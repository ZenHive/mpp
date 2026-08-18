# Codex second opinion — audit(4eebb5c..6a4d95f)

The `d9cd224` audit ran single-reviewer: the session rule in force forbade
dispatching subagents unprompted, so the skill's mandatory Codex pass was
recorded as missing in every full report rather than silently skipped. The
operator then asked for it. This file records the second-reviewer pass and what
it changed.

## Scope

Five background Codex jobs over the six commits where a second opinion can buy
something — the five that touch `lib/`, plus the CI workflow commit. The seven
roadmap/TOML-only commits in the range stayed single-reviewer: there is no
production surface for a second reasoner to disagree about.

| commit | subject | Codex verdict |
|---|---|---|
| `ddc4686` | task 78 sponsor budget | 1 already-closed bug, 1 doc fix, 3 open test gaps |
| `9461e4e` | 0.11.0 prep / CI gate | REQUIRES CHANGES — 2 already closed, 1 fixed, 2 open |
| `f788c6e` | load store modules before callback check | PASS WITH WARNINGS — independently confirmed this report's conclusion |
| `290be9d` + `a38172e` | task 29 session intent wire keys | 1 real validation gap (fixed), 1 finding refuted, 1 escalated |
| `ba5893a` | cross-validation nightly CI | 1 already closed, 3 fixed, 1 dropped, 1 open |

## What the second reviewer actually caught

Codex found real defects the first pass missed. The three that mattered:

1. **`--include integration` cannot enforce "never a silent 0-tests pass".** The
   workflow comment claimed that guarantee; `--include` does not provide it,
   because untagged tests still run and green the job. Codex verified this by
   running a nonexistent tag: 36 untagged tests passed, exit 0. Fixed to
   `--only integration`, which exits 1 when nothing matches.
2. **`ex_unit_json` auto-retry can green a real conformance divergence.** Retry
   defaults to `true` (`deps/ex_unit_json/lib/ex_unit_json/config.ex:176`); a
   healed failure is reported as `flaky` with exit 0 and survives only in the
   log. Both nightly workflows now pass `--no-retry`.
3. **Session optional fields accepted any type.** `"unitType" => 123` was
   accepted although mpp-rs types it `Option<String>`
   (`refs/mpp-rs/src/protocol/intents/session.rs:40-61`), so we could build a
   request the reference SDKs cannot parse. Fixed with
   `Shared.validate_optional_string/1` + six tests.

Codex also over-flagged once, which is the expected failure direction: it called
`externalId` on the session receipt a divergence by citing only the specific
session-receipt encoders, missing that mppx's **base** receipt schema declares it
optional (`refs/mppx/src/Receipt.ts:12`). Refuted; only the wrong moduledoc
wording was real.

## Discovered while verifying: a masked test-isolation defect

Running the offline suite to check the fixes reported `flaky: 3` — auto-retry
had been healing them into a green run, the exact pattern finding 2 describes.
They were not noise:

`MPP.Test.TempoMemoryStore` registers its Agent under the global name
`__MODULE__`, because `MPP.Tempo.Store` dispatches on the module and carries no
pid/name argument. `tempo_test.exs` and `tempo_full_flow_test.exs` were both
`async: true` and both call `start_supervised!(TempoMemoryStore)` — so they
raced, the loser got `{:already_started, pid}`, and when they did *not* raise
they shared one dedup table. That makes replay-protection assertions depend on
the scheduler.

Fixed by serializing the two modules (`async: false`, the idiomatic ExUnit answer
for a globally-named resource) and documenting the constraint in the store's
moduledoc so the next test does not re-introduce it. Verified with
`--no-retry` across seeds 1 / 424242 / 987654: 1106 passed, 0 failed, 0 flaky
(was 3 flaky before).

## Applied in this commit

| file | change |
|---|---|
| `.github/workflows/integration.yml` | `--include integration` → `--only integration --no-retry`; corrected the comment |
| `.github/workflows/cross-validation.yml` | added `--no-retry` |
| `lib/mpp/intents/shared.ex` | added `validate_optional_string/1` |
| `lib/mpp/intents/session.ex` | `unit_type` / `recipient` / `suggested_deposit` validated; `:invalid_field_type` added to the descripex error surface |
| `lib/mpp/methods/tempo.ex` | `:sponsor_capacity_exhausted` added to the `verify/2` error metadata |
| `lib/mpp/methods/tempo/session_receipt.ex` | corrected the `external_id` moduledoc, citing both refs |
| `mix.exs` | `ex_ast` `~> 0.12` → `~> 0.12.0` |
| `test/mpp/intents/session_test.exs` | 6 tests for the new validation |
| `test/mpp/tempo/cross_validation_test.exs` | removed the `assert true` placeholder, kept its explanation as a comment |
| `test/mpp/methods/tempo_test.exs`, `tempo_full_flow_test.exs` | `async: false` + rationale |
| `test/support/tempo_memory_store.ex` | documented the single-global-instance constraint |

`mix precommit.full` exits 0 on the result: dialyzer 0 warnings, reach clean,
doctor 100%, credo clean, coverage above the 95% critical-tier threshold,
`AGENTS.md` fresh, `deps.audit.gated` clean. `:integration` and
`:cross_validation` were not run this session (live credentials / JS toolchain).

## Open, deliberately not fixed here

- **`currency` lowercasing** (`shared.ex`) — both references preserve the string
  verbatim; we normalize. Documented public behavior of a released library, so
  the change is the operator's call, not an audit's. Detail in the task-29
  reports.
- **Sponsor-budget test gaps** (3) — the dedup-loser/owner-fencing race, the
  reservation-retention assertion on failed post-broadcast, and TTL refresh
  against production `ConCacheStore` rather than the spy. Task-sized.
- **`agents.check` is host-only** — a runner cannot execute a script that lives
  in another checkout. Enforced on the developer host; flagged, not papered over.
- **`descripex_test.exs:82`** — the `short_name` atom→string contract is unasserted.
- **No repository-controlled alert** for a failed scheduled run.
- **`CHANGELOG.md:96`** 0.11.0 dependency versions are the parent's, not the
  released ones. Not touched: that file carries another session's uncommitted work.
