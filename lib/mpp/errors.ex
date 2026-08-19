defmodule MPP.Errors do
  @moduledoc """
  RFC 9457 Problem Details for MPP payment errors.

  Each error type maps to a problem URI under `https://paymentauth.org/problems/`,
  an HTTP status code, and a human-readable title. Use `to_map/1` to render an
  error as a JSON-compatible map for HTTP response bodies.

  ## Problem Types

  ### Charge / Core

    * `:payment_required` — no payment credential provided (402)
    * `:payment_insufficient` — payment amount too low (402)
    * `:payment_expired` — challenge has expired (402)
    * `:verification_failed` — payment proof is invalid (402)
    * `:method_unsupported` — payment method not accepted (400)
    * `:malformed_credential` — credential cannot be parsed (402)
    * `:invalid_challenge` — challenge ID doesn't match or is unknown (402)
    * `:credential_mismatch` — echoed challenge fields don't match this endpoint (402)
    * `:invalid_payload` — credential payload doesn't match schema (402)
    * `:bad_request` — malformed request (400)
    * `:payment_action_required` — payment requires additional action, e.g. 3DS (402)
    * `:sponsor_capacity_exhausted` — fee sponsor capacity is temporarily unavailable (402)
    * `:settlement_failed` — verified payment reached a non-success terminal settlement (402)
    * `:settlement_unavailable` — settlement backend or required origin RPC is unavailable (503)
    * `:settlement_timeout` — settlement did not reach a terminal state before the server deadline (504)

  ### Session

    * `:insufficient_balance` — insufficient balance in the payment channel (402)
    * `:invalid_signature` — voucher or close request signature is invalid (402)
    * `:signer_mismatch` — recovered signer is not authorized for this channel (402)
    * `:amount_exceeds_deposit` — voucher cumulative amount exceeds the channel deposit (402)
    * `:delta_too_small` — voucher amount increase is below the minimum delta (402)
    * `:channel_not_found` — no channel with this ID exists (410)
    * `:channel_closed` — channel is closed or finalized (410)
  """

  use Descripex, namespace: "/protocol"

  @base_uri "https://paymentauth.org/problems/"

  @problem_types %{
    payment_required: %{suffix: "payment-required", title: "Payment Required", status: 402},
    payment_insufficient: %{suffix: "payment-insufficient", title: "Payment Insufficient", status: 402},
    payment_expired: %{suffix: "payment-expired", title: "Payment Expired", status: 402},
    verification_failed: %{suffix: "verification-failed", title: "Verification Failed", status: 402},
    method_unsupported: %{suffix: "method-unsupported", title: "Method Unsupported", status: 400},
    malformed_credential: %{suffix: "malformed-credential", title: "Malformed Credential", status: 402},
    invalid_challenge: %{suffix: "invalid-challenge", title: "Invalid Challenge", status: 402},
    credential_mismatch: %{suffix: "credential-mismatch", title: "Credential Mismatch", status: 402},
    invalid_payload: %{suffix: "invalid-payload", title: "Invalid Payload", status: 402},
    bad_request: %{suffix: "bad-request", title: "Bad Request", status: 400},
    payment_action_required: %{
      suffix: "payment-action-required",
      title: "Payment Action Required",
      status: 402
    },
    sponsor_capacity_exhausted: %{
      uri: "https://zenhive.github.io/mpp/problems/sponsor-capacity-exhausted",
      title: "Sponsor Capacity Exhausted",
      status: 402
    },
    settlement_failed: %{suffix: "settlement-failed", title: "Settlement Failed", status: 402},
    settlement_unavailable: %{
      suffix: "server-error",
      title: "Settlement Backend Unavailable",
      status: 503
    },
    settlement_timeout: %{suffix: "server-error", title: "Settlement Timeout", status: 504},
    # Session error types (Phase 10)
    insufficient_balance: %{
      suffix: "session/insufficient-balance",
      title: "Insufficient Balance",
      status: 402
    },
    invalid_signature: %{
      suffix: "session/invalid-signature",
      title: "Invalid Signature",
      status: 402
    },
    signer_mismatch: %{suffix: "session/signer-mismatch", title: "Signer Mismatch", status: 402},
    amount_exceeds_deposit: %{
      suffix: "session/amount-exceeds-deposit",
      title: "Amount Exceeds Deposit",
      status: 402
    },
    delta_too_small: %{suffix: "session/delta-too-small", title: "Delta Too Small", status: 402},
    channel_not_found: %{
      suffix: "session/channel-not-found",
      title: "Channel Not Found",
      status: 410
    },
    channel_closed: %{suffix: "session/channel-finalized", title: "Channel Closed", status: 410}
  }

  @type problem_type ::
          :payment_required
          | :payment_insufficient
          | :payment_expired
          | :verification_failed
          | :method_unsupported
          | :malformed_credential
          | :invalid_challenge
          | :credential_mismatch
          | :invalid_payload
          | :bad_request
          | :payment_action_required
          | :sponsor_capacity_exhausted
          | :settlement_failed
          | :settlement_unavailable
          | :settlement_timeout
          | :insufficient_balance
          | :invalid_signature
          | :signer_mismatch
          | :amount_exceeds_deposit
          | :delta_too_small
          | :channel_not_found
          | :channel_closed

  @type t :: %__MODULE__{
          type: String.t(),
          title: String.t(),
          status: pos_integer(),
          detail: String.t(),
          retry_after: pos_integer() | nil
        }

  @enforce_keys [:type, :title, :status, :detail]
  defstruct [:type, :title, :status, :detail, retry_after: nil]

  api(:new, "Create an RFC 9457 Problem Detail error for the given problem type.",
    params: [
      type: [kind: :value, description: "Problem type atom (e.g., `:payment_required`, `:verification_failed`)"],
      detail: [kind: :value, description: "Human-readable error detail string"]
    ],
    returns: %{type: :struct, description: "Error struct with `type` URI, `title`, `status`, and `detail`"},
    composes_with: [:to_map, :to_json]
  )

  @spec new(problem_type(), String.t()) :: t()
  def new(type, detail) when is_atom(type) and is_binary(detail) do
    case Map.fetch(@problem_types, type) do
      {:ok, problem} ->
        %__MODULE__{
          type: Map.get(problem, :uri, @base_uri <> Map.get(problem, :suffix, "")),
          title: problem.title,
          status: problem.status,
          detail: detail
        }

      :error ->
        raise ArgumentError, "unknown problem type: #{inspect(type)}"
    end
  end

  api(:to_json, "Render the error as an RFC 9457 Problem Details JSON string.",
    params: [
      error: [kind: :value, description: "Error struct to serialize"]
    ],
    returns: %{type: :string, description: "JSON string with `type`, `title`, `status`, `detail` keys"},
    composes_with: [:new, :to_map]
  )

  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = error) do
    error
    |> to_map()
    |> Jason.encode!()
  end

  api(:to_map, "Render the error as an RFC 9457 Problem Details map with string keys.",
    params: [
      error: [kind: :value, description: "Error struct to render"]
    ],
    returns: %{type: :map, description: ~s(Map with `"type"`, `"title"`, `"status"`, `"detail"` keys)},
    composes_with: [:new, :to_json]
  )

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = error) do
    %{
      "type" => error.type,
      "title" => error.title,
      "status" => error.status,
      "detail" => error.detail
    }
  end

  api(:put_retry_after, "Attach a positive Retry-After delta in seconds to an error.")

  @doc "Attach a positive `Retry-After` delta-seconds value to an error."
  @spec put_retry_after(t(), integer()) :: t()
  def put_retry_after(%__MODULE__{} = error, seconds) when is_integer(seconds) do
    %{error | retry_after: max(seconds, 1)}
  end

  api(:types, "Return the list of known problem type atoms.")

  @spec types :: [problem_type()]
  def types, do: Map.keys(@problem_types)
end
