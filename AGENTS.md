<!-- Auto-generated from CLAUDE.md by claude-marketplace/scripts/sync-agents-md.sh — do not edit manually -->

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

<!-- @-import: ~/.claude/includes/critical-rules.md -->
## 🚨 ANSWER IN SHORT TEXT — ALWAYS

Every answer — explanation, proposal, pushback, summary — is short, pointed text. Too short beats too long: unclear → the user asks. Too long → the user often doesn't read it, which is worse.

## 🚨 BE A REAL PARTNER, NOT A YES-SAYER

**Challenge ideas that seem wrong, risky, or suboptimal.** Not every user request is a good idea. A real partner pushes back when it matters.

- **Flawed approach:** "I'd push back on this because..." — don't just comply
- **Better alternative exists:** present it with reasoning, not "have you considered..."
- **Scope too big or small:** flag it. "This feels like it's solving the wrong problem" is valid
- **Wrong assumptions:** correct them — after verifying yours are right (gate below)
- **Tone:** direct and respectful, not combative. Disagree like a trusted colleague
- **When to yield:** if you've made your case and the user still wants to proceed, commit fully. Pushback ≠ blocking

### Pushback Gate — Understand Before You Challenge

**Misinformed pushback is worse than no pushback.** Earn it:

1. Restate the user's mechanism + goal in two sentences they'd endorse. Can't? Ask — don't challenge.
2. "I understand X, disagree because Z" is partnership. "Seems wrong" without naming X is noise.
3. Objection reduces to "not how software is normally built"? Not an objection — see next section.
4. Pushback strength scales with understanding depth. Partial understanding → questions only.
5. Pushback is ≤3 sentences. State the disagreement, not an essay — the user asks if they want more.

### Think As an AI, Not Only As a Developer

The user builds AI-native systems. Developer instincts produce systematically wrong pushback here.

**The design question: judgment or mechanics?**

- **Judgment** (interpret meaning, classify failures, diagnose, decide done/worth/fault, fuzzy match) → an AI does it better than code. A regex / cond-branch / disposition table for a judgment call IS the bug.
- **Mechanics** (counters, timers, git, process spawning, deterministic checks) → code.

Developer instincts that are wrong in this paradigm — drop them:

- "Should be deterministic / unit-testable" — for judgment, non-determinism is the design
- "LLM call is slow / expensive / unreliable" — the alternative is a procedural approximation wrong at every edge
- "Parse / normalize / schema the output" — AI consumers read raw; normalization layers break
- "Handle this edge case in code" — every hard-coded case removes a judgment from the AI

Precedent (cite, don't relitigate): harness Tasks 153–163 — every run-lifecycle bug was judgment-as-procedural-code; the fix was deletion (−1,219 lines), not improvement.

When designing or reviewing, ask: **"which parts would an AI do better than code?"**

## 🚨 SURFACE THE OVERRIDE — DON'T DECIDE SILENTLY

**When you make a judgment call that overrides the user's discernible intent — defer it, build it differently, skip it, "I know better" — make the call visible in one line *before* you act. Never act silently and rationalize afterward.**

The failure mode: you disagree, act on your own read, and wrap it in fluent reasoning after the fact — so the user finds the override at discovery time, not decision time. A stronger model makes this *worse*: the rationalization is more eloquent, so the silent override is harder to spot, not easier.

The check, before the trained pattern fires — is this **clarity**, or **habit / wanting-to-please / fear-of-being-wrong**? Only clarity earns a silent decision; the other three get surfaced.

- **Surface ≠ block.** State it as an interruptible assumption — "doing X instead of Y because Z — say if wrong" — then proceed. Don't gate on a question (that's the *opposite* failure).
- This is the override-form of "assumptions, don't gate on questions" (response-conventions), and the gap between input and output where you ask *where the response is coming from* before committing to it.

## 🚨 NEVER START THE PHOENIX SERVER

The Phoenix server is always already running. Never run `mix phx.server` via Bash. Assume localhost:4000. User starts/stops manually. To verify behavior, ask the user to check the browser.

## 🚨 ALWAYS WRITE TESTS

Every feature MUST have tests, even if the spec doesn't mention them. Unit tests for context functions, integration tests for LiveViews, tests for all CRUD/validations/error cases/edge cases (nil, empty, boundary). A feature without tests is not complete.

## 🚨 RAISE COVERAGE BEFORE MUTATING

**Before any code-changing task on an existing module, that module's `mix test.json --cover` percentage must be at the target tier:**

- **≥80%** for standard business logic
- **≥95%** for critical business logic (signing, money handling, cryptographic operations, low-level encoders, security-sensitive parsers)

If below tier, raise coverage **first** — write the missing tests, confirm the gate passes, then implement the change. The new tests are part of the task, not a follow-up.

**Scope — code-changing mutations only.** Exempt:
- Doc-only edits (`@doc`, `@moduledoc`, inline comments, README, CHANGELOG)
- Formatting, whitespace, alias reordering, autoformat-driven changes
- Pure renames (variable, function, module — no behavior change)
- Typo fixes in strings, log messages, error messages

The gate is a "do I have a safety net before I touch this?" check; writing the missing tests also surfaces the module's actual contract.

**How to apply:**
1. Run `mix test.json --cover --quiet --output /tmp/cov.json` (or `--cover-threshold 80` for a hard exit).
2. Inspect the touched module's percentage: `jq '.coverage.modules[] | select(.module == "MyApp.Foo")' /tmp/cov.json`.
3. If below tier, write tests for the uncovered lines until the gate passes — even if those lines aren't the ones you came to change.
4. Then implement the original mutation.

**Tier classification:** "critical business logic" is project-defined. When in doubt, treat anything that handles money, signs/verifies, encodes/decodes wire formats, or enforces authorization as critical (95%). Plain data transforms, UI glue, and reporting code are standard (80%).

## 🚨 NEVER HIDE TEST FAILURES

**TESTS THAT HIDE ERRORS ARE WORSE THAN NO TESTS AT ALL.** A test that silently passes on errors is lying and ships the bug it was meant to catch.

The anti-pattern in all its forms — `{:error, _} -> assert true`, a catch-all `{:error, _} -> :ok`, or `IO.puts(...)` then `assert true`: any clause that makes *every* outcome pass. The fix is always an explicit `flunk` on the unexpected:

```elixir
case result do
  {:ok, data} -> assert is_map(data)
  {:error, :insufficient_balance} -> :ok          # this specific error is expected
  {:error, other} -> flunk("Unexpected error: #{inspect(other)}")
end
```

**THE RULE:** if you don't know what error to expect, DON'T write the test yet — explore via Tidewave first, then assert. A test must FAIL when the code is wrong.

**Integration tests — never skip silently on missing credentials.** A suite reporting "0 failures" that ran 0 tests is lying. Don't `:skip` in `setup`; let the test run and `flunk()` at the top with a multi-line message listing the missing env vars, the exact `export` commands, and the URL to get them.

## 🚨 FIX HOOK-FLAGGED ISSUES ON FILES YOU TOUCH

**When our hooks flag issues on files you touched, just fix them — including pre-existing flags unrelated to your change.** Don't plan around it, don't ask permission, don't burn tokens discussing whether to. Hook fires → fix → re-run → stage.

Applies to every hook-driven check (credo, format, dialyzer, doctor, sobelow, ex_dna, etc.). Scope is **only the files your change touched** — not the whole project. User pre-approves the broader scope so each fix doesn't need a clarifying question; debt accumulates across sessions otherwise, and a touched file ending dirtier than baseline makes the next session noisier.

**How to apply:**
- Pre-existing flags in your touched file count too: alias ordering, unused vars, refactor opportunities, `TODO:` formatting.
- Generated files → fix the generator, not the output.
- Don't move the fix to ROADMAP or a follow-up task. It happens in this commit.
- **Don't manually re-run a check the hook just ran on the same files.** Act on the hook output directly — re-running `mix test.json` / `mix credo` / `mix dialyzer.json` / `mix sobelow` / `mix precommit` on the file set the hook already graded is duplicated work. Full-suite re-runs earn their cost only before a PR/merge, after `mix deps.get` or a branch switch, or when the user asks. See `~/.claude/CLAUDE.md` § "Don't Re-Run Hook-Driven Checks on the Same Files" for the host-specific rule.

## 🚨 READ TO THE ANSWER — DON'T USE THE RUNNER AS AN ORACLE

**Reason to the fix by reading code; run once to CONFIRM — don't run to DISCOVER.** The failure mode: change → run suite → read one failure → fix one thing → run again, N times, each cycle paying the compile tax for a problem one read surfaces whole.

- **Read the code path before the test that exercises it** — front-load the model, don't learn the function's shape from a failing assertion three fixes later.
- **Treat a failure as a SURVEY, not a single fix** — enumerate every plausible cause from the output + one read, fix them in a batch, run once.
- **Verify handoffs/summaries against ground truth** — a compaction summary or another session's "X is already wired" is a hypothesis; `grep` the load-bearing claim before acting on it.
- **Trust the hooks** — per-edit checks already graded the file; re-running is wasted cycles.
- **Under a flaky terminal, go sequential-and-simple** — one command → write to a file → Read it; no parallel batches of *dependent* calls, one early failure cancels the round.

## 🚨 FLAKY TESTS & TEST-RUN TOKEN ECONOMY

**Elixir suites are non-deterministic at the edges (async / GenServer / Port / LiveView / supervision), and `mix test` is the biggest time/token sink in a session.** Four disciplines:

- **A small red count is a flaky HYPOTHESIS, not a regression — until confirmed.** 1–2 failures out of hundreds, in a file your diff didn't touch → suspect flake. Re-run ONLY that test in isolation (`mix test.json <file>:<line>` or `--failed`): passes alone → flaky, proceed; fails deterministically → real, fix it. One isolated re-run is the whole investigation — never repair-loop or block a merge on an unconfirmed flake.
- **NEVER `Process.sleep` to "fix" a flake.** Sleeps mask the race, slow every future run, and still ship it (passing *most* of the time is the same lie as hiding a failure). Synchronize instead: `assert_receive`/`refute_receive` with a timeout, `Process.monitor` + `assert_receive {:DOWN, …}`, `start_supervised!`, or poll-until-condition.
- **Don't re-run a full suite to grade already-graded code.** Per-edit hooks already ran `test.json` on touched files; a harness run already graded the stack green. A disjoint cherry-pick / clean merge of verified code needs no `precommit.full` re-run. Full suite only via a non-graded path — manual editor edits, a rebase with overlapping hunks, a branch switch, after `mix deps.get`.
- **Bound test output — never let coverage hit context.** `mix test.json --cover` dumps the entire per-module JSON (tens–hundreds of KB). Always `--output /tmp/cov.json` + `jq`; triage with `--max-failures 1` / `--failed` / a single `file:line`; drop `--cover` if you only need pass/fail.

## 🛑 MINIMALIST APPROACH FIRST

**Do exactly what is asked — nothing more, nothing less.**

- **NO** proactive features or improvements unless explicitly requested
- **NO** additional error handling beyond what's needed
- **NO** extra validation, refactoring, or documentation files
- **ALWAYS** ask before adding anything not explicitly mentioned
- **IF UNCLEAR:** Ask "Should I also do X?" before proceeding

### BUT: Minimalism Is Not Incomplete Work

**"Start minimal" means no EXTRA features — not skipping items the task implies.**

When a task says "define unified data structs," the scope is ALL structs the system needs, not "the 7 I can think of." When a source of truth exists (e.g., `method_defs/0` listing 241 methods, each implying a return type), audit it — don't cherry-pick.

**The pattern to avoid:**
1. Task says "build X for all Y"
2. Claude scopes to "build X for the obvious Y" (filtering/cherry-picking)
3. Later session discovers the gap and adds a fix-up task
4. The fix-up task does what should have been done originally

**How to catch it:**
- If the task mentions "all," audit the source of truth — don't rely on what comes to mind
- If a data source defines N items, process N items (or explain why some are excluded)
- If you're writing "for now we'll just do these 7" without being asked to limit scope — STOP. That's scoping out, not starting minimal.

**Minimalism guards against:** adding caching when nobody asked, building admin UIs "just in case," over-abstracting simple code.

**Minimalism does NOT mean:** skipping half the items in an enumerable set, cherry-picking "common" cases from a known complete list, or deferring clearly-implied work to future tasks.

## 🚨 NO PSEUDO-RIGOROUS HEDGING

**Don't gate user-requested work behind invented "evidence requirements" you cannot satisfy.**

You have no consumer telemetry. No usage counts. No signal about whether a feature will be called 12 times or 1200 times. So phrases like *"demand for this is unproven"*, *"we should wait until N consumers ask for this"*, *"is this widely needed?"*, *"only worth doing if a Nth+ use case is imminent"* are **risk-aversion theater**, not analysis. They sound rigorous; they're hedging.

- In single-developer codebases or focused teams, the developer IS the demand signal. They asked. That's the data point.
- "Wait for usage data" is a corporate-flavored instinct that doesn't apply to small teams. There's no telemetry pipeline; there's the user in front of you.
- It gaslights the user: their request is reframed as "unproven need" requiring further validation. They have to argue for what they already asked for.

**Distinguish from minimalism (the section above):**
- Minimalism = don't add features the user **didn't ask for**.
- This rule = don't refuse / defer features the user **did ask for** by inventing evidence requirements.

**Distinguish from dependency-gating (the *legitimate* "wait"):** parking work behind a **named technical / legal / market-scope trigger** with a concrete unblock path — a missing dep, an unactivated market, an **additive change that's migration-cheap to add later** — is NOT hedging. Hedging invents *demand* evidence you can't get ("wait until someone wants it"); dependency-gating cites a *structural fact* ("park until market MY activates — it's an additive `@by_country` member, so deferring forecloses nothing"). The STOP-list below targets the former, not the latter. **Build-now pressure is for *foreclosing* decisions** (annoying/migration-heavy to reverse — e.g. a geo dimension threaded through schema); an **additive** change carries no such pressure, so "build it now because one instance happens to be live" is overfit, not rigor. Reflexively reaching for build-now to avoid *looking* like you're hedging is the same theater inverted.

