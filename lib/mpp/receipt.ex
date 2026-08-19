defmodule MPP.Receipt do
  @moduledoc """
  Payment receipt — proof-of-payment returned in the `Payment-Receipt` header.

  A receipt confirms that payment was verified successfully. It is serialized
  as base64url-encoded JSON (no padding) for transport in HTTP headers.

  Receipts only represent success. Payment failures are communicated via
  HTTP 402 responses with RFC 9457 Problem Details (see `MPP.Errors`).

  ## Fields

    * `status` — always `"success"`
    * `method` — payment method name (e.g., `"stripe"`, `"tempo"`)
    * `timestamp` — RFC 3339 datetime string
    * `reference` — method-specific payment reference (PaymentIntent ID, tx hash, etc.)
    * `external_id` — optional, echoed from the credential payload
    * `subscription_id` — optional server-issued subscription identifier (wire `subscriptionId`)
    * `extensions` — method-specific top-level fields not in the core set (e.g. `originTxHash`)

  Unknown top-level keys are preserved through decode → encode (mpp-rs #383
  serde-flattened `extensions`, `refs/mpp-rs/src/protocol/core/challenge.rs:818-820`;
  mppx `z.looseObject`, `refs/mppx/src/Receipt.ts:38`). Core fields keep
  precedence: extensions can never shadow them.
  """

  use Descripex, namespace: "/protocol"

  alias MPP.Codec

  @core_wire_keys ~w(status method timestamp reference externalId subscriptionId)

  @type t :: %__MODULE__{
          status: String.t(),
          method: String.t(),
          timestamp: String.t(),
          reference: String.t(),
          external_id: String.t() | nil,
          subscription_id: String.t() | nil,
          extensions: %{optional(String.t()) => term()}
        }

  @enforce_keys [:method, :reference]
  defstruct status: "success",
            method: nil,
            timestamp: nil,
            reference: nil,
            external_id: nil,
            subscription_id: nil,
            extensions: %{}

  api(:new, "Create a new receipt with defaults for `status` and `timestamp`.",
    params: [
      opts: [
        kind: :value,
        description:
          "Keyword list with `:method` (required), `:reference` (required), `:external_id`, `:subscription_id`, `:extensions` (optional), `:timestamp` (optional, defaults to now)"
      ]
    ],
    returns: %{type: :struct, description: "Receipt struct with status `\"success\"` and RFC 3339 timestamp"}
  )

  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    timestamp = Keyword.get(opts, :timestamp) || DateTime.to_iso8601(DateTime.utc_now())

    struct!(__MODULE__, Keyword.put(opts, :timestamp, timestamp))
  end

  api(:encode, "Encode a receipt to a base64url JSON string (no padding) for the `Payment-Receipt` header.",
    params: [
      receipt: [kind: :value, description: "Receipt struct to encode"]
    ],
    returns: %{type: :string, description: "Base64url-encoded JSON string"},
    composes_with: [:decode]
  )

  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = receipt) do
    receipt
    |> to_map()
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  api(:decode, "Decode a base64url JSON string into a receipt.",
    params: [
      encoded: [kind: :value, description: "Base64url-encoded JSON receipt string"]
    ],
    returns: %{type: :tagged_tuple, description: "`{:ok, receipt}` on success, `{:error, reason}` on failure"},
    errors: [:invalid_base64, :invalid_json, :missing_required_fields, :invalid_field_type],
    composes_with: [:encode]
  )

  @spec decode(String.t()) :: {:ok, t()} | {:error, atom()}
  def decode(encoded) when is_binary(encoded) do
    with {:ok, map} <- Codec.decode_base64_json(encoded) do
      from_map(map)
    end
  end

  # Serializes receipt struct to a map with string keys matching the spec.
  # Extensions are merged first so core keys always win (mpp-rs flatten + named
  # fields; a stuffed `extensions["status"]` cannot override `status`).
  defp to_map(%__MODULE__{} = receipt) do
    core = %{
      "status" => receipt.status,
      "method" => receipt.method,
      "timestamp" => receipt.timestamp,
      "reference" => receipt.reference
    }

    receipt.extensions
    |> Map.drop(@core_wire_keys)
    |> Map.merge(core)
    |> maybe_put("externalId", receipt.external_id)
    |> maybe_put("subscriptionId", receipt.subscription_id)
  end

  # Deserializes a string-keyed map into a receipt struct.
  defp from_map(%{"method" => method, "reference" => reference, "timestamp" => timestamp} = map)
       when is_binary(timestamp) do
    with {:ok, subscription_id} <- optional_string(Map.get(map, "subscriptionId")) do
      {:ok,
       %__MODULE__{
         status: Map.get(map, "status", "success"),
         method: method,
         timestamp: timestamp,
         reference: reference,
         external_id: Map.get(map, "externalId"),
         subscription_id: subscription_id,
         extensions: Map.drop(map, @core_wire_keys)
       }}
    end
  end

  defp from_map(_), do: {:error, :missing_required_fields}

  defp optional_string(nil), do: {:ok, nil}
  defp optional_string(value) when is_binary(value), do: {:ok, value}
  defp optional_string(_value), do: {:error, :invalid_field_type}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
