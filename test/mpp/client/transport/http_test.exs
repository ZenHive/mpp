defmodule MPP.Client.Transport.HTTPTest do
  use ExUnit.Case, async: true

  alias MPP.Challenge
  alias MPP.Client.MultiProvider
  alias MPP.Client.PaymentProvider
  alias MPP.Client.Transport
  alias MPP.Client.Transport.HTTP
  alias MPP.Credential
  alias MPP.Headers

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
  end

  # -- Descripex annotation presence ---------------------------------------------

  test "HTTP module exposes Descripex metadata for all callbacks" do
    api = HTTP.__api__()
    names = for f <- api, do: f.name

    assert :payment_required? in names
    assert :get_challenges in names
    assert :set_credential in names
  end
end
