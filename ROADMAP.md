# MPP Roadmap

**Vision:** First Elixir implementation of the Machine Payments Protocol — HTTP 402 payment middleware that turns any Phoenix API into an agent-billable service. No accounts, no API keys. Payment is authentication.

**Completed work:** See [CHANGELOG.md](CHANGELOG.md) for finished tasks.

**Spec:** [tempoxyz/mpp-specs](https://github.com/tempoxyz/mpp-specs) | **Reference impl:** [tempoxyz/mpp-rs](https://github.com/tempoxyz/mpp-rs)

---

## Current Focus

**Phase 6: Multi-Method Challenges** — Complete. Task 15 done.

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
| Task 15: Multi-Method 402 | ✅ | [D:3/B:6/U:7 → Eff:2.17] | Multiple payment methods per endpoint |
| Task 16: v0.1.0 Release | ✅ | [D:2/B:8/U:8 → Eff:4.0] | First Hex publish |

---

## Phase 1: Core Protocol

### Task 1: Challenge Module ✅

See [CHANGELOG.md](CHANGELOG.md#task-1-challenge-module) for details.

### Task 2: Credential Module ✅

See [CHANGELOG.md](CHANGELOG.md#task-2-credential-module) for details.

### Task 3: Receipt Module ✅

See [CHANGELOG.md](CHANGELOG.md#task-3-receipt-module) for details.

### Task 4: Headers Module ✅

See [CHANGELOG.md](CHANGELOG.md#task-4-headers-module) for details.

### Task 5: Errors Module ✅

See [CHANGELOG.md](CHANGELOG.md#task-5-errors-module) for details.

### Task 6: Charge Request Schema ✅

See [CHANGELOG.md](CHANGELOG.md#task-6-charge-request-schema) for details.

### Task 7: Method Behaviour ✅

See [CHANGELOG.md](CHANGELOG.md#task-7-method-behaviour) for details.

### Task 8: Plug Middleware ✅

See [CHANGELOG.md](CHANGELOG.md#task-8-plug-middleware) for details.

---

## Phase 2: Stripe Payment Method

### Task 9: Stripe Method ✅

See [CHANGELOG.md](CHANGELOG.md#task-9-stripe-method) for details.

### Task 10: Stripe Integration Test ✅

See [CHANGELOG.md](CHANGELOG.md#task-10-stripe-integration-test) for details.

---

## Phase 3: Descripex + Discovery

### Task 11: Descripex Annotations ✅

See [CHANGELOG.md](CHANGELOG.md#task-11-descripex-annotations) for details.

### Task 12: mix mpp.manifest ✅

See [CHANGELOG.md](CHANGELOG.md#task-12-mix-mppmanifest) for details.

---

## Phase 4: Tempo Payment Method

### Task 13: Tempo Method

[D:5/B:7/U:6 → Eff:1.3]

Implement `MPP.Methods.Tempo` — TIP-20 stablecoin verification. The credential payload contains a signature-based proof. Verify by checking the signature against the Tempo network. Depends on Tempo SDK/API availability — may need to implement against their REST API directly.

Success criteria:
- [ ] Implements `MPP.Method` behaviour
- [ ] Verifies TIP-20 payment signatures
- [ ] Unit tests with mocked Tempo responses
- [ ] Integration test with Tempo testnet (if available)

---

## Phase 5: x402 Payment Method

### Task 14: x402/EVM Method

[D:6/B:7/U:6 → Eff:1.08]

Implement `MPP.Methods.X402` — EVM on-chain payment verification. Credential payload contains either a transaction hash (already broadcast) or a signed transaction (to broadcast). Verify by checking on-chain settlement: correct amount, correct recipient, correct token (USDC/ERC-20). Use [`onchain`](https://github.com/ZenHive/onchain) (optional dep) for RPC, ERC-20 reads, and address validation. Add as `{:onchain, github: "ZenHive/onchain", optional: true}` — runtime check in the method module that it's available.

Success criteria:
- [ ] Implements `MPP.Method` behaviour
- [ ] Supports transaction hash and signed transaction payload types
- [ ] Verifies on-chain settlement via `Onchain.RPC` + `Onchain.ERC20` (amount, recipient, token)
- [ ] `Onchain.Address` for address validation/normalization
- [ ] Runtime check that `:onchain` is loaded (clear error if missing)
- [ ] Unit tests with mocked RPC responses
- [ ] Integration test with testnet

---

## Phase 6: Multi-Method Challenges ✅

### Task 15: Multi-Method 402 ✅

See [CHANGELOG.md](CHANGELOG.md#task-15-multi-method-402) for details.

---

## Phase 7: Hex Publish ✅

### Task 16: v0.1.0 Release ✅

See [CHANGELOG.md](CHANGELOG.md#010---2026-03-25) for details.

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
