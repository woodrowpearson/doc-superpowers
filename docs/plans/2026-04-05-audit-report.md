## Documentation Freshness Audit — 2026-04-05

**Repo HEAD:** 696ba07 (feat: add Claude-powered CI workflow templates for full feature branch coverage)
**Branch:** main

### Summary
- Scanned: 18 docs across 4 scopes (architecture, workflows, guides, specs/plans)
- Fresh: 2 | Stale: 16 | Missing coverage: 0 | Untracked: 2

Root cause: Commit 696ba07 added 4 Claude-powered CI workflow templates (`doc-audit-update.yml`, `doc-review-pr.yml`, `doc-release.yml`, `doc-spec-verify.yml`). Prior commits added hooks path fix (39fb590) and version management tooling (fc3621c). Docs have not been regenerated since.

### P0 Critical

1. **docs/codebase-guide.md** — SKILL.md path references non-existent root location
   - Doc says: `├── SKILL.md  # Main skill definition — discovery, routing, agents, verification`
   - Code shows: Root `SKILL.md` does not exist. Moved to `skills/doc-superpowers/SKILL.md` in commit 25401a5.
   - All "Where to Find Things" and "Key Files" references point to bare `SKILL.md`.
   - Suggested fix: Add `skills/` directory to tree, update all references to `skills/doc-superpowers/SKILL.md`.

### P1 Stale

2. **docs/architecture/system-overview.md** — CI template count lists 3 of 7
   - Doc says: "PR freshness check, weekly scheduled audit, doc-index auto-update" (line 109)
   - Code shows: `scripts/hooks/ci/` contains 7 files (3 shell-based + 4 Claude-powered)
   - Suggested fix: Update CI/CD Templates row and C4 Context diagram to reflect all 7 templates.

3. **docs/architecture/system-overview.md** — No mention of SKILL.md relocation
   - Doc references `SKILL.md` without path qualifier (lines 63, 67, 135, 153)
   - Code shows: SKILL.md is at `skills/doc-superpowers/SKILL.md`
   - Suggested fix: Update path references.

4. **docs/workflows/doc-superpowers.md** — CI tier table lists 3 of 7 templates
   - Doc says: `| CI/CD | --ci | PR freshness check workflow, weekly audit workflow, doc-index auto-update workflow |` (line 322)
   - Code shows: Installer iterates over all 7 workflows (install.sh lines 375, 394)
   - Suggested fix: Update CI/CD tier row to list all 7 workflows.

5. **docs/workflows/doc-superpowers.md** — No mention of SKILL.md relocation
   - Multiple references to `SKILL.md` without path qualifier (lines 7, 80, 123, 129, 132, 203, 301, 664)
   - Suggested fix: Update references to `skills/doc-superpowers/SKILL.md`.

6. **docs/codebase-guide.md** — CI workflow tree lists 3 of 7 templates
   - Doc says: `doc-freshness-pr.yml`, `doc-freshness-schedule.yml`, `doc-index-update.yml` (lines 43-45)
   - Code shows: 7 files in `scripts/hooks/ci/`
   - Suggested fix: Add 4 new templates to directory tree and "Where to Find Things" table.

7. **docs/codebase-guide.md** — doc-tools.sh subcommand count says 7, actual is 9
   - Doc says: "Bundled freshness tooling (build-index, check-freshness, update-index, add-entry, remove-entry, deprecate-entry, status)" (line 26)
   - Code shows: 9 subcommands — missing `bump-version` and `check-version`
   - Suggested fix: Update annotation and Key Files table to list 9 subcommands.

8. **docs/conventions.md** — CI tier table lists 3 of 7 workflows
   - Doc says: `| CI/CD | --ci | doc-freshness-pr.yml, doc-freshness-schedule.yml, doc-index-update.yml |` (line 190-191)
   - Code shows: 7 CI workflow templates
   - Suggested fix: Update to list all 7.

9. **docs/guides/getting-started.md** — README manual install references root SKILL.md
   - README says: "Copy `SKILL.md` and `references/` into `.claude/skills/doc-superpowers/`"
   - Code shows: SKILL.md is at `skills/doc-superpowers/SKILL.md`
   - Suggested fix: Update README manual installation path.

10. **docs/superpowers/specs/2026-03-12-bundled-doc-tooling-design.md** — Says 4 subcommands, actual is 9
    - Spec says: "Single shell script with four subcommands" (line 237)
    - Code shows: 9 subcommands in doc-tools.sh. Missing design for add-entry, remove-entry, deprecate-entry, bump-version, check-version.
    - Suggested fix: Update subcommand count; add notes for missing subcommands.

11. **docs/superpowers/specs/2026-03-13-workflow-hooks-harness-design.md** — Lists 3 CI workflows, actual is 7
    - Spec directory layout (lines 53-57) shows only 3 CI templates
    - Claude hook commands use simple relative paths; actual uses git-root wrapping (commit 39fb590)
    - Suggested fix: Add 4 new CI templates to spec; update Claude hook command format.

