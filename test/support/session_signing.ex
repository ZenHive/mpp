defmodule MPP.Test.SessionSigning do
  @moduledoc false

  alias Cartouche.Recover
  alias Cartouche.Signer.Curvy
  alias MPP.Session.Voucher

  # Anvil account 0 — the well-known dev key; its address is the
  # authorized_signer used across session tests.
  @private_key Base.decode16!("ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80", case: :lower)

  @signer_address "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"

  @spec signer_address() :: String.t()
  def signer_address, do: @signer_address

  @doc "EIP-712-sign a session voucher for the given domain with the Anvil-0 key."
  @spec sign_voucher(String.t(), non_neg_integer(), String.t(), non_neg_integer()) :: String.t()
  def sign_voucher(channel_id, cumulative_amount, escrow_contract, chain_id) do
    voucher = struct(Voucher, channel_id: String.downcase(channel_id), cumulative_amount: cumulative_amount)
    digest = Voucher.hash!(voucher, escrow_contract, chain_id)
    {:ok, signature} = Curvy.sign_payload(digest, @private_key)
    signature = Recover.normalize_low_s(signature)
    {:ok, address} = Curvy.get_address(@private_key)
    {:ok, recid} = Recover.find_recid_from_digest(digest, signature, address)

    "0x" <>
      Base.encode16(
        <<signature.r::unsigned-big-size(256), signature.s::unsigned-big-size(256), recid + 27::8>>,
        case: :lower
      )
  end
end
