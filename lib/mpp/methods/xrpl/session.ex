# The shared callback set IS a behaviour (`use MPP.Method`); reach's source frontend
# can't see the macro-injected `@behaviour`, so the candidate smell false-positives.
# reach:disable-next-line behaviour_candidate
defmodule MPP.Methods.XRPL.Session do
  @moduledoc """
  XRPL session verification over native payment channels.

  Implements `draft-xrpl-session-00` at mpp-specs commit `213b098`. Open
  submits a signed `PaymentChannelCreate`, then treats `amount` + `signature`
  as the first claim. Voucher and close are off-ledger claims over the
  cumulative drop total. Channel high-water state is stored through
  `MPP.Session.Actions` / `MPP.Session.Store`.

  Configure `rpc_url` (HTTPS) and `network` (`mainnet` / `testnet` / `devnet`).
  `min_settle_delay` defaults to 3600 seconds; `closing_margin` defaults to
  3600 seconds of ledger close-time. The session store is namespaced by
  network so the same PayChannel ID on two ledgers cannot share a mark.
  """

  use MPP.Method
  use Descripex, namespace: "/methods"

  alias MPP.Errors
  alias MPP.Intents.Session
  alias MPP.Methods.XRPL.Claim
  alias MPP.Methods.XRPL.Codec
  alias MPP.Methods.XRPL.RPC
  alias MPP.Receipt
  alias MPP.Session.Actions
  alias MPP.Session.Channel
  alias MPP.Session.ETSStore
  alias MPP.Session.Payload
  alias MPP.Session.Store

  @public_fields ~w(network)
  @default_settle_delay 3_600
  @default_closing_margin 3_600
  @max_drops 100_000_000_000_000_000

  api(:method_name, "Return the XRPL payment method identifier.")

  @impl MPP.Method
  @spec method_name() :: String.t()
  def method_name, do: "xrpl"

  api(:credential_types, "Session credentials are discriminated by action, not payload.type.")

  @impl MPP.Method
  @spec credential_types() :: [String.t()]
  def credential_types, do: []

  api(:validate_config!, "Validate RPC, network and settle-delay configuration.")

  @impl MPP.Method
  @spec validate_config!(map()) :: :ok
  def validate_config!(config) do
    if not valid_config?(config) do
      raise ArgumentError,
            "XRPL session requires HTTPS rpc_url, network, and positive min_settle_delay / closing_margin"
    end

    :ok
  end

  api(:challenge_method_details, "Expose the draft's public session method details.")

  @impl MPP.Method
  @spec challenge_method_details(Session.t()) :: map()
  def challenge_method_details(%Session{} = session) do
    Map.take(session.method_details || %{}, @public_fields)
  end

  api(:verify, "Verify an XRPL session credential and update the channel store.")

  @impl MPP.Method
  @spec verify(map(), Session.t()) :: {:ok, Receipt.t()} | {:error, Errors.t()}
  def verify(payload, %Session{} = session) when is_map(payload) do
    config = session.method_details || %{}

    with true <- valid_config?(config),
         true <- valid_session?(session),
         {:ok, parsed} <- parse(payload),
         :ok <- source(config) do
      dispatch(parsed, session, config)
    else
      {:error, %Errors{} = error} -> {:error, error}
      _ -> failed()
    end
  end

  def verify(_payload, _intent),
    do: {:error, Errors.new(:invalid_payload, "XRPL session method requires a session intent")}

  defp dispatch({:open, blob, amount, signature}, session, config) do
    with {:ok, tx} <- create_fields(blob, session, config),
         {:ok, channel_id} <- predicted_id(tx),
         :ok <- unused_channel(channel_id, config),
         :ok <- RPC.check_network(config),
         {:ok, hash} <- RPC.submit_blob(blob, config),
         {:ok, result} <- RPC.await_validated(hash, config),
         :ok <- created?(result, hash, channel_id),
         {:ok, channel} <- ledger_channel(channel_id, config),
         :ok <- channel_state(channel, channel_id, amount, session, config, signature) do
      apply_action(:open, channel_id, amount, deposit(channel), config, session, %{"txHash" => hash})
    end
  end

  defp dispatch({action, channel_id, amount, signature}, session, config) when action in [:voucher, :close] do
    with :ok <- RPC.check_network(config),
         {:ok, channel} <- ledger_channel(channel_id, config),
         :ok <- channel_state(channel, channel_id, amount, session, config, signature) do
      apply_action(action, channel_id, amount, deposit(channel), config, session, %{})
    end
  end

  defp apply_action(action, channel_id, amount, deposit, config, session, extra) do
    payload = %Payload{action: action, channel_id: channel_id, cumulative_amount: amount, signature: nil}

    with {:ok, receipt} <- Actions.handle(payload, action_opts(action, channel_id, deposit, config, session)) do
      finish_receipt(receipt, channel_id, extra)
    end
  end

  defp create_fields(blob, session, config) do
    with {:ok, tx} <- Codec.decode_create(blob),
         true <- Codec.signed?(tx),
         true <- is_integer(tx["LastLedgerSequence"]) and tx["LastLedgerSequence"] > 0,
         true <- is_integer(tx["Sequence"]) or is_integer(tx["TicketSequence"]),
         true <- Codec.address?(tx["Account"]) and tx["Destination"] == session.recipient,
         true <- source_matches?(tx["Account"], config),
         {:ok, deposit} <- drops(tx["Amount"]),
         true <- deposit > 0,
         true <- is_integer(tx["SettleDelay"]) and tx["SettleDelay"] >= min_settle_delay(config),
         true <- is_binary(tx["PublicKey"]) and RPC.hex?(tx["PublicKey"], 66) do
      {:ok, tx}
    else
      _ -> failed()
    end
  end

  defp predicted_id(tx) do
    sequence = tx["TicketSequence"] || tx["Sequence"]
    Channel.compute_xrpl_id(tx["Account"], tx["Destination"], sequence)
  end

  defp unused_channel(channel_id, config) do
    case Store.get(store(config), channel_id) do
      :not_found -> :ok
      {:ok, %Channel{status: :closed}} -> {:error, Errors.new(:channel_closed, "channel is closed")}
      {:ok, _} -> {:error, Errors.new(:invalid_payload, "channel already exists")}
      _ -> failed()
    end
  end

  defp created?(result, hash, channel_id) do
    meta = Map.get(result, "meta", %{})
    nodes = Map.get(meta, "AffectedNodes", [])

    with {:ok, wire_id} <- Channel.to_xrpl_id(channel_id),
         true <- result["validated"] == true,
         true <- meta["TransactionResult"] == "tesSUCCESS",
         true <- is_integer(result["ledger_index"]) and result["ledger_index"] > 0,
         true <- is_binary(result["hash"]) and String.upcase(result["hash"]) == hash,
         true <- created_channel?(nodes, wire_id) do
      :ok
    else
      _ -> failed()
    end
  end

  defp created_channel?(nodes, wire_id) when is_list(nodes) do
    Enum.any?(nodes, fn
      %{"CreatedNode" => %{"LedgerEntryType" => "PayChannel", "LedgerIndex" => index}} ->
        is_binary(index) and String.upcase(index) == wire_id

      _ ->
        false
    end)
  end

  defp created_channel?(_nodes, _wire_id), do: false

  defp ledger_channel(channel_id, config) do
    with {:ok, wire_id} <- Channel.to_xrpl_id(channel_id),
         {:ok, result} <- RPC.call(config, "ledger_entry", %{"index" => wire_id, "ledger_index" => "validated"}) do
      case result do
        %{"node" => %{"LedgerEntryType" => "PayChannel"} = node} -> {:ok, node}
        %{"error" => "entryNotFound"} -> {:error, Errors.new(:channel_not_found, "channel not found")}
        _ -> failed()
      end
    else
      {:error, {:invalid_channel_id, _}} -> malformed()
      _ -> failed()
    end
  end

  defp channel_state(node, channel_id, amount, session, config, signature) do
    with {:ok, deposit} <- drops(node["Amount"]),
         {:ok, balance} <- drops(node["Balance"]),
         true <- node["Destination"] == session.recipient,
         true <- source_matches?(node["Account"], config),
         true <- is_integer(node["SettleDelay"]) and node["SettleDelay"] >= min_settle_delay(config),
         :ok <- closing_window(node, config),
         :ok <- claim_bounds(amount, balance, deposit),
         :ok <- Claim.verify(channel_id, amount, signature, node["PublicKey"]) do
      :ok
    else
      {:error, %Errors{} = error} -> {:error, error}
      {:error, :invalid_signature} -> {:error, Errors.new(:invalid_signature, "invalid claim signature")}
      _ -> failed()
    end
  end

  defp claim_bounds(amount, _balance, deposit) when amount > deposit do
    {:error, Errors.new(:amount_exceeds_deposit, "claim exceeds channel deposit")}
  end

  defp claim_bounds(amount, balance, _deposit) when amount > balance, do: :ok
  defp claim_bounds(_amount, _balance, _deposit), do: failed()

  defp closing_window(node, config) do
    case RPC.call(config, "ledger", %{"ledger_index" => "validated"}) do
      {:ok, %{"ledger" => %{"close_time" => close_time}}} when is_integer(close_time) ->
        margin = closing_margin(config)

        if expired?(node["Expiration"], close_time, margin) or expired?(node["CancelAfter"], close_time, margin) do
          {:error, Errors.new(:channel_closed, "channel is inside the settlement margin or expired")}
        else
          :ok
        end

      _ ->
        failed()
    end
  end

  defp expired?(nil, _close_time, _margin), do: false
  defp expired?(deadline, close_time, margin) when is_integer(deadline), do: deadline <= close_time + margin
  defp expired?(_deadline, _close_time, _margin), do: true

  defp action_opts(action, _channel_id, deposit, config, session) do
    request = request_amount(session)

    [
      store: store(config),
      deposit: deposit,
      payer: payer(config),
      recipient: session.recipient,
      token: "XRP",
      request_amount: if(action == :close, do: 0, else: request),
      min_voucher_delta: request,
      verify_signature: :already_verified,
      method_name: "xrpl"
    ]
  end

  defp finish_receipt(receipt, channel_id, extra) do
    {:ok, wire_id} = Channel.to_xrpl_id(channel_id)
    cumulative = receipt.extensions["acceptedCumulative"]

    {:ok,
     %{
       receipt
       | method: "xrpl",
         reference: wire_id,
         extensions:
           receipt.extensions
           |> Map.put("channelId", wire_id)
           |> Map.put("cumulative", cumulative)
           |> Map.merge(extra)
     }}
  end

  defp parse(%{"action" => "open", "transaction" => transaction, "amount" => amount, "signature" => signature}) do
    with {:ok, blob} <- blob(transaction),
         {:ok, drops} <- drops(amount),
         {:ok, signature} <- signature(signature) do
      {:ok, {:open, blob, drops, signature}}
    else
      _ -> malformed()
    end
  end

  defp parse(%{"action" => action, "channelId" => channel_id, "amount" => amount, "signature" => signature})
       when action in ["voucher", "close"] do
    with {:ok, channel_id} <- Channel.normalize_id(channel_id),
         {:ok, drops} <- drops(amount),
         {:ok, signature} <- signature(signature) do
      {:ok, {if(action == "voucher", do: :voucher, else: :close), channel_id, drops, signature}}
    else
      _ -> malformed()
    end
  end

  defp parse(_), do: malformed()

  defp blob(value) when is_binary(value) do
    stripped = strip_hex(value)
    size = byte_size(stripped)

    if size in 2..131_072 and rem(size, 2) == 0 and RPC.hex?(stripped, size) do
      {:ok, String.upcase(stripped)}
    else
      :error
    end
  end

  defp blob(_), do: :error

  defp signature(value) when is_binary(value) do
    stripped = strip_hex(value)
    size = byte_size(stripped)

    if size in 128..200 and rem(size, 2) == 0 and RPC.hex?(stripped, size) do
      {:ok, String.upcase(stripped)}
    else
      :error
    end
  end

  defp signature(_), do: :error

  defp drops(value) when is_binary(value) do
    if Regex.match?(~r/\A(?:0|[1-9]\d*)\z/, value) do
      amount = String.to_integer(value)
      if amount <= @max_drops, do: {:ok, amount}, else: :error
    else
      :error
    end
  end

  defp drops(value) when is_integer(value) and value >= 0 and value <= @max_drops, do: {:ok, value}
  defp drops(_), do: :error

  defp valid_session?(%Session{currency: currency, recipient: recipient, amount: amount}) do
    currency in [nil, "XRP"] and Codec.address?(recipient) and match?({:ok, value} when value > 0, drops(amount))
  end

  defp valid_config?(config) do
    is_map(config) and RPC.valid_url?(config["rpc_url"]) and Map.has_key?(RPC.networks(), config["network"]) and
      positive_int?(min_settle_delay(config)) and positive_int?(closing_margin(config))
  end

  defp source(config) do
    prefix = "did:pkh:xrpl:#{RPC.networks()[config["network"]]}:"

    case config["credential_source"] do
      source when is_binary(source) ->
        if String.starts_with?(source, prefix) and Codec.address?(String.replace_prefix(source, prefix, "")),
          do: :ok,
          else: failed()

      _ ->
        failed()
    end
  end

  defp source_matches?(account, config) do
    is_binary(account) and config["credential_source"] == "did:pkh:xrpl:#{RPC.networks()[config["network"]]}:#{account}"
  end

  defp store(config) do
    case Map.get(config, "session_store", Store.default_store()) do
      {ETSStore, opts} when is_list(opts) -> {ETSStore, Keyword.put(opts, :network, config["network"])}
      other -> other
    end
  end

  defp payer(config) do
    prefix = "did:pkh:xrpl:#{RPC.networks()[config["network"]]}:"
    String.replace_prefix(config["credential_source"], prefix, "")
  end

  defp request_amount(session) do
    {:ok, amount} = drops(session.amount)
    amount
  end

  defp deposit(node) do
    {:ok, amount} = drops(node["Amount"])
    amount
  end

  defp min_settle_delay(config), do: Map.get(config, "min_settle_delay", @default_settle_delay)
  defp closing_margin(config), do: Map.get(config, "closing_margin", @default_closing_margin)
  defp positive_int?(value), do: is_integer(value) and value > 0
  defp strip_hex("0x" <> rest), do: rest
  defp strip_hex("0X" <> rest), do: rest
  defp strip_hex(value), do: value
  defp failed, do: {:error, Errors.new(:verification_failed, "XRPL session verification failed")}
  defp malformed, do: {:error, Errors.new(:malformed_credential, "Malformed XRPL session credential")}
end
