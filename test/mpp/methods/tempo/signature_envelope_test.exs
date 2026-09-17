defmodule MPP.Methods.Tempo.SignatureEnvelopeTest do
  use ExUnit.Case, async: true

  alias Cartouche.Recover
  alias Cartouche.Signer.Curvy
  alias MPP.Methods.Tempo.SignatureEnvelope

  @root_private_key "01" |> String.duplicate(32) |> Base.decode16!(case: :mixed)
  @access_private_key "02" |> String.duplicate(32) |> Base.decode16!(case: :mixed)
  @digest_a "a1" |> String.duplicate(32) |> Base.decode16!(case: :mixed)
  @digest_b "b2" |> String.duplicate(32) |> Base.decode16!(case: :mixed)

  test "deserializes plain secp256k1 envelope" do
    {:ok, root_address} = Curvy.get_address(@root_private_key)
    digest = @digest_a
    sig_hex = sign_digest!(digest, @root_private_key, root_address)

    assert {:ok, {:secp256k1, _}} = SignatureEnvelope.deserialize(sig_hex)
  end

  test "rejects secp256k1 envelopes whose scalars or recovery id are out of range" do
    n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
    hex = fn r, s, v -> "0x" <> Base.encode16(<<r::unsigned-256, s::unsigned-256, v::8>>, case: :lower) end

    # r = 0 / s = 0 crashed recovery with a FunctionClauseError and v outside
    # 27..30 with a RuntimeError before decoding rejected them.
    for {r, s, v} <- [{0, 1, 27}, {1, 0, 28}, {n, 1, 27}, {1, n, 27}, {1, 1, 26}, {1, 1, 31}, {1, 1, 0}] do
      assert {:error, "invalid proof signature"} = SignatureEnvelope.deserialize(hex.(r, s, v))
    end

    assert {:ok, {:secp256k1, _}} = SignatureEnvelope.deserialize(hex.(1, n - 1, 30))
  end

  test "recovery fails closed when the library raises on an unusable signature" do
    unusable = {:secp256k1, %Elixir.Curvy.Signature{crv: :secp256k1, r: 0, s: 0, recid: 0}}
    zero = "0x" <> String.duplicate("0", 40)

    refute SignatureEnvelope.verify_secp256k1(unusable, @digest_a, zero)
    assert {:error, "proof signature recovery failed"} = SignatureEnvelope.extract_address(unusable, @digest_a)
  end

  test "deserializes keychain v1 and v2 envelopes" do
    {:ok, root_address} = Curvy.get_address(@root_private_key)
    {:ok, access_address} = Curvy.get_address(@access_private_key)
    root_hex = "0x" <> Base.encode16(root_address, case: :lower)
    digest = @digest_b

    for version <- [:v1, :v2] do
      payload =
        case version do
          :v1 -> digest
          :v2 -> Cartouche.Hash.keccak(<<0x04>> <> digest <> root_address)
        end

      inner_hex = sign_digest!(payload, @access_private_key, access_address)
      envelope_hex = wrap_keychain!(root_address, inner_hex, version)

      assert {:ok, {:keychain, ^root_hex, {:secp256k1, _}, ^version}} =
               SignatureEnvelope.deserialize(envelope_hex)
    end
  end

  test "extract_address and verify_secp256k1 for secp256k1 envelope" do
    {:ok, root_address} = Curvy.get_address(@root_private_key)
    root_hex = "0x" <> Base.encode16(root_address, case: :lower)
    digest = @digest_a
    sig_hex = sign_digest!(digest, @root_private_key, root_address)
    {:ok, envelope} = SignatureEnvelope.deserialize(sig_hex)

    assert {:ok, ^root_hex} = SignatureEnvelope.extract_address(envelope, digest)
    assert SignatureEnvelope.verify_secp256k1(envelope, digest, root_hex)
    refute SignatureEnvelope.verify_secp256k1(envelope, digest, "0x000000000000000000000000000000000000dEaD")
  end

  test "rejects invalid envelope bytes" do
    assert {:error, "invalid proof signature"} = SignatureEnvelope.deserialize("0xdead")
    assert {:error, "invalid proof signature"} = SignatureEnvelope.deserialize("0x" <> String.duplicate("ab", 10))
  end

  defp sign_digest!(digest, private_key, address) do
    {:ok, sig} = Curvy.sign_payload(digest, private_key)
    sig = Recover.normalize_low_s(sig)
    {:ok, recid} = Recover.find_recid_from_digest(digest, sig, address)

    r = sig.r |> Cartouche.Hex.encode_bytes(32) |> Base.encode16(case: :lower)
    s = sig.s |> Cartouche.Hex.encode_bytes(32) |> Base.encode16(case: :lower)
    "0x" <> r <> s <> Base.encode16(<<27 + recid>>, case: :lower)
  end

  defp wrap_keychain!(user_address, inner_hex, version) do
    user = user_address
    inner = Base.decode16!(String.replace_prefix(inner_hex, "0x", ""), case: :mixed)
    prefix = if version == :v2, do: <<0x04>>, else: <<0x03>>
    "0x" <> Base.encode16(prefix <> user <> inner, case: :lower)
  end
end
