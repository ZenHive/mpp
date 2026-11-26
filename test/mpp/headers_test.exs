defmodule MPP.HeadersTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MPP.Challenge
  alias MPP.Credential
  alias MPP.Headers
  alias MPP.Methods.Tempo.SessionReceipt
  alias MPP.Receipt
  alias MPP.Test.MppxChallengeBundle

  @secret "test-secret-key-padded-to-32-bytes-xxxxxxxxxxxxxxxx"

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
      refute header =~ "header="
    end

    test "includes optional fields when present" do
      challenge = make_challenge(expires: "2025-01-15T12:05:00Z", description: "Test payment")
      header = Headers.format_challenge(challenge)

      assert header =~ ~s(expires="2025-01-15T12:05:00Z")
      assert header =~ ~s(description="Test payment")
    end

    test "includes header when Payment-Authorization is advertised" do
      challenge = make_challenge(header: "Payment-Authorization")
      header = Headers.format_challenge(challenge)

      assert header =~ ~s(header="Payment-Authorization")
      refute header =~ ~s(header="Authorization")
    end

    test "omits header when Authorization is the implicit default" do
      challenge = make_challenge(header: "Authorization")
      header = Headers.format_challenge(challenge)

      refute header =~ "header="
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

    test "escapes every code point outside HTAB and printable ASCII as \\uXXXX (mpp-rs #450)" do
      # mppx #813 left Latin-1 raw (× U+00D7) and escaped only U+0100+.
      # mpp-rs #450 escapes both, so a Latin-1 client does not read UTF-8 as mojibake.
      challenge = make_challenge(description: "1 × Classmatic — General Admission")
      header = Headers.format_challenge(challenge)

      assert header =~ ~s(description="1 \\u00d7 Classmatic \\u2014 General Admission")
      assert ascii_header?(header)
    end

    test "escapes Latin-1, a C0 control, and DEL in the description only" do
      description = "caf\u00E9\u0007\u007F\t"
      header = Headers.format_challenge(make_challenge(description: description))

      assert ascii_header?(header)
      assert header =~ ~s(description="caf\\u00e9\\u0007\\u007f\t")
    end

    # mpp-rs `escape_quoted_value` (refs/mpp-rs/src/protocol/core/auth_params.rs);
    # mppx `authParam` refuses above U+00FF (refs/mppx/src/Challenge.ts).
    test "refuses a bound value outside HTAB and printable ASCII" do
      for {field, value} <- [realm: "caf\u00E9", realm: "a\u2014b", realm: "bell\a", realm: "del\u007F", id: "id\u00E9"] do
        challenge = Map.put(make_challenge(), field, value)

        assert_raise ArgumentError, ~r/#{field} must be printable ASCII/, fn ->
          Headers.format_challenge(challenge)
        end
      end

      assert Headers.format_challenge(make_challenge(realm: "My \"API\"\t\\v2")) =~ ~s(realm="My \\"API\\"\t\\\\v2")
    end

    test "refuses to format a challenge parsed with a legacy escape in a bound param" do
      assert {:ok, legacy} = Headers.parse_challenge(raw_header(realm: "caf\\u00e9"))

      assert_raise ArgumentError, ~r/legacy unicode escape/, fn -> Headers.format_challenge(legacy) end
    end

    test "escapes code points outside the BMP as a UTF-16 surrogate pair, matching mppx (#813)" do
      # mppx test fixture: 'Tickets 🎟️ "VIP"' -> 'Tickets 🎟️ \"VIP\"'
      challenge = make_challenge(description: ~s(Tickets 🎟️ "VIP"))
      header = Headers.format_challenge(challenge)

      assert header =~ ~s(description="Tickets \\ud83c\\udf9f\\ufe0f \\"VIP\\"")
    end

    test "ASCII-only header bytes are unchanged (wire-format invariant)" do
      challenge =
        Challenge.create(
          [
            realm: "api.example.com",
            method: "stripe",
            intent: "charge",
            request: "eyJhbW91bnQiOiIxMDAifQ",
            expires: "2025-01-15T12:05:00Z",
            description: "ASCII only description"
          ],
          @secret
        )

      header = Headers.format_challenge(challenge)

      assert header ==
               ~s(Payment id="Lnq5JFN3szaFlTpcEVJpdrlxggFIxLJ6F8aIYhtbuy8", realm="api.example.com", method="stripe", ) <>
                 ~s(intent="charge", request="eyJhbW91bnQiOiIxMDAifQ", expires="2025-01-15T12:05:00Z", ) <>
                 ~s(description="ASCII only description")
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

    test "roundtrip preserves Payment-Authorization header" do
      original = make_challenge(header: "Payment-Authorization")
      header = Headers.format_challenge(original)
      assert {:ok, parsed} = Headers.parse_challenge(header)

      assert parsed.header == "Payment-Authorization"
      assert parsed.id == original.id
    end

    test "rejects a parsed header other than Payment-Authorization" do
      header = Headers.format_challenge(make_challenge()) <> ~s(, header="Cookie")
      assert {:error, :invalid_header} = Headers.parse_challenge(header)
    end

    test "parsed payment-authorization is payable in any ASCII case" do
      original = make_challenge()
      header = Headers.format_challenge(original) <> ~s(, header="payment-authorization")

      assert {:ok, parsed} = Headers.parse_challenge(header)
      assert parsed.header == "payment-authorization"
      assert Challenge.payable?(parsed)
      assert Challenge.credential_header(parsed) == "payment-authorization"
    end

    test "parses header=Payment-Authorization from a foreign server" do
      original = make_challenge()

      header =
        Headers.format_challenge(original) <> ~s(, header="Payment-Authorization")

      assert {:ok, parsed} = Headers.parse_challenge(header)
      assert parsed.header == "Payment-Authorization"
    end

    # mppx `deserialize` and mpp-rs reject a written default: only an absent
    # `header` selects `Authorization`.
    test "rejects an explicit header=Authorization or an empty header" do
      for value <- ["Authorization", "authorization", ""] do
        header = Headers.format_challenge(make_challenge()) <> ~s(, header="#{value}")
        assert {:error, :invalid_header} = Headers.parse_challenge(header), value
      end
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

    # Core draft: "implementations MUST ignore unknown parameters".
    test "ignores unknown params and still rejects a repeated one" do
      assert {:ok, %Challenge{id: "abc", realm: "api.example.com"}} =
               Headers.parse_challenge(raw_header([]) <> ~s(, x-note=v, unknown="x"))

      assert {:error, :duplicate_param} = Headers.parse_challenge(raw_header([]) <> ~s(, x-note=v, x-note=w))

      assert {:ok, %Challenge{legacy_unicode_escape: false}} =
               Headers.parse_challenge(raw_header([]) <> ~S(, x-note="caf\u00e9"))
    end

    test "accepts header as a known optional param (Task 83 whitelist is not loosened)" do
      original = make_challenge()
      header = Headers.format_challenge(original) <> ~s(, header="Payment-Authorization")

      assert {:ok, parsed} = Headers.parse_challenge(header)
      assert parsed.header == "Payment-Authorization"
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

    # mppx `readAuthParamValue` requires 1*tchar (refs/mppx/src/Challenge.ts);
    # mpp-rs still reads an empty unquoted value as "".
    test "rejects an empty unquoted value" do
      base = ~s(Payment id="a", realm="b", method="c", intent="d", request="eyJhIjoxfQ", description=)

      for header <- [
            base,
            base <> ~s(, digest="sha-256=abc"),
            ~s(Payment id=, realm="b", method="c", intent="d", request="eyJhIjoxfQ")
          ] do
        assert {:error, :invalid_auth_params} = Headers.parse_challenge(header), header
      end

      assert {:ok, %Challenge{description: ""}} = Headers.parse_challenge(base <> ~s(""))
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

    # RFC 9110 §5.6.4; mppx `readQuotedAuthParamValue` (refs/mppx/src/Challenge.ts),
    # mpp-rs `Tokenizer::value` (refs/mpp-rs/src/protocol/core/auth_params.rs).
    test "reads a backslash-u sequence as a quoted-pair, not an escape" do
      header =
        ~s(Payment id="a", realm="b", method="c", intent="d", request="eyJhIjoxfQ", ) <>
          ~s(description="1 \\u00d7 Classmatic \\u2014 \\"GA\\" \\ud83c\\udf9f")

      assert {:ok, parsed} = Headers.parse_challenge(header)
      assert parsed.description == ~s(1 u00d7 Classmatic u2014 "GA" ud83cudf9f)
      refute parsed.legacy_unicode_escape
    end

    test "flags a backslash-u escape in every param but the description" do
      for {field, value} <- [
            id: "\\u00e9abc",
            realm: "caf\\u00e9",
            intent: "ch\\u0061rge"
          ] do
        header = raw_header([{field, value}])
        assert {:ok, %Challenge{legacy_unicode_escape: true}} = Headers.parse_challenge(header), header
      end

      assert {:ok, %Challenge{legacy_unicode_escape: false, description: "cafu00e9"}} =
               Headers.parse_challenge(raw_header(description: "caf\\u00e9"))

      assert {:ok, %Challenge{realm: "cafu00e9"}} = Headers.parse_challenge(raw_header(realm: "caf\\u00e9"))

      for value <- ["caf\\u00e", "caf\\U00e9", "caf\\\\u00e9", "cafu00e9"] do
        assert {:ok, %Challenge{legacy_unicode_escape: false}} = Headers.parse_challenge(raw_header(realm: value)),
               value
      end
    end

    test "does not round-trip a non-ASCII description: the receiver shows the escape text" do
      header = Headers.format_challenge(make_challenge(description: "北京 — café"))

      assert {:ok, parsed} = Headers.parse_challenge(header)
      assert parsed.description == "u5317u4eac u2014 cafu00e9"
      refute parsed.legacy_unicode_escape
    end

    test "rejects a quoted string that ends in a backslash" do
      assert {:error, :invalid_auth_params} = Headers.parse_challenge(~s(Payment id="a\\u1))
      assert {:error, :invalid_auth_params} = Headers.parse_challenge(~s(Payment id="a\\))
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

    # auth-params = auth-param *( OWS "," OWS auth-param ): mppx `parseAuthParams`,
    # mpp-rs `read_challenge_flagged` ("Expected ',' between auth-params").
    test "rejects auth-params that are not separated by a comma" do
      for separator <- [" ", "\t", ""] do
        header =
          Enum.join(
            [
              ~s(Payment id="abc"),
              ~s(realm="test.com"),
              ~s(method="stripe"),
              ~s(intent="charge"),
              ~s(request="eyJ0ZXN0Ijp0cnVlfQ")
            ],
            separator
          )

        assert {:error, :invalid_auth_params} = Headers.parse_challenge(header), inspect(separator)
      end

      assert {:error, :invalid_auth_params} =
               Headers.parse_challenge(
                 "Payment id=abc realm=test.com, method=stripe, intent=charge, request=eyJ0ZXN0Ijp0cnVlfQ"
               )
    end

    test "accepts repeated commas and whitespace around the comma and the equals sign" do
      header =
        ~s(Payment ,, id = "abc" ,,\t realm= test.com,method ="stripe" , , intent=charge,request=eyJ0ZXN0Ijp0cnVlfQ,,)

      assert {:ok, parsed} = Headers.parse_challenge(header)
      assert {parsed.id, parsed.realm, parsed.method, parsed.intent} == {"abc", "test.com", "stripe", "charge"}
    end

    test "rejects an unquoted value that is not a token" do
      for value <- ["a/b", "a:b", "a=b", "a(b", "a\"b", "caf\u00E9", "a;b", "a@b"] do
        header = ~s(Payment id=#{value}, realm="b", method="c", intent="d", request="eyJhIjoxfQ")
        assert {:error, :invalid_auth_params} = Headers.parse_challenge(header), value
      end

      assert {:ok, %Challenge{id: "!#$%&'*+-.^_`|~aZ9"}} =
               Headers.parse_challenge(
                 ~s(Payment id=!#$%&'*+-.^_`|~aZ9, realm="b", method="c", intent="d", request="eyJhIjoxfQ")
               )
    end

    test "rejects text after a value that is not a comma" do
      header = ~s(Payment id="abc"x, realm="b", method="c", intent="d", request="eyJhIjoxfQ")
      assert {:error, :invalid_auth_params} = Headers.parse_challenge(header)
    end

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

    test "encodes a Tempo session receipt" do
      receipt =
        SessionReceipt.new(
          challenge_id: "ch_1",
          channel_id: "0x" <> String.duplicate("11", 32),
          accepted_cumulative: "100",
          spent: "10"
        )

      header = Headers.format_receipt(receipt)
      assert {:ok, parsed} = SessionReceipt.from_header(header)
      assert parsed.channel_id == receipt.channel_id
      assert parsed.accepted_cumulative == "100"
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

    test "skips an offer whose method is not lowercase letters and keeps the rest" do
      header =
        Enum.join(
          [raw_header(method: "x402"), raw_header(realm: "ok.example.com"), raw_header(method: "tempo-v2")],
          ", "
        )

      assert {:ok, [%Challenge{method: "tempo", realm: "ok.example.com"}]} = Headers.parse_challenges(header)
      assert {:error, :invalid_method} = Headers.parse_challenges(raw_header(method: "x402"))
    end

    # A bare scheme ends the Payment offer wherever the header ends after it
    # (cross-validated against mppx in "other schemes in the same header").
    test "a bare scheme after the Payment offer does not join it" do
      for suffix <- [", Basic, Digest realm=other", ", Bearer", ", Bearer ", ", Basic\t, Digest realm=other"] do
        header = raw_header(id: "good") <> suffix

        assert {:ok, [%Challenge{id: "good", description: nil}]} = Headers.parse_challenges(header), suffix
      end
    end

    test "skips an offer with a grammar error and keeps a legacy-escaped one flagged" do
      header =
        ~s(Payment id="abc" realm="x", method="tempo", intent="charge", request="eyJhIjoxfQ", ) <>
          raw_header(realm: "caf\\u00e9")

      assert {:ok, [%Challenge{realm: "cafu00e9", legacy_unicode_escape: true}]} = Headers.parse_challenges(header)
    end

    # Whitespace before the equals sign is BWS, not a scheme boundary.
    test "keeps an offer whole when a param has whitespace before its equals sign" do
      header = ~s(Payment id=ch, realm = shop, method=tempo, intent=charge, request=e30, description = "d")

      assert {:ok, [%Challenge{realm: "shop", description: "d"}]} = Headers.parse_challenges(header)
      assert {:ok, [%Challenge{method: "tempo"}]} = Headers.parse_challenges(header <> ~s(, Bearer realm = "x"))
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

    test "an escaped quote inside a quoted value does not end the challenge" do
      c2 = make_challenge(realm: "second.com")

      header =
        ~s(Payment id="x", realm="a\\"b, c", method="m", intent="charge", request="eyJhIjoxfQ", ) <>
          Headers.format_challenge(c2)

      assert {:ok, [p1, p2]} = Headers.parse_challenges(header)
      assert p1.realm == ~s(a"b, c)
      assert p2.realm == "second.com"
    end

    test "a trailing bare scheme token is ignored" do
      challenge = make_challenge(realm: "only.com")
      header = Headers.format_challenge(challenge) <> ", Basic"
      assert {:ok, [parsed]} = Headers.parse_challenges(header)
      assert parsed.realm == "only.com"
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
    # A credential is bounded as a whole field value at 64 KiB (mpp-rs
    # MAX_AUTHORIZATION_LEN, refs/mpp-rs/src/protocol/core/headers.rs:29,761).
    test "rejects an Authorization value over 64 KiB before decode" do
      token = String.duplicate("A", 64 * 1024 - 7)
      assert {:error, :token_too_large} = Headers.parse_credential("Payment #{token}")
    end

    test "an Authorization value of 64 KiB passes the size gate and reaches decode" do
      token = String.duplicate("A", 64 * 1024 - 8)
      assert {:error, :invalid_json} = Headers.parse_credential("Payment #{token}")
    end

    # mpp-rs `test_authorization_accepts_credential_echoing_request_at_the_limit`
    # (refs/mpp-rs/src/protocol/core/headers.rs:1381).
    test "a credential echoing a request at the 16 KiB limit round-trips" do
      request = %{"data" => String.duplicate("a", 12_277)} |> Jason.encode!() |> Base.url_encode64(padding: false)
      assert byte_size(request) == @max_token_len

      challenge =
        Challenge.create([realm: "api.example.com", method: "tempo", intent: "charge", request: request], @secret)

      header = Headers.format_credential(%Credential{challenge: challenge, payload: %{"hash" => "0xabc"}})
      assert byte_size(header) > @max_token_len

      assert {:ok, ^header} = Headers.select_payment_credential([header], [], "Authorization")
      assert {:ok, parsed} = Headers.parse_credential(header)
      assert parsed.challenge.request == request
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

    # Writes the values between the quotes as given, without escaping.
    defp raw_header(overrides) do
      params =
        Keyword.merge(
          [id: "abc", realm: "api.example.com", method: "tempo", intent: "charge", request: "eyJhIjoxfQ"],
          overrides
        )

      "Payment " <> Enum.map_join(params, ", ", fn {key, value} -> ~s(#{key}="#{value}") end)
    end

    test "rejects an empty id" do
      # Challenge.create computes the id, so craft the header directly to force id="".
      header =
        ~s(Payment id="", realm="api.example.com", method="stripe", intent="charge", request="eyJhbW91bnQiOiIxMDAifQ")

      assert {:error, :empty_id} = Headers.parse_challenge(header)
    end

    test "rejects an uppercase method" do
      assert {:error, :invalid_method} = Headers.parse_challenge(raw_header(method: "Stripe"))
    end

    test "accepts methods of lowercase letters only (1*LOWERALPHA)" do
      for method <- ["tempo", "a", "nearintents"] do
        assert {:ok, %Challenge{method: ^method}} = Headers.parse_challenge(challenge_header(method: method))
      end

      for method <- ["x402", "tempo-v2", "a:b", "a_b"] do
        assert {:error, :invalid_method} = Headers.parse_challenge(raw_header(method: method)), method
        assert_raise ArgumentError, ~r/lowercase letters/, fn -> challenge_header(method: method) end
      end
    end

    test "rejects a method that does not start with a lowercase letter" do
      for method <- ["-tempo", ":tempo", "_tempo", "123", "tempo!"] do
        assert {:error, :invalid_method} = Headers.parse_challenge(raw_header(method: method)), method
      end
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

  # mpp-rs `select_payment_credential` (refs/mpp-rs/src/protocol/core/headers.rs)
  # and mppx `countPaymentCredentials` (refs/mppx/src/server/Transport.ts).
  describe "select_payment_credential/3" do
    test "returns the credential of the selected field" do
      assert {:ok, "Payment abc"} = Headers.select_payment_credential(["Payment abc"], [], "Authorization")
      assert {:ok, "payment\tabc"} = Headers.select_payment_credential(["Bearer x , payment\tabc "], [], "authorization")

      assert {:ok, "Payment abc"} =
               Headers.select_payment_credential(["Bearer x"], ["Payment abc"], "Payment-Authorization")
    end

    test "a credential in the other field, a bare scheme and other schemes count as absent" do
      assert {:ok, nil} = Headers.select_payment_credential([], [], "Authorization")
      assert {:ok, nil} = Headers.select_payment_credential(["Payment abc"], [], "Payment-Authorization")
      assert {:ok, nil} = Headers.select_payment_credential([], ["Payment abc"], "Authorization")

      assert {:ok, nil} =
               Headers.select_payment_credential(["Payment", "Payment ", "Paymentx abc", "Bearer x"], [], "Authorization")
    end

    test "more than one credential is an error wherever they are" do
      for {authorization, alternate} <- [
            {["Payment a", "Payment b"], []},
            {["Payment a, Payment b"], []},
            {["Payment a,PAYMENT b"], []},
            {["Payment a"], ["Payment b"]},
            {[], ["Payment a", "Payment b"]}
          ],
          selected <- ["Authorization", "Payment-Authorization"] do
        assert {:error, :multiple_credentials} = Headers.select_payment_credential(authorization, alternate, selected)
      end
    end

    # mpp-rs reads `Payment` followed by `=` as an auth-param of the scheme
    # before it (refs/mpp-rs/src/protocol/core/auth_params.rs:232).
    test "a parameter named Payment is not a credential" do
      for value <- [
            ~s(Digest a="1", Payment ="x", Payment abc),
            "Digest a=1, payment\t= x, Payment abc",
            "Digest Payment=x, Payment abc"
          ] do
        assert {:ok, "Payment abc"} = Headers.select_payment_credential([value], [], "Authorization")
      end

      assert {:ok, "Payment =abc"} = Headers.select_payment_credential(["Payment =abc"], [], "Authorization")
    end

    # A credential runs to the next comma whatever it contains (mpp-rs
    # `Tokenizer::credentials`); an unterminated quoted string in another
    # scheme ends the scan of that value.
    test "quotes do not extend a credential, and a broken quoted string ends the scan" do
      assert {:error, :multiple_credentials} =
               Headers.select_payment_credential([~s(Payment a"b, Payment c)], [], "Authorization")

      assert {:ok, nil} = Headers.select_payment_credential([~s(Digest a="x, Payment abc)], [], "Authorization")

      assert {:ok, "Payment abc"} =
               Headers.select_payment_credential([~s(Payment abc, Digest a="x, Payment def)], [], "Authorization")
    end

    # Only a parameter value that starts with a quote is a quoted string
    # (refs/mpp-rs/src/protocol/core/auth_params.rs:131-135).
    test "a stray quote in another scheme does not hide a later credential" do
      for value <- [
            ~s(Digest a=b"c, Payment abc),
            ~s(Digest tok"en, Payment abc),
            ~s(Basic dXNlcg==, Payment abc),
            ~s(Digest a=b=c=d, Payment abc),
            ~s(Digest a=b="c, Payment abc),
            ~s(Digest a=b=c="x, Payment abc, y")
          ] do
        assert {:ok, "Payment abc"} = Headers.select_payment_credential([value], [], "Authorization")
      end

      assert {:error, :multiple_credentials} =
               Headers.select_payment_credential([~s(Payment abc, Digest a=b"c, Payment def)], [], "Authorization")
    end

    # mpp-rs stops at the first decisive condition
    # (refs/mpp-rs/src/protocol/core/headers.rs:138-165).
    test "the first error in request order is the one reported" do
      full = String.duplicate("a", 64 * 1024)

      assert {:error, :multiple_credentials} =
               Headers.select_payment_credential(["Payment a", "Payment b", full, full, "x"], [], "Authorization")

      assert {:error, :too_many_credential_values} =
               Headers.select_payment_credential([full, full, "x", "Payment a", "Payment b"], [], "Authorization")
    end

    test "commas inside quoted strings do not separate credentials" do
      value = ~s(Digest realm="a, Payment b", nonce="q\\", Payment c", Payment abc)
      assert {:ok, "Payment abc"} = Headers.select_payment_credential([value], [], "Authorization")
    end

    test "a value over 64 KiB carries no credential" do
      at_limit = "Payment " <> String.duplicate("a", 64 * 1024 - 8)
      assert {:ok, ^at_limit} = Headers.select_payment_credential([at_limit], [], "Authorization")
      assert {:ok, nil} = Headers.select_payment_credential([at_limit <> "a"], [], "Authorization")
      assert {:ok, "Payment b"} = Headers.select_payment_credential([at_limit <> "a", "Payment b"], [], "Authorization")
    end

    test "more than 32 values or more than 128 KiB to scan is an error" do
      values = List.duplicate("Bearer x", 16)
      assert {:ok, nil} = Headers.select_payment_credential(values, values, "Authorization")

      assert {:error, :too_many_credential_values} =
               Headers.select_payment_credential(values, ["x" | values], "Authorization")

      full = String.duplicate("a", 64 * 1024)
      assert {:ok, nil} = Headers.select_payment_credential([full], [full], "Authorization")

      assert {:error, :too_many_credential_values} =
               Headers.select_payment_credential([full, "a"], [full], "Authorization")
    end
  end

  describe "property: parse_challenge/1 rejects malformed methods (Task 72)" do
    property "any method with a character outside [a-z0-9:_-] is rejected as :invalid_method" do
      check all(
              lower <- StreamData.string(?a..?z, min_length: 1, max_length: 8),
              bad_char <- StreamData.member_of([?A, ?Z, ?!, ?., ?/, ?~, ?+]),
              suffix <- StreamData.string([?a..?z, ?0..?9, ?:, ?_, ?-], min_length: 0, max_length: 8)
            ) do
        # Guaranteed non-conformant: at least one byte outside the grammar is present.
        method = lower <> <<bad_char>> <> suffix
        assert {:error, :invalid_method} = Headers.parse_challenge(raw_header(method: method))
      end
    end

    property "any method starting with a non-letter is rejected even when the rest conforms" do
      check all(
              first <- StreamData.member_of([?0, ?9, ?:, ?_, ?-, ?A]),
              rest <- StreamData.string([?a..?z, ?0..?9, ?:, ?_, ?-], min_length: 0, max_length: 8)
            ) do
        assert {:error, :invalid_method} = Headers.parse_challenge(raw_header(method: <<first>> <> rest))
      end
    end

    property "a method round-trips exactly when it is one or more lowercase letters" do
      check all(method <- StreamData.string([?a..?z, ?0..?9, ?:, ?_, ?-], min_length: 1, max_length: 8)) do
        if method =~ ~r/\A[a-z]+\z/ do
          header = Headers.format_challenge(make_challenge(method: method))
          assert {:ok, %Challenge{method: ^method}} = Headers.parse_challenge(header)
        else
          assert {:error, :invalid_method} = Headers.parse_challenge(raw_header(method: method))
          assert_raise ArgumentError, fn -> Headers.format_challenge(make_challenge(method: method)) end
        end
      end
    end
  end

  defp safe_str do
    :printable
    |> StreamData.string(min_length: 1, max_length: 40)
    |> StreamData.map(&String.replace(&1, ["\r", "\n"], " "))
  end

  describe "property: round-trip identity (format then parse)" do
    property "format_challenge/1 + parse_challenge/1 is identity" do
      check all(
              realm <- StreamData.string([?\t, 0x20..0x7E], min_length: 1, max_length: 40),
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

    property "a realm holding anything but HTAB and printable ASCII is refused" do
      check all(realm <- safe_str(), not Challenge.header_text?(realm)) do
        assert_raise ArgumentError, fn -> Headers.format_challenge(make_challenge(realm: realm)) end
      end
    end

    property "any description formats to an ASCII header that parses without a legacy flag" do
      check all(description <- safe_str()) do
        header = Headers.format_challenge(make_challenge(description: description))
        assert ascii_header?(header)
        assert {:ok, %Challenge{legacy_unicode_escape: false}} = Headers.parse_challenge(header)
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

  # --- Cross-validation against mppx's Challenge.serialize/deserialize (mppx #813) ---
  #
  # Deterministic but requires a JS toolchain (QuickBEAM + node + npx/esbuild +
  # the `zod`/`ox` npm packages mppx's Challenge.ts imports). Excluded from the
  # default gate; run explicitly with `mix test.json --include cross_validation`.
  describe "cross-validation: description escape vs mppx Challenge" do
    @describetag :cross_validation

    setup do
      if !Code.ensure_loaded?(QuickBEAM) do
        flunk("""
        QuickBEAM not available. This test requires the dev/test dependency stack.
        """)
      end

      rt = start_supervised!({QuickBEAM, apis: :browser})
      MppxChallengeBundle.load!(rt)
      %{rt: rt}
    end

    test "mppx serializes a non-Latin-1 description and we read the same text mppx does", %{rt: rt} do
      description = "1 × Classmatic — General Admission 🎟️"

      {:ok, header} =
        QuickBEAM.call(rt, "mppxSerialize", [
          Map.put(
            %{
              "id" => "abc123",
              "realm" => "api.example.com",
              "method" => "tempo",
              "intent" => "charge",
              "request" => %{"amount" => "1000000"}
            },
            "description",
            description
          )
        ])

      # mppx escapes only above U+00FF, and both sides read the escape as text.
      assert {:ok, %{"ok" => true, "challenge" => mppx_parsed}} = QuickBEAM.call(rt, "mppxRead", [header])
      assert {:ok, parsed} = Headers.parse_challenge(header)
      assert parsed.description == "1 × Classmatic u2014 General Admission ud83cudf9fufe0f"
      assert parsed.description == mppx_parsed["description"]
      refute parsed.legacy_unicode_escape
    end

    # mppx reads a quoted-pair literally (refs/mppx/src/Challenge.ts
    # `readQuotedAuthParamValue`), so the description arrives as escape text.
    test "we serialize a non-Latin-1 description and mppx reads the same escape text we do", %{rt: rt} do
      challenge = make_challenge(method: "tempo", description: "1 × Classmatic — General Admission 🎟️")
      header = Headers.format_challenge(challenge)

      assert {:ok, %{"ok" => true, "legacy" => false, "challenge" => mppx_parsed}} =
               QuickBEAM.call(rt, "mppxRead", [header])

      assert {:ok, ours} = Headers.parse_challenge(header)

      assert ours.description == "1 u00d7 Classmatic u2014 General Admission ud83cudf9fufe0f"
      assert mppx_parsed["description"] == ours.description
    end

    test "mppx serializes header=Payment-Authorization and we parse it", %{rt: rt} do
      {:ok, header} =
        QuickBEAM.call(rt, "mppxSerialize", [
          %{
            "id" => "abc123",
            "realm" => "api.example.com",
            "method" => "tempo",
            "intent" => "charge",
            "request" => %{"amount" => "1000000"},
            "header" => "Payment-Authorization"
          }
        ])

      assert {:ok, parsed} = Headers.parse_challenge(header)
      assert parsed.header == "Payment-Authorization"
    end

    test "we serialize header=Payment-Authorization and mppx parses it", %{rt: rt} do
      challenge = make_challenge(method: "tempo", header: "Payment-Authorization")
      header = Headers.format_challenge(challenge)

      {:ok, mppx_parsed} = QuickBEAM.call(rt, "mppxDeserialize", [header])

      assert mppx_parsed["header"] == "Payment-Authorization"
    end

    test "we escape Latin-1, a C0 control, and DEL to ASCII and mppx reads the escape text", %{rt: rt} do
      header = Headers.format_challenge(make_challenge(method: "tempo", description: "caf\u00E9\u0007\u007F"))

      assert ascii_header?(header)

      assert {:ok, %{"ok" => true, "legacy" => false, "challenge" => mppx_parsed}} =
               QuickBEAM.call(rt, "mppxRead", [header])

      assert mppx_parsed["description"] == "cafu00e9u0007u007f"
    end
  end

  # Each grammar rule against mppx at runtime (refs/mppx/src/Challenge.ts, mppx
  # #1341 / #1349). The mpp-rs verdicts are the ones its own tests pin in
  # refs/mpp-rs/src/protocol/core/headers.rs and auth_params.rs; they are named
  # per vector where mpp-rs differs.
  describe "cross-validation: core header grammar vs mppx Challenge" do
    @describetag :cross_validation

    setup do
      if !Code.ensure_loaded?(QuickBEAM) do
        flunk("""
        QuickBEAM not available. This test requires the dev/test dependency stack.
        """)
      end

      rt = start_supervised!({QuickBEAM, apis: :browser})
      MppxChallengeBundle.load!(rt)
      %{rt: rt}
    end

    @quoted ~s(realm="api.example.com", method="tempo", intent="charge", request="eyJhIjoxfQ")

    test "both accept or both reject each header", %{rt: rt} do
      vectors = [
        # comma-separated auth-params; empty list elements
        {~s(Payment id="abc", #{@quoted}), true},
        {~s(Payment id="abc" #{@quoted}), false},
        {~s(Payment id="abc"\t#{@quoted}), false},
        {~s(Payment id="abc"x, #{@quoted}), false},
        {~s(Payment ,, id="abc" ,, #{@quoted},,), true},
        {~s(Payment id = "abc" , #{@quoted}), true},
        # unquoted values are tokens
        {~s(Payment id=abc, #{@quoted}), true},
        {~s(Payment id=!#$%&'*+-.^_`|~aZ9, #{@quoted}), true},
        {~s(Payment id=a/b, #{@quoted}), false},
        {~s(Payment id=a:b, #{@quoted}), false},
        {~s(Payment id=a@b, #{@quoted}), false},
        # mpp-rs reads the empty unquoted value as "" and then rejects the empty id
        {~s(Payment id=, #{@quoted}), false},
        # method identifiers
        {raw_header(method: "x402"), false},
        {raw_header(method: "tempo-v2"), false},
        {raw_header(method: "a:b"), false},
        {raw_header(method: "a_b"), false},
        {raw_header(method: "Tempo"), false},
        {raw_header(method: ""), false},
        # quoted strings
        {raw_header(realm: "caf\\u00e9"), true},
        {raw_header(realm: "a\\\"b\\\\c\\x"), true},
        {~s(Payment id="abc), false},
        {~s(Payment id="abc\\), false}
      ]

      for {header, accepted?} <- vectors do
        assert {:ok, %{"ok" => mppx_ok}} = QuickBEAM.call(rt, "mppxRead", [header])
        ours_ok = match?({:ok, _}, Headers.parse_challenge(header))

        assert mppx_ok == accepted?, "mppx on #{inspect(header)}"
        assert ours_ok == accepted?, "ours on #{inspect(header)}"
      end
    end

    # mpp-rs reads this one as description "" (refs/mpp-rs/src/protocol/core/headers.rs
    # `read_challenge_flagged`: "An empty unquoted value is still read as \"\""); we follow mppx.
    test "an empty unquoted description is rejected, as mppx rejects it", %{rt: rt} do
      header = ~s(Payment id="abc", #{@quoted}, description=)

      assert {:ok, %{"ok" => false}} = QuickBEAM.call(rt, "mppxRead", [header])
      assert {:error, :invalid_auth_params} = Headers.parse_challenge(header)
    end

    test "quoted-pairs read to the same text and the same legacy verdict", %{rt: rt} do
      # {param, wire value, legacy?} — refs/mpp-rs/src/protocol/core/headers.rs
      # `test_parse_payable_challenges_refuses_legacy_unicode_escapes` pins the first four.
      vectors = [
        {"realm", "caf\\u00e9.example.com", true},
        {"realm", "merchant\\u2014api.example.com", true},
        {"realm", "lower hex \\u00E9 and \\uabcd", true},
        {"realm", "caf\\u00e", false},
        {"realm", "caf\\U00e9", false},
        {"realm", "caf\\\\u00e9", false},
        {"realm", "a\\\"b\\x", false},
        {"description", "caf\\u00e9", false}
      ]

      for {param, value, legacy?} <- vectors do
        header = raw_header([{String.to_atom(param), value}])

        assert {:ok, %{"ok" => true, "legacy" => mppx_legacy, "challenge" => mppx_parsed}} =
                 QuickBEAM.call(rt, "mppxRead", [header])

        assert {:ok, ours} = Headers.parse_challenge(header)
        assert Map.fetch!(ours, String.to_atom(param)) == mppx_parsed[param], value
        assert mppx_legacy == legacy?, "mppx on #{value}"
        assert ours.legacy_unicode_escape == legacy?, "ours on #{value}"
      end
    end

    # mppx flags the params it binds into the id and leaves `id` itself out
    # (`boundParams`); mpp-rs flags `id` too (`read_challenge_flagged`,
    # `("id", r"ch\u00e9")`). We follow mpp-rs: the credential echoes the id.
    test "a legacy escape in the id is flagged, as mpp-rs flags it", %{rt: rt} do
      header = raw_header(id: "ch\\u00e9")

      assert {:ok, %{"ok" => true, "legacy" => false}} = QuickBEAM.call(rt, "mppxRead", [header])
      assert {:ok, %Challenge{id: "chu00e9", legacy_unicode_escape: true}} = Headers.parse_challenge(header)
    end

    test "mppx refuses a realm above U+00FF and a non-letter method when writing; so do we", %{rt: rt} do
      base = %{
        "id" => "abc",
        "realm" => "api.example.com",
        "method" => "tempo",
        "intent" => "charge",
        "request" => %{"a" => "1"}
      }

      for {field, value} <- [{"realm", "merchant—api"}, {"method", "x402"}, {"method", "tempo-v2"}] do
        assert {:ok, %{"ok" => false}} = QuickBEAM.call(rt, "mppxWrite", [Map.put(base, field, value)])
      end

      assert_raise ArgumentError, fn -> Headers.format_challenge(make_challenge(realm: "merchant—api")) end
      assert_raise ArgumentError, fn -> Headers.format_challenge(make_challenge(method: "x402")) end
      assert_raise ArgumentError, fn -> Headers.format_challenge(make_challenge(method: "tempo-v2")) end
    end

    test "a multi-challenge header keeps the conformant offer on both sides", %{rt: rt} do
      header = raw_header(method: "tempo-v2") <> ", " <> raw_header(id: "good")

      assert {:ok, ["good"]} = QuickBEAM.call(rt, "mppxReadList", [header])
      assert {:ok, [%Challenge{id: "good"}]} = Headers.parse_challenges(header)
    end

    # Another scheme's params never join the Payment offer, and a bare scheme ends it.
    test "other schemes in the same header leave the Payment offer as mppx reads it", %{rt: rt} do
      for suffix <- [", New_Scheme realm=other, description=secondary", ", Basic, Digest realm=other", ", Bearer"] do
        header = raw_header(id: "good") <> suffix

        assert {:ok, ["good"]} = QuickBEAM.call(rt, "mppxReadList", [header]), suffix
        assert {:ok, [%Challenge{id: "good", description: nil}]} = Headers.parse_challenges(header), suffix
      end
    end

    test "a parameter name that is not a token is rejected, as mppx rejects it", %{rt: rt} do
      header = raw_header([]) <> ", /note=v"

      assert {:ok, %{"ok" => false}} = QuickBEAM.call(rt, "mppxRead", [header])
      assert {:error, :invalid_auth_params} = Headers.parse_challenge(header)
    end

    test "a receipt with a non-string method or reference is rejected, as mppx rejects it", %{rt: rt} do
      base = %{"method" => "tempo", "reference" => "0xabc", "timestamp" => "2024-01-01T00:00:00Z", "status" => "success"}

      for {key, value, accepted?} <- [
            {"method", "tempo", true},
            {"method", 42, false},
            {"reference", nil, false},
            {"reference", %{}, false}
          ] do
        encoded = base |> Map.put(key, value) |> Jason.encode!() |> Base.url_encode64(padding: false)

        assert {:ok, %{"ok" => ^accepted?}} = QuickBEAM.call(rt, "mppxReceiptRead", [encoded])
        assert match?({:ok, _}, Receipt.decode(encoded)) == accepted?, "#{key}=#{inspect(value)}"
      end
    end

    test "unknown params, an explicit default header and BWS read as mppx reads them", %{rt: rt} do
      for {header, accepted?} <- [
            {raw_header([]) <> ", x-note=v", true},
            {raw_header([]) <> ~s(, header="Authorization"), false},
            {raw_header([]) <> ~s(, header=""), false},
            {raw_header([]) <> ~s(, header="payment-authorization"), true},
            {~s(Payment id=ch, realm = shop, method=tempo, intent=charge, request=e30), true}
          ] do
        assert {:ok, %{"ok" => mppx_ok}} = QuickBEAM.call(rt, "mppxRead", [header])
        assert mppx_ok == accepted?, "mppx on #{inspect(header)}"
        assert match?({:ok, [_]}, Headers.parse_challenges(header)) == accepted?, "ours on #{inspect(header)}"
      end
    end

    # mppx still writes U+0080-U+00FF raw (`authParam`); mpp-rs refuses everything
    # outside HTAB and printable ASCII (`escape_quoted_value`). We apply the mpp-rs
    # rule, which every header mppx accepts from us also satisfies.
    test "our bound values stay within what mppx reads back unchanged", %{rt: rt} do
      challenge = make_challenge(method: "tempo", realm: "My \"API\"\t\\v2 ~!")
      # --- Property tests for Task 63 ---
      header = Headers.format_challenge(challenge)

      assert {:ok, %{"ok" => true, "legacy" => false, "challenge" => mppx_parsed}} =
               QuickBEAM.call(rt, "mppxRead", [header])

      assert mppx_parsed["realm"] == challenge.realm
      assert_raise ArgumentError, fn -> Headers.format_challenge(make_challenge(realm: "caf\u00E9")) end
    end
  end

  defp ascii_header?(header) do
    header |> :binary.bin_to_list() |> Enum.all?(&(&1 == 9 or &1 in 0x20..0x7E))
  end
end
