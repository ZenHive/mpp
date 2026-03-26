defmodule Mix.Tasks.Mpp.Manifest do
  @shortdoc "Generate api_manifest.json from descripex metadata"

  @moduledoc """
  Generates a static `api_manifest.json` from the library's descripex annotations.

  The manifest is a JSON-serializable representation of every public function
  in the library — params, return types, errors, specs, and descriptions.
  Suitable for agent discovery, validators, and API generation.

      mix mpp.manifest
      mix mpp.manifest path/to/output.json

  Uses `MPP.__descripex_modules__/0` as the single source of truth for which
  modules to include. Output defaults to `api_manifest.json` in the project root.
  """

  use Mix.Task

  @default_output "api_manifest.json"

  @impl Mix.Task
  def run(args) do
    output_file = List.first(args) || @default_output
    modules = MPP.__descripex_modules__()
    manifest = Descripex.Manifest.build(modules)
    json = Jason.encode!(manifest, pretty: true)
    File.write!(output_file, json)
    # Use IO.puts instead of Mix.shell().info to avoid Dialyzer PLT warning
    IO.puts("Generated #{output_file} (#{length(modules)} modules)")
  end
end
