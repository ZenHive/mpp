defmodule MPP.Methods.TempoTest do
  use ExUnit.Case, async: true

  import MPP.Test.TempoTestHelpers

  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.Methods.Tempo
  alias MPP.Receipt
  alias MPP.Test.TempoMemoryStore
  alias MPP.Test.TempoTxBuilder

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

    test "rejects transaction with invalid hex in signature field", %{charge: charge} do
      payload = %{"type" => "transaction", "signature" => "0xdeadbeef"}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "Not a Tempo transaction"
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

  describe "verify/2 — transaction credential" do
    setup %{charge: charge} do
      # Build a valid 0x76 transaction with a transfer call matching the charge
      calldata = transfer_calldata(@recipient, 1_000_000)
      call = build_call(@token_address, calldata)

      tx_hex = build_tempo_tx(calls: [call], chain_id: 42_431)
      {:ok, tx_hex: tx_hex, charge: charge}
    end

    test "returns receipt on valid transaction credential", %{charge: charge, tx_hex: tx_hex} do
      stub_broadcast_and_receipt(success_receipt())

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:ok, %Receipt{} = receipt} = Tempo.verify(payload, charge)
      assert receipt.method == "tempo"
      assert receipt.status == "success"
    end

    test "preserves external_id in transaction receipt", %{charge: charge, tx_hex: tx_hex} do
      charge = %{charge | external_id: "tx-order-99"}
      stub_broadcast_and_receipt(success_receipt())

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:ok, %Receipt{} = receipt} = Tempo.verify(payload, charge)
      assert receipt.external_id == "tx-order-99"
    end

    test "returns error on missing signature field", %{charge: charge} do
      payload = %{"type" => "transaction"}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "invalid-payload"
      assert error.detail =~ "signature"
    end

    test "returns error on empty signature field", %{charge: charge} do
      payload = %{"type" => "transaction", "signature" => ""}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "invalid-payload"
      assert error.detail =~ "signature"
    end

    test "returns error on chain_id mismatch", %{charge: charge} do
      # Build tx with wrong chain_id
      calldata = transfer_calldata(@recipient, 1_000_000)
      call = build_call(@token_address, calldata)
      wrong_chain_tx = build_tempo_tx(calls: [call], chain_id: 9999)

      payload = %{"type" => "transaction", "signature" => wrong_chain_tx}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "Chain ID mismatch"
    end

    test "returns error when no matching transfer call", %{charge: charge} do
      # Build tx with transfer to wrong recipient
      wrong_recipient = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
      calldata = transfer_calldata(wrong_recipient, 1_000_000)
      call = build_call(@token_address, calldata)
      bad_tx = build_tempo_tx(calls: [call], chain_id: 42_431)

      payload = %{"type" => "transaction", "signature" => bad_tx}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "No matching transfer call"
    end

    test "returns error on broadcast failure", %{charge: charge, tx_hex: tx_hex} do
      Req.Test.stub(Tempo, fn conn ->
        Req.Test.json(conn, %{
          "jsonrpc" => "2.0",
          "error" => %{"code" => -32_000, "message" => "nonce too low"},
          "id" => 1
        })
      end)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "Broadcast failed"
    end

    test "returns error when transaction reverts on-chain", %{charge: charge, tx_hex: tx_hex} do
      stub_broadcast_and_receipt(reverted_receipt())

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "reverted"
    end

    test "returns error on non-0x76 transaction", %{charge: charge} do
      # Build something that starts with 0x02 (EIP-1559)
      body = ExRLP.encode([<<1>>, <<>>, <<>>, <<>>, [], [], <<>>, <<>>, <<>>])
      bad_hex = "0x02" <> Base.encode16(body, case: :lower)

      payload = %{"type" => "transaction", "signature" => bad_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "Not a Tempo transaction"
    end

    test "sends raw hex via eth_sendRawTransactionSync and uses receipt tx hash", %{charge: charge, tx_hex: tx_hex} do
      test_pid = self()

      Req.Test.stub(Tempo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)
        send(test_pid, {:rpc_call, request["method"], request["params"]})

        # eth_sendRawTransactionSync returns the full receipt directly
        Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => success_receipt(), "id" => 1})
      end)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:ok, %Receipt{} = receipt} = Tempo.verify(payload, charge)
      assert receipt.reference == @tx_hash

      # Verify the sync RPC method was called with raw tx hex
      assert_received {:rpc_call, "eth_sendRawTransactionSync", [sent_hex]}
      assert sent_hex == tx_hex

      # Verify NO separate receipt fetch was made (sync returns receipt directly)
      refute_received {:rpc_call, "eth_getTransactionReceipt", _}
    end

    test "returns receipt on valid transferWithMemo transaction when memo configured", %{charge: charge} do
      charge = %{charge | method_details: Map.put(charge.method_details, "memo", @test_memo)}

      calldata = transfer_with_memo_calldata(@recipient, 1_000_000, @test_memo)
      call = build_call(@token_address, calldata)
      tx_hex = build_tempo_tx(calls: [call], chain_id: 42_431)

      receipt = success_receipt(logs: [transfer_with_memo_log(memo: @test_memo)])
      stub_broadcast_and_receipt(receipt)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:ok, %Receipt{} = receipt} = Tempo.verify(payload, charge)
      assert receipt.reference == @tx_hash
    end

    test "returns error on broadcast network failure", %{charge: charge, tx_hex: tx_hex} do
      Req.Test.stub(Tempo, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "Broadcast request failed"
    end

    test "returns error on unexpected broadcast response body", %{charge: charge, tx_hex: tx_hex} do
      Req.Test.stub(Tempo, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"oops" => true})
      end)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "Unexpected broadcast response"
    end
  end

  describe "verify/2 — optimistic broadcast (wait_for_confirmation: false)" do
    setup %{charge: charge} do
      # Enable optimistic mode
      charge = %{
        charge
        | method_details: Map.put(charge.method_details, "wait_for_confirmation", false)
      }

      # Build a valid 0x76 transaction with a transfer call matching the charge
      calldata = transfer_calldata(@recipient, 1_000_000)
      call = build_call(@token_address, calldata)
      tx_hex = build_tempo_tx(calls: [call], chain_id: 42_431)

      {:ok, charge: charge, tx_hex: tx_hex}
    end

    test "returns optimistic receipt after simulation + async broadcast", %{charge: charge, tx_hex: tx_hex} do
      stub_optimistic_flow(@tx_hash)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:ok, %Receipt{} = receipt} = Tempo.verify(payload, charge)
      assert receipt.method == "tempo"
      assert receipt.status == "success"
      assert receipt.reference == @tx_hash
    end

    test "preserves external_id in optimistic receipt", %{charge: charge, tx_hex: tx_hex} do
      charge = %{charge | external_id: "optimistic-order-1"}
      stub_optimistic_flow(@tx_hash)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:ok, %Receipt{} = receipt} = Tempo.verify(payload, charge)
      assert receipt.external_id == "optimistic-order-1"
    end

    test "returns error when simulation fails (never broadcasts)", %{charge: charge, tx_hex: tx_hex} do
      test_pid = self()

      Req.Test.stub(Tempo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)
        send(test_pid, {:rpc_call, request["method"]})

        case request["method"] do
          "eth_call" ->
            Req.Test.json(conn, %{
              "jsonrpc" => "2.0",
              "error" => %{"code" => -32_000, "message" => "execution reverted"},
              "id" => 1
            })

          _ ->
            Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => nil, "id" => 1})
        end
      end)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "Simulation failed"

      # Verify simulation was called but broadcast was NOT
      assert_received {:rpc_call, "eth_call"}
      refute_received {:rpc_call, "eth_sendRawTransaction"}
    end

    test "returns error when async broadcast fails after successful simulation", %{charge: charge, tx_hex: tx_hex} do
      Req.Test.stub(Tempo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        case request["method"] do
          "eth_call" ->
            Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => "0x", "id" => 1})

          "eth_sendRawTransaction" ->
            Req.Test.json(conn, %{
              "jsonrpc" => "2.0",
              "error" => %{"code" => -32_000, "message" => "nonce too low"},
              "id" => 1
            })
        end
      end)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "Broadcast failed"
    end

    test "calls eth_call then eth_sendRawTransaction (not sync variant)", %{charge: charge, tx_hex: tx_hex} do
      test_pid = self()

      Req.Test.stub(Tempo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)
        send(test_pid, {:rpc_call, request["method"], request["params"]})

        case request["method"] do
          "eth_call" ->
            Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => "0x", "id" => 1})

          "eth_sendRawTransaction" ->
            Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => @tx_hash, "id" => 1})
        end
      end)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:ok, %Receipt{}} = Tempo.verify(payload, charge)

      # Verify the correct RPC methods were called with the raw tx
      assert_received {:rpc_call, "eth_call", _}
      assert_received {:rpc_call, "eth_sendRawTransaction", [sent_hex]}
      assert sent_hex == tx_hex

      # Verify sync variant was NOT called
      refute_received {:rpc_call, "eth_sendRawTransactionSync", _}
    end

    test "simulation network failure returns error", %{charge: charge, tx_hex: tx_hex} do
      Req.Test.stub(Tempo, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "Simulation request failed"
    end

    test "async broadcast network failure returns error", %{charge: charge, tx_hex: tx_hex} do
      Req.Test.stub(Tempo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        case request["method"] do
          "eth_call" ->
            # Simulation succeeds
            Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => "0x", "id" => 1})

          "eth_sendRawTransaction" ->
            # Broadcast hits network error
            Req.Test.transport_error(conn, :econnrefused)
        end
      end)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "Broadcast request failed"
    end

    test "async broadcast unexpected response status returns error", %{charge: charge, tx_hex: tx_hex} do
      Req.Test.stub(Tempo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        case request["method"] do
          "eth_call" ->
            Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => "0x", "id" => 1})

          "eth_sendRawTransaction" ->
            # Return 503 with no error/result fields
            conn
            |> Plug.Conn.put_status(503)
            |> Req.Test.json(%{"jsonrpc" => "2.0", "id" => 1})
        end
      end)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "Unexpected broadcast response"
    end
  end

  describe "verify/2 — dedup store" do
    setup %{charge: charge} do
      start_supervised!(TempoMemoryStore)

      charge = %{
        charge
        | method_details: Map.put(charge.method_details, "store", TempoMemoryStore)
      }

      {:ok, charge: charge}
    end

    test "hash path rejects replay of already-used hash", %{charge: charge} do
      stub_receipt(success_receipt())

      payload = %{"type" => "hash", "hash" => @tx_hash}

      # First call succeeds
      assert {:ok, %Receipt{}} = Tempo.verify(payload, charge)

      # Second call with same hash is rejected
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "already used"
    end

    test "transaction path rejects replay of already-used signed tx", %{charge: charge} do
      calldata = transfer_calldata(@recipient, 1_000_000)
      call = build_call(@token_address, calldata)
      tx_hex = build_tempo_tx(calls: [call], chain_id: 42_431)

      stub_broadcast_and_receipt(success_receipt())

      payload = %{"type" => "transaction", "signature" => tx_hex}

      # First call succeeds
      assert {:ok, %Receipt{}} = Tempo.verify(payload, charge)

      # Second call with same signed tx is rejected before broadcast
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "already used"
    end

    test "hash path allows retry after transient RPC failure", %{charge: charge} do
      # First attempt: RPC returns error (transient failure)
      stub_receipt_response(%{"jsonrpc" => "2.0", "error" => %{"code" => -32_000, "message" => "timeout"}, "id" => 1})

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{}} = Tempo.verify(payload, charge)

      # Hash should NOT be burned — store should have no entry
      expected_key = "mpp:charge:" <> String.downcase(@tx_hash)
      assert :not_found = TempoMemoryStore.get(expected_key)

      # Second attempt: RPC succeeds — retry should work
      stub_receipt(success_receipt())
      assert {:ok, %Receipt{}} = Tempo.verify(payload, charge)

      # Now the hash IS marked
      assert {:ok, _timestamp} = TempoMemoryStore.get(expected_key)
    end

    test "hash path records key in store after success", %{charge: charge} do
      stub_receipt(success_receipt())

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:ok, %Receipt{}} = Tempo.verify(payload, charge)

      expected_key = "mpp:charge:" <> String.downcase(@tx_hash)
      assert {:ok, _timestamp} = TempoMemoryStore.get(expected_key)
    end

    test "post-broadcast dedup records on-chain hash when it differs from input", %{charge: charge} do
      # Stub broadcast to return a DIFFERENT tx hash than the input
      different_on_chain_hash = "0x" <> String.duplicate("cd", 32)

      Req.Test.stub(Tempo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        "eth_sendRawTransactionSync" = request["method"]
        receipt = %{success_receipt() | "transactionHash" => different_on_chain_hash}
        Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => receipt, "id" => 1})
      end)

      calldata = transfer_calldata(@recipient, 1_000_000)
      call = build_call(@token_address, calldata)
      tx_hex = build_tempo_tx(calls: [call], chain_id: 42_431)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:ok, %Receipt{}} = Tempo.verify(payload, charge)

      # Both the input hex and the on-chain hash should be recorded
      input_key = "mpp:charge:" <> String.downcase(tx_hex)
      onchain_key = "mpp:charge:" <> String.downcase(different_on_chain_hash)
      assert {:ok, _} = TempoMemoryStore.get(input_key)
      assert {:ok, _} = TempoMemoryStore.get(onchain_key)
    end

    test "store get error surfaces as verification_failed", %{charge: charge} do
      # Override store with a failing module
      defmodule FailingStore do
        @moduledoc false
        @behaviour Store

        def get(_key), do: {:error, :connection_refused}
        def put(_key, _value), do: :ok
      end

      charge = %{
        charge
        | method_details: Map.put(charge.method_details, "store", FailingStore)
      }

      stub_receipt(success_receipt())

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "Dedup store error"
    end

    test "concurrent requests with same signed tx — only one succeeds", %{charge: charge} do
      calldata = transfer_calldata(@recipient, 1_000_000)
      call = build_call(@token_address, calldata)
      tx_hex = build_tempo_tx(calls: [call], chain_id: 42_431)

      stub_broadcast_and_receipt(success_receipt())

      payload = %{"type" => "transaction", "signature" => tx_hex}

      # Fire two concurrent verify calls with identical signed tx
      tasks =
        for _ <- 1..2 do
          Task.async(fn -> Tempo.verify(payload, charge) end)
        end

      results = Task.await_many(tasks)

      ok_count = Enum.count(results, &match?({:ok, _}, &1))
      error_count = Enum.count(results, &match?({:error, _}, &1))

      assert ok_count == 1, "Expected exactly 1 success, got #{ok_count}: #{inspect(results)}"
      assert error_count == 1, "Expected exactly 1 rejection, got #{error_count}: #{inspect(results)}"

      # The rejected one should cite "already used"
      [{:error, %Errors{} = error}] =
        Enum.filter(results, &match?({:error, _}, &1))

      assert error.detail =~ "already used"
    end

    test "post-broadcast store.put crash does not fail the request", %{charge: charge} do
      # Store that succeeds on check_and_mark but raises on put (post-broadcast path)
      defmodule CrashingPutStore do
        @moduledoc false
        @behaviour Store

        use Agent

        def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

        def get(key) do
          case Agent.get(__MODULE__, &Map.get(&1, key)) do
            nil -> :not_found
            value -> {:ok, value}
          end
        end

        def put(_key, _value), do: raise("store crashed!")

        def check_and_mark(key, value) do
          Agent.get_and_update(__MODULE__, fn state ->
            if Map.has_key?(state, key) do
              {{:error, :already_exists}, state}
            else
              {:ok, Map.put(state, key, value)}
            end
          end)
        end
      end

      start_supervised!(CrashingPutStore)

      charge = %{
        charge
        | method_details: Map.put(charge.method_details, "store", CrashingPutStore)
      }

      # Broadcast returns a DIFFERENT hash to trigger safe_dedup_post_broadcast
      different_hash = "0x" <> String.duplicate("ef", 32)

      Req.Test.stub(Tempo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        "eth_sendRawTransactionSync" = request["method"]
        receipt = %{success_receipt() | "transactionHash" => different_hash}
        Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => receipt, "id" => 1})
      end)

      calldata = transfer_calldata(@recipient, 1_000_000)
      call = build_call(@token_address, calldata)
      tx_hex = build_tempo_tx(calls: [call], chain_id: 42_431)

      payload = %{"type" => "transaction", "signature" => tx_hex}

      # Should succeed despite post-broadcast store.put raising
      assert {:ok, %Receipt{reference: ^different_hash}} = Tempo.verify(payload, charge)
    end

    test "post-broadcast dead store process does not fail the request", %{charge: charge} do
      # Store with a real Agent for check_and_mark, but we kill it before post-broadcast
      defmodule DeadProcessStore do
        @moduledoc false
        @behaviour MPP.Tempo.Store

        use Agent

        def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

        def get(key) do
          case Agent.get(__MODULE__, &Map.get(&1, key)) do
            nil -> :not_found
            value -> {:ok, value}
          end
        end

        def put(_key, _value), do: Agent.update(__MODULE__, & &1)

        def check_and_mark(key, value) do
          Agent.get_and_update(__MODULE__, fn state ->
            if Map.has_key?(state, key) do
              {{:error, :already_exists}, state}
            else
              {:ok, Map.put(state, key, value)}
            end
          end)
        end
      end

      start_supervised!(DeadProcessStore)

      charge = %{
        charge
        | method_details: Map.put(charge.method_details, "store", DeadProcessStore)
      }

      # Broadcast returns a DIFFERENT hash to trigger safe_dedup_post_broadcast
      different_hash = "0x" <> String.duplicate("de", 32)

      Req.Test.stub(Tempo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        "eth_sendRawTransactionSync" = request["method"]

        # Kill the store process AFTER broadcast succeeds but before post-broadcast dedup runs.
        # We can't time it precisely, so we kill it here — the post-broadcast put will hit a dead process.
        Agent.stop(DeadProcessStore)

        receipt = %{success_receipt() | "transactionHash" => different_hash}
        Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => receipt, "id" => 1})
      end)

      calldata = transfer_calldata(@recipient, 1_000_000)
      call = build_call(@token_address, calldata)
      tx_hex = build_tempo_tx(calls: [call], chain_id: 42_431)

      payload = %{"type" => "transaction", "signature" => tx_hex}

      # Should succeed despite post-broadcast store process being dead (catch :exit)
      assert {:ok, %Receipt{reference: ^different_hash}} = Tempo.verify(payload, charge)
    end

    test "validate_config! rejects invalid store module" do
      assert_raise ArgumentError, ~r/must be a module implementing/, fn ->
        Tempo.validate_config!(%{"rpc_url" => "https://example.com", "store" => :not_a_real_module})
      end

      assert_raise ArgumentError, ~r/must be a module implementing/, fn ->
        Tempo.validate_config!(%{"rpc_url" => "https://example.com", "store" => "not_a_module"})
      end
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

  describe "validate_config!/1 — fee payer" do
    @fee_payer_key String.duplicate("ab", 32)
    @fee_payer_token "0x20C0000000000000000000000000000000000000"

    test "accepts valid fee payer config" do
      assert :ok =
               Tempo.validate_config!(%{
                 "rpc_url" => @rpc_url,
                 "fee_payer" => true,
                 "fee_payer_private_key" => @fee_payer_key,
                 "fee_token" => @fee_payer_token
               })
    end

    test "raises when fee_payer true but missing fee_payer_private_key" do
      assert_raise ArgumentError, ~r/fee_payer_private_key/, fn ->
        Tempo.validate_config!(%{
          "rpc_url" => @rpc_url,
          "fee_payer" => true,
          "fee_token" => @fee_payer_token
        })
      end
    end

    test "raises when fee_payer true but missing fee_token" do
      assert_raise ArgumentError, ~r/fee_token/, fn ->
        Tempo.validate_config!(%{
          "rpc_url" => @rpc_url,
          "fee_payer" => true,
          "fee_payer_private_key" => @fee_payer_key
        })
      end
    end

    test "raises on invalid fee_payer_private_key (wrong length)" do
      assert_raise ArgumentError, ~r/fee_payer_private_key/, fn ->
        Tempo.validate_config!(%{
          "rpc_url" => @rpc_url,
          "fee_payer" => true,
          "fee_payer_private_key" => "deadbeef",
          "fee_token" => @fee_payer_token
        })
      end
    end

    test "raises on invalid fee_token (wrong length)" do
      assert_raise ArgumentError, ~r/fee_token/, fn ->
        Tempo.validate_config!(%{
          "rpc_url" => @rpc_url,
          "fee_payer" => true,
          "fee_payer_private_key" => @fee_payer_key,
          "fee_token" => "0xdead"
        })
      end
    end

    test "skips fee payer validation when fee_payer is false" do
      assert :ok = Tempo.validate_config!(%{"rpc_url" => @rpc_url, "fee_payer" => false})
    end

    test "skips fee payer validation when fee_payer is absent" do
      assert :ok = Tempo.validate_config!(%{"rpc_url" => @rpc_url})
    end
  end

  describe "verify/2 — hash + fee_payer rejection" do
    test "rejects type=hash when fee_payer is true", %{charge: charge} do
      charge = %{charge | method_details: Map.put(charge.method_details, "fee_payer", true)}

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "invalid-payload"
      assert error.detail =~ "hash"
      assert error.detail =~ "feePayer"
    end

    test "allows type=hash when fee_payer is false", %{charge: charge} do
      stub_receipt(success_receipt())
      charge = %{charge | method_details: Map.put(charge.method_details, "fee_payer", false)}

      payload = %{"type" => "hash", "hash" => @tx_hash}
      assert {:ok, %Receipt{}} = Tempo.verify(payload, charge)
    end
  end

  describe "verify/2 — fee payer co-signing" do
    # Hardhat default test keys (testnet only, no security concern).
    @client_private_key "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
    @fee_payer_private_key "59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
    @fee_token_address "0x20C0000000000000000000000000000000000000"

    setup %{charge: charge} do
      charge = %{
        charge
        | method_details:
            Map.merge(charge.method_details, %{
              "fee_payer" => true,
              "fee_payer_private_key" => @fee_payer_private_key,
              "fee_token" => @fee_token_address
            })
      }

      {:ok, charge: charge}
    end

    test "co-signs and broadcasts fee payer transaction", %{charge: charge} do
      # Build a real signed tx with fee payer placeholder using TempoTxBuilder
      {:ok, tx_hex} =
        TempoTxBuilder.build_fee_payer_transfer(
          private_key: @client_private_key,
          token: @token_address,
          recipient: @recipient,
          amount: 1_000_000,
          chain_id: 42_431,
          rpc_url: @rpc_url,
          nonce: 0
        )

      # Stub broadcast — server will co-sign then broadcast the modified tx
      test_pid = self()

      Req.Test.stub(Tempo, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)
        send(test_pid, {:rpc_call, request["method"], request["params"]})
        Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => success_receipt(), "id" => 1})
      end)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:ok, %Receipt{} = receipt} = Tempo.verify(payload, charge)
      assert receipt.method == "tempo"
      assert receipt.status == "success"

      # Verify the broadcast used a DIFFERENT hex than the original (co-signed version)
      assert_received {:rpc_call, "eth_sendRawTransactionSync", [broadcast_hex]}
      assert broadcast_hex != tx_hex
      assert String.starts_with?(broadcast_hex, "0x76")
    end

    test "rejects transaction without fee_payer_signature placeholder", %{charge: charge} do
      # Build a normal tx (no fee payer placeholder)
      calldata = transfer_calldata(@recipient, 1_000_000)
      call = build_call(@token_address, calldata)
      tx_hex = build_tempo_tx(calls: [call], chain_id: 42_431, fee_payer: false)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "placeholder"
    end

    test "rejects transaction with non-empty fee_token", %{charge: charge} do
      # Build a tx with fee_payer placeholder but with fee_token set
      # (client shouldn't set fee_token when requesting fee sponsorship)
      calldata = transfer_calldata(@recipient, 1_000_000)
      call_rlp = build_call(@token_address, calldata)
      token_bytes = decode_address(@token_address)

      body = [
        :binary.encode_unsigned(42_431),
        <<>>,
        <<>>,
        :binary.encode_unsigned(21_000),
        [call_rlp],
        [],
        <<>>,
        <<>>,
        <<>>,
        <<>>,
        token_bytes,
        <<0x00>>,
        [],
        <<1::512>>
      ]

      raw = <<0x76>> <> ExRLP.encode(body)
      tx_hex = "0x" <> Base.encode16(raw, case: :lower)

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:error, %Errors{} = error} = Tempo.verify(payload, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "fee_token"
    end

    test "passes through when fee_payer is false (no co-signing)", %{charge: charge} do
      # Disable fee_payer
      charge = %{charge | method_details: Map.put(charge.method_details, "fee_payer", false)}

      calldata = transfer_calldata(@recipient, 1_000_000)
      call = build_call(@token_address, calldata)
      tx_hex = build_tempo_tx(calls: [call], chain_id: 42_431)

      stub_broadcast_and_receipt(success_receipt())

      payload = %{"type" => "transaction", "signature" => tx_hex}
      assert {:ok, %Receipt{}} = Tempo.verify(payload, charge)
    end
  end

  # Stubs the two-step optimistic flow: eth_call succeeds, eth_sendRawTransaction returns tx hash.
  defp stub_optimistic_flow(tx_hash) do
    Req.Test.stub(Tempo, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      case request["method"] do
        "eth_call" ->
          Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => "0x", "id" => 1})

        "eth_sendRawTransaction" ->
          Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => tx_hash, "id" => 1})
      end
    end)
  end

  # Stubs eth_sendRawTransactionSync to return a receipt directly (synchronous broadcast).
  defp stub_broadcast_and_receipt(receipt) do
    Req.Test.stub(Tempo, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      case request["method"] do
        "eth_sendRawTransactionSync" ->
          Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => receipt, "id" => 1})

        other ->
          Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => nil, "id" => 1, "_method" => other})
      end
    end)
  end
end
