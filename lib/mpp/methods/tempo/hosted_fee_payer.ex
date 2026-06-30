defmodule MPP.Methods.Tempo.HostedFeePayer do
  @moduledoc false

  alias Onchain.Tempo.Transaction

  @tempo_tx_type 0x76
  @fee_token_index 10
  @fee_payer_sig_index 11
  @gas_limit_index 3
  @max_fee_index 2
  @max_priority_fee_index 1
  @nonce_key_index 6
  @nonce_index 7
  @valid_before_index 8
  @valid_after_index 9
  @access_list_index 5

  @default_fill_error "hosted fee payer failed to sponsor transaction"

  @doc """
  Co-signs a client transaction via a hosted `eth_fillTransaction` endpoint.

  Returns `{:ok, tx}` with updated `raw` hex, or `{:error, reason}`.
  """
  @spec fill(Transaction.t(), String.t(), keyword()) :: {:ok, Transaction.t()} | {:error, String.t()}
  def fill(%Transaction{} = tx, url, opts \\ []) when is_binary(url) do
    with {:ok, request} <- build_fill_request(tx),
         {:ok, response} <- post_fill(url, request, opts),
         {:ok, fee_token_hex} <- require_fee_token(response),
         {:ok, sig_tuple} <- parse_fee_payer_signature(Map.get(response, "feePayerSignature")),
         {:ok, fee_token} <- decode_address(fee_token_hex) do
      apply_fill(tx, fee_token, sig_tuple)
    end
  end

  @doc "Build the `eth_fillTransaction` request map for a client-signed sponsorship envelope."
  @spec build_fill_request(Transaction.t()) :: {:ok, map()} | {:error, String.t()}
  def build_fill_request(%Transaction{fields: fields, calls: calls} = tx) do
    with {:ok, from} <- Transaction.sender(tx) do
      request =
        %{
          "type" => "0x76",
          "feePayer" => true,
          "from" => hex_data(from),
          "nonce" => field_quantity(fields, @nonce_index),
          "calls" => Enum.map(calls, &call_to_request/1)
        }
        |> maybe_put_quantity("gas", field_int(fields, @gas_limit_index))
        |> maybe_put_quantity("maxFeePerGas", field_int(fields, @max_fee_index))
        |> maybe_put_quantity("maxPriorityFeePerGas", field_int(fields, @max_priority_fee_index))
        |> maybe_put_quantity("nonceKey", field_int(fields, @nonce_key_index))
        |> maybe_put_quantity("validBefore", field_int(fields, @valid_before_index))
        |> maybe_put_quantity("validAfter", field_int(fields, @valid_after_index))
        |> maybe_put_access_list(fields)
        |> maybe_put_key_authorization(fields)

      {:ok, request}
    end
  end

  defp maybe_put_access_list(request, fields) do
    case Enum.at(fields, @access_list_index) do
      list when is_list(list) and list != [] -> Map.put(request, "accessList", list)
      _ -> request
    end
  end

  defp maybe_put_key_authorization(request, fields) do
    case fields do
      [_, _, _, _, _, _, _, _, _, _, _, _, _, auth, _sender] when is_binary(auth) and auth != <<>> ->
        Map.put(request, "keyAuthorization", hex_data(auth))

      _ ->
        request
    end
  end

  defp call_to_request(%{to: to, value: value, input: input}) do
    %{
      "value" => hex_quantity(value)
    }
    |> maybe_put_hex("to", to)
    |> maybe_put_hex("data", input)
  end

  defp maybe_put_hex(map, _key, <<>>), do: map
  defp maybe_put_hex(map, key, bin) when is_binary(bin), do: Map.put(map, key, hex_data(bin))

  defp maybe_put_quantity(map, _key, 0), do: map
  defp maybe_put_quantity(map, key, value) when is_integer(value), do: Map.put(map, key, hex_quantity(value))

  defp post_fill(url, request, opts) do
    body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "eth_fillTransaction", "params" => [request]}
    req_opts = Keyword.merge([json: body], Keyword.get(opts, :req_options, []))

    case Req.post(url, req_opts) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        parse_fill_response(response_body)

      {:ok, %{status: status}} ->
        {:error, "hosted fee payer request failed with status #{status}"}

      {:error, reason} ->
        {:error, "hosted fee payer request failed: #{inspect(reason)}"}
    end
  end

  defp parse_fill_response(%{"result" => %{"tx" => tx}}) when is_map(tx), do: {:ok, tx}

  defp parse_fill_response(%{"error" => %{"message" => message}}) when is_binary(message), do: {:error, message}

  defp parse_fill_response(body), do: {:error, get_in(body, ["error", "message"]) || @default_fill_error}

  defp require_fee_token(%{"feeToken" => fee_token}) when is_binary(fee_token) and fee_token != "" do
    {:ok, fee_token}
  end

  defp require_fee_token(_), do: {:error, "hosted fee payer did not return a feeToken"}

  defp parse_fee_payer_signature(%{"r" => r_hex, "s" => s_hex} = sig) when is_binary(r_hex) and is_binary(s_hex) do
    with {:ok, y} <- parse_y_parity(sig),
         {:ok, r} <- decode_quantity(r_hex),
         {:ok, s} <- decode_quantity(s_hex) do
      {:ok, [if(y == 1, do: <<1>>, else: <<>>), encode_uint(r), encode_uint(s)]}
    else
      _ -> {:error, "hosted fee payer returned an invalid feePayerSignature"}
    end
  end

  defp parse_fee_payer_signature(_), do: {:error, "hosted fee payer returned an invalid feePayerSignature"}

  defp apply_fill(%Transaction{fields: fields} = tx, fee_token, fp_sig_tuple) do
    sender_sig_raw = List.last(fields)
    base_fields = Enum.take(fields, length(fields) - 1)

    signed_fields =
      base_fields
      |> List.replace_at(@fee_token_index, fee_token)
      |> List.replace_at(@fee_payer_sig_index, fp_sig_tuple)
      |> Kernel.++([sender_sig_raw])

    signed_raw = <<@tempo_tx_type>> <> ExRLP.encode(signed_fields)
    new_hex = "0x" <> Base.encode16(signed_raw, case: :lower)

    {:ok, %{tx | raw: new_hex, fields: signed_fields}}
  end

  defp decode_address(hex) do
    case Base.decode16(strip_0x(hex), case: :mixed) do
      {:ok, <<addr::binary-size(20)>>} -> {:ok, addr}
      _ -> {:error, "hosted fee payer did not return a feeToken"}
    end
  end

  defp field_int(fields, idx) do
    case Enum.at(fields, idx) do
      bin when is_binary(bin) -> :binary.decode_unsigned(bin)
      _ -> 0
    end
  end

  defp field_quantity(fields, idx), do: hex_quantity(field_int(fields, idx))

  defp hex_data(bin) when is_binary(bin), do: "0x" <> Base.encode16(bin, case: :lower)

  defp hex_quantity(0), do: "0x0"
  defp hex_quantity(n) when is_integer(n) and n > 0, do: "0x" <> String.downcase(Integer.to_string(n, 16))

  defp encode_uint(n) when is_integer(n) and n >= 0, do: :binary.encode_unsigned(n)

  defp parse_y_parity(%{"yParity" => y}) when is_integer(y), do: {:ok, y}

  defp parse_y_parity(%{"yParity" => y}) when is_binary(y), do: decode_quantity(y)

  defp parse_y_parity(%{"v" => v}) when is_binary(v) do
    with {:ok, n} <- decode_quantity(v) do
      {:ok, if(n >= 27, do: n - 27, else: n)}
    end
  end

  defp parse_y_parity(_), do: {:error, :invalid}

  defp decode_quantity("0x" <> hex) do
    hex = if rem(byte_size(hex), 2) == 1, do: "0" <> hex, else: hex

    case Base.decode16(hex, case: :mixed) do
      {:ok, bin} -> {:ok, :binary.decode_unsigned(bin)}
      :error -> {:error, :invalid}
    end
  end

  defp decode_quantity("0x"), do: {:ok, 0}

  defp strip_0x("0x" <> rest), do: rest
  defp strip_0x(rest), do: rest
end
