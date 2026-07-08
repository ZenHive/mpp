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

  ## Single-Method Options

    * `:method` — (required) module implementing `MPP.Method`
    * `:amount` — (required) price in base units (string)
    * `:currency` — (required) currency code (string, normalized to lowercase)
    * `:recipient` — (optional) payment recipient identifier
    * `:description` — (optional) human-readable description
    * `:external_id` — (optional) merchant reference ID included in the challenge request
    * `:method_config` — (optional) server-only config map for `verify/2`

  ## Multi-Method Options

    * `:methods` — (required) list of keyword lists, each with per-method opts:
      `:method`, `:amount`, `:currency`, and optionally `:recipient`,
      `:description`, `:external_id`, `:method_config`
  """

  @behaviour Plug

  alias MPP.Challenge
  alias MPP.Errors
  alias MPP.Headers
  alias MPP.Intents.Charge
  alias MPP.JCS
  alias MPP.Telemetry
  alias MPP.Tempo.ConCacheStore
  alias MPP.Tempo.Store
  alias MPP.Verifier

  @default_expires_in_seconds 300
  @dedup_store_key_prefix "mpp:credential:"
  @dedup_store_error_detail "Dedup store error"

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
            expires_in: pos_integer(),
            digest: String.t() | nil,
            opaque: String.t() | nil,
            store: module() | {module(), keyword()} | nil
          }

    @enforce_keys [:secret_key, :realm, :method_entries]
    defstruct [:secret_key, :realm, :method_entries, :expires_in, :digest, :opaque, :store]
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
    method_lists = normalize_methods(opts)
    entries = Enum.map(method_lists, &build_method_entry/1)
    validate_unique_method_names!(entries)

    %Config{
      secret_key: require_opt!(opts, :secret_key),
      realm: require_opt!(opts, :realm),
      method_entries: entries,
      expires_in: validate_expires_in!(Keyword.get(opts, :expires_in, @default_expires_in_seconds)),
      digest: Keyword.get(opts, :digest),
      opaque: Keyword.get(opts, :opaque),
      store: opts |> Keyword.get(:store) |> validate_store!() |> Store.resolve()
    }
  end

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
    if !(is_atom(store) and function_exported?(store, :get, 1) and function_exported?(store, :put, 2) and
           function_exported?(store, :check_and_mark, 2)) do
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
            :method_config
          ])
        ]

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
        description: Keyword.get(method_opts, :description),
        external_id: Keyword.get(method_opts, :external_id)
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
      |> JCS.canonicalize()
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
    store = replay_store(config, entry)
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

    case check_credential_unused(store, credential) do
      {:error, %Errors{} = error} ->
        start_time = Telemetry.verify_start(credential, charge, %{realm: config.realm})
        Telemetry.verify_fail(credential, charge, start_time, error, %{realm: config.realm})
        respond_error(conn, config, error)

      :ok ->
        with {:ok, receipt} <- Verifier.verify(credential, opts),
             :ok <- mark_credential_used(store, credential) do
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

  # Skip the plug-level credential store for Tempo — that method self-manages its
  # own dedup (mpp:charge:/mpp:proof: + attribution binding), which already covers
  # the credential-replay case. Every other method gets the plug store. EVM
  # deliberately runs BOTH layers: the plug credential store (challenge-bound) and
  # its method-level mpp:evm: hash store (cross-challenge single-use) — disjoint
  # keys, complementary guarantees; do not "fix" this by extending the carve-out.
  defp replay_store(%Config{store: nil}, _entry), do: nil

  defp replay_store(config, %{method: method}) do
    if method.method_name() == "tempo", do: nil, else: config.store
  end

  defp check_credential_unused(nil, _credential), do: :ok

  defp check_credential_unused(store, credential) do
    key = credential_store_key(credential)

    case Store.get(store, key) do
      :not_found -> :ok
      {:ok, _value} -> {:error, Errors.new(:verification_failed, "Payment credential already used")}
      {:error, _reason} -> {:error, Errors.new(:verification_failed, @dedup_store_error_detail)}
    end
  end

  defp mark_credential_used(nil, _credential), do: :ok

  # Atomic single-use claim. validate_store!/1 guarantees the store implements
  # check_and_mark/2, so there is no non-atomic fallback (GHSA-w8j7-7qc3-5f24).
  defp mark_credential_used(store, credential) do
    key = credential_store_key(credential)
    value = System.system_time(:millisecond)

    case Store.check_and_mark(store, key, value) do
      :ok -> :ok
      {:error, :already_exists} -> {:error, Errors.new(:verification_failed, "Payment credential already used")}
      {:error, _reason} -> {:error, Errors.new(:verification_failed, @dedup_store_error_detail)}
    end
  end

  defp credential_store_key(credential) do
    @dedup_store_key_prefix <> credential.challenge.id <> ":" <> payload_hash(credential.payload)
  end

  defp payload_hash(payload) do
    :sha256
    |> :crypto.hash(JCS.canonicalize(payload))
    |> Base.url_encode64(padding: false)
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

    Headers.apply_accept_payment_header(method_entries, header, fn entry ->
      {entry.method.method_name(), "charge"}
    end)
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
      |> maybe_add(:digest, config.digest)
      |> maybe_add(:opaque, config.opaque)

    Challenge.create(params, config.secret_key)
  end

  # Computes an RFC 3339 expiration timestamp from a TTL in seconds.
  defp compute_expires(seconds) when is_integer(seconds) do
    DateTime.utc_now()
    |> DateTime.add(seconds, :second)
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
