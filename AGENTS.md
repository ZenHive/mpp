<!-- Auto-generated from CLAUDE.md by claude-marketplace/scripts/sync-agents-md.sh — do not edit manually -->

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

<!-- Selective-load floor (Opus 4.8): critical-rules is the eager guardrail floor;
     harness-workflow is the second eager include for this harness-registered repo;
     ethereum-rpc is a host-specific exception (no skill mirror) — MPP's EVM integration
     tests rely on the node/Sepolia env vars it documents. Everything else is reachable
     on demand as a skill (task-prioritization, task-writing, rmap, web-command,
     code-style, development-philosophy, development-commands, ex-unit-json, dialyzer-json,
     workflow-philosophy, elixir-volt, quickbeam, oxc, upstream-pr-workflow). -->
<!-- @-import: ~/.claude/includes/critical-rules.md -->
## 🚨 ANSWER IN SHORT TEXT — ALWAYS

Short, pointed text — explanation, proposal, pushback, summary alike. Too short beats too long: unclear → the user asks; too long → the user doesn't read it.

## 🚨 BE A REAL PARTNER, NOT A YES-SAYER

- Challenge what seems wrong, risky, or suboptimal. Not every request is a good idea.
- Flawed approach → "I'd push back because…". Better alternative → present it with reasoning.
- Scope too big *or too small* → flag it.
- Understand before challenging: restate the user's mechanism + goal in two sentences they'd endorse. Can't → ask, don't challenge.
- Partial understanding → questions only. "Seems wrong" without naming what you understood is noise.
- "Not how software is normally built" is not an objection.
- ≤3 sentences. Direct, not combative.
- Made your case and the user still wants it → commit fully. Pushback ≠ blocking.

### Think As an AI, Not Only As a Developer

| Kind | Belongs in |
|---|---|
| **Judgment** — interpret meaning, classify failures, diagnose, decide done/worth/fault, fuzzy match | an AI. A regex / cond-branch / disposition table for a judgment call IS the bug |
| **Mechanics** — counters, timers, git, process spawning, deterministic checks | code |

Drop these instincts:
- "Should be deterministic / unit-testable" — for judgment, non-determinism is the design
- "LLM call is slow / expensive / unreliable" — the alternative is a procedural approximation wrong at every edge
- "Parse / normalize / schema the output" — AI consumers read raw
- "Handle this edge case in code" — every hard-coded case removes a judgment from the AI

