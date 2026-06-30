defmodule MPP.Methods.Tempo.ProofTest do
  use ExUnit.Case, async: true
  use Cartouche.Hex

  alias Cartouche.Recover
  alias Cartouche.Signer.Curvy
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

  describe "access-key proof signer recovery (mppx Charge.test.ts)" do
    @root_private_key "01" |> String.duplicate(32) |> Base.decode16!(case: :mixed)
    @access_private_key "02" |> String.duplicate(32) |> Base.decode16!(case: :mixed)

    test "recovers access key when proof is bound to root account" do
      {:ok, root_address} = Curvy.get_address(@root_private_key)
      {:ok, access_address} = Curvy.get_address(@access_private_key)
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
      {:ok, root_address} = Curvy.get_address(@root_private_key)
      {:ok, access_address} = Curvy.get_address(@access_private_key)
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
      {:ok, root_address} = Curvy.get_address(@root_private_key)
      {:ok, access_address} = Curvy.get_address(@access_private_key)
      root_hex = "0x" <> Base.encode16(root_address, case: :lower)

      params = %{
        account: root_hex,
        chain_id: @vector_chain_id,
        challenge_id: @vector_challenge_id,
        realm: @vector_realm
      }

      digest = Proof.hash(params)
      keychain_payload = Cartouche.Hash.keccak(<<0x04>> <> digest <> root_address)
      inner = sign_proof_digest!(keychain_payload, @access_private_key, access_address)
      signature = wrap_keychain_v2!(root_address, inner)

      assert {:ok, recovered} = Proof.recover_authorized_proof_signer(params, signature, root_hex)

      assert String.downcase(recovered) ==
               String.downcase("0x" <> Base.encode16(access_address, case: :lower))
    end

    test "rejects keychain envelope when user address does not match source" do
      {:ok, root_address} = Curvy.get_address(@root_private_key)
      {:ok, access_address} = Curvy.get_address(@access_private_key)
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
    {:ok, sig} = Curvy.sign_payload(digest, private_key)
    sig = Recover.normalize_low_s(sig)
    {:ok, recid} = Recover.find_recid_from_digest(digest, sig, address)

    r = sig.r |> Cartouche.Hex.encode_bytes(32) |> Base.encode16(case: :lower)
    s = sig.s |> Cartouche.Hex.encode_bytes(32) |> Base.encode16(case: :lower)
    "0x" <> r <> s <> Base.encode16(<<27 + recid>>, case: :lower)
  end
end
