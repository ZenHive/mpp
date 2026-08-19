# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

<!-- Selective-load floor (Opus 4.8): critical-rules is the eager guardrail floor;
     harness-workflow is the second eager include for this harness-registered repo;
     ethereum-rpc is a host-specific exception (no skill mirror) — MPP's EVM integration
     tests rely on the node/Sepolia env vars it documents. Everything else is reachable
     on demand as a skill (task-prioritization, task-writing, rmap, web-command,
     code-style, development-philosophy, development-commands, ex-unit-json, dialyzer-json,
     workflow-philosophy, elixir-volt, quickbeam, oxc, upstream-pr-workflow). -->
@~/.claude/includes/critical-rules.md
@~/.claude/includes/harness-workflow.md
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

mix ex_dna --max-clones 0          # clone detection (folded into precommit.full)
mix reach.check --arch --smells --path lib   # architecture/smell checks (folded into precommit.full)
mix deps.audit.gated               # advisory-freshness proof + deps.audit (folded into precommit.full)
mix ci                             # canonical gate = mix precommit.full (see "Toolchain & check commands")
```

## Toolchain & check commands

For cross-family reviewers (codex / cursor / grok) who don't inherit this repo's Claude Code hooks or skills:

- **Canonical gate:** `mix ci` (= `mix precommit.full`) — runs format-check, compile (warnings-as-errors), credo `--strict` (with the `ex_slop` plugin via `.credo.exs`), doctor, the test+cover gate (95% — MPP is critical-tier: money, signing, wire-format encoding), sobelow, then the vibe_kit analyzer steps `ex_dna --max-clones 0` (zero-tolerance clone detection) and `reach.check --arch --smells --path lib` (architecture/smell checks, policy in `.reach.exs`), dialyzer, `agents.check`, and finally `deps.audit.gated`. `mix precommit` is the same minus those trailing steps; `mix check.fast` is the seconds-long inner-loop (format + compile + credo).
- **`mix reach.check --arch --smells --path lib` gates from `.reach.exs`** (`smells: [strict: true]`). Smell findings must be **fixed, never added to an ignore list**. `--path lib` is load-bearing: reach otherwise auto-discovers roots via `*/lib` + `*/src` wildcards and picks up gitignored sibling checkouts (`mpp-docs-fork/src`) that don't exist on a CI runner, so the gate would grade different file sets locally and in CI.
- **`deps.audit.gated`** proves the local advisory mirror is fresh (`bin/advisory-freshness.sh` in the onchain-stack coordination home) before running `deps.audit --ignore-file .mix_audit_ignore`, and asserts the mirror is populated afterward — `mix_audit` silently discards its own sync failure, so a stale *or absent* mirror would otherwise report false-green (the freshness script is a developer-host script and skips on CI, which is exactly where the post-audit count matters). It also fails if `MIX_AUDIT_ADVISORY_PATH` diverges from `MixAudit.Repo`'s hardcoded path, and if `cowboy` enters `mix.lock` while `.mix_audit_ignore` still ignores `GHSA-w4f7-4cxr-rv3c` (the ignore file takes advisory IDs only, never a package scope, and that advisory is genuine for cowboy `< 2.16.0`).
- **`agents.check`** fails when `AGENTS.md` has drifted from this file (`sync-agents-md.sh --check`) — cross-family reviewers (codex/cursor/grok) read `AGENTS.md`, not this file directly.
- **`mix test.json` (`ex_unit_json`) and `mix dialyzer.json` (`dialyzer_json`) emit JSON by design** — parse it for real failures (`summary.result`, `coverage.threshold_met`, `warnings[]`); **never flag the JSON envelope itself as a build failure.** A non-empty JSON document on stdout is a *successful* run, not an error.
- When `dialyzer.json`'s encoder can't serialize a warning shape, **plain `mix dialyzer` is the authoritative dialyzer check.**
- Integration tests (`:integration` tag) and Tempo JS cross-validation tests (`:cross_validation` tag) are excluded from the gate. `:integration` requires live Moderato/Stripe/Sepolia credentials. `:cross_validation` requires a local JS toolchain (node + `ox` + `viem` npm packages + npx/esbuild for QuickBEAM bundles; see `test/mpp/tempo/cross_validation_test.exs`). Run explicitly with `mix test.json --include integration` or `mix test.json --include cross_validation`. The documented cold/offline check (`mix test.json --cover --exclude integration --exclude cross_validation`) succeeds on a fresh checkout with no gitignored node_modules. Excluded from the gate does not mean unexecuted: both tiers run nightly in their own workflows (`.github/workflows/integration.yml`, `.github/workflows/cross-validation.yml`), which supply the credentials and JS toolchain the gate deliberately does without.

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
MPP.Credential             — Credential parsing, challenge echo validation, payload extraction; hash_payload/1 + parse_hash_payload/1 for type="hash"
MPP.Receipt                — Receipt struct, base64url JSON serialization
MPP.Headers                — Parse/format WWW-Authenticate, Authorization, Payment-Receipt wire format (SchemeSplitter = internal multi-scheme boundary state machine)
MPP.AcceptPayment          — Accept-Payment client-preference header: parse/format/rank/apply_header
MPP.Hex                    — Internal hex-string helpers (strip_0x, hex_string?) shared across method/wire modules
MPP.Codec                  — Internal base64url→JSON decode (decode_base64_json) shared by credential/receipt/session_receipt
MPP.Methods.Shared         — Internal method-verification helpers (require_config, check_receipt_status, parse_charge_amount)
MPP.Errors                 — RFC 9457 problem types (paymentauth.org/problems/*), includes session error types
MPP.Intents.Charge         — Charge intent request schema (amount, currency, recipient, ...)
MPP.Intents.Session        — Session intent request schema (per-unit rate, unit_type, suggested_deposit, ...)
MPP.Session.Channel        — Session channel state, balance tracking, action wire mapping
MPP.Session.Voucher        — EIP-712 voucher typed data and signature verification
MPP.Session.Payload        — Session credential payload schema (open / voucher / topUp / close)
MPP.Session.Actions        — Session credential action handlers and per-channel balance updates
MPP.Session.Method         — use-wrapper that dispatches Method.verify/2 through session actions
MPP.Session.Store          — Behaviour for pluggable session-channel persistence
MPP.Session.ETSStore       — ETS-backed default session store (app-started)
MPP.BodyDigest             — SHA-256 body digest compute/verify for request body binding
MPP.Amount                 — Amount/decimals helpers: parse_units, with_base_units, parse_dollar_amount
MPP.JCS                    — RFC 8785 JSON Canonicalization Scheme (MPP subset: ASCII keys, no floats) for cross-SDK HMAC interop
MPP.Verifier               — Transport-neutral verification pipeline (HMAC, realm, expiry, request match, method.verify)
MPP.Method                 — Behaviour for pluggable payment methods (verify/2)
MPP.Methods.Stripe         — Stripe SPT → PaymentIntent verification (Req, no Stripe SDK); optional server-only Connect settlement routing
MPP.Methods.Tempo          — Tempo on-chain TIP-20 transfer verification (delegates chain ops to onchain_tempo)
MPP.Methods.Tempo.MachineToken — Canonical first-party machine-token (MPP Credits) charge-route match (approve + swapTo)
MPP.Methods.EVM            — Generic EVM on-chain transfer verification (any chain: Ethereum, Base, Polygon, etc.)
MPP.Methods.Tempo.SessionReceipt — Session-intent receipt for Tempo (to_header/from_header, camelCase wire keys)
MPP.Methods.Tempo.FeePayerPolicy — Sponsor gas-economics policy: bounds client gas fields before fee-payer co-sign (anti-drain)
MPP.Tempo.Store            — Behaviour for tx dedup stores (get/put + required atomic check_and_mark); default-on via Store.resolve/1, opt out with store: false
MPP.Tempo.ConCacheStore    — Built-in ETS dedup store with TTL via ConCache; app-started as the default store
MPP.Session.Channel        — Session channel state + contract-backed channel ID (keccak of identity fields)
MPP.Session.Voucher        — EIP-712 voucher typed data + secp256k1 signature verification
MPP.Session.Store          — Behaviour for pluggable session-channel persistence (get/put/update/delete)
MPP.Session.ETSStore       — App-started ETS default session store (atomic update/2 within one node)
MPP.Replay                 — Internal credential single-use dedup shared by the Plug and MCP transports (check_unused/mark_used, Tempo carve-out)
MPP.Plug                   — HTTP Plug middleware, delegates verification to MPP.Verifier
MPP.Plug.MethodEntry       — Per-method config within a multi-method endpoint (method, charge, request, method_config)
MPP.Plug.Config            — Validated endpoint config struct (shared settings + list of MethodEntry structs)
MPP.Mcp                    — MCP (JSON-RPC) transport: constants (-32042/-32602/-32043, meta keys), server transport adapter (init/1 + call/3 with replay dedup), server/client helpers
MPP.Client.PaymentProvider — Behaviour for client-side payment providers (supports?/3, pay/2)
MPP.Client.MultiProvider   — Multi-provider dispatch: wraps [{module, config}], routes to first match
MPP.Client.Providers.Tempo — Built-in Tempo charge provider: chain-pinned, attribution-bound TIP-20 payments
MPP.Client.Providers.Stripe — Built-in Stripe charge provider: Shared Payment Token creation
MPP.Client.SelectionPolicy — Transport-neutral challenge selection/ordering (default: server offer order)
MPP.Client.Req             — Payment-aware Req plugin: attach/2 intercepts 402, pays, retries
MPP.Client.Transport       — Transport behaviour: payment_required?/1, get_challenges/1, set_credential/2 + select_challenge/2 helper
MPP.Client.Transport.HTTP  — HTTP transport over Req: 402 detection, WWW-Authenticate parsing, Authorization: Payment attach
MPP.Client.Transport.MCP   — MCP/JSON-RPC transport: -32042 detection, error.data.challenges, params._meta credential attach
MPP.Client.MCP             — Payment-aware MCP client: SelectionPolicy, approval hook, MultiProvider pay, single retry
MPP.Demo.Method            — Toy payment method accepting "demo-token" (for mix mpp.demo)
MPP.Demo.Router            — Plug.Router demo server with protected /resource endpoint
```

