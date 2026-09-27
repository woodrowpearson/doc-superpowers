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
