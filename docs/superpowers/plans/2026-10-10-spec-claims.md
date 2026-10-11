# Spec Claims Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship doc-superpowers 3.2.0 with `doc-tools.sh claims <verb>`: executable spec claims, verdicts recorded at the lifecycle gates, and a direction protocol. A project with no `docs/spec-claims/` directory sees no change in behaviour.

**Architecture:** All claim logic lives in `scripts/doc-tools.sh` as a new `claims` verb group. That file is the single-file CLI that the hooks and CI templates already vendor and run. JSON handling and text normalisation go through `jq`, Markdown structure through `awk`, and history through `git` (merge-base, `patch-id --stable`, throwaway worktrees). Host test frameworks plug in through small adapter executables named in `docs/spec-claims/config.json`. The lifecycle integration is reference prose: `spec-inject` injects the gate tasks, and `spec-verify` and `spec-generate` report or write claims. The hook and CI templates call the same verbs. A new sixth suite, `scripts/test-spec-claims.sh`, drives everything through `/bin/sh` stub adapters in throwaway fixture repos.

**Tech Stack:** bash ≥ 3.2, `jq` ≥ 1.6, git, awk, and the shared `scripts/test-helpers.sh` harness.

**Spec:** `docs/superpowers/specs/2026-10-10-spec-claims-design.md` (header: "Approved by the owner 2026-10-10"). Section references below (§A–§H, V1–V12) are to that design.

## Global Constraints

- **Interpreters:** bash 3.2 and `jq` ≥ 1.6 only. Shipped code adds no dependency: no python, no yq, no associative arrays, no `mapfile`, no `${v,,}`. The bash-4 static guard in `scripts/test-doc-tools.sh` scans `doc-tools.sh`, `scripts/hooks/git/*` and `scripts/hooks/ci/doc-superpowers-steps/*.sh`, and must stay green. Under `set -u`, bash 3.2 treats `"${a[@]}"` of an empty array as unbound, so every possibly-empty array is expanded as `${a[@]+"${a[@]}"}` (the doc-tools idiom).
- **jq regex:** Oniguruma. Lazy quantifiers (`*?`) and `[\s\S]` are fine. Never `gsub` a pattern that can match the empty string (jq 1.6 loops on it). Never use `index`/`indices` on strings: jq 1.6 returns byte offsets where slicing uses codepoints. Count and locate with `split($q)` and `length`.
- **Inert:** when `docs/spec-claims/` does not exist (in the working tree), every `claims` verb prints `{"verb":"<verb>","enabled":false,"exit":0}` and exits 0. Hooks, CI templates and the `spec-*` actions then behave byte-identically to 3.1.0.
- **Enabled:** `docs/spec-claims/` exists. `config.json` is optional; missing keys take the defaults in Task 1.
- **Exit codes (claims verbs only):** `0` as expected · `1` findings · `2` could not run (an adapter reported `indeterminate` or exited non-zero, an unresolvable base, an internal failure) · `3` usage. Precedence `1 > 2 > 0`. An internal failure is 2, never 1. This is enforced in doc-tools' EXIT trap (Task 1), not left to each call site. The global doc-tools exit table (usage = 2) is unchanged for every other verb.
- **Order of argument handling (claims verbs):** `_parse_args` runs first, so an unknown option exits 3 even in an inert project. The inert check runs next. Required-argument validation runs after that (`--plan`, `--chunk`, one of `--staged`/`--all`, …), so a missing required argument in an inert project exits 0 with `enabled:false`.
- **Blocking:** in `validate`, a finding blocks when its check is in config `blocking`. In `run`, `promote`, `gate` and `attest`, every finding blocks, whatever its label: those verbs set `_CL_ALL_BLOCKING=1`. Only explicit advisories (e.g. `unverifiable-here`) are non-blocking there.
- **Stdin:** every adapter call and every doc-tools call made from a hook runs with `</dev/null`. An adapter must never consume a hook's stdin (the pre-push ref lines).
- **Output:** exactly one verdict JSON object on stdout. The one exception is `claims rulings --format markdown`, which prints the amendment batch as Markdown for a PR body.
- **Exact names:** subcommand `doc-tools.sh claims <verb>` · sidecars `docs/spec-claims/<DOC-ID>.json` · config `docs/spec-claims/config.json` · gate records `docs/spec-claims/gates/<plan-stem>/chunk-<n>.json` and `final.json` · verdict store `$(git rev-parse --git-common-dir)/spec-claims/promotions/<digest>.json` · status-block markers `<!-- spec-claims:status:begin -->` / `<!-- spec-claims:status:end -->` · descriptive marker `<!-- spec-claims:descriptive -->`.
- **Adapter contracts:** the JSON shapes are copied verbatim from §D (Task 7 and Task 21). They are not to be extended or renamed.
- **Ratchets** compare against `git merge-base HEAD <base>`, never the base tip. `<base>` is `--base`, else config `base`, else `origin/main`.
- **File writes** (sidecars, docs, gate records, verdicts) go through doc-tools' `_tmp_beside` + `_replace_file`: a temp file beside the target, then `mv`.
- **Self-install refresh:** every commit that changes `scripts/doc-tools.sh`, a step script or `scripts/hooks/ci/doc-freshness-schedule.yml` also runs `bash scripts/hooks/install.sh install --ci` and stages `.github/`. Otherwise tests.yml's *Self-installed CI tier matches its templates* step fails.
- **Test runs:** a step that says "run the suite" means `bash scripts/test-spec-claims.sh` (or the suite named). At each chunk end, run all six suites under both interpreters: `for B in /opt/homebrew/bin/bash /bin/bash; do for s in doc-tools hooks spec-status-model doc-pr-release merge-driver spec-claims; do BASH_BIN=$B $B scripts/test-$s.sh || echo "FAIL: $B $s"; done; done`. Expect no `FAIL:` line.
- **Stub adapters in tests** are `#!/bin/sh` fixtures, not code under test, so they are interpreter-neutral. Everything under test runs through `bash_bin_shim`. Stubs write their call log to `$STUB_LOG`, a `harness_mktemp` file outside the work tree, so logging never dirties the fixture.
- **Dirty-tree check** (`gate`, `promote`, `attest --final`): `git status --porcelain --untracked-files=no`, ignoring `docs/spec-claims/gates/`. Untracked files are not counted. The trade-off: an untracked file a test happens to read can influence a verdict without dirtying the tree. Counting untracked files instead would refuse every run in a checkout with stray build output, which is the common case.
- **Public repository:** examples use generic ids (`SPEC-AUTH-001#token-ttl`, `ADR-007#…`). No host-project names.
- **Commits:** every message ends with the executing session's attribution trailer. Never `--no-verify`.

## Review Focus

1. **CRLF docs:** a governing doc saved with `\r\n` must anchor quotes exactly as its LF twin does (`\r` is part of a line wrap). Test `test_v2_crlf_doc` (Task 3).
2. **Non-ASCII quote text** (`é`, `—`, `§`): occurrence counting and V8 line coverage must use codepoints throughout. A jq 1.6 byte-offset `index` would shift every later line. Tests `test_v2_unicode_quote` (Task 3) and `test_v8_unicode_line_coverage` (Task 18).
3. **Paths with spaces** in `subject`, a test node, a lint path or an adapter argument must reach the adapter as one argument. Test `test_run_node_with_spaces` (Task 7).
4. **A sidecar whose doc was archived or renamed** (`git mv` into `docs/archive/`): while it holds live claims, one V1 finding names the doc and advises `RETIRE` + `move-entry`, never a crash or a V2 storm. Once every claim is retired, it is a legal end state. Tests `test_v1_archived_doc_sidecar` and `test_v1_archived_doc_all_retired_ok` (Task 2).
5. **An adapter printing noise or malformed JSON** (a log line on stdout, a missing `outcome`, an unknown outcome) makes every requested node `indeterminate` (exit 2). It is never a pass, and never exit 1. Test `test_run_adapter_malformed_json_indeterminate` (Task 7).

## Design deviations

| Design statement | Plan | Why |
|---|---|---|
| §H "Wording everywhere: `update-index` / `last_verified` record a baseline reset, never verification" | Applied to **prose** only: SKILL.md, the references, doc-tools' help text. The CLI report token `Re-verified`, the JSON field `last_verified` and the verb names stay. | Renaming an output token or field changes behaviour for projects without `docs/spec-claims/`, which a non-goal forbids, and `test-doc-tools.sh` pins `Re-verified 1 entry`. |
| §B status block "lists every non-`built` claim" | Lists every claim that is neither `built` nor `retired`. `Claims: N built` renders when every non-retired claim is `built`. | A retired claim has no tracker and its sentence is struck. Listing it would put dead text in the block a reader uses to see open gaps. |
| §C V6 "a claim deleted … without a new ruling" | Deleting a single claim is a V6 finding: "retire it instead". The one legal deletion is a **whole sidecar whose claims were all `retired` at `_CL_MB`**. | A deleted record cannot carry the ruling that would license its deletion, and `RETIRE` keeps the history. An archived or deleted governing doc still needs an end state, so its fully retired sidecar may go. |
| §F "the direction protocol replaces 'surface to user, let them decide'"; §E Execute "flags and continues" | The replacement is **conditional on claims being enabled**. The existing wiring lines (`spec-lifecycle-protocol.md` wiring block) and the Execute *Drifted* branch stay as written, and each gains a "Claims-enabled projects:" sentence. | The non-goal "changing behaviour for projects without `docs/spec-claims/`" outranks the replacement. Projects without claims keep the exact instructions they have today. |
| §B / V5 "an open tracker" | A tracker that is a repo path is open unless its `**Status**:` / front-matter `status:` value matches `closed|resolved|done|fixed|completed|wontfix` (case-insensitive). A tracker matching `tracker_patterns` (an issue number, a URL) is accepted as open. | A pattern tracker's state lives in a remote service a pre-commit hook cannot read offline. |
| §B quote normalisation "whitespace and line wraps collapsed; emphasis stripped" | It also strips leading blockquote markers (`>`) per line, and masks code-fence lines before stripping `~~…~~` strikes. | Without the first, a quote that wraps inside an `AMENDED` block (a blockquote) could never match, though §B says those blocks are live. Without the second, a `~~~` fence would be read as a strike. |

## Design clarifications (decisions the design leaves open)

