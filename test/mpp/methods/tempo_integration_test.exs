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
  alias Onchain.Tempo.Faucet
  alias Onchain.Tempo.Transaction.Builder, as: TempoTxBuilder

  @moduletag :integration

  # --- Testnet constants ---
  @default_rpc_url "https://rpc.moderato.tempo.xyz"
  @chain_id 42_431
  @path_usd "0x20c0000000000000000000000000000000000000"

  # Deterministic testnet-only recipient key (no value on mainnet) — used only
  # to derive a stable recipient address. Sender and fee-payer wallets are
  # minted fresh per test via `Onchain.Tempo.Faucet.fresh_funded_wallet/1`.
  #
  # NOT an Anvil/Hardhat well-known key: Moderato blocklists the standard test
  # EOAs (e.g. Anvil acct #1, 0x70997970…), redirecting TIP-20 transfers to a
  # block sentinel (0xB10C…0000) so no Transfer event reaches the intended
  # recipient — which silently fails every `find_matching_transfer` assertion.
  # This key derives to 0x19E7E376…, a plain address transfers land on cleanly.
  @recipient_key "0x1111111111111111111111111111111111111111111111111111111111111111"

  # 1 pathUSD (6 decimals)
  @transfer_amount 1_000_000
  @test_memo "0x" <> String.duplicate("ab", 32)
  @attribution_memo_version 1
  @attribution_server_fingerprint_length 10
  @attribution_client_fingerprint_length 10
  @attribution_nonce_length 7

  # Plug config
  @hmac_secret "test-hmac-secret-for-tempo-integration"
  @realm "tempo-integration-test.example.com"

  # Polling config for tx confirmation
  @confirmation_poll_interval_ms 2_000
  @confirmation_max_attempts 30

  setup_all do
    if !Code.ensure_loaded?(Onchain) do
      flunk("""
      Missing `onchain` dependency!

      Add it to your mix.exs:
        {:onchain, "~> 0.10"}

      Then run: mix deps.get
      """)
    end

    rpc_url = System.get_env("TEMPO_RPC_URL") || @default_rpc_url

    # Recipient is a fixed address (never broadcasts), so we derive once from a
    # known key for stability across tests.
    {:ok, recipient_address} = Onchain.Signer.address_from_key(@recipient_key)

    # Mint a fresh, funded fixture wallet used only to seed the shared
    # `tx_hash` and `memo_tx_hash` fixtures below. Fresh per suite run → nonce
    # starts at 0, no persistent address to collide with other runs.
    fixture_wallet = fresh_wallet!(rpc_url)

    # Seed tx 1: pathUSD transfer from fixture wallet → recipient (nonce 0).
    # Use the 0x76 Tempo transaction builder (TIP-20 `transfer` call) — the path
    # real MPP clients use, exercised by every transaction-credential test below.
    # `gas_limit` is omitted so the builder auto-estimates each call via
    # `eth_estimateGas` (onchain_tempo ≥ 0.4.0, 1.25× headroom): a cold TIP-20
    # transfer on Moderato costs ~560k–810k (the chain charges a protocol fee on
    # the transfer path), which the old static 500k default OOG-reverted.
    # `broadcast_..._sync!` asserts the receipt status is 0x1, so a revert
    # surfaces loudly here.
    {:ok, seed_tx} =
      TempoTxBuilder.build_signed_transfer(
        private_key: fixture_wallet.private_key,
        token: @path_usd,
        recipient: recipient_address,
        amount: @transfer_amount,
        chain_id: @chain_id,
        rpc_url: rpc_url,
        fee_token: @path_usd,
        nonce: 0
      )

    tx_hash = broadcast_raw_transaction_sync!(seed_tx, rpc_url)

    # Seed tx 2: transferWithMemo from fixture wallet → recipient (nonce 1).
    memo_call =
      TempoTestHelpers.build_call(
        @path_usd,
        TempoTestHelpers.transfer_with_memo_calldata(recipient_address, @transfer_amount, @test_memo)
      )

    {:ok, memo_tx} =
      TempoTxBuilder.build_signed_multicall(
        private_key: fixture_wallet.private_key,
        calls: [memo_call],
        chain_id: @chain_id,
        rpc_url: rpc_url,
        fee_token: @path_usd,
        nonce: 1
      )

    memo_tx_hash = broadcast_raw_transaction_sync!(memo_tx, rpc_url)

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

    {:ok, config: config, tx_hash: tx_hash, memo_tx_hash: memo_tx_hash, recipient: recipient_address, rpc_url: rpc_url}
  end

  describe "full 402 handshake" do
    test "happy path: 402 → hash credential → receipt", %{
      config: config,
      recipient: recipient_address,
      rpc_url: rpc_url
    } do
      # Step 1: Request without credentials → 402 with challenge
      challenge = request_challenge!(config)
      assert challenge.method == "tempo"
      assert challenge.intent == "charge"
      assert challenge.realm == @realm

      sender = fresh_wallet!(rpc_url)
      tx_hash = broadcast_bound_transfer!(sender, recipient_address, @transfer_amount, rpc_url, challenge)

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
      recipient: recipient_address,
      rpc_url: rpc_url
    } do
      # Start an in-memory store and inject it into the config's method_config
      start_supervised!(TempoMemoryStore)

      [entry] = config.method_entries
      updated_entry = %{entry | method_config: Map.put(entry.method_config, "store", TempoMemoryStore)}
      config_with_store = %{config | method_entries: [updated_entry]}

      # First request: 402 → credential → success
      challenge1 = request_challenge!(config_with_store)
      sender1 = fresh_wallet!(rpc_url)
      tx_hash = broadcast_bound_transfer!(sender1, recipient_address, @transfer_amount, rpc_url, challenge1)

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

      credential2 = %Credential{
        challenge: challenge1,
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
      sender = fresh_wallet!(rpc_url)
      memo_config = tempo_config(recipient_address, rpc_url, %{"memo" => @test_memo})

      memo_call =
        TempoTestHelpers.build_call(
          @path_usd,
          TempoTestHelpers.transfer_with_memo_calldata(recipient_address, @transfer_amount, @test_memo)
        )

      {:ok, signed_tx} =
        TempoTxBuilder.build_signed_multicall(
          private_key: sender.private_key,
          calls: [memo_call],
          chain_id: @chain_id,
          rpc_url: rpc_url,
          fee_token: @path_usd,
          nonce: 0
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
      sender = fresh_wallet!(rpc_url)
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

      # Get challenge and submit credential
      challenge = request_challenge!(optimistic_config)
      assert challenge.method == "tempo"

      {:ok, signed_tx} = build_bound_signed_tx(sender, recipient_address, @transfer_amount, rpc_url, challenge)

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
      sender = fresh_wallet!(rpc_url)
      # Use an absurdly large amount that the sender cannot cover.
      # The eth_simulateV1 pre-broadcast simulation should detect the revert and
      # return verification-failed WITHOUT broadcasting.
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

      challenge = request_challenge!(optimistic_config)

      # Build a tx with the impossible amount — it will pass local parsing
      # (find_payment_call matches) but should fail simulation on Moderato.
      {:ok, signed_tx} =
        build_bound_signed_tx(sender, recipient_address, impossible_amount, rpc_url, challenge, gas_limit: 100_000)

      body = submit_credential!(optimistic_config, challenge, %{"type" => "transaction", "signature" => signed_tx})
      assert body["type"] =~ "verification-failed"

      detail = body["detail"]

      assert detail =~ "Pre-broadcast simulation rejected" or detail =~ "Pre-broadcast simulation failed",
             "Expected pre-broadcast simulation to reject the transaction, got: #{inspect(detail)}"
    end

    test "multicall: full transaction is simulated before broadcast", %{
      recipient: recipient_address,
      rpc_url: rpc_url
    } do
      sender = fresh_wallet!(rpc_url)
      impossible_amount = 999_999_999_999_999

      optimistic_config =
        tempo_config(
          recipient_address,
          rpc_url,
          %{"wait_for_confirmation" => false},
          impossible_amount
        )

      challenge = request_challenge!(optimistic_config)
      memo = attribution_memo(challenge)

      harmless_call =
        TempoTestHelpers.build_call(
          @path_usd,
          TempoTestHelpers.transfer_calldata(recipient_address, 1)
        )

      payment_call =
        TempoTestHelpers.build_call(
          @path_usd,
          TempoTestHelpers.transfer_with_memo_calldata(recipient_address, impossible_amount, memo)
        )

      {:ok, signed_tx} =
        TempoTxBuilder.build_signed_multicall(
          private_key: sender.private_key,
          calls: [harmless_call, payment_call],
          chain_id: @chain_id,
          rpc_url: rpc_url,
          fee_token: @path_usd,
          # Pin gas_limit — the payment call is deliberately unaffordable, so
          # auto-estimation (eth_estimateGas) would revert at build time before
          # the tx reaches the simulation step under test. See sibling test above.
          gas_limit: 100_000,
          nonce: 0
        )

      body = submit_credential!(optimistic_config, challenge, %{"type" => "transaction", "signature" => signed_tx})
      assert body["type"] =~ "verification-failed"

      detail = body["detail"]

      assert detail =~ "Pre-broadcast simulation rejected" or detail =~ "Pre-broadcast simulation failed",
             "Expected pre-broadcast simulation to reject the transaction, got: #{inspect(detail)}"
    end
  end

  describe "transaction credential path" do
    test "happy path: 402 → signed tx credential → server broadcasts → receipt", %{
      config: config,
      recipient: recipient_address,
      rpc_url: rpc_url
    } do
      sender = fresh_wallet!(rpc_url)
      # Step 1: Get a 402 challenge
      challenge = request_challenge!(config)
      assert challenge.method == "tempo"

      # Build and sign a 0x76 Tempo Transaction with a matching TIP-20 transfer.
      {:ok, signed_tx} = build_bound_signed_tx(sender, recipient_address, @transfer_amount, rpc_url, challenge)

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
      sender = fresh_wallet!(rpc_url)
      # Build tx transferring to a different address than the challenge expects
      wrong_recipient = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"

      {:ok, signed_tx} =
        TempoTxBuilder.build_signed_transfer(
          private_key: sender.private_key,
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
      sender = fresh_wallet!(rpc_url)
      # Build tx with a different amount than the challenge expects
      wrong_amount = @transfer_amount + 1

      {:ok, signed_tx} =
        TempoTxBuilder.build_signed_transfer(
          private_key: sender.private_key,
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
      sender = fresh_wallet!(rpc_url)
      start_supervised!(TempoMemoryStore)

      config = tempo_config(recipient_address, rpc_url, %{"store" => TempoMemoryStore})

      challenge = request_challenge!(config)
      {:ok, signed_tx} = build_bound_signed_tx(sender, recipient_address, @transfer_amount, rpc_url, challenge)

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

      body = submit_credential!(config, challenge, %{"type" => "transaction", "signature" => signed_tx})
      assert body["type"] =~ "verification-failed"
      assert body["detail"] =~ "already used"
    end
  end

  describe "fee payer co-signing" do
    test "happy path: single transfer with fee payer co-signing", %{
      recipient: recipient_address,
      rpc_url: rpc_url
    } do
      sender = fresh_wallet!(rpc_url)
      fee_payer_key_hex = fresh_fee_payer_hex!(rpc_url)

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
            "fee_payer_private_key" => fee_payer_key_hex,
            "fee_token" => @path_usd
          }
        )

      # 402 → credential → server co-signs → broadcasts → receipt
      challenge = request_challenge!(fee_payer_config)

      # Build a fee-payer transfer (placeholder sig, empty fee_token, expiring
      # nonce + future valid_before so it satisfies the sponsor policy)
      {:ok, signed_tx} =
        build_bound_fee_payer_tx(sender, recipient_address, @transfer_amount, rpc_url, challenge,
          nonce: 0,
          nonce_key: TempoTestHelpers.expiring_nonce_key_int(),
          valid_before: TempoTestHelpers.future_valid_before()
        )

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
      sender = fresh_wallet!(rpc_url)
      fee_payer_key_hex = fresh_fee_payer_hex!(rpc_url)

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
            "fee_payer_private_key" => fee_payer_key_hex,
            "fee_token" => @path_usd
          }
        )

      challenge = request_challenge!(fee_payer_config)

      # Build a multicall with valid payment + rogue extra call
      valid_call = bound_payment_call(recipient_address, @transfer_amount, challenge)
      token_bytes = TempoTestHelpers.decode_address(@path_usd)
      rogue_call = [token_bytes, <<>>, <<0xDE, 0xAD, 0xBE, 0xEF>> <> :binary.copy(<<0>>, 64)]

      {:ok, signed_tx} =
        TempoTxBuilder.build_fee_payer_multicall(
          private_key: sender.private_key,
          calls: [valid_call, rogue_call],
          chain_id: @chain_id,
          rpc_url: rpc_url,
          # Pin gas_limit — the rogue (0xDEADBEEF) call reverts under
          # eth_estimateGas, so auto-estimation would fail the build before the
          # call-scope check (which is what rejects this tx) can run.
          gas_limit: 200_000,
          nonce: 0,
          nonce_key: TempoTestHelpers.expiring_nonce_key_int(),
          valid_before: TempoTestHelpers.future_valid_before()
        )

      body = submit_credential!(fee_payer_config, challenge, %{"type" => "transaction", "signature" => signed_tx})
      assert body["type"] =~ "verification-failed"
      assert body["detail"] =~ "disallowed call pattern"
    end
  end

  describe "fee-payer validation" do
    defp fee_payer_config(recipient_address, rpc_url, fee_payer_key_hex, extra \\ %{}) do
      tempo_config(
        recipient_address,
        rpc_url,
        Map.merge(
          %{
            "fee_payer" => true,
            "fee_payer_private_key" => fee_payer_key_hex,
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
      fee_payer_key_hex = fresh_fee_payer_hex!(rpc_url)
      config = fee_payer_config(recipient_address, rpc_url, fee_payer_key_hex)

      body = submit_credential!(config, %{"type" => "hash", "hash" => tx_hash})
      assert body["type"] =~ "invalid-payload"
      assert body["detail"] =~ "feePayer"
    end

    test "rejects transaction missing fee_payer_signature placeholder", %{
      recipient: recipient_address,
      rpc_url: rpc_url
    } do
      sender = fresh_wallet!(rpc_url)
      fee_payer_key_hex = fresh_fee_payer_hex!(rpc_url)
      config = fee_payer_config(recipient_address, rpc_url, fee_payer_key_hex)

      # build_signed_transfer sets fee_payer_signature = <<>> (absent), NOT <<0x00>> (placeholder).
      # Expiring nonce + future valid_before so the tx clears the economics/validity
      # gate and the missing-placeholder check is what rejects it.
      {:ok, non_fp_tx} =
        TempoTxBuilder.build_signed_transfer(
          private_key: sender.private_key,
          token: @path_usd,
          recipient: recipient_address,
          amount: @transfer_amount,
          chain_id: @chain_id,
          rpc_url: rpc_url,
          fee_token: @path_usd,
          nonce_key: TempoTestHelpers.expiring_nonce_key_int(),
          valid_before: TempoTestHelpers.future_valid_before()
        )

      body = submit_credential!(config, %{"type" => "transaction", "signature" => non_fp_tx})
      assert body["type"] =~ "verification-failed"
      assert body["detail"] =~ "placeholder"
    end

    test "rejects transaction with non-empty fee_token in fee-payer mode", %{
      recipient: recipient_address,
      rpc_url: rpc_url
    } do
      fee_payer_key_hex = fresh_fee_payer_hex!(rpc_url)
      config = fee_payer_config(recipient_address, rpc_url, fee_payer_key_hex)

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
        # nonce_key: expiring (so the validity gate passes and fee_token is the rejection)
        TempoTestHelpers.expiring_nonce_key(),
        <<>>,
        # valid_before: future (same reason)
        :binary.encode_unsigned(TempoTestHelpers.future_valid_before()),
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

    test "rejects a sponsored tx with a non-expiring nonce key before broadcast", %{
      recipient: recipient_address,
      rpc_url: rpc_url
    } do
      sender = fresh_wallet!(rpc_url)
      fee_payer_key_hex = fresh_fee_payer_hex!(rpc_url)
      config = fee_payer_config(recipient_address, rpc_url, fee_payer_key_hex)

      # nonce_key omitted → defaults to 0 (a fixed, non-expiring nonce). valid_before
      # is in-window so the expiring-nonce check is the one that must fire.
      {:ok, signed_tx} =
        TempoTxBuilder.build_fee_payer_transfer(
          private_key: sender.private_key,
          token: @path_usd,
          recipient: recipient_address,
          amount: @transfer_amount,
          chain_id: @chain_id,
          rpc_url: rpc_url,
          nonce: 0,
          valid_before: TempoTestHelpers.future_valid_before()
        )

      body = submit_credential!(config, %{"type" => "transaction", "signature" => signed_tx})
      assert body["type"] =~ "verification-failed"
      assert body["detail"] =~ "expiring nonce key"
    end

    test "rejects a sponsored tx whose validity window exceeds the policy", %{
      recipient: recipient_address,
      rpc_url: rpc_url
    } do
      sender = fresh_wallet!(rpc_url)
      fee_payer_key_hex = fresh_fee_payer_hex!(rpc_url)
      config = fee_payer_config(recipient_address, rpc_url, fee_payer_key_hex)

      # Expiring nonce but valid_before a full day out — far beyond the 15-min
      # default window, so the server must refuse to co-sign a long-lived sponsorship.
      {:ok, signed_tx} =
        TempoTxBuilder.build_fee_payer_transfer(
          private_key: sender.private_key,
          token: @path_usd,
          recipient: recipient_address,
          amount: @transfer_amount,
          chain_id: @chain_id,
          rpc_url: rpc_url,
          nonce: 0,
          nonce_key: TempoTestHelpers.expiring_nonce_key_int(),
          valid_before: System.os_time(:second) + 86_400
        )

      body = submit_credential!(config, %{"type" => "transaction", "signature" => signed_tx})
      assert body["type"] =~ "verification-failed"
      assert body["detail"] =~ "validity window"
    end
  end

  describe "fee-payer dedup" do
    test "co-signed transaction rejected on second submission", %{
      recipient: recipient_address,
      rpc_url: rpc_url
    } do
      sender = fresh_wallet!(rpc_url)
      fee_payer_key_hex = fresh_fee_payer_hex!(rpc_url)

      start_supervised!(TempoMemoryStore)

      config =
        tempo_config(
          recipient_address,
          rpc_url,
          %{
            "fee_payer" => true,
            "fee_payer_private_key" => fee_payer_key_hex,
            "fee_token" => @path_usd,
            "store" => TempoMemoryStore
          }
        )

      # First: co-signed and broadcast succeeds
      challenge = request_challenge!(config)

      {:ok, signed_tx} =
        build_bound_fee_payer_tx(sender, recipient_address, @transfer_amount, rpc_url, challenge,
          nonce: 0,
          nonce_key: TempoTestHelpers.expiring_nonce_key_int(),
          valid_before: TempoTestHelpers.future_valid_before()
        )

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
      body = submit_credential!(config, challenge, %{"type" => "transaction", "signature" => signed_tx})
      assert body["type"] =~ "verification-failed"
      assert body["detail"] =~ "already used"
    end
  end

  describe "fee payer + optimistic broadcast" do
    test "fee payer co-signs and optimistically broadcasts transfer", %{
      recipient: recipient_address,
      rpc_url: rpc_url
    } do
      sender = fresh_wallet!(rpc_url)
      fee_payer_key_hex = fresh_fee_payer_hex!(rpc_url)

      start_supervised!(TempoMemoryStore)

      config =
        tempo_config(
          recipient_address,
          rpc_url,
          %{
            "fee_payer" => true,
            "fee_payer_private_key" => fee_payer_key_hex,
            "fee_token" => @path_usd,
            "wait_for_confirmation" => false,
            "store" => TempoMemoryStore
          }
        )

      challenge = request_challenge!(config)

      {:ok, signed_tx} =
        build_bound_fee_payer_tx(sender, recipient_address, @transfer_amount, rpc_url, challenge,
          nonce: 0,
          # Fee-payer txs MUST carry the expiring nonce key + a valid_before
          # window, or MPP.Methods.Tempo.FeePayerPolicy rejects them before
          # co-signing (anti-replay). Every other fee-payer build below sets these.
          nonce_key: TempoTestHelpers.expiring_nonce_key_int(),
          valid_before: TempoTestHelpers.future_valid_before()
        )

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
      sender = fresh_wallet!(rpc_url)
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

      # First submission: optimistic pass-through
      challenge = request_challenge!(config)

      {:ok, signed_tx} = build_bound_signed_tx(sender, recipient_address, @transfer_amount, rpc_url, challenge)

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
      body = submit_credential!(config, challenge, %{"type" => "transaction", "signature" => signed_tx})
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
    submit_credential!(config, challenge, payload)
  end

  defp submit_credential!(config, challenge, payload) do
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

  defp broadcast_bound_transfer!(sender, recipient_address, amount, rpc_url, challenge) do
    {:ok, signed_tx} = build_bound_signed_tx(sender, recipient_address, amount, rpc_url, challenge)
    broadcast_raw_transaction_sync!(signed_tx, rpc_url)
  end

  defp build_bound_signed_tx(sender, recipient_address, amount, rpc_url, challenge, opts \\ []) do
    [
      private_key: sender.private_key,
      calls: [bound_payment_call(recipient_address, amount, challenge)],
      chain_id: @chain_id,
      rpc_url: rpc_url,
      fee_token: @path_usd,
      nonce: 0
    ]
    |> Keyword.merge(opts)
    |> TempoTxBuilder.build_signed_multicall()
  end

  defp build_bound_fee_payer_tx(sender, recipient_address, amount, rpc_url, challenge, opts) do
    [
      private_key: sender.private_key,
      calls: [bound_payment_call(recipient_address, amount, challenge)],
      chain_id: @chain_id,
      rpc_url: rpc_url,
      nonce: 0,
      nonce_key: TempoTestHelpers.expiring_nonce_key_int(),
      valid_before: TempoTestHelpers.future_valid_before()
    ]
    |> Keyword.merge(opts)
    |> TempoTxBuilder.build_fee_payer_multicall()
  end

  defp bound_payment_call(recipient_address, amount, challenge) do
    TempoTestHelpers.build_call(
      @path_usd,
      TempoTestHelpers.transfer_with_memo_calldata(recipient_address, amount, attribution_memo(challenge))
    )
  end

  defp attribution_memo(challenge) do
    tag = binary_part(ExSha3.keccak_256("mpp"), 0, 4)
    server = binary_part(ExSha3.keccak_256(challenge.realm), 0, @attribution_server_fingerprint_length)
    client = <<0::size(@attribution_client_fingerprint_length * 8)>>
    nonce = binary_part(ExSha3.keccak_256(challenge.id), 0, @attribution_nonce_length)

    "0x" <> Base.encode16(tag <> <<@attribution_memo_version>> <> server <> client <> nonce, case: :lower)
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

  # Mints a fresh, funded wallet on Moderato via onchain_tempo's Faucet helper.
  # Returns %{private_key: <32 bytes>, address_hex: "0x...", address_bin: <20 bytes>}.
  # Flunks loudly if the faucet is unavailable so "0 failures / 0 tests run" can't hide.
  defp fresh_wallet!(rpc_url) do
    case Faucet.fresh_funded_wallet(rpc_url: rpc_url) do
      {:ok, wallet} ->
        wallet

      {:error, msg} ->
        flunk("""
        Tempo Moderato faucet failed to fund a fresh test wallet.

        Error: #{msg}
        RPC URL: #{rpc_url}

        The Tempo Moderato testnet faucet may be down or rate-limited.
        Set TEMPO_RPC_URL to override: export TEMPO_RPC_URL="https://rpc.moderato.tempo.xyz"
        """)
    end
  end

  # Mints a fresh, funded wallet and returns its private key as lowercase hex
  # (the format `MPP.Methods.Tempo`'s `fee_payer_private_key` method_config expects).
  defp fresh_fee_payer_hex!(rpc_url) do
    wallet = fresh_wallet!(rpc_url)
    Base.encode16(wallet.private_key, case: :lower)
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
