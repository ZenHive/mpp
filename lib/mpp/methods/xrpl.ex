defmodule MPP.Methods.XRPL do
  @moduledoc """
  XRPL charge verification for native XRP, issued currencies and MPTs.

  Implements `draft-xrpl-charge-00` at mpp-specs commit `213b098`.
  Pull credentials carry `type: "transaction", blob: "<hex>"`; push credentials
  carry `type: "hash", hash: "<64 hex>"`. Pull blobs are decoded and checked
  before submission, then checked again against validated ledger metadata.

  Configure `rpc_url` (HTTPS), `network` (mainnet/testnet/devnet), `store`
  (a durable, shared `MPP.Tempo.Store` implementation) and `store_retention_ms`.
  Retention must cover challenge expiry plus `poll_timeout_ms` (default 60 seconds).
  The store operator must guarantee the declared retention across restarts and
  replicas. Testnet/devnet may explicitly set `allow_process_local_store: true`
  to use a configured ConCache store. Disabling the store is not supported.

  `MPP.Verifier` supplies `challenge_id`, `challenge_expires`, `credential_source`
  and `realm`. Direct callers must supply authenticated values themselves.
  The source is `did:pkh:xrpl:<network ID>:<classic address>`.
  Binding defaults to SHA-512Half of the challenge ID, never a static tag.
  An explicit `invoiceId` must be unique to that challenge.

  Public details are `network`, `reference`, `invoiceId`, `destinationTag`,
  `sourceTag`, and `memos`. The draft leaves memo entry structure unspecified;
  this implementation accepts UTF-8 maps with `data`, optional `type` and `format`,
  mapping to the corresponding XRPL Memo fields. They must match exactly.
  `req_options` configures Req; `poll_interval_ms` defaults to 1000 milliseconds.
  The JSON-RPC connection must support `server_info`, `submit` and `tx` API v1.
  """

  @behaviour MPP.Method

  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.Methods.Shared
  alias MPP.Methods.XRPL.Codec
  alias MPP.Receipt
  alias MPP.Tempo.ConCacheStore
  alias MPP.Tempo.Store

  # refs/mpp-specs/specs/methods/xrpl/draft-xrpl-charge-00.md:236,308-313,365-378
  @public_fields ~w(network reference invoiceId destinationTag sourceTag memos)
  # CAIP XRPL namespace: https://namespaces.chainagnostic.org/xrpl/caip10
  @networks %{"mainnet" => 0, "testnet" => 1, "devnet" => 2}
  # XRPL-owned Payment flags; draft requires its absence at :427.
  @partial_payment 0x00020000

  @impl MPP.Method
  @doc "Return the XRPL payment method identifier."
  @spec method_name() :: String.t()
  def method_name, do: "xrpl"

  @impl MPP.Method
  @doc "Return the draft's two charge credential types."
  @spec credential_types() :: [String.t()]
  def credential_types, do: ~w(transaction hash)

  @impl MPP.Method
  @doc "Validate the RPC, network and mandatory replay-store configuration."
  @spec validate_config!(map()) :: :ok
  def validate_config!(config) do
    if not valid_config?(config),
      do:
        raise(
          ArgumentError,
          "XRPL requires HTTPS rpc_url, network, an atomic shared durable store, and positive store_retention_ms; process-local stores require an explicit testnet/devnet opt-in"
        )

    :ok
  end

  @impl MPP.Method
  @doc "Expose only the draft's public method details."
  @spec challenge_method_details(Charge.t()) :: map()
  def challenge_method_details(%Charge{} = charge), do: Map.take(charge.method_details || %{}, @public_fields)

  @impl MPP.Method
  @doc "Verify a charge against a validated XRPL Payment and atomically consume it."
  @spec verify(map(), Charge.t()) :: {:ok, Receipt.t()} | {:error, Errors.t()}
  def verify(payload, %Charge{} = charge) do
    config = charge.method_details || %{}

    with {:ok, proof} <- proof(payload),
         :ok <- freshness(config),
         {:ok, _url} <- Shared.require_config(config, "rpc_url", "XRPL"),
         true <- valid_config?(config),
         true <- valid_charge?(charge),
         true <- valid_source?(config),
         :ok <- unused(config, "challenge:" <> config["challenge_id"]),
         {:ok, prepared} <- prepare(proof, charge, config),
         :ok <- network(config),
         {:ok, hash} <- submit(prepared, config),
         :ok <- unused(config, "tx:" <> hash),
         {:ok, result} <- await_transaction(hash, config),
         :ok <- settled(result, hash, charge, config),
         :ok <- freshness(config),
         :ok <- mark(config, "tx:" <> hash),
         :ok <- mark(config, "challenge:" <> config["challenge_id"]) do
      # refs/mpp-specs/specs/methods/xrpl/draft-xrpl-charge-00.md:535-548
      {:ok,
       Receipt.new(
         method: "xrpl",
         reference: hash,
         external_id: charge.external_id,
         extensions: %{"txHash" => hash, "ledgerIndex" => result["ledger_index"]}
       )}
    else
      {:error, %Errors{} = error} -> {:error, error}
      _ -> failed()
    end
  end

  # Draft :365-378, :264-275. Bound hex before decoding or making RPC calls.
  defp proof(%{"type" => "hash", "hash" => hash}) do
    if hex?(hash, 64), do: {:ok, {:hash, String.upcase(hash)}}, else: malformed()
  end

  defp proof(%{"type" => "transaction", "blob" => blob}) do
    case Codec.decode(blob) do
      {:ok, tx} -> {:ok, {:blob, String.upcase(blob), tx}}
      _ -> malformed()
    end
  end

  defp proof(_), do: malformed()

  defp prepare({:hash, _} = proof, _charge, _config), do: {:ok, proof}

  defp prepare({:blob, blob, tx}, charge, config) do
    with :ok <- fields(tx, tx["Amount"], charge, config),
         true <- signed?(tx),
         true <- is_integer(tx["LastLedgerSequence"]) and tx["LastLedgerSequence"] > 0,
         :ok <- unused(config, "tx:" <> blob_hash(blob)) do
      {:ok, {:blob, blob}}
    else
      {:error, %Errors{} = error} -> {:error, error}
      _ -> failed()
    end
  end

  defp signed?(%{"TxnSignature" => signature}), do: is_binary(signature) and byte_size(signature) > 0
  defp signed?(%{"Signers" => signers}), do: is_list(signers) and signers != []
  defp signed?(_), do: false

  defp submit({:hash, hash}, _config), do: {:ok, hash}

  defp submit({:blob, blob}, config) do
    expected_hash = blob_hash(blob)

    with {:ok, result} <- rpc(config, "submit", %{"tx_blob" => blob}),
         true <- result["engine_result"] in ["tesSUCCESS", "terQUEUED"],
         hash when is_binary(hash) <- get_in(result, ["tx_json", "hash"]),
         true <- hex?(hash, 64) and String.upcase(hash) == expected_hash do
      {:ok, expected_hash}
    else
      _ -> failed()
    end
  end

  # XRPLF/rippled include/xrpl/protocol/HashPrefix.h: TransactionId = "TXN\0".
  defp blob_hash(blob) do
    <<digest::binary-32, _::binary>> = :crypto.hash(:sha512, <<"TXN", 0>> <> Base.decode16!(blob))
    Base.encode16(digest)
  end

  defp network(config) do
    with {:ok, %{"info" => %{"network_id" => id}}} <- rpc(config, "server_info", %{}),
         true <- id == @networks[config["network"]] do
      :ok
    else
      _ -> failed()
    end
  end

  defp await_transaction(hash, config) do
    deadline = System.monotonic_time(:millisecond) + timeout(config)
    poll(hash, config, deadline, 0)
  end

  defp poll(hash, config, deadline, misses) do
    case rpc(config, "tx", %{"transaction" => hash, "binary" => false}) do
      {:ok, %{"validated" => true} = result} -> {:ok, result}
      {:ok, %{"error" => "txnNotFound"}} when misses < 2 -> retry(hash, config, deadline, misses + 1)
      {:ok, %{"validated" => false}} -> retry(hash, config, deadline, misses)
      _ -> failed()
    end
  end

  defp retry(hash, config, deadline, misses) do
    delay = Map.get(config, "poll_interval_ms", 1000)

    if System.monotonic_time(:millisecond) + delay < deadline do
      receive do
      after
        delay -> :ok
      end

      poll(hash, config, deadline, misses)
    else
      failed()
    end
  end

  # Draft :413-468; https://xrpl.org/docs/concepts/payment-types/partial-payments
  defp settled(%{"validated" => true, "meta" => %{"TransactionResult" => "tesSUCCESS"} = meta} = tx, hash, charge, config) do
    if is_integer(tx["ledger_index"]) and tx["ledger_index"] > 0 and
         is_binary(tx["hash"]) and String.upcase(tx["hash"]) == hash do
      fields(tx, Map.get(meta, "delivered_amount", tx["Amount"]), charge, config)
    else
      failed()
    end
  end

  defp settled(_, _, _, _), do: failed()

  defp fields(tx, delivered, charge, config) do
    flags = Map.get(tx, "Flags", 0)

    checks = [
      tx["TransactionType"] == "Payment",
      tx["Destination"] == charge.recipient,
      source_matches?(tx["Account"], config),
      is_integer(flags) and Bitwise.band(flags, @partial_payment) == 0,
      amount_matches?(delivered, charge),
      invoice_matches?(tx["InvoiceID"], config),
      optional_matches?(tx, "DestinationTag", config, "destinationTag"),
      optional_matches?(tx, "SourceTag", config, "sourceTag"),
      memos_match?(tx, config)
    ]

    if Enum.all?(checks), do: :ok, else: failed()
  end

  defp valid_source?(config) do
    prefix = "did:pkh:xrpl:#{@networks[config["network"]]}:"

    case config["credential_source"] do
      source when is_binary(source) ->
        String.starts_with?(source, prefix) and Codec.address?(String.replace_prefix(source, prefix, ""))

      _ ->
        false
    end
  end

  defp source_matches?(account, config) do
    is_binary(account) and config["credential_source"] == "did:pkh:xrpl:#{@networks[config["network"]]}:#{account}"
  end

  # Draft :442-456. Require the binding on both paths, including older pull clients.
  defp invoice_matches?(invoice, config) do
    expected = config["invoiceId"] || derived_invoice(config["challenge_id"])
    hex?(invoice, 64) and hex?(expected, 64) and String.upcase(invoice) == String.upcase(expected)
  end

  defp derived_invoice(id) do
    <<digest::binary-32, _::binary>> = :crypto.hash(:sha512, id)
    Base.encode16(digest)
  end

  defp optional_matches?(tx, ledger_key, config, key), do: not Map.has_key?(config, key) or tx[ledger_key] == config[key]

  defp memos_match?(tx, %{"memos" => memos}) do
    expected =
      Enum.map(memos, fn memo ->
        fields =
          for {key, field} <- [{"data", "MemoData"}, {"type", "MemoType"}, {"format", "MemoFormat"}],
              Map.has_key?(memo, key),
              into: %{},
              do: {field, Base.encode16(memo[key])}

        %{"Memo" => fields}
      end)

    tx["Memos"] == expected
  end

  defp memos_match?(_tx, _config), do: true

  # Draft :256-260, :291-302; currency JSON is carried in the shared string field
  # as demonstrated by the issued-currency example at :793.
  defp amount_matches?(delivered, %Charge{currency: "XRP", amount: expected}) when is_binary(delivered),
    do: decimal_equal?(delivered, expected)

  defp amount_matches?(%{"value" => value} = delivered, charge) do
    with {:ok, asset} <- Jason.decode(charge.currency),
         true <- Map.delete(delivered, "value") == asset do
      decimal_equal?(value, charge.amount)
    else
      _ -> false
    end
  end

  defp amount_matches?(_, _), do: false

  defp decimal_equal?(left, right) do
    match?({{:ok, value}, {:ok, value}}, {decimal(left), decimal(right)})
  end

  defp decimal(value) when is_binary(value) and byte_size(value) <= 160 do
    case Regex.run(~r/\A(\d+)(?:\.(\d+))?(?:[eE]([+-]?\d{1,3}))?\z/, value, capture: :all_but_first) do
      nil ->
        :error

      parts ->
        [whole, fraction, exponent] = Enum.take(parts ++ ["", ""], 3)
        digits = String.trim_leading(whole <> fraction, "0")
        normalized = String.trim_trailing(digits, "0")

        power =
          if(exponent == "", do: 0, else: String.to_integer(exponent)) - byte_size(fraction) + byte_size(digits) -
            byte_size(normalized)

        if normalized == "", do: :error, else: {:ok, {normalized, power}}
    end
  end

  defp decimal(_), do: :error

  defp valid_charge?(charge) do
    Codec.address?(charge.recipient) and is_binary(charge.amount) and
      Regex.match?(~r/\A\d+(?:\.\d+)?\z/, charge.amount) and decimal(charge.amount) != :error and
      valid_currency?(charge.currency, charge.amount)
  end

  defp valid_currency?("XRP", amount), do: not String.contains?(amount, ".")

  defp valid_currency?(currency, _amount) when is_binary(currency) do
    case Jason.decode(currency) do
      {:ok, %{"currency" => code, "issuer" => issuer} = asset} ->
        map_size(asset) == 2 and currency_code?(code) and Codec.address?(issuer)

      {:ok, %{"mpt_issuance_id" => id} = asset} ->
        map_size(asset) == 1 and hex?(id, 48)

      _ ->
        false
    end
  end

  defp valid_currency?(_, _), do: false

  defp currency_code?(code) when is_binary(code), do: code != "XRP" and (byte_size(code) == 3 or hex?(code, 40))
  defp currency_code?(_), do: false

  # Draft :391-409, :584-587. No expiry or no atomic store is never unbounded.
  defp freshness(config) do
    with id when is_binary(id) and byte_size(id) > 0 <- config["challenge_id"],
         expires when is_binary(expires) <- config["challenge_expires"],
         {:ok, date, _} <- DateTime.from_iso8601(expires),
         remaining when remaining > 0 <- DateTime.diff(date, DateTime.utc_now(), :millisecond),
         retention when is_integer(retention) <- config["store_retention_ms"],
         true <- is_integer(timeout(config)) and timeout(config) > 0 and retention >= remaining + timeout(config) do
      :ok
    else
      _ -> invalid_challenge()
    end
  end

  defp valid_config?(config) do
    is_map(config) and valid_url?(config["rpc_url"]) and Map.has_key?(@networks, config["network"]) and
      valid_store?(config) and valid_limits?(config) and valid_details?(config)
  end

  defp valid_limits?(config) do
    Enum.all?([config["store_retention_ms"], timeout(config), Map.get(config, "poll_interval_ms", 1000)], fn value ->
      is_integer(value) and value > 0
    end)
  end

  defp valid_details?(config) do
    Enum.all?(~w(destinationTag sourceTag), fn key ->
      not Map.has_key?(config, key) or (is_integer(config[key]) and config[key] in 0..4_294_967_295)
    end) and
      (not Map.has_key?(config, "invoiceId") or hex?(config["invoiceId"], 64)) and
      valid_memos?(Map.get(config, "memos", []))
  end

  defp valid_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) and host != "" -> true
      %URI{scheme: "http", host: host} when host in ["localhost", "127.0.0.1", "::1"] -> true
      _ -> false
    end
  end

  defp valid_url?(_), do: false

  defp valid_store?(%{"store" => {ConCacheStore, opts}} = config) when is_list(opts), do: local_store?(config)
  defp valid_store?(%{"store" => ConCacheStore} = config), do: local_store?(config)
  defp valid_store?(%{"store" => store}), do: Store.dedup_capable?(store)
  defp valid_store?(_), do: false
  defp local_store?(config), do: config["allow_process_local_store"] == true and config["network"] in ~w(testnet devnet)

  defp valid_memos?(memos) when is_list(memos) do
    Enum.all?(memos, fn memo ->
      is_map(memo) and map_size(memo) > 0 and
        Enum.all?(memo, fn {key, value} -> key in ~w(data type format) and is_binary(value) and String.valid?(value) end)
    end)
  end

  defp valid_memos?(_), do: false

  defp unused(config, suffix) do
    case Store.get(config["store"], store_key(config, suffix)) do
      :not_found -> :ok
      {:ok, _} -> invalid_challenge()
      _ -> failed()
    end
  end

  defp mark(config, suffix) do
    case Store.check_and_mark(config["store"], store_key(config, suffix), true) do
      :ok -> :ok
      {:error, :already_exists} -> invalid_challenge()
      _ -> failed()
    end
  end

  defp store_key(config, suffix), do: "mpp:xrpl:#{config["network"]}:#{suffix}"
  defp timeout(config), do: Map.get(config, "poll_timeout_ms", 60_000)

  defp rpc(config, method, params) do
    opts =
      Keyword.merge(Map.get(config, "req_options", []),
        json: %{"method" => method, "params" => [Map.put(params, "api_version", 1)]},
        retry: false,
        receive_timeout: timeout(config)
      )

    case Req.post(config["rpc_url"], opts) do
      {:ok, %{status: 200, body: %{"result" => result}}} when is_map(result) -> {:ok, result}
      _ -> failed()
    end
  end

  defp hex?(value, size) when is_binary(value) and byte_size(value) == size,
    do: match?({:ok, _}, Base.decode16(value, case: :mixed))

  defp hex?(_, _), do: false
  # Draft :550-565 introduces no new error types; never disclose ledger results.
  defp failed, do: {:error, Errors.new(:verification_failed, "XRPL payment verification failed")}
  defp invalid_challenge, do: {:error, Errors.new(:invalid_challenge, "XRPL challenge is invalid")}
  defp malformed, do: {:error, Errors.new(:malformed_credential, "Malformed XRPL credential")}
end
