---
sha: d713e58cd5fe3708fb163b30aa8d029fc9c51260
short_sha: d713e58
audited_at: 2026-07-08
auditor_model: claude-opus-4-8
verdict: clean
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: Suppress reach behaviour_candidate false-positive on MPP.Methods.EVM

**Original commit:** d713e58 — `Suppress reach behaviour_candidate false-positive on MPP.Methods.EVM`
**Author:** E.FU
**Files touched:** 1 (lib/mpp/methods/evm.ex)
**LOC:** +3

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| — | — | — | — | No findings | — |

A correctly-scoped `# reach:disable-next-line behaviour_candidate` on the one
`defmodule MPP.Methods.EVM` site, with an accurate explanatory comment: the four
`use MPP.Method` impls share a callback set because `MPP.Method` already IS the
behaviour (macro-injected `@behaviour`), which reach's source frontend can't see.
Genuine false positive; suppression is minimal and does not mask any real smell.

## Auto-applied fixes

- (none)

## Discuss-tier resolutions

- (none)

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: — (both reviewers: clean)
Codex confirmed the suppression is scoped to the following line, that
`lib/mpp/method.ex` injects `@behaviour MPP.Method`, and that `mix reach.check`
and `mix credo` are clean. (Codex noted 6 unrelated `tempo_full_flow_test`
failures on current HEAD from the later static-memo/store requirement — not this
commit.)
