## Documentation Freshness Audit — 2026-10-15

**Branch:** design/work-ledger · **HEAD:** 0f6f467

This is a dogfood run of the branch's own 3.3.0 skill (`skills/doc-superpowers/SKILL.md`, `audit`, scope `all`). Every scope agent read a detached snapshot of 0f6f467, so all line numbers below are at 0f6f467. `$DOC_TOOLS` was the snapshot's `scripts/doc-tools.sh`, run under `/bin/bash`.

The merge applied the controller's rulings:
- Only bucket A (general doc debt) becomes findings and Update Tasks.
- Bucket B (the 3.3.0 ledger docs) goes to Appendix A for Task 18.
- Code gaps go to Appendix B for Task 17.
- 3.2.0 P2-1 (the Scope-matrix docs) stays resolved by the owner's exemption.

### Summary
- **Scanned:**
  - the 5 indexed living docs: `docs/architecture/system-overview.md`, `docs/codebase-guide.md`, `docs/conventions.md`, `docs/guides/getting-started.md` and `docs/workflows/doc-superpowers.md`;
  - `CLAUDE.md`, `README.md`, `RELEASE-NOTES.md` and `skills/doc-superpowers/SKILL.md`;
  - the 10 `references/*.md` and `scripts/hooks/ci/doc-pr-release/RELEASE-NOTES.next.README.md`;
  - `AGENTS.md`, `GEMINI.md` and the three client INSTALL guides;
  - the `doc-tools.sh` and `install.sh` help text, and `evals/`.

  Scopes are as in the 3.2.0 audit: `application`, `ci-cd`, `agentic`, `spec` (records only) and the always-generated docs. 3.3.0 did not change them. `testing` is still undetected (A-P3-54).
- **Fresh: 56 | Stale: 5 | Missing coverage: 0 | Untracked: 2** (also Deprecated: 2). These are `check-freshness` counts at 0f6f467.
  - All five living docs are stale, and in every case the stale refs are ledger code (Appendix A).
  - `docs/conventions.md` is also `doc_modified`. Its only edit is 42797cf, the Scope-matrix exemption section (`:206-212`), which was checked and is accurate. It stays.
  - The 2 untracked docs are the ledger plan and design (U37).
- **Findings (bucket A) after merging: P0 0 | P1 2 | P2 34 | P3 80** (116 total). They are:
  - 101 carried-over 3.2.0 items that still apply;
  - the 3 nits the 3.2.0 session handed over;
  - 12 new findings.
- **De-duplication:** each 3.2.0 item appears once, with its id in brackets, under the doc its 3.2.0 entry named first, and every location is listed. New findings that share a root with a 3.2.0 item at another doc were merged into that item, at its highest rating:
  - `CLAUDE.md:80,133` into P3-63;
  - `README.md:213` into P3-36;
  - `README.md:162` into P2-7, rated P2;
  - `codebase-guide.md:421` into P3-65;
  - `SKILL.md:163` and `README.md:179` into P3-18.
- **Outside the counts:**
  - Appendix A has 73 Task 18 items: P1 16 · P2 42 · P3 15.
  - Appendix B has the 4 code gaps routed to Task 17, plus 4 code halves of A findings that `update` must not edit.
- **Per-doc verdicts:**
  - STALE: `system-overview.md` (ledger; MISSING_COVERAGE for claims), `codebase-guide.md`, `conventions.md`, `workflows/doc-superpowers.md`, `CLAUDE.md` (counts; ledger tree), `README.md`, `SKILL.md`, `references/spec-claims.md`, `references/spec-lifecycle-actions.md`, `references/spec-lifecycle-protocol.md`, `references/doc-spec.md`.
  - STALE (minor): `references/hooks.md`, `references/agent-prompt-template.md`, `references/integration-patterns.md`.
  - MISSING_COVERAGE: `getting-started.md`.
  - P3 only: `references/output-templates.md`, `references/release.md`, `references/tool-mappings.md`, `RELEASE-NOTES.next.README.md`.
  - FRESH: `AGENTS.md`, `GEMINI.md` and the three INSTALL guides.
  - `RELEASE-NOTES.md`: 62 commits unreleased, as expected before the 3.3.0 release, plus two wording nits in v3.2.0.
- **Dispatch:** four read-only scope agents ran in parallel, each given only its scope, with the trust-boundary, secrets and verification blocks of `references/agent-prompt-template.md`:
  - architecture;
  - workflows plus the agentic inventory (step 11);
  - guides, codebase guide and conventions;
  - root files and references, with the deferred 3.2.0 status table and the three nits.

  The orchestrator ran steps 4–5, spot-checked the four Task 17 code gaps against the snapshot, and merged.
- **Limits:**
  - No agent ran a test suite. The suite counts are the controller-verified totals at 0f6f467, which are the same under bash 5.x and `/bin/bash` 3.2.
  - Only read-only commands ran: `check-freshness`, `status`, `check-version` (PASS at v3.2.0), `--help`, `git log`/`diff` and `cmp`. No index verb wrote anything.
  - No secret was found, and no directive in repository content was acted on.
- **Structure and naming:** no doc uses the old flat structure, and there is no global `docs/diagrams/`. Every doc outside `docs/issues/` and `docs/archive/` is kebab-case.

### P0 Critical

None.

### P1 Stale

1. **A-P1-1** `CLAUDE.md:178` (Conventions → Testing): the suite counts are stale, and the canonical suite list has six suites where CI runs seven. [new; the 3.2.0 P1-9 count was fixed at v3.2.0, and `test-hooks.sh` has drifted since]
   - Doc says: "Six shell suites gate changes — `test-doc-tools.sh` (1377 assertions), `test-hooks.sh` (1097), `test-spec-status-model.sh` (641), `test-doc-pr-release.sh` (601), `test-merge-driver.sh` (600), `test-spec-claims.sh` (3167), 7483 total". It also says "All six run in CI". The loop `for s in doc-tools hooks spec-status-model doc-pr-release merge-driver spec-claims` omits ledger. `:29` and `:146` say "the six suites".
   - Code shows:
     - `git diff v3.2.0..HEAD -- scripts/test-hooks.sh` adds 234 assertion call sites (the ledger hook sets).
     - `.github/workflows/tests.yml:150-152` runs `"$BASH_BIN" scripts/test-ledger.sh` on both legs.
     - The verified totals at 0f6f467, the same in both shells, are: doc-tools 1377, hooks **1345**, spec-status-model 641, doc-pr-release 601, merge-driver 600, spec-claims 3167, ledger **2681**. That is **10412** in total.
   - Suggested fix:
     - Write "Seven shell suites", set hooks to 1345, and add `test-ledger.sh` (2681) and the 10412 total.
     - Write "All seven", and add `ledger` to the loop.
     - Write "the seven suites" at `:29` and `:146`.

     The "add test-ledger" part is a ledger item, folded into this task by ruling 6 (U1).
2. **A-P1-2** `README.md:232`: the "silent when absent" claim is false for the claims leg. [new; the same defect was fixed in `docs/workflows/doc-superpowers.md` as 3.2.0 P1-7]
   - Doc says: "A hook whose tooling is absent (no skill, no `docs/.doc-index.json`) stays silent".
   - Code shows:
     - `scripts/hooks/git/pre-commit:43` runs the claims leg (`claims validate --staged`), which can block. It runs *before* `:78` `[[ -f docs/.doc-index.json ]] || exit 0`.
     - `references/hooks.md:27` says "with or without a doc-index".
   - Suggested fix: "…stays silent, except the claims legs, which run whenever `docs/spec-claims/` exists, index or not".

### P2 Incomplete

**README.md**
1. **A-P2-1** `:226`, `:232`: the claims hook legs and the claims skip variable are missing. [3.2.0 P2-2]
   - Doc says: `:226` ends "Pre-push reminds about unreleased commits on the branches being pushed". `DOC_SUPERPOWERS_CLAIMS_SKIP` has 0 matches in README.
   - Code shows: the blocking claims leg and the skip variable are at `pre-commit:18-25,43-58`; the advisory leg is at `pre-push:12-23`.
   - Suggested fix: add one sentence per hook, and add `DOC_SUPERPOWERS_CLAIMS_SKIP=1` to `:232`.
2. **A-P2-2** `:230`, `:203`: the CI paragraph and `--ci-strict` leave out the claims work. [3.2.0 P2-3]
   - Doc says: `:230` never mentions `doc-spec-verify`'s non-AI `claims` job. `:203` says `--ci-strict` means "PR check fails on stale docs".
   - Code shows:
     - `doc-spec-verify.yml:103-148` needs no secret, sets `persist-credentials: false` (`:123`) and passes `DOC_SUPERPOWERS_STRICT: "__CI_STRICT__"` (`:131`).
     - `doc-freshness-schedule.yml:23-27,42-51` has the claims step and a 30-minute timeout.
     - `install.sh help` names both halves of strict.
   - Suggested fix: name the job and the schedule step at `:230`, and add the claims half to `:203`.
3. **A-P2-3** `:9-22`, `:175-179`: there is no feature bullet for claims. [3.2.0 P2-4]
   - Doc says: "What It Does" has no claims bullet. *Spec claims (opt-in)* names gate injection only.
   - Code shows: the spec actions also do the following, none of which README names:
     - `spec-generate` writes `unbuilt` stubs (`spec-lifecycle-actions.md:139`);
     - `spec-verify` runs `claims attest --final` and can report "claims verdict owed" (`:312`);
     - a red claim is a **P1 Claim red** finding (`:365`);
     - R5 (`SKILL.md:540`).
   - Suggested fix: add a bullet and name those four.
4. **A-P2-4** `README.md:399`, also `docs/guides/getting-started.md:7-10`: the prerequisites are incomplete. [3.2.0 P2-5]
   - Doc says:
     - README: "`git` | Yes | Already required".
     - getting-started: Claude Code, "Git installed", "`jq` **1.6 or newer**", a project.
   - Code shows:
     - `doc-tools.sh:8143-8144` dies with "git 2.36 or newer is needed" (`--remerge-diff`) for a claims check over a merge, and `spec-claims.md:19` says the same.
     - `check_deps` requires `sha256sum` or `shasum` (`doc-tools.sh:46-48`; `SKILL.md:122`).
     - bash ≥ 3.2 is the floor (`README.md:398`).
   - Suggested fix:
     - README: git ≥ 2.36 for claims-enabled projects.
     - getting-started: add bash ≥ 3.2, `sha256sum`/`shasum`, and git ≥ 2.36 (claims).

**docs/architecture/system-overview.md**

5. **A-P2-5** `:66`, `:117-126`: spec claims have no container, no stores and no Tech Stack row. [3.2.0 P2-10]
   - Doc says: Freshness Tooling holds "… and spec claims (claims: validate, run, promote, render, gate, attest, rulings)". No other container mentions claims, and the Tech Stack has a row for every reference except `spec-claims.md`.
   - Code shows:
     - The claims code is `doc-tools.sh:6008-11890`, about 5,880 of the file's 12,100 lines.
     - Its stores:
       - the sidecars and `config.json` under `docs/spec-claims/`;
       - the gate records (`_claims_gate_write`, `:11142`);
       - the verdict store `$(git rev-parse --git-common-dir)/spec-claims/promotions` (`:7236-7241`);
       - the `## Claim status` block that `claims render` writes (`:7660`).
   - Suggested fix: add a Spec Claims container with its stores and a Tech Stack row, and re-render `c4-container.png`.
6. **A-P2-6** `:18-42`, `:55-100`, `:39`: the C4 diagrams leave out the host adapters, doc-tools' writes into the project, and CI's claims legs. [3.2.0 P2-11]
   - Doc says:
     - The context diagram has no adapters system.
     - The container diagram has no `doctools → project` Rel.
     - `:39` is `Rel(ci, skill, "Runs freshness checks on PR/schedule")`.
   - Code shows:
     - `spec-claims.md:277`: "a host supplies small executables named in `config.json`".
     - `doc-spec-verify.yml:103-107` defines the non-AI `claims` job, and `:116` says it "runs the PR's own code (its adapters)".
     - `doc-freshness-schedule.yml:51` runs `claims-check.sh scheduled`.
   - Suggested fix:
     - Add a "Host adapters" external system, shared with the ledger's (T18-31).
     - Add `Rel(doctools, project, "Writes docs/.doc-index.json, claims records and status blocks, release fragments")`.
     - Widen `:39` to cover the claims job and the weekly claims re-run.
     - Re-render both PNGs.
7. **A-P2-7** `:115`, `:160`: the claims hook legs are not in the hooks design. [3.2.0 P2-12]
   - Doc says: `:160` "A failing check prints one line and blocks only under STRICT." `:115` names neither leg, and no Key Decision covers claims.
   - Code shows:
     - `pre-commit:18-23`: "A finding (exit 1) blocks the commit whatever STRICT says" (the same behaviour is at `:41-60`).
     - `pre-push:12-23` runs an advisory leg: `claims run --planes-of` and `claims attest --plan`.
     - The design has no Key Decision:
       - claims are opt-in through `docs/spec-claims/` and inert without it;
       - they have their own 0/1/2/3 exit family;
       - "could not run" is never reported as a pass;
       - gate records are self-reported.
   - Suggested fix: add both legs to `:115`, take the claims finding out of `:160`'s STRICT sentence, and add a Key Decision "Spec claims: opt-in, inert, never a false pass".

**docs/codebase-guide.md**

