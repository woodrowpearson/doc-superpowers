# Work ledger: upkeep precision and `ledger declare`: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `ledger upkeep`'s proposals precise enough to act on: blind-judged precision ≥ 0.6 on the abundance replay. Ship the attended confirm-and-link flow, `/doc-superpowers ledger declare`, that writes the confirmed proposals.

**Architecture:** All rule changes sit in the upkeep core, `scripts/ledger/upkeep.sh` (`_lg_up_core` and the `_LG_JQ_UPKEEP` program). `validate --pushed`'s advisory reads the core's `touched`, so it follows the core with no change of its own. `declare` is a skill flow, documented in SKILL.md and `references/ledger.md`, the same way `ledger file` is; it adds no doc-tools verb.

**Tech Stack:** bash 3.2+, jq ≥ 1.6, POSIX awk, git.

**Spec:** `docs/superpowers/specs/2026-10-18-ledger-upkeep-and-filing-design.md`, amended 2026-10-20. D7 covers §4 *Touched contracts* (the **Names** rule), *Proposals* (the attribution of range-added items, and consumes (b)) and *Acceptance*; D8 is §7 `ledger declare`. Every exact string is in the spec.

## Global Constraints

- **bash 3.2 compatible.** Every test passes under `/usr/local/bin/bash` (5.x) and `/bin/bash` (3.2): `BASH_BIN=$B $B scripts/test-ledger.sh 2>&1 | grep -E "FAIL|Results"`.
- **No new dependencies.** jq floor is 1.6, and awk is `LC_ALL=C awk`. The static gates in `test-doc-tools.sh` (no bash-4 constructs, no jq-1.7 forms, shellcheck at warning severity) hold.
- **Output and exit contracts are unchanged.** Exits stay 0/1/2/3, `--format json` emits one object, and the JSON payload shape is unchanged; only the evidence strings change, as the spec words them. The advisory never changes a push's exit code (R16).
- **Same conventions as the module.** Comment density, the function header comments and the `_lg_up_*` / `_LG_JQ_UP_*` naming all follow `upkeep.sh`.
- **Not in this branch:** RELEASE-NOTES.md, version bumps, `scripts/hooks/install.sh`, CI templates.
- **Test counts** live only in CLAUDE.md → *Testing*. Update them in Task 5. The base is 12445 at 2ef8c03.
- **Throwaway and remotes.** Never touch `~/code/abundance-mvp`. The throwaway is `$S/ab2`, with its private bare remote `$S/ab2-remote.git`, where `S=/private/tmp/claude-501/-Volumes-mm-apfs---Data-code-doc-superpowers/0497558f-94f2-4b05-b38e-75759a6b7ff2/scratchpad`. Never push to GitHub.

## Review Focus

1. **Name matching takes regex metacharacters literally.** `field:order.total` must not be named by `orderXtotal`, and `flag:a+b` must not throw a regex error. (Task 1.)
2. **Binary files and huge diffs.** A binary defining file has no changed lines, so it names nothing: no crash and no proposal. A 2,000-file range still uses exactly one `git diff -U0`. (Task 1.)
3. **A deleted defining file.** Its removed lines count, so a deleted file that spelled the contract touches it. (Task 1.)
4. **Item text that names a contract only in its own relation lists** (`changes: [x]`) does not count for consumes (b). (Task 2.)
5. **A range-added item that a claim trailer names** stays a candidate, and so does a range-added item when it is the only item the range involves. (Task 3.)

---

### Task 1: Touched contracts require a changed line that names them

**Files:**
- Modify `scripts/ledger/upkeep.sh`:
  - In `_lg_up_core`, after `$s.fc` / `$s.rc`, filter each (file, contract) pair to those where a changed line of that file names the contract (spec §4 **Names**).
  - Run one `git diff -U0 --no-renames <a> <b> -- <kept files>` per core run.
  - Change the evidence strings in `up_ev_changes` and the (a) evidence to the spec's wording.
- Modify `references/ledger.md`:
  - the *Merge-time upkeep* bullet **Touched contracts**: the name rule, and `Contract-Change:` for a contract the code never spells;
  - the evidence strings in **Proposals** and the payload table;
  - the *Validation* row of `undeclared-contract-change`: "touched (a changed line names it)".
- Modify the `ledger upkeep` help text in `scripts/doc-tools.sh`, only if it states the touched rule.
- Test: `scripts/test-ledger.sh`, in the `# --- upkeep / filing (#36, #39) ---` group.

