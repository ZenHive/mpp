defmodule MPP.Transports.WebSocket.IntegrationTest do
  use ExUnit.Case, async: true

  alias MPP.Client.Transport.WebSocket, as: ClientTransport
  alias MPP.Client.Transport.WebSocket.Retry
  alias MPP.Credential
  alias MPP.Demo.Method, as: DemoMethod
  alias MPP.Session.ETSStore
  alias MPP.Test.SessionSigning
  alias MPP.Test.WebSocketLoopback
  alias MPP.Transports.WebSocket

  @moduletag :websocket

  @secret_key "test-secret-key-for-ws-e2e"
  @realm "ws-e2e.example.com"
  @channel_id "0x5db832ef1f06a767e0561f2fe53231240f8804895a21d5804ddb15b329c73c5e"
  @payer "0x1111111111111111111111111111111111111111"
  @recipient "0x2222222222222222222222222222222222222222"
  @token "0x3333333333333333333333333333333333333333"
  @escrow "0x4d50500000000000000000000000000000000000"

  defmodule MockSessionMethod do
    @moduledoc false
    use MPP.Session.Method

    @impl MPP.Method
    def method_name, do: "mocksession"

    @impl MPP.Method
    def validate_config!(_config), do: :ok
  end

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

  describe "session metering loopback" do
    test "needVoucher, voucher, resume, then session receipt" do
      store = session_store()
      server = start_session_adapter!(store)
      assert {:ok, client} = WebSocketLoopback.connect(server.port)

      {challenge_frame, client} = recv_frame!(client)
      assert ClientTransport.payment_required?(challenge_frame)
      assert {:ok, [challenge]} = ClientTransport.get_challenges(challenge_frame)

      retry = Retry.new()
      assert Retry.should_pay?(retry)
      {:continue, retry} = Retry.transition(retry, :pay_started)

      open_frame =
        ClientTransport.set_credential(%{}, %Credential{
          challenge: challenge,
          payload: session_open_payload(50)
        })

      assert :ok = WebSocketLoopback.send_text(client, WebSocket.encode_frame(open_frame))
      {:continue, retry} = Retry.transition(retry, :credential_sent)

      {open_receipt, client} = recv_frame!(client)
      assert open_receipt["type"] == "receipt"
      {:continue, retry} = Retry.transition(retry, :receipt)

      {data, client} = recv_frame!(client)
      assert data["type"] == "message"
      assert data["data"] == "chunk-1"

      {need_voucher, client} = recv_frame!(client)
      assert ClientTransport.need_voucher?(need_voucher)
      assert {:ok, request} = ClientTransport.voucher_request(need_voucher)
      assert request.channel_id == @channel_id
      assert request.required_cumulative == "100"
      {:continue, retry} = Retry.transition(retry, :need_voucher)
      assert retry.voucher_in_flight?
      refute Retry.should_pay?(retry)

      voucher_frame =
        ClientTransport.set_credential(%{}, %Credential{
          challenge: challenge,
          payload: session_voucher_payload(100)
        })

      assert :ok = WebSocketLoopback.send_text(client, WebSocket.encode_frame(voucher_frame))
      {:continue, retry} = Retry.transition(retry, :credential_sent)
      assert retry.awaiting_receipt?

      {resumed, client} = recv_frame!(client)
      assert resumed["type"] == "message"
      assert resumed["data"] == "chunk-2"
      refute Retry.should_pay?(retry)

      {session_receipt, client} = recv_frame!(client)
      assert session_receipt["type"] == "receipt"
      assert session_receipt["receipt"]["intent"] == "session"
      assert session_receipt["receipt"]["channelId"] == @channel_id
      assert session_receipt["receipt"]["acceptedCumulative"] == "100"
      assert session_receipt["receipt"]["spent"] == "100"
      assert session_receipt["receipt"]["units"] == 2
      {:continue, retry} = Retry.transition(retry, :receipt)
      assert Retry.should_pay?(retry)

      assert {:ok, channel} = MPP.Session.Store.get(store, @channel_id)
      assert channel.spent == 100
      assert channel.units == 2

      rpc = %{"jsonrpc" => "2.0", "id" => 1, "method" => "eth_chainId", "params" => []}
      assert :ok = WebSocketLoopback.send_text(client, WebSocket.encode_frame(WebSocket.message_frame(rpc)))
      {message_frame, client} = recv_frame!(client)
      assert Jason.decode!(message_frame["data"]) == %{"jsonrpc" => "2.0", "id" => 1, "result" => "0xa61"}

      WebSocketLoopback.close(client)
    end

    test "second needVoucher while a voucher is in flight is fatal" do
      need_voucher =
        Jason.encode!(%{
          "type" => "needVoucher",
          "channelId" => @channel_id,
          "requiredCumulative" => "150",
          "acceptedCumulative" => "100",
          "deposit" => "1000"
        })

      {:ok, server} =
        WebSocketLoopback.start(
          mode: :script,
          script: [
            {:send, need_voucher},
            {:send, need_voucher}
          ]
        )

      on_exit(fn -> WebSocketLoopback.stop(server) end)

      assert {:ok, client} = WebSocketLoopback.connect(server.port)
      {first, client} = recv_frame!(client)
      assert ClientTransport.need_voucher?(first)
      {:continue, retry} = Retry.transition(Retry.new(), :need_voucher)
      assert retry.voucher_in_flight?

      {second, client} = recv_frame!(client)
      assert ClientTransport.need_voucher?(second)
      {{:fatal, :second_voucher_in_flight}, retry} = Retry.transition(retry, :need_voucher)
      refute Retry.should_pay?(retry)
      refute Retry.reconnect?(retry)
      {{:fatal, :second_voucher_in_flight}, _} = Retry.transition(retry, :pay_started)

      WebSocketLoopback.close(client)
    end
  end

  defp session_store do
    name = :"#{__MODULE__}.session.#{System.unique_integer([:positive])}"
    start_supervised!(ETSStore.child_spec(name: name))
    {ETSStore, [name: name]}
  end

  defp start_session_adapter!(store) do
    session =
      WebSocket.init(
        handler: fn
          %{"method" => "eth_chainId"} -> "0xa61"
          %{"method" => method} -> %{"error" => %{"code" => -32_601, "message" => "Method not found: #{method}"}}
        end,
        secret_key: @secret_key,
        realm: @realm,
        intent: "session",
        method: MockSessionMethod,
        amount: "50",
        currency: @token,
        recipient: @recipient,
        suggested_deposit: "1000",
        session_store: store,
        method_config: %{
          "deposit" => 1_000,
          "payer" => @payer,
          "token" => @token,
          "escrowContract" => @escrow,
          "chainId" => 42_431,
          "authorizedSigner" => SessionSigning.signer_address()
        },
        store: false,
        tick_cost: 50,
        generate: ["chunk-1", "chunk-2"]
      )

    {:ok, server} = WebSocketLoopback.start(mode: :adapter, session: session)
    on_exit(fn -> WebSocketLoopback.stop(server) end)
    server
  end

  defp session_open_payload(amount) do
    %{
      "action" => "open",
      "type" => "transaction",
      "channelId" => @channel_id,
      "transaction" => "0x76abcd",
      "cumulativeAmount" => Integer.to_string(amount),
      "signature" => session_sign(amount)
    }
  end

  defp session_voucher_payload(amount) do
    %{
      "action" => "voucher",
      "channelId" => @channel_id,
      "cumulativeAmount" => Integer.to_string(amount),
      "signature" => session_sign(amount)
    }
  end

  defp session_sign(amount) do
    SessionSigning.sign_voucher(@channel_id, amount, @escrow, 42_431)
  end
end
