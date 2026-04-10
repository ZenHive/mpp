defmodule MPP.JCSTest do
  use ExUnit.Case, async: true

  alias MPP.JCS

  describe "canonicalize/1 scalars" do
    test "string" do
      assert JCS.canonicalize("hello") == ~S("hello")
    end

    test "string with escaping" do
      assert JCS.canonicalize(~S(he said "hi")) == ~S("he said \"hi\"")
    end

    test "string with backslash" do
      assert JCS.canonicalize("back\\slash") == ~S("back\\slash")
    end

    test "string with control characters" do
      assert JCS.canonicalize("line\nbreak") == ~S("line\nbreak")
    end

    test "integer" do
      assert JCS.canonicalize(42) == "42"
    end

    test "negative integer" do
      assert JCS.canonicalize(-7) == "-7"
    end

    test "zero" do
      assert JCS.canonicalize(0) == "0"
    end

    # Float clause intentionally removed — spec excludes floats, FunctionClauseError
    # is natural Elixir behavior. No test needed for language-level pattern matching.

    test "true" do
      assert JCS.canonicalize(true) == "true"
    end

    test "false" do
      assert JCS.canonicalize(false) == "false"
    end

    test "nil" do
      assert JCS.canonicalize(nil) == "null"
    end
  end

  describe "canonicalize/1 arrays" do
    test "empty list" do
      assert JCS.canonicalize([]) == "[]"
    end

    test "list of scalars" do
      assert JCS.canonicalize([1, "two", true, nil]) == ~S([1,"two",true,null])
    end

    test "nested list" do
      assert JCS.canonicalize([[1, 2], [3]]) == "[[1,2],[3]]"
    end
  end

  describe "canonicalize/1 objects" do
    test "empty map" do
      assert JCS.canonicalize(%{}) == "{}"
    end

    test "single key" do
      assert JCS.canonicalize(%{"a" => 1}) == ~S({"a":1})
    end

    test "keys sorted alphabetically" do
      assert JCS.canonicalize(%{"b" => 1, "a" => 2}) == ~S({"a":2,"b":1})
    end

    test "many keys sorted" do
      input = %{"z" => 26, "m" => 13, "a" => 1, "d" => 4}
      assert JCS.canonicalize(input) == ~S({"a":1,"d":4,"m":13,"z":26})
    end

    test "nested maps sorted at every level" do
      input = %{"b" => %{"d" => 1, "c" => 2}, "a" => 3}
      assert JCS.canonicalize(input) == ~S({"a":3,"b":{"c":2,"d":1}})
    end

    test "mixed value types" do
      input = %{"str" => "val", "num" => 42, "bool" => true, "nil" => nil, "arr" => [1]}
      assert JCS.canonicalize(input) == ~S({"arr":[1],"bool":true,"nil":null,"num":42,"str":"val"})
    end

    test "deeply nested" do
      input = %{"a" => %{"b" => %{"c" => "deep"}}}
      assert JCS.canonicalize(input) == ~S({"a":{"b":{"c":"deep"}}})
    end
  end

  describe "canonicalize/1 MPP charge request cross-validation" do
    test "simple charge request matches expected canonical form" do
      # Matches mppx: Json.canonicalize({amount: "1000", currency: "usd"})
      request = %{"amount" => "1000", "currency" => "usd"}
      assert JCS.canonicalize(request) == ~S({"amount":"1000","currency":"usd"})
    end

    test "charge request with recipient" do
      request = %{"amount" => "1000", "currency" => "usd", "recipient" => "acct_123"}
      assert JCS.canonicalize(request) == ~S({"amount":"1000","currency":"usd","recipient":"acct_123"})
    end

    test "charge request with all optional fields" do
      request = %{
        "amount" => "1000000",
        "currency" => "0x20c0000000000000000000000000000000000001",
        "description" => "API call",
        "methodDetails" => %{"chainId" => 42_431, "networkId" => "tempo-moderato"},
        "recipient" => "0x742d35Cc6634C0532925a3b844Bc9e7595f8fE00"
      }

      expected =
        ~S({"amount":"1000000","currency":"0x20c0000000000000000000000000000000000001",) <>
          ~S("description":"API call","methodDetails":{"chainId":42431,"networkId":"tempo-moderato"},) <>
          ~S("recipient":"0x742d35Cc6634C0532925a3b844Bc9e7595f8fE00"})

      assert JCS.canonicalize(request) == expected
    end

    test "base64url encoding matches round-trip" do
      request = %{"amount" => "1000", "currency" => "usd"}
      canonical = JCS.canonicalize(request)
      encoded = Base.url_encode64(canonical, padding: false)
      {:ok, decoded} = Base.url_decode64(encoded, padding: false)
      assert decoded == canonical
    end
  end
end
