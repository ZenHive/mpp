# Changelog

Completed roadmap tasks.

---

## [Unreleased]

### Additional Tempo Integration Tests

**What was done:**
- Added 5 integration tests against live Moderato testnet: fee payer + optimistic broadcast (co-sign, pass-through, poll for on-chain confirmation), optimistic broadcast + dedup store (reserve_hash_atomic fires before async broadcast), challenge expiration (2s TTL, 3s sleep, rejected before method.verify), memo in challenge details (present when configured, absent when not)

**Key decisions:**
- Challenge expiration test doesn't need a real tx — expiration check runs before method.verify in the plug pipeline
- Optimistic + dedup test proves ordering guarantee: store reservation happens before broadcast in async mode

### Tempo Real Integration Tests + TransferWithMemo Event Fix

**What was done:**
- Extended `tempo_integration_test.exs` with real Moderato testnet tests: transferWithMemo (hash + tx paths, memo mismatch rejection, plain transfer rejection when memo configured), fee-payer validation (hash rejection, missing placeholder, non-empty fee_token), transaction dedup, optimistic multicall targeting, fee-payer dedup
- Fixed TransferWithMemo event signature — `memo` parameter is `indexed` (topic, not data), discovered via real Moderato receipts
- Updated stub log builders in `tempo_test.exs` and `tempo_full_flow_test.exs` to match real on-chain format
- Added `build_signed_multicall/1` to `TempoTxBuilder` for arbitrary-calldata 0x76 transactions
- Added `broadcast_raw_transaction_sync!/2` helper and `tempo_config/3,4` config builder

**Key decisions:**
- All new tests in existing integration file (same `:integration` tag, same `setup_all`)
- `setup_all` extended to also execute a real `transferWithMemo` on Moderato
- Stub-based `tempo_full_flow_test.exs` retained for pipeline wiring coverage

### Tempo Full-Flow Stub Tests

**What was done:**
- Added `test/mpp/methods/tempo_full_flow_test.exs` — stub-based tests exercising the complete Plug pipeline (402 → credential → verify → receipt) with `Req.Test` stubs
- Covers: memo matching, dedup replay prevention, fee-payer edge cases, optimistic multicall simulation targeting, log filtering with unrelated events

**Key decisions:**
- Separate from unit tests (`tempo_test.exs`) and real integration tests — tests Plug wiring layer specifically
- No `:integration` tag — always runnable without network access

### Phase 4: Tempo Payment Method

#### Bug Fix: Reject Empty Calls in Transaction Deserialization

**What was done:**
- `extract_calls/2` now returns `{:error, "Calls list cannot be empty"}` for empty call lists, matching ox/tempo's `CallsEmptyError` behavior
- Updated cross-validation test from documenting asymmetry to asserting both parsers reject
- Added unit test for the empty-calls error path in `transaction_test.exs`

#### Bug Fix: Normalize Sender Signature v-values in `recover_sender`

**What was done:**
- `recover_sender/2` now normalizes legacy v-values (27/28) to recid (0/1) before passing to `Curvy.Signature`. Previously, transactions signed by ox/tempo SDK (which encodes yParity as 0x1b/0x1c) would pass `recid: 27` to Curvy, causing recovery failure. Matches Signet's own `decode_signature` normalization logic.

**Key decisions:**
- This is a library-level interop fix — any client using ox/tempo, viem, or ethers.js to sign Tempo transactions would hit this
- Separate from the test builder change (below) which is cosmetic

#### Test Support: Builder yParity Encoding Aligned with ox/tempo

**What was done:**
- `TempoTxBuilder.sign_and_encode/3` now encodes sender signature yParity as legacy v-values (recid + 27) matching ox/tempo convention
- Golden hex regression test upgraded from structural comparison to exact byte round-trip via `assert_js_round_trip!/2`

#### Docs: Clarify Transaction `raw` Field Encoding

**What was done:**
- Updated `@typedoc` for `Transaction.t()` to explicitly note that `raw` is a hex string with `0x` prefix, suitable for direct JSON-RPC broadcast

#### Bug Fix: Optimistic Multicall Simulation Target

**What was done:**
- Fixed optimistic broadcast path simulating the wrong call in multicall transactions. In a `[approve, swap, transfer]` batch, `eth_call` was targeting the first call (approve) instead of the matched payment call (transfer). The simulation could pass while the actual payment call reverts.
- Threaded the matched payment call from `find_payment_call` through to `broadcast_and_verify` via a new `:call` key in the match result
- Added multicall regression test verifying `eth_call` targets the token contract (transfer's `to`), not the DEX (approve's `to`)

