# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

@~/.claude/includes/across-instances.md
@~/.claude/includes/critical-rules.md
@~/.claude/includes/task-prioritization.md
@~/.claude/includes/task-writing.md
@~/.claude/includes/web-command.md
@~/.claude/includes/code-style.md
@~/.claude/includes/development-philosophy.md
@~/.claude/includes/documentation-guidelines.md
@~/.claude/includes/ai-coder-docs.md
@~/.claude/includes/agent-economy.md
@~/.claude/includes/elixir-patterns.md
@~/.claude/includes/elixir-setup.md
@~/.claude/includes/development-commands.md
@~/.claude/includes/ex-unit-json.md
@~/.claude/includes/dialyzer-json.md
@~/.claude/includes/library-design.md
@~/.claude/includes/meta-development.md
@~/.claude/includes/workflow-philosophy.md
@~/.claude/includes/skills-awareness.md
@~/.claude/includes/quickbeam.md
@~/.claude/includes/oxc.md
@~/.claude/includes/cli-aliases.md
@~/.claude/includes/ethereum-rpc.md

## Project

MPP (Machine Payments Protocol) — Elixir library implementing HTTP 402 payment middleware for AI agents and machine-to-machine commerce. Built on the [MPP spec](https://github.com/tempoxyz/mpp-specs) co-developed by Stripe and Tempo Labs.

**Repo:** [ZenHive/mpp](https://github.com/ZenHive/mpp) | **Org:** ZenHive

Core idea: **payment is authentication.** No user accounts, no API keys. A client hits an endpoint, gets a 402 challenge with price + payment method, pays, and retries with an `Authorization: Payment` credential.

## Commands

```bash
mix test.json              # tests (AI-friendly JSON output)
mix test.json --failed     # re-run only failures
mix test path/to/file.exs  # single test file
mix test path/to/file.exs:42  # single test at line

mix dialyzer.json          # type checking (AI-friendly output)
mix credo --strict --format json  # static analysis
mix sobelow                # security scanner
mix doctor                 # docs/specs coverage

mix mpp.demo               # start demo server on port 4402 (--port to override)
mix format                 # auto-format (Styler runs as plugin)
mix docs                   # generate ExDoc
```

## Architecture

This is a **library** (not a Phoenix app). It provides Plug middleware that any Phoenix or Plug app can mount.

### Protocol flow (what this lib implements)

1. Request hits a protected resource
2. Server responds `402 Payment Required` with `WWW-Authenticate: Payment` header containing a challenge (price, accepted payment methods)
3. Client fulfills payment off-band (Stripe charge, on-chain tx, etc.)
4. Client retries with `Authorization: Payment <credential>` header
5. Server verifies payment, returns resource with `Payment-Receipt` header

### Module map

```
MPP                        — Root module, Discoverable entry point (describe/0-2 for progressive API discovery)
MPP.Challenge              — Challenge struct, HMAC-SHA256 ID binding, create/verify
MPP.Credential             — Credential parsing, challenge echo validation, payload extraction
MPP.Receipt                — Receipt struct, base64url JSON serialization
MPP.Headers                — Parse/format WWW-Authenticate, Authorization, Payment-Receipt
MPP.Errors                 — RFC 9457 problem types (paymentauth.org/problems/*), includes session error types
MPP.Intents.Charge         — Charge intent request schema (amount, currency, recipient, ...)
MPP.BodyDigest             — SHA-256 body digest compute/verify for request body binding
MPP.Amount                 — Amount/decimals helpers: parse_units, with_base_units, parse_dollar_amount
MPP.JCS                    — RFC 8785 JSON Canonicalization Scheme (MPP subset: ASCII keys, no floats) for cross-SDK HMAC interop
MPP.Verifier               — Transport-neutral verification pipeline (HMAC, realm, expiry, request match, method.verify)
MPP.Method                 — Behaviour for pluggable payment methods (verify/2)
MPP.Methods.Stripe         — Stripe SPT → PaymentIntent verification (Req, no Stripe SDK)
MPP.Methods.Tempo          — Tempo on-chain TIP-20 transfer verification (delegates chain ops to onchain_tempo)
MPP.Methods.EVM            — Generic EVM on-chain transfer verification (any chain: Ethereum, Base, Polygon, etc.)
MPP.Tempo.Store            — Behaviour for optional tx dedup stores (get/put + optional atomic check_and_mark)
MPP.Tempo.ConCacheStore    — Built-in ETS dedup store with TTL via ConCache (optional dep)
MPP.Plug                   — HTTP Plug middleware, delegates verification to MPP.Verifier
MPP.Plug.MethodEntry       — Per-method config within a multi-method endpoint (method, charge, request, method_config)
MPP.Plug.Config            — Validated endpoint config struct (shared settings + list of MethodEntry structs)
MPP.Mcp                    — MCP (JSON-RPC) transport: constants (-32042/-32043, meta keys), server/client helpers
MPP.Client.PaymentProvider — Behaviour for client-side payment providers (supports?/3, pay/2)
MPP.Client.MultiProvider   — Multi-provider dispatch: wraps [{module, config}], routes to first match
MPP.Demo.Method            — Toy payment method accepting "demo-token" (for mix mpp.demo)
MPP.Demo.Router            — Plug.Router demo server with protected /resource endpoint
```

### Design decisions

- **Stateless HMAC-bound challenges.** Challenge ID = `base64url(HMAC-SHA256(secret, realm|method|intent|request|expires|digest|opaque))`. No challenge store needed — the server recomputes and does constant-time comparison on verification.
- **Intent = Schema, Method = Implementation.** `MPP.Intents.Charge` defines the shared request schema (amount, currency, recipient). `MPP.Method` implementations only handle verification. All methods share the same intent structs.
- **Explicit credentials.** Per `library-design.md`: no `Application.get_env`, no ENV fallback. Pass `secret_key`, `realm`, `method` module, and pricing explicitly via Plug opts.
- **Per-route pricing via Plug opts.** Each route mounts `MPP.Plug` with its own amount/currency. No global pricing config.
- **Base64url encoding preserves original bytes.** Critical for HMAC verification — never re-serialize, always use the raw base64url string from the original challenge.
- **Server-only method_config.** `MPP.Plug` accepts `:method_config` (a map) for secrets like `stripe_secret_key`. Public fields go to the client via `challenge_method_details/1`; private fields are merged into `charge.method_details` at verify time only, never serialized into challenges.

### Protocol constants

| Constant | Value |
|----------|-------|
| Auth scheme | `Payment` |
| Challenge header | `WWW-Authenticate` |
| Credential header | `Authorization` |
| Receipt header | `Payment-Receipt` |
| Problem base URI | `https://paymentauth.org/problems/` |
| HMAC algorithm | HMAC-SHA256 |
| HMAC input separator | `\|` (pipe) |
| Encoding | base64url (no padding) |

### Tempo network chain IDs

| Network | Chain ID | RPC URL | Docs |
|---------|----------|---------|------|
| Tempo Mainnet | `4217` | `https://rpc.tempo.xyz` | [connection-details#mainnet](https://docs.tempo.xyz/quickstart/connection-details#mainnet) |
| Tempo Testnet (Moderato) | `42431` | `https://rpc.moderato.tempo.xyz` | [connection-details#testnet](https://docs.tempo.xyz/quickstart/connection-details#testnet) |

Our code defaults to `42431` (Moderato testnet) — see `@moderato_chain_id` in `MPP.Methods.Tempo`. README examples use `4217` (mainnet).

### Dependencies

- `plug` — HTTP middleware framework (the integration surface)
- `jason` — JSON encoding/decoding for challenge/receipt payloads
- `req` — HTTP client for payment method API calls (Stripe, etc.)
- `descripex` — Self-describing API metadata (`api()` macro, `Discoverable`)
- `onchain` — Ethereum RPC, address validation, and ERC-20 transfer parsing
- `onchain_tempo` — Tempo chain primitives: 0x76 transaction handling, TIP-20 calldata, Tempo RPC, TransferWithMemo event parsing
- `con_cache` — ETS-based TTL cache for `MPP.Tempo.ConCacheStore` dedup store
### JS/TS cross-referencing (dev/test only)

Three tools for verifying our implementation against the mppx TypeScript reference impl (`refs/mppx/`). **These are NEVER production dependencies.** MPP is a library — consumers must not pull in JS runtimes.

#### When to use what

| Question type | Tool | Example |
|---------------|------|---------|
| Understand logic/flow of one file | **Read** | "How does mppx's auth-param parser handle escapes?" |
| Structural query across files | **OXC** | "What functions does mppx export?" / "Who imports Challenge?" |
| Extract schemas/types to compare against our Elixir structs | **OXC** | "Do our Receipt fields match mppx's?" |
| Compliance check (do our error types match?) | **OXC** | Extract all mppx error URIs, compare against `MPP.Errors` |
| Verify runtime behavior matches | **QuickBEAM** | "Does mppx's HMAC produce the same output as ours for this input?" |
| Load ox/tempo for runtime cross-validation | **esbuild + QuickBEAM** | `MPP.Test.OxTempoBundle.load!(rt)` -- see below |
| Small file (<150 lines) | **Read** | Receipt.ts is 131 lines -- OXC adds overhead for no benefit |

#### Loading ox/tempo into QuickBEAM (esbuild pattern)

OXC's bundler can't produce clean IIFEs for packages with mixed ESM/CJS deps (like ox with @noble/*). Use **esbuild** instead:

```elixir
# In tests -- OxTempoBundle handles bundling + caching automatically
{:ok, rt} = QuickBEAM.start(apis: :browser)
MPP.Test.OxTempoBundle.load!(rt)
{:ok, result} = QuickBEAM.call(rt, "TxET.deserialize", ["0x76..."])
```

How it works:
- `test/support/ox_tempo_entry.mjs` -- thin entry importing `deserialize`/`serialize` from ox/tempo
- `test/support/ox_tempo_bundle.ex` -- shells out to `npx esbuild` with `--format=iife --platform=browser`
- Bundle cached to `_build/test/ox_tempo_bundle.js`, rebuilt when entry or ox version changes
- esbuild resolves all deps via ESM export conditions -- no scope collisions in QuickJS

#### OXC strengths and limitations

**OXC excels at:** cross-file function inventories (`OXC.collect` across all `src/*.ts`), import graph analysis (`OXC.imports/2`), schema field extraction from Zod objects, finding which functions use specific APIs (Base64, Hash, etc.).

**OXC struggles with:** complex AST node types your collection logic doesn't handle (SpreadElement, ConditionalExpression in object literals). When the JS uses patterns beyond simple properties, the collector crashes. Read doesn't have this problem.

**OXC comparison scripts need domain awareness:** OXC extracts mppx data perfectly, but comparing against our Elixir code requires understanding how we structure things (e.g., `@base_uri <> suffix` vs literal URI strings). Naive `String.contains?` misses these patterns.

#### How to use OXC (patterns that work)

```elixir
# Parse a file
{:ok, ast} = OXC.parse(File.read!("refs/mppx/src/Challenge.ts"), "Challenge.ts")

# Collect exported functions with arities
OXC.collect(ast, fn
  %{type: "ExportNamedDeclaration", declaration: %{type: "FunctionDeclaration", id: %{name: name}, params: params}} ->
    {:keep, {name, length(params)}}
  _ -> :skip
end)

# Extract z.object schema fields with required/optional
OXC.collect(ast, fn
  %{type: "CallExpression", callee: %{property: %{name: "object"}}, arguments: [%{type: "ObjectExpression", properties: props}]} ->
    fields = Enum.map(props, fn p ->
      key = Map.get(p.key, :name) || Map.get(p.key, :value)
      optional? = match?(%{callee: %{property: %{name: "optional"}}}, p.value)
      {key, if(optional?, do: :optional, else: :required)}
    end)
    {:keep, fields}
  _ -> :skip
end)

# Import graph (fast, no full parse)
{:ok, imports} = OXC.imports(File.read!("refs/mppx/src/Credential.ts"), "Credential.ts")
# => ["ox", "./Challenge.js", "./PaymentRequest.js"]

# Cross-file: find which functions touch Base64
for file <- ~w[Challenge.ts Credential.ts Receipt.ts] do
  source = File.read!("refs/mppx/src/#{file}")
  {:ok, ast} = OXC.parse(source, file)
  fns = OXC.collect(ast, fn
    %{type: "FunctionDeclaration", id: %{name: name}, body: body} ->
      if String.contains?(String.slice(source, body.start..body.end), "Base64"),
        do: {:keep, name}, else: :skip
    _ -> :skip
  end)
  if fns != [], do: IO.puts("#{file}: #{Enum.join(fns, ", ")}")
end
```

Run scripts with: `MIX_ENV=dev mix run /tmp/script.exs`

**Explore freely.** These patterns are starting points — try your own OXC queries against `refs/mppx/` to discover what works best for your specific question.

### First consumer

[api_cache](../api_cache/) is the first consumer — Phase 7, Tasks 47-51 in its roadmap. The Plug API must be mountable in a Phoenix router with per-route pricing. mpp has zero api_cache dependencies.

### Reference implementations (local clones)

Three reference repos are cloned into `refs/` (gitignored, auto-updated on session start via hook). **Read these directly — do NOT WebFetch from GitHub.**

```
refs/mpp-specs/   — IETF spec source (specs/, examples/)
refs/mppx/        — TypeScript SDK (primary reference). Key files in src/:
                    Challenge.ts, Credential.ts, Receipt.ts, Errors.ts,
                    Method.ts, PaymentRequest.ts
refs/mpp-rs/      — Rust SDK. Key files in src/: protocol/, client/, server/
```

Also available:
- IETF spec: https://paymentauth.org/
- Developer docs: https://mpp.dev/ (llms-full.txt for complete docs)
- MCP server at `.mcp.json` — `mcp__mpp__*` tools for cross-referencing SDK source code:
  - `search_source` / `read_source_file` / `get_file_tree` — work for **mppx**, **mpp-rs**, **pympp**, **tempo**
  - `list_pages` / `search_docs` — not functional (docs not indexed); use WebFetch for mpp.dev content
  - `mpp-specs` source — empty via MCP; use local `refs/mpp-specs/` instead

### Upstream docs (mpp.dev)

The mpp.dev docs site ([tempoxyz/mpp](https://github.com/tempoxyz/mpp)) lists official and community SDKs. Our Elixir SDK docs are added via [PR #473](https://github.com/tempoxyz/mpp/pull/473) — three pages (overview, core types, server) under `/sdk/elixir`. When releasing new versions with API changes, update the docs in the `e-fu/mpp` fork and open a follow-up PR.

### Conventions

- Styler is the formatter plugin (runs automatically via `mix format`)
- `test/support/` is compiled in test env (`elixirc_paths`)
- **Integration tests are mandatory.** Every payment method feature that makes RPC or API calls MUST have integration tests against the real service (Moderato testnet, Stripe test API, etc.). Unit tests with stubs only prove internal consistency — they cannot catch wrong request shapes, unexpected responses, or protocol mismatches. The Task 13g `eth_call` params bug proved this: all stub tests passed, but Moderato rejected the request. Tagged `:integration`, run with `mix test --include integration`.
- Spec source: `refs/mpp-specs/` (local) or [tempoxyz/mpp-specs](https://github.com/tempoxyz/mpp-specs)
- Reference impl: `refs/mppx/` (local) or [wevm/mppx](https://github.com/wevm/mppx) (TypeScript)
- Reference impl: `refs/mpp-rs/` (local) or [tempoxyz/mpp-rs](https://github.com/tempoxyz/mpp-rs) (Rust)

## Git Commit Configuration

**Configured**: 2026-03-25

### Commit Message Format

**Format**: imperative-mood

#### Imperative Mood Template
```
<description>
```
Start with imperative verb: Add, Update, Fix, Remove, etc.
