---
sha: 542a525563c2fcedd670b593437deca81c6797a4
short_sha: 542a525
audited_at: 2026-07-08
auditor_model: claude-opus-4-8
verdict: clean
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: Harden payment challenge verification

**Original commit:** 542a525 — `Harden payment challenge verification`
**Author:** E.FU
**Files touched:** 18 (lib: mcp, stripe, tempo, plug, verifier, mix.exs; + tests, CHANGELOG/README/ROADMAP)
**LOC:** +666 / -117

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 2 | doc-gap | CHANGELOG.md | "Development tooling." lead-in not bolded like sibling entries | Cosmetic; left (edits a shipped 0.6.1 entry) |
| 2 | — | acceptance | lib/mpp/methods/tempo.ex | Attribution memo layout verified byte-for-byte vs refs | No fix needed |
| 3 | — | out-of-scope | lib/mpp/credential.ex | Codex parse-time input-validation gap, outside this diff | Routed to pending Task 72 |

Core hardening reviewed and verified sound:

- **Fail-closed expiration:** `check_expiration(%Challenge{expires: nil})` now
  rejects; Plug defaults `expires_in` to 300 and always issues an `expires`.
- **Echoed field pinning:** verifier adds `check_digest_match` / `check_opaque_match`
  and a distinct `:realm_mismatch`; all post-HMAC field checks confirmed.
- **Constant-time compare** (Plug.Crypto.secure_compare), **raw base64url**
  preservation, and the **HMAC input layout** (`realm|method|intent|request|expires|digest|opaque`)
  all verified against `refs/mpp-rs` and `refs/mppx` (they agree).
- **Error sanitization:** provider/RPC/store/simulation failure details are
  collapsed to constant strings before becoming public 402 responses — no
  internal detail leakage.
- **Tempo source + attribution binding:** hash-credential DID payer is bound to
  the on-chain transfer sender + chain; no-static-memo routes now require
  challenge-bound attribution metadata.

**Attribution memo wire-format verification (per CLAUDE.md domain-ground-truth
rule):** the 32-byte memo decoder was checked byte-for-byte against
`refs/mpp-rs/src/tempo/attribution.rs` — tag `keccak256("mpp")[0..4]`, version
`0x01`, server `keccak256(realm)[0..10]`, client 10B (anonymous-capable, ignored
server-side), nonce `keccak256(challenge_id)[0..7]`. Matches exactly, including
passing `realm` as the server_id (`method.rs:465`). No golden-ratifies-a-wrong-
constant risk.

## Auto-applied fixes

- (none — the one doc nit is cosmetic and edits a shipped release entry; skipped)

## Discuss-tier resolutions

- (none)

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: 2 (all forgery/bypass/timing invariants — Codex verdict:
PASS on every one, matching Claude's verification vs the reference SDKs).
Codex-only (out of scope): a parse-time input-validation robustness gap in
`lib/mpp/credential.ex` (not in this commit's diff). Verified: those files are
untouched by 542a525. Already covered by pending **Task 72** ("Parse-time input
validation parity for challenge/credential") — recorded there, not fixed in this
commit's audit and not expanded here.
