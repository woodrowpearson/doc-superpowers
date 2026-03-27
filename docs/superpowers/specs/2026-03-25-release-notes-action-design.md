# Release Notes Action & README.md Sync Design

## Problem

doc-superpowers manages documentation freshness across a project but has two blind spots:

1. **Release notes**: RELEASE-NOTES.md is listed as a key file in CLAUDE.md with "When to Modify: Every release" and semver conventions are documented in conventions.md, but no action detects staleness or drafts new entries. The project's own RELEASE-NOTES.md proves the gap — it's 11 days and 7+ commits behind.

2. **README.md drift**: README.md suffers the same staleness problem as CLAUDE.md did before c1e795f. The project description still says "extends them with automated discovery of agentic pipelines, multi-scope parallel auditing, and architecture diagram generation" — missing hooks, spec lifecycle, and everything added since v1.0.0. No action detects or fixes this.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Detection + action | Both (C) | Follows existing audit-detects, action-fixes pattern |
| Action placement | Standalone `release` (A) | Versioning is intentional, not a side effect of `update` |
| Git tags | Draft + offer to tag (B) | Fills tagging gap without being presumptuous |
| Version bump | Auto-suggest from commit prefixes (A) | Conventional commits already in use; user confirms or overrides |
| Audit severity | P2 Incomplete | Existing entries aren't wrong, just missing new work |
| PR review | Does not flag | Release notes are project-level, not per-PR |
| README.md sync | Cross-cutting like CLAUDE.md (B) | Same class of problem — all write actions should check it, not just `release` |

## Design

### New action: `release`

**Trigger:** `/doc-superpowers release` with optional `--from=<ref>` override.

**Steps:**

1. **Parse RELEASE-NOTES.md** — Extract the latest version number, date, and section types. This establishes the format to match.

2. **Determine commit range** — Check for a git tag matching the latest version. If found, use `git log <tag>..HEAD`. If not, fall back to `git log --after=<last-release-date>`. Respect `--from=<ref>` override.

3. **Auto-suggest version bump** — Parse conventional commit prefixes: `feat:` maps to MINOR, `fix:` maps to PATCH, `docs:` maps to PATCH, `!` suffix or `BREAKING CHANGE` footer maps to MAJOR. Unmapped prefixes (`chore:`, `refactor:`, `test:`, etc.) default to PATCH. Highest wins. Present suggestion with commit evidence (e.g., "Found 2 feat: and 3 fix: commits, suggesting MINOR bump to v2.3.0"). User confirms or overrides.

4. **Dispatch drafting agent** — Single `general-purpose` agent receives:
   - The commit list with messages
   - The full `git diff` for the range (or per-commit diffs if range is large)
   - The conventions.md bump table for cross-referencing
   - The previous RELEASE-NOTES.md entry as a format exemplar
   - Instructions: group changes into Features/Fixes/Breaking Changes/Dependencies sections using the existing bold-title-colon-description format, flag anything that looks like a breaking change

5. **Present draft to user** — Show the drafted entry in full. User edits or approves.

6. **Prepend to RELEASE-NOTES.md** — Insert new version entry after `# Release Notes` header, before the previous version entry.

7. **Sync CLAUDE.md and README.md** — If unreleased commits changed commands, key files, directory structure, actions, or features, update CLAUDE.md and README.md per `references/doc-spec.md` rules. This catches drift that accumulated across the commits being released.

8. **Offer git tag** — Prompt: "Create git tag `vX.Y.Z`?" If yes, run `git tag vX.Y.Z`. If the project has older untagged versions, mention them and offer to backfill.

### Audit integration

**New audit step** (after CLAUDE.md currency check, before scope agent dispatch):

Check RELEASE-NOTES.md currency — parse latest version entry date, find commits after that date (or after matching git tag). If unreleased commits exist, emit P2 Incomplete:

> "RELEASE-NOTES.md: N commits unreleased since vX.Y.Z (YYYY-MM-DD). Run `/doc-superpowers release` to draft a new version entry."

**Excluded:** `review-pr` does not flag this. `update` does not auto-fix this — `release` is the dedicated fix action.

### Audit report template

New section in `references/output-templates.md` alongside CLAUDE.md Status:

```
### RELEASE-NOTES.md Status
- [ ] {current | N commits unreleased since vX.Y.Z (YYYY-MM-DD)}
```

### Cross-cutting: README.md sync

Same pattern as CLAUDE.md sync (c1e795f). README.md is the project's public face — if it lists outdated features, users don't know what the tool can do.

**Read-only actions (audit, review-pr) — detect and report:**

- `audit`: New step after CLAUDE.md and RELEASE-NOTES.md currency checks. Compare README.md's feature list, action list, and usage examples against actual SKILL.md actions and capabilities. Flag discrepancies as P1 Stale (features described that no longer exist or work differently) or P2 Incomplete (new actions/features not mentioned). Include findings in audit report.
- `review-pr`: If PR changes affect actions, commands, or features listed in README.md, include a finding: "README.md may need updating — {section} references changed capabilities." Severity: P1 if listed features were removed/changed, P2 if new features should be added.

**Write actions (init, update, sync) — fix:**

- `init`: Generate README.md from discovered project state (already creates it, but should include all detected actions/features).
- `update`: After all doc changes are applied, check README.md sections against current project state. Update feature list, action list, and usage examples if stale. **SEE** `references/doc-spec.md` for update rules (a new README.md section will be added alongside the existing CLAUDE.md rules).
- `sync`: Check README.md currency alongside CLAUDE.md. If stale, update.
- `release`: Inherits this behavior from the cross-cutting pattern — step 7 already syncs CLAUDE.md, README.md gets the same treatment.

**Audit report template:**

New section in `references/output-templates.md`:

```
### README.md Status
- [ ] Feature list: {current | stale — list discrepancies}
- [ ] Action list: {current | stale — list discrepancies}
- [ ] Usage examples: {current | stale — list discrepancies}
```

**doc-spec.md update rules:**

New "README.md Updates" section alongside "CLAUDE.md Updates":

- **Feature list**: Sync with actual SKILL.md actions and capabilities
- **Action list**: Sync with action definitions (init, audit, review-pr, update, diagram, sync, hooks, release, spec-*)
- **Usage examples**: Verify examples still work and reference current action names/flags
- **Project description**: Ensure it covers current major capabilities
- Preserve the user's voice and structure — only update sections that are factually stale

## Files Changed

| File | Change |
|------|--------|
| `SKILL.md` | New `release` action definition; new audit step for RELEASE-NOTES.md; README.md sync steps in all write/read actions; action routing entry; Common Mistakes rows for both |
| `references/output-templates.md` | Audit report template gets RELEASE-NOTES.md Status and README.md Status sections |
| `references/doc-spec.md` | New "README.md Updates" section alongside "CLAUDE.md Updates" |
| `references/integration-patterns.md` | Cross-cutting section updated to include README.md alongside CLAUDE.md |
| `CLAUDE.md` | Commands section gets `/doc-superpowers release` |
| `README.md` | Feature list, action list, and usage updated to reflect current state (dogfooding) |
| `RELEASE-NOTES.md` | New version entry for this change (dogfooding) |
