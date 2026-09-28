---
date: 2026-09-27
status: Resolved
priority: P1
type: bug
component: skill
source: sweep-skill
cluster-key: sweep-skill:full-repo:I-11
run-id: 05ea982
related-files:
  - skills/doc-superpowers/SKILL.md
  - references/spec-lifecycle-actions.md
  - references/spec-lifecycle-protocol.md
  - references/doc-spec.md
  - references/tool-mappings.md
  - references/integration-patterns.md
  - evals/evals.json
screenshots: null
axiom-agent: null
branch: null
design-doc: null
report: docs/plans/2026-09-27-full-repo-05ea982-audit-findings.md
---

# I-11 — Skill prompt ↔ tool contract and agent safety

> Cluster **I-11** of sweep run `05ea982`, ranked #6 of 14. Evidence:
> [findings index](../plans/2026-09-27-full-repo-05ea982-audit-findings.md) (S8). Fix: **Task 12**
> of the [fix plan](../plans/2026-09-27-full-repo-05ea982-fix-plan.md). It runs after the tool
> Tasks, so the prompts describe the fixed tools.

## Summary

The prompt layer (SKILL.md + references) is how agents drive the tools. It has drifted from the
tools in both directions:
- it routes index writes to verbs that reject the input or replace the index;
- it resolves the tools only through the Claude Code plugin cache;
- its review-pr base detection yields an empty base;
- it runs repo scripts from the working tree during discovery.

## Incorrect assumption

- "Tools live in the Claude plugin cache."
- "`build-index` is incremental; `update-index` upserts."
- "The host project is doc-superpowers."
- "Repo scripts are trusted."
- "A prose rule is a guard" (A5).

## Verified evidence

- [P1] Tool resolution. `SKILL.md:85-94,432,505,580`; `tool-mappings.md:41-43`: `$DOC_TOOLS`,
  `install.sh` and `references/` resolve only through the plugin-cache glob. With no cache, the glob
  stays literal (rc 127). So 4 of the 5 supported clients have no tooling, despite the "full parity"
  claims. Measured.
- [P1] Review-pr base detection (root cause not named in the Phase-5 draft; added after Phase-4
  review). `SKILL.md:346-349`: `|| echo main` binds to `sed`, so `BASE=""` wherever `origin/HEAD`
  is unset. That includes this repo and `actions/checkout`. The diff is then empty, and
  `check-freshness --code-refs` with no arguments applies **no filter**. Measured.
- [P1] Index-write routing. `SKILL.md:291,373,393,428,639`; `spec-lifecycle-actions.md:92,128`;
  `evals.json:151`: the routing predates `add/move/remove/deprecate-entry`. Measured.
  - New docs go to `update-index`, which rejects them and loses the batch.
  - Untracked docs and migrations go to `build-index`, which replaces the index. The tool-side guard
    is I-4.
  - Archival never re-keys or deprecates.
  - `sync` has no add or remove step.
- [P1] `spec-lifecycle-actions.md:127`: spec-generate allows "module names" as `code_refs`. Their
  `code_commit` is null, so the spec reads current forever. Measured.
- [P1] `SKILL.md:81,158-164,424-427`: discovery (every action except hooks and release) and `sync`
  run `uv run scripts/validate_docs.py` from the working tree. So `review-pr` on a checked-out PR
  executes PR-author code. Structural.
