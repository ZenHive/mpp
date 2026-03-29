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

defmodule MPP.Test.NonAtomicStore do
  @moduledoc """
  Test store that implements only `get/1` and `put/2` (no `check_and_mark/2`).
  Forces the sequential fallback path in `reserve_hash_atomic/2`.
  """

  @behaviour MPP.Tempo.Store

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @impl true
  def get(key) do
    case Agent.get(__MODULE__, &Map.get(&1, key)) do
      nil -> :not_found
      value -> {:ok, value}
    end
  end

  @impl true
  def put(key, value) do
    Agent.update(__MODULE__, &Map.put(&1, key, value))
    :ok
  end

  # Deliberately does NOT implement check_and_mark/2
end

defmodule MPP.Test.NonAtomicFailingPutStore do
  @moduledoc """
  Non-atomic store where `put/2` always fails.
  Tests the sequential path's put-error branch.
  """

  @behaviour MPP.Tempo.Store

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @impl true
  def get(key) do
    case Agent.get(__MODULE__, &Map.get(&1, key)) do
      nil -> :not_found
      value -> {:ok, value}
    end
  end

  @impl true
  def put(_key, _value), do: {:error, :disk_full}

  # No check_and_mark/2 — forces sequential path
end

defmodule MPP.Test.NonAtomicGetFailStore do
  @moduledoc """
  Non-atomic store where `get/1` always fails.
  Tests the sequential path's get-error branch.
  """

  @behaviour MPP.Tempo.Store

  @impl true
  def get(_key), do: {:error, :connection_lost}

  @impl true
  def put(_key, _value), do: :ok

  # No check_and_mark/2 — forces sequential path
end
