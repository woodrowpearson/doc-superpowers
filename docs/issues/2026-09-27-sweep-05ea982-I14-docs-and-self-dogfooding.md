---
date: 2026-09-27
status: Resolved
priority: P1
type: bug
component: docs
source: sweep-skill
cluster-key: sweep-skill:full-repo:I-14
run-id: 05ea982
related-files:
  - .github/workflows/doc-freshness-pr.yml
  - .github/workflows/doc-freshness-schedule.yml
  - .github/workflows/doc-index-update.yml
  - .github/workflows/tests.yml
  - .claude/settings.local.json
  - .claude/hooks/doc-superpowers/pre-commit-gate.sh
  - .claude/hooks/doc-superpowers/post-commit-sync.sh
  - .claude/hooks/doc-superpowers/session-summary.sh
  - .gitignore
  - CLAUDE.md
  - README.md
  - docs/codebase-guide.md
  - docs/conventions.md
  - docs/workflows/doc-superpowers.md
  - docs/architecture/system-overview.md
  - docs/.doc-index.json
screenshots: null
axiom-agent: null
branch: null
design-doc: null
report: docs/plans/2026-09-27-full-repo-05ea982-audit-findings.md
---

# I-14 — Self-dogfooding gap and living-doc drift

> Cluster **I-14** of sweep run `05ea982`, ranked #14 of 14 by finding weight. Its priority is P1
> because of the S6 item below: the self-installed workflows have never run doc-tools. The
> CI-execution finding is only P3 on the verifier's evidence, but restoring CI is still the first owner
> action, because it gates every later fix. Evidence:
> [findings index](../plans/2026-09-27-full-repo-05ea982-audit-findings.md) (S11, S5, S6, Phase 4).
> Fix: **Task 14** of the [fix plan](../plans/2026-09-27-full-repo-05ea982-fix-plan.md), except the
> CI-execution item, which is a repository-settings action for the owner and is **not** a code
> change.

## Summary

This repository installs its own Claude and CI tiers, but none of them has been working:
- **CI tier:** the self-installed workflows call `.github/scripts/doc-tools.sh`, which was never
  committed, and the gate fails open.
- **Claude tier:** the hooks are pinned to `/Users/w/…` paths, and the tier could not have fired
  anyway (I-6).
