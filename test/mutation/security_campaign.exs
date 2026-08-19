Code.require_file("security_mutations.exs", __DIR__)

case MPP.Test.SecurityMutationCampaign.run(File.cwd!()) do
  :ok ->
    IO.puts("Mutation campaign passed: every payment-security mutant was killed")

  {:error, reason} ->
    IO.puts(:stderr, "Mutation campaign failed: #{inspect(reason, pretty: true)}")
    System.halt(1)
end
