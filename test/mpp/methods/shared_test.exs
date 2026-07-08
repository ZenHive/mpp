defmodule MPP.Methods.SharedTest do
  use ExUnit.Case, async: true

  alias MPP.Errors
  alias MPP.Methods.Shared

  describe "require_config/3" do
    test "returns the value when the key is present" do
      assert {:ok, "sk_test"} = Shared.require_config(%{"stripe_secret_key" => "sk_test"}, "stripe_secret_key", "Stripe")
    end

    test "names the method label in the error when the key is missing" do
      assert {:error, %Errors{detail: detail} = err} = Shared.require_config(%{}, "rpc_url", "EVM")
      assert err.type =~ "verification-failed"
      assert detail == "EVM method missing required config: rpc_url"
    end

    test "the label is interpolated per caller" do
      assert {:error, %Errors{detail: "Tempo method missing required config: chain_id"}} =
               Shared.require_config(%{}, "chain_id", "Tempo")
    end
  end

  describe "check_receipt_status/1" do
    test "ok when status is 1" do
      assert :ok = Shared.check_receipt_status(%{status: 1})
    end

    test "verification error when the transaction reverted" do
      assert {:error, %Errors{detail: detail}} = Shared.check_receipt_status(%{status: 0})
      assert detail =~ "reverted"
    end
  end

  describe "parse_charge_amount/1" do
    test "parses a plain integer string" do
      assert {:ok, 1000} = Shared.parse_charge_amount("1000")
    end

    test "rejects a non-integer string" do
      assert {:error, %Errors{detail: detail}} = Shared.parse_charge_amount("1.5")
      assert detail =~ "not a valid integer"
    end

    test "rejects trailing garbage after the integer" do
      assert {:error, %Errors{}} = Shared.parse_charge_amount("100abc")
    end
  end
end
