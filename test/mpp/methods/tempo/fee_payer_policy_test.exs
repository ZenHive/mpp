defmodule MPP.Methods.Tempo.FeePayerPolicyTest do
  use ExUnit.Case, async: true

  import MPP.Test.TempoTestHelpers

  alias MPP.Methods.Tempo.FeePayerPolicy
  alias Onchain.Tempo.Transaction

  doctest FeePayerPolicy

  @moderato_chain_id 42_431
  @mainnet_chain_id 4217
  @token "0x20c0000000000000000000000000000000000000"
  @recipient "0x1111111111111111111111111111111111111111"
  # Fixed reference time so validity-window comparisons are deterministic.
  @now 1_700_000_000

  # A fee-payer tx that satisfies the default policy: gas 51_299, max_fee 1 Gwei.
  defp valid_tx(opts \\ []) do
    call = build_call(@token, transfer_calldata(@recipient, 1_000_000))

    {:ok, tx} =
      [fee_payer: true, calls: [call]]
      |> Keyword.merge(opts)
      |> build_tempo_tx()
      |> Transaction.deserialize()

    tx
  end

  describe "resolve/2" do
    test "returns the documented defaults for an unknown chain" do
      p = FeePayerPolicy.resolve(@mainnet_chain_id, nil)

      assert p.max_gas == 2_000_000
      assert p.max_fee_per_gas == 100_000_000_000
      assert p.max_priority_fee_per_gas == 10_000_000_000
      assert p.max_total_fee == 50_000_000_000_000_000
      assert p.max_validity_window_seconds == 900
    end

    test "raises the priority-fee ceiling on Moderato testnet" do
      assert FeePayerPolicy.resolve(@moderato_chain_id, nil).max_priority_fee_per_gas ==
               50_000_000_000
    end

    test "applies integer overrides, ignoring the rest" do
      p =
        FeePayerPolicy.resolve(@mainnet_chain_id, %{
          "max_gas" => 500_000,
          "max_total_fee" => 1_000
        })

      assert p.max_gas == 500_000
      assert p.max_total_fee == 1_000
      # untouched keys keep chain defaults
      assert p.max_fee_per_gas == 100_000_000_000
    end

    test "ignores non-integer and negative overrides" do
      p =
        FeePayerPolicy.resolve(@mainnet_chain_id, %{
          "max_gas" => "lots",
          "max_fee_per_gas" => -1
        })

      assert p.max_gas == 2_000_000
      assert p.max_fee_per_gas == 100_000_000_000
    end

    test "treats nil overrides as no overrides" do
      assert FeePayerPolicy.resolve(@mainnet_chain_id, nil) ==
               FeePayerPolicy.resolve(@mainnet_chain_id, %{})
    end
  end

  describe "default_allowed_fee_tokens/1 and fee_token_allowed?/3" do
    test "includes pathUSD and chain default on Moderato" do
      tokens = FeePayerPolicy.default_allowed_fee_tokens(@moderato_chain_id)
      assert "0x20c0000000000000000000000000000000000000" in Enum.map(tokens, &String.downcase/1)
    end

    test "includes USDC on mainnet" do
      tokens = FeePayerPolicy.default_allowed_fee_tokens(@mainnet_chain_id)
      assert Enum.any?(tokens, &String.contains?(String.downcase(&1), "b9537d"))
    end

    test "rejects token outside default allowlist" do
      refute FeePayerPolicy.fee_token_allowed?(
               @moderato_chain_id,
               "0x1111111111111111111111111111111111111111"
             )
    end

    test "honors custom override list" do
      custom = ["0x1111111111111111111111111111111111111111"]

      assert FeePayerPolicy.fee_token_allowed?(
               @moderato_chain_id,
               "0x1111111111111111111111111111111111111111",
               custom
             )
    end
  end

  describe "validate/2 — accepts well-formed sponsored transactions" do
    test "passes a default-valid fee-payer tx" do
      policy = FeePayerPolicy.resolve(@moderato_chain_id, nil)
      assert FeePayerPolicy.validate(valid_tx(), policy) == :ok
    end

    test "passes at the exact ceilings" do
      policy = FeePayerPolicy.resolve(@mainnet_chain_id, nil)
      # gas * max_fee = 500_000 * 100_000_000_000 = 5e16 == max_total_fee
      tx = valid_tx(gas_limit: 500_000, max_fee_per_gas: 100_000_000_000, max_priority_fee_per_gas: 10_000_000_000)
      assert FeePayerPolicy.validate(tx, policy) == :ok
    end

    test "passes at the exact gas-limit ceiling" do
      policy = FeePayerPolicy.resolve(@moderato_chain_id, nil)
      # gas_limit == max_gas (2_000_000); 1 Gwei keeps the total-fee budget well under cap.
      tx = valid_tx(gas_limit: 2_000_000, max_fee_per_gas: 1_000_000_000, max_priority_fee_per_gas: 1_000_000_000)
      assert FeePayerPolicy.validate(tx, policy) == :ok
    end
  end

  describe "validate/2 — malformed input fails closed" do
    test "rejects a non-binary (malformed RLP scalar) gas field" do
      policy = FeePayerPolicy.resolve(@moderato_chain_id, nil)
      tx = valid_tx()
      # Corrupt max_fee_per_gas (field index 2) into a list — not a valid RLP scalar.
      corrupted = %{tx | fields: List.replace_at(tx.fields, 2, [<<1>>])}

      assert {:error, reason} = FeePayerPolicy.validate(corrupted, policy)
      assert reason =~ "malformed"
    end
  end

  describe "validate/2 — gas price draining (GHSA-vv77-66rf-pm86)" do
    test "rejects max_fee_per_gas above the ceiling" do
      policy = FeePayerPolicy.resolve(@moderato_chain_id, nil)
      tx = valid_tx(max_fee_per_gas: 100_000_000_001, gas_limit: 21_000)

      assert {:error, reason} = FeePayerPolicy.validate(tx, policy)
      assert reason =~ "max_fee_per_gas"
    end

    test "rejects zero max_fee_per_gas" do
      policy = FeePayerPolicy.resolve(@moderato_chain_id, nil)
      tx = valid_tx(max_fee_per_gas: 0, max_priority_fee_per_gas: 0)

      assert {:error, reason} = FeePayerPolicy.validate(tx, policy)
      assert reason =~ "max_fee_per_gas"
    end

    test "rejects a total fee budget over the cap even when each field is in range" do
      # max_fee 100 Gwei (== ceiling) * gas 2_000_000 (== ceiling) = 2e17 > 5e16 cap
      policy = FeePayerPolicy.resolve(@mainnet_chain_id, nil)
      tx = valid_tx(gas_limit: 2_000_000, max_fee_per_gas: 100_000_000_000, max_priority_fee_per_gas: 10_000_000_000)

      assert {:error, reason} = FeePayerPolicy.validate(tx, policy)
      assert reason =~ "total fee budget"
    end

    test "rejects max_priority_fee_per_gas above max_fee_per_gas" do
      policy = FeePayerPolicy.resolve(@moderato_chain_id, nil)
      tx = valid_tx(max_fee_per_gas: 1_000_000_000, max_priority_fee_per_gas: 2_000_000_000)

      assert {:error, reason} = FeePayerPolicy.validate(tx, policy)
      assert reason =~ "exceeds max_fee_per_gas"
    end

    test "rejects max_priority_fee_per_gas above the policy ceiling" do
      # On mainnet the priority ceiling is 10 Gwei; set max_fee high so the
      # ordering check passes and the ceiling check is what fires.
      policy = FeePayerPolicy.resolve(@mainnet_chain_id, nil)
      tx = valid_tx(max_fee_per_gas: 90_000_000_000, max_priority_fee_per_gas: 11_000_000_000, gas_limit: 21_000)

      assert {:error, reason} = FeePayerPolicy.validate(tx, policy)
      assert reason =~ "exceeds maximum"
    end
  end

  describe "validate/2 — gas limit ceiling" do
    test "rejects gas_limit above the ceiling" do
      policy = FeePayerPolicy.resolve(@moderato_chain_id, nil)
      tx = valid_tx(gas_limit: 2_000_001)

      assert {:error, reason} = FeePayerPolicy.validate(tx, policy)
      assert reason =~ "gas_limit"
    end

    test "rejects zero gas_limit" do
      policy = FeePayerPolicy.resolve(@moderato_chain_id, nil)
      tx = valid_tx(gas_limit: 0)

      assert {:error, reason} = FeePayerPolicy.validate(tx, policy)
      assert reason =~ "gas_limit"
    end
  end

  describe "validate/2 — access-list padding (GHSA-qpxh-ff8m-c62v)" do
    test "rejects a non-empty access list" do
      policy = FeePayerPolicy.resolve(@moderato_chain_id, nil)
      # One EIP-2930 entry: [address, [storage_keys]].
      entry = [<<0::160>>, []]
      tx = valid_tx(access_list: [entry])

      assert {:error, reason} = FeePayerPolicy.validate(tx, policy)
      assert reason =~ "access list"
    end

    test "accepts an empty access list" do
      policy = FeePayerPolicy.resolve(@moderato_chain_id, nil)
      assert FeePayerPolicy.validate(valid_tx(access_list: []), policy) == :ok
    end

    test "fails closed when the access-list field is malformed (non-list scalar)" do
      policy = FeePayerPolicy.resolve(@moderato_chain_id, nil)
      # Access list lives at RLP index 5; a scalar there is a malformed envelope.
      tx = valid_tx()
      corrupted = %{tx | fields: List.replace_at(tx.fields, 5, <<1>>)}

      assert {:error, reason} = FeePayerPolicy.validate(corrupted, policy)
      assert reason =~ "malformed access_list"
    end
  end

  describe "validate/3 — validity window + expiring nonce (held-sponsorship defense)" do
    test "rejects a non-expiring nonce key" do
      policy = FeePayerPolicy.resolve(@moderato_chain_id, nil)
      tx = valid_tx(nonce_key: <<1>>, valid_before: @now + 300)

      assert {:error, reason} = FeePayerPolicy.validate(tx, policy, @now)
      assert reason =~ "expiring nonce key"
    end

    test "rejects a missing valid_before" do
      policy = FeePayerPolicy.resolve(@moderato_chain_id, nil)
      tx = valid_tx(valid_before: 0)

      assert {:error, reason} = FeePayerPolicy.validate(tx, policy, @now)
      assert reason =~ "must declare valid_before"
    end

    test "rejects an already-expired valid_before" do
      policy = FeePayerPolicy.resolve(@moderato_chain_id, nil)
      tx = valid_tx(valid_before: @now - 1)

      assert {:error, reason} = FeePayerPolicy.validate(tx, policy, @now)
      assert reason =~ "already expired"
    end

    test "rejects a validity window beyond the policy maximum" do
      # Default window is 900s; 1_000s out exceeds it even though it is in the future.
      policy = FeePayerPolicy.resolve(@moderato_chain_id, nil)
      tx = valid_tx(valid_before: @now + 1_000)

      assert {:error, reason} = FeePayerPolicy.validate(tx, policy, @now)
      assert reason =~ "validity window"
    end

    test "accepts a valid_before inside the window" do
      policy = FeePayerPolicy.resolve(@moderato_chain_id, nil)
      assert FeePayerPolicy.validate(valid_tx(valid_before: @now + 600), policy, @now) == :ok
    end

    test "accepts valid_before exactly at the window edge" do
      # Default window is 900s; exactly 900s out is allowed (not > max).
      policy = FeePayerPolicy.resolve(@moderato_chain_id, nil)
      assert FeePayerPolicy.validate(valid_tx(valid_before: @now + 900), policy, @now) == :ok
    end

    test "honors a widened max_validity_window_seconds override" do
      policy = FeePayerPolicy.resolve(@moderato_chain_id, %{"max_validity_window_seconds" => 7_200})
      assert FeePayerPolicy.validate(valid_tx(valid_before: @now + 3_600), policy, @now) == :ok
    end

    test "the expiring-nonce sentinel is exactly U256::MAX (2^256 - 1)" do
      assert expiring_nonce_key_int() == Bitwise.bsl(1, 256) - 1
    end
  end

  describe "validate/2 — call value (mppx #602 intrinsic-gas family)" do
    test "rejects a call carrying nonzero native value" do
      policy = FeePayerPolicy.resolve(@moderato_chain_id, nil)
      call = build_call(@token, 1, transfer_calldata(@recipient, 1_000_000))
      tx = valid_tx(calls: [call])

      assert {:error, reason} = FeePayerPolicy.validate(tx, policy)
      assert reason =~ "value is not allowed"
    end

    test "accepts calls with zero value" do
      policy = FeePayerPolicy.resolve(@moderato_chain_id, nil)
      assert FeePayerPolicy.validate(valid_tx(), policy) == :ok
    end
  end

  describe "validate/2 — calldata canonicality (mppx #602)" do
    @memo "0x" <> String.duplicate("ab", 32)

    test "rejects trailing-padded transfer calldata" do
      policy = FeePayerPolicy.resolve(@moderato_chain_id, nil)
      padded = transfer_calldata(@recipient, 1_000_000) <> <<0::256>>
      tx = valid_tx(calls: [build_call(@token, padded)])

      assert {:error, reason} = FeePayerPolicy.validate(tx, policy)
      assert reason =~ "not canonical"
    end

    test "rejects non-canonical high-order padding in an address word" do
      policy = FeePayerPolicy.resolve(@moderato_chain_id, nil)
      # Dirty the first high-pad byte of the address word (canonical requires zero).
      <<sel::binary-size(4), _first::8, rest::binary>> = transfer_calldata(@recipient, 1_000_000)
      dirty = <<sel::binary, 0xFF, rest::binary>>
      tx = valid_tx(calls: [build_call(@token, dirty)])

      assert {:error, reason} = FeePayerPolicy.validate(tx, policy)
      assert reason =~ "not canonical"
    end

    test "rejects trailing-padded transferWithMemo calldata" do
      policy = FeePayerPolicy.resolve(@moderato_chain_id, nil)
      padded = transfer_with_memo_calldata(@recipient, 1_000_000, @memo) <> <<0::256>>
      tx = valid_tx(calls: [build_call(@token, padded)])

      assert {:error, reason} = FeePayerPolicy.validate(tx, policy)
      assert reason =~ "not canonical"
    end

    test "rejects trailing-padded approve calldata" do
      policy = FeePayerPolicy.resolve(@moderato_chain_id, nil)
      padded = approve_calldata(dex_address(), 1_000_000) <> <<0::256>>
      tx = valid_tx(calls: [build_call(@token, padded)])

      assert {:error, reason} = FeePayerPolicy.validate(tx, policy)
      assert reason =~ "not canonical"
    end

    test "rejects trailing-padded swapExactAmountOut calldata" do
      policy = FeePayerPolicy.resolve(@moderato_chain_id, nil)
      tx = valid_tx(calls: [build_call(dex_address(), swap_calldata() <> <<0::256>>)])

      assert {:error, reason} = FeePayerPolicy.validate(tx, policy)
      assert reason =~ "not canonical"
    end

    test "accepts canonical transfer calldata" do
      policy = FeePayerPolicy.resolve(@moderato_chain_id, nil)
      assert FeePayerPolicy.validate(valid_tx(), policy) == :ok
    end

    test "accepts canonical transferWithMemo calldata" do
      policy = FeePayerPolicy.resolve(@moderato_chain_id, nil)
      call = build_call(@token, transfer_with_memo_calldata(@recipient, 1_000_000, @memo))
      assert FeePayerPolicy.validate(valid_tx(calls: [call]), policy) == :ok
    end

    test "accepts canonical approve calldata" do
      policy = FeePayerPolicy.resolve(@moderato_chain_id, nil)
      call = build_call(@token, approve_calldata(dex_address(), 1_000_000))
      assert FeePayerPolicy.validate(valid_tx(calls: [call]), policy) == :ok
    end

    test "accepts canonical swapExactAmountOut calldata" do
      policy = FeePayerPolicy.resolve(@moderato_chain_id, nil)
      call = build_call(dex_address(), swap_calldata())
      assert FeePayerPolicy.validate(valid_tx(calls: [call]), policy) == :ok
    end

    test "accepts an unrecognized selector (call scope gated separately)" do
      policy = FeePayerPolicy.resolve(@moderato_chain_id, nil)
      unknown = <<0xDE, 0xAD, 0xBE, 0xEF>> <> <<0::256>>
      assert FeePayerPolicy.validate(valid_tx(calls: [build_call(@token, unknown)]), policy) == :ok
    end
  end
end
