defmodule MPP.Integration.MppDevTest do
  @moduledoc """
  Integration tests against the live mpp.dev/api/ping/paid endpoint.

  These tests verify that our client-side parsing modules (Headers, Challenge,
  Charge) correctly handle real 402 responses from an external MPP server.
  Read-only — no wallet or payment credentials required.

  Run with: mix test --include integration test/mpp/integration/mpp_dev_test.exs
  """

  use ExUnit.Case, async: false

  alias MPP.Challenge
  alias MPP.Headers
  alias MPP.Intents.Charge

  @moduletag :integration

  @endpoint "https://mpp.dev/api/ping/paid"

  # Fetch a fresh 402 response for each test to avoid expiration issues
  setup do
    case Req.get(@endpoint) do
      {:ok, %Req.Response{status: 402} = response} ->
        {:ok, response: response}

      {:ok, %Req.Response{status: status}} ->
        flunk("""
        Expected 402 from #{@endpoint}, got #{status}.

        The mpp.dev/api/ping/paid endpoint may have changed or be temporarily unavailable.
        """)

      {:error, exception} ->
        flunk("""
        Failed to reach #{@endpoint}: #{Exception.message(exception)}

        Ensure you have internet connectivity. This test requires access to mpp.dev.
        """)
    end
  end

  describe "402 response structure" do
    test "returns 402 with correct content type and WWW-Authenticate header", %{response: resp} do
      content_type = Req.Response.get_header(resp, "content-type")

      assert content_type == ["application/problem+json"],
             "Expected application/problem+json, got: #{inspect(content_type)}"

      www_auth = Req.Response.get_header(resp, "www-authenticate")
      assert [header] = www_auth, "Expected exactly one WWW-Authenticate header"
      assert String.starts_with?(header, "Payment "), "WWW-Authenticate must start with 'Payment' scheme"
    end
  end

  describe "challenge parsing" do
    test "Headers.parse_challenge/1 succeeds on live challenge", %{response: resp} do
      [header] = Req.Response.get_header(resp, "www-authenticate")
      assert {:ok, %Challenge{}} = Headers.parse_challenge(header)
    end

    test "parsed challenge has all required fields", %{response: resp} do
      {:ok, challenge} = parse_challenge(resp)

      assert is_binary(challenge.id) and byte_size(challenge.id) > 0, "Challenge ID must be a non-empty string"
      assert is_binary(challenge.realm) and byte_size(challenge.realm) > 0, "Realm must be a non-empty string"
      assert is_binary(challenge.method) and byte_size(challenge.method) > 0, "Method must be a non-empty string"
      assert is_binary(challenge.intent) and byte_size(challenge.intent) > 0, "Intent must be a non-empty string"
      assert is_binary(challenge.request) and byte_size(challenge.request) > 0, "Request must be a non-empty string"
    end

    test "challenge has valid method, intent, and realm", %{response: resp} do
      {:ok, challenge} = parse_challenge(resp)

      # Protocol invariants: method and intent must be known strings, realm must be non-empty
      assert challenge.method in ["tempo", "stripe", "lightning"],
             "Unexpected method: #{challenge.method}"

      assert challenge.intent == "charge"
      assert is_binary(challenge.realm) and byte_size(challenge.realm) > 0
    end

    test "challenge expires in the future (within ~5 minutes)", %{response: resp} do
      {:ok, challenge} = parse_challenge(resp)

      assert is_binary(challenge.expires), "Expected expires field"
      assert {:ok, expires_dt, _offset} = DateTime.from_iso8601(challenge.expires)

      now = DateTime.utc_now()
      assert DateTime.after?(expires_dt, now), "Challenge should not be expired yet"

      # Should expire within ~6 minutes (5 min window + network tolerance)
      max_expiry_seconds = 360
      diff_seconds = DateTime.diff(expires_dt, now, :second)
      assert diff_seconds <= max_expiry_seconds, "Challenge expires too far in the future: #{diff_seconds}s"
    end
  end

  describe "charge request decoding" do
    test "request field decodes to valid Charge intent", %{response: resp} do
      {:ok, challenge} = parse_challenge(resp)
      {:ok, charge} = decode_charge_request(challenge)

      assert %Charge{} = charge
      assert byte_size(charge.amount) > 0
      assert is_binary(charge.currency) and byte_size(charge.currency) > 0
    end

    test "charge has Tempo-specific method details", %{response: resp} do
      {:ok, challenge} = parse_challenge(resp)
      {:ok, charge} = decode_charge_request(challenge)

      assert is_map(charge.method_details), "Expected methodDetails map"
      assert Map.has_key?(charge.method_details, "chainId"), "Expected chainId in methodDetails"
      assert is_integer(charge.method_details["chainId"]), "chainId must be an integer"
    end

    test "charge has a recipient address", %{response: resp} do
      {:ok, challenge} = parse_challenge(resp)
      {:ok, charge} = decode_charge_request(challenge)

      assert is_binary(charge.recipient), "Expected recipient address"
      assert String.starts_with?(charge.recipient, "0x"), "Recipient should be an Ethereum-style address"
    end
  end

  describe "RFC 9457 error body" do
    test "body contains required problem detail fields", %{response: resp} do
      body = resp.body

      assert is_map(body), "Expected JSON body"
      assert Map.has_key?(body, "type"), "Missing 'type' field"
      assert Map.has_key?(body, "title"), "Missing 'title' field"
      assert Map.has_key?(body, "status"), "Missing 'status' field"
      assert Map.has_key?(body, "detail"), "Missing 'detail' field"
    end

    test "problem type matches payment-required", %{response: resp} do
      body = resp.body

      assert body["type"] == "https://paymentauth.org/problems/payment-required"
      assert body["title"] == "Payment Required"
      assert body["status"] == 402
    end

    test "challengeId matches WWW-Authenticate id", %{response: resp} do
      {:ok, challenge} = parse_challenge(resp)
      body = resp.body

      assert body["challengeId"] == challenge.id,
             "Body challengeId (#{body["challengeId"]}) should match header id (#{challenge.id})"
    end
  end

  # Parses the challenge from the WWW-Authenticate header
  defp parse_challenge(resp) do
    [header] = Req.Response.get_header(resp, "www-authenticate")
    Headers.parse_challenge(header)
  end

  # Decodes the base64url request field into a Charge struct
  defp decode_charge_request(challenge) do
    with {:ok, json} <- Base.url_decode64(challenge.request, padding: false),
         {:ok, map} <- Jason.decode(json) do
      Charge.from_request(map)
    else
      :error -> {:error, :invalid_base64}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
      {:error, reason} -> {:error, reason}
    end
  end
end
