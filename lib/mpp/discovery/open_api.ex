defmodule MPP.Discovery.OpenApi do
  @moduledoc """
  Generates OpenAPI 3.1.0 discovery documents for MPP-enabled HTTP operations.

  The input is a keyword list or map containing `:info`, `:routes`, and optional
  `:service_info`. Routes with payment metadata emit `x-payment-info` and a 402
  response; routes with `payment: nil` or no `:payment` key are unpaid and omit
  both. Payment metadata may use either discovery form, but generated documents
  always contain the recommended multi-offer `offers` array on payable operations.

      MPP.Discovery.OpenApi.generate(
        info: %{title: "Example API", version: "1.0.0"},
        service_info: %{
          "categories" => ["compute"],
          "docs" => %{"homepage" => "https://example.com"}
        },
        routes: [
          [method: :get, path: "/health"],
          [
            method: :post,
            path: "/v1/search",
            summary: "Search documents",
            payment: %{
              "intent" => "charge",
              "method" => "tempo",
              "amount" => "100",
              "currency" => "usd"
            }
          ]
        ]
      )

  Invalid generation config raises `ArgumentError` so malformed discovery
  documents fail at build time rather than being published.
  """

  use Descripex, namespace: "/discovery"

  alias MPP.Discovery.PaymentInfo

  @http_methods ~w(delete get head options patch post put trace)
  @openapi_version "3.1.0"

  api(
    :generate,
    "Generate an OpenAPI 3.1.0 document with MPP discovery extensions.",
    params: [
      config: [
        kind: :value,
        description: "Keyword list or map with `info`, non-empty `routes`, and optional `service_info`"
      ]
    ],
    returns: %{type: :map, description: "JSON-compatible OpenAPI 3.1.0 document"}
  )

  @spec generate(keyword() | map()) :: map()
  def generate(config) when is_list(config) or is_map(config) do
    info = config |> fetch_required!(:info) |> normalize_info!()
    routes = fetch_required!(config, :routes)
    paths = build_paths!(routes)

    put_service_info(
      %{"openapi" => @openapi_version, "info" => info, "paths" => paths},
      config_value(config, :service_info)
    )
  end

  def generate(_config), do: raise(ArgumentError, "OpenAPI config must be a keyword list or map")

  defp build_paths!(routes) when is_list(routes) and routes != [] do
    Enum.reduce(routes, %{}, fn route, paths ->
      {path, method, operation} = normalize_route!(route)
      path_item = Map.get(paths, path, %{})

      if Map.has_key?(path_item, method) do
        raise ArgumentError, "duplicate OpenAPI route: #{String.upcase(method)} #{path}"
      end

      Map.put(paths, path, Map.put(path_item, method, operation))
    end)
  end

  defp build_paths!(_routes), do: raise(ArgumentError, "OpenAPI routes must be a non-empty list")

  defp normalize_route!(route) when is_list(route) or is_map(route) do
    path = route |> fetch_required!(:path) |> validate_path!()
    method = route |> fetch_required!(:method) |> normalize_method!()

    operation =
      %{"responses" => %{"200" => %{"description" => "Successful response"}}}
      |> put_payment_extension(config_value(route, :payment))
      |> put_optional_string("summary", config_value(route, :summary))
      |> put_request_body(config_value(route, :request_body))

    {path, method, operation}
  end

  defp normalize_route!(_route), do: raise(ArgumentError, "each OpenAPI route must be a keyword list or map")

  defp normalize_info!(info) when is_list(info) or is_map(info) do
    %{
      "title" => info |> fetch_required!(:title) |> require_string!("info.title"),
      "version" => info |> fetch_required!(:version) |> require_string!("info.version")
    }
  end

  defp normalize_info!(_info), do: raise(ArgumentError, "OpenAPI info must be a keyword list or map")

  defp put_payment_extension(operation, nil), do: operation

  defp put_payment_extension(operation, payment) do
    payment_info =
      payment
      |> mapish!("x-payment-info")
      |> parse_payment_info!()

    operation
    |> put_in(["responses", "402"], %{"description" => "Payment Required"})
    |> Map.put("x-payment-info", payment_info)
  end

  defp parse_payment_info!(payment_info) do
    case PaymentInfo.parse(payment_info) do
      {:ok, normalized} -> normalized
      {:error, reason} -> raise ArgumentError, "invalid x-payment-info: #{inspect(reason)}"
    end
  end

  defp normalize_method!(method) when is_atom(method) or is_binary(method) do
    normalized = method |> to_string() |> String.downcase()

    if normalized in @http_methods do
      normalized
    else
      raise ArgumentError, "unsupported OpenAPI HTTP method: #{inspect(method)}"
    end
  end

  defp normalize_method!(method), do: raise(ArgumentError, "invalid OpenAPI HTTP method: #{inspect(method)}")

  defp validate_path!("/" <> _rest = path), do: path
  defp validate_path!(path), do: raise(ArgumentError, "OpenAPI route path must start with /: #{inspect(path)}")

  defp put_service_info(document, nil), do: document

  defp put_service_info(document, service_info) do
    Map.put(document, "x-service-info", normalize_service_info!(service_info))
  end

  defp normalize_service_info!(service_info) do
    service_info =
      service_info
      |> mapish!("x-service-info")
      |> reject_unknown_keys!(~w(categories docs), "x-service-info")

    service_info
    |> normalize_categories!()
    |> normalize_docs!(service_info)
  end

  defp normalize_categories!(service_info) do
    case Map.fetch(service_info, "categories") do
      :error ->
        %{}

      {:ok, categories} when is_list(categories) ->
        if Enum.all?(categories, &is_binary/1) do
          %{"categories" => categories}
        else
          raise ArgumentError, "x-service-info categories must be strings"
        end

      {:ok, _categories} ->
        raise ArgumentError, "x-service-info categories must be a list"
    end
  end

  defp normalize_docs!(normalized, service_info) do
    case Map.fetch(service_info, "docs") do
      :error -> normalized
      {:ok, docs} -> Map.put(normalized, "docs", normalize_doc_links!(docs))
    end
  end

  defp normalize_doc_links!(docs) do
    docs
    |> mapish!("x-service-info.docs")
    |> reject_unknown_keys!(~w(apiReference homepage llms), "x-service-info.docs")
    |> Map.new(fn {key, uri} -> {key, require_uri!(uri, key)} end)
  end

  defp require_uri!(uri, _field) when is_binary(uri) do
    case URI.new(uri) do
      {:ok, %URI{scheme: scheme}} when is_binary(scheme) -> uri
      _result -> raise ArgumentError, "x-service-info documentation link must be an absolute URI: #{inspect(uri)}"
    end
  end

  defp require_uri!(uri, field), do: raise(ArgumentError, "x-service-info #{field} must be a URI: #{inspect(uri)}")

  defp reject_unknown_keys!(map, allowed, label) do
    case Map.keys(map) -- allowed do
      [] -> map
      keys -> raise ArgumentError, "#{label} has unsupported fields: #{inspect(Enum.sort(keys))}"
    end
  end

  defp put_optional_string(map, _key, nil), do: map

  defp put_optional_string(map, key, value) when is_binary(value), do: Map.put(map, key, value)

  defp put_optional_string(_map, key, value) do
    raise ArgumentError, "OpenAPI #{key} must be a string: #{inspect(value)}"
  end

  defp put_request_body(operation, nil), do: operation

  defp put_request_body(operation, request_body) when is_map(request_body),
    do: Map.put(operation, "requestBody", request_body)

  defp put_request_body(_operation, request_body) do
    raise ArgumentError, "OpenAPI request_body must be a map: #{inspect(request_body)}"
  end

  defp require_string!(value, _field) when is_binary(value), do: value
  defp require_string!(value, field), do: raise(ArgumentError, "OpenAPI #{field} must be a string: #{inspect(value)}")

  defp mapish!(value, label) do
    case stringify_config(value) do
      %{} = map -> map
      _other -> raise ArgumentError, "#{label} must be a map or keyword list: #{inspect(value)}"
    end
  end

  defp stringify_config(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      string_key = config_key!(key)

      if Map.has_key?(acc, string_key) do
        raise ArgumentError, "duplicate OpenAPI config key after normalization: #{string_key}"
      end

      Map.put(acc, string_key, stringify_config(value))
    end)
  end

  defp stringify_config([{_key, _value} | _] = list) do
    if Keyword.keyword?(list) do
      stringify_config(Map.new(list))
    else
      Enum.map(list, &stringify_config/1)
    end
  end

  defp stringify_config(list) when is_list(list), do: Enum.map(list, &stringify_config/1)
  defp stringify_config(value), do: value

  defp config_key!(key) when is_atom(key), do: Atom.to_string(key)
  defp config_key!(key) when is_binary(key), do: key
  defp config_key!(key), do: raise(ArgumentError, "OpenAPI config keys must be atoms or strings: #{inspect(key)}")

  defp fetch_required!(container, key) do
    case config_value(container, key, :missing) do
      :missing -> raise ArgumentError, "missing OpenAPI config key: #{key}"
      value -> value
    end
  end

  defp config_value(container, key, default \\ nil)
  defp config_value(container, key, default) when is_list(container), do: Keyword.get(container, key, default)

  defp config_value(container, key, default) when is_map(container) do
    Map.get(container, key, Map.get(container, Atom.to_string(key), default))
  end
end
