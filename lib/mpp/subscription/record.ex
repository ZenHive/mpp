defmodule MPP.Subscription.Record do
  @moduledoc """
  Persisted recurring-payment authority and settlement state.

  `billing_anchor` is the start of the first paid period. Provider-specific
  authority belongs in `method_state`; the remaining fields model billing
  periods shared by every subscription method.
  """

  alias MPP.Intents.Subscription

  @type payment :: %{
          required(:period) => non_neg_integer(),
          required(:reference) => String.t(),
          required(:timestamp) => String.t(),
          required(:event_ids) => [String.t()]
        }

  @type t :: %__MODULE__{
          subscription_id: String.t(),
          method: String.t(),
          subscription: Subscription.t(),
          method_state: map(),
          billing_anchor: DateTime.t(),
          last_charged_period: non_neg_integer(),
          payments: %{non_neg_integer() => payment()},
          reference: String.t(),
          timestamp: String.t(),
          cancellation_effective_at: DateTime.t() | nil,
          in_flight_period: non_neg_integer() | nil,
          in_flight_reference: String.t() | nil
        }

  @enforce_keys [
    :subscription_id,
    :method,
    :subscription,
    :method_state,
    :billing_anchor,
    :reference,
    :timestamp
  ]
  defstruct [
    :subscription_id,
    :method,
    :subscription,
    :method_state,
    :billing_anchor,
    :reference,
    :timestamp,
    last_charged_period: 0,
    payments: %{},
    cancellation_effective_at: nil,
    in_flight_period: nil,
    in_flight_reference: nil
  ]
end
