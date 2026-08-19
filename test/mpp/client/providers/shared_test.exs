defmodule MPP.Client.Providers.SharedTest do
  use ExUnit.Case, async: true

  alias MPP.Challenge
  alias MPP.Client.Providers.Shared
  alias MPP.Expires

  @request Base.url_encode64(~s({"amount":"100","currency":"usd"}), padding: false)

  test "parses a valid unexpired charge" do
    assert {:ok, charge} = Shared.parse_charge(challenge(), "stripe")
    assert charge.amount == "100"
    assert charge.currency == "usd"
  end

  test "rejects unsupported, expired, and malformed challenges" do
    assert {:error, :unsupported_challenge} = Shared.parse_charge(challenge(method: "tempo"), "stripe")

    assert {:error, :payment_expired} =
             Shared.parse_charge(challenge(expires: Expires.seconds(-1)), "stripe")

    assert {:error, :invalid_expires} =
             Shared.parse_charge(challenge(expires: "not-a-timestamp"), "stripe")
  end

  test "derives an expiration from the challenge or a default TTL" do
    now = System.os_time(:second)
    assert {:ok, default_expiration} = Shared.expiration_unix(challenge(), 60)
    assert default_expiration in (now + 60)..(now + 61)

    expires = Expires.minutes(5)
    assert {:ok, datetime, _offset} = DateTime.from_iso8601(expires)
    expected_expiration = DateTime.to_unix(datetime)
    assert {:ok, ^expected_expiration} = Shared.expiration_unix(challenge(expires: expires), 60)

    assert {:error, :invalid_expires} = Shared.expiration_unix(challenge(expires: "invalid"), 60)
  end

  defp challenge(opts \\ []) do
    %Challenge{
      id: "shared-provider-challenge",
      realm: "payments.example.com",
      method: Keyword.get(opts, :method, "stripe"),
      intent: "charge",
      request: @request,
      expires: Keyword.get(opts, :expires)
    }
  end
end
