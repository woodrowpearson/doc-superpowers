# Release Notes

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
