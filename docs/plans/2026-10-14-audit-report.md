## Documentation Freshness Audit — 2026-10-14

**Branch:** design/spec-claims · **HEAD:** abfd5e2

Dogfood run of this branch's own 3.2.0 skill (`skills/doc-superpowers/SKILL.md`, `audit`, scope `all`), close-out Task 5. `$DOC_TOOLS` was this worktree's `scripts/doc-tools.sh` (resolved with the *Detect Bundled Tooling* block, run under `/bin/bash`). Every scope agent read a `git archive` snapshot of abfd5e2, so all line numbers below are at abfd5e2.

### Summary
- Scanned: 5 indexed living docs (`docs/architecture/system-overview.md`, `docs/codebase-guide.md`, `docs/conventions.md`, `docs/guides/getting-started.md`, `docs/workflows/doc-superpowers.md`), plus `CLAUDE.md`, `README.md`, `AGENTS.md`, `GEMINI.md`, the three client INSTALL guides, the 5 version manifests, `RELEASE-NOTES.md`, `skills/doc-superpowers/SKILL.md`, all 10 `references/*.md`, `scripts/hooks/ci/doc-pr-release/RELEASE-NOTES.next.README.md`, the `doc-tools.sh` help text, the CI templates' prompts and `--allowedTools`, this repo's own CI tier, and `evals/`. Scopes: `application`, `ci-cd`, `agentic`, `spec` (design specs and plans under `docs/superpowers/` only, which are records), plus the always-generated docs.
- Fresh: 60 | Stale: 0 | Missing coverage: 0 | Untracked: 0 (also Deprecated: 2). These are `check-freshness` counts (current 60, stale 0, missing 0, deprecated 2, untracked 0). One living doc is `doc_modified`: `docs/architecture/system-overview.md`, edited by abfd5e2 (the C4 container re-render) after the 330832d re-baseline. The architecture agent read every abfd5e2 edit against the code and found them accurate (P3-61).
- Findings after merging: **P0 2 | P1 10 | P2 36 | P3 72** (120 total). Where several agents reported the same root cause, it is merged into one entry at the highest rating, with every affected location listed.
- Per-doc verdicts from the scope agents: `system-overview.md` MISSING_COVERAGE · `codebase-guide.md` MISSING_COVERAGE · `conventions.md` STALE · `getting-started.md` MISSING_COVERAGE · `workflows/doc-superpowers.md` STALE · `README.md` MISSING_COVERAGE · `AGENTS.md`, `GEMINI.md`, the three INSTALL guides FRESH · manifests FRESH (one optional note) · `SKILL.md` STALE · `references/spec-claims.md` STALE · `references/spec-lifecycle-actions.md` STALE · `references/spec-lifecycle-protocol.md` STALE · `references/hooks.md` STALE · `references/doc-spec.md` STALE · `references/release.md`, `integration-patterns.md`, `agent-prompt-template.md` STALE (minor) · `references/tool-mappings.md`, `output-templates.md` FRESH (P3 only) · `RELEASE-NOTES.next.README.md` FRESH (P3 only) · `CLAUDE.md` STALE (counts only) · `RELEASE-NOTES.md` STALE.
- Dispatch: eight read-only `general-purpose` scope agents ran in parallel, each given only its scope's docs and code, with the trust-boundary, secrets and verification blocks of `references/agent-prompt-template.md`. The eight were: architecture; workflows + agentic inventory; guides + conventions; ci-cd + testing; spec claims reference; spec lifecycle references; SKILL.md + core references + help text; README + cross-client packaging. The orchestrator ran steps 3–8 itself (gaps, naming, structure, CLAUDE.md, RELEASE-NOTES; README through its agent) and spot-checked every P0 and P1 against the code before merging.
- Limits: no test suite was run, by instruction (host load). The suite counts in `CLAUDE.md` were therefore not re-measured (P1-9 rests on the diff, not on a run). No repository script ran except `doc-tools.sh` / `install.sh` `--help` and the read-only `check-freshness`. No index verb wrote anything. No secret was found in any scanned file, and no directive embedded in repository content was acted on.
- Structure: no flat-structure docs and no global `docs/diagrams/`. Naming: every living doc is kebab-case. The `docs/issues/2026-09-27-sweep-05ea982-I0n-*.md` records carry an upper-case `I0n` token, but issues have no naming row and are records, so no action is needed.

### P0 Critical

1. `references/spec-lifecycle-actions.md:365` (`spec-verify --mode=review` step 3c) with `scripts/hooks/ci/doc-spec-verify.yml:75,76-92`: in a claims-enabled project, the CI agent is told to run commands that its tools refuse.
   - Doc says: "3c. **Claims** (claims-enabled projects only): `$DOC_TOOLS claims run --planes-of <base>...HEAD` and `claims validate --all`'s V9 items; a red claim is a **P1 Claim red** finding."
   - Code shows: the `spec-verify` AI job grants exactly `check-freshness:*`, `status:*` and `implementation-status:*` of `.github/scripts/doc-tools.sh` (`doc-spec-verify.yml:75`). Its prompt (`:76-92`) does not tell the agent to skip 3c, and `SKILL.md:136`'s list of commands not granted in CI does not cover it. Both claims commands also execute the PR's own runner adapters, which `SKILL.md:91` forbids in a CI workflow, so granting them would be the wrong fix. The non-AI `claims` job (`doc-spec-verify.yml:94-146`) already runs these checks.
   - Suggested fix: in the template prompt, say "Skip step 3c: this workflow's `claims` job runs the claims checks". In `spec-lifecycle-actions.md` 3c, add "(skip it in a CI run where a non-AI claims job covers it, such as `doc-spec-verify`'s)". `doc-spec-verify` is not self-installed here, so no `install --ci` re-render is needed for this one.

2. `RELEASE-NOTES.md:11` (v3.2.0, Features, the `promote` bullet): it describes the promotion rule that 745ea2d removed.
   - Doc says: "Where the verdict is missing (a fresh clone, CI), V6, `gate` and `attest` judge the claim by its record at `promotion.at`, the record promote proved."
   - Code shows: 745ea2d ("promotion fingerprint — V6 decides by proved, not history") replaced that rule. `claims promote` now writes `promotion.proved` (`{states, test, subject, enforced_by, nonvacuity, when}`), and V6 compares a built or gated claim with `proved` field by field and reads no history (`_claims_proved`, `_claims_proved_delta`, `_claims_verdict_bound`; `scripts/doc-tools.sh:6843-6980, 7020-7215`). `references/spec-claims.md` was updated in 745ea2d and ffca4cf, and `scripts/test-spec-status-model.sh:1443-1445` now forbids "record at `promotion.at`" in that reference. `RELEASE-NOTES.md:11` is the only place outside the records that still says it.
   - Suggested fix: rewrite the sentence around `promotion.proved`: V6 compares each promoted claim with what promote proved, and `unverifiable-here` is left only for a missing verdict with every field unchanged. Also name the V1 canonical-number rule for `when` (ffca4cf). Close-out Task 6 already owes this edit.

### P1 Stale

