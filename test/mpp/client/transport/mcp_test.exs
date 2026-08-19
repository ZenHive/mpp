defmodule MPP.Client.Transport.MCPTest do
  use ExUnit.Case, async: true

  alias MPP.Challenge
  alias MPP.Client.Transport.MCP
  alias MPP.Credential
  alias MPP.Mcp

  @secret_key "test-secret-key"
  @request "eyJhbW91bnQiOiIxMDAwIiwiY3VycmVuY3kiOiJ1c2QifQ"

  defp make_challenge(method \\ "tempo") do
    Challenge.create(
      [realm: "api.example.com", method: method, intent: "charge", request: @request],
      @secret_key
    )
  end

  defp payment_error(challenges) do
    Mcp.payment_required_error(List.wrap(challenges))
  end

  defp envelope(error_or_result, kind \\ :error) do
    base = %{"jsonrpc" => "2.0", "id" => "req-1"}

    case kind do
      :error -> Map.put(base, "error", error_or_result)
      :result -> Map.put(base, "result", error_or_result)
    end
  end

  describe "payment_required?/1" do
    test "true for a -32042 error object" do
      assert MCP.payment_required?(payment_error(make_challenge()))
    end

    test "true for a full JSON-RPC error envelope" do
      assert MCP.payment_required?(envelope(payment_error(make_challenge())))
    end

    test "true for payment-required result metadata" do
      challenge = make_challenge()
      [wire] = payment_error(challenge)["data"]["challenges"]

      response =
        envelope(
          %{"_meta" => %{Mcp.payment_required_meta_key() => %{"challenges" => [wire]}}},
          :result
        )

      assert MCP.payment_required?(response)
    end

    test "false for verification-failed, success, and malformed envelopes" do
      refute MCP.payment_required?(
               Mcp.verification_failed_error(make_challenge(), MPP.Errors.new(:verification_failed, "bad"))
             )

      refute MCP.payment_required?(envelope(%{"content" => []}, :result))
      refute MCP.payment_required?(%{"jsonrpc" => "2.0", "id" => 1})
      refute MCP.payment_required?(%{})
      refute MCP.payment_required?("not-a-map")
      refute MCP.payment_required?(nil)
      refute MCP.payment_required?([])
    end
  end

  describe "get_challenges/1" do
    test "parses challenges from a bare error and a full envelope" do
      challenge = make_challenge()
      error = payment_error(challenge)

      assert {:ok, [parsed]} = MCP.get_challenges(error)
      assert parsed.id == challenge.id
      assert parsed.method == "tempo"

      assert {:ok, [from_envelope]} = MCP.get_challenges(envelope(error))
      assert from_envelope.id == challenge.id
    end

    test "parses challenges from payment-required result metadata" do
      challenge = make_challenge("stripe")
      [wire] = payment_error(challenge)["data"]["challenges"]

      response =
        envelope(
          %{"_meta" => %{Mcp.payment_required_meta_key() => %{"challenges" => [wire]}}},
          :result
        )

      assert {:ok, [parsed]} = MCP.get_challenges(response)
      assert parsed.method == "stripe"
    end

    test "returns :no_challenges for a valid envelope with no challenge list" do
      assert {:error, :no_challenges} =
               MCP.get_challenges(%{"jsonrpc" => "2.0", "id" => 1, "error" => %{"code" => Mcp.payment_required_code()}})

      assert {:error, :no_challenges} =
               MCP.get_challenges(%{"code" => Mcp.payment_required_code(), "data" => %{"challenges" => []}})

      assert {:error, :no_challenges} = MCP.get_challenges(%{})
      assert {:error, :no_challenges} = MCP.get_challenges(%{"jsonrpc" => "2.0", "id" => 1})
    end

    test "returns :invalid_challenge for a well-shaped envelope with a bad challenge object" do
      error = %{
        "code" => Mcp.payment_required_code(),
        "data" => %{"challenges" => [%{"not" => "a challenge"}]}
      }

      assert {:error, :invalid_challenge} = MCP.get_challenges(error)
      assert {:error, :invalid_challenge} = MCP.get_challenges(envelope(error))
    end

    test "returns :malformed_envelope for non-map JSON-RPC values" do
      for garbage <- ["not-json", 42, nil, []] do
        assert {:error, :malformed_envelope} = MCP.get_challenges(garbage),
               "expected malformed_envelope for #{inspect(garbage)}"
      end
    end
  end

  describe "set_credential/2" do
    test "attaches the credential under params._meta on a JSON-RPC request" do
      challenge = make_challenge()
      credential = %Credential{challenge: challenge, payload: %{"type" => "hash"}, source: nil}

      request = %{
        "jsonrpc" => "2.0",
        "id" => "req-1",
        "method" => "tools/call",
        "params" => %{"name" => "premium", "arguments" => %{"q" => "a"}}
      }

      updated = MCP.set_credential(request, credential)
      meta = get_in(updated, ["params", "_meta"])

      assert meta[Mcp.credential_meta_key()]["challenge"]["id"] == challenge.id
      assert updated["params"]["name"] == "premium"
      assert updated["params"]["arguments"] == %{"q" => "a"}
      assert {:ok, parsed} = Mcp.extract_credential(updated["params"])
      assert parsed.challenge.id == challenge.id
    end

    test "preserves existing _meta keys and replaces a missing or non-map params" do
      challenge = make_challenge()
      credential = %Credential{challenge: challenge, payload: %{"token" => "demo-token"}, source: nil}

      with_meta = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "params" => %{"_meta" => %{"keep" => true}, "name" => "paid"}
      }

      updated = MCP.set_credential(with_meta, credential)
      assert updated["params"]["_meta"]["keep"] == true
      assert updated["params"]["_meta"][Mcp.credential_meta_key()]

      for params <- [nil, [1, 2], "positional"] do
        request = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/call", "params" => params}
        attached = MCP.set_credential(request, credential)
        assert {:ok, _} = Mcp.extract_credential(attached["params"])
      end
    end

    test "attaches at the top-level _meta of an MCP tool-params map" do
      challenge = make_challenge()
      credential = %Credential{challenge: challenge, payload: %{"spt" => "spt_test"}, source: nil}
      params = %{"name" => "premium", "arguments" => %{}}

      updated = MCP.set_credential(params, credential)

      assert updated["name"] == "premium"
      refute Map.has_key?(updated, "params")
      assert {:ok, parsed} = Mcp.extract_credential(updated)
      assert parsed.payload == %{"spt" => "spt_test"}
    end

    test "treats params-only and method-only maps as JSON-RPC request envelopes" do
      challenge = make_challenge()
      credential = %Credential{challenge: challenge, payload: %{"type" => "hash"}, source: nil}

      with_params = MCP.set_credential(%{"params" => %{"name" => "paid"}}, credential)
      assert {:ok, _} = Mcp.extract_credential(with_params["params"])
      assert with_params["params"]["name"] == "paid"

      with_method = MCP.set_credential(%{"method" => "tools/call", "id" => 1}, credential)
      assert {:ok, _} = Mcp.extract_credential(with_method["params"])
      assert with_method["method"] == "tools/call"

      # `name` marks MCP tool-call params even if a `method` key is also present.
      with_name = MCP.set_credential(%{"method" => "tools/call", "name" => "premium"}, credential)
      assert with_name["name"] == "premium"
      refute Map.has_key?(with_name, "params")
      assert {:ok, _} = Mcp.extract_credential(with_name)
    end
  end

  test "MCP module exposes Descripex metadata for all callbacks" do
    names = for f <- MCP.__api__(), do: f.name

    assert :payment_required? in names
    assert :get_challenges in names
    assert :set_credential in names
  end
end
