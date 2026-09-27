---
date: 2026-09-27
status: Draft
type: plan
run-id: 05ea982
governing_specs:
  - docs/superpowers/specs/2026-03-12-bundled-doc-tooling-design.md
  - docs/superpowers/specs/2026-03-13-workflow-hooks-harness-design.md
  - docs/superpowers/specs/2026-03-14-spec-lifecycle-protocol-design.md
  - docs/superpowers/specs/2026-03-25-release-notes-action-design.md
  - docs/superpowers/specs/2026-07-24-spec-status-transition-model-design.md
related-files:
  - docs/plans/2026-09-27-full-repo-05ea982-audit-findings.md
  - docs/plans/2026-09-27-full-repo-05ea982-jumping-off-point.md
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

# doc-superpowers full-repo sweep — Fix Plan (clusters I-1 … I-14)

> **For agentic workers:** use `superpowers:subagent-driven-development` to implement this plan
> task-by-task (one fresh implementer per Task, review between Tasks). Steps use checkbox syntax.
> Evidence for every finding cited here is in the findings index
> ([`2026-09-27-full-repo-05ea982-audit-findings.md`](2026-09-27-full-repo-05ea982-audit-findings.md));
> each Task names the cluster issue it closes.

**Goal:** close the 14 verified clusters from the `05ea982` sweep by fixing the five wrong
foundational assumptions (commit-SHA identity, write == verify, single uninterrupted writer,
assumed harness contracts, prose-as-guard) rather than patching symptoms one by one.

**Architecture.** Sequenced cheapest-foundation-first: (T1) make the test harness trustworthy so
every later red/green is real; (T2) introduce **one index persistence primitive** — `_index_load`
(shape-validated snapshot), `_index_apply` (one jq program over a batch, lock, beside-target
tmp + `chmod` + `mv`), correct traps — that every writer uses; (T3) put the CLI on one argument
parser and one stdin-line parser; (T4) replace commit-SHA identity with **content identity**
(`code_oids`, checked in one `git cat-file --batch-check` pass), which fixes squash/rebase/shallow
false-stale, pre-commit blindness *and* the O(N·H) scaling in one change; (T5) make the stored state
honest (only deprecation is stored; only `update-index` attests); then fix the consumers
(merge driver, hooks, installer, CI, fragment pipeline, prompts, packaging, docs) against the new
primitives. Nothing in this plan adds a runtime dependency; two are removed (GNU sed, `rg`).

**Tech stack:** bash (3.2-compatible), jq, git, POSIX awk/sed/coreutils (GNU + BSD); GitHub Actions
YAML; Markdown prompt layer. Tests: the five shell suites via `scripts/test-helpers.sh`.

## Global Constraints

- **Zero new dependencies.** Shipped scripts use bash + git + jq + POSIX tools only. Removing GNU sed
  and `rg` is in scope; adding anything is not.
- **bash 3.2.57 + BSD userland are real targets.** No bash-4-only constructs; guard empty-array
  expansions under `set -u`; no GNU-only flags (`sed -i`, `sort -V`, `readlink -f`, …). The static
  guard in `test-doc-tools.sh` is extended in T1 and must stay green.
- **Behaviour-preserving unless the Task fixes a verified bug** — then the failing test written in
  Step 1 *is* the new behaviour. Sanctioned behaviour changes are listed per Task under
  "Behaviour change".
- **Tool ↔ prompt lockstep.** Any change to a verb's semantics ships with the matching
  `SKILL.md` / `references/*.md` edit in the same Task (the sweep found the two layers drifting in
  both directions).
- **Tests never touch a real repo.** Every fixture runs in `mktemp -d` with a sanitized git
  environment (T1 makes this the harness default). Two verifiers in the sweep accidentally wrote into
  the real repo by running tools with the wrong cwd — do not repeat it.
- **Versioning:** RELEASE-NOTES.md is canonical; use `scripts/doc-tools.sh bump-version X.Y.Z` then
  `check-version`. Recommendation: ship T2–T5 + T8's default change + T9's template removal as
  **v3.0.0** (index schema and installer defaults change; the 2026-05-04 issue already proposed a
  major for this class), everything else as minors/patches along the way.
- **Close-out per Task:** set the owning cluster issue's frontmatter `status: Resolved` (the repo's
  issue convention), run `doc-tools.sh update-index` for every doc the Task edited, and commit with a
  conventional-commit subject naming the cluster (`fix(doc-tools): … (sweep 05ea982 I-2)`).

## Verification commands (all Tasks)

```bash
# the five gating suites (the macOS/bash-3.2 leg runs in CI via tests.yml)
for s in doc-tools hooks spec-status-model doc-pr-release merge-driver; do
  bash "scripts/test-$s.sh" || { echo "FAIL: test-$s.sh"; exit 1; }
done
bash scripts/doc-tools.sh check-version
# optional local bash-3.2 check if available:  /bin/bash scripts/test-doc-tools.sh
```

## File-by-file map

