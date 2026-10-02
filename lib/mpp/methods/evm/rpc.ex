defmodule MPP.Methods.EVM.RPC do
  @moduledoc """
  Shared EVM JSON-RPC helpers used by hash, authorization, and transaction paths.
  """

  alias MPP.Errors
  alias MPP.Hex
  alias Onchain.Transaction.Info

  @doc "Require a non-negative integer `chain_id` in method config."
  @spec require_chain_id(map()) :: {:ok, non_neg_integer()} | {:error, Errors.t()}
  def require_chain_id(config) when is_map(config) do
    case config["chain_id"] do
      chain_id when is_integer(chain_id) and chain_id >= 0 -> {:ok, chain_id}
      _ -> {:error, Errors.new(:verification_failed, "EVM method missing required config: chain_id")}
    end
  end

  @doc "Normalize a 0x-prefixed transaction hash to lowercase."
  @spec canonicalize_hash(String.t()) :: String.t()
  def canonicalize_hash(hash) when is_binary(hash) do
    "0x" <> String.downcase(Hex.strip_0x(hash))
  end

  @doc """
  Fetch a transaction's recipient and value by hash (`eth_getTransactionByHash`).

  Legacy transactions carry `to`/`value`, typed ones `destination`/`amount`;
  both come back as `%{to: <<_::160>> | nil, value: non_neg_integer()}`.
  An unknown hash is `{:ok, nil}`.
  """
  @spec transaction_by_hash(String.t(), keyword()) ::
          {:ok, %{to: binary() | nil, value: non_neg_integer()} | nil} | {:error, term()}
  def transaction_by_hash(hash, opts) when is_binary(hash) and is_list(opts) do
    case Onchain.RPC.eth_get_transaction_by_hash(hash, opts) do
      {:ok, %Info{transaction: %Onchain.Transaction.V1{to: to, value: value}}} ->
        {:ok, %{to: to, value: value}}

      {:ok, %Info{transaction: %{destination: to, amount: value}}} ->
        {:ok, %{to: to, value: value}}

      {:error, :not_found} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Build Onchain.RPC options from an RPC URL and optional Req overrides."
  @spec rpc_opts(String.t(), map()) :: keyword()
  def rpc_opts(rpc_url, config) when is_binary(rpc_url) and is_map(config) do
    case config["req_options"] do
      nil -> [rpc_url: rpc_url]
      req_options -> [rpc_url: rpc_url, req_options: req_options]
    end
  end
end