- **Tests workflow:** since 2026-08-31 *every* GitHub Actions job in the repo has ended as `failure`
  within 2–6 s with no logs. v2.15.0 (PR #17) merged with the Tests workflow red and never executed.
  Its bash 3.2 leg last ran on 2026-07-30.

Because the tool never ran against itself, none of the runtime defects in I-6 and I-8 surfaced. The
living docs also describe features that do not work, and repeat counts that have drifted.

## Incorrect assumption

- "Hand-mirrored self-installs stay current."
- "A green badge once means CI is running."
- "Counts copied into N docs stay in sync."
- "Refreshing the index == verifying the doc."

## Verified evidence

- **[P3, verifier-authoritative (V-FU4); controller proposed P1; measured via the GitHub API]** Actions
  jobs are not executing.
  - Realized risk today is low. Since the last green bash-3.2 run (PR #16 head 6e2bc76,
    2026-07-30), the only change under `scripts/` is `test-spec-status-model.sh` (+36 lines), and
    one of those lines is a vacuous assertion (I-13).
  - Every future change, however, merges ungated.
  - Every workflow run from 2026-08-31 onward concluded `failure` within 2–6 s:
    - Tests runs 8–11, both the `ubuntu / bash 5.x` and `macos / bash 3.2` jobs;
    - Doc Index Update runs 19–20;
    - Doc Freshness Check run 20;
    - Doc Freshness Audit (Scheduled) runs 23–26, the latest on 2026-09-21.
  - Job logs return HTTP 404 and check runs carry no output, which is consistent with jobs that
    never started.
  - The last run that actually executed was the scheduled audit on 2026-08-24 (success, 10 s).
  - The cause is **needs-runtime**: it is not visible through the API. Typical causes are an Actions
    spending limit or billing lock, or Actions disabled for the repo or account; macOS minutes bill
    at 10×.
  - Consequences:
    - PR #17 (v2.15.0) and HEAD `05ea982` merged without the five suites ever running in CI;
    - the "696 assertions in CI on bash 5.x and 3.2" claim in CLAUDE.md is unverified for v2.15.0;
    - the sweep measured 696/696 locally on bash 5.2 only.
  - PR #17 merged about 3 minutes after its Tests check failed. Either `main` has no required status
    checks, or they were bypassed. The API calls used here cannot tell which.
- [P1] `.github/workflows/doc-freshness-pr.yml:51`, `doc-freshness-schedule.yml:33`,
  `doc-index-update.yml:52` call `.github/scripts/doc-tools.sh`, which was never committed (since
  4727d2f, 2026-04-05). None of these workflows has ever run doc-tools here. PR #17 had 20 stale
  docs under STRICT=1 and passed. Measured.
- [P2] `.claude/settings.local.json` is tracked. It is a personal settings file, committed with
  `/Users/w/…` paths and broad pre-approvals (`Bash(git push:*)`, `Bash(gh repo:*)`). The
  self-installed hooks pin `/Users/w/code/doc-superpowers/scripts/doc-tools.sh`, so this repo's
  Claude tier is dead on every clone. `.gitignore` does not list the file. Measured.
- [P2] `README.md:202`, `codebase-guide.md:58-59`, workflows doc `:384` claim the Claude hooks
  auto-run `update-index`. That call has never worked.
- [P2] `CLAUDE.md:23-28`, `README.md:291-295`, `codebase-guide.md:21-25,168` describe the
  self-installed CI tier as working.
- [P2] `CLAUDE.md:150,152`, workflows doc `:514,527,582`, `codebase-guide.md:342`,
  `conventions.md:274`: v2.15.0's `:amends` / `spec-verify --plan` are missing from the agent-facing
  docs.
- [P2] `docs/conventions.md:309-317,331`: the status table contradicts the code (also I-3).
- [P3] Reinstated after Phase-4 review; verifier V-S3 had dropped it. The repo does not register its
  own merge driver, and has no `.gitattributes` entry for `docs/.doc-index.json`. PR #16's conflict,
  which exists only in the generated index, is exactly the case the driver exists for. Dogfood it
  only **after** I-5 makes the driver three-way.
- [P3] Index and doc hygiene:
  - three `code_commit` SHAs are reachable only from tag v2.12.0 (pre-rebase copies);
  - point-in-time records are 91% of the stale signal;
  - archived docs are not deprecated;
  - test counts disagree (`(68)` / `680`);
  - GNU sed is missing from the dependency lists;
  - the `.claude/mcp.json` location is wrong;
  - the C4 PNGs are older than their Mermaid;
  - docs name `__DOC_TOOLS_PATH__`;
  - `tests.yml` is missing from the directory trees;
  - a `doc_type` mismatch;
  - the v2.14.0 `[""]` explanation is wrong;
  - the INSTALL pin check is not followed;
  - "except hooks" wording;
  - lying code comments at `doc-tools.sh:284,428,429,510`.
- [P3, unverified carry-over] `tests.yml` has no step that diffs the self-installed workflows and
  the vendored tool against their templates. That missing guard is why this drift went unnoticed.

### Follow-up pass FU4, spec drift (verified by V-FU4)

The Phase-4 critic found that the five governing design specs had never been read. The verifier
dropped 25 of the finder's spec items as superseded history (a later RELEASE-NOTES entry or spec
records the change) or as duplicates. What survives:

- [P3] `docs/superpowers/specs/*`: the Status headers misstate the lifecycle in 5 of 6 specs.
  - 2026-03-12 says "11 subcommands"; there are 14.
  - 2026-03-13 says "in flight"; it shipped in v2.12.0.
  - 2026-03-14 says "Approved"; it shipped in v2.2.0, and its transitions were replaced by
    2026-07-24 with no back-pointer.
  - 2026-03-25 has no Status.
  - 2026-07-24 says "Approved, Target 2.13.0"; it shipped in v2.13.0.

  Nothing updates a spec's Status or its supersession pointer when it ships. All 6 report stale.
  Five of them are the fix plan's `governing_specs`.
