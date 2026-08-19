defmodule Mix.Tasks.Mpp.OpenapiTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Mpp.Openapi

  setup do
    suffix = System.unique_integer([:positive])
    config_path = Path.join(System.tmp_dir!(), "mpp_openapi_config_#{suffix}.exs")
    output_path = Path.join(System.tmp_dir!(), "mpp_openapi_output_#{suffix}.json")
    default_output_dir = Path.join(System.tmp_dir!(), "mpp_openapi_default_#{suffix}")
    default_output_path = Path.join(default_output_dir, "openapi.json")

    File.mkdir!(default_output_dir)

    File.write!(config_path, """
    [
      info: %{title: "Generated API", version: "1.0.0"},
      routes: [[
        method: :get,
        path: "/paid",
        payment: %{"intent" => "charge", "method" => "tempo", "amount" => "10"}
      ]]
    ]
    """)

    on_exit(fn ->
      File.rm(config_path)
      File.rm(output_path)
      File.rm(default_output_path)
      File.rmdir(default_output_dir)
    end)

    {:ok,
     config_path: config_path,
     output_path: output_path,
     default_output_dir: default_output_dir,
     default_output_path: default_output_path}
  end

  describe "run/1" do
    test "writes a generated OpenAPI JSON document", %{config_path: config_path, output_path: output_path} do
      output = capture_io(fn -> Openapi.run([config_path, output_path]) end)

      assert output == "Generated #{output_path} (1 paths)\n"
      assert {:ok, document} = output_path |> File.read!() |> Jason.decode()
      assert document["openapi"] == "3.1.0"

      assert document["paths"]["/paid"]["get"]["x-payment-info"]["offers"] == [
               %{"intent" => "charge", "method" => "tempo", "amount" => "10"}
             ]
    end

    test "raises with usage for invalid arguments" do
      assert_raise Mix.Error, ~r/usage: mix mpp.openapi/, fn -> Openapi.run([]) end
      assert_raise Mix.Error, ~r/usage: mix mpp.openapi/, fn -> Openapi.run(["one", "two", "three"]) end
    end

    test "defaults output to openapi.json", context do
      output =
        File.cd!(context.default_output_dir, fn ->
          capture_io(fn -> Openapi.run([context.config_path]) end)
        end)

      assert output == "Generated openapi.json (1 paths)\n"
      assert context.default_output_path |> File.read!() |> Jason.decode!() |> Map.fetch!("openapi") == "3.1.0"
    end
  end
end
