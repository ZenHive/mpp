defmodule MPP.Methods.Tempo.ProofSignature do
  @moduledoc false

  alias Cartouche.Hash
  alias MPP.Hex
  alias MPP.Methods.Tempo.KeyAuthorization
  alias MPP.Methods.Tempo.SignatureEnvelope

  @p256_half_order 0x7FFFFFFF800000007FFFFFFFFFFFFFFFDE737D56D38BCF4279DCE5617E3192A8
  @magic_suffix :binary.copy(<<0x77>>, 32)
  @unsupported_web_authn "unsupported proof signature type: WebAuthn"

  @type t :: SignatureEnvelope.t() | {:p256, binary()} | {:keychain, String.t(), t(), :v1 | :v2}

  @doc "Decode proof signatures while retaining legacy secp256k1 envelope semantics."
  @spec deserialize(String.t()) :: {:ok, t()} | {:error, String.t()}
  def deserialize(hex) do
    case SignatureEnvelope.deserialize(hex) do
      {:ok, envelope} -> {:ok, envelope}
      {:error, _reason} -> deserialize_extended(hex)
    end
  end

  defp deserialize_extended(hex) do
    case Base.decode16(Hex.strip_0x(hex), case: :mixed) do
      {:ok, bytes} -> decode(strip_magic(bytes))
      :error -> {:error, "invalid proof signature"}
    end
  end

  @doc "Return the primitive key type, including through a keychain wrapper."
  @spec key_type(t()) :: KeyAuthorization.key_type()
  def key_type({:keychain, _user, inner, _version}), do: key_type(inner)
  def key_type({:p256, _signature}), do: :p256
  def key_type({:secp256k1, _signature}), do: :secp256k1

  @doc "Verify a primitive proof signature and return its signer address."
  @spec extract_address(t(), <<_::256>>) :: {:ok, String.t()} | {:error, String.t()}
  def extract_address({:p256, signature}, digest), do: verify_p256(signature, digest)
  def extract_address(envelope, digest), do: SignatureEnvelope.extract_address(envelope, digest)

  defp decode(bytes) when byte_size(bytes) == 65, do: legacy_decode(bytes)
  defp decode(<<1, _::binary-size(129)>> = signature), do: {:ok, {:p256, signature}}
  defp decode(<<2, _::binary>>), do: {:error, @unsupported_web_authn}

  defp decode(<<prefix, user::binary-size(20), inner::binary>>) when prefix in [3, 4] do
    with {:ok, envelope} <- decode(inner) do
      {:ok, {:keychain, hex(user), envelope, if(prefix == 3, do: :v1, else: :v2)}}
    end
  end

  defp decode(bytes), do: legacy_decode(bytes)
  defp legacy_decode(bytes), do: SignatureEnvelope.deserialize(hex(bytes))

  defp strip_magic(bytes) when byte_size(bytes) > 32 do
    size = byte_size(bytes) - 32

    case bytes do
      <<signature::binary-size(^size), @magic_suffix>> -> signature
      _ -> bytes
    end
  end

  defp strip_magic(bytes), do: bytes

  # Tempo's primitive verifier uses low-s P-256 over the digest, or SHA256(digest)
  # when the envelope's prehash byte is nonzero (tt_signature.rs).
  defp verify_p256(<<1, r::256, s::256, public_key::binary-size(64), prehash>>, digest)
       when r > 0 and s > 0 and s <= @p256_half_order do
    digest = if prehash == 0, do: digest, else: :crypto.hash(:sha256, digest)
    signature = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})

    if :crypto.verify(:ecdsa, :sha256, {:digest, digest}, signature, [<<4, public_key::binary>>, :secp256r1]) do
      {:ok, public_key |> Hash.keccak() |> binary_part(12, 20) |> hex()}
    else
      {:error, "invalid P-256 proof signature"}
    end
  rescue
    _error in [ArgumentError, ErlangError] -> {:error, "invalid P-256 proof signature"}
  end

  defp verify_p256(_signature, _digest), do: {:error, "invalid P-256 proof signature"}
  defp hex(bytes), do: "0x" <> Base.encode16(bytes, case: :lower)
end