1. `skills/doc-superpowers/SKILL.md:178,190,461,507`, the `doc-tools.sh` help (`:2457-2458`, `:2128`) and `references/doc-spec.md:1052,1069,1081-1082`: the documented archive recipe erases an existing `superseded_by`.
   - Doc says (SKILL.md:178): "`git mv` into `docs/archive/<type>/`, then `move-entry <old> <new>`, then `deprecate-entry <new>`". The routing table's "Never" column (`:177,182`) implies the routed verbs keep a doc's "baseline, deprecation and links".
   - Code shows: without `--superseded-by`, `local superseded_by="null"` (`scripts/doc-tools.sh:4064`), and the patch is `merge: {status: "deprecated", superseded_by: $superseded_by}` (`:4092`). Archiving a doc that was already superseded (for example by `spec-generate` step 5) sets its `superseded_by` to null, while its successor's `replaces` still names it. No test pins this behaviour.
   - Suggested fix: preferably change `deprecate-entry` to keep an existing `superseded_by` when the option is absent (a code change, outside `update`). Otherwise, have every archive recipe pass `--superseded-by <successor>` when one exists, and document the reset in the help text and `doc-spec.md`.

2. `references/spec-lifecycle-actions.md:214` (the injected `Claims gate (chunk N)` task, Step 3): the documented `--holds` form exits 3.
   - Doc says: "Adjudicate each V9 item: `--holds <id>` when `states` still holds, else a ruling."
   - Code shows: `if [ ${#_OPTV_holds[@]} -gt 0 ] && [ -z "$by" ]; then _usage_error "claims gate" "--holds needs --by <principal>: …"` (`scripts/doc-tools.sh:10703-10705`), a usage error, exit 3. `references/spec-claims.md:251` spells it `gate --holds <id> --by <principal>`. Step 1 (`:212`) routes only exits 0, 1 and 2.
   - Suggested fix: "re-run Step 1 as `$DOC_TOOLS claims gate --plan {plan-path} --chunk {C} --holds <id> --by <principal>`", and route exit 3 as a usage error.

3. `references/spec-claims.md:168,201,205,214`: a `lint`, `log` or `judge` claim has no supported path into `built`.
   - Doc says: `built` needs "a check; for `test`, a non-vacuity proof and a `promotion` (V3)" (`:168`); it describes a built lint claim (`:201,205`); and "**`claims promote <id>` is the only path into `built`.**" (`:214`).
   - Code shows: promote refuses anything but a test claim: `elif $c.enforced_by != "test" then "enforced_by …: promote proves a test claim …"` (`scripts/doc-tools.sh:10049`). V6 still flags any move into `built`/`gated` without a promotion, whatever the tier: `.bare = (.moved_in and (.claim.promotion | type) != "object")` (`:7032`; message at `:7073`). The suite's own `lint_promote` fixture hand-writes a promotion (`scripts/test-spec-claims.sh:4116-4126`, `hand_promotion`).
   - Suggested fix: decide which side is wrong. Either document that promote proves test claims only and give the supported path for lint, log and judge claims, or change the code: scope V6's "without a promotion" check to test claims, or let promote handle lint.

4. `references/hooks.md:57`: the `persist-credentials` statement is now false.
   - Doc says: "`actions/checkout` also persists the job's token in `.git/config` (no template sets `persist-credentials: false`: the commit steps push with it)".
   - Code shows: `doc-spec-verify.yml:121` sets `persist-credentials: false` on the new `claims` job's checkout, because that job "runs the PR's own code (its adapters) and needs no git credentials" (`:111-116`). `RELEASE-NOTES.md` v3.2.0 says so too.
   - Suggested fix: "no AI job's checkout sets `persist-credentials: false` …; only `doc-spec-verify`'s non-AI `claims` job does, because it runs the PR's own adapters". Add a bullet that the `claims` job executes PR-head code.

5. `references/spec-lifecycle-protocol.md:15` (review row of the interception table): it misstates which claims review runs.
   - Doc says: "Adds the claims verdict for claims whose subject or runner the change touched, and the V9 items".
   - Code shows: `--planes-of` selects only test claims, by runner `paths` (`_claims_planes_of` / `_claims_planes_sel`, `scripts/doc-tools.sh:7800-7856`). It never selects by `subject`.
   - Suggested fix: "for the test claims of every runner whose `paths` match a changed file".

6. `docs/workflows/doc-superpowers.md:396`: "two exceptions" to the step-script rule. 3.2.0 added a third.
   - Doc says: "Every `run:` step is a script in `.github/scripts/doc-superpowers-steps/` … with two exceptions in `doc-pr-release.yml`".
   - Code shows: `run: .github/scripts/doc-pr-release/update-pr-body.sh "$PR" < "$AMENDMENTS"` (`scripts/hooks/ci/doc-spec-verify.yml:146`). The doc's own `:761` already mentions this step, so the doc contradicts itself. `references/hooks.md:127-129` has the same gap (P3-40).
   - Suggested fix: "…three exceptions: two in `doc-pr-release.yml` (…), and `doc-spec-verify.yml`'s amendment step, which runs `doc-pr-release/update-pr-body.sh` only when that helper is installed (`hashFiles`)."

7. `docs/workflows/doc-superpowers.md:365` ("Absent vs failing"): no longer true for the claims legs.
   - Doc says: "When the skill or `docs/.doc-index.json` is absent, the hook stays silent."
   - Code shows: `scripts/hooks/git/pre-commit:43-77` runs the claims leg before `[[ -f docs/.doc-index.json ]] || exit 0` (`:79`), so it can block a commit in a project with no index. `pre-push:103` never checks for the index. `references/hooks.md:27` says the leg runs "with or without a doc-index".
   - Suggested fix: add "…except the claims legs, which run whenever `docs/spec-claims/` exists, index or not."

8. `docs/conventions.md:332`: the spec numbering rule is out of date.
   - Doc says: "If extending an existing category (not superseding), use the next sequential number (e.g., `SPEC-AUTH-002` if `SPEC-AUTH-001` exists)."
   - Code shows: `references/doc-spec.md:1024-1026` says "Sequential per category, never reused … one past the highest for that category in `docs/specs/` **and** `docs/archive/specs/`". `references/spec-lifecycle-actions.md:134` says "a number is never reused, even after its spec is archived". The text dates from v2.3.0 (97134e0); the rule changed in 7ea49d2.
   - Suggested fix: restate the never-reused rule, counting `docs/archive/specs/`, and add the matching ADR rule (`doc-spec.md:1020-1022`).

9. `CLAUDE.md:178` (Conventions → Testing) and `RELEASE-NOTES.md` v3.2.0 *Other*: the per-suite assertion counts predate five commits that added assertions.
   - Doc says: "`test-spec-status-model.sh` (602), `test-doc-pr-release.sh` (582), … `test-spec-claims.sh` (2883), 7132 total". The counts were last set in 61167c8 ("v3.2.0 notes and suite counts after the final-review fixes").
   - Code shows: five later commits changed the suites. They are 745ea2d (`test-spec-claims.sh` +539/−89, `test-spec-status-model.sh`), ffca4cf (`test-spec-claims.sh` +52, `test-spec-status-model.sh` +13), c743712 (`test-spec-claims.sh` +42), e63b9f1 (`test-doc-pr-release.sh` +64) and 3d38dba (`test-spec-claims.sh` +35). Counted statically, their diffs add about 80 assertion call sites net (`assert_*` / `_pass`: +72/−18, +10/−1, +4, +5, +9). `CLAUDE.md` has not been touched since 159806f.
   - Suggested fix: re-measure all six suites and update `CLAUDE.md:178` and the v3.2.0 *Other* section (close-out Task 6 owes this). The counts stay unverified until the suites run; this audit ran none, by instruction.

