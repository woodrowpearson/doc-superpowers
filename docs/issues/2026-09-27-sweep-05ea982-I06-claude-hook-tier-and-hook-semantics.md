---
date: 2026-09-27
status: Resolved
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

- [P3, new: FU4/V-FU4, measured] `claude/pre-commit-gate.sh:29-30`: PreToolUse derives scope from
  `git diff --cached` *before* the command runs. A typical agent `git add … && git commit -m …` or
  `git commit -am …` therefore sees an empty index. Under STRICT, both return rc 0 and print
  nothing; the same change pre-staged gives rc 2. This is latent behind the `TOOL_INPUT` P1 and
  survives that fix. The fix is to parse `-a`/pathspecs, or to rely on the git `pre-commit` hook,
  which sees the real index.
- [P3, FU4/V-FU4, structural] On macOS ≤14, GUI git clients run hooks with the launchd PATH
  (`/usr/bin:/bin:…`), so Homebrew `jq` is invisible. `check_deps` then exits 1, and `|| exit 0`
  silently removes the gate, STRICT included. The silent part is this issue's "failing == absent"
  class; the PATH trigger is new. macOS 15 ships `/usr/bin/jq`.
- [P4, FU4/V-FU4, measured] `claude/post-commit-sync.sh:31`: the "initial commit" fallback
  `git diff-tree --no-commit-id --name-only -r HEAD` prints nothing without `--root`. The tier is
  currently dead anyway.
- Clean (FU4/V-FU4): the git and Claude hooks contain no bash-4 syntax and no `set -u` empty-array
  risk. The static bash-4 guard covers all 15 shell files under `scripts/hooks/`, but checks syntax
  only, not GNU-only commands. `\b`/`\s` in `grep -E` work on GNU and macOS grep, and OpenBSD is not
  a stated target. All portability verdicts are structural.


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

- [x] Tests drive the **installed** hook through its **registered** command string, with
  `TOOL_INPUT` unset and the real PreToolUse JSON on stdin.
- [x] The gate reports. STRICT exits 2 with the reason on stderr.
- [x] The index is byte-identical after every hook.
- [x] `git commit -m x` never gains `#` lines.
- [x] A staged invalidating change is reported in *that* commit.
- [x] `git mv` of a code file puts the doc citing the old path in scope.
- [x] README hook table, `docs/workflows/doc-superpowers.md` and `docs/codebase-guide.md` no longer
  claim the hooks "auto-run update-index".

## Resolution (Task 7)

Resolved by Task 7 of the fix plan. The hooks are written against the harness contracts as
documented, and every test drives the **installed** copy the way its caller does. The git hooks
run under real `git commit` / `merge` / `checkout`. The Claude hooks run through the command
string the installer registered: `sh -c <command>`, the event JSON on stdin, `TOOL_INPUT` unset.
The `TOOL_INPUT` tests were converted, not kept. Of the new assertions, 68 failed against the old
hooks.

**Claude Code hooks**

- **Input.** Each hook reads the event on stdin, and the command is
  `jq -r '.tool_input.command // empty'`. A `*commit*` pattern test needs no process, and the POSIX
  regex `git([[:space:]]+-[Cc][[:space:]]+[^[:space:]]+)*[[:space:]]+commit([[:space:]]|$)`
  (bash `=~`) runs *before* `doc-tools.sh` is resolved. A non-commit Bash call starts at most one
  process, `jq`. A test with a `sort` probe pins the order. `git -C <dir> commit` and
  `git -c k=v commit` match; `git commit-graph` does not.
- **Output.**
  - The advisory is ONE JSON object: `hookSpecificOutput.additionalContext` for Claude and
    `systemMessage` for the user.
  - Under STRICT the gate exits 2 with the report and the bypass on stderr.
  - QUIET still silences the output, never the exit code (README:206).
- **Commands that stage (V-FU4).** These are `git add … && git commit`, `commit -a/-am`, a `--`
  pathspec, another index-changing git command, and `update-index` before the commit. The gate
  **defers** them to the git `pre-commit` hook, which runs on the real index. Its
  `additionalContext` says so and never reports "current". When no doc-superpowers git pre-commit
  hook is installed, it says that nothing checks the commit, and under STRICT it tells the user
  too. The installed git hook then blocks `git add -A && git commit` and `commit -am` under
  STRICT (tested end to end).
