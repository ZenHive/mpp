---
name: sdk-delta-watch
description: >
  Run the MPP reference-SDK delta watch: detect upstream changes in mppx / mpp-rs /
  mpp-specs (especially security and wire-format fixes) that our Elixir implementation
  lacks, and track each finding under the repo's disclosure policy. Invoke when the user
  says "sdk-delta-watch", "check the SDKs", "watch upstream", "triage upstream deltas",
  or the session-start hook reminds that the watch is stale. Runs locally in an
  authenticated session, so the private-advisory disclosure path actually works.
---

# sdk-delta-watch (local, authenticated)

Detect upstream reference-SDK changes our Elixir impl lacks, and route each finding by
**type** under the repo's disclosure policy. This is the **local** replacement for the
retired cloud routine — you run it in *your* authenticated session, so you have
`gh` advisory-write scope and you see the output inline.

## 🚨 Disclosure policy — read and obey FIRST

`ZenHive/mpp` is a **PUBLIC** repo: `roadmap/tasks.toml`, `ROADMAP.md`, and everything
under `docs/` publish on push. An **unfixed, exploitable security gap must NEVER be
written to any committed/public file** — not a public `security` rmap task, not a public
ledger row, not a commit message. That hands attackers a checklist for a deployed money
library. The authority is `critical-rules.md` § "NEVER BROADCAST AN UNPATCHED
VULNERABILITY" and `CLAUDE.md` § "Security-parity ledger + disclosure convention" — read
both, plus `docs/security-parity.md` (the standing ledger), before routing anything.

## Steps

1. **Load state.** Read `.sdk-watch.json` at repo root — per ref (`mppx`, `mpp-rs`,
   `mpp-specs`) it holds `url`, `branch`, `last_seen` SHA, plus shared `critical_paths`
   (per ref) and `triage_keywords`. The `refs/` clones already exist and were pulled by
   the SessionStart hook; `git -C refs/<name> fetch --quiet` to be current.

2. **Diff since watermark.** For each ref:
   `git -C refs/<name> log <last_seen>..origin/<branch> --oneline -- <critical_paths...>`.
   Empty ⇒ that ref is clean, skip it.

3. **Judge parity per commit.** For each new commit on a critical path — prioritise any
   whose subject (or added `.changelog/` / `.changeset/` file) matches a `triage_keyword`
   — read its diff (`git -C refs/<name> show <sha>`), then read OUR code under `lib/mpp/`
   and tests under `test/mpp/` and decide: do we already implement/guard this, or is it a
   genuine gap? Record `refs/<name>/<path>:<line>` evidence. Per `CLAUDE.md` § Conventions,
   verify any wire-format constant against BOTH `refs/mpp-rs` and `refs/mppx` when they agree.

4. **Route each finding by TYPE** — never commit unfixed-security-gap detail to a public file:
   - **PARITY CONFIRMED** (we already guard it) → add a ✓ row to the confirmed-parity table
     in `docs/security-parity.md`, citing the upstream ref + our `lib/mpp/…:line`. Public-safe.
   - **GENUINE SECURITY GAP** (DoS / auth bypass / fund drain / replay / wire-format
     correctness / any exploitable hole) → **do NOT** file a public task or write detail to
     any committed file. You are authenticated, so file a **PRIVATE draft GitHub security
     advisory** yourself. **Dedupe first:**
     `gh api repos/ZenHive/mpp/security-advisories --jq '.[] | {ghsa: .ghsa_id, state, summary}'`
     — prefer updating an existing advisory over a near-duplicate. Then create the draft:
     ```bash
     gh api repos/ZenHive/mpp/security-advisories -X POST --input advisory.json
     ```
     where `advisory.json` has `summary`, `description` (upstream PR + `refs/…:line` + our
     `lib/mpp/…:line` + the fix to port + suggested severity), `severity`, and
     `vulnerabilities: [{"package": {"ecosystem": "erlang", "name": "mpp"},
     "vulnerable_version_range": "<= <current>", "vulnerable_functions": []}]`. Capture the
     returned GHSA id and report it inline. It stays **draft** (private) — publish only when
     the fix ships, with the patched release (coordinated disclosure). You MAY bump the
     generic open-item **count** in the "Open hardening items" section of
     `docs/security-parity.md`, but never the detail. If the gap is high-stakes or ambiguous,
     surface it to the user with the proposed advisory body and confirm before POSTing.
   - **GENUINE NON-SECURITY functional/parity gap** (no exploit value) → file normally:
     dedupe (`grep` `roadmap/tasks.toml`, `rmap list`; prefer updating an existing task's
     `acceptance_criteria`/`body` per the rmap dedupe rule), then `rmap new --from-stdin`
     with `assignee` + `model` if dispatchable, then `rmap validate && rmap render`.

5. **Advance the watermark.** Set each ref's `last_seen` to its current `origin/<branch>`
   HEAD and `checked_at` to today in `.sdk-watch.json`.

6. **Commit public-safe paths only**, each via explicit `git add <path>` (never `git add -A`):
   `.sdk-watch.json`, `docs/security-parity.md` (✓ rows / count bump only),
   `roadmap/tasks.toml` (non-security tasks only), and — only if you ran `rmap render` —
   `ROADMAP.md` + `roadmap/data.json`. **🚨 GATE:** before committing, run
   `git diff --cached` and confirm NO unfixed-security-gap mechanism is staged; if any is,
   unstage it and move it to the draft advisory. Message:
   `chore(sdk-watch): triage upstream deltas (<refs/PRs>)`. Push. If no ref had new commits,
   just update `checked_at` and commit `.sdk-watch.json` alone; if nothing public changed,
   skip the commit (private advisories are not commits). Respect any in-flight session on
   `tasks.toml` — re-read before mutating (rmap concurrent-write rule).

7. **Report inline.** Per ref: new commits seen; ✓ rows added; **security gaps and how each
   was tracked** (GHSA id created / updated); non-security tasks filed; whether `rmap render`
   ran. Surface clearly any security gap that needs a release to disclose.
