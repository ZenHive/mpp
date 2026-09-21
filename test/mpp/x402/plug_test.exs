defmodule MPP.X402.PlugTest do
  use ExUnit.Case, async: true

  alias MPP.Errors
  alias MPP.Method
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

    test "dropping the mppx extension falls back to the unbound contract under :resource" do
      # Without `extensions.mppx` the credential is a plain x402 exact payment
      # (mppx `isRouteBound` false); `:resource` binding only checks the URL.
      opts = plug_opts(self(), extensions: @extensions)
      payload = signed_payload(opts)
      unbound = Map.delete(payload, "extensions")

      conn = settle(opts, unbound)

      assert conn.status == 200
      assert_received {:verify, _payload, _requirements}
    end

    test "dropping the mppx extension is rejected under :required" do
      opts = plug_opts(self(), extensions: @extensions, route_binding: :required)
      payload = signed_payload(opts)
      unbound = Map.delete(payload, "extensions")

      conn = settle(opts, unbound)

      assert conn.status == 402
      assert problem_detail(conn) =~ "route_binding_required"
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

  defp signed_payload(opts) do
    unpaid = :get |> Plug.Test.conn(@url) |> PaymentPlug.call(opts)
    assert unpaid.status == 402
    [required] = Plug.Conn.get_resp_header(unpaid, "payment-required")
    assert {:ok, [challenge]} = X402.challenges_from_header(required, @url)
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
        Keyword.take(overrides, [:extensions, :route_binding])

    PaymentPlug.init(
      secret_key: "x402-plug-secret",
      realm: "example.com",
      method: MockMethod,
      amount: "1000",
      currency: "usd",
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