| File | Tasks |
|---|---|
| `scripts/test-helpers.sh` | T1 |
| `scripts/test-doc-tools.sh` | T1, T2, T3, T4, T5, T10, T11 |
| `scripts/test-merge-driver.sh` | T1, T6 |
| `scripts/test-hooks.sh` | T1, T7, T8, T9 |
| `scripts/test-doc-pr-release.sh` | T1, T10 |
| `scripts/test-spec-status-model.sh` | T12 |
| `scripts/doc-tools.sh` | T2, T3, T4, T5, T10, T11 |
| `scripts/merge-doc-index.sh` | T6 |
| `scripts/hooks/git/*`, `scripts/hooks/claude/*` | T7 |
| `scripts/hooks/install.sh`, `scripts/hooks/state.sh` | T8 (+ T6 driver registration, T9 defaults) |
| `scripts/hooks/ci/*.yml`, `scripts/hooks/ci/doc-pr-release/*` | T9, T10 |
| `skills/doc-superpowers/SKILL.md`, `references/*.md`, `evals/evals.json` | T12 (+ lockstep edits in T3–T5, T7, T10, T11) |
| `.opencode/*`, `.cursor-plugin/*`, `.codex/INSTALL.md`, `GEMINI.md`, `AGENTS.md`, `claude-code.json`, `package.json` | T13 |
| `.github/**`, `.claude/**`, `.gitignore`, `README.md`, `CLAUDE.md`, `docs/**`, `docs/.doc-index.json` | T14 |

---

# Task 1: I-13 — make the test harness trustworthy first

