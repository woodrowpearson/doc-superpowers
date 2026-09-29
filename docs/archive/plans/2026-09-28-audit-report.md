## Documentation Freshness Audit — 2026-09-28

**Branch:** claude/2026-09-27-repo-handoff-4b960b · **HEAD:** 132a987

### Summary
- Scanned: 9 docs across 4 scopes (application, ci-cd, agentic, spec — design specs only, which are records). The 9 are the 5 living docs (`docs/architecture/system-overview.md`, `docs/workflows/doc-superpowers.md`, `docs/codebase-guide.md`, `docs/conventions.md`, `docs/guides/getting-started.md`) plus `CLAUDE.md`, `README.md`, `AGENTS.md` and `GEMINI.md`.
- Fresh: 55 | Stale: 0 | Missing coverage: 0 | Untracked: 0 (also Deprecated: 2). These are the `check-freshness` counts (current 55, stale 0, missing 0, deprecated 2, untracked 0).
- Every living doc was re-attested during sweep 05ea982, so every finding below is a content inaccuracy, not a freshness-index staleness. "Stale: 0" above counts the index verdict only.
- Findings after merging: P0 0 | P1 10 | P2 17 | P3 41 (68 total). Three duplicate reports across the four scope reports were merged (see the P1 entry 1 and the P3 entry `.worktrees/`).
- Per-doc verdicts from the scope agents: `docs/architecture/system-overview.md` STALE (minor; broadly accurate) · `docs/workflows/doc-superpowers.md` STALE · `docs/codebase-guide.md` STALE · `docs/conventions.md` STALE · `docs/guides/getting-started.md` STALE · `README.md` STALE · `CLAUDE.md` MISSING_COVERAGE · `AGENTS.md` FRESH (no findings) · `GEMINI.md` FRESH (no findings).
- Structure: there are no flat-structure docs and no global `docs/diagrams/`.
- Scope-agent limits: all four passes were read-only. No repository script was run (only `bash scripts/doc-tools.sh --help`, from a scratch directory). Mermaid sources were read for accuracy only (`mmdc` could not render them: no Chrome). The suite counts in `CLAUDE.md` were checked against the dispatch, not re-measured.
- Findings marked "(unverified: ...)" rest on evidence the scope agent could not check first-hand; `update` must verify them before editing.

### P0 Critical
None.

### P1 Stale

Grouped by doc, in this order: system-overview, workflows, codebase-guide, conventions, getting-started, README.

1. `docs/architecture/system-overview.md:109` (also `docs/workflows/doc-superpowers.md:385` and `docs/conventions.md:266`) — the statements about which CI `run:` steps are vendored or inline are false
   - Flagged by: the architecture scope (system-overview P1, plus a note on conventions.md), the workflows scope (workflows doc, rated P3) and the application scope (conventions.md P1). Merged into one entry at the highest rating (P1). One root cause, three docs to edit.
   - Doc says (system-overview.md:109): "Every `run:` step is a vendored script in `.github/scripts/doc-superpowers-steps/`; …"
   - Doc says (doc-superpowers.md:385): "Every `run:` step is a script in `.github/scripts/doc-superpowers-steps/`, so that directory ships with any workflow." (`references/hooks.md:126-127` says the same; it is not an audited doc.)
   - Doc says (conventions.md:266): "the only inline steps are `doc-pr-release.yml`'s pre-checkout PR resolver and a one-line echo"
   - Code shows:
     - `doc-pr-release.yml:74` has an inline multi-line `run: |` step ("Resolve PR number and head ref"). Its comment at lines 67-73 says it "Stays inline: this step runs BEFORE actions/checkout".
     - `doc-pr-release.yml:329` runs `.github/scripts/doc-pr-release/commit-and-push.sh "$PR_NUMBER"`, from `doc-pr-release/`, not `doc-superpowers-steps/`.
     - No other template has a `run:` outside `doc-superpowers-steps/`: `grep -n '^ *run:' scripts/hooks/ci/*.yml`.
     - The five commit steps run the `$RUNNER_TEMP/doc-superpowers-steps/commit-changes.sh` snapshot of the step script (doc-audit-update.yml:116, doc-release.yml:133, doc-pr-full-cycle.yml:127, doc-pr-release.yml:305).
     - There is no echo-only step. Across the eight templates exactly one `run:` body is inline, the resolver at `doc-pr-release.yml:74`; every other `run:` is a single helper call (`rg -n "run:" scripts/hooks/ci/*.yml`: 31 hits, all `.github/scripts/...` or `"$RUNNER_TEMP"/doc-superpowers-steps/...`). `scripts/test-doc-pr-release.sh:1118-1122` sanctions only that one ("One sanctioned inline step: the pre-checkout resolver"), and any other inline body is reported as a failure.
     - `docs/conventions.md:266` already states the `doc-pr-release/` exception, so only its "one-line echo" is wrong.
   - Suggested fix:
     - system-overview.md:109: "Every `run:` step is a script in `.github/scripts/doc-superpowers-steps/` (or, for the producer's commit, `doc-pr-release/`), except `doc-pr-release.yml`'s pre-checkout PR resolver, which stays inline."
     - doc-superpowers.md:385: "Every `run:` step is a script … except doc-pr-release's first step (inline: it runs before checkout) and its commit step (`doc-pr-release/commit-and-push.sh`); the commit steps run a pre-agent snapshot of `commit-changes.sh`."
     - conventions.md:266: "the only inline step is `doc-pr-release.yml`'s pre-checkout PR resolver".

2. `docs/workflows/doc-superpowers.md:631` and `:641` — spec-verify emits FOUR P3 informational lines, the doc says three (twice)
   - Doc says: "The check also emits three non-blocking **P3 informational** lines — inferred constraints, unrecognized statuses, and targets held at `In Review` by design" (line 631) and "the three P3 informational lines (inferred constraints, unrecognized statuses, targets held at `In Review` by design)" (line 641)
   - Code shows: "Then emit four **P3 informational** lines" — inferred constraints, unrecognized statuses, **Amendments verified**, held short of `Implemented` (`references/spec-lifecycle-actions.md:295-299`); `references/output-templates.md:115-120` lists the same four; `scripts/test-spec-status-model.sh:622-623` pins "four **P3 informational** lines" and asserts "…not three"
   - Suggested fix: say four in both places and add "amendments verified as landed" to each list.

3. `docs/workflows/doc-superpowers.md:768`, `:784-788` — the doc inventories five spec-lifecycle sub-agents that nothing dispatches
   - Doc says: Steps table row "3b | Spec lifecycle (generate/inject/verify) | Spec lifecycle agents" (line 768) and Sub-Agents rows "Spec generate (per domain)", "Spec inject (plan)", "Spec inject (execute)", "Spec verify (post-execute)", "Spec verify (review)", each "Fresh Context: Yes" (lines 784-788)
   - Code shows: `references/spec-lifecycle-actions.md`, `spec-lifecycle-protocol.md` and `integration-patterns.md` contain no dispatch, sub-agent or `Agent` instruction (rg for dispatch/sub-agent/Agent tool/fresh context: no hits). The `Agent` tool is dispatched only by `init` (SKILL.md:333, 341), `audit` (369), `review-pr` (418), `update` (444) and `release` (references/release.md:23). The spec actions run in the invoking agent.
   - Suggested fix: delete rows 784-788 and change row 3b to "the invoking agent runs the spec actions inline (no sub-agent dispatch)". (Rubric-wise this could be P0, "describes behaviour the code does not implement"; the scope agent kept it P1 because the process sections for the spec actions are correct.)

4. `docs/workflows/doc-superpowers.md:566-607` — `spec-inject --phase=execute`: the doc has the phase always writing spec status and the index, and a ladder it does not walk
   - Doc says: "**Aligned** … — update spec `Status` as the model permits, update Implementation Notes, refine `code_refs` (`set-code-refs`), call `update-index`" (line 575); sequence diagram `alt Aligned: SI->>FS: Update spec status + Implementation Notes; SI->>DT: update-index` (lines 604-607); "**Status transitions**: … `Draft` → `In Review` (first implementation) → `Approved` → `Implemented` (verification passes)" (line 578)
   - Code shows: "**One per-chunk writer.** … When `--plan` names a plan carrying injected spec tasks …, those tasks are the writer: this phase then writes nothing and only reports" (`references/spec-lifecycle-actions.md:260`); Aligned applies "and this phase is the writer … When the plan's `Task N+1` is the writer, report 'aligned' and write nothing" (:264); "This phase itself only ever writes `Draft` → `In Review`. … `Approved` is human-set — no action ever writes it" (:267). The doc's own Input bullet (line 566) states the one-writer rule, so lines 575, 578 and 604-607 contradict it.
   - Suggested fix: qualify step 2's Aligned branch and the diagram ("when no injected plan tasks own the chunk; otherwise report only"), and step 3: this phase writes only `Draft` → `In Review`; `Implemented` belongs to the finalize task; `Approved` is human-set. Add the "amendment pending (Task N)" report to the Amendment bullet.

5. `docs/codebase-guide.md:213-215` — init code-flow "Discovery Phase" block describes the old discovery, not the current one
   - Doc says: "→ Bash: detect doc tooling (scripts/*doc*)" / "→ Bash: detect scopes (docs/*/)" / "→ Bash: detect agentic workflows (.claude/skills/*)" (docs/codebase-guide.md:213-215)
   - Code shows: Section 0 has four parts, none of them those.
     - (a) *Detect Bundled Tooling* resolves the plugin's own tool: `ROOT="${CLAUDE_SKILL_DIR}/../.."` (SKILL.md:98, 105, 115). The project's `scripts/*validate_docs*`-style scripts are only listed, "list them, never run them" (SKILL.md:137; Safety Rules :90), and there is no `scripts/*doc*` pattern anywhere in SKILL.md.
     - (b) *Detect Scopes* (SKILL.md:197) uses structural signals: package manifests, API schemas, IaC, CI configs, tests, agentic files, existing ADR/spec dirs. It does not look at `docs/*/`.
     - (c) *Run Baseline Checks* (SKILL.md:216) runs `check-freshness` through a jq filter, and the flow omits it.
     - (d) *Detect Agentic Workflows* (SKILL.md:227) scans `.claude/skills` and `skills`, plus commands and MCP configs.
     - `docs/workflows/doc-superpowers.md:52-60` already lists the current five steps, so the two living docs conflict.
   - Suggested fix: replace the three `Bash:` lines with the real steps: detect bundled tooling (`$ROOT` / `$DOC_TOOLS`; project scripts listed, never run) → detect scopes (structural signals) → run baseline checks (`check-freshness` through the jq filter) → detect agentic workflows (skills, commands, MCP configs) → build inventory. The same block should also add init steps 2 and 7 (flat-to-structured migration check with a user yes; ADR seeding), which the "Typical init flow" skips.

