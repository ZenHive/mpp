# MPP Roadmap

**Vision:** First Elixir implementation of the Machine Payments Protocol — HTTP 402 payment middleware that turns any Phoenix API into an agent-billable service. No accounts, no API keys. Payment is authentication.

**Completed work:** See [CHANGELOG.md](CHANGELOG.md) for finished tasks.

**Spec:** [tempoxyz/mpp-specs](https://github.com/tempoxyz/mpp-specs) | **Reference impl:** [tempoxyz/mpp-rs](https://github.com/tempoxyz/mpp-rs)

---

## Current Focus

**Phase 1: Core Protocol** — Build the foundation modules that implement the MPP handshake.

> **Philosophy reminder:** This is a library, not an app. Explicit credentials, no global config, no ENV fallback. Per-route pricing via Plug opts. Stateless HMAC-bound challenges.

### Summary

| Task | Status | Score | Notes |
|------|--------|-------|-------|
| Task 1: Challenge module | ✅ | [D:4/B:10/U:10 → Eff:2.5] | HMAC-SHA256 binding |
| Task 2: Credential module | ✅ | [D:3/B:9/U:9 → Eff:3.0] | base64url JSON decode/encode |
| Task 3: Receipt module | ✅ | [D:2/B:8/U:8 → Eff:4.0] | base64url JSON encode/decode |
| Task 4: Headers module `[P]` | ⬜ | [D:3/B:9/U:9 → Eff:3.0] | Independent (parse/format only) |
| Task 5: Errors module | ✅ | [D:2/B:7/U:7 → Eff:3.5] | 9 RFC 9457 problem types |
| Task 6: ChargeRequest | ✅ | [D:2/B:8/U:8 → Eff:4.0] | Intent schema with validation |
| Task 7: Method behaviour | ⬜ | [D:3/B:10/U:10 → Eff:3.33] | Unblocked (Tasks 1, 3, 6 done) |
| Task 8: Plug middleware | ⬜ | [D:5/B:10/U:10 → Eff:2.0] | Depends on 4, 7 |

---

## Phase 1: Core Protocol

### Task 1: Challenge Module ✅

See [CHANGELOG.md](CHANGELOG.md#task-1-challenge-module) for details.

### Task 2: Credential Module ✅

See [CHANGELOG.md](CHANGELOG.md#task-2-credential-module) for details.

### Task 3: Receipt Module ✅

See [CHANGELOG.md](CHANGELOG.md#task-3-receipt-module) for details.

### Task 4: Headers Module

[D:3/B:9/U:9 → Eff:3.0]

Implement `MPP.Headers` — parsing and formatting the three protocol headers. `WWW-Authenticate: Payment` uses RFC 9110 auth-param syntax (key=value or key="quoted-value"). `Authorization: Payment <base64url>` is simpler. `Payment-Receipt: <base64url>` is just a base64url blob. Write a custom parser for WWW-Authenticate (the auth-param format has quoting rules that regex handles poorly). Format functions produce spec-compliant header values.

Success criteria:
- [ ] `format_challenge/1` — Challenge struct → WWW-Authenticate header value
- [ ] `parse_challenge/1` — WWW-Authenticate header value → Challenge struct
- [ ] `format_credential/1` — Credential struct → Authorization header value
- [ ] `parse_credential/1` — Authorization header value → Credential struct
- [ ] `format_receipt/1` — Receipt struct → Payment-Receipt header value
- [ ] `parse_receipt/1` — Payment-Receipt header value → Receipt struct
- [ ] Tests for roundtrip parsing, quoted values, multiple auth-params

### Task 5: Errors Module ✅

See [CHANGELOG.md](CHANGELOG.md#task-5-errors-module) for details.

### Task 6: Charge Request Schema ✅

See [CHANGELOG.md](CHANGELOG.md#task-6-charge-request-schema) for details.

### Task 7: Method Behaviour

[D:3/B:10/U:10 → Eff:3.33]

Define `MPP.Method` behaviour — the contract that payment method modules implement. Callbacks: `method_name/0` (returns lowercase string like "stripe"), `verify/2` (takes credential payload + charge request, returns `{:ok, Receipt.t()}` or `{:error, Errors.t()}`). Optional callback `challenge_method_details/1` for methods that need to add method-specific fields to the challenge request (like Stripe's `networkId`).

Success criteria:
- [ ] `MPP.Method` behaviour with `@callback` definitions and typespecs
- [ ] `method_name/0` → `String.t()`
- [ ] `verify/2` → `{:ok, Receipt.t()} | {:error, term()}`
- [ ] Optional `challenge_method_details/1` callback with default impl
- [ ] Documentation with example implementation skeleton

### Task 8: Plug Middleware

[D:5/B:10/U:10 → Eff:2.0]

Implement `MPP.Plug` — the main integration point that any Phoenix router can mount. On `init/1`, accept options: `secret_key`, `realm`, `method` (module implementing `MPP.Method`), `amount`, `currency`, and optional `recipient`, `description`, `expires_in`. On `call/2`: check for `Authorization: Payment` header. If absent, generate a fresh challenge and respond 402 with `WWW-Authenticate: Payment` + `Cache-Control: no-store`. If present, parse credential, verify challenge HMAC, verify payment via method module, and on success assign receipt to conn and set `Payment-Receipt` header. On failure, respond 402 with fresh challenge + RFC 9457 error body. Support cross-route replay prevention by checking amount/currency match.

Success criteria:
- [ ] `MPP.Plug` implements `Plug` behaviour (init/1, call/2)
- [ ] No-credential request → 402 with WWW-Authenticate challenge
- [ ] Valid credential → conn passes through with receipt in assigns + Payment-Receipt header
- [ ] Invalid/expired/tampered credential → 402 with fresh challenge + error body
- [ ] `Cache-Control: no-store` on 402 responses
- [ ] `Cache-Control: private` on responses with Payment-Receipt
- [ ] Cross-route replay prevention (amount/currency mismatch → rejection)
- [ ] Tests using `Plug.Test` for the full 402 flow with a mock method module

---

## Phase 2: Stripe Payment Method

### Task 9: Stripe Method

[D:4/B:9/U:8 → Eff:2.13]

Implement `MPP.Methods.Stripe` — the first real `MPP.Method` implementation. Verifies payment by creating a Stripe PaymentIntent with `shared_payment_granted_token: spt_...` and `confirm: true`. Uses `Req` for Stripe API calls (not a Stripe SDK dep). Idempotency key = `{challenge_id}_{spt}` to prevent duplicate charges. `challenge_method_details/1` adds `networkId` and `paymentMethodTypes` to the challenge request. The method requires `stripe_secret_key` and `network_id` passed explicitly (no ENV fallback per library-design.md).

Success criteria:
- [ ] Implements `MPP.Method` behaviour
- [ ] `verify/2` creates PaymentIntent with SPT, checks `status == "succeeded"`
- [ ] Idempotency key prevents duplicate charges
- [ ] `challenge_method_details/1` adds Stripe-specific fields
- [ ] Explicit config (stripe_secret_key, network_id) — no ENV fallback
- [ ] Unit tests with mocked HTTP responses
- [ ] Handles Stripe error responses gracefully (card declined, invalid SPT, etc.)

### Task 10: Stripe Integration Test

[D:3/B:7/U:6 → Eff:2.17]

Write integration tests for `MPP.Methods.Stripe` against Stripe's test mode API. Requires `STRIPE_SECRET_KEY` env var. Tests must flunk with actionable setup instructions if credentials are missing (never skip silently). Test the full flow: create a test SPT, submit as credential, verify PaymentIntent creation succeeds.

Success criteria:
- [ ] Integration test tagged `@moduletag :integration`
- [ ] Missing credentials → `flunk()` with setup instructions
- [ ] Full flow test: SPT creation → credential → verification → receipt
- [ ] Handles expected Stripe test mode behaviors

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

Implement `MPP.Methods.X402` — EVM on-chain payment verification. Credential payload contains either a transaction hash (already broadcast) or a signed transaction (to broadcast). Verify by checking on-chain settlement: correct amount, correct recipient, correct token (USDC/ERC-20). May use `onchain` library or direct JSON-RPC calls.

Success criteria:
- [ ] Implements `MPP.Method` behaviour
- [ ] Supports transaction hash and signed transaction payload types
- [ ] Verifies on-chain settlement (amount, recipient, token)
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
