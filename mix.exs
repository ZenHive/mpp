defmodule MPP.MixProject do
  use Mix.Project

  @version "0.2.0"
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
      {:plug, "~> 1.16"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},

      # Dev/test tooling
      {:ex_doc, "~> 0.39", only: :dev, runtime: false},
      {:styler, "~> 1.4", only: [:dev, :test], runtime: false},
      # TODO: Using git branch as workaround for Credo 1.7.x crash on Elixir 1.20-rc multi-line sigils.
      # Switch back to hex {:credo, "~> 1.8"} when a compatible release is published.
      {:credo, github: "rrrene/credo", branch: "release/1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.22", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:ex_unit_json, "~> 0.4", only: [:dev, :test], runtime: false},
      {:dialyzer_json, "~> 0.1", only: [:dev, :test], runtime: false},
      {:tidewave, "~> 0.5", only: :dev},
      {:bandit, "~> 1.10", only: :dev},

      # Code analysis tools
      {:ex_dna, "~> 1.1", only: [:dev, :test], runtime: false},
      {:ex_ast, "~> 0.2", only: [:dev, :test], runtime: false},

      # JS tooling for dev/test (cross-referencing mppx TypeScript SDK, never production)
      {:quickbeam, "~> 0.5", only: [:dev, :test], runtime: false},
      {:oxc, "~> 0.5", only: [:dev, :test], runtime: false},
      {:npm, "~> 0.5", only: [:dev, :test], runtime: false},

      # On-chain verification (optional — required by Tempo method)
      {:onchain, "~> 0.4", optional: true},

      # Tempo chain primitives (optional — required by Tempo method)
      {:onchain_tempo, "~> 0.1", optional: true},

      # ETS-based dedup store with TTL (optional — used by ConCacheStore)
      {:con_cache, "~> 1.1", optional: true},

      # Self-describing APIs
      {:descripex, "~> 0.4"}
    ]
  end

  defp description do
    """
    Elixir implementation of the Machine Payments Protocol (MPP) — HTTP 402
    payment middleware for AI agents and machine-to-machine commerce. Supports
    Stripe and Tempo payment methods with pluggable architecture.
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
        :signet,
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
