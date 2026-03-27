# MPP Roadmap

**Vision:** First Elixir implementation of the Machine Payments Protocol — HTTP 402 payment middleware that turns any Phoenix API into an agent-billable service. No accounts, no API keys. Payment is authentication.

**Completed work:** See [CHANGELOG.md](CHANGELOG.md) for finished tasks.

**Spec:** [tempoxyz/mpp-specs](https://github.com/tempoxyz/mpp-specs) | **Reference impl:** [tempoxyz/mpp-rs](https://github.com/tempoxyz/mpp-rs)

---

## Current Focus

**Phase 4: Tempo Payment Method** — Tasks 13a/13b/13e complete (skeleton, hash verification, integration tests). Next: 13c (transaction credential, Eff:0.92) or Task 17 (mix mpp.demo, Eff:2.83).

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
| Task 13c: Tempo tx verify | ⬜ | [D:6/B:6/U:5 → Eff:0.92] | type="transaction" + MPP.Tempo.Transaction |
| Task 13d: Tempo fee payer | ⬜ | [D:7/B:4/U:3 → Eff:0.5] | Server-side fee sponsorship |
| Task 13e: Tempo integration | ✅ | [D:3/B:6/U:5 → Eff:1.83] | Moderato testnet tests |
| Task 15: Multi-Method 402 | ✅ | [D:3/B:6/U:7 → Eff:2.17] | Multiple payment methods per endpoint |
| Task 16: v0.1.0 Release | ✅ | [D:2/B:8/U:8 → Eff:4.0] | First Hex publish |
| Task 17: mix mpp.demo | ⬜ | [D:3/B:8/U:9 → Eff:2.83] | After Tasks 13/14 |
| Task 18: Live integration tests | ⬜ | [D:4/B:7/U:8 → Eff:1.88] | Tests against mpp.dev/api/ping/paid |
| Task 19: Lightning charge | ⬜ | [D:5/B:7/U:7 → Eff:1.4] | BOLT11 invoice + preimage verification |
| Task 20: Lightning session | ⬜ | [D:8/B:5/U:4 → Eff:0.56] | Prepaid streaming (deposit/topUp/close) |
| Task 21: Solana charge | ⬜ | [D:6/B:6/U:5 → Eff:0.92] | SOL/SPL pull+push modes, fee payer, splits |
| Task 22: Card charge | ⬜ | [D:8/B:5/U:4 → Eff:0.56] | JWE encrypted network tokens, intermediaries |

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

> Tempo has two credential types: `type="hash"` (client already broadcast, server verifies via RPC) and `type="transaction"` (client sends signed tx, server decodes/broadcasts). The hash path uses standard EVM RPC calls that `onchain` already provides. The transaction path requires Tempo-specific 0x76 tx parsing — lives in `MPP.Tempo.Transaction` within mpp (not in onchain; protocol-specific, not chain-generic).
>
> Spec: `refs/mpp-specs/specs/methods/tempo/draft-tempo-charge-00.md`

### Task 13a: Tempo Method Skeleton + Challenge Details ✅

See [CHANGELOG.md](CHANGELOG.md#task-13a-tempo-method-skeleton) for details.

### Task 13b: Hash Credential Verification (type="hash") ✅

See [CHANGELOG.md](CHANGELOG.md#task-13b-hash-credential-verification) for details.

### Task 13c: Transaction Credential Verification (type="transaction")

[D:6/B:6/U:5 → Eff:0.92] ⚠️

Implement `verify/2` for `type="transaction"` credentials. Create `MPP.Tempo.Transaction` helper module for 0x76 tx decoding (uses signet's RLP primitives + `Onchain.ABI` for standard parts; custom envelope parsing is mpp's responsibility). Decode the RLP Tempo Transaction from `payload["signature"]`, verify it contains `transfer(recipient, amount)` or `transferWithMemo(recipient, amount, memo)` on the correct TIP-20 token, verify amount/recipient match challenge, broadcast via `eth_sendRawTxSync`, verify receipt. Unit tests with crafted test transactions. Reference: `refs/mppx/src/tempo/server/` for broadcast + verify flow, `refs/mpp-specs/specs/methods/tempo/draft-tempo-charge-00.md` §Transaction Verification for spec. Depends on Task 13a.

### Task 13d: Fee Payer Support

[D:7/B:4/U:3 → Eff:0.5] ⚠️

Implement server-side fee sponsorship for `feePayer: true`. Accept `fee_payer_private_key` and `fee_token` in method_config. Extract client-signed transaction, add server's fee payer signature (domain 0x78), construct dual-signed transaction, broadcast and verify. Reference: `refs/mpp-specs/specs/methods/tempo/draft-tempo-charge-00.md` §Fee Payment for spec, `refs/mppx/src/tempo/server/` for dual-signature construction. Depends on Task 13c. Defer until demand exists.

### Task 13e: Tempo Integration Tests ✅

See [CHANGELOG.md](CHANGELOG.md#task-13e-tempo-integration-tests) for details.

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

## Phase 8: Developer Experience

### Task 17: mix mpp.demo — Interactive Demo Server

[D:3/B:8/U:9 → Eff:2.83] 🎯

Ship a `mix mpp.demo` task that starts a local Bandit server with a demo payment method. Users run it, see the full 402 flow in action, and get copy-paste curl commands. No real payment provider needed — a magic "demo-token" succeeds. Serves as both a learning tool and a local test target for client implementations.

Success criteria:
- [ ] `mix mpp.demo` starts server on port 4402 (configurable via `--port`)
- [ ] Demo payment method accepts `"demo-token"` payload
- [ ] GET /resource returns 402 with proper WWW-Authenticate challenge
- [ ] Valid credential returns 200 with Payment-Receipt header
- [ ] Startup banner prints working curl commands (pre-computed credential)
- [ ] Runtime check for Bandit with clear error if missing
- [ ] Tests for DemoMethod and Router via Plug.Test

### Task 18: Live Protocol Integration Tests

[D:4/B:7/U:8 → Eff:1.88] 🚀

Integration tests against the live `mpp.dev/api/ping/paid` endpoint. Verify our client-side modules (Headers.parse_challenge, Credential.encode, Receipt.decode) work correctly against a real MPP server. Uses the Tempo payment method — requires Tempo wallet credentials. Tagged `:integration` so they don't run by default.

Success criteria:
- [ ] Hit `https://mpp.dev/api/ping/paid`, parse the 402 response
- [ ] Verify Challenge struct parsed correctly from WWW-Authenticate header
- [ ] Verify RFC 9457 error body matches our Errors module
- [ ] Verify challenge fields (realm, method, intent, request, expires)
- [ ] Optional: full roundtrip with Tempo wallet (if credentials available)
- [ ] Tagged `@moduletag :integration`, fails loudly on missing credentials

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
