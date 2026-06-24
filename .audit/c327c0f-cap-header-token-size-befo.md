---
sha: c327c0f18e035180f9baf13d0198c3112adc9231
short_sha: c327c0f
audited_at: 2026-06-24
auditor_model: claude-opus-4-8
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: Cap header token size before decode (DoS hardening, mpp-rs #299)

**Original commit:** c327c0f — `Cap header token size before decode (DoS hardening, mpp-rs #299)`
**Author:** E.FU
**Files touched:** 6 (ROADMAP.md, lib/mpp/headers.ex, roadmap/data.json, roadmap/tasks.toml, test/mpp/headers_test.exs, test/mpp/plug_test.exs)
**LOC:** ±137
**Task:** 65 (security, parallel)

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 7 | bug (DoS) | lib/mpp/methods/tempo/session_receipt.ex:128 | Public `from_header/1` base64-decodes uncapped input — Tempo sibling of the capped `parse_receipt` (codex, verified) | **Applied** — added @max_token_len cap before decode + 2 tests |
| 2 | discuss-design | bug-adjacent | lib/mpp/headers.ex:104 | Challenge `request` param materialized in full before size check (vs mpp-rs incremental bail at :140/164) — Claude+Codex corroborated | **No code change** — reversible divergence, Claude position picked (see below) |
| 3 | — | bug | lib/mpp/headers.ex:145 | `parse_challenges` drops an over-limit segment when a sibling parses (codex) | **Dropped** — false positive (intentional documented partial-failure tolerance; DoS still prevented per-segment before decode) |
| 4 | — | doc-gap | roadmap/tasks.toml:1449 | Task 65 `done` without `shipped_in` in this commit (codex) | **Dropped** — transient; resolved by sibling commit c2034a9 in this same batch |
| 5 | 2 | extraction | test/mpp/plug_test.exs:471 | Test duplicates `16 * 1024 + 1` literal instead of a named constant (codex) | **Dropped** — cosmetic, single-reasoner (Codex-only) |

## Auto-applied fixes

- **lib/mpp/methods/tempo/session_receipt.ex** — added `@max_token_len 16 * 1024` + `check_token_size/1` guard, enforced before `Base.url_decode64` in `from_header/1`; added `:token_too_large` to the `api()` errors list (additive, non-breaking). This closes the whole-surface gap c327c0f left: the commit capped the three `MPP.Headers` parse sites but its Tempo-session receipt sibling parsed uncapped. Boundary mirrors `MPP.Headers` exactly (strictly-greater; 16384 passes, 16385 rejects), cited to refs/mpp-rs/src/protocol/core/headers.rs:18.
- **test/mpp/methods/tempo/session_receipt_test.exs** — 2 boundary tests (over-limit → `:token_too_large`; at-limit passes the gate). Module coverage 97.5% (critical tier ≥95%). Suite green (24/24).

## Discuss-tier resolutions

**Finding 2 — challenge `request` materialized before size check (reversible divergence; Claude position picked).**

- **Codex position (pri 8):** the cap is a gap relative to mpp-rs, which bails *during* the byte-scan parse (refs/mpp-rs/...headers.rs:140 quoted-value path, :164 unquoted) before materializing >16 KiB; our `parse_auth_params/1` materializes all param values, then `check_request_size/1` rejects.
- **Claude position (no action):** the attack mpp-rs #299 targets — base64url + JCS + JSON *decode* amplification of the `request` payload — is fully prevented, because `check_request_size/1` runs before any downstream verification decode. The residual raw-string materialization is (a) bounded by the HTTP server's max-header-size for the plug path (Bandit/Cowboy default single-digit-to-tens of KB), and (b) not faithfully fixable cheaply: a whole-header cap at `@max_token_len` would reject *valid* at-limit challenges (request=16 KiB + realm/method/intent/expires/digest/opaque legitimately exceeds 16 KiB — exactly what the green "at-limit request param still parses" test asserts), and the faithful fix (rewrite `parse_auth_params` into an incremental scanner that bails at 16 KiB on the `request` value specifically) is a non-trivial change to a security-critical parser, beyond Task 65's "before decode" scope.
- **Resolution:** reversible (the choice is no-code-change vs. a parser rewrite; picking no-change is trivially reversible). Picked Claude's position. The decode-amplification surface is closed; the materialization refinement is a defense-in-depth item for the Task 63 header-fuzz/hardening work, not a c327c0f defect. If the user wants the incremental-scanner bail for library-direct callers that don't bound header size themselves, that is a deliberate, separately-scoped hardening task (file via `rmap new` on explicit ask).

## Codex second-opinion

Status: dual-reviewer (job task-mqs6dmjg-3x9rqo, 2m47s, completed)
Corroborated findings: 2 (challenge materialization — Claude raised it in pre-commit review, Codex independently corroborated)
Codex-verified constant/boundary: mpp-rs `MAX_TOKEN_LEN = 16 * 1024` at refs/mpp-rs/src/protocol/core/headers.rs:18; token checks `>` at :459/:496; mppx matches at refs/mppx/src/Challenge.ts:10; plug fallback safe at lib/mpp/plug.ex:219. Matches this auditor's independent pre-commit verification.
Codex-only findings (verified → applied): 1 (SessionReceipt uncapped — real, fixed)
Codex-only findings (verified → dropped as false positive): 3 (parse_challenges partial-failure — intentional), 4 (shipped_in — resolved in-batch by c2034a9)
Codex-only findings (dropped as cosmetic): 5 (test literal duplication)
HIGH-tier fix grader (finding 1, security-shaped lib path): Codex second-grader read — verdict recorded below.

Fix grader verdict: **approve** (job task-mqs6nu2f-dsoaq9, completed) — Codex (different agent than the Claude implementer of the fix) confirmed boundary, before-decode ordering, additive error contract, and test coverage. Fix lands in this audit commit.
