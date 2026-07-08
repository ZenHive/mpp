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
