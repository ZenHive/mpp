defmodule MPP.Methods.EVM.Permit2.Settlement do
  @moduledoc false

  import Bitwise

  alias MPP.Errors
  alias MPP.Methods.Shared
  alias Onchain.Address
  alias Onchain.Hex
  alias Onchain.RPC
  alias Onchain.Signer

  @doc "Reject a nonce whose bit is set in the canonical Permit2 bitmap."
  @spec check_nonce(String.t(), String.t(), non_neg_integer(), map()) :: :ok | {:error, Errors.t()}
  def check_nonce(contract, owner, nonce, config) do
    {:ok, owner} = Address.validate(owner)

    case Onchain.Contract.call(contract, "nonceBitmap(address,uint256)", [owner, nonce >>> 8], "(uint256)", opts(config)) do
      {:ok, [bitmap]} ->
        if (bitmap &&& 1 <<< (nonce &&& 255)) == 0,
          do: :ok,
          else: {:error, Errors.new(:verification_failed, "Permit2 nonce already used")}

      {:error, reason} ->
        rpc_error(reason)
    end
  end

  @doc "Simulate, sign, broadcast, and await a server-funded transaction."
  @spec submit(String.t(), String.t(), map()) :: {:ok, map()} | {:error, Errors.t()}
  def submit(to, calldata, config) do
    opts = opts(config)
    key = config["private_key"]
    chain = config["chain_id"]

    with {:ok, actual_chain} <- RPC.chain_id(opts),
         :ok <- match_chain(actual_chain, chain),
         {:ok, sender} <- Signer.address_from_key(key),
         {:ok, gas} <- RPC.eth_estimate_gas(%{from: sender, to: to, data: calldata}, opts),
         {:ok, nonce} <- RPC.get_transaction_count(sender, Keyword.put(opts, :block, "pending")),
         {:ok, bytes} <- Hex.decode(calldata),
         {:ok, unsigned} <- Signer.build_transaction(to, bytes, tx_opts(config, nonce, gas)),
         {:ok, signed} <- Signer.sign_transaction(unsigned, key, chain),
         {:ok, raw} <- Signer.encode_transaction(signed),
         {:ok, hash} <- RPC.eth_send_raw_transaction(raw, opts) do
      await_receipt(hash, opts, System.monotonic_time(:millisecond) + 60_000)
    else
      {:error, %Errors{} = error} -> {:error, error}
      {:error, reason} -> rpc_error(reason)
    end
  end

  defp match_chain(chain, chain), do: :ok
  defp match_chain(_, _), do: {:error, Errors.new(:verification_failed, "Permit2 RPC chain does not match challenge")}

  defp tx_opts(config, nonce, gas) do
    [nonce: nonce, chain_id: config["chain_id"], gas_limit: div(gas * 5 + 3, 4)]
    |> fee(:max_fee_per_gas, config["max_fee_per_gas"])
    |> fee(:max_priority_fee_per_gas, config["max_priority_fee_per_gas"])
  end

  defp fee(opts, _key, nil), do: opts
  defp fee(opts, key, value), do: Keyword.put(opts, key, value)

  defp await_receipt(hash, opts, deadline) do
    case RPC.get_transaction_receipt(hash, opts) do
      {:ok, nil} ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            1_000 -> await_receipt(hash, opts, deadline)
          end
        else
          {:error, Errors.new(:settlement_timeout, "Permit2 settlement was not confirmed")}
        end

      {:ok, receipt} ->
        with :ok <- Shared.check_receipt_status(receipt), do: {:ok, receipt}

      {:error, reason} ->
        rpc_error(reason)
    end
  end

  defp opts(config) do
    [rpc_url: config["rpc_url"], req_options: config["req_options"] || []]
  end

  defp rpc_error({:rpc_error, %{data: "0x756688fe"}}),
    do: {:error, Errors.new(:verification_failed, "Permit2 nonce already used")}

  defp rpc_error(_reason), do: {:error, Errors.new(:settlement_failed, "Permit2 RPC request failed")}
end
