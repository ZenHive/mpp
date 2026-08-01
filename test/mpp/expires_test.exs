defmodule MPP.ExpiresTest do
  use ExUnit.Case, async: true

  alias MPP.Expires
  alias MPP.Expires.InvalidChallengeError
  alias MPP.Expires.PaymentExpiredError

  describe "duration helpers" do
    test "seconds/1 returns valid ISO 8601" do
      assert {:ok, _dt, _offset} = DateTime.from_iso8601(Expires.seconds(30))
    end

    test "minutes/5 returns ~5 minutes from now" do
      before = DateTime.utc_now()
      expires = Expires.minutes(5)
      after_ = DateTime.utc_now()

      assert {:ok, expires_dt, _} = DateTime.from_iso8601(expires)

      lower = DateTime.shift(before, second: 5 * 60 - 1)
      upper = DateTime.shift(after_, second: 5 * 60 + 1)

      assert DateTime.compare(expires_dt, lower) in [:gt, :eq]
      assert DateTime.compare(expires_dt, upper) in [:lt, :eq]
    end

    test "hours/1 returns valid ISO 8601" do
      assert {:ok, _dt, _offset} = DateTime.from_iso8601(Expires.hours(2))
    end

    test "days/1 returns valid ISO 8601" do
      assert {:ok, _dt, _offset} = DateTime.from_iso8601(Expires.days(1))
    end

    test "weeks/1 returns valid ISO 8601" do
      assert {:ok, _dt, _offset} = DateTime.from_iso8601(Expires.weeks(1))
    end

    test "months/1 returns ~30 days from now (mppx-compatible)" do
      before = DateTime.utc_now()
      expires = Expires.months(1)
      after_ = DateTime.utc_now()

      assert {:ok, expires_dt, _} = DateTime.from_iso8601(expires)

      lower = DateTime.shift(before, second: 30 * 86_400 - 1)
      upper = DateTime.shift(after_, second: 30 * 86_400 + 1)

      assert DateTime.compare(expires_dt, lower) in [:gt, :eq]
      assert DateTime.compare(expires_dt, upper) in [:lt, :eq]
    end

    test "years/1 returns valid ISO 8601" do
      assert {:ok, _dt, _offset} = DateTime.from_iso8601(Expires.years(1))
    end
  end

  describe "assert!/1" do
    test "returns :ok for a future timestamp" do
      assert :ok = Expires.assert!(Expires.minutes(5))
    end

    test "accepts timezone-aware timestamps with explicit offset" do
      future =
        DateTime.utc_now()
        |> DateTime.shift(minute: 5)
        |> Calendar.strftime("%Y-%m-%dT%H:%M:%S+00:00")

      assert :ok = Expires.assert!(future)
    end

    test "raises on nil" do
      assert_raise InvalidChallengeError, ~r/missing required expires field/, fn ->
        Expires.assert!(nil)
      end
    end

    test "raises on malformed timestamps" do
      for malformed <- ["", "not-a-date", "2025-13-40T00:00:00Z", "2025-01-01", 123] do
        assert_raise InvalidChallengeError, ~r/malformed expires timestamp/, fn ->
          Expires.assert!(malformed)
        end
      end
    end

    test "raises on expired timestamps" do
      expired = DateTime.to_iso8601(DateTime.shift(DateTime.utc_now(), minute: -1))

      assert_raise PaymentExpiredError, ~r/Payment expired at #{expired}/, fn ->
        Expires.assert!(expired)
      end
    end
  end

  describe "assert!/2" do
    test "includes challenge_id in invalid-challenge errors" do
      assert_raise InvalidChallengeError, ~r/Challenge "ch_test123" is invalid/, fn ->
        Expires.assert!(nil, "ch_test123")
      end
    end

    test "includes challenge_id in malformed errors" do
      assert_raise InvalidChallengeError, ~r/Challenge "ch_bad" is invalid: malformed expires timestamp/, fn ->
        Expires.assert!("bad-timestamp", "ch_bad")
      end
    end

    test "returns :ok for valid future timestamp with challenge_id" do
      assert :ok = Expires.assert!(Expires.minutes(1), "ch_ok")
    end
  end
end
