defmodule MPP.Client.Providers.X402Exact do
  @moduledoc """
  Client provider for x402 v2 exact EVM EIP-3009 payments.

  Signs synthetic `PAYMENT-REQUIRED` challenges via `MPP.X402.Exact` (Task 40
  `sign_transfer/2` + x402 nonce rules). Native Payment-auth EVM challenges are
  refused through `supports_challenge?/2`.
  """

  use MPP.Client.PaymentProvider

  alias MPP.Challenge
  alias MPP.Client.PaymentProvider
  alias MPP.Credential
  alias MPP.X402
  alias MPP.X402.Exact

  @doc "Return true for EVM charge offers; `supports_challenge?/2` further restricts to x402."
  @impl PaymentProvider
  @spec supports?(String.t(), String.t(), map()) :: boolean()
  def supports?(method, intent, _config) do
    method == X402.payment_method() and intent == X402.exact_intent()
  end

  @doc "Return true only for synthetic x402 exact challenges this config can sign."
  @impl PaymentProvider
  @spec supports_challenge?(Challenge.t(), map()) :: boolean()
  def supports_challenge?(%Challenge{} = challenge, config) when is_map(config) do
    Exact.can_handle?(challenge, config)
  end

  @doc "Sign an x402 exact PAYMENT-SIGNATURE payload."
  @impl PaymentProvider
  @spec pay(Challenge.t(), map()) :: {:ok, Credential.t()} | {:error, term()}
  def pay(%Challenge{} = challenge, config) when is_map(config) do
    with {:ok, payload} <- Exact.sign(challenge, config) do
      {:ok, %Credential{challenge: challenge, payload: payload, source: nil}}
    end
  end
end
