defmodule MPP.Client.AcceptPolicyTest do
  use ExUnit.Case, async: true

  alias MPP.Client.AcceptPolicy

  describe "allows?/2" do
    test ":always permits any URL" do
      assert AcceptPolicy.allows?(:always, "https://example.com/api")
      assert AcceptPolicy.allows?(:always, "http://localhost:8080/")
    end

    test ":never blocks any URL" do
      refute AcceptPolicy.allows?(:never, "https://example.com/api")
    end

    test "default is :always" do
      assert AcceptPolicy.allows?(AcceptPolicy.default(), "https://example.com/")
    end

    test "{:same_origin, origin} matches scheme/host/port" do
      policy = {:same_origin, "https://app.example.com"}

      assert AcceptPolicy.allows?(policy, "https://app.example.com/api")
      refute AcceptPolicy.allows?(policy, "https://other.example.com/api")
      refute AcceptPolicy.allows?(policy, "http://app.example.com/api")
    end

    test "{:same_origin, origin} respects explicit port" do
      policy = {:same_origin, "http://localhost:3000"}

      assert AcceptPolicy.allows?(policy, "http://localhost:3000/api")
      refute AcceptPolicy.allows?(policy, "http://localhost:3001/api")
    end

    test "{:origins, patterns} supports exact and wildcard hosts" do
      exact = {:origins, ["https://app.example.com"]}
      assert AcceptPolicy.allows?(exact, "https://app.example.com/x")
      refute AcceptPolicy.allows?(exact, "https://other.com/x")

      wildcard = {:origins, ["*.example.com"]}
      assert AcceptPolicy.allows?(wildcard, "https://api.example.com/")
      assert AcceptPolicy.allows?(wildcard, "https://example.com/")
      refute AcceptPolicy.allows?(wildcard, "https://maliciousexample.com/")
      refute AcceptPolicy.allows?(wildcard, "https://example.org/")
    end

    test "rejects host-only patterns without scheme" do
      policy = {:origins, ["api.example.com"]}
      refute AcceptPolicy.allows?(policy, "https://api.example.com/")
    end
  end
end
