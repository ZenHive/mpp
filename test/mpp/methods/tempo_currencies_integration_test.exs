defmodule MPP.Methods.TempoCurrenciesIntegrationTest do
  @moduledoc """
  Live OUSD settlement pin on Moderato. Uses the public faucet; no keys required.
  Override the RPC with `export TEMPO_RPC_URL=https://rpc.moderato.tempo.xyz`.
  """
  use ExUnit.Case, async: false

  alias MPP.Errors
  alias MPP.Methods.Tempo
  alias MPP.Receipt
  alias MPP.Test.FaucetWallet
  alias Onchain.Address
  alias Onchain.Tempo.RPC
  alias Onchain.Tempo.Transaction.Builder

  @moduletag :integration
  # docs.tempo.xyz/guide/ousd prints this account in lowercase and deploys it on
  # both mainnet and Moderato. Challenges use the EIP-55 form (viem/mppx).
  @ousd "0x20c0000000000000000000006a37DA5C996874BE"
  @ousd_docs "0x20c0000000000000000000006a37da5c996874be"
  @path_usd "0x20c0000000000000000000000000000000000000"
  @recipient "0x19e7e376e7c213b7e7e7e46cc70a5dd086daff2a"

  test "Moderato OUSD payment succeeds and cannot satisfy the pathUSD offer" do
    rpc_url = System.get_env("TEMPO_RPC_URL") || "https://rpc.moderato.tempo.xyz"
    wallet = FaucetWallet.tempo!(rpc_url)

    assert {:ok, raw} =
             Builder.build_signed_transfer(
               private_key: wallet.private_key,
               token: @ousd,
               recipient: @recipient,
               amount: 1_000_000,
               chain_id: 42_431,
               rpc_url: rpc_url,
               fee_token: @path_usd,
               nonce: 0
             )

    assert {:ok, hash, %{status: 1}} = RPC.broadcast_sync(raw, rpc_url)

    config =
      MPP.Plug.init(
        secret_key: String.duplicate("k", 32),
        realm: "ousd.integration.test",
        method: Tempo,
        amount: "1000000",
        recipient: @recipient,
        method_config: %{"chain_id" => 42_431, "rpc_url" => rpc_url, "store" => false}
      )

    assert Address.equal?(@ousd, @ousd_docs)
    assert Enum.map(config.method_entries, & &1.charge.currency) == [@ousd, @path_usd]
    [ousd, path_usd] = config.method_entries
    payload = %{"type" => "hash", "hash" => hash}
    charge = %{ousd.charge | method_details: ousd.method_config}
    assert {:ok, %Receipt{funding_currency: @ousd} = receipt} = Tempo.verify(payload, charge)
    assert {:ok, ^receipt} = receipt |> Receipt.encode() |> Receipt.decode()

    wrong_charge = %{path_usd.charge | method_details: path_usd.method_config}

    assert {:error, %Errors{detail: "No matching Transfer event found in transaction"}} =
             Tempo.verify(payload, wrong_charge)
  end
end
