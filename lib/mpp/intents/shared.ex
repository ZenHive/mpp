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

  @doc """
  Validate an optional wire field that must be a string when present.

  mpp-rs types `unitType` / `recipient` / `suggestedDeposit` as `Option<String>`
  (refs/mpp-rs/src/protocol/intents/session.rs:40-61), so serde rejects a
  non-string there. Accepting `123` would let us build a request the reference
  SDKs cannot parse.
  """
  @spec validate_optional_string(term()) :: {:ok, String.t() | nil} | {:error, :invalid_field_type}
  def validate_optional_string(nil), do: {:ok, nil}
  def validate_optional_string(value) when is_binary(value), do: {:ok, value}
  def validate_optional_string(_), do: {:error, :invalid_field_type}

  @doc "Put a map key only when the value is not nil."
  @spec put_optional(map(), String.t(), term()) :: map()
  def put_optional(map, _key, nil), do: map
  def put_optional(map, key, value), do: Map.put(map, key, value)
end
