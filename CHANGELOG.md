# Changelog

All notable changes to this project will be documented in this file.

Per-task history (acceptance criteria, scoring, decision notes) lives in `roadmap/tasks.toml` — query with `rmap show <id>` or read `roadmap/data.json`. This file is curated release notes only.

---

## [Unreleased]

**Security (Tempo fee-payer gas draining).** When the server acts as fee payer it now validates the client-signed `0x76` envelope's gas economics **before** co-signing, closing two reported gas-draining vectors (GHSA-vv77-66rf-pm86, GHSA-qpxh-ff8m-c62v): unbounded `max_fee_per_gas`/`max_priority_fee_per_gas` and access-list padding. A new `MPP.Methods.Tempo.FeePayerPolicy` bounds `gas_limit`, `max_fee_per_gas`, `max_priority_fee_per_gas`, the `gas × max_fee_per_gas` total-fee budget, and rejects non-empty access lists. Cross-checking against the mppx and mpp-rs reference SDKs surfaced a further defense both enforce that we were missing — folded in here: the sponsored transaction must use the expiring nonce key and declare a `valid_before` that is in the future and within `max_validity_window_seconds` (default 15 min), so a client cannot hold a co-signed sponsorship broadcastable far into the future. All ceilings (gas economics + validity window) default to the reference-SDK values (per-chain; Moderato gets a higher priority-fee ceiling) and are overridable via `method_config["fee_payer_policy"]`. Safe-by-default — existing `fee_payer: true` deployments are protected without config changes. The remaining low-`gas_limit` revert vector (GHSA-vj8p-hp9x-gh47), which needs pre-broadcast simulation of the co-signed transaction, is tracked separately.

Dependency updates. Runtime: `req ~> 0.5.17` → `~> 0.6.1` (cascades transitive `finch ~> 0.17` → `~> 0.21/0.22`; MPP uses only the stable `Req.request/2` + `Req.Response`/`Req.Request` surface, no code changes). Dev/test JS tooling moved as a set now that quickbeam relaxed its constraints: `quickbeam 0.10.5` → `0.10.15`, `oxc ~> 0.13.0` → `~> 0.15.1`, `npm ~> 0.6.1` → `~> 0.7.4`; `ex_unit_json ~> 0.4.3` → `~> 0.5.0`; dev-only `bandit ~> 1.11.1` → `~> 1.12.0`.

