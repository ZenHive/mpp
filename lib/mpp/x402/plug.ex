defmodule MPP.X402.Plug do
  @moduledoc """
  Server-side x402 v2 exact settlement through a configurable facilitator.

  Verifies `PAYMENT-SIGNATURE`, binds route and body, claims the authorization
  nonce, settles, and attaches `PAYMENT-RESPONSE`. Coexists with native
  Payment-auth on the same `MPP.Plug` endpoint.

  The facilitator always receives the server-configured requirements that the
  echoed `accepted` matched (including `extra`), never the client's copy —
  `refs/mppx/src/x402/server/EvmCharge.ts` `facilitatorPayment`. A
  route-bound credential (`extensions.mppx.info.nonce`) must echo the
  advertised `:extensions` (schema and info, minus the client nonce salt)
  before its nonce is recomputed — mppx `containsExtensions`.
  """

  alias MPP.BodyDigest
  alias MPP.Errors
  alias MPP.X402
  alias MPP.X402.Facilitator
  alias MPP.X402.Headers
  alias MPP.X402.Nonce
  alias MPP.X402.Replay
  alias Onchain.Address
  alias Plug.Conn

  @type t :: %__MODULE__{
          facilitator: Facilitator.t(),
          accepts: [map()],
          resource: map() | nil,
          extensions: map() | nil,
          route_binding: :resource | :required,
          digest: String.t() | nil
        }

  @enforce_keys [:facilitator, :accepts]
  defstruct [
    :facilitator,
    :accepts,
    resource: nil,
    extensions: nil,
    route_binding: :resource,
    digest: nil
  ]

  @doc "Build x402 plug options from `MPP.Plug` `:x402` config."
  @spec configure(nil | false | keyword() | map()) :: t() | nil
  def configure(nil), do: nil
  def configure(false), do: nil

  def configure(opts) when is_list(opts), do: configure(Map.new(opts))

  def configure(%{} = opts) do
    %__MODULE__{
      facilitator: Facilitator.resolve(Map.get(opts, :facilitator)),
      accepts: normalize_accepts(opts),
      resource: Map.get(opts, :resource),
      extensions: Map.get(opts, :extensions),
      route_binding: configure_binding(opts),
      digest: Map.get(opts, :digest)
    }
  end

  @doc "Settle a `PAYMENT-SIGNATURE` when present; otherwise continue the native handshake."
  @spec maybe_settle(Conn.t(), t() | nil, term()) :: :continue | {:ok, Conn.t()} | {:error, Errors.t()}
  def maybe_settle(_conn, nil, _store), do: :continue

  def maybe_settle(%Conn{} = conn, %__MODULE__{} = x402, store) do
    case Conn.get_req_header(conn, "payment-signature") do
      [] -> :continue
      [header | _rest] -> settle_header(conn, x402, store, header)
    end
  end

  @doc "Attach `PAYMENT-REQUIRED` to a 402 response when x402 is configured."
  @spec put_challenge(Conn.t(), t() | nil) :: Conn.t()
  def put_challenge(%Conn{} = conn, nil), do: conn

  def put_challenge(%Conn{} = conn, %__MODULE__{} = x402) do
    envelope = payment_required_envelope(conn, x402)

    case Headers.encode_payment_required(envelope) do
      {:ok, header} -> Conn.put_resp_header(conn, "payment-required", header)
      {:error, _reason} -> conn
    end
  end

  defp settle_header(conn, x402, store, header) do
    with {:ok, payload} <- Headers.decode_payment_signature(header),
         {:ok, accepted} <- bind_route(payload, conn, x402),
         :ok <- reject_native_nonce(payload, conn, x402),
         :ok <- Replay.claim(store, authorization_nonce(payload)),
         payload = Map.put(payload, "accepted", accepted),
         {:ok, verified} <- Facilitator.verify(x402.facilitator, payload, accepted),
         :ok <- require_valid(verified),
         {:ok, settled} <- Facilitator.settle(x402.facilitator, payload, accepted),
         :ok <- require_success(settled) do
      {:ok, put_settlement(conn, settled)}
    else
      {:error, %Errors{} = error} -> {:error, error}
      {:error, :already_used} -> {:error, Errors.new(:verification_failed, "x402 payment has already been settled")}
      {:error, reason} -> {:error, Errors.new(:verification_failed, x402_error(reason))}
    end
  end

  defp bind_route(payload, conn, x402) do
    with {:ok, accepted} <- match_accepted(payload["accepted"], x402.accepts),
         :ok <- match_resource(payload, conn, x402),
         :ok <- match_digest(conn, x402),
         :ok <- match_extensions(payload, x402),
         :ok <- match_extension_nonce(payload, accepted, conn, x402) do
      {:ok, accepted}
    end
  end

  defp match_accepted(accepted, accepts) do
    case Enum.find(accepts, &same_requirements?(&1, accepted)) do
      nil -> {:error, :requirements_mismatch}
      matched -> {:ok, matched}
    end
  end

  defp same_requirements?(left, right) do
    left["scheme"] == right["scheme"] and left["network"] == right["network"] and left["amount"] == right["amount"] and
      left["maxTimeoutSeconds"] == right["maxTimeoutSeconds"] and left["extra"] == right["extra"] and
      address_eq?(left["asset"], right["asset"]) and address_eq?(left["payTo"], right["payTo"])
  end

  defp address_eq?(left, right) do
    case {Address.normalize(left), Address.normalize(right)} do
      {{:ok, a}, {:ok, b}} -> a == b
      _other -> left == right
    end
  end

  defp match_resource(payload, conn, x402) do
    expected = resource_url(conn, x402)
    actual = get_in(payload, ["resource", "url"])
    compare_resource(actual, expected, route_bound?(payload), x402)
  end

  defp compare_resource(actual, expected, true, _x402) do
    if actual == expected, do: :ok, else: {:error, :resource_mismatch}
  end

  defp compare_resource(_actual, _expected, false, %__MODULE__{route_binding: :required}) do
    {:error, :route_binding_required}
  end

  defp compare_resource(actual, expected, false, %__MODULE__{digest: digest}) when is_binary(digest) do
    if actual == expected, do: :ok, else: {:error, :resource_mismatch}
  end

  defp compare_resource(nil, _expected, false, _x402), do: :ok

  defp compare_resource(actual, expected, false, _x402) do
    if actual == expected, do: :ok, else: {:error, :resource_mismatch}
  end

  defp match_digest(%Conn{} = conn, %__MODULE__{digest: digest}) when is_binary(digest) do
    body = raw_body(conn)

    if body == "" or BodyDigest.verify(digest, body) do
      :ok
    else
      {:error, :body_digest_mismatch}
    end
  end

  defp match_digest(_conn, _x402), do: :ok

  defp match_extensions(payload, %__MODULE__{extensions: expected}) when is_map(expected) do
    if route_bound?(payload) and not contains_extensions?(payload["extensions"], expected) do
      {:error, :extension_mismatch}
    else
      :ok
    end
  end

  defp match_extensions(_payload, _x402), do: :ok

  defp contains_extensions?(actual, expected) when is_map(actual) do
    Enum.all?(expected, fn {key, expected_extension} -> same_extension?(actual[key], expected_extension) end)
  end

  defp contains_extensions?(_actual, _expected), do: false

  defp same_extension?(%{} = actual, %{} = expected) do
    actual["schema"] == expected["schema"] and
      strip_client_nonce(actual["info"] || %{}) == (expected["info"] || %{})
  end

  defp same_extension?(actual, expected), do: actual == expected

  defp strip_client_nonce(%{"nonce" => nonce} = info) when is_binary(nonce), do: Map.delete(info, "nonce")
  defp strip_client_nonce(info), do: info

  defp match_extension_nonce(payload, accepted, conn, x402) do
    extensions = payload["extensions"]

    case Nonce.contract(extensions) do
      :extension_bound -> assert_extension_nonce(payload, accepted, conn, x402, extensions)
      :random -> :ok
    end
  end

  defp assert_extension_nonce(payload, accepted, conn, x402, extensions) do
    expected = Nonce.extension_bound(accepted, %{"url" => resource_url(conn, x402)}, extensions)

    if String.downcase(authorization_nonce(payload)) == String.downcase(expected) do
      :ok
    else
      {:error, :nonce_mismatch}
    end
  end

  defp reject_native_nonce(payload, conn, x402) do
    nonce = authorization_nonce(payload)
    realm = resource_host(conn, x402)
    id = X402.synthetic_id_prefix() <> "0"

    if Nonce.challenge_hash?(nonce, id, realm) do
      {:error, :native_nonce}
    else
      :ok
    end
  end

  defp require_valid(%{"isValid" => true}), do: :ok

  defp require_valid(%{"isValid" => false} = verified) do
    {:error, verified["invalidMessage"] || verified["invalidReason"] || :verify_failed}
  end

  defp require_success(%{"success" => true}), do: :ok

  defp require_success(%{"success" => false} = settled) do
    {:error, settled["errorMessage"] || settled["errorReason"] || :settle_failed}
  end

  defp put_settlement(conn, settled) do
    conn
    |> Conn.assign(:x402_settlement, settled)
    |> Conn.register_before_send(&maybe_put_payment_response(&1, settled))
  end

  defp maybe_put_payment_response(%Conn{status: status} = conn, settled) when status in 200..299 do
    case Headers.encode_payment_response(settled) do
      {:ok, header} -> Conn.put_resp_header(conn, "payment-response", header)
      {:error, _reason} -> conn
    end
  end

  defp maybe_put_payment_response(conn, _settled), do: conn

  defp payment_required_envelope(conn, x402) do
    envelope = %{
      "x402Version" => 2,
      "error" => "PAYMENT-SIGNATURE header is required",
      "resource" => %{"url" => resource_url(conn, x402)},
      "accepts" => x402.accepts
    }

    case x402.extensions do
      extensions when is_map(extensions) -> Map.put(envelope, "extensions", extensions)
      _other -> envelope
    end
  end

  defp resource_url(_conn, %__MODULE__{resource: %{"url" => url}}) when is_binary(url) and url != "", do: url
  defp resource_url(%Conn{} = conn, _x402), do: Conn.request_url(conn)

  defp resource_host(conn, x402) do
    case conn |> resource_url(x402) |> URI.parse() do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _other -> "x402"
    end
  end

  defp route_bound?(%{"extensions" => %{"mppx" => %{"info" => info}}}) when is_map(info) do
    is_binary(info["nonce"])
  end

  defp route_bound?(_payload), do: false

  defp authorization_nonce(payload) do
    get_in(payload, ["payload", "authorization", "nonce"]) || ""
  end

  defp raw_body(%Conn{private: %{raw_body: body}}) when is_binary(body), do: body
  defp raw_body(%Conn{adapter: {_, %{body: body}}}) when is_binary(body), do: body
  defp raw_body(_conn), do: ""

  defp normalize_accepts(opts) do
    case Map.get(opts, :accepts) do
      accepts when is_list(accepts) and accepts != [] -> Enum.map(accepts, &parse_accept!/1)
      _other -> raise ArgumentError, "MPP.Plug :x402 requires a non-empty :accepts list"
    end
  end

  defp parse_accept!(accept) do
    case Headers.parse_requirements(accept) do
      {:ok, parsed} -> parsed
      {:error, reason} -> raise ArgumentError, "MPP.Plug :x402 :accepts is invalid (#{reason})"
    end
  end

  defp configure_binding(opts) do
    case Map.get(opts, :route_binding, :resource) do
      binding when binding in [:resource, :required] -> binding
      _other -> raise ArgumentError, "MPP.Plug :x402 :route_binding must be :resource or :required"
    end
  end

  defp x402_error(reason) when is_atom(reason), do: "x402 #{reason}"
  defp x402_error(reason) when is_binary(reason), do: reason
  defp x402_error(reason), do: "x402 settlement failed: #{inspect(reason)}"
end
