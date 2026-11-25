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

    # mppx `compute` (refs/mppx/src/BodyDigest.ts) and mpp-rs `compute`
    # (refs/mpp-rs/src/body_digest.rs) write padded standard Base64.
    test "uses padded standard base64" do
      assert BodyDigest.compute("hello") == "sha-256=LPJNul+wow4m6DsqxbninhsWHlwfp0JecwQzYpOLmCQ="
    end

    # Vectors of refs/mpp-rs/src/server/mpp/tests/body_digest.rs.
    test "verify/2 accepts the bare and the RFC 9530 form, padded or not" do
      hash = "LPJNul+wow4m6DsqxbninhsWHlwfp0JecwQzYpOLmCQ"

      for digest <- ["sha-256=#{hash}=", "sha-256=#{hash}", "sha-256=:#{hash}=:", "sha-256=:#{hash}:"] do
        assert BodyDigest.verify(digest, "hello")
        refute BodyDigest.verify(digest, "hello!")
      end
    end

    test "verify/2 refuses a digest that is not a sha-256 hash" do
      hash = "LPJNul+wow4m6DsqxbninhsWHlwfp0JecwQzYpOLmCQ="

      for digest <- [
            "",
            "sha-256=",
            "sha-256=::",
            "sha-256=:",
            "sha-256=:#{hash}",
            "sha-256=#{hash}:",
            "sha-256=#{hash}=",
            "sha-256==",
            "sha-512=#{hash}",
            hash
          ] do
        refute BodyDigest.verify(digest, "hello")
      end
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
