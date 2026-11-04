defmodule MPP.Tempo.ConCacheStore do
  @moduledoc """
  Built-in ETS-based atomic store using ConCache (TTL-enabled ETS wrapper by Saša Jurić).

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

  A mark bound to a challenge (`MPP.Tempo.Store.check_and_mark/4`) is kept
  until the challenge expires plus 30 seconds when that is later than the
  store's TTL, so a long `expires_in` cannot outlive its replay mark. Other
  entries expire after the TTL. This needs the TTL recorded by `child_spec/1`:
  for a ConCache started any other way the TTL **must be ≥ your challenge
  `expires_in`**. A good default is 2× the challenge expiry.

  ## Sponsor-budget scope

  A ConCache instance is process-local and therefore provides a sponsor-wide
  bound only inside one BEAM node. Every endpoint in that node sponsoring the
  same wallet must select the same cache `:name`. Horizontally scaled nodes must
  instead select one shared store backend implementing `MPP.Tempo.Store.update/3`.

  ## Options

    * `:ttl` — time-to-live for entries in milliseconds. Default: 10 minutes (2× the
      default Plug `expires_in` of 300 seconds).
    * `:name` — registered name for the ConCache process. Default: `:mpp_tempo_dedup`.
      Override to avoid child ID collisions if your app already supervises other
      ConCache instances.
    * `:ttl_check_interval` — how often to sweep expired entries. Default: 30 seconds.
    * `:key_prefix` — string prepended to every backing key for multi-tenant
      namespacing when sharing one cache. Default: `""` (no prefix).
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

    concache_opts = [name: name, ttl_check_interval: check_interval, global_ttl: ttl]

    concache_opts
    |> ConCache.child_spec()
    |> Map.merge(%{id: {__MODULE__, name}, start: {__MODULE__, :start_link, [concache_opts]}})
  end

  @doc false
  # Records the cache TTL so challenge-bound marks can tell when they must
  # outlive it.
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(concache_opts) do
    with {:ok, pid} <- ConCache.start_link(concache_opts) do
      :persistent_term.put({__MODULE__, :ttl, concache_opts[:name]}, concache_opts[:global_ttl])
      {:ok, pid}
    end
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
    case ConCache.get(cache_name(opts), Store.storage_key(key, opts)) do
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
    ConCache.put(cache_name(opts), Store.storage_key(key, opts), value)
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
  `:min_ttl_ms` keeps the mark at least that long when it exceeds the TTL
  recorded by `child_spec/1`.
  """
  @spec check_and_mark(String.t(), term(), keyword()) :: :ok | {:error, :already_exists}
  def check_and_mark(key, value, opts) do
    cache_name = cache_name(opts)
    storage_key = Store.storage_key(key, opts)

    ConCache.isolated(cache_name, storage_key, fn ->
      case ConCache.get(cache_name, storage_key) do
        nil ->
          ConCache.put(cache_name, storage_key, mark_item(cache_name, value, opts[:min_ttl_ms]))
          :ok

        _existing ->
          {:error, :already_exists}
      end
    end)
  end

  @impl Store
  @doc """
  Atomically reserves a dedup key in the default ConCache for at least `ttl_ms`.
  """
  @spec check_and_mark_ttl(String.t(), term(), pos_integer()) :: :ok | {:error, :already_exists}
  def check_and_mark_ttl(key, value, ttl_ms), do: check_and_mark(key, value, min_ttl_ms: ttl_ms)

  # Only ever extends a mark past the cache TTL; an unknown or infinite TTL
  # keeps the cache default.
  defp mark_item(_cache_name, value, nil), do: value

  defp mark_item(cache_name, value, min_ttl_ms) do
    case :persistent_term.get({__MODULE__, :ttl, cache_name}, nil) do
      ttl when is_integer(ttl) and min_ttl_ms > ttl -> %ConCache.Item{value: value, ttl: min_ttl_ms}
      _keep_default -> value
    end
  end

  @impl Store
  @doc """
  Atomically updates a value in the default ConCache.
  """
  @spec update(String.t(), (term() | :not_found -> term()), keyword()) ::
          {:ok, term()} | {:error, term()}
  def update(key, fun, opts) when is_function(fun, 1) do
    cache_name = cache_name(opts)
    storage_key = storage_key(key, opts)

    ConCache.isolated(cache_name, storage_key, fn ->
      current =
        case ConCache.get(cache_name, storage_key) do
          nil -> :not_found
          value -> value
        end

      apply_update(cache_name, storage_key, fun.(current), opts)
    end)
  end

  @impl Store
  @doc """
  Compare-and-deletes a dedup key in the default ConCache.
  """
  @spec delete(String.t(), term()) :: :ok
  def delete(key, expected), do: delete(key, expected, [])

  @doc """
  Compare-and-deletes a dedup key, optionally using a non-default ConCache name from opts.

  Same as `delete/2` when `opts` is `[]`. Deletes only when the stored value
  still equals `expected`; a mismatch or missing key is a successful no-op.
  """
  @spec delete(String.t(), term(), keyword()) :: :ok
  def delete(key, expected, opts) do
    cache_name = cache_name(opts)
    storage_key = Store.storage_key(key, opts)

    ConCache.isolated(cache_name, storage_key, fn ->
      case ConCache.get(cache_name, storage_key) do
        ^expected ->
          ConCache.delete(cache_name, storage_key)
          :ok

        _other ->
          :ok
      end
    end)
  end

  @spec apply_update(ConCache.t(), term(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  defp apply_update(cache_name, storage_key, {:put, value, result}, opts) do
    case stored_value(value, opts) do
      {:ok, stored} ->
        ConCache.dirty_put(cache_name, storage_key, stored)
        {:ok, result}

      {:error, _reason} = error ->
        error
    end
  end

  defp apply_update(cache_name, storage_key, {:delete, result}, _opts) do
    ConCache.dirty_delete(cache_name, storage_key)
    {:ok, result}
  end

  defp apply_update(_cache_name, _storage_key, {:noop, result}, _opts), do: {:ok, result}

  defp apply_update(_cache_name, _storage_key, other, _opts), do: {:error, {:invalid_update_result, other}}

  @spec stored_value(term(), keyword()) :: {:ok, term()} | {:error, term()}
  defp stored_value(value, opts) do
    case Keyword.fetch(opts, :ttl_ms) do
      :error ->
        {:ok, value}

      {:ok, ttl_fun} when is_function(ttl_fun, 1) ->
        wrap_ttl(value, ttl_fun.(value))

      {:ok, ttl_ms} ->
        wrap_ttl(value, ttl_ms)
    end
  end

  @spec wrap_ttl(term(), term()) :: {:ok, ConCache.Item.t()} | {:error, term()}
  defp wrap_ttl(value, ttl_ms) when is_integer(ttl_ms) and ttl_ms > 0,
    do: {:ok, %ConCache.Item{value: value, ttl: ttl_ms}}

  defp wrap_ttl(_value, ttl_ms), do: {:error, {:invalid_ttl_ms, ttl_ms}}

  @spec storage_key(String.t(), keyword()) :: String.t()
  defp storage_key(key, opts) do
    if Keyword.get(opts, :ignore_key_prefix, false),
      do: key,
      else: Store.storage_key(key, opts)
  end

  defp cache_name(opts), do: Keyword.get(opts, :name, @cache_name)
end
