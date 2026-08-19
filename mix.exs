defmodule MPP.MixProject do
  use Mix.Project

  @version "0.15.0"
  @source_url "https://github.com/ZenHive/mpp"

  def project do
    [
      app: :mpp,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      test_coverage: test_coverage(),
      test_ignore_filters: [~r{^test/mutation/security_(campaign|mutations)\.exs$}],
      dialyzer: dialyzer(),
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url,
      aliases: aliases()
    ]
  end

  def cli do
    [
      preferred_envs: [
        "test.json": :test,
        "dialyzer.json": :dev,
        "mutation.security": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      # Starts the default replay-dedup store (MPP.Tempo.ConCacheStore) so replay
      # protection is on by default (issue #7), plus MPP.Session.ETSStore.
      mod: {MPP.Application, []}
    ]
  end

  defp deps do
    [
      {:plug, "~> 1.19"},
      {:jason, "~> 1.4.5"},
      {:req, "~> 0.6.1 or ~> 0.7"},
      {:telemetry, "~> 1.4"},

      # Dev/test tooling
      {:ex_doc, "~> 0.40.2", only: :dev, runtime: false},
      {:styler, "~> 1.12", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7.18", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4.7", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.23.0", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.15", only: [:dev, :test], runtime: false},
      {:ex_unit_json, "~> 0.6.0", only: [:dev, :test], runtime: false},
      {:dialyzer_json, "~> 0.2.0", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.0", only: [:dev, :test]},
      {:tidewave, "~> 0.9", only: :dev},
      {:bandit, "~> 1.12.0", only: :dev},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},

      # Code analysis tools (vibe_kit baseline: credo + ex_slop, ex_dna, reach)
      {:ex_dna, "~> 1.5.1", only: [:dev, :test], runtime: false},
      {:ex_ast, "~> 0.12.0", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.7", only: [:dev, :test], runtime: false},

      # JS tooling for dev/test (cross-referencing mppx TypeScript SDK, never production)
      {:quickbeam, "~> 0.11.0", only: [:dev, :test], runtime: false},
      {:oxc, "~> 0.16", only: [:dev, :test], runtime: false},
      {:npm, "~> 0.7.4", only: [:dev, :test], runtime: false},

      # On-chain verification (Tempo and EVM methods). Floor requires the
      # Onchain.RPC surface the EVM method delegates to; it also pulls
      # `cartouche ~> 0.6` (and therefore req 0.6.x) rather than permitting an
      # existing lock on cartouche 0.5.x to sit indefinitely.
      # Three-segment: mpp is a leaf app, so capping at the next minor costs no
      # consumer anything and makes an onchain minor a deliberate step here.
      {:onchain, "~> 0.12.0"},

      # Solana RPC, legacy transaction codec, and System/Token/ATA instruction
      # builders used by MPP.Methods.Solana. Already pulled by onchain; declared
      # directly because this method calls Cartouche.Solana.* rather than an
      # onchain wrapper. Three-segment for the same reason as onchain above.
      {:cartouche, "~> 0.7.0"},

      # Tempo chain primitives (Tempo method) — sender-recovery plus
      # Onchain.Tempo.RPC.simulate/3, which the fee-payer pre-broadcast
      # simulation (MPP.Methods.Tempo) calls directly. Same cartouche-floor
      # reason, and three-segment for the same reason, as onchain above.
      {:onchain_tempo, "~> 0.9.0"},

      # ETS-based dedup store with TTL (ConCacheStore)
      {:con_cache, "~> 1.1.1"},

      # Self-describing APIs. Three-segment on purpose (caps at < 0.13.0):
      # descripex 0.12.0 changed `short_name` in describe/1 output from atom to
      # string at a *minor* bump, which the previous `~> 0.11` would have
      # absorbed silently. A 0.x package that breaks on minor earns the tighter
      # form; raise the cap deliberately after reading its CHANGELOG.
      {:descripex, "~> 0.12.0"}
    ]
  end

  defp description do
    """
    Elixir implementation of the Machine Payments Protocol (MPP) — HTTP 402
    payment middleware for AI agents and machine-to-machine commerce. Supports
    Stripe, Tempo, generic EVM, Solana, and NEAR Intents payment methods with
    pluggable architecture.
    """
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "MPP Spec" => "https://mpp.dev",
        "Changelog" => "#{@source_url}/blob/v#{@version}/CHANGELOG.md"
      }
    ]
  end

  # Exclude dev-only scaffolding from the 95% critical-tier coverage gate
  # (money/signing/wire-format). `Mix.Tasks.Mpp.Demo` is the dev demo-server
  # launcher — out of scope per SECURITY.md. `MPP.Application` now carries real
  # logic (starts the default dedup store) and is covered by application_test.exs.
  defp test_coverage do
    [ignore_modules: [Mix.Tasks.Mpp.Demo]]
  end

  defp dialyzer do
    [
      plt_add_apps: [
        :mix,
        :plug,
        :plug_crypto,
        :jason,
        :req,
        :telemetry,
        :descripex,
        :onchain,
        :onchain_tempo,
        :cartouche,
        :hieroglyph,
        :curvy,
        :ex_rlp,
        :con_cache
      ],
      plt_local_path: "_build/dialyzer",
      plt_core_path: "_build/dialyzer",
      ignore_warnings: ".dialyzer_ignore.exs"
    ]
  end

  defp docs do
    [
      main: "MPP",
      source_ref: "v#{@version}",
      source_url: @source_url,
      skip_code_autolink_to: [
        "MPP.Headers.SchemeSplitter",
        "MPP.Headers.parse_accept_payment/1",
        "MPP.Replay"
      ],
      extras: ["README.md", "CHANGELOG.md", "LICENSE", "SECURITY.md"]
    ]
  end

  defp aliases do
    [
      tidewave: [
        "run --no-halt -e 'Agent.start(fn -> Bandit.start_link(plug: Tidewave, port: 4008) end)'"
      ],
      # Fast inner-loop gate — seconds. Run after meaningful edits.
      "check.fast": [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict --ignore TagTODO,TagFIXME"
      ],
      # Manual / pre-handoff gate (NOT run by the commit hook). 95% cover —
      # MPP handles money, signing, and wire-format encoding (critical tier).
      precommit: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict --ignore TagTODO,TagFIXME",
        "doctor --raise",
        # preferred_envs (cli/0) is ignored for alias steps — set MIX_ENV via `env`
        # (Elixir 1.20's `mix cmd` no longer parses a leading VAR=val prefix).
        "cmd env MIX_ENV=test mix test.json --quiet --cover --cover-threshold 95 --exclude integration --exclude cross_validation",
        # --skip honors inline # sobelow_skip annotations (MPP is Plug-facing).
        "sobelow --skip --exit low"
      ],
      # CI mirror — folds the vibe_kit analyzer steps (clone detection + arch/smell
      # checks), the gated security audit, dialyzer, and the AGENTS.md freshness
      # check onto the precommit gate.
      "precommit.full": [
        "precommit",
        "ex_dna --max-clones 0",
        # --path lib pins the analysis scope. Reach otherwise auto-discovers roots
        # via `*/lib` + `*/src` wildcards (project.ex discovered_child_roots/2), which
        # picks up gitignored sibling checkouts (mpp-docs-fork/src) that do not exist
        # on a runner — so an unpinned smell gate would grade different file sets
        # locally and in CI.
        "reach.check --arch --smells --path lib",
        "dialyzer.json --quiet",
        # AGENTS.md is what the cross-family (codex/cursor/grok) reviewers read;
        # a stale render makes them gate against rules that already changed.
        "agents.check",
        # LAST on purpose: mix_audit signals a finding via System.stop(1), which is
        # asynchronous — it returns, the alias proceeds, and the concurrent VM
        # shutdown truncates whatever step ran next. Exit status stays non-zero
        # either way, but only a trailing position keeps the log readable.
        "deps.audit.gated"
      ],
      "check.dispatch": [
        "precommit.full"
      ],
      "mutation.security": "run test/mutation/security_campaign.exs",
      # Fails when AGENTS.md has drifted from CLAUDE.md. Compares rendered output,
      # not mtimes, so drift in a transitive @-import is caught too.
      "agents.check": [
        &agents_check/1
      ],
      # The project-scoped ignore has a package-range guard below, so raw
      # `mix deps.audit` must honor it just like the full gate does.
      "deps.audit": [
        "deps.audit --ignore-file .mix_audit_ignore"
      ],
      # mix_audit discards its sync exit status (mirego/mix_audit#61), so a frozen
      # — or entirely absent — advisory DB still reports green. Prove freshness
      # first, audit, then prove the mirror the audit actually read was populated.
      "deps.audit.gated": [
        &advisory_ignore_scope/1,
        &advisory_freshness/1,
        "deps.audit",
        &advisory_mirror_populated/1
      ],
      ci: ["precommit.full"]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Both gates below shell out to scripts that live OUTSIDE this repo, on the
  # developer host: the AGENTS.md renderer needs the claude-marketplace
  # checkout plus ~/.claude/includes, and the advisory-freshness prover needs
  # the local mix_audit mirror. Neither exists on a CI runner, and `mix cmd`
  # with an absent path exits non-zero — which aborted the whole `mix ci`
  # alias, and since these steps precede test.json/dialyzer it took the test,
  # coverage and dialyzer signal down with it. Skip loudly when the script is
  # absent so CI keeps running the checks it CAN run; the developer host and
  # the harness reviewer still get the full gate.
  @spec agents_check([String.t()]) :: :ok
  defp agents_check(_args) do
    host_script(
      "~/_DATA/code/claude-marketplace/scripts/sync-agents-md.sh",
      ["--check"],
      "AGENTS.md freshness check"
    )
  end

  @spec advisory_freshness([String.t()]) :: :ok
  defp advisory_freshness(_args) do
    host_script(
      "~/_DATA/code/onchain-stack/bin/advisory-freshness.sh",
      [],
      "advisory-mirror freshness check"
    )
  end

  # MixAudit.Repo hardcodes the mirror path (repo.ex path/0) with no env override,
  # while bin/advisory-freshness.sh honors MIX_AUDIT_ADVISORY_PATH. Diverging values
  # would prove freshness for a directory the audit never reads.
  @spec advisory_ignore_scope([String.t()]) :: :ok
  defp advisory_ignore_scope(_args) do
    case System.get_env("MIX_AUDIT_ADVISORY_PATH") do
      nil ->
        :ok

      override ->
        if Path.expand(override) != advisory_mirror_path() do
          Mix.raise("""
          MIX_AUDIT_ADVISORY_PATH is set to #{Path.expand(override)}, but mix_audit reads
          #{advisory_mirror_path()} (MixAudit.Repo.path/0 is hardcoded). The freshness proof
          and the audit would cover different mirrors — unset the variable or point it here.
          """)
        end
    end

    # `deps.audit --ignore-file` only takes advisory IDs, never a package scope, so
    # ignoring GHSA-w4f7-4cxr-rv3c for gun also silences it for cowboy — where it is
    # a genuine `< 2.16.0` vulnerability. Inert while no cowboy resolves; fail the
    # moment one enters the tree.
    if File.regular?("mix.lock") and String.contains?(File.read!("mix.lock"), ~s("cowboy":)) and
         String.contains?(File.read!(".mix_audit_ignore"), "GHSA-w4f7-4cxr-rv3c") do
      Mix.raise("""
      cowboy is now in mix.lock while .mix_audit_ignore still ignores GHSA-w4f7-4cxr-rv3c.
      That advisory genuinely affects cowboy < 2.16.0 — the ignore was scoped to gun only
      by the absence of cowboy. Confirm the resolved cowboy version is >= 2.16.0, then
      either drop the ignore (if the mirego importer split landed) or narrow it.
      """)
    end

    :ok
  end

  # A failed advisory clone leaves mix_audit with zero advisories and a passing
  # report (repo.ex synchronize/0 discards the git exit status). The freshness
  # script catches that on the developer host but does not exist on a runner, so
  # assert the mirror is populated after the audit ran — the only environment-neutral
  # proof that the audit had anything to match against.
  @spec advisory_mirror_populated([String.t()]) :: :ok
  defp advisory_mirror_populated(_args) do
    count =
      advisory_mirror_path()
      |> Path.join("packages/**/*.yml")
      |> Path.wildcard()
      |> length()

    if count < 50 do
      Mix.raise("""
      Advisory mirror at #{advisory_mirror_path()} holds #{count} advisories (expected 50+).
      mix_audit silently reports "No vulnerabilities found." when its clone/pull fails, so
      the audit that just ran proves nothing. Check network access to
      https://github.com/mirego/elixir-security-advisories.git and re-run.
      """)
    end

    :ok
  end

  @spec advisory_mirror_path() :: String.t()
  defp advisory_mirror_path do
    Path.join([System.user_home!(), ".local", "share", "elixir-security-advisories-mirego"])
  end

  @spec host_script(String.t(), [String.t()], String.t()) :: :ok
  defp host_script(path, args, label) do
    expanded = Path.expand(path)

    if executable?(expanded) do
      {_out, status} =
        System.cmd(expanded, args, into: IO.stream(:stdio, :line), stderr_to_stdout: true)

      if status != 0 do
        Mix.raise("#{label} failed (#{expanded} exited #{status})")
      end
    else
      # IO.puts, not Mix.shell().info/1: `dialyzer.json --quiet` installs
      # Mix.Shell.Quiet into Mix.State for the remainder of the run, whose info/1
      # is a no-op — the skip notice would vanish in exactly the CI run it exists for.
      IO.puts("[skip] #{label}: #{expanded} not executable (developer-host script, absent in CI).")
    end

    :ok
  end

  # File.exists?/1 is true for a directory and for a regular file with no +x bit;
  # System.cmd/3 then raises ErlangError :enoent and aborts the gate with a message
  # that names neither the skip path nor the intended failure label.
  @spec executable?(String.t()) :: boolean()
  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end
end
