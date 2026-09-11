defmodule MPP.Methods.XRPL.Wallet do
  @moduledoc false

  alias Curvy.Key
  alias MPP.Methods.XRPL.Codec
  alias MPP.Methods.XRPL.RPC

  # secp256k1 curve order n (FIPS 186-4 / SEC 2).
  @n 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141

  @type t :: %{
          algorithm: :ed25519 | :secp256k1,
          private_key: binary(),
          public_key: String.t(),
          address: String.t()
        }

  @doc false
  @spec from_seed(term()) :: {:ok, t()} | :error
  def from_seed(seed) do
    with {:ok, {algorithm, entropy}} <- Codec.decode_seed(seed) do
      derive(algorithm, entropy)
    end
  end

  @doc false
  @spec sign_claim(t(), map()) :: {:ok, String.t(), String.t()} | :error
  def sign_claim(wallet, tx) when is_map(wallet) and is_map(tx) do
    tx = Map.put(tx, "SigningPubKey", wallet.public_key)

    with {:ok, data} <- Codec.claim_signing_data(tx),
         {:ok, signature} <- sign(wallet, data),
         {:ok, blob} <- Codec.encode_claim(Map.put(tx, "TxnSignature", signature)) do
      {:ok, blob, RPC.blob_hash(blob)}
    else
      _ -> :error
    end
  end

  defp derive(:ed25519, entropy) do
    private_key = RPC.sha512_half(entropy)
    {public, _} = :crypto.generate_key(:eddsa, :ed25519, private_key)
    finish(:ed25519, private_key, <<0xED, public::binary>>)
  end

  defp derive(:secp256k1, entropy) do
    with private_gen when is_integer(private_gen) <- derive_scalar(entropy),
         {:ok, public_gen} <- compressed_pubkey(private_gen),
         scalar when is_integer(scalar) <- derive_scalar(public_gen, 0) do
      finish_secp(rem(scalar + private_gen, @n))
    else
      _ -> :error
    end
  end

  defp finish_secp(private) when is_integer(private) and private > 0 do
    private_key = <<private::unsigned-256>>

    with {:ok, public} <- compressed_pubkey(private) do
      finish(:secp256k1, private_key, public)
    end
  end

  defp finish_secp(_private), do: :error

  defp finish(algorithm, private_key, public) do
    with {:ok, address} <- Codec.encode_account(account_id(public)) do
      {:ok,
       %{
         algorithm: algorithm,
         private_key: private_key,
         public_key: Base.encode16(public),
         address: address
       }}
    end
  end

  defp sign(%{algorithm: :ed25519, private_key: private_key}, data) do
    {:ok, Base.encode16(:crypto.sign(:eddsa, :none, data, [private_key, :ed25519]))}
  rescue
    _error in [ArgumentError, ErlangError] -> :error
  end

  defp sign(%{algorithm: :secp256k1, private_key: private_key}, data) do
    digest = RPC.sha512_half(data)
    {:ok, Base.encode16(Curvy.sign(digest, private_key, hash: false, normalize: true))}
  rescue
    _error in [ArgumentError, ErlangError] -> :error
  end

  defp compressed_pubkey(scalar) when is_integer(scalar) and scalar > 0 do
    {:ok, Key.to_pubkey(Key.from_privkey(<<scalar::unsigned-256>>))}
  rescue
    _error in [ArgumentError, ErlangError] -> :error
  end

  defp compressed_pubkey(_scalar), do: :error

  defp derive_scalar(bytes, discrim \\ nil), do: derive_scalar(bytes, discrim, 0)

  defp derive_scalar(_bytes, _discrim, seq) when seq > 0xFFFFFFFF, do: :error

  defp derive_scalar(bytes, discrim, seq) do
    <<n::unsigned-256>> = RPC.sha512_half(bytes <> discrim_bytes(discrim) <> <<seq::unsigned-32>>)

    if n > 0 and n < @n, do: n, else: derive_scalar(bytes, discrim, seq + 1)
  end

  defp discrim_bytes(nil), do: <<>>
  defp discrim_bytes(discrim) when is_integer(discrim) and discrim >= 0, do: <<discrim::unsigned-32>>

  defp account_id(public), do: :crypto.hash(:ripemd160, :crypto.hash(:sha256, public))
end
