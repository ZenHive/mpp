---
sha: 2c1ab0d30f4851e03b4bb5695becb37376a6bf91
short_sha: 2c1ab0d
audited_at: 2026-06-24
auditor_model: claude-opus-4-8
verdict: clean
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: Upgrade onchain stack to 0.10; delegate EVM RPC to Onchain.RPC

**Original commit:** 2c1ab0d — `Upgrade onchain stack to 0.10; delegate EVM RPC to Onchain.RPC`
**Author:** E.FU
**Files touched:** 8
**LOC:** ±420

## Findings

| # | Pri | Category | File:Line | Description | Resolution |
|---|-----|----------|-----------|-------------|------------|
| — | —   | —        | —         | No findings — clean dual-reviewer pass | — |

## Key-risk verification (output-shape contract)

The refactor deletes `evm.ex`'s hand-rolled `parse_receipt`/`parse_transaction`/`hex_to_integer`
layer and delegates to `Onchain.RPC.get_transaction_receipt/2` + `get_transaction_by_hash/2`.
The consumers `check_receipt_status/1` (`%{status: 1}`), `find_matching_transfer/2` (`%{logs: logs}`),
and `check_native_transfer/2` (`tx.to`, `tx.value` integer) now trust the dep's return shape
directly — exactly the wire-format / dep-shape concern CLAUDE.md flags.

Verified on two independent axes:

- **Test design exercises the contract end-to-end.** `evm_test.exs` stubs at the HTTP layer
  (`req_options: [plug: {Req.Test, EVM}]`) returning *raw* JSON-RPC JSON (string keys, hex
  values like `"status" => "0x1"`); Onchain.RPC's real decode path runs on that response before
  reaching the consumers. A wrong shape would fail the stubbed suite. Ran it: **31/31 green.**
- **Codex confirmed against the installed dep source.** Onchain.RPC 0.10
  `get_transaction_receipt/2` → `parse_receipt/1` returns atom keys incl. integer-decoded
  `:status` and `:logs` (`deps/onchain/lib/onchain/rpc.ex:1331/1342/1344`,
  hex decode via `helpers.ex:231`); `get_transaction_by_hash/2` → `parse_transaction_map/1`
  returns atom-keyed `:to` + integer `:value` (`helpers.ex:245/253/254`). Matches consumers exactly.

## Auto-applied fixes

- (none)

## Discuss-tier resolutions

- (none)

## Codex second-opinion

Status: dual-reviewer
Corroborated findings: none (both reviewers clean)
Codex-only findings (verified): —
Codex-only findings (discarded as over-flag): —
Codex key-risk verdict: Onchain.RPC 0.10 return shape matches evm.ex expectations; 31/31 stubbed suite passed.
