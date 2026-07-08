# MPP Roadmap

**Vision:** First Elixir implementation of the Machine Payments Protocol — HTTP 402 payment middleware that turns any Phoenix API into an agent-billable service. No accounts, no API keys. Payment is authentication.

**Completed work:** See [CHANGELOG.md](CHANGELOG.md) for finished tasks.

**Spec:** [tempoxyz/mpp-specs](https://github.com/tempoxyz/mpp-specs) | **Reference impl:** [tempoxyz/mpp-rs](https://github.com/tempoxyz/mpp-rs)

---

> **Philosophy reminder:** This is a library, not an app. Explicit credentials, no global config, no ENV fallback. Per-route pricing via Plug opts. Stateless HMAC-bound challenges.

<!-- FOCUS:BEGIN -->
**Focus phase:** 9 — Protocol Utilities (31 of 31 done · 0 in progress)

**Last shipped:** Task 72 — Parse-time input validation parity for challenge/credential, Task 73 — Extract shared helpers and split MPP.Headers (mechanical refactor), Task 74 — Docs hygiene: README modules, ROADMAP focus, SECURITY version, Task 75 — Presenter-identity binding for Tempo hash-credential path (close GHSA-34g7-vx6g-82mq residual) on 2026-07-08

**Up next:** Task 32b — MCP server transport [D:3/B:7/U:8 → Eff:2.5] 🎯
<!-- FOCUS:END -->

---

## Phase 1: Core Protocol ✅

> 8 tasks complete (v0.1.0). Challenge, Credential, Receipt, Headers, Errors, Charge intent, Method behaviour, Plug middleware.

<!-- TASKS:BEGIN phase=1 -->
> 9 tasks. See [CHANGELOG.md](CHANGELOG.md#phase-1-core-protocol).
<!-- TASKS:END -->

---

## Phase 2: Stripe Payment Method ✅

> 2 tasks complete (v0.1.0). Stripe SPT verification + integration tests against Stripe test API.

<!-- TASKS:BEGIN phase=2 -->
> 4 tasks. See [CHANGELOG.md](CHANGELOG.md#phase-2-stripe-payment-method).
<!-- TASKS:END -->

---

## Phase 3: Descripex + Local Discovery ✅

> 2 tasks complete (v0.2.0). `api()` annotations on all public functions, `MPP.describe/0-2`, and `mix mpp.manifest` for local discovery/manifest generation.

<!-- TASKS:BEGIN phase=3 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 11 | ✅ | 🎁 **descripex** · Descripex annotations [D:3/B:7/U:8 → Eff:2.5?] 🎯 |
| Task 12 | ✅ | 🎁 **descripex** · mix mpp.manifest [D:2/B:6/U:7 → Eff:3.25?] 🎯 |
| Task 42 `[P]` | ⬜ | 🎁 **discovery** · OpenAPI discovery document generation [D:4/B:7/U:8 → Eff:1.88?] 🚀 |
<!-- TASKS:END -->

---

## Phase 4: Tempo Payment Method ✅

> 8 tasks complete (v0.2.0). Hash + transaction credential paths, fee payer co-signing, optimistic broadcast, dedup store, ConCacheStore, integration tests against Moderato testnet, ox/tempo cross-validation.

<!-- TASKS:BEGIN phase=4 -->
> 5 tasks. See [CHANGELOG.md](CHANGELOG.md#phase-4-tempo-payment-method).
<!-- TASKS:END -->

---

## Phase 5: EVM Payment Method ✅

<!-- TASKS:BEGIN phase=5 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 14 | ✅ | 🎁 **evm** · Generic EVM method [D:6/B:7/U:6 → Eff:1.08?] 📋 |
| Task 38 `[P]` | ⬜ | 🎁 **evm** · EVM credentialTypes backfill [D:3/B:5/U:6 → Eff:1.83?] 🚀 |
<!-- TASKS:END -->

---

## Phase 6: Multi-Method Challenges ✅

> 1 task complete (v0.2.0). Multiple payment methods per endpoint with per-method pricing and credential routing.

<!-- TASKS:BEGIN phase=6 -->
> 1 task. See [CHANGELOG.md](CHANGELOG.md#phase-6-multi-method-challenges).
<!-- TASKS:END -->

---

## Phase 7: Hex Publish ✅

> v0.1.0 published to Hex (2026-03-25). v0.2.0 published (2026-03-28). v0.3.0 published (2026-04-03). v0.4.0 published (2026-04-18) — Phase 9 utilities (BodyDigest, Amount, JCS, Verifier, multi-challenge), Phase 10 session error types, Phase 11 MCP types, Phase 12 PaymentProvider behaviour.

<!-- TASKS:BEGIN phase=7 -->
> 1 task. See [CHANGELOG.md](CHANGELOG.md#phase-7-hex-publish).
<!-- TASKS:END -->

---

## Phase 8: Developer Experience

<!-- TASKS:BEGIN phase=8 -->
> 2 tasks. See [CHANGELOG.md](CHANGELOG.md#phase-8-developer-experience).
<!-- TASKS:END -->

---

## Phase 9: Protocol Utilities

> Cross-SDK gap analysis (2026-04-04) identified missing protocol features in mppx and mpp-rs that our library lacks. These are small, independent modules — all `[P]` parallelizable.

<!-- TASKS:BEGIN phase=9 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 24 | ✅ | 🎁 **utilities** · Multi-challenge parsing [D:3/B:7/U:7 → Eff:2.33?] 🎯 |
| Task 25 | ✅ | 🎁 **utilities** · Body digest [D:2/B:6/U:5 → Eff:2.75?] 🎯 |
| Task 26 | ✅ | 🎁 **utilities** · Amount and decimals helpers [D:2/B:6/U:6 → Eff:3.0?] 🎯 |
| Task 27 `[P]` | ✅ | 🎁 **utilities** · Expiration and DID helpers [D:2/B:4/U:5 → Eff:2.25?] 🎯 |
| Task 34 | ✅ | 🎁 **utilities** · Verifier extraction + JCS [D:4/B:9/U:10 → Eff:2.38?] 🎯 |
| Task 35 `[P]` | ✅ | 🎁 **utilities** · Generic dedup at Plug level [D:3/B:7/U:7 → Eff:2.33?] 🎯 |
| Task 37 `[P]` | ✅ | 🎁 **utilities** · Accept-Payment header support [D:3/B:6/U:7 → Eff:2.17?] 🎯 |
| Task 45 | ✅ | 🎁 **utilities** · Tier-2 pinned-field verification [D:4/B:8/U:7 → Eff:1.88?] 🚀 |
| Task 46 | ✅ | 🎁 **utilities** · Tempo + session hardening audit vs. latest reference impls [D:5/B:8/U:7 → Eff:1.5?] 🚀 |
| Task 53 | ✅ | 🎁 **utilities** · Payment event hooks (server-side observability surface) [D:3/B:5/U:6 → Eff:1.83?] 🚀 |
| Task 56 `[P]` | ✅ | 🎁 **utilities** · GitHub Actions CI workflow [D:3/B:7/U:7 → Eff:2.33] 🎯 |
| Task 57 `[P]` | ✅ | 🎁 **utilities** · Unit tests for MultiProvider and ConCacheStore [D:2/B:5/U:6 → Eff:2.75] 🎯 |
| Task 58 | ✅ | 🎁 **utilities** · 📝 Public API @doc + missing @spec pass [D:3/B:4/U:4 → Eff:1.33] 📋 |
| Task 59 | ✅ | 🎁 **tempo** · 🔒 Fee-payer pre-broadcast simulation of co-signed Tempo transactions [D:6/B:8/U:7 → Eff:1.25] 📋 |
| Task 60 | ✅ | 🎁 **utilities** · Credential-gated integration CI: nightly cron + pre-merge gate [D:3/B:6/U:5 → Eff:1.83] 🚀 |
| Task 61 | ✅ | 🎁 **utilities** · GitHub security/CI hardening: Sobelow SARIF code-scanning, Dependabot, SECURITY.md scope [D:2/B:5/U:4 → Eff:2.25] 🎯 |
| Task 62 | ✅ | 🎁 **utilities** · Fix CI coverage gate to green (repair precommit alias + restore 95%) [D:3/B:6/U:6 → Eff:2.0] 🎯 |
| Task 63 `[P]` | ✅ | 🎁 **utilities** · Header parser property/fuzz tests [D:3/B:5/U:5 → Eff:1.67] 🚀 |
| Task 65 `[P]` | ✅ | 🎁 **utilities** · 🔒 Cap header token size before decode (memory-exhaustion DoS, mpp-rs #299) [D:2/B:7/U:6 → Eff:3.25] 🎯 |
| Task 66 | ✅ | 🎁 **tempo** · 🔒 Harden Tempo hash-credential dedup to an atomic commit [D:3/B:7/U:6 → Eff:2.17] 🎯 |
| Task 67 | ✅ | 🎁 **utilities** · Align cold check scope with Tempo JS cross-validation dependencies [D:3/B:7/U:5 → Eff:2.0] 🎯 |
| Task 68 | ✅ | 🎁 **utilities** · 🔒 Tempo hosted fee-payer parity [D:5/B:7/U:6 → Eff:1.3] 📋 |
| Task 69 | ✅ | 🎁 **utilities** · 🔒 Tempo proof access-key authorization parity [D:4/B:6/U:5 → Eff:1.38] 📋 |
| Task 70 | ✅ | 🎁 **evm** · 🔒 EVM method: on-chain payment-proof hardening parity with Tempo [D:4/B:9/U:8 → Eff:2.12] 🎯 |
| Task 71 | ✅ | 🎁 **tempo** · 🔒 EVM/Tempo method-module hardening and doc corrections [D:3/B:6/U:6 → Eff:2.0] 🎯 |
| Task 72 | ✅ | 🎁 **core-protocol** · Parse-time input validation parity for challenge/credential [D:3/B:5/U:6 → Eff:1.83] 🚀 |
| Task 73 | ✅ | 🎁 **utilities** · Extract shared helpers and split MPP.Headers (mechanical refactor) [D:3/B:4/U:6 → Eff:1.67] 🚀 |
| Task 74 | ✅ | 🎁 **dx** · 📝 Docs hygiene: README modules, ROADMAP focus, SECURITY version [D:1/B:3/U:5 → Eff:4.0] 🎯 |
| Task 75 | ✅ | 🎁 **tempo** · 🔒 Presenter-identity binding for Tempo hash-credential path (close GHSA-34g7-vx6g-82mq residual) [D:5/B:7/U:6 → Eff:1.3] 📋 |
| Task 76 | ✅ | 🎁 **tempo** · 🔒 Replay protection ON by default: app-started default dedup store for Tempo/EVM (closes issue #7) [D:5/B:7/U:7 → Eff:1.4] 📋 |
| Task 77 | ✅ | 🎁 **tempo** · 🔒 Harden Tempo dedup-store contract (breaking; see private advisory) [D:5/B:7/U:6 → Eff:1.3] 📋 |
<!-- TASKS:END -->

---

## Phase 10: Session Support

> The session intent is the second major intent type (alongside charge). It enables streaming/metered payments via payment channels — clients open a channel with a deposit, present signed vouchers for ongoing access, and either party can close. Both mppx and mpp-rs have full session support.

<!-- TASKS:BEGIN phase=10 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 28 | ✅ | 🎁 **session** · Session error types [D:2/B:5/U:7 → Eff:3.0?] 🎯 |
| Task 29 | ⬜ | 🎁 **session** · Session intent schema [D:4/B:7/U:8 → Eff:1.88?] 🚀 |
| Task 41 | ✅ | 🎁 **session** · Tempo SessionReceipt [D:2/B:5/U:6 → Eff:2.75?] 🎯 |
| Task 30 | ⬜ | 🎁 **session** · Channel state and voucher types [D:5/B:6/U:7 → Eff:1.3?] 📋 |
| Task 31 | ⬜ | 🎁 **session** · Session credential actions [D:5/B:6/U:6 → Eff:1.2?] 📋 |
| Task 50 | ⬜ | 🎁 **session** · Tempo subscriptions [D:6/B:6/U:5 → Eff:0.92?] ⚠️ |
<!-- TASKS:END -->

---

## Phase 11: MCP Transport

> MCP (Model Context Protocol) support enables payments over JSON-RPC — critical for AI agent economy. Independent of sessions, can be built in parallel with Phase 10. Types alone are not enough here; both reference SDKs also expose concrete server/client MCP integration points.

<!-- TASKS:BEGIN phase=11 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 32 | ✅ | 🎁 **mcp** · MCP types and constants [D:2/B:7/U:8 → Eff:3.75?] 🎯 |
| Task 32b | ⬜ | 🎁 **mcp** · MCP server transport [D:3/B:7/U:8 → Eff:2.5?] 🎯 |
<!-- TASKS:END -->

---

## Phase 12: Client SDK

> Currently we're server-only — `MPP.Plug` lets you charge for endpoints, but there's no way to make MPP-authenticated requests as a client. This phase adds the client-side SDK foundation plus built-in providers so the package is usable out of the box. mppx has `Mppx.create()` + `Fetch.from()` + built-in methods, mpp-rs has `PaymentProvider` + `PaymentExt` plus concrete providers.

<!-- TASKS:BEGIN phase=12 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 33a | ✅ | 🎁 **client-sdk** · Client PaymentProvider behaviour [D:3/B:8/U:9 → Eff:2.83?] 🎯 |
| Task 33b | ✅ | 🎁 **client-sdk** · HTTP client transport [D:3/B:7/U:8 → Eff:2.5?] 🎯 |
| Task 33c | ⬜ | 🎁 **client-sdk** · Payment-aware Req plugin [D:4/B:8/U:8 → Eff:2.0?] 🎯 |
| Task 33d | ⬜ | 🎁 **client-sdk** · MCP client transport [D:3/B:6/U:7 → Eff:2.17?] 🎯 |
| Task 33e | ⬜ | 🎁 **client-sdk** · Built-in charge providers [D:6/B:8/U:9 → Eff:1.42?] 📋 |
| Task 47 | ⬜ | 🎁 **client-sdk** · Client challenge ordering hook [D:2/B:4/U:5 → Eff:2.25?] 🎯 |
<!-- TASKS:END -->

---

## Phase 13: Lightning Payment Method

> Lightning has two specs: charge (one-time BOLT11 invoice) and session (prepaid streaming with deposit/topUp/close). Verification is simple: SHA256(preimage) == payment_hash. Neither mppx nor mpp-rs implement Lightning — we'd be first movers. Lightning session (Task 20) depends on session infrastructure from Phase 10.
>
> Specs: `refs/mpp-specs/specs/methods/lightning/draft-lightning-charge-00.md`, `draft-lightning-session-00.md`

<!-- TASKS:BEGIN phase=13 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 19 | ⬜ | 🎁 **lightning** · Lightning charge method [D:5/B:7/U:7 → Eff:1.4?] 📋 |
| Task 20 | ⬜ | 🎁 **lightning** · Lightning session method [D:8/B:5/U:4 → Eff:0.56?] ⚠️ |
<!-- TASKS:END -->

---

## Phase 14: Solana Payment Method

> Solana supports two modes: pull (client signs tx, server broadcasts — default) and push (client broadcasts, sends confirmed signature). Supports native SOL and SPL tokens, fee payer option, and payment splits (up to 8 recipients). Similar pattern to Tempo's on-chain verification. Neither mppx nor mpp-rs implement Solana.
>
> Spec: `refs/mpp-specs/specs/methods/solana/draft-solana-charge-00.md`

<!-- TASKS:BEGIN phase=14 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 21 | ⬜ | 🎁 **solana** · Solana charge method [D:6/B:6/U:5 → Eff:0.92?] ⚠️ |
<!-- TASKS:END -->

---

## Phase 15: Card Payment Method

> Card is the most complex method — uses JWE-encrypted network tokens with RSA-OAEP-256 + AES-256-GCM. Requires "Client Enabler" (token provisioning) and "Server Enabler" (decryption + processing) intermediaries. Least aligned with machine-to-machine payments. Neither mppx nor mpp-rs implement Card. Defer until ecosystem demand.
>
> Spec: `refs/mpp-specs/specs/methods/card/draft-card-charge-00.md`

<!-- TASKS:BEGIN phase=15 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 22 | ⬜ | 🎁 **card** · Card charge method [D:8/B:5/U:4 → Eff:0.56?] ⚠️ |
<!-- TASKS:END -->

---

## Phase 16: Additional Payment Methods

> Methods with spec support but limited ecosystem pull. Deferred until demand or partnership surfaces.

<!-- TASKS:BEGIN phase=16 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 36 | ⬜ | 🎁 **additional-methods** · Stellar charge method [D:7/B:5/U:6 → Eff:0.79?] ⚠️ |
| Task 39 | ⬜ | 🎁 **additional-methods** · EVM Permit2 credential path [D:7/B:7/U:7 → Eff:1.0?] 📋 |
| Task 40 | ⬜ | 🎁 **additional-methods** · EVM EIP-3009 authorization credential [D:6/B:5/U:5 → Eff:0.83?] ⚠️ |
| Task 51 | ⬜ | 🎁 **additional-methods** · Hedera charge method [D:6/B:4/U:4 → Eff:0.67?] ⚠️ |
<!-- TASKS:END -->

---

## Deferred

Items identified in cross-SDK gap analysis but not worth phasing yet:

- **SSE support** — Server-Sent Events for streaming payments (`payment-receipt` + `payment-need-voucher` events). **Canonical session transport in mpp-rs and mppx** (not optional). Blocked on Tasks 30-31; escalate priority when Phase 10 work begins. [D:4/B:6/U:6 → Eff:1.5]
- **Store backends** — Redis adapter, file store. ConCache + behaviour is sufficient for now. [D:3/B:3/U:3 → Eff:1.0]
- **HTML/UI** — Browser payment helper UI and hosted-form config (mostly mppx-specific). Not relevant for library. [D:5/B:3/U:2 → Eff:0.5]

## Separate Package: mpp_proxy

Proxy/gateway functionality scoped out to a standalone `mpp_proxy` hex package (not part of this library). Both mppx and mpp-rs ship proxy as core modules — but the proxy is a **product** (payment gateway), not a library feature. Separate package keeps `mpp` focused on protocol correctness while `mpp_proxy` targets the "wrap any API → monetize it" use case. See `mpp_proxy` repo for roadmap once created.

---

## References

| Resource | What |
|----------|------|
| [ZenHive/mpp](https://github.com/ZenHive/mpp) | This repo — Elixir MPP implementation |
| [MPP Spec](https://github.com/tempoxyz/mpp-specs) | IETF draft — core protocol, intents, methods |
| [mpp-rs](https://github.com/tempoxyz/mpp-rs) | Rust reference implementation (Tower/Axum) |
| [x402 Docs](https://docs.x402.org) | Coinbase-backed on-chain payment protocol |
| [Stripe MPP Blog](https://stripe.com/blog/machine-payments-protocol) | Stripe's agent commerce vision |
| api_cache Phase 7 | First consumer — Tasks 47-51 |
