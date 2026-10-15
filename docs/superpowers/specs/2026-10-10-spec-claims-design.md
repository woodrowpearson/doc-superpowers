# Design: Spec Claims — Executable Spec Statements, Recorded Lifecycle Gates, and a Direction Protocol

**Date:** 2026-10-10
**Status:** Approved by the owner 2026-10-10 — reviewed with its host-project adoption design (three consult rounds on the combined design, then a review of this split). Plan: `docs/superpowers/plans/2026-10-10-spec-claims.md`.
**Author:** woodrow pearson (with Claude)
**Issue:** none yet
**Target version:** 3.2.0 — additive and opt-in: a project with no `docs/spec-claims/` directory sees no behaviour change.

## Problem

A host project's conformance audit found specs and ADRs that had disagreed with the code for up to five months, across one subsystem's governing docs. The host ran the full spec lifecycle — `spec-generate` from design docs, `spec-inject` into plans, `spec-verify` — and the drift still went undetected. Four drift shapes were traced:

| Shape | What happened |
|---|---|
| **Unbuilt** | An ADR decision was never decomposed into a plan task. Its copies in a spec and in model prompts were false from the day they were written. |
| **Never reconciled** | A spec clause was copied from a design written for an earlier architecture. The code was built to the later architecture, and four correct diagnoses over two months each fixed only the symptom in hand. |
| **Ratified deviation** | A decision lived only in an issue. The implementer substituted a different approach, and a spec section written from the landed code the same day recorded the deviation as an "architectural decision". |
| **Parity by assertion** | An evaluation's control arm, documented as "byte-for-byte the shipped call", sent a different request from production's. Months of conclusions rested on it. |

The one detection that fired was resolved by editing the spec to match the code. Nobody asked which side was the intent.

### What doc-superpowers contributed

| # | Failure class | Where |
|---|---|---|
| **F1** | Content-hash freshness cannot see an unbuilt requirement or a gap in a file outside `code_refs`; `update-index` re-baselines with no record of what was checked; the execute phase's "aligned" branch calls `update-index` itself. | `scripts/doc-tools.sh` `check-freshness` / `update-index`; `references/spec-lifecycle-actions.md` Execute Phase |
| **F2** | `spec-verify` (both modes) reads no spec text: it is freshness, status and coverage bookkeeping. | `references/spec-lifecycle-actions.md` Post-Execute / Review Mode |
| **F3** | Execute-phase drift detection runs only when a spec reads stale, judges a diff with an agent, and on drift "flags and continues". `:amends` specs are exempt from drift entirely. | Execute Phase |
| **F4** | The five interception points are documented (`spec-lifecycle-protocol.md` § Lifecycle Overview), but nothing records that a point ran or what it found, so a wrapper that skips one is indistinguishable from a wrapper that ran it. The host's plan → execute chain skipped the per-chunk point for months. | `references/spec-lifecycle-protocol.md`, `references/integration-patterns.md` |
| **F5** | Remedy direction is undefined: "If deviation flags returned → surface to user"; post-execute FAIL offers "update spec status" or "accept drift with documented rationale". The path of least resistance — edit the doc to match the code — became the host's written policy ("code is authoritative"). | Protocol § Wiring; post-execute FAIL template |

### Planted-drift experiment (host repo, doc-superpowers v3.1.0)

| Planted drift | Tool | Result |
|---|---|---|
| none — run the standard remedy on a spec 76 commits stale | `update-index` | `current`; nothing read |
| an unbuilt normative requirement added to a spec | `status` → `update-index` → `check-freshness` | missed |
| a threshold changed in a `code_refs` file, contradicting the spec | `check-freshness --tree` | "file changed", shared with 17 unrelated docs; the host's tests still passed |
| then the suggested remedy | `update-index` | flag cleared, contradiction in place |
| a deploy-config change outside every `code_refs` disabling the behaviour | `check-freshness` | missed |
| the two code drifts | `spec-verify --mode=review` | missed: generic "Stale" findings only |

### Root cause

No statement in a spec is ever **executed** against the system, no lifecycle point **records a verdict**, and no rule says **which side is the intent** when they disagree. Specs are written first in this lifecycle (`spec-generate` runs before the plan), so the spec's normative text is the intent — but nothing in the tooling says so.

