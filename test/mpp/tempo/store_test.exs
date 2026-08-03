defmodule MPP.Tempo.StoreTest do
  use ExUnit.Case, async: false

  alias MPP.Tempo.ConCacheStore
  alias MPP.Tempo.Store
  alias MPP.Test.FailingPutStore
  alias MPP.Test.TempoMemoryStore

  @ttl_ms 1_000

  setup do
    cache_name = unique_cache_name()

    start_supervised!(
      ConCacheStore.child_spec(
        name: cache_name,
        ttl: @ttl_ms
      )
    )

    {:ok, _pid} = start_supervised(TempoMemoryStore)

    {:ok, con_cache_store: {ConCacheStore, [name: cache_name]}}
  end

  describe "get/2 and put/3" do
    test "dispatches to a store module" do
      assert :not_found = Store.get(TempoMemoryStore, "module-key")
      assert :ok = Store.put(TempoMemoryStore, "module-key", :module_value)
      assert {:ok, :module_value} = Store.get(TempoMemoryStore, "module-key")
    end

    test "dispatches to configured ConCacheStore tuple", %{con_cache_store: store} do
      assert :not_found = Store.get(store, "tuple-key")
      assert :ok = Store.put(store, "tuple-key", :tuple_value)
      assert {:ok, :tuple_value} = Store.get(store, "tuple-key")
    end
  end

  describe "check_and_mark/3" do
    test "dispatches to a store module" do
      assert :ok = Store.check_and_mark(TempoMemoryStore, "module-atomic", :first)
      assert {:error, :already_exists} = Store.check_and_mark(TempoMemoryStore, "module-atomic", :second)
      assert {:ok, :first} = Store.get(TempoMemoryStore, "module-atomic")
    end

    test "dispatches to configured ConCacheStore tuple", %{con_cache_store: store} do
      assert :ok = Store.check_and_mark(store, "tuple-atomic", :first)
      assert {:error, :already_exists} = Store.check_and_mark(store, "tuple-atomic", :second)
      assert {:ok, :first} = Store.get(store, "tuple-atomic")
    end
  end

  describe "dedup_capable?/1 and update_capable?/1" do
    test "detect callbacks on a store module that is not loaded yet" do
      # Regression: a bare function_exported?/3 answers false for a compiled but
      # unloaded module, which rejected a valid store at init depending on whether
      # anything had happened to call it first.
      unload(TempoMemoryStore)
      refute :erlang.module_loaded(TempoMemoryStore)
      assert Store.dedup_capable?(TempoMemoryStore)

      unload(TempoMemoryStore)
      refute :erlang.module_loaded(TempoMemoryStore)
      assert Store.update_capable?(TempoMemoryStore)
    end

    test "reject non-modules and stores missing the callbacks" do
      refute Store.dedup_capable?(nil)
      refute Store.dedup_capable?(false)
      refute Store.dedup_capable?("MPP.Test.TempoMemoryStore")
      refute Store.dedup_capable?(MPP.Tempo.NoSuchStore)
      refute Store.update_capable?(FailingPutStore)
    end

    test "unwraps the ConCacheStore tuple form for update_capable?/1" do
      assert Store.update_capable?({ConCacheStore, name: :whatever})
      refute Store.update_capable?({FailingPutStore, []})
    end
  end

  describe "update/4" do
    test "dispatches to a store module" do
      update = fn :not_found -> {:put, 1, :created} end

      assert {:ok, :created} = Store.update(TempoMemoryStore, "module-update", update)
      assert {:ok, 1} = Store.get(TempoMemoryStore, "module-update")
    end

    test "merges configured ConCache opts with call opts", %{con_cache_store: store} do
      {ConCacheStore, store_opts} = store
      prefixed_store = {ConCacheStore, Keyword.put(store_opts, :key_prefix, "tenant:")}
      update = fn :not_found -> {:put, :budget, :created} end

      assert {:ok, :created} =
               Store.update(prefixed_store, "mpp:sponsor-budget:1:wallet", update,
                 ignore_key_prefix: true,
                 ttl_ms: @ttl_ms
               )

      assert {:ok, :budget} = ConCacheStore.get("mpp:sponsor-budget:1:wallet", store_opts)

      assert :not_found =
               ConCacheStore.get("mpp:sponsor-budget:1:wallet", Keyword.put(store_opts, :key_prefix, "tenant:"))
    end
  end

  describe "storage_key/2" do
    test "returns the key unchanged when no prefix is configured" do
      assert Store.storage_key("mpp:charge:0xabc") == "mpp:charge:0xabc"
      assert Store.storage_key("mpp:charge:0xabc", []) == "mpp:charge:0xabc"
    end

    test "prepends key_prefix from opts" do
      assert Store.storage_key("mpp:charge:0xabc", key_prefix: "billing:") ==
               "billing:mpp:charge:0xabc"
    end
  end

  describe "resolve/1 and default_store/0" do
    test "default_store/0 is the built-in ConCacheStore" do
      assert Store.default_store() == ConCacheStore
    end

    test "nil (absent/unconfigured) resolves to the default store — on by default" do
      assert Store.resolve(nil) == ConCacheStore
    end

    test "false resolves to nil — explicit opt-out" do
      assert Store.resolve(false) == nil
    end

    test "an explicit store ref is returned unchanged", %{con_cache_store: store} do
      assert Store.resolve(TempoMemoryStore) == TempoMemoryStore
      assert Store.resolve(store) == store
    end
  end

  # Drops the loaded copy so the next lookup has to go back to the code path,
  # reproducing the state a consumer's store module is in before its first call.
  defp unload(module) do
    :code.purge(module)
    :code.delete(module)
    :code.purge(module)
    :ok
  end

  defp unique_cache_name do
    [:positive]
    |> System.unique_integer()
    |> then(&:"#{__MODULE__}.#{&1}")
  end
end
