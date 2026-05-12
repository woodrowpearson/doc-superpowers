# Release Notes

## v2.10.0 (2026-05-12)

### Features
- **Per-PR release-notes fragment producer**: New `doc-pr-release.yml` CI workflow template (installed by `--ci` tier) drafts and maintains a `RELEASE-NOTES.next/PR-<N>.md` fragment for every open PR. On each push, an AI step rewrites the fragment in Keep-a-Changelog format and syncs a managed `<!-- doc-superpowers:start/end -->` section in the PR body. Fragments use a SHA-256 hash on line 2 over the bytes from line 3 onwards so human edits are detected and never silently overwritten — the workflow comments on the PR asking for reconciliation instead. This is the producer half of the fragment lifecycle; the consumer half (release-time merge and delete) ships in a forthcoming PR.
- **Three colocated shell helpers**: `extract-context.sh` emits a JSON context blob (PR body, existing fragment, full and new commit ranges); `update-pr-body.sh` idempotently merges a managed section into the PR body with marker-injection, CRLF, and trailing-newline hardening; `commit-and-push.sh` stages, commits with a `[doc-superpowers]` prefix, and pushes the fragment back to the PR branch. The installer copies them to `.github/scripts/doc-pr-release/` alongside the workflow.
- **Fragment-format spec installed in consuming repos**: `hooks install --ci` now also drops a `RELEASE-NOTES.next/README.md` into the consuming repo (only if missing — never overwritten) that documents the fragment lifecycle, marker conventions, and the SHA-256 manual-edit protocol. Both halves of the lifecycle adhere to this format.
- **CLAUDE_CODE_OAUTH_TOKEN auth for new template**: The new `doc-pr-release.yml` template uses `claude_code_oauth_token` rather than `anthropic_api_key`. Sibling templates still reference `ANTHROPIC_API_KEY` and will migrate in a separate PR.

### Other
- **25-assertion test harness for the new helpers**: `scripts/test-doc-pr-release.sh` covers update-pr-body (8 cases — insert, replace, empty body, no-op, malformed markers, trailing newline, CRLF, marker injection), extract-context (12 cases on a fixture repo with a `gh` shim), and commit-and-push (5 smoke tests covering argv validation, no-op, and missing `GITHUB_HEAD_REF`).
- **Installer hardening for the helper tier**: `install_ci`, `uninstall_ci`, and `status_ci` know about `doc-pr-release.yml` and the helper subdirectory. Uninstall removes the workflow and helpers but intentionally preserves `RELEASE-NOTES.next/README.md` (since the directory may carry unmerged fragments).

## v2.9.1 (2026-05-04)

### Other
- **Issue filed: doc-index metadata churn on every commit**: Top-level `generated_at` and `build_commit` rewrite on every `update-index` call, causing GitHub PRs to flag conflicts even when no docs were touched. The shipped merge driver resolves these locally but GitHub's server-side mergeability check ignores it. Issue proposes moving regeneration metadata to a gitignored sidecar so the version-controlled index becomes content-addressable. See `docs/issues/2026-05-04-doc-index-metadata-rewrite-on-every-commit.md`.

## v2.9.0 (2026-04-07)

### Features
- **Full-cycle PR documentation workflow**: New `doc-pr-full-cycle.yml` CI workflow template orchestrates the complete doc lifecycle on PR open — review, update, diagram regeneration, and index sync — in a single Claude-powered workflow. This is the 5th AI workflow, bringing the total CI template count to 8.
- **Custom merge driver for doc-index.json**: `hooks install --git` now registers a custom git merge driver that auto-resolves timestamp and entry conflicts in `docs/.doc-index.json` during merge and rebase using jq three-way merge. Includes a companion test suite with 314 lines of coverage.

