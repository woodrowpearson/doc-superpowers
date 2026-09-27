# Spec Lifecycle Actions — Detailed Procedures

Read this file when executing `spec-generate`, `spec-inject`, or `spec-verify`. For routing logic (which action to use when), see the Spec Lifecycle Routing diagram in SKILL.md. For wrapper skill integration patterns, see `spec-lifecycle-protocol.md`.

---

## Spec Status Model — Canonical Transition Rules

**Every action in this file MUST follow this model. Do not restate these rules elsewhere — cite this section.**

### Vocabulary

| Class | Statuses | Automation behaviour |
|---|---|---|
| **Ladder** | `Draft` → `In Review` → `Approved` → `Implemented` | Participate in automated transitions |
| **Exempt** | `Active`, `Deprecated`, `Superseded`, **and any status not listed in the ladder** | Never transitioned by any action |

The exempt class is open-world. A spec carrying an unrecognized status is exempt — leave it alone. Do not treat it as a data-entry error to be corrected, and do not extend automation by enumerating exempt values.

Match statuses case-insensitively and with surrounding whitespace trimmed, so `implemented` and `` `In Review` `` with a trailing space resolve to their ladder values rather than falling into the exempt class. A value that still does not match a ladder status after that normalization is genuinely exempt — and is reported by `spec-verify`'s unrecognized-status line, not silently corrected.

### Rules

- **R1 — Read before write.** Parse the spec's current `Status` before assigning any value. Never write `Status` without having read it first.
- **R2 — Monotonic.** Transitions move forward along the ladder only. Never write a status earlier in the ladder than the current value. A regression is always a defect, never an intended outcome.
- **R3 — Open-world exemption.** If the current `Status` is not a ladder value, make no transition, add no Implementation Notes, and make no `code_refs` write. Leave the spec untouched.
- **R4 — Scope-gated advancement.** Advance a spec to `Implemented` only when this work implemented the spec's surface **and** that surface is fully covered.

`Approved` needs no special-casing: it sits past `In Review` on the ladder, so R2 alone prevents a `Draft → In Review` step from regressing it.

### Spec roles — implementation target, constraint reference, amendment

A path passed via `--specs` is one of:

- **target** — the work is expected to implement this spec's surface and advance its status.
- **constraint** — the work must respect this spec (e.g. a field allowlist it must not violate) but must **not** advance it.
- **amendment** — the work is expected to correct **what this spec says** while building none of its surface. The spec moves toward reality, or toward a new ruling: its claims about behaviour, presentation, or contract change, and its status does not.

Resolution, in precedence order:

1. **Explicit marker.** `--specs=<path>:target` or `--specs=<path>:constraint`, or `--specs=<path>:amends`. An explicit marker always wins. The suffix is optional — unsuffixed paths remain valid.
   ```
   --specs=docs/specs/SPEC-UI-010-collection-view.md:target,docs/specs/SPEC-API-006-backend.md:constraint,docs/specs/SPEC-UI-041-recents.md:amends
   ```
2. **Inferred.** For an unsuffixed path, intersect the work's changed files (`git diff` against the branch base) with the spec's `code_refs` in `.doc-index.json`. Non-empty intersection → **target**. Empty intersection → **constraint**. Inference never yields **amendment**: an amendment is a claim about what the work promised to write *in the spec*, which no diff of the code can express. The role exists only when the caller declares it.

A spec resolved as **constraint** is never written: no `Status` change, no Implementation Notes, no `code_refs` refinement, no `update-index` call.

A spec resolved as **amendment** is **status-neutral by construction**: an amendment neither completes nor reopens a spec, so R2 and R3 hold exactly as they do for a constraint — no `Status` change, no Implementation Notes, no `code_refs` refinement. Unlike a constraint it *is* written, in one specific way. The correction is recorded inline in the section it corrects, as a dated block that cites the plan that made it:

```markdown
> ⚠️ **AMENDED YYYY-MM-DD — <what changed>.** <what the section used to assert, what is
> true now, and why>. Landed by `<plan path>` Task <N>.
```

`update-index <spec-path>` runs after the edit, because the spec's bytes changed even though its `Status` did not. Whole-doc supersession is a different operation and is unaffected: `Supersedes:` / `Superseded by:` replaces a document, an AMENDED block corrects a passage. Reach for one where the other belongs and the spec's history stops being readable.