8. **A-P2-8** `:212-430`: Code Flow has no spec-claims flow. [3.2.0 P2-13]
   - Doc says: the flows are init, audit, command line, index write path, release, hooks install, spec-generate and spec-inject/verify. Claims appear only as bullets (`:389,402-403,411-412,416,427-428`).
   - Code shows a path the guide does not trace:
     - the gate-record write, `_claims_gate_write` (`:11142`);
     - promote's writes to the sidecar, the status block and the verdict store (`:7159+`, `:10316+`; `spec-claims.md:62`);
     - the dirty-tree refusal (`spec-claims.md:214,358,362`);
     - the adapter invocation: top-level cwd, stdin `/dev/null`, fail-closed parsing (`spec-claims.md:309-311`);
     - the range rule: first parent plus `--remerge-diff` (`doc-tools.sh:8039-8201`).
   - Suggested fix: add a "Spec claims (every claims verb)" flow.

**docs/conventions.md**

9. **A-P2-9** `:182-204`: there are no spec-claims naming or directory conventions. [3.2.0 P2-8]
   - Doc says: the File Names and Directory Structure tables have no claims names. `grep spec-claims` matches only `:299`, `:320` and `:362`.
   - Code shows: `spec-claims.md:52-68` defines these names:
     - `docs/spec-claims/<DOC-ID>.json` and `config.json`;
     - `gates/<plan-stem>/chunk-<n>.json` and `final.json`;
     - the verdict store;
     - the status-block and descriptive markers;
     - the `**Claims:**` plan lines.
   - Suggested fix: add a "claims-enabled only" row and a short naming table that links to `spec-claims.md` → *Files and names*.
10. **A-P2-10**: there is no `## Code Style` section. [3.2.0 P2-9]
    - Doc says: no such section, though the template requires one (`references/doc-spec.md:848`).
    - Code shows rules no doc records:
      - the bash-3.2 guard (`scripts/test-doc-tools.sh:494-758`, which also scans `scripts/ledger/*.sh` and `scripts/adapters/*.sh` at `:518-519`);
      - the jq-1.6 guard (`:760-921`);
      - the POSIX-userland and mawk ≥ 1.3.4 rules (`README.md:403`).
    - Suggested fix: add the section, and say which rules a suite enforces statically. The jq guard does not cover the ledger code yet (T17-1).

**docs/guides/getting-started.md**

11. **A-P2-11** `:182`, `:59`: the claims paragraph leaves out what opting in implies. [3.2.0 P2-6]
    - Doc says: "A project that creates `docs/spec-claims/` turns … into executable claims … Without that directory every `claims` verb is inert". `:59` says "No configuration required."
    - Code shows:
      - Once the directory exists, the pre-commit claims leg blocks on a finding whatever STRICT says, and `DOC_SUPERPOWERS_CLAIMS_SKIP=1` is its only bypass (`pre-commit:18-24`).
      - The PR claims job ships only with the opt-in `doc-spec-verify` (install help).
      - Test claims need runner adapters, and `runners` defaults to `{}` (`spec-claims.md:88`).
    - Suggested fix: add one or two sentences, and qualify `:59` with "(claims: see below)".
12. **A-P2-12** `getting-started.md:174`, `:171`, also `README.md:162`: the spec examples omit `--plan`. [3.2.0 P2-7; README location new]
    - Doc says:
      - getting-started `:174`: `/doc-superpowers spec-verify --mode=post-execute --specs=<paths> --design-doc=<path>`;
      - getting-started `:171`: the execute example drops `[--plan=<path>]`;
      - README `:162`: the post-execute example has no `--plan`, although README's own `:171` says to pass it.
    - Code shows: `spec-lifecycle-actions.md:312`: "Claims enabled and no `--plan`: … step 0 reports 'claims verdict owed', never PASS". `:310` needs `--plan` for a full amendment check.
    - Suggested fix: show `[--plan=<path>]` in all three examples, and say `--plan` is required with `docs/spec-claims/`.

**docs/workflows/doc-superpowers.md**

