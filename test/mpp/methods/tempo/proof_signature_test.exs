defmodule MPP.Methods.Tempo.ProofSignatureTest do
  use ExUnit.Case, async: true

  alias Cartouche.Hash
  alias MPP.Methods.Tempo.Proof
  alias MPP.Methods.Tempo.ProofSignature

  @order 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
  @account "0x" <> String.duplicate("12", 20)
  @params %{account: @account, chain_id: 42_431, challenge_id: "p256-proof", realm: "example.test"}

  test "P-256 digest and SHA256 prehash signatures verify and bind to the challenge" do
    digest = Proof.hash(@params)

    for prehash <- [0, 1, 255] do
      {signature, address} = sign(digest, prehash)
      assert {:ok, envelope} = ProofSignature.deserialize(hex(signature))
      assert ProofSignature.key_type(envelope) == :p256
      assert {:ok, ^address} = ProofSignature.extract_address(envelope, digest)

      assert {:ok, %{address: ^address, key_type: :p256}} =
               Proof.recover_authorized_proof_key(@params, hex(signature), @account)

      assert {:error, _} =
               Proof.recover_authorized_proof_signer(%{@params | realm: "other.test"}, hex(signature), @account)
    end
  end

  test "P-256 keychain versions bind the root and v2 payload" do
    {:ok, account} = Onchain.Address.validate(@account)
    digest = Proof.hash(@params)

    for version <- [3, 4] do
      payload = if version == 3, do: digest, else: Hash.keccak(<<4, digest::binary, account::binary>>)
      {signature, address} = sign(payload, 0)
      wrapped = hex(<<version, account::binary, signature::binary>>)
      assert {:ok, ^address} = Proof.recover_authorized_proof_signer(@params, wrapped, @account)
      assert {:error, _} = Proof.recover_authorized_proof_signer(@params, wrapped, "0x" <> String.duplicate("34", 20))
      assert {:ok, envelope} = ProofSignature.deserialize(wrapped)
      assert ProofSignature.key_type(envelope) == :p256
      nested = hex(<<version, account::binary, version, account::binary, signature::binary>>)
      assert {:error, _} = Proof.recover_authorized_proof_signer(@params, nested, @account)
    end
  end

  test "rejects invalid lengths, scalars, public keys and high-s signatures" do
    digest = Proof.hash(@params)
    {<<1, r::256, s::256, key::binary-size(64), flag>>, _address} = sign(digest, 0)

    for invalid <- [<<1, 0>>, <<1>>, <<1, 0::1040>>, <<>>, <<9>>] do
      assert {:error, _} = ProofSignature.deserialize(hex(invalid))
    end

    assert {:error, _} = ProofSignature.deserialize("0xzz")

    for signature <- [
          <<1, 0::256, s::256, key::binary, flag>>,
          <<1, r::256, 0::256, key::binary, flag>>,
          <<1, r::256, @order - s::256, key::binary, flag>>,
          <<1, @order::256, s::256, key::binary, flag>>,
          <<1, r::256, s::256, 0::512, flag>>
        ] do
      assert {:ok, envelope} = ProofSignature.deserialize(hex(signature))
      assert {:error, "invalid P-256 proof signature"} = ProofSignature.extract_address(envelope, digest)
    end
  end

  test "WebAuthn fails explicitly, including malformed and wrapped envelopes" do
    {:ok, account} = Onchain.Address.validate(@account)

    for bytes <- [<<2>>, <<2, 0::1024>>, <<3, account::binary, 2>>, <<4, account::binary, 2, 0::1024>>] do
      assert {:error, "unsupported proof signature type: WebAuthn"} = ProofSignature.deserialize(hex(bytes))

      assert {:error, "unsupported proof signature type: WebAuthn"} =
               Proof.recover_authorized_proof_signer(@params, hex(bytes), @account)
    end
  end

  test "wallet magic suffix and secp256k1 length precedence are preserved" do
    digest = Proof.hash(@params)
    {signature, address} = sign(digest, 0)
    assert {:ok, envelope} = ProofSignature.deserialize(hex(signature <> :binary.copy(<<0x77>>, 32)))
    assert {:ok, ^address} = ProofSignature.extract_address(envelope, digest)
    assert {:ok, secp} = ProofSignature.deserialize(hex(<<2, 1::504, 27>>))
    assert ProofSignature.key_type(secp) == :secp256k1
  end

  test "legacy signer extraction delegates without changing secp256k1 signatures" do
    private = :binary.copy(<<1>>, 32)
    {:ok, address} = Cartouche.Signer.Curvy.get_address(private)
    digest = Proof.hash(@params)
    signature = MPP.Test.TempoAccessKey.sign_proof!(digest, private, address)
    assert {:ok, envelope} = ProofSignature.deserialize(signature)
    assert ProofSignature.extract_address(envelope, digest) == {:ok, hex(address)}
  end

  defp sign(digest, prehash) do
    {<<4, key::binary>>, private} = :crypto.generate_key(:ecdh, :secp256r1)
    payload = if prehash == 0, do: digest, else: :crypto.hash(:sha256, digest)
    der = :crypto.sign(:ecdsa, :sha256, {:digest, payload}, [private, :secp256r1])
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    s = min(s, @order - s)
    address = key |> Hash.keccak() |> binary_part(12, 20) |> hex()
    {<<1, r::256, s::256, key::binary, prehash>>, address}
  end

  defp hex(bytes), do: "0x" <> Base.encode16(bytes, case: :lower)
end
