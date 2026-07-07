---
sha: 46c5b0e1311da7d92190dc7d9ea89027a1d365e9
short_sha: 46c5b0e
audited_at: 2026-07-08
auditor_model: claude-opus-4-8
verdict: clean
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: Harden Tempo hash-credential dedup to an atomic commit

**Original commit:** 46c5b0e — `Harden Tempo hash-credential dedup to an atomic commit`
**Author:** E.FU
**Files touched:** 3 (lib/mpp/methods/tempo.ex, test/mpp/methods/tempo_test.exs, CHANGELOG.md)
**LOC:** +56 / -10

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| — | — | — | — | Commit is sound; one dedup-store hardening item tracked privately | See below |

The commit itself is a correct security improvement: the `type="hash"` path now
commits its dedup mark through the store's atomic `check_and_mark/2` (the same
primitive the `type="transaction"` path uses), with the mark applied only after
successful on-chain verification so a transient RPC failure does not burn a
legitimate hash. A concurrency test is added and the CHANGELOG entry is present.
Atomicity of the built-in `MPP.Tempo.ConCacheStore` was verified (ConCache
row-level isolation) and the reference-SDK parity confirmed against
`refs/mpp-rs` (`put_if_absent`) and `refs/mppx` (atomic store update).

A follow-up **dedup-store contract hardening** item was surfaced during review.
Per `SECURITY.md` disclosure policy it is tracked privately (see the private
security advisory / rmap follow-up); no mechanism, trigger, or affected-config
detail is recorded in this committed report. It is a *hardening* of an already
security-conscious design, not a defect introduced by this commit.

## Auto-applied fixes

- (none — no fix applied to committed source; the follow-up is tracked, not
  broadcast, per disclosure policy)

## Discuss-tier resolutions

- One `discuss-design` item routed to private tracking (reversible in code but a
  breaking public-API change to ship deliberately in a versioned release).

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: —
Codex confirmed the commit's atomic path and reference parity. Codex additionally
proposed a hardening of the store contract; that proposal (and any working-tree
edits it produced) was reverted from this audit and redirected to the private
disclosure channel rather than applied or described here.
