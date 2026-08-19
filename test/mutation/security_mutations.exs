defmodule MPP.Test.SecurityMutations do
  @moduledoc false

  @type mutation :: %{
          id: String.t(),
          class: String.t(),
          file: String.t(),
          before: String.t(),
          after: String.t(),
          tests: [String.t()],
          canary: boolean()
        }

  @spec all() :: [mutation()]
  def all do
    [
      mutation(
        "jcs-descending-key-order",
        "canonical-ordering",
        "lib/mpp/jcs.ex",
        "|> Enum.sort_by(fn {k, _v} -> string_key!(k) end)",
        "|> Enum.sort_by(fn {k, _v} -> string_key!(k) end, :desc)",
        ["test/mpp/jcs_test.exs"],
        true
      ),
      mutation(
        "hmac-request-slot-omitted",
        "hmac-domain",
        "lib/mpp/challenge.ex",
        "          challenge.request,\n",
        "          \"\",\n",
        ["test/mpp/challenge_conformance_test.exs"],
        false
      ),
      mutation(
        "hmac-digest-slot-omitted",
        "digest-hmac-domain",
        "lib/mpp/challenge.ex",
        "          challenge.digest || \"\",\n",
        "          \"\",\n",
        ["test/mpp/challenge_conformance_test.exs"],
        false
      ),
      mutation(
        "verifier-request-pin-bypassed",
        "pinned-fields",
        "lib/mpp/verifier.ex",
        "    if request == expected, do: :ok, else: {:error, :request_mismatch}\n",
        "    if is_binary(request) and is_binary(expected), do: :ok, else: {:error, :request_mismatch}\n",
        ["test/mpp/verifier_pinned_property_test.exs", "test/mpp/verifier_pinned_conformance_test.exs"],
        true
      ),
      mutation(
        "verifier-chain-pin-bypassed",
        "chain-binding",
        "lib/mpp/verifier.ex",
        "    if actual_str == chain_id_string(expected) do\n",
        "    if is_binary(actual_str) and is_binary(chain_id_string(expected)) do\n",
        ["test/mpp/verifier_pinned_conformance_test.exs"],
        false
      ),
      mutation(
        "verifier-expiry-bypassed",
        "expiry",
        "lib/mpp/verifier.ex",
        "        if DateTime.before?(DateTime.utc_now(), expires_dt) do\n",
        "        if is_struct(expires_dt, DateTime) do\n",
        ["test/mpp/verifier_test.exs"],
        false
      ),
      mutation(
        "credential-replay-precheck-bypassed",
        "replay",
        "lib/mpp/replay.ex",
        "        {:ok, _value} -> {:error, Errors.new(:verification_failed, \"Payment credential already used\")}\n",
        "        {:ok, _value} -> :ok\n",
        ["test/mpp/replay_test.exs"],
        false
      ),
      mutation(
        "evm-recipient-match-bypassed",
        "evm-recipient-authorization",
        "lib/mpp/methods/evm.ex",
        "            Onchain.Address.equal?(transfer.to, charge.recipient) and\n",
        "            is_binary(charge.recipient) and\n",
        ["test/mpp/methods/evm_test.exs"],
        false
      ),
      mutation(
        "evm-amount-match-bypassed",
        "evm-amount-authorization",
        "lib/mpp/methods/evm.ex",
        "            transfer.amount == amount_int and\n            from_matches?(transfer, expected_from)\n",
        "            is_integer(amount_int) and\n            from_matches?(transfer, expected_from)\n",
        ["test/mpp/methods/evm_test.exs"],
        false
      ),
      mutation(
        "evm-authorization-dispatch-hash-routed",
        "authorization-dispatch",
        "lib/mpp/methods/evm.ex",
        ~s|  def verify(%{"type" => "authorization"} = payload, %Charge{} = charge) do\n|,
        ~s|  def verify(%{"type" => "authorization-mutant"} = payload, %Charge{} = charge) do\n|,
        ["test/mpp/methods/evm_test.exs"],
        true
      ),
      mutation(
        "evm-authorization-from-match-bypassed",
        "evm-authorization-signer-binding",
        "lib/mpp/methods/evm.ex",
        "  defp from_matches?(transfer, expected_from), do: Onchain.Address.equal?(transfer.from, expected_from)\n",
        "  defp from_matches?(_transfer, _expected_from), do: true\n",
        ["test/mpp/methods/evm_test.exs"],
        false
      ),
      mutation(
        "tempo-amount-match-bypassed",
        "tempo-amount-authorization",
        "lib/mpp/methods/tempo.ex",
        """
                    transfer.amount == amount_int and
                    transfer_sender_allowed?(transfer, source, sender_policy) and
                    transfer_memo_bound?(transfer, charge)
        """,
        """
                    is_integer(amount_int) and
                    transfer_sender_allowed?(transfer, source, sender_policy) and
                    transfer_memo_bound?(transfer, charge)
        """,
        ["test/mpp/methods/tempo_test.exs"],
        false
      ),
      mutation(
        "tempo-chain-match-bypassed",
        "tempo-chain-authorization",
        "lib/mpp/methods/tempo.ex",
        "  defp verify_chain_id(%Transaction{chain_id: actual}, expected) when actual == expected, do: :ok\n",
        "  defp verify_chain_id(%Transaction{chain_id: actual}, expected) when is_integer(actual) and is_integer(expected), do: :ok\n",
        ["test/mpp/methods/tempo_test.exs"],
        false
      ),
      mutation(
        "tempo-unknown-dispatch-accepted",
        "authorization-dispatch",
        "lib/mpp/methods/tempo.ex",
        """
          def verify(_payload, %Charge{}) do
            {:error,
             Errors.new(:invalid_payload, ~s(Missing or invalid 'type' field — expected "hash", "transaction", or "proof"))}
          end
        """,
        """
          def verify(_payload, %Charge{} = charge) do
            {:ok, Receipt.new(method: "tempo", reference: "mutant", external_id: charge.external_id)}
          end
        """,
        ["test/mpp/methods/tempo_test.exs"],
        true
      )
    ]
  end

  @spec apply_once(String.t(), mutation()) :: {:ok, String.t()} | {:error, {:replacement_count, non_neg_integer()}}
  def apply_once(source, mutation) do
    case length(:binary.matches(source, mutation.before)) do
      1 -> {:ok, String.replace(source, mutation.before, mutation.after)}
      count -> {:error, {:replacement_count, count}}
    end
  end

  @spec fingerprint(Path.t()) :: String.t()
  def fingerprint(root) do
    definitions =
      Enum.map_join(all(), "\n", fn mutation ->
        Enum.join(
          [mutation.id, mutation.class, mutation.file, mutation.before, mutation.after | mutation.tests],
          "\u0000"
        )
      end)

    files =
      all()
      |> Enum.flat_map(&[&1.file | &1.tests])
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map_join("\n", fn file -> file <> "\u0000" <> File.read!(Path.join(root, file)) end)

    :sha256
    |> :crypto.hash(definitions <> "\n" <> files)
    |> Base.encode16(case: :lower)
  end

  @spec validate_ledger(map(), Path.t()) :: :ok | {:error, term()}
  def validate_ledger(ledger, root) do
    mutation_ids = Enum.map(all(), & &1.id)
    ledger_mutations = get_in(ledger, ["campaign", "mutations"]) || []
    ledger_ids = Enum.map(ledger_mutations, & &1["id"])
    statuses = Enum.map(ledger_mutations, & &1["status"])

    cond do
      ledger_ids != mutation_ids -> {:error, {:mutation_ids, mutation_ids, ledger_ids}}
      Enum.any?(statuses, &(&1 != "killed")) -> {:error, {:unexpected_statuses, statuses}}
      get_in(ledger, ["campaign", "survivors"]) != [] -> {:error, :unclassified_survivors}
      get_in(ledger, ["campaign", "fingerprint_sha256"]) != fingerprint(root) -> {:error, :fingerprint_mismatch}
      true -> :ok
    end
  end

  defp mutation(id, class, file, before, replacement, tests, canary) do
    %{id: id, class: class, file: file, before: before, after: replacement, tests: tests, canary: canary}
  end
