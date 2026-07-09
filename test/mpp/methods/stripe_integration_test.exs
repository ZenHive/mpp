defmodule MPP.Methods.StripeIntegrationTest do
  @moduledoc """
  Integration tests for the Stripe payment method against Stripe's real test mode API.

  Requires `STRIPE_SECRET_KEY` environment variable set to a Stripe test mode secret key.
  Run with: `mix test --include integration`
  """

  use ExUnit.Case, async: false

  alias MPP.Credential
  alias MPP.Headers
  alias MPP.Methods.Stripe
  alias MPP.Receipt

  @moduletag :integration

  @hmac_secret "test-hmac-secret-for-integration"
  @realm "integration-test.example.com"
  @amount "100"
  @currency "usd"

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

  describe "Stripe Connect settlement" do
    test "destination charge routes funds to a connected account", %{stripe_secret_key: stripe_secret_key} do
      connect_account =
        System.get_env("STRIPE_CONNECT_ACCOUNT") ||
          flunk("""
          Missing Stripe Connect test account!

          Set this environment variable to a connected account id (acct_...) that
          exists under your platform's Stripe test mode:
            export STRIPE_CONNECT_ACCOUNT="acct_..."

          Create one at: https://dashboard.stripe.com/test/connect/accounts/overview
          Then run:
            STRIPE_SECRET_KEY=sk_test_... STRIPE_CONNECT_ACCOUNT=acct_... mix test --include integration
          """)

      # Route the full payment (@amount) to the connected account as a destination charge.
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
            "connect" => %{"transfer_data" => %{"destination" => connect_account}}
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
end
