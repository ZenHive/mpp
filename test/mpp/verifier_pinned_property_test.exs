defmodule MPP.VerifierPinnedPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MPP.Challenge
  alias MPP.Credential
  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.JCS
  alias MPP.Receipt
  alias MPP.Verifier

  defmodule MockMethod do
    @moduledoc false
    use MPP.Method

    @impl MPP.Method
    def method_name, do: "mock"

    @impl MPP.Method
    def verify(_payload, _charge), do: {:ok, Receipt.new(method: method_name(), reference: "ref_ok")}
  end

  @secret "property-test-secret"
  @realm "api.property.test"

  defp build_charge(amount, currency) do
    {:ok, charge} = Charge.new(amount: amount, currency: currency)
    charge
  end

  defp encode_request(charge) do
    charge
    |> Charge.to_request()
    |> JCS.canonicalize()
    |> Base.url_encode64(padding: false)
  end

  defp future_expires do
    DateTime.utc_now()
    |> DateTime.shift(minute: 10)
    |> DateTime.to_iso8601()
  end

  defp valid_credential(charge) do
    challenge =
      Challenge.create(
        [
          realm: @realm,
          method: "mock",
          intent: "charge",
          request: encode_request(charge),
          expires: future_expires()
        ],
        @secret
      )

    %Credential{challenge: challenge, payload: %{"proof" => "valid"}}
  end

  defp verify_opts(charge) do
    [
      secret_key: @secret,
      realm: @realm,
      method: MockMethod,
      charge: charge
    ]
  end

  describe "property: valid credentials pass Tier-1 and Tier-2" do
    property "matching charge and credential always verifies" do
      check all(
              amount <- 1..999_999 |> StreamData.integer() |> StreamData.map(&Integer.to_string/1),
              currency <- StreamData.one_of([StreamData.constant("usd"), StreamData.constant("eur")])
            ) do
        charge = build_charge(amount, currency)
        credential = valid_credential(charge)

        assert {:ok, %Receipt{}} = Verifier.verify(credential, verify_opts(charge))
      end
    end
  end

  describe "property: pinned-field divergence yields credential_mismatch when HMAC re-signed" do
    property "tampered echoed realm without re-sign returns credential_mismatch" do
      check all(other_realm <- StreamData.string(:alphanumeric, min_length: 3, max_length: 20)) do
        charge = build_charge("1000", "usd")
        credential = valid_credential(charge)
        tampered = %{credential | challenge: %{credential.challenge | realm: other_realm}}

        if other_realm == @realm do
          assert {:ok, _} = Verifier.verify(tampered, verify_opts(charge))
        else
          assert {:error, %Errors{type: type}} = Verifier.verify(tampered, verify_opts(charge))
          assert String.contains?(type, "credential-mismatch")
        end
      end
    end

    property "wrong currency in request (re-signed) returns credential_mismatch" do
      check all(
              amount <- StreamData.constant("1000"),
              currency <- StreamData.one_of([StreamData.constant("usd"), StreamData.constant("eur")]),
              other <- StreamData.one_of([StreamData.constant("usd"), StreamData.constant("eur")])
            ) do
        charge = build_charge(amount, currency)
        tampered = build_charge(amount, other)

        challenge =
          Challenge.create(
            [
              realm: @realm,
              method: "mock",
              intent: "charge",
              request: encode_request(tampered),
              expires: future_expires()
            ],
            @secret
          )

        credential = %Credential{challenge: challenge, payload: %{"proof" => "valid"}}

        if currency == other do
          assert {:ok, _} = Verifier.verify(credential, verify_opts(charge))
        else
          assert {:error, %Errors{type: type}} = Verifier.verify(credential, verify_opts(charge))
          assert String.contains?(type, "credential-mismatch")
        end
      end
    end

    property "wrong amount in request (re-signed) returns credential_mismatch" do
      check all(
              amount <- StreamData.integer(1..999_999),
              other_amount <- StreamData.integer(1..999_999)
            ) do
        charge = build_charge(Integer.to_string(amount), "usd")
        tampered = build_charge(Integer.to_string(other_amount), "usd")

        challenge =
          Challenge.create(
            [
              realm: @realm,
              method: "mock",
              intent: "charge",
              request: encode_request(tampered),
              expires: future_expires()
            ],
            @secret
          )

        credential = %Credential{challenge: challenge, payload: %{"proof" => "valid"}}

        if amount == other_amount do
          assert {:ok, _receipt} = Verifier.verify(credential, verify_opts(charge))
        else
          assert {:error, %Errors{type: type}} = Verifier.verify(credential, verify_opts(charge))
          assert String.contains?(type, "credential-mismatch")
        end
      end
    end
  end

  describe "property: HMAC corruption yields invalid_challenge, not credential_mismatch" do
    property "wrong secret never returns credential_mismatch" do
      check all(
              wrong <- StreamData.string(:alphanumeric, min_length: 8, max_length: 32),
              wrong != @secret
            ) do
        charge = build_charge("1000", "usd")
        credential = valid_credential(charge)

        assert {:error, %Errors{type: type}} =
                 Verifier.verify(credential, charge |> verify_opts() |> Keyword.put(:secret_key, wrong))

        assert String.contains?(type, "invalid-challenge")
        refute String.contains?(type, "credential-mismatch")
      end
    end
  end
end
