defmodule MPP.Client.Providers.StripeTest do
  use ExUnit.Case, async: true

  alias MPP.Challenge
  alias MPP.Client.MultiProvider
  alias MPP.Client.Providers.Stripe
  alias MPP.Client.Providers.Tempo
  alias MPP.Expires
  alias MPP.Intents.Charge

  @network_id "profile_1MqDcVKA5fEO2tZvKQm9g8Yj"
  @spt "spt_test_123"

  describe "supports?/3" do
    test "supports only Stripe charge challenges" do
      assert Stripe.supports?("stripe", "charge", %{})
      refute Stripe.supports?("tempo", "charge", %{})
      refute Stripe.supports?("stripe", "session", %{})
    end
  end

  describe "pay/2" do
    test "creates a test-mode SPT and echoes the challenge external ID" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/v1/test_helpers/shared_payment/granted_tokens"
        assert ["Basic " <> encoded_key] = Plug.Conn.get_req_header(conn, "authorization")
        assert Base.decode64!(encoded_key) == "sk_test_provider:"
        assert ["2026-07-29.preview"] = Plug.Conn.get_req_header(conn, "stripe-version")

        params = form_params(conn)
        assert params["payment_method"] == "pm_card_visa"
        assert params["usage_limits[currency]"] == "usd"
        assert params["usage_limits[max_amount]"] == "1250"
        assert params["seller_details[network_id]"] == @network_id
        assert params["metadata[cart]"] == "cart_123"
        assert String.to_integer(params["usage_limits[expires_at]"]) > System.os_time(:second)

        Req.Test.json(conn, %{"id" => @spt})
      end)

      challenge = challenge(external_id: "order_123", metadata: %{"cart" => "cart_123"})

      assert {:ok, credential} = Stripe.pay(challenge, provider_config())
      assert credential.challenge == challenge
      assert credential.payload == %{"spt" => @spt, "externalId" => "order_123"}
    end

    test "uses the live endpoint and business-profile field for a live key" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/v1/shared_payment/issued_tokens"
        params = form_params(conn)
        assert params["seller_details[network_business_profile]"] == @network_id
        refute Map.has_key?(params, "seller_details[network_id]")
        Req.Test.json(conn, %{"id" => @spt})
      end)

      config = %{provider_config() | secret_key: "sk_live_provider"}
      assert {:ok, credential} = Stripe.pay(challenge(), config)
      assert credential.payload == %{"spt" => @spt}
    end

    test "retries the test helper without optional seller fields when Stripe rejects them" do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(__MODULE__, fn conn ->
        call = Agent.get_and_update(calls, fn count -> {count, count + 1} end)

        case call do
          0 ->
            params = form_params(conn)
            assert params["seller_details[network_id]"] == @network_id

            conn
            |> Plug.Conn.put_status(400)
            |> Req.Test.json(%{"error" => %{"message" => "Received unknown parameter: seller_details"}})

          1 ->
            params = form_params(conn)
            refute Map.has_key?(params, "seller_details[network_id]")
            Req.Test.json(conn, %{"id" => @spt})
        end
      end)

      assert {:ok, credential} = Stripe.pay(challenge(metadata: %{"cart" => "cart_123"}), provider_config())
      assert credential.payload["spt"] == @spt
      assert Agent.get(calls, & &1) == 2
    end

    test "returns Stripe API errors without hiding their response" do
      body = %{"error" => %{"code" => "resource_missing", "message" => "No such payment method"}}

      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(body)
      end)

      assert {:error, {:stripe_api_error, 400, ^body}} =
               Stripe.pay(challenge(), provider_config())
    end

    test "does not retry a test-mode API error unrelated to optional fields" do
      body = %{"error" => %{"message" => "The payment method was declined"}}
      Req.Test.expect(__MODULE__, fn conn -> conn |> Plug.Conn.put_status(402) |> Req.Test.json(body) end)

      assert {:error, {:stripe_api_error, 402, ^body}} =
               Stripe.pay(challenge(metadata: %{"cart" => "cart_123"}), provider_config())

      Req.Test.verify!(__MODULE__)
    end

    test "propagates transport errors" do
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
      config = Map.put(provider_config(), :req_options, plug: {Req.Test, __MODULE__}, retry: false)

      assert {:error, %Req.TransportError{reason: :econnrefused}} = Stripe.pay(challenge(), config)
    end

    test "uses a configured fallback external ID" do
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{"id" => @spt}) end)
      config = Map.put(provider_config(), :external_id, "fallback_order")

      assert {:ok, credential} = Stripe.pay(challenge(), config)
      assert credential.payload["externalId"] == "fallback_order"
    end

    test "returns explicit config and challenge errors without issuing a request" do
      assert {:error, {:missing_config, :secret_key}} = Stripe.pay(challenge(), %{})

      assert {:error, {:invalid_config, :expected_map}} = Stripe.pay(challenge(), [])

      assert {:error, {:invalid_config, :secret_key}} =
               Stripe.pay(challenge(), Map.put(provider_config(), :secret_key, 12))

      assert {:error, {:missing_challenge_field, "networkId"}} =
               Stripe.pay(challenge(method_details: %{}), provider_config())

      assert {:error, {:invalid_challenge_field, "networkId"}} =
               Stripe.pay(challenge(method_details: %{"networkId" => 12}), provider_config())

      assert {:error, :invalid_method_details} =
               Stripe.pay(
                 challenge(method_details: nil),
                 provider_config() |> Map.delete(:req_options) |> Map.put(:spt_url, "https://stripe.invalid")
               )

      assert {:error, :invalid_metadata} =
               Stripe.pay(challenge(metadata: "invalid"), provider_config())

      assert {:error, :invalid_metadata} =
               Stripe.pay(challenge(metadata: %{"count" => 12}), provider_config())

      assert {:error, :reserved_external_id_metadata} =
               Stripe.pay(challenge(metadata: %{"externalId" => "shadow"}), provider_config())

      assert {:error, {:invalid_config, :external_id}} =
               Stripe.pay(challenge(), Map.put(provider_config(), :external_id, ""))

      assert {:error, {:invalid_config, :req_options}} =
               Stripe.pay(challenge(), Map.put(provider_config(), :req_options, %{}))

      expired = %{challenge() | expires: Expires.seconds(-1)}
      assert {:error, :payment_expired} = Stripe.pay(expired, provider_config())
    end
  end

  test "MultiProvider selects the built-in Stripe provider after Tempo declines" do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{"id" => @spt}) end)

    multi =
      MultiProvider.new([
        {Tempo, %{}},
        {Stripe, provider_config()}
      ])

    assert MultiProvider.supports?(multi, "stripe", "charge")
    assert {:ok, credential} = MultiProvider.pay(multi, challenge())
    assert credential.payload["spt"] == @spt
  end

  defp challenge(opts \\ []) do
    details =
      opts
      |> Keyword.get(:method_details, %{"networkId" => @network_id})
      |> maybe_put_metadata(Keyword.get(opts, :metadata))

    {:ok, charge} =
      Charge.new(
        amount: "1250",
        currency: "usd",
        external_id: Keyword.get(opts, :external_id),
        method_details: details
      )

    request = charge |> Charge.to_request() |> Jason.encode!() |> Base.url_encode64(padding: false)

    %Challenge{
      id: "stripe-challenge-123",
      realm: "payments.example.com",
      method: "stripe",
      intent: "charge",
      request: request,
      expires: Expires.minutes(5)
    }
  end

  defp provider_config do
    %{
      secret_key: "sk_test_provider",
      payment_method: "pm_card_visa",
      req_options: [plug: {Req.Test, __MODULE__}]
    }
  end

  defp form_params(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    URI.decode_query(body)
  end

  defp maybe_put_metadata(details, nil), do: details
  defp maybe_put_metadata(details, metadata), do: Map.put(details, "metadata", metadata)
end
