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
  TTL expiry via ConCache (optional dependency). For most single-node deployments,
  this is all you need — add it to your supervision tree and pass it in method_config.

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
      end

  Then pass it in method_config:

      plug MPP.Plug,
        method: MPP.Methods.Tempo,
        method_config: %{
          "rpc_url" => "https://rpc.moderato.tempo.xyz",
          "store" => MyApp.PaymentStore
        }
  """

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
  If the store can implement this atomically (Redis SETNX, DB upsert with
  unique constraint, etc.), concurrent requests with the same key will be
  serialized — only the first succeeds.

  Returns `:ok` if the key was not present and is now marked,
  `{:error, :already_exists}` if the key was already present,
  or `{:error, reason}` on store failure.

  Optional — when not implemented, the library falls back to sequential
  `get/1` + `put/2` (smaller race window but not fully atomic).
  """
  @callback check_and_mark(key :: String.t(), value :: term()) ::
              :ok | {:error, :already_exists} | {:error, term()}

  @optional_callbacks [check_and_mark: 2]
end
