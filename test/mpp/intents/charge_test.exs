defmodule MPP.Intents.ChargeTest do
  use ExUnit.Case, async: true

  alias MPP.Intents.Charge

  describe "new/1" do
    test "creates charge with required fields" do
      assert {:ok, charge} = Charge.new(amount: "1000", currency: "usd")

      assert charge.amount == "1000"
      assert charge.currency == "usd"
      assert charge.recipient == nil
      assert charge.description == nil
      assert charge.external_id == nil
      assert charge.method_details == nil
    end

    # Wire parity: mpp-rs types currency as a plain String and asserts verbatim
    # round-trip (refs/mpp-rs/src/protocol/intents/session.rs:44,169); its doctest
    # at :24 carries a checksummed token address. Normalizing would break an mppx
    # client comparing `challenge.currency === "USD"` and would strip the EIP-55
    # checksum from an on-chain token address.
    test "preserves currency verbatim" do
      assert {:ok, charge} = Charge.new(amount: "500", currency: "USD")
      assert charge.currency == "USD"

      assert {:ok, charge2} = Charge.new(amount: "500", currency: "Eur")
      assert charge2.currency == "Eur"

      checksummed = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
      assert {:ok, charge3} = Charge.new(amount: "500", currency: checksummed)
      assert charge3.currency == checksummed
    end

    test "accepts all optional fields" do
      assert {:ok, charge} =
               Charge.new(
                 amount: "2000",
                 currency: "usd",
                 recipient: "acct_123",
                 description: "API call",
                 external_id: "order-42",
                 method_details: %{"networkId" => "acct_abc"}
               )

      assert charge.recipient == "acct_123"
      assert charge.description == "API call"
      assert charge.external_id == "order-42"
      assert charge.method_details == %{"networkId" => "acct_abc"}
    end

    test "returns error when amount is missing" do
      assert {:error, :amount_required} = Charge.new(currency: "usd")
    end

    test "returns error when amount is empty string" do
      assert {:error, :invalid_amount} = Charge.new(amount: "", currency: "usd")
    end

    test "returns error when amount is not a string" do
      assert {:error, :invalid_amount} = Charge.new(amount: 1000, currency: "usd")
    end

    test "returns error when currency is missing" do
      assert {:error, :currency_required} = Charge.new(amount: "1000")
    end

    test "returns error when currency is empty string" do
      assert {:error, :invalid_currency} = Charge.new(amount: "1000", currency: "")
    end
  end

  describe "to_request/1 and from_request/1" do
    test "roundtrip preserves all fields" do
      assert {:ok, charge} =
               Charge.new(
                 amount: "1500",
                 currency: "usd",
                 recipient: "acct_xyz",
                 external_id: "ext-1",
                 method_details: %{"networkId" => "net_123"}
               )

      request = Charge.to_request(charge)
      assert {:ok, restored} = Charge.from_request(request)

      assert restored.amount == charge.amount
      assert restored.currency == charge.currency
      assert restored.recipient == charge.recipient
      assert restored.external_id == charge.external_id
      assert restored.method_details == charge.method_details
    end

    test "to_request uses camelCase keys" do
      assert {:ok, charge} =
               Charge.new(
                 amount: "100",
                 currency: "usd",
                 external_id: "abc",
                 method_details: %{"foo" => "bar"}
               )

      request = Charge.to_request(charge)

      assert Map.has_key?(request, "externalId")
      assert Map.has_key?(request, "methodDetails")
      refute Map.has_key?(request, "external_id")
      refute Map.has_key?(request, "method_details")
    end

    test "to_request omits nil optional fields" do
      assert {:ok, charge} = Charge.new(amount: "100", currency: "usd")
      request = Charge.to_request(charge)

      assert request == %{"amount" => "100", "currency" => "usd"}
    end

    test "from_request returns error for missing required fields" do
      assert {:error, :missing_required_fields} = Charge.from_request(%{"amount" => "100"})
      assert {:error, :missing_required_fields} = Charge.from_request(%{})
    end
  end
end
