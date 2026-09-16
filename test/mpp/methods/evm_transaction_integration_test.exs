defmodule MPP.Methods.EVMTransactionIntegrationTest do
  @moduledoc """
  Live Sepolia integration for EVM `type=transaction` credentials.

  The client signs an EIP-1559 ERC-20 `transfer`; the server broadcasts it and
  requires a matching Transfer event (draft-evm-charge-00 § Transaction
  Verification). Authority: live Sepolia + draft-evm-charge-00 at
  tempoxyz/mpp-specs@582b890. Re-checked at pickup: mppx still implements
  authorization only (`src/evm/Types.ts` `credentialTypes = ['authorization']`);
  mpp-rs has no EVM charge method (`src/evm.rs` is address/amount helpers).

  Requires:
    * `ETH_SEPOLIA_RPC_URL` (or `EVM_RPC_URL`)
    * `ETH_SEPOLIA_PRIVATE_KEY` (or `EVM_PRIVATE_KEY`) — funded Sepolia ETH

  Run with:
    mix test test/mpp/methods/evm_transaction_integration_test.exs --include integration
  """

  use ExUnit.Case, async: false

  alias MPP.Headers
  alias MPP.Intents.Charge
  alias MPP.Methods.EVM
  alias MPP.Receipt
  alias MPP.Test.EVMTransaction

  @moduletag :integration

  @default_chain_id 11_155_111
  @weth "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14"
  @weth_deposit_selector "d0e30db0"
  @recipient_key "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
  @weth_amount 10_000
  @hmac_secret "test-hmac-secret-for-evm-transaction"
  @realm "evm-transaction-test.example.com"
  @confirmation_poll_interval_ms 3_000
  @confirmation_max_attempts 20

  setup_all do
    rpc_url = System.get_env("ETH_SEPOLIA_RPC_URL") || System.get_env("EVM_RPC_URL")
    private_key = System.get_env("ETH_SEPOLIA_PRIVATE_KEY") || System.get_env("EVM_PRIVATE_KEY")

    if is_nil(rpc_url) or is_nil(private_key) do
      flunk("""
      Missing EVM testnet credentials!

      Set these environment variables:
        export ETH_SEPOLIA_RPC_URL="https://ethereum-sepolia-rpc.publicnode.com"
        export ETH_SEPOLIA_PRIVATE_KEY="0x<your-funded-sepolia-private-key>"

      Then run:
        mix test test/mpp/methods/evm_transaction_integration_test.exs --include integration
      """)
    end

    rpc_opts = [rpc_url: rpc_url]
    {:ok, sender} = Onchain.Signer.address_from_key(private_key)
    {:ok, recipient} = Onchain.Signer.address_from_key(@recipient_key)
    {:ok, nonce} = Onchain.RPC.get_transaction_count(sender, rpc_opts)

    deposit = Onchain.Hex.decode!("0x" <> @weth_deposit_selector)

    {:ok, wrap_hash} =
      Onchain.Signer.send_transaction(
        @weth,
        deposit,
        Keyword.merge(rpc_opts,
          private_key: private_key,
          chain_id: @default_chain_id,
          nonce: nonce,
          value: @weth_amount
        )
      )

    wrap_receipt = wait_for_receipt!(wrap_hash, rpc_opts)

    if wrap_receipt.status != 1 do
      flunk("Test setup: WETH deposit reverted (tx: #{wrap_hash})")
    end

    {:ok, rpc_url: rpc_url, private_key: private_key, sender: sender, recipient: recipient}
  end

  test "server-broadcasts a signed WETH transfer and requires the Transfer event", %{
    rpc_url: rpc_url,
    private_key: private_key,
    recipient: recipient
  } do
    signed = sign_weth_transfer(private_key, recipient, rpc_url)
    charge = transaction_charge(recipient, rpc_url, store: :default)

    assert {:ok, %Receipt{} = receipt} = EVM.verify(signed.payload, charge)
    assert receipt.method == "evm"
    assert receipt.reference == signed.hash

    on_chain = wait_for_receipt!(signed.hash, rpc_url: rpc_url)
    assert on_chain.status == 1
    {:ok, transfers} = Onchain.Transfer.parse_logs(on_chain.logs)

    assert Enum.any?(transfers, fn transfer ->
             Onchain.Address.equal?(transfer.token, @weth) and
               Onchain.Address.equal?(transfer.to, recipient) and
               transfer.amount == @weth_amount
           end)

    assert {:error, replay} = EVM.verify(signed.payload, charge)
    assert replay.detail =~ "already used"
  end

  test "rejects a signed transfer whose recipient does not match the charge", %{
    rpc_url: rpc_url,
    private_key: private_key,
    recipient: recipient
  } do
    wrong = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
    signed = sign_weth_transfer(private_key, wrong, rpc_url)
    charge = transaction_charge(recipient, rpc_url)

    assert {:error, error} = EVM.verify(signed.payload, charge)
    assert error.type =~ "verification-failed"
    assert error.detail =~ "recipient"
  end

  test "402 challenge advertises transaction only when enabled", %{
    recipient: recipient,
    rpc_url: rpc_url
  } do
    enabled =
      MPP.Plug.init(
        secret_key: @hmac_secret,
        realm: @realm,
        method: EVM,
        amount: Integer.to_string(@weth_amount),
        currency: @weth,
        recipient: recipient,
        method_config: %{
          "rpc_url" => rpc_url,
          "chain_id" => @default_chain_id,
          "transaction" => true
        }
      )

    disabled =
      MPP.Plug.init(
        secret_key: @hmac_secret,
        realm: @realm,
        method: EVM,
        amount: Integer.to_string(@weth_amount),
        currency: @weth,
        recipient: recipient,
        method_config: %{
          "rpc_url" => rpc_url,
          "chain_id" => @default_chain_id
        }
      )

    assert challenge_types(enabled) == ["transaction", "hash"]
    assert challenge_types(disabled) == ["hash"]
  end

  defp sign_weth_transfer(private_key, recipient, rpc_url) do
    {:ok, sender} = Onchain.Signer.address_from_key(private_key)
    {:ok, nonce} = Onchain.RPC.get_transaction_count(sender, rpc_url: rpc_url, block: "pending")

    EVMTransaction.sign_transfer(%{
      private_key: private_key,
      chain_id: @default_chain_id,
      currency: @weth,
      recipient: recipient,
      amount: @weth_amount,
      nonce: nonce,
      max_fee_per_gas: {50, :gwei},
      max_priority_fee_per_gas: {2, :gwei}
    })
  end

  defp transaction_charge(recipient, rpc_url, opts \\ []) do
    store = Keyword.get(opts, :store, false)

    details = %{
      "rpc_url" => rpc_url,
      "chain_id" => @default_chain_id,
      "transaction" => true,
      "challenge_expires" => DateTime.utc_now() |> DateTime.shift(minute: 10) |> DateTime.to_iso8601()
    }

    details = if store == :default, do: details, else: Map.put(details, "store", store)

    %Charge{
      amount: Integer.to_string(@weth_amount),
      currency: @weth,
      recipient: recipient,
      method_details: details
    }
  end

  defp challenge_types(config) do
    conn = :get |> Plug.Test.conn("/api/data") |> MPP.Plug.call(config)
    assert conn.status == 402
    assert [header] = Plug.Conn.get_resp_header(conn, "www-authenticate")
    assert {:ok, challenge} = Headers.parse_challenge(header)
    assert {:ok, json} = Base.url_decode64(challenge.request, padding: false)
    assert {:ok, request} = Jason.decode(json)
    request["methodDetails"]["credentialTypes"]
  end

  defp wait_for_receipt!(tx_hash, rpc_opts) do
    wait_for_receipt!(tx_hash, rpc_opts, 0)
  end

  defp wait_for_receipt!(tx_hash, rpc_opts, attempt) when attempt >= @confirmation_max_attempts do
    flunk("""
    Transaction not confirmed after #{@confirmation_max_attempts} attempts.

    Tx hash: #{tx_hash}
    RPC URL: #{Keyword.get(rpc_opts, :rpc_url, "unknown")}
    """)
  end

  defp wait_for_receipt!(tx_hash, rpc_opts, attempt) do
    case Onchain.RPC.get_transaction_receipt(tx_hash, rpc_opts) do
      {:ok, nil} ->
        receive do
        after
          @confirmation_poll_interval_ms -> wait_for_receipt!(tx_hash, rpc_opts, attempt + 1)
        end

      {:ok, receipt} ->
        receipt

      {:error, reason} ->
        flunk("eth_getTransactionReceipt failed: #{inspect(reason)}")
    end
  end
end