- [ ] **Step 1: Write the failing tests.**
  - `test_lg_upkeep_touched_needs_a_naming_line`:
    - a comment-only edit to a `defined_in` file that doesn't spell `order.total` proposes nothing;
    - an added line `total = order.total + tax` proposes `changes field:order.total`, with evidence `diff names field:order.total in <f> (defined_in of field:order.total)`;
    - a removed line naming it also counts;
    - `orderXtotal`, `order.totals` and `xorder.total` do not name it.
  - `test_lg_upkeep_names_glob_and_literals`:
    - `flag:--mock-*` is named by a line containing `--mock-users`;
    - a contract id with `+` or `(` (e.g. `flag:a+b`) neither errors nor matches `aab`.
  - `test_lg_upkeep_names_binary_deleted_space`:
    - a binary `defined_in` file changes and nothing is proposed, with rc 0;
    - a deleted file whose removed lines spell the contract proposes it;
    - a path with a space works.
  - `test_lg_upkeep_contract_change_without_naming`: a `Contract-Change: field:order.total — …` trailer still touches it with no naming line.
  - `test_lg_upkeep_read_needs_a_naming_line`: a `read_by` file edit that doesn't spell the contract gives no consumes (a); one that does gives it.
  - `test_lg_validate_pushed_advisory_needs_a_naming_line`: a push that edits a defining file without naming its contract gives no `undeclared-contract-change`.
  - Update the existing upkeep and advisory fixtures whose commits edit a `defined_in` file, so that a changed line names the contract they expect to be proposed. Every expectation stays as it was apart from the evidence wording.
- [ ] **Step 2: Run** `test-ledger.sh` under bash 5. Expected: the new tests FAIL.
- [ ] **Step 3: Implement.** One `git diff -U0` pass, parsed with awk into per-file changed lines. A jq-1.6-safe whole-word match must escape the regex metacharacters in the name and map `*` to `[A-Za-z0-9_.-]*`; alternatively, an awk `index()` scan with explicit boundary checks. The advisory needs no change of its own: confirm that it reads `.touched`.
- [ ] **Step 4: Run** `test-ledger.sh` under both bashes. Expected: all pass.
- [ ] **Step 5: Commit** `fix(ledger): upkeep counts a contract touched only when a changed line names it`.

---

### Task 2: consumes (b) needs the item's own text to name the contract

**Files:**
- Modify `scripts/ledger/upkeep.sh`. For each involved item at rank ≤ 2, read its text: title, `summary` and body, without the frontmatter relation lists. When `<b>` is HEAD, read it from the working tree; otherwise read `<b>:<path>`. Keep a listed-file contract only when that text names it, by the same rule as Task 1, and use the spec's evidence wording.
- Modify `references/ledger.md`: the **Proposals** bullet (b), and *Building on the ledger*'s payload row if it quotes the evidence.
- Test: `scripts/test-ledger.sh`.

- [ ] **Step 1: Write the failing tests.**
  - `test_lg_upkeep_consumes_b_needs_item_text`: item app-1 lists `server/orders/model.js`, which defines `field:order.total` and `field:order.tax`, and its body names `order.total`.
    - A range that edits app-1's file and not `model.js` proposes `consumes field:order.total` only, with evidence `the item names field:order.total and lists server/orders/model.js (defined_in of field:order.total), which the range does not change`.
  - `test_lg_upkeep_consumes_b_ignores_relation_lists`: the name appears only in app-1's `changes: [field:order.tax]` frontmatter, so there is no consumes (b) for `order.tax`.
  - `test_lg_upkeep_consumes_b_reads_b_not_worktree`: with `<b>` ≠ HEAD, the item text is read at `<b>`. A working-tree edit that adds the name does not count.
- [ ] **Step 2: Run** the tests. Expected: they FAIL.
- [ ] **Step 3: Implement.** Read the items' text once per core run, not once per contract.
- [ ] **Step 4: Run** `test-ledger.sh` under both bashes. Expected: all pass.
- [ ] **Step 5: Commit** `fix(ledger): upkeep proposes a listed file's contract to consume only when the item names it`.

---

### Task 3: An item the range adds takes contracts only when no other item is involved

**Files:**
- Modify `scripts/ledger/upkeep.sh`:
  - Mark each involved item whose path the net diff adds (`git diff-tree --diff-filter=A`, the same net diff) and which no claim trailer names (`trailer:claims*` absent from its `found_by`).
  - In `up_attr`, drop such items from the candidates when another involved item exists. This applies to the `changes` attribution and the read attribution alike.
- Modify `references/ledger.md`: the **Proposals** attribution bullet.
- Test: `scripts/test-ledger.sh`.

- [ ] **Step 1: Write the failing tests.**
  - `test_lg_upkeep_added_item_yields_to_others`: one range does all of the following.
    - It adds item app-9, which lists `server/orders/model.js`.
    - It edits a line naming `order.total` in `model.js`.
    - Its message names app-1 (key-in-message), and app-1 lists nothing relevant.
    - Expected: `changes field:order.total` goes to app-1, not app-9.
  - `test_lg_upkeep_added_item_claimed_by_trailer`: the same range with `Ledger-Claims: app-9` gives app-9 the contract.
  - `test_lg_upkeep_added_item_alone`: the same range without the app-1 mention gives app-9 the contract.
- [ ] **Step 2: Run** the tests. Expected: they FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `test-ledger.sh` under both bashes. Expected: all pass.
- [ ] **Step 5: Commit** `fix(ledger): upkeep gives a range's new items contracts only when no other item is involved`.

---

### Task 4: `/doc-superpowers ledger declare`, the confirm-and-link flow

