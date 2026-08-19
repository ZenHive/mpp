defmodule MPP.Session.VoucherTest do
  use ExUnit.Case, async: true

  import Bitwise, only: [<<<: 2]

  alias Cartouche.Typed.Domain
  alias MPP.Session.Voucher
  alias Onchain.Hex

  @channel_id "0x5db832ef1f06a767e0561f2fe53231240f8804895a21d5804ddb15b329c73c5e"
  @cumulative_amount 1_000_000
  @escrow_contract "0x5555555555555555555555555555555555555555"
  @chain_id 42_431
  @signer "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
  @max_uint128 (1 <<< 128) - 1

  # Generated with mppx's legacy Voucher.ts domain/types and viem's
  # hashTypedData/privateKeyToAccount using the Anvil account-0 key.
  @mppx_digest "0x65634beff4a9c9761b8b67baedefc7f10f671ef27263182af880dfd78b4c84e4"
  @mppx_signature "0x729359a3e060a6822af39785f1c806d820f6fb25bf94cb075038c60dc33fb37262db7e618685db686c2f870ead2e955ae0d907dde5739607d15ef1dafc65a31b1c"

  describe "EIP-712 conformance" do
    test "matches the mppx voucher digest and verifies its signature" do
      voucher = voucher()

      assert {:ok, digest} = Voucher.hash(voucher, @escrow_contract, @chain_id)
      assert Hex.encode(digest) == @mppx_digest
      assert Voucher.hash!(voucher, @escrow_contract, @chain_id) == digest
      assert :ok = Voucher.verify_signature(voucher, @escrow_contract, @chain_id, @signer)
    end

    test "builds the legacy stream-channel domain and uint128 voucher type" do
      assert {:ok, typed_data} = Voucher.typed_data(voucher(), @escrow_contract, @chain_id)
      assert %Domain{name: "Tempo Stream Channel", version: "1", chain_id: @chain_id} = typed_data.domain
      assert typed_data.domain.verifying_contract == Hex.decode!(@escrow_contract)

      assert typed_data.types["Voucher"].fields == [
               {"channelId", {:bytes, 32}},
               {"cumulativeAmount", {:uint, 128}}
             ]

      assert Voucher.typed_data!(voucher(), @escrow_contract, @chain_id) == typed_data
    end

    test "rejects tampering and domain changes" do
      voucher = voucher()

      assert {:error, :signature_mismatch} =
               voucher
               |> Map.put(:cumulative_amount, @cumulative_amount + 1)
               |> Voucher.verify_signature(@escrow_contract, @chain_id, @signer)

      assert {:error, :signature_mismatch} =
               voucher
               |> Map.put(:channel_id, "0x" <> String.duplicate("99", 32))
               |> Voucher.verify_signature(@escrow_contract, @chain_id, @signer)

      assert {:error, :signature_mismatch} =
               Voucher.verify_signature(voucher, @escrow_contract, 1, @signer)

      assert {:error, :signature_mismatch} =
               Voucher.verify_signature(
                 voucher,
                 "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                 @chain_id,
                 @signer
               )

      assert {:error, :signature_mismatch} =
               Voucher.verify_signature(
                 voucher,
                 @escrow_contract,
                 @chain_id,
                 "0x0000000000000000000000000000000000000001"
               )
    end
  end

  describe "validation" do
    test "normalizes the voucher wire values" do
      upper_signature = uppercase_hex(@mppx_signature)

      assert {:ok, voucher} =
               Voucher.new(
                 channel_id: uppercase_hex(@channel_id),
                 cumulative_amount: @cumulative_amount,
                 signature: upper_signature
               )

      assert voucher.channel_id == @channel_id
      assert voucher.signature == @mppx_signature
    end

    test "accepts uint128 boundaries and rejects overflow" do
      assert {:ok, _voucher} =
               Voucher.new(
                 channel_id: @channel_id,
                 cumulative_amount: 0,
                 signature: @mppx_signature
               )

      assert {:ok, _voucher} =
               Voucher.new(
                 channel_id: @channel_id,
                 cumulative_amount: @max_uint128,
                 signature: @mppx_signature
               )

      for invalid <- [-1, @max_uint128 + 1, "1", nil] do
        assert {:error, :invalid_cumulative_amount} =
                 Voucher.new(
                   channel_id: @channel_id,
                   cumulative_amount: invalid,
                   signature: @mppx_signature
                 )
      end
    end

    test "rejects malformed and non-canonical signatures" do
      assert {:error, :invalid_signature} =
               Voucher.new(
                 channel_id: @channel_id,
                 cumulative_amount: @cumulative_amount,
                 signature: "0xdead"
               )

      eip155_signature = String.replace_suffix(@mppx_signature, "1c", "24")

      assert {:error, :invalid_signature} =
               Voucher.new(
                 channel_id: @channel_id,
                 cumulative_amount: @cumulative_amount,
                 signature: eip155_signature
               )

      magic_signature = @mppx_signature <> String.duplicate("77", 32)

      assert {:error, :invalid_signature} =
               Voucher.new(
                 channel_id: @channel_id,
                 cumulative_amount: @cumulative_amount,
                 signature: magic_signature
               )

      assert_raise ArgumentError, fn ->
        Voucher.new!(channel_id: "0xdead", cumulative_amount: 0, signature: "0xdead")
      end
    end

    test "returns typed errors for invalid verification inputs" do
      assert {:error, :invalid_escrow_contract} =
               Voucher.hash(voucher(), "0xdead", @chain_id)

      assert {:error, :invalid_chain_id} =
               Voucher.hash(voucher(), @escrow_contract, -1)

      assert {:error, :invalid_expected_signer} =
               Voucher.verify_signature(voucher(), @escrow_contract, @chain_id, "0xdead")

      assert {:error, :invalid_signature} =
               Voucher.verify_signature(%{voucher() | signature: nil}, @escrow_contract, @chain_id, @signer)

      unrecoverable = "0x" <> String.duplicate("00", 64) <> "1b"

      assert {:error, :signature_recovery_failed} =
               Voucher.verify_signature(
                 %{voucher() | signature: unrecoverable},
                 @escrow_contract,
                 @chain_id,
                 @signer
               )

      assert_raise ArgumentError, fn ->
        Voucher.typed_data!(voucher(), "0xdead", @chain_id)
      end

      assert_raise ArgumentError, fn ->
        Voucher.hash!(voucher(), "0xdead", @chain_id)
      end
    end
  end

  defp voucher do
    Voucher.new!(
      channel_id: @channel_id,
      cumulative_amount: @cumulative_amount,
      signature: @mppx_signature
    )
  end

  defp uppercase_hex("0x" <> hex), do: "0x" <> String.upcase(hex)
end
