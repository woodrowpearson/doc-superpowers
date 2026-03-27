# Spec Lifecycle Protocol — Integration Guide

Reference for wrapper skill authors integrating doc-superpowers spec lifecycle actions into their pipelines. doc-superpowers actions are context-agnostic composable primitives — they have zero knowledge of what wrapper skill invokes them.

## Lifecycle Overview

5 pipeline interception points mapped to 3 actions:

| Pipeline Point | When | Action | Mode |
|---|---|---|---|
| Post-brainstorm | Design doc written and committed | `spec-generate` | — |
| During plan | Implementation plan being written | `spec-inject` | `plan` |
| During execute | After each plan chunk completes | `spec-inject` | `execute` |
| Pre-finish | All tasks done, before merging | `spec-verify` | `post-execute` |
| During review | Alongside other review participants | `spec-verify` | `review` |

```
Design doc ──→ spec-generate ──→ formal SPEC-{CAT}-NNN files
                                      │
Plan doc ──→ spec-inject (plan) ──→ plan + spec maintenance tasks
                                      │
Chunk done ──→ spec-inject (execute) ──→ spec status updates / drift flags
                                      │
All done ──→ spec-verify (post-execute) ──→ compliance report (PASS/FAIL)
                                      │
PR review ──→ spec-verify (review) ──→ freshness + coverage findings
```

## Action Reference

### spec-generate

**Input:**
- `--design-doc=<path>` — Path to the narrative design spec

**Output:**
- N formal `SPEC-{CAT}-NNN-{slug}.md` files in `docs/specs/`
- Updated `.doc-index.json` entries
- Updated `docs/specs/README.md` index
- Modified design doc with `Generated Specs` section appended
- Updated CLAUDE.md (if new directories or commands were bootstrapped)
- Updated README.md (if new actions or features were added)
- List of generated spec paths (for downstream `--specs` parameters)

**Prerequisites:**
- Design doc must exist and be committed
- `docs/specs/` directory must exist (bootstrapped if missing)
- `references/doc-spec.md` must be accessible (for spec template)

**Error handling:**
- Missing design doc → error with path suggestion
- No `docs/specs/` directory → bootstrap it (mkdir + create template + README)
- No `.doc-index.json` → run `doc-tools.sh build-index` first

---

### spec-inject

**Input (plan phase):**
- `--phase=plan`
- `--plan=<path>` — Path to the implementation plan
- `--specs=<paths>` — Comma-separated paths to governing specs

**Output (plan phase):**
- Modified plan document with spec maintenance tasks appended to each chunk

**Input (execute phase):**
- `--phase=execute`
- `--specs=<paths>` — Paths to governing specs

**Output (execute phase):**
- Updated spec files (status, Implementation Notes, code_refs) if aligned
- Deviation flags if drifted (what spec says vs. what code does)

**Prerequisites:**
- Governing specs must exist (output of `spec-generate`)
- `.doc-index.json` must exist with entries for governing specs
- For plan phase: plan document must exist
- For execute phase: code changes must be committed

**Error handling:**
- Missing governing specs → warning listing missing paths
- No `.doc-index.json` → error suggesting `doc-tools.sh build-index`
- Plan without chunk boundaries → fall back to `### Task N:` headings

---

### spec-verify

**Input (post-execute mode):**
- `--mode=post-execute`
- `--specs=<paths>` — Paths to governing specs
- `--design-doc=<path>` — Path to original design doc

**Output (post-execute mode):**
- Structured compliance report with PASS/FAIL verdict (includes CLAUDE.md and README.md currency check)

**Input (review mode):**
- `--mode=review`
- `--changed-files=<paths>` — Files changed in the PR/branch

**Output (review mode):**
- Review findings in standard doc-superpowers severity format

**Prerequisites:**
- `.doc-index.json` must exist with `code_refs` populated
- For post-execute: governing specs must exist
- For review: changed files list must be provided

**Error handling:**
- Missing `.doc-index.json` → error suggesting `doc-tools.sh build-index`
- No governing specs found → finding: "No formal specs govern this implementation"
- No changed files match any `code_refs` → report: "No spec-governed files changed"

---

## Integration Patterns

### Wiring into a wrapper skill

At each pipeline point, invoke the corresponding doc-superpowers action. Pass results downstream where needed.

```
Post-brainstorm:
  After design doc committed →
    invoke doc-superpowers spec-generate --design-doc=<path>
    Store generated spec paths for downstream use

During plan:
  After writing-plans produces plan →
    invoke doc-superpowers spec-inject --phase=plan --plan=<path> --specs=<paths>
    (modifies plan in-place — no further action needed)

During execute:
  After each plan chunk completes →
    invoke doc-superpowers spec-inject --phase=execute --specs=<paths>
    If deviation flags returned → surface to user

Pre-finish:
  After all tasks, before finishing →
    invoke doc-superpowers spec-verify --mode=post-execute --specs=<paths> --design-doc=<path>
    If FAIL → surface report to user, let them decide

During review:
  Alongside other review participants →
    invoke doc-superpowers spec-verify --mode=review --changed-files=<paths>
    Merge findings into review report
```

### Standalone usage

All actions are user-invocable outside wrapper skills:

```
/doc-superpowers spec-generate --design-doc=docs/superpowers/specs/2026-03-14-feature-design.md

/doc-superpowers spec-inject --phase=plan --plan=docs/superpowers/plans/2026-03-14-feature.md --specs=docs/specs/SPEC-AUTH-001-oauth-flow.md

/doc-superpowers spec-inject --phase=execute --specs=docs/specs/SPEC-AUTH-001-oauth-flow.md

/doc-superpowers spec-verify --mode=post-execute --specs=docs/specs/SPEC-AUTH-001-oauth-flow.md --design-doc=docs/superpowers/specs/2026-03-14-feature-design.md

/doc-superpowers spec-verify --mode=review --changed-files=src/auth/oauth.py,src/auth/session.py
```

## Host Project Assumptions

doc-superpowers expects these to exist (or bootstraps them):

| Artifact | Created by | Bootstrapped by |
|----------|-----------|----------------|
| `docs/specs/` directory | `init` action | `spec-generate` (mkdir + template + README) |
| `docs/specs/template.md` | `init` action | `spec-generate` |
| `docs/specs/README.md` | `init` action | `spec-generate` |
| `docs/.doc-index.json` | `doc-tools.sh build-index` | `spec-generate` |
| Spec template in `references/doc-spec.md` | Bundled with skill | (always available) |
