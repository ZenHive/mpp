defmodule MPP.Transports.WebSocket.IntegrationTest do
  use ExUnit.Case, async: true

  alias MPP.Client.Transport.WebSocket, as: ClientTransport
  alias MPP.Client.Transport.WebSocket.Retry
  alias MPP.Credential
  alias MPP.Demo.Method, as: DemoMethod
  alias MPP.Test.WebSocketLoopback
  alias MPP.Transports.WebSocket

  @moduletag :websocket

  @secret_key "test-secret-key-for-ws-e2e"
  @realm "ws-e2e.example.com"

  defp adapter_session do
    WebSocket.init(
      handler: fn
        %{"method" => "eth_chainId"} -> "0xa61"
        %{"method" => "eth_getBlockByNumber", "params" => ["latest", false]} -> %{"number" => "0x1348c9"}
        %{"method" => method} -> %{"error" => %{"code" => -32_601, "message" => "Method not found: #{method}"}}
      end,
      secret_key: @secret_key,
      realm: @realm,
      method: DemoMethod,
      amount: "1000",
      currency: "usd",
      store: false
    )
  end

  defp start_adapter! do
    {:ok, server} = WebSocketLoopback.start(mode: :adapter, session: adapter_session())
    on_exit(fn -> WebSocketLoopback.stop(server) end)
    server
  end

  defp recv_frame!(client) do
    assert {:ok, text, client} = WebSocketLoopback.recv_text(client)
    assert {:ok, frame} = WebSocket.decode_frame(text)
    {frame, client}
  end

  describe "real local WebSocket pay-and-retry" do
    test "handshake challenge, pay, receipt, then JSON-RPC result" do
      server = start_adapter!()
      assert {:ok, client} = WebSocketLoopback.connect(server.port)

      {challenge_frame, client} = recv_frame!(client)
      assert ClientTransport.payment_required?(challenge_frame)
      assert {:ok, [challenge]} = ClientTransport.get_challenges(challenge_frame)
      assert challenge.method == "demo"
      assert challenge.realm == @realm

      retry = Retry.new()
      assert Retry.should_pay?(retry)
      {:continue, retry} = Retry.transition(retry, :pay_started)

      credential = %Credential{challenge: challenge, payload: %{"token" => "demo-token"}}
      cred_frame = ClientTransport.set_credential(%{}, credential)
      assert :ok = WebSocketLoopback.send_text(client, WebSocket.encode_frame(cred_frame))
      {:continue, retry} = Retry.transition(retry, :credential_sent)

      {receipt_frame, client} = recv_frame!(client)
      assert receipt_frame["type"] == "receipt"
      assert receipt_frame["receipt"]["status"] == "success"
      assert receipt_frame["receipt"]["challengeId"] == challenge.id
      {:continue, retry} = Retry.transition(retry, :receipt)
      assert Retry.should_pay?(retry)

      rpc = %{"jsonrpc" => "2.0", "id" => 1, "method" => "eth_chainId", "params" => []}
      assert :ok = WebSocketLoopback.send_text(client, WebSocket.encode_frame(WebSocket.message_frame(rpc)))

      {message_frame, client} = recv_frame!(client)
      assert message_frame["type"] == "message"
      assert Jason.decode!(message_frame["data"]) == %{"jsonrpc" => "2.0", "id" => 1, "result" => "0xa61"}

      WebSocketLoopback.close(client)
    end

    test "server close after credential does not amplify payment retries" do
      challenge = %{
        "id" => "ch-e2e",
        "realm" => @realm,
        "method" => "demo",
        "intent" => "charge",
        "request" => "eyJhbW91bnQiOiIxMDAwIiwiY3VycmVuY3kiOiJ1c2QifQ"
      }

      {:ok, server} =
        WebSocketLoopback.start(
          mode: :script,
          script: [
            {:send, Jason.encode!(%{"type" => "challenge", "challenge" => challenge})},
            :recv,
            :close
          ]
        )

      on_exit(fn -> WebSocketLoopback.stop(server) end)

      assert {:ok, client} = WebSocketLoopback.connect(server.port)
      {challenge_frame, client} = recv_frame!(client)
      assert ClientTransport.payment_required?(challenge_frame)
      assert {:ok, [challenge]} = ClientTransport.get_challenges(challenge_frame)

      retry = Retry.new()
      {:continue, retry} = Retry.transition(retry, :pay_started)
      assert retry.pay_count == 1

      cred_frame =
        ClientTransport.set_credential(%{}, %Credential{
          challenge: challenge,
          payload: %{"token" => "demo-token"}
        })

      assert :ok = WebSocketLoopback.send_text(client, WebSocket.encode_frame(cred_frame))
      {:continue, retry} = Retry.transition(retry, :credential_sent)
      assert_receive {:ws_script_recv, _text}, 1_000

      assert {:error, :closed} = WebSocketLoopback.recv_text(client)
      {{:fatal, :dropped_awaiting_receipt}, retry} = Retry.transition(retry, :connection_dropped)

      refute Retry.should_pay?(retry)
      refute Retry.reconnect?(retry)
      {{:fatal, :dropped_awaiting_receipt}, retry} = Retry.transition(retry, :pay_started)
      assert retry.pay_count == 1

      WebSocketLoopback.close(client)
    end

    test "malformed inbound frame is a protocol error, not a reconnect" do
      server = start_adapter!()
      assert {:ok, client} = WebSocketLoopback.connect(server.port)
      {_challenge, client} = recv_frame!(client)

      assert :ok = WebSocketLoopback.send_text(client, "{not-json")
      {frame, client} = recv_frame!(client)
      assert frame["type"] == "error"
      assert frame["error"] == "malformed MPP frame"

      {{:fatal, :malformed_frame}, retry} = Retry.transition(Retry.new(), :malformed_frame)
      refute Retry.reconnect?(retry)
      refute Retry.should_pay?(retry)

      WebSocketLoopback.close(client)
    end
  end
end
