defmodule MPP.Session.Actions do
  @moduledoc """
  Server-side session credential action handlers.

  Dispatches on `credential.payload.action` to `open`, `voucher`, `top_up`,
  and `close`. Each handler updates per-channel deposit / voucher /
  spend balances through `MPP.Session.Store`.

  `topUp` requires a funding verifier, passed as the `:verify_top_up` option
  or the server-only `"verify_top_up"` method-config key. It is called as
  `verify.(payload, channel, opts)`, must confirm the top-up transaction
  on-chain, and returns `{:ok, total_deposit}` with the escrow's confirmed
  channel deposit (or `{:error, %MPP.Errors{}}`). The channel ceiling becomes
  that total; the payload's `additionalDeposit` is never trusted. Without a
  verifier every `topUp` is rejected.

  The voucher signer is fixed at `open` and stored on the channel. It is the
  descriptor's `authorizedSigner` (the payer when that is the zero address)
  once the descriptor hashes to `channelId` under the configured
  `escrow_contract` and `chain_id`; otherwise the configured
  `:authorized_signer`, falling back to the payer. A descriptor's payee and
  token must match the configured recipient and token. A credential's
  top-level `authorizedSigner` must equal that signer. Vouchers and closes are
  verified against the stored signer only.
  """

  alias MPP.Errors
  alias MPP.Intents.Session
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

  @doc "Apply a parsed session payload to the channel store."
  @spec handle(Payload.t(), opts()) :: {:ok, Receipt.t()} | {:error, Errors.t()}
  def handle(%Payload{action: :open} = payload, opts), do: handle_open(payload, opts)
  def handle(%Payload{action: :top_up} = payload, opts), do: handle_top_up(payload, opts)
  def handle(%Payload{action: :voucher} = payload, opts), do: handle_voucher(payload, opts)
  def handle(%Payload{action: :close} = payload, opts), do: handle_close(payload, opts)

  defp handle_open(payload, opts) do
    with {:ok, deposit} <- fetch_open_deposit(payload, opts),
         :ok <- ensure_covers_request(payload.cumulative_amount, deposit, request_amount(opts)),
         {:ok, identity} <- fetch_open_identity(payload, opts),
         :ok <- maybe_verify_signature(payload, identity.authorized_signer, opts) do
      update_channel(payload, opts, fn
        :not_found ->
          open_channel(payload, identity, deposit, opts)

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
         {:ok, deposit} <- verify_top_up(payload, current, opts) do
      update_channel(payload, opts, fn
        :not_found ->
          {:error, Errors.new(:channel_not_found, "channel not found")}

        %Channel{status: :closed} ->
          {:error, Errors.new(:channel_closed, "channel is closed")}

        %Channel{} = channel ->
          Channel.apply_verified_deposit(channel, deposit)
      end)
    end
  end

  defp fetch_live_channel(payload, opts) do
    case Store.get(store(opts), payload.channel_id) do
      {:ok, %Channel{status: :closed}} -> {:error, Errors.new(:channel_closed, "channel is closed")}
      {:ok, %Channel{} = channel} -> {:ok, channel}
      :not_found -> {:error, Errors.new(:channel_not_found, "channel not found")}
      {:error, reason} -> {:error, store_error(reason)}
    end
  end

  defp require_positive_top_up(%Payload{additional_deposit: amount}) when is_integer(amount) and amount > 0, do: :ok
  defp require_positive_top_up(_payload), do: {:error, store_error({:invalid_amount, :additional_deposit})}

  # The claimed additionalDeposit is never trusted: the deposit ceiling only
  # moves to the escrow total the configured verifier confirms on-chain.
  defp verify_top_up(payload, channel, opts) do
    case Keyword.get(opts, :verify_top_up) do
      fun when is_function(fun, 3) ->
        case fun.(payload, channel, opts) do
          {:ok, deposit} when is_integer(deposit) and deposit >= 0 -> {:ok, deposit}
          {:error, %Errors{} = error} -> {:error, error}
          other -> {:error, Errors.new(:verification_failed, "topUp funding verification failed: #{inspect(other)}")}
        end

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

  defp handle_close(payload, opts) do
    with_channel_signer(payload, opts, &close_channel/3)
  end

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
        signer = channel_signer(channel, opts)

        with :ok <- ensure_same_descriptor(payload, signer, opts),
             :ok <- maybe_verify_signature(payload, signer, opts) do
          apply_fun.(channel, payload, opts)
        end
    end)
  end

  defp channel_signer(%Channel{authorized_signer: signer}, _opts) when is_binary(signer), do: signer
  defp channel_signer(%Channel{}, opts), do: Keyword.get(opts, :authorized_signer)

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

  defp open_channel(payload, identity, deposit, opts) do
    with {:ok, channel} <-
           Channel.new(
             channel_id: payload.channel_id,
             payer: identity.payer,
             recipient: identity.recipient,
             token: identity.token,
             authorized_signer: identity.authorized_signer,
             deposit: deposit,
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

  defp settlement_proof(%Payload{signature: signature, cumulative_amount: amount}, opts)
       when is_binary(signature) and signature != "" do
    case Keyword.get(opts, :proof) do
      %{public_key: key} when is_binary(key) and key != "" ->
        Channel.new_proof(amount, signature, key)

      _ ->
        nil
    end
  end

  defp settlement_proof(_payload, _opts), do: nil

  defp maybe_spend(channel, 0), do: {:ok, channel}
  defp maybe_spend(channel, amount), do: Channel.apply_spend(channel, amount)

  defp update_channel(%Payload{} = payload, opts, fun) do
    opts = Keyword.put(opts, :action, payload.action)

    case Store.update(store(opts), payload.channel_id, &normalize_update(fun.(&1))) do
      {:ok, channel} -> {:ok, receipt(channel, opts)}
      {:error, reason} -> {:error, store_error(reason)}
    end
  end

  defp store_error(%Errors{} = error), do: error
  defp store_error(:insufficient_balance), do: Errors.new(:insufficient_balance, "insufficient channel balance")
  defp store_error(:amount_exceeds_deposit), do: Errors.new(:amount_exceeds_deposit, "amount exceeds channel deposit")

  defp store_error(:deposit_not_increased),
    do: Errors.new(:verification_failed, "channel deposit did not increase after topUp")

  defp store_error({:invalid_transition, status, _to}) do
    Errors.new(:invalid_payload, "invalid channel transition from #{status}")
  end

  defp store_error({:invalid_amount, field}), do: Errors.new(:invalid_payload, "invalid #{field}")
  defp store_error(reason), do: Errors.new(:verification_failed, "session store update failed: #{inspect(reason)}")

  defp normalize_update({:ok, %Channel{}} = ok), do: ok
  defp normalize_update({:error, _reason} = error), do: error
  defp normalize_update(other), do: {:error, {:invalid_update_result, other}}

  defp fetch_open_deposit(payload, opts) do
    case parse_amount(Keyword.get(opts, :deposit)) do
      {:ok, deposit} when deposit >= payload.cumulative_amount ->
        {:ok, deposit}

      {:ok, _deposit} ->
        {:error, Errors.new(:amount_exceeds_deposit, "voucher amount exceeds open deposit")}

      :error ->
        {:error, Errors.new(:invalid_payload, "deposit required for open action")}
    end
  end

  # Server configuration is authoritative for recipient and token. A
  # descriptor is only honored once it hashes to the channelId under the
  # server's escrow and chain, and it must agree with configured identity.
  defp fetch_open_identity(%Payload{descriptor: nil} = payload, opts) do
    payer = Keyword.get(opts, :payer)
    signer = Keyword.get(opts, :authorized_signer) || payer

    build_open_identity(payload, payer, Keyword.get(opts, :recipient), Keyword.get(opts, :token), signer)
  end

  defp fetch_open_identity(%Payload{descriptor: descriptor} = payload, opts) do
    with :ok <- ensure_descriptor_binds_channel(payload, opts),
         {:ok, payer} <- configured_or_descriptor(opts, :payer, descriptor.payer),
         {:ok, recipient} <- configured_or_descriptor(opts, :recipient, descriptor.payee),
         {:ok, token} <- configured_or_descriptor(opts, :token, descriptor.token) do
      build_open_identity(payload, payer, recipient, token, descriptor_signer(descriptor))
    end
  end

  defp build_open_identity(payload, payer, recipient, token, signer) do
    cond do
      not (is_binary(payer) and is_binary(recipient) and is_binary(token)) ->
        {:error, Errors.new(:invalid_payload, "payer, recipient, and token required to open a channel")}

      is_binary(payload.authorized_signer) and not same_address?(payload.authorized_signer, signer) ->
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

  # TIP-1034: a zero authorizedSigner delegates signing to the payer.
  defp descriptor_signer(%{authorized_signer: signer, payer: payer}) do
    if Address.zero?(signer), do: payer, else: signer
  end

  defp same_address?(a, b) when is_binary(a) and is_binary(b), do: a == b or Address.equal?(a, b)
  defp same_address?(_a, _b), do: false

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

  defp receipt(%Channel{} = channel, opts) do
    Receipt.new(
      method: Keyword.get(opts, :method_name, "session"),
      reference: channel.channel_id,
      extensions: %{
        "action" => Channel.action_to_wire(Keyword.fetch!(opts, :action)),
        "channelId" => channel.channel_id,
        "acceptedCumulative" => Integer.to_string(channel.cumulative_amount),
        "spent" => Integer.to_string(channel.spent),
        "units" => channel.units
      }
    )
  end

  defp opts_from_session(%Session{} = session) do
    details = session.method_details || %{}

    [
      store: Map.get(details, "session_store", Store.default_store()),
      deposit: Map.get(details, "deposit", session.suggested_deposit),
      payer: Map.get(details, "payer"),
      recipient: Map.get(details, "recipient", session.recipient),
      token: Map.get(details, "token", session.currency),
      escrow_contract: Map.get(details, "escrowContract") || Map.get(details, "escrow_contract"),
      chain_id: Map.get(details, "chainId") || Map.get(details, "chain_id"),
      authorized_signer: Map.get(details, "authorizedSigner") || Map.get(details, "authorized_signer"),
      min_voucher_delta: Map.get(details, "minVoucherDelta") || Map.get(details, "min_voucher_delta", 1),
      request_amount: Map.get(details, "request_amount", session.amount),
      method_name: Map.get(details, "method", "session"),
      verify_top_up: Map.get(details, "verify_top_up")
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
