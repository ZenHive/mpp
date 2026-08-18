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

    test "echoes externalId from route request to receipt", %{charge: charge} do
      Req.Test.stub(Stripe, fn conn ->
        Req.Test.json(conn, %{"id" => @pi_id, "status" => "succeeded"})
      end)

      charge = %{charge | external_id: "order_42"}
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

    test "rejects missing credential externalId when route has externalId", %{charge: charge} do
      charge = %{charge | external_id: "order_42"}

      assert {:error, %Errors{} = error} = Stripe.verify(%{"spt" => @spt}, charge)
      assert error.type =~ "invalid-challenge"
      assert error.detail =~ "externalId"
    end

    test "ignores payload-only externalId when route has no externalId", %{charge: charge} do
      Req.Test.stub(Stripe, fn conn ->
        Req.Test.json(conn, %{"id" => @pi_id, "status" => "succeeded"})
      end)

      assert {:ok, receipt} = Stripe.verify(%{"spt" => @spt, "externalId" => "attacker-order"}, charge)
      assert receipt.external_id == nil
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

    # The intent layer keeps the operator's currency string verbatim for wire
    # parity with mpp-rs/mppx, so the lowercase ISO 4217 code Stripe's API
    # documents has to be produced at this boundary.
    test "lowercases the currency for Stripe even when the charge preserves case", %{charge: charge} do
      charge = %{charge | currency: "USD"}
      test_pid = self()

      Req.Test.stub(Stripe, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, body})
        Req.Test.json(conn, %{"id" => @pi_id, "status" => "succeeded"})
      end)

      assert {:ok, _receipt} = Stripe.verify(%{"spt" => @spt}, charge)

      assert_received {:request_body, body}
      assert URI.decode_query(body)["currency"] == "usd"
      assert charge.currency == "USD"
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

  describe "Stripe Connect settlement" do
    # Capture the outgoing PaymentIntent request (body params + headers) so we can
    # assert the exact wire mapping against the mppx reference.
    defp capture_request(charge, connect, payload \\ %{"spt" => @spt}) do
      test_pid = self()

      charge = %{charge | method_details: Map.put(charge.method_details, "connect", connect)}

      Req.Test.stub(Stripe, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:captured, URI.decode_query(body), conn.req_headers})
        Req.Test.json(conn, %{"id" => @pi_id, "status" => "succeeded"})
      end)

      result = Stripe.verify(payload, charge)
      {result, receive_captured()}
    end

    defp receive_captured do
      receive do
        {:captured, params, headers} -> {params, headers}
      after
        0 -> {nil, nil}
      end
    end

    test "destination charge sends transfer_data[destination] and amount", %{charge: charge} do
      {result, {params, _headers}} =
        capture_request(charge, %{"transfer_data" => %{"destination" => "acct_seller", "amount" => 4000}})

      assert {:ok, %Receipt{}} = result
      assert params["transfer_data[destination]"] == "acct_seller"
      assert params["transfer_data[amount]"] == "4000"
    end

    test "destination charge without transfer amount omits transfer_data[amount]", %{charge: charge} do
      {result, {params, _headers}} =
        capture_request(charge, %{"transfer_data" => %{"destination" => "acct_seller"}})

      assert {:ok, %Receipt{}} = result
      assert params["transfer_data[destination]"] == "acct_seller"
      refute Map.has_key?(params, "transfer_data[amount]")
    end

    test "direct charge sends Stripe-Account header", %{charge: charge} do
      {result, {_params, headers}} = capture_request(charge, %{"stripe_account" => "acct_seller"})

      assert {:ok, %Receipt{}} = result
      assert {_, "acct_seller"} = List.keyfind(headers, "stripe-account", 0)
    end

    test "application fee routing sends application_fee_amount", %{charge: charge} do
      {result, {params, _headers}} = capture_request(charge, %{"application_fee_amount" => 500})

      assert {:ok, %Receipt{}} = result
      assert params["application_fee_amount"] == "500"
    end

    test "sends on_behalf_of and transfer_group", %{charge: charge} do
      {result, {params, _headers}} =
        capture_request(charge, %{"on_behalf_of" => "acct_seller", "transfer_group" => "order_42"})

      assert {:ok, %Receipt{}} = result
      assert params["on_behalf_of"] == "acct_seller"
      assert params["transfer_group"] == "order_42"
    end

    test "no connect config leaves the body free of Connect params", %{charge: charge} do
      test_pid = self()

      Req.Test.stub(Stripe, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, URI.decode_query(body), conn.req_headers})
        Req.Test.json(conn, %{"id" => @pi_id, "status" => "succeeded"})
      end)

      assert {:ok, _} = Stripe.verify(%{"spt" => @spt}, charge)
      assert_received {:request_body, params, headers}

      refute Map.has_key?(params, "application_fee_amount")
      refute Map.has_key?(params, "on_behalf_of")
      refute Map.has_key?(params, "transfer_data[destination]")
      refute Map.has_key?(params, "transfer_group")
      assert List.keyfind(headers, "stripe-account", 0) == nil

      # The SPT preview version pin is sent on every PaymentIntent request,
      # Connect or not (mppx stripePreviewVersion).
      assert {_, "2026-02-25.preview"} = List.keyfind(headers, "stripe-version", 0)
    end

    test "rejects application_fee_amount exceeding the payment amount", %{charge: charge} do
      charge = %{charge | method_details: Map.put(charge.method_details, "connect", %{"application_fee_amount" => 6000})}

      assert {:error, %Errors{} = error} = Stripe.verify(%{"spt" => @spt}, charge)
      assert error.type =~ "verification-failed"
      assert error.detail =~ "less than or equal to"
    end

    test "rejects negative application_fee_amount", %{charge: charge} do
      charge = %{charge | method_details: Map.put(charge.method_details, "connect", %{"application_fee_amount" => -1})}

      assert {:error, %Errors{} = error} = Stripe.verify(%{"spt" => @spt}, charge)
      assert error.detail =~ "non-negative integer"
    end

    test "rejects transfer_data.amount exceeding the payment amount", %{charge: charge} do
      connect = %{"transfer_data" => %{"destination" => "acct_seller", "amount" => 9999}}
      charge = %{charge | method_details: Map.put(charge.method_details, "connect", connect)}

      assert {:error, %Errors{} = error} = Stripe.verify(%{"spt" => @spt}, charge)
      assert error.detail =~ "transfer_data.amount"
      assert error.detail =~ "less than or equal to"
    end

    test "rejects transfer_data missing a destination", %{charge: charge} do
      connect = %{"transfer_data" => %{"amount" => 100}}
      charge = %{charge | method_details: Map.put(charge.method_details, "connect", connect)}

      assert {:error, %Errors{} = error} = Stripe.verify(%{"spt" => @spt}, charge)
      assert error.detail =~ "transfer_data.destination"
    end

    test "rejects empty stripe_account", %{charge: charge} do
      charge = %{charge | method_details: Map.put(charge.method_details, "connect", %{"stripe_account" => ""})}

      assert {:error, %Errors{} = error} = Stripe.verify(%{"spt" => @spt}, charge)
      assert error.detail =~ "stripe_account"
      assert error.detail =~ "non-empty"
    end

    test "rejects empty on_behalf_of", %{charge: charge} do
      charge = %{charge | method_details: Map.put(charge.method_details, "connect", %{"on_behalf_of" => ""})}

      assert {:error, %Errors{} = error} = Stripe.verify(%{"spt" => @spt}, charge)
      assert error.detail =~ "on_behalf_of"
      assert error.detail =~ "non-empty"
    end

    test "rejects non-map connect config", %{charge: charge} do
      charge = %{charge | method_details: Map.put(charge.method_details, "connect", "acct_seller")}

      assert {:error, %Errors{} = error} = Stripe.verify(%{"spt" => @spt}, charge)
      assert error.detail =~ "must be a map"
    end

    test "rejects non-map transfer_data", %{charge: charge} do
      charge = %{charge | method_details: Map.put(charge.method_details, "connect", %{"transfer_data" => "acct"})}

      assert {:error, %Errors{} = error} = Stripe.verify(%{"spt" => @spt}, charge)
      assert error.detail =~ "transfer_data must be a map"
    end

    test "rejects non-string transfer_group", %{charge: charge} do
      charge = %{charge | method_details: Map.put(charge.method_details, "connect", %{"transfer_group" => %{}})}

      assert {:error, %Errors{} = error} = Stripe.verify(%{"spt" => @spt}, charge)
      assert error.detail =~ "transfer_group must be a string"
    end

    test "rejects settlement when the charge amount is not a valid integer", %{charge: charge} do
      charge = %{
        charge
        | amount: "not-a-number",
          method_details: Map.put(charge.method_details, "connect", %{"application_fee_amount" => 1})
      }

      assert {:error, %Errors{} = error} = Stripe.verify(%{"spt" => @spt}, charge)
      assert error.detail =~ "Stripe amount must be a non-negative integer"
    end

    test "invalid settlement is rejected before any Stripe API call", %{charge: charge} do
      charge = %{
        charge
        | method_details: Map.put(charge.method_details, "connect", %{"application_fee_amount" => 99_999})
      }

      # A stub that flunks proves no HTTP request is issued when settlement is invalid.
      Req.Test.stub(Stripe, fn _conn -> flunk("Stripe API must not be called for invalid settlement") end)

      assert {:error, %Errors{}} = Stripe.verify(%{"spt" => @spt}, charge)
    end
  end

  describe "cross-validation with mppx Stripe Connect output (src/stripe/server/Charge.ts)" do
    test "full settlement config produces the exact mppx form body + header", %{charge: charge} do
      test_pid = self()

      # Equivalent to the mppx ConnectSettlement:
      #   { stripeAccount, applicationFeeAmount, onBehalfOf, transferData: {destination, amount}, transferGroup }
      connect = %{
        "stripe_account" => "acct_platform",
        "application_fee_amount" => 500,
        "on_behalf_of" => "acct_merchant",
        "transfer_data" => %{"destination" => "acct_seller", "amount" => 4000},
        "transfer_group" => "order_42"
      }

      charge = %{charge | method_details: Map.put(charge.method_details, "connect", connect)}

      Req.Test.stub(Stripe, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:captured, URI.decode_query(body), conn.req_headers})
        Req.Test.json(conn, %{"id" => @pi_id, "status" => "succeeded"})
      end)

      assert {:ok, _} = Stripe.verify(%{"spt" => @spt}, charge)
      assert_received {:captured, params, headers}

      # Body params — mppx createWithSecretKey (form-encoded) mapping.
      assert params["application_fee_amount"] == "500"
      assert params["on_behalf_of"] == "acct_merchant"
      assert params["transfer_data[destination]"] == "acct_seller"
      assert params["transfer_data[amount]"] == "4000"
      assert params["transfer_group"] == "order_42"

      # stripe_account routes to the Stripe-Account header, never the body.
      assert {_, "acct_platform"} = List.keyfind(headers, "stripe-account", 0)
      refute Map.has_key?(params, "stripe_account")

      # SPT preview version pin — mppx stripePreviewVersion
      # (refs/mppx/src/stripe/internal/constants.ts).
      assert {_, "2026-02-25.preview"} = List.keyfind(headers, "stripe-version", 0)

      # Base PaymentIntent params remain intact alongside settlement.
      assert params["amount"] == "5000"
      assert params["confirm"] == "true"
      assert params["shared_payment_granted_token"] == @spt
    end

    test "Connect settlement never leaks into the public 402 challenge" do
      config =
        PaymentPlug.init(
          secret_key: @hmac_secret,
          realm: @realm,
          method: Stripe,
          amount: "5000",
          currency: "usd",
          method_config: %{
            "stripe_secret_key" => @stripe_secret_key,
            "network_id" => @network_id,
            "connect" => %{"transfer_data" => %{"destination" => "acct_secret"}}
          }
        )

      conn =
        :get
        |> Plug.Test.conn("/api/data")
        |> PaymentPlug.call(config)

      [challenge_header] = Plug.Conn.get_resp_header(conn, "www-authenticate")
      {:ok, challenge} = Headers.parse_challenge(challenge_header)
      {:ok, request_map} = decode_challenge_request(challenge)

      # Public challenge advertises only networkId/paymentMethodTypes — no connect topology.
      assert request_map["methodDetails"]["networkId"] == @network_id
      refute Map.has_key?(request_map["methodDetails"], "connect")
      refute Map.has_key?(request_map["methodDetails"], "transfer_data")
      refute challenge_header =~ "acct_secret"
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

      conn = submit_stripe_credential(config, external_id: "premium-001")

      assert conn.status == 402
      body = Jason.decode!(conn.resp_body)
      assert body["type"] =~ "verification-failed"
      assert body["detail"] =~ "requires action"
    end

    test "non-succeeded PaymentIntent status returns 402 through plug", %{config: config} do
      Req.Test.stub(Stripe, fn conn ->
        Req.Test.json(conn, %{"id" => @pi_id, "status" => "processing"})
      end)

      conn = submit_stripe_credential(config, external_id: "premium-001")

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

      conn = submit_stripe_credential(config, external_id: "premium-001")

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

      conn = submit_stripe_credential(config, external_id: "premium-001")

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

  defp submit_stripe_credential(config, opts) do
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
