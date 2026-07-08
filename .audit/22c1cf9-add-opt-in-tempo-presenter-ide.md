---
sha: 22c1cf92677a06cca6301783e9f560367cabe7c4
short_sha: 22c1cf9
audited_at: 2026-07-08
auditor_model: claude-opus-4-8
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: Add opt-in Tempo presenter-identity binding for hash/transaction credentials (0.8.0)

**Original commit:** 22c1cf9 — `Add opt-in Tempo presenter-identity binding for hash/transaction credentials (0.8.0)`
**Author:** E.FU
**Files touched:** 11 (lib/mpp/methods/tempo.ex + tests + docs + roadmap)
**LOC:** ±626

Security commit (Task 75): closes the front-running residual of published advisory `GHSA-34g7-vx6g-82mq`.
New opt-in Tempo `method_config` key `"require_presenter_binding"`; `type="hash"` / `type="transaction"`
credentials must carry a `"presenterSignature"` (EIP-712 over the proof path's typed data,
MPP domain v3 `{account, challengeId, realm}`) recovering to the transfer sender or an authorized
access key. Advertised as `"presenterBinding": true` in 402 method details. Off by default.

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 4   | doc-gap (no-PR) | — | Direct-push to `development`, no PR review trail | Recorded (informational) |
| 2 | —   | acceptance | (GHSA advisory) | Criterion 5b: `GHSA-34g7-vx6g-82mq` still shows `patched: 0.6.4`; residual opt-in-close in 0.8.0 not noted | STOP — surfaced to user (outward-facing advisory mutation; not auto-applied) |

No code bugs, missing extractions, missing TODO markers, abstraction opportunities, or actionable
TODOs found by either reasoner. The diff itself *adds* a clean extraction
(`access_key_metadata_result/1`, `stub_receipt_and_access_key!/1` in the test helper).

## Acceptance criteria (Task 75)

| # | Criterion | Result |
|---|-----------|--------|
| 1 | Third party who only observed a settled transfer cannot claim it against their own challenge (regression test) | ✅ Met — unit + integration regression tests present (`tempo_test.exs`, `tempo_integration_test.exs`) |
| 2 | Presenter binding verified against transfer's sender, mirroring the proof path | ✅ Met — `verify_presenter_signature/4` reuses `verify_proof_signature/4`; hash path enforces `from == source` via `find_matching_transfer/4`; tx path recovers sender from the signed 0x76 tx |
| 3 | Existing clients presenting a hash for their own transfer are not broken (opt-in) | ✅ Met — off by default; `{nil presenterSignature, false required} -> :ok` |
| 4 | Wire/signature layout cross-checked against refs/mpp-rs + refs/mppx and cited | ✅ Met — reuses existing proof envelope (no new wire constant); reference claims independently confirmed: `refs/mpp-rs/src/protocol/methods/tempo/method.rs:773` (`source_address.unwrap_or_else(|| receipt.from())`), `refs/mppx/src/tempo/server/Charge.ts:246` (`source?.address ?? receipt.from`) |
| 5a | docs/security-parity.md row moved to closed | ✅ Met — new ✓ row under "Confirmed parity (closed in our impl)" (line 59) |
| 5b | GHSA-34g7-vx6g-82mq updated to fixed-in-\<version\> | ❌ **Not met (external action)** — published advisory still lists `patched_versions: 0.6.4`, no note that the residual front-running race is opt-in-closed in 0.8.0 |

## Auto-applied fixes

- (none) — the commit is complete and correct; no code or repo-file fixes were warranted.

## Discuss-tier resolutions

- (none)

## Codex second-opinion

Status: dual-reviewer (jobId `task-mrbfizcf-gx36mi`, model default, 2m24s)
Verdict: "No security-correctness bypass found in the presenter binding paths I checked."
Ran `mix test.json --quiet test/mpp/methods/tempo_test.exs` → **164 tests passed**.
Corroborated findings: none (no code defects raised by either reasoner).
Codex-only findings: 1 — "Task 75 still `in_progress`" at `roadmap/tasks.toml:1699`. **Non-actionable:** resolved by the very next commit in this range (`42ffa8d` flips it to `done`); Codex was scoped to the single commit and could not see the follow-up.

## Notes / verification trail

- `security-parity.md` "Open hardening items" count (**4**) was deliberately **not** changed: Task 75 closed a residual of an already-published, roadmap-tracked (📋) advisory, not one of the private open-item gaps that count enumerates. Adjusting it without knowing the private set would be a guess.
- Disclosure check: `GHSA-34g7-vx6g-82mq` is **published** — the CHANGELOG / README / ledger references to the mechanism are compliant with the repo's disclosure policy (fixed AND advisory published → OK to reference).
- Presenter-binding pipeline ordering reviewed: on the hash path, `verify_hash_presenter_binding/4` runs after `check_hash_unused/2` and before the atomic `commit_hash_used/2`; a captured presenter signature is replay-bound to `challengeId` (inside the signed EIP-712 digest), confirmed by the "different challenge" regression test.
