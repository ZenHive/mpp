defmodule MPP.Methods.Tempo.EnvelopeFieldsTest do
  use ExUnit.Case, async: true

  alias MPP.Methods.Tempo.EnvelopeFields
  alias MPP.Methods.Tempo.SubscriptionTransaction
  alias MPP.Test.SubscriptionHelpers
  alias Onchain.Tempo.Transaction
  alias Onchain.Tempo.Transaction.Builder, as: TempoTxBuilder

  @rpc_url "https://rpc.moderato.tempo.xyz"
  @token_address "0x20C0000000000000000000000000000000000000"
  @recipient "0x1234567890AbcdEF1234567890aBcDeF12345678"
  @client_private_key "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

  test "a transaction without key authorization has no key authorization field" do
    {:ok, tx_hex} =
      TempoTxBuilder.build_fee_payer_transfer(
        private_key: @client_private_key,
        token: @token_address,
        recipient: @recipient,
        amount: 1_000_000,
        chain_id: 42_431,
        rpc_url: @rpc_url,
        gas_limit: 1_000_000,
        nonce: 0,
        nonce_key: Bitwise.bsl(1, 256) - 1,
        valid_before: System.os_time(:second) + 900
      )

    {:ok, %Transaction{key_authorization: nil} = tx} = Transaction.deserialize(tx_hex)

    assert {:error, "transaction does not carry a key authorization field"} =
             EnvelopeFields.key_authorization_field(tx)
  end

  test "returns the canonical RLP item of a carried key authorization" do
    subscription = SubscriptionHelpers.subscription()
    {_serialized, authorization, _rpc} = SubscriptionHelpers.signed_authorization(subscription)

    config = %{
      "chain_id" => SubscriptionHelpers.chain_id(),
      "rpc_url" => "https://moderato.invalid",
      "subscription_access_key_private_key" => SubscriptionHelpers.access_private_key(),
      "subscription_nonce" => 0,
      "fee_token" => SubscriptionHelpers.token()
    }

    {:ok, tx, _memo} =
      SubscriptionTransaction.build(subscription, authorization, SubscriptionHelpers.root_address(), config, "c1")

    assert {:ok, field} = EnvelopeFields.key_authorization_field(tx)
    assert field == authorization.field
  end
end
