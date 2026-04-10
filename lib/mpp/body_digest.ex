defmodule MPP.BodyDigest do
  @moduledoc """
  SHA-256 body digest computation and verification.

  Produces digest strings in the format `"sha-256=<base64>"` for binding request
  bodies to challenges. Maps are JSON-encoded before hashing. Verification uses
  constant-time comparison to prevent timing attacks.

  **Note:** When passing a map, the digest is computed over `Jason.encode!/1` output.
  For request body binding, pass the raw body bytes to ensure the digest matches
  the exact wire format. The map convenience path matches the mppx TypeScript
  reference but may produce different digests than raw body strings if key
  ordering differs.

  ## Examples

      iex> MPP.BodyDigest.compute(~s({"amount":"1000"}))
      "sha-256=" <> _base64

      iex> digest = MPP.BodyDigest.compute(%{"amount" => "1000"})
      iex> MPP.BodyDigest.verify(digest, %{"amount" => "1000"})
      true
  """

  use Descripex, namespace: "/protocol"

  @digest_prefix "sha-256="

  api(:compute, "Compute a SHA-256 digest of the given body.",
    params: [
      body: [
        kind: :value,
        description: "Request body as a string or map (maps are JSON-encoded before hashing)"
      ]
    ],
    returns: %{
      type: :string,
      description: ~s(Digest string in format "sha-256=<base64>"),
      example: "sha-256=X48E9qOokqqrvdts8nOJRJN3OWDUoyWxBf7kbu9DBPE"
    },
    composes_with: [:verify]
  )

  @spec compute(String.t() | map()) :: String.t()
  def compute(body) when is_binary(body) do
    hash = :crypto.hash(:sha256, body)
    @digest_prefix <> Base.encode64(hash, padding: false)
  end

  def compute(body) when is_map(body) do
    body
    |> Jason.encode!()
    |> compute()
  end

  api(:verify, "Verify a digest matches the given body using constant-time comparison.",
    params: [
      digest: [kind: :value, description: "Digest string to verify (e.g., \"sha-256=...\")"],
      body: [
        kind: :value,
        description: "Request body as a string or map (maps are JSON-encoded before hashing)"
      ]
    ],
    returns: %{type: :boolean, description: "True if the digest matches, false otherwise"},
    composes_with: [:compute]
  )

  @spec verify(String.t(), String.t() | map()) :: boolean()
  def verify(digest, body) when is_binary(digest) do
    Plug.Crypto.secure_compare(compute(body), digest)
  end
end
