defmodule MPP.Session.Payload do
  @moduledoc """
  Session credential payload schema, discriminated on `action`.

  Wire JSON uses camelCase action names (`"open"` / `"topUp"` / `"voucher"` /
  `"close"`). Elixir atoms are snake_case (`:open` / `:top_up` / `:voucher` /
  `:close`). Field names match the TIP-1034 precompile payloads in mppx
  `Protocol.ts` and mpp-rs `SessionCredentialPayload`.
  """

  alias MPP.Hex
  alias MPP.Session.Channel
  alias Onchain.Address

  @type action :: Channel.action()

  @type descriptor :: %{
          payer: String.t(),
          payee: String.t(),
          operator: String.t(),
          token: String.t(),
          salt: String.t(),
          authorized_signer: String.t(),
          expiring_nonce_hash: String.t()
        }

  @type settlement_route :: %{
          adapter: String.t(),
          recipient: String.t(),
          target_token: String.t(),
          route_salt: String.t()
        }

  @type t :: %__MODULE__{
          action: action(),
          channel_id: String.t(),
          type: String.t() | nil,
          transaction: String.t() | nil,
          descriptor: descriptor() | nil,
          settlement_route: settlement_route() | nil,
          authorized_signer: String.t() | nil,
          cumulative_amount: non_neg_integer() | nil,
          additional_deposit: non_neg_integer() | nil,
          signature: String.t() | nil
        }

  @enforce_keys [:action, :channel_id]
  defstruct [
    :action,
    :channel_id,
    :type,
    :transaction,
    :descriptor,
    :settlement_route,
    :authorized_signer,
    :cumulative_amount,
    :additional_deposit,
    :signature
  ]

  @doc "Parse a session credential payload map into a typed struct."
  @spec parse(term()) :: {:ok, t()} | {:error, term()}
  def parse(payload) when is_map(payload) do
    with {:ok, action} <- Channel.action_from_wire(payload["action"]),
         {:ok, channel_id} <- Channel.normalize_id(payload["channelId"]),
         {:ok, descriptor} <- parse_optional_descriptor(payload["descriptor"]),
         {:ok, settlement_route} <- parse_optional_settlement_route(payload["settlementRoute"]) do
      parse_action(action, payload, channel_id, descriptor, settlement_route)
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  @doc "Serialize a session payload to the camelCase wire map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = payload) do
    %{"action" => Channel.action_to_wire(payload.action), "channelId" => payload.channel_id}
    |> maybe_put("type", payload.type)
    |> maybe_put("transaction", payload.transaction)
    |> maybe_put("descriptor", descriptor_to_map(payload.descriptor))
    |> maybe_put("settlementRoute", settlement_route_to_map(payload.settlement_route))
    |> maybe_put("authorizedSigner", payload.authorized_signer)
    |> maybe_put_amount("cumulativeAmount", payload.cumulative_amount)
    |> maybe_put_amount("additionalDeposit", payload.additional_deposit)
    |> maybe_put("signature", payload.signature)
  end

  defp parse_action(:open, payload, channel_id, descriptor, settlement_route) do
    with :ok <- require_transaction_type(payload["type"]),
         {:ok, transaction} <- require_hex(payload["transaction"], :transaction),
         {:ok, cumulative_amount} <- require_amount(payload["cumulativeAmount"], :cumulative_amount),
         {:ok, signature} <- require_hex(payload["signature"], :signature),
         {:ok, authorized_signer} <- parse_optional_address(payload["authorizedSigner"], :authorized_signer) do
      {:ok,
       %__MODULE__{
         action: :open,
         type: "transaction",
         channel_id: channel_id,
         transaction: transaction,
         descriptor: descriptor,
         settlement_route: settlement_route,
         authorized_signer: authorized_signer,
         cumulative_amount: cumulative_amount,
         signature: signature
       }}
    end
  end

  defp parse_action(:top_up, payload, channel_id, descriptor, settlement_route) do
    with :ok <- require_transaction_type(payload["type"]),
         {:ok, transaction} <- require_hex(payload["transaction"], :transaction),
         {:ok, additional_deposit} <- require_amount(payload["additionalDeposit"], :additional_deposit) do
      {:ok,
       %__MODULE__{
         action: :top_up,
         type: "transaction",
         channel_id: channel_id,
         transaction: transaction,
         descriptor: descriptor,
         settlement_route: settlement_route,
         additional_deposit: additional_deposit
       }}
    end
  end

  defp parse_action(:voucher, payload, channel_id, descriptor, settlement_route) do
    with {:ok, cumulative_amount} <- require_amount(payload["cumulativeAmount"], :cumulative_amount),
         {:ok, signature} <- require_hex(payload["signature"], :signature) do
      {:ok,
       %__MODULE__{
         action: :voucher,
         channel_id: channel_id,
         descriptor: descriptor,
         settlement_route: settlement_route,
         cumulative_amount: cumulative_amount,
         signature: signature
       }}
    end
  end

  defp parse_action(:close, payload, channel_id, descriptor, settlement_route) do
    with {:ok, cumulative_amount} <- require_amount(payload["cumulativeAmount"], :cumulative_amount),
         {:ok, signature} <- require_hex(payload["signature"], :signature) do
      {:ok,
       %__MODULE__{
         action: :close,
         channel_id: channel_id,
         descriptor: descriptor,
         settlement_route: settlement_route,
         cumulative_amount: cumulative_amount,
         signature: signature
       }}
    end
  end

  defp require_transaction_type("transaction"), do: :ok
  defp require_transaction_type(_type), do: {:error, :invalid_transaction_type}

  defp require_hex(value, field) when is_binary(value) do
    stripped = Hex.strip_0x(value)

    if Hex.hex_string?(stripped) do
      {:ok, "0x" <> String.downcase(stripped)}
    else
      {:error, {:invalid_hex, field}}
    end
  end

  defp require_hex(_value, field), do: {:error, {:invalid_hex, field}}

  defp require_amount(value, field) when is_binary(value) do
    if Regex.match?(~r/\A[0-9]+\z/, value) do
      {:ok, String.to_integer(value)}
    else
      {:error, {:invalid_amount, field}}
    end
  end

  defp require_amount(value, _field) when is_integer(value) and value >= 0, do: {:ok, value}
  defp require_amount(_value, field), do: {:error, {:invalid_amount, field}}

  defp parse_optional_descriptor(nil), do: {:ok, nil}

  defp parse_optional_descriptor(map) when is_map(map) do
    with {:ok, payer} <- require_address(map["payer"], :payer),
         {:ok, payee} <- require_address(map["payee"], :payee),
         {:ok, operator} <- require_address(map["operator"], :operator),
         {:ok, token} <- require_address(map["token"], :token),
         {:ok, salt} <- require_hash(map["salt"], :salt),
         {:ok, authorized_signer} <- require_address(map["authorizedSigner"], :authorized_signer),
         {:ok, expiring_nonce_hash} <- require_hash(map["expiringNonceHash"], :expiring_nonce_hash) do
      {:ok,
       %{
         payer: payer,
         payee: payee,
         operator: operator,
         token: token,
         salt: salt,
         authorized_signer: authorized_signer,
         expiring_nonce_hash: expiring_nonce_hash
       }}
    end
  end

  defp parse_optional_descriptor(_value), do: {:error, :invalid_descriptor}

  defp parse_optional_settlement_route(nil), do: {:ok, nil}

  defp parse_optional_settlement_route(map) when is_map(map) do
    with {:ok, adapter} <- require_address(map["adapter"], :adapter),
         {:ok, recipient} <- require_address(map["recipient"], :recipient),
         {:ok, target_token} <- require_address(map["targetToken"], :target_token),
         {:ok, route_salt} <- require_hash(map["routeSalt"], :route_salt) do
      {:ok,
       %{
         adapter: adapter,
         recipient: recipient,
         target_token: target_token,
         route_salt: route_salt
       }}
    end
  end

  defp parse_optional_settlement_route(_value), do: {:error, :invalid_settlement_route}

  defp parse_optional_address(nil, _field), do: {:ok, nil}
  defp parse_optional_address(value, field), do: require_address(value, field)

  defp require_address(value, field) do
    case Address.normalize(value) do
      {:ok, address} -> {:ok, address}
      {:error, _reason} -> {:error, {:invalid_address, field}}
    end
  end

  defp require_hash(value, field) do
    case Channel.normalize_id(value) do
      {:ok, hash} -> {:ok, hash}
      {:error, _reason} -> {:error, {:invalid_hash, field}}
    end
  end

  defp descriptor_to_map(nil), do: nil

  defp descriptor_to_map(descriptor) do
    %{
      "payer" => descriptor.payer,
      "payee" => descriptor.payee,
      "operator" => descriptor.operator,
      "token" => descriptor.token,
      "salt" => descriptor.salt,
      "authorizedSigner" => descriptor.authorized_signer,
      "expiringNonceHash" => descriptor.expiring_nonce_hash
    }
  end

  defp settlement_route_to_map(nil), do: nil

  defp settlement_route_to_map(route) do
    %{
      "adapter" => route.adapter,
      "recipient" => route.recipient,
      "targetToken" => route.target_token,
      "routeSalt" => route.route_salt
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_amount(map, _key, nil), do: map
  defp maybe_put_amount(map, key, value), do: Map.put(map, key, Integer.to_string(value))
end
