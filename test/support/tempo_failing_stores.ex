defmodule MPP.Test.FailingPutStore do
  @moduledoc """
  Test store where `put/2` always fails and `check_and_mark/2` returns unexpected errors.
  Used to test dedup store error paths in `MPP.Methods.Tempo`.
  """

  @behaviour MPP.Tempo.Store

  @impl true
  def get(_key), do: :not_found

  @impl true
  def put(_key, _value), do: {:error, :store_failure}

  @impl true
  def check_and_mark(_key, _value), do: {:error, :unexpected_store_error}
end

defmodule MPP.Test.FaultyDeleteStore do
  @moduledoc """
  Agent store whose `delete/2` raises, exits, or returns `{:error, reason}`
  according to `start_link/1` `:mode`, leaving reserved keys in place.
  """

  @behaviour MPP.Tempo.Store

  use Agent

  alias MPP.Tempo.Store

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts) do
    mode = Keyword.get(opts, :mode, :raise)
    Agent.start_link(fn -> %{data: %{}, mode: mode} end, name: __MODULE__)
  end

  @impl Store
  def get(key) do
    case Agent.get(__MODULE__, &Map.get(&1.data, key)) do
      nil -> :not_found
      value -> {:ok, value}
    end
  end

  @impl Store
  def put(key, value) do
    Agent.update(__MODULE__, fn state -> %{state | data: Map.put(state.data, key, value)} end)
    :ok
  end

  @impl Store
  def check_and_mark(key, value) do
    Agent.get_and_update(__MODULE__, fn state ->
      if Map.has_key?(state.data, key) do
        {{:error, :already_exists}, state}
      else
        {:ok, %{state | data: Map.put(state.data, key, value)}}
      end
    end)
  end

  @impl Store
  def delete(key, expected) do
    case Agent.get_and_update(__MODULE__, &delete_op(&1, key, expected)) do
      {:raise, message} -> raise message
      {:exit, reason} -> exit(reason)
      other -> other
    end
  end

  @spec delete_op(map(), String.t(), term()) :: {term(), map()}
  defp delete_op(%{mode: :raise} = state, _key, _expected), do: {{:raise, "store delete crashed"}, state}
  defp delete_op(%{mode: :exit} = state, _key, _expected), do: {{:exit, :store_partitioned}, state}

  defp delete_op(%{mode: :error} = state, _key, _expected), do: {{:error, :store_failure}, state}

  defp delete_op(state, key, expected) do
    case Map.get(state.data, key) do
      ^expected -> {:ok, %{state | data: Map.delete(state.data, key)}}
      _other -> {:ok, state}
    end
  end
end