10. `RELEASE-NOTES.md` v3.2.0 *Documentation*, the "Known gap" paragraph: abfd5e2 made it obsolete.
    - Doc says: "Known gap: the C4 container diagram still reads "17 subcommands" (label and PNG update owed: mmdc was unavailable)", followed by five Mermaid line items.
    - Code shows: abfd5e2 re-rendered `docs/architecture/diagrams/c4-container.png`. Its source now reads "18 subcommands", "10 step scripts (claims-check.sh among them)", "R1-R5" and "git pre-commit and pre-push run claims", and names the claims-check relation (`docs/architecture/system-overview.md:66-94`). The architecture agent confirmed that the PNG matches. Close-out Task 4 lists "Remove the "Known gap" line from `RELEASE-NOTES.md`", which abfd5e2 did not do (it touched only the doc and the PNG).
    - Suggested fix: delete the paragraph, and say under *Documentation* that the container diagram was re-rendered for 3.2.0.

### P2 Incomplete

**Matrix gaps (audit step 3)**

1. The repo lacks docs that the *Scope → Generated Docs Matrix* (`SKILL.md:294-308`) calls for:
   - `docs/specs/README.md` + `template.md` and `docs/adr/README.md` + `template.md` (the "Always" row);
   - `docs/ci-cd.md` and `docs/workflows/deployment.md` (`ci-cd` is detected from `.github/workflows/`);
   - `docs/workflows/agentic/README.md` + `agentic/doc-superpowers.md` (`agentic` is detected from `skills/doc-superpowers/SKILL.md`; the agentic content lives at `docs/workflows/doc-superpowers.md:763`).

   Earlier audits (2026-07-24, 2026-09-28) recorded the agentic layout as a structural decision. Fix: the owner decides whether to create these docs or record the exemption. `update` must not create them unasked.

**README.md**

2. `README.md:226,232`: the git-hooks and environment-variable paragraphs leave out the 3.2.0 claims legs. Doc says "Pre-push reminds about unreleased commits on the branches being pushed", and `DOC_SUPERPOWERS_CLAIMS_SKIP` appears nowhere (0 matches). Code shows `scripts/hooks/git/pre-commit:18-25` ("A finding (exit 1) blocks the commit whatever STRICT says … DOC_SUPERPOWERS_CLAIMS_SKIP=1 bypasses that leg alone") and `pre-push:12-23` (the advisory `claims (advisory): <n> red, <m> indeterminate` leg). Fix: add one sentence per hook, and add `DOC_SUPERPOWERS_CLAIMS_SKIP=1` to the variables.
3. `README.md:230` (also `:177,203`): the CI paragraph leaves out:
   - `doc-spec-verify.yml`'s non-AI `claims` job (`:94-146`): it needs no Anthropic secret, sets `persist-credentials: false` and has a host test-setup slot;
   - the schedule's claims step, its "### Spec claims" issue section and the 30-minute timeout (`doc-freshness-schedule.yml:8-11,27`);
   - that `--ci-strict` fails a claims check that cannot run.

   Fix: say all of this, and say that a claims-enabled project needs `--workflows=doc-spec-verify` for a PR check.
4. `README.md:9-22,120-122,177`: the feature list has no claims bullet, and the spec actions' claims behaviour is missing: `spec-generate`'s `unbuilt` stubs (`spec-lifecycle-actions.md:139`), `spec-verify`'s `claims attest --final` and "claims verdict owed" (`:312`), **P1 Claim red** (`:365`) and R5 (`SKILL.md:540`). Fix: add a "What It Does" bullet and one sentence on each.
5. `README.md:399` and `docs/guides/getting-started.md:5-10`: the prerequisites are incomplete. README says "`git` | Yes | Already required"; getting-started lists only git and jq ≥ 1.6. Code shows two missing requirements:
   - claims checks over a merge use `git show --remerge-diff`, which needs git ≥ 2.36 (`scripts/doc-tools.sh:7617,7695-7703`; `references/spec-claims.md:17-19`);
   - `check_deps` also requires `sha256sum` or `shasum` (`doc-tools.sh:46-48`).

   Bash ≥ 3.2 is in README but not in getting-started. Fix: add git ≥ 2.36 (claims-enabled projects only) to both docs, and add bash ≥ 3.2 and `sha256sum`/`shasum` to getting-started.

**docs/guides/getting-started.md**

6. `:182`: the claims paragraph leaves out what a user needs after opting in.
   - Once `docs/spec-claims/` exists, the pre-commit leg blocks on any finding whatever STRICT says (`pre-commit:43-60`). Its only bypass is `DOC_SUPERPOWERS_CLAIMS_SKIP=1`.
   - The PR claims job ships only in the opt-in `doc-spec-verify`.
   - Test claims need runner adapters in `docs/spec-claims/config.json` (`runners`, default `{}`, `spec-claims.md:86`), so `:59` "No configuration required" is untrue for claims.

   Fix: add one or two sentences.
7. `:174`: the `spec-verify --mode=post-execute` example omits `--plan`. With claims enabled, "Claims enabled and no `--plan`: … step 0 reports 'claims verdict owed', never PASS" (`spec-lifecycle-actions.md:312`). Fix: show `[--plan=<path>]` and say it is required with `docs/spec-claims/`.

**docs/conventions.md**

8. `:182-204`: there are no naming or directory conventions for spec claims (`spec-claims.md:54-68`). Missing:
   - sidecars `docs/spec-claims/<DOC-ID>.json` and `config.json`;
   - `gates/<plan-stem>/chunk-<n>.json` and `final.json`;
   - claim ids `<DOC-ID>#<slug>`;
   - plan lines `**Claims:** <ids>` / `**Claims:** none — <reason>`;
   - the status-block markers;
   - the verdict store under `$(git rev-parse --git-common-dir)`.

   Fix: add a row and a short naming table, both marked claims-enabled only.
9. The doc has no `## Code Style` section, although the template requires one (`references/doc-spec.md:848`). The rules it would hold are undocumented here: the bash-3.2 guard (`scripts/test-doc-tools.sh:504-596`), the jq-1.6 guard added in 3.2.0 (`:757-775`), and the POSIX-userland and mawk rules (`README.md:403`). Fix: add the section, and say which rules the suite enforces statically.

**docs/architecture/system-overview.md**

10. `:66,71,114`: spec claims have no place in the architecture beyond verb lists.
    - The claims code is `scripts/doc-tools.sh:5581-11408`, about half the file, and sits inside "Freshness Tooling".
    - Tech Stack has no row for `references/spec-claims.md`, although every other reference has one (`:117-126`).
    - None of the claims data stores is shown: sidecars, `config.json`, gate records (`_claims_gate_write`, `:10674`), the local verdict store `$(git rev-parse --git-common-dir)/spec-claims/promotions/` (`:6805-6810`), and the "## Claim status" block.

    Fix: add a "Spec Claims checker" container with its stores, and a Tech Stack row.