end

defmodule MPP.Test.SecurityMutationCampaign do
  @moduledoc false

  alias MPP.Test.SecurityMutations

  @output_tail_lines 20

  @spec run(Path.t()) :: :ok | {:error, term()}
  def run(root) do
    ledger_path = Path.join(root, "test/mutation/payment_security_ledger.json")
    ledger = ledger_path |> File.read!() |> Jason.decode!()

    with :ok <- SecurityMutations.validate_ledger(ledger, root) do
      sandbox = create_sandbox(root)

      try do
        with :ok <- run_baseline(sandbox),
             {:ok, results} <- run_mutations(sandbox) do
          validate_results(results, ledger)
        end
      after
        File.rm_rf!(sandbox)
      end
    end
  end

  @spec validate_results([map()], map()) :: :ok | {:error, term()}
  def validate_results(results, ledger) do
    expected =
      ledger
      |> get_in(["campaign", "mutations"])
      |> Map.new(&{&1["id"], &1["status"]})

    survivors = Enum.filter(results, &(&1.status == "survived"))
    invalid = Enum.filter(results, &(expected[&1.id] != &1.status))
    surviving_canaries = Enum.filter(survivors, & &1.canary)

    cond do
      surviving_canaries != [] -> {:error, {:surviving_canaries, Enum.map(surviving_canaries, & &1.id)}}
      survivors != [] -> {:error, {:unclassified_survivors, Enum.map(survivors, & &1.id)}}
      invalid != [] -> {:error, {:ledger_result_mismatch, invalid}}
      true -> :ok
    end
  end

  defp create_sandbox(root) do
    sandbox = Path.join(System.tmp_dir!(), "mpp-security-mutation-#{System.unique_integer([:positive])}")
    File.mkdir_p!(sandbox)

    try do
      root
      |> tracked_files()
      |> Enum.each(fn relative ->
        destination = Path.join(sandbox, relative)
        File.mkdir_p!(Path.dirname(destination))
        File.cp!(Path.join(root, relative), destination)
      end)

      File.ln_s!(Path.join(root, "deps"), Path.join(sandbox, "deps"))

      if File.dir?(Path.join(root, "_build/test")) do
        File.mkdir_p!(Path.join(sandbox, "_build"))
        File.cp_r!(Path.join(root, "_build/test"), Path.join(sandbox, "_build/test"))
      end

      sandbox
    rescue
      exception ->
        File.rm_rf!(sandbox)
        reraise exception, __STACKTRACE__
    end
  end

  defp tracked_files(root) do
    {output, 0} =
      System.cmd("git", ["ls-files", "--cached", "--others", "--exclude-standard"],
        cd: root,
        stderr_to_stdout: true
      )

    String.split(output, "\n", trim: true)
  end

  defp run_baseline(sandbox) do
    tests = SecurityMutations.all() |> Enum.flat_map(& &1.tests) |> Enum.uniq()

    case command(sandbox, ["test", "--seed", "0" | tests]) do
      {_, 0} -> :ok
      {output, status} -> {:error, {:baseline_failed, status, tail(output)}}
    end
  end

  defp run_mutations(sandbox) do
    SecurityMutations.all()
    |> Enum.reduce_while({:ok, []}, fn mutation, {:ok, results} ->
      case run_mutation(sandbox, mutation) do
        {:ok, result} -> {:cont, {:ok, [result | results]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp run_mutation(sandbox, mutation) do
    path = Path.join(sandbox, mutation.file)
    source = File.read!(path)

    case SecurityMutations.apply_once(source, mutation) do
      {:ok, mutated} ->
        File.write!(path, mutated)

        result =
          case command(sandbox, ["compile", "--force", "--warnings-as-errors"]) do
            {_, 0} -> classify_test_result(sandbox, mutation)
            {output, status} -> {:error, {:invalid_mutant, mutation.id, status, tail(output)}}
          end

        File.write!(path, source)
        result

      {:error, reason} ->
        {:error, {:mutation_not_applied, mutation.id, reason}}
    end
  end

  defp classify_test_result(sandbox, mutation) do
    args = ["test", "--no-compile", "--seed", "0", "--max-failures", "1" | mutation.tests]

    case command(sandbox, args) do
      {output, 0} ->
        IO.puts("SURVIVED #{mutation.id}")
        {:ok, %{id: mutation.id, status: "survived", output: tail(output), canary: mutation.canary}}

      {output, _status} ->
        IO.puts("KILLED #{mutation.id}")
        {:ok, %{id: mutation.id, status: "killed", output: tail(output), canary: mutation.canary}}
    end
  end

  defp command(sandbox, args) do
    System.cmd("mix", args,
      cd: sandbox,
      env: [{"MIX_ENV", "test"}],
      stderr_to_stdout: true
    )
  end

  defp tail(output) do
    output |> String.split("\n") |> Enum.take(-@output_tail_lines) |> Enum.join("\n")
  end
end
