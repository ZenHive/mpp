defmodule MPP.Client.PaymentProvider do
  @moduledoc """
  Behaviour for client-side payment providers.

  A payment provider connects the MPP client to a real payment system
  (Stripe, Tempo, EVM, etc.). Each provider module implements two callbacks
  that the client transport uses when handling 402 challenges:

    1. `supports?/3` — check if this provider handles the given method+intent
    2. `pay/2` — execute payment for a challenge, return a credential

  This is the client-side counterpart to `MPP.Method` (server-side verification).
  Where a method's `verify/2` checks payment proof, `PaymentProvider.pay/2`
  *creates* payment proof.

  ## Usage

      defmodule MyApp.Payments.StripeProvider do
        use MPP.Client.PaymentProvider

        @impl MPP.Client.PaymentProvider
        def supports?(_method, _intent, _config), do: true

        @impl MPP.Client.PaymentProvider
        def pay(challenge, config) do
          # 1. Parse challenge.request for payment details
          # 2. Execute payment (call Stripe API, sign tx, etc.)
          # 3. Return credential with proof payload
          payload = %{"spt" => create_stripe_token(challenge, config)}
          {:ok, %MPP.Credential{challenge: challenge, payload: payload}}
        end
      end

  ## Design

  **Config is explicit.** Providers receive a `config` map on every call —
  no `Application.get_env`, no ENV fallback. The caller passes credentials,
  RPC URLs, and other settings at the call site. This enables multi-tenant
  usage and parallel testing with different configs.

  For multi-provider dispatch, see `MPP.Client.MultiProvider`.
  """

  use Descripex, namespace: "/client"

  alias MPP.Challenge

  @doc """
  Check if this provider supports the given payment method and intent.

  Called before `pay/2` to determine which provider should handle a challenge.
  Return `true` if this provider can execute payment for the combination.

  ## Arguments

    * `method` — payment method name from the challenge (e.g., `"stripe"`, `"tempo"`)
    * `intent` — intent type from the challenge (e.g., `"charge"`, `"session"`)
    * `config` — provider-specific configuration (credentials, endpoints, etc.)
  """
  @callback supports?(method :: String.t(), intent :: String.t(), config :: map()) :: boolean()

  @doc """
  Execute payment for the given challenge and return a credential.

  This callback should:
  1. Decode the challenge request to extract payment details
  2. Execute the payment (sign transaction, call API, etc.)
  3. Build and return a `MPP.Credential` with the echoed challenge and proof payload

  ## Arguments

    * `challenge` — the `MPP.Challenge` struct from the 402 response
    * `config` — provider-specific configuration (API keys, RPC URLs, etc.)

  ## Returns

    * `{:ok, MPP.Credential.t()}` — payment executed, credential ready to send
    * `{:error, term()}` — payment failed
  """
  @callback pay(challenge :: Challenge.t(), config :: map()) ::
              {:ok, MPP.Credential.t()} | {:error, term()}

  api(:supports?, "Check if a provider module supports the given method and intent.",
    params: [
      module: [kind: :value, description: "Provider module implementing this behaviour"],
      method: [kind: :value, description: ~s{Payment method name (e.g., "stripe", "tempo")}],
      intent: [kind: :value, description: ~s{Intent type (e.g., "charge", "session")}],
      config: [kind: :value, description: "Provider-specific configuration map"]
    ],
    returns: %{type: :boolean, description: "true if the provider supports this combination"}
  )

  @doc """
  Check if a provider module supports the given method and intent.

  Convenience function that delegates to `module.supports?/3`.
  """
  @spec supports?(module(), String.t(), String.t(), map()) :: boolean()
  def supports?(module, method, intent, config) do
    module.supports?(method, intent, config)
  end

  api(:pay, "Execute payment using a provider module for the given challenge.",
    params: [
      module: [kind: :value, description: "Provider module implementing this behaviour"],
      challenge: [kind: :value, description: "Challenge struct from 402 response"],
      config: [kind: :value, description: "Provider-specific configuration map"]
    ],
    returns: %{type: :tuple, description: "{:ok, Credential.t()} or {:error, term()}"}
  )

  @doc """
  Execute payment using a provider module for the given challenge.

  Convenience function that delegates to `module.pay/2`.
  """
  @spec pay(module(), Challenge.t(), map()) ::
          {:ok, MPP.Credential.t()} | {:error, term()}
  def pay(module, challenge, config) do
    module.pay(challenge, config)
  end

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour MPP.Client.PaymentProvider
    end
  end
end
