## Documentation Freshness Audit — 2026-03-27

### Summary
- Scanned: 16 docs across 4 scopes (architecture, workflows, guides, specs)
- Fresh: 2 | Stale: 14 (hash-based) | Semantic findings: 16 | Untracked: 0
- Note: All 14 hash-stale docs are 1 commit behind (b349e85). Most were updated in that same commit but the index was built before the commit landed, causing hash staleness without semantic drift. Semantic analysis below identifies the real issues.

### P0 Critical
None.

### P1 Stale

1. `references/doc-spec.md` — CLAUDE.md Updates "When to apply" list
   - Doc says: `"This includes init, update, spec-generate, and sync."` (omits `release`)
   - Code shows: SKILL.md line 426 and `docs/conventions.md` line 100 both include `release` as a CLAUDE.md sync action
   - Suggested fix: Add `release` to the CLAUDE.md Updates "When to apply" list in `references/doc-spec.md` to match SKILL.md and conventions.md

2. `references/spec-lifecycle-actions.md` — Coverage check label
   - Doc says: `"Three-way alignment across three artifacts"` (line 125)
   - Code shows: Five checks are listed immediately after (Design→Specs, Specs→Code, Code→Specs, CLAUDE.md→Filesystem, README.md→Capabilities); design spec says "five-way"
   - Suggested fix: Change label to "Five-way alignment across five artifact relationships" to match the actual content and design spec

3. `references/spec-lifecycle-actions.md` — PASS/FAIL criteria structure
   - Doc says: Base PASS/FAIL criteria omit CLAUDE.md/README.md, then a separate sentence adds "If CLAUDE.md or README.md is stale, include it in the FAIL reasons"
   - Code shows: Design spec (`2026-03-14-spec-lifecycle-protocol-design.md` lines 233-235) integrates CLAUDE.md/README.md currency into the core PASS/FAIL criteria
   - Suggested fix: Incorporate CLAUDE.md/README.md into the primary PASS/FAIL criteria rather than as a separate addendum (behavior is semantically equivalent but structure diverges from spec)

4. `docs/superpowers/specs/2026-03-25-release-notes-action-design.md` — Step 7
   - Doc says: `"7. **Sync CLAUDE.md** — If unreleased commits changed commands, key files, or directory structure, update CLAUDE.md"`
   - Code shows: SKILL.md line 426 says `"7. **Sync CLAUDE.md and README.md**"` — and the spec's own cross-cutting section (line 85) confirms README.md should be included
   - Suggested fix: Update step 7 text to "Sync CLAUDE.md and README.md" to match implementation and spec's own cross-cutting section

### P2 Incomplete

1. `docs/workflows/doc-superpowers.md` — Init process steps
   - Doc says: 10 steps covering init
   - Code shows: SKILL.md has 14 steps for init, including flat-to-structured migration check (step 2), directory structure creation (step 5), ADR seeding (step 7), freshness markers (step 11), and detailed build-index format (step 12)
   - Suggested fix: Add the 4 missing substantive steps (migration check, directory creation, ADR seeding, freshness markers) and align step count

2. `docs/workflows/doc-superpowers.md` — Init Mermaid diagram
   - Doc says: Phase 3 goes from "build-index" → "Update CLAUDE.md" with no README.md node
   - Code shows: SKILL.md step 9 "Sync README.md" is a distinct step between CLAUDE.md (step 8) and diagrams (step 10)
   - Suggested fix: Add "Sync README.md" node between CLAUDE.md and Phase 4 in the init flowchart

3. `docs/workflows/doc-superpowers.md` — Update steps 6-7 ordering
   - Doc says: Step 6 "Preserve manually-added content" and step 7 "Update freshness markers" as discrete top-level steps after CLAUDE.md sync
   - Code shows: SKILL.md treats preservation and marker updates as part of the per-doc EXECUTE sub-phase, which completes before CLAUDE.md sync
   - Suggested fix: Fold steps 6-7 into the scope agent cycle description, or reorder to precede CLAUDE.md sync

