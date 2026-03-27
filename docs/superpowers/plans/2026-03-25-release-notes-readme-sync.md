# Release Notes Action & README.md Sync — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `release` action for drafting version entries from git history, and weave README.md sync into all actions as a cross-cutting concern (mirroring the CLAUDE.md sync pattern).

**Architecture:** Two independent concerns implemented sequentially — README.md sync first (it touches every action), then the `release` action (standalone). Both follow established patterns from c1e795f (CLAUDE.md sync).

**Tech Stack:** Pure SKILL.md / reference doc changes — no scripts or code.

---

### Task 1: Add README.md update rules to doc-spec.md

**Files:**
- Modify: `references/doc-spec.md:749-751` (after CLAUDE.md Updates section, before `---` separator)

- [ ] **Step 1: Add README.md Updates section**

Insert after line 749 (after CLAUDE.md Updates "Keep it concise" paragraph), before the `---` separator at line 751:

```markdown
## README.md Updates

README.md is the project's public documentation — if it lists outdated features or missing actions, users and contributors don't know what the tool can do. Like CLAUDE.md, README.md sync is a cross-cutting concern for every write action.

**When to apply these rules**: After ANY doc-superpowers write action that changes capabilities, actions, features, or project structure. This includes `init`, `update`, `sync`, `release`, and `spec-generate`. The `audit` and `review-pr` actions detect README.md staleness and report it; the write actions fix it.

**If README.md exists**: Read it first. Only update sections that are factually stale:
- **Feature list**: Sync with actual SKILL.md actions and capabilities
- **Action list**: Sync with action definitions (init, audit, review-pr, update, diagram, sync, hooks, release, spec-*)
- **Usage examples**: Verify examples still work and reference current action names/flags
- **Project description**: Ensure it covers current major capabilities

**Preserve everything else** — tone, structure, installation instructions, contributing guidelines, and any manually-written content. Do NOT rewrite sections that are still accurate. Do NOT reformat or restructure. Treat README.md as the project owner's voice.

**If README.md does not exist**: Do not create one — README.md is the project owner's responsibility. Flag as P2 Incomplete in audit if the project has docs but no README.md.
```

- [ ] **Step 2: Commit**

```bash
git add references/doc-spec.md
git commit -m "docs: add README.md update rules to doc-spec.md"
```

### Task 2: Add README.md sync to all SKILL.md actions

**Files:**
- Modify: `SKILL.md:259` (init step 8), `SKILL.md:275-276` (audit step 6-7), `SKILL.md:327-328` (review-pr step 6-7), `SKILL.md:363-364` (update step 4-5), `SKILL.md:397-398` (sync step 6-7)

- [ ] **Step 1: Add README.md to init (after CLAUDE.md step)**

After step 8 (Update CLAUDE.md), add step 9 for README.md. Renumber steps 9-13 to 10-14.

- [ ] **Step 2: Add README.md check to audit (after CLAUDE.md check)**

After step 6 (Check CLAUDE.md currency), add step 7 for README.md currency check. Renumber steps 7-12 to 8-13. Update step 9 merge description to include README.md findings.

- [ ] **Step 3: Add README.md check to review-pr (after CLAUDE.md check)**

After step 6 (Check CLAUDE.md impact), add step 7 for README.md impact check. Renumber step 7 to 8. Update merge step to include README.md findings.

- [ ] **Step 4: Add README.md sync to update (after CLAUDE.md sync)**

After step 4 (Sync CLAUDE.md), add step 5 for README.md sync. Renumber steps 5-6 to 6-7.

- [ ] **Step 5: Add README.md check to sync (after CLAUDE.md check)**

After step 6 (Check CLAUDE.md currency), add step 7 for README.md currency check. Renumber steps 7 to 8.

- [ ] **Step 6: Commit**

```bash
git add SKILL.md
git commit -m "feat: add README.md sync to all doc-superpowers actions"
```

### Task 3: Add README.md to output templates and integration patterns

