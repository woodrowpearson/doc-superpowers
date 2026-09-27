---
title: doc-superpowers full-repo sweep — Consolidated Findings Index
created: 2026-09-27
date: 2026-09-27
type: audit-findings
source: sweep-skill
issue: null
# NO `status:` — deliberate (sweep-skill rule). This index aggregates 14 clusters at
# different stages; tracking lives in the per-cluster issues + the fix plan's Tasks.
target: full repository @ 05ea982 (v2.15.0)
run-id: 05ea982
planes: [shell-tooling, ci-workflows, skill-prompt, cross-client-packaging, tests, docs]
related-files:
  - docs/plans/2026-09-27-full-repo-05ea982-fix-plan.md
  - docs/plans/2026-09-27-full-repo-05ea982-jumping-off-point.md
  - docs/plans/2026-09-27-full-repo-05ea982-evidence.md
  - docs/issues/2026-09-27-sweep-05ea982-I01-freshness-identity-model.md
  - docs/issues/2026-09-27-sweep-05ea982-I02-index-persistence-layer.md
  - docs/issues/2026-09-27-sweep-05ea982-I03-index-semantics.md
  - docs/issues/2026-09-27-sweep-05ea982-I04-doc-tools-input-cli-robustness.md
  - docs/issues/2026-09-27-sweep-05ea982-I05-merge-driver-not-three-way.md
  - docs/issues/2026-09-27-sweep-05ea982-I06-claude-hook-tier-and-hook-semantics.md
  - docs/issues/2026-09-27-sweep-05ea982-I07-installer-ownership-placement-state.md
  - docs/issues/2026-09-27-sweep-05ea982-I08-ci-templates.md
  - docs/issues/2026-09-27-sweep-05ea982-I09-release-fragment-pipeline.md
  - docs/issues/2026-09-27-sweep-05ea982-I10-implementation-version-vendoring-verbs.md
  - docs/issues/2026-09-27-sweep-05ea982-I11-skill-prompt-tool-contract.md
  - docs/issues/2026-09-27-sweep-05ea982-I12-cross-client-packaging.md
  - docs/issues/2026-09-27-sweep-05ea982-I13-test-suite-fidelity.md
  - docs/issues/2026-09-27-sweep-05ea982-I14-docs-and-self-dogfooding.md
---

# doc-superpowers full-repo sweep — Consolidated Findings Index

> Running index for the sweep-skill audit of **the whole repository at `05ea982` (v2.15.0)**,
> run-id `05ea982`. **This map is WHERE-to-look; fixes are a separate session** — see the fix plan
> ([`2026-09-27-full-repo-05ea982-fix-plan.md`](2026-09-27-full-repo-05ea982-fix-plan.md)).
> Methodology: the `sweep-skill` pipeline (Phase 0 discovery → 1 baselines → 2 lens fan-out →
> 3 per-surface adversarial verify → 4 completeness critic → 5 consolidate → 6 emit), applied with a
> **first-principles** brief: every finding names the *incorrect assumption* that produced it, fixes
> must be dependency-free, and new capability is proposed only where a demonstrated need exists.
> Verifier reports, surface map and prototypes are preserved in the
> [evidence appendix](2026-09-27-full-repo-05ea982-evidence.md).
> Evidence base: 21 Phase-2 leaf-auditor dispatches, 12 Phase-3 verifier dispatches, 1 completeness
> critic; scratch-repo reproductions, mutation testing of the suites, and reads of pinned upstream
> sources (claude-code-action `1eddb334`, OpenCode, Codex, Gemini CLI, Claude Code hooks docs).

## Executive summary

**Scale.** 113 tracked files in 11 surfaces + 2 catch-all files. After adversarial verification
(which dropped or downgraded roughly a third of Phase-2 claims — every P0 but one was re-severitied
on evidence), the verified set is **1 P0 · 51 P1 · 93 P2 · 88 P3 finding lines** (counted per
surface before cross-surface de-duplication), consolidated into **14 root-cause clusters (I-1 … I-14)**.
The Phase-4 critic found coverage gaps. Four verified follow-up passes closed them and added
**0 P1 · 8 P2 · 53 P3 · 5 P4** (see Phase 4).

**What is broken for users today** (all measured unless noted):

1. **The Claude Code hook tier has never activated.** The hooks read a `$TOOL_INPUT` env var that
   Claude Code does not set (input arrives as JSON on stdin), and their reports go to stdout, which
   Claude Code sends to the debug log. The test suite injects the env var, so it passes — and it
   *rejects* the correct fix. (I-6, I-13)
2. **The merge driver is not a three-way merge.** It keeps the entry with the newer `last_verified`
   and never compares either side to the base, so a merge can silently undo a deprecation, drop a
   `move-entry` repoint, or lose a re-verification — and the result depends on merge direction.
   The only P0 that survived verification. (I-5)
3. **Staleness is keyed on a commit SHA derived by walking history.** Squash merges, rebase
   merges, cherry-picks, reverts and shallow clones all produce false "stale"; a commit can never
   verify itself; pre-commit hooks cannot see the change being committed; and every doc costs its
   own history walks (≈16 ms/doc at 200 commits, 117 s at 4,000 docs × 3,000 commits, ≈23 min
   extrapolated at 30,000 commits). A prototype content-identity check resolves 12,000 refs in
   0.25 s independent of history. (I-1)
4. **This repository's own CI has not run doc-tools since 2026-04-05.** The self-installed
   workflows call `.github/scripts/doc-tools.sh`, which was never committed; the freshness gate
   fails *open* (`stale_count=0`, even with `STRICT=1`) and the index-update workflow has failed on
   every docs push since at least 2026-05-28. The six AI templates cannot do their jobs even after
   GH #5 is fixed (no skill, no tool grants). Since 2026-08-31 **no Actions job has executed at all**
   (each fails in 2–6 s with no runner and no logs), so v2.15.0 merged with its Tests workflow red and
   never run. The cause needs an owner check of Actions billing/settings. (I-8, I-14)
