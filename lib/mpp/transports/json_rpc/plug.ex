defmodule MPP.Transports.JsonRpc.Plug do
  @moduledoc """
  Plug adapter for the bare JSON-RPC payment transport.

  Mount on a POST route (or `forward`) with the same endpoint options as
  `MPP.Plug`, plus a `:handler` that receives the verified JSON-RPC request
  map and returns a result or JSON-RPC response:

      forward "/rpc",
        to: MPP.Transports.JsonRpc.Plug,
        init_opts: [
          handler: &MyApp.Rpc.dispatch/1,
          secret_key: secret,
          realm: "rpc.example.com",
          method: MyMethod,
          amount: "1000",
          currency: "usd"
        ]

  Payment-required and verification failures are JSON-RPC errors (`-32042` /
  `-32602` / `-32043`) on HTTP 200, matching JSON-RPC-over-HTTP convention
  and the MPP transport spec's `error.data.httpStatus: 402` field. Payment-gated
  notifications (JSON-RPC requests with no `id`) are dropped with HTTP 204.
  """

  @behaviour Plug

  alias MPP.Transports.JsonRpc

  @parse_error_code -32_700
  @invalid_request_code -32_600

  @type state :: %{config: MPP.Plug.Config.t(), handler: (map() -> term())}

  @impl Plug
  @spec init(keyword()) :: state()
  def init(opts) when is_list(opts) do
    {handler, plug_opts} = Keyword.pop(opts, :handler)

    if !is_function(handler, 1) do
      raise ArgumentError, "MPP.Transports.JsonRpc.Plug requires :handler (arity-1 function)"
    end

    %{config: JsonRpc.init(plug_opts), handler: handler}
  end

  @impl Plug
  @spec call(Plug.Conn.t(), state()) :: Plug.Conn.t()
  def call(%Plug.Conn{} = conn, %{config: config, handler: handler}) do
    case read_json_rpc(conn) do
      {:ok, conn, request} when is_map(request) ->
        cond do
          notification?(request) ->
            conn
            |> Plug.Conn.send_resp(204, "")
            |> Plug.Conn.halt()

          json_rpc_request?(request) ->
            request
            |> JsonRpc.call(config, handler)
            |> then(&send_json(conn, 200, &1))

          true ->
            send_json(conn, 200, rpc_error(Map.get(request, "id"), @invalid_request_code, "Invalid Request"))
        end

      {:ok, conn, _other} ->
        send_json(conn, 200, rpc_error(nil, @invalid_request_code, "Invalid Request"))

      {:error, conn, :parse} ->
        send_json(conn, 200, rpc_error(nil, @parse_error_code, "Parse error"))
    end
  end

  defp read_json_rpc(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}} = conn), do: read_raw_body(conn)

  defp read_json_rpc(%Plug.Conn{body_params: params} = conn) when is_map(params) and map_size(params) > 0 do
    {:ok, conn, params}
  end

  defp read_json_rpc(conn), do: read_raw_body(conn)

  defp read_raw_body(conn) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, conn} when is_binary(body) and body != "" ->
        case Jason.decode(body) do
          {:ok, decoded} -> {:ok, conn, decoded}
          {:error, _} -> {:error, conn, :parse}
        end

      _other ->
        {:error, conn, :parse}
    end
  end

  defp notification?(request) when is_map(request) do
    json_rpc_request?(request) and not Map.has_key?(request, "id")
  end

  defp json_rpc_request?(request) when is_map(request) do
    request["jsonrpc"] == "2.0" and is_binary(request["method"])
  end

  defp rpc_error(id, code, message) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    }
  end

  defp send_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.put_resp_header("cache-control", "private, no-store")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
    |> Plug.Conn.halt()
  end
end
