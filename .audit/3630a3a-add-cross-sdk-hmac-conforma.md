---
sha: 3630a3ad2f1a0bc58fd1bec4a0bc007c70113ea1
short_sha: 3630a3a
audited_at: 2026-06-24
auditor_model: claude-opus-4-8
verdict: clean
codex_status: single-reviewer
audited_by: audit-review v1
---

# Audit: Add cross-SDK HMAC challenge-ID conformance vectors; file header-fuzz + Stripe-stub-parity tasks

**Original commit:** 3630a3a — `Add cross-SDK HMAC challenge-ID conformance vectors; file header-fuzz + Stripe-stub-parity tasks`
**Author:** E.FU
**Files touched:** 4 (ROADMAP.md, roadmap/data.json, roadmap/tasks.toml, test/mpp/challenge_conformance_test.exs)
**LOC:** ±227

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | — | acceptance | test/mpp/challenge_conformance_test.exs | 14 golden vectors pinned from mpp-rs; all green | verified in-session — no fix |

No code-correctness, extraction, TODO, or doc-drift findings. No production-code (`lib/`) paths touched.

## Codex second-opinion

Status: single-reviewer (no production-code paths in this commit; the only Cat-1 surface is the conformance test's own correctness, verified in-session by running it). Codex dispatch reserved for the production-code commit c327c0f in this batch.

## Notes

- This commit is exactly the cross-SDK conformance pattern CLAUDE.md mandates for wire-format constants ("the golden test ratifies the bug" failure mode): it pins `MPP.Challenge.create/2`'s HMAC-SHA256 challenge ID against 14 golden vectors copied verbatim from `refs/mpp-rs/src/protocol/core/challenge.rs` (`test_golden_vectors` ×10, `test_opaque_golden_vectors` ×4), not against self-built fixtures. A red here is a real divergence; the moduledoc correctly instructs fixing `MPP.Challenge`/`MPP.JCS`, never the pinned value.
- **Verified in-session:** ran `mix test.json challenge_conformance_test.exs headers_test.exs` → 74/74 passed. Our `Challenge.create/2` reproduces every mpp-rs golden ID. The "JCS over already-sorted compact JSON is identity" assumption holds for all vectors (keys are sorted in every literal: `amount<currency<recipient`, `amount<currency<methodDetails`, `deposit<pi`).
- Roadmap changes (file Tasks 63/64, append acceptance criteria to Task 46 + Tempo-subscriptions, bump phase counts) render consistently across `tasks.toml` → `ROADMAP.md` → `data.json`. No status flip owed; no CHANGELOG entry owed (test-coverage + roadmap bookkeeping, not a release-worthy behavior change).
