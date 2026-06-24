---
sha: 30c28bb6fb63d7cf75d170c1f870ad6c9e7c8989
short_sha: 30c28bb
audited_at: 2026-06-24
auditor_model: claude-opus-4-8
verdict: clean — fast-path
codex_status: not-dispatched
audited_by: audit-review v1
---

# Audit: Add security-parity ledger + disclosure convention

**Reason for fast-path:** 79 LOC, no production-code paths touched (docs + CLAUDE.md convention).
**Files touched:** CLAUDE.md, docs/security-parity.md
**Note:** Establishes the public-ledger/private-advisory disclosure split later synced to
AGENTS.md (289e31f) — consistent with critical-rules.md § "NEVER BROADCAST AN UNPATCHED
VULNERABILITY". No exploit detail in the committed ledger (✓/📋 rows only). Direct-push (no PR trail).
