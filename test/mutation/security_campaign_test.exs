defmodule MPP.Test.SecurityMutationCampaignTest do
  use ExUnit.Case, async: true

  alias MPP.Test.SecurityMutationCampaign
  alias MPP.Test.SecurityMutations

  Code.require_file("security_mutations.exs", __DIR__)

  @ledger_path Path.join(__DIR__, "payment_security_ledger.json")
  @workflow_path ".github/workflows/mutation-security.yml"

  test "every mutation applies exactly once to the current source" do
    for mutation <- SecurityMutations.all() do
      source = File.read!(mutation.file)

      assert {:ok, mutated} = SecurityMutations.apply_once(source, mutation), mutation.id
      refute mutated == source
      refute String.contains?(mutated, mutation.before)
    end
  end

  test "duplicate and absent replacement sites invalidate a mutant" do
    [mutation | _] = SecurityMutations.all()

    assert {:error, {:replacement_count, 0}} = SecurityMutations.apply_once("absent", mutation)

    duplicate = mutation.before <> mutation.before
    assert {:error, {:replacement_count, 2}} = SecurityMutations.apply_once(duplicate, mutation)
  end

  test "ledger matches the executable campaign and has no unclassified survivors" do
    ledger = @ledger_path |> File.read!() |> Jason.decode!()

    assert :ok = SecurityMutations.validate_ledger(ledger, File.cwd!())
    assert get_in(ledger, ["campaign", "survivors"]) == []
    assert Enum.all?(get_in(ledger, ["campaign", "mutations"]), &(&1["status"] == "killed"))
  end

  test "canonicalization, pinning and authorization dispatch canaries are mandatory" do
    canary_ids =
      SecurityMutations.all()
      |> Enum.filter(& &1.canary)
      |> Enum.map(& &1.id)

    assert Enum.sort(canary_ids) ==
             Enum.sort([
               "jcs-descending-key-order",
               "verifier-request-pin-bypassed",
               "evm-authorization-dispatch-hash-routed",
               "tempo-unknown-dispatch-accepted"
             ])
  end

  test "a surviving canary fails the campaign even when the ledger says killed" do
    ledger = @ledger_path |> File.read!() |> Jason.decode!()

    for %{id: id} = mutation <- SecurityMutations.all(), mutation.canary do
      results = campaign_results(id, "survived")

      assert {:error, {:surviving_canaries, [^id]}} =
               SecurityMutationCampaign.validate_results(results, ledger)
    end
  end

  test "a surviving non-canary is still a campaign failure" do
    ledger = @ledger_path |> File.read!() |> Jason.decode!()
    %{id: id} = Enum.find(SecurityMutations.all(), &(not &1.canary))

    assert {:error, {:unclassified_survivors, [^id]}} =
             SecurityMutationCampaign.validate_results(campaign_results(id, "survived"), ledger)
  end

  test "nightly workflow runs the executable campaign off the PR gate" do
    workflow = File.read!(@workflow_path)
    on_block = yaml_mapping_block(workflow, "on")

    assert on_block =~ ~r/^\s+schedule:\s*$/m
    assert on_block =~ ~r/cron:\s+"\d+ \d+ \* \* \*"/
    assert on_block =~ "workflow_dispatch:"
    refute on_block =~ "pull_request:"
    refute on_block =~ "push:"

    run_steps =
      ~r/^\s+run:\s+(.+)$/m
      |> Regex.scan(workflow, capture: :all_but_first)
      |> List.flatten()

    assert "mix compile" in run_steps
    assert "mix mutation.security" in run_steps
    refute "mix ci" in run_steps
    refute Enum.any?(run_steps, &String.contains?(&1, "precommit.full"))
  end

  test "mix precommit.full does not fold in the mutation campaign" do
    aliases = Mix.Project.config()[:aliases]

    for name <- [:precommit, :"precommit.full", :ci, :"check.dispatch"] do
      steps = aliases |> Keyword.get(name, []) |> List.wrap()
      refute "mutation.security" in steps, "#{name} must stay free of mutation.security"
    end

    assert aliases[:"mutation.security"] == "run test/mutation/security_campaign.exs"
    refute File.read!(".github/workflows/ci.yml") =~ "mutation.security"
  end

  defp campaign_results(surviving_id, surviving_status) do
    Enum.map(SecurityMutations.all(), fn candidate ->
      status = if candidate.id == surviving_id, do: surviving_status, else: "killed"
      %{id: candidate.id, status: status, canary: candidate.canary, output: ""}
    end)
  end

  defp yaml_mapping_block(source, key) do
    case Regex.run(~r/^#{Regex.escape(key)}:\n((?:  .*\n|\n)*)/m, source) do
      [_, block] -> block
      nil -> flunk("workflow is missing a #{key}: mapping")
    end
  end
end
