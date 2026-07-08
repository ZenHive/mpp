---
sha: 059ab84
short_sha: 059ab84
audited_at: 2026-07-08
auditor_model: claude-opus-4-8
verdict: clean
codex_status: claude-only
audited_by: audit-review v1
---

# Audit: Expiration and DID helpers (task 27)

**Original commit:** 059ab84 — `harness: agent delivery — task 27 Expiration and DID helpers`
**Author:** E.FU
**Files touched:** 7 (lib/mpp.ex, lib/mpp/did.ex, lib/mpp/expires.ex, package-lock.json, test/mpp/descripex_test.exs, test/mpp/did_test.exs, test/mpp/expires_test.exs)
**LOC:** +577 / -0

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| — | — | — | — | No findings | — |

Two new consumer helper modules, both reviewed at HEAD (folds in the 9a81374 fix).

**`MPP.Expires` — expiry gate is correct (security-relevant).**
- `assert!/2` (expires.ex:103-123): `nil` → raise `InvalidChallengeError` ("missing"); binary → `DateTime.from_iso8601` (which normalizes any offset to UTC) → `expired?` → raise `PaymentExpiredError` when past, `:ok` otherwise; malformed binary → raise invalid; the non-binary catch-all also raises invalid. **No input path silently returns `:ok`** — every rejection raises a typed error.
- `expired?/1` (expires.ex:131-133): `DateTime.compare(utc_now(), expires_dt) == :gt`. Correct absolute-instant comparison; exactly-at-expiry (`:eq`) stays valid — a standard inclusive "valid until" convention, not a bug.
- Duration helpers (`seconds`/…/`years`) use explicit `@seconds_per_*` constants; `months` = 30-day, `years` = 365-day, documented as mppx-compatible.

**`MPP.DID` — parser rejects all malformed forms, never raises.**
- `parse_evm_did/1` (did.ex:44-61): only matches the `did:pkh:eip155:` prefix; rejects leading-zero chain-id strings (`invalid_chain_id_string?`), requires full `Integer.parse` consumption + `chain_id >= 0`, validates the address is exactly 40 hex chars (`normalize_address`), and downcases. Every failure path returns `{:error, :invalid_did}` — no raise, no partial accept.

## Auto-applied fixes / Discuss-tier
- (none)

## Codex second-opinion

Status: claude-only. Pure helper modules (date math + string parsing, no wire-format
constant, no HMAC surface); a direct read of every branch is conclusive. Reviewed
for silent-pass and unhandled-input paths — none. Clean.
