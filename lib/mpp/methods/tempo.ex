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
    * `"memo"` — (optional) bytes32 hex memo for `transferWithMemo`
    * `"wait_for_confirmation"` — (optional) when `false`, broadcasts without waiting
      for on-chain confirmation. Simulates via `eth_call` first to catch obvious reverts,
      then broadcasts async and returns an optimistic receipt. Default `true`.
    * `"store"` — (optional) module implementing `MPP.Tempo.Store` behaviour for
      transaction dedup, or `{MPP.Tempo.ConCacheStore, opts}` to configure the built-in
      ConCache store (for example a custom cache `:name`). Prevents replay by tracking
      used tx hashes. When `nil` (default), no dedup is performed — library stays stateless.

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
  alias MPP.Tempo.ConCacheStore
  alias MPP.Tempo.Transaction

  require Logger

  # onchain is optional — suppress unknown function warnings for its APIs.
  # Runtime availability is enforced by validate_config!/1 at Plug init time.
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
    validate_store!(config["store"])
    validate_fee_payer!(config)
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

    if config["fee_payer"] do
      {:error, Errors.new(:invalid_payload, ~s(type="hash" is not allowed when feePayer is true))}
    else
      memo = config["memo"]
      store = config["store"]

      with {:ok, hash} <- extract_hash(payload),
           :ok <- check_hash_unused(store, hash),
           {:ok, rpc_url} <- require_config(config, "rpc_url"),
           {:ok, receipt} <- fetch_receipt(hash, rpc_url, config),
           :ok <- check_receipt_status(receipt),
           {:ok, _transfer} <- find_matching_transfer(receipt, charge, memo),
           :ok <- mark_hash_used(store, hash) do
        {:ok, Receipt.new(method: "tempo", reference: hash, external_id: charge.external_id)}
      end
    end
  end

  def verify(%{"type" => "transaction"} = payload, %Charge{} = charge) do
    config = charge.method_details || %{}
    memo = config["memo"]
    store = config["store"]
    expected_chain_id = config["chain_id"] || @moderato_chain_id
    wait? = config["wait_for_confirmation"] != false

    with {:ok, signature} <- extract_signature(payload),
         {:ok, tx} <- Transaction.deserialize(signature),
         :ok <- verify_chain_id(tx, expected_chain_id),
         {:ok, %{call: payment_call}} <-
           Transaction.find_payment_call(tx, charge.currency,
             amount: charge.amount,
             recipient: charge.recipient,
             memo: memo
           ),
         :ok <- maybe_validate_call_scope(tx, config),
         {:ok, tx} <- maybe_cosign_fee_payer(tx, config),
         :ok <- reserve_hash_atomic(store, tx.raw),
         {:ok, rpc_url} <- require_config(config, "rpc_url"),
         {:ok, tx_hash} <- broadcast_and_verify(tx, rpc_url, config, charge, memo, wait?, payment_call) do
      # Post-broadcast: record on-chain hash if it differs from input (malleable variants).
      # Best-effort — payment already succeeded, so store failures don't fail the request.
      safe_dedup_post_broadcast(store, tx_hash, tx.raw)
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

  # Validates that the store config is a module implementing the Store behaviour.
  defp validate_store!(nil), do: :ok

  defp validate_store!({ConCacheStore, _opts}) do
    validate_store!(ConCacheStore)
  end

  defp validate_store!(ConCacheStore) do
    if !Code.ensure_loaded?(ConCache) do
      raise ArgumentError, """
      MPP.Tempo.ConCacheStore requires the `con_cache` package.

      Add it to your mix.exs dependencies:

          {:con_cache, "~> 1.1"}
      """
    end

    :ok
  end

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
  # Hash path (type="hash"): check → verify on-chain → mark. The hash is only
  # marked after successful verification so transient RPC failures don't burn
  # legitimate retries. Matches mppx (Charge.ts:126-141).
  #
  # Transaction path (type="transaction"): atomic reserve → verify → broadcast.
  # Must reserve BEFORE broadcast to prevent concurrent duplicate broadcasts of
  # the same signed tx. Matches mppx (Charge.ts:144-146).

  # TODO(Task 23): When extracting to onchain_tempo, consider switching to keccak256(raw_hex)
  # for fixed-length keys (matches mppx/mpp-rs convention). Currently using raw hex to avoid
  # adding a hash dependency.
  @store_key_prefix "mpp:charge:"

  # Checks if a hash has already been used (read-only). Used by hash path before verification.
  defp check_hash_unused(nil, _hash), do: :ok

  defp check_hash_unused(store, hash) do
    key = store_key(hash)

    case store_get(store, key) do
      :not_found -> :ok
      {:ok, _} -> {:error, Errors.new(:verification_failed, "Transaction hash already used")}
      {:error, reason} -> {:error, Errors.new(:verification_failed, "Dedup store error: #{inspect(reason)}")}
    end
  end

  # Marks a hash as used after successful verification. Used by hash path after on-chain check.
  defp mark_hash_used(nil, _hash), do: :ok

  defp mark_hash_used(store, hash) do
    key = store_key(hash)
    ts = System.system_time(:millisecond)

    case store_put(store, key, ts) do
      :ok -> :ok
      {:error, reason} -> {:error, Errors.new(:verification_failed, "Dedup store error: #{inspect(reason)}")}
    end
  end

  # Atomically checks and reserves a hash before broadcast. Used by transaction path.
  # Uses check_and_mark/2 when available (atomic); falls back to get + put.
  defp reserve_hash_atomic(nil, _hash), do: :ok

  defp reserve_hash_atomic(store, hash) do
    key = store_key(hash)
    ts = System.system_time(:millisecond)

    if store_supports_atomic?(store) do
      case store_check_and_mark(store, key, ts) do
        :ok -> :ok
        {:error, :already_exists} -> {:error, Errors.new(:verification_failed, "Transaction hash already used")}
        {:error, reason} -> {:error, Errors.new(:verification_failed, "Dedup store error: #{inspect(reason)}")}
      end
    else
      reserve_hash_sequential(store, key, ts)
    end
  end

  # Non-atomic fallback: check then mark as separate steps. Small race window.
  defp reserve_hash_sequential(store, key, ts) do
    case store_get(store, key) do
      :not_found ->
        case store_put(store, key, ts) do
          :ok -> :ok
          {:error, reason} -> {:error, Errors.new(:verification_failed, "Dedup store error: #{inspect(reason)}")}
        end

      {:ok, _} ->
        {:error, Errors.new(:verification_failed, "Transaction hash already used")}

      {:error, reason} ->
        {:error, Errors.new(:verification_failed, "Dedup store error: #{inspect(reason)}")}
    end
  end

  # Post-broadcast dedup: if the on-chain tx hash differs from the input hash
  # (malleable variants), record the on-chain hash too.
  # Payment already succeeded on-chain at this point — a store crash (e.g. dead
  # Agent process, network partition to Redis) must not fail the HTTP response.
  # The pre-broadcast reserve_hash_atomic is the critical gate; this is
  # supplementary protection against hash malleability.
  # Uses both rescue (exceptions) and catch (process exits from dead Agents/GenServers).
  # TODO: Replace Logger.warning with :telemetry.execute/3 when adding telemetry
  # events for the full verify lifecycle (e.g. [:mpp, :tempo, :store, :error]).
  defp safe_dedup_post_broadcast(nil, _tx_hash, _input_hash), do: :ok

  defp safe_dedup_post_broadcast(store, tx_hash, input_hash) do
    if String.downcase(tx_hash) != String.downcase(input_hash) do
      key = store_key(tx_hash)
      store_put(store, key, System.system_time(:millisecond))
    end

    :ok
  rescue
    exception ->
      Logger.warning("MPP.Methods.Tempo: post-broadcast dedup store failed: #{Exception.message(exception)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning("MPP.Methods.Tempo: post-broadcast dedup store exited: #{inspect(reason)}")
      :ok
  end

  defp store_get({ConCacheStore, opts}, key), do: ConCacheStore.get(key, opts)
  defp store_get(store, key), do: store.get(key)

  defp store_put({ConCacheStore, opts}, key, value), do: ConCacheStore.put(key, value, opts)
  defp store_put(store, key, value), do: store.put(key, value)

  defp store_check_and_mark({ConCacheStore, opts}, key, value), do: ConCacheStore.check_and_mark(key, value, opts)

  defp store_check_and_mark(store, key, value), do: store.check_and_mark(key, value)

  defp store_supports_atomic?({ConCacheStore, _opts}), do: true
  defp store_supports_atomic?(store), do: function_exported?(store, :check_and_mark, 2)

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

  # Dispatches between confirmation and optimistic broadcast paths.
  # Confirmation (default): broadcast sync → verify receipt logs.
  # Optimistic: simulate via eth_call → broadcast async → return tx hash without receipt verification.
  defp broadcast_and_verify(%Transaction{raw: raw_hex}, rpc_url, config, charge, memo, true = _wait?, _payment_call) do
    with {:ok, tx_hash, receipt} <- broadcast_transaction_sync(raw_hex, rpc_url, config),
         :ok <- check_receipt_status(receipt),
         {:ok, _transfer} <- find_matching_transfer(receipt, charge, memo) do
      {:ok, tx_hash}
    end
  end

  defp broadcast_and_verify(%Transaction{raw: raw_hex}, rpc_url, config, _charge, _memo, false = _wait?, payment_call) do
    with :ok <- simulate_payment_call(payment_call, rpc_url, config) do
      broadcast_transaction_async(raw_hex, rpc_url, config)
    end
  end

  # Simulates the matched payment call via eth_call to catch obvious reverts (insufficient
  # balance, invalid state) before broadcasting. Uses the call's target contract and ABI
  # calldata — NOT the raw serialized transaction. Matches mppx's viem_call approach
  # (Charge.ts:257-262) which passes structured transaction fields to eth_call.
  # Not a guarantee of on-chain success — blockchain state can change between simulation
  # and inclusion.
  defp simulate_payment_call(%{to: to, input: input}, rpc_url, config) do
    req_options = config["req_options"] || []

    # to is 20-byte binary, input is ABI-encoded calldata binary — hex-encode for JSON-RPC
    to_hex = "0x" <> Base.encode16(to, case: :lower)
    data_hex = "0x" <> Base.encode16(input, case: :lower)

    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "eth_call",
        "params" => [%{"to" => to_hex, "data" => data_hex}, "latest"],
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
      {:ok, %Req.Response{status: status, body: %{"result" => _}}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{body: %{"error" => error}}} ->
        {:error, Errors.new(:verification_failed, "Simulation failed: #{inspect(error)}")}

      {:error, exception} ->
        {:error, Errors.new(:verification_failed, "Simulation request failed: #{Exception.message(exception)}")}

      {:ok, %Req.Response{} = response} ->
        {:error, Errors.new(:verification_failed, "Unexpected simulation response (status #{response.status})")}
    end
  end

  # TODO(onchain_tempo): Extract broadcast_transaction_async/3 to OnchainTempo.RPC
  # Broadcasts a transaction via async eth_sendRawTransaction. Returns the tx hash
  # immediately without waiting for block inclusion. Used in optimistic mode.
  defp broadcast_transaction_async(raw_hex, rpc_url, config) do
    req_options = config["req_options"] || []

    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "eth_sendRawTransaction",
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
      {:ok, %Req.Response{status: status, body: %{"result" => tx_hash}}}
      when status in 200..299 and is_binary(tx_hash) ->
        {:ok, tx_hash}

      {:ok, %Req.Response{body: %{"error" => error}}} ->
        {:error, Errors.new(:verification_failed, "Broadcast failed: #{inspect(error)}")}

      {:error, exception} ->
        {:error, Errors.new(:verification_failed, "Broadcast request failed: #{Exception.message(exception)}")}

      {:ok, %Req.Response{} = response} ->
        {:error, Errors.new(:verification_failed, "Unexpected broadcast response (status #{response.status})")}
    end
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
  # Moderato emits `memo` as an indexed topic and `amount` in the data payload.
  @transfer_with_memo_sig "TransferWithMemo(address indexed from, address indexed to, uint256 amount, bytes32 indexed memo)"

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
