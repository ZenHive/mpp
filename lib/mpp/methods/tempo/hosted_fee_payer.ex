defmodule MPP.Methods.Tempo.HostedFeePayer do
  @moduledoc """
  Hosted Tempo fee-payer JSON-RPC fill support.

  This module sends a client-signed sponsorship envelope to a configured
  `eth_fillTransaction` endpoint and locally rebuilds the broadcastable 0x76
  transaction from the returned fee token and fee-payer signature.
  """

  alias MPP.Hex
  alias MPP.Methods.Tempo.EnvelopeFields, as: TxFields
  alias Onchain.Tempo.Transaction

  require Logger

  @default_fill_error "hosted fee payer failed to sponsor transaction"
  @fill_request_failed_detail "hosted fee payer request failed"
  # Dropped from the caller's options and again from the built request, which
  # carries application-wide Req defaults: these would retarget, re-encode or
  # re-send the fill (Req reads the legacy :follow_redirects before :redirect,
  # and :form / :form_multipart / :body before or instead of :json).
  @dropped_request_options [
    :url,
    :method,
    :json,
    :body,
    :form,
    :form_multipart,
    :params,
    :path_params,
    :redirect,
    :follow_redirects,
    :retry,
    :http_errors,
    :into
  ]

  @doc """
  Co-signs a client transaction via a hosted `eth_fillTransaction` endpoint.

  `opts[:req_options]` is merged into the request. The URL, method and JSON body
  are always the fill request, and redirects, retries and raising on HTTP errors
  are always off; a raising option or step returns `{:error, reason}`.

  Returns `{:ok, tx}` re-decoded from the filled envelope, or `{:error, reason}`.
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
  def build_fill_request(%Transaction{calls: calls} = tx) do
    with {:ok, from} <- Transaction.sender(tx) do
      request =
        %{
          "type" => "0x76",
          "feePayer" => true,
          "from" => hex_data(from),
          "nonce" => hex_quantity(tx.nonce),
          "calls" => Enum.map(calls, &call_to_request/1)
        }
        |> maybe_put_quantity("gas", tx.gas_limit)
        |> maybe_put_quantity("maxFeePerGas", tx.max_fee_per_gas)
        |> maybe_put_quantity("maxPriorityFeePerGas", tx.max_priority_fee_per_gas)
        |> maybe_put_quantity("nonceKey", tx.nonce_key)
        |> maybe_put_quantity("validBefore", tx.valid_before)
        |> maybe_put_quantity("validAfter", tx.valid_after)
        |> maybe_put_access_list(tx.access_list)

      maybe_put_key_authorization(request, tx)
    end
  end

  defp maybe_put_access_list(request, []), do: request

  defp maybe_put_access_list(request, access_list) do
    Map.put(
      request,
      "accessList",
      Enum.map(access_list, fn %{address: address, storage_keys: keys} ->
        %{"address" => hex_data(address), "storageKeys" => Enum.map(keys, &hex_data/1)}
      end)
    )
  end

  # The key authorization travels as the hex of its canonical RLP item.
  defp maybe_put_key_authorization(request, %Transaction{key_authorization: nil}), do: {:ok, request}

  defp maybe_put_key_authorization(request, tx) do
    with {:ok, field} <- TxFields.key_authorization_field(tx) do
      {:ok, Map.put(request, "keyAuthorization", field |> ExRLP.encode() |> hex_data())}
    end
  end

  defp call_to_request(%{to: to, value: value, input: input}) do
    %{
      "value" => hex_quantity(value)
    }
    |> maybe_put_hex("to", to)
    |> maybe_put_hex("data", input)
  end

  defp maybe_put_hex(map, _key, value) when value in [nil, <<>>], do: map
  defp maybe_put_hex(map, key, bin) when is_binary(bin), do: Map.put(map, key, hex_data(bin))

  defp maybe_put_quantity(map, _key, value) when value in [nil, 0], do: map
  defp maybe_put_quantity(map, key, value) when is_integer(value), do: Map.put(map, key, hex_quantity(value))

  defp post_fill(url, request, opts) do
    body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "eth_fillTransaction", "params" => [request]}

    case send_fill(url, body, Keyword.get(opts, :req_options, [])) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        parse_fill_response(response_body)

      {:ok, %{status: status}} ->
        {:error, "#{@fill_request_failed_detail} with status #{status}"}

      {:error, reason} ->
        Logger.warning("MPP.Methods.Tempo.HostedFeePayer: eth_fillTransaction failed: #{inspect(reason)}")
        {:error, @fill_request_failed_detail}
    end
  end

  # The target, body and delivery policy are pinned on the built request, after
  # Req has merged its application-wide defaults: a redirect would carry the
  # fee-payer headers to another host, and a retry could re-send a sign request
  # the sponsor already acted on (mpp-rs builds its client with no redirects or
  # retries).
  defp send_fill(url, body, caller_options) do
    # The URL goes in at construction so a default URL is never parsed, and the
    # only credentials kept are the caller's :auth or the sponsor URL's own
    # userinfo: an inherited :auth (or one Req derived from a default URL's
    # userinfo) belongs to another host.
    request =
      caller_options
      |> Keyword.drop(@dropped_request_options)
      |> Keyword.merge(url: url, method: :post)
      |> Req.new()

    pinned_options =
      request.options
      |> Map.drop([:auth | @dropped_request_options])
      |> Map.merge(%{json: body, redirect: false, retry: false, http_errors: :return})
      |> put_fee_payer_auth(Keyword.get(caller_options, :auth) || url_auth(url))

    Req.request(%{request | body: nil, into: nil, options: pinned_options})
  rescue
    # A caller option, step or adapter that raises or exits must still end in
    # an error tuple, so the caller releases what it reserved for this fill.
    # Only the exception module is logged: the message can carry the headers.
    # reach:disable-next-line bare_rescue
    exception ->
      Logger.warning("MPP.Methods.Tempo.HostedFeePayer: eth_fillTransaction raised #{inspect(exception.__struct__)}")
      {:error, :raised}
  catch
    :exit, _reason ->
      Logger.warning("MPP.Methods.Tempo.HostedFeePayer: eth_fillTransaction exited")
      {:error, :exited}
  end

  defp put_fee_payer_auth(options, nil), do: options
  defp put_fee_payer_auth(options, auth), do: Map.put(options, :auth, auth)

  defp url_auth(url) do
    case URI.parse(url) do
      %URI{userinfo: userinfo} when is_binary(userinfo) -> {:basic, userinfo}
      _ -> nil
    end
  end

  defp parse_fill_response(%{"error" => %{"message" => message}}) when is_binary(message), do: {:error, message}
  defp parse_fill_response(%{"result" => %{"tx" => tx}}) when is_map(tx), do: {:ok, tx}
  defp parse_fill_response(_body), do: {:error, @default_fill_error}

  defp require_fee_token(%{"feeToken" => fee_token}) when is_binary(fee_token) and fee_token != "" do
    {:ok, fee_token}
  end

  defp require_fee_token(_), do: {:error, "hosted fee payer did not return a feeToken"}

  defp parse_fee_payer_signature(%{"r" => r_hex, "s" => s_hex} = sig) when is_binary(r_hex) and is_binary(s_hex) do
    with {:ok, y} <- parse_y_parity(sig),
         {:ok, r} <- decode_quantity(r_hex),
         {:ok, s} <- decode_quantity(s_hex) do
      {:ok, %{r: r, s: s, y_parity: y}}
    else
      _ -> {:error, "hosted fee payer returned an invalid feePayerSignature"}
    end
  end

  defp parse_fee_payer_signature(_), do: {:error, "hosted fee payer returned an invalid feePayerSignature"}

  defp apply_fill(%Transaction{} = tx, fee_token, fee_payer_signature) do
    filled = %{tx | fee_token: fee_token, fee_payer_signature: fee_payer_signature}

    with {:ok, raw} <- Transaction.serialize(filled) do
      Transaction.deserialize(raw)
    end
  end

  defp decode_address(hex) do
    case Base.decode16(Hex.strip_0x(hex), case: :mixed) do
      {:ok, <<addr::binary-size(20)>>} -> {:ok, addr}
      _ -> {:error, "hosted fee payer did not return a feeToken"}
    end
  end

  defp hex_data(bin) when is_binary(bin), do: "0x" <> Base.encode16(bin, case: :lower)

  defp hex_quantity(0), do: "0x0"
  defp hex_quantity(n) when is_integer(n) and n > 0, do: "0x" <> String.downcase(Integer.to_string(n, 16))

  defp parse_y_parity(%{"yParity" => y}) when is_integer(y), do: validate_recovery_id(y)

  defp parse_y_parity(%{"yParity" => y}) when is_binary(y) do
    with {:ok, decoded} <- decode_quantity(y), do: validate_recovery_id(decoded)
  end

  defp parse_y_parity(%{"v" => v}) when is_binary(v) do
    with {:ok, n} <- decode_quantity(v) do
      n
      |> normalize_v()
      |> validate_recovery_id()
    end
  end

  defp parse_y_parity(_), do: {:error, :invalid}

  defp normalize_v(n) when n in [27, 28], do: n - 27
  defp normalize_v(n), do: n

  defp validate_recovery_id(n) when n in [0, 1], do: {:ok, n}
  defp validate_recovery_id(_), do: {:error, :invalid}

  # At most 32 bytes: a signature component or recovery id, never more.
  defp decode_quantity("0x" <> hex) when byte_size(hex) <= 64 do
    hex = if rem(byte_size(hex), 2) == 1, do: "0" <> hex, else: hex

    case hex do
      "" ->
        {:ok, 0}

      _ ->
        case Base.decode16(hex, case: :mixed) do
          {:ok, bin} -> {:ok, :binary.decode_unsigned(bin)}
          :error -> {:error, :invalid}
        end
    end
  end

  defp decode_quantity(_value), do: {:error, :invalid}
end
