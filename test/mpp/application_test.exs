defmodule MPP.ApplicationTest do
  use ExUnit.Case, async: true

  alias MPP.Tempo.ConCacheStore
  alias MPP.Tempo.Store

  describe "default dedup store" do
    test "the :mpp application starts the default ConCacheStore under its supervisor" do
      # MPP.Application.start/2 (wired via `mod:` in mix.exs) starts the default
      # store so replay protection is on out of the box (issue #7).
      pid = Process.whereis(:mpp_tempo_dedup)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "the app-started default store enforces single-use via the default store ref" do
      store = Store.default_store()
      key = "mpp:test:" <> Integer.to_string(System.unique_integer([:positive]))

      assert :ok = ConCacheStore.check_and_mark(key, :first)
      assert {:error, :already_exists} = ConCacheStore.check_and_mark(key, :second)
      assert {:ok, :first} = Store.get(store, key)
    end
  end
end
