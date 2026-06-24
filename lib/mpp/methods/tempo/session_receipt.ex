defmodule MPP.Methods.Tempo.SessionReceipt do
  @moduledoc """
  Session-intent receipt for Tempo — returned in the `Payment-Receipt` header
  for session/pay-as-you-go payments.

  Extends the base [`MPP.Receipt`](`MPP.Receipt`) contract with session-specific
  fields: `channel_id`, `accepted_cumulative`, `spent`, and the optional
  `units` / `tx_hash`. The `reference` field mirrors `channel_id` so this
  receipt satisfies the base receipt shape.

  Serialized as base64url-encoded JSON (no padding) for transport. Wire keys
  are camelCase (`challengeId`, `channelId`, `acceptedCumulative`, `txHash`) to
  stay compatible with the `mppx` and `mpp-rs` reference SDKs. Optional fields
  are omitted from the wire JSON entirely when `nil` (not serialized as
  `null`).

  Receipts only represent success. Session failures are communicated via
  HTTP 402 responses with RFC 9457 Problem Details (see `MPP.Errors`).

  ## Fields

    * `method` — always `"tempo"`
    * `intent` — always `"session"`
    * `status` — always `"success"`
    * `timestamp` — RFC 3339 datetime string (set by `new/1` from
      `DateTime.utc_now/0` unless overridden)
    * `reference` — mirrors `channel_id`; satisfies the base receipt contract
    * `challenge_id` — challenge identifier
    * `channel_id` — payment channel identifier (hex)
    * `accepted_cumulative` — highest accepted cumulative voucher amount
      (decimal string; bigint wire format)
    * `spent` — amount spent in this session (decimal string)
    * `units` — optional integer, number of units consumed
    * `tx_hash` — optional settlement transaction hash (hex)
  """

  use Descripex, namespace: "/methods/tempo"

  @type t :: %__MODULE__{
          method: String.t(),
          intent: String.t(),
          status: String.t(),
          timestamp: String.t(),
          reference: String.t(),
          challenge_id: String.t(),
          channel_id: String.t(),
          accepted_cumulative: String.t(),
          spent: String.t(),
          units: non_neg_integer() | nil,
          tx_hash: String.t() | nil
        }

  @enforce_keys [:challenge_id, :channel_id, :accepted_cumulative, :spent]
  defstruct method: "tempo",
            intent: "session",
            status: "success",
            timestamp: nil,
            reference: nil,
            challenge_id: nil,
            channel_id: nil,
            accepted_cumulative: nil,
            spent: nil,
            units: nil,
            tx_hash: nil

  # 16 KiB cap on client-supplied session-receipt tokens, enforced BEFORE any
  # base64url decode to prevent a memory-exhaustion DoS (an oversized token would
  # force unbounded allocation in Base.url_decode64 + Jason.decode). Mirrors the
  # cap MPP.Headers applies at its three parse sites (mpp-rs #299): this is the
  # Tempo-session sibling of MPP.Headers.parse_receipt and must match its posture.
  # Matches mpp-rs MAX_TOKEN_LEN (refs/mpp-rs/src/protocol/core/headers.rs:18) and
  # mppx maxRequestParameterLength (refs/mppx/src/Challenge.ts:10) — both `16 * 1024`.
  # At-limit input still parses; only over-limit is rejected.
  @max_token_len 16 * 1024

  api(:new, "Create a new Tempo session receipt with defaults for method/intent/status/timestamp.",
    params: [
      opts: [
        kind: :value,
        description:
          "Keyword list with `:challenge_id`, `:channel_id`, `:accepted_cumulative`, `:spent` (all required), and optional `:timestamp`, `:units`, `:tx_hash`. `:reference` defaults to `channel_id`."
      ]
    ],
    returns: %{
      type: :struct,
      description:
        ~s(SessionReceipt struct with method `"tempo"`, intent `"session"`, status `"success"`, RFC 3339 timestamp, and `reference` mirroring `channel_id`)
    }
  )

  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    timestamp = Keyword.get(opts, :timestamp) || DateTime.to_iso8601(DateTime.utc_now())
    channel_id = Keyword.fetch!(opts, :channel_id)
    reference = Keyword.get(opts, :reference, channel_id)

    opts =
      opts
      |> Keyword.put(:timestamp, timestamp)
      |> Keyword.put(:reference, reference)

    struct!(__MODULE__, opts)
  end

  api(
    :to_header,
    "Encode a session receipt to a base64url JSON string (no padding) for the `Payment-Receipt` header.",
    params: [
      receipt: [kind: :value, description: "SessionReceipt struct to encode"]
    ],
    returns: %{type: :string, description: "Base64url-encoded JSON string"},
    composes_with: [:from_header]
  )

  @spec to_header(t()) :: String.t()
  def to_header(%__MODULE__{} = receipt) do
    receipt
    |> to_map()
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  api(
    :from_header,
    "Decode a base64url JSON `Payment-Receipt` header value into a session receipt.",
    params: [
      encoded: [kind: :value, description: "Base64url-encoded JSON session receipt string"]
    ],
    returns: %{
      type: :tagged_tuple,
      description: "`{:ok, receipt}` on success, `{:error, reason}` on failure"
    },
    errors: [:invalid_base64, :invalid_json, :missing_required_fields, :invalid_field_type, :token_too_large],
    composes_with: [:to_header]
  )

  @spec from_header(String.t()) :: {:ok, t()} | {:error, atom()}
  def from_header(encoded) when is_binary(encoded) do
    token = String.trim(encoded)

    with :ok <- check_token_size(token),
         {:ok, json} <- Base.url_decode64(token, padding: false),
         {:ok, map} <- Jason.decode(json),
         {:ok, receipt} <- from_map(map) do
      {:ok, receipt}
    else
      :error -> {:error, :invalid_base64}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
      {:error, reason} -> {:error, reason}
    end
  end

  # Rejects a base64url session-receipt token that exceeds @max_token_len BEFORE
  # it reaches Base.url_decode64 + Jason.decode (token-size DoS guard, mpp-rs #299).
  # At-limit passes; only over-limit is rejected — boundary matches MPP.Headers.
  @spec check_token_size(binary()) :: :ok | {:error, :token_too_large}
  defp check_token_size(token) when byte_size(token) > @max_token_len, do: {:error, :token_too_large}
  defp check_token_size(_token), do: :ok

  defp to_map(%__MODULE__{} = receipt) do
    base = %{
      "method" => receipt.method,
      "intent" => receipt.intent,
      "status" => receipt.status,
      "timestamp" => receipt.timestamp,
      "reference" => receipt.reference,
      "challengeId" => receipt.challenge_id,
      "channelId" => receipt.channel_id,
      "acceptedCumulative" => receipt.accepted_cumulative,
      "spent" => receipt.spent
    }

    base
    |> maybe_put("units", receipt.units)
    |> maybe_put("txHash", receipt.tx_hash)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp from_map(
         %{
           "method" => method,
           "intent" => intent,
           "status" => status,
           "timestamp" => timestamp,
           "reference" => reference,
           "challengeId" => challenge_id,
           "channelId" => channel_id,
           "acceptedCumulative" => accepted_cumulative,
           "spent" => spent
         } = map
       )
       when is_binary(method) and is_binary(intent) and is_binary(status) and is_binary(timestamp) and
              is_binary(reference) and is_binary(challenge_id) and is_binary(channel_id) and
              is_binary(accepted_cumulative) and is_binary(spent) do
    with {:ok, units} <- validate_units(Map.get(map, "units")),
         {:ok, tx_hash} <- validate_tx_hash(Map.get(map, "txHash")) do
      {:ok,
       %__MODULE__{
         method: method,
         intent: intent,
         status: status,
         timestamp: timestamp,
         reference: reference,
         challenge_id: challenge_id,
         channel_id: channel_id,
         accepted_cumulative: accepted_cumulative,
         spent: spent,
         units: units,
         tx_hash: tx_hash
       }}
    end
  end

  defp from_map(_), do: {:error, :missing_required_fields}

  defp validate_units(nil), do: {:ok, nil}
  defp validate_units(v) when is_integer(v) and v >= 0, do: {:ok, v}
  defp validate_units(_), do: {:error, :invalid_field_type}

  defp validate_tx_hash(nil), do: {:ok, nil}
  defp validate_tx_hash(v) when is_binary(v), do: {:ok, v}
  defp validate_tx_hash(_), do: {:error, :invalid_field_type}
end
