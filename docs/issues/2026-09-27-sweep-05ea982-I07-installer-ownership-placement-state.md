---
date: 2026-09-27
status: Open
priority: P1
type: bug
component: hooks
source: sweep-skill
cluster-key: sweep-skill:full-repo:I-7
run-id: 05ea982
related-files:
  - scripts/hooks/install.sh
  - scripts/hooks/state.sh
  - scripts/doc-tools.sh
  - scripts/test-hooks.sh
  - skills/doc-superpowers/SKILL.md
  - README.md
screenshots: null
axiom-agent: null
branch: null
design-doc: null
report: docs/plans/2026-09-27-full-repo-05ea982-audit-findings.md
---

# I-7 — Installer ownership, placement, host-hook integration and install state

> Cluster **I-7** of sweep run `05ea982`, ranked #9 of 14. Evidence:
> [findings index](../plans/2026-09-27-full-repo-05ea982-audit-findings.md) (S4, X-SHELL). Fix:
> **Task 8** of the [fix plan](../plans/2026-09-27-full-repo-05ea982-fix-plan.md).

## Summary

The installer works out *what it owns*, *where to write* and *what was installed* by guessing:
- **Ownership:** any settings hook group whose text contains `"doc-superpowers"` is treated as ours.
- **Placement:** assumes `.git` is a directory and that cwd is the repo top.
- **Integration:** assumes the host hook is written in bash.
- **Hook tool path:** assumes the skill's parent directory holds only plugin versions, and resolves
  the tool path by globbing it.
- **Writes:** writes through committed symlinks.
- **State:** records "installed" but not the choices, so a plain re-install (the upgrade path)
  silently changes configuration.

## Incorrect assumption

- "Any file mentioning doc-superpowers is ours."
- "`.git` is a directory and cwd is the top."
- "The host hook is bash."
- "The parent dir holds only plugin versions."
- "Recording 'installed' is enough to reproduce an install."

## Verified evidence (measured unless noted)

- [P1] **Hook-group deletion.** `install.sh:335-340,362-365` judges ownership of Claude settings by
  searching a hook **group** for the substring `"doc-superpowers"`.
  - Install and uninstall both delete user hook groups, including unrelated hooks that share a group.
  - `settings.local.json` is untracked, so the deletion cannot be recovered.
- [P1] **Integration block.** `install.sh:147-172` splices a bash-only block into an existing hook:
  - `#!/bin/sh` hooks fail with `[[: not found`;
  - the block drops `"$@"`, so integrated `prepare-commit-msg`/`post-checkout` never work;
  - it swallows STRICT;
  - in pre-commit-framework hooks it lands after `exec` and never runs.
- [P1] **Writes follow committed symlinks** (root cause not named in the Phase-5 draft; added after
  Phase-4 review).
  - Affected writes:
    - `install.sh:144,171,181,197-200,304,342,373,486,564-565,589-590,601-603`;
    - `doc-tools.sh:1817-1844` (`tools install`);
    - `state.sh:150-153`.
  - Measured examples:
    - `.claude/settings.local.json → global settings`;
    - `.github/scripts/doc-tools.sh → ~/.bashrc`;
    - `.githooks/pre-commit → ~/.bashrc`, which gives **persistent code execution** after cloning a
      hostile repo and running the installer.
- [P2] **Sibling-directory execution.** `install.sh:16` plus hook line 5 resolve the tool with
  `__DOC_TOOLS_PARENT__/*/scripts/doc-tools.sh | sort -V | tail -1`.
  - That runs whichever **sibling** directory's script sorts last. Measured: code execution from
    `~/code/<sibling>` in the clone layout.
  - `sort -V` is absent on older macOS, where every hook then no-ops.
- [P2] **Placement guesses.** `install.sh:106-126,209-216,293-299,519` derive the hooks dir and repo
  root from cwd:
  - `.githooks/` is used without `core.hooksPath` set, yet status says "✓ installed";
  - a literal `~` directory is created;
  - a **global** `core.hooksPath` is spliced into;
  - worktrees and submodules return rc 1 and abort `--all`;
  - a subdirectory install writes into `packages/web/.github`.