- **`update-index` is deleted** from `post-commit-sync.sh` and `session-summary.sh`, not repaired.
  A wrapper that logs every doc-tools subcommand the three hooks run records `check-freshness`
  only.
- **Stop, not SessionEnd.** Current Claude Code docs say Stop fires whenever Claude finishes
  responding. SessionEnd hooks share a 1.5 s budget and their output reaches no one. So the
  reminder stays on Stop, scoped to what is in progress:
  - The scope is `git diff --name-only --no-renames HEAD` plus untracked files.
  - The paths are judged **as the working tree holds them**: a private copy of git's index,
    `add -A`, then `write-tree`. A doc re-verified with `update-index` in the working tree reads
    current; judged at HEAD it would read stale.
  - A clean tree costs two git calls and prints nothing. The "session ending" wording is gone.
  - The check has a 2 s budget, in its own process group (`set -m`) with a watchdog that kills the
    group. Both jobs write to a `mktemp -d` directory, so the hook's stdout is never held open. A
    timeout leaves a one-line `systemMessage`.
  - There is one implementation, with no `timeout`/`gtimeout` branches, so the tested path is the
    shipped path on every platform.
- **Root commit.** `post-commit-sync` falls back to `git diff-tree --root` (V-FU4 P4).

**Git hooks**

- **`pre-commit`** runs `check-freshness --tree "$(git write-tree)" --code-refs-from -` on the
  staged paths. Git hands the hook the commit's own index, also for `-a` and pathspec commits. A
  staged invalidating change is reported (or blocked) in *that* commit, and code + doc +
  `update-index` in one commit passes under STRICT.
- **`prepare-commit-msg`** acts only when `$2` is empty or `template`. It stays silent under a
  non-strip `commit.cleanup` and under `core.commentChar=auto`, and uses a custom comment string
  when one is set. Its block says the docs are **already stale** in this commit. `-m`, `-F` and
  `--amend --no-edit` commits carry no `#` lines (tested; an editor commit shows the note and git
  strips it).
- **Diffs.** Every `git diff --name-only` is `git -c core.quotePath=false diff --name-only
  --no-renames`, so a `git mv` puts the doc citing the old path in scope, in `pre-commit` and in
  `post-merge`.
- **`post-merge`** no longer reports the whole index's `untracked` docs.
- **`post-checkout`** prints its list without a trailing comma.
- **`pre-push`** reads the pushed refs from stdin, skipping tags and deletions. It counts per pushed
  branch, not HEAD, and has the DOC_TOOLS guard.
- **`DOC_INDEX` is gone.** The index is `docs/.doc-index.json`.

**All hooks: absent vs failing.** When the skill or `docs/.doc-index.json` is absent, the hooks stay
silent. When the check fails, the hook prints one line naming the cause: a corrupt index, or jq
missing from PATH, as under the launchd PATH of macOS ≤ 14 GUI clients (tested with a PATH without
jq). That covers the jq-floor message from T2 too. Claude hooks also send the line as a
`systemMessage`, because Claude Code shows no one the stderr of an exit-0 hook. The failure
blocks only under STRICT. The `prepare-commit-msg` hook writes it as one comment line instead, so
an editor commit does not print it twice.

**Left for other Tasks**

- `install.sh` still registers commands that `cd` to the current toplevel and run a relative path.
  `$CLAUDE_PROJECT_DIR` is T8. The `sort -V` DOC_TOOLS resolution is also T8.
- This repo's own `.claude/hooks/doc-superpowers/` copies and `.git/hooks` are re-rendered by T14
  (dogfooding).
- The O(N·F·R) scope filter (P3) is unchanged.

## Related

- I-13: the test suite injects `TOOL_INPUT`, so it passes today and *rejects* the correct fix.
- I-7: installer registration and placement.
- I-14: this repo's own Claude tier is pinned to `/Users/w/…` paths.
- Refutes the stated cause in `2026-05-04-doc-index-metadata-rewrite-on-every-commit.md`.