- **Sidecar envelope:** `{"schema": 1, "doc": "<repo path>", "claims": [<claim record>…]}`. The claim record is exactly §B's. The file stem must equal the DOC-ID of `doc`.
- **DOC-ID:** for an ADR, the filename prefix matched by `^ADR-[0-9]+`; for a spec, `^SPEC-[A-Z]+-[0-9]+`; for a host-added glob (`governing_extra`), the file stem. A doc under a default glob with no id prefix (`template.md`, `README.md`) is not governing.
- **Ruling fields:** `{date, direction, by, record, reason}`. `reason` is required for `DOC-STALE` and `RETIRE`, because §F "the ruling records why" and the amendment batch (§E (4)) prints it.
- **Tracker:** a repo path present in the proposed tree and open (Design deviations), or a string matching one of config `tracker_patterns` (an ERE, e.g. `^#[0-9]+$`).
- **V8 default normative headings**, matched case-insensitively against the heading text at any level: `design` (the spec template's only normative section, `references/doc-spec.md` `## Design`), `requirements?`, `invariants?`, `interfaces?`, `inputs?`, `outputs?`, `inputs? and outputs?`, `decisions?`, `.*(phase|stage) contracts?`. Also an ADR's `Decision`, the resolved column of an `Open questions` table, and the host's `normative_headings`.
- **V8n "citing a normative section is exempt":** the trigger phrases are exactly `as specified`, `conforms`, `aligned with`, `matches §`, `implemented per`. A descriptive line that points at a normative section without one of them (`see §Interfaces`) is never flagged.
- **V3 `subject_imports_ok: false`** is a finding for every status (the design's literal rule), though its rationale names `unbuilt`.
- **CLI options the design implies but does not name:** `--base <ref>` on every verb; `claims gate --from <rev> --holds <id> --by <principal>` (V9 adjudication must be recorded); `claims promote --reverify (<id>…|--all)` (§G scheduled re-verification); `claims run --scheduled --judge-sample <n>` (log claims and the rotating judge sample); `claims rulings --format json|markdown`.
- **Config keys beyond §B's list:** `base`, `governing_extra`, `code_roots`, `plans`, `tracker_patterns`, `source_doc_patterns`, `blocking`.
- **Gate preconditions:** `claims gate`, `claims promote` and `claims attest --final` refuse with exit 2 (`reason: dirty-tree`) when the dirty-tree check (Global Constraints) finds anything. A record's `tree` is then the tree its verdicts ran on.
- **Gate-exempt commits:** after the final gate, a commit counts as doc-only when every path it touches is a non-code path (`_claims_is_code_path`, Task 14). With `code_roots` empty, everything outside `docs/` is code.
- **Plan governing specs (V12, policy):** a plan's governing specs are the union of the `- <path> — <role>` lines in its injected `**Specs**` lists, plus a `governing_specs:` front-matter list (each entry with an optional `:role` suffix). For the decomposition check and the ruling policy (Task 15), `infer` counts as `target`.
- **Final-gate reconciliation:** rulings made at the final gate name `docs/spec-claims/gates/<plan-stem>/final.json` as their `record`. `final.json` carries a `reconciliations` field built, over the changes since the last chunk record's `head`, by the same record-inclusion rule as chunk records (Task 16). A ruling counts only when its `record` names that record. A promotion counts when its `verdict_sha256` matches the digest a record stored for it (decided by digest, never by the local verdict store, so a fresh clone or CI gives the same answer). Status changes carried by a counted ruling or promotion count too. Without a local verdict, "re-promote owed" is decided by commit order (Task 5). `attest --final` writes the file even when red, so the record exists before the ruling that cites it.
- **DOC-STALE on a `built`/`gated` claim:** the amendment changes `states`, so the verdict no longer matches. V6 reports advisory `re-promote owed` instead of a blocking mismatch when the same change carries the covering DOC-STALE/RETIRE ruling. `promote` re-proves the claim, and `gate`/`attest` are red until it has.
- **Promote and the clean tree:** the injected gate task commits after each `claims promote` (Task 25), so a second promote sees a clean tree. The dirty check is not loosened.
- **Pre-commit claims leg** blocks on exit 1 whatever `DOC_SUPERPOWERS_STRICT` says (V1–V6, V10–V12 are blocking by design). `DOC_SUPERPOWERS_CLAIMS_SKIP=1` bypasses that leg alone. An exit 2 warns, and blocks only under STRICT.
- **Dogfood** (design Verification, last bullet) is this repository's *next* plan. Nothing here creates `docs/spec-claims/` in this repo.

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `scripts/doc-tools.sh` | Modify | `claims` verb rows in `_VERBS`; a `# --- Spec claims ---` section (`_claims_*` helpers, `_JQ_CLAIMS_*` jq programs, `cmd_claims_{validate,run,promote,render,gate,attest,rulings}`); a claims exit-code family in `_main` / `_usage_error` / `_on_exit` / `_die`; worktree cleanup in `cleanup`; help notes; the update-index wording |
| `scripts/test-spec-claims.sh` | Create | Sixth suite: one fixture per check, run / promote / gate / attest flows, replay fixtures |
| `scripts/test-spec-status-model.sh` | Modify | Pins R5, the injected gate tasks, the direction protocol, the inert conditionals, the update-index wording |
| `scripts/test-hooks.sh` | Modify | Pre-commit claims leg (inert / blocking / advisory / skip), pre-push advisory |
| `scripts/test-doc-pr-release.sh` | Modify | `claims-check.sh`, the claims job in `doc-spec-verify.yml`, the schedule step, `update-pr-body.sh` named sections |
| `scripts/hooks/git/pre-commit`, `scripts/hooks/git/pre-push` | Modify | Claims legs |
| `scripts/hooks/ci/doc-superpowers-steps/claims-check.sh` | Create | CI step: `pr` and `scheduled` modes, scalar outputs |
| `scripts/hooks/ci/doc-spec-verify.yml`, `scripts/hooks/ci/doc-freshness-schedule.yml` | Modify | Claims job / step |
| `scripts/hooks/ci/doc-pr-release/update-pr-body.sh` | Modify | `DOC_SUPERPOWERS_SECTION` named managed section, inserted at the top |
| `references/spec-claims.md` | Create | Schema, checks, adapters, policy, reference pytest/jest helpers |
| `references/spec-lifecycle-actions.md`, `references/spec-lifecycle-protocol.md`, `references/integration-patterns.md`, `references/doc-spec.md`, `references/hooks.md`, `references/output-templates.md`, `skills/doc-superpowers/SKILL.md` | Modify | Lifecycle (§E), R5, direction protocol (§F), template, hooks/CI, wording |
| `CLAUDE.md`, `README.md`, `docs/codebase-guide.md`, `docs/conventions.md`, `.github/workflows/tests.yml`, `RELEASE-NOTES.md`, the 5 manifests, `.github/` (installer output) | Modify | Suite list and counts, docs, release 3.2.0 |

---

## Chunk 1: Sidecars, `claims validate` core, the status block

### Task 1: Claims verb group, exit-code family, verdict emitter, config, inert behaviour, suite skeleton

**Files:**
- Modify: `scripts/doc-tools.sh`: `_VERBS` (insert the seven `claims` rows after `set-implementation`), `_usage_error`, `_main`, `cleanup`, `_USAGE_NOTES` (new "Spec claims" paragraph and an exit-status paragraph); new section `# --- Spec claims ---` before `# --- Main ---`
- Create: `scripts/test-spec-claims.sh`
- Modify: `.github/workflows/tests.yml` (a `test-spec-claims.sh` step after `test-merge-driver.sh`, so CI covers the suite from its first commit; the comment's "five suites" becomes "six")

**Interfaces:**
- Produces (verb rows, exact):
  ```
  claims validate|cmd_claims_validate|repo|staged all config=* base=
  claims run|cmd_claims_run|repo|claims+ planes-of= all scheduled judge-sample= base=
  claims promote|cmd_claims_promote|repo|reverify all base=
  claims render|cmd_claims_render|repo|check base=
  claims gate|cmd_claims_gate|repo|plan= chunk= from= holds=* by= base=
  claims attest|cmd_claims_attest|repo|plan= final deep base=
  claims rulings|cmd_claims_rulings|repo|range= format= base=
  ```
  Verbs whose handler is not written yet get a stub that calls `_claims_init` and `_claims_emit`, so each is inert-correct from Task 1 on.
- Produces (exit discipline, verified against `_on_exit` / `_exit_ok` / `_die` at doc-tools.sh:1418 and :1487-1500):
  - `_main`, when the verb starts with `claims`, sets `_CL_ACTIVE=1` and runs `exec 9>&1` before verb lookup. fd 9 is the run's real stdout (a fixed fd number: bash 3.2 has no `{fd}`; doc-tools uses no fd 9 today). Every verdict (`_claims_emit`, `_claims_die`, the inert object, the `_on_exit` fallback) and the `rulings --format markdown` output are written with `>&9`. So a verdict printed inside a `$(…)` subshell still reaches the caller instead of being captured into a variable.
  - "Emitted" is recorded twice: `_CL_EMITTED=1` in the current shell, and `: > "$_SCRATCH/cl-emitted"` (a subshell's variable never reaches its parent; the file does). `_claims_emit`, `_claims_die`, the inert path, `_usage_error` (before its exit 3) and `cmd_claims_rulings --format markdown` (after printing) record it through one helper, `_claims_mark_emitted`. That helper sets `_CL_EMITTED=1` **first, before any I/O**, and writes the marker file **only when `[ -n "$_SCRATCH" ]`**. Before the scratch dir exists, no `$(…)` has run claims code yet, so the variable alone suffices. A marker is never written to `/cl-emitted` (an empty `$_SCRATCH`), not even on a failure path. The emitters end through `_exit_ok` for rc 0 (the EXIT trap turns a bare `exit 0` into 1 unless `_EXIT_OK=1`) and `exit <rc>` otherwise.
  - **Scratch creation failure:** `_scratch_init` assigns through a temporary (`d=$(mktemp -d -t doc-tools.XXXXXX) || { _SCRATCH=""; _die "mktemp -d failed"; }`, then `_SCRATCH=$d`), so `_SCRATCH` is still empty when `_die` → `_claims_die` runs. The result is exit 2, one verdict object on fd 9, no marker file, and no `/cl-…` path touched. This changes `_scratch_init` for every verb, but only in how the failed value is held: the other verbs still exit 1 through `_die`.
  - Required-argument violations (missing `--plan`/`--chunk`, not exactly one of `--staged`/`--all`, a missing `<id>`) go through `_usage_error <verb> <message>`, so they exit 3 like every other usage error.
  - `_on_exit`: when `_CL_ACTIVE=1` and neither `_CL_EMITTED=1` nor (with `_SCRATCH` non-empty) `$_SCRATCH/cl-emitted` exists, any rc other than 130/143 becomes 2, and it prints `{"verb":<verb>,"enabled":true,"exit":2,"error":"internal failure (rc <original rc>)"}` to fd 9 (stdout if fd 9 is not open, i.e. the failure came before `exec 9>&1`). That covers a `set -u` crash, a stray `exit 1`, a failed jq. When the marker file exists (a subshell already emitted), no second object is printed and the rc still maps to 2 (or keeps the emitted code if it was 0/1/3).
  - `_die`, with `_CL_ACTIVE=1`, delegates to `_claims_die`, which calls `_claims_mark_emitted` (the variable first; the file only if scratch exists), prints the error verdict to fd 9, and exits 2.
  - **`_claims_die` inside `$(…)`:** the verdict reaches the real stdout through fd 9 and the subshell exits 2. The parent then **propagates** that exit; it never continues with the half-built value. Every command substitution in claims code that can die is written `v=$(…) || _claims_propagate $?`, where `_claims_propagate <rc>` exits `<rc>` (normally 2) without printing, since the marker file shows a verdict was already emitted. A bare `v=$(…)` that fails under `set -e` reaches `_on_exit`, which sees the marker and prints nothing more. Either way stdout holds exactly one JSON object.
- Produces (shell helpers, all in doc-tools.sh):
  - `_claims_init <mode>`, where mode is `staged|all|head`. Sets `_CL_ENABLED` (0/1), `_CL_MODE`, `_CL_ROOT` (top level, absolute), `_CL_BASE_REF`, `_CL_MB` (the merge-base sha, empty when unresolvable). Writes the merged config to `$_SCRATCH/cl-config.json` and creates the empty JSONL accumulators `$_SCRATCH/cl-findings.jsonl`, `cl-advisories.jsonl`, `cl-indet.jsonl`, `cl-results.jsonl`. Calls `_scratch_init`.
  - `_claims_finding <check> <claim|-> <doc|-> <message>`, `_claims_advisory <check> <claim|-> <code> <message>`, `_claims_indeterminate <check> <claim|-> <reason>`, `_claims_result <json-object>`. Each appends one JSONL row.
  - `_CL_ALL_BLOCKING`: set to 1 by `run`, `promote`, `gate` and `attest` (Global Constraints → Blocking).
  - `_claims_emit <verb> [<extra-json>]` prints one verdict object and exits with the precedence code. A finding goes to `findings` (it drives exit 1) when `_CL_ALL_BLOCKING=1` or its check is in config `blocking`; otherwise it goes to `advisories`. Verdict object:
    `{"verb", "enabled": true, "exit", "base": {"ref", "merge_base"}, "findings": [{"check","claim","doc","message"}], "advisories": [{"check","claim","code","message"}], "indeterminate": [{"check","claim","reason"}], "results": [...]}`, merged with `<extra-json>`.
  - `_claims_die <message>` prints `{"verb", "enabled": true, "exit": 2, "error": <message>}` to fd 9 and exits 2 (see exit discipline above).
  - `_claims_jq <label> <jq args…>`: every jq call in claims code goes through it. It runs `jq "$@"`, and on a non-zero status it calls `_claims_die "jq failed (<label>, rc <n>)"`, so a jq failure inside `$(…)` emits its one verdict there. The exception is a `jq -e` predicate whose non-zero status is an answer, not a failure; those call jq directly inside an `if`.
  - `_claims_read <path>` prints the proposed content (mode `staged`: `git show ":$path"`; `all`/`head`: the working tree / `HEAD:`) and returns 1 when the path is absent. `_claims_read_at <rev> <path>` does the same at a revision.
  - `_claims_glob_match <path> <glob>`: a `case` pattern, where `*` also crosses `/` (documented in the help text).
- Config defaults (`_JQ_CLAIMS_DEFAULTS`, deep-merged with jq `*` under the host file; arrays are replaced, except that `governing_extra` is appended to `governing`):
  ```json
  {"schema":1,"base":"origin/main","governing":["docs/adr/*.md","docs/specs/*.md"],"governing_extra":[],
   "normative_headings":[],"descriptive_headings":[],"kinds":[],"code_roots":[],
   "plans":["docs/superpowers/plans/*.md","docs/plans/*.md"],"tracker_patterns":[],
   "source_doc_patterns":["docs/issues/","docs/superpowers/specs/"],
   "runners":{},"log_adapter":null,"config_adapter":null,
   "policy":{"in_plan_ruling_requires_gate_record":true,"outside_plan_presumption":"CODE-DIVERGES","doc_stale_outside_plan_requires":null},
   "blocking":["V1","V2","V3","V4","V5","V6","V10","V11","V12"]}
  ```
  A `config.json` that is not one JSON object makes the run exit 2 (`_claims_die`). An unknown top-level key is a V1 finding (`config: unknown key <k>`).

- [ ] **Step 1: Write the failing tests.** Create `scripts/test-spec-claims.sh` with the header and harness wiring of `test-doc-tools.sh` (`source test-helpers.sh`; `DOC_TOOLS="$(bash_bin_shim "$SCRIPT_DIR/doc-tools.sh")"`; `run_tests` at the bottom listing every `test_*`, then `print_summary`). Add these fixture helpers, used by every later task:
  - `claims_fixture`: `setup`, then write `docs/specs/SPEC-AUTH-001-token.md` with `## Summary` / `## Requirements` (`- Access tokens expire after 15 minutes.` / `- Refresh tokens are single-use.`) / `## Implementation Notes` / `## Open Questions` (a table `| Question | Resolved |` with the row `| Rotate keys? | Keys rotate every 30 days. |`); `src/auth/token.py` (`TTL_SECONDS = 900`); `docs/issues/token-ttl.md`; `docs/spec-claims/config.json` = `{"schema":1,"base":"main"}`; `docs/spec-claims/SPEC-AUTH-001.json` with one claim `SPEC-AUTH-001#token-ttl` (`quote` "Access tokens expire after 15 minutes", `states` "An issued access token is rejected 15 minutes after issue.", `kind` behaviour, `subject` `["src/auth/token.py"]`, `status` unbuilt, `enforced_by` test, `test` null, `tracker` `docs/issues/token-ttl.md`, the remaining §B fields null/empty). Commit on `main`, then `git checkout -qb feature`.
  - `cl <verb> [args…]`: runs `"$DOC_TOOLS" claims <verb> args` and sets `CL_RC`, `CL_OUT` (stdout) and `CL_ERR`.
  - `jset <file> <jq-filter>`: rewrites a JSON file in place via jq.

  ```bash
  test_inert_without_spec_claims_dir() {
    echo "test: no docs/spec-claims/ → every claims verb is inert"
    setup
    local v
    for v in validate run promote render gate attest rulings; do
      cl "$v"
      assert_eq "0" "$CL_RC" "claims $v exits 0 without docs/spec-claims/"
      assert_json_field "$CL_OUT" '.enabled' "false" "claims $v reports enabled:false"
    done
    teardown
  }
  ```
  Also add:
  - `test_usage_errors_exit_3`: with claims enabled, `claims validate --bogus`, `claims frobnicate`, `claims validate --staged --all` and `claims gate` (no `--plan`) each exit 3. The general verb `status --bogus` still exits 2.
  - `test_inert_runs_before_required_args`: no `docs/spec-claims/`, so `claims gate` (no `--plan`) and `claims validate` (no mode) exit 0 with `enabled:false`, while `claims validate --bogus` exits 3.
  - `test_internal_failure_exit_2_never_1`: the injected scratch-creation failure. Claims enabled, `TMPDIR=$SUITE_TMP/absent cl validate --all` makes `_scratch_init`'s `mktemp -d` fail → rc 2, `.error` contains `mktemp`, and stdout is exactly one JSON object (`jq -s 'length'` = 1). No file named `cl-emitted` exists anywhere the run could reach (`/cl-emitted` is absent, and `find "$TEST_DIR" "$SUITE_TMP" -name cl-emitted` prints nothing).
  - `test_usage_error_no_stray_marker`: claims enabled, `cl validate --bogus` → rc 3, and `find "$TEST_DIR" "$SUITE_TMP" -name cl-emitted` prints nothing. The marker is a variable only: the usage error comes before scratch exists, and `/cl-emitted` is absent.
  - `test_die_in_subshell_single_verdict`: claims enabled, with `PATH` prefixed by a test-only `jq` shim. The shim execs the real jq, except that it exits 5 when any argument contains `governing_extra`, which only the config-merge program (`_JQ_CLAIMS_DEFAULTS`) contains. `_claims_init` runs that program as `cfg=$(_claims_jq config-merge … ) || _claims_propagate $?`, so the failure reaches `_claims_die` inside the subshell. Expected: rc 2, `.error` non-empty, and `jq -s 'length'` of stdout = 1 (no second object from `_on_exit`).
  - `test_rulings_markdown_exit_0`: `cl rulings --range HEAD..HEAD --format markdown` → rc 0 (not mapped to 2) and stdout is Markdown, not JSON.
  - `test_base_unresolvable_indeterminate`: config `base` `nope`, so `claims validate --all` → rc 2 and `.indeterminate[0].reason == "base-unresolvable"`.
  - `test_config_malformed_exit_2`.
  - `test_v1_config_unknown_key`: rc 1, `.findings[0].check == "V1"`.
- [ ] **Step 2: Run the suite.** Expected: FAIL. Every assertion reports an unknown subcommand (rc 2).
- [ ] **Step 3: Implement.** Rows, stubs and helpers as in Interfaces. In `_main`, set `_USAGE_RC=3` and `_CL_ACTIVE=1` before verb lookup when `$1` is `claims` (`_USAGE_RC` defaults to 2), and have `_usage_error` exit `$_USAGE_RC`. For a `claims` verb, a failed `check_deps` exits 2 instead of 1. On jq 1.6: the risk is accepted (ruled 2026-10-10). Both CI runners ship jq 1.7.x, so the 1.6 floor, which predates this plan, is not exercised by CI. Code still avoids the known 1.6 traps (Global Constraints → jq regex). `_claims_init` checks `[ -d docs/spec-claims ]` first and, when it is absent, prints the inert object and exits 0 (via `_exit_ok`) before reading any config. Each handler validates its required arguments only after `_claims_init` returns: exactly one of `--staged` / `--all` for `validate`, and `--plan` + `--chunk` for `gate`. A violation calls `_usage_error` (exit 3, emitted marker set). For the merge-base: `git rev-parse -q --verify "$ref^{commit}"`, then `git merge-base HEAD "$ref"`; on any failure, `_CL_MB=""` and an indeterminate row `{"check":"V6","claim":null,"reason":"base-unresolvable"}`. Help text: a "Spec claims" note naming the four exit codes and their precedence, and noting that `*` in a claims glob crosses `/`.
- [ ] **Step 4: Run the suite.** Expected: PASS. Also run `bash scripts/test-doc-tools.sh`, whose bash-4 guard and usage tests must still pass.
- [ ] **Step 5: Commit** `feat(claims): claims verb group, exit-code family and inert default` (with the self-install refresh).

### Task 2: V1 schema

**Files:** Modify `scripts/doc-tools.sh` (Spec claims section) and `scripts/test-spec-claims.sh`.

**Interfaces:**
- Produces: `_claims_doc_id <path>`, which prints the DOC-ID or nothing. `_claims_is_governing <path>`, which returns 0 when the path matches a governing glob and has a DOC-ID. `_claims_load`, which writes `$_SCRATCH/cl-claims.json` (proposed) and `$_SCRATCH/cl-claims-base.json` (at `_CL_MB`; `[]` when it is empty). Each is an array of `{"sidecar","doc","doc_id","claim":{…}}` built from `docs/spec-claims/*.json` minus `config.json`, never from `gates/`. In mode `staged` the list comes from `git ls-files --cached -- 'docs/spec-claims/*.json'`. `_claims_touched` writes `$_SCRATCH/cl-touched.json`, the claim ids V1–V6 check under `--staged`: every claim of a staged sidecar, every claim of a staged doc, every claim whose `subject`, `test` file or `lint.paths` include a staged path. Under `--all`, every claim.
- Produces (jq def `claims_v1` in `_JQ_CLAIMS_SCHEMA`): one finding message per violation. Enums: `status` ∈ built/diverged/unbuilt/retired (+ `gated`, Task 21). `kind` ∈ behaviour/interface/config + config `kinds`. `enforced_by` ∈ test/lint/log/judge. Ruling `direction` ∈ CODE-DIVERGES/DOC-STALE/RETIRE. Required: `id`, `quote`, `states`, `kind`, `subject` (array), `status`, `enforced_by`. `test` = `{runner, node[, file]}`; it may be null only while `unbuilt`. `lint` = `{pattern, paths[], expect: present|absent, selftest: {violates, clean}}`. A ruling needs `date` (`YYYY-MM-DD`), `by` and `record` non-empty, and `reason` non-empty for DOC-STALE/RETIRE. The id must match `^<DOC-ID>#[a-z0-9][a-z0-9-]*$`. Ids are unique across all sidecars. The sidecar stem must equal the DOC-ID of `doc`. `doc` must be governing and present, **unless every claim in the sidecar is `retired`**: a fully retired sidecar may name an archived, moved, deleted or non-governing doc, and V2 is skipped for it. For that case the DOC-ID comes from the doc path's basename by the same prefix rules (`docs/archive/specs/SPEC-AUTH-001-token.md` → `SPEC-AUTH-001`).

- [ ] **Step 1: Write the failing tests.** Each mutates the fixture sidecar with `jset`, then runs `cl validate --all` and asserts rc 1 and `.findings[] | select(.check=="V1")` with the named substring in `.message`:

  | Test | Mutation | Message contains |
  |---|---|---|
  | `test_v1_malformed_record` | delete `.claims[0].states` | `states` |
  | `test_v1_bad_id` | id `SPEC-AUTH-001-token-ttl` | `id` |
  | `test_v1_duplicate_id` | append a copy of claim 0 | `duplicate` |
  | `test_v1_doc_not_governing` | `doc` = `docs/notes.md` (created) | `not governing` |
  | `test_v1_stem_mismatch` | rename the sidecar to `SPEC-AUTH-002.json` | `stem` |
  | `test_v1_host_glob_doc_id_is_stem` | `governing_extra: ["docs/evals/*.md"]`; sidecar `docs/spec-claims/prereg-a.json` for `docs/evals/prereg-a.md` | rc 0, no V1 |
  | `test_v1_ruling_missing_reason` | a DOC-STALE ruling without `reason` | `reason` |
  | `test_v1_archived_doc_sidecar` | `git mv` the spec to `docs/archive/specs/`, live claim | exactly one V1 finding, message has `RETIRE` and `move-entry`; no V2 finding |
  | `test_v1_archived_doc_all_retired_ok` | the same, with the claim `retired` (RETIRE ruling, `record` an issue doc) and `doc` = the archived path | rc 0, no V1, no V2 |
  | `test_v1_valid_fixture_passes` | none | rc 0, `.findings == []` |
- [ ] **Step 2: Run the suite.** Expected: FAIL on these rows.
- [ ] **Step 3: Implement** `_claims_load`, `_claims_touched` and V1 in `cmd_claims_validate`. If a doc is missing or not governing, skip V2–V5 for its claims (Review Focus 4); V6 still runs.
- [ ] **Step 4: Run the suite.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(claims): V1 schema validation` (with the self-install refresh).

### Task 3: Quote normalisation and V2 anchor

**Files:** Modify `scripts/doc-tools.sh` and `scripts/test-spec-claims.sh`.

**Interfaces:**
- Produces `_JQ_CLAIMS_NORM`, the jq defs that Task 6 (render), Task 18 (V8) and Task 19 (V8n) consume:
  - `claims_live`: raw text → the same line count, with dead spans blanked to their newlines.
  - `claims_norm`: string → normalised string.
  - `claims_doc`: raw doc → `{"text": <normalised>, "lines": [{"n": <1-based line>, "start", "end", "amended": bool}]}`. `start`/`end` are codepoint offsets into `text` for every line whose normalised form is non-empty.
  - `claims_occ($q)`: on `claims_doc` output → the array of non-overlapping start offsets of `$q` in `.text`.
  - `claims_lines_hit($q; $k)`: line numbers intersecting the `$k`-th occurrence.
- Bash 3.2: all of it runs in one `jq -Rs` call per doc. No shell loops over lines.

  ```jq
  def claims_blank: gsub("[^\n]"; "");
  # Fence masking first, so a ~~~ fence is never read as a strike: one reduce over the
  # lines, toggling on ^[ \t]*(```|~~~); a fence delimiter line becomes "", and every "~"
  # inside fenced content becomes the sentinel U+FFFF, always written in the source as the
  # six-character jq escape \uffff (ASCII), never as a raw U+FFFF byte sequence.
  def claims_mask_fences: split("\n") | <reduce as described; masks with "\uffff"> | join("\n");
  def claims_live: gsub("\r\n"; "\n") | claims_mask_fences
    | gsub("(?<s><!-- spec-claims:status:begin -->[\\s\\S]*?<!-- spec-claims:status:end -->)"; .s | claims_blank)
    | gsub("(?<s>~~[\\s\\S]*?~~)"; .s | claims_blank)
    | gsub("\uffff"; "~");
  def claims_norm_line: sub("^[ \t]*(>[ \t]?)+"; "") | gsub("[*_`]"; "") | gsub("[ \t]+"; " ")
    | sub("^ "; "") | sub(" $"; "");
  def claims_norm: claims_live | split("\n") | map(claims_norm_line) | map(select(. != "")) | join(" ");
  # claims_doc: reduce over the claims_live lines; a non-empty normalised line gets
  #   start = current offset, end = start + length; offset += length + 1 (the joining space).
  #   amended = the line starts with ">" and belongs to a blockquote whose first line matches
  #   ^>.*\*\*AMENDED [0-9]{4}-[0-9]{2}-[0-9]{2}  (state carried through the reduce).
  # claims_occ($q): positions from split($q): p_0 = len(part_0); p_k = p_{k-1} + len($q) + len(part_k).
  ```
- V2 rules, with `count = (.text | split($q) | length) - 1` and `$q = (quote | claims_norm)`:
  - `quote_occurrence` absent → `count == 1`;
  - present (n) → `count >= n`;
  - `retired` → `count == 0`;
  - `count > 1`, some occurrence hits an `amended` line, and no `quote_occurrence` → the uniqueness finding's message becomes `AMENDED block re-quotes a claimed sentence: set quote_occurrence to the live occurrence (a ruling alone does not anchor it)`.
  
  The design's "or a ruling" route is anchored by `quote_occurrence`: a `DOC-STALE` ruling that re-quotes the sentence in an `AMENDED` block must set `quote_occurrence` (normally to the amended occurrence) in the same change. There is no ruling-only exemption, because with `count == 2` the claim would still have no unique anchor.

- [ ] **Step 1: Write the failing tests** (all `cl validate --all`; a "finding" is rc 1 with `.findings[].check == "V2"`):

  | Test | Doc / claim change | Expect |
  |---|---|---|
  | `test_v2_unique_live_quote_passes` | none | rc 0 |
  | `test_v2_quote_missing` | change "15" to "30" in the doc | finding `not found` |
  | `test_v2_quote_twice_needs_occurrence` | add a second copy of the sentence under `## Summary` | finding `2 live occurrences`; then `quote_occurrence: 1` → rc 0 |
  | `test_v2_reflow_passes` | wrap the sentence over two lines with extra indent | rc 0 |
  | `test_v2_emphasis_stripped` | doc `**Access** tokens expire after _15_ minutes` | rc 0 |
  | `test_v2_struck_text_not_live` | wrap the original in `~~…~~` and add a fresh copy | rc 0 (the struck copy is not counted) |
  | `test_v2_multiline_struck_lazy` | two struck spans on separate lines with the quote between them | rc 0 (the lazy match does not swallow the quote) |
  | `test_v2_status_block_not_live` | the quote copied inside the status markers | rc 0 |
  | `test_v2_retired_quote_still_live` | status `retired` + a RETIRE ruling, sentence not struck | finding `retired` |
  | `test_v2_amended_requote_fires` | add `> ⚠️ **AMENDED 2026-10-10 — ttl.** Access tokens expire after 15 minutes.` under Requirements | finding `AMENDED block re-quotes` |
  | `test_v2_amended_requote_with_occurrence_ok` | same, plus `quote_occurrence: 2` | rc 0 |
  | `test_v2_amended_requote_ruling_alone_fails` | same as the re-quote case, plus a new DOC-STALE ruling and no `quote_occurrence` | finding `a ruling alone does not anchor it` |
  | `test_v2_tilde_fence_not_strike` | a `~~~` fenced block above the sentence and another below it | rc 0 (the fences are not a strike span) |
  | `test_v2_fenced_tilde_restored` | a fenced line `a ~~ b` and the claim quoting a prose line after the fence | rc 0 |
  | `test_no_raw_sentinel_in_doc_tools` | none (static) | `LC_ALL=C grep -c $'\xef\xbf\xbf' scripts/doc-tools.sh` = 0, and `grep -cF '\uffff' scripts/doc-tools.sh` ≥ 2 |
  | `test_v2_crlf_doc` | `sed 's/$/\r/'` over the doc | rc 0, same as LF |
  | `test_v2_unicode_quote` | quote `Tokens — même après 15 minutes` in a doc whose earlier lines hold `é`/`—` | rc 0; `claims_occ` offset equals the jq codepoint offset (assert via `jq -Rs` on the doc) |
- [ ] **Step 2: Run the suite.** Expected: FAIL on these rows.
- [ ] **Step 3: Implement** `_JQ_CLAIMS_NORM` and V2 (one `jq -Rs --argjson claims …` per doc touched).
- [ ] **Step 4: Run the suite.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(claims): quote normalisation and V2 anchoring` (with the self-install refresh).

### Task 4: V5 status

**Files:** Modify `scripts/doc-tools.sh` and `scripts/test-spec-claims.sh`.

**Interfaces:** Produces `_claims_tracker_open <tracker>`. It returns 0 when the tracker is a path in the proposed tree whose status value is not closed (a path with no status line is open). The status value is taken from the first `**Status**:` / `**Status:**` line, or front-matter `status:`. Strip leading whitespace, `*`, `` ` `` and `_`. The value's **leading word** (the first run of `[A-Za-z]+`) is matched exactly and case-insensitively against `^(closed|resolved|done|fixed|completed|wontfix)$`. A word appearing later in the value never counts: `Approved — not done` is open, `Done (2026-10-01)` is closed. The tracker is also open or when it matches a `tracker_patterns` ERE (tested in jq with `test()`; assumed open, Design deviations).

- [ ] **Step 1: Write the failing tests** (rc 1 and a `V5` finding unless noted): `test_v5_diverged_without_tracker` (status diverged, tracker null); `test_v5_tracker_missing_path` (tracker `docs/issues/nope.md`); `test_v5_tracker_closed_is_finding` (the issue doc gains `**Status**: Resolved` → finding `tracker is closed`); `test_v5_tracker_status_leading_word` (`**Status**: Approved — not done` → no V5, open; `**Status:** \`Done\` (2026-10-01)` → finding `tracker is closed`; front matter `status: reopened, was closed` → open); `test_v5_tracker_pattern_accepted` (`tracker_patterns: ["^#[0-9]+$"]`, tracker `#42`, a CODE-DIVERGES ruling → no V5); `test_v5_diverged_without_code_diverges_ruling` (diverged + tracker, no ruling); `test_v5_retired_without_ruling`; `test_v5_judge_without_why` (`enforced_by` judge, no `why_not_mechanical`).
- [ ] **Step 2: Run the suite.** Expected: FAIL.
- [ ] **Step 3: Implement V5.** `diverged`/`unbuilt` need an open tracker; `diverged` needs a CODE-DIVERGES ruling; `retired` needs a RETIRE or DOC-STALE ruling; `judge` needs `why_not_mechanical`. (`gated` is added in Task 21.)
- [ ] **Step 4: Run the suite.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(claims): V5 status requirements` (with the self-install refresh).

### Task 5: V6 merge-base ratchet (incl. token-changing re-anchor and the verdict-store read side)

**Files:** Modify `scripts/doc-tools.sh` and `scripts/test-spec-claims.sh`.

**Interfaces:**
- Consumes: `cl-claims.json` and `cl-claims-base.json` (Task 2), `claims_norm` (Task 3).
- Produces: `_claims_store_dir`, which prints the absolute `$(git rev-parse --git-common-dir)/spec-claims/promotions` (resolved with `cd … && pwd -P`). `_claims_sha256 <file>`, which calls `_hash_one` and strips its `sha256:` prefix (`${_HASH#sha256:}`). Every digest, verdict file name and `states_sha256` is that bare 64-hex form. `_claims_verdict_check <claim-json>`, which prints `ok`, `missing` or `mismatch`. The verdict file `<digest>.json` must exist, its bare sha256 must equal `promotion.verdict_sha256`, and its `.claim`, `.states_sha256` (bare sha256 of the `states` string's bytes), `.test` and `.status_to` must equal the claim's current values. The verdict file format itself is defined in Task 11.
- Rules (one jq pass over base and proposed records, joined by id, with no bash loop per claim). A "new ruling" is a ruling object in the proposed record that is not present (by JSON equality) at `_CL_MB`. Each item below is a V6 finding unless a new ruling exists:
  - `states` changed;
  - status moved off `built`;
  - `enforced_by` lowered (rank test 4 > lint 3 > log 2 > judge 1);
  - quote changed and `(old|claims_norm) != (new|claims_norm)`.
  
  Further:
  - A claim present at base and absent now is a finding `deleted: retire it instead`. The one exception is a whole sidecar deleted when every one of its claims was `retired` at `_CL_MB`.
  - Moving into `built`/`gated` (from another status, or a new claim) without `promotion` is a finding.
  - `_claims_verdict_check` runs for **every** `built`/`gated` claim whose record differs from its `_CL_MB` record, or which is new, not only for a status transition. `missing` → advisory code `unverifiable-here`. `mismatch` → finding, **unless** the same change carries a new `DOC-STALE` or `RETIRE` ruling on that claim (one not present at `_CL_MB`) that covers it. Then it is advisory code `re-promote owed` (message `states changed under a ruling: run claims promote <id>`). That is how a `DOC-STALE` amendment of a `built`/`gated` claim, which necessarily changes `states` and so the verdict's `states_sha256`, can be committed; `promote` then re-proves it (Task 11), and `gate`/`attest` treat it as red until it does (Tasks 16, 17). A claim byte-identical to its base record is not re-checked.
- Produces `_claims_repromote_owed <claim-id> <since-rev>`, which prints `owed`, `clear` or `unverifiable-here` for a `built`/`gated` claim (`clear` for any other status). Consumed by Tasks 16 and 17, with `<since-rev>` = the gate's `from` / `_CL_MB`.
  - **Verdict present locally:** `mismatch` → `owed`; `ok` → `clear`.
  - **Verdict missing** (a fresh clone, CI): decided by commit order, never by the store. For each covering DOC-STALE/RETIRE ruling absent at `<since-rev>`, find its introducing commit. That is the first commit in `git rev-list --reverse <since-rev>..HEAD -- <sidecar>` whose `git show <c>:<sidecar>` contains the ruling object (jq `any(.claims[] | select(.id == $id) | .rulings[]; . == $r)`), a bash loop over a short commit list. The claim is `owed` when that commit is **not** an ancestor of `promotion.at` (`git merge-base --is-ancestor <ruling-commit> <promotion.at>` fails): the amendment came after the proof. It is `clear` when every such commit is an ancestor (the claim was re-promoted after the amendment), or when there is no such ruling. When `promotion.at` does not resolve to a commit here (a rebased branch's old sha), the result is `unverifiable-here`.
  - A missing verdict on its own is never a finding, here or anywhere: `unverifiable-here` is always an advisory, as V6 already treats it.
  - Every new ruling: its `record` exists in the proposed tree and is neither the doc nor the sidecar (`self-referential record`), else a finding.
  - `_CL_MB` empty: V6 is skipped; the indeterminate row comes from Task 1.

- [ ] **Step 1: Write the failing tests.** Fixture: `claims_fixture` already branches `feature` off `main` with base `main`. Each test commits or stages its change on `feature` and runs `cl validate --staged` (staged changes) or `--all`:

  | Test | Change on `feature` | Expect |
  |---|---|---|
  | `test_v6_states_changed_without_ruling` | edit `states` | V6 finding `states` |
  | `test_v6_states_changed_with_doc_stale_ruling_ok` | edit `states`; add a DOC-STALE ruling (reason, `record` `docs/issues/token-ttl.md`) | rc 0 |
  | `test_v6_status_off_built_without_ruling` | base claim built (with a hand-written matching verdict file in the store), now `unbuilt` | finding |
  | `test_v6_enforced_by_lowered` | test → judge (+why) | finding `enforced_by` |
  | `test_v6_claim_deleted` | remove the claim | finding `retire it instead` |
  | `test_v6_sidecar_deleted_after_all_retired_ok` | on `main`: the claim retired (ruling) and the sentence struck, committed before the branch point; on `feature`: `git rm` the sidecar | rc 0 |
  | `test_v6_sidecar_deleted_with_live_claims_finding` | `git rm` the fixture's sidecar (claim `unbuilt` at base) | finding `retire it instead` |
  | `test_v6_built_record_edit_rechecks_verdict` | base claim built with a matching verdict; on `feature` change only `subject` (status stays built) and delete the verdict file | advisory `unverifiable-here` (re-checked though the status did not move) |
  | `test_v6_reanchor_reflow_needs_no_ruling` | quote → `Access  tokens expire\nafter 15 minutes` (doc reflowed to match) | rc 0 |
  | `test_v6_reanchor_token_change_needs_ruling` | doc and quote both "15" → "20" | finding `re-anchor` |
  | `test_v6_self_referential_record_refused` | a new ruling with `record` = the doc path; repeat with the sidecar path | finding `self-referential` (both) |
  | `test_v6_record_missing_refused` | `record` `docs/issues/absent.md` | finding `record` |
  | `test_v6_merge_base_ratchet_behind_trunk` | on `main` (after the branch point): DOC-STALE edit + ruling, committed; on `feature`: an unrelated commit | `cl validate --all` on `feature` → rc 0 |
  | `test_v6_hand_edited_built_refused` | status → built, no promotion | finding |
  | `test_v6_unverifiable_here_advisory` | status → built with `promotion` whose digest has no verdict file | rc 0, `.advisories[].code == "unverifiable-here"` |
  | `test_v6_verdict_mismatch_is_finding` | built + promotion whose verdict file exists but carries another `states_sha256` | finding `verdict` |
  | `test_v6_doc_stale_on_built_is_repromote_owed` | base claim built with a matching verdict; on `feature`, a DOC-STALE amendment (AMENDED block, new `states`, `quote_occurrence`, ruling with reason + existing record) | `--staged` rc 0, `.advisories[].code == "re-promote owed"`, no V6 finding |
  | `test_v6_mismatch_with_code_diverges_ruling_still_finding` | same, but the new ruling is CODE-DIVERGES (and status stays built) | finding `verdict` (only DOC-STALE/RETIRE cover a `states` change) |
  | `test_v6_staged_reads_index_not_worktree` | stage a clean sidecar, then dirty the worktree copy (states edit) | `--staged` rc 0; `--all` rc 1 |
- [ ] **Step 2: Run the suite.** Expected: FAIL.
- [ ] **Step 3: Implement V6** in `_JQ_CLAIMS_RATCHET`, with sha256 through `_claims_sha256`.
- [ ] **Step 4: Run the suite.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(claims): V6 merge-base ratchet` (with the self-install refresh).

### Task 6: `claims render`, the status block and V11

**Files:** Modify `scripts/doc-tools.sh` and `scripts/test-spec-claims.sh`.

**Interfaces:**
- Produces `_claims_render_doc <doc> <sidecar-json-file>`, which prints the doc's new content. The block is exactly:
  ```
  <!-- spec-claims:status:begin -->
  ## Claim status

  | Claim | Status | Tracker |
  |---|---|---|
  | `<id>` | <status> | <tracker or —> |

  <!-- spec-claims:status:end -->
  ```
  Rows are claims that are neither `built` nor `retired`, sorted by id. A `gated` row's status cell is `gated (when: KEY=VALUE, …)` (Task 21). When every non-retired claim is built, the table is replaced by the single line `Claims: N built`. The block carries no dates, SHAs or live values. It goes on the first render immediately before the doc's second `##` heading line outside a code fence (at end of file when there is none, after one blank line). Thereafter it replaces the span between the markers, inclusive.
- `claims render` writes every doc that has a sidecar (atomic), and reports `{"results": [{"doc", "changed": bool}]}`. `claims render --check` writes nothing, emits a V11 finding per doc that differs, and exits 1 on any.
- **Eligible sidecars only.** `render`, `render --check` and V11 (under `--staged` and `--all`) skip any sidecar whose `doc` is missing in the tree they read or is not governing. That is the same condition under which V2 is skipped (Task 2), and it is exactly the all-retired end state for an archived, moved or deleted doc. A skipped sidecar is reported as `{"doc", "skipped": "doc missing"|"not governing"}` in `results`. Nothing is ever written into an archived record, and a missing doc is never created.
- V11 in `validate --staged` applies only to docs whose sidecar is staged: it compares the staged doc against a render of the staged sidecar. Under `--all`, it covers every doc with an eligible sidecar.

- [ ] **Step 1: Write the failing tests:**
  - `test_v11_render_inserts_before_second_heading`: after `cl render`, the line before `## Requirements` region holds the end marker, and `## Summary` precedes the begin marker.
  - `test_v11_render_idempotent`: a second render reports `changed: false` and leaves `hash_file` equal.
  - `test_v11_render_all_built_one_line`: one claim, built with a verdict → block body `Claims: 1 built`.
  - `test_v11_check_detects_hand_edit`: edit a row → `render --check` gives rc 1 and V11.
  - `test_v11_only_when_sidecar_staged`: hand-edit the block, stage only the doc → `validate --staged` gives no V11; stage the sidecar too → V11.
  - `test_v11_fence_heading_ignored`: a `## x` inside a fence is not the second heading.
  - `test_v11_retired_not_listed`.
  - `test_render_archived_doc_skipped`: the claim retired (RETIRE ruling) and the spec `git mv`'d to `docs/archive/specs/`, with the sidecar's `doc` pointing there and committed. `cl render` leaves the archived file byte-identical (`hash_file` before and after) and reports `skipped: "not governing"`; `validate --all` and `validate --staged` (sidecar staged) give no V11; `render --check` → rc 0.
  - `test_render_deleted_doc_check_ok`: the claim retired and the spec deleted (`git rm`), with the sidecar kept. `render --check` → rc 0 with `skipped: "doc missing"`; `cl render` creates no file at the old path; `validate --all` gives no V11.
- [ ] **Step 2: Run the suite.** Expected: FAIL.
- [ ] **Step 3: Implement** (awk to find the insertion line, fence-aware with ```` ``` ````/`~~~` toggles; jq for the table).
- [ ] **Step 4: Run all six suites under both interpreters** (Global Constraints). Expected: no `FAIL:` line.
- [ ] **Step 5: Commit** `feat(claims): status block render and V11` (with the self-install refresh).

---

## Chunk 2: Runner adapters and `claims run`

### Task 7: Runner-adapter contract, stub adapters, `claims run`

**Files:** Modify `scripts/doc-tools.sh` and `scripts/test-spec-claims.sh`.

**Interfaces:**
- Contract (§D, verbatim):
  - `<adapter> list [<file>…]` → JSON lines `{"id", "node", "file", "in_gate": bool, "subject_imports_ok": bool, "when": {…}|null}`.
  - `<adapter> run --root <dir> <node>…` → JSON lines `{"node", "outcome": "pass"|"assert-fail"|"error"|"not-found"|"indeterminate", "reason"}`.
  - `<adapter> edited-bound-tests --staged | <range>` → claim ids.
  - Log adapter: `<adapter> run <claim-id>` → `{"outcome": "pass"|"fail"|"indeterminate", "evidence"}`.
- Config: `runners.<name> = {"adapter": "<repo path>", "paths": ["<prefix-or-glob>"…]}`, `log_adapter: "<repo path>"|null`.
- Produces:
  - `_claims_adapter_call <out-file> <adapter-path> <args…>` runs `"$_CL_ROOT/<adapter>" args` from the repo root and returns its rc. A missing or non-executable adapter returns 126 without running anything.
  - `_claims_parse_run <out-file> <requested-nodes-file>` prints one JSONL row per requested node. A missing node, a malformed line, an unknown outcome, any non-JSON stdout line or a non-zero adapter rc gives `{"node","outcome":"indeterminate","reason":"adapter-exit-<rc>"|"malformed-adapter-output"}`.
  - jq def `claims_expect(status; outcome)` → `{"verdict": "ok"|"finding"|"indeterminate", "message"}`:

    | status | pass | assert-fail | error | not-found | indeterminate |
    |---|---|---|---|---|---|
    | built, gated | ok | finding | finding | finding | indeterminate |
    | diverged | finding `passes: promote` | ok | finding `error is not an expected red` | finding | indeterminate |
    | unbuilt | finding `passes: promote` | ok | ok | ok | indeterminate |

    An `unbuilt` claim with `test: null` is not run: `ok`, message `no check yet`.
  - `claims run` selection: `--claims <id>…` (one or more values; commas are also split) | `--planes-of <range>` (every claim of each runner with a `paths` entry matching a path in `git diff -z --name-only --no-renames <range>`) | `--all`. Claims that are `retired`, have `frozen_at` set or are `judge` are listed in `results` as `skipped` with a reason. `log` claims run only with `--scheduled`. `--judge-sample <n>` adds `judge_sample`: n judge claim ids, sorted by id, starting at index `(ISO week from date +%V) mod count`. One `run` call per runner, with nodes passed as separate arguments. Each result row: `{"claim","status","node","outcome","verdict","message"}`.
- Stub runner (test fixture, written by `stub_runner` into `tools/claims/runner`, `#!/bin/sh`, mode 755):
  - `list` cats `tools/claims/list.jsonl`.
  - `run` reads `tools/claims/checks` (tab-separated `node file needle`) and, for each node argument, prints `pass` if `<root>/<file>` contains `needle` (`grep -F`), `assert-fail` if the file exists without it, and `error` if the file is missing. A node absent from `checks` gives `not-found`. A node listed in `tools/claims/force` (`node outcome [reason]`) prints that outcome instead.
  - `STUB_EXIT=<n>` makes it exit n after printing.
  - `edited-bound-tests` cats `tools/claims/edited`.
  - Every call appends `<subcommand> <args, one per line>` and then whatever it read from stdin (`cat`) to `$STUB_LOG`. That is a `harness_mktemp` file outside the work tree (Global Constraints), so the log never dirties the fixture.
  
  The stub files are committed with the fixture. A test that edits `force`, `checks` or `edited` before a `promote`/`gate` commits the edit first. Config `runners.stub = {"adapter":"tools/claims/runner","paths":["src/","tests/"]}`.
- `_claims_adapter_call` runs the adapter with `</dev/null 9>&-` (Global Constraints → Stdin). Closing fd 9, the verdict fd (Task 1), keeps an adapter, or a long-lived child it backgrounds, from holding the caller's captured stdout open. Otherwise a hook's `$(doc-tools.sh claims …)` would block until that grandchild exited. The config adapter (`_claims_recorded`, Task 21) and the log adapter go through `_claims_adapter_call` too, so the same redirections apply to every adapter.

- [ ] **Step 1: Write the failing tests** (`claims_fixture` + `stub_runner`; the claim gets `test: {runner: stub, node: "tests/test_token.py::test_ttl"}` and a `checks` line `tests/test_token.py::test_ttl	src/auth/token.py	TTL_SECONDS = 900`):

  | Test | Setup | Expect |
  |---|---|---|
  | `test_run_built_pass_exit_0` | status built (+ a verdict file) | `run --all` rc 0, verdict ok |
  | `test_run_built_assert_fail_exit_1` | built; source → 1800 | rc 1 |
  | `test_run_diverged_assert_fail_expected_exit_0` | diverged (+ tracker, ruling); source → 1800 | rc 0 |
  | `test_run_diverged_pass_is_finding_promote` | diverged; source 900 | rc 1, message `promote` |
  | `test_run_diverged_error_is_finding` | diverged; delete the subject file | rc 1, message `error is not an expected red` |
  | `test_run_unbuilt_any_failure_ok` | unbuilt; force `error` | rc 0 |
  | `test_run_unbuilt_pass_is_finding` | unbuilt; source 900 | rc 1 |
  | `test_run_unbuilt_no_check_yet` | unbuilt, `test` null | rc 0, message `no check yet` |
  | `test_run_indeterminate_exit_2` | force `indeterminate env-missing` | rc 2, `.indeterminate[0].reason == "env-missing"` |
  | `test_run_adapter_nonzero_all_indeterminate` | two claims; `STUB_EXIT=3` | rc 2, both indeterminate `adapter-exit-3` |
  | `test_run_precedence_finding_beats_indeterminate` | one claim red, one forced indeterminate | rc 1 |
  | `test_run_adapter_malformed_json_indeterminate` | force file emits `oops` on stdout before the JSON | rc 2, `malformed-adapter-output` |
  | `test_run_frozen_skipped` | `frozen_at` set | rc 0, result `skipped` `frozen`; the adapter was not called (`$STUB_LOG` is empty) |
  | `test_run_planes_of_selects_runner_by_paths` | a second runner `docs` with paths `docs/`; commit a change under `src/` | `--planes-of HEAD~1..HEAD` runs only stub claims |
  | `test_run_log_claims_only_scheduled` | a `log` claim with a stub log adapter | without `--scheduled` it is skipped; with it, it runs |
  | `test_run_judge_sample_rotates` | three judge claims | `--judge-sample 1` returns one id, equal to the index computed from `date +%V` in the test |
  | `test_run_node_with_spaces` | node `tests/a b.py::t`, file `src/a b.py` | the adapter receives one argument (`$STUB_LOG` shows it intact); rc 0 |
  | `test_adapter_child_does_not_hold_stdout` | stub `run` with `STUB_BG=1` starts `sleep 30 >/dev/null 2>&1 &` (inheriting every other fd, fd 9 included unless closed), writes its pid to `$STUB_LOG.bgpid`, and returns at once | `out=$("$DOC_TOOLS" claims run --all 2>/dev/null)` (a plain `$(…)` pipe capture, as a hook does, not the `cl` helper) returns in under 10 s, measured with `SECONDS`; then the test kills the pid from `$STUB_LOG.bgpid`. The same assertion holds for a stub log adapter with `STUB_BG=1` under `run --all --scheduled` |
  | `test_adapter_stdin_is_dev_null` | `printf 'ref-line\n' \| cl run --all` | `$STUB_LOG` records no stdin bytes (the adapter could not eat a hook's ref lines) |
- [ ] **Step 2: Run the suite.** Expected: FAIL.
- [ ] **Step 3: Implement.** Bash 3.2: pass nodes as a bash indexed array, expanded as `${nodes[@]+"${nodes[@]}"}` (it may be empty under `set -u`), collected by a `while IFS= read -r` loop over a jq `-r` list. No associative arrays: join results to claims in jq by node.
- [ ] **Step 4: Run the suite.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(claims): runner adapters and claims run` (with the self-install refresh).

### Task 8: V3 binding

**Files:** Modify `scripts/doc-tools.sh` and `scripts/test-spec-claims.sh`.

**Interfaces:**
- Consumes `_claims_adapter_call` (Task 7).
- Rules: for each touched `test` claim with a non-null `test`, call `<adapter> list <file>`. The file is `test.file` if set, else the node's prefix before `::` when that is an existing path, else nothing (all files). One call per runner, with all files collected. Then:
  - finding when no list row has `id == claim.id and node == test.node` (`not bound`);
  - a bound row with `in_gate: false` (`outside the test gate`);
  - a bound row with `subject_imports_ok: false` (`imports its subject at module level`);
  - `built` (or `gated`) without `nonvacuity` or without `promotion`;
  - `nonvacuity.mutant.find` not occurring exactly once in the proposed `mutant.file`, counted with jq `split` (literal);
  - an adapter rc ≠ 0 → indeterminate for those claims.
  
  The `when:` comparisons are added in Task 21.

- [ ] **Step 1: Write the failing tests** (rc 1 with V3 unless noted): `test_v3_unbound_node` (list.jsonl empty); `test_v3_bound_passes` (rc 0); `test_v3_in_gate_false`; `test_v3_subject_imports_not_ok`; `test_v3_built_without_nonvacuity`; `test_v3_mutant_find_not_unique` (`find: "TTL"` and the file contains `TTL` twice); `test_v3_list_adapter_failure_indeterminate` (`STUB_EXIT=1` → rc 2).
- [ ] **Step 2: Run the suite.** Expected: FAIL.
- [ ] **Step 3: Implement V3** in `cmd_claims_validate`.
- [ ] **Step 4: Run the suite.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(claims): V3 test binding` (with the self-install refresh).

### Task 9: V4 lint (validate) and lint re-runs (run)

**Files:** Modify `scripts/doc-tools.sh` and `scripts/test-spec-claims.sh`.

**Interfaces:**
- Produces `_claims_lint_eval <pattern> <expect> <file>`, which prints `pass` or `fail`. With `expect: present`, pass iff `grep -Eq -- "$pattern" "$file"`; with `absent`, pass iff it does not match.
- V4: `selftest.violates` written to a scratch file must evaluate to `fail`, and `selftest.clean` to `pass`. Otherwise it is a finding (`vacuous pattern`). The concatenation of the proposed `lint.paths` files is evaluated: `built` expects pass, `diverged` expects fail, `unbuilt` either. A contradiction is a finding.
- `claims run` uses the same evaluation for `lint` claims and reports through `claims_expect` (pass → `pass`, fail → `assert-fail`).

- [ ] **Step 1: Write the failing tests:** `test_v4_selftest_violates_passes` (pattern `.*`); `test_v4_selftest_clean_fails`; `test_v4_pattern_contradicts_status` (built, but the pattern is absent from the paths); `test_v4_valid_lint_passes`; `test_run_lint_rerun` (built lint claim → rc 0; edit the source to violate → rc 1).
- [ ] **Step 2: Run the suite.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the suite.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(claims): V4 lint self-tests and lint runs` (with the self-install refresh).

### Task 10: V9 claim-bound test edits

**Files:** Modify `scripts/doc-tools.sh` and `scripts/test-spec-claims.sh`.

**Interfaces:** V9 calls `<adapter> edited-bound-tests` for each configured runner: with `--staged` under `validate --staged`, with `"$_CL_MB..HEAD"` under `validate --all` (skipped, with the base indeterminate row, when `_CL_MB` is empty), and with `<from>..HEAD` under `gate` (Task 16). Each id returned that is a known claim becomes a V9 finding, message `bound test edited: adjudicate (states still holds → gate --holds <id>, else a ruling)`. V9 is not in the default `blocking` list, so it is advisory in `validate`. Produces `_claims_v9 <arg>`, consumed by Task 16.

- [ ] **Step 1: Write the failing tests:** `test_v9_edited_bound_test_listed_advisory` (`edited` contains the id → `validate --staged` rc 0, `.advisories[].check == "V9"`); `test_v9_all_uses_merge_base_range` (`validate --all` → `$STUB_LOG` shows `edited-bound-tests <mb>..HEAD` with the fixture's merge-base sha); `test_v9_unknown_id_ignored`.
- [ ] **Step 2: Run the suite.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run all six suites under both interpreters.** Expected: no `FAIL:` line.
- [ ] **Step 5: Commit** `feat(claims): V9 bound-test edit listing` (with the self-install refresh).

---

## Chunk 3: `promote`, non-vacuity, the verdict store

### Task 11: `claims promote` with a mutant proof

**Files:** Modify `scripts/doc-tools.sh` (incl. `cleanup`) and `scripts/test-spec-claims.sh`.

**Interfaces:**
- Produces:
  - `_claims_worktree_add <rev>` sets `_CL_WT` to a new `git worktree add --detach "$_SCRATCH/wt.<n>" <rev>` and registers it. `cleanup` runs `git worktree remove --force` on each registered path, then `git worktree prune`.
  - `_claims_mutate <file> <find> <replace>` rewrites `<file>` through `jq -j -Rs --arg f --arg r 'split($f) | if length != 2 then error("find matches \(length - 1) times") else join($r) end'`. That is literal, exactly-once and glob-free. `-j` writes the result raw, with no added newline and no JSON quoting. Bash 3.2: never `${s/…/…}`.
  - Verdict file `<store>/<digest>.json`: canonical `jq -cS` bytes of `{"claim","states_sha256","test","nonvacuity","head","subject_oids":{<path>:<blob oid at head>},"green":"pass","red":"assert-fail","status_to":"built"|"gated"}`. `<digest>` is the sha256 hex of those bytes, also stored as `promotion.verdict_sha256`.
- `claims promote <id>`:
  1. Refuse with exit 2 `dirty-tree` (gate preconditions, clarifications).
  2. The claim must be `test`-enforced and have a `nonvacuity` proof (else exit 1, a finding), with status `unbuilt`, `diverged`, `gated`, or `built`/`gated` whose verdict check is not `ok` (`mismatch`, e.g. after a DOC-STALE amendment, or `missing` in a clone without the verdict; re-proving is always safe). A `built` claim whose verdict is `ok` is refused (exit 1 `already promoted`). A re-promotion runs steps 3–6 unchanged and replaces `promotion` with the new digest.
  3. Run the bound node at HEAD through the adapter with `--root "$_CL_ROOT"`: `pass` is required (else a finding `not green`; indeterminate → exit 2).
  4. Mutant: worktree at HEAD, `_claims_mutate`, run the node with `--root "$_CL_WT"`. The outcome must be `assert-fail`. `pass` → finding `mutant stays green`; `error`/`not-found` → finding `mutant error is not an assertion failure`.
  5. Store the verdict (`mkdir -p` the store), then write the sidecar atomically: `status` → `status_to`, `promotion` → `{"at": HEAD, "verdict_sha256": digest}`.
  6. Run `render` for that doc.
  
  The worktree is removed on every path, refusals included.

- [ ] **Step 1: Write the failing tests** (claim unbuilt with test bound, tracker, `nonvacuity.mutant = {file: "src/auth/token.py", find: "TTL_SECONDS = 900", replace: "TTL_SECONDS = 1800"}`, list.jsonl binding it; everything committed):

  | Test | Expect |
  |---|---|
  | `test_promote_mutant_assert_fail_promotes` | rc 0; sidecar status built, `promotion.verdict_sha256` = sha256 of the stored file; `validate --all` rc 0 |
  | `test_promote_mutant_stays_green_refused` | replace `TTL_SECONDS = 900 ` (still contains the needle) → rc 1 `mutant stays green`; sidecar unchanged |
  | `test_promote_mutant_error_refused` | `checks` points at a file the mutant deletes (force `error` under the worktree root) → rc 1 |
  | `test_promote_mutant_find_not_unique_refused` | rc 1 `matches 2 times` |
  | `test_promote_mutant_literal_safe` | file line `x = a*b[0]$\1` with `find` = that exact text → the mutation applies literally (assert the mutated content via the stub's `$STUB_LOG` record of the root) |
  | `test_promote_requires_green_first` | source at 1800 → rc 1 `not green` |
  | `test_promote_dirty_tree_exit_2` | an unstaged edit → rc 2 `dirty-tree` |
  | `test_promote_throwaway_worktree_removed` | `git worktree list` has 1 line after a success and after a refusal |
  | `test_promote_second_without_commit_refused` | two unbuilt claims; promote the first, then the second with no commit between → rc 2 `dirty-tree` (the first promote's sidecar and doc writes); the first claim's promotion is intact |
  | `test_promote_twice_with_commit_between` | the same, committing the first promote's sidecar + doc (the gate template's Step 2 sequence, Task 25) → the second promote rc 0 |
  | `test_promote_built_with_ok_verdict_refused` | promote, commit, promote again → rc 1 `already promoted` |
  | `test_repromote_after_doc_stale` | promote and commit; then commit a DOC-STALE amendment of the claim (new `states`, AMENDED block, `quote_occurrence`, ruling) → `validate --all` gives advisory `re-promote owed`; `promote <id>` → rc 0, a new `promotion.verdict_sha256` ≠ the old one, and the new verdict's `states_sha256` matches the new `states`; after a commit, `validate --all` → rc 0 with no `re-promote owed` |
- [ ] **Step 2: Run the suite.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the suite.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(claims): promote with mutant non-vacuity` (with the self-install refresh).

### Task 12: `observed_red` proofs

**Files:** Modify `scripts/doc-tools.sh` and `scripts/test-spec-claims.sh`.

**Interfaces:** For `nonvacuity.observed_red: <sha>`: worktree at HEAD; then, for each subject path, `git -C "$_CL_WT" checkout <sha> -- <path>` when `git cat-file -e <sha>:<path>` succeeds, else `rm -rf` of that path in the worktree. A path absent at `<sha>` is the test-first case, and a `checkout` of it would fail. The test stays at HEAD; the subject is the old one. Run the node; the outcome must be `assert-fail`. `<sha>` must be a commit (else a finding `observed_red is not a commit`).

- [ ] **Step 1: Write the failing tests:** `test_promote_observed_red_reverified` (commit 1 has 1800, commit 2 has 900; `observed_red` = commit 1 → rc 0, promoted); `test_promote_observed_red_passes_refused` (`observed_red` = a commit where the subject already had 900 → rc 1); `test_promote_observed_red_bad_sha` (rc 1); `test_promote_observed_red_subject_absent_at_sha` (subject `["src/auth/token.py","src/auth/helper.py"]`; `helper.py` was added after `<sha>`, where `token.py` had 1800 → the helper is removed in the worktree, not checked out; the run gives `assert-fail`, rc 0, promoted, and the worktree is gone).
- [ ] **Step 2: Run the suite.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the suite.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(claims): observed_red non-vacuity` (with the self-install refresh).

### Task 13: Verdict-store round trip, shared store, `--reverify`

**Files:** Modify `scripts/doc-tools.sh` and `scripts/test-spec-claims.sh`.

**Interfaces:** `claims promote --reverify (<id>…|--all)` re-runs steps 3–4 of Task 11 for each `built`/`gated` claim with a promotion. It writes a fresh verdict file to the store and never touches the sidecar. A failure is a finding naming the claim. It reports `results: [{"claim","verdict"}]`.

- [ ] **Step 1: Write the failing tests:** `test_verdict_round_trip_v6_accepts` (promote, then edit `states` with no ruling → V6 finding *and* `mismatch`); `test_verdict_store_shared_across_worktrees` (promote in the main checkout; `validate --all` inside a `git worktree add` of the same repo shows no `unverifiable-here`); `test_verdict_store_fresh_clone_unverifiable` (`git clone` the fixture → `unverifiable-here` advisory, rc 0); `test_promote_reverify_all_no_sidecar_write` (sidecar hash unchanged, rc 0; after a committed change of the source to 1800, rc 1).
- [ ] **Step 2: Run the suite.** Expected: FAIL.
- [ ] **Step 3: Implement** `--reverify`.
- [ ] **Step 4: Run all six suites under both interpreters.** Expected: no `FAIL:` line.
- [ ] **Step 5: Commit** `feat(claims): verdict store re-verification` (with the self-install refresh).

---

## Chunk 4: Plans, `gate`, `attest`, `rulings`, V12, policy

### Task 14: Plan parser and V12 plan structure

**Files:** Modify `scripts/doc-tools.sh` and `scripts/test-spec-claims.sh`.

**Interfaces:**
- Produces:
  - `_claims_is_code_path <path>`: with `code_roots` empty, a path outside `docs/`; otherwise one matching a `code_roots` glob or prefix.
  - `_claims_plan_parse <plan-path> <source: staged|all|rev:<sha>>` prints JSON:
    `{"path","stem","completed":bool,"specs":[{"path","role"}],"chunks":[{"n","tasks":[{"title","kind","line","claims":[ids],"claims_none":<reason>|null,"files":[paths],"links":[paths]}]}]}`.
    
    Parsing is an awk pass emitting TSV records, with jq assembling the JSON. The task titles come from literal constants in doc-tools.sh, passed to awk with `-v` and compared as fixed strings (`index($0, t) == 1` on the title text), never re-typed as a regex: `_CL_GATE_TITLE_PREFIX='Claims gate (chunk '`, `_CL_FINAL_GATE_TITLE='Final claims gate'`, `_CL_SPEC_UPDATE_TITLE='Update governing specs for this chunk'`, `_CL_AMEND_TITLE_PREFIX='Land the spec amendment for '`, `_CL_FINALIZE_TITLE='Finalize all governing specs'`. Task 25 pins these lines. Recognised lines:
    - `^## Chunk ([0-9]+):`;
    - `^### Task [^:]+: (.*)$`, whose `kind` is `gate` when the title starts with `_CL_GATE_TITLE_PREFIX` (the chunk number is the digits before `)`), `final-gate` when it equals `_CL_FINAL_GATE_TITLE`, `spec-update` when it equals `_CL_SPEC_UPDATE_TITLE`, `amendment` when it starts with `_CL_AMEND_TITLE_PREFIX`, `finalize` when it equals `_CL_FINALIZE_TITLE`, and `impl` otherwise;
    - `^\*\*Claims:\*\* (.*)$`: a comma list of ids, or `none — <reason>`;
    - `^- (Create|Modify|Test): \`([^\`]+)\``, with a `:N-M` suffix stripped;
    - inside a `**Specs**` block, `^- (\S+) — (target|constraint|amends|infer)$`;
    - front matter `governing_specs:` items `- <path>[:role]`;
    - `completed` when a `**Status**: Completed` / `**Status:** Completed` line or front-matter `status: completed` (case-insensitive) is present;
    - `links`: every path-like token matching a `source_doc_patterns` prefix.
    
    Lines inside code fences are ignored. **Chunkless plans** (no `## Chunk` heading; spec-inject then treats each `### Task` as a chunk boundary) get `"chunked": false`. Each `impl` task opens chunk n (numbered in order), and the injected tasks that follow it (gate, spec-update, amendment, final gate, finalize) belong to that chunk.
- V12 applies to every plan matching config `plans` that is staged (`--staged`) or present (`--all`), has governing specs, **and** is either new (absent at `_CL_MB`) or gate-carrying (has at least one `gate` or `final-gate` task). A pre-claims plan edited later is exempt. Checks:
  - chunked plan: a chunk without a `gate` task before its `spec-update` task (`chunk N: no claims gate before the spec-update task`). Chunkless plan: each `spec-update` task's immediately preceding `### Task` must be the `gate` task for the same chunk (`chunk N: the claims gate must immediately precede the spec-update task`);
  - no `final-gate` task before the `finalize` task;
  - each `unbuilt` claim of a spec with role `target`/`infer` must be named on some `**Claims:**` line;
  - each `impl` task whose `files` include a code path needs a `**Claims:**` line;
  - an `impl` task with `claims_none` must not have `links`;
  - a **transition** to completed: `completed` is true in the proposed state and false (or the plan absent) at `_CL_MB`, while the plan's `final.json` is absent, has `result != "pass"`, or has a `head` that is not an ancestor-or-equal of HEAD, or while some commit in `git rev-list --no-merges HEAD ^<final.head> ^"$_CL_MB"` (non-merge commits after the final gate that the base does not already hold) touches a code path. Merge commits are excluded: a merge of the base into the branch carries trunk's code changes, which are not this plan's, and its own diff is not this branch's work. A plan already completed at `_CL_MB` is history and is never re-judged, under `--staged` or `--all`.
  
  A plan without governing specs is exempt.

- [ ] **Step 1: Write the failing tests.** The fixture plan is `docs/superpowers/plans/2026-01-01-ttl.md`, with two chunks, injected `**Specs**` lists naming `docs/specs/SPEC-AUTH-001-token.md — target`, gate tasks, a final gate and Claims lines. Each row removes or alters one element, stages, and runs `validate --staged`; each expects rc 1 with a V12 message except the first and last:

  | Test | Mutation | Message |
  |---|---|---|
  | `test_v12_well_formed_plan_passes` | none | rc 0 |
  | `test_v12_chunk_without_gate` | delete chunk 2's gate task | `chunk 2: no claims gate` |
  | `test_v12_gate_after_spec_update` | move chunk 1's gate after its spec-update task | `chunk 1: no claims gate before` |
  | `test_v12_no_final_gate` | delete the final gate | `final claims gate` |
  | `test_v12_unbuilt_target_claim_unnamed` | delete the `**Claims:**` line naming the claim | `SPEC-AUTH-001#token-ttl` |
  | `test_v12_code_task_without_claims_line` | an impl task modifying `src/auth/token.py` without Claims | `no **Claims:** line` |
  | `test_v12_claims_none_linking_issue` | `**Claims:** none — refactor` plus a link `docs/issues/token-ttl.md` | `promote the decision into a governing doc` |
  | `test_v12_completed_without_final_record` | add `**Status**: Completed` | `final gate` |
  | `test_v12_plan_without_governing_specs_exempt` | strip every `**Specs**` list | rc 0 |
  | `test_v12_legacy_plan_without_gates_exempt` | a plan committed on `main` before the branch point, with Specs lists and no gate tasks; edit one line on `feature` | rc 0 |
  | `test_v12_fenced_example_ignored` | a gate-task heading inside a code fence only | still `chunk 1: no claims gate` |
  | `test_v12_chunkless_plan_gate_immediately_precedes` | a plan with `### Task` headings only: impl, gate (chunk 1), spec-update, impl, spec-update, gate (chunk 2) | `chunk 2: the claims gate must immediately precede the spec-update task`; reorder chunk 2 → rc 0 |
  | `test_v12_completed_after_base_merge_ok` | after `attest --final` passes, merge `main` (which gained a code commit) into `feature`, then mark the plan Completed | rc 0 (the merge is excluded by `--no-merges`, and trunk's code commit is reachable from the new merge-base) |
  | `test_v12_historical_completed_plan_not_finding` | a plan committed `**Status**: Completed` on `main` before the branch point, with no `final.json`; `validate --all` on `feature` | rc 0 |
- [ ] **Step 2: Run the suite.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the suite.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(claims): plan parser and V12` (with the self-install refresh).

### Task 15: Direction policy in V6

**Files:** Modify `scripts/doc-tools.sh` and `scripts/test-spec-claims.sh`.

**Interfaces:** These extend V6's new-ruling checks for `DOC-STALE`/`RETIRE` rulings.
- With `policy.in_plan_ruling_requires_gate_record` true, a ruling whose `record` is a gate record is valid only when a plan matching `plans` has stem `<stem>` and lists the claim's doc with role `target`, `infer` (treated as `target`, as in V12's decomposition check) or `amends` (`_claims_plan_parse`). A gate record is `docs/spec-claims/gates/<stem>/chunk-<n>.json` **or** `docs/spec-claims/gates/<stem>/final.json`, and the record must exist (V6). Otherwise it is a finding `gate record of a plan that does not govern <doc>`.
- A ruling whose record is not a gate record is outside a plan. When `policy.doc_stale_outside_plan_requires` is a string, `by` must equal it; otherwise the finding is `outside a plan, DOC-STALE needs <principal>`.
- `outside_plan_presumption` is reported in the help and in `references/spec-claims.md` only. It has no mechanical effect.

- [ ] **Step 1: Write the failing tests:** `test_v6_in_plan_ruling_requires_gate_record_of_listing_plan` (record `docs/spec-claims/gates/2026-01-01-ttl/chunk-1.json` exists, but the plan lists the spec as `constraint` → finding; as `target` → rc 0); `test_v6_in_plan_ruling_infer_role_ok` (the plan lists the spec as `infer` → rc 0); `test_v6_final_json_is_a_gate_record` (the ruling's record is `docs/spec-claims/gates/2026-01-01-ttl/final.json`, target role → rc 0, and it is not treated as outside a plan when `doc_stale_outside_plan_requires` is set); `test_v6_outside_plan_requires_principal` (policy `"doc-owner"`, `by` `"someone"` → finding; `"doc-owner"` → rc 0); `test_v6_policy_off_allows_any_record` (flag false → rc 0).
- [ ] **Step 2: Run the suite.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the suite.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(claims): direction policy checks` (with the self-install refresh).

### Task 16: `claims gate`

**Files:** Modify `scripts/doc-tools.sh` and `scripts/test-spec-claims.sh`.

**Interfaces:**
- Produces `_claims_patch_ids <range>`, which prints a JSON array `[{"sha","patch_id"}]`: `git log -p --no-merges --format='commit %H' <range> | git patch-id --stable`, read into jq with `-R` (merges are skipped). Consumed by Task 17.
- `claims gate --plan <p> --chunk <n> [--from <rev>] [--holds <id>]… [--by <principal>]`:
  1. Dirty-tree refusal (exit 2).
  2. `from` is `--from`, else the `head` of `chunk-<n-1>.json`, else `_CL_MB`.
  3. Run, via the Task 7 core, the claims named on the chunk's `**Claims:**` lines plus `--planes-of <from>..HEAD`.
  4. Each named claim still `unbuilt` is red (`chunk was meant to build it: promote, rule, or defer`). Each run claim for which `_claims_repromote_owed <id> <from>` prints `owed` is red (`re-promote owed: run claims promote <id>`), even when its test passes, until a re-promotion replaces its verdict. `unverifiable-here` is an advisory, never red.
  5. V8, V8n (Task 18/19; until they land, the gate calls the V8/V8n hooks, which are no-ops) and V9 over `<from>..HEAD`. All are blocking here, because `gate` sets `_CL_ALL_BLOCKING=1` (Global Constraints → Blocking). A V9 id given in `--holds` is satisfied.
  6. Reconciliations follow the **record-inclusion rule** (jq def `claims_reconciliations($record_path)`, shared with Task 17's `final.json`). Over the sidecar changes between `from` and HEAD, on the claims in scope:
     - a new **ruling** is included only when its `record` equals this record's path (`docs/spec-claims/gates/<plan-stem>/chunk-<n>.json`);
     - every new **promotion** is included, and the record stores its `verdict_sha256`. Whether a promotion counts is decided by **digest match, never by the local store**: when attest cross-checks a sidecar promotion (Task 17), it counts when some record's reconciliation for that claim stores the same `verdict_sha256`. A missing verdict file never excludes a promotion; the gate adds only the advisory `unverifiable-here`. A *mismatching* verdict is not excluded either: it is the re-promote check's business (step 4), not the inclusion rule's;
     - a **status change** is included only when the same claim has an included ruling or an included promotion in this set;
     - plus one `{"claim","kind":"states-holds","by"}` per `--holds`.
     
     Every other ruling or status change in range is listed under `unrecorded` and is red (`silent reconciliation`). A ruling made during the chunk must cite this chunk's record to count; one citing an issue doc, or another record, does not. The rule reads only the sidecars and the records, so it gives the same answer in any clone.
  7. Write `docs/spec-claims/gates/<plan-stem>/chunk-<n>.json` atomically (`mkdir -p`), even when red:
     ```json
     {"schema":1,"plan":"<p>","chunk":<n>,"base":"<_CL_MB>","from":"<sha>","head":"<HEAD>","tree":"<HEAD^{tree}>",
      "commits":[{"sha","patch_id"}],"claims":["<id>"],"verdicts":[{"claim","status","outcome","verdict"}],
      "checks":{"V8":[…],"V8n":[…],"V9":[…]},"reconciliations":[{"claim","kind","ruling":{…}|null,"from_status","to_status","verdict_sha256":…|null}],
      "unrecorded":[{"claim","kind","ruling":{…}|null}],"result":"pass"|"red"|"indeterminate"}
     ```
  
  Exit 0 for pass, 1 for red, 2 for indeterminate.

- [ ] **Step 1: Write the failing tests** (plan fixture from Task 14, the stub runner, the claim bound with a mutant):
  - `test_gate_writes_record_with_patch_ids`: rc 0 after promote; the record exists; `.commits[].patch_id` equals `git patch-id --stable` computed in the test.
  - `test_gate_red_claim_exit_1_record_result_red`: source at 1800 → rc 1, `.result == "red"`.
  - `test_gate_unbuilt_named_claim_is_red`.
  - `test_gate_v8_v9_mandatory_blocking`: `edited` lists the id → rc 1 with V9 in `findings`; with `--holds <id>` → rc 0 and the reconciliation `states-holds`.
  - `test_gate_dirty_tree_refused_exit_2`.
  - `test_gate_from_defaults_previous_chunk_head`: chunk 2's `from` equals chunk 1's `head`.
  - `test_gate_records_reconciliations_from_sidecar_changes`: after a red `gate --chunk 1`, commit a DOC-STALE ruling (on a claim that is not built, so no re-promotion is owed) whose record is chunk-1.json, together with that record → the re-run `gate --chunk 1` lists it in `reconciliations`.
  - `test_gate_ruling_citing_other_record_is_silent`: during chunk 2, commit a DOC-STALE ruling whose `record` is an issue doc → `gate --chunk 2` rc 1, `.unrecorded[0].ruling.record == "docs/issues/token-ttl.md"`, finding `silent reconciliation`; the same ruling citing `chunk-1.json` (another record) → also unrecorded.
  - `test_gate_promotion_without_ruling_included`: a promote committed during the chunk with no ruling → in `reconciliations` with its `verdict_sha256`, rc 0.
  - `test_gate_promotion_missing_verdict_still_included`: as above, then delete the verdict file from the store before the gate → the promotion is still in `reconciliations` with its digest, advisory `unverifiable-here`, rc 0.
  - `test_gate_doc_stale_repromote_cycle`: the full chunk-gate cycle on a `built` claim.
    1. Change the source to 1800 and commit → `gate` rc 1 (red), `chunk-1.json` written.
    2. Commit, together with that `chunk-1.json`, a DOC-STALE amendment: the original sentence struck, an `AMENDED` block with the 30-minute sentence, the quote re-anchored, new `states`, and a ruling (reason, `record` = `chunk-1.json`). Update the stub `checks` needle and the mutant (`find` `TTL_SECONDS = 1800`, `replace` `TTL_SECONDS = 900`) in the same commit. `validate --staged` → rc 0 with advisory `re-promote owed`.
    3. `gate` → rc 1, `re-promote owed`.
    4. `promote <id>` → rc 0; commit.
    5. `gate` → rc 0. `reconciliations` holds the ruling (record = chunk-1.json) and the new promotion; `unrecorded == []`.
  - `test_gate_indeterminate_exit_2`.
- [ ] **Step 2: Run the suite.** Expected: FAIL.
- [ ] **Step 3: Implement.** Bash 3.2: no associative arrays; diff the sidecars at two revisions in one jq pass.
- [ ] **Step 4: Run the suite.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(claims): chunk gate records` (with the self-install refresh).

### Task 17: `claims attest` and `claims rulings`

**Files:** Modify `scripts/doc-tools.sh` and `scripts/test-spec-claims.sh`.

**Interfaces:**
- `claims rulings --range <a>..<b> [--format json|markdown]`: for every DOC-STALE/RETIRE ruling present at `<b>` and absent at `<a>`, the row is `{"claim","doc","direction","by","date","reason","approved":{"quote","states"} (at a; null for a new claim),"new":{"quote","states"} (at b)}`. Markdown: a heading `## Spec amendments (N)`, then per row `### <claim> — <direction>`, `**Approved:** <states>`, `**New:** <states>`, `**Reason:** <reason>`.
- `claims attest --plan <p> [--final] [--deep]`:
  1. Every chunk of the plan that has a `gate` task needs `chunk-<n>.json` (else a finding `chunk <n>: no gate record`). Each record's commits are matched by `patch_id` against `_claims_patch_ids "$_CL_MB..HEAD"` (a jq join, no `sort`/`join` needed). A record with any unmatched commit is marked `"rebased": "re-verified"`; it is covered by step 2, not a finding.
  2. Run every claim named by the plan at HEAD: `built`/`gated` must pass; `diverged` needs its ruling and tracker (V5) and an `assert-fail`. A named claim still `unbuilt` is a finding `named claim still unbuilt at the final gate` (consistent with R5). The only exits from that are promote, rule, or defer as `diverged`. A named claim for which `_claims_repromote_owed <id> "$_CL_MB"` prints `owed` is a finding `re-promote owed: run claims promote <id>`, even when its test passes. `unverifiable-here` is an advisory only. In a clone without the verdict store (CI), the answer comes from commit order (Task 5), so a plan that converged locally passes there.
  3. Cross-check, scoped to the plan: claims the plan names, plus claims of docs the plan governs (its Specs lists / `governing_specs:`). Every ruling, promotion and status change on those claims in the sidecars over `_CL_MB..HEAD` must appear in the `reconciliations` of some chunk record **or of `final.json`**, else a finding `silent reconciliation`. A ruling matches by JSON equality. A promotion matches when a reconciliation for that claim stores the same `verdict_sha256`; the local verdict store is never consulted here. A status change matches its record's entry. `final.json`'s `reconciliations` are rebuilt on each `--final` run by the **record-inclusion rule** (Task 16, `claims_reconciliations($record_path)` with `final.json`'s path), over the changes between the last chunk record's `head` and HEAD. A ruling made at the final gate counts only when its `record` is `final.json` (Task 15). A ruling citing anything else (an issue doc, an earlier chunk record) is never absorbed into `final.json`: it stays in `cross_check.unrecorded` and fails the attest. Every record reconciliation's ruling must still exist at HEAD (else `reconciliation reverted at HEAD`).
  4. Amendments: `claims rulings --range "$_CL_MB..HEAD"` rows go in `amendments`.
  5. `render --check` (V11).
  
  `--deep` re-runs each record's claims in a worktree at its `tree` (`git worktree add --detach … <tree-commit>`, where the commit is `head`). A missing object is indeterminate. `--final` writes `docs/spec-claims/gates/<stem>/final.json` = `{"schema":1,"plan","base","head","tree","from":"<last chunk record head>","chunks":[{"chunk","record","rebased":…|null}],"claims":[{"claim","status","verdict"}],"reconciliations":[{"claim","kind","ruling":{…}|null,"from_status","to_status","verdict_sha256":…|null}],"cross_check":{"unrecorded":[{"claim","kind","ruling":{…}|null}],"reverted":[]},"amendments":[…],"render_check":"ok"|"failed","result":"pass"|"fail"|"indeterminate"}`. It writes the file **even when the result is not pass**, so a ruling can cite it before the re-run (dirty-tree refusal as for the gate).

- [ ] **Step 1: Write the failing tests:**

  | Test | Expect |
  |---|---|
  | `test_attest_final_all_records_pass` | rc 0, `final.json` `.result == "pass"`; then `validate --staged` with the plan marked Completed → rc 0 |
  | `test_attest_missing_chunk_record` | rc 1 `chunk 2: no gate record` |
  | `test_attest_rebased_branch_matched_by_patch_id` | gate on `feature`; add an unrelated commit on `main`; `git rebase main` → rc 0, no `rebased` mark |
  | `test_attest_unmatched_commit_marked_rebased_reverified` | squash the chunk's two commits → `.chunks[0].rebased == "re-verified"`, rc 0 |
  | `test_attest_sidecar_ruling_with_no_gate_record` | commit a DOC-STALE ruling (record = an issue doc) after the last chunk gate, then run `attest --final` → rc 1 `silent reconciliation`; `final.json` is written with `result: fail`, its `reconciliations` do **not** contain the ruling, and `cross_check.unrecorded[0].ruling.record == "docs/issues/token-ttl.md"`. A second `--final` run gives the same rc 1 (the ruling is never absorbed) |
  | `test_attest_record_reconciliation_reverted_at_head` | revert the ruling commit → rc 1 |
  | `test_attest_named_claim_red_at_head` | source → 1800 after the gate → rc 1 |
  | `test_attest_named_claim_unbuilt_is_finding` | a named claim left `unbuilt` → rc 1 `named claim still unbuilt at the final gate` |
  | `test_attest_final_reconciliation_converges` | the Final claims gate sequence of Task 25, on a `built` claim.<br>1. Change the source to 1800 and commit after the last chunk gate → `--final` rc 1, and `final.json` is written with `result: fail`.<br>2. Commit, together with that `final.json`, a DOC-STALE amendment: the original sentence struck, an `AMENDED` block with the 30-minute sentence, the quote re-anchored, new `states`, a ruling whose `record` is `final.json`, and the stub needle and mutant updated. `validate --staged` → rc 0 with advisory `re-promote owed`.<br>3. `--final` → rc 1 `re-promote owed`.<br>4. `promote <id>` → rc 0; commit.<br>5. `--final` → rc 0. `final.json`'s `reconciliations` holds the ruling and the new promotion, and `cross_check.unrecorded == []` |
  | `test_attest_final_fresh_clone_passes_converged_plan` | after the converges sequence (local store populated, `final.json` committed with `result: pass`), make a fresh clone with an empty verdict store (helper `fresh_clone`: `git clone -q -b feature "$TEST_DIR" "$c"`, `git -C "$c" branch -q main origin/main`, then `cd "$c"`). `attest --plan … --final` there → rc 0. Promotions match by stored digest, no `silent reconciliation`; `unverifiable-here` advisories only |
  | `test_attest_fresh_clone_repromoted_not_flagged` | the same clone: no `re-promote owed` finding or advisory for the amended, re-promoted claim (the DOC-STALE commit is an ancestor of `promotion.at`) |
  | `test_attest_fresh_clone_unrepromoted_flagged_by_commit_order` | locally: a `built` claim, then a committed DOC-STALE amendment with its record and **no** re-promotion. In a fresh clone, `attest --final` → rc 1 `re-promote owed` (the ruling's introducing commit is not an ancestor of `promotion.at`). Rewriting `promotion.at` in that clone to a sha that does not exist (committed there, because attest needs a clean tree), then `attest --plan …` without `--final` → advisory `unverifiable-here`, no `re-promote owed` finding |
  | `test_attest_unrelated_ruling_not_attributed` | plan A governs `SPEC-AUTH-001` only. On `feature`, a DOC-STALE ruling (record = an issue doc) on a claim of `ADR-007`, which A does not govern. `attest --plan A` → no `silent reconciliation` finding. The CI side, where `claims-check.sh pr` does not attest an unchanged old plan at all, is Task 28's `test_claims_check_pr_attests_only_plans_changed_in_range` |
  | `test_attest_deep_reruns_recorded_tree` | `--deep` runs the stub with `--root` under a worktree (`$STUB_LOG` shows the worktree root) |
  | `test_attest_render_check_fails` | hand-edit the status block → rc 1 V11 |
  | `test_rulings_amendment_batch_json_and_markdown` | one DOC-STALE ruling → JSON row with approved/new/reason; markdown has `## Spec amendments (1)` |
- [ ] **Step 2: Run the suite.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run all six suites under both interpreters.** Expected: no `FAIL:` line.
- [ ] **Step 5: Commit** `feat(claims): attest, final gate and the amendment batch` (with the self-install refresh).

---

## Chunk 5: Structural coverage

### Task 18: V8 normative coverage

**Files:** Modify `scripts/doc-tools.sh` and `scripts/test-spec-claims.sh`.

**Interfaces:**
- Produces:
  - `_claims_sections <doc-file>` (awk, fence-aware) prints TSV `line<TAB>class` for every line, where class is `normative|descriptive|openq|other`. It tracks the innermost heading. A heading resets the class for its level and everything below it. `normative` applies to an ADR doc (DOC-ID `ADR-*`) under `Decision`, and to any doc under a heading matching the default list (clarifications) or a `normative_headings` entry (case-insensitive ERE on the heading text). `openq` applies under `Open questions`. `descriptive` applies under `Implementation Notes`, a `descriptive_headings` entry, or a heading followed (before any other content line) by `<!-- spec-claims:descriptive -->`. Lines between the status markers are `other`.
  - `_claims_added_lines <doc> <diff-args…>` parses `git diff -U0 --no-color <diff-args> -- <doc>` hunk headers `@@ -a,b +c,d @@` (awk) and prints the added line numbers in the new file.
- V8, `--staged` (or a gate range): for each governing doc with added lines, an added non-blank `normative` line is uncovered when no claim of that doc has an occurrence (`claims_occ` with `quote_occurrence`) whose span hits that line (`claims_lines_hit`). For an `openq` table row, the column whose header matches `resolved|resolution|answer|decision` is examined: the row is covered when some normalised quote is a substring of the normalised cell, or the cell of the quote. Each uncovered line is a finding `<doc>:<line>: normative text no claim covers`. `--all` runs over every line of docs that have a sidecar.

- [ ] **Step 1: Write the failing tests** (`validate --staged`; V8 is advisory, so assert on `.advisories[] | select(.check=="V8")`):

  | Test | Staged change | Expect |
  |---|---|---|
  | `test_v8_adr_decision_hunk_uncovered` | new `docs/adr/ADR-007-cache.md` with a `## Decision` line and an empty sidecar | one V8 advisory naming the line |
  | `test_v8_covered_by_claim_quote` | add a Requirements line plus a claim quoting it | none |
  | `test_v8_wrapped_quote_covers_both_lines` | the quote wraps over two added lines | none |
  | `test_v8_spec_requirements_heading` | an added Requirements line without a claim | one |
  | `test_v8_design_default_normative` | no config; an uncovered line added under the spec template's `## Design` | one |
  | `test_v8_host_heading` | `normative_headings: ["^Contract$"]`, an added line under `## Contract` | one |
  | `test_v8_open_questions_resolved_column` | a new row with a non-empty Resolved cell | one; with a claim quoting the cell → none |
  | `test_v8_non_normative_section_ignored` | an added Summary line | none |
  | `test_v8_status_block_excluded` | render, then stage | none |
  | `test_v8_heading_inside_fence_ignored` | a fenced `## Requirements` under Summary | none |
  | `test_v8_unicode_line_coverage` | a covered line after lines with `é`/`—` | none |
  | `test_v8_blocking_when_configured` | `blocking` includes V8 → rc 1 | |
- [ ] **Step 2: Run the suite.** Expected: FAIL.
- [ ] **Step 3: Implement**, and wire it into the gate's V8 hook.
- [ ] **Step 4: Run the suite.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(claims): V8 structural coverage` (with the self-install refresh).

### Task 19: V8n descriptive conformance lines

**Files:** Modify `scripts/doc-tools.sh` and `scripts/test-spec-claims.sh`.

**Interfaces:** On added `descriptive` lines (`--staged`, gate range) or all of them (`--all`), a line matching (case-insensitively) `as specified|conforms|aligned with|matches §|implemented per` is a finding. It is exempt if it contains `(unverified)`, or contains a token matching `[A-Z][A-Z0-9-]*#[a-z0-9][a-z0-9-]*` that is a known claim id. An unknown id is a finding `cites unknown claim`.

- [ ] **Step 1: Write the failing tests:** `test_v8n_conformance_without_id` (an added Implementation Notes line `Token expiry as specified.` → V8n advisory); `test_v8n_with_claim_id_ok` (`… as specified (SPEC-AUTH-001#token-ttl).`); `test_v8n_unverified_ok`; `test_v8n_descriptive_marker_section` (`## Build log` followed by `<!-- spec-claims:descriptive -->`, with a conformance line → V8n); `test_v8n_unknown_claim_id`; `test_v8n_pointer_without_trigger_ignored` (`See §Requirements.`).
- [ ] **Step 2: Run the suite.** Expected: FAIL.
- [ ] **Step 3: Implement**, and wire it into the gate's V8n hook.
- [ ] **Step 4: Run the suite.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(claims): V8n descriptive conformance` (with the self-install refresh).

### Task 20: V7 restates sweep

**Files:** Modify `scripts/doc-tools.sh` and `scripts/test-spec-claims.sh`.

**Interfaces:** For each claim A with `restates: [B…]`: when B's `states` differs between `_CL_MB` and the proposed state and A has no new ruling, V7 is a finding (advisory by default) `restates <B>, whose states changed`. An id in `restates` that is not a known claim is a V1 finding (added to `claims_v1`).

- [ ] **Step 1: Write the failing tests:** `test_v7_restates_sweep` (ADR-007's claim restates the spec claim; the spec claim's `states` changes with a ruling → V7 advisory on ADR-007's claim); `test_v7_sibling_ruled_ok` (ADR claim also gets a ruling → none); `test_v1_restates_unknown_id`.
- [ ] **Step 2: Run the suite.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run all six suites under both interpreters.** Expected: no `FAIL:` line.
- [ ] **Step 5: Commit** `feat(claims): V7 restates sweep` (with the self-install refresh).

---

## Chunk 6: The §B.1 configuration extension, and replay fixtures

### Task 21: Config adapter, `when:`, `gated`, configuration-faithful checks

**Files:** Modify `scripts/doc-tools.sh` and `scripts/test-spec-claims.sh`.

**Interfaces:**
- Contract (§D, verbatim):
  - `<adapter> surfaces` → the files that carry production configuration;
  - `<adapter> recorded [--rev <rev> | --staged] [--override KEY=VALUE]` → JSON `{key: {"recorded": …, "default": …}}`;
  - `<adapter> readers <path>…` → the keys read by code in those paths.
  
  Config: `config_adapter: "<repo path>"`. Off when it is null.
- Produces `_claims_b1_on` (0 when on) and `_claims_recorded <args…>`, which writes `$_SCRATCH/cl-recorded.json` (adapter failure → indeterminate). Every config-adapter call (`surfaces`, `recorded`, `readers`) goes through `_claims_adapter_call` (Task 7), so it runs with `</dev/null 9>&-`. jq def `claims_when_ok($rec)`: every `when` key has `$rec[k].recorded == when[k]`.
- Behaviour:
  - Off: a claim with `when` or status `gated` is a V1 finding `configuration extension is off`, and a runner `list` row's `when` is ignored.
  - On: V1 checks that `when` keys are keys of `recorded --staged` (or the working tree under `--all`).
  - V3 (on): for each claim, the keys from `readers <subject…>` whose `recorded != default` must appear in `when` with the recorded value, unless `config_independent` is a non-empty string (else `configuration-faithful: pin <k>=<v> in when or declare config_independent`). The bound `list` row's `when` must contain every claim `when` pair (else `test does not establish when <k>`). V3 extends to `gated`, like `built`.
  - V5: `gated` needs an open tracker (`_claims_tracker_open`).
  - A `built` claim with `when` not satisfied by the recorded configuration is a V3 finding `built but recorded configuration does not satisfy when: gated`.
  - `claims_expect`: `gated` behaves like `built`.
  - Promote: `status_to` is `gated` when `claims_when_ok` fails against `recorded --rev HEAD`.
  - Render: `gated (when: K=V, …)`, keys sorted.
- Stub config adapter (`tools/claims/config`, `#!/bin/sh`):
  - `surfaces` prints `deploy/flags.json`;
  - `recorded` builds the JSON from `deploy/flags.json` (via `git show <rev>:` for `--rev`, `git show :` for `--staged`, otherwise the file) and `tools/claims/defaults.json`, applying `--override`;
  - `readers` prints the keys listed for each path in `tools/claims/readers` (`path<TAB>key`).

- [ ] **Step 1: Write the failing tests:** `test_v1_when_without_config_adapter`; `test_v1_gated_without_config_adapter`; `test_v1_when_unknown_key`; `test_v3_config_faithful_pin_required` (readers lists `token_ttl_minutes`, recorded 15 ≠ default 30, no `when` → V3); `test_v3_config_independent_accepted`; `test_v3_when_not_established_by_test` (list `when` null while the claim has `when`); `test_v5_gated_requires_tracker`; `test_built_unsatisfied_when_is_finding`; `test_run_gated_expects_pass`; `test_promote_writes_gated_when_recorded_unsatisfied`; `test_render_gated_names_condition` (row `gated (when: token_ttl_minutes=15)`); `test_extension_off_list_when_ignored`; `test_config_adapter_child_does_not_hold_stdout` (the stub config adapter with `STUB_BG=1` backgrounds `sleep 30` on `recorded`; `out=$("$DOC_TOOLS" claims validate --all 2>/dev/null)` returns in under 10 s, by `SECONDS`, because `_claims_recorded` calls through `_claims_adapter_call` with `9>&-`; then the test kills the sleeper).
- [ ] **Step 2: Run the suite.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the suite.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(claims): configuration-conditioned claims (off unless declared)` (with the self-install refresh).

### Task 22: V10 configuration re-classification and `validate --config`

**Files:** Modify `scripts/doc-tools.sh` and `scripts/test-spec-claims.sh`.

**Interfaces:** V10 runs only with B.1 on, when a staged path (`--staged`) is among the `surfaces`, or when `--config KEY=VALUE` (repeatable) is given. It compares `recorded --rev "$_CL_MB"` with `recorded --staged` (or, under `--config`, `recorded` with `--override` applied). For each claim whose `when` keys or `readers(subject)` keys include a changed key:
- `gated` now satisfied → finding `now satisfied: promote to built`;
- `built` no longer satisfied and no new ruling → finding `ruling owed`;
- `diverged` whose `when` is switched on → finding `switches on a diverged claim`.

V10 is in the default `blocking` list.

- [ ] **Step 1: Write the failing tests:** `test_v10_gated_now_satisfied_promote`; `test_v10_built_no_longer_satisfied_ruling_owed`; `test_v10_built_with_ruling_ok`; `test_v10_diverged_when_switched_on`; `test_validate_config_override` (`--config token_ttl_minutes=30` with nothing staged → `ruling owed`); `test_v10_unrelated_key_ignored`.
- [ ] **Step 2: Run the suite.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the suite.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(claims): V10 configuration re-classification` (with the self-install refresh).

### Task 23: Replay fixtures, the four drift shapes and the planted drifts

**Files:** Modify `scripts/test-spec-claims.sh` (tests only; any production fix they force goes in `scripts/doc-tools.sh` within this task).

**Interfaces:** Consumes every check above. Each replay names its check and its lifecycle point in its `echo` line.

- [ ] **Step 1: Write the replay tests:**

  | Test | Scenario | Caught by / at |
  |---|---|---|
  | `test_replay_unbuilt` | an ADR decision (claim `unbuilt`, tracker = the design doc) and a plan whose tasks never name it | V12 at plan commit (`validate --staged`); and `gate` red `chunk was meant to build it` once it is named and still unbuilt |
  | `test_replay_never_reconciled` | spec `states` and quote edited to match the code, no ruling | V6 at pre-commit |
  | `test_replay_ratified_deviation` | an impl task `**Claims:** none — swap approach` linking `docs/issues/…`, plus Implementation Notes `uses X as specified` | V12 at plan commit; V8n at the chunk gate |
  | `test_replay_parity_by_assertion` | host kind `parity` (`kinds: ["parity"]`), a claim "the control arm sends the shipped request", a stub check failing | `run` / `gate` red (exit 1) |
  | `test_planted_update_index_does_not_clear_claim` | threshold changed in the subject, then `doc-tools.sh update-index` on the spec | `claims run` still rc 1 (an index re-baseline never clears a claim) |
  | `test_planted_unbuilt_requirement_v8` | an unbuilt normative requirement added to a spec | V8 advisory at pre-commit; V8 blocking at the gate |
  | `test_planted_threshold_change_run_red` | threshold changed in a subject file | `run --planes-of` rc 1 |
  | `test_planted_deploy_config_v10` | a change to `deploy/flags.json` outside every `code_refs` disables the behaviour | V10 at pre-commit |
- [ ] **Step 2: Run the suite.** Expected: PASS. A failure here is a defect in an earlier task: fix it in `doc-tools.sh`, and add the case to that task's tests.
- [ ] **Step 3: Run all six suites under both interpreters.** Expected: no `FAIL:` line.
- [ ] **Step 4: Commit** `test(claims): replay fixtures for the drift shapes and planted drifts` (with the self-install refresh if doc-tools.sh changed).

---

## Chunk 7: Lifecycle integration (references, SKILL.md)

### Task 24: Spec Status Model R5 and the execute / post-execute / review phases

**Files:** Modify `references/spec-lifecycle-actions.md`, `references/output-templates.md` (Spec Compliance Report) and `scripts/test-spec-status-model.sh`.

**Interfaces:** Produces the exact phrases below. The test pins them, and Task 25, Task 26 and `references/spec-claims.md` cite them.
- In `### Rules`, after R4: `- **R5 — Claim-gated advancement.** **Claims-enabled projects only** (\`docs/spec-claims/\` exists): a target spec advances to \`Implemented\` only when every claim the plan names for it is \`built\` with a passing verdict at the final gate (\`claims attest --final\`); with the configuration extension, \`gated\` also qualifies. \`:amends\` specs remain exempt from \`Status\` writes but not from claim checks.`
- `### Evaluation order`: a new step between R4 and R2: `**R5** — claims enabled and the final gate does not show every named claim of this spec \`built\` (or \`gated\`) and passing → hold short of \`Implemented\` (R2 still applies).`
- Execute Phase:
  - add `**With claims enabled**, the plan's \`Claims gate (chunk N)\` task is the chunk's verifier: this phase reports its record's verdicts and does not judge drift by agent.`;
  - in the Aligned branch, add `It never calls \`update-index\` while a claim of that spec fails.`;
  - keep the Drifted branch's existing text byte for byte (the instructions for projects without claims) and append `**Claims-enabled projects:** rule the direction (**Direction protocol**, \`spec-lifecycle-protocol.md\`) before editing either side, and record the ruling in the sidecar.` (Design deviations: the replacement is conditional);
  - in the Amendment branch, add `With claims enabled an \`:amends\` spec's claims are still checked at the gate.`
- Post-Execute Mode: new step `0. **Claims verdict** (claims-enabled projects only): run \`$DOC_TOOLS claims attest --plan <plan> --final\`; exit 1 → FAIL; exit 2 → report "claims verdict owed", never PASS; include its amendment batch.` The PASS rule gains `AND (claims disabled OR \`claims attest --final\` exit 0)`.
- Review Mode: step `3c. **Claims** (claims-enabled projects only): \`$DOC_TOOLS claims run --planes-of <base>...HEAD\` and \`claims validate --all\`'s V9 items; a red claim is a **P1 Claim red** finding.` The severity list gains `**P1 Claim red**`.
- `references/output-templates.md` Spec Compliance Report gains a `### Claims verdict` block (`attest exit`, red claims, `rebased: re-verified` chunks, the amendment batch) marked "claims-enabled projects only".

- [ ] **Step 1: Write the failing pins** in a new `echo "--- spec claims: R5 and phases ---"` block of `test-spec-status-model.sh`: an `assert_contains` per quoted phrase above (one pin per phrase, the em-dash exact). The Drifted branch's current sentence is pinned unchanged: `assert_contains "$ACTIONS" "Flag for human review with a deviation note"`. Then `assert_contains "$ACTIONS" "Claims-enabled projects only"`, `assert_contains "$TEMPLATES" "### Claims verdict"`, and `assert_line_matches "$(_section "$ACTIONS" '### Evaluation order')" '\*\*R5\*\*'`. Existing pins must keep passing (`per the **Spec Status Model**`, `four **P3 informational** lines`).
- [ ] **Step 2: Run** `bash scripts/test-spec-status-model.sh`. Expected: FAIL on the new pins only.
- [ ] **Step 3: Edit the references** as specified.
- [ ] **Step 4: Run the suite.** Expected: PASS.
- [ ] **Step 5: Commit** `docs(spec-lifecycle): R5 and claim verdicts in execute/verify`.

### Task 25: spec-generate claim stubs and spec-inject gate tasks

**Files:** Modify `references/spec-lifecycle-actions.md` and `scripts/test-spec-status-model.sh`.

**Interfaces:**
- Produces the task-title strings that V12 (Task 14) parses. They must match byte for byte: `Claims gate (chunk {C})`, `Final claims gate`, `**Claims:**`.
- spec-generate gains step `6b. **Claim stubs** (claims-enabled projects only — \`docs/spec-claims/\` exists)`: for each requirement, decision, invariant or interface the spec states, write a stub into `docs/spec-claims/<DOC-ID>.json` (status `unbuilt`, `tracker` = the design doc path, `test: null`, `quote` verbatim from the generated normative text), then `$DOC_TOOLS claims render` and `$DOC_TOOLS claims validate --all`.
- Plan Phase gains:
  - step `1b. **Claims lines**`: each implementation task gets `**Claims:** <ids>` or `**Claims:** none — <reason>`; a task whose behaviour comes from an issue or design names no `none` — promote the decision into a governing doc first.
  - step `2b`: in each chunk, **before** its `Task N+1`, insert:
    ````markdown
    ### Task N+1g: Claims gate (chunk {C})

    **Run by the orchestrating agent, not a delegated implementer**: reconciliation may need a judge it dispatches.

    - [ ] **Step 1: Run the gate** — `$DOC_TOOLS claims gate --plan {plan-path} --chunk {C}`. Exit 0 → Step 4. Exit 1 → Step 2. Exit 2 → the gate could not run: fix the cause and re-run; never treat it as green.
    - [ ] **Step 2: Promote what this chunk built** — for each named claim still `unbuilt` whose test now passes, one at a time: `$DOC_TOOLS claims promote <id>`, then commit what it wrote (the claim's sidecar and doc) before the next promote. `promote` needs a clean tree.
    - [ ] **Step 3: Reconcile every red claim before the next chunk starts** (**Direction protocol**) — fix the code; or rule `DOC-STALE` (dated `AMENDED` block + new `states` + `quote_occurrence` when the block re-quotes the sentence + a ruling whose `record` is `docs/spec-claims/gates/{plan-stem}/chunk-{C}.json`); or defer as `diverged` (a `CODE-DIVERGES` ruling + an open tracker). Adjudicate each V9 item: `--holds <id>` when `states` still holds, else a ruling. Commit each ruling **together with** the current `chunk-{C}.json` (Step 1 wrote it, red), so the pre-commit check (`validate --staged`, V6) finds the record the ruling cites. A ruling citing any other record (an issue doc, an earlier chunk's record) does not count here and leaves the gate red (`silent reconciliation`). **A `DOC-STALE` on a claim that is already `built`/`gated`** changes its `states`, so the commit passes with the advisory `re-promote owed` and the gate stays red until you run `$DOC_TOOLS claims promote <id>` and commit what it wrote. The order is: DOC-STALE commit (with the record) → `promote` → commit → re-run Step 1.
    - [ ] **Step 4: Commit the record** — `git add docs/spec-claims/gates/{plan-stem}/chunk-{C}.json`. Task N+1's Implementation Notes cite this record's verdicts.
    ````
  - step `4b`: in the last chunk, before `Task N+2`, insert `### Task N+2g: Final claims gate` (run by the orchestrating agent). Its steps run `$DOC_TOOLS claims attest --plan {plan-path} --final` (it writes `final.json` even when red), and reconcile as in the chunk gate. A ruling made here cites `docs/spec-claims/gates/{plan-stem}/final.json` as its `record` and is committed together with that `final.json`; a ruling citing anything else is never absorbed and keeps the attest red. A DOC-STALE on a `built`/`gated` claim is followed by `$DOC_TOOLS claims promote <id>` and a commit, the same DOC-STALE commit → `promote` → commit sequence as the chunk gate. The steps then re-run `attest --final`, which records the ruling and the re-promotion in `final.json`'s `reconciliations`, until exit 0 (Task 17's `test_attest_final_reconciliation_converges`), commit `final.json`, and paste `$DOC_TOOLS claims rulings --range <merge-base>..HEAD --format markdown` into the PR description for the human who reviews docs.
  
  Each insertion is conditional, with the sentence `Inject these only when \`docs/spec-claims/\` exists; otherwise the plan is unchanged.` Task N+2 Step 1's target branch gains `subject to R5`.

- [ ] **Step 1: Write the failing pins:** `assert_contains` for `Claims gate (chunk {C})`, `Final claims gate`, `**Claims:** none — <reason>`, `Run by the orchestrating agent, not a delegated implementer`, `Inject these only when \`docs/spec-claims/\` exists; otherwise the plan is unchanged.`, `6b. **Claim stubs**`, `DOC-STALE commit (with the record) → \`promote\` → commit → re-run Step 1`. Cross-file pins on the literal constants (Task 14), so the reference and the parser cannot drift: `grep -F "_CL_GATE_TITLE_PREFIX='Claims gate (chunk '" scripts/doc-tools.sh` and `grep -F "_CL_FINAL_GATE_TITLE='Final claims gate'" scripts/doc-tools.sh` each match exactly one line, and the reference contains each constant's value. The order (gate before spec-update) is **not** pinned on the reference's text order, because the reference describes the spec-update template (step 2) before the gate insertion (step 2b). It is pinned on an injected plan: `test_v12_reference_template_passes` in `test-spec-claims.sh` extracts the gate, spec-update, final-gate and finalize task blocks from the reference's fences, assembles a two-chunk fixture plan the way the injection steps describe (impl → gate → spec-update per chunk; final gate before finalize), stages it, and asserts `claims validate --staged` reports no V12 finding.
- [ ] **Step 2: Run** `bash scripts/test-spec-status-model.sh` and `bash scripts/test-spec-claims.sh`. Expected: FAIL on the new cases.
- [ ] **Step 3: Edit the reference.**
- [ ] **Step 4: Run both suites.** Expected: PASS.
- [ ] **Step 5: Commit** `docs(spec-lifecycle): claim stubs and injected claims gates`.

### Task 26: Direction protocol, integration patterns, SKILL.md, update-index wording

**Files:** Modify `references/spec-lifecycle-protocol.md`, `references/integration-patterns.md`, `skills/doc-superpowers/SKILL.md`, `scripts/doc-tools.sh` (help prose only), and the remaining "attests" prose, located 2026-10-10:
- `references/doc-spec.md` (schema row `docs.<path>.last_verified`, "the one verb that attests"; the `stale → current` transition line, "the attestation");
- `README.md` (Claude hooks paragraph, "only a reviewer attests a doc");
- `docs/codebase-guide.md` (:123 "the one verb that attests", :230 "to attest them", :265 "attests");
- `docs/conventions.md` (:341, :404);
- `docs/workflows/doc-superpowers.md` (:152, :362, :745);
- `docs/architecture/system-overview.md` (:114, :160 "Hooks report, never attest").

Also `scripts/test-spec-status-model.sh` and `scripts/test-doc-tools.sh` (only pins that quote changed prose). Run `rg -n "attest|Who may" scripts/test-*.sh` first, then `rg -n "attest" references README.md docs skills --glob '!docs/superpowers/**' --glob '!docs/archive/**' --glob '!docs/plans/**' --glob '!docs/issues/**'` to find any site added since. Plans, issues, archives and design records are history and are not reworded. The new verb name `claims attest` is not "attest" prose.

**Interfaces:**
- `spec-lifecycle-protocol.md`:
  - The Lifecycle Overview gains a column `With claims enabled` (the §E table's right column, condensed).
  - A new section `## Direction protocol` holds the §F table, the sentence `When a doc and the code disagree, neither side is edited until the direction is ruled and recorded.`, the "Deviation is expected; an unreconciled deviation is the failure" paragraph, the three policy keys with their defaults and the `by` caveat. Its scope sentence is `This protocol applies to claims-enabled projects (\`docs/spec-claims/\` exists). Without claims, the wiring below is unchanged, and the three directions are offered as a recommended framing for the question put to the user.`
  - The wiring block keeps `If deviation flags returned → surface to user` and `If FAIL → surface report to user, let them decide` **byte for byte**. Each gains a following line: `Claims-enabled: a red claim or a flagged deviation → rule the direction (Direction protocol) before editing either side` and `Claims-enabled: surface the report and its amendment batch; every unreconciled deviation needs a ruling (Direction protocol)` (Design deviations: the replacement is conditional).
  - Host Project Assumptions gains rows for `docs/spec-claims/` (created by the host, optional) and the runner adapters.
- `integration-patterns.md`: a `## Claims-enabled wrappers` section listing where each gate runs (the plan tasks), and stating that a wrapper that skips one is detected by `claims attest --final`.
- `SKILL.md`:
  - the tool table gains a `doc-tools.sh claims <verb>` row;
  - the required-references table gains `references/spec-claims.md` ("**REQUIRED** when `docs/spec-claims/` exists");
  - the Spec Lifecycle Actions section gains one bullet on gates, R5 and the direction protocol;
  - row 147 becomes: `**Records a baseline reset, never a verification**: records each code ref's content as the working tree holds it now and stamps \`last_verified\`; run it only for a doc you read against its code. A verification verdict comes only from claims (\`claims run\` / \`attest\`)`;
  - the routing row `Doc edited and read against its code` keeps that prefix and the `update-index` cell, with "the one verb that attests" changed to "a baseline reset";
  - "Who may attest." becomes "Who may re-baseline.".
- `doc-tools.sh` help: the `update-index` description's first sentence becomes `Re-baseline indexed docs (a baseline reset, never a verification — claims carry verification): …`, and `Stored state (who may attest):` becomes `Stored state (who may re-baseline):`. Output tokens are unchanged (Design deviations).
- The listed docs: each "attests / attestation / the one verb that attests" phrase about `update-index`, `last_verified` or hooks becomes the matching "re-baselines / baseline reset" phrase. The facts stay: only `update-index` writes `last_verified`, run it only for a doc you read against its code, and no hook runs it.

- [ ] **Step 1: Write the failing pins:** `assert_contains "$PROTOCOL" "## Direction protocol"`; the "neither side is edited" sentence; each of `CODE-DIVERGES`, `DOC-STALE`, `RETIRE`, `in_plan_ruling_requires_gate_record`, `outside_plan_presumption`, `doc_stale_outside_plan_requires`; `assert_contains "$PROTOCOL" "If deviation flags returned → surface to user"` and `assert_contains "$PROTOCOL" "If FAIL → surface report to user, let them decide"` (unchanged for projects without claims); `assert_contains "$PROTOCOL" "Claims-enabled: a red claim or a flagged deviation → rule the direction"`; `assert_contains "$SKILLMD" "Records a baseline reset, never a verification"`; `assert_not_contains "$SKILLMD" "The one verb that attests a doc was checked against its code"`; `assert_contains "$INTEGRATION" "## Claims-enabled wrappers"`; `assert_contains "$SKILLMD" "references/spec-claims.md"`. For the help pin, add to the suite's setup (the suite has no doc-tools wrapper yet) `DOC_TOOLS_SHIM="$(bash_bin_shim "$REPO_ROOT/scripts/doc-tools.sh")"`, then `assert_contains "$("$DOC_TOOLS_SHIM" update-index --help)" "never a verification"`. A sweep pin: `assert_eq "" "$(grep -n 'the one verb that attests\|only verb that attests' "$REPO_ROOT"/references/doc-spec.md "$REPO_ROOT"/docs/codebase-guide.md "$REPO_ROOT"/docs/conventions.md "$REPO_ROOT"/docs/workflows/doc-superpowers.md "$REPO_ROOT"/docs/architecture/system-overview.md "$REPO_ROOT"/skills/doc-superpowers/SKILL.md || true)" "no doc still calls update-index the verb that attests"`. Existing pins (`routing: edited and verified → update-index`, the three `--plan` wiring lines per file) must keep passing.
- [ ] **Step 2: Run** `bash scripts/test-spec-status-model.sh`. Expected: FAIL on the new pins only.
- [ ] **Step 3: Edit.**
- [ ] **Step 4: Run all six suites under both interpreters.** Expected: no `FAIL:` line.
- [ ] **Step 5: Commit** `docs: direction protocol, claims wiring, update-index is a baseline reset` (with the self-install refresh: doc-tools.sh help changed).

---

## Chunk 8: Hooks, CI, reference doc, release 3.2.0

### Task 27: Git hook claims legs

**Files:** Modify `scripts/hooks/git/pre-commit`, `scripts/hooks/git/pre-push`, `references/hooks.md` and `scripts/test-hooks.sh`.

**Interfaces:**
- pre-commit (verified against the template: `[[ -f "$DOC_TOOLS" ]] || exit 0` at :27, the doc-index check `[[ -f docs/.doc-index.json ]] || exit 0` at :28, `_quiet`/`_strict` defined at :30-31):
  - **Move** the doc-index check from :28 to just after the claims leg.
  - Insert the claims leg **after** the `_quiet`/`_strict` definitions, so it can use them.
  - With claims disabled the leg is skipped, so the hook's behaviour (exit 0 with no index, its freshness leg) is unchanged.
  
  The leg runs when `[[ -d docs/spec-claims ]]` and `DOC_SUPERPOWERS_CLAIMS_SKIP` is not `1`. It runs `"$DOC_TOOLS" claims validate --staged </dev/null` and captures the JSON and the rc:
  - rc 0 → print advisories (unless QUIET) as `doc-superpowers: claims: <check> <claim>: <message>`, and continue;
  - rc 1 → print findings the same way plus `  Commit blocked (claims). Fix, or rule the direction — see references/spec-claims.md. DOC_SUPERPOWERS_CLAIMS_SKIP=1 bypasses.`, then `exit 1`;
  - rc 2 or 3, or an unknown verb from an older doc-tools → one line `doc-superpowers: pre-commit: claims check could not run: <error|first indeterminate reason>`; continue, except `exit 1` under STRICT.
  
  The rest of the hook is unchanged. The header comment documents the leg and the new variable.
- pre-push (verified: the loop's `continue`s at :27-30 skip everything after them when the pushed commit has no tag, or ≤ 5 commits since one). The claims leg goes **inside the ref loop, after the tag/deletion `continue`s (:19-26) and before the `latest_tag` line (:27)**, so it runs for every pushed branch whether or not the release reminder fires. When `docs/spec-claims` exists and the claims skip is not set, it runs two things, each with `</dev/null` so nothing consumes the loop's ref lines on stdin:
  - `claims run --planes-of <range>`, where `<range>` is `<remote_oid>..<local_oid>`, or `$(git merge-base <local_oid> <config base or origin/main>)..<local_oid>` when the remote oid is all zeros;
  - for each `docs/spec-claims/gates/<stem>/` without `final.json` whose plan exists, `claims attest --plan <plan>`.
  
  It prints `doc-superpowers: claims (advisory): <n> red, <m> indeterminate` plus the finding lines, and never changes the exit code. The release reminder below it is unchanged.
- `references/hooks.md`: the git-tier table rows for both hooks gain the claims leg, `DOC_SUPERPOWERS_CLAIMS_SKIP` and the blocking semantics.

- [ ] **Step 1: Write the failing tests** in `test-hooks.sh`. That suite gets its own fixture, `claims_hook_fixture`: `indexed_fixture`, plus a governing spec `docs/specs/SPEC-AUTH-001-token.md` holding the requirement line, its sidecar with one `unbuilt` claim and a tracker doc, `docs/spec-claims/config.json` (`{"schema":1,"base":"main"}`) and a `#!/bin/sh` stub runner like Task 7's, logging to a `harness_mktemp` file. All of it is committed on `main`, then `git checkout -qb feature` and `install_tiers --git`. It does not source `test-spec-claims.sh`.
  - `test_pre_commit_claims_inert_without_dir`: `hooked_fixture`, stage an unrelated file, with `DOC_TOOLS` pointing at a wrapper that appends its argv to a log and then execs the shim → rc 0, empty output, and the log has no line starting with `claims`.
  - `test_pre_commit_claims_blocks_on_v2`: `claims_hook_fixture`, stage a doc edit breaking the quote → rc 1, `assert_contains "$RUN_OUT" "V2"`.
  - `test_pre_commit_claims_advisory_v8_does_not_block`.
  - `test_pre_commit_claims_indeterminate_warns`: base `nope` → rc 0 with the `could not run` line; with `DOC_SUPERPOWERS_STRICT=1` → rc 1.
  - `test_pre_commit_claims_skip_env`.
  - `test_pre_commit_claims_runs_without_doc_index`: a claims fixture with no `.doc-index.json` still blocks on V2.
  - `test_pre_push_claims_advisory_never_blocks`: a red claim → rc 0 and the output has `claims (advisory): 1 red`.
  - `test_pre_push_claims_runs_without_tags`: the fixture has no tag, so the release reminder's `continue` fires; the claims line is still printed.
  - `test_pre_push_claims_two_refs_both_processed`: `RUN_STDIN` holds two ref lines for two branches, and the stub runner reads (and logs) its stdin → the claims leg runs for both refs, and the stub's log records no stdin bytes.
  - `test_pre_push_claims_quiet`.
- [ ] **Step 2: Run** `bash scripts/test-hooks.sh`. Expected: FAIL on the new tests only.
- [ ] **Step 3: Edit the templates and `hooks.md`.**
- [ ] **Step 4: Run** `bash scripts/test-hooks.sh` and `bash scripts/test-doc-tools.sh` (bash-4 guard). Expected: PASS.
- [ ] **Step 5: Commit** `feat(hooks): claims legs in pre-commit and pre-push`.

### Task 28: CI step, templates, named PR-body section

**Files:**
- Create: `scripts/hooks/ci/doc-superpowers-steps/claims-check.sh`
- Modify: `scripts/hooks/ci/doc-spec-verify.yml`, `scripts/hooks/ci/doc-freshness-schedule.yml`, `scripts/hooks/ci/doc-pr-release/update-pr-body.sh`, `references/hooks.md` and `scripts/test-doc-pr-release.sh`

**Interfaces:**
- `claims-check.sh pr|scheduled` follows the conventions of the `freshness-check.sh` header (usage exit 2 without `GITHUB_OUTPUT`; `DOC_TOOLS` default `.github/scripts/doc-tools.sh`; files in `$RUNNER_TEMP`).
  - With no `docs/spec-claims/`: `status=disabled`, exit 0.
  - Every `claims` call passes `--base <PR base sha>` (the left side of `RANGE`) in `pr` mode, and `--base "$BASE_REF"` in `scheduled` mode. The template sets env `BASE_REF: origin/__BASE_BRANCH__`, substituted by `install.sh`'s `render_workflow` like the other templates. So the ratchet never depends on `origin/main` existing under that name.
  - `pr` (env `RANGE=<base>...<head>`) runs, in order, `claims validate --all`, `claims run --all`, and `claims attest --plan <p> --final` for each plan under `plans` whose gates dir exists, which is `completed` or has `final.json`, **and whose plan file or `final.json` changed in `RANGE`** (`git diff --name-only --no-renames $RANGE`). An old plan the PR does not touch is never attested, so an unrelated PR's ruling is never attributed to it. The CI checkout's verdict store is always empty. That is expected: promotions count by stored digest and "re-promote owed" is decided by commit order (Tasks 5, 16, 17), so a missing verdict yields `unverifiable-here` advisories and never a finding. It writes `claims-report.json` (an array of the verdict objects) and `claims-amendments.md` (`claims rulings --range <merge-base>..<head> --format markdown`, empty when there are none). Outputs: `status=ok|findings|indeterminate`, `findings=<n>`, `report=<path>`, `amendments=<path>`, `amendments_count=<n>`. Exit 1 on findings. Exit 0 with `::warning::` on indeterminate, exit 1 under `DOC_SUPERPOWERS_STRICT=1`.
  - `scheduled` runs `claims run --all --scheduled --judge-sample 3`, `claims promote --reverify --all` and `claims validate --all`, with the same outputs plus `judge_sample=<comma ids>`. It never exits 1 for findings (the issue step reports them) and exits 1 only when nothing could run.
- `doc-spec-verify.yml` gains a job `claims` (no AI): `runs-on: ubuntu-latest`, `timeout-minutes: 20`, `permissions: {contents: read, pull-requests: write}`, the same `if:` guard as `spec-verify`, checkout with `fetch-depth: 0`, then step `.github/scripts/doc-superpowers-steps/claims-check.sh pr` with `RANGE`. A following step runs `if: steps.claims.outputs.amendments_count != '0' && hashFiles('.github/scripts/doc-pr-release/update-pr-body.sh') != ''` and pipes the amendments file to `DOC_SUPERPOWERS_SECTION=spec-claims .github/scripts/doc-pr-release/update-pr-body.sh <PR>` with `GH_TOKEN`. A comment in the job says hosts add their test-environment setup before the claims step in their own workflow; without it, adapters report `indeterminate`.
- `doc-freshness-schedule.yml` gains the step `claims-check.sh scheduled` (`id: claims`, `continue-on-error: false`, env `BASE_REF: origin/__BASE_BRANCH__`) after the freshness step. The job's `timeout-minutes` rises from 10 to 30, with a comment: `claims run --all` plus `promote --reverify --all` execute the host's claim-bound tests twice over, and the freshness check alone was budgeted at 10. A disabled project still finishes in the old time.
  - The issue step's condition becomes `(freshness ok && count != '0') || steps.claims.outputs.status == 'findings'`.
  - The body appends a `### Spec claims` section (`<n> finding(s)`, the first 200 lines of findings from the report, the judge sample) only when `steps.claims.outputs.status` is `findings` or `indeterminate`.
  - The close condition additionally requires `steps.claims.outputs.status` ∈ {`disabled`, `ok`}.
  - With `status=disabled`, the rendered issue body is identical to 3.1.0's.
- `update-pr-body.sh`: env `DOC_SUPERPOWERS_SECTION=<name>` (`[a-z0-9-]+`, else exit 2) selects the markers `<!-- doc-superpowers:<name>:start -->` / `<!-- doc-superpowers:<name>:end -->`. A new named section is inserted at the **top** of the body, followed by one blank line. When it is unset, behaviour is unchanged (existing tests pin it). Marker-injection rejection covers both the default and the named markers.

- [ ] **Step 1: Write the failing tests** in `test-doc-pr-release.sh`:
  - `test_claims_check_disabled` (no dir → `status=disabled`, rc 0);
  - `test_claims_check_pr_empty_store_converged_plan_passes` (a plan converged locally, including a DOC-STALE plus re-promotion, with `final.json` changed in `RANGE`; run `claims-check.sh pr` in a fresh clone with an empty verdict store → rc 0, `status=ok`);
  - `test_claims_check_pr_findings_exit_1` (claims fixture with a red claim and the stub runner, `DOC_TOOLS` = the repo's doc-tools shim → rc 1, `findings=1`);
  - `test_claims_check_pr_indeterminate_warns` (rc 0 with `::warning::`; STRICT → rc 1);
  - `test_claims_check_pr_amendments_file` (one DOC-STALE ruling in range → `amendments_count=1` and the file has `## Spec amendments (1)`);
  - `test_claims_check_scheduled_reports_judge_sample`;
  - `test_claims_check_pr_passes_pr_base` (the doc-tools wrapper's argv log shows `--base <left side of RANGE>` on every `claims` call);
  - `test_claims_check_pr_attests_only_plans_changed_in_range` (two completed plans with `final.json`; only plan B's file changes in `RANGE` → the argv log shows `attest --plan <B>` and no `attest --plan <A>`; a ruling on a doc plan A governs, added in `RANGE` outside any plan, yields no finding attributed to plan A);
  - `test_schedule_timeout_raised` (parsed YAML: `jobs.audit-freshness.timeout-minutes == 30`);
  - the template structure: `doc-spec-verify.yml` has job `claims` with exactly `contents: read` and `pull-requests: write`, its run step is `.github/scripts/doc-superpowers-steps/claims-check.sh pr`, and both templates still parse after placeholder substitution (existing YAML loop);
  - `test_schedule_close_requires_claims_ok` (a jq read of the parsed YAML `if:` string contains `steps.claims.outputs.status`);
  - `test_named_section_inserted_at_top`, `test_named_section_replaced_in_place`, `test_named_and_default_sections_coexist`, `test_named_section_bad_name_exit_2`.
- [ ] **Step 2: Run** `bash scripts/test-doc-pr-release.sh`. Expected: FAIL on the new tests.
- [ ] **Step 3: Implement** the step, templates and editor, then `bash scripts/hooks/install.sh install --ci` (the schedule template and the steps dir changed).
- [ ] **Step 4: Run** `bash scripts/test-doc-pr-release.sh`, then `bash scripts/test-doc-tools.sh` (the bash-4 guard scans the new step and the inline `run:` blocks). Expected: PASS. Confirm the drift check locally: `git status --porcelain .github/` lists only the installer's writes, which you stage.
- [ ] **Step 5: Commit** `feat(ci): claims checks in spec-verify and the scheduled audit` (with `.github/`).

### Task 29: `references/spec-claims.md` and the spec template

**Files:** Create `references/spec-claims.md`. Modify `references/doc-spec.md` and `scripts/test-spec-status-model.sh`.

**Interfaces:**
- `references/spec-claims.md` sections, in order:
  1. When this applies (`docs/spec-claims/` exists; inert otherwise).
  2. Normative vs descriptive text.
  3. Files and names (the exact names list).
  4. `config.json` (every key with its default, from Task 1).
  5. Claim record (§B verbatim, plus the sidecar envelope and ruling `reason`).
  6. Statuses and the strict-xfail table.
  7. Enforcement tiers.
  8. Non-vacuity and `promote`.
  9. Checks V1–V12 (one row each, with what blocks by default).
  10. Exit codes.
  11. Adapter contracts (§D verbatim).
  12. The configuration extension (§B.1).
  13. Gates, records and `attest`, including the design's caveat, verbatim in substance: records are self-reported, and attest proves they are consistent with the tree, not that an agent ran them.
  14. Direction protocol (a pointer to `spec-lifecycle-protocol.md`, not a copy).
  15. Reference helpers.
  
  The reference helpers are examples, not shipped executables:
  - a pytest `conftest.py` that reads the sidecars, registers `@pytest.mark.claim("<id>")`, and applies `pytest.mark.xfail(strict=True, raises=AssertionError)` to `diverged` and `pytest.mark.xfail(strict=True)` to `unbuilt`;
  - a jest helper `claim(id, name, fn)` that wraps `test.failing` for `diverged`/`unbuilt` and rethrows non-assertion errors for `diverged` (an assertion is `err.matcherResult !== undefined || err.name === 'AssertionError'`);
  - a skeleton pytest runner adapter: `list` = a static scan (`grep -n`) for the marker plus `def test_`, never collection; `run` = `pytest --junitxml`, with `failure` of type `AssertionError` → `assert-fail`, other failures/errors → `error`, collection failure → `error`, and a missing interpreter or env → `indeterminate env-missing`.
- `doc-spec.md` spec template: between `## Summary` and `## Motivation`, a commented example of the generated block (`<!-- spec-claims:status:begin -->` … `<!-- spec-claims:status:end -->`, "generated by `claims render`; do not edit"). Under `## Implementation Notes`, the line `<!-- spec-claims:descriptive -->`. A paragraph after the template explains both and links `references/spec-claims.md`. The ADR template gets the same status-block comment before `## Decision`.

- [ ] **Step 1: Write the failing pins** in `test-spec-status-model.sh`: the file exists; it contains `<!-- spec-claims:status:begin -->`, `<!-- spec-claims:descriptive -->`, `xfail(strict=True, raises=AssertionError)`, `"subject_imports_ok"`, `"outcome": "pass"|"assert-fail"|"error"|"not-found"|"indeterminate"`; `DOCSPEC` contains `<!-- spec-claims:descriptive -->`. When `python3` is present, the pytest example blocks (extracted from ```` ```python ```` fences) pass `python3 -m py_compile`; otherwise `record_skip` (CI has python). When `node` is present, the jest block passes `node --check`; otherwise SKIP, made a FAIL under `DOC_SP_REQUIRE_NODE=1`.
- [ ] **Step 2: Run** `bash scripts/test-spec-status-model.sh`. Expected: FAIL.
- [ ] **Step 3: Write the reference and edit the template.**
- [ ] **Step 4: Run the suite.** Expected: PASS.
- [ ] **Step 5: Commit** `docs: references/spec-claims.md and the spec template status block`.

### Task 30: Project docs, suite list and counts, tests.yml

**Files:** Modify `CLAUDE.md`, `README.md`, `docs/codebase-guide.md`, `docs/conventions.md`, `docs/architecture/system-overview.md`, `docs/architecture/diagrams/c4-container.png` (re-render), `docs/workflows/doc-superpowers.md` and `.github/workflows/tests.yml` (comments only; the step landed in Task 1). Sites located 2026-10-10:
- "five" suites: `CLAUDE.md` :29, :142, :174; `README.md` :320, :402; `docs/codebase-guide.md` :26, :148; `docs/conventions.md` :82 ("Run the five shell test suites — …", which also lists the suites: add `scripts/test-spec-claims.sh`); `.github/workflows/tests.yml` :1.
- "17 subcommands": `CLAUDE.md` Key Files; `docs/codebase-guide.md` :123; `docs/architecture/system-overview.md` :66 (the C4 container label) and :114; `docs/workflows/doc-superpowers.md` :745.

**Interfaces:**
- CLAUDE.md:
  - the Directory Structure gains `test-spec-claims.sh` and `references/spec-claims.md`, and the `doc-superpowers-steps/` comment (:70) adds `claims-check` to its step-script list;
  - the `doc-tools.sh` lines read `18 subcommands` and add `claims`, listed among the verbs that take sub-verbs;
  - the Key Files table gains rows for `scripts/test-spec-claims.sh` and `references/spec-claims.md`;
  - "five" becomes "six" in the tests.yml rows and the Testing paragraph;
  - the Testing paragraph's loop gains `spec-claims`, and its per-suite and total counts are the ones observed in Step 2.
- README.md: a "Spec claims (opt-in)" feature subsection (what it is, that it is inert without `docs/spec-claims/`, a link to `references/spec-claims.md`); "five test suites" becomes "six".
- codebase-guide / conventions: the suite list and the new files.
- system-overview / workflows: `18 subcommands`, with `claims` named. The C4 container label at system-overview.md:66 changes, so `docs/architecture/diagrams/c4-container.png` is re-rendered with the settings v3.1.0 recorded (mmdc 11.6.0, headless Chrome, `c4.wrap: false`, width 1248, scale 2). **If mmdc is unavailable** (ruled 2026-10-10): do **not** change the label in the Mermaid source at system-overview.md:66. Leave the source and the PNG mutually consistent at "17 subcommands", update every other site, and do not halt. Report `C4 container label update owed (mmdc unavailable): system-overview.md:66 + c4-container.png` in the task's output, and carry the same line into the release notes (Task 31). The prose table at system-overview.md:114 is updated either way.

- [ ] **Step 1: Find every count and enumeration:** `rg -n -i "five( shell)?( test)? suites|the five\b|17 subcommands|17th" CLAUDE.md README.md docs .github/workflows/tests.yml --glob '!docs/superpowers/**' --glob '!docs/plans/**' --glob '!docs/issues/**' --glob '!docs/archive/**'`. Expect at least the sites listed under Files. A hit about something other than suites or subcommands ("five-way coverage", "the five manifests") stays.
- [ ] **Step 2: Run the six suites under both interpreters,** recording each suite's `Results: N passed` line from the bash 5 run (both must show `0 failed`).
- [ ] **Step 3: Edit** each hit from Step 1, using the counts from Step 2. If `command -v mmdc` succeeds, change the C4 label and re-render the PNG. Otherwise leave both, and record the owed line.
- [ ] **Step 4: Run** `bash scripts/test-spec-status-model.sh`, which pins manifests and client docs. Expected: PASS.
- [ ] **Step 5: Commit** `docs: six suites, the claims verb group and spec claims in project docs`.

### Task 31: Release 3.2.0

**Files:** Modify `RELEASE-NOTES.md` and the 5 manifests (via `bump-version`).

**Interfaces:** The heading is `## v3.2.0 (<release date>)`, inserted above `## v3.1.0`. Sections:
- a lead paragraph (opt-in; inert without `docs/spec-claims/`);
- `### Features` (`claims` verbs, gates, the configuration extension, hooks/CI);
- `### Changed (claims-enabled projects only)`: `spec-inject --phase=plan` injects gate tasks and Claims lines; `spec-verify` reports `attest`/`run` verdicts and FAILs on them; R5; the pre-commit claims leg blocks;
- `### Changed (all projects)`: wording only (`update-index` is a baseline reset), the direction protocol offered as framing, the scheduled audit's `timeout-minutes` 10 → 30 (re-run `install.sh install --ci` to pick it up) and a claims step that reports `disabled`; no change in outcome without `docs/spec-claims/`;
- `### Documentation`, including, when Task 30 reported it, the line `Known gap: the C4 container diagram still reads "17 subcommands" (label and PNG update owed: mmdc was unavailable).`;
- `### Other`: the new suite and its assertion count, with the per-suite count changes taken from Task 30.

- [ ] **Step 1: Write the release-notes entry.**
- [ ] **Step 2: Run** `scripts/doc-tools.sh bump-version 3.2.0`, then `scripts/doc-tools.sh check-version`. Expected: exit 0, all five manifests at 3.2.0.
- [ ] **Step 3: Run all six suites under both interpreters,** then `bash scripts/hooks/install.sh install --ci` and `git status --porcelain .github/` (expected: no output, so the tier is current). Expected: no `FAIL:` line.
- [ ] **Step 4: Commit** `release: v3.2.0 — spec claims` (RELEASE-NOTES.md, manifests).

---

## Review record

| Round | Reviewer | Verdict | Findings | Disposition |
|---|---|---|---|---|
| 1 | consult (independent judge) | CHANGES REQUESTED | 27 (9 P1, 18 P2), plus one open question (the jq 1.6 floor; ruled: accept the risk) | All accepted, none rejected; folded |
| 2 | consult | CHANGES REQUESTED | 7 (3 P1, 4 P2), plus one open question (mmdc unavailable; ruled: leave the C4 label and PNG consistent, report the update as owed, do not halt) | All accepted, none rejected; folded |
| 3 | consult | CHANGES REQUESTED | 3 (2 P1, 1 P2) | All accepted, none rejected; folded |

The review loop reached its cap at round 3. **The round-3 fixes are folded but not re-reviewed.** They are:
- the emitted-marker ordering and the `_scratch_init` failure path (Task 1);
- digest-matched promotion inclusion and the commit-order "re-promote owed" decision (Tasks 5, 16, 17, 28);
- `9>&-` on every adapter call (Tasks 7, 21).

They get their first independent review in the executing session's per-task reviews. Those reviewers should check them against the code as written, and not take this record as evidence that they hold.
