defmodule MPP.Discovery.OpenApiTest do
  use ExUnit.Case, async: true

  alias MPP.Discovery.OpenApi

  describe "generate/1" do
    test "matches mppx OpenApi output for an equivalent standard offer" do
      # Cross-validated by executing mppx 0.8.17 generateProxy/1. Source at
      # c004d2c8e115fc18a8ef21154723488ed1710a6d: src/discovery/OpenApi.ts.
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

  defp assert_route_error(config, key, value, message) do
    route = config[:routes] |> hd() |> Keyword.put(key, value)
    assert_raise ArgumentError, message, fn -> OpenApi.generate(Keyword.put(config, :routes, [route])) end
  end

  defp assert_service_error(config, service_info, message) do
    assert_raise ArgumentError, message, fn ->
      OpenApi.generate(Keyword.put(config, :service_info, service_info))
    end
  end
end
