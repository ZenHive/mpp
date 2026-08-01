defmodule MPP.Expires do
  @moduledoc """
  Expiration timestamp helpers for MPP challenges.

  Duration helpers return ISO 8601 datetime strings offset from `DateTime.utc_now/0`.
  `months/1` uses 30-day months (mppx-compatible). `assert!/1` validates that a
  timestamp is present, well-formed, and not in the past.
  """

  use Descripex, namespace: "/protocol"

  @seconds_per_minute 60
  @seconds_per_hour 3_600
  @seconds_per_day 86_400
  @seconds_per_week 7 * @seconds_per_day
  @seconds_per_month 30 * @seconds_per_day
  @seconds_per_year 365 * @seconds_per_day

  defmodule InvalidChallengeError do
    @moduledoc false
    defexception [:message, :challenge_id, :reason]
  end

  defmodule PaymentExpiredError do
    @moduledoc false
    defexception [:message, :expires]
  end

  api(:seconds, "Returns an ISO 8601 datetime string `n` seconds from now.",
    params: [n: [kind: :value, description: "Number of seconds"]],
    returns: %{type: :string, description: "RFC 3339 expiration timestamp"}
  )

  @spec seconds(number()) :: String.t()
  def seconds(n), do: offset_iso8601(n)

  api(:minutes, "Returns an ISO 8601 datetime string `n` minutes from now.",
    params: [n: [kind: :value, description: "Number of minutes"]],
    returns: %{type: :string, description: "RFC 3339 expiration timestamp"}
  )

  @spec minutes(number()) :: String.t()
  def minutes(n), do: offset_iso8601(n * @seconds_per_minute)

  api(:hours, "Returns an ISO 8601 datetime string `n` hours from now.",
    params: [n: [kind: :value, description: "Number of hours"]],
    returns: %{type: :string, description: "RFC 3339 expiration timestamp"}
  )

  @spec hours(number()) :: String.t()
  def hours(n), do: offset_iso8601(n * @seconds_per_hour)

  api(:days, "Returns an ISO 8601 datetime string `n` days from now.",
    params: [n: [kind: :value, description: "Number of days"]],
    returns: %{type: :string, description: "RFC 3339 expiration timestamp"}
  )

  @spec days(number()) :: String.t()
  def days(n), do: offset_iso8601(n * @seconds_per_day)

  api(:weeks, "Returns an ISO 8601 datetime string `n` weeks from now.",
    params: [n: [kind: :value, description: "Number of weeks"]],
    returns: %{type: :string, description: "RFC 3339 expiration timestamp"}
  )

  @spec weeks(number()) :: String.t()
  def weeks(n), do: offset_iso8601(n * @seconds_per_week)

  api(:months, "Returns an ISO 8601 datetime string `n` months (30 days) from now.",
    params: [n: [kind: :value, description: "Number of 30-day months"]],
    returns: %{type: :string, description: "RFC 3339 expiration timestamp"}
  )

  @spec months(number()) :: String.t()
  def months(n), do: offset_iso8601(n * @seconds_per_month)

  api(:years, "Returns an ISO 8601 datetime string `n` years (365 days) from now.",
    params: [n: [kind: :value, description: "Number of 365-day years"]],
    returns: %{type: :string, description: "RFC 3339 expiration timestamp"}
  )

  @spec years(number()) :: String.t()
  def years(n), do: offset_iso8601(n * @seconds_per_year)

  api(:assert!, "Asserts that `expires` is present, well-formed, and not in the past.",
    params: [
      expires: [kind: :value, description: "RFC 3339 expiration timestamp"],
      challenge_id: [kind: :value, description: "Optional challenge ID for error context"]
    ],
    returns: %{type: :atom, description: "`:ok` when valid"},
    errors: [:invalid_challenge, :payment_expired]
  )

  @spec assert!(term()) :: :ok
  def assert!(expires), do: assert!(expires, nil)

  @doc """
  Asserts that `expires` is present, well-formed, and not in the past.

  When `challenge_id` is provided, it is included in invalid-challenge errors.
  """
  @spec assert!(term(), String.t() | nil) :: :ok
  def assert!(nil, challenge_id) do
    raise_invalid!(challenge_id, "missing required expires field")
  end

  def assert!(expires, challenge_id) when is_binary(expires) do
    case DateTime.from_iso8601(expires) do
      {:ok, expires_dt, _offset} ->
        if expired?(expires_dt) do
          raise_payment_expired!(expires)
        else
          :ok
        end

      {:error, _} ->
        raise_invalid!(challenge_id, "malformed expires timestamp")
    end
  end

  def assert!(_expires, challenge_id) do
    raise_invalid!(challenge_id, "malformed expires timestamp")
  end

  defp offset_iso8601(seconds) when is_number(seconds) do
    DateTime.utc_now()
    |> DateTime.shift(second: trunc(seconds))
    |> DateTime.to_iso8601()
  end

  defp expired?(expires_dt) do
    match?(:gt, DateTime.compare(DateTime.utc_now(), expires_dt))
  end

  defp raise_invalid!(challenge_id, reason) do
    id_part = if challenge_id, do: " \"#{challenge_id}\"", else: ""

    raise InvalidChallengeError,
      challenge_id: challenge_id,
      reason: reason,
      message: "Challenge#{id_part} is invalid: #{reason}."
  end

  defp raise_payment_expired!(expires) do
    raise PaymentExpiredError,
      expires: expires,
      message: "Payment expired at #{expires}."
  end
end
