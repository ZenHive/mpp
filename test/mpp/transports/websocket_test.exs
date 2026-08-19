defmodule MPP.Transports.WebSocketTest do
  use ExUnit.Case, async: true

  alias MPP.Client.Transport.WebSocket, as: ClientTransport
  alias MPP.Credential
  alias MPP.Demo.Method, as: DemoMethod
  alias MPP.Transports.WebSocket

  @secret_key "test-secret-key-for-websocket"
  @realm "ws.example.com"

  defp session(overrides \\ []) do
    [
      handler: fn
        %{"method" => "eth_chainId"} -> "0xa61"
        %{"method" => "eth_getBlockByNumber", "params" => params} -> %{"number" => "0x1", "params" => params}
        %{"method" => method} -> %{"error" => %{"code" => -32_601, "message" => "Method not found: #{method}"}}
      end,
      secret_key: @secret_key,
      realm: @realm,
      method: DemoMethod,
      amount: "1000",
      currency: "usd",
      store: false
    ]
    |> Keyword.merge(overrides)
    |> WebSocket.init()
  end

  defp decode_one([text]) do
    assert {:ok, frame} = WebSocket.decode_frame(text)
    frame
  end

  describe "init/1" do
    test "requires a handler" do
      assert_raise ArgumentError, ~r/requires :handler/, fn ->
        WebSocket.init(secret_key: @secret_key, realm: @realm, method: DemoMethod, amount: "1", currency: "usd")
      end
    end
  end

  describe "open/1 handshake" do
    test "emits a challenge frame with HTTP-style base64url request" do
      {_session, texts} = WebSocket.open(session())
      frame = decode_one(texts)

      assert frame["type"] == "challenge"
      refute Map.has_key?(frame, "error")
      challenge = frame["challenge"]
      assert challenge["realm"] == @realm
      assert challenge["method"] == "demo"
      assert challenge["intent"] == "charge"
      assert is_binary(challenge["request"])
      assert {:ok, _} = Base.url_decode64(challenge["request"], padding: false)
      assert ClientTransport.payment_required?(frame)
    end
  end

  describe "handle_text/2" do
    test "pay-and-retry: credential then JSON-RPC message" do
      {sess, [challenge_text]} = WebSocket.open(session())
      {:ok, challenge_frame} = WebSocket.decode_frame(challenge_text)
      assert {:ok, [challenge]} = ClientTransport.get_challenges(challenge_frame)

      credential = %Credential{challenge: challenge, payload: %{"token" => "demo-token"}}
      cred_frame = ClientTransport.set_credential(%{"type" => "message", "data" => %{}}, credential)

      {sess, [receipt_text]} = WebSocket.handle_text(Jason.encode!(cred_frame), sess)
      {:ok, receipt_frame} = WebSocket.decode_frame(receipt_text)
      assert receipt_frame["type"] == "receipt"
      assert receipt_frame["receipt"]["status"] == "success"
      assert receipt_frame["receipt"]["method"] == "demo"
      assert receipt_frame["receipt"]["challengeId"] == challenge.id
      assert sess.status == :authorized

      rpc = %{"jsonrpc" => "2.0", "id" => 1, "method" => "eth_chainId", "params" => []}
      {_sess, [message_text]} = WebSocket.handle_text(Jason.encode!(%{"type" => "message", "data" => rpc}), sess)
      {:ok, message_frame} = WebSocket.decode_frame(message_text)
      assert message_frame["type"] == "message"
      assert is_binary(message_frame["data"])
      assert Jason.decode!(message_frame["data"]) == %{"jsonrpc" => "2.0", "id" => 1, "result" => "0xa61"}
    end

    test "message before payment re-issues the handshake challenge" do
      {sess, _} = WebSocket.open(session())
      rpc = %{"jsonrpc" => "2.0", "id" => 1, "method" => "eth_chainId", "params" => []}

      {_sess, [text]} = WebSocket.handle_text(Jason.encode!(%{"type" => "message", "data" => rpc}), sess)
      {:ok, frame} = WebSocket.decode_frame(text)
      assert frame["type"] == "challenge"
      assert ClientTransport.payment_required?(frame)
    end

    test "invalid demo token yields an error frame" do
      {sess, [challenge_text]} = WebSocket.open(session())
      {:ok, challenge_frame} = WebSocket.decode_frame(challenge_text)
      {:ok, [challenge]} = ClientTransport.get_challenges(challenge_frame)

      cred_frame =
        ClientTransport.set_credential(%{}, %Credential{challenge: challenge, payload: %{"token" => "nope"}})

      {sess, [text]} = WebSocket.handle_text(Jason.encode!(cred_frame), sess)
      {:ok, frame} = WebSocket.decode_frame(text)
      assert frame["type"] == "error"
      assert is_binary(frame["error"]) and frame["error"] != ""
      assert sess.status == :open
    end

    test "malformed JSON is a fatal protocol error frame" do
      {sess, _} = WebSocket.open(session())
      {_sess, [text]} = WebSocket.handle_text("{not-json", sess)
      {:ok, frame} = WebSocket.decode_frame(text)
      assert frame["type"] == "error"
      assert frame["error"] == "malformed MPP frame"
    end

    test "unknown frame type is rejected" do
      {sess, _} = WebSocket.open(session())
      {_sess, [text]} = WebSocket.handle_text(~s({"type":"nope"}), sess)
      {:ok, frame} = WebSocket.decode_frame(text)
      assert frame["type"] == "error"
      assert frame["error"] == "unknown MPP frame"
    end

    test "malformed credential string is rejected" do
      {sess, _} = WebSocket.open(session())
      {_sess, [text]} = WebSocket.handle_text(~s({"type":"credential","credential":"Bearer xyz"}), sess)
      {:ok, frame} = WebSocket.decode_frame(text)
      assert frame["type"] == "error"
      assert frame["error"] =~ "malformed credential"
    end
  end

  describe "frame helpers" do
    test "needVoucher uses camelCase wire keys from mpp-rs" do
      frame =
        WebSocket.need_voucher_frame(
          channel_id: "0xabc",
          required_cumulative: "2000",
          accepted_cumulative: "1000",
          deposit: "5000"
        )

      assert frame["type"] == "needVoucher"
      assert frame["channelId"] == "0xabc"
      assert frame["requiredCumulative"] == "2000"
      encoded = WebSocket.encode_frame(frame)
      assert encoded =~ ~s("type":"needVoucher")
      assert encoded =~ ~s("channelId":"0xabc")
    end

    test "error and receipt frames round-trip" do
      error = WebSocket.error_frame("payment failed")
      assert {:ok, ^error} = WebSocket.decode_frame(WebSocket.encode_frame(error))

      receipt = WebSocket.receipt_frame(%{"status" => "success", "reference" => "0x1"})
      assert {:ok, decoded} = WebSocket.decode_frame(WebSocket.encode_frame(receipt))
      assert decoded["receipt"]["reference"] == "0x1"
    end

    test "challenge_frame carries an optional error string" do
      {sess, _} = WebSocket.open(session())
      frame = WebSocket.challenge_frame(sess.challenge, "previous payment failed")
      assert frame["error"] == "previous payment failed"
      assert {:ok, decoded} = WebSocket.decode_frame(WebSocket.encode_frame(frame))
      assert decoded["error"] == "previous payment failed"
    end

    test "needVoucher accepts a string-keyed map" do
      frame =
        WebSocket.need_voucher_frame(%{
          "channelId" => "0xdef",
          "requiredCumulative" => "1",
          "acceptedCumulative" => "0",
          "deposit" => "9"
        })

      assert frame["channelId"] == "0xdef"
    end

    test "message_frame leaves an already-encoded JSON string untouched" do
      assert WebSocket.message_frame("{\"ok\":true}") == %{"type" => "message", "data" => "{\"ok\":true}"}
    end

    test "encode_frame drops a null error field" do
      encoded = WebSocket.encode_frame(%{"type" => "error", "error" => nil})
      assert encoded == ~s({"type":"error"})
    end
  end

  describe "handle_frame/2 edge cases" do
    test "unexpected inbound type is an error frame" do
      {sess, _} = WebSocket.open(session())
      {_sess, [frame]} = WebSocket.handle_frame(%{"type" => "needVoucher"}, sess)
      assert frame["type"] == "error"
      assert frame["error"] == "unexpected MPP frame"
    end

    test "credential frame without a string payload is malformed" do
      {sess, _} = WebSocket.open(session())
      {_sess, [frame]} = WebSocket.handle_frame(%{"type" => "credential", "credential" => 12}, sess)
      assert frame == %{"type" => "error", "error" => "malformed credential"}
    end

    test "authorized non-object message data is rejected" do
      {sess, [challenge_text]} = WebSocket.open(session())
      {:ok, challenge_frame} = WebSocket.decode_frame(challenge_text)
      {:ok, [challenge]} = ClientTransport.get_challenges(challenge_frame)
      cred = ClientTransport.set_credential(%{}, %Credential{challenge: challenge, payload: %{"token" => "demo-token"}})
      {sess, _} = WebSocket.handle_text(Jason.encode!(cred), sess)

      {_sess, [frame]} = WebSocket.handle_frame(%{"type" => "message", "data" => ["latest"]}, sess)
      assert frame["type"] == "error"
      assert frame["error"] == "malformed JSON-RPC payload"

      {_sess, [plain]} = WebSocket.handle_frame(%{"type" => "message", "data" => "not-json"}, sess)
      assert plain["error"] == "malformed JSON-RPC payload"
    end

    test "authorized message without data is a malformed frame" do
      {sess, [challenge_text]} = WebSocket.open(session())
      {:ok, challenge_frame} = WebSocket.decode_frame(challenge_text)
      {:ok, [challenge]} = ClientTransport.get_challenges(challenge_frame)
      cred = ClientTransport.set_credential(%{}, %Credential{challenge: challenge, payload: %{"token" => "demo-token"}})
      {sess, _} = WebSocket.handle_text(Jason.encode!(cred), sess)

      {_sess, [frame]} = WebSocket.handle_frame(%{"type" => "message"}, sess)
      assert frame["type"] == "error"
      assert frame["error"] == "malformed MPP frame"
    end

    test "message before open still issues a fresh handshake challenge" do
      sess = session()
      assert sess.challenge == nil
      {_sess, [frame]} = WebSocket.handle_frame(%{"type" => "message", "data" => %{}}, sess)
      assert frame["type"] == "challenge"
      assert is_binary(frame["challenge"]["id"])
    end
  end
end
