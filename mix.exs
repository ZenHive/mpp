defmodule MPP.MixProject do
  use Mix.Project

  @version "0.6.1"
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
        "dialyzer.json": :dev
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
      # TODO: Uncomment mod if MPP ever needs supervised processes (currently stateless)
      # mod: {MPP.Application, []}
    ]
  end

  defp deps do
    [
      {:plug, "~> 1.19"},
      {:jason, "~> 1.4.5"},
      {:req, "~> 0.6.1"},

      # Dev/test tooling
      {:ex_doc, "~> 0.40.2", only: :dev, runtime: false},
      {:styler, "~> 1.11.0", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7.18", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4.7", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.23.0", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14.1", only: [:dev, :test], runtime: false},
      {:ex_unit_json, "~> 0.6.0", only: [:dev, :test], runtime: false},
      {:dialyzer_json, "~> 0.2.0", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.0", only: [:dev, :test]},
      {:tidewave, "~> 0.6", only: :dev},
      {:bandit, "~> 1.12.0", only: :dev},

      # Code analysis tools (vibe_kit baseline: credo + ex_slop, ex_dna, reach)
      {:ex_dna, "~> 1.5.1", only: [:dev, :test], runtime: false},
      {:ex_ast, "~> 0.12.0", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.7", only: [:dev, :test], runtime: false},

      # JS tooling for dev/test (cross-referencing mppx TypeScript SDK, never production)
      {:quickbeam, "~> 0.10.16", only: [:dev, :test], runtime: false},
      {:oxc, "~> 0.16", only: [:dev, :test], runtime: false},
      {:npm, "~> 0.7.4", only: [:dev, :test], runtime: false},

      # On-chain verification (Tempo and EVM methods) — 0.10 for the
      # Onchain.RPC surface the EVM method delegates to.
      {:onchain, "~> 0.10"},

      # Tempo chain primitives (Tempo method) — 0.7 for the sender-recovery +
      # Onchain.Tempo.RPC.simulate/3 primitives the fee-payer pre-broadcast
      # simulation (MPP.Methods.Tempo) calls directly.
      {:onchain_tempo, "~> 0.7"},

      # ETS-based dedup store with TTL (ConCacheStore)
      {:con_cache, "~> 1.1.1"},

      # Self-describing APIs
      {:descripex, "~> 0.9"}
    ]
  end

  defp description do
    """
    Elixir implementation of the Machine Payments Protocol (MPP) — HTTP 402
    payment middleware for AI agents and machine-to-machine commerce. Supports
    Stripe, Tempo, and generic EVM payment methods with pluggable architecture.
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

  # Exclude inert/dev-only scaffolding from the 95% critical-tier coverage gate
  # (money/signing/wire-format). `MPP.Application` is an unwired boot stub (`mod:`
  # is commented out below); `Mix.Tasks.Mpp.Demo` is the dev demo-server launcher.
  # Both are out of scope per SECURITY.md — they don't belong in the money-path signal.
  defp test_coverage do
    [ignore_modules: [MPP.Application, Mix.Tasks.Mpp.Demo]]
  end

  defp dialyzer do
    [
      plt_add_apps: [
        :mix,
        :plug,
        :plug_crypto,
        :jason,
        :req,
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
        "cmd env MIX_ENV=test mix test.json --quiet --cover --cover-threshold 95 --summary-only --exclude integration",
        # --skip honors inline # sobelow_skip annotations (MPP is Plug-facing).
        "sobelow --skip"
      ],
      # CI mirror — folds the vibe_kit analyzer steps (clone detection + arch/smell
      # checks) and dialyzer onto the precommit gate.
      "precommit.full": [
        "precommit",
        "ex_dna --max-clones 0",
        "reach.check --arch --smells",
        "dialyzer.json --quiet"
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
