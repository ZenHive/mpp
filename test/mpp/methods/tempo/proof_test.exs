defmodule MPP.Methods.Tempo.ProofTest do
  use ExUnit.Case, async: true
  use Onchain.Hex

  alias MPP.Methods.Tempo.Proof
  alias Onchain.Recover
  alias Onchain.Signer.Secp256k1

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

  # viem 2.57.1 fixture from mpp-rs #664 (75a0538),
  # refs/mpp-rs/src/protocol/methods/tempo/proof.rs:424-500: the proof typed
  # data for root key 0x11..11, signed by that key and as a Keychain V2
  # envelope by access key 0x22..22.
  describe "viem keychain V2 vector (mpp-rs proof.rs)" do
    @viem_proof_hash "0x2db9f3ad46355ef4479f0b322396221c624618117d42cfa3ddcce707682ab155"
    @viem_signature "0x3baf02ba159042829a9bcaa17774cecb25b0194cccff0dd076db7474befcaa2b26592fc409ed59c24888f9d3b276debe61696c86793e9a35632cbff79c3496d01c"
    @viem_keychain_signature "0x0419e7e376e7c213b7e7e7e46cc70a5dd086daff2aa64ad10a15b8ed2c208c147daf58f5ec3989b4de18173565f10d3acad84fc1cf3ccc20181099d57723b7b9f9ed3821442c44f641e0eb4e8a4f2965d15be9e8621c"

    defp fixture_address(byte) do
      {:ok, address} = Secp256k1.get_address(:binary.copy(<<byte>>, 32))
      "0x" <> Base.encode16(address, case: :lower)
    end

    defp viem_params do
      %{
        account: fixture_address(0x11),
        chain_id: 42_431,
        challenge_id: "kM9xPqWvT2nJrHsY4aDfEb",
        realm: "api.example.com"
      }
    end

    test "the proof hash and the root signature match viem" do
      assert viem_params() |> Proof.hash() |> to_hex() |> String.downcase() == @viem_proof_hash
      assert :ok = Proof.verify_signature(viem_params(), @viem_signature, fixture_address(0x11))
    end

    test "the keychain V2 envelope recovers the access key for its own user only" do
      root = fixture_address(0x11)
      access = fixture_address(0x22)

      assert {:ok, signer} = Proof.recover_authorized_proof_signer(viem_params(), @viem_keychain_signature, root)
      assert Onchain.Address.equal?(signer, access)

      assert {:error, "proof signature recovery failed"} =
               Proof.recover_authorized_proof_signer(
                 %{viem_params() | account: fixture_address(0x33)},
                 @viem_keychain_signature,
                 fixture_address(0x33)
               )
    end
  end

  describe "access-key proof signer recovery (mppx Charge.test.ts)" do
    @root_private_key "01" |> String.duplicate(32) |> Base.decode16!(case: :mixed)
    @access_private_key "02" |> String.duplicate(32) |> Base.decode16!(case: :mixed)

    test "recovers access key when proof is bound to root account" do
      {:ok, root_address} = Secp256k1.get_address(@root_private_key)
      {:ok, access_address} = Secp256k1.get_address(@access_private_key)
      root_hex = "0x" <> Base.encode16(root_address, case: :lower)

      params = %{
        account: root_hex,
        chain_id: @vector_chain_id,
        challenge_id: @vector_challenge_id,
        realm: @vector_realm
      }

      signature = sign_proof_digest!(Proof.hash(params), @access_private_key, access_address)

      refute Proof.verify_signature(params, signature, root_hex) == :ok

      assert {:ok, recovered} =
               Proof.recover_authorized_proof_signer(params, signature, root_hex)

      assert String.downcase(recovered) == String.downcase("0x" <> Base.encode16(access_address, case: :lower))
    end

    test "still recovers signer when claimed source differs (authorization checked later)" do
      {:ok, root_address} = Secp256k1.get_address(@root_private_key)
      {:ok, access_address} = Secp256k1.get_address(@access_private_key)
      root_hex = "0x" <> Base.encode16(root_address, case: :lower)
      other_root = "0x000000000000000000000000000000000000bEEF"
      access_hex = "0x" <> Base.encode16(access_address, case: :lower)

      params = %{
        account: root_hex,
        chain_id: @vector_chain_id,
        challenge_id: @vector_challenge_id,
        realm: @vector_realm
      }

      signature = sign_proof_digest!(Proof.hash(params), @access_private_key, access_address)

      assert {:ok, recovered} = Proof.recover_authorized_proof_signer(params, signature, other_root)
      assert String.downcase(recovered) == String.downcase(access_hex)
    end

    test "recovers access key from keychain v2 envelope when root matches source" do
      {:ok, root_address} = Secp256k1.get_address(@root_private_key)
      {:ok, access_address} = Secp256k1.get_address(@access_private_key)
      root_hex = "0x" <> Base.encode16(root_address, case: :lower)

      params = %{
        account: root_hex,
        chain_id: @vector_chain_id,
        challenge_id: @vector_challenge_id,
        realm: @vector_realm
      }

      digest = Proof.hash(params)
      keychain_payload = Onchain.Hash.keccak(<<0x04>> <> digest <> root_address)
      inner = sign_proof_digest!(keychain_payload, @access_private_key, access_address)
      signature = wrap_keychain_v2!(root_address, inner)

      assert {:ok, recovered} = Proof.recover_authorized_proof_signer(params, signature, root_hex)

      assert String.downcase(recovered) ==
               String.downcase("0x" <> Base.encode16(access_address, case: :lower))
    end

    test "rejects keychain envelope when user address does not match source" do
      {:ok, root_address} = Secp256k1.get_address(@root_private_key)
      {:ok, access_address} = Secp256k1.get_address(@access_private_key)
      root_hex = "0x" <> Base.encode16(root_address, case: :lower)

      other_root =
        Base.decode16!(String.replace_prefix("0x000000000000000000000000000000000000bEEF", "0x", ""), case: :mixed)

      params = %{
        account: root_hex,
        chain_id: @vector_chain_id,
        challenge_id: @vector_challenge_id,
        realm: @vector_realm
      }

      digest = Proof.hash(params)
      inner = sign_proof_digest!(digest, @access_private_key, access_address)
      signature = wrap_keychain_v1!(other_root, inner)

      assert {:error, "proof signature recovery failed"} =
               Proof.recover_authorized_proof_signer(params, signature, root_hex)
    end
  end

  defp wrap_keychain_v1!(user_address, inner_hex) do
    inner = Base.decode16!(String.replace_prefix(inner_hex, "0x", ""), case: :mixed)
    "0x" <> Base.encode16(<<0x03>> <> user_address <> inner, case: :lower)
  end

  defp wrap_keychain_v2!(user_address, inner_hex) do
    inner = Base.decode16!(String.replace_prefix(inner_hex, "0x", ""), case: :mixed)
    "0x" <> Base.encode16(<<0x04>> <> user_address <> inner, case: :lower)
  end

  defp sign_proof_digest!(digest, private_key, address) do
    {:ok, sig} = Secp256k1.sign_payload(digest, private_key)
    sig = Recover.normalize_low_s(sig)
    {:ok, recid} = Recover.find_recid_from_digest(digest, sig, address)

    r = sig.r |> Onchain.Hex.encode_bytes(32) |> Base.encode16(case: :lower)
    s = sig.s |> Onchain.Hex.encode_bytes(32) |> Base.encode16(case: :lower)
    "0x" <> r <> s <> Base.encode16(<<27 + recid>>, case: :lower)
  end
end
