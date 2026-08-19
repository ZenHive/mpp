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
    * `:expires_in` — (optional) challenge TTL in seconds (integer, defaults to 300)
    * `:digest` — (optional) expected content digest for body-bound challenges
    * `:opaque` — (optional) base64url-encoded server correlation data
    * `:store` — (optional) shared `MPP.Tempo.Store` replay-protection store
    * `:intent` — (optional) `"charge"` (default) or `"session"`
    * `:session_store` — (optional, session intent) `MPP.Session.Store` reference;
      defaults to the application-started `MPP.Session.ETSStore`

  ## Single-Method Options

    * `:method` — (required) module implementing `MPP.Method`
    * `:amount` — (required) price in base units (string)
    * `:currency` — (required) currency code (string, preserved verbatim on the wire)
    * `:recipient` — (optional) payment recipient identifier
    * `:description` — (optional) human-readable description
    * `:external_id` — (optional) merchant reference ID included in the challenge request
    * `:unit_type` — (optional, session intent) rate unit, e.g. `"request"`
    * `:suggested_deposit` — (optional, session intent) suggested channel deposit
    * `:method_config` — (optional) server-only config map for `verify/2`

  ## Multi-Method Options

    * `:methods` — (required) list of keyword lists, each with per-method opts:
      `:method`, `:amount`, `:currency`, and optionally `:recipient`,
      `:description`, `:external_id`, `:method_config`
  """

  @behaviour Plug

  alias MPP.AcceptPayment
  alias MPP.Challenge
  alias MPP.Errors
  alias MPP.Headers
  alias MPP.Intents.Charge
  alias MPP.Intents.Session
  alias MPP.JCS
  alias MPP.Replay
  alias MPP.Session.Store, as: SessionStore
  alias MPP.Telemetry
  alias MPP.Tempo.ConCacheStore
  alias MPP.Tempo.Store
  alias MPP.Verifier

  @default_expires_in_seconds 300

  defmodule MethodEntry do
    @moduledoc """
    Per-method configuration within a multi-method endpoint.

    Holds the pre-computed charge, base64url request string, and server-only
    config for a single payment method.
    """

    @type t :: %__MODULE__{
            method: module(),
            charge: Charge.t() | Session.t(),
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
            expires_in: pos_integer(),
            digest: String.t() | nil,
            opaque: String.t() | nil,
            store: module() | {module(), keyword()} | nil,
            intent: String.t(),
            session_store: SessionStore.store_ref() | nil
          }

    @enforce_keys [:secret_key, :realm, :method_entries]
    defstruct [
      :secret_key,
      :realm,
      :method_entries,
      :expires_in,
      :digest,
      :opaque,
      :store,
      intent: "charge",
      session_store: nil
    ]
  end

  @doc """
  Builds validated plug configuration from options at init time.

  Normalizes single- or multi-method opts into a `%Config{}` with one
  `MethodEntry` per accepted payment method. Raises on missing required
  options or duplicate method names.
  """
  @impl Plug
  @spec init(keyword()) :: Config.t()
  def init(opts) when is_list(opts) do
    intent = validate_intent!(Keyword.get(opts, :intent, "charge"))
    session_store = resolve_session_store(intent, Keyword.get(opts, :session_store))
    method_lists = normalize_methods(opts)
    entries = Enum.map(method_lists, &build_method_entry(&1, intent, session_store))
    validate_method_name_format!(entries)
    validate_unique_method_names!(entries)

    %Config{
      secret_key: require_opt!(opts, :secret_key),
      realm: require_opt!(opts, :realm),
      method_entries: entries,
      expires_in: validate_expires_in!(Keyword.get(opts, :expires_in, @default_expires_in_seconds)),
      digest: Keyword.get(opts, :digest),
      opaque: Keyword.get(opts, :opaque),
      store: opts |> Keyword.get(:store) |> validate_store!() |> Store.resolve(),
      intent: intent,
      session_store: session_store
    }
  end

  defp validate_intent!(intent) when intent in ["charge", "session"], do: intent

  defp validate_intent!(_intent) do
    raise ArgumentError, ~s(MPP.Plug: :intent must be "charge" or "session")
  end

  defp resolve_session_store("session", nil), do: SessionStore.default_store()
  defp resolve_session_store("session", store), do: store
  defp resolve_session_store(_intent, _store), do: nil

  defp validate_expires_in!(seconds) when is_integer(seconds) and seconds > 0, do: seconds

  defp validate_expires_in!(_seconds) do
    raise ArgumentError, "MPP.Plug: :expires_in must be a positive integer"
  end

  # `nil`/absent resolves to the default store (replay protection on by default);
  # `false` is an explicit opt-out. A configured store MUST implement the atomic
  # check_and_mark/2 — a non-atomic get/put store is rejected here rather than
  # silently degrading to a racy fallback (GHSA-w8j7-7qc3-5f24). Resolution to the default /
  # opt-out is applied by MPP.Tempo.Store.resolve/1 in init/1.
  defp validate_store!(nil), do: nil
  defp validate_store!(false), do: false

  defp validate_store!({ConCacheStore, opts} = store) do
    if !Keyword.keyword?(opts) do
      raise ArgumentError,
            "MPP.Plug :store opts for {MPP.Tempo.ConCacheStore, opts} must be a keyword list; got: #{inspect(opts)}"
    end

    store
  end

  defp validate_store!({store, _opts}) do
    raise ArgumentError,
          "MPP.Plug :store tuple form is only supported for {MPP.Tempo.ConCacheStore, opts}; got: #{inspect(store)}"
  end

  defp validate_store!(store) do
    if !Store.dedup_capable?(store) do
      raise ArgumentError,
            "MPP.Plug :store must implement MPP.Tempo.Store (get/1, put/2, check_and_mark/2 — " <>
              "atomic single-use is required; use `store: false` to disable dedup)"
    end

    store
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
        [
          Keyword.take(opts, [
            :method,
            :amount,
            :currency,
            :recipient,
            :description,
            :external_id,
            :unit_type,
            :suggested_deposit,
            :method_config
          ])
        ]

      true ->
        raise ArgumentError, "MPP.Plug requires either :method or :methods option"
    end
  end

  # Builds a MethodEntry from per-method keyword opts.
  defp build_method_entry(method_opts, intent, session_store) do
    method = require_opt!(method_opts, :method)
    method_config = Keyword.get(method_opts, :method_config, %{})
    method_config = put_session_store(method_config, session_store)
    method.validate_config!(method_config)

    {:ok, charge} = build_pricing_intent(intent, method_opts)

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
      |> intent_to_request()
      |> JCS.canonicalize()
      |> Base.url_encode64(padding: false)

    %MethodEntry{
      method: method,
      charge: charge,
      request: request,
      method_config: method_config
    }
  end

  defp put_session_store(method_config, nil), do: method_config

  defp put_session_store(method_config, session_store) do
    Map.put_new(method_config, "session_store", session_store)
  end

  defp build_pricing_intent("charge", method_opts) do
    Charge.new(
      amount: require_opt!(method_opts, :amount),
      currency: require_opt!(method_opts, :currency),
      recipient: Keyword.get(method_opts, :recipient),
      description: Keyword.get(method_opts, :description),
      external_id: Keyword.get(method_opts, :external_id)
    )
  end

  defp build_pricing_intent("session", method_opts) do
    Session.new(
      amount: require_opt!(method_opts, :amount),
      currency: require_opt!(method_opts, :currency),
      recipient: Keyword.get(method_opts, :recipient),
      unit_type: Keyword.get(method_opts, :unit_type),
      suggested_deposit: Keyword.get(method_opts, :suggested_deposit)
    )
  end

  defp intent_to_request(%Charge{} = charge), do: Charge.to_request(charge)
  defp intent_to_request(%Session{} = session), do: Session.to_request(session)

  # Validates that every method name matches the spec ABNF
  # `payment-method-id = 1*LOWERALPHA`. Challenge parsing (this library's own
  # client paths included) rejects any other shape as `:invalid_method`, so a
  # non-conformant name must fail at boot rather than emit unparseable
  # challenges.
  defp validate_method_name_format!(entries) do
    bad =
      entries
      |> Enum.map(& &1.method.method_name())
      |> Enum.reject(&Challenge.valid_method_name?/1)

    if bad != [] do
      raise ArgumentError,
            "MPP.Plug: method names must be non-empty lowercase ASCII letters " <>
              "(spec `payment-method-id = 1*LOWERALPHA`): #{inspect(Enum.uniq(bad))}"
    end
  end

  # Validates that all method entries have unique method names.
  defp validate_unique_method_names!(entries) do
    names = Enum.map(entries, & &1.method.method_name())
    dupes = names -- Enum.uniq(names)

    if dupes != [] do
      raise ArgumentError, "MPP.Plug: duplicate method names: #{inspect(Enum.uniq(dupes))}"
    end
  end

  @doc """
  Runs the MPP 402 payment handshake for the current request.

  Returns `402` with fresh challenges when no valid credential is present;
  halts with an RFC 9457 problem body on verification failure; otherwise
  passes the connection through with `:mpp_receipt` assigned and a
  `Payment-Receipt` response header.
  """
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
            charge = Telemetry.charge_from_challenge(credential.challenge)
            error = Errors.new(:method_unsupported, "Unknown payment method: #{credential.challenge.method}")
            start_time = Telemetry.verify_start(credential, charge, %{realm: config.realm})
            Telemetry.verify_fail(credential, charge, start_time, error, %{realm: config.realm})

            respond_error(conn, config, error)

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

  # Delegates verification to the transport-neutral MPP.Verifier, then handles
  # the Plug-specific result (conn assigns, headers, error responses).
  defp verify_credential(conn, config, credential, entry) do
    store = Replay.store_for(config, entry)
    charge = entry.charge

    opts = [
      secret_key: config.secret_key,
      realm: config.realm,
      method: entry.method,
      charge: charge,
      method_config: entry.method_config,
      digest: config.digest,
      opaque: config.opaque
    ]

    case Replay.check_unused(store, credential) do
      {:error, %Errors{} = error} ->
        start_time = Telemetry.verify_start(credential, charge, %{realm: config.realm})
        Telemetry.verify_fail(credential, charge, start_time, error, %{realm: config.realm})
        respond_error(conn, config, error)

      :ok ->
        with {:ok, receipt} <- Verifier.verify(credential, opts),
             :ok <- Replay.mark_used(store, credential) do
          conn
          |> Plug.Conn.assign(:mpp_receipt, receipt)
          |> Plug.Conn.put_resp_header("payment-receipt", Headers.format_receipt(receipt))
          |> Plug.Conn.put_resp_header("cache-control", "private")
        else
          {:error, %Errors{} = error} ->
            respond_error(conn, config, error)
        end
    end
  end

  # Sends an error response with RFC 9457 error body.
  # Only 402 responses include WWW-Authenticate challenge headers.
  defp respond_error(conn, config, %Errors{} = error) do
    conn =
      if error.status == 402 do
        entries = filter_method_entries_by_accept_payment(conn, config.method_entries)

        challenge_headers =
          Enum.map(entries, fn entry ->
            challenge = generate_challenge(config, entry)
            Telemetry.challenge(challenge, entry.charge, %{realm: config.realm})
            {"www-authenticate", Headers.format_challenge(challenge)}
          end)

        Plug.Conn.prepend_resp_headers(conn, challenge_headers)
      else
        conn
      end

    conn =
      case error.retry_after do
        seconds when is_integer(seconds) -> Plug.Conn.put_resp_header(conn, "retry-after", Integer.to_string(seconds))
        nil -> conn
      end

    conn
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> Plug.Conn.put_resp_content_type("application/problem+json")
    |> Plug.Conn.send_resp(error.status, Errors.to_json(error))
    |> Plug.Conn.halt()
  end

  defp filter_method_entries_by_accept_payment(conn, method_entries) do
    header =
      case Plug.Conn.get_req_header(conn, "accept-payment") do
        [] -> nil
        [value | _] -> value
      end

    AcceptPayment.apply_header(method_entries, header, fn entry ->
      {entry.method.method_name(), intent_name(entry.charge)}
    end)
  end

  defp intent_name(%Charge{}), do: "charge"
  defp intent_name(%Session{}), do: "session"

  # Generates a fresh challenge for a specific method entry. Public (but
  # undocumented) so the MCP server adapter (`MPP.Mcp`) can reuse the exact same
  # challenge-generation logic instead of duplicating it.
  @doc false
  @spec generate_challenge(Config.t(), MethodEntry.t()) :: Challenge.t()
  def generate_challenge(config, entry) do
    params =
      [
        realm: config.realm,
        method: entry.method.method_name(),
        intent: config.intent,
        request: entry.request
      ]
      |> maybe_add(:expires, compute_expires(config.expires_in))
      |> maybe_add(:digest, config.digest)
      |> maybe_add(:opaque, config.opaque)

    Challenge.create(params, config.secret_key)
  end

  # Computes an RFC 3339 expiration timestamp from a TTL in seconds.
  defp compute_expires(seconds) when is_integer(seconds) do
    DateTime.utc_now()
    |> DateTime.shift(second: seconds)
    |> DateTime.to_iso8601()
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
