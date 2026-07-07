---
sha: 62ea7de167b6c558f9c44cbc19a0a0fa0539acb4
short_sha: 62ea7de
audited_at: 2026-07-08
auditor_model: claude-opus-4-8
verdict: clean
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: Extract shared atomic-claim helper; correct hash-dedup ref-SDK citation

**Original commit:** 62ea7de — `Extract shared atomic-claim helper; correct hash-dedup ref-SDK citation`
**Author:** E.FU
**Files touched:** 1 (lib/mpp/methods/tempo.ex)
**LOC:** +19 / -12

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| — | — | — | — | No findings | — |

Extracts the atomic `check_and_mark` handling into a shared `claim_atomic/3` used
by both the transaction-path reserve and the hash-path commit (clears the
`ex_dna --max-clones 0` clone). The extraction preserves the exact branch
semantics statement-for-statement: `:ok` → accept, `{:error, :already_exists}` →
replay rejection, other → sanitized store error. Comment citations were corrected
to `mpp-rs verify_hash` (atomic `put_if_absent` after verification) and mppx's
reserve-before-verify path.

## Auto-applied fixes

- (none)

## Discuss-tier resolutions

- (none)

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: — (both reviewers: clean)
Codex verified the extraction is behaviour-preserving and cross-checked the
corrected citations against `refs/mpp-rs/src/protocol/methods/tempo/method.rs`
(post-verification `put_if_absent`) and `refs/mppx/.../Charge.ts` (atomic
`update`). `mix credo`, `mix dialyzer.json`, and focused Tempo tests pass.
