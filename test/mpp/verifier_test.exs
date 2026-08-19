defmodule MPP.VerifierTest do
  use ExUnit.Case, async: true

  alias MPP.Challenge
  alias MPP.Credential
  alias MPP.Errors
  # --- Mock Methods (no Plug dependency) ---
  alias MPP.Intents.Charge
  alias MPP.JCS
  alias MPP.Methods.Stripe
  alias MPP.Receipt
  alias MPP.Verifier

  defmodule MockMethod do
    @moduledoc false
    use MPP.Method

    @impl MPP.Method
    def method_name, do: "mock"

    @impl MPP.Method
    def verify(%{"proof" => "valid"}, charge) do
      {:ok, Receipt.new(method: method_name(), reference: "ref_#{charge.amount}")}
    end

    @impl MPP.Method
    def verify(%{"proof" => "invalid"}, _charge) do
      {:error, Errors.new(:verification_failed, "Invalid proof")}
    end

    @impl MPP.Method
    def verify(_payload, _charge) do
      {:error, Errors.new(:invalid_payload, "Missing proof field")}
    end
  end

  defmodule MockMethodUnexpected do
    @moduledoc false
    use MPP.Method

    @impl MPP.Method
    def method_name, do: "mockunexpected"

    @impl MPP.Method
    def verify(_payload, _charge) do
      {:error, :some_unknown_reason}
    end
  end

  defmodule MockHashMethod do
    @moduledoc false
    use MPP.Method

    @impl MPP.Method
    def method_name, do: "mockhash"

    @impl MPP.Method
    def credential_types, do: ["hash"]

    @impl MPP.Method
    def verify(%{"type" => "hash", "hash" => hash}, _charge) when is_binary(hash) do
      {:ok, Receipt.new(method: method_name(), reference: hash)}
    end

    def verify(_payload, _charge) do
      {:error, Errors.new(:invalid_payload, "Expected hash payload")}
    end
  end

  defmodule MockTransactionMethod do
    @moduledoc false
    use MPP.Method

    @impl MPP.Method
    def method_name, do: "mocktx"

    @impl MPP.Method
    # --- Test Helpers ---
    def credential_types, do: ["transaction"]

    @impl MPP.Method
    def verify(%{"type" => "transaction"}, _charge) do
      {:ok, Receipt.new(method: method_name(), reference: "tx-ok")}
    end

    def verify(_payload, _charge) do
      {:error, Errors.new(:invalid_payload, "Expected transaction payload")}
    end
  end

  @secret_key "test-secret-key-for-verifier"
  @realm "api.test.com"

  defp build_charge(overrides \\ []) do
    opts =
      Keyword.merge(
        [amount: "1000", currency: "usd"],
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

  defp build_credential(opts \\ []) do
    charge = Keyword.get(opts, :charge, build_charge())
    secret = Keyword.get(opts, :secret_key, @secret_key)
    realm = Keyword.get(opts, :realm, @realm)
    method_name = Keyword.get(opts, :method_name, "mock")
    payload = Keyword.get(opts, :payload, %{"proof" => "valid"})
    expires = Keyword.get(opts, :expires, future_expires())
    digest = Keyword.get(opts, :digest, nil)
    opaque = Keyword.get(opts, :opaque, nil)

    params =
      [
        realm: realm,
        method: method_name,
        intent: "charge",
        request: encode_request(charge)
      ]
      |> then(fn p -> if expires, do: Keyword.put(p, :expires, expires), else: p end)
      |> then(fn p -> if digest, do: Keyword.put(p, :digest, digest), else: p end)
      |> then(fn p -> if opaque, do: Keyword.put(p, :opaque, opaque), else: p end)

    # --- Tests ---
    challenge = Challenge.create(params, secret)
    %Credential{challenge: challenge, payload: payload}
  end

  defp verify_opts(overrides \\ []) do
    Keyword.merge(
      [
        secret_key: @secret_key,
        realm: @realm,
        method: MockMethod,
        charge: build_charge()
      ],
      overrides
    )
  end

  describe "verify/2 success" do
    test "valid credential returns receipt" do
      credential = build_credential()
      opts = verify_opts()

      assert {:ok, %Receipt{} = receipt} = Verifier.verify(credential, opts)
      assert receipt.method == "mock"
      assert receipt.reference == "ref_1000"
    end

    test "with method_config merges into charge" do
      credential = build_credential()
      opts = verify_opts(method_config: %{"extra" => "data"})

      assert {:ok, %Receipt{}} = Verifier.verify(credential, opts)
    end

    test "with recipient configured and matching" do
      charge = build_charge(recipient: "acct_123")
      credential = build_credential(charge: charge)
      opts = verify_opts(charge: charge)

      assert {:ok, %Receipt{}} = Verifier.verify(credential, opts)
    end

    test "credential and endpoint with matching nil recipient" do
      charge = build_charge()
      credential = build_credential(charge: charge)
      opts = verify_opts(charge: charge)

      assert {:ok, %Receipt{}} = Verifier.verify(credential, opts)
    end
  end

  describe "verify/2 HMAC failure" do
    test "wrong secret key returns invalid_challenge" do
      credential = build_credential()
      opts = verify_opts(secret_key: "wrong-secret")

      assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
      assert error.status == 402
      assert String.contains?(error.type, "invalid-challenge")
      refute String.contains?(error.type, "credential-mismatch")
    end
  end

  describe "verify/2 method mismatch" do
    test "credential for different method returns credential_mismatch" do
      # Credential was created for "mock" method, but we verify with MockMethodUnexpected ("mockunexpected")
      credential = build_credential(method_name: "mock")
      opts = verify_opts(method: MockMethodUnexpected)

      assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
      assert String.contains?(error.type, "credential-mismatch")
      assert String.contains?(error.detail, "does not match this route's requirements")
    end
  end

  describe "verify/2 intent mismatch" do
    test "session intent credential rejected on charge endpoint" do
      # Build a credential with intent: "session" instead of "charge"
      charge = build_charge()
      request = encode_request(charge)

      params = [
        realm: @realm,
        method: "mock",
        intent: "session",
        request: request,
        expires: future_expires()
      ]

      challenge = Challenge.create(params, @secret_key)
      credential = %Credential{challenge: challenge, payload: %{"proof" => "valid"}}
      opts = verify_opts()

      assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
      assert String.contains?(error.type, "credential-mismatch")
      assert String.contains?(error.detail, "intent 'session'")
    end
  end

  describe "verify/2 realm mismatch" do
    test "tampered echoed realm returns credential_mismatch (Tier-2, HMAC uses server realm)" do
      credential = build_credential()
      tampered = %{credential | challenge: %{credential.challenge | realm: "other.realm.com"}}
      opts = verify_opts()

      assert {:error, %Errors{} = error} = Verifier.verify(tampered, opts)
      assert String.contains?(error.type, "credential-mismatch")
      assert String.contains?(error.detail, "realm 'other.realm.com'")
    end
  end

  describe "verify/2 expiration" do
    test "expired challenge returns payment_expired" do
      expired = DateTime.utc_now() |> DateTime.shift(minute: -1) |> DateTime.to_iso8601()
      credential = build_credential(expires: expired)
      opts = verify_opts()

      assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
      assert String.contains?(error.type, "payment-expired")
    end

    test "malformed expires is distinguished from expired (credential_mismatch, not payment_expired)" do
      credential = build_credential(expires: "not-a-date")
      opts = verify_opts()

      assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
      assert String.contains?(error.type, "credential-mismatch")
      refute String.contains?(error.type, "payment-expired")
      assert String.contains?(error.detail, "ISO 8601")
    end

    test "non-expired challenge passes" do
      future = DateTime.utc_now() |> DateTime.shift(minute: 5) |> DateTime.to_iso8601()
      credential = build_credential(expires: future)
      opts = verify_opts()

      assert {:ok, %Receipt{}} = Verifier.verify(credential, opts)
    end

    test "nil expires returns credential_mismatch" do
      charge = build_charge()

      challenge =
        Challenge.create(
          [
            realm: @realm,
            method: "mock",
            intent: "charge",
            request: encode_request(charge)
          ],
          @secret_key
        )

      credential = %Credential{challenge: challenge, payload: %{"proof" => "valid"}}
      assert credential.challenge.expires == nil

      assert {:error, %Errors{} = error} = Verifier.verify(credential, verify_opts(charge: charge))
      assert String.contains?(error.type, "credential-mismatch")
      assert String.contains?(error.detail, "expires")
    end
  end

  describe "verify/2 request mismatch" do
    test "wrong amount returns credential_mismatch" do
      credential = build_credential()
      opts = verify_opts(charge: build_charge(amount: "2000"))

      assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
      assert String.contains?(error.type, "credential-mismatch")
    end

    test "wrong currency returns credential_mismatch" do
      credential = build_credential()
      opts = verify_opts(charge: build_charge(currency: "eur"))

      assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
      assert String.contains?(error.type, "credential-mismatch")
    end

    test "wrong recipient returns credential_mismatch" do
      charge = build_charge(recipient: "acct_123")
      credential = build_credential(charge: charge)
      opts = verify_opts(charge: build_charge(recipient: "acct_456"))

      assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
      assert String.contains?(error.type, "credential-mismatch")
    end

    test "different description prevents cross-route replay" do
      charge_a = build_charge(description: "Service A")
      charge_b = build_charge(description: "Service B")
      credential = build_credential(charge: charge_a)
      opts = verify_opts(charge: charge_b)

      assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
      assert String.contains?(error.type, "credential-mismatch")
    end

    test "different method_details prevents cross-route replay" do
      charge_a = build_charge(method_details: %{"networkId" => "mainnet"})
      charge_b = build_charge(method_details: %{"networkId" => "testnet"})
      credential = build_credential(charge: charge_a)
      opts = verify_opts(charge: charge_b)

      assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
      assert String.contains?(error.type, "credential-mismatch")
    end

    test "credential with recipient rejected on endpoint without recipient" do
      charge_with = build_charge(recipient: "acct_123")
      charge_without = build_charge()
      credential = build_credential(charge: charge_with)
      opts = verify_opts(charge: charge_without)

      assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
      assert String.contains?(error.type, "credential-mismatch")
    end
  end

  describe "verify/2 opaque mismatch" do
    test "matching opaque passes" do
      opaque = "eyJyb3V0ZSI6ImEifQ"
      credential = build_credential(opaque: opaque)
      opts = verify_opts(opaque: opaque)

      assert {:ok, %Receipt{}} = Verifier.verify(credential, opts)
    end

    test "credential opaque rejected when endpoint has none" do
      credential = build_credential(opaque: "eyJyb3V0ZSI6ImEifQ")
      opts = verify_opts()

      assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
      assert String.contains?(error.type, "credential-mismatch")
      assert String.contains?(error.detail, "opaque")
    end

    test "missing credential opaque rejected when endpoint expects opaque" do
      credential = build_credential()
      opts = verify_opts(opaque: "eyJyb3V0ZSI6ImEifQ")

      assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
      assert String.contains?(error.type, "credential-mismatch")
      assert String.contains?(error.detail, "opaque")
    end

    test "wrong opaque rejected" do
      credential = build_credential(opaque: "eyJyb3V0ZSI6ImEifQ")
      opts = verify_opts(opaque: "eyJyb3V0ZSI6ImIifQ")

      assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
      assert String.contains?(error.type, "credential-mismatch")
      assert String.contains?(error.detail, "opaque")
    end
  end

  describe "verify/2 digest mismatch" do
    test "matching digest passes" do
      digest = "sha-256=X48E9qOokqqrvdts8nOJRJN3OWDUoyWxBf7kbu9DBPE"
      credential = build_credential(digest: digest)
      opts = verify_opts(digest: digest)

      assert {:ok, %Receipt{}} = Verifier.verify(credential, opts)
    end

    test "credential digest rejected when endpoint has none" do
      credential = build_credential(digest: "sha-256=X48E9qOokqqrvdts8nOJRJN3OWDUoyWxBf7kbu9DBPE")
      opts = verify_opts()

      assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
      assert String.contains?(error.type, "credential-mismatch")
      assert String.contains?(error.detail, "digest")
    end

    test "wrong digest rejected" do
      credential = build_credential(digest: "sha-256=X48E9qOokqqrvdts8nOJRJN3OWDUoyWxBf7kbu9DBPE")
      opts = verify_opts(digest: "sha-256=Y48E9qOokqqrvdts8nOJRJN3OWDUoyWxBf7kbu9DBPE")

      assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
      assert String.contains?(error.type, "credential-mismatch")
      assert String.contains?(error.detail, "digest")
    end
  end

  describe "verify/2 method verification failure" do
    test "method returns structured error" do
      credential = build_credential(payload: %{"proof" => "invalid"})
      opts = verify_opts()

      assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
      assert String.contains?(error.type, "verification-failed")
    end

    test "method returns missing payload error" do
      credential = build_credential(payload: %{})
      opts = verify_opts()

      assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
      assert String.contains?(error.type, "invalid-payload")
    end

    test "method returns unexpected error atom" do
      credential = build_credential(method_name: "mockunexpected")
      opts = verify_opts(method: MockMethodUnexpected)

      assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
      assert String.contains?(error.type, "verification-failed")
      assert error.detail == "Payment verification failed"
      refute error.detail =~ "some_unknown_reason"
    end
  end

  describe "verify/2 malformed request payload" do
    test "non-map JSON in challenge request returns structured error" do
      # Craft a credential where the request field is base64url("[]") — valid JSON but not a map
      malformed_request = Base.url_encode64("[]", padding: false)

      params = [
        realm: @realm,
        method: "mock",
        intent: "charge",
        request: malformed_request,
        expires: future_expires()
      ]

      challenge = Challenge.create(params, @secret_key)
      credential = %Credential{challenge: challenge, payload: %{"proof" => "valid"}}
      opts = verify_opts()

      assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
      assert String.contains?(error.type, "credential-mismatch")
    end
  end

  describe "verify/2 required opts validation" do
    test "missing secret_key raises" do
      credential = build_credential()
      opts = Keyword.delete(verify_opts(), :secret_key)

      assert_raise ArgumentError, ~r/secret_key/, fn ->
        Verifier.verify(credential, opts)
      end
    end

    test "missing realm raises" do
      credential = build_credential()
      opts = Keyword.delete(verify_opts(), :realm)

      assert_raise ArgumentError, ~r/realm/, fn ->
        Verifier.verify(credential, opts)
      end
    end

    test "missing method raises" do
      credential = build_credential()
      opts = Keyword.delete(verify_opts(), :method)

      assert_raise ArgumentError, ~r/method/, fn ->
        Verifier.verify(credential, opts)
      end
    end

    test "missing charge raises" do
      credential = build_credential()
      opts = Keyword.delete(verify_opts(), :charge)

      assert_raise ArgumentError, ~r/charge/, fn ->
        Verifier.verify(credential, opts)
      end
    end
  end

  describe "verify/2 hash credential type" do
    # mpp-rs PaymentPayload hash vector (refs/mpp-rs/src/protocol/core/challenge.rs)
    @mpp_rs_hash %{"type" => "hash", "hash" => "0xdef123"}
    # mppx Tempo Methods.test.ts `schema: validates hash payload`
    @mppx_hash %{
      "type" => "hash",
      "hash" => "0x1a2b3c4d5e6f7890abcdef1234567890abcdef1234567890abcdef1234567890"
    }

    test "accepts the mpp-rs hash vector on a hash-capable method" do
      credential = build_credential(method_name: "mockhash", payload: @mpp_rs_hash)
      opts = verify_opts(method: MockHashMethod)

      assert {:ok, %Receipt{method: "mockhash", reference: "0xdef123"}} =
               Verifier.verify(credential, opts)
    end

    test "accepts the mppx Tempo hash vector on a hash-capable method" do
      credential = build_credential(method_name: "mockhash", payload: @mppx_hash)
      opts = verify_opts(method: MockHashMethod)

      assert {:ok, %Receipt{reference: "0x1a2b3c4d5e6f7890abcdef1234567890abcdef1234567890abcdef1234567890"}} =
               Verifier.verify(credential, opts)
    end

    test "rejects a well-formed hash credential against a method that does not accept hash" do
      credential = build_credential(payload: @mpp_rs_hash)
      opts = verify_opts()

      assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
      assert String.contains?(error.type, "invalid-payload")
      assert error.detail == ~s(type="hash" is not accepted by this payment method)
    end

    test "rejects a well-formed hash credential against Stripe (SPT, not hash)" do
      credential = build_credential(method_name: "stripe", payload: @mpp_rs_hash)
      opts = verify_opts(method: Stripe)

      assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
      assert String.contains?(error.type, "invalid-payload")
      assert error.detail == ~s(type="hash" is not accepted by this payment method)
    end

    test "rejects the mpp-rs hash-with-signature vector as malformed" do
      credential = build_credential(method_name: "mockhash", payload: %{"type" => "hash", "signature" => "0xdef123"})
      opts = verify_opts(method: MockHashMethod)

      assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
      assert String.contains?(error.type, "invalid-payload")
      assert error.detail == "hash payload requires 'hash' field"
    end

    test "rejects type=hash with an empty or non-string hash field" do
      for bad <- [%{"type" => "hash", "hash" => ""}, %{"type" => "hash", "hash" => 1}] do
        credential = build_credential(method_name: "mockhash", payload: bad)
        opts = verify_opts(method: MockHashMethod)

        assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
        assert String.contains?(error.type, "invalid-payload")
        assert error.detail == "hash payload requires 'hash' field"
      end
    end

    test "does not type-gate an untyped payload" do
      untyped = build_credential(payload: %{"proof" => "valid"})
      assert {:ok, %Receipt{}} = Verifier.verify(untyped, verify_opts())
    end

    test "rejects any typed payload whose type the method does not accept" do
      for type <- ["transaction", "proof"] do
        credential = build_credential(payload: %{"type" => type, "signature" => "0xabc"})

        assert {:error, %Errors{} = error} = Verifier.verify(credential, verify_opts())
        assert String.contains?(error.type, "invalid-payload")
        assert error.detail == ~s(type="#{type}" is not accepted by this payment method)
      end
    end

    test "rejects a typed non-hash payload against Stripe (SPT, not typed)" do
      credential = build_credential(method_name: "stripe", payload: %{"type" => "transaction", "signature" => "0xabc"})
      opts = verify_opts(method: Stripe)

      assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
      assert String.contains?(error.type, "invalid-payload")
      assert error.detail == ~s(type="transaction" is not accepted by this payment method)
    end

    test "accepts a typed payload the method declares in credential_types/0" do
      credential = build_credential(method_name: "mocktx", payload: %{"type" => "transaction", "signature" => "0xabc"})
      opts = verify_opts(method: MockTransactionMethod)

      assert {:ok, %Receipt{method: "mocktx", reference: "tx-ok"}} = Verifier.verify(credential, opts)
    end

    test "rejects a payload whose type is not a string" do
      credential = build_credential(payload: %{"type" => 123, "proof" => "valid"})

      assert {:error, %Errors{} = error} = Verifier.verify(credential, verify_opts())
      assert String.contains?(error.type, "invalid-payload")
      assert error.detail == "credential payload 'type' must be a string"
    end
  end
end