5. **The skill tells agents to call tools in ways that damage the index.** `build-index` (which
   *replaces* the index, and wipes it on empty stdin — the default in an agent's non-TTY shell) is
   the documented remedy for untracked docs; new docs are routed to `update-index` (which rejects
   them and drops the whole batch); archival never uses `move-entry`/`deprecate-entry`; and
   `$DOC_TOOLS` only resolves from the Claude Code plugin cache, so 4 of 5 supported clients get a
   literal glob. (I-11, I-3, I-4)

**The five incorrect foundational assumptions** that explain most clusters:

| # | Assumption | Reality | Clusters |
|---|---|---|---|
| A1 | "The commit that last touched the refs identifies the code a doc was verified against." | SHAs are re-minted by squash/rebase/cherry-pick; shallow clones graft; content identity is what matters. | I-1, I-5, I-8 |
| A2 | "Writing an index entry is verifying the doc." | `build-index`, `add-entry`, `deprecate-entry`, CI and the merge driver all stamp `current`/`last_verified` without anyone reading the doc. | I-3, I-5, I-8 |
| A3 | "There is one writer, it is never interrupted, and the file is always valid JSON." | The skill dispatches parallel agents; traps resume after SIGTERM; `>` truncates; empty reads parse as `{}`. | I-2, I-4 |
| A4 | "The harness contracts are what the author assumed" (`$TOOL_INPUT`, stdout visibility, plugin cache, skill present on CI runners). | Each was contradicted by the upstream source or docs; tests encode the assumption, and the repo's own dogfood install was broken, so nothing surfaced. | I-6, I-8, I-11, I-12, I-13, I-14 |
| A5 | "A prose rule is a guard." ("human reviews diffs", "will not overwrite human edits", "deprecated is terminal", "read-only") | None of these is enforced by code; several are contradicted by the tools. | I-3, I-9, I-11 |

## Phase 0 — Scope & surface discovery

**Target & run-id.** Whole repository at `05ea982` (= `origin/main`, v2.15.0 + one docs commit).
Run-id `05ea982` (first 7 of the tip SHA).

**Taxonomy adaptation.** The sweep-skill's surface taxonomy is written for an iOS/Cloud-Functions/ADK
monorepo; this repo is bash + jq + git tooling, GitHub Actions templates, a prompt layer and
multi-client manifests. Surface-kinds were extended (not replaced): `shell-tool` (≈ `cloud-other`:
floor + concurrency + scaling + security), `ci-workflow` (≈ `terraform`: L-INFRA static-read +
security), `skill-prompt` (≈ `adk-agent`: contract + prompt-injection security + context-cost/evals),
`test`, `manifests` (≈ `other`), `docs`. **L-DATAFLOW was force-run** on the doc-index lifecycle
(chains: create → verify → detect → mutate → merge) with an inline dataflow map.

| Surface | Kind | Files | Lenses (disjoint set) |
|---|---|---|---|
| **S1** doc-tools core (`scripts/doc-tools.sh` 1–1255 + dispatcher) | shell-tool (shared root) | 1 | CORRECTNESS · PERF · DEADCODE-SIMPLIFY · CONCURRENCY · SECURITY · TESTS · DATAFLOW · CONTRACT |
| **S2** doc-tools 1256–2006 (versions, fragments, implementation, vendoring) | shell-tool | (same file) | CORRECTNESS · DEADCODE · SECURITY · CONCURRENCY · TESTS · CONTRACT |
| **S3** merge driver (`scripts/merge-doc-index.sh`) | shell-tool | 1 | CORRECTNESS + TESTS · SECURITY · CONCURRENCY · PERF |
| **S4** installer + state (`scripts/hooks/install.sh`, `state.sh`) | shell-tool (shared root) | 2 | CORRECTNESS · CONTRACT · SECURITY · CONCURRENCY · TESTS |
| **S5** runtime hooks (`scripts/hooks/git/*`, `scripts/hooks/claude/*`, `.claude/**`) | shell-tool | 12 | CORRECTNESS · CONTRACT · SECURITY · PERF · TESTS |
| **S6** CI templates + repo workflows (`scripts/hooks/ci/*.yml`, `.github/workflows/*`) | ci-workflow | 11 | INFRA · SECURITY · CONTRACT · CONCURRENCY · TESTS |
| **S7** per-PR release-notes pipeline (`doc-pr-release*`, `doc-release.yml`) | ci-workflow + shell-tool | 6 | CONTRACT + CORRECTNESS · SECURITY · CONCURRENCY · TESTS |
| **S8** skill prompt layer (`skills/`, `references/`, `evals/`) | skill-prompt | 9 | CONTRACT · CORRECTNESS + DEADCODE + COST-EVAL · SECURITY |
| **S9** test suites (`scripts/test-*.sh`) | test | 6 | TESTS ×2 (incl. harness correctness, 43 mutations) |
| **S10** cross-client packaging (`.claude-plugin`, `.cursor-plugin`, `.codex`, `.opencode`, manifests, `AGENTS.md`, `GEMINI.md`) | manifests | 12 | CONTRACT + CORRECTNESS + DEADCODE |
| **S11** project docs + `docs/.doc-index.json` | docs | 51 | DOCS-DRIFT (+ gate-script `check-freshness`, measured) |
| X (cross-surface) | — | — | CONCURRENCY · DATAFLOW (force-run) · SECURITY (all shipped shell) |

- **All 113 tracked paths resolved to a surface:** yes (the surface map is in the [evidence appendix](2026-09-27-full-repo-05ea982-evidence.md#surface-map)).
- **Fell to the `other` catch-all (listed by name):** `.gitignore` (reviewed: lacks
  `.claude/settings.local.json` — see I-6/I-14), `LICENSE` (MIT — Clean).
- **Shared / rippling roots:** `scripts/doc-tools.sh` → consumed by every hook, every CI template,
  and every SKILL.md action; `scripts/hooks/install.sh` → writes S5/S6 into consumer repos;
  `scripts/merge-doc-index.sh` → every local merge of the index.
- **Not applicable (with reason):** the Swift/iOS lenses (no Swift); L-SCHEMA-RULES (no rules
  files); L-FLAGS (no Remote Config — version sync covered by `check-version`, measured PASS);
  L-FLAG-SEMANTICS (the `DOC_SUPERPOWERS_*` env knobs were examined inside S5 correctness);
  L-OBSERVABILITY (no telemetry sink — its "silent failure" intent is carried by pattern P-A).

## Phase 1 — Baselines (measured)

| Baseline | Result |
|---|---|
| Five shell suites (bash 5.2, Linux) | **696 / 696 pass** — test-doc-tools 253 (54 s), test-hooks 308 (23 s), test-spec-status-model 84, test-doc-pr-release 32, test-merge-driver 19 |
| `check-version` | PASS — 6/6 manifests at v2.15.0 |
| `check-freshness` on this repo's own index | 36 entries: **13 current, 23 stale**, 0 missing, 0 untracked (0.63 s). 21 of the 23 stale are point-in-time records (plans, specs, issues, archived reports) |
| Scaling, synthetic (flat 2,000-file tree, 301 commits) | `git log -1 -- <file>` ≈ 181 ms/call; `build-index` over 2,000 docs **421 s** |
| Scaling, synthetic (nested tree) | 16.1 ms/doc at H=201 (N=100 → 1.7 s, N=400 → 6.5 s); 117 s for N=4,000 at H=3,000; 179 + 161 ms per stable-ref doc at H=30,000 (≈23 min extrapolated for 4,000 docs) |
| Claude Code hook input contract | Fetched docs: input is JSON on **stdin**; env vars are `CLAUDE_PROJECT_DIR`, `CLAUDE_PLUGIN_ROOT`, `CLAUDE_PLUGIN_DATA`, `CLAUDE_EFFORT`; **no `TOOL_INPUT`**; exit-0 stdout of PreToolUse/PostToolUse/Stop goes to the debug log |
| GitHub state | Issues **#5** (AI templates lack `id-token: write`) and **#18** (no verb edits an entry's `code_refs`) open and **unresolved** at HEAD; PR **#16** (issue record: no batch/archive re-key primitive) open, `mergeable_state: dirty` (conflict only in `docs/.doc-index.json`; merges cleanly with the repo's own driver registered — measured) |
| GitHub Actions on this repo | `doc-freshness-pr` run 30534235825 (2026-07-30) reported *success* although the tool was missing (fail-open). `doc-index-update` failed on every executed run through 2026-07-30 (replayed locally: `update-index` rc 1). **From 2026-08-31 onward no job executes:** every run of every workflow (Tests 8–11, both legs; Doc Index Update 19–20; Doc Freshness Check 20; Scheduled 23–26) concludes `failure` in 2–6 s, with log download returning 404 and empty check-run output. The last executed run was 2026-08-24. v2.15.0 (PR #17) merged with Tests red and never run; the bash 3.2 leg last ran on 2026-07-30. The cause is needs-runtime (see I-14). |
| Local open issue records | All four `status: Open` records in `docs/issues/` are still live at HEAD (non-atomic writes; merge driver `version`; `usage()` omits verbs; metadata churn) — the sweep adds new root causes to three of them (see Reconciliation) |

## Phases 2–3 — Verified findings by surface

Format: `[Pn] <file:line> — <root cause> · <level> → <cluster>`. Only findings that survived the
Phase-3 adversarial verifier are listed; the verifier's severity is authoritative. `measured` means
reproduced in a scratch repo (or a deterministic tool verdict); `structural` means a static read;
`needs-runtime` means it needs a real GitHub Actions / client run the audit could not do.

### S1 — doc-tools core (`scripts/doc-tools.sh` 1–1255 + dispatcher)

- [P1] `:177,365,569,743,867` (+ `git/pre-commit:26`, `claude/pre-commit-gate.sh:37`) — freshness keyed on a commit SHA re-derived by history walk: squash → stale (commits_behind 1) while `git rev-parse <stored>:<ref>` equals `HEAD:<ref>`; rebase-merge, cherry-pick, revert, same-commit verification and shallow clones all misjudge; a staged invalidating change reads current. After squash + branch delete the stored commit is *absent* in fresh clones, so only storing ref object IDs fixes it · measured → **I-1**
- [P1] `:564-597,166-207` — every doc pays its own `git log -1` + `git rev-list --count` walks + 7–21 processes; t ≈ 16.1 ms·N at H=201; 117 s at N=4,000/H=3,000 · measured → **I-1**
- [P1] `:311,503` — INT/TERM traps delete the accumulators and **resume**: `build-index` then atomically installs a truncated index with rc 0 (single-pid TERM: 225/300 entries; Ctrl-C-like `timeout -s INT` ignored in 2/5; blocked on stdin under `timeout` → installs an **empty** index); `check-freshness` prints a summary that disagrees with its `.docs` · measured → **I-2**
- [P1] `:511,519,627-640` — `check-freshness` re-implements `compute_freshness` inline and splits `@tsv` records on tab, which is IFS whitespace: any empty middle field (null `code_commit` — the *normal* state for spec-first refs —, null `content_hash`, empty `doc_type`) shifts later fields and reports stale docs as current; refs are glob-expanded; empty refs make `git log` fail silently; `status` disagrees · measured → **I-4**
- [P1] `:316-453` — `build-index` replaces the whole index on zero or partial input (empty stdin → `{}` rc 0; `--help </dev/null` → `{}`; one-line pipe → one key; deprecations reset) · measured → **I-4**
- [P1] `:1111,460-472,1973` — positional-only flags, unknown options accepted: `deprecate-entry <old> --superseded-by <new>` deprecates the **successor**, rc 0; `check-freshness --code-refs=x` / positional paths silently ignored; `remove-entry --help` rewrites the index · measured → **I-4**
- [P1] `:776-787` — `update-index` always writes `status=current`, silently un-deprecating (reached by the documented supersede flow, `spec-lifecycle-actions.md:96 → :116`) · measured → **I-3**
- [P1] `:324-326,363-366,829-831,865-868` — unvalidated `path:refs:type` stdin parser: bare path becomes refs + type; `a, b` stores `" b"` (never matches); CRLF; colons in paths re-key; typo'd refs → null `code_commit` (never stale); duplicate-key policy differs between verbs · measured → **I-4**
- [P1] (X) `SKILL.md:639,373`; `:378-401,878-900,1157` — writers that verify nothing stamp `status=current` + `last_verified=now` (`build-index` re-baselines to HEAD; `add-entry` baselines to HEAD; `deprecate-entry` bumps `last_verified`) · measured → **I-3**
- [P2] `:526-537` — `--code-refs` filter is a raw two-way string prefix (`src/m1` matched 260/400, 40 expected; `''` matches all; C-quoted non-ASCII paths never match) and costs O(N·R·S) in bash · measured → **I-4**
- [P2] `:56,177,…` — every git call ends `2>/dev/null || true`: outside a repo `check-freshness` reports everything current, rc 0 · measured → **I-4**
- [P2] `:193-208,580-597` — `code_refs_changed` compares each ref's last commit to the doc-level SHA (lists untouched refs); null `code_commit` → stale with `commits_behind 0` · measured → **I-1**
- [P2] `:485-488,627-656,694-701,811-814` — index shape never validated; jq on empty input yields empty output: 0-byte index → `check-freshness` rc 0, `add-entry` "Added 1 entry" leaving 1 byte · measured → **I-2**
- [P2] `:701-980,1131-1167` — each write verb re-parses the whole index per path: O(k·N) (update-index 205 ms/doc at N=4,000) · measured → **I-2**
- [P2] `:578-581` — `commits_behind` computed for every *current* doc (always 0; ≈ half the git time) · measured → **I-1**
- [P2] `:511,629-641` — `read -d ''` from a process substitution reads one byte per syscall (73,985 reads for 73,784 B) · measured → **I-1**
- [P2] `:177,365,569,743,867` — porcelain `git log` honours `log.showSignature` → `code_commit: "No signature\n…"` · measured → **I-4**
- [P2] (X) `:384,401,884,900` — stored `current`/`stale` status is dead data (no writer stores `stale`) · structural → **I-3**
- [P2] (X) `:657`; `SKILL.md:335` — point-in-time records carry `code_refs` and go stale by construction (21 of 23 stale entries here) · measured → **I-3**
- [P3] `:712-717` update-index aborts the whole batch on an unknown key → I-4 · `:28-34` `hash_file` breaks on backslash filenames (escaped `sha256sum` output) → I-4 · `:56` unborn HEAD → `build_commit: "HEAD\nunknown"` → I-4 · `:124-129` `docs//a.md` stored as a separate key → I-4 · `:982-985,1169-1172` remove/deprecate report requested targets, not changes → I-4 · `:437,453` index installed mode 0600 → I-2 · `:758-768` `Implementation:` capture reads inside code fences → I-10 · `:371-405,872-904` build-index/add-entry never write `implementation` (10/36 entries have it) → I-3 · `:284,428,429,510` comments that lie ("stubs", absent plan doc, "only test helpers read the field", "add-entry rejects colons") → I-14 · `:281,1970,2004-2005` dispatcher (`--help` rc 1, no "unknown subcommand", help needs jq) → I-4 · (X) `SKILL.md:290`, `doc-spec.md:33` in-doc `date | commit` marker is a second, unread freshness claim → I-3

### S2 — doc-tools 1256–2006 (versions, fragments, implementation, vendoring)

- [P1] `:1665,1684-1687,1699-1706` — `set-implementation` splices `--ref/--note/--status` into `grep -E` and GNU `sed` program text: benign inputs corrupt (`R&D`, `(squash)`, `a|b`, backslashes; `PR: #N` refs can delete the bullet) and a newline in `--note` injects sed `e`/`w` commands (measured file creation/write) · measured → **I-10**
- [P1] `:1702-1706` — create path anchors on `**Date:**`; the shipped ADR/SPEC templates use `**Date**:` / `**Created**:` → rc 0, file byte-identical · measured → **I-10**
- [P1] `:1686-1698,1729-1735` vs `:758-762` — one writer and two readers use different `Implementation:`/`Realized-by:` grammars (Realized-by drops from the index; `[]` appends invisible; appends land inside later code fences; file-global replace) · measured → **I-10**
- [P1] `:1571,1601,1603-1605` — `fragments merge` drops a fragment's last line when it has no trailing newline yet lists it in `--paths-out` (→ `git rm`) · measured → **I-9**
- [P1] `:1565-1605` — merge discards any text not under a `### ` heading and still records the fragment as consumed (a hash-valid heading-less fragment → empty output, no warning) · measured → **I-9**
- [P2] `:40-49,1678-1680` (+ `tests.yml:66-71`) — GNU sed is a dependency for this one verb only · structural → **I-10**
- [P2] `:1363,1572,1539-1545` — headings/markers not trimmed of trailing space/CR (duplicate sections; CRLF fragments fail validate silently) · measured → **I-9**
- [P2] `:1410,1417-1418,1447-1452,1280-1281,1300` — `var=$(cmd|filter)` under errexit+pipefail aborts silently (`fragments list` rc 1 no output; `check-version` rc 2 no output; `bump-version` partial bump then rc 5) · measured → **I-10 / I-9**
- [P2] `:1747-1750` — `implementation-status --filter` broken on every platform and depends on undeclared `rg` (zero callers) · measured → **I-10**
- [P2] `:1593,1620` — fragment dedupe is per *line*, so shared sub-bullets/fence lines vanish from later bullets · measured → **I-9**
- [P2] `:1862-1891` — `tools uninstall` `rm -rf`s user-added files in `doc-pr-release/` and a drifted vendored `doc-tools.sh` · measured → **I-10**
- [P3] `:1275-1337` bump/check-version succeed on 0 files; mode 644→600 → I-10 · `:1300,1958` version = first `## vX.Y.Z` substring anywhere (+ pre-release suffix passes) → I-10 · `:1504-1505` invalid range ref swallowed → I-9 · `:1467-1470,1995` `--paths-out` only as exact 4th arg in `=` form → I-9 · `:1759-1763,1817-1818` `tools install` from the vendored copy fails (`cp: same file`) → I-10 · `:1914-1927,1952-1965` `tools status` from the vendored copy compares the file with itself and reports the consumer's version → I-10 · `:1343-1433` dead branches, O(F²) list rebuild, misleading comments → I-10

### S3 — merge driver (`scripts/merge-doc-index.sh`)

- **[P0]** `:47-53,61,64-65,70-71` — the driver never consults the base (`$base_docs` only feeds `has()`); per key it keeps the whole entry with the newer `last_verified` (tie → `%A`), and a key missing on one side is dropped even if the other side changed it. Measured through real `git merge`/`rebase`/`revert`: (a) deprecate vs update-index → deprecation undone in both directions; (b) `move-entry` repoint + hand-edited refs lost in one merge direction and under `git rebase` (dangling `superseded_by`); (c) reverting a deprecation doesn't revert it; (d) move vs re-verify → re-verification lost; (e) a one-sided change with an older `last_verified` dropped. Docs recommend the lossy direction (`2026-05-04` issue: "rebase … driver resolves silently") and call it "three-way" · measured → **I-5**
- [P2] `scripts/hooks/install.sh:187-190` — driver registered as an unquoted absolute path into the versioned skill dir: a space or a pruned dir → CONFLICT with **no markers**, ours-only content; driver fixes never reach existing installs · measured/structural → **I-5**
- [P2] `:32,55-57,84` — `jq empty` admits 0-byte / `null` / `{}` sides → all base entries deleted with exit 0; a 0-byte ours → `%A` = `"\n"` · measured → **I-5**
- [P2] `scripts/test-merge-driver.sh:17-41,49-157,244-251` — no fixture compares against the base (why the P0 passes 19/19) · structural → **I-13**
- [P3] `:14,39-40,77-83` top-level object rebuilt from a fixed field list (drops `schema_version`; merge-time `build_commit`; wall-clock `generated_at`) → I-5 (known: merge-driver-reads-version) · `:18,76` sorts `.docs` while writers keep insertion order (247+/246- diff for one change per side) → I-5 · `:10-11,27-35` a failing driver leaves `%A` = ours with no markers (header comment claims otherwise) → I-5 · `install.sh:242-248` uninstall leaves a 0-byte `.gitattributes` → I-7 · `test-merge-driver.sh:43-46` BSD `mktemp` suffix, no trap → I-13

### S4 — installer + install state (`scripts/hooks/install.sh`, `state.sh`)

- [P1] `install.sh:335-340,362-365` — Claude-settings ownership = substring `"doc-superpowers"` anywhere in a hook **group**: install and uninstall delete user hook groups, including unrelated hooks in the same group (settings.local.json is untracked → unrecoverable) · measured → **I-7**
- [P1] `install.sh:147-172` — the block spliced into an existing hook is bash-only (`[[: not found` in `#!/bin/sh` hooks), drops `"$@"` (integrated prepare-commit-msg/post-checkout never work) and swallows STRICT; lands after `exec` in pre-commit-framework hooks · measured → **I-7**
- [P1] (SHELL) `install.sh:144,171,181,197-200,304,342,373,486,564-565,589-590,601-603`; `doc-tools.sh:1817-1844`; `state.sh:150-153` — installer and `tools install` write fixed repo-relative paths through committed **symlinks** (`.claude/settings.local.json → global settings`, `.github/scripts/doc-tools.sh → ~/.bashrc`, `.githooks/pre-commit → ~/.bashrc` → persistent code execution) · measured → **I-7**
- [P2] `install.sh:16` + hook line 5 — `__DOC_TOOLS_PARENT__/*/scripts/doc-tools.sh | sort -V | tail -1` runs whichever **sibling** directory's script sorts last (measured code execution from `~/code/<sibling>` in the clone layout); `sort -V` absent on older macOS → every hook no-ops · measured → **I-7**
- [P2] `install.sh:106-126,209-216,293-299,519` — hooks dir and repo root from cwd + guesses: `.githooks/` without `core.hooksPath` (status lies "✓ installed"), literal `~` dir, **global** `core.hooksPath` spliced, worktree/submodule rc 1 aborting `--all`, subdir installs into `packages/web/.github` · measured → **I-7**
- [P2] `install.sh:144,181,304,187-190` — install path interpolated unquoted (a space → every hook silently no-ops; merge driver loses theirs) · measured → **I-7**
- [P2] `install.sh:478-486,541-553`; `state.sh:175-188` — state records "installed" but not the choices: a plain re-install (the upgrade path) flips `STRICT "1"→"0"`, installs 9 workflows, rewrites `installed_at` · measured → **I-7**
- [P2] `install.sh:312-342,358-373` — settings merge crashes on a `type:"prompt"` hook (rc 5 after copying scripts) and "installs" into a 0-byte file · measured → **I-7**
- [P2] `install.sh:136-141` — an integrated hook's local copy is never re-rendered on re-install (release note v2.12.2 claim false for integrated installs) · measured → **I-7**
- [P2] `install.sh:423-428` — default `--ci` installs all 9 workflows, including both AI PR workflows the template says never to combine; help/menu understate · measured → **I-7 / I-8**
- [P2] `install.sh:296-349` — the Claude tier writes wiring into the *personal* `settings.local.json` without git-ignoring it while writing machine-specific scripts into shareable `.claude/hooks/` · measured → **I-7**
- [P3] unescaped `sed` replacements + masked sed failure (`--base-branch 'a|b'` → 0-byte workflow, "1 installed", stuck) · symlinked user hooks de-linked · uninstall of integrated hooks not an inverse · helpers installed when doc-pr-release was skipped · `uninstall --workflows=<typo>` rc 0 · comments promise checks the code doesn't do · uninstall residue · `state_is_valid` syntax-only · unguarded empty array (bash 3.2) · dead `__DOC_TOOLS_PATH__` substitution · exact-string `v1` markers · unescaped install-time values → all **I-7**

### S5 — runtime hooks (`scripts/hooks/git/*`, `scripts/hooks/claude/*`, `.claude/**`)

- [P1] `claude/pre-commit-gate.sh:14-23`, `post-commit-sync.sh:13-22` (+ `.claude/hooks` copies) — read `$TOOL_INPUT` (never set) and the wrong path `.command`: gate and sync **never activate** (measured through the exact settings wrapper) · measured → **I-6**
- [P1] `claude/*.sh` — reports go to stdout (debug log only); STRICT exits 2 with **empty stderr** (blocked without a reason); `session-summary` says "session ending" but Stop fires every turn · measured → **I-6**
- [P1] `git/prepare-commit-msg:7-10,29-39` — appends `#` lines regardless of message source: committed into history with `-m`/`-F`/`--amend --no-edit` (28 of this repo's own commit messages contain them) · measured → **I-6**
- [P2] `git/pre-commit:16-31`, `prepare-commit-msg:15-26`, `claude/pre-commit-gate.sh:29-41` — freshness is evaluated at HEAD, so the commit that makes a doc stale passes and the *next* commit is blocked under STRICT (root cause is I-1) · measured → **I-6 / I-1**
- [P2] `claude/session-summary.sh:16-32,47` — unscoped full walk with a 1 s budget, silent on timeout, ≈1 s added to every turn · measured → **I-6**
- [P2] all hooks — `2>/dev/null) || exit 0` treats "tooling failing" as "tooling absent" (a conflicted index silently disables STRICT) · measured → **I-6**
- [P2] `git/post-merge:18`, `post-checkout:22`, … — `git diff --name-only` without `--no-renames` → the doc citing the *old* path of a moved file is never in scope · measured → **I-6**
- [P2] `claude/post-commit-sync.sh:28`, `session-summary.sh:36-45` — the "auto-refresh" `update-index` with no arguments always exits 1 (swallowed) — dead since the hook was written; must be **removed**, not made to work (a working version would mark every doc verified) · measured → **I-6** (known: metadata-rewrite — its premise is refuted)
- [P2] (SHELL) `install.sh:323-330` — registered Claude hook commands `cd` to the toplevel of the *current* directory and exec a relative path → a nested repo's copy runs; use `$CLAUDE_PROJECT_DIR` · measured (shell level) → **I-6**
- [P2] `.claude/settings.local.json` (tracked) — personal settings committed with `/Users/w/…` paths and broad pre-approvals (`Bash(git push:*)`, `Bash(gh repo:*)`); self-installed hooks pin `/Users/w/code/doc-superpowers/scripts/doc-tools.sh` → this repo's Claude tier is dead on every clone · measured → **I-14**
- [P3] `git/post-merge` reports whole-index `untracked` on every merge · `git/post-checkout:41,49` trailing-comma join · `session-summary.sh:22-29` macOS fallback holds stdout ≥1 s, predictable `/tmp` path · `git/pre-push:5-13` ignores pushed refs, no DOC_TOOLS guard · O(N·F·R) scope filter (4.5 s at N=4,019 × 500 files) · per-Bash-call spawn cost of the Claude hooks (≈17 ms) → all **I-6**

### S6 — CI templates + this repo's workflows

- [P1] `.github/workflows/doc-freshness-pr.yml:51`, `doc-freshness-schedule.yml:33`, `doc-index-update.yml:52` — the self-installed workflows call `.github/scripts/doc-tools.sh`, never committed (since 4727d2f, 2026-04-05) → none has ever run doc-tools here (PR #17 had 20 stale docs under STRICT=1 and passed) · measured → **I-14 / I-8**
- [P1] `ci/doc-index-update.yml:30,52` — passes every changed `docs/` path (the index itself, PNGs, unindexed docs) to `update-index`, which aborts: 12/12 recent main commits replayed → rc 1 · measured → **I-8**
- [P1] `ci/doc-index-update.yml:24-25,52` — `fetch-depth: 2` makes `update-index` record the shallow graft as `code_commit` → permanently stale in full history · measured → **I-8 / I-1**
- [P1] `ci/doc-freshness-schedule.yml:39-44,102-104`, `doc-freshness-pr.yml:29-40,57-62,117-119` — index-sized JSON passed through `$GITHUB_OUTPUT` into a single env var: E2BIG at ≈421 docs (311 B/entry; single env string cap 131,072 B measured for `/bin/true` and node) · measured / needs-runtime → **I-8**
- [P1] six AI templates — no `claude_args`/`plugins`: in agent mode the model has no Bash/Write/MCP and no `/doc-superpowers` skill, so none can do its job even after GH #5; audit-update/full-cycle prompts never say "push" · structural (pinned source) + needs-runtime → **I-8**
- [P2] `doc-freshness-pr.yml:51-55,121-127`, `doc-freshness-schedule.yml:33-37,106-133` — fail-open: a tool failure becomes `stale_count=0`, STRICT passes, the schedule **closes** the tracking issue · measured → **I-8**
- [P2] `doc-index-update.yml:45-52` — "doc edited on main" treated as "doc re-verified" (typo fix clears real staleness) · measured → **I-8 / I-3**
- [P2] `doc-review-pr.yml:16-24,31-33,68-69` — `prompt:` forces agent mode on every comment: `trigger_phrase` is dead; any member comment runs a paid review of the *default branch*; a comment cancels the in-flight PR review (not a security issue — the comment never reaches the model) · structural → **I-8**
- [P2] all six `claude-code-action` steps — known **GH #5**: the proposed `id-token: write` fix swaps in a Claude App installation token scoped server-side (not by `permissions:`), writes it into the origin URL and `GH_TOKEN`, and makes bot pushes re-trigger workflows; `github_token: ${{ github.token }}` fixes #5 without OIDC · structural (pinned source) → **I-8**
- [P2] fork/Dependabot/bot PRs get red checks (no same-repo guard outside doc-pr-release) · path filters hard-coded to this repo's layout · three templates commit to the same PR branch under separate concurrency groups · structural → **I-8**
- [P3] paths-ignore "recursion guard" rationale wrong · changed-file list word-splits/globs; empty list → no filter · report-comment lifecycle (never cleared, first page only, no author check) · `workflow_dispatch` without PR context · dead `DOC_SUPERPOWERS_VERSION` env + unused permission · no `timeout-minutes`/`--max-turns` · `test-doc-pr-release.sh` not on the shared harness · pin comments imprecise (SHAs genuine) · `__BASE_BRANCH__` unvalidated · `workflow_dispatch` on a fork PR resolves the head by name → all **I-8**

### S7 — per-PR release-notes pipeline

- [P1] `doc-tools.sh:1571-1601`; `RELEASE-NOTES.next.README.md:60-61` — the consumer drops lines 1–2 without checking they are markers and drops pre-heading text, yet lists the fragment for deletion (the "required" line-1 marker is checked nowhere in the consumer) · measured → **I-9**
- [P1] `doc-pr-release/commit-and-push.sh:72,62-93` — a human force-push that removes commits between checkout and push is silently undone (fast-forward push *and* the rebase retry; measured a "committed secret" commit restored) — needs a compare-and-swap, not `rebase --onto` · measured → **I-9**
- [P1] `doc-tools.sh:1495-1507`; `SKILL.md:449-481` — "already released" = ancestry of the *oldest* commit touching the fragment, while consumption is recorded by deleting it: a fragment merged after a release branch was cut (tag on main) is never released nor deleted · measured → **I-9**
- [P1] `extract-context.sh:133` — the new-commits range does not exclude the base: after "Update branch", other PRs' commits are copied into this PR's fragment · measured → **I-9**
- [P1] `doc-pr-release.yml:227-236,274-305` — "will not overwrite human edits" and the hash check are enforced only by the LLM; the verify step passes on a rejected push and on a wrong hash · measured → **I-9**
- [P1] `doc-release.yml:33-34` — `!contains(head_commit.message,'[doc-superpowers]')` skips the release job when the branch is cut at a squash commit listing the bot's sync commits (match the exact bot subject instead) · structural/needs-runtime → **I-9**
- [P2] watermark = last commit touching the fragment (mid-run pushes never integrated) · `update-pr-body.sh:58-75,101-117` marker order/fence unchecked (END-before-START deletes human sections) · skipped sentinel still runs later steps (`'' != '0'`) · section vocabulary disagrees across README / prompt / SKILL · no deterministic opt-out / re-seal → all **I-9**
- [P3] paths-ignore rationale → I-9 (dups of S2/CI/SHELL items listed there)

### S8 — skill prompt layer (`SKILL.md`, `references/*.md`, `evals/evals.json`)

- [P1] `SKILL.md:85-94,432,505,580`; `tool-mappings.md:41-43` — `$DOC_TOOLS`, `install.sh` and `references/` resolve only through the Claude Code plugin-cache glob; with no cache the glob stays literal (rc 127) → 4 of 5 supported clients have no tooling despite "full parity" claims · measured → **I-11**
- [P1] `SKILL.md:346-349` — review-pr base detection: `|| echo main` binds to `sed`, so `BASE=""` wherever `origin/HEAD` is unset (this repo; `actions/checkout`) → empty diff → `check-freshness --code-refs` with no args = **no filter** · measured → **I-11**
- [P1] `SKILL.md:291,373,393,428,639`; `spec-lifecycle-actions.md:92,128`; `evals.json:151` — index-write routing predates `add/move/remove/deprecate-entry`: new docs → `update-index` (rejected, batch lost); untracked docs + migrations → `build-index` (replaces the index); archival never re-keys or deprecates; `sync` has no add/remove step · measured → **I-11**
- [P1] `spec-lifecycle-actions.md:127` — spec-generate allows "module names" as `code_refs` → `code_commit` null → spec current forever · measured → **I-11**
- [P1] `SKILL.md:81,158-164,424-427` — discovery (every action but hooks/release) and sync run `uv run scripts/validate_docs.py` from the working tree → `review-pr` on a checked-out PR executes PR-author code · structural → **I-11**
- [P2] update-index un-deprecates vs doc-spec "terminal" · set-implementation anchors vs templates · host project assumed to be doc-superpowers (README synced against SKILL.md actions; mandatory bump of doc-superpowers' own manifests passes vacuously) · release has no commit step before `git tag` · `:amends` landed-check per chunk (false FAILs) · two per-chunk Status writers with different gates · explicit `:constraint` marker lost in injected plans · landed-check grep not section-aware · index semantics misdescribed · `replaces`/`code_refs` writes with no verb (GH #18) · audit→update handoff undefined · v2.15 `:amends`/`--plan` missing from protocol/templates · no data-vs-instructions trust boundary · no secret-handling rule · doc-pr-release trust list incomplete · `--ci` default installs overlapping AI workflows · discovery dumps the full check-freshness JSON into context (~1.25 MB at 4,019 entries) · evals not runnable (13/13 `files: []`) → all **I-11**
- [P3] headless CI commits vs "human reviews diffs" · migration/archival without confirmation · fixed `/tmp` consumed-list path · unquoted caller strings · "read-only" claims contradicted · stale schema table · release underspecified · stale wording/counts, broken anchors, duplicated templates, SKILL.md size (5,949 words; release+hooks = 25%) → all **I-11**

### S9 — test suites

- [P1] `test-hooks.sh:443-601` — Claude hook tests inject `TOOL_INPUT` and assert merged stdout: the correct stdin contract makes 4 assertions **fail**; replacing the registered settings command with `cd /nonexistent` passes 308/308 · measured → **I-13**
- [P1] `test-hooks.sh:810-881` — nothing tests that the Claude tier preserves user hook entries (3 destructive mutations survive) · measured → **I-13**
- [P1] `test-hooks.sh:643-656,705-730,1212-1228` — integrated mode never run the way git runs it · structural → **I-13**
- [P1] `test-hooks.sh:12,639,842` — installed hooks' runtime doc-tools lookup never executed (glob mutation survives) · structural (finder measured) → **I-13**
- [P1] `test-doc-tools.sh:1449-1578,267-282` — add-entry skip-existing guard and update-index re-stamp untested (both mutations survive) · measured → **I-13**
- [P1] `test-doc-tools.sh:141-152` — no check-freshness test on an entry with an empty middle field · measured → **I-13**
- [P1] `test-merge-driver.sh:17-20,139-157` — no tie / one-sided-edit fixture · structural → **I-13**
- [P1] `test-doc-tools.sh:179-263` — no shallow / squash / rebase fixture · structural → **I-13**
- [P2] `test-helpers.sh:91,103` — `echo "$h" | grep -qF` under `pipefail`: SIGPIPE false FAIL 1–2/1000 and **false PASS with the forbidden string present** 0–2/1000; 1–2 of 60 whole-suite runs flake · measured → **I-13**
- [P2] `test-helpers.sh:59-69` — fixtures inherit the caller's git config: with a global `core.hooksPath` the suite **writes into the contributor's real global hooks dir** · measured → **I-13**
- [P2] helpers-installed untested · bash-4 static guard misses 12 planted forms · ours-deleted merge rule untested · one-sided assertions (new production defect: `code_refs_changed` lists untouched refs) · `//` normalization untested · four merge-driver tests cannot fail · negative-path tests silent anyway · placeholder/YAML checks don't test installer output · session-summary timeout path never exercised · dead refresh call unchecked · S2 defect gaps · fixed `/tmp` paths · wall-clock perf guard aborts the suite without a FAIL → all **I-13**
- [P3] `[[ ]]; assert_eq 0 $?` can't record FAIL · INT trap leaves suite running · test-doc-pr-release not on the shared harness · missing YAML parser should SKIP loudly (the parser itself is justified) · no install→uninstall round trip · 6× `sleep 1` + duplicate corpora · version edge cases · `--help` pins · wording-freeze assertions (by design) → all **I-13**

### S10 — cross-client packaging

- [P1, provisional] `.cursor-plugin/INSTALL.md:8` — manual install clones into `~/.cursor/plugins/doc-superpowers`; Cursor's local-plugin location is `~/.cursor/plugins/local/<name>/` · structural (external; vendor site unreachable) → **I-12**
- [P2] `.opencode/plugins/doc-superpowers.js:27-28` — replaces `output.system: string[]` with a string: the tool mappings never reach the model; a later push-style plugin would throw · measured (node simulation vs OpenCode source) → **I-12**
- [P2] `.cursor-plugin/plugin.json:24` — `"skills": "./"` predates the move to `skills/` · structural → **I-12**
- [P2] `tool-mappings.md` + INSTALL files — tool names wrong for OpenCode, Codex, Gemini (e.g. Gemini has `ask_user`, plan mode and subagents); SKILL.md never references the mapping, so nothing delivers it to Codex · measured vs client source → **I-12**
- [P2] `GEMINI.md:1` — imports the whole 45 KB SKILL.md into every Gemini session although the extension's `skills/` dir already exposes it on demand (~11k always-on tokens) · structural → **I-12**
- [P2] "full parity" claims for doc-tools (dup of I-11 resolution) → **I-11**
- [P3] top-level `multi_agent` in the Codex snippet is ignored (it is a `[features]` key, on by default) · `claude-code.json` has no consumer · capability tables duplicated in 5–6 files and drifted · `install.sh:22` version fallback unreachable under `pipefail` → **I-12**

### S11 — project docs + `docs/.doc-index.json`

- [P2] `docs/conventions.md:309-317,331` — status table contradicts the code (update-index un-deprecates; `stale` is never stored; "hash mismatch" wrong) · measured → **I-3 / I-14**
- [P2] `README.md:202`, `codebase-guide.md:58-59`, workflows doc `:384` — docs claim the Claude hooks auto-run update-index; that call has never worked · measured → **I-14**
- [P2] `CLAUDE.md:23-28`, `README.md:291-295`, `codebase-guide.md:21-25,168` — the repo's self-installed CI tier is described as working; it has not run doc-tools since 2026-04-05 · measured → **I-14**
- [P2] `CLAUDE.md:150,152`, workflows doc `:514,527,582`, `codebase-guide.md:342`, `conventions.md:274` — v2.15.0 `:amends` / `spec-verify --plan` missing from agent-facing docs · measured → **I-14**
- [P3] `.claude/hooks/*.sh:5` `/Users/w` pin · three `code_commit` SHAs reachable only from tag v2.12.0 (pre-rebase copies) · point-in-time records = 91% of stale signal (83% excluding two open issues) · archived docs not deprecated · test counts `(68)/680` · GNU sed missing from dependency lists · `.claude/mcp.json` wrong location · C4 PNGs older than their Mermaid · `__DOC_TOOLS_PATH__` named in docs · `tests.yml` missing from trees · `doc_type` mismatch · v2.14.0 `[""]` explanation wrong · INSTALL pin check not followed · "except hooks" wording → all **I-14** (index-content items also feed **I-3**)

### X — cross-surface (concurrency, all-shell security, dataflow)

- [P1] `doc-tools.sh:701+792, 814+918, 949+980, 1018+1089, 1131+1167`; `SKILL.md:374,393` — six writers read-modify-write with **no lock** while the skill's `update` action dispatches one agent per stale doc, each calling `update-index`: 10 parallel runs → 9 of 10 updates lost, all rc 0 · measured → **I-2**
- [P1] same writers — two overlapping truncating `>` writes leave a valid JSON prefix + stale tail: permanently unparsable (6/25 mixed-writer bursts); hooks' `|| exit 0` then disable the gate silently · measured → **I-2** (known: index-write-not-atomic — new trigger)
- [P2] empty read treated as a valid empty index (7/209 racing readers reported stale 0) · three AI templates commit to one branch under separate concurrency groups · mktemp+mv leaves files 0600 and `bump-version` half-applies · `settings.local.json`/vendored script rewritten in place · `tools install` self-copy fails → **I-2 / I-8 / I-10**
- [P3] (SHELL) `code_commit`/tag values reach `git rev-list` as options (`--output=…` truncates a `…..HEAD` file) · index key `-` drains `check-freshness`'s stdin · commit without pathspec · predictable `/tmp` · fragment reader follows symlinks · unquoted glob expansion of refs · unvalidated `PR_NUMBER` → I-4 / I-9 / I-6

## Final phase — Consolidated surface × lens matrix (ranked by weight)

| Rank | Cluster | Sev | Surfaces | Motivating evidence | Issue |
|---|---|---|---|---|---|
| 1 | **I-1 Freshness identity model** (commit SHA + per-doc history walks) | P1 | S1, S5, S6, X | squash/rebase/cherry-pick/revert/shallow false-stale; pre-commit blind; 117 s @ 4k docs; prototype 0.25 s for 12k refs | [I-1](../issues/2026-09-27-sweep-05ea982-I01-freshness-identity-model.md) |
| 2 | **I-5 Merge driver is not three-way** | **P0** | S3 | deprecation undone; repoints lost by merge direction; rebase lossy | [I-5](../issues/2026-09-27-sweep-05ea982-I05-merge-driver-not-three-way.md) |
| 3 | **I-2 Index persistence layer** (signals, atomicity, locking, load validation, O(k·N)) | P1 | S1, S2, X | TERM → truncated/empty index rc 0; 9/10 parallel updates lost; unparsable index from overlapping writes | [I-2](../issues/2026-09-27-sweep-05ea982-I02-index-persistence-layer.md) |
| 4 | **I-6 Claude hook tier + hook semantics** | P1 | S5 | tier never activated; stdout invisible; `#` lines committed; Stop every turn | [I-6](../issues/2026-09-27-sweep-05ea982-I06-claude-hook-tier-and-hook-semantics.md) |
| 5 | **I-8 CI templates** | P1 | S6, S7 | fail-open gate; doc-index-update fails every run + shallow SHAs; E2BIG; AI templates inert; GH #5 fix shape | [I-8](../issues/2026-09-27-sweep-05ea982-I08-ci-templates.md) |
| 6 | **I-11 Skill prompt ↔ tool contract & agent safety** | P1 | S8 | 4/5 clients no tooling; build-index as remedy; review-pr empty BASE; repo script execution | [I-11](../issues/2026-09-27-sweep-05ea982-I11-skill-prompt-tool-contract.md) |
| 7 | **I-4 doc-tools input & CLI robustness** | P1 | S1, S2 | tab-collapse false-current; build-index wipe; successor deprecated; parser | [I-4](../issues/2026-09-27-sweep-05ea982-I04-doc-tools-input-cli-robustness.md) |
| 8 | **I-3 Index semantics** (what is stored, who may attest) | P1 | S1, S11, X | un-deprecation; writers stamp verification; records stale forever; GH #18; PR #16 | [I-3](../issues/2026-09-27-sweep-05ea982-I03-index-semantics.md) |
| 9 | **I-7 Installer ownership, placement, integration, state** | P1 | S4 | user hook groups deleted; symlink write-through; integration block broken; sibling pickup | [I-7](../issues/2026-09-27-sweep-05ea982-I07-installer-ownership-placement-state.md) |
| 10 | **I-9 Release-notes fragment pipeline** | P1 | S7, S2 | fragment content lost yet deleted; force-push undone; never-released fragments | [I-9](../issues/2026-09-27-sweep-05ea982-I09-release-fragment-pipeline.md) |
| 11 | **I-10 Implementation / version / vendoring verbs** | P1 | S2, S10 | set-implementation corruption + sed injection; silent no-op on templates; GNU sed + rg deps | [I-10](../issues/2026-09-27-sweep-05ea982-I10-implementation-version-vendoring-verbs.md) |
| 12 | **I-13 Test-suite fidelity & reliability** | P1 | S9 | suite rejects the correct hook contract; flaky false-PASS; writes into contributor's global hooks | [I-13](../issues/2026-09-27-sweep-05ea982-I13-test-suite-fidelity.md) |
| 13 | **I-12 Cross-client packaging & install docs** | P1 (prov.) / P2 | S10 | Cursor path; OpenCode array bug; wrong tool tables; Gemini double-load | [I-12](../issues/2026-09-27-sweep-05ea982-I12-cross-client-packaging.md) |
| 14 | **I-14 Project docs & self-dogfooding** | P2 | S11, S5, S6 | own CI and own Claude hooks dead; drift in living docs; index hygiene | [I-14](../issues/2026-09-27-sweep-05ea982-I14-docs-and-self-dogfooding.md) |

No cluster is `cross-plane` in the sweep-skill's iOS↔backend sense; the closest analogue is the
**tool ↔ prompt** lockstep (I-3/I-4 ↔ I-11): any change to verb semantics must ship with the matching
SKILL.md/reference edit in the same Task.

### Cross-cutting patterns → cluster mapping

- **P-A Silent success on failure** (`2>/dev/null || true`, `|| exit 0`, `stale_count=0`, rc 0 on 0 files, trap-resume, jq on empty input) → I-2, I-4, I-6, I-8, I-9, I-10
- **P-B Identity by accident** (commit SHA as content identity; substring `"doc-superpowers"` as ownership; `last_verified` as a write clock; oldest touching commit as a release marker; last fragment commit as a watermark) → I-1, I-5, I-7, I-9
- **P-C Duplicated logic drifting** (inline `check-freshness` copy; five writers; three `Implementation:` parsers; two stdin parsers; version regex ×3; capability tables in six files; test counts in three docs) → I-2, I-4, I-10, I-12, I-14
- **P-D Tests assert the author's model, not the runtime contract** (`TOOL_INPUT`; hand-written fixtures; template instead of installed artifact; one-sided assertions; ≥39 surviving mutations) → I-13
- **P-E Dogfooding gap** (own CI never ran doc-tools since 2026-04-05; own Claude hooks pinned to `/Users/w`; so none of I-6/I-8's runtime defects surfaced) → I-14, I-6, I-8
- **P-F Hidden dependencies** (GNU sed, `rg`, `sort -V`; PyYAML/ruby are test-only and justified) → I-10, I-7, I-13
- **P-G Per-item process spawning / O(N·H) walks** (per-doc `git log` + `rev-list`; O(N·R·S) bash filter; O(k·N) writers; byte-at-a-time `read -d`) → I-1, I-2, I-6
- **P-H Prose contracts instead of deterministic guards** ("will not overwrite", "human reviews diffs", "read-only", "deprecated is terminal") → I-9, I-11, I-3

### Remove rather than fix

`scripts/hooks/ci/doc-index-update.yml` (and its self-installed copy + installer entry) ·
the `update-index` calls in `post-commit-sync.sh` and `session-summary.sh` · persisted
`current`/`stale` status values (store only deprecation) · eager `commits_behind` (compute for stale
docs only) · the `date | commit` part of the in-doc marker · `implementation-status --filter` (zero
callers; or rewrite with `grep`) · the dead `__DOC_TOOLS_PATH__` substitution · the unread
`DOC_SUPERPOWERS_VERSION` env · the `@SKILL.md` import in `GEMINI.md` · the undocumented
`DOC_INDEX` hook knob · `gnu_sed()` · the per-turn full walk in the Stop hook ·
`claude-code.json` (after confirming no external registry reads it).

### Dependency audit (the project's zero-dependency principle)

| Dependency | Where | Verdict |
|---|---|---|
| GNU sed | `set-implementation` only (`gnu_sed()`), plus a `brew install gnu-sed` CI step | **Remove** — one awk pass fixes I-10's corruption/injection bugs and drops the dependency |
| ripgrep (`rg`) | `implementation-status --filter` | **Remove** — undeclared, not in `check_deps`, zero callers |
| `sort -V` | hook DOC_TOOLS resolution | **Replace** with a numeric `sort -t. -k1,1n -k2,2n -k3,3n` over version-named dirs only |
| PyYAML / ruby | `test-doc-pr-release.sh` YAML parse | **Keep** (test-only; 6 of 9 templates are parsed nowhere else) — make its absence a loud SKIP |
| `uv` | SKILL.md discovery runs `uv run scripts/validate_docs.py` | Not a dependency of the tool, but an **execution** path of repo code — see I-11 |

## Reconciliation with open GitHub items and tracked issues

| Item | Resolved at HEAD? | What the sweep adds | Owning cluster |
|---|---|---|---|
| **GH #5** AI templates lack `id-token: write` | **No** | The proposed fix is the wrong shape: it swaps in a Claude App token not bounded by `permissions:` and makes bot pushes re-trigger workflows. Pass `github_token: ${{ github.token }}` instead. Even then the templates are inert without `plugins`/`claude_args`. | I-8 |
| **GH #18** no verb edits an entry's `code_refs` | **No** | Also no writer for `replaces`. Should be built on the shared `_index_apply` primitive (I-2) so it is atomic, in-position, batchable. | I-3 |
| **PR #16** issue record: no batch/archive re-key primitive | Merged after the audit (`ae05f65`, 2026-09-27; the index-only conflict was resolved by structural merge). Its record `docs/issues/2026-07-30-no-batch-or-archive-aware-re-key-primitive.md` stays **Open** until T5 | Claims verified. The same `_index_apply` primitive makes Option A (stdin batch `move-entry`) trivial. Option B (`archived_at` verb) conflicts with `docs/conventions.md`'s archive rule (deprecate in place) — decide the archive model first. | I-3 |
| `2026-07-29-index-write-is-not-atomic` | No | Two **new root causes**: the INT/TERM trap resumes (so tmp+mv alone does not protect `build-index`), and concurrent writers corrupt/lose updates with no crash at all (needs a lock). Its per-commit exposure premise (post-commit hook runs `update-index`) is false. The proposed beside-target `mktemp` still yields mode 0600. | I-2 |
| `2026-07-29-merge-driver-reads-version-not-schema-version` | No | Subsumed by the **P0**: the driver is not three-way at all; the fix (start from ours; per-key base comparison) removes the version bug as a side effect. | I-5 |
| `2026-07-29-usage-omits-implementation-verbs` | No | Part of the CLI surface rework (dispatcher + usage generated from one list). | I-4 |
| `2026-05-04-doc-index-metadata-rewrite-on-every-commit` | Partially (update-index no longer rewrites `build_commit`) | Its stated cause is **wrong** — the post-commit hook's `update-index` call has always failed; churn comes from explicit/CI `update-index` and the merge driver's wall-clock `generated_at`. Content identity (I-1) makes identical verifications byte-identical, removing most of the conflict surface. | I-1 / I-5 |

## Dropped by adversarial verification (recorded for honesty)

- "README/getting-started symlink install loads nothing" — **measured false**: the repo root carries `.claude-plugin/plugin.json`, so the symlink loads as a skills-dir plugin (Claude Code 2.1.283). Only the `$DOC_TOOLS` gap remains (I-11).
- "CLAUDE.md/README rewritten without confirmation" as a security finding — documented core behaviour, visible in the diff, no privilege gain.
- "Effective tools/MCP come from the PR's `.claude/settings*.json`" in CI — the pinned action restores `.claude/`, `.mcp.json` etc. from the base branch.
- "Maintainer comment on a fork PR runs an agent over fork content with secrets" — on `issue_comment` the checkout is the default branch and the comment never reaches the model.
- "`/dev/zero` symlink defeats the fragment size cap"; "fragments double up next release" (`--paths-out` form); "`compute_freshness` emits `[""]`"; "four docs are false-stale on real data" (their refs genuinely changed) — each disproved by reproduction.
- `.gitattributes` absent in this repo — deliberate (the repo self-installs only the Claude and CI tiers).
- Every Phase-2 P0 except the merge driver was re-severitied to P1 or lower on evidence (INT/TERM trap, concurrent writers, installer group deletion, symlink write-through, three fragment-pipeline P0s, prompt-side script execution).

## Phase 4 — Coverage attestation

See the attestation block appended below (produced by the Phase-4 completeness critic, a separate
dispatch that read every finder and verifier report).

### Coverage attestation (critic dispatch, then controller follow-up)

**Critic verdict: PASS-WITH-GAPS.** The critic's inputs:
- all 21 Phase-2 finder reports;
- all 12 Phase-3 verifier reports;
- the surface map;
- the controller's coverage matrix.

What the critic confirmed:
- **No-drop:** the surface map equals `git ls-files` exactly (113 paths).
- Every surface received its core lenses, each ending in findings or a `Clean:` line.
- Every finder family reached a verifier.
- The single P0 (I-5) is owned by a cluster.

**Silent skips found by the critic, and how each was closed.** A second-round finder pass,
followed by an adversarial verify, was dispatched for the first five rows:

| Gap (critic) | Closure |
|---|---|
| S4 installer × L-PERF not dispatched | FU2 (measured) → see Follow-up results |
| S4 × L-DEADCODE-SIMPLIFY (no dedicated pass; install.sh 731-778, 853-890; state.sh 1-40, 199-249 uncited) | FU2 |
| S7 × L-PERF not dispatched (per-fragment full-history walk; extract-context on long PRs) | FU1 (measured) |
| Fragment-pipeline test-gap mapping missing (the 8 verified S7/S2 P1s; `test-doc-tools.sh` 989-1044) | FU1 (mutation testing) |
| S5 hooks × bash-3.2 / BSD portability had no Clean line | FU4 (structural; no bash 3.2 in the container). Also checked the `tests.yml` macOS run history via the GitHub API, which led to the CI-not-executing finding in I-14 |
| L-DATAFLOW chain B (verify: `update-index`, `post-commit-sync`, `doc-index-update.yml`) named neither as findings nor as Clean | Not a skip. Chain B produced findings, not a Clean line: writers that stamp verification (I-3), dead `update-index` hook calls (I-6), and `doc-index-update` failing and equating "edited" with "verified" (I-8). The chain map is now recorded here: **A** create (`init`/`sync` → `build-index`/`add-entry`) · **B** verify (`update`/`sync` → `update-index`; the Claude PostToolUse sync; CI `doc-index-update`) · **C** detect (`check-freshness`/`status` ← `audit`, git hooks, the Claude gate, CI freshness) · **D** mutate (`move`/`remove`/`deprecate-entry`) · **E** merge (the driver). A, C, D and E each have a verified `Clean:` line or findings in X-DATAFLOW / V-S1 |
| S5 × L-CONCURRENCY missing from the matrix row | Bookkeeping only. X-CONC covered it: the git hooks are read-only. Recorded |

**Uncited regions, and how each was handled:**
- **Record docs (31 files).** Judged in aggregate as point-in-time records (I-3/I-14). The governing
  design specs were then read individually: FU4 for spec drift, and FU1/FU3 against design intent.
  Plans and issues remain aggregate-only, deliberately: they are historical records, not code
  contracts.
- **`references/doc-spec.md`** (~470 uncited lines of generated-doc templates) and **SKILL.md 49-74
  and 193-260** (the `init` output contract): FU3.
- **`spec-lifecycle-actions.md:1-38` and `spec-lifecycle-protocol.md:1-54`:** FU3 checked them
  against the 2026-07-24 design spec.
- **PNGs:** checked by render date only (I-14 P3).
- **`LICENSE` and `.gitignore`:** controller floor.
- **`package.json` and `gemini-extension.json`:** manifest validity only (S10 Clean line).
- **Positive-path test blocks:** declared Clean by S9a/S9b after mutation testing.

**Items that fell between verifiers.** These are carried forward, marked *unverified*, into their
clusters:
- the Claude hook per-Bash-call spawn cost (I-6 P3);
- the per-fragment `git log --reverse` walk (I-9 P3; FU1 measured it);
- CI gates ignoring `.summary.missing` (I-8 P3);
- no `tests.yml` step diffing the self-installed files against their templates (I-14 P3);
- the doc-index-update PR lifecycle (moot: the template is removed in T9).

**Unowned P0/P1 root causes named by the critic.** The draft cluster map omitted six verified P1
root causes. Each is now named explicitly in its cluster issue:
- installer writes follow committed symlinks → I-7;
- E2BIG from index-sized env vars → I-8;
- `commit-and-push.sh` restores force-pushed-away commits → I-9;
- `extract-context.sh:133` base not excluded → I-9;
- `doc-release.yml` `contains` skip → I-9;
- review-pr `BASE=""` → I-11.

Three were owned only implicitly and are now explicit:
- the `build-index` zero/partial-stdin wipe (tool side) → I-4;
- `fragments merge` last line without a newline → I-9;
- module-name `code_refs` → I-11.

**Reinstated finding.** Controller observation C4 is reinstated: the repo registers no merge driver
and has no `.gitattributes` entry for its own index. V-S3 dropped it with the reason "registration is
per-clone". That reason ignores that the `.gitattributes` line is committed. It is now I-14 P3,
gated on I-5.

**Deviations (declared):**
- **D1** Lens grouping: some small surfaces combined lenses in one dispatch. Accepted: per-lens
  findings and Clean lines were still emitted.
- **D2** Cross-surface lens dispatches: SHELL-SEC, X-CONC and X-DATAFLOW each covered several
  surfaces. Accepted: Clean lines were given per surface.
- **D3** Engine: plain agent dispatch (the Workflow engine was not opted into), with a cap of 20
  concurrent agents. X-DATAFLOW launched after the first finder returned. Process only.
- **D4** No symptoms sidecar, so the blind-finder contract was not mandatory.
  - Domain context listed 7 already-tracked defects as "report only if new". This is a deliberate
    anchoring trade-off for dedup. The `known:` tags carry new root causes, so anchoring did not
    suppress new angles.
  - **Recall on the controller's 13 private observations: 13/13** were found by at least one finder.
    C1 was found independently by 5 finders that never saw the file.
  - **Blindness leak:** one finder (S1-PERF) read the controller-observations file mid-run, after
    independently finding C1. The file was then moved out of reach.
- **D5** Repo hygiene. Two verifiers briefly wrote into the real repo:
  - an untracked `docs/a.md`;
  - `docs/.doc-index.json` overwritten by a fixture.

  Both were reverted. The final tree was verified clean at `05ea982`, with no `merge.*` config and
  no installed hooks. The critic also noted:
  - the S11 verifier's fixture commands landed in other agents' scratch dirs;
  - concurrent suite runs collided on fixed `/tmp` paths. That biases mutants toward being killed,
    so the survivor counts are lower bounds.

  The 23/36-stale figures agree across 4 reports, so there is no sign of contamination.
- **D6** There is no bash 3.2 or BSD userland in the container, so **every portability verdict is
  structural (unmeasured).** The repo's own macOS leg could not substitute: it has not executed
  since 2026-07-30 (see I-14).
- **D7** No front-end plane, so no Phase-1 simulator capture.
- **D8** Needs-runtime items (GitHub Actions semantics, the claude-code-action runtime,
  Cursor/Gemini runtime) were not executed; pinned-source reads were used instead. These P1s are
  labelled **provisional** in their clusters:
  - the AI templates are inert (I-8);
  - `doc-release.yml`'s `contains` check (I-9);
  - the Cursor local-plugin path (I-12).
- **D9** Artifact placement. The skill's default findings path is `docs/reports/audits/`, and it
  tracks work with a ledger row. This repo has neither `docs/reports/` nor ledgers: its convention
  puts audit reports in `docs/plans/` (CLAUDE.md). So the findings index lives in `docs/plans/`, and
  the no-ledger fallback applies: one **local** issue record per cluster in `docs/issues/`, using the
  repo's issue frontmatter plus `cluster-key: sweep-skill:full-repo:I-N` for dedup. **No GitHub
  issues were filed.** That is outward-facing and awaits the owner's decision.

### Follow-up results (FU1–FU4)

The critic's gaps were closed by four follow-up finder passes (FU1–FU4). Each had its own
adversarial verifier (V-FU1–V-FU4). As in Phases 2–3, the verifier's severity is authoritative.
**No follow-up finding survived at P1 or above.** Every proposed P1 was downgraded on evidence.

**Totals:** 8 P2 · 53 P3 · 5 P4 (trivia) kept. The verifiers dropped 48 finder items, as duplicates
of Phase-2/3 findings, superseded history, or refuted.

| Pass | Scope | Kept (P2 / P3 / P4) | Dropped | Headline verified items | Folded into |
|---|---|---|---|---|---|
| **FU1 → V-FU1** | S7 fragment pipeline: L-PERF, L-TESTS (44 mutants), L-CONTRACT vs the 2026-05-12 design plan | 3 / 10 / 0 | 7 | `extract-context.sh:136-147` passes payloads through argv, so the 128 KiB per-argument cap hits (rc 126); the 1 MiB cap is dead code · `fragments merge` O(F×H), 10.46 s at H=5k/F=200 · the proposed one-pass fix is **not** equivalent (renames, merge commits) · release-branch consumption can re-release · first release has no range start · 16 of 17 spot-checked mutants survive | I-9, I-13 |
| **FU2 → V-FU2** | S4 installer: L-PERF, L-DEADCODE-SIMPLIFY | 1 / 17 / 0 | 5 | malformed `installed.json` (the installer's own merge conflict) resurrects intentionally removed workflows · 53 jq / 12 rewrites per `install --ci` (~300 ms of ~390 ms) · write-only state fields, dead `state_dump_ci` · drifted duplicate vendoring · out-of-scope flags ignored · nothing scales with repo size | I-7 |
| **FU3 → V-FU3** | `init` output contract (doc-spec templates, SKILL.md 49-74 / 193-260), Spec Status Model vs its design | 4 / 18 / 0 | 11 | per-chunk Task N+1 still writes exempt-status targets (R3) · no template has a Mermaid-source slot, so `diagram` cannot find generated docs · `init`'s own commit makes its docs stale (and `.` can never stay current) · disagreeing api-contracts/ERD predicates · all 11 Mermaid blocks render | I-11 |
| **FU4 → V-FU4** | S5 hook portability (bash 3.2 / BSD), governing-spec drift | 0 / 8 / 5 | 25 | no bash-4 syntax or empty-array risk in any hook (structural) · the Claude gate misses `git add && git commit` / `commit -am` under STRICT · integration block inserted before every column-0 `exit 0` · `test-spec-status-model.sh:206` vacuous · live schema table says version 1 · 5 of 6 design specs misstate their Status · CI not executing re-severitied **P1 → P3** (only +36 test lines unrun since the last green run) | I-6, I-7, I-11, I-13, I-14 |

**Items still open after the follow-ups:**
- Every portability verdict remains structural until the repo's macOS leg executes again (D6).
- The provisional P1s (D8) still need one real Actions/client run each.
- Plans and issues under `docs/` remain aggregate-only by design.

**Attestation, final: PASS-WITH-GAPS.**
- The gaps are declared in D6 and D8.
- No surface × lens is silently skipped.
- The critic named 6 P1 root causes that the draft cluster map left unnamed; each is now named in
  its cluster issue.
- The single P0 is owned.
