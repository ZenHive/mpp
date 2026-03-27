defmodule MPP.Methods.Tempo do
  @moduledoc """
  Tempo payment method — verifies payment via on-chain TIP-20 token transfer.

  Tempo supports two credential types:

    * `type="hash"` — Client already broadcast the transaction; server verifies
      the receipt via RPC (`eth_getTransactionReceipt`).
    * `type="transaction"` — Client sends a signed Tempo Transaction (0x76);
      server decodes, optionally adds fee payer signature, broadcasts, and verifies.

  ## Configuration

  Pass Tempo-specific config via `:method_config` in `MPP.Plug` opts:

      plug MPP.Plug,
        secret_key: "hmac-secret",
        realm: "api.example.com",
        method: MPP.Methods.Tempo,
        amount: "1000000",
        currency: "0x20c0000000000000000000000000000000000000",
        method_config: %{
          "rpc_url" => "https://rpc.moderato.tempo.xyz",
          "chain_id" => 42431,
          "fee_payer" => false
        }

  ## Config Keys

    * `"rpc_url"` — (required) Tempo RPC endpoint URL
    * `"chain_id"` — (optional) network chain ID, defaults to `42431` (Moderato testnet)
    * `"fee_payer"` — (optional) enable server-side fee sponsorship, defaults to `false`
    * `"memo"` — (optional) bytes32 hex memo for `transferWithMemo`

  ## Credential Payload

  The credential `payload` map must contain one of:

    * `"type" => "hash"`, `"hash" => "0x..."` — transaction hash for receipt verification
    * `"type" => "transaction"`, `"signature" => "..."` — RLP-serialized signed Tempo Transaction

  ## Dependencies

  Requires the `onchain` package (optional dependency) for RPC calls and transfer
  log parsing. The method checks availability at init time via `validate_config!/1`.
  """

  use MPP.Method
  use Descripex, namespace: "/methods"

  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.Receipt
  # onchain is optional — suppress unknown function warnings for its APIs.
  # Runtime availability is enforced by validate_config!/1 at Plug init time.
  alias MPP.Tempo.Transaction

  @dialyzer {:nowarn_function, [find_matching_transfer: 3, parse_transfer_with_memo_logs: 1]}

  @moderato_chain_id 42_431
  @required_config_keys ~w(rpc_url)
  @memo_hex_length 64

  api(:method_name, "Return the payment method identifier for Tempo.")

  @impl MPP.Method
  @spec method_name() :: String.t()
  def method_name, do: "tempo"

  api(
    :validate_config!,
    "Validate Tempo method_config at init time. Raises on missing `rpc_url` or unavailable `onchain` dependency.",
    params: [
      config: [kind: :value, description: "method_config map to validate"]
    ],
    returns: %{type: :atom, description: "`:ok` on success, raises `ArgumentError` on missing keys"}
  )

  @impl MPP.Method
  @spec validate_config!(map()) :: :ok
  def validate_config!(config) do
    missing = Enum.filter(@required_config_keys, &is_nil(config[&1]))

    if missing != [] do
      raise ArgumentError,
            "MPP.Methods.Tempo requires these keys in method_config: #{Enum.join(missing, ", ")}"
    end

    validate_memo!(config["memo"])
    check_onchain_available!()

    :ok
  end

  api(:verify, "Verify a Tempo credential by checking on-chain settlement.",
    params: [
      payload: [
        kind: :value,
        description: ~s{Credential payload map with `"type"` (`"hash"` or `"transaction"`) and corresponding proof field}
      ],
      charge: [
        kind: :value,
        description: "Charge intent struct with amount, currency, and method_details (including `rpc_url`)"
      ]
    ],
    returns: %{type: :tagged_tuple, description: "`{:ok, receipt}` on success, `{:error, error}` on failure"},
    errors: [:invalid_payload, :verification_failed]
  )

  @impl MPP.Method
  @spec verify(map(), Charge.t()) :: {:ok, Receipt.t()} | {:error, Errors.t()}
  def verify(%{"type" => "hash"} = payload, %Charge{} = charge) do
    config = charge.method_details || %{}
    memo = config["memo"]

    with {:ok, hash} <- extract_hash(payload),
         {:ok, rpc_url} <- require_config(config, "rpc_url"),
         {:ok, receipt} <- fetch_receipt(hash, rpc_url, config),
         :ok <- check_receipt_status(receipt),
         {:ok, _transfer} <- find_matching_transfer(receipt, charge, memo) do
      {:ok, Receipt.new(method: "tempo", reference: hash, external_id: charge.external_id)}
    end
  end

  def verify(%{"type" => "transaction"} = payload, %Charge{} = charge) do
    config = charge.method_details || %{}
    memo = config["memo"]
    expected_chain_id = config["chain_id"] || @moderato_chain_id

    with {:ok, signature} <- extract_signature(payload),
         {:ok, tx} <- Transaction.deserialize(signature),
         :ok <- verify_chain_id(tx, expected_chain_id),
         {:ok, _call} <-
           Transaction.find_payment_call(tx, charge.currency,
             amount: charge.amount,
             recipient: charge.recipient,
             memo: memo
           ),
         {:ok, rpc_url} <- require_config(config, "rpc_url"),
         {:ok, tx_hash, receipt} <- broadcast_transaction_sync(tx.raw, rpc_url, config),
         :ok <- check_receipt_status(receipt),
         {:ok, _transfer} <- find_matching_transfer(receipt, charge, memo) do
      {:ok, Receipt.new(method: "tempo", reference: tx_hash, external_id: charge.external_id)}
    else
      {:error, %Errors{} = error} -> {:error, error}
      {:error, reason} when is_binary(reason) -> {:error, Errors.new(:verification_failed, reason)}
    end
  end

  def verify(_payload, %Charge{}) do
    {:error, Errors.new(:invalid_payload, ~s(Missing or invalid 'type' field — expected "hash" or "transaction"))}
  end

  api(
    :challenge_method_details,
    "Return Tempo-specific fields (`chainId`, `feePayer`, `memo`) for the 402 challenge.",
    params: [
      charge: [
        kind: :value,
        description: "Charge struct with method_details containing `chain_id`, `fee_payer`, and optionally `memo`"
      ]
    ],
    returns: %{
      type: :map,
      description: "Map with `chainId` (default 42431), `feePayer` (default false), and optional `memo`"
    }
  )

  @impl MPP.Method
  @spec challenge_method_details(Charge.t()) :: map()
  def challenge_method_details(%Charge{} = charge) do
    config = charge.method_details || %{}

    details = %{
      "chainId" => config["chain_id"] || @moderato_chain_id,
      "feePayer" => config["fee_payer"] || false
    }

    case config["memo"] do
      nil -> details
      memo -> Map.put(details, "memo", memo)
    end
  end

  # --- Private helpers ---

  # Validates memo format: exactly 32 bytes of hex (64 chars), optional 0x prefix.
  defp validate_memo!(nil), do: :ok

  defp validate_memo!(memo) when is_binary(memo) do
    hex = strip_0x(memo)

    if !(byte_size(hex) == @memo_hex_length and hex_string?(hex)) do
      raise ArgumentError,
            "memo must be a 32-byte hex string (#{@memo_hex_length} hex chars), got: #{inspect(memo)}"
    end

    :ok
  end

  defp validate_memo!(other) do
    raise ArgumentError,
          "memo must be a 32-byte hex string (#{@memo_hex_length} hex chars), got: #{inspect(other)}"
  end

  # Extracts and validates the tx hash from a hash credential payload.
  defp extract_hash(%{"hash" => hash}) when is_binary(hash) do
    hex = strip_0x(hash)

    if byte_size(hex) == 64 and hex_string?(hex) do
      {:ok, hash}
    else
      {:error, Errors.new(:invalid_payload, "Invalid transaction hash format")}
    end
  end

  defp extract_hash(_) do
    {:error, Errors.new(:invalid_payload, "Missing or invalid 'hash' field in credential payload")}
  end

  # Extracts and validates the serialized transaction from a transaction credential payload.
  defp extract_signature(%{"signature" => sig}) when is_binary(sig) and byte_size(sig) > 0 do
    {:ok, sig}
  end

  defp extract_signature(_) do
    {:error, Errors.new(:invalid_payload, "Missing or invalid 'signature' field in credential payload")}
  end

  # Compares the transaction's chain_id against the expected value from config.
  defp verify_chain_id(%Transaction{chain_id: actual}, expected) when actual == expected, do: :ok

  defp verify_chain_id(%Transaction{chain_id: actual}, expected) do
    {:error, "Chain ID mismatch: expected #{expected}, got #{actual}"}
  end

  # TODO(onchain_tempo): Extract broadcast_transaction_sync/3 to OnchainTempo.RPC
  # Broadcasts a signed transaction via Tempo's synchronous eth_sendRawTransactionSync
  # JSON-RPC method. Unlike eth_sendRawTransaction (async), the sync variant waits for
  # block inclusion (~500ms on Tempo) and returns the full receipt directly — eliminating
  # the race condition where a separate eth_getTransactionReceipt call arrives before mining.
  # Returns {:ok, tx_hash, parsed_receipt} on success.
  defp broadcast_transaction_sync(raw_hex, rpc_url, config) do
    req_options = config["req_options"] || []

    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "eth_sendRawTransactionSync",
        "params" => [raw_hex],
        "id" => 1
      })

    result =
      Req.request(
        [
          url: rpc_url,
          method: :post,
          headers: [{"content-type", "application/json"}],
          body: body
        ],
        req_options
      )

    case result do
      {:ok, %Req.Response{status: status, body: %{"result" => receipt}}}
      when status in 200..299 and is_map(receipt) ->
        tx_hash = receipt["transactionHash"]
        {:ok, tx_hash, parse_rpc_receipt(receipt)}

      {:ok, %Req.Response{body: %{"error" => error}}} ->
        {:error, Errors.new(:verification_failed, "Broadcast failed: #{inspect(error)}")}

      {:error, exception} ->
        {:error, Errors.new(:verification_failed, "Broadcast request failed: #{Exception.message(exception)}")}

      {:ok, %Req.Response{} = response} ->
        {:error, Errors.new(:verification_failed, "Unexpected broadcast response (status #{response.status})")}
    end
  end

  # Gets a required key from the method_details config map.
  defp require_config(config, key) do
    case config[key] do
      nil -> {:error, Errors.new(:verification_failed, "Tempo method missing required config: #{key}")}
      value -> {:ok, value}
    end
  end

  # Fetches a transaction receipt via JSON-RPC using Req.
  defp fetch_receipt(hash, rpc_url, config) do
    req_options = config["req_options"] || []

    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "eth_getTransactionReceipt",
        "params" => [hash],
        "id" => 1
      })

    result =
      Req.request(
        [
          url: rpc_url,
          method: :post,
          headers: [{"content-type", "application/json"}],
          body: body
        ],
        req_options
      )

    case result do
      {:ok, %Req.Response{status: status, body: %{"result" => receipt}}} when status in 200..299 ->
        if is_nil(receipt) do
          {:error, Errors.new(:verification_failed, "Transaction not found on-chain")}
        else
          {:ok, parse_rpc_receipt(receipt)}
        end

      {:ok, %Req.Response{body: %{"error" => error}}} ->
        {:error, Errors.new(:verification_failed, "RPC error: #{inspect(error)}")}

      {:error, exception} ->
        {:error, Errors.new(:verification_failed, "RPC request failed: #{Exception.message(exception)}")}

      {:ok, %Req.Response{} = response} ->
        {:error, Errors.new(:verification_failed, "Unexpected RPC response (status #{response.status})")}
    end
  end

  # Verifies that the transaction succeeded (status 0x1).
  defp check_receipt_status(%{status: 1}), do: :ok

  defp check_receipt_status(%{status: _}) do
    {:error, Errors.new(:verification_failed, "Transaction failed on-chain (reverted)")}
  end

  # TODO(onchain_tempo): Extract parse_transfer_with_memo_logs/1 to OnchainTempo.Transfer
  # TIP-20 TransferWithMemo event signature — Tempo-specific, not in onchain.
  @transfer_with_memo_sig "TransferWithMemo(address indexed from, address indexed to, uint256 amount, bytes32 memo)"

  # Finds a matching transfer event. When memo is configured, requires TransferWithMemo
  # with matching memo. When no memo, accepts both Transfer and TransferWithMemo events.
  # Spec: draft-tempo-charge-00.md §Transaction Verification, lines 395-399.
  defp find_matching_transfer(receipt, charge, memo)

  defp find_matching_transfer(%{logs: logs}, %Charge{} = charge, nil) do
    # No memo configured — accept Transfer OR TransferWithMemo matching token/recipient/amount.
    with {:ok, amount_int} <- parse_charge_amount(charge.amount),
         {:ok, transfers} <- Onchain.Transfer.parse_logs(logs) do
      # Also check TransferWithMemo events (onchain only parses standard Transfer)
      memo_transfers = parse_transfer_with_memo_logs(logs)

      match =
        Enum.find(transfers ++ memo_transfers, fn transfer ->
          Onchain.Address.equal?(transfer.token, charge.currency) and
            Onchain.Address.equal?(transfer.to, charge.recipient) and
            transfer.amount == amount_int
        end)

      case match do
        nil -> {:error, Errors.new(:verification_failed, "No matching Transfer event found in transaction")}
        transfer -> {:ok, transfer}
      end
    end
  end

  defp find_matching_transfer(%{logs: logs}, %Charge{} = charge, memo) when is_binary(memo) do
    # Memo configured — MUST match TransferWithMemo with matching memo value.
    with {:ok, amount_int} <- parse_charge_amount(charge.amount) do
      normalized_memo = String.downcase(strip_0x(memo))

      match =
        logs
        |> parse_transfer_with_memo_logs()
        |> Enum.find(fn transfer ->
          Onchain.Address.equal?(transfer.token, charge.currency) and
            Onchain.Address.equal?(transfer.to, charge.recipient) and
            transfer.amount == amount_int and
            String.downcase(strip_0x(transfer.memo)) == normalized_memo
        end)

      case match do
        nil ->
          {:error, Errors.new(:verification_failed, "No matching TransferWithMemo event found in transaction")}

        transfer ->
          {:ok, transfer}
      end
    end
  end

  # Parses TransferWithMemo events from raw logs. Returns a flat list of maps
  # with :token, :from, :to, :amount, :memo keys (same shape as Onchain.Transfer
  # structs plus :memo, for uniform matching).
  defp parse_transfer_with_memo_logs(logs) do
    Enum.flat_map(logs, fn log ->
      case Onchain.Log.decode_event(log, @transfer_with_memo_sig) do
        {:ok, %{from: from, to: to, amount: amount, memo: memo_bytes}} ->
          [
            %{
              token: log.address,
              from: from,
              to: to,
              amount: amount,
              memo: encode_memo(memo_bytes)
            }
          ]

        _ ->
          []
      end
    end)
  end

  # Encodes a raw bytes32 memo value to hex string for comparison.
  # Onchain.Log.decode_event returns bytes32 as a 32-byte binary.
  defp encode_memo(memo) when is_binary(memo) and byte_size(memo) == 32 do
    Base.encode16(memo, case: :lower)
  end

  defp encode_memo(<<"0x", _::binary>> = hex), do: String.downcase(strip_0x(hex))
  defp encode_memo(memo) when is_binary(memo), do: String.downcase(memo)

  # Parses charge amount string to integer safely.
  defp parse_charge_amount(amount) do
    case Integer.parse(amount) do
      {int, ""} -> {:ok, int}
      _ -> {:error, Errors.new(:verification_failed, "Invalid charge amount: not a valid integer")}
    end
  end

  # Parses raw JSON-RPC receipt into the atom-keyed format expected by Onchain.Transfer.
  defp parse_rpc_receipt(raw) do
    %{
      status: parse_hex_integer(raw["status"]),
      logs: Enum.map(raw["logs"] || [], &parse_rpc_log/1)
    }
  end

  # Converts a raw JSON-RPC log entry to atom-keyed map for Onchain.Transfer.parse_log/1.
  defp parse_rpc_log(log) do
    %{
      address: log["address"],
      topics: log["topics"] || [],
      data: log["data"],
      block_number: parse_hex_integer(log["blockNumber"]) || 0,
      transaction_hash: log["transactionHash"],
      log_index: parse_hex_integer(log["logIndex"]) || 0
    }
  end

  # Parses a hex string like "0x1" into an integer.
  defp parse_hex_integer(nil), do: nil
  defp parse_hex_integer("0x" <> hex), do: String.to_integer(hex, 16)
  defp parse_hex_integer(_), do: nil

  # Strips the optional "0x" prefix from a hex string.
  defp strip_0x("0x" <> rest), do: rest
  defp strip_0x(hex), do: hex

  # Checks if a string contains only hex characters.
  defp hex_string?(str), do: Regex.match?(~r/\A[0-9a-fA-F]+\z/, str)

  # Checks that the onchain library is available at runtime.
  defp check_onchain_available! do
    if !Code.ensure_loaded?(Onchain) do
      raise ArgumentError, """
      MPP.Methods.Tempo requires the `onchain` package.

      Add it to your mix.exs dependencies:

          {:onchain, "~> 0.4"}
      """
    end
  end
end
