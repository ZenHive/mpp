defmodule MPP.Methods.TempoFullFlowTest do
  @moduledoc """
  Full Plug pipeline tests for the Tempo payment method with stubbed RPC.

  Tests the complete 402 -> credential -> verify -> receipt flow through `MPP.Plug`,
  covering memo matching, dedup replay prevention, fee-payer edge cases, optimistic
  multicall correctness, and log filtering.

  Unlike `tempo_test.exs` (unit, tests verify/2 directly) and `tempo_integration_test.exs`
  (real Moderato testnet, tagged `:integration`), these always run with stubbed RPC.
  """

  use ExUnit.Case, async: true

  import MPP.Test.TempoTestHelpers

  alias MPP.Credential
  alias MPP.Headers
  alias MPP.Methods.Tempo
  alias MPP.Plug, as: PaymentPlug
  alias MPP.Receipt
  alias MPP.Test.TempoMemoryStore
  alias Onchain.Tempo.Transaction.Builder, as: TempoTxBuilder

  # --- Constants ---

  @rpc_url "https://rpc.moderato.tempo.xyz"
  @token_address "0x20C0000000000000000000000000000000000000"
  @recipient "0x1234567890AbcdEF1234567890aBcDeF12345678"
  @tx_hash "0x" <> String.duplicate("ab", 32)
  @chain_id 42_431
  @amount "1000000"
  @hmac_secret "test-secret-for-full-flow"
  @realm "full-flow-test.example.com"

  # Event topics
  @transfer_topic "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
  @transfer_with_memo_topic "0x57bc7354aa85aed339e000bccffabbc529466af35f0772c8f8ee1145927de7f0"
  @test_memo "0x" <> String.duplicate("ab", 32)

  # Deterministic test keys (Hardhat defaults, no value)
  @client_private_key "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  @fee_payer_private_key "59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"

  # ============================================================================
  # Test 1: Fee-payer type="hash" rejection
  # ============================================================================

  describe "fee-payer rejects hash credential at Plug level" do
    test "returns invalid-payload error for hash credential when feePayer is true" do
      config = init_tempo_config(fee_payer_config())

      body = submit_credential!(config, %{"type" => "hash", "hash" => @tx_hash})

      assert body["type"] =~ "invalid-payload"
      assert body["detail"] =~ "feePayer"
    end
  end

  # ============================================================================
  # Test 2: Hash-path receipt with extra unrelated logs
  # ============================================================================

  describe "hash path filters correct Transfer from noisy logs" do
    test "selects correct Transfer event ignoring unrelated logs" do
      config = init_tempo_config_with_memo_store()

      unrelated_log = %{
        "address" => "0x0000000000000000000000000000000000000001",
        "topics" => ["0x" <> String.duplicate("ff", 32)],
        "data" => "0x" <> String.duplicate("00", 32),
        "blockNumber" => "0x1a",
        "transactionHash" => @tx_hash,
        "logIndex" => "0x0"
      }

      wrong_token_transfer = transfer_log(token: "0x0000000000000000000000000000000000000099")
      correct_transfer = transfer_with_memo_log(memo: @test_memo)

      receipt = success_receipt(logs: [unrelated_log, wrong_token_transfer, correct_transfer])
      stub_receipt(receipt)

      conn = submit_credential_expect_success!(config, %{"type" => "hash", "hash" => @tx_hash})

      assert conn.assigns[:mpp_receipt].reference == @tx_hash
      assert conn.assigns[:mpp_receipt].status == "success"
      assert conn.assigns[:mpp_receipt].method == "tempo"
    end
  end

  # ============================================================================
  # Tests 3 & 4: transferWithMemo
  # ============================================================================

  describe "transferWithMemo full flow" do
    test "hash path: rejects when log has wrong memo" do
      config = init_tempo_config_with_memo_store()

      wrong_memo = "0x" <> String.duplicate("cd", 32)
      stub_receipt(success_receipt(logs: [transfer_with_memo_log(memo: wrong_memo)]))

      body = submit_credential!(config, %{"type" => "hash", "hash" => @tx_hash})

      assert body["type"] =~ "verification-failed"
    end

    test "hash path: rejects plain Transfer when memo is configured" do
      config = init_tempo_config_with_memo_store()

      # success_receipt() generates a plain Transfer log (no memo)
      stub_receipt(success_receipt())

      body = submit_credential!(config, %{"type" => "hash", "hash" => @tx_hash})

      assert body["type"] =~ "verification-failed"
    end

    test "hash path: accepts matching transferWithMemo" do
      config = init_tempo_config_with_memo_store()

      stub_receipt(success_receipt(logs: [transfer_with_memo_log(memo: @test_memo)]))

      conn = submit_credential_expect_success!(config, %{"type" => "hash", "hash" => @tx_hash})

      assert %Receipt{} = receipt = conn.assigns[:mpp_receipt]
      assert receipt.status == "success"
      assert receipt.method == "tempo"
      assert receipt.reference == @tx_hash

      # Verify Payment-Receipt header
      assert [receipt_header] = Plug.Conn.get_resp_header(conn, "payment-receipt")
      assert {:ok, parsed} = Headers.parse_receipt(receipt_header)
      assert parsed.reference == receipt.reference
    end

    test "transaction path: accepts matching transferWithMemo" do
      config = init_tempo_config_with_memo_store()

      # Build tx with transferWithMemo calldata
      call = build_call(@token_address, transfer_with_memo_calldata(@recipient, 1_000_000, @test_memo))
      tx_hex = build_tempo_tx(calls: [call], chain_id: @chain_id)

      stub_broadcast_and_receipt(success_receipt(logs: [transfer_with_memo_log(memo: @test_memo)]))

      conn =
        submit_credential_expect_success!(config, %{
          "type" => "transaction",
          "signature" => tx_hex
        })

      assert conn.assigns[:mpp_receipt].status == "success"
    end
  end

  # ============================================================================
  # Test 5: Fee-payer malformed client transaction rejection
  # ============================================================================

  describe "fee-payer malformed transaction rejection" do
    test "rejects transaction missing fee_payer_signature placeholder" do
      config = init_tempo_config(fee_payer_config())

      # Build a normal tx (fee_payer: false → no placeholder) with otherwise-valid
      # gas economics, so the placeholder check is what rejects it.
      call = build_call(@token_address, transfer_calldata(@recipient, 1_000_000))

      tx_hex =
        build_tempo_tx(
          calls: [call],
          chain_id: @chain_id,
          fee_payer: false,
          gas_limit: 51_299,
          max_fee_per_gas: 1_000_000_000,
          max_priority_fee_per_gas: 1_000_000_000,
          nonce_key: expiring_nonce_key(),
          valid_before: future_valid_before()
        )

      body =
        submit_credential!(config, %{"type" => "transaction", "signature" => tx_hex})

      assert body["type"] =~ "verification-failed"
      assert body["detail"] =~ "placeholder"
    end

    test "rejects transaction with non-empty fee_token" do
      config = init_tempo_config(fee_payer_config())

      # Build tx with placeholder but non-empty fee_token
      # Manual RLP construction: fee_payer_signature = <<0x00>>, fee_token = token_bytes
      token_bytes = decode_address(@token_address)
      call = build_call(@token_address, transfer_calldata(@recipient, 1_000_000))
      tx_hex = build_tempo_tx_with_fee_token(call, token_bytes)

      body =
        submit_credential!(config, %{"type" => "transaction", "signature" => tx_hex})

      assert body["type"] =~ "verification-failed"
      assert body["detail"] =~ "fee_token"
    end
  end

  # ============================================================================
  # Test 6: Transaction replay/dedup through Plug
  # ============================================================================

  describe "transaction dedup through Plug flow" do
    test "first submission succeeds, second rejected as already used" do
      start_supervised!(TempoMemoryStore)

      config =
        init_tempo_config(method_config: %{"store" => TempoMemoryStore, "memo" => @test_memo})

      call = build_call(@token_address, transfer_with_memo_calldata(@recipient, 1_000_000, @test_memo))
      tx_hex = build_tempo_tx(calls: [call], chain_id: @chain_id)

      stub_broadcast_and_receipt(success_receipt(logs: [transfer_with_memo_log(memo: @test_memo)]))

      # First: succeeds
      conn =
        submit_credential_expect_success!(config, %{
          "type" => "transaction",
          "signature" => tx_hex
        })

      assert conn.assigns[:mpp_receipt].status == "success"

      # Second: rejected as already used
      body =
        submit_credential!(config, %{"type" => "transaction", "signature" => tx_hex})

      assert body["type"] =~ "verification-failed"
      assert body["detail"] =~ "already used"
    end
  end

  # ============================================================================
  # Test 7: Optimistic multicall pre-broadcast simulation
  # ============================================================================

  describe "optimistic multicall simulates the full transaction before broadcast" do
    test "simulates via eth_simulateV1, then broadcasts" do
      config = init_tempo_config_with_memo_store(%{"wait_for_confirmation" => false})

      # Build 3-call tx: [approve(dex), swap(dex), transfer(token)]. The full tx is
      # simulated via eth_simulateV1 — there is no per-call eth_call to mis-target.
      dex = dex_address()
      approve_call = build_call(@token_address, approve_calldata(dex, 1_000_000))
      swap_call = build_call(dex, swap_calldata())
      transfer_call = build_call(@token_address, transfer_with_memo_calldata(@recipient, 1_000_000, @test_memo))
      tx_hex = build_tempo_tx(calls: [approve_call, swap_call, transfer_call], chain_id: @chain_id)

      test_pid = self()

      Req.Test.stub(TempoFullFlow, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)
        send(test_pid, {:rpc_call, request["method"]})

        case request["method"] do
          "eth_simulateV1" ->
            Req.Test.json(conn, simulate_success_body())

          "eth_sendRawTransaction" ->
            Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => @tx_hash, "id" => 1})
        end
      end)

      conn =
        submit_credential_expect_success!(config, %{
          "type" => "transaction",
          "signature" => tx_hex
        })

      assert conn.assigns[:mpp_receipt].status == "success"

      # The full tx is simulated before broadcast.
      assert_received {:rpc_call, "eth_simulateV1"}
      assert_received {:rpc_call, "eth_sendRawTransaction"}
    end
  end

  # ============================================================================
  # Test 8: Fee-payer replay/dedup
  # ============================================================================

  describe "fee-payer dedup" do
    test "co-signed transaction rejected on second submission" do
      start_supervised!(TempoMemoryStore)

      fee_payer_mc = Keyword.fetch!(fee_payer_config(), :method_config)

      config =
        init_tempo_config(
          method_config: fee_payer_mc |> Map.put("store", TempoMemoryStore) |> Map.put("memo", @test_memo)
        )

      call = build_call(@token_address, transfer_with_memo_calldata(@recipient, 1_000_000, @test_memo))

      {:ok, signed_tx} =
        TempoTxBuilder.build_fee_payer_multicall(
          private_key: @client_private_key,
          calls: [call],
          chain_id: @chain_id,
          rpc_url: @rpc_url,
          # Pin gas so the builder skips eth_estimateGas — this suite is offline
          # (stubbed RPC); an omitted gas_limit would make a real network call.
          gas_limit: 1_000_000,
          nonce: 0,
          nonce_key: expiring_nonce_key_int(),
          valid_before: future_valid_before()
        )

      stub_broadcast_and_receipt(success_receipt(logs: [transfer_with_memo_log(memo: @test_memo)]))

      # First: co-signed and broadcast succeeds
      conn =
        submit_credential_expect_success!(config, %{
          "type" => "transaction",
          "signature" => signed_tx
        })

      assert conn.assigns[:mpp_receipt].status == "success"

      # Second: same client tx -> store catches duplicate
      body =
        submit_credential!(config, %{"type" => "transaction", "signature" => signed_tx})

      assert body["type"] =~ "verification-failed"
      assert body["detail"] =~ "already used"
    end
  end

  # ============================================================================
  # Private helpers
  # ============================================================================

  # --- Config builders ---

  defp init_tempo_config_with_memo_store(extra \\ %{}) do
    start_supervised!(TempoMemoryStore)

    init_tempo_config(method_config: Map.merge(%{"store" => TempoMemoryStore, "memo" => @test_memo}, extra))
  end

  defp init_tempo_config(overrides) do
    extra_method_config = Keyword.get(overrides, :method_config, %{})

    method_config =
      Map.merge(
        %{"rpc_url" => @rpc_url, "chain_id" => @chain_id, "req_options" => [plug: {Req.Test, TempoFullFlow}]},
        extra_method_config
      )

    PaymentPlug.init(
      secret_key: @hmac_secret,
      realm: @realm,
      method: Tempo,
      amount: Keyword.get(overrides, :amount, @amount),
      currency: Keyword.get(overrides, :currency, @token_address),
      recipient: Keyword.get(overrides, :recipient, @recipient),
      method_config: method_config
    )
  end

  defp fee_payer_config do
    [
      method_config: %{
        "fee_payer" => true,
        "fee_payer_private_key" => @fee_payer_private_key,
        "fee_token" => @token_address
      }
    ]
  end

  # --- Plug flow helpers ---

  # Sends a bare GET through the Plug, asserts 402, parses challenge.
  defp request_challenge!(config) do
    conn =
      :get
      |> Plug.Test.conn("/api/data")
      |> PaymentPlug.call(config)

    assert conn.status == 402
    assert [challenge_header] = Plug.Conn.get_resp_header(conn, "www-authenticate")
    assert {:ok, challenge} = Headers.parse_challenge(challenge_header)
    challenge
  end

  # Gets fresh challenge, builds credential, submits. Asserts 402, returns decoded error body.
  defp submit_credential!(config, payload) do
    challenge = request_challenge!(config)

    credential = %Credential{challenge: challenge, payload: payload}
    auth_header = Headers.format_credential(credential)

    conn =
      :get
      |> Plug.Test.conn("/api/data")
      |> Plug.Conn.put_req_header("authorization", auth_header)
      |> PaymentPlug.call(config)

    assert conn.status == 402, "Expected 402, got #{conn.status || "nil (pass-through)"}"
    Jason.decode!(conn.resp_body)
  end

  # Gets fresh challenge, builds credential, submits. Asserts pass-through, returns conn.
  defp submit_credential_expect_success!(config, payload) do
    challenge = request_challenge!(config)

    credential = %Credential{challenge: challenge, payload: payload}
    auth_header = Headers.format_credential(credential)

    conn =
      :get
      |> Plug.Test.conn("/api/data")
      |> Plug.Conn.put_req_header("authorization", auth_header)
      |> PaymentPlug.call(config)

    assert conn.status == nil,
           "Expected pass-through, got #{conn.status}: #{conn.resp_body}"

    conn
  end

  # --- Stub helpers ---

  # Stubs eth_getTransactionReceipt to return the given receipt.
  defp stub_receipt(receipt) do
    Req.Test.stub(TempoFullFlow, fn conn ->
      Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => receipt, "id" => 1})
    end)
  end

  # Stubs the confirmation flow: pre-broadcast eth_simulateV1 succeeds, then
  # eth_sendRawTransactionSync returns the given receipt. Dispatches by method.
  defp stub_broadcast_and_receipt(receipt) do
    Req.Test.stub(TempoFullFlow, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      case request["method"] do
        "eth_simulateV1" ->
          Req.Test.json(conn, simulate_success_body())

        "eth_sendRawTransactionSync" ->
          Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => receipt, "id" => 1})

        _other ->
          Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => nil, "id" => 1})
      end
    end)
  end

  # eth_simulateV1 success response body: one block, one call with status 0x1.
  defp simulate_success_body do
    %{"jsonrpc" => "2.0", "result" => [%{"calls" => [%{"status" => "0x1"}]}], "id" => 1}
  end

  # --- Receipt/log builders ---

  # Builds a successful receipt with a matching Transfer log.
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

  # Builds a raw ERC-20 Transfer log entry.
  defp transfer_log(opts) do
    amount = Keyword.get(opts, :amount, 1_000_000)
    from = Keyword.get(opts, :from, "0x" <> String.duplicate("00", 20))
    to = Keyword.get(opts, :to, @recipient)
    token = Keyword.get(opts, :token, @token_address)

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

  # Builds a raw TIP-20 TransferWithMemo log entry matching real Moderato format.
  # The memo is indexed, so it appears in topics[3]; data contains only the amount.
  defp transfer_with_memo_log(opts) do
    amount = Keyword.get(opts, :amount, 1_000_000)
    from = Keyword.get(opts, :from, "0x" <> String.duplicate("00", 20))
    to = Keyword.get(opts, :to, @recipient)
    token = Keyword.get(opts, :token, @token_address)
    memo = Keyword.get(opts, :memo, @test_memo)

    from_padded = "0x" <> String.pad_leading(strip_0x(from), 64, "0")
    to_padded = "0x" <> String.pad_leading(strip_0x(to), 64, "0")

    memo_topic = "0x" <> String.pad_leading(strip_0x(memo), 64, "0")
    amount_hex = String.pad_leading(Integer.to_string(amount, 16), 64, "0")
    data = "0x" <> amount_hex

    %{
      "address" => token,
      "topics" => [@transfer_with_memo_topic, from_padded, to_padded, memo_topic],
      "data" => data,
      "blockNumber" => "0x1a",
      "transactionHash" => @tx_hash,
      "logIndex" => "0x0"
    }
  end

  # --- Transaction builders ---

  # Builds a 0x76 tx with fee_payer_signature placeholder (0x00) but non-empty fee_token.
  # Used to test fee_token validation.
  defp build_tempo_tx_with_fee_token(call, fee_token_bytes) do
    chain_id_bin = :binary.encode_unsigned(@chain_id)

    # calls: [[to, value, input]]
    [to_bin, value_bin, input] = call

    fields = [
      chain_id_bin,
      # max_priority_fee_per_gas
      <<1>>,
      # max_fee_per_gas
      <<1>>,
      # gas_limit
      :binary.encode_unsigned(21_000),
      # calls
      [[to_bin, value_bin, input]],
      # access_list
      [],
      # nonce_key (expiring — so the tx clears the validity check and the
      # fee_token check is what rejects it)
      expiring_nonce_key(),
      # nonce
      <<>>,
      # valid_before (future — same reason)
      :binary.encode_unsigned(future_valid_before()),
      # valid_after
      <<>>,
      # fee_token (NON-EMPTY — this is what we're testing)
      fee_token_bytes,
      # fee_payer_signature (placeholder)
      <<0x00>>,
      # aa_authorization_list
      []
    ]

    rlp = ExRLP.encode(fields)
    "0x76" <> Base.encode16(rlp, case: :lower)
  end
end