- [P3] `workflow-hooks-harness-design.md:220,287,321,650-651,288,324`: the spec prescribes four
  mechanisms that measurably fail, and the code implements them exactly as written. It is the spec
  side of I-6, so amend it in lockstep with T7.
  - The `#` block "excluded from commit".
  - The no-argument `update-index` refresh.
  - The root-commit `diff-tree` fallback.
  - The 1 s session-summary budget (re-measured 8.8 s on the macOS fallback path).
- [P4] Mechanism samples that disagree with the code:
  - hooks spec `:74/:241` (local copy name), `:101` (`core.hooksPath` existence; the code is right),
    `:150/:223/:310` (the hooks drop `code_refs_changed`), `:179` (build-index hint);
  - tooling spec `:343` (build-index hint), `:123-129` ("must use writing-plans", relaxed without a
    note);
  - release spec `:128` ("step 7"; it is step 10);
  - pages spec `:104,109` (duplicate `nav` key).


## Proposed fix

**Owner action, immediately, not a code change:** open *Settings → Billing and plans* (Actions
spending limit / payment) and *Settings → Actions → General* for the repository and the account, to
find why jobs stop before starting. Then:
- re-run Tests on `main`;
- add branch protection on `main` requiring the two Tests jobs, so a red or never-run CI cannot
  merge.

**Code (fix plan Task 14, run last):**
- Re-run the installer for this repo once T7–T9 have landed.
- Commit the vendored tool, or re-render the self-installed workflows to call `scripts/doc-tools.sh`.
- Untrack `.claude/settings.local.json` and git-ignore it.
- Add a `tests.yml` step that diffs self-installed files against their templates.
- Index hygiene via `set-code-refs` (T5).
- Keep suite counts only in CLAUDE.md.
- Fix the drifted docs.
- Amend drifted mechanism sentences in the five governing specs.
- Register the merge driver after T6.

## Acceptance criteria

- [ ] The Tests workflow executes on `main`, both legs, and is required by branch protection.
- [ ] The self-installed freshness workflows run doc-tools and fail closed.
- [ ] `check-freshness` on this repo reports only genuinely living docs as stale.
- [ ] No doc claims a hook behaviour the hook lacks.

## Resolution (Task 14)

Resolved by Task 14 of the fix plan, in commits `8121b14` (dogfood) and the one that carries
this section (tests, docs, index). The CI-execution item stays an **owner action** — not a code
change, and not done: Actions is still blocked by the account's billing lock, so none of this has
run in GitHub Actions yet.

**Dogfood.** The fixed installer was run from this checkout onto this checkout, once per tier:
- **CI tier** (`install --ci`): the two freshness workflows re-rendered from the current
  templates with the choices read back from the old copies (base `main`, cron `0 9 * * 1`,
  strict `true`) and recorded in `.claude/doc-superpowers/installed.json`;
  `.github/scripts/doc-tools.sh` and `.github/scripts/doc-superpowers-steps/` vendored. All of
  it is committed, so the workflows now run the tool they call, and they fail closed.
- **Claude tier** (`install --claude`): per-user, as R8 decided. `.claude/settings.local.json`
  and `.claude/hooks/doc-superpowers/` are untracked and git-ignored: the rendered hooks name the
  installing machine's plugin path, which is what left the tier dead on every other clone.
- **Git tier** (`install --git`): the shared `.git/hooks` copies were the 2026-03-29 v1 hooks
  (including the prepare-commit-msg that wrote `# stale:` lines into `-m` messages). They are
  replaced, the three-way merge driver is registered, and its `.gitattributes` block is
  committed.
- **Drift guard:** `tests.yml` gained *Self-installed CI tier matches its templates*, run on
  both matrix legs. It re-renders every workflow the state file records with the recorded
  choices and `diff`s it against the installed copy, `cmp`s the vendored `doc-tools.sh` and every
  vendored helper against the plugin's, requires each script a workflow runs to be present and
  executable, and checks the index's merge-driver attribute. Locally it passed on the installed
  tree and failed on an edited workflow, an edited vendored tool, and a helper without its exec
  bit (Task 14 report).

