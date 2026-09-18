defmodule MPP.X402.Facilitator do
  @moduledoc """
  Configurable x402 facilitator client (`POST /verify` and `POST /settle`).

  A facilitator is either an HTTP base URL or an in-process map of functions.
  Requests disable retries so observed error bodies are not swallowed.
  """

  alias MPP.X402.Headers

  @type t :: %{
          verify: (map(), map() -> {:ok, map()} | {:error, term()}),
          settle: (map(), map() -> {:ok, map()} | {:error, term()})
        }

  @doc "Resolve a URL, function map, or existing client into a facilitator client."
  @spec resolve(String.t() | t(), keyword()) :: t()
  def resolve(facilitator, opts \\ [])

  def resolve(%{verify: verify, settle: settle} = facilitator, _opts)
      when is_function(verify, 2) and is_function(settle, 2) do
    facilitator
  end

  def resolve(url, opts) when is_binary(url) and url != "" do
    http(url, opts)
  end

  def resolve(_other, _opts) do
    raise ArgumentError, "x402 facilitator must be a URL or %{verify: fun, settle: fun}"
  end

  @doc "Build an HTTP facilitator client from a base URL."
  @spec http(String.t(), keyword()) :: t()
  def http(url, opts \\ []) when is_binary(url) do
    base = String.trim_trailing(url, "/")
    req_options = Keyword.get(opts, :req_options, [])

    %{
      verify: fn payload, requirements -> post(base, "verify", payload, requirements, req_options) end,
      settle: fn payload, requirements -> post(base, "settle", payload, requirements, req_options) end
    }
  end

  @doc "Verify a payment payload against requirements."
  @spec verify(t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def verify(%{verify: verify}, payload, requirements) when is_function(verify, 2) do
    with {:ok, body} <- verify.(payload, requirements) do
      Headers.parse_verify_response(body)
    end
  end

  @doc "Settle a verified payment payload."
  @spec settle(t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def settle(%{settle: settle}, payload, requirements) when is_function(settle, 2) do
    with {:ok, body} <- settle.(payload, requirements) do
      Headers.parse_settle_response(body)
    end
  end

  defp post(base, action, payload, requirements, req_options) do
    body = %{
      "x402Version" => 2,
      "paymentPayload" => payload,
      "paymentRequirements" => requirements
    }

    case Req.post(base <> "/" <> action, Keyword.merge([json: body, retry: false], req_options)) do
      {:ok, %{status: status, body: response}} when status in 200..299 and is_map(response) ->
        {:ok, response}

      {:ok, %{status: status, body: body}} ->
        {:error, {:facilitator_http, status, body}}

      {:error, reason} ->
        {:error, {:facilitator_request, reason}}
    end
  end
end
