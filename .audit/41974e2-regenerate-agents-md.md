# audit 41974e2 — Regenerate AGENTS.md after critical-rules sweep

verdict: clean
scope: `AGENTS.md` (generated artifact)
reviewers: Claude only — Codex second-opinion not dispatched (generated-file regen)

`AGENTS.md` is rendered from `CLAUDE.md` with every `@`-import inlined; it is what the
cross-family reviewers (codex/cursor/grok) actually read. Freshness is gated by `mix agents.check`
in `precommit.full`, and `sync-agents-md.sh --check` passes on the current tree — so this
regeneration is in sync and the gate would have caught it otherwise.

## Categories 1-6

No findings.