### Fixes
- **Broken Gemini CLI include path**: Fix incorrect include path in `gemini-extension.json` and expand platform installation docs for Codex, OpenCode, and Gemini.
- **Missing Cursor INSTALL.md in directory trees**: Add Cursor INSTALL.md entries to directory trees in AGENTS.md and README.md, and expand Cursor plugin documentation.
- **Dead guard and overlap warning in SKILL.md**: Remove unreachable guard clause and add an overlap warning for the spec-generate stale content scan step.
- **doc-tools.sh resolution in plugin cache**: Use shell glob instead of `fd` to locate the bundled `doc-tools.sh` script, fixing failures when the skill is installed in a plugin cache directory.
- **Merge driver installer hardening**: Add 4 installer tests (16 assertions), validate paths in `status_git()`, and fix blank-line and duplicate-rm bugs in the hook scripts.

## v2.8.0 (2026-04-05)

### Features
- **Vendor doc-tools.sh locally for CI**: The `hooks install --ci` command now copies `doc-tools.sh` into `.github/scripts/doc-tools.sh` in the consuming project. Shell-based CI workflows reference this local copy instead of curling from `raw.githubusercontent.com` at runtime. Uninstall cleans up the vendored file.
- **SHA-pinned GitHub Actions**: All actions in CI workflow templates (`actions/checkout`, `actions/github-script`, `anthropics/claude-code-action`) are now pinned to full commit SHAs to prevent tag-mutation supply-chain attacks.
- **Author association gate on @claude trigger**: `doc-review-pr.yml` now restricts `issue_comment` triggers to OWNER/MEMBER/COLLABORATOR, preventing unauthorized users from consuming `ANTHROPIC_API_KEY` credits.
- **Concurrency groups on AI workflows**: `doc-audit-update.yml`, `doc-release.yml`, and `doc-spec-verify.yml` now include concurrency groups to prevent duplicate concurrent runs.

## v2.7.0 (2026-04-05)

### Features
- **Claude-powered CI workflow templates**: Four new GitHub Actions templates using `anthropics/claude-code-action` for AI-driven doc management on feature branches: `doc-audit-update.yml` (auto audit+update on push), `doc-review-pr.yml` (PR doc review with `@claude` interactive support), `doc-release.yml` (release notes drafting on release branches), and `doc-spec-verify.yml` (spec compliance checks on PRs). Install with `hooks install --ci`.
- **Stale content scan in spec-generate**: New Step 5b detects existing specs with invalidated content when generating specs from a design doc. Extracts removal keywords, greps overlapping specs, classifies severity (HIGH/MEDIUM), and offers to apply deprecation notices immediately rather than deferring to the spec-inject execute phase.

### Other
- **Eval coverage for new features**: Added eval #5 for spec-generate stale content scan (6 assertions) and updated eval #6 hook assertions to match the expanded CI template count (3 to 7).
- **CLAUDE.md path corrections**: Fixed SKILL.md path reference and added missing directory entries for `skills/` and `docs/issues/`.

## v2.6.1 (2026-03-29)

### Fixes
- **Hooks resolve from git root**: Hook commands in `settings.local.json` and hook scripts now cd to `$(git rev-parse --show-toplevel)` before executing, fixing "No such file or directory" errors when cwd drifts to a subdirectory (e.g., after `cd functions && npx jest`). Defense in depth — both the installer command wrapper and each hook script independently resolve to the project root.

## v2.6.0 (2026-03-29)

### Features
- **Deterministic version management**: New `doc-tools.sh bump-version` and `check-version` subcommands update and verify version strings across all 6 manifest files (package.json, claude-code.json, plugin.json, marketplace.json, cursor plugin.json, gemini-extension.json). The `release` action now mandates `bump-version` + `check-version` before tagging, preventing version drift.

### Fixes
- **Skill directory structure**: Moved SKILL.md to `skills/doc-superpowers/SKILL.md` for correct Claude Code plugin discovery when installed via the marketplace.
- **Stale version sync**: Fixed `gemini-extension.json` and `.cursor-plugin/plugin.json` which were stuck at v2.4.0 while other manifests were at v2.5.0.

## v2.5.0 (2026-03-29)

