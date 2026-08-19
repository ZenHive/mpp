defmodule MPP.Client.Transport.WebSocketTest do
  use ExUnit.Case, async: true

  alias MPP.Challenge
  alias MPP.Client.Transport.WebSocket, as: Transport
  alias MPP.Client.Transport.WebSocket.Retry
  alias MPP.Credential
  alias MPP.Headers
  alias MPP.Mcp

  @secret_key "test-secret-key"
  @request "eyJhbW91bnQiOiIxMDAwIiwiY3VycmVuY3kiOiJ1c2QifQ"

  defp make_challenge do
    Challenge.create(
      [realm: "ws.example.com", method: "tempo", intent: "charge", request: @request],
      @secret_key
    )
  end

  describe "payment_required?/1" do
    test "true for challenge frames" do
      assert Transport.payment_required?(%{"type" => "challenge", "challenge" => %{}})
    end

    test "true for JSON-RPC -32042 envelopes" do
      error = Mcp.payment_required_error(make_challenge())
      assert Transport.payment_required?(error)
      assert Transport.payment_required?(%{"jsonrpc" => "2.0", "id" => 1, "error" => error})
    end

    test "false for receipts, messages, and non-maps" do
      refute Transport.payment_required?(%{"type" => "receipt", "receipt" => %{}})
      refute Transport.payment_required?(%{"type" => "message", "data" => "{}"})
      refute Transport.payment_required?(%{"jsonrpc" => "2.0", "id" => 1, "result" => "0x1"})
      refute Transport.payment_required?("not-a-map")
    end
  end

  describe "get_challenges/1" do
    test "parses a WS challenge frame with base64url request" do
      challenge = make_challenge()

      frame = %{
        "type" => "challenge",
        "challenge" => %{
          "id" => challenge.id,
          "realm" => challenge.realm,
          "method" => challenge.method,
          "intent" => challenge.intent,
          "request" => challenge.request
        }
      }

      assert {:ok, [parsed]} = Transport.get_challenges(frame)
      assert parsed.id == challenge.id
      assert parsed.request == challenge.request
    end

    test "rejects an empty challenge id" do
      frame = %{
        "type" => "challenge",
        "challenge" => %{
          "id" => "",
          "realm" => "ws.example.com",
          "method" => "tempo",
          "intent" => "charge",
          "request" => @request,
          "description" => 12
        }
      }

      assert {:error, :invalid_challenge} = Transport.get_challenges(frame)
    end

    test "rejects a challenge whose request is a decoded object" do
      frame = %{
        "type" => "challenge",
        "challenge" => %{
          "id" => "ch-1",
          "realm" => "ws.example.com",
          "method" => "tempo",
          "intent" => "charge",
          "request" => %{"amount" => "1000"}
        }
      }

      assert {:error, :invalid_challenge} = Transport.get_challenges(frame)
    end

    test "returns :no_challenges when the challenge object is missing" do
      assert {:error, :no_challenges} = Transport.get_challenges(%{"type" => "challenge"})
    end

    test "returns :malformed_envelope for non-maps" do
      assert {:error, :malformed_envelope} = Transport.get_challenges("nope")
    end

    test "parses JSON-RPC -32042 challenge lists" do
      challenge = make_challenge()
      error = Mcp.payment_required_error(challenge)
      assert {:ok, [parsed]} = Transport.get_challenges(%{"jsonrpc" => "2.0", "id" => 1, "error" => error})
      assert parsed.id == challenge.id
    end
  end

  describe "set_credential/2" do
    test "replaces the request with a Payment authorization credential frame" do
      challenge = make_challenge()
      credential = %Credential{challenge: challenge, payload: %{"type" => "hash"}}

      frame = Transport.set_credential(%{"type" => "message", "data" => %{"jsonrpc" => "2.0"}}, credential)

      assert frame["type"] == "credential"
      assert frame["credential"] == Headers.format_credential(credential)
      assert String.starts_with?(frame["credential"], "Payment ")
    end
  end

  describe "Retry" do
    test "defaults match alloy-transport-mpp / alloy-pubsub" do
      state = Retry.new()
      assert state.max_retries == 10
      assert state.retry_interval_ms == 3_000
      assert Retry.handshake_timeout_ms(state) == 30_000
      assert Retry.should_pay?(state)
      assert Retry.reconnect?(state)
    end

    test "capped exponential backoff: 3s base → 3, 6, 12, 24, 30" do
      state = Retry.new()

      {_, state} = Retry.transition(state, :connection_dropped)
      assert Retry.delay_ms(state) == 3_000

      {_, state} = Retry.transition(state, :connection_dropped)
      assert Retry.delay_ms(state) == 6_000

      {_, state} = Retry.transition(state, :connection_dropped)
      assert Retry.delay_ms(state) == 12_000

      {_, state} = Retry.transition(state, :connection_dropped)
      assert Retry.delay_ms(state) == 24_000

      {_, state} = Retry.transition(state, :connection_dropped)
      assert Retry.delay_ms(state) == 30_000
    end

    test "configured base above the 30s cap is preserved" do
      state = Retry.new(retry_interval_ms: 60_000)
      {_, state} = Retry.transition(state, :connection_dropped)
      assert Retry.delay_ms(state) == 60_000
      {_, state} = Retry.transition(state, :connection_dropped)
      assert Retry.delay_ms(state) == 60_000
    end

    test "drop after credential sent is fatal and refuses another payment" do
      state = Retry.new()
      {:continue, state} = Retry.transition(state, :pay_started)
      assert state.pay_count == 1
      {:continue, state} = Retry.transition(state, :credential_sent)
      refute Retry.should_pay?(state)

      {{:fatal, :dropped_awaiting_receipt}, state} = Retry.transition(state, :connection_dropped)
      refute Retry.should_pay?(state)
      refute Retry.reconnect?(state)

      {{:fatal, :dropped_awaiting_receipt}, state} = Retry.transition(state, :pay_started)
      assert state.pay_count == 1
    end

    test "socket error before paying is transient and still allows pay" do
      state = Retry.new()
      {{:retry, 3_000}, state} = Retry.transition(state, {:socket_error, :closed})
      assert Retry.should_pay?(state)
      assert Retry.reconnect?(state)
      assert state.attempts == 1
    end

    test "close 1012/1013 are transient; other close codes are fatal" do
      assert Retry.transient_close?(1012)
      assert Retry.transient_close?(1013)
      refute Retry.transient_close?(1000)
      refute Retry.transient_close?(nil)

      {{:retry, _}, _} = Retry.transition(Retry.new(), {:close, 1012})
      {{:fatal, :fatal_close}, _} = Retry.transition(Retry.new(), {:close, 1000})
    end

    test "deterministic MPP failures latch and do not burn the retry budget" do
      for event <- [:malformed_frame, :binary_frame, :handshake_timeout, :provider_error, :server_error] do
        {{:fatal, ^event}, state} = Retry.transition(Retry.new(), event)
        assert state.attempts == 0
        refute Retry.reconnect?(state)
        {{:fatal, ^event}, _} = Retry.transition(state, :connection_dropped)
      end
    end

    test "second challenge while payment is in flight is fatal" do
      {:continue, state} = Retry.transition(Retry.new(), :pay_started)
      {{:fatal, :second_challenge_in_flight}, state} = Retry.transition(state, :challenge)
      refute Retry.should_pay?(state)
    end

    test "a replacement challenge after an unacked credential rolls back and allows re-pay" do
      {:continue, state} = Retry.transition(Retry.new(), :pay_started)
      {:continue, state} = Retry.transition(state, :credential_sent)
      {:continue, state} = Retry.transition(state, :challenge)
      assert Retry.should_pay?(state)
      refute state.fatal?
    end

    test "exhausting max_retries latches fatal" do
      state = Retry.new(max_retries: 2)
      {{:retry, _}, state} = Retry.transition(state, :connection_dropped)
      {{:fatal, :max_retries}, state} = Retry.transition(state, :connection_dropped)
      refute Retry.reconnect?(state)
    end

    test "receipt clears awaiting and allows later session vouchers" do
      {:continue, state} = Retry.transition(Retry.new(), :pay_started)
      {:continue, state} = Retry.transition(state, :credential_sent)
      {:continue, state} = Retry.transition(state, :receipt)
      assert Retry.should_pay?(state)
      refute state.awaiting_receipt?
    end

    test "a challenge with no payment in flight is continue" do
      assert {:continue, _} = Retry.transition(Retry.new(), :challenge)
    end

    test "pay_started while awaiting a receipt is refused" do
      {:continue, state} = Retry.transition(Retry.new(), :pay_started)
      {:continue, state} = Retry.transition(state, :credential_sent)
      {{:fatal, :payment_retry_refused}, state} = Retry.transition(state, :pay_started)
      assert state.pay_count == 1
    end

    test "drop variants while awaiting receipt are all fatal" do
      awaiting = fn ->
        {:continue, state} = Retry.transition(Retry.new(), :pay_started)
        {:continue, state} = Retry.transition(state, :credential_sent)
        state
      end

      {{:fatal, :dropped_awaiting_receipt}, _} = Retry.transition(awaiting.(), :server_gone)
      {{:fatal, :dropped_awaiting_receipt}, _} = Retry.transition(awaiting.(), {:socket_error, :econnreset})
      {{:fatal, :dropped_awaiting_receipt}, _} = Retry.transition(awaiting.(), {:close, 1012})
    end

    test "server_gone and socket_error before pay are transient" do
      {{:retry, 3_000}, _} = Retry.transition(Retry.new(), :server_gone)
      {{:retry, 3_000}, _} = Retry.transition(Retry.new(), {:close, 1013})
    end

    test "delay_ms with a huge attempt count stays capped" do
      state = %{Retry.new() | attempts: 40}
      assert Retry.delay_ms(state) == 30_000
    end
  end
end