6. `docs/codebase-guide.md:168` — "Where to Find Things" points at a doc-spec.md section that no longer exists
   - Doc says: `| Agentic workflow template | \`references/doc-spec.md\` "Agentic Workflow Section Template" |` (docs/codebase-guide.md:168)
   - Code shows: `references/doc-spec.md` has no heading of that name. The agentic templates are `## docs/workflows/agentic/README.md` (doc-spec.md:548) and `## docs/workflows/agentic/{skill-name}.md` (doc-spec.md:577), with the Mermaid patterns under `### Agentic workflows` (doc-spec.md:421). The heading was renamed by commit 7ea49d2 (sweep I-11).
   - Suggested fix: point at the `docs/workflows/agentic/README.md` and `docs/workflows/agentic/{skill-name}.md` templates in `references/doc-spec.md`.

7. `docs/guides/getting-started.md:225-228` (and `:86`) — verification step tells the reader every generated file starts with the marker; templates are exempt
   - Doc says: "2. Each file should start with the doc-superpowers marker ... `<!-- Generated by doc-superpowers -->`" (getting-started.md:225-228), after listing `specs/README.md + template.md` and `adr/README.md + template.md` (:210-211)
   - Code shows: "Add the marker as the first line of each generated doc, except `template.md` files (a spec or ADR copied from a template would inherit a false "Generated by" line)" (SKILL.md:350); "Add this HTML comment as the first line of every generated doc file — except `template.md` files" (`references/doc-spec.md:35`). A verifier following the guide would flag a correct `template.md`.
   - Suggested fix: "Each generated file except `template.md` should start with ..." (and the same exception at :86, "Mark each generated file").

8. `README.md:381` — "Zero dependencies" claim contradicts the skill's own hard stop
   - Doc says: "The skill itself (`skills/doc-superpowers/SKILL.md` + `references/`) has zero dependencies. The bundled tooling in `scripts/` requires:" (README.md:381)
   - Code shows: SKILL.md's *Detect Bundled Tooling* block ends `[ -x "$DOC_TOOLS" ] || { echo "doc-superpowers: $ROOT has no executable scripts/doc-tools.sh — stop" >&2; exit 1; }` and "If it prints the error instead of the two paths, **stop**" (SKILL.md:114, :119); the same README says "Copy all of it, not only `skills/doc-superpowers/SKILL.md` and `references/`: the skill runs `scripts/doc-tools.sh`" (README.md:44). SKILL.md:96 makes tool resolution run for every action, including `hooks` and `release`. So `bash`, `git`, `jq >= 1.6` and `sha256sum`/`shasum` are the skill's dependencies, and SKILL.md + references/ alone cannot run.
   - Suggested fix: "The skill runs the bundled tooling in `scripts/` (and reads `references/`) from its plugin root, so it needs the whole repository and:" and keep the table.

9. `README.md:107` — usage line says scopes are auto-detected from `docs/`; they are detected from the project
   - Doc says: "Scopes:  all | <auto-detected from docs/ structure>" (README.md:107)
   - Code shows: "Scopes:  all | one scope from Detect Scopes (application, api-contracts, data-layer, …)" (SKILL.md:60). *Detect Scopes* derives scopes from project signals (package manifests, API schemas, migrations, IaC, CI config, tests, skills, existing ADRs/specs), not from the `docs/` layout (SKILL.md:197-214). SKILL.md:63 also says `[scope]` is read by `audit`, `update` and `diagram` only; the README does not say so.
   - Suggested fix: "Scopes:  all | one scope from Detect Scopes (application, api-contracts, data-layer, …)" plus one sentence: `[scope]` applies to `audit`, `update`, `diagram` only.

10. `README.md:78-84` — skills.sh install path installs only the skill folder, without the tooling the skill needs (unverified: vendor-doc reading only; the scope agent read the `vercel-labs/skills` README on 2026-09-28 and did not run `npx skills add`)
    - Doc says: "npx skills add woodrowpearson/doc-superpowers ... Works with 40+ supported agents." (README.md:78-84)
    - Code/evidence shows: the repo's skill is `skills/doc-superpowers/SKILL.md` and resolves its tooling as `ROOT="${CLAUDE_SKILL_DIR}/../.."` (SKILL.md:105). The `skills` CLI's README (github.com/vercel-labs/skills, fetched 2026-09-28) says `npx skills add` "installs individual skill directories (containing `SKILL.md`), not entire repositories" and that sibling `scripts/` / `references/` at the repo root "are **not** automatically copied"; it lists 75+ agents. A skills.sh install would therefore have no `scripts/doc-tools.sh`, so the skill stops (SKILL.md:114), and README.md:44 itself says the whole repository is needed. No test, INSTALL file or `tool-mappings.md` source covers this path (`grep -ri 'skills\.sh\|npx skills'` finds only README.md:78-84 outside RELEASE-NOTES). This is a vendor-doc reading, not a real install; `npx` was not run.
    - Suggested fix: verify once with a real `npx skills add` in a scratch directory; if it copies only `skills/doc-superpowers/`, remove the section (or say it cannot supply `scripts/` and `references/`, so use the marketplace or a checkout); if kept, drop or correct "40+" (the CLI lists 75+).

### P2 Incomplete

1. `docs/architecture/system-overview.md:65-117` — `references/release.md` and `references/hooks.md` are missing from the component inventory
   - Doc says: the Tech Stack table has a row for every other reference: doc-spec, agent-prompt-template, output-templates, integration-patterns, tool-mappings, the two spec-lifecycle refs. The Container diagram has only `templates`, `speclifecycle`, `specprotocol` (system-overview.md:65, 69, 70, 110-117). `release.md` appears nowhere in the file. `hooks.md` appears once, in passing, in the CI row (line 109).
   - Code shows: SKILL.md's references table marks both **REQUIRED**: `references/release.md` "REQUIRED for `release` — steps 1–12" and `references/hooks.md` "REQUIRED for `hooks` — installer routing, consent table, CI templates" (SKILL.md:43-44). They are 37 and 146 lines, and they hold the release procedure and the hooks/CI consent table that the doc's Key Decisions summarize.
   - Suggested fix: add Tech Stack rows for both. Mention in the Container `router` node (or a new node) that `release` and `hooks` load their REQUIRED reference.

2. `docs/architecture/system-overview.md:83,87` — the C4 container diagram omits the data flows the doc's own prose describes between hooks, doc-tools.sh and CI
   - Doc says: Container Rels are only `Rel(hooks, project, …)` and `Rel(router, doctools, "Builds/checks freshness index")` (system-overview.md:83, 87). There is no node for the merge driver, the CI templates or the step helpers, and no Rel from `hooks` or CI to `doctools`.
   - Code shows:
     - The installer calls doc-tools: `install.sh` `run_tools` runs `doc-tools.sh tools install|uninstall --helper …`, and `ci_version` runs `doc-tools.sh tools version` (install.sh:82, 1231).
     - Git hooks and Claude hooks call `"$DOC_TOOLS" check-freshness --tree "$tree" --code-refs-from -`, resolved at run time by the `__DOC_TOOLS_RESOLVE__` rule (git/pre-commit:24,50; claude/pre-commit-gate.sh:62,134).
     - CI shell templates run the vendored `.github/scripts/doc-tools.sh` via `freshness-check.sh` (freshness-check.sh: `DOC_TOOLS="${DOC_TOOLS:-.github/scripts/doc-tools.sh}"`).
     - The merge driver, `scripts/merge-doc-index.sh`, is registered by the installer and is a separate jq program that does not call doc-tools.
   - Suggested fix: add `Rel(hooks, doctools, "Vendors doc-tools.sh; git/Claude hooks and CI run check-freshness")`, and optionally a `Container` for the merge driver and CI templates.

3. `docs/architecture/system-overview.md:107,139,161` — the index schema version and field list are never stated, nor the v2/v3 compatibility rule
   - Doc says: mentions `code_oids`, `code_commit`, `last_verified`, `content_hash`, `implementation` only in passing (system-overview.md:107, 139, 161). "schema" occurs only in unrelated senses. `schema_version` 3 is not mentioned.
   - Code shows:
     - Writers stamp `schema_version` 3; "a v2 index is read as it is" (doc-tools.sh `--help`, "Index writes"). Live index: `jq .schema_version docs/.doc-index.json` gives 3.
     - Entries with no `code_oids` (pre-v3) keep the old commit comparison at HEAD until `update-index` re-verifies them (`--help`, `check-freshness`).
     - The full field table (`content_hash`, `code_refs`, `code_oids`, `code_commit`, `doc_type`, `status`, `replaces`, `superseded_by`, `last_verified`, `implementation`) is in `references/doc-spec.md:988-1030`.
     - The installer state file has its own `schema_version: 2` (state.sh:10-12).
   - Suggested fix: add one sentence to the Staleness Detection row or the "Content hash + code object ids" decision: "index schema v3 (per-ref `code_oids`; a v2 index is read as it is), field reference in `references/doc-spec.md` → Doc-Index Schema Reference".

4. `docs/architecture/system-overview.md:109,151` — the hook scripts and CI step helpers are not enumerated, although the brief's inventory expects every script
   - Doc says: names only `pre-commit` (line 151), `commit-changes.sh`, `freshness-check.sh` and `fragment-lib.sh` (line 109). The git and Claude tiers are described generically ("git hooks", "the three scripts").
   - Code shows:
     - Five git hooks: `pre-commit`, `post-merge`, `post-checkout`, `prepare-commit-msg`, `pre-push` (install.sh:44 `GIT_HOOKS`).
     - Three Claude scripts: `pre-commit-gate`, `post-commit-sync`, `session-summary` (install.sh:45 `CLAUDE_HOOKS`, bound to PreToolUse, PostToolUse and Stop, install.sh:866-868).
     - Nine step scripts in `scripts/hooks/ci/doc-superpowers-steps/`: commit-changes, freshness-check, pr-guard, precheck, prepare-agent, resolve-auth, sentinel-check, verify-fragment, write-context.
     - SKILL.md's `sync` prints "Hooks: N/5 git, N/3 claude, N/8 ci" (SKILL.md:512).
   - Suggested fix: add a one-line inventory to the Hooks Engine / CI rows, for example "5 git hooks (pre-commit, post-merge, post-checkout, prepare-commit-msg, pre-push), 3 Claude scripts, 9 step scripts".

5. `docs/workflows/doc-superpowers.md:206,274,710-714` — the `[scope]` argument is not documented anywhere in the flows
   - Doc says: no mention; audit step 8 "For each affected scope, dispatch a scope agent", update step 3 "For each stale doc, dispatch a scope agent", commands table `/doc-superpowers audit`, `update`, `diagram` with no argument (lines 206, 274, 710-714)
   - Code shows: "`[scope]` is read by `audit`, `update` and `diagram` only: it limits their scope agents to that one scope (default `all`)" (SKILL.md:63); "(only `[scope]`, when one is given)" (SKILL.md:369, 444); Usage `Scopes: all | one scope from Detect Scopes` (SKILL.md:60)
   - Suggested fix: add `[scope]` to the three commands in the table and to audit step 8 / update step 3 / diagram.