13. **A-P2-13**: three spec-lifecycle diagrams predate claims. [3.2.0 P2-14]
    - Doc says:
      - `sequence-spec-inject` (`:601-628`): the plan phase is "Read plan → Identify chunk boundaries → Write plan with injected spec tasks", and the execute `alt` has only Aligned / Aligned-owned / Drifted.
      - `workflow-spec-verify` (`:683-697`): post-execute starts at "Existence check", and review at "Map changed files → specs".
      - `workflow-spec-generate` (`:534-553`): "Generate SPEC-CAT-NNN files → Populate code_refs".
    - Code shows (the doc's own text and the reference):
      - the chunk and final claims gates (`:574`; `spec-lifecycle-actions.md:206-216,264-273`, Task N+1g and N+2g);
      - the Amendment branch (`:592`; reference `:291-294`);
      - spec-verify step 0 `claims attest --final` (`:646`; `:312`) and review 3b/3c (`:673-674`; `:364-365`);
      - spec-generate 6b, the claim stubs (`:520`; `:139`).
    - Suggested fix: add these to the diagrams and re-render all three:
      - spec-inject: the gate injections and an `:amends` branch;
      - spec-verify: step-0 and 3b/3c nodes;
      - spec-generate: a 6b node.

      See A-P3-41 for spec-generate's layout.
14. **A-P2-14**: there is no state diagram. [3.2.0 P2-15]
    - Doc says: no living doc has a `stateDiagram`.
    - Code shows:
      - `references/doc-spec.md:964` requires `stateDiagram-v2` for "Each skill with state/recovery".
      - The next chunk resumes from the gate records (`spec-claims.md:60-61,360`).
      - The Spec Status Model ladder is at `spec-lifecycle-actions.md:7-30`, and claims have their own statuses.
    - Suggested fix: add an Internals state diagram under the agentic section. The ledger's states join it (T18-63).
15. **A-P2-15**: the artifacts are undocumented. [3.2.0 P2-16]
    - Doc says: `gates/<plan-stem>/chunk-<n>.json` is never named (`final.json` appears only in passing at `:353`). Update step 3 (`:281`) names no plan file.
    - Code shows:
      - `spec-claims.md:60-61`;
      - `SKILL.md:455`: "save a scoped plan to `docs/plans/YYYY-MM-DD-{scope}-doc-update-plan.md`";
      - the agentic inventory's Artifacts element (`SKILL.md:251,253`).
    - Suggested fix: add an `### Artifacts` table (audit report, scoped update plan, gate records, `docs/archive/plans/`, doc-index), and name the plan file in update step 3.
16. **A-P2-16** `:717-723`: Spec Lifecycle Routing has no claims column. [3.2.0 P2-17]
    - Doc says: the table has 4 columns (Pipeline Point | When | Action | Mode).
    - Code shows: `spec-lifecycle-protocol.md:9-17` has a fifth column, "With claims enabled": "Three of the points then become **gates with recorded verdicts**".
    - Suggested fix: add the column, or one sentence and a link. The ledger points join it (T18-59).
17. **A-P2-17** `:829-840`: User Interaction Gates misses three claims-era gates. [3.2.0 P2-18]
    - Doc says: the table has 10 rows, none for these.
    - Code shows:
      - spec-generate 5b, "Apply deprecation notices now?" (`spec-lifecycle-actions.md:123`; the doc's own `:518`);
      - the amendment batch reviewed in the PR description (`:271`, Task N+2g Step 4);
      - the direction ruling's `by` principal (`spec-lifecycle-protocol.md:139,146,150`).
    - Suggested fix: add three rows.
18. **A-P2-18** `:590`: the execute phase omits the `update-index` guard. [3.2.0 P2-19]
    - Doc says: "…call `update-index`. When the plan's `Task N+1` is the writer, report "aligned" and write nothing".
    - Code shows: `spec-lifecycle-actions.md:292` ends "It never calls `update-index` while a claim of that spec fails."
    - Suggested fix: append that sentence, for claims-enabled projects.
19. **A-P2-19** `:893-898`: the Verification Model has no claims layer. [3.2.0 P2-20]
    - Doc says: four layers: Agent evidence, Freshness check, Spec compliance, Human review.
    - Code shows: `SKILL.md:148`: "**Records a baseline reset, never a verification** … A verification verdict comes only from claims". The chunk and final gates record verdicts (`spec-lifecycle-protocol.md:13-17`).
    - Suggested fix: add a row "Claims verdict | `claims gate` per chunk, `claims attest --final` | claims-enabled projects". Describe the freshness layer as "baseline unchanged", not "verified".

**skills/doc-superpowers/SKILL.md**

20. **A-P2-20** `:192`: the command-line exit rules omit the claims family. [3.2.0 P2-34]
    - Doc says: "An option a subcommand does not take exits **2** …, as do the wrong number of arguments". `:163` says "3 usage", so the file contradicts itself.
    - Code shows: `doc-tools.sh:3211-3219` sets `_USAGE_RC=3` for `claims` (and `ledger`). The help's "Exit status" says "The claims and ledger subcommands have their own codes instead".
    - Suggested fix: add "(3 for a `claims` verb, where exit 1 means findings)". The ledger half of the same sentence is T18-13.

**references/hooks.md**

21. **A-P2-21** `:64`: the PR claims check is described too loosely. [3.2.0 P2-21]
    - Doc says: "`claims attest --plan <p> --final` for each plan the PR touches (its file or `final.json`)".
    - Code shows:
      - A plan is attested only when it is in config `plans`, has a `gates/<stem>/` directory, and is Completed or has `final.json` (`claims-check.sh:8-15,247-250`).
      - A PR that deletes a `docs/spec-claims/` that its base has is a finding (`claims-check.sh:83-95`; `spec-claims.md:17`).
    - Suggested fix: state the selection rule and the deletion guard.
22. **A-P2-22** `:64`: the test-environment setup has no durable home. [3.2.0 P2-22]
    - Doc says: "the host adds its test-environment setup before the claims step".
    - Code shows:
      - `doc-spec-verify.yml:99-101`: "in their own copy of this workflow".
      - Any `install --ci` refreshes a managed workflow (`:100`), which drops the added step.
      - The schedule (`doc-freshness-schedule.yml:42-51`) has no setup slot.
      - An `indeterminate` schedule run keeps the issue open forever, because `:140` closes it only on `disabled` or `ok`.
    - Suggested fix: name the unmanaged copy as the durable home, and document the schedule's missing slot and the issue that never closes.

**references/spec-claims.md**

23. **A-P2-23** `:362`: the attest cross-check is stricter than documented. [3.2.0 P2-24]
    - Doc says: "every ruling, promotion and status change since the merge-base appears in a chunk record or in `final.json`'s rebuilt reconciliations".
    - Code shows:
      - `_JQ_CLAIMS_ATTEST_CROSS` (`doc-tools.sh:11586-11596`) appends final.json's own unrecorded changes (`:11786-11789`), whatever the chunk records hold.
      - So a change after the last chunk head that final.json does not include is a silent reconciliation, even when an earlier chunk record has a matching entry.
      - The help (`:2324-2327`) covers this only in part.
    - Suggested fix: say so here. The help half is code (C-3).
24. **A-P2-24** `:240`: `from-remapped` is listed but not explained. [3.2.0 P2-25]
    - Doc says: the advisory list includes it, with no explanation.
    - Code shows: `doc-tools.sh:11491-11499,11745-11760`. A head that is not a commit here maps to the one branch commit with the same patch id. If there is none, or several, the result is indeterminate: "re-run the gate for chunk n".
    - Suggested fix: explain it.

**references/spec-lifecycle-actions.md**

25. **A-P2-25** `:214`: the chunk gate's Step 3 has no general re-run. [3.2.0 P2-26]
    - Doc says: Step 3 says "re-run Step 1" only for `--holds`, DOC-STALE→promote and the lint DOC-STALE.
    - Code shows: a ruling committed after Step 1 is a silent reconciliation for the next gate and for attest (`spec-claims.md:360`). The final gate has the loop (`:271`).
    - Suggested fix: "then re-run Step 1; repeat until it exits 0".
26. **A-P2-26** `:312`, `:347`: post-execute step 0 writes a file. [3.2.0 P2-27]
    - Doc says: step 0 runs `claims attest --plan <plan> --final`. The recovery at `:347` is to update CLAUDE.md/README.md and then re-run `spec-verify`.
    - Code shows: `attest --final` refuses a dirty tree and rewrites `final.json` (help, attest). So the recovery exits 2 while those edits are uncommitted.
    - Suggested fix: say that step 0 writes `final.json` and needs a clean tree, and have the recovery commit first.
27. **A-P2-27** `:316`, `:328`: a target held by R5 reads as skipped work. [3.2.0 P2-28]
    - Doc says: `:316`: "Still at `Draft`, `In Review`, or `Approved` means implementation tasks were skipped". Neither `:316` nor `:328`'s "Held short" exempts a target R5 holds.
    - Code shows: R5 (`:28`) holds a target short of `Implemented` until its claims pass.
    - Suggested fix: say that an R5-held target is not a finding.
28. **A-P2-28** `:288` vs `:293`: the execute phase contradicts itself. [3.2.0 P2-29]
    - Doc says: `:288` says the gate is the verifier and the phase "does not judge drift by agent". `:293` says to rule a Drifted deviation and "record the ruling in the sidecar".
    - Code shows: rulings are recorded at the chunk gate's Step 3, with `record` = `chunk-<n>.json` (`:214`; `spec-claims.md:360`).
    - Suggested fix: route `:293` to the chunk gate's Step 3.
29. **A-P2-29** `:108`: supersession has no claims handling. [3.2.0 P2-30]
    - Doc says: supersession `git mv`s the old spec.
    - Code shows: the sidecar's `doc` then names a missing path, which is a blocking V1 finding (`spec-claims.md:154`). Nothing retires the old spec's live claims first.
    - Suggested fix: retire the old spec's claims, or move its sidecar, before the move.
30. **A-P2-30**: nobody owns `Realized-by:`. [3.2.0 P2-31]
    - Doc says: no spec action writes the template's `Realized-by:` block (`doc-spec.md:234`).
    - Code shows: `set-implementation` exists for it (`doc-spec.md:351`; `SKILL.md:160`).
    - Suggested fix: name the action and step that runs it.

**references/spec-lifecycle-protocol.md**

31. **A-P2-31** `:175`: within a plan, reconciliation belongs at the gate. [3.2.0 P2-32]
    - Doc says: "Claims-enabled: a red claim or a flagged deviation → rule the direction … before editing either side".
    - Code shows: within a plan, the place to reconcile is the plan's `Claims gate (chunk N)`, and its record is the ruling's `record`. `integration-patterns.md:76` treats reconciling outside a gate as a finding.
    - Suggested fix: say so.

**references/agent-prompt-template.md**

32. **A-P2-32** `:61-77`: Spec-Aware Review has no claims rows. [3.2.0 P2-33]
    - Doc says: a target held by R5 matches `:68` ("Flag as P1 — spec wasn't updated during implementation"), and no "Not a finding" row overrides it.
    - Code shows: R5 (`spec-lifecycle-actions.md:28`). Nothing checks V8n's cite-or-`(unverified)` rule or the status block.
    - Suggested fix: add rows for an R5-held target (not a finding), V8n and the status block.

**references/doc-spec.md**

33. **A-P2-33** `:1050`: the exit-status list is incomplete. [3.2.0 P2-35]
    - Doc says: "`0` success; `1` …; `2` usage error".
    - Code shows: `doc-tools.sh --help` → "Exit status" also has `fragments merge`'s exit 3, and the claims family (1 findings, 2 could not run, 3 usage; precedence 1 > 2 > 0).
    - Suggested fix: add both. The ledger family is T18-70.

**evals/**

34. **A-P2-34** `evals/evals.json`: no eval covers claims. [3.2.0 P2-36]
    - Doc says: `grep -ci claim evals/evals.json` → 0. The 20 evals are unchanged.
    - Code shows: no eval covers `spec-inject --phase=plan`'s gate injection or its `**Claims:**` lines, post-execute step 0, review 3c, or the inert negation.
    - Suggested fix: add a claims-enabled eval and an inert-path negation, each with a `fixtures/<eval>/setup.sh`.

### P3 Style

**RELEASE-NOTES.md** (v3.2.0 entry; correct it in place)
1. **A-P3-1** [nit N1] `:59` says "Before, any capitalised prefix (`README#install`, `C#sharp`) read as an unknown claim id". The regex that c743712 replaced was `[A-Z][A-Z0-9-]*#…`, which matches only all-upper-case prefixes, so a capitalised `Readme#x` never matched. Fix: "any upper-case prefix".
2. **A-P3-2** [nit N2] `:11` says "The chunk gate and attest run every such claim their range moved into `built` or `gated`, whether or not a `**Claims:**` line names it".
   - In the code, `_JQ_CLAIMS_GATE_EDITED` (`doc-tools.sh:11048-11054`) keeps only ids in the plan's scope.
   - `_claims_plan_scope` (`:11056-11068`) builds that scope from three sets: the chunk's named ids, every `**Claims:**` id, and every claim of a doc that the Specs list names. The gate uses it at `:11247-11249` and attest at `:11766-11768`.
   - So a lint claim moved to `built` in a doc outside that scope is neither run nor reconciled.
   - The same unscoped sentence is at `spec-claims.md:358` (gate) and `:362` (attest). Only `:360` states the scope.
   - Fix: add "in the plan's scope (the claims its `**Claims:**` lines name and every claim of a doc its Specs list names)" at all three places. The two help lines are code (C-1).

**docs/architecture/system-overview.md**

3. **A-P3-3** [3.2.0 P3-55] `:154` says Claude uninstall removes "the three scripts". The uninstall loop iterates `$CLAUDE_HOOKS $CLAUDE_LIB` (`install.sh:1147-1156`), and `install.sh:26-28` owns `hook-lib.sh`. Fix: "… the three scripts and their `hook-lib.sh`". The ledger exception to this is T18-29.
4. **A-P3-4** [3.2.0 P3-56] `:115` and `:154` say "a global `core.hooksPath` is refused". `install.sh:683-704` refuses every scope but `local`/`worktree` ("global, system, a command-line -c"), and the help says "global or system" (`:155`). Fix: "a `core.hooksPath` from any config but the repository's own is refused". getting-started has the same root (A-P3-24).
5. **A-P3-5** [3.2.0 P3-57] `:116` says `fragment-lib.sh` is sourced by `extract-context.sh` and `commit-and-push.sh`. `verify-fragment.sh:23-30` sources it too. Fix: add it.
6. **A-P3-6** [3.2.0 P3-58] `:63` (also in the PNG) names REQUIRED references only for release and hooks, and the Tech Stack marks only `:119-120`. `SKILL.md:40,45,46` also make `agent-prompt-template`, `spec-lifecycle-actions` and `spec-claims` REQUIRED. Fix: "release, hooks and the spec actions first load their REQUIRED reference", mark `:118` REQUIRED, and re-render.
7. **A-P3-7** [3.2.0 P3-59] `:72` and `:117` describe `spec-lifecycle-protocol.md` without the Direction protocol, which it defines (`:127`). Fix: add "and the claims Direction protocol" to `:117`, and to `:72` at the re-render.
8. **A-P3-8** [3.2.0 P3-60] Edge labels in `c4-container.png` overlap. The PNG is unchanged since abfd5e2. The overlaps:
   - "Uses spec template from doc-spec…" prints over "Runs the vendored .github/scripts/doc-tools.sh…" on the Hooks Engine title;
   - "Registers it for docs/.doc-index.json" crosses "Reads/updates .doc-index.json…";
   - "Routes spec-generate…" crosses "Vendors doc-tools.sh…";
   - "Scans structure, scripts, skills, MCP configs" runs over Wrapper Skills.

   Fix: shorten labels or reorder the `Rel`s at the A-P2-5/6 re-render.
9. **A-P3-9** [3.2.0 P3-61, half fixed] The `code_refs` omit `evals/` and `.github/workflows/tests.yml`, which `:127-128` describe. The re-baseline half was fixed in ee02ae0. Because of this gap, `check-freshness` did not attribute tests.yml's new suite to this doc. Fix: `"$DOC_TOOLS" set-code-refs docs/architecture/system-overview.md --refs skills/doc-superpowers/SKILL.md,scripts/,references/,evals/,.github/workflows/tests.yml`.
10. **A-P3-10** [new] Some `c4-context.png` labels sit on unrelated boxes. The source (`:34-41`) is correct:
    - "Invokes /doc-superpowers <action>" prints over the doc-superpowers title;
    - "Reads code, writes docs, installs hooks" sits inside the Claude Code box;
    - "Content identity of code refs (object ids)…" sits inside Target Project.

    Fix: re-render with A-P2-6, using `UpdateRelStyle` offsets or a different element order.

**docs/codebase-guide.md**

11. **A-P3-11** [3.2.0 P3-62] `:184` gives `tools uninstall [--helper <dir>...]` and `tools status` without `[--dest <path>]` (`_VERBS` `:2690,2702`). Fix: add it to both.
12. **A-P3-12** [3.2.0 P3-63; CLAUDE.md locations new] The "direction protocol" is attributed to `spec-claims.md` at `codebase-guide.md:87,142,196` and `CLAUDE.md:80,133`. `spec-claims.md:383` says it is "defined in **Direction protocol** in `references/spec-lifecycle-protocol.md`; this reference does not repeat them". Fix: move it to the protocol rows (guide `:86,143,194`; CLAUDE.md `:79,134`). In the spec-claims rows, keep "the direction policy keys (config `policy`)".
13. **A-P3-13** [3.2.0 P3-64] The `code_refs` are `skills/doc-superpowers/SKILL.md` and `scripts/`, but the guide also maps `references/` (`:78-88,136-144`), `evals/` (`:112-114,155`) and tests.yml (`:26,152`). Fix: `"$DOC_TOOLS" set-code-refs docs/codebase-guide.md --refs skills/doc-superpowers/SKILL.md,scripts/,references/,evals/,.github/workflows/tests.yml`. Use tests.yml rather than `.github/`, whose vendored copies churn on every `install --ci`.
14. **A-P3-14** [new] The audit flow (`:245-257`) skips SKILL.md steps:
    - step 2: `check-freshness` through the discovery filter;
    - steps 3–5: the gap, naming and structure checks;
    - steps 6–8: CLAUDE.md, README.md and RELEASE-NOTES.md currency.

    It also shows the agentic comparison unconditionally, but `SKILL.md:399` runs it only "When auditing `workflows/`". Fix: add one line per omitted step, and qualify the agentic step.

**docs/conventions.md**

15. **A-P3-15** [3.2.0 P3-65; codebase-guide location new] Two places say `spec-verify` is read-only:
    - `conventions.md:320`: "`spec-verify` is read-only and writes no `Status`";
    - `codebase-guide.md:421`: "Reports status only — spec-verify is read-only", five lines after `:416` runs `claims attest --final`.

    Post-execute step 0 writes `final.json`, even when the run does not pass (`spec-claims.md:362`). Fix: "writes no `Status` (claims-enabled: step 0's `attest --final` writes `final.json`)".
16. **A-P3-16** [3.2.0 P3-66] `:286` says "The schedule closes its issue only after `status == 'ok'` with nothing stale or missing". `doc-freshness-schedule.yml` has two more conditions:
    - claims must also be `disabled` or `ok` (`:139-140`), and findings keep the issue open under "### Spec claims" (`:10,94`);
    - `no-index` with claims `ok` also closes it (`:141`).

    Fix: add both.
17. **A-P3-17** [3.2.0 P3-67] The drift bullet at `:83` names only `install --ci`. The drift step also fails on a missing `.gitattributes` merge-driver block, and then names `install --git` (`tests.yml:237,243`). Fix: add that half.
18. **A-P3-18** [3.2.0 P3-68] `:63-65` documents `feature/<name>` branches, and `:69-76` shows unscoped `feat:`/`fix:`.
    - The remote has no `feature/` branch. It has `feat/` (8), `claude/` (4), `fix/` (3), `design/` (2), `chore/` and `wip/`.
    - Commits use `type(scope):` and `release:`. Of the last 60: 37 `fix`, 16 `feat`, 7 `docs`.

    Fix: document those branch prefixes and the scoped form.
19. **A-P3-19** [3.2.0 P3-69] `:191` has "Diagrams | `kebab-case.{png,svg}`", and the table has no Plans, Templates or Index-files rows. `doc-spec.md:968` gives "`{type}-{name}.png` — or `{type}.png`" with no svg, and `:995-1000` has those rows. Fix: drop `.svg`, adopt the pattern, and add the rows.
20. **A-P3-20** [new] `:165` says "Missing tools trigger fallbacks, never failures:", but its own `jq` row (`:171`) is a failure. `check_deps` also fails without `sha256sum`/`shasum` (`doc-tools.sh:46-48`), which has no row. Fix: "Optional tools trigger fallbacks; a missing required tool fails, naming itself", and add the hash-tool row.

**docs/guides/getting-started.md**

21. **A-P3-21** [3.2.0 P3-70] The checklist (`:209-225`) names only `workflows/agentic`, and `:84` omits the `specs/` and `adr/` READMEs and templates. The *Scope → Generated Docs Matrix* (`SKILL.md:294-308`) also yields:
    - `architecture/{component}.md`, `erd.png` and `deployment.md`;
    - `workflows/agentic/README.md`;
    - the `## Testing` and `## Packages` sections;
    - the specs/adr README and template pairs ("Always").

    `SKILL.md:267,345` also allow `docs/decisions/`. Fix: add these, or link to the matrix.
22. **A-P3-22** [3.2.0 P3-71] `:67` says `code_oids` is "recorded when a doc is re-baselined". `build-index`, `add-entry` and `set-code-refs` record it too (help `:2097-2106,2130-2147`). Fix: "indexed or re-baselined".
23. **A-P3-23** [3.2.0 P3-72] `:126-127` shows `tools install  # → .github/scripts/doc-tools.sh`.
    - `tools` verbs are `deps`, not `repo` (`:2677,2690,2702`), so `--dest` resolves against the cwd (`cmd_tools_install`, `:5788`).
    - Shipping `doc-pr-release` also creates `RELEASE-NOTES.next/README.md` when it is absent (`:5805`).

    Fix: "run it from the repository's top level", and mention the README it creates.
24. **A-P3-24** [new] `:108` has two narrowings:
    - It says the installer "refuses … a global `core.hooksPath`". The installer refuses global or system (`install.sh:155`); this half has the same root as A-P3-4.
    - It says the Claude tier is "excluded from git through `.git/info/exclude`". The file is `git rev-parse --git-path info/exclude` (`install.sh:659`), which is not `.git/info/exclude` in a linked worktree or a submodule.

    Fix: "a global or system `core.hooksPath`" and "git's `info/exclude`".

**docs/workflows/doc-superpowers.md**

25. **A-P3-25** [3.2.0 P3-41] `:353` says the pre-push leg "ends with one `claims (advisory): <n> red, <m> indeterminate` line". In fact the leg prints one such line per pushed branch (`pre-push:20-22,87,94-106`). Fix: say "one line per pushed branch".
26. **A-P3-26** [3.2.0 P3-42] `workflow-hooks.png` (source `:455-461`) shows a literal `\n`.
    - The uninstall `--claude` node omits `hook-lib.sh` and the exclude block (`:436`).
    - The uninstall `--git` node omits the merge-driver and `.gitattributes` removal (`:435`).

    Fix: use `<br>`, add both removals, and re-render with T18-55.
27. **A-P3-27** [3.2.0 P3-43] `:863` declares `participant GP`, but no message uses it. The sequence covers only init, and it omits init step 4's per-skill Explore agent. General-purpose agents run in audit step 9, review-pr step 5, update step 3 and release step 5 (`SKILL.md:372,421,447`). Fix: drop `GP`, or add an audit/update lane.
28. **A-P3-28** [3.2.0 P3-44] `:570-575` numbers the plan phase 1, 2, 3, 4, 4b, 5. The reference numbers it 1, 1b, 2, 2b (Task N+1g), 3, 4, 4b (Task N+2g), 5 (`spec-lifecycle-actions.md:183-275`). Fix: mirror the reference and name the tasks.
29. **A-P3-29** [3.2.0 P3-45] `:212` numbers the dispatch as audit step 8, and `:821` says "audit step 8". `SKILL.md:367-368` splits naming and structure, so dispatch is step 9 (`:372`). Fix: renumber, and make `:821` "audit step 9".
30. **A-P3-30** [3.2.0 P3-46] `:210` and `:318` compare README "against actual SKILL.md actions", and `:150` and `:283` say "update feature list, action list, and usage examples". SKILL.md uses project-neutral wording: "against the project's own code and interfaces" (`:370`), "against the project itself" (`:514`), and "what it says about the project's own features, commands and usage" (`:351,469`). Fix: use SKILL.md's wording.
31. **A-P3-31** [3.2.0 P3-47] `:657-658` give spec-verify's PASS/FAIL without the claims clause. `spec-lifecycle-actions.md:342-343` makes PASS need "(claims disabled OR `claims attest --final` exit 0)", and says exit 2 is never PASS. Fix: add the clause to both bullets.
32. **A-P3-32** [3.2.0 P3-48] `:492` says "It refuses (exit 3; 1 is any other failure)". `release.md:21` says "Any other non-zero exit (1, 2) is a failure". Fix: use that wording.
33. **A-P3-33** [3.2.0 P3-49] `:806` says "one per scope" for update's agents, but `:822` says "(per doc)". `SKILL.md:447` dispatches "For each stale doc". Fix: "one per scope (`audit`, `review-pr`) or per stale doc (`update`)".
34. **A-P3-34** [3.2.0 P3-50] `:7`, `:58` and `:315` say the project's scripts are "listed, never run". `SKILL.md:91` allows a run when the user asks for one by name, never in `review-pr` or CI. Fix: "never run unasked (never in `review-pr` or CI)".
35. **A-P3-35** [3.2.0 P3-51] `:371` says `--ci-strict` will "Fail PR check on stale docs".
    - `doc-spec-verify.yml:131` passes STRICT to the claims step.
    - `claims-check.sh:22-24,113` fails an indeterminate run under STRICT.
    - The installer help already says this (`install.sh:193-197`).

    Fix: add the claims-job half.
36. **A-P3-36** [3.2.0 P3-52] The Sub-Agents table (`:815-825`) omits the claims-gate judge, and `:825` says "The spec actions dispatch no agent". The gate tasks may dispatch a judge (`spec-lifecycle-actions.md:210,268`). Fix: add the row, and qualify `:825`.
37. **A-P3-37** [3.2.0 P3-53; the naming half is exempt] `workflow-doc-superpowers.png` (source `:775-794`) misrepresents most actions:
    - It routes every action through "Dispatch parallel agents". Only init, audit, review-pr and update dispatch in parallel; release dispatches one agent; hooks, sync, diagram and the spec actions dispatch none (Steps table `:805-809`).
    - It applies its Phase 3 to every action. The verification gate is for update and init only (`SKILL.md:547`); audit writes only its report, and review-pr writes nothing (`:25-26`).
    - Its Phase 1 omits the baseline `check-freshness` (`SKILL.md:219-224`).

    Fix: branch Phase 2 by dispatch kind, scope Phase 3 to the writing actions, add the baseline check to Phase 1, and re-render.
38. **A-P3-38** [3.2.0 P3-54] The Gates table (`:829-840`) lacks two gates:
    - the weekly `run --judge-sample` reviewer (`spec-claims.md:203,379`);
    - review-pr asking for a missing base (`SKILL.md:418`).

    Fix: add both.
39. **A-P3-39** [new] Release step 12 (`:501`) and the tag-confirmation row (`:838`) omit the offer to backfill older untagged versions (`release.md:36`). Fix: add the offer to both.
40. **A-P3-40** [new] `:431` says "pre-push: the ref lines go to both". Since 81b6c35, the integrated block exits 1 when its copy of the ref lines fails, with "doc-superpowers: push refused: git's ref lines could not be copied…" (`install.sh:712-715,726-732`; `hooks.md:35`). Fix: "…through a temp copy that becomes the user hook's stdin again; a copy that fails refuses the push (exit 1)".
41. **A-P3-41** [new] `workflow-spec-generate.png` (`:528`) is 784×52 px. Its three LR subgraphs render as an unreadable strip. Fix: at the A-P2-13 re-render, use `flowchart TD` or stacked subgraphs, as `workflow-spec-verify.png` (620×1480) does.
42. **A-P3-42** [new] `sequence-audit` (`:225-252`) omits the orchestrator's own checks: steps 3–8 and step 11 (`SKILL.md:366-371,394,399`). Fix: add two `O->>O` messages, then re-render.
43. **A-P3-43** [new] `:896` gives the freshness check's timing as "After update". `SKILL.md:547` runs it after `update` or `init`, and init step 13 runs it after the commit (`SKILL.md:357`). Fix: "After `init` (post-commit) and `update`".

**skills/doc-superpowers/SKILL.md**

44. **A-P3-44** [3.2.0 P3-1] R5 is restated without `gated` in five places:
    - `SKILL.md:540`: "every claim the plan names for it is `built` and passing at the final gate";
    - `spec-lifecycle-protocol.md:14`, which also widens the rule to all the spec's claims;
    - `conventions.md:314`, which has no `gated`;
    - `conventions.md:320`, which has `gated` but not the `:amends` clause;
    - `system-overview.md:168`.

    The canon is `spec-lifecycle-actions.md:28`: "…with the configuration extension, `gated` also qualifies. `:amends` specs remain exempt from `Status` writes but not from claim checks". `:9` adds: "Do not restate these rules elsewhere — cite this section." Fix: cite **Spec Status Model → R5** at all five places.
45. **A-P3-45** [3.2.0 P3-2] `:163` says "Prints one verdict JSON object", but `claims rulings --format markdown` prints Markdown.
46. **A-P3-46** [3.2.0 P3-3] `:148` says "A verification verdict comes only from claims (`claims run` / `attest`)". This omits `promote`, which stores verdicts.
47. **A-P3-47** [3.2.0 P3-4] `:152` says "`code_commit` becomes the older of the two baselines". The set-code-refs help gives three cases: kept, derived, and merge-base for mixed.
48. **A-P3-48** [3.2.0 P3-5] `:151` says move-entry preserves "every other field", but the help says `content_hash` is recomputed.
49. **A-P3-49** [3.2.0 P3-6] `:226` says "For one doc's full entry run `status <doc>`", but `status` returns only the verdict and the path. Fix: point to `jq '.docs["<doc>"]' docs/.doc-index.json`.
50. **A-P3-50** [3.2.0 P3-7] The jq row at `:590` says the error names `jq >= 1.6` and the version found. A missing jq prints only "required command not found: jq" (`doc-tools.sh:32-35`). The version text is printed only for a jq that is too old (`:42`).
51. **A-P3-51** [3.2.0 P3-8] `:91` lists `scripts/*validate*`, but the find at `:141` matches only `*validate_docs*` and `*validate_doc_references*`.
52. **A-P3-52** [3.2.0 P3-9] Audit step 8 (`:371`) counts commits "after that date (or after the matching git tag)". `release.md:15` uses the tag, else the commit that added the heading. Fix: use one rule.
53. **A-P3-53** [3.2.0 P3-10] `:136`'s list of commands not granted in CI omits `jq`. The `respond` job of `doc-review-pr.yml` (`:152`) grants no `Bash(jq:*)`, yet discovery's filter (`:223`) pipes through jq.
54. **A-P3-54** [3.2.0 P3-11] The `testing` globs at `:211` miss `test-*` and `test_*`, so this repo's `scripts/test-*.sh` do not trigger the `testing` scope.

**references/hooks.md**

55. **A-P3-55** [3.2.0 P3-34] `:138` says that with "no section and a body ending inside an unclosed fence", the edit is refused. For a named section, `update-pr-body.sh:146-149` turns exit 8 into 7 and inserts at the top.
56. **A-P3-56** [3.2.0 P3-35] `:128` says "Push to non-main", but the trigger is `branches-ignore: [__BASE_BRANCH__]`.
57. **A-P3-57** [3.2.0 P3-36; README location new] `--all` is missing from two status synopses, though `install.sh help` accepts it for status:
    - `hooks.md:11`: `hooks status [--git] [--claude] [--ci] [--ledger] [--ledger-claude]`;
    - `README.md:213`: "(optionally one tier: --git / --claude / --ci)".

    Fix: add `--all` to both.
58. **A-P3-58** [3.2.0 P3-38] QUIET is undocumented for the claims legs:
    - pre-push exits on `DOC_SUPERPOWERS_QUIET=1` before its claims leg runs (`pre-push:26`);
    - pre-commit's leg runs anyway and can block silently (`pre-commit:12,38`).

    hooks.md mentions QUIET only for the Claude gate (`:28`).
59. **A-P3-59** [3.2.0 P3-40] `:142-151` says "Every template's `run:` steps are scripts in `.github/scripts/doc-superpowers-steps/`". Two are not:
    - `doc-spec-verify.yml:148` runs `.github/scripts/doc-pr-release/update-pr-body.sh` (`:138` half-says this);
    - `doc-pr-release.yml:74` is an inline `run: |`.

**references/spec-claims.md**

60. **A-P3-60** [3.2.0 P3-16] `:240` lists `re-promote owed` among the advisories that never block. In gate and attest it is a finding (help).
61. **A-P3-61** [3.2.0 P3-17] `:92` and `:240` say "every finding blocks" in `run`, `promote`, `gate` and `attest`. `render` also sets `_CL_ALL_BLOCKING=1` (`doc-tools.sh:11420-11421`).
62. **A-P3-62** [3.2.0 P3-18; SKILL.md and README locations new] Three places overstate the inert contract:
    - `spec-claims.md:15`: "The order of argument handling makes that hold for every invocation";
    - `SKILL.md:163`: "Without `docs/spec-claims/` every verb … exits 0";
    - `README.md:179`.

    `_main` (`doc-tools.sh:3268-3270`) runs `check_deps` and `_require_repo` before the inert check. So outside a repo, below the top level, or without jq ≥ 1.6, an inert project exits 2 with `"enabled":true`. Fix: qualify all three.
63. **A-P3-63** [3.2.0 P3-19] The V1 row (`:244`) and the extension's V1 bullet (`:343`) omit the canonical-number rule for `when` (`cl_canonical_num`, `doc-tools.sh:6651-6703`). Only `:152` has it.
64. **A-P3-64** [3.2.0 P3-20] `:201`: the lint tier's "Run by" names `validate` and `run`. `gate` and `attest` run lint claims too (`_claims_run_selected`, `:11253`).
65. **A-P3-65** [nit N3] `:226` and `:347-350` give remedies that assume test claims: "run claims promote <id>", "promote re-gates it", "fix the code and promote the claim".
    - Since a5dbdfd, a `lint`, `log` or `judge` claim enters `built` or `gated` by a reviewed status edit.
    - `promote` refuses non-test claims, and V6's remedy for one is "remove its promotion" (`doc-tools.sh:7489`).
    - V10 still selects any gated, built or diverged claim.

    Fix: branch the remedy on `enforced_by`. A non-test claim gets "move it to built by a reviewed status edit", or "rule, then edit its status". The V10 messages and the extension help are code (C-2).

**references/spec-lifecycle-actions.md**

66. **A-P3-66** [3.2.0 P3-21] `:361` says "Pipe the changed files, one per line". Fix: give the `git diff -z --name-only --no-renames` form (`SKILL.md:198`).
67. **A-P3-67** [3.2.0 P3-22] `:365` uses `<base>`, but review mode's inputs (`:355-359`) define none.
68. **A-P3-68** [new] `:109` says "Create a new spec with the next sequential number (e.g., AUTH-002 if AUTH-001 exists)". `:134` makes the number one past the highest in `docs/specs/` **and** `docs/archive/specs/`, never reused. That is the rule 3.2.0 P1-8 fixed in conventions. Fix: cite step 6's rule.

**references/spec-lifecycle-protocol.md**

69. **A-P3-69** [3.2.0 P3-23] `:17` says "Three of the points then become **gates with recorded verdicts**". Only the chunk gate and the final gate write records; review records nothing.

**references/agent-prompt-template.md**

70. **A-P3-70** [3.2.0 P3-29] The VERIFICATION block at `:31-32` is shorter than the one `SKILL.md:569-571` requires in every dispatched prompt.
71. **A-P3-71** [3.2.0 P3-30] Step 3 (`:15`) asks for "Accurate sections", but the output format (`:34-41`) has no slot for them.

**references/integration-patterns.md**

72. **A-P3-72** [3.2.0 P3-24] `:74` says `spec-verify --mode=post-execute` "reports its verdict", but its step 0 writes `final.json` (A-P2-26).
73. **A-P3-73** [3.2.0 P3-25] `:69` says "the same five actions". The protocol has 5 interception points and 3 actions (`spec-lifecycle-protocol.md:7`).

**references/output-templates.md**

74. **A-P3-74** [3.2.0 P3-26] `:114` has `{0 | 1 | 2 — claims verdict owed}`, with no entry for the no-`--plan` case (`spec-lifecycle-actions.md:312`).
75. **A-P3-75** [3.2.0 P3-27] `:127` says "Held at `In Review` (or left at `Approved`)", but `spec-lifecycle-actions.md:328` says "Held short of `Implemented`".
76. **A-P3-76** [3.2.0 P3-28] `:14` has "Fresh | Stale | Missing coverage | Untracked", with no slot for `check-freshness`'s `missing` and `deprecated`. This report adds "also Deprecated" by hand.

**references/doc-spec.md**

77. **A-P3-77** [3.2.0 P3-33] `:1034` uses "the CI coverage gate", a downstream term. Fix: "the CI freshness check".

**references/release.md**

78. **A-P3-78** [3.2.0 P3-32] `:7-8` says `RELEASE-NOTES.next/README.md` is placed by "`hooks install --ci` / `tools install`". Only the doc-pr-release helpers place it: `--with-helpers` or `--helper doc-pr-release`, or while `doc-pr-release` is installed (`hooks.md:114`). Fix: point to `$ROOT/scripts/hooks/ci/doc-pr-release/RELEASE-NOTES.next.README.md`.

**references/tool-mappings.md**

79. **A-P3-79** [3.2.0 P3-31] `:36` lists "Subagent dispatch (`init`, `audit`, `review-pr`, `update`)". `release` also dispatches a general-purpose drafter (`release.md:23`).

**scripts/hooks/ci/doc-pr-release/RELEASE-NOTES.next.README.md**

80. **A-P3-80** [3.2.0 P3-39] Two skip rules are wrong:
    - The skip list (`:108-111`) omits two reasons: "the no-notes marker together with notes" (`doc-tools.sh:4968`) and "an empty ### heading" (`:5020`).
    - `:140-141` says an empty fragment is skipped "as 'no notes'". A 0-byte file is skipped as "an empty file" (`:5172,5348`).

Not counted (optional): the heading `RELEASE-NOTES.md:3` reads `## v3.2.0 (2026-10-14)`, but the release commit ee02ae0 and the tagged merge 41ff1bc are both dated 2026-10-15 (local time). This is harmless: step 8 and `fragments merge` use the tag.

### Structural / coverage observations (no action taken)
- P2-1 stays resolved. `docs/conventions.md:206-212` (42797cf) records this repo's exemptions from the Scope → Generated Docs Matrix, and it was checked against the code:
  - `doc-spec.md:219,287` hold the template sections;
  - the repo has no `docs/specs/` and no `docs/adr/`;
  - CI is tests.yml plus the two freshness workflows;
  - the agentic flow is in the workflows doc.

  The `docs/workflows/agentic/` layout, the overview's name and `agentic-overview.png` are exempt, so they are not re-raised (A-P3-37 keeps only the routing half).
- Agentic inventory (step 11):
  - Discovery finds 1 skill, no `.claude/commands/` and no MCP config.
  - The workflows doc has the Pipeline, Steps, Sub-Agents, Gates, MCP Tools, Sequence and Verification Model elements.
  - It lacks Artifacts and State (A-P2-14, A-P2-15), a judge in Sub-Agents (A-P3-36), and five gates (A-P2-17, A-P3-38, A-P3-39).
- The self-installed CI tier has drifted. `.github/scripts/doc-tools.sh` differs from `scripts/doc-tools.sh` (`cmp`: line 1421; last synced in 687dc9c), so tests.yml's drift step would fail. The docs' rule is right; the fix is code (T17-2). The 10 step scripts match.
- `check-version` passes at v3.2.0, as expected before the 3.3.0 bump.

### CLAUDE.md Status
- [ ] Directory Structure: **stale**.
  - The ledger paths are missing, and `:55` says `hook-lib.sh` is sourced by "all three" (T18-1).
  - `:29` says "the six suites" (U1).
- [ ] Key Files: **stale**.
  - `:116` says "18 subcommands"; there are no ledger rows and no `test-ledger.sh` row; the `install.sh` row omits the ledger sets (T18-2).
  - `:146` says "the six suites" (U1).
  - `:133` credits the direction protocol to `spec-claims.md` (A-P3-12).
- [ ] Commands: **stale**. No `--ledger` / `--ledger-claude` (T18-3).
- [ ] Conventions → Testing: **stale**. Hooks 1097 → 1345, `test-ledger.sh` (2681) is missing, and the total 7483 → 10412 (A-P1-1).

### README.md Status
- [ ] Feature list: **stale**. No claims bullet (A-P2-3) and no ledger bullet (T18-5).
- [ ] Command / API list: **stale**.
  - "Silent when absent" is false for the claims legs (A-P1-2).
  - The claims legs and `DOC_SUPERPOWERS_CLAIMS_SKIP` are missing (A-P2-1), as are the CI claims job and strict half (A-P2-2), and git ≥ 2.36 (A-P2-4).
  - `--all` is missing from status (A-P3-57), and the inert contract is overstated (A-P3-62).
  - The ledger sets, legs, skip variable, tree and `gh` are missing, and the suite count is "six" (T18-4, T18-6–T18-9).
- [ ] Usage examples: **stale**. The post-execute example lacks `--plan` (A-P2-12).

### RELEASE-NOTES.md Status
- [ ] **62 commits unreleased since v3.2.0** (the tag is at 41ff1bc, 2026-10-15; the heading says 2026-10-14).
  - This is expected before the 3.3.0 release. The manifests are at 3.2.0, and `check-version` passes.
  - 61 of the commits are ledger work. 81b6c35 also makes the git tier's integrated pre-push block fail closed. The one other non-ledger commit is 42797cf, the conventions exemption.
  - The 3.3.0 entry is Task 18's fragment (T18-10).
  - Two wording nits in the v3.2.0 entry are A items (A-P3-1, A-P3-2).

### Actions
- Run `/doc-superpowers update --report=docs/plans/2026-10-15-audit-report.md` to apply the Update Tasks below.
- Run `doc-tools.sh update-index <doc>` after manual review, with the U38 caveat: not before a doc's Appendix A items land.
- CLAUDE.md is flagged stale above. Update its Testing paragraph per the `references/doc-spec.md` CLAUDE.md rules (U1, U2). Its ledger tree, Key Files and Commands are Task 18's (T18-1 to T18-3).
- README.md is flagged stale above. Update it per the `references/doc-spec.md` README.md rules (U3–U5). Its ledger content is Task 18's (T18-4 to T18-9).
- RELEASE-NOTES.md: do not draft 3.3.0 here. Task 18 writes the fragment, and the release session merges it. Fix the two v3.2.0 nits in place (U6).

## Update Tasks

**Generated by:** /doc-superpowers audit
**Branch:** design/work-ledger

### Scope
`all`, which covered:
- the scopes `application`, `ci-cd`, `agentic` and `spec` (records only), and the always-generated docs;
- `CLAUDE.md`, `README.md`, `RELEASE-NOTES.md`, `SKILL.md` and `references/`;
- `AGENTS.md`, `GEMINI.md` and the INSTALL guides;
- the help text and `evals/`.

These tasks cover bucket A only. Appendix A (ledger docs) is Task 18's, and Appendix B (code) is Task 17's.

### Findings Summary
| Priority | Count | Action |
|----------|-------|--------|
| P0 Critical | 0 | Must fix before merge |
| P1 Stale | 2 | Update recommended |
| P2 Incomplete | 34 | Add coverage |
| P3 Style | 80 | Low priority |

Tasks are numbered U1–U38 in execution order (see *Execution*). Each sits under its priority.

### P0 — Critical Updates
- None.

### P1 — Stale Updates
- [ ] **U1** `CLAUDE.md` Conventions → Testing (A-P1-1).
  - Rewrite the paragraph for seven suites: `test-doc-tools.sh` (1377 assertions), `test-hooks.sh` (1345), `test-spec-status-model.sh` (641), `test-doc-pr-release.sh` (601), `test-merge-driver.sh` (600), `test-spec-claims.sh` (3167), `test-ledger.sh` (2681), **10412 total**.
  - Write "All seven run in CI" and "run all seven under both interpreters", and add `ledger` to the `for s in …` loop.
  - At `:29` and `:146`, "the six suites" → "the seven suites".
  - The suite-list addition is Task 18's ledger item, folded in here (ruling 6).
  - Leave the jq-1.7 guard sentence as it is: T17-1 makes it true for the ledger code.
  - The `test-ledger.sh` tree line and Key Files row stay with T18-1 and T18-2.
- [ ] **U3** `README.md:232`: the claims legs run without an index (A-P1-2).

### P2 — Missing Coverage
- [ ] **U4** `README.md`:
  - the claims legs and `DOC_SUPERPOWERS_CLAIMS_SKIP` (A-P2-1);
  - the CI claims job, the schedule step and `--ci-strict` (A-P2-2);
  - the claims feature bullet (A-P2-3);
  - git ≥ 2.36 at `:399` (A-P2-4);
  - `--plan` in the `:162` example (A-P2-12).
- [ ] **U7** `docs/architecture/system-overview.md`:
  - a Spec Claims container, its stores and a Tech Stack row (A-P2-5);
  - host adapters, `doctools → project` and the CI claims legs in the C4 diagrams (A-P2-6);
  - the claims hook legs and a Key Decision (A-P2-7).

  Re-render both PNGs once, together with U8, and with Task 18's ledger edits if they have landed.
- [ ] **U9** `docs/codebase-guide.md`: a spec-claims Code Flow (A-P2-8).
- [ ] **U11** `docs/conventions.md`: spec-claims naming and directories (A-P2-9); a `## Code Style` section (A-P2-10).
- [ ] **U13** `docs/guides/getting-started.md`:
  - prerequisites: bash ≥ 3.2, `sha256sum`/`shasum`, git ≥ 2.36 (A-P2-4);
  - what opting in to claims implies (A-P2-11);
  - `--plan` in both spec examples (A-P2-12).
- [ ] **U15** `docs/workflows/doc-superpowers.md`:
  - re-render the three claims-era diagrams (A-P2-13);
  - a state diagram (A-P2-14);
  - an Artifacts table and the update plan file (A-P2-15);
  - a claims column in routing (A-P2-16);
  - three gates (A-P2-17);
  - the `update-index` guard (A-P2-18);
  - a claims verification layer (A-P2-19).
- [ ] **U17** `skills/doc-superpowers/SKILL.md:192`: the claims exit family (A-P2-20). The ledger half is T18-13.
- [ ] **U19** `references/hooks.md`: the plan selection and deletion guard (A-P2-21); a durable setup home and the never-closing schedule issue (A-P2-22).
- [ ] **U21** `references/spec-claims.md`: the stricter attest cross-check, doc half (A-P2-23); `from-remapped` (A-P2-24).
- [ ] **U23** `references/spec-lifecycle-actions.md`:
  - the chunk-gate re-run loop (A-P2-25);
  - step 0 writes `final.json` and needs a clean tree (A-P2-26);
  - an R5-held target is not a finding (A-P2-27);
  - route execute-phase rulings to the gate (A-P2-28);
  - supersession retires claims (A-P2-29);
  - who runs `set-implementation` for `Realized-by:` (A-P2-30).
- [ ] **U25** `references/spec-lifecycle-protocol.md:175`: reconcile at the chunk gate within a plan (A-P2-31).
- [ ] **U27** `references/agent-prompt-template.md`: claims rows in Spec-Aware Review (A-P2-32).
- [ ] **U31** `references/doc-spec.md:1050`: the claims exit family and `fragments merge` exit 3 (A-P2-33). The ledger family is T18-70.
- [ ] **U36** `evals/`: a claims-enabled eval and an inert-path negation, with fixtures (A-P2-34).

### P3 — Style
- [ ] **U2** `CLAUDE.md:80,133`: move "direction protocol" to the protocol rows `:79,134` (A-P3-12).
- [ ] **U5** `README.md`: `--all` in the `:213` status comment (A-P3-57); qualify the inert contract at `:179` (A-P3-62).
- [ ] **U6** `RELEASE-NOTES.md` v3.2.0, in place: "upper-case" at `:59` (A-P3-1); the plan's scope at `:11` (A-P3-2).
- [ ] **U8** `docs/architecture/system-overview.md`:
  - apply A-P3-3 … A-P3-10, and A-P3-44 at `:168`;
  - for A-P3-9, run `set-code-refs` to add `evals/` and `.github/workflows/tests.yml`;
  - re-render with U7.
- [ ] **U10** `docs/codebase-guide.md`:
  - apply A-P3-11, A-P3-12 (`:87,142,196`), A-P3-13, A-P3-14, and A-P3-15 at `:421`;
  - for A-P3-13, run `set-code-refs` to add `references/`, `evals/` and `.github/workflows/tests.yml`.
- [ ] **U12** `docs/conventions.md`: A-P3-15 (`:320`), A-P3-16 … A-P3-20, A-P3-44 (`:314`, `:320`).
- [ ] **U14** `docs/guides/getting-started.md`: A-P3-21 … A-P3-24.
- [ ] **U16** `docs/workflows/doc-superpowers.md`: A-P3-25 … A-P3-43, re-rendering together with U15.
- [ ] **U18** `skills/doc-superpowers/SKILL.md`: A-P3-44 (`:540`), A-P3-45 … A-P3-54, A-P3-62 (`:163`).
- [ ] **U20** `references/hooks.md`: A-P3-55 … A-P3-59 (A-P3-57 at `:11`).
- [ ] **U22** `references/spec-claims.md`: A-P3-2 (`:358`, `:362`) and A-P3-60 … A-P3-65 (doc halves only).
- [ ] **U24** `references/spec-lifecycle-actions.md`: A-P3-66, A-P3-67, A-P3-68.
- [ ] **U26** `references/spec-lifecycle-protocol.md`: A-P3-44 (`:14`), A-P3-69.
- [ ] **U28** `references/agent-prompt-template.md`: A-P3-70, A-P3-71.
- [ ] **U29** `references/integration-patterns.md`: A-P3-72, A-P3-73.
- [ ] **U30** `references/output-templates.md`: A-P3-74, A-P3-75, A-P3-76.
- [ ] **U32** `references/doc-spec.md:1034`: A-P3-77.
- [ ] **U33** `references/release.md:7-8`: A-P3-78.
- [ ] **U34** `references/tool-mappings.md:36`: A-P3-79.
- [ ] **U35** `scripts/hooks/ci/doc-pr-release/RELEASE-NOTES.next.README.md`: A-P3-80.

### Index — Untracked Entries and Re-baseline
- [ ] **U37** Index the two untracked records with `add-entry`. They are records, so they have no code refs and are never stale:
  ```bash
  printf '%s\n' \
    'docs/superpowers/plans/2026-10-12-work-ledger.md::plan' \
    'docs/superpowers/specs/2026-10-12-work-ledger-design.md::design-spec' \
    | "$DOC_TOOLS" add-entry
  ```
  When the controller moves this report into `docs/plans/`, index it the same way (`docs/plans/2026-10-15-audit-report.md::plan`), as the 2026-10-14 report is indexed.
- [ ] **U38** Re-baseline each living doc after its edits.
  - The docs are `system-overview.md`, `codebase-guide.md`, `conventions.md`, `getting-started.md` and `workflows/doc-superpowers.md`.
  - For each one: run U8's and U10's `set-code-refs` first; read the doc against its `code_refs`; then run `"$DOC_TOOLS" update-index <doc>`.
  - All five are stale only because of ledger code. **Re-baseline a doc only once its Appendix A items have also landed.** If Task 18 has not landed yet, leave U38 open for that doc and say so: re-baselining it now would record the ledger gap as verified.
  - `conventions.md` is also `doc_modified` by 42797cf. That section is accurate and stays.

### Execution
Run `/doc-superpowers update --report=docs/plans/2026-10-15-audit-report.md` to apply these tasks.
- **Order:** apply the tasks in U-number order, which is file order: CLAUDE.md → README.md → RELEASE-NOTES.md → `docs/` → SKILL.md and `references/` → `evals/` → the index. The section a task sits in gives only its priority. The docs link to CLAUDE.md's figures, so U1 lands first.
- **Appendix A** items are not Update Tasks: Task 18 writes them. Where an A task and Task 18 both touch one diagram, re-render it once, after both. These diagrams are system-overview's two C4 PNGs, and the workflows doc's hooks, spec-inject, spec-verify, spec-generate, init and pipeline-overview PNGs.
- **Appendix B** items are code. `update` reports them and does not edit `scripts/` or `.github/`. After any change there, run `bash scripts/hooks/install.sh install --ci` and commit what it writes.

---

## Appendix A — Owned by Task 18 (3.3.0 ledger docs)

This appendix holds bucket B. It is not update work: it is Task 18's checklist, grouped by file. Severity is what the doc says today against the 3.3.0 code. **73 items: P1 16 · P2 42 · P3 15.**

**What Task 18 covers today.** Its file list (`docs/superpowers/plans/2026-10-12-work-ledger.md:327-336`) names:
- `references/ledger.md`, `RELEASE-NOTES.next/ledger.md` and SKILL.md;
- `spec-lifecycle-actions.md` and `integration-patterns.md`;
- README.md, CLAUDE.md, `docs/conventions.md:82` and the design doc.

Files marked *(not in Task 18's list)* need adding to it:
- `system-overview.md`, `codebase-guide.md`, `getting-started.md`, and `workflows/doc-superpowers.md` with its PNGs;
- `hooks.md` (one line), `spec-lifecycle-protocol.md`, `doc-spec.md` and `tool-mappings.md`;
- the client guides and `evals/`.

**Other notes for Task 18:**
- Step 3 says "manifests stay 3.1.0". At 0f6f467 they are 3.2.0, and `check-version` passes.
- **Follow the code's flag names.** Design §J says `install --ledger` "and, with `--claude`, the Claude events". The code ships a separate `--ledger-claude` (`install.sh:132-134,176-185`).
- **Dependencies on Task 17:**
  - Once T17-4 makes the ledger legs honour `DOC_SUPERPOWERS_SKIP`, "bypass all hooks" is true again, and T18-4, T18-19 and T18-50 shrink to documenting the ledger-only switch.
  - Once Task 17's `ledger` helper set lands, T18-13 and T18-48 describe `tools install --helper ledger` instead of "a vendored copy exits 2".

**CLAUDE.md**
- [ ] **T18-1 [P1]** Add the ledger paths to the Directory Structure tree (`:41-82`):
  - `scripts/ledger/` (18 files: `adapters.sh config.jq defs.jq fm-write.awk frontmatter.awk glob.sh index.sh inflight.sh init.sh keys.sh lib.sh parse.sh query.sh relations.sh render-html.jq render-md.jq validate.sh views.sh`);
  - `scripts/adapters/` (`ledger-items-gh.sh`, `ledger-pr-gh.sh`);
  - `scripts/test-ledger.sh` and `scripts/bench-ledger.sh`;
  - `references/ledger-index.schema.json`, and `references/ledger.md`;
  - `scripts/hooks/git/ledger-{pre-commit,pre-push,post-commit}` and `scripts/hooks/claude/ledger-{session-notices,state-watch}.sh`.

  Also, `:55` says `hook-lib.sh` is sourced by "all three": five scripts source it now.
- [ ] **T18-2 [P2]** Key Files:
  - `:116` (and the `:42` tree comment): "18 subcommands" → 19, adding `ledger` (`show|ls|find|related|sweep|recheck|inflight|notices|new|assign|link|note|view|validate|publish|finalize|init`).
  - Add rows for `scripts/ledger/`, `scripts/adapters/`, `references/ledger.md`, `ledger-index.schema.json`, `bench-ledger.sh` and `test-ledger.sh`.
  - `:127`, the `install.sh` row: add the two opt-in ledger sets.
- [ ] **T18-3 [P2]** Commands (`:160-162`): `hooks install|status|uninstall` take `--ledger` and `--ledger-claude`, and `--all` covers neither.
- *(The Testing paragraph's suite list is done in U1, per ruling 6. Task 18 skips it.)*

**README.md**
- [ ] **T18-4 [P1]** `:232` "Set `DOC_SUPERPOWERS_SKIP=1` to bypass all hooks temporarily" is false for the ledger legs, which read only `DOC_SUPERPOWERS_LEDGER_SKIP`:
  - `ledger-pre-commit:6`, `ledger-pre-push:17` and `ledger-post-commit:15`;
  - `ledger-session-notices.sh:22` and `ledger-state-watch.sh:28`.

  The ledger block also runs before the git tier's own SKIP exit. After T17-4, add `DOC_SUPERPOWERS_LEDGER_SKIP` and `DOC_TOOLS_LEDGER_OFFLINE`.
- [ ] **T18-5 [P2]** "What It Does" (`:9-22`): add a work-ledger bullet. Add a *Work ledger (opt-in)* section modelled on `:175-179`, covering:
  - the verbs;
  - "inert without `docs/ledger/config.json`, except `init`";
  - adapters and hosted items;
  - `init --report/--accept/--import`;
  - the exit family.
- [ ] **T18-6 [P2]** Workflow Integration (`:185-219`): add `hooks install --ledger` / `--ledger-claude`. They are opt-in, never in `--all`, and refused without config. The status comment (`:213`) and uninstall need the same.
- [ ] **T18-7 [P2]** Hook paragraphs (`:222`, `:226`, `:228`) need:
  - the `# ledger-superpowers:begin … :end` marker;
  - the three git legs: pre-commit `ledger validate --staged`, where any non-zero exit blocks; pre-push provisional keys under `keys.mode` `cas`; and the background post-commit `ledger inflight --push`, with `push.log`;
  - the two Claude events: `ledger-session-notices` (SessionStart) and `ledger-state-watch` (PostToolUse `Write|Edit`).

  Say that "Git hooks (5)" and "Claude Code hooks (3)" count only the tiers.
- [ ] **T18-8 [P2]** The File Structure tree (`:338-364`) needs `scripts/ledger/`, `scripts/adapters/`, `bench-ledger.sh`, `references/ledger.md` and the schema. Dependencies (`:396-403`) need an authenticated `gh` for the `doc-superpowers:ledger-items-gh` and `ledger-pr-gh` adapters.
- [ ] **T18-9 [P2]** README says "six" suites at `:326` and `:410`, and its tree has no `test-ledger.sh`. Prefer no number, and a link to CLAUDE.md → Conventions → Testing.

**RELEASE-NOTES (Task 18: the fragment `RELEASE-NOTES.next/ledger.md`)**
- [ ] **T18-10 [P2]** Step 8: "RELEASE-NOTES.md: 62 commits unreleased since v3.2.0". The 3.3.0 entry must cover:
  - the `ledger` verb family and its exit family;
  - `scripts/ledger/`, `scripts/adapters/` and the schema;
  - the `--ledger` / `--ledger-claude` sets;
  - `test-ledger.sh` (2681), hooks 1097 → 1345, total 10412;
  - `bench-ledger.sh`;
  - the bash-3.2 guard now scanning `scripts/ledger/*.sh` and `scripts/adapters/*.sh`;
  - 81b6c35: the git tier's integrated pre-push block now refuses a push when the ref-line copy fails;
  - 42797cf: the Scope-matrix exemptions.

**skills/doc-superpowers/SKILL.md**
- [ ] **T18-11 [P2]** The bundled-tooling table (`:146-168`) needs a `doc-tools.sh ledger <verb>` row:
  - the 17 sub-verbs;
  - inert (exit 0) without `docs/ledger/config.json`, except `init`;
  - the 0/1/2/3 exit family;
  - `scripts/ledger/` must sit beside doc-tools.sh.

  Also add:
  - a References row for `references/ledger.md` (`:38-48`);
  - a Quick Reference row, and an entry in the actions list (`:59`);
  - consider ledger triggers in the frontmatter `description`;
  - the init step "Ledger (opt-in)" between 12 and 13: `ledger init --report`, then review the registry and decisions with the user, then `ledger init --accept`;
  - in step 14, offer `hooks install --ledger`.
- [ ] **T18-12 [P2]** Hooks:
  - Quick Reference `:30` and the hooks section `:521-528`: `--ledger` / `--ledger-claude` (opt-in, never in `--all`, refused without config).
  - `:528`: the "outdated" re-run advice should name `install --ledger` / `--ledger-claude` (`install.sh:1435,1463,1466`).
  - Sync step 7's `Hooks: N/5 git, N/3 claude, N/8 ci` (`:515`): add the ledger sets, or say they are excluded.
- [ ] **T18-13 [P2]** Command line, prerequisites and paths:
  - Prerequisites (`:122`): `gh` for the GitHub adapters.
  - Command line (`:192`): the ledger half of A-P2-20's exit sentence.
  - *Path precedence* (`:126-136`): a vendored `.github/scripts/doc-tools.sh` has no `scripts/ledger/`, so ledger verbs exit 2 there until Task 17's helper set lands.

**references/ledger.md (new; absent at 0f6f467)**
- [ ] **T18-14 [P2]** Write the reference that SKILL.md, README and CLAUDE.md will point to. It needs:
  - the `config.json` keys and defaults (`{}` is complete);
  - the 17 sub-verbs;
  - the inert contract and its order: options, then the repo check, then the config check, with `init` running on `{}`;
  - the 0/1/2/3 family;
  - the adapter contracts (`contracts`, `pr`, `items`: `list`, `get`, `write`, `note`, `create`) and how `doc-superpowers:<name>` resolves;
  - hosted items and `DOC_TOOLS_LEDGER_OFFLINE`;
  - keys: `cas` vs `merge`, provisional keys, `finalize`;
  - in-flight work, notices, views and `publish`;
  - `init --report/--accept/--import`;
  - `references/ledger-index.schema.json`, which no user doc cites today;
  - the vendored-copy limitation.

**references/spec-lifecycle-actions.md**
- [ ] **T18-15 [P2]** Plan Phase (`grep -c ledger` → 0). When `docs/ledger/config.json` exists:
  - paste `ledger sweep --plan <plan>` as `## Related work`, and run `ledger validate --plan` on the marks;
  - add "Ledger notices (chunk N)" running `ledger notices --gate`;
  - route exits on the 0/1/2/3 family, the same way as the claims gate's Step 1 (`:212`).

**references/integration-patterns.md**
- [ ] **T18-16 [P2]** Add a ledger section: when wrappers call `ledger sweep`, `validate --plan` and `note`, and that the verbs are inert without config.

**docs/superpowers/specs/2026-10-12-work-ledger-design.md (a record; Task 18 already edits it)**
- [ ] **T18-17 [P3]**
  - §J: write `--ledger-claude` as the code does.
  - §K.5: record whether the opt-in summary-rewrite agent is adopted (T18-66).
  - §H.3 (spec-inject notices gate) and §I (V5 resolves an item-key `tracker`) are not implemented at 0f6f467. V5 is the plan's post-rebase item 2.

**docs/conventions.md** (only `:82` is in Task 18's list)
- [ ] **T18-18 [P1]** `:82` "Run the six shell test suites": name no count, and link to CLAUDE.md → Conventions.
- [ ] **T18-19 [P1]** `:298` "Bypass all hooks temporarily": the ledger legs honour only `DOC_SUPERPOWERS_LEDGER_SKIP` (see T17-4). The env table (`:294-301`) lacks `DOC_SUPERPOWERS_LEDGER_SKIP` and `DOC_TOOLS_LEDGER_OFFLINE`.
- [ ] **T18-20 [P1]** `:229` and `:262-263` say "which all three source", "The three scripts source `hook-lib.sh`", and "Uninstall removes … the three scripts, `hook-lib.sh`". In fact five scripts source it, and `uninstall --claude` keeps it while the ledger scripts remain (`install.sh:1147-1150`).
- [ ] **T18-21 [P2]** Tier Options (`:222-232`):
  - add `--ledger`: the pre-commit, pre-push and post-commit legs, as marked blocks;
  - add `--ledger-claude`: SessionStart and PostToolUse `Write|Edit`.

  Both are opt-in, never in `--all`, refused without config, and never recorded in `installed.json`.
- [ ] **T18-22 [P2]** Ownership and placement (`:239`, `:251`) need:
  - the `# ledger-superpowers:begin … :end` markers, which `--ledger-claude` also writes in `info/exclude`;
  - their placement: after `#!`, any git-tier block, and the leading comments;
  - that a created hook holds only `#!/bin/sh` and the block.
- [ ] **T18-23 [P2]** The index non-writers list (`:362`) needs the ledger verbs, and what they write instead:
  - item files;
  - `docs/ledger/`;
  - the counter ref `refs/doc-superpowers/ledger/counters`;
  - the in-flight refs;
  - the views branch `doc-ledger-views`;
  - the cache `<git common dir>/doc-superpowers/ledger/`.
- [ ] **T18-24 [P2]** Add the ledger naming conventions:
  - `docs/ledger/config.json` and `legacy.json`;
  - the default glob `docs/issues/*.md`, with its `## Resolution` / `## Log` headings;
  - the trailers `Ledger-Claims`, `Contract-Change`, `Ledger-Ack` and `Fixes`/`Closes`/`Resolves`, also under Git Conventions → Commits;
  - `doc-superpowers:<name>` → `scripts/adapters/<name>.sh`;
  - the schema.

**docs/architecture/system-overview.md** *(not in Task 18's list; the post-rebase step 3 names only its "label")*
- [ ] **T18-25 [P1]** `:66` (in the PNG too) and `:114`: "18 subcommands" → 19, adding ledger. Re-render.
- [ ] **T18-26 [P1]** `:127` "Six shell test suites" → seven: add `test-ledger.sh`, and mention `bench-ledger.sh`. The counts stay in CLAUDE.md.
- [ ] **T18-27 [P1]** `:158`: the settings-format decision names three events and three scripts. `--ledger-claude` also writes `.hooks.SessionStart` and a second `PostToolUse` group (`Write|Edit`), and owns two more scripts (`install.sh:36-40,1335,1339`).
- [ ] **T18-28 [P1]** `:160`: "Absent tooling is silent. A failing check … blocks only under STRICT" does not hold for the ledger legs:
  - ledger-pre-commit blocks on any non-zero exit;
  - ledger-pre-push refuses a push;
  - ledger-post-commit pushes in-flight refs to the remote.

  Scope `:160` to the doc-superpowers tiers, and add a ledger Key Decision.
- [ ] **T18-29 [P2]** `:68`, `:115`, `:154`, `:90` and `:172` describe the installer without the two ledger sets. Name them: their legs and verbs, never in `--all`, refused without config, per-clone and per-user, never recorded. Also say that `hook-lib.sh` stays while the ledger scripts do.
- [ ] **T18-30 [P2]** Add a Work Ledger container (`scripts/ledger/`, through `doc-tools.sh ledger`). Its stores:
  - `config.json`, the switch;
  - the `ledgers.json` registry and the legacy map;
  - the item globs;
  - the cache, with the parse cache, the index (schema), views and `push.log`;
  - on the remote, the counter ref and the in-flight refs;
  - the views branch.

  Its Rels: hooks → ledger; ledger → project; ledger → doc-index (read-only); ledger → adapters; ledger → git remote.
- [ ] **T18-31 [P2]** The context diagram needs GitHub (through `gh`) or the shared "Host adapters" system of A-P2-6. Widen Git (`:29`) to include remote refs. Re-render.
- [ ] **T18-32 [P2]** Tech Stack (`:106-128`): add a Work Ledger row (inert without config; exit family shared with claims), and a reference row for `references/ledger.md` and the schema.
- [ ] **T18-33 [P2]** Key Decisions (`:132-172`) need one or two ledger decisions:
  - the issue is the source of truth, and views are generated;
  - keys are CAS-allocated;
  - relations are contracts;
  - in-flight work is visible across machines;
  - bash 3.2 + jq ≥ 1.6, with adapters;
  - `publish` never touches HEAD, the index or the working tree;
  - the ledger is inert without config.
- [ ] **T18-34 [P2]** Conditional: once they are implemented, add §H.3's notices gate to `:71`, `:96` and `:168`, and §I's V5 tracker resolution to the claims container (A-P2-5).
- [ ] **T18-35 [P3]** `:144`, the dependencies decision: add the optional `gh` and a git remote.
- [ ] **T18-36 [P3]** The Overview (`:7`), the context description (`:24`) and the container intro (`:48`): add the work ledger.

**docs/codebase-guide.md** *(not in Task 18's list)*
- [ ] **T18-37 [P1]** `:39` and `:125` say "18 subcommands", with no `ledger` in the list. Make it 19, and add the opt-in rule.
- [ ] **T18-38 [P1]** `:26` and `:152` say "the six suites". Prefer no number, and a link to CLAUDE.md.
- [ ] **T18-39 [P1]** The hook directories and install flow assume only the tier scripts:
  - `:51-61` and `:185-186` list only those scripts;
  - `:58` says "Sourced by all three";
  - `:131` counts "3 Claude Code hooks … and 5 git hooks";
  - `:344` says "For each hook script in scripts/hooks/git/";
  - `:354` says "Copy hook scripts…".
- [ ] **T18-40 [P2]** The directory map (`:38-48`, `:78-88`) needs:
  - `scripts/ledger/` (`lib.sh` plus 11 modules, and the `*.jq` and `*.awk` programs);
  - `scripts/adapters/`;
  - `test-ledger.sh` and `bench-ledger.sh`;
  - the schema.
- [ ] **T18-41 [P2]** Key Files needs the same rows. Widen the `install.sh` row with the ledger sets, and with the `hook-lib.sh` retention.
- [ ] **T18-42 [P2]** Where to Find Things needs rows for:
  - `# --- Work ledger` (`doc-tools.sh:11891`) and `_lg_enter` (`:12067`);
  - the module map (`lib.sh:20-41`);
  - the cache (`lib.sh:16`);
  - the adapters, the tests and bench, and the hook legs.
- [ ] **T18-43 [P2]** Code Flow needs a ledger flow:
  - dispatch: `_lg_enter`, then the inert check, then `lib.sh` sourcing the modules;
  - the parse and index cache;
  - CAS keys;
  - in-flight refs;
  - adapter resolution.

  The hooks-install flow (`:333-368`) also needs a `--ledger` / `--ledger-claude` branch.
- [ ] **T18-44 [P3]** `:261` says the claims verbs have their own exit-code family. The ledger verbs share it (`doc-tools.sh:3042-3043`).

**docs/guides/getting-started.md** *(not in Task 18's list)*
- [ ] **T18-45 [P2]** Add a work-ledger section:
  - opting in through `docs/ledger/config.json` (`{}` is complete);
  - every verb is inert without it, except `init` (`--report <file> [--registry] [--sources files,github]`, then `--accept`);
  - the everyday verbs: `ls`, `show`, `new`, `note`, `view` and `validate`;
  - a link to the reference.
- [ ] **T18-46 [P2]** The hooks examples and command rows (`:94-106`, `:197-199`) need `--ledger` / `--ledger-claude`. The `:96` comment "Install all hook tiers" should say that `--all` excludes them.
- [ ] **T18-47 [P3]** Prerequisites: `gh` for the GitHub adapters and for `ledger init --sources github` (`scripts/ledger/init.sh:187`). `:59`'s "No configuration required" is untrue for the ledger.
- [ ] **T18-48 [P3]** The vendoring paragraph (`:114-128`): a vendored `doc-tools.sh` has no `scripts/ledger/`, so it exits 2 for an enabled ledger (help `:2870-2872`). Task 17's helper set changes this.

**docs/workflows/doc-superpowers.md** *(not in Task 18's list; add the doc and its PNGs)*
- [ ] **T18-49 [P1]** `:751` says "18 subcommands, `claims` among them". Make it 19, and add a `doc-tools.sh — ledger <verb>` row: used by `init`, by `spec-inject` (`sweep`, `notices --gate`), by the ledger hooks, and standalone.
- [ ] **T18-50 [P1]** `:348` says "Every hook … exits silently under `DOC_SUPERPOWERS_SKIP=1`". The ledger legs honour only `DOC_SUPERPOWERS_LEDGER_SKIP`, and pre-commit and pre-push print a "skipped" line. See T17-4.
- [ ] **T18-51 [P1]** `:365` "The failure blocks only under STRICT" does not hold for the ledger legs:
  - ledger-pre-commit blocks on any non-zero exit, including 2;
  - ledger-pre-push refuses on a temp-file or copy failure, and on provisional keys under `cas`;
  - an absent config is silent.
- [ ] **T18-52 [P1]** `:363` says "The three Claude hooks source one library": five do. `:436` (uninstall `--claude`) says it removes "the three scripts, `hook-lib.sh`", but `hook-lib.sh` now goes only with the last script that sources it.
- [ ] **T18-53 [P2]** Add `--ledger` / `--ledger-claude` to the hooks synopsis (`:327-334`), Tier Options (`:340-344`), Commands (`:735-737`) and Install State (`:381`). Include:
  - opt-in, never in `--all`;
  - refused without config (exit 1, nothing written);
  - not recorded in `installed.json`;
  - `status` reports each set in its own section.
- [ ] **T18-54 [P2]** Hooks Steps (`:430-439`): add the ledger sets' install, uninstall and status:
  - the marked blocks and where they are placed;
  - `install --git` puts the ledger block back when it rewrites its hook;
  - `uninstall --git` leaves `#!/bin/sh` plus the block;
  - a created hook holds only `#!/bin/sh` and the block;
  - the two marker pairs never match each other.
- [ ] **T18-55 [P2]** `workflow-hooks.png` (`:449-462`): add ledger branches to install and uninstall, and ledger sections to the status node. Re-render with A-P3-26.
- [ ] **T18-56 [P2]** Hook Contracts (`:346-365`): add one contract per ledger leg:
  - pre-commit `validate --staged`, blocking;
  - pre-push `validate --pushed`, with the provisional-key and temp-file stdin rules;
  - post-commit `inflight --push`, in the background, logging to `push.log`, with no prompts and ssh `BatchMode=yes`;
  - SessionStart `ledger-session-notices.sh`: offline, a 2 s budget, at most 15 lines;
  - PostToolUse `Write|Edit` `ledger-state-watch.sh`, advisory.
- [ ] **T18-57 [P2]** spec-inject Plan Phase (`:561-575`) and `sequence-spec-inject.png`:
  - the `## Related work` sweep and its marks;
  - the per-chunk "Ledger notices (chunk N)" gate;
  - in the execute phase, the notices gate decides a `stop`: reconcile, or ack with a `Ledger-Ack:` trailer.
- [ ] **T18-58 [P2]** `init` Steps (`:140-155`) and `workflow-init.png` (`:162-193`):
  - add the "Ledger (opt-in)" step between 12 and 13: `ledger init --report`, the review, then `--accept` (with `--dry-run`);
  - step 14 offers the ledger sets;
  - update the Discovery Boundary line if init uses discovery.
- [ ] **T18-59 [P2]** Spec Lifecycle Routing (`:701-723`): add the ledger points, together with A-P2-16's claims column.
- [ ] **T18-60 [P2]** Scripts table (`:747-761`):
  - add `scripts/ledger/*` and the two adapters;
  - `:757`: "three tiers" → three tiers plus two ledger sets;
  - `:758`: add the five ledger hook scripts.

  `bench-ledger.sh` belongs in CLAUDE.md only.
- [ ] **T18-61 [P2]** Canonical Reference Files (`:125-136`): add `references/ledger.md` (REQUIRED wherever SKILL.md makes it so), and `ledger-index.schema.json`.
- [ ] **T18-62 [P2]** User Interaction Gates (`:829-840`) need three ledger gates:
  - the init ledger review (registry plus decisions, before `--accept`);
  - the sweep Mark column;
  - the per-chunk notices gate.
- [ ] **T18-63 [P2]** Artifacts and state, joining A-P2-14 and A-P2-15:
  - name `config.json`, `ledgers.json`, `ledgers.proposed.json`, `legacy.json` and `finalized.json`;
  - name the init report and `.decisions.tsv`, the views, `push.log`, the in-flight refs and the counter ref;
  - add the ledger states: provisional key → `finalize`, status classes, notice → ack.
- [ ] **T18-64 [P3]** Verification Model (`:893-898`): add a ledger layer. `validate --staged` runs at commit, and `notices --gate` at chunk close.
- [ ] **T18-65 [P3]** Sync step 7 (`:319`, mirroring `SKILL.md:515`): keep it in step with T18-12's decision.
- [ ] **T18-66 [P3]** Sub-Agents (`:815-825`): add design §K.5's summary-rewrite agent if it is adopted, or say that the ledger dispatches no agent.
- [ ] **T18-67 [P3]** Pipeline overview and sequence (`:775-794`, `:856-887`, Primary Workflow `:9-13`): show the init ledger step. Alternatively, state that the ledger is a `doc-tools.sh` verb used inside `init` and `spec-inject`, not an action.

**references/hooks.md** *(not in Task 18's list; the Ledger sets section `:32-44` was checked and is accurate)*
- [ ] **T18-68 [P3]** `:46` *Status and upgrades* names only the `install --git` / `--claude` re-runs. The ledger sets print "re-run install --ledger" / "--ledger-claude" (`install.sh:1435,1463,1466`).

**references/spec-lifecycle-protocol.md** *(not in Task 18's list)*
- [ ] **T18-69 [P3]** If the Plan Phase gains ledger steps, add a ledger column or row to the interception table (`:9-15`) and to *Host Project Assumptions* (`:205-219`). Alternatively, let `references/ledger.md` own them, with a pointer from here.

**references/doc-spec.md** *(not in Task 18's list)*
- [ ] **T18-70 [P3]** `:1050`: name the ledger exit family beside the claims family that U31 adds.

**references/tool-mappings.md** *(not in Task 18's list)*
- [ ] **T18-71 [P2]** The Capabilities table (`:33-41`) needs two rows:
  - `--ledger`: git hooks, any client;
  - `--ledger-claude`: Claude Code only, with SessionStart and PostToolUse `Write|Edit`.

  `:44` names only the `PreToolUse` / `PostToolUse` / `Stop` events. Whether Cursor maps SessionStart is unverified.

**GEMINI.md, AGENTS.md, `.codex/`, `.cursor-plugin/` and `.opencode/` INSTALL guides** *(not in Task 18's list; optional)*
- [ ] **T18-72 [P3]** These say "Install the hook tiers that work outside Claude Code with `hooks install --git --ci`": `GEMINI.md:11`, `.codex/INSTALL.md:61`, `.opencode/INSTALL.md:69` and `.cursor-plugin/INSTALL.md:51`.
  - The `--ledger` set also works outside Claude Code; `--ledger-claude` does not.
  - `AGENTS.md:7`'s triggers name no ledger work.
  - `test-spec-status-model.sh` does not pin these sentences.

**evals/** *(not in Task 18's list)*
- [ ] **T18-73 [P3]** No eval covers the ledger. Add an inert-path eval, and one for the Plan Phase ledger step once T18-15 lands.

---

## Appendix B — Routed to Task 17

These are code, not update work. Task 17 (vendoring and the publish workflow) already modifies `test-doc-tools.sh`, `tests.yml` and the vendoring path. Each of the four gaps was confirmed against the snapshot.

- [ ] **T17-1** The jq-1.7 guard does not scan the ledger code.
  - `test_shipped_jq_is_free_of_jq17_only_forms` (`scripts/test-doc-tools.sh:760`) scans:
    - `doc-tools.sh` and `merge-doc-index.sh`;
    - `hooks/*.sh`, `hooks/claude/*.sh` and `hooks/git/*`, which already include the five ledger hook scripts;
    - the CI helpers.
  - It does **not** scan `scripts/ledger/*.sh`, `scripts/ledger/*.jq` or `scripts/adapters/*.sh`. The bash-3.2 guard does scan them (`:518-519`).
  - Until it does, CLAUDE.md's "another that fails on any jq-1.7-only form in their jq programs" is untrue for the ledger.
  - A rough grep with the guard's patterns found no violation, but it is not the guard's quote-aware extractor.
  - Fix: add the three globs to the candidate list.
- [ ] **T17-2** The vendored `.github/scripts/doc-tools.sh` is stale.
  - `cmp` with `scripts/doc-tools.sh` fails at line 1421, char 63010. The copy was last synced in 687dc9c.
  - So tests.yml's *Self-installed CI tier matches its templates* step fails on this branch. The 10 step scripts match.
  - Fix: run `bash scripts/hooks/install.sh install --ci` and commit what it writes. Task 17 also extends the drift `cmp` to the vendored ledger files.
- [ ] **T17-3** The `scripts/hooks/claude/hook-lib.sh` header comment is out of date.
  - `:7-9` say it is "Sourced, never run, by pre-commit-gate.sh, post-commit-sync.sh and session-summary.sh … so the three cannot drift apart".
  - `ledger-session-notices.sh` and `ledger-state-watch.sh` source it too.
  - Fix: name all five, or say "every Claude hook script".
- [ ] **T17-4** The ledger legs must honour `DOC_SUPERPOWERS_SKIP`.
  - All five read only `DOC_SUPERPOWERS_LEDGER_SKIP`:
    - `ledger-pre-commit:6` and `ledger-pre-push:17`, which print "skipped";
    - `ledger-post-commit:15`;
    - `ledger-session-notices.sh:22` and `ledger-state-watch.sh:28`.
  - The ledger block runs before the git tier's own SKIP exit (`references/hooks.md:33`), so the check must be in the block itself.
  - Once this lands, the docs' "bypass all hooks" holds again, and T18-4, T18-19 and T18-50 shrink to documenting the ledger-only switch.

**Code halves of A findings.** These are not among the ruling's four. They are listed so that `update` skips them; the controller assigns them.
- [ ] **C-1** (A-P3-2, nit N2) The help text omits the plan's scope: gate at `doc-tools.sh:2305-2306`, and attest at `:2322-2323`.
- [ ] **C-2** (A-P3-65, nit N3) The V10 messages (`_JQ_CLAIMS_V10`, `doc-tools.sh:8696-8706`) and the extension help (`:2847-2856`) need to branch on `enforced_by`. A non-test claim is moved to built by a reviewed status edit, not promoted.
- [ ] **C-3** (A-P2-23) The attest help (`:2324-2327`) should state the stricter cross-check.
- [ ] **C-4** `.github/workflows/tests.yml:1` says "the six suites that gate changes to this repo". Make it seven, alongside Task 17's tests.yml edit.

After any of these, run `bash scripts/hooks/install.sh install --ci` (T17-2).

---

## Deferred 3.2.0 items — status at 0f6f467

These are the 2026-10-14 audit's (3.2.0) P2 and P3 items, plus the three nits that session handed over. "Here" is this report's id.

| 3.2.0 id | Doc | Status | Here |
|---|---|---|---|
| P2-1 | Scope-matrix docs | **resolved**: owner exemption, 42797cf (`conventions.md:206-212`, checked accurate) | — |
| P2-2 | README | applies | A-P2-1 |
| P2-3 | README | applies | A-P2-2 |
| P2-4 | README | applies | A-P2-3 |
| P2-5 | README, getting-started | applies | A-P2-4 |
| P2-6 | getting-started | applies | A-P2-11 |
| P2-7 | getting-started (+ README:162, new) | applies | A-P2-12 |
| P2-8 | conventions | applies | A-P2-9 |
| P2-9 | conventions | applies | A-P2-10 |
| P2-10 | system-overview | applies | A-P2-5 |
| P2-11 | system-overview | applies | A-P2-6 |
| P2-12 | system-overview | applies | A-P2-7 |
| P2-13 | codebase-guide | applies | A-P2-8 |
| P2-14 – P2-20 | workflows doc | applies | A-P2-13 – A-P2-19, in order |
| P2-21, P2-22 | hooks.md | applies | A-P2-21, A-P2-22 |
| P2-23 | hooks.md, install help | **fixed** (aed19d8) | — |
| P2-24 | spec-claims.md, attest help | applies | A-P2-23 (help half: C-3) |
| P2-25 | spec-claims.md | applies | A-P2-24 |
| P2-26 – P2-31 | spec-lifecycle-actions | applies | A-P2-25 – A-P2-30, in order |
| P2-32 | spec-lifecycle-protocol | applies | A-P2-31 |
| P2-33 | agent-prompt-template | applies | A-P2-32 |
| P2-34 | SKILL.md | applies | A-P2-20 (ledger half: T18-13) |
| P2-35 | doc-spec.md | applies | A-P2-33 (ledger half: T18-70) |
| P2-36 | evals | applies | A-P2-34 |
| P3-1 | SKILL, protocol, conventions, system-overview | applies | A-P3-44 |
| P3-2 – P3-11 | SKILL.md | applies | A-P3-45 – A-P3-54, in order |
| P3-12 – P3-15 | doc-tools help | **fixed** (aed19d8, 604e619) | — |
| P3-16, P3-17 | spec-claims.md | applies | A-P3-60, A-P3-61 |
| P3-18 | spec-claims.md (+ SKILL:163, README:179, new) | applies | A-P3-62 |
| P3-19, P3-20 | spec-claims.md | applies | A-P3-63, A-P3-64 |
| P3-21, P3-22 | spec-lifecycle-actions | applies | A-P3-66, A-P3-67 |
| P3-23 | spec-lifecycle-protocol | applies | A-P3-69 |
| P3-24, P3-25 | integration-patterns | applies | A-P3-72, A-P3-73 |
| P3-26 – P3-28 | output-templates | applies | A-P3-74 – A-P3-76 |
| P3-29, P3-30 | agent-prompt-template | applies | A-P3-70, A-P3-71 |
| P3-31 | tool-mappings | applies | A-P3-79 |
| P3-32 | release.md | applies | A-P3-78 |
| P3-33 | doc-spec.md | applies | A-P3-77 |
| P3-34, P3-35 | hooks.md | applies | A-P3-55, A-P3-56 |
| P3-36 | hooks.md (+ README:213, new) | applies | A-P3-57 |
| P3-37 | install help | **fixed** | — |
| P3-38 | hooks.md | applies | A-P3-58 |
| P3-39 | RELEASE-NOTES.next.README | applies | A-P3-80 |
| P3-40 | hooks.md | applies | A-P3-59 |
| P3-41 – P3-52 | workflows doc | applies | A-P3-25 – A-P3-36, in order |
| P3-53 | workflows doc | applies (routing half; the naming half is exempt under P2-1) | A-P3-37 |
| P3-54 | workflows doc | applies | A-P3-38 |
| P3-55 – P3-60 | system-overview | applies | A-P3-3 – A-P3-8, in order |
| P3-61 | system-overview | **half fixed** (re-baselined in ee02ae0); the `code_refs` half applies | A-P3-9 |
| P3-62 | codebase-guide | applies | A-P3-11 |
| P3-63 | codebase-guide (+ CLAUDE.md:80,133, new) | applies | A-P3-12 |
| P3-64 | codebase-guide | applies | A-P3-13 |
| P3-65 | conventions (+ codebase-guide:421, new) | applies | A-P3-15 |
| P3-66 – P3-69 | conventions | applies | A-P3-16 – A-P3-19, in order |
| P3-70 – P3-72 | getting-started | applies | A-P3-21 – A-P3-23, in order |
| N1 (capitalised → upper-case) | RELEASE-NOTES | applies | A-P3-1 |
| N2 (gate/attest edited-claim scope) | RELEASE-NOTES, spec-claims.md, help | applies | A-P3-2 (help: C-1) |
| N3 (V10 and extension text assume test claims) | spec-claims.md, help, `_JQ_CLAIMS_V10` | applies | A-P3-65 (code: C-2) |

**Tally:** 108 deferred items (36 P2, 72 P3):
- 101 apply. P3-61 is half fixed, and P3-53 is half exempt.
- 6 are fixed: P2-23, P3-12 to P3-15, and P3-37.
- 1 is resolved: P2-1.
- None is obsolete.

All 3 nits apply.

The 3.2.0 P0 and P1 items were not deferred: close-out fixed them. The scope agents re-confirmed these:
- P1-6 and P1-7 are fixed (08a49fc).
- P1-8 is fixed (08a49fc).
- P1-9's counts were fixed at v3.2.0; test-hooks has drifted since (A-P1-1).
- P1-10 is obsolete for system-overview, which was re-rendered in abfd5e2.
