defmodule MPP.Methods.Tempo.BroadcastTest do
  use ExUnit.Case, async: true

  alias MPP.Methods.Tempo.Broadcast

  @rpc_url "https://rpc.moderato.tempo.xyz"
  @raw "0x76c0"
  @hash "0x" <> String.duplicate("cd", 32)
  @receipt %{"transactionHash" => @hash, "status" => "0x1", "logs" => []}

  defp opts(extra \\ []) do
    Keyword.merge([req_options: [plug: {Req.Test, __MODULE__}], timeout_ms: 200, interval_ms: 5], extra)
  end

  # `send` answers the send call; each receipt lookup answers `receipt.()` and reports itself.
  defp stub(send, receipt \\ fn -> nil end) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case Jason.decode!(body)["method"] do
        "eth_getTransactionReceipt" ->
          send(test_pid, :lookup)
          Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => receipt.(), "id" => 1})

        _send ->
          send.(conn)
      end
    end)
  end

  defp rpc_error(code, message),
    do: &Req.Test.json(&1, %{"jsonrpc" => "2.0", "error" => %{"code" => code, "message" => message}, "id" => 1})

  defp lookups(count \\ 0) do
    receive do
      :lookup -> lookups(count + 1)
    after
      0 -> count
    end
  end

  describe "send_sync/4" do
    test "returns the receipt the node answers with, without a lookup" do
      stub(&Req.Test.json(&1, %{"jsonrpc" => "2.0", "result" => @receipt, "id" => 1}))
      assert {:ok, @hash, %{status: _}} = Broadcast.send_sync(@raw, @hash, @rpc_url, opts())
      assert lookups() == 0
    end

    test "a definitive rejection is final" do
      for answer <- [
            rpc_error(-32_003, "insufficient funds for gas"),
            &(&1 |> Plug.Conn.put_status(400) |> Req.Test.json(%{"oops" => true}))
          ] do
        stub(answer)
        assert {:error, :rejected} = Broadcast.send_sync(@raw, @hash, @rpc_url, opts())
        assert lookups() == 0
      end
    end

    test "nonce too low makes exactly one lookup" do
      stub(rpc_error(-32_000, "nonce too low: next nonce 1, tx nonce 0"))
      assert {:error, :rejected} = Broadcast.send_sync(@raw, @hash, @rpc_url, opts())
      assert lookups() == 1

      stub(rpc_error(-32_000, "nonce too low"), fn -> @receipt end)
      assert {:ok, @hash, _receipt} = Broadcast.send_sync(@raw, @hash, @rpc_url, opts())
    end

    test "an ambiguous answer polls until the confirmation budget ends" do
      stub(&Req.Test.transport_error(&1, :timeout))
      started = System.monotonic_time(:millisecond)
      assert {:error, :unresolved} = Broadcast.send_sync(@raw, @hash, @rpc_url, opts())
      assert System.monotonic_time(:millisecond) - started >= 200
      assert lookups() > 1
    end

    test "a success answer without a receipt is ambiguous" do
      stub(&Req.Test.json(&1, %{"jsonrpc" => "2.0", "result" => nil, "id" => 1}), fn -> @receipt end)
      assert {:ok, @hash, _receipt} = Broadcast.send_sync(@raw, @hash, @rpc_url, opts())
    end

    test "an HTTP 5xx is ambiguous even with a JSON-RPC error body" do
      stub(
        &(&1 |> Plug.Conn.put_status(503) |> Req.Test.json(%{"jsonrpc" => "2.0", "error" => "upstream timeout"})),
        fn -> @receipt end
      )

      assert {:ok, @hash, _receipt} = Broadcast.send_sync(@raw, @hash, @rpc_url, opts())
    end

    test "a stalled send or lookup cannot outlast the confirmation budget" do
      stall = fn conn ->
        Process.sleep(2_000)
        Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => nil, "id" => 1})
      end

      Req.Test.stub(__MODULE__, stall)
      started = System.monotonic_time(:millisecond)
      assert {:error, :unresolved} = Broadcast.send_sync(@raw, @hash, @rpc_url, opts(timeout_ms: 150))
      assert System.monotonic_time(:millisecond) - started < 600

      started = System.monotonic_time(:millisecond)
      assert {:error, :unresolved} = Broadcast.send_async(@raw, @hash, @rpc_url, opts(timeout_ms: 150))
      assert System.monotonic_time(:millisecond) - started < 600
    end

    test "a passed validBefore ends polling at once with one final lookup" do
      stub(&Req.Test.transport_error(&1, :timeout))
      clock = fn -> 1_000_000_000 end

      assert {:error, :unresolved} =
               Broadcast.send_sync(@raw, @hash, @rpc_url, opts(timeout_ms: 60_000, valid_before: 900_000, clock: clock))

      assert lookups() == 2
    end

    test "a failed lookup leaves the outcome open" do
      Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))
      assert {:error, :unresolved} = Broadcast.send_sync(@raw, @hash, @rpc_url, opts())
    end
  end

  describe "send_async/4" do
    test "returns the node's hash" do
      stub(&Req.Test.json(&1, %{"jsonrpc" => "2.0", "result" => @hash, "id" => 1}))
      assert {:ok, @hash} = Broadcast.send_async(@raw, @hash, @rpc_url, opts())
      assert lookups() == 0
    end

    test "a definitive rejection is final" do
      for answer <- [
            rpc_error(-32_003, "insufficient funds for gas"),
            &Req.Test.json(&1, %{"error" => %{"code" => -32_602}})
          ] do
        stub(answer)
        assert {:error, :rejected} = Broadcast.send_async(@raw, @hash, @rpc_url, opts())
        assert lookups() == 0
      end
    end

    test "a success answer without a hash or without a result is ambiguous" do
      for answer <- [
            &Req.Test.json(&1, %{"jsonrpc" => "2.0", "result" => 7, "id" => 1}),
            &Req.Test.json(&1, %{"jsonrpc" => "2.0", "id" => 1})
          ] do
        stub(answer, fn -> @receipt end)
        assert {:ok, @hash, _receipt} = Broadcast.send_async(@raw, @hash, @rpc_url, opts())
      end
    end

    test "an ambiguous answer makes one lookup" do
      stub(rpc_error(-32_000, "expiring nonce transaction already included"))
      assert {:error, :unresolved} = Broadcast.send_async(@raw, @hash, @rpc_url, opts())
      assert lookups() == 1

      stub(rpc_error(4, "timeout"), fn -> @receipt end)
      assert {:ok, @hash, %{status: _}} = Broadcast.send_async(@raw, @hash, @rpc_url, opts())
    end
  end

  describe "already_held?/1" do
    test "matches the messages of a node that already holds the transaction" do
      for message <- [
            "already known",
            "AlreadyKnown",
            "known transaction: 0xab",
            "ExpiringNonceReplay",
            "expiring nonce transaction already included"
          ] do
        assert Broadcast.already_held?(message), message
      end

      refute Broadcast.already_held?("nonce too low")
      refute Broadcast.already_held?("unknown transaction type")
    end
  end
end
