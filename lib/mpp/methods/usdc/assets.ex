defmodule MPP.Methods.USDC.Assets do
  @moduledoc """
  Circle-published native USDC deployments for the direct profiles.

  Addresses are the Circle contract list fetched 2026-09-24 from
  <https://developers.circle.com/stablecoins/usdc-contract-addresses>.
  Chain ids are the EIP-155 ids for those networks. Arc Testnet's id
  `5042002` is the one in `draft-usdc-charge-00` appendix A.1, and its
  token address matches Circle's Arc Testnet entry. A chain that is
  absent here is rejected: v00 accepts only native USDC, not a bridged
  or lookalike asset.

  EIP-712 name and version are not taken from this table. The EVM profile
  checks them against the token contract's `DOMAIN_SEPARATOR()`.
  """

  alias Onchain.Address

  @evm %{
    1 => "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
    10 => "0x0b2c639c533813f4aa9d7837caf62653d097ff85",
    130 => "0x078d782b760474a361dda0af3839290b0ef57ad6",
    137 => "0x3c499c542cef5e3811e1192ce70d8cc03d5c3359",
    42_220 => "0xceba9300f2b948710d2653dd7b07f33a8b32118c",
    43_114 => "0xb97ef9ef8734c71904d8002f8b6bc66dd9c48a6e",
    43_113 => "0x5425890298aed601595a70ab815c96711a31bc65",
    59_144 => "0x176211869ca2b568f2a7d4ee941e073a821ee1ff",
    8_453 => "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
    84_532 => "0x036cbd53842c5426634e7929541ec2318f3dcf7e",
    42_161 => "0xaf88d065e77c8cc2239327c5edb3a432268e5831",
    421_614 => "0x75faf114eafb1bdbe2f0316df893fd58ce46aa4d",
    80_002 => "0x41e94eb019c0762f9bfcf9fb1e58725bfb0e7582",
    11_155_420 => "0x5fd84259d66cd46123540766be93dfe6d43130d7",
    11_155_111 => "0x1c7d4b196cb0c7b01d743fbc6116a902379c7238",
    5_042_002 => "0x3600000000000000000000000000000000000000"
  }

  @solana %{
    "mainnet" => "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
    "devnet" => "4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU"
  }

  @doc "True when `chain_id` has a Circle native USDC deployment in this registry."
  @spec known_evm_chain?(term()) :: boolean()
  def known_evm_chain?(chain_id) when is_integer(chain_id), do: Map.has_key?(@evm, chain_id)
  def known_evm_chain?(_chain_id), do: false

  @doc "Return the lowercase native USDC address for an EVM chain."
  @spec evm_currency(integer()) :: {:ok, String.t()} | :error
  def evm_currency(chain_id) when is_integer(chain_id) do
    Map.fetch(@evm, chain_id)
  end

  def evm_currency(_chain_id), do: :error

  @doc "True when `currency` is Circle native USDC on `chain_id`."
  @spec evm?(integer(), term()) :: boolean()
  def evm?(chain_id, currency) when is_integer(chain_id) and is_binary(currency) do
    case Map.fetch(@evm, chain_id) do
      {:ok, expected} -> Address.equal?(currency, expected)
      :error -> false
    end
  end

  def evm?(_chain_id, _currency), do: false

  @doc "True when `currency` is the Circle native USDC mint for `network`."
  @spec solana?(String.t(), term()) :: boolean()
  def solana?(network, currency) when is_binary(network) and is_binary(currency) do
    Map.get(@solana, network) == currency
  end

  def solana?(_network, _currency), do: false

  @doc "Return the Circle USDC mint for `mainnet` or `devnet`."
  @spec solana_mint(String.t()) :: {:ok, String.t()} | :error
  def solana_mint(network) when is_binary(network), do: Map.fetch(@solana, network)
  def solana_mint(_network), do: :error
end
