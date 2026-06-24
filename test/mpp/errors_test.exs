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
    {:invalid_payload, 402, "Invalid Payload"},
    {:bad_request, 400, "Bad Request"},
    {:payment_action_required, 402, "Payment Action Required"},
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

    test "returns all 17 problem types" do
      types = Errors.types()

      assert Enum.count(types) == 17
      assert :payment_required in types
      assert :malformed_credential in types
      # Session types
      assert :insufficient_balance in types
      assert :channel_closed in types
      # 3DS flow
      assert :payment_action_required in types
    end
  end
end