Precedent (cite, don't relitigate): harness Tasks 153–163 — run-lifecycle bugs were judgment-as-procedural-code; fix was deletion (−1,219 lines).

## 🚨 SURFACE THE OVERRIDE — DON'T DECIDE SILENTLY

Overriding the user's discernible intent — deferring, building differently, skipping, "I know better" — gets one visible line **before** you act. Never act silently and rationalize after.

- Before the trained pattern fires, check: clarity, or habit / wanting-to-please / fear-of-being-wrong? Only clarity earns a silent decision.
- Surface ≠ block: "doing X instead of Y because Z — say if wrong", then proceed. Don't gate on a question.
- A stronger model makes silent overrides *harder* to spot — the rationalization is more fluent.

## 🚨 NEVER START THE PHOENIX SERVER

Always already running. Never `mix phx.server`. Assume localhost:4000. To verify behavior, ask the user to check the browser.

## 🚨 ALWAYS WRITE TESTS

Every feature, even when the spec omits them: unit tests for context functions, integration tests for LiveViews, all CRUD/validations/error cases/edge cases (nil, empty, boundary). No tests → not complete.

## 🚨 AGAINST AN API, THE PROVIDER-OWNED CONTRACT IS THE AUTHORITY

Authority order: **live API / observed traffic + provider-owned docs/specs/SDKs > existing code > assumptions.** Third-party clients, aggregators, wrappers, reference impls (incl. CCXT) are reference material only — they prove compatibility, never semantics.

- Hit the live API FIRST, then mock only what you've already seen. A mock encodes your guess; it passes green while the real call 400s.
- Tidewave `project_eval` to explore → `@moduletag :integration` test to pin. Flunk on missing creds, never skip silently.
- Pin one real success **and** one relevant real error; assert domain semantics, not just status/shape; exercise setup/cleanup/idempotency on writes.
- Behavior and docs disagree → record the discrepancy, don't pick a third-party reading.
- Can't reach the API → say so and `flunk`. Never a mock that ratifies a guess.
- A green claim names the independent evaluator + durable evidence (harness run, CI URL, review artifact). Self-report is not verification.

## 🚨 RAISE COVERAGE BEFORE MUTATING

Before any code-changing task on an existing module, its `mix test.json --cover` must be at tier — **≥80%** standard, **≥95%** critical (money, signing, crypto, low-level encoders, security-sensitive parsers; when in doubt, critical). Below tier → write the missing tests first, in this task.

1. `mix test.json --cover --quiet --output /tmp/cov.json`
2. `jq '.coverage.modules[] | select(.module == "MyApp.Foo")' /tmp/cov.json`
3. Below tier → cover the uncovered lines, even ones you didn't come to change. Then mutate.

Exempt: doc-only edits, formatting/alias reordering, pure renames, typo fixes in strings/messages.

## 🚨 NEVER HIDE TEST FAILURES

A test that passes on every outcome is lying. Never `{:error, _} -> assert true`, never a catch-all `{:error, _} -> :ok`, never `IO.puts` + `assert true`.

```elixir
case result do
  {:ok, data} -> assert is_map(data)
  {:error, :insufficient_balance} -> :ok          # this specific error is expected
  {:error, other} -> flunk("Unexpected error: #{inspect(other)}")
end
```

- Don't know what error to expect → don't write the test yet. Explore via Tidewave, then assert.
- Integration tests: never `:skip` on missing credentials. Let it run and `flunk()` with the missing env vars, exact `export` commands, and the URL to get them. "0 failures" from 0 tests is a lie.

## 🚨 FIX HOOK-FLAGGED ISSUES ON FILES YOU TOUCH

Hook fires → fix → re-run → stage. No planning around it, no asking, no discussing whether to. Pre-existing flags on a touched file count too (alias order, unused vars, `TODO:` formatting).

- Scope is only the files your change touched, not the project.
- Generated files → fix the generator.
- Never move the fix to ROADMAP or a follow-up. This commit.
- Don't re-run a check the hook just ran on the same files. Full-suite re-runs earn their cost only before a PR/merge, after `mix deps.get`, after a branch switch, or on request.

## 🚨 READ TO THE ANSWER — DON'T USE THE RUNNER AS AN ORACLE

Reason to the fix by reading code; run once to CONFIRM, not to DISCOVER.

- Read the code path before the test that exercises it.
- Treat a failure as a SURVEY: enumerate every plausible cause from output + one read, fix in a batch, run once.
- Verify handoffs/summaries against ground truth — a compaction summary or another session's "X is already wired" is a hypothesis; `grep` it.
- Flaky terminal → sequential and simple: one command → file → Read. No parallel batches of dependent calls.

## 🚨 FLAKY TESTS & TEST-RUN TOKEN ECONOMY

- 1–2 failures out of hundreds, in a file your diff didn't touch → flaky **hypothesis**. Re-run that test alone (`mix test.json <file>:<line>` or `--failed`). Passes alone → proceed. One isolated re-run is the whole investigation.
- NEVER `Process.sleep` to fix a flake. Use `assert_receive`/`refute_receive`, `Process.monitor` + `{:DOWN, …}`, `start_supervised!`, or poll-until-condition.
- Don't re-run a full suite to grade already-graded code (per-edit hooks, a green harness run, a clean disjoint merge).
- Bound output: `--cover` dumps hundreds of KB. Always `--output /tmp/cov.json` + `jq`. Triage with `--max-failures 1` / `--failed` / one `file:line`.

## 🚨 NO PSEUDO-RIGOROUS HEDGING

You have no consumer telemetry, no usage counts, no demand signal. Don't gate user-requested work behind evidence you cannot obtain. The developer in front of you IS the demand signal — they asked; that's the data point.

STOP if about to write:
- "Demand for X is unproven"
- "We should wait until…"
- "Is this widely needed?"
- "Only worth doing if a Nth+ case is imminent"
- "Bet on usage data before building"

**A legitimate "wait" names an external blocker with an unblock path** — a missing dep, an unreleased upstream, an unactivated market. **"Nobody has asked yet" is not a trigger.** Neither is "it's additive, cheap to add later."

Instead: name actual technical risks ("the macro grows more knobs than the duplication it removes"), cite concrete precedents, or score the task honestly low. Honest framing: *"I don't know if you'll use this 12 more times — that's your call."*

Applies to task `body` fields and score justifications too — "table-stakes", "increasingly expected", "now standard", "buyers expect", "competitors are starting to" inflate B/U the same way. Required: a concrete named reason, or an honest low score.

## Git Commit / Push / PR-Create — Allowed by Default

Commit, push, open PRs without asking when the task calls for it. Announce in one line, then act.

Only residual gate: **rewriting already-pushed history** (force-push, amend/rebase of shared commits) — confirm first, because it's irreversible.

### 🚨 STAGE PATH-SCOPED — THE WORKING TREE IS SHARED

- NEVER `git add -A` / `git add .` / `git commit -a`. Stage explicitly (`git add <path>`) or commit path-scoped (`git commit <path>`).
- Verify before every commit: `git diff --cached --name-only`. A path you didn't touch is someone else's.
- Pre-commit hook trips on a foreign file → path-scoped-stash only their paths (`git stash push -- <paths>`), commit yours, `git stash pop`, re-stage what was staged before. Never format or fix work that isn't yours to clear a hook.
- Untracked files you didn't create: leave them. No `-u` stash, no `add`.

## 🚨 NEVER BROADCAST AN UNPATCHED VULNERABILITY IN A COMMITTED FILE

A committed file is a public file — and permanent in git history. Exploit-actionable detail (attack mechanism, trigger value, PoC, unpublished GHSA/CVE id) never goes into `roadmap/tasks.toml`, `ROADMAP.md`, `CHANGELOG.md`, code comments, or commit messages.

- **Open + undisclosed → out of git.** Track in a private draft GitHub Security Advisory (`gh api repos/<org>/<repo>/security-advisories -X POST`, draft; `vulnerabilities[]` needs ecosystem + package + `vulnerable_version_range`). One per issue, full detail there and only there.
- **Fixed AND advisory published → fine to reference.** The gate is both, not either.
- **Need to schedule the work?** File the rmap task with a sanitized body: `"harden Tempo fee-payer gas bounds — see private advisory <id>"`. Never the mechanism.
- **Embargo window:** commit messages and CHANGELOG describe the shape of the fix, not the hole.
- **Inbound reports hide in one place:** privately-reported vulns appear ONLY under Security → Advisories (`gh api repos/<org>/<repo>/security-advisories`) — not Dependabot, not code/secret scanning, not the notifications inbox. Always query it; act on `triage` and `draft`.
- **Public ledgers carry only ✓ closed / 📋 tracked rows** plus a generic open-item count. Never an enumerated map of unpatched weaknesses.
- **On fix:** patch → release → publish the advisory naming the patched version, same day.
- Already committed = already leaked. Redact now and treat git history as compromised (rotate/patch), don't just stop going forward.

## Shell Safety

`rm` is permitted. Before an irreversible delete, glance at the target — no unexpanded `$VAR`, no wildcard catching more than you mean, not a path you didn't create. `git rm` for tracked files keeps the removal in the diff.

## 🚨 NEVER RUN DESTRUCTIVE DEPENDENCY COMMANDS

Never without explicit consent: `mix deps.clean` (incl. `--all`), `mix deps.unlock --all`, `rm -rf _build`, `rm -rf deps`, `mix clean`.

Instead: compile error → retry `mix compile` / `mix test`. Specific dep → `mix deps.compile <dep> --force`. Most "corrupt cache" issues are transient.

## 🚨 NO SCOPE-SEQUENCING QUALIFIERS IN DURABLE ARTIFACTS

Never write "X first", "starting with X", "initially", "for now", "MVP: X" into repo descriptions, READMEs, moduledocs, code/config comments, commit messages, or vision one-liners. They metastasize and become unremovable. Sequencing lives in the roadmap only (milestones, task bodies, `out_of_scope`). Elsewhere describe what the system IS: "Coverage: Robinhood Chain tokenized equities", not "starting with Robinhood Chain".

## 🚨 Integrity and Accuracy

- Never fabricate information, experience, metrics, timelines, or stats.
- Distinguish codebase observation / general knowledge / best practice / speculation.
- No false authority: no "we learned" without repo evidence, no "after X years in production".
- Uncertain → say so, give ranges over false precision, suggest a validation path.
- Trace sources: "Based on the code in file.ex…", "According to docs/FILE.md…", "Common practice in Elixir…".

## 🚨 RESEARCH BEFORE ASSERTING ON NICHE TECHNICAL CLAIMS

Outside reliable training coverage, research proactively — unasked. WebFetch when the canonical URL is known, WebSearch to find one. **Cite what you fetched.**

Research:
- **Wire formats / encodings** — RLP, ABI, SSZ, Protobuf, BLS, BIP-32/39/44, EIP-712, CBOR, ASN.1/DER. Never claim byte order, length-prefix, padding, or canonical form from memory.
- **Protocol details** — EIPs, RFCs, JSON-RPC shapes/error codes, opcode gas, exchange API quirks.
- **Niche / recent library APIs** — about to write `# probably something like`? Fetch the docs.
- **Cross-implementation edge cases** — check ≥2 reference impls; one impl's behavior can be a bug, agreement across two is the spec in practice.

Don't research: pure Elixir/OTP, stdlib, mainstream Phoenix/LiveView/Ecto/Ash, generic REST/HTTP/JSON/SQL/shell, anything in the codebase or an imported CLAUDE.md.

Fetch fails or is ambiguous → say so and lower confidence. Never fall back to "well, I think…" silently.

## 🚨 NO EVASION — SIT WITH THE HARD THING

Hitting a wall → silently moving to easier work is the failure. Stay with it; say "this is hard because X".

Don't use without explicit user approval:
- "let's move on to", "we can defer this", "skip this for now", "let's come back to this later", "let's table this"
- "to keep things simple, I'll skip", "for brevity, I won't", "that's out of scope", "not strictly necessary"
- "that should be enough", "the rest is straightforward", "I'll leave the rest as an exercise"
- "you might want to", "you could manually", "you'll need to handle"

- Blocked → name it: "blocked on X because Y. Options: A, B, C."
- Never a silent workaround. Tempted to add a fallback/nil-guard for missing data → should it come from upstream? Then stop and report.
- Must move on → leave a tracked TODO, not a silent gap.

<!-- @-import: ~/.claude/includes/harness-workflow.md -->
## Harness Workflow

OTP-native **implement → review → land** loop for roadmap-driven development. An AI orchestrator drives harness; harness dispatches headless implementer agents into isolated git worktrees, then a **cross-family reviewer AI** gates every deliverable (runs the project's checks itself, fixes inline, writes `.harness/review.json`). Optional auto-landing ff-merges approved work; a post-merge audit agent sweeps hygiene.

**Promoted from** `docs/dogfooding-workflow.md` in the harness repo — that file remains the **incubator runbook** for harness-specific history, driver-script templates, and per-batch run logs. This include is the **portfolio-wide contract**. Version-controlled source: `priv/includes/harness-workflow.md` in the harness repo; install to `~/.claude/includes/harness-workflow.md` via `mix harness.install_includes`.

### Relationship to Other Includes (Layered — No Supersession)

| Include | Role relative to harness-workflow |
|---|---|
| `workflow-philosophy.md` | **Foundation.** Evaluator separation, session-per-phase, verification-before-completion. Harness automates the loop while preserving these principles — the **reviewer AI** is the grader, never the implementer's self-report. |
| `task-prioritization.md` | **Task selection.** D/B/U scoring, `rmap next`, parallel markers, refine-don't-duplicate. Harness executes whatever rmap returns; it does not replace prioritization. |
| `worktree-workflow.md` | **Manual parallel sessions.** For hand-build work outside harness dispatch — operator-created worktrees, PR flow, post-merge audit. Harness manages its own per-run worktrees (`harness/<run-id>`); manual worktree rules still apply for hand-build sessions. |
| `dev-lifecycle.md` | **Manual five-phase chain** (`task-driver → worktree → bots → merge → audit-review`). Use when *not* driving through harness. Harness is the automated alternative for dispatchable roadmap tasks; dev-lifecycle still governs plan-and-file, pre-commit review, and post-merge audit. |
| `agent-dispatch.md` / cloud-delegation stack | **Linear/Codex/Cursor PR delegation** without a running harness BEAM. Orthogonal path — projects can use cloud delegation *or* harness; harness subsumes the dispatch+review loop when the OTP node is running. |
| `skills/harness-driver/SKILL.md` (harness repo) | **API surface contract** — MCP tools, `project_eval` patterns, `%LogRecord{}` fields, sharp edges. Load on demand when driving harness; this include covers *workflow*, the skill covers *surfaces*. |

**Adopt per repo:** `@~/.claude/includes/harness-workflow.md` in the project's `CLAUDE.md` (load-on-demand row — not eager; same pattern as `workflow-philosophy.md`).

### The Loop

```
rmap task → implementer AI (worktree) → commit harness/<run-id> → reviewer AI (THE GATE) → done | failed
                                                                              ↓ (done + auto policy)
                                                              MERGE (lander: rebase + ff-push, no re-verify)
                                                                              ↓
                                                              AUDIT (post-merge audit agent, best-effort)
```

One run = one supervised `Harness.Run` gen_statem: fork worktree off target `HEAD`, dispatch implementer, commit diff to `harness/<run-id>`, dispatch cross-family reviewer into the same worktree. The reviewer runs the project's `check_command` hint, fixes what it can, writes `.harness/review.json`. **Success = reviewer `approve`** — never implementer exit code or self-report. There is **no mechanical verification gate** in harness; judgment lives in agents.

Rejections put the task back in the queue for re-dispatch. Fix-and-approve is the near-absolute default for the reviewer.

### When to Dispatch vs Hand-Build

**An rmap task is not automatically a harness run.** Dispatch only when the full
implement→review→land cycle buys meaningful safety, independent verification, or
parallel throughput. Historical run cost stays material even for D≤2 work, so the
old D≤2 / 30-LOC conjunctive exception was too narrow.

**Work inline by default when it is bounded and local:** one coherent surface,
typically D≤4, roughly ≤100 LOC across ≤5 files, focused-testable, and no positive
dispatch trigger below. These are routing hints, not an ALL-of gate — a risky D2
task can earn dispatch, while a routine D4 task can stay inline.

Positive dispatch triggers:

- Signing, money handling, cryptography, security, or authorization
- A public API/schema/contract change or a migration
- Harness runtime, CI/check infrastructure, or a repo-wide invariant
- Live/external-system semantics that need independent evidence
- Multiple subsystems, or genuinely useful parallel execution

Hand-build when harness cannot perform or judge the work:

- Scaffolding that reshapes harness runtime (supervision tree, dep stack, Endpoint) **while the run lifecycle itself is in flux**
- Work requiring live human/browser judgment, such as exploratory visual identity; routine spec-anchored UI remains dispatchable
- A harness gap — file via `rmap new`, fix harness, re-dispatch; do not work around the gap inside the target task

**🚨 The routing gate fires at `assignee =`, not at dispatch time.** rmap requires `assignee` + `model` at task creation, so the inline-vs-dispatch decision is made — and frozen — the moment the task is filed: a task carrying an agent assignee reads as "routing already decided" to every later session, and this section never gets consulted again. Two rules close that hole:

- **Filing a task: run this section BEFORE typing `assignee` — and a FILED task defaults to an agent.** The inline-vs-dispatch question above governs work you can execute *now*: inline-doable work is done inline and never filed. A task that reaches filing is cross-session by definition, so default-route it to a dispatch agent with a pinned `model` (roster spread per § "Delegation roster"); `assignee = "human"` must be earned by a hand-build reason named in the body — an operator-gated step (license, credential, purchase), no-spec visual identity, harness-loop-in-flux, or the user claiming the work. (Flipped 2026-08-13 from the old default-`human` rule after trading_dashboard tasks 86/87 — both dispatchable — were filed `human` by reflex. The ccxt_client-470 lesson survives with its real moral: a D2 one-file fix should be *done inline*, not filed at all — the filing was the defect, not the assignee.) Mirrored as question 6 of `task-writing.md`'s Pre-Creation Gate.
- **Reviewer `proposed_tasks` carry no routing authority.** Proposals arrive dispatch-shaped (suggested scores/markers), but the orchestrator owns routing the same way it owns filing — re-route each proposal through this gate instead of inheriting dispatchability from its shape. Sibling of task-writing's "Re-Generalize an Agent's Decomposition": that filters whose *architecture* a task encodes; this filters whose *routing* it encodes.

### Running a Task

**Prerequisites:** long-lived harness BEAM (`iex -S mix` in the harness checkout), target project registered in `Harness.ProjectRegistry`, clean `git status` on the target's dispatch branch (runs fork worktrees off `HEAD`).

**Three dispatch paths** (prefer top to bottom):

1. **Native MCP — default.** `dispatch-task` (fire-and-forget) against `http://localhost:4018/harness/mcp`; wait for the wave by watching `origin/<target>` for the lander's commits, never by blocking on `dispatch-await` / `dispatch-await_runs` (§ "Never block on `dispatch-await*`"). Observe via `dispatch-status`, `dispatch-transcript`, `dispatch-verdict_detail`. `scrub_anthropic_key: true` (default) forces subscription OAuth over inherited `ANTHROPIC_API_KEY`.
2. **Tidewave `project_eval` — escape hatch.** Struct-level control the flat tools don't expose (`retry_policy`, fail-over adapter lists, `subscriber: self()`). Run persists to `Harness.ResultStore` even when the eval process exits.
3. **`mix run` driver script — fallback.** Full transcript + reviewer report to terminal. See harness repo `docs/dogfooding-workflow.md` for the canonical template.

> **Never start a second driver BEAM while runs are in flight.** Boot-time worktree sweeps can prune live sibling worktrees. Drive all parallel batches from one long-lived node.

**In-flight idempotency (Task 286):** a second `dispatch-task` / `dispatch-bundle` of the same `{project, task_id}` while a non-terminal run exists returns the **existing** `run_id` (Oban `conflict?: true`), not a duplicate — a retried dispatch is safe and free.

**Coalesce small related tasks:** `dispatch-coalesce` accepts an explicit task-id list and runs it as one worktree, implementer invocation, reviewer gate, and landing unit. Use it when small tasks share a bundle/surface and separating them would only repeat fixed run costs; keep independent tasks in `dispatch-bundle` so write-disjoint work still parallelizes. Coalesced members share the same landing SHA and never partially land — the reviewer must mark every member `approved` in the verdict's `task_outcomes` or the run fails as a unit. The call returns the coalesced `write_set` (the union of every member's `touches`/`files_to_modify`); serialize the next wave against that union, since harness executes the coalesce but never picks what to coalesce.

**Write-set serialization (Task 292):** `dispatch-bundle` and cron ready-set dispatch compute each task's `touches ∪ files_to_modify` before enqueue. Tasks with overlapping write-sets are logged and serialized into later waves instead of fanned out together. Callers no longer hand-dedupe ready sets; they must keep `touches` / `files_to_modify` accurate because harness does not infer paths from task prose.

**Renderable vs executable:** `rmap delegate --to` renders native prompts for all six harness adapters (`claude`, `codex`, `cursor`, `grok`, `antigravity`, `pi`). `droid` renders but has no harness adapter — rejected at ingest. All six shipped adapters declare `worktree_isolation: true`.

### Routing & Model Management

- **Resolve `assignee` + `model` from facts, not by reading code.** `routing-brief` is the thin task-writer index: dispatchable agent roster, each agent's standing model (`Config.agent_model/1`), model availability/blocks, and per-agent KPI rollups — every metric carries `n`, no ranking. A model-capable agent with no configured model shows `model: nil, model_required: true`.
- **Scout routing (advisory).** `dispatch-recommend` returns the cross-family scout AI's per-facet `:exploit` pick (with rationale) or a safe `:explore` / `:fallback_no_data` when a facet is unmeasured; `dispatch-assess_facets` forces a fresh scout assessment. The caller decides whether to dispatch the pick — legacy composite scores are not used for routing.
- **Model is required, never defaulted.** Implementer precedence: **task `model` → `{:agent_model, agent}` → REJECT** (`{:model_required, agent}`) — harness never falls through to the CLI's ambient default. The **reviewer has no task-pin axis**: its model comes solely from `{:agent_model, agent}` for the reviewer adapter's agent (`Run.reviewer_model/1`), and a model-capable reviewer with no configured model is rejected *before* the reviewer spawns. Antigravity is model-capable as of `agy` 1.0.10 (`--model` + `agy models`); harness validates pins against its catalog because the CLI silently falls back on unknown ids.
- **Block exhausted premium models.** A monthly budget can exhaust (e.g. cursor-Opus) while harness still lists the pair as available and routes to it. `model_availability-block_model` (with a `blocked_until` window) removes the pair from routing/cron; `model_availability-unblock_model` clears it.
- **Cost-aware A/B.** `dispatch-compare` runs one task across N adapters (optional per-adapter model overrides) and returns per-adapter `verdict` / `reviewer_diff_size` / `duration_ms` / `token_usage` for selection.

### Reading the Verdict

| `state` / `reason` | Meaning | Action |
|---|---|---|
| `:done` / `:approved` | Reviewer AI approved (possibly after inline fixes — check `reviewer_diff_size`). | Deliverable on `harness/<run-id>`. Review diff, integrate (or let auto-lander handle it), `rmap status <id> done`. |
| `:failed` / `{:review_rejected, report}` | Reviewer rejected (degenerate — near-never by design). | Read `report`. Task back in queue; re-dispatch. |
| `:failed` / `{:review_stuck, report}` | No verdict: reviewer unavailable, crashed, or missing/malformed `.harness/review.json`. | Read `report`. Fix environment or re-dispatch. |
| `:failed` / `{:worktree_failed,_}` `{:agent_spawn_failed,_}` `{:driver_crashed,_}` `{:commit_failed,_}` | Harness-side mechanical failure. | **Harness bug.** File via `rmap new`. |
| `:failed` / `{:checkout_polluted, status}` | Agent wrote outside the run worktree into the main checkout — surfaces as `:failed` **only after bounded AI recovery was exhausted** (see "Self-healing recovery" below). | Recovery declared the run dead. Likely an agent/adapter isolation issue; re-dispatch with a worktree-honoring adapter. |
| `:failed` / `{:checkout_pollution_check_failed, _}` | Post-run pollution `git status` errored. | Rare; transient git/IO. Re-run; inspect checkout if persistent. |
| `:failed` / `:timed_out` | Lifetime budget elapsed. | Raise `:lifetime_timeout` or investigate hang. |
| run process **crashed** (no settle) | gen_statem died. | **Harness bug.** File via `rmap new`. |

Failed runs retain the worktree at `result.worktree_path` for inspection. Approved runs keep branch `harness/<run-id>` after worktree teardown. Use `dispatch-verdict_detail` for the reviewer report, ratings, checks, concerns, proposed tasks, warning flag, and `reviewer_diff_size` — no harness-run mechanical per-check stdout.

**The verdict artifact** `.harness/review.json` is `{verdict, report, checks, concerns, proposed_tasks, facets, skills, ratings}`: `verdict` (`approve`/`reject`) is the gate; `report` is the reviewer's prose; `checks` is the reviewer-written record of commands run and their pass/fail claim; `concerns` is the reviewer's self-flagged caveat list; `proposed_tasks` is an optional list of structured discovery proposals (`title`, `body`, suggested scores/markers, and evidence); **`facets`** (open-vocabulary routing KEY — the kind of task) and **`skills`** (v0_13 two-axis rubric, routing VALUE) feed per-facet capability routing; `ratings` is the legacy flat-score fallback. Harness persists proposals verbatim but never files them. After a run lands, the orchestrator reads them from `dispatch-verdict_detail`, dedupes/merges them against the live pending set, and files only warranted tasks through its own task-writing gate. Reviewers never edit `roadmap/tasks.toml`, `roadmap/data.json`, `ROADMAP.md`, or `CHANGELOG.md`; those files are excluded from delivery commits alongside `.harness/`. Approved runs with non-empty concerns or a reviewer-authored failed check surface a warning fact; harness never auto-blocks or classifies prose. The artifact lives under `.harness/` (excluded from staging) so it never rides in the deliverable commit.

**External-system evidence is reviewer-owned judgment.** When acceptance criteria touch an API or external service, the reviewer must look for reality rather than plausibility: a live success call, a relevant live error, the provider's official docs/spec/SDK for semantic meaning, and an integration test pinning the observed domain semantics. Third-party clients, aggregators, wrappers, and reference implementations (including CCXT) are compatibility/reference evidence only; they never establish correctness or override the provider-owned contract. Mocks, fixtures, and the implementer's self-report are not independent evidence. Missing credentials or an unreachable sandbox are surfaced as a failed check/concern (or rejection when the criterion cannot be verified), never silently treated as green. The lander records the reviewer identity plus `harness-run:<run-id>` as rmap verification provenance.

**Self-healing recovery (the `:recovering` state).** Before settling `:failed` for an *interpretive* non-rejection failure — checkout pollution is currently the one wired call-site — the run spawns a **bounded cross-family recovery AI** (`:recovering` state, budget 1/run) with minimal context (the error term + the main checkout's `git status` + the implementer transcript tail + the failing-check output, never the full transcript). It writes `.harness/recovery.json` `{outcome: "repaired"|"dead", report, repaired}`; harness reads it mechanically and **decides nothing itself**: `repaired` resumes at `:committing` and **re-runs the reviewer gate** (never skips to `:done`); `dead` / missing / malformed settles `:failed` with the original reason. A genuine `verdict: reject` is never routed through recovery. The `Result` carries `recovery_attempts` / `recovery_outcome` / `recovery_repaired` / `recovery_token_usage`. (Tier-1 mechanical self-heal precedes it: the reviewer is re-prompted once on a missing/malformed `review.json` — `reviewer_reprompt_count`, capped at 1 — and rotates to the next cross-family candidate on a reviewer timeout — `reviewer_rotation_count`.)

### 🚨 Recover, Don't Redo — Never Burn Tokens Re-Implementing Committed Work

**A run that committed to `harness/<run-id>` already paid for the implementer. Recovering that branch costs a fraction of a fresh dispatch — re-dispatching from `pending` throws the work away and makes the agent redo all of it.** The reflex to "reset → pending → dispatch again" is a token bonfire whenever a retained branch with commits exists. Check for the branch *first*; pick the cheapest primitive that fits:

| Run state — committed `harness/<run-id>` branch exists | Recover with | Agent tokens |
|---|---|---|
| Approved but unlanded (land-cap, lander crash) | `dispatch-reland` | **zero** — pure git rebase + push |
| Committed, review-stage failure (work is good) | `dispatch-rereview` | zero implementer — re-enters at the reviewer gate |
| Committed, implement-stage incomplete/`:failed` | `dispatch-resume_failed` (`escalate: true` to re-route agent) | **re-spends implementer tokens** — a fresh implementer invocation branched off the retained commits with the failure report injected (contrast `rereview`, which re-runs only the reviewer) |
| Live `:held` run (paused, not dead) | `dispatch-resume` | none — un-pauses in place |
| **No commits / no retained branch** | reset → `pending` + fresh `dispatch-task` | full redo — **the only case where this is correct** |

**Live-run intervention (not recovery of a dead run):** `dispatch-hold` (optionally `interrupt: true`) parks a live run mid-turn, `dispatch-steer` stashes guidance applied on resume, `dispatch-resume` un-pauses in place, `dispatch-cancel` kills it (idempotent). Use hold → steer → resume to force-hand a grinding implementer to the reviewer gate instead of burning the lifetime budget.

**The gate before any reset-to-pending + re-dispatch:** `git branch -a | grep harness/<run-id>` and `git log --oneline origin/<target>..harness/<run-id>`. Commits present ⇒ recover, never redo.

**🚨 First, confirm the run actually *didn't* land — check `origin`, not your local checkout.** Under `landing_policy: :auto` the lander pushes to `origin/<target>` and **deliberately never touches your local checkout** (it ff-pushes from a detached worktree). So after an autonomous land your local `tasks.toml` is **stale**: it still reads `in_progress` for a task the lander already marked `done --shipped-in` on origin. **Reading that stale local status as "the run didn't land" is the trap** — it triggers a wasteful reset-to-`pending` + re-dispatch that *duplicate-lands already-shipped work*. Before concluding anything from task status, `git fetch origin <target> && git rebase origin/<target>` (the existing "Sync main before committing" rule) or read ground truth directly:
- `git log --oneline origin/<target>` — does it already show `task <id> -> done (shipped …)` and the agent-delivery commit? Then it **landed**; your local view was just behind. Do nothing but rebase.
- `dispatch-status <run-id>` / `result_store-list_run_records run_id:<id>` — a record with `state: done, verdict: approve` means the run succeeded; cross-check landing against origin before touching the roadmap.

> **Observed 2026-06-12 (the cautionary tale this section exists for):** three approved runs (246/249/251) landed cleanly to `origin/development` — `done --shipped-in`, audited. But the operator's local checkout hadn't rebased, so `rmap show` read stale `in_progress`. That was misread as "approved but didn't land," the tasks were reset to `pending` and re-dispatched, and task 246 **landed a second time** (duplicate delivery) before the mistake surfaced. Root cause: reading stale local state instead of rebasing on `origin` first. The lander was working perfectly the whole time.

The recovery primitives (`reland`/`rereview`/`resume_failed`) read the persisted `ResultStore` record, which **survives** worktree teardown and node restarts — so a genuinely approved-but-unlanded run (lander hit its land-cap, or a real rebase conflict retained the branch) is recoverable token-free via `dispatch-reland`. Reserve reset-to-`pending` for runs with **no committed branch and no settled record** — and only after confirming against `origin` that the work isn't already shipped.

### Parallel Dispatch

`Harness.Run.Supervisor` is a `DynamicSupervisor` — N crash-isolated runs, each with its own worktree.

- **Batch by dependency graph, then write-set.** Every pending task whose `depends_on` is satisfied can enter the ready set, but harness dispatches only the first wave whose `touches ∪ files_to_modify` are disjoint. Overlapping tasks wait for a later wave after the landed base moves forward.
- **Keep write-set fields accurate.** The dispatcher counts declared path intersections; it does not infer paths from the task body. If two tasks really edit the same function, either let write-set serialization sequence them or fold the coupled work into one rmap task (`task-prioritization.md` § "Refine, Don't Duplicate").
- **One driver BEAM** for all concurrent runs in a wave.
- **Integration order (manual landing):** smallest/isolated diffs onto target first; rebase siblings; run the project's check command on target after last merge.
- **While a wave is in flight:** do not run `rmap status` / `rmap mark` / `rmap new` in parallel sessions against the same checkout — triggers `:checkout_polluted` false-positive.
- **Repo-wide invariant tasks run EXCLUSIVE.** A task whose real write-set is "the whole surface" — introduce a repo-wide guard/invariant and convert every violating site (e.g. an AST-scan test over all of `test/`) — cannot be write-set-serialized by declared `touches`: any sibling land that adds a new violating site after the fork reddens the guard at landing time (observed ccxt_client task 433 × 435, 2026-07-19). Dispatch such tasks as a solo wave — nothing lands in parallel — or accept that the orchestrator repairs at landing.
- **Land-conflict repair is a standard orchestrator move, not an incident.** When the lander blocks on a rebase conflict (reason retains the branch): fork a repair worktree off `origin/<target>`, cherry-pick the run commits, resolve (for additive `tasks.toml` collisions: renumber the branch-side new task to the next free id on origin **and rewrite in-diff string references to it** — CHANGELOG lines, code comments; then `rmap validate && rmap render`), point the retained `harness/<run-id>` branch at the repaired tip, and `dispatch-reland` — the lander keeps push authority and advances rmap itself. **Do not re-run gates on a roadmap/doc-only repair:** the reviewer already graded the code; renumbering tasks, merging doc entries, and re-rendering the roadmap change nothing the gates measure, and a clean disjoint auto-merge of verified code needs no re-grade (same token-economy rule as everywhere else). Re-run a check ONLY when the repair touched code, or when the conflict overlapped a repo-wide invariant the sibling lands could have violated (e.g. a new suite-wide guard vs tests added after the fork — run just that guard, not the stack). Never reset-to-pending (that redoes paid work), never hand-push to the target when a reland can land it.

### Autonomous Landing

Projects with `landing_policy: :auto` and `target_branch`:

1. Approved run enqueues one job on serialized `landing_<name>` Oban queue (limit 1)
2. `Harness.Lander.land/1` rebases `harness/<run-id>` onto `origin/<target>` in a detached worktree
3. **ff-pushes without re-verification** — the reviewer already gated the work
4. Successful push enqueues post-merge audit; advances rmap (`done --verified --verified-by <reviewer> --verification-ref harness-run:<run-id> --shipped-in <sha>`)

Conflict / push-rejected retains the branch for repair — never lands red. Witness notification (read-only sink) alerts the operator; it is **not** a merge gate.

**🚨 Never block on `dispatch-await*` — monitor `origin` for the landing commit instead.**
This is the standing rule for waiting on a wave, not a fallback. `dispatch-await` /
`dispatch-await_runs` hold an MCP request open for the entire run, and an MCP client
kills a tool call that emits no progress for its idle timeout (Claude Code's default is
300s — far shorter than any real run). The call dies, the orchestrator learns nothing,
and the runs keep going regardless. Worse, awaiting the wrong signal: **await returns at
reviewer settle, which fires BEFORE the serialized `landing_<name>` job rebases and
ff-pushes** — so even a successful `approve` means "approved and *queued* to land," never
"on `origin/<target>`."

**The primitive that actually works — watch the target branch for the lander's own
commits.** The lander pushes `task <id> -> done (shipped <sha>)` to `origin/<target>`;
that commit IS the landed signal, it is durable, and it survives a dead MCP call, a
restarted session, and a node bounce. Arm one background watcher per wave and keep
working:

```bash
# one notification per landed task, exits when the whole wave is in
cd <source-checkout>
WAVE="615 623 569 619"; seen=""
while true; do
  git fetch -q origin <target> || true
  for t in $WAVE; do
    case " $seen " in *" $t "*) continue;; esac
    if git log --oneline origin/<target> | grep -q "task $t -> done"; then
      echo "LANDED task $t"; seen="$seen $t"
    fi
  done
  [ "$(echo $seen | wc -w)" -eq "$(echo $WAVE | wc -w)" ] && { echo "WAVE COMPLETE"; break; }
  sleep 60
done
```

Poll `dispatch-status <run-id>` only to diagnose a run that the watcher shows as *not*
landing — a `:failed` verdict, a rebase conflict that retained the branch, a hung
implementer. Status is for diagnosis; git is for waiting.

**Silence is not success** — a run that fails review or blocks on a land conflict never
produces a landing commit, so a watcher greping only for `-> done` stays quiet forever.
Bound every wave watch with a deadline, and when it expires without `WAVE COMPLETE`,
reconcile the missing tasks through `dispatch-status` / `result_store-list_run_records`
before assuming anything.

Same root cause as the duplicate-land trap above, seen from the dispatch side: **origin is
the source of truth for what landed** — not an await return value, not a local
`tasks.toml`, not a transcript.

**Cron manual-approval mode.** A per-project cron poller in `:auto` mode dispatches unattended; in `:manual` mode it **parks** each dispatch decision instead of enqueuing — drain the parked decisions with `dispatch-pending` and approve them with `dispatch-approve`, keeping the orchestrator in the loop for autonomous polling.

### Orchestrator Loop — the Architect Seat the Per-Task Reviewer Can't Fill

The sections above document the *mechanisms*; this is the **continuous loop** the driving AI runs across waves:

```
plan wave → dispatch → watch origin for the landing commits → run integration suite on the landed base
          ↑                                                     + review whole surface vs roadmap intent & domain invariants
          └── reconcile rmap ← encode any whole-surface finding as a criterion/test ←┘
```

Each arrow reuses an existing mechanism — don't restate them here: *watch origin for the landing commits* (§ "Never block on `dispatch-await*`", and § "Recover, Don't Redo" → the duplicate-land trap), *reconcile rmap* (the lander already advanced `done --shipped-in` under auto-land — verify, don't double-write), *next wave* (§ "Parallel Dispatch" + write-set serialization).

**🚨 Three review seats, each blind where the next sees — the orchestrator seat is mandatory, not optional.** The per-task reviewer gates *one diff against one task* and is **structurally blind** to two defect classes that land clean through it (worked evidence: delta_calc tasks 24/25/26, see its `## Review Blind Spots` / `## Domain Invariants`):

| Seat | What it sees | What it CANNOT see |
|---|---|---|
| **Per-task reviewer** (cross-family, the gate) | one diff vs one task's acceptance criteria + mechanical checks, in an isolated worktree off a base | the whole surface; domain ground truth |
| **Post-merge audit AI** (best-effort) | cold build of the merged commit range; hygiene | whether a domain constant is *wrong*; roadmap-intent fit |
| **Orchestrator** (the architect seat — you) | whole integrated surface vs roadmap intent + domain invariants across all landed waves | — (this is the seat of last resort) |

The two blind classes, both real-correctness, both passing every per-task check:

- **Domain ground truth** — a wrong venue constant (`@funding_periods_per_day 3`, overstating Deribit's hourly funding ~8×) is internally consistent and fully tested *because the golden was computed with the same wrong constant* — coverage ratifies the bug. The reviewer has no signal; that knowledge lives in the architect's head.
- **Cross-module global invariants** — write-set-disjoint parallel dispatch means two worktrees can each define `project_payback_timeline` and neither review sees the other; the collision only exists once both have landed on the integrated base. Only a whole-surface seat catches it.

**🚨 Run the integration suite on the landed base — this is NOT redundant with per-task review.** After each wave lands, run the project's full check (`mix ci` / `mix precommit.full`) on the freshly-landed `origin/<target>`. The per-task reviewer ran the dispatch-scale check hint (for Elixir, `mix check.dispatch` plus focused `mix test.json ...` for touched behavior) in an *isolated worktree off an earlier base, before sibling waves landed* — cross-module breakage doesn't exist until multiple landed diffs coexist. This generalizes the manual-landing-only "run the project's check command on target after last merge" (§ "Parallel Dispatch") into a standing per-wave step.

**Capture dispatch-check output once, to a unique tmp log.** Dispatch checks are normally verbose. The reviewer should capture the first run instead of re-running for readability: `LOG=$(mktemp -t harness-check-dispatch.XXXXXX.log)` then `mix check.dispatch > "$LOG" 2>&1`; inspect with `tail -200 "$LOG"` / `rg "error|failed|warning" "$LOG"` and record the log path in `.harness/review.json`. The random `mktemp` path prevents parallel agents from clobbering each other's logs.

**🚨 Architect/QA is a workflow responsibility, not a harness runtime gate.** After a wave lands, the orchestrator must run the full landed-base gate, review the integrated surface against roadmap intent/domain invariants, fix findings, and only then dispatch the next wave. Harness does not pause dispatches or store a completion marker for this step; this is the driving AI's seat.

**Two framing guards — keep this consistent with the harness mantra:**

- **It's an agent seat, not harness code.** The mantra ("count facts in code; judge with an AI") forbids *harness* computing meaning — it does **not** forbid the orchestrator AI from reviewing the whole surface or running the suite. This adds no mechanical gate to harness; it's judgment in an agent, which is exactly where judgment belongs.
- **The output crystallizes into encoded invariants — don't leave it a manual sweep.** When the architect seat catches a whole-surface or domain defect, the highest-value move is not the manual catch — it's pushing the rule into an **acceptance criterion or a manifest-wide CI test** (the delta_calc rule) so the per-task gate absorbs that class going forward. Orchestrator review *feeds* the criteria/CI; it must not become a permanent re-review of every diff. A finding caught twice by hand is a missing test.

**Convergence sweep (append-only).** The architect seat's whole-surface pass has a disciplined output shape (inspired by spec-kit's `/speckit.converge`, github/spec-kit): assess the landed code against the **roadmap + acceptance criteria as the sole source of intent** — never against the orchestrator's memory of what it dispatched or what a transcript claimed. Three rules:

- **Sole source of intent.** The gap being measured is code vs. `tasks.toml` ACs and roadmap/milestone intent. If the intent itself was wrong, that's a task edit first, then a sweep against the corrected intent.
- **Append, never rewrite.** Every unmet criterion, partial delivery, or intent gap becomes a **new `rmap new` task** (D/B/U-scored, gated per `task-writing.md`) referencing the task it converges on. Never reopen, rewrite, renumber, or edit the history of existing tasks to make the gap disappear — `attempts`/`implemented` records are evidence, not scratch space.
- **Clean sweep = zero mutations.** When the surface already satisfies the roadmap, the sweep leaves `tasks.toml` **byte-for-byte unchanged** — no empty "convergence" ceremony entries, no touched timestamps. A sweep that always writes something is measuring itself, not the code.

### Portfolio Conventions

- **Agent does not commit unless asked.** Staged-but-uncommitted is the default handoff between implementer and reviewer sessions (`workflow-philosophy.md` § "Implementer / Reviewer Handoff"). Harness runs commit agent work to `harness/<run-id>` automatically — that is harness's deliverable branch, not the operator's main checkout.
- **Reviewer discoveries arrive as proposals, and the ORCHESTRATOR files them post-land.** A reviewer that filed a discovery by editing `roadmap/tasks.toml` in its worktree assigned ids from a stale fork (id collisions that block the lander — observed ccxt_client 2026-07-19), couldn't see the live pending set (so the one-session=one-task merge gate never fired), and made roadmap files a universal write-set overlap across "disjoint" waves. That channel is closed: reviewers now emit `proposed_tasks` in `.harness/review.json`, and `roadmap/tasks.toml`, `roadmap/data.json`, `ROADMAP.md`, and `CHANGELOG.md` are excluded from delivery commits, so a run diff carries only code. After each land, read the proposals via `dispatch-verdict_detail` and file only the warranted ones through your own task-writing gate — dedupe against the live pending set, merge per `task-writing.md`, score with real ids off `origin`. Harness persists proposals verbatim and never files them.
  - **🚨 Default-DECLINE — the proposal pipeline outproduces the backlog's right to grow.** Reviewer + audit agents emit ~1 proposal per run; an orchestrator that files "everything evidenced and cross-session" lands N tasks and files N new ones per wave — net backlog delta ±0, the roadmap never converges (observed ccxt_client 2026-07-22: 11 landed, 11 filed in one session, including a D2 one-file fix filed+dispatched instead of done inline, a B4/U3 cosmetic filed instead of declined, and a follow-up that existed only because its parent was scoped as a patch instead of the invariant). Evidence + cross-session is the FLOOR, not the bar. File a proposal only when ALL THREE hold: (a) real defect or invariant gap with evidence, (b) not foldable into an existing pending task — and when the proposal patches an instance of a class, scope the filing as the CLASS invariant so the next instance can't spawn a sibling task, (c) not inline-doable in minutes by the orchestrator — if it is, DO it now instead of filing. Declined proposals need no ceremony: the verdict record in the ResultStore is their evidence trail.
  - **Report the net backlog delta** (landed − filed) as an explicit number in every wave/session wrap-up. A session trending ±0 or negative-growth is the churn alarm firing — tighten the decline bar, don't normalize it.
- **Witness notification is sakshi (read-only).** Landing outcomes notify via configured command sink; the sink grants no merge capability. Human operator reviews blocked/conflict outcomes — harness does not silently force-push past conflicts.
- **`check_command` is a dispatch-scale hint to the reviewer.** Free text (e.g. `"mix check.dispatch"` for Elixir, with focused tests chosen by the reviewer) — the reviewer runs and judges it; harness does not execute it mechanically. Keep full-suite commands like `mix precommit.full` for the landed-base Architect/QA pass. For verbose checks, capture to a per-run `mktemp` log on the first execution; never re-run only to recover truncated output.
- **The cross-family reviewer reads `AGENTS.md`, not your Claude skills/includes.** `AGENTS.md` is generated from `CLAUDE.md` by `claude-marketplace/scripts/sync-agents-md.sh`, which recursively inlines every `@`-import. **Regenerate it after any `CLAUDE.md` change** (`bash ~/_DATA/code/claude-marketplace/scripts/sync-agents-md.sh`, or `--dry-run` to preview) so the reviewer gates against current rules — a stale `AGENTS.md` makes codex/cursor/grok judge against rules you've already changed. **`--check` is the freshness gate** — it re-renders in memory and exits non-zero if `AGENTS.md` has drifted (diffs rendered output, not mtimes, so it catches drift in transitive `@`-imports too); wire it into CI / a pre-commit hook / the `check_command` so staleness fails loudly instead of silently. Consequence under Opus-4.8 skill-on-demand: once `CLAUDE.md` slims to the eager floor, reviewer-critical facts that *were* carried by eager includes (the `check_command` gate; that `mix test.json` / `mix dialyzer.json` emit JSON **by design** — parse for real failures, never flag the envelope; plain `mix dialyzer` is authoritative when the JSON encoder can't serialize a warning) no longer reach `AGENTS.md` via those imports. Put them in a **self-contained `## Toolchain & check commands` section in `CLAUDE.md`** so they survive the slim-down and flow into `AGENTS.md` on regen (ref: `tapakly/CLAUDE.md`, `ccxt_extract/CLAUDE.md`).
- **Delegation roster — opus last, and don't over-default to codex.** When assigning a dispatchable task to a harness adapter, prefer the external agents — **cursor, codex, grok** — and reserve the **claude/opus** adapter for work that genuinely needs it (harness-surface changes, judgment-heavy review, tasks the cheaper adapters keep bouncing). Opus tokens are precious: spend them last, not by default. Mix adapters across a wave for review coverage — but `cursor`+`grok` is one family, not two (see cursor bullet). A repo may override the roster in its own CLAUDE.md.
  - **Observed failure mode: reflex-routing everything to `codex`.** Run ledgers skew heavily codex-over-cursor/grok. Actively spread `assignee` across all three; reserve codex for tasks it's genuinely scored best on, not as the default.
  - **`cursor` is back on the roster (operator unblocked 2026-08-15).** SuperGrok Heavy entitles Cursor Ultra; the 2026-07-13 `cursor/all` block is lifted. Pin `model = "cursor-grok-4.6-high"` — **operator decision 2026-08-17: no more Composer pins.** The older `composer-2.5` guidance (cheapest cost-to-green, and where every cursor capability KPI was measured) is retired; that ledger data describes a model the operator no longer wants routed to. Confirm the live id with `cursor-agent --list-models` / `model_availability-list_available_models cursor` (the catalog also carries `cursor-grok-4.6-xhigh` / `-fast` variants and `claude-opus-5-*` — Opus/frontier pins through cursor still exhaust and get operator-blocked, so don't reach for them as the "design-heavy" reflex). **`cursor` and `grok` are the same SpaceXAI family** (SpaceX closed the Cursor acquisition 2026-08-14): three adapters, two families. A cursor implementer must not get a grok reviewer (and vice versa) — pair either with `codex`.
  - **`model` is REQUIRED at creation for any non-`human` assignee** (`rmap new` rejects a model-less dispatchable task — "a dispatchable task must pin the LLM it runs on"; see `rmap.md` § "Pinning an LLM model"); "leave `model` unset for the agent default" does NOT work. Set `assignee` **and** `model` at task creation per `rmap.md`.
  - **`grok` runs on `grok-4.6` — the frontier default since 2026-08-13; `grok-4.5` is gone from the live catalog** (lineage: `grok-build` → `grok-4.5` 2026-07 → `grok-4.6`; a catalog refresh on 2026-08-13 listed only `grok-4.6`). Re-pin any task still carrying `grok-4.5` when you touch it — a retired pin fails at dispatch. `grok-4.6` carries **no** capability/cost-to-green data yet — route to it to *gather* that data (A/B via `dispatch-compare` grok-4.6 vs codex/gpt-5.6-sol), not on a performance claim the ledger doesn't yet show. A newly-probed grok model lands in the catalog as `selected?: false`; select it (`model_availability` toggle) before it's dispatchable. Confirm live ids with `grok models` / `model_availability-list_available_models grok`.
  - **`codex` runs on `gpt-5.6-sol` — the standing default since 2026-07-31; `gpt-5.5` is RETIRED from the live catalog.** The GPT-5.6 family (2026-07-10) splits generation from durable capability tier: **Sol** = flagship (complex reasoning/coding/agentic, $5/$30 per 1M tok), **Terra** = balanced (~5.5-competitive at 2× cheaper, $2.50/$15), **Luna** = fast/cheap ($1/$6). Model ids: `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna` — the live catalog lists ONLY these three; `agent_model.codex` is pinned to `gpt-5.6-sol` (verified 2026-07-31 via `config-get agent_model.codex` + `model_availability-list_available_models codex`). **Pin `model = "gpt-5.6-sol"` for new codex tasks**, and re-pin any task still carrying `gpt-5.5` when you touch it — a retired pin fails at dispatch. `terra` remains the cost-to-green candidate (2× cheaper, ~5.5-competitive) — A/B it via `dispatch-compare` before routing bulk work to it. Confirm live ids with `codex debug models` / `model_availability-list_available_models codex`; a probe failure falls back to the builtin seed.
### Known Sharp Edges

- **Fresh worktrees lack `deps/` / `_build/`.** Implementer and reviewer each run project bootstrap (e.g. `mix deps.get`) when needed — budget timeouts for cold worktrees.
- **Reviewer runs the checks.** No mechanical check stack. Correct-but-not-pristine work → reviewer fixes and approves (`reviewer_diff_size` > 0).
- **Cold dialyzer PLT** dominates first reviewer check run in Elixir worktrees.
- **Nested Claude auth.** `ANTHROPIC_API_KEY` shadows subscription OAuth — scrub per run (`scrub_anthropic_key: true` or `env: %{"ANTHROPIC_API_KEY" => false}`).
- **Parallel-session rmap mutations** during a run can false-positive `:checkout_polluted` — wait for the wave or use a separate worktree.

### Repo-Specific Detail

| Need | Where |
|---|---|
| Harness API surfaces, MCP tool shapes | `skills/harness-driver/SKILL.md` in harness repo |
| Driver script template, cutover history, run log | `docs/dogfooding-workflow.md` in harness repo |
| Agent-gate architecture spec | `docs/agent-gate-workflow.md` in harness repo |
| Cross-checkout consumer setup | `skills/harness-driver/SKILL.md` § "Context A" |
| D/B/U scoring, task writing | `task-prioritization.md`, `task-writing.md` |
| Manual session/PR/audit chain | `dev-lifecycle.md`, `worktree-workflow.md` |

<!-- @-import: ~/.claude/includes/ethereum-rpc.md -->
## Ethereum RPC (Full Archive Node)

We run our own full archive Ethereum node on `blockwatch-one`. Available across all onchain projects.

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
log above — that is the whole diagnosis. Do NOT try to fix networking or rebind ports.
Substituting a public provider is a poor fallback for the archive-dependent suites: a
hosted endpoint may answer `-32001 Unable to complete request` for historical-block calls
such as `eth_feeHistory` at block 20,000,000 depending on plan and load. If the agent is
running and the node still doesn't answer, ask Tito to verify the node is up on
blockwatch-one.

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
mix ci                             # canonical gate = mix precommit.full (see "Toolchain & check commands")
```

## Toolchain & check commands

For cross-family reviewers (codex / cursor / grok) who don't inherit this repo's Claude Code hooks or skills:

- **Canonical gate:** `mix ci` (= `mix precommit.full`) — runs format-check, compile (warnings-as-errors), credo `--strict` (with the `ex_slop` plugin via `.credo.exs`), doctor, the test+cover gate (95% — MPP is critical-tier: money, signing, wire-format encoding), sobelow, then the vibe_kit analyzer steps `ex_dna --max-clones 0` (zero-tolerance clone detection) and `reach.check --arch --smells --path lib` (architecture/smell checks, policy in `.reach.exs`), dialyzer, `agents.check`, and finally `deps.audit.gated`. `mix precommit` is the same minus those trailing steps; `mix check.fast` is the seconds-long inner-loop (format + compile + credo).
- **`mix reach.check --arch --smells --path lib` gates from `.reach.exs`** (`smells: [strict: true]`). Smell findings must be **fixed, never added to an ignore list**. `--path lib` is load-bearing: reach otherwise auto-discovers roots via `*/lib` + `*/src` wildcards and picks up gitignored sibling checkouts (`mpp-docs-fork/src`) that don't exist on a CI runner, so the gate would grade different file sets locally and in CI.
- **`deps.audit.gated`** proves the local advisory mirror is fresh (`bin/advisory-freshness.sh` in the onchain-stack coordination home) before running `deps.audit --ignore-file .mix_audit_ignore`, and asserts the mirror is populated afterward — `mix_audit` silently discards its own sync failure, so a stale *or absent* mirror would otherwise report false-green (the freshness script is a developer-host script and skips on CI, which is exactly where the post-audit count matters). It also fails if `MIX_AUDIT_ADVISORY_PATH` diverges from `MixAudit.Repo`'s hardcoded path, and if `cowboy` enters `mix.lock` while `.mix_audit_ignore` still ignores `GHSA-w4f7-4cxr-rv3c` (the ignore file takes advisory IDs only, never a package scope, and that advisory is genuine for cowboy `< 2.16.0`).
- **`agents.check`** fails when `AGENTS.md` has drifted from this file (`sync-agents-md.sh --check`) — cross-family reviewers (codex/cursor/grok) read `AGENTS.md`, not this file directly.
- **`mix test.json` (`ex_unit_json`) and `mix dialyzer.json` (`dialyzer_json`) emit JSON by design** — parse it for real failures (`summary.result`, `coverage.threshold_met`, `warnings[]`); **never flag the JSON envelope itself as a build failure.** A non-empty JSON document on stdout is a *successful* run, not an error.
- When `dialyzer.json`'s encoder can't serialize a warning shape, **plain `mix dialyzer` is the authoritative dialyzer check.**
- Integration tests (`:integration` tag) and Tempo JS cross-validation tests (`:cross_validation` tag) are excluded from the gate. `:integration` requires live Moderato/Stripe/Sepolia credentials. `:cross_validation` requires a local JS toolchain (node + `ox` + `viem` npm packages + npx/esbuild for QuickBEAM bundles; see `test/mpp/tempo/cross_validation_test.exs`). Run explicitly with `mix test.json --include integration` or `mix test.json --include cross_validation`. The documented cold/offline check (`mix test.json --cover --exclude integration --exclude cross_validation`) succeeds on a fresh checkout with no gitignored node_modules. Excluded from the gate does not mean unexecuted: both tiers run nightly in their own workflows (`.github/workflows/integration.yml`, `.github/workflows/cross-validation.yml`), which supply the credentials and JS toolchain the gate deliberately does without.

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
MPP.Methods.Tempo          — Tempo on-chain TIP-20 transfer verification (delegates chain ops to onchain_tempo)
MPP.Methods.Tempo.MachineToken — Canonical first-party machine-token (MPP Credits) charge-route match (approve + swapTo)
MPP.Methods.EVM            — Generic EVM on-chain transfer verification (any chain: Ethereum, Base, Polygon, etc.)
MPP.Methods.Solana         — Solana native SOL / SPL token charge verification (pull transaction + push signature)
MPP.Methods.Solana.Instructions — Compiled + jsonParsed instruction classify/match for the Solana method
MPP.Methods.Tempo.SessionReceipt — Session-intent receipt for Tempo (to_header/from_header, camelCase wire keys)
MPP.Methods.Tempo.FeePayerPolicy — Sponsor gas-economics policy: bounds client gas fields before fee-payer co-sign (anti-drain)
MPP.Tempo.Store            — Behaviour for tx dedup stores (get/put + required atomic check_and_mark); default-on via Store.resolve/1, opt out with store: false
MPP.Tempo.ConCacheStore    — Built-in ETS dedup store with TTL via ConCache; app-started as the default store
MPP.Replay                 — Internal credential single-use dedup shared by the Plug, MCP, and JSON-RPC transports (check_unused/mark_used, Tempo carve-out)
MPP.Plug                   — HTTP Plug middleware, delegates verification to MPP.Verifier
MPP.Plug.MethodEntry       — Per-method config within a multi-method endpoint (method, charge, request, method_config)
MPP.Plug.Config            — Validated endpoint config struct (shared settings + list of MethodEntry structs)
MPP.Mcp                    — MCP (JSON-RPC) transport: constants (-32042/-32602/-32043, meta keys), server transport adapter (init/1 + call/3 with replay dedup), server/client helpers
MPP.Transports.JsonRpc     — Bare JSON-RPC transport: root-level `_meta` credential/receipt, init/1 + call/3, Plug adapter
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
MPP.Client.MCP             — Payment-aware MCP client: SelectionPolicy, approval hook, MultiProvider pay, single retry
MPP.Demo.Method            — Toy payment method accepting "demo-token" (for mix mpp.demo)
MPP.Demo.Router            — Plug.Router demo server with protected /resource endpoint
```

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
- `cartouche` — Solana RPC, legacy transaction codec, and System/Token/ATA instruction builders (Solana method)
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

A daily cloud routine (`sdk-delta-watch`, manage at https://claude.ai/code/routines) watches these SDKs for upstream changes we may need to port: it diffs new commits since the watermark in `.sdk-watch.json` (committed at repo root) over the protocol-critical paths, judges parity against our Elixir impl, and auto-files `security`-marked rmap tasks for genuine gaps (the pattern that caught mpp-rs #299 → Task 65 and mppx #577 → Task 46). If it filed tasks but couldn't run `rmap render` in the cloud env, run `rmap render` locally to re-sync ROADMAP.md.

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
gh api repos/ZenHive/mpp/code-scanning/alerts                    # CodeQL (if enabled)
gh api repos/ZenHive/mpp/secret-scanning/alerts                  # leaked secrets
```

**🚨 `security-advisories` is the one most easily missed and the highest-stakes.** Privately-reported vulnerabilities submitted through Private Vulnerability Reporting land **only** in the Security → Advisories tab — they do **NOT** appear as Dependabot alerts, code/secret-scanning alerts, or in the notifications inbox (advisory submissions email repo admins, they don't generate a `reason: security_alert` inbox item). The four scanning endpoints cover *automated* findings; `security-advisories` covers *human-reported* ones. **Always query it.** As of 2026-06, three reporter `kai-kka` gas-draining advisories (critical/high/medium) sat in `triage` for up to 12 days before being noticed precisely because earlier sweeps skipped this endpoint.

Triage states to act on: `triage` (new, unreviewed), `draft` (being worked). Reporter, PoC, and affected-version detail are at `gh api repos/ZenHive/mpp/security-advisories/<GHSA-id>`.

### Security-parity ledger + disclosure convention

`docs/security-parity.md` is the standing record of every upstream-SDK security advisory / fix mapped to our parity status (✓ have / 📋 tracked-in-Task-N). It and the `sdk-delta-watch` routine keep upstream security work *tracked*, not silently assumed. **🚨 Disclosure rule — this repo is public, so `tasks.toml` / `ROADMAP.md` / `docs/` are all published.** Therefore: a parity *gap* that is unfixed and exploitable is NEVER filed as a public `security` rmap task or a public ledger row — that would hand attackers a checklist for a deployed money library. Unfixed-gap detail goes to a **private draft GitHub security advisory** (Security → Advisories, the same channel inbound PVRs use); the public ledger holds only ✓/📋 rows plus a generic open-item count. When a fix ships, the item moves to a ✓ row and the advisory is published with the patched release (coordinated disclosure, per `SECURITY.md`). The `sdk-delta-watch` routine follows the same split: parity-confirmed → ✓ row; genuine gap → private advisory, never a public row.

## Git Commit Configuration

**Configured**: 2026-03-25

### Commit Message Format

**Format**: imperative-mood

#### Imperative Mood Template
```
<description>
```
Start with imperative verb: Add, Update, Fix, Remove, etc.
