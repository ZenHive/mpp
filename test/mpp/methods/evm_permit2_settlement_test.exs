defmodule MPP.Methods.EVMPermit2SettlementTest do
  use ExUnit.Case, async: true

  alias MPP.Credential
  alias MPP.Headers
  alias MPP.Intents.Charge
  alias MPP.Methods.EVM
  alias MPP.Methods.EVM.Permit2
  alias MPP.Test.EVMAuthorization

  @token "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"
  @recipient "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
  @split "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
  @secret "permit2-test-secret"
  @realm "permit2.integration"

  setup do
    owner = EVMAuthorization.signer_address()

    config = %{
      "permit2" => true,
      "private_key" => EVMAuthorization.private_key(),
      "chain_id" => 11_155_111,
      "rpc_url" => "http://unused",
      "challenge_id" => "permit2",
      "realm" => @realm,
      "req_options" => [plug: {Req.Test, __MODULE__}]
    }

    {:ok, config: config, owner: owner}
  end

  test "HTTP challenge, client signature, verifier dispatch, and MCP advertise configured Permit2", ctx do
    config =
      MPP.Plug.init(
        secret_key: @secret,
        realm: @realm,
        method: EVM,
        amount: "1",
        currency: @token,
        recipient: @recipient,
        method_config: ctx.config,
        store: false
      )

    conn = :get |> Plug.Test.conn("/resource") |> MPP.Plug.call(config)
    [header] = Plug.Conn.get_resp_header(conn, "www-authenticate")
    assert {:ok, challenge} = Headers.parse_challenge(header)
    [entry] = config.method_entries
    assert entry.charge.method_details["credentialTypes"] == ["permit2", "authorization", "hash"]

    assert get_in(MPP.Mcp.capabilities(config), ["experimental", "payment", "methods", "evm", "credentialTypes"]) ==
             ["permit2", "authorization", "hash"]

    charge = %{entry.charge | method_details: Map.put(ctx.config, "challenge_id", challenge.id)}
    {:ok, payload} = sign(charge, ctx.owner)
    credential = %Credential{challenge: challenge, payload: payload, source: "did:pkh:eip155:11155111:" <> ctx.owner}
    stub("single", ctx.owner)

    assert {:ok, receipt} =
             MPP.Verifier.verify(credential,
               secret_key: @secret,
               realm: @realm,
               method: EVM,
               charge: entry.charge,
               method_config: ctx.config
             )

    assert receipt.method == "evm"
    assert_receive {:rpc, "eth_sendRawTransaction", [_]}
  end

  test "recorded single and batch receipts exercise ordered log verification", ctx do
    for name <- ["single", "batch"] do
      {charge, payload} = payment(ctx, name)
      stub(name, ctx.owner)
      assert {:ok, receipt} = EVM.verify(payload, charge)
      assert receipt.reference == fixture(name)["receipt"]["transactionHash"]
      assert_receive {:rpc, "eth_estimateGas", [%{"data" => calldata, "from" => from}, "latest"]}
      assert String.starts_with?(calldata, if(name == "single", do: "0x137c29fe", else: "0xfe8ec1a7"))
      assert String.downcase(from) == String.downcase(ctx.owner)
    end
  end

  test "payer and gas sponsor can be different accounts", ctx do
    sponsor_key = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
    {:ok, sponsor} = Onchain.Signer.address_from_key(sponsor_key)
    {charge, _payload} = payment(ctx, "single")
    charge = %{charge | method_details: Map.put(charge.method_details, "private_key", sponsor_key)}
    assert {:ok, payload} = Permit2.sign(charge, EVMAuthorization.private_key(), sponsor, "123", "2000000000")
    assert {:ok, owner} = Permit2.verify(payload, charge)
    assert Onchain.Address.equal?(owner, ctx.owner)
    refute Onchain.Address.equal?(owner, sponsor)
    stub("single", ctx.owner)
    assert {:ok, _} = EVM.verify(payload, charge)
    assert_receive {:rpc, "eth_estimateGas", [%{"from" => from}, "latest"]}
    assert Onchain.Address.equal?(from, sponsor)
  end

  test "missing, reversed, wrong-amount, wrong-token and wrong-sender logs are rejected", ctx do
    {charge, payload} = payment(ctx, "batch")

    transforms = [
      fn receipt -> Map.put(receipt, "logs", []) end,
      fn receipt -> Map.update!(receipt, "logs", &Enum.reverse/1) end,
      fn receipt ->
        update_in(receipt["logs"], fn [first | rest] ->
          [Map.put(first, "data", "0x" <> String.duplicate("0", 64)) | rest]
        end)
      end,
      fn receipt -> update_in(receipt["logs"], &Enum.map(&1, fn log -> Map.put(log, "address", @split) end)) end,
      fn receipt ->
        update_in(
          receipt["logs"],
          &Enum.map(&1, fn log -> update_in(log["topics"], fn [sig, _from, to] -> [sig, to, to] end) end)
        )
      end
    ]

    for transform <- transforms do
      stub("batch", ctx.owner, %{}, transform)
      assert {:error, error} = EVM.verify(payload, charge)
      assert error.detail == "Permit2 receipt does not match ordered transfers"
    end
  end

  test "nonce bitmap collision and observed InvalidNonce RPC error both reject replay", ctx do
    {charge, payload} = payment(ctx, "single")
    bitmap = "0x" <> Base.encode16(<<Bitwise.bsl(1, 123)::256>>, case: :lower)
    stub("single", ctx.owner, %{"eth_call" => {"result", bitmap}})
    assert {:error, error} = EVM.verify(payload, charge)
    assert error.detail == "Permit2 nonce already used"
    refute_receive {:rpc, "eth_sendRawTransaction", _}

    stub("single", ctx.owner, %{
      "eth_estimateGas" => {"error", %{"code" => 3, "message" => "execution reverted", "data" => "0x756688fe"}}
    })

    assert {:error, error} = EVM.verify(payload, charge)
    assert error.detail == "Permit2 nonce already used"
    refute_receive {:rpc, "eth_sendRawTransaction", _}
  end

  test "RPC failures and a mismatched network never become successful payments", ctx do
    {charge, payload} = payment(ctx, "single")

    for method <- ["eth_call", "eth_estimateGas", "eth_sendRawTransaction", "eth_getTransactionReceipt"] do
      stub("single", ctx.owner, %{
        method =>
          {"error",
           %{"code" => 3, "message" => "execution reverted", "data" => "0xcd21db4f" <> String.duplicate("0", 64)}}
      })

      assert {:error, error} = EVM.verify(payload, charge)
      assert error.type =~ "settlement-failed"
    end

    stub("single", ctx.owner, %{"eth_chainId" => {"result", "0x1"}})
    assert {:error, error} = EVM.verify(payload, charge)
    assert error.detail == "Permit2 RPC chain does not match challenge"
  end

  test "receipt status must succeed and pending receipts are polled", ctx do
    {charge, payload} = payment(ctx, "single")
    stub("single", ctx.owner, %{}, &Map.put(&1, "status", "0x0"))
    assert {:error, _} = EVM.verify(payload, charge)
    Process.put(:permit2_pending_receipt, true)
    stub("single", ctx.owner)
    assert {:ok, _} = EVM.verify(payload, charge)
    assert_receive {:rpc, "eth_getTransactionReceipt", [_]}
    assert_receive {:rpc, "eth_getTransactionReceipt", [_]}
  end

  defp payment(ctx, name) do
    config =
      if name == "batch", do: Map.put(ctx.config, "splits", [%{"recipient" => @split, "amount" => "1"}]), else: ctx.config

    config = Map.put(config, "max_fee_per_gas", 2_000_000_000)

    charge = %Charge{
      amount: if(name == "batch", do: "3", else: "1"),
      currency: @token,
      recipient: @recipient,
      method_details: config
    }

    {:ok, payload} = sign(charge, ctx.owner)
    {charge, payload}
  end

  defp sign(charge, owner), do: Permit2.sign(charge, EVMAuthorization.private_key(), owner, "123", "2000000000")

  # Fixtures are successful Sepolia transactions, not an oracle for provider
  # semantics. Only the payer topic is substituted for the deterministic test key.
  defp fixture(name), do: "test/fixtures/evm_permit2/#{name}.json" |> File.read!() |> Jason.decode!()

  defp stub(name, owner, overrides \\ %{}, transform \\ &Function.identity/1) do
    observed = fixture(name)

    receipt =
      update_in(observed["receipt"]["logs"], fn logs ->
        Enum.map(logs, fn log ->
          update_in(log["topics"], fn [sig, _from, to] ->
            [sig, "0x" <> String.duplicate("0", 24) <> String.downcase(String.slice(owner, 2..-1//1)), to]
          end)
        end)
      end)["receipt"]

    receipt = transform.(receipt)
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      method = request["method"]
      send(test_pid, {:rpc, method, request["params"]})

      result =
        case method do
          "eth_call" ->
            "0x" <> String.duplicate("0", 64)

          "eth_chainId" ->
            observed["transaction"]["chainId"]

          "eth_estimateGas" ->
            observed["transaction"]["gas"]

          "eth_getTransactionCount" ->
            observed["transaction"]["nonce"]

          "eth_sendRawTransaction" ->
            receipt["transactionHash"]

          "eth_getTransactionReceipt" ->
            pending_or_receipt(receipt)
        end

      {key, value} = Map.get(overrides, method, {"result", result})
      Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => request["id"], key => value})
    end)
  end

  defp pending_or_receipt(receipt) do
    if Process.delete(:permit2_pending_receipt), do: nil, else: receipt
  end
end
