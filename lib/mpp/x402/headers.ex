defmodule MPP.X402.Headers do
  @moduledoc """
  x402 v2 HTTP header codecs.

  Wire encoding is standard Base64 JSON (`PAYMENT-REQUIRED`,
  `PAYMENT-SIGNATURE`, `PAYMENT-RESPONSE`). This is distinct from native
  Payment-auth base64url/JCS headers — a PAYMENT-* value is rejected by
  `MPP.Headers` as `:invalid_scheme`.
  """

  use Descripex, namespace: "/x402"

  @payment_required "PAYMENT-REQUIRED"
  @payment_signature "PAYMENT-SIGNATURE"
  @payment_response "PAYMENT-RESPONSE"
  @max_header_len 16 * 1024
  @evm_network_prefix "eip155:"
  @atomic_amount ~r/\A\d+\z/

  api(:payment_required_header, "Return the x402 payment-required HTTP field name.",
    returns: %{type: :string, description: "`PAYMENT-REQUIRED`"}
  )

  @spec payment_required_header() :: String.t()
  def payment_required_header, do: @payment_required

  api(:payment_signature_header, "Return the x402 payment-signature HTTP field name.",
    returns: %{type: :string, description: "`PAYMENT-SIGNATURE`"}
  )

  @spec payment_signature_header() :: String.t()
  def payment_signature_header, do: @payment_signature

  api(:payment_response_header, "Return the x402 payment-response HTTP field name.",
    returns: %{type: :string, description: "`PAYMENT-RESPONSE`"}
  )

  @spec payment_response_header() :: String.t()
  def payment_response_header, do: @payment_response

  api(:encode_payment_required, "Encode a PaymentRequired object for `PAYMENT-REQUIRED`.",
    params: [value: [kind: :value, description: "PaymentRequired map"]],
    returns: %{type: :tagged_tuple, description: "`{:ok, header}` or `{:error, reason}`"}
  )

  @spec encode_payment_required(map()) :: {:ok, String.t()} | {:error, atom()}
  def encode_payment_required(value) when is_map(value) do
    with {:ok, payment_required} <- parse_payment_required(value) do
      encode_json(payment_required)
    end
  end

  api(:decode_payment_required, "Decode a `PAYMENT-REQUIRED` header into a PaymentRequired object.",
    params: [header: [kind: :value, description: "Base64 JSON header value"]],
    returns: %{type: :tagged_tuple, description: "`{:ok, map}` or `{:error, reason}`"}
  )

  @spec decode_payment_required(String.t()) :: {:ok, map()} | {:error, atom()}
  def decode_payment_required(header) when is_binary(header) do
    with {:ok, decoded} <- decode_json(header) do
      parse_payment_required(decoded)
    end
  end

  @doc """
  Decode the `PAYMENT-REQUIRED` envelope without requiring every accept to be
  a supported exact EVM offer. Matches mppx `decodePaymentRequiredEnvelope`.
  """
  @spec decode_payment_required_envelope(String.t()) :: {:ok, map()} | {:error, atom()}
  def decode_payment_required_envelope(header) when is_binary(header) do
    with {:ok, decoded} <- decode_json(header),
         true <- is_map(decoded),
         2 <- decoded["x402Version"],
         accepts when is_list(accepts) <- decoded["accepts"],
         {:ok, resource} <- parse_resource(decoded["resource"]) do
      envelope = %{"x402Version" => 2, "accepts" => accepts, "resource" => resource}

      {:ok,
       envelope
       |> maybe_put("error", decoded["error"])
       |> maybe_put_extensions(decoded["extensions"])}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_header}
    end
  end

  api(:encode_payment_signature, "Encode a PaymentPayload object for `PAYMENT-SIGNATURE`.",
    params: [value: [kind: :value, description: "PaymentPayload map"]],
    returns: %{type: :tagged_tuple, description: "`{:ok, header}` or `{:error, reason}`"}
  )

  @spec encode_payment_signature(map()) :: {:ok, String.t()} | {:error, atom()}
  def encode_payment_signature(value) when is_map(value) do
    with {:ok, payload} <- parse_payment_payload(value) do
      encode_json(payload)
    end
  end

  api(:decode_payment_signature, "Decode a `PAYMENT-SIGNATURE` header into a PaymentPayload object.",
    params: [header: [kind: :value, description: "Base64 JSON header value"]],
    returns: %{type: :tagged_tuple, description: "`{:ok, map}` or `{:error, reason}`"}
  )

  @spec decode_payment_signature(String.t()) :: {:ok, map()} | {:error, atom()}
  def decode_payment_signature(header) when is_binary(header) do
    with {:ok, decoded} <- decode_json(header) do
      parse_payment_payload(decoded)
    end
  end

  api(:encode_payment_response, "Encode a SettlementResponse object for `PAYMENT-RESPONSE`.",
    params: [value: [kind: :value, description: "SettlementResponse map"]],
    returns: %{type: :tagged_tuple, description: "`{:ok, header}` or `{:error, reason}`"}
  )

  @spec encode_payment_response(map()) :: {:ok, String.t()} | {:error, atom()}
  def encode_payment_response(value) when is_map(value) do
    with {:ok, response} <- parse_settle_response(value) do
      encode_json(response)
    end
  end

  api(:decode_payment_response, "Decode a `PAYMENT-RESPONSE` header into a SettlementResponse object.",
    params: [header: [kind: :value, description: "Base64 JSON header value"]],
    returns: %{type: :tagged_tuple, description: "`{:ok, map}` or `{:error, reason}`"}
  )

  @spec decode_payment_response(String.t()) :: {:ok, map()} | {:error, atom()}
  def decode_payment_response(header) when is_binary(header) do
    with {:ok, decoded} <- decode_json(header) do
      parse_settle_response(decoded)
    end
  end

  @doc "Parse exact EVM payment requirements. Permit2 extras are left for `reject_permit2/1`."
  @spec parse_requirements(map()) :: {:ok, map()} | {:error, atom()}
  def parse_requirements(value) when is_map(value) do
    with {:ok, scheme} <- require_string(value, "scheme"),
         true <- scheme == "exact",
         {:ok, network} <- require_string(value, "network"),
         true <- evm_network?(network),
         {:ok, amount} <- require_atomic(value, "amount"),
         {:ok, asset} <- require_string(value, "asset"),
         {:ok, pay_to} <- require_string(value, "payTo"),
         {:ok, timeout} <- require_positive_number(value, "maxTimeoutSeconds") do
      requirements = %{
        "scheme" => scheme,
        "network" => network,
        "amount" => amount,
        "asset" => asset,
        "payTo" => pay_to,
        "maxTimeoutSeconds" => timeout
      }

      {:ok, maybe_put(requirements, "extra", extra(value["extra"]))}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_requirements}
    end
  end

  def parse_requirements(_other), do: {:error, :invalid_requirements}

  @doc "Reject an accept whose `extra.assetTransferMethod` is Permit2."
  @spec reject_permit2(map()) :: :ok | {:error, atom()}
  def reject_permit2(%{"extra" => extra}) when is_map(extra) do
    case extra["assetTransferMethod"] do
      method when method in [nil, "eip3009"] -> :ok
      _other -> {:error, :unsupported_transfer_method}
    end
  end

  def reject_permit2(_requirements), do: :ok

  @doc "Parse a facilitator verify JSON body."
  @spec parse_verify_response(map()) :: {:ok, map()} | {:error, atom()}
  def parse_verify_response(value) when is_map(value) do
    case value["isValid"] do
      is_valid when is_boolean(is_valid) ->
        {:ok,
         %{"isValid" => is_valid}
         |> maybe_put("invalidReason", value["invalidReason"])
         |> maybe_put("invalidMessage", value["invalidMessage"])
         |> maybe_put("payer", value["payer"])
         |> maybe_put("extra", extra(value["extra"]))
         |> maybe_put_extensions(value["extensions"])}

      _other ->
        {:error, :invalid_verify_response}
    end
  end

  def parse_verify_response(_other), do: {:error, :invalid_verify_response}

  @doc "Parse a facilitator settle / PAYMENT-RESPONSE JSON body."
  @spec parse_settle_response(map()) :: {:ok, map()} | {:error, atom()}
  def parse_settle_response(value) when is_map(value) do
    with true <- is_boolean(value["success"]),
         {:ok, network} <- require_string(value, "network"),
         {:ok, transaction} <- require_string_allow_empty(value, "transaction") do
      {:ok,
       %{
         "success" => value["success"],
         "network" => network,
         "transaction" => transaction
       }
       |> maybe_put("payer", value["payer"])
       |> maybe_put("errorReason", value["errorReason"])
       |> maybe_put("errorMessage", value["errorMessage"])
       |> maybe_put("amount", value["amount"])
       |> maybe_put("extra", extra(value["extra"]))
       |> maybe_put_extensions(value["extensions"])}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_settle_response}
    end
  end

  def parse_settle_response(_other), do: {:error, :invalid_settle_response}

  defp parse_payment_required(value) when is_map(value) do
    with 2 <- value["x402Version"],
         {:ok, resource} <- parse_resource(value["resource"]),
         accepts when is_list(accepts) and accepts != [] <- value["accepts"],
         {:ok, parsed_accepts} <- parse_all_requirements(accepts) do
      {:ok,
       %{"x402Version" => 2, "resource" => resource, "accepts" => parsed_accepts}
       |> maybe_put("error", value["error"])
       |> maybe_put_extensions(value["extensions"])}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_payment_required}
    end
  end

  defp parse_payment_required(_other), do: {:error, :invalid_payment_required}

  defp parse_payment_payload(value) when is_map(value) do
    with 2 <- value["x402Version"],
         {:ok, accepted} <- parse_requirements(value["accepted"]),
         :ok <- reject_permit2(accepted),
         {:ok, payload} <- parse_exact_payload(value["payload"]) do
      {:ok,
       %{"x402Version" => 2, "accepted" => accepted, "payload" => payload}
       |> maybe_put("resource", resource_or_nil(value["resource"]))
       |> maybe_put_extensions(value["extensions"])}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_payment_payload}
    end
  end

  defp parse_payment_payload(_other), do: {:error, :invalid_payment_payload}

  defp parse_all_requirements(accepts) do
    parsed = Enum.map(accepts, &parse_requirements/1)

    if Enum.all?(parsed, &match?({:ok, _}, &1)) do
      {:ok, Enum.map(parsed, fn {:ok, req} -> req end)}
    else
      {:error, :invalid_requirements}
    end
  end

  defp parse_resource(%{"url" => url} = resource) when is_binary(url) and url != "" do
    parsed = %{"url" => url}

    {:ok,
     parsed
     |> maybe_put("description", resource["description"])
     |> maybe_put("mimeType", resource["mimeType"])
     |> maybe_put("serviceName", resource["serviceName"])
     |> maybe_put("iconUrl", resource["iconUrl"])
     |> maybe_put("tags", tags(resource["tags"]))}
  end

  defp parse_resource(_other), do: {:error, :invalid_resource}

  defp resource_or_nil(nil), do: nil

  defp resource_or_nil(resource) do
    case parse_resource(resource) do
      {:ok, parsed} -> parsed
      {:error, _reason} -> nil
    end
  end

  defp parse_exact_payload(%{"authorization" => authorization, "signature" => signature} = payload)
       when is_map(authorization) and is_binary(signature) do
    with {:ok, from} <- require_string(authorization, "from"),
         {:ok, to} <- require_string(authorization, "to"),
         {:ok, value} <- require_atomic(authorization, "value"),
         {:ok, valid_after} <- require_atomic(authorization, "validAfter"),
         {:ok, valid_before} <- require_atomic(authorization, "validBefore"),
         {:ok, nonce} <- require_string(authorization, "nonce") do
      {:ok,
       maybe_put_extensions(
         %{
           "signature" => signature,
           "authorization" => %{
             "from" => from,
             "to" => to,
             "value" => value,
             "validAfter" => valid_after,
             "validBefore" => valid_before,
             "nonce" => nonce
           }
         },
         payload["extensions"]
       )}
    end
  end

  defp parse_exact_payload(%{"permit2Authorization" => _}), do: {:error, :unsupported_transfer_method}
  defp parse_exact_payload(_other), do: {:error, :invalid_payment_payload}

  defp encode_json(value) do
    {:ok, value |> Jason.encode!() |> Base.encode64()}
  rescue
    Jason.EncodeError -> {:error, :invalid_json}
  end

  defp decode_json(header) do
    if byte_size(header) > @max_header_len do
      {:error, :header_too_large}
    else
      with {:ok, json} <- decode_base64(header),
           {:ok, decoded} <- Jason.decode(json) do
        {:ok, decoded}
      else
        :error -> {:error, :invalid_base64}
        {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
      end
    end
  end

  defp decode_base64(value) do
    case Base.decode64(value) do
      {:ok, json} -> {:ok, json}
      :error -> Base.decode64(value, padding: false)
    end
  end

  defp evm_network?(@evm_network_prefix <> rest) do
    case Integer.parse(rest) do
      {_id, ""} -> true
      _other -> false
    end
  end

  defp evm_network?(_other), do: false

  defp require_string(map, key) do
    case map[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :invalid_header}
    end
  end

  defp require_string_allow_empty(map, key) do
    case map[key] do
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, :invalid_header}
    end
  end

  defp require_atomic(map, key) do
    case map[key] do
      value when is_binary(value) ->
        if Regex.match?(@atomic_amount, value), do: {:ok, value}, else: {:error, :invalid_header}

      _other ->
        {:error, :invalid_header}
    end
  end

  defp require_positive_number(map, key) do
    case map[key] do
      value when is_integer(value) and value > 0 -> {:ok, value}
      value when is_float(value) and value > 0 -> {:ok, trunc(value)}
      _other -> {:error, :invalid_header}
    end
  end

  defp extra(extra) when is_map(extra), do: extra
  defp extra(_other), do: nil

  defp tags(tags) when is_list(tags) do
    if valid_tags?(tags), do: tags
  end

  defp tags(_other), do: nil

  defp valid_tags?([_, _, _, _, _, _ | _]), do: false
  defp valid_tags?(tags), do: Enum.all?(tags, &is_binary/1)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_extensions(map, extensions) when is_map(extensions), do: Map.put(map, "extensions", extensions)
  defp maybe_put_extensions(map, _extensions), do: map
end
