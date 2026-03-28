defmodule MPP.Tempo.Store do
  @moduledoc """
  Behaviour for transaction dedup stores used by `MPP.Methods.Tempo`.

  Prevents within-challenge replay attacks by tracking which transaction hashes
  have already been used. HMAC-bound challenges prevent cross-request replay;
  this store prevents a client from resubmitting the same signed transaction
  within a single challenge window.

  ## Implementation

  Consumers implement this behaviour with their choice of backend (ETS, Redis,
  database, etc.). The library does not provide a built-in implementation —
  store lifecycle and cleanup are the consumer's responsibility.

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
