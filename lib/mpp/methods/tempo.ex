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
      transaction fees. Requires `"fee_payer_private_key"` and `"fee_token"`, unless
      `"fee_payer_url"` is set for hosted sponsorship. Sponsorship also requires an
      explicitly selected atomic `"store"`.
    * `"fee_payer_url"` — (optional) URL of a hosted fee-payer service that implements
      `eth_fillTransaction`. When set, the server delegates co-signing to the remote
      endpoint instead of using `"fee_payer_private_key"`. Mutually exclusive with the
      local key path.
    * `"sponsor_budget_id"` — required with `"fee_payer_url"`; stable identity shared
      by every endpoint using the same hosted sponsor wallet. It is normalized before
      use and should normally be that wallet's address.
    * `"fee_payer_private_key"` — (required when `fee_payer: true` and no `fee_payer_url`)
      hex-encoded 32-byte
      secp256k1 private key for the fee payer account
    * `"fee_token"` — (required for local co-sign when `fee_payer: true` and no
      `fee_payer_url`) hex address of a USD-denominated
      TIP-20 token to use for fee payment (e.g., pathUSD). Must be on the sponsor
      allowlist (`fee_payer_allowed_fee_tokens` or per-chain defaults).
    * `"fee_payer_allowed_fee_tokens"` — (optional, `fee_payer: true` only) list of
      hex addresses overriding the default sponsor fee-token allowlist.
    * `"fee_payer_policy"` — (optional, `fee_payer: true` only) map of sponsor
      ceilings overriding the per-chain defaults: `"max_gas"`,
      `"max_fee_per_gas"`, `"max_priority_fee_per_gas"`, `"max_total_fee"` (wei),
      and `"max_validity_window_seconds"` (seconds). Bounds the client-supplied
      gas fields and validity window before the server co-signs so a malicious
      client cannot drain the fee-payer wallet via inflated gas price, total fee
      budget, or a padded access list, nor hold a co-signed sponsorship
      broadcastable far into the future. The same map accepts
      `"max_in_flight_total_fee"` and `"max_in_flight_reservations"` for aggregate
      worst-case exposure. See `MPP.Methods.Tempo.FeePayerPolicy`.
    * `"sponsor_budget_reconcile"` — (optional, defaults to `false`) when `true`, an
      at-capacity request checks a bounded set of pending async transaction receipts
      before rejecting.
    * `"memo"` — (optional) bytes32 hex memo for `transferWithMemo`
    * `"wait_for_confirmation"` — (optional) when `false`, broadcasts without waiting
      for on-chain confirmation. Pre-simulates the full co-signed transaction via
      `eth_simulateV1` first (same guard as the default path) to reject a tx that would
      revert before broadcast, then broadcasts async and returns an optimistic receipt.
      Default `true`.
    * `"store"` — (optional) replay-dedup store. **On by default** — when absent, the
      app-started `MPP.Tempo.ConCacheStore` is used so replay protection is enabled out of
      the box (issue #7). Pass a module implementing `MPP.Tempo.Store` (Redis,
      Postgres, etc. — for multi-node deployments) or `{MPP.Tempo.ConCacheStore, opts}` to
      configure the built-in store (for example a custom cache `:name`). A configured store
      MUST implement the atomic `check_and_mark/2`. Pass `store: false` to explicitly opt out
      of dedup (not recommended; incompatible with a static `"memo"`).
      Fee sponsorship is stricter: the store must be selected explicitly and implement
      atomic `update/3`. `MPP.Tempo.ConCacheStore` provides a single-node bound. Every
      node and endpoint sponsoring the same wallet must use the same physical shared
      atomic backend for a cluster-wide bound.
    * `"machine_token_enabled"` — (optional) advertise and verify first-party
      machine-token (MPP Credits / machineUSD) charge payments. When `true`, 402
      method details include `"machineTokenEnabled" => true`, hash receipts may
      settle from the canonical swapper, and `type="transaction"` credentials may
      match the exact `[approve, swapTo]` route. Supported only on Tempo mainnet
      (`4217`) and Moderato (`42431`). Defaults to `false`.
    * `"require_presenter_binding"` — (optional) require `type="hash"` and
      `type="transaction"` credential presenters to prove control of the transfer's
      sender wallet via a `"presenterSignature"` payload field (see *Presenter
      binding* below). Defaults to `false`.

  ## Credential Payload

  The credential `payload` map must contain one of:

    * `"type" => "hash"`, `"hash" => "0x..."` — transaction hash for receipt verification
    * `"type" => "transaction"`, `"signature" => "..."` — RLP-serialized signed Tempo Transaction

  Both may additionally carry `"presenterSignature" => "0x..."` (see below).

  ## Recurring subscriptions

  Routes configured with `intent: "subscription"` use the shared
  `MPP.Intents.Subscription` schema and delegate activation and renewal to
  `MPP.Methods.Tempo.Subscription`. Subscription configuration requires
  `"rpc_url"`, `"chain_id"`, and `"subscription_access_key_private_key"`.
  It accepts a `"subscription_store"` implementing `MPP.Subscription.Store`;
  the application-started `MPP.Subscription.ETSStore` is the single-node
  default. Subscription fee sponsorship supports the local fee-payer path,
  not `"fee_payer_url"`.

  ## Presenter Binding

  On the hash/transaction paths, dedup is keyed on the tx hash alone — nothing in the
  base protocol proves the credential *presenter* controls the wallet that broadcast
  the transfer, so a third party who observes a settled transfer can race its hash
  against their own fresh challenge (the residual documented in GHSA-34g7-vx6g-82mq).
  Setting `"require_presenter_binding" => true` closes that race: the presenter must
  include `"presenterSignature"`, an EIP-712 signature over the same `Proof` typed
  data the `type="proof"` path uses (domain `{name: "MPP", version: "3", chainId}`,
  struct `{account, challengeId, realm}` — see `MPP.Methods.Tempo.Proof`), signed by
  the transfer sender's wallet or one of its authorized access keys.

    * `type="hash"` — the credential's top-level `source` (a `did:pkh:eip155:` DID)
      is required and names the account; the signature must recover to it, and the
      matched transfer's `from` must equal it (or, when `"machine_token_enabled"`
      is set, equal the canonical swapper while the transaction sender equals it).
    * `type="transaction"` — the account is the sender recovered from the signed
      transaction itself; a `source`, when present, must match it.

  When the flag is off (default) a supplied `"presenterSignature"` is still verified
  (an invalid one is rejected), so compliant clients can send it unconditionally.
  The requirement is advertised to clients as `"presenterBinding" => true` in the
  402 challenge's method details.

  This is a deliberate hardening extension beyond the reference SDKs: neither mpp-rs
  nor mppx binds the presenter on the hash path (both default the expected sender to
  the receipt's `from` — `refs/mpp-rs/src/protocol/methods/tempo/method.rs` `verify_hash`,
  `refs/mppx/src/tempo/server/Charge.ts` hash branch), which is why it is opt-in.

  ## Dependencies

  Requires the `onchain` and `onchain_tempo` packages for RPC calls, transfer log
  parsing, and 0x76 Tempo transaction handling.
  """

  use MPP.Method
  use Descripex, namespace: "/methods"

  alias MPP.DID
  alias MPP.Errors
  alias MPP.Hex
  alias MPP.Intents.Charge
  alias MPP.Intents.Subscription
  alias MPP.Methods.Shared
  alias MPP.Methods.Tempo.AccessKey
  alias MPP.Methods.Tempo.EnvelopeFields, as: TxFields
  alias MPP.Methods.Tempo.FeePayerPolicy
  alias MPP.Methods.Tempo.HostedFeePayer
  alias MPP.Methods.Tempo.MachineToken
  alias MPP.Methods.Tempo.Proof
  alias MPP.Methods.Tempo.SponsorBudget
  alias MPP.Methods.Tempo.Subscription, as: TempoSubscription
  alias MPP.Receipt
  alias MPP.Tempo.ConCacheStore
  alias MPP.Tempo.Store
  alias Onchain.Signer
  alias Onchain.Tempo.RPC
  alias Onchain.Tempo.Transaction
  alias Onchain.Tempo.Transfer

  require Logger

  @moderato_chain_id 42_431
  @required_config_keys ~w(rpc_url)
  @memo_hex_length 64
  @attribution_memo_length 32
  @attribution_tag binary_part(ExSha3.keccak_256("mpp"), 0, 4)
  @attribution_version 1
  @attribution_server_fingerprint_length 10
  @attribution_client_fingerprint_length 10
  @attribution_nonce_length 7
  @dedup_store_error_detail "Dedup store error"
  @store_key_prefix "mpp:charge:"
  @proof_store_key_prefix "mpp:proof:"
  @tempo_rpc_error_detail "Tempo RPC request failed"
  @simulation_rejected_detail "Pre-broadcast simulation rejected the transaction"
  @simulation_failed_detail "Pre-broadcast simulation failed"
  @sponsor_budget_unavailable_detail "Tempo sponsorship is temporarily unavailable"
  @sponsor_capacity_detail "Tempo sponsor capacity is temporarily unavailable"

  api(:method_name, "Return the payment method identifier for Tempo.")

  @impl MPP.Method
  @spec method_name() :: String.t()
  def method_name, do: "tempo"

  api(:credential_types, "Return the Tempo charge payload types: hash, transaction, and proof.")

  @impl MPP.Method
  @spec credential_types() :: [String.t()]
  def credential_types, do: ~w(hash transaction proof keyAuthorization)

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
    validate_memo_store_binding!(config)
    validate_fee_payer!(config)
    validate_sponsor_budget!(config)
    validate_fee_payer_allowed_tokens!(config)
    validate_presenter_binding!(config["require_presenter_binding"])
    validate_machine_token!(config)
    if config["intent"] == "subscription", do: TempoSubscription.validate_config!(config)
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
    errors: [:invalid_payload, :verification_failed, :sponsor_capacity_exhausted]
  )

  @impl MPP.Method
  @spec verify(map(), Charge.t()) :: {:ok, Receipt.t()} | {:error, Errors.t()}
  def verify(%{"type" => "hash"} = payload, %Charge{} = charge) do
    config = charge.method_details || %{}

    with :ok <- reject_non_proof_for_zero_amount(charge, "hash"),
         :ok <- reject_hash_when_fee_payer(config) do
      verify_hash_credential(payload, charge, config)
    end
  end

  @impl MPP.Method
  @spec verify(map(), Charge.t()) :: {:ok, Receipt.t()} | {:error, Errors.t()}
  def verify(%{"type" => "transaction"} = payload, %Charge{} = charge) do
    config = charge.method_details || %{}

    with :ok <- reject_non_proof_for_zero_amount(charge, "transaction") do
      verify_transaction_credential(payload, charge, config)
    end
  end

  @impl MPP.Method
  @spec verify(map(), Charge.t()) :: {:ok, Receipt.t()} | {:error, Errors.t()}
  def verify(%{"type" => "proof"} = payload, %Charge{} = charge) do
    config = charge.method_details || %{}
    store = Store.resolve(config["store"])
    expected_chain_id = config["chain_id"] || @moderato_chain_id

    with :ok <- require_zero_amount(charge),
         {:ok, signature} <- extract_proof_signature(payload),
         {:ok, source} <- require_proof_source(config["credential_source"]),
         {:ok, parsed} <- parse_proof_source(source, expected_chain_id),
         :ok <- verify_proof_signature(parsed, config, signature),
         :ok <- commit_proof_used(store, config["challenge_id"]) do
      reference = config["challenge_id"] || "proof"
      {:ok, Receipt.new(method: "tempo", reference: reference, external_id: charge.external_id)}
    end
  end

  @impl MPP.Method
  @spec verify(map(), Subscription.t()) :: {:ok, Receipt.t()} | {:error, Errors.t()}
  def verify(payload, %Subscription{} = subscription), do: TempoSubscription.verify(payload, subscription)

  @impl MPP.Method
  @spec verify(map(), Charge.t()) :: {:error, Errors.t()}
  def verify(_payload, %Charge{}) do
    {:error,
     Errors.new(:invalid_payload, ~s(Missing or invalid 'type' field — expected "hash", "transaction", or "proof"))}
  end

  defp verify_hash_credential(payload, charge, config) do
    memo = config["memo"]
    store = Store.resolve(config["store"])
    expected_chain_id = config["chain_id"] || @moderato_chain_id

    with {:ok, source} <- parse_hash_credential_source(config["credential_source"], expected_chain_id),
         {:ok, hash} <- extract_hash(payload),
         :ok <- check_hash_unused(store, hash),
         :ok <- verify_hash_presenter_binding(payload, source, expected_chain_id, config),
         {:ok, rpc_url} <- Shared.require_config(config, "rpc_url", "Tempo"),
         {:ok, receipt} <- rpc_fetch_receipt(hash, rpc_url, rpc_options(config)),
         :ok <- Shared.check_receipt_status(receipt),
         {:ok, sender_policy} <- hash_sender_policy(hash, rpc_url, config),
         {:ok, _transfer} <- find_matching_transfer(receipt, charge, memo, source, sender_policy),
         :ok <- commit_hash_used(store, hash) do
      {:ok, Receipt.new(method: "tempo", reference: hash, external_id: charge.external_id)}
    end
  end

  defp verify_transaction_credential(payload, charge, config) do
    memo = config["memo"]
    store = Store.resolve(config["store"])
    expected_chain_id = config["chain_id"] || @moderato_chain_id
    wait? = config["wait_for_confirmation"] != false

    result =
      with {:ok, signature} <- extract_signature(payload),
           {:ok, tx} <- Transaction.deserialize(signature),
           :ok <- verify_chain_id(tx, expected_chain_id),
           :ok <- verify_transaction_presenter_binding(payload, tx, expected_chain_id, config),
           {:ok, payment} <- find_transaction_payment(tx, charge, config, memo),
           :ok <- maybe_validate_call_scope(tx, config, payment),
           {:ok, budget} <- maybe_reserve_sponsor_budget(tx, config, expected_chain_id) do
        verify_transaction_after_budget(tx, payment, charge, config, memo, store, wait?, budget)
      end

    case result do
      {:error, %Errors{} = error} -> {:error, error}
      {:error, reason} when is_binary(reason) -> {:error, Errors.new(:verification_failed, reason)}
      other -> other
    end
  end

  api(
    :challenge_method_details,
    "Return Tempo-specific fields (`chainId`, `feePayer`, `memo`, `machineTokenEnabled`, `presenterBinding`) for the 402 challenge.",
    params: [
      charge: [
        kind: :value,
        description: "Charge struct with method_details containing `chain_id`, `fee_payer`, and optionally `memo`"
      ]
    ],
    returns: %{
      type: :map,
      description:
        "Map with `chainId` (default 42431), `feePayer` (default false), optional `memo`, `machineTokenEnabled` (present and `true` only when enabled), and `presenterBinding` (present and `true` only when required)"
    }
  )

  @impl MPP.Method
  @spec challenge_method_details(Charge.t()) :: map()
  def challenge_method_details(%Charge{} = charge) do
    config = charge.method_details || %{}

    details = %{
      "chainId" => config["chain_id"] || @moderato_chain_id,
      "feePayer" => fee_payer_enabled?(config)
    }

    details =
      case config["memo"] do
        nil -> details
        memo -> Map.put(details, "memo", memo)
      end

    details =
      if machine_token_enabled?(config) do
        Map.put(details, "machineTokenEnabled", true)
      else
        details
      end

    if presenter_binding_required?(config) do
      Map.put(details, "presenterBinding", true)
    else
      details
    end
  end

  @impl MPP.Method
  @spec challenge_method_details(Subscription.t()) :: map()
  def challenge_method_details(%Subscription{} = subscription),
    do: TempoSubscription.challenge_method_details(subscription)

  # --- Private helpers ---

  # Validates the store config. `nil`/absent resolves to the default store (replay
  # protection on by default); `false` is an explicit opt-out. A configured store
  # MUST implement the atomic check_and_mark/2 — a non-atomic get/put store is
  # rejected here rather than silently degrading to a racy fallback (GHSA-w8j7-7qc3-5f24).
  defp validate_store!(nil), do: :ok
  defp validate_store!(false), do: :ok

  defp validate_store!({ConCacheStore, opts}) do
    if !Keyword.keyword?(opts) do
      raise ArgumentError,
            "MPP.Methods.Tempo :store opts for {MPP.Tempo.ConCacheStore, opts} must be a keyword list; got: #{inspect(opts)}"
    end

    validate_store!(ConCacheStore)
  end

  defp validate_store!(ConCacheStore), do: :ok

  defp validate_store!({store, _opts}) do
    raise ArgumentError,
          "MPP.Methods.Tempo :store tuple form is only supported for {MPP.Tempo.ConCacheStore, opts}; got: #{inspect(store)}"
  end

  defp validate_store!(store) do
    if !Store.dedup_capable?(store) do
      raise ArgumentError,
            "MPP.Methods.Tempo :store must be a module implementing MPP.Tempo.Store " <>
              "(get/1, put/2, check_and_mark/2 — atomic single-use is required; use `store: false` to disable dedup)"
    end

    :ok
  end

  # --- Fee payer helpers ---

  # A static `memo` disables the automatic per-challenge attribution binding that the
  # no-memo path relies on (the memo can't hold both a fixed value and a challenge-bound
  # nonce). Without a dedup `store`, any third party can replay a publicly-observable
  # matching TransferWithMemo they never signed. Dedup is on by default, so this only
  # bites when the operator has explicitly opted out (`store: false`) — reject that
  # combination. Matches mpp-rs's store-on-by-default backstop (refs/mpp-rs/src/server/tempo.rs).
  defp validate_memo_store_binding!(%{"memo" => memo} = config) when is_binary(memo) do
    if is_nil(Store.resolve(config["store"])) do
      raise ArgumentError,
            ~s{MPP.Methods.Tempo: a static "memo" requires dedup, but you disabled it with `store: false` — } <>
              "without single-use enforcement, a publicly-observable matching transfer can be replayed by a " <>
              "third party. Remove `store: false` (dedup is on by default) or omit the static memo to use " <>
              "challenge-bound attribution."
    end

    :ok
  end

  defp validate_memo_store_binding!(_config), do: :ok

  defp validate_fee_payer!(%{"fee_payer_url" => url} = config) when is_binary(url) do
    if config["fee_payer_private_key"] || config["fee_token"] do
      raise ArgumentError,
            "MPP.Methods.Tempo fee_payer_url cannot be combined with fee_payer_private_key or fee_token"
    end

    if !valid_fee_payer_url?(url) do
      raise ArgumentError,
            "MPP.Methods.Tempo fee_payer_url must be an http or https URL"
    end

    :ok
  end

  # Validates fee payer config at init time. When fee_payer is enabled locally,
  # requires fee_payer_private_key (32-byte hex) and fee_token (20-byte hex address).
  defp validate_fee_payer!(%{"fee_payer" => true} = config) do
    key = config["fee_payer_private_key"]
    token = config["fee_token"]

    if !is_binary(key) or byte_size(Hex.strip_0x(key)) != 64 or !Hex.hex_string?(Hex.strip_0x(key)) do
      raise ArgumentError,
            "MPP.Methods.Tempo fee_payer requires \"fee_payer_private_key\" (32-byte hex string) in method_config"
    end

    if !is_binary(token) or byte_size(Hex.strip_0x(token)) != 40 or !Hex.hex_string?(Hex.strip_0x(token)) do
      raise ArgumentError,
            "MPP.Methods.Tempo fee_payer requires \"fee_token\" (20-byte hex address) in method_config"
    end

    :ok
  end

  defp validate_fee_payer!(_config), do: :ok

  defp validate_sponsor_budget!(config) do
    if fee_payer_enabled?(config) do
      validate_explicit_sponsor_store!(config)
      validate_sponsor_budget_limits!(config)
      validate_sponsor_identity!(config)
    else
      :ok
    end
  end

  defp validate_explicit_sponsor_store!(config) do
    case Map.fetch(config, "store") do
      {:ok, store_config} when not is_nil(store_config) and store_config != false ->
        store = Store.resolve(store_config)

        if !Store.update_capable?(store) do
          raise ArgumentError,
                "MPP.Methods.Tempo sponsorship requires an explicitly selected atomic store implementing update/3"
        end

      _other ->
        raise ArgumentError,
              "MPP.Methods.Tempo sponsorship requires an explicit store; select MPP.Tempo.ConCacheStore for one node or a shared atomic backend for multiple nodes"
    end
  end

  defp validate_sponsor_budget_limits!(config) do
    overrides = config["fee_payer_policy"]

    if !is_nil(overrides) and !is_map(overrides) do
      raise ArgumentError, "MPP.Methods.Tempo fee_payer_policy must be a map"
    end

    overrides = overrides || %{}

    Enum.each(~w(max_in_flight_total_fee max_in_flight_reservations), fn key ->
      if Map.has_key?(overrides, key) and !(is_integer(overrides[key]) and overrides[key] > 0) do
        raise ArgumentError, "MPP.Methods.Tempo fee_payer_policy #{key} must be a positive integer"
      end
    end)

    chain_id = config["chain_id"] || @moderato_chain_id
    policy = FeePayerPolicy.resolve(chain_id, overrides)

    if policy.max_total_fee > policy.max_in_flight_total_fee do
      raise ArgumentError,
            "MPP.Methods.Tempo max_in_flight_total_fee must be greater than or equal to max_total_fee"
    end
  end

  defp validate_sponsor_identity!(%{"fee_payer_url" => url} = config) when is_binary(url) do
    case normalize_sponsor_id(config["sponsor_budget_id"]) do
      {:ok, _sponsor_id} ->
        :ok

      {:error, _reason} ->
        raise ArgumentError, "MPP.Methods.Tempo hosted sponsorship requires a non-empty sponsor_budget_id"
    end
  end

  defp validate_sponsor_identity!(%{"fee_payer" => true} = config) do
    case local_sponsor_id(config) do
      {:ok, _sponsor_id} -> :ok
      {:error, _reason} -> raise ArgumentError, "MPP.Methods.Tempo could not derive the local sponsor identity"
    end
  end

  defp validate_sponsor_identity!(_config), do: :ok

  defp validate_fee_payer_allowed_tokens!(config) do
    if fee_payer_enabled?(config) do
      validate_fee_payer_allowed_tokens_list!(config["fee_payer_allowed_fee_tokens"])
    else
      :ok
    end
  end

  defp validate_fee_payer_allowed_tokens_list!(nil), do: :ok

  defp validate_fee_payer_allowed_tokens_list!(tokens) when is_list(tokens) do
    if Enum.all?(tokens, &valid_fee_token_address?/1) do
      :ok
    else
      raise ArgumentError,
            "MPP.Methods.Tempo fee_payer_allowed_fee_tokens must be a list of 20-byte hex addresses"
    end
  end

  defp validate_fee_payer_allowed_tokens_list!(_tokens) do
    raise ArgumentError,
          "MPP.Methods.Tempo fee_payer_allowed_fee_tokens must be a list of hex addresses"
  end

  defp valid_fee_token_address?(token) when is_binary(token) do
    hex = Hex.strip_0x(token)
    byte_size(hex) == 40 and Hex.hex_string?(hex)
  end

  defp valid_fee_token_address?(_), do: false

  defp reject_hash_when_fee_payer(config) do
    if fee_payer_enabled?(config) do
      {:error, Errors.new(:invalid_payload, ~s(type="hash" is not allowed when feePayer is true))}
    else
      :ok
    end
  end

  defp fee_payer_enabled?(%{"fee_payer_url" => url}) when is_binary(url), do: true
  defp fee_payer_enabled?(%{"fee_payer" => true}), do: true
  defp fee_payer_enabled?(_), do: false

  defp valid_fee_payer_url?(url) do
    uri = URI.parse(url)
    uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != ""
  end

  defp reject_non_proof_for_zero_amount(%Charge{amount: "0"}, "proof"), do: :ok

  defp reject_non_proof_for_zero_amount(%Charge{amount: "0"}, _type) do
    {:error, Errors.new(:verification_failed, "Zero-amount challenges require a proof credential")}
  end

  defp reject_non_proof_for_zero_amount(_charge, _type), do: :ok

  defp require_zero_amount(%Charge{amount: "0"}), do: :ok

  defp require_zero_amount(_charge) do
    {:error, Errors.new(:verification_failed, "Proof credentials are only valid for zero-amount challenges")}
  end

  defp extract_proof_signature(%{"signature" => sig}) when is_binary(sig) and byte_size(sig) > 0 do
    {:ok, sig}
  end

  defp extract_proof_signature(_) do
    {:error, Errors.new(:invalid_payload, "Missing or invalid 'signature' field in proof credential")}
  end

  defp require_proof_source(nil) do
    {:error, Errors.new(:invalid_payload, "Proof credential must include a source")}
  end

  defp require_proof_source(source) when is_binary(source), do: {:ok, source}

  defp require_proof_source(_) do
    {:error, Errors.new(:invalid_payload, "Proof credential must include a source")}
  end

  defp parse_proof_source(source, expected_chain_id) do
    with {:ok, %{chain_id: chain_id, address: address}} <- DID.parse_evm_did(source),
         true <- chain_id == expected_chain_id do
      {:ok, %{chain_id: chain_id, address: address}}
    else
      _ -> {:error, Errors.new(:invalid_payload, "Proof credential source is invalid")}
    end
  end

  defp verify_proof_signature(parsed, config, signature) do
    verify_proof_signature(parsed, config, signature, "Proof signature does not match source")
  end

  defp verify_proof_signature(%{address: address, chain_id: chain_id}, config, signature, mismatch_detail) do
    challenge_id = config["challenge_id"]
    realm = config["realm"]

    if is_binary(challenge_id) and is_binary(realm) do
      proof_params = %{
        account: address,
        chain_id: chain_id,
        challenge_id: challenge_id,
        realm: realm
      }

      case Proof.verify_signature(proof_params, signature, address) do
        :ok ->
          :ok

        {:error, _} ->
          verify_proof_access_key_authorization(proof_params, config, signature, address, mismatch_detail)
      end
    else
      {:error, Errors.new(:verification_failed, "Proof verification missing challenge binding")}
    end
  end

  defp verify_proof_access_key_authorization(proof_params, config, signature, source_address, mismatch_detail) do
    with {:ok, rpc_url} <- Shared.require_config(config, "rpc_url", "Tempo"),
         rpc_opts = Keyword.merge([rpc_url: rpc_url], rpc_options(config)),
         {:ok, access_key} <- Proof.recover_authorized_proof_signer(proof_params, signature, source_address),
         true <- AccessKey.active?(source_address, access_key, rpc_opts) do
      :ok
    else
      _ -> {:error, Errors.new(:verification_failed, mismatch_detail)}
    end
  end

  # --- Presenter binding helpers (hash/transaction paths) ---
  #
  # Deliberate hardening divergence, opt-in via "require_presenter_binding": neither
  # reference SDK binds the credential presenter to the transfer sender on the hash
  # path — both default the expected sender to the receipt's `from` with no presenter
  # proof (refs/mpp-rs/src/protocol/methods/tempo/method.rs verify_hash, expected_sender
  # fallback; refs/mppx/src/tempo/server/Charge.ts hash branch, `source?.address ??
  # receipt.from`). The signature envelope reuses the proof path's EIP-712 typed data
  # (MPP domain v3 {account, challengeId, realm}, refs/mppx/src/tempo/internal/proof.ts),
  # so no new wire format is introduced and existing proof-capable clients can satisfy
  # the requirement. challengeId inside the signed digest makes a captured presenter
  # signature useless against any other challenge.

  defp presenter_binding_required?(config), do: config["require_presenter_binding"] == true

  defp validate_presenter_binding!(nil), do: :ok
  defp validate_presenter_binding!(flag) when is_boolean(flag), do: :ok

  defp validate_presenter_binding!(other) do
    raise ArgumentError,
          ~s{MPP.Methods.Tempo "require_presenter_binding" must be a boolean, got: #{inspect(other)}}
  end

  defp machine_token_enabled?(%{"machine_token_enabled" => true}), do: true
  defp machine_token_enabled?(_config), do: false

  defp validate_machine_token!(config) do
    case config["machine_token_enabled"] do
      nil ->
        :ok

      false ->
        :ok

      true ->
        chain_id = config["chain_id"] || @moderato_chain_id

        if MachineToken.supported?(chain_id) do
          :ok
        else
          raise ArgumentError, "MPP.Methods.Tempo machine tokens are not supported on chain ID #{chain_id}"
        end

      other ->
        raise ArgumentError,
              ~s{MPP.Methods.Tempo "machine_token_enabled" must be a boolean, got: #{inspect(other)}}
    end
  end

  # Hash path: the account being proven is named by the credential's top-level
  # `source` DID; the matched transfer's `from` is then enforced against the same
  # address by transfer_sender_allowed?/3 (source is guaranteed non-nil here when
  # the binding verifies). When machine tokens are enabled, `from` may be the
  # canonical swapper if the transaction sender equals that source.
  defp verify_hash_presenter_binding(payload, source, expected_chain_id, config) do
    case {payload["presenterSignature"], presenter_binding_required?(config)} do
      {nil, false} ->
        :ok

      {nil, true} ->
        {:error, missing_presenter_signature_error()}

      {sig, _required?} when is_binary(sig) and byte_size(sig) > 0 ->
        if is_binary(source) do
          verify_presenter_signature(source, expected_chain_id, config, sig)
        else
          {:error,
           Errors.new(
             :invalid_payload,
             "'presenterSignature' requires a credential source (did:pkh) naming the transfer sender"
           )}
        end

      {_other, _required?} ->
        {:error, Errors.new(:invalid_payload, "Missing or invalid 'presenterSignature' field in credential payload")}
    end
  end

  # Transaction path: the account is the sender recovered from the signed 0x76
  # transaction itself; a credential `source`, when present, must agree.
  defp verify_transaction_presenter_binding(payload, tx, expected_chain_id, config) do
    case {payload["presenterSignature"], presenter_binding_required?(config)} do
      {nil, false} ->
        :ok

      {nil, true} ->
        {:error, missing_presenter_signature_error()}

      {sig, _required?} when is_binary(sig) and byte_size(sig) > 0 ->
        with {:ok, sender} <- recover_transaction_sender(tx),
             :ok <- check_source_matches_sender(config["credential_source"], sender, expected_chain_id) do
          verify_presenter_signature(sender, expected_chain_id, config, sig)
        end

      {_other, _required?} ->
        {:error, Errors.new(:invalid_payload, "Missing or invalid 'presenterSignature' field in credential payload")}
    end
  end

  defp missing_presenter_signature_error do
    Errors.new(
      :invalid_payload,
      "Presenter binding is required — credential payload must include 'presenterSignature'"
    )
  end

  defp verify_presenter_signature(account, chain_id, config, signature) do
    verify_proof_signature(
      %{address: account, chain_id: chain_id},
      config,
      signature,
      "Presenter signature does not match the transfer sender"
    )
  end

  defp recover_transaction_sender(tx) do
    case Transaction.sender(tx) do
      {:ok, <<_::binary-size(20)>> = addr} ->
        {:ok, "0x" <> Base.encode16(addr, case: :lower)}

      {:error, _reason} ->
        {:error, Errors.new(:verification_failed, "Could not recover transaction sender for presenter binding")}
    end
  end

  defp check_source_matches_sender(nil, _sender, _expected_chain_id), do: :ok

  defp check_source_matches_sender(source, sender, expected_chain_id) do
    case parse_hash_credential_source(source, expected_chain_id) do
      {:ok, address} when is_binary(address) ->
        if Onchain.Address.equal?(address, sender) do
          :ok
        else
          {:error, Errors.new(:verification_failed, "Credential source does not match the transaction sender")}
        end

      {:error, %Errors{}} = error ->
        error
    end
  end

  defp commit_proof_used(nil, _challenge_id), do: :ok

  defp commit_proof_used(_store, nil), do: :ok

  defp commit_proof_used(store, challenge_id) do
    commit_store_mark(store, @proof_store_key_prefix <> challenge_id)
  end

  defp check_fee_token_allowed(config, _token) do
    chain_id = config["chain_id"] || @moderato_chain_id
    check_returned_fee_token_allowed(config, config["fee_token"], chain_id)
  end

  defp check_returned_fee_token_allowed(config, fee_token_hex, chain_id) do
    overrides = config["fee_payer_allowed_fee_tokens"]

    if FeePayerPolicy.fee_token_allowed?(chain_id, fee_token_hex, overrides) do
      :ok
    else
      {:error, "Fee-sponsored transaction feeToken is not allowed"}
    end
  end

  defp fee_token_hex(%Transaction{fields: fields}) do
    case Enum.at(fields, TxFields.fee_token()) do
      <<token::binary-size(20)>> ->
        {:ok, "0x" <> Base.encode16(token, case: :lower)}

      _ ->
        {:error, "hosted fee payer did not return a feeToken"}
    end
  end

  # Validates call scope when fee_payer is enabled.
  # Machine-token `[approve, swapTo]` is an allowed sponsored route (mpp-rs
  # `validate_transaction_transfers_with_machine_token` skips DEX call-scope when
  # the canonical route matches). No-op when fee_payer is falsy.
  defp maybe_validate_call_scope(_tx, _config, %{machine_token?: true}), do: :ok

  defp maybe_validate_call_scope(tx, config, _payment) do
    if fee_payer_enabled?(config), do: Transaction.validate_call_scope(tx), else: :ok
  end

  defp find_transaction_payment(tx, charge, config, memo) do
    case maybe_match_machine_token_route(tx, charge, config, memo) do
      {:ok, _route} = ok -> ok
      :error -> find_tip20_payment_call(tx, charge, memo)
    end
  end

  defp maybe_match_machine_token_route(tx, charge, config, memo) do
    if machine_token_enabled?(config) do
      match_machine_token_route(tx, charge, config, memo)
    else
      :error
    end
  end

  defp match_machine_token_route(tx, charge, config, memo) do
    chain_id = config["chain_id"] || @moderato_chain_id

    case MachineToken.match_route(tx.calls, chain_id, charge.currency, charge.amount, charge.recipient, memo) do
      {:ok, route} -> {:ok, Map.put(route, :machine_token?, true)}
      :error -> :error
    end
  end

  defp find_tip20_payment_call(tx, charge, memo) do
    Transaction.find_payment_call(tx, charge.currency,
      amount: charge.amount,
      recipient: charge.recipient,
      memo: memo
    )
  end

  defp maybe_reserve_sponsor_budget(tx, config, chain_id) do
    if fee_payer_enabled?(config) do
      policy = FeePayerPolicy.resolve(chain_id, config["fee_payer_policy"])

      with {:ok, measurement} <- FeePayerPolicy.measure(tx, policy),
           {:ok, store} <- sponsor_store(config),
           {:ok, sponsor_id} <- sponsor_identity(config) do
        reserve_sponsor_budget(store, config, chain_id, sponsor_id, policy, measurement)
      else
        {:error, reason} when is_binary(reason) -> {:error, reason}
        {:error, _reason} -> {:error, Errors.new(:verification_failed, @sponsor_budget_unavailable_detail)}
      end
    else
      {:ok, nil}
    end
  end

  defp reserve_sponsor_budget(store, config, chain_id, sponsor_id, policy, measurement) do
    params = %{
      chain_id: chain_id,
      sponsor_id: sponsor_id,
      fee: measurement.total_fee,
      valid_before: measurement.valid_before,
      limits: %{
        max_in_flight_total_fee: policy.max_in_flight_total_fee,
        max_in_flight_reservations: policy.max_in_flight_reservations
      }
    }

    case SponsorBudget.reserve(store, params, sponsor_budget_options(config)) do
      {:ok, handle} ->
        {:ok, %{handle: handle, store: store}}

      {:error, {:capacity_exhausted, retry_after}} ->
        error =
          :sponsor_capacity_exhausted
          |> Errors.new(@sponsor_capacity_detail)
          |> Errors.put_retry_after(retry_after)

        {:error, error}

      {:error, _reason} ->
        {:error, Errors.new(:verification_failed, @sponsor_budget_unavailable_detail)}
    end
  end

  defp sponsor_budget_options(%{"sponsor_budget_reconcile" => true} = config) do
    receipt_fetcher = fn tx_hash -> rpc_fetch_receipt(tx_hash, config["rpc_url"], rpc_options(config)) end
    [reconcile: receipt_fetcher]
  end

  defp sponsor_budget_options(_config), do: []

  defp sponsor_store(config) do
    with {:ok, configured} when configured not in [nil, false] <- Map.fetch(config, "store"),
         store = Store.resolve(configured),
         true <- Store.update_capable?(store) do
      {:ok, store}
    else
      _other -> {:error, :invalid_store}
    end
  end

  defp sponsor_identity(%{"fee_payer_url" => url} = config) when is_binary(url),
    do: normalize_sponsor_id(config["sponsor_budget_id"])

  defp sponsor_identity(%{"fee_payer" => true} = config), do: local_sponsor_id(config)
  defp sponsor_identity(_config), do: {:error, :missing_identity}

  defp local_sponsor_id(config) do
    case Signer.address_from_key(config["fee_payer_private_key"]) do
      {:ok, address} -> normalize_sponsor_id(address)
      {:error, _reason} = error -> error
    end
  end

  defp normalize_sponsor_id(sponsor_id) when is_binary(sponsor_id) do
    normalized = sponsor_id |> String.trim() |> String.downcase()
    if normalized == "", do: {:error, :missing_identity}, else: {:ok, normalized}
  end

  defp normalize_sponsor_id(_sponsor_id), do: {:error, :missing_identity}

  defp verify_transaction_after_budget(tx, payment, charge, config, memo, store, wait?, budget) do
    case prepare_sponsored_transaction(tx, payment, config, memo, store) do
      {:ok, tx, rpc_url} ->
        broadcast_reserved_transaction(tx, rpc_url, config, charge, memo, wait?, store, budget)

      {:error, _reason} = error ->
        safe_budget_release(budget)
        error
    end
  end

  defp prepare_sponsored_transaction(tx, payment, config, memo, store) do
    with {:ok, tx} <- maybe_cosign_fee_payer(tx, config),
         {:ok, _payment} <- check_matched_memo_binding(payment, config, memo),
         :ok <- reserve_hash_atomic(store, tx.raw),
         {:ok, rpc_url} <- Shared.require_config(config, "rpc_url", "Tempo"),
         :ok <- simulate_cosigned_tx(tx.raw, rpc_url, config) do
      {:ok, tx, rpc_url}
    end
  end

  defp broadcast_reserved_transaction(tx, rpc_url, config, charge, memo, wait?, store, budget) do
    with :ok <- begin_budget_broadcast(budget),
         {:ok, tx_hash} <- broadcast_with_budget(tx, rpc_url, config, charge, memo, wait?, budget) do
      safe_dedup_post_broadcast(store, tx_hash, tx.raw)
      {:ok, Receipt.new(method: "tempo", reference: tx_hash, external_id: charge.external_id)}
    else
      {:error, :budget_transition_failed} ->
        safe_budget_release(budget)
        {:error, Errors.new(:verification_failed, @sponsor_budget_unavailable_detail)}

      {:error, _reason} = error ->
        error
    end
  end

  defp begin_budget_broadcast(nil), do: :ok

  defp begin_budget_broadcast(%{store: store, handle: handle}) do
    case SponsorBudget.transition(store, handle, :broadcasting) do
      :ok -> :ok
      {:error, _reason} -> {:error, :budget_transition_failed}
    end
  end

  defp broadcast_with_budget(%Transaction{raw: raw_hex} = tx, rpc_url, config, charge, memo, true, budget) do
    case rpc_broadcast_sync(raw_hex, rpc_url, rpc_options(config)) do
      {:ok, tx_hash, receipt} ->
        safe_budget_release(budget)

        with :ok <- Shared.check_receipt_status(receipt),
             {:ok, sender_policy} <- transaction_sender_policy(tx, config),
             {:ok, _transfer} <- find_matching_transfer(receipt, charge, memo, nil, sender_policy) do
          {:ok, tx_hash}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp broadcast_with_budget(%Transaction{raw: raw_hex}, rpc_url, config, _charge, _memo, false, budget) do
    case rpc_broadcast_async(raw_hex, rpc_url, rpc_options(config)) do
      {:ok, tx_hash} ->
        safe_budget_pending(budget, tx_hash)
        {:ok, tx_hash}

      {:error, _reason} = error ->
        error
    end
  end

  defp safe_budget_release(nil), do: :ok

  defp safe_budget_release(%{store: store, handle: handle}) do
    case SponsorBudget.release(store, handle) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("MPP.Methods.Tempo: sponsor budget release failed: #{inspect(reason)}")
    end
  end

  defp safe_budget_pending(nil, _tx_hash), do: :ok

  defp safe_budget_pending(%{store: store, handle: handle}, tx_hash) do
    case SponsorBudget.transition(store, handle, {:pending, tx_hash}) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("MPP.Methods.Tempo: sponsor budget pending transition failed: #{inspect(reason)}")
    end
  end

  defp maybe_cosign_fee_payer(tx, %{"fee_payer_url" => url} = config) when is_binary(url) do
    chain_id = config["chain_id"] || @moderato_chain_id

    with :ok <- check_fee_payer_placeholder(tx),
         :ok <- check_fee_token_empty(tx),
         {:ok, cosigned} <- HostedFeePayer.fill(tx, url, hosted_req_options(config)),
         {:ok, fee_token_hex} <- fee_token_hex(cosigned),
         :ok <- check_returned_fee_token_allowed(config, fee_token_hex, chain_id) do
      {:ok, cosigned}
    end
  end

  # Co-signs transaction as fee payer when fee_payer is enabled locally.
  # No-op when fee_payer is falsy — passes transaction through unchanged.
  defp maybe_cosign_fee_payer(tx, %{"fee_payer" => true} = config) do
    with {:ok, key} <- decode_hex_key(config["fee_payer_private_key"]),
         {:ok, token} <- decode_hex_address(config["fee_token"]),
         :ok <- check_fee_payer_placeholder(tx),
         :ok <- check_fee_token_empty(tx),
         :ok <- check_fee_token_allowed(config, token) do
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
    case Base.decode16(Hex.strip_0x(hex), case: :mixed) do
      {:ok, <<key::binary-size(32)>>} -> {:ok, key}
      _ -> {:error, "Invalid fee_payer_private_key format"}
    end
  end

  defp decode_hex_key(_), do: {:error, "Missing fee_payer_private_key"}

  # Decodes a hex address string to 20-byte binary.
  defp decode_hex_address(hex) when is_binary(hex) do
    case Base.decode16(Hex.strip_0x(hex), case: :mixed) do
      {:ok, <<addr::binary-size(20)>>} -> {:ok, addr}
      _ -> {:error, "Invalid fee_token address format"}
    end
  end

  defp decode_hex_address(_), do: {:error, "Missing fee_token"}

  # --- Dedup store helpers ---
  # Store is on by default (Store.resolve/1); these no-op only when a route opts
  # out with `store: false` (which resolves to nil).
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

  # Commits a hash as used AFTER successful on-chain verification, via the store's
  # atomic check_and_mark/2. Concurrent same-hash requests collide here, so exactly
  # one wins and the loser gets "already used". Atomicity is guaranteed by
  # validate_store!/1 (a non-atomic store is rejected at init), so there is no
  # non-atomic fallback (GHSA-w8j7-7qc3-5f24).
  defp commit_hash_used(nil, _hash), do: :ok

  defp commit_hash_used(store, hash) do
    commit_store_mark(store, store_key(hash))
  end

  defp commit_store_mark(store, key) do
    claim_atomic(store, key, System.system_time(:millisecond))
  end

  # Atomically reserves a hash before broadcast. Used by the transaction path to
  # prevent concurrent duplicate broadcasts of the same signed tx.
  defp reserve_hash_atomic(nil, _hash), do: :ok

  defp reserve_hash_atomic(store, hash) do
    claim_atomic(store, store_key(hash), System.system_time(:millisecond))
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

  # Post-broadcast dedup: if the on-chain tx hash differs from the input hash
  # (malleable variants), record the on-chain hash too.
  # Payment already succeeded on-chain at this point — a store crash (e.g. dead
  # Agent process, network partition to Redis) must not fail the HTTP response.
  # The pre-broadcast reserve_hash_atomic is the critical gate; this is
  # supplementary protection against hash malleability.
  # Uses both rescue (exceptions) and catch (process exits from dead Agents/GenServers).
  # Logger.warning is intentional: payment already settled on-chain, so this
  # supplementary dedup write must never fail the HTTP response.
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

  defp store_key(hash), do: @store_key_prefix <> String.downcase(hash)

  # Validates memo format: exactly 32 bytes of hex (64 chars), optional 0x prefix.
  defp validate_memo!(nil), do: :ok

  defp validate_memo!(memo) when is_binary(memo) do
    hex = Hex.strip_0x(memo)

    if !(byte_size(hex) == @memo_hex_length and Hex.hex_string?(hex)) do
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
    hex = Hex.strip_0x(hash)

    if byte_size(hex) == 64 and Hex.hex_string?(hex) do
      {:ok, hash}
    else
      {:error, Errors.new(:invalid_payload, "Invalid transaction hash format")}
    end
  end

  defp extract_hash(_) do
    {:error, Errors.new(:invalid_payload, "Missing or invalid 'hash' field in credential payload")}
  end

  defp parse_hash_credential_source(nil, _expected_chain_id), do: {:ok, nil}

  defp parse_hash_credential_source(source, expected_chain_id) when is_binary(source) do
    with {:ok, %{chain_id: chain_id, address: address}} <- DID.parse_evm_did(source),
         true <- chain_id == expected_chain_id do
      {:ok, address}
    else
      _ -> {:error, Errors.new(:invalid_payload, "Hash credential source is invalid")}
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

  # --- Onchain.Tempo.RPC adapter functions ---
  # Delegates to onchain_tempo and wraps string errors in MPP.Errors structs.

  defp rpc_options(config), do: [req_options: config["req_options"] || []]

  defp hosted_req_options(config) do
    case config["req_options"] do
      nil -> []
      opts -> [req_options: opts]
    end
  end

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

  # Finds a matching transfer event. When memo is configured, requires TransferWithMemo
  # with matching memo. When no memo, accepts both Transfer and TransferWithMemo events.
  # Spec: draft-tempo-charge-00.md §Transaction Verification, lines 395-399.
  # `sender_policy` is the mpp-rs ReceiptSenderPolicy: when machine tokens are
  # enabled, a transfer `from` the canonical swapper is accepted if the
  # transaction sender equals the expected payer.
  defp find_matching_transfer(receipt, charge, memo, source, sender_policy)

  defp find_matching_transfer(%{logs: logs}, %Charge{} = charge, nil, source, sender_policy) do
    # No memo configured — accept Transfer OR TransferWithMemo matching token/recipient/amount.
    with {:ok, amount_int} <- Shared.parse_charge_amount(charge.amount),
         {:ok, transfers} <- Onchain.Transfer.parse_logs(logs) do
      # Also check TransferWithMemo events (onchain only parses standard Transfer)
      memo_transfers = Transfer.parse_transfer_with_memo_logs(logs)

      match =
        Enum.find(memo_transfers ++ transfers, fn transfer ->
          Onchain.Address.equal?(transfer.token, charge.currency) and
            Onchain.Address.equal?(transfer.to, charge.recipient) and
            transfer.amount == amount_int and
            transfer_sender_allowed?(transfer, source, sender_policy) and
            transfer_memo_bound?(transfer, charge)
        end)

      case match do
        nil -> {:error, Errors.new(:verification_failed, "No matching Transfer event found in transaction")}
        transfer -> {:ok, transfer}
      end
    end
  end

  defp find_matching_transfer(%{logs: logs}, %Charge{} = charge, memo, source, sender_policy) when is_binary(memo) do
    # Memo configured — MUST match TransferWithMemo with matching memo value.
    with {:ok, amount_int} <- Shared.parse_charge_amount(charge.amount) do
      normalized_memo = String.downcase(Hex.strip_0x(memo))

      match =
        logs
        |> Transfer.parse_transfer_with_memo_logs()
        |> Enum.find(fn transfer ->
          Onchain.Address.equal?(transfer.token, charge.currency) and
            Onchain.Address.equal?(transfer.to, charge.recipient) and
            transfer.amount == amount_int and
            String.downcase(Hex.strip_0x(transfer.memo)) == normalized_memo and
            transfer_sender_allowed?(transfer, source, sender_policy)
        end)

      case match do
        nil ->
          {:error, Errors.new(:verification_failed, "No matching TransferWithMemo event found in transaction")}

        transfer ->
          {:ok, transfer}
      end
    end
  end

  # Non-machine-token path: no source means any `from`; a source must match the
  # transfer sender. Machine-token path (mpp-rs `ReceiptSenderPolicy` /
  # mppx `isValidTransferSender`): accept the expected payer or the canonical
  # swapper when the transaction sender is that payer.
  defp transfer_sender_allowed?(transfer, source, nil) do
    is_nil(source) or Onchain.Address.equal?(transfer.from, source)
  end

  defp transfer_sender_allowed?(transfer, source, %{transaction_sender: tx_from, settlement_senders: senders}) do
    expected = source || tx_from

    Onchain.Address.equal?(transfer.from, expected) or
      (Onchain.Address.equal?(tx_from, expected) and settlement_sender?(transfer.from, senders))
  end

  defp settlement_sender?(from, senders) do
    Enum.any?(senders, &Onchain.Address.equal?(from, &1))
  end

  defp hash_sender_policy(hash, rpc_url, config) do
    settlement_sender_policy(config, fn swapper ->
      with {:ok, from} <- rpc_fetch_transaction_from(hash, rpc_url, rpc_options(config)) do
        {:ok, %{transaction_sender: from, settlement_senders: [swapper]}}
      end
    end)
  end

  defp transaction_sender_policy(tx, config) do
    settlement_sender_policy(config, fn swapper ->
      case Transaction.sender(tx) do
        {:ok, sender} -> {:ok, %{transaction_sender: sender, settlement_senders: [swapper]}}
        {:error, reason} -> {:error, Errors.new(:verification_failed, reason)}
      end
    end)
  end

  defp settlement_sender_policy(config, fun) do
    if machine_token_enabled?(config) do
      resolve_settlement_sender(config["chain_id"] || @moderato_chain_id, fun)
    else
      {:ok, nil}
    end
  end

  defp resolve_settlement_sender(chain_id, fun) do
    case MachineToken.settlement_sender(chain_id) do
      nil -> {:error, Errors.new(:verification_failed, "Machine tokens are not supported on chain ID #{chain_id}")}
      swapper -> fun.(swapper)
    end
  end

  # onchain_tempo's receipt parser drops `from` (RPC.parse_receipt keeps only
  # status/logs). Machine-token hash verification needs the transaction sender
  # to bind swapper-emitted TransferWithMemo logs to the payer — fetch it from
  # eth_getTransactionByHash over the same Req options as the other Tempo RPCs.
  defp rpc_fetch_transaction_from(hash, rpc_url, opts) do
    req_options = Keyword.get(opts, :req_options, [])

    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "eth_getTransactionByHash",
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
      {:ok, %Req.Response{status: status, body: %{"result" => %{"from" => from}}}}
      when status in 200..299 and is_binary(from) ->
        {:ok, from}

      {:ok, %Req.Response{status: status, body: %{"result" => nil}}} when status in 200..299 ->
        {:error, Errors.new(:verification_failed, "Transaction not found on-chain")}

      {:error, _exception} ->
        {:error, Errors.new(:verification_failed, @tempo_rpc_error_detail)}

      {:ok, %Req.Response{}} ->
        {:error, Errors.new(:verification_failed, @tempo_rpc_error_detail)}
    end
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
    case Base.decode16(Hex.strip_0x(memo), case: :mixed) do
      {:ok, <<_::binary-size(@attribution_memo_length)>> = bytes} -> {:ok, bytes}
      _ -> :error
    end
  end

  defp decode_memo(_memo), do: :error
end
