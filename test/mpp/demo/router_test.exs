defmodule MPP.Demo.RouterTest do
  use ExUnit.Case, async: true

  alias MPP.Challenge
  alias MPP.Credential
  alias MPP.Demo.Router
  alias MPP.Headers

  @opts Router.init([])

  defp call(conn) do
    Router.call(conn, @opts)
  end

  describe "GET /" do
    test "returns 200 with API info" do
      conn =
        :get
        |> Plug.Test.conn("/")
        |> call()

      assert conn.status == 200
      assert get_content_type(conn) =~ "application/json"

      body = Jason.decode!(conn.resp_body)
      assert body["name"] == "MPP Demo Server"
      assert is_map(body["endpoints"])
    end
  end

  describe "GET /resource" do
    test "returns 402 without Authorization header" do
      conn =
        :get
        |> Plug.Test.conn("/resource")
        |> call()

      assert conn.status == 402
      assert get_content_type(conn) =~ "application/problem+json"

      # Has WWW-Authenticate challenge header
      [challenge_header] = Plug.Conn.get_resp_header(conn, "www-authenticate")
      assert challenge_header =~ "Payment"
      assert challenge_header =~ "method=\"demo\""
      assert challenge_header =~ "realm=\"localhost\""

      # Body is RFC 9457 error
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == 402
      assert body["type"] =~ "payment-required"
    end

    test "returns 200 with valid credential" do
      conn =
        :get
        |> Plug.Test.conn("/resource")
        |> put_auth_header(valid_credential())
        |> call()

      assert conn.status == 200
      assert get_content_type(conn) =~ "application/json"

      body = Jason.decode!(conn.resp_body)
      assert body["message"] =~ "You paid"
      assert body["payment"]["method"] == "demo"
      assert is_binary(body["payment"]["reference"])

      # Has Payment-Receipt header
      [receipt_header] = Plug.Conn.get_resp_header(conn, "payment-receipt")
      assert {:ok, _receipt} = Headers.parse_receipt(receipt_header)
    end

    test "returns 402 with invalid token" do
      credential = build_credential(%{"token" => "wrong"})

      conn =
        :get
        |> Plug.Test.conn("/resource")
        |> put_auth_header(credential)
        |> call()

      assert conn.status == 402

      body = Jason.decode!(conn.resp_body)
      assert body["type"] =~ "verification-failed"
    end

    test "returns 402 with missing payload fields" do
      credential = build_credential(%{"garbage" => true})

      conn =
        :get
        |> Plug.Test.conn("/resource")
        |> put_auth_header(credential)
        |> call()

      assert conn.status == 402

      body = Jason.decode!(conn.resp_body)
      assert body["type"] =~ "invalid-payload"
    end
  end

  describe "GET /health" do
    test "returns 200 ok" do
      conn =
        :get
        |> Plug.Test.conn("/health")
        |> call()

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{"status" => "ok"}
    end
  end

  describe "unknown routes" do
    test "returns 404" do
      conn =
        :get
        |> Plug.Test.conn("/nonexistent")
        |> call()

      assert conn.status == 404
    end
  end

  # --- Helpers ---

  defp valid_credential do
    build_credential(%{"token" => "demo-token"})
  end

  defp build_credential(payload) do
    config = Router.mpp_config()
    entry = hd(config.method_entries)

    challenge =
      Challenge.create(
        [
          realm: config.realm,
          method: entry.method.method_name(),
          intent: "charge",
          request: entry.request
        ],
        config.secret_key
      )

    Headers.format_credential(%Credential{challenge: challenge, payload: payload})
  end

  defp put_auth_header(conn, header_value) do
    Plug.Conn.put_req_header(conn, "authorization", header_value)
  end

  defp get_content_type(conn) do
    conn
    |> Plug.Conn.get_resp_header("content-type")
    |> List.first("")
  end
end
