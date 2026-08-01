defmodule MPP.Methods.Tempo.SponsorBudgetTest do
  use ExUnit.Case, async: false

  alias MPP.Methods.Tempo.SponsorBudget
  alias MPP.Tempo.ConCacheStore
  alias MPP.Test.TempoMemoryStore

  @now 1_700_000_000
  @clock_skew_margin_seconds 60
  @ttl_boundary_guard_seconds 1
  @prepared_lease_seconds 60
  @concurrent_attempts 10
  @task_timeout_ms to_timeout(second: 5)

  defmodule FailingStore do
    @moduledoc false

    def update(_key, _fun, _opts), do: {:error, :unavailable}
  end

  defmodule RaisingStore do
    @moduledoc false

    def update(_key, _fun, _opts), do: raise("unavailable")
  end

  defmodule ExitingStore do
    @moduledoc false

    def update(_key, _fun, _opts), do: exit(:unavailable)
  end

  defmodule TtlSpyStore do
    @moduledoc false

    use Agent

    def start_link(_opts), do: Agent.start_link(fn -> %{value: :not_found, ttl_ms: nil} end, name: __MODULE__)

    def update(_key, fun, opts) do
      Agent.get_and_update(__MODULE__, fn state ->
        case fun.(state.value) do
          {:put, value, result} ->
            ttl_ms = opts |> Keyword.fetch!(:ttl_ms) |> then(& &1.(value))
            {{:ok, result}, %{value: value, ttl_ms: ttl_ms}}

          {:delete, result} ->
            {{:ok, result}, %{value: :not_found, ttl_ms: nil}}

          {:noop, result} ->
            {{:ok, result}, state}
        end
      end)
    end

    def state, do: Agent.get(__MODULE__, & &1)
  end

  setup do
    start_supervised!(TempoMemoryStore)
    :ok
  end

  describe "reserve/3" do
    test "atomically enforces aggregate fee and reservation ceilings under contention" do
      parent = self()

      tasks =
        for attempt <- 1..@concurrent_attempts do
          Task.async(fn ->
            send(parent, {:ready, attempt})

            receive do
              :go ->
                SponsorBudget.reserve(TempoMemoryStore, params(fee: 10, total_limit: 30, count_limit: 3), now: @now)
            after
              @task_timeout_ms -> {:error, :not_released}
            end
          end)
        end

      for attempt <- 1..@concurrent_attempts do
        assert_receive {:ready, ^attempt}, @task_timeout_ms
      end

      Enum.each(tasks, &send(&1.pid, :go))

      results = Task.await_many(tasks, @task_timeout_ms)
      assert Enum.count(results, &match?({:ok, _handle}, &1)) == 3
      assert Enum.count(results, &match?({:error, {:capacity_exhausted, _seconds}}, &1)) == 7

      assert {:ok, state} = TempoMemoryStore.get(budget_key())
      assert map_size(state.reservations) == 3
      assert state.reservations |> Map.values() |> Enum.sum_by(& &1.fee) == 30
    end

    test "enforces the reservation-count ceiling independently" do
      assert {:ok, _first} =
               SponsorBudget.reserve(TempoMemoryStore, params(fee: 1, total_limit: 100, count_limit: 1), now: @now)

      assert {:error, {:capacity_exhausted, retry_after}} =
               SponsorBudget.reserve(TempoMemoryStore, params(fee: 1, total_limit: 100, count_limit: 1), now: @now)

      assert retry_after == @prepared_lease_seconds
    end

    test "rejects incompatible state, divergent limits, store failures, and invalid identity without overwriting" do
      assert :ok = TempoMemoryStore.put(budget_key(), :foreign)

      assert {:error, :incompatible_state} =
               SponsorBudget.reserve(TempoMemoryStore, params(), now: @now)

      assert {:ok, :foreign} = TempoMemoryStore.get(budget_key())

      assert :ok = TempoMemoryStore.put(budget_key(), %{version: 2, limits: limits(), reservations: %{}})

      assert {:error, :incompatible_state} =
               SponsorBudget.reserve(TempoMemoryStore, params(), now: @now)

      assert {:ok, %{version: 2}} = TempoMemoryStore.get(budget_key())

      assert :ok = TempoMemoryStore.put(budget_key(), :not_used)
      assert {:error, :store_unavailable} = SponsorBudget.reserve(FailingStore, params(), now: @now)

      assert {:error, :invalid_request} =
               SponsorBudget.reserve(TempoMemoryStore, params(sponsor_id: "  "), now: @now)

      assert {:ok, :not_used} = TempoMemoryStore.get(budget_key())

      assert {:error, :store_unavailable} = SponsorBudget.reserve(RaisingStore, params(), now: @now)
      assert {:error, :store_unavailable} = SponsorBudget.reserve(ExitingStore, params(), now: @now)
    end

    test "rejects malformed public input and malformed reservation state" do
      assert {:error, :invalid_request} = SponsorBudget.reserve(TempoMemoryStore, %{})

      assert {:error, :invalid_request} =
               SponsorBudget.reserve(TempoMemoryStore, Map.put(params(), :limits, %{}), now: @now)

      assert {:error, :invalid_request} = SponsorBudget.transition(TempoMemoryStore, %{}, :broadcasting)
      assert {:error, :invalid_request} = SponsorBudget.release(TempoMemoryStore, %{})

      malformed = %{version: 1, limits: limits(), reservations: %{"id" => :foreign}}
      assert :ok = TempoMemoryStore.put(budget_key(), malformed)
      assert {:error, :incompatible_state} = SponsorBudget.reserve(TempoMemoryStore, params(), now: @now)
      assert {:ok, ^malformed} = TempoMemoryStore.get(budget_key())

      malformed = %{
        version: 1,
        limits: limits(),
        reservations: %{
          "id" => %{fee: 0, valid_before: @now, lease_until: @now, phase: :prepared, tx_hash: nil}
        }
      }

      assert :ok = TempoMemoryStore.put(budget_key(), malformed)
      assert {:error, :incompatible_state} = SponsorBudget.reserve(TempoMemoryStore, params(), now: @now)
      assert {:ok, ^malformed} = TempoMemoryStore.get(budget_key())
    end

    test "pins limits while live and re-pins after the state drains" do
      assert {:ok, handle} = SponsorBudget.reserve(TempoMemoryStore, params(total_limit: 20), now: @now)
      original = TempoMemoryStore.get(budget_key())

      assert {:error, :limits_mismatch} =
               SponsorBudget.reserve(TempoMemoryStore, params(total_limit: 30), now: @now)

      assert TempoMemoryStore.get(budget_key()) == original
      assert :ok = SponsorBudget.release(TempoMemoryStore, handle, now: @now)
      assert :not_found = TempoMemoryStore.get(budget_key())

      assert {:ok, _handle} = SponsorBudget.reserve(TempoMemoryStore, params(total_limit: 30), now: @now)
      assert {:ok, %{limits: %{max_in_flight_total_fee: 30}}} = TempoMemoryStore.get(budget_key())
    end

    test "sweeps expired state before re-pinning or reporting capacity" do
      assert {:ok, _expired} =
               SponsorBudget.reserve(TempoMemoryStore, params(total_limit: 20, count_limit: 1), now: @now)

      assert {:ok, _replacement} =
               SponsorBudget.reserve(
                 TempoMemoryStore,
                 params(total_limit: 30, count_limit: 1, valid_before: @now + 180),
                 now: @now + @prepared_lease_seconds
               )

      assert {:ok, %{limits: %{max_in_flight_total_fee: 30}}} = TempoMemoryStore.get(budget_key())

      live = %{
        "live" => %{
          fee: 10,
          valid_before: @now + 120,
          lease_until: @now + @prepared_lease_seconds,
          phase: :broadcasting,
          tx_hash: nil
        },
        "expired" => %{
          fee: 10,
          valid_before: @now + 120,
          lease_until: @now,
          phase: :prepared,
          tx_hash: nil
        }
      }

      state = %{version: 1, limits: %{max_in_flight_total_fee: 20, max_in_flight_reservations: 1}, reservations: live}
      assert :ok = TempoMemoryStore.put(budget_key(), state)

      assert {:error, {:capacity_exhausted, _seconds}} =
               SponsorBudget.reserve(TempoMemoryStore, params(total_limit: 20, count_limit: 1), now: @now)

      assert {:ok, swept} = TempoMemoryStore.get(budget_key())
      assert Map.keys(swept.reservations) == ["live"]
    end

    test "normalizes sponsor casing and bypasses replay key prefixes" do
      cache_name = unique_cache_name()
      start_supervised!(ConCacheStore.child_spec(name: cache_name))

      store_a = {ConCacheStore, name: cache_name, key_prefix: "route-a:"}
      store_b = {ConCacheStore, name: cache_name, key_prefix: "route-b:"}

      assert {:ok, _handle} =
               SponsorBudget.reserve(store_a, params(sponsor_id: "  Sponsor-Wallet ", count_limit: 1), now: @now)

      assert {:error, {:capacity_exhausted, _seconds}} =
               SponsorBudget.reserve(store_b, params(sponsor_id: "sponsor-wallet", count_limit: 1), now: @now)
    end
  end

  describe "ownership and lifecycle" do
    test "only the owner can transition or release a reservation" do
      assert {:ok, handle} = SponsorBudget.reserve(TempoMemoryStore, params(), now: @now)
      foreign = %{handle | reservation_id: "another-request"}
      original = TempoMemoryStore.get(budget_key())

      assert {:error, :ownership_lost} = SponsorBudget.transition(TempoMemoryStore, foreign, :broadcasting, now: @now)
      assert {:error, :ownership_lost} = SponsorBudget.release(TempoMemoryStore, foreign, now: @now)
      assert TempoMemoryStore.get(budget_key()) == original

      assert :ok = SponsorBudget.transition(TempoMemoryStore, handle, :broadcasting, now: @now)
      assert {:error, :ownership_lost} = SponsorBudget.transition(TempoMemoryStore, handle, :broadcasting, now: @now)
      assert :ok = SponsorBudget.transition(TempoMemoryStore, handle, {:pending, "0xabc"}, now: @now)

      assert {:ok, state} = TempoMemoryStore.get(budget_key())
      assert state.reservations[handle.reservation_id].phase == :pending
      assert state.reservations[handle.reservation_id].tx_hash == "0xabc"
      assert :ok = SponsorBudget.release(TempoMemoryStore, handle, now: @now)
      assert :not_found = TempoMemoryStore.get(budget_key())
    end

    test "prepared lease and conservative chain-valid expiry retain exact boundaries" do
      reservation = %{
        fee: 1,
        valid_before: @now + 10,
        lease_until: @now + @prepared_lease_seconds,
        phase: :broadcasting,
        tx_hash: nil
      }

      conservative_expiry = reservation.valid_before + @clock_skew_margin_seconds

      assert map_size(SponsorBudget.sweep(%{"id" => reservation}, conservative_expiry - 1)) == 1
      assert map_size(SponsorBudget.sweep(%{"id" => reservation}, conservative_expiry)) == 1
      assert SponsorBudget.sweep(%{"id" => reservation}, conservative_expiry + 1) == %{}

      prepared = %{reservation | phase: :prepared}
      assert map_size(SponsorBudget.sweep(%{"id" => prepared}, prepared.lease_until - 1)) == 1
      assert SponsorBudget.sweep(%{"id" => prepared}, prepared.lease_until) == %{}
    end

    test "state-derived TTL refreshes from the longest conservative expiry" do
      start_supervised!(TtlSpyStore)
      long_valid_before = @now + 900
      short_valid_before = @now + 60

      expected_ttl_ms =
        (long_valid_before + @clock_skew_margin_seconds - @now + @ttl_boundary_guard_seconds) * 1_000

      assert {:ok, long_handle} =
               SponsorBudget.reserve(TtlSpyStore, params(valid_before: long_valid_before, count_limit: 3), now: @now)

      assert %{ttl_ms: ^expected_ttl_ms} = TtlSpyStore.state()

      assert {:ok, short_handle} =
               SponsorBudget.reserve(TtlSpyStore, params(valid_before: short_valid_before, count_limit: 3), now: @now)

      assert %{ttl_ms: ^expected_ttl_ms} = TtlSpyStore.state()
      assert :ok = SponsorBudget.release(TtlSpyStore, short_handle, now: @now)
      assert %{ttl_ms: ^expected_ttl_ms} = TtlSpyStore.state()
      assert :ok = SponsorBudget.transition(TtlSpyStore, long_handle, :broadcasting, now: @now)
      assert %{ttl_ms: ^expected_ttl_ms} = TtlSpyStore.state()
    end
  end

  describe "bounded pending reconciliation" do
    test "failed or absent receipts retain pending capacity; a terminal receipt frees it" do
      assert {:ok, handle} =
               SponsorBudget.reserve(TempoMemoryStore, params(count_limit: 1), now: @now)

      assert :ok = SponsorBudget.transition(TempoMemoryStore, handle, :broadcasting, now: @now)
      assert :ok = SponsorBudget.transition(TempoMemoryStore, handle, {:pending, "0xabc"}, now: @now)

      assert {:error, {:capacity_exhausted, _seconds}} =
               SponsorBudget.reserve(TempoMemoryStore, params(count_limit: 1),
                 now: @now,
                 reconcile: fn _tx_hash -> {:error, :not_found} end
               )

      assert {:ok, %{reservations: retained}} = TempoMemoryStore.get(budget_key())
      assert map_size(retained) == 1

      assert {:ok, new_handle} =
               SponsorBudget.reserve(TempoMemoryStore, params(count_limit: 1),
                 now: @now,
                 reconcile: fn "0xabc" -> {:ok, %{status: :terminal}} end
               )

      refute new_handle.reservation_id == handle.reservation_id
    end

    test "reconciliation ignores broadcasting reservations and caps receipt fan-out" do
      count_limit = 10

      handles =
        for index <- 1..count_limit do
          assert {:ok, handle} =
                   SponsorBudget.reserve(TempoMemoryStore, params(fee: 1, total_limit: 10, count_limit: count_limit),
                     now: @now
                   )

          assert :ok = SponsorBudget.transition(TempoMemoryStore, handle, :broadcasting, now: @now)

          if index == count_limit do
            handle
          else
            assert :ok =
                     SponsorBudget.transition(TempoMemoryStore, handle, {:pending, "0x#{index}"}, now: @now)

            handle
          end
        end

      counter = start_supervised!({Agent, fn -> 0 end})

      assert {:error, {:capacity_exhausted, _seconds}} =
               SponsorBudget.reserve(TempoMemoryStore, params(fee: 1, total_limit: 10, count_limit: count_limit),
                 now: @now,
                 reconcile: fn _tx_hash ->
                   Agent.update(counter, &(&1 + 1))
                   {:error, :pending}
                 end
               )

      assert Agent.get(counter, & &1) == 8
      broadcasting_handle = List.last(handles)
      assert {:ok, state} = TempoMemoryStore.get(budget_key())
      assert state.reservations[broadcasting_handle.reservation_id].phase == :broadcasting
    end
  end

  defp params(overrides \\ []) do
    %{
      chain_id: Keyword.get(overrides, :chain_id, 42_431),
      sponsor_id: Keyword.get(overrides, :sponsor_id, "sponsor-wallet"),
      fee: Keyword.get(overrides, :fee, 10),
      valid_before: Keyword.get(overrides, :valid_before, @now + 120),
      limits: %{
        max_in_flight_total_fee: Keyword.get(overrides, :total_limit, 20),
        max_in_flight_reservations: Keyword.get(overrides, :count_limit, 2)
      }
    }
  end

  defp limits do
    %{max_in_flight_total_fee: 20, max_in_flight_reservations: 2}
  end

  defp budget_key, do: "mpp:sponsor-budget:42431:sponsor-wallet"

  defp unique_cache_name do
    [:positive]
    |> System.unique_integer()
    |> then(&:"#{__MODULE__}.#{&1}")
  end
end
