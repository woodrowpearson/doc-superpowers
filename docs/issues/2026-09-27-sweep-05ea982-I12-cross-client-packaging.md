---
date: 2026-09-27
status: Resolved
priority: P1
# the provisional P1 (Cursor manual-install path) was confirmed against Cursor's docs in Task 13
# (cursor.com/docs/plugins, "Test plugins locally"); the rest of the cluster is P2/P3
type: bug
component: packaging
source: sweep-skill
cluster-key: sweep-skill:full-repo:I-12
run-id: 05ea982
related-files:
  - .opencode/plugins/doc-superpowers.js
  - .opencode/INSTALL.md
  - .cursor-plugin/plugin.json
  - .cursor-plugin/INSTALL.md
  - .codex/INSTALL.md
  - GEMINI.md
  - gemini-extension.json
  - AGENTS.md
  - claude-code.json
  - package.json
  - references/tool-mappings.md
screenshots: null
axiom-agent: null
branch: null
design-doc: null
report: docs/plans/2026-09-27-full-repo-05ea982-audit-findings.md
---

# I-12 — Cross-client packaging and install docs

> Cluster **I-12** of sweep run `05ea982`, ranked #13 of 14. Evidence:
> [findings index](../plans/2026-09-27-full-repo-05ea982-audit-findings.md) (S10). Fix: **Task 13**
> of the [fix plan](../plans/2026-09-27-full-repo-05ea982-fix-plan.md).

## Summary

The non-Claude clients were packaged on two assumptions:
- that every client shares one naming scheme;
- that capability tables copied into six files stay in sync.

The resulting problems:
- the OpenCode plugin replaces the system-prompt array with a string;
- the Cursor manifest points at the pre-`skills/` layout;
- the tool-name tables are wrong for three clients;
- Gemini loads the whole SKILL.md into every session.

The larger defect, that `$DOC_TOOLS` resolves only from the Claude plugin cache, is owned by I-11.

## Incorrect assumption

- "Every non-Claude client shares one naming scheme and installs into the Claude plugin cache."
- "Copied tables stay in sync."

## Verified evidence

- [P1, provisional: structural; the vendor site was unreachable] `.cursor-plugin/INSTALL.md:8`: the
  manual install clones into `~/.cursor/plugins/doc-superpowers`. Cursor's local-plugin location is
  `~/.cursor/plugins/local/<name>/`.
- [P2] `.opencode/plugins/doc-superpowers.js:27-28` replaces `output.system`, which is a `string[]`,
  with a string.
  - The tool mappings never reach the model.
  - A later push-style plugin would throw.
  - Measured: node simulation against the OpenCode source.
- [P2] `.cursor-plugin/plugin.json:24`: `"skills": "./"` predates the move to `skills/`. Structural.
- [P2] `tool-mappings.md` and the INSTALL files give wrong tool names for OpenCode, Codex and Gemini.
  For example, Gemini has `ask_user`, plan mode and subagents. SKILL.md never references the
  mapping, so nothing delivers it to Codex. Measured against client source.
- [P2] `GEMINI.md:1` imports the whole 45 KB SKILL.md into every Gemini session (~11k tokens always
  on). The extension's `skills/` dir already exposes it on demand.
- [P3] Smaller defects:
  - the top-level `multi_agent` in the Codex snippet is ignored (it is a `[features]` key, on by
    default);
  - `claude-code.json` has no consumer;
  - the capability tables are duplicated in 5–6 files and have drifted;
  - `install.sh:22`'s version fallback is unreachable under `pipefail`;
  - INSTALL pins are not checked.

## Proposed fix (fix plan Task 13)

- OpenCode: `output.system.push(toolMappings)`, reading the file once at load.
- Cursor: fix the `skills` key and the install path.
- Keep **one** capability matrix, in `references/tool-mappings.md`, with corrected names; the
  INSTALL files link to it.
- Drop the `@SKILL.md` import from `GEMINI.md`.
- Fix the Codex `[features]` snippet.
- Document marketplace install.
- Remove `claude-code.json` once no external consumer is confirmed (update `VERSION_FILES`, the test
  fixture and the docs).

## Acceptance criteria

- [x] A node simulation test shows the OpenCode system array stays an array and gains the mappings.
- [x] A JSON test shows `.cursor-plugin/plugin.json` points at `./skills/`.
- [x] Capability names appear in exactly one file.
- [x] The Cursor path is confirmed against current Cursor docs before this cluster closes
  (docs-confirmed; an end-to-end install of this plugin is still pending — see below).

## Resolution (Task 13)

Resolved by Task 13 of the fix plan. The packaging contracts are pinned in
`scripts/test-spec-status-model.sh` (section *I-12: cross-client packaging*) and, for the version
files, `scripts/test-doc-tools.sh`. Each cross-client fact was checked against the client's
current documentation or source on 2026-09-28; `references/tool-mappings.md` lists the sources,
and says *unverified* wherever the docs are silent.

