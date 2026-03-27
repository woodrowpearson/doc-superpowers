# Spec Lifecycle Protocol — Design Spec

**Date:** 2026-03-14
**Status:** Approved (spec review passed, iteration 3)
**Author:** Claude (brainstorming with @woodrowpearson)

## Problem

Today there are two separate spec systems that don't talk to each other:

1. **superpowers/brainstorming** writes informal design specs to `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md` — narrative-style design documents with no metadata, categorization, or lifecycle tracking.
2. **doc-superpowers** has a structured spec system with `SPEC-{CAT}-NNN-{slug}.md` naming, status enums, category codes, freshness indexing via `.doc-index.json`, and supersession chains — but these are only created/maintained during `audit` or `init` actions (reactive, not proactive).

The result is three distinct gaps:

- **No structured spec generation** — brainstorming produces a narrative design doc with no metadata, categorization, or lifecycle tracking
- **No spec creation during implementation** — writing-plans never includes tasks for generating or maintaining formal specs
- **No spec verification at completion** — no skill verifies that what was built matches formal spec documents, or that formal specs even exist

Research on Spec-Driven Development (SDD) within the RPI harness (see `sdd-rpi-agentic-coding/research_narrative.md`) confirms that specs become MORE valuable at 1M context — they serve as deterministic anchors preventing capable models from hallucinating elegant but incorrect architecture. The research recommends "Agent-Drafted Specs" as formalized durable artifacts within the RPI workflow.

## Goal

Add three composable actions to doc-superpowers that manage the formal spec lifecycle alongside the superpowers pipeline. These actions are context-agnostic primitives — doc-superpowers has zero knowledge of wrapper skills, axiom, or any specific integration. Wrapper skills read a protocol reference doc and invoke the actions at their own pipeline points.

## Success Criteria

- A design doc produced by brainstorming can be decomposed into formal `SPEC-{CAT}-NNN-{slug}.md` documents with full metadata in one action
- Implementation plans include spec maintenance tasks without manual intervention
- Spec staleness during execution is detected using existing `doc-tools.sh check-freshness` — no new drift detection mechanism
- Post-execution verification produces a structured pass/fail compliance report
- Review mode maps changed files to governing specs and flags coverage gaps
- All three actions work standalone (user-invocable) AND composable (wrapper-invocable)
- No changes to `doc-tools.sh`, `.doc-index.json` schema, or existing 7 actions

## Non-Goals

