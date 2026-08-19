defmodule MPP.Test.EVMAuthorization do
  @moduledoc false

  alias Cartouche.Hash
  alias Cartouche.Recover
  alias Cartouche.Signer.Curvy
  alias Cartouche.Typed
  alias Cartouche.Typed.Domain
  alias Cartouche.Typed.Type
  alias MPP.Methods.EVM.Authorization
  alias Onchain.Address
  alias Onchain.Hex
  alias Onchain.PrivateKey

  @anvil0_key "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

  @spec private_key() :: String.t()
  def private_key, do: "0x" <> @anvil0_key

  @spec signer_address() :: String.t()
  def signer_address do
    {:ok, address} = Onchain.Signer.address_from_key(private_key())
    address
  end

  @spec sign(map()) :: String.t()
  def sign(params) do
    private_key = Map.get(params, :private_key, private_key())
    {:ok, key_bin} = PrivateKey.decode(private_key)
    {:ok, verifying} = Address.validate(params.currency)
    {:ok, from} = Address.validate(params.from)
    {:ok, to} = Address.validate(params.to)
    {:ok, nonce} = Hex.decode(params.nonce)

    typed = %Typed{
      domain: %Domain{
        name: params.name,
        version: params.version,
        chain_id: params.chain_id,
        verifying_contract: verifying
      },
      types: %{
        "TransferWithAuthorization" => %Type{
          fields: [
            {"from", :address},
            {"to", :address},
            {"value", {:uint, 256}},
            {"validAfter", {:uint, 256}},
            {"validBefore", {:uint, 256}},
            {"nonce", {:bytes, 32}}
          ]
        }
      },
      value: %{
        "from" => from,
        "to" => to,
        "value" => params.value,
        "validAfter" => params.valid_after,
        "validBefore" => params.valid_before,
        "nonce" => nonce
      }
    }

    digest = typed |> Typed.encode() |> Hash.keccak()
    {:ok, signature} = Curvy.sign_payload(digest, key_bin)
    signature = Recover.normalize_low_s(signature)
    {:ok, recid} = Recover.find_recid_from_digest(digest, signature, from)

    "0x" <>
      Base.encode16(
        <<signature.r::unsigned-big-size(256), signature.s::unsigned-big-size(256), recid + 27::8>>,
        case: :lower
      )
  end

  @spec payload(map()) :: map()
  def payload(params) do
    nonce = params[:nonce] || Authorization.challenge_hash(params.challenge_id, params.realm)
    valid_after = params[:valid_after] || 0
    valid_before = params[:valid_before] || System.system_time(:second) + 3600
    value = params[:value] || String.to_integer(params.amount)
    from = params[:from] || signer_address()
    to = params[:to] || params.recipient

    signature =
      params[:signature] ||
        sign(%{
          currency: params.currency,
          name: params.name,
          version: params.version,
          chain_id: params.chain_id,
          from: from,
          to: to,
          value: value,
          valid_after: valid_after,
          valid_before: valid_before,
          nonce: nonce,
          private_key: params[:private_key] || private_key()
        })

    %{
      "type" => "authorization",
      "from" => from,
      "to" => to,
      "value" => Integer.to_string(value),
      "validAfter" => Integer.to_string(valid_after),
      "validBefore" => Integer.to_string(valid_before),
      "nonce" => nonce,
      "signature" => signature
    }
  end
end