11. The C4 diagrams leave out the host adapters and doc-tools' writes into the project. `spec-claims.md:271-275` says "a host supplies small executables named in `config.json`", and `doc-spec-verify.yml:111-114` says "This job runs the PR's own code (its adapters)". Neither diagram has an external system for the adapters, and the container diagram has no `doctools → project` relation. `:39`, `Rel(ci, skill, "Runs freshness checks on PR/schedule")`, leaves out the claims job and the weekly re-verification. Fix: add both, widen `:39`, and re-render.
12. `:160` ("Hooks report, never re-baseline"): the decision says "A failing check prints one line and blocks only under STRICT", but the claims pre-commit leg blocks on a finding whatever STRICT says (`pre-commit:20-21`). The Hooks Installer row (`:115`) mentions neither claims leg. No key decision records the claims design: opt-in by directory and inert otherwise, its own 0/1/2/3 exit family, "could not run" never reported as a pass, and self-reported gate records. Fix: add the decision and both legs.

**docs/codebase-guide.md**

13. `:212-429`: Code Flow has no claims flow. Missing:
    - the gate-record write path (`_claims_gate_write`, `doc-tools.sh:10674-10684`);
    - promote's writes to the sidecar, the status block and the verdict store (`:6805-6810`);
    - the dirty-tree refusal;
    - adapter invocation: top-level cwd, stdin `/dev/null`, fail-closed parsing (`spec-claims.md:301-305`);
    - the range rule: first-parent plus `--remerge-diff` (`doc-tools.sh:7598+`).

    Fix: add a "Spec claims (every claims verb)" flow.

**docs/workflows/doc-superpowers.md**

14. Three diagrams were not updated for 3.2.0, though each PNG still matches its own source:
    - `sequence-spec-inject` (`:601-628`) has no claims-gate or final-gate injection and no amendment branch, although the text at `:592` has them;
    - `workflow-spec-verify` (`:683-697`) lacks post-execute step 0 and review steps 3b and 3c;
    - `workflow-spec-generate` (`:534-553`) lacks step 6b (claim stubs).

    Fix: add the nodes and re-render.
15. The required state diagram is missing. `references/doc-spec.md:964` requires `stateDiagram-v2` for "Each skill with state/recovery". The skill now keeps gate records: chunk n's `<from>` defaults to chunk n−1's recorded head, and attest rebuilds from the last record (`spec-claims.md:355-359`). It also has the Spec Status Model ladder and the claim statuses. No living doc has a `stateDiagram`.
16. Artifacts are undocumented. The gate records (`docs/spec-claims/gates/<plan-stem>/chunk-<n>.json`, `final.json`) are never named; the only hit is pre-push's `final.json` at `:353`. `update`'s scoped plan `docs/plans/YYYY-MM-DD-{scope}-doc-update-plan.md` (`SKILL.md:455`) is missing from `:281`.
17. `:701-723`: the Spec Lifecycle Routing section lacks the "With claims enabled" column and the "points become gates with recorded verdicts" statement (`spec-lifecycle-protocol.md:9-17`).
18. `:829-840`: the User Interaction Gates table is missing three gates:
    - spec-generate 5b's "Apply deprecation notices now?" (`spec-lifecycle-actions.md:123-129`);
    - the human review of the amendment batch pasted into the PR description (`:273`; `doc-spec-verify.yml:132-146`);
    - the direction ruling's `by` principal (`spec-lifecycle-protocol.md:149`).
19. `:590`: the execute phase's aligned branch omits the guard "It never calls `update-index` while a claim of that spec fails" (`spec-lifecycle-actions.md:292`).
20. `:893-898`: the Verification Model table has no claims-verdict layer, although `SKILL.md:148` says "A verification verdict comes only from claims".

**references/hooks.md**

21. `:50`: the claims-check deletion guard and plan-selection rule are missing. The doc says only "each plan the PR touches". The code adds two rules:
    - a PR that deletes a `docs/spec-claims/` that its base has is `status=findings`, exit 1 (`claims-check.sh:82-97`; `spec-claims.md:375`);
    - a plan is attested only when it matches config `plans`, has `gates/<stem>/`, and is Completed or has `final.json` (`claims-check.sh:8-15,237-251`).

    Fix: document both.
22. `:50`, with `doc-spec-verify.yml:97-99,123` and `doc-freshness-schedule.yml`: the host test-environment setup has no durable home. The doc says "the host adds its test-environment setup before the claims step". The code makes that fragile:
    - every `install --ci` re-renders the managed workflows and overwrites them (`install.sh:1337-1349`; `hooks.md:85`), so an added step is lost;
    - the schedule runs the same claim-bound tests but has no setup slot;
    - an `indeterminate` schedule step only warns (`claims-check.sh:338-344`), but the close condition needs claims `ok` or `disabled` (`doc-freshness-schedule.yml:137-141`), so the issue never auto-closes.

    Fix: say where host setup survives a re-install, and document the schedule's need and the never-closing issue.
23. `:72` (and the `install.sh:156` help): `--ci-strict` does more than the doc says. The doc says "Fail the PR check on stale docs". In the code, `__CI_STRICT__` is also rendered into `doc-spec-verify.yml:129` (`DOC_SUPERPOWERS_STRICT` for `claims-check.sh pr`), so a claims check that cannot run fails the job (`install.sh:485-491`). Fix: add the claims half, in the doc and in the help.

**references/spec-claims.md and the claims help**

24. `:359` and the attest help (`doc-tools.sh:2275-2290`): the attest cross-check has been stricter since a129623 than they say. The doc says every change "appears in a chunk record or in `final.json`'s rebuilt reconciliations". In the code, final.json's own unrecorded changes (`$frecon.unrecorded`, `:11302-11304`) join `cross_check.unrecorded` (`:11118`). So a change after the last chunk record's head that final.json does not include is a silent reconciliation, even when an earlier chunk record has a matching entry. Fix: say so.
25. `:238,359`: attest's `from` remap is undocumented; `from-remapped` is only listed. In the code (`:11262-11283`), when the last usable chunk record's head is not a commit here, attest takes the one branch commit with the same patch id and emits `from-remapped`. With no such commit, or several, it exits 2 with "re-run the gate for chunk n". Fix: add one sentence.

**references/spec-lifecycle-actions.md**

26. `:212-215`: the chunk gate never says to re-run Step 1 after reconciling, as the final gate does (`:271`, "repeat until it exits 0"). A ruling is included only when `.record == $record_path` at the moment the gate writes the record (`doc-tools.sh:10571`). So a ruling committed after Step 1 is reported as a silent reconciliation by the next gate (`:10760-10762`) and by attest (`:11303`). Fix: end Step 3 with "then re-run Step 1; repeat until it exits 0".
27. `:312` (post-execute step 0): `claims attest --plan <plan> --final` writes a file and refuses a dirty tree, and step 0 says neither. With `--final`, attest calls `_claims_refuse_dirty` and overwrites `final.json` (`doc-tools.sh:11205-11210,11367`). This has two effects:
    - spec-verify leaves a rewritten, uncommitted `final.json`;
    - the documented recovery, "update CLAUDE.md/README.md … then re-run `spec-verify`" (`:347`), exits 2 while those edits are uncommitted, so the run can never PASS.

    Fix: use `claims attest --plan <plan>` without `--final` (the same checks, no write, no refusal), or document "commit first" and the rewrite.
