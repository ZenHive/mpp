defmodule MPP.Amount do
  @moduledoc """
  Amount and decimal helpers for converting human-readable amounts to base units.

  All arithmetic is pure integer/string manipulation — no floating point. This
  matches the mpp-rs `parse_units` and `parse_dollar_amount` implementations.

  ## Examples

      iex> MPP.Amount.parse_units("1.5", 6)
      {:ok, "1500000"}

      iex> MPP.Amount.parse_units("0.10", 6)
      {:ok, "100000"}

      iex> MPP.Amount.parse_dollar_amount("$1.50", 2)
      {:ok, {"150", "usd", 2}}
  """

  use Descripex, namespace: "/protocol"

  api(:parse_units, "Convert a human-readable amount to base units by scaling with 10^decimals.",
    params: [
      amount: [kind: :value, description: ~s{Human-readable amount string (e.g., "1.5", "100", "0.001")}],
      decimals: [kind: :value, description: "Number of decimal places for the token (e.g., 6 for USDC, 18 for ETH)"]
    ],
    returns: %{
      type: :tuple,
      description: "{:ok, base_units_string} or {:error, reason}",
      example: "1500000"
    },
    composes_with: [:with_base_units]
  )

  @spec parse_units(String.t(), non_neg_integer()) :: {:ok, String.t()} | {:error, atom() | {atom(), String.t()}}
  def parse_units(amount, decimals) when is_binary(amount) and is_integer(decimals) and decimals >= 0 do
    amount = String.trim(amount)

    with :ok <- validate_not_empty(amount),
         :ok <- validate_not_negative(amount),
         {:ok, {integer_part, frac_part}} <- split_amount(amount),
         :ok <- validate_digits(integer_part, frac_part, amount),
         :ok <- validate_precision(frac_part, decimals) do
      padded_frac = String.pad_trailing(frac_part, decimals, "0")
      combined = integer_part <> padded_frac

      result = String.trim_leading(combined, "0")

      {:ok, if(result == "", do: "0", else: result)}
    end
  end

  # Boundary validation: amount must be binary, decimals must be non-negative integer
  @spec parse_units(term(), term()) :: {:error, :invalid_input}
  def parse_units(amount, _decimals) when not is_binary(amount), do: {:error, :invalid_input}

  @spec parse_units(term(), term()) :: {:error, :invalid_input}
  def parse_units(_amount, decimals) when not is_integer(decimals) or decimals < 0, do: {:error, :invalid_input}

  api(:with_base_units, "Apply parse_units to any intent struct's amount field.",
    params: [
      intent: [kind: :value, description: "Intent struct (Charge, Session, etc.) with an :amount field"],
      decimals: [kind: :value, description: "Number of decimal places for the token"]
    ],
    returns: %{
      type: :tuple,
      description: "{:ok, updated_intent} with amount in base units, or {:error, reason}"
    },
    composes_with: [:parse_units]
  )

  @spec with_base_units(map(), non_neg_integer()) :: {:ok, map()} | {:error, atom() | {atom(), String.t()}}
  def with_base_units(%{amount: amount} = intent, decimals) do
    case parse_units(amount, decimals) do
      {:ok, base_units} -> {:ok, %{intent | amount: base_units}}
      {:error, _} = error -> error
    end
  end

  api(:parse_dollar_amount, "Parse a dollar-notation string into {base_units, currency, decimals}.",
    params: [
      input: [
        kind: :value,
        description: ~s(Dollar string like "$1.50", "€0.10", or "1.50 USD")
      ],
      decimals: [
        kind: :value,
        description: "Number of decimal places for the currency (caller-supplied, not inferred from currency code)"
      ]
    ],
    returns: %{
      type: :tuple,
      description: ~s({:ok, {base_units, currency, decimals}} where currency is lowercase 3-letter code),
      example: %{base_units: "150", currency: "usd", decimals: 2}
    }
  )

  @currency_symbols %{
    "$" => "usd",
    "€" => "eur",
    "£" => "gbp",
    "¥" => "jpy"
  }

  @spec parse_dollar_amount(String.t(), non_neg_integer()) ::
          {:ok, {String.t(), String.t(), non_neg_integer()}} | {:error, atom() | {atom(), String.t()}}
  def parse_dollar_amount(input, decimals) when is_binary(input) and is_integer(decimals) and decimals >= 0 do
    input = String.trim(input)

    with :ok <- validate_not_empty(input),
         {:ok, {amount_str, currency}} <- extract_currency(input),
         {:ok, base_units} <- parse_units(amount_str, decimals) do
      {:ok, {base_units, currency, decimals}}
    end
  end

  # Boundary validation: input must be binary, decimals must be non-negative integer
  @spec parse_dollar_amount(term(), term()) :: {:error, :invalid_input}
  def parse_dollar_amount(_input, _decimals), do: {:error, :invalid_input}

  # Extracts currency symbol/code and amount from input — returns {amount_str, currency} only.
  # Decimals are caller-supplied, not inferred from currency code (matches official SDK design).
  defp extract_currency(input) do
    case Enum.find(@currency_symbols, fn {symbol, _} -> String.starts_with?(input, symbol) end) do
      {symbol, currency} ->
        amount_str = input |> String.replace_prefix(symbol, "") |> String.trim()
        {:ok, {amount_str, currency}}

      nil ->
        extract_suffix_currency(input)
    end
  end

  # Suffix code: "1.50 USD" — must be exactly two tokens with a 3-letter alpha code.
  # Format is validated (3 alpha chars) but not checked against an ISO 4217 registry.
  defp extract_suffix_currency(input) do
    with [amount_str, code] <- String.split(input, ~r/\s+/, trim: true),
         true <- Regex.match?(~r/^[A-Za-z]{3}$/, code) do
      {:ok, {amount_str, String.downcase(code)}}
    else
      _ -> {:error, {:invalid_format, input}}
    end
  end

  defp validate_not_empty(""), do: {:error, :empty}
  defp validate_not_empty(_), do: :ok

  defp validate_not_negative("-" <> _), do: {:error, :negative}
  defp validate_not_negative(_), do: :ok

  # Splits "1.5" into {"1", "5"}, "100" into {"100", ""}, ".5" into {"", "5"}
  defp split_amount(amount) do
    case String.split(amount, ".", parts: 3) do
      [int] -> {:ok, {int, ""}}
      [int, frac] -> {:ok, {int, frac}}
      _multiple_dots -> {:error, {:invalid_format, amount}}
    end
  end

  defp validate_digits(integer_part, frac_part, amount) do
    all_digits? = fn
      "" -> true
      s -> s |> String.to_charlist() |> Enum.all?(&(&1 in ?0..?9))
    end

    if all_digits?.(integer_part) and all_digits?.(frac_part) and
         not (integer_part == "" and frac_part == "") do
      :ok
    else
      {:error, {:invalid_format, amount}}
    end
  end

  defp validate_precision(frac_part, decimals) do
    if String.length(frac_part) > decimals do
      {:error, :too_many_decimals}
    else
      :ok
    end
  end
end
