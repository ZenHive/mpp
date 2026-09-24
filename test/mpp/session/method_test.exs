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

  test "requires the complete voucher verification and funding config at init" do
    config = %{
      "escrow_contract" => "0x4d50500000000000000000000000000000000000",
      "chain_id" => 42_431,
      "authorized_signer" => "0x1111111111111111111111111111111111111111",
      "verify_open" => fn _payload, _opts -> {:ok, %{deposit: 1_000}} end
    }

    assert :ok = DemoSessionMethod.validate_config!(config)

    for missing <- ~w(escrow_contract chain_id authorized_signer verify_open) do
      assert_raise ArgumentError, ~r/#{missing}/, fn ->
        DemoSessionMethod.validate_config!(Map.delete(config, missing))
      end
    end

    assert_raise ArgumentError, ~r/verify_open/, fn ->
      DemoSessionMethod.validate_config!(Map.put(config, "verify_open", 1_000))
    end
  end

  test "rejects a charge intent" do
    {:ok, charge} = Charge.new(amount: "1", currency: "usd")

    assert {:error, %Errors{} = error} = DemoSessionMethod.verify(%{"action" => "open"}, charge)
    assert String.contains?(error.type, "invalid-payload")
    assert error.detail =~ "session intent"
  end
end
