defmodule MPP.Tempo.CrossValidationTest do
  @moduledoc """
  Cross-validates our Elixir Tempo implementation against the canonical ox/tempo
  TypeScript SDK via QuickBEAM.

  Two types of cross-validation:
  1. **Constants** — hardcoded addresses, selectors, ABIs match viem/tempo source
  2. **Transaction encoding** — our RLP bytes round-trip through ox/tempo's
     TxEnvelopeTempo.deserialize/serialize, proving byte-level compatibility

  Run with: `mix test test/mpp/tempo/cross_validation_test.exs --include cross_validation`
  """

  use ExUnit.Case, async: true

  alias MPP.Tempo.Transaction
  alias MPP.Test.OxTempoBundle

  @moduletag :cross_validation

  # Our hardcoded values (must match canonical viem/tempo source).
  @stablecoin_dex_hex "0xdec0000000000000000000000000000000000000"

  # Function signature -> keccak256 first 4 bytes (hex)
  @expected_selectors %{
    "transfer" => "a9059cbb",
    "transferWithMemo" => "95777d59",
    "approve" => "095ea7b3",
    "swapExactAmountOut" => "f0122b75"
  }

  # Canonical function signatures (must match viem/tempo ABI definitions).
  @canonical_signatures %{
    "transfer" => "transfer(address,uint256)",
    "transferWithMemo" => "transferWithMemo(address,uint256,bytes32)",
    "approve" => "approve(address,uint256)",
    "swapExactAmountOut" => "swapExactAmountOut(address,address,uint128,uint128)"
  }

  describe "viem/tempo constant cross-validation" do
    setup do
      if !Code.ensure_loaded?(QuickBEAM) do
        flunk("""
        Missing `quickbeam` dependency!

        QuickBEAM is required for cross-validation tests.
        Add it to your mix.exs:
          {:quickbeam, "~> 0.6", only: [:dev, :test]}
        """)
      end

      {:ok, rt} = QuickBEAM.start(apis: :browser)

      on_exit(fn ->
        if Process.alive?(rt), do: QuickBEAM.stop(rt)
      end)

      {:ok, rt: rt}
    end

    test "stablecoinDex address matches viem/tempo", %{rt: rt} do
      # Strip ES module `export` keywords -- QuickBEAM doesn't support ESM syntax
      addresses_js =
        "node_modules/viem/_esm/tempo/Addresses.js"
        |> File.read!()
        |> strip_esm_exports()

      # `const` declarations aren't globals -- assign to globalThis after loading
      {:ok, _} = QuickBEAM.eval(rt, addresses_js <> "\nglobalThis._dex = stablecoinDex;")
      {:ok, dex_from_js} = QuickBEAM.get_global(rt, "_dex")

      assert is_binary(dex_from_js),
             "Expected string from viem/tempo stablecoinDex, got: #{inspect(dex_from_js)}"

      assert String.downcase(dex_from_js) == @stablecoin_dex_hex,
             "stablecoinDex mismatch: viem/tempo=#{dex_from_js}, ours=#{@stablecoin_dex_hex}"
    end

    test "selectors match keccak256 of canonical function signatures" do
      for {name, signature} <- @canonical_signatures do
        computed = keccak_selector(signature)
        expected = @expected_selectors[name]

        assert computed == expected,
               "#{name} selector mismatch: keccak(#{signature})=#{computed}, hardcoded=#{expected}"
      end
    end

    test "function signatures match viem/tempo ABI definitions", %{rt: rt} do
      abis_js =
        "node_modules/viem/_esm/tempo/Abis.js"
        |> File.read!()
        |> strip_esm_exports()

      {:ok, _} = QuickBEAM.eval(rt, abis_js)

      # Extract function signatures from viem's tip20 ABI
      {:ok, tip20_sigs} =
        QuickBEAM.eval(rt, """
          tip20
            .filter(x => x.type === 'function')
            .map(x => x.name + '(' + x.inputs.map(i => i.type).join(',') + ')')
        """)

      assert @canonical_signatures["transfer"] in tip20_sigs,
             "transfer signature not found in viem/tempo tip20 ABI"

      assert @canonical_signatures["transferWithMemo"] in tip20_sigs,
             "transferWithMemo signature not found in viem/tempo tip20 ABI"

      assert @canonical_signatures["approve"] in tip20_sigs,
             "approve signature not found in viem/tempo tip20 ABI"

      # swapExactAmountOut is on stablecoinDex ABI, not tip20
      {:ok, dex_sigs} =
        QuickBEAM.eval(rt, """
          stablecoinDex
            .filter(x => x.type === 'function')
            .map(x => x.name + '(' + x.inputs.map(i => i.type).join(',') + ')')
        """)

      assert @canonical_signatures["swapExactAmountOut"] in dex_sigs,
             "swapExactAmountOut signature not found in viem/tempo stablecoinDex ABI"
    end
  end

  describe "TxEnvelopeTempo transaction cross-validation" do
    setup do
      if !Code.ensure_loaded?(QuickBEAM) do
        flunk("Missing `quickbeam` dependency -- see cross_validation tag docs")
      end

      {:ok, rt} = QuickBEAM.start(apis: :browser)
      OxTempoBundle.load!(rt)

      on_exit(fn ->
        if Process.alive?(rt), do: QuickBEAM.stop(rt)
      end)

      {:ok, rt: rt}
    end

    test "Elixir->JS: unsigned transfer deserializes correctly in ox/tempo", %{rt: rt} do
      hex = build_unsigned_transfer_hex(chain_id: 42_431, nonce: 1, gas: 200_000)

      # Our Elixir parser
      {:ok, elixir_tx} = Transaction.deserialize(hex)
      assert elixir_tx.chain_id == 42_431
      assert length(elixir_tx.calls) == 1

      # ox/tempo TypeScript parser
      js_tx = js_deserialize!(rt, hex)
      assert js_tx["chainId"] == 42_431
      assert js_tx["type"] == "tempo"
      assert js_tx["gas"] == "200000"
      assert js_tx["nonce"] == "1"
      assert length(js_tx["calls"]) == 1

      # Cross-validate: call targets match
      [elixir_call] = elixir_tx.calls
      [js_call] = js_tx["calls"]

      assert String.downcase("0x" <> Base.encode16(elixir_call.to)) ==
               String.downcase(js_call["to"]),
             "Call target mismatch between Elixir and ox/tempo"
    end

    test "Elixir->JS: fee payer placeholder (0x00) round-trips", %{rt: rt} do
      hex = build_fee_payer_placeholder_hex(chain_id: 42_431, nonce: 5)

      {:ok, elixir_tx} = Transaction.deserialize(hex)
      assert elixir_tx.chain_id == 42_431

      js_tx = js_deserialize!(rt, hex)
      assert js_tx["chainId"] == 42_431
      # ox/tempo sets feePayerSignature to null for 0x00 placeholder
      assert js_tx["feePayerSignature"] == nil
    end

    test "JS->Elixir: ox/tempo serialize produces bytes our parser accepts", %{rt: rt} do
      # Build a tx in ox/tempo's serialize, then parse with our Elixir deserializer
      {:ok, hex} =
        QuickBEAM.eval(rt, """
          const envelope = {
            chainId: 42431,
            type: 'tempo',
            maxFeePerGas: 25000000000n,
            maxPriorityFeePerGas: 1000000000n,
            gas: 200000n,
            nonce: 3n,
            nonceKey: 0n,
            calls: [{
              to: '0x70997970c51812dc3a010c7d01b50e0d17dc79c8',
              value: 1000000000000000000n,
              data: '0x'
            }]
          };
          TxET.serialize(envelope);
        """)

      assert String.starts_with?(hex, "0x76"),
             "Expected 0x76 prefix, got: #{String.slice(hex, 0, 4)}"

      {:ok, elixir_tx} = Transaction.deserialize(hex)
      assert elixir_tx.chain_id == 42_431
      assert length(elixir_tx.calls) == 1
    end

    test "Elixir->JS->Elixir: full round-trip preserves bytes", %{rt: rt} do
      # Build in Elixir -> deserialize in JS -> re-serialize in JS -> compare hex
      hex = build_unsigned_transfer_hex(chain_id: 1, nonce: 0, gas: 21_000)

      {:ok, reserialized} =
        QuickBEAM.eval(rt, """
          const _rtTx = TxET.deserialize('#{hex}');
          TxET.serialize(_rtTx);
        """)

      assert String.downcase(reserialized) == String.downcase(hex),
             "Round-trip hex mismatch:\n  original:     #{hex}\n  reserialized: #{reserialized}"
    end

    test "Elixir->JS: multi-call transaction fields match", %{rt: rt} do
      hex = build_multicall_hex(chain_id: 42_431, nonce: 10)

      {:ok, elixir_tx} = Transaction.deserialize(hex)
      assert length(elixir_tx.calls) == 2

      js_tx = js_deserialize!(rt, hex)
      assert length(js_tx["calls"]) == 2

      # Both parsers see same number of calls with same targets
      for {ex_call, js_call} <- Enum.zip(elixir_tx.calls, js_tx["calls"]) do
        assert String.downcase("0x" <> Base.encode16(ex_call.to)) ==
                 String.downcase(js_call["to"])
      end
    end

    test "protocol constants match ox/tempo", %{rt: rt} do
      {:ok, [serial_type, fee_magic]} =
        QuickBEAM.eval(rt, "[TxET.serializedType, TxET.feePayerMagic]")

      assert serial_type == "0x76", "serializedType: expected 0x76, got #{serial_type}"
      assert fee_magic == "0x78", "feePayerMagic: expected 0x78, got #{fee_magic}"
    end
  end

  # --- Helpers: JS interop ---

  # Deserializes a hex string via ox/tempo and returns parsed map.
  defp js_deserialize!(rt, hex) do
    {:ok, json} =
      QuickBEAM.eval(rt, """
        const _dtx = TxET.deserialize('#{hex}');
        JSON.stringify(_dtx, (k, v) => typeof v === 'bigint' ? v.toString() : v);
      """)

    Jason.decode!(json)
  end

  # --- Helpers: Elixir RLP transaction builders ---

  # Builds an unsigned 0x76 transfer transaction hex string.
  defp build_unsigned_transfer_hex(opts) do
    chain_id = Keyword.fetch!(opts, :chain_id)
    nonce = Keyword.fetch!(opts, :nonce)
    gas = Keyword.fetch!(opts, :gas)

    token = decode_hex!("0xdec0000000000000000000000000000000000000")
    recipient = decode_hex!("0x70997970c51812dc3a010c7d01b50e0d17dc79c8")
    amount = 1_000_000_000_000_000_000

    selector = <<0xA9, 0x05, 0x9C, 0xBB>>
    calldata = selector <> <<0::size(96), recipient::binary, amount::unsigned-big-size(256)>>
    call = [token, <<>>, calldata]

    fields = [
      encode_uint(chain_id),
      encode_uint(1_000_000_000),
      encode_uint(25_000_000_000),
      encode_uint(gas),
      [call],
      [],
      encode_uint(0),
      encode_uint(nonce),
      encode_uint(0),
      encode_uint(0),
      <<>>,
      <<>>,
      []
    ]

    "0x76" <> Base.encode16(ExRLP.encode(fields), case: :lower)
  end

  # Builds a 0x76 tx with fee_payer_signature = 0x00 placeholder.
  defp build_fee_payer_placeholder_hex(opts) do
    chain_id = Keyword.fetch!(opts, :chain_id)
    nonce = Keyword.fetch!(opts, :nonce)

    token = decode_hex!("0xdec0000000000000000000000000000000000000")
    recipient = decode_hex!("0x70997970c51812dc3a010c7d01b50e0d17dc79c8")
    amount = 500_000_000_000_000_000

    selector = <<0xA9, 0x05, 0x9C, 0xBB>>
    calldata = selector <> <<0::size(96), recipient::binary, amount::unsigned-big-size(256)>>
    call = [token, <<>>, calldata]

    fields = [
      encode_uint(chain_id),
      encode_uint(1_000_000_000),
      encode_uint(25_000_000_000),
      encode_uint(200_000),
      [call],
      [],
      encode_uint(0),
      encode_uint(nonce),
      encode_uint(0),
      encode_uint(0),
      <<>>,
      <<0x00>>,
      []
    ]

    "0x76" <> Base.encode16(ExRLP.encode(fields), case: :lower)
  end

  # Builds a 0x76 tx with two calls (multi-call).
  defp build_multicall_hex(opts) do
    chain_id = Keyword.fetch!(opts, :chain_id)
    nonce = Keyword.fetch!(opts, :nonce)

    token = decode_hex!("0xdec0000000000000000000000000000000000000")
    recipient1 = decode_hex!("0x70997970c51812dc3a010c7d01b50e0d17dc79c8")
    recipient2 = decode_hex!("0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc")
    selector = <<0xA9, 0x05, 0x9C, 0xBB>>

    call1_data = selector <> <<0::96, recipient1::binary, 1_000_000::unsigned-big-256>>
    call2_data = selector <> <<0::96, recipient2::binary, 2_000_000::unsigned-big-256>>

    fields = [
      encode_uint(chain_id),
      encode_uint(1_000_000_000),
      encode_uint(25_000_000_000),
      encode_uint(200_000),
      [[token, <<>>, call1_data], [token, <<>>, call2_data]],
      [],
      encode_uint(0),
      encode_uint(nonce),
      encode_uint(0),
      encode_uint(0),
      <<>>,
      <<>>,
      []
    ]

    "0x76" <> Base.encode16(ExRLP.encode(fields), case: :lower)
  end

  # Encodes an unsigned integer to minimal big-endian bytes (RLP convention).
  defp encode_uint(0), do: <<>>
  defp encode_uint(n) when is_integer(n) and n > 0, do: :binary.encode_unsigned(n)

  # Decodes a 0x-prefixed hex string to raw bytes.
  defp decode_hex!("0x" <> hex), do: Base.decode16!(hex, case: :mixed)

  # Computes the 4-byte function selector (hex) from a Solidity function signature.
  defp keccak_selector(signature) do
    <<selector::binary-size(4), _::binary>> = Signet.Hash.keccak(signature)
    Base.encode16(selector, case: :lower)
  end

  # Strips `export const` -> `const` so ESM files can be loaded by QuickBEAM.
  defp strip_esm_exports(js) do
    js
    |> String.replace("export const ", "const ")
    |> String.replace("export function ", "function ")
    |> String.replace(~r|//# sourceMappingURL=.*|, "")
  end
end
