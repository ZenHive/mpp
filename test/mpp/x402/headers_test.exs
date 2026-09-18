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
end
