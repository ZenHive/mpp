defmodule MPP.Client.AcceptPolicy do
  @moduledoc """
  Gates `Accept-Payment` header injection on outgoing HTTP requests.

  Without a gate, a global payment middleware advertises supported payment
  methods on every cross-origin request, which can break CORS preflight and
  leak wallet capabilities.

  Defaults to `:always` for backwards compatibility (matches mpp-rs
  `AcceptPaymentPolicy::Always`).
  """

  use Descripex, namespace: "/client"

  @type t ::
          :always
          | :never
          | {:same_origin, String.t()}
          | {:origins, [String.t()]}

  api(:allows?, "Return true if `Accept-Payment` injection is permitted for `url`.",
    params: [
      policy: [kind: :value, description: "AcceptPolicy value"],
      url: [kind: :value, description: "Request URL string or `%URI{}`"]
    ],
    returns: %{type: :boolean, description: "true when the header may be sent"}
  )

  @doc """
  Return `true` if `Accept-Payment` header injection is permitted for `url`.
  """
  @spec allows?(t(), String.t() | URI.t()) :: boolean()
  def allows?(:always, _url), do: true
  def allows?(:never, _url), do: false

  def allows?({:same_origin, same_origin}, url) do
    with {:ok, origin} <- parse_origin(same_origin),
         {:ok, request_origin} <- origin_from_url(url) do
      origin == request_origin
    else
      _ -> false
    end
  end

  def allows?({:origins, patterns}, url) when is_list(patterns) do
    uri = normalize_uri(url)
    Enum.any?(patterns, &matches_origin_pattern?(uri, &1))
  end

  api(:default, "Return the default policy (`:always`).", returns: %{type: :atom, description: "`:always`"})

  @doc "Return the default policy (`:always`)."
  @spec default() :: t()
  def default, do: :always

  defp normalize_uri(%URI{} = uri), do: uri

  defp normalize_uri(url) when is_binary(url) do
    URI.parse(url)
  end

  defp parse_origin(origin) when is_binary(origin) do
    case URI.parse(origin) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        {:ok, origin_key(uri)}

      _ ->
        :error
    end
  end

  defp origin_from_url(url) do
    case normalize_uri(url) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        {:ok, origin_key(uri)}

      _ ->
        :error
    end
  end

  defp origin_key(%URI{scheme: scheme, host: host, port: port}) do
    default_port? =
      (scheme == "https" and port == 443) or
        (scheme == "http" and port == 80) or port == nil

    host = String.downcase(host)

    if default_port? do
      "#{scheme}://#{host}"
    else
      "#{scheme}://#{host}:#{port}"
    end
  end

  defp matches_origin_pattern?(%URI{} = uri, pattern) do
    if String.starts_with?(pattern, "*.") do
      match_wildcard_host?(uri, String.slice(pattern, 2..-1//1))
    else
      case parse_origin(pattern) do
        {:ok, pattern_origin} ->
          case origin_from_url(uri) do
            {:ok, request_origin} -> pattern_origin == request_origin
            _ -> false
          end

        :error ->
          false
      end
    end
  end

  defp match_wildcard_host?(%URI{host: host}, suffix) when is_binary(host) do
    host = String.downcase(host)
    suffix = String.downcase(suffix)
    host == suffix or String.ends_with?(host, "." <> suffix)
  end

  defp match_wildcard_host?(_, _), do: false
end
