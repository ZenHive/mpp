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
    * `"chain_id"` — (required) EIP-155 chain ID of the target network,
      advertised as `chainId` in challenge `methodDetails` (e.g. `1` for
      Ethereum mainnet, `8453` for Base, `11155111` for Sepolia). Clients
      reject challenges whose `chainId` they do not support.
    * `"permit2_address"` — (optional) Permit2 contract advertised as
      `permit2Address` in challenge `methodDetails`. Defaults to the canonical
      deployment `0x000000000022D473030F116dDEE9F6B43aC78BA3`
    * `"store"` — (optional) replay-dedup store, **on by default** (see "Replay
      protection"): when absent, the app-started `MPP.Tempo.ConCacheStore` enforces
      single-use of each on-chain transaction hash out of the box. Pass a module
      implementing `MPP.Tempo.Store` (Redis/Postgres for multi-node) or
      `{MPP.Tempo.ConCacheStore, opts}`; a configured store MUST implement the atomic
      `check_and_mark/2`. Pass `store: false` to opt out (not recommended)
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

  Requires the `onchain` package for address validation and Transfer event parsing.
  """

  use MPP.Method
  use Descripex, namespace: "/methods"

  alias MPP.Errors
  alias MPP.Hex
  alias MPP.Intents.Charge
  alias MPP.Methods.Shared
  alias MPP.Receipt
  alias MPP.Tempo.ConCacheStore
  alias MPP.Tempo.Store

  require Logger

  # draft-evm-charge-00.md:276-291
  # (tempoxyz/mpp-specs@3fa03a9385fb4cc65b05815ba4acdaf5b0d9766a):
  # methodDetails.chainId is REQUIRED (EIP-155 chain ID).
  @required_config_keys ~w(rpc_url chain_id)
  @zero_address "0x0000000000000000000000000000000000000000"

  # draft-evm-charge-00.md:235 (canonical Permit2)
  @canonical_permit2_address "0x000000000022D473030F116dDEE9F6B43aC78BA3"

  # Single-use dedup: an EVM tx hash is namespaced separately from Tempo's
  # "mpp:charge:" keyspace so one shared store can back both methods without
  # cross-method key collisions.
  @dedup_store_error_detail "Dedup store error"
  @evm_rpc_error_detail "EVM RPC request failed"
  @store_key_prefix "mpp:evm:"
  @zero_amount_non_proof_detail "Zero-amount challenges require a proof credential"

  api(:method_name, "Return the payment method identifier for EVM.")

  @impl MPP.Method
  @spec method_name() :: String.t()
  def method_name, do: "evm"

  api(:credential_types, "Return the EVM charge payload types currently implemented: hash.")

  @impl MPP.Method
  @spec credential_types() :: [String.t()]
  def credential_types, do: ~w(hash)

  api(
    :validate_config!,
    "Validate EVM method_config at init time. Raises on missing `rpc_url` or `chain_id`.",
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
    store = Store.resolve(config["store"])

    with :ok <- reject_non_proof_for_zero_amount(charge),
         {:ok, hash} <- extract_hash(payload),
         {:ok, rpc_url} <- Shared.require_config(config, "rpc_url", "EVM"),
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
    "Return EVM-specific fields (`chainId`, `credentialTypes`, `permit2Address`) for the 402 challenge.",
    params: [
      charge: [
        kind: :value,
        description: "Charge struct with method_details containing required `chain_id` and optional `permit2_address`"
      ]
    ],
    returns: %{
      type: :map,
      description: "Map with required `chainId` (EIP-155), `credentialTypes`, and `permit2Address`"
    }
  )

  @impl MPP.Method
  @spec challenge_method_details(Charge.t()) :: map()
  def challenge_method_details(%Charge{} = charge) do
    config = charge.method_details || %{}

    details = %{
      "credentialTypes" => credential_types(),
      "permit2Address" => config["permit2_address"] || @canonical_permit2_address
    }

    case config["chain_id"] do
      nil -> details
      chain_id -> Map.put(details, "chainId", chain_id)
    end
  end

  # --- ERC-20 verification ---

  # Fetches the transaction receipt, parses Transfer logs, and finds a matching transfer.
  defp verify_erc20_transfer(hash, charge, rpc_url, config) do
    with {:ok, receipt} <- fetch_receipt(hash, rpc_url, config),
         :ok <- Shared.check_receipt_status(receipt),
         {:ok, _transfer} <- find_matching_transfer(receipt, charge) do
      {:ok, Receipt.new(method: "evm", reference: hash, external_id: charge.external_id)}
    end
  end

  # --- Native ETH verification ---

  # Fetches the transaction, checks value matches charge amount, and verifies recipient.
  defp verify_native_transfer(hash, charge, rpc_url, config) do
    with {:ok, receipt} <- fetch_receipt(hash, rpc_url, config),
         :ok <- Shared.check_receipt_status(receipt),
         {:ok, tx} <- fetch_transaction(hash, rpc_url, config),
         :ok <- check_native_transfer(tx, charge) do
      {:ok, Receipt.new(method: "evm", reference: hash, external_id: charge.external_id)}
    end
  end

  # Verifies a native ETH transfer: recipient and value must match the charge.
  defp check_native_transfer(tx, charge) do
    with {:ok, expected_amount} <- Shared.parse_charge_amount(charge.amount) do
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
    with {:ok, amount_int} <- Shared.parse_charge_amount(charge.amount),
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
      {:ok, nil} ->
        {:error, Errors.new(:verification_failed, "Transaction not found on-chain")}

      {:ok, receipt} ->
        {:ok, receipt}

      {:error, reason} ->
        Logger.warning("MPP.Methods.EVM: RPC get_transaction_receipt failed: #{inspect(reason)}")
        {:error, Errors.new(:verification_failed, @evm_rpc_error_detail)}
    end
  end

  defp fetch_transaction(hash, rpc_url, config) do
    case Onchain.RPC.get_transaction_by_hash(hash, rpc_opts(rpc_url, config)) do
      {:ok, nil} ->
        {:error, Errors.new(:verification_failed, "Transaction not found on-chain")}

      {:ok, tx} ->
        {:ok, tx}

      {:error, reason} ->
        Logger.warning("MPP.Methods.EVM: RPC get_transaction_by_hash failed: #{inspect(reason)}")
        {:error, Errors.new(:verification_failed, @evm_rpc_error_detail)}
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

  defp extract_hash(%{"hash" => hash}) when is_binary(hash) do
    hex = Hex.strip_0x(hash)

    if byte_size(hex) == 64 and Hex.hex_string?(hex) do
      {:ok, "0x" <> String.downcase(hex)}
    else
      {:error, Errors.new(:invalid_payload, "Invalid transaction hash format")}
    end
  end

  defp extract_hash(_) do
    {:error, Errors.new(:invalid_payload, "Missing or invalid 'hash' field in credential payload")}
  end

  # EVM verification requires a recipient address — fail fast if nil.
  defp require_recipient(%Charge{recipient: nil}),
    do: {:error, Errors.new(:verification_failed, "EVM method requires a recipient address")}

  defp require_recipient(%Charge{}), do: :ok

  defp reject_non_proof_for_zero_amount(%Charge{amount: "0"}) do
    {:error, Errors.new(:verification_failed, @zero_amount_non_proof_detail)}
  end

  defp reject_non_proof_for_zero_amount(_charge), do: :ok

  # Returns true if the currency represents native ETH (not an ERC-20 token).
  defp native_currency?(currency) when is_binary(currency) do
    down = String.downcase(currency)
    down == "eth" or down == String.downcase(@zero_address)
  end

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

  # Commits a hash as used AFTER successful on-chain verification, via the store's
  # atomic check_and_mark/2: concurrent same-hash requests collide here, so exactly
  # one wins and the loser gets "already used". Atomicity is guaranteed by
  # validate_store!/1 (a non-atomic store is rejected at init) — no fallback (GHSA-w8j7-7qc3-5f24).
  defp commit_hash_used(nil, _hash), do: :ok

  defp commit_hash_used(store, hash) do
    case Store.check_and_mark(store, store_key(hash), System.system_time(:millisecond)) do
      :ok -> :ok
      {:error, :already_exists} -> {:error, Errors.new(:verification_failed, "Transaction hash already used")}
      {:error, _reason} -> {:error, Errors.new(:verification_failed, @dedup_store_error_detail)}
    end
  end

  # Canonical dedup key: lowercase the (0x-prefixed) hash so casing variants
  # of the same transaction collapse to one entry.
  defp store_key(hash), do: @store_key_prefix <> String.downcase(hash)

  # Validates the :store config. `nil`/absent resolves to the default store (replay
  # protection on by default); `false` is an explicit opt-out. A configured store MUST
  # implement the atomic check_and_mark/2 — a non-atomic get/put store is rejected here
  # rather than silently degrading to a racy fallback (GHSA-w8j7-7qc3-5f24).
  defp validate_store!(nil), do: :ok
  defp validate_store!(false), do: :ok

  defp validate_store!({ConCacheStore, opts}) do
    if !Keyword.keyword?(opts) do
      raise ArgumentError,
            "MPP.Methods.EVM :store opts for {MPP.Tempo.ConCacheStore, opts} must be a keyword list; got: #{inspect(opts)}"
    end

    validate_store!(ConCacheStore)
  end

  defp validate_store!(ConCacheStore), do: :ok

  defp validate_store!({store, _opts}) do
    raise ArgumentError,
          "MPP.Methods.EVM :store tuple form is only supported for {MPP.Tempo.ConCacheStore, opts}; got: #{inspect(store)}"
  end

  defp validate_store!(store) do
    if !Store.dedup_capable?(store) do
      raise ArgumentError,
            "MPP.Methods.EVM :store must be a module implementing MPP.Tempo.Store " <>
              "(get/1, put/2, check_and_mark/2 — atomic single-use is required; use `store: false` to disable dedup)"
    end

    :ok
  end
end
