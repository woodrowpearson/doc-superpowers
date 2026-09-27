---
date: 2026-09-27
status: Open
priority: P1
type: bug
component: tests
source: sweep-skill
cluster-key: sweep-skill:full-repo:I-13
run-id: 05ea982
related-files:
  - scripts/test-helpers.sh
  - scripts/test-doc-tools.sh
  - scripts/test-hooks.sh
  - scripts/test-merge-driver.sh
  - scripts/test-doc-pr-release.sh
  - scripts/test-spec-status-model.sh
  - .github/workflows/tests.yml
screenshots: null
axiom-agent: null
branch: null
design-doc: null
report: docs/plans/2026-09-27-full-repo-05ea982-audit-findings.md
---

# I-13 — Test-suite fidelity and reliability

> Cluster **I-13** of sweep run `05ea982`, ranked #12 of 14. Evidence:
> [findings index](../plans/2026-09-27-full-repo-05ea982-audit-findings.md) (S9). Fix: **Task 1** of
> the [fix plan](../plans/2026-09-27-full-repo-05ea982-fix-plan.md) for the harness half. The
> coverage half is Step 1 of every later Task.

## Summary

696 of 696 assertions pass, and several verified P0/P1 defects pass with them. The suites test the
author's *model* of each runtime contract, not the contract itself:
- the Claude hook tests inject `TOOL_INPUT`, so they reject the correct stdin fix;
- the merge-driver fixtures never differ from base;
- templates are tested instead of installed artifacts.

The harness has its own defects:
- a pipefail race can false-PASS an assertion while the forbidden string is present;
- fixtures inherit the contributor's global git config, including a global `core.hooksPath`, and
  write into it;
- a tripped perf guard aborts the suite without counting a FAIL.

## Incorrect assumption

- "Testing the template with injected env == testing the installed artifact via its real invoker."
- "`echo | grep -q` is safe under pipefail."
- "The test machine has no global git config."

## Verified evidence

- [P1] `test-hooks.sh:443-601`: the Claude hook tests inject `TOOL_INPUT` and assert merged stdout.
  Measured:
  - the correct stdin contract makes 4 assertions **fail**;
  - replacing the registered settings command with `cd /nonexistent` still passes 308/308.
- [P1] `test-hooks.sh:810-881`: nothing tests that the Claude tier preserves user hook entries.
  3 destructive mutations survive. Measured.
- [P1] `test-hooks.sh:643-656,705-730,1212-1228`: integrated mode is never run the way git runs it.
  Structural.
- [P1] `test-hooks.sh:12,639,842`: the installed hooks' runtime doc-tools lookup is never executed;
  a glob mutation survives.
- [P1] `test-doc-tools.sh:1449-1578,267-282`: the add-entry skip-existing guard and the update-index
  re-stamp are untested; both mutations survive. Measured.
- [P1] `test-doc-tools.sh:141-152`: no check-freshness test uses an entry with an empty middle field.
  This is why I-4's column shift passes.
- [P1] `test-merge-driver.sh:17-20,139-157`: no tie fixture and no one-sided-edit fixture. This is
  why I-5's P0 passes 19/19.
- [P1] `test-doc-tools.sh:179-263`: no shallow, squash or rebase fixture (I-1).
- [P2] `test-helpers.sh:91,103`: `echo "$h" | grep -qF` under `pipefail`. Measured:
  - SIGPIPE gives a false FAIL in 1–2 of 1,000 runs;
  - it gives a **false PASS with the forbidden string present** in 0–2 of 1,000 runs;
  - 1–2 of 60 whole-suite runs flake.
- [P2] `test-helpers.sh:59-69`: fixtures inherit the caller's git config. With a global
  `core.hooksPath`, the suite **writes into the contributor's real global hooks dir**. Measured.
- [P2] Further gaps:
  - installed helpers are untested;
  - the bash-4 static guard misses 12 planted forms;
  - the ours-deleted merge rule is untested;
  - one-sided assertions (a new production defect found this way: `code_refs_changed` lists
    untouched refs);
  - `//` normalization is untested;
  - four merge-driver tests cannot fail;
  - negative-path tests stay silent anyway;
  - placeholder/YAML checks do not test installer output;
  - the session-summary timeout path is never exercised;
  - the dead refresh call is unchecked;
  - there are fixed `/tmp` paths;
  - the wall-clock perf guard aborts without a FAIL.
- [P3] Smaller defects:
  - `[[ ]]; assert_eq 0 $?` cannot record a FAIL;
  - the INT trap leaves the suite running;
  - `test-doc-pr-release.sh` is not on the shared harness;
  - a missing YAML parser should SKIP loudly;
  - there is no install→uninstall round trip;
  - 6× `sleep 1` and duplicate corpora;
  - version edge cases are missing.

## Proposed fix (fix plan Task 1)

- Pipefail-safe asserts (`grep -qF -- "$n" <<<"$h"`).
- An isolated git environment in `setup()`: `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM=1`,
  a private `HOME`, and `unset GIT_DIR …`.
- No fixed `/tmp` paths.
- Every failure is counted.
- A process-count perf guard.
- The bash-4 static guard is extended with the 12 missed forms.
- `test-doc-pr-release.sh` moves onto the shared harness.
- Later Tasks add the missing contract fixtures, each red first.

## Acceptance criteria

- [ ] A harness self-test proves `assert_not_contains` never false-PASSes on a 64 KB haystack.
- [ ] With `GIT_CONFIG_GLOBAL` pointing at a hooksPath, the suite leaves that dir empty.
- [ ] 60 consecutive runs of `test-spec-status-model.sh` show 0 flakes.
- [ ] The CI Tests workflow actually executes (see I-14: it has not run since 2026-08-31).
