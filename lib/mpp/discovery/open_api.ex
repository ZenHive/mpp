defmodule MPP.Discovery.OpenApi do
  @moduledoc """
  Generates OpenAPI 3.1.0 discovery documents for MPP-enabled HTTP operations.

  The input is a keyword list or map containing `:info`, `:routes`, and optional
  `:service_info`. Routes with payment metadata emit `x-payment-info` and a 402
  response; routes with `payment: nil` or no `:payment` key are unpaid and omit
  both. Payment metadata may use either discovery form, but generated documents
  always contain the recommended multi-offer `offers` array on payable operations.

  Routes may declare OpenAPI Parameter Objects via `:parameters` (`in` of
  `query`, `path`, `header`, or `cookie`) and an optional success-response
  schema via `:response_schema` (media type `:response_media_type`, default
  `application/json`). A path template with a `{placeholder}` and no matching
  `in: path` parameter is rejected at generation time.

      MPP.Discovery.OpenApi.generate(
        info: %{title: "Example API", version: "1.0.0"},
        service_info: %{
          "categories" => ["compute"],
          "docs" => %{"homepage" => "https://example.com"}
        },
        routes: [
          [method: :get, path: "/health"],
          [
            method: :get,
            path: "/v1/items/{id}",
            summary: "Get item",
            parameters: [
              [name: "id", in: :path, required: true, schema: %{"type" => "string"}],
              [name: "lang", in: :query, schema: %{"type" => "string"}, description: "Locale"]
            ],
            response_schema: %{"type" => "object", "properties" => %{"id" => %{"type" => "string"}}},
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
  @parameter_fields ~w(name in required schema description)
  @parameter_locations ~w(query path header cookie)
  @path_placeholders ~r/\{([^{}]+)\}/

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
      |> put_parameters(path, config_value(route, :parameters))
      |> put_response_schema(
        config_value(route, :response_schema),
        config_value(route, :response_media_type)
      )

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

  defp put_parameters(operation, path, parameters) do
    normalized = normalize_parameters!(parameters)
    validate_path_parameters!(path, normalized)

    case normalized do
      [] -> operation
      _parameters -> Map.put(operation, "parameters", normalized)
    end
  end

  defp normalize_parameters!(nil), do: []

  defp normalize_parameters!(parameters) when is_list(parameters) do
    parameters
    |> Enum.with_index()
    |> Enum.map(fn {parameter, index} -> normalize_parameter!(parameter, index) end)
    |> reject_duplicate_parameters!()
  end

  defp normalize_parameters!(parameters) do
    raise ArgumentError, "OpenAPI parameters must be a list: #{inspect(parameters)}"
  end

  defp normalize_parameter!(parameter, index) when is_list(parameter) or is_map(parameter) do
    parameter =
      parameter
      |> mapish!("OpenAPI parameters[#{index}]")
      |> reject_unknown_keys!(@parameter_fields, "OpenAPI parameters[#{index}]")

    name = parameter |> fetch_parameter_field!(index, "name") |> require_parameter_name!()
    location = parameter |> fetch_parameter_field!(index, "in") |> normalize_parameter_in!()
    schema = parameter |> fetch_parameter_field!(index, "schema") |> require_schema_map!("parameters.schema")

    %{"name" => name, "in" => location, "schema" => schema}
    |> put_parameter_required(name, location, Map.get(parameter, "required", :missing))
    |> put_optional_string("description", Map.get(parameter, "description"))
  end

  defp normalize_parameter!(parameter, index) do
    raise ArgumentError, "OpenAPI parameters[#{index}] must be a map or keyword list: #{inspect(parameter)}"
  end

  defp fetch_parameter_field!(parameter, index, field) do
    case Map.fetch(parameter, field) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "missing OpenAPI parameters[#{index}].#{field}"
    end
  end

  defp require_parameter_name!(name) when is_binary(name) and name != "", do: name

  defp require_parameter_name!(name) do
    raise ArgumentError, "OpenAPI parameters.name must be a non-empty string: #{inspect(name)}"
  end

  defp normalize_parameter_in!(location) when is_atom(location) or is_binary(location) do
    normalized = location |> to_string() |> String.downcase()

    if normalized in @parameter_locations do
      normalized
    else
      raise ArgumentError, "OpenAPI parameters.in is invalid: #{inspect(location)}"
    end
  end

  defp normalize_parameter_in!(location) do
    raise ArgumentError, "OpenAPI parameters.in is invalid: #{inspect(location)}"
  end

  defp put_parameter_required(parameter, _name, "path", true), do: Map.put(parameter, "required", true)

  defp put_parameter_required(_parameter, name, "path", required) do
    raise ArgumentError, "OpenAPI parameters.required must be true for path parameter #{name}: #{inspect(required)}"
  end

  defp put_parameter_required(parameter, _name, _location, :missing), do: parameter

  defp put_parameter_required(parameter, _name, _location, required) when is_boolean(required) do
    Map.put(parameter, "required", required)
  end

  defp put_parameter_required(_parameter, _name, _location, required) do
    raise ArgumentError, "OpenAPI parameters.required must be a boolean: #{inspect(required)}"
  end

  defp reject_duplicate_parameters!(parameters) do
    parameters
    |> Enum.group_by(&{&1["name"], &1["in"]})
    |> Enum.each(fn
      {{name, location}, [_, _ | _]} ->
        raise ArgumentError, "duplicate OpenAPI parameter: #{location} #{name}"

      {_key, _copies} ->
        :ok
    end)

    parameters
  end

  defp validate_path_parameters!(path, parameters) do
    placeholders = path |> path_placeholders() |> MapSet.new()

    path_names =
      parameters
      |> Enum.filter(&(&1["in"] == "path"))
      |> MapSet.new(& &1["name"])

    missing = placeholders |> MapSet.difference(path_names) |> Enum.sort()
    extra = path_names |> MapSet.difference(placeholders) |> Enum.sort()

    cond do
      missing != [] ->
        raise ArgumentError, "OpenAPI path #{path} is missing path parameter: #{Enum.join(missing, ", ")}"

      extra != [] ->
        raise ArgumentError, "OpenAPI path parameter #{Enum.join(extra, ", ")} does not appear in path #{path}"

      true ->
        :ok
    end
  end

  defp path_placeholders(path) do
    @path_placeholders
    |> Regex.scan(path, capture: :all_but_first)
    |> List.flatten()
  end

  defp put_response_schema(operation, nil, nil), do: operation

  defp put_response_schema(_operation, nil, media_type) do
    raise ArgumentError, "OpenAPI response_media_type requires response_schema: #{inspect(media_type)}"
  end

  defp put_response_schema(operation, schema, media_type) do
    schema = require_schema_map!(schema, "response_schema")
    media_type = normalize_media_type!(media_type)
    put_in(operation, ["responses", "200", "content"], %{media_type => %{"schema" => schema}})
  end

  defp normalize_media_type!(nil), do: "application/json"

  defp normalize_media_type!(media_type) when is_binary(media_type) and media_type != "" do
    if String.contains?(media_type, "/") do
      media_type
    else
      raise ArgumentError, "OpenAPI response_media_type must be a media type: #{inspect(media_type)}"
    end
  end

  defp normalize_media_type!(media_type) do
    raise ArgumentError, "OpenAPI response_media_type must be a string: #{inspect(media_type)}"
  end

  defp require_schema_map!(schema, field) when is_map(schema), do: mapish!(schema, "OpenAPI #{field}")

  defp require_schema_map!(schema, field) do
    raise ArgumentError, "OpenAPI #{field} must be a map: #{inspect(schema)}"
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
