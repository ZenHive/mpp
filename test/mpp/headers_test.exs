defmodule MPP.HeadersTest do
  use ExUnit.Case, async: true

  alias MPP.Challenge
  alias MPP.Credential
  alias MPP.Headers
  alias MPP.Receipt

  @secret "test-secret-key"

  defp make_challenge(opts \\ []) do
    defaults = [realm: "api.example.com", method: "stripe", intent: "charge", request: "eyJhbW91bnQiOiIxMDAifQ"]
    Challenge.create(Keyword.merge(defaults, opts), @secret)
  end

  defp make_credential(opts \\ []) do
    challenge = make_challenge(opts)

    %Credential{
      challenge: challenge,
      payload: %{"spt" => "spt_abc123"},
      source: nil
    }
  end

  defp make_receipt do
    Receipt.new(method: "stripe", reference: "pi_abc123", timestamp: "2025-01-15T12:00:00Z")
  end

  describe "format_challenge/1" do
    test "formats required fields only" do
      challenge = make_challenge()
      header = Headers.format_challenge(challenge)

      assert String.starts_with?(header, "Payment ")
      assert header =~ ~r/id="[^"]+"/
      assert header =~ ~s(realm="api.example.com")
      assert header =~ ~s(method="stripe")
      assert header =~ ~s(intent="charge")
      assert header =~ ~s(request="eyJhbW91bnQiOiIxMDAifQ")
      refute header =~ "expires="
      refute header =~ "digest="
      refute header =~ "description="
      refute header =~ "opaque="
    end

    test "includes optional fields when present" do
      challenge = make_challenge(expires: "2025-01-15T12:05:00Z", description: "Test payment")
      header = Headers.format_challenge(challenge)

      assert header =~ ~s(expires="2025-01-15T12:05:00Z")
      assert header =~ ~s(description="Test payment")
    end

    test "escapes quotes in values" do
      challenge = make_challenge(description: ~s(A "quoted" value))
      header = Headers.format_challenge(challenge)

      assert header =~ ~s(description="A \\"quoted\\" value")
    end

    test "escapes backslashes in values" do
      challenge = make_challenge(description: ~s(path\\to\\file))
      header = Headers.format_challenge(challenge)

      assert header =~ ~s(description="path\\\\to\\\\file")
    end

    test "raises on CR/LF in values to prevent invalid header text" do
      challenge = make_challenge(description: "line1\r\nInjected: x")

      assert_raise ArgumentError, ~r/CR\/LF/, fn ->
        Headers.format_challenge(challenge)
      end
    end
  end

  describe "parse_challenge/1" do
    test "parses a formatted challenge (roundtrip)" do
      original = make_challenge()
      header = Headers.format_challenge(original)
      assert {:ok, parsed} = Headers.parse_challenge(header)

      assert parsed.id == original.id
      assert parsed.realm == original.realm
      assert parsed.method == original.method
      assert parsed.intent == original.intent
      assert parsed.request == original.request
    end

    test "roundtrip preserves all optional fields" do
      original =
        make_challenge(
          expires: "2025-01-15T12:05:00Z",
          digest: "sha-256=abc123",
          description: "Test payment",
          opaque: "eyJjb3JyZWxhdGlvbiI6IjEyMyJ9"
        )

      header = Headers.format_challenge(original)
      assert {:ok, parsed} = Headers.parse_challenge(header)

      assert parsed.expires == original.expires
      assert parsed.digest == original.digest
      assert parsed.description == original.description
      assert parsed.opaque == original.opaque
    end

    test "roundtrip preserves escaped quotes in description" do
      original = make_challenge(description: ~s(Say "hello"))
      header = Headers.format_challenge(original)
      assert {:ok, parsed} = Headers.parse_challenge(header)

      assert parsed.description == ~s(Say "hello")
    end

    test "roundtrip preserves escaped backslashes" do
      original = make_challenge(description: ~s(path\\here))
      header = Headers.format_challenge(original)
      assert {:ok, parsed} = Headers.parse_challenge(header)

      assert parsed.description == ~s(path\\here)
    end

    test "case-insensitive scheme matching" do
      challenge = make_challenge()
      header = Headers.format_challenge(challenge)

      # Replace "Payment" with different cases
      for scheme <- ["payment", "PAYMENT", "pAyMeNt"] do
        modified = String.replace(header, "Payment", scheme, global: false)
        assert {:ok, _} = Headers.parse_challenge(modified)
      end
    end

    test "handles extra whitespace" do
      challenge = make_challenge()
      header = Headers.format_challenge(challenge)

      # Add leading whitespace
      assert {:ok, _} = Headers.parse_challenge("  " <> header)
    end

    test "rejects non-Payment scheme" do
      assert {:error, :invalid_scheme} = Headers.parse_challenge(~s(Bearer token="abc"))
    end

    test "rejects missing required params" do
      assert {:error, :missing_required_params} =
               Headers.parse_challenge(~s(Payment id="abc", realm="test"))
    end

    test "rejects duplicate params" do
      assert {:error, :duplicate_param} =
               Headers.parse_challenge(~s(Payment id="a", realm="b", method="c", intent="d", request="e", id="f"))
    end

    test "rejects unknown params" do
      assert {:error, :invalid_auth_params} =
               Headers.parse_challenge(~s(Payment id="a", realm="b", method="c", intent="d", request="e", unknown="x"))
    end

    test "rejects scheme-only input with no params" do
      assert {:error, :invalid_scheme} = Headers.parse_challenge("Payment")
    end

    test "rejects param without equals sign" do
      assert {:error, :invalid_auth_params} =
               Headers.parse_challenge(~s(Payment id="a", realm="b", method="c", intent="d", request="e", opaque))
    end

    test "rejects unterminated quoted string" do
      assert {:error, :invalid_auth_params} =
               Headers.parse_challenge(~s(Payment id="unterminated))
    end

    test "handles generic backslash escape in quoted string" do
      # \x should be parsed as literal x (generic escape)
      header = ~s(Payment id="a\\x", realm="b", method="c", intent="d", request="e")
      assert {:ok, parsed} = Headers.parse_challenge(header)
      assert parsed.id == "ax"
    end

    test "rejects bare newline in quoted string" do
      assert {:error, :invalid_auth_params} =
               Headers.parse_challenge(~s(Payment id="a\nb", realm="x", method="y", intent="z", request="w"))
    end

    test "rejects CRLF in quoted values (header injection)" do
      assert {:error, :invalid_auth_params} =
               Headers.parse_challenge(
                 ~s(Payment id="a\r\nInjected: header", realm="b", method="c", intent="d", request="e")
               )
    end

    test "parses unquoted token values" do
      header = ~s(Payment id=abc, realm=test.com, method=stripe, intent=charge, request=eyJ0ZXN0Ijp0cnVlfQ)
      assert {:ok, parsed} = Headers.parse_challenge(header)
      assert parsed.id == "abc"
      assert parsed.realm == "test.com"
    end
  end

  describe "format_credential/1" do
    test "produces Payment scheme prefix" do
      credential = make_credential()
      header = Headers.format_credential(credential)

      assert String.starts_with?(header, "Payment ")
      # Rest should be valid base64url
      "Payment " <> rest = header
      assert {:ok, _} = Base.url_decode64(rest, padding: false)
    end
  end

  describe "parse_credential/1" do
    test "roundtrip format → parse" do
      original = make_credential()
      header = Headers.format_credential(original)
      assert {:ok, parsed} = Headers.parse_credential(header)

      assert parsed.challenge.realm == original.challenge.realm
      assert parsed.challenge.method == original.challenge.method
      assert parsed.payload == original.payload
    end

    test "case-insensitive scheme" do
      credential = make_credential()
      header = Headers.format_credential(credential)
      modified = String.replace(header, "Payment", "payment", global: false)

      assert {:ok, _} = Headers.parse_credential(modified)
    end

    test "rejects non-Payment scheme" do
      assert {:error, :invalid_scheme} = Headers.parse_credential("Bearer eyJhbGciOiJIUzI1NiJ9")
    end

    test "rejects invalid base64url body" do
      assert {:error, :invalid_base64} = Headers.parse_credential("Payment !!!invalid!!!")
    end

    test "rejects invalid JSON body" do
      encoded = Base.url_encode64("not json", padding: false)
      assert {:error, :invalid_json} = Headers.parse_credential("Payment #{encoded}")
    end
  end

  describe "format_receipt/1" do
    test "produces bare base64url (no scheme prefix)" do
      receipt = make_receipt()
      header = Headers.format_receipt(receipt)

      refute String.starts_with?(header, "Payment")
      assert {:ok, _} = Base.url_decode64(header, padding: false)
    end
  end

  describe "parse_receipt/1" do
    test "roundtrip format → parse" do
      original = make_receipt()
      header = Headers.format_receipt(original)
      assert {:ok, parsed} = Headers.parse_receipt(header)

      assert parsed.method == original.method
      assert parsed.reference == original.reference
      assert parsed.status == "success"
      assert parsed.timestamp == original.timestamp
    end

    test "handles leading/trailing whitespace" do
      receipt = make_receipt()
      header = Headers.format_receipt(receipt)
      assert {:ok, _} = Headers.parse_receipt("  #{header}  ")
    end

    test "rejects invalid base64url" do
      assert {:error, :invalid_base64} = Headers.parse_receipt("!!!invalid!!!")
    end
  end

  describe "HMAC verification through headers" do
    test "parsed challenge verifies against original secret" do
      original = make_challenge()
      header = Headers.format_challenge(original)
      {:ok, parsed} = Headers.parse_challenge(header)

      assert :ok = Challenge.verify(parsed, @secret)
    end

    test "parsed challenge fails with wrong secret" do
      original = make_challenge()
      header = Headers.format_challenge(original)
      {:ok, parsed} = Headers.parse_challenge(header)

      assert {:error, :invalid_challenge} = Challenge.verify(parsed, "wrong-secret")
    end
  end
end