28. `:257,316-317`: a target that R5 holds back is treated as skipped work.
    - attest passes with a named claim `diverged`, given a CODE-DIVERGES ruling and a tracker; only `unbuilt` and owed re-promotions are findings (`doc-tools.sh:11320-11324`).
    - R5 then holds the target below `Implemented`.
    - Step 3 reads an unadvanced target as "implementation tasks were skipped", so spec-verify FAILs a state the protocol sanctions.

    Fix: add "target held by R5 → not a finding", here and in the "Held short" P3 line.
29. `:288` vs `:293`: the execute phase contradicts itself. Line 288 says the gate is the verifier and the phase "does not judge drift by agent". Line 293 says to rule a Drifted deviation and "record the ruling in the sidecar". A ruling whose `record` is not this chunk's record is a silent reconciliation (`:10571,10760`). Fix: route claims-enabled drift to the chunk gate's Step 3, with `record` = `chunk-<n>.json`.
30. `:108` (spec-generate step 5, supersession): there is no claims handling. A `git mv` of a spec that has a sidecar leaves the sidecar's `doc` pointing at a missing path. That is a blocking V1 finding (`doc-tools.sh:6387-6389`), and the pre-commit leg then blocks. Fix: with `docs/spec-claims/`, retire the old spec's live claims (a RETIRE ruling whose `record` is the new spec) before the move.
31. No spec action writes the spec template's `Realized-by:` block (`doc-spec.md:234`). `set-implementation` and `implementation-status` exist for it (`doc-spec.md:338`), and doc-spec-verify grants `implementation-status`, but Task N+2 records no realization entry. Fix: add a Task N+2 `set-implementation` step, or state that the block is left to humans.

**references/spec-lifecycle-protocol.md, agent-prompt-template.md**

32. `spec-lifecycle-protocol.md:175` ("During execute") tells the wrapper to "rule the direction … before editing either side". `integration-patterns.md:76` says that reconciling outside a gate is a finding. Fix: "reconcile at the plan's `Claims gate (chunk N)` (its record is the ruling's `record`)".
33. `references/agent-prompt-template.md:65-77`: the Spec-Aware Review table has no claims rows.
    - A target held by R5 matches row 68 ("Flag as P1 — spec wasn't updated during implementation"), and no "Not a finding" row overrides it.
    - Nothing checks that Implementation Notes conformance lines cite a claim id or say `(unverified)` (V8n, `doc-spec.md:286`).
    - Nothing checks that the status block is current.

    Fix: add an R5-hold "Not a finding" row and a claims-enabled row.

**SKILL.md and doc-spec.md exit codes**

34. `SKILL.md:192` ("Command line") says "An option a subcommand does not take exits **2** … as do the wrong number of arguments". For `claims`, `_USAGE_RC=3` (`doc-tools.sh:2806`), and the help says "(exit 2; 3 for a claims subcommand)" (`:2375-2376`). SKILL.md's own claims row (`:163`) says "3 usage", so the file contradicts itself. Fix: add "(3 for a `claims` verb; claims exit 1 means findings)".
35. `references/doc-spec.md:1050`: the exit-status list ("`0` success; `1` …; `2` usage error") omits two cases. One is `fragments merge`'s refusal, exit 3 (help `:2524-2525`). The other is the claims family: 1 findings, 2 could not run, 3 usage, with precedence 1 > 2 > 0 (`:2527-2535`). Fix: add both, or defer to `--help` → "Exit status".

**evals**

36. `evals/evals.json` and `evals/fixtures/`: no eval exercises 3.2.0 claims behaviour (`grep -ci claim evals/evals.json` → 0). Uncovered:
    - claim stubs (6b), gate injection (2b/4b) and `**Claims:**` lines;
    - post-execute step 0 and review 3c;
    - the hooks' claims legs;
    - the inert path (no `Claims gate (chunk` task without `docs/spec-claims/`).

    Fix: add a claims-enabled `spec-inject --phase=plan` eval that asserts the gate titles and their order, and a negated gate-title assertion on `spec-inject-amends`.

### P3 Style

**R5 restated without `gated` (merged across four agents)**
1. `SKILL.md:540`, `references/spec-lifecycle-protocol.md:14`, `docs/conventions.md:306` and `docs/architecture/system-overview.md:168` restate R5 as "every claim … is `built` and passing". They drop "(or, with the configuration extension, `gated`)" from the canonical `spec-lifecycle-actions.md:28`. `spec-lifecycle-protocol.md:14` also widens "every claim the plan names for it" to all of the spec's claims, against `spec-lifecycle-actions.md:9` ("Do not restate these rules elsewhere — cite this section"). `conventions.md:312` has `gated` but not the `:amends` clause. Fix: cite **Spec Status Model → R5**.

**SKILL.md**
2. `:163`: "Prints one verdict JSON object" has one exception, `claims rulings --format markdown` (`spec-claims.md:269`).
3. `:148`: "A verification verdict comes only from claims (`claims run` / `attest`)" omits `promote`, the verb that stores verdicts (help `:2241`; `spec-claims.md:214,218`).
4. `:152`: "`code_commit` becomes the older of the two baselines". The code has three cases (keep, fresh, mixed), and only mixed takes the merge-base (`doc-tools.sh:3941-3966`; help `:2104-2111`).
5. `:151`: move-entry preserves "every other field", but `content_hash` is recomputed (help `:2081`; `:3734-3766`).
6. `:226`: "For one doc's full entry run `status <doc>`". `status` returns `{path}` plus the verdict, without `code_refs`, `code_oids`, `code_commit` or `content_hash` (`:4173-4175`), and nothing says where agents should read `code_refs`. Point to `jq '.docs["<doc>"]' docs/.doc-index.json`.
7. `:590` (Error Handling, jq row): a missing jq prints only "required command not found: jq" (`:32-36`). The `>= 1.6` and the version found appear only for a jq that is too old (`:42`).
8. `:91` lists `scripts/*validate*`, but the find at `:141` matches only `*validate_docs*` and `*validate_doc_references*`.
9. Audit step 8 (`:371`) counts unreleased commits "after that date (or after the matching git tag)". `references/release.md:15` and `fragments merge` (help `:2316-2317`) use the tag, else the commit that added the heading. Use one rule.
10. `:136`: the CI note's list of commands not granted omits `jq`. Discovery's filter (`:223`) and review-pr step 3 pipe through jq, and the `respond` job of `doc-review-pr.yml` (`:152`) grants no `Bash(jq:*)`.
11. Detect Scopes (`:211`): the `testing` globs (`*_test.*`, `*.test.*`, `test/`, …) miss prefix-named tests such as this repo's `scripts/test-*.sh` and pytest's `test_*.py`. So this repo's `testing` scope is not detected, and no `## Testing` section is required. Consider adding `test-*` and `test_*`.

**doc-tools.sh help text**
12. `:2263`: `claims gate [--holds <id>...]` reads as several ids after one flag. The option is repeatable with one id each (`holds=*`, `:2262`), and a second bare id is refused with exit 3 (`:10696`). Fix: `[--holds <id>]...`, "(repeatable)".
13. `:2264-2275`: the gate help omits that the gate runs V8 and V8n over the range and reports named claims that are unknown or still `unbuilt` (`:10797-10812`).
14. `:2530-2534`: the claims exit-2 list omits "a dirty tree where one is refused" (`_claims_refuse_dirty`; `spec-claims.md:264` has it).
15. `:2229`: the run help says "an unsafe or missing lint path … is one [finding]", but a missing path on an `unbuilt` claim is an allowed `assert-fail` (`spec-claims.md:205` is correct).

