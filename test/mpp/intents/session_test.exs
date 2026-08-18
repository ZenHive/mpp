defmodule MPP.Intents.SessionTest do
  use ExUnit.Case, async: true

  alias MPP.Intents.Session

  describe "new/1" do
    test "creates session with required fields" do
      assert {:ok, session} = Session.new(amount: "1000", currency: "usd")

      assert session.amount == "1000"
      assert session.currency == "usd"
      assert session.unit_type == nil
      assert session.recipient == nil
      assert session.suggested_deposit == nil
      assert session.decimals == nil
      assert session.external_id == nil
      assert session.method_details == nil
    end

    # Wire parity: mpp-rs types currency as a plain String and asserts verbatim
    # round-trip (refs/mpp-rs/src/protocol/intents/session.rs:44,169); its doctest
    # at :24 carries a checksummed token address. Normalizing would break an mppx
    # client comparing `challenge.currency === "USD"` and would strip the EIP-55
    # checksum from an on-chain token address.
    test "preserves currency verbatim" do
      assert {:ok, session} = Session.new(amount: "500", currency: "USD")
      assert session.currency == "USD"

      assert {:ok, session2} = Session.new(amount: "500", currency: "Eur")
      assert session2.currency == "Eur"

      checksummed = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
      assert {:ok, session3} = Session.new(amount: "500", currency: checksummed)
      assert session3.currency == checksummed
    end

    test "accepts all optional fields" do
      assert {:ok, session} =
               Session.new(
                 amount: "1000",
                 currency: "usd",
                 unit_type: "second",
                 recipient: "0x742d35Cc6634C0532925a3b844Bc9e7595f1B0F2",
                 suggested_deposit: "60000",
                 decimals: 6,
                 external_id: "sess-42",
                 method_details: %{"chainId" => 42_431, "feePayer" => true}
               )

      assert session.unit_type == "second"
      assert session.recipient == "0x742d35Cc6634C0532925a3b844Bc9e7595f1B0F2"
      assert session.suggested_deposit == "60000"
      assert session.decimals == 6
      assert session.external_id == "sess-42"
      assert session.method_details == %{"chainId" => 42_431, "feePayer" => true}
    end

    test "returns error when amount is missing" do
      assert {:error, :amount_required} = Session.new(currency: "usd")
    end

    test "returns error when amount is empty string" do
      assert {:error, :invalid_amount} = Session.new(amount: "", currency: "usd")
    end

    test "returns error when amount is not a string" do
      assert {:error, :invalid_amount} = Session.new(amount: 1000, currency: "usd")
    end

    test "returns error when currency is missing" do
      assert {:error, :currency_required} = Session.new(amount: "1000")
    end

    test "returns error when currency is empty string" do
      assert {:error, :invalid_currency} = Session.new(amount: "1000", currency: "")
    end

    # mpp-rs types unitType/recipient/suggestedDeposit as Option<String>
    # (refs/mpp-rs/src/protocol/intents/session.rs:40-61), so serde rejects a
    # non-string. Accepting one here would let us emit a request the reference
    # SDKs cannot parse.
    test "returns error when unit_type is not a string" do
      assert {:error, :invalid_field_type} =
               Session.new(amount: "1000", currency: "usd", unit_type: 123)
    end

    test "returns error when recipient is not a string" do
      assert {:error, :invalid_field_type} =
               Session.new(amount: "1000", currency: "usd", recipient: %{"a" => 1})
    end

    test "returns error when suggested_deposit is not a string" do
      assert {:error, :invalid_field_type} =
               Session.new(amount: "1000", currency: "usd", suggested_deposit: 5000)
    end

    test "accepts nil for every optional string field" do
      assert {:ok, session} =
               Session.new(
                 amount: "1000",
                 currency: "usd",
                 unit_type: nil,
                 recipient: nil,
                 suggested_deposit: nil
               )

      assert session.unit_type == nil
      assert session.recipient == nil
      assert session.suggested_deposit == nil
    end
  end

  describe "to_request/1 and from_request/1" do
    test "roundtrip preserves wire fields" do
      assert {:ok, session} =
               Session.new(
                 amount: "1000",
                 currency: "usd",
                 unit_type: "second",
                 recipient: "0x456",
                 suggested_deposit: "60000",
                 external_id: "ext-1",
                 method_details: %{"chainId" => 42_431}
               )

      request = Session.to_request(session)
      assert {:ok, restored} = Session.from_request(request)

      assert restored.amount == session.amount
      assert restored.currency == session.currency
      assert restored.unit_type == session.unit_type
      assert restored.recipient == session.recipient
      assert restored.suggested_deposit == session.suggested_deposit
      # external_id is transient (not on mpp-rs SessionRequest wire)
      assert restored.external_id == nil
      assert restored.method_details == session.method_details
    end

    test "to_request uses camelCase keys matching mpp-rs SessionRequest and omits transient fields" do
      assert {:ok, session} =
               Session.new(
                 amount: "1000",
                 currency: "0x123",
                 unit_type: "second",
                 suggested_deposit: "60000",
                 decimals: 6,
                 external_id: "abc",
                 method_details: %{"chainId" => 42_431, "feePayer" => true}
               )

      request = Session.to_request(session)

      assert request["amount"] == "1000"
      assert request["currency"] == "0x123"
      assert request["unitType"] == "second"
      assert request["suggestedDeposit"] == "60000"
      assert request["methodDetails"] == %{"chainId" => 42_431, "feePayer" => true}

      # mpp-rs SessionRequest has no externalId; decimals is #[serde(skip)]
      refute Map.has_key?(request, "decimals")
      refute Map.has_key?(request, "externalId")
      refute Map.has_key?(request, "unit_type")
      refute Map.has_key?(request, "suggested_deposit")
      refute Map.has_key?(request, "external_id")
      refute Map.has_key?(request, "method_details")
    end

    test "to_request omits nil optional fields and transient decimals/external_id" do
      assert {:ok, session} =
               Session.new(amount: "500", currency: "usd", decimals: 6, external_id: "ext")

      request = Session.to_request(session)

      assert request == %{"amount" => "500", "currency" => "usd"}
      refute Map.has_key?(request, "decimals")
      refute Map.has_key?(request, "externalId")
      refute Map.has_key?(request, "unitType")
      refute Map.has_key?(request, "suggestedDeposit")
      refute Map.has_key?(request, "recipient")
      refute Map.has_key?(request, "methodDetails")
    end

    test "from_request accepts mpp-rs SessionRequest JSON shape" do
      # Matches mpp-rs test_session_request_deserialization fixture
      json = %{
        "amount" => "2000",
        "unitType" => "minute",
        "currency" => "0xabc",
        "decimals" => 6,
        "externalId" => "ext-1"
      }

      assert {:ok, session} = Session.from_request(json)
      assert session.amount == "2000"
      assert session.unit_type == "minute"
      assert session.currency == "0xabc"
      assert session.recipient == nil
      assert session.suggested_deposit == nil
      assert session.decimals == nil
      assert session.external_id == nil
      assert session.method_details == nil
    end

    test "from_request rejects a non-string unitType on the wire" do
      assert {:error, :invalid_field_type} =
               Session.from_request(%{"amount" => "1000", "currency" => "usd", "unitType" => 123})
    end

    test "from_request rejects a non-string suggestedDeposit on the wire" do
      assert {:error, :invalid_field_type} =
               Session.from_request(%{
                 "amount" => "1000",
                 "currency" => "usd",
                 "suggestedDeposit" => 5000
               })
    end

    test "from_request accepts session without unitType" do
      # Matches mpp-rs test_session_request_without_unit_type
      json = %{"amount" => "2000", "currency" => "0xabc"}

      assert {:ok, session} = Session.from_request(json)
      assert session.amount == "2000"
      assert session.unit_type == nil
    end

    test "from_request ignores transient fields present on the map" do
      assert {:ok, session} =
               Session.from_request(%{
                 "amount" => "100",
                 "currency" => "usd",
                 "decimals" => 6,
                 "externalId" => "ext-1"
               })

      assert session.decimals == nil
      assert session.external_id == nil
    end

    test "from_request returns error for missing required fields" do
      assert {:error, :missing_required_fields} = Session.from_request(%{"amount" => "100"})
      assert {:error, :missing_required_fields} = Session.from_request(%{})
    end

    test "roundtrip does not restore transient decimals or external_id" do
      assert {:ok, session} =
               Session.new(
                 amount: "1.5",
                 currency: "usd",
                 unit_type: "second",
                 decimals: 6,
                 external_id: "sess-1"
               )

      assert session.decimals == 6
      assert session.external_id == "sess-1"
      restored = session |> Session.to_request() |> Session.from_request()
      assert {:ok, %Session{decimals: nil, external_id: nil}} = restored
    end
  end
end
