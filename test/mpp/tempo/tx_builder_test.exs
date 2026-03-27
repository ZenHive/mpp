defmodule MPP.Test.TempoTxBuilderTest do
  use ExUnit.Case, async: true

  alias MPP.Tempo.Transaction
  alias MPP.Test.TempoTxBuilder

  @private_key "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  @recipient "0x70997970c51812dc3a010c7d01b50e0d17dc79c8"
  @token "0x20c0000000000000000000000000000000000000"
  @chain_id 42_431
  @amount 1_000_000
  @rpc_url "https://rpc.example.test"

  describe "build_signed_transfer/1" do
    test "builds a signed 0x76 transaction that deserializes and matches the payment call" do
      assert {:ok, tx_hex} = TempoTxBuilder.build_signed_transfer(valid_opts())
      assert String.starts_with?(tx_hex, "0x76")

      assert {:ok, tx} = Transaction.deserialize(tx_hex)
      assert tx.chain_id == @chain_id

      assert {:ok, match} =
               Transaction.find_payment_call(tx, @token,
                 amount: Integer.to_string(@amount),
                 recipient: @recipient
               )

      assert match.amount == @amount
    end

    test "returns an error when a required option is missing" do
      opts = Keyword.delete(valid_opts(), :private_key)

      assert {:error, "missing required option: private_key"} =
               TempoTxBuilder.build_signed_transfer(opts)
    end

    test "returns an error on invalid private key hex" do
      opts = Keyword.put(valid_opts(), :private_key, "0xnothex")

      assert {:error, "invalid private_key: expected 32-byte hex string"} =
               TempoTxBuilder.build_signed_transfer(opts)
    end

    test "returns an error on invalid recipient address" do
      opts = Keyword.put(valid_opts(), :recipient, "0xnothex")

      assert {:error, "invalid recipient: expected 20-byte hex address"} =
               TempoTxBuilder.build_signed_transfer(opts)
    end

    test "returns an error on invalid fee token address" do
      opts = Keyword.put(valid_opts(), :fee_token, "0xnothex")

      assert {:error, "invalid fee_token: expected 20-byte hex address"} =
               TempoTxBuilder.build_signed_transfer(opts)
    end

    test "returns an error on invalid amount" do
      opts = Keyword.put(valid_opts(), :amount, "1000000")

      assert {:error, "invalid amount: expected non-negative integer"} =
               TempoTxBuilder.build_signed_transfer(opts)
    end

    test "returns an error on invalid explicit nonce" do
      opts = Keyword.put(valid_opts(), :nonce, "bad-nonce")

      assert {:error, "invalid nonce: expected non-negative integer"} =
               TempoTxBuilder.build_signed_transfer(opts)
    end
  end

  defp valid_opts do
    [
      private_key: @private_key,
      token: @token,
      recipient: @recipient,
      amount: @amount,
      chain_id: @chain_id,
      rpc_url: @rpc_url,
      nonce: 0
    ]
  end
end
