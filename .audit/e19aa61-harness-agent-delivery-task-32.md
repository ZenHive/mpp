---
sha: e19aa610de950bfefee533752f350c2184cefa6e
short_sha: e19aa61
audited_at: 2026-07-09
auditor_model: claude-fable-5
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: harness: agent delivery — task 32b MCP server transport

**Original commit:** e19aa61 — `harness: agent delivery — task 32b MCP server transport (run run-1783571050387-e0d6d4cb)`
**Author:** harness (codex implementer, reviewer-gated)
**Files touched:** 2 (lib/mpp/mcp.ex + test/mpp/mcp_test.exs)
**LOC:** +569

Direct-delivery harness commit; reviewer-gated at dispatch time. Adds `MPP.Mcp.init/1`
+ `call/3` — the server-side JSON-RPC transport adapter. Error-code mapping verified
against `refs/mppx/src/server/Transport.ts` `mcpErrorCode()`: no-error/payment-required
→ `-32042`, malformed-credential → `-32602`, everything else → `-32043` — exact match.
Envelope shape (`error.data.httpStatus/challenges/problem`, `result._meta` receipt +
`challengeId`) matches `mcp()`'s `respondChallenge`/`respondReceipt`; ours sends all
configured method entries' challenges where single-method mppx sends one (superset,
consistent with multi-method `MPP.Plug`). Two follow-up commits in this batch (91c9d32
challenge-generation dedup, 1e6fa07 replay dedup) were audited on top, not re-flagged.

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 6 | bug (codex) | lib/mpp/mcp.ex:370 | `call/3` crashed (`FunctionClauseError`) on legal non-map JSON-RPC `params` (array / explicit null) | applied — normalize to `%{}` → no-credential path (mppx optional-chaining parity) + test over `[[1,2], nil, "positional"]` |
| 2 | 6 | interop (codex) | lib/mpp/mcp.ex:295 | Client helpers rejected the full JSON-RPC envelope `call/3` emits — `payment_required?/1` false, `extract_challenges/1` `:no_challenges` on a whole response | applied — `%{"error" => e}` unwrap clauses (mppx `paymentRequiredData` accepts the full message) + round-trip test |
| 3 | 4 | doc-gap | CHANGELOG.md | No `[Unreleased]` entry for the server transport | applied |
| 4 | 3 | doc-gap | CLAUDE.md:96 / README.md:214 / moduledoc | Docs still described `MPP.Mcp` as constants/helpers only | applied — all three updated |
| 5 | 1 | cosmetic | lib/mpp/mcp.ex:387 | `Errors.new(:malformed_credential, "#{reason}")` interpolates a raw atom into `detail` (e.g. "invalid_challenge") | skipped — cosmetic; wire `type`/`title` are correct |

## Auto-applied fixes

- `lib/mpp/mcp.ex` `authorize_request/2`: non-map `params` → `%{}` (treated as no
  credential, mirroring mppx `request.params?._meta`).
- `lib/mpp/mcp.ex` client helpers: `payment_required?/1` and `extract_challenges/1`
  gain `%{"error" => error}` delegation clauses, symmetric with the existing
  `%{"result" => _}` clauses; api descriptions updated.
- Moduledoc: new "Server Transport Adapter" section (`init/1`, `call/3`).
- CHANGELOG `[Unreleased]`, CLAUDE.md module map, README module table.

## Acceptance criteria (Task 32b)

- Server transport bridging MPP.Verifier into JSON-RPC ✅
- `_meta` credential read, `-32042` + challenges + RFC 9457 problem, `_meta` receipt ✅
- Tier-3 fixture tests over synthetic JSON-RPC exchanges ✅
- Tier-2 `:cross_validation` test pinning the envelope to mppx's server transport ✅
  (asserts mppx source markers + our envelope; Codex ran it green: 57 passed)
- No chain/API re-testing through MCP ✅ (MockMethod only)

## Codex second-opinion

Status: dual-reviewer (job task-mrd3httc-rwfnus; ran the suite incl. `--include cross_validation`, 57 passed)
Corroborated findings: 3, 4
Codex-only findings (verified + applied): 1 (confirmed: `extract_credential/1` has only map clauses), 2 (confirmed against mppx client `paymentRequiredData`)
Codex-only findings (discarded as over-flag): none
