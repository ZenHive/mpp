defmodule MPP.Session.MethodTest do
  use ExUnit.Case, async: true

  alias MPP.Errors
  alias MPP.Intents.Charge

  defmodule DemoSessionMethod do
    @moduledoc false
    use MPP.Session.Method

    @impl MPP.Method
    def method_name, do: "mocksession"
  end

  test "declares the transaction credential type" do
    assert DemoSessionMethod.credential_types() == ["transaction"]
  end

  test "rejects a charge intent" do
    {:ok, charge} = Charge.new(amount: "1", currency: "usd")

    assert {:error, %Errors{} = error} = DemoSessionMethod.verify(%{"action" => "open"}, charge)
    assert String.contains?(error.type, "invalid-payload")
    assert error.detail =~ "session intent"
  end
end
