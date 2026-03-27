# Changelog

Completed roadmap tasks.

---

## [Unreleased]

### Phase 4: Tempo Payment Method

#### Task 13e: Tempo Integration Tests
**Completed** | [D:3/B:6/U:5 → Eff:1.83]

**What was done:**
- Integration tests against Tempo Moderato testnet (chainId 42431) validating the full 402 handshake with `type="hash"` credentials
- Fully automated test setup: derives addresses from deterministic test keys, funds sender via `tempo_fundAddress` custom RPC, executes a real pathUSD TIP-20 transfer on-chain, polls for confirmation
- Five tests: happy path 402→credential→receipt roundtrip, challenge method details verification, non-existent hash rejection, malformed hash rejection, missing type field rejection
- Tagged `@moduletag :integration` — excluded by default, run with `--include integration`

**Key decisions:**
- `setup_all` (not `setup`) — single on-chain transfer shared across all tests, avoids per-test faucet/transfer overhead
- Hardcoded deterministic private keys (Hardhat default #0 and #1) — testnet only, no security concern
- Polling loop for tx confirmation with configurable interval and max attempts — Moderato block times vary
- Follows Stripe integration test patterns: `flunk()` with actionable instructions on missing deps or network failures
- `TEMPO_RPC_URL` env var read at runtime (not compile-time module attribute) — avoids stale-compilation gotcha
- `fund_test_address` checks JSON-RPC error-in-200 body — faucet rate limiting or errors surface immediately, not as confusing downstream failures

#### Task 13b: Hash Credential Verification
**Completed** | [D:4/B:8/U:8 → Eff:2.0]

**What was done:**
- `verify/2` for `type="hash"` credentials — full on-chain payment verification via JSON-RPC
- Fetches transaction receipt via `eth_getTransactionReceipt` using Req (same HTTP pattern as Stripe)
- Parses Transfer event logs with `Onchain.Transfer.parse_logs/1` and verifies amount, token, and recipient match the challenge using `Onchain.Address.equal?/2`
- Memo enforcement per spec (draft-tempo-charge-00.md §Transaction Verification): when `methodDetails.memo` is configured, requires `TransferWithMemo` event with matching memo; without memo, accepts both `Transfer` and `TransferWithMemo`
- Memo validation in `validate_config!/1` — rejects invalid memo format at init time (32 bytes hex, optional 0x prefix)
- Dispatches `type="hash"` vs `type="transaction"` vs unknown type with pattern-matched function heads
- Preserves `external_id` from charge in receipt

**Key decisions:**
- Req for HTTP, onchain for parsing — follows Stripe pattern for `Req.Test` mockability while leveraging onchain's pure parsing functions
- Raw JSON-RPC response converted to atom-keyed format matching onchain's transfer log parser expectations
- `@dialyzer {:nowarn_function, ...}` for optional onchain calls — runtime availability enforced by `validate_config!/1` at Plug init
- `TransferWithMemo` parsed directly in Tempo module (not in onchain — TIP-20 specific, not chain-generic) using `Onchain.Log.decode_event/2` with custom event signature
- Memo validation is validate-only (no normalization) — Method behaviour returns `:ok`, can't thread normalized config back
- Safe `Integer.parse/1` for charge amounts and catch-all in RPC response handling — typed error contract preserved on all paths

**Code review fixes (post-implementation):**
- Memo enforcement gap: `find_matching_transfer/3` now branches on memo presence, matching mppx reference (Charge.ts:337-378)
- `fetch_receipt/3` catch-all clause for unexpected RPC responses (prevents CaseClauseError)
- Safe amount parsing via `Integer.parse/1` instead of `String.to_integer/1` (prevents ArgumentError on non-numeric amounts)

#### Task 13a: Tempo Method Skeleton
**Completed** | [D:2/B:7/U:8 → Eff:3.75]

**What was done:**
- `MPP.Methods.Tempo` module implementing the `MPP.Method` behaviour — second payment method after Stripe
- `method_name/0` returns `"tempo"`, `validate_config!/1` requires `rpc_url` in method_config
- `challenge_method_details/1` returns `chainId` (default 42431 Moderato testnet), `feePayer` (default false), and optional `memo`
- Runtime availability check for `onchain` dependency in `validate_config!/1`
- `verify/2` stub returns `:verification_failed` — implementation deferred to Task 13b (hash) and 13c (transaction)
- Descripex `api()` annotations on all 4 public functions, registered in `MPP.describe/0`
- Added `onchain` ~> 0.4 as optional Hex dependency

**Key decisions:**
- `onchain` is optional (not required at compile time) — runtime check raises with install instructions if missing
- Challenge details always return a map (never nil) — Tempo always needs `chainId` in the challenge
- `type="hash"` is the primary verification path — all RPC primitives exist in `onchain` today
- `type="transaction"` requires Tempo-specific 0x76 tx parsing — lives in `MPP.Tempo.Transaction` within mpp (protocol-specific, not chain-generic)
- Fee payer support (Task 13d) deferred until demand — low efficiency score

### Phase 6: Multi-Method Challenges

#### Task 15: Multi-Method 402
**Completed** | [D:3/B:6/U:7 → Eff:2.17]

**What was done:**
- `MPP.Plug` now supports multiple payment methods per endpoint via `:methods` option
- 402 responses include one `WWW-Authenticate: Payment` header per accepted method, each with its own HMAC-bound challenge
- Credential routing: echoed challenge's `method` field routes to the correct `MethodEntry` for verification
- Unknown method names return 400 with `:method_unsupported` error (pre-existing RFC 9457 type)
- Full backwards compatibility: existing single-method `:method` + `:amount` + `:currency` opts still work
- Introduced `MPP.Plug.MethodEntry` struct for per-method config (method, charge, request, method_config)
- Restructured `MPP.Plug.Config` to hold shared settings + list of `MethodEntry` structs
- Init-time validation rejects duplicate method names

**Key decisions:**
- Multi-method format uses `:methods` keyword with list of keyword lists (Elixir-idiomatic, consistent with Plug opts pattern)
- `Plug.Conn.prepend_resp_headers/2` for multiple WWW-Authenticate headers (not `put_resp_header` which overwrites)
- Per-method pricing: each method can have different amount/currency — the spec (§1017-1035) explicitly allows this
- Shared secret_key/realm/expires_in/opaque across methods — HMAC binding still prevents cross-method forgery since method name is in the HMAC input

### Phase 3: Descripex + Discovery

#### Task 11: Descripex Annotations
**Completed** | [D:3/B:7/U:8 → Eff:2.5]

**What was done:**
- Added `api()` macros to all public functions across 7 modules (~23 functions total)
- Added `use Descripex.Discoverable` to root `MPP` module for `MPP.describe/0-2` progressive discovery
- Namespace grouping: `/protocol` (Challenge, Credential, Receipt, Headers, Errors), `/intents` (Charge), `/methods` (Stripe)
- `composes_with` links between related functions (e.g., `create` ↔ `verify`, `encode` ↔ `decode`, `format_*` ↔ `parse_*`)
- Validation test ensures all exported functions have `:hints` metadata
- Tests for `MPP.describe/0-2` at all three discovery levels

**Key decisions:**
- `MPP.Method` and `MPP.Plug` not annotated — behaviour definitions and framework callbacks, not agent-callable APIs
- Error tuples in `api()` declarations document known error atoms for agent consumption
- `describe/2` Level 3 returns a flat map with params/returns/errors at top level (not nested under `hints`)

#### Task 12: mix mpp.manifest
**Completed** | [D:2/B:6/U:7 → Eff:3.25]

**What was done:**
- `Mix.Tasks.Mpp.Manifest` generates `api_manifest.json` from descripex metadata
- Uses `MPP.__descripex_modules__/0` as single source of truth (no hardcoded module list)
- Pretty-printed JSON output with all 7 modules, functions, params, returns, errors, and specs
- Added `api_manifest.json` to `.gitignore` (generated artifact)

**Key decisions:**
- Bumped descripex 0.5.2 → 0.5.3 which fixes `{atom, description}` error tuples not being JSON-serializable in `Manifest.build/1`

---

## [0.1.0] - 2026-03-25

### Task 16: v0.1.0 Hex Release

First public release with core protocol (Phase 1) and Stripe payment method (Phase 2).

**What was done:**
- Published to Hex as `mpp` v0.1.0
- README with Quick Start guide, module map, and Stripe configuration example
- All quality gates passing: 0 dialyzer warnings, 0 credo issues, doctor passes

### Phase 2: Stripe Payment Method

#### Task 10: Stripe Integration Test
**Completed** | [D:3/B:7/U:6 → Eff:2.17]

**What was done:**
- Integration tests for `MPP.Methods.Stripe` against Stripe's real test mode API
- Full 402 handshake test: no credential → 402 challenge → SPT creation → credential → receipt verification
- Invalid SPT rejection test, missing SPT rejection test, receipt format stability test
- SPT creation helper using Stripe's `test_helpers/shared_payment/granted_tokens` endpoint
- Tests excluded by default (`ExUnit.configure(exclude: [:integration])`), opt-in with `mix test --include integration`
- Missing `STRIPE_SECRET_KEY` → `flunk()` with actionable setup instructions (never skips silently)

**Key decisions:**
- Tests use `Plug.Test.conn` directly against `MPP.Plug` (no HTTP server needed — Plug is just a function)
- SPT creation follows the TypeScript reference pattern using `pm_card_visa` with usage limits
- `pm_card_visa` test payment method always succeeds in Stripe test mode

#### Task 9: Stripe Method
**Completed** | [D:4/B:9/U:8 → Eff:2.13]

**What was done:**
- `MPP.Methods.Stripe` implementing the `MPP.Method` behaviour — first real payment method
- `verify/2` creates a Stripe PaymentIntent with SPT (`shared_payment_granted_token`), `confirm: true`, and immediate status check
- Idempotency key format `mpp_{challenge_id}_{spt}` prevents duplicate charges on client retry
- `challenge_method_details/1` returns `networkId` and `paymentMethodTypes` for client challenge
- Analytics metadata injected into PaymentIntent (`mpp_version`, `mpp_is_mpp`, `mpp_challenge_id`, `mpp_server_id`)
- Handles Stripe error responses (card declined, requires_action/3DS, unexpected status)
- Added `req` as runtime dependency for Stripe API calls (no Stripe SDK needed)
- Added `method_config` to `MPP.Plug.Config` — server-only config map passed to `verify/2` via `charge.method_details` at runtime, never serialized to the client in challenges

**Key decisions:**
- Config passed via `:method_config` Plug opt, not ENV or Application config (per library-design.md)
- `method_config` solves the "server secrets in method_details" problem: public fields (networkId, paymentMethodTypes) go to the client via `challenge_method_details/1`; private fields (stripe_secret_key) stay server-only and are merged into charge at verify time
- Uses `Req.Test` stub/plug pattern for unit tests — no real Stripe API calls in unit tests
- `req_options` key in method_config allows test injection of Req adapters

### Phase 1: Core Protocol

#### Task 1: Challenge Module
**Completed** | [D:4/B:10/U:10 → Eff:2.5]

**What was done:**
- `MPP.Challenge` struct with all 9 spec fields (id, realm, method, intent, request, description, digest, expires, opaque)
- `create/2` computes HMAC-SHA256 challenge ID from 7 pipe-delimited positional slots
- `verify/2` recomputes HMAC and uses `Plug.Crypto.secure_compare/2` for constant-time comparison
- Base64url encoding without padding for challenge IDs
- Optional fields use empty string in HMAC input (fixed slot positions)

#### Task 3: Receipt Module
**Completed** | [D:2/B:8/U:8 → Eff:4.0]

**What was done:**
- `MPP.Receipt` struct with status (always "success"), method, timestamp, reference, external_id
- `new/1` with defaults for status and RFC 3339 timestamp
- `encode/1` / `decode/1` for base64url JSON serialization (Payment-Receipt header format)
- camelCase JSON keys per spec (`externalId`)

#### Task 5: Errors Module
**Completed** | [D:2/B:7/U:7 → Eff:3.5]

**What was done:**
- `MPP.Errors` with 9 RFC 9457 Problem Detail types (expanded from spec's original 7 — added `:invalid_payload` and `:bad_request`)
- `new/2` creates typed errors, `to_map/1` and `to_json/1` render RFC 9457 JSON bodies
- All URIs under `https://paymentauth.org/problems/` base
- Appropriate HTTP status codes (402 for payment errors, 400 for request errors)

#### Task 2: Credential Module
**Completed** | [D:3/B:9/U:9 → Eff:3.0]

**What was done:**
- `MPP.Credential` struct with `challenge` (echoed `MPP.Challenge`), `payload` (method-specific proof map), `source` (optional payer DID)
- `decode/1` parses base64url JSON string into credential with validation of required challenge fields
- `encode/1` serializes credential to base64url JSON, omitting nil optional fields
- Echoed challenge reconstructed as `MPP.Challenge` struct — compatible with `Challenge.verify/2` for HMAC validation
- Challenge `request` preserved as raw base64url string through encode/decode roundtrip

#### Task 6: Charge Request Schema
**Completed** | [D:2/B:8/U:8 → Eff:4.0]

**What was done:**
- `MPP.Intents.Charge` struct with amount (string), currency (lowercase), recipient, description, external_id, method_details
- `new/1` with validation (amount must be string, currency normalized to lowercase)
- `to_request/1` / `from_request/1` for camelCase JSON conversion per spec
- "Intent = Schema" design — all payment methods share this structure

#### Task 4: Headers Module
**Completed** | [D:3/B:9/U:9 → Eff:3.0]

**What was done:**
- `MPP.Headers` with 6 public functions: format/parse for challenge, credential, and receipt headers
- WWW-Authenticate auth-param parser: state-machine for quoted strings with escape handling (`\"`, `\\`)
- CRLF rejection in quoted values (header injection prevention)
- Validates required params, rejects duplicates and unknown params
- Authorization/Receipt headers delegate to existing `Credential.encode/decode` and `Receipt.encode/decode`
- Roundtrip-safe: format → parse preserves all fields including HMAC-verifiable challenge IDs

#### Task 7: Method Behaviour
**Completed** | [D:3/B:10/U:10 → Eff:3.33]

**What was done:**
- `MPP.Method` behaviour with three callbacks: `method_name/0`, `verify/2`, `challenge_method_details/1`
- `verify/2` takes raw payload map + `MPP.Intents.Charge` struct, returns `{:ok, Receipt.t()}` or `{:error, Errors.t()}`
- `challenge_method_details/1` is optional with default `nil` via `__using__` macro
- "Intent = Schema, Method = Implementation" — methods only handle verification, shared charge struct
- Resolved `TODO(Task 7)` in `Intents.Charge` — numeric amount validation is by design delegated to methods

#### Task 8: Plug Middleware
**Completed** | [D:5/B:10/U:10 → Eff:2.0]

**What was done:**
- `MPP.Plug` implementing the full 402 payment handshake as mountable Plug middleware
- `MPP.Plug.Config` struct for validated, pre-computed endpoint configuration (secret_key, realm, method, charge, request, expires_in, opaque)
- `init/1` pre-computes charge struct, method_details, and base64url request string at compile time
- `call/2` implements: no credential → 402 challenge; valid credential → pass-through with receipt; invalid → 402 with error
- Cross-route replay prevention: decodes credential's request and compares amount/currency against endpoint config (follows mpp-rs pattern)
- Challenge expiration support via `expires_in` option (TTL in seconds)
- Fresh challenge included in every 402 response for immediate retry
- `Cache-Control: no-store` on 402 responses, `Cache-Control: private` on successful responses
- RFC 9457 Problem Details JSON error bodies with `content-type: application/problem+json`
- Receipt stored in `conn.assigns[:mpp_receipt]` and `Payment-Receipt` header on success

**Key decisions:**
- Config as struct (not plain map) — compile-time validation via `@enforce_keys`, self-documenting fields
- Explicit amount/currency comparison for replay prevention — HMAC alone doesn't prevent cross-route replay when routes share a secret key
- `require_opt!/2` raises per-field (not batch) for clear error messages at init time

#### Code Review Fixes
- Fixed `Challenge.create/2` `@doc` — removed incorrect "or map" from parameter description (only keyword lists accepted)
- Simplified `Receipt.new/1` — removed unnecessary `then` wrapper around `struct!`
- Added `TODO(Task 7)` to `Intents.Charge` — amount string not validated as numeric, deferred to Method behaviour
- Fixed `Method` `@doc` example — replaced undefined variable with string literal
- Strengthened `MethodTest` error assertions — verify specific error types, not just shared 402 status

---

## [0.0.1] - 2026-03-24

### Added

- Initial release with project scaffold
- Project scaffold with Plug and Jason dependencies
