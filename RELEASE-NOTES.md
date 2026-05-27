# Release Notes

## v2.12.2 (2026-05-26)

Hook-installer fix — generated git/Claude hooks now resolve the latest installed plugin-cache version at runtime instead of pinning the version that was active at install time. Closes a class of bug where the `check-freshness` perf fix (v2.12.1) was shipping but invisible at the commit boundary because hook bodies kept invoking the older `2.12.0/scripts/doc-tools.sh` baked into them at install.

### Fixes
- **Hooks pinned `DOC_TOOLS` to the install-time plugin-cache version, so `check-freshness` perf fixes were invisible at the commit boundary** (`scripts/hooks/git/*`, `scripts/hooks/claude/*`, `scripts/hooks/install.sh`) — Hook templates substituted `__DOC_TOOLS_PATH__` with the version-pinned `$SKILL_DIR/scripts/doc-tools.sh` at install time. When the user `claude plugin update doc-superpowers` brought in a newer version, the new sibling appeared in `~/.claude/plugins/cache/doc-superpowers/doc-superpowers/<NEW>/` but the hooks kept calling `<OLD>/scripts/doc-tools.sh` indefinitely. Symptom: even with v2.12.1 installed, commits on doc-heavy branches still hit the v2.12.0 slow path (e.g., the abundance-mvp repo observed 4+ minute hangs on a 2-file docs commit despite v2.12.1 being in cache). Fix: a new `DOC_TOOLS_PARENT` substitution carries the plugin-cache parent directory (computed via `dirname "$SKILL_DIR"`) into each hook template; the hook then runs `$(printf '%s\n' $DOC_TOOLS_PARENT/*/scripts/doc-tools.sh | sort -V | tail -1)` at hook-invocation time, picking the highest-version sibling on every commit. `DOC_TOOLS` env-var override (already present in templates) still wins for test harnesses and operator overrides. Two new test assertions per hook surface: the new `__DOC_TOOLS_PARENT__` placeholder is substituted away AND the `sort -V | tail -1` resolver fragment is present in the rendered hook. No API change; no migration needed — operators get the fix on the next `hooks install` run.

## v2.12.1 (2026-05-26)

Performance fix for `check-freshness` — the full walk now completes on 2000+ entry indexes that previously hit the harness's 10-min ceiling. No API change.

### Fixes
- **`check-freshness` full walk timed out at ~10 min on indexes ≥ ~2000 entries** (`doc-tools.sh`) — Root cause: the inner loop invoked `jq` ~10× per entry (5 field extractions on the parsed entry, then 3–4 calls to rebuild the running `docs_out` accumulator). At 2083 entries that's ~20,000 `jq` process spawns; on the abundance-mvp index this consistently SIGKILL'd around 600 s wall-clock. The rewrite extracts every entry's fields in **one** `jq -j ... | @tsv` streaming pass, processes each row in pure bash, and appends per-doc results as JSON-lines to a `mktemp` file that's merged once with `jq -s 'reduce .[] as $row ({}; . + $row)'`. Untracked detection switched from per-file `jq '.docs | has($p)'` calls to a single `jq keys` + `comm -23` set-difference. Real-world measurement on the abundance-mvp 2082-entry index: **133 s** (down from >600 s SIGKILL) — well under the harness ceiling and runnable as a full audit pass. `compute_freshness` is left untouched so `cmd_status` callers keep their existing signature. All 147 prior tests pass unchanged; one new regression-guard test (`test_check_freshness_scales_to_large_index`) builds a synthetic 500-entry index, walks it under a 60 s budget, and asserts the freshness summary. The new test measured at **23 s** on a developer laptop.

## v2.12.0 (2026-05-16)

Adds granular CI install with persistent install-state tracking, a standalone `tools install/uninstall/status` subcommand on `doc-tools.sh`, and a new `scripts/hooks/state.sh` module that backs the state file. Lets users opt out of subsets of the 9 doc-superpowers CI workflows, with the installer remembering uninstall decisions so they survive across re-runs.