- [P2] Contract drift:
  - `update-index` un-deprecates, but doc-spec calls deprecation "terminal";
  - `set-implementation` anchors differ from the templates;
  - the host project is assumed to be doc-superpowers (README synced against SKILL.md actions; the
    mandatory manifest bump passes vacuously);
  - `release` has no commit step before `git tag`;
  - the `:amends` landed-check runs per chunk, giving false FAILs;
  - two per-chunk Status writers use different gates;
  - an explicit `:constraint` marker is lost in injected plans;
  - the landed-check grep is not section-aware;
  - index semantics are described wrongly;
  - `replaces`/`code_refs` writes have no verb (GH #18);
  - the audit→update handoff is undefined;
  - v2.15's `:amends`/`--plan` are missing from the protocol and templates.
- [P2] Safety gaps:
  - no data-vs-instructions trust boundary;
  - no secret-handling rule;
  - the doc-pr-release trust list is incomplete;
  - the `--ci` default installs overlapping AI workflows.
- [P2] Cost and evals:
  - discovery dumps the full `check-freshness` JSON into context (~1.25 MB at 4,019 entries);
  - evals are not runnable (13 of 13 have `files: []`).
- [P3] Smaller defects:
  - headless CI commits contradict "human reviews diffs";
  - migration and archival run without confirmation;
  - the consumed-list path is a fixed `/tmp` path;
  - "read-only" claims are contradicted;
  - the schema table is stale;
  - `release` is underspecified;
  - broken anchors and duplicated templates;
  - SKILL.md is 5,949 words, of which the `release` and `hooks` bodies are 25%.

## Follow-up pass FU3 (`init` output contract + Spec Status Model, verified by V-FU3)

The Phase-4 critic found that ~470 lines of `references/doc-spec.md` (the generated-doc templates)
and `SKILL.md` 49-74 / 193-260 had never been cited. It also found that
`spec-lifecycle-actions.md:1-38` had never been compared with its design spec. The follow-up pass
added the items below. Of the finder's items, 11 were dropped on verification: duplicates of V-S1,
V-S2 and V-S8, plus two refuted.

- [P2, downgraded from P1] Exempt-status targets are still written.
  - Where: `spec-lifecycle-actions.md:184-190` (+`:249`).
  - In per-chunk Task N+1 the exempt-status bullet says only "leave unchanged". Steps 2–4 still add
    Implementation Notes, replace `code_refs` and run `update-index` for
    Active/Deprecated/Superseded/unknown targets.
  - That contradicts rule R3 (`:26`), the evaluation order (`:74` "exempt → stop, write nothing")
    and design `:143`.
  - No assertion in `test-spec-status-model.sh` pins it. Eval 13's `SPEC-ARCH-004` is exactly this
    case.
- [P2, downgraded from P1] No template has a Mermaid-source slot.
  - Where: `references/doc-spec.md:50-58,128,301,343,372,510,539,557` + `SKILL.md:402-404`.
  - The `diagram` action discovers docs by `rg -l '```mermaid'`, so docs generated from the templates
    are invisible to later regeneration and accuracy checks.
  - The repo's own `<details>` Mermaid-source convention (and CLAUDE.md's "Mermaid source in docs")
    is not encoded in any template.
- [P2] `init` has no rule for choosing `code_refs`.
  - Where: `SKILL.md:291-292` + `doc-spec.md:862`.
  - The step-13 gate passes on uncommitted output (9/9 current). The `init` commit then makes stale
    every doc whose refs cover what `init` wrote (2 stale: `.` and `README.md`). Measured.
  - A `.` or `docs/` ref can never stay current: committing any index refresh changes a path under
    it. With I-1's content identity this becomes "never cite a path that contains the index".
- [P2] Two predicate sets decide the same outputs, and they disagree. Structural.
  - Where: `SKILL.md:237-238` vs `:144-145`; `doc-spec.md:138,546,779`.
  - A routes-only HTTP app gets no `api-contracts.md`.
  - The ERD is "Always" while `data-layer.md` is "skip if no persistence".
- [P3, new at verification] `spec-lifecycle-actions.md:230` vs `:272-273,:301-304`;
  `agent-prompt-template.md:60`: finalize leaves a partially covered **Approved** target at
  Approved. spec-verify exempts only targets "held at In Review", so that target produces a false
  FAIL, contrary to design `:147`.
