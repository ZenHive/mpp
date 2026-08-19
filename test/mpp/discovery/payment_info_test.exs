defmodule MPP.Discovery.PaymentInfoTest do
  use ExUnit.Case, async: true

  alias MPP.Discovery.PaymentInfo

  describe "parse/1" do
    test "normalizes single-offer shorthand into an offers array" do
      shorthand = %{
        "intent" => "charge",
        "method" => "tempo",
        "amount" => "500",
        "currency" => "usd",
        "description" => "Per request"
      }

      assert {:ok, %{"offers" => [^shorthand]}} = PaymentInfo.parse(shorthand)
    end

    test "preserves valid multi-offer form and dynamic pricing" do
      payment_info = %{
        "offers" => [
          %{"intent" => "charge", "method" => "tempo", "amount" => "0"},
          %{"intent" => "session", "method" => "stripe", "amount" => nil, "currency" => "usd"}
        ]
      }

      assert {:ok, ^payment_info} = PaymentInfo.parse(payment_info)
    end

    test "rejects mixing offers with shorthand fields" do
      assert {:error, :mixed_offer_forms} =
               PaymentInfo.parse(%{
                 "offers" => [%{"intent" => "charge", "method" => "tempo", "amount" => "1"}],
                 "currency" => "usd"
               })
    end

    test "rejects invalid offers containers" do
      assert {:error, :empty_offers} = PaymentInfo.parse(%{"offers" => []})
      assert {:error, :invalid_payment_info} = PaymentInfo.parse(%{"offers" => "invalid"})
      assert {:error, :invalid_payment_info} = PaymentInfo.parse("invalid")
    end

    test "reports the index and reason for an invalid offer" do
      valid = %{"intent" => "charge", "method" => "tempo", "amount" => "1"}

      assert {:error, {:invalid_offer, 1, :not_an_object}} =
               PaymentInfo.parse(%{"offers" => [valid, "invalid"]})

      assert {:error, {:invalid_offer, 0, {:missing_fields, ["amount"]}}} =
               PaymentInfo.parse(%{"intent" => "charge", "method" => "tempo"})
    end

    test "enforces the discovery offer schema" do
      base = %{"intent" => "charge", "method" => "tempo", "amount" => "1"}

      assert_invalid(base, "intent", "subscribe", :invalid_intent)
      assert_invalid(base, "method", nil, {:invalid_string, "method"})
      assert_invalid(base, "amount", "01", :invalid_amount)
      assert_invalid(base, "amount", 1, :invalid_amount)
      assert_invalid(base, "currency", nil, {:invalid_string, "currency"})
      assert_invalid(base, "description", 42, {:invalid_string, "description"})

      assert {:error, {:invalid_offer, 0, {:unsupported_fields, ["recipient"]}}} =
               PaymentInfo.parse(Map.put(base, "recipient", "0xabc"))
    end
  end

  defp assert_invalid(base, field, value, reason) do
    assert {:error, {:invalid_offer, 0, ^reason}} = PaymentInfo.parse(Map.put(base, field, value))
  end
end
