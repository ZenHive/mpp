# The shared callback set IS a behaviour (`use MPP.Method`); reach's source frontend
# can't see the macro-injected `@behaviour`, so the candidate smell false-positives.
# reach:disable-next-line behaviour_candidate
defmodule MPP.Methods.USDC do
  @moduledoc """
  `usdc` charge method for direct Circle USDC.

  v00 implements the EVM EIP-3009 profile and the Solana legacy-SPL profile
  from `draft-usdc-charge-00`. `methodDetails.type` selects the profile, and
  exactly one nested profile object is accepted. Stacks and Gateway register
  in `profiles/0` without changing the EVM or Solana modules.

  ## Configuration

      plug MPP.Plug,
        secret_key: "hmac-secret",
        realm: "api.example.com",
        method: MPP.Methods.USDC,
        amount: "1000000",
        currency: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238",
        recipient: "0xrecipient",
        method_config: %{
          "profile" => "evm",
          "rpc_url" => "https://ethereum-sepolia-rpc.publicnode.com",
          "chain_id" => 11_155_111,
          "private_key" => "0x..."
        }

  Solana uses `"profile" => "solana"`, `"network"` (`mainnet` or `devnet`),
  and the Circle USDC mint as `currency`. Set `"fee_payer" => true` with
  `"fee_payer_private_key"` and `"fee_payer_key"` when the server pays the
  Solana fee.

  Server config stays out of the challenge. The advertised `methodDetails`
  are the nested profile object from the draft.
  """

  use MPP.Method
  use Descripex, namespace: "/methods"

  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.Methods.USDC.Binding
  alias MPP.Receipt
  alias MPP.Tempo.ConCacheStore
  alias MPP.Tempo.Store

  @profiles %{
    "evm" => __MODULE__.EVM,
    "solana" => __MODULE__.Solana
  }

  api(:method_name, "Return the payment method identifier for USDC.")

  @impl MPP.Method
  @spec method_name() :: String.t()
  def method_name, do: "usdc"

  api(:credential_types, "Return the USDC payload types: authorization and transaction.")

  @impl MPP.Method
  @spec credential_types() :: [String.t()]
  def credential_types, do: ~w(authorization transaction)

  api(:profiles, "Return implemented USDC profile modules keyed by methodDetails.type.")

  @spec profiles() :: %{optional(String.t()) => module()}
  def profiles, do: @profiles

  api(
    :validate_config!,
    "Validate USDC method_config. Requires profile plus that profile's keys.",
    params: [config: [kind: :value, description: "method_config map, including profile"]],
    returns: %{type: :atom, description: "`:ok`, or raises ArgumentError"}
  )

  @impl MPP.Method
  @spec validate_config!(map()) :: :ok
  def validate_config!(config) when is_map(config) do
    validate_store!(config["store"])

    case Map.fetch(@profiles, config["profile"]) do
      {:ok, module} ->
        module.validate_config!(config)

      :error ->
        known = @profiles |> Map.keys() |> Enum.sort() |> Enum.join(", ")

        raise ArgumentError,
              "MPP.Methods.USDC requires method_config profile to be one of: #{known}"
    end
  end

  api(:verify, "Verify a USDC credential for the selected direct profile.",
    params: [
      payload: [kind: :value, description: "Credential payload map for the active profile"],
      charge: [kind: :value, description: "Charge whose method_details select the USDC profile"]
    ],
    returns: %{type: :tagged_tuple, description: "`{:ok, receipt}` or `{:error, error}`"},
    errors: [:invalid_payload, :verification_failed]
  )

  @impl MPP.Method
  @spec verify(map(), MPP.Method.intent()) :: {:ok, Receipt.t()} | {:error, Errors.t()}
  def verify(payload, %Charge{} = charge) do
    config = charge.method_details || %{}

    with :ok <- Binding.positive_amount(charge),
         {:ok, type, _profile} <- Binding.select_profile(config),
         :ok <- configured_profile(config, type),
         {:ok, module} <- implemented_profile(type),
         :ok <- payload_type(payload, module) do
      module.verify(payload, charge)
    end
  end

  def verify(_payload, _intent) do
    {:error, Errors.new(:verification_failed, "USDC method supports only the charge intent")}
  end

  api(
    :challenge_method_details,
    "Return the nested USDC methodDetails for the configured profile.",
    params: [charge: [kind: :value, description: "Charge carrying server method_config in method_details"]],
    returns: %{type: :map, description: "Public methodDetails with type and exactly one profile object"}
  )

  @impl MPP.Method
  @spec challenge_method_details(MPP.Method.intent()) :: map() | nil
  def challenge_method_details(%Charge{} = charge) do
    config = charge.method_details || %{}
    module = Map.fetch!(@profiles, config["profile"])
    type = module.name()
    %{"type" => type, type => module.challenge_details(charge)}
  end

  def challenge_method_details(_intent), do: nil

  defp configured_profile(config, type) do
    case config["profile"] do
      nil -> :ok
      ^type -> :ok
      _other -> {:error, Errors.new(:verification_failed, "USDC profile does not match method config")}
    end
  end

  defp implemented_profile(type) do
    case Map.fetch(@profiles, type) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, Errors.new(:verification_failed, "USDC #{type} profile is not implemented")}
    end
  end

  defp payload_type(%{"type" => type}, module) when is_binary(type) do
    if type == module.credential_type() do
      :ok
    else
      {:error,
       Errors.new(:invalid_payload, "USDC #{module.name()} credentials require payload type #{module.credential_type()}")}
    end
  end

  defp payload_type(_payload, module) do
    {:error,
     Errors.new(:invalid_payload, "USDC #{module.name()} credentials require payload type #{module.credential_type()}")}
  end

  defp validate_store!(nil), do: :ok
  defp validate_store!(false), do: :ok

  defp validate_store!({ConCacheStore, opts}) when is_list(opts) do
    if Keyword.keyword?(opts) do
      :ok
    else
      raise ArgumentError, "MPP.Methods.USDC store opts must be a keyword list"
    end
  end

  defp validate_store!(store) when is_atom(store) do
    if Store.dedup_capable?(store) do
      :ok
    else
      raise ArgumentError, "MPP.Methods.USDC store must implement MPP.Tempo.Store"
    end
  end

  defp validate_store!(other) do
    raise ArgumentError, "MPP.Methods.USDC store is invalid: #{inspect(other)}"
  end
end