12. **docs/superpowers/plans/2026-03-13-workflow-hooks-harness.md** — Plan scope exceeded by implementation
    - Plan lists 3 CI workflows; actual has 7. Plan uses simple hook command paths; actual wraps with git-root resolution.
    - Suggested fix: Mark as "Implemented with extensions" noting commits 696ba07 and 39fb590.

13. **skills/doc-superpowers/SKILL.md** — Hook status summary counts wrong
    - SKILL.md says: `Hooks: N/4 git, N/2 claude, N/7 ci` (line 410)
    - Code shows: 5 git hooks, 3 claude hooks, 7 ci templates
    - Suggested fix: Update to `Hooks: N/5 git, N/3 claude, N/7 ci`.

### P2 Incomplete

14. **docs/workflows/doc-superpowers.md** — No documentation for 4 new AI-powered CI workflows
    - Missing descriptions for: doc-audit-update.yml (AI audit+update on feature branches), doc-review-pr.yml (AI PR doc review + @claude interactive), doc-release.yml (AI release notes drafting), doc-spec-verify.yml (AI spec compliance on PRs)
    - Suggested fix: Add descriptions for each template including triggers and requirements.

15. **docs/conventions.md** — Claude Code hooks tier missing post-commit-sync.sh
    - Doc says: `| Claude Code | --claude | pre-commit-gate.sh, session-summary.sh |` (line 189)
    - Code shows: 3 scripts — also includes `post-commit-sync.sh`
    - Suggested fix: Add `post-commit-sync.sh` to Claude Code tier row.

16. **docs/conventions.md** — Git hooks tier missing pre-push
    - Doc says: `| Git | --git | pre-commit, post-merge, post-checkout, prepare-commit-msg |` (line 188)
    - Code shows: 5 git hooks — also includes `pre-push`
    - Suggested fix: Add `pre-push` to Git tier row.

17. **docs/conventions.md** — No mention of bump-version/check-version conventions
    - Versioning section describes semantic versioning but not the doc-tools.sh commands that automate it
    - Suggested fix: Add subsection noting `bump-version` and `check-version` as canonical version management tools.

18. **docs/superpowers/specs/2026-03-25-release-notes-action-design.md** — Missing bump-version/check-version tooling
    - Spec describes release action design but not the supporting doc-tools.sh subcommands added to implement it
    - Suggested fix: Add note about supporting tooling in doc-tools.sh.

19. **docs/superpowers/plans/2026-03-29-github-pages-site.md** — Not in doc index
    - Suggested fix: Run `doc-tools.sh add-entry` to register.

20. **docs/superpowers/specs/2026-03-29-github-pages-site-design.md** — Not in doc index
    - Suggested fix: Run `doc-tools.sh add-entry` to register.

### P3 Style

21. **docs/architecture/system-overview.md** — Freshness marker outdated (commit 97134e0, HEAD is 696ba07)
22. **docs/workflows/doc-superpowers.md** — Freshness marker outdated (commit 97134e0, HEAD is 696ba07)
23. **docs/codebase-guide.md** — Missing `docs/archive/` subtree in directory tree
24. **docs/plans/2026-03-26-audit-report.md** — Historical snapshot (commit 0c8e907), accurate at time of writing
25. **docs/plans/2026-03-27-audit-report.md** — Historical snapshot (commit 97134e0), accurate at time of writing
26. **docs/archive/plans/2026-03-15-audit-report.md** — Archived historical snapshot
27. **docs/archive/plans/2026-03-25-audit-report.md** — Archived historical snapshot
28. **docs/superpowers/plans/2026-03-25-release-notes-readme-sync.md** — Current within declared scope
29. **docs/superpowers/plans/2026-03-26-multi-framework-support.md** — Current (plan snapshot)

### CLAUDE.md Status
- [x] Directory Structure: current — lists all 7 CI templates, correct skills/ path
- [x] Key Files: current
- [x] Commands: current

### README.md Status
- [ ] Feature list: stale — CI/CD hooks description (line 180) only mentions 3 shell-based workflows, not the 4 Claude-powered ones
- [ ] Action list: current
- [ ] Usage examples: stale — manual install (line 40 area) references root `SKILL.md` path

### RELEASE-NOTES.md Status
- [ ] 1 commit unreleased since v2.6.1 (2026-03-29): 696ba07 `feat: add Claude-powered CI workflow templates`

### Actions
- Run `/doc-superpowers update` to generate fixes
- Run `doc-tools.sh update-index <doc>` after manual review
- Fix SKILL.md hook count at line 410: `N/4 git, N/2 claude` → `N/5 git, N/3 claude`
- Update README.md CI hooks description and manual install path
- Run `/doc-superpowers release` to draft v2.7.0 entry (feat: commit = MINOR bump)
- Run `doc-tools.sh add-entry` for 2 untracked docs
