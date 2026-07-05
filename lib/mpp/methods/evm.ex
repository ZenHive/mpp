# The shared callback set IS a behaviour (`use MPP.Method`); reach's source frontend
# can't see the macro-injected `@behaviour`, so the candidate smell false-positives.
# reach:disable-next-line behaviour_candidate
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
    * `"store"` — (optional but **strongly recommended** — see "Replay protection")
      a module implementing `MPP.Tempo.Store`, or `{MPP.Tempo.ConCacheStore, opts}`,
      used to enforce single-use of each on-chain transaction hash
    * `"req_options"` — (optional) merged into the `Onchain.RPC` call as
      `:req_options` (e.g. `[plug: {Req.Test, MyMod}]`) for testing stubs

  ## Replay protection

  This method verifies an **already-broadcast** transaction by hash and matches it
  against the charge's `token`/`to`/`amount`. That match alone does not bind the
  proof to a single use, so without a dedup store one settled transfer can satisfy
  unlimited future charges on a static-price route (replay).

  Configure `"store"` to make each transaction hash single-use: the hash is checked
  before verification and atomically committed after, reusing the same
  `MPP.Tempo.Store` behaviour (and `MPP.Tempo.ConCacheStore`) as the Tempo method.
  The store's TTL must be ≥ your challenge `expires_in` (a good default is 2×) so a
  hash cannot be evicted and replayed while its challenge is still valid.

  **Residual limitation:** a store makes each transaction single-use, but the
  hash-pointer credential carries no on-chain binding to a *specific* challenge — so
  on its *first* presentation, any unrelated transfer that happens to match
  `token`/`to`/`amount` is accepted. Binding a payment to one challenge on-chain is
  the EIP-3009 authorization path (nonce = `keccak256(challengeId ‖ realm)`), tracked
  separately in the roadmap; prefer it when per-challenge attribution is required.

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
  alias MPP.Tempo.ConCacheStore
  alias MPP.Tempo.Store

  @required_config_keys ~w(rpc_url)
  @zero_address "0x0000000000000000000000000000000000000000"

  # Single-use dedup: an EVM tx hash is namespaced separately from Tempo's
  # "mpp:charge:" keyspace so one shared store can back both methods without
  # cross-method key collisions.
  @dedup_store_error_detail "Dedup store error"
  @store_key_prefix "mpp:evm:"

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

    validate_store!(config["store"])
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
    store = config["store"]

    with {:ok, hash} <- extract_hash(payload),
         {:ok, rpc_url} <- require_config(config, "rpc_url"),
         :ok <- require_recipient(charge),
         :ok <- check_hash_unused(store, hash),
         {:ok, receipt} <- verify_transfer(hash, charge, rpc_url, config),
         :ok <- commit_hash_used(store, hash) do
      {:ok, receipt}
    end
  end

  # Dispatches to native or ERC-20 verification. Called between the dedup
  # fast-reject (check_hash_unused) and the atomic commit (commit_hash_used).
  defp verify_transfer(hash, charge, rpc_url, config) do
    if native_currency?(charge.currency) do
      verify_native_transfer(hash, charge, rpc_url, config)
    else
      verify_erc20_transfer(hash, charge, rpc_url, config)
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
    with {:ok, receipt} <- fetch_receipt(hash, rpc_url, config),
         :ok <- check_receipt_status(receipt),
         {:ok, _transfer} <- find_matching_transfer(receipt, charge) do
      {:ok, Receipt.new(method: "evm", reference: hash, external_id: charge.external_id)}
    end
  end

  # --- Native ETH verification ---

  # Fetches the transaction, checks value matches charge amount, and verifies recipient.
  defp verify_native_transfer(hash, charge, rpc_url, config) do
    with {:ok, receipt} <- fetch_receipt(hash, rpc_url, config),
         :ok <- check_receipt_status(receipt),
         {:ok, tx} <- fetch_transaction(hash, rpc_url, config),
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

  # --- RPC (delegated to Onchain.RPC) ---
  # Onchain.RPC returns atom-keyed, hex-decoded receipts/transactions and is
  # Req-stubbable via the `:req_options` opt (e.g. `[plug: {Req.Test, EVM}]`).

  defp fetch_receipt(hash, rpc_url, config) do
    case Onchain.RPC.get_transaction_receipt(hash, rpc_opts(rpc_url, config)) do
      {:ok, nil} -> {:error, Errors.new(:verification_failed, "Transaction not found on-chain")}
      {:ok, receipt} -> {:ok, receipt}
      {:error, reason} -> {:error, Errors.new(:verification_failed, "RPC error fetching receipt: #{inspect(reason)}")}
    end
  end

  defp fetch_transaction(hash, rpc_url, config) do
    case Onchain.RPC.get_transaction_by_hash(hash, rpc_opts(rpc_url, config)) do
      {:ok, nil} -> {:error, Errors.new(:verification_failed, "Transaction not found on-chain")}
      {:ok, tx} -> {:ok, tx}
      {:error, reason} -> {:error, Errors.new(:verification_failed, "RPC error fetching transaction: #{inspect(reason)}")}
    end
  end

  # Builds Onchain.RPC opts: the node URL plus optional Req overrides (test stubs).
  defp rpc_opts(rpc_url, config) do
    case config["req_options"] do
      nil -> [rpc_url: rpc_url]
      req_options -> [rpc_url: rpc_url, req_options: req_options]
    end
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

  # --- Single-use dedup (mirrors MPP.Methods.Tempo's type="hash" path) ---
  # Reuses the MPP.Tempo.Store behaviour: fast-reject read before on-chain
  # verification, atomic commit after. These thin wrappers are extraction
  # candidates for the shared-helper refactor (roadmap task 73).

  # Read-only pre-check: reject a tx hash already recorded as used.
  defp check_hash_unused(nil, _hash), do: :ok

  defp check_hash_unused(store, hash) do
    case Store.get(store, store_key(hash)) do
      :not_found -> :ok
      {:ok, _} -> {:error, Errors.new(:verification_failed, "Transaction hash already used")}
      {:error, _reason} -> {:error, Errors.new(:verification_failed, @dedup_store_error_detail)}
    end
  end

  # Commits a hash as used AFTER successful on-chain verification. Atomic when the
  # store supports check_and_mark/2: concurrent same-hash requests collide here, so
  # exactly one wins and the loser gets "already used" — closing the check→mark race
  # the plain get/put commit left open. Stores without check_and_mark/2 fall back to a
  # best-effort put (the early read remains their only, non-atomic, guard).
  defp commit_hash_used(nil, _hash), do: :ok

  defp commit_hash_used(store, hash) do
    key = store_key(hash)
    ts = System.system_time(:millisecond)

    if Store.supports_atomic?(store) do
      case Store.check_and_mark(store, key, ts) do
        :ok -> :ok
        {:error, :already_exists} -> {:error, Errors.new(:verification_failed, "Transaction hash already used")}
        {:error, _reason} -> {:error, Errors.new(:verification_failed, @dedup_store_error_detail)}
      end
    else
      case Store.put(store, key, ts) do
        :ok -> :ok
        {:error, _reason} -> {:error, Errors.new(:verification_failed, @dedup_store_error_detail)}
      end
    end
  end

  # Canonical dedup key: lowercase the (0x-prefixed) hash so casing variants
  # of the same transaction collapse to one entry.
  defp store_key(hash), do: @store_key_prefix <> String.downcase(hash)

  # Validates the :store config is a module implementing the Store behaviour.
  defp validate_store!(nil), do: :ok

  defp validate_store!({ConCacheStore, _opts}), do: validate_store!(ConCacheStore)

  defp validate_store!(ConCacheStore), do: :ok

  defp validate_store!({store, _opts}) do
    raise ArgumentError,
          "MPP.Methods.EVM :store tuple form is only supported for {MPP.Tempo.ConCacheStore, opts}; got: #{inspect(store)}"
  end

  defp validate_store!(store) do
    if !(is_atom(store) and function_exported?(store, :get, 1) and function_exported?(store, :put, 2)) do
      raise ArgumentError,
            "MPP.Methods.EVM :store must be a module implementing MPP.Tempo.Store (get/1, put/2)"
    end

    :ok
  end
end