**Failure-mode test — if you're about to write any of these, STOP:**
- "Demand for X is unproven"
- "We should wait until..." *(unless it names a concrete technical/legal/market-scope trigger with an unblock path — that's dependency-gating, not hedging)*
- "Is this widely needed?"
- "Only worth doing if a Nth+ case is imminent"
- "Bet on usage data before building"

You don't have data either way. The honest framing is: *"I don't know if you'll use this 12 more times — that's your call."*

**What to do instead:**
- Name the **actual technical risks** (e.g., "the macro might grow more knobs than the duplication it removes," "this couples us to an upstream that breaks every release," "the test surface explodes at N+1 cases"). Those are real costs you can reason about.
- Cite **concrete precedents** when scoring complexity (see `development-philosophy.md` "Cite Ecosystem Precedents Before Crying Complexity"). Generic "this could grow" without naming a specific failure pattern is the same hedging by another name.
- If the task genuinely scores low on benefit/usefulness, score it that way honestly — don't smuggle a demand-speculation into the U/B numbers and pretend it came from analysis.

**Scope extends to task `body` fields and scoring justifications, not just live responses.** Same hedge phrases written into a task's `body` to justify B/U — "table-stakes", "increasingly expected", "now standard", "buyers expect", "competitors are starting to", "modern apps all do" — inflate the score the same way they inflate a response. Required instead: named consumer evidence (named partner asked, named competitor lever, measured conversion uplift) OR honest low score. Enforced at task-creation time by `task-writing.md` § Pre-Creation Gate (question 5).

## Git Commit / Push / PR-Create — Allowed by Default

Committing, pushing, and opening PRs are normal parts of the work — do them without asking when the task calls for it (the agent-gate / auto-land workflow, worktree branches, and shared default branches alike). Announce the action in one line, then take it; the diff and push are the recap.

The only residual caution is the general one for any hard-to-reverse action: **rewriting already-pushed history** (force-push, amend/rebase of shared commits) can destroy others' work, so confirm before doing that on a shared branch — not because commits need permission, but because history-rewrite is irreversible.

### 🚨 STAGE PATH-SCOPED — THE WORKING TREE IS SHARED, YOU WORK IN PARALLEL

**Never assume the working tree or index holds only your changes.** Unrelated WIP sits in the tree, the index may already hold files another session `git add`ed, and an auto-land harness is a second committer. A blanket stage sweeps all of it into *your* commit.

- **NEVER `git add -A` / `git add .` / `git commit -a`.** Stage explicitly: `git add <path> …`, or commit path-scoped: `git commit <path> …`. The commit then carries exactly the paths you name, regardless of what else is dirty or staged.
- **Verify the staged set before every commit** — `git diff --cached --name-only`. If a path you didn't touch is there, it's someone else's; don't commit it.
- **A pre-commit hook tripping on a file you didn't touch means foreign WIP is dirty, not that you must fix it.** Path-scoped-stash ONLY the foreign paths (`git stash push -- <their-paths>`), make your clean commit, `git stash pop`, then **re-stage whatever was staged before** so the other session's index is exactly as you found it. Never format, fix, or commit work that isn't yours to clear a hook.
- **Untracked dirs/files you didn't create:** leave them — don't `-u`-stash or `add` them.

The failure mode this guards: you path-scope your *commit* correctly but `git add -A` first, or you stash `-u` to clear a hook and bury another session's staged work. Both corrupt parallel work silently.

## Shell Safety

`rm` (including `rm -rf`) is permitted — the hook allows it; the old blanket ban caused more friction than it prevented. One habit, not a gate: before an irreversible delete, glance at the target — confirm the path is what you intend (no unexpanded `$VAR`, no wildcard catching more than you mean, not a path you didn't create or weren't asked to remove). `git rm` for tracked files keeps the removal in the diff. (Destructive *dependency / build* commands — `mix deps.clean`, `rm -rf _build` — stay consent-gated below, for slow-recovery reasons, not safety.)

## 🚨 NEVER RUN DESTRUCTIVE DEPENDENCY COMMANDS

**Never run these without explicit user consent:**

- ❌ `mix deps.clean` / `mix deps.clean --all` — deletes compiled deps; slow recovery
- ❌ `mix deps.unlock --all` — unlocks all versions
- ❌ `rm -rf _build` or `rm -rf deps` — nukes build artifacts
- ❌ `mix clean` — removes compiled app files

**What to do instead:**
- Compile error → just retry `mix compile` or `mix test`
- Specific dep issue → `mix deps.compile <dep_name> --force`
- Most "corrupt cache" issues are transient glitches

Ask before running any destructive command.

## 🚨 Integrity and Accuracy

**Never fabricate information, experience, or data.** When providing technical guidance:

- **Honest about sources:** distinguish codebase observations, general knowledge, best practices, and speculation. Never claim production experience you don't have or invent metrics/timelines/stats.
- **No false authority:** don't claim "we learned" without repo evidence; don't state "after X years in production" without evidence; use "typically/often/may/could" when uncertain.
- **Document uncertainty:** identify what you don't know, suggest validation paths, provide ranges over false precision.
- **Trace sources:** "Based on the code in file.ex...", "According to docs/FILE.md...", "Common practice in Elixir...", "This suggests..."

False technical claims cascade into bad architectural decisions, wasted resources, and damaged trust.

## 🚨 RESEARCH BEFORE ASSERTING ON NICHE TECHNICAL CLAIMS

**When the question lives outside reliable training coverage, research proactively — without being asked.** The failure mode is asserting from training-bias confidence on specs/protocols/niche APIs the model never deeply absorbed. Codex fetches reference implementations to verify; Claude defaults to "answer from memory." Close the gap.

**Research (WebFetch a known URL, WebSearch to find one) when the topic is:**
- **Wire formats / encodings** — RLP, ABI, SSZ, Protobuf, BLS, BIP-32/39/44, EIP-712, CBOR, ASN.1/DER. Fetch the spec or a reference impl before claiming byte order, length-prefix, padding, or canonical form.
- **Protocol details** — EIPs, RFCs, JSON-RPC shapes/error codes, opcode gas, exchange API quirks (signature canonicalization, error envelopes, rate-limit headers).
- **Niche / recent library APIs** — guessing signatures, return shapes, version-pinned breaking changes. If you'd write `# probably something like`, go fetch the docs.
- **Cross-implementation edge cases** — "what does X do when Y is malformed?" → check ≥2 reference impls; one impl's behavior can be a bug, agreement across two is the spec in practice.

**Don't research (use memory):** pure Elixir/OTP, stdlib, mainstream Phoenix/LiveView/Ecto/Ash, generic REST/HTTP/JSON/SQL/shell, anything already in the codebase / hex docs pulled this session / an imported CLAUDE.md.

**How to apply:** prefer WebFetch when the canonical URL is known (the EIP/RFC/hex doc/reference-impl path), WebSearch to find one; **cite what you fetched** — the citation is part of the answer, name both impls for cross-checks. If a fetch fails or is ambiguous, say so and lower confidence — don't fall back to "well, I think…" silently.

## 🚨 NO EVASION — SIT WITH THE HARD THING

**When you hit something difficult, do NOT optimize for "appearing productive" by moving to easier work.** The most common failure mode: hit a wall → silently move on → user discovers the gap later.

### Evasion Patterns (don't use without explicit user approval)

**Task abandonment:**
- "let's move on to", "we can defer this", "skip this for now"
- "let's come back to this later", "we can revisit this", "let's table this"

**Scope reduction without asking:**
- "to keep things simple, I'll skip", "for brevity, I won't"
- "that's out of scope", "not strictly necessary"

**False completion:**
- "that should be enough", "the rest is straightforward"
- "I'll leave the rest as an exercise", "the pattern is clear enough"

**Deflection to user:**
- "you might want to", "you could manually", "you'll need to handle"
- (Sometimes legitimate — but often evasion disguised as helpfulness)

### What To Do Instead

1. **Stay with it.** If it's hard, say "this is hard because X" — don't silently move on
2. **Flag blockers explicitly.** "I'm blocked on X because Y. Options: A, B, or C."
3. **Ask before deferring.** "This is taking longer than expected. Should I continue or switch?"
4. **Never write workarounds silently.** If tempted to add a fallback/default/nil-guard for missing data, ask: should this come from upstream? If yes, STOP and report it
5. **Incomplete work gets a TODO.** If you must move on, leave a tracked TODO — not a silent gap

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

**Default: dispatch every pending rmap task whose dependencies are satisfied.** Hand-build only what harness cannot yet do:

- Scaffolding that reshapes harness runtime (supervision tree, dep stack, Endpoint) **while the run lifecycle itself is in flux**
- Tiny tasks — ALL of (a) D≤2, (b) ≤30 LOC across ≤3 files, (c) no harness-surface change
- UI / LiveView / heex / CSS — headless agents idle-timeout without visual reward; use tidewave + browser
- A harness gap — file via `rmap new`, fix harness, re-dispatch; do not work around by hand-building

### Running a Task

**Prerequisites:** long-lived harness BEAM (`iex -S mix` in the harness checkout), target project registered in `Harness.ProjectRegistry`, clean `git status` on the target's dispatch branch (runs fork worktrees off `HEAD`).

**Three dispatch paths** (prefer top to bottom):

1. **Native MCP — default.** `dispatch-task` (fire-and-forget) or `dispatch-await` (blocks until settle) against `http://localhost:4018/harness/mcp`. Observe via `dispatch-status`, `dispatch-transcript`, `dispatch-verdict_detail`. `scrub_anthropic_key: true` (default) forces subscription OAuth over inherited `ANTHROPIC_API_KEY`.
2. **Tidewave `project_eval` — escape hatch.** Struct-level control the flat tools don't expose (`retry_policy`, fail-over adapter lists, `subscriber: self()`). Run persists to `Harness.ResultStore` even when the eval process exits.
3. **`mix run` driver script — fallback.** Full transcript + reviewer report to terminal. See harness repo `docs/dogfooding-workflow.md` for the canonical template.

> **Never start a second driver BEAM while runs are in flight.** Boot-time worktree sweeps can prune live sibling worktrees. Drive all parallel batches from one long-lived node.

**In-flight idempotency (Task 286):** a second `dispatch-task` / `dispatch-bundle` of the same `{project, task_id}` while a non-terminal run exists returns the **existing** `run_id` (Oban `conflict?: true`), not a duplicate — a retried dispatch is safe and free.

**Write-set serialization (Task 292):** `dispatch-bundle` and cron ready-set dispatch compute each task's `touches ∪ files_to_modify` before enqueue. Tasks with overlapping write-sets are logged and serialized into later waves instead of fanned out together. Callers no longer hand-dedupe ready sets; they must keep `touches` / `files_to_modify` accurate because harness does not infer paths from task prose.

**Renderable vs executable:** `rmap delegate --to` renders native prompts for all six harness adapters (`claude`, `codex`, `cursor`, `grok`, `antigravity`, `pi`). `droid` renders but has no harness adapter — rejected at ingest. All six shipped adapters declare `worktree_isolation: true`.

### Routing & Model Management

- **Resolve `assignee` + `model` from facts, not by reading code.** `routing-brief` is the thin task-writer index: dispatchable agent roster, each agent's standing model (`Config.agent_model/1`), model availability/blocks, and per-agent KPI rollups — every metric carries `n`, no ranking. A model-capable agent with no configured model shows `model: nil, model_required: true`.
- **Scout routing (advisory).** `dispatch-recommend` returns the cross-family scout AI's per-facet `:exploit` pick (with rationale) or a safe `:explore` / `:fallback_no_data` when a facet is unmeasured; `dispatch-assess_facets` forces a fresh scout assessment. The caller decides whether to dispatch the pick — legacy composite scores are not used for routing.
- **Model is required, never defaulted.** Implementer precedence: **task `model` → `{:agent_model, agent}` → REJECT** (`{:model_required, agent}`) — harness never falls through to the CLI's ambient default. The **reviewer has no task-pin axis**: its model comes solely from `{:agent_model, agent}` for the reviewer adapter's agent (`Run.reviewer_model/1`), and a model-capable reviewer with no configured model is rejected *before* the reviewer spawns. `antigravity` (no `--model` flag) is the lone model-incapable exemption.
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

Failed runs retain the worktree at `result.worktree_path` for inspection. Approved runs keep branch `harness/<run-id>` after worktree teardown. Use `dispatch-verdict_detail` for the reviewer report, ratings, checks, concerns, warning flag, and `reviewer_diff_size` — no harness-run mechanical per-check stdout.

**The verdict artifact** `.harness/review.json` is `{verdict, report, checks, concerns, facets, skills, ratings}`: `verdict` (`approve`/`reject`) is the gate; `report` is the reviewer's prose; `checks` is the reviewer-written record of commands run and their pass/fail claim; `concerns` is the reviewer's self-flagged caveat list; **`facets`** (open-vocabulary routing KEY — the kind of task) and **`skills`** (v0_13 two-axis rubric, routing VALUE) feed per-facet capability routing; `ratings` is the legacy flat-score fallback. Approved runs with non-empty concerns or a reviewer-authored failed check surface a warning fact; harness never auto-blocks or classifies prose. The artifact lives under `.harness/` (excluded from staging) so it never rides in the deliverable commit.

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

**🚨 First, confirm the run actually *didn't* land — check `origin`, not your local checkout.** Under `landing_policy: :auto` the lander pushes to `origin/<target>` and **deliberately never touches your local checkout** (it ff-pushes from a detached worktree). So after an autonomous land your local `tasks.toml` is **stale**: it still reads `in_progress` for a task the lander already marked `done --shipped-in` on origin. **Reading that stale local status as "the run didn't land" is the trap** — it triggers a wasteful reset-to-`pending` + re-dispatch that *duplicate-lands already-shipped work*. Before concluding anything from task status, `git fetch origin <target> && git rebase origin/<target>` (the existing "Sync development before committing" rule) or read ground truth directly:
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

### Autonomous Landing

Projects with `landing_policy: :auto` and `target_branch`:

1. Approved run enqueues one job on serialized `landing_<name>` Oban queue (limit 1)
2. `Harness.Lander.land/1` rebases `harness/<run-id>` onto `origin/<target>` in a detached worktree
3. **ff-pushes without re-verification** — the reviewer already gated the work
4. Successful push enqueues post-merge audit; advances rmap (`done --verified --shipped-in <sha>`)

Conflict / push-rejected retains the branch for repair — never lands red. Witness notification (read-only sink) alerts the operator; it is **not** a merge gate.

**🚨 Settle ≠ landed — don't conflate the two signals.** `dispatch-await` / `dispatch-await_runs` block until **reviewer settle** (`state: :done, verdict: approve`, or `:failed`), which fires the *moment the reviewer approves* — **before** the serialized `landing_<name>` job rebases and ff-pushes. So an `approve` from `await_runs` means "approved and *queued* to land," **not** "on `origin/<target>`." There is **no blocking await-landed tool**; landing is async and surfaces via the witness sink (`Harness.Notification.FileSink` tailing `~/.harness/settled.jsonl`, or `CommandSink`). To gate a next wave on the base actually moving forward, await settle **then** confirm the land against origin once (`git fetch origin <target> && git log --oneline origin/<target>` for the `task <id> -> done (shipped …)` commit) or consume the witness event — never treat approval as landed. This is the same root cause as the duplicate-land trap above, seen from the dispatch side: a poll loop watching `origin` for the landing commit is a workaround for a *fixed* `await_runs`, not a substitute for it — await settles, origin confirms the land.

**Cron manual-approval mode.** A per-project cron poller in `:auto` mode dispatches unattended; in `:manual` mode it **parks** each dispatch decision instead of enqueuing — drain the parked decisions with `dispatch-pending` and approve them with `dispatch-approve`, keeping the orchestrator in the loop for autonomous polling.

### Orchestrator Loop — the Architect Seat the Per-Task Reviewer Can't Fill

The sections above document the *mechanisms*; this is the **continuous loop** the driving AI runs across waves:

```
plan wave → dispatch → await settle → confirm land on origin → run integration suite on the landed base
          ↑                                                     + review whole surface vs roadmap intent & domain invariants
          └── reconcile rmap ← encode any whole-surface finding as a criterion/test ←┘
```

Each arrow reuses an existing mechanism — don't restate them here: *await settle* (§ "Settle ≠ landed"), *confirm land on origin* (§ "Recover, Don't Redo" → the duplicate-land trap), *reconcile rmap* (the lander already advanced `done --shipped-in` under auto-land — verify, don't double-write), *next wave* (§ "Parallel Dispatch" + write-set serialization).

**🚨 Three review seats, each blind where the next sees — the orchestrator seat is mandatory, not optional.** The per-task reviewer gates *one diff against one task* and is **structurally blind** to two defect classes that land clean through it (worked evidence: delta_calc tasks 24/25/26, see its `## Review Blind Spots` / `## Domain Invariants`):

| Seat | What it sees | What it CANNOT see |
|---|---|---|
| **Per-task reviewer** (cross-family, the gate) | one diff vs one task's acceptance criteria + mechanical checks, in an isolated worktree off a base | the whole surface; domain ground truth |
| **Post-merge audit AI** (best-effort) | cold build of the merged commit range; hygiene | whether a domain constant is *wrong*; roadmap-intent fit |
| **Orchestrator** (the architect seat — you) | whole integrated surface vs roadmap intent + domain invariants across all landed waves | — (this is the seat of last resort) |

The two blind classes, both real-correctness, both passing every per-task check:

- **Domain ground truth** — a wrong venue constant (`@funding_periods_per_day 3`, overstating Deribit's hourly funding ~8×) is internally consistent and fully tested *because the golden was computed with the same wrong constant* — coverage ratifies the bug. The reviewer has no signal; that knowledge lives in the architect's head.
- **Cross-module global invariants** — write-set-disjoint parallel dispatch means two worktrees can each define `project_payback_timeline` and neither review sees the other; the collision only exists once both have landed on the integrated base. Only a whole-surface seat catches it.

**🚨 Run the integration suite on the landed base — this is NOT redundant with per-task review.** After each wave lands, run the project's full check (`mix ci` / `mix precommit.full`) on the freshly-landed `origin/<target>`. The per-task reviewer ran its checks in an *isolated worktree off an earlier base, before sibling waves landed* — cross-module breakage doesn't exist until multiple landed diffs coexist. This generalizes the manual-landing-only "run the project's check command on target after last merge" (§ "Parallel Dispatch") into a standing per-wave step.

**Two framing guards — keep this consistent with the harness mantra:**

- **It's an agent seat, not harness code.** The mantra ("count facts in code; judge with an AI") forbids *harness* computing meaning — it does **not** forbid the orchestrator AI from reviewing the whole surface or running the suite. This adds no mechanical gate to harness; it's judgment in an agent, which is exactly where judgment belongs.
- **The output crystallizes into encoded invariants — don't leave it a manual sweep.** When the architect seat catches a whole-surface or domain defect, the highest-value move is not the manual catch — it's pushing the rule into an **acceptance criterion or a manifest-wide CI test** (the delta_calc rule) so the per-task gate absorbs that class going forward. Orchestrator review *feeds* the criteria/CI; it must not become a permanent re-review of every diff. A finding caught twice by hand is a missing test.

### Portfolio Conventions

- **Agent does not commit unless asked.** Staged-but-uncommitted is the default handoff between implementer and reviewer sessions (`workflow-philosophy.md` § "Implementer / Reviewer Handoff"). Harness runs commit agent work to `harness/<run-id>` automatically — that is harness's deliverable branch, not the operator's main checkout.
- **Witness notification is sakshi (read-only).** Landing outcomes notify via configured command sink; the sink grants no merge capability. Human operator reviews blocked/conflict outcomes — harness does not silently force-push past conflicts.
- **`check_command` is a hint to the reviewer.** Free text (e.g. `"mix precommit.full"`) — the reviewer runs and judges it; harness does not execute it mechanically.
- **The cross-family reviewer reads `AGENTS.md`, not your Claude skills/includes.** `AGENTS.md` is generated from `CLAUDE.md` by `claude-marketplace/scripts/sync-agents-md.sh`, which recursively inlines every `@`-import. **Regenerate it after any `CLAUDE.md` change** (`bash ~/_DATA/code/claude-marketplace/scripts/sync-agents-md.sh`, or `--dry-run` to preview) so the reviewer gates against current rules — a stale `AGENTS.md` makes codex/cursor/grok judge against rules you've already changed. **`--check` is the freshness gate** — it re-renders in memory and exits non-zero if `AGENTS.md` has drifted (diffs rendered output, not mtimes, so it catches drift in transitive `@`-imports too); wire it into CI / a pre-commit hook / the `check_command` so staleness fails loudly instead of silently. Consequence under Opus-4.8 skill-on-demand: once `CLAUDE.md` slims to the eager floor, reviewer-critical facts that *were* carried by eager includes (the `check_command` gate; that `mix test.json` / `mix dialyzer.json` emit JSON **by design** — parse for real failures, never flag the envelope; plain `mix dialyzer` is authoritative when the JSON encoder can't serialize a warning) no longer reach `AGENTS.md` via those imports. Put them in a **self-contained `## Toolchain & check commands` section in `CLAUDE.md`** so they survive the slim-down and flow into `AGENTS.md` on regen (ref: `tapakly/CLAUDE.md`, `ccxt_extract/CLAUDE.md`).
- **Delegation roster — opus last, and don't over-default to codex.** When assigning a dispatchable task to a harness adapter, prefer the external agents — **cursor, codex, grok** — and reserve the **claude/opus** adapter for work that genuinely needs it (harness-surface changes, judgment-heavy review, tasks the cheaper adapters keep bouncing). Opus tokens are precious: spend them last, not by default. Mix adapters across a wave for review coverage. A repo may override the roster in its own CLAUDE.md.
  - **Observed failure mode: reflex-routing everything to `codex`.** Run ledgers skew heavily codex-over-cursor/grok. Actively spread `assignee` across all three; reserve codex for tasks it's genuinely scored best on, not as the default.
  - **`cursor` runs on Composer (`composer-2.5`) by default — and that's the data-backed pick.** Pin `model = "composer-2.5"` for cursor work: it's the cheapest cost-to-green in the ledger, and **every cursor capability KPI is measured on Composer** (it's a multi-model front-end, but the scores you'd route on reflect Composer, not whatever you pin). The `composer-2.5-fast` variant is cheaper still, but its budget routinely exhausts and the operator blocks it — so **`composer-2.5` (non-fast) is the standing default**; confirm the live id with `cursor-agent --list-models` / `model_availability-list_available_models cursor`. A heavier cursor model exists (`cursor-agent --list-models` lists `claude-opus-4-8-thinking-high` etc.) but is **not** the default, carries **no** capability data, and draws a *monthly Opus token budget that exhausts* (when spent the operator blocks it and routes Opus-grade work to codex/gpt-5.5) — pinning it *claims performance the ledger doesn't show*, so reach for it only with a concrete, named reason, not as the "design-heavy/Opus-grade" reflex. Model IDs churn; confirm with `cursor-agent --list-models`. **`model` is REQUIRED at creation for any non-`human` assignee** (`rmap new` rejects a model-less dispatchable task — "a dispatchable task must pin the LLM it runs on"; see `rmap.md` § "Pinning an LLM model"); "leave `model` unset for the agent default" does NOT work. Set `assignee` **and** `model` at task creation per `rmap.md`.

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


<!-- @-import: ~/.claude/includes/task-prioritization.md -->
## Task Prioritization Framework

### Scope

D/B/U scoring, status, and the `parallel` marker apply to **`roadmap/tasks.toml`** — the typed roadmap source `rmap` renders into `ROADMAP.md`. They are **not for `/plan` files** (single-task session blueprints). See `rmap.md` for the tool surface and `task-writing.md` for how to write a task's prompt body.

### Scoring Format

Each `[[task]]` in `roadmap/tasks.toml` carries `scores = { d, b, u }`. `rmap` computes `Eff = (B + U) / (2 × D)` at read time and renders `[D:X/B:Y/U:Z → Eff:W]` into `ROADMAP.md` — you set the three numbers, you never hand-format the bracket. Scales are 1–10.

| Eff | Tier |
|-----|------|
| ≥ 2.0 | 🎯 Exceptional ROI — do immediately |
| 1.5–<2.0 | 🚀 High ROI — do soon |
| 1.0–<1.5 | 📋 Good ROI — plan carefully |
| < 1.0 | ⚠️ Poor ROI — reconsider or defer |

`rmap` applies these exact tier thresholds; a `scored_at` older than 30 days renders an `Eff:W?` decay suffix.

### Scale (D / B / U)

| Value | Difficulty | Benefit | Usefulness |
|-------|------------|---------|------------|
| 1 | < 1hr, trivial | Minimal impact | Pure hygiene, invisible |
| 3 | Few hours | Minor/cosmetic | Infrastructure only |
| 5 | 1–2 days | Nice to have | Moderate unlock |
| 7 | 2–5 days | Significant QoL | Common question OR unblocks 2+ tasks |
| 9 | 1–2 weeks | Major improvement | Daily question AND unblocks 3+ tasks |
| 10 | Weeks, architectural | Transforms system | — |

**U vs B:** U captures unlock leverage, query frequency, and gap visibility. B captures impact magnitude. Infrastructure-only tasks score high D/B but low U — U prevents them from crowding out user-facing features.

### Exclusions (don't score)

🐛 bugs, 🔒 security, 📝 docs of completed work, ✅ in-progress tasks — always highest priority. In `tasks.toml`, bug and security work carry the `bug` / `security` markers.

### Status

rmap status vocabulary — transition via `rmap status <id> <state>`, never by hand-editing `ROADMAP.md`:

- `pending` — not started
- `in_progress` — being worked; record the `branch` in `tasks.toml`
- `blocked` — paused; requires a `blocked_reason`
- `done` — complete
- `superseded` — obsoleted by another task or a design change

`rmap render` turns these into glyphs in `ROADMAP.md` — the glyphs are output, not something you type.

### Pre-Implementation Gate

Before starting a code-mutating task on an existing module, confirm the module's coverage is at tier:

- ≥80% for standard business logic
- ≥95% for critical business logic (signing, money handling, cryptographic ops, low-level encoders)

If below, raising coverage is **part of this task** — not a follow-up to defer. See `critical-rules.md` § "RAISE COVERAGE BEFORE MUTATING" for scope guards (trivial doc/format/rename mutations are exempt) and the `mix test.json --cover` workflow.

### Parallel Work (`parallel` marker)

Mark independent tasks with the `parallel` marker (`rmap mark <id> +parallel`, or `markers = ["parallel"]` in `tasks.toml`). `rmap next --marker parallel` surfaces them. Before starting one: `rmap status <id> in_progress`, commit any pending work on the main checkout, then create a worktree at `~/_DATA/worktrees/<repo>/task-<id>/` (use the task id as the worktree ID). See `worktree-workflow.md` for the full convention.

### Ceremony Floor — When NOT to Open a Task

**Scope:** applies to **review-surface findings** (`review:code-review` pre-commit; `review:audit-review` post-merge). Discoveries during `/research`, `/plan`, or implementation follow the discovery-capture rules (file via `rmap new`) — not this floor.

Findings during code review or PR review have a ceremony floor below which they are NEVER tracked as `rmap` tasks. The roadmap-as-queue earns its overhead only when work spans sessions; an inline `defp` extraction does not.

| Finding shape                                         | Action                                              |
|-------------------------------------------------------|-----------------------------------------------------|
| ≤ 5 LOC, cosmetic / abstraction / nit                 | Push back inline OR drop — never track              |
| ≤ 5 LOC, **bug or correctness gap**                   | Push back inline — **never drop, never silently track** |
| > 5 LOC, cosmetic / abstraction / nit                 | Push back if cheap, else drop                       |
| > 5 LOC, **bug or correctness gap**                   | Push back inline                                    |
| Cross-session coordination cost (any size)            | rmap task candidate (`rmap new`) (e.g. public-API rename, schema migration, deprecation downstream repos must track) |
| Scope-affecting / architectural / breaks acceptance criteria | Surface for judgment (`discuss`-tier)        |

**Hard rules:**
- Bugs and correctness gaps are NEVER silently dropped, regardless of size or score. They are always pushed back inline.
- Cosmetic / abstraction findings ≤ 5 LOC are NEVER rmap task candidates unless they have cross-session coordination cost.
- "Drop" is permitted ONLY when the diff is genuinely better-as-is AND pushback would generate noise without value (e.g., a stylistic preference the implementing agent's choice is also defensible). When in doubt between drop and push-back, push back.
- Questions like "File a new rmap task for X (under Phase Y, scored [D:N/B:N/U:N])?" are forbidden for findings that fit the current PR — that prompt format implies the floor is broken.

**Why "correctness × size" not "D/B/U × LOC":** D/B/U scores prioritize tracked work; they don't decide whether work should be tracked. A D:1 finding can still be a real bug (3-line missing nil-check) — dropping it because the score is low is exactly the failure mode "iterate fast but error-free" forbids. Correctness vs cosmetic is the load-bearing axis; LOC is just a tiebreaker for tracking-vs-inline.

**Cross-references (delegation flows only — applies if `delegation.md` is imported):** push-back-vs-fix-locally calculus is in `agent-pr-review.md` § "Push-Back-vs-Fix-Locally Matrix by Agent". Hard rule against pushing to cloud-agent branches is in `delegation-rules.md` § "NEVER PUSH TO A CLOUD-AGENT'S BRANCH".

### Refine, Merge, Don't Duplicate — Before `rmap new`

Two `rmap new` failure modes: (1) new task when existing pending task should absorb the new info; (2) two adjacent tasks when one covers both because they ship in one session.

**Required check before every `rmap new`:** scan pending tasks in same bundle (`rmap list --status pending`, or grep `roadmap/tasks.toml`). Same-surface match → edit existing (`body` / `acceptance_criteria` / `out_of_scope` / `scores`). One-session match → merge into one task. New task ONLY when work ships as independent PR alongside the existing one.

**Heuristic:**

| Signal                                                                            | Action                       |
|-----------------------------------------------------------------------------------|------------------------------|
| Same bundle, same outcome, sharper requirements                                   | Edit existing                |
| Same bundle, same outcome, adds edge case / constraint                            | Edit existing (`acceptance_criteria`) |
| Same bundle, ships as separable follow-up PR                                      | New task, `depends_on`       |
| Different bundle or different user-visible outcome                                | New task                     |
| Bug against **pending** task's surface (unclaimed)                                | Edit existing (`acceptance_criteria`) — not a new bug task |
| Bug against **claimed / in-flight** task's surface                                | Push back to agent (`agent-pr-review`) or follow-up task |
| Two adjacent pending tasks ship in **one Claude session / one PR / one branch**   | Merge into one task          |

In doubt → edit or merge.

**One-session test (merge rule).** Before writing the second task in a sequence, ask: predicted PR count for this + adjacent task = 1? Yes → one task with combined `acceptance_criteria`. Each split doubles ceremony (status × 2, branch × 2, PR × 2, audit × 2) for zero work-isolation gain. Always-merge patterns: install-X + use-X; define-resource + CRUD-LiveView-for-resource; adjacent sibling features in same bundle with no dependency split.

Full pre-creation gate (5 questions, this is #3): `task-writing.md` § Pre-Creation Gate.

### Task Descriptions as Prompts

A task's `body` field should be a prompt for Claude Code (WHAT to accomplish), not an implementation spec (HOW). Let Claude research the codebase. Avoid code examples (they rot). Capture success criteria as `acceptance_criteria`. See `task-writing.md` for detail.

### Example

A task in `roadmap/tasks.toml`:

```toml
[[task]]
id = 42
phase = 2
bundle = "realtime"
status = "pending"
title = "Add WebSocket reconnection"
scores = { d = 3, b = 9, u = 9 }   # rmap computes Eff 3.0 → 🎯
markers = ["parallel"]
body = "Implement automatic reconnection with exponential backoff. Include connection state tracking."
acceptance_criteria = ["Reconnects after a transient drop", "Backoff caps at a configured ceiling"]
```

`rmap render` turns that into the scored, tiered row in `ROADMAP.md`. You author the TOML (or `rmap new --from-stdin`) — you never hand-write `[D:3/B:9/U:9 → Eff:3.0] 🎯`.

### Roadmap Maintenance

`roadmap/tasks.toml` is the source of truth; `ROADMAP.md` is rendered by `rmap render`. **Never hand-edit task tables in `ROADMAP.md`** — edit `tasks.toml` or use `rmap status` / `rmap mark` / `rmap new`, then let rmap render.

**When completing a task:**

1. `rmap status <id> done` — rmap re-renders `ROADMAP.md` + `data.json`. Record `shipped_in` (PR/commit) in `tasks.toml` if tracked.
2. **CLAUDE.md** — if repo structure / architecture / conventions changed.
3. **README.md** — if user-facing features or setup changed.
4. **CHANGELOG.md** — *only* a curated human release-notes entry under `## [Unreleased]`, if the change is release-worthy.

A task without updated docs is incomplete.

**Done tasks stay in `tasks.toml`.** rmap keeps `done` / `superseded` tasks as the durable per-task record (`body`, `done_at`, `shipped_in` all persist); `rmap list --status done` and `rmap diff` are the queries. When a phase is fully complete, set `[phases.N].status = "done"` and rmap collapses its rendered table to a one-line summary — no manual archiving, no strikethrough, no copying detail into CHANGELOG.

**CHANGELOG.md is release notes, not a task archive.** Version-grouped human-readable prose, written only when a change is release-worthy. No per-task entries, no D/B/U scores, no counts or stats — numbers rot and burn tokens, and `tasks.toml` already holds the per-task history. Describe *what* shipped and *why*.

The `ROADMAP.md` marker-pair contract (`<!-- TASKS:BEGIN -->` etc.) lives in `rmap.md`.

<!-- @-import: ~/.claude/includes/task-writing.md -->
## Writing Task Descriptions as Prompts

### Scope

Applies to **`roadmap/tasks.toml`, task lists, cross-instance docs**. Does NOT apply to `/plan` files (single-task session blueprints, consumed by the same instance that wrote them).

**Cross-instance docs** optimize for durability: prompt-style, vague enough to survive codebase changes. **Plan mode files** are the opposite — specific (exact paths, function names, line numbers) because the research just happened and will be used immediately.

**Plan mode files include:** exact paths, concrete approach (not alternatives), specific reuse patterns with locations, verification steps.

**Plan mode files exclude:** D/B scoring, prompt-style vagueness, "let Claude research" (you ARE Claude — you just did).

---

Task descriptions in cross-instance documents are **prompts for Claude Code to implement**, not implementation specs. Claude adapts to current codebase state.

### Pre-Creation Gate

Run all 5 before `rmap new`. Any fail → defer / merge / rewrite. Do not create the task.

**1. Anchor.** `body` MUST name the first consumer (sibling task in same bundle, user-visible feature, regulator inquiry, incident class).
- Consumer ≤2 tasks away in same bundle → merge into consumer.
- Consumer unscheduled or in later phase → do not create yet.
- No named consumer → U = low; do not create.
- Disallowed phrases: "for future use", "so we have it", "upfront because cheaper later".

**2. Baseline before optimization.** Quality / normalization / fuzzy-match / ML / multi-variant / observability-depth tasks score U:low until BOTH:
- (a) raw single-path version is shipped, AND
- (b) ≥1 specific user has complained about the thing this task fixes.
- "Cheaper to build now than retrofit" is not a valid score input.
- Disallowed: branching/variants before users, seed taxonomies before raw data, embeddings before raw search.

**3. One session = one task.** If implementing agent lands this task AND an adjacent task in one Claude session / one PR / one branch → merge. No exceptions for "logical separation".
- Test: predicted PR count = 1 → write 1 task.
- Always-merge patterns: install-X + use-X; define-resource + CRUD-LiveView-for-resource; adjacent sibling features in same bundle with no dependency split.
- Full rule: `task-prioritization.md` § Refine, Merge, Don't Duplicate.

**4. Milestone-fit.** Milestone `description` MUST state a hypothesis (`rmap.md` § Milestones). For each pinned task, classify:
- Tests hypothesis → pin.
- Assumes hypothesis true, builds on top → unpin; move to next milestone.
- No classification possible → milestone description is broken; fix it first.

**5. No hedging in justification** (`critical-rules.md` § NO PSEUDO-RIGOROUS HEDGING). Disallowed phrases in `body` as load-bearing reason for B/U: "table-stakes", "increasingly expected", "now standard", "buyers expect", "competitors are starting to", "modern apps all do".
- Required instead: named partner asked, named competitor lever, measured conversion uplift, OR honest low score.
- Test: remove the hedge phrase. If `body` no longer justifies the score → demote.

Pass all 5 → write body (next section).

### 🚨 Re-Generalize an Agent's Decomposition Before Filing

**When an agent breaks a too-big problem into sub-tasks, its split is overfit to the
solution it happened to find — not the problem's natural seams.** The tasks read as
"the steps of *my* implementation," carrying the agent's accidental architecture
forward into your roadmap. File them verbatim and you've hard-coded one run's
incidental structure as the project's plan.

Before turning any agent-proposed breakdown into `rmap new` tasks, re-generalize:

- **Ask "what are the problem's seams?", not "what did the agent build?"** A task
  should name a capability/boundary that survives a different implementation — not a
  step that only exists because the agent chose approach X.
- **Strip solution-shape tells:** sub-tasks named after the agent's modules/functions,
  a split that mirrors its file-creation order, "wire up the thing the previous step
  made" steps (that's the coupling smell from `rmap.md` § Right-size — fold it in).
- **Re-apply the coupling test to the *generalized* shape**, not the agent's — overfit
  splits routinely propose N tasks where the problem has 2 (or 1).

This pairs with the Pre-Creation Gate: the gate filters *whether* a task earns its
existence; this filters *whose architecture* its shape encodes. The agent's
decomposition is a draft input, never the filed plan.

### Bad: Over-Specified

```
Task: Add user authentication
Files to modify: lib/myapp/accounts.ex, lib/myapp_web/controllers/session_controller.ex
Implementation: [exact module structure, function signatures...]
```

Paths rot. Code examples conflict with evolving patterns.

### Good: Task as Prompt

```
Task: Add user authentication

Add email/password authentication with session tokens. Users register, log in, access protected routes. Hash passwords with bcrypt. Include tests for registration, login success, login failure.
```

Claude finds where, matches existing patterns, survives codebase changes. Clear success criteria, no implementation constraints.

### When Specificity Is Warranted

- User explicitly requested a specific approach
- External constraints (API contracts, database schemas)
- Migration paths where exact steps matter
- Security requirements needing precise implementation

Separate the *requirement* from the *suggestion* even then.

### Task Fields in `roadmap/tasks.toml`

A task's prose lives in two `rmap` schema fields; the rest is structured metadata:

- `title` — one-line imperative summary
- `body` — the prompt: WHAT to accomplish, in prose (the "Task as Prompt" content above)
- `acceptance_criteria` — bullet list a fresh QA session can verify
- `out_of_scope` — what the task explicitly does NOT do
- `files_to_modify` — anchor paths **only when specificity is warranted** (see above); omit for prompt-style tasks
- `scores = { d, b, u }`, `markers`, `depends_on`, `phase`, `bundle` — structured metadata, not prose

Author tasks with `rmap new --from-stdin` (TOML on stdin, atomic batch):

```bash
rmap new --from-stdin <<'TOML'
[[task]]
phase = 2
bundle = "auth"
title = "Add user authentication"
scores = { d = 5, b = 9, u = 8 }
body = "Add email/password auth with session tokens. Users register, log in, access protected routes. Hash passwords with bcrypt."
acceptance_criteria = ["Registration creates a user", "Login success issues a token", "Login failure is rejected"]
TOML
```

`rmap delegate <id> --to claude|codex|cursor` renders a task as a paste-ready cloud-agent prompt — the task-as-prompt principle with an executable consumer. See `rmap.md`.

<!-- @-import: ~/.claude/includes/rmap.md -->
## rmap — Roadmap Substrate

`rmap` is a single-binary CLI that manages `roadmap/tasks.toml` as the typed source of truth for a project's roadmap, rendering `ROADMAP.md` (human view) and `roadmap/data.json` (agent view) from it. **Every project uses rmap** — `tasks.toml` is canonical, `ROADMAP.md` is generated. Hand-editing task tables in `ROADMAP.md` is legacy; migrate (see below).

This file is the **decision layer** — *which* command, *when*. The authoritative command contract is `rmap --help` / `rmap schema` (the live `tasks.toml` field list, derived from the source) plus rmap's own CI-gated `SKILLS.md` in the rmap repo. Don't hand-maintain a parallel command reference here.

### Project layout

```
<project_root>/
├── ROADMAP.md         # rendered — hand-edited prose outside marker pairs is byte-preserved
└── roadmap/
    ├── tasks.toml     # canonical source — author this
    └── data.json      # generated — agents read it for structured access
```

`rmap` walks ancestors of cwd to find `roadmap/tasks.toml`.

### Command surface, by intent

| Intent | Command |
|---|---|
| Read one task / many | `rmap show <id> [--json]` · `rmap list --status\|--phase\|--marker\|--bundle\|--milestone\|--delivered-by [--json]` |
| Traverse the dependency graph | `rmap blocks <id> [--json]` (transitive dependents — what `<id>` unblocks) · `rmap deps <id> [--json]` (transitive dependencies — what `<id>` needs first) |
| Pick the next task | `rmap next [--marker M] [--bundle B] [--milestone V] [--count N] [--json]` |
| Pick a session-sized bundle | `rmap next-bundle [--json]` · `rmap bundles` to discover them |
| Pick the parallel-safe dispatch set | `rmap ready [--bundle B] [--phase N] [--marker M] [--milestone V] [--count N] [--dispatchable] [--fields a,b,c] [--json]` |
| See the parallel dispatch schedule | `rmap waves [--json]` — every pending/unblocked task grouped by `dep_layer`; wave 0 runs first, each wave gates the next |
| List release lines / pin to a release | `rmap milestones [--has-next\|--status\|--json]` · `rmap milestone <id> <name\|none>` |
| Change status | `rmap status <id> <pending\|in_progress\|blocked\|done\|superseded> [--implemented "..."] [--delivered-by <agent>] [--verified] [--shipped-in <sha>] [--reason "..."]` (bulk `1,2,3` atomic; `done` requires `implemented`; outcome flags settable only on `done`; `--reason` settable only on `blocked`) |
| Toggle a marker | `rmap mark <id> +parallel -cx` |
| Set/clear agent routing | `rmap assign <id> <assignee\|none\|human> [--model <m>]` — non-`human` live tasks require `--model`; `none`/`human` clear both fields |
| Add a dependency | `rmap depend <id> on <id>` |
| Create task(s) | `rmap new --from-stdin` (TOML on stdin, atomic batch, full field set per `rmap schema`) — see `task-writing.md`. Interactive `rmap new` covers the common subset; reach for `--from-stdin` when interactive doesn't prompt for a field you need. **A created task is *always* `pending`.** `new` accepts `status` only as `"pending"` (a tolerated no-op, so echoing the default isn't a rejected round-trip); any non-pending value is rejected with `creates pending tasks only` pointing at `rmap status`. Every other transition/outcome field (`implemented`, `delivered_by`, `verified`, `shipped_in`, `started_at`, `done_at`) is still rejected with `unknown field`. Flip to a non-pending state afterward via `rmap status`. Creation-time fields only: `id phase bundle milestone title scores markers depends_on linear_id assignee module model acceptance_criteria out_of_scope files_to_modify touches cross_repo branch body created_at scored_at`. |
| Format a task as a cloud-agent prompt | `rmap delegate <id> [--to claude\|codex\|cursor\|grok\|antigravity\|pi\|droid]` — `--to` optional, defaults to the task's `assignee` |
| Migrate a hand-edited ROADMAP.md | `rmap import` |
| See what changed vs a git ref | `rmap diff [--verbose] [--json]` |
| List stalled in-progress tasks | `rmap stale --over <dur>` (e.g. `30d`, `2w`; also folded into `doctor`) |
| Health signals (soft, always exit 0) | `rmap doctor [--json] [--bottleneck-min N]` |
| Strict gates (pre-commit / CI) | `rmap validate` · `rmap validate --check-render` |
| Render after editing tasks.toml directly | `rmap render` (or `rmap watch` for live re-render) |
| Emit data.json to stdout (read-only) | `rmap export json` (`render` is what writes the file) |
| Emit the dep graph as Graphviz (read-only) | `rmap export dot` — DOT digraph of the in-repo `depends_on` graph (edges dependency → dependent); pipe to `dot` |

All mutators **validate-then-write**: an invalid mutation leaves `tasks.toml` byte-equal to its prior state. `--json` envelopes on the read commands are append-only stable surfaces.

### Concurrent sessions write to rmap — verify task IDs before mutating

`roadmap/tasks.toml` is a **shared, multi-writer file**: parallel Claude sessions, harness dispatches, and cloud agents all create and mutate tasks concurrently. A task ID or task state read earlier in your session is a *snapshot*, not a lock — another writer may have created tasks (shifting "the next ID"), completed the task you're about to mark, or changed the very task you're targeting.

Before any mutation, re-verify against the current file:

- **Before `rmap status <id> …` / `rmap mark` / `rmap milestone` / `rmap assign` / `rmap depend`:** run `rmap show <id>` first and confirm the title/body matches the task you mean. An ID memorized earlier (or quoted by another session) may now point at a different or already-mutated task.
- **Before `rmap new`:** never assume what ID the new task will get; read it from the command's output after creation, not from "last ID I saw + 1".
- **Before hand-editing `tasks.toml` directly:** re-read the file immediately before the edit — never write from a stale in-context copy. Prefer the `rmap` mutators over hand edits; they re-read and validate-then-write atomically.
- **Referencing tasks across sessions / handoffs:** quote the task *title* alongside the ID so the receiver can detect drift (`rmap show <id>` title mismatch ⇒ stop and re-resolve).

The validate-then-write guarantee protects against *invalid* writes, not *lost* ones — two valid writers can still silently overwrite each other's fields. The verification habit above is the consumer-side discipline that prevents it.

### 🚨 Search existing tasks before `rmap new` — update beats duplicate

A roadmap accretes near-duplicate tasks when each session files "the obvious next task" without first checking whether one already covers it. The result is two tasks the harness dispatches twice, scored inconsistently, drifting apart. **Before filing ANY new task, search the roadmap for prior coverage** — and prefer *updating* an existing task over creating a sibling.

The gate, before every `rmap new`:

1. **Search by concept, not just title.** `grep -niE "<keyword>|<synonym>" roadmap/tasks.toml` across titles *and* bodies (the overlap usually hides in an existing task's `acceptance_criteria`/`body`, not its title), plus `rmap list --bundle <b>` for the bundle the task would land in. One keyword misses it; search the 2–3 ways the idea could be phrased.
2. **Read the candidates in full** — `rmap show <id>` for each near-match. A task whose ACs already imply your work is coverage, even if its title reads differently.
3. **Classify the finding, then act:**
   - **Already fully covered** → don't file. Note the existing ID back to whoever asked.
   - **~80% covered, missing a facet** → *update the existing task* (add an AC + a dated body note naming the new facet) rather than file a near-clone. Hand-edit `tasks.toml`, then `rmap validate && rmap render`.
   - **Genuinely new, but adjacent** → file it, and wire `depends_on` / a body cross-ref to the adjacent task so the relationship is explicit (`out_of_scope` is the right place to say "X belongs to Task N, not here").
   - **Splits into build-now + decide-later** → file the buildable part and a separate *decision spike* (the `task-writing.md` spike shape), rather than one oversized task.
4. **Report the verdict before writing** when the ask was "scope these tasks": say which are new, which fold into an existing ID, which are already done — so the human sees the dedupe, not just the result.

This pairs with the ID-safety rule above (that one stops you *colliding* on an ID; this one stops you *duplicating* the work) and with `task-writing.md`'s Pre-Creation Gate (add the dedupe search as the first gate question — content novelty precedes scoring).

### 🚨 `tasks.toml` is a machine-read contract — corruption or missing outcome fields makes harness re-dispatch landed work

`roadmap/tasks.toml` is not a human notes file. **Harness ingests it as the run queue** (`mcp__harness__roadmap-ingest` / `roadmap-ready`), and the landing pipeline writes back through it (`Harness.Lander` advances `done --verified --shipped-in <sha>` on a successful ff-push). The file is the *single source of truth for what has already landed.* When it's wrong, harness believes already-shipped tasks are still open and **re-dispatches work that is already in `development`** — burning a full implement→review→land cycle (and agent tokens) to redo a merged task, or worse, landing a conflicting second copy.

Two failure classes cause this, both observed in this repo:

1. **Parse-breaking corruption** — a duplicate key in a `[[task]]` table, an invalid `status` enum (`"completed"` instead of `"done"`), a malformed value. `rmap` and every harness consumer that loads the file then **error out or skip the whole file**, so *every* task — including landed ones — reads as absent/pending. One bad table blinds the consumer to the entire roadmap.
2. **Incomplete outcome layer on a landed task** — `status = "done"` but missing `shipped_in` / `done_at` / `verified`. The task parses, but a consumer keying landing-state off those fields can't tell it shipped, so it stays eligible for dispatch. `done` alone is "an implementer claimed it"; **`shipped_in` is the proof it's in the branch** — set both together.

**The disciplines that prevent it:**

- **Prefer the `rmap` mutators over hand-editing.** They re-read, validate-then-write atomically, and reject invalid status/missing-`implemented` transitions — exactly the corruption classes above. Reach for a hand-edit only when no mutator covers the field.
- **After ANY hand-edit of `tasks.toml`, run `rmap validate` before you move on.** It is the gate that catches duplicate keys, bad enums, and `done`-without-`implemented` before a harness consumer trips over them. A hand-edit you didn't validate is a landmine for the next ingest.
- **When work lands, write the full outcome layer in one motion** — `rmap status <id> done --implemented "…" --verified --shipped-in <sha>`. A `done` task without `shipped_in` is an incomplete record harness can misread as still-open. Use the full 40-char SHA, matching the existing rows.
- **Never leave `tasks.toml` in a non-parsing state across a commit.** If `rmap list` errors, fix it *now* — a committed parse error means every concurrent session and every harness ingest is flying blind until someone notices.

This is the rmap-specific, high-stakes corollary of § "Concurrent sessions write to rmap": there the cost of a sloppy write is a lost field; here, because harness *acts* on the file, the cost is redundant or conflicting dispatch of already-shipped work.

### rmap is cheap — set and complete inline; don't manufacture a session

A task's *existence in rmap* is decoupled from *how it gets executed*. Creating one
(`rmap new`) and completing it (`rmap status <id> done`) are lightweight ledger
writes — seconds, a handful of tokens. Neither warrants a separate session, a
dispatch, or a round of "should this even be a task?" deliberation.

When a task is small and you're already in the relevant code, the cheapest correct
path is: **do it inline now, then `rmap status <id> done --implemented "…"` in the same
motion.** Reserve a separate dispatched/cloud-agent session for work that genuinely
earns it — large, risky, parallelizable, or (under a dogfooding mandate) a change to
the orchestrator's own surface. Capturing a discovery as a *pending* task is also fine
and cheap — but **capture ≠ dispatch, and a task ≠ a session.** Hand-done inline tasks
honestly leave `verified` unset (no independent grader ran).

**Failure mode this kills:** treating every rmap entry as a dispatch-and-verify cycle,
or looping in discussion over whether to file/dispatch, when setting + doing +
marking-done inline costs less than the deliberation. Set it, do it (or defer it),
mark it done — don't burn time, tokens, and circles on the ceremony around it.

### 🚨 Right-size tasks — a task is a *dispatch unit*, not a *changelog line*

**The unit of an rmap task is one implement→review→land cycle's worth of coupled
work — not the smallest namable edit.** Every dispatched task pays a full cycle's
overhead (worktree, implementer run, cross-family reviewer, merge, audit). A task
too small to justify that overhead is a manufactured session: it spends an entire
loop to land a one-liner. The 223 lesson (a whole dispatchable task filed for a
moduledoc edit) is the canonical anti-pattern — **that work gets done inline, the
instant you spot it, never filed.**

**Before creating OR splitting a task, apply the coupling test — split on coupling,
never on size:**

1. **Does task B only delete / fix up / wire what task A orphans?** Then B is not a
   task — it's the second half of A. Fold it in. (Tell: B `depends_on` A *and* B's
   files are the ones A stops using; or A's own acceptance criteria already entail
   B's deliverable. Worked example: the CapabilityScore-delete task was redundant —
   its parent's criteria already said "no magic weights remain in the routing
   path," which *is* the deletion. Merged.)
2. **Would one reviewer naturally verify both in a single pass over a single diff?**
   Then they're one dispatch. Don't make the merge train run twice for one logical
   change.
3. **Is it ALL of: D≤2, ≤30 LOC, ≤3 files, no public-surface change?** Then it's an
   *inline* task, not a *dispatch* — do it now and `rmap status … done`, per "rmap
   is cheap" above. Don't file it for later; don't route it through an agent.

**The opposite anti-pattern is equally wrong — do NOT grab-bag.** Combine only
*coupled* small tasks (shared files, one orphans the other, same atomic change).
Two small tasks that are merely both small but touch disjoint files and unrelated
concerns stay separate — bagging them creates a task a reviewer can't verify as one
thing. **Coupling is the merge criterion; size is only the inline-vs-dispatch
criterion.**

**Failure-mode tell — about to file/keep a task whose entire body is "delete the
thing the previous task stopped using," or whose deliverable is already entailed by
a sibling's acceptance criteria? STOP. Fold it into the sibling. About to merge two
small tasks that share no files and no dependency just because both are small? STOP.
That's a grab-bag — keep them separate.**

### Batches are derived, not declared

`rmap next-bundle` returns a session-sized **bundle** — a set of related pending tasks. A *batch* is a finer-grained slice of that bundle: the executor groups bundle tasks by `depends_on` into successive layers of disjoint work (per `workflow-philosophy.md` § "Batched Execution"). There is no `rmap batch` command — batch derivation is the executor's job, not the source-of-truth's. Hierarchy: phase ⊇ bundle ⊇ batch ⊇ task.

### Parallel-dispatch surface (`rmap ready` + the orchestration fields)

When you need *the set of tasks I can dispatch in parallel right now* — not "a session's worth" (`next-bundle`) and not "the single best" (`next`) — use **`rmap ready`**. It returns every `pending` task whose deps are all `done`, which is **mutually independent by construction** (a pending task with all deps done can't depend on another pending task), so the whole set is safe to fan out at once. `rmap ready --bundle <B>` is the dispatchable layer-0 of a bundle — the parallel batch `next-bundle`'s serial chain can't express. Five facts the orchestrator reads instead of re-parsing every task body:

- **`assignee`** (creation-time field, validated against `human|claude|codex|cursor|grok|antigravity|pi|droid`): **THE agent-routing field** — which agent executes the task. Orchestrators route on it (`--fields id,assignee,markers`), and `rmap delegate` defaults `--to` from it. `assignee = "human"` means "not for autonomous dispatch" — consumers skip it. Don't overload `model` (a free-text LLM id) or the `cx`/`csr` markers (filter/discovery tags) for routing. **Set `assignee` at creation** (`rmap new` / `--from-stdin`) or **reassign later** via `rmap assign <id> <agent> [--model <m>]` — an unset assignee carries no routing intent, so the interactive `rmap delegate` errors (pass `--to`) and an autonomous consumer falls back to *its* configured default dispatch agent rather than your intent. Pick the agent when you file the task; use `rmap assign <id> none` when the work is genuinely for hand-build only.
- **`dep_layer`** (computed, on every `--json`): longest-path depth over the in-repo dep graph. Within a result set the lowest `dep_layer` present is the current parallel wave; higher layers are later waves — makes `next-bundle`'s topo chain self-describing.
- **`unlocks`** (computed, on every `--json`): count of tasks that transitively depend on this one — the size of its `rmap blocks <id>` set. Turns hand-guessed unlock leverage (the `U` score's leverage component) into a graph fact: a high-`unlocks` pending task gates a lot of downstream work. Like `dep_layer` / `eff`, computed at read time, never persisted. Use `rmap blocks <id>` to see *which* tasks, `unlocks` to rank by *how many*.
- **`handbuild` marker + `--dispatchable`**: `--dispatchable` (on `ready` / `list`) drops `handbuild`-marked tasks. **UI/LiveView/CSS work is NOT handbuild by default** — incremental UI against an existing design system or a frontend-design doc is normal headless dispatch. Reserve `handbuild` for the genuine minority where a human-in-browser is required: net-new visual identity with no design spec to build against (exploratory look-and-feel / motion / brand). Everything else — backend and spec-anchored UI alike — is headless-dispatchable by default.
- **`touches`** (creation-time field): the broader *involvement hint* — files a task may read or write, typically a superset of `files_to_modify` (the write target). Consumer collision rule (you dedupe; rmap doesn't enforce): two tasks conflict iff `(touches(A) ∪ files_to_modify(A)) ∩ (touches(B) ∪ files_to_modify(B)) ≠ ∅`. Unioning both fields keeps `files_to_modify` respected even when a task's `touches` isn't a perfect superset — `touches` is "typically," not guaranteed, a superset. Set it via `rmap new --from-stdin`.
- **`--fields a,b,c`** (on `ready` / `list`): projects `--json` to a bare array of just the named keys per task — token-cheap for an orchestrator that only needs `id,status,eff,depends_on,dep_layer,touches`. Implies `--json`; unknown name exits 1.

### D/B/U mapping

rmap's scoring **is** the `task-prioritization.md` framework, executable:

- `scores = { d, b, u }` on each `[[task]]` ⇒ the `[D:X/B:Y/U:Z]` you'd otherwise hand-write
- `eff = (b + u) / (2 × d)`, computed at read time, never stored — same formula, same tiers (`≥2.0 🎯 / ≥1.5 🚀 / ≥1.0 📋 / else ⚠️`)
- `scored_at` older than 30 days renders an `Eff:W?` decay suffix

Set scores in `tasks.toml` (via `rmap new` or editing the file); never hand-format the bracket — `rmap render` produces it.

### Status & marker vocabulary

- **status:** `pending | in_progress | blocked | done | superseded` — transitions go through `rmap status`. `blocked` requires a `blocked_reason` (set inline via `--reason "..."`; free-text, blocked-only, overwrites, and **auto-cleared when the task leaves the blocked state** — it renders inline on the blocked row in `ROADMAP.md`); `done` requires `implemented` (set inline via `--implemented "..."`, or pre-populated in `tasks.toml`; on a TTY without the flag, `rmap status` prompts). For bulk `rmap status 1,2,3 done`: the mutation is atomic — if any task is missing `implemented` AND no `--implemented` flag is given AND we're not on a TTY, the whole batch is rejected; `--implemented "..."` applies the same string to every task in the batch.
- **markers:** `parallel | cx | csr | bug | security | docs | handbuild` — `parallel` is the old `[P]`; `cx` / `csr` are the Codex / Cursor delegation markers; `handbuild` flags the narrow human-in-browser exception — net-new visual identity with no design spec (NOT routine UI/LiveView/CSS, which is dispatchable) — that `rmap ready --dispatchable` / `rmap list --dispatchable` exclude.
- **milestone status:** `pending | active | done` — distinct vocabulary from task status. Flip by hand-editing `[milestones.<name>].status` (no mutator yet); `active` milestones sort first in `rmap milestones` and are the load-bearing affordance for the "what release am I cutting next?" query.

### Milestones — first-class release lines

`[milestones.<name>]` is a fourth top-level concept alongside phases / bundles / markers. **Phase** orders work, **bundle** groups topically, **markers** modify execution, **milestone** pins a task to a release line. Milestones cross phases by design: a `v1.0` cut typically pulls from several phases.

**Milestone `description` MUST state a hypothesis.** One sentence naming what the milestone tests (e.g., *"proves Bali professionals will pay for a Bali-specific material-price tool"*, not *"data platform complete"*). Feature-checklist descriptions break the Pre-Creation Gate's milestone-fit check (`task-writing.md` § 4): without a hypothesis, no pinned task can be classified as "tests hypothesis" vs "assumes hypothesis, builds on top", and heavy moat-building drifts onto early validation milestones.

**Default at session start: pick the next task via the active milestone.** Keep exactly one milestone at `status = "active"` (the MVP/release you're cutting); plain `rmap next` then auto-biases to it — no `--milestone` flag needed. Reach for `rmap next --milestone <name>` only to override to a different release line.

- Author the table in `tasks.toml`: `[milestones.v0_1] name = "..." order = N status = "active" target_version = "0.1.0"`. `target_version` is optional free-text.
- Pin a task: `rmap milestone <id> v0_1` (or set `milestone = "v0_1"` directly). Unpin: `rmap milestone <id> none`. One milestone per task.
- Discovery: `rmap milestones` (table view with done/total counts + next-task glyph + active-first sort); `rmap milestones --json` for the agent envelope.
- Drive a release line: `rmap next --milestone v0_1` returns the next pending task in that release; composes with `--bundle`, `--phase`, `--marker`. Without an explicit `--milestone`, `rmap next` automatically biases toward tasks pinned to any `active` milestone — analogous to the existing focus-phase bias. **Focus phase dominates** milestone when the two diverge (4-tier lexicographic: focus-only > active-milestone-only); pass `--milestone <name>` to override the auto-bias to a different release.
- `rmap delegate` surfaces the milestone in `## Context` as `- Milestone: v0_1 (target=0.1.0)` so the target agent knows which release ships their work.
- `rmap render` adds a conditional `🚀 **<milestone>** ·` segment to the task row in `ROADMAP.md` — rows without a milestone render byte-identically to before.
- `rmap render` also fills an optional `<!-- MILESTONES:BEGIN -->` / `<!-- MILESTONES:END -->` section when present. Body shape: one markdown block per declared milestone, sorted like `rmap milestones`; each block includes `### <key> — <name>`, `target_version` (`none` when absent), status glyph + status (`🔄 active`, `⬜ pending`, `✅ done`), the hypothesis from `milestone.description`, and `<done>/<total> done` pinned-task counts. Projects without the marker pair render byte-identically to before.

### `body` vs `implemented`

- `body` = original task definition / intent (never mutated after creation — the spec at scoping time).
- `implemented` = what was actually built and why (required when `status = "done"`; `rmap show` renders both side-by-side as `body (original intent):` / `implemented (what shipped):` when present together). For trivial tasks where delivery matched the spec, `implemented = "as specified in body"` is honest and durable.

### Outcome layer: `delivered_by` + `verified` + `shipped_in`

Three optional transition-time fields next to `implemented`, all set by `rmap status <id> done`. The triple answers who built it, whether a grader agreed, and where it landed:

- `delivered_by = "<agent>"` — which agent or instance actually shipped the task (free-text, unvalidated, like `model`). Answers "who built this?" as a queryable fact without parsing prose. Settable via `--delivered-by <agent>` on `done` transitions; overwrites on re-set.
- `verified = true` — independent evaluator confirmed the task. Two-state: `true` = a check separate from the implementer passed (verification stack green, code-review approved); absent = not yet graded (hand-built, bootstrap, merged directly). Settable via `--verified` presence flag on `done`; to clear, edit `tasks.toml` directly. Encodes evaluator-separation as a fact, not as a status — `done` means "an implementer said so", `verified` means "a grader agreed".
- `shipped_in = "<sha>"` — where the work landed (commit SHA / PR ref, free-text, unvalidated). Settable via `--shipped-in <sha>` on `done` transitions; overwrites on re-set. No sha-shape validation, no git auto-derivation — the caller supplies it.

All three surface in `rmap show`, `rmap list` JSON / `data.json` (via `ExportedTask`), and `rmap diff --verbose`. `rmap list --delivered-by <agent>` filters the roadmap into a per-agent delivery ledger (status-agnostic — matches the field, not just done tasks). `rmap doctor` emits a soft `ClaimedNotGraded` advisory for `done && verified.is_none()` ("claimed, not graded") — always exit 0, hand-built tasks are legitimate. Graph-health advisories (`bottleneck`, `isolated_node`) flag high-leverage gating tasks and disconnected/off-milestone nodes — also soft, exit 0; tune the bottleneck cutoff with `--bottleneck-min` (default 3). All three stay off `StdinTask` / `NewTaskFields` on purpose; they are outcome facts, not creation-time intent.

### Pinning an LLM model per task

`model = "<model-id>"` on a `[[task]]` records which LLM should do the work — the *value* is free-text and unvalidated (model IDs churn, so no closed set). `rmap delegate` surfaces it as a `- Model:` bullet in the prompt's `## Context` so the target agent knows which model to run. Settable at creation via `rmap new` (interactive + `--from-stdin`) or a direct edit.

**`model` is required (presence, not value) on a live agent-assigned task.** `rmap validate` hard-errors (exit 1, agent-grep `missing model`) when a `pending`/`in_progress` task has `assignee` set and != `"human"` but no `model` — harness hard-rejects a dispatch that resolves to no model (it never falls through to the agent CLI's ambient default), so rmap refuses to author one. The mutators inherit this (validate-then-write): `rmap new --assignee <agent>` on a model-less task fails before write; `rmap assign <id> <agent>` without `--model` fails the same way. Pin a model whenever you set an agent assignee on a live task. Terminal tasks (`done`/`superseded`/`blocked`) and assignee-unset / `human` tasks are exempt.

`rmap assign <id> <assignee> [--model <m>]` sets routing on an existing task (creation-time fields otherwise only writable via `rmap new` or hand edit). `rmap assign <id> none` or `rmap assign <id> human` clears both `assignee` and `model` for hand-build work — `--model` is forbidden on that path.

The three-way split — don't conflate them:

- **`assignee`** = which *agent* executes the task (validated agent set; THE routing field consumers route on)
- **`model`** = which *LLM* that agent runs (free-text pin; never an agent name)
- **`delegate --to`** = explicit render-time override of `assignee` for one prompt (omit it to honor the stored routing intent)

A fourth, advisory dimension sits alongside these: **`domains`** = a free-text list of capability tags on a `[[task]]` (e.g. `domains = ["otp", "ecto"]`), unvalidated and no closed enum — the *downstream consumer* owns the vocabulary (harness maps them to its `CapabilityDomain` for per-`{agent, domain}` capability scoring). Unlike `assignee`/`model`/`--to`, `domains` does not route a single dispatch — it labels the task so a consumer can group outcomes by domain and move dispatch from explore to exploit. Settable at creation via `rmap new` (interactive + `--from-stdin`) or a direct edit; surfaces on every `--json` payload, in `data.json`, and as a `- Domains:` bullet in `rmap delegate`'s `## Context`.

### Migrating a hand-edited ROADMAP.md

Run `rmap import` — it emits a paste-ready prompt that walks an agent through converting one or more hand-edited `ROADMAP.md` files into `roadmap/tasks.toml` (schema, marker pairs, validate → render → diff-check). One-time, LLM-driven; the prompt carries the detail so this include doesn't have to.

### Cross-references

- `task-prioritization.md` — the D/B/U framework, tiers, ceremony floor, exclusions that rmap executes
- `task-writing.md` — how to write a task's `body` / `acceptance_criteria`; the `rmap new --from-stdin` shape
- `workflow-philosophy.md` § "Batched Execution" — canonical rule for the batch derivation referenced in § "Batches are derived, not declared"

<!-- @-import: ~/.claude/includes/web-command.md -->
## Web Browsing: `web` vs `WebFetch`

- **`WebFetch`** — read-only content extraction (docs, articles). LLM-processed, clean.
- **`web` command** (`/usr/local/bin/web`) — real browser for forms, JS, LiveView, screenshots, sessions. Raw HTML→markdown (includes nav/chrome noise — bad for pure reading).

Repo: https://github.com/chrismccord/web

### When to Use Which

| Task | Tool |
|------|------|
| Read docs, articles, extract data from a page | `WebFetch` |
| Submit forms, Phoenix LiveView, screenshots, JS execution, session/cookie persistence, JS-rendered pages | `web` |

### `web` Usage

```bash
web https://example.com                           # default: 100k char markdown
web https://example.com --truncate-after 5000
web https://example.com --screenshot /tmp/page.png
web https://example.com --js "document.querySelector('button').click()"
```

### Phoenix LiveView Form Submission (auto-waits for `.phx-connected`)

```bash
web http://localhost:4000/users/log-in \
    --form "login_form" \
    --input "user[email]" --value "test@example.com" \
    --input "user[password]" --value "secret123" \
    --after-submit "http://localhost:4000/dashboard"
```

### Session Persistence

```bash
web --profile "myapp" http://localhost:4000/login ...
web --profile "myapp" http://localhost:4000/protected-page
```

### Key Flags

| Flag | Purpose |
|------|---------|
| `--raw` | Raw HTML instead of markdown |
| `--truncate-after N` | Limit output (default 100000) |
| `--screenshot PATH` | Full-page screenshot |
| `--form ID` / `--input NAME` / `--value V` / `--after-submit URL` | Form submission |
| `--js CODE` | Run JS after page loads |
| `--profile NAME` | Named session profile |

<!-- @-import: ~/.claude/includes/code-style.md -->
## Code Quality KPIs (Complexity-Based)

**Simple Code** (utilities, helpers, data transforms):
- Functions per module: 12 max
- Lines per function: 10 max
- Call depth: 2 max
- Pattern match depth: 3 max

**Standard Code** (business logic, controllers, contexts):
- Functions per module: 8 max
- Lines per function: 15 max
- Call depth: 3 max
- Pattern match depth: 4 max

**Complex Code** (GenServers, supervisors, distributed systems):
- Functions per module: 6 max
- Lines per function: 20 max
- Call depth: 4 max
- Pattern match depth: 5 max

**Universal Standards:**
- Dialyzer warnings: 0 (mandatory)
- Credo score: 8.0 minimum
- Test coverage: 80% minimum (95% for critical business logic)
- Documentation coverage: 100% for public APIs

<!-- @-import: ~/.claude/includes/development-philosophy.md -->
## Elixir Documentation Standards

**No IO in `@doc` examples.** `@doc` demonstrates API usage, not console output.

```elixir
# ❌ IO.puts("User: #{user[:name]}")  /  IO.inspect(user)
# ✅ {:ok, user} = MyApp.get_user("id")
# ✅ users = MyApp.list_users()
```

## Marking Internal API Surface

Elixir has no true visibility modifier on `def`. These markers communicate "not public API" to docs tooling, callers, and Dialyzer — none make a function actually private (only `defp` does that).

### Functions

| Marker | Hides from HexDocs? | Importable via `import`? | When to use |
|---|---|---|---|
| `defp` | ✅ | N/A (not callable) | True privacy. Default for any helper that doesn't need cross-module visibility. |
| `@doc false` on `def` | ✅ (function only) | ✅ | `def` that *must* be public (macro target, behaviour callback shim, called by sibling internal module) but isn't part of the consumer contract. |
| `@moduledoc false` on whole module | ✅ (entire module) | ✅ | Every function in the module is internal. Group internal helpers in `MyLib.Internal` / `MyLib.Impl` and mark the module — cleaner than scattering `@doc false`. **Elixir-core-recommended pattern.** |
| Leading `_` in name (`_foo`) | ✅ (with `@doc false`) | ❌ — compiler skips on `import` | Strongest "do not depend on this" signal. Compiler-enforced no-import. Rare in practice; reach for it when the function shape looks public-ish and you want a name-level deterrent. |
| `__foo__/N` (double underscore) | — | — | **Reserved for compile-time metadata / introspection** (`__info__/1`, `__struct__/0`, `__changeset__/0`, `__schema__/1`). Don't use for ordinary internal helpers — confuses readers who associate it with macro-generated metadata. |

**Decision tree:**
1. Can it be `defp`? → `defp`. Stop.
2. Must it be `def` (cross-module, macro target, behaviour shim)? → `@doc false`.
3. Is the *whole module* internal? → put it in `MyLib.Internal` (or similar) with `@moduledoc false`. Skip per-function `@doc false` inside.
4. Want compiler-enforced no-import? → leading single underscore. Reserve `__foo__/N` for metadata.

### Types

| Marker | Visible in docs? | Usable in other modules' specs? | Internal structure visible? |
|---|---|---|---|
| `@type` | ✅ | ✅ | ✅ |
| `@opaque` | ✅ | ✅ | ❌ — pattern-matching on internals is a contract violation |
| `@typep` | ❌ | ❌ — module-local only | ✅ (within the module) |

**Decision:**
- Public type, structure is part of the contract → `@type`.
- Public type, structure is implementation detail (callers shouldn't pattern-match) → `@opaque`. Use this for tokens, handles, IDs, anything where you want freedom to change the internal representation.
- Type only used inside this module → `@typep`. Keeps the public type surface clean.

### Specs

**Mandate: every function gets a `@spec` — `def` and `defp` alike.** No exceptions for "trivial" helpers; the spec is one line and pins the contract Dialyzer can't always infer (e.g. `integer() | float()` vs the narrower `integer()` you actually meant).

- **Why mandate, not "publics-only" (the community default):** community default optimizes for team-onboarding cost — irrelevant here. Solo-dev library portfolio with Credo strict + Dialyzer in CI on every repo. Cost is one line per function; payoff is Dialyzer pointing at the spec mismatch (fast) instead of a downstream call site three layers away (slow). Domain is signing / wallet / wire-format code where binary-length, hex-vs-binary, and union-narrowing bugs are exactly what specs on `defp` catch.
- **CI enforcement:** in `.credo.exs`, configure `{Credo.Check.Readability.Specs, [include_defp: true]}`. The Credo default is `include_defp: false` (publics-only). We override to `true` because the mandate covers every function. Doctor's spec-coverage gate handles publics; this Credo check closes the gap on privates.
- **Placement:** `@spec` line goes immediately above the `def` / `defp`, after `@doc` / `@doc false`.
- **The one trade-off:** macro-generated `defp` functions can trip the Credo check. Suppress per-callsite with `# credo:disable-for-next-line Credo.Check.Readability.Specs` rather than dropping `include_defp` back to `false`.

## Doctests Are Documentation, Not Tests

**Doctests prove the happy path as readable prose. They are not a substitute for focused ExUnit assertions on edge cases, boundary conditions, or invariants.** When the question is "does my code work the way the readme suggests?", doctests are perfect. When the question is "does my code behave correctly across the full input space?", you need real tests.

**Why the distinction matters:**
- Doctests read top-to-bottom as a narrative. Adding three more doctests to cover empty-list, nil, and union-element cases turns the moduledoc into a wall of fixture noise that future readers skip past.
- Doctests pin one input → one output per example. They don't compose well for "for all X in this set, F(X) preserves invariant Y."
- Doctests can't easily share `setup` blocks, fixtures, or helper functions. ExUnit `describe` blocks can.
- Doctests have no `assert_raise`, no parameterized cases, no `assert_in_delta`, no custom failure messages. They check `inspect/1` equality on the literal expression result.
- Coverage that comes only from doctests is shallow — the doctest proves "this representative input works," not "this branch of the function is exercised."

**The rule:**
- **Add doctests when the example clarifies how the API is meant to be called.** Treat them as compile-checked README snippets.
- **Add ExUnit assertions for everything else** — boundaries (empty/nil/zero/max), unions (each variant of a sum type), invariants (round-trips, idempotence), error paths (`assert_raise`, `flunk`-on-unexpected), and any case where the input space is wider than one demonstrative shape.
- **When a spec narrows or an invariant changes, add focused ExUnit assertions even if a doctest exists.** A doctest that happened to match the new spec doesn't *prove* the spec; it proves one example of it. The assertions document what the spec actually guarantees.

**Concrete heuristic:** if you find yourself writing a second doctest "to also cover the empty case" or "to also cover the integer branch of the union," stop and write an ExUnit `describe` block instead. Doctests that exist to cover edge cases are the failure mode this rule guards against — they bloat the moduledoc, they're harder to maintain, and they signal that the test suite isn't carrying its share of the load.

## Explore Before Coding (Tidewave Workflow)

For external APIs, databases, or unfamiliar code: **explore with `mcp__tidewave__project_eval` before writing any implementation.** Test real API calls, inspect real response structures, field names, data types, and error formats. Never assume. When something breaks, inspect real data flow — don't add debug prints.

Understand reality before implementing against it. Tidewave is the exploration tool; use it liberally before and during development.

## TODO Comment Requirements

**All temporary implementations and production references MUST use the `TODO:` prefix** so `mix credo` can track them. Without the prefix, technical debt is invisible to automated review.

Rewrite phrases like "For now...", "Currently...", "Temporarily...", "In production...", "This is a workaround..." with a `TODO:` prefix. When uncertain about the correct approach, write a TODO explaining the uncertainty — better than a wrong guess; Credo will surface it.

```elixir
# ❌ BAD: credo won't find this
# For now, hardcoded timeout
timeout = 5000

# ✅ GOOD
# TODO: For now, hardcoded timeout — should be configurable
timeout = 5000

# ✅ When genuinely uncertain:
# TODO: Uncertain whether this should retry on :timeout or fail fast — both patterns exist
```

## Cite Ecosystem Precedents Before Crying Complexity

**Before objecting that a macro / DSL / abstraction "is risky" or "could grow knobs," check whether a battle-tested Elixir precedent already solves the same shape.** Generic FUD without a named failure pattern is risk-aversion theater.

Elixir has mature, working-at-scale macro patterns for declarative DSLs. If the proposed shape matches one of these, the "macros are scary" objection is **already disproven by existence**:

| Precedent | Shape | What it proves |
|---|---|---|
| **`Phoenix.Router`** (`get/2`, `post/2`, `scope/2`, `pipe_through/1`) | Declarative HTTP route DSL: verb + path + controller + action + pipeline + helper-name | One macro family handles 6+ orthogonal concerns, working since 2014, used by every Phoenix app |
| **`Ecto.Schema`** (`field/3`, `belongs_to/3`, `has_many/3`, `embeds_many/3`) | Multiple specialized macros instead of one fits-all | Lesson: when shapes genuinely diverge, split macros — don't grow a single one |
| **`NimbleOptions`** | Compile-time validated option-keyword schemas | Removes the "macro grows unchecked knobs" failure mode by making the option surface declarative + validated. Used in Bandit, Plug, Broadway, Oban, hundreds of others |
| **`Absinthe.Schema`** (`field/3`, `arg/3`, `resolve/1`) | GraphQL DSL with arg validation, resolvers, middleware | Variance + composition + introspection in one declaration |
| **LiveView** (`attr/3`, `slot/3`) | Component prop typing + validation + defaults | Modern (2023+) example of disciplined macro DSL |
| **`TypedStruct`** | Single declaration → struct + types + dialyzer specs + validations | Multi-output codegen from one declarative input |
| **`Ash.Resource`** | Whole-resource DSL: attributes, relationships, actions, policies | Largest-scale Elixir DSL in production; proves the pattern scales arbitrarily |

**Rule:** when about to push back on a macro proposal, either (a) name the **specific** Elixir precedent that fails the same way, or (b) accept the proposal as a well-trodden pattern and move to concrete design questions. "Macros are complex" / "DSLs grow" / "this could become a tarball" — without a specific failure pattern — is hedging, not analysis.

**Concrete pattern for new macro DSLs.** Define a `NimbleOptions` schema for the option keyword list:

```elixir
@defrpc_schema NimbleOptions.new!(
  decode: [type: {:in, [:hex_unsigned, :raw_hex, :tx_receipt]}, default: :raw_hex],
  params: [type: :keyword_list, default: []],
  description: [type: :string, required: true]
)

defmacro defrpc(name, method, opts \\ []) do
  opts = NimbleOptions.validate!(opts, @defrpc_schema)
  # expand to function + bang + api() + @spec
end
```

The schema **is** the macro's public contract. Adding a knob requires changing the schema, which makes drift visible at code-review time. This is the pattern Bandit, Plug, Broadway, and Oban all use — proven, mechanical, surfaces complexity instead of hiding it.

## Recommend Libraries Before Crying Friction

**When you're about to characterize some cost as a real trade-off (case-conversion friction, validation boilerplate, encoding wire-format edge cases, parity-maintenance overhead), first check hex.pm.** The default failure mode is treating a solved problem as a cost when a ~5-line dependency reduces it to near-zero. Friction cited without a hex check is hedging dressed up as analysis — and it can flip a real decision (e.g. "stick with the inferior format" / "build it ourselves" / "skip this integration") on the back of a non-existent cost.

**Failure-mode test — about to write any of these? STOP, search hex.pm first:**
- "X feels foreign in idiomatic Elixir" / "X requires manual conversion at the boundary"
- "You'd have to hand-write Y at every call site"
- "Z requires custom encoding/parsing"
- "Maintaining parity between A and B is error-prone"
- "It'd be a lot of boilerplate to bridge that"

**Common reaches (non-exhaustive — search the package, don't recite from this list):**

| Friction the model might claim | Hex package that mostly eliminates it |
|---|---|
| snake_case ↔ camelCase / kebab-case key conversion at API boundaries | `recase` (`Recase.to_camel/1`, `Recase.Enumerable.convert_keys/2`) |
| Hand-validating + defaulting keyword option lists | `nimble_options` |
| Compile-time option/config parsing, doc generation from the schema | `nimble_options` (it generates `@moduledoc` fragments too) |
| Hand-rolling enum values + Ecto type + DB constraint | `ecto_enum` |
| HTTP client with retries, decompression, redirect-handling, JSON, multipart | `req` (almost always the right answer over `httpoison` / raw `:hackney`) |
| JSON encode/decode | `jason` |
| CSV reading with header handling, streaming, large files | `nimble_csv` |
| Struct + types + dialyzer specs + validations from one declaration | `typed_struct` |
| Schema-validated maps (incl. JSON Schema) | `nimble_options`, `peri`, `ex_json_schema` |
| Parameter parsing for CLI tools | `optimus` |
| Cron-like scheduling, recurring jobs | `oban` (also a generic background job runner — usually the right answer over custom GenServer pools) |

**How to apply:**
1. Notice the friction-claim trigger — you're about to write a sentence describing a "cost" or "downside."
2. Search hex.pm for the obvious keywords (one short search; `WebFetch` against `https://hex.pm/packages?search=<term>&sort=downloads` works). Look for packages with > a few thousand downloads + recent commits.
3. If a library handles it, **that's the recommendation** — surface it, show the ~5-line shape, and either drop the friction claim or reframe it honestly ("the boundary code is ~5 lines via `recase`").
4. If you searched and found nothing serious, *say so explicitly* ("checked hex.pm for case-conversion libraries; the choices are recase, proper_case, and macro/ — recase is the right fit") so the cost characterization comes with a citation, not an assertion.

**Sister rules:**
- "Cite Ecosystem Precedents Before Crying Complexity" (above) — same instinct narrowed to macros / DSLs.
- "Investigate Before Building" (`~/.claude/CLAUDE.md` § Working Wisdom) — same instinct for codebase dependencies.

This rule is broader than both: it catches friction-citations in *any* trade-off analysis, not just architectural pushback.

## Tightening a Validator: Trace Inputs, Not Just Callsites

**When narrowing what a function accepts at an API boundary, audit what types flow *into* it — not just who calls it.** Callsite lists are a local neighborhood; the upstream call graph is the actual contract surface.

**Three signals you're about to break a contract:**

1. **The public docstring already lists multiple shapes.** If `@doc` says "0x hex string or 20-byte binary," both shapes ARE the contract. Tightening to one shape is a breaking change, not a cleanup — even if the loose form "feels wrong."
2. **Existing tests named `"accepts X"` are about to flip to `"rejects X"`.** Stop. Those tests document the contract. Ask why they exist before flipping them. They aren't legacy noise; they're the spec.
3. **Upstream normalizers return the "wrong" shape by design.** If a helper like `Address.validate/1` is documented to return a 20-byte binary, every caller of it hands binaries forward. The validator at the boundary inherits that flow whether the local callsite list shows it or not.

**Why this fails repeatedly:** broad solutions look cleaner on paper. "Only accept the canonical form" reads as discipline. But if 30 callsites legitimately pass a non-canonical-but-documented shape, the broad fix produces 30+ failures masquerading as bugs. The lure is real — recognize it as a lure.

**How to apply:**
- Before tightening a validator, search for what types flow *into* it. `Grep` for the input — not just `Grep` for the function name.
- When flipping a test from `accepts X` → `rejects X`, pause. What contract was that test documenting? If the public API says X is legal, the test IS the spec.
- Prefer surgical fixes. The real bug is usually narrow (one ambiguous case colliding with another shape's branch). The surgical fix — accept both shapes, explicitly reject the one ambiguous combination — is almost always correct over the "while we're here, let's only accept canonical" cleanup.
- If you must broaden scope, propose it explicitly: "I can fix the narrow bug, OR I can tighten the contract to canonical-only — the second breaks N internal callers. Which?"

<!-- @-import: ~/.claude/includes/development-commands.md -->
## Development Commands

### Compilation

**Always prefix `mix compile` with `time`** — tracks compilation duration:

```bash
time mix compile
time MIX_ENV=prod mix compile
```

For tests/dialyzer/credo, see `ex-unit-json.md`, `dialyzer-json.md`. Credo: always `mix credo --strict --format json`.

### ExDNA — Duplication Detection

```bash
mix ex_dna                                # scan for duplicates
mix ex_dna --literal-mode abstract        # also catch renamed vars (Type II)
mix ex_dna --format json                  # machine-readable
mix ex_dna --ignore "lib/generated/*.ex"  # skip generated code
mix ex_dna.explain 3                      # detailed analysis of one clone
```

Config: `.ex_dna.exs`. Suppress intentional dupes with `@no_clone true`.

### ExAST — AST Search & Replace

**Prefer `ex_ast.search` over `grep` for Elixir patterns** — understands AST structure. Min version: `{:ex_ast, "~> 0.12"}`.

```bash
mix ex_ast.search 'IO.inspect(_)'                              # find debug leftovers
mix ex_ast.search --count 'Logger.debug(_)'
mix ex_ast.replace 'dbg(expr)' 'expr'                          # cleanup, preserve expression
mix ex_ast.replace --dry-run 'use Mix.Config' 'import Config'  # preview migrations

# Pipe awareness — matches both forms bidirectionally
mix ex_ast.search 'Enum.map(_, _)'                             # matches `data |> Enum.map(f)` too
mix ex_ast.search 'data |> Enum.map(f)'                        # matches `Enum.map(data, f)` too

# Ancestor-context filters
mix ex_ast.search 'Repo.get!(_, _)' --inside 'def _(_)'        # only inside function defs
mix ex_ast.search 'IO.inspect(_)' --not-inside 'test _, do: _' # skip inside tests

# Multi-node patterns (sequential statements)
mix ex_ast.search 'a = Repo.get!(_, _); Repo.delete(a)'        # N+1-ish load-then-delete pairs

# Ellipsis `...` — matches zero or more nodes (args, list items, block body)
mix ex_ast.search 'IO.inspect(...)'                            # any arity
mix ex_ast.search 'foo(first, ..., last)'                      # head + tail
mix ex_ast.search 'def run(_) do ... end'                      # any body

# Syntax-aware diff (GumTree-inspired — matches fns by name/arity,
# classifies edits :insert | :delete | :update | :move)
mix ex_ast.diff lib/old.ex lib/new.ex
mix ex_ast.diff --summary lib/old.ex lib/new.ex                # one-line per edit
mix ex_ast.diff --no-moves lib/old.ex lib/new.ex               # disable move detection
mix ex_ast.diff --json lib/old.ex lib/new.ex                   # structured output
```

**Programmatic API — quoted patterns, sigil, AST/zipper input:**

```elixir
# Quoted expressions or ~p sigil instead of strings
import ExAST.Sigil
ExAST.Patcher.find_all(source, ~p"IO.inspect(...)")
ExAST.Patcher.replace_all(ast, quote(do: IO.inspect(expr)), quote(do: dbg(expr)))

# find_all/replace_all accept source string, AST, or Sourceror.Zipper
ast = Sourceror.parse_string!(source)
ExAST.Patcher.replace_all(ast, "dbg(expr)", "expr")   # returns AST (not string)

# Syntax-aware diff as a library call
%{edits: edits} = ExAST.diff(old_source, new_source)
# edits are %ExAST.Diff.Edit{op:, kind:, summary:, old_range:, new_range:, meta:}
ExAST.apply_diff(diff_result)                         # produces patched source
```

**Multi-pattern single traversal:**

```elixir
# search_many — multiple named patterns, matches tagged with :pattern
ExAST.search_many(source, %{
  debug_inspect: ~p"IO.inspect(...)",
  dbg_call:      ~p"dbg(...)",
  console_log:   ~p"Logger.debug(_)"
}, limit: 50)
# => [%{pattern: :debug_inspect, ...}, %{pattern: :dbg_call, ...}, ...]

# ExAST.Patcher.find_many/3 — same idea, accepts source/AST/zipper
ExAST.Patcher.find_many(ast, [debug: ~p"IO.inspect(...)", trace: ~p"dbg(...)"])
```

**Selector predicates, indexing, symbol queries:**

```elixir
# piped()/not piped() in where clauses — distinguish pipe form from direct form.
# Useful when the piped subject is at a different argument slot than the direct form.
from(~p"Regex.replace(_, _, _)") |> where(piped())     # only `text |> Regex.replace(re, "")`
from(~p"Enum.map(_, _)")         |> where(not piped()) # only direct calls

# Indexing API — build an external candidate index, keep ExAST as semantic verifier
plan = ExAST.Index.plan(~p"IO.inspect(...)")
ExAST.Index.terms(plan)                                # term signals for indexing
ExAST.Selector.find_all(plan, files, source: true)     # source-aware planning

# Symbol queries — syntactic def/ref extraction with stable qualified names
ExAST.Symbols.definitions(source)                      # all def/defp/defmacro sites
ExAST.Symbols.references(source)                       # all callsites
ExAST.Symbols.qualified_name(node)                     # "MyApp.Foo.bar/2"
ExAST.Symbols.mfa(node)                                # {MyApp.Foo, :bar, 2}
```

Named captures (`expr`, `x`) in search carry to replacement. Structs/maps match partially. Run `mix format` after replacements.

<!-- @-import: ~/.claude/includes/ex-unit-json.md -->
## ExUnitJSON — `mix test.json`

AI-friendly JSON test output. Use instead of `mix test`. Default shows only failures.

### Install

```elixir
defp deps do
  [{:ex_unit_json, "~> 0.6", only: [:dev, :test], runtime: false}]
end
```

Requires Elixir 1.18+ (uses built-in `:json` — no external JSON dependency).

`cli/0` for `preferred_envs` is required — see `elixir-setup.md` (or invoke the `elixir:elixir-setup` skill if the include isn't `@`-imported in your project).

### Quick Reference

```bash
mix test.json --quiet                              # first run — failures only (default)
mix test.json --quiet --failed --first-failure     # iterate on failures (fast)
mix test.json --quiet --failed --summary-only      # verify failures fixed
mix test.json --quiet --all                        # include passing tests
mix test.json --quiet --group-by-error --summary-only  # cluster failures
mix test.json --quiet --filter-out "credentials"   # exclude known-noise patterns (repeatable)
mix test.json --quiet --cover --cover-threshold 80 # coverage gate
```

Auto-reminder: if you forget `--failed` when previous failures exist, output includes a TIP suggesting `--failed`. Skipped when already focused (file/dir target or tag filter).

**When NOT to use `--failed`:** after editing fixtures/shared setup, after adding new test files (not in `.mix_test_failures`), or when verifying a full green suite.

### Key Flags

| Flag | Purpose |
|------|---------|
| `--quiet` | **Default.** Suppresses Logger/warnings for clean JSON. Omit when debugging to see runtime output. |
| `--failed` | Re-run only previously failed tests |
| `--summary-only` | Counts only, no test details |
| `--all` | Include passing tests (default shows failures only) |
| `--failures-only` | Failed tests only (default behavior) |
| `--first-failure` | Stop at first failure |
| `--group-by-error` | Cluster failures by error message |
| `--filter-out "X"` | Exclude failures matching pattern (repeatable) |
| `--output FILE` | Write to file instead of stdout |
| `--compact` | JSONL output, one line per test |
| `--cover` / `--cover-threshold N` | Coverage collection / fail under N% |
| `--no-retry` | Disable auto-retry of failed tests (on by default) |
| `--no-warn` | Suppress "use --failed" tip when prior failures exist |

ExUnit flags compose: `mix test.json --only integration --quiet`, `mix test.json test/foo_test.exs --quiet`, `--seed 12345`.

### Automatic Retry — Flaky Healing (default on)

When a bare run has failures, `mix test.json` re-runs **only** the previously-failed tests once (ExUnit-native `--failed --all`, in a subprocess) and merges by `{module, name}`:

- **confirmed** — failed both runs → stays in `tests`, exit 2.
- **flaky** — failed then passed → moved to a top-level `flaky[]` array (named, never hidden) and no longer blocks.

If **every** first-run failure heals, `summary.result` becomes `"passed"` and the **exit code is 0** — so an agent running the default command isn't blocked by an intermittent async/GenServer/Port/LiveView red. A `retry` object (`retried`/`confirmed`/`flaky`) is added whenever a retry runs. This is the in-task version of the "small red count is a flaky-test hypothesis" discipline — no `--failed` flag needed.

**Auto-skipped** (no second run) for: `--no-retry`, `config :ex_unit_json, retry: false`, an already-green suite, and modes the naive merge can't preserve — `--failed`, `--summary-only`, `--first-failure`, `--compact`, `--group-by-error`, `--filter-out`, a `file:line` target, and umbrella projects.

```elixir
# config/test.exs — disable globally
config :ex_unit_json, retry: false
```

### Message Tracing — Flight Recorder (opt-in, v0.6+)

Capture the inter-process `send`/`receive` flow that led to a failure. Wire the setup callback once into a shared `ExUnit.CaseTemplate`:

```elixir
defmodule MyApp.Case do
  use ExUnit.CaseTemplate
  using do
    quote do
      setup {ExUnitJSON.Trace, :setup}
    end
  end
end
```

Then opt a test or module in with a tag:

```elixir
@moduletag trace_messages: true   # whole module
@tag trace_messages: true         # one test
@tag trace_messages: 200          # one test, ring buffer of 200 events
```

**Only failing tests** emit a `"trace"` block (passing tests discard it); untagged tests are a zero-cost no-op. The `messages` flow is the reliable signal; `mailboxes` is a best-effort, `approx`-labeled snapshot of processes still alive near the failure (a dead process's mailbox can't be recovered on the BEAM). `overflow: true` means a per-test event budget was hit and tracing stopped early; `dropped` counts events lost. Requires OTP 27+ (already implied by `:json`).

### Output Schema (v1)

```json
{
  "version": 1,
  "seed": 12345,
  "hint": "3 test(s) failed previously. Use --failed to re-run only those.",
  "summary": {"total": 100, "passed": 80, "failed": 20, "skipped": 0, "excluded": 0, "invalid": 0, "filtered": 15, "flaky": 2, "duration_us": 123456, "result": "failed"},
  "coverage": {"total_percentage": 92.5, "threshold": 80, "threshold_met": true, "modules": [{"module": "MyApp.Users", "percentage": 95.0, "uncovered_lines": [45, 67]}]},
  "error_groups": [{"pattern": "Connection refused", "count": 10, "example": {"file": "...", "line": 42}}],
  "retry": {"ran": true, "passes": 1, "retried": 4, "confirmed": 2, "flaky": 2},
  "flaky": [{"module": "...", "name": "...", "state": "failed"}],
  "module_failures": [{"name": "MyApp.SomeTest", "file": "test/some_test.exs", "state": "failed", "failures": [...]}],
  "tests": [{"file": "...", "name": "...", "state": "failed", "trace": {
    "messages": [
      {"t_us": 12, "dir": "send", "from": "#PID<0.310.0>", "to": "#PID<0.311.0>", "msg": "{:place_order, %{...}}"},
      {"t_us": 45, "dir": "recv", "pid": "#PID<0.311.0>", "msg": "{:ok, %Order{...}}"}
    ],
    "mailboxes": [{"pid": "#PID<0.311.0>", "registered": "MyServer", "messages": ["..."], "approx": true}],
    "overflow": false, "dropped": 0
  }}]
}
```

Conditional fields: `hint` only when prior failures exist and retry is disabled/not applicable (suppressed when auto-retry is ON — its default — because the retry supersedes the manual tip; suppressed by `--no-warn`); `coverage` only with `--cover`; `coverage.threshold_met` only with `--cover-threshold`; `summary.filtered` only with `--filter-out`; `summary.flaky` and top-level `flaky`/`retry` only when a retry actually ran; `error_groups` only with `--group-by-error`; `module_failures` only on `setup_all` failure; `tests` omitted with `--summary-only`; a test's `trace` only on a **failing** test tagged `trace_messages`. `summary.excluded` and `summary.invalid` are always present (zero when none). Test `state` is one of `"passed"`, `"failed"`, `"skipped"`, `"excluded"`, or `"invalid"` (`invalid` occurs when `setup_all` fails; it also drives `summary.result: "failed"`). A flake that healed appears in `flaky[]`, **not** `tests[]`. Trace `messages` entries differ by direction: `send` has `from`/`to`; `recv` has `pid` instead.

### Using jq

**One run captures everything — never summarize-then-detail.** `mix test.json --quiet --output /tmp/r.json` writes the full schema in one payload: `summary`, failing `tests`, `error_groups`, `coverage`, `module_failures`. Slice it after: `jq '.summary' /tmp/r.json` for the summary view, `jq '.tests[] | select(.state == "failed")'` for detail, `jq '.error_groups'` for clusters. The default output is already compacted (only failed tests in `.tests[]`), so a "summary-only first, full run for details next" pass doubles compile-cache rehydration + suite-execution cost for zero informational gain. **Do not** start with `--summary-only` to "scope the failure space" — the captured full JSON contains the summary AND the detail AND the error-groups already.

**Default to `--output FILE`. Always.** Pick a path (e.g. `/tmp/r.json`) before running. A re-run is seconds-to-minutes; a `jq` against the captured file is microseconds. Even a "one-shot" pipe is wrong-by-default: the moment you want to slice a second facet you've paid for the suite twice. Piping is the exception, not the rule — reserve it for genuinely throwaway shell composition.

Piping (when you actually need it) requires `MIX_QUIET=1` to suppress compilation output that would corrupt the JSON stream.

```bash
MIX_QUIET=1 mix test.json --quiet --summary-only | jq '.summary'
MIX_QUIET=1 mix test.json --quiet --group-by-error --summary-only | jq '.error_groups | map({pattern, count})'

mix test.json --quiet --output /tmp/results.json
jq '.tests[] | select(.state == "failed")' /tmp/results.json
jq '.tests | group_by(.file) | map({file: .[0].file, count: length})' /tmp/results.json
```

For large suites that exceed context: `--summary-only`, or `--output FILE` + selective jq.

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All tests passed (and coverage threshold met if set) |
| 2 | Failures OR coverage below threshold — JSON still valid, check `summary.result` / `coverage.threshold_met` |

Exit 2 may trigger shell error display; use `2>&1` to capture both streams.

### Strict Enforcement (optional)

```elixir
# config/test.exs
config :ex_unit_json, enforce_failed: true
```

Blocks full test runs when failures exist unless `--failed` or a focused filter is used.

<!-- @-import: ~/.claude/includes/dialyzer-json.md -->
## DialyzerJSON — `mix dialyzer.json`

AI-friendly JSON dialyzer output. Use instead of `mix dialyzer`.

### Install

```elixir
defp deps do
  [{:dialyzer_json, "~> 0.2", only: [:dev, :test], runtime: false}]
end
```

`cli/0` for `preferred_envs` is required — see `elixir-setup.md` (or invoke the `elixir:elixir-setup` skill if the include isn't `@`-imported in your project).

### Quick Start

```bash
mix dialyzer.json --quiet                          # clean JSON
mix dialyzer.json --quiet --summary-only           # health check
mix dialyzer.json --quiet --group-by-file          # which files need work
mix dialyzer.json --quiet --filter-type no_return  # focus on one type (repeatable)
```

### Key Flags

| Flag | Purpose |
|------|---------|
| `--quiet` | **Always use.** Compilation output pollutes JSON otherwise. |
| `--summary-only` | Counts by type, no details |
| `--group-by-warning` / `--group-by-file` | Cluster by type / by file |
| `--filter-type TYPE` | Only TYPE (repeatable, OR logic) |
| `--compact` | JSONL, one warning per line |
| `--output FILE` | Write to file |
| `--ignore-exit-status` | Don't fail on warnings |

### Fix Hints (prioritization)

| Hint | Meaning | Action |
|------|---------|--------|
| `"code"` | Likely real bug | Fix immediately |
| `"spec"` | Typespec mismatch | Fix the `@spec` (code probably correct) |
| `"pattern"` | Safe-to-ignore | Often intentional (third-party behaviours) |
| `"unknown"` | Unrecognized | Investigate manually |

### Workflows

```bash
# Real bugs first
MIX_QUIET=1 mix dialyzer.json --quiet | jq '.warnings[] | select(.fix_hint == "code")'

# Most common types
MIX_QUIET=1 mix dialyzer.json --quiet | jq '.summary.by_type | to_entries | sort_by(-.value)'

# Large output — write to file
mix dialyzer.json --quiet --output /tmp/dialyzer.json
jq '.warnings[] | select(.fix_hint == "code")' /tmp/dialyzer.json
```

### Output Structure

```json
{
  "metadata": {"schema_version": "1.0", "dialyzer_version": "5.4", "elixir_version": "1.19.4", "otp_version": "28", "run_at": "2026-02-02T07:00:03.768447Z"},
  "warnings": [
    {"file": "lib/foo.ex", "line": 42, "column": 5, "function": "bar/2", "module": "Foo",
     "warning_type": "no_return", "message": "Function has no local return", "raw_message": "...",
     "fix_hint": "code"}
  ],
  "summary": {"total": 5, "skipped": 0, "by_type": {"no_return": 2, "call": 3}, "by_fix_hint": {"code": 4, "spec": 1}}
}
```

**0.2+:** honors `.dialyzer_ignore.exs` (filtered → `summary.skipped`) and `:dialyzer` flags from `mix.exs` (`dialyzer_flags`, `dialyzer_removed_defaults`). `message` is dialyxir's friendly format; `raw_message` is dialyzer's original.

> **🚨 Ignore-file format gotcha — `dialyzer_json` reads ONLY the `.exs` term format.** dialyxir accepts two ignore-file shapes: the legacy **plain-text** `.dialyzer_ignore` (one substring/line per warning) and the **term-format** `.dialyzer_ignore.exs` (a list of tuples / regexes). `dialyzer_json` loads `.dialyzer_ignore.exs` **only** — it **silently ignores** a plain-text `.dialyzer_ignore`: no error, nothing suppressed, `summary.skipped: 0`, and `mix dialyzer` exits non-zero on warnings you thought were muted. The failure mode: a repo carries a working-under-dialyxir plain-text ignore, adds `dialyzer_json`, and the gate goes red for "new" warnings that were always there. **Fix:** convert to `.dialyzer_ignore.exs` term format — a list whose entries match the warning (regex against the short-description is robust: `[{~r/Unknown type: Ash.Resource.record\/0/}]`). The `.exs` term format is honored by **both** dialyxir-native and `dialyzer_json`, so converting loses nothing. Verify in-BEAM that the `FilterMap` loads and `skip?` returns `true` for the target warning before trusting the suppression. (Observed: tapakly Task 26, 2026-06 — 6 spurious OTP-29 `Ash.Resource.record/0` warnings stayed red because the ignore was plain-text.)

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | No warnings |
| 2 | Warnings found (JSON still valid) |

Piping to jq: use `MIX_QUIET=1` to suppress compilation messages.

<!-- @-import: ~/.claude/includes/workflow-philosophy.md -->
## Workflow Philosophy

Language-agnostic principles for multi-session development. Derived from Anthropic's [Harness Design for Long-Running Apps](https://www.anthropic.com/engineering/harness-design-long-running-apps).

### Session-Per-Phase

Each phase runs in a fresh session. The human orchestrates; file artifacts are the handoffs. Fresh sessions avoid context-anxiety-driven early wrap-up and force explicit state capture.

```
brainstorm/interview → .thoughts/
plan                 → reads context, writes plan to .thoughts/
implement            → reads plan, writes code, updates ROADMAP
code-review          → reviews staged changes (pre-commit)
QA                   → validates against acceptance criteria
```

Durable handoffs: ROADMAP.md (cross-session), `.thoughts/` (within-workflow). Oneshot commands (`/elixir-oneshot`) are for small-medium scope only — large features use separate sessions.

### Acceptance Criteria

Plans produce testable criteria a fresh QA session can check without ambiguity.

**Good:** "Hook returns deny JSON with permissionDecision when .py file is edited"
**Bad:** "Works correctly" / "Handles edge cases"

### Evaluator Separation

**The agent doing the work must not grade its own output** — the single strongest lever from the harness research.

- **Hooks** — real-time (post-edit compile, format)
- **`review:code-review`** — pre-commit (staged changes)
- **`/elixir-qa`** — post-implementation (against the plan)

Implementer and evaluator are always different sessions. Even with the same model, separation beats self-evaluation. For high-stakes code (auth, crypto, money, migrations), a second reviewer catches what self-review misses.

### Implementer / Reviewer Handoff

The done-signal between sessions is **staged-but-uncommitted**, not a commit. The implementer session stages the finished change set (`git add`) and stops; a fresh session runs `review:code-review` against `git diff --cached`, then commits only after approval. This is the only handoff shape that lets the reviewer see exactly what shipped *and* kept evaluator separation — if the implementer commits, they've self-graded by declaring the work mergeable.

- **Implementer:** when tests pass and docs are updated, `git add` the final set and summarise what's staged. Do **not** `git commit`, even if the task "feels done" — that's the temptation the rule exists to stop.
- **Reviewer (fresh session):** read the staged diff, run the review, stage no new code (the set being reviewed must be frozen); either approve + commit, or push back and let the original author amend the staged set in a follow-up.
- **Exception:** the user explicitly says "commit it" in the implementer session. Global CLAUDE.md's "never commit without being asked" still governs — staging is the default handoff, not a permission to commit later.

**Hand over a ready commit message.** Whenever you stop and a commit is the next step — the staged-but-uncommitted handoff above, a `⏸ CHECKPOINT`, or simply "the user will commit this" — include a ready one-line commit message in your closing summary. The user (or the next session) should never have to replay chat history to reconstruct what the commit should say. One line, imperative mood, matching the repo's existing log style.

### Batched Execution

**A sequenced plan executes as successive *batches* of disjoint work, with `/compact` rendered as explicit STOP checkpoints between batches — first-class markers, not prose.** This generalizes what `agent-dispatch` already does for delegation batches: the same disjoint-work + `/compact`-between pattern, lifted from the delegation-specific context into a general execution rule.

**When this applies (threshold-gated).** Batched structure is for genuine multi-batch work: a plan with ≥3 batches, or a multi-file migration / phased feature whose file count would blow the context window run start-to-finish. A 2-step plan needs neither fan-out nor checkpoints — the ceremony costs more than it saves. Below the threshold, plan and execute in the main session normally.

**What a batch is.** A batch is a set of work items with no unmet dependency among them — mutually disjoint, runnable simultaneously. Batches are *derived, not declared*: given a task set (e.g. an `rmap next-bundle` result), group it by `depends_on` into successive batches. A task set with no internal dependencies is a single batch. (Hierarchy: phase ⊇ bundle ⊇ batch ⊇ task.)

**Batches nest inside a phase — they don't replace it.** Session-Per-Phase still holds: each *phase* runs in a fresh session with file-artifact handoffs. A *batch* is an in-session sub-structure within one phase's work. `⏸ CHECKPOINT` / `/compact` is the lightweight in-session boundary between batches; the fresh-session handoff stays the heavier boundary between phases. Phase > batch.

**Rule 1 — disjoint work in a batch fans out to subagents.** A batch's items are disjoint by construction, so dispatch them to parallel subagents instead of running them sequentially in the main session. Constraints (per the agents docs):

- Subagents that touch files use `isolation: worktree` — parallel edits collide otherwise.
- Subagents return a *summary*, not a dump — every result lands back in main context.
- **Subagents cannot spawn subagents** — a batch's fan-out is always orchestrated from the main session.
- For a *uniform, mechanical* batch (one instruction describes every item), `/batch` is the native single-batch executor (worktree-isolated fan-out, one PR per item). `/batch` covers one batch, not the inter-batch structure.

**Rule 2 — `/compact` is a first-class STOP checkpoint between batches.** Between batches, render an explicit marker — not a prose sentence the reader must notice:

    ⏸ CHECKPOINT — batch N complete, /compact before batch N+1

At the marker: finish the batch, one-line status, then **STOP**. Hand back so the user can `/compact` and signal continue. A checkpoint is a *planned* pause, not a clarification ask — compatible with "work without stopping for questions". If the batch closes with a commit the agent isn't making itself, the checkpoint carries a ready one-line commit message (see § "Implementer / Reviewer Handoff").

**Render both, structurally.** A genuinely multi-batch plan artifact shows the batches and `⏸ CHECKPOINT` markers as distinct elements. A sentence saying "you may want to compact between phases" does *not* satisfy the rule — the marker is a line of its own.

### Model Assumption Tagging

Every hook/automation encodes an assumption about what the model can't do:

- **Convention** (permanent) — standards-enforcement regardless of model capability (format check, compile check, test runner)
- **Model-limitation** (review when models improve) — compensates for current weaknesses (nudging toward `--failed`, suggesting test patterns)

When a new model ships, review model-limitation tags and strip what's no longer load-bearing.

### Verification Before Completion

No completion claims without fresh evidence. Run the command, read the output, then claim success. Applies to tests passing, files existing, JSON being valid.

### Workflow Routing

| Situation | Tool |
|-----------|------|
| Existing roadmap task (harness BEAM running) | `@~/.claude/includes/harness-workflow.md` + `skills/harness-driver/SKILL.md` |
| Existing roadmap task (no harness) | `task-driver` skill |
| New feature from scratch | `/elixir-plan` → `/elixir-implement` |
| Pre-commit review | `review:code-review` |
| Post-implementation validation | `/elixir-qa` |
| Small-medium feature, single session | `/elixir-oneshot` |
| Large feature | Separate sessions + `.thoughts/` handoffs |

### Layered Architecture

| Layer | Scope | Example |
|-------|-------|---------|
| Global includes | Language-agnostic, loaded everywhere | `workflow-philosophy.md`, `task-prioritization.md`, `harness-workflow.md` |
| Universal skills | Language-agnostic foundations | `task-driver`, `review:code-review` |
| Language commands | Domain concerns | `/elixir-plan`, `/elixir-qa` |
| Language hooks | Real-time enforcement | `post-edit-check.sh`, `pre-commit-unified.sh` |

<!-- @-import: ~/.claude/includes/elixir-volt.md -->
## Elixir-Volt: JavaScript on the BEAM Without Node.js

The [elixir-volt](https://github.com/elixir-volt) ecosystem — Node.js replacement via Rust and Zig NIFs.

### Ecosystem

| Package | Hex | Purpose | Detail |
|---|---|---|---|
| `oxc` | `~> 0.15` | Parse, transform, bundle, minify, format, lint JS/TS (Rust NIFs) | `oxc.md` |
| `quickbeam` | `~> 0.10.15` | Run JS on the BEAM — browser APIs, DOM, fetch, crypto, WebSocket, WASM (Zig NIF) | `quickbeam.md` |
| `npm` | `~> 0.7.4` | Install npm packages, resolve deps, verify integrity, supply-chain hardening (OSV checks, exotic-dep allowlist, registry policy, package-age warnings) | Pure Elixir — `npm-*.md` |
| `npm_semver` | `~> 0.1` | npm-compatible semver | Pure Elixir |

**Phoenix frontend packages:** `volt` (build tool / dev server / HMR — replaces Vite), `oxide_ex` (Tailwind Oxide via Rust NIF), `vize_ex` (Vue SFC compiler), `phoenix_vapor` (Vue templates → LiveView rendered structs).

### npm_ex Quick Reference

```bash
mix npm.install lodash                # install
mix npm.install ccxt@^4.5             # version range
mix npm.install eslint --save-dev
mix npm.remove lodash
mix npm.list
mix npm.outdated
mix npm.tree
```

Packages install to `node_modules/`. Browser bundles (`dist/*.browser.min.js`) load into QuickBEAM.

**Specialized npm skills:**
- `elixir:npm-ci-verify` — CI, lockfile verification, reproducible builds
- `elixir:npm-security-audit` — CVE, license, supply chain
- `elixir:npm-dep-analysis` — size, graph, package quality

### When to Use What

| Need | Tool |
|---|---|
| Parse JS/TS source | OXC |
| Run a JS library (npm) | QuickBEAM + npm_ex |
| Bundle multiple JS/TS | `OXC.bundle` |
| Strip TypeScript types | `OXC.transform` |
| Extract imports | `OXC.imports` / `OXC.collect_imports` |
| Minify for production | `OXC.minify` |
| Web3 signing (ethers.js, noble-curves, starknet.js) | QuickBEAM |
| WebSocket from JS | QuickBEAM (Mint-backed) |
| WebAssembly from JS | QuickBEAM (WAMR-backed) |
| Frontend build + HMR | Volt |
| Tailwind CSS | oxide_ex |
| Vue SFC | vize_ex |

**Good for:** extraction, prototyping, web3 signing, slow-path operations, running npm libraries, DOM manipulation. **Not for:** hot-path HFT (use native Elixir / Rust NIFs for sub-ms).

For API details, usage, recipes, and pitfalls, see `oxc.md` and `quickbeam.md`.

<!-- @-import: ~/.claude/includes/quickbeam.md -->
## QuickBEAM: JavaScript Runtime for the BEAM

QuickJS-NG as a Zig NIF. Each runtime is a GenServer with a persistent JS context — run JS libraries, bridge Elixir↔JS bidirectionally. No Node.js.

**Min version: `{:quickbeam, "~> 0.10.18"}`.** Requires `oxc ~> 0.17.1` (atom-keyed AST — see `oxc.md`). Ships `QuickBEAM.Cover` (JS line coverage via `mix test --cover`), `Beam.XML.parse` (xmerl), and a default `max_stack_size` of 8MB. The bundler exposes oxc's `module_types` per-extension loader option. Vendored C symbols are hidden in the native library, so QuickBEAM can be loaded alongside other Zig/C NIFs without symbol collisions.

**`npm_ex` is optional.** QuickBEAM does not pull `npm_ex` into your dep tree. The runtime / `eval` / `call` / `load_module` path works without it. Add `{:npm, "~> 0.7.4"}` to your own `mix.exs` only when you actually need `mix npm.install`, lockfile resolution, or browser-bundle hot-loading. The public `QuickBEAM.JS` surface (`parse`, `transform`, `minify`, `bundle`, `bundle_file`) does NOT depend on npm.

**Does NOT cover:** static JS/TS analysis (→ OXC), installing npm packages (→ `mix npm.install`), frontend builds (→ Volt).

### Lifecycle

```elixir
# Start a runtime (GenServer)
{:ok, rt} = QuickBEAM.start()

# With options
{:ok, rt} = QuickBEAM.start(
  name: MyApp.JSRuntime,       # register name
  script: "priv/js/app.ts",   # file to run at startup (auto-bundles imports)
  apis: :browser,              # :browser | :node | [:browser, :node] | false
  handlers: %{},               # Elixir functions callable from JS
  define: %{},                 # compile-time globals (JSON-encoded)
  memory_limit: 256_000_000,   # 256MB default
  max_stack_size: 8_000_000,   # 8MB default — ~55 recursive frames
  max_convert_depth: 32,       # nested structure depth limit
  max_convert_nodes: 10_000    # total nodes in conversion
)

# Stop and free resources
QuickBEAM.stop(rt)

# Reset to fresh context (clears all state)
QuickBEAM.reset(rt)

# Diagnostics
QuickBEAM.info(rt)
QuickBEAM.memory_usage(rt)     # => %{malloc_size: ..., memory_used_size: ..., obj_count: ..., ...}
QuickBEAM.globals(rt)          # list all global names
QuickBEAM.globals(rt, user_only: true)  # only user-defined globals
```

**API surfaces:**

| `:apis` | Provides | Does NOT provide |
|---|---|---|
| `:browser` (default) | `fetch`, `document`, `crypto`, `WebSocket`, `URL`, `TextEncoder` | `self`, `window`, `process` |
| `:node` | `process`, `path`, `fs`, `os` | `fetch`, `document` |
| `[:browser, :node]` | Both | — |
| `false` | Bare QuickJS | Everything above |

`:browser` does NOT define `self`/`window` — see "npm Browser Bundles" for the correct stub pattern.

### Code Execution

```elixir
# Evaluate JS — supports top-level await
{:ok, 42} = QuickBEAM.eval(rt, "40 + 2")
{:ok, 42} = QuickBEAM.eval(rt, "await Promise.resolve(42)")

# With timeout (runtime remains usable after timeout)
{:error, %QuickBEAM.JSError{}} = QuickBEAM.eval(rt, "while(true){}", timeout: 1000)

# With vars — injected as globals, auto-cleaned up after execution (even on error)
{:ok, "QUICKBEAM"} = QuickBEAM.eval(rt, "name.toUpperCase()", vars: %{"name" => "quickbeam"})
{:ok, 40} = QuickBEAM.eval(rt, "items.map(i => i.price * i.qty).reduce((a, b) => a + b, 0)",
  vars: %{"items" => [%{"price" => 10, "qty" => 3}, %{"price" => 5, "qty" => 2}]})

# Evaluate TypeScript (transforms via OXC, then evaluates)
{:ok, 42} = QuickBEAM.eval_ts(rt, "const x: number = 42; x")

# Call a global JS function — auto-awaits promises
{:ok, 5} = QuickBEAM.call(rt, "add", [2, 3])
{:ok, result} = QuickBEAM.call(rt, "fetchData", [url], timeout: 10_000)
```

**`call` vs `eval`:** prefer `call` for invoking functions — native arg passing (no string interpolation), auto-awaits Promises. Use `eval` for defining functions, running scripts, or `:vars`.

### Globals

```elixir
# Set a JS global from Elixir (native BEAM->JS conversion, not JSON)
QuickBEAM.set_global(rt, "config", %{"key" => "value"})
QuickBEAM.set_global(rt, "items", [1, 2, 3])

# Get a JS global back to Elixir — returns STRING-keyed maps (not atom-keyed)
{:ok, %{"key" => "value"}} = QuickBEAM.get_global(rt, "config")

# Inline objects from eval/call are also string-keyed
{:ok, %{"x" => 1, "y" => 2}} = QuickBEAM.eval(rt, "({x: 1, y: 2})")
```

**Key type difference:** OXC AST uses atom keys; QuickBEAM returns string keys. Matters for pattern matching.

### Module Loading

```elixir
# Load ES module — top-level evaluation errors propagate as {:error, %JSError{}}
QuickBEAM.load_module(rt, "utils", "export function add(a, b) { return a + b; }")

# Compile to bytecode (for reuse across runtimes)
{:ok, bytecode} = QuickBEAM.compile(rt, code)
QuickBEAM.load_bytecode(rt, bytecode)

# Disassemble bytecode for inspection
{:ok, bc} = QuickBEAM.disasm(bytecode)
# => %QuickBEAM.Bytecode{opcodes: [{0, :push_i32, 40}, ...], ...}
```

### Handlers: JS Calling Elixir

Define Elixir functions that JavaScript can invoke:

```elixir
{:ok, rt} = QuickBEAM.start(handlers: %{
  "fetchData" => fn [url] ->
    case Req.get(url) do
      {:ok, %{body: body}} -> body
      {:error, _} -> nil
    end
  end,
  "log" => fn [message] ->
    Logger.info("JS: #{message}")
    :ok
  end
})
```

JS invokes handlers two ways:
```javascript
const data = Beam.callSync("fetchData", "https://api.example.com");    // blocks
const data = await Beam.call("fetchData", "https://api.example.com");  // Promise
```

Arguments arrive as a flat list: `Beam.callSync("fn", "a", "b")` → handler receives `["a", "b"]`.

### Loading npm Browser Bundles

```elixir
{:ok, rt} = QuickBEAM.start()

# Stub browser globals. self/window must BE globalThis, not just defined.
# set_global with an atom converts to STRING — won't work here.
QuickBEAM.eval(rt, "globalThis.self = globalThis; globalThis.window = globalThis")
QuickBEAM.set_global(rt, "navigator", %{"userAgent" => "QuickBEAM"})
QuickBEAM.set_global(rt, "location", %{"protocol" => "https:"})

bundle = File.read!("node_modules/library/dist/library.browser.min.js")
{:ok, _} = QuickBEAM.call(rt, "eval", [bundle])
{:ok, result} = QuickBEAM.eval(rt, "libraryName.doThing('input')")
```

### Returning Complex Data

Simple values and nested objects convert natively up to `max_convert_depth` (32). Beyond that, leaves become `nil` silently — return `JSON.stringify(result)` from JS and decode with Jason.

### Pools

**Pool** (full runtimes, ~2MB each — use when each needs heavy init like large bundles):
```elixir
{:ok, pool} = QuickBEAM.Pool.start_link(
  name: MyApp.JSPool, size: 10,
  init: fn rt -> QuickBEAM.eval(rt, File.read!("priv/js/app.js")) end,   # runs after creation AND reset
  lazy: false
)

result = QuickBEAM.Pool.run(pool, fn rt ->
  {:ok, val} = QuickBEAM.call(rt, "process", [data]); val
end)   # default 5000ms timeout
```

**ContextPool** (lightweight, ~58-429KB — many cheap isolated environments, per-connection/request):
```elixir
{:ok, pool} = QuickBEAM.ContextPool.start_link(name: MyApp.CtxPool, size: System.schedulers_online())
{:ok, ctx} = QuickBEAM.Context.start_link(pool: MyApp.CtxPool)
{:ok, 42} = QuickBEAM.Context.eval(ctx, "40 + 2")
QuickBEAM.Context.set_global(ctx, "x", 42)
QuickBEAM.Context.stop(ctx)
```

### DOM Access

With `:browser` APIs, native DOM is included:

```elixir
{:ok, el}   = QuickBEAM.dom_find(rt, "div.container")
{:ok, els}  = QuickBEAM.dom_find_all(rt, "li.item")
{:ok, text} = QuickBEAM.dom_text(rt, "h1")
{:ok, href} = QuickBEAM.dom_attr(rt, "a.link", "href")
```

### QuickBEAM.JS — TypeScript Toolchain

Mirrors OXC's API but runs inside a runtime. Same atom-keyed AST contract as OXC.

```elixir
{:ok, ast} = QuickBEAM.JS.parse(source, "file.ts")
{:ok, js}  = QuickBEAM.JS.transform(source, "file.ts")
{:ok, min} = QuickBEAM.JS.minify(source, "file.js")
{:ok, js}  = QuickBEAM.JS.bundle(files, entry: "main.ts")
{:ok, js}  = QuickBEAM.JS.bundle_file("entry.ts")       # resolves from disk
```

Prefer OXC (Rust NIF) for performance. Use `QuickBEAM.JS` when you need `bundle_file` (disk resolution) or are already in a runtime.

### QuickBEAM.Cover — JS Line Coverage

Integrates with `mix test --cover`:

```elixir
# mix.exs
def project, do: [..., test_coverage: [tool: QuickBEAM.Cover]]
```

**Sidecar with excoveralls:**
```elixir
# test/test_helper.exs
QuickBEAM.Cover.start()
ExUnit.after_suite(fn _ -> QuickBEAM.Cover.stop() end)
```

Writes to `cover/js_lcov.info`.

| Function | Signature | Purpose |
|---|---|---|
| `start/0`, `start/2` | `start()` / Mix callback | Begin recording |
| `stop/1`, `results/1` | `(opts \\ [])` — **not** runtime | Stop / snapshot |
| `record/1` | `(coverage_map)` — **not** runtime | Merge a runtime snapshot into global |
| `export_lcov/2`, `export_istanbul/2` | `(path, data)` — data from `results/1`/`stop/1` | Export |
| `enabled?/0` | — | Is recording active? |

Cover is centered on a `coverage_map`, not runtimes — `record`/`export` take that map, not an `rt`.

### Recipes

**Define-then-Call (standard pattern):**
```elixir
{:ok, rt} = QuickBEAM.start()
QuickBEAM.eval(rt, "globalThis.self = globalThis; globalThis.window = globalThis")
QuickBEAM.call(rt, "eval", [File.read!("node_modules/lib/dist/lib.browser.min.js")])
QuickBEAM.eval(rt, """
  globalThis.doWork = async (input) => JSON.stringify(await lib.process(input));
""")
{:ok, json} = QuickBEAM.call(rt, "doWork", [input])
result = Jason.decode!(json)
```

**Long-lived runtime in supervision tree:** wrap `QuickBEAM.start/1` in a GenServer; call `QuickBEAM.stop/1` in `terminate/2`.

**Handler bridge:**
```elixir
{:ok, rt} = QuickBEAM.start(handlers: %{
  "httpGet" => fn [url] -> Req.get!(url).body end,
  "readFile" => fn [path] -> File.read!(path) end
})
QuickBEAM.eval(rt, """
  const html = Beam.callSync("httpGet", "https://example.com");
  const config = JSON.parse(Beam.callSync("readFile", "config.json"));
""")
```

### WebSocket

Mint-backed, full JS `WebSocket` API — `onopen`, `onmessage`, `onclose`, `onerror`, `send()`, `close()`, subprotocol negotiation:

```elixir
{:ok, rt} = QuickBEAM.start(apis: :browser)

{:ok, log} = QuickBEAM.eval(rt, """
  new Promise((resolve, reject) => {
    const ws = new WebSocket("wss://stream.binance.com:9443/ws/btcusdt@trade");
    const log = [];
    ws.onopen    = () => log.push("open");
    ws.onmessage = (e) => { log.push("msg"); ws.close(); };
    ws.onclose   = (e) => { log.push("close:" + e.code); resolve(log.join(" | ")); };
    ws.onerror   = () => reject(new Error("WS error"));
  });
""", timeout: 15_000)
```

### WebAssembly

WAMR-backed, standard JS `WebAssembly` API — `Module`, `Instance`, `Memory`, `Table`, `Global`, `compile`, `instantiate`, `validate`, `CompileError`, `LinkError`, `RuntimeError`.

```elixir
{:ok, 42} = QuickBEAM.eval(rt, """
  (async () => {
    const bytes = new Uint8Array([/* add(a,b)→i32 */]);
    const inst = new WebAssembly.Instance(new WebAssembly.Module(bytes));
    return inst.exports.add(40, 2);
  })()
""", timeout: 10_000)
```

### Common Pitfalls

| Problem | Cause | Fix |
|---|---|---|
| Globals missing after bundle load | `self`/`window` set as strings | `QuickBEAM.eval(rt, "globalThis.self = globalThis")` — never `set_global` with atoms |
| `ReferenceError: self is not defined` | Library expects browser globals | Stub `self`, `window`, `navigator`, `location` before loading |
| Deep nested `nil` leaves | Exceeds `max_convert_depth` (32) | Return `JSON.stringify(result)`, decode with Jason |
| Memory grows unbounded | Runtime accumulates state | `QuickBEAM.reset/1` or stop/restart |
| Timeout on large bundle load | No default timeout | Pass `timeout: 30_000` |
| String keys unexpected | JS objects always string-keyed | Unlike OXC (atom keys) |

### DO NOT

1. Don't interpolate Elixir values into JS strings — use `call/3` with args or `:vars`.
2. Don't forget to stop runtimes — each holds native memory.
3. Don't use QuickBEAM for static JS/TS analysis — OXC is orders of magnitude faster.

### Performance

| Operation | ~Time | Notes |
|---|---|---|
| Start runtime | 5ms | GenServer + QuickJS init |
| Load 5MB bundle | 2s | One-time per runtime |
| Function call overhead | 1ms | NIF, no IPC |
| HTTP via fetch | 140ms | Network-bound (~84ms native Elixir) |
| Context creation | 1ms | Shares runtime thread |
| Runtime memory | ~2MB | With JS heap |
| Context memory | ~58-429KB | Depends on API surface |

<!-- @-import: ~/.claude/includes/oxc.md -->
## OXC: Parse, Transform, and Bundle JS/TS on the BEAM

Rust NIF bindings for the [OXC](https://oxc.rs) toolchain. Parses, transforms, minifies, and bundles JS/TS on the BEAM — no Node.js.

**Min version: `{:oxc, "~> 0.17"}`.** The atom-keyed AST contract: `:type`/`:kind` values are snake_case atoms (`:import_declaration`, not `"ImportDeclaration"`); error tuples are `{:error, [%{message: String.t()}]}`; bang functions raise `OXC.Error`. Source-taking APIs accept `iodata()` across parse / transform / minify / collect_imports / lint / format / patch_string / virtual bundle inputs. Surface includes `OXC.codegen/1,!`, `OXC.bind/2`/`splice/3` (placeholder templating), `OXC.transform_many/2` (parallel via rayon), `OXC.Format` (oxfmt as a separate Rust NIF — Prettier-compatible, ~30× faster, ships `:sort_imports` and `:sort_tailwindcss` plugins), `OXC.Lint` (oxlint's 650+ rules, custom Elixir rules via `OXC.Lint.Rule`, and `tsgolint`-backed type-aware mode), the full Rolldown (1.1+) bundle option surface (`:external`, `:exports`, `:preserve_entry_signatures`, `:conditions`, `:main_fields`, `:modules`, `:module_types`, `:cwd`), and `OXC.Bundle` (composable pipeline for multi-entry builds returning all chunks and assets via `OXC.Bundle.Result`). `OXC.bundle/2` accepts either a filesystem entry path (string) or a virtual `[{filename, source}]` project (single-entry convenience). `OXC.select/3` extracts lightweight parser events (8 selector atoms — `:import_sources`, `:asset_urls`, `:workers`, `:glob_imports`, `:require_calls`, and more) without allocating a full AST. The low-level `OXC.Native` NIF surface is public (rarely needed — use the `OXC` wrapper).

**Does NOT cover:** runtime JS execution (→ QuickBEAM), installing npm packages (→ `mix npm.install`), frontend build + HMR (→ Volt).

### Parsing

```elixir
# Parse JS or TS to ESTree AST (maps with atom keys AND atom :type/:kind values)
# File extension determines language: .ts, .tsx, .js, .jsx
{:ok, ast} = OXC.parse(source, "file.ts")
ast.type  # => :program

{:error, [%{message: msg} | _]} = OXC.parse(bad_source, "file.ts")

# Raising variant — raises OXC.Error
ast = OXC.parse!(source, "file.ts")

# Fast syntax validation (no AST allocation)
true = OXC.valid?(source, "file.ts")
```

AST uses **atom keys** AND **atom values** for `:type`/`:kind` (`:import_declaration`, `:variable_declaration`, …).

### Transform (TS → JS)

```elixir
# Strip type annotations AND interfaces, transform JSX
{:ok, js} = OXC.transform(source, "file.ts")
# "const x: number = 1; interface Foo { bar: string }" → "const x = 1;\n"

# Options
{:ok, js} = OXC.transform(source, "file.tsx",
  jsx: :automatic,           # :automatic | :classic
  jsx_factory: "h",          # custom JSX factory (classic mode)
  jsx_fragment: "Fragment",  # custom fragment
  import_source: "preact",   # JSX import source (automatic mode)
  target: "es2020",          # target ES version
  sourcemap: true            # generate source map
)
```

### Codegen

`OXC.codegen/1` emits JavaScript source from an ESTree AST. Handles precedence, indentation, semicolon insertion. **Roundtripping TS through codegen emits JS** — TypeScript type annotations, interfaces, and `as`/satisfies expressions are stripped.

```elixir
{:ok, ast} = OXC.parse("const x: number = 40 + 2;", "f.ts")
{:ok, "const x = 40 + 2;\n"} = OXC.codegen(ast)   # TS type annotation gone

js = OXC.codegen!(ast)                             # bang variant
```

Works on hand-built ASTs too — manually construct a `:program` with `.body` and codegen will emit it, as long as each node has its required ESTree fields.

### Bind & Splice — Placeholder Templating

AST-level string templating. `$placeholder` identifiers in the source are replaced with Elixir values, structurally (not by string substitution), so you can't build syntactically invalid output.

```elixir
{:ok, ast} = OXC.parse("const x = $v;", "t.js")

# Bindings is a keyword list, NOT a map
OXC.bind(ast, v: {:literal, 42})    |> OXC.codegen!()  # => "const x = 42;\n"
OXC.bind(ast, v: "userId")          |> OXC.codegen!()  # => "const x = userId;\n"   (identifier rename)
OXC.bind(ast, v: {:expr, "40 + 2"}) |> OXC.codegen!()  # => "const x = 40 + 2;\n"   (parsed sub-AST)
OXC.bind(ast, v: other_ast_node)    |> OXC.codegen!()  # raw AST node (must have :type)
```

Binding value forms:
- **string** — replaced as identifier name (rename)
- **`{:literal, v}`** — replaced with a literal node. Maps/lists recursively become JS object/array literals.
- **`{:expr, "code"}`** — parsed as a JS expression, inserted as a sub-AST
- **raw AST node** (map with `:type`) — spliced directly

`splice/3` replaces `$name` *statements*, shorthand object *properties*, or array *elements* with one or more nodes (strings auto-parse as JS):

```elixir
{:ok, ast} = OXC.parse("function f() { $body }", "t.js")
OXC.splice(ast, :body, ["const x = 1;", "return x;"]) |> OXC.codegen!()
# => "function f() {\n\tconst x = 1;\n\treturn x;\n}\n"
```

`bind` = substitute at expression positions. `splice` = substitute at statement/list positions.

### Minify

```elixir
{:ok, minified} = OXC.minify(source, "file.js")                     # DCE, constant folding, whitespace
{:ok, minified} = OXC.minify(source, "file.js", mangle: false)      # keep original names
minified = OXC.minify!(source, "file.js")                           # bang — raises OXC.Error
```

### Format

`OXC.Format` wraps oxfmt (the OXC formatter, separate Rust NIF `oxc_fmt_nif`). Prettier-compatible output, ~30× faster.

```elixir
{:ok, "const x = 1 + 2;\nfunction foo(a, b) {\n  return a + b;\n}\n"} =
  OXC.Format.run("const   x=1 +2 ; function  foo(   a,b) {return a+b ;}", "t.js")

formatted = OXC.Format.run!(source, "t.ts")   # bang variant — raises OXC.Error
```

**Prettier-ish options:** `:print_width` (default 80), `:tab_width` (2), `:use_tabs` (false), `:semi` (true), `:single_quote` (false), `:jsx_single_quote` (false), `:trailing_comma` (`:all`), `:bracket_spacing` (true), `:bracket_same_line` (false), `:arrow_parens` (`:always`), `:end_of_line` (`:lf`), `:quote_props` (`:as_needed`), `:single_attribute_per_line` (false), `:object_wrap` (`:preserve` | `:collapse`), `:experimental_operator_position` (`:start` | `:end`), `:experimental_ternaries` (false), `:embedded_language_formatting` (`:auto` | `:off`).

**`:sort_imports`** — `true` for defaults, or a map of sub-options. Groups, orders, and dedupes import declarations:

```elixir
OXC.Format.run!(source, "t.ts",
  sort_imports: %{
    ignore_case: true,        # case-insensitive sorting (default)
    sort_side_effects: false, # leave `import "x"` alone (default)
    order: :asc,              # :asc | :desc
    newlines_between: true,   # blank lines between groups
    partition_by_newline: false,
    partition_by_comment: false,
    internal_pattern: ["~/", "@/"]  # prefixes treated as internal imports
  })
```

**`:sort_tailwindcss`** — `true` for defaults, or a map. Sorts class names to Tailwind's recommended order:

```elixir
OXC.Format.run!(source, "App.tsx",
  sort_tailwindcss: %{
    config: "tailwind.config.js",  # v3 config path
    stylesheet: "app.css",         # v4 stylesheet path
    functions: ["clsx", "cn"],     # function names containing classes
    attributes: ["className"],     # extra attrs to sort
    preserve_whitespace: false,
    preserve_duplicates: false
  })
```

`oxc_fmt_nif` ships precompiled for aarch64/x86_64 glibc + darwin — **no musl builds**, so on Alpine you'll compile from source (Rust toolchain required).

### Transform Many

Parallel transform via a Rust (rayon) thread pool — significantly faster than `Task.async_stream` for many files since work is distributed across OS threads without BEAM scheduling overhead.

```elixir
# Footgun: {source, filename} — OPPOSITE order from OXC.bundle/2 ({filename, source})
results = OXC.transform_many([
  {"const a: number = 1;", "a.ts"},
  {"const b: string = 'x';", "b.ts"}
])
# => [ok: "const a = 1;\n", ok: "const b = \"x\";\n"]

# Shared opts apply to all files
OXC.transform_many(inputs, jsx: :automatic, target: "es2020")
```

Each result is `{:ok, code}`, `{:ok, %{code:, sourcemap:}}` (with `sourcemap: true`), or `{:error, errors}`. Preserves input order.

### Bundle

```elixir
js = OXC.bundle!("priv/js/app.ts", cwd: File.cwd!())   # bang — raises OXC.Error

# Virtual project — list of {filename, source} tuples; :entry REQUIRED
{:ok, js} = OXC.bundle(
  [
    {"event.ts", event_source},
    {"target.ts", target_source}  # can import from './event'
  ],
  entry: "target.ts"
)

# Filesystem entry — first arg is a real path (string), resolves packages
# from :cwd (or the file's directory). :entry is NOT used in this mode.
{:ok, js} = OXC.bundle("priv/js/app.ts", cwd: File.cwd!())

# Full options
{:ok, js} = OXC.bundle(input,
  entry: "main.ts",          # virtual-project entry filename (omit for filesystem path input)
  cwd: File.cwd!(),          # project dir — resolves packages for filesystem entries
  format: :iife,             # :iife (default) | :esm | :cjs
  minify: true,
  treeshake: true,           # remove unused exports
  preamble: "const { ref } = Vue;",  # code injected at top of IIFE body
  external: ["react", "scheduler"],  # preserve as `import` in output (bare ESM
                                     # specifiers auto-detect; this is for cases auto-detect misses)
  exports: :auto,            # :auto | :default | :named | :none
  preserve_entry_signatures: :strict,  # :strict | :allow_extension | :exports_only | false
  conditions: ["browser", "import", "default"],  # package export conditions for the resolver
  main_fields: ["browser", "module", "main"],    # package.json fields for resolution
  modules: ["node_modules"],                     # module directories
  module_types: %{".css" => :empty, ".ttf" => :dataurl},  # per-extension loader
  banner: "/* v1.0 */",
  footer: "/* end */",
  define: %{"process.env.NODE_ENV" => ~s("production")},
  sourcemap: true,           # returns %{code: ..., sourcemap: ...} instead of string
  drop_console: true,
  jsx: :automatic,
  target: "es2020"
)
```

**`:module_types` loaders:** `:js`, `:jsx`, `:ts`, `:tsx`, `:json`, `:text`, `:base64`, `:dataurl`, `:binary`, `:empty`, `:css`, `:asset`. Use `:empty` to stub out CSS/font imports that the bundler doesn't need to process.

**Filesystem vs virtual:** virtual projects (`[{filename, source}]`) are best for tests, generated sources, and the esbuild-style "load this exact string" use case. Filesystem entries (`"path/to/entry.ts"`) resolve packages through `node_modules` via `:cwd` — closes the gap the README pattern in this repo previously fills with `npx esbuild`.

### OXC.Bundle — Composable Multi-Entry Pipeline

`OXC.Bundle` wraps Rolldown's full multi-entry build — returns **all chunks and assets** as `OXC.Bundle.Result` instead of a single string. Use `OXC.bundle/2` for single-entry convenience; use `OXC.Bundle` when you need multiple entry points, output-directory writes, or want to inspect individual output chunks.

```elixir
# Multi-entry build
{:ok, %OXC.Bundle.Result{outputs: outputs, warnings: warns}} =
  OXC.Bundle.new()
  |> OXC.Bundle.entry("src/index.js")
  |> OXC.Bundle.entry("src/admin.js")
  |> OXC.Bundle.cwd(File.cwd!())
  |> OXC.Bundle.outdir("dist")
  |> OXC.Bundle.format(:esm)
  |> OXC.Bundle.minify(true)
  |> OXC.Bundle.treeshake(true)
  |> OXC.Bundle.run()

# Each output is %OXC.Bundle.Output{} with fields:
#   :code, :file_name, :path, :name, :type, :source,
#   :sourcemap, :exports, :imports, :dynamic_imports
Enum.each(outputs, fn out -> File.write!(out.path, out.code) end)
```

**Builder functions:** `new/1`, `entry/2`, `entries/2`, `file/2`, `files/2`, `cwd/2`, `outdir/2`, `format/2`, `minify/2`, `treeshake/2`, `output/2`, `resolve/2`, `transform/2`. All return the updated `OXC.Bundle.t()` struct for piping; `run/1` executes and returns `{:ok, Result.t()} | {:error, [map()]}`.

### Imports

```elixir
# Fast path — source strings only (type-only imports excluded)
{:ok, ["vue", "axios"]} = OXC.imports(source, "file.ts")

# collect_imports/2 — with type info + byte offsets
{:ok, imports} = OXC.collect_imports(source, "file.ts")
# => [%{specifier: "vue", type: :static, kind: :import, start: 19, end: 24}, ...]
# Fields: :specifier, :type (:static | :dynamic), :kind (:import | :export | :export_all),
#          :start, :end (byte offsets, including quotes)
```

### Select (Compact Parser Events)

`OXC.select/3` extracts lightweight metadata from source in a single pass — no full AST allocation. Faster than `parse` + walk when you only need import/export shapes or asset references.

```elixir
# Selector is an atom; returns {:ok, list} | {:error, errors}
{:ok, refs} = OXC.select(source, "file.ts", :import_sources)
# => [%{specifier: "vue", type: :static, kind: :import, start: 20, end: 25}]
```

Available selectors:

| Selector | Returns |
|---|---|
| `:import_sources` | import/export specifiers with `:type`, `:kind`, byte `:start`/`:end` (superset of `collect_imports`) |
| `:import_specifiers` | just the specifier strings |
| `:asset_urls` | `new URL(...)` references with byte positions |
| `:workers` | Web Worker constructor call sites |
| `:glob_imports` | `import.meta.glob(...)` patterns |
| `:import_meta_env` | `import.meta.env.*` accesses |
| `:dynamic_import_templates` | template-literal dynamic imports |
| `:require_calls` | CommonJS `require()` calls |

**Prefer `OXC.imports/2` or `OXC.collect_imports/2`** for the common case of just listing static import specifiers — they predate `select/3` and are equally fast. Use `select/3` when you need non-import event types (assets, workers, env refs, require calls).

### Rewrite Specifiers

```elixir
# Callback MUST return {:rewrite, new} | :keep — bare string raises CaseClauseError.
{:ok, rewritten} = OXC.rewrite_specifiers(source, "file.ts", fn
  "vue" -> {:rewrite, "/@vendor/vue.js"}
  _ -> :keep
end)
rewritten = OXC.rewrite_specifiers!(source, "file.ts", fn  # bang — raises OXC.Error
  "vue" -> {:rewrite, "/@vendor/vue.js"}
  _ -> :keep
end)
```

Cleaner than parse → collect → patch for simple rewrites.

### Patch String

```elixir
patched = OXC.patch_string(source, [
  %{start: 10, end: 20, change: "replacement"},
  %{start: 30, end: 35, change: ""}            # deletion
])
```

Use `.start`/`.end` from AST nodes — byte offsets. Patches can be in any order (sorted internally). For specifier rewrites, prefer `rewrite_specifiers/3`.

### AST Navigation

Pattern-match on atoms:

```elixir
{:ok, ast} = OXC.parse(source, "file.ts")

# ast.body is a list of top-level statements
# `export default class` → top is :export_default_declaration with .declaration
export = Enum.find(ast.body, &(&1.type == :export_default_declaration))
class = export.declaration
# Plain class (no export default) → :class_declaration directly:
class = Enum.find(ast.body, &(&1.type == :class_declaration))

class.id.name           # nil if anonymous
class.superClass.name   # nil if no extends
class.body.body         # class members

methods = Enum.filter(class.body.body, &(&1.type == :method_definition))
# method.key.name, method.value.async, .params, .body.body
# FunctionExpression (method.value) keys: :async, :id, :params, :body, :generator,
# :declare, :typeParameters, :expression, :returnType
```

#### Key ESTree Node Types

Atom names follow PascalCase → snake_case (`"FooBar"` in the ESTree spec is `:foo_bar` here).

| Atom | Key Fields |
|------|------------|
| `:program` | `.body` |
| `:export_default_declaration` | `.declaration` |
| `:export_named_declaration` | `.declaration`, `.specifiers`, `.source` |
| `:class_declaration` | `.id.name`, `.superClass`, `.body.body` |
| `:method_definition` | `.key.name`, `.value` (function_expression) |
| `:function_expression` | `.async`, `.params`, `.body.body`, `.returnType` |
| `:function_declaration` | `.id.name`, `.params`, `.body.body` |
| `:arrow_function_expression` | `.async`, `.params`, `.body` |
| `:object_expression` | `.properties` |
| `:array_expression` | `.elements` |
| `:literal` | `.value` (string/number/boolean/null) |
| `:identifier` | `.name` |
| `:call_expression` | `.callee`, `.arguments` |
| `:unary_expression` | `.operator`, `.argument` |
| `:member_expression` | `.object`, `.property` |
| `:return_statement` | `.argument` |
| `:import_declaration` | `.source.value`, `.specifiers` |
| `:variable_declaration` | `.declarations`, `.kind` (`:var`/`:let`/`:const`) |

Unknown atom for a type? Run `OXC.parse(source, "file.ts")` and inspect `ast.body |> hd() |> Map.get(:type)` — runtime is authoritative.

#### Type Annotations (TypeScript)

Nested under `.typeAnnotation.typeAnnotation`:

```elixir
# function(x: string)
type_name = get_in(param, [:typeAnnotation, :typeAnnotation, :typeName, :name])
```

### Traversal

```elixir
# walk — side-effects only, returns :ok
:ok = OXC.walk(ast, fn
  %{type: :call_expression, callee: c} -> IO.inspect(c)
  _ -> :ok
end)

# postwalk — depth-first post-order (children before parents)
transformed = OXC.postwalk(ast, fn
  %{type: :identifier, name: "old"} = node -> %{node | name: "new"}
  node -> node
end)

# postwalk with accumulator
{_ast, patches} = OXC.postwalk(ast, [], fn
  %{type: :import_declaration, source: %{value: "vue"} = src} = node, acc ->
    {node, [%{start: src.start, end: src.end, change: "'/@vendor/vue.js'"} | acc]}
  node, acc -> {node, acc}
end)
# For this specific rewrite, prefer OXC.rewrite_specifiers/3.

# collect — {:keep, value} collects, :skip ignores
method_names = OXC.collect(ast, fn
  %{type: :method_definition, key: %{name: name}} -> {:keep, name}
  _ -> :skip
end)
```

### Lint

`OXC.Lint` wraps oxlint (650+ rules, Rust-speed) and lets you add Elixir-side custom rules that walk the same atom-keyed AST `OXC.parse/2` returns.

```elixir
# Built-ins only — severity is :allow | :warn | :deny
{:ok, diags} = OXC.Lint.run(source, "app.tsx",
  plugins: [:react, :typescript],
  rules: %{"no-debugger" => :deny, "no-console" => :warn}
)

# Bang variant — raises OXC.Error on parse failure, returns diags list directly
diags = OXC.Lint.run!(source, "app.tsx", rules: %{"no-debugger" => :deny})

# Diagnostic shape (rule is namespaced — "eslint(no-debugger)"):
# %{rule: "eslint(no-debugger)", severity: :deny, message: "...",
#   span: {start, end}, labels: [{s, e}], help: String.t() | nil}

# Custom Elixir rules — module implements OXC.Lint.Rule (meta/0 + run/2)
{:ok, diags} = OXC.Lint.run(source, "app.ts",
  custom_rules: [{MyApp.NoConsoleLog, :warn}]
)
```

Plugin atoms: `:react`, `:typescript`, `:unicorn`, `:import`, `:jsdoc`, `:jest`, `:vitest`, `:jsx_a11y`, `:nextjs`, `:react_perf`, `:promise`, `:node`, `:vue`, `:oxc`. Default is oxlint's correctness set (no plugin flag needed for rules like `no-debugger`).

`:fix` option computes suggested fixes; `:settings` passes arbitrary context to custom rules.

**Type-aware linting (`type_aware: true`)** — runs through `tsgolint` headless mode for rules that need TypeScript type information. Accepts a file list plus the project's tsconfig and emits normalized diagnostics with fixes and suggestions in the same shape as parse-only output.

```elixir
{:ok, diags} = OXC.Lint.run(file_list, "tsconfig.json",
  type_aware: true,
  type_check: true,           # run tsgolint's type-check phase
  source_overrides: %{"src/x.ts" => override_source},
  rules: %{"no-floating-promises" => :deny}
)
```

Nonzero `tsgolint` exits — including panics from unsupported input files — surface as `{:error, ...}` with stderr captured. Empty or malformed `tsgolint` output is reported as an error rather than silently treated as a clean run.

Category filters (e.g. `rules: %{"correctness" => :deny}`) honor the configured severity instead of always reporting `:warn`.

### Recipes

**Recursive AST value extraction** (object_expression/array_expression/literal → Elixir):

```elixir
extract = fn
  %{type: :literal, value: v}, _r -> v
  %{type: :object_expression, properties: props}, r ->
    Map.new(props, fn p ->
      key = Map.get(p.key, :name) || to_string(Map.get(p.key, :value, "?"))
      {key, r.(p.value, r)}
    end)
  %{type: :array_expression, elements: els}, r -> Enum.map(els, &r.(&1, r))
  %{type: :identifier, name: "undefined"}, _r -> :undefined
  %{type: :identifier, name: n}, _r -> {:ref, n}
  %{type: :unary_expression, operator: "-", argument: %{value: v}}, _r -> -v
  %{type: :call_expression} = node, _r ->
    callee = get_in(node, [:callee, :property, :name]) || "unknown"
    {:call, callee, Enum.map(node.arguments, &Map.get(&1, :value, "?"))}
  %{type: t}, _r -> {:ast, t}
  nil, _r -> nil
end

value = extract.(config_node, extract)   # Y-combinator: anon fns can't self-recurse
```

**Find method in class:**
```elixir
export = Enum.find(ast.body, &(&1.type == :export_default_declaration))
methods = Enum.filter(export.declaration.body.body, &(&1.type == :method_definition))
target = Enum.find(methods, &(&1.key.name == "describe"))
```

**Find property in ObjectExpression** (keys can be identifier `.name` or literal `.value`):
```elixir
Enum.find(object_node.properties, fn p ->
  (Map.get(p.key, :name) || Map.get(p.key, :value)) == "id"
end)
```

### Error Handling

```elixir
case OXC.parse(source, "file.ts") do
  {:ok, ast} -> process(ast)
  {:error, errors} ->
    for %{message: msg} <- errors, do: Logger.warning("OXC: #{msg}")
end

try do
  OXC.parse!(source, "file.ts")
rescue
  e in OXC.Error -> Logger.error(Exception.message(e))
end
```

### Common Pitfalls

| Problem | Cause | Fix |
|---|---|---|
| `KeyError` on node | Optional fields missing | Match `.type` first, use `Map.get/3` for optionals |
| `.superClass` is nil | No `extends` | Check `is_nil(class.superClass)` |
| Property key access fails | Keys can be identifier or literal | `p.key.name \|\| p.key.value` |
| Wrong file extension | Extension picks parser | `.ts`, `.tsx`, `.js`, `.jsx` |
| Y-combinator forgotten | Anon fns can't self-recurse | Pass `fn` as arg |
| `bundle/2` empty | Missing `:entry` (virtual project) | `:entry` is required when input is `[{filename, source}]`; omit it when input is a filesystem path string |
| `transform_many`/`bundle` arg order reversed | `transform_many` is `{source, filename}`; `bundle` is `{filename, source}` | Remember: bundle files are virtual project *files* (filename first); transform inputs are *sources* being labeled |
| `OXC.bind` `FunctionClauseError` | Passed a map `%{v: ...}` | Bindings must be a keyword list `[v: ...]` |
| TS types vanish after `codegen` roundtrip | `codegen` emits JS, not TS | Expected — codegen is not an identity function on TS |

### DO NOT

1. Don't use string keys — always atom-keyed maps (`node.type`, not `node["type"]`).
2. Don't parse just to validate — use `OXC.valid?/2`.
3. Don't parse just for imports — use `OXC.imports/2`, `OXC.collect_imports/2`, or `OXC.select/3` (for non-import events like `:asset_urls` or `:require_calls`).
4. Don't hand-roll import rewrites — `OXC.rewrite_specifiers/3` is a single pass.
5. Don't use OXC to run JS — static analysis only. Use QuickBEAM for runtime.
6. Don't use `OXC.bundle/2` for multi-entry builds — use `OXC.Bundle` pipeline to get all chunks and assets.

### Performance

| Operation | ~Time |
|---|---|
| Parse 14.5k-line TS | 43ms |
| Transform TS→JS | 10ms |
| Minify | 5ms |
| `valid?` | 20ms |
| `imports` | 15ms |
| `collect_imports` | 20ms |

Rust NIF, CPU-bound. For batch transform, prefer `OXC.transform_many/2` (rayon thread pool) over `Task.async_stream` — distributes across OS threads without BEAM scheduling overhead.

<!-- @-import: ~/.claude/includes/ethereum-rpc.md -->
## Ethereum RPC (Full Archive Node)

We run our own full archive Ethereum node on `blockwatch-one`. Available across all onchain projects.

**Access from Mac:**

| Method | HTTP | WebSocket |
|--------|------|-----------|
| SSH tunnel | `http://localhost:8545` | `ws://localhost:8546` |
| WireGuard VPN | `http://10.100.0.1:8545` | `ws://10.100.0.1:8546` |

**SSH tunnel setup:**
```bash
ssh -L 8545:127.0.0.1:8545 -L 8546:127.0.0.1:8546 blockwatch-one
```

**For integration tests:**
```bash
ETHEREUM_API_URL=http://localhost:8545 mix test.json --quiet --include integration
```

**If RPC connection fails (timeout, connection refused):** Do NOT try to diagnose or fix networking. Ask Tito to:
- Check if the SSH tunnel is running
- Start WireGuard if needed
- Verify the node is up on blockwatch-one

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

<!-- @-import: ~/.claude/includes/upstream-pr-workflow.md -->
## Upstream PR Workflow (Forked Libraries)

How to contribute back to a forked external library without leaking your personal tooling stack into the PR diff — and without letting your project-scoped Claude hooks enforce *your* standards on *their* code.

### 1. When This Applies

You forked an external library on GitHub, cloned your fork, and want to land a PR upstream. This is the opposite of greenfield work in your own repos: **their conventions win**. Your full dev stack (`ex_unit_json`, `dialyzer_json`, `credo`, `tidewave`, `ex_dna`, etc.) is for *your* feedback loop, not a mandate to impose on maintainers who never opted into it.

### 2. Setup

Two shapes, pick by isolation need.

**Worktree off `upstream/main`** — fastest, reuses the existing fork clone:

```bash
cd /path/to/your-fork
git remote add upstream <upstream-url>    # one-time
git fetch upstream
git worktree add -b feat/<feature> ../upstream-<feature> upstream/main
cd ../upstream-<feature>
```

**Separate clone** — cleaner isolation when upstream's stack diverges heavily (different Elixir/OTP major, Erlang-only, polyglot repo where your Elixir tooling is just noise):

```bash
git clone <your-fork-url> ~/_DATA/code/upstream-<project>
cd ~/_DATA/code/upstream-<project>
git remote add upstream <upstream-url>
git fetch upstream
git checkout -b feat/<feature> upstream/main
```

The "no branches/worktrees without explicit permission" rule in `critical-rules.md` still governs — contributing upstream is itself the explicit task, so that permission is scoped to the contribution and nothing else.

### 3. Your Stack Works There (Mostly)

Your personal tooling is **additive** — it runs locally, produces reports, and doesn't touch upstream's code. Layer these into the clone's `mix.exs` under `only: [:dev, :test], runtime: false` and use them normally:

| Tool | Command | Safe upstream? |
|------|---------|----------------|
| ex_unit_json | `mix test.json --quiet` | ✅ read-only |
| dialyzer_json | `mix dialyzer.json --quiet` | ✅ read-only |
| credo | `mix credo --strict --format json` | ✅ read-only |
| dialyxir | `mix dialyzer` | ✅ read-only |
| ex_dna | `mix ex_dna` | ✅ read-only |
| ex_ast | `mix ex_ast.search 'pattern'` | ✅ `search` only — `ex_ast.replace` **rewrites files** |
| doctor | `mix doctor` | ✅ read-only |
| tidewave | `iex -S mix tidewave` + MCP | ✅ runtime-only |
| **styler** | — | **🚨 DO NOT ENABLE** |

Coverage thresholds, complexity KPIs, and Credo strictness are **your** standards — treat their output as advisory. Upstream's bar is upstream's bar.

**🚨 Styler is the exception — do NOT enable it unless upstream already uses it.** Every other tool in the stack is read-only relative to upstream's source. Styler is a `mix format` plugin: the moment `plugins: [Styler]` lands in `.formatter.exs`, every subsequent `mix format` — editor-on-save, PostToolUse hook, CI — aggressively restyles whatever file it touches to Styler conventions. That produces a PR diff full of unrelated reformatting that maintainers will (correctly) refuse. **Leave `.formatter.exs` exactly as upstream ships it.** If your muscle-memory includes adding Styler, actively resist.

### 4. Don't Leak Personal Tooling into the PR Diff

The tools run locally; their fingerprints stay local. Concrete "keep out of the staged diff" list:

- **`mix.exs`** — entries for `ex_unit_json`, `dialyzer_json`, `credo`, `dialyxir`, `doctor`, `tidewave`, `bandit` (if you added it for Tidewave), `ex_dna`, `ex_ast`, `descripex`, `api_toolkit`. Also `styler` — but per §3 you shouldn't have added it in the first place.
- **`cli/0`** — `preferred_envs` additions for `test.json` / `dialyzer.json`.
- **`.formatter.exs`** — must match upstream byte-for-byte. If you slipped and added a plugin, revert it *before* running `mix format` again, or the plugin's last run is already baked into your diff.
- **`.credo.exs`** — your strict/custom config.
- **`CLAUDE.md`** — your project instructions (checked-in files show up in diff).
- **`.mcp.json`** — your Tidewave port mapping.
- **`.ex_dna.exs`, `.dialyzer_ignore.exs`, `.doctor.exs`** — tool configs.
- **Inline pragmas** — `@no_clone true` (ex_dna), `sobelow_skip`, `@moduledoc false` stamped by Doctor workflows, etc.
- **`TODO:` comments** you added during exploration — Credo-visible for you, noise for them.

Run these before every commit:

```bash
git diff --cached --name-only        # what am I about to commit
git diff --cached | grep -E 'ex_unit_json|dialyzer_json|tidewave|styler|ex_dna|ex_ast|credo|doctor|@no_clone|TODO:'
```

If upstream ships its own `mix.exs` / `.credo.exs` / `.formatter.exs`, the clean pattern is:

1. Do the work with your local tooling edits present.
2. `git checkout upstream/main -- mix.exs .formatter.exs .credo.exs` to restore their versions.
3. Stage only your actual code changes.

### 5. Bypass Project Hooks with Your Shell Aliases

Claude Code's project-scoped hooks (`post-edit-check.sh`, `pre-commit-unified.sh`, dialyzer wrapper) match on the **literal command string** Claude sends via the Bash tool — `mix test`, `mix dialyzer`, `git commit`. Aliases expand inside zsh *after* the hook matcher has already decided to pass, so Claude invoking `mt` via the Bash tool bypasses the project's format/test hook even though the expanded form (`mix format && time mix test`) would have matched.

| Alias | Expands to | Why it bypasses |
|-------|------------|-----------------|
| `gc -m "msg"` | `git commit --verbose -m "msg"` | Hook matches `git commit`, not `gc` |
| `mt` | `mix format && time mix test` | Hook matches `mix test`, not `mt` |
| `mdlzer` | `mix dialyzer` | Hook matches `mix dialyzer`, not `mdlzer` |

`gc` takes the same flags as `git commit` (so `gc -m "msg"` or `gc -am "msg"` both work). Use a HEREDOC for multi-line messages exactly as you would with `git commit`.

**Use these directly via Bash** — `mt` for the suite, `mdlzer` for a dialyzer run, `gc -m "msg"` to commit. Claude running them is fine; the alias indirection does the work. Reserve `!` shell-escape for cases where you explicitly want the user to do the typing (e.g. interactive auth flows), not as a workaround for hooks the aliases already handle.

**When bypassing is appropriate (not just upstream contributions):** any forked or ported-in codebase where `pre-commit-unified.sh` flags pre-existing issues in files your current commit didn't touch — Credo style drift, Doctor spec-coverage gaps, Sobelow flags in legacy code, etc. The hook runs against the full project, not just the staged diff; a flagged issue is only load-bearing when it's *in your diff*. Before using `gc`, confirm with `git diff --cached --name-only` that the flagged files aren't yours. If they are, fix the issue instead.

**Still do not bypass** when the flag is inside your staged diff, when tests actually fail (that's a correctness failure, not a style artifact), or when the user asks you to fix the issue instead of bypass it. The default remains global `critical-rules.md`: "never skip hooks without explicit request" — these aliases are that explicit request, configured once in the shell.

### 6. Cleanup

After the PR merges or is abandoned:

- **Worktree:** from the main fork clone, `git worktree remove <path>` then `git branch -D feat/<feature>`. Removing the worktree is part of completing the task — orphan worktrees are the failure mode that earned the "no worktrees without permission" rule in `critical-rules.md`.
- **Separate clone:** `rm -rf <clone-dir>` (or move it to `~/.Trash` if you'd rather keep it recoverable) — double-check the path first per `critical-rules.md` shell-safety.
- **Keep your fork current:** on the main clone, `git fetch upstream && git merge upstream/main && git push origin main`, so the next contribution starts from a clean base.


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
```

## Toolchain & check commands

For cross-family reviewers (codex / cursor / grok) who don't inherit this repo's Claude Code hooks or skills:

- **Canonical gate:** `mix precommit.full` — runs format-check, compile (warnings-as-errors), credo `--strict`, doctor, the test+cover gate (95% — MPP is critical-tier: money, signing, wire-format encoding), sobelow, and dialyzer. `mix precommit` is the same minus dialyzer; `mix check.fast` is the seconds-long inner-loop (format + compile + credo).
- **`mix test.json` (`ex_unit_json`) and `mix dialyzer.json` (`dialyzer_json`) emit JSON by design** — parse it for real failures (`summary.result`, `coverage.threshold_met`, `warnings[]`); **never flag the JSON envelope itself as a build failure.** A non-empty JSON document on stdout is a *successful* run, not an error.
- When `dialyzer.json`'s encoder can't serialize a warning shape, **plain `mix dialyzer` is the authoritative dialyzer check.**
- Integration tests (`:integration` tag) are excluded from the gate — they need live testnet/Stripe credentials. Run explicitly with `mix test.json --include integration`.

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
MPP.Credential             — Credential parsing, challenge echo validation, payload extraction
MPP.Receipt                — Receipt struct, base64url JSON serialization
MPP.Headers                — Parse/format WWW-Authenticate, Authorization, Payment-Receipt
MPP.Errors                 — RFC 9457 problem types (paymentauth.org/problems/*), includes session error types
MPP.Intents.Charge         — Charge intent request schema (amount, currency, recipient, ...)
MPP.BodyDigest             — SHA-256 body digest compute/verify for request body binding
MPP.Amount                 — Amount/decimals helpers: parse_units, with_base_units, parse_dollar_amount
MPP.JCS                    — RFC 8785 JSON Canonicalization Scheme (MPP subset: ASCII keys, no floats) for cross-SDK HMAC interop
MPP.Verifier               — Transport-neutral verification pipeline (HMAC, realm, expiry, request match, method.verify)
MPP.Method                 — Behaviour for pluggable payment methods (verify/2)
MPP.Methods.Stripe         — Stripe SPT → PaymentIntent verification (Req, no Stripe SDK)
MPP.Methods.Tempo          — Tempo on-chain TIP-20 transfer verification (delegates chain ops to onchain_tempo)
MPP.Methods.EVM            — Generic EVM on-chain transfer verification (any chain: Ethereum, Base, Polygon, etc.)
MPP.Methods.Tempo.SessionReceipt — Session-intent receipt for Tempo (to_header/from_header, camelCase wire keys)
MPP.Methods.Tempo.FeePayerPolicy — Sponsor gas-economics policy: bounds client gas fields before fee-payer co-sign (anti-drain)
MPP.Tempo.Store            — Behaviour for optional tx dedup stores (get/put + optional atomic check_and_mark)
MPP.Tempo.ConCacheStore    — Built-in ETS dedup store with TTL via ConCache (optional dep)
MPP.Plug                   — HTTP Plug middleware, delegates verification to MPP.Verifier
MPP.Plug.MethodEntry       — Per-method config within a multi-method endpoint (method, charge, request, method_config)
MPP.Plug.Config            — Validated endpoint config struct (shared settings + list of MethodEntry structs)
MPP.Mcp                    — MCP (JSON-RPC) transport: constants (-32042/-32043, meta keys), server/client helpers
MPP.Client.PaymentProvider — Behaviour for client-side payment providers (supports?/3, pay/2)
MPP.Client.MultiProvider   — Multi-provider dispatch: wraps [{module, config}], routes to first match
MPP.Client.Transport       — Transport behaviour: payment_required?/1, get_challenges/1, set_credential/2 + select_challenge/2 helper
MPP.Client.Transport.HTTP  — HTTP transport over Req: 402 detection, WWW-Authenticate parsing, Authorization: Payment attach
MPP.Demo.Method            — Toy payment method accepting "demo-token" (for mix mpp.demo)
MPP.Demo.Router            — Plug.Router demo server with protected /resource endpoint
```

### Design decisions

- **Stateless HMAC-bound challenges.** Challenge ID = `base64url(HMAC-SHA256(secret, realm|method|intent|request|expires|digest|opaque))`. No challenge store needed — the server recomputes and does constant-time comparison on verification.
- **Intent = Schema, Method = Implementation.** `MPP.Intents.Charge` defines the shared request schema (amount, currency, recipient). `MPP.Method` implementations only handle verification. All methods share the same intent structs.
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
- `con_cache` — ETS-based TTL cache for `MPP.Tempo.ConCacheStore` dedup store
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
- MCP server at `.mcp.json` — `mcp__mpp__*` tools for cross-referencing SDK source code:
  - `search_source` / `read_source_file` / `get_file_tree` — work for **mppx**, **mpp-rs**, **pympp**, **tempo**
  - `list_pages` / `search_docs` — not functional (docs not indexed); use WebFetch for mpp.dev content
  - `mpp-specs` source — empty via MCP; use local `refs/mpp-specs/` instead

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

## Git Commit Configuration

**Configured**: 2026-03-25

### Commit Message Format

**Format**: imperative-mood

#### Imperative Mood Template
```
<description>
```
Start with imperative verb: Add, Update, Fix, Remove, etc.
