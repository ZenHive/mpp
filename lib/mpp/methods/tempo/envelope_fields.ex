defmodule MPP.Methods.Tempo.EnvelopeFields do
  @moduledoc false

  # Byte-level view of the 0x76 RLP envelope for the one check that compares raw
  # bytes: the sponsor's key-authorization pin. Everything else reads the named
  # fields of `Onchain.Tempo.Transaction`.
  #
  # Field order (mppx TxEnvelopeTempo, mpp-rs Tempo transaction encoding,
  # onchain_tempo 0.13 CHANGELOG migration table):
  #
  #   chain_id, max_priority_fee_per_gas, max_fee_per_gas, gas_limit,
  #   calls, access_list, nonce_key, nonce, valid_before, valid_after,
  #   fee_token, fee_payer_signature, aa_authorization_list,
  #   key_authorization?, sender_signature

  alias Onchain.Tempo.Transaction

  @key_authorization 13
  @signed_with_key_auth_field_count 15

  @doc false
  @spec key_authorization_field(Transaction.t()) :: {:ok, term()} | {:error, String.t()}
  def key_authorization_field(%Transaction{} = tx) do
    with {:ok, "0x76" <> hex} <- Transaction.serialize(tx),
         {:ok, rlp} <- Base.decode16(hex, case: :mixed),
         fields when length(fields) == @signed_with_key_auth_field_count <- ExRLP.decode(rlp) do
      {:ok, Enum.at(fields, @key_authorization)}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _ -> {:error, "transaction does not carry a key authorization field"}
    end
  end
end
