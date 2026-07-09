---
sha: 1e6fa07fa64bebb1e51ca1ea0f31152a6af6b52b
short_sha: 1e6fa07
audited_at: 2026-07-09
auditor_model: claude-fable-5
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: Share credential single-use dedup across Plug and MCP transports (MPP.Replay)

**Original commit:** 1e6fa07 — `Share credential single-use dedup across Plug and MCP transports (MPP.Replay)`
**Author:** E.FU
**Files touched:** 5 (new lib/mpp/replay.ex; lib/mpp/plug.ex, lib/mpp/mcp.ex; replay + mcp tests)
**LOC:** +233 / −61

Extraction verified faithful to the pre-extraction `MPP.Plug` code: same
`mpp:credential:` key prefix, same Tempo carve-out (with the EVM
both-layers-deliberate comment preserved), same error texts, atomic
`check_and_mark/2` only (GHSA-w8j7-7qc3-5f24 — no non-atomic fallback). The MCP
wire-up (check before verify, claim after) closes the JSON-RPC replay gap the new
transport would otherwise have shipped with. Codex additionally verified the
`mark_used`-fails-after-verify path returns `-32043` without running the handler.

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 7 | bug (codex) | lib/mpp/replay.ex:76 | Attacker-supplied payload with a JSON float (e.g. `%{"x" => 1.5}`) raised `FunctionClauseError` in `JCS.canonicalize/1` for store-backed methods — on both transports (pre-existing on the HTTP path since the Plug store shipped) | applied — `safe_key/1` rejects as `malformed-credential`; unit + MCP end-to-end tests |
| 2 | 5 | parity (Claude + codex) | lib/mpp/mcp.ex:422 | Replayed MCP credential emitted no `[:mpp, :verify, :start]`/`:fail` telemetry; the Plug path emits both (plug.ex:353-356) | applied — `verify_with_entry` restructured to mirror Plug's branch; telemetry test |
| 3 | 4 | doc-gap (Claude + codex) | CLAUDE.md:84 | Module map enumerates every module (incl. internal Hex/Codec/Shared) but omitted `MPP.Replay` | applied — row added |
| 4 | 4 | doc-gap (Claude + codex) | CHANGELOG.md | No `[Unreleased]` entry for the security-relevant extraction | applied |

## Auto-applied fixes

- `lib/mpp/replay.ex`: `safe_key/1` wraps key computation; a payload the deliberate
  MPP JCS subset cannot canonicalize (floats) now returns
  `{:error, malformed-credential "Credential payload contains an unsupported JSON value"}`
  from both `check_unused/2` and `mark_used/2` instead of leaking the raise (same
  class as the 0.10.0 JCS pre-check hardening in `MPP.Mcp`). Tests prove the key
  failure short-circuits before any store access.
- `lib/mpp/mcp.ex`: replay rejection now emits the same verify start/fail telemetry
  as `MPP.Plug` (metadata incl. `challenge_id`, `error_type`, `realm`); asserted via
  an attached telemetry handler in the MCP test.
- CHANGELOG `[Unreleased]` + CLAUDE.md module map.

## HIGH-tier second-grader (stake-gated ladder)

The fixes to `lib/mpp/replay.ex` and `lib/mpp/methods/stripe.ex` (money/replay
paths) plus the `lib/mpp/mcp.ex` replay-gate restructure were graded by an
independent Codex read of the working-tree diff (job task-mrd45amy-al9uhw).
**Verdict: approve — no blocking findings.** The grader independently re-verified
the Stripe preview pin and transferGroup typing against mppx source, confirmed the
`safe_key/1` rescue is scoped to the JCS-unsupported-payload case only, confirmed
the MCP flow still gates before verification and marks after (matching Plug's
replay/telemetry shape), and ran the three touched test files (128 passed) + credo
(clean). Dialyzer was not runnable in the grader sandbox; run locally after the
fixes: 0 warnings.

## Codex second-opinion

Status: dual-reviewer (job task-mrd3iklx-di7q99; ran replay + mcp suites, 64 passed; credo clean; dialyzer 0 warnings)
Corroborated findings: 2, 3, 4
Codex-only findings (verified + applied): 1 (confirmed: jcs.ex documents the float raise; float payload is attacker-reachable wire input)
Codex-only findings (discarded as over-flag): none
