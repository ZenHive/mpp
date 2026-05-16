defmodule MPP.MixProject do
  use Mix.Project

  @version "0.5.0"
  @source_url "https://github.com/ZenHive/mpp"

  def project do
    [
      app: :mpp,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
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
      {:plug, "~> 1.19.2"},
      {:jason, "~> 1.4.5"},
      {:req, "~> 0.5.17"},

      # Dev/test tooling
      {:ex_doc, "~> 0.40.2", only: :dev, runtime: false},
      {:styler, "~> 1.11.0", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7.18", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4.7", only: [:dev, :test], runtime: false},
      # TODO: bump doctor to 0.23.0 once onchain (and transitive decimal ~> 2.0) catches up to decimal ~> 3.1
      {:doctor, "~> 0.22.0", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14.1", only: [:dev, :test], runtime: false},
      {:ex_unit_json, "~> 0.4.3", only: [:dev, :test], runtime: false},
      {:dialyzer_json, "~> 0.2.0", only: [:dev, :test], runtime: false},
      {:tidewave, "~> 0.5.6", only: :dev},
      {:bandit, "~> 1.11.1", only: :dev},

      # Code analysis tools
      {:ex_dna, "~> 1.5.1", only: [:dev, :test], runtime: false},
      {:ex_ast, "~> 0.12.0", only: [:dev, :test], runtime: false},

      # JS tooling for dev/test (cross-referencing mppx TypeScript SDK, never production)
      # TODO: bump quickbeam to 0.10.12 (and npm to 0.7.x) once upstream relaxes its oxc ~> 0.12.1 constraint
      # quickbeam 0.10.5 pins npm ~> 0.6.0, so npm stays on 0.6.x until quickbeam moves
      {:quickbeam, "~> 0.10.5", only: [:dev, :test], runtime: false},
      {:oxc, "~> 0.13.0", only: [:dev, :test], runtime: false},
      {:npm, "~> 0.6.1", only: [:dev, :test], runtime: false},

      # On-chain verification (Tempo and EVM methods)
      {:onchain, "~> 0.5.4"},

      # Tempo chain primitives (Tempo method)
      {:onchain_tempo, "~> 0.2.1"},

      # ETS-based dedup store with TTL (ConCacheStore)
      {:con_cache, "~> 1.1.1"},

      # Self-describing APIs
      {:descripex, "~> 0.6.0"}
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
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      }
    ]
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
      extras: ["README.md", "CHANGELOG.md", "LICENSE"]
    ]
  end

  defp aliases do
    [
      tidewave: [
        "run --no-halt -e 'Agent.start(fn -> Bandit.start_link(plug: Tidewave, port: 4008) end)'"
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
