defmodule MPP.X402.FacilitatorIntegrationTest do
  @moduledoc """
  Live x402 v2 facilitator contract probes, observed on 2026-09-18.

  Run with:
    mix test test/mpp/x402/facilitator_integration_test.exs --include integration

  Requires X402_PRIVATE_KEY (or ETH_SEPOLIA_PRIVATE_KEY) funded with Base Sepolia
  USDC, not Ethereum Sepolia USDC. See docs/x402-interoperability.md.
  """

  use ExUnit.Case, async: false

  alias MPP.Test.EVMAuthorization
  alias Onchain.Address
  alias Onchain.Contract
  alias Onchain.Signer

  @moduletag :integration
  @moduletag timeout: 120_000

  @asset "0x036CbD53842c5426634e7929541eC2318f3dCF7e"
  @network "eip155:84532"
  @recipient "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"

  setup_all do
    key = System.get_env("X402_PRIVATE_KEY") || System.get_env("ETH_SEPOLIA_PRIVATE_KEY")

    if is_nil(key) or key == "" do
      flunk("""
      Missing x402 testnet payer key. Set:
        export X402_PRIVATE_KEY="0x<your-testnet-private-key>"
        export X402_RPC_URL="https://sepolia.base.org"
        export X402_FACILITATOR_URL="https://www.x402.org/facilitator"

      Fund its address with USDC on Base Sepolia at https://faucet.circle.com/.
      Run mix test test/mpp/x402/facilitator_integration_test.exs --include integration
      """)
    end

    {:ok, payer} = Signer.address_from_key(key)

    {:ok,
     key: key,
     payer: payer,
     rpc: System.get_env("X402_RPC_URL") || "https://sepolia.base.org",
     facilitator: System.get_env("X402_FACILITATOR_URL") || "https://www.x402.org/facilitator"}
  end

  test "live facilitator rejects a signed amount above the payer balance", context do
    amount = balance(context) + 1
    body = payment(context, amount)

    assert {:ok, %{status: 200, body: verified}} = post(context, "verify", body)
    assert verified["isValid"] == false
    assert verified["invalidReason"] == "invalid_exact_evm_insufficient_balance"
    assert String.downcase(verified["payer"]) == String.downcase(context.payer)

    assert {:ok, %{status: 200, body: settled}} = post(context, "settle", body)
    assert settled["success"] == false
    assert settled["errorReason"] == "invalid_exact_evm_insufficient_balance"
    assert settled["transaction"] == ""
    assert settled["network"] == @network
    assert String.downcase(settled["payer"]) == String.downcase(context.payer)
  end

  test "payer is funded for the mandatory successful live settlement observation", context do
    assert balance(context) >= 1, """
    Missing Base Sepolia USDC for the required live x402 settlement observation.
    Payer: #{context.payer}
    Token: #{@asset} (chain 84532)

    Set:
      export X402_PRIVATE_KEY="0x<your-funded-testnet-private-key>"
      export X402_RPC_URL="https://sepolia.base.org"
      export X402_FACILITATOR_URL="https://www.x402.org/facilitator"

    Fund the payer on Base Sepolia at https://faucet.circle.com/.
    Run mix test test/mpp/x402/facilitator_integration_test.exs --include integration
    Funding alone does not prove settlement; the successful live observation is still required.
    """
  end

  defp balance(context) do
    {:ok, address} = Address.validate(context.payer)

    assert {:ok, [amount]} =
             Contract.call(@asset, "balanceOf(address)", [address], "(uint256)", rpc_url: context.rpc)

    amount
  end

  defp payment(context, amount) do
    now = System.system_time(:second)
    nonce = "0x" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

    requirements = %{
      "scheme" => "exact",
      "network" => @network,
      "amount" => Integer.to_string(amount),
      "asset" => @asset,
      "payTo" => @recipient,
      "maxTimeoutSeconds" => 300,
      "extra" => %{"name" => "USDC", "version" => "2"}
    }

    signature =
      EVMAuthorization.sign(%{
        private_key: context.key,
        currency: @asset,
        name: "USDC",
        version: "2",
        chain_id: 84_532,
        from: context.payer,
        to: @recipient,
        value: amount,
        valid_after: now - 600,
        valid_before: now + 300,
        nonce: nonce
      })

    %{
      "x402Version" => 2,
      "paymentRequirements" => requirements,
      "paymentPayload" => %{
        "x402Version" => 2,
        "accepted" => requirements,
        "resource" => %{"url" => "https://example.com/x402-probe"},
        "payload" => %{
          "signature" => signature,
          "authorization" => %{
            "from" => context.payer,
            "to" => @recipient,
            "value" => Integer.to_string(amount),
            "validAfter" => Integer.to_string(now - 600),
            "validBefore" => Integer.to_string(now + 300),
            "nonce" => nonce
          }
        }
      }
    }
  end

  defp post(context, action, body) do
    Req.post(String.trim_trailing(context.facilitator, "/") <> "/" <> action,
      json: body,
      retry: false,
      receive_timeout: 30_000
    )
  end
end