**references/spec-claims.md**
16. `:238`: it lists "`re-promote owed`" among the advisories that do not block in `run`, `promote`, `gate` and `attest`. In gate and attest it is a finding (`_claims_finding … "re-promote owed…"`, `:10650`); `:234` is correct.
17. `:92,238`: `render` (which sets `_CL_ALL_BLOCKING=1`) is missing from the "every finding blocks" lists.
18. `:15` (and help `:2465`): "for every invocation" overstates the inert contract. `_require_repo` and `check_deps` run first (`:2763-2771`, `:5855`), so an inert project still exits 2 with `"enabled":true` outside a repo, below its top level, or without jq ≥ 1.6 or a sha256 tool.
19. `:242,340`: the V1 row and the extension's V1 bullet omit the canonical-number check on `when` (`cl_canonical_num`, `:6235`). Only `:152` mentions it.
20. `:201`: the lint tier's "Run by" lists `validate` and `run`, but `gate` and `attest` also judge lint claims (`_claims_run_selected`, `:7859`).

**Other references (spec-lifecycle-actions, protocol, integration-patterns, output-templates, agent-prompt-template, tool-mappings, release, doc-spec)**
21. `spec-lifecycle-actions.md:361`: "Pipe the changed files, one per line". `:46` and the `check-freshness` help say to use `git diff -z`. Give the `-z` command.
22. `spec-lifecycle-actions.md:365`: step 3c uses `<base>`, but review mode's inputs (`:356-359`) define no base.
23. `spec-lifecycle-protocol.md:17`: "Three of the points then become gates with recorded verdicts". Only the chunk gate and the final gate write records; review records nothing.
24. `integration-patterns.md:74`: spec-verify "reports its verdict", but its step 0 re-runs `attest --final`, which writes `final.json` (see P2-27).
25. `integration-patterns.md:69`: "the same five actions". The protocol has 5 interception points and 3 actions.
26. `output-templates.md:114`: the Claims verdict exit field `{0 | 1 | 2 — claims verdict owed}` has no entry for the no-`--plan` case (`spec-lifecycle-actions.md:312`).
27. `output-templates.md:127` labels the fourth P3 line "Held at `In Review` (or left at `Approved`)", while `spec-lifecycle-actions.md:328` calls it "Held short of `Implemented`".
28. `output-templates.md:14`: the Summary line ("Fresh | Stale | Missing coverage | Untracked") has no slot for `check-freshness`'s `missing` and `deprecated` counts (`doc-tools.sh:3211-3212`).
29. `agent-prompt-template.md:31-32`: its VERIFICATION block is shorter than the one `SKILL.md:569-571` says every dispatched prompt must include ("you MUST verify your findings by reading both the doc AND its code_refs"). Use SKILL.md's text.
30. `agent-prompt-template.md:34-41`: step 3 asks for "Accurate sections", but the output format has no place for them.
31. `tool-mappings.md:36`: the Subagent dispatch row lists `init`, `audit`, `review-pr` and `update`, but `release` also dispatches a `general-purpose` drafter (`release.md:23`).
32. `release.md:7-8`: `RELEASE-NOTES.next/README.md` is placed only when the doc-pr-release helpers ship (`doc-tools.sh:5403-5410`), not by a default `install --ci` (`install.sh:51-52`). Say so, and point to `$ROOT/scripts/hooks/ci/doc-pr-release/RELEASE-NOTES.next.README.md`.
33. `doc-spec.md:1034`: "the CI coverage gate" is a downstream repo's term (`RELEASE-NOTES.md:349`). Use "the CI freshness check".

**references/hooks.md, the installer help, RELEASE-NOTES.next.README.md**
34. `hooks.md:123`: "no section and a body ending inside an unclosed fence, is refused" holds for the default section only. For a named section, exit 8 becomes 7 and the section is inserted at the top (`update-pr-body.sh:142-146`).
35. `hooks.md:113`: "Push to non-main". The template ignores the configured base branch, not `main` (`doc-audit-update.yml:19`, `branches-ignore: [__BASE_BRANCH__]`).
36. `hooks.md:11`: `hooks status [--git] [--claude] [--ci]` omits `--all`, which `install.sh:118,1541` accepts.
37. `hooks.md:15` says `install.sh help` "lists every hook and workflow", but the help never mentions claims. The `doc-spec-verify` entry (`install.sh:101`) has no claims job, and the pre-commit and pre-push lines (`:127,131`) have no claims legs. The fix belongs in `workflow_desc` / `usage`.
38. `hooks.md`: under `DOC_SUPERPOWERS_QUIET=1`, pre-push exits before its claims leg (`pre-push:26`), but pre-commit still runs its leg and can block silently. Neither behaviour is documented.
39. `RELEASE-NOTES.next.README.md:108-111`: the skip list omits "the no-notes marker together with notes" (`doc-tools.sh:4541`) and "an empty ### heading" (`:4593`). Also, `:141` says an empty fragment is skipped as "no notes", but a 0-byte file is skipped as "an empty file" (`:4921`).
40. `hooks.md:127-129`: "Every template's `run:` steps are scripts in `.github/scripts/doc-superpowers-steps/`" has two exceptions: `doc-spec-verify.yml:146` and the inline step at `doc-pr-release.yml:74` (see P1-6).

**docs/workflows/doc-superpowers.md**
41. `:353`: "it ends with one `claims (advisory): …` line". The line is printed once per pushed branch (`pre-push:87,103-104`).
42. `workflow-hooks.png` (source `:455-461`) shows a literal `\n` in every multi-line label, because the source uses `\n`, not `<br>`. Its uninstall `--claude` node omits `hook-lib.sh` (`:436` says it is removed), and its uninstall `--git` node omits unregistering the merge driver.
43. `:862`: the agentic sequence declares `GP as General-Purpose Agent` and never messages it, and it covers `init` only.
44. The spec-inject plan-phase numbering differs from the reference. The doc has 3 = finalize, 4 = amendment, 4b = all claims; the reference has 1b, 2b, 3 = amendment, 4 = finalize, 4b = final gate. The doc never names `Task N+1g` / `Task N+2g` (`spec-lifecycle-actions.md:208,266`).
45. The audit step numbering differs from `SKILL.md`. The doc merges steps 4–5, so its dispatch is step 8 where `SKILL.md:372` has 9, and its Sub-Agents row says "audit step 8".
46. Audit step 6 and sync step 6 compare README "against actual SKILL.md actions". `SKILL.md:370,514` now say "against the project's own code and interfaces" and "against the project itself".
47. spec-verify step 5's PASS/FAIL leaves out the claims clause of `spec-lifecycle-actions.md:342-343`.
48. Release step 3 says "1 is any other failure". `release.md:21` says "Any other non-zero exit (1, 2)".
49. Update agents: the Steps table says "one per scope", the Sub-Agents table "General-purpose (per doc) | update step 3".
50. `:7`: project scripts are "listed, never run". `SKILL.md:91` allows a run the user asks for by name, except in review-pr and CI.
51. `:371`: `--ci-strict` does not mention that it also fails the claims job when a check cannot run (`doc-spec-verify.yml:129`).
52. The Sub-Agents table omits the judge that the orchestrating agent may dispatch during a claims gate. "Spec actions dispatch no agent" is true of the actions, not of the tasks they inject.
53. `workflow-doc-superpowers.png` routes every action through "Dispatch parallel agents". In fact release dispatches one agent, and hooks, sync, diagram and the spec actions dispatch none. The flowchart is also named `workflow-doc-superpowers.png`, not `agentic-doc-superpowers.png` (`doc-spec.md:979`), and there is no `agentic-overview.png` (see P2-1).
54. The User Interaction Gates table (`:829-840`) also omits the weekly judge-sample review, and review-pr asking the user for a missing base (`SKILL.md:418`).

