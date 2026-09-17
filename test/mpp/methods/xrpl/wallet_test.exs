defmodule MPP.Methods.XRPL.WalletTest do
  use ExUnit.Case, async: true

  alias MPP.Methods.XRPL.Wallet

  @fixture "test/fixtures/xrpl/session.json" |> File.read!() |> Jason.decode!()

  test "sign_claim rejects an ed25519 wallet whose private key cannot be used to sign" do
    wallet = wallet!("ed25519")

    assert :error = Wallet.sign_claim(%{wallet | private_key: <<>>}, claim_tx(wallet))
  end

  test "sign_claim rejects a secp256k1 wallet whose private key cannot be used to sign" do
    wallet = wallet!("secp256k1")

    assert :error = Wallet.sign_claim(%{wallet | private_key: <<>>}, claim_tx(wallet))
  end

  defp wallet!(label) do
    {:ok, wallet} = Wallet.from_seed(@fixture["destination"][label]["seed"])
    wallet
  end

  defp claim_tx(wallet) do
    %{
      "TransactionType" => "PaymentChannelClaim",
      "Account" => wallet.address,
      "Channel" => @fixture["channelId"],
      "Amount" => "200000",
      "Balance" => "200000",
      "Signature" => @fixture["claims"]["voucher"],
      "PublicKey" => @fixture["payer"]["publicKey"],
      "Flags" => 131_072,
      "Sequence" => 1,
      "LastLedgerSequence" => 100,
      "Fee" => "12"
    }
  end
end
