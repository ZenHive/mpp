# audit a38172e — harness: agent delivery — task 29 Session intent schema (doc follow-up)

verdict: clean
scope: `lib/mpp/intents/session.ex` (moduledoc only), `test/mpp/intents/session_test.exs`, AGENTS.md
reviewers: Claude only — Codex second-opinion not dispatched (session policy)

Second delivery run for the same task; the code delta is one moduledoc sentence restating that
`decimals` and `external_id` are transient, plus a test asserting the wire map has no
`externalId`. The wire claim itself is verified in the `290be9d` report against
`refs/mpp-rs/src/protocol/intents/session.rs:35-65`.

## Categories 1-6

No findings. AGENTS.md regeneration in the same commit keeps the cross-family reviewer surface in
sync with CLAUDE.md (`sync-agents-md.sh --check` passes on the current tree).

Process note (Cat 6, priority 2, not actionable now): two harness runs landed for one task
(`run-…-6ddeb5e4` and `run-…-a343b1b7`), each with its own roadmap flip commit. Harmless
duplication of the delivery trail, recorded for pattern-watching only.

## Codex second opinion (2026-08-18)

Codex audited both task-29 commits against the reference SDKs with cited
evidence. Its headline claim — that our wire format "does not fully match" —
holds only partly; one of its findings does not survive verification.

| finding | verdict |
|---|---|
| `session.ex` optional wire values accepted without type validation: `"unitType" => 123` succeeds although both references type it `Option<String>` (prio 7) | **Confirmed, FIXED.** Added `Shared.validate_optional_string/1` and wired `unit_type` / `recipient` / `suggested_deposit` through it in `Session.new/1`, so `from_request/1` rejects them with `:invalid_field_type`. Evidence: `refs/mpp-rs/src/protocol/intents/session.rs:40-61`. Six tests added (three `new/1`, two wire-shape `from_request/1`, one nil-passthrough). |
| `session_receipt.ex:175` emits `externalId`, absent from the reference session-receipt encoders (prio 6) | **Partly refuted.** `refs/mpp-rs/.../session_receipt.rs:33-70` indeed has no such field — but mppx's **base** receipt schema declares it optional at `refs/mppx/src/Receipt.ts:12`, and we omit it when nil. So it is additive and mppx-compatible, not a divergence. The moduledoc *was* wrong ("echoed from the charge request" on a session receipt) — **FIXED**, now stating the additive status with both refs cited. |
| `shared.ex:10` `currency` is lowercased while both references preserve the supplied string (prio 5) | **Confirmed, deliberately NOT changed — operator decision needed.** `refs/mpp-rs/.../session.rs:24` uses a checksummed token address in its doctest and `:169` asserts verbatim round-trip preservation; mppx preserves too. Two references agreeing is the spec in practice. But the normalization is documented public behavior of a released 0.13.0 library (`charge.ex:15`), so silently changing what consumers' challenges contain inside an *audit* commit is the wrong venue. The HMAC path is not at risk — challenges bind our own serialization and the credential path reuses raw base64url bytes. The latent hazard is client-side: parsing a foreign challenge and re-serializing would mutate a checksummed address. **Escalated to the operator.** |
| `session.ex:30` `external_id` retained as a public field with no production consumer, deliberately dropped at serialization (prio 4) | **Confirmed as correct behavior.** Both references' `SessionRequest` lack it (`session.rs:35-65`, `refs/mppx/src/tempo/Methods.ts:231-300`) — our omission from the wire is right. The unused public field is cosmetic; dropped. |
| `AGENTS.md` gained a 32-line "harness-injected… ephemeral, do not commit" block (prio 6) | **Confirmed for the snapshot, already closed** — `41974e2` regenerated `AGENTS.md`; no such block at HEAD (verified by grep). |
| `session_test.exs:140` claims to match the Rust fixture but adds `decimals`/`externalId`, and duplicates the unknown-field test at :170 (prio 4) | **Confirmed, open.** Minor test-hygiene drift. |
| roundtrip tests share encoder and decoder, so both being wrong would still pass (prio 3) | **Confirmed, known.** Mitigated by separate literal-key fixtures; not independent wire evidence. This is why the `:cross_validation` tier exists. |
| `unitType`/`methodDetails` optionality differs between mpp-rs and mppx (`discuss`) | **Left open** — the references genuinely disagree, so there is no authority to converge on without a spec ruling. |
