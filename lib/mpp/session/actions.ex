defmodule MPP.Session.Actions do
  @moduledoc """
  Server-side session credential action handlers.

  Dispatches on `credential.payload.action` to `open`, `voucher`, `top_up`,
  and `close`. Each handler updates per-channel deposit / voucher /
  spend balances through `MPP.Session.Store`.
  """

  alias MPP.Errors
  alias MPP.Intents.Session
  alias MPP.Receipt
  alias MPP.Session.Channel
  alias MPP.Session.Payload
  alias MPP.Session.Store
  alias MPP.Session.Voucher

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
         :ok <- maybe_verify_signature(payload, opts),
         {:ok, identity} <- fetch_open_identity(payload, opts) do
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
    update_channel(payload, opts, fn
      :not_found ->
        {:error, Errors.new(:channel_not_found, "channel not found")}

      %Channel{status: :closed} ->
        {:error, Errors.new(:channel_closed, "channel is closed")}

      %Channel{} = channel ->
        Channel.apply_top_up(channel, payload.additional_deposit)
    end)
  end

  defp handle_voucher(payload, opts) do
    with :ok <- maybe_verify_signature(payload, opts) do
      update_channel(payload, opts, fn
        :not_found ->
          {:error, Errors.new(:channel_not_found, "channel not found")}

        %Channel{status: :closed} ->
          {:error, Errors.new(:channel_closed, "channel is closed")}

        %Channel{} = channel ->
          accept_voucher(channel, payload, opts)
      end)
    end
  end

  defp handle_close(payload, opts) do
    with :ok <- maybe_verify_signature(payload, opts) do
      update_channel(payload, opts, fn
        :not_found ->
          {:error, Errors.new(:channel_not_found, "channel not found")}

        %Channel{status: :closed} ->
          {:error, Errors.new(:channel_closed, "channel is closed")}

        %Channel{} = channel ->
          close_channel(channel, payload)
      end)
    end
  end

  defp open_channel(payload, identity, deposit, opts) do
    with {:ok, channel} <-
           Channel.new(
             channel_id: payload.channel_id,
             payer: identity.payer,
             recipient: identity.recipient,
             token: identity.token,
             deposit: deposit,
             cumulative_amount: payload.cumulative_amount
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
        {:ok, channel}

      payload.cumulative_amount < channel.cumulative_amount ->
        {:error, Errors.new(:invalid_payload, "voucher cumulativeAmount is not monotonic")}

      delta < min_delta ->
        {:error, Errors.new(:delta_too_small, "voucher delta #{delta} below minimum #{min_delta}")}

      true ->
        with {:ok, channel} <- Channel.apply_voucher(channel, payload.cumulative_amount) do
          maybe_spend(channel, request_amount(opts))
        end
    end
  end

  defp close_channel(channel, payload) do
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
        with {:ok, channel} <- Channel.apply_voucher(channel, payload.cumulative_amount) do
          Channel.close(channel)
        end

      true ->
        Channel.close(channel)
    end
  end

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

  defp fetch_open_identity(payload, opts) do
    payer = identity_value(payload, opts, :payer, :payer)
    recipient = identity_value(payload, opts, :payee, :recipient)
    token = identity_value(payload, opts, :token, :token)

    if is_binary(payer) and is_binary(recipient) and is_binary(token) do
      {:ok, %{payer: payer, recipient: recipient, token: token}}
    else
      {:error, Errors.new(:invalid_payload, "payer, recipient, and token required to open a channel")}
    end
  end

  defp identity_value(%Payload{descriptor: %{payer: payer}}, opts, :payer, :payer) do
    payer || Keyword.get(opts, :payer)
  end

  defp identity_value(%Payload{descriptor: %{payee: payee}}, opts, :payee, :recipient) do
    payee || Keyword.get(opts, :recipient)
  end

  defp identity_value(%Payload{descriptor: %{token: token}}, opts, :token, :token) do
    token || Keyword.get(opts, :token)
  end

  defp identity_value(_payload, opts, _descriptor_key, opt_key), do: Keyword.get(opts, opt_key)

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

  defp maybe_verify_signature(%Payload{signature: nil}, _opts), do: :ok

  defp maybe_verify_signature(%Payload{} = payload, opts) do
    escrow = Keyword.get(opts, :escrow_contract)
    chain_id = Keyword.get(opts, :chain_id)
    signer = signature_signer(payload, opts)

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

  defp signature_signer(%Payload{authorized_signer: signer}, _opts) when is_binary(signer), do: signer

  defp signature_signer(%Payload{descriptor: %{authorized_signer: signer}}, _opts) when is_binary(signer), do: signer

  defp signature_signer(_payload, opts), do: Keyword.get(opts, :authorized_signer)

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
      request_amount: session.amount,
      method_name: Map.get(details, "method", "session")
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
