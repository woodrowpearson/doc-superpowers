---
date: 2026-09-28
status: Open
priority: P2
type: enhancement
component: shared
source: sweep-skill
cluster-key: sweep-skill:full-repo:followups
run-id: 05ea982
related-files:
  - scripts/doc-tools.sh
  - scripts/merge-doc-index.sh
  - scripts/test-helpers.sh
  - scripts/hooks/install.sh
  - scripts/hooks/git/pre-commit
  - scripts/hooks/claude/pre-commit-gate.sh
  - scripts/hooks/ci/doc-pr-release/commit-and-push.sh
  - scripts/hooks/ci/doc-pr-release/update-pr-body.sh
  - scripts/hooks/ci/doc-superpowers-steps/precheck.sh
  - scripts/hooks/ci/doc-superpowers-steps/commit-changes.sh
  - scripts/hooks/ci/doc-pr-release.yml
  - scripts/test-spec-status-model.sh
  - .github/workflows/tests.yml
  - references/doc-spec.md
  - references/hooks.md
  - references/release.md
screenshots: null
axiom-agent: null
branch: claude/resume-plan-execution-03646c
design-doc: null
report: null
---

## Summary

Sweep 05ea982 (Tasks T1–T14 on `claude/resume-plan-execution-03646c`) ended with a
five-seat whole-branch review and one fix wave (finished on
`claude/2026-09-27-repo-handoff-4b960b`). Everything the seats triaged as
"fix-later", every item that can only be proven by a real GitHub Actions run or a
real non-Claude client, and the three findings the controller deferred (ruling
F8) are listed here, one line each with its source, so none of them is lost with
the sweep's git-ignored ledger. Sources: `deferred N` is the line number in the
sweep ledger's deferred list; `seat N` the review seat (1 core tools, 2
installer + hooks, 3 CI, 4 prompt + packaging, 5 living docs); `F8` the
controller's deferral ruling; `re-review seat A/B/C/D` the scoped re-review of the fix
wave (A core + installer, B CI, C prompt layer, D living docs), whose parked items
(ruling R-RR2) are listed here too.

## CI-return (needs a real Actions run)

- The CI matrix (ubuntu bash 5 / macOS bash 3.2) has never run on this branch: Actions was billing-locked; every verdict so far is from the local two-interpreter runs. (deferred 277; seats 3, 4)
- One real run per AI template: plugin install from the local marketplace path, `--allowedTools` patterns, tag-mode checkout, PR creation with the job token. (deferred 296; seats 3, 4)
- claude-code-action tag mode: how it merges `--allowedTools` with its own tools, whether it checks out the PR branch under `contents: read`, the Skill-tool `/doc-superpowers` invocation under `claude -p`, and whether the action writes files into the workspace (the commit checker would refuse them). (deferred 304; seats 3, 4)
- Agent Bash permission matching for `fragments merge … --remove`, and the exact `head_commit.message` forms GitHub produces for squash and merge commits. (deferred 334, 344; seats 3, 4)
- `--force-with-lease` against GitHub in `commit-and-push.sh`. (deferred 344; seat 3)
- Prefix matching of piped commands (`git diff -z … | .github/scripts/doc-tools.sh check-freshness --code-refs-from -`, `… | jq`) and `${CLAUDE_SKILL_DIR}` substitution for an action-installed plugin. (deferred 370; seats 3, 4)
- The fix wave's CI changes have run only locally: the `tests.yml` drift step (`if: ${{ !cancelled() }}`, the retired-workflow check, the `install --git` summary) by extracting and running its body; `doc-pr-release`'s dispatch refusal of a fork PR (`gh pr view --json isCrossRepository`) and `commit-and-push.sh`'s `fragments list` pre-check through shims and fixtures. (final fix wave; seat 3)
- `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB: "1"` on the action steps (documented as recommended hardening in `references/hooks.md`, not set in the templates): confirm `gh` still authenticates under it before setting it by default. (ruling F1; seat 3 S-I1)
- The release flow: the AI templates install the plugin from tag `v<version>`, so tag `v3.0.0` must exist on GitHub when v3.0.0 ships. (deferred 297; seat 3)

## Real-client checks (Cursor / Codex / Gemini)

