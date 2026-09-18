defmodule MPP.X402.Replay do
  @moduledoc false

  alias MPP.Tempo.Store

  @prefix "mpp:x402:"

  @doc "Atomically claim an x402 authorization nonce so settlement cannot run twice."
  @spec claim(module() | {module(), keyword()} | nil, String.t()) :: :ok | {:error, :already_used | :store_error}
  def claim(nil, _nonce), do: :ok

  def claim(store, nonce) when is_binary(nonce) do
    value = System.system_time(:millisecond)

    case Store.check_and_mark(store, @prefix <> String.downcase(nonce), value) do
      :ok -> :ok
      {:error, :already_exists} -> {:error, :already_used}
      {:error, _reason} -> {:error, :store_error}
    end
  end
end