- [P2] `install.sh:144,181,304,187-190` interpolate the install path unquoted. A path with a space
  makes every hook silently no-op.
- [P2] **Choices not recorded.** `install.sh:478-486,541-553`; `state.sh:175-188`: a plain re-install
  - flips `STRICT` from `"1"` to `"0"`;
  - installs all 9 workflows;
  - rewrites `installed_at`.
- [P2] `install.sh:312-342,358-373`: the settings merge crashes on a `type:"prompt"` hook (rc 5,
  after the scripts were already copied), and "installs" into a 0-byte file.
- [P2] `install.sh:136-141` never re-renders an integrated hook's local copy on re-install. The
  v2.12.2 release note claims otherwise.
- [P2] `install.sh:423-428`: the default `--ci` installs all 9 workflows, including both AI PR
  workflows that the template says never to combine.
- [P2] `install.sh:296-349`: the Claude tier writes wiring into the *personal*
  `settings.local.json` without git-ignoring it, while writing machine-specific scripts into the
  shareable `.claude/hooks/`.
- [P3]:
  - unescaped `sed` replacements: `--base-branch 'a|b'` produces a 0-byte workflow and reports
    "1 installed";
  - symlinked user hooks are de-linked;
  - uninstall of integrated hooks is not the inverse of install;
  - helpers are installed when doc-pr-release was skipped;
  - `uninstall --workflows=<typo>` returns rc 0;
  - `state_is_valid` checks syntax only;
  - an unguarded empty array breaks under bash 3.2;
  - the `__DOC_TOOLS_PATH__` substitution is dead;
  - `v1` markers are matched as exact strings;
  - uninstall leaves a 0-byte `.gitattributes`.

## Follow-up pass FU2 (L-PERF + L-DEADCODE-SIMPLIFY, verified by V-FU2)

The Phase-4 critic found that no pass had covered S4 × L-PERF or S4 × L-DEADCODE. The follow-up pass
added the items below. Measured unless noted. Five of the finder's items were dropped on
verification: the Claude-tier jq cost, `--workflows=all`, the secrets NOTE, the env-overrides line,
and the menu (a duplicate).

- [P2] `state.sh:31,179-182,196-199,214-217`; `install.sh:521-524`: a malformed `installed.json`,
  such as the merge conflict produced by the installer's own `installed_at` churn, loses every
  `intentional` record.
  - `install --ci` rebuilds the file from disk, so workflows that were removed on purpose come back.
    Measured through a real two-branch merge: 3 conflict hunks, then "9 installed".
  - `uninstall` resets the file to a skeleton.
  - The rewritten file is valid JSON, so `git add` "resolves" the conflict with the resurrected state.
  - Fix: refuse to write over an unparsable state file (or move it aside and install nothing new).
    Stop rewriting timestamps on no-op marks. `test-hooks.sh:1388-1401` pins the current behaviour.
- [P3] `state.sh:146-233`; `install.sh:538-557,…`: every state mark is a full transaction.
  - `install --ci` = 53 jq and 12 whole-file rewrites; about 300 ms of its ~390 ms is state
    bookkeeping.
  - Fix: `state_load` once, then `state_flush` once, but flush or mark **before** deleting files, so
    an interrupted uninstall cannot resurrect workflows.
- [P3] `state.sh:51-77`; `install.sh:447,495-517`: the workflow list is re-derived for every
  membership test, so cost is O(k·W). A 9-name CSV = 338 execve, 174 of them `basename`.
- [P3] `install.sh:715-731,757`: `status` has two defects.
  - On a file that is valid JSON but the wrong shape, it aborts with rc 5 and no message.
  - On a malformed file, it prints the WARN twice.
- [P3] Dead or write-only code:
  - `state_dump_ci` has zero callers.
  - `.tiers.ci.tools`, `.helpers`, `.dest`, the timestamps and `schema_version` are written but never
    read. After `tools uninstall`, the state still says "installed".
  - The `found` counter is never read.
  - The CSV validation is duplicated (`:424` is dead).
  - The hardcoded fallback workflow list and its unreachable `return 1`; `docs/codebase-guide.md:123`
    documents the fallback.
  - Guards that never apply, and the unset `DOC_SP_STATE_FILE` knob.
  - The `VERSION` computation feeds only the dead `DOC_SUPERPOWERS_VERSION`.
  - The sed render is copy-pasted 3×.
