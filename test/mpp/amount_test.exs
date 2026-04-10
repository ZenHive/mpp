defmodule MPP.AmountTest do
  use ExUnit.Case, async: true

  alias MPP.Amount
  alias MPP.Intents.Charge

  describe "parse_units/2" do
    test "whole numbers" do
      assert {:ok, "1000000"} = Amount.parse_units("1", 6)
      assert {:ok, "10000000"} = Amount.parse_units("10", 6)
      assert {:ok, "100000000"} = Amount.parse_units("100", 6)
    end

    test "decimal amounts" do
      assert {:ok, "100000"} = Amount.parse_units("0.10", 6)
      assert {:ok, "10000"} = Amount.parse_units("0.01", 6)
      assert {:ok, "1500000"} = Amount.parse_units("1.50", 6)
      assert {:ok, "1000"} = Amount.parse_units("0.001", 6)
    end

    test "max precision" do
      assert {:ok, "1000001"} = Amount.parse_units("1.000001", 6)
      assert {:ok, "1"} = Amount.parse_units("0.000001", 6)
    end

    test "zero returns zero" do
      assert {:ok, "0"} = Amount.parse_units("0", 6)
      assert {:ok, "0"} = Amount.parse_units("0.000000", 6)
    end

    test "zero decimals" do
      assert {:ok, "100"} = Amount.parse_units("100", 0)
    end

    test "18 decimals (ETH-scale)" do
      assert {:ok, "1000000000000000000"} = Amount.parse_units("1", 18)
      assert {:ok, "500000000000000000"} = Amount.parse_units("0.5", 18)
      assert {:ok, "1"} = Amount.parse_units("0.000000000000000001", 18)
      assert {:ok, "1000000000000000"} = Amount.parse_units("0.001", 18)
    end

    test "trailing dot treated as whole number" do
      assert {:ok, "1000000"} = Amount.parse_units("1.", 6)
    end

    test "leading dot" do
      assert {:ok, "500000"} = Amount.parse_units(".5", 6)
      assert {:ok, "123456"} = Amount.parse_units(".123456", 6)
      assert {:ok, "1"} = Amount.parse_units(".000001", 6)
    end

    test "leading zeros in integer part" do
      assert {:ok, "1500000"} = Amount.parse_units("01.50", 6)
    end

    test "whitespace trimmed" do
      assert {:ok, "1500000"} = Amount.parse_units("  1.50  ", 6)
    end

    test "errors on too many decimal places" do
      assert {:error, :too_many_decimals} = Amount.parse_units("1.1234567", 6)
      assert {:error, :too_many_decimals} = Amount.parse_units("0.0000001", 6)
    end

    test "errors on empty string" do
      assert {:error, :empty} = Amount.parse_units("", 6)
    end

    test "errors on negative" do
      assert {:error, :negative} = Amount.parse_units("-1", 6)
    end

    test "errors on invalid format" do
      assert {:error, {:invalid_format, _}} = Amount.parse_units("abc", 6)
      assert {:error, {:invalid_format, _}} = Amount.parse_units("1.2.3", 6)
      assert {:error, {:invalid_format, _}} = Amount.parse_units("$1.00", 6)
    end

    test "errors on non-string amount" do
      assert {:error, :invalid_input} = Amount.parse_units(123, 6)
      assert {:error, :invalid_input} = Amount.parse_units(nil, 6)
    end

    test "errors on invalid decimals" do
      assert {:error, :invalid_input} = Amount.parse_units("1", -1)
      assert {:error, :invalid_input} = Amount.parse_units("1", "6")
    end
  end

  describe "with_base_units/2" do
    test "transforms charge amount to base units" do
      {:ok, charge} = Charge.new(amount: "1.50", currency: "usd")
      assert {:ok, %Charge{amount: "1500000"}} = Amount.with_base_units(charge, 6)
    end

    test "works with any map containing :amount" do
      # Simulates a Session or other intent struct
      intent = %{amount: "1.50", currency: "usd", suggested_deposit: "0.50", decimals: 6}
      assert {:ok, %{amount: "1500000"} = result} = Amount.with_base_units(intent, 6)
      assert result.currency == "usd"
      assert result.suggested_deposit == "0.50"
    end

    test "preserves other charge fields" do
      {:ok, charge} = Charge.new(amount: "0.10", currency: "usd", recipient: "0xabc")
      {:ok, result} = Amount.with_base_units(charge, 6)
      assert result.amount == "100000"
      assert result.currency == "usd"
      assert result.recipient == "0xabc"
    end

    test "propagates parse errors" do
      {:ok, charge} = Charge.new(amount: "abc", currency: "usd")
      assert {:error, {:invalid_format, _}} = Amount.with_base_units(charge, 6)
    end
  end

  describe "parse_dollar_amount/2" do
    test "parses dollar symbol prefix" do
      assert {:ok, {"150", "usd", 2}} = Amount.parse_dollar_amount("$1.50", 2)
      assert {:ok, {"10", "usd", 2}} = Amount.parse_dollar_amount("$0.10", 2)
      assert {:ok, {"100", "usd", 2}} = Amount.parse_dollar_amount("$1.00", 2)
    end

    test "parses euro symbol prefix" do
      assert {:ok, {"150", "eur", 2}} = Amount.parse_dollar_amount("€1.50", 2)
    end

    test "parses pound symbol prefix" do
      assert {:ok, {"250", "gbp", 2}} = Amount.parse_dollar_amount("£2.50", 2)
    end

    test "parses yen symbol prefix with caller-supplied decimals" do
      assert {:ok, {"100", "jpy", 0}} = Amount.parse_dollar_amount("¥100", 0)
    end

    test "parses suffix currency code" do
      assert {:ok, {"150", "usd", 2}} = Amount.parse_dollar_amount("1.50 USD", 2)
      assert {:ok, {"150", "eur", 2}} = Amount.parse_dollar_amount("1.50 EUR", 2)
    end

    test "currency code is lowercased" do
      assert {:ok, {_, "usd", _}} = Amount.parse_dollar_amount("1.50 USD", 2)
      assert {:ok, {_, "gbp", _}} = Amount.parse_dollar_amount("1.50 GBP", 2)
    end

    test "decimals are caller-supplied, not inferred from currency" do
      # Same currency, different decimals — proves no inference
      assert {:ok, {"1500000", "usd", 6}} = Amount.parse_dollar_amount("$1.50", 6)
      assert {:ok, {"150", "usd", 2}} = Amount.parse_dollar_amount("$1.50", 2)
      assert {:ok, {"1", "usd", 0}} = Amount.parse_dollar_amount("$1", 0)
    end

    test "caller controls decimals for any currency" do
      assert {:ok, {"1500", "kwd", 3}} = Amount.parse_dollar_amount("1.500 KWD", 3)
      assert {:ok, {"100", "krw", 0}} = Amount.parse_dollar_amount("100 KRW", 0)
      assert {:ok, {"100", "huf", 2}} = Amount.parse_dollar_amount("1.00 HUF", 2)
    end

    test "allows zero amount" do
      # Zero-amount charges are valid for identity/proof flows (matches mpp-rs)
      assert {:ok, {"0", "usd", 2}} = Amount.parse_dollar_amount("$0.00", 2)
    end

    test "rejects empty input" do
      assert {:error, :empty} = Amount.parse_dollar_amount("", 2)
    end

    test "rejects bare number without currency" do
      assert {:error, {:invalid_format, _}} = Amount.parse_dollar_amount("1.50", 2)
    end

    test "rejects multi-token suffix" do
      assert {:error, {:invalid_format, _}} = Amount.parse_dollar_amount("1.50 USD EUR", 2)
    end

    test "rejects fractional amounts when decimals is 0" do
      assert {:error, :too_many_decimals} = Amount.parse_dollar_amount("100.50 KRW", 0)
      assert {:error, :too_many_decimals} = Amount.parse_dollar_amount("¥100.1", 0)
    end

    test "rejects double-symbol prefix" do
      assert {:error, {:invalid_format, _}} = Amount.parse_dollar_amount("$$1.50", 2)
      assert {:error, {:invalid_format, _}} = Amount.parse_dollar_amount("€€1.50", 2)
    end

    test "rejects non-string input" do
      assert {:error, :invalid_input} = Amount.parse_dollar_amount(123, 2)
    end

    test "rejects invalid decimals" do
      assert {:error, :invalid_input} = Amount.parse_dollar_amount("$1.50", -1)
      assert {:error, :invalid_input} = Amount.parse_dollar_amount("$1.50", "2")
    end
  end
end
