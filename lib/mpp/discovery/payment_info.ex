defmodule MPP.Discovery.PaymentInfo do
  @moduledoc """
  Parser and normalizer for the discovery specification's `x-payment-info` extension.

  Both the single-offer shorthand and the multi-offer form are accepted. The
  normalized result always uses the multi-offer `offers` array recommended for
  newly published discovery documents.
  """

  use Descripex, namespace: "/discovery"

  @amount_pattern ~r/^(0|[1-9][0-9]*)$/
  @offer_fields ~w(amount currency description intent method)
  @required_fields ~w(intent method amount)
  @supported_intents ~w(charge session)

  @type offer :: %{
          required(String.t()) => String.t() | nil
        }
  @type t :: %{required(String.t()) => [offer()]}
  @type reason ::
          :empty_offers
          | :invalid_payment_info
          | :mixed_offer_forms
          | {:invalid_offer, non_neg_integer(), term()}

  api(
    :parse,
    "Parse x-payment-info and normalize single-offer shorthand into the multi-offer array form.",
    params: [payment_info: [kind: :value, description: "JSON-compatible x-payment-info map"]],
    returns: %{
      type: :tagged_tuple,
      description: "`{:ok, %{\"offers\" => offers}}` or `{:error, reason}`"
    },
    errors: [:invalid_payment_info, :mixed_offer_forms, :empty_offers, :invalid_offer]
  )

  @spec parse(term()) :: {:ok, t()} | {:error, reason()}
  def parse(%{"offers" => offers} = payment_info) do
    if map_size(payment_info) == 1 do
      parse_offers(offers)
    else
      {:error, :mixed_offer_forms}
    end
  end

  def parse(%{} = offer) do
    case validate_offer(offer) do
      :ok -> {:ok, %{"offers" => [offer]}}
      {:error, reason} -> {:error, {:invalid_offer, 0, reason}}
    end
  end

  def parse(_payment_info), do: {:error, :invalid_payment_info}

  defp parse_offers([]), do: {:error, :empty_offers}

  defp parse_offers(offers) when is_list(offers) do
    offers
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {offer, index}, :ok ->
      case validate_offer(offer) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:invalid_offer, index, reason}}}
      end
    end)
    |> case do
      :ok -> {:ok, %{"offers" => offers}}
      error -> error
    end
  end

  defp parse_offers(_offers), do: {:error, :invalid_payment_info}

  defp validate_offer(offer) when is_map(offer) do
    with :ok <- validate_fields(offer),
         :ok <- validate_required_fields(offer),
         :ok <- validate_intent(offer["intent"]),
         :ok <- validate_string(offer["method"], "method"),
         :ok <- validate_amount(offer["amount"]),
         :ok <- validate_optional_string(offer, "currency") do
      validate_optional_string(offer, "description")
    end
  end

  defp validate_offer(_offer), do: {:error, :not_an_object}

  defp validate_fields(offer) do
    case Map.keys(offer) -- @offer_fields do
      [] -> :ok
      fields -> {:error, {:unsupported_fields, Enum.sort(fields)}}
    end
  end

  defp validate_required_fields(offer) do
    case Enum.reject(@required_fields, &Map.has_key?(offer, &1)) do
      [] -> :ok
      fields -> {:error, {:missing_fields, fields}}
    end
  end

  defp validate_intent(intent) when intent in @supported_intents, do: :ok
  defp validate_intent(_intent), do: {:error, :invalid_intent}

  defp validate_amount(nil), do: :ok

  defp validate_amount(amount) when is_binary(amount) do
    if Regex.match?(@amount_pattern, amount), do: :ok, else: {:error, :invalid_amount}
  end

  defp validate_amount(_amount), do: {:error, :invalid_amount}

  defp validate_optional_string(offer, field) do
    case Map.fetch(offer, field) do
      :error -> :ok
      {:ok, value} -> validate_string(value, field)
    end
  end

  defp validate_string(value, _field) when is_binary(value), do: :ok
  defp validate_string(_value, field), do: {:error, {:invalid_string, field}}
end
