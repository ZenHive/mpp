defmodule MPP.Demo.MethodTest do
  use ExUnit.Case, async: true

  alias MPP.Demo.Method, as: DemoMethod
  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.Receipt

  {:ok, charge} = Charge.new(amount: "100", currency: "usd")
  @charge charge

  describe "method_name/0" do
    test "returns \"demo\"" do
      assert DemoMethod.method_name() == "demo"
    end
  end

  describe "verify/2" do
    test "accepts demo-token and returns receipt" do
      payload = %{"token" => "demo-token"}

      assert {:ok, %Receipt{} = receipt} = DemoMethod.verify(payload, @charge)
      assert receipt.method == "demo"
      assert receipt.status == "success"
      assert is_binary(receipt.reference)
      assert String.starts_with?(receipt.reference, "demo_")
      assert is_binary(receipt.timestamp)
    end

    test "echoes externalId in receipt" do
      payload = %{"token" => "demo-token", "externalId" => "req_123"}

      assert {:ok, %Receipt{external_id: "req_123"}} = DemoMethod.verify(payload, @charge)
    end

    test "rejects invalid token" do
      payload = %{"token" => "wrong-token"}

      assert {:error, %Errors{} = error} = DemoMethod.verify(payload, @charge)
      assert error.status == 402
      assert error.detail =~ "Invalid demo token"
    end

    test "rejects missing token field" do
      assert {:error, %Errors{} = error} = DemoMethod.verify(%{}, @charge)
      assert error.status == 402
      assert error.detail =~ "Missing 'token' field"
    end

    test "generates unique references" do
      payload = %{"token" => "demo-token"}

      {:ok, receipt1} = DemoMethod.verify(payload, @charge)
      {:ok, receipt2} = DemoMethod.verify(payload, @charge)

      assert receipt1.reference != receipt2.reference
    end
  end

  describe "challenge_method_details/1" do
    test "returns accepted tokens" do
      details = DemoMethod.challenge_method_details(@charge)

      assert details == %{"acceptedTokens" => ["demo-token"]}
    end
  end
end
