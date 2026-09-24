defmodule MPP.Client.Transport.HTTPTest do
  use ExUnit.Case, async: true

  alias MPP.AcceptPayment
  alias MPP.Challenge
  alias MPP.Client.MultiProvider
  alias MPP.Client.PaymentProvider
  alias MPP.Client.Transport
  alias MPP.Client.Transport.HTTP
  alias MPP.Credential
  alias MPP.Headers
  alias MPP.X402
  alias MPP.X402.Headers, as: X402Headers

  @secret_key "test-secret-key"
  @request "eyJhbW91bnQiOiIxMDAwIiwiY3VycmVuY3kiOiJ1c2QifQ"

  # -- Mock providers -------------------------------------------------------------

  defmodule TempoProvider do
    @moduledoc false
    use PaymentProvider

    @impl PaymentProvider
    def supports?(method, intent, _config), do: method == "tempo" and intent == "charge"

    @impl PaymentProvider
    def pay(challenge, _config), do: {:ok, %Credential{challenge: challenge, payload: %{"type" => "hash"}, source: nil}}
  end

  defmodule StripeProvider do
    @moduledoc false
    use PaymentProvider

    @impl PaymentProvider
    def supports?(method, intent, _config), do: method == "stripe" and intent == "charge"

    @impl PaymentProvider
    def pay(challenge, _config),
      do: {:ok, %Credential{challenge: challenge, payload: %{"spt" => "spt_test"}, source: nil}}
  end

  # -- Helpers --------------------------------------------------------------------

  defp make_challenge(method \\ "tempo") do
    Challenge.create(
      [realm: "api.example.com", method: method, intent: "charge", request: @request],
      @secret_key
    )
  end

  defp response_with_challenges(values) when is_list(values) do
    Req.Response.new(status: 402, headers: %{"www-authenticate" => values})
  end

  # mppx src/client/Transport.test.ts @ 4dc37a8. resource.url need not equal response.url.
  @x402_resource_response_pairs [
    {"https://api.example.com/x402", ""},
    {"https://api.example.com/x402", "http://api.example.com/x402"},
    {"https://api.example.com/x402", "https://other.example.com/x402"},
    {"https://api.example.com/x402", "https://api.example.com:8443/x402"},
    {"https://api.example.com/x402", "https://api.example.com/other"},
    {"https://api.example.com/x402", "https://api.example.com/x402"},
    {"https://api.example.com/x402", "https://api.example.com/x402?summary=hello"},
    {"https://api.example.com/x402?summary=hello", "https://api.example.com/x402?summary=world"},
    {"https://api.example.com/x402?summary=hello#details", "https://api.example.com/x402"}
  ]

  defp x402_required_response(resource_url) do
    {:ok, header} =
      X402Headers.encode_payment_required(%{
        "x402Version" => 2,
        "resource" => %{"url" => resource_url},
        "accepts" => [
          %{
            "scheme" => "exact",
            "network" => "eip155:84532",
            "amount" => "10000",
            "asset" => "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
            "payTo" => "0x209693Bc6afc0C5328bA36FaF03C514EF312287C",
            "maxTimeoutSeconds" => 60
          }
        ]
      })

    Req.Response.new(status: 402, headers: %{"payment-required" => [header]})
  end

  # -- payment_required?/1 --------------------------------------------------------

  describe "payment_required?/1" do
    test "true for 402" do
      assert HTTP.payment_required?(Req.Response.new(status: 402))
    end

    test "false for 200, 401, 403, 500" do
      for status <- [200, 401, 403, 500] do
        refute HTTP.payment_required?(Req.Response.new(status: status)),
               "expected false for status #{status}"
      end
    end
  end

  describe "retry_after/1" do
    test "parses the emitted delta-seconds form" do
      response = Req.Response.new(status: 402, headers: %{"retry-after" => [" 17 "]})
      assert {:ok, 17} = HTTP.retry_after(response)
    end

    test "rejects missing, repeated, non-integer, and non-positive values" do
      assert :error = HTTP.retry_after(Req.Response.new(status: 402))

      for values <- [["1", "2"], ["tomorrow"], ["0"], ["-1"], ["12 seconds"]] do
        response = Req.Response.new(status: 402, headers: %{"retry-after" => values})
        assert :error = HTTP.retry_after(response)
      end
    end
  end

  # -- get_challenges/1 -----------------------------------------------------------

  describe "get_challenges/1" do
    test "parses a single Payment challenge from one header" do
      challenge = make_challenge()
      response = response_with_challenges([Headers.format_challenge(challenge)])

      assert {:ok, [parsed]} = HTTP.get_challenges(response)
      assert parsed.id == challenge.id
      assert parsed.method == "tempo"
      assert parsed.intent == "charge"
    end

    test "parses two Payment challenges in a single comma-separated header" do
      tempo = Headers.format_challenge(make_challenge("tempo"))
      stripe = Headers.format_challenge(make_challenge("stripe"))
      response = response_with_challenges([tempo <> ", " <> stripe])

      assert {:ok, [c1, c2]} = HTTP.get_challenges(response)
      assert c1.method == "tempo"
      assert c2.method == "stripe"
    end

    test "parses challenges split across two repeated WWW-Authenticate headers" do
      tempo = Headers.format_challenge(make_challenge("tempo"))
      stripe = Headers.format_challenge(make_challenge("stripe"))
      response = response_with_challenges([tempo, stripe])

      assert {:ok, [c1, c2]} = HTTP.get_challenges(response)
      assert c1.method == "tempo"
      assert c2.method == "stripe"
    end

    test "returns error when only non-Payment schemes are present" do
      response = response_with_challenges([~s(Basic realm="example")])

      assert {:error, :no_payment_challenges} = HTTP.get_challenges(response)
    end

    test "returns error when WWW-Authenticate header is missing" do
      response = Req.Response.new(status: 402)

      assert {:error, :missing_www_authenticate} = HTTP.get_challenges(response)
    end
  end

  describe "get_challenges/2 x402 resource URL" do
    test "keeps one synthetic challenge for each mppx resource/response URL pair" do
      assert [_, _, _, _, _, _, _, _, _] = @x402_resource_response_pairs

      for {resource_url, response_url} <- @x402_resource_response_pairs do
        response = x402_required_response(resource_url)
        label = "resource #{resource_url} response #{inspect(response_url)}"

        assert {:ok, [challenge]} = HTTP.get_challenges(response, response_url),
               "expected one challenge for #{label}"

        assert X402.synthetic?(challenge), "expected a synthetic x402 challenge for #{label}"
        assert challenge.realm == "api.example.com"
        assert challenge.method == "evm"
        assert {:ok, %{"resource" => %{"url" => ^resource_url}}} = X402.exact_request(challenge)
      end
    end
  end

  # -- set_credential/2 -----------------------------------------------------------

  describe "set_credential/2" do
    test "sets Authorization: Payment <base64url> on the request" do
      challenge = make_challenge()
      credential = %Credential{challenge: challenge, payload: %{"type" => "hash"}, source: nil}
      request = %Req.Request{}

      updated = HTTP.set_credential(request, credential)

      assert [auth] = Req.Request.get_header(updated, "authorization")
      assert "Payment " <> blob = auth
      assert blob != ""
      # Round-trips through the canonical parser
      assert {:ok, parsed} = Headers.parse_credential(auth)
      assert parsed.challenge.id == challenge.id
    end

    test "preserves existing unrelated headers" do
      challenge = make_challenge()
      credential = %Credential{challenge: challenge, payload: %{"type" => "hash"}, source: nil}

      request =
        [url: "https://example.com"] |> Req.Request.new() |> Req.Request.put_header("content-type", "application/json")

      updated = HTTP.set_credential(request, credential)

      assert Req.Request.get_header(updated, "content-type") == ["application/json"]
      assert [_auth] = Req.Request.get_header(updated, "authorization")
    end

    test "attaches to Payment-Authorization when the challenge advertised header" do
      challenge =
        Challenge.create(
          [
            realm: "api.example.com",
            method: "tempo",
            intent: "charge",
            request: @request,
            header: "Payment-Authorization"
          ],
          @secret_key
        )

      credential = %Credential{challenge: challenge, payload: %{"type" => "hash"}, source: nil}
      request = %Req.Request{}

      updated = HTTP.set_credential(request, credential)

      assert Req.Request.get_header(updated, "authorization") == []
      assert [value] = Req.Request.get_header(updated, "payment-authorization")
      assert {:ok, parsed} = Headers.parse_credential(value)
      assert parsed.challenge.id == challenge.id
      assert parsed.challenge.header == "Payment-Authorization"
    end

    test "clears a stale Payment Authorization when attaching to Payment-Authorization" do
      challenge =
        Challenge.create(
          [
            realm: "api.example.com",
            method: "tempo",
            intent: "charge",
            request: @request,
            header: "Payment-Authorization"
          ],
          @secret_key
        )

      credential = %Credential{challenge: challenge, payload: %{"type" => "hash"}, source: nil}

      "Payment " <> token = Headers.format_credential(credential)

      for prefix <- ["Payment ", "payment ", "PAYMENT\t", "pAyMeNt  ", " \tpayment\t ", "payment\n"],
          payload <- [token, "stale", ""] do
        stale = prefix <> payload
        refute Headers.parse_credential(stale) == {:error, :invalid_scheme}

        request =
          %Req.Request{}
          |> Req.Request.put_header("authorization", stale)
          |> Req.Request.put_header("x-app", "keep")

        updated = HTTP.set_credential(request, credential)

        assert Req.Request.get_header(updated, "authorization") == [], inspect(stale)
        assert Req.Request.get_header(updated, "x-app") == ["keep"]
        assert Req.Request.get_header(updated, "payment-authorization") == [Headers.format_credential(credential)]
      end
    end

    test "preserves non-Payment Authorization when attaching to Payment-Authorization" do
      challenge =
        Challenge.create(
          [
            realm: "api.example.com",
            method: "tempo",
            intent: "charge",
            request: @request,
            header: "Payment-Authorization"
          ],
          @secret_key
        )

      credential = %Credential{challenge: challenge, payload: %{"type" => "hash"}, source: nil}

      for authorization <- ["Bearer ordinary", "Basic dXNlcjpwYXNz", "paymentish token", "payment", ""] do
        assert Headers.parse_credential(authorization) == {:error, :invalid_scheme}
        request = Req.Request.put_header(%Req.Request{}, "authorization", authorization)
        updated = HTTP.set_credential(request, credential)

        assert Req.Request.get_header(updated, "authorization") == [authorization]
        assert [_value] = Req.Request.get_header(updated, "payment-authorization")
      end
    end
  end

  # -- Transport.select_challenge/2 -----------------------------------------------

  describe "Transport.select_challenge/2" do
    test "picks the challenge whose method is supported" do
      challenges = [make_challenge("tempo"), make_challenge("stripe")]
      multi = MultiProvider.new([{StripeProvider, %{}}])

      assert {:ok, c} = Transport.select_challenge(challenges, multi)
      assert c.method == "stripe"
    end

    test "picks the first challenge when multiple are supported (server offer order)" do
      challenges = [make_challenge("tempo"), make_challenge("stripe")]
      multi = MultiProvider.new([{TempoProvider, %{}}, {StripeProvider, %{}}])

      assert {:ok, c} = Transport.select_challenge(challenges, multi)
      assert c.method == "tempo"
    end

    test "returns error when no challenge is supported" do
      challenges = [make_challenge("tempo"), make_challenge("stripe")]
      multi = MultiProvider.new([])

      assert {:error, :no_supported_challenge} = Transport.select_challenge(challenges, multi)
    end

    test "returns error on empty challenge list" do
      assert {:error, :no_supported_challenge} =
               Transport.select_challenge([], MultiProvider.new([{TempoProvider, %{}}]))
    end

    test "skips a challenge whose header is not Payment-Authorization" do
      payable = make_challenge("tempo")
      unrecognized = %{payable | header: "X-Custom"}
      multi = MultiProvider.new([{TempoProvider, %{}}])

      assert {:error, :no_supported_challenge} =
               Transport.select_challenge([unrecognized], multi)

      assert {:ok, ^payable} = Transport.select_challenge([unrecognized, payable], multi)
    end

    test "ranks by Accept-Payment before picking supported challenge" do
      challenges = [make_challenge("stripe"), make_challenge("tempo")]
      multi = MultiProvider.new([{TempoProvider, %{}}, {StripeProvider, %{}}])
      prefs = AcceptPayment.parse("stripe/charge, tempo/charge;q=0.5")

      assert {:ok, c} = Transport.select_challenge(challenges, multi, accept_payment: prefs)
      assert c.method == "stripe"
    end
  end

  describe "Transport.approve/2" do
    test "skips approval when the hook is nil" do
      assert :ok = Transport.approve(make_challenge("tempo"), nil)
    end

    test "returns :ok when the hook approves" do
      assert :ok = Transport.approve(make_challenge("tempo"), fn _challenge -> true end)
    end

    test "returns payment_declined when the hook denies" do
      assert {:error, :payment_declined} =
               Transport.approve(make_challenge("tempo"), fn _challenge -> false end)
    end

    test "raises when the hook does not return a boolean" do
      assert_raise ArgumentError, ~r/on_payment_required must return a boolean/, fn ->
        Transport.approve(make_challenge("tempo"), fn _challenge -> :maybe end)
      end
    end
  end

  describe "set_accept_payment/2" do
    test "sets Accept-Payment header from entries" do
      request = %Req.Request{}
      entries = AcceptPayment.parse("tempo/charge, stripe/charge;q=0.5")

      updated = HTTP.set_accept_payment(request, entries)

      assert [header] = Req.Request.get_header(updated, "accept-payment")
      assert header == "tempo/charge, stripe/charge;q=0.5"
    end

    test "does not overwrite existing Accept-Payment header" do
      request = Req.Request.put_header(%Req.Request{}, "accept-payment", "custom/charge")

      updated = HTTP.set_accept_payment(request, [{"tempo", "charge", 1.0}])

      assert Req.Request.get_header(updated, "accept-payment") == ["custom/charge"]
    end
  end

  describe "set_accept_payment_from_providers/3" do
    test "injects header from provider list when policy allows" do
      request = Req.Request.new(url: "https://app.example.com/api")

      updated =
        HTTP.set_accept_payment_from_providers(
          request,
          [{"tempo", "charge"}, {"stripe", "charge"}],
          {:same_origin, "https://app.example.com"}
        )

      assert [header] = Req.Request.get_header(updated, "accept-payment")
      assert header == "tempo/charge, stripe/charge"
    end

    test "skips injection when policy blocks cross-origin" do
      request = Req.Request.new(url: "https://other.example.com/api")

      updated =
        HTTP.set_accept_payment_from_providers(
          request,
          [{"tempo", "charge"}],
          {:same_origin, "https://app.example.com"}
        )

      assert Req.Request.get_header(updated, "accept-payment") == []
    end

    test "supports binary and absent request URLs" do
      binary_url_request = %Req.Request{url: "https://app.example.com/api"}
      absent_url_request = %Req.Request{url: nil}

      assert ["tempo/charge"] =
               binary_url_request
               |> HTTP.set_accept_payment_from_providers([{"tempo", "charge"}])
               |> Req.Request.get_header("accept-payment")

      assert ["tempo/charge"] =
               absent_url_request
               |> HTTP.set_accept_payment_from_providers([{"tempo", "charge"}])
               |> Req.Request.get_header("accept-payment")
    end
  end

  # -- Descripex annotation presence ---------------------------------------------

  test "HTTP module exposes Descripex metadata for all callbacks" do
    api = HTTP.__api__()
    names = for f <- api, do: f.name

    assert :payment_required? in names
    assert :get_challenges in names
    assert :set_credential in names
    assert :set_accept_payment in names
    assert :set_accept_payment_from_providers in names
  end

  test "moduledoc warns not to attach a credential after a cross-origin redirect" do
    # mpp-rs #379 (refs/mpp-rs/src/client/fetch.rs:256-272). Transport is passive;
    # the guard is consumer guidance here — MPP.Client.Req enforces it in code.
    {:docs_v1, _, :elixir, _, %{"en" => doc}, _, _} = Code.fetch_docs(HTTP)
    downcased = String.downcase(doc)
    assert downcased =~ "cross-origin"
    assert downcased =~ "must never be created or attached"
  end
end
