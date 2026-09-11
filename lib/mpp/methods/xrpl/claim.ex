defmodule MPP.Methods.XRPL.Claim do
  @moduledoc """
  Payment-channel claim message and signature verification.

  The signed message is HashPrefix `CLM\\0` plus the 32-byte channel ID plus
  the authorized drops as a big-endian uint64, matching
  `serializePayChanAuthorization` / `channel_verify`
  (xrpl.org PaymentChannelClaim and channel_verify). secp256k1 signatures
  are SHA-512Half then canonical low-S ECDSA; Ed25519 keys (`ED` prefix)
  sign the raw message bytes.
  """

  alias Curvy.Signature, as: CurvySignature
  alias MPP.Methods.XRPL.RPC
  alias MPP.Session.Channel

  # secp256k1 curve order n / 2; high-S encodings of an accepted claim are
  # still that claim (draft Signature Malleability).
  @half_n 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0

  @doc "SHA-512Half of the PaymentChannelClaim authorization message."
  @spec digest(String.t(), non_neg_integer()) :: {:ok, binary()} | {:error, term()}
  def digest(channel_id, amount) when is_integer(amount) and amount >= 0 do
    with {:ok, message} <- message(channel_id, amount) do
      {:ok, RPC.sha512_half(message)}
    end
  end

  def digest(_channel_id, _amount), do: {:error, :invalid_amount}

  @doc "Verify a claim signature over channel ID and cumulative drops."
  @spec verify(String.t(), non_neg_integer(), String.t(), String.t()) :: :ok | {:error, term()}
  def verify(channel_id, amount, signature, public_key)
      when is_integer(amount) and amount >= 0 and is_binary(signature) and is_binary(public_key) do
    with {:ok, message} <- message(channel_id, amount),
         {:ok, signature} <- signature_bytes(signature),
         {:ok, public_key} <- public_key_bytes(public_key) do
      verify_key(message, signature, public_key)
    end
  end

  def verify(_channel_id, amount, _signature, _public_key) when is_integer(amount) and amount < 0,
    do: {:error, :invalid_amount}

  def verify(_channel_id, _amount, _signature, _public_key), do: {:error, :invalid_signature}

  defp message(channel_id, amount) do
    with {:ok, normalized} <- Channel.normalize_id(channel_id),
         {:ok, bytes} <- Onchain.Hex.decode(normalized) do
      {:ok, <<"CLM", 0>> <> bytes <> <<amount::unsigned-big-64>>}
    else
      _ -> {:error, :invalid_channel_id}
    end
  end

  defp verify_key(message, signature, <<0xED, key::binary-32>>) do
    if :crypto.verify(:eddsa, :none, message, signature, [key, :ed25519]) do
      :ok
    else
      {:error, :invalid_signature}
    end
  rescue
    _error in [ArgumentError, ErlangError] -> {:error, :invalid_signature}
  end

  defp verify_key(message, signature, public_key) when byte_size(public_key) == 33 do
    digest = RPC.sha512_half(message)

    with %CurvySignature{} = parsed <- CurvySignature.parse(signature),
         true <- parsed.s > 0 and parsed.s <= @half_n,
         true <- Curvy.verify(signature, digest, public_key, hash: false) do
      :ok
    else
      _ -> {:error, :invalid_signature}
    end
  end

  defp verify_key(_message, _signature, _public_key), do: {:error, :invalid_public_key}

  defp signature_bytes(signature) do
    stripped = strip_hex(signature)
    size = byte_size(stripped)

    if size in 128..200 and rem(size, 2) == 0 and RPC.hex?(stripped, size) do
      Base.decode16(stripped, case: :mixed)
    else
      {:error, :invalid_signature}
    end
  end

  defp public_key_bytes(public_key) do
    stripped = strip_hex(public_key)

    size = byte_size(stripped)

    if size in [64, 66] and RPC.hex?(stripped, size) do
      Base.decode16(stripped, case: :mixed)
    else
      {:error, :invalid_public_key}
    end
  end

  defp strip_hex("0x" <> rest), do: rest
  defp strip_hex("0X" <> rest), do: rest
  defp strip_hex(value), do: value
end