**Files:**
- Modify: `references/output-templates.md:27-35` (audit report template)
- Modify: `references/integration-patterns.md:5-15` (cross-cutting section)

- [ ] **Step 1: Add README.md Status to audit report template**

After CLAUDE.md Status section (line 30), before Actions section (line 32), add:

```markdown
### README.md Status
- [ ] Feature list: {current | stale — list discrepancies}
- [ ] Action list: {current | stale — list discrepancies}
- [ ] Usage examples: {current | stale — list discrepancies}
```

Update Actions section to include README.md fix suggestion.

- [ ] **Step 2: Add README.md to integration patterns cross-cutting section**

Update the Cross-cutting section heading and content to cover both CLAUDE.md and README.md. Update the numbered checklist to include README.md alongside CLAUDE.md.

- [ ] **Step 3: Commit**

```bash
git add references/output-templates.md references/integration-patterns.md
git commit -m "docs: add README.md to output templates and integration patterns"
```

### Task 4: Add Common Mistakes row for README.md

**Files:**
- Modify: `SKILL.md:498` (Common Mistakes table)

- [ ] **Step 1: Add README.md row**

After the CLAUDE.md row, add:

```
| Updating docs but not README.md | Every write action (`init`, `update`, `sync`, `release`, `spec-generate`) must sync README.md — see `references/doc-spec.md` README.md Updates |
```

- [ ] **Step 2: Commit**

```bash
git add SKILL.md
git commit -m "docs: add README.md Common Mistakes row"
```

### Task 5: Add `release` action to SKILL.md

**Files:**
- Modify: `SKILL.md:225-237` (action routing flowchart)
- Modify: `SKILL.md` (insert new action before `hooks`)

- [ ] **Step 1: Update action routing flowchart**

Add `release` to the Mermaid flowchart decision tree.

- [ ] **Step 2: Add RELEASE-NOTES.md currency check to audit**

After the README.md currency check step (added in Task 2), add a RELEASE-NOTES.md currency check step. Renumber subsequent steps.

- [ ] **Step 3: Write the `release` action definition**

Insert before the `hooks` action. Full 8-step definition per the design spec.

- [ ] **Step 4: Commit**

```bash
git add SKILL.md
git commit -m "feat: add release action for version entry drafting"
```

### Task 6: Add RELEASE-NOTES.md to output templates

**Files:**
- Modify: `references/output-templates.md` (audit report template)

- [ ] **Step 1: Add RELEASE-NOTES.md Status section**

After README.md Status, before Actions, add:

```markdown
### RELEASE-NOTES.md Status
- [ ] {current | N commits unreleased since vX.Y.Z (YYYY-MM-DD)}
```

Update Actions to include release notes fix suggestion.

- [ ] **Step 2: Commit**

```bash
git add references/output-templates.md
git commit -m "docs: add RELEASE-NOTES.md status to audit report template"
```

### Task 7: Update CLAUDE.md and README.md (dogfooding)

**Files:**
- Modify: `CLAUDE.md:71-84` (Commands section)
- Modify: `README.md` (feature list, action list, usage)

- [ ] **Step 1: Add `release` command to CLAUDE.md**

- [ ] **Step 2: Update README.md to reflect current state**

Update project description, feature list, action table, and usage examples to cover all current capabilities including hooks, spec lifecycle, release, and README.md sync.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: update CLAUDE.md and README.md to reflect current state (dogfooding)"
```

### Task 8: Add RELEASE-NOTES.md entry (dogfooding)

**Files:**
- Modify: `RELEASE-NOTES.md`

- [ ] **Step 1: Draft v2.3.0 entry**

New MINOR version (new `release` action = MINOR per conventions.md bump table). Include Features (release action, README.md sync) and Fixes (Common Mistakes table completeness).

- [ ] **Step 2: Commit**

```bash
git add RELEASE-NOTES.md
git commit -m "docs: add v2.3.0 release notes (dogfooding)"
```
