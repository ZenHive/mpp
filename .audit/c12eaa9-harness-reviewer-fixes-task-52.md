---
sha: c12eaa9abf167829dd6b515e959a6ea6e0bf74de
short_sha: c12eaa9
audited_at: 2026-07-09
auditor_model: claude-fable-5
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: harness: reviewer fixes — task 52 Stripe Connect settlement options

**Original commit:** c12eaa9 — `harness: reviewer fixes — task 52 Stripe Connect settlement options (run run-1783571058611-d23068b2)`
**Author:** harness (grok implementer, reviewer-gated)
**Files touched:** 3 (lib/mpp/methods/stripe.ex + unit/integration tests)
**LOC:** +470 / −12

Direct-delivery harness commit; reviewer-gated at dispatch time (no PR trail by design).
Wire mapping and validation verified line-by-line against the mppx reference
(`refs/mppx/src/stripe/server/Charge.ts` `validateConnectSettlement` /
`createWithSecretKey`): param names (`application_fee_amount`, `on_behalf_of`,
`transfer_data[destination]`, `transfer_data[amount]`, `transfer_group`), the
`stripe_account` → `Stripe-Account` header routing, the non-empty account-id rule,
the ≤-payment-amount rule with identical error texts, and independent (not summed)
fee/transfer validation all match. The server-only non-leak guarantee (connect never
in the public challenge) is pinned by tests.

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 7 | wire-parity (codex) | lib/mpp/methods/stripe.ex:273 | Missing `Stripe-Version: 2026-02-25.preview` (mppx sends it; required for SPT preview) | applied — header added + pinned in 2 tests |
| 2 | 5 | bug (codex) | lib/mpp/methods/stripe.ex | Non-string `transfer_group` (e.g. `%{}`) bypassed validation, raised in `URI.encode_query` at request time | applied — `validate_transfer_group/1` + test |
| 3 | 4 | doc-gap | CHANGELOG.md | No `[Unreleased]` entry for Connect settlement | applied — entry added |
| 4 | 3 | doc-gap | CLAUDE.md:86 | Module map omitted Connect settlement on the Stripe row | applied |
| 5 | — | dropped (codex) | lib/mpp/methods/stripe.ex:216 | mppx rejects amounts > `Number.MAX_SAFE_INTEGER`; our `Integer.parse` accepts them | dropped — JS-precision artifact, not protocol semantics; BEAM integers are exact and Stripe enforces its own amount ceiling. Porting `isSafeInteger` would cargo-cult a JS limitation |

## Auto-applied fixes

- `lib/mpp/methods/stripe.ex`: `@stripe_preview_version "2026-02-25.preview"` sent as `stripe-version` header on every PaymentIntent request (mppx `stripePreviewVersion` parity — refs/mppx/src/stripe/internal/constants.ts documents it as required for `shared_payment_granted_token` private preview). NOTE: not yet exercised against live Stripe — run `mix test.json --include integration` with Stripe creds before the next release to confirm the pinned version is accepted.
- `lib/mpp/methods/stripe.ex`: `validate_transfer_group/1` — nil or binary passes; anything else returns the standard connect verification error instead of raising at request time (mppx enforces string via TS types; this is the runtime equivalent).
- Tests: `stripe-version` header asserted in the mppx cross-validation test and the no-connect test; non-string `transfer_group` rejection test added.
- CHANGELOG `[Unreleased]` + CLAUDE.md module map row.

## Acceptance criteria (Task 52)

- ~~"Challenge `method_details` carries Connect settlement fields"~~ — **criterion was wrong**; the discovery the task body mandated (read mppx at implementation time) establishes the opposite: mppx documents `connect` as *"Not included in MPP challenges"* (server-only credential). Shipped behavior is correct; criterion refined via `rmap status 52 done --implemented "..."`. Tests pin the non-leak (`refute challenge_header =~ "acct_secret"`).
- Connect routing (destination / direct / application fee) ✅ — verified + wire-mapped against mppx.
- Cross-validated against mppx output ✅ — exact form-body test; audit closed the one true gap (Stripe-Version).
- Integration test with a Connect account ✅ — exists, flunks loudly on missing `STRIPE_CONNECT_ACCOUNT` (not runnable in this audit session — no creds).

## Codex second-opinion

Status: dual-reviewer (job task-mrd3i2ez-ytp434)
Corroborated findings: 3, 4 (doc gaps)
Codex-only findings (verified + applied): 1 (Stripe-Version — confirmed against refs/mppx/src/stripe/server/Charge.ts:344), 2 (transfer_group — confirmed `URI.encode_query` raises on map values)
Codex-only findings (discarded as over-flag): 5 (unsafe-integer — see Findings table rationale)

HIGH-tier grader verdict on the applied stripe.ex fixes: see the batch grader section in `.audit/1e6fa07-share-credential-single-use-de.md`.
