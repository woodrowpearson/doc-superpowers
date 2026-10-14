# Spec Claims 3.2.0 Close-out Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the items the 3.2.0 final review left open before the release ships:
- the promotion fingerprint, which removes V6's dependence on history and catches mutant and subject swaps;
- the small deferred correctness fixes;
- a jq 1.6 CI leg;
- the C4 re-render;
- a dogfood `audit` + `update` with the 3.2.0 skill.

**Base:** branch `design/spec-claims` at `159806f` (v3.2.0 release commit plus the final-review fixes). Execution ledger: `.superpowers/sdd/2026-10-10-spec-claims/progress.md`. Rulings referenced below live there.

**Spec:** `docs/superpowers/specs/2026-10-10-spec-claims-design.md`. Every Global Constraint, Design deviation and Design clarification of `docs/superpowers/plans/2026-10-10-spec-claims.md` still binds.

## Design addendum: the promotion fingerprint

V6, gate and attest currently decide two questions by reading the sidecar at `promotion.at`:
- "re-promote owed": `_claims_proof_delta`;
- "test/subject/tier changed since the proof".

That commit becomes unreachable on trunk under squash or rebase merges, so every promoted claim then reads `unverifiable-here`. The current verdict check also binds only `id`, `states`, `test` and `status`, so a swap of `nonvacuity` alone, or of `subject` alone, is never detected.

**Change.** `claims promote` writes, next to `at` and `verdict_sha256`, a `proved` object:

```json
"promotion": {"at": "<sha>", "verdict_sha256": "<digest>",
              "proved": {"states": "<sha256>", "test": "<sha256>", "subject": "<sha256>",
                         "enforced_by": "<tier>", "nonvacuity": "<sha256>", "when": "<sha256>"}}
```

- Each digest is the sha256 of the field's canonical JSON. Canonical means compact `jq -cS` of the field value, with `null` for an absent field, and no trailing newline. `enforced_by` is stored as its value.
- `proved` describes the record that promote ran green against. The record the claim carries now is compared with it field by field. No history is read.

**Rules.** These replace `_claims_proof_delta` and the history rule:
- A field equal to its `proved` value is unchanged.
- A `states` difference covered by a new `DOC-STALE`/`RETIRE` ruling is the advisory `re-promote owed`. A `nonvacuity` difference that comes with such a `states` difference is the same advisory (ruling (b) of the final-review fix wave). `when` follows the same rule as `nonvacuity`.
- Any other difference is a V6 finding. This covers `test`, `subject`, `enforced_by`, a `nonvacuity` difference without a covering states amendment, and a `states` difference without `DOC-STALE`/`RETIRE`. The message names the field and says "run claims promote <id>".
- This holds whether or not the local verdict store has the verdict. When the store has it, the verdict file's own binding is still checked, so a forged `proved` with a real verdict cannot hide a mismatch.
- `unverifiable-here` remains only for a verdict missing from the store when every field equals `proved`. That is a promotion from another clone with nothing changed since, and the scheduled run re-verifies it.
- `_claims_repromote_owed` (gate and attest) uses the same comparison: owed when `states`, `test` or `nonvacuity` differs from `proved`.
- V1: a `built`/`gated` claim's `promotion` must carry `proved` with the six keys. No 3.2.0 promotion exists outside this branch's tests, so there is no legacy form to accept.

The trust-by-digest limit stays as `references/spec-claims.md` states it: a forged `proved` is as undetectable outside the promoting clone as a forged `verdict_sha256`.

## File Structure

