defmodule MPP.Methods.EVM do
  @moduledoc """
  Generic EVM payment method — verifies on-chain ERC-20 or native ETH transfers.

  Works on any EVM chain (Ethereum, Base, Polygon, Arbitrum, etc.) by configuring
  the appropriate RPC endpoint and chain ID. The client broadcasts a transaction,
  then sends the transaction hash as a credential. The server fetches the receipt
  via RPC and verifies the transfer matches the charge intent.

  ## Configuration

  Pass EVM-specific config via `:method_config` in `MPP.Plug` opts:

      plug MPP.Plug,
        secret_key: "hmac-secret",
        realm: "api.example.com",
        method: MPP.Methods.EVM,
        amount: "1000000",
        currency: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
        method_config: %{
          "rpc_url" => "https://mainnet.infura.io/v3/YOUR_KEY",
          "chain_id" => 1
        }

  ## Config Keys

    * `"rpc_url"` — (required) JSON-RPC endpoint URL for the target EVM chain
    * `"chain_id"` — (optional) network chain ID, included in challenge details
      so the client knows which chain to transact on
    * `"req_options"` — (optional) passed to `Req.request/2` for testing stubs

  ## Credential Payload

  The credential `payload` map must contain:

    * `"hash"` — (required) 0x-prefixed transaction hash (32 bytes, 66 hex chars)

  ## Currency Conventions

    * ERC-20 tokens: use the token contract address as currency
      (e.g., `"0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"` for USDC on Ethereum)
    * Native ETH: use `"ETH"` or the zero address
      (`"0x0000000000000000000000000000000000000000"`)

  ## Dependencies

  Requires the `onchain` package (optional dependency) for address validation
  and Transfer event parsing. The method checks availability at init time
  via `validate_config!/1`.
  """

  use MPP.Method
  use Descripex, namespace: "/methods"

  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.Receipt

  @required_config_keys ~w(rpc_url)
  @zero_address "0x0000000000000000000000000000000000000000"

  api(:method_name, "Return the payment method identifier for EVM.")

  @impl MPP.Method
  @spec method_name() :: String.t()
  def method_name, do: "evm"

  api(
    :validate_config!,
    "Validate EVM method_config at init time. Raises on missing `rpc_url` or unavailable `onchain` dependency.",
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
            "MPP.Methods.EVM requires these keys in method_config: #{Enum.join(missing, ", ")}"
    end

    :ok
  end

  api(:verify, "Verify an EVM credential by checking on-chain settlement via transaction receipt.",
    params: [
      payload: [
        kind: :value,
        description: ~s{Credential payload map with `"hash"` (0x-prefixed transaction hash)}
      ],
      charge: [
        kind: :value,
        description: "Charge intent struct with amount, currency, recipient, and method_details (including `rpc_url`)"
      ]
    ],
    returns: %{type: :tagged_tuple, description: "`{:ok, receipt}` on success, `{:error, error}` on failure"},
    errors: [:invalid_payload, :verification_failed]
  )

  @impl MPP.Method
  @spec verify(map(), Charge.t()) :: {:ok, Receipt.t()} | {:error, Errors.t()}
  def verify(payload, %Charge{} = charge) do
    config = charge.method_details || %{}

    with {:ok, hash} <- extract_hash(payload),
         {:ok, rpc_url} <- require_config(config, "rpc_url"),
         :ok <- require_recipient(charge) do
      if native_currency?(charge.currency) do
        verify_native_transfer(hash, charge, rpc_url, config)
      else
        verify_erc20_transfer(hash, charge, rpc_url, config)
      end
    end
  end

  api(
    :challenge_method_details,
    "Return EVM-specific fields (`chainId`) for the 402 challenge.",
    params: [
      charge: [
        kind: :value,
        description: "Charge struct with method_details optionally containing `chain_id`"
      ]
    ],
    returns: %{
      type: :map_or_nil,
      description: "Map with `chainId` key, or `nil` if no `chain_id` configured"
    }
  )

  @impl MPP.Method
  @spec challenge_method_details(Charge.t()) :: map() | nil
  def challenge_method_details(%Charge{} = charge) do
    config = charge.method_details || %{}

    case config["chain_id"] do
      nil -> nil
      chain_id -> %{"chainId" => chain_id}
    end
  end

  # --- ERC-20 verification ---

  # Fetches the transaction receipt, parses Transfer logs, and finds a matching transfer.
  defp verify_erc20_transfer(hash, charge, rpc_url, config) do
    with {:ok, receipt} <- rpc_get_receipt(hash, rpc_url, config),
         :ok <- check_receipt_status(receipt),
         {:ok, _transfer} <- find_matching_transfer(receipt, charge) do
      {:ok, Receipt.new(method: "evm", reference: hash, external_id: charge.external_id)}
    end
  end

  # --- Native ETH verification ---

  # Fetches the transaction, checks value matches charge amount, and verifies recipient.
  defp verify_native_transfer(hash, charge, rpc_url, config) do
    with {:ok, receipt} <- rpc_get_receipt(hash, rpc_url, config),
         :ok <- check_receipt_status(receipt),
         {:ok, tx} <- rpc_get_transaction(hash, rpc_url, config),
         :ok <- check_native_transfer(tx, charge) do
      {:ok, Receipt.new(method: "evm", reference: hash, external_id: charge.external_id)}
    end
  end

  # Verifies a native ETH transfer: recipient and value must match the charge.
  defp check_native_transfer(tx, charge) do
    with {:ok, expected_amount} <- parse_charge_amount(charge.amount) do
      cond do
        !Onchain.Address.equal?(tx.to, charge.recipient) ->
          {:error, Errors.new(:verification_failed, "Transaction recipient does not match charge recipient")}

        tx.value != expected_amount ->
          {:error,
           Errors.new(
             :verification_failed,
             "Transaction value #{tx.value} does not match charge amount #{charge.amount}"
           )}

        true ->
          :ok
      end
    end
  end

  # --- Transfer matching ---

  # Parses Transfer events from receipt logs and finds one matching the charge.
  defp find_matching_transfer(%{logs: logs}, %Charge{} = charge) do
    with {:ok, amount_int} <- parse_charge_amount(charge.amount),
         {:ok, transfers} <- Onchain.Transfer.parse_logs(logs) do
      match =
        Enum.find(transfers, fn transfer ->
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

  # --- RPC helpers ---
  # Uses Req directly because Onchain.RPC delegates to Signet.RPC → Finch,
  # bypassing Req entirely. Req.Test stubs only intercept Req.request/2 calls.

  defp rpc_get_receipt(hash, rpc_url, config) do
    case rpc_request("eth_getTransactionReceipt", [hash], rpc_url, config) do
      {:ok, nil} ->
        {:error, Errors.new(:verification_failed, "Transaction not found on-chain")}

      {:ok, receipt} when is_map(receipt) ->
        {:ok, parse_receipt(receipt)}

      {:error, reason} ->
        {:error, Errors.new(:verification_failed, "RPC error fetching receipt: #{inspect(reason)}")}
    end
  end

  defp rpc_get_transaction(hash, rpc_url, config) do
    case rpc_request("eth_getTransactionByHash", [hash], rpc_url, config) do
      {:ok, nil} ->
        {:error, Errors.new(:verification_failed, "Transaction not found on-chain")}

      {:ok, tx} when is_map(tx) ->
        {:ok, parse_transaction(tx)}

      {:error, reason} ->
        {:error, Errors.new(:verification_failed, "RPC error fetching transaction: #{inspect(reason)}")}
    end
  end

  defp rpc_request(method, params, rpc_url, config) do
    req_options = config["req_options"] || []

    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => method,
        "params" => params,
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
      {:ok, %Req.Response{status: status, body: %{"result" => value}}} when status in 200..299 ->
        {:ok, value}

      {:ok, %Req.Response{body: %{"error" => error}}} ->
        {:error, "RPC error: #{inspect(error)}"}

      {:error, exception} ->
        {:error, "RPC request failed: #{Exception.message(exception)}"}

      {:ok, %Req.Response{} = response} ->
        {:error, "Unexpected RPC response (status #{response.status})"}
    end
  end

  # Parses a raw JSON-RPC receipt map into atom-keyed format compatible with Onchain.Transfer.
  defp parse_receipt(raw) do
    %{
      transaction_hash: raw["transactionHash"],
      block_number: hex_to_integer(raw["blockNumber"]),
      status: hex_to_integer(raw["status"]),
      from: raw["from"],
      to: raw["to"],
      logs: Enum.map(raw["logs"] || [], &parse_log/1)
    }
  end

  # Parses a raw JSON-RPC log entry into the atom-keyed format Onchain.Transfer expects.
  defp parse_log(raw) do
    %{
      address: raw["address"],
      topics: raw["topics"] || [],
      data: raw["data"],
      block_number: raw["blockNumber"],
      transaction_hash: raw["transactionHash"],
      log_index: raw["logIndex"]
    }
  end

  # Parses a raw JSON-RPC transaction map into atom-keyed format.
  defp parse_transaction(raw) do
    %{
      hash: raw["hash"],
      from: raw["from"],
      to: raw["to"],
      value: hex_to_integer(raw["value"]),
      input: raw["input"]
    }
  end

  # --- Shared helpers ---

  defp extract_hash(%{"hash" => "0x" <> hex = hash}) when is_binary(hash) do
    if byte_size(hex) == 64 and hex_string?(hex) do
      {:ok, hash}
    else
      {:error, Errors.new(:invalid_payload, "Invalid transaction hash format")}
    end
  end

  defp extract_hash(_) do
    {:error, Errors.new(:invalid_payload, "Missing or invalid 'hash' field in credential payload")}
  end

  defp require_config(config, key) do
    case config[key] do
      nil -> {:error, Errors.new(:verification_failed, "EVM method missing required config: #{key}")}
      value -> {:ok, value}
    end
  end

  # EVM verification requires a recipient address — fail fast if nil.
  defp require_recipient(%Charge{recipient: nil}),
    do: {:error, Errors.new(:verification_failed, "EVM method requires a recipient address")}

  defp require_recipient(%Charge{}), do: :ok

  defp parse_charge_amount(amount) do
    case Integer.parse(amount) do
      {int, ""} -> {:ok, int}
      _ -> {:error, Errors.new(:verification_failed, "Invalid charge amount: not a valid integer")}
    end
  end

  # Returns true if the currency represents native ETH (not an ERC-20 token).
  defp native_currency?("ETH"), do: true
  defp native_currency?("eth"), do: true
  defp native_currency?(@zero_address), do: true
  defp native_currency?(_), do: false

  defp check_receipt_status(%{status: 1}), do: :ok

  defp check_receipt_status(%{status: _}) do
    {:error, Errors.new(:verification_failed, "Transaction failed on-chain (reverted)")}
  end

  defp hex_string?(str), do: Regex.match?(~r/\A[0-9a-fA-F]+\z/, str)

  defp hex_to_integer(nil), do: nil
  defp hex_to_integer("0x" <> hex), do: String.to_integer(hex, 16)
  defp hex_to_integer(val) when is_integer(val), do: val
end
