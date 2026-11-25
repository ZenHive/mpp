defmodule MPP.BodyDigest do
  @moduledoc """
  SHA-256 body digest computation and verification.

  Produces digest strings in the format `"sha-256=<base64>"` (padded Base64, as
  mppx and mpp-rs write it) for binding request bodies to challenges.
  `verify/2` also accepts the RFC 9530 form `"sha-256=:<base64>:"` and either
  form without padding. Maps are JSON-encoded before hashing. Verification uses
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
      example: "sha-256=X48E9qOokqqrvdts8nOJRJN3OWDUoyWxBf7kbu9DBPE="
    },
    composes_with: [:verify]
  )

  @spec compute(String.t() | map()) :: String.t()
  def compute(body) when is_binary(body) do
    hash = :crypto.hash(:sha256, body)
    @digest_prefix <> Base.encode64(hash)
  end

  @spec compute(map()) :: String.t()
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
  def verify(@digest_prefix <> encoded, body) when is_binary(body) do
    case digest_hash(encoded) do
      {:ok, hash} -> Plug.Crypto.secure_compare(Base.encode64(:crypto.hash(:sha256, body), padding: false), hash)
      :error -> false
    end
  end

  def verify(digest, body) when is_binary(digest) and is_map(body), do: verify(digest, Jason.encode!(body))
  def verify(digest, _body) when is_binary(digest), do: false

  # The Base64 hash without padding, from `<base64>` or the RFC 9530 byte
  # sequence `:<base64>:`, either of which may omit its padding
  # (mpp-rs `verify`, refs/mpp-rs/src/body_digest.rs; mppx `normalize`,
  # refs/mppx/src/BodyDigest.ts).
  defp digest_hash(encoded) do
    hash =
      case encoded do
        <<":", rest::binary>> when byte_size(rest) > 0 ->
          if String.ends_with?(rest, ":"),
            do: rest |> binary_part(0, byte_size(rest) - 1) |> String.trim_trailing("="),
            else: :error

        # A SHA-256 hash has one padding character; the bare form is otherwise literal.
        bare ->
          String.replace_suffix(bare, "=", "")
      end

    if is_binary(hash) and hash != "" and not String.contains?(hash, ":"), do: {:ok, hash}, else: :error
  end
end
