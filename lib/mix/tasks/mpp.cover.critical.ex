defmodule Mix.Tasks.Mpp.Cover.Critical do
  @shortdoc "Fail if a money-critical module is below the 95% coverage floor"

  @moduledoc """
  Reads the coverage JSON produced by `mix test.json --cover --output` and
  fails if any module in the money-critical tier is below the 95% floor.

  The tier is every payment method under `lib/mpp/methods/`, the session
  channel code under `lib/mpp/session/`, x402 settlement and signing under
  `lib/mpp/x402/` and `lib/mpp/x402.ex`, and the verification core every
  method depends on (headers, verifier, challenge, credential, replay, JCS,
  body digest). Client transports, discovery and the demo stay
  aggregate-gated.

  Does not run the test suite. The `precommit` alias writes `_build/test/cover.json`
  from the existing test+cover step, then this task reads that file.

      mix mpp.cover.critical
      mix mpp.cover.critical path/to/cover.json
  """

  use Mix.Task

  @floor 95
  @critical_prefixes [
    "lib/mpp/methods/",
    "lib/mpp/session/",
    "lib/mpp/x402/",
    "lib/mpp/x402.ex",
    "lib/mpp/headers/",
    "lib/mpp/headers.ex",
    "lib/mpp/verifier.ex",
    "lib/mpp/challenge.ex",
    "lib/mpp/credential.ex",
    "lib/mpp/replay.ex",
    "lib/mpp/jcs.ex",
    "lib/mpp/body_digest.ex"
  ]
  # Erlang cover counts the `defmodule` line itself (and a callback stub) in the
  # denominator, so a behaviour-sized module reports far below 95% with nothing
  # to cover. MPP.Client.Transport is the worked example: 77.78% with uncovered
  # lines [1, 120] out of 9 relevant lines. The exemption is therefore scoped to
  # modules with at most this many relevant lines; a 35-line wire-format module
  # with two uncovered branches is graded against the floor like any other.
  @small_module_lines 10
  @default_path "_build/test/cover.json"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    path = List.first(args) || @default_path

    document =
      case File.read(path) do
        {:ok, json} ->
          decode_coverage!(json, path)

        {:error, reason} ->
          Mix.raise("mpp.cover.critical: cannot read #{path} (#{inspect(reason)})")
      end

    Mix.shell().info("[mpp.cover.critical] #{summary_line(document)} — suite JSON: #{path}")

    case evaluate(document) do
      :ok ->
        Mix.shell().info(
          "[mpp.cover.critical] money-critical modules at or above #{@floor}% (exempt: at most #{@small_module_lines} relevant lines)"
        )

        :ok

      {:error, message} ->
        Mix.raise(message)
    end
  end

  @doc "Evaluate a decoded `mix test.json --cover` document against the money-critical floor."
  @spec evaluate(map()) :: :ok | {:error, String.t()}
  def evaluate(%{"coverage" => %{"modules" => modules}}) when is_list(modules) do
    failures =
      modules
      |> Enum.filter(&failing_critical_module?/1)
      |> Enum.sort_by(& &1["module"])

    case failures do
      [] ->
        :ok

      failing ->
        {:error, format_failure(failing)}
    end
  end

  def evaluate(_document) do
    {:error, "mpp.cover.critical: coverage JSON is missing coverage.modules"}
  end

  @doc "The `lib/` path prefixes that make up the money-critical tier."
  @spec critical_prefixes() :: [String.t()]
  def critical_prefixes, do: @critical_prefixes

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
        Mix.raise("mpp.cover.critical: #{path} is not a JSON object")

      {:error, %Jason.DecodeError{} = error} ->
        Mix.raise("mpp.cover.critical: #{path} is not valid JSON (#{Exception.message(error)})")
    end
  end

  defp critical_module?(%{"file" => file}) when is_binary(file) do
    Enum.any?(@critical_prefixes, &String.starts_with?(file, &1))
  end

  defp critical_module?(_module), do: false

  defp failing_critical_module?(module) do
    critical_module?(module) and percentage(module) < @floor and not small_module?(module)
  end

  # Fail closed on a malformed entry: an absent or mistyped line count means the
  # coverage schema changed under us, and the exemption must not be the thing
  # that silently lets a below-floor module through.
  defp small_module?(%{"covered_lines" => covered, "uncovered_lines" => uncovered})
       when is_integer(covered) and is_list(uncovered) do
    covered + length(uncovered) <= @small_module_lines
  end

  defp small_module?(_module), do: false

  defp percentage(%{"percentage" => percentage}) when is_number(percentage), do: percentage
  defp percentage(_module), do: 0

  defp uncovered_count(%{"uncovered_lines" => lines}) when is_list(lines), do: length(lines)
  defp uncovered_count(_module), do: 0

  defp format_failure(failures) do
    rows =
      Enum.map_join(failures, "\n", fn module ->
        name = module["module"] || "unknown"
        "  #{name} #{percentage(module)}% (#{uncovered_count(module)} uncovered lines)"
      end)

    """
    money-critical coverage floor #{@floor}% failed:
    #{rows}
    """
  end
end
