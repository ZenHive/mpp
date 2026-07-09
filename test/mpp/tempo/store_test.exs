defmodule MPP.Tempo.StoreTest do
  use ExUnit.Case, async: false

  alias MPP.Tempo.ConCacheStore
  alias MPP.Tempo.Store
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

  describe "storage_key/2" do
    test "returns the key unchanged when no prefix is configured" do
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

  defp unique_cache_name do
    [:positive]
    |> System.unique_integer()
    |> then(&:"#{__MODULE__}.#{&1}")
  end
end
