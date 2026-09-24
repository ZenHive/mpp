defmodule MPP.Methods.USDC.Binding do
  @moduledoc """
  Challenge binding shared by every `usdc` profile.

  The EVM authorization nonce and the public request hash follow
  `draft-usdc-charge-00`. `requestHash` inside the nonce preimage is the
  `0x`-prefixed lowercase hex encoding of `keccak256` over the UTF-8 JCS
  request. The draft names that digest but does not pick a JSON string
  encoding; hex with a `0x` prefix matches the nonce field's own encoding.
  """

  alias Cartouche.Hash
  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.JCS
  alias MPP.Receipt
  alias Onchain.Hex

  @profile_types ~w(evm solana stacks gateway)
  @method "usdc"
  @intent "charge"

  @doc "Profile names the v00 draft allows in `methodDetails.type`."
  @spec profile_types() :: [String.t()]
  def profile_types, do: @profile_types

  @doc "Require a positive base-unit amount with no leading zeros."
  @spec positive_amount(Charge.t()) :: :ok | {:error, Errors.t()}
  def positive_amount(%Charge{amount: amount}) when is_binary(amount) do
    if Regex.match?(~r/^[1-9][0-9]*$/, amount) do
      :ok
    else
      {:error, Errors.new(:verification_failed, "USDC amount must be a positive integer in base units")}
    end
  end

  def positive_amount(_charge) do
    {:error, Errors.new(:verification_failed, "USDC amount must be a positive integer in base units")}
  end

  @doc "Select the single profile object whose key equals `methodDetails.type`."
  @spec select_profile(map()) :: {:ok, String.t(), map()} | {:error, Errors.t()}
  def select_profile(details) when is_map(details) do
    type = details["type"]
    present = Enum.filter(@profile_types, &Map.has_key?(details, &1))

    cond do
      type not in @profile_types ->
        {:error, Errors.new(:invalid_payload, "USDC methodDetails.type must be evm, solana, stacks, or gateway")}

      present != [type] or not is_map(details[type]) ->
        {:error,
         Errors.new(
           :invalid_payload,
           "USDC methodDetails must include exactly one profile object matching type"
         )}

      true ->
        {:ok, type, details[type]}
    end
  end

  def select_profile(_details) do
    {:error, Errors.new(:invalid_payload, "USDC methodDetails.type must be evm, solana, stacks, or gateway")}
  end

  @doc "Rebuild the public challenge request, without server config keys."
  @spec public_request(Charge.t()) :: {:ok, map()} | {:error, Errors.t()}
  def public_request(%Charge{} = charge) do
    with {:ok, type, profile} <- select_profile(charge.method_details || %{}) do
      {:ok, Charge.to_request(%{charge | method_details: %{"type" => type, type => profile}})}
    end
  end

  @doc """
  EIP-3009 nonce bound to this USDC challenge.

  `request` is the public JCS request map, not the server config merge.
  """
  @spec authorization_nonce(String.t(), String.t(), map()) :: String.t()
  def authorization_nonce(id, realm, request) when is_binary(id) and is_binary(realm) and is_map(request) do
    preimage = %{
      "id" => id,
      "intent" => @intent,
      "method" => @method,
      "realm" => realm,
      "requestHash" => request_hash(request)
    }

    preimage |> JCS.canonicalize() |> hash_hex()
  end

  @doc "USDC receipt for a settled profile. `network` is the CAIP-2 settlement id."
  @spec receipt(Charge.t(), String.t(), String.t(), String.t()) :: Receipt.t()
  def receipt(%Charge{} = charge, type, reference, network)
      when is_binary(type) and is_binary(reference) and is_binary(network) do
    config = charge.method_details || %{}

    Receipt.new(
      method: @method,
      reference: reference,
      external_id: charge.external_id,
      extensions: %{
        "challengeId" => config["challenge_id"],
        "network" => network,
        "type" => type
      }
    )
  end

  @spec request_hash(map()) :: String.t()
  defp request_hash(request) do
    request |> JCS.canonicalize() |> hash_hex()
  end

  defp hash_hex(bytes) when is_binary(bytes), do: bytes |> Hash.keccak() |> Hex.encode()
end
