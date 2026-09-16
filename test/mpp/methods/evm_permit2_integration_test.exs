defmodule MPP.Methods.EVMPermit2IntegrationTest do
  @moduledoc """
  Live canonical Permit2 settlement on Sepolia. Requires a funded account with
  Sepolia ETH and at least 4 base units of Circle USDC (https://faucet.circle.com/).
  Run: mix test test/mpp/methods/evm_permit2_integration_test.exs --include integration
  """
  use ExUnit.Case, async: false

  alias MPP.Intents.Charge
  alias MPP.Methods.EVM
  alias MPP.Methods.EVM.Permit2
  alias MPP.Methods.EVM.Permit2.Settlement
  alias Onchain.Address
  alias Onchain.Contract
  alias Onchain.RPC
  alias Onchain.Signer

  @moduletag :integration
  @moduletag timeout: 180_000
  @token "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"
  @permit2 "0x000000000022D473030F116dDEE9F6B43aC78BA3"
  @recipient "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
  @split "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"

  setup_all do
    rpc = System.get_env("ETH_SEPOLIA_RPC_URL")
    key = System.get_env("ETH_SEPOLIA_PRIVATE_KEY")

    if is_nil(rpc) or is_nil(key) do
      flunk("""
      Missing Permit2 Sepolia credentials. Set:
        export ETH_SEPOLIA_RPC_URL="https://ethereum-sepolia-rpc.publicnode.com"
        export ETH_SEPOLIA_PRIVATE_KEY="0x<funded-sepolia-private-key>"
      Obtain Sepolia ETH at https://cloud.google.com/application/web3/faucet/ethereum/sepolia
      and USDC at https://faucet.circle.com/ for that account, then run:
        mix test test/mpp/methods/evm_permit2_integration_test.exs --include integration
      """)
    end

    assert {:ok, 11_155_111} = RPC.chain_id(rpc_url: rpc)
    {:ok, owner} = Signer.address_from_key(key)
    {:ok, owner_bin} = Address.validate(owner)
    {:ok, permit_bin} = Address.validate(@permit2)
    opts = [rpc_url: rpc]
    assert {:ok, [balance]} = Contract.call(@token, "balanceOf(address)", [owner_bin], "(uint256)", opts)
    assert balance >= 4, "Fund #{owner} with Sepolia USDC at https://faucet.circle.com/ (need 4 base units)"

    assert {:ok, [allowance]} =
             Contract.call(@token, "allowance(address,address)", [owner_bin, permit_bin], "(uint256)", opts)

    config = %{
      "rpc_url" => rpc,
      "chain_id" => 11_155_111,
      "private_key" => key,
      "permit2" => true,
      "realm" => "permit2.integration",
      "store" => false,
      "max_fee_per_gas" => 2_000_000_000,
      "max_priority_fee_per_gas" => 1_000_000_000
    }

    on_exit(fn ->
      {:ok, data} = Onchain.ABI.encode_call("approve(address,uint256)", [permit_bin, allowance])
      assert {:ok, _} = Settlement.submit(@token, data, config)
    end)

    {:ok, data} = Onchain.ABI.encode_call("approve(address,uint256)", [permit_bin, 4])
    assert {:ok, _} = Settlement.submit(@token, data, config)
    {:ok, config: config, key: key, owner: owner, opts: opts}
  end

  test "single and ordered atomic batch settle; witness, externalId, and nonce are bound", ctx do
    for splits <- [nil, [%{"recipient" => @split, "amount" => "1"}]] do
      charge = charge(ctx.config, splits)
      nonce = 32 |> :crypto.strong_rand_bytes() |> :binary.decode_unsigned() |> Integer.to_string()

      assert {:ok, payload} =
               Permit2.sign(charge, ctx.key, ctx.owner, nonce, Integer.to_string(System.system_time(:second) + 600))

      for changed <- [
            put_in(payload, ["witness", "externalId"], "another-order"),
            put_in(payload, ["witness", "challengeHash"], "0x" <> String.duplicate("00", 32))
          ] do
        assert {:error, error} = EVM.verify(changed, charge)
        assert error.type =~ "verification-failed"
      end

      if splits do
        assert {:error, error} = EVM.verify(Map.update!(payload, "transferDetails", &Enum.reverse/1), charge)
        assert error.type =~ "verification-failed"
      end

      assert {:ok, receipt} = EVM.verify(payload, charge)
      IO.puts("Permit2 settlement: #{receipt.reference}")
      assert receipt.external_id == charge.external_id
      assert {:ok, chain_receipt} = RPC.get_transaction_receipt(receipt.reference, ctx.opts)
      assert chain_receipt.status == 1
      assert {:ok, transfers} = Onchain.Transfer.parse_logs(chain_receipt.logs)

      assert Enum.map(transfers, &{String.downcase(&1.to), &1.amount}) ==
               if(splits,
                 do: [{String.downcase(@recipient), 2}, {String.downcase(@split), 1}],
                 else: [{String.downcase(@recipient), 1}]
               )

      assert Enum.all?(transfers, &Address.equal?(&1.from, ctx.owner))
      assert {:error, reused} = EVM.verify(payload, charge)
      assert reused.detail == "Permit2 nonce already used"
      assert {:ok, calldata} = Permit2.calldata(payload, ctx.owner)

      assert {:error, {:rpc_error, error}} =
               RPC.eth_estimate_gas(%{from: ctx.owner, to: @permit2, data: calldata}, ctx.opts)

      assert error.code == 3
      assert error.data == "0x756688fe"
    end
  end

  test "canonical contract rejects an expired permit with SignatureExpired(uint256)", ctx do
    charge = charge(ctx.config, nil)
    deadline = Integer.to_string(System.system_time(:second) - 60)
    assert {:ok, payload} = Permit2.sign(charge, ctx.key, ctx.owner, "123", deadline)
    assert {:ok, calldata} = Permit2.calldata(payload, ctx.owner)

    assert {:error, {:rpc_error, error}} =
             RPC.eth_estimate_gas(%{from: ctx.owner, to: @permit2, data: calldata}, ctx.opts)

    assert error.code == 3
    assert error.data == "0xcd21db4f" <> Base.encode16(<<String.to_integer(deadline)::256>>, case: :lower)
  end

  defp charge(config, splits) do
    config = Map.put(config, "challenge_id", Base.encode16(:crypto.strong_rand_bytes(16)))
    config = if splits, do: Map.put(config, "splits", splits), else: config

    %Charge{
      amount: if(splits, do: "3", else: "1"),
      currency: @token,
      recipient: @recipient,
      external_id: "permit2-order",
      method_details: config
    }
  end
end
