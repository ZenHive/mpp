defmodule MPP.HexTest do
  use ExUnit.Case, async: true

  alias MPP.Hex

  describe "strip_0x/1" do
    test "drops a leading 0x prefix" do
      assert Hex.strip_0x("0xabc123") == "abc123"
    end

    test "returns the string unchanged when there is no prefix" do
      assert Hex.strip_0x("abc123") == "abc123"
    end

    test "strips only the first 0x, leaving the rest intact" do
      assert Hex.strip_0x("0x0xff") == "0xff"
    end

    test "returns an empty string for a bare 0x" do
      assert Hex.strip_0x("0x") == ""
    end

    test "leaves an empty string unchanged" do
      assert Hex.strip_0x("") == ""
    end
  end

  describe "hex_string?/1" do
    test "true for bare lowercase hex" do
      assert Hex.hex_string?("deadbeef")
    end

    test "true for mixed-case hex" do
      assert Hex.hex_string?("DeadBeef00FF")
    end

    test "false for a 0x-prefixed string (prefix must be stripped first)" do
      refute Hex.hex_string?("0xabc")
    end

    test "false for an empty string" do
      refute Hex.hex_string?("")
    end

    test "false when non-hex characters are present" do
      refute Hex.hex_string?("abcxyz")
      refute Hex.hex_string?("12 34")
    end
  end
end
