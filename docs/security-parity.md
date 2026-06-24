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
the parity set is well-bounded. Last full audit: 2026-06-24.

---

## Published upstream advisories

| Advisory | Sev | What it covered | Our status |
|---|---|---|---|
| mppx `GHSA-8x4m-qw58-3pcx` / mpp-rs `GHSA-fxc9-7j2w-vx54` | CRITICAL 9.3 | "Multiple payment bypass & griefing" — 10 vectors: charge/session replay, free requests, channel piggyback, fee-payer manipulation, Stripe replay | **Partial — see component rows.** Charge-path replay & fee-payer drain: ✓ / 📋 Task 46. Session vectors: 📋 Task 50 (unbuilt). Stripe replay: 📋 Task 35/64. |
| mppx `GHSA-mv9j-8jvg-j8mr` / CVE-2026-34209 | HIGH 7.5 | Tempo session close-voucher bypass via settled-amount equality (`<` vs `<=`) | 📋 **Task 50** — sessions not yet implemented; the `<=` boundary is a pinned acceptance criterion for the close handler. |
| mppx `GHSA-8mhj-rffc-rcvw` / CVE-2026-34210 | MEDIUM 5.4 | Stripe charge replay via missing `Idempotent-Replayed` check | 📋 **Task 35** (plug-level dedup) + **Task 64** (Stripe stub scenario asserting replay → 402). |

mpp-specs: no advisories.

---

## ✓ Confirmed parity (closed in our impl)

| Upstream fix | What it guards | Our implementation |
|---|---|---|
| mpp-rs #175 / #296 constant-time HMAC | Timing side-channel on challenge-ID compare | `Plug.Crypto.secure_compare/2` — `challenge.ex:85`, `body_digest.ex:71` |
| mpp-rs #299 / mppx `ec1ad50` (#562) token cap | Memory-exhaustion DoS via oversized header token | `@max_token_len 16 KiB` enforced pre-decode at all 3 parse sites — `headers.ex:53,228,235` (Task 65, done) |
| mpp-specs #204 `hash`+`feePayer` MUST REJECT | Bypass of sponsorship validation via hash credential | `tempo.ex:139` rejects `type="hash"` when `fee_payer: true` |
| mppx #501 escape challenge quoted strings | Header / CRLF injection in `WWW-Authenticate` | `escape_quoted/1` raises on CR/LF — `headers.ex:369-377`; parser rejects CR/LF in values `headers.ex:478-479` |
| mppx #497 require expiring nonce for fee payer | Fixed-nonce replay of sponsored tx | `@expiring_nonce_key` checked in `FeePayerPolicy` — `fee_payer_policy.ex:224-230` |
| Inbound `GHSA-vv77-66rf-pm86` (no gas limit) + `GHSA-qpxh-ff8m-c62v` (access list) | Gas-price / total-fee / validity / access-list drain of sponsor wallet | `FeePayerPolicy` five ceilings + empty-access-list check — `fee_payer_policy.ex:76-81,191-263` |
| mpp-rs #293 / mppx #534 (`e80feeb`) pre-broadcast simulation | Sponsor commits gas for a co-signed tx that would revert on-chain | `MPP.Methods.Tempo` simulates the full co-signed tx via `eth_simulateV1` before broadcast on both paths; reverting → reject, -32601 → graceful skip, other RPC error → fail closed — `tempo.ex` (Task 59, done) |
| mpp-rs #219 prevent caching of 402 | Intermediary caches serving stale challenges | `cache-control: no-store` on all error responses — `plug.ex:293` |
| mpp-specs #210 verify-before-extract-SPT ordering | Stripe API call triggered before challenge validity confirmed | Pipeline runs `Challenge.verify` + expiry + request-match *before* `method.verify` — `verifier.ex:81-87` |
| mppx #450 reject forged credential metadata | Client `meta` overriding server-derived request | No client `meta` field exists; server re-derives request from its own charge and pins it — `verifier.ex:151-158` |
| mpp-specs #285 / mppx #570 non-empty challenge id | Empty `id` undermining HMAC binding | Rejected via HMAC recomputation — empty `id` never matches a real MAC — `challenge.ex:82-85` |
| (defense-in-depth) JCS recursion | Stack-exhaustion via deeply nested input | Not attacker-reachable: `JCS.canonicalize/1` runs only on server-controlled data (`charge`); the credential's echoed `request` stays a raw string, never re-canonicalized — `verifier.ex:151-156`, `jcs.ex` |

---

## 📋 Tracked as roadmap work (parity pending)

| Upstream fix | Where tracked |
|---|---|
| Fee-payer token allowlist (#286) · atomic `put_if_absent` CAS (#280) · proof-wallet-binding (#253) · proof-source DID validation (#267, `384c4fe`) | **Task 46** (Tempo hardening audit) |
| Session integrity — voucher replay (#247) · payee+currency binding (#188) · channel scope (#246) · **close-voucher equality CVE-2026-34209** (`9408824`) · relay-sponsored calls (#494) · sender/fee-payer separation (mppx #247) | **Task 50** (sessions unbuilt) |
| Generic EVM/Stripe replay incl. **Stripe `Idempotent-Replayed` CVE-2026-34210** | **Task 35** (plug-level dedup) + **Task 64** (Stripe stubs) |
| Hash-credential `source` (did:pkh) validation | **Task 55** |

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