**Index hygiene** (through `doc-tools.sh` verbs only). Record docs' `code_refs` are emptied
(`set-code-refs --refs ''`). The two older issues are retyped `issue`, the six design specs
`design-spec`, and the five `[""]` entries are now `[]`. No verb changes `doc_type`, and
`set-code-refs` treats `[""]` as `[]` (no write) and keeps a stored `code_commit`, so those
entries were re-indexed with `remove-entry` + `add-entry`, unverified (`last_verified: null`).
That also dropped the last `code_commit`s reachable only from tag v2.12.0 (`f063b04` on two
entries and `abb3e64`; the third, `c2496da`, was already gone). The archived plans
are deprecated.

**Living docs.** Suite counts live only in CLAUDE.md, and the other docs link to it. `:amends`
and `spec-verify --plan` are now in CLAUDE.md, the workflows doc, the codebase guide and the
conventions. Also fixed:
- the status table (a `missing` row; record docs are `current` only when present);
- the dependency lines (`jq` ≥ 1.6, bash ≥ 3.2, no GNU tools);
- the Mermaid MCP location (`claude mcp add`, `.mcp.json`);
- the directory trees (`tests.yml`, `.github/scripts/`, the per-user Claude tier);
- README *Contributing* (run the five suites; re-install the CI tier);
- the workflows doc's discovery, `update` and `sync` steps, which still ran project scripts and
  rebuilt the index.

The C4, primary, discovery, init and hooks PNGs are re-rendered, with the C4 descriptions cut
back to fit. `__DOC_TOOLS_PARENT__` / `__DOC_TOOLS_PATH__` no longer appear in any living doc.
The two `doc-tools.sh` comments that cited a plan this repo never had are corrected.

**Governing specs.** The Status headers are corrected in the five governing specs, and the pages
spec's `Approved` stands. 2026-03-14 points to 2026-07-24, which supersedes its transitions.
Dated **AMENDED** blocks (the repo's spec-amendment form, citing the fix plan's Task 14) now sit
at each drifted mechanism:
- **the hooks spec**, in lockstep with Tasks 6–9:
  - the four failing mechanisms (the `#` block, the no-argument `update-index`, the root-commit
    `diff-tree`, the 1 s budget);
  - the placeholder, local copy and hooks-dir samples;
  - the untracked hint and the integration point;
  - the retired `doc-index-update.yml`;
  - a superseded pointer on the newest-wins merge driver;
- **the tooling spec**: content identity, schema 3, the `add-entry` hint, the relaxed
  writing-plans rule, and the version floors;
- **the protocol spec**: `add-entry`, the guarded transitions, and what `check-freshness`
  compares;
- **the release spec**: the current flow, step 9, and five manifests;
- **the transition-model spec**: the third role, `:amends`.

**Test noise.** Three wall-clock guards were made load-robust, and each still guards what it
did:
- the check-freshness scale bound is 20 s, still under half the per-doc cost, next to its exact
  spawn counts;
- the deprecate/remove budgets are 10 s, still below the quadratic time;
- the session-summary output guard stretches the watchdog's sleep to 60 s with a `sleep` shim,
  so a held output costs a minute instead of racing a 2 s budget. It was mutation-tested.

**Acceptance criteria.**
- The Tests workflow executing on `main` and required by branch protection is an owner action,
  **open**.
- The self-installed freshness workflows run the committed doc-tools and fail closed. This is
  **done in code**; one real Actions run is still pending the billing lock.
- `check-freshness` on this repo reports only genuinely living docs as stale. **Done**: none are
  stale after this Task's verification.
- No doc claims a hook behaviour the hook lacks. **Done**: the hooks spec's claims are amended,
  and the living docs were rechecked.

**Left for the release flow:** the RELEASE-NOTES v2.14.0 `[""]` explanation. RELEASE-NOTES.md is
the release's file.

**Later (the final review fix wave).** `set-doc-type` now retypes an entry in place, keeping its
other fields, so the next retype needs no `remove-entry` + `add-entry` (the seven `last_verified`
values lost here stay lost; this issue and the six design specs were re-attested after reading).
The deprecate/remove budgets are now 7 s. `tests.yml`'s drift step also runs after a failing
suite, flags a retired doc-superpowers workflow, and names `install --git` for `.gitattributes`
drift. What the wave deferred is listed in `docs/issues/2026-09-28-sweep-05ea982-followups.md`.

