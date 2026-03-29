# Changelog

All notable changes to this project will be documented in this file.

---

## [Unreleased]

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
