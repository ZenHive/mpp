defmodule MPP.Methods.Tempo.EnvelopeFields do
  @moduledoc false

  # 0x76 RLP envelope field indices — matches Onchain.Tempo.Transaction wire layout
  # (deps/onchain_tempo/lib/onchain/tempo/transaction.ex) and cross-checked against
  # mppx TxEnvelopeTempo + mpp-rs Tempo transaction encoding:
  #
  #   chain_id, max_priority_fee_per_gas, max_fee_per_gas, gas_limit,
  #   calls, access_list, nonce_key, nonce, valid_before, valid_after,
  #   fee_token, fee_payer_signature, aa_authorization_list,
  #   key_authorization?, sender_signature

  @type field_index :: non_neg_integer()

  @chain_id 0
  @max_priority_fee_per_gas 1
  @max_fee_per_gas 2
  @gas_limit 3
  @calls 4
  @access_list 5
  @nonce_key 6
  @nonce 7
  @valid_before 8
  @valid_after 9
  @fee_token 10
  @fee_payer_signature 11
  @aa_authorization_list 12
  @key_authorization 13
  @sender_signature 14

  # Signed envelope sizes from Onchain.Tempo.Transaction.Builder (13 base fields +
  # sender_signature, optional key_authorization inserted before sender_signature).
  @signed_field_count 14
  @signed_with_key_auth_field_count 15

  @spec chain_id() :: field_index()
  @doc false
  def chain_id, do: @chain_id

  @spec max_priority_fee_per_gas() :: field_index()
  @doc false
  def max_priority_fee_per_gas, do: @max_priority_fee_per_gas

  @spec max_fee_per_gas() :: field_index()
  @doc false
  def max_fee_per_gas, do: @max_fee_per_gas

  @spec gas_limit() :: field_index()
  @doc false
  def gas_limit, do: @gas_limit

  @spec calls() :: field_index()
  @doc false
  def calls, do: @calls

  @spec access_list() :: field_index()
  @doc false
  def access_list, do: @access_list

  @spec nonce_key() :: field_index()
  @doc false
  def nonce_key, do: @nonce_key

  @spec nonce() :: field_index()
  @doc false
  def nonce, do: @nonce

  @spec valid_before() :: field_index()
  @doc false
  def valid_before, do: @valid_before

  @spec valid_after() :: field_index()
  @doc false
  def valid_after, do: @valid_after

  @spec fee_token() :: field_index()
  @doc false
  def fee_token, do: @fee_token

  @spec fee_payer_signature() :: field_index()
  @doc false
  def fee_payer_signature, do: @fee_payer_signature

  @spec aa_authorization_list() :: field_index()
  @doc false
  def aa_authorization_list, do: @aa_authorization_list

  @spec key_authorization() :: field_index()
  @doc false
  def key_authorization, do: @key_authorization

  @spec sender_signature() :: field_index()
  @doc false
  def sender_signature, do: @sender_signature

  @spec signed_field_count() :: pos_integer()
  @doc false
  def signed_field_count, do: @signed_field_count

  @spec signed_with_key_auth_field_count() :: pos_integer()
  @doc false
  def signed_with_key_auth_field_count, do: @signed_with_key_auth_field_count
end