## Design

### A. Claims — the unit of verification

A **claim** is one atomic, falsifiable statement in a governing doc about what the system does, what an interface carries, or how the system is configured. Rationale and history are not claims.

**Normative vs descriptive text.** A governing doc holds two kinds of text:
- **Normative** — decisions, requirements, invariants, interfaces, resolved open questions, dated `AMENDED` blocks. Written first (`spec-generate`), approved by the human who reviews docs. **Claims anchor only in normative text, and normative text is the intent.**
- **Descriptive** — `## Implementation Notes` and any section the execute phase writes from landed code. It reports what was built and never overrides normative text. A descriptive line that asserts conformance ("as specified", "conforms", "aligned with", "matches §…", "implemented per") must cite a claim id whose verdict it reports, or carry `(unverified)`.

**Governing docs** are, by default, `docs/adr/*.md` and `docs/specs/*.md`; a host may add globs (e.g. evaluation pre-registrations). A decision that lives only in an issue, plan or design must be promoted into a governing doc before a plan task implements it.

### B. Storage

- **Sidecar per governing doc:** `docs/spec-claims/<DOC-ID>.json` (JSON, so `jq` reads it — no new dependency). `<DOC-ID>` is the doc's `ADR-NNN` / `SPEC-CAT-NNN` id or, for a host-added glob, its file stem.
- **Host config:** `docs/spec-claims/config.json` — governing-doc globs, extra normative/descriptive headings, runner adapters, the direction policy (§F), which checks block, and — only for the optional configuration extension (§B.1) — a config adapter.
- **Gate records:** `docs/spec-claims/gates/<plan-stem>/chunk-<n>.json` and `final.json` (§E).
- **Promotion verdicts:** a local store, `$(git rev-parse --git-common-dir)/spec-claims/promotions/<digest>.json` (not committed).

A claim record:

```json
{
  "id": "SPEC-AUTH-001#token-ttl",
  "quote": "access tokens expire after 15 minutes",
  "states": "An issued access token is rejected 15 minutes after issue.",
  "kind": "behaviour",
  "subject": ["src/auth/token.py"],
  "status": "built",
  "enforced_by": "test",
  "test": {"runner": "pytest", "node": "tests/unit/test_token.py::test_ttl_is_15_minutes"},
  "nonvacuity": {"mutant": {"file": "src/auth/token.py", "find": "TTL_SECONDS = 900", "replace": "TTL_SECONDS = 1800"}},
  "promotion": {"at": "<sha>", "verdict_sha256": "<digest>"},
  "tracker": null,
  "frozen_at": null,
  "restates": [],
  "rulings": [{"date": "2026-10-10", "direction": "DOC-STALE", "by": "<principal>", "record": "<path>"}]
}
```

> ⚠️ **AMENDED 2026-10-14 — the promotion records what it proved.** Landed by `docs/superpowers/plans/2026-10-14-spec-claims-closeout.md` Task 1. `promotion` is `{at, verdict_sha256, proved}`, and `proved` is `{states, test, subject, enforced_by, nonvacuity, when}`. Each field but `enforced_by` is the sha256 of that field's canonical JSON: the compact `jq -cS` bytes of its value, `null` for an absent field, with no trailing newline. `enforced_by` is stored as its value. `proved` describes the record `promote` ran green against, and the stored verdict carries the same `proved`. A `built` or `gated` claim's promotion must carry it with the six keys (V1). `promotion.at` stays as a record only: nothing reads it back, because a squash or rebase merge leaves that commit on no branch.

