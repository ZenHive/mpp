# Changelog

All notable changes to this project will be documented in this file.

---

## [0.4.0] - 2026-04-18

### Dependency bumps

- `quickbeam` 0.8.1 → 0.10.0 (dev/test)
- `oxc` 0.5.4 → 0.7.2 (dev/test, unblocked by quickbeam 0.10's `~> 0.7` requirement — breaking: AST `:type`/`:kind` values are now snake_case atoms; no in-repo usage yet, so no code changes)
- `ex_dna` 1.2.2 → 1.3.0 (dev/test)
- `npm` 0.5.1 → 0.5.3 (dev/test, pulled in by quickbeam 0.10's `~> 0.5.2`)
- `credo` git `release/1.7` branch → hex `~> 1.7` (1.7.18) — upstream released the Elixir 1.20-rc multi-line sigil fix, so the git pin is no longer needed

### Task 24: Multi-Challenge Parsing

Added `parse_challenges/1` to `MPP.Headers` for parsing `WWW-Authenticate` headers containing multiple `Payment` challenges.

**What was built:**
- `MPP.Headers.parse_challenges/1` — splits multi-challenge header on scheme boundaries, returns `{:ok, [Challenge.t()]}` for all successfully parsed Payment challenges
- Scheme boundary detection finds all auth scheme tokens (not just Payment) to correctly segment mixed-scheme headers like `Bearer token, Payment id="a"..., Basic xyz, Payment id="b"...`
- Partial failure tolerance: if some Payment challenges parse and others fail, only successful ones are returned (matching mppx `deserializeList` semantics)

**Key decisions:**
- Boundary detection (not comma splitting) — commas inside quoted auth-param values are not splitters
- All scheme boundaries used as segment endpoints, but only Payment segments extracted — prevents non-Payment scheme text (e.g., `Basic xyz`) from polluting adjacent Payment segments
- `valid_scheme_start?` validates that a scheme match is at position 0 or preceded by a comma, preventing false matches inside quoted strings like `description="Payment plan"`
- Returns `:no_payment_challenges` error when no Payment schemes are found (distinct from individual parse errors)

**Unblocks:**
- Task 33b (HTTP client transport) — `parse_challenges/1` needed for extracting challenges from 402 responses

### Task 34: Verifier Extraction + JCS

Extracted the verification pipeline from `MPP.Plug` into a transport-neutral `MPP.Verifier` module. Added `MPP.JCS` for RFC 8785 JSON Canonicalization Scheme.

**What was built:**
- `MPP.JCS` — RFC 8785 canonical JSON (MPP subset: ASCII keys, string/integer/boolean/nil values). Floats rejected with `FunctionClauseError`. Matches mppx/mpp-rs output for all MPP protocol data
- `MPP.Verifier` — transport-neutral `verify/2` with the full verification pipeline: HMAC challenge binding, realm match, expiration, request match, method.verify. No Plug dependency
- `MPP.Plug` refactored to a thin HTTP adapter delegating to `MPP.Verifier`
- MCP `encode_request` updated from `Jason.encode!` to `JCS.canonicalize` (cross-SDK HMAC interop)

**Key decisions:**
- Verifier accepts keyword opts (`:secret_key`, `:realm`, `:method`, `:charge`, `:method_config`) rather than Plug types — zero coupling to HTTP transport
- Verifier always returns `{:ok, Receipt.t()} | {:error, Errors.t()}` with structured errors — callers never map error atoms to Errors themselves
- JCS implemented inline (~30 lines) rather than adding a dependency — the subset needed for MPP (ASCII keys, string/integer values) is trivial
- Dropped the `:request_serializer` option from the plan — JCS is mandatory per spec, not configurable. Both mppx and mpp-rs hardcode JCS canonicalization

**Unblocks:**
- Task 32b (MCP server transport) — can now use `MPP.Verifier` for JSON-RPC handler integration
- Task 33b (HTTP client transport) — transport-neutral verification pattern established

### Task 33a: Client PaymentProvider Behaviour

Client-side counterpart to server-side `MPP.Method` — where methods *verify* payment proof, providers *create* it.

**What was built:**
- `MPP.Client.PaymentProvider` behaviour with `supports?/3` and `pay/2` callbacks
- `MPP.Client.MultiProvider` struct wrapping `[{module, config}]` tuples with first-match dispatch
- Convenience functions on `PaymentProvider` for direct module delegation
- Descripex annotations on both modules, registered in `MPP.describe/0-2`

**Key decisions:**
- Config is explicit on every callback (no global state) — matches library design principle and enables multi-tenant usage
- `MultiProvider` is a concrete struct with its own API, not a behaviour implementation — avoids awkward arity clashes between behaviour callbacks and struct-based dispatch
- Provider ordering matters: first `supports?/3` match wins, matching mpp-rs `MultiProvider` semantics
- Error atom `:unsupported_payment_method` when no provider matches (mirrors mpp-rs `UnsupportedPaymentMethod`)

### Breaking: `parse_dollar_amount/1` → `parse_dollar_amount/2`

**`MPP.Amount.parse_dollar_amount` now requires explicit `decimals` parameter.**

Before: `parse_dollar_amount("$1.50")` — inferred decimals from currency code via internal ISO 4217 table.
After: `parse_dollar_amount("$1.50", 2)` — caller supplies decimals explicitly.

**Why:** Neither mppx (TypeScript) nor mpp-rs (Rust) reference implementations maintain a currency-to-decimals table. Both require the caller/server configuration to supply decimals explicitly. Our implicit inference created correctness risks (HUF/TWD classification is debatable) and diverged from the spec's "explicit configuration" philosophy. Flagged by Codex review.

### Codex Review Fixes (Tasks 25 & 26)

**Fixes:**
- `with_base_units/2` now accepts any intent struct with an `:amount` field, not just `Charge` — partially unblocks Task 29 (Session's `suggested_deposit` transform deferred to Task 29)
- BodyDigest `@moduledoc` clarifies map-path key-ordering caveat (matches mppx, no code change needed)

### Task 28: Session Error Types

Extended `MPP.Errors` with 8 new RFC 9457 problem types, cross-validated against mppx `Errors.ts`.

**What was built:**
- 7 session error types under `session/` URI prefix: `:insufficient_balance`, `:invalid_signature`, `:signer_mismatch`, `:amount_exceeds_deposit`, `:delta_too_small`, `:channel_not_found` (410), `:channel_closed` (410)
- 1 core error type: `:payment_action_required` for 3DS flows (402)

**Key decisions:**
- Channel errors (`:channel_not_found`, `:channel_closed`) use HTTP 410 Gone (not 402) matching mppx
- `:channel_closed` maps to URI suffix `session/channel-finalized` (matching mppx's `ChannelClosedError` which uses the "finalized" term in the URI)

### Task 25: Body Digest

`MPP.BodyDigest` — SHA-256 body digest computation and verification for request body binding.

**What was built:**
- `compute/1` — hashes string or map body, returns `"sha-256=<base64>"` (standard base64, no padding)
- `verify/2` — constant-time comparison via `Plug.Crypto.secure_compare/2`
- Maps are JSON-encoded before hashing (matching mppx behavior)

**Key decisions:**
- Standard base64 (not base64url) without padding — matches mppx `BodyDigest.compute()` output format
- Registered in `MPP.describe(:body_digest)` via Discoverable

### Task 26: Amount and Decimals Helpers

`MPP.Amount` — pure integer/string arithmetic for converting human-readable amounts to base units.

**What was built:**
- `parse_units/2` — "1.5" + 6 decimals → "1500000" (cross-validated against mpp-rs test vectors)
- `with_base_units/2` — applies `parse_units` to any intent struct's amount field
- `parse_dollar_amount/2` — "$1.50" + decimals → `{"150", "usd", 2}` with currency symbol detection ($, €, £, ¥) and suffix codes ("1.50 USD")

**Key decisions:**
- Caller supplies decimals explicitly (no currency-to-decimals inference) — matches mppx and mpp-rs design
- Zero allowed by both `parse_units/2` and `parse_dollar_amount/2` — zero-amount charges are valid for identity/proof flows (matches mpp-rs)
- No floating point anywhere — all arithmetic via string splitting and padding

### Task 32: MCP Types and Constants

MCP (Model Context Protocol) transport helpers for embedding MPP payment flows in JSON-RPC messages.

**What was built:**
- `MPP.Mcp` module with 4 spec constants (`-32042`, `-32043`, `org.paymentauth/credential`, `org.paymentauth/receipt`)
- Server helpers: `extract_credential/1`, `payment_required_error/1`, `verification_failed_error/2`, `attach_receipt/3`
- Client helpers: `payment_required?/1`, `extract_challenges/1`, `attach_credential/2`
- Full round-trip test: challenge → error → extract → credential → attach → receipt

**Key decisions:**
- Single `MPP.Mcp` module (not split into sub-modules) — matches mpp-rs single `mcp.rs` pattern, surface is small
- No new structs — reuses existing `Challenge`, `Credential`, `Receipt` types; MCP-specific shapes are plain maps matching JSON-RPC wire format
- MCP credentials are plain JSON maps in `_meta` (not base64url-encoded like HTTP transport) — helpers handle this difference transparently
- Challenge `to_map`/`from_map` kept private in this module — can be promoted to `MPP.Challenge` when Task 34 (Verifier extraction) creates a shared need

### Fix: MCP request field serialization and defensive parsing

Fixed two issues found via code review:

**MCP `request` field format** — The MCP transport spec requires `request` as a native JSON object, not base64url-encoded. `challenge_to_map` now decodes base64url→JSON on output, `challenge_from_map` re-encodes JSON→base64url on input. The internal `Challenge.request` remains base64url (needed for HMAC binding); the MCP module handles translation at the transport boundary.

**Defensive error handling** — `challenge_from_map` now validates required fields and returns `{:ok, challenge} | {:error, :invalid_challenge}` instead of raising `FunctionClauseError` on malformed input. Callers (`extract_challenges`, `credential_from_map`) propagate errors via `with`.

**Known limitation:** `encode_request` uses `Jason.encode!/1` (not JCS/RFC 8785) for the native JSON → base64url path. Safe for same-server round-trips but cross-implementation interop depends on Task 34 (JCS). Documented with TODO.

### Fix: MCP malformed input crash paths and spec accuracy (Codex review)

Four issues found via Codex code review, all verified and fixed:

**Crash on non-map/non-binary request** (High) — `encode_request/1` only handled maps and binaries. A peer-controlled MCP message with `"request": []` caused `FunctionClauseError`. Added catch-all clause returning `:invalid` sentinel, checked in `challenge_from_map`.

**Optional fields not type-validated** (Medium) — `description`, `digest`, `expires`, `opaque` were copied through without type checks. A malformed `"expires": {}` would be accepted then crash HMAC verification downstream. Added `validate_optional_strings/1` rejecting non-binary values.

**Inaccurate public specs** (Medium) — `extract_credential/1` and `extract_challenges/1` could return `{:error, :invalid_challenge}` but specs/docs only advertised narrower error sets. Updated `@spec`, `errors:`, and descriptions on both functions.

**Missing from Discoverable registry** (Low) — `MPP.Mcp` was documented in `lib/mpp.ex` moduledoc but not in the `Discoverable` modules list. `MPP.describe(:mcp)` now works.

### Proxy/Gateway Scoped to Separate Package (2026-04-04)

Reviewed proxy/gateway functionality in both reference SDKs (mppx `src/proxy/`, mpp-rs `src/proxy/`). Both ship proxy as a core module with pre-built service adapters (OpenAI, Anthropic, Stripe) and agent discovery (llms.txt, OpenAPI).

**Decision:** Proxy is a **product** (payment gateway), not a library feature. Scoped out to a separate `mpp_proxy` hex package that depends on `mpp`. This keeps `mpp` focused on protocol correctness (Phases 9-12) while `mpp_proxy` targets the "wrap any API → monetize it" use case. The BEAM is uniquely suited for a payment proxy — lightweight processes, per-connection fault isolation, hot code upgrades, built-in observability.

### Cross-SDK Gap Analysis (2026-04-04)

Audited mppx (TypeScript) and mpp-rs (Rust) reference implementations against our Elixir library. Expanded `ROADMAP.md` with new phases for protocol utilities, sessions, MCP, and client SDK, and renumbered payment method phases (Lightning, Solana, Card) from 9-11 to 13-15.

**Key gaps found:**
- No client-side SDK (server-only — can charge but not pay)
- No session/streaming payment intent (only charge)
- No MCP transport support (HTTP only)
- Missing protocol utilities: body digest, multi-challenge parsing, amount helpers, expiration/DID helpers
- Missing 8 session-specific RFC 9457 error types

**Key decision:** Protocol completeness (Phases 9-12) prioritized over new payment methods (Phases 13-15). Both mppx and mpp-rs have explicit transport-neutral core architecture — confirmed this pattern as the target for our client SDK design.

### EVM Integration Tests

Added integration tests for `MPP.Methods.EVM` against Sepolia testnet — validates real RPC round-trips that unit stubs can't catch.

**What was built:**
- `test/mpp/methods/evm_integration_test.exs` — 10 tests covering direct `verify/2` and full 402 Plug handshake
- ERC-20 path: wraps ETH → WETH via `deposit()`, transfers to recipient, verifies via Transfer log parsing
- Native ETH path: sends ETH to recipient, verifies via transaction value/recipient matching
- Error cases: wrong amount, wrong recipient, non-existent tx hash
- Full 402 flow: challenge parsing, credential submission, receipt verification, Payment-Receipt header

**Key decisions:**
- Sepolia (not Tempo Moderato) — proves EVM method works on a vanilla EVM chain, not just Tempo infrastructure
- WETH for ERC-20 tests — wrapping ETH guarantees token balance without external faucets
- Fixed inaccurate RPC comment — Onchain.RPC uses Signet → Finch, not Req; that's the real reason EVM uses Req directly

---

## [0.3.0] - 2026-04-03

### Task 14: Generic EVM Method

On-chain payment verification for any EVM chain (Ethereum, Base, Polygon, Arbitrum, etc.).

**What was built:**
- `MPP.Methods.EVM` — generic EVM payment method implementing `MPP.Method` behaviour
- Hash-only credential path: client broadcasts tx, sends hash, server verifies receipt
- ERC-20 transfers verified via Transfer event log parsing (`Onchain.Transfer.parse_logs/1`)
- Native ETH transfers verified via transaction value + recipient matching
- Currency convention: ERC-20 tokens use contract address; native ETH uses `"ETH"` or zero address

**Key decisions:**
- Hash-only verification (no signed-tx broadcast path) — simpler, universally works across all EVM chains without chain-specific transaction types. Signed-tx broadcast can be added later if needed.
- RPC calls via Req directly — Onchain.RPC delegates to Signet → Finch, bypassing Req entirely; using Req enables Req.Test stubbing for unit tests
- No dedup store — hash-only path is inherently idempotent (same receipt verification produces same result)
- Chain ID is optional in method_config — included in challenge details when configured so client knows which chain to use

### Store Deployment Strategies

Added deployment topology guidance to `MPP.Tempo.Store` moduledoc — documents when `ConCacheStore` is sufficient (single node, sticky routing) vs when a shared backend is needed (multi-node without sticky routing). Includes Fly.io `fly-replay` as a concrete example of cookie-based sticky sessions.

### Task 18: Live Protocol Integration Tests

Read-only integration tests against the live `mpp.dev/api/ping/paid` endpoint, validating protocol compatibility with the reference MPP server.

**What was built:**
- `test/mpp/integration/mpp_dev_test.exs` — verifies client-side parsing against a real 402 Tempo challenge
- Covers: 402 response structure, challenge parsing via `Headers.parse_challenge/1`, challenge field validation, charge request decoding via `Charge.from_request/1`, RFC 9457 error body format, and challengeId cross-validation between body and header

**Key decisions:**
- Read-only tests only (no wallet/payment required) — validates parsing without needing Tempo credentials
- Each test fetches a fresh 402 to avoid challenge expiration (5-minute window)
- Validates protocol invariants (non-empty realm, integer chainId, Ethereum-style recipient address) rather than deployment-specific values
- Uses `Req.get/1` with proper error handling (network failures flunk with actionable messages)

### Task 17: mix mpp.demo

Interactive demo server for exploring the MPP 402 payment flow without real payment credentials.

**What was built:**
- `MPP.Demo.Method` — toy payment method accepting `"demo-token"` as magic payload
- `MPP.Demo.Router` — Plug.Router with protected `/resource` endpoint, welcome page, and healthcheck
- `Mix.Tasks.Mpp.Demo` — `mix mpp.demo` starts a Bandit server on port 4402 (configurable via `--port`), prints copy-paste curl commands with a pre-computed valid credential

**Key decisions:**
- Fixed HMAC secret key (`"mpp-demo-secret-key"`) enables pre-computing a valid credential for the startup banner — zero-friction first experience
- Port 4402 chosen as memorable (HTTP 402 is the protocol's status code)
- Runtime check for Bandit (`:dev` only dep) with actionable error message
- `challenge_method_details/1` returns `%{"acceptedTokens" => ["demo-token"]}` so agents/clients know what payload to send

### Task 23: onchain_tempo Extraction

Extracted Tempo chain primitives from mpp into the standalone `onchain_tempo` package. MPP now depends on `onchain_tempo` (optional, Hex.pm) and delegates chain operations instead of implementing them directly.

**What moved out:**
- `MPP.Tempo.Transaction` → `Onchain.Tempo.Transaction` (deserialize, payment matching, fee payer co-signing)
- `MPP.Test.TempoTxBuilder` → `Onchain.Tempo.Transaction.Builder` (build + sign 0x76 transactions)
- `MPP.Test.TempoTestHelpers` calldata functions → `Onchain.Tempo.TIP20` (selectors, ABI encoding)
- Broadcast functions (`broadcast_transaction_async/3`, `broadcast_transaction_sync/3`) → `Onchain.Tempo.RPC`
- `parse_transfer_with_memo_logs/1` → `Onchain.Tempo.Transfer`

**What stays in mpp:**
- `MPP.Methods.Tempo` — verify/2, challenge_method_details/1, dedup store, Plug error wrapping
- `MPP.Tempo.Store` behaviour + `MPP.Tempo.ConCacheStore` — payment-protocol replay protection
- `simulate_payment_call` — MPP-specific eth_call simulation
- `MPP.Test.TempoTestHelpers` reduced to thin hex-input wrappers over `Onchain.Tempo.TIP20`

**Key decisions:**
- RPC adapter functions bridge onchain_tempo's `{:error, string}` to MPP's `{:error, Errors.t()}` RFC 9457 format
- `onchain` and `onchain_tempo` remain published Hex.pm dependencies
- Test error message assertions updated to match onchain_tempo's generic RPC error format

---

## [0.2.0] - 2026-03-28

### Features

- **Tempo payment method** (`MPP.Methods.Tempo`) — on-chain TIP-20 transfer verification via Tempo's JSON-RPC, supporting both `type="hash"` (client-broadcast) and `type="transaction"` (server-broadcast) credential paths
- **TransferWithMemo support** — memo matching for `transferWithMemo(address,uint256,bytes32)` calls, enforced per spec when `methodDetails.memo` is configured
- **Fee payer co-signing** — server-side fee sponsorship for `feePayer: true` with 0x78 domain signing and call scope validation (whitelist of 4 allowed selector patterns matching mppx `callScopes`)
- **Optimistic broadcast mode** — `wait_for_confirmation: false` simulates payment call via `eth_call` then broadcasts asynchronously, returning an optimistic receipt without waiting for block inclusion
- **Transaction dedup store** (`MPP.Tempo.Store` behaviour) — pluggable replay protection with `get/1`, `put/2`, and optional atomic `check_and_mark/2` callbacks; different dedup semantics per credential path (hash: post-verification mark; transaction: pre-broadcast reservation)
- **Built-in ConCacheStore** (`MPP.Tempo.ConCacheStore`) — ETS-based dedup store with automatic TTL via ConCache (optional dep), configurable TTL and check interval
- **Multi-method 402 endpoints** (`MPP.Plug` `:methods` option) — multiple payment methods per route with per-method pricing, credential routing via echoed challenge method field, backwards-compatible with single-method config
- **Descripex annotations** — `api()` macros on all public functions with `MPP.describe/0-2` progressive discovery and `mix mpp.manifest` for JSON API contract generation

### Bug Fixes

- **TransferWithMemo event signature** — `memo` parameter is `indexed` (topic, not data field), discovered via real Moderato receipts
- **v-value normalization** — `recover_sender/2` now normalizes legacy v-values (27/28) to recid (0/1) for ox/tempo SDK interop
- **Empty calls rejection** — `extract_calls/2` returns error for empty call lists, matching ox/tempo's `CallsEmptyError`
- **Optimistic multicall simulation target** — `eth_call` now targets the matched payment call, not the first call in the batch
- **Hash path dedup** — hash path no longer burns hashes on transient RPC failures (check → verify → mark, matching mppx)
- **Non-atomic store fallback** — sequential `get` + `put` fallback now propagates `put/2` errors instead of unconditionally returning `:ok`
- **Post-broadcast store crash protection** — `safe_dedup_post_broadcast` catches process exits alongside rescued exceptions

### Test Infrastructure

- **Moderato integration tests** — real testnet tests for hash path, transaction path, fee payer co-signing, optimistic broadcast, memo matching, challenge expiration, and dedup store
- **ox/tempo cross-validation** — runtime cross-validation of 0x76 RLP encoding via QuickBEAM + esbuild bundle against ox/tempo TypeScript SDK
- **Full-flow stub suite** — `Req.Test`-based pipeline tests covering the complete 402 → credential → verify → receipt flow
- **TempoTxBuilder** — test support module for constructing and signing real 0x76 Tempo Transactions (later extracted to `Onchain.Tempo.Transaction.Builder`)

---

## [0.1.0] - 2026-03-25

First public release with core protocol and Stripe payment method.

- **Core protocol** — Challenge (HMAC-SHA256 bound), Credential, Receipt, Headers (WWW-Authenticate/Authorization/Payment-Receipt), Errors (RFC 9457 problem types)
- **Stripe payment method** (`MPP.Methods.Stripe`) — PaymentIntent verification via SPT with idempotency, analytics metadata, and `Req.Test` mockability
- **Plug middleware** (`MPP.Plug`) — mount in any Phoenix/Plug router with per-route pricing and explicit credential configuration
- **Stripe integration tests** — real Stripe test mode API with full 402 handshake
