# Shared helpers for building test 0x76 Tempo Transactions and TIP-20 calldata.
# Used by both MPP.Tempo.TransactionTest (unit) and MPP.Methods.TempoTest (integration).
defmodule MPP.Test.TempoTestHelpers do
  @moduledoc false

  # TIP-20 function selectors (keccak256 of function signature, first 4 bytes).
  @transfer_selector <<0xA9, 0x05, 0x9C, 0xBB>>
  @transfer_with_memo_selector <<0x95, 0x77, 0x7D, 0x59>>

  @doc "Builds a hex-encoded 0x76 Tempo Transaction with the given calls and chain_id."
  def build_tempo_tx(opts \\ []) do
    chain_id = Keyword.get(opts, :chain_id, 42_431)
    calls = Keyword.get(opts, :calls, [])

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
      <<>>,
      [],
      <<1::512>>
    ]

    raw = <<0x76>> <> ExRLP.encode(body)
    "0x" <> Base.encode16(raw, case: :lower)
  end

  @doc "Builds a single call tuple [to, value, input] for RLP encoding."
  def build_call(to_hex, input) do
    [decode_address(to_hex), <<>>, input]
  end

  @doc "Builds ABI-encoded calldata for transfer(address,uint256)."
  def transfer_calldata(recipient_hex, amount) do
    recipient = decode_address(recipient_hex)
    @transfer_selector <> <<0::96, recipient::binary-size(20), amount::unsigned-big-size(256)>>
  end

  @doc "Builds ABI-encoded calldata for transferWithMemo(address,uint256,bytes32)."
  def transfer_with_memo_calldata(recipient_hex, amount, memo_hex) do
    recipient = decode_address(recipient_hex)
    {:ok, memo_bytes} = Base.decode16(strip_0x(memo_hex), case: :mixed)

    @transfer_with_memo_selector <>
      <<0::96, recipient::binary-size(20), amount::unsigned-big-size(256), memo_bytes::binary-size(32)>>
  end

  @doc "Decodes a hex address (with or without 0x prefix) to a 20-byte binary."
  def decode_address("0x" <> hex), do: decode_address(hex)

  def decode_address(hex) do
    {:ok, bytes} = Base.decode16(hex, case: :mixed)
    bytes
  end

  @doc "Strips the optional 0x prefix from a hex string."
  def strip_0x("0x" <> rest), do: rest
  def strip_0x(hex), do: hex
end
