---
date: 2026-09-27
status: Open
priority: P1
type: bug
component: skill
source: sweep-skill
cluster-key: sweep-skill:full-repo:I-11
run-id: 05ea982
related-files:
  - skills/doc-superpowers/SKILL.md
  - references/spec-lifecycle-actions.md
  - references/spec-lifecycle-protocol.md
  - references/doc-spec.md
  - references/tool-mappings.md
  - references/integration-patterns.md
  - evals/evals.json
screenshots: null
axiom-agent: null
branch: null
design-doc: null
report: docs/plans/2026-09-27-full-repo-05ea982-audit-findings.md
---

# I-11 — Skill prompt ↔ tool contract and agent safety

> Cluster **I-11** of sweep run `05ea982`, ranked #6 of 14. Evidence:
> [findings index](../plans/2026-09-27-full-repo-05ea982-audit-findings.md) (S8). Fix: **Task 12**
> of the [fix plan](../plans/2026-09-27-full-repo-05ea982-fix-plan.md). It runs after the tool
> Tasks, so the prompts describe the fixed tools.

## Summary

The prompt layer (SKILL.md + references) is how agents drive the tools. It has drifted from the
tools in both directions:
- it routes index writes to verbs that reject the input or replace the index;
- it resolves the tools only through the Claude Code plugin cache;
- its review-pr base detection yields an empty base;
- it runs repo scripts from the working tree during discovery.

## Incorrect assumption

- "Tools live in the Claude plugin cache."
- "`build-index` is incremental; `update-index` upserts."
- "The host project is doc-superpowers."
- "Repo scripts are trusted."
- "A prose rule is a guard" (A5).

## Verified evidence

- [P1] Tool resolution. `SKILL.md:85-94,432,505,580`; `tool-mappings.md:41-43`: `$DOC_TOOLS`,
  `install.sh` and `references/` resolve only through the plugin-cache glob. With no cache, the glob
  stays literal (rc 127). So 4 of the 5 supported clients have no tooling, despite the "full parity"
  claims. Measured.
- [P1] Review-pr base detection (root cause not named in the Phase-5 draft; added after Phase-4
  review). `SKILL.md:346-349`: `|| echo main` binds to `sed`, so `BASE=""` wherever `origin/HEAD`
  is unset. That includes this repo and `actions/checkout`. The diff is then empty, and
  `check-freshness --code-refs` with no arguments applies **no filter**. Measured.
- [P1] Index-write routing. `SKILL.md:291,373,393,428,639`; `spec-lifecycle-actions.md:92,128`;
  `evals.json:151`: the routing predates `add/move/remove/deprecate-entry`. Measured.
  - New docs go to `update-index`, which rejects them and loses the batch.
  - Untracked docs and migrations go to `build-index`, which replaces the index. The tool-side guard
    is I-4.
  - Archival never re-keys or deprecates.
  - `sync` has no add or remove step.
- [P1] `spec-lifecycle-actions.md:127`: spec-generate allows "module names" as `code_refs`. Their
  `code_commit` is null, so the spec reads current forever. Measured.
- [P1] `SKILL.md:81,158-164,424-427`: discovery (every action except hooks and release) and `sync`
  run `uv run scripts/validate_docs.py` from the working tree. So `review-pr` on a checked-out PR
  executes PR-author code. Structural.
- [P2] Contract drift:
  - `update-index` un-deprecates, but doc-spec calls deprecation "terminal";
  - `set-implementation` anchors differ from the templates;
  - the host project is assumed to be doc-superpowers (README synced against SKILL.md actions; the
    mandatory manifest bump passes vacuously);
  - `release` has no commit step before `git tag`;
  - the `:amends` landed-check runs per chunk, giving false FAILs;
  - two per-chunk Status writers use different gates;
  - an explicit `:constraint` marker is lost in injected plans;
  - the landed-check grep is not section-aware;
  - index semantics are described wrongly;
  - `replaces`/`code_refs` writes have no verb (GH #18);
  - the audit→update handoff is undefined;
  - v2.15's `:amends`/`--plan` are missing from the protocol and templates.
- [P2] Safety gaps:
  - no data-vs-instructions trust boundary;
  - no secret-handling rule;
  - the doc-pr-release trust list is incomplete;
  - the `--ci` default installs overlapping AI workflows.
- [P2] Cost and evals:
  - discovery dumps the full `check-freshness` JSON into context (~1.25 MB at 4,019 entries);
  - evals are not runnable (13 of 13 have `files: []`).
- [P3] Smaller defects:
  - headless CI commits contradict "human reviews diffs";
  - migration and archival run without confirmation;
  - the consumed-list path is a fixed `/tmp` path;
  - "read-only" claims are contradicted;
  - the schema table is stale;
  - `release` is underspecified;
  - broken anchors and duplicated templates;
  - SKILL.md is 5,949 words, of which the `release` and `hooks` bodies are 25%.

## Proposed fix (fix plan Task 12)

- **Tool resolution:** `ROOT=<skill base dir>/../..`, with the plugin cache only as a fallback. Stop
  if the tool is not executable.
- **Routing table:**
  - new doc → `add-entry`;
  - moved or archived → `move-entry` (+ `deprecate-entry`);
  - deleted → `remove-entry`;
  - verified → `update-index`;
  - refs changed → `set-code-refs`;
  - `build-index` only when no index exists.
- **review-pr:** base from `git symbolic-ref --short -q refs/remotes/origin/HEAD` or `origin/main`.
  Stop on an empty diff.
- **Spec lifecycle:** the fixes listed under P2 above. `code_refs` must be pathspecs.
- **Safety:**
  - a trust-boundary block;
  - a secret-handling rule;
  - confirmation before migrations;
  - **never** auto-run `scripts/*validate*`.
- **Context:** discovery filters `check-freshness` through jq. Move the `release`/`hooks` bodies into
  references.
- **Evals:** give them machine-checkable fields and fixtures.

## Acceptance criteria

- [ ] Contract tests (token assertions, not prose freezes) pin the routing table, the base
  detection, the pathspec rule and the no-auto-run rule.
- [ ] At least evals 3, 4, 6, 9 and 12 have fixtures and checkable assertions.