**Quote anchoring.** `quote` is a verbatim substring of the doc after normalisation (whitespace and line wraps collapsed; `*`, `_`, `` ` `` emphasis stripped) with exactly one live occurrence (or `quote_occurrence: n`). Text inside `~~…~~` and the generated status block is not live; dated `AMENDED` blocks are live (they carry the current normative text). Editing the prose breaks the quote, so a doc edit to a claimed sentence is always detected without inline markup.

**Statuses** (strict-xfail semantics — the expected result is part of the status):

| Status | Meaning | Expected check result | Requires |
|---|---|---|---|
| `built` | the code does what the claim states | pass; a failure is a finding | a check; for `test` a verified non-vacuity proof and a `promotion` |
| `diverged` | ruled CODE-DIVERGES, not yet fixed | an **assertion** failure; a pass is a finding ("promote") | a `CODE-DIVERGES` ruling + an open tracker |
| `unbuilt` | planned, not implemented | any failure, or no check yet | an open tracker |
| `retired` | the doc no longer asserts it | none | a `RETIRE` / `DOC-STALE` ruling; no live occurrence of the quote |

**Kinds** (`kind`): `behaviour`, `interface`, `config` — plus any host kinds declared in `config.json` `kinds` (e.g. an evaluation-parity kind). **Frozen claims:** `frozen_at: <sha>` marks a claim that was true of a concluded record (e.g. a finished evaluation); it is validated structurally and excluded from `run`.

**Enforcement tiers** (`enforced_by`, ranked `test > lint > log > judge`): `test` (a host test that binds itself to the claim id, run through a runner adapter); `lint` (a static pattern with `expect: present|absent` and a `selftest: {violates, clean}` pair, so a vacuous pattern fails validation); `log` (a host-defined production query, scheduled runs only); `judge` (no mechanical check is feasible — carries `why_not_mechanical` and is sampled by a reviewer).

**Non-vacuity.** A `built` `test` claim proves its test can fail on the behaviour it claims: `observed_red: <sha>` (at that SHA the bound test failed with an **assertion** failure, re-verified against that SHA's subject files) or `mutant: {file, find, replace}` (`find` matches exactly once; under the mutation the test fails with an assertion failure). `promote` is the only path into `built` (§C).

**The doc shows its own status.** A doc with a sidecar carries a generated `## Claim status` section, delimited by `<!-- spec-claims:status:begin -->` / `<!-- spec-claims:status:end -->` markers (idempotent re-render; the marked span is excluded from V2/V8), inserted on first render immediately before the doc's second `##` heading and found by its markers thereafter. It lists every non-`built` claim with its tracker and, when every claim is `built`, renders one line (`Claims: N built`) so a reader knows the doc is claim-checked. No dates, SHAs or live values; it changes only when a status changes, so it adds no churn; the human who reviews docs sees the gap in the doc they read.

### B.1 Optional extension — configuration-conditioned claims

**Off unless a host declares a config adapter in `config.json`.** A project with no feature flags, environment switches or build variants never sees anything in this section: its claims are `built`, `diverged`, `unbuilt` or `retired`, its tests run under the code's defaults, and nothing below is checked.

The extension exists for hosts whose production behaviour depends on recorded configuration — feature flags, environment variables in deploy manifests, build variants — where a claim can be true of the code yet not of what production runs. It adds:

- **`when: {KEY: VALUE}`** on a claim — the condition under which the claim holds. The bound test establishes it itself (an environment variable, a configuration mock — however the host's configuration works); the claim declares it, and the runner adapter's `list` reports the conditions the test sets, so V3 can compare. The checker never injects configuration.
- **Status `gated`** — the claim passes under `when:`, but the host's **recorded production configuration** does not set it. Expected result: pass under `when:`. Requires a tracker for the configuration change, a non-vacuity proof and a `promotion` (it enters through `promote`, like `built`). It is never a final state: once the recorded configuration satisfies `when:`, the claim is promoted to `built`. With the extension on, `built` means true under the recorded production configuration.
- **Configuration-faithful checks** (part of V3) — when a claim's subject reads a key whose recorded production value differs from its code default, the claim must pin that value in `when:`, or declare `config_independent: <reason>`.
- **V10 configuration** — a staged change to a configuration surface re-classifies claims whose `when:` or subject names a changed key: a `gated` claim now satisfied → promote; a `built` claim no longer satisfied → a ruling is owed (§F); a `diverged` claim whose `when:` is being switched on → finding. `claims validate --config KEY=VALUE` runs the same check before a configuration change that is published outside git.
- **The config adapter** (contract in §D) — tells the checker which files carry configuration, the recorded and default value of each key, and which keys a path reads.

In the status block, `gated` claims name their condition. Under R5 (§E), a spec may reach `Implemented` with `gated` claims: `Implemented` means the code implements the spec, and the status block — not the Status field — says what production runs, so a spec's Status never tracks live configuration.

### C. `doc-tools.sh claims` — the checker

New subcommand group, bash 3.2 + `jq` ≥ 1.6, like the rest of `doc-tools.sh`. Every ratchet compares against `git merge-base HEAD <base>` (default `origin/main`), never the base tip, so a branch behind trunk never sees trunk's ruled changes in reverse.

| Command | Does |
|---|---|
| `claims validate --staged \| --all` | structural checks below; executes no test (`--config KEY=VALUE`: §B.1) |
| `claims run --claims <ids> \| --planes-of <range> \| --all` | executes `test` claims through runner adapters, `log` claims through the log adapter (scheduled runs only), and re-runs `lint`; `--planes-of` runs every claim of each runner whose paths the range touched; frozen claims are skipped |
| `claims promote <id>` | runs the test green (under `when:` when §B.1 is on), verifies the non-vacuity proof in a throwaway worktree, stores the verdict, writes `promotion` |
| `claims render [--check]` | writes / checks the status blocks |
| `claims gate --plan <p> --chunk <n>` · `claims attest --plan <p> [--final] [--deep]` · `claims rulings --range <a>..<b>` | §E |

**Checks** (each scoped to touched claims and staged files under `--staged`; `--all` is ambient):

| Check | Fails when |
|---|---|
| V1 schema | malformed record; id not `<DOC-ID>#<slug>`; duplicate id; doc not governing; a `when:` or `gated` with §B.1 off, or a `when:` key the config adapter does not know |
| V2 anchor | quote not uniquely live; a `retired` claim's quote still live; an `AMENDED` block re-quoting a claimed sentence without `quote_occurrence` or a ruling |
| V3 binding | `test` claim whose node the runner adapter's static `list` does not report as bound to this id (§D); a bound node reported outside the host's normal test gate (`in_gate: false`) or importing its subject at module level (`subject_imports_ok: false` — an unbuilt subject would be a collection error no expected-failure can absorb); `built` (or `gated`) without non-vacuity + `promotion`; a `mutant.find` not unique; with §B.1 on, the configuration-faithful checks and a `when:` the adapter reports the test does not establish |
| V4 lint | selftest `violates` passes or `clean` fails; the pattern contradicts the status |
| V5 status | `diverged`/`unbuilt` (or `gated`) without an existing tracker; `diverged`/`retired` without the required ruling; `judge` without `why_not_mechanical` |
| V6 ratchet | vs merge-base: `states` changed, status moved off `built`, status moved into `built` (or `gated`) without a stored-verdict `promotion` (a promotion whose verdict is in another clone's local store reports `unverifiable-here`, advisory; the scheduled run re-verifies it), `enforced_by` lowered, a claim deleted, or a re-anchor that changed any token — without a new ruling (§F). A re-anchor equal after normalisation (a reflow or move) needs none. A ruling's `record` must exist and must not be the doc or its sidecar. |
| V7 restates | a claim restating another whose `states` changed after this claim's last ruling (sibling sweep) |
| V8 coverage | a staged hunk adds or changes normative text no claim covers. Structural keys: an ADR's `## Decision`; spec sections whose headings match the template's normative sections (requirements, invariants, interfaces, inputs/outputs, decisions, phase/stage contracts) plus host-configured headings; the resolved column of an `## Open questions` table |
| V8n descriptive | a descriptive-section line asserting conformance without a claim id or `(unverified)`; citing a normative section is exempt |
| V9 claim-bound test edit | a staged change inside a test bound to a claim (reported by the runner adapter) — listed for adjudication: `states` still holds, or a ruling is owed |
| V10 configuration | §B.1 only — configuration surfaces re-classify conditioned claims |
| V11 status block | the block differs from `render` output (only when that doc's sidecar is staged) |
| V12 plan structure | for a new (or gate-carrying) plan with governing specs: a chunk without a claims-gate task placed **before** its spec-update task (the gate's verdicts are what the Implementation Notes cite), or no final gate before the finalize tasks; **decomposition:** an `unbuilt` claim of a target spec named by no task, a task touching the host's configured code roots with no `**Claims:**` line, or a `**Claims:** none` task that links an issue or design as the source of its behaviour (the decision must be promoted into a governing doc first); a plan moving to `Completed` without a final-gate record that `attest --final` accepts |

> ⚠️ **AMENDED 2026-10-14 — V6 decides by `proved`, not by history.** Landed by `docs/superpowers/plans/2026-10-14-spec-claims-closeout.md` Task 1. A `built` or `gated` claim that is new or changed is compared with its `promotion.proved` (§B) field by field, whether or not the local store holds its verdict. No history is read. A field equal to its `proved` value is unchanged. A `states` difference covered by a new `DOC-STALE` or `RETIRE` ruling is the advisory `re-promote owed`, and so is a `nonvacuity` or `when` difference that comes with it (an amended threshold needs a new mutant). Any other difference is a V6 finding that names the field and says `run claims promote <id>`: a `test`, `subject` or `enforced_by` difference, a `nonvacuity` or `when` difference without such a `states` amendment, and a `states` difference without `DOC-STALE`/`RETIRE`. When the store holds the verdict, the verdict must still bind the claim (its id, status and `proved`), so a forged `proved` beside a real verdict is a finding. `unverifiable-here` is left for one case: the verdict is missing from the store and every field equals `proved`, which is a promotion from another clone with nothing changed since; the scheduled run re-verifies it. `gate` and `attest` owe a re-promotion when `states`, `test` or `nonvacuity` differs from `proved`. A forged `proved` is as undetectable outside the promoting clone as a forged `verdict_sha256`.

**Exit codes:** `0` everything as expected · `1` findings (a `built` or `gated` claim failing, a `diverged`/`unbuilt` claim passing, a structural violation) · `2` could not run — an adapter reported `indeterminate` (or exited non-zero), never reported as pass · `3` usage. Precedence `1 > 2 > 0`. Output is one verdict JSON on stdout.

### D. Host adapter contracts

doc-superpowers stays language- and platform-agnostic; a host supplies small executables named in `config.json`.

**Runner adapter** (one per test framework):

| Call | Returns |
|---|---|
| `<adapter> list [<file>…]` | JSON lines `{"id", "node", "file", "in_gate": bool, "subject_imports_ok": bool, "when": {…}\|null}` for every test in the given files (all test files when none given) that binds itself to a claim id (pytest marker, jest helper, …). **Must be static and cheap** — a syntax scan of the files, never a test collection — because pre-commit calls it with the staged and claim-bound files under a blocking time budget. This is the binding V3 checks: a test self-declares its claim, and the adapter reports it. |
| `<adapter> run --root <dir> <node>…` | JSON lines `{"node", "outcome": "pass"\|"assert-fail"\|"error"\|"not-found"\|"indeterminate", "reason"}`. `assert-fail` is distinguished from `error` so an import or typo error is never an expected red. `indeterminate` (with a reason such as `env-missing` or `owed-on-host` — a runner that cannot execute on this machine) maps to exit 2, never to a finding; a non-zero exit of the adapter itself makes every requested node indeterminate. `--root` lets the adapter run inside a throwaway worktree (how it reuses environments is the host's business). |
| `<adapter> edited-bound-tests --staged \| <range>` | the claim ids whose bound test bodies changed (V9) |

**Log adapter** (optional, for `log` claims): `<adapter> run <claim-id>` → `{"outcome": "pass"\|"fail"\|"indeterminate", "evidence"}`, read-only, called only by scheduled runs.

**Config adapter** (only for the configuration extension, §B.1):

| Call | Returns |
|---|---|
| `<adapter> surfaces` | the files that carry production configuration |
| `<adapter> recorded [--rev <rev> \| --staged] [--override KEY=VALUE]` | JSON `{key: {"recorded": …, "default": …}}` — the recorded production value and the code default, read from the host's own records at that revision (or the index for `--staged`), never a live read. V10 compares the merge-base with the staged state. |
| `<adapter> readers <path>…` | the keys read by code in those paths |

Without a config adapter the extension is off (§B.1). The runner adapter's `list` field `when` is then always `null`.

**Expected-red tests.** A runner adapter's test-side helper (host code) must make `diverged` claims expected-to-fail on assertion failure only (e.g. pytest `xfail(strict=True, raises=AssertionError)`) and `unbuilt` claims expected-to-fail on any failure, so the host's ordinary suite stays green while a claim is known-diverged and turns red when it is unexpectedly fixed or breaks with an error. `references/spec-claims.md` ships reference helpers for pytest and jest as examples.

### E. The lifecycle — recorded gates at every interception point

The five interception points stay; three become **gates with recorded verdicts** when claims are enabled.

| Point | Today | With claims |
|---|---|---|
| Post-brainstorm — `spec-generate` | writes specs | also writes claim stubs (`unbuilt`, tracker = the design doc) for each requirement / decision it generates |
| During plan — `spec-inject --phase=plan` | appends spec maintenance tasks per chunk | also inserts a **Claims gate (chunk N)** task in each chunk **before** its spec-update task (so the Implementation Notes it writes cite the gate's verdicts) and a **Final claims gate** task before the finalize tasks; each implementation task carries `**Claims:** <ids>` or `**Claims:** none — <reason>`. Because the gate is a plan task, it runs on every execute path, including chains that never re-enter a wrapper's execute step (F4). |
| After each chunk — the **chunk gate** | `spec-inject --phase=execute`: stale-gated agent judgement | `claims gate`: run the chunk's claims and `--planes-of` the chunk's range; V8, V8n and V9 over the chunk's hunks, mandatory here. **Every red claim is reconciled before the next chunk starts** — fix the code, or rule `DOC-STALE` and amend (dated `AMENDED` block + `states` + ruling), or defer as `diverged` with a tracker. A still-`unbuilt` claim the chunk was meant to build is reconciled the same way. The record `chunk-<n>.json` carries the gated commits' **patch-ids** and tree, each verdict, each reconciliation and its ruling. The task text states that the **orchestrating agent** executes the gate (reconciliation may need a judge it dispatches), not a delegated implementer. Implementation Notes then cite these verdicts (V8n). |
| Pre-finish — the **final gate** | `spec-verify --mode=post-execute`: bookkeeping | `claims attest --final`: (1) every chunk has a record, matched to `merge-base..HEAD` **by patch-id** so a rebase does not orphan it (unmatched → re-verified by step 2 and marked `rebased: re-verified`); (2) every claim the plan names re-run at HEAD — `built` (or `gated`) passing, or `diverged` with ruling and tracker; (3) cross-check: every ruling, promotion and status change in the sidecars over the range appears in a record, and every record's reconciliation exists at HEAD (a ruling with no gate record is a silent reconciliation); (4) `claims rulings --range` emits the **amendment batch** — every `DOC-STALE`/`RETIRE` with the approved text, the new text and the reason — for the human who reviews docs; (5) `render --check`. `spec-verify --mode=post-execute` reports this verdict. `--deep` re-runs each chunk at its recorded tree. Records are self-reported; attest proves their consistency with the tree, not that an agent ran them. |
| During review — `spec-verify --mode=review` | freshness + coverage | adds the claims verdict for claims whose subject or runner the change touched, and the V9 items |

**Spec Status Model — new rule R5.** A target spec advances to `Implemented` only when every claim the plan names for it is `built` with a passing verdict at the final gate (with the configuration extension, `gated` also qualifies — §B.1). `:amends` specs remain exempt from Status writes but **not** from claim checks (F3).

### F. The direction protocol

When a doc and the code disagree — a failing claim, an edit to a claimed quote or `states`, a configuration conflict (§B.1), or a mismatch found by any audit or review — **neither side is edited until the direction is ruled and recorded**:

| Direction | Meaning | What changes |
|---|---|---|
| `CODE-DIVERGES` | the doc is the intent | the code is fixed, or the claim goes `diverged` with a tracker |
| `DOC-STALE` | the approved text was wrong or incomplete | the doc's normative text (dated `AMENDED` block) and the claim's `states`; the ruling records why — an implementation finding, a later decision. "The code is what runs" is evidence of behaviour, never of intent. |
| `RETIRE` | the decision is withdrawn | the claim is `retired`; the sentence is struck or removed |

**Deviation is expected; an unreconciled deviation is the failure.** No plan or spec is perfect. Inside a plan, the chunk gate is where deviations are reconciled, with the full context and no presumption. **Outside a plan** (an audit, a review, a later session), nobody recorded a reason to depart from approved text, so the default presumption is `CODE-DIVERGES`.

**Policy** (`config.json` `policy`, host-set; doc-superpowers ships the defaults in brackets):
- `in_plan_ruling_requires_gate_record` [true] — a `DOC-STALE`/`RETIRE` ruled at a chunk gate is valid only when its `record` is a gate record of a plan whose governing specs list that doc as target or amendment (V6), so the in-plan latitude cannot be obtained by labelling.
- `outside_plan_presumption` [`CODE-DIVERGES`].
- `doc_stale_outside_plan_requires` [any principal] — a host may require a named principal (e.g. the doc owner) for `DOC-STALE`/`RETIRE` on approved text outside a plan.

The `by` field names a principal; doc-superpowers records it and checks the `record` path, and makes no claim to verify who ruled.

### G. Hooks and CI templates

- **Git tier:** a pre-commit template (`claims validate --staged`; V1–V6, V11, V12 — and V10 when §B.1 is on — blocking; V7–V9 advisory) and a pre-push template (`claims run --planes-of` and `claims attest` for an in-progress plan; advisory). Hosts with their own hook managers call the same commands.
- **CI tier:** `doc-spec-verify.yml` runs `claims validate --all`, `claims run --all` and `claims attest --final` on PRs carrying a completed plan; `doc-pr-release`'s managed-section editor can place the amendment batch at the top of the PR body.
- **Scheduled:** `doc-freshness-schedule.yml` adds `claims run --all`, promotion re-verification (mutants and `observed_red`), ambient V5/V11, and a rotating sample of `judge` claims for review.

### H. Documentation changes

- `references/spec-lifecycle-protocol.md`: the interception points are gates with recorded verdicts when claims are enabled; the per-chunk point is a plan task; the direction protocol replaces "surface to user, let them decide".
- `references/spec-lifecycle-actions.md`: execute and post-execute use claim verdicts; the "aligned" branch never calls `update-index` while a claim of that spec fails; R5.
- `references/integration-patterns.md` + new `references/spec-claims.md`: schema, checks, adapters, reference test helpers.
- `references/doc-spec.md`: the spec template gains the `## Claim status` section and the descriptive-section marker (`<!-- spec-claims:descriptive -->`).
- Wording everywhere: `update-index` / `last_verified` record a baseline reset, never verification; a skill reports a verification verdict only from claims.

## Non-goals

- Auditing or backfilling existing docs into claims (each host's own work; V8 and the scheduled sampler surface coverage gaps).
- Shipping production runner or config adapters for every framework (reference helpers only).
- Requiring any configuration or feature-flag system: the configuration extension (§B.1) is off unless a host declares a config adapter.
- Verifying that a named principal actually ruled.
- Changing behaviour for projects without `docs/spec-claims/`.

## Verification

- **New suite `scripts/test-spec-claims.sh`** on the existing harness, in CI under bash 5.x and `/bin/bash` 3.2: a passing/failing fixture per check; normalisation (reflow passes, struck text and the status block ignored, an `AMENDED` re-quote fires); the merge-base ratchet (a branch behind a ruled trunk change does not fail); token-changing re-anchor, self-referential `record`, hand-edited `built` all refused; `run` exit codes and precedence with stub adapters; `assert-fail` vs `error`; `promote` with a mutant that stays green refused; gate/attest on a fixture plan, including a rebased branch matched by patch-id and a sidecar ruling with no gate record.
- **Replay fixtures** for the four drift shapes and the planted drifts above, each caught by its named check at its named point.
- `test-spec-status-model.sh` pins R5; `test-doc-tools.sh`'s bash-4 guard covers the new code; `check-version` for the bump.
- The sixth suite is wired in the same release: `CLAUDE.md`'s suite list and counts, the one-line run loop, and `.github/workflows/tests.yml`'s matrix.
- Implementation notes for bash 3.2: quote normalisation with `jq -Rs` and `gsub` (including a lazy multi-line `~~…~~`); V8's structural keys with awk heading-tracking over `git diff -U0`; patch-id joins with `git patch-id --stable` plus `sort`/`join` or `jq` (no associative arrays); mutant substitution with a literal-safe replace (`index`-based in `jq`/awk), never a glob-interpreting `${s/…}`.
- Dogfood: this repo's next plan carries Claims lines and gate tasks.

## Version

3.2.0 (minor). Everything is inert without `docs/spec-claims/`. With it, `spec-inject`/`spec-verify` change behaviour as described in §E; release notes call this out under "Changed (claims-enabled projects only)".
