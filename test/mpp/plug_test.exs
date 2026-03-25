defmodule MPP.PlugTest do
  use ExUnit.Case, async: true

  alias MPP.Challenge
  alias MPP.Credential
  alias MPP.Errors
  alias MPP.Headers
  alias MPP.Intents.Charge
  alias MPP.Plug, as: PaymentPlug
  alias MPP.Receipt

  # --- Mock Method ---

  defmodule MockMethod do
    @moduledoc false
    use MPP.Method

    @impl MPP.Method
    def method_name, do: "mock"

    @impl MPP.Method
    def verify(%{"proof" => "valid"}, charge) do
      {:ok, Receipt.new(method: method_name(), reference: "ref_#{charge.amount}")}
    end

    def verify(%{"proof" => "invalid"}, _charge) do
      {:error, Errors.new(:verification_failed, "Invalid proof")}
    end

    def verify(_payload, _charge) do
      {:error, Errors.new(:invalid_payload, "Missing proof field")}
    end
  end

  defmodule MockMethodWithDetails do
    @moduledoc false
    use MPP.Method

    @impl MPP.Method
    def method_name, do: "mock_details"

    @impl MPP.Method
    def verify(%{"proof" => _}, charge) do
      {:ok, Receipt.new(method: method_name(), reference: "ref_#{charge.amount}")}
    end

    def verify(_payload, _charge) do
      {:error, Errors.new(:invalid_payload, "Missing proof")}
    end

    @impl MPP.Method
    def challenge_method_details(_charge) do
      %{"networkId" => "net_test", "paymentMethodTypes" => ["card"]}
    end
  end

  # --- Helpers ---

  @secret_key "test-secret-key-for-plug"
  @base_opts [
    secret_key: @secret_key,
    realm: "api.test.com",
    method: MockMethod,
    amount: "1000",
    currency: "usd"
  ]

  defp init_config(overrides \\ []) do
    @base_opts
    |> Keyword.merge(overrides)
    |> PaymentPlug.init()
  end

  defp call_plug(conn, config) do
    PaymentPlug.call(conn, config)
  end

  # Builds a valid credential for the given config and returns the Authorization header value.
  defp build_authorization_header(config, payload \\ %{"proof" => "valid"}) do
    challenge =
      Challenge.create(
        [
          realm: config.realm,
          method: config.method.method_name(),
          intent: "charge",
          request: config.request
        ],
        config.secret_key
      )

    credential = %Credential{challenge: challenge, payload: payload}
    Headers.format_credential(credential)
  end

  defp decode_json_body(conn) do
    Jason.decode!(conn.resp_body)
  end

  defp get_resp_header(conn, header) do
    case Plug.Conn.get_resp_header(conn, header) do
      [value | _] -> value
      [] -> nil
    end
  end

  # --- init/1 ---

  describe "init/1" do
    test "returns Config struct with valid opts" do
      config = init_config()
      assert %PaymentPlug.Config{} = config
      assert config.secret_key == @secret_key
      assert config.realm == "api.test.com"
      assert config.method == MockMethod
      assert %Charge{amount: "1000", currency: "usd"} = config.charge
      assert is_binary(config.request)
    end

    test "raises on missing required opts" do
      assert_raise ArgumentError, ~r/:secret_key/, fn ->
        PaymentPlug.init(realm: "x", method: MockMethod, amount: "1", currency: "usd")
      end

      assert_raise ArgumentError, ~r/:method/, fn ->
        PaymentPlug.init(secret_key: "x", realm: "x", amount: "1", currency: "usd")
      end
    end

    test "accepts optional fields" do
      config = init_config(recipient: "acct_123", description: "Premium", expires_in: 300, opaque: "eyJ0ZXN0Ijp0cnVlfQ")
      assert config.charge.recipient == "acct_123"
      assert config.charge.description == "Premium"
      assert config.expires_in == 300
      assert config.opaque == "eyJ0ZXN0Ijp0cnVlfQ"
    end

    test "optional fields default to nil" do
      config = init_config()
      assert config.expires_in == nil
      assert config.opaque == nil
      assert config.charge.recipient == nil
    end

    test "merges method_details from challenge_method_details callback" do
      config = init_config(method: MockMethodWithDetails)
      assert config.charge.method_details == %{"networkId" => "net_test", "paymentMethodTypes" => ["card"]}
    end

    test "pre-encodes request as base64url JSON" do
      config = init_config()
      {:ok, json} = Base.url_decode64(config.request, padding: false)
      {:ok, map} = Jason.decode(json)
      assert map["amount"] == "1000"
      assert map["currency"] == "usd"
    end
  end

  # --- No credential → 402 ---

  describe "call/2 without credential" do
    setup do
      {:ok, config: init_config()}
    end

    test "returns 402 when no Authorization header", %{config: config} do
      conn =
        :get
        |> Plug.Test.conn("/premium")
        |> call_plug(config)

      assert conn.status == 402
      assert conn.halted
    end

    test "includes WWW-Authenticate header with valid challenge", %{config: config} do
      conn =
        :get
        |> Plug.Test.conn("/premium")
        |> call_plug(config)

      www_auth = get_resp_header(conn, "www-authenticate")
      assert www_auth
      {:ok, challenge} = Headers.parse_challenge(www_auth)
      assert challenge.realm == "api.test.com"
      assert challenge.method == "mock"
      assert challenge.intent == "charge"
      assert challenge.id
    end

    test "sets Cache-Control: no-store", %{config: config} do
      conn =
        :get
        |> Plug.Test.conn("/premium")
        |> call_plug(config)

      assert get_resp_header(conn, "cache-control") == "no-store"
    end

    test "returns RFC 9457 error body", %{config: config} do
      conn =
        :get
        |> Plug.Test.conn("/premium")
        |> call_plug(config)

      body = decode_json_body(conn)
      assert body["type"] =~ "payment-required"
      assert body["status"] == 402
      assert is_binary(body["detail"])
    end

    test "treats Bearer scheme as no credential", %{config: config} do
      conn =
        :get
        |> Plug.Test.conn("/premium")
        |> Plug.Conn.put_req_header("authorization", "Bearer some-token")
        |> call_plug(config)

      assert conn.status == 402
      body = decode_json_body(conn)
      assert body["type"] =~ "payment-required"
    end
  end

  # --- Valid credential → pass-through ---

  describe "call/2 with valid credential" do
    setup do
      config = init_config()
      auth_header = build_authorization_header(config)
      {:ok, config: config, auth_header: auth_header}
    end

    test "passes through without setting status", %{config: config, auth_header: auth_header} do
      conn =
        :get
        |> Plug.Test.conn("/premium")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> call_plug(config)

      refute conn.halted
      assert conn.status == nil
    end

    test "sets Payment-Receipt header", %{config: config, auth_header: auth_header} do
      conn =
        :get
        |> Plug.Test.conn("/premium")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> call_plug(config)

      receipt_header = get_resp_header(conn, "payment-receipt")
      assert receipt_header
      {:ok, receipt} = Headers.parse_receipt(receipt_header)
      assert receipt.method == "mock"
      assert receipt.reference == "ref_1000"
      assert receipt.status == "success"
    end

    test "sets Cache-Control: private", %{config: config, auth_header: auth_header} do
      conn =
        :get
        |> Plug.Test.conn("/premium")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> call_plug(config)

      assert get_resp_header(conn, "cache-control") == "private"
    end

    test "assigns receipt to conn", %{config: config, auth_header: auth_header} do
      conn =
        :get
        |> Plug.Test.conn("/premium")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> call_plug(config)

      assert %Receipt{method: "mock", reference: "ref_1000"} = conn.assigns[:mpp_receipt]
    end
  end

  # --- Invalid credential scenarios ---

  describe "call/2 with invalid credentials" do
    setup do
      {:ok, config: init_config()}
    end

    test "malformed base64 returns 402 with malformed_credential", %{config: config} do
      conn =
        :get
        |> Plug.Test.conn("/premium")
        |> Plug.Conn.put_req_header("authorization", "Payment !!!not-base64!!!")
        |> call_plug(config)

      assert conn.status == 402
      body = decode_json_body(conn)
      assert body["type"] =~ "malformed-credential"
    end

    test "tampered challenge returns 402 with invalid_challenge", %{config: config} do
      # Build a credential but with a different secret key (simulates tampering)
      challenge =
        Challenge.create(
          [realm: config.realm, method: "mock", intent: "charge", request: config.request],
          "wrong-secret-key"
        )

      credential = %Credential{challenge: challenge, payload: %{"proof" => "valid"}}
      auth_header = Headers.format_credential(credential)

      conn =
        :get
        |> Plug.Test.conn("/premium")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> call_plug(config)

      assert conn.status == 402
      body = decode_json_body(conn)
      assert body["type"] =~ "invalid-challenge"
    end

    test "expired challenge returns 402 with payment_expired", %{config: config} do
      past_time =
        DateTime.utc_now()
        |> DateTime.add(-3600, :second)
        |> DateTime.to_iso8601()

      challenge =
        Challenge.create(
          [
            realm: config.realm,
            method: "mock",
            intent: "charge",
            request: config.request,
            expires: past_time
          ],
          config.secret_key
        )

      credential = %Credential{challenge: challenge, payload: %{"proof" => "valid"}}
      auth_header = Headers.format_credential(credential)

      conn =
        :get
        |> Plug.Test.conn("/premium")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> call_plug(config)

      assert conn.status == 402
      body = decode_json_body(conn)
      assert body["type"] =~ "payment-expired"
    end

    test "method verification failure returns 402 with method's error", %{config: config} do
      auth_header = build_authorization_header(config, %{"proof" => "invalid"})

      conn =
        :get
        |> Plug.Test.conn("/premium")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> call_plug(config)

      assert conn.status == 402
      body = decode_json_body(conn)
      assert body["type"] =~ "verification-failed"
      assert body["detail"] == "Invalid proof"
    end

    test "missing payload fields returns 402 with method's error", %{config: config} do
      auth_header = build_authorization_header(config, %{})

      conn =
        :get
        |> Plug.Test.conn("/premium")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> call_plug(config)

      assert conn.status == 402
      body = decode_json_body(conn)
      assert body["type"] =~ "invalid-payload"
    end

    test "402 responses always include a fresh challenge", %{config: config} do
      # Malformed credential
      conn =
        :get
        |> Plug.Test.conn("/premium")
        |> Plug.Conn.put_req_header("authorization", "Payment !!!bad!!!")
        |> call_plug(config)

      www_auth = get_resp_header(conn, "www-authenticate")
      assert www_auth
      {:ok, challenge} = Headers.parse_challenge(www_auth)
      assert challenge.id
      assert challenge.realm == "api.test.com"
    end
  end

  # --- Cross-route replay prevention ---

  describe "cross-route replay prevention" do
    test "rejects credential with wrong amount" do
      config_cheap = init_config(amount: "1000")
      config_expensive = init_config(amount: "5000")

      # Build credential for the cheap route
      auth_header = build_authorization_header(config_cheap)

      # Try to use it on the expensive route
      conn =
        :get
        |> Plug.Test.conn("/expensive")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> call_plug(config_expensive)

      assert conn.status == 402
      body = decode_json_body(conn)
      assert body["type"] =~ "invalid-challenge"
    end

    test "rejects credential with wrong currency" do
      config_usd = init_config(currency: "usd")
      config_eur = init_config(currency: "eur")

      auth_header = build_authorization_header(config_usd)

      conn =
        :get
        |> Plug.Test.conn("/eur-endpoint")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> call_plug(config_eur)

      assert conn.status == 402
      body = decode_json_body(conn)
      assert body["type"] =~ "invalid-challenge"
    end
  end

  # --- Expiration ---

  describe "challenge expiration" do
    test "includes expires field when expires_in is set" do
      config = init_config(expires_in: 300)

      conn =
        :get
        |> Plug.Test.conn("/premium")
        |> call_plug(config)

      www_auth = get_resp_header(conn, "www-authenticate")
      {:ok, challenge} = Headers.parse_challenge(www_auth)
      assert challenge.expires

      {:ok, expires_dt, _} = DateTime.from_iso8601(challenge.expires)
      # Should be ~5 minutes in the future (with some tolerance)
      diff = DateTime.diff(expires_dt, DateTime.utc_now(), :second)
      assert diff > 290 and diff <= 300
    end

    test "non-expired challenge with expires_in is accepted" do
      config = init_config(expires_in: 300)
      auth_header = build_authorization_header_with_expires(config, 300)

      conn =
        :get
        |> Plug.Test.conn("/premium")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> call_plug(config)

      refute conn.halted
    end
  end

  # Helper that builds a credential with an expires field
  defp build_authorization_header_with_expires(config, expires_in) do
    expires =
      DateTime.utc_now()
      |> DateTime.add(expires_in, :second)
      |> DateTime.to_iso8601()

    challenge =
      Challenge.create(
        [
          realm: config.realm,
          method: config.method.method_name(),
          intent: "charge",
          request: config.request,
          expires: expires
        ],
        config.secret_key
      )

    credential = %Credential{challenge: challenge, payload: %{"proof" => "valid"}}
    Headers.format_credential(credential)
  end
end
