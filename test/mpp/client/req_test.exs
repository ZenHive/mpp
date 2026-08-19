defmodule MPP.Client.ReqTest do
  use ExUnit.Case, async: true

  alias MPP.Challenge
  alias MPP.Client.MultiProvider
  alias MPP.Client.PaymentProvider
  alias MPP.Client.Req, as: ClientReq
  alias MPP.Credential
  alias MPP.Demo.Router
  alias MPP.Headers

  @secret_key "test-secret-key"
  @request "eyJhbW91bnQiOiIxMDAwIiwiY3VycmVuY3kiOiJ1c2QifQ"

  defmodule TempoProvider do
    @moduledoc false
    use PaymentProvider

    @impl PaymentProvider
    def supports?(method, intent, _config), do: method == "tempo" and intent == "charge"

    @impl PaymentProvider
    def pay(challenge, config) do
      if pid = config[:test_pid], do: send(pid, {:paid, challenge.method})

      {:ok,
       %Credential{
         challenge: challenge,
         payload: %{"type" => "hash", "hash" => "0xabc"},
         source: nil
       }}
    end
  end

  defmodule StripeProvider do
    @moduledoc false
    use PaymentProvider

    @impl PaymentProvider
    def supports?(method, intent, _config), do: method == "stripe" and intent == "charge"

    @impl PaymentProvider
    def pay(challenge, config) do
      if pid = config[:test_pid], do: send(pid, {:paid, challenge.method})

      {:ok, %Credential{challenge: challenge, payload: %{"spt" => "spt_test"}, source: nil}}
    end
  end

  defmodule FailingProvider do
    @moduledoc false
    use PaymentProvider

    @impl PaymentProvider
    def supports?(_method, _intent, _config), do: true

    @impl PaymentProvider
    def pay(_challenge, _config), do: {:error, :payment_failed}
  end

  defmodule DemoProvider do
    @moduledoc false
    use PaymentProvider

    @impl PaymentProvider
    def supports?(method, intent, _config), do: method == "demo" and intent == "charge"

    @impl PaymentProvider
    def pay(challenge, _config) do
      {:ok, %Credential{challenge: challenge, payload: %{"token" => "demo-token"}, source: nil}}
    end
  end

  defp make_challenge(method) do
    Challenge.create(
      [realm: "api.example.com", method: method, intent: "charge", request: @request],
      @secret_key
    )
  end

  defp challenge_header(method) do
    method
    |> make_challenge()
    |> Headers.format_challenge()
  end

  defp client(plug, opts) do
    [plug: plug]
    |> Req.new()
    |> ClientReq.attach(opts)
  end

  describe "attach/2" do
    test "requires a provider" do
      assert_raise ArgumentError, ~r/:provider/, fn ->
        ClientReq.attach(Req.new(), [])
      end
    end

    test "rejects a negative retry budget" do
      assert_raise ArgumentError, ~r/max_payment_retries/, fn ->
        ClientReq.attach(Req.new(), provider: TempoProvider, max_payment_retries: -1)
      end
    end

    test "accepts a MultiProvider, a tuple, and a bare module" do
      multi = MultiProvider.new([{TempoProvider, %{}}])

      assert %Req.Request{} = ClientReq.attach(Req.new(), provider: multi)
      assert %Req.Request{} = ClientReq.attach(Req.new(), provider: {TempoProvider, %{}})
      assert %Req.Request{} = ClientReq.attach(Req.new(), provider: TempoProvider)
    end

    test "Error.message/1 uses the explicit message or inspects the reason" do
      with_message = %ClientReq.Error{reason: :no_supported_challenge, message: "no configured provider"}
      assert Exception.message(with_message) == "no configured provider"

      without_message = %ClientReq.Error{reason: :boom}
      assert Exception.message(without_message) == "MPP payment failed: :boom"
    end

    test "rejects an invalid selection policy" do
      assert_raise ArgumentError, ~r/:selection/, fn ->
        ClientReq.attach(Req.new(), provider: TempoProvider, selection: :newest)
      end
    end
  end

  describe "non-402 passthrough" do
    test "leaves a 200 response untouched and does not pay" do
      plug = fn conn ->
        Plug.Conn.send_resp(conn, 200, "ok")
      end

      req = client(plug, provider: {TempoProvider, %{test_pid: self()}})

      assert {:ok, %Req.Response{status: 200, body: "ok"}} =
               Req.get(req, url: "http://example.com/ok")

      refute_received {:paid, _}
    end
  end

  describe "402 detection and retry" do
    test "pays the selected challenge and retries with Authorization" do
      challenge = make_challenge("tempo")
      header = Headers.format_challenge(challenge)

      plug = fn conn ->
        case Plug.Conn.get_req_header(conn, "authorization") do
          [] ->
            conn
            |> Plug.Conn.put_resp_header("www-authenticate", header)
            |> Plug.Conn.send_resp(402, "pay")

          ["Payment " <> _blob] ->
            Plug.Conn.send_resp(conn, 200, "paid")
        end
      end

      req = client(plug, provider: {TempoProvider, %{test_pid: self()}})

      assert {:ok, %Req.Response{status: 200, body: "paid"}} =
               Req.get(req, url: "http://example.com/resource")

      assert_received {:paid, "tempo"}
    end

    test "selects the first supported challenge in server order" do
      plug = fn conn ->
        case Plug.Conn.get_req_header(conn, "authorization") do
          [] ->
            conn
            |> Plug.Conn.put_resp_header(
              "www-authenticate",
              challenge_header("tempo") <> ", " <> challenge_header("stripe")
            )
            |> Plug.Conn.send_resp(402, "pay")

          _auth ->
            Plug.Conn.send_resp(conn, 200, "paid")
        end
      end

      req =
        client(plug,
          provider: MultiProvider.new([{TempoProvider, %{test_pid: self()}}, {StripeProvider, %{test_pid: self()}}])
        )

      assert {:ok, %Req.Response{status: 200}} = Req.get(req, url: "http://example.com/resource")
      assert_received {:paid, "tempo"}
      refute_received {:paid, "stripe"}
    end

    test "accept_payment entries rank challenges when :selection is omitted" do
      plug = fn conn ->
        case Plug.Conn.get_req_header(conn, "authorization") do
          [] ->
            conn
            |> Plug.Conn.put_resp_header(
              "www-authenticate",
              challenge_header("tempo") <> ", " <> challenge_header("stripe")
            )
            |> Plug.Conn.send_resp(402, "pay")

          _auth ->
            Plug.Conn.send_resp(conn, 200, "paid")
        end
      end

      req =
        client(plug,
          provider: MultiProvider.new([{TempoProvider, %{test_pid: self()}}, {StripeProvider, %{test_pid: self()}}]),
          accept_payment: [{"stripe", "charge", 1.0}, {"tempo", "charge", 0.1}]
        )

      assert {:ok, %Req.Response{status: 200}} = Req.get(req, url: "http://example.com/resource")
      assert_received {:paid, "stripe"}
      refute_received {:paid, "tempo"}
    end

    test "custom selection policy can prefer a later offer" do
      plug = fn conn ->
        case Plug.Conn.get_req_header(conn, "authorization") do
          [] ->
            conn
            |> Plug.Conn.put_resp_header(
              "www-authenticate",
              challenge_header("tempo") <> ", " <> challenge_header("stripe")
            )
            |> Plug.Conn.send_resp(402, "pay")

          _auth ->
            Plug.Conn.send_resp(conn, 200, "paid")
        end
      end

      req =
        client(plug,
          provider: MultiProvider.new([{TempoProvider, %{test_pid: self()}}, {StripeProvider, %{test_pid: self()}}]),
          selection: fn challenges -> Enum.reverse(challenges) end
        )

      assert {:ok, %Req.Response{status: 200}} = Req.get(req, url: "http://example.com/resource")
      assert_received {:paid, "stripe"}
      refute_received {:paid, "tempo"}
    end

    test "returns an error when no provider supports the offers" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("www-authenticate", challenge_header("tempo"))
        |> Plug.Conn.send_resp(402, "pay")
      end

      req = client(plug, provider: MultiProvider.new([]))

      assert {:error, %ClientReq.Error{reason: :no_supported_challenge}} =
               Req.get(req, url: "http://example.com/resource")
    end

    test "returns an error when payment execution fails" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("www-authenticate", challenge_header("tempo"))
        |> Plug.Conn.send_resp(402, "pay")
      end

      req = client(plug, provider: FailingProvider)

      assert {:error, %ClientReq.Error{reason: :payment_failed}} =
               Req.get(req, url: "http://example.com/resource")
    end

    test "returns an error when the 402 has no Payment challenge" do
      plug = fn conn ->
        Plug.Conn.send_resp(conn, 402, "pay")
      end

      req = client(plug, provider: TempoProvider)

      assert {:error, %ClientReq.Error{reason: :missing_www_authenticate}} =
               Req.get(req, url: "http://example.com/resource")
    end

    test "stops after max_payment_retries and returns the last 402" do
      header = challenge_header("tempo")

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("www-authenticate", header)
        |> Plug.Conn.send_resp(402, "still-pay")
      end

      req =
        client(plug,
          provider: {TempoProvider, %{test_pid: self()}},
          max_payment_retries: 1
        )

      assert {:ok, %Req.Response{status: 402, body: "still-pay"}} =
               Req.get(req, url: "http://example.com/resource")

      assert_received {:paid, "tempo"}
      refute_received {:paid, _}
    end

    test "a paid retry that omits WWW-Authenticate returns the 402" do
      plug = fn conn ->
        case Plug.Conn.get_req_header(conn, "authorization") do
          [] ->
            conn
            |> Plug.Conn.put_resp_header("www-authenticate", challenge_header("tempo"))
            |> Plug.Conn.send_resp(402, "pay")

          _auth ->
            Plug.Conn.send_resp(conn, 402, "rejected")
        end
      end

      req = client(plug, provider: {TempoProvider, %{test_pid: self()}})

      assert {:ok, %Req.Response{status: 402, body: "rejected"}} =
               Req.get(req, url: "http://example.com/resource")

      assert_received {:paid, "tempo"}
    end

    test "explicit {:accept_payment, entries} selection ranks challenges" do
      plug = fn conn ->
        case Plug.Conn.get_req_header(conn, "authorization") do
          [] ->
            conn
            |> Plug.Conn.put_resp_header(
              "www-authenticate",
              challenge_header("tempo") <> ", " <> challenge_header("stripe")
            )
            |> Plug.Conn.send_resp(402, "pay")

          _auth ->
            Plug.Conn.send_resp(conn, 200, "paid")
        end
      end

      req =
        client(plug,
          provider: MultiProvider.new([{TempoProvider, %{test_pid: self()}}, {StripeProvider, %{test_pid: self()}}]),
          selection: {:accept_payment, [{"stripe", "charge", 1.0}, {"tempo", "charge", 0.1}]}
        )

      assert {:ok, %Req.Response{status: 200}} = Req.get(req, url: "http://example.com/resource")
      assert_received {:paid, "stripe"}
      refute_received {:paid, "tempo"}
    end

    test "explicit :selection wins over :accept_payment ranking" do
      plug = fn conn ->
        case Plug.Conn.get_req_header(conn, "authorization") do
          [] ->
            conn
            |> Plug.Conn.put_resp_header(
              "www-authenticate",
              challenge_header("tempo") <> ", " <> challenge_header("stripe")
            )
            |> Plug.Conn.send_resp(402, "pay")

          _auth ->
            Plug.Conn.send_resp(conn, 200, "paid")
        end
      end

      req =
        client(plug,
          provider: MultiProvider.new([{TempoProvider, %{test_pid: self()}}, {StripeProvider, %{test_pid: self()}}]),
          accept_payment: [{"stripe", "charge", 1.0}, {"tempo", "charge", 0.1}],
          selection: :server_order
        )

      assert {:ok, %Req.Response{status: 200}} = Req.get(req, url: "http://example.com/resource")
      assert_received {:paid, "tempo"}
      refute_received {:paid, "stripe"}
    end

    test "refuses to pay after a cross-origin redirect" do
      header = challenge_header("tempo")

      plug = fn conn ->
        case {conn.host, conn.request_path} do
          {"good.example", "/resource"} ->
            conn
            |> Plug.Conn.put_resp_header("location", "http://evil.example/resource")
            |> Plug.Conn.send_resp(302, "redirect")

          {"evil.example", "/resource"} ->
            send(self(), {:evil_auth, Plug.Conn.get_req_header(conn, "authorization")})

            conn
            |> Plug.Conn.put_resp_header("www-authenticate", header)
            |> Plug.Conn.send_resp(402, "pay")

          _other ->
            Plug.Conn.send_resp(conn, 500, "unexpected")
        end
      end

      req = client(plug, provider: {TempoProvider, %{test_pid: self()}})

      assert {:error, %ClientReq.Error{reason: :cross_origin_redirect} = error} =
               Req.get(req, url: "http://good.example/resource")

      assert Exception.message(error) =~ "cross-origin redirect"
      refute_received {:paid, _}
      assert_received {:evil_auth, []}
    end

    test "pays after a same-origin redirect" do
      header = challenge_header("tempo")

      plug = fn conn ->
        case conn.request_path do
          "/start" ->
            conn
            |> Plug.Conn.put_resp_header("location", "/resource")
            |> Plug.Conn.send_resp(302, "")

          "/resource" ->
            case Plug.Conn.get_req_header(conn, "authorization") do
              [] ->
                conn
                |> Plug.Conn.put_resp_header("www-authenticate", header)
                |> Plug.Conn.send_resp(402, "pay")

              _auth ->
                Plug.Conn.send_resp(conn, 200, "paid")
            end

          _other ->
            Plug.Conn.send_resp(conn, 500, "unexpected")
        end
      end

      req = client(plug, provider: {TempoProvider, %{test_pid: self()}})

      assert {:ok, %Req.Response{status: 200, body: "paid"}} =
               Req.get(req, url: "http://example.com/start")

      assert_received {:paid, "tempo"}
    end

    test "a paid retry that offers no supported challenge returns the 402" do
      tempo = challenge_header("tempo")
      stripe = challenge_header("stripe")

      plug = fn conn ->
        case Plug.Conn.get_req_header(conn, "authorization") do
          [] ->
            conn
            |> Plug.Conn.put_resp_header("www-authenticate", tempo)
            |> Plug.Conn.send_resp(402, "tempo")

          _auth ->
            conn
            |> Plug.Conn.put_resp_header("www-authenticate", stripe)
            |> Plug.Conn.send_resp(402, "stripe-only")
        end
      end

      req = client(plug, provider: {TempoProvider, %{test_pid: self()}})

      assert {:ok, %Req.Response{status: 402, body: "stripe-only"}} =
               Req.get(req, url: "http://example.com/resource")

      assert_received {:paid, "tempo"}
    end
  end

  describe "Accept-Payment advertisement" do
    test "injects Accept-Payment from configured entries" do
      plug = fn conn ->
        send(self(), {:accept, Plug.Conn.get_req_header(conn, "accept-payment")})
        Plug.Conn.send_resp(conn, 200, "ok")
      end

      req =
        client(plug,
          provider: TempoProvider,
          accept_payment: [%{method: "tempo", intent: "charge", q: 1.0}]
        )

      assert {:ok, %Req.Response{status: 200}} = Req.get(req, url: "http://example.com/ok")
      assert_received {:accept, ["tempo/charge"]}
    end

    test "preserves Accept-Payment q values on the wire" do
      plug = fn conn ->
        send(self(), {:accept, Plug.Conn.get_req_header(conn, "accept-payment")})
        Plug.Conn.send_resp(conn, 200, "ok")
      end

      req =
        client(plug,
          provider: TempoProvider,
          accept_payment: [{"stripe", "charge", 1.0}, {"tempo", "charge", 0.1}]
        )

      assert {:ok, %Req.Response{status: 200}} = Req.get(req, url: "http://example.com/ok")
      assert_received {:accept, ["stripe/charge, tempo/charge;q=0.1"]}
    end

    test "respects AcceptPolicy when injection is blocked" do
      plug = fn conn ->
        send(self(), {:accept, Plug.Conn.get_req_header(conn, "accept-payment")})
        Plug.Conn.send_resp(conn, 200, "ok")
      end

      req =
        client(plug,
          provider: TempoProvider,
          accept_payment: [{"tempo", "charge", 1.0}],
          accept_policy: :never
        )

      assert {:ok, %Req.Response{status: 200}} = Req.get(req, url: "http://example.com/ok")
      assert_received {:accept, []}
    end
  end

  describe "mix mpp.demo server" do
    test "pays the demo challenge and retrieves /resource" do
      req =
        [plug: Router]
        |> Req.new()
        |> ClientReq.attach(provider: {DemoProvider, %{}})

      assert {:ok, %Req.Response{status: 200} = response} =
               Req.get(req, url: "http://localhost/resource")

      body = response.body
      body = if is_binary(body), do: Jason.decode!(body), else: body

      assert body["message"] =~ "You paid"
      assert body["payment"]["method"] == "demo"
      assert [_receipt] = Req.Response.get_header(response, "payment-receipt")
    end

    test "does not intercept the unprotected /health endpoint" do
      req =
        [plug: Router]
        |> Req.new()
        |> ClientReq.attach(provider: {DemoProvider, %{}})

      assert {:ok, %Req.Response{status: 200} = response} =
               Req.get(req, url: "http://localhost/health")

      body = response.body
      body = if is_binary(body), do: Jason.decode!(body), else: body
      assert body == %{"status" => "ok"}
    end
  end
end
