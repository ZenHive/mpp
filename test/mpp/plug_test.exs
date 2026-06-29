defmodule MPP.PlugTest do
  use ExUnit.Case, async: true

  alias MPP.Challenge
  alias MPP.Credential
  alias MPP.Errors
  alias MPP.Headers
  alias MPP.Intents.Charge
  alias MPP.Plug, as: PaymentPlug
  alias MPP.Receipt
  alias MPP.Tempo.ConCacheStore
  alias MPP.Test.TempoMemoryStore

  # --- Mock Methods ---

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

  defmodule MockMethodUnexpectedError do
    @moduledoc false
    use MPP.Method

    @impl MPP.Method
    def method_name, do: "mock_unexpected"

    @impl MPP.Method
    def verify(_payload, _charge) do
      {:error, :some_unknown_reason}
    end
  end

  defmodule MockMethodB do
    @moduledoc false
    use MPP.Method

    @impl MPP.Method
    def method_name, do: "mock_b"

    @impl MPP.Method
    def verify(%{"token" => "valid"}, charge) do
      {:ok, Receipt.new(method: method_name(), reference: "ref_b_#{charge.amount}")}
    end

    def verify(_payload, _charge) do
      {:error, Errors.new(:invalid_payload, "Missing token field")}
    end
  end

  defmodule MockTempoMethod do
    @moduledoc false
    use MPP.Method

    @impl MPP.Method
    def method_name, do: "tempo"

    @impl MPP.Method
    def verify(%{"proof" => "valid"}, _charge) do
      {:ok, Receipt.new(method: method_name(), reference: "tempo_ref")}
    end

    def verify(_payload, _charge) do
      {:error, Errors.new(:invalid_payload, "Missing proof")}
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

  # Returns the first (or only) method entry from config.
  defp first_entry(config), do: hd(config.method_entries)

  defp expires_for(config) do
    DateTime.utc_now()
    |> DateTime.add(config.expires_in, :second)
    |> DateTime.to_iso8601()
  end

  # Builds a valid credential for the given config's first method entry.
  defp build_authorization_header(config, payload \\ %{"proof" => "valid"}) do
    build_authorization_header_for_entry(config, first_entry(config), payload)
  end

  # Builds a valid credential for a specific method entry.
  defp build_authorization_header_for_entry(config, entry, payload) do
    params =
      [
        realm: config.realm,
        method: entry.method.method_name(),
        intent: "charge",
        request: entry.request,
        expires: expires_for(config)
      ]

    params = if config.digest, do: Keyword.put(params, :digest, config.digest), else: params
    params = if config.opaque, do: Keyword.put(params, :opaque, config.opaque), else: params
    challenge = Challenge.create(params, config.secret_key)

    credential = %Credential{challenge: challenge, payload: payload}
    Headers.format_credential(credential)
  end

  # Builds a credential with an expires field.
  defp build_authorization_header_with_expires(config, expires_in) do
    entry = first_entry(config)

    expires =
      DateTime.utc_now()
      |> DateTime.add(expires_in, :second)
      |> DateTime.to_iso8601()

    challenge =
      Challenge.create(
        [
          realm: config.realm,
          method: entry.method.method_name(),
          intent: "charge",
          request: entry.request,
          expires: expires
        ],
        config.secret_key
      )

    credential = %Credential{challenge: challenge, payload: %{"proof" => "valid"}}
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

  defp get_all_resp_headers(conn, header) do
    Plug.Conn.get_resp_header(conn, header)
  end

  defp start_replay_store! do
    cache_name = :"#{__MODULE__}.#{System.unique_integer([:positive])}"
    start_supervised!({ConCacheStore, name: cache_name})
    {ConCacheStore, name: cache_name}
  end

  # --- init/1 (single-method, backwards compat) ---

  describe "init/1" do
    test "returns Config struct with valid opts" do
      config = init_config()
      assert %PaymentPlug.Config{} = config
      assert config.secret_key == @secret_key
      assert config.realm == "api.test.com"

      assert [%PaymentPlug.MethodEntry{} = entry] = config.method_entries
      assert entry.method == MockMethod
      assert %Charge{amount: "1000", currency: "usd"} = entry.charge
      assert is_binary(entry.request)
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
      config =
        init_config(
          recipient: "acct_123",
          description: "Premium",
          expires_in: 300,
          digest: "sha-256=X48E9qOokqqrvdts8nOJRJN3OWDUoyWxBf7kbu9DBPE",
          opaque: "eyJ0ZXN0Ijp0cnVlfQ"
        )

      entry = first_entry(config)
      assert entry.charge.recipient == "acct_123"
      assert entry.charge.description == "Premium"
      assert config.expires_in == 300
      assert config.digest == "sha-256=X48E9qOokqqrvdts8nOJRJN3OWDUoyWxBf7kbu9DBPE"
      assert config.opaque == "eyJ0ZXN0Ijp0cnVlfQ"
    end

    test "optional fields use secure defaults" do
      config = init_config()
      assert config.expires_in == 300
      assert config.digest == nil
      assert config.opaque == nil
      assert config.store == nil
      assert first_entry(config).charge.recipient == nil
    end

    test "accepts optional shared replay store" do
      store = {ConCacheStore, name: :plug_replay_test}
      config = init_config(store: store)

      assert config.store == store
    end

    test "raises when expires_in is not a positive integer" do
      for expires_in <- [0, -1, "300"] do
        assert_raise ArgumentError, ~r/:expires_in must be a positive integer/, fn ->
          init_config(expires_in: expires_in)
        end
      end
    end

    test "merges method_details from challenge_method_details callback" do
      config = init_config(method: MockMethodWithDetails)
      assert first_entry(config).charge.method_details == %{"networkId" => "net_test", "paymentMethodTypes" => ["card"]}
    end

    test "pre-encodes request as base64url JSON" do
      config = init_config()
      {:ok, json} = Base.url_decode64(first_entry(config).request, padding: false)
      {:ok, map} = Jason.decode(json)
      assert map["amount"] == "1000"
      assert map["currency"] == "usd"
    end
  end

  # --- init/1 multi-method ---

  describe "init/1 multi-method" do
    test "returns Config with multiple MethodEntry structs" do
      config =
        PaymentPlug.init(
          secret_key: @secret_key,
          realm: "api.test.com",
          methods: [
            [method: MockMethod, amount: "1000", currency: "usd"],
            [method: MockMethodB, amount: "500", currency: "usd"]
          ]
        )

      assert %PaymentPlug.Config{} = config
      assert [_, _] = config.method_entries

      [entry_a, entry_b] = config.method_entries
      assert entry_a.method == MockMethod
      assert entry_a.charge.amount == "1000"
      assert entry_b.method == MockMethodB
      assert entry_b.charge.amount == "500"
    end

    test "each entry has independent request encoding" do
      config =
        PaymentPlug.init(
          secret_key: @secret_key,
          realm: "api.test.com",
          methods: [
            [method: MockMethod, amount: "1000", currency: "usd"],
            [method: MockMethodB, amount: "500", currency: "eur"]
          ]
        )

      [entry_a, entry_b] = config.method_entries
      refute entry_a.request == entry_b.request

      {:ok, json_a} = Base.url_decode64(entry_a.request, padding: false)
      {:ok, map_a} = Jason.decode(json_a)
      assert map_a["amount"] == "1000"
      assert map_a["currency"] == "usd"

      {:ok, json_b} = Base.url_decode64(entry_b.request, padding: false)
      {:ok, map_b} = Jason.decode(json_b)
      assert map_b["amount"] == "500"
      assert map_b["currency"] == "eur"
    end

    test "raises when both :method and :methods present" do
      assert_raise ArgumentError, ~r/either :method or :methods/, fn ->
        PaymentPlug.init(
          secret_key: @secret_key,
          realm: "api.test.com",
          method: MockMethod,
          amount: "1000",
          currency: "usd",
          methods: [[method: MockMethodB, amount: "500", currency: "usd"]]
        )
      end
    end

    test "raises when neither :method nor :methods present" do
      assert_raise ArgumentError, ~r/either :method or :methods/, fn ->
        PaymentPlug.init(secret_key: @secret_key, realm: "api.test.com")
      end
    end

    test "raises on duplicate method names" do
      assert_raise ArgumentError, ~r/duplicate method names/, fn ->
        PaymentPlug.init(
          secret_key: @secret_key,
          realm: "api.test.com",
          methods: [
            [method: MockMethod, amount: "1000", currency: "usd"],
            [method: MockMethod, amount: "500", currency: "usd"]
          ]
        )
      end
    end

    test "per-method method_config stays independent" do
      config =
        PaymentPlug.init(
          secret_key: @secret_key,
          realm: "api.test.com",
          methods: [
            [method: MockMethod, amount: "1000", currency: "usd", method_config: %{"key" => "a"}],
            [method: MockMethodB, amount: "500", currency: "usd", method_config: %{"key" => "b"}]
          ]
        )

      [entry_a, entry_b] = config.method_entries
      assert entry_a.method_config == %{"key" => "a"}
      assert entry_b.method_config == %{"key" => "b"}
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

  describe "call/2 with shared replay store" do
    setup do
      store = start_replay_store!()
      config = init_config(store: store)
      auth_header = build_authorization_header(config)

      {:ok, config: config, auth_header: auth_header}
    end

    test "rejects the same credential on second use", %{config: config, auth_header: auth_header} do
      first_conn =
        :get
        |> Plug.Test.conn("/premium")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> call_plug(config)

      refute first_conn.halted

      second_conn =
        :get
        |> Plug.Test.conn("/premium")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> call_plug(config)

      assert second_conn.status == 402
      body = decode_json_body(second_conn)
      assert body["type"] =~ "verification-failed"
      assert body["detail"] == "Payment credential already used"
    end

    test "does not mark failed method verification as used", %{config: config} do
      auth_header = build_authorization_header(config, %{"proof" => "invalid"})

      first_conn =
        :get
        |> Plug.Test.conn("/premium")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> call_plug(config)

      second_conn =
        :get
        |> Plug.Test.conn("/premium")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> call_plug(config)

      assert first_conn.status == 402
      assert second_conn.status == 402
      assert decode_json_body(first_conn)["detail"] == "Invalid proof"
      assert decode_json_body(second_conn)["detail"] == "Invalid proof"
    end

    test "non-tempo method_config store does not skip plug-level replay store" do
      config =
        init_config(
          method_config: %{"store" => TempoMemoryStore},
          store: start_replay_store!()
        )

      auth_header = build_authorization_header(config)

      first_conn =
        :get
        |> Plug.Test.conn("/premium")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> call_plug(config)

      second_conn =
        :get
        |> Plug.Test.conn("/premium")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> call_plug(config)

      refute first_conn.halted
      assert second_conn.status == 402
      assert decode_json_body(second_conn)["detail"] == "Payment credential already used"
    end

    test "tempo method with its own store skips plug-level replay store" do
      config =
        init_config(
          method: MockTempoMethod,
          method_config: %{"store" => TempoMemoryStore},
          store: start_replay_store!()
        )

      auth_header = build_authorization_header(config)

      first_conn =
        :get
        |> Plug.Test.conn("/premium")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> call_plug(config)

      second_conn =
        :get
        |> Plug.Test.conn("/premium")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> call_plug(config)

      refute first_conn.halted
      refute second_conn.halted
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

    test "accepts the same credential twice when no shared replay store is configured", %{
      config: config,
      auth_header: auth_header
    } do
      first_conn =
        :get
        |> Plug.Test.conn("/premium")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> call_plug(config)

      second_conn =
        :get
        |> Plug.Test.conn("/premium")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> call_plug(config)

      refute first_conn.halted
      refute second_conn.halted
    end

    test "accepts credential whose digest matches endpoint config" do
      digest = "sha-256=X48E9qOokqqrvdts8nOJRJN3OWDUoyWxBf7kbu9DBPE"
      config = init_config(digest: digest)
      auth_header = build_authorization_header(config)

      conn =
        :get
        |> Plug.Test.conn("/premium")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> call_plug(config)

      refute conn.halted
      assert get_resp_header(conn, "payment-receipt")
    end

    test "rejects credential whose digest differs from endpoint config" do
      config = init_config(digest: "sha-256=X48E9qOokqqrvdts8nOJRJN3OWDUoyWxBf7kbu9DBPE")
      entry = first_entry(config)

      challenge =
        Challenge.create(
          [
            realm: config.realm,
            method: entry.method.method_name(),
            intent: "charge",
            request: entry.request,
            expires: expires_for(config),
            digest: "sha-256=Y48E9qOokqqrvdts8nOJRJN3OWDUoyWxBf7kbu9DBPE"
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
      assert body["type"] =~ "invalid-challenge"
      assert body["detail"] =~ "digest"
    end

    test "assigns receipt to conn", %{config: config, auth_header: auth_header} do
      conn =
        :get
        |> Plug.Test.conn("/premium")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> call_plug(config)

      assert %Receipt{method: "mock", reference: "ref_1000"} = conn.assigns[:mpp_receipt]
    end

    test "accepts credential whose opaque matches endpoint config" do
      config = init_config(opaque: "eyJyb3V0ZSI6ImEifQ")
      auth_header = build_authorization_header(config)

      conn =
        :get
        |> Plug.Test.conn("/premium")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> call_plug(config)

      refute conn.halted
      assert get_resp_header(conn, "payment-receipt")
    end

    test "rejects credential whose opaque differs from endpoint config" do
      config = init_config(opaque: "eyJyb3V0ZSI6ImEifQ")
      entry = first_entry(config)

      challenge =
        Challenge.create(
          [
            realm: config.realm,
            method: entry.method.method_name(),
            intent: "charge",
            request: entry.request,
            expires: expires_for(config),
            opaque: "eyJyb3V0ZSI6ImIifQ"
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
      assert body["type"] =~ "invalid-challenge"
      assert body["detail"] =~ "opaque"
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

    # End-to-end through the plug: an over-16KiB Authorization token is rejected
    # before any base64url decode (token-size DoS cap, mpp-rs #299) and surfaces
    # as the standard malformed_credential 402, not a crash or unbounded alloc.
    test "over-limit Authorization token returns 402 before decode", %{config: config} do
      oversized = "Payment " <> String.duplicate("A", 16 * 1024 + 1)

      conn =
        :get
        |> Plug.Test.conn("/premium")
        |> Plug.Conn.put_req_header("authorization", oversized)
        |> call_plug(config)

      assert conn.status == 402
      body = decode_json_body(conn)
      assert body["type"] =~ "malformed-credential"
      assert body["detail"] =~ "token_too_large"
    end

    test "tampered challenge returns 402 with invalid_challenge", %{config: config} do
      entry = first_entry(config)

      challenge =
        Challenge.create(
          [realm: config.realm, method: "mock", intent: "charge", request: entry.request],
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
      entry = first_entry(config)

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
            request: entry.request,
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

      auth_header = build_authorization_header(config_cheap)

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

    test "rejects credential with wrong recipient" do
      config_alice = init_config(recipient: "acct_alice")
      config_bob = init_config(recipient: "acct_bob")

      auth_header = build_authorization_header(config_alice)

      conn =
        :get
        |> Plug.Test.conn("/bob-endpoint")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> call_plug(config_bob)

      assert conn.status == 402
      body = decode_json_body(conn)
      assert body["type"] =~ "invalid-challenge"
    end

    test "rejects credential with no recipient on endpoint that requires one" do
      config_no_recipient = init_config()
      config_with_recipient = init_config(recipient: "acct_bob")

      # Credential from an endpoint with no recipient
      auth_header = build_authorization_header(config_no_recipient)

      # Presented to an endpoint that requires a specific recipient
      conn =
        :get
        |> Plug.Test.conn("/bob-endpoint")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> call_plug(config_with_recipient)

      assert conn.status == 402
      body = decode_json_body(conn)
      assert body["type"] =~ "invalid-challenge"
    end

    test "rejects credential with wrong realm (shared-secret deployment)" do
      # Both configs use the same secret_key but different realms
      config_a = init_config(realm: "api-a.example.com")
      config_b = init_config(realm: "api-b.example.com")

      auth_header = build_authorization_header(config_a)

      conn =
        :get
        |> Plug.Test.conn("/endpoint-b")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> call_plug(config_b)

      assert conn.status == 402
      body = decode_json_body(conn)
      assert body["type"] =~ "invalid-challenge"
    end
  end

  # --- Expiration ---

  describe "challenge expiration" do
    test "includes expires field by default" do
      config = init_config()

      conn =
        :get
        |> Plug.Test.conn("/premium")
        |> call_plug(config)

      www_auth = get_resp_header(conn, "www-authenticate")
      {:ok, challenge} = Headers.parse_challenge(www_auth)
      assert challenge.expires

      {:ok, expires_dt, _} = DateTime.from_iso8601(challenge.expires)
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

  # --- Multi-method 402 response ---

  describe "call/2 multi-method 402 response" do
    setup do
      config =
        PaymentPlug.init(
          secret_key: @secret_key,
          realm: "api.test.com",
          methods: [
            [method: MockMethod, amount: "1000", currency: "usd"],
            [method: MockMethodB, amount: "500", currency: "usd"]
          ]
        )

      {:ok, config: config}
    end

    test "returns multiple WWW-Authenticate headers", %{config: config} do
      conn =
        :get
        |> Plug.Test.conn("/premium")
        |> call_plug(config)

      assert conn.status == 402
      headers = get_all_resp_headers(conn, "www-authenticate")
      assert [_, _] = headers
    end

    test "each header has correct method name", %{config: config} do
      conn =
        :get
        |> Plug.Test.conn("/premium")
        |> call_plug(config)

      headers = get_all_resp_headers(conn, "www-authenticate")

      challenges =
        Enum.map(headers, fn h ->
          {:ok, c} = Headers.parse_challenge(h)
          c
        end)

      method_names = challenges |> Enum.map(& &1.method) |> Enum.sort()
      assert method_names == ["mock", "mock_b"]
    end

    test "all challenges share the same realm", %{config: config} do
      conn =
        :get
        |> Plug.Test.conn("/premium")
        |> call_plug(config)

      headers = get_all_resp_headers(conn, "www-authenticate")

      realms =
        Enum.map(headers, fn h ->
          {:ok, c} = Headers.parse_challenge(h)
          c.realm
        end)

      assert Enum.uniq(realms) == ["api.test.com"]
    end

    test "each challenge has a unique HMAC-bound ID", %{config: config} do
      conn =
        :get
        |> Plug.Test.conn("/premium")
        |> call_plug(config)

      headers = get_all_resp_headers(conn, "www-authenticate")

      ids =
        Enum.map(headers, fn h ->
          {:ok, c} = Headers.parse_challenge(h)
          c.id
        end)

      assert [_, _] = Enum.uniq(ids)
    end
  end

  # --- Multi-method credential routing ---

  describe "call/2 multi-method credential routing" do
    setup do
      config =
        PaymentPlug.init(
          secret_key: @secret_key,
          realm: "api.test.com",
          methods: [
            [method: MockMethod, amount: "1000", currency: "usd"],
            [method: MockMethodB, amount: "500", currency: "usd"]
          ]
        )

      {:ok, config: config}
    end

    test "credential for method A routes to A and succeeds", %{config: config} do
      [entry_a, _entry_b] = config.method_entries
      auth_header = build_authorization_header_for_entry(config, entry_a, %{"proof" => "valid"})

      conn =
        :get
        |> Plug.Test.conn("/premium")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> call_plug(config)

      refute conn.halted
      {:ok, receipt} = Headers.parse_receipt(get_resp_header(conn, "payment-receipt"))
      assert receipt.method == "mock"
      assert receipt.reference == "ref_1000"
    end

    test "credential for method B routes to B and succeeds", %{config: config} do
      [_entry_a, entry_b] = config.method_entries
      auth_header = build_authorization_header_for_entry(config, entry_b, %{"token" => "valid"})

      conn =
        :get
        |> Plug.Test.conn("/premium")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> call_plug(config)

      refute conn.halted
      {:ok, receipt} = Headers.parse_receipt(get_resp_header(conn, "payment-receipt"))
      assert receipt.method == "mock_b"
      assert receipt.reference == "ref_b_500"
    end

    test "credential for unknown method returns method_unsupported", %{config: config} do
      # Build a credential with a method name that doesn't match any entry
      challenge =
        Challenge.create(
          [
            realm: config.realm,
            method: "nonexistent",
            intent: "charge",
            request: first_entry(config).request
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

      assert conn.status == 400
      body = decode_json_body(conn)
      assert body["type"] =~ "method-unsupported"
      assert get_all_resp_headers(conn, "www-authenticate") == []
    end

    test "method A payload rejected by method B", %{config: config} do
      [_entry_a, entry_b] = config.method_entries
      # Send MockMethod's payload format to MockMethodB (expects "token", not "proof")
      auth_header = build_authorization_header_for_entry(config, entry_b, %{"proof" => "valid"})

      conn =
        :get
        |> Plug.Test.conn("/premium")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> call_plug(config)

      assert conn.status == 402
      body = decode_json_body(conn)
      assert body["type"] =~ "invalid-payload"
    end
  end

  # --- Multi-method cross-route replay ---

  describe "multi-method cross-route replay" do
    test "credential for method A at price X rejected when method A has price Y" do
      config_cheap =
        PaymentPlug.init(
          secret_key: @secret_key,
          realm: "api.test.com",
          methods: [
            [method: MockMethod, amount: "1000", currency: "usd"],
            [method: MockMethodB, amount: "500", currency: "usd"]
          ]
        )

      config_expensive =
        PaymentPlug.init(
          secret_key: @secret_key,
          realm: "api.test.com",
          methods: [
            [method: MockMethod, amount: "5000", currency: "usd"],
            [method: MockMethodB, amount: "2500", currency: "usd"]
          ]
        )

      # Build credential for cheap MockMethod
      [entry_a, _] = config_cheap.method_entries
      auth_header = build_authorization_header_for_entry(config_cheap, entry_a, %{"proof" => "valid"})

      # Try on expensive endpoint
      conn =
        :get
        |> Plug.Test.conn("/expensive")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> call_plug(config_expensive)

      assert conn.status == 402
      body = decode_json_body(conn)
      assert body["type"] =~ "invalid-challenge"
    end
  end

  # --- Coverage: unexpected verify error and malformed expires ---

  describe "verify_credential/4 catch-all error" do
    test "unexpected error type from method returns 402 with verification_failed" do
      config = init_config(method: MockMethodUnexpectedError)
      auth_header = build_authorization_header(config, %{"anything" => "value"})

      conn =
        :get
        |> Plug.Test.conn("/premium")
        |> Plug.Conn.put_req_header("authorization", auth_header)
        |> call_plug(config)

      assert conn.status == 402
      body = decode_json_body(conn)
      assert body["type"] =~ "verification-failed"
      assert body["detail"] =~ "Payment verification failed"
    end
  end

  describe "check_expiration/1 malformed expires" do
    test "malformed expires timestamp returns 402 payment_expired" do
      config = init_config()
      entry = first_entry(config)

      # Build a challenge with an invalid expires value
      challenge =
        Challenge.create(
          [
            realm: config.realm,
            method: entry.method.method_name(),
            intent: "charge",
            request: entry.request,
            expires: "not-a-valid-date"
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
  end
end
