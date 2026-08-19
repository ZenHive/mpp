defmodule MPP.Intents.SubscriptionTest do
  use ExUnit.Case, async: true

  alias MPP.Intents.Subscription

  @request %{
    "amount" => "1000000",
    "currency" => "USD",
    "periodUnit" => "month",
    "periodCount" => "1"
  }

  test "round-trips the shared method-neutral subscription schema" do
    request =
      Map.merge(@request, %{
        "recipient" => "acct_123",
        "subscriptionExpires" => "2027-01-01T00:00:00Z",
        "description" => "Monthly API access",
        "externalId" => "plan_42",
        "methodDetails" => %{"provider" => "stripe"}
      })

    assert {:ok, subscription} = Subscription.from_request(request)
    assert subscription.period_unit == :month
    assert subscription.currency == "USD"
    assert Subscription.to_request(subscription) == request
  end

  test "accepts every shared period unit and omits absent optional fields" do
    for unit <- ~w(day week month) do
      assert {:ok, subscription} = Subscription.from_request(%{@request | "periodUnit" => unit})

      assert Subscription.to_request(subscription) == %{
               "amount" => "1000000",
               "currency" => "USD",
               "periodUnit" => unit,
               "periodCount" => "1"
             }
    end
  end

  test "requires canonical positive decimal amount and periodCount" do
    for amount <- [nil, "", "0", "01", "-1", "1.0", 1] do
      assert {:error, :invalid_amount} = Subscription.from_request(%{@request | "amount" => amount})
    end

    for count <- [nil, "", "0", "01", "-1", "1.0", 1] do
      assert {:error, :invalid_period_count} =
               Subscription.from_request(%{@request | "periodCount" => count})
    end
  end

  test "validates the remaining required and optional fields" do
    assert {:error, :missing_required_fields} = Subscription.from_request(%{})
    assert {:error, :invalid_period_unit} = Subscription.from_request(%{@request | "periodUnit" => "year"})
    assert {:error, :invalid_currency} = Subscription.from_request(%{@request | "currency" => ""})

    assert {:error, :invalid_subscription_expires} =
             Subscription.from_request(Map.put(@request, "subscriptionExpires", "not-a-date"))

    assert {:error, :invalid_subscription_expires} =
             Subscription.from_request(Map.put(@request, "subscriptionExpires", 1))

    assert {:error, :invalid_field_type} = Subscription.from_request(Map.put(@request, "recipient", 1))

    assert {:error, :invalid_method_details} =
             Subscription.from_request(Map.put(@request, "methodDetails", "tempo"))
  end
end
