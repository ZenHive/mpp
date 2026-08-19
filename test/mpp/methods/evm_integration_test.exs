defmodule MPP.Methods.EVMIntegrationTest do
  @moduledoc """
  Integration tests for the EVM payment method against a real EVM chain (Sepolia).

  Tests both ERC-20 (WETH) and native ETH transfer verification via real JSON-RPC
  calls, plus the full 402 Plug handshake flow.

  Requires two environment variables:
    * `ETH_SEPOLIA_RPC_URL` (or `EVM_RPC_URL`) — Sepolia JSON-RPC endpoint
    * `ETH_SEPOLIA_PRIVATE_KEY` (or `EVM_PRIVATE_KEY`) — hex private key of a funded Sepolia account

  Run with: `mix test test/mpp/methods/evm_integration_test.exs --include integration`
  """

  use ExUnit.Case, async: false

  alias MPP.Credential
  alias MPP.Headers
  alias MPP.Methods.EVM
  alias MPP.Receipt

  @moduletag :integration

  # --- Sepolia constants ---
  @default_chain_id 11_155_111

  # Canonical WETH on Sepolia
  @weth_address "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14"

  # deposit() function selector — wraps ETH into WETH
  @weth_deposit_selector "d0e30db0"

  # Hardhat account #1 — deterministic testnet-only key (no value on mainnet)
  @recipient_key "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"

  # Small amounts to minimize testnet resource usage
  @weth_amount 10_000
  @eth_amount 10_000
  @private_key_bytes 32

  # Plug config
  @hmac_secret "test-hmac-secret-for-evm-integration"
  @realm "evm-integration-test.example.com"

  # Polling config for tx confirmation (Sepolia has ~12s blocks)
  @confirmation_poll_interval_ms 3_000
  @confirmation_max_attempts 20

  setup_all do
    if !Code.ensure_loaded?(Onchain) do
      flunk("""
      Missing `onchain` dependency!

      Add it to your mix.exs:
        {:onchain, "~> 0.4"}

      Then run: mix deps.get
      """)
    end

    rpc_url = System.get_env("ETH_SEPOLIA_RPC_URL") || System.get_env("EVM_RPC_URL")
    private_key = System.get_env("ETH_SEPOLIA_PRIVATE_KEY") || System.get_env("EVM_PRIVATE_KEY")

    if is_nil(rpc_url) or is_nil(private_key) do
      flunk("""
      Missing EVM testnet credentials!

      Set these environment variables:
        export ETH_SEPOLIA_RPC_URL="https://ethereum-sepolia-rpc.publicnode.com"
        export ETH_SEPOLIA_PRIVATE_KEY="0x<your-funded-sepolia-private-key>"

      Then run:
        mix test test/mpp/methods/evm_integration_test.exs --include integration
      """)
    end

    rpc_opts = [rpc_url: rpc_url]

    # Derive addresses
    {:ok, sender_address} = Onchain.Signer.address_from_key(private_key)
    {:ok, recipient_address} = Onchain.Signer.address_from_key(@recipient_key)
    native_recipient_address = fresh_eoa_address!()

    # Get sender nonce
    {:ok, nonce} = Onchain.RPC.get_transaction_count(sender_address, rpc_opts)

    tx_opts =
      Keyword.merge(rpc_opts,
        private_key: private_key,
        chain_id: @default_chain_id,
        nonce: nonce
      )

    # Step 1: Wrap ETH → WETH via deposit()
    deposit_calldata = Onchain.Hex.decode!("0x" <> @weth_deposit_selector)

    {:ok, wrap_hash} =
      Onchain.Signer.send_transaction(
        @weth_address,
        deposit_calldata,
        Keyword.put(tx_opts, :value, @weth_amount)
      )

    wrap_receipt = wait_for_receipt!(wrap_hash, rpc_opts)

    if wrap_receipt.status != 1 do
      flunk("Test setup: WETH deposit reverted (tx: #{wrap_hash})")
    end

    # Step 2: Transfer WETH from sender to recipient (ERC-20 test tx)
    {:ok, erc20_tx_hash} =
      Onchain.ERC20.transfer(
        @weth_address,
        recipient_address,
        @weth_amount,
        Keyword.put(tx_opts, :nonce, nonce + 1)
      )

    erc20_receipt = wait_for_receipt!(erc20_tx_hash, rpc_opts)

    if erc20_receipt.status != 1 do
      flunk("Test setup: WETH transfer reverted (tx: #{erc20_tx_hash})")
    end

    # Step 3: Send native ETH to a distinct EOA. The fixed Hardhat recipient has
    # bytecode on Sepolia and reverts plain native transfer gas estimation.
    {:ok, eth_tx_hash} =
      Onchain.Signer.send_transaction(
        native_recipient_address,
        <<>>,
        Keyword.merge(tx_opts, nonce: nonce + 2, value: @eth_amount)
      )

    eth_receipt = wait_for_receipt!(eth_tx_hash, rpc_opts)

    if eth_receipt.status != 1 do
      flunk("Test setup: Native ETH transfer reverted (tx: #{eth_tx_hash})")
    end

    # Build Plug configs for 402 handshake tests
    erc20_config =
      MPP.Plug.init(
        secret_key: @hmac_secret,
        realm: @realm,
        method: EVM,
        amount: Integer.to_string(@weth_amount),
        currency: @weth_address,
        recipient: recipient_address,
        method_config: %{
          "rpc_url" => rpc_url,
          "chain_id" => @default_chain_id
        }
      )

    eth_config =
      MPP.Plug.init(
        secret_key: @hmac_secret,
        realm: @realm,
        method: EVM,
        amount: Integer.to_string(@eth_amount),
        currency: "ETH",
        recipient: native_recipient_address,
        method_config: %{
          "rpc_url" => rpc_url,
          "chain_id" => @default_chain_id
        }
      )

    {:ok,
     erc20_config: erc20_config,
     eth_config: eth_config,
     erc20_tx_hash: erc20_tx_hash,
     eth_tx_hash: eth_tx_hash,
     sender: sender_address,
     recipient: recipient_address,
     eth_recipient: native_recipient_address,
     rpc_url: rpc_url}
  end

  defp fresh_eoa_address! do
    private_key = "0x" <> Base.encode16(:crypto.strong_rand_bytes(@private_key_bytes), case: :lower)
    Onchain.Signer.address_from_key!(private_key)
  end

  describe "direct verify/2 — ERC-20" do
    test "verifies a real WETH transfer on Sepolia", %{
      erc20_tx_hash: tx_hash,
      recipient: recipient,
      rpc_url: rpc_url
    } do
      charge = build_charge(@weth_address, @weth_amount, recipient, rpc_url)

      assert {:ok, %Receipt{} = receipt} = EVM.verify(%{"hash" => tx_hash}, charge)
      assert receipt.method == "evm"
      assert receipt.reference == tx_hash
    end

    test "rejects wrong amount", %{
      erc20_tx_hash: tx_hash,
      recipient: recipient,
      rpc_url: rpc_url
    } do
      charge = build_charge(@weth_address, @weth_amount + 1, recipient, rpc_url)

      assert {:error, error} = EVM.verify(%{"hash" => tx_hash}, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "No matching Transfer"
    end

    test "rejects wrong recipient", %{
      erc20_tx_hash: tx_hash,
      rpc_url: rpc_url
    } do
      wrong_recipient = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
      charge = build_charge(@weth_address, @weth_amount, wrong_recipient, rpc_url)

      assert {:error, error} = EVM.verify(%{"hash" => tx_hash}, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "No matching Transfer"
    end

    test "returns error for non-existent tx hash", %{
      recipient: recipient,
      rpc_url: rpc_url
    } do
      fake_hash = "0x" <> String.duplicate("ab", 32)
      charge = build_charge(@weth_address, @weth_amount, recipient, rpc_url)

      assert {:error, error} = EVM.verify(%{"hash" => fake_hash}, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "not found"
    end
  end

  describe "direct verify/2 — native ETH" do
    test "verifies a real native ETH transfer on Sepolia", %{
      eth_tx_hash: tx_hash,
      eth_recipient: recipient,
      rpc_url: rpc_url
    } do
      charge = build_charge("ETH", @eth_amount, recipient, rpc_url)

      assert {:ok, %Receipt{} = receipt} = EVM.verify(%{"hash" => tx_hash}, charge)
      assert receipt.method == "evm"
      assert receipt.reference == tx_hash
    end

    test "rejects wrong value", %{
      eth_tx_hash: tx_hash,
      eth_recipient: recipient,
      rpc_url: rpc_url
    } do
      charge = build_charge("ETH", @eth_amount + 1, recipient, rpc_url)

      assert {:error, error} = EVM.verify(%{"hash" => tx_hash}, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "value"
    end

    test "rejects wrong recipient", %{
      eth_tx_hash: tx_hash,
      rpc_url: rpc_url
    } do
      wrong_recipient = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
      charge = build_charge("ETH", @eth_amount, wrong_recipient, rpc_url)

      assert {:error, error} = EVM.verify(%{"hash" => tx_hash}, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "recipient"
    end
  end

  describe "full 402 handshake" do
    test "ERC-20: 402 → credential → receipt", %{
      erc20_config: config,
      erc20_tx_hash: tx_hash
    } do
      # Step 1: Request without credentials → 402 with challenge
      challenge = request_challenge!(config)
      assert challenge.method == "evm"
      assert challenge.intent == "charge"
      assert challenge.realm == @realm

      # Step 2: Build credential with tx hash + echoed challenge
      credential = %Credential{
        challenge: challenge,
        payload: %{"hash" => tx_hash}
      }

      auth_header = Headers.format_credential(credential)

      # Step 3: Retry with credential → success with receipt
      conn =
        :get
        |> Plug.Test.conn("/api/data")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> MPP.Plug.call(config)

      assert conn.status == nil, "Plug should pass through on valid credential"
      assert %Receipt{} = receipt = conn.assigns[:mpp_receipt]
      assert receipt.status == "success"
      assert receipt.method == "evm"
      assert receipt.reference == tx_hash

      # Verify Payment-Receipt header
      assert [receipt_header] = Plug.Conn.get_resp_header(conn, "payment-receipt")
      assert {:ok, parsed_receipt} = Headers.parse_receipt(receipt_header)
      assert parsed_receipt.reference == receipt.reference
    end

    test "native ETH: 402 → credential → receipt", %{
      eth_config: config,
      eth_tx_hash: tx_hash
    } do
      challenge = request_challenge!(config)
      assert challenge.method == "evm"

      credential = %Credential{
        challenge: challenge,
        payload: %{"hash" => tx_hash}
      }

      conn =
        :get
        |> Plug.Test.conn("/api/data")
        |> Plug.Conn.put_req_header("authorization", Headers.format_credential(credential))
        |> MPP.Plug.call(config)

      assert conn.status == nil, "Plug should pass through on valid credential"
      assert %Receipt{} = receipt = conn.assigns[:mpp_receipt]
      assert receipt.status == "success"
      assert receipt.method == "evm"
      assert receipt.reference == tx_hash
    end

    test "challenge includes chainId in method details", %{erc20_config: config} do
      challenge = request_challenge!(config)
      assert {:ok, request_json} = Base.url_decode64(challenge.request, padding: false)
      assert {:ok, request_map} = Jason.decode(request_json)

      assert request_map["methodDetails"]["chainId"] == @default_chain_id
      assert request_map["methodDetails"]["credentialTypes"] == ["transaction", "hash"]
      assert request_map["methodDetails"]["permit2Address"] == "0x000000000022D473030F116dDEE9F6B43aC78BA3"
    end
  end

  # --- Private helpers ---

  # Builds a Charge struct for direct verify/2 calls.
  defp build_charge(currency, amount, recipient, rpc_url) do
    %MPP.Intents.Charge{
      amount: Integer.to_string(amount),
      currency: currency,
      recipient: recipient,
      method_details: %{
        "rpc_url" => rpc_url,
        "chain_id" => @default_chain_id,
        # These transfer-matching tests reuse the same real on-chain hash across
        # positive and negative cases. Dedup is on by default now, so opt out
        # (`store: false`) — otherwise the first verify marks the hash and later
        # cases short-circuit on "already used" before recipient/value are checked.
        "store" => false
      }
    }
  end

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

  # Polls for transaction receipt until confirmed or max attempts reached.
  defp wait_for_receipt!(tx_hash, rpc_opts) do
    wait_for_receipt!(tx_hash, rpc_opts, 0)
  end

  defp wait_for_receipt!(tx_hash, rpc_opts, attempt) when attempt >= @confirmation_max_attempts do
    rpc_url = Keyword.get(rpc_opts, :rpc_url, "unknown")

    flunk("""
    Transaction not confirmed after #{@confirmation_max_attempts} attempts (#{@confirmation_max_attempts * @confirmation_poll_interval_ms / 1_000}s).

    Tx hash: #{tx_hash}
    RPC URL: #{rpc_url}

    The Sepolia testnet may be congested or the transaction may have failed.
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
