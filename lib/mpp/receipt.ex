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

  @doc """
  Creates a new receipt with defaults for `status` and `timestamp`.

  ## Options

    * `:method` — (required) payment method name
    * `:reference` — (required) method-specific payment reference
    * `:external_id` — (optional) echoed from credential payload
    * `:timestamp` — (optional) RFC 3339 string, defaults to `DateTime.utc_now/0`

  ## Examples

      receipt = MPP.Receipt.new(method: "stripe", reference: "pi_abc123")
      receipt.status
      "success"
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    timestamp = Keyword.get(opts, :timestamp) || DateTime.to_iso8601(DateTime.utc_now())

    struct!(__MODULE__, Keyword.put(opts, :timestamp, timestamp))
  end

  @doc """
  Encodes a receipt to a base64url JSON string (no padding) for the `Payment-Receipt` header.
  """
  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = receipt) do
    receipt
    |> to_map()
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Decodes a base64url JSON string into a receipt.

  Returns `{:ok, receipt}` on success, `{:error, reason}` on failure.
  """
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
  defp from_map(%{"method" => method, "reference" => reference} = map) do
    {:ok,
     %__MODULE__{
       status: Map.get(map, "status", "success"),
       method: method,
       timestamp: Map.get(map, "timestamp"),
       reference: reference,
       external_id: Map.get(map, "externalId")
     }}
  end

  defp from_map(_), do: {:error, :missing_required_fields}
end
