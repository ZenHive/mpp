defmodule MPP.Credential do
  @moduledoc """
  Payment credential — the client's response to a 402 challenge.

  A credential is sent in the `Authorization: Payment <base64url JSON>` header
  after the client has fulfilled payment. It echoes the original challenge
  parameters alongside method-specific payment proof, enabling the server to
  verify both the challenge binding (via `MPP.Challenge.verify/2`) and the
  payment itself (via the method module).

  ## Wire Format

  The base64url-decoded JSON contains:

      %{
        "challenge" => %{...},   # Echoed challenge parameters
        "payload"   => %{...},   # Method-specific payment proof
        "source"    => "did:..."  # (optional) Payer identifier
      }

  The `challenge.request` field remains as its raw base64url string — never
  re-serialized — to preserve the exact bytes used in HMAC computation.

  ## Fields

    * `challenge` — echoed `MPP.Challenge` struct from the 402 response
    * `payload` — method-specific payment proof (opaque map at this layer)
    * `source` — (optional) payer identifier, recommended as DID format
  """

  use Descripex, namespace: "/protocol"

  alias MPP.Challenge
  alias MPP.Codec

  @type t :: %__MODULE__{
          challenge: Challenge.t(),
          payload: map(),
          source: String.t() | nil
        }

  @enforce_keys [:challenge, :payload]
  defstruct [:challenge, :payload, :source]

  @challenge_required_keys ~w(id realm method intent request)
  @challenge_optional_keys ~w(description digest expires opaque)

  api(:decode, "Decode a base64url JSON string into a credential with echoed challenge validation.",
    params: [
      encoded: [kind: :value, description: "Base64url-encoded JSON credential string"]
    ],
    returns: %{type: :tagged_tuple, description: "`{:ok, credential}` on success, `{:error, reason}` on failure"},
    errors: [
      :invalid_base64,
      :invalid_json,
      :missing_required_fields,
      :invalid_optional_field,
      :empty_id,
      :invalid_method,
      :invalid_request,
      :invalid_digest
    ],
    composes_with: [:encode]
  )

  @spec decode(String.t()) :: {:ok, t()} | {:error, atom()}
  def decode(encoded) when is_binary(encoded) do
    case Codec.decode_base64_json(encoded) do
      {:ok, map} -> from_map(map)
      {:error, _reason} = error -> error
    end
  end

  api(:encode, "Encode a credential to a base64url JSON string (no padding) for the Authorization header.",
    params: [
      credential: [kind: :value, description: "Credential struct to encode"]
    ],
    returns: %{type: :string, description: "Base64url-encoded JSON string"},
    composes_with: [:decode]
  )

  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = credential) do
    credential
    |> to_map()
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  # Deserializes a string-keyed map into a credential struct.
  defp from_map(%{"challenge" => challenge_map, "payload" => payload} = map)
       when is_map(challenge_map) and is_map(payload) do
    with :ok <- validate_optional_string(map["source"]),
         {:ok, challenge} <- challenge_from_map(challenge_map) do
      {:ok, %__MODULE__{challenge: challenge, payload: payload, source: map["source"]}}
    end
  end

  defp from_map(_), do: {:error, :missing_required_fields}

  # Validates and reconstructs a Challenge struct from the echoed challenge map.
  # After confirming the required keys are present strings and the optional keys
  # are absent or strings, the shared `Challenge.validate_fields/1` rejects a
  # malformed echoed field (empty id, non-lowercase method, non-JSON request,
  # bad digest) at parse time with a distinct atom rather than deferring to a
  # downstream HMAC mismatch.
  defp challenge_from_map(map) do
    if Enum.all?(@challenge_required_keys, &is_binary(map[&1])) do
      challenge = %Challenge{
        id: map["id"],
        realm: map["realm"],
        method: map["method"],
        intent: map["intent"],
        request: map["request"],
        description: map["description"],
        digest: map["digest"],
        expires: map["expires"],
        opaque: map["opaque"]
      }

      with :ok <- validate_optional_challenge_fields(map),
           :ok <- Challenge.validate_fields(challenge) do
        {:ok, challenge}
      end
    else
      {:error, :missing_required_fields}
    end
  end

  # Optional echoed-challenge fields (and the top-level `source`) must be absent
  # or strings. A non-string value (map, list, number) is never emitted by a
  # compliant server and would otherwise flow into the HMAC input join /
  # ISO-8601 parse downstream and crash the verifier on attacker-supplied wire
  # bytes. mppx (`z.optional(z.string())`) and mpp-rs (`Option<String>` via
  # serde) both reject these shapes at deserialization.
  defp validate_optional_challenge_fields(map) do
    Enum.reduce_while(@challenge_optional_keys, :ok, fn key, :ok ->
      case validate_optional_string(map[key]) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_optional_string(value) when is_nil(value) or is_binary(value), do: :ok
  defp validate_optional_string(_value), do: {:error, :invalid_optional_field}

  # Serializes credential struct to a map with string keys matching the spec.
  defp to_map(%__MODULE__{} = credential) do
    map = %{
      "challenge" => challenge_to_map(credential.challenge),
      "payload" => credential.payload
    }

    if credential.source do
      Map.put(map, "source", credential.source)
    else
      map
    end
  end

  # Serializes a Challenge struct to a string-keyed map, omitting nil optional fields.
  defp challenge_to_map(%Challenge{} = challenge) do
    base = %{
      "id" => challenge.id,
      "realm" => challenge.realm,
      "method" => challenge.method,
      "intent" => challenge.intent,
      "request" => challenge.request
    }

    base
    |> maybe_put("description", challenge.description)
    |> maybe_put("digest", challenge.digest)
    |> maybe_put("expires", challenge.expires)
    |> maybe_put("opaque", challenge.opaque)
  end

  # Adds a key-value pair to the map only if the value is non-nil.
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
