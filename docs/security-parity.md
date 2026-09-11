# Security Parity Ledger — MPP Elixir vs. reference SDKs

**What this is.** A standing record of every published security advisory and security/wire-format
fix in the MPP reference SDKs (`mppx`, `mpp-rs`, `mpp-specs`), mapped to whether our Elixir
implementation closes it. It exists so upstream security work is *tracked* against our code, not
silently assumed — and so the `sdk-delta-watch` routine has a durable artifact to append to.

**Scope & disclosure policy.** This file records only **closed / confirmed-parity** items (✓) and
items **already tracked as roadmap work** (📋). Per `SECURITY.md`, detail on *open, unfixed*
hardening gaps is **not** published here — it lives in private draft GitHub security advisories
(Security → Advisories) until a fix ships, at which point the item moves here as a ✓ row and the
advisory is published with the patched release. This is coordinated disclosure: a public list of
our unpatched weaknesses in a deployed, money-handling library would be an attacker's checklist.

**Source basis.** The reference clones in `refs/` are shallow (mpp-rs 72 commits, mppx 174,
mpp-specs 24, truncated ~2026-03). The **four published advisories below (2026-03-26) are the
authoritative historical security record**; every named fix falls inside the visible window, so
the parity set is well-bounded. Last full audit: 2026-06-30; last sdk-delta-watch sweep: 2026-09-11.

---

## Published upstream advisories

| Advisory | Sev | What it covered | Our status |
|---|---|---|---|
| mppx `GHSA-8x4m-qw58-3pcx` / mpp-rs `GHSA-fxc9-7j2w-vx54` | CRITICAL 9.3 | "Multiple payment bypass & griefing" — published upstream advisory | **Partial — see component rows.** Charge-path replay, Stripe replay, fee-payer drain, proof binding, fee-token allowlist, and hosted fee-payer fills: ✓. Remaining session work: 📋 Task 50. |
| mppx `GHSA-mv9j-8jvg-j8mr` / CVE-2026-34209 | HIGH 7.5 | Published upstream session advisory | 📋 **Task 50** shipped the session machinery; component parity against this advisory is re-audited per sweep and any residual is counted (not enumerated) under "Open hardening items". |
| mppx `GHSA-8mhj-rffc-rcvw` / CVE-2026-34210 | MEDIUM 5.4 | Stripe charge replay via missing `Idempotent-Replayed` check | ✓ Stripe replay is covered by the `Idempotent-Replayed` rejection plus Plug-level credential dedup (Tasks 35 + 64). |

mpp-specs: no advisories.

---

## Our published advisories & CVE IDs

Every advisory published on `ZenHive/mpp`, with its CVE assignment. Hex packages fall under the
**Erlang Ecosystem Foundation CNA** — GitHub declines to assign for them and routes requests to
the EEF (`cna@erlef.org`), which assigned the first three on 2026-07-17, the next four on 2026-08-19, and the two 0.16.1 fee-payer CVEs on 2026-09-06. A CNA-assigned CVE is not
backlinked automatically — the ID was attached to each GitHub advisory via
`gh api -X PATCH repos/ZenHive/mpp/security-advisories/<ghsa> -f cve_id=<cve>` (2026-08-18, 2026-09-04 and 2026-09-11).
OSV carries both the `CVE-` and the `EEF-CVE-` alias.

