defmodule MPP.Subscription.Record do
  @moduledoc """
  Persisted recurring-payment authority and settlement state.

  `billing_anchor` is the first settlement block timestamp. Period zero is
  charged by activation; `last_charged_period` advances only after a confirmed
  renewal.
  """

  alias MPP.Intents.Subscription
  alias MPP.Methods.Tempo.KeyAuthorization

  @type t :: %__MODULE__{
          subscription_id: String.t(),
          subscription: Subscription.t(),
          source: String.t(),
          access_key: String.t(),
          access_key_type: KeyAuthorization.key_type(),
          key_authorization: String.t(),
          billing_anchor: DateTime.t(),
          last_charged_period: non_neg_integer(),
          reference: String.t(),
          timestamp: String.t(),
          in_flight_period: non_neg_integer() | nil,
          in_flight_reference: String.t() | nil
        }

  @enforce_keys [
    :subscription_id,
    :subscription,
    :source,
    :access_key,
    :access_key_type,
    :key_authorization,
    :billing_anchor,
    :reference,
    :timestamp
  ]
  defstruct [
    :subscription_id,
    :subscription,
    :source,
    :access_key,
    :access_key_type,
    :key_authorization,
    :billing_anchor,
    :reference,
    :timestamp,
    last_charged_period: 0,
    in_flight_period: nil,
    in_flight_reference: nil
  ]
end
