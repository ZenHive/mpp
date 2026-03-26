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
  """

  use Descripex, namespace: "/protocol"

  @type t :: %__MODULE__{
          status: String.t(),
          method: String.t(),
          timestamp: String.t(),
          reference: String.t(),
          external_id: String.t() | nil
        }

  @enforce_keys [:method, :reference]
  defstruct status: "success",
            method: nil,
            timestamp: nil,
            reference: nil,
            external_id: nil

  api(:new, "Create a new receipt with defaults for `status` and `timestamp`.",
    params: [
      opts: [
        kind: :value,
        description:
          "Keyword list with `:method` (required), `:reference` (required), `:external_id` (optional), `:timestamp` (optional, defaults to now)"
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
    errors: [:invalid_base64, :invalid_json, :missing_required_fields],
    composes_with: [:encode]
  )

  @spec decode(String.t()) :: {:ok, t()} | {:error, atom()}
  def decode(encoded) when is_binary(encoded) do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, map} <- Jason.decode(json),
         {:ok, receipt} <- from_map(map) do
      {:ok, receipt}
    else
      :error -> {:error, :invalid_base64}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
      {:error, reason} -> {:error, reason}
    end
  end

  # Serializes receipt struct to a map with string keys matching the spec.
  defp to_map(%__MODULE__{} = receipt) do
    map = %{
      "status" => receipt.status,
      "method" => receipt.method,
      "timestamp" => receipt.timestamp,
      "reference" => receipt.reference
    }

    if receipt.external_id do
      Map.put(map, "externalId", receipt.external_id)
    else
      map
    end
  end

  # Deserializes a string-keyed map into a receipt struct.
  defp from_map(%{"method" => method, "reference" => reference, "timestamp" => timestamp} = map)
       when is_binary(timestamp) do
    {:ok,
     %__MODULE__{
       status: Map.get(map, "status", "success"),
       method: method,
       timestamp: timestamp,
       reference: reference,
       external_id: Map.get(map, "externalId")
     }}
  end

  defp from_map(_), do: {:error, :missing_required_fields}
end
