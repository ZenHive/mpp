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
end
