defmodule MPP.Client.Providers.Tempo do
  @moduledoc """
  Built-in Tempo charge provider.

  The provider parses a Tempo charge challenge, verifies that the configured
  RPC is serving the advertised chain, signs a TIP-20 `transferWithMemo`, and
  returns a transaction credential for the server to broadcast.

  Configuration is explicit:

    * `:private_key` — required 32-byte private key, raw or hex encoded
    * `:rpc_url` — required Tempo JSON-RPC URL
    * `:expected_chain_id` — optional additional chain pin
    * `:client_id` — optional attribution client identifier
    * `:fee_token` — optional fee token; defaults to the charge currency
    * `:req_options` — optional Req options for the chain-ID check

  Transaction tuning options accepted by `onchain_tempo` (`:gas_limit`,
  `:nonce`, `:nonce_key`, `:valid_before`, and `:valid_after`) may also be
  supplied. Charge transactions use Tempo's expiring nonce lane by default.
  """

  use MPP.Client.PaymentProvider

  alias Cartouche.Recover
  alias Cartouche.Signer.Curvy
  alias MPP.Challenge
  alias MPP.Client.PaymentProvider
  alias MPP.Client.Providers.Shared
  alias MPP.Credential
  alias MPP.DID
  alias MPP.Intents.Charge
  alias MPP.Intents.Subscription
  alias MPP.Methods.Tempo.KeyAuthorization
  alias MPP.Methods.Tempo.Proof
  alias Onchain.Address
  alias Onchain.RPC
  alias Onchain.Signer
  alias Onchain.Tempo.TIP20
  alias Onchain.Tempo.Transaction.Builder

  @attribution_version 1
  @tag_bytes 4
  @server_fingerprint_bytes 10
  @client_fingerprint_bytes 10
  @challenge_nonce_bytes 7
  @memo_bytes 32
  @bits_per_byte 8
  @signature_component_bits 256
  @recovery_id_offset 27
  @expiring_nonce_key :binary.decode_unsigned(:binary.copy(<<0xFF>>, @memo_bytes))
  @expiring_validity_seconds 25
  @transaction_option_keys ~w(gas_limit nonce nonce_key valid_before valid_after)a

  @doc "Returns true for Tempo charge and subscription challenges."
  @impl PaymentProvider
  @spec supports?(String.t(), String.t(), map()) :: boolean()
  def supports?("tempo", "charge", _config), do: true
  def supports?("tempo", "subscription", _config), do: true
  def supports?(_method, _intent, _config), do: false

  @doc "Pays a Tempo charge or authorizes a Tempo subscription challenge."
  @impl PaymentProvider
  @spec pay(Challenge.t(), map()) :: {:ok, Credential.t()} | {:error, term()}
  def pay(%Challenge{intent: "subscription"} = challenge, config) when is_map(config) do
    with {:ok, subscription} <- Shared.parse_subscription(challenge, "tempo"),
         {:ok, wallet_rpc_url} <- Shared.required_config(config, :wallet_rpc_url),
         {:ok, details} <- subscription_method_details(subscription),
         {:ok, chain_id} <- advertised_chain_id(details["chainId"]),
         true <- is_integer(chain_id),
         {:ok, access_key, key_type} <- subscription_access_key(details),
         {:ok, params} <-
           KeyAuthorization.wallet_params(subscription,
             access_key: access_key,
             key_type: key_type
           ),
         {:ok, authorization} <- authorize_access_key(wallet_rpc_url, params, config[:req_options]),
         :ok <-
           KeyAuthorization.verify(authorization, subscription,
             chain_id: chain_id,
             access_key: access_key,
             key_type: key_type,
             challenge_expires: challenge.expires
           ) do
      {:ok,
       %Credential{
         challenge: challenge,
         payload: %{"type" => "keyAuthorization", "signature" => KeyAuthorization.serialize(authorization)},
         source: DID.evm_did(authorization.source, chain_id)
       }}
    else
      false -> {:error, :invalid_chain_id}
      {:error, _reason} = error -> error
    end
  end

  def pay(%Challenge{} = challenge, config) when is_map(config) do
    with {:ok, charge} <- Shared.parse_charge(challenge, "tempo"),
         {:ok, provider} <- parse_config(config),
         {:ok, details} <- method_details(charge),
         {:ok, chain_id} <- resolve_chain_id(details, provider.expected_chain_id),
         :ok <- pin_rpc_chain(chain_id, provider),
         {:ok, address} <- Signer.address_from_key(provider.private_key),
         {:ok, amount} <- parse_amount(charge.amount) do
      create_credential(challenge, charge, details, amount, chain_id, address, provider)
    end
  end

  def pay(%Challenge{}, _config), do: {:error, {:invalid_config, :expected_map}}

  defp parse_config(config) do
    with {:ok, private_key} <- private_key(config[:private_key]),
         {:ok, rpc_url} <- Shared.required_config(config, :rpc_url),
         {:ok, expected_chain_id} <- optional_chain_id(config[:expected_chain_id]),
         {:ok, client_id} <- optional_string(config[:client_id], :client_id),
         {:ok, req_options} <- req_options(config[:req_options]) do
      {:ok,
       %{
         private_key: private_key,
         rpc_url: rpc_url,
         expected_chain_id: expected_chain_id,
         client_id: client_id,
         fee_token: config[:fee_token],
         req_options: req_options,
         transaction_options: Map.take(config, @transaction_option_keys)
       }}
    end
  end

  defp create_credential(challenge, _charge, _details, 0, chain_id, address, provider) do
    with {:ok, signature} <- proof_signature(challenge, chain_id, address, provider.private_key) do
      {:ok,
       %Credential{
         challenge: challenge,
         payload: %{"type" => "proof", "signature" => signature},
         source: DID.evm_did(address, chain_id)
       }}
    end
  end

  defp create_credential(challenge, charge, details, amount, chain_id, address, provider) do
    with {:ok, memo} <- payment_memo(challenge, details, provider.client_id),
         {:ok, token} <- Address.validate(charge.currency),
         {:ok, recipient} <- Address.validate(charge.recipient),
         calldata = TIP20.transfer_with_memo_calldata(recipient, amount, memo),
         {:ok, signature} <- build_transaction([token, <<>>, calldata], challenge, charge, details, chain_id, provider),
         {:ok, payload} <-
           transaction_payload(signature, challenge, details, chain_id, address, provider.private_key) do
      {:ok,
       %Credential{
         challenge: challenge,
         payload: payload,
         source: DID.evm_did(address, chain_id)
       }}
    end
  end

  defp build_transaction(call, challenge, charge, details, chain_id, provider) do
    opts =
      provider.transaction_options
      |> Map.put_new(:nonce, 0)
      |> Map.put_new(:nonce_key, @expiring_nonce_key)
      |> Map.put_new(:valid_before, valid_before(challenge))
      |> Map.merge(%{
        private_key: provider.private_key,
        calls: [call],
        chain_id: chain_id,
        rpc_url: provider.rpc_url
      })
      |> Map.to_list()

    if details["feePayer"] == true do
      Builder.build_fee_payer_multicall(opts)
    else
      fee_token = provider.fee_token || charge.currency
      Builder.build_signed_multicall(Keyword.put(opts, :fee_token, fee_token))
    end
  end

  defp transaction_payload(signature, challenge, %{"presenterBinding" => true}, chain_id, address, private_key) do
    with {:ok, presenter_signature} <- proof_signature(challenge, chain_id, address, private_key) do
      {:ok,
       %{
         "type" => "transaction",
         "signature" => signature,
         "presenterSignature" => presenter_signature
       }}
    end
  end

  defp transaction_payload(signature, _challenge, _details, _chain_id, _address, _private_key) do
    {:ok, %{"type" => "transaction", "signature" => signature}}
  end

  defp payment_memo(_challenge, %{"memo" => memo}, _client_id), do: decode_memo(memo)

  defp payment_memo(challenge, _details, client_id) do
    client =
      if is_binary(client_id) and client_id != "",
        do: binary_part(ExSha3.keccak_256(client_id), 0, @client_fingerprint_bytes),
        else: <<0::size(@client_fingerprint_bytes * @bits_per_byte)>>

    {:ok,
     binary_part(ExSha3.keccak_256("mpp"), 0, @tag_bytes) <>
       <<@attribution_version>> <>
       fingerprint(challenge.realm) <>
       client <>
       binary_part(ExSha3.keccak_256(challenge.id), 0, @challenge_nonce_bytes)}
  end

  defp fingerprint(value), do: binary_part(ExSha3.keccak_256(value), 0, @server_fingerprint_bytes)

  defp decode_memo("0x" <> hex), do: decode_memo(hex)

  defp decode_memo(hex) when is_binary(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, <<memo::binary-size(@memo_bytes)>>} -> {:ok, memo}
      _ -> {:error, :invalid_memo}
    end
  end

  defp decode_memo(_memo), do: {:error, :invalid_memo}

  defp proof_signature(challenge, chain_id, address, private_key) do
    digest =
      Proof.hash(%{
        account: address,
        chain_id: chain_id,
        challenge_id: challenge.id,
        realm: challenge.realm
      })

    with {:ok, address_bytes} <- Address.validate(address),
         {:ok, signature} <- Curvy.sign_payload(digest, private_key),
         signature = Recover.normalize_low_s(signature),
         {:ok, recovery_id} <- Recover.find_recid_from_digest(digest, signature, address_bytes) do
      raw =
        <<signature.r::unsigned-big-size(@signature_component_bits),
          signature.s::unsigned-big-size(@signature_component_bits), recovery_id + @recovery_id_offset::8>>

      {:ok, "0x" <> Base.encode16(raw, case: :lower)}
    end
  end

  defp resolve_chain_id(details, expected) do
    with {:ok, advertised} <- advertised_chain_id(details["chainId"]) do
      select_chain_id(advertised, expected)
    end
  end

  defp advertised_chain_id(nil), do: {:ok, nil}
  defp advertised_chain_id(chain_id) when is_integer(chain_id) and chain_id >= 0, do: {:ok, chain_id}
  defp advertised_chain_id(_chain_id), do: {:error, :invalid_chain_id}

  defp select_chain_id(nil, nil), do: {:error, :invalid_chain_id}
  defp select_chain_id(nil, expected), do: {:ok, expected}
  defp select_chain_id(advertised, nil), do: {:ok, advertised}
  defp select_chain_id(chain_id, chain_id), do: {:ok, chain_id}
  defp select_chain_id(advertised, expected), do: {:error, {:chain_id_mismatch, expected, advertised}}

  defp pin_rpc_chain(chain_id, provider) do
    opts = [rpc_url: provider.rpc_url, req_options: provider.req_options]

    case RPC.chain_id(opts) do
      {:ok, ^chain_id} -> :ok
      {:ok, actual} -> {:error, {:rpc_chain_id_mismatch, chain_id, actual}}
      {:error, _reason} = error -> error
    end
  end

  defp method_details(%Charge{method_details: nil}), do: {:ok, %{}}
  defp method_details(%Charge{method_details: details}) when is_map(details), do: {:ok, details}

  defp subscription_method_details(%Subscription{method_details: details}) when is_map(details), do: {:ok, details}
  defp subscription_method_details(%Subscription{}), do: {:error, :missing_method_details}

  defp subscription_access_key(%{"accessKey" => %{"accessKeyAddress" => address, "keyType" => key_type}}) do
    with {:ok, normalized} <- Address.normalize(address),
         {:ok, type} <- subscription_key_type(key_type) do
      {:ok, normalized, type}
    else
      _ -> {:error, :invalid_access_key}
    end
  end

  defp subscription_access_key(_details), do: {:error, :missing_access_key}

  defp subscription_key_type("secp256k1"), do: {:ok, :secp256k1}
  defp subscription_key_type("p256"), do: {:ok, :p256}
  defp subscription_key_type("webAuthn"), do: {:ok, :web_authn}
  defp subscription_key_type(_type), do: {:error, :invalid_access_key_type}

  defp authorize_access_key(url, params, req_options) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "wallet_authorizeAccessKey",
      "params" => [params]
    }

    opts = Keyword.merge([json: body], req_options || [])

    case Req.post(url, opts) do
      {:ok, %{status: status, body: %{"result" => %{"keyAuthorization" => authorization}}}}
      when status in 200..299 ->
        KeyAuthorization.from_rpc(authorization)

      {:ok, %{body: %{"error" => %{"message" => message}}}} when is_binary(message) ->
        {:error, {:wallet_authorization_failed, message}}

      {:ok, %{status: status}} ->
        {:error, {:wallet_authorization_failed, status}}

      {:error, reason} ->
        {:error, {:wallet_authorization_failed, reason}}
    end
  end

  defp parse_amount(amount) do
    case Integer.parse(amount) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _other -> {:error, :invalid_amount}
    end
  end

  defp private_key(nil), do: {:error, {:missing_config, :private_key}}
  defp private_key(<<key::binary-size(32)>>), do: {:ok, key}
  defp private_key("0x" <> hex), do: private_key(hex)

  defp private_key(hex) when is_binary(hex) and byte_size(hex) == 64 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, <<key::binary-size(32)>>} -> {:ok, key}
      :error -> {:error, {:invalid_config, :private_key}}
    end
  end

  defp private_key(_other), do: {:error, {:invalid_config, :private_key}}

  defp optional_chain_id(nil), do: {:ok, nil}
  defp optional_chain_id(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp optional_chain_id(_other), do: {:error, {:invalid_config, :expected_chain_id}}

  defp optional_string(nil, _key), do: {:ok, nil}
  defp optional_string(value, _key) when is_binary(value), do: {:ok, value}
  defp optional_string(_value, key), do: {:error, {:invalid_config, key}}

  defp req_options(nil), do: {:ok, []}
  defp req_options(value) when is_list(value), do: {:ok, value}
  defp req_options(_value), do: {:error, {:invalid_config, :req_options}}

  defp valid_before(%Challenge{expires: expires}) do
    window_end = System.os_time(:second) + @expiring_validity_seconds

    case expires do
      nil -> window_end
      timestamp -> min(window_end, timestamp |> DateTime.from_iso8601() |> elem(1) |> DateTime.to_unix())
    end
  end
end
