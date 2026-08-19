defmodule MPP.Intents.Subscription do
  @moduledoc """
  Shared recurring-subscription intent schema.

  The schema is payment-method neutral: Tempo and Stripe subscription methods
  consume the same wire fields while applying their own method constraints.
  """

  @behaviour MPP.Intent

  use Descripex, namespace: "/intents"

  alias MPP.Intents.Shared

  @period_units ~w(day week month)

  @type period_unit :: :day | :week | :month
  @type t :: %__MODULE__{
          amount: String.t(),
          currency: String.t(),
          period_unit: period_unit(),
          period_count: String.t(),
          recipient: String.t() | nil,
          subscription_expires: String.t() | nil,
          description: String.t() | nil,
          external_id: String.t() | nil,
          method_details: map() | nil
        }

  @enforce_keys [:amount, :currency, :period_unit, :period_count]
  defstruct [
    :amount,
    :currency,
    :period_unit,
    :period_count,
    :recipient,
    :subscription_expires,
    :description,
    :external_id,
    :method_details
  ]

  api(:new, "Create a validated shared subscription intent.")

  @impl MPP.Intent
  @spec new(keyword()) :: {:ok, t()} | {:error, atom()}
  def new(opts) when is_list(opts) do
    with {:ok, amount} <- validate_positive_decimal(opts[:amount], :invalid_amount),
         {:ok, currency} <- Shared.validate_currency(opts[:currency]),
         {:ok, period_unit} <- validate_period_unit(opts[:period_unit]),
         {:ok, period_count} <- validate_positive_decimal(opts[:period_count], :invalid_period_count),
         {:ok, recipient} <- Shared.validate_optional_string(opts[:recipient]),
         {:ok, subscription_expires} <- validate_expiry(opts[:subscription_expires]),
         {:ok, description} <- Shared.validate_optional_string(opts[:description]),
         {:ok, external_id} <- Shared.validate_optional_string(opts[:external_id]),
         {:ok, method_details} <- validate_method_details(opts[:method_details]) do
      {:ok,
       %__MODULE__{
         amount: amount,
         currency: currency,
         period_unit: period_unit,
         period_count: period_count,
         recipient: recipient,
         subscription_expires: subscription_expires,
         description: description,
         external_id: external_id,
         method_details: method_details
       }}
    end
  end

  api(:to_request, "Serialize a subscription intent with normative camelCase wire keys.")

  @impl MPP.Intent
  @spec to_request(t()) :: map()
  def to_request(%__MODULE__{} = subscription) do
    %{
      "amount" => subscription.amount,
      "currency" => subscription.currency,
      "periodUnit" => Atom.to_string(subscription.period_unit),
      "periodCount" => subscription.period_count
    }
    |> Shared.put_optional("recipient", subscription.recipient)
    |> Shared.put_optional("subscriptionExpires", subscription.subscription_expires)
    |> Shared.put_optional("description", subscription.description)
    |> Shared.put_optional("externalId", subscription.external_id)
    |> Shared.put_optional("methodDetails", subscription.method_details)
  end

  api(:from_request, "Parse a subscription intent from normative camelCase wire keys.")

  @impl MPP.Intent
  @spec from_request(map()) :: {:ok, t()} | {:error, atom()}
  def from_request(
        %{"amount" => amount, "currency" => currency, "periodUnit" => period_unit, "periodCount" => period_count} =
          request
      ) do
    new(
      amount: amount,
      currency: currency,
      period_unit: period_unit,
      period_count: period_count,
      recipient: request["recipient"],
      subscription_expires: request["subscriptionExpires"],
      description: request["description"],
      external_id: request["externalId"],
      method_details: request["methodDetails"]
    )
  end

  @spec from_request(term()) :: {:error, :missing_required_fields}
  def from_request(_request), do: {:error, :missing_required_fields}

  @spec validate_period_unit(term()) :: {:ok, period_unit()} | {:error, :invalid_period_unit}
  defp validate_period_unit(unit) when is_atom(unit), do: unit |> Atom.to_string() |> validate_period_unit()

  defp validate_period_unit(unit) when unit in @period_units, do: {:ok, String.to_existing_atom(unit)}

  defp validate_period_unit(_unit), do: {:error, :invalid_period_unit}

  @spec validate_expiry(term()) :: {:ok, String.t() | nil} | {:error, :invalid_subscription_expires}
  defp validate_expiry(nil), do: {:ok, nil}

  defp validate_expiry(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, _offset} -> {:ok, value}
      {:error, _reason} -> {:error, :invalid_subscription_expires}
    end
  end

  defp validate_expiry(_value), do: {:error, :invalid_subscription_expires}

  @spec validate_method_details(term()) :: {:ok, map() | nil} | {:error, :invalid_method_details}
  defp validate_method_details(nil), do: {:ok, nil}
  defp validate_method_details(details) when is_map(details), do: {:ok, details}
  defp validate_method_details(_details), do: {:error, :invalid_method_details}

  @spec validate_positive_decimal(term(), atom()) :: {:ok, String.t()} | {:error, atom()}
  defp validate_positive_decimal(value, error) when is_binary(value) do
    if Regex.match?(~r/\A[1-9][0-9]*\z/, value), do: {:ok, value}, else: {:error, error}
  end

  defp validate_positive_decimal(_value, error), do: {:error, error}
end
