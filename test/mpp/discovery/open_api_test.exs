defmodule MPP.Discovery.OpenApiTest do
  use ExUnit.Case, async: true

  alias MPP.Discovery.OpenApi

  describe "generate/1" do
    test "matches mppx OpenApi output for an equivalent standard offer" do
      # Semantic match of mppx generateProxy → createDocument for this config.
      # Source: wevm/mppx@c004d2c8 src/discovery/OpenApi.ts (402+200 responses,
      # PaymentInfo.parse wrapping shorthand into offers). Map equality, not
      # JSON byte order — mppx emits info/openapi/paths and 402 before 200.
      document =
        OpenApi.generate(
          info: %{title: "test-realm", version: "1.0.0"},
          routes: [
            [
              method: :get,
              path: "/api/resource",
              payment: %{
                "intent" => "charge",
                "method" => "tempo",
                "amount" => "100",
                "currency" => "0xUSDC"
              }
            ]
          ]
        )

      assert document == %{
               "info" => %{"title" => "test-realm", "version" => "1.0.0"},
               "openapi" => "3.1.0",
               "paths" => %{
                 "/api/resource" => %{
                   "get" => %{
                     "responses" => %{
                       "200" => %{"description" => "Successful response"},
                       "402" => %{"description" => "Payment Required"}
                     },
                     "x-payment-info" => %{
                       "offers" => [
                         %{
                           "amount" => "100",
                           "currency" => "0xUSDC",
                           "intent" => "charge",
                           "method" => "tempo"
                         }
                       ]
                     }
                   }
                 }
               }
             }
    end

    test "emits service info, route metadata, and multiple operations on one path" do
      request_body = %{
        "content" => %{"application/json" => %{"schema" => %{"type" => "object"}}}
      }

      document =
        OpenApi.generate(%{
          "info" => %{"title" => "Search API", "version" => "2.0.0"},
          "routes" => [
            %{
              "method" => "POST",
              "path" => "/search",
              "payment" => %{
                "offers" => [
                  %{"intent" => "charge", "method" => "tempo", "amount" => "50", "currency" => "usd"},
                  %{"intent" => "session", "method" => "tempo", "amount" => nil}
                ]
              },
              "request_body" => request_body,
              "summary" => "Search documents"
            },
            %{
              "method" => "get",
              "path" => "/search",
              "payment" => %{"intent" => "charge", "method" => "stripe", "amount" => "75"}
            }
          ],
          "service_info" => %{
            "categories" => ["search", "data"],
            "docs" => %{
              "apiReference" => "https://example.com/api",
              "homepage" => "https://example.com",
              "llms" => "https://example.com/llms.txt"
            }
          }
        })

      assert document["x-service-info"]["categories"] == ["search", "data"]
      assert document["x-service-info"]["docs"]["llms"] == "https://example.com/llms.txt"
      assert document["paths"]["/search"]["post"]["summary"] == "Search documents"
      assert document["paths"]["/search"]["post"]["requestBody"] == request_body
      assert [_, _] = document["paths"]["/search"]["post"]["x-payment-info"]["offers"]
      assert document["paths"]["/search"]["get"]["responses"]["402"] == %{"description" => "Payment Required"}
    end

    test "omits x-payment-info and 402 for unpaid GET routes alongside paid POSTs" do
      # Matches mppx createDocument / generateProxy: 402 and x-payment-info only
      # when route.payment is truthy (wevm/mppx src/discovery/OpenApi.ts).
      # draft-payment-discovery-00 §4.4: only payable operations MUST carry them.
      document =
        OpenApi.generate(
          info: %{title: "Mixed API", version: "1.0.0"},
          routes: [
            [method: :get, path: "/resource"],
            [
              method: :post,
              path: "/resource",
              payment: %{"intent" => "charge", "method" => "tempo", "amount" => "100"}
            ],
            [method: :get, path: "/health", payment: nil],
            %{
              "method" => "post",
              "path" => "/search",
              "payment" => %{"intent" => "charge", "method" => "stripe", "amount" => "50"}
            }
          ]
        )

      assert_openapi_3_1_0(document)

      unpaid = %{"responses" => %{"200" => %{"description" => "Successful response"}}}
      assert document["paths"]["/resource"]["get"] == unpaid
      assert document["paths"]["/health"]["get"] == unpaid

      paid_same_path = document["paths"]["/resource"]["post"]
      assert paid_same_path["responses"]["402"] == %{"description" => "Payment Required"}

      assert paid_same_path["x-payment-info"]["offers"] == [
               %{"intent" => "charge", "method" => "tempo", "amount" => "100"}
             ]

      paid_other_path = document["paths"]["/search"]["post"]
      assert paid_other_path["responses"]["402"] == %{"description" => "Payment Required"}

      assert paid_other_path["x-payment-info"]["offers"] == [
               %{"intent" => "charge", "method" => "stripe", "amount" => "50"}
             ]
    end

    test "accepts Elixir atom-key and keyword-list payment and service_info" do
      document =
        OpenApi.generate(
          info: [title: "Keyword API", version: "1.0.0"],
          service_info: [
            categories: ["search"],
            docs: [homepage: "https://example.com"]
          ],
          routes: [
            [
              method: :get,
              path: "/paid",
              payment: [intent: "charge", method: "tempo", amount: "10", currency: "usd"]
            ]
          ]
        )

      assert document["info"] == %{"title" => "Keyword API", "version" => "1.0.0"}

      assert document["x-service-info"] == %{
               "categories" => ["search"],
               "docs" => %{"homepage" => "https://example.com"}
             }

      assert document["paths"]["/paid"]["get"]["x-payment-info"]["offers"] == [
               %{"intent" => "charge", "method" => "tempo", "amount" => "10", "currency" => "usd"}
             ]
    end

    test "rejects mixed atom and string keys that would collide" do
      valid = valid_config()
      route = hd(valid[:routes])
      payment = Map.put(route[:payment], :intent, "session")

      assert_raise ArgumentError, ~r/duplicate OpenAPI config key after normalization: intent/, fn ->
        OpenApi.generate(Keyword.put(valid, :routes, [Keyword.put(route, :payment, payment)]))
      end
    end

    test "rejects invalid document and route config" do
      valid = valid_config()

      assert_raise ArgumentError, ~r/keyword list or map/, fn -> OpenApi.generate(:invalid) end
      assert_raise ArgumentError, ~r/missing OpenAPI config key: info/, fn -> OpenApi.generate(routes: []) end
      assert_raise ArgumentError, ~r/non-empty list/, fn -> OpenApi.generate(info: valid[:info], routes: []) end

      assert_raise ArgumentError, ~r/info must be a keyword list or map/, fn ->
        OpenApi.generate(info: nil, routes: [hd(valid[:routes])])
      end

      assert_raise ArgumentError, ~r/info.title must be a string/, fn ->
        OpenApi.generate(put_in(valid, [:info, :title], 42))
      end

      assert_raise ArgumentError, ~r/each OpenAPI route/, fn ->
        OpenApi.generate(put_in(valid, [:routes], [:invalid]))
      end

      assert_route_error(valid, :path, "resource", ~r/path must start with/)
      assert_route_error(valid, :method, :connect, ~r/unsupported OpenAPI HTTP method/)
      assert_route_error(valid, :method, 42, ~r/invalid OpenAPI HTTP method/)
      assert_route_error(valid, :summary, 42, ~r/summary must be a string/)
      assert_route_error(valid, :request_body, [], ~r/request_body must be a map/)
      assert_route_error(valid, :payment, %{"offers" => []}, ~r/invalid x-payment-info/)
      assert_route_error(valid, :payment, [{"intent", "charge"}], ~r/x-payment-info must be a map or keyword list/)
      assert_route_error(valid, :payment, %{1 => "charge"}, ~r/keys must be atoms or strings/)
      assert_route_error(valid, :parameters, %{}, ~r/parameters must be a list/)
      assert_route_error(valid, :response_schema, [], ~r/response_schema must be a map/)

      assert_route_error(
        valid,
        :response_media_type,
        "application/json",
        ~r/response_media_type requires response_schema/
      )
    end

    test "emits query and path parameters and a success-response schema" do
      request_body = %{
        "content" => %{"application/json" => %{"schema" => %{"type" => "object"}}}
      }

      response_schema = %{
        "type" => "object",
        "required" => ["id"],
        "properties" => %{"id" => %{"type" => "string"}}
      }

      document =
        OpenApi.generate(
          info: %{title: "Items API", version: "1.0.0"},
          routes: [
            [
              method: :get,
              path: "/items/{id}",
              summary: "Get item",
              payment: %{"intent" => "charge", "method" => "tempo", "amount" => "25"},
              parameters: [
                [
                  name: "id",
                  in: :path,
                  required: true,
                  schema: %{type: "string"},
                  description: "Item id"
                ],
                [
                  name: "lang",
                  in: "query",
                  required: false,
                  schema: %{"type" => "string"},
                  description: "Locale"
                ]
              ],
              response_schema: response_schema
            ],
            [
              method: :post,
              path: "/items",
              request_body: request_body
            ]
          ]
        )

      get = document["paths"]["/items/{id}"]["get"]
      post = document["paths"]["/items"]["post"]

      assert get["parameters"] == [
               %{
                 "name" => "id",
                 "in" => "path",
                 "required" => true,
                 "schema" => %{"type" => "string"},
                 "description" => "Item id"
               },
               %{
                 "name" => "lang",
                 "in" => "query",
                 "required" => false,
                 "schema" => %{"type" => "string"},
                 "description" => "Locale"
               }
             ]

      assert get["responses"]["200"] == %{
               "description" => "Successful response",
               "content" => %{"application/json" => %{"schema" => response_schema}}
             }

      assert get["responses"]["402"] == %{"description" => "Payment Required"}

      assert get["x-payment-info"]["offers"] == [
               %{"intent" => "charge", "method" => "tempo", "amount" => "25"}
             ]

      assert post == %{
               "requestBody" => request_body,
               "responses" => %{"200" => %{"description" => "Successful response"}}
             }

      refute Map.has_key?(post, "x-payment-info")
      assert_openapi_3_1_0(document)

      spec = OpenApiSpex.OpenApi.from_map(document)
      params = spec.paths["/items/{id}"].get.parameters
      locations = Enum.map(params, &{to_string(&1.name), &1.in, &1.required})
      assert {"id", :path, true} in locations
      assert {"lang", :query, false} in locations
      assert spec.paths["/items"].post.requestBody
    end

    test "overrides the success-response media type" do
      document =
        OpenApi.generate(
          info: %{title: "API", version: "1"},
          routes: [
            [
              method: :get,
              path: "/export",
              response_schema: %{"type" => "string"},
              response_media_type: "text/csv"
            ]
          ]
        )

      assert document["paths"]["/export"]["get"]["responses"]["200"] == %{
               "description" => "Successful response",
               "content" => %{"text/csv" => %{"schema" => %{"type" => "string"}}}
             }
    end

    test "a route without parameters or response_schema stays description-only" do
      document =
        OpenApi.generate(
          info: %{title: "test-realm", version: "1.0.0"},
          routes: [
            [
              method: :get,
              path: "/api/resource",
              payment: %{
                "intent" => "charge",
                "method" => "tempo",
                "amount" => "100",
                "currency" => "0xUSDC"
              }
            ]
          ]
        )

      operation = document["paths"]["/api/resource"]["get"]
      refute Map.has_key?(operation, "parameters")
      assert operation["responses"]["200"] == %{"description" => "Successful response"}
    end

    test "rejects malformed parameters and unmatched path placeholders" do
      valid = valid_config()
      path_route = valid[:routes] |> hd() |> Keyword.put(:path, "/items/{id}")

      assert_raise ArgumentError, ~r/missing path parameter: id/, fn ->
        OpenApi.generate(Keyword.put(valid, :routes, [path_route]))
      end

      assert_route_error(valid, :parameters, [:invalid], ~r/parameters\[0\] must be a map or keyword list/)

      assert_route_error(
        valid,
        :parameters,
        [[in: :query, schema: %{"type" => "string"}]],
        ~r/missing OpenAPI parameters\[0\]\.name/
      )

      assert_route_error(
        valid,
        :parameters,
        [[name: "q", schema: %{"type" => "string"}]],
        ~r/missing OpenAPI parameters\[0\]\.in/
      )

      assert_route_error(valid, :parameters, [[name: "q", in: :query]], ~r/missing OpenAPI parameters\[0\]\.schema/)

      assert_route_error(
        valid,
        :parameters,
        [[name: "", in: :query, schema: %{"type" => "string"}]],
        ~r/parameters\.name must be a non-empty string/
      )

      assert_route_error(
        valid,
        :parameters,
        [[name: "q", in: :body, schema: %{"type" => "string"}]],
        ~r/parameters\.in is invalid/
      )

      assert_route_error(
        valid,
        :parameters,
        [[name: "q", in: 1, schema: %{"type" => "string"}]],
        ~r/parameters\.in is invalid/
      )

      assert_route_error(valid, :parameters, [[name: "q", in: :query, schema: []]], ~r/parameters\.schema must be a map/)

      assert_route_error(
        valid,
        :parameters,
        [[name: "q", in: :query, required: "yes", schema: %{"type" => "string"}]],
        ~r/parameters\.required must be a boolean/
      )

      assert_route_error(
        valid,
        :parameters,
        [[name: "q", in: :query, schema: %{"type" => "string"}, description: 1]],
        ~r/description must be a string/
      )

      assert_route_error(
        valid,
        :parameters,
        [[name: "q", in: :query, schema: %{"type" => "string"}, explode: true]],
        ~r/unsupported fields/
      )

      assert_raise ArgumentError, ~r/parameters\.required must be true for path parameter id/, fn ->
        OpenApi.generate(
          Keyword.put(valid, :routes, [
            Keyword.put(path_route, :parameters, [[name: "id", in: :path, required: false, schema: %{"type" => "string"}]])
          ])
        )
      end

      assert_raise ArgumentError, ~r/parameters\.required must be true for path parameter id/, fn ->
        OpenApi.generate(
          Keyword.put(valid, :routes, [
            Keyword.put(path_route, :parameters, [[name: "id", in: :path, schema: %{"type" => "string"}]])
          ])
        )
      end

      assert_raise ArgumentError, ~r/duplicate OpenAPI parameter: query q/, fn ->
        OpenApi.generate(
          Keyword.put(valid, :routes, [
            Keyword.put(hd(valid[:routes]), :parameters, [
              [name: "q", in: :query, schema: %{"type" => "string"}],
              [name: "q", in: "query", schema: %{"type" => "integer"}]
            ])
          ])
        )
      end

      assert_raise ArgumentError, ~r/does not appear in path/, fn ->
        OpenApi.generate(
          Keyword.put(valid, :routes, [
            Keyword.put(hd(valid[:routes]), :parameters, [
              [name: "id", in: :path, required: true, schema: %{"type" => "string"}]
            ])
          ])
        )
      end

      schema = %{"type" => "object"}

      assert_raise ArgumentError, ~r/response_media_type must be a string/, fn ->
        OpenApi.generate(put_route(valid, response_schema: schema, response_media_type: ""))
      end

      assert_raise ArgumentError, ~r/response_media_type must be a media type/, fn ->
        OpenApi.generate(put_route(valid, response_schema: schema, response_media_type: "json"))
      end

      assert_raise ArgumentError, ~r/response_media_type must be a string/, fn ->
        OpenApi.generate(put_route(valid, response_schema: schema, response_media_type: 42))
      end
    end

    test "rejects duplicate operations" do
      route = hd(valid_config()[:routes])

      assert_raise ArgumentError, ~r/duplicate OpenAPI route: GET \/resource/, fn ->
        OpenApi.generate(info: %{title: "API", version: "1"}, routes: [route, route])
      end
    end

    test "validates x-service-info" do
      valid = valid_config()

      assert %{"x-service-info" => %{"categories" => ["search"]}} =
               OpenApi.generate(Keyword.put(valid, :service_info, %{"categories" => ["search"]}))

      assert_service_error(valid, [], ~r/x-service-info must be a map/)
      assert_service_error(valid, %{"unknown" => true}, ~r/unsupported fields/)
      assert_service_error(valid, %{"categories" => "search"}, ~r/categories must be a list/)
      assert_service_error(valid, %{"categories" => ["search", 42]}, ~r/categories must be strings/)
      assert_service_error(valid, %{"docs" => []}, ~r/docs must be a map/)
      assert_service_error(valid, %{"docs" => %{"unknown" => "https://example.com"}}, ~r/unsupported fields/)
      assert_service_error(valid, %{"docs" => %{"homepage" => "/docs"}}, ~r/absolute URI/)
      assert_service_error(valid, %{"docs" => %{"homepage" => 42}}, ~r/homepage must be a URI/)
    end
  end

  defp valid_config do
    [
      info: %{title: "API", version: "1.0.0"},
      routes: [
        [
          method: :get,
          path: "/resource",
          payment: %{"intent" => "charge", "method" => "tempo", "amount" => "1"}
        ]
      ]
    ]
  end

  defp put_route(config, extra) do
    route = config[:routes] |> hd() |> Keyword.merge(extra)
    Keyword.put(config, :routes, [route])
  end

  defp assert_route_error(config, key, value, message) do
    route = config[:routes] |> hd() |> Keyword.put(key, value)
    assert_raise ArgumentError, message, fn -> OpenApi.generate(Keyword.put(config, :routes, [route])) end
  end

  defp assert_service_error(config, service_info, message) do
    assert_raise ArgumentError, message, fn ->
      OpenApi.generate(Keyword.put(config, :service_info, service_info))
    end
  end

  defp assert_openapi_3_1_0(document) do
    assert document["openapi"] == "3.1.0"
    assert is_binary(document["info"]["title"])
    assert is_binary(document["info"]["version"])
    assert map_size(document["paths"]) > 0
    assert {:ok, _json} = Jason.encode(document)
    # Independent validator: OpenApiSpex.OpenApi.from_map/1 (open_api_spex).
    assert %OpenApiSpex.OpenApi{openapi: "3.1.0"} = OpenApiSpex.OpenApi.from_map(document)

    for {path, path_item} <- document["paths"], {method, operation} <- path_item do
      assert String.starts_with?(path, "/")
      assert method in ~w(delete get head options patch post put trace)
      assert %{"200" => %{"description" => description}} = operation["responses"]
      assert is_binary(description)

      if Map.has_key?(operation, "x-payment-info") do
        assert operation["responses"]["402"] == %{"description" => "Payment Required"}
      else
        refute Map.has_key?(operation["responses"], "402")
      end
    end
  end
end
