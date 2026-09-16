defmodule MPP.Test.EVMTransaction do
  @moduledoc false

  alias Cartouche.Hash
  alias MPP.Test.EVMAuthorization
  alias Onchain.ABI
  alias Onchain.Address
  alias Onchain.Hex
  alias Onchain.Signer

  @spec private_key() :: String.t()
  def private_key, do: EVMAuthorization.private_key()

  @spec signer_address() :: String.t()
  def signer_address, do: EVMAuthorization.signer_address()

  @spec sign_transfer(map()) :: %{payload: map(), hash: String.t(), raw: String.t()}
  def sign_transfer(params) do
    private_key = Map.get(params, :private_key, private_key())
    nonce = Map.get(params, :nonce, 0)
    chain_id = Map.fetch!(params, :chain_id)
    gas_limit = Map.get(params, :gas_limit, 100_000)
    max_fee = Map.get(params, :max_fee_per_gas, {30, :gwei})
    max_priority = Map.get(params, :max_priority_fee_per_gas, {2, :gwei})
    amount = Map.fetch!(params, :amount)
    recipient = Map.fetch!(params, :recipient)
    currency = Map.fetch!(params, :currency)

    {:ok, to_bin} = Address.validate(recipient)

    calldata =
      case Map.fetch(params, :data) do
        {:ok, data} when is_binary(data) ->
          data

        :error ->
          {:ok, calldata_hex} = ABI.encode_call("transfer(address,uint256)", [to_bin, amount])
          Hex.decode!(calldata_hex)
      end

    {:ok, unsigned} =
      Signer.build_transaction(currency, calldata,
        nonce: nonce,
        chain_id: chain_id,
        gas_limit: gas_limit,
        max_fee_per_gas: max_fee,
        max_priority_fee_per_gas: max_priority
      )

    {:ok, signed} = Signer.sign_transaction(unsigned, private_key, chain_id)
    {:ok, raw} = Signer.encode_transaction(signed)
    bytes = Hex.decode!(raw)
    hash = Hex.encode(Hash.keccak(bytes))

    %{payload: %{"type" => "transaction", "signature" => raw}, hash: hash, raw: raw}
  end
end