- Modifying superpowers skills (brainstorming, writing-plans, executing-plans, etc.)
- Awareness of axiom or any specific wrapper skill
- Auto-fixing spec drift (flag for human review, don't silently rewrite spec content)
- New doc-tools.sh subcommands or .doc-index.json schema fields
- Replacing the brainstorming design doc with formal specs (design docs remain the narrative source of truth; formal specs are the tracked, indexed derivative)

---

## Design

### Architecture: Composable Primitives

The design follows doc-superpowers' existing pattern: actions are independently invocable, produce deterministic outputs, and use existing tooling (`doc-tools.sh`, `.doc-index.json`) for state management.

```
┌─────────────────────────────────────────────────────────┐
│                    Wrapper Skill                         │
│  (e.g., ios-superpowers, custom project skill)          │
│                                                          │
│  Reads: references/spec-lifecycle-protocol.md            │
│  Invokes doc-superpowers actions at pipeline points      │
└───────┬──────────────┬──────────────────┬───────────────┘
        │              │                  │
        ▼              ▼                  ▼
┌──────────────┐ ┌────────────┐ ┌──────────────┐
│ spec-generate│ │ spec-inject│ │ spec-verify  │
│              │ │            │ │              │
│ Design doc → │ │ Plan: add  │ │ Post-execute:│
│ formal specs │ │ spec tasks │ │ compliance   │
│              │ │            │ │ report       │
│ Calls:       │ │ Execute:   │ │              │
│ update-index │ │ check-     │ │ Review:      │
│              │ │ freshness  │ │ freshness +  │
│              │ │ + update-  │ │ coverage     │
│              │ │ index      │ │ findings     │
└──────────────┘ └────────────┘ └──────────────┘
        │              │                  │
        ▼              ▼                  ▼
┌─────────────────────────────────────────────────────────┐
│              Existing doc-superpowers infra              │
│  doc-tools.sh | .doc-index.json | docs/specs/ | templates│
└─────────────────────────────────────────────────────────┘
```

### Pipeline Interception Points

5 interception points mapped to 3 actions:

| Pipeline Point | When | Action | Mode |
|---|---|---|---|
| Post-brainstorm | Design doc written and committed | `spec-generate` | — |
| During plan | writing-plans producing implementation plan | `spec-inject` | `plan` |
| During execute | After each plan chunk completes (not per-task) | `spec-inject` | `execute` |
| Pre-finish | All tasks done, before finishing-a-development-branch | `spec-verify` | `post-execute` |
| Review | Alongside other review participants | `spec-verify` | `review` |

---

### Action 1: `spec-generate`

**Trigger:** Post-brainstorm, after design doc is written and approved.

**Input:**
- `--design-doc=<path>` — Path to the narrative design spec (e.g., `docs/superpowers/specs/2026-03-14-feature-design.md`)
- Project root (auto-detected)

**Process:**

1. **Run discovery** (if not already run in this session).

2. **Bootstrap if needed** — If `docs/specs/` doesn't exist, create it with `template.md` and `README.md` from `references/doc-spec.md`. If `.doc-index.json` doesn't exist, run `doc-tools.sh build-index`.

3. **Parse the design doc** — Read the narrative design spec and identify distinct specification domains using doc-superpowers' 9 CAT codes (ARCH, AUTH, DATA, API, UI, PIPE, OPS, INFRA, TEST) as a classification lens.

4. **Check for idempotency** — If the design doc already has a `## Generated Specs` section, read it to identify previously generated specs. Only generate specs for newly identified domains not already listed.

5. **Check for overlapping existing specs** — For each identified domain, scan `docs/specs/` for existing specs in that category:
   - If the design doc **replaces** the existing spec's scope entirely → Create the new spec with `Supersedes: <path-to-old>`, update the old spec's `Superseded by` field, move the old spec to `docs/archive/specs/`, and update the archived spec's `.doc-index.json` entry to `status: "deprecated"`.
   - If the design doc **extends** existing scope → Create a new spec with the next sequential number (e.g., AUTH-002 if AUTH-001 exists), no supersession.
   - If the design doc covers the **same scope with the same intent** → Do not create a duplicate. Flag for human review: "Existing SPEC-{CAT}-NNN already covers this scope. Update existing or supersede?"

6. **Generate formal specs** — For each identified domain, create `SPEC-{CAT}-NNN-{slug}.md` using the template from `references/doc-spec.md` with full metadata:
   - `Status`: Draft
   - `Category`: matched CAT code
   - `NNN`: next available sequential number for that category (scan existing specs)
   - `Author`: inherited from design doc or `git config user.name`
   - `Supersedes` / `Superseded by`: linked if replacing existing specs (step 5)
   - `Source`: path to the design doc (Markdown-header metadata field; NOT indexed in `.doc-index.json`)
   - Content: extracted and formalized from the relevant design doc sections

7. **Populate `code_refs`** — For each spec, extract `code_refs` from the design doc's references to code paths (file paths, directory references, module names). If the design doc doesn't reference specific code paths, set `code_refs` to the project directories most likely affected by the spec's category based on project structure discovery. These initial `code_refs` are best-effort — they get refined during `spec-inject` (execute phase).

8. **Update indexes** — Call `doc-tools.sh update-index` for each new spec (including populated `code_refs`). Update `docs/specs/README.md` index table.

9. **Link back to design doc** — Append a `Generated Specs` section to the design doc listing all formal specs produced with their paths.

10. **Sync CLAUDE.md** — If any new files or directories were created (spec files, `docs/specs/` bootstrap, new category dirs), update CLAUDE.md to reflect the new paths and any new commands. See `references/doc-spec.md` for CLAUDE.md update rules. This ensures Claude sessions see the new spec infrastructure immediately.

11. **Sync README.md** — If any new actions or capabilities were documented in the generated specs, update README.md per `references/doc-spec.md` README.md update rules. This ensures the project's public documentation reflects the new spec infrastructure.

**Decomposition decision tree:**
- Does the design span multiple CAT domains? → Generate one spec per domain
- Does a domain have sub-concerns that benefit from separate tracking? → Split (e.g., AUTH-001 for OAuth flow, AUTH-002 for session management)
- Is the design doc small and focused? → Generate one spec, one category

**Output:**
- N formal spec files in `docs/specs/`
- Updated `.doc-index.json` entries
- Updated `docs/specs/README.md` index
- Modified design doc with `Generated Specs` section
- Updated CLAUDE.md and README.md (if new paths or capabilities were added)
- List of generated spec paths (for downstream consumption by wrapper skills)

---

### Action 2: `spec-inject`

**Trigger:** Two modes, invoked at different pipeline points.

#### Plan Phase

**Input:**
- `--phase=plan`
- `--plan=<path>` — Path to the implementation plan
- `--specs=<paths>` — Comma-separated paths to governing specs (output of `spec-generate`)

**Process:**

Read the plan document and identify chunk boundaries. Plan documents produced by `superpowers:writing-plans` use `## Chunk N: <name>` headings to delimit chunks (each chunk ≤1000 lines, containing a set of related tasks). Append spec maintenance steps to each chunk:

- **Per-chunk:** Add a spec update task at the end of each chunk — "Update SPEC-{CAT}-NNN status from Draft to In Review, verify implementation notes match what was built in this chunk, refine `code_refs` in `.doc-index.json` to reflect actual file paths created/modified"
- **Final chunk:** Add a spec finalization task — "Update all governing specs to Implemented status, fill in Implementation Notes sections with actual file paths and decisions made"

Injected tasks follow the same format as other plan tasks (checkbox syntax, file paths, clear acceptance criteria). They are appended to chunk ends, never restructuring the existing plan.

If the plan document does not follow the `## Chunk N:` convention, treat each `### Task N:` heading as a chunk boundary instead.

**Output:** Modified plan document with spec maintenance tasks injected.

#### Execute Phase

**Input:**
- `--phase=execute`
- `--specs=<paths>` — Paths to governing specs

**Process:**

Runs after each plan chunk completes (not after every individual task — that would be excessive and noisy).

1. Call `doc-tools.sh check-freshness` against the governing specs. This compares the spec's `content_hash` in `.doc-index.json` against the current `code_commit` for its `code_refs`.

2. If code changed but spec didn't (flagged stale), determine alignment vs. drift:

   **How to determine aligned vs. drifted:** The agent reads three inputs — (a) the spec's relevant section content, (b) the code changes in files matching the spec's `code_refs`, and (c) the plan task description that was just executed. It then answers: "Does the implementation achieve what the spec describes, even if through a different mechanism?" The key question is intent compliance, not literal matching.

   - **Aligned** (implementation achieves spec intent, possibly through different means than originally described): Update the spec's `Status` field, update the spec's Implementation Notes to reflect actual approach taken, call `doc-tools.sh update-index` to refresh hashes. Refine `code_refs` if actual file paths differ from initial estimates. No human intervention.
   - **Drifted** (implementation contradicts spec intent, omits spec requirements, or introduces unspecified behavior): Flag for human review with a deviation note: what the spec says, what the code does, and why they diverge. Do not auto-update spec content — that's a human decision about whether to update the spec or the code.

3. Status transitions: Draft → In Review → Implemented, driven by `check-freshness` results.

**Output:** Updated spec files (if aligned) or deviation flags (if drifted).

---

### Action 3: `spec-verify`

**Trigger:** Two modes at different pipeline points.

#### Post-Execute Mode

**Input:**
- `--mode=post-execute`
- `--specs=<paths>` — Paths to governing specs
- `--design-doc=<path>` — Path to original design doc (for coverage checks)

**Process:**

1. **Existence check** — Run `doc-tools.sh check-freshness` across all specs in scope. Governing specs should exist if `spec-generate` ran earlier. Missing specs are a finding.

2. **Staleness check** — Any specs still flagged stale after all tasks completed? Catches specs that `spec-inject` (execute phase) flagged for review but were never addressed.

3. **Status check** — Are all governing specs in `Implemented` status? Any still at `Draft` or `In Review` means implementation tasks were skipped or the plan didn't cover that spec's scope.

4. **Coverage check** — Five-way alignment across five artifact relationships:

   **Design doc → Specs:** Parse the design doc's major sections (identified by `##` headings that describe system behavior or architecture). For each section, check whether a governing spec exists whose `Source` field points to this design doc AND whose category and content correspond to that section's domain. Missing correspondence = "design intent without formal spec."

   **Specs → Code:** For each governing spec, check whether its `code_refs` directories/files exist and contain implementation. A spec with empty or nonexistent `code_refs` targets = "spec without implementation." A spec whose `code_refs` exist but whose `check-freshness` shows the spec was never updated past `Draft` = "spec with untouched implementation."

   **Code → Specs:** For files changed during this implementation (identified via `git diff` against the branch base), check whether each changed file falls within any governing spec's `code_refs`. Changed files with no governing spec = "unspecified implementation."

   **CLAUDE.md → Filesystem:** Check that CLAUDE.md sections (Directory Structure, Key Files, Commands) accurately reflect the current project state, including any new spec directories, generated docs, or changed paths from this implementation. Stale CLAUDE.md sections = "config file drift." This matters because CLAUDE.md is loaded at session start — stale entries mean future Claude sessions work with incorrect context.

   **README.md → Capabilities:** Check that README.md sections (feature list, action list, usage examples) accurately reflect the current project capabilities. Stale README.md sections = "public doc drift." This matters because README.md is the project's public documentation — outdated entries mislead users and contributors.

5. **PASS/FAIL criteria:**
   - **PASS:** All governing specs are in `Implemented` status AND no unresolved deviations AND no "design intent without formal spec" findings AND CLAUDE.md and README.md are current
   - **FAIL:** Any spec not in `Implemented` status, OR any unresolved deviation, OR any "design intent without formal spec" finding, OR CLAUDE.md/README.md staleness detected. **Recovery for CLAUDE.md/README.md staleness:** update per `references/doc-spec.md` update rules, then re-run `spec-verify`.

6. **Compliance report** — Use the format from `references/output-templates.md` (Spec Compliance Report section).

   If FAIL, the report is surfaced to the user before `finishing-a-development-branch` proceeds. The user decides whether to fix or accept.

**Output:** Structured compliance report including spec status, freshness, five-way alignment checks (Design→Specs, Specs→Code, Code→Specs, CLAUDE.md→Filesystem, README.md→Capabilities).

#### Review Mode

**Input:**
- `--mode=review`
- `--changed-files=<paths>` — Files changed in the PR/branch

**Process:**

1. **Map changed files to governing specs** — Using `.doc-index.json` `code_refs`, identify which specs are affected by the changed files.

2. **Run `check-freshness` on affected specs** — Are any stale relative to the changes?

3. **Coverage gap detection** — Are there changed files that have no governing spec at all? Flag as "unspecified changes."

4. **Produce review findings** — Standard doc-superpowers severity format:
   - **P1 Stale**: Spec exists but hasn't been updated to reflect code changes
   - **P2 Incomplete**: Changed files have no governing spec
   - **P3 Style**: Spec metadata inconsistencies

   Output is ready for synthesis into a review report by whatever wrapper or process invoked this action.

**Output:** Review findings in standard doc-superpowers severity format (see `references/spec-lifecycle-actions.md` for the full P1/P2/P3 mapping).

---

### Protocol Reference Doc

A new file `references/spec-lifecycle-protocol.md` serves as the wrapper author's guide. It contains:

**1. Lifecycle Overview** — The 5 interception points, the 3 actions, and a pipeline diagram.

**2. Action Reference** — For each action:
- Input contract (required parameters, expected context)
- Output contract (what the action returns)
- Prerequisites (what must exist before invoking)
- Error handling (what happens if prerequisites aren't met)

**3. Integration Patterns** — Generic invocation patterns for wiring into a wrapper skill:

```
Post-brainstorm:
  After design doc committed →
    invoke doc-superpowers spec-generate --design-doc=<path>

During plan:
  After writing-plans produces plan →
    invoke doc-superpowers spec-inject --phase=plan --plan=<path> --specs=<paths>

During execute:
  After each plan chunk completes →
    invoke doc-superpowers spec-inject --phase=execute --specs=<paths>

Pre-finish:
  After all tasks, before finishing →
    invoke doc-superpowers spec-verify --mode=post-execute --specs=<paths>

During review:
  Alongside other review participants →
    invoke doc-superpowers spec-verify --mode=review --changed-files=<paths>
```

**4. Standalone Usage** — All actions are user-invocable outside wrapper skills:
```
/doc-superpowers spec-generate --design-doc=docs/superpowers/specs/2026-03-14-feature-design.md
/doc-superpowers spec-verify --mode=post-execute --specs=docs/specs/SPEC-AUTH-001-oauth-flow.md
```

**5. Host Project Assumptions** — What doc-superpowers expects:
- `docs/specs/` directory (created by `init` or bootstrapped by `spec-generate`)
- `.doc-index.json` (created by `doc-tools.sh build-index` or bootstrapped)
- Spec template available in `references/doc-spec.md`

If these don't exist, `spec-generate` bootstraps them.

---

### Changes to Existing doc-superpowers

| File | Change | Scope |
|------|--------|-------|
| `SKILL.md` | Add 3 new actions to routing table | Action definitions, trigger patterns, agent prompts |
| `references/doc-spec.md` | Add `Source` metadata field to spec template | One line: `**Source**: {path to design doc or "manual"}` |
| `references/spec-lifecycle-protocol.md` | **New file** — wrapper author's guide | Protocol contract, integration patterns, standalone usage |
| `README.md` | Add 3 new commands to command list | Documentation |
| `CLAUDE.md` | Add commands and key file entry | Documentation |

**No changes to:**
- `scripts/doc-tools.sh` — no new subcommands
- `.doc-index.json` schema — no new fields
- Existing 7 actions (init, audit, review-pr, update, diagram, sync, hooks)
- Spec naming conventions (`SPEC-{CAT}-NNN-{slug}.md`)
- Directory structure (`docs/specs/`)
- Existing templates (only one field added)

---

## Open Questions

None — all questions were resolved during brainstorming:
- Drift detection uses existing `doc-tools.sh check-freshness` (not a new mechanism)
- doc-superpowers has zero awareness of wrapper skills (context-agnostic primitives)
- Review mode produces standard findings format, wrapper handles synthesis
- Design docs remain the narrative source; formal specs are the tracked derivative
