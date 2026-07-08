defmodule MPP.Tempo.Store do
  @moduledoc """
  Behaviour for transaction dedup stores used by `MPP.Methods.Tempo`.

  Prevents replay attacks by tracking which transaction hashes have already
  been used. HMAC-bound challenges prevent cross-request replay; this store
  prevents a client from resubmitting the same signed transaction within
  the store's TTL window.

  **Important:** The store's TTL must be ≥ your challenge `expires_in` to
  ensure a tx hash cannot be evicted and replayed while the challenge is
  still valid. A good default is 2× the challenge expiry.

  ## Built-in Store

  `MPP.Tempo.ConCacheStore` provides an ETS-based implementation with automatic
  TTL expiry via ConCache. It is started by the `:mpp` application as the **default**
  store, so replay protection is on out of the box (issue #7). For most
  single-node deployments this is all you need; for multi-node, configure a shared
  backend (Redis/Postgres) as your `:store`.

  ## Custom Implementations

  Implement this behaviour with your choice of backend (Redis, database, etc.)
  for custom needs. Store lifecycle and cleanup are the consumer's responsibility.

  ## Deployment Strategies

  The store choice depends on your deployment topology:

  - **Single node:** `ConCacheStore` is sufficient — all requests hit the same ETS table.
  - **Multi-node with sticky routing:** If your load balancer pins clients to specific
    nodes (e.g., Fly.io's `fly-replay` with cookie-based sticky sessions, or consistent
    hashing by session ID), per-node `ConCacheStore` is effectively global — the same
    client always hits the same node's store.
  - **Multi-node without sticky routing:** Use a shared backend (Redis, Postgres)
    to ensure a tx replayed on a different node is still caught.

  Keys are formatted as `"mpp:charge:<lowercase_hex_value>"` where the value is
  the transaction hash (for `type="hash"`) or the full serialized transaction
  hex (for `type="transaction"`).

  ## Example

      defmodule MyApp.PaymentStore do
        @behaviour MPP.Tempo.Store

        def get(key) do
          case :ets.lookup(:payment_dedup, key) do
            [{^key, value}] -> {:ok, value}
            [] -> :not_found
          end
        end

        def put(key, value) do
          :ets.insert(:payment_dedup, {key, value})
          :ok
        end

        def check_and_mark(key, value) do
          if :ets.insert_new(:payment_dedup, {key, value}) do
            :ok
          else
            {:error, :already_exists}
          end
        end
      end

  Then pass it in method_config:

      plug MPP.Plug,
        method: MPP.Methods.Tempo,
        method_config: %{
          "rpc_url" => "https://rpc.moderato.tempo.xyz",
          "store" => MyApp.PaymentStore
        }
  """

  alias MPP.Tempo.ConCacheStore

  @type store_ref :: module() | {module(), keyword()}

  # The app-started default dedup store (started by MPP.Application). A bare
  # module ref resolves to the default ConCache instance (name :mpp_tempo_dedup).
  @default_store ConCacheStore

  @doc """
  Return the default dedup store started by the `:mpp` application.

  Replay protection is on by default (issue #7); this is the store
  used when a method/plug is configured without an explicit `:store`.
  """
  @spec default_store() :: module()
  def default_store, do: @default_store

  @doc """
  Resolve a configured `:store` option to the store actually used at runtime.

    * `nil` (absent / not configured) → the app-started `default_store/0` (on by default)
    * `false` → `nil` (explicit opt-out — no replay protection)
    * any other ref → returned unchanged

  Callers validate the ref separately (see each method's `validate_store!/1`);
  this only applies the default-on / opt-out policy.
  """
  @spec resolve(store_ref() | nil | false) :: store_ref() | nil
  def resolve(nil), do: @default_store
  def resolve(false), do: nil
  def resolve(store), do: store

  @doc """
  Look up a key in the store.

  Returns `{:ok, value}` if found, `:not_found` if the key doesn't exist,
  or `{:error, reason}` on store failure.
  """
  @callback get(key :: String.t()) :: {:ok, term()} | :not_found | {:error, term()}

  @doc """
  Store a key-value pair.

  Returns `:ok` on success or `{:error, reason}` on store failure.
  """
  @callback put(key :: String.t(), value :: term()) :: :ok | {:error, term()}

  @doc """
  Atomically check if a key exists and mark it if not.

  This is the critical operation for preventing concurrent replay attacks.
  The store MUST implement it atomically (Redis SETNX, DB upsert with a unique
  constraint, ConCache row isolation, etc.) so concurrent requests with the same
  key are serialized — only the first succeeds.

  Returns `:ok` if the key was not present and is now marked,
  `{:error, :already_exists}` if the key was already present,
  or `{:error, reason}` on store failure.

  **Required.** A store that does not export `check_and_mark/2` is rejected at
  `Plug.init` / `validate_config!` — the library never falls back to a
  non-atomic `get/1` + `put/2`, which would leave a TOCTOU replay window
  (see GHSA-w8j7-7qc3-5f24).
  """
  @callback check_and_mark(key :: String.t(), value :: term()) ::
              :ok | {:error, :already_exists} | {:error, term()}

  @doc """
  Look up a key using either a store module or `{MPP.Tempo.ConCacheStore, opts}`.
  """
  @spec get(store_ref(), String.t()) ::
          {:ok, term()} | :not_found | {:error, term()}
  def get({ConCacheStore, opts}, key), do: ConCacheStore.get(key, opts)
  def get(store, key), do: store.get(key)

  @doc """
  Store a key-value pair using either a store module or `{MPP.Tempo.ConCacheStore, opts}`.
  """
  @spec put(store_ref(), String.t(), term()) :: :ok | {:error, term()}
  def put({ConCacheStore, opts}, key, value), do: ConCacheStore.put(key, value, opts)
  def put(store, key, value), do: store.put(key, value)

  @doc """
  Atomically check and mark a key using either a store module or `{MPP.Tempo.ConCacheStore, opts}`.
  """
  @spec check_and_mark(store_ref(), String.t(), term()) ::
          :ok | {:error, :already_exists} | {:error, term()}
  def check_and_mark({ConCacheStore, opts}, key, value), do: ConCacheStore.check_and_mark(key, value, opts)
  def check_and_mark(store, key, value), do: store.check_and_mark(key, value)
end
