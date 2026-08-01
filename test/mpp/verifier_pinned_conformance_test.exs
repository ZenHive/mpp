defmodule MPP.VerifierPinnedConformanceTest do
  @moduledoc """
  Cross-SDK Tier-2 pinned-field conformance against mpp-rs server charge vectors.

  Source of truth: `refs/mpp-rs/src/server/mpp.rs` (`verify_pinned_fields` and the
  `test_pinned_*` / `test_hmac_tampered_realm_rejected` tests). Each fail-path case
  re-signs the HMAC with the server secret so Tier-1 passes and Tier-2 catches the
  drift — mirroring the Rust test pattern.
  """
  use ExUnit.Case, async: true

  alias MPP.Challenge
  alias MPP.Credential
  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.JCS
  alias MPP.Receipt
  alias MPP.Verifier

  defmodule TempoMock do
    @moduledoc false
    use MPP.Method

    @impl MPP.Method
    def method_name, do: "tempo"

    @impl MPP.Method
    def verify(_payload, _charge), do: {:ok, Receipt.new(method: method_name(), reference: "0xtxhash")}
  end

  @secret "test-secret"
  @realm "MPP Payment"
  @currency "0x20c0000000000000000000000000000000000000"
  @recipient "0x742d35Cc6634C0532925a3b844Bc9e7595f1B0F2"

  defp tempo_charge(overrides \\ []) do
    opts =
      Keyword.merge(
        [
          amount: "100000",
          currency: @currency,
          recipient: @recipient
        ],
        overrides
      )

    {:ok, charge} = Charge.new(opts)
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
    |> DateTime.shift(minute: 5)
    |> DateTime.to_iso8601()
  end

  defp resign_echo(echo_params) do
    Challenge.create(echo_params, @secret)
  end

  defp base_echo_params(charge, overrides \\ []) do
    Keyword.merge(
      [
        realm: @realm,
        method: "tempo",
        intent: "charge",
        request: encode_request(charge),
        expires: future_expires()
      ],
      overrides
    )
  end

  defp credential_from_echo(echo_params, payload \\ %{"tx" => "0xdeadbeef"}) do
    challenge = resign_echo(echo_params)
    %Credential{challenge: challenge, payload: payload}
  end

  defp verify_opts(charge, overrides \\ []) do
    Keyword.merge(
      [
        secret_key: @secret,
        realm: @realm,
        method: TempoMock,
        charge: charge
      ],
      overrides
    )
  end

  defp assert_credential_mismatch(result, field_fragment) do
    assert {:error, %Errors{} = error} = result
    assert String.contains?(error.type, "credential-mismatch")
    assert String.contains?(error.detail, field_fragment)
  end

  describe "mpp-rs happy path (test_pinned_fields_pass_when_matching)" do
    test "matching pinned fields verify successfully" do
      charge = tempo_charge(method_details: %{"chainId" => 42_431})
      credential = credential_from_echo(base_echo_params(charge))

      assert {:ok, %Receipt{reference: "0xtxhash"}} =
               Verifier.verify(credential, verify_opts(charge))
    end
  end

  describe "mpp-rs Tier-2 fail paths (HMAC re-signed, pinning catches drift)" do
    test "currency mismatch (test_pinned_currency_mismatch_rejected)" do
      charge = tempo_charge()
      tampered = tempo_charge(currency: "0xDEAD000000000000000000000000000000000000")
      credential = credential_from_echo(base_echo_params(tampered))

      assert_credential_mismatch(Verifier.verify(credential, verify_opts(charge)), "currency")
    end

    test "recipient mismatch (test_pinned_recipient_mismatch_rejected)" do
      charge = tempo_charge()
      tampered = tempo_charge(recipient: "0xDEAD000000000000000000000000000000000000")
      credential = credential_from_echo(base_echo_params(tampered))

      assert_credential_mismatch(Verifier.verify(credential, verify_opts(charge)), "recipient")
    end

    test "chainId mismatch (test_pinned_chain_id_mismatch_rejected)" do
      charge = tempo_charge(method_details: %{"chainId" => 42_431})
      tampered = tempo_charge(method_details: %{"chainId" => 9999})
      credential = credential_from_echo(base_echo_params(tampered))

      assert_credential_mismatch(Verifier.verify(credential, verify_opts(charge)), "chainId")
    end

    test "chainId missing when required (test_pinned_chain_id_missing_rejected)" do
      charge = tempo_charge(method_details: %{"chainId" => 42_431})
      tampered = tempo_charge()
      credential = credential_from_echo(base_echo_params(tampered))

      assert_credential_mismatch(Verifier.verify(credential, verify_opts(charge)), "chainId")
    end

    test "intent mismatch (test_pinned_intent_mismatch_rejected)" do
      charge = tempo_charge()
      echo_params = base_echo_params(charge, intent: "session")
      credential = credential_from_echo(echo_params)

      assert_credential_mismatch(Verifier.verify(credential, verify_opts(charge)), "intent")
    end

    test "method mismatch (test_pinned_method_mismatch_rejected)" do
      charge = tempo_charge()
      echo_params = base_echo_params(charge, method: "stripe")
      credential = credential_from_echo(echo_params)

      assert_credential_mismatch(Verifier.verify(credential, verify_opts(charge)), "method")
    end

    test "opaque mismatch when endpoint expects opaque (test_pinned_opaque_configured_mismatch_rejected)" do
      route_opaque = Base.url_encode64(~s({"route":"a"}), padding: false)
      other_opaque = Base.url_encode64(~s({"route":"b"}), padding: false)
      charge = tempo_charge()

      credential =
        credential_from_echo(base_echo_params(charge, opaque: other_opaque))

      assert_credential_mismatch(
        Verifier.verify(credential, verify_opts(charge, opaque: route_opaque)),
        "opaque"
      )
    end

    test "opaque absent when endpoint expects opaque (test_pinned_opaque_configured_but_absent_rejected)" do
      route_opaque = Base.url_encode64(~s({"route":"a"}), padding: false)
      charge = tempo_charge()
      credential = credential_from_echo(base_echo_params(charge))

      assert_credential_mismatch(
        Verifier.verify(credential, verify_opts(charge, opaque: route_opaque)),
        "opaque"
      )
    end
  end

  describe "mpp-rs Tier-1 vs Tier-2 error distinction" do
    test "tampered realm without re-sign hits Tier-2 credential_mismatch (test_hmac_tampered_realm_rejected)" do
      charge = tempo_charge()
      challenge = resign_echo(base_echo_params(charge))
      tampered = %{challenge | realm: "evil.example.com"}
      credential = %Credential{challenge: tampered, payload: %{"tx" => "0xdeadbeef"}}

      assert_credential_mismatch(Verifier.verify(credential, verify_opts(charge)), "realm")
    end

    test "wrong secret hits Tier-1 invalid_challenge, not credential_mismatch" do
      charge = tempo_charge()
      credential = credential_from_echo(base_echo_params(charge))

      assert {:error, %Errors{} = error} =
               Verifier.verify(credential, verify_opts(charge, secret_key: "wrong-secret"))

      assert String.contains?(error.type, "invalid-challenge")
      refute String.contains?(error.type, "credential-mismatch")
    end

    test "tampered request without re-sign hits Tier-1 invalid_challenge (test_hmac_tampered_request_rejected)" do
      charge = tempo_charge()
      challenge = resign_echo(base_echo_params(charge))
      tampered = %{challenge | request: encode_request(tempo_charge(amount: "999999"))}
      credential = %Credential{challenge: tampered, payload: %{"tx" => "0xdeadbeef"}}

      assert {:error, %Errors{} = error} = Verifier.verify(credential, verify_opts(charge))
      assert String.contains?(error.type, "invalid-challenge")
    end
  end
end
