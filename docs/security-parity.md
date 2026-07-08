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
the parity set is well-bounded. Last full audit: 2026-06-30.

---

## Published upstream advisories

| Advisory | Sev | What it covered | Our status |
|---|---|---|---|
| mppx `GHSA-8x4m-qw58-3pcx` / mpp-rs `GHSA-fxc9-7j2w-vx54` | CRITICAL 9.3 | "Multiple payment bypass & griefing" — published upstream advisory | **Partial — see component rows.** Charge-path replay, Stripe replay, fee-payer drain, proof binding, fee-token allowlist, and hosted fee-payer fills: ✓. Remaining session work: 📋 Task 50. |
| mppx `GHSA-mv9j-8jvg-j8mr` / CVE-2026-34209 | HIGH 7.5 | Published upstream session advisory | 📋 **Task 50** — sessions not yet implemented; detailed acceptance criteria remain out of this public ledger until fixed. |
| mppx `GHSA-8mhj-rffc-rcvw` / CVE-2026-34210 | MEDIUM 5.4 | Stripe charge replay via missing `Idempotent-Replayed` check | ✓ Stripe replay is covered by the `Idempotent-Replayed` rejection plus Plug-level credential dedup (Tasks 35 + 64). |

mpp-specs: no advisories.

---

## ✓ Confirmed parity (closed in our impl)

