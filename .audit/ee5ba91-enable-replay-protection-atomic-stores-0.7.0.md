---
sha: ee5ba91
short_sha: ee5ba91
audited_at: 2026-07-08
auditor_model: claude-opus-4-8
verdict: clean
codex_status: claude-only-codex-stalled
audited_by: audit-review v1
---

# Audit: Enable replay protection by default and require atomic dedup stores (0.7.0)

**Original commit:** ee5ba91 — `Enable replay protection by default and require atomic dedup stores (0.7.0)`
**Author:** E.FU
**Files touched:** 23 (6 lib: application.ex, methods/evm.ex, methods/tempo.ex, plug.ex, tempo/con_cache_store.ex, tempo/store.ex; mix.exs; + tests & docs)
**LOC:** +397 / -435

The flagship 0.7.0 security commit. Every vulnerability it closes is **already
publicly disclosed** (published GitHub advisories + the 0.7.0 CHANGELOG), so this
report carries full detail. Reviewed against the actual code and the reference SDKs.

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| — | — | — | — | No findings | — |

### GHSA closures — each verified against the code

**GHSA-w8j7-7qc3-5f24 (non-atomic dedup TOCTOU) — CLOSED.**
- `check_and_mark/2` is now a **required** `MPP.Tempo.Store` callback — the
  `@optional_callbacks [check_and_mark: 2]` declaration is removed (`store.ex`).
- `Store.supports_atomic?/1` is **deleted entirely** (`grep -rn supports_atomic lib/`
  → no matches). There is no atomic-vs-fallback branch left anywhere.
- All **three** dedup layers reject a non-atomic store at init and use only
  `check_and_mark`: `plug.ex` ("no non-atomic fallback (GHSA-w8j7-7qc3-5f24)",
  `validate_store!` via `function_exported?(store, :check_and_mark, 2)`),
  `methods/tempo.ex`, and `methods/evm.ex` (`commit_hash_used` → single
  `Store.check_and_mark` call, `validate_store!` rejects get/put-only stores).
- Reference SDKs meet the same contract: mpp-rs `put_if_absent` fails closed on
  `AtomicUnsupported`; mppx atomic `update`.

**Replay protection on by default (issue #7) — CLOSED.**
- `MPP.Application` now supervises `ConCacheStore.child_spec([])`; `mix.exs` wires
  `mod: {MPP.Application, []}` (previously a commented-out stub).
- `Store.resolve/1` encodes the policy cleanly: `nil` (absent) → app-started default
  store; `false` → `nil` (explicit opt-out); any other ref → unchanged. Call sites
  thread `... |> validate_store!() |> Store.resolve()`, so validation precedes the
  default-on resolution and the default `ConCacheStore` (itself atomic) never trips
  validation.
- Breaking-change semantics are coherent and documented (CHANGELOG "Breaking changes"):
  `store: nil`/absent now means *use the default store*, not *no dedup*; opt out with
  `store: false` / `"store" => false`. No path silently disables dedup.
- The now-wired `MPP.Application` is removed from the 95%-coverage exclusion list in
  `mix.exs` and covered by a new `test/mpp/application_test.exs` (coverage-before-mutation
  respected).

**GHSA-vp5h-xh25-44wf (EVM payment-proof single-use) — CLOSED.**
- `MPP.Methods.EVM` tx-hash single-use is checked **before** on-chain verification and
  atomically committed **after** via `Store.check_and_mark`, keyed on the canonical
  (lowercased) hash (`store_key/1`), mirroring the Tempo `type="hash"` path. Store
  misconfig rejected at init via `validate_config!`.

**GHSA-34g7-vx6g-82mq (Tempo static-memo) — backstopped.**
- A static `"memo"` now requires a configured `"store"` or `MPP.Plug` raises at init —
  the dedup store provides the single-use guarantee a static memo cannot (it pins
  attribution independently of the per-challenge nonce).

**Docs consistency check.** The CHANGELOG's older `## [0.6.3]` entry still describes
the EVM store as having a "non-atomic `put/2` fallback" — this is **correct history**
(0.6.3 shipped that fallback; 0.7.0 removed it, per the `## [0.7.0]` entry). Append-only
changelog; no edit warranted.

## Auto-applied fixes / Discuss-tier
- (none — commit is clean)

## Codex second-opinion

Status: **claude-only (Codex review stalled).** A Codex second-opinion was dispatched
but hung in its "verifying" phase for 8+ minutes without producing any findings
(32-line job log, no verdict) and was cancelled. This report rests on the direct
review above: all four GHSA closures were verified against the actual `lib/` code and
cross-checked against the reference SDKs and the published advisories. The commit is
well-documented, internally consistent across all three dedup layers, and adds the
required coverage. Clean.
