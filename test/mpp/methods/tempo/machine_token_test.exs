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
