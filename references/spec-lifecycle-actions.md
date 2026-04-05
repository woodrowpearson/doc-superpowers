# Spec Lifecycle Actions — Detailed Procedures

Read this file when executing `spec-generate`, `spec-inject`, or `spec-verify`. For routing logic (which action to use when), see the Spec Lifecycle Routing diagram in SKILL.md. For wrapper skill integration patterns, see `spec-lifecycle-protocol.md`.

---

## `spec-generate` — Generate Formal Specs from Design Doc

Use after brainstorming produces a design spec. Decomposes a narrative design document into formal `SPEC-{CAT}-NNN-{slug}.md` files with full metadata, indexing, and freshness tracking.

**Input:** `--design-doc=<path>` — Path to the narrative design spec.

1. **Run discovery** (if not already run in this session).
2. **Bootstrap if needed**: If `docs/specs/` doesn't exist, create it with `template.md` and `README.md` from `references/doc-spec.md`. If `.doc-index.json` doesn't exist, run `doc-tools.sh build-index`.
3. **Parse the design doc** — Read the narrative design spec and identify distinct specification domains using the 9 CAT codes (ARCH, AUTH, DATA, API, UI, PIPE, OPS, INFRA, TEST) as a classification lens.
4. **Check for idempotency** — If the design doc already has a `## Generated Specs` section, read it to identify previously generated specs. Only generate specs for newly identified domains not already listed.
5. **Check for overlapping existing specs** — For each identified domain, scan `docs/specs/` for existing specs in that category:
   - If the design doc **replaces** the existing spec's scope entirely → Create the new spec with `Supersedes: <path-to-old>`, update the old spec's `Superseded by` field, move the old spec to `docs/archive/specs/`, and update the archived spec's `.doc-index.json` entry to `status: "deprecated"`.
   - If the design doc **extends** existing scope → Create a new spec with the next sequential number (e.g., AUTH-002 if AUTH-001 exists), no supersession.
   - If the design doc covers the **same scope with the same intent** → Do not create a duplicate. Flag for human review: "Existing SPEC-{CAT}-NNN already covers this scope. Update existing or supersede?"
5b. **Stale content scan for overlapping specs** — For specs identified as "extends" or "overlaps" in Step 5 (i.e., NOT superseded/archived, but still active):
   1. **Extract removal keywords** from the design doc — scan for section headings containing "Delete", "Remove", "Drop", "Deprecate", "Replace", and collect the component/feature names listed for removal or replacement.
   2. **Grep each overlapping spec** for those keywords. Count matches per spec.
   3. **Classify severity:**
      - **HIGH** (>5 matches): Spec has significant stale content describing removed architecture. Recommend immediate deprecation notices.
      - **MEDIUM** (1–5 matches): Spec has some stale references. Note in "Specs Requiring Updates" table.
   4. **Report findings** — Output a table:
      ```
      | Spec | Stale Refs | Severity | Key Terms |
      |------|-----------|----------|-----------|
      | SPEC-PIPE-007 | 34 | HIGH | sweep mode, EdgeTAM |
      ```
   5. **Offer deprecation notices** — "N specs have stale content (M total references). Apply deprecation notices now?"
      - **If yes:** For each stale section in affected specs, prepend a blockquote deprecation notice:
        ```markdown
        > **Deprecated (YYYY-MM-DD):** This section references {removed feature} which has been superseded by {new approach}. See [SPEC-{NEW}]({path}) for current architecture.
        ```
        Then call `doc-tools.sh update-index` for each modified spec.
      - **If no:** Defer to `spec-inject` execute phase (current behavior). The "Specs Requiring Updates" table from Step 9 will still list them.
   6. **Include stale reference count in design doc table** — When writing the "Specs Requiring Updates" table (appended in Step 9), add a `Stale Refs` column so severity is visible to downstream consumers.
6. **Generate formal specs** — For each identified domain, create `SPEC-{CAT}-NNN-{slug}.md` using the template from `references/doc-spec.md`:
   - `Status`: Draft
   - `Category`: matched CAT code
   - `NNN`: next available sequential number for that category
   - `Author`: inherited from design doc or `git config user.name`
   - `Supersedes` / `Superseded by`: linked if replacing existing specs (step 5)
   - `Source`: path to the design doc (Markdown-header only, NOT indexed in `.doc-index.json`)
   - Content: extracted and formalized from the relevant design doc sections
