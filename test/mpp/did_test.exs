defmodule MPP.DIDTest do
  use ExUnit.Case, async: true

  alias MPP.DID

  describe "evm_did/2" do
    test "returns correctly formatted DID string" do
      address = "0x742d35Cc6634c0532925a3b844bC9e7595F8fE00"
      chain_id = 42_431

      assert DID.evm_did(address, chain_id) ==
               "did:pkh:eip155:42431:0x742d35Cc6634c0532925a3b844bC9e7595F8fE00"
    end

    test "preserves address casing" do
      address = "0xAbCdEf0123456789AbCdEf0123456789AbCdEf01"

      assert DID.evm_did(address, 1) ==
               "did:pkh:eip155:1:0xAbCdEf0123456789AbCdEf0123456789AbCdEf01"
    end

    test "works with mainnet chain id" do
      address = "0x742d35Cc6634c0532925a3b844bC9e7595F8fE00"

      assert DID.evm_did(address, 4217) ==
               "did:pkh:eip155:4217:0x742d35Cc6634c0532925a3b844bC9e7595F8fE00"
    end
  end

  describe "parse_evm_did/1" do
    test "roundtrips evm_did/2" do
      address = "0x742d35Cc6634c0532925a3b844bC9e7595F8fE00"
      did = DID.evm_did(address, 42_431)

      assert {:ok, %{chain_id: 42_431, address: "0x742d35cc6634c0532925a3b844bc9e7595f8fe00"}} =
               DID.parse_evm_did(did)
    end

    test "rejects leading-zero chain id" do
      assert {:error, :invalid_did} =
               DID.parse_evm_did("did:pkh:eip155:042431:0x742d35Cc6634C0532925a3b844bC9e7595F8fE00")
    end

    test "rejects extra colon segments" do
      assert {:error, :invalid_did} =
               DID.parse_evm_did("did:pkh:eip155:42431:extra:0x742d35Cc6634C0532925a3b844bC9e7595F8fE00")
    end

    test "rejects missing address segment" do
      assert {:error, :invalid_did} = DID.parse_evm_did("did:pkh:eip155:42431")
    end

    test "rejects non-string input" do
      assert {:error, :invalid_did} = DID.parse_evm_did(nil)
    end
  end
end
