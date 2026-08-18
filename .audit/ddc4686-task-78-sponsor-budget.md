# audit ddc4686 — harness: agent delivery — task 78 Add aggregate in-flight sponsor budgets

verdict: clean (scoped audit — see "Depth and its limits")
scope: new `lib/mpp/methods/tempo/sponsor_budget.ex` (496 lines) + `tempo.ex`, `store.ex`,
       `con_cache_store.ex`, errors/MCP/plug wiring, ~1 100 lines of tests
reviewers: Claude only — Codex second-opinion not dispatched (session policy)
prior gates: harness cross-family reviewer at delivery; shipped in 0.12.0 and disclosed as
`GHSA-j4j7-7xpr-c7cr` (CVE requested from the EEF CNA 2026-08-18)

## Depth and its limits

This is a 2 230-line security-critical delivery that already passed a cross-family reviewer gate
and shipped under a published advisory. This audit did **not** re-derive the concurrency proof.
It read the reservation state machine end to end and checked the invariants that a later,
unrelated diff could plausibly break. Stated plainly so the report isn't read as more assurance
than it is.

## What was checked

- **Fail-closed shape.** `reserve/3` validates before touching the store (`fee > 0`,
  `valid_before > now`, non-blank `sponsor_id`, `fee <= max_in_flight_total_fee`, both limits
  positive integers) and returns `{:error, :invalid_request}` from a catch-all clause rather than
  falling through. ✓
- **Limits pinning.** A live reservation set pins its limits; a divergent config gets
  `{:error, :limits_mismatch}` instead of silently re-pinning. Re-pinning happens only when the
  swept set is empty — i.e. when there is no exposure to re-pin against. ✓
- **Ownership.** Every mutation goes through `mutate_owned/5` / `release_owned/3` keyed by the
  random `reservation_id` from `reserve/3`; a missing id yields `:ownership_lost`, never a
  best-effort delete. ✓
- **Sweep is conservative.** Expiry runs off `valid_before` + a named clock-skew margin, and a
  capacity rejection that swept something still persists the swept state (`admit/5`'s
  `original_state` branch), so a full budget can drain without a successful reservation.
- **Reconciliation is opt-in and bounded** (`:reconcile` fetcher, fan-out limit 8, 5 s timeout),
  and re-reserves through the same atomic path rather than assuming the freed capacity.

## Categories 1-6

No findings. CHANGELOG carries the 0.12.0 security section; `docs/security-parity.md` carries the
matching ✓ row.

## Codex second opinion (2026-08-18)

Dispatched post-hoc after the initial single-reviewer pass. Codex verified fee
arithmetic and transaction validity against both `refs/mppx` and `refs/mpp-rs`;
reservation phases, reconciliation and owner fencing against `refs/mppx` only
(`mpp-rs` has no aggregate-budget implementation).

| finding | verdict |
|---|---|
| `lib/mpp/methods/tempo.ex:475` bare `function_exported?/3` rejects compiled-but-unloaded custom stores (prio 7) | **Confirmed, already closed** by `f788c6e` (`Code.ensure_loaded?` before the callback check). No action. |
| `lib/mpp/methods/tempo.ex:220` descripex `errors:` omits `:sponsor_capacity_exhausted` although `verify/2` returns it at `tempo.ex:832` (prio 3) | **Confirmed, FIXED** — added to the `api(:verify, …)` metadata. |
| `sponsor_budget_test.exs:65` concurrency test races isolated reservations, not duplicate full verifications — the dedup-loser/owner-fencing race is untested (prio 6) | **Confirmed, open.** Real coverage gap; writing a duplicate-verification race test is a task-sized change, not an audit fix. Recorded here rather than silently dropped. |
| `tempo_test.exs:2332` failed post-broadcast `:pending` test asserts only the receipt, not that the reservation is retained — a fail-open release regression would pass (prio 6) | **Confirmed, open.** Same class as above. |
| `sponsor_budget_test.exs:272` mixed-validity TTL refresh goes through `TtlSpyStore`, not production `ConCacheStore` (prio 5) | **Confirmed, open.** The spy proves the call, not the expiry. |

The three open items are genuine test-quality gaps on the sponsor anti-drain
path. They are named here, in the ledger, so the next roadmap pass sees them.
