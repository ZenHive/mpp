defmodule MPP.Session.VoucherTest do
  use ExUnit.Case, async: true

  import Bitwise, only: [<<<: 2]

  alias Cartouche.Typed.Domain
  alias MPP.Session.Voucher
  alias Onchain.Hex

  @channel_id "0x57e629663a75a0a49f8dc65c9f62ee38ab5dfa9124d7316d160766e4ecbc1227"
  @cumulative_amount 50
  @escrow_contract "0x4d50500000000000000000000000000000000000"
  @chain_id 42_431
  @signer "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
  @max_uint96 (1 <<< 96) - 1

  # refs/mpp-rs/src/protocol/methods/tempo/precompile_voucher.rs
  # precompile_voucher_signing_hash_matches_tip1034_golden.
  @tip1034_digest "0x41a23f1573d302acae1dcec60d237f78d2514768faf670ef27458931c38b5db3"
  @tip1034_signature "0x543a3c0d8484f2f0e2a6f190c87e07803cf96b9abdd6d15337455469c003861f40ef9cbf9411ef324692c1bfbc384efee9fd0476d1cd46743afcd6c82638b3b11b"

  describe "EIP-712 conformance" do
    test "matches the mpp-rs TIP-1034 digest and verifies a deterministic signature" do
      voucher = voucher()

      assert {:ok, digest} = Voucher.hash(voucher, @escrow_contract, @chain_id)
      assert Hex.encode(digest) == @tip1034_digest
      assert Voucher.hash!(voucher, @escrow_contract, @chain_id) == digest
      assert :ok = Voucher.verify_signature(voucher, @escrow_contract, @chain_id, @signer)
    end

    test "builds the TIP-1034 domain and uint96 voucher type" do
      assert {:ok, typed_data} = Voucher.typed_data(voucher(), @escrow_contract, @chain_id)
      assert %Domain{name: "TIP20 Channel Reserve", version: "1", chain_id: @chain_id} = typed_data.domain
      assert typed_data.domain.verifying_contract == Hex.decode!(@escrow_contract)

      assert typed_data.types["Voucher"].fields == [
               {"channelId", {:bytes, 32}},
               {"cumulativeAmount", {:uint, 96}}
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
      upper_signature = uppercase_hex(@tip1034_signature)

      assert {:ok, voucher} =
               Voucher.new(
                 channel_id: uppercase_hex(@channel_id),
                 cumulative_amount: @cumulative_amount,
                 signature: upper_signature
               )

      assert voucher.channel_id == @channel_id
      assert voucher.signature == @tip1034_signature
    end

    test "accepts uint96 boundaries and rejects overflow" do
      assert {:ok, _voucher} =
               Voucher.new(
                 channel_id: @channel_id,
                 cumulative_amount: 0,
                 signature: @tip1034_signature
               )

      assert {:ok, _voucher} =
               Voucher.new(
                 channel_id: @channel_id,
                 cumulative_amount: @max_uint96,
                 signature: @tip1034_signature
               )

      for invalid <- [-1, @max_uint96 + 1, "1", nil] do
        assert {:error, :invalid_cumulative_amount} =
                 Voucher.new(
                   channel_id: @channel_id,
                   cumulative_amount: invalid,
                   signature: @tip1034_signature
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

      eip155_signature = String.replace_suffix(@tip1034_signature, "1b", "24")

      assert {:error, :invalid_signature} =
               Voucher.new(
                 channel_id: @channel_id,
                 cumulative_amount: @cumulative_amount,
                 signature: eip155_signature
               )

      magic_signature = @tip1034_signature <> String.duplicate("77", 32)

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
      signature: @tip1034_signature
    )
  end

  defp uppercase_hex("0x" <> hex), do: "0x" <> String.upcase(hex)
end
