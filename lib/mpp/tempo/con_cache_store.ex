defmodule MPP.Tempo.ConCacheStore do
  @moduledoc """
  Built-in ETS-based dedup store using ConCache (TTL-enabled ETS wrapper by Saša Jurić).

  Backed by the `con_cache` dependency. This store is started automatically by
  the `:mpp` application as the **default** dedup store (replay protection on by
  default — issue #7), so most single-node deployments need no setup.

  ## Setup (custom instances)

  To run an additional/renamed instance, add it to your supervision tree:

      children = [
        MPP.Tempo.ConCacheStore.child_spec(name: :my_dedup, ttl: to_timeout(minute: 10))
      ]

  Then pass in method_config:

      plug MPP.Plug,
        method: MPP.Methods.Tempo,
        method_config: %{
          "rpc_url" => "https://rpc.moderato.tempo.xyz",
          "store" => MPP.Tempo.ConCacheStore
        }

  If you override the cache name in your supervision tree, pass the same name in
  `method_config`:

      children = [
        MPP.Tempo.ConCacheStore.child_spec(name: :my_custom_dedup, ttl: to_timeout(minute: 10))
      ]

      plug MPP.Plug,
        method: MPP.Methods.Tempo,
        method_config: %{
          "rpc_url" => "https://rpc.moderato.tempo.xyz",
          "store" => {MPP.Tempo.ConCacheStore, name: :my_custom_dedup}
        }

  ## TTL and Challenge Expiry

  The store's TTL **must be ≥ your challenge `expires_in`** to prevent replay.
  If the cache evicts a tx hash before the challenge expires, the same tx can
  be replayed. A good default is 2× the challenge expiry.

  Example: if your Plug uses `expires_in: 300` (5 min), set the store TTL to
  at least `to_timeout(minute: 10)`.

  ## Options

    * `:ttl` — time-to-live for entries in milliseconds. Default: 10 minutes (2× the
      default Plug `expires_in` of 300 seconds).
    * `:name` — registered name for the ConCache process. Default: `:mpp_tempo_dedup`.
      Override to avoid child ID collisions if your app already supervises other
      ConCache instances.
    * `:ttl_check_interval` — how often to sweep expired entries. Default: 30 seconds.
  """

  @behaviour MPP.Tempo.Store

  alias MPP.Tempo.Store

  @cache_name :mpp_tempo_dedup
  @default_ttl_ms to_timeout(minute: 10)
  @default_check_interval_ms to_timeout(second: 30)

  @doc """
  Returns a child spec for the ConCache process.

  Start under your application's supervision tree:

      children = [
        MPP.Tempo.ConCacheStore.child_spec(ttl: :timer.minutes(10))
      ]

  The child spec `id` is `{MPP.Tempo.ConCacheStore, name}` to avoid collisions
  with other ConCache instances in the same supervisor.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts \\ []) do
    name = Keyword.get(opts, :name, @cache_name)
    ttl = Keyword.get(opts, :ttl, @default_ttl_ms)
    check_interval = Keyword.get(opts, :ttl_check_interval, @default_check_interval_ms)

    [name: name, ttl_check_interval: check_interval, global_ttl: ttl]
    |> ConCache.child_spec()
    |> Map.put(:id, {__MODULE__, name})
  end

  @impl Store
  @doc """
  Looks up a dedup key in the default ConCache.
  """
  @spec get(String.t()) :: {:ok, term()} | :not_found
  def get(key), do: get(key, [])

  @doc """
  Looks up a dedup key, optionally using a non-default ConCache name from opts.

  Same as `get/1` when `opts` is `[]`.
  """
  @spec get(String.t(), keyword()) :: {:ok, term()} | :not_found
  def get(key, opts) do
    case ConCache.get(cache_name(opts), key) do
      nil -> :not_found
      value -> {:ok, value}
    end
  end

  @impl Store
  @doc """
  Stores a dedup key in the default ConCache.
  """
  @spec put(String.t(), term()) :: :ok
  def put(key, value), do: put(key, value, [])

  @doc """
  Stores a dedup key, optionally using a non-default ConCache name from opts.

  Same as `put/2` when `opts` is `[]`.
  """
  @spec put(String.t(), term(), keyword()) :: :ok
  def put(key, value, opts) do
    ConCache.put(cache_name(opts), key, value)
    :ok
  end

  @impl Store
  @doc """
  Atomically reserves a dedup key in the default ConCache.
  """
  @spec check_and_mark(String.t(), term()) :: :ok | {:error, :already_exists}
  def check_and_mark(key, value), do: check_and_mark(key, value, [])

  @doc """
  Atomically reserves a dedup key, optionally using a non-default ConCache name from opts.

  Same as `check_and_mark/2` when `opts` is `[]`.
  """
  @spec check_and_mark(String.t(), term(), keyword()) :: :ok | {:error, :already_exists}
  def check_and_mark(key, value, opts) do
    cache_name = cache_name(opts)

    ConCache.isolated(cache_name, key, fn ->
      case ConCache.get(cache_name, key) do
        nil ->
          ConCache.put(cache_name, key, value)
          :ok

        _existing ->
          {:error, :already_exists}
      end
    end)
  end

  defp cache_name(opts), do: Keyword.get(opts, :name, @cache_name)
end
