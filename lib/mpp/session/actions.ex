defmodule MPP.Session.Actions do
  @moduledoc """
  Server-side session credential action handlers.

  Dispatches on `credential.payload.action` to `open`, `voucher`, `top_up`,
  and `close`. Each handler updates per-channel deposit / voucher /
  spend balances through `MPP.Session.Store`.

  `open` and `topUp` require funding verifiers, passed as the `:verify_open` /
  `:verify_top_up` options or the server-only `"verify_open"` /
  `"verify_top_up"` method-config keys. `open` calls `verify.(payload, opts)`
  and `topUp` calls `verify.(payload, channel, opts)`. Without a verifier the
  action is rejected.

  A verifier MUST confirm on-chain, at the finality the server requires, that
  the credential's transaction succeeded, that it targets the configured
  `escrow_contract` on the configured `chain_id`, and that it funds the
  credential's `channelId` with the configured payee and token. It returns
  the escrow's current channel state, or `{:error, %MPP.Errors{}}`:

      {:ok, %{
        deposit: non_neg_integer(),      # total escrowed deposit
        settled: non_neg_integer(),      # paid out of the escrow, at most deposit
        close_requested: boolean(),      # a close is pending on-chain
        finalized: boolean(),            # the channel is closed on-chain
        payer: String.t(),               # open only, optional
        authorized_signer: String.t(),   # open only, optional
        tx_hash: String.t()              # optional; this action's receipt txHash
      }}

  A reported `tx_hash` is copied onto that action's receipt only. It is not
  stored on the channel, so a later voucher does not inherit it. `verify_top_up`
  MUST confirm the transaction calldata is an escrow `topUp` for this
  `channelId` and `additionalDeposit`. Actions does not decode the calldata.

  `deposit`, `settled`, `close_requested`, and `finalized` are all required;
  a result missing any of them, or of any other shape, is a verification
  failure. A zero deposit is rejected as an unfunded channel;
  `close_requested` or `finalized` reject the action as a closed channel. The payload's `additionalDeposit` and any configured
  or suggested deposit are never trusted as the ceiling.

  Settled funds were already paid out of the escrow for earlier vouchers. At
  `open` the voucher's `cumulativeAmount` must lie between `settled` and
  `deposit`, the channel records `settled` as already spent, and only
  `cumulativeAmount - settled` counts toward the request. At `topUp` the
  deposit must increase, `settled` never decreases, and spent and cumulative
  are raised to it, so settled funds are never counted twice.

  At `open` a verified payer must match the configured payer, and a verified
  signer becomes the channel signer (a descriptor must agree with it).

  The voucher signer is fixed at `open` and stored on the channel. A zero
  signer address, from any source, means the payer signs. The signer is the
  descriptor's `authorizedSigner` once the descriptor hashes to `channelId`
  under the configured `escrow_contract` and `chain_id`; otherwise the
  verified signer, then the configured `:authorized_signer`, falling back to
  the payer. A descriptor's payee and
  token must match the configured recipient and token. A credential's
  top-level `authorizedSigner` must equal that signer. Vouchers and closes are
  verified against the stored signer only.

  The highest accepted voucher signature is kept on the channel as its
  settlement proof.

  Local open checks run before `verify_open` broadcasts. The channel must be
  absent, and the voucher's cumulative amount must cover the request. When a
  signer is already known (the configured key, or a bound descriptor's signer),
  the signature must recover to that signer even if the payer is still
  missing. A descriptor or credential signer that already disagrees with
  server configuration is rejected once payer, recipient, and token are known.
  A missing payer may still be supplied by the callback. The on-chain deposit
  is known only after `verify_open`, so a callback that broadcasts must reject
  a voucher above the decoded deposit before sending. Actions repeats that
  bound, and rejects an unsettled deposit below the request, only after the
  callback returns. When that callback names a different signer, the signature
  is checked again against it.

  `close` requires a settlement callback, passed as the `:settle_close` option
  or the server-only `"settle_close"` method-config key. Once the close voucher
  has been validated, `close` calls `settle.(payload, closing_channel, opts)`.
  The callback MUST submit the escrow close (or settle) for that voucher, wait
  for the transaction to succeed at the finality the server requires, and
  return `{:ok, %{tx_hash: "0x" <> 64 hex}}` or `{:error, %MPP.Errors{}}`. Only
  then is the channel marked closed. The hash is recorded on its proof and
  returned as the receipt `txHash`; the receipt reference stays the channel id.
  Before the callback runs, the channel is reserved as closing: it accepts no
  vouchers, spends, top-ups or competing closes. `{:error, %MPP.Errors{}}`
  must mean the close definitively did not settle; it releases the reservation
  and the channel stays active. Any other result (or a raise) leaves the
  outcome unknown, so the close is rejected and the channel stays reserved
  for the operator to reconcile. Methods
  that redeem closed channels themselves (`MPP.Methods.XRPL.Session`) pass
  `settle_close: :caller`.
  """

  alias MPP.Errors
  alias MPP.Intents.Session
  alias MPP.Methods.Shared
  alias MPP.Receipt
  alias MPP.Session.Channel
  alias MPP.Session.Payload
  alias MPP.Session.Store
  alias MPP.Session.Voucher
  alias Onchain.Address

  @type opts :: keyword()

  @doc "Parse a session payload and apply the matching channel-state handler."
  @spec dispatch(map(), opts()) :: {:ok, Receipt.t()} | {:error, Errors.t()}
  def dispatch(payload, opts \\ []) when is_list(opts) do
    case Payload.parse(payload) do
      {:ok, parsed} -> handle(parsed, opts)
      {:error, reason} -> {:error, payload_error(reason)}
    end
  end

  @doc "Dispatch a session credential payload using fields on the session intent."
  @spec verify(map(), Session.t()) :: {:ok, Receipt.t()} | {:error, Errors.t()}
  def verify(payload, %Session{} = session) when is_map(payload) do
    dispatch(payload, opts_from_session(session))
  end

  @doc "Return the effective minimum voucher delta for a session intent."
  @spec minimum_voucher_delta(Session.t()) :: non_neg_integer()
  def minimum_voucher_delta(%Session{} = session) do
    session |> opts_from_session() |> min_voucher_delta()
  end

  @doc "Apply a parsed session payload to the channel store."
  @spec handle(Payload.t(), opts()) :: {:ok, Receipt.t()} | {:error, Errors.t()}
  def handle(%Payload{action: :open} = payload, opts), do: handle_open(payload, opts)
  def handle(%Payload{action: :top_up} = payload, opts), do: handle_top_up(payload, opts)
  def handle(%Payload{action: :voucher} = payload, opts), do: handle_voucher(payload, opts)
  def handle(%Payload{action: :close} = payload, opts), do: handle_close(payload, opts)

  defp handle_open(payload, opts) do
    with :ok <- ensure_channel_absent(payload, opts),
         :ok <- ensure_voucher_covers_request(payload, opts),
         :ok <- precheck_local_open(payload, opts),
         {:ok, verified} <- verify_open(payload, opts),
         :ok <- ensure_open_within_escrow(payload, verified),
         :ok <-
           ensure_covers_request(
             payload.cumulative_amount - verified.settled,
             verified.deposit - verified.settled,
             request_amount(opts)
           ),
         {:ok, identity_opts} <- apply_verified_identity(opts, verified),
         {:ok, identity} <- require_open_identity(payload, identity_opts),
         :ok <- reverify_open_signature(payload, identity, opts) do
      update_channel(payload, put_tx_hash(opts, verified), fn
        :not_found ->
          open_channel(payload, identity, verified, opts)

        %Channel{status: :closed} ->
          {:error, Errors.new(:channel_closed, "channel is closed")}

        %Channel{} ->
          {:error, Errors.new(:invalid_payload, "channel already exists")}
      end)
    end
  end

  defp handle_top_up(payload, opts) do
    with {:ok, current} <- fetch_live_channel(payload, opts),
         :ok <- require_positive_top_up(payload),
         {:ok, verified} <- verify_top_up(payload, current, opts) do
      update_channel(payload, put_tx_hash(opts, verified), fn
        :not_found ->
          {:error, Errors.new(:channel_not_found, "channel not found")}

        %Channel{status: :closed} ->
          {:error, Errors.new(:channel_closed, "channel is closed")}

        %Channel{} = channel ->
          Channel.apply_verified_deposit(channel, verified.deposit, verified.settled)
      end)
    end
  end

  defp fetch_live_channel(payload, opts) do
    case Store.get(store(opts), payload.channel_id) do
      {:ok, %Channel{status: :closed}} -> {:error, Errors.new(:channel_closed, "channel is closed")}
      {:ok, %Channel{closing: true}} -> {:error, store_error(:channel_closing)}
      {:ok, %Channel{} = channel} -> {:ok, channel}
      :not_found -> {:error, Errors.new(:channel_not_found, "channel not found")}
      {:error, reason} -> {:error, store_error(reason)}
    end
  end

  defp require_positive_top_up(%Payload{additional_deposit: amount}) when is_integer(amount) and amount > 0, do: :ok
  defp require_positive_top_up(_payload), do: {:error, store_error({:invalid_amount, :additional_deposit})}

  # The claimed additionalDeposit is never trusted: the deposit ceiling only
  # moves to the escrow total the configured verifier confirms on-chain.
  # The callback MUST confirm the calldata is an escrow `topUp` for this
  # channelId and additionalDeposit. Actions does not decode the transaction.
  defp verify_top_up(payload, channel, opts) do
    case Keyword.get(opts, :verify_top_up) do
      fun when is_function(fun, 3) ->
        payload |> fun.(channel, opts) |> escrow_state("topUp")

      _ ->
        {:error,
         Errors.new(
           :verification_failed,
           "topUp requires a configured funding verifier (verify_top_up) that confirms the escrow deposit on-chain"
         )}
    end
  end

  defp handle_voucher(payload, opts) do
    with_channel_signer(payload, opts, &accept_voucher/3)
  end

  # A close finalizes the channel only after the escrow settled it on-chain:
  # the configured `settle_close` callback submits the close and returns the
  # mined transaction hash. Methods that redeem closed channels themselves
  # (XRPL `redeem/2`) pass `settle_close: :caller`.
  defp handle_close(payload, opts) do
    case Keyword.get(opts, :settle_close) do
      :caller ->
        with_channel_signer(payload, opts, &close_channel/3)

      fun when is_function(fun, 3) ->
        settle_and_close(payload, fun, opts)

      _ ->
        {:error,
         Errors.new(
           :verification_failed,
           "close requires a configured settlement callback (settle_close) that closes the channel on-chain"
         )}
    end
  end

  # The channel is reserved (`closing`) atomically before settlement, so no
  # voucher, spend, top-up or competing close can move it while the escrow
  # close is in flight (mpp-rs `mark_pending_close`, mppx CredentialVerification).
  defp settle_and_close(payload, settle, opts) do
    with {:ok, reserved} <- reserve_close(payload, opts),
         {:ok, closing} <- reserved |> Channel.clear_closing() |> close_channel(payload, opts),
         {:ok, tx_hash} <- settle_reserved(payload, settle.(payload, closing, opts), opts) do
      finalize_close(payload, tx_hash, opts)
    else
      {:error, {:invalid_transition, _status, _to} = reason} -> {:error, store_error(reason)}
      {:error, {:invalid_amount, _field} = reason} -> {:error, store_error(reason)}
      other -> other
    end
  end

  defp reserve_close(payload, opts) do
    store_update(payload, opts, fn
      :not_found ->
        {:error, Errors.new(:channel_not_found, "channel not found")}

      %Channel{status: :closed} ->
        {:error, Errors.new(:channel_closed, "channel is closed")}

      %Channel{} = channel ->
        with :ok <- verify_channel_signer(channel, payload, opts),
             {:ok, _closed} <- channel |> Channel.clear_closing() |> close_channel(payload, opts) do
          Channel.mark_closing(channel)
        end
    end)
  end

  # Only a definitive `{:error, %MPP.Errors{}}` releases the reservation. Any
  # other result leaves the close outcome unknown, so the channel stays pending
  # close (no further spending) until the operator reconciles it.
  defp settle_reserved(payload, {:error, %Errors{}} = failed, opts) do
    _released =
      Store.update(store(opts), payload.channel_id, fn
        %Channel{closing: true} = channel -> {:ok, Channel.clear_closing(channel)}
        %Channel{} = channel -> {:ok, channel}
        :not_found -> {:error, :channel_not_found}
      end)

    failed
  end

  defp settle_reserved(_payload, {:ok, %{tx_hash: "0x" <> hex}}, _opts) when byte_size(hex) == 64 do
    if MPP.Hex.hex_string?(hex),
      do: {:ok, "0x" <> String.downcase(hex)},
      else: unknown_settlement({:ok, %{tx_hash: "0x" <> hex}})
  end

  defp settle_reserved(_payload, result, _opts), do: unknown_settlement(result)

  defp unknown_settlement(result) do
    {:error,
     Errors.new(
       :verification_failed,
       "close settlement returned an unrecognized result; channel left pending close: #{inspect(result)}"
     )}
  end

  defp finalize_close(payload, tx_hash, opts) do
    update_channel(payload, opts, fn
      %Channel{status: :active, closing: true} = channel ->
        with {:ok, closed} <- channel |> Channel.clear_closing() |> close_channel(payload, opts) do
          {:ok, put_close_tx_hash(closed, tx_hash)}
        end

      _other ->
        {:error, Errors.new(:verification_failed, "channel is no longer pending close")}
    end)
  end

  defp put_close_tx_hash(%Channel{proof: proof} = channel, tx_hash) when is_map(proof),
    do: %{channel | proof: Map.put(proof, :tx_hash, tx_hash)}

  defp put_close_tx_hash(channel, _tx_hash), do: channel

  # Voucher and close signatures are checked against the signer recorded on
  # the channel at open, never against a signer named by the credential. The
  # check runs inside the atomic update so it sees the same channel it mutates.
  defp with_channel_signer(payload, opts, apply_fun) do
    update_channel(payload, opts, fn
      :not_found ->
        {:error, Errors.new(:channel_not_found, "channel not found")}

      %Channel{status: :closed} ->
        {:error, Errors.new(:channel_closed, "channel is closed")}

      %Channel{} = channel ->
        with :ok <- verify_channel_signer(channel, payload, opts) do
          apply_fun.(channel, payload, opts)
        end
    end)
  end

  defp verify_channel_signer(channel, payload, opts) do
    signer = channel_signer(channel, opts)

    with :ok <- ensure_same_descriptor(payload, signer, opts) do
      maybe_verify_signature(payload, signer, opts)
    end
  end

  defp channel_signer(%Channel{authorized_signer: signer, payer: payer}, _opts) when is_binary(signer),
    do: resolve_signer(signer, payer)

  defp channel_signer(%Channel{payer: payer}, opts), do: resolve_signer(Keyword.get(opts, :authorized_signer), payer)

  defp ensure_same_descriptor(%Payload{descriptor: nil}, _signer, _opts), do: :ok

  defp ensure_same_descriptor(%Payload{descriptor: descriptor} = payload, signer, opts) do
    with :ok <- ensure_descriptor_binds_channel(payload, opts) do
      if same_address?(descriptor_signer(descriptor), signer) do
        :ok
      else
        {:error, Errors.new(:signer_mismatch, "descriptor signer does not match the channel")}
      end
    end
  end

  # Already-settled funds were paid from accepted vouchers, so they start as
  # spent rather than as spendable balance.
  defp open_channel(payload, identity, verified, opts) do
    with {:ok, channel} <-
           Channel.new(
             channel_id: payload.channel_id,
             payer: identity.payer,
             recipient: identity.recipient,
             token: identity.token,
             authorized_signer: identity.authorized_signer,
             deposit: verified.deposit,
             settled: verified.settled,
             spent: verified.settled,
             cumulative_amount: payload.cumulative_amount,
             proof: settlement_proof(payload, opts)
           ),
         {:ok, channel} <- Channel.activate(channel) do
      maybe_spend(channel, request_amount(opts))
    end
  end

  defp accept_voucher(channel, payload, opts) do
    delta = payload.cumulative_amount - channel.cumulative_amount
    min_delta = min_voucher_delta(opts)

    cond do
      payload.cumulative_amount == channel.cumulative_amount ->
        {:error, Errors.new(:delta_too_small, "voucher must increase the accepted cumulative amount")}

      payload.cumulative_amount < channel.cumulative_amount ->
        {:error, Errors.new(:invalid_payload, "voucher cumulativeAmount is not monotonic")}

      delta < min_delta ->
        {:error, Errors.new(:delta_too_small, "voucher delta #{delta} below minimum #{min_delta}")}

      true ->
        proof = settlement_proof(payload, opts)

        with {:ok, channel} <- Channel.apply_voucher(channel, payload.cumulative_amount, proof) do
          maybe_spend(channel, request_amount(opts))
        end
    end
  end

  defp close_channel(channel, payload, opts) do
    proof = settlement_proof(payload, opts)

    cond do
      payload.cumulative_amount < channel.spent ->
        {:error,
         Errors.new(
           :verification_failed,
           "close voucher amount must be >= #{channel.spent} (spent)"
         )}

      payload.cumulative_amount > channel.deposit ->
        {:error, Errors.new(:amount_exceeds_deposit, "close voucher amount exceeds deposit")}

      payload.cumulative_amount > channel.cumulative_amount ->
        with {:ok, channel} <- Channel.apply_voucher(channel, payload.cumulative_amount, proof) do
          Channel.close(channel)
        end

      true ->
        Channel.close(channel)
    end
  end

  # The highest accepted voucher signature is retained so the channel can be
  # settled on-chain. XRPL claims also carry the ledger PublicKey.
  defp settlement_proof(%Payload{signature: signature, cumulative_amount: amount}, opts)
       when is_binary(signature) and signature != "" do
    case Keyword.get(opts, :proof) do
      %{public_key: key} when is_binary(key) and key != "" ->
        Channel.new_proof(amount, signature, key)

      _ ->
        Channel.new_proof(amount, signature, nil)
    end
  end

  defp settlement_proof(_payload, _opts), do: nil

  defp maybe_spend(channel, 0), do: {:ok, channel}
  defp maybe_spend(channel, amount), do: Channel.apply_spend(channel, amount)

  defp update_channel(%Payload{} = payload, opts, fun) do
    opts = Keyword.put(opts, :action, payload.action)

    with {:ok, channel} <- store_update(payload, opts, fun), do: {:ok, receipt(channel, opts)}
  end

  defp store_update(%Payload{} = payload, opts, fun) do
    case Store.update(store(opts), payload.channel_id, &normalize_update(fun.(&1))) do
      {:ok, channel} -> {:ok, channel}
      {:error, reason} -> {:error, store_error(reason)}
    end
  end

  defp store_error(%Errors{} = error), do: error
  defp store_error(:channel_closing), do: Errors.new(:channel_closed, "channel is closing")
  defp store_error(:insufficient_balance), do: Errors.new(:insufficient_balance, "insufficient channel balance")
  defp store_error(:amount_exceeds_deposit), do: Errors.new(:amount_exceeds_deposit, "amount exceeds channel deposit")

  defp store_error(:deposit_not_increased),
    do: Errors.new(:verification_failed, "channel deposit did not increase after topUp")

  defp store_error({:invalid_transition, status, _to}) do
    Errors.new(:invalid_payload, "invalid channel transition from #{status}")
  end

  defp store_error({:invalid_amount, field}), do: Errors.new(:invalid_payload, "invalid #{field}")
  defp store_error(_reason), do: Shared.internal_payment_error()

  defp normalize_update({:ok, %Channel{}} = ok), do: ok
  defp normalize_update({:error, _reason} = error), do: error
  defp normalize_update(other), do: {:error, {:invalid_update_result, other}}

  defp ensure_channel_absent(payload, opts) do
    case Store.get(store(opts), payload.channel_id) do
      :not_found -> :ok
      {:ok, %Channel{status: :closed}} -> {:error, Errors.new(:channel_closed, "channel is closed")}
      {:ok, %Channel{}} -> {:error, Errors.new(:invalid_payload, "channel already exists")}
      {:error, reason} -> {:error, store_error(reason)}
    end
  end

  # The channel ceiling is the escrow deposit the configured verifier confirms
  # on-chain; no configured or suggested deposit is trusted in its place.
  defp verify_open(payload, opts) do
    case Keyword.get(opts, :verify_open) do
      fun when is_function(fun, 2) ->
        payload |> fun.(opts) |> escrow_state("open")

      _ ->
        {:error,
         Errors.new(
           :verification_failed,
           "open requires a configured funding verifier (verify_open) that confirms the escrow deposit on-chain"
         )}
    end
  end

  # Normalizes a funding verifier result into the confirmed escrow state,
  # rejecting unfunded, closing, and finalized channels.
  # Every state key is required: an omitted flag must not read as "open".
  defp escrow_state({:ok, %{deposit: _, settled: _, close_requested: _, finalized: _} = state} = result, action) do
    if well_formed_escrow?(state), do: escrow_status(state), else: escrow_failure(result, action)
  end

  defp escrow_state({:error, %Errors{} = error}, _action), do: {:error, error}
  defp escrow_state(other, action), do: escrow_failure(other, action)

  defp escrow_failure(result, action),
    do: {:error, Errors.new(:verification_failed, "#{action} funding verification failed: #{inspect(result)}")}

  defp well_formed_escrow?(%{deposit: deposit, settled: settled} = state) do
    is_integer(deposit) and is_integer(settled) and settled >= 0 and settled <= deposit and
      is_boolean(state.close_requested) and
      is_boolean(state.finalized)
  end

  defp escrow_status(%{finalized: true}), do: {:error, Errors.new(:channel_closed, "channel is finalized on-chain")}

  defp escrow_status(%{close_requested: true}),
    do: {:error, Errors.new(:channel_closed, "channel has a pending close request")}

  defp escrow_status(%{deposit: 0}), do: {:error, Errors.new(:channel_not_found, "channel not funded on-chain")}
  defp escrow_status(state), do: {:ok, state}

  defp ensure_open_within_escrow(payload, %{deposit: deposit, settled: settled}) do
    cond do
      payload.cumulative_amount > deposit ->
        {:error, Errors.new(:amount_exceeds_deposit, "voucher amount exceeds open deposit")}

      payload.cumulative_amount < settled ->
        {:error, Errors.new(:verification_failed, "voucher cumulativeAmount is below on-chain settled amount")}

      true ->
        :ok
    end
  end

  defp apply_verified_identity(opts, verified) do
    with {:ok, opts} <- put_verified(opts, :payer, Map.get(verified, :payer)) do
      {:ok, Keyword.put(opts, :verified_signer, Map.get(verified, :authorized_signer))}
    end
  end

  defp put_verified(opts, _key, nil), do: {:ok, opts}

  defp put_verified(opts, key, value) do
    case Keyword.get(opts, key) do
      nil ->
        {:ok, Keyword.put(opts, key, value)}

      configured ->
        if same_address?(configured, value) do
          {:ok, Keyword.put(opts, key, value)}
        else
          {:error, Errors.new(:invalid_payload, "verified channel #{key} does not match server configuration")}
        end
    end
  end

  # Server configuration is authoritative for recipient and token. A
  # descriptor is only honored once it hashes to the channelId under the
  # server's escrow and chain, and it must agree with configured identity.
  defp fetch_open_identity(%Payload{descriptor: nil} = payload, opts) do
    payer = Keyword.get(opts, :payer)

    signer =
      resolve_signer(Keyword.get(opts, :verified_signer), payer) ||
        resolve_signer(Keyword.get(opts, :authorized_signer), payer) || payer

    build_open_identity(payload, payer, Keyword.get(opts, :recipient), Keyword.get(opts, :token), signer)
  end

  defp fetch_open_identity(%Payload{descriptor: descriptor} = payload, opts) do
    with :ok <- ensure_descriptor_binds_channel(payload, opts),
         {:ok, payer} <- configured_or_descriptor(opts, :payer, descriptor.payer),
         {:ok, recipient} <- configured_or_descriptor(opts, :recipient, descriptor.payee),
         {:ok, token} <- configured_or_descriptor(opts, :token, descriptor.token),
         :ok <- ensure_verified_signer(opts, payer, descriptor_signer(descriptor)) do
      build_open_identity(payload, payer, recipient, token, descriptor_signer(descriptor))
    end
  end

  defp ensure_verified_signer(opts, payer, signer) do
    case resolve_signer(Keyword.get(opts, :verified_signer), payer) do
      nil ->
        :ok

      verified ->
        if same_address?(verified, signer),
          do: :ok,
          else: {:error, Errors.new(:signer_mismatch, "descriptor signer does not match the verified channel")}
    end
  end

  defp build_open_identity(payload, payer, recipient, token, signer) do
    cond do
      not (is_binary(payer) and is_binary(recipient) and is_binary(token)) ->
        {:error, :identity_incomplete}

      is_binary(payload.authorized_signer) and
          not same_address?(resolve_signer(payload.authorized_signer, payer), signer) ->
        {:error, Errors.new(:signer_mismatch, "authorizedSigner does not match the channel signer")}

      true ->
        {:ok, %{payer: payer, recipient: recipient, token: token, authorized_signer: signer}}
    end
  end

  defp configured_or_descriptor(opts, key, descriptor_value) do
    case Keyword.get(opts, key) do
      nil ->
        {:ok, descriptor_value}

      configured ->
        if same_address?(configured, descriptor_value) do
          {:ok, configured}
        else
          {:error, Errors.new(:invalid_payload, "channel descriptor #{key} does not match server configuration")}
        end
    end
  end

  defp ensure_descriptor_binds_channel(%Payload{descriptor: descriptor, channel_id: channel_id}, opts) do
    params =
      Map.merge(descriptor, %{
        escrow_contract: Keyword.get(opts, :escrow_contract),
        chain_id: Keyword.get(opts, :chain_id)
      })

    case Channel.compute_id(params) do
      {:ok, ^channel_id} ->
        :ok

      {:ok, _other} ->
        {:error, Errors.new(:invalid_payload, "channel descriptor does not match channelId")}

      {:error, _reason} ->
        {:error,
         Errors.new(
           :invalid_payload,
           "channel descriptor cannot be verified: escrow_contract and chain_id must be configured"
         )}
    end
  end

  # TIP-1034: a zero authorizedSigner delegates signing to the payer, whether it
  # comes from a descriptor, the funding verifier, or server configuration.
  defp descriptor_signer(%{authorized_signer: signer, payer: payer}), do: resolve_signer(signer, payer)

  defp resolve_signer(nil, _payer), do: nil

  defp resolve_signer(signer, payer) do
    if Address.zero?(signer), do: payer, else: signer
  end

  defp same_address?(a, b) when is_binary(a) and is_binary(b), do: a == b or Address.equal?(a, b)
  defp same_address?(_a, _b), do: false

  # A missing payer can still arrive from verify_open. Definitive local
  # identity failures, and a signature that does not recover to a signer
  # already known locally, are rejected before that callback broadcasts.
  defp precheck_local_open(payload, opts) do
    case fetch_open_identity(payload, opts) do
      {:ok, identity} ->
        maybe_verify_signature(payload, identity.authorized_signer, opts)

      {:error, :identity_incomplete} ->
        case local_open_signer(payload, opts) do
          signer when is_binary(signer) -> maybe_verify_signature(payload, signer, opts)
          _signer -> :ok
        end

      {:error, %Errors{}} = error ->
        error
    end
  end

  # The signer `fetch_open_identity/2` would use once the payer arrives.
  # `verified_signer` is not known until after `verify_open`.
  defp local_open_signer(%Payload{descriptor: nil}, opts) do
    resolve_signer(Keyword.get(opts, :authorized_signer), Keyword.get(opts, :payer))
  end

  defp local_open_signer(%Payload{descriptor: descriptor}, _opts), do: descriptor_signer(descriptor)

  defp require_open_identity(payload, opts) do
    case fetch_open_identity(payload, opts) do
      {:error, :identity_incomplete} ->
        {:error, Errors.new(:invalid_payload, "payer, recipient, and token required to open a channel")}

      other ->
        other
    end
  end

  # Checked once against the local signer. Run again only when the escrow names another.
  defp reverify_open_signature(payload, identity, opts) do
    case fetch_open_identity(payload, opts) do
      {:ok, local} ->
        if same_address?(local.authorized_signer, identity.authorized_signer) do
          :ok
        else
          maybe_verify_signature(payload, identity.authorized_signer, opts)
        end

      _other ->
        maybe_verify_signature(payload, identity.authorized_signer, opts)
    end
  end

  defp ensure_voucher_covers_request(%Payload{cumulative_amount: cumulative}, opts) do
    request = request_amount(opts)

    if request > 0 and cumulative < request do
      {:error, Errors.new(:verification_failed, "voucher amount is less than request amount")}
    else
      :ok
    end
  end

  defp ensure_covers_request(_cumulative, _deposit, 0), do: :ok

  defp ensure_covers_request(cumulative, deposit, request_amount) do
    cond do
      deposit < request_amount ->
        {:error, Errors.new(:verification_failed, "open deposit is less than request amount")}

      cumulative < request_amount ->
        {:error, Errors.new(:verification_failed, "voucher amount is less than request amount")}

      true ->
        :ok
    end
  end

  # Custom verifiers receive the channel's resolved signer as :authorized_signer.
  defp maybe_verify_signature(payload, signer, opts) do
    case Keyword.get(opts, :verify_signature, :default) do
      :already_verified -> :ok
      fun when is_function(fun, 2) -> fun.(payload, Keyword.put(opts, :authorized_signer, signer))
      :default -> verify_presented_signature(payload, signer, opts)
    end
  end

  defp verify_presented_signature(%Payload{signature: nil}, _signer, _opts), do: :ok

  defp verify_presented_signature(%Payload{} = payload, signer, opts) do
    escrow = Keyword.get(opts, :escrow_contract)
    chain_id = Keyword.get(opts, :chain_id)

    # Fail closed: a presented signature must be verifiable. Missing EIP-712
    # domain config (escrow_contract / chain_id / authorized_signer) is a
    # caller configuration error, never a reason to skip verification.
    if is_nil(escrow) or is_nil(chain_id) or is_nil(signer) do
      {:error,
       Errors.new(
         :invalid_signature,
         "voucher signature cannot be verified: escrow_contract, chain_id, and authorized_signer must all be configured"
       )}
    else
      verify_voucher_signature(payload, escrow, chain_id, signer)
    end
  end

  defp verify_voucher_signature(payload, escrow, chain_id, signer) do
    case Voucher.new(
           channel_id: payload.channel_id,
           cumulative_amount: payload.cumulative_amount,
           signature: payload.signature
         ) do
      {:ok, voucher} ->
        case Voucher.verify_signature(voucher, escrow, chain_id, signer) do
          :ok ->
            :ok

          {:error, :signature_mismatch} ->
            {:error, Errors.new(:invalid_signature, "invalid voucher signature")}

          {:error, :invalid_expected_signer} ->
            {:error, Errors.new(:signer_mismatch, "recovered signer is not authorized")}

          {:error, _reason} ->
            {:error, Errors.new(:invalid_signature, "invalid voucher signature")}
        end

      {:error, _reason} ->
        {:error, Errors.new(:invalid_signature, "invalid voucher signature")}
    end
  end

  # Wire fields follow mpp-rs `SessionReceipt::to_base_receipt` and mppx
  # `SessionReceipt`. `reference` stays the channel id; `txHash` is separate.
  defp receipt(%Channel{} = channel, opts) do
    Receipt.new(
      method: Keyword.get(opts, :method_name, "session"),
      reference: channel.channel_id,
      extensions:
        %{
          "action" => Channel.action_to_wire(Keyword.fetch!(opts, :action)),
          "intent" => "session",
          "channelId" => channel.channel_id,
          "acceptedCumulative" => Integer.to_string(channel.cumulative_amount),
          "spent" => Integer.to_string(channel.spent),
          "units" => channel.units
        }
        |> maybe_put_extension("challengeId", optional_binary(Keyword.get(opts, :challenge_id)))
        |> maybe_put_extension("txHash", receipt_tx_hash(channel, opts))
    )
  end

  defp receipt_tx_hash(%Channel{proof: %{tx_hash: hash}}, _opts) when is_binary(hash) and hash != "", do: hash
  defp receipt_tx_hash(_channel, opts), do: optional_binary(Keyword.get(opts, :tx_hash))

  defp put_tx_hash(opts, %{tx_hash: hash}) when is_binary(hash) and hash != "", do: Keyword.put(opts, :tx_hash, hash)
  defp put_tx_hash(opts, _verified), do: opts

  defp optional_binary(value) when is_binary(value) and value != "", do: value
  defp optional_binary(_value), do: nil

  defp maybe_put_extension(map, _key, nil), do: map
  defp maybe_put_extension(map, key, value), do: Map.put(map, key, value)

  defp opts_from_session(%Session{} = session) do
    details = session.method_details || %{}

    [
      store: Map.get(details, "session_store", Store.default_store()),
      payer: Map.get(details, "payer"),
      recipient: Map.get(details, "recipient", session.recipient),
      token: Map.get(details, "token", session.currency),
      escrow_contract: Map.get(details, "escrowContract") || Map.get(details, "escrow_contract"),
      chain_id: Map.get(details, "chainId") || Map.get(details, "chain_id"),
      authorized_signer: Map.get(details, "authorizedSigner") || Map.get(details, "authorized_signer"),
      min_voucher_delta: Map.get(details, "minVoucherDelta") || Map.get(details, "min_voucher_delta", 1),
      request_amount: Map.get(details, "request_amount", session.amount),
      method_name: Map.get(details, "method", "session"),
      challenge_id: optional_binary(Map.get(details, "challenge_id") || Map.get(details, "challengeId")),
      verify_open: Map.get(details, "verify_open"),
      verify_top_up: Map.get(details, "verify_top_up"),
      settle_close: Map.get(details, "settle_close")
    ]
  end

  defp store(opts), do: Keyword.get(opts, :store, Store.default_store())

  defp min_voucher_delta(opts) do
    case parse_amount(Keyword.get(opts, :min_voucher_delta, 1)) do
      {:ok, delta} -> delta
      :error -> 1
    end
  end

  defp request_amount(opts) do
    case parse_amount(Keyword.get(opts, :request_amount, 0)) do
      {:ok, amount} -> amount
      :error -> 0
    end
  end

  defp parse_amount(nil), do: :error
  defp parse_amount(amount) when is_integer(amount) and amount >= 0, do: {:ok, amount}

  defp parse_amount(amount) when is_binary(amount) do
    if Regex.match?(~r/\A[0-9]+\z/, amount), do: {:ok, String.to_integer(amount)}, else: :error
  end

  defp parse_amount(_amount), do: :error

  defp payload_error(:invalid_action), do: Errors.new(:invalid_payload, "invalid session credential action")
  defp payload_error(:invalid_payload), do: Errors.new(:invalid_payload, "invalid session credential payload")

  defp payload_error(:invalid_transaction_type),
    do: Errors.new(:invalid_payload, "invalid session credential transaction type")

  defp payload_error(:invalid_descriptor), do: Errors.new(:invalid_payload, "invalid session credential descriptor")

  defp payload_error(:invalid_settlement_route),
    do: Errors.new(:invalid_payload, "invalid session credential settlementRoute")

  defp payload_error({:invalid_channel_id, _value}),
    do: Errors.new(:invalid_payload, "invalid session credential channelId")

  defp payload_error({:invalid_hex, field}), do: Errors.new(:invalid_payload, "invalid session credential #{field}")
  defp payload_error({:invalid_amount, field}), do: Errors.new(:invalid_payload, "invalid session credential #{field}")
  defp payload_error({:invalid_address, field}), do: Errors.new(:invalid_payload, "invalid session credential #{field}")
  defp payload_error({:invalid_hash, field}), do: Errors.new(:invalid_payload, "invalid session credential #{field}")
end
