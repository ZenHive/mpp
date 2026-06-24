---
sha: 2cacfb6a3ff5e2e30dc295d8b063e2411f1cd84b
short_sha: 2cacfb6
audited_at: 2026-06-24
auditor_model: claude-opus-4-8
verdict: clean — fast-path
codex_status: not-dispatched
audited_by: audit-review v1
---

# Audit: Exclude JS cross-validation tests from CI (gitignored toolchain, like :integration)

**Reason for fast-path:** <100 LOC, no production-code (lib/) paths touched.
**Files touched:** .github/workflows/ci.yml, test/mpp/tempo/cross_validation_test.exs