### Features
- **Post-commit doc sync hook**: New `post-commit-sync.sh` Claude Code hook (PostToolUse event) auto-runs `update-index` after git commits and surfaces stale doc guidance, closing the gap where hooks only detected staleness but never triggered remediation.
- **Pre-push release reminder**: New `pre-push` git hook warns when more than 5 unreleased commits exist since the last tag, prompting developers to run `/doc-superpowers release`.
- **Session-summary auto index-update**: The Stop hook now auto-refreshes the doc index before session exit, keeping it current between sessions without requiring manual `/doc-superpowers sync`.
- **All hooks installed on this repo**: Git (5), Claude Code (3), and CI/CD (3) hooks deployed with `--ci-strict` for self-enforcing documentation quality.

### Fixes
- **Session-summary timeout guard**: The `update-index` call in `session-summary.sh` is now wrapped in a 1-second timeout guard matching the existing `check-freshness` timeout pattern, preventing potential session exit delays.
- **Post-commit-sync initial commit handling**: Falls back to `git diff-tree` when `HEAD~1` doesn't exist on initial commits, instead of silently failing.

## v2.4.1 (2026-03-29)

### Fixes
- **Plugin manifest conflict resolved**: Removed `strict` and `skills` keys from `.claude-plugin/marketplace.json` that created ambiguous dual-source component discovery, causing Claude Code to reject the plugin with "conflicting manifests." Plugin now delegates all component discovery to `plugin.json`, matching the pattern used by other single-plugin marketplaces.

### Docs
- **Architecture and workflow diagrams refreshed**: Regenerated C4 container/context, workflow, and sequence diagrams to reflect multi-framework support additions from v2.4.0.
- **Audit findings resolved**: Addressed 15 documentation audit findings across codebase guide, conventions, getting-started guide, and workflow docs. Rebuilt doc index after git history squash.

## v2.4.0 (2026-03-27)

### Features
- **Multi-framework agent support**: doc-superpowers can now be installed in Cursor, Codex, OpenCode, and Gemini CLI — not just Claude Code. Adds `.cursor-plugin/plugin.json`, `.codex/INSTALL.md`, `.opencode/plugins/doc-superpowers.js` (ESM plugin), `gemini-extension.json`, `GEMINI.md`, `AGENTS.md` (cross-client), `package.json`, and `references/tool-mappings.md` with a full tool-name translation table. Also installable via `npx skills add` (skills.sh) for 40+ agents.
- **Index lifecycle commands**: Three new `doc-tools.sh` subcommands for managing the doc index without a full rebuild. `add-entry` appends new docs to an existing index from stdin, `remove-entry` deletes entries by path, and `deprecate-entry` marks entries as deprecated with optional `--superseded-by` linking.
- **Missing-doc detection in hooks**: All git hooks (pre-commit, post-merge, post-checkout) and Claude Code hooks (pre-commit-gate, session-summary) now detect and report indexed documents that no longer exist on disk, with guidance to run `remove-entry` or `deprecate-entry` to clean up.

### Fixes
- **Hook integration uses subprocess instead of source**: The installer now emits `bash "$DOC_SP_HOOK"` instead of `source "$DOC_SP_HOOK"` when integrating into existing git hooks, preventing doc-superpowers hook failures from terminating the parent hook process.
- **Installer respects core.hooksPath when directory does not exist**: `resolve_hooks_dir` no longer requires the `core.hooksPath` directory to already exist on disk; the installer creates it during `install --git`.
- **Installer argument validation for --base-branch and --cron**: Both flags now emit a clear error message and exit 1 when invoked without a required value, instead of silently consuming the next flag as the value.
- **CI workflow GITHUB_OUTPUT multiline fix**: The `doc-freshness-pr.yml` template now uses heredoc-style delimiters for the `files` output, preventing truncation when the changed-file list contains newlines.
- **update-index skips missing files instead of writing null hash**: `update-index` now warns and skips entries whose files no longer exist on disk instead of silently setting `content_hash` to null and marking them current.
- **Session summary timeout on vanilla macOS**: The session-summary hook now uses a background-process-with-kill fallback when neither `timeout` nor `gtimeout` is available.
- **DOC_INDEX path now overridable in all hooks**: All hook scripts accept `DOC_INDEX` as an environment variable, enabling non-standard index locations and easier testing.
- **Uninstaller cleanup for bash-style integration**: `uninstall --git` sed pattern now matches both `bash` and legacy `source` integration lines, and squeezes consecutive blank lines left by marker removal.
- **Test helper assertion hardening**: `assert_contains` and `assert_not_contains` now use `grep -F` (fixed string) matching, preventing false positives from regex metacharacters.
- **Documentation sync across references and guides**: Resolved audit findings across `doc-spec.md`, `output-templates.md`, `spec-lifecycle-actions.md`, `spec-lifecycle-protocol.md`, and all workflow/architecture docs to reflect the release action, README.md sync, and five-way spec-verify coverage checks.

