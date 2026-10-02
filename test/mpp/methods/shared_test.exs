defmodule MPP.Methods.SharedTest do
  use ExUnit.Case, async: true

  alias MPP.Errors
  alias MPP.Methods.Shared

  describe "extract_hash/1" do
    test "canonicalizes mixed-case hashes with or without the prefix" do
      digits = String.duplicate("aB", 32)
      expected = "0x" <> String.downcase(digits)

      for hash <- [digits, "0x" <> digits] do
        assert {:ok, ^expected} = Shared.extract_hash(%{"hash" => hash})
      end
    end

    test "rejects malformed hashes and missing values with distinct errors" do
      for hash <- ["", String.duplicate("a", 63), String.duplicate("a", 65), String.duplicate("g", 64)] do
        assert {:error, %Errors{detail: "Invalid transaction hash format"}} =
                 Shared.extract_hash(%{"hash" => hash})
      end

      for payload <- [%{}, %{"hash" => nil}, %{"hash" => 123}] do
        assert {:error, %Errors{detail: "Missing or invalid 'hash' field in credential payload"}} =
                 Shared.extract_hash(payload)
      end
    end
  end

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
      assert {:ok, 0} = Shared.parse_charge_amount("0")
      assert {:ok, 7} = Shared.parse_charge_amount("007")
    end

    test "rejects a non-integer string" do
      assert {:error, %Errors{detail: detail}} = Shared.parse_charge_amount("1.5")
      assert detail =~ "not a valid integer"
    end

    test "rejects trailing garbage after the integer" do
      assert {:error, %Errors{}} = Shared.parse_charge_amount("100abc")
    end

    test "rejects signs, exponents, and surrounding whitespace (mpp-rs #485)" do
      for amount <- ["+100", "-5", "1e3", " 100", "100 ", "100\n", "0x10", "1_000", ""] do
        assert {:error, %Errors{}} = Shared.parse_charge_amount(amount), "accepted #{inspect(amount)}"
      end
    end
  end

  describe "valid_rpc_url?/1" do
    test "accepts https without userinfo" do
      assert Shared.valid_rpc_url?("https://soroban-testnet.stellar.org")
    end

    test "rejects https with userinfo" do
      refute Shared.valid_rpc_url?("https://user:pass@rpc.example")
    end

    test "accepts loopback http and rejects other http" do
      assert Shared.valid_rpc_url?("http://127.0.0.1:8000")
      refute Shared.valid_rpc_url?("http://rpc.example")
    end
  end

  describe "poll_timeout_ms/1" do
    test "uses the configured timeout or the default" do
      assert Shared.poll_timeout_ms(%{"poll_timeout_ms" => 5_000}) == 5_000
      assert Shared.poll_timeout_ms(%{}) == 60_000
    end
  end

  describe "internal_payment_error/0" do
    test "returns the fixed 500 problem with no internals" do
      error = Shared.internal_payment_error()
      assert error.status == 500
      assert error.type == "https://paymentauth.org/problems/internal-payment-error"
      assert error.detail == "An internal payment error occurred."
    end
  end
end
