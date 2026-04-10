defmodule MPP.BodyDigestTest do
  use ExUnit.Case, async: true

  alias MPP.BodyDigest

  describe "compute/1" do
    test "returns sha-256 prefixed digest for string body" do
      digest = BodyDigest.compute("hello")
      assert String.starts_with?(digest, "sha-256=")
    end

    test "produces consistent output for same input" do
      digest1 = BodyDigest.compute("test body")
      digest2 = BodyDigest.compute("test body")
      assert digest1 == digest2
    end

    test "produces different output for different input" do
      digest1 = BodyDigest.compute("body a")
      digest2 = BodyDigest.compute("body b")
      refute digest1 == digest2
    end

    test "JSON-encodes maps before hashing" do
      map_digest = BodyDigest.compute(%{"amount" => "1000"})
      string_digest = BodyDigest.compute(Jason.encode!(%{"amount" => "1000"}))
      assert map_digest == string_digest
    end

    test "uses standard base64 without padding" do
      "sha-256=" <> hash = BodyDigest.compute("test")
      # base64 alphabet: A-Z, a-z, 0-9, +, / (no - or _ which would be base64url)
      refute String.ends_with?(hash, "=")
      # SHA-256 = 32 bytes → 43 base64 chars without padding
      assert byte_size(hash) == 43
    end

    test "matches known SHA-256 vector" do
      # SHA-256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
      digest = BodyDigest.compute("")
      "sha-256=" <> hash = digest
      {:ok, raw} = Base.decode64(hash, padding: false)
      assert Base.encode16(raw, case: :lower) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    end
  end

  describe "verify/2" do
    test "returns true for matching digest" do
      body = ~s({"amount":"1000"})
      digest = BodyDigest.compute(body)
      assert BodyDigest.verify(digest, body)
    end

    test "returns false for non-matching digest" do
      digest = BodyDigest.compute("original")
      refute BodyDigest.verify(digest, "tampered")
    end

    test "works with map bodies" do
      map = %{"key" => "value"}
      digest = BodyDigest.compute(map)
      assert BodyDigest.verify(digest, map)
    end

    test "returns false for corrupted digest" do
      body = "test"
      digest = BodyDigest.compute(body)
      corrupted = digest <> "x"
      refute BodyDigest.verify(corrupted, body)
    end

    test "map digest may differ from hand-ordered JSON string (expected behavior)" do
      # Jason may serialize keys in a different order than a hand-written JSON string.
      # For wire-format binding, always pass raw body bytes — not a map.
      map_digest = BodyDigest.compute(%{"b" => 1, "a" => 2})
      hand_ordered = BodyDigest.compute(~s({"b":1,"a":2}))
      jason_encoded = Jason.encode!(%{"b" => 1, "a" => 2})
      same_via_jason = BodyDigest.compute(jason_encoded)

      # Map path always matches Jason.encode! of the same map
      assert map_digest == same_via_jason

      # If Jason reorders keys, the hand-ordered string produces a different digest
      if ~s({"b":1,"a":2}) != jason_encoded do
        refute map_digest == hand_ordered
      end
    end
  end
end