## v2.3.0 (2026-03-25)

### Features
- **Release notes action**: New `/doc-superpowers release` action drafts RELEASE-NOTES.md entries from git history. Parses conventional commit prefixes to auto-suggest semver bump, dispatches a drafting agent that reads actual diffs (not just commit messages) for richer descriptions, and optionally creates git tags — including backfilling untagged older versions.
- **README.md cross-cutting sync**: README.md now gets the same freshness treatment as CLAUDE.md across all actions. Read-only actions (`audit`, `review-pr`) detect drift in feature lists, action tables, and usage examples. Write actions (`init`, `update`, `sync`, `release`, `spec-generate`) fix it. Update rules in `references/doc-spec.md`.
- **RELEASE-NOTES.md audit detection**: `audit` now checks for unreleased commits since the last version entry and emits P2 Incomplete findings with a suggestion to run `/doc-superpowers release`.

### Fixes
- **CLAUDE.md sync completeness**: `spec-generate` and `spec-verify` now sync README.md alongside CLAUDE.md in `references/spec-lifecycle-actions.md`, matching the cross-cutting pattern used by all other actions.

## v2.2.0 (2026-03-14)

### Features
- **Spec lifecycle actions**: Three new actions for formal specification tracking through implementation:
  - `spec-generate --design-doc=<path>` — Decompose narrative design docs into formal `SPEC-{CAT}-NNN-{slug}.md` files with metadata, indexing, and freshness tracking
  - `spec-inject --phase=plan|execute` — Inject spec maintenance tasks into implementation plans (plan phase) and detect alignment vs. drift after each chunk (execute phase)
  - `spec-verify --mode=post-execute|review` — Final compliance check with PASS/FAIL verdict (post-execute) and spec coverage findings for code review (review mode)
- **Spec lifecycle protocol**: `references/spec-lifecycle-protocol.md` — integration guide for wrapper skill authors with input/output contracts and pipeline interception patterns
- **Spec lifecycle routing**: Graphviz decision tree in SKILL.md for choosing the right spec action based on project state
- **9 spec category codes**: ARCH, AUTH, DATA, API, UI, PIPE, OPS, INFRA, TEST — used in `SPEC-{CAT}-NNN` naming
- **Spec supersession**: Automated handling of superseded specs with `replaces`/`superseded_by` fields and archive migration
- **Three-way coverage check**: Design doc ↔ Specs ↔ Code alignment verification in `spec-verify --mode=post-execute`

### Fixes
- **Audit is now read-only**: Audit follows gather→analyze→report (never writes docs). Execution cycle (plan→execute→diagram→sync) moved to `update` where it belongs.
- **Audit always writes report**: Output saved to `docs/plans/YYYY-MM-DD-audit-report.md` as structured handoff to `update`.
- **Update reads audit report**: Consumes latest `*-audit-report.md` as structured input; falls back to `check-freshness` if no report exists.
- **Untracked doc detection**: `check-freshness` now reports docs in `docs/` not present in the index via `summary.untracked` count and `untracked_docs` array.
- **Flat-to-structured migration**: `update` detects old flat-structure docs and migrates to structured directories with diagram co-location.
- **build-index stdin format documented**: Usage text clarifies `doc_path:code_refs_csv:doc_type` format.

