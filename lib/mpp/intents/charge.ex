defmodule MPP.Intents.Charge do
  @moduledoc """
  Charge intent request schema — the "Intent = Schema" half of MPP.

  Defines the shared payment request structure used by all payment methods.
  A charge intent specifies what needs to be paid (amount, currency) and
  optional metadata (recipient, description, external ID).

  The struct uses Elixir snake_case conventions internally. Use `to_request/1`
  and `from_request/1` to convert to/from the spec's camelCase JSON format.

  ## Fields

    * `amount` — (required) string in base units (cents for fiat, wei for ETH). Never a float.
    * `currency` — (required) lowercase string (ISO 4217 for fiat, token address for on-chain)
    * `recipient` — (optional) payment recipient identifier
    * `description` — (optional) human-readable description
    * `external_id` — (optional) caller-provided correlation ID
    * `method_details` — (optional) method-specific fields (e.g., Stripe's `networkId`)
  """

  @type t :: %__MODULE__{
          amount: String.t(),
          currency: String.t(),
          recipient: String.t() | nil,
          description: String.t() | nil,
          external_id: String.t() | nil,
          method_details: map() | nil
        }

  @enforce_keys [:amount, :currency]
  defstruct [:amount, :currency, :recipient, :description, :external_id, :method_details]

  @doc """
  Creates a new charge intent with validation.

  Amount must be a string (base units). Currency is normalized to lowercase.

  ## Examples

      {:ok, charge} = MPP.Intents.Charge.new(amount: "1000", currency: "USD")
      charge.currency
      "usd"
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, atom()}
  def new(opts) when is_list(opts) do
    with {:ok, amount} <- validate_amount(opts[:amount]),
         {:ok, currency} <- validate_currency(opts[:currency]) do
      {:ok,
       %__MODULE__{
         amount: amount,
         currency: currency,
         recipient: opts[:recipient],
         description: opts[:description],
         external_id: opts[:external_id],
         method_details: opts[:method_details]
       }}
    end
  end

  @doc """
  Serializes the charge intent to a JSON-compatible map with camelCase keys per spec.

  This map is what gets JSON-encoded and base64url-encoded into the challenge `request` field.
  """
  @spec to_request(t()) :: map()
  def to_request(%__MODULE__{} = charge) do
    %{"amount" => charge.amount, "currency" => charge.currency}
    |> put_optional("recipient", charge.recipient)
    |> put_optional("description", charge.description)
    |> put_optional("externalId", charge.external_id)
    |> put_optional("methodDetails", charge.method_details)
  end

  @doc """
  Deserializes a camelCase JSON map back into a charge intent struct.

  Returns `{:ok, charge}` on success, `{:error, reason}` on failure.
  """
  @spec from_request(map()) :: {:ok, t()} | {:error, atom()}
  def from_request(%{"amount" => amount, "currency" => currency} = map) do
    new(
      amount: amount,
      currency: currency,
      recipient: map["recipient"],
      description: map["description"],
      external_id: map["externalId"],
      method_details: map["methodDetails"]
    )
  end

  def from_request(_), do: {:error, :missing_required_fields}

  # Validates that amount is a non-empty string. Numeric validation is intentionally
  # deferred to MPP.Method.verify/2 which checks against the payment provider.
  defp validate_amount(nil), do: {:error, :amount_required}
  defp validate_amount(amount) when is_binary(amount) and byte_size(amount) > 0, do: {:ok, amount}
  defp validate_amount(_), do: {:error, :invalid_amount}

  # Validates that currency is present and normalizes to lowercase.
  defp validate_currency(nil), do: {:error, :currency_required}

  defp validate_currency(currency) when is_binary(currency) and byte_size(currency) > 0,
    do: {:ok, String.downcase(currency)}

  defp validate_currency(_), do: {:error, :invalid_currency}

  # Adds an optional field to the map only if the value is non-nil.
  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
