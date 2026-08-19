defmodule MPP.McpTest do
  use ExUnit.Case, async: true

  alias MPP.Challenge
  alias MPP.Credential
  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.JCS
  alias MPP.Mcp
  alias MPP.Receipt
  alias MPP.Tempo.ConCacheStore

  defmodule MockMethod do
    @moduledoc false
    use MPP.Method

    @impl MPP.Method
    def method_name, do: "mock"

    @impl MPP.Method
    def verify(%{"proof" => "valid"}, _charge) do
      {:ok, Receipt.new(method: method_name(), reference: "ref_mcp", timestamp: "2026-04-04T12:00:00Z")}
    end

    @impl MPP.Method
    def verify(%{"proof" => "invalid"}, _charge) do
      {:error, Errors.new(:verification_failed, "Invalid proof")}
    end

    @impl MPP.Method
    def verify(%{"proof" => "required"}, _charge) do
      {:error, Errors.new(:payment_required, "Payment still required")}
    end

    @impl MPP.Method
    def verify(%{"proof" => "malformed"}, _charge) do
      {:error, Errors.new(:malformed_credential, "Malformed proof")}
    end

    @impl MPP.Method
    def verify(%{"proof" => "capacity"}, _charge) do
      error =
        :sponsor_capacity_exhausted
        |> Errors.new("Sponsor capacity is temporarily unavailable")
        |> Errors.put_retry_after(23)

      {:error, error}
    end

    @impl MPP.Method
    def verify(_payload, _charge) do
      {:error, Errors.new(:invalid_payload, "Missing proof field")}
    end
  end

  # Shared test fixtures
  @secret_key "test-secret-key-for-mcp"
  @realm "api.example.com"

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

  defp sample_json_rpc_request do
    %{
      "jsonrpc" => "2.0",
      "id" => "req-1",
      "method" => "tools/call",
      "params" => %{
        "name" => "premium_lookup",
        "arguments" => %{"query" => "alpha"}
      }
    }
  end

  defp sample_receipt do
    Receipt.new(
      method: "tempo",
      reference: "0xtx789",
      timestamp: "2026-04-04T12:00:00Z"
    )
  end

  defp server_config(overrides \\ []) do
    [
      secret_key: @secret_key,
      realm: @realm,
      method: MockMethod,
      amount: "1000",
      currency: "usd",
      store: false
    ]
    |> Keyword.merge(overrides)
    |> Mcp.init()
  end

  # Fresh, uniquely-named ConCache replay store per test (async isolation).
  defp start_replay_store! do
    cache_name = :"mcp_replay_#{System.unique_integer([:positive])}"
    start_supervised!({ConCacheStore, name: cache_name})
    {ConCacheStore, name: cache_name}
  end

  defp json_rpc_request_with_credential(payload \\ %{"proof" => "valid"}) do
    request = sample_json_rpc_request()
    challenge = mock_challenge()
    credential = %Credential{challenge: challenge, payload: payload}

    Map.update!(request, "params", &Mcp.attach_credential(&1, credential))
  end

  defp mock_challenge do
    mock_challenge(method: "mock")
  end

  defp mock_challenge(opts) do
    charge = mock_charge()

    Challenge.create(
      [
        realm: @realm,
        method: Keyword.fetch!(opts, :method),
        intent: "charge",
        request: encode_request(charge),
        expires: future_expires()
      ],
      @secret_key
    )
  end

  defp mock_charge do
    {:ok, charge} = Charge.new(amount: "1000", currency: "usd")
    charge
  end

  defp encode_request(charge) do
    charge
    |> Charge.to_request()
    |> JCS.canonicalize()
    |> Base.url_encode64(padding: false)
  end

  defp future_expires do
    DateTime.utc_now()
    |> DateTime.shift(minute: 5)
    |> DateTime.to_iso8601()
  end

  defp read_mppx_transport_source! do
    [
      "refs/mppx/src/server/Transport.ts",
      "refs/mppx/src/mcp/server/Transport.ts",
      "node_modules/mppx/src/server/Transport.ts"
    ]
    |> Enum.find(&File.exists?/1)
    |> case do
      nil ->
        flunk("""
        Missing mppx reference source for MCP cross-validation.

        Expected one of:
          refs/mppx/src/server/Transport.ts
          refs/mppx/src/mcp/server/Transport.ts
          node_modules/mppx/src/server/Transport.ts
        """)

      path ->
        File.read!(path)
    end
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

    test "payment_required_meta_key matches spec" do
      assert Mcp.payment_required_meta_key() == "org.paymentauth/payment-required"
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

      assert [_, _] = error["data"]["challenges"]
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
      assert [_] = error["data"]["challenges"]
    end

    test "accepts list of challenges" do
      challenges = [sample_challenge(), %{sample_challenge() | id: "ch_2", method: "stripe"}]
      problem = Errors.new(:malformed_credential, "Missing payload")

      error = Mcp.verification_failed_error(challenges, problem)

      assert error["data"]["httpStatus"] == 402
      assert [_, _] = error["data"]["challenges"]
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

    test "includes subscriptionId and extension fields when present on receipt" do
      receipt = %{
        sample_receipt()
        | subscription_id: "sub_123",
          extensions: %{"originTxHash" => "0xdef456"}
      }

      updated = Mcp.attach_receipt(%{}, receipt, "ch_123")
      mcp_receipt = updated["_meta"]["org.paymentauth/receipt"]

      assert mcp_receipt["subscriptionId"] == "sub_123"
      assert mcp_receipt["originTxHash"] == "0xdef456"
      assert mcp_receipt["challengeId"] == "ch_123"
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

    test "returns true for payment-required result metadata" do
      result = %{
        "result" => %{
          "_meta" => %{
            "org.paymentauth/payment-required" => %{
              "challenges" => [
                sample_challenge() |> Mcp.payment_required_error() |> get_in(["data", "challenges"]) |> hd()
              ]
            }
          }
        }
      }

      assert Mcp.payment_required?(result)
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

    test "returns false for malformed payment-required result metadata" do
      result = %{"result" => %{"_meta" => %{"org.paymentauth/payment-required" => %{"challenges" => []}}}}

      refute Mcp.payment_required?(result)
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

    test "parses challenges from payment-required result metadata" do
      challenge = sample_challenge()
      error = Mcp.payment_required_error(challenge)

      response = %{
        "result" => %{
          "_meta" => %{
            "org.paymentauth/payment-required" => %{
              "challenges" => error["data"]["challenges"]
            }
          }
        }
      }

      assert {:ok, [parsed]} = Mcp.extract_challenges(response)
      assert parsed.id == challenge.id
      assert parsed.request == challenge.request
    end

    test "parses multiple challenges" do
      c1 = sample_challenge()
      c2 = %{c1 | id: "ch_stripe", method: "stripe"}
      error = Mcp.payment_required_error([c1, c2])

      assert {:ok, parsed} = Mcp.extract_challenges(error)
      assert [_, _] = parsed
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

    test "returns error when a native request map has non-string keys" do
      # `JCS.canonicalize/1` raises on non-string keys (RFC 8785 contract), so
      # the JCS pre-check must reject them gracefully instead of leaking the raise.
      error = %{
        "data" => %{
          "challenges" => [
            %{
              "id" => "ch_1",
              "realm" => "api.example.com",
              "method" => "tempo",
              "intent" => "charge",
              "request" => %{amount: "100"}
            }
          ]
        }
      }

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

  describe "server-side MCP transport adapter" do
    test "returns mppx-shaped payment-required JSON-RPC error when credential is missing" do
      response =
        Mcp.call(sample_json_rpc_request(), server_config(), fn _request ->
          flunk("handler must not run without a credential")
        end)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == "req-1"
      assert response["error"]["code"] == -32_042
      assert response["error"]["message"] == "Payment Required"

      data = response["error"]["data"]
      assert data["httpStatus"] == 402
      assert data["problem"]["type"] == "https://paymentauth.org/problems/payment-required"
      assert data["problem"]["title"] == "Payment Required"
      assert data["problem"]["detail"] == "No payment credential provided"

      [challenge] = data["challenges"]
      assert challenge["realm"] == @realm
      assert challenge["method"] == "mock"
      assert challenge["intent"] == "charge"
      assert challenge["request"] == %{"amount" => "1000", "currency" => "usd"}
      assert is_binary(challenge["expires"])
    end

    test "rejects a replayed credential — store-backed replay parity with MPP.Plug" do
      config = server_config(store: start_replay_store!())
      request = json_rpc_request_with_credential()

      first =
        Mcp.call(request, config, fn req ->
          %{"jsonrpc" => "2.0", "id" => req["id"], "result" => %{"content" => []}}
        end)

      assert first["result"]["_meta"]["org.paymentauth/receipt"],
             "first call must verify and attach a receipt"

      second =
        Mcp.call(request, config, fn _req ->
          flunk("handler must not run when the credential is replayed")
        end)

      assert second["error"]["code"] == -32_043
      assert second["error"]["data"]["problem"]["detail"] == "Payment credential already used"
    end

    test "emits verify start/fail telemetry when a replayed credential is rejected — parity with MPP.Plug" do
      config = server_config(store: start_replay_store!())
      request = json_rpc_request_with_credential()
      challenge_id = get_in(request, ["params", "_meta", "org.paymentauth/credential", "challenge", "id"])

      handler_id = {:mcp_replay_telemetry, make_ref()}
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:mpp, :verify, :fail],
        fn event, _measurements, metadata, _config -> send(test_pid, {:telemetry, event, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      first =
        Mcp.call(request, config, fn req ->
          %{"jsonrpc" => "2.0", "id" => req["id"], "result" => %{"content" => []}}
        end)

      assert first["result"], "first call must verify"

      second = Mcp.call(request, config, fn _req -> flunk("handler must not run when the credential is replayed") end)
      assert second["error"]["data"]["problem"]["detail"] == "Payment credential already used"

      assert_receive {:telemetry, [:mpp, :verify, :fail], %{challenge_id: ^challenge_id} = metadata}
      assert metadata.error_type == "https://paymentauth.org/problems/verification-failed"
    end

    test "treats non-map JSON-RPC params as carrying no credential" do
      # JSON-RPC params may legally be an array or an explicit null.
      for params <- [[1, 2], nil, "positional"] do
        request = Map.put(sample_json_rpc_request(), "params", params)

        response =
          Mcp.call(request, server_config(), fn _request ->
            flunk("handler must not run without a credential (params: #{inspect(params)})")
          end)

        assert response["error"]["code"] == -32_042
        assert [_challenge] = response["error"]["data"]["challenges"]
      end
    end

    test "rejects a credential whose payload the JCS subset cannot canonicalize instead of crashing" do
      config = server_config(store: start_replay_store!())
      request = json_rpc_request_with_credential(%{"proof" => "valid", "x" => 1.5})

      response = Mcp.call(request, config, fn _request -> flunk("handler must not run") end)

      assert response["error"]["code"] == -32_602
      assert response["error"]["data"]["problem"]["type"] == "https://paymentauth.org/problems/malformed-credential"
    end

    test "client helpers accept the full JSON-RPC error envelope emitted by call/3" do
      response =
        Mcp.call(sample_json_rpc_request(), server_config(), fn _request ->
          flunk("handler must not run without a credential")
        end)

      assert Mcp.payment_required?(response)
      assert {:ok, [challenge]} = Mcp.extract_challenges(response)
      assert challenge.realm == @realm

      refute Mcp.payment_required?(%{"jsonrpc" => "2.0", "id" => 1, "error" => %{"code" => -32_000}})
      assert {:error, :no_challenges} = Mcp.extract_challenges(%{"jsonrpc" => "2.0", "error" => %{"code" => -32_000}})
    end

    test "returns invalid params error when credential metadata is malformed" do
      request =
        Map.update!(sample_json_rpc_request(), "params", fn params ->
          Map.put(params, "_meta", %{"org.paymentauth/credential" => %{"not" => "a credential"}})
        end)

      response =
        Mcp.call(request, server_config(), fn _request ->
          flunk("handler must not run with malformed credential metadata")
        end)

      assert response["error"]["code"] == -32_602
      assert response["error"]["message"] == "Malformed Credential"
      assert response["error"]["data"]["problem"]["type"] == "https://paymentauth.org/problems/malformed-credential"
      assert [_challenge] = response["error"]["data"]["challenges"]
    end

    test "verifies credential then attaches receipt to successful JSON-RPC result metadata" do
      request = json_rpc_request_with_credential()

      response =
        Mcp.call(request, server_config(), fn verified_request ->
          assert get_in(verified_request, ["params", "_meta", "org.paymentauth/credential"])

          %{
            "jsonrpc" => "2.0",
            "id" => verified_request["id"],
            "result" => %{
              "content" => [%{"type" => "text", "text" => "premium data"}],
              "_meta" => %{"existing" => "kept"}
            }
          }
        end)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == "req-1"
      assert response["result"]["content"] == [%{"type" => "text", "text" => "premium data"}]
      assert response["result"]["_meta"]["existing"] == "kept"

      receipt = response["result"]["_meta"]["org.paymentauth/receipt"]
      assert receipt["status"] == "success"
      assert receipt["method"] == "mock"
      assert receipt["reference"] == "ref_mcp"
      assert receipt["timestamp"] == "2026-04-04T12:00:00Z"

      assert receipt["challengeId"] ==
               get_in(request, ["params", "_meta", "org.paymentauth/credential", "challenge", "id"])
    end

    test "does not attach a receipt when verified handler returns a JSON-RPC error" do
      response =
        Mcp.call(json_rpc_request_with_credential(), server_config(), fn request ->
          %{
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "error" => %{"code" => -32_000, "message" => "handler failed"}
          }
        end)

      assert response["error"]["message"] == "handler failed"
      refute Map.has_key?(response, "result")
    end

    test "returns verification failure error when credential proof is rejected" do
      response =
        %{"proof" => "invalid"}
        |> json_rpc_request_with_credential()
        |> Mcp.call(server_config(), fn _request ->
          flunk("handler must not run when verifier rejects the credential")
        end)

      assert response["error"]["code"] == -32_043
      assert response["error"]["message"] == "Verification Failed"
      assert response["error"]["data"]["httpStatus"] == 402
      assert response["error"]["data"]["problem"]["detail"] == "Invalid proof"
      assert [_challenge] = response["error"]["data"]["challenges"]
    end

    test "returns verification failure error when credential method is unsupported" do
      request = sample_json_rpc_request()
      credential = %Credential{challenge: mock_challenge(method: "other"), payload: %{"proof" => "valid"}}
      request = Map.update!(request, "params", &Mcp.attach_credential(&1, credential))

      response =
        Mcp.call(request, server_config(), fn _request ->
          flunk("handler must not run when credential method is unsupported")
        end)

      assert response["error"]["code"] == -32_043
      assert response["error"]["message"] == "Method Unsupported"
      assert response["error"]["data"]["problem"]["detail"] == "Unknown payment method: other"
    end

    test "maps verifier payment-required and malformed-credential errors to mppx JSON-RPC codes" do
      payment_required =
        %{"proof" => "required"}
        |> json_rpc_request_with_credential()
        |> Mcp.call(server_config(), fn _request -> flunk("handler must not run") end)

      malformed =
        %{"proof" => "malformed"}
        |> json_rpc_request_with_credential()
        |> Mcp.call(server_config(), fn _request -> flunk("handler must not run") end)

      assert payment_required["error"]["code"] == -32_042
      assert payment_required["error"]["message"] == "Payment Required"
      assert malformed["error"]["code"] == -32_602
      assert malformed["error"]["message"] == "Malformed Credential"
    end

    test "maps sponsor capacity to payment-required with retry timing" do
      response =
        %{"proof" => "capacity"}
        |> json_rpc_request_with_credential()
        |> Mcp.call(server_config(), fn _request -> flunk("handler must not run") end)

      assert response["error"]["code"] == -32_042
      assert response["error"]["data"]["httpStatus"] == 402
      assert response["error"]["data"]["retryAfter"] == 23

      problem = response["error"]["data"]["problem"]
      assert problem["type"] == "https://zenhive.github.io/mpp/problems/sponsor-capacity-exhausted"
      refute Map.has_key?(problem, "retryAfter")
    end

    test "normalizes handler result maps and tagged tuples before attaching receipt" do
      bare_result =
        Mcp.call(json_rpc_request_with_credential(), server_config(), fn _request -> %{"content" => []} end)

      ok_tuple =
        Mcp.call(json_rpc_request_with_credential(), server_config(), fn _request ->
          {:ok, %{"result" => %{"content" => []}}}
        end)

      error_tuple =
        Mcp.call(json_rpc_request_with_credential(), server_config(), fn _request ->
          {:error, %{"error" => %{"code" => -32_000}}}
        end)

      assert bare_result["jsonrpc"] == "2.0"
      assert bare_result["result"]["_meta"]["org.paymentauth/receipt"]["reference"] == "ref_mcp"
      assert ok_tuple["jsonrpc"] == "2.0"
      assert ok_tuple["id"] == "req-1"
      assert ok_tuple["result"]["_meta"]["org.paymentauth/receipt"]["reference"] == "ref_mcp"
      assert error_tuple["jsonrpc"] == "2.0"
      assert error_tuple["id"] == "req-1"
      assert error_tuple["error"]["code"] == -32_000
      refute Map.has_key?(error_tuple, "result")
    end

    test "rejects malformed challenge fields from MCP metadata without raising" do
      assert {:error, :invalid_challenge} =
               Mcp.extract_challenges(%{
                 "_meta" => %{
                   "org.paymentauth/payment-required" => %{
                     "challenges" => [
                       %{
                         "id" => "",
                         "realm" => "api.example.com",
                         "method" => "mock",
                         "intent" => "charge",
                         "request" => %{"amount" => "1000", "currency" => "usd"}
                       }
                     ]
                   }
                 }
               })

      assert {:error, :invalid_challenge} =
               Mcp.extract_challenges(%{
                 "_meta" => %{"org.paymentauth/payment-required" => %{"challenges" => "bad"}}
               })

      assert {:error, :no_challenges} =
               Mcp.extract_challenges(%{
                 "_meta" => %{"org.paymentauth/payment-required" => %{}}
               })
    end

    @tag :cross_validation
    test "raw JSON-RPC envelope matches mppx server transport contract" do
      # Contract source: refs/mppx/src/server/Transport.ts `mcp()`.
      # The fixture asserts the same top-level envelope, error code field,
      # data.challenge placement, and result._meta receipt placement.
      source = read_mppx_transport_source!()

      assert source =~ "export function mcp()"
      assert source =~ "jsonrpc: '2.0'"
      assert source =~ "id: input.id"
      assert source =~ "code: mcpErrorCode(error)"
      assert source =~ "challenges: [challenge]"
      assert source =~ "[core_Mcp.receiptMetaKey]: mcpReceipt"

      error_response =
        Mcp.call(sample_json_rpc_request(), server_config(), fn _request ->
          flunk("handler must not run without payment")
        end)

      assert %{
               "jsonrpc" => "2.0",
               "id" => "req-1",
               "error" => %{
                 "code" => -32_042,
                 "data" => %{
                   "httpStatus" => 402,
                   "challenges" => [_],
                   "problem" => %{"type" => "https://paymentauth.org/problems/payment-required"}
                 }
               }
             } = error_response

      receipt_response =
        Mcp.call(json_rpc_request_with_credential(), server_config(), fn request ->
          %{"jsonrpc" => "2.0", "id" => request["id"], "result" => %{"content" => []}}
        end)

      assert %{
               "jsonrpc" => "2.0",
               "id" => "req-1",
               "result" => %{
                 "_meta" => %{
                   "org.paymentauth/receipt" => %{
                     "status" => "success",
                     "method" => "mock",
                     "reference" => "ref_mcp",
                     "challengeId" => _
                   }
                 }
               }
             } = receipt_response
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
