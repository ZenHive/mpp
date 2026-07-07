defmodule MPP.Methods.Tempo.EnvelopeFieldsTest do
  use ExUnit.Case, async: true

  alias MPP.Methods.Tempo.EnvelopeFields
  alias Onchain.Tempo.Transaction
  alias Onchain.Tempo.Transaction.Builder, as: TempoTxBuilder

  @rpc_url "https://rpc.moderato.tempo.xyz"
  @token_address "0x20C0000000000000000000000000000000000000"
  @recipient "0x1234567890AbcdEF1234567890aBcDeF12345678"
  @client_private_key "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

  test "field indices match onchain_tempo 0x76 wire layout" do
    assert EnvelopeFields.chain_id() == 0
    assert EnvelopeFields.max_priority_fee_per_gas() == 1
    assert EnvelopeFields.max_fee_per_gas() == 2
    assert EnvelopeFields.gas_limit() == 3
    assert EnvelopeFields.calls() == 4
    assert EnvelopeFields.access_list() == 5
    assert EnvelopeFields.nonce_key() == 6
    assert EnvelopeFields.nonce() == 7
    assert EnvelopeFields.valid_before() == 8
    assert EnvelopeFields.valid_after() == 9
    assert EnvelopeFields.fee_token() == 10
    assert EnvelopeFields.fee_payer_signature() == 11
    assert EnvelopeFields.aa_authorization_list() == 12
    assert EnvelopeFields.key_authorization() == 13
    assert EnvelopeFields.sender_signature() == 14
  end

  test "signed fee-payer transfer has the expected field count" do
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

    {:ok, %Transaction{fields: fields}} = Transaction.deserialize(tx_hex)
    assert length(fields) == EnvelopeFields.signed_field_count()
  end
end
