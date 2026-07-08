defmodule MPP.Methods.Tempo.SignatureEnvelope do
  @moduledoc false

  use Cartouche.Hex

  alias Cartouche.Recover
  alias Curvy.Signature, as: CurvySignature
  alias MPP.Hex

  @magic_suffix :binary.copy(<<0x77>>, 32)

  @type secp256k1 :: {:secp256k1, CurvySignature.t()}
  @type keychain :: {:keychain, String.t(), secp256k1() | keychain(), :v1 | :v2}
  @type t :: secp256k1() | keychain()

  @doc """
  Deserialize a Tempo signature envelope hex string.

  Supports secp256k1 (65-byte legacy) and keychain V1 (`0x03`) / V2 (`0x04`) wrappers
  used by the proof access-key authorization path in `refs/mppx/src/tempo/server/Charge.ts`.
  """
  @spec deserialize(String.t()) :: {:ok, t()} | {:error, String.t()}
  def deserialize(signature_hex) when is_binary(signature_hex) do
    with {:ok, bytes} <- decode_hex_bytes(signature_hex) do
      bytes = strip_magic(bytes)
      deserialize_bytes(bytes)
    end
  end

  @doc """
  Recover the signer address for a secp256k1 envelope over `payload` (32-byte digest).
  """
  @spec extract_address(t(), <<_::256>>) :: {:ok, String.t()} | {:error, String.t()}
  def extract_address({:secp256k1, signature}, payload) when is_binary(payload) do
    recover_address(payload, signature)
  end

  def extract_address({:keychain, _user, inner, _version}, payload) do
    extract_address(inner, payload)
  end

  @doc """
  Returns `true` when `envelope` is a valid secp256k1 signature over `payload` for `address`.
  """
  @spec verify_secp256k1(t(), <<_::256>>, String.t()) :: boolean()
  def verify_secp256k1({:secp256k1, signature}, payload, address) do
    case recover_address(payload, signature) do
      {:ok, recovered} -> Onchain.Address.equal?(recovered, address)
      {:error, _} -> false
    end
  end

  def verify_secp256k1({:keychain, _user, _inner, _version}, _payload, _address), do: false

  defp deserialize_bytes(bytes) when byte_size(bytes) == 65 do
    decode_secp256k1(bytes)
  end

  defp deserialize_bytes(<<0x03, rest::binary>>) do
    decode_keychain(rest, :v1)
  end

  defp deserialize_bytes(<<0x04, rest::binary>>) do
    decode_keychain(rest, :v2)
  end

  defp deserialize_bytes(_), do: {:error, "invalid proof signature"}

  defp decode_keychain(bytes, version) do
    case split_user_and_inner(bytes) do
      {:ok, <<user::binary-size(20), inner_bytes::binary>>} ->
        user_hex = to_hex(user)

        case deserialize_bytes(inner_bytes) do
          {:ok, inner} -> {:ok, {:keychain, user_hex, inner, version}}
          error -> error
        end

      error ->
        error
    end
  end

  defp split_user_and_inner(bytes) when byte_size(bytes) >= 85 do
    {:ok, bytes}
  end

  defp split_user_and_inner(_), do: {:error, "invalid keychain signature"}

  defp decode_secp256k1(bytes) do
    <<r::binary-size(32), s::binary-size(32), v::8>> = bytes
    recid = v - 27

    {:ok,
     {:secp256k1,
      %CurvySignature{
        crv: :secp256k1,
        r: :binary.decode_unsigned(r),
        s: :binary.decode_unsigned(s),
        recid: recid
      }}}
  end

  defp recover_address(payload, %CurvySignature{recid: recid} = signature)
       when is_binary(payload) and is_integer(recid) do
    addr = Recover.recover_eth_from_digest(payload, signature)
    {:ok, to_hex(addr)}
  rescue
    ArgumentError -> {:error, "proof signature recovery failed"}
  end

  defp strip_magic(bytes) do
    if byte_size(bytes) > 32 and :binary.part(bytes, byte_size(bytes) - 32, 32) == @magic_suffix do
      :binary.part(bytes, 0, byte_size(bytes) - 32)
    else
      bytes
    end
  end

  defp decode_hex_bytes(hex) do
    stripped = Hex.strip_0x(hex)

    case Base.decode16(stripped, case: :mixed) do
      {:ok, bytes} when byte_size(bytes) > 0 -> {:ok, bytes}
      _ -> {:error, "invalid proof signature"}
    end
  end
end
