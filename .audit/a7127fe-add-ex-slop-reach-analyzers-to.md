---
sha: a7127feb25a0869c2da3503350be72315be8ec38
short_sha: a7127fe
audited_at: 2026-07-08
auditor_model: claude-opus-4-8
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: Add ex_slop + reach analyzers to precommit.full and apply slop fixes

**Original commit:** a7127fe — `Add ex_slop + reach analyzers to precommit.full and apply slop fixes`
**Author:** E.FU
**Files touched:** 17
**LOC:** +95 / -2312 (mostly mechanical slop/style cleanup)

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 7 | bug/ci-gate | .github/workflows/ci.yml | CI omits new precommit.full analyzer steps (ex_dna, reach) while claiming to mirror it | Applied: added both steps to ci.yml |
| 2 | 5 | doc-gap | .github/workflows/ci.yml:2 | Header comment says CI mirrors `mix precommit.full` but no longer did | Applied: corrected comment |

## Auto-applied fixes

- `.github/workflows/ci.yml`: added `mix ex_dna --max-clones 0` (clone detection)
  and `mix reach.check --arch --smells` (architecture/smell) steps before the
  Dialyzer step, mirroring the `precommit.full` alias ordering (mix.exs:176-179).
  Both confirmed green on the audited HEAD locally before wiring in (ex_dna: 0
  clones / 38 files; reach: architecture OK, no smells), so CI won't go red.
- `.github/workflows/ci.yml:2-4`: corrected the header comment to list the
  clone-detection and arch+smell steps so the "mirrors `mix precommit.full`"
  claim is accurate again.

Rationale: this commit added ex_dna + reach to the local `precommit.full` gate but
did not update the CI workflow, so a PR introducing a clone or arch smell would
pass CI while failing the local gate — the exact local/CI drift the repo's
"turn global invariants into CI failures" guidance warns against. Low-tier
(CI-config) mechanical fix.

The slop-fix hunks across production modules (Headers, JCS, Mcp, Tempo, demo)
were reviewed for behavior change; none found — all are cleanup (comment/style
removal), consistent with the commit's stated intent.

## Discuss-tier resolutions

- (none)

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: 1, 2 (the CI-drift bug and doc-gap were Codex-surfaced;
Claude independently confirmed against mix.exs + ci.yml before applying).
Codex also noted `.reach.exs` carries an empty/permissive policy with a
"populate as architecture settles" note (pri 3, no `TODO:` marker) — left as-is:
the policy file is intentionally seeded permissive and reach still runs its
built-in arch/smell checks; not worth a marker churn on config.
