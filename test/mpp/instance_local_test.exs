defmodule MPP.InstanceLocalTest do
  # Mutates process-wide environment variables, so it cannot run concurrently.
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias MPP.Challenge
  alias MPP.Credential
  alias MPP.Demo.Method, as: DemoMethod
  alias MPP.Headers
  alias MPP.InstanceLocal
  alias MPP.Intents.Charge
  alias MPP.Intents.Session
  alias MPP.Methods.Tempo
  alias MPP.Replay
  alias MPP.Session.Actions
  alias MPP.Session.ETSStore, as: SessionETSStore
  alias MPP.Session.Store, as: SessionStore
  alias MPP.Subscription.ETSStore, as: SubscriptionETSStore
  alias MPP.Subscription.Store, as: SubscriptionStore
  alias MPP.Tempo.ConCacheStore
  alias MPP.Tempo.Store

  defmodule SessionMethod do
    @moduledoc false
    use MPP.Method

    @impl MPP.Method
    def method_name, do: "mocksession"

    @impl MPP.Method
    def verify(_payload, _intent), do: {:error, MPP.Errors.new(:invalid_payload, "unused")}
  end

  # The list mppx reads in refs/mppx/src/internal/env.ts (`sharedPlatforms`),
  # minus the JavaScript-only hosts (Vercel, Netlify, Deno Deploy).
  @platform_variables ~w(AWS_LAMBDA_FUNCTION_NAME DYNO FLY_APP_NAME K_SERVICE RAILWAY_ENVIRONMENT RENDER)
  @secret_key String.duplicate("k", 32)

  setup do
    saved = Map.new(@platform_variables, &{&1, System.get_env(&1)})
    Enum.each(@platform_variables, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  describe "shared_runtime/2" do
    test "a single node with no platform variable is not shared" do
      assert InstanceLocal.shared_runtime([], fn _name -> nil end) == nil
    end

    test "each platform variable is a signal" do
      for name <- @platform_variables do
        getenv = fn
          ^name -> "value"
          _other -> nil
        end

        assert InstanceLocal.shared_runtime([], getenv) == "#{name} is set"
      end
    end

    test "an empty platform variable is not a signal" do
      assert InstanceLocal.shared_runtime([], fn _name -> "" end) == nil
    end

    test "an unrelated variable is not a signal" do
      getenv = fn
        "MIX_ENV" -> "prod"
        _other -> nil
      end

      assert InstanceLocal.shared_runtime([], getenv) == nil
    end

    test "connected nodes are a signal" do
      assert InstanceLocal.shared_runtime([:b@host, :c@host], fn _name -> nil end) ==
               "this node is connected to 2 other node(s)"
    end
  end

  describe "MPP.Tempo.Store.for_method/2" do
    test "falls back to the default store on a single local node" do
      assert Store.for_method(nil, "tempo") == ConCacheStore
    end

    test "refuses the default store when a platform variable is set" do
      System.put_env("FLY_APP_NAME", "shop")

      error = assert_raise ArgumentError, fn -> Store.for_method(nil, "tempo") end

      assert error.message =~ "the tempo route"
      assert error.message =~ "FLY_APP_NAME is set"
      assert error.message =~ "Configure a shared MPP.Tempo.Store backend"
      assert error.message =~ "pass MPP.Tempo.ConCacheStore explicitly"
    end

    test "an explicit store is returned unchanged on a shared runtime" do
      System.put_env("FLY_APP_NAME", "shop")

      assert Store.for_method(ConCacheStore, "tempo") == ConCacheStore
      assert Store.for_method({ConCacheStore, name: :other}, "tempo") == {ConCacheStore, name: :other}
    end

    test "the opt-out is unchanged on a shared runtime" do
      System.put_env("FLY_APP_NAME", "shop")

      assert Store.for_method(false, "tempo") == nil
    end
  end

  describe "method verification" do
    @charge %Charge{
      amount: "1000",
      currency: "0x20c0000000000000000000000000000000000000",
      recipient: "0x1111111111111111111111111111111111111111"
    }
    @payload %{"type" => "hash", "hash" => "0x" <> String.duplicate("ab", 32)}

    test "a Tempo charge without a store raises on a shared runtime" do
      System.put_env("K_SERVICE", "shop")

      assert_raise ArgumentError, ~r/the tempo route has no method_config "store" configured and K_SERVICE is set/, fn ->
        Tempo.verify(@payload, %{@charge | method_details: %{}})
      end
    end

    test "a Tempo charge naming ConCacheStore reaches verification on a shared runtime" do
      System.put_env("K_SERVICE", "shop")

      # No credential source is configured, so verification rejects the
      # credential; the point is that it gets that far instead of raising.
      assert {:error, %MPP.Errors{}} =
               Tempo.verify(@payload, %{@charge | method_details: %{"store" => ConCacheStore}})
    end
  end

  describe "session and subscription stores" do
    # Well-formed, so the action reaches the store; a malformed payload is
    # rejected before any store is selected.
    defp voucher_payload do
      %{
        "action" => "voucher",
        "channelId" => "0x" <> String.duplicate("ab", 32),
        "cumulativeAmount" => "10",
        "signature" => "0x" <> String.duplicate("cd", 65)
      }
    end

    test "fall back to the ETS stores on a single local node" do
      assert SessionStore.for_method(nil, "tempo") == SessionETSStore
      assert SubscriptionStore.for_method(nil, "stripe") == SubscriptionETSStore
    end

    test "refuse the ETS stores on a shared runtime" do
      System.put_env("DYNO", "web.1")

      assert_raise ArgumentError, ~r/the tempo route has no session_store configured and DYNO is set/, fn ->
        SessionStore.for_method(nil, "tempo")
      end

      assert_raise ArgumentError, ~r/the stripe route has no method_config "subscription_store" configured/, fn ->
        SubscriptionStore.for_method(nil, "stripe")
      end
    end

    test "explicit ETS stores are returned unchanged on a shared runtime" do
      System.put_env("DYNO", "web.1")

      assert SessionStore.for_method(SessionETSStore, "tempo") == SessionETSStore
      assert SubscriptionStore.for_method(SubscriptionETSStore, "stripe") == SubscriptionETSStore
    end

    test "dispatch/2 and handle/2 without :store raise on a shared runtime" do
      System.put_env("RENDER", "true")
      voucher = voucher_payload()

      assert_raise ArgumentError, ~r/the xrpl route has no session_store configured and RENDER is set/, fn ->
        Actions.dispatch(voucher, method_name: "xrpl")
      end

      assert_raise ArgumentError, ~r/the session route has no session_store configured/, fn ->
        Actions.dispatch(voucher, [])
      end

      assert_raise ArgumentError, ~r/has no session_store configured/, fn ->
        {:ok, payload} = MPP.Session.Payload.parse(voucher)
        Actions.handle(payload, [])
      end
    end

    test "dispatch/2 with an explicit ETS store does not raise on a shared runtime" do
      System.put_env("RENDER", "true")
      voucher = voucher_payload()

      assert {:error, %MPP.Errors{}} = Actions.dispatch(voucher, store: SessionETSStore)
    end

    test "a session route without a session store raises on a shared runtime" do
      System.put_env("RENDER", "true")

      session = %Session{amount: "10", currency: "0xtoken", recipient: "0xrecipient", method_details: %{}}

      assert_raise ArgumentError, ~r/has no session_store configured and RENDER is set/, fn ->
        Actions.verify(voucher_payload(), session)
      end
    end
  end

  describe "MPP.Plug" do
    defp init(overrides) do
      [secret_key: @secret_key, realm: "api.test", method: DemoMethod, amount: "100", currency: "usd"]
      |> Keyword.merge(overrides)
      |> MPP.Plug.init()
    end

    defp paid_request(config) do
      [entry] = config.method_entries

      challenge =
        Challenge.create(
          [
            realm: config.realm,
            method: entry.method.method_name(),
            intent: config.intent,
            request: entry.request,
            expires: DateTime.utc_now() |> DateTime.shift(second: config.expires_in) |> DateTime.to_iso8601()
          ],
          config.secret_key
        )

      header = Headers.format_credential(%Credential{challenge: challenge, payload: %{"token" => "demo-token"}})

      :get
      |> conn("/resource")
      |> put_req_header("authorization", header)
      |> MPP.Plug.call(config)
    end

    test "init succeeds on a shared runtime; the check runs per request" do
      System.put_env("RAILWAY_ENVIRONMENT", "production")

      config = init([])

      assert config.implicit_store
      assert config.store == ConCacheStore
    end

    test "a route without :store issues challenges but raises on a paid request" do
      config = init([])
      System.put_env("RAILWAY_ENVIRONMENT", "production")

      assert %Plug.Conn{status: 402} = MPP.Plug.call(conn(:get, "/resource"), config)

      assert_raise ArgumentError,
                   ~r/the demo route has no the :store option configured and RAILWAY_ENVIRONMENT is set/,
                   fn -> paid_request(config) end
    end

    test "a route naming ConCacheStore accepts the payment on a shared runtime" do
      name = :"instance_local_#{System.unique_integer([:positive])}"
      start_supervised!({ConCacheStore, name: name})
      config = init(store: {ConCacheStore, name: name})
      System.put_env("RAILWAY_ENVIRONMENT", "production")

      refute config.implicit_store
      assert %Plug.Conn{halted: false} = paid_request(config)
    end

    test "a route with store: false accepts the payment on a shared runtime" do
      config = init(store: false)
      System.put_env("RAILWAY_ENVIRONMENT", "production")

      assert %Plug.Conn{halted: false} = paid_request(config)
    end

    test "a route without :store accepts the payment on a single local node" do
      assert %Plug.Conn{halted: false} = paid_request(init([]))
    end

    test "an x402 route without :store challenges unpaid requests and raises on an x402 payment" do
      facilitator = %{
        verify: fn _payload, _requirements -> flunk("no facilitator call expected") end,
        settle: fn _payload, _requirements -> flunk("no facilitator call expected") end
      }

      accept = %{
        "scheme" => "exact",
        "network" => "eip155:84532",
        "amount" => "10000",
        "asset" => "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
        "payTo" => "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
        "maxTimeoutSeconds" => 300,
        "extra" => %{"name" => "USDC", "version" => "2"}
      }

      config = init(x402: [facilitator: facilitator, accepts: [accept]])
      System.put_env("FLY_APP_NAME", "shop")

      unpaid = MPP.Plug.call(conn(:get, "/resource"), config)
      assert unpaid.status == 402
      assert [_header] = get_resp_header(unpaid, "payment-required")

      assert_raise ArgumentError, ~r/the x402 route has no the :store option configured and FLY_APP_NAME is set/, fn ->
        :get |> conn("/resource") |> put_req_header("payment-signature", "e30") |> MPP.Plug.call(config)
      end

      explicit = init(x402: [facilitator: facilitator, accepts: [accept]], store: ConCacheStore)

      assert %Plug.Conn{status: 402} =
               :get |> conn("/resource") |> put_req_header("payment-signature", "e30") |> MPP.Plug.call(explicit)
    end

    test "the plug-level store is not consulted for Tempo routes" do
      System.put_env("AWS_LAMBDA_FUNCTION_NAME", "shop")

      assert Replay.store_for(%{store: ConCacheStore, implicit_store: true}, %{method: Tempo}) == nil
    end

    test "a session route writes only a configured session store into method_config" do
      opts = [
        intent: "session",
        method: SessionMethod,
        unit_type: "request",
        suggested_deposit: "1000",
        currency: "0x20c0000000000000000000000000000000000000",
        recipient: "0x1111111111111111111111111111111111111111",
        store: false
      ]

      [implicit] = init(opts).method_entries
      refute Map.has_key?(implicit.method_config, "session_store")

      [explicit] = init(Keyword.put(opts, :session_store, SessionETSStore)).method_entries
      assert explicit.method_config["session_store"] == SessionETSStore
    end
  end
end