> **Closes:** [I-13](../issues/2026-09-27-sweep-05ea982-I13-test-suite-fidelity.md) (harness half; the
> coverage half is carried by each later Task's Step 1).
> **Why first:** today an assertion can pass with the forbidden string present, the suite can write
> into a contributor's global hooks dir, and a tripped perf guard aborts without counting a failure.

**Files:** `scripts/test-helpers.sh`, `scripts/test-doc-tools.sh`, `scripts/test-merge-driver.sh`,
`scripts/test-hooks.sh`, `scripts/test-doc-pr-release.sh`, `.github/workflows/tests.yml`.

- [ ] **Step 1 — Red:** add a harness self-test that runs `assert_not_contains` on a ≥64 KB haystack
  that *does* contain the needle 500× under `set -o pipefail`; today it false-PASSes ~0.1–0.2% of
  the time (loop until it does, bounded). Add a test that sets `GIT_CONFIG_GLOBAL` to a file with
  `core.hooksPath=$scratch/global` and asserts the suite leaves `$scratch/global` empty.
- [ ] **Step 2 — Edit:**
  - `assert_contains` / `assert_not_contains`: `grep -qF -- "$needle" <<<"$haystack"` (no pipe).
  - `setup()`: `unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY`; export
    `HOME="$TEST_DIR/home" XDG_CONFIG_HOME="$TEST_DIR/xdg" GIT_CONFIG_NOSYSTEM=1
    GIT_CONFIG_GLOBAL=/dev/null`; set author/committer via env; `git init -q -b main` (fallback for
    old git: `git init -q && git symbolic-ref HEAD refs/heads/main`).
  - Replace every fixed `/tmp/...` path and `mktemp /tmp/x.XXXXXX.json` with paths under `$TEST_DIR`.
  - Replace every `[[ … ]]; assert_eq "0" "$?"` with an `if` form so failures are counted.
  - Perf guard: record a timeout as `FAIL` (do not `return 1`), and add a *process-count* guard
    (counting `jq` shim on `PATH`, assert ≤ N + c spawns) — wall-clock alone missed a 4-jq-per-entry
    regression.
  - Extend the bash-4 static guard with the 12 missed forms (`local -n`, `declare -[gAlu]`,
    `[[ -v`, `|&`, `${x:0:-1}`, `${x@Q}`, `exec {fd}>`, `printf '%(`, `EPOCHSECONDS`, `globstar`,
    `;;&`/`;&`, `read -N`) and treat `grep` rc ≥ 2 as FAIL.
  - Make `test-doc-pr-release.sh` source `test-helpers.sh` (shared asserts + `bash_bin_shim`), and
    make a missing YAML parser a loud `SKIP` (CI still enforces a parser in `tests.yml`).
  - INT trap: `trap 'cleanup; exit 130' INT`.
- [ ] **Step 3 — Verify:** all five suites green; run `test-spec-status-model.sh` 60× and expect 0
  flaky runs (baseline was 1–2/60).
- [ ] **Step 4 — Commit** `test(harness): pipefail-safe asserts, isolated git env, counted failures (sweep 05ea982 I-13)`.

# Task 2: I-2 — one index persistence primitive (load, apply, lock, write, signals)

> **Closes:** [I-2](../issues/2026-09-27-sweep-05ea982-I02-index-persistence-layer.md); supersedes the
> fix proposed in `docs/issues/2026-07-29-index-write-is-not-atomic.md` (mark it Resolved here).

**Root cause:** A3 — "one writer, never interrupted, file always valid". Traps resume after
INT/TERM (`doc-tools.sh:311,503`), five writers truncate with `>` (`:792,918,980,1089,1167`), no lock
while `SKILL.md:374,393` dispatches parallel agents, and jq on an empty file yields an empty
"valid" index (`:485-488,627-656,694-701`).

**Interfaces (new, internal to `doc-tools.sh`):**
```bash
_index_load   # → prints path of a validated snapshot; dies unless type=="object" and .docs is an object
_index_lock   # portable mkdir spin-lock "docs/.doc-index.json.lock" (flock is not on macOS); released by EXIT trap
_index_apply <jq-program> [jq args…]   # lock → snapshot → one jq pass → tmp beside target → chmod to prior mode (644 default) → mv
_traps        # trap 'cleanup' EXIT; trap 'exit 130' INT; trap 'exit 143' TERM   (never RETURN; never resume)
```

- [ ] **Step 1 — Red:** tests for (a) `kill -TERM` mid-`build-index` → previous index byte-identical,
  rc ≠ 0; (b) `{ sleep 3; } | timeout 1 build-index` → index unchanged; (c) 10 parallel
  `update-index` on 10 stale docs → 0 stale afterwards; (d) a writer racing a reader for 10 s → index
  always parses; (e) 0-byte index → every verb exits non-zero with a clear message; (f) resulting
  index mode is 0644 under umask 022.
- [ ] **Step 2 — Edit:** implement the four helpers; convert `build-index`, `update-index`,
  `add-entry`, `remove-entry`, `move-entry`, `deprecate-entry`, and the two `check-freshness` reads
  (one snapshot for both passes). Each writer becomes: parse args → build a per-key patch list
  (JSONL) → one `_index_apply` → report the keys *actually changed*. A no-op run writes nothing (no
  `generated_at` bump). This also turns every writer into an O(N + k) batch operation.
- [ ] **Step 3 — Verify** (commands above) and re-run the scaling probe: `update-index` of 50 docs on
  a 4,000-entry index should drop from ≈10 s to < 1 s.
- [ ] **Step 4 — Docs:** update `docs/codebase-guide.md` (index write path) and mark
  `docs/issues/2026-07-29-index-write-is-not-atomic.md` Resolved with a pointer to this Task.
- [ ] **Step 5 — Commit** `fix(doc-tools): single locked atomic index writer; signals terminate (sweep 05ea982 I-2)`.

# Task 3: I-4 — CLI and input robustness

> **Closes:** [I-4](../issues/2026-09-27-sweep-05ea982-I04-doc-tools-input-cli-robustness.md) and
> `docs/issues/2026-07-29-usage-omits-implementation-verbs.md`.

**Root cause:** callers (mostly LLM agents) are assumed to pass well-formed input in documented
positional order; every git failure is assumed to mean "no history"; `check-freshness` carries a
drifting inline copy of `compute_freshness`.

- [ ] **Step 1 — Red:** tests for: `deprecate-entry <old> --superseded-by <new>` (flag after path)
  deprecates only `<old>`; unknown `--flags` exit 2; `build-index </dev/null` on an existing index
  refuses (exit ≠ 0, index unchanged); a bare-path / CRLF / `a, b` / `docs/a:b.md` stdin line is
  rejected or normalized; `check-freshness` and `status` agree for entries with null
  `code_commit`, null `content_hash`, empty `doc_type`, refs containing `,,`, and glob characters;
  `--code-refs src/m1` does not match `src/m10/x`; `docs//x.md` normalizes to `docs/x.md`;
  outside a git repo every verb exits non-zero; with `log.showSignature=true` `code_commit` is a bare
  SHA; unborn HEAD gives `build_commit: null`; `--help` exits 0 and lists **every** dispatchable verb.
- [ ] **Step 2 — Edit:**
  - One `_parse_args` loop per verb: `--flag X` and `--flag=X` anywhere, `--help` → usage, other
    `-*` → exit 2; `normalize_doc_path` rejects `-*`.
  - One `_entry_from_line`: `IFS=: read -r path refs type extra <<<"${line%$'\r'}"`; reject when
    `extra` is set; split refs once (`IFS=, read -r -a`), trim, drop empties; the *same* array feeds
    JSON and git; warn when a ref matches no tracked path.
  - `build-index`: exit non-zero on zero parsed entries; refuse to overwrite a non-empty index
    without `--force`.
  - One freshness function used by both `check-freshness` and `status`; field extraction with
    `join("\u001f")` + `IFS=$'\x1f'` (tab is IFS whitespace — the root of the column shift).
  - `--code-refs`: path-segment match (`f == r`, `f` under `r/`, `r` under `f/`; `.` = repo root);
    accept `--code-refs-from <file|->` so hooks/CI pass lists without argv limits; callers use
    `git -c core.quotePath=false diff --name-only --no-renames`.
  - `git rev-parse --git-dir` once, die on failure; test git exit codes instead of `|| true`;
    plumbing `git rev-list -1 HEAD -- …` instead of porcelain `git log`; `git rev-parse --verify -q HEAD`.
  - `hash_file`: hash stdin (`sha256sum < "$1"`), so escaped filenames and leading `-` are safe.
  - Dispatcher and `usage()` generated from one verb table; `update-index` with an unknown key warns,
    applies the rest, exits 1 at the end.
- [ ] **Step 3 — Lockstep:** update `SKILL.md` tooling table and `references/doc-spec.md` for the
  flag grammar, `--force`, and `--code-refs-from`.
- [ ] **Step 4 — Verify; Step 5 — Commit** `fix(doc-tools): one arg parser, one line parser, one freshness path (sweep 05ea982 I-4)`.

# Task 4: I-1 — content identity instead of commit identity

> **Closes:** [I-1](../issues/2026-09-27-sweep-05ea982-I01-freshness-identity-model.md). Largest single
> win: fixes squash/rebase/cherry-pick/revert/shallow false-stale, pre-commit blindness, and the
> O(N·H) scaling together.

**Root cause:** A1 — "the last commit touching the refs identifies the verified code". Measured:
squash → stale while `git rev-parse <stored>:<ref>` equals `HEAD:<ref>`; after squash + branch
delete the stored commit object is absent in fresh clones, so the object IDs **must be stored**.

**Interface (index schema, additive → `schema_version: 3`):**
```json
"code_oids": { "src/": "<tree-oid>", "src/a.ts": "<blob-oid>", "docs/missing": "missing" }
```
- **Writers** (`update-index`, `add-entry`, `build-index`, `move-entry` preserves): capture the OID
  of every ref from the *working tree* at verification time (temp `GIT_INDEX_FILE`,
  `git add -A -- <refs>`, `git write-tree`, then `git rev-parse <tree>:<ref>` for all refs in one
  `git cat-file --batch-check` pass). Keep writing `code_commit` for display/back-compat.
- **Readers** (`check-freshness`, `status`): build one `--batch-check` input of `<tree>:<ref>` lines
  for the whole index; `<tree>` = `HEAD` by default, or `--tree <tree-ish>` (pre-commit passes
  `$(git write-tree)`, i.e. the staged tree). Stale ⇔ any ref's OID differs. Legacy entries without
  `code_oids` fall back to the current `code_commit` logic until re-verified.
- `commits_behind` and `code_refs_changed` computed **only for stale docs**, from the per-ref OID
  mismatch (`code_refs_changed` becomes exact); `commits_behind` from `git rev-list --count
  <verified_head>..HEAD -- <refs>` when that commit is reachable, else `null` (never a masked `0`).
- Writers refuse to record `code_commit` in a shallow repository
  (`git rev-parse --is-shallow-repository`) — OIDs remain valid there.

- [ ] **Step 1 — Red:** fixtures (T1 harness) for squash-merge, GitHub-style rebase-merge,
  cherry-pick, revert-to-verified-bytes, `--depth 1` clone, "code + doc + update-index in one
  commit", and a staged invalidating change seen via `--tree $(git write-tree)`; each asserts the
  correct verdict. Add a scale test: N=2,000 docs, H≥500 commits, `check-freshness` < 5 s (and a
  process-count bound from T1).
- [ ] **Step 2 — Edit** per the interface above. Prototype references from the sweep: one-walk and
  OID batch-check scripts (0.79 s for 4,000 docs at H=3k; 0.46 s at H=30k; identical stale set).
- [ ] **Step 3 — Lockstep:** `references/doc-spec.md` schema table (`schema_version` 3, `code_oids`,
  `implementation`), `docs/conventions.md` freshness model, `SKILL.md` audit wording ("stale =
  code content changed since verification"). Remove the `date | commit` from the in-doc marker
  (`SKILL.md:290`, `doc-spec.md:33`) — the index is the single freshness record.
- [ ] **Step 4 — Verify** + record the before/after timing in the Task's commit message.
- [ ] **Step 5 — Commit** `feat(doc-tools)!: content-identity freshness (code_oids), staged-tree checks (sweep 05ea982 I-1)`.

# Task 5: I-3 — honest stored state (what is stored, who may attest)

> **Closes:** [I-3](../issues/2026-09-27-sweep-05ea982-I03-index-semantics.md), **GH #18**, and the
> issue recorded by **PR #16** (merge that PR first; see the jumping-off point).

**Root cause:** A2 — "writing an entry == verifying the doc"; "status is a stored lifecycle";
"every indexed doc describes current code".

- [ ] **Step 1 — Red:** `update-index` on a deprecated entry keeps it deprecated;
  `build-index --force` preserves deprecations; `add-entry` does not claim `last_verified` for a doc
  nobody verified (baseline = the doc's own last commit tree, per X-DATAFLOW); `deprecate-entry
  --superseded-by X` also sets `X.replaces`; `set-code-refs <doc> --refs a,b` edits in place
  (key position, all other fields preserved, OIDs re-derived); stdin batch form of `move-entry`
  (`<old>\t<new>` per line) validates every pair before writing anything and preserves the same
  metadata as the single form; a record doc (`doc_type` plan/issue/audit/design-spec, or any entry
  under `docs/archive/`) is never reported stale.
- [ ] **Step 2 — Edit:**
  - Stored `status` becomes `deprecated` or absent; `current`/`stale` are always computed (readers
    treat a legacy stored `current` as absent).
  - Only `update-index` writes `last_verified`; `deprecate-entry` stops bumping it.
  - `set-code-refs` (GH #18) and batch `move-entry` (PR #16 Option A) implemented on
    `_index_apply` from T2; the `update-index` "remove-entry + add-entry would drop …" warning names
    `set-code-refs`.
  - **Archive model decision (record it in `docs/conventions.md`):** archival = `git mv` to
    `docs/archive/<type>/` + `move-entry` + `deprecate-entry`; no new `archived_at` field
    (PR #16 Option B is not needed once batch `move-entry` exists).
- [ ] **Step 3 — Lockstep:** `docs/conventions.md` status table, `references/doc-spec.md`
  transitions, `SKILL.md` tooling table (new verb + batch form).
- [ ] **Step 4 — Verify; Step 5 — Commit** `feat(doc-tools): set-code-refs, batch move-entry, derived status (sweep 05ea982 I-3; closes #18)`.

# Task 6: I-5 — a real three-way merge driver

> **Closes:** [I-5](../issues/2026-09-27-sweep-05ea982-I05-merge-driver-not-three-way.md) (**P0**) and
> `docs/issues/2026-07-29-merge-driver-reads-version-not-schema-version.md`.

**Root cause:** "the entry with the newest `last_verified` carries every change from both sides; a
side missing a key meant to delete it" — `$base_docs` is only used for `has()`.

- [ ] **Step 1 — Red** (fixtures built with the real doc-tools verbs, merged with real `git merge`,
  `git rebase` and `git revert` in both directions): deprecate vs update-index; move-entry repoint vs
  add-entry; hand edit vs untouched; delete vs modify; delete on ours; tie on `last_verified`;
  one-sided change with an older `last_verified`; degenerate sides (0-byte, `null`, `{}`, two
  documents) → exit ≠ 0 with conflict markers in `%A`; `schema_version` survives; key order of ours
  preserved.
- [ ] **Step 2 — Edit:** per key with `b/o/t` = base/ours/theirs (null if absent): `o==t → o`;
  `o==b → t`; `t==b → o`; otherwise field-wise (the side that changed a field wins; both changed →
  newer `last_verified`; `deprecated` wins); a deleted key is dropped only when the surviving side
  equals base, else exit 1. Validate `%A`/`%B` with `jq -e -s 'length==1 and (.[0].docs|type=="object")'`.
  Top level starts from ours (keeps `schema_version`, `build_commit`); keep ours' key order, append
  theirs-only keys. On any failure write markers with `git merge-file -L ours -L base -L theirs`
  and exit 1. Registration (`install.sh:187-190`): quote the path and resolve the newest driver at
  runtime the same way the hooks do (or vendor it into the repo).
- [ ] **Step 3 — Docs:** fix the "three-way" claims (`system-overview.md:159`, `codebase-guide.md`)
  and the "rebase … resolves silently" advice in `docs/issues/2026-05-04-…`.
- [ ] **Step 4 — Verify; Step 5 — Commit** `fix(merge-driver): base-aware per-key three-way merge (sweep 05ea982 I-5)`.

# Task 7: I-6 — make the hook tier real

> **Closes:** [I-6](../issues/2026-09-27-sweep-05ea982-I06-claude-hook-tier-and-hook-semantics.md).

**Root cause:** A4 — the Claude hooks were built against an assumed harness (`$TOOL_INPUT`,
visible stdout, Stop == session end) and the git hooks against HEAD-time freshness.

- [ ] **Step 1 — Red** (T1 harness; drive the *installed* artifact through its *registered* command
  string, not the template with injected env): pipe the real PreToolUse JSON
  (`{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}`) with `TOOL_INPUT` unset → the
  gate reports; strict mode exits 2 **with the reason on stderr**; advisory output is a
  `hookSpecificOutput.additionalContext` / `systemMessage` JSON object; the index is byte-identical
  after every hook; `git commit -m x` never gets `#` lines appended; a staged change that makes a
  doc stale is reported by `pre-commit` *in that commit*; `git mv` of a code file puts the doc
  citing the old path in scope; a corrupted index prints one stderr line instead of silently
  passing.
- [ ] **Step 2 — Edit:**
  - Claude hooks read stdin: `command=$(jq -r '.tool_input.command // empty')`; POSIX regex
    `git([[:space:]]+-[Cc][[:space:]]+[^[:space:]]+)*[[:space:]]+commit([[:space:]]|$)`; test the
    command *before* resolving DOC_TOOLS (saves ≈17 ms on every Bash call).
  - Output via the documented JSON channels; strict reason on stderr.
  - **Remove** the `update-index` calls in `post-commit-sync.sh` and `session-summary.sh`.
  - Stop hook: scope to paths changed in the working tree (`git diff --name-only --no-renames HEAD` +
    untracked) or move to `SessionEnd`; print a one-line note on timeout; macOS fallback uses
    `mktemp` and signals the process group.
  - Git hooks: `pre-commit` uses `check-freshness --tree "$(git write-tree)" --code-refs-from -`
    (T3/T4); `prepare-commit-msg` only acts for editor commits (`$2` empty or `template`) and says
    "already stale"; every `git diff --name-only` gains `--no-renames` and `-c core.quotePath=false`;
    `post-merge` stops reporting whole-index `untracked`; `pre-push` reads the pushed refs from stdin
    and has the DOC_TOOLS guard; drop the undocumented `DOC_INDEX` knob.
  - Distinguish "tooling absent" (silent) from "tooling failing" (one stderr line, still exit 0 unless
    STRICT).
- [ ] **Step 3 — Lockstep:** README hook table, `docs/workflows/doc-superpowers.md`,
  `docs/codebase-guide.md` (remove "auto-runs update-index").
- [ ] **Step 4 — Verify; Step 5 — Commit** `fix(hooks): stdin hook input, visible output, staged-tree pre-commit (sweep 05ea982 I-6)`.

# Task 8: I-7 — installer ownership, placement, integration, state

> **Closes:** [I-7](../issues/2026-09-27-sweep-05ea982-I07-installer-ownership-placement-state.md).

**Root cause:** "anything mentioning doc-superpowers is ours; `.git` is a directory and cwd is the
top; the host hook is bash; the skill's parent dir holds only plugin versions; 'installed' is enough
state to reproduce an install".

- [ ] **Step 1 — Red:** user hook group sharing a `"doc-superpowers"` substring survives
  install + uninstall byte-for-byte; a committed symlink at any write target (file, dangling, parent
  dir) makes the installer refuse; `#!/bin/sh` host hook runs the integrated block with its
  arguments and strict exit; linked worktree, submodule and subdirectory installs land where git
  runs them; a global `core.hooksPath` is refused; a sibling `…/zzz/scripts/doc-tools.sh` is never
  executed; a path containing a space works; `--base-branch 'a|b'` is rejected; plain re-install
  reproduces the prior choices (`--ci-strict`, `--workflows=…`, branch, cron) and refreshes an
  integrated hook's local copy; `uninstall --workflows=typo` exits non-zero; install→uninstall
  leaves no residue except the state file.
- [ ] **Step 2 — Edit:**
  - `cd "$(git rev-parse --show-toplevel)"`; `hooks_dir=$(git rev-parse --git-path hooks)`; refuse
    unless `git config --show-scope core.hooksPath` is empty or `local`.
  - `safe_dest()` refusing symlinked targets/parents; every write = tmp beside target + `mv`.
  - Ownership by exact path `.claude/hooks/doc-superpowers/` per hook *entry*; `.gitattributes`
    edits limited to the marker-delimited block.
  - Integration block (POSIX, inserted once after the shebang):
    `if [ -f "$H" ]; then bash "$H" "$@" || exit $?; fi` (exit propagation only for pre-commit).
  - DOC_TOOLS resolution: glob only when `basename(SKILL_DIR)` is a version (`^[0-9]+\.[0-9]+\.[0-9]+$`),
    only version-named siblings, numeric sort (`sort -t. -k1,1n -k2,2n -k3,3n`); otherwise the
    absolute `SKILL_DIR`. Quote the substituted path; escape `\ & |` for sed; validate branch names.
  - State records choices under `.tiers.<tier>` (base_branch, cron, ci_strict, workflow set) and keeps
    `installed_at`; plain re-install refreshes only recorded entries.
  - Claude tier becomes explicitly per-user (append `.claude/settings.local.json` and
    `.claude/hooks/doc-superpowers/` to `$(git rev-parse --git-path info/exclude)`) **or** team-shared
    via `.claude/settings.json` with `"$CLAUDE_PROJECT_DIR"/.claude/hooks/…` and machine-independent
    scripts — pick one and document it; hook commands use `$CLAUDE_PROJECT_DIR`.
  - Default `--ci` = the three shell workflows; AI templates opt-in by name; help/menu list every
    hook and workflow.
- [ ] **Step 3 — Lockstep:** SKILL.md `hooks` section (consent text lists permissions and commit
  behaviour of each workflow; never pass `--force` unless asked), README install section.
- [ ] **Step 4 — Verify; Step 5 — Commit** `fix(installer): git-plumbing placement, symlink-safe writes, exact ownership, recorded choices (sweep 05ea982 I-7)`.

# Task 9: I-8 — CI templates that fail closed and can actually run

> **Closes:** [I-8](../issues/2026-09-27-sweep-05ea982-I08-ci-templates.md) and **GH #5**.

**Root cause:** "a tool failure means 0 stale; the runner's Claude has the local skill and tool
grants; every changed `docs/` path is an indexed doc; two commits of history are enough".

- [ ] **Step 1 — Red** (`test-hooks.sh` / `test-doc-pr-release.sh` on installer output): no
  placeholder survives `install --all`; every AI template passes `github_token`, `plugins`,
  `plugin_marketplaces` and a scoped `claude_args --allowedTools`; every job has `timeout-minutes`;
  freshness templates never pass index-sized data through `$GITHUB_OUTPUT`; the schedule close step
  is gated on a successful check; the PR gate emits `::error::` and exits 1 on tool failure when
  STRICT.
- [ ] **Step 2 — Edit:**
  - **Remove** `doc-index-update.yml` (template, installer list, this repo's copy); state.sh
    uninstalls it on upgrade. Nothing consumes its output, it treats "edited" as "verified", and it
    has failed every run.
  - Freshness PR/schedule: write the result to `$RUNNER_TEMP/freshness.json`, filter to
    `{summary, stale+missing}` with jq, read it in github-script with `fs.readFileSync`; count
    `missing`; `::error::`/`::warning::` on tool failure; never auto-close on failure; upsert the PR
    comment (including "0 stale") matched by a hidden marker + bot author, paginated.
  - AI templates: `github_token: ${{ github.token }}` (**fixes GH #5 without `id-token: write`**, keeps
    the job's `permissions:` as the ceiling and GitHub's no-retrigger rule); install the skill via
    `plugin_marketplaces`/`plugins` pinned to `__VERSION__` (or delete the unread
    `DOC_SUPERPOWERS_VERSION` env); least-privilege `--allowedTools` per template; commit/push in a
    deterministic step that asserts the diff paths; same-repo guard on every PR-triggered AI
    template; one shared write concurrency group per branch; `--max-turns`.
  - `doc-review-pr.yml`: split into a `pull_request` job (fixed prompt) and a comment job with no
    `prompt:` (tag mode) gated on `github.event.issue.pull_request && contains(body,'@claude')`.
  - Replace hard-coded code path filters with a `__CODE_PATHS__` placeholder or drop them and gate
    inside the job with `check-freshness --code-refs-from`.
  - Exact version comments on pins (`# v4.3.1`, `# v7.1.0`, `# v1.0.88`).
- [ ] **Step 3 — Verify; Step 4 — Commit** `fix(ci)!: fail-closed freshness gates, runnable AI templates, drop doc-index-update (sweep 05ea982 I-8; closes #5)`.

# Task 10: I-9 — release-notes fragment pipeline

> **Closes:** [I-9](../issues/2026-09-27-sweep-05ea982-I09-release-fragment-pipeline.md).

- [ ] **Step 1 — Red:** a fragment with a deleted hash line, no markers, pre-heading text, no
  trailing newline, CRLF, trailing-space headings, or shared sub-bullets is either merged losslessly
  or *excluded from `--paths-out`* with a warning; `fragments merge` validates both refs and accepts
  `--paths-out F` and `--paths-out=F`; a fragment merged after a release branch was cut is released
  next time (presence at range end = unreleased) and every present-but-excluded fragment is listed;
  `commit-and-push.sh` refuses when the checkout SHA is no longer an ancestor of the fetched tip
  (force-push) and commits only the fragment path; `extract-context.sh` excludes base-branch commits
  and uses the SHA recorded in the last sentinel as its watermark; `update-pr-body.sh` refuses
  END-before-START and ignores fenced markers.
- [ ] **Step 2 — Edit:** consumer checks line-1/line-2 markers against the filename; unit-level
  (bullet block) dedupe; trims `\r`/trailing blanks; `extract-context` emits
  `existing_fragment_hash_valid`; `commit-and-push` writes the line-2 hash itself, uses
  compare-and-swap (`--force-with-lease=<branch>:<checkout-sha>` semantics without force: fetch,
  verify ancestry, else exit and let the next run regenerate); `doc-release.yml` skips only on the
  exact bot subject; one section vocabulary with a mapping table in the README; document re-sealing
  (`tail -n +3 f | sha256sum`) and an explicit "no notes" state.
- [ ] **Step 3 — Lockstep:** SKILL.md `release` steps: run `fragments merge` *before* dispatching the
  drafting agent; remove step 5's duplicate filter; add the commit step before `git tag`; `mktemp`
  for the consumed list, filtered to `^RELEASE-NOTES\.next/PR-[0-9]+\.md$`.
- [ ] **Step 4 — Verify; Step 5 — Commit** `fix(release): lossless fragment consumer, force-push-safe producer (sweep 05ea982 I-9)`.

# Task 11: I-10 — implementation / version / vendoring verbs

> **Closes:** [I-10](../issues/2026-09-27-sweep-05ea982-I10-implementation-version-vendoring-verbs.md).

- [ ] **Step 1 — Red:** `set-implementation` with `R&D`, `a|b`, `(squash)`, backslashes and a
  newline-carrying `--note` writes the literal text (and executes nothing); it inserts after
  `**Date**:`, `**Date:**` or `**Created**:` and exits non-zero when no anchor exists; `Realized-by:`,
  `Implementation: []`, fenced examples and 4-space bullets are handled by one grammar in all three
  verbs; `check-version` reads the first *line-anchored* `## vX.Y.Z` heading outside code fences
  and rejects a pre-release suffix; `bump-version`/`check-version` fail when 0 manifests are found,
  pre-validate every manifest before writing any, and keep file modes; `tools uninstall` keeps
  user-edited or user-added files; `tools install`/`status` from the vendored copy behave sensibly.
- [ ] **Step 2 — Edit:** one awk block locator shared by `update-index`, `implementation-status` and
  `set-implementation`; `set-implementation` rewritten as one awk pass (literal `index()` matching,
  values via `ENVIRON`) into tmp + `mv`; **delete `gnu_sed()`** and the `brew install gnu-sed` CI
  step; delete `implementation-status --filter` (or reimplement with `grep -E … || true`); one
  `_release_notes_version` helper (also used by `install.sh:22`); cmp-based `tools uninstall`;
  `[ "$src" -ef "$dest" ]` short-circuit.
- [ ] **Step 3 — Lockstep:** ADR/SPEC templates in `references/doc-spec.md` gain the
  `Implementation:` / `Realized-by:` field and one header style; README dependency table drops GNU sed.
- [ ] **Step 4 — Verify; Step 5 — Commit** `fix(doc-tools): awk set-implementation, one block grammar, drop GNU sed and rg (sweep 05ea982 I-10)`.

# Task 12: I-11 — skill prompt ↔ tool contract & agent safety

> **Closes:** [I-11](../issues/2026-09-27-sweep-05ea982-I11-skill-prompt-tool-contract.md). Runs after
> T2–T11 so the prompts describe the fixed tools.

- [ ] **Step 1 — Red:** `test-spec-status-model.sh`-style guards (token/contract assertions, not
  prose freezes) for: the routing table below; no `build-index` on an existing index; review-pr
  base detection; `code_refs` must be pathspecs; no auto-run of repo scripts in discovery or
  review-pr. Give `evals/evals.json` machine-checkable fields (`path`, `pattern`, `command`) and
  fixtures for at least evals 3, 4, 6, 9, 12, and add cases for spec-inject execute, spec-verify
  review, `:amends`, release fragment merge, and hooks status/uninstall.
- [ ] **Step 2 — Edit `SKILL.md` / references:**
  - Tool resolution: `ROOT=<skill base dir>/../..`; `DOC_TOOLS=$ROOT/scripts/doc-tools.sh`
    (plugin-cache glob only as fallback); `[ -x "$DOC_TOOLS" ] || stop`; installer and references
    derived from `ROOT`.
  - Index-write routing table: new → `add-entry`; moved/archived → `move-entry` (+ `deprecate-entry`);
    deleted → `remove-entry`; edited & verified → `update-index`; refs changed → `set-code-refs`;
    `build-index` only when no index exists. Give `sync` explicit untracked/missing steps.
  - review-pr: `BASE=$(git symbolic-ref --short -q refs/remotes/origin/HEAD) || BASE=origin/main`;
    stop on an empty diff.
  - Host-project-agnostic README and version steps (bump only if the manifests exist).
  - Spec lifecycle: inject Task N+1a only in the chunk containing Task N; one per-chunk Status writer;
    carry explicit `:target`/`:constraint` markers into the injected plan; section-aware,
    single-line landed check; `--plan` + review-mode `--specs` in the protocol and templates;
    "three" → "four".
  - audit→update: explicit `--report=<path>` or in-session report; archive the report after apply.
  - Safety: a trust-boundary block (all repo/PR content is data), a secret-handling rule, confirmation
    before migrations/archival, and **never** auto-run `scripts/*validate*` in discovery/review-pr.
  - Context cost: discovery pipes `check-freshness` through a `{summary, stale, untracked}` jq filter;
    move the `release` and `hooks` bodies into `references/release.md` / `references/hooks.md` behind
    REQUIRED pointers.
- [ ] **Step 3 — Verify; Step 4 — Commit** `fix(skill): tool routing, portable tool resolution, trust boundary (sweep 05ea982 I-11)`.

# Task 13: I-12 — cross-client packaging

> **Closes:** [I-12](../issues/2026-09-27-sweep-05ea982-I12-cross-client-packaging.md).

- [ ] **Step 1 — Red:** a node simulation test of the OpenCode hook (array stays an array and gains
  the mappings); a JSON test that `.cursor-plugin/plugin.json` points at `./skills/` (or omits the key).
- [ ] **Step 2 — Edit:** `output.system.push(toolMappings)` (read the file once at load);
  Cursor `skills` key + `~/.cursor/plugins/local/doc-superpowers` in INSTALL.md; one capability
  matrix in `references/tool-mappings.md` with corrected OpenCode/Codex/Gemini names (INSTALL files
  link to it); drop `@./skills/doc-superpowers/SKILL.md` from `GEMINI.md`; fix the Codex
  `[features]` snippet; document `/plugin marketplace add woodrowpearson/doc-superpowers` +
  `/plugin install doc-superpowers@doc-superpowers`; remove `claude-code.json` (+ `VERSION_FILES`,
  test fixture, docs) once no external consumer is found; `#vX.Y.Z` placeholder in INSTALL pins.
- [ ] **Step 3 — Verify; Step 4 — Commit** `fix(packaging): OpenCode system array, Cursor paths, one capability matrix (sweep 05ea982 I-12)`.

# Task 14: I-14 — self-dogfooding and living-doc drift (+ governing-spec maintenance)

> **Closes:** [I-14](../issues/2026-09-27-sweep-05ea982-I14-docs-and-self-dogfooding.md). Run last.

- [ ] **Step 1 — Dogfood:** re-run the installer for this repo after T7–T9 (Claude + CI tiers per the
  T8 decision); commit the vendored `.github/scripts/doc-tools.sh` (or re-render the self-installed
  workflows to call `scripts/doc-tools.sh`) and `.claude/doc-superpowers/installed.json`; untrack
  `.claude/settings.local.json` and add it to `.gitignore`; add a `tests.yml` step that diffs each
  self-installed file against its substituted template and `cmp`s the vendored tool.
- [ ] **Step 2 — Index hygiene:** record docs get empty `code_refs` via `set-code-refs` (T5);
  archived plans deprecated; the two older issues retyped `issue`; `[""]` entries migrated to `[]`.
- [ ] **Step 3 — Living docs:** keep suite counts only in CLAUDE.md (others link); add `:amends` and
  `spec-verify --plan` to CLAUDE.md, the workflows doc, codebase-guide and conventions; fix the status
  table, `__DOC_TOOLS_PARENT__` naming, dependency tables, `.mcp.json` location, directory trees
  (`tests.yml`), README Contributing (run the five suites); re-render the two C4 PNGs; fix lying code
  comments listed under I-14.
- [ ] **Step 4 — Governing specs:** amend only drifted mechanism sentences in the five
  `governing_specs` (no status transitions — these are reference design specs); `update-index` each
  edited spec.
- [ ] **Step 5 — Verify** (all suites + `check-freshness` on this repo: only genuinely living docs
  may be stale) **and Commit** `docs: dogfood the fixed tiers, single-source counts, index hygiene (sweep 05ea982 I-14)`.

---

## Self-review (done at authoring)

- **Coverage:** I-1→T4 · I-2→T2 · I-3→T5 · I-4→T3 · I-5→T6 · I-6→T7 · I-7→T8 · I-8→T9 ·
  I-9→T10 · I-10→T11 · I-11→T12 · I-12→T13 · I-13→T1 (+ Step 1 of every Task) · I-14→T14.
  Every verified P0/P1 in the findings index is named in its cluster's Task.
- **Existing issue records closed here:** index-write-not-atomic (T2), usage-omits-implementation-verbs
  (T3), merge-driver-reads-version (T6), metadata-rewrite-on-every-commit (T4 + T6 remove its real
  causes; T7 removes the hook it wrongly blamed), GH #18 (T5), PR #16's issue (T5), GH #5 (T9).
- **Out of scope (deliberately):** a new `archive-entry` verb / `archived_at` field (not needed once
  batch `move-entry` exists — PR #16 Option B); an `update-index --all`/refresh-all mode (would mark
  unread docs verified); server-side GitHub merge of the index (content identity + no-op writes
  remove most conflicts; a resolver workflow stays a consumer choice).
- **Type/name consistency:** `_index_load`, `_index_apply`, `_index_lock`, `_entry_from_line`,
  `code_oids`, `--tree`, `--code-refs-from`, `set-code-refs` are used identically across Tasks.
- **Honesty:** no measured claim without an artifact; bash 3.2/BSD behaviour is structural until the
  macOS CI leg runs each Task; GitHub-Actions-runtime claims in T9 need one real run per template.

## Execution Handoff

Dependency graph: **T1 → T2 → T3 → T4 → T5** (strictly sequential; each builds on the previous
primitive). After T5, **T6, T7, T8, T10, T11** are independent of each other (different files) and
may run in parallel worktrees; **T9** depends on T8 (installer defaults) and T7 (hook output);
**T12** after T3–T11; **T13** anytime after T12's tool-resolution decision; **T14** last.

1. **Subagent-driven (recommended)** — one fresh implementer per Task via
   `superpowers:subagent-driven-development`, review between Tasks.
2. **Inline** — `superpowers:executing-plans` with a checkpoint after each Task.
