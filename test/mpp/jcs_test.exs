defmodule MPP.JCSTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MPP.JCS

  @property_runs 50

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

    property "sorts generated ASCII keys at every object boundary" do
      check all(
              fields <-
                StreamData.uniq_list_of(
                  StreamData.tuple({ascii_key(), scalar()}),
                  min_length: 1,
                  max_length: 12,
                  uniq_fun: &elem(&1, 0)
                ),
              max_runs: @property_runs
            ) do
        object = Map.new(fields)

        expected =
          fields
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.map_join(",", fn {key, value} -> Jason.encode!(key) <> ":" <> JCS.canonicalize(value) end)

        assert JCS.canonicalize(object) == "{" <> expected <> "}"
      end
    end

    property "canonical output is independent of generated insertion order" do
      check all(
              fields <-
                StreamData.uniq_list_of(
                  StreamData.tuple({ascii_key(), scalar()}),
                  min_length: 1,
                  max_length: 12,
                  uniq_fun: &elem(&1, 0)
                ),
              max_runs: @property_runs
            ) do
        forward = fields |> Map.new() |> JCS.canonicalize()
        reverse = fields |> Enum.reverse() |> Map.new() |> JCS.canonicalize()

        assert forward == reverse
      end
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

  describe "binary-key contract (Task 72)" do
    test "raises ArgumentError on an atom map key" do
      assert_raise ArgumentError, ~r/string map keys/, fn ->
        JCS.canonicalize(%{atom_key: "value"})
      end
    end

    test "raises ArgumentError on an integer map key" do
      assert_raise ArgumentError, ~r/string map keys/, fn ->
        JCS.canonicalize(%{1 => "value"})
      end
    end

    test "raises on a non-binary key nested inside a value map" do
      assert_raise ArgumentError, ~r/string map keys/, fn ->
        JCS.canonicalize(%{"outer" => %{inner: "value"}})
      end
    end
  end

  defp ascii_key do
    StreamData.string(?a..?z, min_length: 1, max_length: 12)
  end

  defp scalar do
    StreamData.one_of([
      StreamData.integer(),
      StreamData.boolean(),
      StreamData.constant(nil),
      StreamData.string(:alphanumeric, max_length: 24)
    ])
  end
end
