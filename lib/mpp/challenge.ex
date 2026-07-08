defmodule MPP.Challenge do
  @moduledoc """
  Payment challenge — the 402 response that tells a client what to pay.

  A challenge is returned in the `WWW-Authenticate: Payment` header when a
  request lacks a valid payment credential. The challenge ID is HMAC-SHA256
  bound to all challenge parameters, making it tamper-proof without requiring
  server-side state.

  ## HMAC Binding

  The challenge ID is computed as:

      base64url(HMAC-SHA256(secret_key, realm|method|intent|request|expires|digest|opaque))

  Seven fixed positional slots joined by `|`. Optional fields use empty string
  when absent, preserving slot positions. The `request` and `opaque` fields are
  used as their raw base64url-encoded strings (never re-serialized).

  ## Fields

    * `id` — HMAC-SHA256 challenge ID (computed by `create/2`)
    * `realm` — server protection space (e.g., `"api.example.com"`)
    * `method` — payment method name (e.g., `"stripe"`, `"tempo"`)
    * `intent` — intent type (e.g., `"charge"`)
    * `request` — base64url-encoded JSON request payload (pre-encoded)
    * `description` — (optional) human-readable description
    * `digest` — (optional) content digest per RFC 9530
    * `expires` — (optional) RFC 3339 expiration timestamp
    * `opaque` — (optional) base64url-encoded JSON server correlation data
  """

  use Descripex, namespace: "/protocol"

  @type t :: %__MODULE__{
          id: String.t() | nil,
          realm: String.t(),
          method: String.t(),
          intent: String.t(),
          request: String.t(),
          description: String.t() | nil,
          digest: String.t() | nil,
          expires: String.t() | nil,
          opaque: String.t() | nil
        }

  @enforce_keys [:realm, :method, :intent, :request]
  defstruct [:id, :realm, :method, :intent, :request, :description, :digest, :expires, :opaque]

  @hmac_separator "|"

  api(:create, "Create a new challenge with an HMAC-SHA256 bound ID.",
    params: [
      params: [
        kind: :value,
        description:
          "Keyword list with `:realm`, `:method`, `:intent`, `:request` (required) and `:description`, `:digest`, `:expires`, `:opaque` (optional)"
      ],
      secret_key: [kind: :value, description: "HMAC-SHA256 secret key for challenge binding"]
    ],
    returns: %{type: :struct, description: "Challenge struct with computed `id`"},
    composes_with: [:verify]
  )

  @spec create(keyword(), String.t()) :: t()
  def create(params, secret_key) when is_list(params) and is_binary(secret_key) do
    challenge = struct!(__MODULE__, Keyword.delete(params, :id))
    %{challenge | id: compute_id(challenge, secret_key)}
  end

  api(:verify, "Verify a challenge's HMAC-bound ID against a secret key using constant-time comparison.",
    params: [
      challenge: [kind: :value, description: "Challenge struct to verify"],
      secret_key: [kind: :value, description: "HMAC-SHA256 secret key used when challenge was created"]
    ],
    returns: %{type: :tagged, description: "`:ok` if valid, `{:error, :invalid_challenge}` if tampered"},
    errors: [:invalid_challenge],
    composes_with: [:create]
  )

  @spec verify(t(), String.t()) :: :ok | {:error, :invalid_challenge}
  def verify(%__MODULE__{id: id} = challenge, secret_key) when is_binary(id) and is_binary(secret_key) do
    expected = compute_id(challenge, secret_key)

    if Plug.Crypto.secure_compare(id, expected) do
      :ok
    else
      {:error, :invalid_challenge}
    end
  end

  @spec verify(t(), String.t()) :: {:error, :invalid_challenge}
  def verify(%__MODULE__{id: nil}, _secret_key), do: {:error, :invalid_challenge}

  api(
    :verify_server_binding,
    "Verify challenge HMAC using the server's configured realm (Tier-1 server binding). Recomputes the ID with `server_realm` instead of the echoed realm, matching mpp-rs `verify_hmac_and_expiry`.",
    params: [
      challenge: [kind: :value, description: "Challenge struct with echoed fields"],
      secret_key: [kind: :value, description: "HMAC-SHA256 secret key"],
      server_realm: [kind: :value, description: "Server's configured protection space realm"]
    ],
    returns: %{type: :tagged, description: "`:ok` if valid, `{:error, :invalid_challenge}` if tampered"},
    errors: [:invalid_challenge],
    composes_with: [:create, :verify]
  )

  @spec verify_server_binding(t(), String.t(), String.t()) :: :ok | {:error, :invalid_challenge}
  def verify_server_binding(%__MODULE__{id: id} = challenge, secret_key, server_realm)
      when is_binary(id) and is_binary(secret_key) and is_binary(server_realm) do
    expected = compute_id(%{challenge | realm: server_realm}, secret_key)

    if Plug.Crypto.secure_compare(id, expected) do
      :ok
    else
      {:error, :invalid_challenge}
    end
  end

  @spec verify_server_binding(t(), String.t(), String.t()) :: {:error, :invalid_challenge}
  def verify_server_binding(%__MODULE__{id: nil}, _secret_key, _server_realm), do: {:error, :invalid_challenge}

  api(
    :validate_fields,
    "Validate the field shapes of a parsed challenge (id non-empty, method `1*LOWERALPHA`, request base64url-JSON object, digest `sha-256=…`). Returns distinct error atoms so a malformed field is rejected at parse time rather than deferring to a downstream mismatch.",
    params: [
      challenge: [
        kind: :value,
        description: "Challenge struct built from a parsed WWW-Authenticate header or echoed credential"
      ]
    ],
    returns: %{type: :tagged, description: "`:ok` if all fields are well-formed, `{:error, reason}` otherwise"},
    errors: [:empty_id, :invalid_method, :invalid_request, :invalid_digest],
    composes_with: [:create, :verify]
  )

  @spec validate_fields(t()) :: :ok | {:error, :empty_id | :invalid_method | :invalid_request | :invalid_digest}
  def validate_fields(%__MODULE__{} = challenge) do
    with :ok <- validate_id(challenge.id),
         :ok <- validate_method(challenge.method),
         :ok <- validate_request(challenge.request) do
      validate_digest(challenge.digest)
    end
  end

  # id MUST be non-empty (mpp-rs "Empty 'id' parameter"; mppx `z.minLength(1)`).
  defp validate_id(id) when is_binary(id) and id != "", do: :ok
  defp validate_id(_id), do: {:error, :empty_id}

  # method MUST match `payment-method-id = 1*LOWERALPHA` (spec §"Method Identifier
  # Format", refs/mpp-specs/specs/core/draft-httpauth-payment-00.md:504-510). Follows
  # mpp-rs (`chars().all(is_ascii_lowercase)`); mppx's `[a-z][a-z0-9:_-]*` is looser
  # than the spec ABNF, so the spec breaks the tie toward lowercase-letters-only.
  defp validate_method(method) when is_binary(method) do
    if method != "" and lower_alpha?(method), do: :ok, else: {:error, :invalid_method}
  end

  defp validate_method(_method), do: {:error, :invalid_method}

  defp lower_alpha?(method), do: method |> :binary.bin_to_list() |> Enum.all?(&(&1 in ?a..?z))

  # request MUST base64url-decode to a valid JSON object (mpp-rs validates JSON via
  # `serde_json::from_slice`; mppx via `PaymentRequest.deserialize` + `z.record`,
  # which requires an object). The raw base64url string stays on the struct so the
  # HMAC binds the wire bytes — this only checks the shape, discarding the decode.
  defp validate_request(request) when is_binary(request) do
    with {:ok, json} <- Base.url_decode64(request, padding: false),
         {:ok, decoded} <- Jason.decode(json),
         true <- is_map(decoded) do
      :ok
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp validate_request(_request), do: {:error, :invalid_request}

  # digest, when present, MUST start with "sha-256=" (mpp-rs `is_valid_digest_format`;
  # mppx `z.regex(/^sha-256=/)`).
  defp validate_digest(nil), do: :ok
  defp validate_digest("sha-256=" <> _), do: :ok
  defp validate_digest(_digest), do: {:error, :invalid_digest}

  # Computes the HMAC-SHA256 challenge ID from 7 fixed positional slots.
  #
  # Input format: realm|method|intent|request|expires_or_empty|digest_or_empty|opaque_or_empty
  # Result: base64url(HMAC-SHA256(secret_key, input)) with no padding
  defp compute_id(%__MODULE__{} = challenge, secret_key) do
    input =
      Enum.join(
        [
          challenge.realm,
          challenge.method,
          challenge.intent,
          challenge.request,
          challenge.expires || "",
          challenge.digest || "",
          challenge.opaque || ""
        ],
        @hmac_separator
      )

    :hmac
    |> :crypto.mac(:sha256, secret_key, input)
    |> Base.url_encode64(padding: false)
  end
end