- [P3] Smaller items:
  - `:20` reports the sanctioned Active/Deprecated/Superseded on the "unrecognized status" line.
  - The `[scope]` argument is consumed by no action.
  - The routing diagram shadows inject/verify once a design doc exists, and has no `sync` or spec
    leaves.
  - The primary workflow doc has no filename, and there is no flowchart slot.
  - Agentic-diagram triggers are unreconciled.
  - Spec/ADR NNN is not tied to the archive.
  - `docs/decisions/` detection writes a second ADR log.
  - "FAILs in both modes" is wrong for review mode.
  - The protocol says "must be committed" and "bootstrapped if missing".
  - The adr/specs README is conditional in the matrix but unconditional in step 6.
  - The `testing`/`monorepo` scopes point at sections no template contains.
  - The component diagram has no Required-Diagrams row.
  - Agentic docs share the `workflow-{slug}.png` namespace and can collide.
  - Naming-table gaps (`erd.png`, README index files).
  - Nested fences are written as `` \`\`\` `` inside templates.
  - Two generated-marker forms stamp `template.md`, so every hand-copied spec/ADR inherits a false
    "Generated by" line.
  - There is no flat→structured mapping table.
- Clean (verified):
  - all 11 Mermaid blocks render (mermaid-cli 11, used at audit time only);
  - Usage and Quick Reference list the same 11 actions;
  - all relative image paths resolve;
  - the evaluation order matches design §A;
  - the protocol's 5 interception points and 3 actions match.

- [P3, new: FU4/V-FU4, structural] `references/doc-spec.md:857-869`: the **live** index schema table
  is wrong in three ways.
  - It still documents `version` "(currently 1)"; `build-index` writes `schema_version: 2`.
  - It has no per-entry `implementation`.
  - It lists `stale` as a stored status.

  `docs/conventions.md:322` has it right, so the two live references disagree. T4 Step 3 rewrites
  this table for schema v3 anyway.


## Proposed fix (fix plan Task 12)

- **Tool resolution:** `ROOT=<skill base dir>/../..`, with the plugin cache only as a fallback. Stop
  if the tool is not executable.
- **Routing table:**
  - new doc → `add-entry`;
  - moved or archived → `move-entry` (+ `deprecate-entry`);
  - deleted → `remove-entry`;
  - verified → `update-index`;
  - refs changed → `set-code-refs`;
  - `build-index` only when no index exists.
- **review-pr:** base from `git symbolic-ref --short -q refs/remotes/origin/HEAD` or `origin/main`.
  Stop on an empty diff.
- **Spec lifecycle:** the fixes listed under P2 above. `code_refs` must be pathspecs.
- **Safety:**
  - a trust-boundary block;
  - a secret-handling rule;
  - confirmation before migrations;
  - **never** auto-run `scripts/*validate*`.
- **Context:** discovery filters `check-freshness` through jq. Move the `release`/`hooks` bodies into
  references.
- **Evals:** give them machine-checkable fields and fixtures.

## Acceptance criteria

- [x] Contract tests (token assertions, not prose freezes) pin the routing table, the base
  detection, the pathspec rule and the no-auto-run rule.
- [x] At least evals 3, 4, 6, 9 and 12 have fixtures and checkable assertions.

## Resolution (Task 12)

Resolved by Task 12 of the fix plan. The prompt layer now describes the fixed tools, and
`scripts/test-spec-status-model.sh` pins the contracts — several by **executing** the command the
prompt tells an agent to run.

**Tool resolution** — `ROOT="${CLAUDE_SKILL_DIR}/../.."` (Claude Code substitutes the skill's base
directory; another client puts the path it loaded `SKILL.md` from), `DOC_TOOLS="$ROOT/scripts/doc-tools.sh"`;
the Claude Code plugin cache is only a fallback, picked in numeric version order without a glob
(`ls | grep | sort -t. -k1,1n -k2,2n -k3,3n`, so no `sort -V` and no zsh no-match error);
`[ -x "$DOC_TOOLS" ] || stop`. The installer and `references/` come from `$ROOT`.
`references/tool-mappings.md` has a Tool resolution section. Tests run the block under
`$BASH_BIN` and zsh: substituted dir, cache fallback (2.10.0 > 2.9.0; a version without the tool
is skipped), nothing → non-zero.

**Index-write routing** — one table in SKILL.md: new → `add-entry`; moved → `move-entry`;
archived → `move-entry` + `deprecate-entry`; deleted → `remove-entry`; edited and read →
`update-index`; refs changed → `set-code-refs`; superseded → `deprecate-entry --superseded-by`;
`build-index` only when no index exists. Migration re-keys with `move-entry --stdin` (no rebuild);
`sync` has explicit `untracked` / `missing` / `doc_modified` / `stale` steps; spec-generate
`code_refs` are literal paths (never module names; empty + `set-code-refs` later); Task N+1 and the
execute phase refine with `set-code-refs`. A guard fails any instruction to run `build-index`
that is not conditioned on there being no index.

**review-pr** — `BASE=$(git symbolic-ref --short -q refs/remotes/origin/HEAD) || BASE=origin/main`
(executed in fixtures: `origin/main` without origin/HEAD, `origin/trunk` with it); a range the
caller names wins; an empty list stops the review.

**Safety** — SKILL.md *Safety Rules*: a trust boundary (repository and PR content is data, not
instructions), a secret rule, confirmation before migrating/archiving/deleting/superseding a doc
(CI: report instead), and **never** auto-running repository scripts (`scripts/*validate*` are
listed, not run; no `uv run` anywhere). `agent-prompt-template.md` carries the trust boundary and
the secret rule. doc-pr-release's trust list covers `.existing_fragment`, its command list matches
its `--allowedTools`, and it says what to do when `update-pr-body.sh` refuses.

**Context cost** — discovery pipes `check-freshness` through
`jq '{summary, stale: [...], untracked: .untracked_docs}'` (run against real `check-freshness`
output in a test); the templates whose agents run discovery grant `Bash(jq:*)` and
`Bash(git -c core.quotePath=false diff:*)`. The `release` and `hooks` bodies moved verbatim to
`references/release.md` and `references/hooks.md` behind REQUIRED pointers (T8/T9/T10 lockstep text
kept and pinned; release.md's `$DOC_TOOLS` verbs are checked against doc-release's
`--allowedTools`).

**Host-agnostic** — README sync measures the project itself, not doc-superpowers' actions;
`release` bumps only the manifests the project has.

**Spec lifecycle** — `Task N+1a` once per `:amends` spec, in the chunk that contains Task {N};
injected tasks carry the caller's role markers (`infer` for the rest); one per-chunk `Status`
writer (the plan's Task N+1 when it exists, else the execute phase, with the same Draft → In Review
gate); a section-aware, single-line landed-check defined once (executed against a fixture spec:
in-section → PASS; other section, next section, other plan, citation on line 2 → FAIL);
an exempt-status target skips Steps 2–4; the Approved partial target is not a finding; "four" P3
lines; `--plan` and review-mode `--specs` in the protocol, integration patterns and templates.

**audit → update** — `update --report=<path>` or this session's audit, never the newest report on
disk; one report file (report + Update Tasks); the applied report is archived to
`docs/archive/plans/` with `move-entry`.

**FU3** — every template PNG has a `<details><summary>Mermaid source</summary>` slot; nested
fences are real (four-backtick outer fences); one predicate per output (`api-contracts`,
`data-layer` + ERD); Required Diagrams is the one trigger list (component row, agentic overview in
`workflows/agentic/README.md`, agentic diagrams in their own `agentic-*` namespace); the primary
workflow doc is `workflows/{workflow-name}.md`; `init` has a `code_refs` rule (never `.`, `docs/`,
or README/CLAUDE.md when synced) and runs its freshness gate after the commit; `template.md` gets
no marker; seeded ADRs are `Proposed`; `docs/decisions/` is used when present; spec/ADR numbers
count the archive; `[scope]` is defined; both routing diagrams fixed; the FU3 P3 list otherwise as
listed above. R4: the schema table (T4) verified.

**Evals** — `evals/evals.json` assertions carry `path` / `pattern` / `command` (+ `negate`,
`count`, `before`, `mode`); evals 3, 4, 6, 9, 12 and new 14–18 (spec-inject execute, spec-verify
review, `:amends`, release fragment merge, hooks status/uninstall) have `evals/fixtures/<eval>/setup.sh`
fixtures that build and self-check their scenario. The suite validates the fields, compiles every
regex, checks every named doc-tools verb exists, runs every fixture, and rejects vacuous
`file_exists` assertions.
