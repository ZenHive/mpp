defmodule MPP.X402.ReplayTest do
  use ExUnit.Case, async: true

  alias MPP.Tempo.ConCacheStore
  alias MPP.Tempo.Store
  alias MPP.X402.Replay

  defmodule UnavailableStore do
    @moduledoc false
    @behaviour Store

    @impl true
    @spec get(String.t()) :: {:error, :offline}
    def get(_key), do: {:error, :offline}

    @impl true
    @spec put(String.t(), term()) :: {:error, :offline}
    def put(_key, _value), do: {:error, :offline}

    @impl true
    @spec check_and_mark(String.t(), term()) :: {:error, :offline}
    def check_and_mark(_key, _value), do: {:error, :offline}
  end

  test "claims are atomic, case-insensitive and namespaced" do
    name = :"x402_replay_#{System.unique_integer([:positive])}"
    start_supervised!({ConCacheStore, name: name})
    store = {ConCacheStore, name: name}
    results = 1..16 |> Task.async_stream(fn _ -> Replay.claim(store, "0xAB") end) |> Enum.to_list()
    assert Enum.count(results, &(&1 == {:ok, :ok})) == 1
    assert Enum.count(results, &(&1 == {:ok, {:error, :already_used}})) == 15
    assert {:error, :already_used} = Replay.claim(store, "0xab")
    assert {:ok, timestamp} = Store.get(store, "mpp:x402:0xab")
    assert is_integer(timestamp)
    assert :ok = Replay.claim(store, "0xac")
  end

  test "disabled storage bypasses claims while storage failures fail closed" do
    assert :ok = Replay.claim(nil, "0xab")
    assert {:error, :store_error} = Replay.claim(UnavailableStore, "0xab")
  end
end
