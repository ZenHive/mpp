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

  ## Route binding

  Every challenge advertises an `extensions.mppx` route binding derived from
  the route itself (mppx `routeExtensions`,
  `refs/mppx/src/x402/server/EvmCharge.ts:414-433`): `info.method` is the
  request method, `info.digest` the route digest and `info.opaque` the route
  opaque value. The digest and opaque come from the `MPP.Plug` route
  (`:digest` / `:opaque`) or from the nested `:x402` options; a value set in
  both places must agree. Caller-supplied `:extensions` are advertised
  alongside, and their other `mppx.info` keys are kept; the route-derived keys
  take precedence. A route-bound credential must echo this binding before its
  nonce is recomputed over it (`EvmCharge.ts:173-218`), so a credential signed
  for one route scope does not match another.

  A route is *scoped* when the derived `mppx.info` carries `digest`, `opaque`
  or `_mppx_scope` (`routeRequiresBinding`, `EvmCharge.ts:158-162`).
  `info.method` alone does not scope a route. `:route_binding` decides how a
  scoped route treats a credential without `extensions.mppx.info.nonce`
  (`EvmCharge.ts:168-198`):

    * `:required` (default) — rejected with `route_binding_required`. Only
      clients implementing the mppx route binding can pay a scoped route.
    * `:resource` — accepted when it echoes the route's `resource.url` and
      `accepted`. `resource` is not covered by the EIP-3009 signature, so this
      binds weaker than the route-bound nonce.

  Unscoped routes accept plain x402 exact payloads in either mode; an echoed
  `resource.url` must still match. Route-bound credentials are always checked
  in full (resource, extensions, recomputed nonce).

  ## Body digest

  A route with a digest verifies it against the raw request body, which the
  host must cache in `conn.private.raw_body` (for example with a
  `Plug.Parsers` `:body_reader`). An empty body is checked like any other.
  Only a request without a body skips the check; a body that was not cached
  is rejected (`body_digest_unavailable`).
  """

  alias MPP.BodyDigest
  alias MPP.Errors
  alias MPP.Methods.Shared
  alias MPP.X402
  alias MPP.X402.Facilitator
  alias MPP.X402.Headers
  alias MPP.X402.Nonce
  alias MPP.X402.Replay
  alias Onchain.Address
  alias Plug.Conn

  require Logger

  @route_scope_keys ["digest", "opaque", "_mppx_scope"]
  @mppx_binding_schema %{
    "additionalProperties" => false,
    "properties" => %{
      "_mppx_scope" => %{"type" => "string"},
      "digest" => %{"type" => "string"},
      "method" => %{"type" => "string"},
      "nonce" => %{"type" => "string"},
      "opaque" => %{"type" => "string"}
    },
    "required" => ["method"],
    "type" => "object"
  }

  @type t :: %__MODULE__{
          facilitator: Facilitator.t(),
          accepts: [map()],
          resource: map() | nil,
          extensions: map() | nil,
          route_binding: :resource | :required,
          digest: String.t() | nil,
          opaque: String.t() | nil
        }

  @enforce_keys [:facilitator, :accepts]
  defstruct [
    :facilitator,
    :accepts,
    resource: nil,
    extensions: nil,
    route_binding: :required,
    digest: nil,
    opaque: nil
  ]

  @doc """
  Build x402 plug options from `MPP.Plug` `:x402` config.

  `route` carries the enclosing route's `:digest` and `:opaque`; they scope the
  x402 binding together with any nested `:digest` / `:opaque`.
  """
  @spec configure(nil | false | keyword() | map(), keyword()) :: t() | nil
  def configure(opts, route \\ [])
  def configure(nil, _route), do: nil
  def configure(false, _route), do: nil

  def configure(opts, route) when is_list(opts), do: configure(Map.new(opts), route)

  def configure(%{} = opts, route) do
    %__MODULE__{
      facilitator: Facilitator.resolve(Map.get(opts, :facilitator)),
      accepts: normalize_accepts(opts),
      resource: Map.get(opts, :resource),
      extensions: Map.get(opts, :extensions),
      route_binding: configure_binding(opts),
      digest: route_scope!(:digest, Map.get(opts, :digest), Keyword.get(route, :digest)),
      opaque: route_scope!(:opaque, Map.get(opts, :opaque), Keyword.get(route, :opaque))
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
         {:ok, verified} <- facilitator_call(:verify, Facilitator.verify(x402.facilitator, payload, accepted)),
         :ok <- require_valid(verified),
         {:ok, settled} <- facilitator_call(:settle, Facilitator.settle(x402.facilitator, payload, accepted)),
         :ok <- require_success(settled) do
      {:ok, put_settlement(conn, settled)}
    else
      {:error, %Errors{} = error} -> {:error, error}
      {:error, :already_used} -> {:error, Errors.new(:verification_failed, "x402 payment has already been settled")}
      {:error, :store_error} -> {:error, Shared.internal_payment_error()}
      {:error, reason} when is_atom(reason) -> {:error, Errors.new(:verification_failed, "x402 #{reason}")}
      {:error, reason} when is_binary(reason) -> {:error, Errors.new(:verification_failed, reason)}
    end
  end

  # A raw facilitator error (transport, HTTP, or callback term of any shape) is
  # an internal failure; only the facilitator's `isValid`/`success` results are
  # public rejections. Typed errors pass through and are rendered by
  # `MPP.Errors.client_detail/1`.
  defp facilitator_call(_stage, {:ok, _response} = ok), do: ok
  defp facilitator_call(_stage, {:error, %Errors{}} = error), do: error

  defp facilitator_call(stage, {:error, reason}) do
    Logger.error("MPP x402 facilitator #{stage} failed: #{inspect(reason)}")
    {:error, Shared.internal_payment_error()}
  end

  defp bind_route(payload, conn, x402) do
    binding = route_extensions(conn, x402)

    with {:ok, accepted} <- match_accepted(payload["accepted"], x402.accepts),
         :ok <- match_resource(payload, conn, x402, binding),
         :ok <- match_digest(conn, x402),
         :ok <- match_extensions(payload, binding),
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

  defp match_resource(payload, conn, x402, binding) do
    expected = resource_url(conn, x402)
    actual = get_in(payload, ["resource", "url"])
    compare_resource(actual, expected, route_bound?(payload), x402, binding)
  end

  defp compare_resource(actual, expected, true, _x402, _binding) do
    if actual == expected, do: :ok, else: {:error, :resource_mismatch}
  end

  defp compare_resource(actual, expected, false, x402, binding) do
    case {scoped?(binding), x402.route_binding, actual} do
      {true, :required, _actual} -> {:error, :route_binding_required}
      {false, _binding, nil} -> :ok
      _other -> if actual == expected, do: :ok, else: {:error, :resource_mismatch}
    end
  end

  defp scoped?(%{"mppx" => %{"info" => info}}), do: Enum.any?(@route_scope_keys, &Map.has_key?(info, &1))

  # mppx routeExtensions (refs/mppx/src/x402/server/EvmCharge.ts:414-433).
  defp route_extensions(%Conn{method: method}, %__MODULE__{} = x402) do
    caller = if is_map(x402.extensions), do: x402.extensions, else: %{}
    mppx = if is_map(caller["mppx"]), do: caller["mppx"], else: %{}
    info = if is_map(mppx["info"]), do: mppx["info"], else: %{}

    info =
      info
      |> Map.put("method", method)
      |> put_present("digest", x402.digest)
      |> put_present("opaque", x402.opaque)

    Map.put(caller, "mppx", %{"info" => info, "schema" => Map.get(mppx, "schema", @mppx_binding_schema)})
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # Skips only a request without a body (mppx `input.body === null`); a body
  # that was not cached in `conn.private.raw_body` cannot be bound and fails
  # closed (`EvmCharge.ts:456-469`).
  defp match_digest(%Conn{} = conn, %__MODULE__{digest: digest}) when is_binary(digest) do
    case request_body(conn) do
      :none -> :ok
      :unavailable -> {:error, :body_digest_unavailable}
      {:ok, body} -> if BodyDigest.verify(digest, body), do: :ok, else: {:error, :body_digest_mismatch}
    end
  end

  defp match_digest(_conn, _x402), do: :ok

  defp match_extensions(payload, expected) do
    if route_bound?(payload) and not contains_extensions?(payload["extensions"], expected) do
      {:error, :extension_mismatch}
    else
      :ok
    end
  end

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

    Map.put(envelope, "extensions", route_extensions(conn, x402))
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

  defp request_body(%Conn{private: %{raw_body: body}} = conn) when is_binary(body) do
    if body == "" and bodyless?(conn), do: :none, else: {:ok, body}
  end

  defp request_body(conn) do
    cond do
      Conn.get_req_header(conn, "content-length") == ["0"] -> {:ok, ""}
      bodyless?(conn) -> :none
      true -> :unavailable
    end
  end

  # HTTP/1.x framing: a request without Content-Length or Transfer-Encoding has
  # no body. HTTP/2 and later may carry a body without either header.
  defp bodyless?(conn) do
    Conn.get_http_protocol(conn) in [:"HTTP/1.0", :"HTTP/1.1"] and
      Conn.get_req_header(conn, "content-length") == [] and
      Conn.get_req_header(conn, "transfer-encoding") == []
  end

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
    case Map.get(opts, :route_binding, :required) do
      binding when binding in [:resource, :required] -> binding
      _other -> raise ArgumentError, "MPP.Plug :x402 :route_binding must be :resource or :required"
    end
  end

  defp route_scope!(_key, nil, route), do: route
  defp route_scope!(_key, nested, nil), do: nested
  defp route_scope!(_key, same, same), do: same

  defp route_scope!(key, _nested, _route) do
    raise ArgumentError, "MPP.Plug :x402 :#{key} conflicts with the route :#{key}"
  end
end
