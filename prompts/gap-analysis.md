# Gap Analysis Prompt — ROADMAP.md vs. upstream SDKs and spec

Reusable prompt for a fresh session. Before kicking off, update:

- `{{LAST_ANALYSIS_DATE}}` — date of the most recent gap analysis (search ROADMAP.md / CHANGELOG.md or prior analysis reports)
- `{{CURRENT_PHASE_SUMMARY}}` — one line: which phases are done, which are in flight, which are queued

Also verify `refs/mppx`, `refs/mpp-rs`, `refs/mpp-specs` are at origin HEAD:

```bash
for d in refs/mppx refs/mpp-rs refs/mpp-specs; do
  (cd "$d" && git fetch --depth=1 origin && git reset --hard origin/HEAD && git log -1 --format="%h %ci %s")
done
```

---

## Task: Gap analysis — ROADMAP.md vs. reference SDKs and spec

You're working on **ZenHive/mpp** (`/Users/efries/_DATA/code/mpp`), the Elixir implementation of the Machine Payments Protocol. Our roadmap tracks features we've built vs. features we still need to build. The reference SDKs and the spec evolve continuously, and our roadmap can drift behind.

**Your job:** find what *they* now ship (or *the spec* now defines) that we *don't* have, and propose concrete roadmap updates.

**Last gap analysis:** {{LAST_ANALYSIS_DATE}}
**Current phase state:** {{CURRENT_PHASE_SUMMARY}}

## Scope

Investigate three upstream sources in roughly this priority order:

1. **Local reference clones** under `refs/` — `refs/mppx/` (TypeScript, primary), `refs/mpp-rs/` (Rust), `refs/mpp-specs/` (IETF spec source). These are auto-updated on session start, so they should reflect current upstream. Read them directly with Read/Grep/OXC — do NOT WebFetch GitHub mirrors.
2. **IETF spec site:** https://paymentauth.org/ — check for new draft revisions, new method specs, new intent types, or new header/error semantics since the last analysis.
3. **Non-cloned SDKs** (fetch on demand only if a gap looks promising): `pympp` (Python) and `mpp-go` (Go) — both listed as official on https://mpp.dev/sdk. Python and Go specifically offer "framework middleware integrations" per the SDK index, so they may reveal adapter patterns we lack.

## Method

1. **Start with the roadmap.** Read `ROADMAP.md` and `CHANGELOG.md` to understand:
   - What we've shipped.
   - What's queued / in flight.
   - What's explicitly deferred or scoped out (SSE, store backends, HTML/UI, `mpp_proxy`).

2. **Enumerate upstream surface.** For each of mppx and mpp-rs, list top-level modules/exports:
   - mppx: use OXC on `refs/mppx/src/*.ts` — `OXC.collect_imports/2` across the tree, plus exported symbols. Look especially for files we haven't seen before (new methods under `src/methods/`, new transports, new intent types, new utility modules).
   - mpp-rs: `Grep` for `pub mod`, `pub fn`, `pub struct` across `refs/mpp-rs/src/`. Note new modules and public types.
   - mpp-specs: `ls refs/mpp-specs/specs/` and note any method drafts or intent drafts not yet in our ROADMAP.
   - **Commit history hint:** `git log --since={{LAST_ANALYSIS_DATE}} --oneline` in each clone can surface what changed since last pass — often the fastest way to spot new features.

3. **Diff against our module map.** Our module map lives in `CLAUDE.md` under "Module map." For each upstream capability, classify:
   - **We have it** (skip).
   - **Already planned** (roadmap task exists — note the task number; check if upstream's shape changed enough that the plan needs revision).
   - **Gap** (not ours, not planned). These are candidates for new tasks.

4. **Check paymentauth.org.** WebFetch https://paymentauth.org/ and any linked drafts. Look for:
   - New problem types / error URIs under `paymentauth.org/problems/*` beyond what `MPP.Errors` covers.
   - Clarifications or additions to `WWW-Authenticate` / `Authorization` / `Payment-Receipt` parsing.
   - New intent kinds beyond charge and session.
   - Canonicalization or signature changes (we implement RFC 8785 JCS — check if other schemes are now specified).

5. **Prioritize.** For each gap, score with our D/B/U framework (see `ROADMAP.md` for examples; 1–10 scale each; Eff = (B+U)/(2×D)). Respect existing policy: we're a library, not an app; no global config; `mpp_proxy` is out of scope.

## Deliverable

**Do NOT edit ROADMAP.md yourself.** Return a findings report in chat with:

1. **"Upstream shipped since last pass"** — bulleted list. One line per capability: source (mppx/mpp-rs/spec), path, one-sentence description.
2. **"Gaps in our roadmap"** — table. Columns: gap, source evidence (file:line), proposed task title, D/B/U score, proposed phase.
3. **"Existing tasks that need revision"** — table. Columns: task number, current description gist, what changed upstream, suggested revision.
4. **"Worth reconsidering as scoped-out"** — anything we explicitly deferred (SSE, store backends) that upstream has now made more central. Don't flip decisions unilaterally — flag for discussion.
5. **"Proposed ROADMAP.md edits"** — concrete diff sketch (header changes, new phase entries, revised task bodies). Markdown blocks showing before/after.

Keep the report dense but scannable — the next session will use it as the input to an actual ROADMAP.md edit pass.

## Constraints

- **Don't *rewrite* the Elixir codebase.** Gap analysis produces a report, not edits. The module map in `CLAUDE.md` is the default source of truth for "have it / don't have it." Read our actual code only when (a) a gap claim is ambiguous, (b) a planned task's current shape matters for revision, or (c) the map looks stale. Pick one mode per claim — trust the map or read thoroughly; don't skim.
- **Don't clone new repos.** If `pympp` or `mpp-go` look promising after the mppx/mpp-rs pass, use `gh api` or targeted WebFetch — don't add to `refs/`.
- **Flag genuine spec ambiguities** rather than guessing. If paymentauth.org defines something we can't map cleanly to an Elixir construct, note it as an open question.
- **Respect the library-not-app boundary.** Features that belong in `mpp_proxy` (gateway/reverse-proxy patterns) should be noted for that separate package, not added to this roadmap.
