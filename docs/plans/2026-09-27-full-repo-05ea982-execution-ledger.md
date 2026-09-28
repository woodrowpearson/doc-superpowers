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

````text
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
PAUSED: handoff commit 1070fb1 pushed to origin/claude/resume-plan-execution-03646c (no PR opened). Resume at T11.
RESUMED (new session, 2026-09-27): branch head 1070fb1 clean; CI still billing-locked (no runs since 06:49Z) — pre-flight CI ruling stands.
T11 BASE=1070fb1
Task 11: dispatched implementer (opus) agent a6dbb76b0963fc6c4 (carries: T1 helper-vendoring minors, file-mode preservation, --filter choice)
Task 11: implementer DONE_WITH_CONCERNS — commit a9a1e8a; 2228/interp 0 fail 2 XFAIL; BSD doc-tools 1041 merge-driver 486 hooks 506 (1 flaky first run, see minor)
Task 11: concern (brief deviation) — newline in --ref/--note refused (exit 2, nothing written) instead of written literally; awaiting review before ruling
Task 11: concern → T8: `tools install --with-helpers` ships both helper dirs always (install.sh ships per-workflow); `tools uninstall` keeps a vendored copy from an older plugin version (no longer cmp-equal); new `tools version` verb used by install.sh:22 (fallback now `unknown`, was `2.0.0`)
Task 11: concern → T10: I-10 fragment items (fragments list silent abort, O(F²) list rebuild, dead helper branches)
Task 11: note → v3.0.0 notes: implementation-status --filter deleted; set-implementation refuses symlinked docs
Task 11: minor (deferred → final wave): T7 hooks test $SECONDS timing check flaky under load (`took 2s`, `test 2 -lt 2`) — failed once on BSD leg, 5/5 alone
Task 11: task review dispatched on 1070fb1..a9a1e8a
Task 11: task reviewer (opus) agent ad97f870a7fdb3238; implementer agent a6dbb76b0963fc6c4 (resume for fix rounds 1-3)
Task 11: review → Needs fixes (1 Important): `tools install` no longer restores +x on existing files (_tools_copy → _replace_file keeps old mode; base did chmod +x unconditionally) — CI templates exec these directly; T8 will route install --ci through this verb
Ruling: T11 newline in --ref/--note refused (exit 2, nothing written) instead of written literally — a raw line break cannot live in a one-line bullet without breaking the block grammar; the brief's binding intent (literal text, nothing executes) is met and tested — cost if wrong: multi-line notes impossible (they never parsed correctly before either)
Ruling: T11 awk constructs (`[[][]]`, `sub(/^ ? ? ?/…)`, `exit` in END, ENVIRON) verified only under BWK awk; no gawk/mawk/docker locally — fold into round 1: rewrite ambiguous bracket/regex forms to unambiguous POSIX forms (escaped `\[`/`\]` or index()); Linux-leg confirmation stays a CI-return item — cost if wrong: set-implementation/update-index misparse on Linux runners until CI catches it
Ruling: T11 fragment items (fragments list silent abort, O(F²) rebuild, dead helper branches) appended to task-10-brief.md so they are not lost with I-10 Resolved — cost if wrong: none
Ruling: T11 minors folded into round 1 (same verbs, small): #2 duplicate ref replaced twice; #3 accumulator flush/join duplicated in update-index awk and _AWK_IMPL_READ (the brief's "one grammar"); #4 _TOOLS_ROOT dirname fork at load; #5 install.sh:27 version lookup prints ERROR during a successful install when RELEASE-NOTES.md missing; #6 tools status counts user-added *.sh as "differ"; #8 `Implementation: [ ]` not recognised as empty → second block; #9 grammar docs say unindented line ends block but column-0 `- ` bullets are items; #10 tests for #1/#2/bump-version failure-path tmp cleanup/PR #1 vs #10 prefix/status drift count — cost if wrong: slightly larger fix diff
Task 11: minor (deferred): CRLF docs get LF-only inserted lines (mixed endings)
Task 11: minor (deferred → T14): system-overview.md:66 "15 subcommands" + CLAUDE.md counts stale after `tools version`
Task 11: fix round 1 → resume implementer a6dbb76b0963fc6c4 (FIX_BASE=a9a1e8a)
Task 11: SendMessage resume failed (no transcript — session persistence off via inherited CLAUDE_CODE_CHILD_SESSION); fix rounds use fresh implementers with brief + report + findings file
Task 11: fix round 1 dispatched (opus, fresh) agent aaf5451467fd6c916; findings file task-11-fix-round-1.md
RESUMED (new top-level session ab7d4105, 2026-09-27 20:25): prior controller + fix-round-1 implementer aaf5451467fd6c916 gone; implementer left UNCOMMITTED edits (9 files, last write 19:59:33), no fix report appended. Draft saved to task-11-fix-round-1-interrupted.patch. Session persistence now on (CLAUDE_CODE_CHILD_SESSION absent from launch env).
Ruling: T11 fix round 1 continues as a fresh implementer on top of the uncommitted draft (audit each finding against it, finish, test, commit) rather than reverting to a9a1e8a — the draft is the same round's work and is preserved as a patch — cost if wrong: a half-finished edit in the draft slips through; the scoped re-review covers the whole a9a1e8a..HEAD range
Task 11: fix round 1 re-dispatched (opus, fresh, on top of draft) agent a1daf1c0701a43c77; FIX_BASE=a9a1e8a
Task 11: fix round 1 implementer done — commit 71eceb2; draft kept (1-6, 8-10 found correct), #11 awk rewrites + new mutation-checked test; both interps 0 fail (doc-tools 1081, hooks 511, spec 86, pr-release 107+2 XFAIL, merge 486); BSD doc-tools 1081 hooks 511
Task 11: re-review dispatched on review-a9a1e8a..71eceb2.diff
Task 11: note → T14: CLAUDE.md suite counts stale (doc-tools 1081, hooks 511 after T11 r1); I14 issue :116 "GNU sed missing from dependency lists" now moot
Task 11: note → T12: SKILL.md:419 tells the agent to run `rg -l '```mermaid' docs/` (agent-side, not a script dep)
Task 11: note → v3.0.0 notes: see task-11-report.md "Concerns / hand-offs" (behaviour changes list)
Task 11: fix round 1/5 (10 addressed, 0 open; commits a9a1e8a..71eceb2)
Task 11: minor (deferred): grammar docs' new end rule "any other line ends the block" is false for an indented line between header and first entry (classified inner; block continues) — doc-spec.md:263, doc-tools.sh:2097-2098,:4112-4114, I-10 issue :116-117
Task 11: minor (deferred): test-doc-tools.sh:5297 (and :5286) `-name '*.XXXXXX'` alternative can never match (mktemp replaced the X's); `.*.json.*` does the work
Task 11: minor (deferred): doc-tools.sh:4126 comment says POSIX classes "fine" in mawk — mawk 1.3.3 lacks [[:space:]] (CI's 1.3.4 fine; pre-existing usage)
Task 11: complete (commits 1070fb1..71eceb2, review clean)
T8 BASE=71eceb2
Task 8: dispatched implementer (opus) agent ac7a0f45118da8afb (carries task-8-carry.md: R8 per-user, T1/T6/T7/T11 hand-offs)
Task 8: implementer DONE_WITH_CONCERNS — commit 1ab0557; both interps 0 fail (doc-tools 1099, hooks 805, spec 86, pr-release 107+2 XFAIL, merge 486); BSD hooks/doc-tools/merge green; RED 220 hooks + 13 doc-tools
Ruling: T8 integration block placed once right after the shebang (brief Step 2) not "before the final exit 0" (Step 2b) — the two brief lines conflict; after-shebang is the Step-2 design, runs even when the host hook ends in `exec` or exits early, and still inserts exactly once — cost if wrong: our hook runs before the user's hook instead of after (ordering; stdin-consuming hooks like pre-push share one stdin either way — reviewer to check)
Ruling: T8 edits to earlier-task tests accepted pending review (T1 --helpers=false refusal test uses --workflows=all after the default-set change; T1 install message now from `tools install`; T7 gate-probe test installs from a version-named plugin copy) — contracts kept, fixtures follow the brief's new defaults — cost if wrong: a weakened earlier assertion; task review checks each
Task 8: concern → T9: remove doc-index-update from the default set; add retired-workflows cleanup
Task 8: concern → T12: agent-side `sort -V` still in SKILL.md discovery
Task 8: concern → T14: tracked .claude/settings.local.json; stale workflow-hooks.png; CLAUDE.md suite counts; 4 docs stamped verified by update-index though only installer passages were reviewed (re-attest in T14 audit)
Task 8: note: `tools install|uninstall` gained `--helper <dir>` (per-workflow helpers)
Task 8: task review dispatched on review-71eceb2..1ab0557.diff (342 KB)
Task 8: review → Approved, spec ✅ (0 Critical, 0 Important, 11 Minor); placement ruling judged sound (args, pre-push stdin fan-out via tmp, stderr, exit, once, uninstall); T1/T7 test edits: contracts kept, none weakened
Task 8: ⚠️ resolved: CI matrix (ubuntu/macOS) unverifiable — CI billing-locked; CI-return item
Task 8: ⚠️ resolved → deferred minor: hooks_path_scope fallback for git < 2.26 (exit 129 → --local compare) untested
Task 8: ⚠️ resolved: Cursor sets CLAUDE_PROJECT_DIR ("Alias for project dir (Claude compatibility)", always present — cursor.com/docs third-party hooks via ctx7) → not a gap; Cursor docs only name .claude/settings.json, so whether Cursor loads settings.local.json is unverified — pre-existing claim in .cursor-plugin/INSTALL.md (gotcha 11 Cursor path) → T14/final
Task 8: minor (deferred): uninstall --git refused under global core.hooksPath with install-worded message; no guidance to remove hooks the pre-3.0 installer put there or in unconfigured .githooks/ (install.sh:516-527,:1515)
Task 8: minor (deferred): --helpers inert except refusal; help text implies --helpers=true ships helpers (install.sh:1137,:144; SKILL.md:562)
Task 8: minor (deferred): strip_blocks adds trailing newline to a host hook lacking one; CRLF shebang host reported "not a shell script" (install.sh:371,:562)
Task 8: minor (deferred): install_ci runs vendor_sync (may tools uninstall helpers) before state_flush — letter of 2b (install.sh:1225-1226)
Task 8: minor (deferred): corrupt-state recovery only for plain install; --workflows=all reinstalls removed templates; SKILL.md:575 unqualified (install.sh:1101)
Task 8: minor (deferred): no up-front jq check — missing jq reported as unreadable installed.json with advice to move it aside (state.sh:90, install.sh:1039)
Task 8: minor (deferred): after-shebang block → our pre-commit runs before user's hook (formatters/lint-staged re-staging judged on pre-fix tree); document (install.sh:535)
Task 8: minor (deferred): safe_dest (install.sh:245) / _tools_no_link (doc-tools.sh:4466) near-verbatim link walks; file_mode duplicated (doc-tools.sh:1492) — add cross-ref comments
Task 8: minor (deferred): status shows ✓ integrated for non-executable host (git skips it) (install.sh:741)
Task 8: minor (deferred): test name test_install_ci_malformed_state_file_falls_back_with_warn asserts a refusal (test-hooks.sh:2280)
Task 8: minor (deferred): install.sh 1032→1549 lines; consider sourced lib for safe-write/marked-block helpers; workflow-hooks.png stale (→T14)
Task 8: complete (commits 71eceb2..1ab0557, review clean)
T9 BASE=1ab0557
Task 9: dispatched implementer (opus) agent a73eb899314490e6f (carries task-9-carry.md)
Task 9: implementer DONE_WITH_CONCERNS — commit 5c1be11; both interps 0 fail (doc-tools 1099, hooks 843, spec 86, pr-release 231+2 XFAIL, merge 486); BSD hooks/pr-release/doc-tools green; check-version PASS; RED hooks 19, pr-release 105
Task 9: choice — plugin pin: prepare-agent.sh clones tag v<version> to $RUNNER_TEMP, local path to plugin_marketplaces (pinned action requires .git URL, no tag); DOC_SUPERPOWERS_VERSION kept (read by that step). Path filters dropped from AI templates; in-job `freshness-check.sh scope` via check-freshness --code-refs-from
Task 9: concern → CI-return: plugin install from local marketplace, --allowedTools patterns, tag-mode checkout, PR creation with job token need one real Actions run; I-8 "one real run per template" left unticked
Task 9: concern → release (T14/v3.0.0): AI templates install plugin from tag v<version> — tag v3.0.0 must exist on GitHub at release
Task 9: concern → T10: SKILL.md release step 9 `xargs … git rm` refused by doc-release's --allowedTools (see task-9-report.md T10 hand-off)
Task 9: task review dispatched on review-1ab0557..5c1be11.diff (309 KB)
Task 9: review → Needs fixes (2 Important): commit-changes.sh:167 `git add -A --pathspec-from-file` dies on a staged `git rm` deletion → doc-release can never commit consumed fragments; shared write group (plan-mandated) with default queue:single cancels other writers' pending runs → latest push never audited
Ruling: T9 shared write group kept (brief-mandated) + `queue: max` on the three groups (docs.github.com workflow-syntax, verified via ctx7: ≤100 pending FIFO, invalid only with cancel-in-progress:true) + YAML comment for GHES without queue support; a queued run whose checkout SHA is no longer the tip exits 0 "superseded" in commit-changes.sh (no commit/push), commit-and-push.sh CAS left to T10 — cost if wrong: GHES consumers lacking `queue` get a workflow validation error until they drop the key
Ruling: T9 ⚠️ "upsert … (including '0 stale')" read as: an existing comment is updated to "no stale or missing docs"; no new comment on a clean PR — fixes the issue's complaint (report never cleared) without noise — cost if wrong: clean PRs get no positive confirmation comment
Ruling: T9 minors folded into round 1 (same file/task, small): agent-writable checker → run from pre-agent copy + git -c core.hooksPath=/dev/null -c core.fsmonitor=false; --ignore trailing-slash; install.sh retired-workflow loop written twice (:1093/:1323) — cost if wrong: slightly larger fix diff
Task 9: ⚠️ → CI-return: claude-code-action@1eddb33 tag mode merging --allowedTools with its own tools and checking out PR branch under contents:read; Skill-tool /doc-superpowers invocation under claude -p and Bash prefix rules; whether the action writes files into the workspace (commit-changes.sh would refuse → every run fails closed)
Task 9: minor (deferred): doc-release.yml:108 --allow manifest list duplicates VERSION_FILES (doc-tools.sh:3684) — matches today; drift fails closed
Task 9: minor (deferred → T14): .github/workflows/tests.yml:79 says "nine CI templates" (now eight)
Task 9: note → T10: doc-release stays unable to consume fragments until T10 fixes SKILL.md:501 xargs form (with round-1 #1)
Task 9: fix round 1 → resume implementer a73eb899314490e6f (FIX_BASE=5c1be11); findings file task-9-fix-round-1.md
Task 9: fix round 1 implementer done — commit ecdeeb1; both interps 0 fail (doc-tools 1099, hooks 843, spec 86, pr-release 254+2 XFAIL, merge 486); BSD hooks/pr-release green; RED 22 on 5c1be11
Task 9: concern → T10: a stale queued pr-release run still reaches commit-and-push.sh rebase-retry; T10's CAS should make it a clean exit (append to task-10-carry)
Task 9: concern (deferred → final): other executable .git/config settings (filter drivers) planted by the agent are still honoured by the checker's git calls (git must read .git/config for checkout credentials)
Task 9: re-review round 1 dispatched on review-5c1be11..ecdeeb1.diff, with named risk: superseded exit assumes a newer run exists, but GITHUB_TOKEN pushes trigger no runs; doc-audit-update checks out the event SHA (no ref:) — a queued audit behind a pr-release bot push may exit superseded with nothing covering the user push (controller ruling may be wrong)
Task 9: fix round 1/5 (4 addressed, 1 open — #2 superseded exit discards doc-audit-update's work: it checks out event sha, GITHUB_TOKEN bot pushes start no covering run → latest push silently unaudited; commits 5c1be11..ecdeeb1)
Ruling (amends T9 round-1 superseded ruling): every write template checks out the branch (audit-update `ref: ${{ github.ref_name }}`); commit-changes claims superseded only when head..tip holds a non-`[doc-superpowers]` commit, else ::error:: exit 1; notice says what happened (no "a newer run covers it"), docs lockstep — my round-1 ruling assumed every tip move triggers a newer run, false for GITHUB_TOKEN pushes — cost if wrong: a run that only saw bot commits goes red instead of green (visible, re-runnable)
Ruling: T9 out-of-scope security observation (agent with Edit/Write + Bash(.github/scripts/doc-tools.sh:*) can run arbitrary code, rewrite the checker snapshot, push with the persisted credential) — accepted as the design: the security ceiling is the job token's `permissions:` (listed in the SKILL.md consent table); the snapshot/-c flags are an integrity check against agent mistakes, not a sandbox; round 2 rewords any text implying a boundary; no new sandboxing — cost if wrong: a prompt-injected agent can push arbitrary content within the token's permissions (true before T9 as well) → flag for final review
Ruling: T9 round-2 folded minors (same lines): err inside $(remote_tip) swallowed; usage() --ignore text; prepare-agent-before-check-only order test — cost if wrong: none
Task 9: minor (deferred): superseded check runs after the agent (stale queued runs spend a full agent run) — moot once writers check out the branch tip
Task 9: minor (deferred): doc-release re-run: release-notes-<run_id> branch exists → --open-pr fails exit 1; error remedy "allow it" cannot succeed on a re-run (not a regression)
Task 9: note → T10: pr-release queued behind itself — pr-release(P1) rebase-pushes F atop P2, pr-release(P2) hits sentinel-check and skips; P2's changes can be missing from the fragment
Task 9: fix round 2 → resume implementer a73eb899314490e6f (FIX_BASE=ecdeeb1); findings file task-9-fix-round-2.md
Task 9: fix round 2 implementer done — commit 5d5f8aa; both interps 0 fail (doc-tools 1099, hooks 843, spec 86, pr-release 266+2 XFAIL, merge 486); BSD hooks/pr-release green; RED 8 on ecdeeb1
Task 9: re-review round 2 dispatched on review-ecdeeb1..5d5f8aa.diff
Task 9: fix round 2/5 (1 addressed + 4 folded addressed, 0 open; commits ecdeeb1..5d5f8aa)
Task 9: minor (deferred): ambiguous push (accepted remotely, client confirmation lost) now hard-fails via moved() since the run's own commit is `[doc-superpowers]` (commit-changes.sh:248-253) — loud, safe
Task 9: minor (deferred): `[doc-superpowers]` subject prefix spoofable by a branch writer → forced CI failure (nuisance), never a silent bypass
Task 9: note → T14: check-freshness reports 9 stale docs (system-overview, codebase-guide, getting-started, 6 design specs) — pre-existing, for the T14 audit
Task 9: complete (commits 1ab0557..5d5f8aa, review clean)
T10 BASE=5d5f8aa
Task 10: dispatched implementer (opus) agent a5a965129f8c71b47 (carries task-10-carry.md items 1-5)
Task 10: implementer interrupted by session restart (~03:09); uncommitted edits in doc-tools.sh, commit-changes.sh, test-doc-pr-release.sh, test-doc-tools.sh, no report; draft saved to task-10-interrupted.patch; resuming same agent via SendMessage (transcript persisted)
Task 10: implementer DONE_WITH_CONCERNS — commit a917d6a; both interps 0 fail (doc-tools 1181, hooks 843, spec 86, pr-release 352, merge 486); BSD doc-tools/pr-release/hooks green; check-version PASS; 0 XFAIL left (both T10 XFAILs converted)
Ruling: T10 earlier-contract changes accepted pending review (all brief-mandated): T1 rebase-retry test → "superseded"; verify-fragment requires a sealed fragment; doc-release `if:` exact subject match; `Bash(git rm:*)` dropped from doc-release tools, SKILL uses new `fragments merge --remove` — cost if wrong: a weakened earlier assertion; task review checks each
Task 10: concern: "release commit reaches main" enforced by `fragments merge` + doc-release precheck; cannot catch a tag placed before its own release commit — docs state "tag the release commit" as a rule
Task 10: concern → CI-return: agent Bash permission matching for `fragments merge … --remove`; exact `head_commit.message` forms GitHub produces
Task 10: task review dispatched on review-5d5f8aa..a917d6a.diff
Task 10: note → T14: CLAUDE.md suite counts (doc-tools 1181, pr-release 352, no XFAIL); README CI paragraph could mention "release commit must reach main"; update-index attested 6 docs of which only release/fragment passages were reviewed — re-attest in T14 audit
Task 10: note → T12: appended to task-12-carry.md item 4 (release steps, fragments merge --remove, CI paragraphs)
Task 10: note → v3.0.0 notes: task-10-report.md "v3.0.0 release-note behaviour changes"
Task 10: review → Needs fixes (3 Important): update-pr-body unclosed fence → appends a section every run (probe-verified); consumer drops prose/unindented-continuation lines silently (column-0 = new unit; probe-verified), --remove then deletes the only copy; hash-line rule in 4 copies (trimmed/sha256 x2 + inline, glob vs awk regex disagree on '>'), fence parser verbatim in doc-tools.sh + update-pr-body.sh. Spec ✅ otherwise; carry 1-5 ✅; earlier-contract changes legitimate; both XFAILs now real asserts
Ruling: T10 fence-parser duplication — doc-tools.sh is vendored as one self-contained file, so it may keep its own copy with cross-ref comments + a shared-fixture test; the three CI helpers share one sourced library — cost if wrong: two fence parsers remain (pinned by a common test)
Ruling: T10 minors folded into round 1: fragments merge exit 1 overloaded (refusal vs _die) → distinct refusal exit code, precheck/SKILL match it; rejected-push path fixtures — cost if wrong: slightly larger fix diff
Task 10: minor (deferred): fragments merge ignores uncommitted fragment edits (reads <range-end> blobs); surfaces only at --remove after drafting — warn at merge time
Task 10: minor (deferred → final/T14): wall-clock guard `check-freshness took 5s … (< 5 s)` flaky under parallel load (cf. T11 $SECONDS flake)
Task 10: ⚠️ → CI-return: claude-code-action prefix match on `…fragments merge <s> HEAD --remove`; GitHub squash/merge subjects; --force-with-lease against GitHub
Task 10: fix round 1 → resume implementer a5a965129f8c71b47 (FIX_BASE=a917d6a); findings file task-10-fix-round-1.md
Task 10: fix round 1 implementer done — commit 888dfd7; both interps 0 fail (doc-tools 1186, hooks 843, spec 86, pr-release 406, merge 486); BSD doc-tools/pr-release/hooks green; RED doc-tools 4/24, pr-release 20/406 on a917d6a
Task 10: concern: finding 1 fixed narrower — refuse only when no managed section exists and the body ends inside an unclosed fence; a section before an unclosed fence is still replaced in place (idempotent, pinned) — re-review judges
Task 10: note: finding 5 fixtures pass on a917d6a too (path was correct, only untested)
Task 10: re-review round 1 dispatched on review-a917d6a..888dfd7.diff
Task 10: fix round 1/5 (5 addressed, 0 open; commits a917d6a..888dfd7)
Task 10: minor (deferred): consumer is_item treats any `N.`/`N)` line as a list item (CommonMark: only `1.` interrupts a paragraph) — paragraph line starting "10. …" split/deduped, can drop a line silently (pre-existing, narrow)
Task 10: minor (deferred): update-pr-body.sh:15 header says exit 1 = malformed markers; also covers unclosed-fence refusal
Task 10: minor (→ T12): doc-pr-release.yml:179-182,245-255 prompt calls update-pr-body "idempotent" and gives no action on refusal — add "if the helper refuses, post its message with gh pr comment" (if allowed by --allowedTools)
Task 10: minor (deferred): unit dedupe detaches a deduped list item from a different fragment's lead-in paragraph (by design); commit-and-push seals a fragment with text before first ### (caught at release with warning)
Task 10: note → T14: CLAUDE.md Key Files row for doc-pr-release/*.sh should include fragment-lib.sh
Task 10: complete (commits 5d5f8aa..888dfd7, review clean)
T12 BASE=888dfd7
Task 12: dispatched implementer (opus) agent ae958e02908652d9b (carries task-12-carry.md items 1-5)
Task 12: implementer DONE_WITH_CONCERNS — commit 7ea49d2; both interps 0 fail (doc-tools 1186, hooks 843, spec 309, pr-release 406, merge 486); BSD spec/pr-release green; RED 165 fail/100 pass; mutation-checked guards
Ruling: T12 replaced two earlier assertions per brief ("section-aware, single-line landed check"; one amendment task per chunk): AMENDED block must cite its plan on its first line — accepted pending review — cost if wrong: consumers' older AMENDED blocks with a later-line citation fail the landed check (v3.0.0 note)
Task 12: concern: widened --allowedTools on the 4 discovery-running AI templates: Bash(jq:*), Bash(git -c core.quotePath=false diff:*) to match the prompt — reviewer judges least-privilege; permission matching of piped commands → CI-return
Task 12: concern → T14: SKILL.md change leaves system-overview, codebase-guide, conventions, getting-started, workflows doc stale; getting-started.md:107 still shows plugin-cache `sort -V` lookup
Task 12: note: mermaid tool once wrote test PNGs to repo root — moved to scratch, none committed (verified status clean)
Task 12: task review dispatched on review-888dfd7..7ea49d2.diff
Task 12: note → T13/T14: hand-offs appended to task-13-carry.md item 3 and task-14-carry.md item 16
Task 12: review → Needs fixes (2 Important): SKILL.md:465 archive step `git mv` fails on the default untracked in-session report and is ungranted in doc-audit-update CI (eval 3 fixture hides it; conflicts with Safety Rule confirmation); AMENDED-block citation moved to line 1 and landed-check reads only line 1 → old-style blocks get false FAIL/P1, break undocumented (partly plan-mandated). Spec ✅ otherwise; moved text verbatim; verbs match --help; jq/quotePath grants within least privilege
Ruling: T12 landed-check made block-aware (join the AMENDED block's `> ` continuation lines, one command, section-aware) instead of documenting a format break — old and new blocks both pass — cost if wrong: slightly more complex check command in injected plans
Ruling: T12 minors folded into round 1 (prompt-layer correctness in the same files): review-pr missing-base check; tool resolution for every action; audit wording; host-agnostic output-templates row + release step 11 add-only-existing; sync skips installer in CI; identical landed-check copies guard; prose-freeze guards → tokens; eval order check; free-text verb guard; report rationale fix — cost if wrong: larger fix diff
Task 12: minor (deferred → T14): CLAUDE.md:127 "Audit report format + plan template"
Task 12: ⚠️ → CI-return: claude-code-action prefix matching for Bash(git -c core.quotePath=false diff:*) / Bash(jq:*) in a pipe; ${CLAUDE_SKILL_DIR} substitution for an action-installed plugin
Task 12: ⚠️ resolved: brief "--plan + review --specs in the protocol and templates" — covered in protocol/integration-patterns/output-templates; doc-spec-verify.yml passes neither (CI has no plan) — accepted
Task 12: fix round 1 → resume implementer ae958e02908652d9b (FIX_BASE=7ea49d2); findings file task-12-fix-round-1.md
Task 12: fix round 1 implementer done — commit fa8384a; both interps 0 fail (doc-tools 1186, hooks 843, spec 353, pr-release 406, merge 486); BSD spec/pr-release green; RED 32 fail/317 on 7ea49d2; quotePath grant narrowed to `diff --name-only:*`
Task 12: re-review round 1 dispatched on review-7ea49d2..fa8384a.diff
Task 12: fix round 1/5 (12 addressed, 0 open; commits 7ea49d2..fa8384a) — landed-check probed under bash 3.2 + BSD awk/grep (5 cases), archive block executed in tracked/untracked layouts
Task 12: minor (deferred): task-12-report.md CI-return note still names the pre-narrowing quotePath grant (report only)
Task 12: complete (commits 888dfd7..fa8384a, review clean)
T13 BASE=fa8384a
Task 13: dispatched implementer (opus) agent a8ddd78631a35d7c6 (carries task-13-carry.md items 1-3; ctx7 for cross-client facts)
Task 13: implementer DONE_WITH_CONCERNS — commit 8e9d4f6; bash3.2 0 fail (doc-tools 1192, hooks 843, spec 432, pr-release 406, merge 486); bash5 same except 1 unidentified doc-tools failure in the matrix run (log overwritten), 1192/1192 in separate runs before/after; BSD legs clean; check-version PASS (5 files)
Ruling: T13 left conventions.md + codebase-guide.md unattested after editing (both already stale from T12) — accepted: attesting would hide T12 drift from T14, which reads and re-attests them in full — cost if wrong: none (T14 carry item 10/16 covers them)
Task 13: R9 — claude-code.json removed (search found no consumer); bump-version/check-version now ignore it (v3.0.0 note)
Task 13: concern → CI-return/real-run: Cursor local install path; Cursor loading settings.local.json; Codex skill discovery via ~/.agents/skills symlink; Gemini read_file reaching $ROOT/references/
Task 13: note: node simulation test in test-spec-status-model.sh; counted SKIP without node, FAIL under DOC_SP_REQUIRE_NODE=1 (tests.yml sets it)
Task 13: controller re-running doc-tools under bash 5 in background to catch the unidentified failure
Task 13: task review dispatched on review-fa8384a..8e9d4f6.diff
Task 13: review → Approved, spec ✅ (0 Critical, 0 Important, 2 Minor); OpenCode fix probe-executed under node; 6 cross-client facts spot-checked via ctx7, all accurate; R9 search thorough, every coupling updated
Task 13: minor (→ T14): README "From a checkout" states a symlinked ~/.claude/skills/doc-superpowers loads as `doc-superpowers@skills-dir` as fact — Claude Code docs flag symlink handling differs; hedge like the other unverified claims
Task 13: minor (→ T14): CLAUDE.md suite counts stale (pre-existing; T14 item 1)
Task 13: ⚠️ unidentified bash-5 doc-tools failure: controller rerun run1 rc=0 (runs 2-3 pending) → if none recurs, treated as the known wall-clock flake (T14 item 14)
Task 13: complete (commits fa8384a..8e9d4f6, review clean)
T14 BASE=8e9d4f6
Task 14: dispatched implementer (opus) agent a5173b0361ff874f2 (carries task-14-carry.md items 1-19; dogfood runs installer on this repo by design)
Task 13: ⚠️ resolved: controller reran test-doc-tools.sh 3x under bash 5 at 8e9d4f6 → 1192/1192 each (logs scratchpad/t13-doctools-b5-run{1,2,3}.log); treated as the known load-sensitive wall-clock flake (T14 item 14)
Task 14: implementer DONE_WITH_CONCERNS — commits 8121b14 (ci dogfood + tests.yml drift check), 6a59f7a (load-robust wall-clock guards), cfabc56 (docs/index hygiene); both interps 3360/3360; BSD hooks 844; check-freshness 54 current, 0 stale, 2 deprecated
Task 14: concern (outside-worktree side effect, already done): git-tier dogfood install wrote the SHARED hooks (/Users/w/code/doc-superpowers/.git/hooks: pre-commit, prepare-commit-msg, post-checkout, post-merge, pre-push) and merge.doc-index.driver in the shared .git/config, resolving THIS worktree's scripts/ on the external volume. Checked: pre-commit exits 0 when tools absent; merge driver leaves conflict markers + exit 1 when absent → degrades safely if the volume unmounts or the worktree is removed. Follow-up for the user: re-run `scripts/hooks/install.sh install --git` from the main checkout after merge
Ruling: T14 untracked + gitignored `.claude/hooks/doc-superpowers/` beyond the brief's settings.local.json (rendered hooks embed a machine path) and committed `.gitattributes` (the issue's fix lists it) — accepted pending review; consistent with R8 per-user tier — cost if wrong: team members must install the Claude tier themselves (already the R8 contract)
Task 14: note: 15 record-doc entries read last_verified: null after remove+add re-indexing (retypes, [""] migration, edited specs) — record docs are not staleness-tracked (T5)
Task 14: minor (deferred → final): harness SIGINT self-test fails when a suite is launched with `&` (async commands ignore SIGINT in non-interactive bash) — likely the T13 unidentified bash-5 failure; make the self-test detect an inherited-ignored SIGINT and skip loudly
Task 14: note → release flow: RELEASE-NOTES v2.14.0's `[""]` fix note left for the release flow; release-notes material collected in task-14-report.md
Task 14: task review dispatched on review-8e9d4f6..cfabc56.diff
Ruling: final whole-branch review split into area-scoped seats run in parallel (whole-branch diff b59375f..HEAD is ~2.4 MB / 35 commits — too large for one reviewer's context): (1) core tools doc-tools.sh/merge-doc-index.sh/test-helpers.sh; (2) installer + hooks; (3) CI templates + helpers + .github; (4) prompt layer + packaging; (5) living docs; each gets the full commit list + branch stat, its area's diff, the tests on demand, its area's deferred minors to triage, and a cross-cutting interface list; findings merged into ONE fix dispatch + one scoped re-review — cost if wrong: a cross-area interaction no single seat sees (mitigated by the interface list each seat checks at HEAD)
Task 14: review → Approved, spec ✅ except Minor Step-4 literal deviation (0 Critical, 0 Important, 7 Minor); drift step probe-verified under both bashes + BSD PATH (passes on fresh clone, fails on 11 mutation kinds); vendored copies byte-identical; index hygiene verified; R5 respected; untracking .claude/hooks + committing .gitattributes accepted
Task 14: minor (deferred): 7 edited docs (6 governing specs + I-14 issue) re-indexed via remove+add → last_verified null; brief/close-out/`:amends` protocol prescribe update-index for them (other 8 null record entries fine)
Task 14: minor (deferred): tests.yml:214 drift summary always says `install --ci` but the .gitattributes drift (:211) needs `install --git`; CLAUDE.md:141 same
Task 14: minor (deferred): tests.yml:171 drift loop covers only current templates — a stray retired doc-index-update.yml recorded in state passes
Task 14: minor (deferred): tests.yml:157 drift step after the five suites without `if: always()` — suite failure hides drift
Task 14: minor (deferred): CLAUDE.md:169 matrix loop `for B in bash /bin/bash` may run the same interpreter twice; name bash-5 binary or print $B --version
Task 14: minor (deferred): deprecate/remove timing budgets 10 s now only 1.4× below the 14-15 s quadratic time (was 2.8×); ~7 s restores margin (test-doc-tools.sh:4545-4546)
Task 14: HANDOFF (user): 8121b14 untracks .claude/settings.local.json + .claude/hooks/doc-superpowers/*.sh — merging into a checkout deletes its tracked copies incl. its permission allowlist → after merge run `scripts/hooks/install.sh install --git --claude` from the main checkout; restore old permissions via `git show 8e9d4f6:.claude/settings.local.json`
Task 14: complete (commits 8e9d4f6..cfabc56, review clean)
ALL TASKS COMPLETE (T1–T14). Next: final whole-branch review (split seats per ruling), one fix wave, scoped re-review; then doc-superpowers audit → update → diagram; then release flow.
FINAL REVIEW dispatched at HEAD cfabc56 (MERGE_BASE b59375f): seat1 core (opus) a1fee3473b70694c4; seat2 installer (opus) a0b18f9b5a05effa0; seat3 ci (opus) aeaf7816e387ef8aa; seat4 prompt (opus) aea6a726e144f7559; seat5 docs (sonnet) a39bde92e34230138; common brief final-review-common.md, rulings final-review-rulings.txt, deferred final-review-deferred.txt
FINAL seat5 docs: With fixes — 2 Important (system-overview.md:161 merge/rebase overstatement; CLAUDE.md:141 .gitattributes remedy --ci→--git), 3 Minor; saved final-review-findings-seat5-docs.md
FINAL seat4 prompt: With fixes — 3 Important (sync rename detection; release range start for untagged versions; eval command patterns miss quoted invocations), 7 Minor; saved final-review-findings-seat4-prompt.md
FINAL seat2 installer: With fixes — 3 Important (status reports dead v2 hooks healthy + no upgrade guidance; "missing from disk"/remove-entry advice for on-disk-but-unstaged docs; untracking .claude files deletes teammates copies silently — NOTE incomplete), 5 Minor; saved final-review-findings-seat2-installer.md
Controller observation (dogfood): the self-installed Claude pre-commit gate emitted its "stages changes as it commits" deferral note on a Bash call whose quoted heredoc body merely mentioned a backticked commit -a (backtick = command position to the regex) — advisory only, no block; same class as deferred T7 regex minor 226
FINAL seat1 core: With fixes — 2 Important (no in-place doc_type retype verb while record status depends on it; remove-entry/deprecate-entry exit 0 for unknown key vs documented exit 1), 9 Minor; disagrees with ruling 244 (exit code); saved final-review-findings-seat1-core.md
FINAL seat3 ci: With fixes — 4 Important (consent/security text understates agent capability incl. secret exposure via jq env + code exec in read-only jobs; GITHUB_TOKEN commits start no runs undisclosed; full-cycle superseded ends green, work dropped; SKILL update steps edit CLAUDE.md/README which CI commit sets refuse), 6 Minor; disagrees with R315 + R314; saved final-review-findings-seat3-ci.md
FINAL REVIEW complete: 5 seats, all "With fixes", 0 Critical, 14 Important, 30 Minor. Fix wave spec: final-fix-wave.md (FIX_BASE=cfabc56)
Ruling F1 (amends R315): the "security ceiling is the job token's permissions:" text is inaccurate (agent code exec in read-only jobs via git --output; jq env exposes Anthropic/GH tokens; repo-wide contents:write incl. step scripts later run with secrets; doc-release's repo setting lets agent jobs approve PRs) — reword accurately, recommend branch protection with required human review, document CLAUDE_CODE_SUBPROCESS_ENV_SCRUB as hardening (not set: unverifiable offline), drop Bash(jq:*) from tag-mode respond if unused; no new sandboxing — cost if wrong: residual secret-exposure risk remains documented rather than mitigated by default
Ruling F2 (amends R314): superseded ends green only where the trigger re-fires (audit-update push, pr-release synchronize); doc-pr-full-cycle (opened only) fails visibly — cost if wrong: a red full-cycle run on a busy PR that a re-run fixes
Ruling F3: in CI, `update` reports needed CLAUDE.md/README.md changes instead of editing (commit sets not widened) — cost if wrong: those two files lag until a local run
Ruling F4: new verb `set-doc-type <doc> <type>` (16 subcommands) to retype in place, routed in SKILL.md — cost if wrong: one more verb to maintain
Ruling F5: deprecate-entry exits 1 for unknown keys (after applying the rest); remove-entry stays idempotent exit 0, documented — cost if wrong: scripts calling deprecate-entry on absent keys now fail
Ruling F6 (seat-1 disagreement with ruling 244): keep exit 2 for set-implementation/fragments validate malformed values; document per-verb exceptions — cost if wrong: exit-code inconsistency remains, but documented
Ruling F7: one "Upgrading from 2.x" section + `status` detects outdated installs — cost if wrong: none
Ruling F8: deferred to a follow-up issue: H-M1 (worktree-shared exclude block), H-M3 (symlinked host hook refuses git tier), C-M8, plus all fix-later/CI-return triage lines — cost if wrong: multi-worktree users (incl. this user) can see other worktrees' per-user files un-excluded after one worktree's uninstall --claude
Ruling F9: update-index the 7 docs T14 read+edited but re-indexed via remove+add; leave 8 other null record entries — cost if wrong: none
Ruling F10: follow-ups written to docs/issues/2026-09-28-sweep-05ea982-followups.md so deferred items survive the ledger's deletion — cost if wrong: none
FINAL fix wave dispatched (opus) agent a748423046b7b4865 on final-fix-wave.md (FIX_BASE=cfabc56)
USER (2026-09-28 ~16:30): find the next safe stopping point; switching accounts; write a handoff to continue on this host in a fresh session.
FINAL fix wave PAUSED after area 1 (core tools): commit 34a3841; both interps 3447/3447 (doc-tools 1279, hooks 844, spec 432, pr-release 406, merge 486), 0 SKIP/XFAIL; BSD doc-tools/pr-release green; check-version PASS; tests.yml drift step green after re-vendoring .github/scripts/doc-tools.sh
FINAL fix wave done: C-I1 (F4 set-doc-type), C-I2 (F5), C-M1 (F6), C-M2..C-M7, 98, 122, 264, 399, 409, + doc-tools.sh parts of S-M1, S-M4, H-M2. NOT started: everything else — see final-fix-wave-report.md "## Paused" (line ~140) + unapplied drafts in final-fix-wave-drafts/ (edit-installer.py, edit-skill-ci.py, followups.md, precheck.new.sh, upgrade-section.md, …)
FINAL fix wave notes: 129 not reproducible (regression test kept); set-doc-type known-type set = documented types + types already in the index; C-M4 no local RED (no mawk); 5 living docs now stale (system-overview, codebase-guide, conventions, getting-started, workflows) → docs area; system-overview PNG still says "15 subcommands" (source says 16) → diagram pass; _doc_commits declares an unused local `checks` (minor); first BSD doc-tools run aborted rc 128 on a fixture `git commit` "unable to create temporary file: Invalid argument" — isolated rerun + full rerun green (environment glitch; watch for recurrence)
PAUSED: resume = fresh implementer (opus) on final-fix-wave.md + final-fix-wave-report.md "## Paused" (FIX_BASE for the eventual scoped re-review stays cfabc56; resume areas: installer+hooks → CI → prompt → docs + follow-up issue), then scoped re-review of cfabc56..HEAD, then audit → update → diagram, then release flow.
````
