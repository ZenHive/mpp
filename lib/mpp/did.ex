defmodule MPP.DID do
  @moduledoc """
  Decentralized identifier (DID) helpers for MPP credential sources.

  EVM wallet addresses use the `did:pkh:eip155` method per CAIP-10.
  """

  use Descripex, namespace: "/protocol"

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
    "did:pkh:eip155:#{chain_id}:#{address}"
  end
end
