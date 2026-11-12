defmodule MPP.Methods.Tempo.MachineTokenTest do
  use ExUnit.Case, async: true

  import MPP.Test.TempoTestHelpers

  alias MPP.Methods.Tempo.MachineToken
  alias Onchain.Tempo.TIP20

  @mainnet_chain_id 4217
  @moderato_chain_id 42_431
  @unsupported_chain_id 1

  # Cross-checked: refs/mpp-rs/src/protocol/methods/tempo/machine_token.rs:29-37
  # and refs/mppx/src/tempo/internal/defaults.ts:24-32.
  @token_mainnet "0x20C0000000000000000000003793c39601711f19"
  @swapper_mainnet "0xC6D32f013E0fA3e83B63Dc680E99826761595732"
  @token_moderato "0x20c000000000000000000000f85bbCa724044De0"
  @swapper_moderato "0x07f1FE0467Ae01DE340024aa4b7DD9729b1c169b"

  # Live Moderato push settlement 0x6b1cdd6740dfe19c4a3e5e92cf7001b609fe21e845474cf1133b86338e5cd2f0
  # `calls[0].input` — selector 0x34189fed, amount 10_000_000 pathUSD-equivalent.
  @live_swap_to_calldata Base.decode16!(
                           "34189fed" <>
                             "00000000000000000000000020c000000000000000000000f85bbca724044de0" <>
                             "0000000000000000000000000000000000000000000000000000000000989680" <>
                             "00000000000000000000000020c0000000000000000000000000000000000001" <>
                             "000000000000000000000000967fa869a1f124770f93d48cc900255936de641a" <>
                             "1b9389b6b5448148fbf008ef525dbb5107467f234586b4fad360b7aff3509dde",
                           case: :lower
                         )

  @live_amount 10_000_000
  @live_currency "0x20c0000000000000000000000000000000000001"
  @live_recipient "0x967fa869a1f124770f93d48cc900255936de641a"
  @live_memo "0x1b9389b6b5448148fbf008ef525dbb5107467f234586b4fad360b7aff3509dde"

  describe "supported?/1 and deployments" do
    test "recognizes Tempo mainnet and Moderato" do
      assert MachineToken.supported?(@mainnet_chain_id)
      assert MachineToken.supported?(@moderato_chain_id)
      refute MachineToken.supported?(@unsupported_chain_id)
    end

    test "returns canonical token and swapper addresses" do
      assert MachineToken.token(@mainnet_chain_id) == @token_mainnet
      assert MachineToken.settlement_sender(@mainnet_chain_id) == @swapper_mainnet
      assert MachineToken.token(@moderato_chain_id) == @token_moderato
      assert MachineToken.settlement_sender(@moderato_chain_id) == @swapper_moderato
      assert is_nil(MachineToken.token(@unsupported_chain_id))
      assert is_nil(MachineToken.settlement_sender(@unsupported_chain_id))
    end
  end

  test "both chains recognize MACH and machineUSD without mixing deployments" do
    for {chain_id, mach_swapper} <- [
          {4217, "0xF72E5107c32C655ffA7539a3C8e97B7C3cE16A3F"},
          {42_431, "0xd05f8EdFBB54Da0d765C9fE9b2B3f7d2E3a8C466"}
        ] do
      assert [mach, legacy] = MachineToken.deployments(chain_id)
      assert mach.token == "0x20c000000000000000000000f37de3740ADec032"
      assert mach.swapper == mach_swapper
      assert legacy.token == MachineToken.token(chain_id)
      assert legacy.swapper == MachineToken.settlement_sender(chain_id)

      for {name, deployment} <- [mach: mach, machine_usd: legacy] do
        assert MachineToken.machine_token?(chain_id, String.downcase(deployment.token))
        assert MachineToken.funding_token(chain_id, String.downcase(deployment.swapper)) == deployment.token

        assert {:ok, calls} =
                 MachineToken.settlement_calls(
                   chain_id,
                   @live_currency,
                   @live_amount,
                   @live_recipient,
                   decode_memo(@live_memo),
                   name
                 )

        assert {:ok, route} =
                 MachineToken.match_route(
                   calls,
                   chain_id,
                   @live_currency,
                   "#{@live_amount}",
                   @live_recipient,
                   @live_memo
                 )

        assert route.settlement_sender == deployment.swapper

        assert :error =
                 MachineToken.match_route(
                   calls,
                   chain_id,
                   @live_currency,
                   "#{@live_amount + 1}",
                   @live_recipient,
                   @live_memo
                 )

        assert :error =
                 MachineToken.match_route(
                   calls,
                   chain_id,
                   @live_currency,
                   "#{@live_amount}",
                   @live_recipient,
                   "0x" <> String.duplicate("ff", 32)
                 )

        [approve, swap] = calls

        assert :error =
                 MachineToken.match_route(
                   [approve, %{swap | value: 1}],
                   chain_id,
                   @live_currency,
                   "#{@live_amount}",
                   @live_recipient,
                   @live_memo
                 )
      end

      assert {:ok, [mach_approve, _]} =
               MachineToken.settlement_calls(
                 chain_id,
                 @live_currency,
                 @live_amount,
                 @live_recipient,
                 decode_memo(@live_memo),
                 :mach
               )

      assert {:ok, [_, legacy_swap]} =
               MachineToken.settlement_calls(
                 chain_id,
                 @live_currency,
                 @live_amount,
                 @live_recipient,
                 decode_memo(@live_memo),
                 :machine_usd
               )

      assert :error =
               MachineToken.match_route(
                 [mach_approve, legacy_swap],
                 chain_id,
                 @live_currency,
                 "#{@live_amount}",
                 @live_recipient,
                 @live_memo
               )
    end

    assert MachineToken.deployments(1) == []
    refute MachineToken.machine_token?(42_431, @live_currency)
    refute MachineToken.machine_token?(42_431, nil)
    assert MachineToken.funding_token(42_431, @live_recipient) == nil
  end

  describe "settlement_calls/5" do
    test "builds the canonical [approve, swapTo] route that match_route accepts" do
      assert {:ok, calls} =
               MachineToken.settlement_calls(
                 @moderato_chain_id,
                 @live_currency,
                 @live_amount,
                 @live_recipient,
                 decode_memo(@live_memo)
               )

      assert {:ok, route} =
               MachineToken.match_route(
                 calls,
                 @moderato_chain_id,
                 @live_currency,
                 "#{@live_amount}",
                 @live_recipient,
                 @live_memo
               )

      assert route.settlement_sender == @swapper_moderato
      assert route.memo == @live_memo
    end

    test "rejects unsupported chains, bad addresses, and a non-32-byte memo" do
      memo = decode_memo(@live_memo)

      assert :error =
               MachineToken.settlement_calls(
                 @unsupported_chain_id,
                 @live_currency,
                 @live_amount,
                 @live_recipient,
                 memo
               )

      assert :error =
               MachineToken.settlement_calls(
                 @moderato_chain_id,
                 "not-an-address",
                 @live_amount,
                 @live_recipient,
                 memo
               )

      assert :error =
               MachineToken.settlement_calls(
                 @moderato_chain_id,
                 @live_currency,
                 @live_amount,
                 @live_recipient,
                 <<0, 1, 2>>
               )
    end
  end

  describe "swap_to_calldata/5" do
    test "matches live Moderato swapTo calldata (tx 0x6b1cdd67…c2f0)" do
      encoded =
        MachineToken.swap_to_calldata(
          decode_address(@token_moderato),
          @live_amount,
          decode_address(@live_currency),
          decode_address(@live_recipient),
          decode_memo(@live_memo)
        )

      assert encoded == @live_swap_to_calldata
      assert binary_part(encoded, 0, 4) == <<0x34, 0x18, 0x9F, 0xED>>
    end
  end

  describe "match_route/6" do
    test "matches the exact [approve, swapTo] route including a challenge memo" do
      assert {:ok, route} =
               MachineToken.match_route(
                 canonical_calls(@live_memo),
                 @moderato_chain_id,
                 @live_currency,
                 "#{@live_amount}",
                 @live_recipient,
                 @live_memo
               )

      assert route.settlement_sender == @swapper_moderato
      assert String.downcase(route.memo) == @live_memo
    end

    test "takes the memo from swapTo calldata when the challenge has none" do
      assert {:ok, route} =
               MachineToken.match_route(
                 canonical_calls(@live_memo),
                 @moderato_chain_id,
                 @live_currency,
                 @live_amount,
                 @live_recipient,
                 nil
               )

      assert String.downcase(route.memo) == @live_memo
    end

    test "rejects an unsupported chain" do
      assert :error =
               MachineToken.match_route(
                 canonical_calls(@live_memo),
                 @unsupported_chain_id,
                 @live_currency,
                 "#{@live_amount}",
                 @live_recipient,
                 @live_memo
               )
    end

    test "rejects a mutated swapTo amount" do
      [approve, swap] = canonical_calls(@live_memo)
      mutated = %{swap | input: binary_part(swap.input, 0, 4) <> :binary.copy(<<0>>, 160)}

      assert :error =
               MachineToken.match_route(
                 [approve, mutated],
                 @moderato_chain_id,
                 @live_currency,
                 "#{@live_amount}",
                 @live_recipient,
                 @live_memo
               )
    end

    test "rejects a non-zero call value" do
      [approve, swap] = canonical_calls(@live_memo)

      assert :error =
               MachineToken.match_route(
                 [approve, %{swap | value: 1}],
                 @moderato_chain_id,
                 @live_currency,
                 "#{@live_amount}",
                 @live_recipient,
                 @live_memo
               )
    end

    test "rejects a one-call or three-call batch" do
      [approve, swap] = canonical_calls(@live_memo)

      assert :error =
               MachineToken.match_route(
                 [swap],
                 @moderato_chain_id,
                 @live_currency,
                 "#{@live_amount}",
                 @live_recipient,
                 @live_memo
               )

      assert :error =
               MachineToken.match_route(
                 [approve, swap, swap],
                 @moderato_chain_id,
                 @live_currency,
                 "#{@live_amount}",
                 @live_recipient,
                 @live_memo
               )
    end

    test "rejects a malformed challenge memo" do
      assert :error =
               MachineToken.match_route(
                 canonical_calls(@live_memo),
                 @moderato_chain_id,
                 @live_currency,
                 "#{@live_amount}",
                 @live_recipient,
                 "0xdead"
               )
    end

    test "rejects a non-map call" do
      [_approve, swap] = canonical_calls(@live_memo)

      assert :error =
               MachineToken.match_route(
                 [%{not: :a_call}, swap],
                 @moderato_chain_id,
                 @live_currency,
                 "#{@live_amount}",
                 @live_recipient,
                 @live_memo
               )
    end

    test "rejects a non-numeric amount" do
      assert :error =
               MachineToken.match_route(
                 canonical_calls(@live_memo),
                 @moderato_chain_id,
                 @live_currency,
                 "not-an-amount",
                 @live_recipient,
                 @live_memo
               )
    end

    test "rejects a negative amount" do
      assert :error =
               MachineToken.match_route(
                 canonical_calls(@live_memo),
                 @moderato_chain_id,
                 @live_currency,
                 -1,
                 @live_recipient,
                 @live_memo
               )
    end

    test "rejects an invalid currency address" do
      assert :error =
               MachineToken.match_route(
                 canonical_calls(@live_memo),
                 @moderato_chain_id,
                 "not-an-address",
                 @live_amount,
                 @live_recipient,
                 @live_memo
               )
    end

    test "rejects malformed swapTo calldata" do
      [approve, swap] = canonical_calls(@live_memo)

      assert :error =
               MachineToken.match_route(
                 [approve, %{swap | input: <<0x34, 0x18, 0x9F, 0xED>>}],
                 @moderato_chain_id,
                 @live_currency,
                 @live_amount,
                 @live_recipient,
                 @live_memo
               )
    end

    test "rejects a challenge memo that is not a string" do
      assert :error =
               MachineToken.match_route(
                 canonical_calls(@live_memo),
                 @moderato_chain_id,
                 @live_currency,
                 @live_amount,
                 @live_recipient,
                 123
               )
    end
  end

  describe "funding_url/3" do
    @funding_base "https://wallet.tempo.xyz/agent?action=fund&intent=mach&chainId=4217"
    @funding_payer "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"

    # refs/mpp-rs/src/protocol/methods/tempo/machine_token.rs:161,418-426.
    test "matches the mpp-rs vectors" do
      assert MachineToken.funding_url(4217, @funding_payer, 750_000) ==
               "#{@funding_base}&address=#{@funding_payer}&amount=0.75"

      assert MachineToken.funding_url(4217, nil, 1) == "#{@funding_base}&amount=0.01"
      assert MachineToken.funding_url(4217, nil, 12_000_000) == "#{@funding_base}&amount=12.00"
      assert MachineToken.funding_url(4217, nil, 1_250_001) == "#{@funding_base}&amount=1.26"
    end

    # refs/mppx/src/tempo/internal/machine-token-charge.test.ts:190,236 — same
    # base URL, parameter order and value; mppx drops trailing zeros, so only
    # amounts with two significant decimals render identically.
    test "matches the mppx vector for an amount with two decimals" do
      assert MachineToken.funding_url(4217, @funding_payer, 1_250_000) ==
               "#{@funding_base}&address=#{@funding_payer}&amount=1.25"
    end

    test "rounds a fraction of a cent up" do
      assert MachineToken.funding_url(4217, nil, 10_000) == "#{@funding_base}&amount=0.01"
      assert MachineToken.funding_url(4217, nil, 10_001) == "#{@funding_base}&amount=0.02"
      assert MachineToken.funding_url(4217, nil, 999_999) == "#{@funding_base}&amount=1.00"
    end

    test "checksums the address and drops an invalid one" do
      assert MachineToken.funding_url(4217, String.downcase(@funding_payer)) ==
               "#{@funding_base}&address=#{@funding_payer}"

      assert MachineToken.funding_url(4217, "evil&amount=9.99") == @funding_base
      assert MachineToken.funding_url(4217, "0x1234") == @funding_base
    end

    test "leaves out a zero, negative or non-integer amount" do
      for amount <- [0, -1, nil, "100", 1.5] do
        assert MachineToken.funding_url(4217, nil, amount) == @funding_base
      end
    end

    test "returns nil off Tempo mainnet" do
      for chain_id <- [42_431, 1, nil, "4217"] do
        assert MachineToken.funding_url(chain_id, @funding_payer, 1_000_000) == nil
      end
    end
  end

  describe "funding_url?/1" do
    test "accepts every link funding_url/3 writes" do
      for address <- [nil, @funding_payer], amount <- [nil, 1, 750_000, 12_000_000] do
        assert MachineToken.funding_url?(MachineToken.funding_url(4217, address, amount))
      end
    end

    test "rejects anything else" do
      # The last three are the mpp-rs `funding_url_in` rejections
      # (refs/mpp-rs/src/protocol/methods/tempo/machine_token.rs:454).
      for url <- [
            nil,
            "",
            "https://wallet.tempo.xyz/",
            "https://evil.example/agent?action=fund&intent=mach&chainId=4217",
            @funding_base <> "&redirect=https://evil.example",
            @funding_base <> "&address=evil&amount=1.00",
            @funding_base <> "&amount=1.5",
            @funding_base <> "&amount=1.00&address=#{@funding_payer}",
            @funding_base <> "&amount=1.00\n"
          ] do
        refute MachineToken.funding_url?(url)
      end
    end
  end

  describe "format_amount/1" do
    # refs/mpp-rs/src/protocol/methods/tempo/machine_token.rs:187-192.
    test "writes at least two decimals and drops other trailing zeros" do
      assert MachineToken.format_amount(0) == "0.00"
      assert MachineToken.format_amount(250_000) == "0.25"
      assert MachineToken.format_amount(1_000_000) == "1.00"
      assert MachineToken.format_amount(1_000_001) == "1.000001"
      assert MachineToken.format_amount(12_500_000) == "12.50"
    end
  end

  describe "mach?/2" do
    test "is MACH on the chains with a MACH deployment" do
      mach = "0x20c000000000000000000000f37de3740ADec032"

      assert MachineToken.mach?(4217, mach)
      assert MachineToken.mach?(42_431, String.downcase(mach))
      refute MachineToken.mach?(1, mach)
      refute MachineToken.mach?(4217, @token_mainnet)
      refute MachineToken.mach?(4217, nil)
    end
  end

  describe "shortfall/4" do
    @rpc_opts [rpc_url: "https://rpc.invalid", req_options: [plug: {Req.Test, __MODULE__}]]

    defp stub_balance(balance) do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)
        assert request["method"] == "eth_call"
        assert [%{"to" => to, "data" => "0x70a08231" <> _owner}, _block] = request["params"]
        assert String.downcase(to) == "0x20c000000000000000000000f37de3740adec032"

        result = "0x" <> (balance |> Integer.to_string(16) |> String.pad_leading(64, "0"))
        Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
      end)
    end

    test "reports the missing MACH and links the onramp for it" do
      stub_balance(250_000)

      assert {:ok, shortfall} = MachineToken.shortfall(4217, @funding_payer, 1_000_000, @rpc_opts)
      assert shortfall.reason == "requested 1.00 MACH, available 0.25 MACH"
      assert shortfall.shortfall == 750_000
      assert shortfall.funding_url == "#{@funding_base}&address=#{@funding_payer}&amount=0.75"
    end

    test "is :none when the balance covers the amount" do
      stub_balance(1_000_000)
      assert MachineToken.shortfall(4217, @funding_payer, 1_000_000, @rpc_opts) == :none
    end

    test "is :none when the balance cannot be read" do
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
      assert MachineToken.shortfall(4217, @funding_payer, 1_000_000, @rpc_opts) == :none
    end

    test "does not read the balance off Tempo mainnet" do
      Req.Test.stub(__MODULE__, fn _conn -> flunk("no RPC call expected") end)
      assert MachineToken.shortfall(42_431, @funding_payer, 1_000_000, @rpc_opts) == :none
    end
  end

  defp canonical_calls(memo_hex) do
    token = decode_address(@token_moderato)
    swapper = decode_address(@swapper_moderato)

    [
      %{to: token, value: 0, input: TIP20.approve_calldata(swapper, @live_amount)},
      %{
        to: swapper,
        value: 0,
        input:
          MachineToken.swap_to_calldata(
            token,
            @live_amount,
            decode_address(@live_currency),
            decode_address(@live_recipient),
            decode_memo(memo_hex)
          )
      }
    ]
  end

  defp decode_memo(hex), do: Base.decode16!(strip_0x(hex), case: :mixed)
end
