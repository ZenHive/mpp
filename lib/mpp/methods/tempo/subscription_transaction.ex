defmodule MPP.Methods.Tempo.SubscriptionTransaction do
  @moduledoc false

  import Bitwise, only: [<<<: 2]

  alias Cartouche.Hash
  alias Cartouche.Recover
  alias Cartouche.Signer.Curvy
  alias MPP.Intents.Subscription
  alias MPP.Methods.Tempo.FeePayerPolicy
  alias MPP.Methods.Tempo.KeyAuthorization
  alias Onchain.Address
  alias Onchain.RPC
  alias Onchain.Tempo.TIP20
  alias Onchain.Tempo.Transaction

  @tempo_transaction_type 0x76
  @fee_payer_domain 0x78
  @keychain_v2_type 0x04
  @default_max_priority_fee_per_gas 1_000_000_000
  @default_max_fee_per_gas 25_000_000_000
  @default_gas_limit 5_000_000
  @default_validity_seconds 24
  @signature_component_bits 256
  @recovery_id_offset 27
  @expiring_nonce_key (1 <<< 256) - 1
  @fee_token_index 10
  @fee_payer_signature_index 11

  @doc "Build an access-key-signed Tempo subscription payment transaction."
  @spec build(Subscription.t(), KeyAuthorization.t() | nil, String.t(), map(), String.t()) ::
          {:ok, Transaction.t(), String.t()} | {:error, String.t()}
  def build(%Subscription{} = subscription, authorization, source, config, settlement_reference) do
    sponsored? = fee_payer_enabled?(config)
    chain_id = config["chain_id"]
    rpc_url = config["rpc_url"]
    now = System.os_time(:second)

    with {:ok, access_key} <- decode_key(config["subscription_access_key_private_key"]),
         {:ok, access_key_address} <- Curvy.get_address(access_key),
         {:ok, source_address} <- Address.validate(source),
         {:ok, token} <- Address.validate(subscription.currency),
         {:ok, recipient} <- Address.validate(subscription.recipient),
         {:ok, amount} <- parse_amount(subscription.amount),
         {:ok, nonce} <- resolve_nonce(source, rpc_url, config),
         memo = attribution_memo(settlement_reference),
         calldata = TIP20.transfer_with_memo_calldata(recipient, amount, memo),
         call = [token, <<>>, calldata],
         base_fields = base_fields(chain_id, nonce, call, token, sponsored?, now, config, authorization),
         {:ok, sender_signature} <- sign_keychain(base_fields, access_key, access_key_address, source_address),
         fields = base_fields ++ [sender_signature],
         {:ok, tx} <- deserialize(fields),
         :ok <- validate_sponsor_policy(tx, config, sponsored?, now),
         {:ok, tx} <- maybe_cosign(tx, source_address, config) do
      {:ok, tx, hex(memo)}
    else
      {:error, %ArgumentError{} = error} -> {:error, Exception.message(error)}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp base_fields(chain_id, nonce, call, token, sponsored?, now, config, authorization) do
    {fee_token, fee_payer_signature} = fee_fields(sponsored?, config, token)
    {nonce_key, valid_before} = nonce_fields(sponsored?, now, config)

    append_authorization(
      [
        encode_uint(chain_id),
        encode_uint(configured(config, "subscription_max_priority_fee_per_gas", @default_max_priority_fee_per_gas)),
        encode_uint(configured(config, "subscription_max_fee_per_gas", @default_max_fee_per_gas)),
        encode_uint(configured(config, "subscription_gas_limit", @default_gas_limit)),
        [call],
        [],
        encode_uint(nonce_key),
        encode_uint(nonce),
        encode_uint(valid_before),
        <<>>,
        fee_token,
        fee_payer_signature,
        []
      ],
      authorization
    )
  end

  defp fee_fields(true, _config, _token), do: {<<>>, <<0>>}
  defp fee_fields(false, config, token), do: {fee_token(config, token), <<>>}

  defp nonce_fields(true, now, config), do: {@expiring_nonce_key, now + validity_seconds(config)}
  defp nonce_fields(false, _now, config), do: {config["subscription_nonce_key"] || 0, 0}

  defp configured(config, key, default), do: config[key] || default

  defp append_authorization(fields, %KeyAuthorization{} = authorization),
    do: fields ++ [KeyAuthorization.transaction_field(authorization)]

  defp append_authorization(fields, nil), do: fields

  defp sign_keychain(base_fields, access_key, access_key_address, source_address) do
    transaction_digest = Hash.keccak(<<@tempo_transaction_type>> <> ExRLP.encode(base_fields))
    access_digest = Hash.keccak(<<@keychain_v2_type, transaction_digest::binary, source_address::binary>>)

    with {:ok, signature} <- Curvy.sign_payload(access_digest, access_key),
         signature = Recover.normalize_low_s(signature),
         {:ok, recovery_id} <- Recover.find_recid_from_digest(access_digest, signature, access_key_address) do
      inner =
        <<signature.r::unsigned-big-size(@signature_component_bits),
          signature.s::unsigned-big-size(@signature_component_bits), recovery_id + @recovery_id_offset::8>>

      {:ok, <<@keychain_v2_type, source_address::binary, inner::binary>>}
    end
  end

  defp maybe_cosign(tx, source_address, %{"fee_payer" => true} = config) do
    with {:ok, private_key} <- decode_key(config["fee_payer_private_key"]),
         {:ok, fee_token} <- Address.validate(config["fee_token"]),
         true <-
           FeePayerPolicy.fee_token_allowed?(
             config["chain_id"],
             config["fee_token"],
             config["fee_payer_allowed_fee_tokens"]
           ),
         {:ok, signed} <- cosign(tx, source_address, private_key, fee_token) do
      {:ok, signed}
    else
      false -> {:error, "fee token is not allowed for sponsorship"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_cosign(tx, _source_address, config) do
    if is_binary(config["fee_payer_url"]),
      do: {:error, "hosted fee payer does not support subscription keychain transactions"},
      else: {:ok, tx}
  end

  defp cosign(%Transaction{fields: fields} = tx, source_address, private_key, fee_token) do
    sender_signature = List.last(fields)
    base_fields = Enum.take(fields, length(fields) - 1)

    fee_payer_preimage =
      base_fields
      |> List.replace_at(@fee_token_index, fee_token)
      |> List.replace_at(@fee_payer_signature_index, source_address)

    payload = <<@fee_payer_domain>> <> ExRLP.encode(fee_payer_preimage)

    with {:ok, signature} <- Curvy.sign(payload, private_key),
         signature = Recover.normalize_low_s(signature),
         {:ok, fee_payer_address} <- Curvy.get_address(private_key),
         {:ok, recovery_id} <- Recover.find_recid(payload, signature, fee_payer_address) do
      tuple = [encode_uint(recovery_id), encode_uint(signature.r), encode_uint(signature.s)]

      signed_fields =
        base_fields
        |> List.replace_at(@fee_token_index, fee_token)
        |> List.replace_at(@fee_payer_signature_index, tuple)
        |> Kernel.++([sender_signature])

      {:ok, %{tx | fields: signed_fields, raw: encode_transaction(signed_fields)}}
    end
  end

  defp validate_sponsor_policy(_tx, _config, false, _now), do: :ok

  defp validate_sponsor_policy(tx, config, true, now) do
    defaults = %{"max_gas" => @default_gas_limit, "max_total_fee" => 200_000_000_000_000_000}
    overrides = Map.merge(defaults, config["fee_payer_policy"] || %{})
    policy = FeePayerPolicy.resolve(config["chain_id"], overrides)
    FeePayerPolicy.validate(tx, policy, now)
  end

  defp deserialize(fields) do
    raw = encode_transaction(fields)
    Transaction.deserialize(raw)
  end

  defp resolve_nonce(source, rpc_url, config) do
    case config["subscription_nonce"] do
      nonce when is_integer(nonce) and nonce >= 0 -> {:ok, nonce}
      nil -> RPC.get_transaction_count(source, rpc_url: rpc_url, req_options: config["req_options"] || [])
      _ -> {:error, "invalid subscription nonce"}
    end
  end

  defp fee_token(config, default) do
    case Address.validate(config["fee_token"]) do
      {:ok, token} -> token
      {:error, _reason} -> default
    end
  end

  defp decode_key(nil), do: {:error, "missing subscription access key private key"}
  defp decode_key(<<key::binary-size(32)>>), do: {:ok, key}
  defp decode_key("0x" <> key), do: decode_key(key)

  defp decode_key(key) when is_binary(key) and byte_size(key) == 64 do
    case Base.decode16(key, case: :mixed) do
      {:ok, <<decoded::binary-size(32)>>} -> {:ok, decoded}
      :error -> {:error, "invalid private key"}
    end
  end

  defp decode_key(_key), do: {:error, "invalid private key"}

  defp parse_amount(amount) do
    case Integer.parse(amount) do
      {value, ""} when value > 0 -> {:ok, value}
      _ -> {:error, "invalid subscription amount"}
    end
  end

  defp validity_seconds(config) do
    case get_in(config, ["fee_payer_policy", "max_validity_window_seconds"]) do
      value when is_integer(value) and value > 0 -> min(value, @default_validity_seconds)
      _ -> @default_validity_seconds
    end
  end

  defp fee_payer_enabled?(%{"fee_payer" => true}), do: true
  defp fee_payer_enabled?(%{"fee_payer_url" => url}) when is_binary(url), do: true
  defp fee_payer_enabled?(_config), do: false

  defp attribution_memo(reference), do: ExSha3.keccak_256("mpp-subscription|" <> reference)

  defp encode_transaction(fields), do: hex(<<@tempo_transaction_type>> <> ExRLP.encode(fields))
  defp encode_uint(0), do: <<>>
  defp encode_uint(value) when is_integer(value) and value > 0, do: :binary.encode_unsigned(value)
  defp hex(value), do: "0x" <> Base.encode16(value, case: :lower)
end