**docs/architecture/system-overview.md**
55. `:154`: Claude uninstall "removes … the three scripts". The installer also installs and removes `hook-lib.sh` (`install.sh:48,916-918,957-962`).
56. `:115,154`: "a global `core.hooksPath` is refused". The installer refuses one "from your global or system git config" (`install.sh:135`).
57. `:116` says `fragment-lib.sh` is sourced by "`extract-context.sh` and `commit-and-push.sh`". `verify-fragment.sh` sources it too (`verify-fragment.sh:23-30`).
58. `:63` says only release and hooks load a REQUIRED reference. `SKILL.md:44-46` also makes `spec-lifecycle-actions.md` REQUIRED for the spec actions, and `spec-claims.md` when `docs/spec-claims/` exists.
59. `:72,117` do not say that the Direction protocol is now defined in `spec-lifecycle-protocol.md:127`.
60. `c4-container.png`: several edge labels overlap, as the abfd5e2 message acknowledges:
    - "Uses spec template…" crosses "Runs the vendored…" over the Hooks Engine title;
    - "Registers it for…" crosses "Reads/updates .doc-index.json…";
    - "Routes spec-generate…" crosses "Vendors doc-tools.sh…";
    - "Scans structure…" runs over Wrapper Skills.
61. The doc is `doc_modified`. The index records `content_hash` `sha256:cd3510…`, but after abfd5e2 the file hashes to `f908914…`. The edits were verified accurate: re-baseline the doc with `update-index` after its P2 edits. Its `code_refs` also omit `evals/` and `.github/workflows/tests.yml`, which `:127-128` describe.

**docs/codebase-guide.md**
62. `:184`: the `tools uninstall` and `tools status` synopses drop `[--dest <path>]` (`_VERBS` rows `dest=`; the help prints it).
63. `:87,142,196` attribute the Direction protocol to `spec-claims.md`. `spec-claims.md:380` says it is "defined in **Direction protocol** in `references/spec-lifecycle-protocol.md`; this reference does not repeat them", and the guide's protocol rows (`:86,143,194`) don't mention it.
64. Its `code_refs` (`skills/doc-superpowers/SKILL.md`, `scripts/`) omit `references/`, `evals/` and `.github/`, which the guide maps (`:21-26,112-114,142,152-155`). Fix with `set-code-refs`.

**docs/conventions.md**
65. `:312`: "`spec-verify` is read-only and writes no `Status`". With claims enabled, post-execute step 0's `attest --final` writes `final.json`.
66. `:278`: "The schedule closes its issue only after `status == 'ok'` with nothing stale or missing". It also requires claims `disabled` or `ok` (`doc-freshness-schedule.yml:139-141`), and claims findings keep the issue open (`:55-56`).
67. `:83`: the self-install drift bullet names only `install --ci`. The tests.yml drift step also fails on a missing `.gitattributes` block, and names `install --git` (`tests.yml:233,239`).
68. `:63-65`: "`feature/<name>`" branches. In practice the branches are `feat/…` (8 on the remote), `design/…` and `chore/…`, and commits use scoped types (`fix(claims):`, `release:`).
69. `:191` allows `.svg`, which no template uses (`doc-spec.md:968,996`: `{type}-{name}.png`). The File Names table (`:182-191`) also omits the Plans, Templates and Index-file rows of `doc-spec.md:987-1000`.

**docs/guides/getting-started.md**
70. `:209-225`: the expected-output checklist omits the scope-conditional outputs: `architecture/{component}.md`, `workflows/agentic/README.md`, `workflows/deployment.md`, `erd.png` and the `## Testing` section. It also omits the `docs/decisions/` alternative (`SKILL.md:211,294-310`).
71. `:67`: `code_oids` is "recorded when a doc is re-baselined", but `build-index`, `add-entry` and `set-code-refs` also record it (help, "Freshness (index schema v3)"). Use "indexed or re-baselined".
72. `:126-127`: `tools install` resolves `--dest` against the current directory, so run it from the top level. Shipping the doc-pr-release helpers also creates `RELEASE-NOTES.next/README.md`.

Not counted (optional): `.claude-plugin/plugin.json:3,11-22`, `.cursor-plugin/plugin.json:4,12-23`, `marketplace.json:13` and `gemini-extension.json:3` describe "spec lifecycle tracking" and have no claims keyword. Add "executable spec claims" if wanted. Only `version` goes through `bump-version`.

### Structural / coverage observations (no action taken)
- The Scope → Generated Docs Matrix gaps (P2-1) are a standing structural choice of this repo. Resolve them by decision, not by `update` creating files.
- This repo self-installs 2 of the 8 CI templates (`installed.json`: `doc-freshness-pr`, `doc-freshness-schedule`). The new claims job lives in `doc-spec-verify`, which is not self-installed, and the repo has no `docs/spec-claims/`. So its own CI exercises none of the 3.2.0 claims legs, which is consistent with claims being opt-in.
- The repo's own CI tier has no drift:
  - `cmp` shows `.github/scripts/doc-tools.sh` and all 10 step scripts identical to `scripts/`;
  - both workflows match their templates rendered with `installed.json`'s choices;
  - `.gitattributes` matches the installer's `ATTR_BLOCK`;
  - `tests.yml` runs all six suites on both legs.

### CLAUDE.md Status
- [x] Directory Structure: current. The tree matches the filesystem at abfd5e2, including `test-spec-claims.sh`, `claims-check.sh` among the 10 step scripts, `references/spec-claims.md`, the contents of `.github/scripts/`, and the gitignored per-user Claude tier.
- [x] Key Files: current. "18 subcommands" matches `_VERBS` and `doc-tools.sh --help`, and every listed path resolves.
- [x] Commands: current.
- [ ] Conventions → Testing: **stale**. The per-suite counts predate five commits that added assertions (P1-9).

### README.md Status
- [ ] Feature list: **stale**. There is no bullet for executable spec claims, and the spec bullets miss claim stubs, gates, the claims verdict and R5 (P2-4).
- [ ] Command / API list: **stale**. The `claims` verbs are named (`:177`), but:
  - the hook descriptions omit the claims legs and `DOC_SUPERPOWERS_CLAIMS_SKIP` (P2-2);
  - the CI paragraph omits the `claims` job, the schedule's claims step and timeout, and the claims half of `--ci-strict` (P2-3);
  - Dependencies omit git ≥ 2.36 (P2-5).
- [x] Usage examples: current. Every documented command parses against `install.sh` and `doc-tools.sh`.

