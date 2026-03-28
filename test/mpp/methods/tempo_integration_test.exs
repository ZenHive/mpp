defmodule MPP.Methods.TempoIntegrationTest do
  @moduledoc """
  Integration tests for the Tempo payment method against Tempo's Moderato testnet.

  Tests both credential types:

    * `type="hash"` — Client broadcasts a TIP-20 transfer, sends the tx hash as credential.
      Server fetches receipt via RPC and verifies Transfer events.

    * `type="transaction"` — Client builds and signs a 0x76 Tempo Transaction, sends the
      raw signed bytes as credential. Server deserializes, verifies payment call, broadcasts
      via `eth_sendRawTransactionSync`, and verifies the receipt.

  Run with: `mix test test/mpp/methods/tempo_integration_test.exs --include integration`
  """

  use ExUnit.Case, async: false

  alias MPP.Credential
  alias MPP.Headers
  alias MPP.Methods.Tempo
  alias MPP.Receipt
  alias MPP.Test.TempoMemoryStore
  alias MPP.Test.TempoTestHelpers
  alias Onchain.Tempo.Transaction.Builder, as: TempoTxBuilder

  @moduletag :integration

  # --- Testnet constants ---
  @default_rpc_url "https://rpc.moderato.tempo.xyz"
  @chain_id 42_431
  @path_usd "0x20c0000000000000000000000000000000000000"

  # Deterministic testnet-only private keys (no value on mainnet)
  @sender_key "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  @recipient_key "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
  @fee_payer_key "5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"

  # 1 pathUSD (6 decimals)
  @transfer_amount 1_000_000
  @test_memo "0x" <> String.duplicate("ab", 32)

  # Plug config
  @hmac_secret "test-hmac-secret-for-tempo-integration"
  @realm "tempo-integration-test.example.com"

  # Polling config for tx confirmation
  @confirmation_poll_interval_ms 2_000
  @confirmation_max_attempts 30

  # Atomically returns the current sender nonce and increments the counter.
  # Only used by tests that actually broadcast transactions.
  # Requires async: false — tests must run sequentially.
  defp checkout_nonce do
    Agent.get_and_update(__MODULE__.NonceAgent, fn n -> {n, n + 1} end)
  end

  setup_all do
    if !Code.ensure_loaded?(Onchain) do
      flunk("""
      Missing `onchain` dependency!

      Add it to your mix.exs:
        {:onchain, "~> 0.4"}

      Then run: mix deps.get
      """)
    end

    rpc_url = System.get_env("TEMPO_RPC_URL") || @default_rpc_url
    rpc_opts = [rpc_url: rpc_url]

    # Derive addresses from test keys
    {:ok, sender_address} = Onchain.Signer.address_from_key(@sender_key)
    {:ok, recipient_address} = Onchain.Signer.address_from_key(@recipient_key)

    # Fund sender via Tempo's custom faucet RPC
    :ok = fund_test_address(sender_address, rpc_url)

    # Wait for faucet funding to confirm. Moderato has sub-second finality,
    # but the faucet tx needs to be included in a block before we can spend.
    Process.sleep(@confirmation_poll_interval_ms)

    # Get nonce and transfer pathUSD from sender to recipient
    {:ok, nonce} = Onchain.RPC.get_transaction_count(sender_address, rpc_opts)

    tx_opts =
      Keyword.merge(rpc_opts,
        private_key: @sender_key,
        chain_id: @chain_id,
        nonce: nonce
      )

    {:ok, tx_hash} = Onchain.ERC20.transfer(@path_usd, recipient_address, @transfer_amount, tx_opts)

    # Wait for transaction confirmation
    receipt = wait_for_receipt!(tx_hash, rpc_opts)

    if receipt.status != 1 do
      flunk("Test setup: pathUSD transfer reverted (tx: #{tx_hash})")
    end

    memo_call =
      TempoTestHelpers.build_call(
        @path_usd,
        TempoTestHelpers.transfer_with_memo_calldata(recipient_address, @transfer_amount, @test_memo)
      )

    {:ok, memo_tx} =
      TempoTxBuilder.build_signed_multicall(
        private_key: @sender_key,
        calls: [memo_call],
        chain_id: @chain_id,
        rpc_url: rpc_url,
        fee_token: @path_usd,
        nonce: nonce + 1
      )

    memo_tx_hash = broadcast_raw_transaction_sync!(memo_tx, rpc_url)

    # Track sender nonce across tests. ERC20 transfer used `nonce`,
    # memo tx used `nonce + 1`, so next available is `nonce + 2`.
    {:ok, _} = Agent.start_link(fn -> nonce + 2 end, name: __MODULE__.NonceAgent)

    # Build Plug config for 402 handshake tests
    plug_opts = [
      secret_key: @hmac_secret,
      realm: @realm,
      method: Tempo,
      amount: Integer.to_string(@transfer_amount),
      currency: @path_usd,
      recipient: recipient_address,
      method_config: %{
        "rpc_url" => rpc_url,
        "chain_id" => @chain_id,
        "fee_payer" => false
      }
    ]

    config = MPP.Plug.init(plug_opts)

    {:ok,
     config: config,
     tx_hash: tx_hash,
     memo_tx_hash: memo_tx_hash,
     sender: sender_address,
     recipient: recipient_address,
     rpc_url: rpc_url}
  end

  describe "full 402 handshake" do
    test "happy path: 402 → hash credential → receipt", %{
      config: config,
      tx_hash: tx_hash
    } do
      # Step 1: Request without credentials → 402 with challenge
      challenge = request_challenge!(config)
      assert challenge.method == "tempo"
      assert challenge.intent == "charge"
      assert challenge.realm == @realm

      # Step 2: Build credential with tx hash + echoed challenge
      credential = %Credential{
        challenge: challenge,
        payload: %{"type" => "hash", "hash" => tx_hash}
      }

      auth_header = Headers.format_credential(credential)

      # Step 3: Retry with credential → success with receipt
      conn_200 =
        :get
        |> Plug.Test.conn("/api/data")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> MPP.Plug.call(config)

      assert conn_200.status == nil, "Plug should pass through (not send response) on valid credential"
      assert %Receipt{} = conn_200.assigns[:mpp_receipt]

      receipt = conn_200.assigns[:mpp_receipt]
      assert receipt.status == "success"
      assert receipt.method == "tempo"
      assert receipt.reference == tx_hash
      assert receipt.timestamp

      # Verify Payment-Receipt header is set
      assert [receipt_header] = Plug.Conn.get_resp_header(conn_200, "payment-receipt")
      assert {:ok, parsed_receipt} = Headers.parse_receipt(receipt_header)
      assert parsed_receipt.reference == receipt.reference
    end
  end

  describe "dedup store" do
    test "hash credential replay rejected with store", %{
      config: config,
      tx_hash: tx_hash
    } do
      # Start an in-memory store and inject it into the config's method_config
      start_supervised!(TempoMemoryStore)

      [entry] = config.method_entries
      updated_entry = %{entry | method_config: Map.put(entry.method_config, "store", TempoMemoryStore)}
      config_with_store = %{config | method_entries: [updated_entry]}

      # First request: 402 → credential → success
      challenge1 = request_challenge!(config_with_store)

      credential1 = %Credential{
        challenge: challenge1,
        payload: %{"type" => "hash", "hash" => tx_hash}
      }

      conn1 =
        :get
        |> Plug.Test.conn("/api/data")
        |> Plug.Conn.put_req_header("authorization", Headers.format_credential(credential1))
        |> MPP.Plug.call(config_with_store)

      assert conn1.status == nil, "First request should pass through"
      assert %Receipt{} = conn1.assigns[:mpp_receipt]

      # Second request: same hash → 402 with "already used" error
      challenge2 = request_challenge!(config_with_store)

      credential2 = %Credential{
        challenge: challenge2,
        payload: %{"type" => "hash", "hash" => tx_hash}
      }

      conn2 =
        :get
        |> Plug.Test.conn("/api/data")
        |> Plug.Conn.put_req_header("authorization", Headers.format_credential(credential2))
        |> MPP.Plug.call(config_with_store)

      assert conn2.status == 402
      body = Jason.decode!(conn2.resp_body)
      assert body["type"] =~ "verification-failed"
      assert body["detail"] =~ "already used"
    end
  end

  describe "transferWithMemo hash credential path" do
    test "happy path: matching transferWithMemo hash succeeds", %{
      recipient: recipient_address,
      rpc_url: rpc_url,
      memo_tx_hash: memo_tx_hash
    } do
      memo_config = tempo_config(recipient_address, rpc_url, %{"memo" => @test_memo})

      challenge = request_challenge!(memo_config)

      credential = %Credential{
        challenge: challenge,
        payload: %{"type" => "hash", "hash" => memo_tx_hash}
      }

      conn =
        :get
        |> Plug.Test.conn("/api/data")
        |> Plug.Conn.put_req_header("authorization", Headers.format_credential(credential))
        |> MPP.Plug.call(memo_config)

      assert conn.status == nil, "Plug should pass through on valid memo hash credential"
      assert %Receipt{} = receipt = conn.assigns[:mpp_receipt]
      assert receipt.status == "success"
      assert receipt.method == "tempo"
      assert receipt.reference == memo_tx_hash
    end

    test "rejects plain transfer hash when memo is configured", %{
      recipient: recipient_address,
      rpc_url: rpc_url,
      tx_hash: tx_hash
    } do
      memo_config = tempo_config(recipient_address, rpc_url, %{"memo" => @test_memo})

      body = submit_credential!(memo_config, %{"type" => "hash", "hash" => tx_hash})
      assert body["type"] =~ "verification-failed"
      assert body["detail"] =~ "TransferWithMemo"
    end

    test "rejects transferWithMemo hash when memo mismatches", %{
      recipient: recipient_address,
      rpc_url: rpc_url,
      memo_tx_hash: memo_tx_hash
    } do
      wrong_memo = "0x" <> String.duplicate("cd", 32)
      memo_config = tempo_config(recipient_address, rpc_url, %{"memo" => wrong_memo})

      body = submit_credential!(memo_config, %{"type" => "hash", "hash" => memo_tx_hash})
      assert body["type"] =~ "verification-failed"
      assert body["detail"] =~ "TransferWithMemo"
    end
  end

  describe "transferWithMemo transaction credential path" do
    test "happy path: 402 -> signed transferWithMemo credential -> server broadcasts -> receipt", %{
      recipient: recipient_address,
      rpc_url: rpc_url
    } do
      memo_config = tempo_config(recipient_address, rpc_url, %{"memo" => @test_memo})

      memo_call =
        TempoTestHelpers.build_call(
          @path_usd,
          TempoTestHelpers.transfer_with_memo_calldata(recipient_address, @transfer_amount, @test_memo)
        )

      {:ok, signed_tx} =
        TempoTxBuilder.build_signed_multicall(
          private_key: @sender_key,
          calls: [memo_call],
          chain_id: @chain_id,
          rpc_url: rpc_url,
          fee_token: @path_usd,
          nonce: checkout_nonce()
        )

      challenge = request_challenge!(memo_config)

      credential = %Credential{
        challenge: challenge,
        payload: %{"type" => "transaction", "signature" => signed_tx}
      }

      conn =
        :get
        |> Plug.Test.conn("/api/data")
        |> Plug.Conn.put_req_header("authorization", Headers.format_credential(credential))
        |> MPP.Plug.call(memo_config)

      assert conn.status == nil, "Plug should pass through on valid memo transaction credential"
      assert %Receipt{} = receipt = conn.assigns[:mpp_receipt]
      assert receipt.status == "success"
      assert receipt.method == "tempo"
      assert String.starts_with?(receipt.reference, "0x")
    end
  end

  describe "challenge details" do
    test "challenge contains Tempo method details", %{config: config} do
      challenge = request_challenge!(config)
      assert challenge.method == "tempo"

      # Method details are embedded in the base64url-encoded request field
      assert {:ok, request_json} = Base.url_decode64(challenge.request, padding: false)
      assert {:ok, request_map} = Jason.decode(request_json)

      assert request_map["methodDetails"]["chainId"] == @chain_id
      assert request_map["methodDetails"]["feePayer"] == false
    end
  end

  describe "error cases" do
    test "rejects valid tx hash when challenge amount does not match on-chain transfer", %{
      tx_hash: tx_hash,
      recipient: recipient_address
    } do
      wrong_config =
        MPP.Plug.init(
          secret_key: @hmac_secret,
          realm: @realm,
          method: Tempo,
          amount: Integer.to_string(@transfer_amount + 1),
          currency: @path_usd,
          recipient: recipient_address,
          method_config: %{
            "rpc_url" => System.get_env("TEMPO_RPC_URL") || @default_rpc_url,
            "chain_id" => @chain_id,
            "fee_payer" => false
          }
        )

      body = submit_credential!(wrong_config, %{"type" => "hash", "hash" => tx_hash})
      assert body["type"] =~ "verification-failed"
      assert body["detail"] =~ "No matching Transfer"
    end

    test "rejects non-existent transaction hash", %{config: config} do
      fake_hash = "0x" <> String.duplicate("ab", 32)
      body = submit_credential!(config, %{"type" => "hash", "hash" => fake_hash})
      assert body["type"] =~ "verification-failed"
    end

    test "rejects malformed hash", %{config: config} do
      body = submit_credential!(config, %{"type" => "hash", "hash" => "not-a-hash"})
      assert body["type"] =~ "invalid-payload"
    end

    test "rejects credential with missing type field", %{config: config} do
      body = submit_credential!(config, %{})
      assert body["type"] =~ "invalid-payload"
    end

    test "rejects malformed transaction credential", %{config: config} do
      body = submit_credential!(config, %{"type" => "transaction", "signature" => "0xdead"})
      assert body["type"] =~ "verification-failed"
      assert body["detail"] =~ "Not a Tempo transaction"
    end

    test "error responses follow RFC 9457 Problem Details structure", %{config: config} do
      body = submit_credential!(config, %{"type" => "hash", "hash" => "not-a-hash"})

      # RFC 9457 requires type (URI), title, status, detail
      assert body["type"] == "https://paymentauth.org/problems/invalid-payload"
      assert is_binary(body["title"])
      assert body["status"] == 402
      assert is_binary(body["detail"])
    end
  end

  describe "optimistic broadcast (wait_for_confirmation: false)" do
    test "happy path: simulation passes, async broadcast returns optimistic receipt", %{
      recipient: recipient_address,
      rpc_url: rpc_url
    } do
      # Build optimistic config — same as standard but with wait_for_confirmation: false
      optimistic_config =
        MPP.Plug.init(
          secret_key: @hmac_secret,
          realm: @realm,
          method: Tempo,
          amount: Integer.to_string(@transfer_amount),
          currency: @path_usd,
          recipient: recipient_address,
          method_config: %{
            "rpc_url" => rpc_url,
            "chain_id" => @chain_id,
            "fee_payer" => false,
            "wait_for_confirmation" => false
          }
        )

      # Build and sign a valid 0x76 transaction
      {:ok, signed_tx} =
        TempoTxBuilder.build_signed_transfer(
          private_key: @sender_key,
          token: @path_usd,
          recipient: recipient_address,
          amount: @transfer_amount,
          chain_id: @chain_id,
          rpc_url: rpc_url,
          fee_token: @path_usd,
          nonce: checkout_nonce()
        )

      # Get challenge and submit credential
      challenge = request_challenge!(optimistic_config)
      assert challenge.method == "tempo"

      credential = %Credential{
        challenge: challenge,
        payload: %{"type" => "transaction", "signature" => signed_tx}
      }

      auth_header = Headers.format_credential(credential)

      conn =
        :get
        |> Plug.Test.conn("/api/data")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> MPP.Plug.call(optimistic_config)

      # Should succeed with an optimistic receipt
      assert conn.status == nil, "Plug should pass through on valid optimistic credential"
      assert %Receipt{} = receipt = conn.assigns[:mpp_receipt]
      assert receipt.status == "success"
      assert receipt.method == "tempo"
      assert is_binary(receipt.reference)
      assert String.starts_with?(receipt.reference, "0x")

      # Verify Payment-Receipt header is set
      assert [receipt_header] = Plug.Conn.get_resp_header(conn, "payment-receipt")
      assert {:ok, parsed_receipt} = Headers.parse_receipt(receipt_header)
      assert parsed_receipt.reference == receipt.reference

      # The real proof: the returned tx hash should eventually confirm on-chain.
      # Poll until the tx lands in a block — this proves the optimistic broadcast
      # actually submitted a valid transaction, not just returned a fake hash.
      rpc_opts = [rpc_url: rpc_url]
      on_chain_receipt = wait_for_receipt!(receipt.reference, rpc_opts)
      assert on_chain_receipt.status == 1, "Optimistically broadcast tx should confirm on-chain"
    end

    test "simulation catches revert before broadcasting", %{
      recipient: recipient_address,
      rpc_url: rpc_url
    } do
      # Use an absurdly large amount that the sender cannot cover.
      # The eth_call simulation should detect insufficient balance and return
      # verification-failed WITHOUT broadcasting.
      impossible_amount = 999_999_999_999_999

      optimistic_config =
        MPP.Plug.init(
          secret_key: @hmac_secret,
          realm: @realm,
          method: Tempo,
          amount: Integer.to_string(impossible_amount),
          currency: @path_usd,
          recipient: recipient_address,
          method_config: %{
            "rpc_url" => rpc_url,
            "chain_id" => @chain_id,
            "fee_payer" => false,
            "wait_for_confirmation" => false
          }
        )

      # Build a tx with the impossible amount — it will pass local parsing
      # (find_payment_call matches) but should fail simulation on Moderato
      {:ok, signed_tx} =
        TempoTxBuilder.build_signed_transfer(
          private_key: @sender_key,
          token: @path_usd,
          recipient: recipient_address,
          amount: impossible_amount,
          chain_id: @chain_id,
          rpc_url: rpc_url,
          fee_token: @path_usd
        )

      body = submit_credential!(optimistic_config, %{"type" => "transaction", "signature" => signed_tx})
      assert body["type"] =~ "verification-failed"

      detail = body["detail"]

      assert detail =~ "Simulation failed" or detail =~ "Broadcast failed",
             "Expected simulation or broadcast failure, got: #{inspect(detail)}"
    end

    test "multicall: matched payment call is simulated before broadcast", %{
      recipient: recipient_address,
      rpc_url: rpc_url
    } do
      impossible_amount = 999_999_999_999_999

      optimistic_config =
        tempo_config(
          recipient_address,
          rpc_url,
          %{"wait_for_confirmation" => false},
          impossible_amount
        )

      harmless_call =
        TempoTestHelpers.build_call(
          @path_usd,
          TempoTestHelpers.transfer_calldata(recipient_address, 1)
        )

      payment_call =
        TempoTestHelpers.build_call(
          @path_usd,
          TempoTestHelpers.transfer_calldata(recipient_address, impossible_amount)
        )

      {:ok, signed_tx} =
        TempoTxBuilder.build_signed_multicall(
          private_key: @sender_key,
          calls: [harmless_call, payment_call],
          chain_id: @chain_id,
          rpc_url: rpc_url,
          fee_token: @path_usd
        )

      body = submit_credential!(optimistic_config, %{"type" => "transaction", "signature" => signed_tx})
      assert body["type"] =~ "verification-failed"

      detail = body["detail"]

      assert detail =~ "Simulation failed" or detail =~ "Broadcast failed",
             "Expected simulation or broadcast failure, got: #{inspect(detail)}"
    end
  end

  describe "transaction credential path" do
    test "happy path: 402 → signed tx credential → server broadcasts → receipt", %{
      config: config,
      recipient: recipient_address,
      rpc_url: rpc_url
    } do
      # Build and sign a 0x76 Tempo Transaction with a matching TIP-20 transfer
      {:ok, signed_tx} =
        TempoTxBuilder.build_signed_transfer(
          private_key: @sender_key,
          token: @path_usd,
          recipient: recipient_address,
          amount: @transfer_amount,
          chain_id: @chain_id,
          rpc_url: rpc_url,
          fee_token: @path_usd,
          nonce: checkout_nonce()
        )

      # Step 1: Get a 402 challenge
      challenge = request_challenge!(config)
      assert challenge.method == "tempo"

      # Step 2: Submit credential with signed transaction
      credential = %Credential{
        challenge: challenge,
        payload: %{"type" => "transaction", "signature" => signed_tx}
      }

      auth_header = Headers.format_credential(credential)

      # Step 3: Server deserializes, verifies call, broadcasts, checks receipt
      conn =
        :get
        |> Plug.Test.conn("/api/data")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> MPP.Plug.call(config)

      assert conn.status == nil, "Plug should pass through on valid transaction credential"
      assert %Receipt{} = receipt = conn.assigns[:mpp_receipt]
      assert receipt.status == "success"
      assert receipt.method == "tempo"
      # Reference is the on-chain tx hash from broadcast (not the input hex)
      assert is_binary(receipt.reference)
      assert String.starts_with?(receipt.reference, "0x")
      assert receipt.timestamp

      # Verify Payment-Receipt header
      assert [receipt_header] = Plug.Conn.get_resp_header(conn, "payment-receipt")
      assert {:ok, parsed_receipt} = Headers.parse_receipt(receipt_header)
      assert parsed_receipt.reference == receipt.reference
    end

    test "rejects transaction with wrong recipient", %{
      config: config,
      rpc_url: rpc_url
    } do
      # Build tx transferring to a different address than the challenge expects
      wrong_recipient = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"

      {:ok, signed_tx} =
        TempoTxBuilder.build_signed_transfer(
          private_key: @sender_key,
          token: @path_usd,
          recipient: wrong_recipient,
          amount: @transfer_amount,
          chain_id: @chain_id,
          rpc_url: rpc_url,
          fee_token: @path_usd
        )

      body = submit_credential!(config, %{"type" => "transaction", "signature" => signed_tx})
      assert body["type"] =~ "verification-failed"
      assert body["detail"] =~ "No matching transfer call"
    end

    test "rejects transaction with wrong amount", %{
      config: config,
      recipient: recipient_address,
      rpc_url: rpc_url
    } do
      # Build tx with a different amount than the challenge expects
      wrong_amount = @transfer_amount + 1

      {:ok, signed_tx} =
        TempoTxBuilder.build_signed_transfer(
          private_key: @sender_key,
          token: @path_usd,
          recipient: recipient_address,
          amount: wrong_amount,
          chain_id: @chain_id,
          rpc_url: rpc_url,
          fee_token: @path_usd
        )

      body = submit_credential!(config, %{"type" => "transaction", "signature" => signed_tx})
      assert body["type"] =~ "verification-failed"
      assert body["detail"] =~ "No matching transfer call"
    end

    test "same signed transaction is rejected on second submit when store is enabled", %{
      recipient: recipient_address,
      rpc_url: rpc_url
    } do
      start_supervised!(TempoMemoryStore)

      config = tempo_config(recipient_address, rpc_url, %{"store" => TempoMemoryStore})

      {:ok, signed_tx} =
        TempoTxBuilder.build_signed_transfer(
          private_key: @sender_key,
          token: @path_usd,
          recipient: recipient_address,
          amount: @transfer_amount,
          chain_id: @chain_id,
          rpc_url: rpc_url,
          fee_token: @path_usd,
          nonce: checkout_nonce()
        )

      challenge = request_challenge!(config)

      credential = %Credential{
        challenge: challenge,
        payload: %{"type" => "transaction", "signature" => signed_tx}
      }

      conn =
        :get
        |> Plug.Test.conn("/api/data")
        |> Plug.Conn.put_req_header("authorization", Headers.format_credential(credential))
        |> MPP.Plug.call(config)

      assert conn.status == nil, "First transaction submission should pass through"
      assert %Receipt{} = conn.assigns[:mpp_receipt]

      body = submit_credential!(config, %{"type" => "transaction", "signature" => signed_tx})
      assert body["type"] =~ "verification-failed"
      assert body["detail"] =~ "already used"
    end
  end

  describe "fee payer co-signing" do
    test "happy path: single transfer with fee payer co-signing", %{
      recipient: recipient_address,
      rpc_url: rpc_url
    } do
      # Fee payer key — Hardhat account #2 (testnet only, no security concern)
      fee_payer_key = "5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"

      # Fund fee payer so it can pay gas
      {:ok, fee_payer_address} = Onchain.Signer.address_from_key("0x" <> fee_payer_key)
      :ok = fund_test_address(fee_payer_address, rpc_url)
      Process.sleep(@confirmation_poll_interval_ms)

      fee_payer_config =
        MPP.Plug.init(
          secret_key: @hmac_secret,
          realm: @realm,
          method: Tempo,
          amount: Integer.to_string(@transfer_amount),
          currency: @path_usd,
          recipient: recipient_address,
          method_config: %{
            "rpc_url" => rpc_url,
            "chain_id" => @chain_id,
            "fee_payer" => true,
            "fee_payer_private_key" => fee_payer_key,
            "fee_token" => @path_usd
          }
        )

      # Build a fee-payer transfer (placeholder sig, empty fee_token)
      {:ok, signed_tx} =
        TempoTxBuilder.build_fee_payer_transfer(
          private_key: @sender_key,
          token: @path_usd,
          recipient: recipient_address,
          amount: @transfer_amount,
          chain_id: @chain_id,
          rpc_url: rpc_url,
          nonce: checkout_nonce()
        )

      # 402 → credential → server co-signs → broadcasts → receipt
      challenge = request_challenge!(fee_payer_config)

      credential = %Credential{
        challenge: challenge,
        payload: %{"type" => "transaction", "signature" => signed_tx}
      }

      auth_header = Headers.format_credential(credential)

      conn =
        :get
        |> Plug.Test.conn("/api/data")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> MPP.Plug.call(fee_payer_config)

      assert conn.status == nil,
             "Expected plug passthrough, got status #{conn.status}: #{conn.resp_body}"

      assert %Receipt{} = receipt = conn.assigns[:mpp_receipt]
      assert receipt.status == "success"
      assert receipt.method == "tempo"
      assert String.starts_with?(receipt.reference, "0x")
    end

    test "rogue call rejected before broadcast", %{
      recipient: recipient_address,
      rpc_url: rpc_url
    } do
      import TempoTestHelpers, only: [build_call: 2, transfer_calldata: 2]

      fee_payer_key = "5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"

      fee_payer_config =
        MPP.Plug.init(
          secret_key: @hmac_secret,
          realm: @realm,
          method: Tempo,
          amount: Integer.to_string(@transfer_amount),
          currency: @path_usd,
          recipient: recipient_address,
          method_config: %{
            "rpc_url" => rpc_url,
            "chain_id" => @chain_id,
            "fee_payer" => true,
            "fee_payer_private_key" => fee_payer_key,
            "fee_token" => @path_usd
          }
        )

      # Build a multicall with valid transfer + rogue extra call
      valid_call = build_call(@path_usd, transfer_calldata(recipient_address, @transfer_amount))
      token_bytes = TempoTestHelpers.decode_address(@path_usd)
      rogue_call = [token_bytes, <<>>, <<0xDE, 0xAD, 0xBE, 0xEF>> <> :binary.copy(<<0>>, 64)]

      {:ok, signed_tx} =
        TempoTxBuilder.build_fee_payer_multicall(
          private_key: @sender_key,
          calls: [valid_call, rogue_call],
          chain_id: @chain_id,
          rpc_url: rpc_url
        )

      body = submit_credential!(fee_payer_config, %{"type" => "transaction", "signature" => signed_tx})
      assert body["type"] =~ "verification-failed"
      assert body["detail"] =~ "disallowed call pattern"
    end
  end

  describe "fee-payer validation" do
    defp fee_payer_config(recipient_address, rpc_url, extra \\ %{}) do
      tempo_config(
        recipient_address,
        rpc_url,
        Map.merge(
          %{
            "fee_payer" => true,
            "fee_payer_private_key" => @fee_payer_key,
            "fee_token" => @path_usd
          },
          extra
        )
      )
    end

    test "rejects hash credential when feePayer is true", %{
      recipient: recipient_address,
      rpc_url: rpc_url,
      tx_hash: tx_hash
    } do
      config = fee_payer_config(recipient_address, rpc_url)

      body = submit_credential!(config, %{"type" => "hash", "hash" => tx_hash})
      assert body["type"] =~ "invalid-payload"
      assert body["detail"] =~ "feePayer"
    end

    test "rejects transaction missing fee_payer_signature placeholder", %{
      recipient: recipient_address,
      rpc_url: rpc_url
    } do
      config = fee_payer_config(recipient_address, rpc_url)

      # build_signed_transfer sets fee_payer_signature = <<>> (absent), NOT <<0x00>> (placeholder)
      {:ok, non_fp_tx} =
        TempoTxBuilder.build_signed_transfer(
          private_key: @sender_key,
          token: @path_usd,
          recipient: recipient_address,
          amount: @transfer_amount,
          chain_id: @chain_id,
          rpc_url: rpc_url,
          fee_token: @path_usd
        )

      body = submit_credential!(config, %{"type" => "transaction", "signature" => non_fp_tx})
      assert body["type"] =~ "verification-failed"
      assert body["detail"] =~ "placeholder"
    end

    test "rejects transaction with non-empty fee_token in fee-payer mode", %{
      recipient: recipient_address,
      rpc_url: rpc_url
    } do
      config = fee_payer_config(recipient_address, rpc_url)

      # Build raw 0x76 with placeholder sig but non-empty fee_token
      token_bytes = TempoTestHelpers.decode_address(@path_usd)
      calldata = TempoTestHelpers.transfer_calldata(recipient_address, @transfer_amount)
      call = [token_bytes, <<>>, calldata]

      fields = [
        :binary.encode_unsigned(@chain_id),
        <<1>>,
        <<1>>,
        :binary.encode_unsigned(21_000),
        [call],
        [],
        <<>>,
        <<>>,
        <<>>,
        <<>>,
        # fee_token: NON-EMPTY (this is what we're testing)
        token_bytes,
        # fee_payer_signature: placeholder
        <<0x00>>,
        []
      ]

      tx_hex = "0x76" <> Base.encode16(ExRLP.encode(fields), case: :lower)

      body = submit_credential!(config, %{"type" => "transaction", "signature" => tx_hex})
      assert body["type"] =~ "verification-failed"
      assert body["detail"] =~ "fee_token"
    end
  end

  describe "fee-payer dedup" do
    test "co-signed transaction rejected on second submission", %{
      recipient: recipient_address,
      rpc_url: rpc_url
    } do
      start_supervised!(TempoMemoryStore)

      {:ok, fee_payer_address} = Onchain.Signer.address_from_key("0x" <> @fee_payer_key)
      :ok = fund_test_address(fee_payer_address, rpc_url)
      Process.sleep(@confirmation_poll_interval_ms)

      config =
        tempo_config(
          recipient_address,
          rpc_url,
          %{
            "fee_payer" => true,
            "fee_payer_private_key" => @fee_payer_key,
            "fee_token" => @path_usd,
            "store" => TempoMemoryStore
          }
        )

      {:ok, signed_tx} =
        TempoTxBuilder.build_fee_payer_transfer(
          private_key: @sender_key,
          token: @path_usd,
          recipient: recipient_address,
          amount: @transfer_amount,
          chain_id: @chain_id,
          rpc_url: rpc_url,
          nonce: checkout_nonce()
        )

      # First: co-signed and broadcast succeeds
      challenge = request_challenge!(config)

      credential = %Credential{
        challenge: challenge,
        payload: %{"type" => "transaction", "signature" => signed_tx}
      }

      conn =
        :get
        |> Plug.Test.conn("/api/data")
        |> Plug.Conn.put_req_header("authorization", Headers.format_credential(credential))
        |> MPP.Plug.call(config)

      assert conn.status == nil,
             "First submission should pass through, got #{conn.status}: #{conn.resp_body}"

      assert %Receipt{} = conn.assigns[:mpp_receipt]

      # Second: same client tx -> store catches duplicate
      body = submit_credential!(config, %{"type" => "transaction", "signature" => signed_tx})
      assert body["type"] =~ "verification-failed"
      assert body["detail"] =~ "already used"
    end
  end

  describe "fee payer + optimistic broadcast" do
    test "fee payer co-signs and optimistically broadcasts transfer", %{
      recipient: recipient_address,
      rpc_url: rpc_url
    } do
      start_supervised!(TempoMemoryStore)

      {:ok, fee_payer_address} = Onchain.Signer.address_from_key("0x" <> @fee_payer_key)
      :ok = fund_test_address(fee_payer_address, rpc_url)
      Process.sleep(@confirmation_poll_interval_ms)

      config =
        tempo_config(
          recipient_address,
          rpc_url,
          %{
            "fee_payer" => true,
            "fee_payer_private_key" => @fee_payer_key,
            "fee_token" => @path_usd,
            "wait_for_confirmation" => false,
            "store" => TempoMemoryStore
          }
        )

      {:ok, signed_tx} =
        TempoTxBuilder.build_fee_payer_transfer(
          private_key: @sender_key,
          token: @path_usd,
          recipient: recipient_address,
          amount: @transfer_amount,
          chain_id: @chain_id,
          rpc_url: rpc_url,
          nonce: checkout_nonce()
        )

      challenge = request_challenge!(config)

      credential = %Credential{
        challenge: challenge,
        payload: %{"type" => "transaction", "signature" => signed_tx}
      }

      conn =
        :get
        |> Plug.Test.conn("/api/data")
        |> Plug.Conn.put_req_header("authorization", Headers.format_credential(credential))
        |> MPP.Plug.call(config)

      assert conn.status == nil,
             "Fee payer + optimistic should pass through, got #{conn.status}: #{conn.resp_body}"

      receipt = conn.assigns[:mpp_receipt]
      assert %Receipt{} = receipt
      assert receipt.status == "success"
      assert receipt.reference

      # Confirm the co-signed tx actually landed on-chain
      on_chain_receipt = wait_for_receipt!(receipt.reference, rpc_url: rpc_url)
      assert on_chain_receipt.status == 1
    end
  end

  describe "optimistic broadcast + dedup store" do
    test "optimistic broadcast rejects duplicate via store", %{
      recipient: recipient_address,
      rpc_url: rpc_url
    } do
      start_supervised!(TempoMemoryStore)

      config =
        tempo_config(
          recipient_address,
          rpc_url,
          %{
            "wait_for_confirmation" => false,
            "store" => TempoMemoryStore
          }
        )

      {:ok, signed_tx} =
        TempoTxBuilder.build_signed_transfer(
          private_key: @sender_key,
          token: @path_usd,
          recipient: recipient_address,
          amount: @transfer_amount,
          chain_id: @chain_id,
          rpc_url: rpc_url,
          fee_token: @path_usd,
          nonce: checkout_nonce()
        )

      # First submission: optimistic pass-through
      challenge = request_challenge!(config)

      credential = %Credential{
        challenge: challenge,
        payload: %{"type" => "transaction", "signature" => signed_tx}
      }

      conn =
        :get
        |> Plug.Test.conn("/api/data")
        |> Plug.Conn.put_req_header("authorization", Headers.format_credential(credential))
        |> MPP.Plug.call(config)

      assert conn.status == nil,
             "First optimistic submission should pass through, got #{conn.status}: #{conn.resp_body}"

      assert %Receipt{} = conn.assigns[:mpp_receipt]

      # Second submission: store catches duplicate before broadcast
      body = submit_credential!(config, %{"type" => "transaction", "signature" => signed_tx})
      assert body["type"] =~ "verification-failed"
      assert body["detail"] =~ "already used"
    end
  end

  describe "challenge expiration" do
    test "expired challenge rejected before method verification", %{
      recipient: recipient_address,
      rpc_url: rpc_url,
      tx_hash: tx_hash
    } do
      # 2-second TTL — short enough to expire during the sleep
      config =
        MPP.Plug.init(
          secret_key: @hmac_secret,
          realm: @realm,
          method: Tempo,
          amount: Integer.to_string(@transfer_amount),
          currency: @path_usd,
          recipient: recipient_address,
          expires_in: 2,
          method_config: %{
            "rpc_url" => rpc_url,
            "chain_id" => @chain_id,
            "fee_payer" => false
          }
        )

      challenge = request_challenge!(config)

      # Wait for the challenge to expire
      Process.sleep(3_000)

      # Submit with the now-expired challenge — should be rejected at the
      # expiration check, before method.verify/2 is ever called
      credential = %Credential{
        challenge: challenge,
        payload: %{"type" => "hash", "hash" => tx_hash}
      }

      conn =
        :get
        |> Plug.Test.conn("/api/data")
        |> Plug.Conn.put_req_header("authorization", Headers.format_credential(credential))
        |> MPP.Plug.call(config)

      assert conn.status == 402
      body = Jason.decode!(conn.resp_body)
      assert body["type"] =~ "payment-expired"
    end
  end

  describe "memo in challenge details" do
    test "challenge includes memo when configured", %{
      recipient: recipient_address,
      rpc_url: rpc_url
    } do
      config =
        tempo_config(recipient_address, rpc_url, %{"memo" => @test_memo})

      challenge = request_challenge!(config)
      assert {:ok, request_json} = Base.url_decode64(challenge.request, padding: false)
      assert {:ok, request_map} = Jason.decode(request_json)

      assert request_map["methodDetails"]["memo"] == @test_memo
    end

    test "challenge omits memo when not configured", %{config: config} do
      challenge = request_challenge!(config)
      assert {:ok, request_json} = Base.url_decode64(challenge.request, padding: false)
      assert {:ok, request_map} = Jason.decode(request_json)

      refute request_map["methodDetails"]["memo"]
    end
  end

  # --- Private helpers ---

  # Requests a 402 challenge from the Plug and parses it.
  defp request_challenge!(config) do
    conn =
      :get
      |> Plug.Test.conn("/api/data")
      |> MPP.Plug.call(config)

    assert conn.status == 402
    assert [challenge_header] = Plug.Conn.get_resp_header(conn, "www-authenticate")
    assert {:ok, challenge} = Headers.parse_challenge(challenge_header)
    challenge
  end

  # Submits a credential payload against a config and returns the parsed error body.
  # Gets a fresh challenge, builds credential, submits, asserts 402, returns decoded body.
  defp submit_credential!(config, payload) do
    challenge = request_challenge!(config)

    credential = %Credential{
      challenge: challenge,
      payload: payload
    }

    auth_header = Headers.format_credential(credential)

    conn =
      :get
      |> Plug.Test.conn("/api/data")
      |> Plug.Conn.put_req_header("authorization", auth_header)
      |> MPP.Plug.call(config)

    assert conn.status == 402
    Jason.decode!(conn.resp_body)
  end

  # Builds a Tempo Plug config with common test defaults plus method_config overrides.
  defp tempo_config(recipient_address, rpc_url, method_config_overrides) do
    tempo_config(recipient_address, rpc_url, method_config_overrides, @transfer_amount)
  end

  defp tempo_config(recipient_address, rpc_url, method_config_overrides, amount) do
    MPP.Plug.init(
      secret_key: @hmac_secret,
      realm: @realm,
      method: Tempo,
      amount: Integer.to_string(amount),
      currency: @path_usd,
      recipient: recipient_address,
      method_config:
        Map.merge(
          %{
            "rpc_url" => rpc_url,
            "chain_id" => @chain_id,
            "fee_payer" => false
          },
          method_config_overrides
        )
    )
  end

  # Funds a test address via Tempo's custom `tempo_fundAddress` JSON-RPC method.
  defp fund_test_address(address, rpc_url) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "tempo_fundAddress",
        "params" => [address],
        "id" => 1
      })

    case Req.post(rpc_url, headers: [{"content-type", "application/json"}], body: body) do
      {:ok, %Req.Response{status: status, body: %{"error" => %{"message" => msg}}}}
      when status in 200..299 ->
        flunk("""
        tempo_fundAddress RPC returned error.

        Message: #{msg}
        Address: #{address}
        RPC URL: #{rpc_url}

        The Tempo Moderato testnet faucet may be down or rate-limited.
        """)

      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        flunk("""
        Failed to fund test address via tempo_fundAddress.

        Status: #{status}
        Body: #{inspect(resp_body)}
        Address: #{address}
        RPC URL: #{rpc_url}

        The Tempo Moderato testnet faucet may be down or rate-limited.
        """)

      {:error, exception} ->
        flunk("""
        Failed to connect to Tempo Moderato testnet.

        Error: #{Exception.message(exception)}
        RPC URL: #{rpc_url}

        Check network connectivity and that the RPC URL is correct.
        Set TEMPO_RPC_URL to override: export TEMPO_RPC_URL="https://rpc.moderato.tempo.xyz"
        """)
    end
  end

  # Broadcasts a prebuilt signed Tempo transaction via the sync RPC and returns its tx hash.
  defp broadcast_raw_transaction_sync!(raw_tx, rpc_url) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "eth_sendRawTransactionSync",
        "params" => [raw_tx],
        "id" => 1
      })

    case Req.post(rpc_url, headers: [{"content-type", "application/json"}], body: body) do
      {:ok, %Req.Response{status: status, body: %{"result" => receipt}}}
      when status in 200..299 and is_map(receipt) ->
        tx_hash = receipt["transactionHash"]

        if receipt["status"] != "0x1" do
          flunk("Broadcasted raw transaction reverted (tx: #{tx_hash || inspect(receipt)})")
        end

        tx_hash

      {:ok, %Req.Response{status: status, body: %{"error" => error}}} when status in 200..299 ->
        flunk("Failed to broadcast raw transaction: #{inspect(error)}")

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        flunk("Unexpected response broadcasting raw transaction: status=#{status}, body=#{inspect(resp_body)}")

      {:error, exception} ->
        flunk("Failed to broadcast raw transaction: #{Exception.message(exception)}")
    end
  end

  # Polls for transaction receipt until confirmed or max attempts reached.
  defp wait_for_receipt!(tx_hash, rpc_opts) do
    wait_for_receipt!(tx_hash, rpc_opts, 0)
  end

  defp wait_for_receipt!(tx_hash, rpc_opts, attempt) when attempt >= @confirmation_max_attempts do
    rpc_url = Keyword.get(rpc_opts, :rpc_url, @default_rpc_url)

    flunk("""
    Transaction not confirmed after #{@confirmation_max_attempts} attempts.

    Tx hash: #{tx_hash}
    RPC URL: #{rpc_url}

    The Tempo Moderato testnet may be slow or the transaction may have failed.
    """)
  end

  defp wait_for_receipt!(tx_hash, rpc_opts, attempt) do
    case Onchain.RPC.get_transaction_receipt(tx_hash, rpc_opts) do
      {:ok, nil} ->
        Process.sleep(@confirmation_poll_interval_ms)
        wait_for_receipt!(tx_hash, rpc_opts, attempt + 1)

      {:ok, receipt} ->
        receipt

      {:error, reason} ->
        flunk("Failed to get transaction receipt: #{inspect(reason)}")
    end
  end
end
