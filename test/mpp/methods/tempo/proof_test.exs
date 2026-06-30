defmodule MPP.Methods.Tempo.ProofTest do
  use ExUnit.Case, async: true
  use Cartouche.Hex

  alias MPP.Methods.Tempo.Proof

  # Pinned from refs/mppx/src/tempo/Proof.conformance.test.ts (wallet-bound MPP v3).
  @vector_account "0x1a642f0E3c3aF545E7AcBD38b07251B3990914F1"
  @vector_chain_id 42_431
  @vector_challenge_id "kM9xPqWvT2nJrHsY4aDfEb"
  @vector_realm "api.example.com"
  @vector_digest "0x3860a700a55e02ad3c2dc047e92489feceecbdb0a801d948e1d9f0b61ea9bc3f"
  @vector_signature "0x53f5d64d9f995e841b4212639b2e17e508e96752e10316df3814a16443dcbdb626c082190a4c3ecc3148101eb443d15bd83b579380b1be735a9c99f0df36c9fe1b"

  defp vector_params do
    %{
      account: @vector_account,
      chain_id: @vector_chain_id,
      challenge_id: @vector_challenge_id,
      realm: @vector_realm
    }
  end

  describe "conformance vector (mppx Proof.conformance.test.ts)" do
    test "hash matches the deterministic EIP-712 digest" do
      assert vector_params() |> Proof.hash() |> to_hex() |> String.downcase() ==
               String.downcase(@vector_digest)
    end

    test "signature recovers to the bound wallet" do
      assert :ok = Proof.verify_signature(vector_params(), @vector_signature, @vector_account)
    end

    test "digest changes when account is swapped" do
      other = "0x000000000000000000000000000000000000dEaD"

      refute Proof.hash(Map.put(vector_params(), :account, other)) ==
               Proof.hash(vector_params())
    end

    test "rejects malformed signature hex" do
      assert {:error, "invalid proof signature"} =
               Proof.verify_signature(vector_params(), "0xdead", @vector_account)
    end

    test "rejects invalid expected account without raising" do
      assert {:error, "invalid proof account address"} =
               Proof.verify_signature(vector_params(), @vector_signature, "0xdead")
    end

    test "rejects signature that fails recovery" do
      bad_sig = "0x" <> String.duplicate("ab", 65)

      assert {:error, "proof signature recovery failed"} =
               Proof.verify_signature(vector_params(), bad_sig, @vector_account)
    end
  end
end
