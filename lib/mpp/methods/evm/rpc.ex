defmodule MPP.Methods.EVM.RPC do
  @moduledoc """
  Shared EVM JSON-RPC helpers used by hash, authorization, and transaction paths.
  """

  alias MPP.Errors
  alias MPP.Hex

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

  Reads only `to` and `value` from the raw result rather than decoding a full
  Ethereum signing envelope, so chain-specific transaction types (OP Stack
  deposits, zkSync, Celo) still verify. Both fields are validated strictly:
  `to` is `nil` or a 20-byte address, `value` a hex quantity.
  An unknown hash is `{:ok, nil}`.
  """
  @spec transaction_by_hash(String.t(), keyword()) ::
          {:ok, %{to: binary() | nil, value: non_neg_integer()} | nil} | {:error, term()}
  def transaction_by_hash(hash, opts) when is_binary(hash) and is_list(opts) do
    case Onchain.RPC.call("eth_getTransactionByHash", [hash], opts) do
      {:ok, nil} -> {:ok, nil}
      {:ok, %{} = tx} -> decode_transfer(tx)
      {:ok, other} -> {:error, {:invalid_transaction, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_transfer(%{"value" => value} = tx) when is_binary(value) do
    with {:ok, to} <- decode_to(Map.get(tx, "to")),
         {:ok, amount} <- decode_quantity(value) do
      {:ok, %{to: to, value: amount}}
    end
  end

  defp decode_transfer(tx), do: {:error, {:invalid_transaction, tx}}

  defp decode_to(nil), do: {:ok, nil}

  defp decode_to("0x" <> hex = to) when byte_size(hex) == 40 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, address} -> {:ok, address}
      :error -> {:error, {:invalid_transaction_to, to}}
    end
  end

  defp decode_to(to), do: {:error, {:invalid_transaction_to, to}}

  defp decode_quantity("0x" <> digits = value) do
    if digits =~ ~r/\A[0-9a-fA-F]+\z/,
      do: {:ok, String.to_integer(digits, 16)},
      else: {:error, {:invalid_transaction_value, value}}
  end

  defp decode_quantity(value), do: {:error, {:invalid_transaction_value, value}}

  @doc "Build Onchain.RPC options from an RPC URL and optional Req overrides."
  @spec rpc_opts(String.t(), map()) :: keyword()
  def rpc_opts(rpc_url, config) when is_binary(rpc_url) and is_map(config) do
    case config["req_options"] do
      nil -> [rpc_url: rpc_url]
      req_options -> [rpc_url: rpc_url, req_options: req_options]
    end
  end
end
