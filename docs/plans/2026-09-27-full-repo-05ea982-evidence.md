---
title: doc-superpowers full-repo sweep — Evidence appendix
date: 2026-09-27
type: audit-evidence
source: sweep-skill
run-id: 05ea982
# NO `status:`: this is a companion to the findings index. It is raw evidence, not a tracked item.
related-files:
  - docs/plans/2026-09-27-full-repo-05ea982-audit-findings.md
  - docs/plans/2026-09-27-full-repo-05ea982-fix-plan.md
  - docs/plans/2026-09-27-full-repo-05ea982-jumping-off-point.md
---

# doc-superpowers full-repo sweep `05ea982` — Evidence appendix

> **Why this file exists.** The sweep ran in a cloud container. Its scratch artifacts would have
> vanished with that container, so the pieces the fix plan relies on are preserved here:
> - the **adversarial-verifier reports** (the authoritative record of each finding: what was kept,
>   what was dropped and why, and every measurement);
> - the coverage matrix and the surface map (the Phase-0 no-drop check);
> - the **prototype scripts** that Task T4 (content identity) and the scaling numbers cite.
>
> The raw Phase-2 finder reports are *not* included, because their severity is superseded by the
> verifiers. Paths such as `$S/...` or `/tmp/claude-0/...` inside the reports refer to scratch
> directories that no longer exist; the commands and results are what matter. Everything under the
> "Verifier reports" heading is quoted verbatim, with its headings demoted by two levels.

## Contents