- [P3] `install.sh:559-606,676-703` vs `doc-tools.sh:1797-1935`: vendoring is implemented twice and
  the copies have drifted. `uninstall --ci` deletes locally edited helpers, while `tools uninstall`
  keeps them. Delegate to `tools …` only **after** I-10 fixes `tools uninstall`.
- [P3] `install.sh:781-884`: flags outside a command's scope are silently ignored, all rc 0:
  - `status --ci` prints all tiers;
  - `uninstall --ci --helpers=false` still deletes the helpers;
  - `status --workflows=bogus`.
- [P3, new at verification] `install.sh:633-636`: `uninstall --ci` returns "nothing to uninstall"
  when `.github/workflows/` is absent. The vendored tool, the helpers and the state are left behind.
- [P3, new at verification] `install.sh:538-547,722`: the state and the disk are never reconciled.
  A workflow marked intentionally-uninstalled that is back on disk is never refreshed, and `status`
  shows "✓ installed".
- [P3, new at verification] `install.sh:442-515`: duplicate CSV names give "2 installed".
- Clean (verified):
  - nothing scales with repo size (20,000-file repo: `install --all` 418 ms, no reads under the
    source tree);
  - every substituted placeholder has a template sink, except the known `__DOC_TOOLS_PATH__`;
  - 15/15 `install.sh` and 11/12 `state.sh` functions have callers;
  - `install.sh` 731-778 and 853-890 and `state.sh` 1-40 and 199-249 have no further defects.

- [P3, FU4/V-FU4, measured] `install.sh:157-168`: the integration block is inserted before
  **every** column-0 line starting `exit 0`, not only the final one as the hooks spec promises
  (`:243,:505`). A host hook with an early unindented `exit 0` got 2 copies, so the doc hook also
  runs on the host's early-exit path.
- [P4, FU4/V-FU4] `install.sh:457`: `"${names[@]}"` is unguarded. Under bash 3.2 this prints only a
  stderr line, because its exit status is discarded. `--workflows=,` is silently accepted as
  "install none" while still vendoring doc-tools and bootstrapping state. It should error, as an
  unknown name does.


## Proposed fix (fix plan Task 8)

- **Placement:** use git plumbing (`--show-toplevel`, `--git-path hooks`). Refuse a global
  `core.hooksPath`.
- **Writes:** `safe_dest()` refuses symlinked targets and parents; every write is tmp + `mv`.
- **Ownership:** by exact path per hook *entry*.
- **Integration:** a POSIX block inserted once after the shebang, which passes `"$@"` and
  propagates the exit code.
- **Tool resolution:** version-named siblings only, numeric sort (no `sort -V`). Quote and escape
  every substituted value.
- **State:** record the choices per tier.
- **Claude tier:** make it explicitly per-user (added to `info/exclude`) or explicitly team-shared
  (`settings.json` + `$CLAUDE_PROJECT_DIR`).
- **Defaults:** `--ci` installs the three shell workflows only; AI templates are opt-in by name.

## Acceptance criteria

See fix plan Task 8, Step 1. Key cases:
- [ ] User hook groups survive install and uninstall byte-for-byte.
- [ ] A committed symlink at any write target makes the installer refuse.
- [ ] A `#!/bin/sh` host hook runs the integrated block with its arguments.
- [ ] Worktree, submodule and subdirectory installs land where git runs hooks.
- [ ] A sibling `…/zzz/scripts/doc-tools.sh` is never executed.
- [ ] A plain re-install reproduces the prior choices.
- [ ] Install then uninstall leaves no residue except the state file.

## Related

- I-5: merge-driver registration path.
- I-6: hook runtime.
- I-8: the default workflow set.
- I-10: `tools install`/`uninstall`.
- The `sort -V` removal is part of the dependency audit.
