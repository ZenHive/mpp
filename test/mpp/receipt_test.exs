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
  end
end
