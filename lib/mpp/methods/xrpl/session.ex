# The shared callback set IS a behaviour (`use MPP.Method`); reach's source frontend
# can't see the macro-injected `@behaviour`, so the candidate smell false-positives.
# reach:disable-next-line behaviour_candidate
defmodule MPP.Methods.XRPL.Session do
  @moduledoc """
  XRPL session verification over native payment channels.

  Implements `draft-xrpl-session-00` at mpp-specs commit `213b098`. Open
  submits a signed `PaymentChannelCreate`, then treats `amount` + `signature`
  as the first claim. Voucher and close are off-ledger claims over the
  cumulative drop total. The highest accepted claim (cumulative, signature,
  ledger PublicKey) is retained on `MPP.Session.Channel.proof`.

  Close submits `PaymentChannelClaim` with `tfClose` unless
  `defer_redemption` is true, in which case `redeem/2` submits later.
  The Destination (server) pays the claim transaction Fee from its own
  XRP; set `destination_secret` to that account's family seed.

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
  alias MPP.Methods.XRPL.Wallet
  alias MPP.Receipt
  alias MPP.Session.Actions
  alias MPP.Session.Channel
  alias MPP.Session.ETSStore
  alias MPP.Session.Payload
  alias MPP.Session.Store

  @public_fields ~w(network)
  @default_settle_delay 3_600
  @default_closing_margin 3_600
  @default_fee "12"
  @last_ledger_offset 20
  # xrpl.org PaymentChannelClaim Flags: tfClose = 0x00020000
  @tf_close 131_072
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
            "XRPL session requires HTTPS rpc_url, network, positive min_settle_delay / closing_margin, and destination_secret or defer_redemption"
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
         {:ok, result} <- RPC.await_validated(hash, config, submitted: true),
         :ok <- created?(result, hash, channel_id),
         {:ok, channel} <- ledger_channel(channel_id, config),
         :ok <- channel_state(channel, channel_id, amount, session, config, signature) do
      apply_action(%{
        action: :open,
        channel_id: channel_id,
        amount: amount,
        deposit: deposit(channel),
        config: config,
        session: session,
        signature: signature,
        public_key: channel_public_key(channel),
        extra: %{"txHash" => hash}
      })
    else
      {:error, %Errors{} = error} -> {:error, error}
      _ -> failed()
    end
  end

  defp dispatch({action, channel_id, amount, signature}, session, config) when action in [:voucher, :close] do
    with {:ok, channel} <- ledger_channel(channel_id, config),
         :ok <- channel_state(channel, channel_id, amount, session, config, signature),
         :ok <- RPC.check_network(config),
         :ok <- settlement_ready?(action, config) do
      apply_action(%{
        action: action,
        channel_id: channel_id,
        amount: amount,
        deposit: deposit(channel),
        config: config,
        session: session,
        signature: signature,
        public_key: channel_public_key(channel),
        extra: %{}
      })
    else
      {:error, %Errors{} = error} -> {:error, error}
      _ -> failed()
    end
  end

  api(:redeem, "Submit the stored highest PaymentChannelClaim for a channel.")

  @doc """
  Submit the highest retained claim as `PaymentChannelClaim`.

  Used automatically on `close` unless `defer_redemption` is true. The
  Destination pays the transaction Fee from its XRP balance.
  """
  @spec redeem(String.t(), map()) :: {:ok, String.t()} | {:error, Errors.t()}
  def redeem(channel_id, config) when is_binary(channel_id) and is_map(config) do
    with {:ok, id} <- Channel.normalize_id(channel_id),
         {:ok, channel} <- stored_channel(id, config) do
      redeem_channel(channel, config)
    else
      {:error, %Errors{} = error} -> {:error, error}
      {:error, {:invalid_channel_id, _}} -> malformed()
    end
  end

  def redeem(_channel_id, _config), do: failed()

  defp apply_action(params) do
    payload = %Payload{
      action: params.action,
      channel_id: params.channel_id,
      cumulative_amount: params.amount,
      signature: params.signature
    }

    with {:ok, receipt} <- Actions.handle(payload, action_opts(params)),
         {:ok, extra} <- maybe_redeem(params.action, params.channel_id, params.extra, params.config) do
      finish_receipt(receipt, params.channel_id, extra)
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
    with :ok <- Claim.verify(channel_id, amount, signature, node["PublicKey"]),
         {:ok, deposit} <- drops(node["Amount"]),
         {:ok, balance} <- drops(node["Balance"]),
         true <- node["Destination"] == session.recipient,
         true <- source_matches?(node["Account"], config),
         true <- is_integer(node["SettleDelay"]) and node["SettleDelay"] >= min_settle_delay(config),
         :ok <- claim_bounds(amount, balance, deposit),
         :ok <- closing_window(node, config) do
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
      {:ok, %{"ledger_index" => index, "ledger" => %{"close_time" => close_time}}}
      when is_integer(close_time) and is_integer(index) ->
        check_closing_window(node, close_time, closing_margin(config))

      {:ok, %{"ledger" => %{"close_time" => close_time}}} when is_integer(close_time) ->
        check_closing_window(node, close_time, closing_margin(config))

      _ ->
        failed()
    end
  end

  defp check_closing_window(node, close_time, margin) do
    if expired?(node["Expiration"], close_time, margin) or expired?(node["CancelAfter"], close_time, margin) do
      {:error, Errors.new(:channel_closed, "channel is inside the settlement margin or expired")}
    else
      :ok
    end
  end

  defp expired?(nil, _close_time, _margin), do: false
  defp expired?(deadline, close_time, margin) when is_integer(deadline), do: deadline <= close_time + margin
  defp expired?(_deadline, _close_time, _margin), do: true

  defp action_opts(params) do
    request = request_amount(params.session)

    [
      store: store(params.config),
      deposit: params.deposit,
      payer: payer(params.config),
      recipient: params.session.recipient,
      token: "XRP",
      request_amount: if(params.action == :close, do: 0, else: request),
      min_voucher_delta: request,
      verify_signature: :already_verified,
      method_name: "xrpl",
      proof: %{public_key: params.public_key}
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

  defp drops(value) when is_binary(value) and byte_size(value) <= 18 do
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
      positive_int?(min_settle_delay(config)) and positive_int?(closing_margin(config)) and
      settlement_config?(config)
  end

  defp settlement_config?(config) do
    config["defer_redemption"] == true or match?({:ok, _}, Wallet.from_seed(config["destination_secret"]))
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
      ETSStore -> {ETSStore, [network: config["network"]]}
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

  defp channel_public_key(%{"PublicKey" => key}) when is_binary(key), do: String.upcase(strip_hex(key))
  defp channel_public_key(_node), do: ""

  defp deferred?(config), do: config["defer_redemption"] == true

  defp settlement_ready?(:close, config) do
    if deferred?(config) or match?({:ok, _}, Wallet.from_seed(config["destination_secret"])) do
      :ok
    else
      failed()
    end
  end

  defp settlement_ready?(_action, _config), do: :ok

  defp maybe_redeem(:close, channel_id, extra, config) do
    if deferred?(config) do
      {:ok, extra}
    else
      case redeem(channel_id, config) do
        {:ok, hash} -> {:ok, Map.put(extra, "txHash", hash)}
        {:error, %Errors{}} -> {:error, settlement_failed()}
      end
    end
  end

  defp maybe_redeem(_action, _channel_id, extra, _config), do: {:ok, extra}

  defp stored_channel(channel_id, config) do
    case Store.get(store(config), channel_id) do
      {:ok, %Channel{} = channel} -> {:ok, channel}
      :not_found -> {:error, Errors.new(:channel_not_found, "channel not found")}
      _ -> failed()
    end
  end

  defp redeem_channel(channel, config) do
    with {:ok, proof} <- stored_proof(channel),
         {:ok, wallet} <- destination_wallet(config, channel),
         {:ok, sequence} <- account_sequence(wallet.address, config),
         {:ok, last_ledger} <- last_ledger_sequence(config),
         {:ok, tx} <- claim_transaction(channel, proof, wallet, sequence, last_ledger, config),
         {:ok, blob, hash} <- Wallet.sign_claim(wallet, tx),
         {:ok, ^hash} <- submit_claim(blob, hash, config),
         {:ok, result} <- RPC.await_validated(hash, config, submitted: true),
         :ok <- claimed?(result, hash, channel, proof),
         :ok <- confirm_ledger(channel.channel_id, proof.amount, config) do
      {:ok, hash}
    else
      {:error, %Errors{} = error} -> {:error, error}
      _ -> {:error, Errors.new(:settlement_failed, "XRPL PaymentChannelClaim settlement failed")}
    end
  end

  defp submit_claim(blob, hash, config) do
    case RPC.call(config, "submit", %{"tx_blob" => blob}) do
      {:ok, result} ->
        reported = get_in(result, ["tx_json", "hash"])
        engine = result["engine_result"]

        cond do
          engine in ["tesSUCCESS", "terQUEUED"] and is_binary(reported) and RPC.hex?(reported, 64) and
              String.upcase(reported) == hash ->
            {:ok, hash}

          is_binary(engine) ->
            {:error, Errors.new(:settlement_failed, "XRPL PaymentChannelClaim #{engine}")}

          true ->
            {:error, Errors.new(:settlement_failed, "XRPL PaymentChannelClaim submit failed")}
        end

      _ ->
        {:error, Errors.new(:settlement_failed, "XRPL PaymentChannelClaim submit failed")}
    end
  end

  defp stored_proof(%Channel{proof: %{amount: amount, signature: signature, public_key: key} = proof})
       when is_integer(amount) and amount > 0 and is_binary(signature) and is_binary(key) do
    {:ok, proof}
  end

  defp stored_proof(_channel), do: {:error, Errors.new(:settlement_failed, "no retained claim to redeem")}

  defp destination_wallet(config, channel) do
    case Wallet.from_seed(config["destination_secret"]) do
      {:ok, wallet} ->
        if wallet.address == channel.recipient, do: {:ok, wallet}, else: failed()

      :error ->
        failed()
    end
  end

  defp account_sequence(address, config) do
    case RPC.call(config, "account_info", %{"account" => address, "ledger_index" => "validated"}) do
      {:ok, %{"account_data" => %{"Sequence" => sequence}}} when is_integer(sequence) and sequence >= 0 ->
        {:ok, sequence}

      _ ->
        :error
    end
  end

  defp last_ledger_sequence(config) do
    case RPC.call(config, "ledger", %{"ledger_index" => "validated"}) do
      {:ok, result} ->
        case ledger_index(result) do
          {:ok, index} -> {:ok, index + @last_ledger_offset}
          :error -> :error
        end

      _ ->
        :error
    end
  end

  defp ledger_index(%{"ledger_index" => index}), do: positive_index(index)
  defp ledger_index(%{"ledger" => %{"ledger_index" => index}}), do: positive_index(index)
  defp ledger_index(_result), do: :error

  defp positive_index(index) when is_integer(index) and index > 0, do: {:ok, index}

  defp positive_index(index) when is_binary(index) do
    case Integer.parse(index) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp positive_index(_index), do: :error

  defp claim_transaction(channel, proof, wallet, sequence, last_ledger, config) do
    with {:ok, wire_id} <- Channel.to_xrpl_id(channel.channel_id) do
      tx = %{
        "TransactionType" => "PaymentChannelClaim",
        "Account" => wallet.address,
        "Channel" => wire_id,
        "Amount" => Integer.to_string(proof.amount),
        "Balance" => Integer.to_string(proof.amount),
        "Signature" => proof.signature,
        "PublicKey" => proof.public_key,
        "Flags" => @tf_close,
        "Sequence" => sequence,
        "LastLedgerSequence" => last_ledger,
        "Fee" => Map.get(config, "fee", @default_fee)
      }

      {:ok, maybe_network_id(tx, config)}
    end
  end

  defp maybe_network_id(tx, config) do
    case RPC.networks()[config["network"]] do
      id when is_integer(id) and id > 0 -> Map.put(tx, "NetworkID", id)
      _ -> tx
    end
  end

  defp claimed?(result, hash, _channel, _proof) do
    meta = Map.get(result, "meta", %{})
    reported = result["hash"] || get_in(result, ["tx_json", "hash"])

    if result["validated"] == true and meta["TransactionResult"] == "tesSUCCESS" and is_binary(reported) and
         String.upcase(reported) == hash do
      :ok
    else
      :error
    end
  end

  defp confirm_ledger(channel_id, amount, config) do
    case ledger_channel(channel_id, config) do
      {:error, %Errors{type: type}} ->
        if type == Errors.new(:channel_not_found, "").type, do: :ok, else: :error

      {:ok, node} ->
        case drops(node["Balance"]) do
          {:ok, balance} when balance >= amount -> :ok
          _ -> :error
        end
    end
  end

  # draft-xrpl-session-00 §Error Responses: ledger result codes MUST NOT be
  # surfaced raw, so the client-facing close error drops the engine result that
  # `redeem/2` reports to the operator.
  defp settlement_failed, do: Errors.new(:settlement_failed, "XRPL PaymentChannelClaim was not settled")

  defp failed, do: {:error, Errors.new(:verification_failed, "XRPL session verification failed")}
  defp malformed, do: {:error, Errors.new(:malformed_credential, "Malformed XRPL session credential")}
end
