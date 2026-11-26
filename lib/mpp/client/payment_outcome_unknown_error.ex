defmodule MPP.Client.PaymentOutcomeUnknownError do
  @moduledoc """
  A payment credential was sent and the request carrying it ended without a
  verdict: the server answered 5xx, or the request failed in transport.

  The payment may have settled. Do not pay again before reconciling it: look
  up `transaction_hash` when it is set, or ask the server about `credential`.

  Problem type `https://paymentauth.org/problems/payment-outcome-unknown`
  (`MPP.Errors` `:payment_outcome_unknown`, mppx `PaymentOutcomeUnknownError`).

  ## Fields

    * `:challenge` - the challenge the credential paid for
    * `:credential` - the `MPP.Credential` that was sent
    * `:transaction_hash` - the on-chain hash the payment has if it settled,
      when the provider can derive it from the credential
      (`c:MPP.Client.PaymentProvider.transaction_hash/2`), else `nil`
    * `:response` - the 5xx response, when there was one
    * `:cause` - what the request failed with, when there was no response
  """

  alias MPP.Client.MultiProvider

  defexception [:challenge, :credential, :transaction_hash, :response, :cause, reason: :payment_outcome_unknown]

  @type t :: %__MODULE__{
          challenge: MPP.Challenge.t(),
          credential: MPP.Credential.t(),
          transaction_hash: String.t() | nil,
          response: term(),
          cause: term(),
          reason: :payment_outcome_unknown
        }

  @impl Exception
  @spec message(t()) :: String.t()
  def message(%__MODULE__{challenge: challenge, transaction_hash: hash}) do
    base = "Payment outcome is unknown after sending a credential for challenge #{inspect(challenge.id)}."
    hint = if is_binary(hash), do: " Look up transaction #{hash} before retrying.", else: " Do not blindly retry."
    base <> hint
  end

  @doc """
  Build the error for `credential`, asking `provider` for the transaction hash.
  """
  @spec new(MultiProvider.t(), MPP.Credential.t(), keyword()) :: t()
  def new(%MultiProvider{} = provider, %MPP.Credential{} = credential, fields \\ []) do
    struct!(
      __MODULE__,
      [
        challenge: credential.challenge,
        credential: credential,
        transaction_hash: MultiProvider.transaction_hash(provider, credential)
      ] ++ fields
    )
  end
end
