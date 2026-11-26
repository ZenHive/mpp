defmodule MPP.Client.Spend.Units do
  @moduledoc false
  # Amount and asset helpers shared by MPP.Client.Spend and MPP.Client.Budget.

  alias MPP.Client.Spend

  @decimal ~r/\A\d+(?:\.(\d+))?\z/
  @max_decimal_length 1_024
  @address ~r/\A0x[0-9a-fA-F]{40}\z/

  @doc "Key of an asset on a network. Addresses and Stripe currencies compare case-insensitively (mppx `assetKey`)."
  @spec asset_key(String.t(), String.t()) :: {String.t(), String.t()}
  def asset_key(network, asset) when is_binary(network) and is_binary(asset) do
    if network == "stripe" or asset =~ @address, do: {network, String.downcase(asset)}, else: {network, asset}
  end

  @doc "Units of a validated decimal at `decimals` places; further digits are dropped."
  @spec parse_units(String.t(), non_neg_integer()) :: non_neg_integer()
  def parse_units(value, decimals) when is_binary(value) and is_integer(decimals) and decimals >= 0 do
    {integer, fraction} =
      case String.split(value, ".", parts: 2) do
        [integer, fraction] -> {integer, fraction}
        [integer] -> {integer, ""}
      end

    String.to_integer(integer <> (fraction |> String.slice(0, decimals) |> String.pad_trailing(decimals, "0")))
  end

  @doc "Validate a money tuple; the currency is upcased."
  @spec money!(term(), String.t()) :: {String.t(), String.t()}
  def money!({value, currency}, name) when is_binary(value) and is_binary(currency) do
    if String.trim(currency) == "", do: raise(ArgumentError, "#{name} currency must be a non-empty string")

    if byte_size(value) > @max_decimal_length or not (value =~ @decimal) do
      raise ArgumentError, "#{name} value must be a non-negative decimal string, got: #{inspect(value)}"
    end

    {value, String.upcase(currency)}
  end

  def money!(other, name) do
    raise ArgumentError, ~s(#{name} must be {"<decimal>", "<currency>"}, got: #{inspect(other)})
  end

  @doc "Validate an amount of one asset in atomic units."
  @spec asset_limit!(term(), String.t()) :: Spend.asset_limit()
  def asset_limit!(%{network: network, asset: asset, amount: amount} = limit, _name)
      when is_binary(network) and network != "" and is_binary(asset) and asset != "" and is_integer(amount) and
             amount >= 0 do
    Map.take(limit, [:network, :asset, :amount])
  end

  def asset_limit!(other, name) do
    raise ArgumentError,
          "#{name} needs a :network, an :asset and a non-negative integer :amount, got: #{inspect(other)}"
  end
end
