defmodule MPP.McpTest do
  use ExUnit.Case, async: true

  alias MPP.Challenge
  alias MPP.Credential
  alias MPP.Errors
  alias MPP.Mcp
  alias MPP.Receipt

  # Shared test fixtures
  defp sample_challenge do
    %Challenge{
      id: "ch_test_123",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: Base.url_encode64(Jason.encode!(%{"amount" => "1000", "currency" => "usd"}), padding: false),
      expires: "2026-12-31T23:59:59Z",
      description: "API call fee"
    }
  end

  defp sample_credential do
    %Credential{
      challenge: sample_challenge(),
      payload: %{"txHash" => "0xabc123"},
      source: "0x1234567890abcdef"
    }
  end

  defp sample_receipt do
    Receipt.new(
      method: "tempo",
      reference: "0xtx789",
      timestamp: "2026-04-04T12:00:00Z"
    )
  end

  # -------------------------------------------------------------------
  # Constants
  # -------------------------------------------------------------------

  describe "constants" do
    test "payment_required_code is -32042" do
      assert Mcp.payment_required_code() == -32_042
    end

    test "verification_failed_code is -32043" do
      assert Mcp.verification_failed_code() == -32_043
    end

    test "credential_meta_key matches spec" do
      assert Mcp.credential_meta_key() == "org.paymentauth/credential"
    end

    test "receipt_meta_key matches spec" do
      assert Mcp.receipt_meta_key() == "org.paymentauth/receipt"
    end
  end

  # -------------------------------------------------------------------
  # Server Helpers
  # -------------------------------------------------------------------

  describe "payment_required_error/1" do
    test "builds error from single challenge" do
      challenge = sample_challenge()
      error = Mcp.payment_required_error(challenge)

      assert error["code"] == -32_042
      assert error["message"] == "Payment Required"
      assert error["data"]["httpStatus"] == 402
      assert is_nil(error["data"]["problem"])

      [ch] = error["data"]["challenges"]
      assert ch["id"] == "ch_test_123"
      assert ch["realm"] == "api.example.com"
      assert ch["method"] == "tempo"
      assert ch["intent"] == "charge"
      assert ch["expires"] == "2026-12-31T23:59:59Z"
      assert ch["description"] == "API call fee"

      # MCP wire format: request must be a native JSON object, not base64url
      assert is_map(ch["request"])
      assert ch["request"]["amount"] == "1000"
      assert ch["request"]["currency"] == "usd"
    end

    test "builds error from multiple challenges" do
      c1 = sample_challenge()
      c2 = %{c1 | id: "ch_stripe_456", method: "stripe"}

      error = Mcp.payment_required_error([c1, c2])

      assert length(error["data"]["challenges"]) == 2
      assert Enum.map(error["data"]["challenges"], & &1["method"]) == ["tempo", "stripe"]
    end

    test "omits nil optional fields from challenge" do
      challenge = %Challenge{
        id: "ch_minimal",
        realm: "api.example.com",
        method: "tempo",
        intent: "charge",
        request: "eyJ0ZXN0IjoxfQ"
      }

      error = Mcp.payment_required_error(challenge)
      [ch] = error["data"]["challenges"]

      refute Map.has_key?(ch, "expires")
      refute Map.has_key?(ch, "description")
      refute Map.has_key?(ch, "digest")
      refute Map.has_key?(ch, "opaque")
    end
  end

  describe "verification_failed_error/2" do
    test "includes problem details" do
      challenge = sample_challenge()
      problem = Errors.new(:verification_failed, "Invalid transaction hash")

      error = Mcp.verification_failed_error(challenge, problem)

      assert error["code"] == -32_043
      assert error["message"] == "Payment Verification Failed"
      assert error["data"]["httpStatus"] == 402
      assert error["data"]["problem"]["type"] == "https://paymentauth.org/problems/verification-failed"
      assert error["data"]["problem"]["detail"] == "Invalid transaction hash"
      assert length(error["data"]["challenges"]) == 1
    end

    test "accepts list of challenges" do
      challenges = [sample_challenge(), %{sample_challenge() | id: "ch_2", method: "stripe"}]
      problem = Errors.new(:malformed_credential, "Missing payload")

      error = Mcp.verification_failed_error(challenges, problem)

      assert error["data"]["httpStatus"] == 402
      assert length(error["data"]["challenges"]) == 2
    end
  end

  describe "extract_credential/1" do
    test "extracts credential from params._meta" do
      credential = sample_credential()
      params = Mcp.attach_credential(%{"tool" => "test"}, credential)

      assert {:ok, extracted} = Mcp.extract_credential(params)
      assert extracted.challenge.id == "ch_test_123"
      assert extracted.challenge.realm == "api.example.com"
      assert extracted.payload == %{"txHash" => "0xabc123"}
      assert extracted.source == "0x1234567890abcdef"
    end

    test "returns error when _meta is missing" do
      assert {:error, :no_credential} = Mcp.extract_credential(%{"tool" => "test"})
    end

    test "returns error when credential key is missing from _meta" do
      params = %{"_meta" => %{"other_key" => "value"}}
      assert {:error, :no_credential} = Mcp.extract_credential(params)
    end

    test "returns error for malformed credential map" do
      params = %{"_meta" => %{"org.paymentauth/credential" => %{"invalid" => true}}}
      assert {:error, :invalid_credential} = Mcp.extract_credential(params)
    end

    test "returns invalid_credential when credential value is not a map" do
      params = %{"_meta" => %{"org.paymentauth/credential" => "not-a-map"}}
      assert {:error, :invalid_credential} = Mcp.extract_credential(params)
    end

    test "returns error when credential has malformed challenge" do
      params = %{
        "_meta" => %{
          "org.paymentauth/credential" => %{
            "challenge" => %{"not" => "valid"},
            "payload" => %{"txHash" => "0xabc"}
          }
        }
      }

      assert {:error, :invalid_challenge} = Mcp.extract_credential(params)
    end

    test "returns error when credential challenge request contains floats" do
      params = %{
        "_meta" => %{
          "org.paymentauth/credential" => %{
            "challenge" => %{
              "id" => "ch_1",
              "realm" => "api.example.com",
              "method" => "tempo",
              "intent" => "charge",
              "request" => %{"amount" => 1.5}
            },
            "payload" => %{"txHash" => "0xabc"}
          }
        }
      }

      assert {:error, :invalid_challenge} = Mcp.extract_credential(params)
    end

    test "handles credential without optional source field" do
      credential = %{sample_credential() | source: nil}
      params = Mcp.attach_credential(%{}, credential)

      assert {:ok, extracted} = Mcp.extract_credential(params)
      assert is_nil(extracted.source)
      assert extracted.payload == %{"txHash" => "0xabc123"}
    end
  end

  describe "attach_receipt/3" do
    test "attaches receipt with challengeId to result._meta" do
      result = %{"content" => [%{"type" => "text", "text" => "Hello"}]}
      receipt = sample_receipt()

      updated = Mcp.attach_receipt(result, receipt, "ch_test_123")

      mcp_receipt = updated["_meta"]["org.paymentauth/receipt"]
      assert mcp_receipt["status"] == "success"
      assert mcp_receipt["method"] == "tempo"
      assert mcp_receipt["reference"] == "0xtx789"
      assert mcp_receipt["timestamp"] == "2026-04-04T12:00:00Z"
      assert mcp_receipt["challengeId"] == "ch_test_123"
      refute Map.has_key?(mcp_receipt, "externalId")
    end

    test "preserves existing _meta keys" do
      result = %{"_meta" => %{"existing" => "value"}, "data" => 42}
      receipt = sample_receipt()

      updated = Mcp.attach_receipt(result, receipt, "ch_123")

      assert updated["_meta"]["existing"] == "value"
      assert updated["_meta"]["org.paymentauth/receipt"]["method"] == "tempo"
      assert updated["data"] == 42
    end

    test "includes externalId when present on receipt" do
      receipt = %{sample_receipt() | external_id: "ext-001"}

      updated = Mcp.attach_receipt(%{}, receipt, "ch_123")

      assert updated["_meta"]["org.paymentauth/receipt"]["externalId"] == "ext-001"
    end
  end

  # -------------------------------------------------------------------
  # Client Helpers
  # -------------------------------------------------------------------

  describe "payment_required?/1" do
    test "returns true for -32042 error" do
      error = Mcp.payment_required_error(sample_challenge())
      assert Mcp.payment_required?(error)
    end

    test "returns false for -32043 error" do
      error = Mcp.verification_failed_error(sample_challenge(), Errors.new(:verification_failed, "bad"))
      refute Mcp.payment_required?(error)
    end

    test "returns false for other error codes" do
      refute Mcp.payment_required?(%{"code" => -32_600, "message" => "Invalid Request"})
    end

    test "returns false for map without code" do
      refute Mcp.payment_required?(%{"message" => "something"})
    end
  end

  describe "extract_challenges/1" do
    test "parses challenges from error data" do
      challenge = sample_challenge()
      error = Mcp.payment_required_error(challenge)

      assert {:ok, [parsed]} = Mcp.extract_challenges(error)
      assert parsed.id == "ch_test_123"
      assert parsed.realm == "api.example.com"
      assert parsed.method == "tempo"
      assert parsed.intent == "charge"
      assert parsed.request == challenge.request
      assert parsed.expires == "2026-12-31T23:59:59Z"
      assert parsed.description == "API call fee"
    end

    test "parses multiple challenges" do
      c1 = sample_challenge()
      c2 = %{c1 | id: "ch_stripe", method: "stripe"}
      error = Mcp.payment_required_error([c1, c2])

      assert {:ok, parsed} = Mcp.extract_challenges(error)
      assert length(parsed) == 2
      assert Enum.map(parsed, & &1.method) == ["tempo", "stripe"]
    end

    test "encodes a native-object request with list, integer, boolean, and nil values" do
      # Per the MCP transport spec, `request` arrives as a native JSON object; it is
      # re-canonicalized (JCS) and base64url-encoded for internal HMAC use. This
      # exercises every jcs_compatible?/1 value branch (list, integer, boolean, nil).
      error = %{
        "data" => %{
          "challenges" => [
            %{
              "id" => "ch_obj",
              "realm" => "api.example.com",
              "method" => "tempo",
              "intent" => "charge",
              "request" => %{
                "items" => ["a", "b"],
                "count" => 5,
                "active" => true,
                "note" => nil,
                "currency" => "usd"
              }
            }
          ]
        }
      }

      assert {:ok, [parsed]} = Mcp.extract_challenges(error)
      assert is_binary(parsed.request)
    end

    test "accepts a request already encoded as a base64url binary string" do
      error = %{
        "data" => %{
          "challenges" => [
            %{
              "id" => "ch_bin",
              "realm" => "api.example.com",
              "method" => "tempo",
              "intent" => "charge",
              "request" => "eyJ0ZXN0IjoxfQ"
            }
          ]
        }
      }

      assert {:ok, [parsed]} = Mcp.extract_challenges(error)
      assert parsed.request == "eyJ0ZXN0IjoxfQ"
    end

    test "returns error for missing challenges" do
      assert {:error, :no_challenges} = Mcp.extract_challenges(%{"data" => %{}})
    end

    test "returns error for empty challenges list" do
      assert {:error, :no_challenges} = Mcp.extract_challenges(%{"data" => %{"challenges" => []}})
    end

    test "returns error for map without data" do
      assert {:error, :no_challenges} = Mcp.extract_challenges(%{"code" => -32_042})
    end

    test "returns error for malformed challenge objects" do
      error = %{
        "data" => %{
          "challenges" => [%{"not" => "a valid challenge"}]
        }
      }

      assert {:error, :invalid_challenge} = Mcp.extract_challenges(error)
    end

    test "returns error when request is a non-map/non-binary value" do
      error = %{
        "data" => %{
          "challenges" => [
            %{
              "id" => "ch_1",
              "realm" => "api.example.com",
              "method" => "tempo",
              "intent" => "charge",
              "request" => []
            }
          ]
        }
      }

      assert {:error, :invalid_challenge} = Mcp.extract_challenges(error)
    end

    test "returns invalid_challenge when challenges value is not a list" do
      error = %{"data" => %{"challenges" => "not-a-list"}}
      assert {:error, :invalid_challenge} = Mcp.extract_challenges(error)
    end

    test "returns error when request map contains floats" do
      error = %{
        "data" => %{
          "challenges" => [
            %{
              "id" => "ch_1",
              "realm" => "api.example.com",
              "method" => "tempo",
              "intent" => "charge",
              "request" => %{"amount" => 1.5}
            }
          ]
        }
      }

      assert {:error, :invalid_challenge} = Mcp.extract_challenges(error)
    end

    test "returns error when nested request value contains floats" do
      error = %{
        "data" => %{
          "challenges" => [
            %{
              "id" => "ch_1",
              "realm" => "api.example.com",
              "method" => "tempo",
              "intent" => "charge",
              "request" => %{"amount" => "100", "details" => %{"rate" => 0.05}}
            }
          ]
        }
      }

      assert {:error, :invalid_challenge} = Mcp.extract_challenges(error)
    end

    test "returns error when optional field has non-string value" do
      error = %{
        "data" => %{
          "challenges" => [
            %{
              "id" => "ch_1",
              "realm" => "api.example.com",
              "method" => "tempo",
              "intent" => "charge",
              "request" => %{"amount" => "100"},
              "expires" => %{}
            }
          ]
        }
      }

      assert {:error, :invalid_challenge} = Mcp.extract_challenges(error)
    end
  end

  describe "attach_credential/2" do
    test "inserts credential into params._meta" do
      credential = sample_credential()
      params = Mcp.attach_credential(%{"name" => "test_tool"}, credential)

      cred_map = params["_meta"]["org.paymentauth/credential"]
      assert cred_map["challenge"]["id"] == "ch_test_123"
      assert cred_map["payload"] == %{"txHash" => "0xabc123"}
      assert cred_map["source"] == "0x1234567890abcdef"
      assert params["name"] == "test_tool"

      # Echoed challenge request must be native JSON on MCP wire
      assert is_map(cred_map["challenge"]["request"])
    end

    test "preserves existing _meta keys" do
      params = %{"_meta" => %{"progressToken" => "abc"}, "name" => "tool"}
      credential = sample_credential()

      updated = Mcp.attach_credential(params, credential)

      assert updated["_meta"]["progressToken"] == "abc"
      assert updated["_meta"]["org.paymentauth/credential"]["payload"] == %{"txHash" => "0xabc123"}
    end

    test "omits source when nil" do
      credential = %{sample_credential() | source: nil}
      params = Mcp.attach_credential(%{}, credential)

      cred_map = params["_meta"]["org.paymentauth/credential"]
      refute Map.has_key?(cred_map, "source")
    end
  end

  # -------------------------------------------------------------------
  # Round-Trip
  # -------------------------------------------------------------------

  describe "round-trip" do
    test "challenge → error → extract → credential → extract → receipt" do
      challenge = sample_challenge()

      # Server: issue payment-required error
      error = Mcp.payment_required_error(challenge)
      assert Mcp.payment_required?(error)

      # Client: extract challenges from error
      assert {:ok, [parsed_challenge]} = Mcp.extract_challenges(error)
      assert parsed_challenge.id == challenge.id
      assert parsed_challenge.method == challenge.method
      # request survives base64url → native JSON → base64url round-trip
      assert parsed_challenge.request == challenge.request

      # Client: "pay" and attach credential to request
      credential = %Credential{
        challenge: parsed_challenge,
        payload: %{"txHash" => "0xdeadbeef"},
        source: "0xclient"
      }

      params = Mcp.attach_credential(%{"name" => "api_call"}, credential)

      # Server: extract credential from request
      assert {:ok, extracted} = Mcp.extract_credential(params)
      assert extracted.challenge.id == challenge.id
      assert extracted.payload == %{"txHash" => "0xdeadbeef"}

      # Server: verify and attach receipt to result
      receipt = Receipt.new(method: "tempo", reference: "0xtx_final", timestamp: "2026-04-04T12:00:00Z")
      result = Mcp.attach_receipt(%{"content" => "resource_data"}, receipt, challenge.id)

      mcp_receipt = result["_meta"]["org.paymentauth/receipt"]
      assert mcp_receipt["status"] == "success"
      assert mcp_receipt["method"] == "tempo"
      assert mcp_receipt["challengeId"] == challenge.id
      assert result["content"] == "resource_data"
    end
  end
end
