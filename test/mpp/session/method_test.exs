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

  test "requires the complete voucher verification config at init" do
    assert :ok =
             DemoSessionMethod.validate_config!(%{
               "escrow_contract" => "0x4d50500000000000000000000000000000000000",
               "chain_id" => 42_431,
               "authorized_signer" => "0x1111111111111111111111111111111111111111"
             })

    for missing <- ~w(escrow_contract chain_id authorized_signer) do
      config =
        Map.delete(
          %{
            "escrow_contract" => "0x4d50500000000000000000000000000000000000",
            "chain_id" => 42_431,
            "authorized_signer" => "0x1111111111111111111111111111111111111111"
          },
          missing
        )

      assert_raise ArgumentError, ~r/#{missing}/, fn ->
        DemoSessionMethod.validate_config!(config)
      end
    end
  end

  test "rejects a charge intent" do
    {:ok, charge} = Charge.new(amount: "1", currency: "usd")

    assert {:error, %Errors{} = error} = DemoSessionMethod.verify(%{"action" => "open"}, charge)
    assert String.contains?(error.type, "invalid-payload")
    assert error.detail =~ "session intent"
  end
end
