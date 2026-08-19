defmodule MPP.Methods.NearIntents.OneClick do
  @moduledoc false

  @type config :: map()
  @type reason :: :unavailable | {:rejected, non_neg_integer(), term()}

  @doc false
  @spec quote(config(), map()) :: {:ok, map()} | {:error, reason()}
  def quote(config, body), do: request(config, :post, "/v0/quote", json: body)

  @doc false
  @spec submit_deposit(config(), String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, reason()}
  def submit_deposit(config, hash, deposit_address, deposit_memo) do
    body = maybe_put(%{"txHash" => hash, "depositAddress" => deposit_address}, "memo", deposit_memo)

    request(config, :post, "/v0/deposit/submit", json: body)
  end

  @doc false
  @spec status(config(), String.t(), String.t() | nil) :: {:ok, map()} | {:error, reason()}
  def status(config, deposit_address, deposit_memo) do
    params = maybe_put(%{"depositAddress" => deposit_address}, "depositMemo", deposit_memo)

    request(config, :get, "/v0/status", params: params)
  end

  defp request(config, method, path, request_opts) do
    base_url = config["one_click_url"] || "https://1click.chaindefuser.com"
    req_options = config["one_click_req_options"] || []

    options =
      Keyword.merge(
        [method: method, url: String.trim_trailing(base_url, "/") <> path, headers: headers(config)],
        request_opts
      )

    case Req.request(options, req_options) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %Req.Response{status: status}} when status >= 500 -> {:error, :unavailable}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:rejected, status, body}}
      {:error, _exception} -> {:error, :unavailable}
    end
  end

  defp headers(config) do
    maybe_prepend_authorization([{"accept", "application/json"}], config["one_click_jwt"])
  end

  defp maybe_prepend_authorization(headers, nil), do: headers
  defp maybe_prepend_authorization(headers, jwt), do: [{"authorization", "Bearer #{jwt}"} | headers]

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
