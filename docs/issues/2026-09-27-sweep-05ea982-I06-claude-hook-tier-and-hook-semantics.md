---
date: 2026-09-27
status: Open
priority: P1
type: bug
component: hooks
source: sweep-skill
cluster-key: sweep-skill:full-repo:I-6
run-id: 05ea982
related-files:
  - scripts/hooks/claude/pre-commit-gate.sh
  - scripts/hooks/claude/post-commit-sync.sh
  - scripts/hooks/claude/session-summary.sh
  - scripts/hooks/git/pre-commit
  - scripts/hooks/git/prepare-commit-msg
  - scripts/hooks/git/post-merge
  - scripts/hooks/git/post-checkout
  - scripts/hooks/git/pre-push
  - scripts/hooks/install.sh
  - scripts/test-hooks.sh
  - README.md
  - docs/codebase-guide.md
  - docs/workflows/doc-superpowers.md
screenshots: null
axiom-agent: null
branch: null
design-doc: null
report: docs/plans/2026-09-27-full-repo-05ea982-audit-findings.md
---

# I-6 — The Claude Code hook tier has never activated, and the git hooks misjudge the commit being made

> Cluster **I-6** of sweep run `05ea982`, ranked #4 of 14. Evidence:
> [findings index](../plans/2026-09-27-full-repo-05ea982-audit-findings.md) (S5, S9). Fix:
> **Task 7** of the [fix plan](../plans/2026-09-27-full-repo-05ea982-fix-plan.md).

## Summary

The Claude Code hooks were written against an assumed harness contract, not the documented one:
- they read a `$TOOL_INPUT` environment variable that Claude Code never sets (hook input arrives as
  JSON on **stdin**, at `.tool_input.command`);
- they write their reports to stdout, which for PreToolUse/PostToolUse/Stop goes only to the debug
  log.

So the gate and the sync hook have never fired. When STRICT blocks a commit, it gives no reason. The
"session summary" runs a full freshness walk after **every turn**.

The git hooks have their own problems:
- they evaluate freshness at HEAD, so they cannot see the commit being made;
- `prepare-commit-msg` appends `#` lines to non-editor commits, and git keeps them.

## Incorrect assumption

**A4:** "Hook input arrives in `$TOOL_INPUT`; hook stdout reaches someone; Stop means session end;
freshness at HEAD reflects the commit being made."

## Verified evidence

- [P1] `claude/pre-commit-gate.sh:14-23`, `post-commit-sync.sh:13-22` (and the `.claude/hooks/`
  copies) read `$TOOL_INPUT` and the wrong JSON path `.command`. Driven through the exact
  registered settings wrapper, gate and sync **never activate**. Measured.
- [P1] `claude/*.sh`: output channel defects. Measured.
  - Reports go to stdout, which lands only in the debug log.
  - STRICT exits 2 with **empty stderr**, so the commit is blocked without a reason.
  - `session-summary` says "session ending", but Stop fires every turn.
- [P1] `git/prepare-commit-msg:7-10,29-39` appends `#` lines regardless of how the message was
  supplied. Measured.
  - With `-m`, `-F` or `--amend --no-edit`, git does not strip them, so they are committed.
  - 28 of this repo's own commit messages contain them. The HEAD~1 commit message ends with
    `# Doc freshness: 1 stale doc(s)…`.
- [P2] `git/pre-commit:16-31`, `prepare-commit-msg:15-26`, `claude/pre-commit-gate.sh:29-41`
  evaluate freshness at HEAD. The commit that makes a doc stale passes, and under STRICT the next
  one is blocked. Root cause is in I-1; the fix here passes the staged tree.
- [P2] `claude/session-summary.sh:16-32,47` runs an unscoped full walk with a 1 s budget and says
  nothing on timeout. It adds ≈1 s to every turn.
- [P2] All hooks treat "tooling failing" the same as "tooling absent" (`2>/dev/null) || exit 0`).
  A conflicted index therefore silently disables STRICT.
- [P2] `git/post-merge:18`, `post-checkout:22` run `git diff --name-only` without `--no-renames`.
  A doc that cites the *old* path of a moved file is never in scope.
- [P2] `claude/post-commit-sync.sh:28`, `session-summary.sh:36-45`: the "auto-refresh" call is
  `update-index` with no arguments, which always exits 1 and has been dead since it was written.
  **Remove it; do not make it work.** A working version would mark every doc verified without
  anyone reading it (I-3).
- [P2] `install.sh:323-330` registers Claude hook commands that `cd` to the toplevel of the
  *current* directory and run a relative path, so a nested repo's copy runs. Use
  `$CLAUDE_PROJECT_DIR` instead.
- [P3] Smaller defects:
  - `post-merge` reports whole-index `untracked` on every merge.
  - `post-checkout:41,49` joins with a trailing comma.
  - The `session-summary` macOS fallback holds stdout ≥1 s and uses a predictable `/tmp` path.
  - `pre-push` ignores the refs being pushed and has no DOC_TOOLS guard.
  - The scope filter is O(N·F·R): 4.5 s at N=4,019 × 500 files.
  - The gate and sync hooks spawn ≈8 processes (≈17 ms) on *every* Bash tool call before deciding
    "not a commit". Carried from Phase 2, not re-verified in Phase 3.

## Proposed fix (fix plan Task 7)

**Claude hooks:**
- Read stdin with `jq -r '.tool_input.command // empty'`.
- Match `git … commit` with a POSIX regex *before* resolving DOC_TOOLS.
- Report through `hookSpecificOutput.additionalContext` / `systemMessage` JSON. Put the STRICT reason
  on stderr.
- Remove the `update-index` calls.
- Scope the Stop hook to working-tree changes, or move it to `SessionEnd`.

**Git hooks:**
- `pre-commit` runs `check-freshness --tree "$(git write-tree)" --code-refs-from -`.
- `prepare-commit-msg` acts only for editor commits (`$2` empty or `template`).
- Add `--no-renames -c core.quotePath=false` to every diff.
- `pre-push` reads the pushed refs from stdin.
- Drop the undocumented `DOC_INDEX` knob.

**All hooks:** "tooling absent" stays silent; "tooling failing" prints one stderr line.

## Acceptance criteria

- [ ] Tests drive the **installed** hook through its **registered** command string, with
  `TOOL_INPUT` unset and the real PreToolUse JSON on stdin.
- [ ] The gate reports. STRICT exits 2 with the reason on stderr.
- [ ] The index is byte-identical after every hook.
- [ ] `git commit -m x` never gains `#` lines.
- [ ] A staged invalidating change is reported in *that* commit.
- [ ] `git mv` of a code file puts the doc citing the old path in scope.
- [ ] README hook table, `docs/workflows/doc-superpowers.md` and `docs/codebase-guide.md` no longer
  claim the hooks "auto-run update-index".

## Related

- I-13: the test suite injects `TOOL_INPUT`, so it passes today and *rejects* the correct fix.
- I-7: installer registration and placement.
- I-14: this repo's own Claude tier is pinned to `/Users/w/…` paths.
- Refutes the stated cause in `2026-05-04-doc-index-metadata-rewrite-on-every-commit.md`.
