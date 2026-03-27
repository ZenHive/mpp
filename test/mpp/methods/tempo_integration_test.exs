defmodule MPP.Methods.TempoIntegrationTest do
  @moduledoc """
  Integration tests for the Tempo payment method against Tempo's Moderato testnet.

  Creates a real TIP-20 (pathUSD) transfer on-chain, then verifies the full 402
  handshake using the transaction hash as a `type="hash"` credential.

  Run with: `mix test test/mpp/methods/tempo_integration_test.exs --include integration`
  """

  use ExUnit.Case, async: false

  alias MPP.Credential
  alias MPP.Headers
  alias MPP.Methods.Tempo
  alias MPP.Receipt

  @moduletag :integration

  # --- Testnet constants ---
  @default_rpc_url "https://rpc.moderato.tempo.xyz"
  @chain_id 42_431
  @path_usd "0x20c0000000000000000000000000000000000000"

  # Deterministic testnet-only private keys (no value on mainnet)
  @sender_key "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  @recipient_key "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"

  # 1 pathUSD (6 decimals)
  @transfer_amount 1_000_000

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

    {:ok, config: config, tx_hash: tx_hash, sender: sender_address, recipient: recipient_address}
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

    test "rejects transaction type as not yet implemented", %{config: config} do
      body = submit_credential!(config, %{"type" => "transaction", "signature" => "0xdead"})
      assert body["type"] =~ "verification-failed"
      assert body["detail"] =~ "not yet implemented"
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