**OpenCode** — `.opencode/plugins/doc-superpowers.js` reads `references/tool-mappings.md` once,
when the plugin loads, and `experimental.chat.system.transform` pushes it onto `output.system`
(a `string[]` in OpenCode's `Hooks` interface) in place, once per array. The suite **executes**
the plugin under node against that hook shape: the array stays the same array, keeps its entries,
gains the mappings once, still takes a later plugin's `push`, and the hook still works with the
file deleted after load. node is a test-time tool only: without it the case is a counted SKIP,
and a FAIL under `DOC_SP_REQUIRE_NODE=1`, which `tests.yml` sets (its toolchain step also
requires node).

**Cursor** — `.cursor-plugin/plugin.json` has `"skills": "./skills/"`. The manual install clones
into `~/.cursor/plugins/local/doc-superpowers` (a real directory: Cursor skips a symlink there
that points outside the folder). The marketplace route is gone: doc-superpowers is not in
Cursor's marketplace. The "Anthropic-ecosystem" / "full feature parity" claims are gone. The
Claude hook tier under Cursor is stated as documented: Cursor runs Claude Code hooks from
`.claude/settings.json` when *Include Third-Party Plugins, Skills, and Other Configs* is on; this
tier writes `.claude/settings.local.json`, which Cursor's docs do not name — so it is marked
unverified (the installer's per-user tier is unchanged, R8).

**One capability matrix** — `references/tool-mappings.md` holds the only *Tool names* and
*Capabilities* tables, with corrected names: OpenCode `read`/`write`/`edit`/`bash`/`grep`/
`glob`/`task`/`skill`/`question`/`todowrite`/`webfetch`/`websearch`; Codex `exec_command`,
`apply_patch`, `spawn_agent`/`wait_agent`, `update_plan`, `request_user_input`, `web_search`;
Gemini CLI `read_file`/`write_file`/`replace`/`run_shell_command`/`grep_search`/`glob`,
`invoke_agent`, `activate_skill`, `ask_user`, `write_todos`, `google_web_search`/`web_fetch`
(Gemini has subagents and MCP; the "no subagent support" and "MCP not available" claims are
gone). The hook-tier counts that drifted ("(7)" vs 9) are gone. Its *Tool resolution* section
(T12) is kept. The INSTALL files, `AGENTS.md` and `GEMINI.md` link to it; a test fails when a
client tool name, a capability / hook-tier / parity table, or a parity claim appears in any other
live file. SKILL.md's references table tells every non-Claude client to read it — that is how the
mapping reaches Codex and Cursor; OpenCode gets it from the plugin, Gemini from `GEMINI.md`.

**Gemini CLI** — `GEMINI.md` no longer imports SKILL.md (Gemini lists the extension's skill and
loads it on demand); it imports only the tool mapping and points at `skills/doc-superpowers/`.

**Codex** — the snippet is a `[features]` table (`multi_agent`, on by default; a top-level key
is ignored). `.codex/INSTALL.md:44`'s "Codex translates them automatically" is gone.

**Claude Code** — README and AGENTS.md document `/plugin marketplace add
woodrowpearson/doc-superpowers` + `/plugin install doc-superpowers@doc-superpowers`; a test ties
the names to `.claude-plugin/marketplace.json`. README's *Manual* install copies the whole plugin
(the skill resolves its tooling two directories above `SKILL.md`).

**`claude-code.json`** — removed (R9): no consumer in the repository, the installed marketplace
copy, the Claude Code 2.1.280 binary, or GitHub code search. `VERSION_FILES`, `bump-version
--help`, doc-release's commit `--allow` list, `references/release.md` step 9, SKILL.md, CLAUDE.md,
README, conventions and codebase-guide now name five manifests. A test pins doc-release's
`--allow` manifests to `VERSION_FILES`. **Behaviour change:** `bump-version` / `check-version`
no longer read or write a `claude-code.json` a consuming project keeps.

**INSTALL pins** use a `#vX.Y.Z` placeholder; a test fails on a concrete `#vN.N.N` pin.
**`install.sh:22`'s** unreachable version fallback was already fixed by Task 11 (I-10: the
installer reads the version with `doc-tools.sh tools version` and warns when it cannot).

**Still open (not verifiable here):** one end-to-end Cursor install of this plugin (Gotcha 11);
whether Cursor loads `.claude/settings.local.json`; whether Codex scans `~/.agents/skills`
recursively (its loader has a recursive mode; `.codex/INSTALL.md` gives the fallback); whether
Gemini's `read_file` reaches `$ROOT/references/` after `activate_skill`.
