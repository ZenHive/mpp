defmodule MPP.Methods.Tempo.SessionReceiptTest do
  use ExUnit.Case, async: true

  alias MPP.Methods.Tempo.SessionReceipt

  @required [
    challenge_id: "challenge-123",
    channel_id: "0xabc",
    accepted_cumulative: "5000",
    spent: "1000"
  ]

  describe "new/1" do
    test "sets method, intent, and status defaults" do
      receipt = SessionReceipt.new(@required)

      assert receipt.method == "tempo"
      assert receipt.intent == "session"
      assert receipt.status == "success"
    end

    test "auto-sets timestamp to RFC 3339 near now" do
      receipt = SessionReceipt.new(@required)

      assert {:ok, datetime, _offset} = DateTime.from_iso8601(receipt.timestamp)
      assert abs(DateTime.diff(datetime, DateTime.utc_now(), :second)) < 5
    end

    test "accepts custom timestamp" do
      receipt = SessionReceipt.new(Keyword.put(@required, :timestamp, "2026-01-01T00:00:00Z"))

      assert receipt.timestamp == "2026-01-01T00:00:00Z"
    end

    test "sets reference = channel_id by default" do
      receipt = SessionReceipt.new(@required)

      assert receipt.reference == "0xabc"
      assert receipt.reference == receipt.channel_id
    end

    test "accepts optional units and tx_hash" do
      receipt = SessionReceipt.new(@required ++ [units: 42, tx_hash: "0xdef"])

      assert receipt.units == 42
      assert receipt.tx_hash == "0xdef"
    end

    test "omits optional fields as nil when not provided" do
      receipt = SessionReceipt.new(@required)

      assert receipt.units == nil
      assert receipt.tx_hash == nil
    end

    test "raises on missing required field" do
      for missing <- [:challenge_id, :channel_id, :accepted_cumulative, :spent] do
        opts = Keyword.delete(@required, missing)

        assert_raise(
          # :channel_id raises KeyError (Keyword.fetch! in new/1 before struct!);
          # the others raise ArgumentError from struct! @enforce_keys.
          if(missing == :channel_id, do: KeyError, else: ArgumentError),
          fn -> SessionReceipt.new(opts) end
        )
      end
    end
  end

  describe "to_header/1 and from_header/1" do
    test "roundtrip preserves all fields" do
      receipt = SessionReceipt.new(@required ++ [units: 42, tx_hash: "0xdef"])
      encoded = SessionReceipt.to_header(receipt)

      assert {:ok, decoded} = SessionReceipt.from_header(encoded)
      assert decoded == receipt
    end

    test "roundtrip without optionals — units/tx_hash survive as nil" do
      receipt = SessionReceipt.new(@required)
      encoded = SessionReceipt.to_header(receipt)

      assert {:ok, decoded} = SessionReceipt.from_header(encoded)
      assert decoded.units == nil
      assert decoded.tx_hash == nil
      assert decoded == receipt
    end

    test "to_header produces valid base64url (no +, /, =)" do
      encoded = SessionReceipt.to_header(SessionReceipt.new(@required))

      refute String.contains?(encoded, "+")
      refute String.contains?(encoded, "/")
      refute String.contains?(encoded, "=")
    end

    test "wire JSON uses camelCase keys" do
      encoded = SessionReceipt.to_header(SessionReceipt.new(@required ++ [tx_hash: "0x1"]))
      raw = encoded |> Base.url_decode64!(padding: false) |> Jason.decode!()

      assert Map.has_key?(raw, "challengeId")
      assert Map.has_key?(raw, "channelId")
      assert Map.has_key?(raw, "acceptedCumulative")
      assert Map.has_key?(raw, "txHash")

      refute Map.has_key?(raw, "challenge_id")
      refute Map.has_key?(raw, "channel_id")
      refute Map.has_key?(raw, "accepted_cumulative")
      refute Map.has_key?(raw, "tx_hash")
    end

    test "optional fields omitted from wire JSON when nil (not serialized as null)" do
      encoded = SessionReceipt.to_header(SessionReceipt.new(@required))
      raw = encoded |> Base.url_decode64!(padding: false) |> Jason.decode!()

      refute Map.has_key?(raw, "units")
      refute Map.has_key?(raw, "txHash")
    end

    test "optional fields present in wire JSON when set" do
      encoded = SessionReceipt.to_header(SessionReceipt.new(@required ++ [units: 10, tx_hash: "0x123"]))
      raw = encoded |> Base.url_decode64!(padding: false) |> Jason.decode!()

      assert raw["units"] == 10
      assert raw["txHash"] == "0x123"
    end

    test "from_header trims surrounding whitespace" do
      encoded = SessionReceipt.to_header(SessionReceipt.new(@required))

      assert {:ok, _} = SessionReceipt.from_header("  " <> encoded <> "  ")
    end
  end

  describe "from_header/1 error cases" do
    test "returns :invalid_base64 for non-base64 input" do
      assert {:error, :invalid_base64} = SessionReceipt.from_header("not-valid-base64!!!")
    end

    test "returns :invalid_json for valid base64 but bad JSON" do
      encoded = Base.url_encode64("not json", padding: false)

      assert {:error, :invalid_json} = SessionReceipt.from_header(encoded)
    end

    test "returns :missing_required_fields for empty object" do
      encoded = %{} |> Jason.encode!() |> Base.url_encode64(padding: false)

      assert {:error, :missing_required_fields} = SessionReceipt.from_header(encoded)
    end

    test "returns :missing_required_fields when any required key is absent" do
      full = %{
        "method" => "tempo",
        "intent" => "session",
        "status" => "success",
        "timestamp" => "2026-01-01T00:00:00Z",
        "reference" => "0xabc",
        "challengeId" => "ch-1",
        "channelId" => "0xabc",
        "acceptedCumulative" => "5000",
        "spent" => "1000"
      }

      for key <- ~w(timestamp reference challengeId channelId acceptedCumulative spent) do
        encoded = full |> Map.delete(key) |> Jason.encode!() |> Base.url_encode64(padding: false)

        assert {:error, :missing_required_fields} = SessionReceipt.from_header(encoded),
               "expected missing #{key} to be rejected"
      end
    end

    test "rejects missing method/intent/status (mpp-rs parity)" do
      full = %{
        "method" => "tempo",
        "intent" => "session",
        "status" => "success",
        "timestamp" => "2026-01-01T00:00:00Z",
        "reference" => "0xabc",
        "challengeId" => "ch-1",
        "channelId" => "0xabc",
        "acceptedCumulative" => "5000",
        "spent" => "1000"
      }

      for key <- ~w(method intent status) do
        encoded = full |> Map.delete(key) |> Jason.encode!() |> Base.url_encode64(padding: false)

        assert {:error, :missing_required_fields} = SessionReceipt.from_header(encoded),
               "expected missing #{key} to be rejected"
      end
    end

    test "rejects wrong-typed optional fields (mpp-rs parity)" do
      base = %{
        "method" => "tempo",
        "intent" => "session",
        "status" => "success",
        "timestamp" => "2026-01-01T00:00:00Z",
        "reference" => "0xabc",
        "challengeId" => "ch-1",
        "channelId" => "0xabc",
        "acceptedCumulative" => "5000",
        "spent" => "1000"
      }

      bad_units = base |> Map.put("units", "42") |> Jason.encode!() |> Base.url_encode64(padding: false)
      assert {:error, :invalid_field_type} = SessionReceipt.from_header(bad_units)

      neg_units = base |> Map.put("units", -1) |> Jason.encode!() |> Base.url_encode64(padding: false)
      assert {:error, :invalid_field_type} = SessionReceipt.from_header(neg_units)

      bad_tx_hash = base |> Map.put("txHash", 123) |> Jason.encode!() |> Base.url_encode64(padding: false)
      assert {:error, :invalid_field_type} = SessionReceipt.from_header(bad_tx_hash)
    end
  end

  describe "cross-SDK compatibility with mpp-rs" do
    # Ported from refs/mpp-rs/src/protocol/methods/tempo/session_receipt.rs
    # test_header_roundtrip_and_malformed — the "with optionals" block (lines 244-258).
    test "decodes a receipt serialized in the mpp-rs wire format" do
      wire = %{
        "method" => "tempo",
        "intent" => "session",
        "status" => "success",
        "timestamp" => "2026-01-01T00:00:00Z",
        "reference" => "0xdef",
        "challengeId" => "ch-99",
        "channelId" => "0xdef",
        "acceptedCumulative" => "8000",
        "spent" => "3000",
        "units" => 42,
        "txHash" => "0xaaa"
      }

      encoded = wire |> Jason.encode!() |> Base.url_encode64(padding: false)

      assert {:ok, receipt} = SessionReceipt.from_header(encoded)
      assert receipt.method == "tempo"
      assert receipt.intent == "session"
      assert receipt.status == "success"
      assert receipt.channel_id == "0xdef"
      assert receipt.challenge_id == "ch-99"
      assert receipt.accepted_cumulative == "8000"
      assert receipt.spent == "3000"
      assert receipt.units == 42
      assert receipt.tx_hash == "0xaaa"
      assert receipt.reference == "0xdef"
    end

    # Matches mpp-rs `test_serialization_camel_case_keys`: minimal receipt
    # (no optionals) — units/txHash MUST be absent from the wire.
    test "minimal receipt matches mpp-rs test_serialization_camel_case_keys" do
      receipt =
        SessionReceipt.new(
          timestamp: "2026-01-01T00:00:00Z",
          challenge_id: "challenge-123",
          channel_id: "0xabc",
          accepted_cumulative: "5000",
          spent: "1000"
        )

      raw =
        receipt
        |> SessionReceipt.to_header()
        |> Base.url_decode64!(padding: false)

      assert raw =~ ~s("challengeId")
      assert raw =~ ~s("channelId")
      assert raw =~ ~s("acceptedCumulative")
      refute raw =~ ~s("units")
      refute raw =~ ~s("txHash")
    end
  end

  # Token-size DoS cap (mpp-rs #299) — the Tempo-session sibling of the
  # MPP.Headers.parse_receipt cap. The literal mirrors @max_token_len in
  # MPP.Methods.Tempo.SessionReceipt; re-verified against
  # refs/mpp-rs/src/protocol/core/headers.rs:18 (MAX_TOKEN_LEN = 16 * 1024).
  @max_token_len 16 * 1024

  describe "from_header/1 token-size cap before decode (DoS, mpp-rs #299)" do
    test "rejects over-limit token before any base64url decode" do
      token = String.duplicate("A", @max_token_len + 1)
      assert {:error, :token_too_large} = SessionReceipt.from_header(token)
    end

    test "at-limit token passes the size gate and reaches decode" do
      # 16384 valid base64url chars clear the gate, decode, then fail downstream —
      # proving the cap let an at-limit token through (it is NOT :token_too_large).
      token = String.duplicate("A", @max_token_len)
      assert {:error, reason} = SessionReceipt.from_header(token)
      assert reason != :token_too_large
    end
  end
end
