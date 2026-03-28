# Thin wrappers around onchain_tempo modules that accept hex string addresses
# (test convenience — production code uses binary addresses via TIP20 directly).
# Used by MPP.Methods.TempoTest and cross-validation tests.
defmodule MPP.Test.TempoTestHelpers do
  @moduledoc false

  alias Onchain.Tempo.TIP20

  @doc "Builds a hex-encoded 0x76 Tempo Transaction with the given calls and chain_id."
  def build_tempo_tx(opts \\ []) do
    chain_id = Keyword.get(opts, :chain_id, 42_431)
    calls = Keyword.get(opts, :calls, [])
    fee_payer? = Keyword.get(opts, :fee_payer, false)

    # fee_payer_signature: <<0x00>> (placeholder) when fee_payer, <<>> (absent) otherwise.
    fee_payer_sig = if fee_payer?, do: <<0x00>>, else: <<>>

    body = [
      :binary.encode_unsigned(chain_id),
      <<>>,
      <<>>,
      :binary.encode_unsigned(21_000),
      calls,
      [],
      <<>>,
      <<>>,
      <<>>,
      <<>>,
      <<>>,
      fee_payer_sig,
      [],
      <<1::512>>
    ]

    raw = <<0x76>> <> ExRLP.encode(body)
    "0x" <> Base.encode16(raw, case: :lower)
  end

  @doc "Builds a single call tuple [to, value, input] for RLP encoding."
  def build_call(to_hex, input), do: [TIP20.decode_address(to_hex), <<>>, input]

  @doc "Builds ABI-encoded calldata for transfer(address,uint256)."
  def transfer_calldata(recipient_hex, amount) do
    TIP20.transfer_calldata(TIP20.decode_address(recipient_hex), amount)
  end

  @doc "Builds ABI-encoded calldata for transferWithMemo(address,uint256,bytes32)."
  def transfer_with_memo_calldata(recipient_hex, amount, memo_hex) do
    {:ok, memo_bytes} = Base.decode16(strip_0x(memo_hex), case: :mixed)
    TIP20.transfer_with_memo_calldata(TIP20.decode_address(recipient_hex), amount, memo_bytes)
  end

  @doc "Returns the canonical stablecoin DEX address (hex string)."
  def dex_address, do: "0xdec0000000000000000000000000000000000000"

  @doc "Builds ABI-encoded calldata for approve(address,uint256)."
  def approve_calldata(spender_hex, amount) do
    TIP20.approve_calldata(TIP20.decode_address(spender_hex), amount)
  end

  @doc "Builds ABI-encoded calldata for swapExactAmountOut with zero-padded args."
  def swap_calldata do
    TIP20.swap_exact_amount_out_selector() <> :binary.copy(<<0>>, 96)
  end

  @doc "Decodes a hex address (with or without 0x prefix) to a 20-byte binary."
  def decode_address(hex), do: TIP20.decode_address(hex)

  @doc "Strips the optional 0x prefix from a hex string."
  def strip_0x("0x" <> rest), do: rest
  def strip_0x(hex), do: hex
end