### RELEASE-NOTES.md Status
- [ ] v3.2.0 (2026-10-14) is written but **untagged** (`git tag` tops out at `v3.1.0`).
  - No commit is dated after 2026-10-14, so by the step-8 rule there are 0 unreleased commits.
  - But 21 commits follow the release commit ab19876, and the entry was last revised in 61167c8.
  - Five code commits landed since that revision: 745ea2d (promotion fingerprint), ffca4cf (V1 canonical `when` numbers, no-history wording), c743712 (V8n citation shape), e63b9f1 (claims-check fence pairing) and 3d38dba (gate reads the previous record strictly).
  - The entry describes the rule 745ea2d removed (P0-2), keeps the obsolete "Known gap" paragraph (P1-10), and carries pre-fix suite counts (P1-9).
  - Close-out Task 6 owes the revision.

### Actions
- Run `/doc-superpowers update --report=docs/plans/2026-10-14-audit-report.md` to apply the Update Tasks below
- Run `doc-tools.sh update-index <doc>` after manual review
- CLAUDE.md is flagged stale above (Testing counts): update it per the `references/doc-spec.md` CLAUDE.md update rules after re-measuring the suites
- README.md is flagged stale above: update it per the `references/doc-spec.md` README.md update rules
- RELEASE-NOTES.md is flagged stale above: revise the unreleased v3.2.0 entry (close-out Task 6) rather than drafting a new version

## Update Tasks

**Generated by:** /doc-superpowers audit
**Branch:** design/spec-claims

### Scope
`all`, covering:
- the scopes `application`, `ci-cd`, `agentic` and `spec`, and the always-generated docs (architecture, workflows, guides, codebase guide, conventions);
- `CLAUDE.md`, `README.md`, `RELEASE-NOTES.md`, `SKILL.md`, `references/` and the help text;
- the CI templates' prompts, and `evals/`.

The skill's globs did not detect `testing` (P3-11), so the suites were reviewed under `ci-cd`.

### Findings Summary
| Priority | Count | Action |
|----------|-------|--------|
| P0 Critical | 2 | Must fix before merge |
| P1 Stale | 10 | Update recommended |
| P2 Incomplete | 36 | Add coverage |
| P3 Style | 72 | Low priority |

### P0 — Critical Updates
- [ ] `references/spec-lifecycle-actions.md` (step 3c) and `scripts/hooks/ci/doc-spec-verify.yml` (prompt): tell the CI agent to skip 3c where the non-AI `claims` job covers it (P0-1)
- [ ] `RELEASE-NOTES.md` v3.2.0: replace the "record at `promotion.at`" sentence with the `promotion.proved` rule, and add the V1 canonical-`when` rule (P0-2)

### P1 — Stale Updates
- [ ] `SKILL.md`, the `doc-tools.sh` help, `references/doc-spec.md`: archiving resets `superseded_by`. Either fix `deprecate-entry` to keep it (code), or pass `--superseded-by` in every archive recipe and document the reset (P1-1)
- [ ] `references/spec-lifecycle-actions.md`: chunk gate Step 3 needs `--holds <id> --by <principal>`; route exit 3 (P1-2)
- [ ] `references/spec-claims.md`: the path into `built` for lint, log and judge claims; decide whether the doc or the code changes (P1-3)
- [ ] `references/hooks.md`: the `claims` job sets `persist-credentials: false`; add the PR-head-code bullet (P1-4)
- [ ] `references/spec-lifecycle-protocol.md`: review selects test claims by runner `paths` (P1-5)
- [ ] `docs/workflows/doc-superpowers.md`: three `run:` exceptions (P1-6); the claims legs run without an index (P1-7)
- [ ] `docs/conventions.md`: never-reused spec and ADR numbering (P1-8)
- [ ] `CLAUDE.md`, `RELEASE-NOTES.md`: re-measure and update the six suite counts (P1-9; close-out Task 6)
- [ ] `RELEASE-NOTES.md`: delete the obsolete "Known gap" paragraph and note the re-render (P1-10)

### P2 — Missing Coverage
- [ ] Owner decision: the Scope → Generated Docs Matrix gaps (`docs/specs/`, `docs/adr/`, `ci-cd.md`, `deployment.md`, `workflows/agentic/`). Create them or record the exemption; do not create them unasked (P2-1)
- [ ] `README.md`: claims legs and `DOC_SUPERPOWERS_CLAIMS_SKIP` (P2-2); the CI claims job, the schedule step and `--ci-strict` (P2-3); a feature bullet and the spec actions' claims behaviour (P2-4); git ≥ 2.36 (P2-5)
- [ ] `docs/guides/getting-started.md`: prerequisites (P2-5); what opting in to claims implies (P2-6); `--plan` in the post-execute example (P2-7)
- [ ] `docs/conventions.md`: spec-claims naming and directories (P2-8); a `## Code Style` section with the bash-3.2 and jq-1.6 guards (P2-9)
- [ ] `docs/architecture/system-overview.md`: a Spec Claims container, its stores and a Tech Stack row (P2-10); host adapters and `doctools → project` in the C4 diagrams, re-rendered (P2-11); the claims pre-commit leg and a claims key decision (P2-12)
- [ ] `docs/codebase-guide.md`: a claims Code Flow (P2-13)
- [ ] `docs/workflows/doc-superpowers.md`: three claims-era diagrams (P2-14); the state diagram (P2-15); the gate-record and update-plan artifacts (P2-16); a claims column in routing (P2-17); the missing user gates (P2-18); the `update-index` guard (P2-19); a claims verification layer (P2-20)
- [ ] `references/hooks.md`: the deletion guard and plan selection (P2-21); durable host setup and the never-closing schedule issue (P2-22); the claims half of `--ci-strict`, also in the `install.sh` help (P2-23)
- [ ] `references/spec-claims.md` and the attest help: the a129623 cross-check (P2-24); `from-remapped` (P2-25)
- [ ] `references/spec-lifecycle-actions.md`: the chunk-gate re-run (P2-26); post-execute step 0 without `--final`, or commit-first (P2-27); an R5-held target is not a finding (P2-28); execute-phase drift goes to the gate (P2-29); supersession retires claims (P2-30); who owns `Realized-by:` (P2-31)
- [ ] `references/spec-lifecycle-protocol.md`: reconcile at the gate during execute (P2-32)
- [ ] `references/agent-prompt-template.md`: claims rows in Spec-Aware Review (P2-33)
- [ ] `SKILL.md` "Command line" and the `references/doc-spec.md` exit status: the claims exit family and `fragments merge` exit 3 (P2-34, P2-35)
- [ ] `evals/`: a claims-enabled eval and an inert-path negation (P2-36)

### P3 — Style
- [ ] Apply P3-1 … P3-72 (one-line fixes, listed above by doc). Re-baseline `docs/architecture/system-overview.md` with `update-index` once its edits land (P3-61)

### Execution
Run `/doc-superpowers update --report=docs/plans/2026-10-14-audit-report.md` to apply these tasks. Some items change code rather than docs, so they belong to an implementer, not to `update`, which should report them:
- P0-1's template prompt;
- P1-1's preferred fix, and P1-3 if the code side is chosen;
- the installer help (P2-23, P3-37) and the doc-tools help (P3-12–P3-15).

After any change to a CI template or `doc-tools.sh`, run `bash scripts/hooks/install.sh install --ci` and commit what it writes.
