defmodule MPP.Client.PaymentLimitExceededError do
  @moduledoc """
  Returned when a client spending limit refuses a payment. No credential was
  created.

  `:limit` names what refused it: `:max_payment` (the per-payment limit) or
  `:budget` (an `MPP.Client.Budget`).

  `:reason`:

    * `:amount` — the payment is over the limit or the remaining budget
    * `:asset` — the limit cannot count the payment's asset: no per-asset limit
      names it, or the client configures no currency and decimals for it
    * `:intent` — the challenge is not a `charge`. A session or subscription
      keeps paying after one check, so a limit cannot bound it
    * `:challenge` — the challenge's amount, currency or chain cannot be read

  The first three match mppx `PaymentLimitExceededError` (`refs/mppx/src/Errors.ts`).
  """

  defexception [:limit, :reason]

  @type limit :: :max_payment | :budget
  @type reason :: :amount | :asset | :intent | :challenge
  @type t :: %__MODULE__{limit: limit(), reason: reason()}

  @impl Exception
  @spec message(t()) :: String.t()
  def message(%__MODULE__{limit: limit, reason: reason}) do
    name = if limit == :budget, do: "the remaining budget", else: "max_payment"

    case reason do
      :amount ->
        "payment exceeds #{name}, so no credential was created"

      :intent ->
        "payment intent cannot be checked against #{name}: spending limits accept only charges, " <>
          "so no credential was created"

      :asset ->
        "payment asset cannot be checked against #{name}: no limit names it, or the client configures " <>
          "no currency and decimals for it. No credential was created"

      :challenge ->
        "payment cannot be checked against #{name}: the challenge's amount, currency or chain cannot be read. " <>
          "No credential was created"
    end
  end
end