## v2.1.0 (2026-03-13)

### Features
- **Workflow hooks harness**: Opt-in hooks that plug doc-superpowers into git, Claude Code, and CI/CD workflows.
  - Git hooks: `pre-commit` (freshness gate), `post-merge` (stale alert), `post-checkout` (branch check), `prepare-commit-msg` (commit message injection)
  - Claude Code hooks: `PreToolUse` pre-commit gate, `Stop` session summary
  - CI/CD workflows: PR freshness check, weekly drift detector, post-merge index auto-update
- **Tiered installer**: `/doc-superpowers hooks install [--git] [--claude] [--ci] [--all]` with status and uninstall support
- **Environment variable controls**: `DOC_SUPERPOWERS_SKIP`, `DOC_SUPERPOWERS_STRICT`, `DOC_SUPERPOWERS_QUIET`
- **CI parameterization**: `--base-branch`, `--cron`, `--ci-strict` flags for CI tier

## v2.0.0 (2026-03-12)

### Breaking Changes
- **Directory structure**: Generated docs now use structured directories (`docs/architecture/`, `docs/specs/`, `docs/adr/`, `docs/workflows/`, `docs/guides/`). Projects with v1.0.0 flat files will be offered migration on next `init`.
- **Diagram paths**: Diagrams co-located in `docs/{section}/diagrams/` instead of global `docs/diagrams/`.
- **Discovery rewrite**: Scope detection uses structural categories (`application`, `data-layer`, `infrastructure`) instead of platform identifiers.

### Features
- **Bundled freshness tooling**: `scripts/doc-tools.sh` with 4 subcommands (`build-index`, `check-freshness`, `update-index`, `status`). Content hashing for docs, commit SHA comparison for code.
- **Doc-index**: Machine-readable `docs/.doc-index.json` tracks content hashes, code references, staleness, supersession chains.
- **Naming conventions**: `SPEC-{CAT}-NNN-{slug}.md` for specs, `ADR-NNN-{slug}.md` for ADRs, kebab-case for everything else.
- **Read-only analysis**: `audit` and `review-pr` dispatch scope-specific agents through read-only gather-analyze-report cycle (see v2.2.0 fixes for clarification).
- **Audit owns discovery**: All actions consume the same discovery logic. No more duplicated scope detection.
- **New doc templates**: Architecture components, spec template, ADR template, ci-cd.md, infra.md, specs/README.md, adr/README.md.
- **Flat-to-structured migration**: `init` detects old flat files and offers migration.

### Dependencies
- **jq** is now required for `scripts/doc-tools.sh`. The skill itself remains zero-dependency.

## v1.0.0 (2026-03-12)

Initial release as a standalone repository.

### Features
- **Documentation orchestrator** with 6 actions: `init`, `audit`, `review-pr`, `update`, `diagram`, `sync`
- **Discovery phase** auto-detects project doc tooling, scopes, and agentic workflows
- **Parallel agent dispatch** for scope-isolated documentation reviews
- **Agentic workflow documentation** generates pipeline diagrams, sequence diagrams, and state diagrams from `.claude/skills/` inventory
- **Freshness markers** track when docs were last generated/updated
- **PR-scoped review** maps changed files to affected documentation
- **Doc-spec reference** with Mermaid templates for C4, flowchart, sequence, ERD, and state diagrams
- **CLAUDE.md management** creates or updates project instruction files

### Lineage
- Extracted from `~/.claude/skills/doc-superpowers/` (personal skill)
- Supersedes the earlier `doc-audit` skill
- Designed as a superset of [obra/superpowers](https://github.com/obra/superpowers) documentation patterns, extending them with agentic workflow discovery, multi-scope parallel auditing, and diagram generation
