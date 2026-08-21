defmodule MPP.Transports.WebSocketTest do
  use ExUnit.Case, async: true

  alias MPP.Client.Transport.WebSocket, as: ClientTransport
  alias MPP.Credential
  alias MPP.Demo.Method, as: DemoMethod
  alias MPP.Session.Channel
  alias MPP.Session.ETSStore
  alias MPP.Session.Store
  alias MPP.Test.SessionSigning
  alias MPP.Transports.WebSocket
  alias MPP.Transports.WebSocket.Session

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

  defmodule MockSessionMethod do
    @moduledoc false
    use MPP.Session.Method

    @impl MPP.Method
    def method_name, do: "mocksession"

    @impl MPP.Method
    def validate_config!(_config), do: :ok
  end

  defmodule ErrorStore do
    @moduledoc false
    def get(_channel_id), do: {:error, :down}
    def put(_channel), do: :ok
    def update(_channel_id, _fun), do: {:error, :timeout}
    def delete(_channel_id), do: :ok
  end

  describe "session metering" do
    @channel_id "0x5db832ef1f06a767e0561f2fe53231240f8804895a21d5804ddb15b329c73c5e"
    @payer "0x1111111111111111111111111111111111111111"
    @recipient "0x2222222222222222222222222222222222222222"
    @token "0x3333333333333333333333333333333333333333"
    @escrow "0x4d50500000000000000000000000000000000000"

    defp session_store do
      name = :"#{__MODULE__}.meter.#{System.unique_integer([:positive])}"
      start_supervised!(ETSStore.child_spec(name: name))
      {ETSStore, [name: name]}
    end

    defp meter_session(store, overrides \\ []) do
      store
      |> session_options()
      |> Keyword.merge(overrides)
      |> WebSocket.init()
    end

    defp unmetered_session(store) do
      store
      |> session_options()
      |> Keyword.drop([:generate, :tick_cost])
      |> WebSocket.init()
    end

    defp session_options(store) do
      [
        handler: fn %{"method" => "eth_chainId"} -> "0xa61" end,
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
        generate: ["chunk-1", "chunk-2", "chunk-3"]
      ]
    end

    defp put_channel!(store, opts) do
      {:ok, channel} =
        Channel.new(
          channel_id: @channel_id,
          payer: @payer,
          recipient: @recipient,
          token: @token,
          deposit: Keyword.get(opts, :deposit, 1_000),
          cumulative_amount: Keyword.get(opts, :cumulative, 100),
          spent: Keyword.get(opts, :spent, 0)
        )

      {:ok, channel} = Channel.activate(channel)
      :ok = Store.put(store, channel)
      channel
    end

    test "init requires session intent for generate" do
      assert_raise ArgumentError, ~r/intent: "session"/, fn ->
        session(generate: ["x"], tick_cost: 1)
      end
    end

    test "init rejects a non-list generate" do
      assert_raise ArgumentError, ~r/generate must be a list/, fn ->
        meter_session(session_store(), generate: "nope")
      end
    end

    test "start_metering requires an authorized session" do
      sess = meter_session(session_store())

      assert_raise ArgumentError, ~r/authorized/, fn ->
        WebSocket.start_metering(sess, channel_id: @channel_id, generate: ["a"], tick_cost: 50)
      end
    end

    test "start_metering requires a session initialized for metering" do
      store = session_store()
      {sess, [challenge_text]} = WebSocket.open(unmetered_session(store))
      {:ok, challenge_frame} = WebSocket.decode_frame(challenge_text)
      {:ok, [challenge]} = ClientTransport.get_challenges(challenge_frame)

      {sess, [_receipt]} =
        WebSocket.handle_text(credential_text(challenge, session_open_payload(50)), sess)

      assert_raise ArgumentError, ~r/initialized with :generate/, fn ->
        WebSocket.start_metering(sess, channel_id: @channel_id, generate: ["x"], tick_cost: 50)
      end
    end

    test "start_metering validates options before deducting" do
      store = session_store()
      put_channel!(store, cumulative: 100, spent: 0)
      {sess, _} = WebSocket.open(meter_session(store, generate: []))
      sess = %{sess | status: :authorized}

      assert_raise ArgumentError, ~r/generate must be a list/, fn ->
        WebSocket.start_metering(sess, channel_id: @channel_id, generate: "invalid", tick_cost: 50)
      end

      assert_raise ArgumentError, ~r/positive :tick_cost/, fn ->
        WebSocket.start_metering(sess, channel_id: @channel_id, generate: ["x"], tick_cost: 0)
      end

      assert {:ok, channel} = Store.get(store, @channel_id)
      assert channel.spent == 0
      assert channel.units == 0
    end

    test "tick deducts, emits data, then needVoucher when the channel is exhausted" do
      store = session_store()
      put_channel!(store, cumulative: 100, spent: 0)
      {sess, _} = WebSocket.open(meter_session(store, generate: []))
      sess = %{sess | status: :authorized}

      {sess, frames} =
        WebSocket.start_metering(sess,
          channel_id: @channel_id,
          generate: ["chunk-1", "chunk-2", "chunk-3"],
          tick_cost: 50
        )

      assert Enum.map(frames, & &1["type"]) == ["message", "message", "needVoucher"]
      assert Enum.at(frames, 0)["data"] == "chunk-1"
      assert Enum.at(frames, 1)["data"] == "chunk-2"
      nv = Enum.at(frames, 2)
      assert nv["channelId"] == @channel_id
      assert nv["requiredCumulative"] == "150"
      assert nv["acceptedCumulative"] == "100"
      assert nv["deposit"] == "1000"
      assert sess.status == :awaiting_voucher

      {_sess, []} = WebSocket.tick(sess)
    end

    test "tick resumes after a voucher raises the ceiling and finishes with a session receipt" do
      store = session_store()
      put_channel!(store, cumulative: 50, spent: 0)
      {sess, _} = WebSocket.open(meter_session(store, generate: []))
      sess = %{sess | status: :authorized}

      {sess, frames} =
        WebSocket.start_metering(sess,
          channel_id: @channel_id,
          generate: ["a", "b"],
          tick_cost: 50
        )

      assert List.last(frames)["type"] == "needVoucher"

      {:ok, _channel} =
        Store.update(store, @channel_id, fn channel ->
          Channel.apply_voucher(channel, 200)
        end)

      {sess, resume} = WebSocket.tick(%{sess | status: :authorized})
      assert Enum.map(resume, & &1["type"]) == ["message", "receipt"]
      assert hd(resume)["data"] == "b"
      receipt = List.last(resume)["receipt"]
      assert receipt["intent"] == "session"
      assert receipt["channelId"] == @channel_id
      assert receipt["acceptedCumulative"] == "200"
      assert receipt["spent"] == "100"
      assert receipt["units"] == 2
      assert sess.status == :complete
    end

    test "message while awaiting a voucher is rejected" do
      store = session_store()
      put_channel!(store, cumulative: 50, spent: 0)
      {sess, _} = WebSocket.open(meter_session(store, generate: []))
      sess = %{sess | status: :authorized}

      {sess, _frames} =
        WebSocket.start_metering(sess,
          channel_id: @channel_id,
          generate: ["only", "more"],
          tick_cost: 50
        )

      assert sess.status == :awaiting_voucher
      {_sess, [frame]} = WebSocket.handle_frame(%{"type" => "message", "data" => %{}}, sess)
      assert frame == %{"type" => "error", "error" => "voucher required"}
    end

    test "tick errors when the channel is missing or closed" do
      store = session_store()
      {sess, _} = WebSocket.open(meter_session(store, generate: []))
      sess = %{sess | status: :authorized}

      {_sess, [missing]} =
        WebSocket.start_metering(sess, channel_id: @channel_id, generate: ["x"], tick_cost: 50)

      assert missing["error"] == "session channel not found"

      put_channel!(store, cumulative: 100)
      {:ok, _} = Store.update(store, @channel_id, &Channel.close/1)

      {_sess, [closed]} =
        WebSocket.start_metering(%{sess | status: :authorized},
          channel_id: @channel_id,
          generate: ["x"],
          tick_cost: 50
        )

      assert closed["error"] == "session channel is closed"
    end

    test "tick with an unbound meter reports an error" do
      store = session_store()
      sess = meter_session(store)
      {sess, _} = WebSocket.open(sess)
      sess = %{sess | status: :authorized}
      {_sess, [frame]} = WebSocket.tick(sess)
      assert frame["error"] == "session channel is not bound"
    end

    test "empty generate emits a session receipt immediately" do
      store = session_store()
      put_channel!(store, cumulative: 100, spent: 10)
      {sess, _} = WebSocket.open(meter_session(store, generate: []))
      sess = %{sess | status: :authorized}
      {sess, [frame]} = WebSocket.start_metering(sess, channel_id: @channel_id, generate: [], tick_cost: 50)
      assert frame["type"] == "receipt"
      assert frame["receipt"]["spent"] == "10"
      assert sess.status == :complete
    end

    test "empty generate without a channel reports not found" do
      store = session_store()
      {sess, _} = WebSocket.open(meter_session(store, generate: []))
      sess = %{sess | status: :authorized}

      {_sess, [frame]} =
        WebSocket.start_metering(sess, channel_id: @channel_id, generate: [], tick_cost: 50)

      assert frame["error"] == "session channel not found"
    end

    test "tick after a session receipt is a no-op" do
      store = session_store()
      put_channel!(store, cumulative: 100, spent: 10)
      {sess, _} = WebSocket.open(meter_session(store, generate: []))
      sess = %{sess | status: :authorized}
      {sess, _} = WebSocket.start_metering(sess, channel_id: @channel_id, generate: [], tick_cost: 50)
      assert sess.status == :complete
      {_sess, []} = WebSocket.tick(sess)
    end

    test "bind_channel ignores a payload without a channelId" do
      sess = meter_session(session_store())
      refute sess.meter.channel_id
      bound = Session.bind_channel(sess, %{"action" => "open"})
      refute bound.meter.channel_id
    end

    test "finish reports a store get error" do
      {sess, _} = WebSocket.open(meter_session(__MODULE__.ErrorStore, generate: []))
      sess = %{sess | status: :authorized}
      {_sess, [frame]} = WebSocket.start_metering(sess, channel_id: @channel_id, generate: [], tick_cost: 50)
      assert frame["error"] =~ "session store error"
    end

    test "tick reports a store update error" do
      {sess, _} = WebSocket.open(meter_session(__MODULE__.ErrorStore, generate: []))
      sess = %{sess | status: :authorized}
      {_sess, [frame]} = WebSocket.start_metering(sess, channel_id: @channel_id, generate: ["x"], tick_cost: 50)
      assert frame["error"] =~ "session deduct failed"
    end

    test "init defaults tick_cost from the session amount" do
      store = session_store()

      sess =
        WebSocket.init(
          handler: fn %{"method" => "eth_chainId"} -> "0xa61" end,
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
          generate: ["x"]
        )

      assert sess.meter.tick_cost == 50
    end

    test "init requires a positive tick_cost when the session amount is not a unit count" do
      store = session_store()

      assert_raise ArgumentError, ~r/positive :tick_cost/, fn ->
        WebSocket.init(
          handler: fn _ -> %{} end,
          secret_key: @secret_key,
          realm: @realm,
          intent: "session",
          method: MockSessionMethod,
          amount: "0.5",
          currency: @token,
          recipient: @recipient,
          suggested_deposit: "1000",
          session_store: store,
          method_config: %{"deposit" => 1_000, "payer" => @payer, "token" => @token},
          store: false,
          generate: ["x"]
        )
      end
    end

    test "init rejects an explicit non-positive tick_cost even when amount is valid" do
      assert_raise ArgumentError, ~r/positive :tick_cost/, fn ->
        meter_session(session_store(), tick_cost: 0)
      end
    end

    test "open credential drains until needVoucher; a voucher credential resumes and finishes" do
      store = session_store()
      {sess, [challenge_text]} = WebSocket.open(meter_session(store, generate: ["chunk-1", "chunk-2"]))
      {:ok, challenge_frame} = WebSocket.decode_frame(challenge_text)
      {:ok, [challenge]} = ClientTransport.get_challenges(challenge_frame)

      {sess, open_texts} =
        WebSocket.handle_text(credential_text(challenge, session_open_payload(50)), sess)

      open_frames = decode_all(open_texts)
      assert Enum.map(open_frames, & &1["type"]) == ["receipt", "message", "needVoucher"]
      assert Enum.at(open_frames, 1)["data"] == "chunk-1"
      nv = List.last(open_frames)
      assert nv["requiredCumulative"] == "100"
      assert nv["acceptedCumulative"] == "50"
      assert sess.status == :awaiting_voucher

      {sess, voucher_texts} =
        WebSocket.handle_text(credential_text(challenge, session_voucher_payload(100)), sess)

      voucher_frames = decode_all(voucher_texts)
      assert Enum.map(voucher_frames, & &1["type"]) == ["message", "receipt"]
      assert hd(voucher_frames)["data"] == "chunk-2"
      session_receipt = List.last(voucher_frames)["receipt"]
      assert session_receipt["intent"] == "session"
      assert session_receipt["channelId"] == @channel_id
      assert session_receipt["acceptedCumulative"] == "100"
      assert session_receipt["spent"] == "100"
      assert session_receipt["units"] == 2
      assert sess.status == :complete

      assert {:ok, channel} = Store.get(store, @channel_id)
      assert channel.spent == 100
      assert channel.units == 2

      rpc = %{"jsonrpc" => "2.0", "id" => 1, "method" => "eth_chainId", "params" => []}
      {_sess, [message_text]} = WebSocket.handle_text(Jason.encode!(%{"type" => "message", "data" => rpc}), sess)
      {:ok, message_frame} = WebSocket.decode_frame(message_text)
      assert Jason.decode!(message_frame["data"]) == %{"jsonrpc" => "2.0", "id" => 1, "result" => "0xa61"}
    end

    test "an unmetered session retains its one-time handshake charge" do
      store = session_store()
      {sess, [challenge_text]} = WebSocket.open(unmetered_session(store))
      {:ok, challenge_frame} = WebSocket.decode_frame(challenge_text)
      {:ok, [challenge]} = ClientTransport.get_challenges(challenge_frame)

      {_sess, [receipt_text]} =
        WebSocket.handle_text(credential_text(challenge, session_open_payload(50)), sess)

      assert {:ok, receipt_frame} = WebSocket.decode_frame(receipt_text)
      assert receipt_frame["receipt"]["spent"] == "50"
      assert receipt_frame["receipt"]["units"] == 1
      assert {:ok, channel} = Store.get(store, @channel_id)
      assert channel.spent == 50
      assert channel.units == 1
    end

    test "start_metering after the handshake charges only generated items" do
      store = session_store()
      {sess, [challenge_text]} = WebSocket.open(meter_session(store, generate: nil))
      {:ok, challenge_frame} = WebSocket.decode_frame(challenge_text)
      {:ok, [challenge]} = ClientTransport.get_challenges(challenge_frame)

      {sess, [_receipt]} =
        WebSocket.handle_text(credential_text(challenge, session_open_payload(50)), sess)

      assert {:ok, opened} = Store.get(store, @channel_id)
      assert opened.spent == 0
      assert opened.units == 0

      {sess, [message, receipt]} =
        WebSocket.start_metering(sess,
          channel_id: @channel_id,
          generate: ["chunk"],
          tick_cost: 50
        )

      assert message["type"] == "message"
      assert receipt["receipt"]["spent"] == "50"
      assert receipt["receipt"]["units"] == 1
      assert sess.status == :complete
    end
  end

  defp decode_all(texts) do
    Enum.map(texts, fn text ->
      assert {:ok, frame} = WebSocket.decode_frame(text)
      frame
    end)
  end

  defp credential_text(challenge, payload) do
    Jason.encode!(ClientTransport.set_credential(%{}, %Credential{challenge: challenge, payload: payload}))
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
