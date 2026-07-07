---
sha: 7a6676e
short_sha: 7a6676e
audited_at: 2026-07-08
auditor_model: claude-opus-4-8
verdict: clean
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: Stripe stub-server scenario parity vs mpp-rs (task 64)

**Original commit:** 7a6676e — `harness: agent delivery — task 64 Stripe stub-server scenario parity vs mpp-rs`
**Author:** E.FU
**Files touched:** 3 (lib/mpp/methods/stripe.ex +17, lib/mpp/plug.ex +18, test/mpp/methods/stripe_test.exs)
**LOC:** +201 / -6

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | — | acceptance | lib/mpp/methods/stripe.ex | Idempotent-replay rejection verified byte-for-byte vs mpp-rs | No fix needed |
| 2 | 8 | out-of-scope / already-fixed | lib/mpp/methods/stripe.ex | Codex: `payload["externalId"]` echoed to receipt unbound → spoofing | Refuted as live issue — closed at HEAD (task 46, mppx #537); echo predates this diff |
| 3 | 3 | test-comment | test/mpp/methods/stripe_test.exs | Codex: 400-body test claims mpp-rs parity but our error is generic | Left — our sanitization is the *safer* intentional divergence |

### Core change reviewed & verified sound

**Idempotent-replay rejection.** This commit's actual lib change adds
`idempotent_replayed?/1` and rejects a 2xx Stripe response carrying
`Idempotent-Replayed: true` with `verification_failed` "Payment has already been
processed." Verified byte-for-byte against the Rust reference:
`refs/mpp-rs/src/protocol/methods/stripe/method.rs:143-152` — same header name
(`idempotent-replayed`), same `== "true"` test, and the **identical** rejection
string "Payment has already been processed." No golden-ratifies-a-wrong-constant
risk; this is faithful parity porting.

**`external_id` Plug plumbing (plug.ex).** Adds `:external_id` as an optional
per-method opt threaded into the `Charge` intent for both the single-method and
`:methods` paths. Additive config only; the value becomes an HMAC-bound request
field. Benign.

## Codex second-opinion

Status: dual-reviewer

Codex raised a **P8 externalId receipt-spoofing** claim and a **P8 stub-parity**
variant of it: `stripe.ex` reads `payload["externalId"]` and (at this commit's
state) echoed it into the receipt without checking it against the HMAC-bound
request, so a client could pay for one `externalId` and receive a receipt naming
another. **Verified against our actual code — this is not a live vulnerability:**

- **Not introduced by this commit.** 7a6676e's `stripe.ex` diff only touches the
  idempotent-replay area; it never touches `check_status`. The unbound
  `payload["externalId"]` echo *predates* this commit.
- **Closed at HEAD.** `verify/2` gates `check_external_id_binding/2` **first**
  (`stripe.ex:99,144-147`): any credential whose `payload["externalId"]` disagrees
  with the bound `charge.external_id` is rejected with `:invalid_challenge` — the
  mppx #537 port introduced in **task 46 (`ff57a9d`)**. And `check_status` at HEAD
  echoes the **bound** `charge.external_id` (`stripe.ex:249`), not the payload
  value. Both of Codex's cited reference behaviors
  (`refs/mppx/src/stripe/server/Charge.ts:119`, `refs/mpp-rs/.../method.rs:236`)
  are therefore already matched at HEAD.
- No disclosure concern: the gap is already fixed in shipped code, not an open
  vulnerability.

Codex's **P3** (our generic "Stripe PaymentIntent creation failed" 400 body vs
mpp-rs/mppx surfacing Stripe's error detail): Codex itself notes ours is *safer*.
Intentional error-sanitization divergence (no internal detail into public 402s —
same posture affirmed in the 542a525 audit). The only actionable sliver is a
test-comment that overclaims "exact mpp-rs parity" for public error detail; left
as a pri-3 nit, not worth a churn on a passing test whose behavior is correct.

**Hidden-test-failure scan:** Codex PASS — no `assert true`, swallowed catch-all,
rescue/catch masking, or missing failure path in the added scenarios. Concurred.

## Auto-applied fixes

- (none — the one live-code concern is already remediated at HEAD; the P3 item is
  an intentional safer divergence)

## Discuss-tier resolutions

- externalId binding (Codex P8): resolved by cross-checking HEAD — the mppx #537
  guard (`check_external_id_binding`, task 46) and bound-value receipt echo close
  it. Recorded as verified-closed, not re-opened.
