defmodule MPP.Demo.Router do
  @moduledoc """
  Demo router for `mix mpp.demo` — serves a protected endpoint behind MPP.

  Routes:

    * `GET /` — welcome page with JSON instructions
    * `GET /resource` — protected endpoint (402 without payment, 200 with valid credential)
    * `GET /health` — unprotected healthcheck
  """

  use Plug.Router

  alias MPP.Demo.Method, as: DemoMethod

  @secret_key "mpp-demo-secret-key"
  @realm "localhost"
  @amount "100"
  @currency "usd"

  plug(:match)
  plug(:dispatch)

  # Pre-compute MPP.Plug config at compile time
  @mpp_config MPP.Plug.init(
                secret_key: @secret_key,
                realm: @realm,
                method: DemoMethod,
                amount: @amount,
                currency: @currency
              )

  get "/" do
    body =
      Jason.encode!(%{
        "name" => "MPP Demo Server",
        "description" => "Machine Payments Protocol demo — try the 402 flow",
        "endpoints" => %{
          "/resource" => "Protected endpoint (GET) — returns 402 without payment",
          "/health" => "Health check (GET)"
        },
        "hint" => "Run `mix mpp.demo` again to see curl commands"
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  get "/resource" do
    # Run MPP.Plug — returns 402 or passes through with receipt in assigns
    conn = MPP.Plug.call(conn, @mpp_config)

    if conn.halted do
      conn
    else
      receipt = conn.assigns[:mpp_receipt]

      body =
        Jason.encode!(%{
          "message" => "You paid! Here's your resource.",
          "payment" => %{
            "method" => receipt.method,
            "reference" => receipt.reference,
            "timestamp" => receipt.timestamp
          }
        })

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    end
  end

  get "/health" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{"status" => "ok"}))
  end

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{"error" => "not found"}))
  end

  # --- Accessors for the Mix task to pre-compute credentials ---

  @doc false
  @spec secret_key() :: String.t()
  def secret_key, do: @secret_key

  @doc false
  @spec realm() :: String.t()
  def realm, do: @realm

  @doc false
  @spec mpp_config() :: MPP.Plug.Config.t()
  def mpp_config, do: @mpp_config
end