- Cursor: the local install path, and whether Cursor loads `.claude/settings.local.json` (its docs name only `.claude/settings.json`). (deferred 279, 383; seat 4)
- Codex: skill discovery through the `~/.agents/skills` symlink. (deferred 383; seat 4)
- Gemini CLI: whether `read_file` reaches `$ROOT/references/`. (deferred 383; seat 4)

## Fix-later: code and tests

- Worktrees: `uninstall --claude` in one worktree removes the shared `info/exclude` block, so the other worktrees' per-user files show as `??` while their `status` says ✓. Keep the block while any worktree in `git worktree list` has the tier; `status_claude` should check `git check-ignore`. (F8: seat 2 H-M1)
- One symlinked host hook (`.git/hooks/pre-commit -> ../../scripts/pre-commit`) refuses the whole git tier (`safe_dest`); skip that hook with guidance, install the rest, never write through the link. (F8: seat 2 H-M3)
- `bash_bin_shim` names shims by basename: shimming `scripts/doc-tools.sh` and `.github/scripts/doc-tools.sh` in one suite would collide (none does today). (F8: seat 1 C-M8)
- `update-index … >/dev/null` at `set -e` sites in `test-doc-tools.sh` aborts the suite without a FAIL line. (deferred 69; seat 1)
- `test_workflow_helper_wiring` can pass vacuously; its `step=$(jq …)` is not tolerant. (deferred 70; seat 3)
- The global-`core.hooksPath` harness test covers `setup()` only, not source-time isolation. (deferred 75; seat 1)
- SIGINT delivery is covered only statically for doc-tools writers; add a `set -m` subshell test. (deferred 100; seat 1)
- In a consumer repository nothing git-ignores `docs/.doc-index.json.lock*` and `.tmp.*` (this repository's `.gitignore` does): a killed writer's leftovers show as untracked. (deferred 102; seat 1)
- The lock diagnostics: the `mkdir && rmdir` probe can die with a reasonless "cannot create lock"; the timeout says "held by running pid N" when `.lock.break` is the stuck one. (deferred 111; seat 1)
- Legacy un-normalized keys (`docs//x.md`, `-…`) are unaddressable after argument normalization: add a raw-key fallback or a migration. (deferred 128; seat 1)
- Scale-test budgets are thin in places; prefer a ratio assertion to absolute seconds. (deferred 145; seat 1)
- `_wt_stage`'s fallback re-adds every ref one by one when one path is refused; pre-filter with `check-ignore --stdin -z`. (deferred 146; seat 1)
- The untracked-path warning is printed once per run without naming the owning doc. (deferred 152; seat 1)
- `update-index` uses `_entry_facts 0`, so the "recorded missing" warning never fires there (only on build-index / add-entry). (deferred 155; seat 1)
- `_entry_facts` warns on unmatched refs for a pure reorder; a kept legacy glob ref silently becomes a literal missing one; a no-op does not repair a missing `code_oids` key; no test for a legacy kept ref absent from the `code_commit` tree. (deferred 176; seat 1)
- jq 1.6 (the documented floor) has never been executed against the suites. (deferred 197; seat 1)
- Merge driver: `cp "$OURS" "$KEEP"` killed mid-copy leaves a truncated ours hunk; assign `KEEP` after the copy. (deferred 202; seat 1)
- `assert_ways_conflict` does not check `git ls-files -u`. (deferred 205; seat 1)
- Hook tests run the pre-push/post-checkout templates rather than a real push / installed hook; `--amend` with nothing staged is not re-checked; no pre-merge-commit hook for clean `--no-ff` merges; Stop's `add -A` leaves unreachable objects. (deferred 219; seat 2)
- The gate's commit regex: `(then|do|else)` lacks a word boundary ("undo git commit" matches), and some command forms (`git --no-pager commit`, `env X=1`, `time`, `if`, `!`, `commit;`) are false negatives that fall back to the git tier. (deferred 226; seat 2)
- The rest of deferred 227 (its scope part — the entries a staged index adds — landed in the fix wave): the gate's `re_stages` is unanchored (a mere mention such as `echo git add` defers the commit to the git tier), and its no-jq fallback regex over-captures the command field. (deferred 227; seat 2)
- A report/gate comment claims a split index cannot be copied (not reproducible). (deferred 228; seat 2)
- `tools install --with-helpers` ships both helper dirs always (the installer ships per workflow); `tools uninstall` keeps a copy from an older plugin version (no longer `cmp`-equal). (deferred 237; seats 1, 2)
- CRLF docs get LF-only inserted lines from `set-implementation` (mixed endings). (deferred 248; seat 1)
- `test-doc-tools.sh`'s `-name '*.XXXXXX'` alternative can never match (mktemp replaced the X's). (deferred 263; seat 1)
- `hooks_path_scope`'s fallback for git < 2.26 (exit 129 → `--local` compare) is untested. (deferred 278; seat 2)
- `uninstall --git` gives no guidance to remove hooks a pre-3.0 installer put in an unconfigured `.githooks/` (the README's *Upgrading from 2.x* now says it; the installer does not). (deferred 280; seat 2)
- `strip_blocks` adds a trailing newline to a host hook lacking one; a CRLF-shebang host hook is reported "not a shell script". (deferred 282; seat 2)
- Corrupt-state recovery works only for a plain install; `--workflows=all` reinstalls templates removed on purpose. (deferred 284; seats 2, 4)
- No up-front `command -v jq` in the installer: a missing jq is reported as an unreadable `installed.json` with advice to move it aside. (deferred 285; seat 2)
- The after-shebang block runs our pre-commit before the user's hook, so formatters / lint-staged that re-stage are judged on the pre-fix tree: document it. (deferred 286; seat 2)
- `safe_dest` (install.sh) and `_tools_no_link` (doc-tools.sh) are near-verbatim link walks, and `file_mode` is duplicated: add cross-reference comments, share a fixture. (deferred 287; seats 1, 2)
- `status` shows ✓ integrated for a host hook that is not executable (git skips it). (deferred 288; seat 2)
- `test_install_ci_malformed_state_file_falls_back_with_warn` asserts a refusal: rename it. (deferred 289; seat 2)
- `doc-release.yml`'s `--allow` manifest list duplicates doc-tools.sh's `VERSION_FILES` (it matches today; drift fails closed). (deferred 305; seats 3, 4)
- `fragments merge` ignores uncommitted fragment edits (it reads the `<range-end>` blobs), which surfaces only at `--remove` after drafting: warn at merge time. (deferred 342; seats 1, 3)
- The consumer's `is_item` treats any `N.` / `N)` line as a list item (CommonMark: only `1.` interrupts a paragraph), so a paragraph line starting "10. …" can be split and deduped. (deferred 351; seat 3)
- `set-code-refs --refs a,a` stores the ref twice (`["src/a.txt","src/a.txt"]`): dedupe the list as the doc paths are. (deferred 167; seat 1, re-review seat D)
- `move-entry`'s `Repointed` report reads `done < <(jq …)` without checking jq's exit (`cmd_move_entry`, doc-tools.sh ~:3426), so a jq failure there drops report lines silently. (deferred 167; seat 1, re-review seat D)
- `precheck.sh` parses RELEASE-NOTES.md headings with its own awk, which diverges from `_release_notes_version`: it skips a pre-release heading, and a `~~~` line inside a backtick fence ends its fence, exposing a fenced heading. Worst case a wasted AI run; a shared parser verb is a design change. (re-review seat B; ruling R-RR2)
- `commit-and-push.sh`: the `fragments list` pre-check (:161) sends its stderr to /dev/null, and the refusal's "Fix it, then push again" (:164) is wrong for a draft the agent has not committed. (re-review seat B; ruling R-RR2)
- `update-pr-body.sh`'s exit-code header says less than the script does: exit 1 also refuses a new section that contains a marker, and there are more malformed-marker cases than it names. (re-review seat B; ruling R-RR2)
- `tools uninstall` checks for a symlinked `RELEASE-NOTES.next` only after it has removed the helpers. (re-review seat A; ruling R-RR2)
- `_required` in `test-spec-status-model.sh` (the evals whose fixtures must build) is a hand-kept list: derive it from `.evals[] | select(.setup)`. (re-review seat C; ruling R-RR2)
- `set-doc-type` accepts, besides the documented types, any type the index already uses — so a typo already in the index is accepted. Deliberate (a project's own vocabulary; `add-entry` accepts any type); recorded so it is not re-reported. (re-review seat A; ruling R-RR2)
- The git and Claude hooks still list changed paths with `git -c core.quotePath=false diff --name-only` (git quotes a name holding `"`, a backslash or a tab even so, and a quoted name matches no ref); the CI scope step and the prompt layer switched to `git diff -z` in the fix wave, and `check-freshness --code-refs-from` takes a NUL-separated list, so the hooks can follow (a bash variable cannot hold NUL: pipe it). (final fix wave, S-M1 follow-on)
- `_doc_commits` accepts any `tr` status once awk exits 0 (the residual fix for a SIGPIPE inherited as ignored, where BSD `tr` exits 1). A `tr` killed by a signal mid-stream is then accepted too, and it silently truncates the walk: a fault-injected `tr` left a doc's baseline at HEAD, so the doc read current. Accept a non-zero `tr` only when every doc got its hit (or only `tr` ∈ {0, 1, 141}). (residual re-review; ruling R-RR3)
- The eval guard's `_skill_cmds` (`test-spec-status-model.sh`) treats any `git …` / `$DOC_TOOLS …` span in SKILL.md as a prescribed command, including one quoted in a "never" sentence, so a future prose example can fail the guard falsely. (residual re-review; ruling R-RR3)

## Fix-later: docs

- An unreadable doc now aborts the whole `check-freshness` run (`_hash_one` → `_die`): an undocumented behaviour change for the v3.0.0 notes. (deferred 130; seat 1)
- `doc-spec.md`: `content_hash` is null after `build-index` too, not only for a missing doc. (deferred 148; seat 4)
- The block-grammar end rule "any other line ends the block" is false for an indented line between the header and the first entry (doc-spec.md, doc-tools.sh `--help`, the I-10 issue). (deferred 262; seats 1, 4)
- `references/hooks.md`: the corrupt-state recovery advice is unqualified (it works only for a plain install). (deferred 284; seat 4)
- SKILL.md `review-pr`: step 3 gives only the local `< "$CHANGED"` form; when the caller names the range (a CI prompt) there is no `$CHANGED`, and the step does not point to the granted `git diff -z … | $DOC_TOOLS check-freshness --code-refs-from -` pipe from *Scoping by changed files*. Step 4's "git quotes an unusual name" understates it: without `core.quotePath=false`, git also octal-escapes non-ASCII names, and step 5 hands those to scope agents. (residual re-review; ruling R-RR3)
- This repository's own docs carry the agentic subgraph flowchart and multi-actor sequence inside `docs/workflows/doc-superpowers.md` (*Agentic Workflow*), not in the `docs/workflows/agentic/README.md` + `agentic/doc-superpowers.md` layout the Required Diagrams table prescribes. The content is present; moving it needs the owner's yes. The agentic sequence also declares an unused "General-Purpose Agent" participant. (diagram pass; rulings R-DG1, R-DG2)
- `references/release.md` step 2 has no rule for when `git log -1 -S '## vX.Y.Z'` finds no commit (a shallow or grafted history): say what the range start is then. (re-review seat C; ruling R-RR2)

## After merge (owner)

- This repository's shared `.git/hooks` and its `merge.doc-index.driver` registration (in the shared `.git/config`) still resolve another worktree's `scripts/`: the git tier was installed from a worktree during T14. After merging, run `scripts/hooks/install.sh install --git` from the main checkout. (deferred 396)

## Pulled into the final fix wave

Resolved there, listed so the ledger's numbers stay traceable: deferred 98 (lock owner EPERM), 122 (`log.showSignature` in `fragments merge`), 129 (`_warn_refs` reads `git ls-files -z`: fixed in the residual fix after the re-review), 166 (= C-M3), 167 (its `_INDEX_CHANGED` part, = C-M5; the other two parts are listed above), 189 (folded into README *Upgrading from 2.x*), 225 (= H-I2), 227 (its scope part: the entries a staged index adds), 264 (mawk ≥ 1.3.4), 281 (= H-M5 / P-M9), 318 (release branch per run attempt + the precheck regex), 352 (`update-pr-body.sh` header), 354 (= S-M6), 361 (= S-I1: no `jq` for the tag-mode job), 399 (SIGINT self-test), 405/406/407 (tests.yml drift step), 409 (writer timing budgets). The C4 container PNG was regenerated in the diagram pass after the audit (eea82fe), and the v3.0.0 entry and `bump-version 3.0.0` landed in the release commit (ruling R5).
