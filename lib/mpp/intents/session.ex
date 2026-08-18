defmodule MPP.Intents.Session do
  @moduledoc """
  Session intent request schema — the "Intent = Schema" half of MPP for
  pay-as-you-go / metered sessions.

  Defines the shared session payment request structure used by all payment
  methods that support the `"session"` intent. A session intent specifies a
  per-unit rate (`amount`), optional unit type, currency, and optional deposit
  guidance for opening a payment channel.

  The struct uses Elixir snake_case conventions internally. Use `to_request/1`
  and `from_request/1` to convert to/from the spec's camelCase JSON format
  (matching mpp-rs `SessionRequest`). `decimals` and `external_id` are transient
  and are never serialized into the request map.

  Wire shape (mpp-rs `SessionRequest`): `amount`, `currency`, optional
  `unitType` / `recipient` / `suggestedDeposit` / `methodDetails`. Transient
  fields `decimals` and `external_id` are never serialized (mpp-rs has no
  `externalId` on session requests; `decimals` is `#[serde(skip)]`).

  ## Fields

    * `amount` — (required) per-unit rate in base units (string). Never a float.
    * `currency` — (required) string, preserved verbatim (ISO 4217 for fiat, token address for on-chain)
    * `unit_type` — (optional) rate unit, e.g. `"second"`, `"minute"`, `"request"`
    * `recipient` — (optional) payment recipient identifier
    * `suggested_deposit` — (optional) suggested channel deposit in base units
    * `decimals` — (optional, transient) token decimals for human-readable → base-unit conversion;
      stripped from wire serialization (mpp-rs `#[serde(skip)]`)
    * `external_id` — (optional, transient) caller-provided correlation ID; not on the wire
      (unlike charge intent — mpp-rs `SessionRequest` has no `externalId`)
    * `method_details` — (optional) method-specific fields
  """

  use Descripex, namespace: "/intents"

  alias MPP.Intents.Shared

  @type t :: %__MODULE__{
          amount: String.t(),
          currency: String.t(),
          unit_type: String.t() | nil,
          recipient: String.t() | nil,
          suggested_deposit: String.t() | nil,
          decimals: non_neg_integer() | nil,
          external_id: String.t() | nil,
          method_details: map() | nil
        }

  @enforce_keys [:amount, :currency]
  defstruct [
    :amount,
    :currency,
    :unit_type,
    :recipient,
    :suggested_deposit,
    :decimals,
    :external_id,
    :method_details
  ]

  api(
    :new,
    "Create a new session intent with validation. Amount and currency must be strings; currency is preserved verbatim.",
    params: [
      opts: [
        kind: :value,
        description:
          "Keyword list with `:amount` (required string), `:currency` (required string), " <>
            "`:unit_type`, `:recipient`, `:suggested_deposit`, `:decimals`, `:external_id`, " <>
            "`:method_details` (all optional)"
      ]
    ],
    returns: %{type: :tagged_tuple, description: "`{:ok, session}` on success, `{:error, reason}` on failure"},
    errors: [:amount_required, :invalid_amount, :currency_required, :invalid_currency, :invalid_field_type],
    composes_with: [:to_request]
  )

  @spec new(keyword()) :: {:ok, t()} | {:error, atom()}
  def new(opts) when is_list(opts) do
    with {:ok, amount} <- Shared.validate_amount(opts[:amount]),
         {:ok, currency} <- Shared.validate_currency(opts[:currency]),
         {:ok, unit_type} <- Shared.validate_optional_string(opts[:unit_type]),
         {:ok, recipient} <- Shared.validate_optional_string(opts[:recipient]),
         {:ok, suggested_deposit} <- Shared.validate_optional_string(opts[:suggested_deposit]) do
      {:ok,
       %__MODULE__{
         amount: amount,
         currency: currency,
         unit_type: unit_type,
         recipient: recipient,
         suggested_deposit: suggested_deposit,
         decimals: opts[:decimals],
         external_id: opts[:external_id],
         method_details: opts[:method_details]
       }}
    end
  end

  api(
    :to_request,
    "Serialize the session intent to a JSON-compatible map with camelCase keys per mpp-rs SessionRequest.",
    params: [
      session: [kind: :value, description: "Session struct to serialize"]
    ],
    returns: %{
      type: :map,
      description:
        "Map with camelCase string keys for JSON encoding into challenge `request` (transient `decimals`/`external_id` omitted)"
    },
    composes_with: [:new, :from_request]
  )

  @spec to_request(t()) :: map()
  def to_request(%__MODULE__{} = session) do
    # Match mpp-rs SessionRequest wire keys only — omit transient decimals/external_id.
    %{"amount" => session.amount, "currency" => session.currency}
    |> Shared.put_optional("unitType", session.unit_type)
    |> Shared.put_optional("recipient", session.recipient)
    |> Shared.put_optional("suggestedDeposit", session.suggested_deposit)
    |> Shared.put_optional("methodDetails", session.method_details)
  end

  api(
    :from_request,
    "Deserialize a camelCase JSON map back into a session intent struct.",
    params: [
      map: [kind: :value, description: "Map with camelCase string keys (from JSON-decoded challenge request)"]
    ],
    returns: %{type: :tagged_tuple, description: "`{:ok, session}` on success, `{:error, reason}` on failure"},
    errors: [
      :amount_required,
      :invalid_amount,
      :currency_required,
      :invalid_currency,
      :invalid_field_type,
      :missing_required_fields
    ],
    composes_with: [:new, :to_request]
  )

  @spec from_request(map()) :: {:ok, t()} | {:error, atom()}
  def from_request(%{"amount" => amount, "currency" => currency} = map) do
    new(
      amount: amount,
      currency: currency,
      unit_type: map["unitType"],
      recipient: map["recipient"],
      suggested_deposit: map["suggestedDeposit"],
      method_details: map["methodDetails"]
    )
  end

  @spec from_request(term()) :: {:error, :missing_required_fields}
  def from_request(_), do: {:error, :missing_required_fields}
end
