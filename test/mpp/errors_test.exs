defmodule MPP.ErrorsTest do
  use ExUnit.Case, async: true

  alias MPP.Errors

  @all_types [
    # Core / charge
    {:payment_required, 402, "Payment Required"},
    {:payment_insufficient, 402, "Payment Insufficient"},
    {:payment_expired, 402, "Payment Expired"},
    {:verification_failed, 402, "Verification Failed"},
    {:method_unsupported, 400, "Method Unsupported"},
    {:malformed_credential, 402, "Malformed Credential"},
    {:invalid_challenge, 402, "Invalid Challenge"},
    {:credential_mismatch, 402, "Invalid Challenge"},
    {:invalid_payload, 402, "Invalid Payload"},
    {:internal_payment_error, 500, "Internal Payment Error"},
    {:bad_request, 400, "Bad Request"},
    {:payment_action_required, 402, "Payment Action Required"},
    {:settlement_failed, 402, "Settlement Failed"},
    {:settlement_unavailable, 503, "Settlement Backend Unavailable"},
    {:settlement_timeout, 504, "Settlement Timeout"},
    # Session
    {:insufficient_balance, 402, "Insufficient Balance"},
    {:invalid_signature, 402, "Invalid Signature"},
    {:signer_mismatch, 402, "Signer Mismatch"},
    {:amount_exceeds_deposit, 402, "Amount Exceeds Deposit"},
    {:delta_too_small, 402, "Delta Too Small"},
    {:channel_not_found, 410, "Channel Not Found"},
    {:channel_closed, 410, "Channel Closed"}
  ]

  describe "new/2" do
    for {type, expected_status, expected_title} <- @all_types do
      test "creates #{type} error with correct status and title" do
        error = Errors.new(unquote(type), "test detail")

        assert error.status == unquote(expected_status)
        assert error.title == unquote(expected_title)
        assert error.detail == "test detail"
        assert String.starts_with?(error.type, "https://paymentauth.org/problems/")
      end
    end

    test "raises on unknown type" do
      assert_raise ArgumentError, ~r/unknown problem type/, fn ->
        Errors.new(:nonexistent, "detail")
      end
    end

    test "uses the ZenHive-owned sponsor-capacity URI" do
      error = Errors.new(:sponsor_capacity_exhausted, "Sponsor capacity is temporarily unavailable")

      assert error.type == "https://zenhive.github.io/mpp/problems/sponsor-capacity-exhausted"
      assert error.status == 402
      assert error.title == "Sponsor Capacity Exhausted"
    end

    test "internal_payment_error uses the mppx problem URI and HTTP 500" do
      error = Errors.new(:internal_payment_error, "Payment processor failure")

      assert error.type == "https://paymentauth.org/problems/internal-payment-error"
      assert error.status == 500
      assert error.title == "Internal Payment Error"
    end
  end

  describe "client_detail/1" do
    test "an internal payment error renders the fixed detail and logs the original" do
      error = Errors.new(:internal_payment_error, "private-db-marker")

      {map, log} = ExUnit.CaptureLog.with_log(fn -> Errors.to_map(error) end)
      assert map["detail"] == "An internal payment error occurred."
      refute Errors.to_json(error) =~ "private-db-marker"
      assert log =~ "private-db-marker"
      assert error.detail == "private-db-marker"
    end

    test "the fixed internal detail is rendered without a log line" do
      error = Errors.new(:internal_payment_error, "An internal payment error occurred.")

      assert {"An internal payment error occurred.", ""} =
               ExUnit.CaptureLog.with_log(fn -> Errors.client_detail(error) end)
    end

    test "public problem types keep their detail" do
      for type <- [:verification_failed, :invalid_payload, :settlement_unavailable, :channel_closed] do
        assert Errors.client_detail(Errors.new(type, "public detail")) == "public detail"
      end
    end
  end

  describe "put_retry_after/2" do
    test "attaches a positive delta without changing the problem body" do
      error =
        :sponsor_capacity_exhausted
        |> Errors.new("Sponsor capacity is temporarily unavailable")
        |> Errors.put_retry_after(17)

      assert error.retry_after == 17
      refute Map.has_key?(Errors.to_map(error), "retry_after")
      assert Errors.put_retry_after(error, 0).retry_after == 1
    end
  end

  describe "put_funding_url/2" do
    @funding_url "https://wallet.tempo.xyz/agent?action=fund&intent=mach&chainId=4217" <>
                   "&address=0x70997970C51812dc3A010C7d01b50e0d17dc79C8&amount=0.75"

    test "serializes the link as the fundingUrl member and appends it to the detail" do
      for type <- [:verification_failed, :insufficient_balance] do
        error = type |> Errors.new("insufficient MACH balance.") |> Errors.put_funding_url(@funding_url)

        assert error.funding_url == @funding_url
        assert error.detail == "insufficient MACH balance. Add funds at #{@funding_url}"

        map = Errors.to_map(error)
        assert map["fundingUrl"] == @funding_url
        assert map["detail"] == error.detail
        assert Jason.decode!(Errors.to_json(error))["fundingUrl"] == @funding_url
      end
    end

    test "nil leaves the error unchanged" do
      error = Errors.new(:insufficient_balance, "insufficient channel balance")

      assert Errors.put_funding_url(error, nil) == error
      refute Map.has_key?(Errors.to_map(error), "fundingUrl")
    end

    test "an error is never given the member from its detail text" do
      error = Errors.new(:verification_failed, "Add funds at #{@funding_url}")

      assert error.funding_url == nil
      refute Map.has_key?(Errors.to_map(error), "fundingUrl")
    end

    test "rejects a link the funding helper does not write" do
      error = Errors.new(:insufficient_balance, "insufficient channel balance")

      for url <- ["https://evil.example/fund", @funding_url <> "&next=https://evil.example", 42] do
        assert_raise ArgumentError, ~r/accepts only a MACH funding link/, fn ->
          Errors.put_funding_url(error, url)
        end
      end
    end

    test "rejects every problem that is not a balance shortfall" do
      for type <- [:payment_required, :invalid_payload, :internal_payment_error, :channel_closed] do
        assert_raise ArgumentError, ~r/does not apply to/, fn ->
          type |> Errors.new("detail") |> Errors.put_funding_url(@funding_url)
        end
      end
    end
  end

  describe "to_map/1" do
    test "returns RFC 9457 map with string keys" do
      error = Errors.new(:payment_required, "No credential provided")
      map = Errors.to_map(error)

      assert map == %{
               "type" => "https://paymentauth.org/problems/payment-required",
               "title" => "Payment Required",
               "status" => 402,
               "detail" => "No credential provided"
             }
    end
  end

  describe "to_json/1" do
    test "returns valid JSON string" do
      error = Errors.new(:verification_failed, "Invalid SPT")
      json = Errors.to_json(error)

      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["type"] == "https://paymentauth.org/problems/verification-failed"
      assert decoded["title"] == "Verification Failed"
      assert decoded["status"] == 402
      assert decoded["detail"] == "Invalid SPT"
    end
  end

  describe "types/0" do
    test "session errors use session/ URI prefix" do
      session_types = [
        :insufficient_balance,
        :invalid_signature,
        :signer_mismatch,
        :amount_exceeds_deposit,
        :delta_too_small,
        :channel_not_found,
        :channel_closed
      ]

      for type <- session_types do
        error = Errors.new(type, "test")
        assert String.contains?(error.type, "/session/"), "#{type} should have session/ in URI"
      end
    end

    test "channel errors use 410 status (Gone)" do
      for type <- [:channel_not_found, :channel_closed] do
        error = Errors.new(type, "test")
        assert error.status == 410, "#{type} should be 410, got #{error.status}"
      end
    end

    test "returns all 23 problem types" do
      types = Errors.types()

      assert Enum.count(types) == 23
      assert :payment_required in types
      assert :malformed_credential in types
      assert :internal_payment_error in types
      # Session types
      assert :insufficient_balance in types
      assert :channel_closed in types
      # 3DS flow
      assert :payment_action_required in types
      assert :sponsor_capacity_exhausted in types
      assert :settlement_failed in types
      assert :settlement_unavailable in types
      assert :settlement_timeout in types
    end
  end
end
