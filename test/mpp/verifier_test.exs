defmodule MPP.VerifierTest do
  use ExUnit.Case, async: true

  alias MPP.Challenge
  alias MPP.Credential
  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.JCS
  alias MPP.Receipt
  alias MPP.Verifier

  # --- Mock Methods (no Plug dependency) ---

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
    def method_name, do: "mock_unexpected"

    @impl MPP.Method
    def verify(_payload, _charge) do
      {:error, :some_unknown_reason}
    end
  end

  # --- Test Helpers ---

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

  defp build_credential(opts \\ []) do
    charge = Keyword.get(opts, :charge, build_charge())
    secret = Keyword.get(opts, :secret_key, @secret_key)
    realm = Keyword.get(opts, :realm, @realm)
    method_name = Keyword.get(opts, :method_name, "mock")
    payload = Keyword.get(opts, :payload, %{"proof" => "valid"})
    expires = Keyword.get(opts, :expires, nil)

    params =
      then(
        [
          realm: realm,
          method: method_name,
          intent: "charge",
          request: encode_request(charge)
        ],
        fn p -> if expires, do: Keyword.put(p, :expires, expires), else: p end
      )

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

  # --- Tests ---

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
    end
  end

  describe "verify/2 method mismatch" do
    test "credential for different method returns invalid_challenge" do
      # Credential was created for "mock" method, but we verify with MockMethodUnexpected ("mock_unexpected")
      credential = build_credential(method_name: "mock")
      opts = verify_opts(method: MockMethodUnexpected)

      assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
      assert String.contains?(error.type, "invalid-challenge")
      assert String.contains?(error.detail, "Credential method does not match")
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
        request: request
      ]

      challenge = Challenge.create(params, @secret_key)
      credential = %Credential{challenge: challenge, payload: %{"proof" => "valid"}}
      opts = verify_opts()

      assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
      assert String.contains?(error.type, "invalid-challenge")
      assert String.contains?(error.detail, "intent does not match")
    end
  end

  describe "verify/2 realm mismatch" do
    test "different realm returns invalid_challenge" do
      credential = build_credential()
      opts = verify_opts(realm: "other.realm.com")

      assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
      assert String.contains?(error.type, "invalid-challenge")
      assert String.contains?(error.detail, "Request parameters do not match")
    end
  end

  describe "verify/2 expiration" do
    test "expired challenge returns payment_expired" do
      expired = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
      credential = build_credential(expires: expired)
      opts = verify_opts()

      assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
      assert String.contains?(error.type, "payment-expired")
    end

    test "malformed expires returns payment_expired" do
      credential = build_credential(expires: "not-a-date")
      opts = verify_opts()

      assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
      assert String.contains?(error.type, "payment-expired")
    end

    test "non-expired challenge passes" do
      future = DateTime.utc_now() |> DateTime.add(300, :second) |> DateTime.to_iso8601()
      credential = build_credential(expires: future)
      opts = verify_opts()

      assert {:ok, %Receipt{}} = Verifier.verify(credential, opts)
    end

    test "nil expires passes" do
      credential = build_credential()
      assert credential.challenge.expires == nil

      assert {:ok, %Receipt{}} = Verifier.verify(credential, verify_opts())
    end
  end

  describe "verify/2 request mismatch" do
    test "wrong amount returns invalid_challenge" do
      credential = build_credential()
      opts = verify_opts(charge: build_charge(amount: "2000"))

      assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
      assert String.contains?(error.type, "invalid-challenge")
    end

    test "wrong currency returns invalid_challenge" do
      credential = build_credential()
      opts = verify_opts(charge: build_charge(currency: "eur"))

      assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
      assert String.contains?(error.type, "invalid-challenge")
    end

    test "wrong recipient returns invalid_challenge" do
      charge = build_charge(recipient: "acct_123")
      credential = build_credential(charge: charge)
      opts = verify_opts(charge: build_charge(recipient: "acct_456"))

      assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
      assert String.contains?(error.type, "invalid-challenge")
    end

    test "different description prevents cross-route replay" do
      charge_a = build_charge(description: "Service A")
      charge_b = build_charge(description: "Service B")
      credential = build_credential(charge: charge_a)
      opts = verify_opts(charge: charge_b)

      assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
      assert String.contains?(error.type, "invalid-challenge")
    end

    test "different method_details prevents cross-route replay" do
      charge_a = build_charge(method_details: %{"networkId" => "mainnet"})
      charge_b = build_charge(method_details: %{"networkId" => "testnet"})
      credential = build_credential(charge: charge_a)
      opts = verify_opts(charge: charge_b)

      assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
      assert String.contains?(error.type, "invalid-challenge")
    end

    test "credential with recipient rejected on endpoint without recipient" do
      charge_with = build_charge(recipient: "acct_123")
      charge_without = build_charge()
      credential = build_credential(charge: charge_with)
      opts = verify_opts(charge: charge_without)

      assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
      assert String.contains?(error.type, "invalid-challenge")
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
      credential = build_credential(method_name: "mock_unexpected")
      opts = verify_opts(method: MockMethodUnexpected)

      assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
      assert String.contains?(error.type, "verification-failed")
      assert String.contains?(error.detail, "some_unknown_reason")
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
        request: malformed_request
      ]

      challenge = Challenge.create(params, @secret_key)
      credential = %Credential{challenge: challenge, payload: %{"proof" => "valid"}}
      opts = verify_opts()

      assert {:error, %Errors{} = error} = Verifier.verify(credential, opts)
      assert String.contains?(error.type, "invalid-challenge")
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
end
