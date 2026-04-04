defmodule Mix.Tasks.Mpp.Demo do
  @shortdoc "Start a local MPP demo server with a toy payment method"

  @moduledoc """
  Starts a local HTTP server demonstrating the full MPP 402 payment flow.

  No real payment credentials needed — a magic `"demo-token"` payload succeeds.

      mix mpp.demo
      mix mpp.demo --port 8080

  ## Options

    * `--port` — port to listen on (default: 4402)

  ## What It Does

  1. Starts a Bandit server with `MPP.Demo.Router`
  2. `GET /resource` returns a 402 challenge with `WWW-Authenticate: Payment`
  3. Retry with `Authorization: Payment <credential>` to get a 200 with `Payment-Receipt`
  4. The startup banner includes copy-paste curl commands

  ## Requirements

  Bandit must be available (it's a `:dev` dependency of mpp). If you're using
  mpp as a library dependency, add `{:bandit, "~> 1.10", only: :dev}` to your deps.
  """

  use Mix.Task

  alias MPP.Demo.Router

  @compile {:no_warn_undefined, Bandit}

  @default_port 4402

  @impl Mix.Task
  def run(args) do
    port = parse_port(args)
    check_bandit!()

    # Start required applications for HTTP serving
    Mix.Task.run("app.start")

    {:ok, _} = Bandit.start_link(plug: Router, port: port)

    print_banner(port)
    Process.sleep(:infinity)
  end

  # Verifies Bandit is available at runtime.
  defp check_bandit! do
    if !Code.ensure_loaded?(Bandit) do
      Mix.raise("""
      Bandit is required for mix mpp.demo but is not available.

      Add it to your deps:

          {:bandit, "~> 1.10", only: :dev}

      Then run: mix deps.get
      """)
    end
  end

  # Parses --port from CLI args. Raises on invalid values.
  defp parse_port(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, strict: [port: :integer])
    if invalid != [], do: raise_invalid_opts(invalid)
    Keyword.get(opts, :port, @default_port)
  end

  @spec raise_invalid_opts(list()) :: no_return()
  defp raise_invalid_opts(invalid) do
    bad = Enum.map_join(invalid, ", ", &format_invalid_opt/1)
    Mix.raise("Invalid option: #{bad}. Usage: mix mpp.demo [--port PORT]")
  end

  defp format_invalid_opt({k, nil}), do: k
  defp format_invalid_opt({k, v}), do: "#{k} #{v}"

  # Prints the startup banner with working curl commands.
  defp print_banner(port) do
    base_url = "http://localhost:#{port}"
    credential_header = build_credential_header()

    IO.puts("""

    ╔═══════════════════════════════════════════════════════╗
    ║  MPP Demo Server running on #{String.pad_trailing(base_url, 27)}║
    ╚═══════════════════════════════════════════════════════╝

    Try the full 402 payment flow:

    ── Step 1: Get a 402 challenge ──────────────────────────

      curl -si #{base_url}/resource | head -20

    ── Step 2: Pay and retry with credential ────────────────

      curl -s -H "Authorization: #{credential_header}" \\
        #{base_url}/resource | jq .

    ── Step 3: Check the Payment-Receipt header ─────────────

      curl -si -H "Authorization: #{credential_header}" \\
        #{base_url}/resource | head -20

    ── Other endpoints ──────────────────────────────────────

      curl -s #{base_url}/       # API info
      curl -s #{base_url}/health # Health check

    Press Ctrl+C to stop.
    """)
  end

  # Builds a pre-computed Authorization header value with a valid credential.
  defp build_credential_header do
    config = Router.mpp_config()
    entry = hd(config.method_entries)

    challenge =
      MPP.Challenge.create(
        [
          realm: config.realm,
          method: entry.method.method_name(),
          intent: "charge",
          request: entry.request
        ],
        config.secret_key
      )

    credential = %MPP.Credential{
      challenge: challenge,
      payload: %{"token" => "demo-token"}
    }

    MPP.Headers.format_credential(credential)
  end
end
