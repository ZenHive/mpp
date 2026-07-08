---
sha: f6b9e10f1fd6ac87b941d4d021502f770d07e614
short_sha: f6b9e10
audited_at: 2026-07-08
auditor_model: claude-fable-5
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: Add parse-time challenge field validation (Task 72)

**Original commit:** f6b9e10 — `Add parse-time challenge field validation (Task 72)`
**Author:** E.FU
**Files touched:** 14
**LOC:** ±428
**PR:** none — direct push to development (repo convention: local dev + harness auto-land)

## Reference verification (wire-format rule)

All citations in the diff spot-checked against the local reference clones:

- Spec ABNF `payment-method-id = 1*LOWERALPHA` confirmed at `refs/mpp-specs/specs/core/draft-httpauth-payment-00.md` §"Method Identifier Format" ("case-sensitive and MUST be lowercase").
- mppx method regex `/^[a-z][a-z0-9:_-]*$/` (`refs/mppx/src/Challenge.ts:353`) is indeed looser than the spec; mpp-rs enforces `is_ascii_lowercase` on all chars (`refs/mpp-rs/src/protocol/core/headers.rs:255`) — the spec tie-break toward lowercase-letters-only is correct. Codex independently confirmed.
- mpp-rs 16 KiB boundary (`headers.rs:161`): `>=` tested against the accumulator *before* the current byte is pushed → accepts exactly MAX, rejects MAX+1 — the diff comment's analysis is accurate; at-limit test byte math (12,288 JSON bytes → 16,384 base64url) checks out.
- digest `sha-256=` prefix matches mpp-rs `is_valid_digest_format` (`headers.rs:214`) and mppx `z.regex(/^sha-256=/)` (`Challenge.ts:26`).
- Request-must-be-JSON-object: mpp-rs accepts any `serde_json::Value` (`headers.rs:267`); mppx requires an object (`z.record`). Our object requirement follows mppx; divergence from mpp-rs is documented in the code comment. Defensible (2-of-3 agreement with spec's "request object" framing).
- Dead-clause removal in `check_request_recipient` verified behavior-preserving: the removed clause was a strict subset of the retained catch-all with an identical return.
- `:invalid_expires` produced and consumed only within `verifier.ex`; MCP `encoded` is a re-encoded base64url string, so `validate_fields` composes correctly on that path.

## Findings (3-reasoner merge: Claude + Codex; no PR bots — direct push)

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 9 | bug (codex, verified) | lib/mpp/credential.ex | Non-string optional echoed fields (`expires`/`description`/`opaque`, top-level `source`) decode OK then crash verifier (HMAC join / ISO-8601 parse) on wire input | applied: `:invalid_optional_field` at decode + 4 tests |
| 2 | 6 | bug (codex, verified; rated down from 8 — not wire-reachable, Jason never yields atom keys) | lib/mpp/mcp.ex:460 | `jcs_compatible?/1` ignored key types; atom-keyed native request leaks new `JCS.canonicalize/1` raise instead of `:invalid_challenge` | applied: pre-check requires binary keys + test |
| 3 | 5 | consistency (Claude + Codex, corroborated) | lib/mpp/plug.ex:134 | Init validates name uniqueness but not shape — a non-`1*LOWERALPHA` `method_name/0` emits challenges this library's own parse paths reject | applied: boot-time raise via shared `Challenge.valid_method_name?/1` + test |
| 4 | 4 | doc-gap (Claude + Codex, corroborated) | lib/mpp/method.ex:47 | `method_name/0` callback doc said only "lowercase string"; effective contract is now `1*LOWERALPHA` | applied: callback + moduledoc updated; `method_test` mock renamed `mock_with_details` → `mockwithdetails` |
| 5 | 5 | doc-gap | CHANGELOG.md | Audit fixes change public behavior (new error atom, boot-time raise) | applied: audit-hardening paragraph appended under [Unreleased] |

## Auto-applied fixes

- `lib/mpp/credential.ex`: optional echoed-challenge fields + `source` must be nil-or-string (`:invalid_optional_field`); errors list in `api(:decode, ...)` extended
- `lib/mpp/mcp.ex`: `jcs_compatible?/1` requires binary map keys
- `lib/mpp/challenge.ex`: `valid_method_name?/1` extracted (`@doc false`) for sharing with Plug init
- `lib/mpp/plug.ex`: `validate_method_name_format!/1` raises at `init/1` on non-`1*LOWERALPHA` names
- `lib/mpp/method.ex`: `method_name/0` docs state the `1*LOWERALPHA` constraint
- `CHANGELOG.md`: audit-hardening paragraph under [Unreleased]
- Tests: 4 new credential tests, 1 MCP test, 1 plug init test, method_test mock rename

## Stake-gated grading (HIGH tier — core verification/parse paths)

Second-grader dispatch (Codex, session 019f409e-b5ef-7431-a83d-ee269805e1c9) on the fix diff: **approve** — "credential decode now rejects non-string echoed optional fields …; MCP native request maps with non-string keys now return `{:error, :invalid_challenge}` …; Plug init fails fast …. Focused suite 173 tests, 0 failures; Credo strict clean; local refs align on string optional challenge fields / `Option<String>`." (Grader's sandbox could not run dialyzer; per-edit hooks ran `mix dialyzer.json` clean on this side.)

## Discuss-tier resolutions

- (none — finding 3 was corroborated by both reasoners, i.e. convergent, and is reversible: boot-time raise on configs that were already broken end-to-end after this commit)

## Codex second-opinion

Status: dual-reviewer (session 019f4091-32ef-7d82-ba57-538138cb9141)
Corroborated findings: 3, 4
Codex-only findings (verified): 1, 2
Codex-only findings (discarded as over-flag): none
Codex confirmed the spec/mppx/mpp-rs method-ABNF claims and ran the changed test files (281/281 green).

## Acceptance criteria (Task 72, from roadmap/tasks.toml — no Linear link)

- ✅ Malformed id/method/request/digest rejected at parse time with distinct errors, matching refs (verified against both SDKs above)
- ✅ Invalid `expires` distinguished from expired (`:invalid_expires` → credential-mismatch problem type; tests updated)
- ✅ JCS rejects non-binary keys per documented contract (raise + 3 tests)
- ✅ Property + unit tests cover field-by-field malformed input (property test over non-conformant method chars; per-field unit tests on all three parse paths)
