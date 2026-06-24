---
sha: d84e3e528db39654540c2035ea0fbdf7b950d3d1
short_sha: d84e3e5
audited_at: 2026-06-24
auditor_model: claude-opus-4-8
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: Add fee-payer pre-broadcast simulation of co-signed Tempo transactions (Task 59)

**Original commit:** d84e3e5 — `Add fee-payer pre-broadcast simulation of co-signed Tempo transactions (Task 59)`
**Author:** E.FU
**Files touched:** 11
**LOC:** ±492

Security commit: replaces the gas-blind `eth_call` payment-call simulation
(`simulate_payment_call`) with a full co-signed-tx `eth_simulateV1` simulation
(`simulate_cosigned_tx` → `Onchain.Tempo.RPC.simulate/3`), wired into BOTH broadcast
paths before broadcast. Closes the residual low-gas-limit fee-payer drain vector
(maps to inbound advisory GHSA-vj8p-hp9x-gh47). `onchain_tempo` 0.6.0→0.7.0.

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 5 | doc-gap | lib/mpp/methods/tempo.ex:49 | `wait_for_confirmation:false` config doc still said "Simulates via `eth_call`" | Applied: now describes full co-signed `eth_simulateV1` on both paths (also flagged by codex) |
| 2 | 6 | bug/coverage | test/mpp/methods/tempo_test.exs:231 | "fee-payer DoS guard" unit test built a non-fee-payer tx — sponsored co-signed revert path unproven | Applied: added unit test that builds a co-signed sponsored tx, stubs `eth_simulateV1`→`0x0`, asserts reject + `refute_received` broadcast (also flagged by codex) |
| 3 | 5 | coverage | test/mpp/methods/tempo_integration_test.exs:501 | Live Moderato revert test sets `fee_payer:false`; the *sponsored* revert is not exercised against the chain | Surfaced to user — needs live Moderato + funded sponsor wallet; cannot verify in-session. Unit coverage now closes the AC; integration sponsored-revert remains a recommended follow-up (also flagged by codex) |
| 4 | 5 | doc-gap | roadmap/tasks.toml:1336 | `implemented` note overclaimed "all four outcomes on both paths" + implied sponsored-revert coverage | Applied: note corrected — four outcomes incl. co-signed sponsored revert (unit); integration revert exercises non-sponsored path (also flagged by codex) |
| 5 | 3 | discuss-design | lib/mpp/methods/tempo.ex:561 | `:unsupported` (-32601) fail-opens to broadcast, logged at `:info` | Behavior kept (reference-confirmed); see resolution below (codex rated 8) |
| 6 | 4 | doc-gap | (commit) | Direct push to `development`, no PR review trail | Informational — no PR workflow used for this commit |

## Auto-applied fixes

- lib/mpp/methods/tempo.ex:49 — config docstring updated: optimistic path pre-simulates the
  full co-signed tx via `eth_simulateV1` (was stale "Simulates via `eth_call`").
- test/mpp/methods/tempo_test.exs — added "rejects a reverting CO-SIGNED sponsored tx before the
  fee payer broadcasts": builds a real co-signed fee-payer tx (mirrors the existing
  "co-signs and broadcasts" pattern), stubs `eth_simulateV1`→status `0x0`, asserts
  `Pre-broadcast simulation rejected` + `refute_received eth_sendRawTransactionSync` +
  `refute_received eth_sendRawTransaction`. Proves the sponsor never broadcasts a doomed
  co-signed tx. Verified green (`mix test.json test/mpp/methods/tempo_test.exs`: 112/112).
- roadmap/tasks.toml:1336 — `implemented` note corrected to stop overclaiming gate coverage
  (sponsored revert now unit-covered; integration revert exercises the non-sponsored path).
  `rmap validate && rmap render` clean.

## Discuss-tier resolutions

- **F5 `:unsupported` fail-open + log level (reversible discuss-design, position picked).**
  Codex rated this 8 ("guard goes dark"). Verified against the reference design: the task
  body itself specifies, and both reference SDKs (mpp-rs `simulate_before_broadcast`,
  mppx `fee-payer.ts`) implement, **fail-open on method-not-found (-32601)** — a node lacking
  the simulate RPC SKIPS the check rather than failing the payment. So the fail-open
  *behavior* matches the cross-SDK spec and the acceptance criterion; it is **not a defect**,
  and an attacker cannot force `-32601` (it is the node, not the client, declaring no support).
  Position picked: **keep the behavior unchanged.** The only residual is the `:info` log level —
  a security guard going dark on a misconfigured node arguably warrants `:warning` visibility.
  This is a one-word change in HIGH-tier (security-shaped) code; per the Step 9 ladder a fix
  there needs a second-grader dispatch, which is disproportionate for a debatable log-level
  nit where `:info` for graceful degradation is also defensible. **Recommended to user, not
  auto-applied.** Reversible — one-line follow-up if the user wants louder logging.

## Codex second-opinion

Status: dual-reviewer (job task-mqs8sfsc-yp2mqd, 2m45s)
Corroborated findings: 1 (doc drift), 2 (unit coverage), 3 (integration coverage), 4 (overclaim)
Codex-only findings (verified): 5 (fail-open visibility) — verified, behavior is reference-confirmed; log-level recommended to user, behavior kept
Codex-only findings (discarded as over-flag): none — F5's *priority* (8) was downgraded after confirming the fail-open is spec-mandated, but the underlying visibility observation is valid

## Correctness verification (in-session)

- `Onchain.Tempo.RPC.simulate/3` @spec confirmed in deps/onchain_tempo/lib/onchain/tempo/rpc.ex:116-117
  returns exactly `{:ok, :success} | {:ok, {:revert, String.t()}} | {:ok, :unsupported} | {:error, String.t()}`
  — the four `case` clauses in `simulate_cosigned_tx` match it exactly.
- `simulate_cosigned_tx` runs FIRST inside both `broadcast_and_verify` clauses (before
  `rpc_broadcast_sync`/`rpc_broadcast_async`) — no path broadcasts without simulating.
- `find_payment_call` still validates the payment exists/matches in the `verify/2` `with`
  chain (lib/mpp/methods/tempo.ex:169); dropping its result from `broadcast_and_verify` only
  removed the now-unused per-call simulation input.
- No dangling references to the removed `simulate_payment_call` / `payment_call` in lib/.
- Doc hygiene is exemplary: CHANGELOG, ROADMAP (rendered via rmap), docs/security-parity.md
  (✓ row added, tracked-row removed), tasks.toml (done/verified/implemented/done_at) all
  updated coherently and within disclosure policy (no exploit detail in committed files).

## Surfaced to user (NOT committed — disclosure policy)

See the audit summary. Three shipped-but-unprogressed gas-draining advisories and the
integration sponsored-revert follow-up are reported in the session summary, kept out of
committed public files per critical-rules.md § "NEVER BROADCAST AN UNPATCHED VULNERABILITY".
