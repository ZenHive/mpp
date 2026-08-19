defmodule MPP.Test.SecurityMutationCampaignTest do
  use ExUnit.Case, async: true

  alias MPP.Test.SecurityMutations

  Code.require_file("security_mutations.exs", __DIR__)

  @ledger_path Path.join(__DIR__, "payment_security_ledger.json")

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

  test "canonicalization, pinning and authorization canaries are mandatory" do
    canary_classes =
      SecurityMutations.all()
      |> Enum.filter(& &1.canary)
      |> Enum.map(& &1.class)

    assert Enum.sort(canary_classes) == ["authorization-dispatch", "canonical-ordering", "pinned-fields"]
  end
end
