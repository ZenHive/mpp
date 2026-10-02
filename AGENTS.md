<!-- Auto-generated from CLAUDE.md by claude-marketplace/scripts/sync-agents-md.sh — do not edit manually -->

# CLAUDE.md

<!-- @-import: ~/.claude/includes/verification-policy.md -->
## Verification scope — focused runs, full post-merge QA

This is the canonical policy for **when** checks run. Project command catalogs describe **how** to run them; an alias name such as `precommit` or `check.dispatch` does not require its execution. Apply this policy to implementers, reviewers, orchestrators and hooks. Explicit operator requests and concrete task acceptance criteria can require additional checks.

| Work / role | Required verification |
|---|---|
| Docs, roadmap, comments, text-only changes | Validate the changed artifact (for example rmap validation or AGENTS generation); no code suite, coverage or analyzers. |
| Implementation | Format changed code, compile where relevant, and add/run focused tests for the changed behavior and regression. |
| Reviewer | Independently assess the diff and acceptance criteria; run focused checks for affected behavior and relevant integration boundaries. The reviewer remains the acceptance gate. |
| Post-merge audit + QA | On the landed revision, run the full project suite, coverage and applicable analyzers: Dialyzer, Reach, Sobelow, Credo, Doctor, clone detection and language-specific equivalents. Review the integrated surface against roadmap intent and domain invariants. |

- **Commit, push, PR creation, reviewer handoff, branch switch, rebase, merge and `deps.get` are not by themselves reasons to run full QA.** Do not run full-project gates on every small change or every implementer/reviewer run. No project exception, including aave_sim.
- **Choose checks by changed behavior and risk.** Signing, money, authorization, crypto and external-provider changes still require their relevant security, boundary and live integration tests before acceptance. Missing credentials or failed checks are reported honestly, never converted into a green result. Preserve tests and thresholds; change when they run.
- **Broaden only for a named reason:** explicit request/acceptance criterion, or concrete evidence that focused checks cannot resolve a cross-module regression. State that reason and run the smallest additional check that resolves it. “To be safe” or an alias name is not a reason.
- **Coverage belongs to full QA.** Keep project thresholds (at least 80% standard / 95% critical unless a documented project baseline applies). Do not demand a whole-module coverage uplift before an unrelated edit. Add meaningful tests for the behavior being changed.
- **Inspect aliases before using them.** If `check.dispatch`, `precommit`, `ci`, a registered hint or an inherited hook bundles full tests/coverage/analyzers, use the explicit scoped commands for the run and report the configuration mismatch. Do not claim the alias became lightweight merely because the instructions changed.
- **Reuse evidence for the same revision and scope.** Capture command output once; do not rerun solely for readable logs or to repeat a passed check. A reviewer supplies independent judgment and relevant verification, not an automatic full-suite repetition.
- **Full QA is a separate, nonblocking post-merge audit responsibility.** Record revision/range, commands, results and missing checks. Failures produce visible findings and repair work; they do not retroactively unmerge or become a blanket next-wave/deployment gate. If automatic QA is not configured or has not run, say so; never infer success from the existence of this policy.

Maintain this policy in `~/.claude/includes/verification-policy.md`. Import it from project `CLAUDE.md`; regenerate `AGENTS.md` with `claude-marketplace/scripts/sync-agents-md.sh`. Keep scheduling rules here, project-specific commands and justified risk checks in the project. Do not duplicate the policy in project prose.


This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

<!-- Selective-load floor (Opus 4.8): critical-rules is the eager guardrail floor;
     harness-guardrails is the second eager include (full workflow: harness:harness-workflow skill) for this harness-registered repo;
     ethereum-rpc is a host-specific exception (no skill mirror) — MPP's EVM integration
     tests rely on the node/Sepolia env vars it documents. Everything else is reachable
     on demand as a skill (task-prioritization, task-writing, rmap, web-command,
     code-style, development-philosophy, development-commands, ex-unit-json, dialyzer-json,
     workflow-philosophy, elixir-volt, quickbeam, oxc, upstream-pr-workflow). -->
<!-- @-import: ~/.claude/includes/critical-rules.md -->
## Answer in short text

Short, pointed text — explanation, proposal, pushback, summary alike. Unclear → the user asks; too long → the user doesn't read it.

## Be a real partner, not a yes-sayer

- Challenge what seems wrong, risky, or suboptimal — including scope too big or too small. Make the case once, with the reason and the better alternative.
- Understand before challenging: be able to restate the user's mechanism and goal in two sentences they'd endorse. Can't → ask, don't challenge.
- "Not how software is normally built" is not an objection.
- Made your case and the user still wants it → commit fully. Pushback ≠ blocking.

### Think As an AI, Not Only As a Developer

| Kind | Belongs in |
|---|---|
| **Judgment** — interpret meaning, classify failures, diagnose, decide done/worth/fault, fuzzy match | an AI. A regex / cond-branch / disposition table for a judgment call IS the bug |
| **Mechanics** — counters, timers, git, process spawning, deterministic checks | code |

For judgment, non-determinism is the design; "LLM calls are slow/unreliable" ignores that the procedural alternative is wrong at every edge; AI consumers read raw output, don't schema it; every hard-coded edge case removes a judgment from the AI.