1. [Coverage matrix (controller-declared)](#coverage-matrix-controller-declared)
2. [Surface map (Phase-0 no-drop: 113 tracked paths → surface)](#surface-map)
3. [Prototypes (T4 content identity; scaling)](#prototypes)
4. [Verifier reports: Phases 2–3](#verifier-reports-phases-23): V-S1, V-S2, V-S3, V-S4S5, V-S7, V-S8, V-S9, V-S10-S11, V-CI, V-SHELL, V-XCONC
5. [Verifier reports: Phase-4 follow-ups](#verifier-reports-phase-4-follow-ups): V-FU1, V-FU2, V-FU3, V-FU4


## Coverage matrix (controller-declared)


Adapted taxonomy (this repo has no iOS/functions/agents/terraform plane; surface-kinds extended):
  shell-tool (≈ cloud-other): floor + L-CONCURRENCY (atomicity/races) + L-PERF (scaling) + L-SECURITY (/security-review role)
  ci-workflow (≈ terraform/L-INFRA static-read): L-INFRA + L-SECURITY + floor (+ L-CONTRACT with installer)
  skill-prompt (≈ adk-agent): L-CONTRACT (prompt↔tool) + L-SECURITY (prompt-injection) + L-COST-EVAL (context cost + evals) + floor
  test: L-TESTS (+ L-CORRECTNESS on harness)
  manifests (≈ other+flags): L-CONTRACT + floor
  docs: L-DOCS-DRIFT (gate-script check-freshness measured)
  Force-run: L-DATAFLOW on the doc-index lifecycle (cross-surface; --force-lens with an inline dataflow map: chains A–E)
  Not applicable (with reason): L-PERF-IOS, L-CONCURRENCY-SWIFT, L-PERSISTENCE, L-UI-POLISH, L-INTERACTION, L-A11Y, L-LAYOUT, L-NAV, L-MEMORY (no Swift/iOS); L-SCHEMA-RULES (no Firestore rules); L-FLAGS (no Remote Config / flag registry — version sync is covered by check-version gate-script, measured PASS); L-FLAG-SEMANTICS (env knobs STRICT/QUIET/SKIP/DOC_INDEX examined inside S5 correctness instead); L-OBSERVABILITY (no telemetry sink; its "diagnosability" intent folded into S5 error-swallowing checks and cross-cutting pattern P-A); L-COST-EVAL for runtime cost/eval deltas (needs-runtime; static half run on S8).

Surface | Files | Lenses run (dispatch → verify)
S1 doc-tools core (doc-tools.sh 1–1255 + dispatcher) | 1 | L-CORRECTNESS (S1-CORR→V-S1) · L-PERF (S1-PERF→V-S1) · L-DEADCODE-SIMPLIFY (S1S2-DEAD→V-S1) · L-CONCURRENCY (X-CONC→V-XCONC) · L-SECURITY (SHELL-SEC→V-SHELL) · L-TESTS (S9a→V-S9) · L-DATAFLOW (X-DATAFLOW→V-S1) · L-CONTRACT (S8-CONTRACT prompt↔tool→V-S8)
S2 doc-tools 1256–2006 | (same file) | L-CORRECTNESS (S2-CORR→V-S2) · L-DEADCODE-SIMPLIFY (S1S2-DEAD→V-S2) · L-SECURITY (SHELL-SEC→V-SHELL/V-S2) · L-CONCURRENCY (X-CONC bump-version→V-XCONC) · L-PERF (S1-PERF fragments items; V-S1 marked out-of-range → structural only) · L-TESTS (S9a→V-S9) · L-CONTRACT (S7 fragments spec→V-S7)
S3 merge driver | 1 | L-CORRECTNESS + L-TESTS (S3→V-S3) · L-SECURITY (SHELL-SEC clean) · L-CONCURRENCY (X-CONC clean) · L-PERF (S3 measured linear) · L-DEADCODE (inside S3 finder: top-level rebuild, sort)
S4 installer + state | 2 | L-CORRECTNESS (S4-CORR→V-S4S5) · L-CONTRACT + orphan (S4S5-CONTRACT→V-S4S5) · L-SECURITY (SHELL-SEC→V-SHELL) · L-CONCURRENCY (X-CONC→V-XCONC) · L-TESTS (S9b→V-S9)
S5 runtime hooks + self-installed copies + settings | 12 | L-CORRECTNESS (S5-CORR→V-S4S5) · L-CONTRACT (S4S5→V-S4S5) · L-SECURITY (SHELL-SEC→V-SHELL) · L-PERF (S1-PERF callers→V-S1) · L-TESTS (S9b→V-S9)
S6 CI templates + repo workflows | 11 | L-INFRA (CI-INFRA→V-CI) · L-SECURITY (CI-SEC→V-CI) · L-CONTRACT placeholders (S4S5→V-S4S5) · L-CONCURRENCY groups (X-CONC→V-XCONC) · L-TESTS (S9b YAML→V-S9)
S7 PR-release pipeline | 6 | L-CONTRACT + L-CORRECTNESS (S7→V-S7) · L-SECURITY (CI-SEC, SHELL-SEC→V-CI, V-SHELL) · L-CONCURRENCY (X-CONC→V-XCONC) · L-TESTS (S9b→V-S9)
S8 skill prompt layer + references + evals | 9 | L-CONTRACT (S8-CONTRACT) · L-CORRECTNESS + L-DEADCODE + L-COST-EVAL (S8-CORR) · L-SECURITY (S8-SEC) → all V-S8
S9 test suites | 6 | L-TESTS ×2 (S9a, S9b→V-S9) incl. harness correctness + mutation testing
S10 cross-client packaging | 12 | L-CONTRACT + L-CORRECTNESS + L-DEADCODE (S10→V-S10-S11)
S11 project docs + index | 51 | L-DOCS-DRIFT (S11→V-S10-S11) + gate-script check-freshness (controller, measured 13 current / 23 stale)
OTHER catch-all | .gitignore, LICENSE | universal floor by controller: .gitignore lacks .claude/settings.local.json (covered in S5 finding); LICENSE MIT — Clean.

Deviations (declared):
D1 Lens grouping: small surfaces combined lenses in one dispatch (S3 CORR+TESTS; S8-CORR CORR+DEAD+COST; S10 CONTRACT+CORR+DEAD) instead of one-lens-per-dispatch.
D2 Cross-surface lens dispatches (SHELL-SEC, X-CONC, X-DATAFLOW) covered several surfaces at once.
D3 Engine: Agent-dispatch (user did not opt into the Workflow engine). Concurrency cap 20 → X-DATAFLOW launched after the first finder returned.
D4 No symptoms sidecar → blind-finder contract not mandatory; domain context listed 7 already-tracked defects as "report only if new" (deliberate anchoring trade-off for dedup). Controller kept 13 private observations (C1–C13) to test finder coverage; ONE finder (S1-PERF) disclosed reading that file mid-run (after independently finding C1); file moved out of reach afterwards.
D5 Repo hygiene: two verifiers briefly wrote into the real repo (untracked docs/a.md; docs/.doc-index.json overwritten by a fixture) — both reverted (git restore/checkout), final tree verified clean at 05ea982.
D6 bash 3.2 / BSD userland unavailable in container → every portability claim is structural.
D7 No FE plane → no Phase-1 sim capture.
D8 needs-runtime items (GitHub Actions semantics, claude-code-action runtime, Cursor/Gemini runtime) not executed; pinned-source reads used instead.

## Surface map

Format: `path<TAB>surface`. `OTHER` = the catch-all (`.gitignore`, `LICENSE`).

```tsv
S10 cross-client packaging (manifests)	.claude-plugin/marketplace.json
S10 cross-client packaging (manifests)	.claude-plugin/plugin.json
S5 runtime hooks (shell-tool, templates+self-install)	.claude/hooks/doc-superpowers/post-commit-sync.sh
S5 runtime hooks (shell-tool, templates+self-install)	.claude/hooks/doc-superpowers/pre-commit-gate.sh
S5 runtime hooks (shell-tool, templates+self-install)	.claude/hooks/doc-superpowers/session-summary.sh
S5 runtime hooks (shell-tool, templates+self-install)	.claude/settings.local.json
S10 cross-client packaging (manifests)	.codex/INSTALL.md
S10 cross-client packaging (manifests)	.cursor-plugin/INSTALL.md
S10 cross-client packaging (manifests)	.cursor-plugin/plugin.json
S6 CI templates+repo workflows (ci-workflow)	.github/workflows/doc-freshness-pr.yml
S6 CI templates+repo workflows (ci-workflow)	.github/workflows/doc-freshness-schedule.yml
S6 CI templates+repo workflows (ci-workflow)	.github/workflows/doc-index-update.yml
S6 CI templates+repo workflows (ci-workflow)	.github/workflows/tests.yml
OTHER (catch-all)	.gitignore
S10 cross-client packaging (manifests)	.opencode/INSTALL.md
S10 cross-client packaging (manifests)	.opencode/plugins/doc-superpowers.js
S10 cross-client packaging (manifests)	AGENTS.md
S11 project docs+index (docs)	CLAUDE.md
S10 cross-client packaging (manifests)	GEMINI.md
OTHER (catch-all)	LICENSE
S11 project docs+index (docs)	README.md
S11 project docs+index (docs)	RELEASE-NOTES.md
S10 cross-client packaging (manifests)	claude-code.json
S11 project docs+index (docs)	docs/.doc-index.json
S11 project docs+index (docs)	docs/architecture/diagrams/c4-container.png
S11 project docs+index (docs)	docs/architecture/diagrams/c4-context.png
S11 project docs+index (docs)	docs/architecture/system-overview.md
S11 project docs+index (docs)	docs/archive/plans/2026-03-15-audit-report.md
S11 project docs+index (docs)	docs/archive/plans/2026-03-25-audit-report.md
S11 project docs+index (docs)	docs/codebase-guide.md
S11 project docs+index (docs)	docs/conventions.md
S11 project docs+index (docs)	docs/guides/getting-started.md
S11 project docs+index (docs)	docs/issues/2026-04-05-spec-generate-missing-stale-content-updates.md
S11 project docs+index (docs)	docs/issues/2026-05-04-doc-index-metadata-rewrite-on-every-commit.md
S11 project docs+index (docs)	docs/issues/2026-07-29-doc-tools-has-no-move-entry-operation.md
S11 project docs+index (docs)	docs/issues/2026-07-29-index-write-is-not-atomic.md
S11 project docs+index (docs)	docs/issues/2026-07-29-merge-driver-reads-version-not-schema-version.md
S11 project docs+index (docs)	docs/issues/2026-07-29-usage-omits-implementation-verbs.md
S11 project docs+index (docs)	docs/plans/2026-03-26-audit-report.md
S11 project docs+index (docs)	docs/plans/2026-03-27-audit-report.md
S11 project docs+index (docs)	docs/plans/2026-04-05-audit-report-301e7a4.md
S11 project docs+index (docs)	docs/plans/2026-04-05-audit-report-38cd9df.md
S11 project docs+index (docs)	docs/plans/2026-04-05-audit-report.md
S11 project docs+index (docs)	docs/plans/2026-04-06-audit-report.md
S11 project docs+index (docs)	docs/plans/2026-05-12-pr-release-fragment-producer-and-consumer.md
S11 project docs+index (docs)	docs/plans/2026-05-16-audit-report.md
S11 project docs+index (docs)	docs/plans/2026-07-24-audit-report.md
S11 project docs+index (docs)	docs/superpowers/plans/2026-03-12-bundled-doc-tooling.md
S11 project docs+index (docs)	docs/superpowers/plans/2026-03-13-workflow-hooks-harness.md
S11 project docs+index (docs)	docs/superpowers/plans/2026-03-14-spec-lifecycle-protocol.md
S11 project docs+index (docs)	docs/superpowers/plans/2026-03-25-release-notes-readme-sync.md
S11 project docs+index (docs)	docs/superpowers/plans/2026-03-26-multi-framework-support.md
S11 project docs+index (docs)	docs/superpowers/plans/2026-03-29-github-pages-site.md
S11 project docs+index (docs)	docs/superpowers/plans/2026-07-24-spec-status-transition-model.md
S11 project docs+index (docs)	docs/superpowers/plans/2026-07-29-doc-tools-move-entry.md
S11 project docs+index (docs)	docs/superpowers/specs/2026-03-12-bundled-doc-tooling-design.md
S11 project docs+index (docs)	docs/superpowers/specs/2026-03-13-workflow-hooks-harness-design.md
S11 project docs+index (docs)	docs/superpowers/specs/2026-03-14-spec-lifecycle-protocol-design.md
S11 project docs+index (docs)	docs/superpowers/specs/2026-03-25-release-notes-action-design.md
S11 project docs+index (docs)	docs/superpowers/specs/2026-03-29-github-pages-site-design.md
S11 project docs+index (docs)	docs/superpowers/specs/2026-07-24-spec-status-transition-model-design.md
S11 project docs+index (docs)	docs/workflows/diagrams/sequence-audit.png
S11 project docs+index (docs)	docs/workflows/diagrams/sequence-discovery.png
S11 project docs+index (docs)	docs/workflows/diagrams/sequence-spec-inject.png
S11 project docs+index (docs)	docs/workflows/diagrams/workflow-doc-superpowers.png
S11 project docs+index (docs)	docs/workflows/diagrams/workflow-hooks.png
S11 project docs+index (docs)	docs/workflows/diagrams/workflow-init.png
S11 project docs+index (docs)	docs/workflows/diagrams/workflow-primary.png
S11 project docs+index (docs)	docs/workflows/diagrams/workflow-spec-generate.png
S11 project docs+index (docs)	docs/workflows/diagrams/workflow-spec-verify.png
S11 project docs+index (docs)	docs/workflows/doc-superpowers.md
S8 skill prompt layer (skill-prompt)	evals/evals.json
S10 cross-client packaging (manifests)	gemini-extension.json
S10 cross-client packaging (manifests)	package.json
S8 skill prompt layer (skill-prompt)	references/agent-prompt-template.md
S8 skill prompt layer (skill-prompt)	references/doc-spec.md
S8 skill prompt layer (skill-prompt)	references/integration-patterns.md
S8 skill prompt layer (skill-prompt)	references/output-templates.md
S8 skill prompt layer (skill-prompt)	references/spec-lifecycle-actions.md
S8 skill prompt layer (skill-prompt)	references/spec-lifecycle-protocol.md
S8 skill prompt layer (skill-prompt)	references/tool-mappings.md
S1+S2 doc-tools (shell-tool)	scripts/doc-tools.sh
S6 CI templates+repo workflows (ci-workflow)	scripts/hooks/ci/doc-audit-update.yml
S6 CI templates+repo workflows (ci-workflow)	scripts/hooks/ci/doc-freshness-pr.yml
S6 CI templates+repo workflows (ci-workflow)	scripts/hooks/ci/doc-freshness-schedule.yml
S6 CI templates+repo workflows (ci-workflow)	scripts/hooks/ci/doc-index-update.yml
S6 CI templates+repo workflows (ci-workflow)	scripts/hooks/ci/doc-pr-full-cycle.yml
S7 PR-release pipeline (ci-workflow+shell-tool)	scripts/hooks/ci/doc-pr-release.yml
S7 PR-release pipeline (ci-workflow+shell-tool)	scripts/hooks/ci/doc-pr-release/RELEASE-NOTES.next.README.md
S7 PR-release pipeline (ci-workflow+shell-tool)	scripts/hooks/ci/doc-pr-release/commit-and-push.sh
S7 PR-release pipeline (ci-workflow+shell-tool)	scripts/hooks/ci/doc-pr-release/extract-context.sh
S7 PR-release pipeline (ci-workflow+shell-tool)	scripts/hooks/ci/doc-pr-release/update-pr-body.sh
S7 PR-release pipeline (ci-workflow+shell-tool)	scripts/hooks/ci/doc-release.yml
S6 CI templates+repo workflows (ci-workflow)	scripts/hooks/ci/doc-review-pr.yml
S6 CI templates+repo workflows (ci-workflow)	scripts/hooks/ci/doc-spec-verify.yml
S5 runtime hooks (shell-tool, templates+self-install)	scripts/hooks/claude/post-commit-sync.sh
S5 runtime hooks (shell-tool, templates+self-install)	scripts/hooks/claude/pre-commit-gate.sh
S5 runtime hooks (shell-tool, templates+self-install)	scripts/hooks/claude/session-summary.sh
S5 runtime hooks (shell-tool, templates+self-install)	scripts/hooks/git/post-checkout
S5 runtime hooks (shell-tool, templates+self-install)	scripts/hooks/git/post-merge
S5 runtime hooks (shell-tool, templates+self-install)	scripts/hooks/git/pre-commit
S5 runtime hooks (shell-tool, templates+self-install)	scripts/hooks/git/pre-push
S5 runtime hooks (shell-tool, templates+self-install)	scripts/hooks/git/prepare-commit-msg
S4 installer+state (shell-tool)	scripts/hooks/install.sh
S4 installer+state (shell-tool)	scripts/hooks/state.sh
S3 merge driver (shell-tool)	scripts/merge-doc-index.sh
S9 test suites (test)	scripts/test-doc-pr-release.sh
S9 test suites (test)	scripts/test-doc-tools.sh
S9 test suites (test)	scripts/test-helpers.sh
S9 test suites (test)	scripts/test-hooks.sh
S9 test suites (test)	scripts/test-merge-driver.sh
S9 test suites (test)	scripts/test-spec-status-model.sh
S8 skill prompt layer (skill-prompt)	skills/doc-superpowers/SKILL.md
```

## Prototypes

Audit-time scripts. Each was run only in scratch clones and none is shipped. All are bash + git + jq.

### `repro/lib.sh`

Shared helpers for the prototype below.

```bash
DT=/home/user/doc-superpowers/scripts/doc-tools.sh
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkrepo() {
  d=$(mktemp -d -p /tmp/claude-0/-home-user-doc-superpowers/1286c2f8-50a9-5f2b-9d0e-9d02c19207dc/scratchpad/repro r.XXXX); cd "$d"
  git init -q -b main .
  mkdir -p src docs
  echo 'v1' > src/a.sh; echo 'b1' > src/b.sh
  echo '# A doc' > docs/a.md
  git add -A; git commit -qm init
  printf 'docs/a.md:src/a.sh:guide\n' | bash $DT build-index
  git add -A; git commit -qm 'index'
}
fresh() { bash $DT check-freshness | jq -c '.docs["docs/a.md"] | {status, commits_behind, code_refs_changed}'; }
```

### `repro/proto.sh`

**Content-identity prototype (the T4 design).** It stores `code_oids` per ref, captured from the working tree at verification time. `check [--staged]` compares them against HEAD, or against the staged tree for pre-commit. This is the shape Task T4 implements inside `doc-tools.sh`.

```bash
#!/usr/bin/env bash
# Prototype: content-identity freshness. Index file: docs/.proto-index.json
#   { docs: { "<doc>": { code_refs: [...], code_oids: {ref: oid|"missing"}, verified_head: sha } } }
# verify <doc...>  : fingerprint refs as they are in the WORKING TREE (what the verifier read)
# check [--staged] : compare against HEAD tree (default) or the staged tree (pre-commit)
set -euo pipefail
IDX=docs/.proto-index.json
[ -f "$IDX" ] || echo '{"docs":{}}' > "$IDX"
worktree_tree() {  # tree of working tree content without touching the real index
  local tmp; tmp=$(mktemp); cp "$(git rev-parse --git-path index)" "$tmp" 2>/dev/null || rm -f "$tmp"
  GIT_INDEX_FILE=$tmp git add -A -- . >/dev/null 2>&1; GIT_INDEX_FILE=$tmp git write-tree; rm -f "$tmp"
}
oids_for() {  # $1=tree ; stdin: "doc<TAB>ref" lines -> "doc<TAB>ref<TAB>oid"  (ONE git process for all)
  local tree=$1 lines; lines=$(cat)
  [ -z "$lines" ] && return 0
  paste <(printf '%s\n' "$lines") <(printf '%s\n' "$lines" | cut -f2 | sed "s#/*\$##; s#^#$tree:#" \
     | git cat-file --batch-check='%(objectname)' | awk '{print ($2=="missing")?"missing":$1}')
}
case "$1" in
  add) shift; doc=$1; shift; jq --arg d "$doc" '.docs[$d]={code_refs:$ARGS.positional}' "$IDX" --args "$@" > "$IDX.t" && mv "$IDX.t" "$IDX" ;;
  verify) shift; T=$(worktree_tree); H=$(git rev-parse HEAD)
    for d in "$@"; do jq -r --arg d "$d" '.docs[$d].code_refs[] | [$d, .] | @tsv' "$IDX"; done | oids_for "$T" \
    | jq -Rn --arg h "$H" --slurpfile idx "$IDX" 'reduce (inputs|split("\t")) as [$d,$r,$o] ($idx[0]; .docs[$d].code_oids[$r]=$o | .docs[$d].verified_head=$h)' > "$IDX.t" && mv "$IDX.t" "$IDX" ;;
  check) T=HEAD; [ "${2:-}" = "--staged" ] && T=$(git write-tree)
    jq -r '.docs|to_entries[]|.key as $d|.value.code_refs[]|[$d,.]|@tsv' "$IDX" | oids_for "$T" \
    | jq -Rn --slurpfile idx "$IDX" '
        [inputs|split("\t")] | group_by(.[0]) | map({ (.[0][0]): (
           [ .[] | select($idx[0].docs[.[0]].code_oids[.[1]] != .[2]) | .[1] ] as $ch
           | {status: (if ($ch|length)>0 then "stale" else "current" end), code_refs_changed: $ch}) }) | add' ;;
esac
```

### `s1perf/oidcheck.sh`

**Reader-only OID check.** It compares `<stored code_commit>:<ref>` with `HEAD:<ref>` in one `git cat-file --batch-check` pass. It is fast (12,000 refs in 0.25 s), but it is **not sufficient on its own**: after a squash merge plus a branch delete, the stored commit object is absent in fresh clones. That is why T4 *stores* the OIDs.

```bash
#!/usr/bin/env bash
# Prototype: stale iff any ref's tree/blob OID at the stored code_commit differs from HEAD.
# ONE git process for all docs; no history walk. Output TSV: doc \t stale|current|unknown \t changed_refs_csv
set -euo pipefail
idx="$1"
jq -r '.docs | to_entries[] | select(.value.status != "deprecated") | .key as $k | (.value.code_commit // "") as $c
       | (.value.code_refs // [])[] | select(. != "") | sub("/+$"; "") | [$k, $c, .] | @tsv' "$idx" > /tmp/oid_rows.$$
# two lookups per (doc,ref): baseline and HEAD. "." (repo root) -> "<rev>^{tree}"
awk -F'\t' '{ p=($3=="."||$3=="")?"^{tree}":":" $3; b=($2=="")?"MISSINGBASE":$2; print b p; print "HEAD" p }' /tmp/oid_rows.$$ |
  git cat-file --batch-check='%(objectname)' | paste - - > /tmp/oid_res.$$
paste /tmp/oid_rows.$$ /tmp/oid_res.$$ | awk -F'\t' '
  { k=$1; if (!(k in st)) { st[k]="current"; ord[++n]=k }
    base=$4; head=$5
    if (base ~ / missing$/ && head !~ / missing$/) { if (st[k]!="stale") st[k]="unknown" }
    else if (base != head) { st[k]="stale"; ch[k]=ch[k] (ch[k]==""?"":",") $3 } }
  END { for (i=1;i<=n;i++) print ord[i] "\t" st[ord[i]] "\t" ch[ord[i]] }'
rm -f /tmp/oid_rows.$$ /tmp/oid_res.$$
```

### `s1perf/onewalk.sh`

**One-walk alternative.** It computes every doc's last-touching commit in a single `git log --name-only` pass instead of per-doc walks: 0.79 s for 4,000 docs at H=3k and 0.46 s at H=30k, with the same stale set on a linear history. Useful as a legacy-entry fallback, because entries without `code_oids` still need `code_commit` logic.

```bash
#!/usr/bin/env bash
# Prototype: derive "newest commit touching refs" for EVERY doc from ONE history walk.
# Usage: onewalk.sh <index.json>   (run from repo root). Output: TSV doc \t code_commit
set -euo pipefail
idx="$1"; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# distinct refs (normalized: strip trailing "/"; "." and "" => root)
jq -r '.docs[] | (.code_refs // [])[] | select(. != "")' "$idx" | sed 's:/*$::' | sort -u > "$tmp/refs"
git log --format='@%H' --name-only --no-renames --diff-merges=combined HEAD -- 2>/dev/null |
awk -v reffile="$tmp/refs" '
  BEGIN { while ((getline r < reffile) > 0) { if (r == "" || r == ".") root=1; else { want[r]=1; total++ } } if (root) total++ }
  /^@/ { cur=substr($0,2); n++; next }
  $0 == "" { next }
  {
    p=$0
    if (root && !rootdone) { rootdone=1; print ".\t" cur "\t" n; got++ }
    while (1) {
      if ((p in want) && !(p in done)) { done[p]=1; print p "\t" cur "\t" n; got++ }
      if (index(p, "/") == 0) break
      sub(/\/[^\/]*$/, "", p)
    }
    if (got >= total) exit
  }' > "$tmp/first"
# join: per doc, the ref whose first-hit ordinal is smallest
jq -r --rawfile first "$tmp/first" '
  ($first | split("\n") | map(select(length>0) | split("\t")) | map({key: .[0], value: {c: .[1], o: (.[2]|tonumber)}}) | from_entries) as $F
  | .docs | to_entries[]
  | [ .key, ( [ (.value.code_refs // [])[] | select(. != "") | sub("/+$"; "") | (if . == "" then "." else . end) | $F[.] // empty ] | min_by(.o) | .c // "" ) ] | @tsv' "$idx"
```


## Verifier reports: Phases 2–3

### V-S1

### Phase-3 VERIFIED — S1 doc-tools core (1–1255 + dispatcher) + X-DATAFLOW lifecycle

KEPT
[P1] doc-tools.sh:311,503 — INT/TERM trap cleans + resumes: single-pid TERM @1.5 s 3/3 rc 0, index 225–228/300 (first ~75 lost); group TERM 1/6 rc 0 w/ 215 entries (5/6 rc 143 intact); `timeout -s INT 1.5` (Ctrl-C-like) 2/5 IGNORED the signal, ran to completion, installed 234/244-entry indexes (caller sees 124); NEW: `{ sleep 10; } | timeout 3 build-index` → TERM swallowed while blocked on stdin → runs to EOF → installs EMPTY index (6→0 keys); direct TERM on a stuck build-index left it alive; check-freshness TERM → summary 300 vs 213/168 docs. P0→P1 (only after an interrupt; no hook/CI runs build-index; worst realistic: N≈4000 build-index ~117 s ≈ agent Bash tool 120 s default timeout).
[P1] X doc-tools.sh:177,365,569,743,867 (+ git/pre-commit:26, claude/pre-commit-gate.sh:37) — SHA-keyed freshness: squash → stale commits_behind 1 while `git rev-parse <stored>:<ref>` == `HEAD:<ref>` for both refs (content model current); real change → stale under both; code+doc+update-index one commit → stale after; staged invalidating change reads current. CAVEAT: fresh clone after squash + branch delete → stored commit object ABSENT → reader-only `<code_commit>:<ref>` batch-check cannot fix squash for CI/other clones; only STORING ref OIDs in the index (code_oids) does. measured.
[P1] doc-tools.sh:564-597,166-207 — per-doc walks: N=100 1,687 ms (16.9 ms/doc), N=400 6,462 ms (16.2 ms/doc), H=201 → t ≈ 16.1 ms·N + 0.08 s (~65 s @ N=4000/H=200; consistent with finder's 117 s @ H=3k); clone of this repo 689 ms / 36 docs. measured.
[P1] doc-tools.sh:511,519,627-640 — check-freshness inline copy tab-collapse diverges from status (null code_commit / null content_hash / empty doc_type / `src/c.txt,,src/d.txt` / glob + git rm / TAB in key). all measured.
[P1] doc-tools.sh:316-453 — build-index replaces whole index on zero/partial input (empty stdin → {} rc 0; `--help </dev/null` → {}; background build-index with stdin /dev/null as in agent harness → 0 keys; one-line pipe → only that key; deprecations reset). SKILL.md:639 routes untracked docs to it. measured.
[P1] doc-tools.sh:1111,460-472,1973 — positional-only flags; unknown options accepted (deprecate-entry successor deprecated rc 0; --code-refs=x / positional ignored → full report; `remove-entry --help` → "Removed 0 entries: --help" rc 0, index rewritten). measured.
[P1] doc-tools.sh:776-787 — update-index clears deprecation; documented supersede flow reaches it (spec-lifecycle-actions.md:96 then :116). measured.
[P1] doc-tools.sh:324-326,363-366,829-831,865-868 — unvalidated stdin parser (bare path; `a, b` leading space → never matches; CRLF; colon in path → wrong key; typo'd ref → null code_commit; duplicate key policy differs). measured.
[P1] X ci/doc-index-update.yml:25,30,52 (+ no shallow guard in doc-tools) — fails in normal case (index path in list → rc 1); wrong SHAs when it runs (depth-2 → HEAD~1 boundary 3cb7950 vs real 18fc3fb); self-installed copy can't run. measured. (← S1-CORR P0 shallow, S1-PERF fetch-depth)
[P1] X SKILL.md:639,373; doc-tools.sh:378-401,878-900,1157; claude/post-commit-sync.sh:28 — non-verifying writers stamp status=current + last_verified=now (build-index re-baselines to HEAD; add-entry baselines to HEAD; deprecate-entry bumps last_verified); post-commit-sync/session-summary update-index dead. structural + measured.
[P2] doc-tools.sh:526-537 — --code-refs raw string-prefix (`src/m1` matched 260/400, expected 40; `''` matches all; quoted non-ASCII path "src/caf\303\251.ts" → filtered stale 0 vs unfiltered 1); cost ~4 µs per entry×ref×path (S=200 @ N=400: 718 ms vs 71 ms). P1→P2 (typical S ≤ 30 → <1 s @ N=4000; finder's 12.4 s pull figure dominated by per-doc walks).
[P2] doc-tools.sh:56,177,365,569,743,867 — failed git == no history (outside repo: current 1, rc 0). measured.
[P2] doc-tools.sh:193-208,580-597 — code_refs_changed/commits_behind wrong (squash → both refs listed; b-only change → both listed; null code_commit → stale, 0, []). measured.
[P2] doc-tools.sh:485-488,627-656,694-701,811-814 — index shape never validated (0-byte → rc 0 all untracked; add-entry "Added 1 entry" 1-byte file; {"docs":[]} → rc 0). measured.
[P2] doc-tools.sh:701-980,1131-1167 — O(k·N) writers (update-index k=20: 23 ms/doc @ N=100 vs 32 @ N=400; remove-entry 205 → 299 ms). measured.
[P2] doc-tools.sh:578-581 — commits_behind for every current doc (~half of git time). measured.
[P2] doc-tools.sh:511,629-641 — read -d '' from process substitution: 73,985 read syscalls for 73,784 B; 71 ms floor per scoped call. measured.
[P2] doc-tools.sh:177,365,569,743,867 — porcelain git log honors log.showSignature (build-index rc 0 writes "No signature\nf632c82…"; update-index rc 2). P1→P2 (opt-in config; loud).
[P2] X doc-tools.sh:384,401,884,900 — stored current/stale status dead data (no writer stores "stale"; build-index resets deprecations). structural.
[P2] X doc-tools.sh:657; SKILL.md:335 — point-in-time records go stale by design (clone: 23/36 stale, 21 records: superpowers 13, plans 4, issues 2, archive 2; indexed archive entries still evaluated). measured.
[P3] doc-tools.sh:712-717 — update-index unknown key aborts whole batch (loud, no partial write). P2→P3.
[P3] doc-tools.sh:28-34 — hash_file backslash filename → invalid JSON rc 2 (measured); leading '-' structural.
[P3] doc-tools.sh:56 — unborn HEAD → build_commit "HEAD\nunknown". measured.
[P3] doc-tools.sh:124-129 — `docs//a.md` separate key. measured.
[P3] doc-tools.sh:982-985,1169-1172 — remove/deprecate report requested not changed. measured.
[P3] doc-tools.sh:437,453 — index installed 0600. measured. known: index-write-not-atomic.
[P3] doc-tools.sh:758-768 — Implementation: capture reads inside code fences; 4-space/tab bullets unstripped. measured.
[P3] doc-tools.sh:371-405,872-904 — build-index/add-entry never write `implementation` (10/36 entries have it) vs conventions.md:335. P2→P3.
[P3] doc-tools.sh:284,428,429,510 — lying comments ("Subcommand stubs"; absent plan doc; "only test helpers read the field"; "add-entry rejects colons"). structural + measured.
[P3] doc-tools.sh:281,1970,2004-2005 — dispatcher (--help rc 1; no unknown-subcommand msg; help needs jq). structural.
[P3] X SKILL.md:290; doc-spec.md:33 — in-doc date+commit marker is a second, unread freshness claim. structural.
DROPPED
compute_freshness:207 `[""]` — unreachable (stale ⇒ ≥1 ref differs ⇒ changed_refs non-empty).
X-DATAFLOW "REAL DATA identical content yet 4 docs stale" as current false-stale proof — overstated: c2496da1 vs ec4a962 identical for its refs, but all 4 docs' refs differ from HEAD today → stale under content model too; proves re-minted SHAs entered the index (5 entries), not a current false-stale.
S1S2-DEAD "validate_docs.py is downstream" — SKILL.md documents it as an optional user-provided script.

### V-S2

### Phase-3 VERIFIED — S2 doc-tools.sh 1256–2006

KEPT
[P1] doc-tools.sh:1665,1684-1687,1699-1706 — set-implementation splices --ref/--note/--status into grep -E + GNU sed program text → sed e/w injection (measured pwned-C1, written-C3, pwned-C2 with `commit: abc1234` ref) AND benign-input corruption: `(squash)` → duplicate; `R&D` → "R  - PR: #1 — in-progressD"; `a|b` → sed error rc 1; `C:\temp\new` → TAB+newline; `--status '.*'`/`'complete partial'` accepted; `--ref` no value → unbound variable; with `PR: #N` refs the matched bullet is DELETED. One root cause; one fix: awk index() + ENVIRON → tmp+mv. (SHELL verifier rated the security aspect P2; correctness corruption on benign input keeps cluster P1.)
[P1] doc-tools.sh:1702-1706 — create path anchors `**Date:**`; templates use `**Date**:` (doc-spec.md:227) / `**Created**:` (:190) → rc 0, file byte-identical (cmp IDENTICAL both). Two `**Date:**` lines → two blocks. RELEASE-NOTES.md:121 documents `**Date:**` anchor → code, docs, templates disagree.
[P1] doc-tools.sh:1686-1698,1729-1735 vs 758-762 — one writer + two readers, different Implementation grammars; all 5 sub-cases measured (Realized-by → PR #1 drops from index; `[]` append invisible; appended inside later ```yaml fence; "## Rollout log" line rewritten; 4-space bullets → misplace + duplicate).
[P1] doc-tools.sh:1571,1601,1603-1605 — fragments merge drops last line w/o trailing newline, still lists in --paths-out → SKILL step 9 git rm. measured.
[P1] doc-tools.sh:1565-1605 — merge discards body text not under a `### ` heading, still records consumed. measured; WIDER: a hash-VALID fragment with no heading → empty output, NO warning, listed for deletion. Contradicts README.next:60.
[P2] doc-tools.sh:40-49,1678-1680 (+ tests.yml:66-71) — GNU sed dependency for one verb only; loud failure; folds into awk rewrite.
[P2] doc-tools.sh:1363,1572,1539-1545 — headings/markers not trimmed (trailing space → duplicate section; CRLF → validate rc 1 silent, merge emits "### Added" + "### Added^M"). measured.
[P2] doc-tools.sh:1410,1417-1418,1447-1452,1280-1281,1300 — errexit+pipefail silent aborts (list on marker-less OR heading-less fragment rc 1 no output; validate "no hash marker" unreachable; check-version w/o RELEASE-NOTES rc 2 silent; bump-version malformed manifest → 5 "bump:" lines then rc 5 silent = partial bump). measured.
[P2] doc-tools.sh:1747-1750 — implementation-status --filter broken + undeclared rg (P1→P2: zero callers; only RELEASE-NOTES:120 documents it). measured.
[P2] doc-tools.sh:1593,1620 — line-level dedupe drops shared sub-bullets/fence lines, blank lines dropped (P1→P2: uncommon trigger; draft reviewed at SKILL step 7). measured.
[P2] doc-tools.sh:1862-1891 — tools uninstall rm -rf's user-added files in doc-pr-release/ and a DRIFTED doc-tools.sh (P1→P2: vendored files are committed → recoverable; violated byte-for-byte promise for non-.sh files is the real bug). measured.
[P3] doc-tools.sh:1275-1278,1289,1315-1316,1337 — bump/check-version succeed on 0 files; mode 644→600. measured. (dropped sub-claim: failing write-jq counted as bump — unreachable)
[P3] doc-tools.sh:1300,1958 — check-version first-substring version (P2→P3: maintainer-only; loud).
[P3] doc-tools.sh:1504-1505 — invalid range ref swallowed (P2→P3: fragments at HEAD are ancestors of HEAD; only leftovers affected; tests' empty-tree hash "works" only because rc 128 swallowed).
[P3] doc-tools.sh:1467-1470,1995 — --paths-out only `=` form as 4th arg (P2→P3: "double up next release" WRONG — leftovers excluded by range; SKILL `[[ -s ]]` guard skips deletion silently → fragments linger).
[P3] doc-tools.sh:1759-1763,1817-1818 — tools install from vendored copy: cp same file rc 1. measured.
[P3] doc-tools.sh:1914-1927,1952-1965 — tools status from vendored copy self-compares, reports consumer's version as plugin's (SKILL.md:106 tells users to rely on it). measured.
[P3] doc-tools.sh:1388,1712; 1343-1357,1383-1391,1399-1433; 229-230,1970,2004-2005 — misleading comments; dead/redundant fragment helper branches; O(F²) list; dispatcher (--help rc 1 on stderr; no "unknown subcommand"; check_deps before dispatch). structural/measured.
DROPPED: "failing jq in `jq > tmp && mv` still counted as bump:" — unreachable except on I/O failure.

### V-S3

### Phase-3 VERIFIED — S3 merge driver

KEPT
[P0] merge-doc-index.sh:47-53,61,64-65,70-71 — never compares to base ($base_docs only in has()); whole-entry newer-last_verified wins (tie → %A); key missing on one side dropped even if other side changed it. measured, real git merge through registered driver: (a) deprecate vs update-index → deprecation undone both directions; (b) move-entry repoint + hand-edited code_refs lost in one merge direction and in `git rebase` (dangling superseded_by); (c) revert of deprecate commit doesn't revert; (d) move vs re-verify → re-verification lost (current + doc_modified); (e) one-sided change with older last_verified dropped. Docs (issue 2026-05-04:92 "rebase … driver resolves silently"; system-overview.md:159; codebase-guide.md:125/184 "three-way merge") recommend/misdescribe the lossy path.
[P2] install.sh:187-190 — driver registered as unquoted absolute versioned path: space/missing → CONFLICT, 0 markers (measured); version pinning means the P0 fix won't reach consumers until re-install (structural).
[P2] merge-doc-index.sh:32,55-57,84 — `jq empty` admits 0-byte/"\n"/null/{} theirs → all base entries deleted exit 0; 0-byte ours → %A "\n"; concatenated docs written. measured. (widens index-write-not-atomic blast radius)
[P2] test-merge-driver.sh:17-41,49-157,244-251 — no fixture compares against base (why P0 passes); hand-built version:1 fixtures; Test 8 pins version-max. structural.
[P3] merge-doc-index.sh:14,39-40,77-83 — top-level rebuilt from hard-coded list: drops schema_version (measured {"version":0}), build_commit = merge-time HEAD, generated_at wall clock; fix = start from ours. known: merge-driver-reads-version / metadata-rewrite.
[P3] merge-doc-index.sh:18,76 — sorts .docs vs insertion-order writers → 120-entry reverse index, one re-verify per side → 247+/246- diff. measured.
[P3] install.sh:242-248 — uninstall leaves 0-byte .gitattributes; test-hooks.sh:773 can't catch it. measured.
[P3] test-merge-driver.sh:43-46,314-315 — mktemp X's before suffix (BSD literal names) + no trap. structural.
DOWNGRADED
merge-doc-index.sh:10-11,27-35 failing driver leaves ours with no markers (header comment false) P2→P3 (not silent: CONFLICT/UU + stderr; needs corrupt side).
test-merge-driver.sh:186-207 failure-path gap P2→P3; test-hooks.sh registration-string-only P2→P3; ISO string compare P3→P4 (only hand edits).
DROPPED
".gitattributes absent in this repo" — not a defect (repo deliberately self-installs Claude+CI tiers only; driver registration is per-clone .git/config).

### V-S4S5

### Phase-3 VERIFIED — S4+S5 installer, state, runtime hooks

KEPT
[P1] claude/pre-commit-gate.sh:14-23, post-commit-sync.sh:13-22 (+ .claude copies) — read $TOOL_INPUT (never set) + wrong jq path .command → gate + sync never activate. measured (stdin payload, TOOL_INPUT unset, STRICT=1, through exact settings wrapper → rc 0 no output; with TOOL_INPUT → rc 2). test-hooks.sh injects TOOL_INPUT (8 refs). Latent behind it: regex false matches (commit-graph, echo "…git commit") / misses (git -C, git -c); PreToolUse before `git add -A && git commit` stages.
[P1] claude/*.sh output channel — stdout exit 0 → debug log only (PreToolUse/PostToolUse/Stop); STRICT exit 2 with empty stderr (measured 150 B stdout / 0 B stderr) → blocked without reason. Live today for session-summary; "session ending" wrong (Stop fires every turn).
[P1] git/prepare-commit-msg:7-10,29-39 — `#` lines committed with -m / -F / --amend --no-edit (each amend adds a copy). measured. History pollution in default agent commit mode.
[P1] install.sh:147-172 — integration block: bash-only in #!/bin/sh hook (`[[: not found` every commit); drops "$@" (prepare-commit-msg no file, post-checkout no revs); `|| true` swallows STRICT (measured commit rc 0 with stale doc under bash shebang). Structural: appended after `exec` (pre-commit framework), husky `.husky/_` stubs, before every column-0 `exit 0`.
[P1] install.sh:335-340, 362-365 — Claude-settings ownership = substring "doc-superpowers" anywhere in a hook GROUP → install + uninstall delete user hook groups incl. unrelated hooks (measured lint-on-edit.sh deleted; "echo notify doc-superpowers-fan" Stop hook deleted). P0→P1 (precondition: a user hook in the group mentions "doc-superpowers"; settings.local.json normally untracked → unrecoverable). .gitattributes sub-part P3.
[P2] pre-commit timing — git/pre-commit:16-31, prepare-commit-msg:15-26, claude gate:29-41 evaluate HEAD history → warn one commit late; code+doc+update-index in one commit still stale; STRICT blocks the NEXT commit. measured. P1→P2 (not silent; root cause = index model → I-1).
[P2] claude/session-summary.sh:16-32,47 — unscoped full scan, 1 s timeout, silent (152 entries: 3.67 s full; hook rc 0 at 1.02 s, 0 bytes); ~1 s per turn. P1→P2.
[P2] install.sh:144,181,304,187-190 + hooks line 5/7 — install path interpolated raw: space → DOC_TOOLS first word → all hooks no-op (measured "My Skills/…" STRICT commit rc 0); merge driver unquoted → CONFLICT 0 markers ours-only → theirs lost on git add (measured vs control). P1→P2 (uncommon path; severe when hit).
[P2] install.sh:16 + hooks — `__DOC_TOOLS_PARENT__/*/…| sort -V | tail -1` sibling pickup (measured code/zeta-app/scripts/doc-tools.sh executed on commit); sort -V absent in GNU sort 5.93 (macOS ≤12) → every hook no-op (structural). P1→P2 (needs shared-folder clone path + sibling with scripts/doc-tools.sh).
[P2] install.sh:106-126,209-216,293-299,519 — hooks dir/root from cwd + guesses: all 5 measured (.githooks present but hooksPath unset → "✓ installed ×5" yet git runs .git/hooks; core.hooksPath=~/my-hooks → literal ./~ dir; GLOBAL hooksPath → writes/splices user's global hooks dir; linked worktree rc 1 and --all aborts before Claude/CI; run from packages/web → packages/web/.github/workflows (9) + packages/web/.claude). P1→P2.
[P2] install.sh:478-486,541-553; state.sh:175-188 — state records "installed" not choices → plain re-install flipped STRICT "1"→"0", installed 9, rewrote installed_at (measured). This repo ships no installed.json though README:197 + CLAUDE.md say committed; its own STRICT "1" would flip.
[P2] install.sh:312-342,358-373 — settings merge breaks: type:"prompt" hook → jq rc 5 after scripts copied, --claude --ci never reaches CI; 0-byte settings → "3 installed", 0-byte file, status ✗. measured.
[P2] install.sh:136-141 — integrated hook's .doc-superpowers-<hook> never re-rendered on re-install (measured old pin kept); RELEASE-NOTES.md:82 "operators get the fix on the next hooks install run" false for integrated installs.
[P2] all hooks `2>/dev/null) || exit 0` — tooling failure == tooling missing (conflict-marker index → check-freshness rc 5 → STRICT commit over stale doc passes silently); DOC_INDEX knob honored by hooks, 0 refs in doc-tools. measured. (+x sub-case weak: doc-tools.sh is 100755 in git)
[P2] git/post-merge:18, post-checkout:22 (+ pre-commit:16, prepare-commit-msg:15, claude gate:29, sync:31) — `git diff --name-only` without --no-renames → old path never in scope (measured: merge of git mv → post-merge silent while docs/b.md stale).
[P2] .claude/settings.local.json:1-65 (tracked); .claude/hooks/doc-superpowers/*.sh:5; root cause install.sh:296-349 — installer writes Claude wiring into a personal settings file it never git-ignores; this repo committed it with /Users/w paths + broad allows (Bash(git push:*), Bash(gh repo:*), Bash(done), Bash(do git:*)); self-installed hooks hard-pin DOC_TOOLS=/Users/w/… → repo's own Claude tier dead on every clone (git diff vs templates = exactly lines 2 and 5). measured.
[P2] install.sh:187-190 — merge driver pinned to install-time version dir → driver fixes never reach existing installs. structural (failure mode measured via space-path mechanism).
[P2] install.sh:423-428; ci/doc-pr-full-cycle.yml:5-7 — default --ci installs both doc-review-pr + doc-pr-full-cycle ("one or the other, not both"); help/menu understate (P3 part). measured.
[P3] install.sh:144,181,304,481-486,549-550 — unescaped sed + masked failure (`rel&hotfix` → rel__BASE_BRANCH__hotfix; `a|b` → 0-byte workflow, "1 installed", rc 0, stuck). measured. P1→P3.
[P3] install.sh:157-172,226-229 — symlinked user hooks de-linked / appended through into tracked file (measured; no content destroyed; visible in git status). P0→P3.
[P3] git/post-merge:30-32,51-55 — global .summary.untracked noise. measured. P2→P3.
[P3] hooks → doc-tools.sh:526-535 — O(N×F×R) filter: measured 0.25 s @ F=1, 1.10 s @ F=100, 4.51 s @ F=500 (N=4019, R=3) — linear, ~5.6× below the finder's 25.3 s; not a freeze here. P2→P3. (Note: S1-PERF measured 39.3 s @ S=1000 on a different corpus with 350 matches — cost depends on match/ref shape.)
[P3] install.sh:163-164,226-229 — integrated uninstall not inverse (blank-line squeeze; loose pattern deletes; begin w/o end → EOF). structural.
[P3] install.sh:575-606 — helpers installed even when doc-pr-release intentionally skipped. measured.
[P3] install.sh:447-453 via 656-659 — uninstall --workflows=<typo> ERROR but rc 0. measured.
[P3] install.sh:643-646,676-687 — comments promise checks the code doesn't do. structural.
[P3] install.sh:243-247,373,519 — full uninstall residue (0-byte .gitattributes, settings {}, empty .github/workflows). measured.
[P3] state.sh:91-100 — syntax-only validity (`[]` → jq rc 5 after 1 workflow). measured.
[P3] install.sh:457 — unguarded "${names[@]}" (bash 3.2 noise). structural.
[P3] install.sh:144,181,304 — dead __DOC_TOOLS_PATH__ substitution; SKILL.md:507 warning + absence assertion vacuous. measured.
[P3] install.sh:17-18,93-101; state.sh:51-58 — exact-string "v1" markers; removed templates never uninstalled. structural.
[P3] git/post-checkout:41,49 — trailing comma. measured.
[P3] claude/session-summary.sh:22-29 — no-timeout fallback holds stdout ≥1 s (1.10 vs 0.10 s), reused-PID kill, predictable /tmp. measured.
[P3] git/pre-push:5-13 — ignores pushed refs; no DOC_TOOLS guard. structural.
DROPPED
"QUIET=1 + STRICT=1 blocks with no output" — documented behavior (README.md:206).
"move-entry plan:440 falsely claims copies differ only in placeholders" — diff confirms exactly lines 2 and 5.
"precondition recommended by getting-started.md:109" — that line is the vendoring path, not a hook recipe.
"Stop matcher '' ignored" — harmless.
CI-surface items in S4S5 (verified on CI).

### V-S7

### Phase-3 VERIFIED — S7 per-PR release-notes pipeline  (all 3 P0s → P1)

KEPT
[P1] doc-tools.sh:1571-1601 (1593, 1601); README:60-61 — merge parser drops lines 1-2 unchecked + any pre-heading line; file still in --paths-out → SKILL step 9 git rm. measured (PR-12 hash-line deleted → Fixed lost; PR-13 no markers → Security lost; PR-14 pre-heading bullet lost with NO warning). Consumer never checks `doc-superpowers:fragment` marker (only extract-context.sh:90). P0→P1: needs format deviation; recoverable from git; step 4 draft + step 7 review backstops.
[P1] commit-and-push.sh:72 + 62-93 — human force-push removing commits between checkout and push → bot silently restores them. measured both paths: (i) drop tip + force-push → runner's bot→C2→C1 is a FAST-FORWARD → plain push :72 succeeds, C2 back; (ii) drop + new C3 → rejected → rebase replays C2. rc 0 both. ROOT CAUSE CORRECTED: finder's `rebase --onto` fix wouldn't fix (i); need compare-and-swap: fetch first, abort (or --force-with-lease=<branch>:<checkout-sha>) when checkout SHA not ancestor of fetched tip. Normal rebase-onto-main force-push safe (patch-id skip). P0→P1.
[P1] doc-tools.sh:1495-1507; README:36-45; SKILL.md:449-458, 471-475, 478-481 — "already released" = ancestry of OLDEST touching commit while consumption = deletion. measured (a) release/1.1 cut, PR-12 merged to main, release merged back, tag v1.1 on main → PR-12.md never released nor deleted, rc 0, no warning; (b) feat→revert→tag→reapply → consumed=[] PR-42.md left. P0→P1: depends on tag placement (tag on release branch / git-flow safe; doc-release.yml:95 doesn't say where); not destroyed. Step 5/6 duplication redundant not contradictory.
[P1] extract-context.sh:133 — new_commits LAST_FRAG..HEAD doesn't exclude base → after "Update branch", other PRs' commits "new" for this PR. measured.
[P1] doc-pr-release.yml:227-236, 274-305; extract-context.sh:76-97; commit-and-push.sh:41-52; README:63-70 — "will not overwrite human edits" + hash verify rely only on LLM compliance. measured (pre-receive reject → commit-and-push rc 1, verify prints success rc 0; `hash deadbeef` passes verify while validate says drifted; no-commit branch passes whenever file exists).
[P1] doc-release.yml:33-34 — `!contains(head_commit.message,'[doc-superpowers]')` → release job skipped when release branch cut at squash commit (squash body lists bot sync commits). structural. CORRECTION: with rebase-merge the tip is often the bot sync commit itself, so `startsWith` fix insufficient → match exact "[doc-superpowers] draft release notes" subject. needs-runtime to confirm.
[P2] extract-context.sh:99-105, 133; commit-and-push.sh:48-52, 85-88; doc-pr-release.yml:99-108 — watermark skips pre-watermark never-integrated commits. measured. P1→P2 (race/bundled edit; full_commits + release gap-fill backstops).
[P2] update-pr-body.sh:58-75, 101-117 — marker order/context unchecked (END-before-START deletes human Testing + checklist; fenced example replaced; trailing space → permanent refuse). measured. P1→P2 (unusual human edit; GitHub keeps edit history).
[P2] doc-pr-release.yml:110-111, 127-129, 146-147, 280-281 — sentinel skip doesn't gate later steps ('' != '0'). needs-runtime.
[P2] README:18-26; doc-pr-release.yml:218-221; SKILL.md:448 — section vocabulary disagreement (this repo: Features 17, Fixes 16, Other 8, Documentation 3, Changed 1, Breaking Changes 1); producer set has no breaking slot. structural.
[P2] extract-context.sh:91; README:63-70 — no deterministic opt-out/re-seal (empty-payload fragment: validate valid, extract-context corrupt → reconcile comment every push). measured.
[P3] doc-pr-release.yml:13-19 — paths-ignore rationale wrong. needs-runtime.
dups confirmed present (verified elsewhere): line-level dedupe (S2), merge ref/flag validation (S2), grep pipefail list/validate (S2), commit w/o pathspec (SHELL), dispatch fork bypass (CI), \x1f/\x1e forging (CI).
DROPPED: none.

### V-S8

### Phase-3 VERIFIED — S8 skill prompt layer

KEPT
[P1] CON-1 SKILL.md:85-94,432,505,580; tool-mappings.md:41-43; GEMINI.md — DOC_TOOLS / install.sh / references resolve only via ~/.claude/plugins/cache glob; non-marketplace installs get literal glob (measured rc 127 w/ empty HOME); 4/5 clients cut off from core tooling. (← COR-1, SEC-1 L432 part)
[P1] CON-6 SKILL.md:346-349 — review-pr `|| echo main` binds to sed → BASE="" when origin/HEAD unset (this repo, actions/checkout) → empty diff → `check-freshness --code-refs` with no args = NO filter → review of nothing / whole index. measured. (← COR-2)
[P1] CON-3 SKILL.md:291,373,393,428,639; spec-lifecycle-actions.md:92,128; evals.json:151 — index-write routing predates add/move/remove/deprecate-entry: new docs → update-index (exit 1, whole batch unwritten); untracked + migrations → build-index which REPLACES the index (drops unlisted, re-derives code_commit so stale→current); sync lacks add/remove; archived docs become missing+invisible. measured. (← CON-2, COR-3, SEC-6 rebuild half)
[P1] CON-7 spec-lifecycle-actions.md:127 — spec-generate allows "module names" as code_refs → code_commit null → spec current forever (+ constraint forever). measured.
[P1] SEC-1 SKILL.md:81,158-164,424-427 — discovery (every action except hooks/release) + sync run `uv run scripts/validate_docs.py` / `validate_doc_references.py` from the working tree → review-pr on a checked-out PR runs PR-author code (uv also syncs deps). structural. (downgraded P0→P1: no untrusted-actor path without a maintainer running it on an untrusted checkout)
[P2] CON-4 doc-spec.md:872-875; SKILL.md:393,428 — update-index resets deprecated→current. measured.
[P2] CON-5 doc-spec.md:188,226-227; spec-lifecycle-actions.md:195; SKILL.md:127-128 — set-implementation anchor `**Date:**` vs template `**Date**:`; SPEC template no Date; no Implementation:/Realized-by: in templates; no action calls these verbs. measured. (← COR-24, COR-9 status-header half)
[P2] COR-5 SKILL.md:305,431,491; doc-spec.md:760-761 — prompts assume host project IS doc-superpowers (README synced vs SKILL.md actions; mandatory bump/check-version of doc-superpowers' 6 manifests → vacuous PASS in consumers). measured. (← CON-11)
[P2] COR-4 SKILL.md:81,476-493 — release has no commit step though L81/L488 imply one; step 12 tag may land on pre-release HEAD. structural. (← SEC-4 L81 half)
[P2] COR-6 spec-lifecycle-actions.md:192-213,251 — Task N+1a per :amends spec per chunk → false FAIL in chunks before Task {N}; update-index "exactly once" wrong. structural.
[P2] COR-7 spec-lifecycle-actions.md:178-184 vs 249 — two per-chunk Status writers with different gates. structural.
[P2] COR-8 spec-lifecycle-actions.md:60,171-190,225; evals.json eval 13 — explicit :target/:constraint marker not carried into injected tasks → executor re-infers, can advance a constraint spec. structural.
[P2] COR-9 spec-lifecycle-actions.md:209,227,251,278,323 — landed-check grep -A4 not section-aware / misses long blocks. structural.
[P2] CON-9 spec-lifecycle-actions.md:45,247,269,321 — index semantics misdescribed; `check-freshness <doc>` silently ignores the arg (measured). (← COR-10)
[P2] CON-8 SKILL.md:387; spec-lifecycle-actions.md:128,188,249 — prompts ask for `replaces` + code_refs writes no verb performs. known gh-18 (+`replaces` no writer).
[P2] CON-14 SKILL.md:335,366; output-templates.md:48-84 — audit→update handoff undefined ("Section 4" = Common Mistakes; two templates same filename; newest *-audit-report.md w/o age/applied/branch check; never archived; 2 reports miss glob). (← COR-13, SEC-3)
[P2] CON-13 spec-lifecycle-protocol.md:61-63,92-102,131-149,157-165; integration-patterns.md:55-63; output-templates.md:112-116; agent-prompt-template.md:56-67; spec-lifecycle-actions.md:283 — v2.15 :amends/--plan never reached protocol/patterns/templates; "three" vs four; --plan twice. (← COR-11, COR-12, CON-18)
[P2] SEC-2 agent-prompt-template.md:5-33; SKILL.md:281,313-316,351-357,443-448 — no data-vs-instructions trust boundary for write-capable agents. structural (P1→P2 hardening).
[P2] SEC-7 doc-spec.md:143-147,459-464,569-570,611-616; SKILL.md:178,187 — no secret-handling rule.
[P2] SEC-8 doc-pr-release.yml:186-196 vs 164,217,233 — trust list omits .existing_fragment; "only helper scripts" contradicts required jq/sha256sum/gh.
[P2] SEC-9 SKILL.md:512,519,523,546 — --ci default installs doc-review-pr + doc-pr-full-cycle together (full-cycle header says never); consent = tier choice only. (evidence corrected: pair is review-pr, not audit-update)
[P2] COR-15 SKILL.md:156-166,313-316,374-380 — discovery dumps full check-freshness JSON (~311 B/entry → ~1.25 MB @ 4,019); update dispatches uncapped agents. measured.
[P2] COR-19 evals/evals.json — 13/13 "files": []; no runner; eval 4 asserts failing verb; eval 9 expects untracked handling sync lacks; eval 6 "7 YAML" vs 9. measured. (← COR-20)
[P3] SEC-4 (human review vs headless CI commits); SEC-6r (update migrates/archives w/o confirmation vs init offers); SEC-10 (fixed /tmp consumed list); SEC-11 (unquoted caller strings in plan shell + from_ref in prompt); SEC-12 ("read-only" claims contradicted); CON-10 (schema table stale); CON-12 (release underspecified: vocab mismatch, step order, no-tag path); CON-15/16/17/18 + COR-16/17/18/22/23/25 (doc-spec "init and audit"; tool-mappings names incl. Cursor "Anthropic-ecosystem"; error-message table; "(7)"; flat example; PNG-only-via-MCP; agentic globs miss skills/*/SKILL.md; SKILL.md 5,949 words w/ 769+720 on release/hooks; "do not restate" restated; doc-spec broken anchor + duplicated template + "Always" row; assorted contradictions).

DROPPED
SEC-5 (CLAUDE.md/README rewrite w/o confirmation) — documented core behavior, visible in diff, no privilege gain.
SEC-3 standalone — planting a report needs same access as editing docs; residue in SEC-2 / CON-14.
SEC-1 sub-claims — L432 "not anchored" wrong (it's CON-1); L112 globs are ls only.
Bad line cites corrected: tool-mappings.md 41-58/:34; output-templates.md 48-84/86-120; integration-patterns.md :24/55-63.

OUT-OF-SURFACE (verified): post-commit-sync.sh:28 update-index no-args always exit 1 (confirmed); doc-spec-verify.yml:79-84 prompt omits --changed-files; `deprecate-entry <path> --superseded-by <succ>` deprecates the successor, exit 0 (measured); doc-tools.sh:1750 --filter needs rg; doc-index-update.yml passes the index itself to update-index.

### V-S9

### Phase-3 VERIFIED — S9 shell test suites (26 distinct; 22 kept w/ severity, 3 merged, 1 downgraded, 0 dropped)

KEPT
[P1] test-hooks.sh:443,460,477,488,559,574,588,601 — Claude hook tests inject TOOL_INPUT (never set by harness) + assert merged stdout; M2 (correct stdin contract) → 4 assertions in 3 tests FAIL (suite rejects the correct fix); M13 (settings wrapper → cd /nonexistent) → 308/308 (registered command never run). measured.
[P1] test-hooks.sh:810-881 — no test that Claude-tier install/uninstall preserves user hook entries; M25, M26, M7 → 308/308. measured.
[P1] test-hooks.sh:643-656,705-730,1212-1228; install.sh:150-155 — integrated mode never run the way git runs it (only :1222 executes a spliced parent, with PATH bash, asserting only "before"). structural (finder measured).
[P1] test-hooks.sh:12,639,842 — installed hooks' runtime doc-tools lookup never executed (every test passes DOC_TOOLS; installed copies only grepped). structural (finder M16 measured).
[P1] test-doc-tools.sh:1449-1578,267-282; doc-tools.sh:844,784 — add-entry skip-existing guard + update-index last_verified re-stamp untested; DM2, DM1 → 253/253 + 308/308. measured.
[P1] test-doc-tools.sh:141-152; doc-tools.sh:511,639 — no test runs check-freshness on an entry with an empty middle field; repro: build-index ref to not-yet-existing newsrc/ then commit → check-freshness current, stale 0. measured. (dup S1)
[P1] test-merge-driver.sh:17-20,139-157 — no tie / one-sided-edit / null last_verified fixture (MM2, MM5 undetectable). structural (dup S3 P0).
[P1] test-doc-tools.sh:179-263 — no shallow / squash / rebase fixture (grep: no --depth, shallow, squash in any suite). structural (dup I-1).
[P2] test-helpers.sh:91,103 — echo|grep -qF under pipefail: idle 4-core box, 35 KB haystack: false FAIL 1–2/1000, false PASS (forbidden string present) 0–2/1000; test-spec-status-model.sh whole-run failures 1/60, 2/60; here-string 0/200. measured. P1→P2 (≤0.2% false-PASS; real harm ~2–3% flaky red runs).
[P2] test-helpers.sh:59-69 — fixtures inherit caller git env/global config: GIT_CONFIG_GLOBAL with core.hooksPath → test-hooks 289/308 AND the contributor's "global" hooks dir received 5 doc-superpowers hooks + their global pre-commit got the block spliced in (install.sh:108 reads core.hooksPath without --local). measured. Pollutes a contributor machine; CI unaffected.
[P2] install.sh:575-596; test-hooks.sh:1331-1343 — no test that doc-pr-release helpers get installed (M22 → 308/308 + 32/32). measured. P1→P2 (regression would be loud in consumer CI).
[P2] test-doc-tools.sh:463-471,489 — static bash-4 guard 7 regexes; 12 planted forms undetected; none shipped today. measured. P1→P2 (3.2 CI leg catches parse-time forms).
[P2] test-merge-driver.sh:111-133; merge-doc-index.sh:71 — MM1 (ours-deleted rule removed) → 19/19; control MM1b → 2 FAIL. measured. P1→P2.
[P2] test-doc-tools.sh:193-203,942-958,716-744,245-262,328-341 — one-sided assertions (DM16, DM4, DM5, DM7, DM8 survive). NEW production defect reproduced: refs src/,lib/ with only src changed → code_refs_changed ["src/","lib/"] from both check-freshness and status. measured.
[P2] test-doc-tools.sh:1546-1578 — normalization test named "./ and ../" tests only ./; `//` untested (repro: docs//design.md key; untracked 1; update-index docs/design.md not found). measured.
[P2] test-merge-driver.sh:180-181,72-74,244-251,191-207 — four tests cannot fail (jq keys always sorts; generated_at "not ours/theirs"; Test 8 ours already max; Test 6 exit code only). structural.
[P2] test-hooks.sh:219-232,243-257,278-289,484-494,534-544,597-607 — negative-path tests silent anyway (e.g. claude gate SKIP test has no index; post-checkout bogus SHAs). structural (finder measured).
[P2] test-hooks.sh:634-636,836-840; test-doc-pr-release.sh:737-778 — placeholder/path/YAML checks don't test installer output ("/Users/" and "relative path" checks match absolute $TEST_DIR path; YAML test runs own sed, never install.sh). structural.
[P2] test-hooks.sh:505-532 — session-summary tests 1-entry index → timeout path never runs (suite's own perf test ~10 s @ 500 entries). structural.
[P2] test-hooks.sh:567-595 (:592), 505-532 — no-arg update-index call always fails, no test checks index; M1fix (refresh actually works → marks all verified) caught in post-commit-sync (2 FAIL), SURVIVES in session-summary. measured. P1→P2. known: metadata-rewrite.
[P2] test-doc-tools.sh:1129-1208, 1210-1241, 217-230 — coverage gaps for S2 defects (set-implementation, --filter, update-index on deprecated). structural (dup S2).
[P2] test-doc-tools.sh:383,546,583,978,1055,1085; test-merge-driver.sh:44-46; test-doc-pr-release.sh:324-365 — fixed /tmp paths; BSD mktemp non-trailing X. structural.
[P2] test-doc-tools.sh:595-640,2091-2097 — perf guard 60 s wall clock; trip → return 1 under set -e → suite aborts, no FAIL counted, no summary. structural (finder measured 10→16 s undetected).
[P3] test-doc-tools.sh:1278,1322,1352; test-hooks.sh:1031,1070,1340 — `[[ ]]; assert_eq 0 $?` can't record FAIL.
[P3] test-helpers.sh:38,42-45 — INT trap removes shim dir and suite continues; shim printf unescaped; same-basename collision.
[P3] test-doc-pr-release.sh:8-47 — not on shared harness (no bash_bin_shim); CLAUDE.md claim inaccurate (test-helpers.sh:31 says so).
[P3] test-doc-pr-release.sh:720-754 — missing YAML parser should be loud SKIP (parser itself justified).
[P3] test-hooks.sh — no install→uninstall round-trip test.
[P3] test-doc-tools.sh:767,1843,1884,1908,1931,1948,508-640 — runtime waste (6× sleep 1; duplicate 500-entry corpora).
[P3] test-doc-tools.sh:811-908 — bump/check-version edge cases untested.
[P3] test-doc-tools.sh:41-52,2031-2046 — pins --help rc 1 + exact usage strings.
RE-SEVERITIED: Test 8 "version":1 P1→P3 (known); status substring assertions P2→P3; spec-status-model wording-freeze P2→P3 (explicit prose-pinning guard by design, header 3-7); move-entry content_hash test P2→P3 (documented design choice doc-tools.sh:1060-1063).
SHARED ROOT (kept as separate lines): tests exercise template sources with injected env instead of the INSTALLED artifact via its REAL invoker (TOOL_INPUT/M13 · integrated wrapper · runtime DOC_TOOLS lookup/M16 · placeholder/YAML not on installer output).

### V-S10-S11

### Phase-3 VERIFIED — S10 cross-client packaging + S11 project docs

#### S10
KEPT
[P1] .cursor-plugin/INSTALL.md:8 — manual install clones into ~/.cursor/plugins/doc-superpowers; Cursor local-plugin location is ~/.cursor/plugins/local/<name>/ (cursor/plugins repo: create-plugin-scaffold/SKILL.md:21-27, agent-compatibility/README.md:86). structural (external; cursor.com blocked). Provisional P1. doc-superpowers not among 94 entries in cursor/plugins marketplace.json → "install from marketplace" route also unverified.
[P2] .opencode/plugins/doc-superpowers.js:27-28 — replaces `string[]` with string → mappings never reach the model (sst/opencode@dev packages/plugin/src/index.ts:291-296; session/llm/request.ts:58-76). measured (node sim). P1→P2: skill registration works; failed turn only if a later push-style plugin runs. File re-read on every LLM call.
[P2] .cursor-plugin/plugin.json:24 — `"skills": "./"` stale (written at b2042be when SKILL.md was at root; 25401a5 moved it 41 min later); all 20 cursor/plugins manifests that set the key use "./skills/". structural (P1→P2; unverifiable whether it replaces the default scan).
[P2] GEMINI.md:37 et al. — "full parity" for doc-tools vs plugin-cache-only resolution. (dup S8 CON-1)
[P2] tool-mappings.md:11-26,46,53,56-59; INSTALL files; GEMINI.md:22,40; AGENTS.md:42,46-47 — tool tables wrong: OpenCode ids read/write/edit/grep/glob/bash/todowrite/task/question/webfetch/websearch/skill; Codex exec_command/apply_patch/update_plan/spawn_agent/request_user_input/web_search; Gemini has ask_user, plan mode, invoke_agent + documented subagents ("no subagent support" stale); SKILL.md never references tool-mappings.md → nothing delivers mapping to Codex (.codex/INSTALL.md:44 false). measured vs client source.
[P2] GEMINI.md:1 — `@./skills/doc-superpowers/SKILL.md` loads 45,349-byte SKILL.md into every Gemini session although extension skills/ already exposes it via activate_skill → skill loaded twice, ~11k always-on tokens (vs ~142 always-on for Claude Code plugin). structural (documented).
[P2/P3] doc-tools.sh:1275-1337,1958; install.sh:22 — version tooling silent fail / vacuous pass (dup S2); NEW: install.sh:22 VERSION=$(grep|sed) aborts rc 1 silently under pipefail when no match → "2.0.0" fallback unreachable.
[P3] .codex/INSTALL.md:57-64 — top-level multi_agent ignored ([features] key, Stable, default on). measured vs Codex source.
[P3] claude-code.json — no consumer (only VERSION_FILES, test fixture, docs). structural.
[P3] duplicated tables drifted ("(7)" ×4 vs 9; GEMINI.md repeats imported table). measured. (P2→P3)
DROPPED
"README/getting-started symlink install of repo ROOT loads nothing" (S10 P2 + S11 P1 cross-surface) — MEASURED FALSE: repo root has .claude-plugin/plugin.json → symlink at ~/.claude/skills/doc-superpowers loads as a skills-dir plugin; with isolated HOME + README symlink, Claude Code 2.1.283 `claude plugin list --json` shows doc-superpowers@skills-dir enabled; `claude plugin details` → Skills (1). Remaining gap on this route = DOC_TOOLS resolution (S8 CON-1).
.opencode/INSTALL.md:17 #v2.8.0 pin — tag exists; line 21 says check RELEASE-NOTES first; illustrative.
"CI rows parity though 6/9 need Claude credentials" — parity claim holds (credential is an account requirement for all clients).
"Cursor 'All 11 commands' under 13 rows" — 11 actions; hooks split into 3 rows.

#### S11
KEPT
[P2] docs/conventions.md:309-317, 331; doc-tools.sh:771-783 — status table wrong; update-index un-deprecates; "check-freshness detects hash mismatch" wrong; "stale" never stored; ignores deprecate-entry. measured. Automated callers: doc-index-update.yml:52, SKILL.md update SYNC step (392). (root cause shared with archive + records → status model)
[P2] README.md:202; codebase-guide.md:58-59; workflows doc:384 — docs claim Claude hooks auto-run update-index; call always exits 1 (arg requirement existed in 97134e0 v2.3.0 BEFORE the hook was added in cba0330 → never worked). known metadata-rewrite: issue's blamed source wrong (no git post-commit hook; Claude hook call fails; update-index never writes build_commit; live build_commit still 97134e0). (P1→P2)
[P2] CLAUDE.md:23-28; README.md:291-295; codebase-guide.md:21-25,168 — repo's self-installed CI tier presented as working; .github/scripts/doc-tools.sh not in git; via GitHub API: run 30534235825 success (swallowed failure, STRICT=1); doc-index-update runs 15-20 (6 most recent, 2026-05-28 → 2026-09-02 incl. HEAD 05ea982) conclusion=failure. measured.
[P2] CLAUDE.md:150,152; workflows doc:514,527,582; codebase-guide.md:342; conventions.md:274 — v2.15.0 :amends / spec-verify --plan missing from agent-facing living docs (grep -ci amend = 0 in CLAUDE.md, codebase-guide, conventions, workflows doc, AGENTS.md). measured.
[P3] .claude/hooks/doc-superpowers/*.sh:5 pin /Users/w/… (hooks silently exit 0 off maintainer's machine); system-overview.md:147 "relative paths" claim false (DOC_TOOLS_PARENT absolute). (P2→P3; killed sub-claim: CLAUDE.md:121 describes consumer contract)
[P3] three code_commit SHAs (f063b04, c2496da, abb3e64) — CORRECTED: exist, reachable ONLY from tag v2.12.0 (pre-rebase copies of dd55566/ec4a962/d931c80); not ancestors of 05ea982; commits_behind 0 only where objects missing (shallow/no-tags); full clone 4/8/8/8. Residue: rebase after update-index orphans SHAs; nothing checks ancestry; `|| echo 0` masks (doc-tools.sh:581). (P2→P3; feeds I-1)
[P3] point-in-time records: 36 = 5 living + 31 records; 23 stale = 2 living + 21 records → 91% (83% excluding 2 open issues that are useful signal). 26/31 records carry code_refs; 5 [""] never stale; 26/114 commits touch index. Fold into status-model (deprecate once update-index stops un-deprecating). (P2→P3)
[P3] archived docs not deprecated — SKILL.md update step 388-392 moves to archive then update-indexes → prose rule actively undone. (merge into status model)
[P3] test counts conventions.md:82 / system-overview.md:118 "(68)"; 597cc09 re-verified without content fix (suite + CLAUDE.md already 84 at f5808ea). measured.
[P3] GNU sed missing from dependency lists (loud self-explaining failure).
[P3] getting-started.md:56 ".claude/mcp.json" wrong location (optional, graceful fallback; SKILL.md:177 is agentic inventory not mermaid detection).
[P3] C4 PNGs older than Mermaid source (d3e4def 2026-04-07). measured.
[P3] __DOC_TOOLS_PATH__ named in docs (no template has it). measured.
[P3] tests.yml missing from README/codebase-guide trees; Contributing omits suites. measured.
[P3] doc_type mismatch (2 issues typed plan; no code reads doc_type). cosmetic.
[P3] RELEASE-NOTES.md:28 v2.14.0 [""] explanation wrong. measured.
[P3] conventions.md:57 INSTALL pin check not followed.
[P3] workflows doc:51 "except hooks" vs "hooks and release".
DROPPED: README symlink install P1 → superseded by S10 measured drop (see above).
Hygiene note: S11 verifier's early fixture commands landed in other agents' scratch dirs (tmp.*) — cleaned by it; real repo untouched by it.

### V-CI

### Phase-3 VERIFIED — CI (templates + repo workflows)

INCIDENT: a failed `cd` in this verifier sent three commands to the real repo → untracked docs/a.md created (commit + update-index failed without writing); deleted immediately (this was the transient file the stop hook saw). Controller re-verified: working tree clean, no merge.* config, no installed git hooks.

KEPT
[P1] .github/workflows/doc-freshness-pr.yml:51, doc-freshness-schedule.yml:33, doc-index-update.yml:52 — this repo's 3 self-installed workflows call .github/scripts/doc-tools.sh never committed (install.sh:559-567 vendors it but self-install commit 4727d2f never added it). Replay: "No such file…", stale_count=0, exit 0 (real: 23/36 stale; PR #17 head: 20 stale → STRICT=1 should have failed); index-update exit 127. measured.
[P1] scripts/hooks/ci/doc-index-update.yml:30,52 — all changed docs/ paths incl. the index itself → update-index exit 1. Replay on 12 latest first-parent main commits touching docs/: 12/12 rc 1 (11 on docs/.doc-index.json, 1 on unindexed docs/issues/*.md). measured.
[P1] doc-index-update.yml:24-25,52 — fetch-depth 2 stores shallow graft as code_commit → "stale, commits_behind 0" in full history; shallow check-freshness current 0 / stale 2. measured (fires on doc-only pushes — the case the workflow exists for).
[P1] doc-freshness-schedule.yml:39-44,102-104; doc-freshness-pr.yml:29-40,57-62,117-119 — E2BIG: 311 B/entry → ceiling ≈421 docs; measured single env string 131,069 B execs, 131,071 B → "Argument list too long" rc 126 for /bin/true AND node. Schedule payload unfiltered → trips first. measured (kernel) / needs-runtime (runner, 1 MB cap).
[P1] 6 AI templates (doc-audit-update.yml:70-82, doc-review-pr.yml:63-74, doc-spec-verify.yml:73-84, doc-pr-full-cycle.yml:73-95, doc-release.yml:82-97, doc-pr-release.yml:146-272) — no claude_args / plugins → agent has no Bash/Write/MCP and no /doc-superpowers skill → cannot do their job even after gh-5. Pinned source: agent/index.ts:82-122; install-mcp-server.ts:95; tag/index.ts:175 (only place setting acceptEdits/allowedTools); run.ts:252-256 plugins from inputs (none set). NEW: audit-update + full-cycle prompts say "commit" never "push"; agent mode doesn't push → commits discarded. Today all six fail at OIDC first (token.ts:13-23). structural + needs-runtime.
[P2] doc-freshness-pr.yml:51-55,121-127; doc-freshness-schedule.yml:33-37,106-133 — fail-open (tool error → stale_count=0; strict passes; schedule closes open issue; no annotation). Fires only on tool failure (check-freshness exits 0 with stale docs). This fail-open hid the missing vendored tool since April. measured. (P1→P2)
[P2] doc-index-update.yml:45-52 — "edited" treated as "re-verified" (stale commits_behind 3 + typo commit → current 0). measured.
[P2] doc-review-pr.yml:16-24,31-33,68-69 — prompt: forces agent mode on every comment; trigger_phrase dead; any member comment → paid review of DEFAULT branch; comment cancels in-flight synchronize review. NOT a security issue: issue_comment checkout = default-branch HEAD; agent-mode prompt verbatim (comment body never reaches model); .claude/.mcp.json restored from base; no allowedTools/MCP → can't even post. Residue: credit burn, dead @claude, cancelled review. structural. (P1→P2)
[P2] all 6 claude-code-action steps — known gh-5; gh-5's proposed id-token fix WRONG: token.ts:128-151 swaps to Claude App installation token scoped server-side (DEFAULT_PERMISSIONS token.ts:26-30 contents/pull_requests/issues write), not by job permissions:; git-config.ts:76-80 writes it into origin URL; run.ts:170-171 into GH_TOKEN; requires Claude App installed; App-token pushes retrigger synchronize → checkHumanActor (actor.ts:25-60) red. token.ts:15 is the only getIDToken call → `github_token: ${{ github.token }}` fixes gh-5 without id-token. structural (pinned source). (P1→P2 latent)
[P2] doc-review-pr.yml:45-61, doc-spec-verify.yml:54-71, doc-pr-full-cycle.yml:54-71, doc-freshness-pr.yml:64-116 — fork/Dependabot/bot PRs red (no secrets → auth exit 1; freshness-pr createComment 403 when stale ≠ 0; Renovate fails checkHumanActor). structural.
[P2] install.sh:62-72,427-428 — default --workflows=all installs every AI template incl. overlapping ones; help text understates. structural.
[P2] doc-audit-update.yml:10-16, doc-review-pr.yml:11-15, doc-pr-full-cycle.yml:15-19, doc-spec-verify.yml:11-15 — code path filters hard-coded to this repo's layout. structural.
[P3] doc-pr-release.yml:13-19,41-42,123-129 — paths-ignore "recursion guard" comment inaccurate; later steps skipped only via null coercion. structural.
[P3] doc-freshness-pr.yml:29,49-51 — changed-file list fragile; zero paths → all 36 docs unfiltered (measured).
[P3] doc-freshness-pr.yml:65,73,92-116; doc-freshness-schedule.yml:56 — comment lifecycle (never cleared, page 1 only, no author check, 0 → '?').
[P3] doc-review-pr.yml:20, doc-spec-verify.yml:16, doc-pr-full-cycle.yml:20,41 — workflow_dispatch no PR context → default branch.
[P3] 6 AI templates — DOC_SUPERPOWERS_VERSION unread; doc-audit-update unused pull-requests: write.
[P3] tests.yml:132-134 + test-doc-pr-release.sh — not on shared harness; helpers run under shebang bash (Homebrew 5 on macOS).
[P3] all uses: pins genuine (checkout 34e11487 = v4.3.1, "# v4" imprecise; github-script f28e40c7 = v7 / v7.1.0; claude-code-action 1eddb334 = v1.0.88). Node 20 retirement needs-runtime.
[P3] extract-context.sh:121-130 — \x1E/\x1F record forging (measured; low impact: only sha field gains control).
[P3] doc-pr-release.yml:43-45,71-93; commit-and-push.sh:55,72 — dispatch on fork PR (P1→P3: maintainer dispatch + branch-name collision; no untrusted token gain).
[P3] all templates/tests.yml — no timeout-minutes / --max-turns (P2→P3 hardening).
[P3] install.sh:482,789 — __BASE_BRANCH__ unvalidated (robustness; only installing maintainer supplies it).
DROPPED
"scripts from PR head run with write token + persisted creds" — no privilege crossed.
"PR number / dispatch inputs unvalidated; from_ref into prompt" — workflow_dispatch needs write; event PR numbers numeric.
"doc-pr-full-cycle fork PR from main commits onto base main" — fork runs have no secrets (auth exits 1) and read-only token.
"effective tools/hooks/MCP from checked-out .claude/settings*.json + .mcp.json" as attacker surface — pinned action restores .claude/, .mcp.json, .claude.json, .gitmodules, .ripgreprc from BASE on every PR context (restore-config.ts:12-18,42-80; run.ts:236-249).

### V-SHELL

### Phase-3 VERIFIED — SHELL security (all shipped shell)

INCIDENT: a mistyped scratch path in this verifier made one jq fixture write land in the REAL repo's docs/.doc-index.json (code_refs ["src/x.c","/e*"]); restored by the verifier (git restore) and by the controller (git checkout); repo verified clean; no install.sh / doc-tools.sh ever ran with the real repo as cwd.

KEPT
[P1] install.sh:144,171,181,197-200,304,342,373,486,564-565,589-590,601-603; doc-tools.sh:1817-1819,1833-1834,1840-1844; state.sh:150-153 — installer + `tools install` write fixed repo-relative paths via >, >>, cp that FOLLOW committed symlinks (file, dangling, symlinked parent dir) → writes outside repo, git status stays clean. measured (a) settings.local.json → global settings gains hooks (not a trust bypass; makes hooks global/relative, noisy); (b) .github/scripts/doc-tools.sh → ~/.bashrc replaced + chmod +x (terminals unusable; also via tools install); (c) dangling workflow/.gitattributes → files created outside; (d) hooks dir → ~/bin; (e) .claude/doc-superpowers → installed.json written elsewhere. NEW measured variant: committed .githooks/pre-commit → ../../../.bashrc → integrate path appends `bash "$(dirname "$0")/.doc-superpowers-pre-commit"` to .bashrc + chmod +x → interactive shell in repo runs attacker's root-level .doc-superpowers-pre-commit (pwned-G) = persistent code exec. Attacker: repo author / PR author whose symlink is merged; trigger: victim runs hooks install / tools install. P0→P1 (victim must deliberately run the installer in that repo; repo author on trusted-folder path already has code exec via project hooks).
[P1] hook templates line 5-7; install.sh:16 — `__DOC_TOOLS_PARENT__/*/scripts/doc-tools.sh | sort -V | tail -1` runs sibling dir's script that sorts last. measured (sibling `webapp` selected → pwned-B on git commit; fork `doc-superpowers-pr42` sorts before → not picked; payload needs exec bit, git preserves it). Exposure layout-dependent: ~/code clone layout (this repo's own self-installed hook records /Users/w/code/doc-superpowers) exposed to arbitrary cloned repos; ~/.claude/skills symlink / Cursor / OpenCode only to other installed plugins (already trusted); Codex ~/.codex + plugin cache safe → finder's "Codex/Cursor/OpenCode exposed to arbitrary repos" overstated. Non-malicious side: sibling consumer repo with `tools install --dest scripts` has its stale copy run by every hook.
[P2] doc-tools.sh:1684-1706 — set-implementation sed `e`/`w` injection via --note newline (measured pwned-C1, pwned-C4, written-C3); single-line `|e;#` only when REF lacks word-initial `#`. Benign bugs measured: note "parser & lexer" pastes matched old line; "a|b" aborts. P1→P2 (no automated untrusted feed; only an agent copying attacker text).
[P2] install.sh:323-330 — Claude hook command cd to cwd's toplevel + relative exec → nested repo's copy runs (pwned-E, shell level). Fix "$CLAUDE_PROJECT_DIR"/… correct. P1→P2 (nested-repo author already has exec via build/test scripts; hook cwd assumed).
[P3] doc-tools.sh:194,581; git/pre-push:12 — code_commit/tag `--output=` truncates/creates `…..HEAD` file (measured); no content control. P1→P3.
[P3] doc-tools.sh:28-33,564,629 — "-" key drains stdin (measured). P2→P3 (index editor can already mark everything current).
[P3] commit-and-push.sh:41,43,49-52,55,72 — commit without pathspec (measured locally; real GitHub refuses GITHUB_TOKEN pushes touching .github/workflows). P2→P3.
[P3] session-summary.sh:24-29 — predictable /tmp (vanilla macOS, local multi-user). P2→P3.
[P3] install.sh:144,181,190,304,481-486 — unescaped install-time values (robustness, not security): "sp ace/" → silent no-op; unquoted driver path; `--base-branch 'a|b'` → 0-byte workflow + "Done". measured.
[P3] update-pr-body.sh:22,46,141 — PR_NUMBER unvalidated. structural.
[P3] extract-context.sh:76-89; doc-tools.sh:1397,1486 — fragment reader follows symlinks (.git/config, /proc/self/environ → context.json); no boundary crossed. structural.
[P3] doc-tools.sh:515-521 — unquoted glob expansion (`/e*` → /etc). measured. Incidental measured: IFS tab collapse on entry without last_verified → reported current despite changed code.
DROPPED
extract-context "/dev/zero defeats 1 MiB cap" — false ([ -f ] on char-device symlink is false).
"bypasses per-project trust" wording — wrong.
commit-and-push evil.yml as real-GitHub outcome — GITHUB_TOKEN can't push workflow changes.

### V-XCONC

### Phase-3 VERIFIED — X concurrency

KEPT
[P1] doc-tools.sh:311, 503; claude/session-summary.sh:19-27 — INT/TERM trap cleans up + resumes → build-index installs TAIL-only index. measured: kill -TERM @2 s → rc 0, 512/600; @5 s → rc 0, 353/600 (d248..d600 kept); `timeout 2` (group kill) 2/10 runs installed 578/600, 576/600 with rc 124 taking 15 s not 2 s; check-freshness TERM @1 s → rc 0, summary 600 but .docs 518; Stop-hook `timeout 1 check-freshness` ran 5.27 s in 1/5. Known index-write-not-atomic: its proposed tmp+mv fix does NOT keep the previous index intact because the trap defeats it. P0→P1 (no routine TERM source for build-index; realistic trigger = Bash-tool/CI timeout on a large index; index git-tracked; rc non-zero under group kill; raise to P0 if S1 shows a routine TERM source).
[P1] doc-tools.sh:701+792, 814+918, 949+980, 1018+1089, 1131+1167; SKILL.md:374, 393 — no lock → concurrent verbs lose updates silently rc 0 (10 parallel update-index: stale 10→9, 3/3 trials). SKILL.md:374 "For each stale doc, dispatch a scope agent" + :393 "update-index for each changed doc"; README.md:3, :261 "Parallel agents … one agent per doc scope"; no worktree isolation → shared tree. Partial mitigation: step-6 gate re-surfaces lost refreshes; not a lost deprecate-entry. known: index-write-not-atomic (missing lock = separate root cause). Merge with corruption finding (same lock fixes both).
[P1] doc-tools.sh:792, 918, 980, 1089, 1167; git/pre-commit:26; claude/pre-commit-gate.sh:37 — overlapping truncating `>` writes → valid prefix + stale tail → permanently unparsable (30 s race: corrupted after ~51+35 writes; 233,485 B, prefix of 586 docs, trailing tail; then 1144/886 failures); mixed-writer bursts corrupted 6/25; update-index-only bursts 0/8. Hooks `|| exit 0` silence the gate. P0→P1 (needs overlapping ms windows; loud rc 5 at update step-6 gate; git checkout recovers; silent only in hooks). known: index-write-not-atomic (NEW: concurrency alone triggers it).
[P2] doc-tools.sh:629-641, 656, 701, 814, 949, 1018, 1131; install.sh:313+342, 360+373; ci/doc-freshness-schedule.yml:33-36, 106-131; doc-freshness-pr.yml:51-54 — empty read treated as valid empty index (0-byte index: check-freshness rc 0 stale 0 untracked 5; add-entry "Added 1 entry" rc 0 leaves "\n"; race 7/209 rc 0 stale 0; empty settings.local.json → "3 installed" 0-byte). P1→P2 (no own trigger). dup S1-CORR P2.
[P1] commit-and-push.sh:85-88 — force-pushed-away commits restored. dup S7 (not re-run).
[P2] commit-and-push.sh:71-93; doc-pr-release.yml:99-108 — mid-run push marked covered. dup S7.
[P2] ci/doc-audit-update.yml:19-21; doc-pr-full-cycle.yml:22-24; doc-pr-release.yml:32-34 — three templates commit to same PR branch under separate groups (all installed by default --workflows=all, install.sh:69-73); no agent push retry; merge with .gitattributes but no driver → CONFLICT → jq rc 5 (would conflict on generated_at even without attribute). known: metadata-rewrite.
[P2] ci/doc-index-update.yml:7-11,30,52,62 — no concurrency group etc. dup CI.
[P2] claude/post-commit-sync.sh:28; session-summary.sh:36-45 — no-arg update-index; tracked issue index-write-not-atomic literally claims "post-commit-sync runs update-index after every commit" — false premise. dup.
[P3] doc-tools.sh:437-453, 1287-1289; install.sh:148-168; state.sh:151-153 — mktemp+mv → 0600 (index, package.json, claude-code.json); bump-version half-applied on malformed 3rd manifest (2 bumped, rc 5, 4 left at 2.15.0). NEW for known issue: its proposed beside-target mktemp fix still yields 0600 → needs chmod 644. install.sh:168 chmod +x → 0711. git doesn't carry 0600. known: index-write-not-atomic.
[P3] install.sh:342, 373, 564; doc-tools.sh:1760-1763, 1818 — in-place rewrites of settings.local.json / vendored doc-tools.sh (structural, rare); tools install self-copy fails (measured; correctness bug).
[P3] claude/session-summary.sh:24-29, 41-44 — macOS fallback guessable /tmp + orphan timer. dup.
[P3] commit-and-push.sh:41-52 — no pathspec. dup.
DROPPED: "tmp+mv atomic only on same FS; issue says build-index already correct" — EXDEV real (strace) but already in the tracked issue's Technical Context; framing misreads the issue.


## Verifier reports: Phase-4 follow-ups

### V-FU1

### Phase-3 VERIFIED — FU1-S7 (fragment pipeline follow-up: L-PERF, L-TESTS, L-CONTRACT)

run-id 05ea982 · verifier V-FU1 · clone `$S/repo` (S=…/scratchpad/vfu1), code identical to 05ea982 (HEAD commits since then touch docs/** only) · bash 5.2.21, git 2.43.0, jq 1.7, Linux (ARG_MAX 2 MiB, MAX_ARG_STRLEN 131072) · no bash 3.2 / BSD / macOS available, so macOS statements are structural.
Harness: fragment-only runner (10 `test_fragments_*` + bash-4 guard = 26 assertions, baseline 26/26); `test-doc-pr-release.sh` baseline 32/32. One mutant at a time, file restored after each; diffs in `$S/mutdiffs/`.

#### KEPT

- [P2] scripts/hooks/ci/doc-pr-release/extract-context.sh:136-147 (+:72-80) — every payload goes to `jq` as one argv string, so jq fails with E2BIG (rc 126, empty context.json) once any single payload passes 128 KiB. That also makes the 1 MiB "oversized → corrupt" cap dead code for fragments between 128 KiB and 1 MiB · root cause: assumed total ARG_MAX was the only limit; the per-string limit is 128 KiB (update-pr-body.sh:137 already avoids argv for the same reason) · measured:
  - 400 commits with 4-line bodies (139,492 B of log) → rc 126, "Argument list too long".
  - Subject-only commits: 800 → rc 0; 850 → rc 126.
  - Fragment of 124,639 B → rc 0; 132,945 B → rc 126; 622,867 B → rc 126, where the cap should have flagged it as corrupt.
  - PR body of 50,000 CJK characters (150 KB, under GitHub's 65,536-character cap) → rc 126; 65,536 ASCII characters → rc 0.
  - In CI the failure is loud, not silent. The Extract-context `run:` uses the default `bash -e`, so the step goes red and every later step is skipped. That happens on every push to that PR, with no data corruption. The realistic trigger is a large PR (for example a long-lived develop→main PR).
  - macOS has no per-string cap, but its total argv+env limit is about 1 MiB and on a first run `new_commits` ≈ `full_commits`, so the payload counts twice. A fragment near the 1 MiB cap therefore still E2BIGs there (structural). CI runs on ubuntu-latest.
  - Fix: pass the payloads on stdin, as the finder proposed.
- [P3] scripts/doc-tools.sh:1486-1507 — `fragments merge` is O(F×H): each fragment gets its own full-history `git log --reverse`, then two `is-ancestor` calls, then `validate` · root cause: the comment at :1528-1531 assumes the per-fragment git calls are cheap · measured:
  - H=5k/F=200: 10.46 s (the finder measured 10.7 s).
  - Per fragment: 23.6 ms for `log --reverse`, 5.9 and 5.6 ms for the two `is-ancestor` calls, 12 ms for `validate`.
  - The one-pass `log` alone takes 14 ms and returns 200/200 on the linear fixture.
  - Downgraded from P2 to P3: it runs once per release, and passing the 120 s Bash timeout is extrapolated (H=100k, F=200), not measured. This confirms the known I-9 P3, which was an unverified carry-over.
  - **Fix-shape correction:** the proposed `git log --format=%H --name-only --diff-filter=A <s>..<e> -- RELEASE-NOTES.next/` is **not** equivalent as written. On a fixture with a rename, an evil merge, a merge commit and a squash, plus revert→tag→re-land:

    | variant | consumed set |
    |---|---|
    | current code | {51,77,80,90} |
    | one-pass as written | {9,80,90}: misses a renamed fragment (default rename detection reports R, not A) and one added in a merge commit (no diff for merges) |
    | + `--no-renames` | {9,51,80,90} |
    | + `--diff-merges=first-parent` | {9,51,77,80,90} |

    `first-parent` also re-adds fragments that a back-merge brings in, so the merge policy needs a decision.
- [P2] scripts/test-doc-pr-release.sh:278-366 — the only extract-context history fixture is linear · root cause: it never models "Update branch", a human fragment edit or a wrong line-1 · measured. These mutants all survive at 32/32:
  - G-drop-no-merges;
  - G-drop-line1-check (the PR-number marker check deleted);
  - G-drop-minlines.

  This contradicts S9b's "Clean: extract-context tests". It hides the known P1 (g).
- [P2] scripts/test-doc-pr-release.sh:521-701,720-779 — commit-and-push is tested only for the non-fast-forward race, and the workflows only for YAML parse · root cause: the inline `run:` bodies have no harness · measured. These mutants all survive at 32/32:
  - H-reg-stage-all (`git add -A`);
  - H-reg-no-noop-check (an unchanged fragment makes `git commit` return rc 1);
  - Y-verify-always-green (Verify's `exit 1` → `exit 0`);
  - Y-cancel-in-progress (false→true);
  - R-release-guard-removed (doc-release.yml `if:` → `true`).

  This contradicts S9b's "Clean: commit-and-push non-ff rebase test", which is true only for that one path.
- [P3] scripts/test-doc-tools.sh:909-1125 — the fragment tests do not pin current behaviour. These mutants all survive at 26/26:
  - S-reg-canonical-order (canonical order reversed);
  - L-reg-list-nosort;
  - VAL-reg-missing-hash-valid (`validate` returns 0 when there is no hash marker);
  - N-reg-merge-no-numeric-skip;
  - F-newest-touch;
  - the fix mutant A-fix-lastline.

  F-drop-end-ancestry also survives, but it is an *equivalent* mutant whenever `<range-end>`=HEAD, because the walk starts from HEAD. That is not a real gap · measured.
- [P3] scripts/test-doc-pr-release.sh (assertion captures with no `|| rc=`), scripts/test-doc-tools.sh:995,1012 — under `set -euo pipefail`, a helper that fails aborts the whole suite with no FAIL line and no Results line · root cause: captures were not written to tolerate failure · measured:
  - G-drop-size-cap → rc 126, no Results line.
  - Adding a ref check to `merge` → rc 2, abort at `preserves_non_canonical`.

  Same pattern as S9b P3 (test-hooks) and V-S9 P2 (perf guard); these are new locations of it.
- [P3] scripts/hooks/ci/doc-pr-release/extract-context.sh:112-134 — `full_commits` includes the bot's own `[doc-superpowers] sync PR-N …` commits · root cause: no sentinel filter · measured (`full` = ["feat: a","[doc-superpowers] sync PR-42 release notes (x)","feat: b + tweak notes"]). The impact is only noise in the agent's context.
- [P3] scripts/doc-tools.sh:1486-1504 — the candidate set is the worktree glob and the walk is HEAD-rooted, but membership is tested against `<range-end>` · root cause: the verb assumes `<range-end>` is HEAD · measured: PR-200 is present at `<range-end>`=HEAD~1 and deleted at HEAD; `merge v2 HEAD~1` gives rc 0 and empty paths-out. Latent, since every caller passes HEAD.
- [P3] scripts/hooks/ci/doc-release.yml:48-61 — the precheck's "last release" is the nearest tag of any name · root cause: two definitions of "last release" (SKILL.md:441 uses the version tag) · measured (git semantics): a `deploy-marker` tag at HEAD gives count 0, so the job skips; `--match 'v[0-9]*'` gives v1.0.0 with count 1.
- [P3] scripts/hooks/ci/doc-pr-release/RELEASE-NOTES.next.README.md:44-45; SKILL.md:470-475 — the advice "pass `--from=<tag>~1`" · root cause: the edge case was reasoned only from the start side · structural. In the SKILL flow, a fragment at the tag sat inside that release's inclusive `<range-end>` and was already consumed, so the advice re-releases it (and re-lists the tag commit). It is valid only for a tag cut outside the consumer. The finder's "can only re-release" is slightly too strong.
- [P3] docs/plans/2026-05-12-pr-release-fragment-producer-and-consumer.md:128-129,2006 — the plan describes a `git log --all` ancestry test and a "force-push orphans the introducing commit" sharp edge. That design was not shipped: plan:1805-1807, README:40-43 and the code all walk from HEAD. The plan also contradicts itself · measured. With `--all`, the oldest touch of a squash-merged PR-90 is the unmerged branch commit, which is not an ancestor of HEAD, so the fragment would be skipped. The code is right. The plan's text is stale, and the finder's "code is right" call holds.
- [P3] (downgraded from P2) scripts/hooks/ci/doc-release.yml:7-10 + SKILL.md:441,478-490 — consumption runs on `release/**`, and nothing says the release commit must reach main · root cause: consumption is recorded only as a deletion on the branch being released · measured:
  - With no back-propagation, main keeps `PR-1.md`, and main's RELEASE-NOTES.md also lacks v1.
  - SKILL step 2 therefore picks v0.1.0, and `merge v0.1.0 HEAD` **re-consumes PR-1**. This double-release is a consequence the finder did not report.
  - Cherry-picking or merging the release commit carries the deletion, because it is in the same commit (PR-1.md measured gone).
  - The exposure depends on how the release commit reaches main, which is why this is P3 and needs-runtime.

#### NEW

- [P3] SKILL.md:441,459-461 — a first release (no tag) has no expressible `<range-start>`. Step 2 falls back to `--after=<date>`, which is not a ref. The tests use the empty-tree hash, which "works" only because invalid refs are swallowed. I-9's "validate both refs" fix will turn that into rc 2 (measured: 3 tests break). `git rev-list --max-parents=0 HEAD` works, except for fragments introduced in the root commit. Fix: a root sentinel, or document the root-commit form · structural+measured.
- Fix-shape correction for the L-PERF one-pass (see the KEPT P3 on `fragments merge`, above). The finder's "Clean: … same consumed sets" is true only on its linear fixtures.
- Noted, not a defect: update-pr-body.sh:101 passes NEW_SECTION to awk through the environment, which falls under the same 128 KiB per-string cap. It is unreachable in practice: GitHub caps a PR body at 65,536 characters, and the section is 1-3 bullets.

#### DROPPED

- [P2] commit-and-push.sh:41-52 commits the whole index — **duplicate** of SHELL-SEC P2 → V-SHELL P3 ("commit without pathspec"). The I-9 fix plan already says "commits only the fragment path". Reproduced with a bare origin:
  - With nothing pre-staged (the real workflow state: checkout, then extract-context writes an **untracked** context.json), the bot commit holds only the fragment.
  - Extra files leak only when they are pre-staged.
  - Nothing in doc-pr-release.yml stages files before the agent. In agent mode the action grants no Bash (V-CI P1 / I-8), so the script cannot run today.
  - The PR author already has push rights, and context.json holds only the PR body and commit messages, which are already public.
- [P2] test-doc-tools.sh:977-978,995,1012 empty-tree range-start pins the swallowed-ref bug — **duplicate** of S2-CORR:32 / V-S2 P3. The mechanism is re-confirmed: `is-ancestor` against a tree returns rc 128. The new facet moved to NEW (first release).
- [P2] L-CONTRACT released-detection "new trigger" revert→tag→re-land — **duplicate** of V-S7 P1 (b), "feat→revert→tag→reapply → consumed=[]". Re-measured: PR-9 is in the tree and not in paths-out. The plan drift is kept as a P3.
- [P2] watermark: code plus fragment in one commit gives `new_commits=[]` — **duplicate** of V-S7 P2 ("race/bundled edit"). Re-measured: `new=[]`. The missing reconcile comment is the same skip, and the next code push posts it.
- [P2] doc-release.yml:88-97 slash command with no plugin install — **duplicate** of V-CI P1 / CI-INFRA:21 (I-8). The unused `DOC_SUPERPOWERS_VERSION` is V-CI P3.
- [P3] fixed `/tmp/extract-ctx-*`, `/tmp/.merge-stderr`, `/tmp/test-paths-out.txt` — **duplicate** of S9a P2 / S9b P3 / V-S9 P2.
- [P3] hash marker accepts any-length hex — **no observable consequence**:
  - A short hash makes `validate` report "drifted", so `merge` includes the fragment with a WARN.
  - extract-context reports it as not corrupt; the agent recomputes the hash, finds a mismatch, and takes the same "do not overwrite, post a reconcile comment" branch as for a corrupt fragment (yml:223-236).
  - The test-gap part (VAL-reg survives) is kept in the test-doc-tools P3.
- [P3] `fragments list` O(F²) — confirmation of the known S2 P3 → I-10, not new. Re-measured at 3.72 s for F=200 (the finder measured 3.74 s).

#### Clean lines

Plausible and consistent with re-runs:
- sort by N
- hash payload
- drifted inclusion
- update-pr-body marker checks
- bash-4 guard
- concurrency `false`
- paths-out-scoped deletion
- the plan contradicting itself on drifted fragments

Refuted in part: "one-pass fix yields the same consumed sets" (renames and merge-commit adds).

#### Mutants spot-checked (17)

The finder's verdict matched in every case.
- Survived (16): A-fix-lastline, F-newest-touch, F-drop-end-ancestry (equivalent), S-reg-canonical-order, L-reg-list-nosort, VAL-reg-missing-hash-valid, N-reg-merge-no-numeric-skip, H-reg-stage-all, H-reg-no-noop-check, G-drop-no-merges, G-drop-line1-check, G-drop-minlines, U-reg-drop-dup-check, Y-verify-always-green, Y-cancel-in-progress, R-release-guard-removed.
- Killed only by crash (rc 126, no Results line): G-drop-size-cap.
- Also re-ran: P3fix (ref validation) → suite aborts rc 2.

#### Safety

`git -C /home/user/doc-superpowers status --short` → empty (verbatim below). All fixtures, mutants and `_frag_only.sh` live only in `$S/repo`. I did not read the finder's `fu1` scratch dir.
```
```

### V-FU2

### Phase-3 VERIFIED — FU2-S4 (install.sh + state.sh; L-PERF + L-DEADCODE-SIMPLIFY), run 05ea982

Harness: fresh clone at $S=scratchpad/vfu2/skill (HEAD 4fd341f; install.sh and state.sh are byte-identical to 05ea982, checked with diff). Consumer repos are under $S. HOME, GIT_CONFIG_GLOBAL and GIT_CONFIG_NOSYSTEM were sandboxed. Tools: bash 5.2.21, jq 1.7, strace -f. Spawns were counted with a PATH shim that logs each call and then execs the real binary (22 tools). No bash 3.2 binary was available, so 3.2 claims were checked by reading the code only.

#### KEPT

[P2] state.sh:31,179-182,196-199,214-217; install.sh:521-524 — when installed.json exists but is malformed, `install --ci` rebuilds it from disk and `uninstall` resets it to an empty skeleton. Both lose every `intentional` record, so workflows removed on purpose come back. The :31 contract ("fall back to filesystem inference") is also false for uninstall, which never infers anything and only writes the skeleton · root cause: the file is treated as a cache that can be rebuilt from disk, but the one thing in it that can't be rebuilt is exactly what the fallback throws away · measured:
- Two-branch merge: base had doc-review-pr intentionally uninstalled. Branches A and B each ran a plain `install --ci` 1.1 s apart. The merge gave UU with 3 conflict hunks. Running `install --ci` then printed the WARN and "9 installed, … 0 skipped (intentionally uninstalled)", doc-review-pr.yml was back, and its state was `{"state":"installed"}`. The rewritten file is now valid JSON, so `git add` "resolves" the conflict with the resurrected state. A `git merge --abort` afterwards still leaves the resurrected .yml as an untracked file.
- Uninstall variant: with a conflict-marker line prepended, `uninstall --ci --workflows=doc-release` left a file holding only doc-release. The next plain install brought back doc-pr-full-cycle, which had been removed on purpose.
- Severity: borderline P2/P3, kept at P2. Re-running the generator to clear a conflicted generated file is the natural, lockfile-style fix, and the installer itself creates the conflict (known P2 installed_at churn). Mitigations: a WARN is printed, the resurrected files are uncommitted, and the old file can be recovered from git.
- Pin: test-hooks.sh:1388-1401 must change.

[P3] state.sh:146-233; install.sh:538-557,567,595,665-703 — every state mark is a full transaction: validate, transform, re-pretty, date, mktemp and mv · root cause: marks are separate read-modify-write calls, not one batch per run · measured:
- Fresh `install --ci`: exactly 53 jq, 12 mktemp, 12 mv and 13 date, so 12 rewrites. `uninstall --ci`: 33 jq and 11 mv.
- Timing: 368-410 ms as shipped vs 83-93 ms with the state calls stubbed out, so about 300 ms (78%) is state bookkeeping. This agrees with the finder's 80 ms prototype.
- Caveat on the finder's rationale: the claim that a run interrupted mid-loop leaves the state half-marked argues the wrong way for uninstall. A single flush at the end would leave workflows that were removed but never marked, and the next plain install would bring them back. Flush (or mark) before deleting any files.
- Impact: a one-shot command under 0.5 s, so low.

[P3] state.sh:51-58,74-77; install.sh:447,495-517 — the workflow list is re-derived for every membership test (basename for each template, plus sort), so cost is O(k·W) · structural + measured (strace): default `--ci` = 168 execve; the 9-name CSV = 338 execve (174 basename, 19 sort, 21 grep) and 516-554 ms vs 362-402 ms. Bounded by W=9.

[P3] install.sh:715-719,757 — status_ci calls state_is_valid twice, so a malformed file prints the WARN twice (measured: once before the list, once after the "doc-tools.sh: vendored" line). It also runs one jq per absent workflow (10 jq with 8 absent) · measured.

[P3] install.sh:727-731 — `status` on a file that is valid JSON but the wrong shape exits rc 5 right after "CI/CD Workflows:" with no message · root cause: `2>/dev/null` plus errexit on `entry=$(jq…)`, and validity is checked for syntax only · measured with `[]`, `{"tiers":{"ci":{"workflows":[]}}}`, and a plausible future shape `{"schema_version":2,…{"doc-audit-update":"removed"}}`. This is a new symptom of the known state.sh:91-100 syntax-only issue, so fold it in there.

[P3] state.sh:18-19,132-140,207-233; install.sh:567,595,689,702 — write-only state: nothing reads `.tiers.ci.tools`, `.tiers.ci.helpers`, `.dest`, `installed_at`, `uninstalled_at` or `schema_version` in installed.json · structural (grep -rn over the repo; the only `schema_version` hits are for the doc-index) + measured (after `doc-tools.sh tools uninstall`, the state still says tools and helpers are "installed", .github/scripts is gone, and `status` says nothing). Citation fix: the prose is at SKILL.md:529, not :531.

[P3] state.sh:235-248 — state_dump_ci has zero callers · structural: `grep -rnw` over the repo finds only its definition.

[P3] install.sh:715,724 — the `found` counter is incremented but never read · structural.

[P3] install.sh:423-424,433-457 vs 495-517 — the CSV split/validate logic is duplicated. The resolver copy can never fail on install. Line :424 is dead, because :423's `:-all` already maps empty to all · structural.

[P3] state.sh:44-70; install.sh:83-86,468-471,555 — the hardcoded fallback list, the `return 1` branch (unreachable in practice) and the hand-written name list in usage() · structural. The only files that source state.sh are install.sh:46 and test-hooks.sh:1363, and both set SCRIPT_DIR. If the fix removes the fallback, it must also update docs/codebase-guide.md:123, which documents it.

[P3] install.sh:562; state.sh:40,84-86,109-112 — guards and knobs that never apply: `[[ -f $DOC_TOOLS ]]` is always true (main exits at :770-774 otherwise); the SC2034 directive does nothing; DOC_SP_STATE_FILE has a single reference (its own definition) and nothing sets it; the INTERNAL guard is unreachable · structural (shellcheck not available; the SC2034 point was checked by reading).

[P3] install.sh:559-606,676-703,748-756 vs doc-tools.sh:1797-1935 — the vendoring of doc-tools.sh and the helpers is implemented twice, and the copies have drifted · measured: after appending a line to extract-context.sh, `uninstall --ci` deleted the helpers dir, while `tools uninstall` printed "Kept … (contains local edits or unknown files)". Caveat on the finder's fix (delegate to `tools …`): it would import the known V-S2 P2 defects of `tools uninstall` (rm -rf of user-added files, a DRIFTED doc-tools.sh removed, a false "Kept" after a plugin upgrade). Fix those first.

[P3] install.sh:781-806,814-884 — flags outside a command's scope are silently ignored · measured, all rc 0:
- `status --ci` prints all 3 tiers.
- `uninstall --ci --helpers=false` still deletes the helpers.
- `install --ci --transient`.
- `uninstall --ci --force --cron x --ci-strict`.
- Also `status --workflows=bogus` and `install --git --workflows=bogus`, because the only name validation is inside install_ci.

[P3] install.sh:21-25,483 — the VERSION computation only feeds `__VERSION__` → DOC_SUPERPOWERS_VERSION, which nothing reads · known-adjacent (S6 remove list); structural (grep: 6 template definitions, 0 readers).

[P3] install.sh:93-101,144,181,304 — the 3-expression sed render is copy-pasted 3 times, and the two marker functions are identical except for the marker · structural, known-adjacent (sed escaping, dead `__DOC_TOOLS_PATH__`).

[P3] install.sh:5-6 — the header usage comment omits --workflows, --helpers, --force and --transient · structural. Only this part is kept; the menu part is dropped as a duplicate (see below).

#### DROPPED

- **Claude tier: 5 jq on install, 2 on uninstall, 3 on status (install.sh:309-403).** The counts are correct, but the cost is about 16 ms in a one-shot command, and the same lines are rewritten by the known P2 "settings merge breaks" fix (V-S4S5). Not a standalone defect.
- **`--workflows=all` "contradicts explicit beats state" (install.sh:541-543).** Refuted. The comment at :539-540 says "explicitly *listing this workflow*", and `all` lists nothing. usage :70 says `"all" (default)`, and the skip hint at :611 tells the user to pass `--workflows=$n`. The measured result (8 installed vs 9 for the CSV) is what the design intends. The only residue is that usage's "installs every template" leaves out state-respect, which is a doc nit.
- **Secrets NOTE covers every doc-*.yml on disk (install.sh:621).** Behavior confirmed: 0 NOTEs in a fresh repo, 1 when doc-review-pr is already on disk. But the NOTE correctly describes what the repo needs right now, so it is not a defect. The `-r`/`-l` flags are cosmetic.
- **The "Env overrides" line misleads (install.sh:883).** Refuted: "hooks never see that environment" is false. Git hooks inherit the environment of the git process the user starts from their shell, which is the same shell that runs `status`. git/pre-commit:11,65 and claude/pre-commit-gate.sh:8,69 read exactly these variables, and git/pre-commit:60 tells the user to set `DOC_SUPERPOWERS_SKIP=1` in that shell to bypass. Leaving out DOC_INDEX is trivial.
- **Menu [1] omits pre-push, [2] omits post-commit sync (install.sh:822-823).** Duplicate of known items: S4-CORR P2 (install.sh:60-62,822-824), S4S5-CONTRACT P2, and the V-S4S5 "help/menu understate" item.
- **Clean-line nits (conclusions unaffected).** `__BASE_BRANCH__` appears in 7 templates, not 6. The state.sh header omits the `{state:"uninstalled",uninstalled_at}` shape written for tools and helpers, so "matches exactly" overstates it slightly. Every other Clean line was spot-checked and holds: 15/15 install.sh functions have callers and 11/12 state.sh ones do; the token counts are 8 `__INSTALL_DATE__`, 7 `__DOC_TOOLS_PARENT__`, 6 `__VERSION__`, and 1 each for cron and strict; nothing walks the repo.

#### NEW

[P3] install.sh:633-636 (and status_ci :710-713) — `uninstall --ci` returns "nothing to uninstall" when `.github/workflows/` is absent. It skips the vendored doc-tools.sh, the helpers and every state mark, which contradicts :671-672 ("even if the file was missing on disk … we still flip state"). `status` returns early in the same way and hides the helpers, tools and state lines · root cause: whether the tier is present is decided by the workflows dir, not by what the tier installed · measured: `install --ci`, then `rm -rf .github/workflows`, then `uninstall --ci` → "nothing to uninstall"; `.github/scripts/{doc-tools.sh,doc-pr-release}` remain, and the state still says tools, helpers and doc-release are "installed" · fix: drop the early return (the loops already check each file).

[P3] install.sh:538-547, 722; state.sh:161-172 — state-respect ignores whether the file is on disk. Suppose a managed workflow recorded as intentionally uninstalled is back on disk (restored by hand, or kept from a modify/delete merge). Every plain upgrade then skips it, so it is never re-rendered and stays frozen at the old template, and the hint "previously uninstalled" is false. Meanwhile status_ci shows "✓ installed", because it never checks the state when the file exists · root cause: the state and the disk are treated as two independent truths, and nothing reconciles them · measured: restored with `git checkout HEAD~1 -- .github/workflows/doc-release.yml` and edited; `install --ci` then gave "1 skipped (intentionally uninstalled) … skipping doc-release.yml (previously uninstalled…)", the edit survived, and `status` showed "✓ doc-release.yml installed" · fix: if a managed file is present, treat it as installed (refresh it and mark it), or warn that the state and the disk disagree.

[P3] install.sh:442-457, 495-515 — CSV workflow names are not de-duplicated. `install --ci --workflows=doc-release,doc-release` prints "2 installed", renders the template twice and rewrites the state twice · measured · fix: de-duplicate in the single validate step proposed by the CSV-duplication item.

### V-FU3

### Phase-3 VERIFIED — FU3-S8-init (init output contract + Spec Status Model + protocol), run 05ea982

Method: re-read every cited line in the live tree (HEAD 4fd341f). Checked each item against test-spec-status-model.sh, SKILL.md, all references/*, RELEASE-NOTES.md, the design doc, and the already-verified findings (V-S1, V-S2, V-S8, S8-CORR/CONTRACT, X-DATAFLOW), so known items are not double-counted. Re-measured on a fresh 3-file sample repo (package.json, src/app.js, README.md) using a clone of the repo at $S/repo (S=…/scratchpad/vfu3). Re-rendered all 11 mermaid blocks with the finder's mmdc binary, run read-only (output in vfu3/mmd).

#### KEPT

[P2] references/spec-lifecycle-actions.md:184-190 (+:249) — P1→P2. Defect: in per-chunk Task N+1, the exempt-status bullet says only "leave unchanged (R3)". Steps 2 (add Implementation Notes), 3 (replace `code_refs` with chunk file paths) and 4 (update-index) still run for Active/Deprecated/Superseded/unknown targets. That contradicts R3 (:26), Evaluation order step 2 (:74 "exempt → stop, write nothing") and design :143 ("per R1–R3"). Nothing pins it: test-spec-status-model.sh has 0 assertions on the skip clause. Eval 13's SPEC-ARCH-004 (Active, unsuffixed) is exactly this case. The :249 half is partly mitigated: always-loaded SKILL.md:660 gates Implementation Notes on "target role, ladder status", but not the code_refs refinement or update-index. · Root cause: the "skip Steps 2–4" clause was attached per role (constraint/amendment), not per R3 status class. · Why downgraded: there is no Status write. V-S8 kept COR-8 (a constraint spec falsely *advanced*) at P2, and this is strictly milder. · structural

[P2] references/doc-spec.md:50-58,128,301,343,372,510,539,557 + SKILL.md:402-404 — P1→P2. Defect: no template has a Mermaid-source slot, and `diagram` step 1 finds docs only by `rg -l '```mermaid' docs/`. Docs generated from the templates are therefore invisible to later diagram regeneration and the accuracy check. When the MCP renders, only the PNG link survives and the source is lost. The repo's own convention is not encoded in any template: a `<details><summary>Mermaid source</summary>` block under each PNG (system-overview.md:15-44, 2 blocks; workflows/doc-superpowers.md, 10 blocks), backed by CLAUDE.md "Mermaid source in docs". · Root cause: templates assume PNG-only output. · Why downgraded: this degrades a maintenance action but loses no data. SKILL.md:417/:634 ("output Mermaid source") partly covers the no-MCP path. The broken-PNG-link half is known (S8-CORR:33, in the V-S8 P3 bucket) and is excluded here. · structural

[P2] SKILL.md:291-292 (init steps 12–13) + references/doc-spec.md:862 — Defect: there is no rule for choosing `code_refs`. The step-13 gate runs on uncommitted init output, then the init commit makes stale every doc whose refs overlap what init itself wrote. · Root cause: the prompt assumes code_refs never overlap the files that the write actions (docs/, README sync, CLAUDE.md) change. · Measured:
- Gate: 9/9 current.
- After `git commit`: 2 stale (`codebase-guide.md` stale via `.`, `getting-started.md` stale via `README.md`).
- NEW evidence: `.` (or `docs/`) is an unsatisfiable fixed point. After update-index, 9/9 were current. Committing that index refresh made codebase-guide stale again, because docs/.doc-index.json sits under `.`.
- The repo's own index maps getting-started.md to README.md.

[P2] SKILL.md:237-238 vs :144-145; references/doc-spec.md:138,546,779 — Defect: two predicate sets decide the same outputs, and they disagree:
- **api-contracts.md**: the Scope matrix emits it only when a schema-file glob matches. doc-spec says to generate it unless there is "no HTTP/RPC/GraphQL API", so a routes-only Express/Flask/FastAPI app gets no api-contracts.md.
- **ERD**: Required Diagrams marks the ERD "Always / Do NOT skip", but data-layer.md is "skip if no persistence".

· Root cause: independent predicates for one output. · structural

[P3] references/spec-lifecycle-actions.md:20 vs :285 + design:165-167 — P2→P3. Defect: :20 routes every non-ladder value to the unrecognized-status line, which includes sanctioned Active/Deprecated/Superseded. :285 and design B2 limit that line to values outside the documented vocabulary. Normalization is defined only for ladder matching. · Why downgraded: the effect is noise in a P3 info line that never contributes to FAIL. · structural

[P3] SKILL.md:52-55 — P2→P3. Defect: the `[scope]` argument is consumed by no action procedure (grep: only :52 and README.md:91). "Auto-detected from docs/ structure" is also wrong, since most scopes come from code signals (:139-152). · structural

[P3] SKILL.md:63-72 — P2→P3. Defect: in Spec Lifecycle Routing, "Has design doc? → spec-generate" is the first decision, so a persistent design doc shadows the inject and verify branches. · Why downgraded: the Quick-routing text at :582-587, directly below, routes correctly, and explicit commands bypass the diagram. · structural

[P3] references/doc-spec.md:282-305,777,796 + SKILL.md:235 — P2→P3. Defect: the "workflows/ primary" doc has no filename. The Required-Diagrams flowchart is "Always", but the workflow template has no flowchart slot, and `workflow-primary.png` is referenced by no template. · structural

[P3] references/doc-spec.md:430-438 vs :782-784, :508/:537; SKILL.md:408-412 — P2→P3. Defect: there are three unreconciled trigger sets for agentic diagrams. The "Overview" flowchart is required "Always" but has no doc or filename. · structural

[P3] references/doc-spec.md:839-843; spec-lifecycle-actions.md:96,122 — P2→P3. Defect: "next available" NNN is not tied to docs/archive/. · Why downgraded: the spec rule is only "Sequential per category", with no never-reuse rule; ADRs carry "never reused" but nothing documents moving them to the archive. An ID can be reissued only when the max-numbered spec is archived without a same-category successor. · structural

[P3] SKILL.md:150-151,243-244,285 — P2→P3. Defect: `adr` is detected from `docs/decisions/`, but generation always writes into docs/adr/, so a project already using docs/decisions/ gets a second, empty ADR log. · Why downgraded: the Explore "Existing Docs" agent (:279) surfaces docs/decisions. The `spec`←docs/superpowers/specs half is harmless, because step 6 generates specs/README+template unconditionally anyway. · structural

[P3] SKILL.md:588 — Defect: "FAILs in both modes" is wrong for review mode, which emits a P1 finding and has no verdict (spec-lifecycle-actions.md:323-326). · structural

[P3] references/spec-lifecycle-protocol.md:46-47 — Defect: "must be committed" is required by neither the actions nor SKILL.md, and "must exist (bootstrapped if missing)" contradicts itself. · structural

[P3] SKILL.md:252-264 — Defect: the Action Routing diagram has no `sync` leaf and no spec-* leaf, and "no docs/ → init" captures hooks and spec-generate requests. · structural

[P3] SKILL.md:243-244 vs :285 — Defect: the matrix makes the adr/specs README+template conditional on "(existing)", but init step 6 generates them unconditionally. · structural

[P3] SKILL.md:241,245 vs references/doc-spec.md:42-72,632-664,670-696 — Defect: the `testing` and `monorepo` scopes point to sections that no template contains. · structural

[P3] references/doc-spec.md:104,128,794 — Defect: the component diagram has no Required-Diagrams row or syntax. "Discovered by scope detection" is wrong, since components are found by Explore agents. · structural

[P3] references/doc-spec.md:510,539 vs :797-798,:813 — Defect: the agentic template uses `{name}` where the file is `{skill-name}`, and agentic docs share the `workflow-{slug}.png` namespace with regular workflow docs. The repo already has `workflow-doc-superpowers.png`, so a skill doc of the same name would collide. · structural

[P3] references/doc-spec.md:805-816 — Defect: the naming table has three gaps:
- `erd.png` and `{component}.png` break `{type}-{name}.png`.
- It says "one per structured dir", but only specs/ and adr/ get a template.
- It has no row for the README.md index files, so audit step 4 (SKILL.md:302) can flag them.

· structural

[P3] references/doc-spec.md:161-168,607-622,637-644,724-734 — Defect: nested fences are written as `\`\`\`` inside ```markdown templates. Copied verbatim, they produce backslashes instead of a code fence. spec-lifecycle-actions.md:197 already uses the 4-backtick form. · structural

[P3] SKILL.md:286 vs :290 + references/doc-spec.md:30 — Defect: there are two marker forms, bare and dated. The "every generated file" rule stamps template.md, so every hand-copied spec/ADR inherits a false "Generated by" line. · structural

[P3] SKILL.md:271,286 — Defect: there is no flat→structured mapping table, and no Status/Date rule for seeded ADRs. · structural

#### DROPPED

- **P2 Realized-by parser disagreement** (doc-spec 185-248 + doc-tools 760/1691/1731) — duplicate of V-S2 P1 (doc-tools.sh:1686-1698,1729-1735 vs 758-762) and V-S8 CON-5 (templates lack an Implementation/Realized-by block). Re-measured identically:
  - update-index captures `["PR: #7 — complete"]`.
  - implementation-status reports "no Implementation field".
  - set-implementation (rc 0) inserts a second `Implementation:` block between `**Date:**` and `**Source**`.
  - After update-index, the index reads `["PR: #8 — partial"]` (PR #7 silently dropped).
- **P2 plans/design docs permanently untracked** (doc-tools.sh:657; SKILL.md:222,335) — duplicate of V-S1:23 (the same cites, doc-tools.sh:657 and SKILL.md:335: point-in-time records) and X-DATAFLOW:16/27. Re-measured: `summary.untracked=2`, while docs/archive/plans/old.md was correctly excluded. "Permanently" is really the remedy-routing defect (build-index at :639), which is V-S8 CON-3 / V-S1 P1.
- **P2 :45 role inference as literal set intersection** — duplicate of V-S8 CON-9 (S8-CONTRACT:39-40, whose fix-shape is "define intersection as prefix match").
- **P2 R1 Status syntax** — the `**Status**:` vs `**Status:**` half at :195 is duplicate V-S8 CON-5 ("COR-9 status-header half"). The rest is intended design, not a defect. A missing Status line or an unedited `Draft | In Review | …` list is non-ladder, so it is R3-exempt by the design's deliberate open-world rule (design :73-75). It is surfaced by the :285 unrecognized-status line, since a pipe list is outside the documented vocabulary, which is the signal design B2 chose. No tool parses Status, and agents read it semantically rather than by regex.
- **P2 specs README has no category list** (doc-spec.md:821,835) — refuted. The README template's `Category` column (:259) is the in-use category list, so "Check docs/specs/README.md before creating" can be satisfied against it. spec-generate's 9 codes are a "classification lens" (spec-lifecycle-actions.md:93), not a closed list.
- **P3 Approved leapfrogged by finalize** — intended and documented. :29 and :252 say "`Approved` is human-set — no action ever writes it; it appears on the ladder so R2 can protect specs that carry it", matching design :89-91, and R4 is the stated advancement gate. This is a design critique, not a defect.
- **P3 :283 "three" vs four P3 lines** — duplicate of V-S8 CON-13.
- **P3 init creates empty archive/plans dirs** (SKILL.md:223-227,282) — duplicate of S8-CORR:42 (in the V-S8 P3 bucket).
- **P3 SKILL.md:291 flat mapping example / doc_type vocabulary** — the flat-example half duplicates S8-CORR:42 ("flat-path build-index example"). No tool branches on doc_type (grep of doc-tools.sh and hooks), so the vocabulary half is hygiene only.
- **P3 doc-spec.md:780 "Sequence (if multi-step) | Always"** — duplicate of S8-CORR:40.
- **The broken-PNG half of P1 #2** — duplicate of S8-CORR:33.

Clean lines — plausible, spot-checked:
- **Mermaid validity**: re-rendered all 11 blocks (doc-spec L76, 88, 309, 320, 377, 391, 415, 578; SKILL L10, 62, 251). All rc=0, 0 "syntax error" occurrences, SVGs ≥16 KB. SKILL.md's 4th "```mermaid" hit (:404) is inside a bash block, so there are 3 real blocks.
- **Actions**: Usage and Quick Reference both list 11 actions.
- **Relative image paths**: all resolve.
- **Evaluation order and design §A**: the order (role→R3→R4→R2→write, :71-77) matches design §A.
- **Protocol**: 5 interception points and 3 actions match.

#### NEW

[P3] references/spec-lifecycle-actions.md:230 vs :272-273,:301-304 + references/agent-prompt-template.md:60 — Defect: the finalize partial-coverage branch leaves an **Approved** target at Approved with its remaining scope recorded (R2: "leave it exactly as it is"). spec-verify's carve-out covers only a target "held at `In Review`". An Approved partial therefore falls into "target at a ladder status → expect `Implemented`" and produces a FAIL, and it is missing from the exemption list at :304 and the "Held at In Review" P3 line at :287. The review-agent table (:60) has the same gap. This contradicts design :147 ("Require `Implemented` only for fully-covered target specs"). · Root cause: the carve-out keys on the status value (In Review) instead of the recorded-remaining-scope condition. · Rare, because Approved is human-set. · structural

(The `.`/docs/ fixed-point evidence is recorded in KEPT #3 as new measured evidence for an existing finding, not as a separate defect.)

Repo check: `git -C /home/user/doc-superpowers status --short` → (empty)

### V-FU4

### V-FU4 — adversarial verification of FU4 (L-PORTABILITY hooks + L-DOCS-DRIFT specs), run 05ea982

Scratch: .../scratchpad/vfu4 (clone of 4fd341f; consumers c2/c4/cons, rootc). Repo never used as cwd/target for hooks,
doc-tools, installer or tests. Sources fetched for regex claims: musl regcomp.c (kraj/musl mirror), OpenBSD
lib/libc/regex/regcomp.c, bash CHANGES (gitGNU/gnu_bash mirror). GitHub API was used for Actions runs/jobs/workflows.

#### Premise check ("no shipped script changed since last green macOS run 30534235767 @ 6e2bc76")
TRUE, with one precision fix. `git diff --stat 6e2bc76 05ea982 -- scripts/` = only `scripts/test-spec-status-model.sh | 36 +`.
6e2bc76 is NOT an ancestor of 05ea982: it is the PR #16 head on `feat/archive-entry-batch-primitive` (a pull_request run).
It is docs-only on top of f8c2b51, so its scripts/ tree equals f8c2b51's (last green main push, run 30507656289). The API
confirms run 30534235767: both legs green, macos job 90843534717 on runner 1000032159, all 11 steps executed. Runs 8–11
(33598113151 / 33598325258 / 33598387818 / 33598479235) show both jobs `failure` in 2–5 s. The jobs have no runner_id and
no steps, and the logs return 404. Consequence: the +36 lines of test-spec-status-model.sh have never run on either leg.
One of those lines is vacuous (NEW-1).

#### KEPT
- [P3] .github/workflows/tests.yml (bash-3.2 evidence gate) — the Tests workflow has not executed since 2026-07-30. Runs 8–11 have no runner assigned, and v2.15.0 (595b2c9) and HEAD 05ea982 shipped with both legs red. The root cause is unknown/needs-runtime: nothing in the repo explains a job with no runner, and "treated as noise" is inference. Already folded into I-14 via this FU · measured (GitHub API)
- [P3] scripts/hooks/git/pre-commit:26, prepare-commit-msg:23, post-merge:26, post-checkout:30 (+ claude/*.sh check-freshness call) — macOS GUI clients run hooks with launchd PATH `/usr/bin:/bin:/usr/sbin:/sbin`, so Homebrew jq is invisible. check_deps (doc-tools.sh:11-24) then exits 1, and `|| exit 0` silently removes the gate, STRICT included. The scope is narrower than stated in two ways. macOS 15 ships /usr/bin/jq, so this affects macOS ≤14. And some clients import the login-shell environment, so "all five" named clients is unverified · root cause: interactive-shell PATH assumed · structural (the silent-skip half is the I-6/S5-P2 "failing == absent" class; the PATH trigger is new)
- [P3] scripts/hooks/install.sh:157-168 — the integration block is inserted before EVERY column-0 line starting `exit 0`, not the "final" one the spec promises (workflow-hooks spec :243, :505). Measured: a host hook with an unindented `exit 0` in an early `if` branch got 2 copies, so the doc hook also runs on the host's early-exit path. With the same `exit 0` indented it got 1 copy, so the trigger is column-0 only. This defect is not in I-7's integration-block list (`[[`, `"$@"`, STRICT, exec) · root cause: "last exit 0" implemented as "each line with that prefix" · measured
- [P3] docs/superpowers/specs/*: Status headers misstate lifecycle in 5 of 6 specs:
  - 2026-03-12 :5 says "11 subcommands"; the dispatcher has 14.
  - 2026-03-13 :5 says "v2.12.0 (in flight on feat/granular-install)"; it shipped 2026-05-16.
  - 2026-03-14 :4 says "Approved"; it shipped in v2.2.0. Its transition text was replaced by the 2026-07-24 model with no pointer back.
  - 2026-03-25 has no Status line.
  - 2026-07-24 :4-7 says "Approved, Target 2.13.0"; it shipped in v2.13.0.

  Why this matters: the repo's Spec Status Model reads these headers. All 6 specs report `stale` under the repo's own check-freshness (measured in the scratch clone). The committed fix plan 2026-09-27 names 5 of them as `governing_specs` · root cause: no step updates a spec's Status or supersession pointer when it ships or is superseded · structural + measured (check-freshness)
- [P3] …workflow-hooks-harness-design.md:220, 287/321/650-651, 288, 324 — the spec prescribes four mechanisms that measurably do not work, and the code implements them as written:
  - `#` block "excluded from commit": git's default cleanup keeps it with -m. The local shallow history has 25 commits / 27 lines containing it; FU4's "28" was not reproduced, which does not matter.
  - The no-arg `update-index` refresh fails: "ERROR: update-index requires at least one doc path argument.", rc 1, index unchanged.
  - The `diff-tree` root-commit fallback prints nothing.
  - The session-summary 1 s budget is not met on the fallback path: re-measured at 8.8 s and rc 0, reporting "400 stale" while listing 350.

  This is the spec side of I-6 P1/P2, I-14 (`auto-run update-index` claim) and S1-PERF. Change the spec in lockstep with those fixes · measured
- [P4] scripts/hooks/claude/post-commit-sync.sh:31 (+ .claude copy :31) — the "handles initial commit" fallback does not. Measured on git 2.43: `git diff HEAD~1..HEAD` rc 128, `diff-tree --no-commit-id --name-only -r HEAD` prints nothing, and `--root` prints `a.sh`. Re-severity from P3 to P4, for two reasons. First, the hook never activates today (I-6 TOOL_INPUT P1). Second, the trigger needs an index present at the repo's first commit · root cause: diff-tree assumed to diff a root commit against the empty tree · measured
- [P4] …workflow-hooks-harness-design.md mechanism samples that disagree with the code, none superseded by any RELEASE-NOTES entry:
  - :74/:241 — "copied locally as `.doc-superpowers-{name}` … avoids hardcoded absolute paths". The standalone install writes `<hooks_dir>/<name>` (install.sh:181), and both forms embed the absolute DOC_TOOLS_PARENT (install.sh:144, 181).
  - :101 — "core.hooksPath if set and the directory exists". The code uses it whenever it is set (install.sh:108-110) and then runs mkdir. The code is the right behaviour, because git consults hooksPath regardless.
  - :150-151/:223-224/:310-311 — the samples print `: <code_refs>`. check-freshness already emits `code_refs_changed` (verified in the per-doc keys), but the hooks drop it.
  - :179 — the untracked hint says build-index; the code says sync/add-entry (git/post-merge:54).

  · structural
- [P4] …bundled-doc-tooling-design.md (not superseded):
  - :343 — the spec says "suggesting build-index"; the code says "Use add-entry" (doc-tools.sh:715).
  - :123-129 — the spec says each scope agent "**must** use superpowers:writing-plans" and always saves a plan. SKILL.md:382 saves a plan only "for non-trivial changes" and never invokes writing-plans, and no RELEASE-NOTES entry records the relaxation.

  · structural
- [P4] …release-notes-action-design.md:128 — the note (added 2026-04-05) says bump-version is "step 7 … before the git tag offer". It is step 10 in SKILL.md:491, and step 7 of this spec is the CLAUDE/README sync · structural
- [P4] …github-pages-site-design.md:104,109 — the config.ts sample declares `themeConfig.nav` twice, and the later key wins in JS · structural (hygiene only; see DROPPED for the Status claim)

#### DROPPED (with refuting evidence)
- L1 [P3] `\b`/`\s` in `grep -qE` (claude/pre-commit-gate.sh:23, post-commit-sync.sh:22). This is outside the stated targets:
  - Stated support is bash 3.2 + macOS BSD userland. No doc names OpenBSD, NetBSD, FreeBSD, busybox or musl (grep over *.md/*.sh/*.yml).
  - macOS is verified: test-hooks.sh:460/477 can only pass if the grep matches, and they passed on macos-latest with /usr/bin/grep in run 30534235767.
  - The "busybox-on-musl" example is REFUTED: musl's TRE-derived regcomp.c implements `\b` (ASSERT_AT_WB, line ~818) and `\s` (tre_macros `{'s',"[[:space:]]"}`, line ~425).
  - The OpenBSD part is true: libc regcomp.c backslash() handles only `\<` `\>`, so `\b` is a literal b. But OpenBSD is not a target.
  - On macOS ≤12 the question is moot, because `sort -V` (I-7) empties DOC_TOOLS and the hook exits at :25 anyway.

  The fix text overlaps the S5-CORR false-match fix.
- L1 [P3] install.sh:442/503 `--workflows=,` → "raw[@]: unbound variable" abort. REFUTED:
  - Measured on bash 5.2: IFS=, splits "," into 1 empty element and ",," into 2, so raw/_wfs are never empty for a non-empty filter. An empty filter is mapped to "all" first (:424, :496).
  - The real empty expansion is :457 `printf '%s\n' "${names[@]}"`. On bash 3.2 it errors, because bash CHANGES 4.4-release §3a: "Using ${a[@]} … without any assigned elements when nounset is enabled no longer throws an unbound variable error" (so ≤4.3 throws). But :457 runs inside `< <(ci_resolve_workflow_set)` (:531, :659), whose exit status is discarded.
  - Result: only a stderr line on 3.2; the outcome is the same as on 5.2 (measured: rc 0, "0 installed"). Re-filed as NEW-4 (P4).
- L1 [P3] doc-tools.sh:251-254 usage text ("bump-version … Files: RELEASE-NOTES.md …"). The text is confirmed (VERSION_FILES :1247-1254 has 6 JSON files), but this is a DUP. It is the open local issue docs/issues/2026-07-29-usage-omits-implementation-verbs.md, which RELEASE-NOTES v2.14.0 records verbatim, and I-4 absorbs it. Its failure mode is also loud, because check-version FAILs, so it would be P4 anyway.
- Spec [P3] bundled-tooling :237/:600/:614 "nine/9/total to 9", and [P3] :619 "7 manifest files". These are dated Implementation-Notes and File-Changes history. RELEASE-NOTES v2.13.0 explicitly records the correction of the "9 or 11 subcommands" and "7 manifests incl. RELEASE-NOTES.md" claims. Only the Status-line count (a current-state claim) is kept, inside the Status P3.
- Spec [P2] bundled-tooling :181/:214 `"version": 1` with no `implementation`. This is superseded history: RELEASE-NOTES v2.11.0:125 ("schema bump `version: 1` → `schema_version: 2`") and v2.11.0 (`implementation` array). The live reference with the same error is re-filed as NEW-3.
- Spec [P2] bundled-tooling :222-233/:618 enum, writers, "deprecated terminal". The writer list is superseded, because each later verb (add/remove/deprecate/move-entry) has its own RELEASE-NOTES entry and the spec's own Implementation Notes list them. The code side (update-index un-deprecates, measured at doc-tools.sh:778-783) is I-3 P2. The live-ref side ("update-index un-deprecates vs doc-spec 'terminal'") is I-11. DUP.
- Spec [P3] bundled-tooling :23/:367-375 dependencies. jq is in the spec's own table (:373), and the GNU-sed need is recorded in RELEASE-NOTES v2.11.0 (gnu_sed helper), so both are history. "GNU sed missing from dependency lists" is already I-14, and dropping GNU sed is I-10. DUP.
- Spec [P2] workflow-hooks :72/:83/:98 `DOC_TOOLS="${DOC_TOOLS:-__DOC_TOOLS_PATH__}"`. Superseded by RELEASE-NOTES v2.12.2, which describes exactly this change to runtime parent-glob resolution. The hazards (sibling pickup, sort -V) are I-7 P2. History + DUP.
- Spec [P3] workflow-hooks :237/:242/:600 `source "$DOC_SP_HOOK"`. Superseded by RELEASE-NOTES v2.4.0:231 ("Hook integration uses subprocess instead of source"). The code side (STRICT swallowed, `"$@"` dropped, `[[` in /bin/sh) is I-7 P1. Re-measured anyway: under dash, `[[: not found` and the doc hook never runs.
- Spec [P3] workflow-hooks :162-167/:188 post-merge/post-checkout "full scope". Superseded by RELEASE-NOTES v2.12.3 (scoping to the changed files). History.
- Spec [P3] workflow-hooks :487-489 installer menu. This is code-side drift, and the spec is right. DUP of audit-findings:207 ("help/menu understate" → I-7/I-8).
- Spec [P3] workflow-hooks :684/:692/:720/:724 "8 CI workflows". These are commit-anchored Implementation Notes (696ba07, 05d981b) that were true at the time, and the spec's own Status line gives 9. History. (Also, :692's "3+4 … total to 8" is internally wrong, but that is history.)
- Spec [P3] workflow-hooks :728 merge-driver "three-way"/newer-wins, and "314 lines". The mechanism half is the spec side of I-5. The line counts (89/314) are anchored to commit d0fa416. DUP + history.
- Spec [P2] spec-lifecycle-protocol :130/:168/:193 update-index for a new spec and "refine code_refs". This is the origin of the same false claim that S8/I-11 already carries in the live references ("`replaces`/`code_refs` writes with no verb (GH #18)"). DUP.
- Spec [P2] spec-lifecycle-protocol :168-169/:196/:219/:234-235 unconditional Status writes. Explicitly superseded by the 2026-07-24 spec and RELEASE-NOTES v2.13.0 ("Replaces spec-inject's unconditional spec Status writes"). History. The missing back-pointer is kept inside the Status P3.
- Spec [P3] spec-lifecycle-protocol :187/:225 check-freshness "compares content_hash against code_commit" and reads `Draft`. S8 already carries this claim in the live references. DUP.
- Spec [P3] release-notes :30-51 8-step flow without the fragment steps. Superseded by RELEASE-NOTES v2.10.0 (fragment consumer). History. The :128 "step 7" note is kept as P4, because it is a current-state claim added later.
- Spec [P3] github-pages :4 "Approved" but never built. The facts are verified: no site/ and no deploy-site.yml in any fetched ref, and GitHub list_workflows returns 4 workflows with no Pages/deploy workflow. The plan 2026-03-29 has no executed tasks. Even so, this is not drift. "Approved" is the ladder state below Implemented and asserts nothing exists, and doc-index `current` is freshness, not realization. It is a dormant backlog item. Only the duplicate `nav` key is kept (P4).
- Spec [P2] spec-status-transition :94-110 roles as a two-way dichotomy. Explicitly superseded by RELEASE-NOTES v2.15.0 ("`--specs` recognised exactly two roles … adds `:amends`"), and the live contract references/spec-lifecycle-actions.md is current. History.
- Spec [P3] spec-status-transition :191-193 status enum "already correct". This sits in the Non-goals rationale. The live-reference error is NEW-3 / I-3.
- Lens-1 DUPs (sort -V → I-7; session-summary fallback → S1-PERF/X-CONC) are confirmed as DUPs. The fallback was re-measured: 8.8 s, 350 of 400 listed. The GNU `timeout` path took 1.01 s with no output.
- The Clean lines are confirmed:
  - The static guard targets exactly 15 files and covers every shell file under scripts/hooks/.
  - The .claude/hooks copies differ from the templates only at lines 2 and 5.
  - The git hooks have no bash-4 syntax and no `set -u`.

#### NEW
- [P3] scripts/test-spec-status-model.sh:206 — `assert_not_contains "$ACTIONS" 'amendment citation unverified (no \`--plan\`)'`. Inside single quotes the backslashes are literal, so the needle can never match the regressed backticked text. Measured: `grep -qF` of that needle against "WARN: amendment citation unverified (no `--plan`)" does not match, so the check always PASSes. This is the v2.15.0 "one literal, both sides" guard, and it is vacuous. It has also never run in CI (runs 8–11) · root cause: shell-escaping carried into single quotes · measured (I-13 cluster)
- [P3] scripts/hooks/claude/pre-commit-gate.sh:29-30 (+ .claude copy) — PreToolUse derives scope from `git diff --cached` BEFORE the Bash command runs. The typical Claude compound `git add … && git commit -m …` and `git commit -a/-am` therefore see an empty index and exit 0. Measured with STRICT=1 and a stale-making change:
  - `git add -A && git commit -m x` → rc 0, silent.
  - `git commit -am x` → rc 0, silent.
  - The same change pre-staged → rc 2, "1 stale doc(s)".

  This is latent behind the I-6 TOOL_INPUT P1 and survives that fix · root cause: pre-tool index assumed to equal the commit's content · measured
- [P3] references/doc-spec.md:857-869 — the LIVE schema table still documents `version` "(currently 1)", has no per-entry `implementation`, and lists `stale` as a stored status. build-index writes `schema_version: 2` (doc-tools.sh:439-445), update-index writes `.implementation` (:785), and `stale` is never stored. docs/conventions.md:322 has it right, so the two live references disagree. This is the live counterpart of the dropped design-spec items. The fix-plan Step 3 rewrites this table for schema 3, but no finding records the current error. Partial overlap with I-3/I-11 "index semantics misdescribed" · structural
- [P4] scripts/hooks/install.sh:457 — `printf '%s\n' "${names[@]}"` is the one unguarded empty-array expansion in the workflow-filter path; guard it with `${names[@]+…}`. Also, `--workflows=,` / `,,` / ` , ` is silently accepted as "install none" while still vendoring doc-tools.sh and bootstrapping state (measured on 5.2: rc 0, "0 installed"). It should error like an unknown name does · structural (3.2 effect is stderr noise only; see DROPPED)

