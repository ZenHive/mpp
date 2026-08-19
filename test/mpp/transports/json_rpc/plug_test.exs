defmodule MPP.Transports.JsonRpc.PlugTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias MPP.Client.Transport.JsonRpc, as: ClientTransport
  alias MPP.Credential
  alias MPP.Demo.Method, as: DemoMethod
  alias MPP.Transports.JsonRpc
  alias MPP.Transports.JsonRpc.Plug, as: RpcPlug

  @secret_key "test-secret-key-for-jsonrpc-plug"
  @realm "rpc.example.com"

  defmodule PaidRouter do
    @moduledoc false
    use Plug.Router

    alias DemoMethod, as: DemoMethod
    alias RpcPlug, as: RpcPlug

    plug(:match)
    plug(:dispatch)

    @opts RpcPlug.init(
            handler: &__MODULE__.handle/1,
            secret_key: "test-secret-key-for-jsonrpc-plug",
            realm: "rpc.example.com",
            method: DemoMethod,
            amount: "1000",
            currency: "usd",
            store: false
          )

    post "/rpc" do
      RpcPlug.call(conn, @opts)
    end

    @spec handle(map()) :: map() | String.t()
    def handle(%{"method" => "eth_getBlockByNumber", "params" => ["latest", false]}) do
      %{"number" => "0x1348c9", "hash" => "0x7736fab"}
    end

    def handle(%{"method" => "eth_chainId"}) do
      "0xa61"
    end

    def handle(%{"method" => method}) do
      %{"error" => %{"code" => -32_601, "message" => "Method not found: #{method}"}}
    end
  end

  @router_opts PaidRouter.init([])

  defp post_rpc(body) do
    :post
    |> conn("/rpc", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> PaidRouter.call(@router_opts)
  end

  defp decode(conn) do
    Jason.decode!(conn.resp_body)
  end

  describe "end-to-end Plug/JSON-RPC payment retry" do
    test "payment-required then successful pay-and-retry over the real Plug boundary" do
      unpaid_conn =
        post_rpc(%{"jsonrpc" => "2.0", "id" => 1, "method" => "eth_getBlockByNumber", "params" => ["latest", false]})

      assert unpaid_conn.status == 200
      unpaid = decode(unpaid_conn)

      assert ClientTransport.payment_required?(unpaid)
      assert {:ok, [challenge]} = ClientTransport.get_challenges(unpaid)
      assert challenge.method == "demo"
      assert challenge.realm == @realm

      credential = %Credential{challenge: challenge, payload: %{"token" => "demo-token"}}

      paid_request =
        ClientTransport.set_credential(
          %{"jsonrpc" => "2.0", "id" => 1, "method" => "eth_getBlockByNumber", "params" => ["latest", false]},
          credential
        )

      assert paid_request["params"] == ["latest", false]
      assert paid_request["_meta"][JsonRpc.credential_meta_key()]

      paid_conn = post_rpc(paid_request)
      assert paid_conn.status == 200
      paid = decode(paid_conn)

      refute ClientTransport.payment_required?(paid)
      assert paid["result"] == %{"number" => "0x1348c9", "hash" => "0x7736fab"}
      assert paid["_meta"][JsonRpc.receipt_meta_key()]["status"] == "success"
      assert paid["_meta"][JsonRpc.receipt_meta_key()]["challengeId"] == challenge.id
      refute get_in(paid, ["result", "_meta"])
    end

    test "verification-failed response keeps the JSON-RPC error on HTTP 200" do
      unpaid = decode(post_rpc(%{"jsonrpc" => "2.0", "id" => 2, "method" => "eth_chainId", "params" => []}))
      {:ok, [challenge]} = ClientTransport.get_challenges(unpaid)

      request =
        ClientTransport.set_credential(
          %{"jsonrpc" => "2.0", "id" => 2, "method" => "eth_chainId", "params" => []},
          %Credential{challenge: challenge, payload: %{"token" => "nope"}}
        )

      conn = post_rpc(request)
      body = decode(conn)

      assert conn.status == 200
      assert body["error"]["code"] == -32_043
      assert body["error"]["data"]["httpStatus"] == 402
      assert [_challenge] = body["error"]["data"]["challenges"]
    end
  end

  describe "JSON-RPC protocol errors" do
    test "parse error returns -32700" do
      conn =
        :post
        |> conn("/rpc", "{not-json")
        |> put_req_header("content-type", "application/json")
        |> PaidRouter.call(@router_opts)

      assert conn.status == 200
      body = decode(conn)
      assert body["error"]["code"] == -32_700
      assert body["id"] == nil
    end

    test "empty body is a parse error" do
      conn =
        :post
        |> conn("/rpc", "")
        |> put_req_header("content-type", "application/json")
        |> PaidRouter.call(@router_opts)

      assert decode(conn)["error"]["code"] == -32_700
    end

    test "JSON array body is an invalid request" do
      conn =
        :post
        |> conn("/rpc", "[1, 2]")
        |> put_req_header("content-type", "application/json")
        |> PaidRouter.call(@router_opts)

      assert decode(conn)["error"]["code"] == -32_600
    end

    test "already-parsed body_params maps are accepted" do
      conn =
        :post
        |> conn("/rpc", %{
          "jsonrpc" => "2.0",
          "id" => 9,
          "method" => "eth_chainId",
          "params" => []
        })
        |> PaidRouter.call(@router_opts)

      assert conn.status == 200
      assert decode(conn)["error"]["code"] == -32_042
    end

    test "empty fetched body_params falls through to the raw body" do
      conn =
        :post
        |> conn("/rpc", "")
        |> put_req_header("content-type", "application/json")
        |> Map.put(:body_params, %{})
        |> PaidRouter.call(@router_opts)

      assert decode(conn)["error"]["code"] == -32_700
    end

    test "invalid request returns -32600" do
      conn = post_rpc(%{"jsonrpc" => "2.0", "id" => 1})
      assert decode(conn)["error"]["code"] == -32_600
    end

    test "payment-gated notifications are dropped with 204" do
      conn = post_rpc(%{"jsonrpc" => "2.0", "method" => "eth_getBlockByNumber", "params" => ["latest", false]})
      assert conn.status == 204
      assert conn.resp_body == ""
    end
  end

  test "init/1 requires a handler function" do
    assert_raise ArgumentError, ~r/:handler/, fn ->
      RpcPlug.init(secret_key: @secret_key, realm: @realm, method: DemoMethod, amount: "1", currency: "usd")
    end
  end
end
