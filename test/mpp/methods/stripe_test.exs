defmodule MPP.Methods.StripeTest do
  use ExUnit.Case, async: true

  alias MPP.Credential
  alias MPP.Errors
  alias MPP.Headers
  alias MPP.Intents.Charge
  alias MPP.Methods.Stripe
  alias MPP.Plug, as: PaymentPlug
  alias MPP.Receipt

  @stripe_secret_key "sk_test_abc123"
  @network_id "profile_1MqDcVKA5fEO2tZvKQm9g8Yj"
  @spt "spt_1N4Zv32eZvKYlo2CPhVPkJlW"
  @pi_id "pi_3N4Zv42eZvKYlo2C0001"
  @hmac_secret "test-hmac-secret-for-stripe-stubs"
  @realm "api.example.com"

  setup do
    {:ok, charge} =
      Charge.new(
        amount: "5000",
        currency: "usd",
        recipient: "acct_test"
      )

    # Simulate what Plug does: merge method_config into charge.method_details
    charge = %{
      charge
      | method_details: %{
          "stripe_secret_key" => @stripe_secret_key,
          "network_id" => @network_id,
          "payment_method_types" => ["card"],
          "challenge_id" => "ch_test123",
          "realm" => "api.example.com",
          "req_options" => [plug: {Req.Test, Stripe}]
        }
    }

    {:ok, charge: charge}
  end

  describe "method_name/0" do
    test "returns \"stripe\"" do
      assert Stripe.method_name() == "stripe"
    end
  end

  describe "verify/2" do
    test "returns receipt on successful PaymentIntent", %{charge: charge} do
      Req.Test.stub(Stripe, fn conn ->
        Req.Test.json(conn, %{
          "id" => @pi_id,
          "status" => "succeeded",
          "amount" => 5000,
          "currency" => "usd"
        })
      end)

      payload = %{"spt" => @spt}
      assert {:ok, %Receipt{} = receipt} = Stripe.verify(payload, charge)
      assert receipt.method == "stripe"
      assert receipt.reference == @pi_id
      assert receipt.status == "success"
      assert receipt.timestamp
    end

    test "echoes externalId from payload to receipt", %{charge: charge} do
      Req.Test.stub(Stripe, fn conn ->
        Req.Test.json(conn, %{"id" => @pi_id, "status" => "succeeded"})
      end)

      payload = %{"spt" => @spt, "externalId" => "order_42"}
      assert {:ok, %Receipt{} = receipt} = Stripe.verify(payload, charge)
      assert receipt.external_id == "order_42"
    end

    test "rejects credential externalId that disagrees with route request", %{charge: charge} do
      charge = %{charge | external_id: "order_42"}

      assert {:error, %Errors{} = error} =
               Stripe.verify(%{"spt" => @spt, "externalId" => "order_99"}, charge)

      assert error.type =~ "invalid-challenge"
      assert error.detail =~ "externalId"
    end

    test "allows missing credential externalId when route has externalId", %{charge: charge} do
      Req.Test.stub(Stripe, fn conn ->
        Req.Test.json(conn, %{"id" => @pi_id, "status" => "succeeded"})
      end)

      charge = %{charge | external_id: "order_42"}
      assert {:ok, _} = Stripe.verify(%{"spt" => @spt}, charge)
    end

    test "returns error when spt is missing", %{charge: charge} do
      assert {:error, %Errors{} = error} = Stripe.verify(%{}, charge)
      assert error.type =~ "invalid-payload"
      assert error.detail =~ "spt"
    end

    test "returns error when spt is empty string", %{charge: charge} do
      assert {:error, %Errors{} = error} = Stripe.verify(%{"spt" => ""}, charge)
      assert error.type =~ "invalid-payload"
    end

    test "returns error when spt is not a string", %{charge: charge} do
      assert {:error, %Errors{} = error} = Stripe.verify(%{"spt" => 123}, charge)
      assert error.type =~ "invalid-payload"
    end

    test "returns error when PaymentIntent requires action (3DS)", %{charge: charge} do
      Req.Test.stub(Stripe, fn conn ->
        Req.Test.json(conn, %{"id" => @pi_id, "status" => "requires_action"})
      end)

      assert {:error, %Errors{} = error} = Stripe.verify(%{"spt" => @spt}, charge)
      assert error.status == 402
      assert error.type =~ "verification-failed"
      assert error.detail =~ "requires action"
    end

    test "returns error when PaymentIntent has unexpected status", %{charge: charge} do
      Req.Test.stub(Stripe, fn conn ->
        Req.Test.json(conn, %{"id" => @pi_id, "status" => "canceled"})
      end)

      assert {:error, %Errors{} = error} = Stripe.verify(%{"spt" => @spt}, charge)
      assert error.status == 402
      assert error.type =~ "verification-failed"
      assert error.detail =~ "canceled"
    end

    test "returns error when Stripe replays an idempotent credential", %{charge: charge} do
      Req.Test.stub(Stripe, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("idempotent-replayed", "true")
        |> Req.Test.json(%{"id" => @pi_id, "status" => "succeeded"})
      end)

      assert {:error, %Errors{} = error} = Stripe.verify(%{"spt" => @spt}, charge)
      assert error.status == 402
      assert error.type =~ "verification-failed"
      assert error.detail == "Payment has already been processed."
    end

    test "returns error on Stripe API error response", %{charge: charge} do
      Req.Test.stub(Stripe, fn conn ->
        conn
        |> Plug.Conn.put_status(402)
        |> Req.Test.json(%{
          "error" => %{
            "type" => "card_error",
            "message" => "Your card was declined."
          }
        })
      end)

      assert {:error, %Errors{} = error} = Stripe.verify(%{"spt" => @spt}, charge)
      assert error.status == 402
      assert error.type =~ "verification-failed"
      assert error.detail == "Stripe PaymentIntent creation failed"
      refute error.detail =~ "Your card was declined."
      refute error.detail =~ "card_error"
    end

    test "returns error on Stripe API error without message", %{charge: charge} do
      Req.Test.stub(Stripe, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => %{"type" => "invalid_request_error"}})
      end)

      assert {:error, %Errors{} = error} = Stripe.verify(%{"spt" => @spt}, charge)
      assert error.status == 402
      assert error.detail == "Stripe PaymentIntent creation failed"
      refute error.detail =~ "invalid_request_error"
    end

    test "returns error on network failure", %{charge: charge} do
      Req.Test.stub(Stripe, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, %Errors{} = error} = Stripe.verify(%{"spt" => @spt}, charge)
      assert error.type =~ "verification-failed"
      assert error.detail == "Stripe API request failed"
    end

    test "returns error when stripe_secret_key is missing" do
      {:ok, charge} = Charge.new(amount: "5000", currency: "usd")

      # No method_details at all
      assert {:error, %Errors{} = error} = Stripe.verify(%{"spt" => @spt}, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "stripe_secret_key"
    end

    test "sends correct request body to Stripe API", %{charge: charge} do
      test_pid = self()

      Req.Test.stub(Stripe, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, body})
        send(test_pid, {:request_headers, conn.req_headers})
        Req.Test.json(conn, %{"id" => @pi_id, "status" => "succeeded"})
      end)

      assert {:ok, _receipt} = Stripe.verify(%{"spt" => @spt}, charge)

      assert_received {:request_body, body}
      params = URI.decode_query(body)

      assert params["amount"] == "5000"
      assert params["currency"] == "usd"
      assert params["confirm"] == "true"
      assert params["shared_payment_granted_token"] == @spt
      assert params["automatic_payment_methods[enabled]"] == "true"
      assert params["automatic_payment_methods[allow_redirects]"] == "never"
    end

    test "sends idempotency key with challenge_id and spt", %{charge: charge} do
      test_pid = self()

      Req.Test.stub(Stripe, fn conn ->
        send(test_pid, {:request_headers, conn.req_headers})
        Req.Test.json(conn, %{"id" => @pi_id, "status" => "succeeded"})
      end)

      assert {:ok, _receipt} = Stripe.verify(%{"spt" => @spt}, charge)

      assert_received {:request_headers, headers}
      {_, idempotency_key} = List.keyfind(headers, "idempotency-key", 0)
      assert idempotency_key == "mpp_ch_test123_#{@spt}"
    end

    test "sends analytics metadata", %{charge: charge} do
      test_pid = self()

      Req.Test.stub(Stripe, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, body})
        Req.Test.json(conn, %{"id" => @pi_id, "status" => "succeeded"})
      end)

      assert {:ok, _receipt} = Stripe.verify(%{"spt" => @spt}, charge)

      assert_received {:request_body, body}
      params = URI.decode_query(body)

      assert params["metadata[mpp_version]"] == "1"
      assert params["metadata[mpp_is_mpp]"] == "true"
      assert params["metadata[mpp_challenge_id]"] == "ch_test123"
      assert params["metadata[mpp_server_id]"] == "api.example.com"
    end

    test "sends Basic auth header with stripe secret key", %{charge: charge} do
      test_pid = self()

      Req.Test.stub(Stripe, fn conn ->
        send(test_pid, {:request_headers, conn.req_headers})
        Req.Test.json(conn, %{"id" => @pi_id, "status" => "succeeded"})
      end)

      assert {:ok, _receipt} = Stripe.verify(%{"spt" => @spt}, charge)

      assert_received {:request_headers, headers}
      {_, auth} = List.keyfind(headers, "authorization", 0)
      expected_auth = "Basic " <> Base.encode64(@stripe_secret_key <> ":")
      assert auth == expected_auth
    end

    test "idempotency key uses spt only when challenge_id is nil", %{charge: charge} do
      test_pid = self()

      charge = %{
        charge
        | method_details: Map.delete(charge.method_details, "challenge_id")
      }

      Req.Test.stub(Stripe, fn conn ->
        send(test_pid, {:request_headers, conn.req_headers})
        Req.Test.json(conn, %{"id" => @pi_id, "status" => "succeeded"})
      end)

      assert {:ok, _receipt} = Stripe.verify(%{"spt" => @spt}, charge)

      assert_received {:request_headers, headers}
      {_, idempotency_key} = List.keyfind(headers, "idempotency-key", 0)
      assert idempotency_key == "mpp_#{@spt}"
    end

    test "metadata excludes challenge_id and realm when nil", %{charge: charge} do
      test_pid = self()

      charge = %{
        charge
        | method_details:
            charge.method_details
            |> Map.delete("challenge_id")
            |> Map.delete("realm")
      }

      Req.Test.stub(Stripe, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, body})
        Req.Test.json(conn, %{"id" => @pi_id, "status" => "succeeded"})
      end)

      assert {:ok, _receipt} = Stripe.verify(%{"spt" => @spt}, charge)

      assert_received {:request_body, body}
      params = URI.decode_query(body)

      assert params["metadata[mpp_version]"] == "1"
      assert params["metadata[mpp_is_mpp]"] == "true"
      refute Map.has_key?(params, "metadata[mpp_challenge_id]")
      refute Map.has_key?(params, "metadata[mpp_server_id]")
    end

    test "returns error on plain string error body", %{charge: charge} do
      Req.Test.stub(Stripe, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(500, "Internal Server Error")
      end)

      assert {:error, %Errors{} = error} = Stripe.verify(%{"spt" => @spt}, charge)
      assert error.type =~ "verification-failed"
    end

    test "returns error on unexpected response body format", %{charge: charge} do
      Req.Test.stub(Stripe, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"totally" => "unexpected"})
      end)

      assert {:error, %Errors{} = error} = Stripe.verify(%{"spt" => @spt}, charge)
      assert error.type =~ "verification-failed"
    end

    test "handles missing status field in response", %{charge: charge} do
      Req.Test.stub(Stripe, fn conn ->
        Req.Test.json(conn, %{"id" => @pi_id})
      end)

      assert {:error, %Errors{} = error} = Stripe.verify(%{"spt" => @spt}, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "missing status"
    end
  end

  describe "validate_config!/1" do
    test "accepts config with all required keys" do
      config = %{"stripe_secret_key" => "sk_test_...", "network_id" => "profile_..."}
      assert :ok = Stripe.validate_config!(config)
    end

    test "raises when stripe_secret_key is missing" do
      assert_raise ArgumentError, ~r/stripe_secret_key/, fn ->
        Stripe.validate_config!(%{"network_id" => "profile_..."})
      end
    end

    test "raises when network_id is missing" do
      assert_raise ArgumentError, ~r/network_id/, fn ->
        Stripe.validate_config!(%{"stripe_secret_key" => "sk_test_..."})
      end
    end

    test "raises when both required keys are missing" do
      assert_raise ArgumentError, ~r/stripe_secret_key/, fn ->
        Stripe.validate_config!(%{})
      end
    end
  end

  describe "challenge_method_details/1" do
    test "returns networkId and paymentMethodTypes from config" do
      {:ok, charge} = Charge.new(amount: "5000", currency: "usd")

      charge = %{
        charge
        | method_details: %{
            "network_id" => @network_id,
            "payment_method_types" => ["card", "link"]
          }
      }

      details = Stripe.challenge_method_details(charge)
      assert details == %{"networkId" => @network_id, "paymentMethodTypes" => ["card", "link"]}
    end

    test "defaults payment_method_types to [\"card\"]" do
      {:ok, charge} = Charge.new(amount: "5000", currency: "usd")
      charge = %{charge | method_details: %{"network_id" => @network_id}}

      details = Stripe.challenge_method_details(charge)
      assert details == %{"networkId" => @network_id, "paymentMethodTypes" => ["card"]}
    end

    test "returns nil when network_id is missing" do
      {:ok, charge} = Charge.new(amount: "5000", currency: "usd")
      assert Stripe.challenge_method_details(charge) == nil
    end

    test "returns nil when method_details is nil" do
      {:ok, charge} = Charge.new(amount: "5000", currency: "usd")
      assert charge.method_details == nil
      assert Stripe.challenge_method_details(charge) == nil
    end
  end

  describe "stub-server parity scenarios (mpp-rs)" do
    setup do
      config =
        PaymentPlug.init(
          secret_key: @hmac_secret,
          realm: @realm,
          method: Stripe,
          amount: "5000",
          currency: "usd",
          external_id: "premium-001",
          method_config: %{
            "stripe_secret_key" => @stripe_secret_key,
            "network_id" => @network_id,
            "payment_method_types" => ["card"],
            "req_options" => [plug: {Req.Test, Stripe}]
          }
        )

      {:ok, config: config}
    end

    test "402 challenge includes externalId and methodDetails", %{config: config} do
      conn =
        :get
        |> Plug.Test.conn("/api/data")
        |> PaymentPlug.call(config)

      assert conn.status == 402

      [challenge_header] = Plug.Conn.get_resp_header(conn, "www-authenticate")
      assert {:ok, challenge} = Headers.parse_challenge(challenge_header)
      assert {:ok, request_map} = decode_challenge_request(challenge)

      assert request_map["externalId"] == "premium-001"
      assert request_map["methodDetails"]["networkId"] == @network_id
      assert request_map["methodDetails"]["paymentMethodTypes"] == ["card"]
    end

    test "requires_action PaymentIntent returns 402 through plug", %{config: config} do
      Req.Test.stub(Stripe, fn conn ->
        Req.Test.json(conn, %{"id" => @pi_id, "status" => "requires_action"})
      end)

      conn = submit_stripe_credential(config)

      assert conn.status == 402
      body = Jason.decode!(conn.resp_body)
      assert body["type"] =~ "verification-failed"
      assert body["detail"] =~ "requires action"
    end

    test "non-succeeded PaymentIntent status returns 402 through plug", %{config: config} do
      Req.Test.stub(Stripe, fn conn ->
        Req.Test.json(conn, %{"id" => @pi_id, "status" => "processing"})
      end)

      conn = submit_stripe_credential(config)

      assert conn.status == 402
      body = Jason.decode!(conn.resp_body)
      assert body["type"] =~ "verification-failed"
      assert body["detail"] =~ "processing"
    end

    test "replayed idempotent credential returns 402 through plug", %{config: config} do
      Req.Test.stub(Stripe, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("idempotent-replayed", "true")
        |> Req.Test.json(%{"id" => @pi_id, "status" => "succeeded"})
      end)

      conn = submit_stripe_credential(config)

      assert conn.status == 402
      body = Jason.decode!(conn.resp_body)
      assert body["type"] =~ "verification-failed"
      assert body["detail"] == "Payment has already been processed."
    end

    test "Stripe 400 error body returns 402 through plug", %{config: config} do
      Req.Test.stub(Stripe, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{
          "error" => %{
            "message" => "Invalid payment token",
            "type" => "invalid_request_error",
            "code" => "resource_missing"
          }
        })
      end)

      conn = submit_stripe_credential(config)

      assert conn.status == 402
      body = Jason.decode!(conn.resp_body)
      assert body["type"] =~ "verification-failed"
      assert body["detail"] == "Stripe PaymentIntent creation failed"
    end

    test "externalId from credential payload is echoed in receipt when it matches route request", %{
      config: config
    } do
      Req.Test.stub(Stripe, fn conn ->
        Req.Test.json(conn, %{"id" => @pi_id, "status" => "succeeded"})
      end)

      conn = submit_stripe_credential(config, external_id: "premium-001")

      assert conn.status == nil
      receipt = conn.assigns[:mpp_receipt]
      assert receipt.external_id == "premium-001"
      assert receipt.reference == @pi_id

      [receipt_header] = Plug.Conn.get_resp_header(conn, "payment-receipt")
      assert {:ok, parsed_receipt} = Headers.parse_receipt(receipt_header)
      assert parsed_receipt.external_id == "premium-001"
    end
  end

  defp submit_stripe_credential(config, opts \\ []) do
    conn_402 =
      :get
      |> Plug.Test.conn("/api/data")
      |> PaymentPlug.call(config)

    [challenge_header] = Plug.Conn.get_resp_header(conn_402, "www-authenticate")
    {:ok, challenge} = Headers.parse_challenge(challenge_header)

    payload = %{"spt" => @spt}

    payload =
      case Keyword.get(opts, :external_id) do
        nil -> payload
        external_id -> Map.put(payload, "externalId", external_id)
      end

    credential = %Credential{challenge: challenge, payload: payload}
    auth_header = Headers.format_credential(credential)

    :get
    |> Plug.Test.conn("/api/data")
    |> Plug.Conn.put_req_header("authorization", auth_header)
    |> PaymentPlug.call(config)
  end

  defp decode_challenge_request(challenge) do
    with {:ok, json} <- Base.url_decode64(challenge.request, padding: false) do
      Jason.decode(json)
    end
  end
end
