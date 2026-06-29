defmodule MPP.Tempo.StoreTest do
  use ExUnit.Case, async: false

  alias MPP.Tempo.ConCacheStore
  alias MPP.Tempo.Store
  alias MPP.Test.NonAtomicStore
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

  describe "supports_atomic?/1" do
    test "detects module and tuple support", %{con_cache_store: store} do
      assert Store.supports_atomic?(TempoMemoryStore)
      assert Store.supports_atomic?(store)
      refute Store.supports_atomic?(NonAtomicStore)
    end
  end

  defp unique_cache_name do
    [:positive]
    |> System.unique_integer()
    |> then(&:"#{__MODULE__}.#{&1}")
  end
end
