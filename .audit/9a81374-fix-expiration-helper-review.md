---
sha: 9a81374
short_sha: 9a81374
audited_at: 2026-07-08
auditor_model: claude-opus-4-8
verdict: clean
codex_status: claude-only
audited_by: audit-review v1
---

# Audit: Fix expiration helper review issues

**Original commit:** 9a81374 — `Fix expiration helper review issues`
**Author:** E.FU
**Files touched:** 2 (lib/mpp/expires.ex, package-lock.json)
**LOC:** +2 / -257

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| — | — | — | — | No findings | — |

Review-fixup on the task-27 delivery. Two changes:

- **expires.ex** — widens `@spec assert!` from `String.t() | nil` to `term()` (both
  arities). Accurate: the function already has a non-binary catch-all clause
  (`assert!(_expires, challenge_id)` → raise invalid), so the spec now matches the
  code's real domain instead of under-declaring it. Behavior unchanged.
- **package-lock.json** — deletes the accidentally-committed 255-line npm lockfile.
  Correct: MPP is a pure-Elixir library and must never ship a JS lockfile as a
  package artifact (the JS toolchain is dev/test-only cross-validation cruft). The
  −257 LOC is almost entirely this file removal.

No behavioral change to the expiry gate (verified in the 059ab84 audit). Clean.

## Auto-applied fixes / Discuss-tier
- (none)

## Codex second-opinion
Status: claude-only (spec-widen + stray-lockfile deletion; no logic change). Clean.
