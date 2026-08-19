defmodule MPP.Client.Transport.JsonRpcTest do
  use ExUnit.Case, async: true

  alias MPP.Challenge
  alias MPP.Client.Transport.JsonRpc, as: Transport
  alias MPP.Credential
  alias MPP.Mcp
  alias MPP.Transports.JsonRpc

  @secret_key "test-secret-key"
  @request "eyJhbW91bnQiOiIxMDAwIiwiY3VycmVuY3kiOiJ1c2QifQ"

  defp make_challenge do
    Challenge.create(
      [realm: "rpc.example.com", method: "tempo", intent: "charge", request: @request],
      @secret_key
    )
  end

  defp payment_error(challenge) do
    Mcp.payment_required_error(challenge)
  end

  defp envelope(error) do
    %{"jsonrpc" => "2.0", "id" => 1, "error" => error}
  end

  describe "payment_required?/1" do
    test "true for -32042 error objects and full envelopes" do
      error = payment_error(make_challenge())
      assert Transport.payment_required?(error)
      assert Transport.payment_required?(envelope(error))
    end

    test "false for other errors, success, and non-maps" do
      refute Transport.payment_required?(%{"code" => -32_043, "message" => "Payment Verification Failed"})
      refute Transport.payment_required?(%{"jsonrpc" => "2.0", "id" => 1, "result" => "0x1"})
      refute Transport.payment_required?("not-a-map")
      refute Transport.payment_required?(nil)
    end
  end

  describe "get_challenges/1" do
    test "parses challenges from error.data.challenges" do
      challenge = make_challenge()
      assert {:ok, [parsed]} = Transport.get_challenges(envelope(payment_error(challenge)))
      assert parsed.id == challenge.id
      assert parsed.method == "tempo"
    end

    test "returns :malformed_envelope for non-map values" do
      assert {:error, :malformed_envelope} = Transport.get_challenges("nope")
      assert {:error, :malformed_envelope} = Transport.get_challenges([])
    end
  end

  describe "set_credential/2" do
    test "attaches at root _meta and leaves array params untouched" do
      challenge = make_challenge()
      credential = %Credential{challenge: challenge, payload: %{"type" => "hash"}}

      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "eth_getBlockByNumber",
        "params" => ["latest", false]
      }

      updated = Transport.set_credential(request, credential)

      assert updated["params"] == ["latest", false]
      assert updated["_meta"][JsonRpc.credential_meta_key()]["challenge"]["id"] == challenge.id
      assert {:ok, parsed} = JsonRpc.extract_credential(updated)
      assert parsed.payload == %{"type" => "hash"}
    end

    test "preserves existing root _meta keys" do
      challenge = make_challenge()
      credential = %Credential{challenge: challenge, payload: %{"token" => "demo-token"}}

      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "eth_call",
        "params" => [],
        "_meta" => %{"keep" => true}
      }

      updated = Transport.set_credential(request, credential)
      assert updated["_meta"]["keep"] == true
      assert updated["_meta"][JsonRpc.credential_meta_key()]
    end
  end
end
