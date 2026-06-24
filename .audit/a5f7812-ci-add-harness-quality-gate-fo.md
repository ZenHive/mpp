---
sha: a5f7812e9327fd32c10a836a7e035e34b9519ae9
short_sha: a5f7812
audited_at: 2026-06-24
auditor_model: claude-opus-4-8
verdict: findings-applied
codex_status: single-reviewer
audited_by: audit-review v1
---

# Audit: ci: add Harness quality gate

**Original commit:** a5f7812 — `ci: add Harness quality gate (format/compile/credo/doctor/sobelow/test+cover/dialyzer)`
**Author:** E.FU
**Files touched:** 1 (`.github/workflows/harness.yml`, +77)

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 6   | redundancy (Cat 4) | .github/workflows/harness.yml | Broken+redundant duplicate of ci.yml | Applied: deleted harness.yml |

## Whole-surface finding (orchestrator seat)

This commit added `harness.yml` (the generic `elixir-ci-harness` template, family floor 70%).
The repo already had `ci.yml` (e51dc9f, project-specific 95% critical-tier gate). Neither commit's
isolated review could see the collision — it only exists on the integrated surface. Three problems,
all confirmed against ground truth:

1. **Near-duplicate, double cost.** Both run the identical stack (format/compile/credo/doctor/
   sobelow/test+cover/dialyzer) on every push **and** PR to `development` → double compile +
   double cold-PLT dialyzer (the most expensive step) per event.
2. **Conflicting gate.** ci.yml requires ≥95% coverage; harness.yml requires only ≥70% — two
   coverage thresholds on the same trigger.
3. **harness.yml is currently RED.** `cross_validation` tests are excluded only via the explicit
   `--exclude cross_validation` flag (test_helper.exs defaults exclude `:integration` only).
   ci.yml got that flag in 2cacfb6 + Node setup in d4e65d9; harness.yml got neither, so it runs
   the JS-toolchain cross-validation tests on a clean checkout with no `node_modules` → fail.
   Live evidence: `gh run list --branch development` shows **Harness=failure, CI=success**.

ci.yml is a strict superset (covers `main` too, higher coverage bar, excludes cross_validation,
bumped action versions in 7d160e6). harness.yml adds only an irrelevant `priv/plts` cache (this
repo's PLT is `_build/dialyzer`) and `sobelow` without `--skip` (re-flags known FPs — worse).

**Resolution: delete `harness.yml`.** Safe per stake-gated ladder (LOW tier — CI config, no lib/;
reversible via git; `development` branch confirmed **unprotected** so no required-check ripple).

## Auto-applied fixes

- Deleted `.github/workflows/harness.yml` (redundant + broken duplicate of ci.yml)

## Discuss-tier resolutions

- (none — single clear finding, no divergence)

## Codex second-opinion

Status: single-reviewer (CI/infra config — Codex withheld by design)
