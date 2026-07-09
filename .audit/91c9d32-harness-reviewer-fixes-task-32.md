---
sha: 91c9d322b69bc55e68bf89d1db407b490a366bdc
short_sha: 91c9d32
audited_at: 2026-07-09
auditor_model: claude-fable-5
verdict: clean
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: harness: reviewer fixes — task 32b MCP server transport

**Original commit:** 91c9d32 — `harness: reviewer fixes — task 32b MCP server transport (run run-1783571050387-e0d6d4cb)`
**Author:** harness (cross-family reviewer fixes)
**Files touched:** 2 (lib/mpp/mcp.ex, lib/mpp/plug.ex)
**LOC:** +9 / −27

Clean refactor: drops `MPP.Mcp`'s private `generate_challenge`/`compute_expires`/
`maybe_add` copies and promotes `MPP.Plug.generate_challenge/2` to `@doc false`
public so both transports emit byte-identical challenges from the same config —
exactly the right de-duplication for an HMAC-bound wire artifact.

## Findings

None. Both reasoners verified the promoted function's `expires`/`digest`/`opaque`
handling matches what the deleted MCP-local copy did; no leftover unused aliases
or helpers remain in `mcp.ex`.

## Codex second-opinion

Status: dual-reviewer (job task-mrd3i7bb-piwlt8)
Verdict: clean — no findings from either reasoner. Codex ran
`mix test.json test/mpp/mcp_test.exs` (56 passed) and credo (no issues).
