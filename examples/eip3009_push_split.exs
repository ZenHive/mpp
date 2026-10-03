defmodule MPP.Examples.EIP3009PushSplit do
  @moduledoc """
  Consumer-owned Sepolia PushSplit callback. See README's custom settlement section.
  The relayer function owns signing, nonce coordination and confirmation polling.
  Runtime pins identify observed deployments; they are not an audit claim.
  """

  alias Onchain.ABI
  alias Onchain.Address
  alias Onchain.Contract
  alias Onchain.Hash
  alias Onchain.Hex
  alias Onchain.RPC

  @factory "0x8e8eb0cc6ae34a38b67d5cf91aca38f60bc3ecf4"
  @executor "0xca11bde05977b3631167028862be2a173976ca11"
  @implementation "0x1e2086a7e84a32482ac03000d56925f607ccb708"
  @warehouse "0x8fb66f38cf86a3d5e8768f8f1754a24a6c661fb8"
  @token "0x1c7d4b196cb0c7b01d743fbc6116a902379c7238"
  @split_type "(address[],uint256[],uint256,uint16)"
  @pins %{
    @factory => "0x7289581fdbc21ec0b07d4f34c870a5548a03564691d6e24ef9c770134f8e95fb",
    @executor => "0xd5c15df687b16f2ff992fc8d767b4216323184a2bbc6ee2f9c398c318e770891",
    @implementation => "0xeb00da408a2ba60259ce8f16569939f450adfa1919b856f7e3a9a1a3a1110f69",
    @warehouse => "0x1a204831eb3cb0aeafa06775b0726f62f5be026a3fe0ffb64c6ce6795840b676"
  }

  @doc "Submit the payment-required, distribution-optional batch through the consumer's relayer."
  @spec settle(map(), map()) :: {:ok, String.t()} | {:error, term()}
  def settle(input, config) do
    with {:ok, data} <- batch(input, config) do
      config.relay.(@executor, data)
    end
  end

  @doc "Validate consumer policy and encode the two calls; only distribution may fail."
  @spec batch(map(), map()) :: {:ok, binary()} | {:error, term()}
  def batch(%{chain_id: 11_155_111, currency: currency, authorization: auth}, config) do
    with true <- Address.equal?(currency, @token) and Address.equal?(auth.to, config.split),
         :ok <- validate_split(config) do
      calls = [
        {address(@token), false, payment(auth)},
        {address(config.split), true, distribution(config, String.to_integer(auth.value))}
      ]

      {:ok, ABI.encode_call("aggregate3((address,bool,bytes)[])", [calls])}
    else
      false -> {:error, :unexpected_payment_destination}
      {:error, _} = error -> error
    end
  end

  def batch(_input, _config), do: {:error, :unexpected_chain}

  @doc "Check clone identity, implementation, owner, warehouse and immutable allocation."
  @spec validate_split(map()) :: :ok | {:error, term()}
  def validate_split(config) do
    opts = [rpc_url: config.rpc_url]
    {recipients, allocations, total, incentive} = config.params

    with true <- length(recipients) >= 2 and length(recipients) == length(allocations),
         true <- Enum.all?(allocations, &(&1 > 0)) and Enum.sum(allocations) == total and incentive == 0,
         :ok <- validate_pins(opts),
         {:ok, clone} <- RPC.call("eth_getCode", [config.split, "latest"], opts),
         true <- String.downcase(clone) == clone_code(),
         {:ok, [<<0::160>>]} <- Contract.call(config.split, "owner()", [], "(address)", opts),
         {:ok, [factory]} <- Contract.call(config.split, "FACTORY()", [], "(address)", opts),
         true <- Address.equal?(factory, @factory),
         {:ok, [warehouse]} <- Contract.call(config.split, "SPLITS_WAREHOUSE()", [], "(address)", opts),
         true <- Address.equal?(warehouse, @warehouse),
         {:ok, [split_hash]} <- Contract.call(config.split, "splitHash()", [], "(bytes32)", opts),
         true <- split_hash == Hash.keccak(ABI.encode("(#{@split_type})", [{config.params}])) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :unexpected_split_configuration}
    end
  end

  @doc "Encode a distribution of an explicit amount (no implicit dust subtraction)."
  @spec distribution(map(), non_neg_integer()) :: binary()
  def distribution(config, amount) do
    ABI.encode_call("distribute(#{@split_type},address,uint256,bool,address)", [
      config.params,
      address(@token),
      amount,
      false,
      <<0::160>>
    ])
  end

  defp payment(auth) do
    {:ok, <<r::binary-size(32), s::binary-size(32), v>>} = Hex.decode(auth.signature)
    {:ok, nonce} = Hex.decode(auth.nonce)

    ABI.encode_call("transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)", [
      address(auth.from),
      address(auth.to),
      String.to_integer(auth.value),
      auth.valid_after,
      auth.valid_before,
      nonce,
      v,
      r,
      s
    ])
  end

  defp validate_pins(opts) do
    Enum.reduce_while(@pins, :ok, fn {target, expected}, :ok ->
      with {:ok, code} <- RPC.call("eth_getCode", [target, "latest"], opts),
           {:ok, bytes} <- Hex.decode(code),
           true <- Hex.encode(Hash.keccak(bytes)) == expected do
        {:cont, :ok}
      else
        {:error, _} = error -> {:halt, error}
        false -> {:halt, {:error, :unexpected_runtime_code}}
      end
    end)
  end

  # Official Splits Clone.sol runtime embeds the immutable implementation address.
  defp clone_code do
    "0x36602c57343d527f9e4ac34f21c619cefc926c8bd93b54bf5a39c7ab2127a895af1cc0691d7e3dff" <>
      "593da1005b3d3d3d3d363d3d37363d73" <>
      String.trim_leading(@implementation, "0x") <>
      "5af43d3d93803e605757fd5bf3"
  end

  defp address(value) do
    {:ok, bytes} = Address.validate(value)
    bytes
  end
end
