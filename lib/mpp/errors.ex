defmodule MPP.Errors do
  @moduledoc """
  RFC 9457 Problem Details for MPP payment errors.

  Each error type maps to a problem URI under `https://paymentauth.org/problems/`,
  an HTTP status code, and a human-readable title. Use `to_map/1` to render an
  error as a JSON-compatible map for HTTP response bodies.

  ## Problem Types

    * `:payment_required` — no payment credential provided (402)
    * `:payment_insufficient` — payment amount too low (402)
    * `:payment_expired` — challenge has expired (402)
    * `:verification_failed` — payment proof is invalid (402)
    * `:method_unsupported` — payment method not accepted (400)
    * `:malformed_credential` — credential cannot be parsed (402)
    * `:invalid_challenge` — challenge ID doesn't match or is unknown (402)
    * `:invalid_payload` — credential payload doesn't match schema (402)
    * `:bad_request` — malformed request (400)
  """

  @base_uri "https://paymentauth.org/problems/"

  @problem_types %{
    payment_required: %{suffix: "payment-required", title: "Payment Required", status: 402},
    payment_insufficient: %{suffix: "payment-insufficient", title: "Payment Insufficient", status: 402},
    payment_expired: %{suffix: "payment-expired", title: "Payment Expired", status: 402},
    verification_failed: %{suffix: "verification-failed", title: "Verification Failed", status: 402},
    method_unsupported: %{suffix: "method-unsupported", title: "Method Unsupported", status: 400},
    malformed_credential: %{suffix: "malformed-credential", title: "Malformed Credential", status: 402},
    invalid_challenge: %{suffix: "invalid-challenge", title: "Invalid Challenge", status: 402},
    invalid_payload: %{suffix: "invalid-payload", title: "Invalid Payload", status: 402},
    bad_request: %{suffix: "bad-request", title: "Bad Request", status: 400}
  }

  @type problem_type ::
          :payment_required
          | :payment_insufficient
          | :payment_expired
          | :verification_failed
          | :method_unsupported
          | :malformed_credential
          | :invalid_challenge
          | :invalid_payload
          | :bad_request

  @type t :: %__MODULE__{
          type: String.t(),
          title: String.t(),
          status: pos_integer(),
          detail: String.t()
        }

  @enforce_keys [:type, :title, :status, :detail]
  defstruct [:type, :title, :status, :detail]

  @doc """
  Creates a new error for the given problem type.

  ## Examples

      error = MPP.Errors.new(:payment_required, "No Authorization header present")
      error.status
      402
  """
  @spec new(problem_type(), String.t()) :: t()
  def new(type, detail) when is_atom(type) and is_binary(detail) do
    case Map.fetch(@problem_types, type) do
      {:ok, problem} ->
        %__MODULE__{
          type: @base_uri <> problem.suffix,
          title: problem.title,
          status: problem.status,
          detail: detail
        }

      :error ->
        raise ArgumentError, "unknown problem type: #{inspect(type)}"
    end
  end

  @doc """
  Renders the error as an RFC 9457 Problem Details JSON string.
  """
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = error) do
    error
    |> to_map()
    |> Jason.encode!()
  end

  @doc """
  Renders the error as an RFC 9457 Problem Details map.

  Returns a map with string keys matching the RFC 9457 structure:
  `"type"`, `"title"`, `"status"`, `"detail"`.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = error) do
    %{
      "type" => error.type,
      "title" => error.title,
      "status" => error.status,
      "detail" => error.detail
    }
  end

  @doc """
  Returns the list of known problem type atoms.
  """
  @spec types :: [problem_type()]
  def types, do: Map.keys(@problem_types)
end
