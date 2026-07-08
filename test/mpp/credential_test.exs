defmodule MPP.CredentialTest do
  use ExUnit.Case, async: true

  alias MPP.Challenge
  alias MPP.Credential

  @challenge_params [
    realm: "api.example.com",
    method: "stripe",
    intent: "charge",
    request: "eyJhbW91bnQiOiIxMDAwIiwiY3VycmVuY3kiOiJ1c2QifQ"
  ]

  @secret_key "test-secret-key"

  defp build_credential(opts \\ []) do
    challenge = Challenge.create(@challenge_params, @secret_key)

    %Credential{
      challenge: challenge,
      payload: Keyword.get(opts, :payload, %{"proof" => "0xabc123"}),
      source: Keyword.get(opts, :source)
    }
  end

  describe "encode/1 and decode/1" do
    test "roundtrip preserves all fields including source" do
      credential = build_credential(source: "did:pkh:eip155:1:0x1234567890abcdef")
      encoded = Credential.encode(credential)
      assert {:ok, decoded} = Credential.decode(encoded)

      assert decoded.challenge.id == credential.challenge.id
      assert decoded.challenge.realm == credential.challenge.realm
      assert decoded.challenge.method == credential.challenge.method
      assert decoded.challenge.intent == credential.challenge.intent
      assert decoded.challenge.request == credential.challenge.request
      assert decoded.payload == credential.payload
      assert decoded.source == credential.source
    end

    test "roundtrip without optional fields" do
      credential = build_credential()
      encoded = Credential.encode(credential)
      assert {:ok, decoded} = Credential.decode(encoded)

      assert decoded.challenge.id == credential.challenge.id
      assert decoded.payload == %{"proof" => "0xabc123"}
      assert decoded.source == nil
    end

    test "roundtrip preserves optional challenge fields" do
      challenge =
        Challenge.create(
          @challenge_params ++
            [
              expires: "2026-01-15T12:00:00Z",
              digest: "sha-256=abc123",
              description: "Test resource",
              opaque: "eyJvcmRlcklkIjoiNDIifQ"
            ],
          @secret_key
        )

      credential = %Credential{challenge: challenge, payload: %{"sig" => "0x"}}
      encoded = Credential.encode(credential)
      assert {:ok, decoded} = Credential.decode(encoded)

      assert decoded.challenge.expires == "2026-01-15T12:00:00Z"
      assert decoded.challenge.digest == "sha-256=abc123"
      assert decoded.challenge.description == "Test resource"
      assert decoded.challenge.opaque == "eyJvcmRlcklkIjoiNDIifQ"
    end

    test "encode produces valid base64url string" do
      credential = build_credential()
      encoded = Credential.encode(credential)

      refute String.contains?(encoded, "+")
      refute String.contains?(encoded, "/")
      refute String.contains?(encoded, "=")
    end

    test "challenge request stays as raw base64url through roundtrip" do
      credential = build_credential()
      encoded = Credential.encode(credential)
      assert {:ok, decoded} = Credential.decode(encoded)

      # request must be the exact same base64url string, not decoded
      assert decoded.challenge.request == "eyJhbW91bnQiOiIxMDAwIiwiY3VycmVuY3kiOiJ1c2QifQ"
    end

    test "decoded challenge can be verified with Challenge.verify/2" do
      credential = build_credential()
      encoded = Credential.encode(credential)
      assert {:ok, decoded} = Credential.decode(encoded)

      assert :ok = Challenge.verify(decoded.challenge, @secret_key)
    end
  end

  describe "decode/1 error cases" do
    test "returns error for invalid base64" do
      assert {:error, :invalid_base64} = Credential.decode("not-valid-base64!!!")
    end

    test "returns error for valid base64 but invalid JSON" do
      encoded = Base.url_encode64("not json", padding: false)
      assert {:error, :invalid_json} = Credential.decode(encoded)
    end

    test "returns error for missing challenge key" do
      json = Jason.encode!(%{"payload" => %{"proof" => "0x"}})
      encoded = Base.url_encode64(json, padding: false)
      assert {:error, :missing_required_fields} = Credential.decode(encoded)
    end

    test "returns error for missing payload key" do
      json =
        Jason.encode!(%{
          "challenge" => %{"id" => "abc", "realm" => "r", "method" => "m", "intent" => "i", "request" => "r"}
        })

      encoded = Base.url_encode64(json, padding: false)
      assert {:error, :missing_required_fields} = Credential.decode(encoded)
    end

    test "returns error for non-map challenge" do
      json = Jason.encode!(%{"challenge" => "not-a-map", "payload" => %{"proof" => "0x"}})
      encoded = Base.url_encode64(json, padding: false)
      assert {:error, :missing_required_fields} = Credential.decode(encoded)
    end

    test "returns error for challenge missing required fields" do
      json =
        Jason.encode!(%{
          "challenge" => %{"id" => "abc123"},
          "payload" => %{"proof" => "0x"}
        })

      encoded = Base.url_encode64(json, padding: false)
      assert {:error, :missing_required_fields} = Credential.decode(encoded)
    end

    test "returns error for challenge with non-string required fields" do
      json =
        Jason.encode!(%{
          "challenge" => %{"id" => 123, "realm" => "r", "method" => "m", "intent" => "i", "request" => "r"},
          "payload" => %{"proof" => "0x"}
        })

      encoded = Base.url_encode64(json, padding: false)
      assert {:error, :missing_required_fields} = Credential.decode(encoded)
    end

    test "rejects an echoed challenge with a non-lowercase method (Task 72)" do
      encoded = encode_credential(method: "Stripe")
      assert {:error, :invalid_method} = Credential.decode(encoded)
    end

    test "rejects an echoed challenge with a bad digest (Task 72)" do
      encoded = encode_credential(digest: "sha-512=abc")
      assert {:error, :invalid_digest} = Credential.decode(encoded)
    end

    test "rejects an echoed challenge whose request is not base64url-JSON (Task 72)" do
      encoded = encode_credential(request: Base.url_encode64("not json", padding: false))
      assert {:error, :invalid_request} = Credential.decode(encoded)
    end
  end

  # Builds a base64url credential wrapping an echoed challenge with the given
  # field overrides (defaults are all well-formed).
  defp encode_credential(overrides) do
    challenge =
      Map.merge(
        %{
          "id" => "ch_123",
          "realm" => "api.example.com",
          "method" => "stripe",
          "intent" => "charge",
          "request" => "eyJhbW91bnQiOiIxMDAifQ"
        },
        Map.new(overrides, fn {k, v} -> {Atom.to_string(k), v} end)
      )

    %{"challenge" => challenge, "payload" => %{"proof" => "0x"}}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end
end