### Features
- **`tools install|uninstall|status` subcommand on `doc-tools.sh`** — Standalone vendoring of the bundled CLI without the full CI install. `tools install` copies `doc-tools.sh` into `--dest <path>` (default `.github/scripts`); `--with-helpers` also copies the `doc-pr-release/` shell helpers + `RELEASE-NOTES.next/README.md` spec. `tools uninstall` removes the vendored copy and (best-effort, honoring local edits via `cmp -s`) the helpers. `tools status` reports installed/drifted state + helper presence. Enables projects that want only `doc-tools.sh` for their own CI to opt out of the 9-workflow CI install.
- **`install --ci --workflows=<csv|all|none>` flag** — Granular workflow selection on the CI installer. `all` (default) installs every template (backward-compatible with no-flag); `none` skips workflows entirely but still vendors `doc-tools.sh`; CSV (e.g. `--workflows=doc-pr-release,doc-index-update`) installs only the listed templates. Unknown workflow names abort with the full valid set listed. Pairs with `--helpers=<true|false>` (default `true`) to opt out of `doc-pr-release` shell helpers + `RELEASE-NOTES.next/README.md` for "bring your own helpers" cases.
- **State-tracking for prior install decisions (`scripts/hooks/state.sh`)** — Install state is persisted at `.claude/doc-superpowers/installed.json` (committed to the repo so choices propagate across contributors). Schema versioned (`schema_version: 1`). First install on a repo with no state file infers state from filesystem (migration path). Subsequent `install --ci` (no `--workflows=` flag) skips workflows whose state is `uninstalled` with `intentional:true` — emits `skipping <name>.yml (previously uninstalled; pass --workflows=<name> to override, or --force)`. `uninstall --ci` marks `intentional:true`; `--transient` flips it to `false` so the next install re-installs. `--force` on install bypasses the state-respect check. Malformed state file → graceful fallback to filesystem inference + one-line WARN. State writes are atomic (jq + tmp + mv). Canonical workflow list is derived from `scripts/hooks/ci/*.yml` so new templates are picked up automatically. Single-writer concurrency contract documented — wrap parallel installer invocations in `flock` if your runner needs this.
- **`status --ci` surfaces per-workflow state** — Each workflow line now shows `installed`, `uninstalled (intentional)`, `uninstalled (transient)`, or `not installed`. Helpers + vendored `doc-tools.sh` presence + state file path are also reported. One jq invocation per workflow (state + intentional read together).

### Changed
- **`install_ci` and `uninstall_ci` are now workflow-set aware** — Both honor `--workflows=<csv>` to target a specific subset. Vendored `doc-tools.sh` removal on `uninstall --ci` only happens on a full (no-`--workflows=` or `all`) uninstall — partial uninstalls keep the bundled CLI in place. Explicit `--workflows=<name>` always beats state-respect — explicit > implicit.
- **SKILL.md "Detect Bundled Tooling" documents path precedence** — With `tools install` landing, three valid paths to `doc-tools.sh` can coexist (plugin cache for local sessions, project-vendored for CI, plugin source for doc-superpowers itself). The recommended resolution order is documented in the skill.

### Fixes
- **`_tools_uninstall` short-circuit propagated exit 1 in subshell capture** — The function ended with `[[ "$removed" -eq 0 ]] && echo "Nothing to uninstall …"` whose short-circuit propagated a falsy exit code when `removed != 0`. Converted to an `if`-block + explicit `return 0` so `output=$(... tools uninstall)` captures exit 0 on success.
- **bash 3.2 empty-array crash on `--workflows=none`** (`install.sh`) — `"${install_set[@]}"` / `"${uninstall_set[@]}"` under `set -u` raised "unbound variable" on macOS's default `/bin/bash` (3.2.57) when the array was empty. Guarded all four expansion sites with `${arr[@]+"${arr[@]}"}` / `[[ ${#arr[@]} -gt 0 ]]`. Smoke-tested under `/bin/bash 3.2.57`: both `install --ci --workflows=none` and `uninstall --ci --workflows=none` now exit 0 cleanly.
- **`_tools_extract_version` failed for vendored copies** (`doc-tools.sh`) — Original lookup at `$(dirname "$SCRIPT_DIR")/RELEASE-NOTES.md` only resolved for the canonical plugin layout. Falls back to `git rev-parse --show-toplevel`/`RELEASE-NOTES.md` for vendored copies; returns "unknown" cleanly when neither path works.
- **`state_bootstrap` silent dependency on `is_doc_superpowers_workflow`** — Caller-defined function dependency was a load-order coupling with no assertion. Now fails loudly via `declare -F` check if the function isn't defined.

### Other
- **Test harness expansions** — `scripts/test-hooks.sh` grows from 240 → 302 assertions (24 new tests for granular install + state-tracking + the bash-3.2 empty-array path; 1 new test for `uninstall --ci --workflows=none`; 1 test now sources `state_known_workflows` from `state.sh` instead of duplicating the workflow list to remove drift risk). `scripts/test-doc-tools.sh` grows from 100 → 134 assertions covering the `tools install/uninstall/status` subcommand. All four suites green: 302 + 134 + 32 (test-doc-pr-release) + 19 (test-merge-driver) = 487 assertions.
- **Living docs refreshed** — `docs/architecture/system-overview.md`, `docs/codebase-guide.md`, `docs/workflows/doc-superpowers.md`, and `docs/guides/getting-started.md` updated to describe the new flags, state-file semantics, and the `tools` subcommand. Status notes added to 4 superseded plans/specs. `docs/plans/2026-05-16-audit-report.md` captures the audit that drove these updates. `check-freshness` reports 28 current / 0 stale post-update.

