defmodule MPP.Methods.Tempo.SponsorBudget do
  @moduledoc """
  Atomic aggregate in-flight accounting for Tempo fee sponsorship.

  Reservations are scoped by chain and sponsor identity and move through
  `:prepared`, `:broadcasting`, and `:pending` phases. The store pins one limits
  set while reservations are live and rejects divergent configurations.

  The guarantee applies to one physical atomic store. `MPP.Tempo.ConCacheStore`
  is suitable for a single BEAM node; every node and endpoint sponsoring the
  same wallet must select the same shared backend for a cluster-wide bound.

  Reservation expiry is deliberately conservative. A reservation remains live
  through its transaction `valid_before` plus a named clock-skew margin, and the
  state-derived store TTL covers that same boundary.
  """

  alias MPP.Tempo.Store

  @state_version 1
  @store_key_prefix "mpp:sponsor-budget:"
  @prepared_lease_seconds 60
  @clock_skew_margin_seconds 60
  @ttl_boundary_guard_seconds 1
  @reconcile_fan_out_limit 8
  @reconcile_timeout_ms to_timeout(second: 5)

  @typedoc "Pinned aggregate sponsor ceilings."
  @type limits :: %{
          max_in_flight_total_fee: pos_integer(),
          max_in_flight_reservations: pos_integer()
        }

  @typedoc "Opaque ownership handle returned by `reserve/3`."
  @type handle :: %{key: String.t(), reservation_id: String.t()}

  @typedoc "Reservation request accepted by `reserve/3`."
  @type reservation_params :: %{
          chain_id: non_neg_integer(),
          sponsor_id: String.t(),
          fee: pos_integer(),
          valid_before: pos_integer(),
          limits: limits()
        }

  @typedoc "Fail-closed budget error."
  @type error_reason ::
          {:capacity_exhausted, pos_integer()}
          | :incompatible_state
          | :invalid_request
          | :limits_mismatch
          | :ownership_lost
          | :store_unavailable

  @doc """
  Atomically reserve worst-case sponsor capacity before signing.

  Pass `:reconcile` with a one-argument receipt fetcher to opt into bounded
  pending-receipt reconciliation when the budget is at capacity. `:now` is
  available for deterministic tests.
  """
  @spec reserve(Store.store_ref(), reservation_params(), keyword()) ::
          {:ok, handle()} | {:error, error_reason()}
  def reserve(store, params, opts \\ [])

  def reserve(store, %{chain_id: chain_id, sponsor_id: sponsor_id} = params, opts)
      when is_integer(chain_id) and chain_id >= 0 and is_binary(sponsor_id) do
    now = Keyword.get(opts, :now, System.os_time(:second))

    with :ok <- validate_reservation(params, now) do
      key = budget_key(chain_id, sponsor_id)

      case do_reserve(store, key, params, now) do
        {:error, {:capacity_exhausted, _retry_after}} = capacity_error ->
          maybe_reconcile_and_retry(capacity_error, store, key, params, now, opts)

        result ->
          result
      end
    end
  end

  def reserve(_store, _params, _opts), do: {:error, :invalid_request}

  @doc """
  Move an owned reservation to `:broadcasting` or `{:pending, tx_hash}`.

  Only the random handle returned by `reserve/3` can mutate its reservation.
  """
  @spec transition(Store.store_ref(), handle(), :broadcasting | {:pending, String.t()}, keyword()) ::
          :ok | {:error, error_reason()}
  def transition(store, handle, target, opts \\ [])

  def transition(store, %{key: key, reservation_id: reservation_id}, target, opts)
      when is_binary(key) and is_binary(reservation_id) do
    now = Keyword.get(opts, :now, System.os_time(:second))

    update_store(store, key, transition_fun(reservation_id, target, now), now)
  end

  def transition(_store, _handle, _target, _opts), do: {:error, :invalid_request}

  @doc """
  Release an owned reservation after a pre-broadcast failure or terminal receipt.
  """
  @spec release(Store.store_ref(), handle(), keyword()) :: :ok | {:error, error_reason()}
  def release(store, handle, opts \\ [])

  def release(store, %{key: key, reservation_id: reservation_id}, opts)
      when is_binary(key) and is_binary(reservation_id) do
    now = Keyword.get(opts, :now, System.os_time(:second))

    update_store(store, key, release_fun(reservation_id, now), now)
  end

  def release(_store, _handle, _opts), do: {:error, :invalid_request}

  @doc """
  Purely remove expired reservations at `now`.

  Chain-valid reservations remain through `valid_before + clock-skew margin`;
  the exact conservative boundary is retained and removal starts after it.
  """
  @spec sweep(map(), integer()) :: map()
  def sweep(reservations, now) when is_map(reservations) and is_integer(now) do
    Map.reject(reservations, fn {_id, reservation} -> expired?(reservation, now) end)
  end

  @spec validate_reservation(map(), integer()) :: :ok | {:error, :invalid_request}
  defp validate_reservation(%{fee: fee, valid_before: valid_before, limits: limits, sponsor_id: sponsor_id}, now) do
    if is_integer(fee) and fee > 0 and is_integer(valid_before) and valid_before > now and
         String.trim(sponsor_id) != "" and valid_limits?(limits) and fee <= limits.max_in_flight_total_fee,
       do: :ok,
       else: {:error, :invalid_request}
  end

  @spec valid_limits?(term()) :: boolean()
  defp valid_limits?(%{max_in_flight_total_fee: max_fee, max_in_flight_reservations: max_reservations}) do
    is_integer(max_fee) and max_fee > 0 and is_integer(max_reservations) and max_reservations > 0
  end

  defp valid_limits?(_limits), do: false

  @spec do_reserve(Store.store_ref(), String.t(), reservation_params(), integer()) ::
          {:ok, handle()} | {:error, error_reason()}
  defp do_reserve(store, key, params, now) do
    reservation_id = random_id()
    handle = %{key: key, reservation_id: reservation_id}

    update_store(store, key, reserve_fun(params, handle, now), now)
  end

  @spec reserve_fun(reservation_params(), handle(), integer()) :: (term() -> term())
  defp reserve_fun(params, handle, now) do
    fn
      :not_found ->
        admit(empty_state(params.limits), params, handle, now)

      state ->
        reserve_existing(state, params, handle, now)
    end
  end

  @spec reserve_existing(term(), reservation_params(), handle(), integer()) :: term()
  defp reserve_existing(state, params, handle, now) do
    if valid_state?(state) do
      swept_state = %{state | reservations: sweep(state.reservations, now)}

      cond do
        map_size(swept_state.reservations) == 0 ->
          admit(empty_state(params.limits), params, handle, now)

        swept_state.limits != params.limits ->
          {:noop, {:error, :limits_mismatch}}

        true ->
          admit(swept_state, params, handle, now, state)
      end
    else
      {:noop, {:error, :incompatible_state}}
    end
  end

  @spec admit(map(), reservation_params(), handle(), integer(), map() | nil) :: term()
  defp admit(state, params, handle, now, original_state \\ nil) do
    used_fee = Enum.reduce(state.reservations, 0, fn {_id, reservation}, total -> total + reservation.fee end)
    count = map_size(state.reservations)

    if used_fee + params.fee <= state.limits.max_in_flight_total_fee and
         count + 1 <= state.limits.max_in_flight_reservations do
      reservation = %{
        fee: params.fee,
        valid_before: params.valid_before,
        lease_until: now + @prepared_lease_seconds,
        phase: :prepared,
        tx_hash: nil
      }

      updated = put_in(state, [:reservations, handle.reservation_id], reservation)
      {:put, updated, {:ok, handle}}
    else
      result = {:error, {:capacity_exhausted, retry_after(state.reservations, now)}}

      if original_state && original_state != state,
        do: {:put, state, result},
        else: {:noop, result}
    end
  end

  @spec transition_fun(String.t(), :broadcasting | {:pending, String.t()}, integer()) :: (term() -> term())
  defp transition_fun(reservation_id, target, now) do
    fn state ->
      mutate_owned(
        state,
        reservation_id,
        now,
        fn
          %{phase: :prepared} = reservation, :broadcasting ->
            {:ok, %{reservation | phase: :broadcasting}}

          %{phase: :broadcasting} = reservation, {:pending, tx_hash} when is_binary(tx_hash) and tx_hash != "" ->
            {:ok, %{reservation | phase: :pending, tx_hash: tx_hash}}

          _reservation, _target ->
            {:error, :ownership_lost}
        end,
        target
      )
    end
  end

  @spec release_fun(String.t(), integer()) :: (term() -> term())
  defp release_fun(reservation_id, now) do
    fn state -> release_owned(state, reservation_id, now) end
  end

  @spec release_owned(term(), String.t(), integer()) :: term()
  defp release_owned(state, reservation_id, now) do
    if valid_state?(state) do
      swept_state = %{state | reservations: sweep(state.reservations, now)}
      release_from_state(state, swept_state, reservation_id)
    else
      {:noop, {:error, :incompatible_state}}
    end
  end

  @spec release_from_state(map(), map(), String.t()) :: term()
  defp release_from_state(original, swept, reservation_id) do
    if Map.has_key?(swept.reservations, reservation_id) do
      swept
      |> update_in([:reservations], &Map.delete(&1, reservation_id))
      |> write_state(:ok)
    else
      write_if_swept(original, swept, {:error, :ownership_lost})
    end
  end

  @spec mutate_owned(term(), String.t(), integer(), function(), term()) :: term()
  defp mutate_owned(state, reservation_id, now, mutation, target) do
    if valid_state?(state) do
      swept_state = %{state | reservations: sweep(state.reservations, now)}

      case Map.fetch(swept_state.reservations, reservation_id) do
        {:ok, reservation} ->
          apply_owned_mutation(mutation.(reservation, target), state, swept_state, reservation_id)

        :error ->
          write_if_swept(state, swept_state, {:error, :ownership_lost})
      end
    else
      {:noop, {:error, :incompatible_state}}
    end
  end

  @spec apply_owned_mutation(term(), map(), map(), String.t()) :: term()
  defp apply_owned_mutation({:ok, updated_reservation}, _original, swept, reservation_id) do
    swept
    |> put_in([:reservations, reservation_id], updated_reservation)
    |> write_state(:ok)
  end

  defp apply_owned_mutation({:error, reason}, original, swept, _reservation_id) do
    write_if_swept(original, swept, {:error, reason})
  end

  @spec maybe_reconcile_and_retry(term(), Store.store_ref(), String.t(), reservation_params(), integer(), keyword()) ::
          {:ok, handle()} | {:error, error_reason()}
  defp maybe_reconcile_and_retry(capacity_error, store, key, params, now, opts) do
    case Keyword.get(opts, :reconcile) do
      receipt_fetcher when is_function(receipt_fetcher, 1) ->
        with {:ok, _released} <- reconcile_pending(store, key, receipt_fetcher, now) do
          do_reserve(store, key, params, now)
        end

      _other ->
        capacity_error
    end
  end

  @spec reconcile_pending(Store.store_ref(), String.t(), (String.t() -> term()), integer()) ::
          {:ok, non_neg_integer()} | {:error, error_reason()}
  defp reconcile_pending(store, key, receipt_fetcher, now) do
    with {:ok, state} <- snapshot(store, key),
         {:ok, candidates} <- pending_candidates(state, now) do
      confirmed = fetch_confirmed(candidates, receipt_fetcher)

      if confirmed == %{},
        do: {:ok, 0},
        else: update_store(store, key, reconcile_fun(confirmed, now), now)
    end
  end

  @spec snapshot(Store.store_ref(), String.t()) :: {:ok, term()} | {:error, :store_unavailable}
  defp snapshot(store, key) do
    case safe_store_update(store, key, fn state -> {:noop, state} end, ignore_key_prefix: true) do
      {:ok, state} -> {:ok, state}
      {:error, _reason} -> {:error, :store_unavailable}
    end
  end

  @spec pending_candidates(term(), integer()) :: {:ok, [{String.t(), String.t()}]} | {:error, error_reason()}
  defp pending_candidates(:not_found, _now), do: {:ok, []}

  defp pending_candidates(state, now) do
    if valid_state?(state) do
      candidates =
        state.reservations
        |> sweep(now)
        |> Enum.flat_map(fn
          {id, %{phase: :pending, tx_hash: tx_hash}} when is_binary(tx_hash) -> [{id, tx_hash}]
          _other -> []
        end)
        |> Enum.take(@reconcile_fan_out_limit)

      {:ok, candidates}
    else
      {:error, :incompatible_state}
    end
  end

  @spec fetch_confirmed([{String.t(), String.t()}], (String.t() -> term())) :: map()
  defp fetch_confirmed(candidates, receipt_fetcher) do
    candidates
    |> Task.async_stream(
      fn {id, tx_hash} -> {id, tx_hash, receipt_fetcher.(tx_hash)} end,
      max_concurrency: @reconcile_fan_out_limit,
      ordered: false,
      timeout: @reconcile_timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{}, fn
      {:ok, {id, tx_hash, {:ok, _receipt}}}, confirmed -> Map.put(confirmed, id, tx_hash)
      _other, confirmed -> confirmed
    end)
  end

  @spec reconcile_fun(map(), integer()) :: (term() -> term())
  defp reconcile_fun(confirmed, now) do
    fn state -> reconcile_state(state, confirmed, now) end
  end

  @spec reconcile_state(term(), map(), integer()) :: term()
  defp reconcile_state(state, confirmed, now) do
    if valid_state?(state) do
      swept_state = %{state | reservations: sweep(state.reservations, now)}
      reconcile_swept_state(state, swept_state, confirmed)
    else
      {:noop, {:error, :incompatible_state}}
    end
  end

  @spec reconcile_swept_state(map(), map(), map()) :: term()
  defp reconcile_swept_state(original, swept, confirmed) do
    remaining =
      Map.reject(swept.reservations, fn {id, reservation} ->
        reservation.phase == :pending and Map.get(confirmed, id) == reservation.tx_hash
      end)

    released = map_size(swept.reservations) - map_size(remaining)
    write_reconciled_state(original, %{swept | reservations: remaining}, released)
  end

  @spec write_reconciled_state(map(), map(), non_neg_integer()) :: term()
  defp write_reconciled_state(_original, updated, released) when released > 0, do: write_state(updated, {:ok, released})

  defp write_reconciled_state(original, updated, 0) when updated != original, do: write_state(updated, {:ok, 0})

  defp write_reconciled_state(_original, _updated, 0), do: {:noop, {:ok, 0}}

  @spec update_store(Store.store_ref(), String.t(), function(), integer()) :: term()
  defp update_store(store, key, fun, now) do
    opts = [ignore_key_prefix: true, ttl_ms: &ttl_ms(&1, now)]

    case safe_store_update(store, key, fun, opts) do
      {:ok, result} -> result
      {:error, _reason} -> {:error, :store_unavailable}
    end
  end

  @spec safe_store_update(Store.store_ref(), String.t(), function(), keyword()) ::
          {:ok, term()} | {:error, term()}
  defp safe_store_update(store, key, fun, opts) do
    Store.update(store, key, fun, opts)
  catch
    :error, reason -> {:error, {:error, reason}}
    :exit, reason -> {:error, {:exit, reason}}
  end

  @spec write_if_swept(map(), map(), term()) :: term()
  defp write_if_swept(original, swept, result) do
    if original == swept, do: {:noop, result}, else: write_state(swept, result)
  end

  @spec write_state(map(), term()) :: term()
  defp write_state(%{reservations: reservations}, result) when map_size(reservations) == 0, do: {:delete, result}

  defp write_state(state, result), do: {:put, state, result}

  @spec empty_state(limits()) :: map()
  defp empty_state(limits), do: %{version: @state_version, limits: limits, reservations: %{}}

  @spec valid_state?(term()) :: boolean()
  defp valid_state?(%{version: @state_version, limits: limits, reservations: reservations}) when is_map(reservations) do
    valid_limits?(limits) and Enum.all?(reservations, &valid_reservation?/1)
  end

  defp valid_state?(_state), do: false

  @spec valid_reservation?({term(), term()}) :: boolean()
  defp valid_reservation?(
         {id, %{fee: fee, valid_before: valid_before, lease_until: lease_until, phase: phase, tx_hash: tx_hash}}
       )
       when is_binary(id) do
    valid_reservation_values?(fee, valid_before, lease_until, phase, tx_hash)
  end

  defp valid_reservation?(_reservation), do: false

  @spec valid_reservation_values?(term(), term(), term(), term(), term()) :: boolean()
  defp valid_reservation_values?(fee, valid_before, lease_until, phase, tx_hash)
       when is_integer(fee) and fee > 0 and is_integer(valid_before) and valid_before > 0 and is_integer(lease_until) do
    valid_phase?(phase, tx_hash)
  end

  defp valid_reservation_values?(_fee, _valid_before, _lease_until, _phase, _tx_hash), do: false

  @spec valid_phase?(term(), term()) :: boolean()
  defp valid_phase?(phase, nil) when phase in [:prepared, :broadcasting], do: true
  defp valid_phase?(:pending, tx_hash) when is_binary(tx_hash), do: tx_hash != ""
  defp valid_phase?(_phase, _tx_hash), do: false

  @spec expired?(map(), integer()) :: boolean()
  defp expired?(reservation, now) do
    now > conservative_expiry(reservation) or
      (reservation.phase == :prepared and now >= reservation.lease_until)
  end

  @spec conservative_expiry(map()) :: integer()
  defp conservative_expiry(reservation), do: reservation.valid_before + @clock_skew_margin_seconds

  @spec retry_after(map(), integer()) :: pos_integer()
  defp retry_after(reservations, now) do
    release_at =
      reservations
      |> Enum.map(fn {_id, reservation} ->
        if reservation.phase == :prepared,
          do: min(reservation.lease_until, conservative_expiry(reservation)),
          else: conservative_expiry(reservation)
      end)
      |> Enum.min()

    max(release_at - now, 1)
  end

  @spec ttl_ms(map(), integer()) :: pos_integer()
  defp ttl_ms(%{reservations: reservations}, now) do
    latest_expiry =
      reservations
      |> Enum.map(fn {_id, reservation} -> conservative_expiry(reservation) end)
      |> Enum.max()

    max(latest_expiry - now + @ttl_boundary_guard_seconds, @ttl_boundary_guard_seconds) * 1_000
  end

  @spec budget_key(non_neg_integer(), String.t()) :: String.t()
  defp budget_key(chain_id, sponsor_id) do
    @store_key_prefix <> Integer.to_string(chain_id) <> ":" <> (sponsor_id |> String.trim() |> String.downcase())
  end

  @spec random_id() :: String.t()
  defp random_id do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