| File | Tasks |
|---|---|
| `scripts/doc-tools.sh` (+ vendored `.github/scripts/doc-tools.sh` via `install --ci`) | 1, 2 |
| `scripts/hooks/ci/doc-superpowers-steps/claims-check.sh` | 2 |
| `scripts/test-spec-claims.sh`, `scripts/test-doc-pr-release.sh`, `scripts/test-doc-tools.sh` | 1, 2, 3 |
| `.github/workflows/tests.yml` | 3 |
| `docs/superpowers/specs/2026-10-10-spec-claims-design.md` (an `AMENDED` note on §B's record and V6) | 1 |
| `references/spec-claims.md` | 1, 2 |
| `docs/architecture/system-overview.md`, `docs/architecture/diagrams/c4-container.png` | 4 |
| docs found stale by the audit | 5 |
| `RELEASE-NOTES.md`, `CLAUDE.md` counts, `docs/.doc-index.json` | 6 |

### Task 1: Promotion fingerprint

- [ ] **Step 1: Write the failing tests.**
  - promote writes `proved` with the six keys and the right digests;
  - V1 rejects a built promotion without `proved`;
  - a test swap is a finding, both with the store and with it removed;
  - a subject swap alone is a finding, both with the store and with it removed;
  - a mutant (`nonvacuity`) swap alone is a finding;
  - a test → lint tier change under DOC-STALE with states unchanged is a finding;
  - a states-only DOC-STALE gives `re-promote owed`, both with the store and with it removed;
  - a states + nonvacuity DOC-STALE gives `re-promote owed`;
  - a promotion whose `at` is unreachable, with nothing changed and the store removed, gives `unverifiable-here`;
  - the squash case: the promoted branch is squash-merged onto a new main, and validate and attest in a fresh clone still decide owed/clear by `proved`;
  - gate and attest owed or clear by `proved`.
- [ ] **Step 2:** Run the suite. Expected: the new tests fail.
- [ ] **Step 3: Implement.**
  - promote writes `proved`;
  - one shared jq def computes the field digests from a claim, with sha256 in shell through the existing helper;
  - V6's verdict branch and `_claims_repromote_owed` compare against `proved`;
  - V1 checks the shape;
  - remove `_claims_proof_delta` and the history read if nothing else uses them.
  - Update every fixture that hand-writes a promotion (`hand_promote` and the like) to compute `proved`. Enrich fixtures; never weaken a check.
- [ ] **Step 4:** Update `references/spec-claims.md` (claim record, V6 row, "re-promote owed", "unverifiable-here", the verdict-store list). Add a dated `AMENDED` note to the design's §B record and its V6 row, recording the `proved` field and the rules above.
- [ ] **Step 5:** Run all six suites under both interpreters, and spec-claims once more with the jq-1.6-family binary first on `PATH`. Then run `install --ci` and commit `feat(claims): promotion fingerprint — V6 decides by proved, not history`.

### Task 2: Deferred correctness fixes

- [ ] **V8n citation tokens** (triage 162 residue and 164). A token `<P>#<slug>` on a trigger line is a claim citation only when `<P>` is the DOC-ID of a proposed sidecar's doc, or has the ADR/SPEC id shape (`^ADR-[0-9]+$`, `^SPEC-[A-Z]+-[0-9]+$`). `governing_extra` file-stem ids are then citable, and `README#install` or `C#sharp` is never a citation. A citation whose id is unknown is still `cites unknown claim`.
  - Tests: an extra-glob stem id cited gives no finding; a bare `README#install` / `C#sharp` after whitespace gives no `cites unknown claim`; `SPEC-AUTH-001#nope` is still unknown.
- [ ] **claims-check.sh `is_completed`** (the fence rule). Pair code fences the CommonMark way (a closing fence is the same character, at least as long, opened at most 3 spaces in), matching the plan parser. Test: a nested-fence plan whose `**Status**: Completed` sits inside the outer fence is not completed.
- [ ] **Gate's previous-record read** (around doc-tools.sh:10714). Read with `jq -s` and require exactly one object, the same as attest. Test: a record with valid JSON followed by garbage makes the gate exit 2 under jq 1.6.
- [ ] Run all six suites under both interpreters and jq 1.6, run `install --ci`, and commit each fix separately.

### Task 3: jq 1.6 CI leg

- [ ] In `.github/workflows/tests.yml`, add a job (or a matrix leg) on `ubuntu-latest` that:
  1. downloads the official jq 1.6 Linux binary (`https://github.com/jqlang/jq/releases/download/jq-1.6/jq-linux64`);
  2. checks its sha256 against a pinned value, which the implementer computes from the downloaded file and cross-checks against the release's published checksum if one exists;
  3. puts it first on `PATH`, asserts `jq --version` is `jq-1.6`;
  4. runs `test-spec-claims.sh` and `test-doc-tools.sh` under bash 5.x.

  Least privilege: `permissions: contents: read`.
- [ ] Pin the job in `test-doc-tools.sh` or `test-spec-status-model.sh`, following how tests.yml is already pinned: the job exists, it checks the hash, and it runs spec-claims.
- [ ] Commit `ci: jq 1.6 leg for the shipped jq floor`.

### Task 4: C4 re-render

- [ ] Install `@mermaid-js/mermaid-cli@11.6.0` into a scratch prefix outside the repo, with headless Chrome. Use the settings v3.1.0 recorded: `c4.wrap: false`, width 1248, scale 2. Find the recorded config next to the diagram or in the doc's render note, and use it.
- [ ] Update the C4 Mermaid source in `docs/architecture/system-overview.md`:
  - `18 subcommands` with `claims`;
  - 10 step scripts;
  - R1–R5;
  - pre-push calls doc-tools for claims;
  - CI templates and `claims-check.sh`.
  Then re-render `docs/architecture/diagrams/c4-container.png`.
- [ ] Remove the "Known gap" line from `RELEASE-NOTES.md`. Re-render any other diagram whose source changed on this branch (check `git diff 27e698a -- docs/**/*.md` for mermaid blocks with committed PNGs).
- [ ] Commit `docs(architecture): re-render the C4 container diagram for 3.2.0`.

### Task 5: Dogfood audit and update with the 3.2.0 skill

- [ ] Run the branch's own `skills/doc-superpowers/SKILL.md` `audit` action (scope `all`) on this repository, following its procedure: discovery, parallel review agents, report under `docs/plans/`.
- [ ] Then run its `update` action against that report. Every doc edit is read against the code, and `update-index` comes last.
- [ ] Commit the report and the updates. Run `check-freshness --tree`: 0 stale, 0 missing, 0 untracked.

### Task 6: Release notes, counts, final verification

- [ ] Update `RELEASE-NOTES.md` v3.2.0 for Tasks 1–5: the `proved` fingerprint under Features/Changed, the fixes, the jq 1.6 CI leg, the re-rendered diagram, and the audit, plus the new per-suite counts. Update the `CLAUDE.md` Testing paragraph counts.
- [ ] Run `check-version` (still 3.2.0), all six suites under both interpreters (`test-doc-tools.sh` in the foreground), spec-claims under jq 1.6, `install --ci` (no drift), and `check-freshness --tree` (0/0/0).
- [ ] Commit `release: v3.2.0 — close-out (fingerprint, jq 1.6 leg, diagram, audit)`.

### After the plan (the owner approved 2026-10-14: "pr → merge → release → tag")

1. Push and open the PR into `main`. Watch CI.
2. Merge when it is green.
3. Create the GitHub release v3.2.0 from the RELEASE-NOTES entry, with tag `v3.2.0` on the merge commit.
4. Send the merge SHA to the work-ledger SDD coordinator session.
