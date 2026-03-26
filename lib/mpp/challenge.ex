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

  def verify(%__MODULE__{id: nil}, _secret_key), do: {:error, :invalid_challenge}

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
