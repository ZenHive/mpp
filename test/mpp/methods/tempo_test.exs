defmodule MPP.Methods.TempoTest do
  use ExUnit.Case, async: true

  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.Methods.Tempo
  alias MPP.Receipt

  @rpc_url "https://rpc.moderato.tempo.xyz"
  @token_address "0x20C0000000000000000000000000000000000000"
  @recipient "0x1234567890AbcdEF1234567890aBcDeF12345678"
  @tx_hash "0x" <> String.duplicate("ab", 32)

  # ERC-20 Transfer(address,address,uint256) topic
  @transfer_topic "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

  # TIP-20 TransferWithMemo(address,address,uint256,bytes32) topic
  @transfer_with_memo_topic "0x57bc7354aa85aed339e000bccffabbc529466af35f0772c8f8ee1145927de7f0"

  @test_memo "0x" <> String.duplicate("ab", 32)

  setup do
    {:ok, charge} =
      Charge.new(
        amount: "1000000",
        currency: @token_address,
        recipient: @recipient
      )

    # Simulate what Plug does: merge method_config into charge.method_details
    charge = %{
      charge
      | method_details: %{
          "rpc_url" => @rpc_url,
          "chain_id" => 42_431,
          "req_options" => [plug: {Req.Test, Tempo}]
        }
    }

    {:ok, charge: charge}
  end

  describe "method_name/0" do
    test "returns \"tempo\"" do
      assert Tempo.method_name() == "tempo"
    end
  end

  describe "validate_config!/1" do
    test "returns :ok with valid config" do
      assert :ok = Tempo.validate_config!(%{"rpc_url" => @rpc_url})
    end

    test "raises on missing rpc_url" do
      assert_raise ArgumentError, ~r/rpc_url/, fn ->
        Tempo.validate_config!(%{})
      end
    end

    test "raises on nil rpc_url" do
      assert_raise ArgumentError, ~r/rpc_url/, fn ->
        Tempo.validate_config!(%{"rpc_url" => nil})
      end
    end

    test "accepts valid memo with 0x prefix" do
      memo = "0x" <> String.duplicate("ab", 32)
      assert :ok = Tempo.validate_config!(%{"rpc_url" => @rpc_url, "memo" => memo})
    end

    test "accepts valid memo without 0x prefix" do
      memo = String.duplicate("ab", 32)
      assert :ok = Tempo.validate_config!(%{"rpc_url" => @rpc_url, "memo" => memo})
    end

    test "accepts nil memo" do
      assert :ok = Tempo.validate_config!(%{"rpc_url" => @rpc_url, "memo" => nil})
    end

    test "raises on memo with wrong length" do
      assert_raise ArgumentError, ~r/32-byte hex string/, fn ->
        Tempo.validate_config!(%{"rpc_url" => @rpc_url, "memo" => "0xdead"})
      end
    end

    test "raises on memo with non-hex characters" do
      memo = "0x" <> String.duplicate("zz", 32)

      assert_raise ArgumentError, ~r/32-byte hex string/, fn ->
        Tempo.validate_config!(%{"rpc_url" => @rpc_url, "memo" => memo})
      end
    end

    test "raises on non-string memo" do
      assert_raise ArgumentError, ~r/32-byte hex string/, fn ->
        Tempo.validate_config!(%{"rpc_url" => @rpc_url, "memo" => 12_345})
      end
    end
  end

  describe "challenge_method_details/1" do
    test "returns chainId and feePayer with defaults", %{charge: charge} do
      charge = %{charge | method_details: %{"rpc_url" => @rpc_url}}
      details = Tempo.challenge_method_details(charge)

      assert details["chainId"] == 42_431
      assert details["feePayer"] == false
      refute Map.has_key?(details, "memo")
    end

    test "uses configured chain_id", %{charge: charge} do
      charge = %{charge | method_details: %{"chain_id" => 4217}}
      details = Tempo.challenge_method_details(charge)

      assert details["chainId"] == 4217
    end

    test "includes feePayer when configured", %{charge: charge} do
      charge = %{charge | method_details: %{"fee_payer" => true}}
      details = Tempo.challenge_method_details(charge)

      assert details["feePayer"] == true
    end

    test "includes memo when configured", %{charge: charge} do
      memo = "0x" <> String.duplicate("ab", 32)
      charge = %{charge | method_details: %{"memo" => memo}}
      details = Tempo.challenge_method_details(charge)

      assert details["memo"] == memo
    end

    test "omits memo when not configured", %{charge: charge} do
      details = Tempo.challenge_method_details(charge)

      refute Map.has_key?(details, "memo")
    end

    test "handles nil method_details" do
      {:ok, charge} = Charge.new(amount: "1000", currency: @token_address)
      details = Tempo.challenge_method_details(charge)

      assert details["chainId"] == 42_431
      assert details["feePayer"] == false
    end
  end

  describe "verify/2 — hash credential" do
    test "returns receipt on successful Transfer match", %{charge: charge} do
      stub_receipt(success_receipt())

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:ok, %Receipt{} = receipt} = Tempo.verify(payload, charge)
      assert receipt.method == "tempo"
      assert receipt.reference == @tx_hash
      assert receipt.status == "success"
      assert receipt.timestamp
    end

    test "returns error on missing hash field", %{charge: charge} do
      payload = %{"type" => "hash"}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "invalid-payload"
    end

    test "returns error on empty hash", %{charge: charge} do
      payload = %{"type" => "hash", "hash" => ""}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "invalid-payload"
    end

    test "returns error on invalid hash format", %{charge: charge} do
      payload = %{"type" => "hash", "hash" => "0xnothex"}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "invalid-payload"
    end

    test "returns error on missing type field", %{charge: charge} do
      payload = %{"hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "invalid-payload"
    end

    test "returns error for unsupported type", %{charge: charge} do
      payload = %{"type" => "unknown"}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "invalid-payload"
    end

    test "returns error when transaction not found", %{charge: charge} do
      stub_receipt_response(%{"jsonrpc" => "2.0", "result" => nil, "id" => 1})

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "not found"
    end

    test "returns error when transaction reverted", %{charge: charge} do
      stub_receipt(reverted_receipt())

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "reverted"
    end

    test "returns error when amount mismatches", %{charge: charge} do
      # Receipt has transfer for 999999 instead of 1000000
      receipt = success_receipt(amount: 999_999)
      stub_receipt(receipt)

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "No matching Transfer"
    end

    test "returns error when recipient mismatches", %{charge: charge} do
      receipt = success_receipt(to: "0x0000000000000000000000000000000000000000")
      stub_receipt(receipt)

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
    end

    test "returns error when token mismatches", %{charge: charge} do
      receipt = success_receipt(token: "0x0000000000000000000000000000000000000001")
      stub_receipt(receipt)

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
    end

    test "returns error when no Transfer events in logs", %{charge: charge} do
      receipt = success_receipt(logs: [])
      stub_receipt(receipt)

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
    end

    test "returns error on RPC error response", %{charge: charge} do
      stub_receipt_response(%{
        "jsonrpc" => "2.0",
        "error" => %{"code" => -32_000, "message" => "internal error"},
        "id" => 1
      })

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "RPC error"
    end

    test "returns error on network failure", %{charge: charge} do
      Req.Test.stub(Tempo, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "request failed"
    end

    test "returns error on unexpected RPC response body", %{charge: charge} do
      Req.Test.stub(Tempo, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"oops" => true})
      end)

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "Unexpected RPC response"
    end

    test "returns not-implemented for transaction type", %{charge: charge} do
      payload = %{"type" => "transaction", "signature" => "0xdeadbeef"}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "not yet implemented"
    end

    test "preserves external_id in receipt", %{charge: charge} do
      charge = %{charge | external_id: "order-42"}
      stub_receipt(success_receipt())

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:ok, %Receipt{} = receipt} = Tempo.verify(payload, charge)
      assert receipt.external_id == "order-42"
    end

    test "returns error on non-numeric charge amount", %{charge: charge} do
      charge = %{charge | amount: "not_a_number"}
      stub_receipt(success_receipt())

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "not a valid integer"
    end

    test "verifies RPC request body contains correct method and hash", %{charge: charge} do
      test_pid = self()

      Req.Test.stub(Tempo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:rpc_request, Jason.decode!(body)})
        Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => success_receipt(), "id" => 1})
      end)

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:ok, %Receipt{}} = Tempo.verify(payload, charge)

      assert_received {:rpc_request, request}
      assert request["method"] == "eth_getTransactionReceipt"
      assert request["params"] == [@tx_hash]
    end
  end

  describe "verify/2 — memo enforcement" do
    setup %{charge: charge} do
      # Add memo to method_details
      charge = %{
        charge
        | method_details: Map.put(charge.method_details, "memo", @test_memo)
      }

      {:ok, charge: charge}
    end

    test "returns receipt when TransferWithMemo matches with correct memo", %{charge: charge} do
      receipt = success_receipt(logs: [transfer_with_memo_log(memo: @test_memo)])
      stub_receipt(receipt)

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:ok, %Receipt{} = receipt} = Tempo.verify(payload, charge)
      assert receipt.method == "tempo"
    end

    test "returns error when only plain Transfer event (memo configured)", %{charge: charge} do
      stub_receipt(success_receipt())

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "TransferWithMemo"
    end

    test "returns error when TransferWithMemo has wrong memo", %{charge: charge} do
      wrong_memo = "0x" <> String.duplicate("cd", 32)
      receipt = success_receipt(logs: [transfer_with_memo_log(memo: wrong_memo)])
      stub_receipt(receipt)

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "TransferWithMemo"
    end

    test "accepts TransferWithMemo when no memo configured (no-memo path)", %{charge: charge} do
      # Remove memo from config
      charge = %{
        charge
        | method_details: Map.delete(charge.method_details, "memo")
      }

      receipt = success_receipt(logs: [transfer_with_memo_log(memo: @test_memo)])
      stub_receipt(receipt)

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:ok, %Receipt{}} = Tempo.verify(payload, charge)
    end
  end

  # --- Test helpers ---

  # Stubs a successful JSON-RPC response wrapping the given receipt map.
  defp stub_receipt(receipt) do
    stub_receipt_response(%{"jsonrpc" => "2.0", "result" => receipt, "id" => 1})
  end

  # Stubs a raw JSON-RPC response body.
  defp stub_receipt_response(response_body) do
    Req.Test.stub(Tempo, fn conn ->
      Req.Test.json(conn, response_body)
    end)
  end

  # Builds a successful receipt with a matching Transfer log.
  # Override individual fields with opts.
  defp success_receipt(opts \\ []) do
    amount = Keyword.get(opts, :amount, 1_000_000)
    to = Keyword.get(opts, :to, @recipient)
    token = Keyword.get(opts, :token, @token_address)

    default_logs = [transfer_log(amount: amount, to: to, token: token)]
    logs = Keyword.get(opts, :logs, default_logs)

    %{
      "status" => "0x1",
      "transactionHash" => @tx_hash,
      "blockNumber" => "0x1a",
      "blockHash" => "0x" <> String.duplicate("00", 32),
      "logs" => logs
    }
  end

  # Builds a reverted receipt (status 0x0).
  defp reverted_receipt do
    %{success_receipt() | "status" => "0x0"}
  end

  # Builds a raw ERC-20 Transfer log entry matching JSON-RPC format.
  defp transfer_log(opts) do
    amount = Keyword.get(opts, :amount, 1_000_000)
    from = Keyword.get(opts, :from, "0x" <> String.duplicate("00", 20))
    to = Keyword.get(opts, :to, @recipient)
    token = Keyword.get(opts, :token, @token_address)

    # ERC-20 Transfer: 3 topics [topic0, from_padded, to_padded] + value in data
    from_padded = "0x" <> String.pad_leading(strip_0x(from), 64, "0")
    to_padded = "0x" <> String.pad_leading(strip_0x(to), 64, "0")
    data = "0x" <> String.pad_leading(Integer.to_string(amount, 16), 64, "0")

    %{
      "address" => token,
      "topics" => [@transfer_topic, from_padded, to_padded],
      "data" => data,
      "blockNumber" => "0x1a",
      "transactionHash" => @tx_hash,
      "logIndex" => "0x0"
    }
  end

  # Builds a raw TIP-20 TransferWithMemo log entry matching JSON-RPC format.
  # TransferWithMemo(address indexed from, address indexed to, uint256 amount, bytes32 memo)
  defp transfer_with_memo_log(opts) do
    amount = Keyword.get(opts, :amount, 1_000_000)
    from = Keyword.get(opts, :from, "0x" <> String.duplicate("00", 20))
    to = Keyword.get(opts, :to, @recipient)
    token = Keyword.get(opts, :token, @token_address)
    memo = Keyword.get(opts, :memo, @test_memo)

    from_padded = "0x" <> String.pad_leading(strip_0x(from), 64, "0")
    to_padded = "0x" <> String.pad_leading(strip_0x(to), 64, "0")

    # Data contains amount (uint256) + memo (bytes32), each 32 bytes
    amount_hex = String.pad_leading(Integer.to_string(amount, 16), 64, "0")
    memo_hex = String.pad_leading(strip_0x(memo), 64, "0")
    data = "0x" <> amount_hex <> memo_hex

    %{
      "address" => token,
      "topics" => [@transfer_with_memo_topic, from_padded, to_padded],
      "data" => data,
      "blockNumber" => "0x1a",
      "transactionHash" => @tx_hash,
      "logIndex" => "0x0"
    }
  end

  defp strip_0x("0x" <> rest), do: rest
  defp strip_0x(hex), do: hex
end
