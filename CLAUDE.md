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
@~/.claude/includes/agent-economy.md
@~/.claude/includes/elixir-patterns.md
@~/.claude/includes/elixir-setup.md
@~/.claude/includes/development-commands.md
@~/.claude/includes/ex-unit-json.md
@~/.claude/includes/dialyzer-json.md
@~/.claude/includes/library-design.md

## Project

MPP (Machine Payments Protocol) — Elixir library implementing HTTP 402 payment middleware for AI agents and machine-to-machine commerce. Built on the [MPP spec](https://github.com/tempoxyz/mpp-specs) co-developed by Stripe and Tempo Labs. Org: ZenHive.

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

### Key abstractions (planned)

- **Method behaviour** — pluggable payment methods (Stripe, x402/EVM, Tempo/stablecoins, Lightning). Each method knows how to create challenges and verify credentials.
- **Plug middleware** — the main integration point. Intercepts requests, issues 402 challenges, verifies payment credentials.
- **Challenge/Receipt** — structured data types for the 402 handshake.

### Dependencies

- `plug` — HTTP middleware framework (the integration surface)
- `jason` — JSON encoding/decoding for challenge/receipt payloads

### Conventions

- Styler is the formatter plugin (runs automatically via `mix format`)
- `test/support/` is compiled in test env (`elixirc_paths`)
- Binary IDs are not used (standard integer/auto IDs)
