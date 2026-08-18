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

## Codex second opinion (2026-08-18)

Codex checked the workflow against **actual runs**, not just the YAML: the first
run (`actions/runs/30797157705`) and the latest nightly
(`actions/runs/32102581029`) both executed 21 tests, 0 skipped, so the "green
with zero tests" failure mode is not occurring. A wrong `--only` tag exits 1, and
missing npm packages / mppx / esbuild / QuickBEAM all fail hard — there is no
`continue-on-error` or skip fallback.

| finding | verdict |
|---|---|
| `cross-validation.yml:51` `pull_request.branches` targeted `development`, not `main` (prio 7) | **Confirmed, already closed** by `36f7c9f` 15 minutes later. No action. |
| `cross-validation.yml:109` missing `--no-retry`: `ex_unit_json` auto-retries and reports a healed failure as `flaky` with exit 0 (prio 6) | **Confirmed, FIXED** — added `--no-retry`. For wire-format conformance a heal *is* the finding. Verified against `deps/ex_unit_json/lib/ex_unit_json/config.ex:176` (`:retry` defaults to `true`). |
| `integration.yml:99` `--include integration` passes with zero integration-tagged tests because untagged tests still run — contradicting its "never a silent 0-tests pass" comment (prio 5) | **Confirmed, FIXED** — switched to `--only integration --no-retry` and corrected the comment. `--only` additionally excludes untagged tests, so a mistyped or absent tag exits 1. |
| `cross_validation_test.exs:98` the opt-in "test" is a bare `assert true` (prio 4) | **Confirmed, FIXED** — removed; its scope-contract explanation was kept as a comment. A bare `assert true` proves no behavior and would keep the selected suite non-empty after every meaningful test in it disappeared. |
| `ci.yml:10` header documents only the `:integration` exclusion, omitting `:cross_validation` (prio 2) | Cosmetic; dropped. |
| No repository-controlled failure alert for scheduled runs — notification depends on the actor's personal settings (`discuss`) | **Open, flagged to the operator.** Not fixable inside this repo's code; needs a decision on a notification sink. |