**Files:**
- Modify `skills/doc-superpowers/SKILL.md`:
  - Add a **Declaring** bullet to the `ledger` action, next to **Filing**. It routes `/doc-superpowers ledger declare [--range … | --pr <n>] [--items …]` to `references/ledger.md` → **Declaring after a change**, step by step.
  - Point the *Merge-time upkeep* bullet at the new flow.
  - In `review-pr` step 9, when proposals exist, end the section with `/doc-superpowers ledger declare` (plus `--range <range>` when the range is not the default `"$BASE...HEAD"`).
  - Add the flow to the Usage and Quick Reference lines.
- Modify `references/ledger.md`: add `### Declaring after a change` after **Filing an item**, with spec §7 steps 1–7, and an "offered from" line in *Merge-time upkeep* → *Where else the comparison runs*.
- Modify CLAUDE.md (Commands), README.md (the ledger feature bullet), and `docs/workflows/doc-superpowers.md` (the ledger flows; review-pr step 9).
- Modify `scripts/test-spec-status-model.sh` to pin the flow, next to the filing pins:
  - SKILL.md's `ledger` action names `ledger declare` and `Declaring after a change`;
  - review-pr step 9 names `/doc-superpowers ledger declare`;
  - `references/ledger.md` has `### Declaring after a change` and its steps' anchors: `never "none missing"`, `--top 0`, `built from what was confirmed`, `Never commits unless asked`, `never in a CI run`.

- [ ] **Step 1: Write the failing pins.**
- [ ] **Step 2: Run** `BASH_BIN=/usr/local/bin/bash /usr/local/bin/bash scripts/test-spec-status-model.sh 2>&1 | grep -E "FAIL|Results"`. Expected: the new pins FAIL.
- [ ] **Step 3: Write the docs.** review-pr stays read-only: step 9 only names the flow and never runs it.
- [ ] **Step 4: Run** the seven suites under bash 5. Expected: all pass.
- [ ] **Step 5: Commit** `docs(ledger): /doc-superpowers ledger declare, the confirm-and-link flow`.

---

### Task 5a: Replay the real tool and build the blind judging set (measurement only)

The throwaway `$S/ab2` already exists from P0. Its GitHub main is fetched as `gh/main`, and the PRs are listed in `$S/t8/prs.json`.

- [ ] **Step 1: Replay.** At this branch's HEAD, run `$DT ledger upkeep --range <m>^1..<m> --format json` twice for each of the 23 enabled PRs: once with the default `--top`, once with `--top 0`. `$DT` is the worktree's `scripts/doc-tools.sh`, and each run happens in a detached worktree of `$S/ab2` at `<m>`, as `$S/t8/replay.sh` did. Also run:
  - `--pr` for 3005 and 2999;
  - `validate --pushed` for the two extra pushes (all-zeros at #3016's head and at #3020's head).

  Record proposals, `unattributed_contracts`, advisories and run time.
- [ ] **Step 2: Compare with P0's simulation.** For each PR, diff the real `--top 0` proposals against `$S/precision/sim2.py`'s `C1+B3/A2` output. Explain every difference: A2 (the simulation) versus the spec's "only when no other item is involved" is one expected source.
- [ ] **Step 3: Build the judging set.** Write `$S/precision/judge2-set.jsonl` in the exact format of `$S/precision/judge-set.jsonl`, holding every distinct real `--top 0` proposal.
  - Write `$S/precision/judge2-reuse.json`, mapping each entry whose (pr, item, field, contract) is identical to an entry of the first set to that entry's id.
  - Write `$S/precision/judge2-key.json`, listing which entries are in the default `--top` output.
- [ ] **Step 4: Timing.** Time `validate --pushed` for two of Task 8's ranges, cold and warm, and compare them with Task 8's numbers (`$S/sdd-archive/task-8-report.md`).
- [ ] **Step 5: Report** in `<workspace>/task-5a-report.md`. Commit nothing.

### Task 5b (controller): blind judging

Fresh judges label only the new entries, against the same brief (`$S/precision/judge-brief.md`). Reused entries take judges A and B's labels. Then score per judge, over `--top 0` and over the default `--top`.
- **Acceptance:** both judges ≥ 0.6 on `--top 0`.
- **Below 0.6:** rule on it, with the numbers, before Task 5c.

### Task 5c: Close-out

- [ ] `bash scripts/hooks/install.sh install --ci`, if `scripts/doc-tools.sh` changed. Commit what it writes.
- [ ] Run `check-freshness`, then `update-index` for each stale doc, after reading it.
- [ ] Update CLAUDE.md → *Testing* counts.
- [ ] Add one line under the spec's *Acceptance* **Precision** bullet with the measured real-replay figures.
- [ ] Run the full `bash scripts/check-ci.sh`.
- [ ] Commit `docs(index): counts, index and measured precision after upkeep precision`.
- [ ] Delete `$S/ab2`, `$S/ab2-remote.git`, `$S/precision/wt` and `$S/precision/venv`, keeping the reports. Confirm that `~/code/abundance-mvp`'s ledger refs are unchanged.
