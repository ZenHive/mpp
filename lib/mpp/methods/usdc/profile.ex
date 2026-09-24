defmodule MPP.Methods.USDC.Profile do
  @moduledoc """
  One `usdc` charge profile.

  Stacks (Task 122) and Gateway (Task 123) register another module in
  `MPP.Methods.USDC.profiles/0`. That registration does not change the EVM
  or Solana verification modules.
  """

  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.Receipt

  @doc "Wire name stored in `methodDetails.type`."
  @callback name() :: String.t()

  @doc "Credential `payload.type` this profile accepts."
  @callback credential_type() :: String.t()

  @doc "Raise `ArgumentError` when `method_config` cannot advertise this profile."
  @callback validate_config!(map()) :: :ok

  @doc "Public profile object nested under `methodDetails.type`."
  @callback challenge_details(Charge.t()) :: map()

  @doc "Verify a credential and return the USDC receipt."
  @callback verify(map(), Charge.t()) :: {:ok, Receipt.t()} | {:error, Errors.t()}
end
