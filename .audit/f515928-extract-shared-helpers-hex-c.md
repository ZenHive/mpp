---
sha: f515928d9222bd9e49f35d54c56ad4a7a42bca6e
short_sha: f515928
audited_at: 2026-07-08
auditor_model: claude-fable-5
verdict: findings-applied
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: Extract shared helpers (Hex/Codec/Methods.Shared) and split MPP.Headers into MPP.AcceptPayment (Task 73, 0.10.0)

**Original commit:** f515928 — `Extract shared helpers (Hex/Codec/Methods.Shared) and split MPP.Headers into MPP.AcceptPayment (Task 73, 0.10.0)`
**Author:** E.FU
**Files touched:** 33
**LOC:** +977/−759
**PR:** none — direct push to development (repo convention: local dev + harness auto-land)

## Zero-behavior-change verification (the load-bearing claim)

- **Moved Accept-Payment code is byte-faithful.** Every private helper in `MPP.AcceptPayment` (parse/format/rank/apply pipeline, q-value parsing, specificity matching) matches the removed `MPP.Headers` code exactly, including guards, reduce_while control flow, and the `@max_token_len` DoS guard placement. Public names renamed per the documented API move; internal semantics unchanged.
- **`MPP.Headers.SchemeSplitter` is a byte-identical move** of `split_payment_challenges/1` + `find_boundaries` + `extract_scheme_token` + `payment_scheme_at?` (now `@moduledoc false` with public `split/1`).
- **`MPP.Methods.Shared.require_config/3` reproduces the exact previous error strings.** Old per-module copies interpolated "EVM/Tempo/Stripe method missing required config: #{key}"; callers pass the matching label ("EVM", "Tempo", "Stripe") at every site. `check_receipt_status/1` and `parse_charge_amount/1` bodies identical to all removed copies.
- **`MPP.Codec.decode_base64_json/1` error mapping identical** to the three inlined versions it replaced (`:error → :invalid_base64`, `%Jason.DecodeError{} → :invalid_json`, `from_map` errors pass through). Receipt/SessionReceipt `with`-else elimination is behavior-equivalent.
- **`MPP.Hex.strip_0x/1` / `hex_string?/1`** identical to the 5x/3x removed copies (incl. hosted_fee_payer's variant, same semantics). `rg 'defp strip_0x|defp hex_string\?' lib/` → zero remaining.
- **All internal callers migrated** (transport.ex, transport/http.ex, plug.ex); no stale `*accept_payment*` old-name references outside CHANGELOG/roadmap history.

## Acceptance criteria (Task 73)

- ✅ No duplicated `strip_0x` / `hex_string?` / decode-base64-json across the listed modules. Note: `verifier.ex:293` (`decode_credential_request/1`) and `mcp.ex:440` (`decode_request/1`) still decode base64url→JSON inline, but neither is the tagged-error clone the task targeted — verifier deliberately collapses all failures to `:request_mismatch`, MCP deliberately raises on corruption (documented). Different failure semantics, not duplication; ex_dna 0 clones confirms.
- ✅ Accept-Payment logic in its own module with its tests (`lib/mpp/accept_payment.ex` + `test/mpp/accept_payment_test.exs`, tests moved verbatim).
- ✅ Zero behavior change; full suite green; Dialyzer clean (995 tests per delivery record; hook-graded at commit).

## Findings (3-reasoner merge: Claude + Codex; no PR bots — direct push)

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| 1 | 5 | doc-gap (Claude + Codex, corroborated) | README.md:193 | Modules table missing new public `MPP.AcceptPayment` | applied: row added |
| 2 | 3 | doc-gap (Codex, verified — kernel of its pri-8 over-flag) | CHANGELOG.md:11 | "(no behavior change)" heading sits beside "Breaking (moved API)" paragraph | applied: "no runtime behavior change; the Accept-Payment API move below is the one breaking surface" |
| 3 | 3 | doc-gap (Claude) | SECURITY.md:11 | Unsupported row left at `< 0.9` after supported moved to 0.10.x, leaving 0.9.x ambiguous | applied: `< 0.10` |
| 4 | — | discuss-design (Codex) | lib/mpp/accept_payment.ex:34 | 16 KiB `@max_token_len` now defined in 3 modules (Headers, AcceptPayment, SessionReceipt) — centralize? | divergence reversible-picked: keep module-local (see below) |
| 5 | — | dropped (Codex over-flag) | lib/mpp/headers.ex:11 | "Public API removed/renamed breaks callers" rated pri 8 as a bug | dropped: deliberate, documented move with migration mapping in CHANGELOG; all internal callers migrated; pre-1.0. Doc kernel extracted as finding 2 |

## Auto-applied fixes

- `README.md`: `MPP.AcceptPayment` row added to Modules table (the three helper modules `MPP.Hex`/`MPP.Codec`/`MPP.Methods.Shared` are internal-by-intent per their moduledocs and deliberately not listed in the consumer-facing table)
- `CHANGELOG.md`: 0.10.0 refactor paragraph clarified to "no runtime behavior change" + pointer to the breaking-move paragraph
- `SECURITY.md`: unsupported-versions row `< 0.9` → `< 0.10`

All fixes LOW tier (doc drift) — mechanical verification stack via PostToolUse hooks.

## Discuss-tier resolutions

**Finding 4 — token-cap centralization (divergence, reversible, picked Claude's position: keep module-local constants).**

- *Codex position:* the 16 KiB cap is a security limit now repeated across `AcceptPayment`, `Headers`, and `SessionReceipt`; centralize to prevent drift.
- *Claude position (picked):* keep per-module `@max_token_len`. Evidence: both reference SDKs use module-local constants for this exact cap — `refs/mpp-rs/src/protocol/core/headers.rs:18` (`const MAX_TOKEN_LEN: usize = 16 * 1024;`, file-local) and `refs/mppx/src/Challenge.ts:10` (`maxRequestParameterLength`, module-local) — neither has a shared limits module. Each of our three sites carries a comment citing mpp-rs #299 and boundary tests pinning at-limit/over-limit behavior, so silent drift fails a test. The constant is used in guards (`when byte_size(token) > @max_token_len`), so a shared function can't be referenced directly; centralizing would need a compile-time attribute-from-function-call cross-module dep for 3 sites.
- No second dialogue round was dispatched: both positions were already explicit with rationale (Codex's in its finding, Claude's grounded in refs evidence Codex lacked), and the divergence is reversible — a future centralization is a mechanical follow-up if a fourth site appears.

## Codex second-opinion

Status: dual-reviewer (job task-mrbwv7w0-i4zk80, 3m16s, read-only session)
Corroborated findings: 1
Codex-only findings (verified): 2 (as wording kernel), 4 (resolved as discuss-design)
Codex-only findings (discarded as over-flag): 5 (deliberate documented API move rated as pri-8 bug)