### Design decisions

- **Stateless HMAC-bound challenges.** Challenge ID = `base64url(HMAC-SHA256(secret, realm|method|intent|request|expires|digest|opaque))`. No challenge store needed — the server recomputes and does constant-time comparison on verification.
- **Intent = Schema, Method = Implementation.** `MPP.Intents.Charge` and `MPP.Intents.Session` define the shared request schemas (amount, currency, recipient, …). `MPP.Method` implementations only handle verification. Methods accept either intent struct via `MPP.Method.intent()`.
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

Dev/test analysis stack (vibe_kit baseline, all `only: [:dev, :test], runtime: false`): `credo` (+ `ex_slop` plugin for AI-slop antipatterns, configured in `.credo.exs`), `dialyxir`, `ex_dna` (clone detection), `ex_ast` (structural search), `reach` (architecture/smell checks, policy in `.reach.exs`), plus `styler`, `sobelow`, `doctor`, `ex_unit_json`, `dialyzer_json`, `tidewave`.

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

A daily cloud routine (`sdk-delta-watch`, manage at https://claude.ai/code/routines) watches these SDKs for upstream changes we may need to port: it diffs new commits since the watermark in `.sdk-watch.json` (committed at repo root) over the protocol-critical paths, judges parity against our Elixir impl, and auto-files `security`-marked rmap tasks for genuine gaps (the pattern that caught mpp-rs #299 → Task 65 and mppx #577 → Task 46). If it filed tasks but couldn't run `rmap render` in the cloud env, run `rmap render` locally to re-sync ROADMAP.md.

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
- SDK index: https://mpp.dev/sdk — lists four official SDKs (TypeScript `mppx`, Python `pympp`, Rust `mpp-rs`, Go `mpp-go`) plus community SDKs (Elixir/ZenHive, Go/cp0x-org)
- Non-cloned SDKs (`pympp`, `mpp-go`, community `cp0x-org/mppx`) — fetch on demand via `gh repo view` / MCP / WebFetch when cross-referencing
- The `mpp` MCP server (`https://mpp.dev/api/mcp`, formerly `mcp__mpp__*`) is **no longer configured** in `.mcp.json` / `.cursor/mcp.json` / `.grok/config.toml`. Cross-reference SDK source from the local `refs/` clones (Read + OXC + QuickBEAM, above); use WebFetch for mpp.dev docs content.

### Upstream docs (mpp.dev)

The mpp.dev docs site ([tempoxyz/mpp](https://github.com/tempoxyz/mpp)) lists SDKs at https://mpp.dev/sdk in two tables: **Official** (mppx, pympp, mpp-rs, mpp-go) and **Community-Maintained** (our Elixir `mpp` via ZenHive, plus Go `mppx` by cp0x-org). Community entries were added via upstream [PR #502](https://github.com/tempoxyz/mpp/pull/502) on 2026-03-31. Our earlier [PR #473](https://github.com/tempoxyz/mpp/pull/473) (richer per-SDK pages under `/sdk/elixir`) was closed in favor of the community-table approach. If upstream opens the door to per-SDK pages again, revive from the `e-fu/mpp` fork.

### Conventions

- Styler is the formatter plugin (runs automatically via `mix format`)
- `test/support/` is compiled in test env (`elixirc_paths`)
- **Integration tests are mandatory.** Every payment method feature that makes RPC or API calls MUST have integration tests against the real service (Moderato testnet, Stripe test API, etc.). Unit tests with stubs only prove internal consistency — they cannot catch wrong request shapes, unexpected responses, or protocol mismatches. The Task 13g `eth_call` params bug proved this: all stub tests passed, but Moderato rejected the request. Tagged `:integration`, run with `mix test --include integration`.
- **🚨 Verify wire-format constants against the reference SDKs — don't trust your own tests.** Any hardcoded RLP field index, byte offset, length prefix, encoding/canonicalization assumption, or sentinel value (e.g. `MPP.Methods.Tempo.FeePayerPolicy`'s `@max_fee_index 2` / `@nonce_key_index 6` / `@valid_before_index 8`, JCS key ordering, HMAC input layout, `0x76` envelope positions) MUST be confirmed against the reference implementations — **`refs/mpp-rs/`** (Rust) and **`refs/mppx/`** (TypeScript), cross-checked when they agree — before it ships. The failure mode this prevents: a wrong constant whose unit tests still pass because the test fixture builder encodes the *same* wrong layout (the golden test ratifies the bug). Tests over a self-built fixture can't catch a constant that's wrong relative to the wire — only the reference SDK (or a live integration test against the real chain) can. Cite the `refs/…:line` evidence for the verdict. Pairs with the global `critical-rules.md` § "RESEARCH BEFORE ASSERTING ON NICHE TECHNICAL CLAIMS" (wire formats / protocol details) and the domain-ground-truth review seat.
- Spec source: `refs/mpp-specs/` (local) or [tempoxyz/mpp-specs](https://github.com/tempoxyz/mpp-specs)
- Reference impl: `refs/mppx/` (local) or [wevm/mppx](https://github.com/wevm/mppx) (TypeScript)
- Reference impl: `refs/mpp-rs/` (local) or [tempoxyz/mpp-rs](https://github.com/tempoxyz/mpp-rs) (Rust)

### Testing: three tiers of ground truth

Before writing tests for any module, ask **one question: what is ground truth for this code?** The trap all three tiers guard against is identical — *coverage green, reality wrong* — and a self-built fixture can never break that tie, because the golden test builds the fixture with the same wrong assumption it's meant to catch. Only reality (a live call) or an independent implementation (a reference SDK) can.

1. **Code that calls an external service** (Stripe API, chain RPC via `onchain`/`onchain_tempo`) → **the live endpoint is the only truth.** A mock encodes your *guess* of the response shape; it passes green while the real call 400s on a field you misremembered. Tag `:integration`, hit Moderato/Sepolia/Stripe-test. This is the "Integration tests are mandatory" bullet above — Task 13g's `eth_call` params bug is the proof (every stub passed, Moderato rejected the request).
2. **Code that must match a wire format or another implementation** (HMAC input layout, JCS ordering, RLP field indices, the MCP `_meta` envelope, error codes, fee-payer constants) → **the reference SDKs are truth, cross-checked when `mpp-rs` and `mppx` agree.** Tag `:cross_validation`, run via QuickBEAM/OXC against `refs/`. This is the "Verify wire-format constants" bullet above.
3. **Pure glue / transforms / adapters** (MCP transport shaping, header formatting) → no external truth, so fixtures are fine — but **derive the fixtures from tier 1 or 2** (a captured real response, a reference-SDK snapshot), never invent them.

**Operationalizing it:**
- **Explore then pin.** Hit reality *first* via Tidewave `project_eval`, observe the actual shape, *then* write the `:integration` test that asserts it, *then* mock only what you've now seen for the fast unit tests. A real call + one assertion is cheaper than a debug loop against a wrong mental model — integration tests are the time-*saver*, not the tax.
- **Tiers 1 and 2 stay out of the default `precommit.full` gate** (need live creds / JS toolchain) but run explicitly before landing anything touching those surfaces (`mix test.json --include integration` / `--include cross_validation`).
- **Never skip silently.** Missing creds → the test runs and `flunk()`s loudly with the exact `export` vars, not a green `:skip`. "0 failures" from 0 tests is a lie (global `critical-rules.md` § "NEVER HIDE TEST FAILURES").

## GitHub Check Routine

When asked to "check GitHub" (comments, PRs, security), sweep **all** of these surfaces — they are independent and a finding in one does not show up in the others:

```bash
gh pr list --state open                                          # open PRs
gh issue list --state open                                       # open issues
gh api repos/ZenHive/mpp/security-advisories \
  --jq '.[] | {ghsa: .ghsa_id, severity, state, summary}'        # 🚨 private vuln reports (PVR) — Security→Advisories tab
gh api repos/ZenHive/mpp/dependabot/alerts \
  --jq '.[] | select(.state=="open")'                            # vulnerable dependencies
gh api repos/ZenHive/mpp/code-scanning/alerts                    # CodeQL (if enabled)
gh api repos/ZenHive/mpp/secret-scanning/alerts                  # leaked secrets
```

**🚨 `security-advisories` is the one most easily missed and the highest-stakes.** Privately-reported vulnerabilities submitted through Private Vulnerability Reporting land **only** in the Security → Advisories tab — they do **NOT** appear as Dependabot alerts, code/secret-scanning alerts, or in the notifications inbox (advisory submissions email repo admins, they don't generate a `reason: security_alert` inbox item). The four scanning endpoints cover *automated* findings; `security-advisories` covers *human-reported* ones. **Always query it.** As of 2026-06, three reporter `kai-kka` gas-draining advisories (critical/high/medium) sat in `triage` for up to 12 days before being noticed precisely because earlier sweeps skipped this endpoint.

Triage states to act on: `triage` (new, unreviewed), `draft` (being worked). Reporter, PoC, and affected-version detail are at `gh api repos/ZenHive/mpp/security-advisories/<GHSA-id>`.

### Security-parity ledger + disclosure convention

`docs/security-parity.md` is the standing record of every upstream-SDK security advisory / fix mapped to our parity status (✓ have / 📋 tracked-in-Task-N). It and the `sdk-delta-watch` routine keep upstream security work *tracked*, not silently assumed. **🚨 Disclosure rule — this repo is public, so `tasks.toml` / `ROADMAP.md` / `docs/` are all published.** Therefore: a parity *gap* that is unfixed and exploitable is NEVER filed as a public `security` rmap task or a public ledger row — that would hand attackers a checklist for a deployed money library. Unfixed-gap detail goes to a **private draft GitHub security advisory** (Security → Advisories, the same channel inbound PVRs use); the public ledger holds only ✓/📋 rows plus a generic open-item count. When a fix ships, the item moves to a ✓ row and the advisory is published with the patched release (coordinated disclosure, per `SECURITY.md`). The `sdk-delta-watch` routine follows the same split: parity-confirmed → ✓ row; genuine gap → private advisory, never a public row.

## Git Commit Configuration

**Configured**: 2026-03-25

### Commit Message Format

**Format**: imperative-mood

#### Imperative Mood Template
```
<description>
```
Start with imperative verb: Add, Update, Fix, Remove, etc.
