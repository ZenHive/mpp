defmodule MPP.MethodTest do
  use ExUnit.Case, async: true

  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.Intents.Session
  alias MPP.Receipt

  defmodule MockMethod do
    @moduledoc false
    use MPP.Method

    @impl MPP.Method
    def method_name, do: "mock"

    @impl MPP.Method
    def verify(%{"proof" => "valid"}, %{amount: amount}) do
      {:ok, Receipt.new(method: method_name(), reference: "ref_#{amount}")}
    end

    def verify(%{"proof" => "invalid"}, _intent) do
      {:error, Errors.new(:verification_failed, "Invalid proof")}
    end

    def verify(_payload, _intent) do
      {:error, Errors.new(:invalid_payload, "Missing proof field")}
    end
  end

  defmodule MockMethodWithDetails do
    @moduledoc false
    use MPP.Method

    @impl MPP.Method
    def method_name, do: "mockwithdetails"

    @impl MPP.Method
    def verify(%{"proof" => _proof}, charge) do
      {:ok, Receipt.new(method: method_name(), reference: "ref_#{charge.amount}")}
    end

    @impl MPP.Method
    def challenge_method_details(_charge) do
      %{"networkId" => "net_test123", "paymentMethodTypes" => ["card"]}
    end
  end

  setup do
    {:ok, charge} = Charge.new(amount: "1000", currency: "usd", recipient: "acct_test")

    {:ok, session} =
      Session.new(amount: "1000", currency: "usd", unit_type: "second", recipient: "acct_test")

    {:ok, charge: charge, session: session}
  end

  describe "method_name/0" do
    test "returns a lowercase string identifier" do
      assert MockMethod.method_name() == "mock"
      assert MockMethodWithDetails.method_name() == "mockwithdetails"
    end
  end

  describe "verify/2" do
    test "returns {:ok, Receipt.t()} on successful verification", %{charge: charge} do
      assert {:ok, %Receipt{} = receipt} = MockMethod.verify(%{"proof" => "valid"}, charge)
      assert receipt.method == "mock"
      assert receipt.reference == "ref_1000"
      assert receipt.status == "success"
      assert receipt.timestamp
    end

    test "accepts session intent alongside charge", %{session: session} do
      assert {:ok, %Receipt{} = receipt} = MockMethod.verify(%{"proof" => "valid"}, session)
      assert receipt.method == "mock"
      assert receipt.reference == "ref_1000"
    end

    test "returns {:error, Errors.t()} on failed verification", %{charge: charge} do
      assert {:error, %Errors{} = error} = MockMethod.verify(%{"proof" => "invalid"}, charge)
      assert error.status == 402
      assert error.type =~ "verification-failed"
      assert error.detail == "Invalid proof"
    end

    test "returns {:error, Errors.t()} for missing payload fields", %{charge: charge} do
      assert {:error, %Errors{} = error} = MockMethod.verify(%{}, charge)
      assert error.type =~ "invalid-payload"
      assert error.detail == "Missing proof field"
    end
  end

  describe "challenge_method_details/1" do
    test "default implementation returns nil", %{charge: charge, session: session} do
      assert MockMethod.challenge_method_details(charge) == nil
      assert MockMethod.challenge_method_details(session) == nil
    end

    test "can be overridden to return method-specific fields", %{charge: charge} do
      details = MockMethodWithDetails.challenge_method_details(charge)
      assert details == %{"networkId" => "net_test123", "paymentMethodTypes" => ["card"]}
    end
  end

  describe "MPP.Method.intent/0 type" do
    test "Charge and Session are both valid intent structs" do
      assert %Charge{} = struct!(Charge, amount: "1", currency: "usd")
      assert %Session{} = struct!(Session, amount: "1", currency: "usd")
    end
  end
end
