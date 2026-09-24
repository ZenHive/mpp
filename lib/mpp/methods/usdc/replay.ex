defmodule MPP.Methods.USDC.Replay do
  @moduledoc """
  Atomic single-use keys for USDC credentials and merchant orders.

  A failed settlement releases the keys this attempt claimed. A successful
  settlement keeps them, so a second presentation cannot receive another
  receipt.
  """

  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.Tempo.Store

  @prefix "mpp:usdc:"

  @doc "Merchant-order key when the charge carries `externalId`."
  @spec order_key(Charge.t()) :: {:ok, String.t()} | :none
  def order_key(%Charge{external_id: id}) when is_binary(id) and id != "", do: {:ok, "order:" <> id}
  def order_key(_charge), do: :none

  @doc """
  Claim every `{key, failure_detail}` pair, run `fun`, and release the
  claims when `fun` returns an error.

  `store` is a `MPP.Tempo.Store` reference. `nil` skips persistence.
  """
  @spec with_claims(term(), [{String.t(), String.t()}], (-> result)) :: result
        when result: {:ok, term()} | {:error, Errors.t()}
  def with_claims(nil, _keys, fun) when is_function(fun, 0), do: fun.()

  def with_claims(store, keys, fun) when is_list(keys) and is_function(fun, 0) do
    case claim_all(store, keys, []) do
      {:ok, claimed} ->
        case fun.() do
          {:ok, _value} = ok ->
            ok

          {:error, %Errors{}} = error ->
            release_all(store, claimed)
            error
        end

      {:error, %Errors{}} = error ->
        error
    end
  end

  defp claim_all(_store, [], claimed), do: {:ok, Enum.reverse(claimed)}

  defp claim_all(store, [{key, detail} | rest], claimed) do
    case claim(store, key, detail) do
      {:ok, token} -> claim_all(store, rest, [{key, token} | claimed])
      {:error, %Errors{}} = error -> release_and_return(store, claimed, error)
    end
  end

  defp claim(store, key, detail) do
    token = System.unique_integer([:positive])

    case Store.check_and_mark(store, @prefix <> key, token) do
      :ok -> {:ok, token}
      {:error, :already_exists} -> {:error, Errors.new(:verification_failed, detail)}
      {:error, _reason} -> {:error, Errors.new(:verification_failed, "Dedup store error")}
    end
  end

  defp release_and_return(store, claimed, error) do
    release_all(store, claimed)
    error
  end

  defp release_all(store, claimed) do
    Enum.each(claimed, fn {key, token} -> Store.delete(store, @prefix <> key, token) end)
  end
end
