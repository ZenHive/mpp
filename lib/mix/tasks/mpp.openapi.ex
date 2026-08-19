defmodule Mix.Tasks.Mpp.Openapi do
  @shortdoc "Generate an MPP OpenAPI discovery document"

  @moduledoc """
  Generates an OpenAPI 3.1.0 discovery document from an Elixir config file.

      mix mpp.openapi path/to/mpp_openapi.exs
      mix mpp.openapi path/to/mpp_openapi.exs path/to/openapi.json

  The config file must evaluate to the keyword list or map accepted by
  `MPP.Discovery.OpenApi.generate/1`. Output defaults to `openapi.json`.
  """

  use Mix.Task

  alias MPP.Discovery.OpenApi

  @default_output "openapi.json"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run([config_file]), do: run([config_file, @default_output])

  def run([config_file, output_file]) do
    {config, _binding} = Code.eval_file(config_file)
    document = OpenApi.generate(config)
    File.write!(output_file, Jason.encode!(document, pretty: true))
    IO.puts("Generated #{output_file} (#{map_size(document["paths"])} paths)")
  end

  def run(_args) do
    Mix.raise("usage: mix mpp.openapi CONFIG_FILE [OUTPUT_FILE]")
  end
end
