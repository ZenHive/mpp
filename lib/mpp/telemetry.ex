defmodule MPP.Telemetry do
  @moduledoc """
  Server-side payment observability via standard `:telemetry` events.

  Mirrors the reference SDK payment-event-hooks surface
  (`challenge.created`, `payment.failed`, `payment.success`) as Elixir
  telemetry events at challenge, verification, and receipt boundaries.

  Payloads are safe to log — no raw credentials or payment proof appear in
  metadata; only challenge IDs, method/intent names, charge amounts, and
  high-level error or receipt outcomes.

  ## Events

    * `[:mpp, :challenge]` — challenge issued (402 response / retry)
    * `[:mpp, :verify, :start]` — credential verification began
    * `[:mpp, :verify, :ok]` — verification succeeded
    * `[:mpp, :verify, :fail]` — verification failed
    * `[:mpp, :receipt]` — receipt produced after successful verification

  Measurements on `[:mpp, :verify, :ok]` and `[:mpp, :verify, :fail]` include
  `:duration` (native monotonic time from start to outcome).
  """

  alias MPP.Challenge
  alias MPP.Credential
  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.Intents.Session
  alias MPP.Receipt

  @type monotonic_time :: integer()
  @type metadata :: map()

  @doc false
  @spec event_names() :: [[atom()]]
  def event_names do
    [
      [:mpp, :challenge],
      [:mpp, :verify, :start],
      [:mpp, :verify, :ok],
      [:mpp, :verify, :fail],
      [:mpp, :receipt]
    ]
  end

  @doc false
  @spec challenge(Challenge.t(), Charge.t() | Session.t() | nil, metadata()) :: :ok
  def challenge(%Challenge{} = challenge, charge \\ nil, extra \\ %{}) do
    :telemetry.execute(
      [:mpp, :challenge],
      %{},
      Map.merge(challenge_metadata(challenge, charge), extra)
    )
  end

  @doc false
  @spec verify_start(Credential.t(), Charge.t() | Session.t() | nil, metadata()) :: monotonic_time()
  def verify_start(%Credential{} = credential, charge \\ nil, extra \\ %{}) do
    :telemetry.execute(
      [:mpp, :verify, :start],
      %{},
      Map.merge(credential_metadata(credential, charge), extra)
    )

    System.monotonic_time()
  end

  @doc false
  @spec verify_ok(Credential.t(), Charge.t() | Session.t() | nil, monotonic_time(), metadata()) :: :ok
  def verify_ok(%Credential{} = credential, charge, start_time, extra \\ %{}) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:mpp, :verify, :ok],
      %{duration: duration},
      Map.merge(credential_metadata(credential, charge), extra)
    )
  end

  @doc false
  @spec verify_fail(
          Credential.t(),
          Charge.t() | Session.t() | nil,
          monotonic_time(),
          Errors.t() | atom(),
          metadata()
        ) :: :ok
  def verify_fail(%Credential{} = credential, charge, start_time, error, extra \\ %{}) do
    duration = System.monotonic_time() - start_time

    metadata =
      credential
      |> credential_metadata(charge)
      |> Map.merge(error_metadata(error))
      |> Map.merge(extra)

    :telemetry.execute([:mpp, :verify, :fail], %{duration: duration}, metadata)
  end

  @doc false
  @spec receipt(Credential.t(), Receipt.t(), Charge.t() | Session.t() | nil, metadata()) :: :ok
  def receipt(%Credential{} = credential, %Receipt{} = receipt, charge \\ nil, extra \\ %{}) do
    metadata =
      credential
      |> credential_metadata(charge)
      |> Map.merge(%{
        receipt_method: receipt.method,
        receipt_reference: receipt.reference
      })
      |> Map.merge(extra)

    :telemetry.execute([:mpp, :receipt], %{}, metadata)
  end

  @doc false
  @spec charge_from_challenge(Challenge.t()) :: Charge.t() | nil
  def charge_from_challenge(%Challenge{request: request}) when is_binary(request) do
    with {:ok, json} <- Base.url_decode64(request, padding: false),
         {:ok, map} <- Jason.decode(json),
         {:ok, charge} <- Charge.from_request(map) do
      charge
    else
      _ -> nil
    end
  end

  defp challenge_metadata(%Challenge{} = challenge, %{amount: amount, currency: currency}) do
    %{
      challenge_id: challenge.id,
      realm: challenge.realm,
      method: challenge.method,
      intent: challenge.intent,
      amount: amount,
      currency: currency
    }
  end

  defp challenge_metadata(%Challenge{} = challenge, nil) do
    case charge_from_challenge(challenge) do
      %Charge{} = charge ->
        challenge_metadata(challenge, charge)

      nil ->
        %{
          challenge_id: challenge.id,
          realm: challenge.realm,
          method: challenge.method,
          intent: challenge.intent
        }
    end
  end

  defp credential_metadata(%Credential{} = credential, charge) do
    credential.challenge
    |> challenge_metadata(charge)
    |> maybe_put(:payer_source, credential.source)
  end

  defp error_metadata(%Errors{type: type, status: status}) do
    %{error_type: type, error_status: status}
  end

  defp error_metadata(reason) when is_atom(reason) do
    %{error_reason: reason}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
