defmodule MPP.X402.PlugTest do
  use ExUnit.Case, async: true

  alias MPP.Errors
  alias MPP.Method
  alias MPP.Methods.EVM.Authorization
  alias MPP.Plug, as: PaymentPlug
  alias MPP.Receipt
  alias MPP.Tempo.ConCacheStore
  alias MPP.Test.EVMAuthorization
  alias MPP.X402
  alias MPP.X402.Exact
  alias MPP.X402.Headers

  @url "http://example.com/resource"
  @accept %{
    "scheme" => "exact",
    "network" => "eip155:84532",
    "amount" => "10000",
    "asset" => "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
    "payTo" => "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
    "maxTimeoutSeconds" => 300,
    "extra" => %{"name" => "USDC", "version" => "2"}
  }
  @extensions %{
    "mppx" => %{
      "info" => %{"method" => "GET"},
      "schema" => %{"type" => "object"}
    }
  }
  @scoped_extensions %{
    "mppx" => %{
      "info" => %{"method" => "GET", "opaque" => "eyJvcmRlciI6IjEyMyJ9"},
      "schema" => %{"type" => "object"}
    }
  }
  @config %{private_key: EVMAuthorization.private_key(), networks: [84_532]}

  defmodule MockMethod do
    @moduledoc false
    use Method

    @impl Method
    def method_name, do: "mock"

    @impl Method
    def verify(%{"proof" => "valid"}, charge) do
      {:ok, Receipt.new(method: method_name(), reference: "ref_#{charge.amount}")}
    end

    def verify(_payload, _charge) do
      {:error, Errors.new(:invalid_payload, "Missing proof")}
    end
  end

  describe "facilitator requirements" do
    test "the facilitator receives the server-configured accept, not the client's echo" do
      opts = plug_opts(self())
      payload = signed_payload(opts)

      # A client echoing lower-cased addresses still matches (address equality),
      # but the facilitator must be handed the server's own requirements.
      echoed =
        payload
        |> put_in(["accepted", "payTo"], String.downcase(@accept["payTo"]))
        |> put_in(["accepted", "asset"], String.downcase(@accept["asset"]))

      conn = settle(opts, echoed)

      assert conn.status == 200
      assert_received {:verify, sent_payload, requirements}
      assert requirements == server_accept(opts)
      assert sent_payload["accepted"] == server_accept(opts)
      assert_received {:settle, _payload, ^requirements}
      assert %{"success" => true} = conn.assigns.x402_settlement
      assert [_header] = Plug.Conn.get_resp_header(conn, "payment-response")
    end

    test "an altered accepted.extra is rejected before the facilitator is called" do
      opts = plug_opts(self())
      payload = signed_payload(opts)
      tampered = put_in(payload, ["accepted", "extra", "version"], "1")

      conn = settle(opts, tampered)

      assert conn.status == 402
      assert problem_detail(conn) =~ "requirements_mismatch"
      refute_received {:verify, _payload, _requirements}
      refute_received {:settle, _payload, _requirements}
    end
  end

  describe "route binding" do
    test "a route-bound credential settles when it echoes the advertised extensions" do
      opts = plug_opts(self(), extensions: @extensions)
      payload = signed_payload(opts)

      assert get_in(payload, ["extensions", "mppx", "info", "method"]) == "GET"
      assert is_binary(get_in(payload, ["extensions", "mppx", "info", "nonce"]))

      conn = settle(opts, payload)

      assert conn.status == 200
      assert_received {:verify, _payload, requirements}
      assert requirements == server_accept(opts)
    end

    test "a route-bound credential with tampered extension info is rejected" do
      opts = plug_opts(self(), extensions: @extensions)
      payload = signed_payload(opts)
      tampered = put_in(payload, ["extensions", "mppx", "info", "method"], "POST")

      conn = settle(opts, tampered)

      assert conn.status == 402
      assert problem_detail(conn) =~ "extension_mismatch"
      refute_received {:verify, _payload, _requirements}
    end

    test "an unscoped route accepts a plain x402 payload by default" do
      for extensions <- [nil, @extensions] do
        opts = plug_opts(self(), extensions: extensions)
        unbound = opts |> signed_payload() |> Map.delete("extensions")

        conn = settle(opts, unbound)

        assert conn.status == 200
        assert_received {:verify, _payload, _requirements}
      end
    end

    test "a scoped route rejects an unbound payload by default" do
      for scope <- [[extensions: @scoped_extensions], [digest: MPP.BodyDigest.compute("")]] do
        opts = plug_opts(self(), scope)
        unbound = opts |> signed_payload() |> Map.delete("extensions")

        conn = settle(opts, unbound)

        assert conn.status == 402
        assert problem_detail(conn) =~ "route_binding_required"
        refute_received {:verify, _payload, _requirements}
      end
    end

    test "a scoped route accepts a route-bound payload by default" do
      opts = plug_opts(self(), extensions: @scoped_extensions)
      payload = signed_payload(opts)

      assert is_binary(get_in(payload, ["extensions", "mppx", "info", "nonce"]))
      assert settle(opts, payload).status == 200
      assert_received {:verify, _payload, _requirements}
    end

    test "every mppx route scope key scopes the route" do
      for key <- ["digest", "opaque", "_mppx_scope"] do
        extensions = put_in(@extensions, ["mppx", "info", key], "value")
        opts = plug_opts(self(), extensions: extensions)
        unbound = opts |> signed_payload() |> Map.delete("extensions")

        assert problem_detail(settle(opts, unbound)) =~ "route_binding_required"
      end
    end

    test ":resource accepts an unbound payload on a scoped route only when it echoes the resource" do
      opts = plug_opts(self(), extensions: @scoped_extensions, route_binding: :resource)
      unbound = opts |> signed_payload() |> Map.delete("extensions")

      assert settle(opts, unbound).status == 200
      assert_received {:verify, _payload, _requirements}

      missing = Map.delete(unbound, "resource")
      assert problem_detail(settle(opts, missing)) =~ "resource_mismatch"

      moved = put_in(unbound, ["resource", "url"], "http://example.com/other")
      assert problem_detail(settle(opts, moved)) =~ "resource_mismatch"
      refute_received {:verify, _payload, _requirements}
    end

    test "explicit :required rejects unbound payloads on scoped routes and accepts them on unscoped routes" do
      scoped = plug_opts(self(), extensions: @scoped_extensions, route_binding: :required)
      unbound = scoped |> signed_payload() |> Map.delete("extensions")
      assert problem_detail(settle(scoped, unbound)) =~ "route_binding_required"
      refute_received {:verify, _payload, _requirements}

      unscoped = plug_opts(self(), extensions: @extensions, route_binding: :required)
      unbound = unscoped |> signed_payload() |> Map.delete("extensions")
      assert settle(unscoped, unbound).status == 200

      moved = put_in(unbound, ["resource", "url"], "http://example.com/other")
      assert problem_detail(settle(unscoped, moved)) =~ "resource_mismatch"
    end

    test "the route digest and opaque scope x402 and are advertised in the binding" do
      digest = MPP.BodyDigest.compute("")

      for {route, key, value} <- [
            {[route_digest: digest], "digest", digest},
            {[route_opaque: "eyJvcmRlciI6IjEyMyJ9"], "opaque", "eyJvcmRlciI6IjEyMyJ9"},
            {[digest: digest], "digest", digest},
            {[opaque: "eyJvcmRlciI6IjEyMyJ9"], "opaque", "eyJvcmRlciI6IjEyMyJ9"}
          ] do
        opts = plug_opts(self(), route)
        payload = signed_payload(opts)

        assert get_in(payload, ["extensions", "mppx", "info", key]) == value
        assert get_in(payload, ["extensions", "mppx", "info", "method"]) == "GET"
        assert is_binary(get_in(payload, ["extensions", "mppx", "info", "nonce"]))
        assert settle(opts, payload).status == 200
        assert_received {:verify, _payload, _requirements}

        unbound = Map.delete(payload, "extensions")
        assert problem_detail(settle(opts, unbound)) =~ "route_binding_required"
        refute_received {:verify, _payload, _requirements}
      end
    end

    test "nested x402 options keep the route scope" do
      digest = MPP.BodyDigest.compute("")
      opts = plug_opts(self(), route_digest: digest, digest: digest, extensions: @extensions)

      assert opts.x402.digest == digest
      unbound = opts |> signed_payload() |> Map.delete("extensions")
      assert problem_detail(settle(opts, unbound)) =~ "route_binding_required"

      assert_raise ArgumentError, ~r/:digest conflicts/, fn ->
        plug_opts(self(), route_digest: digest, digest: MPP.BodyDigest.compute("other"))
      end

      assert_raise ArgumentError, ~r/:opaque conflicts/, fn ->
        plug_opts(self(), route_opaque: "eyJhIjoiMSJ9", opaque: "eyJhIjoiMiJ9")
      end
    end

    test "a credential bound to one route digest does not match another" do
      first = plug_opts(self(), extensions: @extensions, route_digest: MPP.BodyDigest.compute("body-a"))
      second = plug_opts(self(), extensions: @extensions, route_digest: MPP.BodyDigest.compute("body-b"))
      payload = signed_payload(first)
      {:ok, header} = Headers.encode_payment_signature(payload)

      conn =
        :get
        |> Plug.Test.conn(@url, "body-b")
        |> Plug.Conn.put_req_header("payment-signature", header)
        |> PaymentPlug.call(second)

      assert conn.status == 402
      assert problem_detail(conn) =~ "extension_mismatch"
      refute_received {:verify, _payload, _requirements}
    end

    test "a credential bound to one route opaque does not match another" do
      first = plug_opts(self(), route_opaque: "eyJvcmRlciI6IjEifQ")
      second = plug_opts(self(), route_opaque: "eyJvcmRlciI6IjIifQ")
      payload = signed_payload(first)

      conn = settle(second, payload)

      assert conn.status == 402
      assert problem_detail(conn) =~ "extension_mismatch"
      refute_received {:verify, _payload, _requirements}
    end

    test "a route-bound credential for another resource is rejected" do
      opts = plug_opts(self(), extensions: @extensions)
      payload = signed_payload(opts)
      moved = put_in(payload, ["resource", "url"], "http://example.com/other")

      conn = settle(opts, moved)

      assert conn.status == 402
      assert problem_detail(conn) =~ "resource_mismatch"
      refute_received {:verify, _payload, _requirements}
    end
  end

  describe "replay" do
    test "a settled nonce cannot be settled twice through the plug replay store" do
      store = start_replay_store!()
      opts = plug_opts(self(), store: store)
      payload = signed_payload(opts)

      assert settle(opts, payload).status == 200
      assert_received {:settle, _payload, _requirements}

      replayed = settle(opts, payload)

      assert replayed.status == 402
      assert problem_detail(replayed) =~ "already been settled"
      refute_received {:settle, _payload, _requirements}
    end
  end

  test "configuration rejects invalid accepts and binding modes" do
    assert X402.Plug.configure(false) == nil

    for overrides <- [[accepts: []], [accepts: [%{}]], [route_binding: :other]] do
      assert_raise ArgumentError, fn ->
        X402.Plug.configure(Keyword.merge([facilitator: facilitator(self()), accepts: [@accept]], overrides))
      end
    end
  end

  test "verification and settlement failures stop the pipeline and retain the replay claim" do
    for {stage, response, expected} <- [
          {:verify, {:ok, %{"isValid" => false}}, "verify_failed"},
          {:verify, {:ok, %{"isValid" => false, "invalidMessage" => "declined"}}, "declined"},
          {:settle, {:ok, %{"success" => false, "network" => "eip155:84532", "transaction" => ""}}, "settle_failed"},
          {:settle, {:error, Errors.new(:verification_failed, "custom failure")}, "custom failure"}
        ] do
      opts = plug_opts(self(), store: start_replay_store!())
      payload = signed_payload(opts)
      client = Map.put(opts.x402.facilitator, stage, fn _, _ -> response end)
      opts = %{opts | x402: %{opts.x402 | facilitator: client}}
      failed = settle(opts, payload)
      assert failed.status == 402
      assert problem_detail(failed) =~ expected
      assert Plug.Conn.get_resp_header(failed, "payment-response") == []
      assert problem_detail(settle(opts, payload)) =~ "already been settled"
      refute_received {:settle, _, _}
    end
  end

  test "raw and typed-internal facilitator errors return the generic internal error and log the term" do
    cases =
      for stage <- [:verify, :settle],
          {response, term} <- [
            {{:error, {:transport, :facilitator_db_offline_7f3a}}, "facilitator_db_offline_7f3a"},
            {{:error, {:facilitator_http, 503, %{"trace" => "pg-replica-9c1d"}}}, "pg-replica-9c1d"},
            {{:error, "private-db-marker"}, "private-db-marker"},
            {{:error, :private_db_marker}, "private_db_marker"},
            {{:error, Errors.new(:internal_payment_error, "typed-db-marker")}, "typed-db-marker"}
          ],
          do: {stage, response, term}

    for {stage, response, term} <- cases do
      opts = plug_opts(self(), store: start_replay_store!())
      payload = signed_payload(opts)
      client = Map.put(opts.x402.facilitator, stage, fn _, _ -> response end)
      opts = %{opts | x402: %{opts.x402 | facilitator: client}}

      {failed, log} = ExUnit.CaptureLog.with_log(fn -> settle(opts, payload) end)

      assert failed.status == 500
      assert problem_detail(failed) == MPP.Methods.Shared.internal_payment_error().detail
      refute problem_detail(failed) =~ term
      assert log =~ term
      assert Plug.Conn.get_resp_header(failed, "payment-response") == []
    end
  end

  test "rejects native and altered extension nonces before verification" do
    opts = plug_opts(self())
    payload = opts |> signed_payload() |> Map.delete("extensions")
    native = Authorization.challenge_hash("x402:0", "example.com")
    assert problem_detail(settle(opts, put_in(payload, ["payload", "authorization", "nonce"], native))) =~ "native_nonce"

    bound_opts = plug_opts(self(), extensions: @extensions)
    bound = signed_payload(bound_opts)
    altered = put_in(bound, ["payload", "authorization", "nonce"], X402.Nonce.random())
    assert problem_detail(settle(bound_opts, altered)) =~ "nonce_mismatch"
    refute_received {:verify, _, _}
  end

  describe "digest binding" do
    setup do
      opts = plug_opts(self(), digest: MPP.BodyDigest.compute("expected"))
      {:ok, header} = opts |> signed_payload() |> Headers.encode_payment_signature()
      %{opts: opts, header: header}
    end

    defp digest_conn(header, method, req_headers, raw_body, protocol \\ :"HTTP/1.1") do
      conn =
        method
        |> Plug.Test.conn(@url)
        |> Plug.Test.put_http_protocol(protocol)
        |> Plug.Conn.put_req_header("payment-signature", header)

      conn = Enum.reduce(req_headers, conn, fn {k, v}, acc -> Plug.Conn.put_req_header(acc, k, v) end)
      if raw_body, do: Plug.Conn.put_private(conn, :raw_body, raw_body), else: conn
    end

    test "accepts the cached body the digest pins", %{opts: opts, header: header} do
      conn = digest_conn(header, :get, [{"content-length", "8"}], "expected")
      assert {:ok, _} = X402.Plug.maybe_settle(conn, opts.x402, nil)
    end

    test "skips binding only for a request without a body", %{opts: opts, header: header} do
      for raw_body <- [nil, ""] do
        assert {:ok, _} = X402.Plug.maybe_settle(digest_conn(header, :get, [], raw_body), opts.x402, nil)
      end
    end

    test "checks an empty body against the digest", %{opts: opts, header: header} do
      for raw_body <- [nil, ""] do
        conn = digest_conn(header, :get, [{"content-length", "0"}], raw_body)
        assert {:error, error} = X402.Plug.maybe_settle(conn, opts.x402, nil)
        assert error.detail =~ "body_digest_mismatch"
      end
    end

    test "rejects a cached body that does not match", %{opts: opts, header: header} do
      conn = digest_conn(header, :get, [{"content-length", "5"}], "wrong")
      assert {:error, error} = X402.Plug.maybe_settle(conn, opts.x402, nil)
      assert error.detail =~ "body_digest_mismatch"
    end

    test "fails closed when the body was not cached", %{opts: opts, header: header} do
      for {headers, protocol} <- [
            {[{"content-length", "8"}], :"HTTP/1.1"},
            {[{"transfer-encoding", "chunked"}], :"HTTP/1.1"},
            {[], :"HTTP/2"}
          ] do
        conn = digest_conn(header, :get, headers, nil, protocol)
        assert {:error, error} = X402.Plug.maybe_settle(conn, opts.x402, nil)
        assert error.detail =~ "body_digest_unavailable"
      end

      refute_received {:verify, _, _}
    end

    test "binds the route resource alongside the digest", %{opts: opts} do
      moved = put_in(signed_payload(opts), ["resource", "url"], @url <> "/other")
      assert problem_detail(settle(opts, moved)) =~ "resource_mismatch"
    end
  end

  test "resource defaults to request URL and settlement response is limited to successful HTTP responses" do
    opts = plug_opts(self())
    opts = %{opts | x402: %{opts.x402 | resource: nil}}
    payload = opts |> signed_payload() |> Map.drop(["resource", "extensions"])
    {:ok, header} = Headers.encode_payment_signature(payload)
    conn = :get |> Plug.Test.conn(@url) |> Plug.Conn.put_req_header("payment-signature", header)
    assert {:ok, conn} = X402.Plug.maybe_settle(conn, opts.x402, nil)
    conn = Plug.Conn.send_resp(conn, 500, "application failure")
    assert Plug.Conn.get_resp_header(conn, "payment-response") == []
  end

  test "disabled configuration leaves the connection unchanged" do
    conn = Plug.Test.conn(:get, @url)
    assert X402.Plug.configure(nil) == nil
    assert X402.Plug.maybe_settle(conn, nil, nil) == :continue
    assert X402.Plug.put_challenge(conn, nil) == conn
  end

  test "unencodable challenge and settlement metadata do not emit invalid headers" do
    opts = plug_opts(self())
    conn = Plug.Test.conn(:get, @url)
    invalid = %{opts.x402 | extensions: %{"bad" => <<255>>}}
    assert X402.Plug.put_challenge(conn, invalid) == conn

    payload = signed_payload(opts)

    client =
      Map.put(opts.x402.facilitator, :settle, fn _, _ ->
        {:ok, %{"success" => true, "network" => "eip155:84532", "transaction" => "tx", "extra" => %{"bad" => <<255>>}}}
      end)

    conn = settle(%{opts | x402: %{opts.x402 | facilitator: client}}, payload)
    assert conn.status == 200
    assert conn.assigns.x402_settlement["success"]
    assert Plug.Conn.get_resp_header(conn, "payment-response") == []
  end

  test "additional extension info and scalar values must match" do
    extensions = Map.merge(@extensions, %{"other" => %{"info" => %{"label" => "value"}}, "scalar" => "value"})
    opts = plug_opts(self(), extensions: extensions)
    payload = signed_payload(opts)
    assert settle(opts, payload).status == 200

    tampered = put_in(payload, ["extensions", "scalar"], "other")
    assert problem_detail(settle(opts, tampered)) =~ "extension_mismatch"
  end

  test "malformed addresses cannot match a configured accept" do
    opts = plug_opts(self())
    payload = signed_payload(opts)
    tampered = put_in(payload, ["accepted", "asset"], "invalid")
    assert problem_detail(settle(opts, tampered)) =~ "requirements_mismatch"
    refute_received {:verify, _, _}
  end

  test "relative resource URLs use the fallback realm when rejecting native nonces" do
    opts = plug_opts(self())
    payload = opts |> signed_payload() |> Map.delete("extensions")
    opts = %{opts | x402: %{opts.x402 | resource: %{"url" => "/relative"}}}
    payload = put_in(payload, ["resource", "url"], "/relative")
    native = Authorization.challenge_hash("x402:0", "x402")
    payload = put_in(payload, ["payload", "authorization", "nonce"], native)
    assert problem_detail(settle(opts, payload)) =~ "native_nonce"
    refute_received {:verify, _, _}
  end

  defp signed_payload(opts) do
    unpaid = :get |> Plug.Test.conn(@url) |> PaymentPlug.call(opts)
    assert unpaid.status == 402
    [required] = Plug.Conn.get_resp_header(unpaid, "payment-required")
    assert {:ok, [challenge]} = X402.challenges_from_header(required)
    assert {:ok, payload} = Exact.sign(challenge, @config)
    payload
  end

  defp settle(opts, payload) do
    {:ok, header} = Headers.encode_payment_signature(payload)

    conn =
      :get
      |> Plug.Test.conn(@url)
      |> Plug.Conn.put_req_header("payment-signature", header)
      |> PaymentPlug.call(opts)

    if conn.halted, do: conn, else: Plug.Conn.send_resp(conn, 200, "ok")
  end

  defp server_accept(%PaymentPlug.Config{x402: %{accepts: [accept]}}), do: accept

  defp problem_detail(conn) do
    case Jason.decode!(conn.resp_body) do
      %{"detail" => detail} -> detail
      _other -> ""
    end
  end

  defp start_replay_store! do
    cache_name = :"#{__MODULE__}.#{System.unique_integer([:positive])}"
    start_supervised!({ConCacheStore, name: cache_name})
    {ConCacheStore, name: cache_name}
  end

  defp plug_opts(parent, overrides \\ []) do
    x402 =
      [facilitator: facilitator(parent), accepts: [@accept], resource: %{"url" => @url}] ++
        Keyword.take(overrides, [:extensions, :route_binding, :digest, :opaque])

    PaymentPlug.init(
      secret_key: "x402-plug-secret-xxxxxxxxxxxxxxx",
      realm: "example.com",
      method: MockMethod,
      amount: "1000",
      currency: "usd",
      digest: Keyword.get(overrides, :route_digest),
      opaque: Keyword.get(overrides, :route_opaque),
      store: Keyword.get(overrides, :store, false),
      x402: x402
    )
  end

  defp facilitator(parent) do
    %{
      verify: fn payload, requirements ->
        send(parent, {:verify, payload, requirements})
        {:ok, %{"isValid" => true, "payer" => get_in(payload, ["payload", "authorization", "from"])}}
      end,
      settle: fn payload, requirements ->
        send(parent, {:settle, payload, requirements})

        {:ok,
         %{
           "success" => true,
           "transaction" => "0x" <> String.duplicate("ab", 32),
           "network" => requirements["network"],
           "payer" => get_in(payload, ["payload", "authorization", "from"])
         }}
      end
    }
  end
end
