defmodule MPP.Intents.Shared do
  @moduledoc false

  @doc "Validate a required non-empty string amount."
  @spec validate_amount(term()) :: {:ok, String.t()} | {:error, :amount_required | :invalid_amount}
  def validate_amount(nil), do: {:error, :amount_required}
  def validate_amount(amount) when is_binary(amount) and byte_size(amount) > 0, do: {:ok, amount}
  def validate_amount(_), do: {:error, :invalid_amount}

  @doc "Validate a required non-empty string currency and normalize it to lowercase."
  @spec validate_currency(term()) :: {:ok, String.t()} | {:error, :currency_required | :invalid_currency}
  def validate_currency(nil), do: {:error, :currency_required}

  def validate_currency(currency) when is_binary(currency) and byte_size(currency) > 0,
    do: {:ok, String.downcase(currency)}

  def validate_currency(_), do: {:error, :invalid_currency}

  @doc "Put a map key only when the value is not nil."
  @spec put_optional(map(), String.t(), term()) :: map()
  def put_optional(map, _key, nil), do: map
  def put_optional(map, key, value), do: Map.put(map, key, value)
end
