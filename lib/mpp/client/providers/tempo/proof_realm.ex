defmodule MPP.Client.Providers.Tempo.ProofRealm do
  @moduledoc false

  # Decides whether a zero-amount Tempo proof may be signed for a challenge
  # realm. Matching follows refs/mppx/src/client/internal/ProofRealm.ts and
  # refs/mpp-rs/src/client/flow.rs `is_cross_realm_proof_with_trust`:
  #
  #   * the realm equals the request hostname (ASCII case-insensitive, port
  #     ignored), or
  #   * a pin maps the request origin (scheme, host, port; default ports
  #     elided) to exactly that realm.
  #
  # Without a request URL only realms listed bare (not origin-pinned) count.

  @http_schemes ~w(http https)
  @request_schemes %{"http" => "http", "https" => "https", "ws" => "http", "wss" => "https"}

  @type origin :: {String.t(), String.t(), non_neg_integer()}
  @type pin :: {:origin, origin(), String.t()} | {:realm, String.t()}

  @doc "Normalize `:trusted_tempo_proof_realms` (map, `{origin, realm}` tuples, bare realms)."
  @spec normalize_pins(term()) :: {:ok, [pin()]} | :error
  def normalize_pins(nil), do: {:ok, []}
  def normalize_pins(pins) when is_map(pins), do: pins |> Map.to_list() |> normalize_pins()
  def normalize_pins(pins) when is_list(pins), do: normalize_pins(pins, [])
  def normalize_pins(_pins), do: :error

  defp normalize_pins([], acc), do: {:ok, Enum.reverse(acc)}

  defp normalize_pins([realm | rest], acc) when is_binary(realm), do: normalize_pins(rest, [{:realm, realm} | acc])

  defp normalize_pins([{origin, realm} | rest], acc) when is_binary(realm) do
    case pin_origin(origin) do
      {:ok, origin} -> normalize_pins(rest, [{:origin, origin, realm} | acc])
      :error -> :error
    end
  end

  defp normalize_pins(_pins, _acc), do: :error

  @doc "Return `:ok` when a proof for `realm` may be sent to `url` (`nil` = no origin)."
  @spec check(String.t(), String.t() | URI.t() | nil, [pin()]) :: :ok | {:error, term()}
  def check(realm, nil, pins) do
    if {:realm, realm} in pins, do: :ok, else: {:error, {:untrusted_proof_realm, realm, nil}}
  end

  def check(realm, url, pins) do
    case request_origin(url) do
      {:ok, {_scheme, host, _port} = origin} ->
        cond do
          String.downcase(realm, :ascii) == host -> :ok
          {:origin, origin, realm} in pins -> :ok
          true -> {:error, {:untrusted_proof_realm, realm, format_origin(origin)}}
        end

      :error ->
        {:error, {:invalid_config, :request_url}}
    end
  end

  defp pin_origin(origin) when is_binary(origin) do
    case parse_origin(origin) do
      {:ok, {scheme, _host, _port}} = ok when scheme in @http_schemes -> ok
      _other -> :error
    end
  end

  defp pin_origin(_origin), do: :error

  # WebSocket URLs are compared as their HTTP origin, matching mpp-rs
  # `proof_http_origin` (crates/alloy-transport-mpp/src/ws.rs).
  defp request_origin(url) do
    with {:ok, {scheme, host, port}} <- parse_origin(url),
         {:ok, http_scheme} <- Map.fetch(@request_schemes, scheme) do
      {:ok, {http_scheme, host, port}}
    end
  end

  defp parse_origin(%URI{scheme: scheme, host: host, port: port})
       when is_binary(scheme) and is_binary(host) and host != "" and is_integer(port) do
    {:ok, {String.downcase(scheme, :ascii), String.downcase(host, :ascii), port}}
  end

  defp parse_origin(%URI{}), do: :error

  defp parse_origin(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, uri} -> parse_origin(uri)
      {:error, _part} -> :error
    end
  end

  defp parse_origin(_url), do: :error

  defp format_origin({"http", host, 80}), do: "http://" <> host
  defp format_origin({"https", host, 443}), do: "https://" <> host
  defp format_origin({scheme, host, port}), do: "#{scheme}://#{host}:#{port}"
end
