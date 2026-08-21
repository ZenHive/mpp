defmodule MPP.Test.StripeLifecycleStore do
  @moduledoc false

  @spec get(String.t(), keyword()) :: term()
  def get(_id, opts), do: Keyword.fetch!(opts, :get)

  @spec put(MPP.Subscription.Record.t(), keyword()) :: :ok
  def put(_record, _opts), do: :ok

  @spec update(String.t(), MPP.Subscription.Store.update_fun(), keyword()) :: term()
  def update(_id, fun, opts) do
    case Keyword.fetch!(opts, :update) do
      {:apply, current} -> fun.(current)
      result -> result
    end
  end

  @spec delete(String.t(), keyword()) :: :ok
  def delete(_id, _opts), do: :ok
end

defmodule MPP.Methods.StripeTest do
  use ExUnit.Case, async: true

  alias MPP.Credential
  alias MPP.Errors
  alias MPP.Headers
  alias MPP.Intents.Charge
  alias MPP.Intents.Subscription
  alias MPP.Methods.Stripe
  alias MPP.Methods.Stripe.Subscription, as: StripeSubscription
  alias MPP.Plug, as: PaymentPlug
  alias MPP.Receipt
  alias MPP.Subscription.ETSStore, as: SubscriptionStore
  alias MPP.Subscription.Record
  alias MPP.Subscription.Store
  alias MPP.Test.StripeLifecycleStore

  @stripe_secret_key "sk_test_abc123"
  @network_id "profile_1MqDcVKA5fEO2tZvKQm9g8Yj"
  @spt "spt_1N4Zv32eZvKYlo2CPhVPkJlW"
  @pi_id "pi_3N4Zv42eZvKYlo2C0001"
  @hmac_secret "test-hmac-secret-for-stripe-stubs"
  @realm "api.example.com"

  setup do
    subscription_store_name = :"#{__MODULE__}.#{System.unique_integer([:positive])}"
    start_supervised!(SubscriptionStore.child_spec(name: subscription_store_name))
    Process.put({__MODULE__, :subscription_store}, {SubscriptionStore, [name: subscription_store_name]})

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

  describe "subscription intent" do
    test "Plug init validates config and serializes only public Stripe method details" do
      config =
        PaymentPlug.init(
          secret_key: @hmac_secret,
          realm: @realm,
          intent: "subscription",
          method: Stripe,
          amount: "5000",
          currency: "usd",
          period_unit: "week",
          period_count: "1",
          external_id: "plan_42",
          method_config: %{
            "stripe_secret_key" => @stripe_secret_key,
            "network_id" => @network_id,
            "payment_method_types" => ["card", "link"],
            "metadata" => %{"plan" => "weekly-pro"},
            "req_options" => [plug: {Req.Test, Stripe}]
          }
        )

      [entry] = config.method_entries
      request = entry.request |> Base.url_decode64!(padding: false) |> Jason.decode!()

      assert request["amount"] == "5000"
      assert request["periodUnit"] == "week"
      assert request["periodCount"] == "1"
      assert request["externalId"] == "plan_42"

      assert request["methodDetails"] == %{
               "networkId" => @network_id,
               "paymentMethodTypes" => ["card", "link"],
               "metadata" => %{"plan" => "weekly-pro"}
             }

      refute entry.request =~ @stripe_secret_key
      refute Map.has_key?(request["methodDetails"], "stripe_secret_key")
      refute Map.has_key?(request["methodDetails"], "req_options")
      refute Map.has_key?(request["methodDetails"], "intent")
    end

    test "Plug init rejects Stripe Connect settlement for subscriptions" do
      assert_raise ArgumentError, ~r/does not support Stripe Connect/, fn ->
        PaymentPlug.init(
          secret_key: @hmac_secret,
          realm: @realm,
          intent: "subscription",
          method: Stripe,
          amount: "5000",
          currency: "usd",
          period_unit: "week",
          period_count: "1",
          method_config: %{
            "stripe_secret_key" => @stripe_secret_key,
            "network_id" => @network_id,
            "connect" => %{"stripe_account" => "acct_seller"}
          }
        )
      end
    end

    test "validates subscription-only method config at init" do
      valid = subscription_config()
      assert :ok = Stripe.validate_config!(valid)

      for {key, value, message} <- [
            {"stripe_secret_key", "", "stripe_secret_key"},
            {"network_id", "", "network_id"},
            {"payment_method_types", [], "payment_method_types"},
            {"payment_method_types", ["card", "card"], "payment_method_types"},
            {"payment_method_types", ["us_bank_account"], "payment_method_types"},
            {"metadata", %{"bad[key]" => "value"}, "metadata"},
            {"metadata", %{"plan" => 42}, "metadata"},
            {"connect", %{}, "does not support Stripe Connect"}
          ] do
        assert_raise ArgumentError, ~r/#{message}/, fn ->
          valid |> Map.put(key, value) |> Stripe.validate_config!()
        end
      end

      assert_raise ArgumentError, ~r/subscription_store must implement/, fn ->
        valid |> Map.put("subscription_store", String) |> Stripe.validate_config!()
      end
    end

    test "rejects subscription requests outside the constrained Stripe profile" do
      for {overrides, message} <- [
            {[recipient: "acct_recipient"], "must not include recipient"},
            {[subscription_expires: "2030-01-01T00:00:00Z"], "must not include subscriptionExpires"},
            {[currency: "USD"], "lowercase ISO 4217"},
            {[period_unit: :day, period_count: "1096"], "supported day cadence"},
            {[period_unit: :week, period_count: "157"], "supported week cadence"},
            {[period_unit: :month, period_count: "37"], "supported month cadence"}
          ] do
        assert_raise ArgumentError, ~r/#{message}/, fn ->
          overrides |> stripe_subscription() |> Stripe.challenge_method_details()
        end
      end

      for {period_unit, period_count} <- [day: "1095", week: "156", month: "36"] do
        details =
          Stripe.challenge_method_details(stripe_subscription(period_unit: period_unit, period_count: period_count))

        assert details["paymentMethodTypes"] == ["card"]
      end
    end

    test "activates one fixed-price subscription and validates the paid first invoice" do
      stub_subscription_flow()
      subscription = stripe_subscription(external_id: "plan_42")

      assert {:ok, %Receipt{} = receipt} =
               Stripe.verify(%{"paymentMethod" => "pm_input"}, subscription)

      assert receipt.method == "stripe"
      assert receipt.reference == "in_test"
      assert receipt.external_id == "plan_42"
      assert byte_size(receipt.subscription_id) == 24
      assert receipt.extensions == %{"stripeSubscription" => "sub_test"}
      assert receipt.timestamp == "2023-11-14T22:13:30Z"

      assert {:ok, %Record{} = record} = Store.get(subscription_store(), receipt.subscription_id)
      assert record.method == "stripe"
      assert record.billing_anchor == ~U[2023-11-14 22:13:20Z]
      assert record.last_charged_period == 0
      assert %{0 => %{period: 0, reference: "in_test", event_ids: []}} = record.payments

      assert record.method_state == %{
               stripe_subscription_id: "sub_test",
               customer_id: "cus_test",
               payment_method_id: "pm_test",
               price_id: "price_test"
             }

      refute Map.has_key?(record, :source)
      refute Map.has_key?(record, :access_key)
      refute Map.has_key?(record, :key_authorization)

      assert_received {:stripe_request, "POST", "/v1/customers", customer_params, customer_headers}
      assert customer_params["description"] == "MPP subscription payer"
      assert customer_params["metadata[mpp_challenge_id]"] == "ch_subscription"
      assert customer_params["metadata[mpp_external_id]"] == "plan_42"
      assert idempotency_header(customer_headers) =~ "mpp-subscription-customer-"
      assert List.keyfind(customer_headers, "stripe-version", 0) == {"stripe-version", "2026-02-25.clover"}

      assert_received {:stripe_request, "POST", "/v1/payment_methods/pm_test/attach", attach_params, _headers}
      assert attach_params == %{"customer" => "cus_test"}

      assert_received {:stripe_request, "POST", "/v1/products", product_params, _headers}
      assert product_params["name"] == "MPP subscription"

      assert_received {:stripe_request, "POST", "/v1/prices", price_params, _headers}
      assert price_params["unit_amount"] == "5000"
      assert price_params["currency"] == "usd"
      assert price_params["recurring[interval]"] == "day"
      assert price_params["recurring[interval_count]"] == "1"

      assert_received {:stripe_request, "POST", "/v1/subscriptions", subscription_params, _headers}
      assert subscription_params["collection_method"] == "charge_automatically"
      assert subscription_params["payment_behavior"] == "error_if_incomplete"
      assert subscription_params["proration_behavior"] == "none"
      assert subscription_params["items[0][quantity]"] == "1"
      assert subscription_params["default_payment_method"] == "pm_test"
      assert subscription_params["automatic_tax[enabled]"] == "false"

      assert_received {:stripe_request, "GET", "/v1/invoices/in_test", %{}, invoice_headers}
      assert idempotency_header(invoice_headers) == nil
      refute_received {:stripe_request, "DELETE", "/v1/subscriptions/sub_test", _params, _headers}
    end

    test "reuses an existing customer-bound PaymentMethod without mutating either" do
      stub_subscription_flow(payment_customer: "cus_test")
      subscription = stripe_subscription()

      assert {:ok, %Receipt{}} =
               Stripe.verify(%{"paymentMethod" => "pm_input", "customer" => "cus_test"}, subscription)

      assert_received {:stripe_request, "GET", "/v1/customers/cus_test", %{}, _headers}
      refute_received {:stripe_request, "POST", "/v1/customers", _params, _headers}
      refute_received {:stripe_request, "POST", "/v1/payment_methods/pm_test/attach", _params, _headers}
    end

    test "records one canonical period under concurrent duplicate renewal events" do
      stub_subscription_flow()
      subscription = stripe_subscription()
      assert {:ok, activation} = Stripe.verify(%{"paymentMethod" => "pm_input"}, subscription)

      renewal = stripe_renewal_invoice_fixture("in_renewal", 1)
      Req.Test.stub(Stripe, &Req.Test.json(&1, renewal))

      results =
        1..12
        |> Enum.map(fn _index ->
          Task.async(fn ->
            StripeSubscription.process_invoice("evt_renewal", "in_renewal", subscription.method_details)
          end)
        end)
        |> Task.await_many()

      assert Enum.all?(results, &match?({:ok, %Receipt{reference: "in_renewal"}}, &1))
      assert {:ok, record} = Store.get(subscription_store(), activation.subscription_id)
      assert record.last_charged_period == 1
      assert map_size(record.payments) == 2
      assert record.payments[1].event_ids == ["evt_renewal"]

      assert {:ok, duplicate} =
               StripeSubscription.process_invoice(
                 "evt_renewal_retry",
                 "in_renewal",
                 subscription.method_details
               )

      assert duplicate.reference == "in_renewal"
      assert {:ok, retried} = Store.get(subscription_store(), activation.subscription_id)
      assert Enum.sort(retried.payments[1].event_ids) == ~w(evt_renewal evt_renewal_retry)
      assert map_size(retried.payments) == 2
    end

    test "returns the persisted activation on retry and rejects conflicting durable state" do
      stub_subscription_flow()
      subscription = stripe_subscription()
      assert {:ok, first} = Stripe.verify(%{"paymentMethod" => "pm_input"}, subscription)

      stub_subscription_flow()
      assert {:ok, ^first} = Stripe.verify(%{"paymentMethod" => "pm_input"}, subscription)

      assert {:ok, _changed} =
               Store.update(subscription_store(), first.subscription_id, fn record ->
                 {:ok, put_in(record.method_state.price_id, "price_other")}
               end)

      stub_subscription_flow()

      assert {:error, %Errors{detail: "Stripe subscription activation conflicts with durable state"}} =
               Stripe.verify(%{"paymentMethod" => "pm_input"}, subscription)
    end

    test "rejects malformed renewal events, payment proofs, and activation-period replays" do
      assert {:error, %Errors{type: type}} = StripeSubscription.process_invoice(nil, nil, nil)
      assert type =~ "invalid-payload"
      assert {:error, %Errors{type: cancel_type}} = StripeSubscription.cancel(nil, nil)
      assert cancel_type =~ "invalid-payload"

      stub_subscription_flow()
      subscription = stripe_subscription()
      assert {:ok, _activation} = Stripe.verify(%{"paymentMethod" => "pm_input"}, subscription)

      cases = [
        {"in_not_cycle", "evt_not_cycle", &Map.delete(&1, "billing_reason")},
        {"in_bad_payment", "evt_bad_payment",
         fn invoice ->
           update_in(invoice["payments"]["data"], fn [paid] ->
             paid = %{paid | "amount_paid" => 4999}
             [%{paid | "payment" => put_in(paid["payment"], ["payment_intent", "amount_received"], 4999)}]
           end)
         end},
        {"in_no_payment", "evt_no_payment", &Map.delete(&1, "payments")},
        {"in_period_zero", "evt_period_zero", &put_invoice_period(&1, 1_700_000_000, 1_700_086_400)}
      ]

      for {invoice_id, event_id, transform} <- cases do
        invoice = transform.(stripe_renewal_invoice_fixture(invoice_id, 1))
        Req.Test.stub(Stripe, &Req.Test.json(&1, invoice))

        assert {:error, %Errors{detail: "Stripe renewal invoice does not match the subscription"}} =
                 StripeSubscription.process_invoice(event_id, invoice_id, subscription.method_details)
      end
    end

    test "rejects a second invoice and reused event for an already paid period" do
      stub_subscription_flow()
      subscription = stripe_subscription()
      assert {:ok, activation} = Stripe.verify(%{"paymentMethod" => "pm_input"}, subscription)

      Req.Test.stub(Stripe, &Req.Test.json(&1, stripe_renewal_invoice_fixture("in_renewal", 1)))

      assert {:ok, %Receipt{}} =
               StripeSubscription.process_invoice("evt_renewal", "in_renewal", subscription.method_details)

      Req.Test.stub(Stripe, fn conn ->
        invoice_id = Path.basename(conn.request_path)
        Req.Test.json(conn, stripe_renewal_invoice_fixture(invoice_id, 1))
      end)

      for {event_id, invoice_id} <- [
            {"evt_other", "in_other"},
            {"evt_renewal", "in_other"}
          ] do
        assert {:error, %Errors{detail: "Stripe renewal invoice does not match the subscription"}} =
                 StripeSubscription.process_invoice(event_id, invoice_id, subscription.method_details)
      end

      assert {:ok, record} = Store.get(subscription_store(), activation.subscription_id)
      assert record.payments |> Map.keys() |> Enum.sort() == [0, 1]
    end

    test "rejects a skipped canonical period and the same invoice on a later period" do
      stub_subscription_flow()
      subscription = stripe_subscription()
      assert {:ok, activation} = Stripe.verify(%{"paymentMethod" => "pm_input"}, subscription)

      Req.Test.stub(Stripe, &Req.Test.json(&1, stripe_renewal_invoice_fixture("in_period_two", 2)))

      assert {:error, %Errors{detail: "Stripe renewal invoice does not match the subscription"}} =
               StripeSubscription.process_invoice("evt_period_two", "in_period_two", subscription.method_details)

      Req.Test.stub(Stripe, &Req.Test.json(&1, stripe_renewal_invoice_fixture("in_renewal", 1)))

      assert {:ok, %Receipt{}} =
               StripeSubscription.process_invoice("evt_renewal", "in_renewal", subscription.method_details)

      reused =
        "in_renewal"
        |> stripe_renewal_invoice_fixture(2)
        |> Map.put("id", "in_renewal")

      Req.Test.stub(Stripe, &Req.Test.json(&1, reused))

      assert {:error, %Errors{detail: "Stripe renewal invoice does not match the subscription"}} =
               StripeSubscription.process_invoice("evt_reused_invoice", "in_renewal", subscription.method_details)

      Req.Test.stub(Stripe, &Req.Test.json(&1, stripe_renewal_invoice_fixture("in_period_two", 2)))

      assert {:ok, %Receipt{reference: "in_period_two"}} =
               StripeSubscription.process_invoice("evt_period_two", "in_period_two", subscription.method_details)

      assert {:ok, record} = Store.get(subscription_store(), activation.subscription_id)
      assert record.last_charged_period == 2
      assert record.payments |> Map.keys() |> Enum.sort() == [0, 1, 2]
    end

    test "rejects a renewal whose Stripe period drifts from the activation anchor" do
      stub_subscription_flow()
      subscription = stripe_subscription()
      assert {:ok, activation} = Stripe.verify(%{"paymentMethod" => "pm_input"}, subscription)

      invoice =
        "in_drifted"
        |> stripe_renewal_invoice_fixture(1)
        |> update_in(["lines", "data", Access.at(0), "period", "start"], &(&1 + 1))

      Req.Test.stub(Stripe, &Req.Test.json(&1, invoice))

      assert {:error, %Errors{detail: "Stripe renewal invoice does not match the subscription"}} =
               StripeSubscription.process_invoice("evt_drifted", "in_drifted", subscription.method_details)

      assert {:ok, %{payments: payments}} = Store.get(subscription_store(), activation.subscription_id)
      assert Map.keys(payments) == [0]
    end

    test "maps month renewals to calendar periods anchored at the first invoice" do
      january_31 = 1_706_659_200
      february_29 = 1_709_164_800
      march_31 = 1_711_843_200

      stub_subscription_flow(
        price_transform: &put_in(&1, ["recurring", "interval"], "month"),
        subscription_transform: &put_subscription_period(&1, january_31, february_29),
        invoice_transform: &put_invoice_period(&1, january_31, february_29)
      )

      subscription = stripe_subscription(period_unit: :month)
      assert {:ok, activation} = Stripe.verify(%{"paymentMethod" => "pm_input"}, subscription)

      renewal =
        "in_monthly_renewal"
        |> stripe_renewal_invoice_fixture(1)
        |> put_invoice_period(february_29, march_31)

      Req.Test.stub(Stripe, &Req.Test.json(&1, renewal))

      assert {:ok, %Receipt{reference: "in_monthly_renewal"}} =
               StripeSubscription.process_invoice(
                 "evt_monthly_renewal",
                 "in_monthly_renewal",
                 subscription.method_details
               )

      assert {:ok, record} = Store.get(subscription_store(), activation.subscription_id)
      assert record.billing_anchor == ~U[2024-01-31 00:00:00Z]
      assert record.payments |> Map.keys() |> Enum.sort() == [0, 1]
    end

    test "maps week renewals and rejects periods between multi-month boundaries" do
      week_end = 1_700_604_800
      second_week_end = 1_701_209_600

      stub_subscription_flow(
        price_transform: &put_in(&1, ["recurring", "interval"], "week"),
        subscription_transform: &put_subscription_period(&1, 1_700_000_000, week_end),
        invoice_transform: &put_invoice_period(&1, 1_700_000_000, week_end)
      )

      weekly = stripe_subscription(period_unit: :week)
      assert {:ok, _activation} = Stripe.verify(%{"paymentMethod" => "pm_input"}, weekly)

      renewal =
        "in_weekly"
        |> stripe_renewal_invoice_fixture(1)
        |> put_invoice_period(week_end, second_week_end)

      Req.Test.stub(Stripe, &Req.Test.json(&1, renewal))

      assert {:ok, %Receipt{reference: "in_weekly"}} =
               StripeSubscription.process_invoice("evt_weekly", "in_weekly", weekly.method_details)

      january_31 = 1_706_659_200
      february_29 = 1_709_164_800
      march_31 = 1_711_843_200
      april_29 = 1_714_348_800

      stub_subscription_flow(
        price_transform: fn price ->
          price
          |> put_in(["recurring", "interval"], "month")
          |> put_in(["recurring", "interval_count"], 2)
        end,
        subscription_transform: &put_subscription_period(&1, january_31, march_31),
        invoice_transform: &put_invoice_period(&1, january_31, march_31)
      )

      two_month_details = Map.put(weekly.method_details, "challenge_id", "ch_two_months")

      every_two_months =
        stripe_subscription(period_unit: :month, period_count: "2", method_details: two_month_details)

      assert {:ok, _activation} = Stripe.verify(%{"paymentMethod" => "pm_input"}, every_two_months)

      between_periods =
        "in_between_months"
        |> stripe_renewal_invoice_fixture(1)
        |> put_invoice_period(february_29, april_29)
        |> put_in(["parent", "subscription_details", "metadata", "mpp_challenge_id"], "ch_two_months")

      Req.Test.stub(Stripe, &Req.Test.json(&1, between_periods))

      assert {:error, %Errors{detail: "Stripe renewal invoice does not match the subscription"}} =
               StripeSubscription.process_invoice(
                 "evt_between_months",
                 "in_between_months",
                 every_two_months.method_details
               )
    end

    test "rejects an activation period that does not match the Stripe cadence" do
      stub_subscription_flow(price_transform: &put_in(&1, ["recurring", "interval"], "month"))

      assert {:error, %Errors{detail: "Stripe first invoice does not match the subscription request"}} =
               Stripe.verify(%{"paymentMethod" => "pm_input"}, stripe_subscription(period_unit: :month))
    end

    test "schedules cancellation at the end of the last paid canonical period" do
      stub_subscription_flow()
      subscription = stripe_subscription()
      assert {:ok, activation} = Stripe.verify(%{"paymentMethod" => "pm_input"}, subscription)

      Req.Test.stub(Stripe, &Req.Test.json(&1, stripe_renewal_invoice_fixture("in_renewal", 1)))

      assert {:ok, %Receipt{}} =
               StripeSubscription.process_invoice("evt_renewal", "in_renewal", subscription.method_details)

      test_pid = self()

      Req.Test.stub(Stripe, fn conn ->
        {params, conn} = capture_stripe_request(conn, test_pid)

        Req.Test.json(conn, %{
          "id" => "sub_test",
          "cancel_at" => String.to_integer(params["cancel_at"]),
          "cancel_at_period_end" => true
        })
      end)

      assert {:ok, canceled} = StripeSubscription.cancel(activation.subscription_id, subscription.method_details)
      assert canceled.cancellation_effective_at == ~U[2023-11-16 22:13:20Z]
      assert canceled.in_flight_reference == nil

      assert_received {:stripe_request, "POST", "/v1/subscriptions/sub_test", params, headers}
      assert params == %{"cancel_at" => "1700172800", "proration_behavior" => "none"}
      assert idempotency_header(headers) =~ "mpp-subscription-schedule-cancel-"

      assert {:ok, ^canceled} = StripeSubscription.cancel(activation.subscription_id, subscription.method_details)
      refute_received {:stripe_request, "POST", "/v1/subscriptions/sub_test", _params, _headers}

      Req.Test.stub(Stripe, &Req.Test.json(&1, stripe_renewal_invoice_fixture("in_after_cancel", 2)))

      assert {:error, %Errors{detail: "Stripe renewal invoice does not match the subscription"}} =
               StripeSubscription.process_invoice(
                 "evt_after_cancel",
                 "in_after_cancel",
                 subscription.method_details
               )
    end

    test "records one cancellation under concurrent cancel requests" do
      stub_subscription_flow()
      subscription = stripe_subscription()
      assert {:ok, activation} = Stripe.verify(%{"paymentMethod" => "pm_input"}, subscription)

      test_pid = self()

      Req.Test.stub(Stripe, fn conn ->
        {params, conn} = capture_stripe_request(conn, test_pid)

        Req.Test.json(conn, %{
          "id" => "sub_test",
          "cancel_at" => String.to_integer(params["cancel_at"]),
          "cancel_at_period_end" => true
        })
      end)

      results =
        1..8
        |> Enum.map(fn _index ->
          Task.async(fn ->
            StripeSubscription.cancel(activation.subscription_id, subscription.method_details)
          end)
        end)
        |> Task.await_many()

      assert Enum.all?(results, &match?({:ok, %Record{cancellation_effective_at: ~U[2023-11-15 22:13:20Z]}}, &1))
      assert {:ok, canceled} = Store.get(subscription_store(), activation.subscription_id)
      assert canceled.cancellation_effective_at == ~U[2023-11-15 22:13:20Z]
      assert canceled.in_flight_reference == nil
    end

    test "marks Stripe cancellation events idempotently and rejects post-revocation renewals" do
      stub_subscription_flow()
      subscription = stripe_subscription()
      assert {:ok, activation} = Stripe.verify(%{"paymentMethod" => "pm_input"}, subscription)

      unpaid_event =
        "evt_subscription_unpaid"
        |> stripe_deleted_subscription_event(1_700_050_000)
        |> Map.put("type", "customer.subscription.updated")
        |> put_in(["data", "object", "status"], "unpaid")
        |> put_in(["data", "object", "canceled_at"], nil)

      assert {:ok, unpaid} = StripeSubscription.process_event(unpaid_event, subscription.method_details)
      assert unpaid.cancellation_effective_at == ~U[2023-11-15 12:06:40Z]

      deleted_event = stripe_deleted_subscription_event("evt_subscription_deleted", 1_700_043_200)
      assert {:ok, deleted} = StripeSubscription.process_event(deleted_event, subscription.method_details)
      assert {:ok, ^deleted} = StripeSubscription.process_event(deleted_event, subscription.method_details)
      assert deleted.cancellation_effective_at == ~U[2023-11-15 10:13:20Z]

      assert deleted.method_state.revocation_event_ids ==
               ~w(evt_subscription_unpaid evt_subscription_deleted)

      assert {:ok, persisted} = Store.get(subscription_store(), activation.subscription_id)
      assert persisted == deleted

      Req.Test.stub(Stripe, &Req.Test.json(&1, stripe_renewal_invoice_fixture("in_after_delete", 1)))

      assert {:error, %Errors{detail: "Stripe renewal invoice does not match the subscription"}} =
               StripeSubscription.process_invoice(
                 "evt_after_delete",
                 "in_after_delete",
                 subscription.method_details
               )

      assert {:ok, unchanged} = Store.get(subscription_store(), activation.subscription_id)
      assert Map.keys(unchanged.payments) == [0]
    end

    test "rejects malformed and non-revoking Stripe lifecycle events" do
      assert {:error, %Errors{type: type}} = StripeSubscription.process_event(nil, nil)
      assert type =~ "invalid-payload"

      assert {:error, %Errors{detail: "Stripe subscription lifecycle event does not match the subscription"}} =
               StripeSubscription.process_event(
                 %{"id" => "evt_created", "type" => "customer.subscription.created"},
                 subscription_config()
               )

      active = stripe_deleted_subscription_event("evt_active", 1_700_043_200)
      active = put_in(active, ["data", "object", "status"], "active")

      assert {:error, %Errors{detail: "Stripe subscription lifecycle event does not match the subscription"}} =
               StripeSubscription.process_event(active, subscription_config())

      malformed =
        "evt_malformed"
        |> stripe_deleted_subscription_event(1_700_043_200)
        |> pop_in(["data", "object", "metadata"])
        |> elem(1)

      assert {:error, %Errors{detail: "Stripe subscription lifecycle event does not match the subscription"}} =
               StripeSubscription.process_event(malformed, subscription_config())
    end

    test "preserves lifecycle store errors and rejects changed durable records" do
      stub_subscription_flow()
      subscription = stripe_subscription()
      assert {:ok, activation} = Stripe.verify(%{"paymentMethod" => "pm_input"}, subscription)
      assert {:ok, record} = Store.get(subscription_store(), activation.subscription_id)
      event = stripe_deleted_subscription_event("evt_store_error", 1_700_043_200)
      controlled = Errors.new(:verification_failed, "controlled lifecycle store error")

      cases = [
        {{:error, :store_down}, "Stripe subscription store unavailable"},
        {{:error, controlled}, "controlled lifecycle store error"},
        {{:apply, :not_found}, "Stripe subscription lifecycle event does not match the subscription"},
        {{:apply, %{record | method: "tempo"}}, "Stripe subscription lifecycle event does not match the subscription"}
      ]

      for {update, detail} <- cases do
        lifecycle_store = {StripeLifecycleStore, get: {:ok, record}, update: update}
        config = Map.put(subscription.method_details, "subscription_store", lifecycle_store)
        assert {:error, %Errors{detail: ^detail}} = StripeSubscription.process_event(event, config)
      end
    end

    test "voids a stale open invoice once and rejects a later paid event" do
      stub_subscription_flow()
      subscription = stripe_subscription()
      assert {:ok, activation} = Stripe.verify(%{"paymentMethod" => "pm_input"}, subscription)
      stale = stripe_unpaid_renewal_invoice_fixture("in_stale", 1, "open")
      test_pid = self()

      Req.Test.stub(Stripe, fn conn ->
        {_params, conn} = capture_stripe_request(conn, test_pid)

        case {conn.method, conn.request_path} do
          {"GET", "/v1/invoices/in_stale"} ->
            Req.Test.json(conn, stale)

          {"POST", "/v1/invoices/in_stale/void"} ->
            Req.Test.json(conn, %{
              "id" => "in_stale",
              "status" => "void",
              "auto_advance" => false
            })
        end
      end)

      assert {:ok, closed} =
               StripeSubscription.void_stale_invoice(
                 activation.subscription_id,
                 "in_stale",
                 ~U[2023-11-16 22:13:20Z],
                 subscription.method_details
               )

      assert closed.method_state.closed_invoices["in_stale"] == %{
               period: 1,
               status: "void",
               timestamp: "2023-11-16T22:13:20Z"
             }

      assert_received {:stripe_request, "POST", "/v1/invoices/in_stale/void", %{}, headers}
      assert idempotency_header(headers) =~ "mpp-subscription-void-invoice-"

      assert {:ok, ^closed} =
               StripeSubscription.void_stale_invoice(
                 activation.subscription_id,
                 "in_stale",
                 ~U[2023-11-16 22:13:20Z],
                 subscription.method_details
               )

      refute_received {:stripe_request, "POST", "/v1/invoices/in_stale/void", _params, _headers}

      Req.Test.stub(Stripe, &Req.Test.json(&1, stripe_renewal_invoice_fixture("in_stale", 1)))

      assert {:error, %Errors{detail: "Stripe renewal invoice does not match the subscription"}} =
               StripeSubscription.process_invoice("evt_stale_paid", "in_stale", subscription.method_details)

      assert {:ok, unchanged} = Store.get(subscription_store(), activation.subscription_id)
      assert Map.keys(unchanged.payments) == [0]

      late_paid =
        "in_late_paid"
        |> stripe_renewal_invoice_fixture(1)
        |> put_in(["payments", "data", Access.at(0), "status_transitions", "paid_at"], 1_700_172_800)

      Req.Test.stub(Stripe, &Req.Test.json(&1, late_paid))

      assert {:error, %Errors{detail: "Stripe renewal invoice does not match the subscription"}} =
               StripeSubscription.process_invoice("evt_late_paid", "in_late_paid", subscription.method_details)
    end

    test "disables automatic collection for stale draft invoices" do
      stub_subscription_flow()
      subscription = stripe_subscription()
      assert {:ok, activation} = Stripe.verify(%{"paymentMethod" => "pm_input"}, subscription)
      stale = stripe_unpaid_renewal_invoice_fixture("in_stale_draft", 1, "draft")
      test_pid = self()

      Req.Test.stub(Stripe, fn conn ->
        {params, conn} = capture_stripe_request(conn, test_pid)

        case {conn.method, conn.request_path} do
          {"GET", "/v1/invoices/in_stale_draft"} ->
            Req.Test.json(conn, stale)

          {"POST", "/v1/invoices/in_stale_draft"} ->
            assert params == %{"auto_advance" => "false"}

            Req.Test.json(conn, %{
              "id" => "in_stale_draft",
              "status" => "draft",
              "auto_advance" => false
            })
        end
      end)

      assert {:ok, closed} =
               StripeSubscription.void_stale_invoice(
                 activation.subscription_id,
                 "in_stale_draft",
                 ~U[2023-11-16 22:13:20Z],
                 subscription.method_details
               )

      assert closed.method_state.closed_invoices["in_stale_draft"].status == "collection_disabled"
      assert_received {:stripe_request, "POST", "/v1/invoices/in_stale_draft", %{"auto_advance" => "false"}, _headers}
    end

    test "rejects an invoice before its period closes and releases a failed void claim" do
      stub_subscription_flow()
      subscription = stripe_subscription()
      assert {:ok, activation} = Stripe.verify(%{"paymentMethod" => "pm_input"}, subscription)
      stale = stripe_unpaid_renewal_invoice_fixture("in_stale_retry", 1, "open")
      close_time = ~U[2023-11-16 22:13:20Z]

      assert {:error, %Errors{detail: "Stripe subscription requires stripe_secret_key configuration"}} =
               StripeSubscription.void_stale_invoice(
                 activation.subscription_id,
                 "in_stale_retry",
                 close_time,
                 Map.delete(subscription.method_details, "stripe_secret_key")
               )

      Req.Test.stub(Stripe, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v1/invoices/in_stale_retry"} ->
            Req.Test.json(conn, stale)

          {"POST", "/v1/invoices/in_stale_retry/void"} ->
            conn
            |> Plug.Conn.put_status(500)
            |> Req.Test.json(%{"error" => %{"type" => "api_error"}})
        end
      end)

      assert {:error, %Errors{detail: "Stripe subscription lifecycle event does not match the subscription"}} =
               StripeSubscription.void_stale_invoice(
                 activation.subscription_id,
                 "in_stale_retry",
                 ~U[2023-11-16 22:13:19Z],
                 subscription.method_details
               )

      assert {:error, %Errors{detail: "Stripe stale invoice voiding failed"}} =
               StripeSubscription.void_stale_invoice(
                 activation.subscription_id,
                 "in_stale_retry",
                 close_time,
                 subscription.method_details
               )

      assert {:ok, record} = Store.get(subscription_store(), activation.subscription_id)
      refute Map.has_key?(record.method_state[:closed_invoices] || %{}, "in_stale_retry")

      assert {:error, %Errors{type: invalid_type}} =
               StripeSubscription.void_stale_invoice(nil, nil, nil, nil)

      assert invalid_type =~ "invalid-payload"

      Req.Test.stub(Stripe, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"error" => %{"type" => "api_error"}})
      end)

      assert {:error, %Errors{detail: "Stripe Invoice retrieval failed"}} =
               StripeSubscription.void_stale_invoice(
                 activation.subscription_id,
                 "in_retrieval_failure",
                 close_time,
                 subscription.method_details
               )

      for {invoice_id, transform} <- [
            {"in_wrong_amount", &Map.put(&1, "total", 4999)},
            {"in_malformed_unpaid", &Map.delete(&1, "status")}
          ] do
        invalid = transform.(stripe_unpaid_renewal_invoice_fixture(invoice_id, 1, "open"))
        Req.Test.stub(Stripe, &Req.Test.json(&1, invalid))

        assert {:error, %Errors{detail: "Stripe subscription lifecycle event does not match the subscription"}} =
                 StripeSubscription.void_stale_invoice(
                   activation.subscription_id,
                   invoice_id,
                   close_time,
                   subscription.method_details
                 )
      end

      invalid_response = stripe_unpaid_renewal_invoice_fixture("in_invalid_void", 1, "open")

      Req.Test.stub(Stripe, fn conn ->
        case conn.method do
          "GET" -> Req.Test.json(conn, invalid_response)
          "POST" -> Req.Test.json(conn, %{"id" => "in_invalid_void", "status" => "open", "auto_advance" => true})
        end
      end)

      assert {:error, %Errors{detail: "Stripe subscription lifecycle event does not match the subscription"}} =
               StripeSubscription.void_stale_invoice(
                 activation.subscription_id,
                 "in_invalid_void",
                 close_time,
                 subscription.method_details
               )
    end

    test "resumes a durable stale-invoice claim after interruption" do
      stub_subscription_flow()
      subscription = stripe_subscription()
      assert {:ok, activation} = Stripe.verify(%{"paymentMethod" => "pm_input"}, subscription)
      close_time = ~U[2023-11-16 22:13:20Z]

      assert {:ok, _claimed} =
               Store.update(subscription_store(), activation.subscription_id, fn record ->
                 closure = %{period: 1, status: "closing", timestamp: DateTime.to_iso8601(close_time)}
                 state = Map.put(record.method_state, :closed_invoices, %{"in_interrupted" => closure})
                 {:ok, %{record | method_state: state}}
               end)

      stale =
        "in_interrupted"
        |> stripe_unpaid_renewal_invoice_fixture(1, "void")
        |> Map.put("auto_advance", false)

      Req.Test.stub(Stripe, &Req.Test.json(&1, stale))

      assert {:ok, closed} =
               StripeSubscription.void_stale_invoice(
                 activation.subscription_id,
                 "in_interrupted",
                 close_time,
                 subscription.method_details
               )

      assert closed.method_state.closed_invoices["in_interrupted"].status == "void"

      refute_received {:stripe_request, "POST", "/v1/invoices/in_interrupted/void", _params, _headers}

      assert {:ok, _mismatched} =
               Store.update(subscription_store(), activation.subscription_id, fn record ->
                 closure = %{period: 2, status: "closing", timestamp: DateTime.to_iso8601(close_time)}
                 closed_invoices = Map.put(record.method_state.closed_invoices, "in_mismatched", closure)
                 state = Map.put(record.method_state, :closed_invoices, closed_invoices)
                 {:ok, %{record | method_state: state}}
               end)

      mismatched = stripe_unpaid_renewal_invoice_fixture("in_mismatched", 1, "open")
      Req.Test.stub(Stripe, &Req.Test.json(&1, mismatched))

      assert {:error, %Errors{detail: "Stripe subscription lifecycle event does not match the subscription"}} =
               StripeSubscription.void_stale_invoice(
                 activation.subscription_id,
                 "in_mismatched",
                 close_time,
                 subscription.method_details
               )
    end

    test "maps stale-invoice claim store failures without mutating Stripe" do
      stub_subscription_flow()
      subscription = stripe_subscription()
      assert {:ok, activation} = Stripe.verify(%{"paymentMethod" => "pm_input"}, subscription)
      assert {:ok, record} = Store.get(subscription_store(), activation.subscription_id)
      stale = stripe_unpaid_renewal_invoice_fixture("in_claim_error", 1, "open")
      Req.Test.stub(Stripe, &Req.Test.json(&1, stale))
      controlled = Errors.new(:verification_failed, "controlled stale claim error")

      cases = [
        {{:error, :store_down}, "Stripe subscription store unavailable"},
        {{:error, controlled}, "controlled stale claim error"},
        {{:apply, :not_found}, "Stripe subscription lifecycle event does not match the subscription"},
        {{:apply, %{record | method: "tempo"}}, "Stripe subscription lifecycle event does not match the subscription"}
      ]

      for {update, detail} <- cases do
        lifecycle_store = {StripeLifecycleStore, get: {:ok, record}, update: update}

        config = Map.put(subscription.method_details, "subscription_store", lifecycle_store)

        assert {:error, %Errors{detail: ^detail}} =
                 StripeSubscription.void_stale_invoice(
                   activation.subscription_id,
                   "in_claim_error",
                   ~U[2023-11-16 22:13:20Z],
                   config
                 )
      end

      refute_received {:stripe_request, "POST", "/v1/invoices/in_claim_error/void", _params, _headers}
    end

    test "releases a cancellation claim when Stripe rejects the update" do
      stub_subscription_flow()
      subscription = stripe_subscription()
      assert {:ok, activation} = Stripe.verify(%{"paymentMethod" => "pm_input"}, subscription)

      Req.Test.stub(Stripe, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => %{"type" => "invalid_request_error"}})
      end)

      assert {:error, %Errors{detail: "Stripe subscription cancellation failed"}} =
               StripeSubscription.cancel(activation.subscription_id, subscription.method_details)

      assert {:ok, record} = Store.get(subscription_store(), activation.subscription_id)
      assert record.cancellation_effective_at == nil
      assert record.in_flight_reference == nil

      Req.Test.stub(Stripe, &Req.Test.json(&1, %{"id" => "sub_test", "cancel_at" => nil}))

      assert {:error, %Errors{detail: "Stripe returned an invalid cancellation state"}} =
               StripeSubscription.cancel(activation.subscription_id, subscription.method_details)

      assert {:ok, _in_flight} =
               Store.update(subscription_store(), activation.subscription_id, fn current ->
                 {:ok, %{current | in_flight_reference: "renewal:1"}}
               end)

      assert {:error, %Errors{detail: "Stripe subscription operation is already in flight"}} =
               StripeSubscription.cancel(activation.subscription_id, subscription.method_details)

      assert {:error, %Errors{detail: "Stripe subscription not found"}} =
               StripeSubscription.cancel("missing_subscription", subscription.method_details)

      assert {:ok, _tempo_record} =
               Store.update(subscription_store(), activation.subscription_id, fn current ->
                 {:ok, %{current | method: "tempo", in_flight_reference: nil}}
               end)

      assert {:error, %Errors{detail: "Stripe renewal invoice does not match the subscription"}} =
               StripeSubscription.cancel(activation.subscription_id, subscription.method_details)

      assert {:ok, _malformed_state} =
               Store.update(subscription_store(), activation.subscription_id, fn current ->
                 {:ok,
                  %{current | method: "stripe", method_state: Map.delete(current.method_state, :stripe_subscription_id)}}
               end)

      assert {:error, %Errors{detail: "Stripe renewal invoice does not match the subscription"}} =
               StripeSubscription.cancel(activation.subscription_id, subscription.method_details)
    end

    test "maps Stripe's synchronous first-invoice action requirement to verification failure" do
      stub_subscription_flow(subscription_error: :requires_action)

      assert {:error, %Errors{} = error} =
               Stripe.verify(%{"paymentMethod" => "pm_input"}, stripe_subscription())

      assert error.type =~ "verification-failed"
      assert error.detail == "Stripe subscription first invoice requires customer action"
    end

    test "maps Stripe subscription API failures and non-object responses" do
      for {failure, detail} <- [
            {:api_error, "Stripe subscription activation failed"},
            {:invalid_response, "Stripe returned an invalid Subscription"}
          ] do
        stub_subscription_flow(subscription_error: failure)

        assert {:error, %Errors{detail: ^detail}} =
                 Stripe.verify(%{"paymentMethod" => "pm_input"}, stripe_subscription())
      end
    end

    test "rejects a paid invoice whose amount does not match the challenge" do
      stub_subscription_flow(invoice_transform: &put_in(&1, ["amount_paid"], 4999))

      assert {:error, %Errors{} = error} =
               Stripe.verify(%{"paymentMethod" => "pm_input"}, stripe_subscription())

      assert error.detail == "Stripe first invoice does not match the subscription request"
      assert_received {:stripe_request, "DELETE", "/v1/subscriptions/sub_test", %{}, headers}
      assert idempotency_header(headers) =~ "mpp-subscription-cancel-"
    end

    test "rejects an invoice paid_at that is not a valid Unix timestamp" do
      stub_subscription_flow(
        invoice_transform:
          &put_in(&1, ["payments", "data", Access.at(0), "status_transitions", "paid_at"], 253_402_300_800)
      )

      assert {:error, %Errors{detail: "Stripe first invoice does not match the subscription request"}} =
               Stripe.verify(%{"paymentMethod" => "pm_input"}, stripe_subscription())
    end

    test "rejects malformed subscription credentials before calling Stripe" do
      for payload <- [
            %{},
            %{"paymentMethod" => ""},
            %{"paymentMethod" => 42},
            %{"paymentMethod" => "pm_input", "customer" => ""},
            %{"paymentMethod" => "pm_input", "unexpected" => true},
            "pm_input"
          ] do
        assert {:error, %Errors{type: type}} = Stripe.verify(payload, stripe_subscription())
        assert type =~ "invalid-payload"
      end

      refute_received {:stripe_request, _method, _path, _params, _headers}
    end

    test "rejects credential ids that would traverse Stripe API paths" do
      for payload <- [
            %{"paymentMethod" => "../customers/cus_test"},
            %{"paymentMethod" => "pm_input/../customers"},
            %{"paymentMethod" => "pm_input", "customer" => "cus_test/../payment_methods"}
          ] do
        assert {:error, %Errors{type: type, detail: detail}} =
                 Stripe.verify(payload, stripe_subscription())

        assert type =~ "invalid-payload"
        assert detail =~ "Stripe object id"
      end

      refute_received {:stripe_request, _method, _path, _params, _headers}
    end

    test "rejects a PaymentMethod type not advertised by the challenge" do
      stub_subscription_flow(payment_type: "us_bank_account")

      assert {:error, %Errors{} = error} =
               Stripe.verify(%{"paymentMethod" => "pm_input"}, stripe_subscription())

      assert error.detail == "Stripe PaymentMethod type is not allowed by this challenge"
      refute_received {:stripe_request, "POST", _path, _params, _headers}
    end

    test "rejects a PaymentMethod attached to another Customer" do
      stub_subscription_flow(payment_customer: "cus_other")

      assert {:error, %Errors{} = error} =
               Stripe.verify(
                 %{"paymentMethod" => "pm_input", "customer" => "cus_test"},
                 stripe_subscription()
               )

      assert error.detail == "Stripe PaymentMethod belongs to a different Customer"
      refute_received {:stripe_request, "POST", "/v1/subscriptions", _params, _headers}
    end

    test "rejects malformed Stripe resource objects" do
      cases = [
        {[payment_method_transform: fn _payment_method -> %{} end], %{"paymentMethod" => "pm_input"},
         "invalid PaymentMethod"},
        {[
           payment_customer: "cus_test",
           customer_transform: &Map.put(&1, "deleted", true)
         ], %{"paymentMethod" => "pm_input", "customer" => "cus_test"}, "invalid Customer"},
        {[attach_transform: fn _payment_method -> %{} end], %{"paymentMethod" => "pm_input"},
         "invalid attached PaymentMethod"},
        {[product_transform: fn _product -> %{} end], %{"paymentMethod" => "pm_input"}, "invalid Product"},
        {[price_transform: &Map.put(&1, "unit_amount", 4999)], %{"paymentMethod" => "pm_input"}, "Price does not match"},
        {[price_transform: fn _price -> %{} end], %{"paymentMethod" => "pm_input"}, "Price does not match"},
        {[subscription_transform: &Map.put(&1, "status", "incomplete")], %{"paymentMethod" => "pm_input"},
         "Subscription does not match"},
        {[subscription_transform: &Map.put(&1, "id", "sub_test/../invoices")], %{"paymentMethod" => "pm_input"},
         "invalid Subscription"},
        {[subscription_transform: fn _subscription -> %{} end], %{"paymentMethod" => "pm_input"},
         "Subscription does not match"},
        {[
           subscription_transform: fn stripe_subscription ->
             update_in(stripe_subscription["items"]["data"], fn [item] -> [%{item | "quantity" => 2}] end)
           end
         ], %{"paymentMethod" => "pm_input"}, "Subscription item does not match"},
        {[
           subscription_transform: &put_in(&1, ["automatic_tax", "enabled"], true)
         ], %{"paymentMethod" => "pm_input"}, "must not enable automatic tax"}
      ]

      for {stub_opts, payload, expected_detail} <- cases do
        stub_subscription_flow(stub_opts)
        assert {:error, %Errors{} = error} = Stripe.verify(payload, stripe_subscription())
        assert error.detail =~ expected_detail
      end
    end

    test "rejects every paid-invoice shape that can alter subscription accounting" do
      cases = [
        fn invoice -> invoice |> Map.put("amount_paid", 4999) |> Map.put("total", 4999) end,
        fn invoice ->
          update_in(invoice["lines"]["data"], fn [line] -> [%{line | "amount" => 4999}] end)
        end,
        &Map.delete(&1, "lines"),
        fn invoice ->
          update_in(invoice["payments"]["data"], fn [payment] ->
            payment = %{payment | "amount_paid" => 4999}
            [%{payment | "payment" => put_in(payment["payment"], ["payment_intent", "amount_received"], 4999)}]
          end)
        end,
        &Map.delete(&1, "payments")
      ]

      for transform <- cases do
        stub_subscription_flow(invoice_transform: transform)

        assert {:error, %Errors{detail: "Stripe first invoice does not match the subscription request"}} =
                 Stripe.verify(%{"paymentMethod" => "pm_input"}, stripe_subscription())
      end
    end

    test "rejects missing runtime config and invalid non-string profile currency" do
      subscription = stripe_subscription()
      missing_challenge = %{subscription | method_details: Map.delete(subscription.method_details, "challenge_id")}

      assert {:error, %Errors{detail: detail}} =
               Stripe.verify(%{"paymentMethod" => "pm_input"}, missing_challenge)

      assert detail =~ "challenge_id"

      assert_raise ArgumentError, ~r/lowercase ISO 4217/, fn ->
        Stripe.challenge_method_details(%{subscription | currency: nil})
      end

      too_many_metadata = Map.new(1..51, &{"key#{&1}", "value"})

      assert_raise ArgumentError, ~r/metadata violates Stripe limits/, fn ->
        subscription_config() |> Map.put("metadata", too_many_metadata) |> Stripe.validate_config!()
      end
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

  defp subscription_config do
    %{
      "intent" => "subscription",
      "stripe_secret_key" => @stripe_secret_key,
      "network_id" => @network_id,
      "payment_method_types" => ["card"],
      "subscription_store" => subscription_store()
    }
  end

  defp subscription_store, do: Process.get({__MODULE__, :subscription_store})

  defp stripe_subscription(overrides \\ []) do
    defaults = [
      amount: "5000",
      currency: "usd",
      period_unit: :day,
      period_count: "1",
      method_details:
        Map.merge(subscription_config(), %{
          "challenge_id" => "ch_subscription",
          "req_options" => [plug: {Req.Test, Stripe}]
        })
    ]

    {:ok, subscription} = defaults |> Keyword.merge(overrides) |> Subscription.new()
    subscription
  end

  defp stub_subscription_flow(opts \\ []) do
    test_pid = self()

    state = %{
      payment_customer: Keyword.get(opts, :payment_customer),
      payment_type: Keyword.get(opts, :payment_type, "card"),
      subscription_error: Keyword.get(opts, :subscription_error),
      payment_method_transform: Keyword.get(opts, :payment_method_transform, &Function.identity/1),
      customer_transform: Keyword.get(opts, :customer_transform, &Function.identity/1),
      attach_transform: Keyword.get(opts, :attach_transform, &Function.identity/1),
      product_transform: Keyword.get(opts, :product_transform, &Function.identity/1),
      price_transform: Keyword.get(opts, :price_transform, &Function.identity/1),
      subscription_transform: Keyword.get(opts, :subscription_transform, &Function.identity/1),
      invoice_transform: Keyword.get(opts, :invoice_transform, &Function.identity/1)
    }

    Req.Test.stub(Stripe, fn conn ->
      {params, conn} = capture_stripe_request(conn, test_pid)
      stub_subscription_response(conn, params, state)
    end)
  end

  defp stub_subscription_response(%{method: "GET", request_path: path} = conn, _params, state) do
    case path do
      "/v1/payment_methods/pm_input" ->
        payment_method = %{
          "id" => "pm_test",
          "type" => state.payment_type,
          "customer" => state.payment_customer
        }

        Req.Test.json(conn, state.payment_method_transform.(payment_method))

      "/v1/customers/cus_test" ->
        customer = %{"id" => "cus_test", "object" => "customer", "deleted" => false}
        Req.Test.json(conn, state.customer_transform.(customer))

      "/v1/invoices/in_test" ->
        Req.Test.json(conn, state.invoice_transform.(stripe_invoice_fixture()))
    end
  end

  defp stub_subscription_response(%{method: "DELETE", request_path: "/v1/subscriptions/sub_test"} = conn, _params, _state) do
    Req.Test.json(conn, %{"id" => "sub_test", "status" => "canceled"})
  end

  defp stub_subscription_response(%{method: "POST", request_path: path} = conn, params, state) do
    case path do
      "/v1/customers" ->
        assert params["description"] == "MPP subscription payer"
        Req.Test.json(conn, %{"id" => "cus_test", "object" => "customer", "deleted" => false})

      "/v1/payment_methods/pm_test/attach" ->
        payment_method = %{"id" => "pm_test", "type" => state.payment_type, "customer" => "cus_test"}
        Req.Test.json(conn, state.attach_transform.(payment_method))

      "/v1/products" ->
        product = %{"id" => "prod_test", "object" => "product", "active" => true}
        Req.Test.json(conn, state.product_transform.(product))

      "/v1/prices" ->
        Req.Test.json(conn, state.price_transform.(stripe_price_fixture()))

      "/v1/subscriptions" ->
        stub_subscription_creation(conn, state)
    end
  end

  defp stub_subscription_creation(conn, %{subscription_error: :requires_action}) do
    conn
    |> Plug.Conn.put_status(402)
    |> Req.Test.json(%{
      "error" => %{
        "type" => "card_error",
        "code" => "subscription_payment_intent_requires_action"
      }
    })
  end

  defp stub_subscription_creation(conn, %{subscription_error: :api_error}) do
    conn
    |> Plug.Conn.put_status(500)
    |> Req.Test.json(%{"error" => %{"type" => "api_error"}})
  end

  defp stub_subscription_creation(conn, %{subscription_error: :invalid_response}) do
    Req.Test.json(conn, [])
  end

  defp stub_subscription_creation(conn, state) do
    Req.Test.json(conn, state.subscription_transform.(stripe_subscription_fixture()))
  end

  defp capture_stripe_request(conn, test_pid) do
    {params, conn} =
      case conn.method do
        "POST" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          {URI.decode_query(body), conn}

        _other ->
          {%{}, conn}
      end

    send(test_pid, {:stripe_request, conn.method, conn.request_path, params, conn.req_headers})
    {params, conn}
  end

  defp stripe_price_fixture do
    %{
      "id" => "price_test",
      "active" => true,
      "billing_scheme" => "per_unit",
      "currency" => "usd",
      "product" => "prod_test",
      "recurring" => %{"interval" => "day", "interval_count" => 1, "usage_type" => "licensed"},
      "type" => "recurring",
      "unit_amount" => 5000
    }
  end

  defp stripe_subscription_fixture do
    %{
      "id" => "sub_test",
      "status" => "active",
      "customer" => "cus_test",
      "default_payment_method" => "pm_test",
      "collection_method" => "charge_automatically",
      "latest_invoice" => "in_test",
      "automatic_tax" => %{"enabled" => false},
      "cancel_at" => nil,
      "cancel_at_period_end" => false,
      "discounts" => [],
      "pending_invoice_item_interval" => nil,
      "schedule" => nil,
      "trial_end" => nil,
      "trial_start" => nil,
      "items" => %{
        "data" => [
          %{
            "subscription" => "sub_test",
            "quantity" => 1,
            "discounts" => [],
            "price" => %{"id" => "price_test"},
            "current_period_start" => 1_700_000_000,
            "current_period_end" => 1_700_086_400
          }
        ]
      }
    }
  end

  defp stripe_invoice_fixture do
    %{
      "id" => "in_test",
      "status" => "paid",
      "customer" => "cus_test",
      "currency" => "usd",
      "amount_paid" => 5000,
      "amount_remaining" => 0,
      "total" => 5000,
      "discounts" => [],
      "total_discount_amounts" => [],
      "total_taxes" => [],
      "total_pretax_credit_amounts" => [],
      "pre_payment_credit_notes_amount" => 0,
      "post_payment_credit_notes_amount" => 0,
      "starting_balance" => 0,
      "ending_balance" => 0,
      "automatic_tax" => %{"enabled" => false},
      "parent" => %{
        "type" => "subscription_details",
        "subscription_details" => %{"subscription" => "sub_test"}
      },
      "lines" => %{
        "data" => [
          %{
            "amount" => 5000,
            "currency" => "usd",
            "quantity" => 1,
            "discount_amounts" => [],
            "discounts" => [],
            "taxes" => [],
            "period" => %{"start" => 1_700_000_000, "end" => 1_700_086_400},
            "pricing" => %{"type" => "price_details", "price_details" => %{"price" => "price_test"}},
            "parent" => %{
              "type" => "subscription_item_details",
              "subscription_item_details" => %{"subscription" => "sub_test", "proration" => false}
            }
          }
        ]
      },
      "payments" => %{
        "data" => [
          %{
            "status" => "paid",
            "amount_paid" => 5000,
            "currency" => "usd",
            "status_transitions" => %{"paid_at" => 1_700_000_010},
            "payment" => %{
              "type" => "payment_intent",
              "payment_intent" => %{
                "status" => "succeeded",
                "amount_received" => 5000,
                "currency" => "usd",
                "customer" => "cus_test",
                "payment_method" => "pm_test",
                "setup_future_usage" => "off_session"
              }
            }
          }
        ]
      }
    }
  end

  defp stripe_renewal_invoice_fixture(invoice_id, period) do
    period_start = 1_700_000_000 + period * 86_400
    period_end = period_start + 86_400

    stripe_invoice_fixture()
    |> Map.put("id", invoice_id)
    |> Map.put("billing_reason", "subscription_cycle")
    |> put_in(["parent", "subscription_details", "metadata"], %{"mpp_challenge_id" => "ch_subscription"})
    |> put_in(["lines", "data", Access.at(0), "period"], %{"start" => period_start, "end" => period_end})
    |> put_in(
      ["payments", "data", Access.at(0), "status_transitions", "paid_at"],
      period_start + 10
    )
    |> put_in(
      ["payments", "data", Access.at(0), "payment", "payment_intent", "setup_future_usage"],
      nil
    )
  end

  defp stripe_unpaid_renewal_invoice_fixture(invoice_id, period, status) do
    invoice_id
    |> stripe_renewal_invoice_fixture(period)
    |> Map.merge(%{
      "status" => status,
      "amount_paid" => 0,
      "amount_remaining" => 5000,
      "auto_advance" => true,
      "payments" => %{"data" => []}
    })
  end

  defp stripe_deleted_subscription_event(event_id, canceled_at) do
    %{
      "id" => event_id,
      "type" => "customer.subscription.deleted",
      "created" => canceled_at,
      "data" => %{
        "object" => %{
          "id" => "sub_test",
          "status" => "canceled",
          "canceled_at" => canceled_at,
          "ended_at" => canceled_at,
          "metadata" => %{"mpp_challenge_id" => "ch_subscription"}
        }
      }
    }
  end

  defp put_subscription_period(subscription, period_start, period_end) do
    subscription
    |> put_in(
      ["items", "data", Access.at(0), "current_period_start"],
      period_start
    )
    |> put_in(["items", "data", Access.at(0), "current_period_end"], period_end)
  end

  defp put_invoice_period(invoice, period_start, period_end) do
    invoice
    |> put_in(["lines", "data", Access.at(0), "period"], %{"start" => period_start, "end" => period_end})
    |> put_in(
      ["payments", "data", Access.at(0), "status_transitions", "paid_at"],
      period_start + 10
    )
  end

  defp idempotency_header(headers) do
    case List.keyfind(headers, "idempotency-key", 0) do
      {_, value} -> value
      nil -> nil
    end
  end
end
