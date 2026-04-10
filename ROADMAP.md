# MPP Roadmap

**Vision:** First Elixir implementation of the Machine Payments Protocol — HTTP 402 payment middleware that turns any Phoenix API into an agent-billable service. No accounts, no API keys. Payment is authentication.

**Completed work:** See [CHANGELOG.md](CHANGELOG.md) for finished tasks.

**Spec:** [tempoxyz/mpp-specs](https://github.com/tempoxyz/mpp-specs) | **Reference impl:** [tempoxyz/mpp-rs](https://github.com/tempoxyz/mpp-rs)

---

## Current Focus

**Protocol completeness + client SDK** (2026-04-10) — Prioritizing Phases 9-12 (protocol utilities, sessions, MCP, client SDK) over new payment methods (Phases 13-15). Proxy/gateway scoped out to separate `mpp_proxy` package. Client SDK foundation landed (Task 33a: PaymentProvider behaviour). Next: HTTP transport (Task 33b, needs Task 24), multi-challenge parsing (Task 24), or Verifier+JCS extraction (Task 34).

> **Philosophy reminder:** This is a library, not an app. Explicit credentials, no global config, no ENV fallback. Per-route pricing via Plug opts. Stateless HMAC-bound challenges.

### ✅ Completed (Phases 1-8)

| Task | Score | Notes |
|------|-------|-------|
| Task 1: Challenge module | [D:4/B:10/U:10 → Eff:2.5] | HMAC-SHA256 binding |
| Task 2: Credential module | [D:3/B:9/U:9 → Eff:3.0] | base64url JSON decode/encode |
| Task 3: Receipt module | [D:2/B:8/U:8 → Eff:4.0] | base64url JSON encode/decode |
| Task 4: Headers module | [D:3/B:9/U:9 → Eff:3.0] | Auth-param parser + format |
| Task 5: Errors module | [D:2/B:7/U:7 → Eff:3.5] | 9 RFC 9457 problem types |
| Task 6: ChargeRequest | [D:2/B:8/U:8 → Eff:4.0] | Intent schema with validation |
| Task 7: Method behaviour | [D:3/B:10/U:10 → Eff:3.33] | Behaviour + __using__ macro |
| Task 8: Plug middleware | [D:5/B:10/U:10 → Eff:2.0] | Full 402 handshake |
| Task 9: Stripe method | [D:4/B:9/U:8 → Eff:2.13] | SPT → PaymentIntent verification |
| Task 10: Stripe integration test | [D:3/B:7/U:6 → Eff:2.17] | Full 402 handshake against Stripe test API |
| Task 11: Descripex Annotations | [D:3/B:7/U:8 → Eff:2.5] | api() on 7 modules + local discovery |
| Task 12: mix mpp.manifest | [D:2/B:6/U:7 → Eff:3.25] | Static JSON manifest generation |
| Task 13a-h: Tempo method | [D:2-7/B:4-8/U:3-8] | Hash + tx verify, fee payer, dedup, optimistic, integration |
| Task 15: Multi-Method 402 | [D:3/B:6/U:7 → Eff:2.17] | Multiple payment methods per endpoint |
| Task 16: v0.1.0 Release | [D:2/B:8/U:8 → Eff:4.0] | First Hex publish |
| Task 23: onchain_tempo extraction | [D:5/B:6/U:7 → Eff:1.3] | Extract Tempo chain primitives to onchain_tempo package |
| Task 17: mix mpp.demo | [D:3/B:8/U:9 → Eff:2.83] | Interactive demo server on port 4402 |
| Task 18: Live integration tests | [D:4/B:7/U:8 → Eff:1.88] | Tests against mpp.dev/api/ping/paid |
| Task 14: Generic EVM method | [D:6/B:7/U:6 → Eff:1.08] | Any EVM chain on-chain verification |

### 📋 Upcoming (by efficiency)

| Task | Phase | Status | Score | Notes |
|------|-------|--------|-------|-------|
| ~~Task 32: MCP types + constants~~ | 11 | ✅ | [D:2/B:7/U:8 → Eff:3.75] | Error codes, meta keys, helpers. Codex review fixes: crash paths, type validation, spec accuracy, Discoverable wiring |
| ~~Task 26: Amount/decimals helpers~~ | 9 | ✅ | [D:2/B:6/U:6 → Eff:3.0] | parse_units, with_base_units, parse_dollar_amount |
| ~~Task 28: Session error types~~ | 10 | ✅ | [D:2/B:5/U:7 → Eff:3.0] | 8 new problem types (7 session + payment_action_required) |
| ~~Task 25: Body digest~~ | 9 | ✅ | [D:2/B:6/U:5 → Eff:2.75] | SHA-256 compute/verify with constant-time comparison |
| ~~Task 33a: PaymentProvider behaviour~~ | 12 | ✅ | [D:3/B:8/U:9 → Eff:2.83] | Client-side method abstraction |
| Task 33b: HTTP transport | 12 | ⬜ | [D:3/B:7/U:8 → Eff:2.5] | Client transport behaviour + HTTP |
| Task 32b: MCP server transport | 11 | ⬜ | [D:3/B:7/U:8 → Eff:2.5] | JSON-RPC handler adapter |
| Task 34: Verifier + JCS `[P]` | 9 | ⬜ | [D:4/B:9/U:10 → Eff:2.38] | Transport-neutral verify + RFC 8785 canonical JSON. Blocks cross-impl MCP interop (encode_request TODO) |
| Task 24: Multi-challenge parsing `[P]` | 9 | ⬜ | [D:3/B:7/U:7 → Eff:2.33] | parse_challenges/1 in Headers |
| Task 35: Generic dedup at Plug level `[P]` | 9 | ⬜ | [D:3/B:7/U:7 → Eff:2.33] | Replay protection for all methods |
| Task 27: Expiration + DID helpers `[P]` | 9 | ⬜ | [D:2/B:4/U:5 → Eff:2.25] | Time helpers + DID format |
| Task 33d: MCP client transport | 12 | ⬜ | [D:3/B:6/U:7 → Eff:2.17] | Transport.MCP for JSON-RPC |
| Task 33c: Req plugin | 12 | ⬜ | [D:4/B:8/U:8 → Eff:2.0] | Auto-retry on 402 |
| Task 29: Session intent schema | 10 | ⬜ | [D:4/B:7/U:8 → Eff:1.88] | MPP.Intents.Session struct |
| Task 33e: Built-in charge providers | 12 | ⬜ | [D:6/B:8/U:9 → Eff:1.42] | Tempo + Stripe client providers |
| Task 19: Lightning charge | 13 | ⬜ | [D:5/B:7/U:7 → Eff:1.4] | BOLT11 invoice + preimage |
| Task 30: Channel state + voucher | 10 | ⬜ | [D:5/B:6/U:7 → Eff:1.3] | EIP-712, channel ID, store |
| Task 31: Session credential actions | 10 | ⬜ | [D:5/B:6/U:6 → Eff:1.2] | open/bearer/topUp/close |
| Task 21: Solana charge | 14 | ⬜ | [D:6/B:6/U:5 → Eff:0.92] | SOL/SPL pull+push modes |
| Task 20: Lightning session | 13 | ⬜ | [D:8/B:5/U:4 → Eff:0.56] | Prepaid streaming |
| Task 22: Card charge | 15 | ⬜ | [D:8/B:5/U:4 → Eff:0.56] | JWE network tokens |

---

## Phase 1: Core Protocol ✅

> 8 tasks complete (v0.1.0). Challenge, Credential, Receipt, Headers, Errors, Charge intent, Method behaviour, Plug middleware.

---

## Phase 2: Stripe Payment Method ✅

> 2 tasks complete (v0.1.0). Stripe SPT verification + integration tests against Stripe test API.

---

## Phase 3: Descripex + Local Discovery ✅

> 2 tasks complete (v0.1.0). `api()` annotations on all public functions, `MPP.describe/0-2`, and `mix mpp.manifest` for local discovery/manifest generation.

---

## Phase 4: Tempo Payment Method ✅

> 8 tasks complete (v0.2.0). Hash + transaction credential paths, fee payer co-signing, optimistic broadcast, dedup store, ConCacheStore, integration tests against Moderato testnet, ox/tempo cross-validation.

### Task 23: Extract onchain_tempo Package ✅

[D:5/B:6/U:7 → Eff:1.3] — Completed 2026-03-28. See [CHANGELOG.md](CHANGELOG.md#task-23-onchain_tempo-extraction).

---

## Phase 5: EVM Payment Method ✅

### Task 14: Generic EVM Method ✅

[D:6/B:7/U:6 → Eff:1.08] — Completed 2026-04-03. See [CHANGELOG.md](CHANGELOG.md#task-14-generic-evm-method).

---

## Phase 6: Multi-Method Challenges ✅

> 1 task complete (v0.2.0). Multiple payment methods per endpoint with per-method pricing and credential routing.

---

## Phase 7: Hex Publish ✅

> v0.1.0 published to Hex (2026-03-25). v0.2.0 published (2026-03-28).

---

## Phase 8: Developer Experience

### Task 17: mix mpp.demo — Interactive Demo Server ✅

[D:3/B:8/U:9 → Eff:2.83] — Completed 2026-03-29. See [CHANGELOG.md](CHANGELOG.md#task-17-mix-mppdemo).

### Task 18: Live Protocol Integration Tests ✅

[D:4/B:7/U:8 → Eff:1.88] — Completed 2026-03-29. See [CHANGELOG.md](CHANGELOG.md#task-18-live-protocol-integration-tests).

---

## Phase 9: Protocol Utilities

> Cross-SDK gap analysis (2026-04-04) identified missing protocol features in mppx and mpp-rs that our library lacks. These are small, independent modules — all `[P]` parallelizable.

### Task 25: Body Digest ✅

[D:2/B:6/U:5 → Eff:2.75] — Completed 2026-04-04. See [CHANGELOG.md](CHANGELOG.md#task-25-body-digest).

### Task 26: Amount and Decimals Helpers ✅

[D:2/B:6/U:6 → Eff:3.0] — Completed 2026-04-04. See [CHANGELOG.md](CHANGELOG.md#task-26-amount-and-decimals-helpers).

### Task 24: Multi-Challenge Parsing `[P]`

[D:3/B:7/U:7 → Eff:2.33] 🎯

Add `parse_challenges/1` to `MPP.Headers` that splits comma-separated `WWW-Authenticate` values into a list of challenges. A single header value may contain multiple `Payment` challenges (e.g., `Payment id="a"..., Payment id="b"...`). The existing `parse_challenge/1` handles one; the new function should call it repeatedly after splitting on scheme boundaries. Handle edge cases: quoted strings containing commas, mixed schemes (ignore non-Payment), empty segments. Return `{:ok, [challenge]}` or collect errors. Cross-validate against mppx `deserializeList` behavior.

Success criteria:
- [ ] `parse_challenges/1` returns list of challenges from multi-challenge header
- [ ] Correctly handles commas inside quoted auth-param values
- [ ] Skips non-Payment schemes gracefully
- [ ] Unit tests with 1, 2, and 3 challenges in one header value

### Task 27: Expiration and DID Helpers `[P]`

[D:2/B:4/U:5 → Eff:2.25] 🎯

Add `MPP.Expires` module with `seconds/1`, `minutes/1`, `hours/1`, `days/1`, `weeks/1`, `months/1`, `years/1` returning ISO 8601 datetime strings offset from `DateTime.utc_now/0`. Add `assert!/1` that raises on nil, malformed, or expired timestamps (timezone-aware comparison, malformed ISO edge cases). Add `MPP.DID` module with `evm_did/2` that takes an address and chain_id and returns `"did:pkh:eip155:<chain_id>:<address>"`.

Success criteria:
- [ ] `MPP.Expires.minutes(5)` returns valid ISO 8601 ~5 minutes from now
- [ ] `MPP.Expires.assert!/1` raises on expired/nil/malformed timestamps
- [ ] `MPP.DID.evm_did/2` returns correctly formatted DID string
- [ ] Unit tests for each helper

### Task 34: Verifier Extraction + JCS `[P]`

[D:4/B:8/U:9 → Eff:2.13] 🎯

Extract the verification pipeline from `MPP.Plug` into a transport-neutral `MPP.Verifier` module. Currently, credential verification (HMAC check, realm match, expiration check, request match, method.verify/2) is embedded in `MPP.Plug.call/2` — tightly coupled to HTTP/Plug. The client SDK (Phase 12) and MCP transport (Phase 11) both need this logic without the Plug dependency. `MPP.Verifier.verify/3` should take a credential, a config, and return `{:ok, receipt}` or `{:error, error}`. `MPP.Plug` then becomes a thin HTTP adapter calling `MPP.Verifier`. This mirrors the mppx/mpp-rs architecture where protocol core is transport-neutral.

Also add `MPP.JCS` implementing RFC 8785 JSON Canonicalization Scheme. Both reference SDKs mandate JCS for HMAC reproducibility: mppx uses `Json.canonicalize()` in `PaymentRequest.ts:106`, mpp-rs uses `serde_json_canonicalizer` crate (`Cargo.toml:50`, mandated in [PR #56](https://github.com/tempoxyz/mpp-rs/pull/56)). Without JCS, challenges created by our library won't verify against other SDKs if JSON key ordering differs. Currently we sidestep this by preserving raw base64url strings, but cross-SDK interop for challenge *creation* requires canonical serialization. The verifier should accept a `:request_serializer` option (defaulting to JCS) so both HTTP and MCP transports share the same HMAC computation.

Success criteria:
- [ ] `MPP.JCS` module implementing RFC 8785 canonical JSON serialization
- [ ] Cross-validated against mppx/mpp-rs: same input → same canonical output
- [ ] `MPP.Verifier` module with `verify/3` containing the full verification pipeline
- [ ] Verifier accepts `:request_serializer` option (default: JCS)
- [ ] `MPP.Plug` refactored to delegate to `MPP.Verifier`
- [ ] All existing Plug tests pass unchanged (behavior-preserving refactor)
- [ ] `MPP.Verifier` has no Plug dependency (pure protocol logic)
- [ ] Unit tests for `MPP.Verifier` directly (without Plug/Conn)

### Task 35: Generic Dedup at Plug Level `[P]`

[D:3/B:7/U:7 → Eff:2.33] 🎯

Lift replay protection from Tempo-only to all payment methods. Currently `MPP.Tempo.Store` provides dedup for Tempo credentials, but EVM and Stripe accept the same payment proof twice within the challenge window. Add optional `:store` to `MPP.Plug.Config` (shared across all methods). Before calling `method.verify/2`, check if the credential has been seen (keyed on challenge_id + payload hash). After successful verification, mark as used. Methods that already have their own dedup (Tempo) can skip the plug-level check. The `MPP.Tempo.Store` behaviour is already the right interface — reuse it at the Plug level.

Success criteria:
- [ ] Optional `:store` option in `MPP.Plug` config (shared across methods)
- [ ] Dedup check before `method.verify/2`, mark after success
- [ ] Tempo skips plug-level dedup when it has its own store configured
- [ ] EVM and Stripe benefit from replay protection when store is configured
- [ ] Unit test: same credential rejected on second use
- [ ] Backward compatible — no store = current behavior (no dedup)

---

## Phase 10: Session Support

> The session intent is the second major intent type (alongside charge). It enables streaming/metered payments via payment channels — clients open a channel with a deposit, present signed vouchers for ongoing access, and either party can close. Both mppx and mpp-rs have full session support.

### Task 28: Session Error Types ✅

[D:2/B:5/U:7 → Eff:3.0] — Completed 2026-04-04. See [CHANGELOG.md](CHANGELOG.md#task-28-session-error-types).

### Task 29: Session Intent Schema

[D:4/B:7/U:8 → Eff:1.88] 🚀 — Depends on Task 26

Add `MPP.Intents.Session` as the session intent request schema, parallel to `MPP.Intents.Charge`. Fields: `amount` (required, per-unit rate in base units), `unit_type` (optional, e.g. "second", "minute", "request"), `currency` (required), `recipient` (optional), `suggested_deposit` (optional), `decimals` (optional, transient), `method_details` (optional map). Validate with same pattern as `Charge` — struct with `new/1` validation, `to_request/1` and `from_request/1` serialization.

Success criteria:
- [ ] `MPP.Intents.Session` struct with all fields
- [ ] `new/1` validates required fields, returns `{:ok, session}` or `{:error, reason}`
- [ ] Serializes to same JSON shape as mpp-rs `SessionRequest`
- [ ] Descripex annotations
- [ ] `MPP.Method` behaviour updated to support `intent: "session"` alongside `"charge"`

### Task 30: Channel State and Voucher Types

[D:5/B:6/U:7 → Eff:1.3] 📋 — Depends on Tasks 28, 29

Add `MPP.Session.Channel` for channel state management and `MPP.Session.Voucher` for EIP-712 typed voucher verification. Channel state: channel_id, payer, recipient, token, deposit, cumulative_amount, status. Channel ID = `keccak256(abi.encode(payer, payee, token, salt, authorizedSigner, escrowContract, chainId))`. Voucher: channel_id, cumulative_amount, signature. Channel store behaviour (`MPP.Session.Store`) for pluggable persistence.

Success criteria:
- [ ] Channel ID computation matches mppx/mpp-rs for same inputs
- [ ] EIP-712 voucher signature verification
- [ ] Channel state transitions: open → active → closed
- [ ] Store behaviour with ETS-backed default implementation
- [ ] Cross-validated channel IDs against mppx `Channel.ts`

### Task 31: Session Credential Actions

[D:5/B:6/U:6 → Eff:1.2] 📋 — Depends on Task 30

Implement the four session credential actions: `open` (client deposits, opens channel), `bearer` (client presents voucher for ongoing access), `topUp` (client adds deposit to existing channel), `close` (either party closes channel). Each action maps to a credential payload shape. Server dispatches to correct action handler based on `credential.payload.action`. Integrate with `MPP.Plug` so session endpoints work alongside charge endpoints.

Success criteria:
- [ ] Four action handlers: open, bearer, topUp, close
- [ ] Correct payload schema per action
- [ ] Plug integration for session endpoints
- [ ] Balance tracking per channel
- [ ] Unit tests for each action lifecycle

---

## Phase 11: MCP Transport

> MCP (Model Context Protocol) support enables payments over JSON-RPC — critical for AI agent economy. Independent of sessions, can be built in parallel with Phase 10. Types alone are not enough here; both reference SDKs also expose concrete server/client MCP integration points.

### Task 32: MCP Types and Constants ✅

[D:2/B:7/U:8 → Eff:3.75] — Completed 2026-04-04. See [CHANGELOG.md](CHANGELOG.md#task-32-mcp-types-and-constants).

### Task 32b: MCP Server Transport

[D:3/B:7/U:8 → Eff:2.5] 🎯 — Depends on Tasks 32, 34

Add a server-side MCP transport/adapter that bridges the transport-neutral verifier into JSON-RPC handler environments. Mirror the reference SDK behavior: read credentials from `_meta["org.paymentauth/credential"]`, emit payment-required errors with code `-32042` and challenge data, and attach receipts into `_meta["org.paymentauth/receipt"]` on successful responses. This turns Phase 11 from a types/helpers layer into an actually mountable MCP server integration.

Success criteria:
- [ ] Server-side MCP transport/adapter for JSON-RPC handler inputs and outputs
- [ ] Reads credentials from request `_meta`
- [ ] Emits payment-required errors with challenges and RFC 9457 problem details
- [ ] Attaches receipts to successful result `_meta`
- [ ] Unit tests with mock MCP handler exchanges

---

## Phase 12: Client SDK

> Currently we're server-only — `MPP.Plug` lets you charge for endpoints, but there's no way to make MPP-authenticated requests as a client. This phase adds the client-side SDK foundation plus built-in providers so the package is usable out of the box. mppx has `Mppx.create()` + `Fetch.from()` + built-in methods, mpp-rs has `PaymentProvider` + `PaymentExt` plus concrete providers.

### Task 33a: PaymentProvider Behaviour ✅

[D:3/B:8/U:9 → Eff:2.83] — Completed 2026-04-10. See [CHANGELOG.md](CHANGELOG.md#task-33a-client-paymentprovider-behaviour).

### Task 33b: HTTP Client Transport

[D:3/B:7/U:8 → Eff:2.5] 🎯 — Depends on Task 24

Add `MPP.Client.Transport` behaviour and `MPP.Client.Transport.HTTP` implementation. Transport callbacks: `payment_required?/1` (check if response needs payment), `get_challenges/1` (extract challenges from response), `set_credential/2` (attach credential to request). HTTP implementation: checks status 402, parses `WWW-Authenticate` header using `MPP.Headers.parse_challenges/1`, sets `Authorization` header.

Success criteria:
- [ ] `Transport` behaviour with 3 callbacks
- [ ] HTTP transport using existing `MPP.Headers` functions
- [ ] Handles multi-challenge responses (picks supported method)
- [ ] Unit tests with mock responses

### Task 33c: Payment-Aware Req Plugin

[D:4/B:8/U:8 → Eff:2.0] 🎯 — Depends on Tasks 33a, 33b

Add `MPP.Client.Req` as a Req plugin that intercepts 402 responses, extracts the challenge, calls the configured provider's `pay/1`, and retries with the credential. Pattern: `Req.new() |> MPP.Client.Req.attach(provider: my_provider)`. Non-402 responses pass through untouched. This is the Elixir equivalent of mpp-rs `PaymentExt` for reqwest and mppx `Fetch.from()`.

Success criteria:
- [ ] Req plugin with `attach/2` for pipeline integration
- [ ] Automatic 402 detection and retry
- [ ] Provider selection from multi-challenge responses
- [ ] Non-402 passthrough
- [ ] Integration test against `mix mpp.demo` server

### Task 33d: MCP Client Transport

[D:3/B:6/U:7 → Eff:2.17] 🎯 — Depends on Task 32

Add `MPP.Client.Transport.MCP` implementing the Transport behaviour for JSON-RPC messages. `payment_required?/1` checks error code -32042. `get_challenges/1` extracts from `error.data.challenges`. `set_credential/2` inserts into `params._meta["org.paymentauth/credential"]`. Uses types from Task 32 (`MPP.Mcp`).

Success criteria:
- [ ] Implements `Transport` behaviour for JSON-RPC messages
- [ ] Uses `MPP.Mcp` constants and types
- [ ] Handles payment-required error detection
- [ ] Credential attachment to request params
- [ ] Unit tests with mock JSON-RPC exchanges

### Task 33e: Built-in Charge Providers

[D:6/B:8/U:9 → Eff:1.42] 📋 — Depends on Tasks 33a, 33b

Add built-in client providers so the SDK is useful without every consumer writing their own provider first. Ship `MPP.Client.Providers.Tempo` and `MPP.Client.Providers.Stripe` for charge intent, mirroring the concrete client offerings in the reference SDKs. Each provider should parse the challenge request, execute payment with explicit config, and return a credential for the generic transport/plugin layer. Session-capable providers can layer on after Phase 10 lands.

Success criteria:
- [ ] Built-in Tempo charge provider implementing `PaymentProvider`
- [ ] Built-in Stripe charge provider implementing `PaymentProvider`
- [ ] Public API/docs show end-to-end client usage with the Req plugin or transport layer
- [ ] One integration path per provider against a real or protocol-faithful challenge flow
- [ ] Provider selection works cleanly through `MPP.Client.MultiProvider`

---

## Phase 13: Lightning Payment Method

> Lightning has two specs: charge (one-time BOLT11 invoice) and session (prepaid streaming with deposit/topUp/close). Verification is simple: SHA256(preimage) == payment_hash. Neither mppx nor mpp-rs implement Lightning — we'd be first movers. Lightning session (Task 20) depends on session infrastructure from Phase 10.
>
> Specs: `refs/mpp-specs/specs/methods/lightning/draft-lightning-charge-00.md`, `draft-lightning-session-00.md`

### Task 19: Lightning Charge Method

[D:5/B:7/U:7 → Eff:1.4] 📋

Implement `MPP.Methods.Lightning` for charge intent. Server generates a BOLT11 invoice per request, issues 402 with invoice + payment hash. Client pays via Lightning Network, receives preimage on HTLC settlement, retries with preimage as credential. Server verifies SHA256(preimage) == stored payment_hash. Challenge details include invoice string, paymentHash (hex), network (mainnet/regtest/signet), amount in satoshis. Credential payload: `preimage` (32-byte lowercase hex). Requires Lightning node client library (external dep TBD — LND gRPC or similar).

Success criteria:
- [ ] Implements `MPP.Method` behaviour
- [ ] `challenge_method_details/1` returns invoice, paymentHash, network
- [ ] `verify/2` checks SHA256(preimage) == paymentHash
- [ ] Unit tests with known preimage/hash pairs
- [ ] Integration test with regtest Lightning node (if available)

### Task 20: Lightning Session Method

[D:8/B:5/U:4 → Eff:0.56] ⚠️

Implement prepaid streaming sessions for metered payments (e.g., LLM token generation). Client opens session by paying deposit invoice, provides return invoice for refunds. Server deducts per-unit cost from balance during streaming, emits SSE "need-topup" when balance low. Client can topUp with new deposit or close session (server refunds unspent balance via return invoice). Stateful — needs session store (unlike all other methods). Credential actions: open, bearer, topUp, close. Defer until charge method proven and demand exists.

Success criteria:
- [ ] Session lifecycle: open → bearer → topUp → close
- [ ] Per-unit metering with balance tracking
- [ ] SSE "need-topup" event emission
- [ ] Refund via return invoice on close
- [ ] Session store behaviour (pluggable: ETS, database, etc.)

---

## Phase 14: Solana Payment Method

> Solana supports two modes: pull (client signs tx, server broadcasts — default) and push (client broadcasts, sends confirmed signature). Supports native SOL and SPL tokens, fee payer option, and payment splits (up to 8 recipients). Similar pattern to Tempo's on-chain verification. Neither mppx nor mpp-rs implement Solana.
>
> Spec: `refs/mpp-specs/specs/methods/solana/draft-solana-charge-00.md`

### Task 21: Solana Charge Method

[D:6/B:6/U:5 → Eff:0.92] ⚠️

Implement `MPP.Methods.Solana` for charge intent. Pull mode: client signs Solana transfer tx, sends signed bytes in credential; server optionally co-signs (fee payer), broadcasts, waits for confirmation. Push mode: client broadcasts tx, sends confirmed signature; server fetches tx from RPC and verifies payment details (amount, recipient, token). Challenge details include recipient (base58 pubkey), amount (lamports or token base units), currency ("sol" or mint address), network, decimals, tokenProgram, feePayer flag, feePayerKey, optional splits array. Requires Solana RPC client (external dep TBD).

Success criteria:
- [ ] Implements `MPP.Method` behaviour
- [ ] Pull mode: verify signed tx bytes, broadcast, confirm
- [ ] Push mode: verify confirmed signature via RPC
- [ ] SOL native + SPL token support
- [ ] Fee payer co-signing
- [ ] Payment splits (up to 8 recipients)
- [ ] Unit tests with mocked Solana RPC responses

---

## Phase 15: Card Payment Method

> Card is the most complex method — uses JWE-encrypted network tokens with RSA-OAEP-256 + AES-256-GCM. Requires "Client Enabler" (token provisioning) and "Server Enabler" (decryption + processing) intermediaries. Least aligned with machine-to-machine payments. Neither mppx nor mpp-rs implement Card. Defer until ecosystem demand.
>
> Spec: `refs/mpp-specs/specs/methods/card/draft-card-charge-00.md`

### Task 22: Card Charge Method

[D:8/B:5/U:4 → Eff:0.56] ⚠️

Implement `MPP.Methods.Card` for charge intent. Client works with a Client Enabler to provision an encrypted network token from a token service provider. Token is encrypted with server's RSA public key via JWE (RSA-OAEP-256 + AES-256-GCM). Credential includes encrypted payload, card network (visa/mastercard/amex/discover), PAN last four, expiration, optional cardholder name and billing address, optional PAR. Server forwards encrypted credential to Server Enabler for decryption and processing. Challenge details include accepted networks, merchant name, encryption key (JWK or JWKS URI). Requires RSA key management and JWE library. Defer until ecosystem demand.

Success criteria:
- [ ] Implements `MPP.Method` behaviour
- [ ] RSA key pair generation and JWKS endpoint support
- [ ] JWE token decryption (RSA-OAEP-256 + AES-256-GCM)
- [ ] Network token validation (PAN, expiry, network)
- [ ] Server Enabler integration pattern
- [ ] Unit tests with crafted JWE tokens

---

## Deferred

Items identified in cross-SDK gap analysis but not worth phasing yet:

- **SSE support** — Server-Sent Events for streaming payments (receipt + need-voucher events). Blocked on Phase 10 session infrastructure. [D:4/B:5/U:5 → Eff:1.25]
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