**Boundary.** *A co-move of a value or line inside a spec the plan `implements` or `constrains` is not an amendment; `amends` is for a spec whose stated behaviour the plan changes and whose surface the plan does not build.* The sentence is phrased in the role names a wrapper's plan frontmatter may use — where such a wrapper maps `implements` onto **target** and `constrains` onto **constraint** — so that its contract and this one can carry one byte-identical boundary test.

**Timing.** Role inference needs the changed-file set, which does not exist during `spec-inject --phase=plan` — nothing is implemented yet at plan-authoring time. So at injection time the explicit marker is the only role signal available, and injected tasks are written as instructions the executing agent evaluates against `git diff` **at execution time**. `spec-inject --phase=plan` never bakes a role decision into the plan text. At per-chunk execution the changed-file set reflects only the chunks run so far, so a spec whose surface lands in a later chunk infers as **constraint** in earlier ones and is skipped; this self-corrects at finalize, when the full range is visible, but it does make the inferred-constraints report noisier mid-plan. An **amendment** has no such timing problem: it is explicit-only, so its marker is available at injection time and is never re-resolved against a diff later.

### Coverage completeness

For a **target** spec, classify how much of its surface this work implemented:

- **Full** — the whole surface is implemented → eligible for `Implemented`, subject to R2.
- **Partial** — the spec has surfaces this work deliberately deferred → hold at `In Review` and record the remaining scope in Implementation Notes. Subject to R2: "hold at `In Review`" means *do not advance to `Implemented`* — never write `In Review` over a later status. A partially-covered spec already at `Approved` or `Implemented` stays exactly where it is.

Coverage is a **target**-only classification. Constraints and amendments have no surface this work was expected to implement, so they are never classified as full or partial and never appear in a coverage verdict.

### Evaluation order

Check in this order; the first rule that blocks a write wins:

1. **Role** — resolved as constraint → stop, write nothing. Resolved as amendment → stop as well: write no `Status`, no Implementation Notes, no `code_refs`. (An amendment's inline block is written by the plan task that performs it, never by the status machinery here; what this file owns for an amendment is checking that the block landed.)
2. **R3** — current status is exempt → stop, write nothing.
3. **R4** — scope and coverage determine the target status.
4. **R2** — target status is earlier on the ladder than the current status → stop, write nothing.
5. Write.

A constraint spec at `Draft` is left alone by step 1; an amendment spec at `Implemented` is left alone by the same step, whatever its status; a target spec at `Active` is left alone by step 2. None of them reaches R4.

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
- `--specs=<paths>` — Comma-separated paths to governing specs (output of `spec-generate`). Each path may carry an optional role suffix — `<path>:target` or `<path>:constraint`, or `<path>:amends` — declaring whether the work is expected to advance that spec, leave it untouched, or correct what it says. Unsuffixed paths are resolved by inference at execution time; inference never yields **amendment**. See **Spec Status Model → Spec roles**.

1. **Read the plan document** and identify chunk boundaries. Plans produced by `superpowers:writing-plans` use `## Chunk N: <name>` headings (each chunk ≤1000 lines). If the plan doesn't use that convention, treat each `### Task N:` heading as a chunk boundary instead.
2. **Per-chunk injection** — Append a spec update task at the end of each chunk:
   ```markdown
   ### Task N+1: Update governing specs for this chunk

   **Files:**
   - Modify: {paths to governing specs relevant to this chunk}

   - [ ] **Step 1: Update spec status (guarded)**
   Read SPEC-{CAT}-NNN's current `Status` first, then apply the **Spec Status Model**:
     - Resolved as **constraint** for this work (resolve role per **Spec Status Model → Spec roles**) → leave untouched, and skip Steps 2–4 as well.
     - Resolved as **amendment** (marked `:amends`) → leave `Status`, Implementation Notes and `code_refs` untouched, and skip Steps 2–4 as well, exactly like a constraint. `Task N+1a` owns an amendment spec end to end, including the single `update-index` its changed bytes need; running Step 4 here too would refresh the same edit twice.
     - `Draft` → set `In Review`.
     - `In Review` / `Approved` / `Implemented` → leave unchanged (R2 — never regress).
     - Any other status (`Active`, `Deprecated`, `Superseded`, …) → leave unchanged (R3).
   - [ ] **Step 2: Verify implementation notes**
   Check that the spec's Implementation Notes section matches what was built in this chunk. Add notes for actual file paths created/modified.
   - [ ] **Step 3: Refine code_refs**
   Update the spec's `code_refs` in `.doc-index.json` to reflect actual file paths created/modified (replacing best-effort estimates from `spec-generate`).
   - [ ] **Step 4: Update index**
   Run `doc-tools.sh update-index <spec-path>` to refresh content hash.
   ```
3. **Amendment task injection** — Append ONE further task **per `:amends` spec per chunk**, after that chunk's spec update task. Two amendment specs in one chunk therefore yield two tasks, kept distinguishable by the spec path in the title. The injector resolves every placeholder below at inject time and writes the resolved values into the emitted task, so the executing agent is never left to look one up:
   - `{spec-path}` — the spec this task covers.
   - `{plan-path}` — this invocation's `--plan=` argument, so the check is about *this* plan.
   - `{status}` — the spec's current `**Status:**`, read now. This is the plan-time value the finalize task later compares against, and the emitted task is the only place it is recorded; nothing else captures it.
   - `{N}` — the number of the plan task whose body quotes the `⚠️ **AMENDED` block for `{spec-path}`. Find it by scanning the plan for that block at inject time.
   ````markdown
   ### Task N+1a: Land the spec amendment for {spec-path}

   **Files:**
   - Modify: {spec-path}

   Status at plan time: {status}

   - [ ] **Step 1: Read what was promised**
   Open the plan task whose body quotes the `⚠️ **AMENDED` block for {spec-path}: Task {N}. Read it alongside the amended section of {spec-path}. The amendment text that task quotes is the acceptance criterion — nothing else is.
   - [ ] **Step 2: Verify the block is present and cites this plan**
   ```bash
   grep -n -A4 'AMENDED 20' {spec-path} | grep -F '{plan-path}'
   ```
   PASS iff a dated `AMENDED` block exists in the named section **and** the block cites this plan. Both halves are load-bearing: a bare `grep 'AMENDED 20'` passes vacuously on any spec some earlier work amended, so the citation filter is what makes the check about this plan rather than about the file's history. No match → **FAIL**; the amendment did not land.
   - [ ] **Step 3: Update index**
   Run `doc-tools.sh update-index {spec-path}` — the spec's bytes changed even though its `Status` did not. This task is the single owner of that call: `Task N+1` skips Steps 2–4 for an amendment spec precisely so the index is refreshed exactly once.
   - [ ] **Step 4: Write nothing else**
   No `Status` write, no Implementation Notes entry, no `code_refs` refinement (**Spec Status Model → Spec roles**). The amendment is the record.
   ````
4. **Final chunk injection** — In the last chunk, also add a spec finalization task:
   ```markdown
   ### Task N+2: Finalize all governing specs

   **Files:**
   - Modify: {all governing spec paths}

   - [ ] **Step 1: Advance implemented specs (scope-gated)**
   For each governing spec, resolve its role, then apply the **Spec Status Model**. Resolve role from the caller's explicit `:target` / `:constraint` marker if present; otherwise intersect this plan's changed files (`git diff` against the branch base) with the spec's `code_refs`.
     - **constraint** (marked `:constraint`, or no intersection with `code_refs`) → leave `Status` unchanged and add no Implementation Notes. It was passed as a read-only reference, not an implementation target.
     - **amendment** (marked `:amends`) → leave `Status` unchanged and add no Implementation Notes. Assert two things instead: the dated `AMENDED` block is present and cites this plan (`grep -n -A4 'AMENDED 20' <spec-path> | grep -F '<plan-path>'`), and `Status` still equals the `Status at plan time:` value recorded in that spec's `Task N+1a` (the plan-phase injector captured it; do not re-derive it here — a value read now would agree with itself no matter what moved). No match, or a status that has left that value, is a **FAIL** — the plan promised a correction and the spec does not carry it.
     - **target** at an exempt status (`Active`, `Deprecated`, `Superseded`, …) → leave unchanged (R3). `Active` reference specs sit outside the ladder and never transition.
     - **target**, fully covered by this plan → set `Implemented`.
     - **target**, partially covered (the spec has surfaces this plan deferred) → do **not** advance to `Implemented`. Never write a status earlier than the current value (R2): if the spec is at `Draft` or `In Review`, hold it at `In Review`; if it is already at `Approved` or `Implemented`, leave it exactly as it is. Record the remaining scope in Implementation Notes either way.
   - [ ] **Step 2: Fill Implementation Notes**
   For each spec Step 1 advanced or left at `In Review`, ensure the Implementation Notes section has actual file paths, decisions made, and any deviations from the original design. Skip specs Step 1 left untouched.
   - [ ] **Step 3: Final index update**
   Run `doc-tools.sh update-index` for each spec modified in Steps 1–2. Do not re-index untouched specs.
   ```
5. **Output**: Modified plan document with spec maintenance tasks injected. Tasks follow the same checkbox syntax as other plan tasks.

### Execute Phase

**Input:**
- `--phase=execute`
- `--specs=<paths>` — Paths to governing specs, each with an optional `:target` / `:constraint` / `:amends` role suffix
- `--plan=<path>` — Optional. The plan being executed. Supplied, it lets the amendment branch below verify that an `AMENDED` block cites *this* plan; omitted, that branch degrades as described there.

Runs after each plan chunk completes (not after every individual task).

1. **Check freshness** — Call `doc-tools.sh check-freshness` against the governing specs. This compares the spec's `content_hash` in `.doc-index.json` against the current `code_commit` for its `code_refs`.
2. **Determine alignment vs. drift** — If code changed but spec wasn't updated (flagged stale), the agent reads three inputs: (a) the spec's relevant section content, (b) the code changes in files matching the spec's `code_refs`, (c) the plan task description that was just executed. The key question: "Does the implementation achieve what the spec describes, even if through a different mechanism?"
   - **Aligned** (implementation achieves spec intent): Update the spec's `Status` per the **Spec Status Model** — read the current status first, never regress, and leave exempt statuses and constraint specs untouched. Update the spec's Implementation Notes to reflect actual approach taken. Refine `code_refs` if actual file paths differ from initial estimates. Call `doc-tools.sh update-index` to refresh hashes. No human intervention.
   - **Drifted** (implementation contradicts spec intent, omits requirements, or introduces unspecified behavior): Flag for human review with a deviation note: what the spec says, what the code does, and why they diverge. Do not auto-update spec content.
   - **Amendment** (`:amends`): this branch is not about code at all, so neither alignment nor drift applies — the spec's *text* was supposed to change, and a staleness flag on it is the expected outcome rather than a finding. Write no `Status`, no Implementation Notes, no `code_refs`. Verify instead that the dated `AMENDED` block landed and cites the plan (`grep -n -A4 'AMENDED 20' <spec-path> | grep -F '<plan-path>'`; with no `--plan` the citation half cannot be checked — report block-present and emit `WARN: amendment citation unverified (no --plan)`). Then call `doc-tools.sh update-index` to refresh the hash.
3. **Status transitions**: governed by the **Spec Status Model** — `Draft` → `In Review` (first implementation) → `Approved` → `Implemented` (verification passes). Monotonic (R2); exempt statuses, constraint specs and amendment specs never transition (R3, roles). Never write `Status` without reading the current value first (R1). `Approved` is human-set — no action ever writes it; it appears on the ladder so R2 can protect specs that carry it.
4. **Output**: Updated spec files (if aligned) or deviation flags (if drifted).

---

## `spec-verify` — Verify Spec Compliance Post-Execution and During Review

Two modes: **post-execute** (final compliance check before merging) and **review** (spec findings for code review).

### Post-Execute Mode

**Input:**
- `--mode=post-execute`
- `--specs=<paths>` — Paths to governing specs, each with an optional `:target` / `:constraint` / `:amends` role suffix
- `--design-doc=<path>` — Path to original design doc (for the five-way coverage check)
- `--plan=<path>` — Optional. The plan whose amendments are being verified. Required for a **full** amendment check: without it the landed-check cannot tell an `AMENDED` block this plan wrote from one some earlier work left behind. See the **amendment** bullet in the Status check.

1. **Existence check** — Run `doc-tools.sh check-freshness` across all specs in scope. If governing specs don't exist, that's a finding.
2. **Staleness check** — Are any specs still flagged stale after all tasks completed? This catches specs that `spec-inject` (execute phase) flagged for review but were never addressed.
3. **Status check** — For each governing spec, resolve its role and status class per the **Spec Status Model**, then check only what applies:
   - **target** at a ladder status → expect `Implemented`. Still at `Draft`, `In Review`, or `Approved` means implementation tasks were skipped or the plan didn't cover that spec's scope — report which of the two it is.
   - **target** held at `In Review` with the remaining scope recorded in Implementation Notes → **not a finding**. This is the Spec Status Model's sanctioned outcome for a partially-covered target (see **Coverage completeness**), not a skipped task. Report it as informational. Absent that recorded scope it falls under the branch above — the Implementation Notes are what distinguish a deliberate hold from a skipped task.
   - **target** at an exempt status (`Active`, `Deprecated`, `Superseded`, …) → **not a finding**. `Active` reference specs are continuously evolving and never reach `Implemented` by design.
   - **constraint** → **not a finding** at any status. The work was never expected to advance it.
   - **amendment** → status is **not a finding** at any value, for the same reason: the work was never expected to advance it. What *is* checked is a different question — *does the spec now say what the plan said it would say* — and it is a landed-check, never a code-vs-spec or status comparison:
     ```bash
     grep -n -A4 'AMENDED 20' <spec-path> | grep -F '<plan-path>'
     ```
     A match is a PASS. No match is a **FAIL**: the plan promised a correction the spec does not carry. Both stages matter — the first finds a dated block, the second proves it belongs to this plan; a bare `grep 'AMENDED 20'` passes on any previously-amended spec and so verifies nothing about this work.
     **Without `--plan`** the second stage cannot run. Degrade to block-present only and emit exactly this line, verbatim: `WARN: amendment citation unverified (no --plan)`. Never report a degraded check as a full pass — the whole point of the role is that a promised amendment is provable, and an unproven one must say so.

   Then emit three **P3 informational** lines. These are never findings and never cause a FAIL — they exist because the suppressions above are otherwise silent in the failing direction:
   - **Inferred constraints** — list specs treated as constraint references *by inference* rather than by an explicit `:constraint` marker: "N spec(s) treated as constraint references by inference — pass `:constraint` to confirm, or fix their `code_refs` if they were meant to be implementation targets." Role inference is circular: wrong `code_refs` produce a constraint verdict, the constraint branch skips the `code_refs` refinement step, so the `code_refs` stay wrong and the spec silently never advances. Specs marked `:constraint` explicitly are not listed — the caller already said so.
   - **Unrecognized statuses** — list specs at an unrecognized status, i.e. one outside the documented vocabulary (a typo such as `Implemenetd`, or a value from a downstream vocabulary): "N spec(s) at an unrecognized status — automation will never transition these." R3 correctly declines to write them; reporting them is what keeps them from being invisible forever.
   - **Amendments verified** — list `:amends` specs whose block was found and attributed: "N amendment(s) verified as landed." A degraded check (no `--plan`) is listed here with its WARN, not counted as verified.
   - **Held at `In Review`** — list partially-covered targets held by design: "N spec(s) held at `In Review` by design — remaining scope recorded in Implementation Notes." Without this line a deliberate hold is indistinguishable from a skipped task in the report, which is the ambiguity the recorded scope exists to resolve.
4. **Coverage check** — Five-way alignment across five artifact relationships:

   **Design doc → Specs:** Parse the design doc's major sections (identified by `##` headings that describe system behavior or architecture). For each section, check whether a governing spec exists whose `Source` field points to this design doc AND whose category and content correspond to that section's domain. Missing correspondence = "design intent without formal spec."

   **Specs → Code:** For each governing spec, check whether its `code_refs` directories/files exist and contain implementation. A spec with empty or nonexistent `code_refs` targets = "spec without implementation." A **target** spec whose `code_refs` exist but whose status is still `Draft` = "spec with untouched implementation." Constraint references and specs at exempt statuses are excluded — by design they hold populated `code_refs` and are never advanced, so an unadvanced status is not evidence of untouched implementation (see **Spec Status Model**). Amendment specs are excluded for a stronger reason: this work built none of their surface by definition, so "spec without implementation" and "spec with untouched implementation" are both meaningless verdicts for them.

   **Code → Specs:** For files changed during this implementation (identified via `git diff` against the branch base), check whether each changed file falls within any governing spec's `code_refs`. Changed files with no governing spec = "unspecified implementation."

   **CLAUDE.md → Filesystem:** Check that CLAUDE.md sections (Directory Structure, Key Files, Commands) accurately reflect the current project state, including any new spec directories, generated docs, or changed paths from this implementation. Stale CLAUDE.md sections = "config file drift." This matters because CLAUDE.md is loaded at session start — stale entries mean future Claude sessions work with incorrect context.

   **README.md → Capabilities:** Check that README.md sections (feature list, action list, usage examples) accurately reflect the current project capabilities. Stale README.md sections = "public doc drift." This matters because README.md is the project's public documentation — outdated entries mislead users and contributors.

5. **PASS/FAIL verdict:**
   - **PASS:** Every spec required to be `Implemented` by the Status check (step 3) is `Implemented` AND every `:amends` spec's amendment landed and is attributed to this plan AND no unresolved deviations AND no "design intent without formal spec" findings AND CLAUDE.md and README.md are current
   - **FAIL:** Any spec required to be `Implemented` by the Status check (step 3) is not, OR any `:amends` spec whose `AMENDED` block is absent or not attributed to this plan, OR any unresolved deviation, OR any "design intent without formal spec" finding, OR CLAUDE.md/README.md staleness detected

   Specs the Status check exempts — constraint references, targets held at `In Review` with recorded remaining scope, and specs at `Active` / `Deprecated` / `Superseded` / any other non-ladder status — never contribute to a FAIL verdict. Neither do the P3 informational lines. An amendment spec is exempt from the *status* half on the same footing, but its landed-check is a real verdict and does contribute: it is the only leg in this file that can catch a promised amendment that never happened, because the constraint branch skips the spec entirely and the target branch compares code against the spec's text — the wrong direction when the text is what was supposed to change. A degraded (no-`--plan`) check contributes a WARN, never a FAIL.

   **Recovery:** update per `references/doc-spec.md` CLAUDE.md / README.md update rules, then re-run `spec-verify`.

6. **Compliance report** — Use the format from `references/output-templates.md` (Spec Compliance Report section).

   If FAIL, the report is surfaced to the user before `finishing-a-development-branch` proceeds. The user decides whether to fix or accept.

### Review Mode

**Input:**
- `--mode=review`
- `--changed-files=<paths>` — Files changed in the PR/branch
- `--specs=<paths>` — Optional. Governing specs with their role suffixes, when the caller knows them. Needed for the amendment finding below.
- `--plan=<path>` — Optional. Same role as in post-execute mode: it is what lets the amendment check attribute a block to this plan.

1. **Map changed files to governing specs** — Using `.doc-index.json` `code_refs`, identify which specs are affected by the changed files.
2. **Run `check-freshness` on affected specs** — Are any stale relative to the changes?
3. **Coverage gap detection** — Are there changed files that have no governing spec at all? Flag as "unspecified changes."
3b. **Amendment landed-check** — For each spec passed with `:amends`, run the same two-stage check as post-execute mode (`grep -n -A4 'AMENDED 20' <spec-path> | grep -F '<plan-path>'`). No match → a **P1 Amendment not landed** finding. Without `--plan`, degrade to block-present and attach the same verbatim WARN line as post-execute mode — `WARN: amendment citation unverified (no --plan)` — and do not report it as verified.
4. **Produce review findings** — Standard doc-superpowers severity format:
   - **P1 Stale**: Spec exists but hasn't been updated to reflect code changes
   - **P1 Amendment not landed**: A spec passed as `:amends` carries no dated `AMENDED` block attributed to this plan
   - **P2 Incomplete**: Changed files have no governing spec
   - **P3 Style**: Spec metadata inconsistencies

   Output is ready for synthesis into a review report by whatever wrapper or process invoked this action.
