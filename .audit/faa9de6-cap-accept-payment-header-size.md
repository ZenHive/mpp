---
sha: faa9de6
short_sha: faa9de6
audited_at: 2026-07-08
auditor_model: claude-opus-4-8
verdict: clean
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: Cap Accept-Payment header size and finalize 0.7.0 release docs

**Original commit:** faa9de6 — `Cap Accept-Payment header size and finalize 0.7.0 release docs`
**Files touched:** 7 (lib/mpp/headers.ex, test/mpp/headers_test.exs, CHANGELOG.md, docs/security-parity.md, mix.exs, + release docs)
**LOC:** +55 / -8

> Note: the `lib/mpp/headers.ex` cap + tests in this commit were authored during
> this audit session (P6 finding from the bb6476a review). This report is an
> **independent** re-review — the Codex second-opinion was dispatched precisely to
> avoid rubber-stamping self-authored code.

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | — | correctness | lib/mpp/headers.ex:400 | 16 KiB Accept-Payment DoS cap — verified correct (both reviewers) | No fix needed |
| 2 | 5 | doc-accuracy | CHANGELOG.md:13 | "mpp-rs #299 parity" overstates: the reference SDKs do **not** cap their Accept-Payment parser — ours is an independent hardening | Documented, not edited (released v0.7.0) |

### Core change — DoS cap verified sound (dual-reviewer)

`parse_accept_payment_entries/1` gains a `byte_size(header) > @max_token_len`
(16 KiB) guard returning `{:error, :malformed}` **before** `String.split`. Confirmed
by direct read and Codex:

- **Guard placement** correct — short-circuits before the split allocates a parts list.
- **Both consumer paths covered** — public `parse_accept_payment/1` → `[]`, and the
  server path `MPP.Plug` → `apply_accept_payment_header/3` → no-op (offers unchanged).
  No alternate unguarded `String.split` entry point exists in `headers.ex` / `plug.ex`.
- **Boundary** is strict `>` (not `>=`) — exactly 16 KiB still parses.
- **Ignore-vs-reject semantics** correct — Accept-Payment is advisory (spec MAY-ignore);
  oversized → ignored (fall back to server-offer order), consistent with mpp-rs
  (`server/compose.rs:41-55`) and mppx (`server/Mppx.ts:2319-2333`) parse-failure fallback.
- **Tests are real** — oversized-parse asserts `[]`; oversized-apply asserts unchanged
  offers using syntactically-valid content that *would* reorder if parsed (proves the
  cap short-circuits ranking, not just malformed-ignore); at-limit-parses asserted
  separately. No false-green patterns.

## Discuss-tier resolution — Finding 2 (doc-accuracy, P5)

Codex flagged that the 16 KiB **value** matches mpp-rs `MAX_TOKEN_LEN`
(`refs/mpp-rs/src/protocol/core/headers.rs:18`) and mppx `maxRequestParameterLength`
(`refs/mppx/src/Challenge.ts:10`), but those are *challenge/request/token* caps — the
reference SDKs' **Accept-Payment parsers have no size guard** at all (verified:
mpp-rs `accept_payment.rs` `.split(',')`; mppx `AcceptPayment.ts` `.split(...)` + an
empty-parts check only). So the CHANGELOG title "mpp-rs #299 parity" is generous —
our cap is an *independent hardening beyond* the reference SDKs, reusing the #299
cap value on a fourth surface the refs leave uncapped.

**Resolution: documented, not edited.** (a) The CHANGELOG line lives in the
**released, tagged `v0.7.0`** section — a historical record that should not be
rewritten. (b) The living `docs/security-parity.md` row is itself accurate (it lists
"our implementation" covering 4 client-input sites; it does not claim upstream caps
Accept-Payment). The only overstatement is the released changelog *title*, and the
substance (we cap where the refs don't — strictly *more* protective) is correct. No
code or ledger defect; noted here for the record.

## Auto-applied fixes
- (none — the cap is correct; the one finding is a released-changelog wording nuance, not editable)

## Codex second-opinion

Status: dual-reviewer. Codex independently verified the cap on all axes (placement,
both-path coverage, `>` boundary, semantics, test quality) and raised the P5
doc-parity nuance, which was cross-checked against the reference SDKs and resolved as
above. No code findings.