7. **Populate `code_refs`** — For each spec, extract `code_refs` from the design doc's references to code paths (file paths, directory references, module names). If the design doc doesn't reference specific code paths, set `code_refs` to the project directories most likely affected by the spec's category based on project structure discovery. These initial `code_refs` are best-effort — they get refined during `spec-inject` (execute phase).
8. **Update indexes** — Call `doc-tools.sh update-index` for each new spec (including populated `code_refs`). Update `docs/specs/README.md` index table.
9. **Link back to design doc** — Append a `## Generated Specs` section to the design doc listing all formal specs produced:
   ```markdown
   ## Generated Specs

   | Spec | Category | Path |
   |------|----------|------|
   | SPEC-AUTH-001-oauth-flow | AUTH | docs/specs/SPEC-AUTH-001-oauth-flow.md |
   ```
   If Step 5b identified specs with stale content, also append a `## Specs Requiring Updates` section:
   ```markdown
   ## Specs Requiring Updates

   | Spec | Stale Refs | Severity | Status |
   |------|-----------|----------|--------|
   | SPEC-PIPE-007 | 34 | HIGH | Deprecation notices applied |
   | SPEC-UI-001 | 12 | HIGH | Deferred to spec-inject |
   | SPEC-PIPE-005 | 3 | MEDIUM | Deferred to spec-inject |
   ```
   The `Status` column reflects whether deprecation notices were applied (Step 5b.5) or deferred.
10. **Sync CLAUDE.md** — If any new files or directories were created (spec files, `docs/specs/` bootstrap, new category dirs), update CLAUDE.md to reflect the new paths and any new commands. **SEE** `references/doc-spec.md` for CLAUDE.md update rules. This ensures Claude sessions see the new spec infrastructure immediately.
11. **Sync README.md** — If any new actions or capabilities were documented in the generated specs, update README.md per `references/doc-spec.md` README.md update rules. This ensures the project's public documentation reflects the new spec infrastructure.
12. **Output**: Report list of generated spec paths. These paths are the `--specs` input for downstream `spec-inject` and `spec-verify` actions.

**Decomposition decision tree:**
- Does the design span multiple CAT domains? → Generate one spec per domain
- Does a domain have sub-concerns that benefit from separate tracking? → Split (e.g., AUTH-001 for OAuth flow, AUTH-002 for session management)
- Is the design doc small and focused? → Generate one spec, one category

---

## `spec-inject` — Inject Spec Maintenance into Plans and Track During Execution

Two modes: **plan phase** (inject spec tasks into implementation plan) and **execute phase** (detect drift and update spec status after each chunk).

### Plan Phase

**Input:**
- `--phase=plan`
- `--plan=<path>` — Path to the implementation plan
- `--specs=<paths>` — Comma-separated paths to governing specs (output of `spec-generate`)

1. **Read the plan document** and identify chunk boundaries. Plans produced by `superpowers:writing-plans` use `## Chunk N: <name>` headings (each chunk ≤1000 lines). If the plan doesn't use that convention, treat each `### Task N:` heading as a chunk boundary instead.
2. **Per-chunk injection** — Append a spec update task at the end of each chunk:
   ```markdown
   ### Task N+1: Update governing specs for this chunk

   **Files:**
   - Modify: {paths to governing specs relevant to this chunk}

   - [ ] **Step 1: Update spec status**
   Update SPEC-{CAT}-NNN `Status` from `Draft` to `In Review`.
   - [ ] **Step 2: Verify implementation notes**
   Check that the spec's Implementation Notes section matches what was built in this chunk. Add notes for actual file paths created/modified.
   - [ ] **Step 3: Refine code_refs**
   Update the spec's `code_refs` in `.doc-index.json` to reflect actual file paths created/modified (replacing best-effort estimates from `spec-generate`).
   - [ ] **Step 4: Update index**
   Run `doc-tools.sh update-index <spec-path>` to refresh content hash.
   ```
3. **Final chunk injection** — In the last chunk, also add a spec finalization task:
   ```markdown
   ### Task N+2: Finalize all governing specs

   **Files:**
   - Modify: {all governing spec paths}

   - [ ] **Step 1: Set all specs to Implemented**
   Update every governing spec's `Status` to `Implemented`.
   - [ ] **Step 2: Fill Implementation Notes**
   For each spec, ensure the Implementation Notes section has actual file paths, decisions made, and any deviations from the original design.
   - [ ] **Step 3: Final index update**
   Run `doc-tools.sh update-index` for all governing specs.
   ```
4. **Output**: Modified plan document with spec maintenance tasks injected. Tasks follow the same checkbox syntax as other plan tasks.

### Execute Phase

**Input:**
- `--phase=execute`
- `--specs=<paths>` — Paths to governing specs

Runs after each plan chunk completes (not after every individual task).

