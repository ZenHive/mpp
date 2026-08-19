defmodule MPP.HeadersTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

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
    {payload, opts} = Keyword.pop(opts, :payload, %{"spt" => "spt_abc123"})
    challenge = make_challenge(opts)

    %Credential{
      challenge: challenge,
      payload: payload,
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

    test "accepts uppercase and mixed-case auth-param names (RFC 9110 §11.2, mppx #788)" do
      # refs/mppx/src/Challenge.ts:388 `.toLowerCase()`; refs/mppx/src/Challenge.test.ts:568-583.
      # mpp-rs does not lowercase (refs/mpp-rs/src/protocol/core/headers.rs:150); RFC 9110 §11.2
      # ("the name token is matched case-insensitively") breaks the tie.
      original = make_challenge()
      header = Headers.format_challenge(original)

      upper = Regex.replace(~r/\b(id|realm|method|intent|request)=/, header, fn param -> String.upcase(param) end)

      mixed =
        Regex.replace(~r/\b(id|realm|method|intent|request)=/, header, fn <<first, rest::binary>> ->
          <<first - 32, rest::binary>>
        end)

      assert {:ok, from_upper} = Headers.parse_challenge(upper)
      assert {:ok, from_mixed} = Headers.parse_challenge(mixed)
      assert from_upper.id == original.id
      assert from_mixed.id == original.id
      assert from_upper.realm == original.realm
      assert from_mixed.method == original.method
    end

    test "duplicate detection is case-insensitive (id= + ID= -> :duplicate_param)" do
      # refs/mppx/src/Challenge.test.ts:680-682.
      header =
        ~s(Payment id="a", realm="api.example.com", method="stripe", intent="charge", request="eyJ0ZXN0Ijp0cnVlfQ", ID="b")

      assert {:error, :duplicate_param} = Headers.parse_challenge(header)
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
      header = ~s(Payment id="a\\x", realm="b", method="c", intent="d", request="eyJhIjoxfQ")
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

    test "parses unquoted tokens separated by spaces" do
      header = ~s(Payment id=abc realm=test.com method=stripe intent=charge request=eyJ0ZXN0Ijp0cnVlfQ)
      assert {:ok, parsed} = Headers.parse_challenge(header)
      assert parsed.id == "abc"
      assert parsed.realm == "test.com"
      assert parsed.method == "stripe"
    end

    test "parses unquoted tokens separated by tabs" do
      header = "Payment id=abc\trealm=test.com\tmethod=stripe\tintent=charge\trequest=eyJ0ZXN0Ijp0cnVlfQ"
      assert {:ok, parsed} = Headers.parse_challenge(header)
      assert parsed.id == "abc"
      assert parsed.realm == "test.com"
      assert parsed.method == "stripe"
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

  describe "parse_challenges/1" do
    test "parses a single challenge" do
      challenge = make_challenge()
      header = Headers.format_challenge(challenge)
      assert {:ok, [parsed]} = Headers.parse_challenges(header)
      assert parsed.realm == challenge.realm
      assert parsed.method == challenge.method
    end

    test "parses two challenges" do
      c1 = make_challenge(realm: "api.one.com")
      c2 = make_challenge(realm: "api.two.com", method: "tempo")
      header = Headers.format_challenge(c1) <> ", " <> Headers.format_challenge(c2)
      assert {:ok, [p1, p2]} = Headers.parse_challenges(header)
      assert p1.realm == "api.one.com"
      assert p2.realm == "api.two.com"
      assert p2.method == "tempo"
    end

    test "parses three challenges" do
      c1 = make_challenge(realm: "a.com")
      c2 = make_challenge(realm: "b.com", method: "tempo")
      c3 = make_challenge(realm: "c.com", method: "evm")
      header = Enum.map_join([c1, c2, c3], ", ", &Headers.format_challenge/1)
      assert {:ok, parsed} = Headers.parse_challenges(header)
      assert [_, _, _] = parsed
      assert Enum.map(parsed, & &1.realm) == ["a.com", "b.com", "c.com"]
    end

    test "skips non-Payment schemes" do
      challenge = make_challenge()
      header = ~s(Bearer token123, ) <> Headers.format_challenge(challenge)
      assert {:ok, [parsed]} = Headers.parse_challenges(header)
      assert parsed.realm == challenge.realm
    end

    test "skips non-Payment schemes between Payment challenges" do
      c1 = make_challenge(realm: "first.com")
      c2 = make_challenge(realm: "second.com")
      header = Headers.format_challenge(c1) <> ", Basic xyz, " <> Headers.format_challenge(c2)
      assert {:ok, [p1, p2]} = Headers.parse_challenges(header)
      assert p1.realm == "first.com"
      assert p2.realm == "second.com"
    end

    test "case-insensitive scheme matching" do
      c1 = make_challenge(realm: "upper.com")
      c2 = make_challenge(realm: "lower.com")
      h1 = c1 |> Headers.format_challenge() |> String.replace("Payment", "PAYMENT", global: false)
      h2 = c2 |> Headers.format_challenge() |> String.replace("Payment", "payment", global: false)
      header = h1 <> ", " <> h2
      assert {:ok, [p1, p2]} = Headers.parse_challenges(header)
      assert p1.realm == "upper.com"
      assert p2.realm == "lower.com"
    end

    test "handles compact format (no space after comma)" do
      c1 = make_challenge(realm: "one.com")
      c2 = make_challenge(realm: "two.com")
      header = Headers.format_challenge(c1) <> "," <> Headers.format_challenge(c2)
      assert {:ok, [p1, p2]} = Headers.parse_challenges(header)
      assert p1.realm == "one.com"
      assert p2.realm == "two.com"
    end

    test "does not split on Payment inside quoted values" do
      challenge = make_challenge(description: "Payment plan details")
      header = Headers.format_challenge(challenge)
      assert {:ok, [parsed]} = Headers.parse_challenges(header)
      assert parsed.description == "Payment plan details"
    end

    test "does not split on comma + Payment inside quoted values" do
      challenge = make_challenge(description: "Alpha, Payment plan")
      header = Headers.format_challenge(challenge)
      assert {:ok, [parsed]} = Headers.parse_challenges(header)
      assert parsed.description == "Alpha, Payment plan"
    end

    test "does not split on comma + scheme token inside quoted values (multi-challenge)" do
      c1 = make_challenge(realm: "first.com", description: "See terms, Payment required")
      c2 = make_challenge(realm: "second.com")
      header = Headers.format_challenge(c1) <> ", " <> Headers.format_challenge(c2)
      assert {:ok, [p1, p2]} = Headers.parse_challenges(header)
      assert p1.realm == "first.com"
      assert p1.description == "See terms, Payment required"
      assert p2.realm == "second.com"
    end

    test "does not match prefix schemes like Payments or PaymentX" do
      challenge = make_challenge()
      header = ~s(Payments token123, ) <> Headers.format_challenge(challenge)
      assert {:ok, [parsed]} = Headers.parse_challenges(header)
      assert parsed.realm == challenge.realm
    end

    test "returns no_payment_challenges for prefix-only schemes" do
      assert {:error, :no_payment_challenges} = Headers.parse_challenges("Payments token123")
      assert {:error, :no_payment_challenges} = Headers.parse_challenges("PaymentX stuff")
    end

    test "returns error when no Payment schemes found" do
      assert {:error, :no_payment_challenges} = Headers.parse_challenges("Bearer token123")
    end

    test "returns error on empty string" do
      assert {:error, :no_payment_challenges} = Headers.parse_challenges("")
    end

    test "roundtrip preserves HMAC verification" do
      c1 = make_challenge(realm: "hmac.com")
      c2 = make_challenge(realm: "hmac2.com", method: "tempo")
      header = Headers.format_challenge(c1) <> ", " <> Headers.format_challenge(c2)
      assert {:ok, [p1, p2]} = Headers.parse_challenges(header)
      assert :ok = Challenge.verify(p1, @secret)
      assert :ok = Challenge.verify(p2, @secret)
    end

    test "tolerates partial failures — returns only valid challenges" do
      valid = make_challenge(realm: "good.com")
      # A malformed Payment challenge (missing required params)
      header = Headers.format_challenge(valid) <> ~s(, Payment id="x", realm="bad")
      assert {:ok, [parsed]} = Headers.parse_challenges(header)
      assert parsed.realm == "good.com"
    end

    test "errors when all challenges fail to parse" do
      header = ~s(Payment id="x", Payment id="y")
      assert {:error, :missing_required_params} = Headers.parse_challenges(header)
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

  # Token-size DoS cap (mpp-rs #299). The literal mirrors @max_token_len in
  # MPP.Headers; independently re-verified against
  # refs/mpp-rs/src/protocol/core/headers.rs:18 (MAX_TOKEN_LEN = 16 * 1024) and
  # refs/mppx/src/Challenge.ts:10 (maxRequestParameterLength = 16 * 1024).
  @max_token_len 16 * 1024

  describe "token-size cap before decode (DoS, mpp-rs #299)" do
    test "rejects over-limit Authorization: Payment token before decode" do
      token = String.duplicate("A", @max_token_len + 1)
      assert {:error, :token_too_large} = Headers.parse_credential("Payment #{token}")
    end

    test "at-limit Authorization token passes the size gate and reaches decode" do
      # 16384 valid base64url chars clear the gate, decode, then fail as non-JSON —
      # proving the cap let an at-limit token through (it is NOT :token_too_large).
      token = String.duplicate("A", @max_token_len)
      assert {:error, :invalid_json} = Headers.parse_credential("Payment #{token}")
    end

    test "rejects over-limit Payment-Receipt token before decode" do
      token = String.duplicate("A", @max_token_len + 1)
      assert {:error, :token_too_large} = Headers.parse_receipt(token)
    end

    test "at-limit Payment-Receipt token passes the size gate and reaches decode" do
      token = String.duplicate("A", @max_token_len)
      assert {:error, :invalid_json} = Headers.parse_receipt(token)
    end

    test "rejects over-limit WWW-Authenticate request param before building challenge" do
      header = Headers.format_challenge(make_challenge(request: String.duplicate("A", @max_token_len + 1)))
      assert {:error, :request_too_large} = Headers.parse_challenge(header)
    end

    test "parse_challenges rejects over-limit request param" do
      header = Headers.format_challenge(make_challenge(request: String.duplicate("A", @max_token_len + 1)))
      assert {:error, :request_too_large} = Headers.parse_challenges(header)
    end

    test "at-limit WWW-Authenticate request param still parses" do
      # A valid base64url-JSON object whose wire length is exactly @max_token_len,
      # so it clears both the size guard (mpp-rs #299) and the parse-time JSON
      # validation (Task 72). JSON bytes 12_288 (÷3) → base64url-nopad 16_384.
      json = Jason.encode!(%{"a" => String.duplicate("A", 12_280)})
      request = Base.url_encode64(json, padding: false)
      assert byte_size(request) == @max_token_len
      header = Headers.format_challenge(make_challenge(request: request))

      assert {:ok, %Challenge{request: ^request}} = Headers.parse_challenge(header)
    end
  end

  describe "parse_challenge/1 field validation (Task 72)" do
    defp challenge_header(overrides) do
      Headers.format_challenge(make_challenge(overrides))
    end

    test "rejects an empty id" do
      # Challenge.create computes the id, so craft the header directly to force id="".
      header =
        ~s(Payment id="", realm="api.example.com", method="stripe", intent="charge", request="eyJhbW91bnQiOiIxMDAifQ")

      assert {:error, :empty_id} = Headers.parse_challenge(header)
    end

    test "rejects an uppercase method (spec 1*LOWERALPHA)" do
      assert {:error, :invalid_method} = Headers.parse_challenge(challenge_header(method: "Stripe"))
    end

    test "rejects a method with a digit" do
      assert {:error, :invalid_method} = Headers.parse_challenge(challenge_header(method: "x402"))
    end

    test "rejects a method with a dash" do
      assert {:error, :invalid_method} = Headers.parse_challenge(challenge_header(method: "tempo-v2"))
    end

    test "rejects a request that is not base64url-JSON" do
      request = Base.url_encode64("not json", padding: false)
      assert {:error, :invalid_request} = Headers.parse_challenge(challenge_header(request: request))
    end

    test "rejects a request whose JSON is not an object" do
      request = Base.url_encode64(Jason.encode!([1, 2, 3]), padding: false)
      assert {:error, :invalid_request} = Headers.parse_challenge(challenge_header(request: request))
    end

    test "rejects a non-sha-256 digest" do
      assert {:error, :invalid_digest} = Headers.parse_challenge(challenge_header(digest: "sha-512=abc"))
    end

    test "accepts a valid sha-256 digest" do
      assert {:ok, %Challenge{digest: "sha-256=abc123"}} =
               Headers.parse_challenge(challenge_header(digest: "sha-256=abc123"))
    end

    test "rejects a malformed expires timestamp at parse (mpp-rs #377)" do
      # refs/mpp-rs/src/protocol/core/headers.rs:210 (`is_iso8601_timestamp`) and :284
      # (parse-time guard). Distinct from verifier `check_expiration/1`.
      assert {:error, :invalid_expires} =
               Headers.parse_challenge(challenge_header(expires: "not-a-date"))
    end

    test "rejects a date-only expires value" do
      assert {:error, :invalid_expires} =
               Headers.parse_challenge(challenge_header(expires: "2025-01-01"))
    end

    test "accepts a valid RFC 3339 expires" do
      assert {:ok, %Challenge{expires: "2025-01-15T12:05:00Z"}} =
               Headers.parse_challenge(challenge_header(expires: "2025-01-15T12:05:00Z"))
    end

    test "absent expires still parses" do
      assert {:ok, %Challenge{expires: nil}} = Headers.parse_challenge(challenge_header([]))
    end
  end

  describe "property: parse_challenge/1 rejects malformed methods (Task 72)" do
    property "any method with a non-lowercase-alpha character is rejected as :invalid_method" do
      check all(
              lower <- StreamData.string(?a..?z, min_length: 0, max_length: 8),
              bad_char <- StreamData.member_of([?A, ?Z, ?0, ?9, ?-, ?_, ?:]),
              suffix <- StreamData.string(?a..?z, min_length: 0, max_length: 8)
            ) do
        # Guaranteed non-conformant: at least one non-lowercase-alpha byte present.
        method = lower <> <<bad_char>> <> suffix
        header = Headers.format_challenge(make_challenge(method: method))
        assert {:error, :invalid_method} = Headers.parse_challenge(header)
      end
    end
  end

  # --- Property tests for Task 63 ---

  defp safe_str do
    :printable
    |> StreamData.string(min_length: 1, max_length: 40)
    |> StreamData.map(&String.replace(&1, ["\r", "\n"], " "))
  end

  describe "property: round-trip identity (format then parse)" do
    property "format_challenge/1 + parse_challenge/1 is identity" do
      check all(
              realm <- safe_str(),
              method <-
                StreamData.one_of([
                  StreamData.constant("stripe"),
                  StreamData.constant("tempo"),
                  StreamData.constant("evm")
                ]),
              request <-
                StreamData.map(
                  StreamData.string(:alphanumeric, min_length: 1, max_length: 40),
                  &Base.url_encode64(Jason.encode!(%{"amount" => &1}), padding: false)
                )
            ) do
        ch = make_challenge(realm: realm, method: method, request: request)
        h = Headers.format_challenge(ch)
        assert {:ok, ^ch} = Headers.parse_challenge(h)
      end
    end

    property "format_credential/1 + parse_credential/1 is identity" do
      check all(pval <- safe_str()) do
        cred = make_credential(payload: %{"p" => pval})
        h = Headers.format_credential(cred)
        assert {:ok, ^cred} = Headers.parse_credential(h)
      end
    end

    property "format_receipt/1 + parse_receipt/1 is identity" do
      check all(ref <- safe_str()) do
        r = Receipt.new(method: "stripe", reference: ref)
        h = Headers.format_receipt(r)
        assert {:ok, ^r} = Headers.parse_receipt(h)
      end
    end
  end

  describe "property: malformed-input robustness (never raise, always {:error, _})" do
    property "parse_challenge/1 on arbitrary binaries returns {:error, _}" do
      check all(bin <- StreamData.binary(max_length: 2048)) do
        assert {:error, _} = Headers.parse_challenge(bin)
      end
    end

    property "parse_credential/1 on arbitrary binaries returns {:error, _}" do
      check all(bin <- StreamData.binary(max_length: 2048)) do
        assert {:error, _} = Headers.parse_credential(bin)
      end
    end

    property "parse_receipt/1 on arbitrary binaries returns {:error, _}" do
      check all(bin <- StreamData.binary(max_length: 2048)) do
        assert {:error, _} = Headers.parse_receipt(bin)
      end
    end

    property "Credential.decode on arbitrary binaries and corrupt base64url returns {:error, _}" do
      check all(bin <- StreamData.binary(max_length: 512)) do
        assert {:error, _} = Credential.decode(bin)
      end
    end

    property "corrupt base64url tokens for credential header/decode return error" do
      check all(b <- StreamData.string(:alphanumeric, min_length: 4, max_length: 64)) do
        bad = String.slice(b, 0, div(String.length(b), 2)) <> "!!!" <> String.slice(b, -3, 3)
        assert {:error, _} = Credential.decode(bad)
        assert {:error, _} = Headers.parse_credential("Payment " <> bad)
      end
    end
  end
end
