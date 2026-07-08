defmodule MPP.ChallengeTest do
  use ExUnit.Case, async: true

  alias MPP.Challenge

  @secret_key "test-secret-key-for-hmac"
  @base_params [
    realm: "api.example.com",
    method: "stripe",
    intent: "charge",
    request: "eyJhbW91bnQiOiIxMDAwIiwiY3VycmVuY3kiOiJ1c2QifQ"
  ]

  describe "create/2" do
    test "creates challenge with computed HMAC ID" do
      challenge = Challenge.create(@base_params, @secret_key)

      assert challenge.id
      assert is_binary(challenge.id)
      assert challenge.realm == "api.example.com"
      assert challenge.method == "stripe"
      assert challenge.intent == "charge"
      assert challenge.request == "eyJhbW91bnQiOiIxMDAwIiwiY3VycmVuY3kiOiJ1c2QifQ"
    end

    test "ID is deterministic — same inputs produce same ID" do
      challenge1 = Challenge.create(@base_params, @secret_key)
      challenge2 = Challenge.create(@base_params, @secret_key)

      assert challenge1.id == challenge2.id
    end

    test "different secret keys produce different IDs" do
      challenge1 = Challenge.create(@base_params, "key-one")
      challenge2 = Challenge.create(@base_params, "key-two")

      refute challenge1.id == challenge2.id
    end

    test "accepts optional fields" do
      params =
        @base_params ++
          [
            description: "Pay for API call",
            digest: "sha-256=abc123",
            expires: "2026-12-31T23:59:59Z",
            opaque: "eyJzZXNzaW9uIjoiYWJjIn0"
          ]

      challenge = Challenge.create(params, @secret_key)

      assert challenge.description == "Pay for API call"
      assert challenge.digest == "sha-256=abc123"
      assert challenge.expires == "2026-12-31T23:59:59Z"
      assert challenge.opaque == "eyJzZXNzaW9uIjoiYWJjIn0"
    end

    test "optional fields affect the HMAC ID" do
      without_expires = Challenge.create(@base_params, @secret_key)
      with_expires = Challenge.create(@base_params ++ [expires: "2026-12-31T23:59:59Z"], @secret_key)

      refute without_expires.id == with_expires.id
    end

    test "ID is valid base64url without padding" do
      challenge = Challenge.create(@base_params, @secret_key)

      refute String.contains?(challenge.id, "+")
      refute String.contains?(challenge.id, "/")
      refute String.contains?(challenge.id, "=")
    end

    test "overwrites any provided id" do
      params = @base_params ++ [id: "should-be-overwritten"]
      challenge = Challenge.create(params, @secret_key)

      refute challenge.id == "should-be-overwritten"
    end

    test "raises on missing required fields" do
      assert_raise ArgumentError, fn -> Challenge.create([realm: "r"], @secret_key) end
    end
  end

  describe "verify/2" do
    test "returns :ok for valid challenge" do
      challenge = Challenge.create(@base_params, @secret_key)

      assert :ok = Challenge.verify(challenge, @secret_key)
    end

    test "returns error for tampered realm" do
      challenge = Challenge.create(@base_params, @secret_key)
      tampered = %{challenge | realm: "evil.example.com"}

      assert {:error, :invalid_challenge} = Challenge.verify(tampered, @secret_key)
    end

    test "returns error for tampered method" do
      challenge = Challenge.create(@base_params, @secret_key)
      tampered = %{challenge | method: "tempo"}

      assert {:error, :invalid_challenge} = Challenge.verify(tampered, @secret_key)
    end

    test "returns error for tampered request" do
      challenge = Challenge.create(@base_params, @secret_key)
      tampered = %{challenge | request: "dGFtcGVyZWQ"}

      assert {:error, :invalid_challenge} = Challenge.verify(tampered, @secret_key)
    end

    test "returns error for tampered ID" do
      challenge = Challenge.create(@base_params, @secret_key)
      tampered = %{challenge | id: "dGFtcGVyZWQtaWQ"}

      assert {:error, :invalid_challenge} = Challenge.verify(tampered, @secret_key)
    end

    test "returns error for wrong secret key" do
      challenge = Challenge.create(@base_params, @secret_key)

      assert {:error, :invalid_challenge} = Challenge.verify(challenge, "wrong-key")
    end

    test "returns error for nil ID" do
      challenge = Challenge.create(@base_params, @secret_key)
      no_id = %{challenge | id: nil}

      assert {:error, :invalid_challenge} = Challenge.verify(no_id, @secret_key)
    end

    test "verify works with all optional fields set" do
      params =
        @base_params ++
          [
            description: "Pay here",
            digest: "sha-256=xyz",
            expires: "2026-06-01T00:00:00Z",
            opaque: "eyJrZXkiOiJ2YWx1ZSJ9"
          ]

      challenge = Challenge.create(params, @secret_key)
      assert :ok = Challenge.verify(challenge, @secret_key)
    end

    test "tampered optional field fails verification" do
      params = @base_params ++ [expires: "2026-06-01T00:00:00Z"]
      challenge = Challenge.create(params, @secret_key)
      tampered = %{challenge | expires: "2099-01-01T00:00:00Z"}

      assert {:error, :invalid_challenge} = Challenge.verify(tampered, @secret_key)
    end
  end

  describe "verify_server_binding/3" do
    test "passes when echoed realm is tampered but server realm matches HMAC input" do
      challenge = Challenge.create(@base_params, @secret_key)
      tampered = %{challenge | realm: "evil.example.com"}

      assert :ok = Challenge.verify_server_binding(tampered, @secret_key, "api.example.com")
    end

    test "fails when server realm does not match HMAC binding" do
      challenge = Challenge.create(@base_params, @secret_key)

      assert {:error, :invalid_challenge} =
               Challenge.verify_server_binding(challenge, @secret_key, "other.example.com")
    end
  end

  describe "validate_fields/1 (parse-time field shapes, Task 72)" do
    defp valid_challenge, do: Challenge.create(@base_params, @secret_key)

    test "accepts a well-formed challenge" do
      assert :ok = Challenge.validate_fields(valid_challenge())
    end

    test "accepts an optional sha-256 digest" do
      challenge = %{valid_challenge() | digest: "sha-256=abc123"}
      assert :ok = Challenge.validate_fields(challenge)
    end

    test "rejects empty id" do
      assert {:error, :empty_id} = Challenge.validate_fields(%{valid_challenge() | id: ""})
    end

    test "rejects nil id" do
      assert {:error, :empty_id} = Challenge.validate_fields(%{valid_challenge() | id: nil})
    end

    test "rejects empty method" do
      assert {:error, :invalid_method} = Challenge.validate_fields(%{valid_challenge() | method: ""})
    end

    test "rejects uppercase method (spec 1*LOWERALPHA)" do
      assert {:error, :invalid_method} = Challenge.validate_fields(%{valid_challenge() | method: "Stripe"})
    end

    test "rejects method with a digit" do
      assert {:error, :invalid_method} = Challenge.validate_fields(%{valid_challenge() | method: "x402"})
    end

    test "rejects method with a dash" do
      assert {:error, :invalid_method} = Challenge.validate_fields(%{valid_challenge() | method: "tempo-v2"})
    end

    test "rejects method with an underscore" do
      assert {:error, :invalid_method} = Challenge.validate_fields(%{valid_challenge() | method: "mock_b"})
    end

    test "rejects request that is not base64url" do
      assert {:error, :invalid_request} = Challenge.validate_fields(%{valid_challenge() | request: "@@not-base64@@"})
    end

    test "rejects request that decodes to non-JSON" do
      request = Base.url_encode64("not json at all", padding: false)
      assert {:error, :invalid_request} = Challenge.validate_fields(%{valid_challenge() | request: request})
    end

    test "rejects request whose JSON is not an object" do
      request = Base.url_encode64(Jason.encode!([1, 2, 3]), padding: false)
      assert {:error, :invalid_request} = Challenge.validate_fields(%{valid_challenge() | request: request})
    end

    test "rejects a non-sha-256 digest" do
      assert {:error, :invalid_digest} = Challenge.validate_fields(%{valid_challenge() | digest: "sha-512=abc"})
    end

    test "rejects a non-binary method (defensive)" do
      assert {:error, :invalid_method} = Challenge.validate_fields(%{valid_challenge() | method: 123})
    end

    test "rejects a non-binary request (defensive)" do
      assert {:error, :invalid_request} = Challenge.validate_fields(%{valid_challenge() | request: 123})
    end
  end

  describe "verify_server_binding/3 nil id" do
    test "rejects a challenge with a nil id" do
      challenge = %{Challenge.create(@base_params, @secret_key) | id: nil}

      assert {:error, :invalid_challenge} =
               Challenge.verify_server_binding(challenge, @secret_key, "api.example.com")
    end
  end
end
