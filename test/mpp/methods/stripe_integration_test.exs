defmodule MPP.Methods.StripeIntegrationTest do
  @moduledoc """
  Integration tests for the Stripe payment method against Stripe's real test mode API.

  Requires `STRIPE_SECRET_KEY` environment variable set to a Stripe test mode secret key.
  Run with: `mix test --include integration`
  """

  use ExUnit.Case, async: false

  alias MPP.Client.MultiProvider
  alias MPP.Client.Providers.Stripe, as: StripeProvider
  alias MPP.Credential
  alias MPP.Headers
  alias MPP.Methods.Stripe
  alias MPP.Methods.Stripe.Subscription, as: StripeSubscription
  alias MPP.Receipt
  alias MPP.Subscription.ETSStore, as: SubscriptionStore
  alias MPP.Subscription.Store

  @moduletag :integration

  @hmac_secret "test-hmac-secret-for-integration"
  @realm "integration-test.example.com"
  @amount "100"
  @currency "usd"
  @stripe_api_version "2026-02-25.clover"
  @test_clock_timeout_ms 60_000
  @test_clock_poll_ms 500

  @spt_endpoint "https://api.stripe.com/v1/test_helpers/shared_payment/granted_tokens"

  # 10-minute expiry for test SPTs
  @spt_ttl_seconds 600

  setup do
    stripe_secret_key = System.get_env("STRIPE_SECRET_KEY")

    if is_nil(stripe_secret_key) do
      flunk("""
      Missing Stripe test mode credentials!

      Set this environment variable:
        export STRIPE_SECRET_KEY="sk_test_..."

      Get a test mode key at: https://dashboard.stripe.com/test/apikeys

      Then run:
        STRIPE_SECRET_KEY=sk_test_... mix test --include integration
      """)
    end

    {:ok, config: plug_config(stripe_secret_key), stripe_secret_key: stripe_secret_key}
  end

  describe "full 402 handshake" do
    test "built-in provider creates the SPT and completes the Plug round trip", %{
      config: config,
      stripe_secret_key: stripe_secret_key
    } do
      conn_402 = request_challenge_conn(config)
      [challenge_header] = Plug.Conn.get_resp_header(conn_402, "www-authenticate")
      {:ok, challenge} = Headers.parse_challenge(challenge_header)

      provider =
        MultiProvider.new([
          {StripeProvider, %{secret_key: stripe_secret_key, payment_method: "pm_card_visa"}}
        ])

      assert {:ok, credential} = MultiProvider.pay(provider, challenge)
      assert String.starts_with?(credential.payload["spt"], "spt_")

      conn_200 =
        :get
        |> Plug.Test.conn("/api/data")
        |> Plug.Conn.put_req_header("authorization", Headers.format_credential(credential))
        |> MPP.Plug.call(config)

      assert conn_200.status == nil
      assert %Receipt{method: "stripe", status: "success"} = conn_200.assigns[:mpp_receipt]
    end

    test "built-in provider preserves Stripe's live invalid-payment-method error", %{
      config: config,
      stripe_secret_key: stripe_secret_key
    } do
      conn_402 = request_challenge_conn(config)
      [challenge_header] = Plug.Conn.get_resp_header(conn_402, "www-authenticate")
      {:ok, challenge} = Headers.parse_challenge(challenge_header)

      provider_config = %{
        secret_key: stripe_secret_key,
        payment_method: "pm_missing_mpp_provider_integration"
      }

      assert {:error, {:stripe_api_error, status, %{"error" => %{"message" => message}}}} =
               StripeProvider.pay(challenge, provider_config)

      assert status in 400..499
      assert is_binary(message) and message != ""
    end

    test "happy path: 402 → SPT creation → credential → receipt", %{
      config: config,
      stripe_secret_key: stripe_secret_key
    } do
      # Step 1: Request without credentials → 402 with challenge
      conn_402 =
        :get
        |> Plug.Test.conn("/api/data")
        |> MPP.Plug.call(config)

      assert conn_402.status == 402
      assert [challenge_header] = Plug.Conn.get_resp_header(conn_402, "www-authenticate")
      assert {:ok, challenge} = Headers.parse_challenge(challenge_header)
      assert challenge.method == "stripe"
      assert challenge.intent == "charge"
      assert challenge.realm == @realm

      # Step 2: Create test SPT via Stripe test helpers
      spt = create_test_spt!(stripe_secret_key, @amount, @currency)
      assert String.starts_with?(spt, "spt_")

      # Step 3: Build credential with SPT + echoed challenge
      credential = %Credential{
        challenge: challenge,
        payload: %{"spt" => spt}
      }

      auth_header = Headers.format_credential(credential)

      # Step 4: Retry with credential → success with receipt
      conn_200 =
        :get
        |> Plug.Test.conn("/api/data")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> MPP.Plug.call(config)

      assert conn_200.status == nil, "Plug should pass through (not send response) on valid credential"
      assert %Receipt{} = conn_200.assigns[:mpp_receipt]

      receipt = conn_200.assigns[:mpp_receipt]
      assert receipt.status == "success"
      assert receipt.method == "stripe"
      assert String.starts_with?(receipt.reference, "pi_")
      assert receipt.timestamp

      # Verify Payment-Receipt header is set
      assert [receipt_header] = Plug.Conn.get_resp_header(conn_200, "payment-receipt")
      assert {:ok, parsed_receipt} = Headers.parse_receipt(receipt_header)
      assert parsed_receipt.reference == receipt.reference
    end

    test "rejects invalid SPT", %{config: config} do
      # Get a challenge first
      conn_402 =
        :get
        |> Plug.Test.conn("/api/data")
        |> MPP.Plug.call(config)

      assert conn_402.status == 402
      [challenge_header] = Plug.Conn.get_resp_header(conn_402, "www-authenticate")
      {:ok, challenge} = Headers.parse_challenge(challenge_header)

      # Submit credential with fake SPT
      credential = %Credential{
        challenge: challenge,
        payload: %{"spt" => "spt_invalid_fake_token"}
      }

      auth_header = Headers.format_credential(credential)

      conn_error =
        :get
        |> Plug.Test.conn("/api/data")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> MPP.Plug.call(config)

      assert conn_error.status == 402
      body = Jason.decode!(conn_error.resp_body)
      assert body["type"] =~ "verification-failed"
      assert body["detail"] =~ "Stripe"
    end

    test "rejects credential with missing SPT", %{config: config} do
      conn_402 =
        :get
        |> Plug.Test.conn("/api/data")
        |> MPP.Plug.call(config)

      assert conn_402.status == 402
      [challenge_header] = Plug.Conn.get_resp_header(conn_402, "www-authenticate")
      {:ok, challenge} = Headers.parse_challenge(challenge_header)

      # Submit credential with empty payload (no spt)
      credential = %Credential{
        challenge: challenge,
        payload: %{}
      }

      auth_header = Headers.format_credential(credential)

      conn_error =
        :get
        |> Plug.Test.conn("/api/data")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> MPP.Plug.call(config)

      assert conn_error.status == 402
      body = Jason.decode!(conn_error.resp_body)
      assert body["type"] =~ "invalid-payload"
    end

    test "receipt format matches spec", %{
      stripe_secret_key: stripe_secret_key
    } do
      config =
        plug_config(
          stripe_secret_key,
          external_id: "test_order_42"
        )

      # Get challenge
      conn_402 =
        :get
        |> Plug.Test.conn("/api/data")
        |> MPP.Plug.call(config)

      [challenge_header] = Plug.Conn.get_resp_header(conn_402, "www-authenticate")
      {:ok, challenge} = Headers.parse_challenge(challenge_header)
      assert challenge_request(challenge)["externalId"] == "test_order_42"

      # Create SPT and credential
      spt = create_test_spt!(stripe_secret_key, @amount, @currency)

      credential = %Credential{
        challenge: challenge,
        payload: %{"spt" => spt, "externalId" => "test_order_42"}
      }

      auth_header = Headers.format_credential(credential)

      conn_200 =
        :get
        |> Plug.Test.conn("/api/data")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> MPP.Plug.call(config)

      receipt = conn_200.assigns[:mpp_receipt]

      # Verify all receipt fields per spec
      assert receipt.status == "success"
      assert receipt.method == "stripe"
      assert String.starts_with?(receipt.reference, "pi_")
      assert receipt.external_id == "test_order_42"

      # Timestamp should be valid ISO 8601
      assert {:ok, _dt, _offset} = DateTime.from_iso8601(receipt.timestamp)
    end
  end

  describe "subscription activation" do
    test "creates one fixed-price subscription and validates its paid first invoice", %{
      stripe_secret_key: stripe_secret_key
    } do
      customer_id = create_test_customer!(stripe_secret_key, "success")
      payment_method_id = attach_test_payment_method!(stripe_secret_key, customer_id, "pm_card_visa")
      on_exit(fn -> delete_test_customer!(stripe_secret_key, customer_id) end)

      config = subscription_plug_config(stripe_secret_key)
      conn_402 = request_challenge_conn(config)
      [challenge_header] = Plug.Conn.get_resp_header(conn_402, "www-authenticate")
      {:ok, challenge} = Headers.parse_challenge(challenge_header)
      on_exit(fn -> archive_test_products!(stripe_secret_key, challenge.id) end)

      request = challenge_request(challenge)
      assert challenge.intent == "subscription"
      assert request["periodUnit"] == "day"
      assert request["periodCount"] == "1"
      refute Map.has_key?(request, "recipient")
      refute Map.has_key?(request, "subscriptionExpires")

      credential = %Credential{
        challenge: challenge,
        payload: %{"paymentMethod" => payment_method_id, "customer" => customer_id}
      }

      conn_200 =
        :get
        |> Plug.Test.conn("/api/subscription")
        |> Plug.Conn.put_req_header("authorization", Headers.format_credential(credential))
        |> MPP.Plug.call(config)

      assert conn_200.status == nil, "subscription activation failed: #{inspect(conn_200.resp_body)}"
      assert %Receipt{} = receipt = conn_200.assigns[:mpp_receipt]
      assert receipt.method == "stripe"
      assert receipt.status == "success"
      assert is_binary(receipt.subscription_id) and receipt.subscription_id != ""
      assert String.starts_with?(receipt.reference, "in_")
      assert %{"stripeSubscription" => "sub_" <> _rest = stripe_subscription_id} = receipt.extensions

      stripe_subscription = stripe_get!(stripe_secret_key, "/subscriptions/#{stripe_subscription_id}")
      assert stripe_subscription["status"] == "active"
      assert stripe_subscription["customer"] == customer_id
      assert stripe_subscription["default_payment_method"] == payment_method_id
      assert stripe_subscription["collection_method"] == "charge_automatically"
      assert [%{"quantity" => 1, "price" => price}] = stripe_subscription["items"]["data"]
      assert price["unit_amount"] == 100
      assert price["currency"] == "usd"
      assert price["recurring"]["interval"] == "day"
      assert price["recurring"]["interval_count"] == 1

      invoice =
        stripe_get!(
          stripe_secret_key,
          "/invoices/#{receipt.reference}?" <>
            URI.encode_query([{"expand[]", "payments.data.payment.payment_intent"}])
        )

      assert invoice["status"] == "paid"
      assert invoice["amount_paid"] == 100
      assert invoice["currency"] == "usd"
      assert [payment] = invoice["payments"]["data"]
      assert payment["status"] == "paid"
      assert payment["payment"]["payment_intent"]["status"] == "succeeded"
      assert payment["payment"]["payment_intent"]["setup_future_usage"] == "off_session"
    end

    test "records one live renewal and preserves Stripe's missing-invoice error", %{
      stripe_secret_key: stripe_secret_key
    } do
      frozen_time = System.system_time(:second)

      test_clock =
        stripe_post!(
          stripe_secret_key,
          "/test_helpers/test_clocks",
          [{"frozen_time", Integer.to_string(frozen_time)}, {"name", "MPP renewal integration"}]
        )

      assert %{"id" => "clock_" <> _rest = test_clock_id, "status" => "ready"} = test_clock
      on_exit(fn -> delete_test_clock!(stripe_secret_key, test_clock_id) end)

      customer_id = create_test_customer!(stripe_secret_key, "renewal", test_clock: test_clock_id)
      payment_method_id = attach_test_payment_method!(stripe_secret_key, customer_id, "pm_card_visa")
      store = start_subscription_store!()
      config = subscription_plug_config(stripe_secret_key, store)
      conn_402 = request_challenge_conn(config)
      [challenge_header] = Plug.Conn.get_resp_header(conn_402, "www-authenticate")
      {:ok, challenge} = Headers.parse_challenge(challenge_header)
      on_exit(fn -> archive_test_products!(stripe_secret_key, challenge.id) end)

      credential = %Credential{
        challenge: challenge,
        payload: %{"paymentMethod" => payment_method_id, "customer" => customer_id}
      }

      conn_200 =
        :get
        |> Plug.Test.conn("/api/subscription")
        |> Plug.Conn.put_req_header("authorization", Headers.format_credential(credential))
        |> MPP.Plug.call(config)

      assert %Receipt{} = activation = conn_200.assigns[:mpp_receipt]
      assert {:ok, activation_record} = Store.get(store, activation.subscription_id)

      renewal_time =
        activation_record
        |> then(&DateTime.shift(&1.billing_anchor, day: 1, hour: 2))
        |> DateTime.to_unix()

      stripe_post!(
        stripe_secret_key,
        "/test_helpers/test_clocks/#{test_clock_id}/advance",
        [{"frozen_time", Integer.to_string(renewal_time)}]
      )

      wait_for_test_clock!(stripe_secret_key, test_clock_id)

      renewal_invoice =
        wait_for_paid_renewal!(
          stripe_secret_key,
          activation.extensions["stripeSubscription"]
        )

      assert %{"id" => "in_" <> _rest = renewal_invoice_id} = renewal_invoice

      renewal_event =
        stripe_secret_key
        |> stripe_get!(
          "/events?" <>
            URI.encode_query([
              {"type", "invoice.paid"},
              {"limit", "100"},
              {"created[gte]", Integer.to_string(frozen_time)}
            ])
        )
        |> Map.fetch!("data")
        |> Enum.find(&(get_in(&1, ["data", "object", "id"]) == renewal_invoice_id))

      assert %{"id" => "evt_" <> _rest = event_id} = renewal_event
      method_config = subscription_method_config(stripe_secret_key, store)

      assert {:ok, %Receipt{reference: ^renewal_invoice_id}} =
               StripeSubscription.process_invoice(event_id, renewal_invoice_id, method_config)

      assert {:ok, %Receipt{reference: ^renewal_invoice_id}} =
               StripeSubscription.process_invoice(event_id, renewal_invoice_id, method_config)

      assert {:ok, renewed} = Store.get(store, activation.subscription_id)
      assert renewed.last_charged_period == 1
      assert map_size(renewed.payments) == 2
      assert renewed.payments[1].event_ids == [event_id]

      assert {:ok, canceled} = StripeSubscription.cancel(activation.subscription_id, method_config)
      assert canceled.cancellation_effective_at == DateTime.shift(activation_record.billing_anchor, day: 2)

      stripe_subscription =
        stripe_get!(stripe_secret_key, "/subscriptions/#{activation.extensions["stripeSubscription"]}")

      assert stripe_subscription["cancel_at"] == DateTime.to_unix(canceled.cancellation_effective_at)
      assert {:ok, ^canceled} = StripeSubscription.cancel(activation.subscription_id, method_config)

      assert {:error, error} =
               StripeSubscription.process_invoice(
                 "evt_missing_mpp_renewal",
                 "in_missing_mpp_renewal",
                 method_config
               )

      assert error.detail == "Stripe Invoice retrieval failed"
    end

    test "rejects a first invoice that requires customer action", %{
      stripe_secret_key: stripe_secret_key
    } do
      customer_id = create_test_customer!(stripe_secret_key, "requires-action")

      payment_method_id =
        attach_test_payment_method!(stripe_secret_key, customer_id, "pm_card_authenticationRequired")

      on_exit(fn -> delete_test_customer!(stripe_secret_key, customer_id) end)

      config = subscription_plug_config(stripe_secret_key)
      conn_402 = request_challenge_conn(config)
      [challenge_header] = Plug.Conn.get_resp_header(conn_402, "www-authenticate")
      {:ok, challenge} = Headers.parse_challenge(challenge_header)
      on_exit(fn -> archive_test_products!(stripe_secret_key, challenge.id) end)

      credential = %Credential{
        challenge: challenge,
        payload: %{"paymentMethod" => payment_method_id, "customer" => customer_id}
      }

      conn_error =
        :get
        |> Plug.Test.conn("/api/subscription")
        |> Plug.Conn.put_req_header("authorization", Headers.format_credential(credential))
        |> MPP.Plug.call(config)

      assert conn_error.status == 402
      body = Jason.decode!(conn_error.resp_body)
      assert body["type"] =~ "verification-failed"
      assert body["detail"] == "Stripe subscription first invoice requires customer action"
      assert Plug.Conn.get_resp_header(conn_error, "payment-receipt") == []
    end
  end

  describe "Stripe Connect settlement" do
    test "destination charge settles on and routes funds to a connected account", %{
      stripe_secret_key: stripe_secret_key
    } do
      connect_account =
        System.get_env("STRIPE_CONNECT_ACCOUNT") ||
          flunk("""
          Missing Stripe Connect test account!

          Set this environment variable to a connected account id (acct_...) that
          exists under your platform's Stripe test mode with active
          card_payments and transfers capabilities:
            export STRIPE_CONNECT_ACCOUNT="acct_..."

          Create one at: https://dashboard.stripe.com/test/connect/accounts/overview
          Then run:
            STRIPE_SECRET_KEY=sk_test_... STRIPE_CONNECT_ACCOUNT=acct_... mix test --include integration
          """)

      # Settle on the connected account and route the full payment there. Making
      # the destination the settlement merchant also supports cross-region test
      # accounts, which Stripe rejects for platform-settled destination charges.
      config =
        MPP.Plug.init(
          secret_key: @hmac_secret,
          realm: @realm,
          method: Stripe,
          amount: @amount,
          currency: @currency,
          method_config: %{
            "stripe_secret_key" => stripe_secret_key,
            "network_id" => "internal",
            "connect" => %{
              "on_behalf_of" => connect_account,
              "transfer_data" => %{"destination" => connect_account}
            }
          }
        )

      conn_402 =
        :get
        |> Plug.Test.conn("/api/data")
        |> MPP.Plug.call(config)

      assert conn_402.status == 402
      [challenge_header] = Plug.Conn.get_resp_header(conn_402, "www-authenticate")
      {:ok, challenge} = Headers.parse_challenge(challenge_header)

      # Connect topology must not leak into the public challenge.
      refute challenge_header =~ connect_account

      spt = create_test_spt!(stripe_secret_key, @amount, @currency)
      credential = %Credential{challenge: challenge, payload: %{"spt" => spt}}
      auth_header = Headers.format_credential(credential)

      conn_200 =
        :get
        |> Plug.Test.conn("/api/data")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> MPP.Plug.call(config)

      assert conn_200.status == nil,
             "Destination charge should verify and pass through — got #{inspect(conn_200.resp_body)}"

      receipt = conn_200.assigns[:mpp_receipt]
      assert %Receipt{} = receipt
      assert receipt.status == "success"
      assert String.starts_with?(receipt.reference, "pi_")
    end
  end

  defp plug_config(stripe_secret_key, opts \\ []) do
    plug_opts =
      Keyword.merge(
        [
          secret_key: @hmac_secret,
          realm: @realm,
          method: Stripe,
          amount: @amount,
          currency: @currency,
          method_config: %{"stripe_secret_key" => stripe_secret_key, "network_id" => "internal"}
        ],
        opts
      )

    MPP.Plug.init(plug_opts)
  end

  defp subscription_plug_config(stripe_secret_key, store \\ nil) do
    MPP.Plug.init(
      secret_key: @hmac_secret,
      realm: @realm,
      intent: "subscription",
      method: Stripe,
      amount: @amount,
      currency: @currency,
      period_unit: "day",
      period_count: "1",
      method_config: subscription_method_config(stripe_secret_key, store)
    )
  end

  defp subscription_method_config(stripe_secret_key, store) do
    maybe_put_store(
      %{
        "stripe_secret_key" => stripe_secret_key,
        "network_id" => "internal",
        "payment_method_types" => ["card"],
        "metadata" => %{"test" => "mpp-stripe-subscription"}
      },
      store
    )
  end

  defp maybe_put_store(config, nil), do: config
  defp maybe_put_store(config, store), do: Map.put(config, "subscription_store", store)

  defp request_challenge_conn(config) do
    :get
    |> Plug.Test.conn("/api/data")
    |> MPP.Plug.call(config)
  end

  defp challenge_request(challenge) do
    {:ok, json} = Base.url_decode64(challenge.request, padding: false)
    Jason.decode!(json)
  end

  # Creates a test SPT via Stripe's test helpers endpoint.
  # Uses pm_card_visa which always succeeds in test mode.
  defp create_test_spt!(stripe_secret_key, amount, currency) do
    expires_at = System.system_time(:second) + @spt_ttl_seconds
    auth = Base.encode64(stripe_secret_key <> ":")

    body =
      URI.encode_query(
        [
          {"payment_method", "pm_card_visa"},
          {"usage_limits[currency]", currency},
          {"usage_limits[max_amount]", amount},
          {"usage_limits[expires_at]", Integer.to_string(expires_at)}
        ],
        :www_form
      )

    result =
      Req.post!(@spt_endpoint,
        headers: [
          {"authorization", "Basic #{auth}"},
          {"content-type", "application/x-www-form-urlencoded"}
        ],
        body: body
      )

    case result do
      %Req.Response{status: status, body: %{"id" => spt_id}} when status in 200..299 ->
        spt_id

      %Req.Response{body: %{"error" => %{"message" => message}}} ->
        if String.contains?(message, "Unrecognized request URL") do
          flunk("""
          Stripe SPT endpoint not available for this account.

          Machine payments (SPTs) require beta access:
            https://stripe.com/docs/machine-payments

          Request access: https://stripe.com/contact/sales?topic=machine-payments
          """)
        else
          flunk("Failed to create test SPT: #{message}")
        end

      %Req.Response{status: status, body: body} ->
        flunk("Failed to create test SPT: HTTP #{status} — #{inspect(body)}")
    end
  end

  defp create_test_customer!(stripe_secret_key, scenario, opts \\ []) do
    params = maybe_add_test_clock([{"description", "MPP Stripe subscription integration #{scenario}"}], opts[:test_clock])

    response =
      stripe_post!(
        stripe_secret_key,
        "/customers",
        params
      )

    case response do
      %{"id" => "cus_" <> _rest = customer_id} -> customer_id
      body -> flunk("Stripe returned an invalid test Customer: #{inspect(body)}")
    end
  end

  defp maybe_add_test_clock(params, nil), do: params
  defp maybe_add_test_clock(params, test_clock), do: params ++ [{"test_clock", test_clock}]

  defp attach_test_payment_method!(stripe_secret_key, customer_id, payment_method) do
    response =
      stripe_post!(
        stripe_secret_key,
        "/payment_methods/#{payment_method}/attach",
        [{"customer", customer_id}]
      )

    case response do
      %{"id" => "pm_" <> _rest = payment_method_id, "customer" => ^customer_id} -> payment_method_id
      body -> flunk("Stripe returned an invalid attached PaymentMethod: #{inspect(body)}")
    end
  end

  defp archive_test_products!(stripe_secret_key, challenge_id) do
    stripe_secret_key
    |> stripe_get!("/products?limit=100&active=true")
    |> Map.fetch!("data")
    |> Enum.filter(&(get_in(&1, ["metadata", "mpp_challenge_id"]) == challenge_id))
    |> Enum.each(fn product ->
      response = stripe_post!(stripe_secret_key, "/products/#{product["id"]}", [{"active", "false"}])
      assert response["active"] == false
    end)
  end

  defp delete_test_customer!(stripe_secret_key, customer_id) do
    response = stripe_delete!(stripe_secret_key, "/customers/#{customer_id}")
    assert response["deleted"] == true
    assert response["id"] == customer_id
  end

  defp delete_test_clock!(stripe_secret_key, test_clock_id) do
    response = stripe_delete!(stripe_secret_key, "/test_helpers/test_clocks/#{test_clock_id}")
    assert response["deleted"] == true
    assert response["id"] == test_clock_id
  end

  defp start_subscription_store! do
    name = :"#{__MODULE__}.#{System.unique_integer([:positive])}"
    start_supervised!(SubscriptionStore.child_spec(name: name))
    {SubscriptionStore, [name: name]}
  end

  defp wait_for_test_clock!(stripe_secret_key, test_clock_id) do
    deadline = System.monotonic_time(:millisecond) + @test_clock_timeout_ms
    poll_test_clock!(stripe_secret_key, test_clock_id, deadline)
  end

  defp wait_for_paid_renewal!(stripe_secret_key, stripe_subscription_id) do
    deadline = System.monotonic_time(:millisecond) + @test_clock_timeout_ms
    poll_paid_renewal!(stripe_secret_key, stripe_subscription_id, deadline)
  end

  defp poll_paid_renewal!(stripe_secret_key, stripe_subscription_id, deadline) do
    invoices =
      stripe_secret_key
      |> stripe_get!(
        "/invoices?" <>
          URI.encode_query([{"subscription", stripe_subscription_id}, {"limit", "10"}])
      )
      |> Map.fetch!("data")

    case Enum.find(invoices, &(&1["billing_reason"] == "subscription_cycle" and &1["status"] == "paid")) do
      nil -> wait_for_paid_renewal_retry!(stripe_secret_key, stripe_subscription_id, invoices, deadline)
      invoice -> invoice
    end
  end

  defp wait_for_paid_renewal_retry!(stripe_secret_key, stripe_subscription_id, invoices, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      receive do
      after
        @test_clock_poll_ms -> poll_paid_renewal!(stripe_secret_key, stripe_subscription_id, deadline)
      end
    else
      summary = Enum.map(invoices, &Map.take(&1, ["id", "billing_reason", "status"]))
      flunk("Stripe did not pay a renewal invoice: #{inspect(summary)}")
    end
  end

  defp poll_test_clock!(stripe_secret_key, test_clock_id, deadline) do
    case stripe_get!(stripe_secret_key, "/test_helpers/test_clocks/#{test_clock_id}") do
      %{"status" => "ready"} ->
        :ok

      %{"status" => "advancing"} = clock ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            @test_clock_poll_ms -> poll_test_clock!(stripe_secret_key, test_clock_id, deadline)
          end
        else
          flunk("Stripe test clock did not become ready: #{inspect(clock)}")
        end

      clock ->
        flunk("Stripe test clock did not become ready: #{inspect(clock)}")
    end
  end

  defp stripe_get!(stripe_secret_key, path) do
    stripe_request!(stripe_secret_key, :get, path, nil)
  end

  defp stripe_post!(stripe_secret_key, path, params) do
    stripe_request!(stripe_secret_key, :post, path, URI.encode_query(params, :www_form))
  end

  defp stripe_delete!(stripe_secret_key, path) do
    stripe_request!(stripe_secret_key, :delete, path, nil)
  end

  defp stripe_request!(stripe_secret_key, method, path, body) do
    headers = [
      {"authorization", "Basic #{Base.encode64(stripe_secret_key <> ":")}"},
      {"stripe-version", @stripe_api_version}
    ]

    headers = if body, do: headers ++ [{"content-type", "application/x-www-form-urlencoded"}], else: headers

    request = [url: "https://api.stripe.com/v1" <> path, method: method, headers: headers]
    request = if body, do: Keyword.put(request, :body, body), else: request

    case Req.request!(request) do
      %Req.Response{status: status, body: response_body} when status in 200..299 -> response_body
      %Req.Response{status: status, body: response_body} -> flunk("Stripe API HTTP #{status}: #{inspect(response_body)}")
    end
  end
end
