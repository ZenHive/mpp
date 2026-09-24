defmodule MPP.Test.FaucetWallet do
  @moduledoc false

  # One `tempo_fundAddress` grant is larger than a charge. The minimum only
  # tells the loop when the fee-token balance has landed.
  @tempo_minimum 1_000_000
  @xrpl_minimum 1

  @spec tempo!(String.t()) :: Faucet.EVM.wallet()
  def tempo!(rpc_url) when is_binary(rpc_url) do
    {:ok, wallet} = Faucet.EVM.fresh_wallet()
    Faucet.ensure_min_balance!(Faucet.Source.Tempo, wallet.address_hex, @tempo_minimum, rpc_url: rpc_url)
    wallet
  end

  @spec xrpl!(String.t()) :: %{required(String.t()) => String.t()}
  def xrpl!(rpc_url) when is_binary(rpc_url) do
    wallet = xrpl_keypair!()
    Faucet.ensure_min_balance!(Faucet.Source.XRPL, wallet["address"], @xrpl_minimum, rpc_url: rpc_url)
    wallet
  end

  defp xrpl_keypair! do
    script = Path.expand("xrpl/sign.cjs", __DIR__)
    {output, 0} = System.cmd("node", [script, "{}"], stderr_to_stdout: true)
    Jason.decode!(output)
  end
end