On-chain stack advanced to the descripex-0.9 line: `descripex ~> 0.7.0` → `~> 0.9`, `onchain ~> 0.7.0` → `~> 0.8`, `onchain_tempo ~> 0.2.2` → `~> 0.3`. This required moving the whole ZenHive on-chain family (descripex, cartouche, onchain, onchain_tempo) together — descripex 0.8/0.9 add spec-derived JSON Schema and are additive, but descripex **0.9.1** was cut alongside to fix a `safe_convert` crash (it only rescued `ArgumentError`, so real-world specs like Cartouche's `%{required(non_neg_integer()) => <<_::256>>}` aborted the manifest/`describe` build with an uncaught `CaseClauseError`); cartouche 0.3.0 and onchain 0.8.0 relaxed their own descripex/hieroglyph floors to match. Compile clean under `--warnings-as-errors`; 601 offline tests green against the full updated chain, integration suite green.

## [0.5.1] - 2026-06-09

Dependency updates. Bumped the onchain stack to the 0.7.0 line: `onchain ~> 0.5.4` → `~> 0.7.0`, `onchain_tempo ~> 0.2.1` → `~> 0.2.2`, `descripex ~> 0.6.0` → `~> 0.7.0`. onchain 0.7.0 cascades a major `decimal` `2.4.1` → `3.1.1` jump (transitive only — MPP has no direct `Decimal` use) and pulls `cartouche 0.2.2`. Dev-tool `doctor` advanced `~> 0.22` → `~> 0.23` (0.23 requires `decimal ~> 3.1`, unblocked by the jump). No library code changes — compile clean under `--warnings-as-errors`, 601 offline tests green.

## [0.5.0] - 2026-05-15

Tempo session-receipt support and a client-side HTTP transport. Tempo integration tests now use `Onchain.Tempo.Faucet` for per-test fresh wallets instead of hardcoded keys, removing nonce coupling and unblocking a future move to async tests. `MPP.Client.Transport` behaviour with an HTTP implementation lands as the client-side counterpart to server-side `MPP.Method`, exposing a `select_challenge/2` helper that Task 33c (Req plugin) and Task 33d (MCP) will reuse. Dependency floors tightened: `onchain ~> 0.5`, `onchain_tempo ~> 0.2`. A second cross-SDK gap pass added Tasks 36–42 (Stellar Charge, Accept-Payment, EVM `credentialTypes`/Permit2/EIP-3009, Tempo SessionReceipt, OpenAPI discovery) to the roadmap.

## [0.4.0] - 2026-04-18

The first cross-SDK gap pass with substance. `MPP.Verifier` extracts the verification pipeline (HMAC, realm, expiry, request match, method.verify) out of `MPP.Plug` into a transport-neutral module, so MCP and future transports share the same correctness gate. `MPP.JCS` implements the RFC 8785 subset MPP needs for cross-SDK HMAC interop. The MCP transport (`MPP.Mcp`) lands with -32042/-32043 error codes and the `org.paymentauth/credential` + `org.paymentauth/receipt` `_meta` keys. Client-side gets `MPP.Client.PaymentProvider` behaviour and `MultiProvider` first-match dispatch. Protocol utilities fill in: `MPP.Headers.parse_challenges/1` (multi-challenge `WWW-Authenticate` parsing), `MPP.BodyDigest`, `MPP.Amount` (parse_units / with_base_units / parse_dollar_amount). Eight new RFC 9457 session error types added under `paymentauth.org/problems/session/`. EVM integration tests against Sepolia validate real RPC round-trips for both ERC-20 and native-ETH paths.

**Breaking:** `MPP.Amount.parse_dollar_amount/1` → `parse_dollar_amount/2` — callers now supply `decimals` explicitly. Neither mppx nor mpp-rs maintain a currency-to-decimals table; implicit inference was a correctness risk.

**Scope decision:** proxy/gateway functionality scoped out to a separate `mpp_proxy` package. The `mpp` library focuses on protocol correctness; the BEAM-native payment gateway is a separate product surface.

Dependency bumps: quickbeam 0.8.1 → 0.10.0, oxc 0.5.4 → 0.7.2, ex_dna 1.2.2 → 1.3.0, credo back to hex `~> 1.7` (upstream shipped the Elixir 1.20-rc multi-line sigil fix).

## [0.3.0] - 2026-04-03

Generic EVM payment method and the `onchain_tempo` extraction. `MPP.Methods.EVM` verifies hash-only credentials on any EVM chain (Ethereum, Base, Polygon, Arbitrum, …) — ERC-20 transfers via Transfer event log parsing, native ETH via tx value/recipient matching. Tempo chain primitives moved out of MPP into the standalone `onchain_tempo` Hex package; MPP delegates chain ops and keeps only the payment-protocol surface (dedup store, eth_call simulation, RFC 9457 error wrapping). `mix mpp.demo` ships an interactive Bandit server on port 4402 with a toy `demo-token` method and a pre-computed valid credential in the startup banner — zero-friction first experience. Read-only live-protocol integration tests against `mpp.dev/api/ping/paid` validate parser compatibility with the reference server. `MPP.Tempo.Store` moduledoc gained deployment-topology guidance (`ConCacheStore` for single-node / sticky routing; shared backend otherwise, with `fly-replay` as a worked example).

## [0.2.0] - 2026-03-28

The Tempo payment method (`MPP.Methods.Tempo`) — on-chain TIP-20 transfer verification with both `type="hash"` (client-broadcast) and `type="transaction"` (server-broadcast) credential paths. `transferWithMemo(address,uint256,bytes32)` matching enforced when `methodDetails.memo` is configured. Server-side fee sponsorship via 0x78 domain signing with whitelisted call-scope validation matching mppx's four allowed selector patterns. Optimistic broadcast mode (`wait_for_confirmation: false`) simulates the payment call via `eth_call`, broadcasts asynchronously, and returns an optimistic receipt without waiting for inclusion. `MPP.Tempo.Store` behaviour adds pluggable replay protection with `get`/`put` + optional atomic `check_and_mark/2`; built-in `MPP.Tempo.ConCacheStore` provides ETS-backed TTL dedup. `MPP.Plug`'s `:methods` option enables multi-method 402 endpoints with per-method pricing. All public functions gain Descripex `api()` annotations with `MPP.describe/0-2` progressive discovery and `mix mpp.manifest` for JSON API contract export. Bug fixes covered the TransferWithMemo `memo` indexed-topic discovery (via real Moderato receipts), v-value normalization for ox/tempo SDK interop, hash-path dedup ordering to avoid burning hashes on transient RPC failures, and crash protection in post-broadcast store paths.

## [0.1.0] - 2026-03-25

First public release. Core protocol — HMAC-SHA256-bound Challenge, Credential, Receipt, Headers (WWW-Authenticate / Authorization / Payment-Receipt), and RFC 9457 problem types under `paymentauth.org/problems/`. `MPP.Methods.Stripe` verifies PaymentIntents via SPT with idempotency, analytics metadata, and `Req.Test` mockability. `MPP.Plug` mounts in any Phoenix or Plug router with per-route pricing and explicit credential configuration — no `Application.get_env`, no ENV fallback.
