defmodule MPP.DID do
  @moduledoc """
  Decentralized identifier (DID) helpers for MPP credential sources.

  EVM wallet addresses use the `did:pkh:eip155` method per CAIP-10.
  """

  use Descripex, namespace: "/protocol"

  alias MPP.Hex

  @did_prefix "did:pkh:eip155:"
  @address_hex_length 40

  api(:evm_did, "Build a `did:pkh:eip155` identifier for an EVM address and chain.",
    params: [
      address: [kind: :value, description: "EVM address (e.g., 0x742d35Cc6634c0532925a3b844bC9e7595F8fE00)"],
      chain_id: [kind: :value, description: "EVM chain ID (e.g., 42431 for Tempo Moderato)"]
    ],
    returns: %{
      type: :string,
      description: "DID string in `did:pkh:eip155:<chain_id>:<address>` format",
      example: "did:pkh:eip155:42431:0x742d35Cc6634c0532925a3b844bC9e7595F8fE00"
    }
  )

  @spec evm_did(String.t(), integer()) :: String.t()
  def evm_did(address, chain_id) when is_binary(address) and is_integer(chain_id) do
    "#{@did_prefix}#{chain_id}:#{address}"
  end

  api(
    :parse_evm_did,
    "Parse a `did:pkh:eip155` credential source into chain ID and address.",
    params: [
      did: [kind: :value, description: "DID string (e.g., did:pkh:eip155:42431:0x...)"]
    ],
    returns: %{
      type: :tagged_tuple,
      description: "`{:ok, %{chain_id: int, address: string}}` or `{:error, :invalid_did}`"
    },
    composes_with: [:evm_did]
  )

  @spec parse_evm_did(String.t()) :: {:ok, %{chain_id: non_neg_integer(), address: String.t()}} | {:error, :invalid_did}
  def parse_evm_did(@did_prefix <> rest) when is_binary(rest) do
    case String.split(rest, ":", parts: 2) do
      [chain_id_string, address] ->
        with false <- invalid_chain_id_string?(chain_id_string),
             {chain_id, ""} <- Integer.parse(chain_id_string),
             true <- chain_id >= 0,
             {:ok, normalized} <- normalize_address(address) do
          {:ok, %{chain_id: chain_id, address: normalized}}
        else
          _ -> {:error, :invalid_did}
        end

      _ ->
        {:error, :invalid_did}
    end
  end

  def parse_evm_did(_), do: {:error, :invalid_did}

  @spec invalid_chain_id_string?(String.t()) :: boolean()
  defp invalid_chain_id_string?(chain_id_string) do
    byte_size(chain_id_string) > 1 and String.starts_with?(chain_id_string, "0")
  end

  @spec normalize_address(String.t()) :: {:ok, String.t()} | :error
  defp normalize_address(address) when is_binary(address) do
    hex = Hex.strip_0x(address)

    if byte_size(hex) == @address_hex_length and Hex.hex_string?(hex) do
      {:ok, "0x" <> String.downcase(hex)}
    else
      :error
    end
  end
end