| Upstream fix | What it guards | Our implementation |
|---|---|---|
| mpp-rs #175 / #296 constant-time HMAC | Timing side-channel on challenge-ID compare | `Plug.Crypto.secure_compare/2` — `challenge.ex:85`, `body_digest.ex:71` |
| mpp-rs #299 / mppx `ec1ad50` (#562) token cap | Memory-exhaustion DoS via oversized header token | `@max_token_len 16 KiB` enforced pre-parse at all 4 client-input sites — credential token, receipt token, challenge `request` param (Task 65, done), and `Accept-Payment` header (2026-07-08) |
| mpp-specs #204 `hash`+`feePayer` MUST REJECT | Bypass of sponsorship validation via hash credential | `tempo.ex:139` rejects `type="hash"` when `fee_payer: true` |
| mppx #501 escape challenge quoted strings | Header / CRLF injection in `WWW-Authenticate` | `escape_quoted/1` raises on CR/LF — `headers.ex:369-377`; parser rejects CR/LF in values `headers.ex:478-479` |
| mppx #497 require expiring nonce for fee payer | Fixed-nonce replay of sponsored tx | `@expiring_nonce_key` checked in `FeePayerPolicy` — `fee_payer_policy.ex:224-230` |
| Inbound `GHSA-vv77-66rf-pm86` (no gas limit) + `GHSA-qpxh-ff8m-c62v` (access list) | Gas-price / total-fee / validity / access-list drain of sponsor wallet | `FeePayerPolicy` five ceilings + empty-access-list check — `fee_payer_policy.ex:76-81,191-263` |
| mpp-rs #293 / mppx #534 (`e80feeb`) pre-broadcast simulation | Sponsor commits gas for a co-signed tx that would revert on-chain | `MPP.Methods.Tempo` simulates the full co-signed tx via `eth_simulateV1` before broadcast on both paths; reverting → reject, -32601 → graceful skip, other RPC error → fail closed — `tempo.ex` (Task 59, done) |
| mpp-rs #219 prevent caching of 402 | Intermediary caches serving stale challenges | `cache-control: no-store` on all error responses — `plug.ex:293` |
| mpp-specs #210 verify-before-extract-SPT ordering | Stripe API call triggered before challenge validity confirmed | Pipeline runs `Challenge.verify` + expiry + request-match *before* `method.verify` — `verifier.ex:81-87` |
| mppx `GHSA-8mhj-rffc-rcvw` / CVE-2026-34210 + generic charge replay hardening | Reused Stripe / EVM credentials inside the challenge window | `MPP.Methods.Stripe` rejects `Idempotent-Replayed: true`; `MPP.Plug` supports shared credential dedup keyed by challenge id + payload hash, using the required atomic `check_and_mark/2` (non-atomic stores rejected at init, 0.7.0) — `stripe.ex:226-229`, `plug.ex:302-382` |
| mppx #450 reject forged credential metadata | Client `meta` overriding server-derived request | No client `meta` field exists; server re-derives request from its own charge and pins it — `verifier.ex:151-158` |
| mpp-specs #285 / mppx #570 non-empty challenge id | Empty `id` undermining HMAC binding | Rejected via HMAC recomputation — empty `id` never matches a real MAC — `challenge.ex:82-85` |
| (defense-in-depth) JCS recursion | Stack-exhaustion via deeply nested input | Not attacker-reachable: `JCS.canonicalize/1` runs only on server-controlled data (`charge`); the credential's echoed `request` stays a raw string, never re-canonicalized — `verifier.ex:151-156`, `jcs.ex` |
| mpp-rs #286 fee-payer token allowlist | Sponsor co-signing arbitrary TIP-20 fee tokens | `FeePayerPolicy.fee_token_allowed?/3` + `default_allowed_fee_tokens/1`; enforced before co-sign — `fee_payer_policy.ex`, `tempo.ex` (Task 46) |
| mppx #532 / #253 EIP-712 proof v3 wallet binding | Zero-amount bypass / proof replay across wallets | `MPP.Methods.Tempo.Proof` + `type="proof"` verify; store dedup `mpp:proof:<challenge_id>` — `proof.ex`, `tempo.ex` (Task 46) |
| mpp-rs `384c4fe` hash-credential source DID | Forged / wrong-chain `did:pkh` source | `MPP.DID.parse_evm_did/1` + chain match — `did.ex`, `tempo.ex` (Task 46) |
| mppx #537 Stripe charge externalId binding | Credential externalId overriding route correlation | `check_external_id_binding/2` — `stripe.ex` (Task 46) |
| mpp-specs #266 PaymentWitness externalId | Session receipt wire field | Optional `external_id` / `externalId` on `SessionReceipt` — `session_receipt.ex` (Task 46) |
| mppx #579 proof access-key authorization | Zero-amount proof signed by delegated access key | `recover_authorized_proof_signer` + AccountKeychain `getKey` active check — `proof.ex`, `access_key.ex`, `tempo.ex` (Task 69) |
| mpp-rs store-on-by-default (`server/tempo.rs`) / mppx `Store.memory()` default | Replay of on-chain tx/credential when no store is configured (issue #7; published `GHSA-vp5h-xh25-44wf`) | `MPP.Tempo.Store.resolve/1` default-on + app-started `ConCacheStore`; `store: false` is the explicit opt-out — `store.ex`, `application.ex` (Task 76, ships 0.7.0) |
| mpp-rs `put_if_absent` fails closed / mppx atomic `update` | TOCTOU replay window in non-atomic dedup commit (published `GHSA-w8j7-7qc3-5f24`) | `check_and_mark/2` is a required callback; non-atomic stores rejected at init; sequential get+put fallback removed — `store.ex`, `tempo.ex`, `evm.ex`, `plug.ex` (Task 77, ships 0.7.0) |

---

## 📋 Tracked as roadmap work (parity pending)

| Upstream fix | Where tracked |
|---|---|
| Hosted fee-payer fills (mppx #536 / #538 / #584) | ✓ `fee_payer_url` + `MPP.Methods.Tempo.HostedFeePayer` |
| Session integrity parity for published upstream advisories | 📋 **Task 50** (sessions unbuilt; details stay out of this public ledger until fixed) |
| Client-side Tempo chain pinning (mpp-rs `8880cf7`) | 📋 Task 33e — built-in Tempo provider |

---

## Open hardening items

A small number of secure-defaults / defense-in-depth parity items from the upstream audit remain
open. Per the disclosure policy above, their detail is tracked in **private draft security
advisories** (Security → Advisories), not enumerated here. Each moves to the ✓ table when its fix
ships. As of the last audit: **4 open items** (none a confirmed standalone critical; the
exploitable-replay facets are already covered by Tasks 35/46/50 above).

---

*Maintained by the SDK parity audit + the `sdk-delta-watch` routine. New upstream security
deltas: parity-confirmed → ✓ row here; genuine gap → private advisory, never a public row.*