4. `docs/guides/getting-started.md` — Verification checklist
   - Doc says: Lists 10 expected init outputs
   - Code shows: SKILL.md also generates `plans/` (always), `archive/` (always), `ci-cd.md` (if ci-cd scope), `infra.md` (if infrastructure scope), `workflows/agentic/` (if agentic scope)
   - Suggested fix: Add `plans/`, `archive/` as always-present entries; add conditional entries for `ci-cd.md`, `infra.md`, `workflows/agentic/`

5. `references/spec-lifecycle-protocol.md` — spec-verify post-execute output
   - Doc says: `"Structured compliance report with PASS/FAIL verdict (includes CLAUDE.md currency check)"`
   - Code shows: Design spec and `spec-lifecycle-actions.md` both include README.md alongside CLAUDE.md in the compliance check
   - Suggested fix: Add "and README.md" to the output description

6. `references/output-templates.md` — Spec Compliance Report template
   - Doc says: Summary section has `"- CLAUDE.md: {current | stale}"` line only
   - Code shows: Both CLAUDE.md and README.md are checked in `spec-lifecycle-actions.md` lines 133-135
   - Suggested fix: Add `- README.md: {current | stale — N sections drifted}` after the CLAUDE.md line

7. `RELEASE-NOTES.md` — Unreleased commits
   - Doc says: Latest entry is v2.3.0 (2026-03-25)
   - Code shows: 3 commits after v2.3.0 tag: `b349e85` (fix: resolve 38 audit findings), `0c8e907` (fix: add missing release action), `cff7b3d` (fix: resolve 5 code review findings)
   - Suggested fix: Run `/doc-superpowers release` to draft a v2.3.1 patch entry

8. `README.md` — File Structure tree
   - Doc says: Tree omits `scripts/test-helpers.sh`, `evals/`, `docs/.doc-index.json`, `docs/plans/`, `docs/archive/`, `docs/superpowers/`
   - Code shows: All omitted items exist on filesystem and are listed in CLAUDE.md Directory Structure
   - Suggested fix: Align README.md File Structure with CLAUDE.md Directory Structure tree

### P3 Style

1. `docs/architecture/system-overview.md` — Freshness marker
   - Doc says: `commit: 0c8e907`
   - Code shows: File was last modified in commit `b349e85`
   - Suggested fix: Update marker to `commit: b349e85`

2. `docs/workflows/doc-superpowers.md` — Freshness marker
   - Doc says: `commit: d46ec45` with date `2026-03-25`
   - Code shows: File was last modified in commit `b349e85` on 2026-03-26
   - Suggested fix: Update marker to `2026-03-26 | commit: b349e85`

3. `docs/codebase-guide.md` — Line reference
   - Doc says: `Release action routing | SKILL.md Section 1 "release" subsection (lines 408-427)`
   - Code shows: The `### release` heading is at line 409, not 408
   - Suggested fix: Change to `(lines 409-427)`

4. `CLAUDE.md` — Archive sub-structure
   - Doc says: `archive/` shown as flat entry with comment "created on demand"
   - Code shows: `docs/archive/plans/` exists with 2 archived reports, making it an established pattern
   - Suggested fix: Optionally expand to show `archive/plans/` sub-entry (low priority)

### CLAUDE.md Status
- [x] Directory Structure: current — all listed paths exist, no phantom entries
- [x] Key Files: current — all 15 entries verified
- [x] Commands: current — all 13 command forms match SKILL.md actions

### README.md Status
- [x] Feature list: current — all features including release, README.md sync, RELEASE-NOTES.md audit mentioned
- [x] Action list: current — all 11 actions present and accurately described
- [ ] File Structure: stale — missing `scripts/test-helpers.sh`, `evals/`, `docs/.doc-index.json`, `docs/plans/`, `docs/archive/`, `docs/superpowers/`

### RELEASE-NOTES.md Status
- [ ] 3 commits unreleased since v2.3.0 (2026-03-25)

### Actions
- Run `/doc-superpowers update` to apply fixes from this audit
- Run `doc-tools.sh update-index <doc>` after manual review
- If README.md flagged stale above, update it per `references/doc-spec.md` README.md update rules
- If RELEASE-NOTES.md flagged stale above, run `/doc-superpowers release` to draft a new version entry
