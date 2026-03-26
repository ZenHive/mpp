defmodule MPP.Methods.StripeTest do
  use ExUnit.Case, async: true

  alias MPP.Errors
  alias MPP.Intents.Charge
  alias MPP.Methods.Stripe
  alias MPP.Receipt

  @stripe_secret_key "sk_test_abc123"
  @network_id "profile_1MqDcVKA5fEO2tZvKQm9g8Yj"
  @spt "spt_1N4Zv32eZvKYlo2CPhVPkJlW"
  @pi_id "pi_3N4Zv42eZvKYlo2C0001"

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
      assert error.type =~ "verification-failed"
      assert error.detail =~ "canceled"
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
      assert error.type =~ "verification-failed"
      assert error.detail =~ "Your card was declined."
    end

    test "returns error on Stripe API error without message", %{charge: charge} do
      Req.Test.stub(Stripe, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => %{"type" => "invalid_request_error"}})
      end)

      assert {:error, %Errors{} = error} = Stripe.verify(%{"spt" => @spt}, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "invalid_request_error"
    end

    test "returns error on network failure", %{charge: charge} do
      Req.Test.stub(Stripe, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, %Errors{} = error} = Stripe.verify(%{"spt" => @spt}, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "request failed"
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
end
