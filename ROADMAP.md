# MPP Roadmap

**Vision:** First Elixir implementation of the Machine Payments Protocol — HTTP 402 payment middleware that turns any Phoenix API into an agent-billable service. No accounts, no API keys. Payment is authentication.

**Completed work:** See [CHANGELOG.md](CHANGELOG.md) for finished tasks.

**Spec:** [tempoxyz/mpp-specs](https://github.com/tempoxyz/mpp-specs) | **Reference impl:** [tempoxyz/mpp-rs](https://github.com/tempoxyz/mpp-rs)

---

## Current Focus

**Phase 2: Stripe Payment Method** — Complete. Next: Phase 3 (Descripex + Discovery) or Phase 7 (v0.1.0 Release).

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

### Task 11: Descripex Annotations

[D:3/B:7/U:8 → Eff:2.5]

Add `api()` macros to public-facing modules (`MPP.Challenge`, `MPP.Credential`, `MPP.Receipt`, `MPP.Plug`). Add `use Descripex.Discoverable` to the root `MPP` module for progressive discovery via `MPP.describe/0-2`. Agents calling `MPP.describe()` should see the full module tree with capabilities.

Success criteria:
- [ ] `api()` annotations on all public functions in core modules
- [ ] `MPP.describe()` returns module overview
- [ ] `MPP.describe(:challenge)` returns function list
- [ ] `MPP.describe(:challenge, :create)` returns full contract
- [ ] Validation test: all public functions have `:hints` metadata

### Task 12: mix mpp.manifest

[D:2/B:6/U:7 → Eff:3.25]

Create a Mix task `mix mpp.manifest` that generates `api_manifest.json` from descripex metadata. Uses `Descripex.Manifest.build/1` with the list of annotated modules. Static export for agent discovery — can be published alongside the library or served as an endpoint.

Success criteria:
- [ ] `mix mpp.manifest` generates `api_manifest.json`
- [ ] Manifest includes all annotated functions with params, returns, errors
- [ ] JSON is valid and parseable
- [ ] Test verifies manifest generation

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

## Phase 6: Multi-Method Challenges

### Task 15: Multi-Method 402

[D:3/B:6/U:7 → Eff:2.17]

Update `MPP.Plug` to support multiple payment methods in a single 402 response. The server returns multiple `WWW-Authenticate: Payment` headers, each with a different method/pricing. The agent picks whichever method it can pay with. Update init opts to accept a list of `{method_module, method_opts}` tuples. Each method may have different pricing for the same endpoint.

Success criteria:
- [ ] Plug accepts list of methods with per-method options
- [ ] 402 response includes multiple WWW-Authenticate headers
- [ ] Credential verification routes to correct method based on echoed method name
- [ ] Tests for multi-method challenge generation and single-method credential verification

---

## Phase 7: Hex Publish

### Task 16: v0.1.0 Release

[D:2/B:8/U:8 → Eff:4.0]

Publish v0.1.0 to Hex with Phase 1 + Phase 2 complete. Update README with real usage examples (mounting the Plug, configuring Stripe). Generate ExDoc with llms.txt. Update CHANGELOG. Ensure all quality gates pass (dialyzer 0 warnings, credo strict 0 issues, doctor coverage, tests passing). First Elixir MPP implementation on Hex.

Success criteria:
- [ ] All Phase 1 + 2 tests passing
- [ ] Dialyzer: 0 warnings
- [ ] Credo: 0 issues (strict mode)
- [ ] Doctor: all public modules documented
- [ ] README has usage examples with Plug mounting + Stripe config
- [ ] ExDoc generates cleanly with llms.txt
- [ ] CHANGELOG updated
- [ ] `mix hex.publish` succeeds

---

## References

| Resource | What |
|----------|------|
| [MPP Spec](https://github.com/tempoxyz/mpp-specs) | IETF draft — core protocol, intents, methods |
| [mpp-rs](https://github.com/tempoxyz/mpp-rs) | Rust reference implementation (Tower/Axum) |
| [x402 Docs](https://docs.x402.org) | Coinbase-backed on-chain payment protocol |
| [Stripe MPP Blog](https://stripe.com/blog/machine-payments-protocol) | Stripe's agent commerce vision |
| api_cache Phase 7 | First consumer — Tasks 47-51 |
