defmodule MPP.Hex do
  @moduledoc """
  Small internal hex-string helpers shared across the payment-method and
  wire-format modules.

  These cover two string-level checks that are used before length/format
  validation of Ethereum-style hex addresses and calldata:

    * `strip_0x/1` — drop an optional `0x` prefix, returning the rest unchanged.
    * `hex_string?/1` — true when the (already prefix-stripped) string is one or
      more bare hex digits, with **no** `0x` prefix.

  For decode/encode/integer conversion use `Onchain.Hex` (`decode/1`, `encode/1`,
  `to_integer/1`, `valid?/1`). Note `Onchain.Hex.valid?/1` accepts a `0x` prefix,
  whereas `hex_string?/1` here does not — they are not interchangeable.
  """

  @doc """
  Drop an optional leading `0x` prefix, returning the remaining string unchanged.
  """
  @spec strip_0x(String.t()) :: String.t()
  def strip_0x("0x" <> rest), do: rest
  def strip_0x(hex), do: hex

  @doc """
  Return true when `str` is one or more bare hex digits (`0-9a-fA-F`), with no
  `0x` prefix. An empty string is not valid hex.
  """
  @spec hex_string?(String.t()) :: boolean()
  def hex_string?(str), do: Regex.match?(~r/\A[0-9a-fA-F]+\z/, str)
end