1. **Check freshness** — Call `doc-tools.sh check-freshness` against the governing specs. This compares the spec's `content_hash` in `.doc-index.json` against the current `code_commit` for its `code_refs`.
2. **Determine alignment vs. drift** — If code changed but spec wasn't updated (flagged stale), the agent reads three inputs: (a) the spec's relevant section content, (b) the code changes in files matching the spec's `code_refs`, (c) the plan task description that was just executed. The key question: "Does the implementation achieve what the spec describes, even if through a different mechanism?"
   - **Aligned** (implementation achieves spec intent): Update the spec's `Status` field. Update the spec's Implementation Notes to reflect actual approach taken. Refine `code_refs` if actual file paths differ from initial estimates. Call `doc-tools.sh update-index` to refresh hashes. No human intervention.
   - **Drifted** (implementation contradicts spec intent, omits requirements, or introduces unspecified behavior): Flag for human review with a deviation note: what the spec says, what the code does, and why they diverge. Do not auto-update spec content.
3. **Status transitions**: Draft → In Review (first implementation) → Implemented (verification passes).
4. **Output**: Updated spec files (if aligned) or deviation flags (if drifted).

---

## `spec-verify` — Verify Spec Compliance Post-Execution and During Review

Two modes: **post-execute** (final compliance check before merging) and **review** (spec findings for code review).

### Post-Execute Mode

**Input:**
- `--mode=post-execute`
- `--specs=<paths>` — Paths to governing specs
- `--design-doc=<path>` — Path to original design doc (for three-way check)

1. **Existence check** — Run `doc-tools.sh check-freshness` across all specs in scope. If governing specs don't exist, that's a finding.
2. **Staleness check** — Are any specs still flagged stale after all tasks completed? This catches specs that `spec-inject` (execute phase) flagged for review but were never addressed.
3. **Status check** — Are all governing specs in `Implemented` status? Any still at `Draft` or `In Review` means implementation tasks were skipped or the plan didn't cover that spec's scope.
4. **Coverage check** — Five-way alignment across five artifact relationships:

   **Design doc → Specs:** Parse the design doc's major sections (identified by `##` headings that describe system behavior or architecture). For each section, check whether a governing spec exists whose `Source` field points to this design doc AND whose category and content correspond to that section's domain. Missing correspondence = "design intent without formal spec."

   **Specs → Code:** For each governing spec, check whether its `code_refs` directories/files exist and contain implementation. A spec with empty or nonexistent `code_refs` targets = "spec without implementation." A spec whose `code_refs` exist but whose status is still `Draft` = "spec with untouched implementation."

   **Code → Specs:** For files changed during this implementation (identified via `git diff` against the branch base), check whether each changed file falls within any governing spec's `code_refs`. Changed files with no governing spec = "unspecified implementation."

   **CLAUDE.md → Filesystem:** Check that CLAUDE.md sections (Directory Structure, Key Files, Commands) accurately reflect the current project state, including any new spec directories, generated docs, or changed paths from this implementation. Stale CLAUDE.md sections = "config file drift." This matters because CLAUDE.md is loaded at session start — stale entries mean future Claude sessions work with incorrect context.

   **README.md → Capabilities:** Check that README.md sections (feature list, action list, usage examples) accurately reflect the current project capabilities. Stale README.md sections = "public doc drift." This matters because README.md is the project's public documentation — outdated entries mislead users and contributors.

5. **PASS/FAIL verdict:**
   - **PASS:** All governing specs in `Implemented` status AND no unresolved deviations AND no "design intent without formal spec" findings AND CLAUDE.md and README.md are current
   - **FAIL:** Any spec not in `Implemented` status, OR any unresolved deviation, OR any "design intent without formal spec" finding, OR CLAUDE.md/README.md staleness detected

   **Recovery:** update per `references/doc-spec.md` CLAUDE.md / README.md update rules, then re-run `spec-verify`.

6. **Compliance report** — Use the format from `references/output-templates.md` (Spec Compliance Report section).

   If FAIL, the report is surfaced to the user before `finishing-a-development-branch` proceeds. The user decides whether to fix or accept.

### Review Mode

**Input:**
- `--mode=review`
- `--changed-files=<paths>` — Files changed in the PR/branch

1. **Map changed files to governing specs** — Using `.doc-index.json` `code_refs`, identify which specs are affected by the changed files.
2. **Run `check-freshness` on affected specs** — Are any stale relative to the changes?
3. **Coverage gap detection** — Are there changed files that have no governing spec at all? Flag as "unspecified changes."
4. **Produce review findings** — Standard doc-superpowers severity format:
   - **P1 Stale**: Spec exists but hasn't been updated to reflect code changes
   - **P2 Incomplete**: Changed files have no governing spec
   - **P3 Style**: Spec metadata inconsistencies

   Output is ready for synthesis into a review report by whatever wrapper or process invoked this action.
