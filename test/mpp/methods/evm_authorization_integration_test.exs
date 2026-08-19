defmodule MPP.Methods.EVMAuthorizationIntegrationTest do
  @moduledoc """
  Live Sepolia integration for EVM EIP-3009 `type=authorization` credentials.

  Requires:
    * `ETH_SEPOLIA_RPC_URL` (or `EVM_RPC_URL`)
    * `ETH_SEPOLIA_PRIVATE_KEY` (or `EVM_PRIVATE_KEY`) — funded Sepolia ETH for gas
    * Sepolia USDC on that account for the successful settlement + nonce-replay
      tests (Circle faucet: https://faucet.circle.com/)

  Run with:
    mix test test/mpp/methods/evm_authorization_integration_test.exs --include integration
  """

  use ExUnit.Case, async: false

  alias MPP.Headers
  alias MPP.Intents.Charge
  alias MPP.Methods.EVM
  alias MPP.Receipt
  alias MPP.Test.EVMAuthorization

  @moduletag :integration

  @default_chain_id 11_155_111
  @usdc "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"
  @usdc_name "USDC"
  @usdc_version "2"
  @hmac_secret "test-hmac-secret-for-evm-authorization"
  @realm "evm-authorization-test.example.com"
  @recipient_key "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"

  setup_all do
    rpc_url = System.get_env("ETH_SEPOLIA_RPC_URL") || System.get_env("EVM_RPC_URL")
    private_key = System.get_env("ETH_SEPOLIA_PRIVATE_KEY") || System.get_env("EVM_PRIVATE_KEY")

    if is_nil(rpc_url) or is_nil(private_key) do
      flunk("""
      Missing EVM testnet credentials!

      Set these environment variables:
        export ETH_SEPOLIA_RPC_URL="https://ethereum-sepolia-rpc.publicnode.com"
        export ETH_SEPOLIA_PRIVATE_KEY="0x<your-funded-sepolia-private-key>"

      Get Sepolia USDC from Circle's faucet:
        https://faucet.circle.com/

      Then run:
        mix test test/mpp/methods/evm_authorization_integration_test.exs --include integration
      """)
    end

    {:ok, sender} = Onchain.Signer.address_from_key(private_key)
    {:ok, recipient} = Onchain.Signer.address_from_key(@recipient_key)

    {:ok, rpc_url: rpc_url, private_key: private_key, sender: sender, recipient: recipient}
  end

  test "Circle USDC rejects a correctly signed authorization that exceeds the payer balance", %{
    sender: sender,
    recipient: recipient,
    rpc_url: rpc_url,
    private_key: private_key
  } do
    {:ok, from_bin} = Onchain.Address.validate(sender)

    {:ok, [balance]} =
      Onchain.Contract.call(@usdc, "balanceOf(address)", [from_bin], "(uint256)", rpc_url: rpc_url)

    amount = Integer.to_string(balance + 1)
    charge = authorization_charge(amount, recipient, rpc_url, private_key)
    payload = authorization_payload(charge, sender, amount)

    assert {:error, error} = EVM.verify(payload, charge)
    assert error.type =~ "settlement-failed"
    assert error.detail == "ERC20: transfer amount exceeds balance"
  end

  test "settles transferWithAuthorization and rejects reuse of the same challengeHash nonce", %{
    sender: sender,
    recipient: recipient,
    rpc_url: rpc_url,
    private_key: private_key
  } do
    {:ok, from_bin} = Onchain.Address.validate(sender)

    {:ok, [balance]} =
      Onchain.Contract.call(@usdc, "balanceOf(address)", [from_bin], "(uint256)", rpc_url: rpc_url)

    if balance < 1 do
      flunk("""
      Missing Sepolia USDC for EIP-3009 settlement!

      Account #{sender} has #{balance} testnet USDC on #{@usdc}.

      Get Sepolia USDC from Circle's faucet:
        https://faucet.circle.com/

      Request USDC on Ethereum Sepolia for #{sender}, then rerun:
        mix test test/mpp/methods/evm_authorization_integration_test.exs --include integration
      """)
    end

    amount = "1"
    charge = authorization_charge(amount, recipient, rpc_url, private_key)
    payload = authorization_payload(charge, sender, amount)

    assert {:ok, %Receipt{} = receipt} = EVM.verify(payload, charge)
    assert receipt.method == "evm"
    assert receipt.reference =~ ~r/^0x[0-9a-f]{64}$/

    assert {:error, replay} = EVM.verify(payload, charge)
    assert replay.detail =~ "already used"
  end

  test "402 challenge advertises authorization when settlement is configured", %{
    recipient: recipient,
    rpc_url: rpc_url,
    private_key: private_key
  } do
    config =
      MPP.Plug.init(
        secret_key: @hmac_secret,
        realm: @realm,
        method: EVM,
        amount: "1",
        currency: @usdc,
        recipient: recipient,
        method_config: %{
          "rpc_url" => rpc_url,
          "chain_id" => @default_chain_id,
          "private_key" => private_key
        }
      )

    conn =
      :get
      |> Plug.Test.conn("/api/data")
      |> MPP.Plug.call(config)

    assert conn.status == 402
    assert [challenge_header] = Plug.Conn.get_resp_header(conn, "www-authenticate")
    assert {:ok, challenge} = Headers.parse_challenge(challenge_header)
    assert {:ok, request_json} = Base.url_decode64(challenge.request, padding: false)
    assert {:ok, request_map} = Jason.decode(request_json)
    assert request_map["methodDetails"]["credentialTypes"] == ["authorization", "hash"]
    refute Map.has_key?(request_map["methodDetails"], "private_key")
  end

  defp authorization_charge(amount, recipient, rpc_url, private_key) do
    challenge_id = "evm3009-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    %Charge{
      amount: amount,
      currency: @usdc,
      recipient: recipient,
      method_details: %{
        "rpc_url" => rpc_url,
        "chain_id" => @default_chain_id,
        "private_key" => private_key,
        "challenge_id" => challenge_id,
        "realm" => @realm,
        "store" => false,
        "max_fee_per_gas" => 2_000_000_000,
        "max_priority_fee_per_gas" => 1_000_000_000
      }
    }
  end

  defp authorization_payload(charge, from, amount) do
    EVMAuthorization.payload(%{
      currency: @usdc,
      name: @usdc_name,
      version: @usdc_version,
      chain_id: @default_chain_id,
      from: from,
      recipient: charge.recipient,
      amount: amount,
      challenge_id: charge.method_details["challenge_id"],
      realm: @realm,
      private_key: charge.method_details["private_key"],
      value: String.to_integer(amount)
    })
  end
end
