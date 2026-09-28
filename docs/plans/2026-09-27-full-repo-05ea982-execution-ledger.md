---
date: 2026-09-27
status: Draft
type: plan
source: subagent-driven-development
run-id: 05ea982
related-files:
  - docs/plans/2026-09-27-full-repo-05ea982-fix-plan.md
  - docs/plans/2026-09-27-full-repo-05ea982-jumping-off-point.md
---

# Sweep 05ea982 — execution ledger (copy)

> Verbatim copy of the controller ledger (`.superpowers/sdd/2026-09-27-full-repo-05ea982-fix-plan/progress.md`,
> git-ignored), committed so execution can resume from any checkout. Agent ids are session-local and
> meaningless elsewhere. The live ledger stays authoritative while a session is running; re-copy it at
> each pause.

```text
# SDD ledger — plan: docs/plans/2026-09-27-full-repo-05ea982-fix-plan.md

Branch: claude/resume-plan-execution-03646c (fast-forwarded to origin/claude/affectionate-turing-tu1o9x @ b59375f)
Branch start (MERGE_BASE for final review): b59375f
Specs: plan `governing_specs` (5 design specs under docs/superpowers/specs/) + cluster issues docs/issues/2026-09-27-sweep-05ea982-I*.md
Baseline (b59375f): all five suites green under /opt/homebrew/bin/bash 5.3.9 AND /bin/bash 3.2.57 — 696/696 each (baseline.txt)

## Pre-flight

Ruling: CI gate (Gotcha 1) — Actions blocked by account billing lock ("The job was not started because your account is locked due to a billing issue", Tests run on main 2026-09-27). User chose: proceed, verify locally under /bin/bash 3.2.57 AND bash 5.x per Task; CI confirmation pending owner action — cost if wrong: a Linux-only (GNU userland) regression slips until CI returns.
Ruling: scope — user chose whole plan T1–T14.

### Conflict scan

| Pair / Task | Shared file / interface | Finding | Ruling |
|---|---|---|---|
| Execution Handoff vs SDD skill | parallel worktrees for T6/T7/T8/T10/T11 | SDD forbids parallel implementers; T10+T11 both edit doc-tools.sh + test-doc-tools.sh; T6+T8 both edit install.sh | see R1 |
| T8 ↔ T11 | `doc-tools.sh tools …` vendoring | T8 2b: "delegate vendoring only after T11 fixes tools uninstall" — plan's list order puts T8 before T11 | see R2 |
| T6 ↔ T8 | install.sh merge-driver registration (install.sh:187-190) | T6 changes registration; T8 rewrites installer + re-registers | serial T6 → T8; T8 must keep T6's registration form |
| T9 ↔ T8, T7 | installer default `--ci` set; hook output | plan: T9 after T7+T8 | honoured |
| T1 ↔ T9/T10 | doc-pr-release.yml / doc-release.yml inline `run:` bodies | T1 2b extracts them into testable helpers; T9/T10 later edit the templates | see R3 |
| T1 ↔ T14 | .github/workflows/tests.yml | T1 enforces YAML parser in CI; T14 adds self-install diff step | additive, no conflict |
| T4 ↔ T12 | references/doc-spec.md schema table (:857-869) | T12 2b says "as part of T4 Step 3" | see R4 |
| T3 ↔ T7/T9 | `--code-refs-from <file|->`, `--tree` (T4) | consumers in T7/T9 | interfaces fixed by T3/T4; carry names verbatim |
| T2 ↔ T5 | `_index_apply` | T5 set-code-refs + batch move-entry built on it | serial |
| T4 ↔ T5 | code_oids re-derivation in set-code-refs | serial | ok |
| T3–T5,T7,T10,T11 ↔ T12 | SKILL.md / references lockstep edits | T12 revisits the prompt layer after | serial; T12 must preserve earlier lockstep edits |
| T13 ↔ T14 | claude-code.json removal → bump-version VERSION_FILES, CLAUDE.md "6 manifest files" | T13 removes; T14 fixes living docs | T13 updates VERSION_FILES + its test fixture; T14 sweeps prose |
| T9 ↔ T14 | this repo's .github/workflows/doc-index-update.yml | T9 says remove "this repo's copy"; .github is T14's file | T9 removes it (plan text explicit) |
| all ↔ Global "Versioning" | manifests + RELEASE-NOTES | per-task bumps vs one v3.0.0 | see R5 |
| T1 self | test for 64 KB haystack false-PASS "loop until it does, bounded" | red test is probabilistic by nature | accept: bounded loop; the red evidence may be a statistical run |
| T2 self | Step 1 (b) uses `timeout 1` | `timeout` absent on stock macOS (Gotcha 6); gnubin masks it locally | see R6 |
| T3 self | "outside a git repo every verb exits non-zero" vs `--help` exits 0 | tension for non-git verbs (--help, check-version, bump-version, tools) | see R7 |
| T4 self | "Keep writing code_commit" vs "Writers refuse to record code_commit in a shallow repository" | consistent: shallow → code_commit null, OIDs still written | ok |
| T5 self | record docs never stale vs T14 "record docs get empty code_refs via set-code-refs" | both; T5 is reader rule, T14 is hygiene | ok |
| T6 self | consistent | — | ok |
| T7 self | "Stop hook: scope … or move to SessionEnd" | either/or left open | implementer picks, documents |
| T8 self | "Claude tier per-user OR team-shared — pick one" | open decision | see R8 |
| T9 self | consistent | — | ok |
| T10 self | consistent | — | ok |
| T11 self | "delete implementation-status --filter (or reimplement)" | open | implementer picks; must not use rg |
| T12 self | consistent (big) | — | ok |
| T13 self | "remove claude-code.json once no external consumer is found" | cannot search externals exhaustively | see R9 |
| T14 self | Close-out update-index on real repo vs Gotcha 2 | Gotcha 2 is about *testing*; close-out on real repo is intended | ok |

R1 Ruling: run T6, T7, T11, T8, T9, T10 sequentially in this worktree (no parallel worktrees) — SDD forbids parallel implementers and T10/T11 and T6/T8 share files — cost if wrong: slower wall-clock only.
R2 Ruling: order after T5 is T6 → T7 → T11 → T8 → T9 → T10 → T12 → T13 → T14, so T8 can delegate vendoring to the fixed `tools` verbs — cost if wrong: none functional; plan explicitly allows any order among T6/T7/T8/T10/T11.
R3 Ruling: T1 extracts the inline `run:` bodies into helper scripts under scripts/hooks/ci/ (templates call them); T9/T10 edit those helpers rather than re-inlining — cost if wrong: helper file layout rework in T9/T10.
R4 Ruling: T4 Step 3 corrects the doc-spec.md schema table (incl. the T12 2b item); T12 only verifies it — cost if wrong: small doc edit in T12.
R5 Ruling: no intermediate version bumps; one v3.0.0 RELEASE-NOTES entry + `bump-version 3.0.0` + `check-version` at the end of T14 (branch merges as a unit) — cost if wrong: user wanted split releases; easy to re-split notes.
R6 Ruling: T2's interruption tests use a portable bash kill-after helper (background + sleep + kill), never `timeout` — cost if wrong: none.
R7 Ruling: verbs that read/write the index or query git exit non-zero outside a repo; `--help`/`help` exit 0 anywhere; check-version/bump-version/tools keep working outside git only if they don't call git — cost if wrong: minor contract tweak.
R8 Ruling: Claude tier = per-user (settings.local.json + info/exclude), hook commands via "$CLAUDE_PROJECT_DIR" — matches current settings.local.json choice and T14's "untrack .claude/settings.local.json" — cost if wrong: switching to team-shared later means moving entries to settings.json.
R9 Ruling: T13 removes claude-code.json if repo-wide + README/INSTALL/marketplace search finds no consumer; record the search in the report — cost if wrong: an unknown external consumer loses the file; restorable from git.

## Tasks
T1 BASE=b59375f
Baseline BSD-PATH (/usr/bin:/bin:/opt/homebrew/bin) + /bin/bash: 696/696
Task 1: dispatched implementer (opus) agent a1847ab0cccec10af
Task 1: implementer DONE_WITH_CONCERNS — commit 8630c5b; 813 assertions, 810 pass + 3 known-bug markers (both bashes + BSD PATH)
Task 1: routed known bug → T4: check-freshness spawns 3 jq per stale entry (process-count guard marked known; enforce N+c in T4)
Task 1: routed known bug → T10: extract-context leaks base-branch commits into new_commits after "Update branch" merge
Task 1: routed known bug → T10: commit-and-push.sh sweeps pre-staged files into its commit
Task 1: routed → T10: doc-tools fragment mutants not re-run in T1
Task 1: note → T8: install.sh now ships .github/scripts/doc-release/; `tools install --with-helpers` does not yet (T8/T11 vendoring)
Task 1: task review dispatched (opus) agent acd7861ffdc1e28dc on b59375f..8630c5b
Task 1: review → Needs fixes (5 Important): --helpers=false ships broken doc-release.yml; 2 XFAIL markers can mask regressions; test-doc-tools tolerant captures don't assert rc; resolve-auth.sh duplicated; I-13 fragment mutants have no owner
Ruling: I-13 V-FU1 doc-tools fragment mutants (7) are owned by T10 — implementer records owner in I-13 Resolution; controller carries list into T10 dispatch — cost if wrong: T10 scope grows slightly
Task 1: minor (deferred): update-index >/dev/null at set -e sites abort w/o FAIL line (test-doc-tools.sh:324,342,357,894,908,939,1387)
Task 1: minor (deferred): test_workflow_helper_wiring can pass vacuously; step=$(jq…) not tolerant (test-doc-pr-release.sh:968,974)
Task 1: minor (deferred): perf wall-clock budget raised 60→120s (test-doc-tools.sh:776)
Task 1: minor (deferred): assert_json_field folds jq stderr into value (test-helpers.sh:238)
Task 1: minor (deferred): install.sh doc-release copy/remove blocks duplicate doc-pr-release ones; state.sh doesn't track doc-release helpers; tools --with-helpers doesn't ship them (→T8/T11)
Task 1: minor (deferred): step bodies now run from PR-head checkout incl. secret-bearing step — needs RELEASE-NOTES line (→ v3.0.0 notes, T14)
Task 1: minor (deferred): global-hooksPath test covers setup() only, not source-time isolation
Task 1: minor (deferred): bash-4 guard patterns `read -N` and `printf .*%(` broad (false-positive risk)
Task 1: minor (deferred): doc-tools suite +10s (1000-probe self-test); test-doc-pr-release.sh ~1044 lines
Task 1: fix round 1 implementer done — commit 3bccb8a; step scripts → scripts/hooks/ci/doc-superpowers-steps/ (one resolve-auth.sh); 825 assertions 822 pass + 3 XFAIL pinned
Task 1: fix round 1/5 (4 addressed, 1 open — #1 partial: doc-pr-release.yml still broken under --helpers=false (update-pr-body/commit-and-push/extract-context gated) and the new wiring test skips asserting it; commits 8630c5b..3bccb8a)
Ruling: install --ci with --helpers=false and a selected workflow whose steps need gated helpers (doc-pr-release) must refuse (exit ≠0, clear message, nothing written) rather than ship helpers anyway — preserves --helpers meaning, turns a silent broken install into a loud error; T8 may redesign flags — cost if wrong: a user relying on --helpers=false + doc-pr-release now gets an error instead of a broken workflow
Task 1: minor (deferred): tools install --with-helpers and state.sh helpers tracking don't cover doc-superpowers-steps/ (→T8/T11)
Task 1: fix round 2 implementer done — commit 184daa7 (refuse --helpers=false + doc-pr-release; README example changed)
Task 1: fix round 2/5 (1 addressed, 0 open; commits 3bccb8a..184daa7)
Task 1: minor (deferred → T8): --helpers=false refusal uses raw --workflows set, not state-aware (refuses even when doc-pr-release intentionally uninstalled); undocumented
Task 1: complete (commits b59375f..184daa7, review clean) — suites now 840 assertions (3 XFAIL pinned)
T2 BASE=184daa7
Task 2: dispatched implementer (opus) agent a975ae11c26fef9eb
USER DIRECTIVE (2026-09-27): after ALL fixes are in (T1–T14 + final whole-branch review fixes) and BEFORE the release flow, run `/doc-superpowers audit`, then `update`, then `diagram` (via the doc-superpowers skill, using this branch's fixed tools). Only then do the release.
Ruling: R5 amended — T14 does NOT bump version or write the v3.0.0 RELEASE-NOTES entry; sequence at end = T14 → final review + fix wave → doc-superpowers audit → update → diagram → release flow (`/doc-superpowers release` draft + bump-version 3.0.0 + check-version) — per user directive — cost if wrong: none (user-specified order).
Task 2: implementer DONE_WITH_CONCERNS — commit c74f578; 936 assertions 0 fail 3 XFAIL (both bashes; doc-tools BSD PATH); update-index 50 docs/4k index 9.2–18.5s → 0.32–0.41s
Ruling: the installed prepare-commit-msg hook (in the shared .git/hooks) injects `# stale:` lines into -m commit messages (the I-6 bug T7 fixes). T1 commits 8630c5b/3bccb8a/184daa7 carry 19–22 such lines. All later commits use `git commit --cleanup=strip`; T1 messages get cleaned in one msg-filter pass over the local, unpushed branch at the end, before finishing — cost if wrong: SHAs in this ledger for T1 go stale (recoverable via reflog; ledger note on rewrite)
Task 2: concern → T4: shape validation adds 1 jq to check-freshness (1508 vs ceiling 1520); perf test 86s/120s under load
Task 2: concern → T6: merge driver writes index without the lock
Task 2: concern → T5: deprecate-entry still stamps last_verified
Task 2: task review dispatched (opus) agent a70ce5bb5d92df732 on 184daa7..c74f578
Task 2: review → Needs fixes (1 Important): INT/TERM during lock acquisition leaves pid-less lock that wedges all writers (doc-tools.sh:416-417, :391-392); no test signals a lock holder
Task 2: ⚠️ resolved by controller as real gap: `--args`/`$ARGS.positional` + NUL-framed `jq -Rs` input raise the jq floor; no jq minimum documented anywhere → joins fix loop
Task 2: minor (deferred): kill -0 treats EPERM as dead → breaks a live other-user lock (doc-tools.sh:435; use ps -p)
Task 2: minor (deferred): duplicate targets double-counted in remove/deprecate/update reports (:1401,:1581,:1258)
Task 2: minor (deferred): INT covered only statically; add set -m subshell test
Task 2: minor (deferred): I-02 issue "Related" section stale (says 2026-07-29 issue still open)
Task 2: minor (deferred): docs/.doc-index.json.lock / .tmp.* not gitignored
Task 2: minor (deferred): SKILL.md:137 "safe to run concurrently" overstates build-index (last-writer-wins)
Task 2: minor (deferred → T5): "Unchanged" report sections rarely appear because last_verified re-stamped
Task 2: minor (deferred → T4): check-freshness TERM test precondition (400 entries > 0.5s) will break once T4 speeds it up
Task 2: minor (deferred): stress test (d) runs 6s not 10s
Task 2: fix round 1 implementer done — commit 1d295c6 (deferred-signal acquire; jq>=1.6 gate; NUL-free jq -R input); 964 assertions 0 fail 3 XFAIL
Task 2: fix round 1/5 (2 addressed, 0 open; commits c74f578..1d295c6)
Task 2: minor (deferred → T4 scaling): rec_fields jq decoder is O(k²) (`.out += [...]` in reduce, doc-tools.sh:354) — 40k fields 4s; linear version given in re-review (recurse/slice form)
Task 2: minor (deferred): residual Ctrl-C window closable via `(trap '' INT TERM; exec mkdir "$INDEX_LOCK")`
Task 2: minor (deferred): diagnostic mkdir&&rmdir probe (:526) can die with reasonless "cannot create lock"; timeout msg says "held by running pid N" when .lock.break is stuck (:536)
Task 2: minor (deferred → T14): docs/conventions.md:153 jq line lacks version floor
Task 2: minor (deferred → T7): git hooks run check-freshness 2>/dev/null || exit 0 → jq-floor gate message never surfaces
Task 2: minor (deferred): newline-containing keys reported missing by check-freshness; _index_changed_has newline-framed set can false-match (reports only)
Task 2: complete (commits 184daa7..1d295c6, review clean)
T3 BASE=1d295c6
Task 3: dispatched implementer (opus) agent a1fd81e99c57efa96 (carries deferred T2 minor: dedupe targets)
Task 3: implementer DONE_WITH_CONCERNS — commit 37be531; 1122 assertions/interpreter 0 fail 2 XFAIL (T10); BSD doc-tools 563/563; check-freshness jq spawns 1509→4 (T4 XFAIL flipped to plain assert, budget 10)
Ruling: usage errors (unknown flag/verb, no subcommand, repo verb outside git) exit 2, matching existing `fragments merge` convention; R7's "non-zero" satisfied — cost if wrong: scripts checking `== 1` for these cases break (none found in repo per implementer)
Task 3: concern → T4: T2 per-key report loops quadratic (4k keys: 34s bash5 / 109s bash3.2)
Task 3: concern → T7/T9: hooks/CI still pass argv lists; switch to --code-refs-from -
Task 3: concern → T10: fragments merge uses porcelain git log
Task 3: note → T12: spec-generate step 8 changed update-index→add-entry for new specs; keep it
Task 3: task review dispatched (opus) agent a166fb8502e18013c on 1d295c6..37be531
Task 3: review → Needs fixes (2 Important): colon-in-path lines with ≤3 fields still re-key (docs/a:b.md → key docs/a) while SKILL.md:143 claims rejection; build-index TERM test (test-doc-tools.sh:2254) timing-dependent — likely fails on Linux
Ruling: Minor 3 (unquoted `for s in $spec` glob-expands `code-refs-from=*`, doc-tools.sh:1244,1269) and Minor 5 (arity errors exit 1 vs 2) folded into fix round 1 — same lines the implementer just wrote, trivial, and Minor 3 is a real misparse; loop not extended by them — cost if wrong: slightly larger fix diff
Ruling: glob-looking code_refs (Minor 4) — decision deferred to T4 because content identity (`<tree>:<ref>` OIDs) cannot represent globs; T4 must define it (recommended: refs are literal paths/dirs, git run with --literal-pathspecs, warn on glob-looking refs, legacy glob refs fall back to commit logic) and document in doc-spec.md — cost if wrong: users with glob refs see changed staleness
Task 3: minor (deferred): legacy un-normalized keys (docs//x.md, -…) unaddressable after arg normalization (:224) — raw-key fallback or migration
Task 3: minor (deferred): _warn_unmatched_refs uses git ls-files without -z → false warnings for paths with " \ tab (:1459)
Task 3: minor (deferred → v3 notes): one unreadable doc now aborts whole check-freshness via _hash_one→_die (:60) — undocumented behaviour change
Task 3: fix round 1 implementer done — commit 15b3109; 1156/interp 0 fail 2 XFAIL; BSD 597/597
Task 3: fix round 1/5 (4 addressed, 0 open; commits 37be531..15b3109)
Task 3: complete (commits 1d295c6..15b3109, review clean)
T4 BASE=15b3109
Task 4: dispatched implementer (opus) agent a843f892317ecf09c (carries: glob-ref ruling, quadratic report loops, R4 schema table, legacy coexistence)
Task 4: implementer DONE_WITH_CONCERNS — commit c3cf36c; 1243/interp 0 fail 2 XFAIL; check-freshness 2000 docs×503 commits 43s→1.1s (b5), 61s→1.7s (b3.2); repo stale 32→26
Ruling: bash-3.2 fatal `set -u` error exits 0 (EXIT trap sees $?=0) — real silent-success bug in T2's trap layer; carried into T5 dispatch as a must-fix with a test (T5 edits doc-tools.sh next) — cost if wrong: T5 scope grows slightly
Task 4: concern → T6: current merge driver drops schema_version, writes version: 0
Task 4: concern → T7: hooks/CI still check at HEAD; switch to --tree "$(git write-tree)"
Task 4: note: writers still one git rev-list per distinct ref set for code_commit (display only)
Task 4: note: submodule refs never stale; refs outside sparse cone recorded missing (uncovered)
Task 4: task review dispatched (opus) agent a98e1094bd49852bd on 15b3109..c3cf36c
Task 4: review → Needs fixes (2 Important): git add -A captures untracked files under refs → doc stale forever while warning/SKILL.md:143/doc-spec.md:853/doc-tools.sh:1590 claim "recorded missing"; submodule gitlink refs answer missing → never stale (regression vs legacy)
Ruling: Minor 3 (commits_behind masked 0 when code_commit present but not ancestor) is a brief violation ("never a masked 0") → folded into fix round as spec gap; Minor 4 (real index stores pre-amend code_commit 51c7b74) and Minor 5 (getting-started.md:58 lockstep line) folded in as trivial — cost if wrong: none
Task 4: minor (deferred): scale-test budgets thin (update-index 14s vs quadratic 20s on b3.2; check-freshness ≤4s vs 1.7s) — prefer ratio assertion
Task 4: minor (deferred): _wt_stage fallback re-adds all refs one by one when one path refused (:477-483); pre-filter via check-ignore --stdin -z
Task 4: minor (deferred): commits_behind overcounts for `.`/`docs/` refs (counts index-only commits) — display only
Task 4: minor (deferred): doc-spec.md:867 content_hash null also after build-index
Task 4: fix round 1 implementer done — commits 3dba137 (code/tests/docs), 6818e19 (index re-record); 1259/interp 0 fail 2 XFAIL; repo 27 stale/28 current
Task 4: fix round 1/5 (5 addressed, 1 open — new N-1: empty / all-ignored dirs misclassified as present-untracked (ls-files -o --directory w/o --no-empty-directory; U suppressed on -e) → false "reads stale" warning, true "recorded missing" warning lost; commits c3cf36c..6818e19)
Task 4: minor (deferred → T14): codebase-guide.md:237 freshness description omits merge-base/ls-tree steps; doc-spec.md:869 + conventions.md:312 code_oids rows omit submodule commit oid
Task 4: minor (deferred): untracked-path warning printed once per run without naming owning doc
Task 4: fix round 2 implementer done — commit eb7a3ce; 1267/interp 0 fail 2 XFAIL
Task 4: fix round 2/5 (2 addressed, 0 open; commits 6818e19..eb7a3ce)
Task 4: minor (deferred): update-index uses _entry_facts 0 → "recorded missing" warning never fires on update-index (only build/add)
Task 4: complete (commits 15b3109..eb7a3ce, review clean)
T5 BASE=eb7a3ce
Task 5: dispatched implementer (opus) agent ae7b7ed38d3e50599 (carries: bash-3.2 set -u exit-0 must-fix; add-entry baseline = doc's last-commit tree; honest Unchanged report)
Task 5: implementer DONE_WITH_CONCERNS — commits f770ade, cdc86a3; 1381/interp 0 fail 2 XFAIL; repo stale 31→8
Task 5: INCIDENT — fixture ran in worktree (rm→trash alias + failed cd chain), 7 junk commits (311228c), implementer `git reset --hard eb7a3ce` on unpushed branch. Controller verified: clean tree, no docs/k or src, index 55 keys none junk, no local/worktree config pollution; branch = eb7a3ce+f770ade+cdc86a3
Task 5: concern → T14: 6 design specs typed `spec` not `design-spec` → still stale (8 stale; 2 genuine living); retype in T14 index hygiene
Task 5: concern → T6: merge driver must handle entries with no status and null last_verified
Task 5: task review dispatched (opus) agent a79d1faeb828445fb on eb7a3ce..cdc86a3
Task 5: review → Needs fixes (1 Important): set-code-refs on legacy (no code_oids) entry never a no-op and re-baselines kept refs to doc's last commit → verified doc turns stale (doc-tools.sh:3153-3167); 46/55 repo entries legacy
Ruling: flagged choices (a) never-committed doc → worktree baseline, (b) build-index same baseline as add-entry, (c) record docs commits_behind null — accepted (reviewer agrees); (d) keep code_commit on set-code-refs — accepted only with Minor 1 fix: when refs are added, record _FACT_COMMIT[0] so commits_behind never under-counts (masked-0 contract); folded into fix round with Minor 2 (conventions.md:323-326,:360 lockstep) — cost if wrong: commits_behind may over-count after set-code-refs (display only)
Task 5: minor (deferred): _doc_commits walks full history under index lock, no early stop (:712) → lock-timeout risk on long histories
Task 5: minor (deferred): _INDEX_CHANGED unused/incomplete; Repointed report `done < <(jq …)` swallows jq failure (:3056); --refs a,a stores dup ref; no batch-swap test
Task 5: note → T12: references/spec-lifecycle-actions.md:249 "Refine code_refs" should name set-code-refs
Task 5: fix round 1 BLOCKED — abundance-worktrees volume (disk7s1) unmounted ~09:52; controller found it remounted, uncommitted edits intact (6 files M); resuming implementer
Task 5: fix round 1 BLOCKED again — volume unmounted ~10:03; remounted by 10:04; both interpreters had passed 1397/interp 0 fail before drop
Task 5: third unmount during BSD leg; fix round committed 8158440 before drop; user repaired cable 10:34 — resuming
Task 5: fix round 1 implementer done — commit 8158440; 1397/interp 0 fail 2 XFAIL; BSD doc-tools 838 merge-driver 19; repo stale 10 (living docs left unattested)
Task 5: fix round 1/5 (F1, F3 addressed; F2 partially — new Important: re-derived _FACT_COMMIT[0] can be NEWER than stored code_commit → kept ref's changes between them uncounted → masked 0 regression (doc committed after code moved, before re-verify); commits cdc86a3..8158440)
Ruling: amended my earlier F2 ruling (it was the defect) — on a mixed baseline record the OLDER of the two: `git merge-base <stored cc> <FC>` when stored is usable; stored unusable but a kept v3 ref keeps its recorded id → record null (commits_behind reads null); FC only when every ref is on the doc baseline — cost if wrong: commits_behind over-counts (display only)
Task 5: minor (deferred): conventions.md:313 nits (code_commit also changes on kept-ref-without-record; wrong cross-ref); ref-order significance documented only in doc-spec
Task 5: minor (deferred): _entry_facts warns on unmatched refs for pure reorder; kept legacy glob ref silently becomes literal missing; no-op doesn't repair missing code_oids key; --help Freshness text (:1901) lacks kept-ref exception; no test for legacy kept ref absent from code_commit tree
Task 5: fix round 2 implementer done — commit 5b81c02; 1405/interp 0 fail 2 XFAIL; BSD 846/19
Task 5: fix round 2/5 (named repros fixed; 1 open — divergent: stored cc present but not ancestor of HEAD (index-only cherry-pick) → mixed merge-base yields masked 0; commits 8158440..5b81c02)
Ruling: "usable stored code_commit" = valid oid AND a commit in this repo AND `merge-base --is-ancestor cc HEAD`; otherwise mixed → null. Wording minors (--help/doc-spec "every ref is new" → "every ref's content from the doc's last commit"; conventions.md:333 "newest commit touching refs"; non-commit object in null list; two stale test messages) folded into round 3 — same lines — cost if wrong: none
Task 5: fix round 3 implementer done — commit 16050ba; 1412/interp 0 fail 2 XFAIL; BSD 853/19
Task 5: fix round 3/5 (1 addressed, 0 open; commits 5b81c02..16050ba)
Task 5: minor (deferred): conventions.md "usable record" undefined near :313/:328 (two meanings); SKILL.md null list incomplete; --is-ancestor 2>/dev/null swallows git errors; doc-tools.sh:389 header phrase; doc-spec Freshness "(for a new ref)"
Task 5: DEFERRED-IMPORTANT (final wave): readers can still show masked commits_behind 0 — update-index captured uncommitted content, index-only commit, then checkout → check-freshness stale|0 (contradicts "never masked 0" in conventions/doc-spec). Suggested: stale && count==0 → null
Task 5: complete (commits eb7a3ce..16050ba, review clean after 3 rounds)
T6 BASE=16050ba
Task 6: dispatched implementer (opus) agent a6c9c5e24fea51dc3 (carries: schema_version drop, lock question, null last_verified, legacy status normalization, quoted registration)
Task 6: implementer DONE_WITH_CONCERNS — commit 63fd1c5; merge-driver 19→394 assertions; 1785/interp 0 fail 2 XFAIL; BSD merge-driver+hooks green
Task 6: decisions: no lock (driver writes only git's %A); registration = quoted command resolving newest installed version at merge time (or checkout's own copy); verification fields (content_hash, code_oids, code_commit, last_verified) merged as one unit; tie → ours
Task 6: concern → T8: existing installs keep old registration until re-install (status now warns)
Task 6: concern → T14: 3 legacy non-ancestor code_commits; stale suite counts in docs
Task 6: task review dispatched (opus) agent a9a008ffcb9c5a7cf on 16050ba..63fd1c5
Task 6: review → Needs fixes (1 Important): same-field ties (non-verifying verbs never write last_verified → always tie) silently resolve to ours → direction-dependent loss (set-code-refs both sides; move-entry vs deprecate superseded_by)
Ruling: choices (b) verification-unit merge, (c) no lock, (d) merge-time resolution — accepted (reviewer agrees). Same-field non-verification ties → conflict (exit 1 + markers naming key/field); verification unit on a tie → conflict too unless both sides' units are equal (symmetric) — cost if wrong: occasional conflict a human must resolve instead of silent loss
Ruling: minors folded into round 1 (same file): test :470 mislabel/reverse direction; INT/TERM/HUP during write leaves %A partial w/o markers (merge-doc-index.sh:77,:221); doc-tools.sh:3080 "a merge does not undo it" comment — cost if wrong: none
Task 6: minor (deferred → T14): docs/superpowers/specs/2026-03-13-workflow-hooks-harness-design.md:728 still describes old newest-wins design — add superseded pointer
Task 6: note → T8: git hooks installed into a path with quotes break via sed substitution at install.sh:234
Task 6: minor (deferred): jq 1.6 never executed (read-only compat check)
Task 6: fix round 1 interrupted — implementer hit API session limit (reset 13:50); resumed 14:16 with uncommitted edits to merge-doc-index.sh + test-merge-driver.sh
Task 6: fix round 1 implementer done — commit e0a6526; merge-driver 486; 1877/interp 0 fail 2 XFAIL; BSD merge-driver 486 hooks 345
Ruling: same-second re-verifies with identical content but different code_commit conflict (code_commit is in the verification unit) — accepted as fail-safe and rare — cost if wrong: a rare manual conflict resolution
Task 6: fix round 1/5 (4 addressed, 0 open; commits 63fd1c5..e0a6526)
Task 6: minor (deferred): cp "$OURS" "$KEEP" killed mid-copy → truncated ours hunk (merge-doc-index.sh:155-156; assign KEEP after cp)
Task 6: minor (deferred): "same in every direction, merge or rebase" (system-overview.md:159, 2026-05-04 :233) overstates — replay can differ; say "for a given pair of commits"
Task 6: minor (deferred): set-implementation wrongly listed among tying verbs (driver header :30, I-5 Resolution)
Task 6: minor (deferred): assert_ways_conflict doesn't check ls-files -u (test-merge-driver.sh:147)
Task 6: note (docs): two branches deprecating different docs → same successor now conflict on successor.replaces — worth a doc line
Task 6: complete (commits 16050ba..e0a6526, review clean)
T7 BASE=e0a6526
Task 7: dispatched implementer (opus) agent ac67dc5595ba64d1a (carries: jq-gate stderr visibility, --tree/--code-refs-from consumers, Gotcha 3/4, defer -a to git pre-commit)
Task 7: implementer DONE_WITH_CONCERNS — commit f68c978; hooks 345→457; 1989/interp 0 fail 2 XFAIL; BSD hooks 457
Task 7: decisions: Stop kept (ctx7: SessionEnd output reaches no one); Claude gate defers staging commits (add&&commit, -a) to git pre-commit, warns when git tier absent
Task 7: note → T8: $CLAUDE_PROJECT_DIR command strings; integration block must pass "$@", stdin, stderr, exit code
Task 7: note → T14: repo's own .git/hooks & .claude/hooks still old copies; getting-started + 4 design specs stale in scope
Task 7: task review dispatched (opus) agent a9bcd185932516012 on e0a6526..f68c978
Task 7: review → Needs fixes (3 Important): Stop timeout race (rc=143 wd_alive → false "failing", 2/10 on b5); commit regex unanchored (plan-mandated verbatim) blocks non-commits under STRICT; pre-commit reads working-tree doc-index not staged → STRICT bypass when index unstaged
Ruling: regex (plan-mandated) — replace with command-position-anchored form from review (spec intent is gating commits; brief's regex was a sketch); add negative tests; update workflows doc — cost if wrong: an exotic commit form not gated by Claude tier (git tier still gates)
Ruling: `check-freshness --tree T` evaluates a consistent snapshot: code refs, the doc-index, and any doc content it compares all come from T (index via `T:docs/.doc-index.json`); if T lacks the index file, fall back to the working copy with one stderr note; lockstep docs; fix lives in doc-tools, done in T7 — cost if wrong: CI --tree HEAD semantics shift (reads committed index, which is what CI has anyway)
Ruling: minors folded into round 1: workflows doc broken table (:329-341); Stop's porcelain diff rewrites .git/index (compute scope under GIT_INDEX_FILE copy); QUIET+STRICT exit 2 with empty stderr; post-commit-sync read -d '' → $(cat); test gaps (.git/index byte check, negative regex tests) — cost if wrong: none
Task 7: minor (deferred): pre-push/post-checkout tests run template not real push/installed hook; --amend with nothing staged not re-checked; no pre-merge-commit hook for clean --no-ff merges; Stop add -A leaves unreachable objects
Task 7: note → T8: integration block `bash "$DOC_SP_HOOK" 2>/dev/null || true` drops args/stdin/exit/stderr; gate's deferral probe grep counts chained hook as working
Task 7: fix round 1 implementer done — commit 0c31a8e; 2052/interp 0 fail 2 XFAIL; timeout race 6/20 → 0/20 (both interps)
USER (2026-09-27 ~pm): find a stopping point; commit + push what's done; user switching accounts. Stopping after T7 re-review; no new dispatches.
Ruling: R-msg amended — do NOT rewrite T1 commit messages (msg-filter). Rewriting would change every SHA from 8630c5b on and orphan the code_commit values recorded in docs/.doc-index.json (T4 minor-4 class). Cost: 3 T1 commits keep noisy `# stale:` body lines (cosmetic; vanish on squash-merge).
Task 7: fix round 1/5 (7 addressed, 0 open; commits f68c978..0c31a8e) — reviewer re-ran suites: hooks 502, doc-tools 871, spec-status 86 both bashes
Task 7: minor (deferred): under --tree, hooks print "missing from disk" + remove/move advice for a staged-index-without-doc case; should say "missing from this commit (git add it …)" — Claude reads it as feedback under STRICT
Task 7: minor (deferred): regex (then|do|else) lacks word boundary ("undo git commit" matches); false negatives (git --no-pager commit, env X=1, time, if, !, `commit;`) fail safe to git tier
Task 7: minor (deferred): pre-commit scope misses commit staging only the index (new entry) without the doc; re_stages unanchored; no-jq fallback regex over-captures
Task 7: minor (deferred): report/gate comment wrongly claims split index can't be copied (not reproducible)
Task 7: complete (commits e0a6526..0c31a8e, review clean)
PAUSE POINT: T1–T7 complete. Next: T11 (per R2 order T11 → T8 → T9 → T10 → T12 → T13 → T14), then final review, then audit/update/diagram, then release.
```