## v2.11.0 (2026-05-16)

Adds two new `doc-tools.sh` subcommands for tracking ADR/SPEC realization through code, plus an `update-index` extension that captures the new YAML fields into the doc-index. Supports the orthogonal-implementation-metadata convention (decision lifecycle in `Status:` stays canonical 4-state for ADRs / 5-state for SPECs; realization lifecycle moves to a separate `Implementation:` / `Realized-by:` YAML list with a 7-state per-ref status enum).

### Features
- **`implementation-status [--filter <enum>] <path>...`**: Parse the `Implementation:` (ADR convention) or `Realized-by:` (SPEC convention) YAML block from one or more docs and emit each bullet, optionally filtered by per-ref status (`complete | partial | in-progress | not-started | reverted | superseded | blocked`). Handles the `Implementation: []` empty-list sentinel ("intentionally empty"), missing-field ("no Implementation field"), and missing-file ("not found") cases distinctly.
- **`set-implementation <path> --ref <kind: ref> --status <enum> [--note <txt>]`**: Append or update a single bullet in the Implementation/Realized-by block. Creates the block after the `**Date:**` line if absent. Validates `--status` against the 7-state enum (exit 2 on invalid). If the `--ref` already exists, replaces that line in-place — does NOT duplicate. Uses the new `gnu_sed` helper for cross-platform macOS (`gsed` preferred) / Linux (`sed` fallback when GNU) portability; errors with a clear install hint when neither is available.
- **`update-index` captures Implementation/Realized-by**: Each ADR/SPEC entry in `docs/.doc-index.json` now carries an `implementation` array parsed from the YAML frontmatter field, enabling downstream consumers (validators, doc-audit) to read realization state from the index without re-parsing the markdown.

### Other
- **doc-index schema bump `version: 1` → `schema_version: 2`**: Renamed the top-level field because only test helpers consumed the old `version` key — live consumers walk the `docs:` map directly. Test fixtures updated in lockstep; no live code paths needed changes.
- **Test harness expansion**: `scripts/test-doc-tools.sh` adds 7 new tests (+13 assertions) covering all three new code paths — `implementation-status` (parse / filter / missing-field), `set-implementation` (create / append / replace / invalid-status), and `update-index` (`implementation`-array capture). Total assertions: 113.

## v2.10.0 (2026-05-12)

This release lands both halves of the per-PR release-notes fragment lifecycle in one shot — the producer-side CI workflow that drafts and maintains a `RELEASE-NOTES.next/PR-<N>.md` for every open PR, and the consumer-side `release` action that merges and cleans up those fragments at release time.

