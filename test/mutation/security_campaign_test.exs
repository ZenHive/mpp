defmodule MPP.Test.SecurityMutationCampaignTest do
  use ExUnit.Case, async: true

  alias MPP.Test.SecurityMutationCampaign
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

    stale = put_in(ledger, ["campaign", "fingerprint_sha256"], "stale")
    assert {:error, :fingerprint_mismatch} = SecurityMutations.validate_ledger(stale, File.cwd!())
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
               "tempo-unknown-dispatch-accepted",
               "tempo-reserve-key-caller-bytes"
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

  test "incomplete, duplicate and unknown results cannot certify a campaign" do
    ledger = @ledger_path |> File.read!() |> Jason.decode!()
    results = campaign_results(nil, "survived")
    expected_ids = Enum.map(results, & &1.id)

    for invalid <- [[], tl(results), results ++ [hd(results)], [%{hd(results) | id: "unknown"} | tl(results)]] do
      assert {:error, {:result_ids, ^expected_ids, _}} =
               SecurityMutationCampaign.validate_results(invalid, ledger)
    end
  end

  test "refresh does not bypass invalid ledger statuses or overwrite the ledger" do
    root = Path.join(System.tmp_dir!(), "mpp-invalid-ledger-#{System.unique_integer([:positive])}")
    path = Path.join(root, "test/mutation/payment_security_ledger.json")
    File.mkdir_p!(Path.dirname(path))
    on_exit(fn -> File.rm_rf!(root) end)

    ledger = @ledger_path |> File.read!() |> Jason.decode!()
    [first | rest] = get_in(ledger, ["campaign", "mutations"])
    invalid = put_in(ledger, ["campaign", "mutations"], [%{first | "status" => "survived"} | rest])
    original = Jason.encode!(invalid)
    File.write!(path, original)

    assert {:error, {:unexpected_statuses, ["survived" | _]}} =
             SecurityMutationCampaign.run(root, refresh: true)

    assert File.read!(path) == original
  end

  test "mix precommit.full does not fold in the mutation campaign" do
    aliases = Mix.Project.config()[:aliases]

    for name <- [:precommit, :"precommit.full", :ci, :"check.dispatch"] do
      steps = aliases |> Keyword.get(name, []) |> List.wrap()
      refute "mutation.security" in steps, "#{name} must stay free of mutation.security"
    end

    assert aliases[:"mutation.security"] == "run test/mutation/security_campaign.exs"
  end

  defp campaign_results(surviving_id, surviving_status) do
    Enum.map(SecurityMutations.all(), fn candidate ->
      status = if candidate.id == surviving_id, do: surviving_status, else: "killed"
      %{id: candidate.id, status: status, canary: candidate.canary, output: ""}
    end)
  end
end