6. `docs/workflows/doc-superpowers.md:504-509` — `spec-generate` drops the confirmation-gated supersession/archival and three other steps' content
   - Doc says: step 5 "Handle supersession, extension, or flag duplicates for human review" (line 504); step 6 "create `SPEC-{CAT}-NNN-{slug}.md` per domain" (506); step 8 "pipe each new spec's mapping line to `add-entry` … update `docs/specs/README.md`" (508); step 9 "append `## Generated Specs` section" (509)
   - Code shows: supersession happens "with the user's yes (SKILL.md *Safety Rules* …; in CI, report it instead)", then `git mv` to `docs/archive/specs/` + `move-entry` (`references/spec-lifecycle-actions.md:106`); step 6 numbers past the highest in `docs/specs/` and `docs/archive/specs/` — never reused (:132); step 8 also runs `deprecate-entry <archived> --superseded-by <new>` for each superseded spec (:138); step 9 also appends `## Specs Requiring Updates` when 5b found stale content (:147-157)
   - Suggested fix: add the user-confirmation gate and the archive/`move-entry`/`deprecate-entry` sequence to steps 5 and 8, the no-reuse numbering rule to step 6, and the second table to step 9.

7. `docs/workflows/doc-superpowers.md:790-799` — the User Interaction Gates table is incomplete
   - Doc says: six gates: audit report review, diff review, release draft review, release tag confirmation, spec drift review, compliance report review (lines 790-799)
   - Code shows: further user gates: confirm before migrating / archiving / deleting / superseding a doc (SKILL.md:89 Safety Rules; init step 2, update step 2, spec-generate step 5); the `hooks --ci` consent table, what an AI job's agent can reach, and the branch-protection recommendation, then a yes (SKILL.md:523, `references/hooks.md:34-59`); the version-bump confirmation (`references/release.md:22` "User confirms or overrides"); init's offer to commit before the gate (SKILL.md:354). Discovery is defined to capture "User gates" (SKILL.md:249; doc line 60).
   - Suggested fix: add those four rows.

8. `docs/workflows/doc-superpowers.md:396,406,408,411` — CI workflow tables omit `workflow_dispatch` triggers/inputs, `paths-ignore`, permissions and the commit surface
   - Doc says: Trigger column for `doc-freshness-schedule.yml` "Cron (weekly, configurable)", `doc-audit-update.yml` "Push to non-main branches that leaves indexed docs stale or missing", `doc-release.yml` "Push to `release/*` branches", `doc-pr-release.yml` "PR open/sync/reopen" (lines 396, 406, 408, 411); the tables have no permissions column
   - Code shows: doc-freshness-schedule.yml:14 and doc-audit-update.yml:20 also run on `workflow_dispatch`; doc-release.yml:28-39 `workflow_dispatch` with inputs `from_ref` and `version_bump` (auto/major/minor/patch); doc-pr-release.yml:23-27 `workflow_dispatch` with required `pr_number`, plus `paths-ignore` for `RELEASE-NOTES.next/**` and `RELEASE-NOTES.md` (:19-22). Permissions per job: doc-freshness-pr `contents: read, pull-requests: write`; schedule `contents: read, issues: write`; audit-update `contents: write`; review-pr `review-docs` read+PR write, `respond` also `issues: write`; release, full-cycle, pr-release `contents: write, pull-requests: write`; spec-verify `contents: read, pull-requests: write`. `references/hooks.md:36-45` has this table; the workflows doc has no equivalent and never points at it.
   - Suggested fix: add "manual dispatch" (and the inputs) to the four triggers, the pr-release path filter, and a Permissions / Commits column (or a pointer to the hooks.md consent table).

9. `docs/workflows/doc-superpowers.md` (index entry in `docs/.doc-index.json`) — the doc's `code_refs` do not cover `references/`, which it restates in detail
   - Doc says: index entry `code_refs: ["skills/doc-superpowers/SKILL.md", "scripts/"]` (docs/.doc-index.json, `docs/workflows/doc-superpowers.md`), while the doc mirrors `references/hooks.md` (consent, state, CI templates), `references/release.md`, `references/spec-lifecycle-actions.md` and `references/output-templates.md`
   - Code shows: an edit to any of those references never marks this doc stale; P1 entry 2 (three vs four) is exactly that drift going unseen
   - Suggested fix: `set-code-refs docs/workflows/doc-superpowers.md --refs skills/doc-superpowers/SKILL.md,references/,scripts/hooks/,scripts/doc-tools.sh,scripts/merge-doc-index.sh` (or keep `scripts/`), then `update-index` after the fixes.

10. `docs/conventions.md:326-335` — Read/Write Separation omits two index writers, `set-doc-type` and `remove-entry` (known item confirmed)
    - Doc says: the list (docs/conventions.md:326-335) names `build-index`, `add-entry`, `update-index`, `set-code-refs`, `move-entry`, `deprecate-entry`, then `check-freshness` and `status` as read-only. `set-doc-type` appears only in the status-transition table (:369) and the `doc_type` schema bullet (:384); `remove-entry` appears only as a foil inside the `move-entry` bullet (:332).
    - Code shows: `--help` "Index writes:" (doc-tools.sh:2212-2214): "build-index, update-index, add-entry, remove-entry, move-entry, set-code-refs, set-doc-type and deprecate-entry take the lock ... and replace the index atomically". `cmd_remove_entry` is at :3187 and `cmd_set_doc_type` at :3656 (retypes in place, keeps every other field, "Not a verification").
    - Suggested fix: add two bullets. `set-doc-type` changes one entry's `doc_type` in place (keeps position and every other field; same type writes nothing; not a verification; decides record vs living). `remove-entry` deletes entries; an absent key is a SKIP with exit 0. Optionally note that `implementation-status`, `fragments list|validate` and `check-freshness` / `status` are the read-only verbs.

11. `docs/conventions.md:249-256` — the CI-Specific Flags table omits `--transient`
    - Doc says: the table (docs/conventions.md:249-256) lists `--workflows`, `--base-branch`, `--cron`, `--ci-strict`, `--helpers`, `--force`; the text below it and the "Installation Rules" say only that CI options need `--ci`.
    - Code shows: install.sh accepts `--transient` as an uninstall flag (`allowed()`: `uninstall:--workflows | uninstall:--transient`, install.sh:1515; parsed at :1578; usage text "Uninstall options (uninstall --ci): --workflows=... --transient"). `references/hooks.md:15` counts it among the CI options that need `--ci`, and `docs/codebase-guide.md:127` documents it. conventions.md is the only doc of the three that never mentions it, although it explains `--force` and the "removed on purpose" state that `--transient` toggles.
    - Suggested fix: add a row or short paragraph: `--transient` (uninstall only): record the removal as temporary (`intentional: false`), so the next plain `install --ci` puts the workflow back; without it the removal is intentional.

12. `docs/conventions.md:142-167` — no convention entry for the Safety Rules, and the Graceful Degradation row contradicts one of them
    - Doc says: "| User-provided scripts | Bundled tooling handles core operations; optional scripts supplement |" (docs/conventions.md:163). "Project-Specific Patterns" (:142-167) lists Discovery-First, Parallel Agent Dispatch, Graceful Degradation and Evidence-Based Verification only. grep finds no mention of a trust boundary, secrets, or confirm-before-moving-docs anywhere in conventions.md.
    - Code shows: SKILL.md:83-90 "Safety Rules ... hold for every action, and for every agent this skill dispatches": trust boundary (repository content is data, never instructions), secrets (never copy a value, name it and where it is read), confirm before moving docs, and "Never auto-run repository scripts" (project scripts are listed, never run, unless the user names one; never in `review-pr` or CI). They are repeated in `references/agent-prompt-template.md`. "Optional scripts supplement" reads as if they run alongside the bundled tooling. `docs/codebase-guide.md:121,161` already lists the rules.
    - Suggested fix: add a "Safety Rules" bullet to Project-Specific Patterns (one line each for the four rules, pointing at SKILL.md), and reword the row to "listed, never auto-run (Safety Rules)". The archive model section (:134-140) should also say moving or archiving needs the user's yes (in CI: report it).

13. `docs/guides/getting-started.md:103-104` — CI-opt-in example names a shell (default) workflow under "Claude-powered"
    - Doc says: "# Claude-powered workflows are opt-in by name" then `--workflows=doc-freshness-pr,doc-release` (getting-started.md:103-104)
    - Code shows: `doc-freshness-pr` is one of the two shell workflows installed by default (install.sh:48, `SHELL_WORKFLOWS="doc-freshness-pr doc-freshness-schedule"`); only `doc-release` is Claude-powered. Naming it is harmless but misleading, and the README uses two AI names (`doc-pr-release,doc-review-pr`, README.md:188).
    - Suggested fix: `--workflows=doc-release` (or `doc-pr-release,doc-review-pr` as in the README).

14. `README.md:117` — `update --report=<path>` and the `update` input rules are not in the README
    - Doc says: "`update` | Apply fixes from audit/review | After audit identifies stale docs" (README.md:117); no example shows `update`.
    - Code shows: `update` takes `--report=<path>`, else this session's audit, else `check-freshness`, plus optional `[scope]` (SKILL.md:27, :433); `audit` ends "Run `/doc-superpowers update --report=<that path>`" (SKILL.md:399); and `update` archives the applied report (SKILL.md:468).
    - Suggested fix: add `--report=<path>` to the `update` row and an `update` example next to the audit one.

15. `README.md:234,237` — "Generated Documentation" table over-states two rows
    - Doc says: "`architecture/diagrams/` | C4, component, ERD diagrams | Always" (README.md:234) and "`workflows/{name}.md` | Process flows, CI/CD | Always" (README.md:237)
    - Code shows: the ERD is written only with the `data-layer` scope ("`architecture/diagrams/erd.png`", SKILL.md:298; "Generate this file — and its ERD — when the `data-layer` scope is detected", doc-spec.md:666). Only the primary workflow is always written (SKILL.md:295); `ci-cd` adds `workflows/deployment.md` (SKILL.md:300). The table also lacks `workflows/agentic/README.md` (SKILL.md:302) and the conditional `## Testing` (`testing`) and `## Packages` (`monorepo`) sections (SKILL.md:301, :303).
    - Suggested fix: split the ERD out ("`data-layer` scope"); reword the workflow row ("primary workflow always; `deployment.md` with `ci-cd`"); add the agentic index row.

