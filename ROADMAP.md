# MPP Roadmap

**Vision:** First Elixir implementation of the Machine Payments Protocol — HTTP 402 payment middleware that turns any Phoenix API into an agent-billable service. No accounts, no API keys. Payment is authentication.

**Completed work:** See [CHANGELOG.md](CHANGELOG.md) for finished tasks.

**Spec:** [tempoxyz/mpp-specs](https://github.com/tempoxyz/mpp-specs) | **Reference impl:** [tempoxyz/mpp-rs](https://github.com/tempoxyz/mpp-rs)

---

## Current Focus

**Task 14 complete** (2026-04-03) — Generic EVM on-chain payment method. Next: Task 19 (Lightning charge, Eff:1.4) or Task 21 (Solana charge, Eff:0.92).

> **Philosophy reminder:** This is a library, not an app. Explicit credentials, no global config, no ENV fallback. Per-route pricing via Plug opts. Stateless HMAC-bound challenges.

### Summary

| Task | Status | Score | Notes |
|------|--------|-------|-------|
| Task 1: Challenge module | ✅ | [D:4/B:10/U:10 → Eff:2.5] | HMAC-SHA256 binding |
| Task 2: Credential module | ✅ | [D:3/B:9/U:9 → Eff:3.0] | base64url JSON decode/encode |
| Task 3: Receipt module | ✅ | [D:2/B:8/U:8 → Eff:4.0] | base64url JSON encode/decode |
| Task 4: Headers module | ✅ | [D:3/B:9/U:9 → Eff:3.0] | Auth-param parser + format |
| Task 5: Errors module | ✅ | [D:2/B:7/U:7 → Eff:3.5] | 9 RFC 9457 problem types |
| Task 6: ChargeRequest | ✅ | [D:2/B:8/U:8 → Eff:4.0] | Intent schema with validation |
| Task 7: Method behaviour | ✅ | [D:3/B:10/U:10 → Eff:3.33] | Behaviour + __using__ macro |
| Task 8: Plug middleware | ✅ | [D:5/B:10/U:10 → Eff:2.0] | Phase 1 complete |
| Task 9: Stripe method | ✅ | [D:4/B:9/U:8 → Eff:2.13] | SPT → PaymentIntent verification |
| Task 10: Stripe integration test | ✅ | [D:3/B:7/U:6 → Eff:2.17] | Full 402 handshake against Stripe test API |
| Task 11: Descripex Annotations | ✅ | [D:3/B:7/U:8 → Eff:2.5] | api() on 7 modules + Discoverable |
| Task 12: mix mpp.manifest | ✅ | [D:2/B:6/U:7 → Eff:3.25] | Static JSON manifest generation |
| Task 13a: Tempo skeleton | ✅ | [D:2/B:7/U:8 → Eff:3.75] | Method module + challenge details |
| Task 13b: Tempo hash verify | ✅ | [D:4/B:8/U:8 → Eff:2.0] | type="hash" via Req + onchain parsing |
| Task 13c: Tempo tx verify | ✅ | [D:6/B:6/U:5 → Eff:0.92] | type="transaction" + 0x76 transaction verification |
| Task 13d: Tempo fee payer | ✅ | [D:7/B:4/U:3 → Eff:0.5] | Server-side fee sponsorship |
| Task 13e: Tempo integration | ✅ | [D:3/B:6/U:5 → Eff:1.83] | Moderato testnet tests |
| Task 13f: Tx dedup store | ✅ | [D:4/B:5/U:4 → Eff:1.13] | Optional replay protection for transaction credentials |
| Task 13g: Optimistic broadcast | ✅ | [D:3/B:4/U:3 → Eff:1.17] | waitForConfirmation: false mode |
| Task 13h: Tx integration test | ✅ | [D:4/B:5/U:5 → Eff:1.25] | Testnet test for type="transaction" path |
| Task 15: Multi-Method 402 | ✅ | [D:3/B:6/U:7 → Eff:2.17] | Multiple payment methods per endpoint |
| Task 16: v0.1.0 Release | ✅ | [D:2/B:8/U:8 → Eff:4.0] | First Hex publish |
| Task 23: onchain_tempo extraction | ✅ | [D:5/B:6/U:7 → Eff:1.3] | Extract Tempo chain primitives to onchain_tempo package |
| Task 17: mix mpp.demo | ✅ | [D:3/B:8/U:9 → Eff:2.83] | Interactive demo server on port 4402 |
| Task 18: Live integration tests | ✅ | [D:4/B:7/U:8 → Eff:1.88] | Tests against mpp.dev/api/ping/paid |
| Task 14: Generic EVM method | ✅ | [D:6/B:7/U:6 → Eff:1.08] | Any EVM chain on-chain verification |
| Task 19: Lightning charge | ⬜ | [D:5/B:7/U:7 → Eff:1.4] | BOLT11 invoice + preimage verification |
| Task 20: Lightning session | ⬜ | [D:8/B:5/U:4 → Eff:0.56] | Prepaid streaming (deposit/topUp/close) |
| Task 21: Solana charge | ⬜ | [D:6/B:6/U:5 → Eff:0.92] | SOL/SPL pull+push modes, fee payer, splits |
| Task 22: Card charge | ⬜ | [D:8/B:5/U:4 → Eff:0.56] | JWE encrypted network tokens, intermediaries |

---

## Phase 1: Core Protocol ✅

> 8 tasks complete (v0.1.0). Challenge, Credential, Receipt, Headers, Errors, Charge intent, Method behaviour, Plug middleware.

---

## Phase 2: Stripe Payment Method ✅

> 2 tasks complete (v0.1.0). Stripe SPT verification + integration tests against Stripe test API.

---

## Phase 3: Descripex + Discovery ✅

> 2 tasks complete (v0.1.0). `api()` annotations on all public functions, `MPP.describe/0-2`, `mix mpp.manifest`.

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

## Phase 9: Lightning Payment Method

> Lightning has two specs: charge (one-time BOLT11 invoice) and session (prepaid streaming with deposit/topUp/close). Verification is simple: SHA256(preimage) == payment_hash. Neither mppx nor mpp-rs implement Lightning — we'd be first movers.
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

## Phase 10: Solana Payment Method

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

## Phase 11: Card Payment Method

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

## References

| Resource | What |
|----------|------|
| [ZenHive/mpp](https://github.com/ZenHive/mpp) | This repo — Elixir MPP implementation |
| [MPP Spec](https://github.com/tempoxyz/mpp-specs) | IETF draft — core protocol, intents, methods |
| [mpp-rs](https://github.com/tempoxyz/mpp-rs) | Rust reference implementation (Tower/Axum) |
| [x402 Docs](https://docs.x402.org) | Coinbase-backed on-chain payment protocol |
| [Stripe MPP Blog](https://stripe.com/blog/machine-payments-protocol) | Stripe's agent commerce vision |
| api_cache Phase 7 | First consumer — Tasks 47-51 |
