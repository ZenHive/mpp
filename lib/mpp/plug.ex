defmodule MPP.Plug do
  @moduledoc """
  Plug middleware implementing the MPP 402 payment handshake.

  Mount this plug in any Phoenix or Plug router to gate endpoints behind
  payment. Each route gets its own pricing via plug opts — no global config.

  ## Single-Method Usage

      plug MPP.Plug,
        secret_key: "your-hmac-secret",
        realm: "api.example.com",
        method: MyApp.Payments.Stripe,
        amount: "1000",
        currency: "usd"

  ## Multi-Method Usage

  Accept multiple payment methods per endpoint. Each method can have its own
  pricing and config. The 402 response includes one `WWW-Authenticate` header
  per method; the agent picks whichever it can pay with.

      plug MPP.Plug,
        secret_key: "your-hmac-secret",
        realm: "api.example.com",
        methods: [
          [method: MyApp.Payments.Stripe, amount: "1000", currency: "usd",
           method_config: %{"stripe_secret_key" => "sk_..."}],
          [method: MyApp.Payments.Tempo, amount: "950", currency: "usd"]
        ]

  ## Flow

  1. Request without `Authorization: Payment` → 402 with `WWW-Authenticate` challenge(s)
  2. Client pays off-band, retries with `Authorization: Payment <credential>`
  3. Valid credential → request passes through with `Payment-Receipt` header + receipt in assigns
  4. Invalid credential → 402 with fresh challenge(s) + RFC 9457 error body

  ## Shared Options

    * `:secret_key` — (required) HMAC-SHA256 key for challenge binding
    * `:realm` — (required) server protection space
    * `:expires_in` — (optional) challenge TTL in seconds (integer)
    * `:opaque` — (optional) base64url-encoded server correlation data

  ## Single-Method Options

    * `:method` — (required) module implementing `MPP.Method`
    * `:amount` — (required) price in base units (string)
    * `:currency` — (required) currency code (string, normalized to lowercase)
    * `:recipient` — (optional) payment recipient identifier
    * `:description` — (optional) human-readable description
    * `:method_config` — (optional) server-only config map for `verify/2`

  ## Multi-Method Options

    * `:methods` — (required) list of keyword lists, each with per-method opts:
      `:method`, `:amount`, `:currency`, and optionally `:recipient`,
      `:description`, `:method_config`
  """

  @behaviour Plug

  alias MPP.Challenge
  alias MPP.Errors
  alias MPP.Headers
  alias MPP.Intents.Charge

  defmodule MethodEntry do
    @moduledoc """
    Per-method configuration within a multi-method endpoint.

    Holds the pre-computed charge, base64url request string, and server-only
    config for a single payment method.
    """

    @type t :: %__MODULE__{
            method: module(),
            charge: Charge.t(),
            request: String.t(),
            method_config: map()
          }

    @enforce_keys [:method, :charge, :request]
    defstruct [:method, :charge, :request, method_config: %{}]
  end

  defmodule Config do
    @moduledoc """
    Validated configuration for `MPP.Plug`.

    Built once at init time from plug opts. Holds shared endpoint settings
    and a list of `MethodEntry` structs — one per accepted payment method.
    """

    @type t :: %__MODULE__{
            secret_key: String.t(),
            realm: String.t(),
            method_entries: [MethodEntry.t()],
            expires_in: pos_integer() | nil,
            opaque: String.t() | nil
          }

    @enforce_keys [:secret_key, :realm, :method_entries]
    defstruct [:secret_key, :realm, :method_entries, :expires_in, :opaque]
  end

  @impl Plug
  @spec init(keyword()) :: Config.t()
  def init(opts) when is_list(opts) do
    method_lists = normalize_methods(opts)
    entries = Enum.map(method_lists, &build_method_entry/1)
    validate_unique_method_names!(entries)

    %Config{
      secret_key: require_opt!(opts, :secret_key),
      realm: require_opt!(opts, :realm),
      method_entries: entries,
      expires_in: Keyword.get(opts, :expires_in),
      opaque: Keyword.get(opts, :opaque)
    }
  end

  # Normalizes single-method and multi-method opts into a list of keyword lists.
  defp normalize_methods(opts) do
    has_method = Keyword.has_key?(opts, :method)
    has_methods = Keyword.has_key?(opts, :methods)

    cond do
      has_method and has_methods ->
        raise ArgumentError, "MPP.Plug: provide either :method or :methods, not both"

      has_methods ->
        Keyword.fetch!(opts, :methods)

      has_method ->
        [Keyword.take(opts, [:method, :amount, :currency, :recipient, :description, :method_config])]

      true ->
        raise ArgumentError, "MPP.Plug requires either :method or :methods option"
    end
  end

  # Builds a MethodEntry from per-method keyword opts.
  defp build_method_entry(method_opts) do
    method = require_opt!(method_opts, :method)
    method_config = Keyword.get(method_opts, :method_config, %{})
    method.validate_config!(method_config)

    {:ok, charge} =
      Charge.new(
        amount: require_opt!(method_opts, :amount),
        currency: require_opt!(method_opts, :currency),
        recipient: Keyword.get(method_opts, :recipient),
        description: Keyword.get(method_opts, :description)
      )

    # Pass method_config via charge.method_details so challenge_method_details
    # can read config (e.g., network_id) and return public-facing fields only
    charge_with_config = %{charge | method_details: method_config}

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

    %MethodEntry{
      method: method,
      charge: charge,
      request: request,
      method_config: method_config
    }
  end

  # Validates that all method entries have unique method names.
  defp validate_unique_method_names!(entries) do
    names = Enum.map(entries, & &1.method.method_name())
    dupes = names -- Enum.uniq(names)

    if dupes != [] do
      raise ArgumentError, "MPP.Plug: duplicate method names: #{inspect(Enum.uniq(dupes))}"
    end
  end

  @impl Plug
  @spec call(Plug.Conn.t(), Config.t()) :: Plug.Conn.t()
  def call(conn, %Config{} = config) do
    case extract_credential(conn) do
      nil ->
        respond_error(conn, config, Errors.new(:payment_required, "No payment credential provided"))

      {:error, :invalid_scheme} ->
        respond_error(conn, config, Errors.new(:payment_required, "No payment credential provided"))

      {:error, reason} ->
        respond_error(conn, config, Errors.new(:malformed_credential, "#{reason}"))

      {:ok, credential} ->
        case find_method_entry(config, credential.challenge.method) do
          nil ->
            respond_error(
              conn,
              config,
              Errors.new(:method_unsupported, "Unknown payment method: #{credential.challenge.method}")
            )

          entry ->
            verify_credential(conn, config, credential, entry)
        end
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

  # Finds the MethodEntry matching the credential's method name.
  defp find_method_entry(config, method_name) do
    Enum.find(config.method_entries, fn entry ->
      entry.method.method_name() == method_name
    end)
  end

  # Runs the full verification pipeline on a parsed credential.
  defp verify_credential(conn, config, credential, entry) do
    # Merge server-only method_config into charge.method_details for verify/2.
    # Public method_details (from challenge_method_details) stay in the serialized
    # challenge; method_config adds server-only fields (e.g., stripe_secret_key).
    # Also inject challenge_id and realm for analytics metadata.
    runtime_config =
      entry.method_config
      |> Map.put("challenge_id", credential.challenge.id)
      |> Map.put("realm", config.realm)

    charge_for_verify = merge_method_config(entry.charge, runtime_config)

    with :ok <- Challenge.verify(credential.challenge, config.secret_key),
         :ok <- check_realm_match(credential.challenge, config),
         :ok <- check_expiration(credential.challenge),
         :ok <- check_request_match(credential.challenge, entry),
         {:ok, receipt} <- entry.method.verify(credential.payload, charge_for_verify) do
      conn
      |> Plug.Conn.assign(:mpp_receipt, receipt)
      |> Plug.Conn.put_resp_header("payment-receipt", Headers.format_receipt(receipt))
      |> Plug.Conn.put_resp_header("cache-control", "private")
    else
      {:error, :invalid_challenge} ->
        respond_error(conn, config, Errors.new(:invalid_challenge, "Challenge verification failed"))

      {:error, :payment_expired} ->
        respond_error(conn, config, Errors.new(:payment_expired, "Challenge has expired"))

      {:error, :request_mismatch} ->
        respond_error(conn, config, Errors.new(:invalid_challenge, "Request parameters do not match this endpoint"))

      {:error, %Errors{} = error} ->
        respond_error(conn, config, error)

      {:error, reason} ->
        respond_error(conn, config, Errors.new(:verification_failed, "Payment verification failed: #{inspect(reason)}"))
    end
  end

  # Verifies the credential's realm matches this endpoint's realm.
  # Defense-in-depth: HMAC binding covers realm when secrets are unique per realm,
  # but an explicit check prevents cross-realm replay in shared-secret deployments.
  defp check_realm_match(%Challenge{realm: realm}, %Config{realm: realm}), do: :ok
  defp check_realm_match(_challenge, _config), do: {:error, :request_mismatch}

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

  # Compares the credential's request parameters against this method entry's charge.
  # Prevents cross-route replay: a credential for one endpoint can't be used on another.
  # Checks amount, currency, and recipient to match the reference implementation.
  defp check_request_match(%Challenge{request: request}, entry) do
    with {:ok, json} <- Base.url_decode64(request, padding: false),
         {:ok, req_map} <- Jason.decode(json) do
      cond do
        req_map["amount"] != entry.charge.amount ->
          {:error, :request_mismatch}

        req_map["currency"] != entry.charge.currency ->
          {:error, :request_mismatch}

        !recipient_matches?(req_map["recipient"], entry.charge.recipient) ->
          {:error, :request_mismatch}

        true ->
          :ok
      end
    else
      _ -> {:error, :request_mismatch}
    end
  end

  # Compares recipient values, treating nil as "not configured" (matches anything).
  # When the endpoint has a recipient configured, the credential must match it.
  defp recipient_matches?(_credential_recipient, nil), do: true
  defp recipient_matches?(credential_recipient, endpoint_recipient), do: credential_recipient == endpoint_recipient

  # Sends an error response with RFC 9457 error body.
  # Only 402 responses include WWW-Authenticate challenge headers.
  defp respond_error(conn, config, %Errors{} = error) do
    conn =
      if error.status == 402 do
        challenge_headers =
          Enum.map(config.method_entries, fn entry ->
            challenge = generate_challenge(config, entry)
            {"www-authenticate", Headers.format_challenge(challenge)}
          end)

        Plug.Conn.prepend_resp_headers(conn, challenge_headers)
      else
        conn
      end

    conn
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> Plug.Conn.put_resp_content_type("application/problem+json")
    |> Plug.Conn.send_resp(error.status, Errors.to_json(error))
    |> Plug.Conn.halt()
  end

  # Generates a fresh challenge for a specific method entry.
  defp generate_challenge(config, entry) do
    params =
      [
        realm: config.realm,
        method: entry.method.method_name(),
        intent: "charge",
        request: entry.request
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
  defp merge_method_config(charge, runtime_config) do
    merged = Map.merge(charge.method_details || %{}, runtime_config)
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