16. `CLAUDE.md:148-157` — Commands section drops arguments the skill accepts
    - Doc says: "`/doc-superpowers audit` — Full documentation health check", "`/doc-superpowers update` — Execute doc updates from audit", "`/doc-superpowers diagram` — Regenerate diagrams", "`/doc-superpowers release` — Draft release notes entry from git history", "`/doc-superpowers hooks install [--git] [--claude] [--ci] [--all]`" (CLAUDE.md:148-157)
    - Code shows: `audit`/`update`/`diagram` take `[scope]` (SKILL.md:56-63); `update` takes `--report=<path>` (SKILL.md:27, :433); `release` takes `--from=<ref>` (SKILL.md:34, release.md:14); `hooks install` also takes `--workflows=`, `--force`, `--base-branch`, `--cron`, `--ci-strict` (install.sh:113, :145-158) and `hooks uninstall` takes `--workflows`, `--transient` (install.sh:114). CLAUDE.md does list the `--plan` and `:amends` details for the spec commands, so the omission is uneven.
    - Suggested fix: add `[scope]`, `update [--report=<path>]`, `release [--from=<ref>]`, and one line for the CI options of `hooks install` / `uninstall` (or "see references/hooks.md").

17. `RELEASE-NOTES.md` — 53 commits unreleased since v2.15.0 (2026-09-01)
    - Doc says: the newest entry is v2.15.0 (2026-09-01), and that release is tagged.
    - Code shows: 53 commits since v2.15.0. Docs already say "retired in v3.0.0" / "pre-3.0", and README and the hooks docs name v3.0.0, while the manifests and RELEASE-NOTES.md's newest heading are still v2.15.0. Those statements become true when the v3.0.0 release lands (tracked in `docs/issues/2026-09-28-sweep-05ea982-followups.md`, "Fix-later: docs").
    - Suggested fix: run `/doc-superpowers release` (the planned v3.0.0 release flow covers this). `update` does not edit this file.

### P3 Style

1. `docs/architecture/system-overview.md:30,109` — "both fail closed" needs qualifying for the PR check
   - Doc says: "2 shell workflows (PR freshness, weekly audit; both fail closed)" (system-overview.md:30). Line 109 repeats "freshness-check.sh, which fails closed".
   - Code shows: in `gate` mode (doc-freshness-pr) without `DOC_SUPERPOWERS_STRICT=1`, an unrunnable check exits 0 with `::warning::… (DOC_SUPERPOWERS_STRICT is off, so the PR is not blocked)` (freshness-check.sh:66-70). "Fail closed" here means "never reported as 0 stale" (docs/conventions.md:267 defines it so), not "blocks". Only the schedule run and the AI scope gate always exit 1.
   - Suggested fix: "never report an unrunnable check as all-current (the PR check warns, or fails under `--ci-strict`; the schedule run and AI scope gate fail)".

