---
date: 2026-09-27
status: Open
priority: P2
# contains one provisional P1 (Cursor manual-install path) — raise to P1 if confirmed against Cursor docs
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

- [ ] A node simulation test shows the OpenCode system array stays an array and gains the mappings.
- [ ] A JSON test shows `.cursor-plugin/plugin.json` points at `./skills/`.
- [ ] Capability names appear in exactly one file.
- [ ] The Cursor path is confirmed against current Cursor docs before this cluster closes.
