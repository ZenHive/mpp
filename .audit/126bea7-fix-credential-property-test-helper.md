---
sha: 126bea7ee860
short_sha: 126bea7
audited_at: 2026-07-08
auditor_model: claude-opus-4-8
verdict: clean
codex_status: fast-path
audited_by: audit-review v1
---

# Audit: Fix credential property test helper and lock stream_data

**Original commit:** 126bea7 — `Fix credential property test helper and lock stream_data`
**Author:** E.FU
**Files touched:** 2 (test/mpp/headers_test.exs, mix.lock)
**LOC:** +19 / -15 — **fast-path** (≤100 LOC, 0 lib/src files)

## Summary

Fast-path (test + lockfile only). Two changes, both quality-positive:

- **Strengthens** the `format_credential + parse_credential` identity property from a
  partial-field check (`parsed.challenge.realm` + `parsed.payload`) to a full-struct
  `assert {:ok, ^cred} = ...` match, by parameterizing `make_credential`'s payload
  via `Keyword.pop/3`. A stronger round-trip assertion, not a weaker one.
- Locks `stream_data` in `mix.lock`; also folds a `ex_ast` 0.12.0→0.12.5 lock bump.
- Styler-driven `check all` → `check all(...)` reformat (no semantic change).

No production code touched. Clean.
