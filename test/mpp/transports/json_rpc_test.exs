defmodule MPP.Transports.JsonRpcTest do
  use ExUnit.Case, async: true

  alias MPP.Credential
  alias MPP.Demo.Method, as: DemoMethod
  alias MPP.Receipt
  alias MPP.Tempo.ConCacheStore
  alias MPP.Transports.JsonRpc

  @secret_key "test-secret-key-for-jsonrpc"
  @realm "rpc.example.com"

  defp server_config(overrides \\ []) do
    [
      secret_key: @secret_key,
      realm: @realm,
      method: DemoMethod,
      amount: "1000",
      currency: "usd",
      store: false
    ]
    |> Keyword.merge(overrides)
    |> JsonRpc.init()
  end

  defp rpc_request(opts \\ []) do
    %{
      "jsonrpc" => "2.0",
      "id" => Keyword.get(opts, :id, 1),
      "method" => Keyword.get(opts, :method, "eth_getBlockByNumber"),
      "params" => Keyword.get(opts, :params, ["latest", false])
    }
  end

  defp paid_handler do
    fn request ->
      send(self(), {:handled, request["id"], request["params"]})
      %{"number" => "0x1", "hash" => "0xabc"}
    end
  end

  defp credential_for(challenge, token \\ "demo-token") do
    %Credential{challenge: challenge, payload: %{"token" => token}}
  end

  describe "constants" do
    test "error codes and meta keys match the MPP JSON-RPC transport spec" do
      # paymentauth.org draft-payment-transport-mcp-00 § Error Code Mapping
      # and § IANA Considerations: -32042 Payment Required, -32043 Verification Failed.
      assert JsonRpc.payment_required_code() == -32_042
      assert JsonRpc.verification_failed_code() == -32_043
      assert JsonRpc.credential_meta_key() == "org.paymentauth/credential"
      assert JsonRpc.receipt_meta_key() == "org.paymentauth/receipt"
    end
  end

  describe "call/3" do
    test "returns -32042 with error.data.challenges when no credential is present" do
      response = JsonRpc.call(rpc_request(), server_config(), fn _ -> flunk("handler must not run") end)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["error"]["code"] == -32_042
      assert response["error"]["message"] == "Payment Required"

      data = response["error"]["data"]
      assert data["httpStatus"] == 402
      assert data["problem"]["type"] == "https://paymentauth.org/problems/payment-required"
      [challenge] = data["challenges"]
      assert challenge["realm"] == @realm
      assert challenge["method"] == "demo"
      assert challenge["intent"] == "charge"
      assert challenge["request"]["amount"] == "1000"
      assert challenge["request"]["currency"] == "usd"
      refute Map.has_key?(response, "_meta")
    end

    test "accepts a root-level _meta credential and attaches the receipt at root _meta" do
      unpaid = JsonRpc.call(rpc_request(), server_config(), fn _ -> flunk("unpaid") end)
      assert {:ok, [challenge]} = JsonRpc.extract_challenges(unpaid)

      request = JsonRpc.attach_credential(rpc_request(), credential_for(challenge))

      # Root _meta — params stay a JSON-RPC array (spec § Metadata Placement).
      assert request["params"] == ["latest", false]
      assert request["_meta"][JsonRpc.credential_meta_key()]["challenge"]["id"] == challenge.id

      response = JsonRpc.call(request, server_config(), paid_handler())

      assert_received {:handled, 1, ["latest", false]}
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["result"] == %{"number" => "0x1", "hash" => "0xabc"}
      refute get_in(response, ["result", "_meta"])

      receipt = response["_meta"][JsonRpc.receipt_meta_key()]
      assert receipt["status"] == "success"
      assert receipt["method"] == "demo"
      assert receipt["challengeId"] == challenge.id
      assert is_binary(receipt["reference"])
    end

    test "accepts a nested params._meta credential (servers MUST check both locations)" do
      unpaid = JsonRpc.call(rpc_request(params: %{"n" => 1}), server_config(), fn _ -> flunk("unpaid") end)
      assert {:ok, [challenge]} = JsonRpc.extract_challenges(unpaid)

      request = %{
        "jsonrpc" => "2.0",
        "id" => 7,
        "method" => "custom/paidMethod",
        "params" => MPP.Mcp.attach_credential(%{"n" => 1}, credential_for(challenge))
      }

      refute Map.has_key?(request, "_meta")
      assert {:ok, _} = JsonRpc.extract_credential(request)

      response = JsonRpc.call(request, server_config(), paid_handler())
      assert_received {:handled, 7, %{"n" => 1}}
      assert response["_meta"][JsonRpc.receipt_meta_key()]["challengeId"] == challenge.id
      refute get_in(response, ["result", "_meta"])
    end

    test "wraps a non-object JSON-RPC result and still attaches root _meta receipt" do
      unpaid = JsonRpc.call(rpc_request(), server_config(), fn _ -> flunk("unpaid") end)
      {:ok, [challenge]} = JsonRpc.extract_challenges(unpaid)
      request = JsonRpc.attach_credential(rpc_request(), credential_for(challenge))

      response = JsonRpc.call(request, server_config(), fn _ -> "0x1" end)

      assert response["result"] == "0x1"
      assert response["_meta"][JsonRpc.receipt_meta_key()]["method"] == "demo"
    end

    test "MCP call still nests the receipt even when the credential arrived at root _meta" do
      unpaid = JsonRpc.call(rpc_request(), server_config(), fn _ -> flunk("unpaid") end)
      {:ok, [challenge]} = JsonRpc.extract_challenges(unpaid)
      request = JsonRpc.attach_credential(rpc_request(), credential_for(challenge))

      response = MPP.Mcp.call(request, server_config(), paid_handler())

      assert_received {:handled, 1, ["latest", false]}
      assert get_in(response, ["result", "_meta", JsonRpc.receipt_meta_key(), "challengeId"]) == challenge.id
      refute Map.has_key?(response, "_meta")
    end

    test "maps a rejected credential to -32043 with a fresh challenge" do
      unpaid = JsonRpc.call(rpc_request(), server_config(), fn _ -> flunk("unpaid") end)
      {:ok, [challenge]} = JsonRpc.extract_challenges(unpaid)
      request = JsonRpc.attach_credential(rpc_request(), credential_for(challenge, "wrong-token"))

      response = JsonRpc.call(request, server_config(), fn _ -> flunk("must not run") end)

      assert response["error"]["code"] == -32_043
      assert response["error"]["data"]["httpStatus"] == 402
      assert [_retry] = response["error"]["data"]["challenges"]
      assert response["error"]["data"]["problem"]["type"] == "https://paymentauth.org/problems/verification-failed"
    end

    test "maps a malformed credential to -32602" do
      request = Map.put(rpc_request(), "_meta", %{JsonRpc.credential_meta_key() => "not-an-object"})

      response = JsonRpc.call(request, server_config(), fn _ -> flunk("must not run") end)

      assert response["error"]["code"] == -32_602
      assert response["error"]["data"]["problem"]["type"] == "https://paymentauth.org/problems/malformed-credential"
    end

    test "rejects a replayed credential" do
      cache_name = :"jsonrpc_replay_#{System.unique_integer([:positive])}"
      start_supervised!({ConCacheStore, name: cache_name})
      config = server_config(store: {ConCacheStore, name: cache_name})

      unpaid = JsonRpc.call(rpc_request(), config, fn _ -> flunk("unpaid") end)
      {:ok, [challenge]} = JsonRpc.extract_challenges(unpaid)
      request = JsonRpc.attach_credential(rpc_request(), credential_for(challenge))

      first = JsonRpc.call(request, config, paid_handler())
      assert first["_meta"][JsonRpc.receipt_meta_key()]

      second = JsonRpc.call(request, config, fn _ -> flunk("replay") end)
      assert second["error"]["code"] == -32_043
      assert second["error"]["data"]["problem"]["detail"] == "Payment credential already used"
    end
  end

  describe "extract_credential/1 and attach helpers" do
    test "root _meta wins over params._meta when both are present" do
      unpaid = JsonRpc.call(rpc_request(params: %{}), server_config(), fn _ -> flunk("unpaid") end)
      {:ok, [challenge]} = JsonRpc.extract_challenges(unpaid)

      root = credential_for(challenge)
      nested = credential_for(challenge, "wrong-token")

      request =
        [params: %{}]
        |> rpc_request()
        |> JsonRpc.attach_credential(root)
        |> update_in(["params"], &MPP.Mcp.attach_credential(&1, nested))

      assert {:ok, parsed} = JsonRpc.extract_credential(request)
      assert parsed.payload["token"] == "demo-token"
    end

    test "attach_receipt writes org.paymentauth/receipt at the envelope root" do
      receipt = Receipt.new(method: "demo", reference: "ref_1", timestamp: "2026-04-04T12:00:00Z")

      response =
        JsonRpc.attach_receipt(
          %{"jsonrpc" => "2.0", "id" => 1, "result" => "0x1"},
          receipt,
          "ch_1"
        )

      assert response["result"] == "0x1"
      assert response["_meta"][JsonRpc.receipt_meta_key()]["challengeId"] == "ch_1"
      assert response["_meta"][JsonRpc.receipt_meta_key()]["reference"] == "ref_1"
    end
  end

  test "module exposes Descripex metadata for the public surface" do
    names = for f <- JsonRpc.__api__(), do: f.name

    for expected <- [
          :init,
          :call,
          :extract_credential,
          :attach_credential,
          :attach_receipt,
          :payment_required?,
          :extract_challenges,
          :payment_required_code,
          :verification_failed_code,
          :credential_meta_key,
          :receipt_meta_key
        ] do
      assert expected in names
    end
  end
end
