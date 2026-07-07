---
sha: 7191c1025e909067ee6ab6a7509148920cff1da2
short_sha: 7191c10
audited_at: 2026-07-08
auditor_model: claude-opus-4-8
verdict: clean
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: Raise eth_simulateV1-unsupported log to warning (degraded fee-payer guard)

**Original commit:** 7191c10 — `Raise eth_simulateV1-unsupported log to warning (degraded fee-payer guard)`
**Author:** E.FU
**Files touched:** 1 (lib/mpp/methods/tempo.ex)
**LOC:** +3 / -1

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| — | — | — | — | No findings | — |

Single-line change: `Logger.info` → `Logger.warning` on the `{:ok, :unsupported}`
branch of the pre-broadcast simulation guard, plus clearer message wording. No
control-flow change — the branch still returns `:ok`. Raising the level is the
correct posture: when a node lacks `eth_simulateV1` the simulation guard is
skipped (static fee-payer bounds still apply), and a warning makes that reduced
protection visible in operations.

## Auto-applied fixes

- (none)

## Discuss-tier resolutions

- (none)

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: — (both reviewers: clean)
Codex verified no control-flow change via `git show`, focused Tempo tests,
`mix credo`, `mix doctor`, `mix sobelow`. Matches Claude's read.