**Key decisions:**
- Backwards-compatible: added `:call` key to `match_call` return — existing code only checks `:recipient`/`:amount`/`:memo` keys
- Both `broadcast_and_verify` clauses updated from arity /6 to /7 — confirmation path ignores the payment_call (verifies via receipt logs)

#### Cross-Validation Tests: 10 New ox/tempo Compatibility Tests

**What was done:**
- Added `from`, `getSignPayload` (TxEnvelopeTempo) and `Secp256k1.sign`/`recoverAddress` exports to `ox_tempo_entry.mjs`
- 10 new tests across 4 categories: encoding edge cases (5), signed tx cross-validation (2), JS→Elixir serialization (2), regression guards (1)
- Documents asymmetries: empty calls (Elixir accepts, JS throws CallsEmptyError), keyAuthorization dummy data (Elixir accepts, JS validates key type), sender signature yParity normalization (our 0x00 → ox/tempo's 0x1b)

**Key decisions:**
- Used Hardhat deterministic test keys (account #0 and #1) — public, not secrets
- Golden hex test generates at test time via RFC 6979 deterministic signing rather than hardcoding — avoids stale hex if upstream signing changes
- `tx.raw` is already a hex string — no double-encoding with `Base.encode16`

#### TxEnvelopeTempo Cross-Validation via QuickBEAM + esbuild

**What was done:**
- Runtime cross-validation of our Elixir 0x76 RLP encoding against ox/tempo's TypeScript `TxEnvelopeTempo.deserialize`/`serialize` via QuickBEAM
- New `MPP.Test.OxTempoBundle` helper: bundles ox/tempo into a QuickBEAM-loadable IIFE using esbuild, with caching to `_build/test/`
- Entry point at `test/support/ox_tempo_entry.mjs` — exports only `deserialize`, `serialize`, `serializedType`, `feePayerMagic`
- Six new cross-validation tests: Elixir->JS unsigned transfer, fee payer placeholder, JS->Elixir serialize, full round-trip, multi-call, protocol constants

**Key decisions:**
- **esbuild over OXC bundler** — OXC's bundler mixes ESM and CJS resolution for `@noble/*` dependencies, producing `let`/`const` redefinitions and `require()` calls that QuickJS rejects. esbuild respects ESM export conditions throughout, producing a clean ~154KB IIFE.
- Bundle cached to `_build/test/ox_tempo_bundle.js` — rebuilt only when entry point or ox `package.json` changes
- `npx esbuild` used at test time (not a dev dependency) — keeps the dependency footprint minimal

#### Security Fix: Fee-Payer Call Scope Validation

**What was done:**
- **[Critical] Added `validate_call_scope/1` to `MPP.Tempo.Transaction`.** The fee-payer co-signing path previously checked for a valid payment call but co-signed and broadcast the entire transaction — including any rogue extra calls the client may have bundled. The server was sponsoring gas for all calls.
- New selectors: `@approve_selector`, `@swap_exact_amount_out_selector`
- New constant: `@stablecoin_dex_address` (canonical Tempo DEX address from viem/tempo)
- `@call_scopes` whitelist of 4 allowed ordered selector patterns, matching mppx `callScopes` (fee-payer.ts:21-26)
- Validation checks: selector pattern match, approve spender = DEX, swap target = DEX
- Wired into `verify/2` pipeline between `find_payment_call` and `maybe_cosign_fee_payer` — fires only when `fee_payer: true`
- `TempoTxBuilder.build_fee_payer_multicall/1` for building multi-call test transactions
- QuickBEAM cross-validation test against viem/tempo canonical source (tagged `:cross_validation`)
- Integration tests for fee-payer co-signing path against Moderato testnet

**Key decisions:**
- Error messages match TS reference exactly (lowercase): "disallowed call pattern in fee-payer transaction", "approve spender is not the DEX", "buy target is not the DEX"
- Cross-validation test loads viem/tempo ABIs via QuickBEAM and verifies selectors via keccak256 of canonical function signatures — catches drift if Tempo protocol evolves
- `swapExactAmountOut` actual signature is `(address,address,uint128,uint128)` (4 params, uint128 not uint256) — discovered during cross-validation

#### Task 13d: Fee Payer Support
**Completed** | [D:7/B:4/U:3 → Eff:0.5]

**What was done:**
- Server-side fee sponsorship for `feePayer: true` — server co-signs client transactions with domain `0x78` to pay transaction fees on behalf of the client
- Extended `MPP.Tempo.Transaction` struct with `fields` list preserving all RLP elements for reconstruction after co-signing
- New `cosign_fee_payer/3` function: recovers sender from client's signature, builds 0x78 domain signing preimage, signs with fee payer's private key, reconstructs complete 0x76 transaction with both signatures
- New predicates: `has_fee_payer_placeholder?/1`, `fee_token_empty?/1`
- `validate_config!/1` enforces `fee_payer_private_key` and `fee_token` when `fee_payer: true`
- `type="hash"` rejected when `feePayer: true` (per spec §Fee Payment: server cannot modify client-broadcast transactions)
- `TempoTxBuilder.build_fee_payer_transfer/1` for building test transactions with fee payer placeholder

**Key decisions:**
- Follows mpp-rs inline co-signing approach (not mppx's external relay) — self-contained, no external service dependency
- 0x78 signing domain for fee payer preimage includes `sender_address` (recovered from client sig) and `fee_token` (server's choice), replaces `fee_payer_signature` field position
- `fields` stored as raw RLP-decoded list — avoids re-encoding issues by preserving exact binary representations for untouched fields
- Config-based fee token (`"fee_token"` required in method_config) rather than auto-discovery from chain defaults
- Co-signing happens after payment call validation but before dedup store reservation — ensures only valid transactions get co-signed

#### Fix: Tempo Store Dedup — Per-Path Semantics and Error Handling

**What was done:**
- **[High] Fixed hash path burning hashes on transient failures.** The hash path (`type="hash"`) now uses check → verify on-chain → mark, matching mppx (Charge.ts:126-141). Previously, hashes were reserved before verification, so transient RPC failures permanently burned legitimate retries.
- **[Medium] Fixed non-atomic fallback ignoring `put/2` errors.** The sequential `get` + `put` fallback in `reserve_hash_atomic` now propagates `{:error, reason}` from `put/2` instead of unconditionally returning `:ok`.
- **[Medium] Fixed `safe_dedup_post_broadcast` not catching process exits.** Added `catch :exit` alongside `rescue` — dead Agent/GenServer processes now handled correctly, not just raised exceptions.
- Removed unused `alias MPP.Tempo.Store` from test file
- Added regression test: hash path allows retry after transient RPC failure
- Added regression test: dead store process doesn't crash post-broadcast dedup

**Key decisions:**
- Hash and transaction paths intentionally use **different dedup semantics** matching their risk profiles: hash path marks only after success (burned hash = bad UX); transaction path reserves atomically before broadcast (duplicate broadcast = correctness/money problem). This matches mppx's two-path design.
- `check_and_mark/2` remains `@optional_callbacks`, used only on the transaction path where atomic reservation matters for concurrent request safety

#### Task 13f: Transaction Dedup Store
**Completed** | [D:4/B:5/U:4 → Eff:1.13]

**What was done:**
- New `MPP.Tempo.Store` behaviour with `get/1`, `put/2`, and optional `check_and_mark/2` callbacks for pluggable dedup backends
- Optional `"store"` key in `method_config` — when `nil` (default), library stays stateless; when set, enables within-challenge replay protection
- Hash reservation happens before network I/O (receipt fetch / broadcast) to prevent concurrent replay attacks
- Transaction path: reserves store key before broadcast; post-broadcast dedup catches malleable variants when on-chain hash differs from input
- Post-broadcast store writes are best-effort with crash protection — payment already succeeded on-chain, so store failure doesn't fail the request
- Integration test against Moderato testnet: submit same hash credential twice through full 402 flow, second rejected with "already used"
- Agent-based `MPP.Test.TempoMemoryStore` in `test/support/` with atomic `check_and_mark/2` for test use

**Key decisions:**
- Store is optional (matching mpp-rs pattern) rather than defaulting to in-memory (mppx pattern) — library users manage their own state, more Elixir-idiomatic
- No built-in store implementation in `lib/` — ETS/Redis/database stores are trivial to implement and app-specific
- Raw hex string used as store key (no keccak256 pre-hash) — deterministic for identical signed transactions, avoids adding a hash dependency
- Store key format `"mpp:charge:<lowercase_hash>"` matches mpp-rs convention
- `check_and_mark/2` optional callback for atomic stores; sequential `get` + `put` fallback for simple stores

#### Task 13g: Optimistic Broadcast Mode
**Completed** | [D:3/B:4/U:3 → Eff:1.17]

**What was done:**
- Added `"wait_for_confirmation"` config option to `method_config` (default `true`, preserving existing behavior)
- When `false`, the `type="transaction"` verify path uses a two-step optimistic flow: simulate the payment call via `eth_call` with structured params (`to` + `data`), then broadcast via async `eth_sendRawTransaction` and return an optimistic receipt without waiting for block inclusion
- `broadcast_and_verify/6` accepts the full `Transaction` struct — confirmation path uses `tx.raw` for sync broadcast, optimistic path uses `tx.calls[0]` for simulation and `tx.raw` for async broadcast
- New private functions: `simulate_payment_call/3` (eth_call with call target + calldata), `broadcast_transaction_async/3` (async broadcast returning tx hash only)
- Matches the mppx TypeScript reference implementation (Charge.ts:233-277)
- Integration tests against Moderato testnet: happy path (optimistic receipt → confirmed on-chain) and revert path (impossible amount caught by simulation)

**Key decisions:**
- Simulation uses structured `eth_call` params (`{to, data}` from the deserialized payment call), not raw serialized tx bytes — matches mppx's `viem_call` which unpacks transaction fields. Code review caught the original implementation passing raw 0x76 bytes as `eth_call` `data`, which Moderato rejects.
- `eth_call` used for simulation (matching mppx's `viem_call`), not `eth_estimateGas` — catches state-level reverts, not just gas estimation
- Optimistic mode only applies to `type="transaction"` — `type="hash"` always verifies the existing receipt (client already broadcast)
- No dedup store integration (Task 13f) — optimistic path works without it; HMAC-bound challenges prevent cross-request replay
- Receipt has identical structure to confirmed receipt — the trade-off is implicit (server opted into optimistic mode at init time)

#### Task 13h: Transaction Path Integration Test
**Completed** | [D:4/B:5/U:5 → Eff:1.25]

**What was done:**
- Integration tests against Tempo Moderato testnet for `type="transaction"` credential path — the server-broadcast flow where the client sends a signed 0x76 Tempo Transaction and the server deserializes, verifies, broadcasts, and checks the receipt
- New `test/support/tempo_tx_builder.ex` module that constructs and signs real 0x76 Tempo Transactions using Signet (secp256k1) and ExRLP — first Elixir implementation of Tempo Transaction building
- Three tests: happy path (build signed tx → credential → server broadcasts → receipt with on-chain tx hash), wrong recipient rejection, wrong amount rejection
- Tagged existing Tempo chain primitives with `TODO(onchain_tempo)` for future extraction to `onchain_tempo` package
- Added Task 23 (onchain_tempo extraction) to roadmap

**Key decisions:**
- Tx builder lives in `test/support/` (not `lib/`) — mpp is server-side verification only; building/signing is client-side work that belongs in `onchain_tempo`
- Signing preimage excludes `sender_signature` from RLP (matching EIP-1559 pattern where signature fields are appended after signing, not included in the hash)
- `key_authorization?` field omitted entirely when absent (14-field RLP, not 15) — the Tempo node discriminates by peeking at the next byte (`>= 0xc0` = list = key_auth present)
- `fee_payer_signature = <<>>` (RLP `0x80` = absent) when client pays fees, not `<<0>>` (which is a 1-byte value)
- Moderato minimum base fee is 20 gwei — default `max_fee_per_gas` set to 25 gwei with 1 gwei priority fee

#### Task 13c: Transaction Credential Verification
**Completed** | [D:6/B:6/U:5 → Eff:0.92]

**What was done:**
- `verify/2` for `type="transaction"` credentials — full pre-broadcast verification + broadcast + receipt check
- New `MPP.Tempo.Transaction` module (`lib/mpp/tempo/transaction.ex`) for 0x76 Tempo Transaction RLP deserialization and payment call matching
- Deserializes the RLP envelope, extracts `chain_id` (index 0) and `calls` (index 4), preserves raw hex for broadcast passthrough
- Pre-broadcast verification: iterates transaction calls, matches `transfer(address,uint256)` or `transferWithMemo(address,uint256,bytes32)` selectors against the challenge's currency/recipient/amount/memo
- Chain ID validation prevents cross-chain replay
- Broadcasts via Tempo's synchronous `eth_sendRawTransactionSync` JSON-RPC method, which waits for block inclusion (~500ms) and returns the receipt directly — eliminates the async broadcast race condition where a separate receipt fetch arrives before mining
- Memo enforcement follows same spec rules as hash path: when memo configured, requires `transferWithMemo` with matching memo

**Key decisions:**
- Transaction module returns `{:error, String.t()}` (no MPP.Errors dependency) — verify/2 wraps into protocol errors via `else` clause, keeping the module cleanly separated
- Only `chain_id` and `calls` are extracted from the RLP envelope — all other fields (gas, nonce, signatures) are opaque for payment verification purposes
- RLP field positions confirmed against the official Tempo Transaction Specification at docs.tempo.xyz
- ABI selectors match mpp-rs constants: `transfer` = `0xa9059cbb`, `transferWithMemo` = `0x95777d59`
- Constant-time address comparison via `:crypto.hash_equals/2`
- `ExRLP.decode/1` dialyzer warning suppressed — transitive dep (signet → onchain) with default-arg arity mismatch
- Fee payer co-signing deferred to Task 13d, transaction dedup to Task 13f, optimistic broadcast to Task 13g

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
