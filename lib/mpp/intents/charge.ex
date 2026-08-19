# The shared callback set implements MPP.Intent; reach's behaviour-candidate
# frontend does not suppress plain project-defined @behaviour declarations.
# reach:disable-next-line behaviour_candidate
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
    * `currency` — (required) string, preserved verbatim (ISO 4217 for fiat, token address for on-chain)
    * `recipient` — (optional) payment recipient identifier
    * `description` — (optional) human-readable description
    * `external_id` — (optional) caller-provided correlation ID
    * `method_details` — (optional) method-specific fields (e.g., Stripe's `networkId`)
  """

  @behaviour MPP.Intent

  use Descripex, namespace: "/intents"

  alias MPP.Intents.Shared

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

  api(
    :new,
    "Create a new charge intent with validation. Amount and currency must be strings; currency is preserved verbatim.",
    params: [
      opts: [
        kind: :value,
        description:
          "Keyword list with `:amount` (required string), `:currency` (required string), `:recipient`, `:description`, `:external_id`, `:method_details` (all optional)"
      ]
    ],
    returns: %{type: :tagged_tuple, description: "`{:ok, charge}` on success, `{:error, reason}` on failure"},
    errors: [:amount_required, :invalid_amount, :currency_required, :invalid_currency],
    composes_with: [:to_request]
  )

  @impl MPP.Intent
  @spec new(keyword()) :: {:ok, t()} | {:error, atom()}
  def new(opts) when is_list(opts) do
    with {:ok, amount} <- Shared.validate_amount(opts[:amount]),
         {:ok, currency} <- Shared.validate_currency(opts[:currency]) do
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

  api(:to_request, "Serialize the charge intent to a JSON-compatible map with camelCase keys per spec.",
    params: [
      charge: [kind: :value, description: "Charge struct to serialize"]
    ],
    returns: %{type: :map, description: "Map with camelCase string keys for JSON encoding into challenge `request`"},
    composes_with: [:new, :from_request]
  )

  @impl MPP.Intent
  @spec to_request(t()) :: map()
  def to_request(%__MODULE__{} = charge) do
    %{"amount" => charge.amount, "currency" => charge.currency}
    |> Shared.put_optional("recipient", charge.recipient)
    |> Shared.put_optional("description", charge.description)
    |> Shared.put_optional("externalId", charge.external_id)
    |> Shared.put_optional("methodDetails", charge.method_details)
  end

  api(:from_request, "Deserialize a camelCase JSON map back into a charge intent struct.",
    params: [
      map: [kind: :value, description: "Map with camelCase string keys (from JSON-decoded challenge request)"]
    ],
    returns: %{type: :tagged_tuple, description: "`{:ok, charge}` on success, `{:error, reason}` on failure"},
    errors: [:amount_required, :invalid_amount, :currency_required, :invalid_currency, :missing_required_fields],
    composes_with: [:new, :to_request]
  )

  @impl MPP.Intent
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

  @spec from_request(term()) :: {:error, :missing_required_fields}
  def from_request(_), do: {:error, :missing_required_fields}
end
