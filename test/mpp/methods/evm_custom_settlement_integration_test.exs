Code.require_file("../../../examples/eip3009_push_split.exs", __DIR__)

defmodule MPP.Methods.EVMCustomSettlementIntegrationTest do
  use ExUnit.Case, async: false

  alias MPP.Examples.EIP3009PushSplit, as: PushSplit
  alias MPP.Intents.Charge
  alias MPP.Methods.EVM
  alias MPP.Methods.EVM.Authorization
  alias Onchain.ABI
  alias Onchain.Address
  alias Onchain.Contract
  alias Onchain.Hash
  alias Onchain.Hex
  alias Onchain.RPC
  alias Onchain.Signer

  @moduletag :integration
  @moduletag timeout: 180_000
  @token "0x1c7d4b196cb0c7b01d743fbc6116a902379c7238"
  @split "0x8889c332727d5f3865526391bfb124cfab74c05f"
  @executor "0xca11bde05977b3631167028862be2a173976ca11"
  @factory "0x8e8eb0cc6ae34a38b67d5cf91aca38f60bc3ecf4"
  @warehouse "0x8fb66f38cf86a3d5e8768f8f1754a24a6c661fb8"
  @recipients ["0x898018e18e1aa5819282ec4d9b784e1ae7eecac4", "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"]

  setup_all do
    rpc_url = System.get_env("ETH_SEPOLIA_RPC_URL")
    key = System.get_env("ETH_SEPOLIA_PRIVATE_KEY")

    if !(rpc_url && key) do
      flunk("""
      Missing live Sepolia credentials. Set:
        export ETH_SEPOLIA_RPC_URL="https://ethereum-sepolia-rpc.publicnode.com"
        export ETH_SEPOLIA_PRIVATE_KEY="0x<funded-testnet-key>"
      Fund gas with Sepolia ETH (https://www.alchemy.com/faucets/ethereum-sepolia)
      and testnet USDC (https://faucet.circle.com/).
      Run: mix test test/mpp/methods/evm_custom_settlement_integration_test.exs --include integration
      """)
    end

    opts = [rpc_url: rpc_url]
    assert {:ok, 11_155_111} = RPC.eth_chain_id(opts)
    {:ok, payer} = Signer.address_from_key(key)
    assert balance(payer, opts) >= 4, "Fund #{payer} with Sepolia USDC at https://faucet.circle.com/"
    config = %{rpc_url: rpc_url, split: @split, params: {Enum.map(@recipients, &address/1), [1, 1], 2, 0}}
    assert :ok = PushSplit.validate_split(config)
    record_identity(opts, config)
    {:ok, opts: opts, key: key, payer: payer, config: config}
  end

  test "AUTH-CUSTOM-OPTIONAL-DISTRIBUTION: payment, failed distribution and independent retry", ctx do
    # The known recipient may also be the payer. Compare its net delta accordingly.
    before = balances(ctx.opts)
    config = Map.put(ctx.config, :relay, &relay(&1, &2, ctx, "payment-and-distribution"))
    {payload, charge} = credential(ctx, "2", {&PushSplit.settle/2, config})
    refute Map.has_key?(charge.method_details, "private_key")
    assert {:ok, receipt} = EVM.verify(payload, charge)
    assert receipt.method == "evm"
    assert_distribution_delta(before, balances(ctx.opts), ctx.payer, 2)
    assert {:error, %{detail: "Authorization already used"}} = EVM.verify(payload, charge)

    before = balances(ctx.opts)
    split_before = balance(@split, ctx.opts)

    failing_distribution = fn input, config ->
      with {:ok, data} <- PushSplit.batch(input, config) do
        # Change the incentive in distribution calldata only. The payment stays mandatory.
        # This exercises InvalidSplit(), not Circle blocklisting.
        {:ok, [calls]} = ABI.decode_call("aggregate3((address,bool,bytes)[])", data)
        [payment, {target, true, _distribution}] = calls
        invalid = %{config | params: put_elem(config.params, 3, 1)}

        data =
          ABI.encode_call("aggregate3((address,bool,bytes)[])", [
            [payment, {target, true, PushSplit.distribution(invalid, 2)}]
          ])

        relay(@executor, data, ctx, "payment-distribution-reverted")
      end
    end

    {payload, charge} = credential(ctx, "2", {failing_distribution, ctx.config})
    assert {:ok, _receipt} = EVM.verify(payload, charge)
    assert balance(@split, ctx.opts) == split_before + 2
    assert_payment_only_delta(before, balances(ctx.opts), ctx.payer, 2)

    assert {:ok, _hash} = relay(@split, PushSplit.distribution(ctx.config, 2), ctx, "distribution-retry")
    assert balance(@split, ctx.opts) == split_before
    assert_distribution_delta(before, balances(ctx.opts), ctx.payer, 2)

    # Force a real reverted batch, including no-op optional distribution, through MPP.
    amount = Integer.to_string(balance(ctx.payer, ctx.opts) + 1)

    failed_config =
      Map.put(ctx.config, :relay, fn target, data ->
        relay(target, data, ctx, "payment-reverted", 200_000)
      end)

    {payload, charge} = credential(ctx, amount, {&PushSplit.settle/2, failed_config})
    before = balances(ctx.opts)
    assert {:error, %{detail: detail}} = EVM.verify(payload, charge)
    assert detail =~ "reverted"
    assert balances(ctx.opts) == before
    {:ok, nonce} = Hex.decode(payload["nonce"])

    assert {:ok, [false]} =
             Contract.call(@token, "authorizationState(address,bytes32)", [address(ctx.payer), nonce], "(bool)", ctx.opts)
  end

  defp credential(ctx, amount, callback) do
    id = "custom-" <> Base.encode16(:crypto.strong_rand_bytes(16))
    nonce = Authorization.challenge_hash(id, "pushsplit.example")
    expiry = System.system_time(:second) + 300

    {:ok, signature} =
      Authorization.sign_transfer(
        %{
          from: ctx.payer,
          to: @split,
          value: amount,
          valid_after: 0,
          valid_before: expiry,
          nonce: nonce,
          currency: @token,
          name: "USDC",
          version: "2",
          chain_id: 11_155_111
        },
        ctx.key
      )

    payload = %{
      "type" => "authorization",
      "from" => ctx.payer,
      "to" => @split,
      "value" => amount,
      "validAfter" => 0,
      "validBefore" => expiry,
      "nonce" => nonce,
      "signature" => signature
    }

    charge = %Charge{
      amount: amount,
      currency: @token,
      recipient: @split,
      method_details: %{
        "rpc_url" => ctx.config.rpc_url,
        "chain_id" => 11_155_111,
        "challenge_id" => id,
        "realm" => "pushsplit.example",
        "settle_authorization" => callback
      }
    }

    {payload, charge}
  end

  defp relay(to, data, ctx, label, gas_override \\ nil) do
    {:ok, nonce} = RPC.get_transaction_count(ctx.payer, Keyword.put(ctx.opts, :block, "pending"))
    gas = gas_override || estimate(to, data, ctx)

    {:ok, tx} =
      Signer.build_transaction(to, data,
        nonce: nonce,
        chain_id: 11_155_111,
        gas_limit: gas,
        max_fee_per_gas: 2_000_000_000,
        max_priority_fee_per_gas: 1_000_000_000
      )

    {:ok, signed} = Signer.sign_transaction(tx, ctx.key, 11_155_111)
    {:ok, raw} = Signer.encode_transaction(signed)
    {:ok, hash} = RPC.eth_send_raw_transaction(raw, ctx.opts)
    receipt = await_receipt(hash, ctx.opts, 60)
    record(label, %{transaction: hash, receipt: receipt})
    {:ok, hash}
  end

  defp estimate(to, data, ctx) do
    assert {:ok, gas} =
             RPC.call("eth_estimateGas", [%{"from" => ctx.payer, "to" => to, "data" => Hex.encode(data)}], ctx.opts)

    div(String.to_integer(String.trim_leading(gas, "0x"), 16) * 5, 4)
  end

  defp await_receipt(_hash, _opts, 0), do: flunk("Sepolia receipt not confirmed within 120 seconds")

  defp await_receipt(hash, opts, remaining) do
    assert {:ok, receipt} = RPC.call("eth_getTransactionReceipt", [hash], opts)

    if receipt do
      receipt
    else
      receive do
      after
        2000 -> await_receipt(hash, opts, remaining - 1)
      end
    end
  end

  defp balances(opts), do: Map.new(@recipients, &{&1, balance(&1, opts)})

  defp balance(account, opts) do
    assert {:ok, [balance]} = Contract.call(@token, "balanceOf(address)", [address(account)], "(uint256)", opts)
    balance
  end

  defp assert_distribution_delta(before, after_balances, payer, amount) do
    for recipient <- @recipients do
      debit = if Address.equal?(recipient, payer), do: amount, else: 0
      assert after_balances[recipient] == before[recipient] + div(amount, 2) - debit
    end

    record("distributed-balances", %{before: before, after: after_balances})
  end

  defp assert_payment_only_delta(before, after_balances, payer, amount) do
    for recipient <- @recipients do
      debit = if Address.equal?(recipient, payer), do: amount, else: 0
      assert after_balances[recipient] == before[recipient] - debit
    end

    record("undistributed-balances", %{before: before, after: after_balances})
  end

  defp record_identity(opts, config) do
    assert {:ok, [implementation]} = Contract.call(@factory, "SPLIT_WALLET_IMPLEMENTATION()", [], "(address)", opts)
    assert {:ok, [token_implementation]} = Contract.call(@token, "implementation()", [], "(address)", opts)
    assert {:ok, [admin]} = Contract.call(@token, "admin()", [], "(address)", opts)
    assert {:ok, block} = RPC.call("eth_blockNumber", [], opts)

    addresses = [
      @token,
      @split,
      @executor,
      @factory,
      @warehouse,
      Hex.encode(implementation),
      Hex.encode(token_implementation)
    ]

    codes =
      Map.new(addresses, fn addr ->
        assert {:ok, code} = RPC.call("eth_getCode", [addr, block], opts)
        {:ok, bytes} = Hex.decode(code)
        assert byte_size(bytes) > 0
        {addr, Hex.encode(Hash.keccak(bytes))}
      end)

    {revision, 0} = System.cmd("git", ["rev-parse", "HEAD"])

    sources =
      Map.new(
        [
          "lib/mpp/methods/evm.ex",
          "lib/mpp/methods/evm/authorization.ex",
          "examples/eip3009_push_split.exs",
          __ENV__.file
        ],
        fn path ->
          {Path.relative_to_cwd(path), Base.encode16(:crypto.hash(:sha256, File.read!(path)), case: :lower)}
        end
      )

    record("identity", %{
      chain: 11_155_111,
      block: block,
      code_hashes: codes,
      token_implementation: Hex.encode(token_implementation),
      token_admin: Hex.encode(admin),
      split_implementation: Hex.encode(implementation),
      owner: "0x" <> String.duplicate("00", 20),
      recipients: @recipients,
      allocations: [1, 1],
      total_allocation: 2,
      distributor_incentive: 0,
      split: config.split,
      base_revision: String.trim(revision),
      source_sha256: sources,
      sdk_revision: "c0ce0fecccf29f0dab8457c4356c0a3838af3390"
    })
  end

  defp record(label, data) do
    dir = System.get_env("EVM_SETTLEMENT_EVIDENCE_DIR") || ".harness/evidence/custom-settlement"
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, label <> ".json"), Jason.encode!(data, pretty: true))
  end

  defp address(value), do: value |> Address.validate() |> elem(1)
end
