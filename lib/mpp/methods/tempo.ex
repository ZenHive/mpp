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
    * `"fee_payer"` — (optional) enable server-side fee sponsorship, defaults to `false`.
      When `true`, the server co-signs client transactions with domain `0x78` to pay
      transaction fees. Requires `"fee_payer_private_key"` and `"fee_token"`.
    * `"fee_payer_private_key"` — (required when `fee_payer: true`) hex-encoded 32-byte
      secp256k1 private key for the fee payer account
    * `"fee_token"` — (required when `fee_payer: true`) hex address of a USD-denominated
      TIP-20 token to use for fee payment (e.g., pathUSD)
    * `"fee_payer_policy"` — (optional, `fee_payer: true` only) map of sponsor
      ceilings overriding the per-chain defaults: `"max_gas"`,
      `"max_fee_per_gas"`, `"max_priority_fee_per_gas"`, `"max_total_fee"` (wei),
      and `"max_validity_window_seconds"` (seconds). Bounds the client-supplied
      gas fields and validity window before the server co-signs so a malicious
      client cannot drain the fee-payer wallet via inflated gas price, total fee
      budget, or a padded access list, nor hold a co-signed sponsorship
      broadcastable far into the future. See `MPP.Methods.Tempo.FeePayerPolicy`.
    * `"memo"` — (optional) bytes32 hex memo for `transferWithMemo`
    * `"wait_for_confirmation"` — (optional) when `false`, broadcasts without waiting
      for on-chain confirmation. Pre-simulates the full co-signed transaction via
      `eth_simulateV1` first (same guard as the default path) to reject a tx that would
      revert before broadcast, then broadcasts async and returns an optimistic receipt.
      Default `true`.
    * `"store"` — (optional) module implementing `MPP.Tempo.Store` behaviour for
      transaction dedup, or `{MPP.Tempo.ConCacheStore, opts}` to configure the built-in
      ConCache store (for example a custom cache `:name`). Prevents replay by tracking
      used tx hashes. When `nil` (default), no dedup is performed — library stays stateless.

  ## Credential Payload

  The credential `payload` map must contain one of:

    * `"type" => "hash"`, `"hash" => "0x..."` — transaction hash for receipt verification
    * `"type" => "transaction"`, `"signature" => "..."` — RLP-serialized signed Tempo Transaction

  ## Dependencies

  Requires the `onchain` and `onchain_tempo` packages (optional dependencies)
  for RPC calls, transfer log parsing, and 0x76 Tempo transaction handling.
  The method checks availability at init time via `validate_config!/1`.
  """

  use MPP.Method
  use Descripex, namespace: "/methods"

  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.Methods.Tempo.FeePayerPolicy
  alias MPP.Receipt
  alias MPP.Tempo.ConCacheStore
  alias MPP.Tempo.Store
  alias Onchain.Tempo.RPC
  alias Onchain.Tempo.Transaction
  alias Onchain.Tempo.Transfer

  require Logger

  @moderato_chain_id 42_431
  @required_config_keys ~w(rpc_url)
  @memo_hex_length 64
  @address_hex_length 40
  @attribution_memo_length 32
  @attribution_tag binary_part(ExSha3.keccak_256("mpp"), 0, 4)
  @attribution_version 1
  @attribution_server_fingerprint_length 10
  @attribution_client_fingerprint_length 10
  @attribution_nonce_length 7
  @dedup_store_error_detail "Dedup store error"
  @tempo_rpc_error_detail "Tempo RPC request failed"
  @simulation_rejected_detail "Pre-broadcast simulation rejected the transaction"
  @simulation_failed_detail "Pre-broadcast simulation failed"

  api(:method_name, "Return the payment method identifier for Tempo.")

  @impl MPP.Method
  @spec method_name() :: String.t()
  def method_name, do: "tempo"

  api(
    :validate_config!,
    "Validate Tempo method_config at init time. Raises on missing `rpc_url` or unavailable `onchain` / `onchain_tempo` dependencies.",
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
    validate_store!(config["store"])
    validate_fee_payer!(config)
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

    if config["fee_payer"] do
      {:error, Errors.new(:invalid_payload, ~s(type="hash" is not allowed when feePayer is true))}
    else
      memo = config["memo"]
      store = config["store"]
      expected_chain_id = config["chain_id"] || @moderato_chain_id

      with {:ok, source} <- parse_hash_credential_source(config["credential_source"], expected_chain_id),
           {:ok, hash} <- extract_hash(payload),
           :ok <- check_hash_unused(store, hash),
           {:ok, rpc_url} <- require_config(config, "rpc_url"),
           {:ok, receipt} <- rpc_fetch_receipt(hash, rpc_url, rpc_options(config)),
           :ok <- check_receipt_status(receipt),
           {:ok, _transfer} <- find_matching_transfer(receipt, charge, memo, source),
           :ok <- commit_hash_used(store, hash) do
        {:ok, Receipt.new(method: "tempo", reference: hash, external_id: charge.external_id)}
      end
    end
  end

  @impl MPP.Method
  @spec verify(map(), Charge.t()) :: {:ok, Receipt.t()} | {:error, Errors.t()}
  def verify(%{"type" => "transaction"} = payload, %Charge{} = charge) do
    config = charge.method_details || %{}
    memo = config["memo"]
    store = config["store"]
    expected_chain_id = config["chain_id"] || @moderato_chain_id
    wait? = config["wait_for_confirmation"] != false

    with {:ok, signature} <- extract_signature(payload),
         {:ok, tx} <- Transaction.deserialize(signature),
         :ok <- verify_chain_id(tx, expected_chain_id),
         {:ok, payment} <-
           Transaction.find_payment_call(tx, charge.currency,
             amount: charge.amount,
             recipient: charge.recipient,
             memo: memo
           ),
         :ok <- maybe_validate_call_scope(tx, config),
         :ok <- maybe_validate_fee_payer_economics(tx, config, expected_chain_id),
         {:ok, tx} <- maybe_cosign_fee_payer(tx, config),
         {:ok, _payment} <- check_matched_memo_binding(payment, config, memo),
         :ok <- reserve_hash_atomic(store, tx.raw),
         {:ok, rpc_url} <- require_config(config, "rpc_url"),
         {:ok, tx_hash} <- broadcast_and_verify(tx, rpc_url, config, charge, memo, wait?) do
      # Post-broadcast: record on-chain hash if it differs from input (malleable variants).
      # Best-effort — payment already succeeded, so store failures don't fail the request.
      safe_dedup_post_broadcast(store, tx_hash, tx.raw)
      {:ok, Receipt.new(method: "tempo", reference: tx_hash, external_id: charge.external_id)}
    else
      {:error, %Errors{} = error} -> {:error, error}
      {:error, reason} when is_binary(reason) -> {:error, Errors.new(:verification_failed, reason)}
    end
  end

  @impl MPP.Method
  @spec verify(map(), Charge.t()) :: {:error, Errors.t()}
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

  # Validates that the store config is a module implementing the Store behaviour.
  defp validate_store!(nil), do: :ok

  defp validate_store!({ConCacheStore, _opts}) do
    validate_store!(ConCacheStore)
  end

  defp validate_store!(ConCacheStore), do: :ok

  defp validate_store!({store, _opts}) do
    raise ArgumentError,
          "MPP.Methods.Tempo :store tuple form is only supported for {MPP.Tempo.ConCacheStore, opts}; got: #{inspect(store)}"
  end

  defp validate_store!(store) do
    if !(is_atom(store) and function_exported?(store, :get, 1) and function_exported?(store, :put, 2)) do
      raise ArgumentError,
            "MPP.Methods.Tempo :store must be a module implementing MPP.Tempo.Store (get/1, put/2)"
    end

    :ok
  end

  # --- Fee payer helpers ---

  # Validates fee payer config at init time. When fee_payer is enabled,
  # requires fee_payer_private_key (32-byte hex) and fee_token (20-byte hex address).
  defp validate_fee_payer!(%{"fee_payer" => true} = config) do
    key = config["fee_payer_private_key"]
    token = config["fee_token"]

    if !is_binary(key) or byte_size(strip_0x(key)) != 64 or !hex_string?(strip_0x(key)) do
      raise ArgumentError,
            "MPP.Methods.Tempo fee_payer requires \"fee_payer_private_key\" (32-byte hex string) in method_config"
    end

    if !is_binary(token) or byte_size(strip_0x(token)) != 40 or !hex_string?(strip_0x(token)) do
      raise ArgumentError,
            "MPP.Methods.Tempo fee_payer requires \"fee_token\" (20-byte hex address) in method_config"
    end

    :ok
  end

  defp validate_fee_payer!(_config), do: :ok

  # Validates call scope when fee_payer is enabled.
  # No-op when fee_payer is falsy — any call pattern is allowed for self-paying txs.
  defp maybe_validate_call_scope(tx, %{"fee_payer" => true}), do: Transaction.validate_call_scope(tx)

  defp maybe_validate_call_scope(_tx, _config), do: :ok

  # Bounds client-supplied gas economics when fee_payer is enabled, so a
  # malicious client cannot drain the server's wallet by embedding inflated
  # gas price / total fee / access list in the signed envelope the server
  # co-signs (GHSA-vv77-66rf-pm86, GHSA-qpxh-ff8m-c62v).
  # No-op when fee_payer is falsy — the client pays its own gas.
  defp maybe_validate_fee_payer_economics(tx, %{"fee_payer" => true} = config, chain_id) do
    policy = FeePayerPolicy.resolve(chain_id, config["fee_payer_policy"])
    FeePayerPolicy.validate(tx, policy)
  end

  defp maybe_validate_fee_payer_economics(_tx, _config, _chain_id), do: :ok

  # Co-signs transaction as fee payer when fee_payer is enabled.
  # No-op when fee_payer is falsy — passes transaction through unchanged.
  defp maybe_cosign_fee_payer(tx, %{"fee_payer" => true} = config) do
    with {:ok, key} <- decode_hex_key(config["fee_payer_private_key"]),
         {:ok, token} <- decode_hex_address(config["fee_token"]),
         :ok <- check_fee_payer_placeholder(tx),
         :ok <- check_fee_token_empty(tx) do
      Transaction.cosign_fee_payer(tx, key, token)
    end
  end

  defp maybe_cosign_fee_payer(tx, _config), do: {:ok, tx}

  defp check_fee_payer_placeholder(tx) do
    if Transaction.has_fee_payer_placeholder?(tx) do
      :ok
    else
      {:error, "Transaction missing fee_payer_signature placeholder (expected 0x00)"}
    end
  end

  defp check_fee_token_empty(tx) do
    if Transaction.fee_token_empty?(tx) do
      :ok
    else
      {:error, "Transaction must have empty fee_token when feePayer is true"}
    end
  end

  # Decodes a hex private key string to 32-byte binary.
  defp decode_hex_key(hex) when is_binary(hex) do
    case Base.decode16(strip_0x(hex), case: :mixed) do
      {:ok, <<key::binary-size(32)>>} -> {:ok, key}
      _ -> {:error, "Invalid fee_payer_private_key format"}
    end
  end

  defp decode_hex_key(_), do: {:error, "Missing fee_payer_private_key"}

  # Decodes a hex address string to 20-byte binary.
  defp decode_hex_address(hex) when is_binary(hex) do
    case Base.decode16(strip_0x(hex), case: :mixed) do
      {:ok, <<addr::binary-size(20)>>} -> {:ok, addr}
      _ -> {:error, "Invalid fee_token address format"}
    end
  end

  defp decode_hex_address(_), do: {:error, "Missing fee_token"}

  # --- Dedup store helpers ---
  # No-op when store is nil (library stays stateless by default).
  #
  # Hash path (type="hash"): check → verify on-chain → atomic commit. The early
  # read is a fast-path reject; the hash is committed via the store's atomic
  # check_and_mark AFTER successful verification, so concurrent requests carrying
  # the same confirmed hash collide at commit time (exactly one wins) while a
  # transient RPC failure still doesn't burn legitimate retries. This matches
  # mpp-rs verify_hash, which claims via atomic Store::put_if_absent only after
  # verifying the receipt (method.rs:789-799). mppx reaches the same single-use +
  # retriable guarantee the other way — reserve-before-verify with release-on-
  # failure (Charge.ts:215-273); our mark-after-verify avoids the compensating
  # release entirely.
  #
  # Transaction path (type="transaction"): atomic reserve → verify → broadcast.
  # Must reserve BEFORE broadcast to prevent concurrent duplicate broadcasts of
  # the same signed tx. Matches mppx (Charge.ts:144-146).

  @store_key_prefix "mpp:charge:"

  # Checks if a hash has already been used (read-only). Used by hash path before verification.
  defp check_hash_unused(nil, _hash), do: :ok

  defp check_hash_unused(store, hash) do
    key = store_key(hash)

    case store_get(store, key) do
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

    if store_supports_atomic?(store) do
      claim_atomic(store, key, ts)
    else
      case store_put(store, key, ts) do
        :ok -> :ok
        {:error, _reason} -> {:error, Errors.new(:verification_failed, @dedup_store_error_detail)}
      end
    end
  end

  # Atomically checks and reserves a hash before broadcast. Used by transaction path.
  # Uses check_and_mark/2 when available (atomic); falls back to get + put.
  defp reserve_hash_atomic(nil, _hash), do: :ok

  defp reserve_hash_atomic(store, hash) do
    key = store_key(hash)
    ts = System.system_time(:millisecond)

    if store_supports_atomic?(store) do
      claim_atomic(store, key, ts)
    else
      reserve_hash_sequential(store, key, ts)
    end
  end

  # Atomic single-use claim via the store's check_and_mark/2. Shared by the
  # pre-broadcast reserve (transaction path) and the post-verification commit
  # (hash path) — both treat :already_exists as a replay rejection.
  defp claim_atomic(store, key, ts) do
    case store_check_and_mark(store, key, ts) do
      :ok -> :ok
      {:error, :already_exists} -> {:error, Errors.new(:verification_failed, "Transaction hash already used")}
      {:error, _reason} -> {:error, Errors.new(:verification_failed, @dedup_store_error_detail)}
    end
  end

  # Non-atomic fallback: check then mark as separate steps. Small race window.
  defp reserve_hash_sequential(store, key, ts) do
    case store_get(store, key) do
      :not_found ->
        case store_put(store, key, ts) do
          :ok -> :ok
          {:error, _reason} -> {:error, Errors.new(:verification_failed, @dedup_store_error_detail)}
        end

      {:ok, _} ->
        {:error, Errors.new(:verification_failed, "Transaction hash already used")}

      {:error, _reason} ->
        {:error, Errors.new(:verification_failed, @dedup_store_error_detail)}
    end
  end

  # Post-broadcast dedup: if the on-chain tx hash differs from the input hash
  # (malleable variants), record the on-chain hash too.
  # Payment already succeeded on-chain at this point — a store crash (e.g. dead
  # Agent process, network partition to Redis) must not fail the HTTP response.
  # The pre-broadcast reserve_hash_atomic is the critical gate; this is
  # supplementary protection against hash malleability.
  # Uses both rescue (exceptions) and catch (process exits from dead Agents/GenServers).
  # Task 53 tracks replacing Logger.warning with :telemetry.execute/3 as part
  # of full verify lifecycle telemetry, e.g. [:mpp, :tempo, :store, :error].
  defp safe_dedup_post_broadcast(nil, _tx_hash, _input_hash), do: :ok

  defp safe_dedup_post_broadcast(store, tx_hash, input_hash) do
    if String.downcase(tx_hash) != String.downcase(input_hash) do
      key = store_key(tx_hash)
      store_put(store, key, System.system_time(:millisecond))
    end

    :ok
  rescue
    # Deliberately broad: a custom MPP.Tempo.Store may raise ANY exception struct
    # (e.g. %Redix.ConnectionError{} on a network partition — see the doc above).
    # Payment already settled on-chain, so this supplementary write must never
    # crash the response; narrowing to a fixed exception list would drop exactly
    # the infra failures this guard exists to absorb. Suppress reach's bare_rescue
    # smell at this one deliberate site rather than weaken the safety invariant.
    # reach:disable-next-line bare_rescue
    exception ->
      Logger.warning("MPP.Methods.Tempo: post-broadcast dedup store failed: #{Exception.message(exception)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning("MPP.Methods.Tempo: post-broadcast dedup store exited: #{inspect(reason)}")
      :ok
  end

  defp store_get(store, key), do: Store.get(store, key)

  defp store_put(store, key, value), do: Store.put(store, key, value)

  defp store_check_and_mark(store, key, value), do: Store.check_and_mark(store, key, value)

  defp store_supports_atomic?(store), do: Store.supports_atomic?(store)

  defp store_key(hash), do: @store_key_prefix <> String.downcase(hash)

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

  defp parse_hash_credential_source(nil, _expected_chain_id), do: {:ok, nil}

  defp parse_hash_credential_source("did:pkh:eip155:" <> source, expected_chain_id) do
    with [chain_id_string, address] <- String.split(source, ":", parts: 2),
         {^expected_chain_id, ""} <- Integer.parse(chain_id_string),
         {:ok, normalized_address} <- normalize_address(address) do
      {:ok, normalized_address}
    else
      _ -> {:error, Errors.new(:invalid_payload, "Hash credential source is invalid")}
    end
  end

  defp parse_hash_credential_source(_source, _expected_chain_id) do
    {:error, Errors.new(:invalid_payload, "Hash credential source is invalid")}
  end

  defp normalize_address(address) when is_binary(address) do
    hex = strip_0x(address)

    if byte_size(hex) == @address_hex_length and hex_string?(hex) do
      {:ok, "0x" <> String.downcase(hex)}
    else
      :error
    end
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

  # Dispatches between confirmation and optimistic broadcast paths. Both paths
  # simulate the full co-signed transaction before broadcasting (see
  # simulate_cosigned_tx/3) so a fee payer never pays gas for a transaction that
  # would revert.
  # Confirmation (default): simulate → broadcast sync → verify receipt logs.
  # Optimistic: simulate → broadcast async → return tx hash without receipt verification.
  defp broadcast_and_verify(%Transaction{raw: raw_hex}, rpc_url, config, charge, memo, true = _wait?) do
    rpc_opts = rpc_options(config)

    with :ok <- simulate_cosigned_tx(raw_hex, rpc_url, config),
         {:ok, tx_hash, receipt} <- rpc_broadcast_sync(raw_hex, rpc_url, rpc_opts),
         :ok <- check_receipt_status(receipt),
         {:ok, _transfer} <- find_matching_transfer(receipt, charge, memo, nil) do
      {:ok, tx_hash}
    end
  end

  defp broadcast_and_verify(%Transaction{raw: raw_hex}, rpc_url, config, _charge, _memo, false = _wait?) do
    rpc_opts = rpc_options(config)

    with :ok <- simulate_cosigned_tx(raw_hex, rpc_url, config) do
      rpc_broadcast_async(raw_hex, rpc_url, rpc_opts)
    end
  end

  # Simulates the FULL co-signed 0x76 transaction via eth_simulateV1 before
  # broadcasting. This is the fee-payer gas-drain DoS guard: a malicious client
  # can underfund gas_limit so the call runs out of gas on-chain — the sponsor's
  # fee-payer wallet is still charged for the gas burned while the client pays
  # nothing. Simulating the co-signed tx (recovered sender, folded AA call, gas
  # included) catches that BEFORE the sponsor commits gas, which the prior bare
  # eth_call on the payment call could not (it omitted gas entirely).
  #
  # onchain_tempo classifies the outcome (incl. folding eth_simulateV1's
  # -38xxx execution errors like "intrinsic gas too low" into {:revert, _}):
  #
  #   * {:ok, :success}     → would succeed; proceed to broadcast
  #   * {:ok, {:revert, _}} → would fail on-chain; reject before broadcast (the guard)
  #   * {:ok, :unsupported} → node lacks eth_simulateV1 (-32601); skip + log,
  #                           degrade gracefully, proceed
  #   * {:error, reason}    → operational RPC failure; fail closed — never
  #                           broadcast a transaction we could not validate
  defp simulate_cosigned_tx(raw_hex, rpc_url, config) do
    case RPC.simulate(raw_hex, rpc_url, rpc_options(config)) do
      {:ok, :success} ->
        :ok

      {:ok, {:revert, _detail}} ->
        {:error, Errors.new(:verification_failed, @simulation_rejected_detail)}

      {:ok, :unsupported} ->
        Logger.warning(
          "MPP.Methods.Tempo: node does not implement eth_simulateV1; skipping pre-broadcast fee-payer simulation guard"
        )

        :ok

      {:error, _reason} ->
        {:error, Errors.new(:verification_failed, @simulation_failed_detail)}
    end
  end

  # Gets a required key from the method_details config map.
  defp require_config(config, key) do
    case config[key] do
      nil -> {:error, Errors.new(:verification_failed, "Tempo method missing required config: #{key}")}
      value -> {:ok, value}
    end
  end

  # --- Onchain.Tempo.RPC adapter functions ---
  # Delegates to onchain_tempo and wraps string errors in MPP.Errors structs.

  defp rpc_options(config), do: [req_options: config["req_options"] || []]

  defp rpc_broadcast_async(raw_hex, rpc_url, opts) do
    case RPC.broadcast_async(raw_hex, rpc_url, opts) do
      {:ok, _tx_hash} = ok -> ok
      {:error, _msg} -> {:error, Errors.new(:verification_failed, @tempo_rpc_error_detail)}
    end
  end

  defp rpc_broadcast_sync(raw_hex, rpc_url, opts) do
    case RPC.broadcast_sync(raw_hex, rpc_url, opts) do
      {:ok, _tx_hash, _receipt} = ok -> ok
      {:error, _msg} -> {:error, Errors.new(:verification_failed, @tempo_rpc_error_detail)}
    end
  end

  defp rpc_fetch_receipt(hash, rpc_url, opts) do
    case RPC.fetch_receipt(hash, rpc_url, opts) do
      {:ok, _receipt} = ok -> ok
      {:error, _msg} -> {:error, Errors.new(:verification_failed, @tempo_rpc_error_detail)}
    end
  end

  # Verifies that the transaction succeeded (status 0x1).
  defp check_receipt_status(%{status: 1}), do: :ok

  defp check_receipt_status(%{status: _}) do
    {:error, Errors.new(:verification_failed, "Transaction failed on-chain (reverted)")}
  end

  # Finds a matching transfer event. When memo is configured, requires TransferWithMemo
  # with matching memo. When no memo, accepts both Transfer and TransferWithMemo events.
  # Spec: draft-tempo-charge-00.md §Transaction Verification, lines 395-399.
  defp find_matching_transfer(receipt, charge, memo, source)

  defp find_matching_transfer(%{logs: logs}, %Charge{} = charge, nil, source) do
    # No memo configured — accept Transfer OR TransferWithMemo matching token/recipient/amount.
    with {:ok, amount_int} <- parse_charge_amount(charge.amount),
         {:ok, transfers} <- Onchain.Transfer.parse_logs(logs) do
      # Also check TransferWithMemo events (onchain only parses standard Transfer)
      memo_transfers = Transfer.parse_transfer_with_memo_logs(logs)

      match =
        Enum.find(memo_transfers ++ transfers, fn transfer ->
          Onchain.Address.equal?(transfer.token, charge.currency) and
            Onchain.Address.equal?(transfer.to, charge.recipient) and
            transfer.amount == amount_int and
            transfer_source_matches?(transfer, source) and
            transfer_memo_bound?(transfer, charge)
        end)

      case match do
        nil -> {:error, Errors.new(:verification_failed, "No matching Transfer event found in transaction")}
        transfer -> check_matched_memo_binding(transfer, charge.method_details || %{}, nil)
      end
    end
  end

  defp find_matching_transfer(%{logs: logs}, %Charge{} = charge, memo, source) when is_binary(memo) do
    # Memo configured — MUST match TransferWithMemo with matching memo value.
    with {:ok, amount_int} <- parse_charge_amount(charge.amount) do
      normalized_memo = String.downcase(strip_0x(memo))

      match =
        logs
        |> Transfer.parse_transfer_with_memo_logs()
        |> Enum.find(fn transfer ->
          Onchain.Address.equal?(transfer.token, charge.currency) and
            Onchain.Address.equal?(transfer.to, charge.recipient) and
            transfer.amount == amount_int and
            String.downcase(strip_0x(transfer.memo)) == normalized_memo and
            transfer_source_matches?(transfer, source)
        end)

      case match do
        nil ->
          {:error, Errors.new(:verification_failed, "No matching TransferWithMemo event found in transaction")}

        transfer ->
          {:ok, transfer}
      end
    end
  end

  defp transfer_source_matches?(_transfer, nil), do: true

  defp transfer_source_matches?(transfer, source) do
    Onchain.Address.equal?(transfer.from, source)
  end

  defp transfer_memo_bound?(transfer, %Charge{method_details: config}) do
    case {Map.has_key?(transfer, :memo), config || %{}} do
      {true, %{"challenge_id" => challenge_id, "realm" => realm}} ->
        attribution_memo_bound?(transfer.memo, realm, challenge_id)

      {true, _config} ->
        true

      {false, %{"challenge_id" => _challenge_id, "realm" => _realm}} ->
        false

      {false, _config} ->
        true
    end
  end

  defp check_matched_memo_binding(match, _config, memo) when is_binary(memo), do: {:ok, match}

  defp check_matched_memo_binding(match, %{"challenge_id" => challenge_id, "realm" => realm}, nil) do
    case Map.fetch(match, :memo) do
      {:ok, memo} ->
        if attribution_memo_bound?(memo, realm, challenge_id) do
          {:ok, match}
        else
          {:error, Errors.new(:verification_failed, "Payment memo is not bound to this challenge")}
        end

      :error ->
        {:error, Errors.new(:verification_failed, "Payment memo is not bound to this challenge")}
    end
  end

  defp check_matched_memo_binding(match, _config, nil), do: {:ok, match}

  defp attribution_memo_bound?(memo, realm, challenge_id) do
    with {:ok, bytes} <- decode_memo(memo),
         {:ok, server, nonce} <- decode_attribution_parts(bytes) do
      server == binary_part(ExSha3.keccak_256(realm), 0, @attribution_server_fingerprint_length) and
        nonce == binary_part(ExSha3.keccak_256(challenge_id), 0, @attribution_nonce_length)
    else
      _ -> false
    end
  end

  defp decode_attribution_parts(<<@attribution_tag, @attribution_version, rest::binary>>) do
    server = binary_part(rest, 0, @attribution_server_fingerprint_length)
    nonce_offset = @attribution_server_fingerprint_length + @attribution_client_fingerprint_length
    nonce = binary_part(rest, nonce_offset, @attribution_nonce_length)

    {:ok, server, nonce}
  end

  defp decode_attribution_parts(_bytes), do: :error

  defp decode_memo(memo) when is_binary(memo) do
    case Base.decode16(strip_0x(memo), case: :mixed) do
      {:ok, <<_::binary-size(@attribution_memo_length)>> = bytes} -> {:ok, bytes}
      _ -> :error
    end
  end

  defp decode_memo(_memo), do: :error

  # Parses charge amount string to integer safely.
  defp parse_charge_amount(amount) do
    case Integer.parse(amount) do
      {int, ""} -> {:ok, int}
      _ -> {:error, Errors.new(:verification_failed, "Invalid charge amount: not a valid integer")}
    end
  end

  # Strips the optional "0x" prefix from a hex string.
  defp strip_0x("0x" <> rest), do: rest
  defp strip_0x(hex), do: hex

  # Checks if a string contains only hex characters.
  defp hex_string?(str), do: Regex.match?(~r/\A[0-9a-fA-F]+\z/, str)
end
