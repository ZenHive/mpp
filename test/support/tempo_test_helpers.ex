# Thin wrappers around onchain_tempo modules that accept hex string addresses
# (test convenience — production code uses binary addresses via TIP20 directly).
# Used by MPP.Methods.TempoTest and cross-validation tests.
defmodule MPP.Test.TempoTestHelpers do
  @moduledoc false

  alias Onchain.Tempo.TIP20

  @doc """
  Builds a hex-encoded 0x76 Tempo Transaction with the given calls and chain_id.

  Gas economics (`:gas_limit`, `:max_fee_per_gas`, `:max_priority_fee_per_gas`),
  `:access_list`, the `:nonce_key` (raw binary at field 6), and `:valid_before`
  (unix seconds at field 8) are overridable. When `fee_payer: true`, they default
  to realistic sponsor values that pass `MPP.Methods.Tempo.FeePayerPolicy`
  (expiring nonce key, `valid_before` 10 min out); pass explicit overrides to
  exercise the gas-draining / replay-window attack vectors. Non-fee-payer builds
  keep the historical zero gas-price / 21k gas-limit / empty-field defaults.
  """
  # Expiring nonce key (U256::MAX) — 32 bytes of 0xFF.
  @expiring_nonce_key :binary.copy(<<0xFF>>, 32)

  def build_tempo_tx(opts \\ []) do
    chain_id = Keyword.get(opts, :chain_id, 42_431)
    calls = Keyword.get(opts, :calls, [])
    fee_payer? = Keyword.get(opts, :fee_payer, false)

    # fee_payer_signature: <<0x00>> (placeholder) when fee_payer, <<>> (absent) otherwise.
    fee_payer_sig = if fee_payer?, do: <<0x00>>, else: <<>>

    gas_limit = Keyword.get(opts, :gas_limit, if(fee_payer?, do: 51_299, else: 21_000))
    max_fee = Keyword.get(opts, :max_fee_per_gas, if(fee_payer?, do: 1_000_000_000, else: 0))
    max_priority = Keyword.get(opts, :max_priority_fee_per_gas, max_fee)
    access_list = Keyword.get(opts, :access_list, [])

    nonce_key = Keyword.get(opts, :nonce_key, if(fee_payer?, do: @expiring_nonce_key, else: <<>>))
    valid_before = Keyword.get(opts, :valid_before, if(fee_payer?, do: System.os_time(:second) + 600, else: 0))

    body = [
      :binary.encode_unsigned(chain_id),
      rlp_uint(max_priority),
      rlp_uint(max_fee),
      rlp_uint(gas_limit),
      calls,
      access_list,
      nonce_key,
      <<>>,
      rlp_uint(valid_before),
      <<>>,
      <<>>,
      fee_payer_sig,
      [],
      <<1::512>>
    ]

    raw = <<0x76>> <> ExRLP.encode(body)
    "0x" <> Base.encode16(raw, case: :lower)
  end

  # RLP-canonical unsigned integer: zero encodes as the empty string.
  defp rlp_uint(0), do: <<>>
  defp rlp_uint(n) when is_integer(n) and n > 0, do: :binary.encode_unsigned(n)

  @doc "The expiring nonce key (U256::MAX) as a 32-byte binary — the field-6 value."
  def expiring_nonce_key, do: @expiring_nonce_key

  @doc "The expiring nonce key (U256::MAX) as an integer — for builder `:nonce_key` opts."
  def expiring_nonce_key_int, do: :binary.decode_unsigned(@expiring_nonce_key)

  @doc "A `valid_before` unix timestamp comfortably inside the default 15-min window."
  def future_valid_before, do: System.os_time(:second) + 600

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
