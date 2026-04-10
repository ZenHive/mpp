defmodule MPP.Client.MultiProvider do
  @moduledoc """
  Wraps multiple payment providers and dispatches to the first match.

  `MultiProvider` holds a list of `{module, config}` tuples, each implementing
  `MPP.Client.PaymentProvider`. When `pay/2` is called, it iterates through
  providers and delegates to the first whose `supports?/3` returns `true`.

  ## Usage

      provider = MPP.Client.MultiProvider.new([
        {MyApp.TempoProvider, %{rpc_url: "https://rpc.tempo.xyz", private_key: key}},
        {MyApp.StripeProvider, %{api_key: "sk_test_..."}}
      ])

      # Dispatches to TempoProvider for tempo challenges, StripeProvider for stripe
      {:ok, credential} = MPP.Client.MultiProvider.pay(provider, challenge)

  ## Design

  Providers are tried in order — the first that supports the challenge's
  method+intent wins. This means provider ordering matters when multiple
  providers support the same method+intent (first wins).
  """

  use Descripex, namespace: "/client"

  @type provider_entry :: {module(), map()}

  @type t :: %__MODULE__{
          providers: [provider_entry()]
        }

  defstruct providers: []

  api(:new, "Create a MultiProvider from a list of {module, config} tuples.",
    params: [
      providers: [
        kind: :value,
        description: "List of {module, config} tuples, each module implementing PaymentProvider"
      ]
    ],
    returns: %{type: :struct, description: "MultiProvider struct"}
  )

  @doc """
  Create a MultiProvider from a list of `{module, config}` tuples.

  Each module must implement the `MPP.Client.PaymentProvider` behaviour.
  """
  @spec new([provider_entry()]) :: t()
  def new(providers \\ []) when is_list(providers) do
    %__MODULE__{providers: providers}
  end

  api(:add, "Add a provider to an existing MultiProvider.",
    params: [
      multi: [kind: :value, description: "Existing MultiProvider struct"],
      module: [kind: :value, description: "Provider module implementing PaymentProvider"],
      config: [kind: :value, description: "Provider-specific configuration map"]
    ],
    returns: %{type: :struct, description: "Updated MultiProvider with the new provider appended"}
  )

  @doc """
  Add a provider to an existing MultiProvider.

  New providers are appended to the end of the list (lower priority than existing).
  """
  @spec add(t(), module(), map()) :: t()
  def add(%__MODULE__{providers: providers} = multi, module, config) do
    %{multi | providers: providers ++ [{module, config}]}
  end

  api(:supports?, "Check if any provider in this MultiProvider supports the method+intent.",
    params: [
      multi: [kind: :value, description: "MultiProvider struct"],
      method: [kind: :value, description: "Payment method name"],
      intent: [kind: :value, description: "Intent type"]
    ],
    returns: %{type: :boolean, description: "true if any provider supports this combination"}
  )

  @doc """
  Check if any provider in this MultiProvider supports the method+intent.
  """
  @spec supports?(t(), String.t(), String.t()) :: boolean()
  def supports?(%__MODULE__{providers: providers}, method, intent) do
    Enum.any?(providers, fn {mod, cfg} -> mod.supports?(method, intent, cfg) end)
  end

  api(:pay, "Execute payment by dispatching to the first matching provider.",
    params: [
      multi: [kind: :value, description: "MultiProvider struct"],
      challenge: [kind: :value, description: "Challenge struct from 402 response"]
    ],
    returns: %{type: :tuple, description: "{:ok, Credential.t()} or {:error, term()}"},
    errors: [:unsupported_payment_method]
  )

  @doc """
  Execute payment by dispatching to the first matching provider.

  Iterates through providers in order, delegating to the first whose
  `supports?/3` returns `true` for the challenge's method and intent.

  Returns `{:error, :unsupported_payment_method}` if no provider matches.
  """
  @spec pay(t(), MPP.Challenge.t()) :: {:ok, MPP.Credential.t()} | {:error, term()}
  def pay(%__MODULE__{providers: providers}, challenge) do
    method = challenge.method
    intent = challenge.intent

    providers
    |> Enum.find(fn {mod, cfg} -> mod.supports?(method, intent, cfg) end)
    |> case do
      {mod, cfg} -> mod.pay(challenge, cfg)
      nil -> {:error, :unsupported_payment_method}
    end
  end
end