2. `docs/architecture/system-overview.md:109` — in `doc-pr-release.yml`, `commit-changes.sh` does not commit
   - Doc says: the AI workflows "never let the agent commit (a checked `commit-changes.sh` step does — an integrity check, not a sandbox …)" (system-overview.md:109).
   - Code shows: `doc-pr-release.yml:305` runs `commit-changes.sh --check-only …` (see the flag's help: "check only; the caller commits"). The commit and push is `doc-pr-release/commit-and-push.sh` (line 329). The other four committing AI workflows (audit-update, full-cycle, release) use `commit-changes.sh --message … --push-to`.
   - Suggested fix: add "(for `doc-pr-release`, `commit-changes.sh --check-only` verifies and `commit-and-push.sh` commits)".

3. `docs/architecture/system-overview.md:109` — "gate on the doc index instead of path filters" does not hold for two of the six AI workflows
   - Doc says: "AI workflows … gate on the doc index instead of path filters" (system-overview.md:109).
   - Code shows:
     - Only audit-update, full-cycle, review-pr and spec-verify run `freshness-check.sh scope`.
     - `doc-pr-release.yml:20` has `paths-ignore: ['RELEASE-NOTES.next/**','RELEASE-NOTES.md']`, and no scope step (it gates on `write-context.sh` `run=true`).
     - `doc-release.yml` triggers on any push to `release/**` and gates on `precheck.sh`.
   - Suggested fix: "four of the six gate on the doc index (`freshness-check.sh scope`) instead of path filters; the producer and the release drafter have their own gates".

4. `docs/architecture/system-overview.md:108` — `--helpers=<bool>` is not fully inert
   - Doc says: "`--helpers=<bool>` is deprecated and inert: the helpers ship exactly while a workflow runs them" (system-overview.md:108).
   - Code shows: `--helpers=false` exits 1, writing nothing, when `doc-pr-release` is selected or already installed (install.sh:1200-1210; install.sh help lines 154-156; references/hooks.md `--helpers` bullet). Cross-scope note: the workflows, application and project scope reports each found the same "inert" wording in `docs/workflows/doc-superpowers.md`, `docs/conventions.md` and `README.md` accurate as written, so `update` should check whether those docs need the same qualification before editing them.
   - Suggested fix: append "except that `--helpers=false` is refused while `doc-pr-release` is selected or installed".

5. `docs/architecture/system-overview.md:108,163` — `state.sh` does not derive the workflow list; `install.sh` does
   - Doc says: "`state.sh` records the CI tier's workflow set … derives the workflow list from `scripts/hooks/ci/*.yml`; single-writer" (system-overview.md:108). The same derivation is claimed for the state-respect decision (line 163).
   - Code shows: `KNOWN_WORKFLOWS` is built from `"$SCRIPT_DIR"/ci/*.yml` in `install.sh:61-68`. `state.sh` has no reference to `KNOWN_WORKFLOWS` or `ci/*.yml` (grep). It also carries no lock or single-writer mechanism: the "single-writer" line is an unenforced assumption.
   - Suggested fix: attribute the derivation to `install.sh`.

6. `docs/architecture/system-overview.md:161` — the merge-driver conflict cases are not quite three, and not all name a key and field
   - Doc says: "The driver does not guess in three cases, and each leaves `git merge-file` conflict markers, exits 1 and names the doc key and field." (system-overview.md:161)
   - Code shows:
     - Per-entry conflicts: "deleted on one side, changed on the other" (merge-doc-index.sh:227, names the key, no field) and "both sides changed …, and last_verified does not say which is newer" (:231, key and fields).
     - Also "not an object on every side" (:233) — a fourth per-entry case.
     - Whole-file conflicts: an input that is not a single index object, a corrupt base, jq missing, or a scratch-file failure (merge-doc-index.sh:144-169, 248-253). These name neither key nor field.
   - Suggested fix: "names the doc key (and the fields, for a tie)", and note that the structural failures are reported without a key.

7. `docs/architecture/system-overview.md:7,32` — Codex is not loaded through a plugin manifest
   - Doc says: Overview: "via framework-specific plugin manifests and cross-framework tool name mappings" (system-overview.md:7). Context: "Cursor, Codex, OpenCode, Gemini CLI — supported via plugin manifests and tool-mappings" (:32).
   - Code shows:
     - Manifests exist for Cursor (`.cursor-plugin/plugin.json`), OpenCode (`package.json` plus `.opencode/plugins/doc-superpowers.js`) and Gemini (`gemini-extension.json`, `GEMINI.md`).
     - Codex has only `.codex/INSTALL.md`: clone plus symlink into `~/.agents/skills` (.codex/INSTALL.md:3-13). There is no manifest.
   - Suggested fix: "plugin manifests (Cursor, OpenCode, Gemini CLI) or a symlinked checkout (Codex)".

8. `docs/architecture/system-overview.md:107,109,119,135,141,67,129` — small inventory imprecisions (six sub-items)
   - Doc says / Code shows / Suggested fix, per sub-item:
     - (a) Doc says the Staleness row has "per-PR release-notes fragment validation/merge" (:107). Code: the verb is `fragments list|validate|merge`; `list` is omitted. Fix: name `list`.
     - (b) Doc says the CI row's producer helpers share `fragment-lib.sh` (:109). Code: only `extract-context.sh` (line 72) and `commit-and-push.sh` (line 89) source it; `update-pr-body.sh` does not. Fix: say which two.
     - (c) Doc says the Evaluation Suite row lists only `evals/evals.json` (:119). Code: `evals/fixtures/*/setup.sh` (12 fixtures) plus `evals/fixtures/lib.sh` also exist, and `scripts/test-spec-status-model.sh` runs every setup (lib.sh header). Fix: mention the fixtures.
     - (d) Doc says the Tech Stack names `git` with no version (:135). Code: `commit-changes.sh:71` says "Needs git >= 2.25 (--pathspec-from-file)", a CI-runner requirement. Fix: note the requirement.
     - (e) Doc says the Key Decisions "Audit owns discovery" bullet has the audit verify "the latest entry matches the most recent tagged release" (:141). Code: SKILL.md audit step 8 (SKILL.md:368) only counts commits after the latest entry's date or tag and emits a P2 "N commits unreleased since vX.Y.Z". No tag-match check is specified. Fix: reword to what step 8 does.
     - (f) Doc says the Container `verification` node reads "SKILL.md Section 2: Three-layer verification: agent evidence, freshness checks, human review" (:67, :129). Code: SKILL.md §2 has a five-step Gate Function (freshness check, `git diff`, read doc plus code_refs) and the dispatched-agent evidence rule. Human review is `update` step 8, not §2. Fix: cite "SKILL.md Section 2 and `update` step 8".

9. `docs/architecture/system-overview.md:1` — the generated-by marker on line 1 is the obsolete form and now misleading (same form also in `docs/codebase-guide.md` and `docs/conventions.md`)
   - Doc says: `<!-- Generated by doc-superpowers | 2026-07-24 | commit: 5de9fe2 -->` (system-overview.md:1).
   - Code shows:
     - `references/doc-spec.md:38-41`: the marker "carries no date or commit … A marker from an older release … is still recognized and may be left as it is". SKILL.md init step 11 writes `<!-- Generated by doc-superpowers -->`.
     - The doc was re-attested on 2026-09-29 (`docs/.doc-index.json` `last_verified` 2026-09-29T05:48:33Z), so the July date and commit 5de9fe2 read as a false freshness claim. The other living docs carry the same form, so this is a repo-wide choice. The application scope saw the same legacy dated marker in `docs/codebase-guide.md` (`2026-07-24 | commit: 5de9fe2`) and `docs/conventions.md` (`2026-04-05 | commit: 696ba07`) and did not report it as a finding, because `docs/conventions.md:96` and `references/doc-spec.md:41` say such markers are recognized and may be left as they are.
   - Suggested fix: replace with `<!-- Generated by doc-superpowers -->` (optional; the old form is permitted).

10. `docs/workflows/doc-superpowers.md:130-131` — "(Quick Reference table)" on two reference rows is wrong
    - Doc says: `references/spec-lifecycle-protocol.md` "Wrapper author integration guide (Quick Reference table)"; `references/integration-patterns.md` "Code review, commit review, and wrapper skill integration (Quick Reference table)" (lines 130-131)
    - Code shows: `integration-patterns.md` has no table and no Quick Reference heading (headings: Cross-cutting, Called BY code review skills, Called BY commit review skills, Called BY wrapper skills); `spec-lifecycle-protocol.md` has "Lifecycle Overview" (a table) and "Action Reference", no Quick Reference. The Quick Reference is in SKILL.md:20.
    - Suggested fix: drop the parentheticals, or name the "Lifecycle Overview" table for the protocol file.

11. `docs/workflows/doc-superpowers.md:426,440,447` — hooks flowchart labels: "(3 states)" and "delete hooks dir"
    - Doc says: `B -->|status| E["Report all tiers (3 states)"]` (line 440); `J -->|--claude| L["Remove settings entries\n+ delete hooks dir"]` (447)
    - Code shows: status_git reports installed / outdated / not executable / integrated / integrated-with-outdated-copy / outdated block / not installed (install.sh:764-784); status_claude adds "script missing" and "outdated" (:992-1004); `uninstall --claude` removes the three scripts and the dir only if empty (`remove_dir_if_empty`, install.sh:950-958) and the `info/exclude` block; the doc's own prose (line 426) lists more than three states. The `--claude` install box omits the `info/exclude` block.
    - Suggested fix: "Report all tiers (installed / integrated / outdated / missing)"; "Remove the three scripts (dir if empty) + settings entries + exclude block".

12. `docs/workflows/doc-superpowers.md:428` — the IMPORTANT note gives the wrong reason for "never add hook entries by hand"
    - Doc says: "Manual entries will contain unresolved `__DOC_TOOLS_RESOLVE__` placeholders and break." (line 428)
    - Code shows: the settings entry is just `bash "$CLAUDE_PROJECT_DIR"/.claude/hooks/doc-superpowers/<hook>.sh` (install.sh:836-839; .claude/settings.local.json); the placeholder lives in the hook scripts, which the installer renders (`render_hook`, install.sh:477-479). `references/hooks.md:17` says it right: "never copy hook templates by hand".
    - Suggested fix: "Hand-copied hook scripts keep the unresolved `__DOC_TOOLS_RESOLVE__` placeholder; hand-written entries also bypass the installer's per-entry merge and refusals."

13. `docs/workflows/doc-superpowers.md:389,408` — two CI table nuances: `release/*` and the audit-update scope gate
    - Doc says: "Push to `release/*` branches" (line 408); "a scope step … skips the agent when no indexed doc (or, for `doc-spec-verify`, no indexed spec) or its code is touched" (line 389, presented for all AI templates)
    - Code shows: doc-release.yml:27 `'release/**'` (matches nested names such as `release/1.0/rc`; `release/*` would not; `references/hooks.md` says `release/**`); doc-audit-update.yml:70,78,82 gate on `count != '0'` (stale + missing docs), not "touched" (`affected`), unlike review-pr / spec-verify / full-cycle, which use `affected != '0'`
    - Suggested fix: `release/**`; note that doc-audit-update runs when the branch leaves a doc stale or missing.

14. `docs/workflows/doc-superpowers.md:58-59,77-86` — the discovery sequence diagram runs the agentic scan before the freshness check
    - Doc says: diagram order: resolve tools, find scripts, glob scopes, `find .claude/skills skills .claude/commands, MCP configs`, then `doc-tools.sh check-freshness` (lines 77-86); the numbered steps say 3 = baseline checks, 4 = agentic workflows (lines 58-59)
    - Code shows: SKILL.md order: Detect Bundled Tooling, Detect Scopes, Run Baseline Checks (:216), Detect Agentic Workflows (:227)
    - Suggested fix: swap the two message pairs in the diagram.

15. `docs/workflows/doc-superpowers.md:159-187,777-779,825-827` — `init` flowchart omits steps; the Sub-Agents table splits the Explore agents differently from the diagrams
    - Doc says: init flowchart has no node for step 2 (flat-to-structured migration check), step 4 (per-skill Explore) or step 7 (seed ADRs) (lines 159-187); Sub-Agents rows "Explore (structure)", "Explore (tech)", "Explore (conventions)" as three agents (lines 777-779), while the init flowchart and the agentic sequence diagram pair them as "Structure + Tech", "APIs + Data", "Workflows + Conventions" (lines 166-168, 825-827)
    - Code shows: SKILL.md:331-341 lists seven focus areas over up to three agents; step 7 seeds ADRs; there is no "APIs"/"data" row in the table
    - Suggested fix: add "Seed ADRs" and the migration check to the flowchart; make the table rows match the three paired agents.

16. `docs/workflows/doc-superpowers.md:258-259` — `review-pr` step order and an unsupported mapping claim
    - Doc says: step 1 identify changed files, step 2 "Run discovery to map changed files to documentation scopes (via doc-index `code_refs`, directory heuristics, or skill/command file changes)" (lines 258-259)
    - Code shows: SKILL.md:405-417 runs discovery first (step 1), then identifies changed files (2), scopes the freshness check (3), and maps files to scopes (4) with no method stated; "directory heuristics" and "skill/command file changes" appear nowhere in SKILL.md or references (rg heuristic: no hits)
    - Suggested fix: reorder to SKILL.md's steps and drop the parenthetical or cite the path-segment match of `check-freshness --code-refs-from`.

17. `docs/workflows/doc-superpowers.md:480,485` — `release` omits its skip rules
    - Doc says: "Run `doc-tools.sh bump-version X.Y.Z` to update version strings across all manifests" (line 485); "Auto-suggest version bump from conventional commit prefixes (feat→MINOR, fix→PATCH, BREAKING→MAJOR)" (480)
    - Code shows: "only those the project has … Skip this step when the project has none of these manifests (`bump-version` would exit 1)" (`references/release.md:33`); `docs:` maps to PATCH and unmapped prefixes default to PATCH (:22); a missing RELEASE-NOTES.md is created (:14); no commits ends with "No unreleased commits." (:15)
    - Suggested fix: add those clauses to steps 1, 2, 4 and 9.

18. `docs/workflows/doc-superpowers.md:322,339,342` — Hook Contracts wording: "Every hook", the bypass variable, prepare-commit-msg conditions
    - Doc says: "Every hook runs its freshness check scoped to the paths it cares about, with both sides of a rename (`git … diff --name-only --no-renames`), fed to `check-freshness --code-refs-from -`." (line 339); prepare-commit-msg "acts only when `$2` is empty or `template`" (342); `hooks status [--git] [--claude] [--ci]` (322)
    - Code shows: `scripts/hooks/git/pre-push` runs no freshness check (it counts commits since the newest tag, lines 27-30); every hook honours `DOC_SUPERPOWERS_SKIP=1` and `install.sh status` prints it, but the doc never mentions it (documented in README.md and docs/conventions.md); prepare-commit-msg also requires `commit.cleanup` default/strip and a non-`auto` comment character (git/prepare-commit-msg:26-33); `status` also accepts `--all` (install.sh:1513)
    - Suggested fix: "Every hook except `pre-push`"; add the `SKIP` bypass and the two extra prepare-commit-msg conditions.

19. `docs/workflows/doc-superpowers.md:418,469,706,765,769` — the script inventory is partial ("Scripts & Commands" lists commands only)
    - Doc says: section "Scripts & Commands" (line 706) holds only slash-command forms; the Steps table names `find`, `doc-tools.sh check-freshness`, `jq`, `scripts/hooks/install.sh` (lines 765, 769)
    - Code shows: never named in the doc: `scripts/merge-doc-index.sh` (registered as a "custom merge driver", line 418, without its name), the verbs `set-doc-type`, `status`, `implementation-status`, `set-implementation`, and the step scripts `resolve-auth.sh`, `sentinel-check.sh`, `write-context.sh`, `verify-fragment.sh` (the doc names `freshness-check.sh`, `commit-changes.sh`, `prepare-agent.sh`, `pr-guard.sh` and "precheck"); `tools status` also reports whether `RELEASE-NOTES.next/README.md` matches the plugin's spec (`doc-tools.sh --help`, `tools status`), which line 469 omits. `set-doc-type` is a SKILL.md Index-write routing row (SKILL.md:179) but no flow in this doc uses it.
    - Suggested fix: retitle the section "Commands", add a short "Scripts the skill invokes" table (doc-tools.sh 16 verbs by group, install.sh, state.sh, merge-doc-index.sh, the step scripts).

20. `docs/workflows/doc-superpowers.md:763-771,807-841` — the agentic sequence diagram has no PNG or `<details>` wrapper; phase numbering differs between the table and the flowchart
    - Doc says: "### Sequence Diagram" holds a bare ```` ```mermaid ```` block (lines 807-841); every other diagram has a PNG plus a `<details>` Mermaid source; the Steps table numbers phases 1-6 (lines 763-771) while the flowchart has three (lines 739-757) and the Sub-Agents table cites "init Phase 2", "audit/review-pr Phase 3"
    - Code shows: `references/doc-spec.md:5` "Every diagram is a PNG **plus its Mermaid source** in a `<details>` block"; diagram naming `agentic-sequence-{skill-name}.png` (doc-spec.md:924-938); only `diagrams/workflow-doc-superpowers.png` exists for the agentic section
    - Suggested fix: wrap it in `<details>` under a generated PNG (the diagram pass) and use one phase numbering.

21. `docs/workflows/doc-superpowers.md:149,211,286-294,710-724` — Commands table: `update` wording and missing flags; small step omissions in `audit`, `diagram`, `init`
    - Doc says: `/doc-superpowers update` "Apply fixes from prior audit/review" (line 713); commands listed without `--report=<path>`, `--from=<ref>`, `--plan`/`--specs`/`--design-doc`/`--changed-files` (lines 710-724); audit step 11 "Compare agentic inventory against documented workflow sections" (211); diagram steps 1-6 (286-294); init step 11 "Add the marker as first line of each generated file" (149)
    - Code shows: `update` reads `--report=<path>`, this session's audit, or `check-freshness`; `review-pr` writes no report (SKILL.md:27, 433); audit step 11 is conditional, "When auditing `workflows/`" (SKILL.md:396); `diagram` also checks that `workflows/agentic/{skill-name}.md` exists per skill, and only *missing* diagrams are P2, diverged ones are just flagged (SKILL.md:489-493, 498); init's marker excludes `template.md` files (SKILL.md:350)
    - Suggested fix: reword `update`, add the flags the flows already describe, and restore the three conditions.

22. `docs/codebase-guide.md:274-276` — index write path shows generated_at / schema_version stamping after the atomic install; the code stamps inside the one jq pass, before it
    - Doc says: "→ _index_install   tmp beside the target → chmod to the prior mode (0644 when new) → mv" then "→ changed?         stamp generated_at and schema_version 3; drop any legacy stored status "current"/"stale"" (docs/codebase-guide.md:274-276)
    - Code shows: the stamp and the legacy-status drop are part of the wrapped jq program (`| .generated_at = $now`, doc-tools.sh:1866, followed by the `.docs |= map_values(...)` status drop and `.schema_version = 3`), which runs before the tmp file is written. `_index_install` (doc-tools.sh:1772, called at :1898) only chmods and `mv`s.
    - Suggested fix: move the "changed?" line above `_index_install`, or fold it into the "ONE jq pass" line: "old index → new index; when changed, also stamps generated_at and schema_version 3 and drops legacy stored status".

23. `docs/codebase-guide.md:281` — the list of verbs that take the lock before reading omits `set-doc-type`
    - Doc says: "Verbs whose patch depends on the current entries (`update-index` reads `code_refs`; `move-entry` checks presence; `set-code-refs` keeps recorded `code_oids`; `deprecate-entry --superseded-by` reads the successor's `replaces`) take the lock before reading" (docs/codebase-guide.md:281)
    - Code shows: `cmd_set_doc_type` (doc-tools.sh:3656) also reads the entry and the index's used doc_types under the lock: "What the entry holds and which types this index uses are read under the lock the write then takes (re-entrant)" (:3665-3669, `_index_lock` at :3669). Five verbs call `_index_lock` before `_index_apply`: update-index :2948, move-entry :3346, set-code-refs :3504, set-doc-type :3669, deprecate-entry :3766.
    - Suggested fix: add "`set-doc-type` checks presence and the known doc_types".

24. `docs/codebase-guide.md:251` — command-line paragraph describes the repository check as a single `git rev-parse --git-dir`
    - Doc says: "then, for repository verbs, one `git rev-parse --git-dir` check (also exit 2)" (docs/codebase-guide.md:251)
    - Code shows: `_require_repo` (doc-tools.sh:2499-2510) makes two checks, both exit 2: `git rev-parse --git-dir` (not a repository) and `git rev-parse --show-prefix` (run from a subdirectory: "must run from the repository's top level"). `--help` states the same: "or below its top level".
    - Suggested fix: "one repository check: inside a work tree (`--git-dir`) and at its top level (`--show-prefix`), else exit 2".

25. `docs/codebase-guide.md:92` — workflow diagram directory comment names a diagram family that is not there
    - Doc says: "└── diagrams/           # Workflow PNGs (sequences, workflows, state)" (docs/codebase-guide.md:92)
    - Code shows: `git ls-files docs/workflows/diagrams/` holds `sequence-*` (3) and `workflow-*` (6) PNGs only. No state PNG exists, and docs/workflows/doc-superpowers.md has no `stateDiagram` or state image.
    - Suggested fix: "(sequences, workflows)".

26. `docs/codebase-guide.md:111,150` — fixtures described as covering every eval; only 12 of 20 evals have one
    - Doc says: "lib.sh + <eval>/setup.sh — each eval's scenario, built in an empty dir" (docs/codebase-guide.md:111); "each eval's scenario built by `fixtures/<eval>/setup.sh`" (:150)
    - Code shows: `jq '.evals[]|{id,files}' evals/evals.json` gives 20 evals; ids 1, 2, 5, 7, 8, 10, 11, 13 have `"files":[]` (no setup). The remaining 12 reference `evals/fixtures/<name>/setup.sh` (id 19 also chains `update-from-audit`); `git ls-files evals/fixtures` shows 12 setup dirs plus `lib.sh`.
    - Suggested fix: "the scenario of each eval that needs one (12 of 20)".

27. `docs/codebase-guide.md:292-303` — release flow puts the version-bump suggestion before the fragment merge; `references/release.md` merges first
    - Doc says: the bullets run "Determine the range start" → "Auto-suggest semver bump from conventional commit prefixes" → "Merge per-PR release-notes fragments, before drafting" (docs/codebase-guide.md:292-303)
    - Code shows: `references/release.md:15-23` order is step 2 range start → step 3 "Merge the PR fragments — before drafting" → step 4 "Auto-suggest version bump" → step 5 drafting agent. (The "before drafting" wording is right; the bump/merge order is swapped.)
    - Suggested fix: swap the two bullets.

28. `docs/codebase-guide.md` (index metadata, `docs/.doc-index.json`; not doc text) — codebase-guide is typed `guide`, not `codebase-guide`
    - Doc says: n/a (docs/.doc-index.json entry)
    - Code shows: `docs/codebase-guide.md` has `doc_type: "guide"`, although `set-doc-type` and conventions.md:384 list `codebase-guide` (and `conventions`) as known types. Both are living docs either way, so freshness is unaffected.
    - Suggested fix: optional: `set-doc-type docs/codebase-guide.md codebase-guide` (and the same for conventions.md) at the next attest.

29. `docs/conventions.md:51,335` — two Read/Write and Version Tooling bullets are loose about what the verbs do
    - Doc says: "**`check-version`** — verifies all manifest files contain the same version" (docs/conventions.md:51); "**`status`** is read-only (summarizes current state)" (:335)
    - Code shows: `check-version` compares each manifest with RELEASE-NOTES.md's first release heading and exits 1 on any mismatch, invalid JSON or no manifest (doc-tools.sh:3969-4010; `--help`), so the manifests could all agree and still fail. The doc's own next paragraph (:55) says this. `status` is one doc's freshness, "Freshness of one doc (read-only, JSON): the same verdict check-freshness reports for it" (`--help`), not a summary of the index.
    - Suggested fix: "verifies each manifest carries RELEASE-NOTES.md's version" and "`status` reports one doc's freshness (read-only)".

30. `docs/conventions.md:156,161` — Graceful Degradation first-run row understates what happens
    - Doc says: "| Doc-index (first run) | `check-freshness` reports missing — run `init` to build |" (docs/conventions.md:161), under "Missing tools trigger fallbacks, never failures" (:156)
    - Code shows: with no index `check-freshness` exits 1 ("ERROR: doc-index.json not found at docs/.doc-index.json. Run build-index first.", `_index_load` at doc-tools.sh:1602-1606). SKILL.md:581 Error Handling says the same: "`check-freshness` exits 1 (\"doc-index.json not found\") — run `init`, which builds it". "Reports missing" reads like the computed per-doc `missing` status.
    - Suggested fix: "`check-freshness` exits 1 (\"doc-index.json not found\"); `init` builds it".

31. `docs/conventions.md` (index metadata, `docs/.doc-index.json`; not doc text) — conventions.md documents behaviour in files outside its `code_refs`
    - Doc says: n/a (docs/.doc-index.json entry: `code_refs: ["skills/doc-superpowers/SKILL.md","references/doc-spec.md"]`, `doc_type: "guide"`)
    - Code shows: most of conventions.md describes `scripts/hooks/install.sh`, `scripts/hooks/ci/**`, `scripts/doc-tools.sh` (bump-version, `doc_type` list, schema), `scripts/merge-doc-index.sh` and `scripts/test-helpers.sh`, none of which is a code ref, so a change to them never marks this doc stale. (codebase-guide.md carries `scripts/`.) It is also typed `guide`, not `conventions`.
    - Suggested fix: optional: `set-code-refs docs/conventions.md --refs skills/doc-superpowers/SKILL.md,references/doc-spec.md,scripts/doc-tools.sh,scripts/hooks` and a retype to `conventions`, then `update-index` after reading.

32. `docs/guides/getting-started.md:192,199,201` — "All Available Commands" table omits arguments the actions need
    - Doc says: "`/doc-superpowers spec-inject --phase=plan\|execute`", "`/doc-superpowers spec-verify --mode=post-execute\|review`", "`/doc-superpowers update`" (getting-started.md:192, :199, :201)
    - Code shows: `spec-inject --phase=plan` needs `--plan` and `--specs`; `spec-verify` takes `--specs` (SKILL.md:533-536; CLAUDE.md:159-160 lists them); `update` takes `--report=<path>` and `[scope]`. The same page's spec section (:163-181) does show them, so the table is the outlier.
    - Suggested fix: align the three rows with CLAUDE.md:148-160.

33. `docs/guides/getting-started.md` (index metadata, `docs/.doc-index.json`; not doc text) — index `code_refs` do not cover the installer or `doc-tools.sh` it documents
    - Doc says: (index entry) `code_refs: ["README.md", "skills/doc-superpowers/SKILL.md"]` (docs/.doc-index.json, key `docs/guides/getting-started.md`)
    - Code shows: the page documents `install.sh` flags, state tracking and `doc-tools.sh tools ...` (getting-started.md:90-129, :195-197), so a change to `scripts/hooks/install.sh`, `scripts/hooks/state.sh` or `scripts/doc-tools.sh` will not mark it stale.
    - Suggested fix: `doc-tools.sh set-code-refs docs/guides/getting-started.md --refs README.md,skills/doc-superpowers/SKILL.md,scripts/hooks/install.sh,scripts/doc-tools.sh`, then `update-index` after this pass.

34. `README.md:21` — "Syncs CLAUDE.md and README.md automatically across all write actions" is broader than the skill
    - Doc says: "**Syncs CLAUDE.md and README.md** automatically across all write actions to prevent drift" (README.md:21)
    - Code shows: `init`, `update`, `sync` and `release` sync them (SKILL.md:347-348, :465-466, :510-511; release.md:34); `diagram` and the spec actions do not; in a doc-superpowers CI workflow `update` and `sync` "edit no CLAUDE.md or README.md there" and only report (SKILL.md:135).
    - Suggested fix: "across `init`, `update`, `sync` and `release` (in CI it reports instead of editing)".

35. `README.md:253` — agentic discovery list omits plugin-layout skills
    - Doc says: "**Skills** (`.claude/skills/*/SKILL.md`)" (README.md:253)
    - Code shows: discovery also scans `skills/*/SKILL.md` (SKILL.md:230, :244), which is how this repo's own skill is found.
    - Suggested fix: "`.claude/skills/*/SKILL.md` and `skills/*/SKILL.md`".

36. `README.md:199-203` — `$DOC_TOOLS` is used but never defined in the README
    - Doc says: "$DOC_TOOLS tools install  # → .github/scripts/doc-tools.sh" (README.md:199-203)
    - Code shows: the variable is defined in SKILL.md:105-116 and in getting-started.md:114-123 (how to set it per install type); nothing in the README says where it comes from.
    - Suggested fix: one line before the block: "`$DOC_TOOLS` is the plugin's `scripts/doc-tools.sh` (see getting-started, *Independent of hooks*)".

37. `README.md:44` — manual project-level install omits Claude Code's workspace-trust requirement (unverified: vendor-doc claim only; the scope agent read the Claude Code skills page on 2026-09-28 and did not exercise the behaviour)
    - Doc says: "Copy the whole repository into `.claude/skills/doc-superpowers/` in any project." (README.md:44)
    - Code shows: the Claude Code skills page (checked 2026-09-28) says a skill folder with `.claude-plugin/plugin.json` loads as a plugin `<name>@skills-dir` and "In a project's `.claude/skills/`, this requires accepting the workspace trust dialog first." The README's symlink claim itself (README.md:35) matches that page.
    - Suggested fix: add "(Claude Code asks you to accept the workspace trust dialog first)".

38. `README.md:298` (also `CLAUDE.md:11` and `docs/codebase-guide.md:112`) — `.worktrees/` is described as a skill artifact the skill no longer has
    - Flagged by: the project scope report, twice (README.md finding, plus a CLAUDE.md finding that only says "see the README finding"); merged into one entry. The project report noted `docs/codebase-guide.md:112` needs the same edit (another scope, not separately reported there).
    - Doc says: "├── .worktrees/           # Parallel agent dispatch worktrees (gitignored)" (README.md:298; same line at CLAUDE.md:11)
    - Code shows: no file under `skills/`, `references/`, `scripts/hooks/` or `evals/` mentions `.worktrees` (`grep -rn '\.worktrees'` hits only these two docs, `docs/codebase-guide.md:112`, and record docs); scope agents are dispatched with the `Agent` tool, not worktrees (SKILL.md:333, :369). The directory does not exist in a checkout; only `.gitignore` names it.
    - Suggested fix: drop the tree line from README and CLAUDE.md, or say "(gitignored; worktree location convention only)". `docs/codebase-guide.md:112` needs the same edit.

39. `CLAUDE.md:170` — Testing bullet says the suites run "on every PR"; the workflow filters to PRs targeting `main`
    - Doc says: "All five run in CI via `.github/workflows/tests.yml` on push to `main` and on every PR" (CLAUDE.md:170)
    - Code shows: `on: push: branches: [main]` and `pull_request: branches: [main]` (tests.yml:13-17).
    - Suggested fix: "on push to `main` and on every PR targeting `main`".

40. `CLAUDE.md:138-139,166` — Key Files table has no row for the cross-client manifests, INSTALL guides or GEMINI.md
    - Doc says: Conventions require `bump-version` to "update the 5 manifest files" (CLAUDE.md:166) but no Key Files row names them; the table has rows for `AGENTS.md` and `.opencode/plugins/doc-superpowers.js` only (CLAUDE.md:138-139).
    - Code shows: the five are `package.json`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `.cursor-plugin/plugin.json`, `gemini-extension.json` (doc-tools.sh `bump-version` help); `GEMINI.md`, `gemini-extension.json` and the three INSTALL guides are pinned by `test-spec-status-model.sh` I-12 (:1010-1240) yet only appear in the tree.
    - Suggested fix: one row "`.claude-plugin/*`, `.cursor-plugin/plugin.json`, `gemini-extension.json`, `package.json` — the 5 version manifests (bump-version target)" and one for `.*/INSTALL.md` + `GEMINI.md`.

41. `docs/issues/2026-09-27-sweep-05ea982-I01-*.md` … `I14-*.md` (14 record files) — uppercase `I` in kebab-case file names
    - Doc says: the naming rule flags files that do not match kebab-case patterns (SKILL.md audit step 4; naming table in `references/doc-spec.md`).
    - Code shows: the 14 record issue files `docs/issues/2026-09-27-sweep-05ea982-I01…I14-*.md` carry an uppercase `I` in their kebab-case names.
    - Suggested fix: leave them. They are records, and renaming them needs the owner's yes.

### CLAUDE.md Status
- [ ] Directory Structure: current apart from the `.worktrees/` line (CLAUDE.md:11), which describes an artifact the skill no longer has (P3 entry 38). Every other path exists in `git ls-files` or is gitignored as stated (`.claude/settings.local.json`, `.claude/hooks/doc-superpowers/`); nothing tracked is missing from the tree (9 references, 5 helper files, 9 step scripts, 8 CI templates, evals fixtures checked).
- [ ] Key Files: stale — all 32 listed paths exist and the descriptions match `doc-tools.sh --help` (16 subcommands), install.sh, state.sh, tests.yml and the self-install drift step, but there is no row for the 5 version manifests, the INSTALL guides or `GEMINI.md` (P3 entry 40).
- [ ] Commands: stale — drops `[scope]`, `update --report=<path>`, `release --from=<ref>` and the CI options of `hooks install` / `uninstall` (P2 entry 16). The command list otherwise matches SKILL.md's 11 actions plus `hooks install|status|uninstall`.
- Also: the Testing bullet says the suites run "on every PR", but the workflow filters to PRs targeting `main` (P3 entry 39). The suite counts (1290 / 912 / 516 / 453 / 486 = 3657, no XFAIL) match the dispatch but were not re-measured.

### README.md Status
- [ ] Feature list: stale — "zero dependencies" claim (P1 entry 8); skills.sh install path (P1 entry 10, unverified); "Syncs CLAUDE.md and README.md automatically across all write actions" is too broad (P3 entry 34); the Generated Documentation table over-states two rows (P2 entry 15); agentic discovery list omits `skills/*/SKILL.md` (P3 entry 35).
- [ ] Command / API list: stale — the Usage line says scopes are auto-detected from `docs/` (P1 entry 9); the `update` row lacks `--report=<path>` (P2 entry 14). The action rows for init/audit/review-pr/diagram/sync/hooks/release/spec-*, the installer flags block and the `Upgrading from 2.x` items 1-8 are accurate.
- [ ] Usage examples: stale — no `update` example (P2 entry 14); `$DOC_TOOLS` is never defined (P3 entry 36); the manual install omits the workspace-trust dialog (P3 entry 37, unverified); the `.worktrees/` tree line is stale (P3 entry 38). The per-client install blocks and the File Structure tree otherwise match.

### RELEASE-NOTES.md Status
- [ ] 53 commits unreleased since v2.15.0 (2026-09-01), which is tagged. The planned v3.0.0 release flow covers this; run `/doc-superpowers release` (P2 entry 17).

### Actions
- Run `/doc-superpowers update --report=docs/plans/2026-09-28-audit-report.md` to apply the Update Tasks below
- Run `doc-tools.sh update-index <doc>` after manual review
- CLAUDE.md is flagged stale above: update it per `references/doc-spec.md` CLAUDE.md update rules (in a doc-superpowers CI workflow, `update` reports the change instead)
- README.md is flagged stale above: update it per `references/doc-spec.md` README.md update rules (in a doc-superpowers CI workflow, `update` reports the change instead)
- RELEASE-NOTES.md is flagged stale above: run `/doc-superpowers release` to draft a new version entry

## Update Tasks

**Generated by:** /doc-superpowers audit
**Branch:** claude/2026-09-27-repo-handoff-4b960b

### Scope
application, ci-cd, agentic, spec (design specs only, which are records). Docs audited: `docs/architecture/system-overview.md`, `docs/workflows/doc-superpowers.md`, `docs/codebase-guide.md`, `docs/conventions.md`, `docs/guides/getting-started.md`, `CLAUDE.md`, `README.md`, `AGENTS.md`, `GEMINI.md`, `RELEASE-NOTES.md`. Task numbers below match the entry numbers in the report above (P1 entry n, P2 entry n, P3 entry n).

### Findings Summary
| Priority | Count | Action |
|----------|-------|--------|
| P0 Critical | 0 | Must fix before merge |
| P1 Stale | 10 | Update recommended |
| P2 Incomplete | 17 | Add coverage |
| P3 Style | 41 | Low priority |

### P0 — Critical Updates
None.

### P1 — Stale Updates
- [ ] P1-1 `docs/architecture/system-overview.md:109`, `docs/workflows/doc-superpowers.md:385`, `docs/conventions.md:266`: correct the statements about which CI `run:` steps are vendored or inline. Only `doc-pr-release.yml`'s pre-checkout PR resolver is inline; `doc-pr-release.yml` also runs `doc-pr-release/commit-and-push.sh`; there is no "one-line echo" step (conventions.md).
- [ ] P1-2 `docs/workflows/doc-superpowers.md:631,641`: say spec-verify emits four P3 informational lines (add "amendments verified as landed") in both places.
- [ ] P1-3 `docs/workflows/doc-superpowers.md:768,784-788`: delete the five spec-lifecycle sub-agent rows and change row 3b to "the invoking agent runs the spec actions inline (no sub-agent dispatch)".
- [ ] P1-4 `docs/workflows/doc-superpowers.md:566-607`: qualify the `spec-inject --phase=execute` Aligned branch, sequence diagram and status transitions for the one-per-chunk-writer rule (this phase writes only `Draft` → `In Review`; `Implemented` belongs to the finalize task; `Approved` is human-set); add the "amendment pending (Task N)" report to the Amendment bullet.
- [ ] P1-5 `docs/codebase-guide.md:213-215`: replace the init "Discovery Phase" `Bash:` lines with the current four discovery parts and add init steps 2 and 7 to the "Typical init flow".
- [ ] P1-6 `docs/codebase-guide.md:168`: point "Agentic workflow template" at the `docs/workflows/agentic/README.md` and `docs/workflows/agentic/{skill-name}.md` templates in `references/doc-spec.md`.
- [ ] P1-7 `docs/guides/getting-started.md:225-228,86`: state that every generated file except `template.md` starts with the marker.
- [ ] P1-8 `README.md:381`: replace the "zero dependencies" claim; the skill runs the bundled `scripts/` tooling from its plugin root and needs the whole repository plus bash, git, jq >= 1.6 and sha256sum/shasum.
- [ ] P1-9 `README.md:107`: change the Usage line to "Scopes:  all | one scope from Detect Scopes (...)" and add that `[scope]` applies to `audit`, `update`, `diagram` only.
- [ ] P1-10 `README.md:78-84`: (unverified: vendor-doc reading only; verify with a real `npx skills add` in a scratch directory before editing) if `npx skills add` copies only `skills/doc-superpowers/`, remove the skills.sh section or say it cannot supply `scripts/` and `references/`; if kept, drop or correct "40+" (the CLI lists 75+).

### P2 — Missing Coverage
- [ ] P2-1 `docs/architecture/system-overview.md`: add Tech Stack rows for `references/release.md` and `references/hooks.md` and mention them in the Container `router` node.
- [ ] P2-2 `docs/architecture/system-overview.md:83,87`: add the missing Rels (`hooks`/CI to `doctools`), and optionally Containers for the merge driver and CI templates.
- [ ] P2-3 `docs/architecture/system-overview.md`: state index `schema_version` 3, the v2 read rule and a pointer to the field reference in `references/doc-spec.md`.
- [ ] P2-4 `docs/architecture/system-overview.md:109,151`: add a one-line inventory of the 5 git hooks, 3 Claude scripts and 9 CI step scripts.
- [ ] P2-5 `docs/workflows/doc-superpowers.md:206,274,710-714`: document `[scope]` in the audit/update/diagram commands and steps.
- [ ] P2-6 `docs/workflows/doc-superpowers.md:504-509`: add the user-confirmation gate and archive/`move-entry`/`deprecate-entry` sequence (steps 5 and 8), the no-reuse numbering rule (step 6) and the `## Specs Requiring Updates` table (step 9) to `spec-generate`.
- [ ] P2-7 `docs/workflows/doc-superpowers.md:790-799`: add four rows to the User Interaction Gates table (doc migrate/archive/delete/supersede confirmation; `hooks --ci` consent; version-bump confirmation; init's commit offer).
- [ ] P2-8 `docs/workflows/doc-superpowers.md:396,406,408,411`: add `workflow_dispatch` triggers and inputs, the pr-release `paths-ignore`, and a Permissions / Commits column (or a pointer to the `references/hooks.md` consent table).
- [ ] P2-9 `docs/workflows/doc-superpowers.md` (index entry): `set-code-refs` to add `references/`, `scripts/hooks/`, `scripts/doc-tools.sh`, `scripts/merge-doc-index.sh` (or keep `scripts/`), then `update-index` after the fixes.
- [ ] P2-10 `docs/conventions.md:326-335`: add `set-doc-type` and `remove-entry` to Read/Write Separation.
- [ ] P2-11 `docs/conventions.md:249-256`: add `--transient` (uninstall only) to the CI-Specific Flags table.
- [ ] P2-12 `docs/conventions.md:142-167`: add a "Safety Rules" bullet to Project-Specific Patterns, reword the "User-provided scripts" row to "listed, never auto-run (Safety Rules)", and note in the archive model that moving or archiving needs the user's yes.
- [ ] P2-13 `docs/guides/getting-started.md:103-104`: change the CI opt-in example to `--workflows=doc-release` (or `doc-pr-release,doc-review-pr`).
- [ ] P2-14 `README.md:117`: add `--report=<path>` to the `update` row and an `update` example.
- [ ] P2-15 `README.md:234,237`: mark the ERD as `data-layer` scope only, reword the workflow row (primary workflow always; `deployment.md` with `ci-cd`), and add the agentic index row (and the conditional `## Testing` / `## Packages` sections).
- [ ] P2-16 `CLAUDE.md:148-157`: add `[scope]`, `update [--report=<path>]`, `release [--from=<ref>]` and one line for the CI options of `hooks install` / `uninstall`.
- [ ] P2-17 `RELEASE-NOTES.md`: run `/doc-superpowers release` to draft the v3.0.0 entry for the 53 commits since v2.15.0 (not an `update` edit).

### P3 — Style
- [ ] P3-1 `docs/architecture/system-overview.md:30,109`: qualify "both fail closed" ("never report an unrunnable check as all-current; the PR check warns, or fails under `--ci-strict`; the schedule run and AI scope gate fail").
- [ ] P3-2 `docs/architecture/system-overview.md:109`: note that for `doc-pr-release`, `commit-changes.sh --check-only` verifies and `commit-and-push.sh` commits.
- [ ] P3-3 `docs/architecture/system-overview.md:109`: restrict "gate on the doc index instead of path filters" to four of the six AI workflows (the producer and release drafter have their own gates).
- [ ] P3-4 `docs/architecture/system-overview.md:108`: append "except that `--helpers=false` is refused while `doc-pr-release` is selected or installed"; check whether `docs/workflows/doc-superpowers.md`, `docs/conventions.md` and `README.md` need the same qualification.
- [ ] P3-5 `docs/architecture/system-overview.md:108,163`: attribute the workflow-list derivation to `install.sh`, not `state.sh`, and drop or qualify "single-writer".
- [ ] P3-6 `docs/architecture/system-overview.md:161`: correct the merge-driver conflict cases (names the doc key, and the fields for a tie; structural failures name no key).
- [ ] P3-7 `docs/architecture/system-overview.md:7,32`: say plugin manifests cover Cursor, OpenCode and Gemini CLI, and Codex uses a symlinked checkout.
- [ ] P3-8 `docs/architecture/system-overview.md`: fix the six small inventory imprecisions (a) `fragments list|validate|merge`, (b) `fragment-lib.sh` sourced by two helpers only, (c) eval fixtures, (d) git >= 2.25, (e) audit does not check tag match, (f) cite "SKILL.md Section 2 and `update` step 8".
- [ ] P3-9 `docs/architecture/system-overview.md:1`: (optional) replace the legacy dated marker with `<!-- Generated by doc-superpowers -->`; `docs/codebase-guide.md` and `docs/conventions.md` carry the same legacy form and may be left, per `references/doc-spec.md:41`.
- [ ] P3-10 `docs/workflows/doc-superpowers.md:130-131`: drop the "(Quick Reference table)" parentheticals or name the "Lifecycle Overview" table for the protocol file.
- [ ] P3-11 `docs/workflows/doc-superpowers.md:426,440,447`: fix the hooks flowchart labels ("Report all tiers (installed / integrated / outdated / missing)"; "Remove the three scripts (dir if empty) + settings entries + exclude block").
- [ ] P3-12 `docs/workflows/doc-superpowers.md:428`: correct the reason for "never add hook entries by hand" (hand-copied hook scripts keep the unresolved placeholder; hand-written entries bypass the installer's merge and refusals).
- [ ] P3-13 `docs/workflows/doc-superpowers.md:389,408`: change `release/*` to `release/**` and note that doc-audit-update runs when the branch leaves a doc stale or missing.
- [ ] P3-14 `docs/workflows/doc-superpowers.md:77-86`: swap the two message pairs in the discovery sequence diagram (baseline checks before the agentic scan).
- [ ] P3-15 `docs/workflows/doc-superpowers.md:159-187,777-779`: add "Seed ADRs" and the migration check to the init flowchart and make the Sub-Agents rows match the three paired Explore agents.
- [ ] P3-16 `docs/workflows/doc-superpowers.md:258-259`: reorder `review-pr` steps to SKILL.md's and drop or correct the "directory heuristics" parenthetical.
- [ ] P3-17 `docs/workflows/doc-superpowers.md:480,485`: add the `release` skip rules (no manifests, `docs:`/unmapped prefixes to PATCH, missing RELEASE-NOTES.md created, "No unreleased commits.").
- [ ] P3-18 `docs/workflows/doc-superpowers.md:322,339,342`: say "Every hook except `pre-push`", add the `DOC_SUPERPOWERS_SKIP=1` bypass and the two extra prepare-commit-msg conditions, and `status --all`.
- [ ] P3-19 `docs/workflows/doc-superpowers.md:706`: retitle "Scripts & Commands" to "Commands" and add a "Scripts the skill invokes" table (doc-tools.sh verbs by group, install.sh, state.sh, merge-doc-index.sh, the step scripts); add the `tools status` RELEASE-NOTES.next README check at line 469.
- [ ] P3-20 `docs/workflows/doc-superpowers.md:763-771,807-841`: wrap the agentic sequence diagram in `<details>` under a generated PNG (the diagram pass) and use one phase numbering.
- [ ] P3-21 `docs/workflows/doc-superpowers.md:149,211,286-294,710-724`: reword `update`, add the flags the flows already describe (`--report`, `--from`, `--plan`/`--specs`/`--design-doc`/`--changed-files`), and restore the audit step 11, `diagram` and init-marker conditions.
- [ ] P3-22 `docs/codebase-guide.md:274-276`: move the "changed?" stamp line above `_index_install` or fold it into the "ONE jq pass" line.
- [ ] P3-23 `docs/codebase-guide.md:281`: add `set-doc-type` to the verbs that take the lock before reading.
- [ ] P3-24 `docs/codebase-guide.md:251`: describe the two-part repository check (`--git-dir` and `--show-prefix`).
- [ ] P3-25 `docs/codebase-guide.md:92`: change "(sequences, workflows, state)" to "(sequences, workflows)".
- [ ] P3-26 `docs/codebase-guide.md:111,150`: say fixtures cover the evals that need one (12 of 20).
- [ ] P3-27 `docs/codebase-guide.md:292-303`: swap the version-bump and fragment-merge bullets to match `references/release.md`.
- [ ] P3-28 `docs/codebase-guide.md` (index metadata): optional `set-doc-type docs/codebase-guide.md codebase-guide` (and the same for conventions.md) at the next attest.
- [ ] P3-29 `docs/conventions.md:51,335`: reword `check-version` ("verifies each manifest carries RELEASE-NOTES.md's version") and `status` ("reports one doc's freshness (read-only)").
- [ ] P3-30 `docs/conventions.md:156,161`: reword the first-run row ("`check-freshness` exits 1 (\"doc-index.json not found\"); `init` builds it").
- [ ] P3-31 `docs/conventions.md` (index metadata): optional `set-code-refs docs/conventions.md --refs skills/doc-superpowers/SKILL.md,references/doc-spec.md,scripts/doc-tools.sh,scripts/hooks` and a retype to `conventions`, then `update-index` after reading.
- [ ] P3-32 `docs/guides/getting-started.md:192,199,201`: align the three command-table rows (`spec-inject`, `spec-verify`, `update`) with `CLAUDE.md:148-160`.
- [ ] P3-33 `docs/guides/getting-started.md` (index metadata): `set-code-refs docs/guides/getting-started.md --refs README.md,skills/doc-superpowers/SKILL.md,scripts/hooks/install.sh,scripts/doc-tools.sh`, then `update-index` after this pass.
- [ ] P3-34 `README.md:21`: say the sync covers `init`, `update`, `sync` and `release` (in CI it reports instead of editing).
- [ ] P3-35 `README.md:253`: list both `.claude/skills/*/SKILL.md` and `skills/*/SKILL.md`.
- [ ] P3-36 `README.md:199-203`: add one line saying `$DOC_TOOLS` is the plugin's `scripts/doc-tools.sh` (see getting-started, *Independent of hooks*).
- [ ] P3-37 `README.md:44`: (unverified: vendor-doc claim only; confirm against the Claude Code skills page before editing) add "(Claude Code asks you to accept the workspace trust dialog first)".
- [ ] P3-38 `README.md:298`, `CLAUDE.md:11`, `docs/codebase-guide.md:112`: drop the `.worktrees/` tree line, or say "(gitignored; worktree location convention only)".
- [ ] P3-39 `CLAUDE.md:170`: change "on every PR" to "on every PR targeting `main`".
- [ ] P3-40 `CLAUDE.md:138-139,166`: add a Key Files row for the 5 version manifests and one for the INSTALL guides + `GEMINI.md`.
- [ ] P3-41 `docs/issues/2026-09-27-sweep-05ea982-I01-*.md` … `I14-*.md`: no action. Recommend leaving the uppercase `I`; these are records, and renaming them needs the owner's yes.

### Execution
Run `/doc-superpowers update --report=docs/plans/2026-09-28-audit-report.md` to apply these tasks.
