defmodule MPP.MixAliasesTest do
  use ExUnit.Case, async: true

  # Before (origin/main): check.dispatch -> precommit.full; ci -> precommit.full.
  # After: check.dispatch -> format + compile; ci / precommit.full still expand
  # the full QA list independently (they never called check.dispatch).

  @full_qa_string_steps [
    "format --check-formatted",
    "compile --warnings-as-errors",
    "credo --strict --ignore TagTODO,TagFIXME",
    "doctor --raise",
    "cmd env MIX_ENV=test mix test.json --quiet --cover --cover-threshold 95 --exclude integration --exclude cross_validation --output _build/test/cover.json",
    "mpp.cover.critical",
    "sobelow --skip --exit low",
    "ex_dna --max-clones 0",
    "reach.check --arch --smells --path lib",
    "dialyzer.json --quiet",
    "deps.audit --ignore-file .mix_audit_ignore"
  ]

  @dispatch_forbidden [
    "test.json",
    "--cover",
    "cover-threshold",
    "mpp.cover.critical",
    "dialyzer",
    "reach",
    "sobelow",
    "credo",
    "doctor",
    "ex_dna"
  ]

  test "check.dispatch is format plus compile only" do
    assert aliases()[:"check.dispatch"] == [
             "format --check-formatted",
             "compile --warnings-as-errors"
           ]

    dispatch = expand(:"check.dispatch")

    for forbidden <- @dispatch_forbidden do
      refute Enum.any?(dispatch, &String.contains?(&1, forbidden)),
             "check.dispatch must not run #{forbidden}"
    end
  end

  test "ci and precommit.full keep every full-QA step without depending on check.dispatch" do
    aliases = aliases()

    for name <- [:precommit, :"precommit.full", :ci] do
      steps = aliases |> Keyword.fetch!(name) |> List.wrap()
      refute "check.dispatch" in steps, "#{name} must not depend on check.dispatch"
    end

    assert aliases[:ci] == ["precommit.full"]
    assert List.first(aliases[:"precommit.full"]) == "precommit"

    expanded = expand(:ci)

    for step <- @full_qa_string_steps do
      assert step in expanded, "full QA lost #{step}"
    end

    assert "agents.check" in aliases[:"precommit.full"]
    assert "deps.audit.gated" in aliases[:"precommit.full"]
    assert Enum.any?(expanded, &is_function/1)
  end

  test "mix precommit.full does not fold in the mutation campaign" do
    for name <- [:precommit, :"precommit.full", :ci, :"check.dispatch"] do
      steps = aliases() |> Keyword.get(name, []) |> List.wrap()
      refute "mutation.security" in steps, "#{name} must stay free of mutation.security"
    end
  end

  defp aliases, do: Mix.Project.config()[:aliases]

  defp expand(name) when is_atom(name) do
    aliases()
    |> Keyword.fetch!(name)
    |> List.wrap()
    |> Enum.flat_map(&expand_step/1)
  end

  defp expand_step(step) when is_binary(step) do
    case Enum.find(Keyword.keys(aliases()), &(Atom.to_string(&1) == step)) do
      nil -> [step]
      nested -> expand(nested)
    end
  end

  defp expand_step(step), do: [step]
end
