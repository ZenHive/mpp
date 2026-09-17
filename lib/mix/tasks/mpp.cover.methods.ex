defmodule Mix.Tasks.Mpp.Cover.Methods do
  @shortdoc "Fail if a lib/mpp/methods/ module is below the 95% coverage floor"

  @moduledoc """
  Reads the coverage JSON produced by `mix test.json --cover --output` and
  fails if any module under `lib/mpp/methods/` is below the 95%
  critical-tier floor with more than two uncovered lines.

  Does not run the test suite. The `precommit` alias writes `_build/test/cover.json`
  from the existing test+cover step, then this task reads that file.

      mix mpp.cover.methods
      mix mpp.cover.methods path/to/cover.json
  """

  use Mix.Task

  @floor 95
  # Behaviour-sized modules can report well below 95% because Erlang cover
  # counts the `defmodule` line itself (and a callback stub) in the
  # denominator. MPP.Client.Transport is the worked example: 77.78% with
  # uncovered lines [1, 120]. Fail a lib/mpp/methods/ module only when it is
  # below the floor AND has more than this many uncovered lines, so a two-line
  # behaviour does not fail the gate while a money-verification module with
  # six uncovered lines still does.
  @max_uncovered_lines 2
  @default_path "_build/test/cover.json"
  @methods_prefix "lib/mpp/methods/"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    path = List.first(args) || @default_path

    document =
      case File.read(path) do
        {:ok, json} ->
          decode_coverage!(json, path)

        {:error, reason} ->
          Mix.raise("mpp.cover.methods: cannot read #{path} (#{inspect(reason)})")
      end

    IO.puts("[mpp.cover.methods] #{summary_line(document)} — suite JSON: #{path}")

    case evaluate(document) do
      :ok ->
        IO.puts(
          "[mpp.cover.methods] #{@methods_prefix} modules at or above #{@floor}% (allowance: #{@max_uncovered_lines} uncovered lines)"
        )

        :ok

      {:error, message} ->
        Mix.raise(message)
    end
  end

  @doc "Evaluate a decoded `mix test.json --cover` document against the methods floor."
  @spec evaluate(map()) :: :ok | {:error, String.t()}
  def evaluate(%{"coverage" => %{"modules" => modules}}) when is_list(modules) do
    failures =
      modules
      |> Enum.filter(&failing_methods_module?/1)
      |> Enum.sort_by(& &1["module"])

    case failures do
      [] ->
        :ok

      failing ->
        {:error, format_failure(failing)}
    end
  end

  def evaluate(_document) do
    {:error, "mpp.cover.methods: coverage JSON is missing coverage.modules"}
  end

  # `test.json --output` writes the suite JSON to a file *instead of* stdout, so
  # the gate log would otherwise carry no test or coverage summary at all. Echo
  # the headline numbers and the path that holds the per-test failure detail.
  defp summary_line(document) do
    summary = Map.get(document, "summary", %{})
    coverage = Map.get(document, "coverage", %{})

    "#{Map.get(summary, "passed", 0)} passed, #{Map.get(summary, "failed", 0)} failed, " <>
      "#{Map.get(summary, "excluded", 0)} excluded · aggregate #{Map.get(coverage, "total_percentage", 0)}%"
  end

  defp decode_coverage!(json, path) do
    case Jason.decode(json) do
      {:ok, document} when is_map(document) ->
        document

      {:ok, _other} ->
        Mix.raise("mpp.cover.methods: #{path} is not a JSON object")

      {:error, %Jason.DecodeError{} = error} ->
        Mix.raise("mpp.cover.methods: #{path} is not valid JSON (#{Exception.message(error)})")
    end
  end

  defp methods_module?(%{"file" => file}) when is_binary(file), do: String.starts_with?(file, @methods_prefix)
  defp methods_module?(_module), do: false

  defp failing_methods_module?(module), do: methods_module?(module) and below_floor?(module)

  defp below_floor?(module) do
    percentage(module) < @floor and over_uncovered_allowance?(module)
  end

  # Fail closed on a malformed entry: an absent `uncovered_lines` key means the
  # coverage schema changed under us, and the allowance must not be the thing
  # that silently lets a below-floor module through.
  defp over_uncovered_allowance?(%{"uncovered_lines" => lines}) when is_list(lines) do
    Enum.drop(lines, @max_uncovered_lines) != []
  end

  defp over_uncovered_allowance?(_module), do: true

  defp percentage(%{"percentage" => percentage}) when is_number(percentage), do: percentage
  defp percentage(_module), do: 0

  defp uncovered_lines(%{"uncovered_lines" => lines}) when is_list(lines), do: lines
  defp uncovered_lines(_module), do: []

  defp format_failure(failures) do
    rows =
      Enum.map_join(failures, "\n", fn module ->
        name = module["module"] || "unknown"
        pct = percentage(module)
        count = length(uncovered_lines(module))
        "  #{name} #{pct}% (#{count} uncovered lines)"
      end)

    """
    lib/mpp/methods/ coverage floor #{@floor}% failed:
    #{rows}
    """
  end
end
