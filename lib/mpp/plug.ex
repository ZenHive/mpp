defmodule MPP.Plug do
  @moduledoc """
  Plug middleware implementing the MPP 402 payment handshake.

  Mount this plug in any Phoenix or Plug router to gate endpoints behind
  payment. Each route gets its own pricing via plug opts — no global config.

  ## Usage

      # In a Phoenix router
      pipeline :paid do
        plug MPP.Plug,
          secret_key: "your-hmac-secret",
          realm: "api.example.com",
          method: MyApp.Payments.Stripe,
          amount: "1000",
          currency: "usd"
      end

      scope "/premium", MyAppWeb do
        pipe_through [:api, :paid]
        get "/data", DataController, :show
      end

  ## Flow

  1. Request without `Authorization: Payment` → 402 with `WWW-Authenticate` challenge
  2. Client pays off-band, retries with `Authorization: Payment <credential>`
  3. Valid credential → request passes through with `Payment-Receipt` header + receipt in assigns
  4. Invalid credential → 402 with fresh challenge + RFC 9457 error body

  ## Options

    * `:secret_key` — (required) HMAC-SHA256 key for challenge binding
    * `:realm` — (required) server protection space
    * `:method` — (required) module implementing `MPP.Method`
    * `:amount` — (required) price in base units (string)
    * `:currency` — (required) currency code (string, normalized to lowercase)
    * `:recipient` — (optional) payment recipient identifier
    * `:description` — (optional) human-readable description
    * `:method_config` — (optional) server-only config map passed to `verify/2`
      via `charge.method_details` (never serialized to the client). Use this for
      secrets like API keys that the method needs but clients must not see.
    * `:expires_in` — (optional) challenge TTL in seconds (integer)
    * `:opaque` — (optional) base64url-encoded server correlation data
  """

  @behaviour Plug

  alias MPP.Challenge
  alias MPP.Errors
  alias MPP.Headers
  alias MPP.Intents.Charge

  defmodule Config do
    @moduledoc """
    Validated configuration for `MPP.Plug`.

    Built once at init time from plug opts. Holds the pre-computed charge
    struct, base64url request string, and all endpoint-specific settings.
    """

    @type t :: %__MODULE__{
            secret_key: String.t(),
            realm: String.t(),
            method: module(),
            charge: Charge.t(),
            request: String.t(),
            method_config: map(),
            expires_in: pos_integer() | nil,
            opaque: String.t() | nil
          }

    @enforce_keys [:secret_key, :realm, :method, :charge, :request]
    defstruct [:secret_key, :realm, :method, :charge, :request, :method_config, :expires_in, :opaque]
  end

  @impl Plug
  @spec init(keyword()) :: Config.t()
  def init(opts) when is_list(opts) do
    method = require_opt!(opts, :method)
    method_config = Keyword.get(opts, :method_config, %{})

    {:ok, charge} =
      Charge.new(
        amount: require_opt!(opts, :amount),
        currency: require_opt!(opts, :currency),
        recipient: Keyword.get(opts, :recipient),
        description: Keyword.get(opts, :description)
      )

    # Pass method_config via charge.method_details so challenge_method_details
    # can read config (e.g., network_id) and return public-facing fields only
    charge_with_config = %{charge | method_details: method_config}

    # Merge method-specific public details into the charge (replaces method_config)
    charge =
      case method.challenge_method_details(charge_with_config) do
        nil -> charge
        details when is_map(details) -> %{charge | method_details: details}
      end

    request =
      charge
      |> Charge.to_request()
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    %Config{
      secret_key: require_opt!(opts, :secret_key),
      realm: require_opt!(opts, :realm),
      method: method,
      charge: charge,
      request: request,
      method_config: method_config,
      expires_in: Keyword.get(opts, :expires_in),
      opaque: Keyword.get(opts, :opaque)
    }
  end

  @impl Plug
  @spec call(Plug.Conn.t(), Config.t()) :: Plug.Conn.t()
  def call(conn, %Config{} = config) do
    case extract_credential(conn) do
      nil ->
        respond_402(conn, config, Errors.new(:payment_required, "No payment credential provided"))

      {:error, :invalid_scheme} ->
        respond_402(conn, config, Errors.new(:payment_required, "No payment credential provided"))

      {:error, reason} ->
        respond_402(conn, config, Errors.new(:malformed_credential, "#{reason}"))

      {:ok, credential} ->
        verify_credential(conn, config, credential)
    end
  end

  # Extracts and parses the Authorization header.
  # Returns nil if no header, {:error, reason} if malformed, {:ok, credential} if parsed.
  defp extract_credential(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      [] -> nil
      [header | _] -> Headers.parse_credential(header)
    end
  end

  # Runs the full verification pipeline on a parsed credential.
  defp verify_credential(conn, config, credential) do
    # Merge server-only method_config into charge.method_details for verify/2.
    # Public method_details (from challenge_method_details) stay in the serialized
    # challenge; method_config adds server-only fields (e.g., stripe_secret_key).
    # Also inject challenge_id and realm for analytics metadata.
    runtime_config =
      config.method_config
      |> Map.put("challenge_id", credential.challenge.id)
      |> Map.put("realm", config.realm)

    charge_for_verify = merge_method_config(config.charge, runtime_config)

    with :ok <- Challenge.verify(credential.challenge, config.secret_key),
         :ok <- check_expiration(credential.challenge),
         :ok <- check_request_match(credential.challenge, config),
         {:ok, receipt} <- config.method.verify(credential.payload, charge_for_verify) do
      conn
      |> Plug.Conn.assign(:mpp_receipt, receipt)
      |> Plug.Conn.put_resp_header("payment-receipt", Headers.format_receipt(receipt))
      |> Plug.Conn.put_resp_header("cache-control", "private")
    else
      {:error, :invalid_challenge} ->
        respond_402(conn, config, Errors.new(:invalid_challenge, "Challenge verification failed"))

      {:error, :payment_expired} ->
        respond_402(conn, config, Errors.new(:payment_expired, "Challenge has expired"))

      {:error, :request_mismatch} ->
        respond_402(conn, config, Errors.new(:invalid_challenge, "Request parameters do not match this endpoint"))

      {:error, %Errors{} = error} ->
        respond_402(conn, config, error)

      {:error, reason} ->
        respond_402(conn, config, Errors.new(:verification_failed, "Payment verification failed: #{inspect(reason)}"))
    end
  end

  # Checks whether a challenge has expired based on its `expires` field.
  defp check_expiration(%Challenge{expires: nil}), do: :ok

  defp check_expiration(%Challenge{expires: expires}) do
    case DateTime.from_iso8601(expires) do
      {:ok, expires_dt, _offset} ->
        if DateTime.before?(DateTime.utc_now(), expires_dt) do
          :ok
        else
          {:error, :payment_expired}
        end

      {:error, _} ->
        {:error, :payment_expired}
    end
  end

  # Compares the credential's request parameters against this endpoint's config.
  # Prevents cross-route replay: a credential for $1 can't be used on a $10 endpoint.
  defp check_request_match(%Challenge{request: request}, config) do
    with {:ok, json} <- Base.url_decode64(request, padding: false),
         {:ok, req_map} <- Jason.decode(json) do
      cond do
        req_map["amount"] != config.charge.amount ->
          {:error, :request_mismatch}

        req_map["currency"] != config.charge.currency ->
          {:error, :request_mismatch}

        true ->
          :ok
      end
    else
      _ -> {:error, :request_mismatch}
    end
  end

  # Sends a 402 response with a fresh challenge header and RFC 9457 error body.
  defp respond_402(conn, config, %Errors{} = error) do
    challenge = generate_challenge(config)
    challenge_header = Headers.format_challenge(challenge)

    conn
    |> Plug.Conn.put_resp_header("www-authenticate", challenge_header)
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> Plug.Conn.put_resp_content_type("application/problem+json")
    |> Plug.Conn.send_resp(error.status, Errors.to_json(error))
    |> Plug.Conn.halt()
  end

  # Generates a fresh challenge from the endpoint config.
  defp generate_challenge(config) do
    params =
      [
        realm: config.realm,
        method: config.method.method_name(),
        intent: "charge",
        request: config.request
      ]
      |> maybe_add(:expires, compute_expires(config.expires_in))
      |> maybe_add(:opaque, config.opaque)

    Challenge.create(params, config.secret_key)
  end

  # Computes an RFC 3339 expiration timestamp from a TTL in seconds.
  defp compute_expires(nil), do: nil

  defp compute_expires(seconds) when is_integer(seconds) do
    DateTime.utc_now()
    |> DateTime.add(seconds, :second)
    |> DateTime.to_iso8601()
  end

  # Merges server-only method_config into charge.method_details for verify/2.
  defp merge_method_config(charge, config) do
    merged = Map.merge(charge.method_details || %{}, config)
    %{charge | method_details: merged}
  end

  # Appends a keyword pair only if the value is non-nil.
  defp maybe_add(params, _key, nil), do: params
  defp maybe_add(params, key, value), do: Keyword.put(params, key, value)

  # Fetches a required option or raises with a clear message.
  defp require_opt!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "MPP.Plug requires the :#{key} option"
    end
  end
end