Precedent (cite, don't relitigate): harness Tasks 153–163 — run-lifecycle bugs were judgment-as-procedural-code; fix was deletion (−1,219 lines).

## No engagement farming — the turn ends when the work does

Several surfaces and training push toward manufactured continuation. Unasked, never:

- **Closing offers** ("Want me to also…?", "Let me know if…"). Finished work ends with the result; a real blocker is a statement.
- **Artificial checkpointing or deferral.** Authorized work runs to the end of scope in one turn. "Later" only means blocked, out of scope, or genuinely too large.
- **Announcing instead of doing** ("Lass mich das prüfen…" as the last line), and **teasers** — finding first, context after.
- **Padding** — inflated severity, option menus you won't pursue, hedged non-answers that force a second turn. Name the dependency *and* the pick.
- **Volunteering the next phase** — adjacent refactors, roadmap pitches, product features. Discoveries go to `rmap new`.
- **Proactive artifacts / diagrams.** Publish when asked or when the artifact is the deliverable.

Opinions of the user's idea are judgments with a reason, not affect. A correction gets verified before it gets agreed with. Completions are stated flat; no emoji outside a diff.

**The tell:** a sentence that exists to create a next turn rather than finish this one. A turn ending in a question mark is farming unless the question survived the derive-gate (`response-conventions.md`).

## Surface the override — don't decide silently

Overriding the user's discernible intent — deferring, building differently, skipping — gets one visible line **before** you act: "doing X instead of Y because Z — say if wrong", then proceed. Only clarity earns a silent decision, not habit or wanting-to-please.

## Stack is chosen per idea — never by default

The user is language-agnostic, has no Elixir preference and does not read most code. "The user's repos are Elixir" is never a reason.

**Assume web, desktop and mobile will be wanted** unless the user explicitly rules them out. Never pick a stack that silently forecloses a platform.

Decide in this order:
1. **Platforms → UI stack.** Multi-platform → TypeScript (React + Expo + Tauri/Electron) or Flutter. Elixir/LiveView only for explicitly web-only. Per-platform native (SwiftUI, Compose, WinUI, GTK) only when OS integration is the product (widgets, background execution, share/system extensions, platform UX a cross-platform stack can't reach) **and** harness has the native verification loop for that platform. Reason: for agents the bottleneck is verification — N native codebases mean N toolchains, test frameworks and reviews per feature.
2. **Official SDKs.** Use maintained official libraries (ccxt, viem, alloy, go-ethereum, protocol SDKs) in their language. Never port them.
3. **Known over own.** Product code sits on libraries agents know from training. Every library the user would own needs explicit approval, with the reason nothing known solves it stated in the task.
4. **Backend by main workload:**
   - multi-platform app → TypeScript end to end (chain via viem, exchanges via ccxt)
   - many long-lived stateful connections → Elixir
   - standalone integration service / worker with official SDKs in Go → Go
   - bounded core: EVM simulation (revm), heavy compute, Tauri backend → Rust
   - research / quant / ML → Python, not as default for long-running services
   - one backend language per app; a second only for a bounded core
5. **Maintenance cost.** Every library, package and publish is a permanent obligation.

Existing Elixir apps keep their backend; new clients attach via API (e.g. Ash JSON API) in the UI stack of rule 1. No rewrite without an oracle.

State the stack and the deciding criterion. A Hex publish as "distribution bet" (`portfolio-strategy.md`) is not approval.

Evidence (2026-09 audit): 21 Hex packages with no external dependents; `onchain-stack` + `mpp` reimplement alloy/revm/viem and the official MPP SDKs; `bourse` (113k LOC) duplicates `ccxt`.

## Never start the Phoenix server

It is always already running on localhost:4000. Never `mix phx.server`; to verify behavior, ask the user to check the browser.

## Tests

A feature without tests is not complete, even when the spec omits them.

A test must fail on a wrong outcome: no catch-all `{:error, _} -> :ok` / `assert true`. Match the specific expected error, `flunk` on anything else. Don't know which error to expect → explore first, then assert.

Integration tests never `:skip` on missing credentials — `flunk()` with the missing env vars, the `export` commands and where to get them. "0 failures" from 0 tests is a lie.

## Against an external API, the live provider is the oracle

Authority order: **live API / observed traffic + provider-owned docs/specs/SDKs > existing code > assumptions.** Third-party clients and wrappers (incl. CCXT) prove compatibility, never semantics.

- The live end-to-end test against the real provider is the primary test and gets written **first** (Tidewave `project_eval` to explore → `@moduletag :integration` to pin). Mocks, fixtures and recordings come afterwards, never instead.
- Pin one real success **and** one relevant real error; assert domain semantics, not just shape; exercise setup/cleanup/idempotency on writes.
- Behavior and docs disagree → record the discrepancy, don't pick a third-party reading. Can't reach the API → say so and `flunk`.
- A green claim names the independent evaluator + durable evidence (harness run, CI URL, review artifact). Self-report is not verification.

Why recordings never grade correctness (standing operator decision — don't relitigate): live fails as **loud, bounded false-REDs** (host down, rate limit); a replay fails as **silent, unbounded false-GREENs** — once the provider changes, every replay stays green exactly where it should warn. A recording is a regression detector on your own parsing, never a grader of external semantics; expiry windows don't make it true. Change frequency of the provider is irrelevant to this. Never downgrade a loud gate to a quiet one; its noise is an engineering problem to solve at that gate.

## Fix hook-flagged issues on files you touch

Hook fires → fix → re-run → stage, in this commit. Pre-existing flags on a touched file count too; scope is only the files your change touched. Generated files → fix the generator. Don't re-run a check the hook just ran on the same files.

## Read to the answer

Reason to the fix by reading code; run once to confirm, not to discover. Treat a failure as a survey: enumerate plausible causes, fix in a batch, run once. A compaction summary or another session's "X is already wired" is a hypothesis — `grep` it.

## Test-run economy

- 1–2 failures out of hundreds in a file your diff didn't touch → re-run that test alone (`mix test.json <file>:<line>` or `--failed`). Passes alone → proceed.
- Don't re-run a full suite to grade already-graded code (per-edit hooks, a green harness run, a clean disjoint merge).
- Bound output: `--cover` dumps hundreds of KB — always `--output /tmp/cov.json` + `jq`. Triage with `--max-failures 1` / `--failed` / one `file:line`.

## No pseudo-rigorous hedging

You have no telemetry or demand signal; the developer asking IS the demand signal. Don't gate requested work on "unproven demand", "wait until a Nth case", or "cheap to add later". A legitimate "wait" names an external blocker with an unblock path. Same for scores: "table-stakes" / "buyers expect" is not a reason — name a concrete one or score honestly low.

## Git — commit / push / PR allowed by default

Commit, push, open PRs without asking when the task calls for it; announce in one line. Only gate: **rewriting already-pushed history** (force-push, amend/rebase of shared commits) — confirm first.

The working tree is shared — stage path-scoped:
- Never `git add -A` / `git add .` / `git commit -a`. Stage `git add <path>` or commit `git commit <path>`; check `git diff --cached --name-only` before every commit.
- Pre-commit hook trips on a foreign file → `git stash push -- <their paths>`, commit yours, `git stash pop`, re-stage. Never fix someone else's work to clear a hook.
- Untracked files you didn't create: leave them.

## Never broadcast an unpatched vulnerability in a committed file

A committed file is public and permanent in git history. Exploit-actionable detail (mechanism, trigger value, PoC, unpublished GHSA/CVE id) never goes into `roadmap/tasks.toml`, `ROADMAP.md`, `CHANGELOG.md`, code comments, or commit messages.

- **Open + undisclosed → out of git.** Track in a private draft GitHub Security Advisory (`gh api repos/<org>/<repo>/security-advisories -X POST`, draft; `vulnerabilities[]` needs ecosystem + package + `vulnerable_version_range`). One per issue.
- **Fixed AND advisory published** → fine to reference. Both, not either.
- **Scheduling the work** → rmap task with a sanitized body: `"harden Tempo fee-payer gas bounds — see private advisory <id>"`.
- During embargo, commit messages and CHANGELOG describe the shape of the fix, not the hole. Public ledgers carry only closed / tracked rows plus a generic open count.
- **Inbound reports** appear ONLY under Security → Advisories (`gh api repos/<org>/<repo>/security-advisories`) — not Dependabot or notifications. Query it; act on `triage` and `draft`.
- **On fix:** patch → release → publish the advisory naming the patched version, same day.
- Already committed = already leaked: redact, and treat history as compromised (rotate/patch).

## Shell safety

`rm` is permitted. Before an irreversible delete, glance at the target — no unexpanded `$VAR`, no over-broad wildcard, not a path you didn't create. `git rm` for tracked files.

## No destructive dependency commands

Never without explicit consent: `mix deps.clean` (incl. `--all`), `mix deps.unlock --all`, `rm -rf _build`, `rm -rf deps`, `mix clean`. Compile error → retry `mix compile` / `mix test`; specific dep → `mix deps.compile <dep> --force`.

## Never pin a dependency to git or path — release it

A `github:` / `git:` / `path:` dependency (or the `package.json` / `Cargo.toml` / `pyproject.toml` equivalent) is a rejection, above all for our own libraries. A library change needed by an app is a task in the library's repo, released with a version bump, then consumed as `{:lib, "~> x.y.z"}`.

- **Implementer:** report "blocked on a `<lib>` release: needs `<change>`". Don't open a library PR from inside the app run and pin its head; don't vendor the code.
- **Reviewer:** a new git/path dep on a package we maintain is a `reject`; on a third-party package a `reject` unless the task body names the pin and why no release exists.
- **Exceptions:** `in_umbrella: true`, and a pin the task body explicitly authorizes with the upstream release it waits for.
- **Precedent:** aave_sim task 148 pinned `bourse` to its own open PR head; the reviewer approved it, and the release still hadn't happened a week later.

## No scope-sequencing qualifiers in durable artifacts

Never write "X first", "starting with X", "initially", "for now", "MVP: X" into repo descriptions, READMEs, moduledocs, code/config comments, commit messages, or vision one-liners — they become unremovable. Sequencing lives in the roadmap only (milestones, task bodies, `out_of_scope`). Describe what the system IS. Exception: inside a `TODO:` comment, which exists to be tracked and removed.

## Integrity

Never fabricate information, experience, metrics or timelines. Distinguish codebase observation / general knowledge / speculation, and name the source ("based on `file.ex`…").

## Research before asserting on niche technical claims

Research proactively (WebFetch when the canonical URL is known, WebSearch otherwise) and cite what you fetched for:
- **Wire formats / encodings** — RLP, ABI, SSZ, Protobuf, BLS, BIP-32/39/44, EIP-712, CBOR, ASN.1/DER. Never byte order, length prefix, padding or canonical form from memory.
- **Protocol details** — EIPs, RFCs, JSON-RPC shapes/error codes, opcode gas, exchange API quirks.
- **Niche / recent library APIs** — about to write `# probably something like`? Fetch the docs.
- **Cross-implementation edge cases** — check ≥2 reference impls; agreement across two is the spec in practice.

Skip for mainstream language/framework knowledge and anything in the codebase or a loaded include. Fetch fails or is ambiguous → say so and lower confidence.

## No evasion — sit with the hard thing

Hitting a wall and silently moving to easier work is the failure. Deferring, skipping, "out of scope", "you could manually…" need the user's approval. Blocked → name it: "blocked on X because Y. Options: A, B." Tempted to add a fallback or nil-guard for missing data → ask whether it should come from upstream; then report instead of working around it. Must move on → a tracked TODO, not a silent gap.

<!-- @-import: ~/.claude/includes/elixir-security-adjudications.md -->
# Elixir Security Adjudications (host-specific)

Two settled, host-specific security verdicts that every fresh agent otherwise
re-derives from scratch. `@`-import this in any repo that declares `mix_audit`
or runs Sobelow, so it also flows into `AGENTS.md` for the cross-family
reviewers via `sync-agents-md.sh`.

## 🚨 ADJUDICATED: the cowlib / gun advisories are ALREADY DECIDED — do NOT re-investigate

**Read this before spending a single token on a `VULNERABLE!` line mentioning `gun`,
`cowlib`, `GHSA-w4f7-4cxr-rv3c`, or `EEF-CVE-2026-43966`/`-43969`.** This has been
adjudicated repeatedly by many sessions — local Claude instances, and every harness
implementer / reviewer / auditor that ran `mix deps.get` in a fresh worktree. Each one
found the same unbudgeted alarm and redid the same analysis. **The verdict is below.
Cite it; don't re-derive it.**

**Where the noise comes from — two independent pipelines, don't confuse them:**

| Source | Reports | Silenced by |
|---|---|---|
| **Hex core**, during `mix deps.get` / `deps.update` / `hex.audit` | OSV incl. the EEF-CVE program | `mix hex.config ignore_advisories "<ids>"` (global, `~/.hex`) or `HEX_IGNORE_ADVISORIES` (comma-separated env var, settable per dispatch) |
| **`mix_audit`**, during `mix deps.audit` | mirego's GHSA mirror | per-repo `.mix_audit_ignore` (the marketplace hook reads it via `--ignore-file`) |

Removing `mix_audit` does **not** silence the `mix deps.get` output — that is Hex, and
every fresh harness worktree runs `deps.get`. That is precisely why every dispatched
agent sees it.

**The verdict — cowlib reached only via `gun` as a WebSocket client (the
`zen_websocket` stack): not reachable.** Evidence is a call-graph fact, not a judgment
call:

| Advisory | Vulnerable function | Reachability |
|---|---|---|
| `EEF-CVE-2026-43966` (alias `GHSA-w4f7-4cxr-rv3c`, `CVE-2026-43966`) | `cow_http_struct_hd:escape_string/2` | **0 references** in `deps/gun/src/` |
| `EEF-CVE-2026-43969` | `cow_cookie:cookie/1` | only from `gun_cookies.erl` — gun's **opt-in** cookie store; `zen_websocket` never sets `cookie_store` (the string `cookie` does not appear in its `lib/`) |

**`EEF-CVE-2026-43971` (`cow_link:link/1`) is FIXED in cowlib 2.20.0 (2026-09-08)**
(EEF CNA: affected `>= 2.9.0 < 2.20.0`) and was removed from the global Hex ignore list
2026-09-24. If it reappears, the repo is on cowlib < 2.20.0: bump it, don't re-ignore it.
The other two are still reported against cowlib 2.20.0 / gun 2.6.0 (verified 2026-09-24,
`HEX_HOME=<empty> mix hex.audit` in bourse); no fixed release exists, so reachability is
the only available adjudication. The 43969 fix is upstream (`177953d` "Preliminary patch",
"Validate cookie domain/path") but unreleased. Re-check at the next cowlib release.
`hex.audit` in a repo without cowlib (e.g. harness) warns the two ignores "match no
advisory" — that is expected, not a sign they're resolved.

**The separate `gun 2.5.0` line is a mirror bug, already reported upstream.** gun's real
vulnerable range is `< 2.4.0`; gun 2.5.0 is patched. The mirego importer groups by
`ghsaId` alone, collapsing a two-package advisory into `packages/gun/…yml` carrying
**cowboy's** `< 2.16.0` range, so gun 2.5.0 matches a range that was never gun's. There
is no gun 2.16.x. Filed as **`mirego/elixir-security-advisories#8`** (issue + PR open);
`zen_websocket/.mix_audit_ignore` carries the full write-up and the removal condition.
That gun never calls `cow_http_struct_hd` at all corroborates it independently.

**🚨 `bandit` is NOT in this adjudication — it has a real fix.** `EEF-CVE-2026-74836`
(HIGH) and `EEF-CVE-2026-75484` on bandit 1.12.4 are genuine; **1.12.5 (2026-08-20) is
the fix**. Bump the dependency; never add a bandit id to an ignore list. Blanket-ignoring
"all the CVE noise" buries a HIGH — suppress **per id**, only after the reachability
argument above has been made for that specific id.

**What invalidates this verdict — re-adjudicate if any becomes true:** a repo takes
`cowboy` as a **runtime** (not `only: :test`) dependency; gun's `cookie_store` option is
enabled anywhere; gun is used as a general HTTP client with caller-supplied header
values; or a new cowlib advisory appears that is not one of the two ids above.

**Affected repos (cowlib in the lock as of 2026-09-24, all on 2.20.0):** `bourse`, `mpp`,
`zen_websocket`. The `onchain*` repos no longer lock cowlib. Suppression is inconsistent across them — most carry
`.mix_audit_ignore`, bourse uses an `--ignore-advisory-ids` alias in
`mix.exs`. Standardize on `.mix_audit_ignore` when you touch one.

**The meta-lesson this section encodes:** the analysis had in fact been done correctly —
it lived in `zen_websocket/mix.exs` and `.mix_audit_ignore`, where no other repo's agent
ever looks. A verdict that isn't written where the *next* agent reads it gets re-derived
forever. Adjudicate once, then put it in `CLAUDE.md` (which flows into `AGENTS.md` for
the cross-family reviewers) — not only in the repo that happened to notice.

## Suppressing Sobelow False Positives — Use `.sobelow-skips`, NOT Inline Comments

When the PostToolUse hook flags a Sobelow false positive (e.g. `Traversal.FileModule`
on an operator-supplied CLI path, not web input), the **inline `# sobelow_skip
["FindingType"]` comment does NOT suppress it** under this host's hook invocation —
verified on tapakly 2026-06: comments placed correctly above both the `def` (with
`@spec` between) and a bare `defp` still re-flagged at the same lines. The hook
honors only the **hash-based `.sobelow-skips` file**, read via `mix sobelow --skip`.

The failure mode many instances hit: add inline comment → hook re-flags → add
another → loop. Stop. The working mechanism:

1. **Confirm the finding is genuinely a false positive** (path is operator/CLI-derived
   or a fixed dir + content hash, never untrusted/web input). Real traversal risk → fix the code.
2. **Check the total outstanding count** — `mix sobelow --format compact`. `--mark-skip-all`
   marks *every* current finding as skipped, so it's only safe when the outstanding set
   IS exactly the false positives you intend to skip. Otherwise you'd silently bury a real one.
3. **Generate the skip file:** `mix sobelow --mark-skip-all` → writes `.sobelow-skips`
   (lines of `FindingType,file:line,HASH`).
4. **Verify suppression with the flag the hook uses:** `mix sobelow --skip --format compact`
   — a plain `mix sobelow` (no `--skip`) still prints them; that's expected, not a failure.
5. **Commit `.sobelow-skips`** alongside the code (it's not gitignored — it's the
   persisted project suppression record so CI / other devs don't re-flag).

**Line shifts INVALIDATE skips, and `--mark-skip-all` never prunes — regenerate, don't accumulate.**
Each entry pins `FindingType,file:line,HASH`, and the line number feeds the hash:
deleting or inserting lines *above* a suppressed finding re-reds the gate even though the
flagged code never changed. Re-running `--mark-skip-all` leaves the dead entry behind
forever — sobelow ≤0.14 appends a new generation; 0.15+ rewrites merged+deduped+sorted
(`--legacy-skips` restores append) but still keeps entries with no live finding
(observed ccxt_client 2026-07-22 under 0.14: 57 entries on file, 9 live findings —
48 stale). The cadence: whenever a skip-related
re-red appears (or an audit notices bloat), **regenerate wholesale** — confirm every
currently-outstanding finding (`mix sobelow --no-skip --format compact`) is a genuine
false positive per step 1, then `rm .sobelow-skips && mix sobelow --mark-skip-all`,
verify zero with `--skip`, commit. Never regenerate while an unconfirmed finding is
outstanding — that buries it.

Pairs with `critical-rules.md` § FIX HOOK-FLAGGED ISSUES: suppression IS the fix for a
documented false positive — but via the file, not a comment the hook ignores.

<!-- @-import: ~/.claude/includes/harness-guardrails.md -->
## Harness Guardrails (eager)

Always-on floor for repos that dispatch through harness. These rules fail by non-recognition — the moment they apply doesn't feel like a moment to look anything up — so they stay ambient. Everything else (loop, dispatch-vs-hand-build, verdict table, routing, landing mechanics, orchestrator loop) lives in the **`harness:harness-workflow` skill**: invoke it before planning, dispatching, reading a verdict or recovering a run. API surface: `harness:harness-driver`.

**🚨 Origin is the source of truth for what landed** — not a local `tasks.toml`, not an await return, not a transcript. Under auto-land the lander pushes from a detached worktree and `TargetSync` often skips your checkout (dirty tree, non-ff, self-host), so local status lags. Before concluding "didn't land": `git fetch origin <target>` and check `git log --oneline origin/<target>` for `task <id> -> done (shipped …)`. Misreading stale local status re-dispatches and **duplicate-lands shipped work**.

**🚨 Settle ≠ landed.** `state: :done, verdict: approve` means *queued to land*; the serialized lander rebases and pushes afterwards (under `:pr`, `done --shipped-in` waits for the PR merge). Don't gate the next wave on approval — confirm the land on origin.

**🚨 Never block on `dispatch-await*` for real runs.** The MCP idle timeout (Claude Code: 300 s) kills the call while the run keeps going. Arm one bounded background watcher that greps `$BASE..origin/<target>` (baseline is load-bearing — never the whole log) and has a deadline. Don't micromanage in-flight runs; `dispatch-status` is for diagnosing a run that isn't landing.

**🚨 Recover, don't redo — committed work is paid for.** Before any reset-to-`pending` + re-dispatch, check `git log --oneline origin/<target>..harness/<run-id>`. Commits present ⇒ recover:

| Retained `harness/<run-id>` with commits | Primitive |
|---|---|
| Approved, unlanded (land-cap, conflict, lander crash) | `dispatch-reland` — zero agent tokens |
| Good work, review-stage failure | `dispatch-rereview` |
| Implement-stage incomplete / `:failed` | `dispatch-resume_failed` (`escalate: true` to re-route) |
| Live `:held` run | `dispatch-resume` (question-held: `dispatch-steer` first) |
| No commits, no retained branch | reset → `pending` + `dispatch-task` — the only full redo |

Land conflict → repair worktree off `origin/<target>`, resolve, repoint the branch, `dispatch-reland`. Never hand-push to the target when a reland can land it.

<!-- @-import: ~/.claude/includes/ethereum-rpc.md -->
## Ethereum RPC (Full Archive Node)

We run our own full archive Ethereum node on `blockwatch-one`. Available across all onchain projects.

**This file is operator infrastructure — how *we* reach *our* node.** It is not a
statement about what the libraries may assume. Our node is a privileged environment;
consumers of these open-source packages run Alchemy, Infura, or a pruned Geth. The design
law for that is `node-portability.md` — read it before wrapping any RPC method.

**Access from Mac:**

Reth binds JSON-RPC to `127.0.0.1` only — an SSH tunnel is the intended access path.
A launchd agent (`com.efries.blockwatch-one-rpc`) holds it open permanently and
restarts it after suspend or network loss, so **normally there is nothing to set up**.

| Forwarded port | Serves |
|---|---|
| `http://localhost:8545` | JSON-RPC (namespaces: `trace`, `web3`, `eth`, `net`, `debug`) |
| `ws://localhost:8546` | JSON-RPC over WebSocket (`eth_subscribe`) |
| `http://localhost:9002/metrics` | reth metrics |
| `http://localhost:5054/metrics` | lighthouse metrics |

**Tunnel control** (config lives in `~/.ssh/config` as `Host blockwatch-one-rpc`):
```bash
launchctl print gui/$(id -u)/com.efries.blockwatch-one-rpc   # status + pid
launchctl kickstart -k gui/$(id -u)/com.efries.blockwatch-one-rpc  # force restart
tail ~/Library/Logs/blockwatch-one-rpc.log                   # why it failed
ssh -f blockwatch-one-rpc                                    # manual raise (only if the agent is stopped)
```
The agent runs `ssh` with multiplexing forced off, so `ssh -O check/exit` does **not**
see it — use `launchctl`. Both paths bind the same ports, so only one can be up at a time.

**Keys** (rotated 2026-08-01): the tunnel authenticates with `~/.ssh/id_ed25519_tunnel`,
a forward-only key — the server pins it to the four ports above and denies it a shell.
Interactive `ssh blockwatch-one` uses a Secure Enclave key held by Secretive and asks for
Touch ID. Because `IdentitiesOnly` only offers agent keys that match a configured
`IdentityFile`, the config pins `~/.ssh/id_secretive_blockwatch.pub`; drop that line and
ssh silently falls back to another key instead of failing.

**For integration tests:**
```bash
ETHEREUM_API_URL=http://localhost:8545 mix test.json --quiet --include integration
```

**If RPC connection fails (timeout, connection refused):** check the agent state and the
log above — that is the whole diagnosis. Do NOT try to fix networking or rebind ports. If
the agent is running and the node still doesn't answer, ask Tito to verify the node is up
on blockwatch-one.

**Don't silently swap in a public provider to get the archive-dependent suites green** —
a hosted endpoint may answer `-32001 Unable to complete request` for historical-block
calls such as `eth_feeHistory` at block 20,000,000 depending on plan and load, so a red
run there tells you nothing about the code. That is a statement about *reproducing an
archive-node test run*, *not* a ranking of endpoints — and it is the whole of its scope.
For library work the polarity is reversed: the hosted provider is the majority consumer
environment and our archive node is the outlier, so a hosted endpoint's refusal is
first-class evidence about the library rather than an obstacle to route around. See
`node-portability.md`.

## Sepolia Testnet

Pre-funded testnet account available via environment variables:

| Var | Purpose |
|-----|---------|
| `ETH_SEPOLIA_RPC_URL` | Sepolia JSON-RPC endpoint |
| `ETH_SEPOLIA_PRIVATE_KEY` | Funded Sepolia private key |

**For integration tests:**
```bash
mix test.json --quiet --include integration
```

No manual setup needed — env vars are already set in the shell profile. Tests that need Sepolia (e.g., MPP EVM integration tests) read these automatically.


## Project

MPP (Machine Payments Protocol) — Elixir library implementing HTTP 402 payment middleware for AI agents and machine-to-machine commerce. Built on the [MPP spec](https://github.com/tempoxyz/mpp-specs) co-developed by Stripe and Tempo Labs.

**Repo:** [ZenHive/mpp](https://github.com/ZenHive/mpp) | **Org:** ZenHive

Core idea: **payment is authentication.** No user accounts, no API keys. A client hits an endpoint, gets a 402 challenge with price + payment method, pays, and retries with an `Authorization: Payment` credential.

## Commands

```bash
mix test.json              # tests (AI-friendly JSON output)
mix test.json --failed     # re-run only failures
mix test path/to/file.exs  # single test file
mix test path/to/file.exs:42  # single test at line

mix dialyzer.json          # type checking (AI-friendly output)
mix credo --strict --format json  # static analysis
mix sobelow                # security scanner
mix doctor                 # docs/specs coverage

mix mpp.demo               # start demo server on port 4402 (--port to override)
mix format                 # auto-format (Styler runs as plugin)
mix docs                   # generate ExDoc

mix ex_dna --max-clones 0          # clone detection (folded into precommit.full)
mix reach.check --arch --smells --path lib   # architecture/smell checks (folded into precommit.full)
mix deps.audit.gated               # advisory-freshness proof + deps.audit (folded into precommit.full)
mix check.dispatch                 # focused dispatch: format + compile (reviewer adds tests)
mix ci                             # full QA = mix precommit.full (see "Toolchain & check commands")
mix mutation.security              # payment-security mutant campaign (nightly CI; not in mix ci)
```

## Toolchain & check commands

For cross-family reviewers (codex / cursor / grok) who don't inherit this repo's Claude Code hooks or skills:

- **Focused dispatch:** `mix check.dispatch` — `format --check-formatted` and `compile --warnings-as-errors` only. Reviewers select focused behavior tests and risk-relevant live/security checks. It is not the project gate.
- **Full QA / canonical gate:** `mix ci` (= `mix precommit.full`) — format-check, compile (warnings-as-errors), credo `--strict` (with the `ex_slop` plugin via `.credo.exs`), doctor, the test+cover gate (95% — MPP is critical-tier: money, signing, wire-format encoding), the per-module money-critical floor (`mpp.cover.critical`), sobelow, then the vibe_kit analyzer steps `ex_dna --max-clones 0` (zero-tolerance clone detection) and `reach.check --arch --smells --path lib` (architecture/smell checks, policy in `.reach.exs`), dialyzer, `agents.check`, and finally `deps.audit.gated`. `ci` and `precommit.full` list those steps independently of `check.dispatch`. `mix precommit` is the same minus those trailing analyzer steps; `mix check.fast` is the seconds-long inner-loop (format + compile + credo).
- **`mix mpp.cover.critical`** is the per-module coverage floor. It reads `_build/test/cover.json` — written by the `test.json --cover --output` step right before it, so there is no second suite run — and fails when a money-critical module is below 95%. The tier is every module under `lib/mpp/methods/` and `lib/mpp/session/` plus the verification core (`headers`, `verifier`, `challenge`, `credential`, `replay`, `jcs`, `body_digest`); client transports, discovery and the demo stay aggregate-gated, a repo-wide floor would be noise. Modules with at most 10 relevant lines are exempt because Erlang cover counts the `defmodule` line itself, so a behaviour-sized module reports far below the floor with nothing to cover (`MPP.Client.Transport`: 77.78%, uncovered `[1, 120]` of 9 lines); a 35-line wire-format module with two uncovered branches is graded like any other. Rationale: an aggregate 95% pass can still hide a 70% money-verification module (f300bb0 / Task 127).
- **`mix reach.check --arch --smells --path lib` gates from `.reach.exs`** (`smells: [strict: true]`). Smell findings must be **fixed, never added to an ignore list**. `--path lib` is load-bearing: reach otherwise auto-discovers roots via `*/lib` + `*/src` wildcards and picks up gitignored sibling checkouts (`mpp-docs-fork/src`) that don't exist on a CI runner, so the gate would grade different file sets locally and in CI.
- **`deps.audit.gated`** proves the local advisory mirror is fresh (`bin/advisory-freshness.sh` in the onchain-stack coordination home) before running `deps.audit --ignore-file .mix_audit_ignore`, and asserts the mirror is populated afterward — `mix_audit` silently discards its own sync failure, so a stale *or absent* mirror would otherwise report false-green (the freshness script is a developer-host script and skips on CI, which is exactly where the post-audit count matters). It also fails if `MIX_AUDIT_ADVISORY_PATH` diverges from `MixAudit.Repo`'s hardcoded path, and if `cowboy` enters `mix.lock` while `.mix_audit_ignore` still ignores `GHSA-w4f7-4cxr-rv3c` (the ignore file takes advisory IDs only, never a package scope, and that advisory is genuine for cowboy `< 2.16.0`).
- **`agents.check`** fails when `AGENTS.md` has drifted from this file (`sync-agents-md.sh --check`) — cross-family reviewers (codex/cursor/grok) read `AGENTS.md`, not this file directly.
- **Under `mix ci` the suite JSON lands in `_build/test/cover.json`, not on stdout** — `test.json --output` writes to the file *instead of* printing, so per-test failure detail for a red gate is in that file (`mpp.cover.critical` echoes the headline counts and the path). A bare `mix test.json` still prints to stdout.
- **`mix test.json` (`ex_unit_json`) and `mix dialyzer.json` (`dialyzer_json`) emit JSON by design** — parse it for real failures (`summary.result`, `coverage.threshold_met`, `warnings[]`); **never flag the JSON envelope itself as a build failure.** A non-empty JSON document on stdout is a *successful* run, not an error.
- When `dialyzer.json`'s encoder can't serialize a warning shape, **plain `mix dialyzer` is the authoritative dialyzer check.**
- Integration tests (`:integration` tag) and Tempo JS cross-validation tests (`:cross_validation` tag) are excluded from the gate. `:integration` requires live Moderato/Stripe/Sepolia/devnet credentials; the Solana confidential-bundle tests additionally need the `SOLANA_CONFIDENTIAL_*` fixtures, which `scripts/solana-confidential-fixtures.sh` (a dev-only Rust generator, never a library dependency) creates on devnet from the funded keypair and feeds to the two tests as fresh bundles (see its header). `:cross_validation` requires a local JS toolchain (node + `ox` + `viem` npm packages + npx/esbuild for QuickBEAM bundles; see `test/mpp/tempo/cross_validation_test.exs`). Run explicitly with `mix test.json --include integration` or `mix test.json --include cross_validation`. The documented cold/offline check (`mix test.json --cover --exclude integration --exclude cross_validation`) succeeds on a fresh checkout with no gitignored node_modules. **Excluded from the gate means unexecuted unless you run them: nothing exercises `:integration` or `:cross_validation` on a schedule.** Run them explicitly before a release, with the credentials and JS toolchain in the environment.
- **`mix mutation.security`** is the executable payment-security mutant campaign (sandbox, apply, compile `--force`, run tests). It is not part of `mix ci` / `mix precommit.full`. The default suite only checks that each mutant still applies once and that the checked-in ledger says they were killed. **Nothing runs the campaign on a schedule.** Run `mix mutation.security` by hand before a release that touches payment authorization; a surviving canary (`canonical-ordering`, `pinned-fields`, `authorization-dispatch`) is the failure signal.

## Architecture

This is a **library** (not a Phoenix app). It provides Plug middleware that any Phoenix or Plug app can mount.

### Protocol flow (what this lib implements)

1. Request hits a protected resource
2. Server responds `402 Payment Required` with `WWW-Authenticate: Payment` header containing a challenge (price, accepted payment methods)
3. Client fulfills payment off-band (Stripe charge, on-chain tx, etc.)
4. Client retries with `Authorization: Payment <credential>` header
5. Server verifies payment, returns resource with `Payment-Receipt` header

### Module map

```
MPP                        — Root module, Discoverable entry point (describe/0-2 for progressive API discovery)
MPP.Challenge              — Challenge struct, HMAC-SHA256 ID binding, create/verify
MPP.Credential             — Credential parsing, challenge echo validation, payload extraction; hash_payload/1 + parse_hash_payload/1 for type="hash"
MPP.Receipt                — Receipt struct, base64url JSON serialization
MPP.Headers                — Parse/format WWW-Authenticate, Authorization, Payment-Receipt wire format (SchemeSplitter = internal multi-scheme boundary state machine)
MPP.AcceptPayment          — Accept-Payment client-preference header: parse/format/rank/apply_header
MPP.Hex                    — Internal hex-string helpers (strip_0x, hex_string?) shared across method/wire modules
MPP.Codec                  — Internal base64url→JSON decode (decode_base64_json) shared by credential/receipt/session_receipt
MPP.Methods.Shared         — Internal method-verification helpers (require_config, check_receipt_status, parse_charge_amount)
MPP.Errors                 — RFC 9457 problem types (paymentauth.org/problems/*), includes session error types
MPP.Intents.Charge         — Charge intent request schema (amount, currency, recipient, ...)
MPP.Intents.Session        — Session intent request schema (per-unit rate, unit_type, suggested_deposit, ...)
MPP.Intents.Subscription   — Recurring-subscription intent request schema (period_unit, period_count, subscription_expires, ...)
MPP.Session.Channel        — Session channel state, balance tracking, action wire mapping
MPP.Session.Voucher        — EIP-712 voucher typed data and signature verification
MPP.Session.Payload        — Session credential payload schema (open / voucher / topUp / close)
MPP.Session.Actions        — Session credential action handlers and per-channel balance updates
MPP.Session.Method         — use-wrapper that dispatches Method.verify/2 through session actions
MPP.Session.Store          — Behaviour for pluggable session-channel persistence
MPP.Session.ETSStore       — ETS-backed default session store (app-started)
MPP.BodyDigest             — SHA-256 body digest compute/verify for request body binding
MPP.Amount                 — Amount/decimals helpers: parse_units, with_base_units, parse_dollar_amount
MPP.JCS                    — RFC 8785 JSON Canonicalization Scheme (MPP subset: ASCII keys, no floats) for cross-SDK HMAC interop
MPP.Verifier               — Transport-neutral verification pipeline (HMAC, realm, expiry, request match, method.verify)
MPP.Method                 — Behaviour for pluggable payment methods (verify/2)
MPP.Methods.Stripe         — Stripe SPT → PaymentIntent verification (Req, no Stripe SDK); optional server-only Connect settlement routing
MPP.Methods.Stripe.Subscription — Stripe fixed-price subscription activation, durable renewal (process_invoice/3), and period-end cancellation (cancel/2)
MPP.Methods.Tempo          — Tempo on-chain TIP-20 transfer verification (delegates chain ops to onchain_tempo)
MPP.Methods.Tempo.MachineToken — Canonical first-party machine-token (MPP Credits) charge-route match (approve + swapTo)
MPP.Methods.Tempo.Subscription — Tempo access-key subscription activation, authorize/2 renewals, single-use claim lifecycle
MPP.Methods.Tempo.KeyAuthorization — Tempo subscription key-authorization wire codec and verifier (RLP layout matches ox/tempo)
MPP.Methods.EVM            — Generic EVM on-chain transfer verification (any chain: Ethereum, Base, Polygon, etc.)
MPP.Methods.EVM.Authorization — EIP-3009 transferWithAuthorization credential (challengeHash nonce) for USDC/EURC
MPP.Methods.EVM.Permit2    — Permit2 witness credentials (type="permit2"): challenge-bound off-chain signature, server-submitted, ordered split legs
MPP.Methods.EVM.Transaction — Client-signed EIP-1559 ERC-20 transfer (type="transaction"): validate against the charge, then server-broadcast
MPP.Methods.EVM.RPC        — Internal EVM JSON-RPC helpers (chain_id, hash canonicalization, Req opts) shared by the EVM credential paths
MPP.Methods.USDC           — Direct Circle USDC charge (draft-usdc-charge-00): EVM EIP-3009 + Solana legacy-SPL profiles (Assets, Binding, Profile, Replay, EVM, Solana submodules)
MPP.X402                   — x402 v2 exact client interop: PAYMENT-REQUIRED offers as synthetic challenges (Exact, Headers, Nonce submodules)
MPP.X402.Plug              — Server-side x402 exact settlement via configurable facilitator (MPP.Plug :x402)
MPP.X402.Facilitator       — x402 facilitator client (POST /verify, /settle)
MPP.Client.Providers.X402Exact — Client provider signing x402 exact EIP-3009 payments
MPP.Methods.Solana         — Solana native SOL / SPL token charge verification (pull transaction + push signature)
MPP.Methods.Solana.Instructions — Compiled + jsonParsed instruction classify/match for the Solana method
MPP.Methods.Solana.Confidential — Internal Token-2022 confidential bundle verification (type="bundle", recipient pending-balance decryption)
MPP.Methods.Stellar        — Stellar SEP-41 token charge verification (pull signed XDR + push hash; sponsored and unsponsored)
MPP.Methods.XRPL           — XRPL native XRP / issued currency / MPT charge verification (pull blob + push hash)
MPP.Methods.XRPL.Codec     — Bounded XRPL Payment / PaymentChannelCreate decoder and PaymentChannelClaim codec
MPP.Methods.XRPL.Claim     — Payment-channel claim message (CLM\\0) and signature verification
MPP.Methods.XRPL.Session   — XRPL payment-channel session intent (open / voucher / close); redeem/2 serializes per Destination
MPP.Methods.XRPL.RedeemLock — Single-node ETS lease (Destination account, and per-channel) with bounded acquisition for PaymentChannelClaim Sequence serialization
MPP.Methods.NearIntents    — NEAR Intents hash-credential charge verification via 1Click + origin RPC
MPP.Methods.Tempo.SessionReceipt — Session-intent receipt for Tempo (to_header/from_header, camelCase wire keys)
MPP.Methods.Tempo.FeePayerPolicy — Sponsor policy: bounds every client-controlled 0x76 envelope field (gas economics, access/authorization lists, key authorization, call value/calldata) before fee-payer co-sign (anti-drain)
MPP.Methods.Tempo.SponsorBudget — Atomic aggregate in-flight accounting for Tempo fee sponsorship
MPP.Methods.Tempo.HostedFeePayer — Hosted Tempo fee-payer JSON-RPC fill support
MPP.Methods.Tempo.Proof    — EIP-712 proof credentials for zero-amount Tempo charge flows
MPP.Intent                 — Shared contract implemented by payment-intent schemas (Charge / Session / Subscription)
MPP.Tempo.Store            — Behaviour for tx dedup stores (get/put + required atomic check_and_mark); default-on via Store.resolve/1, opt out with store: false
MPP.Tempo.ConCacheStore    — Built-in ETS dedup store with TTL via ConCache; app-started as the default store
MPP.Subscription.Store     — Behaviour for recurring-subscription persistence
MPP.Subscription.ETSStore  — App-started single-node subscription store
MPP.Subscription.Record    — Persisted recurring-payment authority and settlement state
MPP.Replay                 — Internal credential single-use dedup shared by the Plug, MCP, and JSON-RPC transports (check_unused/mark_used, Tempo carve-out)
MPP.Plug                   — HTTP Plug middleware, delegates verification to MPP.Verifier
MPP.Plug.MethodEntry       — Per-method config within a multi-method endpoint (method, charge, request, method_config)
MPP.Plug.Config            — Validated endpoint config struct (shared settings + list of MethodEntry structs)
MPP.Mcp                    — MCP (JSON-RPC) transport: constants (-32042/-32602/-32603/-32043, meta keys), error_code/1 problem->code mapping, server transport adapter (init/1 + call/3 with replay dedup), initialize capabilities/1, server/client helpers
MPP.Transports.JsonRpc     — Bare JSON-RPC transport: root-level `_meta` credential/receipt, init/1 + call/3, Plug adapter
MPP.Transports.WebSocket   — WS adapter: handshake challenge, credential/receipt frames, JSON-RPC message frames (library-agnostic)
MPP.Client.PaymentProvider — Behaviour for client-side payment providers (supports?/3, pay/2)
MPP.Client.MultiProvider   — Multi-provider dispatch: wraps [{module, config}], routes to first match
MPP.Client.Providers.Tempo — Built-in Tempo charge provider: chain-pinned, attribution-bound TIP-20 payments
MPP.Client.Providers.Stripe — Built-in Stripe charge provider: Shared Payment Token creation
MPP.Client.SelectionPolicy — Transport-neutral challenge selection/ordering (default: server offer order)
MPP.Client.Req             — Payment-aware Req plugin: attach/2 intercepts 402, pays, retries
MPP.Client.Transport       — Transport behaviour: payment_required?/1, get_challenges/1, set_credential/2 + select_challenge/2 helper
MPP.Client.Transport.HTTP  — HTTP transport over Req: 402 detection, WWW-Authenticate parsing, Authorization: Payment attach
MPP.Client.Transport.MCP   — MCP/JSON-RPC transport: -32042 detection, error.data.challenges, params._meta credential attach
MPP.Client.Transport.JsonRpc — Bare JSON-RPC transport: -32042 detection, root-level `_meta` credential attach
MPP.Client.Transport.WebSocket — WS transport: challenge frames, Payment credential frames, retry/backoff (no payment amplification)
MPP.Client.MCP             — Payment-aware MCP client: SelectionPolicy, approval hook, MultiProvider pay, at most two payment attempts (-32042 plus one -32043 re-challenge)
MPP.Client.AcceptPolicy    — Gates Accept-Payment header injection on outgoing requests
MPP.Discovery.OpenApi      — OpenAPI 3.1.0 discovery document generation (x-payment-info, 402 responses, route parameters, response schemas; mix mpp.openapi)
MPP.Discovery.PaymentInfo  — Parse/normalize the x-payment-info discovery extension
MPP.Telemetry              — Server-side payment telemetry events for challenges, verification, receipts
MPP.Expires                — Expiration helpers: seconds/minutes/hours/days/weeks/months/years, assert!
MPP.DID                    — DID helpers for EVM credential sources
MPP.Demo.Method            — Toy payment method accepting "demo-token" (for mix mpp.demo)
MPP.Demo.Router            — Plug.Router demo server with protected /resource endpoint
```

Also in `lib/` and intentionally undocumented above (`@moduledoc false` internals — listed so a gap-analysis pass doesn't re-file them as missing): `MPP.Application`, `MPP.Intents.Shared`, `MPP.Headers.SchemeSplitter`, `MPP.Methods.EVM.Permit2.Settlement`, `MPP.Methods.Tempo.{AccessKey, EnvelopeFields, ProofSignature, SignatureEnvelope, SubscriptionTransaction}`, `MPP.Methods.Solana.Ristretto255`, `MPP.Methods.Stellar.{RPC, Envelope}`, `MPP.Methods.NearIntents.{OneClick, Origin}`, `MPP.Methods.XRPL.{RPC, Wallet}`, `MPP.X402.Replay`, `MPP.Transports.JsonRpc.{Adapter, Plug}`, `MPP.Transports.WebSocket.{Frame, Session}`, `MPP.Client.Providers.Shared`, `MPP.Client.Transport.WebSocket.Retry`.

### Design decisions

- **Stateless HMAC-bound challenges.** Challenge ID = `base64url(HMAC-SHA256(secret, realm|method|intent|request|expires|digest|opaque))`. No challenge store needed — the server recomputes and does constant-time comparison on verification.
- **Intent = Schema, Method = Implementation.** `MPP.Intents.Charge` and `MPP.Intents.Session` define the shared request schemas (amount, currency, recipient, …). `MPP.Method` implementations only handle verification. Methods accept either intent struct via `MPP.Method.intent()`.
- **Explicit credentials.** Per `library-design.md`: no `Application.get_env`, no ENV fallback. Pass `secret_key`, `realm`, `method` module, and pricing explicitly via Plug opts.
- **Per-route pricing via Plug opts.** Each route mounts `MPP.Plug` with its own amount/currency. No global pricing config.
- **Base64url encoding preserves original bytes.** Critical for HMAC verification — never re-serialize, always use the raw base64url string from the original challenge.
- **Server-only method_config.** `MPP.Plug` accepts `:method_config` (a map) for secrets like `stripe_secret_key`. Public fields go to the client via `challenge_method_details/1`; private fields are merged into `charge.method_details` at verify time only, never serialized into challenges.

### Protocol constants

| Constant | Value |
|----------|-------|
| Auth scheme | `Payment` |
| Challenge header | `WWW-Authenticate` |
| Credential header | `Authorization` |
| Receipt header | `Payment-Receipt` |
| Problem base URI | `https://paymentauth.org/problems/` |
| HMAC algorithm | HMAC-SHA256 |
| HMAC input separator | `\|` (pipe) |
| Encoding | base64url (no padding) |

### Tempo network chain IDs

| Network | Chain ID | RPC URL | Docs |
|---------|----------|---------|------|
| Tempo Mainnet | `4217` | `https://rpc.tempo.xyz` | [connection-details#mainnet](https://docs.tempo.xyz/quickstart/connection-details#mainnet) |
| Tempo Testnet (Moderato) | `42431` | `https://rpc.moderato.tempo.xyz` | [connection-details#testnet](https://docs.tempo.xyz/quickstart/connection-details#testnet) |

Our code defaults to `42431` (Moderato testnet) — see `@moderato_chain_id` in `MPP.Methods.Tempo`. README examples use `4217` (mainnet).

### Dependencies

- `plug` — HTTP middleware framework (the integration surface)
- `jason` — JSON encoding/decoding for challenge/receipt payloads
- `req` — HTTP client for payment method API calls (Stripe, etc.)
- `descripex` — Self-describing API metadata (`api()` macro, `Discoverable`)
- `onchain` — Ethereum RPC, address validation, and ERC-20 transfer parsing
- `onchain_tempo` — Tempo chain primitives: 0x76 transaction handling, TIP-20 calldata, Tempo RPC, TransferWithMemo event parsing
- `onchain_solana` — Solana RPC, legacy transaction codec, Base58, and System/Token/ATA instruction builders (Solana method; Base58 also used by the XRPL codec)
- `stellar_base` — Stellar XDR used by the Stellar method to decode envelopes and rebuild sponsored transactions
- `ed25519` — Ed25519 signing for sponsored Stellar fee-payer envelopes
- `con_cache` — ETS-based TTL cache for `MPP.Tempo.ConCacheStore` dedup store

Dev/test analysis stack (vibe_kit baseline, all `only: [:dev, :test], runtime: false`): `credo` (+ `ex_slop` plugin for AI-slop antipatterns, configured in `.credo.exs`), `dialyxir`, `ex_dna` (clone detection), `ex_ast` (structural search), `reach` (architecture/smell checks, policy in `.reach.exs`), plus `styler`, `sobelow`, `doctor`, `ex_unit_json`, `dialyzer_json`, `tidewave`.

### JS/TS cross-referencing (dev/test only)

Three tools for verifying our implementation against the mppx TypeScript reference impl (`refs/mppx/`). **These are NEVER production dependencies.** MPP is a library — consumers must not pull in JS runtimes.

#### When to use what

| Question type | Tool | Example |
|---------------|------|---------|
| Understand logic/flow of one file | **Read** | "How does mppx's auth-param parser handle escapes?" |
| Structural query across files | **OXC** | "What functions does mppx export?" / "Who imports Challenge?" |
| Extract schemas/types to compare against our Elixir structs | **OXC** | "Do our Receipt fields match mppx's?" |
| Compliance check (do our error types match?) | **OXC** | Extract all mppx error URIs, compare against `MPP.Errors` |
| Verify runtime behavior matches | **QuickBEAM** | "Does mppx's HMAC produce the same output as ours for this input?" |
| Load ox/tempo for runtime cross-validation | **esbuild + QuickBEAM** | `MPP.Test.OxTempoBundle.load!(rt)` -- see below |
| Small file (<150 lines) | **Read** | Receipt.ts is 131 lines -- OXC adds overhead for no benefit |

#### Loading ox/tempo into QuickBEAM (esbuild pattern)

OXC's bundler can't produce clean IIFEs for packages with mixed ESM/CJS deps (like ox with @noble/*). Use **esbuild** instead:

```elixir
# In tests -- OxTempoBundle handles bundling + caching automatically
{:ok, rt} = QuickBEAM.start(apis: :browser)
MPP.Test.OxTempoBundle.load!(rt)
{:ok, result} = QuickBEAM.call(rt, "TxET.deserialize", ["0x76..."])
```

How it works:
- `test/support/ox_tempo_entry.mjs` -- thin entry importing `deserialize`/`serialize` from ox/tempo
- `test/support/ox_tempo_bundle.ex` -- shells out to `npx esbuild` with `--format=iife --platform=browser`
- Bundle cached to `_build/test/ox_tempo_bundle.js`, rebuilt when entry or ox version changes
- esbuild resolves all deps via ESM export conditions -- no scope collisions in QuickJS

#### OXC strengths and limitations

**OXC excels at:** cross-file function inventories (`OXC.collect` across all `src/*.ts`), import graph analysis (`OXC.imports/2`), schema field extraction from Zod objects, finding which functions use specific APIs (Base64, Hash, etc.).

**OXC struggles with:** complex AST node types your collection logic doesn't handle (SpreadElement, ConditionalExpression in object literals). When the JS uses patterns beyond simple properties, the collector crashes. Read doesn't have this problem.

**OXC comparison scripts need domain awareness:** OXC extracts mppx data perfectly, but comparing against our Elixir code requires understanding how we structure things (e.g., `@base_uri <> suffix` vs literal URI strings). Naive `String.contains?` misses these patterns.

#### How to use OXC (patterns that work)

```elixir
# Parse a file
{:ok, ast} = OXC.parse(File.read!("refs/mppx/src/Challenge.ts"), "Challenge.ts")

# Collect exported functions with arities
OXC.collect(ast, fn
  %{type: "ExportNamedDeclaration", declaration: %{type: "FunctionDeclaration", id: %{name: name}, params: params}} ->
    {:keep, {name, length(params)}}
  _ -> :skip
end)

# Extract z.object schema fields with required/optional
OXC.collect(ast, fn
  %{type: "CallExpression", callee: %{property: %{name: "object"}}, arguments: [%{type: "ObjectExpression", properties: props}]} ->
    fields = Enum.map(props, fn p ->
      key = Map.get(p.key, :name) || Map.get(p.key, :value)
      optional? = match?(%{callee: %{property: %{name: "optional"}}}, p.value)
      {key, if(optional?, do: :optional, else: :required)}
    end)
    {:keep, fields}
  _ -> :skip
end)

# Import graph (fast, no full parse)
{:ok, imports} = OXC.imports(File.read!("refs/mppx/src/Credential.ts"), "Credential.ts")
# => ["ox", "./Challenge.js", "./PaymentRequest.js"]

# Cross-file: find which functions touch Base64
for file <- ~w[Challenge.ts Credential.ts Receipt.ts] do
  source = File.read!("refs/mppx/src/#{file}")
  {:ok, ast} = OXC.parse(source, file)
  fns = OXC.collect(ast, fn
    %{type: "FunctionDeclaration", id: %{name: name}, body: body} ->
      if String.contains?(String.slice(source, body.start..body.end), "Base64"),
        do: {:keep, name}, else: :skip
    _ -> :skip
  end)
  if fns != [], do: IO.puts("#{file}: #{Enum.join(fns, ", ")}")
end
```

Run scripts with: `MIX_ENV=dev mix run /tmp/script.exs`

**Explore freely.** These patterns are starting points — try your own OXC queries against `refs/mppx/` to discover what works best for your specific question.

### First consumer

[api_cache](../api_cache/) is the first consumer — Phase 7, Tasks 47-51 in its roadmap. The Plug API must be mountable in a Phoenix router with per-route pricing. mpp has zero api_cache dependencies.

### Reference implementations (local clones)

Three reference repos are cloned into `refs/` (gitignored, auto-updated on session start via hook). **Read these directly — do NOT WebFetch from GitHub.**

The `/sdk-delta-watch` skill (`.claude/skills/sdk-delta-watch/SKILL.md`) triages these SDKs for upstream changes we may need to port: it diffs new commits since the watermark in `.sdk-watch.json` (committed at repo root) over the protocol-critical paths and judges parity against our Elixir impl (the pattern that caught mpp-rs #299 → Task 65 and mppx #577 → Task 46). It runs locally in an authenticated session precisely so the private-advisory path works: a genuine unfixed security gap goes to a **private draft GitHub advisory**, never a public `security` rmap task — see § "Security-parity ledger + disclosure convention". Only non-security parity gaps are filed as tasks; run `rmap render` afterwards to re-sync ROADMAP.md. A SessionStart hook suggests the skill once `.sdk-watch.json`'s `checked_at` is 7+ days old.

```
refs/mpp-specs/   — IETF spec source (specs/, examples/)
refs/mppx/        — TypeScript SDK (primary reference). Key files in src/:
                    Challenge.ts, Credential.ts, Receipt.ts, Errors.ts,
                    Method.ts, PaymentRequest.ts
refs/mpp-rs/      — Rust SDK. Key files in src/: protocol/, client/, server/
```

Also available:
- IETF spec: https://paymentauth.org/
- Developer docs: https://mpp.dev/ (llms-full.txt for complete docs)
- SDK index: https://mpp.dev/sdk — lists four official SDKs (TypeScript `mppx`, Python `pympp`, Rust `mpp-rs`, Go `mpp-go`) plus community SDKs (Elixir/ZenHive, Go/cp0x-org)
- Non-cloned SDKs (`pympp`, `mpp-go`, community `cp0x-org/mppx`) — fetch on demand via `gh repo view` / MCP / WebFetch when cross-referencing
- The `mpp` MCP server (`https://mpp.dev/api/mcp`, formerly `mcp__mpp__*`) is **no longer configured** in `.mcp.json` / `.cursor/mcp.json` / `.grok/config.toml`. Cross-reference SDK source from the local `refs/` clones (Read + OXC + QuickBEAM, above); use WebFetch for mpp.dev docs content.

### Upstream docs (mpp.dev)

The mpp.dev docs site ([tempoxyz/mpp](https://github.com/tempoxyz/mpp)) lists SDKs at https://mpp.dev/sdk in two tables: **Official** (mppx, pympp, mpp-rs, mpp-go) and **Community-Maintained** (our Elixir `mpp` via ZenHive, plus Go `mppx` by cp0x-org). Community entries were added via upstream [PR #502](https://github.com/tempoxyz/mpp/pull/502) on 2026-03-31. Our earlier [PR #473](https://github.com/tempoxyz/mpp/pull/473) (richer per-SDK pages under `/sdk/elixir`) was closed in favor of the community-table approach. If upstream opens the door to per-SDK pages again, revive from the `e-fu/mpp` fork.

### Conventions

- Styler is the formatter plugin (runs automatically via `mix format`)
- `test/support/` is compiled in test env (`elixirc_paths`)
- **Integration tests are mandatory.** Every payment method feature that makes RPC or API calls MUST have integration tests against the real service (Moderato testnet, Stripe test API, etc.). Unit tests with stubs only prove internal consistency — they cannot catch wrong request shapes, unexpected responses, or protocol mismatches. The Task 13g `eth_call` params bug proved this: all stub tests passed, but Moderato rejected the request. Tagged `:integration`, run with `mix test --include integration`.
- **🚨 Verify wire-format constants against the reference SDKs — don't trust your own tests.** Any hardcoded RLP field index, byte offset, length prefix, encoding/canonicalization assumption, or sentinel value (e.g. `MPP.Methods.Tempo.FeePayerPolicy`'s `@max_fee_index 2` / `@nonce_key_index 6` / `@valid_before_index 8`, JCS key ordering, HMAC input layout, `0x76` envelope positions) MUST be confirmed against the reference implementations — **`refs/mpp-rs/`** (Rust) and **`refs/mppx/`** (TypeScript), cross-checked when they agree — before it ships. The failure mode this prevents: a wrong constant whose unit tests still pass because the test fixture builder encodes the *same* wrong layout (the golden test ratifies the bug). Tests over a self-built fixture can't catch a constant that's wrong relative to the wire — only the reference SDK (or a live integration test against the real chain) can. Cite the `refs/…:line` evidence for the verdict. Pairs with the global `critical-rules.md` § "RESEARCH BEFORE ASSERTING ON NICHE TECHNICAL CLAIMS" (wire formats / protocol details) and the domain-ground-truth review seat.
- Spec source: `refs/mpp-specs/` (local) or [tempoxyz/mpp-specs](https://github.com/tempoxyz/mpp-specs)
- Reference impl: `refs/mppx/` (local) or [wevm/mppx](https://github.com/wevm/mppx) (TypeScript)
- Reference impl: `refs/mpp-rs/` (local) or [tempoxyz/mpp-rs](https://github.com/tempoxyz/mpp-rs) (Rust)

### Testing: three tiers of ground truth

Before writing tests for any module, ask **one question: what is ground truth for this code?** The trap all three tiers guard against is identical — *coverage green, reality wrong* — and a self-built fixture can never break that tie, because the golden test builds the fixture with the same wrong assumption it's meant to catch. Only reality (a live call) or an independent implementation (a reference SDK) can.

1. **Code that calls an external service** (Stripe API, chain RPC via `onchain`/`onchain_tempo`) → **the live endpoint is the only truth.** A mock encodes your *guess* of the response shape; it passes green while the real call 400s on a field you misremembered. Tag `:integration`, hit Moderato/Sepolia/Stripe-test. This is the "Integration tests are mandatory" bullet above — Task 13g's `eth_call` params bug is the proof (every stub passed, Moderato rejected the request).
2. **Code that must match a wire format or another implementation** (HMAC input layout, JCS ordering, RLP field indices, the MCP `_meta` envelope, error codes, fee-payer constants) → **the reference SDKs are truth, cross-checked when `mpp-rs` and `mppx` agree.** Tag `:cross_validation`, run via QuickBEAM/OXC against `refs/`. This is the "Verify wire-format constants" bullet above.
3. **Pure glue / transforms / adapters** (MCP transport shaping, header formatting) → no external truth, so fixtures are fine — but **derive the fixtures from tier 1 or 2** (a captured real response, a reference-SDK snapshot), never invent them.

**Operationalizing it:**
- **Explore then pin.** Hit reality *first* via Tidewave `project_eval`, observe the actual shape, *then* write the `:integration` test that asserts it, *then* mock only what you've now seen for the fast unit tests. A real call + one assertion is cheaper than a debug loop against a wrong mental model — integration tests are the time-*saver*, not the tax.
- **Tiers 1 and 2 stay out of the default `precommit.full` gate** (need live creds / JS toolchain) but run explicitly before landing anything touching those surfaces (`mix test.json --include integration` / `--include cross_validation`).
- **Never skip silently.** Missing creds → the test runs and `flunk()`s loudly with the exact `export` vars, not a green `:skip`. "0 failures" from 0 tests is a lie (global `critical-rules.md` § "NEVER HIDE TEST FAILURES").

## GitHub Check Routine

When asked to "check GitHub" (comments, PRs, security), sweep **all** of these surfaces — they are independent and a finding in one does not show up in the others:

```bash
gh pr list --state open                                          # open PRs
gh issue list --state open                                       # open issues
gh api repos/ZenHive/mpp/security-advisories \
  --jq '.[] | {ghsa: .ghsa_id, severity, state, summary}'        # 🚨 private vuln reports (PVR) — Security→Advisories tab
gh api repos/ZenHive/mpp/dependabot/alerts \
  --jq '.[] | select(.state=="open")'                            # vulnerable dependencies
gh api repos/ZenHive/mpp/secret-scanning/alerts                  # leaked secrets
```

**🚨 `security-advisories` is the one most easily missed and the highest-stakes.** Privately-reported vulnerabilities submitted through Private Vulnerability Reporting land **only** in the Security → Advisories tab — they do **NOT** appear as Dependabot alerts, code/secret-scanning alerts, or in the notifications inbox (advisory submissions email repo admins, they don't generate a `reason: security_alert` inbox item). The remaining scanning endpoints cover *automated* findings; `security-advisories` covers *human-reported* ones. **Always query it.** As of 2026-06, three reporter `kai-kka` gas-draining advisories (critical/high/medium) sat in `triage` for up to 12 days before being noticed precisely because earlier sweeps skipped this endpoint.

Code scanning is dormant — nothing has uploaded SARIF since the workflows were removed; re-add its query above if a scanner is wired up again.

Triage states to act on: `triage` (new, unreviewed), `draft` (being worked). Reporter, PoC, and affected-version detail are at `gh api repos/ZenHive/mpp/security-advisories/<GHSA-id>`.

### Security-parity ledger + disclosure convention

`docs/security-parity.md` is the standing record of every upstream-SDK security advisory / fix mapped to our parity status (✓ have / 📋 tracked-in-Task-N). It and the `sdk-delta-watch` routine keep upstream security work *tracked*, not silently assumed. **🚨 Disclosure rule — this repo is public, so `tasks.toml` / `ROADMAP.md` / `docs/` are all published.** Therefore: a parity *gap* that is unfixed and exploitable is NEVER filed as a public `security` rmap task or a public ledger row — that would hand attackers a checklist for a deployed money library. Unfixed-gap detail goes to a **private draft GitHub security advisory** (Security → Advisories, the same channel inbound PVRs use); the public ledger holds only ✓/📋 rows plus a generic open-item count. When a fix ships, the item moves to a ✓ row and the advisory is published with the patched release (coordinated disclosure, per `SECURITY.md`). The `sdk-delta-watch` routine follows the same split: parity-confirmed → ✓ row; genuine gap → private advisory, never a public row.

## Git Commit Configuration

**Format:** `<scope>: <lowercase imperative description>` — the convention in this repo's log (169 of the last 200 commits). Scopes in use: `fix`, `test`, `docs`, `deps`, `roadmap`, `release`, `security`, `ci`, `chore(sdk-watch)`. Drop the scope prefix only when none applies.

Title only; add a body when the change needs one. No `Co-Authored-By` footers.
