---
sha: fdde07abae00a64ac883705d6d9326f2c91171e1
short_sha: fdde07a
audited_at: 2026-06-24
auditor_model: claude-opus-4-8
verdict: clean — fast-path
codex_status: not-dispatched
audited_by: audit-review v1
---

# Audit: test(tempo): fix Moderato integration — non-blocklisted recipient, pinned gas, 30s nonce window

**Reason for fast-path:** 50 LOC, no production-code (lib/) paths — test + lockfile only.
**Files touched:** mix.lock, test/mpp/methods/tempo_integration_test.exs, test/support/tempo_test_helpers.ex
