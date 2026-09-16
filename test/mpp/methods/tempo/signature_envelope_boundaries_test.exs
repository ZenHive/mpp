defmodule MPP.Methods.Tempo.SignatureEnvelopeBoundariesTest do
  use ExUnit.Case, async: true

  alias MPP.Methods.Tempo.SignatureEnvelope

  test "rejects invalid hex, truncated keychains, and invalid inner envelopes" do
    for signature <- ["0x", "0xzz", "0x0"] do
      assert {:error, "invalid proof signature"} = SignatureEnvelope.deserialize(signature)
    end

    for prefix <- [3, 4] do
      assert {:error, "invalid keychain signature"} = SignatureEnvelope.deserialize(hex(<<prefix, 0>>))

      assert {:error, "invalid proof signature"} =
               SignatureEnvelope.deserialize(hex(<<prefix>> <> :binary.copy(<<0>>, 86)))
    end
  end

  test "keychain extraction delegates to the inner signature, but is not a primitive" do
    {:ok, address} = Cartouche.Signer.Curvy.get_address(:binary.copy(<<1>>, 32))
    digest = :binary.copy(<<1>>, 32)
    signature = MPP.Test.TempoAccessKey.sign_proof!(digest, :binary.copy(<<1>>, 32), address)
    {:ok, inner} = SignatureEnvelope.deserialize(signature)
    wrapper = {:keychain, hex(address), inner, :v2}
    assert SignatureEnvelope.extract_address(wrapper, digest) == {:ok, hex(address)}
    refute SignatureEnvelope.verify_secp256k1(wrapper, digest, hex(address))
  end

  test "strips the Tempo wallet magic suffix without changing the envelope" do
    bytes = :binary.copy(<<1>>, 64) <> <<27>>

    assert SignatureEnvelope.deserialize(hex(bytes)) ==
             SignatureEnvelope.deserialize(hex(bytes <> :binary.copy(<<0x77>>, 32)))
  end

  defp hex(bytes), do: "0x" <> Base.encode16(bytes, case: :lower)
end
