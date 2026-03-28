defmodule MPP.Test.TempoMemoryStore do
  @moduledoc """
  Agent-based in-memory store implementing `MPP.Tempo.Store` for testing.

  Start with `start_supervised!/1` in test setup for automatic cleanup.
  """

  @behaviour MPP.Tempo.Store

  use Agent

  alias MPP.Tempo.Store

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @impl Store
  def get(key) do
    case Agent.get(__MODULE__, &Map.get(&1, key)) do
      nil -> :not_found
      value -> {:ok, value}
    end
  end

  @impl Store
  def put(key, value) do
    Agent.update(__MODULE__, &Map.put(&1, key, value))
    :ok
  end

  @impl Store
  def check_and_mark(key, value) do
    Agent.get_and_update(__MODULE__, fn state ->
      if Map.has_key?(state, key) do
        {{:error, :already_exists}, state}
      else
        {:ok, Map.put(state, key, value)}
      end
    end)
  end

  @doc "Returns all stored keys (for test assertions)."
  def keys do
    Agent.get(__MODULE__, &Map.keys/1)
  end
end
