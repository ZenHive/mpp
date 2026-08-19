defmodule MPP.ReceiptTest do
  use ExUnit.Case, async: true

  alias MPP.Receipt

  describe "new/1" do
    test "creates receipt with required fields and defaults" do
      receipt = Receipt.new(method: "stripe", reference: "pi_abc123")

      assert receipt.status == "success"
      assert receipt.method == "stripe"
      assert receipt.reference == "pi_abc123"
      assert receipt.timestamp
      assert receipt.external_id == nil
    end

    test "accepts optional external_id" do
      receipt = Receipt.new(method: "tempo", reference: "tx_hash", external_id: "order-42")

      assert receipt.external_id == "order-42"
    end

    test "accepts optional subscription_id" do
      receipt = Receipt.new(method: "tempo", reference: "tx_hash", subscription_id: "sub_123")

      assert receipt.subscription_id == "sub_123"
    end

    test "defaults extensions to an empty map" do
      receipt = Receipt.new(method: "stripe", reference: "pi_abc")

      assert receipt.extensions == %{}
      assert receipt.subscription_id == nil
    end

    test "accepts custom timestamp" do
      receipt = Receipt.new(method: "stripe", reference: "pi_abc", timestamp: "2026-01-01T00:00:00Z")

      assert receipt.timestamp == "2026-01-01T00:00:00Z"
    end

    test "raises on missing required fields" do
      assert_raise ArgumentError, fn -> Receipt.new(method: "stripe") end
      assert_raise ArgumentError, fn -> Receipt.new(reference: "pi_abc") end
      assert_raise ArgumentError, fn -> Receipt.new([]) end
    end
  end

  describe "encode/1 and decode/1" do
    test "roundtrip encode → decode preserves all fields" do
      receipt = Receipt.new(method: "stripe", reference: "pi_abc123", external_id: "ext-1")
      encoded = Receipt.encode(receipt)
      assert {:ok, decoded} = Receipt.decode(encoded)

      assert decoded.status == receipt.status
      assert decoded.method == receipt.method
      assert decoded.reference == receipt.reference
      assert decoded.external_id == receipt.external_id
      assert decoded.timestamp == receipt.timestamp
    end

    test "roundtrip without optional fields" do
      receipt = Receipt.new(method: "tempo", reference: "0xdeadbeef")
      encoded = Receipt.encode(receipt)
      assert {:ok, decoded} = Receipt.decode(encoded)

      assert decoded.method == "tempo"
      assert decoded.reference == "0xdeadbeef"
      assert decoded.external_id == nil
      assert decoded.subscription_id == nil
      assert decoded.extensions == %{}
    end

    test "roundtrip preserves subscriptionId (mpp-rs #383)" do
      # refs/mpp-rs/src/protocol/core/headers.rs:780-794; challenge.rs:815-816.
      receipt = Receipt.new(method: "tempo", reference: "0xabc123", subscription_id: "sub_123")
      encoded = Receipt.encode(receipt)
      assert {:ok, decoded} = Receipt.decode(encoded)

      assert decoded.subscription_id == "sub_123"
    end

    test "roundtrip preserves method-specific extension fields (originTxHash)" do
      # refs/mpp-rs/src/protocol/core/headers.rs:810-817 flatten; refs/mppx/src/Receipt.ts:38 looseObject.
      json =
        Jason.encode!(%{
          "status" => "success",
          "method" => "tempo",
          "timestamp" => "2024-01-01T00:00:00Z",
          "reference" => "0xabc123",
          "originTxHash" => "0xdef456"
        })

      encoded = Base.url_encode64(json, padding: false)
      assert {:ok, parsed} = Receipt.decode(encoded)
      assert parsed.extensions["originTxHash"] == "0xdef456"

      assert {:ok, reparsed} = parsed |> Receipt.encode() |> Receipt.decode()
      assert reparsed.extensions["originTxHash"] == "0xdef456"
    end

    test "core fields keep precedence over stuffed extensions" do
      receipt =
        Receipt.new(
          method: "tempo",
          reference: "0xabc",
          timestamp: "2024-01-01T00:00:00Z",
          extensions: %{"method" => "evil", "status" => "failed", "originTxHash" => "0xdef"}
        )

      encoded = Receipt.encode(receipt)
      {:ok, raw} = encoded |> Base.url_decode64!(padding: false) |> Jason.decode()

      assert raw["method"] == "tempo"
      assert raw["status"] == "success"
      assert raw["originTxHash"] == "0xdef"
      refute raw["method"] == "evil"
    end

    test "foreign subscriptionId on the wire is not dropped" do
      # refs/mpp-rs/src/protocol/core/headers.rs:798-806.
      json =
        Jason.encode!(%{
          "status" => "success",
          "method" => "tempo",
          "timestamp" => "2024-01-01T00:00:00Z",
          "reference" => "0xabc123",
          "subscriptionId" => "sub_123"
        })

      encoded = Base.url_encode64(json, padding: false)
      assert {:ok, parsed} = Receipt.decode(encoded)
      assert parsed.subscription_id == "sub_123"
      refute Map.has_key?(parsed.extensions, "subscriptionId")
    end

    test "encode produces valid base64url string" do
      receipt = Receipt.new(method: "stripe", reference: "pi_test")
      encoded = Receipt.encode(receipt)

      # Should be valid base64url (no + / = characters)
      refute String.contains?(encoded, "+")
      refute String.contains?(encoded, "/")
      refute String.contains?(encoded, "=")
    end
  end

  describe "decode/1 error cases" do
    test "returns error for invalid base64" do
      assert {:error, :invalid_base64} = Receipt.decode("not-valid-base64!!!")
    end

    test "returns error for valid base64 but invalid JSON" do
      encoded = Base.url_encode64("not json", padding: false)
      assert {:error, :invalid_json} = Receipt.decode(encoded)
    end

    test "returns error for missing required fields" do
      json = Jason.encode!(%{"status" => "success"})
      encoded = Base.url_encode64(json, padding: false)
      assert {:error, :missing_required_fields} = Receipt.decode(encoded)
    end

    test "returns error for missing timestamp" do
      json = Jason.encode!(%{"method" => "stripe", "reference" => "pi_123", "status" => "success"})
      encoded = Base.url_encode64(json, padding: false)
      assert {:error, :missing_required_fields} = Receipt.decode(encoded)
    end

    test "returns error for a non-string subscriptionId" do
      json =
        Jason.encode!(%{
          "method" => "tempo",
          "reference" => "0xabc",
          "timestamp" => "2024-01-01T00:00:00Z",
          "status" => "success",
          "subscriptionId" => 123
        })

      encoded = Base.url_encode64(json, padding: false)
      assert {:error, :invalid_field_type} = Receipt.decode(encoded)
    end
  end
end