### Features
- **Per-PR release-notes fragment producer**: New `doc-pr-release.yml` CI workflow template (installed by `--ci` tier) drafts and maintains a `RELEASE-NOTES.next/PR-<N>.md` fragment for every open PR. On each push, an AI step rewrites the fragment in Keep-a-Changelog format and syncs a managed `<!-- doc-superpowers:start/end -->` section in the PR body. Fragments use a SHA-256 hash on line 2 over the bytes from line 3 onwards so human edits are detected and never silently overwritten — the workflow comments on the PR asking for reconciliation instead.
- **`release` action consumes per-PR fragments**: The `/doc-superpowers release` action now globs `RELEASE-NOTES.next/PR-*.md`, validates each fragment's SHA-256 hash against its line-3-onwards payload, merges sections in Keep-a-Changelog canonical order with ascending integer-N ordering, and deletes consumed fragments in the same commit as the new version entry. Drifted hashes (human edits) emit a warning but are still merged — human edits are authoritative. Fragments whose introducing commit is outside the release range are skipped via `git merge-base --is-ancestor`. Non-canonical headings (e.g. `### Notes`, `### Breaking Changes`) are preserved in first-seen order after the canonical sections; bullets are deduped within each section.
- **New `doc-tools.sh fragments` subcommand**: Three verbs — `fragments list` (JSON enumeration with hash validity; skips non-numeric `PR-*.md` filenames with a warning), `fragments validate <path>` (exit 0 valid / 1 drifted / 2 missing), `fragments merge <start> <end> [--paths-out=<file>]` (markdown sections ready to insert under a `## vX.Y.Z` header; `--paths-out` records exactly which fragments were consumed so the release step can `git rm` only those, never destroying fragments belonging to still-open PRs). Encapsulates fragment-parsing in deterministic shell so the AI drafting step doesn't re-implement hashing or parsing in the prompt.
- **Three colocated shell helpers for the producer workflow**: `extract-context.sh` emits a JSON context blob (PR body, existing fragment, full and new commit ranges); `update-pr-body.sh` idempotently merges a managed section into the PR body with marker-injection, CRLF, and trailing-newline hardening; `commit-and-push.sh` stages, commits with a `[doc-superpowers]` prefix, and pushes the fragment back to the PR branch. The installer copies them to `.github/scripts/doc-pr-release/` alongside the workflow.
- **Fragment-format spec installed in consuming repos**: `hooks install --ci` now also drops a `RELEASE-NOTES.next/README.md` into the consuming repo (only if missing — never overwritten) that documents the fragment lifecycle, marker conventions, and the SHA-256 manual-edit protocol. Both halves of the lifecycle adhere to this format.
- **Unified Anthropic auth across all 6 AI workflows**: Every AI workflow (`doc-pr-release`, `doc-release`, `doc-review-pr`, `doc-audit-update`, `doc-spec-verify`, `doc-pr-full-cycle`) now resolves auth through a uniform preflight step: prefers `CLAUDE_CODE_OAUTH_TOKEN`, falls back to `ANTHROPIC_API_KEY`, fails fast with a clear error when both are unset, and emits a `::notice::` when both are set so the precedence is visible. The installer's secret-reminder lists both options with precedence documented.
- **Defense-in-depth recursion + verification guards on `doc-pr-release`**: `concurrency.cancel-in-progress` is now `false` so cancellation between `git commit` and `git push` can't leave orphan commits. A sentinel-commit check at the top of the workflow short-circuits when the head commit is the bot's own `[doc-superpowers] sync PR-<N>` — defending against `paths-ignore` gaps. A post-Claude verification step fails the workflow if the agent silent-skips (no sync commit AND no fragment on disk). An inline comment near the checkout step documents why `GITHUB_TOKEN` (not a PAT) is correct here.

### Fixes
- **Marker-count bug in `update-pr-body.sh` (`grep -oF` → `grep -cFx`)**: The validation count is now line-anchored so it agrees with the awk replace path (`$0 == start`). Previously, a mid-line marker in user prose would pass the count check, awk would no-op the replace, and a fresh managed section would be appended — leaving the stray marker stranded. Added a belt-and-suspenders any-occurrence vs line-occurrence comparison that fails closed on any mismatch.
- **Non-fast-forward push handling in `commit-and-push.sh`**: Push rejection now triggers `git fetch origin <branch>` and `git rebase origin/<branch>` (configurable retries, default 2). No force-push is used — concurrent human commits are preserved, not overwritten. Rebase conflicts fail loudly rather than guessing how to resolve.
- **Corrupted-fragment detection in `extract-context.sh`**: New `existing_fragment_corrupt` JSON field flags fragments that are missing markers, have fewer than 3 lines, or exceed 1 MiB (OOM protection against a malicious mega-fragment). The agent prompt teaches the same human-edit-detected branch for corrupt fragments: post a PR comment, do not auto-overwrite.
- **Trailing-newline drift in `update-pr-body.sh`**: A PR body with multiple trailing newlines is now trimmed to exactly one blank-line separator before the managed section, avoiding stacked blank lines on repeated edits.

### Other
- **Test harness expansions**: `scripts/test-doc-pr-release.sh` adds 32 assertions (up from 25) covering mid-line marker rejection, trailing-whitespace handling, corrupted/oversized/well-formed fragment detection, non-fast-forward push with rebase retry (origin/clone-a/clone-b fixture), and workflow YAML placeholder substitution. `scripts/test-doc-tools.sh` adds 10 new tests covering the `fragments` subcommand — list (empty / valid / non-numeric filename), validate (drifted), merge (ascending-N order, drifted-include, non-canonical headings, bullet dedup, `--paths-out`, outside-git-repo guard) — bringing total `test-doc-tools.sh` assertions to 100. Both suites use `trap … EXIT` / per-test setup-teardown for tempdir cleanup.
- **Installer hardening for the helper tier**: `install_ci`, `uninstall_ci`, and `status_ci` know about `doc-pr-release.yml` and the helper subdirectory. Uninstall removes the workflow and helpers but intentionally preserves `RELEASE-NOTES.next/README.md` (since the directory may carry unmerged fragments). The helper-glob convention (`*.sh` only) is now documented inline so future non-shell helpers can't be silent-skipped.
- **Consumer-contract tightening in `RELEASE-NOTES.next.README.md`**: The ancestry-detection step for skipping unlanded fragments is now a concrete `git merge-base --is-ancestor` recipe rather than hand-wavy prose.

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
