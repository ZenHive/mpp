---
sha: 5d6338e2334084c5f2a78cfcca474830733ed7e8
short_sha: 5d6338e
audited_at: 2026-06-24
auditor_model: claude-opus-4-8
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: Add Tempo fee-payer gas-economics policy (anti gas-draining)

**Original commit:** 5d6338e — `Add Tempo fee-payer gas-economics policy (anti gas-draining)`
**Author:** E.FU
**Files touched:** 10 (new `lib/mpp/methods/tempo/fee_payer_policy.ex` + wire-in to `tempo.ex` + tests + CHANGELOG/ROADMAP/roadmap)
**LOC:** ±931

This is the substantive code commit of the batch and the highest-stakes surface:
a sponsor anti-drain policy that bounds client-supplied gas economics on a `0x76`
envelope the server co-signs (GHSA-vv77-66rf-pm86, GHSA-qpxh-ff8m-c62v).

## Wire-format constant verification (dual-reviewer — Claude + Codex agree)

Every hardcoded `0x76` RLP field index was cross-checked against the parser the
policy reads from (`Onchain.Tempo.Transaction`) and the reference SDKs. **Claude and
Codex independently reached the same verdict on all seven.**

| Constant | Verdict | Evidence |
|---|---|---|
| `@max_priority_fee_index 1` | ✅ correct | `deps/onchain_tempo/lib/onchain/tempo/transaction.ex:8` wire-order docstring; `refs/mpp-rs/src/protocol/methods/tempo/fee_payer_envelope.rs:37` |
| `@max_fee_index 2` | ✅ correct | same |
| `@gas_limit_index 3` | ✅ correct | same |
| `@access_list_index 5` | ✅ correct | `transaction.ex:8` (`access_list` after `calls`@4) |
| `@nonce_key_index 6` | ✅ correct | same |
| `@valid_before_index 8` | ✅ correct | same |
| `@expiring_nonce_key = 2^256-1` | ✅ correct | `mpp-rs` `TEMPO_EXPIRING_NONCE_KEY` (method.rs:1297); `mppx` accepts `maxUint256` (`refs/mppx/src/tempo/internal/fee-payer.ts:306`) |

**Default ceilings + per-chain override** match mppx exactly
(`refs/mppx/src/tempo/internal/fee-payer.ts:277-289`): `maxGas 2_000_000`,
`maxFeePerGas 1e11`, `maxPriorityFeePerGas 1e10` (Moderato `5e10`),
`maxTotalFee 5e16`, `maxValidityWindowSeconds 900`.

**Validation comparison semantics** match mppx (`fee-payer.ts:509-562`):
gas/fee lower+upper bounds, `gas*fee ≤ maxTotalFee`, `priority ≤ maxFee` and
`≤ policy.maxPriority`, expiring-nonce required, `valid_before` present/future/within-window.

**Documented intentional divergence (not a defect):** the validity window is an
absolute `max_validity_window_seconds` cap (matching mpp-rs); mppx additionally
ties the ceiling to `challengeExpires + 60s`. The moduledoc explicitly states this
and provides the mitigation (lower `max_validity_window_seconds` for a tighter,
challenge-relative bound). This is the "cross-check refs; document the divergence"
discipline applied correctly.

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 7 | bug | fee_payer_policy.ex:253 | `check_access_list/1` returned `:ok` for a malformed non-list access-list field — failed **open**, contradicting the moduledoc's stated fail-closed contract | **applied** (also flagged by codex) |
| 2 | — | discuss-design | fee_payer_policy.ex:61 | `0x76` field indices duplicated here instead of exported by `onchain_tempo`; correct now, drift would silently break policy | recorded — no code change (reversible-picked) |
| 3 | 3 | doc-gap | fee_payer_policy.ex:103 | `resolve/2` `@doc` omitted the supported `"max_validity_window_seconds"` override key | **applied** (also flagged by codex) |

## Auto-applied fixes

- **fee_payer_policy.ex `check_access_list/1`** — rewrote to fail closed: `[]` → `:ok`;
  non-empty list → reject (existing); **any non-list term → `{:error, "...malformed access_list..."}`**
  (NEW), matching the sibling `field_int/3` fail-closed pattern and the module's own
  documented contract. Added test `fails closed when the access-list field is malformed
  (non-list scalar)` (corrupts RLP index 5 to a scalar). Test count 28 → 29.
- **fee_payer_policy.ex `resolve/2` `@doc`** — added `"max_validity_window_seconds"` to the
  enumerated override keys.

## Discuss-tier resolutions

- **Finding 2 (index duplication) — reversible divergence, resolved by judgment, no code change.**
  The indices are duplicated from `onchain_tempo`'s wire layout rather than imported (the dep
  exposes no named field accessors). Both reference SDKs and the upstream parser agree the
  current values are correct (verified above). The repo already carries an explicit standing
  mitigation: `CLAUDE.md` § "Verify wire-format constants against the reference SDKs" mandates
  exactly the cross-check this audit just performed. Adding an in-repo duplicate-constant guard
  test would merely re-encode the same numbers (no independent oracle), so it provides marginal
  value over the existing mandate. Position picked: **document the coupling risk, rely on the
  CLAUDE.md verification mandate + dual-SDK confirmation.** Reversible — if `onchain_tempo` later
  exports named indices, switching to them is a mechanical follow-up.

## Mechanical grader (HIGH-tier fix — security-shaped core lib)

- `mix test.json fee_payer_policy_test.exs --cover` → **29/29 passed, 100.0% coverage**
- `mix credo --strict` on the file → **0 issues**
- PostToolUse hook ran format/compile/dialyzer/doctor on the edits (green).
- Cross-family second grader: Codex (cross-family from Claude) independently flagged
  Finding 1 and endorsed the fail-closed direction — satisfies the Step-9 HIGH-tier
  second-grader read.

## Codex second-opinion

Status: dual-reviewer (job task-mqrf223h-72rfzp, session 019ef752-552e-7481-854f-440ba95e3fec)
Corroborated findings: 1 (access-list fail-open), 3 (resolve/2 doc) — both also found by Codex
Codex-only findings (verified, recorded): 2 (index-duplication coupling, discuss-design)
Codex-only findings (discarded as over-flag): none
Wire-format verdict: all 7 constants confirmed correct by both reviewers.