| Advisory | CVE | Sev | Fixed in | Subject |
|---|---|---|---|---|
| `GHSA-vv77-66rf-pm86` | `CVE-2026-59695` | HIGH 8.3 | 0.6.0 | Unbounded `max_fee_per_gas` in Tempo fee-payer — single-request wallet drain |
| `GHSA-qpxh-ff8m-c62v` | `CVE-2026-59694` | HIGH 8.3 | 0.6.0 | Unbounded access list in Tempo fee-payer inflates gas cost per payment |
| `GHSA-vj8p-hp9x-gh47` | `CVE-2026-59252` | HIGH 8.2 | 0.6.0 | Missing `gas_limit` validation in Tempo fee-payer enables wallet drain |
| `GHSA-wvj9-hmjr-7359` | — (not requested: hardening backfill, not a discrete vulnerability) | MEDIUM | 0.6.1 | Hardening backfill from the upstream SDK audit — **not** a single discrete vulnerability; a CVE is likely inappropriate here |
| `GHSA-w8j7-7qc3-5f24` | `CVE-2026-73829` | MEDIUM | 0.7.0 | Non-atomic Tempo hash-credential dedup — replay under a concurrent race |
| `GHSA-vp5h-xh25-44wf` | `CVE-2026-67581` | HIGH | 0.7.0 | EVM on-chain transfer proof not single-use — cross-challenge replay |
| `GHSA-34g7-vx6g-82mq` | `CVE-2026-73136` | HIGH | 0.8.0 | Static Tempo memo disables per-challenge attribution binding — third-party replay |
| `GHSA-j4j7-7xpr-c7cr` | `CVE-2026-73541` | MEDIUM | 0.12.0 | Fee-payer sponsorship bounds each tx individually but not aggregate exposure |
| `GHSA-5qrp-r24c-w6jr` | `CVE-2026-82750` | HIGH | 0.16.1 | Tempo fee-payer sponsorship never inspected the EIP-7702 authorization list — sponsored gas drain and free account delegation (reported by kai-kka) |
| `GHSA-rpwj-vrf7-4x36` | `CVE-2026-82751` | HIGH | 0.16.1 | Tempo fee-payer sponsorship never bounded the `0x76` key-authorization field — sponsored gas drain and free key provisioning (reported by kai-kka) |
| `GHSA-8c63-r789-xrrf` | — (CVE request to the EEF CNA pending) | HIGH | 0.16.2 | Session voucher that adds no new funds was served without a charge — unlimited units after one paid voucher (mpp-rs #415 parity) |
| `GHSA-p9fv-9w58-95x2` | — (CVE request to the EEF CNA pending) | MEDIUM | 0.16.2 | Tempo subscription key authorization was not bound to the issuing challenge — captured activation credential replayable under a fresh challenge (mppx #882 parity) |
| `GHSA-8x7x-5j8g-8hcx` | — (CVE request to the EEF CNA pending) | MEDIUM | 0.16.2 | Tempo pre-broadcast dedup reserve keyed on the caller-supplied encoding — a non-canonical re-encoding reserved a second slot (mppx #818 parity) |
| `GHSA-82qh-vrvm-gqvc` | — (CVE request to the EEF CNA pending) | MEDIUM | 0.16.2 | `Payment-Receipt` and `Cache-Control: private` written before the downstream app ran — consumer `Cache-Control` could expose paid responses to shared caches (mpp-rs #381/#399 parity) |
| `GHSA-65c4-v2vw-rr64` | — (CVE request to the EEF CNA pending) | LOW | 0.17.0 | Tempo canonical dedup reserve did not normalize one signature re-encoding — a second slot for one signed transaction; the live node rejected that encoding at broadcast (residual of `GHSA-8x7x-5j8g-8hcx`) |

The first three were reported by Kian Kai Ang (University of Sydney). CVE assignment for the
remaining four was requested from the EEF CNA on 2026-08-18.

---

## ✓ Confirmed parity (closed in our impl)

| Upstream fix | What it guards | Our implementation |
|---|---|---|
| mpp-rs #415 (`d859a13`) session voucher acceptance | Every accepted voucher adds funds | `MPP.Session.Actions` enforces a positive delta and the configured minimum in the same atomic `Store.update/3` callback as the spend; deterministic concurrency tests cover identical and increasing vouchers (Task 111). |
| mpp-rs #175 / #296 constant-time HMAC | Timing side-channel on challenge-ID compare | `Plug.Crypto.secure_compare/2` — `challenge.ex:85`, `body_digest.ex:71` |
| mpp-rs #299 / mppx `ec1ad50` (#562) token cap | Memory-exhaustion DoS via oversized header token | `@max_token_len 16 KiB` enforced pre-parse at all 4 client-input sites — credential token, receipt token, challenge `request` param (Task 65, done), and `Accept-Payment` header (2026-07-08) |
| mpp-specs #204 `hash`+`feePayer` MUST REJECT | Bypass of sponsorship validation via hash credential | `tempo.ex:139` rejects `type="hash"` when `fee_payer: true` |
| mppx #501 escape challenge quoted strings | Header / CRLF injection in `WWW-Authenticate` | `escape_quoted/1` raises on CR/LF — `headers.ex:369-377`; parser rejects CR/LF in values `headers.ex:478-479` |
| mppx #497 require expiring nonce for fee payer | Fixed-nonce replay of sponsored tx | `@expiring_nonce_key` checked in `FeePayerPolicy` — `fee_payer_policy.ex:224-230` |
| Inbound `GHSA-vv77-66rf-pm86` (no gas limit) + `GHSA-qpxh-ff8m-c62v` (access list) | Gas-price / total-fee / validity / access-list drain of sponsor wallet | `FeePayerPolicy` five ceilings + empty-access-list check — `fee_payer_policy.ex:76-81,191-263` |
| Inbound `GHSA-5qrp-r24c-w6jr` (EIP-7702 list) + `GHSA-rpwj-vrf7-4x36` (key authorization) | Sponsor gas drain and free account delegation / key provisioning through the two `0x76` envelope fields the policy never read | `FeePayerPolicy` requires an empty authorization list and rejects a key authorization on the charge path; subscription activation pins the exact verified authorization via `expect_key_authorization/2` — `fee_payer_policy.ex:229-231,376-410` (Task 102, ships 0.16.1) |
| mppx #602 non-canonical fee-payer tx (intrinsic-gas family) | Padded/non-canonical calldata or nonzero call `value` inflates the sponsor's intrinsic gas within the price ceilings | `FeePayerPolicy` rejects nonzero per-call value + requires byte-exact-canonical calldata for recognized TIP-20/DEX selectors before co-sign — `fee_payer_policy.ex` (0.9.0) |
| mppx #818 (`adcf3b5`) canonical Tempo envelope before reserve/broadcast | One signed Tempo transaction maps to one dedup slot regardless of encoding | `MPP.Methods.Tempo` re-encodes the deserialized 0x76 envelope before FeePayerPolicy, reserve, hosted fill, and any RPC; reserve and post-broadcast keys are keccak256 of those bytes — `tempo.ex` (Task 104, Task 114) |
| mpp-rs #293 / mppx #534 (`e80feeb`) pre-broadcast simulation | Sponsor commits gas for a co-signed tx that would revert on-chain | `MPP.Methods.Tempo` simulates the full co-signed tx via `eth_simulateV1` before broadcast on both paths; reverting → reject, -32601 → graceful skip, other RPC error → fail closed — `tempo.ex` (Task 59, done) |
| mpp-rs #219 prevent caching of 402 | Intermediary caches serving stale challenges | `cache-control: no-store` on all error responses — `plug.ex:293` |
| mpp-specs #210 verify-before-extract-SPT ordering | Stripe API call triggered before challenge validity confirmed | Pipeline runs `Challenge.verify` + expiry + request-match *before* `method.verify` — `verifier.ex:81-87` |
| mppx `GHSA-8mhj-rffc-rcvw` / CVE-2026-34210 + generic charge replay hardening | Reused Stripe / EVM credentials inside the challenge window | `MPP.Methods.Stripe` rejects `Idempotent-Replayed: true`; `MPP.Plug` supports shared credential dedup keyed by challenge id + payload hash, using the required atomic `check_and_mark/2` (non-atomic stores rejected at init, 0.7.0) — `stripe.ex:226-229`, `plug.ex:302-382` |
| mppx #450 reject forged credential metadata | Client `meta` overriding server-derived request | No client `meta` field exists; server re-derives request from its own charge and pins it — `verifier.ex:151-158` |
| mpp-specs #285 / mppx #570 non-empty challenge id | Empty `id` undermining HMAC binding | Rejected via HMAC recomputation — empty `id` never matches a real MAC — `challenge.ex:82-85` |
| (defense-in-depth) JCS recursion | Stack-exhaustion via deeply nested input | Not attacker-reachable: `JCS.canonicalize/1` runs only on server-controlled data (`charge`); the credential's echoed `request` stays a raw string, never re-canonicalized — `verifier.ex:151-156`, `jcs.ex` |
| mpp-rs #286 fee-payer token allowlist | Sponsor co-signing arbitrary TIP-20 fee tokens | `FeePayerPolicy.fee_token_allowed?/3` + `default_allowed_fee_tokens/1`; enforced before co-sign — `fee_payer_policy.ex`, `tempo.ex` (Task 46) |
| mppx #532 / #253 + mpp-rs #318 EIP-712 proof v3 wallet binding | Zero-amount bypass / proof replay across wallets | `MPP.Methods.Tempo.Proof` — domain version `"3"` with the `account` field in the `Proof` struct, matching `refs/mpp-rs/src/protocol/methods/tempo/proof.rs` (`DOMAIN_VERSION = "3"`, `struct Proof { address account; string challengeId; string realm; }`); store dedup `mpp:proof:<challenge_id>` — `proof.ex:22-43`, `tempo.ex` (Task 46) |
| mpp-rs `384c4fe` hash-credential source DID | Forged / wrong-chain `did:pkh` source | `MPP.DID.parse_evm_did/1` + chain match — `did.ex`, `tempo.ex` (Task 46) |
| mppx #537 Stripe charge externalId binding | Credential externalId overriding route correlation | `check_external_id_binding/2` — `stripe.ex` (Task 46) |
| mpp-specs #266 PaymentWitness externalId | Session receipt wire field | Optional `external_id` / `externalId` on `SessionReceipt` — `session_receipt.ex` (Task 46) |
| mppx #579 proof access-key authorization | Zero-amount proof signed by delegated access key | `recover_authorized_proof_signer` + AccountKeychain `getKey` active check — `proof.ex`, `access_key.ex`, `tempo.ex` (Task 69) |
| mpp-rs store-on-by-default (`server/tempo.rs`) / mppx `Store.memory()` default | Replay of on-chain tx/credential when no store is configured (issue #7; published `GHSA-vp5h-xh25-44wf`) | `MPP.Tempo.Store.resolve/1` default-on + app-started `ConCacheStore`; `store: false` is the explicit opt-out — `store.ex`, `application.ex` (Task 76, ships 0.7.0) |
| mpp-rs `put_if_absent` fails closed / mppx atomic `update` | TOCTOU replay window in non-atomic dedup commit (published `GHSA-w8j7-7qc3-5f24`) | `check_and_mark/2` is a required callback; non-atomic stores rejected at init; sequential get+put fallback removed — `store.ex`, `tempo.ex`, `evm.ex`, `plug.ex` (Task 77, ships 0.7.0) |
| mppx #646 hosted fee-payer signature normalization | Sponsor cosignature mis-encoded when the hosted fee payer returns `yParity` as a hex string rather than a number, yielding an invalid or wrong-recovery co-signed tx | `parse_y_parity/1` already accepts integer, hex-string, and legacy `v` forms and validates the recovery id before RLP encoding — `hosted_fee_payer.ex:195-209` (broader than mppx's `Number()` coercion) |
| mppx #699 / #707 aggregate sponsor fee budget (our published `GHSA-j4j7-7xpr-c7cr`) | Per-transaction ceilings bound each sponsored tx in isolation, so N concurrent sponsored requests commit N × `max_total_fee` of sponsor exposure — unbounded in aggregate | `MPP.Methods.Tempo.SponsorBudget` — fail-closed aggregate in-flight fee + reservation-count ceilings, pinned per sponsor identity and enforced in one atomic store update; reserved **before** co-sign, three-phase ownership (`prepared`/`broadcasting`/`pending`) with per-request random ids, released only on an observed terminal receipt or conservative chain-valid expiry, state-derived TTL, opt-in bounded receipt reconciliation. Requires an explicitly selected atomic store (`Store.update/3`); the bound is scoped to that shared store. `mpp-rs` has no equivalent — mppx is the sole prior art — `sponsor_budget.ex`, `tempo.ex` (Task 78, ships 0.12.0) |
| — hardening divergence beyond both SDKs (residual of our published `GHSA-34g7-vx6g-82mq`) | Front-running race on Tempo hash/transaction paths: dedup keyed on tx hash alone, presenter identity never proven (both SDKs default expected sender to `receipt.from` — mpp-rs `verify_hash`, mppx `Charge.ts`) | Opt-in `"require_presenter_binding"`: presenter signs the proof path's EIP-712 envelope (MPP v3 `{account, challengeId, realm}`) with the transfer sender's wallet or an authorized access key; hash path requires a matching `source` DID; advertised as `presenterBinding` in 402 details — `tempo.ex` (Task 75, ships 0.8.0) |
| mpp-rs #378 reject unterminated quoted-string (commit 28c7049, 2026-08-08) | Challenge params silently truncated/misparsed from a malformed quoted value | Already rejected: `parse_quoted_string("", _)` → `{:error, :invalid_auth_params}` — `headers.ex:388` (confirmed 2026-08-18 sweep) |
| mpp-rs #379 reject non-letter method identifiers (commit 7a6e517, 2026-08-10) | Method-name confusion / smuggling via non-`1*LOWERALPHA` identifiers | Already rejected: `Challenge.valid_method_name?/1` enforces the spec ABNF at parse time and at `MPP.Plug.init/1` — `challenge.ex:174-176` |
| mppx #766 quote-aware multi-challenge splitting (commit f7f8e58, 2026-08-05) | Decoy scheme text inside a quoted auth-param value (e.g. `Basic realm="Payment x"`) misparsed as a challenge boundary | Already immune: `MPP.Headers.SchemeSplitter` tracks quoted-string state and requires a start-or-comma boundary before a scheme token — `headers/scheme_splitter.ex` |
| mppx #789 prototype-named auth parameters (commit 106ba18, 2026-08-04) | `__proto__`/`constructor` param names polluting the parsed object (JS-specific) | Immune by construction: Elixir maps have no prototype chain, and unknown param names are strictly whitelist-rejected — `headers.ex:356-362` |
| mpp-rs #381 / #399 `cache-control: private` on paid responses (commits a8e5d6a / 3c75742) | Shared caches serving one client's paid response to others | Receipt and `private` are attached at send time only for successful HTTP responses, preserving application cache directives; errors carry `no-store` — `plug.ex`, `transports/json_rpc/plug.ex` (Task 103) |
| mppx #788 case-insensitive auth-param names (commit 9774481, 2026-08-04) | `Id=`/`ID=` rejected by a case-sensitive whitelist, or `id=`+`ID=` sneaking past duplicate detection | `parse_key/1` downcases ASCII names; RFC 9110 §11.2 is the authority (mpp-rs does not lowercase — `headers.rs:150`) — `headers.ex` (Task 83) |
| mpp-rs #377 reject malformed `expires` at parse (commit 0130060, 2026-08-10) | A non-RFC-3339 `expires` parsed and only failed later in the verifier | `Challenge.validate_fields/1` → `{:error, :invalid_expires}`; verifier `check_expiration/1` unchanged — `challenge.ex` (Task 83) |
| mpp-rs #383 + mppx Receipt `looseObject` preserve method-specific receipt fields (commit 8afed36, 2026-08-10) | Unknown top-level receipt keys (`originTxHash`, `subscriptionId`) silently dropped on decode | `MPP.Receipt` `extensions` + optional `subscription_id`; core keys cannot be shadowed — `receipt.ex` (Task 83) |
| mpp-rs #379 client half — refuse credentials across cross-origin redirects (commit 7a6e517, 2026-08-10) | Payment credential attached to a different origin after `Req` followed a redirect | `MPP.Client.Req` `:cross_origin_redirect`; `MPP.Client.Transport.HTTP` is passive so the contract is documented there and in the README — `req.ex`, `http.ex` (Task 83) |
| mpp-specs #325 (commit 9fa7dd7, 2026-08-24) align the EIP-712 Proof contract with the shipped v3 domain | Proof typed data hashed under a domain/field layout the on-chain contract does not recognize | Already v3-only: domain version 3, `Proof(account,challengeId,realm)` in spec order, access-key fallback; v1/v2 typed data is never constructed — `methods/tempo/proof.ex:22,36-45,128-138`, `tempo.ex:647-680` (confirmed 2026-09-04 sweep) |
| mpp-specs #321 (commit 43146b7, 2026-08-18) MUST NOT grant partial access on verification failure | Resource bytes / tool invocation leaking before verification settles | `MPP.Plug` is a gating plug: every failure `send_resp` + `halt`s before the downstream plug runs — `plug.ex:379-403,460-487`; MCP / JSON-RPC take the handler as a closure invoked only after `Verifier` succeeds — `mcp.ex:186-188` |
| mpp-specs #323 (commit 3fa03a9, 2026-08-18) require challenge-binding verification | Credential echoing a challenge the server never issued | All seven bound slots incl. `opaque` recomputed under the server's configured realm with constant-time compare, plus field-by-field pinning of method/intent/realm/opaque/request/digest/currency/recipient/chainId — `challenge.ex:82-118,220-247`, `verifier.ex:111-113,163-183` |
| mpp-specs #334 (commit 6de3b4d, 2026-08-24) `payment-expired` for expired challenges | Expired challenge reported as a generic invalid challenge | Expired → `payment-expired`; unknown/tampered → `invalid-challenge`, distinct paths — `verifier.ex:117-121,268-278`, `errors.ex:47,51` |
| mpp-rs #396 (commit fadc88c, 2026-08-24) credential retry uses the final same-origin response URL | Credential replayed against the pre-redirect URL, or across origins | Req's `redirect` step rebuilds the request at the final URL before our response step runs; cross-origin is refused — `client/req.ex:174-203` |
| mppx #857 (commit b12e65b, 2026-09-02) preserve multi-rail challenges in framework adapters | Adapter collapsing a multi-method 402 to one challenge | Our Plug is the adapter and emits every configured `:methods` entry — `plug.ex:96-126,228-258` |
| mpp-rs #413 (commit 72a9214, 2026-09-09) reject malformed human-readable amounts | `.`, `1e3`, `+1`, `1.2.3` normalizing to zero or a wrong base-unit value | Already rejected: `parse_units/2` requires digits-only integer/fraction parts, at least one non-empty, a single dot, no sign — `amount.ex:152-172` (confirmed 2026-09-11 sweep) |
| mppx #881 (commit baa0fd5, 2026-09-09) `allowKeyAuthorization` fee-payer policy knob (default allow) | Sponsored transaction installing a new access key at the sponsor's expense | Stricter than upstream: the charge path rejects any `0x76` key authorization outright and the subscription path pins the exact verified authorization — `fee_payer_policy.ex:229-232,392-410` (shipped 0.16.1, `GHSA-rpwj-vrf7-4x36`) |
| mppx #882 (commit 43ec92c, 2026-09-09) Tempo subscription key-authorization challenge witness | A subscription activation credential is bound to the issuing challenge: the ox `witness` field must be the 32-byte decoding of the challenge id, and six-element / TIP-1049 admin-or-account authorizations are rejected on this path | `MPP.Methods.Tempo.KeyAuthorization` requires the matching witness on `verify/3`, decodes the ox trailing `witness` / `isAdmin` / `account` tuple, and threads `witness` through `wallet_params/2` and `from_rpc/1` — `key_authorization.ex` (Task 112) |
| mppx #864 (commit 7949db6, 2026-09-04) expiring nonces for server-side session precompile calls | Nonce collisions when several server processes share one signer | Not applicable to our sessions (no server-side session broadcasts; channels are voucher-settled through `MPP.Session.Store`); the one server-signed Tempo path, sponsored subscription settlement, already uses the expiring nonce key — `subscription_transaction.ex:26,90` |
| mppx #814 / #832 / #845 / #842 / #823 hosted and remote fee-payer transport plumbing | — (viem-transport routing of the sponsor call; no bounding change) | Equivalent HTTP fill already in `MPP.Methods.Tempo.HostedFeePayer.fill/3` — `hosted_fee_payer.ex`, `tempo.ex:963-975` |
| mppx #887 (commit c0ce0fe, 2026-09-10) client recipient allowlist covers the primary recipient and every split | Hostile/misconfigured server redirecting a client TIP-20 transfer to an unlisted address, including via splits or the zero-amount proof path | `MPP.Client.Providers.Tempo` `:expected_recipients` — primary and every `methodDetails.splits` recipient must be listed; refused before RPC or signing; checksum-agnostic — `client/providers/tempo.ex` |

---

## 📋 Tracked as roadmap work (parity pending)

| Upstream fix | Where tracked |
|---|---|
| Hosted fee-payer fills (mppx #536 / #538 / #584) | ✓ `fee_payer_url` + `MPP.Methods.Tempo.HostedFeePayer` |
| Session integrity parity for published upstream advisories | 📋 **Task 50** (done) built the session machinery; residual hardening is tracked as counted open items, never enumerated here |
| Client-side Tempo chain pinning (mpp-rs `8880cf7`) | 📋 Task 33e — built-in Tempo provider |

---

## Open hardening items

**0 open items** as of 2026-09-12 — the draft advisory from the post-landing content review of the 0.16.2 wave (Task 114) shipped in 0.17.0 and was published the same day (`GHSA-65c4-v2vw-rr64`). The four draft advisories from the 2026-09-04 and 2026-09-11 upstream sweeps (Tasks 103, 104, 111, 112) shipped in 0.16.2 and were published the same day (`GHSA-82qh-vrvm-gqvc`, `GHSA-8x7x-5j8g-8hcx`, `GHSA-8c63-r789-xrrf`, `GHSA-p9fv-9w58-95x2`). The two inbound HIGH reports from 2026-09-04 shipped in 0.16.1 and were published the same day (`GHSA-5qrp-r24c-w6jr`, `GHSA-rpwj-vrf7-4x36`). Every advisory tracked against this repo is published with its
patched release; the earlier "4 open items" from
the 2026-06-24 upstream audit shipped in 0.6.1 and were disclosed as `GHSA-wvj9-hmjr-7359`
(published 2026-06-29). When a new gap is found, its detail goes to a **private draft security
advisory** (Security → Advisories) per the disclosure policy above and moves to the ✓ table when
the fix ships.

---

*Maintained by the SDK parity audit + the `sdk-delta-watch` routine. New upstream security
deltas: parity-confirmed → ✓ row here; genuine gap → private advisory, never a public row.*
