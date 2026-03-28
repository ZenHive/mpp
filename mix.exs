defmodule MPP.MixProject do
  use Mix.Project

  @version "0.1.1"
  @source_url "https://github.com/ZenHive/mpp"

  def project do
    [
      app: :mpp,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
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
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
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

      # On-chain verification (optional — required by Tempo and x402 methods)
      {:onchain, "~> 0.4", optional: true},

      # Self-describing APIs
      {:descripex, "~> 0.4"}
    ]
  end

  defp description do
    """
    Elixir implementation of the Machine Payments Protocol (MPP) — HTTP 402
    payment middleware for AI agents and machine-to-machine commerce. Supports
    Stripe, x402, and pluggable payment methods.
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
