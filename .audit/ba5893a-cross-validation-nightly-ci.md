# audit ba5893a — Run the cross-validation suite nightly in CI

verdict: clean
scope: new `.github/workflows/cross-validation.yml`, `test/mpp/tempo/cross_validation_test.exs`,
       CLAUDE.md + AGENTS.md
reviewers: Claude only — Codex second-opinion not dispatched (session policy)

## What was verified against reality, not the diff

- The workflow runs on `schedule` (05:00 UTC), `workflow_dispatch`, and `pull_request` filtered to
  `main` — which matches the repo's actual default branch (`gh repo view` → `main`) after the
  later `36f7c9f` retarget. Integration runs an hour later at 06:00 UTC. ✓
- The nightlies are actually green, not merely configured: the last four days of
  `gh run list` show `Cross-validation` and `Integration` succeeding on `main` through
  2026-08-18. ✓

This closes the gap the tag-exclusion creates — `:cross_validation` and `:integration` are out of
the default gate because they need a JS toolchain / live credentials, so "excluded" would mean
"never executed" without these workflows.

## Categories 1-6

No findings. CLAUDE.md's testing-tier section was updated in the same commit to say both tiers run
nightly.
