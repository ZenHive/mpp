defmodule MPP.X402.HeadersTest do
  use ExUnit.Case, async: true

  alias MPP.Headers
  alias MPP.X402.Headers, as: X402Headers

  # Official x402 v2 PaymentRequired example (specification §5.1.1).
  @official_payment_required %{
    "x402Version" => 2,
    "error" => "PAYMENT-SIGNATURE header is required",
    "resource" => %{
      "url" => "https://api.example.com/premium-data",
      "description" => "Access to premium market data",
      "mimeType" => "application/json",
      "serviceName" => "Example Market Data",
      "tags" => ["market-data", "finance"],
      "iconUrl" => "https://api.example.com/icon.png"
    },
    "accepts" => [
      %{
        "scheme" => "exact",
        "network" => "eip155:84532",
        "amount" => "10000",
        "asset" => "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
        "payTo" => "0x209693Bc6afc0C5328bA36FaF03C514EF312287C",
        "maxTimeoutSeconds" => 60,
        "extra" => %{"name" => "USDC", "version" => "2"}
      }
    ]
  }

  # Official x402 v2 PaymentPayload example (specification §5.2.1).
  @official_payment_payload %{
    "x402Version" => 2,
    "resource" => %{
      "url" => "https://api.example.com/premium-data",
      "description" => "Access to premium market data",
      "mimeType" => "application/json"
    },
    "accepted" => %{
      "scheme" => "exact",
      "network" => "eip155:84532",
      "amount" => "10000",
      "asset" => "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
      "payTo" => "0x209693Bc6afc0C5328bA36FaF03C514EF312287C",
      "maxTimeoutSeconds" => 60,
      "extra" => %{"name" => "USDC", "version" => "2"}
    },
    "payload" => %{
      "signature" =>
        "0x2d6a7588d6acca505cbf0d9a4a227e0c52c6c34008c8e8986a1283259764173608a2ce6496642e377d6da8dbbf5836e9bd15092f9ecab05ded3d6293af148b571c",
      "authorization" => %{
        "from" => "0x857b06519E91e3A54538791bDbb0E22373e36b66",
        "to" => "0x209693Bc6afc0C5328bA36FaF03C514EF312287C",
        "value" => "10000",
        "validAfter" => "1740672089",
        "validBefore" => "1740672154",
        "nonce" => "0xf3746613c2d920b5fdabc0856f2aeb2d4f88ee6037b8cc5d04a71a4462f13480"
      }
    }
  }

  # Official x402 v2 SettlementResponse example (specification §5.3.1).
  @official_settlement %{
    "success" => true,
    "transaction" => "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
    "network" => "eip155:84532",
    "payer" => "0x857b06519E91e3A54538791bDbb0E22373e36b66"
  }

  test "round-trips the official PAYMENT-REQUIRED example as standard Base64 JSON" do
    assert {:ok, header} = X402Headers.encode_payment_required(@official_payment_required)
    assert X402Headers.payment_required_header() == "PAYMENT-REQUIRED"
    assert X402Headers.payment_signature_header() == "PAYMENT-SIGNATURE"
    assert X402Headers.payment_response_header() == "PAYMENT-RESPONSE"
    refute String.contains?(header, "-")
    refute String.contains?(header, "_")
    assert {:ok, decoded} = X402Headers.decode_payment_required(header)
    assert decoded["x402Version"] == 2
    assert decoded["resource"]["url"] == "https://api.example.com/premium-data"
    assert hd(decoded["accepts"])["scheme"] == "exact"
    assert hd(decoded["accepts"])["network"] == "eip155:84532"
    assert {:error, :invalid_scheme} = Headers.parse_challenge(header)
    assert {:error, :no_payment_challenges} = Headers.parse_challenges(header)
  end

  test "round-trips the official PAYMENT-SIGNATURE example without native Payment-auth parse" do
    assert {:ok, header} = X402Headers.encode_payment_signature(@official_payment_payload)
    assert {:ok, decoded} = X402Headers.decode_payment_signature(header)

    assert decoded["payload"]["authorization"]["nonce"] ==
             "0xf3746613c2d920b5fdabc0856f2aeb2d4f88ee6037b8cc5d04a71a4462f13480"

    assert {:error, :invalid_scheme} = Headers.parse_credential(header)
    refute match?({:ok, _}, Headers.parse_credential("Payment " <> header))
  end

  test "round-trips the official PAYMENT-RESPONSE example" do
    assert {:ok, header} = X402Headers.encode_payment_response(@official_settlement)
    assert {:ok, decoded} = X402Headers.decode_payment_response(header)
    assert decoded["success"] == true
    assert decoded["network"] == "eip155:84532"
    refute match?({:ok, _}, Headers.parse_receipt(header))
  end

  test "rejects Permit2 payloads" do
    payload = %{
      "x402Version" => 2,
      "accepted" => %{
        "scheme" => "exact",
        "network" => "eip155:84532",
        "amount" => "1",
        "asset" => "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
        "payTo" => "0x209693Bc6afc0C5328bA36FaF03C514EF312287C",
        "maxTimeoutSeconds" => 60,
        "extra" => %{"assetTransferMethod" => "permit2", "name" => "USDC", "version" => "2"}
      },
      "payload" => %{"permit2Authorization" => %{}}
    }

    assert {:error, :unsupported_transfer_method} = X402Headers.encode_payment_signature(payload)
  end

  test "rejects malformed encoding and enforces the header byte limit" do
    for decode <- [
          &X402Headers.decode_payment_required/1,
          &X402Headers.decode_payment_signature/1,
          &X402Headers.decode_payment_response/1,
          &X402Headers.decode_payment_required_envelope/1
        ] do
      assert {:error, :invalid_base64} = decode.("!")
      assert {:error, :invalid_json} = decode.(Base.encode64("{"))
      assert {:error, :header_too_large} = decode.(String.duplicate("a", 16 * 1024 + 1))
      assert {:error, :invalid_json} = decode.(String.duplicate("a", 16 * 1024))
    end

    unpadded = @official_payment_required |> Jason.encode!() |> Base.encode64(padding: false)
    assert {:ok, _} = X402Headers.decode_payment_required(unpadded)
  end

  test "required envelopes reject malformed fields but permit empty unsupported offers" do
    for value <- [[], %{}, %{"x402Version" => 2, "accepts" => []}] do
      assert {:error, _} = X402Headers.decode_payment_required(encode(value))
      assert {:error, _} = X402Headers.decode_payment_required_envelope(encode(value))
    end

    empty = Map.put(@official_payment_required, "accepts", [])
    assert {:error, :invalid_payment_required} = X402Headers.encode_payment_required(empty)
    assert {:ok, %{"accepts" => []}} = X402Headers.decode_payment_required_envelope(encode(empty))
    invalid = Map.put(@official_payment_required, "accepts", [nil])
    assert {:error, :invalid_requirements} = X402Headers.encode_payment_required(invalid)
  end

  test "requirements validate types, atomic amounts, timeout and supported scheme" do
    accept = hd(@official_payment_required["accepts"])

    for {key, value, reason} <- [
          {"scheme", "other", :invalid_requirements},
          {"network", "solana:1", :invalid_requirements},
          {"network", "eip155:bad", :invalid_requirements},
          {"asset", "", :invalid_header},
          {"amount", "-1", :invalid_header},
          {"amount", 1, :invalid_header},
          {"maxTimeoutSeconds", 0, :invalid_header}
        ] do
      assert {:error, ^reason} = X402Headers.parse_requirements(Map.put(accept, key, value))
    end

    assert {:error, :invalid_requirements} = X402Headers.parse_requirements(nil)

    assert {:ok, %{"maxTimeoutSeconds" => 1}} =
             X402Headers.parse_requirements(Map.put(accept, "maxTimeoutSeconds", 1.5))

    assert :ok = X402Headers.reject_permit2(%{})
  end

  test "payload validation rejects malformed authorization and strips invalid optional resource" do
    for value <- [[], %{}, Map.put(@official_payment_payload, "payload", %{})] do
      assert {:error, :invalid_payment_payload} = X402Headers.decode_payment_signature(encode(value))
    end

    permit = Map.put(@official_payment_payload, "payload", %{"permit2Authorization" => %{}})
    assert {:error, :unsupported_transfer_method} = X402Headers.encode_payment_signature(permit)

    invalid = put_in(@official_payment_payload, ["payload", "authorization", "value"], "1.5")
    assert {:error, :invalid_header} = X402Headers.encode_payment_signature(invalid)

    assert {:ok, header} = X402Headers.encode_payment_signature(Map.put(@official_payment_payload, "resource", %{}))
    assert {:ok, decoded} = X402Headers.decode_payment_signature(header)
    refute Map.has_key?(decoded, "resource")
  end

  test "response parsers preserve failure details and reject malformed responses" do
    for value <- [nil, %{}, %{"isValid" => "true"}] do
      assert {:error, :invalid_verify_response} = X402Headers.parse_verify_response(value)
    end

    assert {:ok, %{"isValid" => false, "invalidReason" => "declined"}} =
             X402Headers.parse_verify_response(%{"isValid" => false, "invalidReason" => "declined"})

    for value <- [nil, %{}, %{"success" => "true"}] do
      assert {:error, :invalid_settle_response} = X402Headers.parse_settle_response(value)
    end

    assert {:error, :invalid_header} =
             X402Headers.parse_settle_response(%{"success" => false, "network" => "eip155:1", "transaction" => nil})

    failure = %{"success" => false, "network" => "eip155:1", "transaction" => "", "errorReason" => "declined"}
    assert {:ok, ^failure} = X402Headers.parse_settle_response(failure)
  end

  test "optional tags are bounded and unencodable metadata returns an error" do
    for tags <- [Enum.to_list(1..6), [1], "tag"] do
      value = put_in(@official_payment_required, ["resource", "tags"], tags)
      assert {:ok, header} = X402Headers.encode_payment_required(value)
      assert {:ok, decoded} = X402Headers.decode_payment_required(header)
      refute Map.has_key?(decoded["resource"], "tags")
    end

    assert {:error, :invalid_json} =
             X402Headers.encode_payment_response(Map.put(@official_settlement, "extra", %{"bad" => <<255>>}))
  end

  defp encode(value), do: value |> Jason.encode!() |> Base.encode64()
end
