# Spec Claims — Reference

Executable spec claims: one atomic, falsifiable statement of a governing doc (a spec or an ADR), stored beside the doc, bound to a check, and judged at recorded lifecycle gates. `doc-tools.sh claims <verb>` (`validate`, `run`, `promote`, `render`, `gate`, `attest`, `rulings`) is the checker; `doc-tools.sh claims <verb> --help` prints each verb's usage, and `doc-tools.sh --help` its "Spec claims" and "Exit status" notes.

This reference describes the checker **as built**. The design it implements is `docs/superpowers/specs/2026-10-10-spec-claims-design.md` in the doc-superpowers repository; where the code deliberately differs from the design's text, this reference states the code's behaviour. Passages marked *verbatim* are copied from the design, and their `§` references are to it.

**Contents:** [When this applies](#when-this-applies) · [Normative vs descriptive text](#normative-vs-descriptive-text) · [Files and names](#files-and-names) · [config.json](#configjson) · [Claim record](#claim-record) · [Statuses and the strict-xfail table](#statuses-and-the-strict-xfail-table) · [Enforcement tiers](#enforcement-tiers) · [Non-vacuity and promote](#non-vacuity-and-promote) · [Checks V1–V12](#checks-v1v12) · [Exit codes](#exit-codes) · [Adapter contracts](#adapter-contracts) · [The configuration extension](#the-configuration-extension) · [Gates, records and attest](#gates-records-and-attest) · [Direction protocol](#direction-protocol) · [Reference helpers](#reference-helpers)

---

## When this applies

Claims are enabled when the directory `docs/spec-claims/` exists in the working tree. `config.json` is optional: every key it omits takes its default ([config.json](#configjson)).

Without the directory everything is inert. Every `claims` verb prints `{"verb":"<verb>","enabled":false,"exit":0}` and exits 0, and the git hooks, the CI templates and the `spec-*` actions behave exactly as they did before claims existed. The order of argument handling makes that hold for every invocation: the options are parsed first (an unknown option exits 3 even in an inert project), then the inert check runs, then the required arguments are checked (so a missing `--plan` or `--chunk` in an inert project still exits 0 with `enabled: false`).

A project opts in by creating `docs/spec-claims/` with its first sidecar. From then on the pre-commit claims leg blocks on findings, the pre-push leg reports, the `doc-spec-verify` `claims` job checks every same-repository PR (fork and dependabot PRs are not checked), and the weekly schedule re-verifies ([Hooks and CI](#hooks-and-ci)). A same-repository PR that deletes a `docs/spec-claims/` its base has is itself a CI finding.

The checker needs bash ≥ 3.2, `jq` ≥ 1.6 and git. A claims check over a commit range that holds a merge — `claims run --planes-of`, `claims gate`, and `claims validate`'s V9 over the merge-base range — reads the merge's hand resolutions with `git show --remerge-diff`, so it needs git ≥ 2.36; an older git makes that check indeterminate (exit 2). `claims attest` never reads a merge.

## Normative vs descriptive text

A governing doc holds two kinds of text. **Normative** text — decisions, requirements, invariants, interfaces, resolved open questions, dated `AMENDED` blocks — is written first (`spec-generate`) and approved by the human who reviews docs: **claims anchor only in normative text, and normative text is the intent.** **Descriptive** text — `## Implementation Notes` and any section the execute phase writes from landed code — reports what was built and never overrides normative text. A decision that lives only in an issue, plan or design must be promoted into a governing doc before a plan task implements it (V12).

**Governing docs** match a `governing` glob of the config (default `docs/adr/*.md`, `docs/specs/*.md`, plus any `governing_extra`) **and** have a DOC-ID. In a claims glob, `*` also matches `/`. The DOC-ID is the file name's prefix, wherever the file lives (an archived spec keeps its id): `ADR-<digits>` for an ADR, `SPEC-<CAT>-<digits>` (`CAT` upper-case letters) for a spec; for a doc under a `governing_extra` glob with no such prefix, the file stem. A doc with no DOC-ID (`template.md`, `README.md`) is never governing.

**How a line is classed** (V8 and V8n read the classes). Each ATX heading outside a code fence sets the class of its level; a line takes the class of the deepest heading above it that has one:

1. **Descriptive** when the heading is followed — blank lines aside, before any other line — by the marker line `<!-- spec-claims:descriptive -->` (up to three leading spaces); or when a config `descriptive_headings` ERE matches it.
2. **Normative** when a config `normative_headings` ERE matches it.
3. Otherwise by its text, with a leading section number (`3.`, `3.1`), `*`, `_` and `` ` `` and a final `:` removed, compared lower-cased: `open questions?` is **openq** (the resolved column of its tables is normative); `implementation notes?` is descriptive; and the default normative headings — `design`, `requirements?`, `invariants?`, `interfaces?`, `inputs?`, `outputs?`, `inputs? and outputs?`, `decisions?`, `.*(phase|stage) contracts?` (an ADR's `Decision` among them) — are normative.
4. **Descriptive is sticky downward.** Under a descriptive heading every deeper heading is descriptive, whatever its text: an `### Interfaces` inside Implementation Notes describes, it does not specify. Under a normative heading a sub-heading with no class of its own inherits normative.

Heading lines, the marker line, a line that is one HTML comment and nothing else (a template's placeholder), and every line of the generated status block are of no class.

**Host heading EREs.** `normative_headings` and `descriptive_headings` are POSIX EREs (awk's dialect, `LC_ALL=C`), matched against the heading's whole text lower-cased — its closing `#`s dropped, but its section number and emphasis still in it — and **not anchored** for you. Anchor them: `^build log$`, or `^([0-9.]+ )?build log$` to allow a number. An unanchored descriptive ERE (`notes`) also matches the `#` title (`# SPEC-AUTH-001: Notes on tokens`), and since descriptive is sticky downward, the whole doc becomes descriptive: V8 then never fires on it. An `## Open questions` section placed under a descriptive section is descriptive too, not openq: its resolved column is not V8-checked, and its lines are read by V8n as descriptive text. An ERE that is not a non-empty string awk compiles makes V8 and V8n indeterminate (exit 2), naming the key.

**Descriptive conformance lines (V8n).** A descriptive line that asserts conformance must cite the claim whose verdict it reports, or say `(unverified)`. The trigger phrases are exactly `as specified`, `conforms`, `aligned with`, `matches §` and `implemented per`, in any case, read from the line's live normalised text; no other wording is read, so a pointer at a normative section (`see §Interfaces`) is never flagged. A claim id on the line (a citation) is a token `<P>#<slug>` — `<P>` a run of letters, digits, `_`, `.` and `-`, the slug `[a-z0-9][a-z0-9-]*` — that starts at a boundary (not after a letter, digit, `_`, `.`, `/`, `#` or `-`, so a path `docs/README#install` or a URL `/API#intro` holds none) and whose `<P>` is a DOC-ID: the DOC-ID of the doc of a sidecar in the proposed tree (a `governing_extra` file stem included), or of the ADR or SPEC id shape (`ADR-<digits>`, `SPEC-<CAT>-<digits>`). Any other token — `README#install`, `C#sharp`, `guide.md#setup` — cites nothing. A known id is the id of any claim of any sidecar (retired claims included). On a trigger line:

- each distinct **unknown** id is a finding, `cites unknown claim <id>` — always, whatever else the line carries;
- a line with **no** id is a finding, `asserts conformance with no claim id or (unverified)`, unless it holds the text `(unverified)`.

So a known id, or `(unverified)`, exempts the line from the no-id finding only: a mistyped id beside a good one is still reported.

```markdown
## Implementation Notes
<!-- spec-claims:descriptive -->
Token expiry is implemented as specified (SPEC-AUTH-001#token-ttl).
Refresh rotation conforms to the design (unverified).
```

## Files and names

| What | Exact name |
|---|---|
| The checker | `doc-tools.sh claims <verb>` — `validate`, `run`, `promote`, `render`, `gate`, `attest`, `rulings` |
| The switch | the directory `docs/spec-claims/` |
| Host config (optional) | `docs/spec-claims/config.json` |
| Sidecar, one per governing doc | `docs/spec-claims/<DOC-ID>.json` (every `docs/spec-claims/*.json` except `config.json`; nothing in a subdirectory is a sidecar) |
| Chunk gate record | `docs/spec-claims/gates/<plan-stem>/chunk-<n>.json` (`<n>` a positive integer, no leading zero) |
| Final gate record | `docs/spec-claims/gates/<plan-stem>/final.json` |
| Verdict store (local, never committed) | `$(git rev-parse --git-common-dir)/spec-claims/promotions/<digest>.json` |
| Status block markers | `<!-- spec-claims:status:begin -->` / `<!-- spec-claims:status:end -->` |
| Descriptive marker | `<!-- spec-claims:descriptive -->` |
| Injected plan tasks | `Claims gate (chunk <n>)`, `Final claims gate` (`references/spec-lifecycle-actions.md`, `spec-inject --phase=plan`) |
| Plan task lines | `**Claims:** <id>, <id>…` · `**Claims:** none — <reason>` |
| Hook bypass (the claims leg only) | `DOC_SUPERPOWERS_CLAIMS_SKIP=1` |

`<plan-stem>` is the plan's file name without its extension.

## config.json

One JSON object. It is deep-merged over the defaults: objects merge key by key, arrays and scalars replace the default, and `governing_extra` is appended to `governing`. A top-level key the defaults do not have is a V1 finding; a file that is not one JSON object makes every verb exit 2.

| Key | Default | Meaning |
|---|---|---|
| `schema` | `1` | The config format. |
| `base` | `"origin/main"` | The base of every ratchet: they compare with `git merge-base HEAD <base>`, never the base's tip. `--base` on any verb wins over it. An unresolvable base is indeterminate (exit 2). |
| `governing` | `["docs/adr/*.md", "docs/specs/*.md"]` | Governing-doc globs (`*` also matches `/`). |
| `governing_extra` | `[]` | More governing globs, appended to `governing`; a doc under one may use its file stem as its DOC-ID. |
| `normative_headings` | `[]` | Host EREs for normative headings (anchor them: [Normative vs descriptive text](#normative-vs-descriptive-text)). |
| `descriptive_headings` | `[]` | Host EREs for descriptive headings (the same). |
| `kinds` | `[]` | Host claim kinds, beside `behaviour`, `interface` and `config`. |
| `code_roots` | `[]` | What counts as code for V12 ("a task touching code") and for gate-exempt doc-only commits. Empty: every path outside `docs/`. Each entry is a glob, or a prefix (the path itself, or a directory above it). |
| `plans` | `["docs/superpowers/plans/*.md", "docs/plans/*.md"]` | Plan globs: V12, the direction policy, and which plans CI attests. |
| `tracker_patterns` | `[]` | Regexes (jq / Oniguruma) for trackers that live in a service, e.g. `"^#[0-9]+$"` or `"^https://tracker\\.example/"`. A tracker matching one is taken as open: a hook cannot read its state offline. |
| `source_doc_patterns` | `["docs/issues/", "docs/superpowers/specs/"]` | Path prefixes that mark a link in a plan task as the source of its behaviour (V12: a `**Claims:** none` task may not have one). |
| `runners` | `{}` | `{"<runner>": {"adapter": "<repo path>", "paths": ["<prefix or glob>"…]}}` — one runner adapter per test framework. `paths` decides which runners `--planes-of` re-runs: an entry holding `*`, `?` or `[` is a glob, any other a prefix. |
| `log_adapter` | `null` | The repo path of the log adapter (`log` claims). |
| `config_adapter` | `null` | The repo path of the config adapter. Not `null` switches the [configuration extension](#the-configuration-extension) on. |
| `policy` | `{"in_plan_ruling_requires_gate_record": true, "outside_plan_presumption": "CODE-DIVERGES", "doc_stale_outside_plan_requires": null}` | The direction policy ([Direction protocol](#direction-protocol)). |
| `blocking` | `["V1", "V2", "V3", "V4", "V5", "V6", "V10", "V11", "V12"]` | The checks whose findings block `validate` (exit 1); any other check's findings are advisories there. Not read by `run`, `promote`, `gate` and `attest`, where every finding blocks. |

An adapter path is a repo path from the work tree's top level: relative, with no empty, `.` or `..` segment, reached through no symbolic link, and executable. Any other path, a missing file, or a `test.runner` that `runners` does not name, is a missing adapter: every call to it is indeterminate (exit 2), never a finding.

```json
{
  "base": "origin/main",
  "runners": {"pytest": {"adapter": "tools/spec-claims/pytest-adapter", "paths": ["src/", "tests/"]}},
  "tracker_patterns": ["^#[0-9]+$"]
}
```

## Claim record

A sidecar is one JSON object, `{"schema": 1, "doc": "<repo path>", "claims": [<claim record>…]}`. `doc` is the governing doc's path from the repo root, as `git ls-files` prints it, and the sidecar's file stem must equal that doc's DOC-ID. The record, *verbatim* from §B:

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
  "promotion": {"at": "<sha>", "verdict_sha256": "<digest>",
                "proved": {"states": "<sha256>", "test": "<sha256>", "subject": "<sha256>",
                           "enforced_by": "test", "nonvacuity": "<sha256>", "when": "<sha256>"}},
  "tracker": null,
  "frozen_at": null,
  "restates": [],
  "rulings": [{"date": "2026-10-10", "direction": "DOC-STALE", "by": "<principal>", "record": "<path>"}]
}
```

As built, a `DOC-STALE` or `RETIRE` ruling also needs `reason` (the example's ruling would need one): the amendment batch prints it, and §F says the ruling records why.

| Field | Type and rule (V1 unless noted) |
|---|---|
| `id` | `<DOC-ID>#<slug>`, slug `[a-z0-9][a-z0-9-]*`; unique across every sidecar. |
| `quote` | Non-empty; anchors in the doc's live text (V2, below). |
| `states` | Non-empty: what the claim asserts, in the verifier's words. Changing it needs a new `DOC-STALE` or `RETIRE` ruling (V6). |
| `kind` | `behaviour`, `interface`, `config`, or a host `kinds` entry. |
| `subject` | Array of repo paths: the code that implements it. |
| `status` | `built`, `diverged`, `unbuilt`, `retired`; `gated` with the configuration extension only. |
| `enforced_by` | `test`, `lint`, `log`, `judge` ([Enforcement tiers](#enforcement-tiers)). |
| `test` | `{runner, node[, file]}`, or `null` — `null` only while `unbuilt` or `retired`. `file` names the test file when `node` does not start with it. |
| `lint` | `{pattern, paths, expect: "present"\|"absent", selftest: {violates, clean}}`, or `null` (as for `test`). |
| `nonvacuity` | `{observed_red: <full commit id>}` and/or `{mutant: {file, find, replace}}`; required for `built` and `gated` (V3). |
| `promotion` | `{at: <commit>, verdict_sha256: <64 hex>, proved: {states, test, subject, enforced_by, nonvacuity, when}}`, written by `claims promote` only. `proved` is the fingerprint of the record promote ran green against: each field but `enforced_by` is the 64-hex sha256 of that field's canonical JSON (its compact `jq -cS` bytes, `null` when the field is absent, no trailing newline), and `enforced_by` is its value. A `built` or `gated` claim's promotion must carry `proved` with exactly these six keys (V1). `at` is HEAD at the proof, a record only: nothing reads it back, so a squash or rebase merge that leaves it on no branch changes nothing. |
| `tracker` | A repo path or a `tracker_patterns` match, or `null`; open trackers are required by V5. |
| `frozen_at` | A commit, or `null`: the claim was true of a concluded record; it is validated structurally and skipped by `run`. |
| `restates` | Ids of the claims this one says again (V7). An id no claim has, or the claim's own id, is a V1 finding. |
| `quote_occurrence` | An integer ≥ 1: which live occurrence of the quote the claim anchors. |
| `rulings` | Array of `{date: "YYYY-MM-DD", direction: "CODE-DIVERGES"\|"DOC-STALE"\|"RETIRE", by, record, reason}`; `reason` required for `DOC-STALE` and `RETIRE`. `record` is a repo path that must exist and be neither the doc nor its sidecar (V6). |
| `why_not_mechanical` | Required for `enforced_by: judge` (V5). |
| `when`, `config_independent` | The configuration extension only ([below](#the-configuration-extension)). Every number inside `when` must be written canonically — an integer, or a decimal with no trailing zero (`1.5`, not `1.50`, `1.0` or `1e3`), at most 15 significant digits — or V1 reports it: jq 1.6 and jq 1.7+ print other literals differently, so `promotion.proved.when` would differ across jq versions. |

A sidecar whose doc is not a safe repo path, is missing, or is not governing is one V1 finding (with the advice to retire each live claim and `move-entry` the index entry), and its claims are skipped by V2–V5 and `render` — unless every claim is `retired`: a fully retired sidecar may name an archived, moved or deleted doc, a legal end state.

*Verbatim* from §B:

**Quote anchoring.** `quote` is a verbatim substring of the doc after normalisation (whitespace and line wraps collapsed; `*`, `_`, `` ` `` emphasis stripped) with exactly one live occurrence (or `quote_occurrence: n`). Text inside `~~…~~` and the generated status block is not live; dated `AMENDED` blocks are live (they carry the current normative text). Editing the prose breaks the quote, so a doc edit to a claimed sentence is always detected without inline markup.

As built, normalisation also drops each line's leading blockquote markers (`>`), so a quote that wraps inside an `AMENDED` block matches; code fences (CommonMark pairing: an inner fence with a shorter or other run stays inside) are masked first, so a `~~~` fence is never read as a strike. An `AMENDED` block is a blockquote whose first line matches `> … **AMENDED YYYY-MM-DD …`. When the quote has several live occurrences and one is in an `AMENDED` block, the claim must set `quote_occurrence` — a ruling alone does not anchor it (V2). Counting is by codepoint, so non-ASCII quotes and CRLF docs anchor exactly as ASCII and LF ones.

## Statuses and the strict-xfail table

The expected result is part of the status. `claims run` judges each raw outcome by it:

| Status | Meaning | Outcome expected by `run` | A finding in `run` | Requires (check) |
|---|---|---|---|---|
| `built` | the code does what the claim states | `pass` | any other outcome | a check; for `test`, a non-vacuity proof and a `promotion` (V3) |
| `gated` (extension) | passes under `when`, which the recorded configuration does not set | `pass` | any other outcome | as `built`, plus a non-empty `when` (V1) and an open tracker (V5) |
| `diverged` | ruled `CODE-DIVERGES`, not yet fixed | `assert-fail` | `pass` ("promote"), `error`, `not-found` | a `CODE-DIVERGES` ruling and an open tracker (V5) |
| `unbuilt` | planned, not implemented | anything but `pass`, or no check yet | `pass` ("promote") | an open tracker (V5) |
| `retired` | the doc no longer asserts it | none (skipped) | — | a `RETIRE` or `DOC-STALE` ruling (V5); no live occurrence of the quote (V2) |

`indeterminate` is never judged: it is exit 2. An open tracker is a repo path present in the tree being checked whose status value — front matter `status:`, or the first `**Status**:` line outside code fences — has a leading word that is not `closed`, `resolved`, `done`, `fixed`, `completed` or `wontfix` (any case: `Approved — not done` is open, `` `Done` (2026-10-01) `` closed; a doc with no status line is open), or a string matching a `tracker_patterns` regex.

The host's own suite mirrors the table, so it stays green while a claim is known-diverged and turns red when the claim is unexpectedly fixed or breaks with an error: `diverged` is an expected failure **on an assertion only** (pytest `xfail(strict=True, raises=AssertionError)`), `unbuilt` an expected failure of any kind (`xfail(strict=True)`). The runner adapter switches that marking off, so `claims run` sees the raw outcome ([Reference helpers](#reference-helpers)).

**The doc shows its own status.** `claims render` writes a generated block into each doc that has a sidecar, and `render --check` (V11) reports one that differs. The block lists every claim that is neither `built` nor `retired`, sorted by id — a retired claim's sentence is struck, so listing it would put dead text where a reader looks for open gaps — or, when every non-retired claim is `built`, the one line `Claims: N built`. A `gated` row names its condition: `gated (when: KEY=VALUE, …)`. No dates, SHAs or live values: it changes only when a status or a tracker does.

```markdown
<!-- spec-claims:status:begin -->
## Claim status

| Claim | Status | Tracker |
|---|---|---|
| `SPEC-AUTH-001#refresh-rotation` | diverged | #42 |
| `SPEC-AUTH-001#token-ttl` | unbuilt | docs/issues/042-token-ttl.md |

<!-- spec-claims:status:end -->
```

The first render inserts the block immediately before the doc's second `##` heading line outside a code fence (at the end of the file when there is none); thereafter it replaces the marker lines and everything between them. A marker counts only alone on its line (up to three leading spaces); a marker quoted in prose is text. Marker lines that are not exactly one begin followed by one end are a V11 finding, and that doc is not written. The block is not live text: V2 and V8 skip it. A CRLF doc gets a CRLF block. Do not edit the block: edit the sidecar and re-render.

## Enforcement tiers

`enforced_by`, ranked `test > lint > log > judge`; lowering it needs a new `DOC-STALE` or `RETIRE` ruling (V6).

| Tier | The check | Run by |
|---|---|---|
| `test` | A host test that binds itself to the claim id (a pytest marker, a jest helper), run through its runner adapter. | `run`, `gate`, `attest`, `promote` |
| `lint` | `grep -E` for `lint.pattern` over the `lint.paths` files: passes when `expect` is `present` and it matches, or `absent` and it does not. `selftest.violates` must fail the lint and `selftest.clean` pass it (each written as one line), else "vacuous pattern" (V4). | `validate` (V4, over the proposed tree), `run` (the working tree) |
| `log` | A host-defined production query through the log adapter; `fail` is judged as `assert-fail`. | `run --scheduled` only |
| `judge` | No mechanical check is feasible: carries `why_not_mechanical` (V5). | Never run: `run --judge-sample <n>` names n of them, rotated weekly, for a reviewer |

For a lint claim, a built or gated claim's lint must pass, a diverged claim's fail, an unbuilt claim's either; an absent `lint.paths` file is an allowed failure only while `unbuilt`. An unsafe path or a pattern `grep -E` rejects is a finding, never a pass or a fail.

## Non-vacuity and promote

A `built` (or `gated`) test claim proves its test can fail on the behaviour it claims, with either proof or both (each must hold):

- **`mutant: {file, find, replace}`** — `find` occurs in `file` exactly once, counted literally; with it replaced, the bound test fails by an assertion. `file` must not be the bound test's own file (a mutant of the test's expectation proves nothing), and must round-trip as UTF-8 text.
- **`observed_red: <commit>`** — a full commit id (not a branch, `HEAD~1` or an abbreviation): with the claim's `subject` files checked out as at that commit, the test fails by an assertion. No subject may be, or hold, the test's own file.

**`claims promote <id>` is the only path into `built`.** It refuses a dirty tree (exit 2, `dirty-tree`; untracked files are not counted, and `docs/spec-claims/gates/` is ignored) and then, in a throwaway worktree at HEAD: runs the bound test unmodified and requires `pass` (so the red run differs from the green one only by the proof); applies each proof and requires `assert-fail`; stores the verdict; writes `promotion` (`at` = HEAD, the digest, and `proved`, the fingerprint of the claim record it proved) and the new status into the sidecar; and re-renders the doc's status block. The result row is `{claim, status_from, status_to, green, red, verdict_sha256}`. Commit after each promote: the next one needs a clean tree.

A built claim whose verdict still matches, every field as `proved` records it, is refused ("already promoted"). With the configuration extension on, promote writes `gated` instead of `built` when the recorded configuration at HEAD does not satisfy the claim's `when` — and a `built` claim in that state is re-proved and **re-gated** rather than refused ([The configuration extension](#the-configuration-extension)).

**The verdict store.** Each verdict is the `jq -cS` bytes of `{claim, states_sha256, test, nonvacuity, proved, head, subject_oids, green, red, status_to}`, stored at `<store>/<digest>.json`, the digest (a bare 64-hex sha256 of those bytes) also written as `promotion.verdict_sha256`; `states_sha256` hashes the `states` string's UTF-8 bytes with no trailing newline, and `proved` is the same fingerprint promote writes into `promotion.proved`. The store is local: a fresh clone or a CI runner has none.

**What a promotion proved is read from `promotion.proved`**, never from the store and never from history, so a fresh clone, CI and a trunk the promoted branch was squash- or rebase-merged onto all give the same answer. V6 compares the claim with `proved` field by field (a missing field compares as `null`):

- a field equal to its `proved` value is unchanged;
- a `states` difference that a new `DOC-STALE` or `RETIRE` ruling covers is the advisory **`re-promote owed`**, and so is a `nonvacuity` or `when` difference that comes with it (an amended threshold needs a new mutant);
- any other difference is a finding that names the field and says `run claims promote <id>`: a `test`, `subject` or `enforced_by` difference whatever the ruling, a `nonvacuity` or `when` difference without such a `states` amendment, and a `states` difference without a new `DOC-STALE`/`RETIRE` ruling;
- when the store holds the verdict, the verdict must also bind the claim: its `claim`, `status_to` and `proved` must be the claim's id, status and `promotion.proved`, and, for each field still as proved, its `states_sha256`, `test`, `nonvacuity` and `subject_oids` paths must be the claim's. Otherwise it is a finding, so a forged `proved` beside a real verdict cannot hide a change;
- V6's **`unverifiable-here`** (an advisory) is left for one case only: the verdict is not in the store and every field equals `proved`, which is a promotion made in another clone with nothing changed since. The scheduled run re-verifies it.

`gate` and `attest` decide **"re-promote owed"** by the same comparison: owed when the claim's `states`, `test` or `nonvacuity` differs from `proved` (or it has none), or the store's verdict does not bind it; a `subject`, `enforced_by` or `when` change is V6's finding.

**Promotions are trusted by digest.** `gate`, `attest` and a clone without the verdict accept a promotion by its `verdict_sha256`; nothing outside the store can tell a real digest from an invented one. A forged digest is undetectable outside the promoting clone: a hand-written `status: built` with a made-up `{at, verdict_sha256, proved}` and a mutant that was never run passes `validate` and `run`, and a gate or attest record includes it by that digest, exactly as it would a claim promoted in another clone. A forged `proved` is as undetectable outside the promoting clone as a forged `verdict_sha256`: `proved` tells what changed since a proof, not that the proof ran. Reviewers should treat a move into `built` (or `gated`) that no `claims promote` run accounts for — no promote commit after the proof's commit, no gate record naming the promotion — as suspect, and the scheduled `promote --reverify --all` re-proves every promoted claim.

**`claims promote --reverify (<id>… | --all)`** re-runs the same proofs at HEAD for each named claim, or every promoted `built` or `gated` claim (a frozen one is skipped), and stores each fresh verdict without writing the sidecar or the doc. The scheduled CI job runs `--reverify --all` weekly.

A `DOC-STALE` amendment of a built claim changes `states`, so the claim no longer matches `proved`: V6 reports the advisory `re-promote owed` (not a finding) when the same change carries the covering ruling and the difference is the `states`, with the `nonvacuity` or `when` that moves with it (the quote and `quote_occurrence` may move too: they are not part of `proved`), and `gate` and `attest` stay red until `promote` has re-proved it. A ruling covers the `states`, not what proves them: a test, subject or tier swap is a finding whatever the ruling.

## Checks V1–V12

`validate --staged` checks the claims the staged change touches, in the staged tree: a claim is touched when a staged path is its sidecar or its doc, or is (or is under) one of its `subject` paths, its test file, its mutant file or a `lint.paths` file; a staged `config.json` touches every claim. `validate --all` checks every claim in the working tree. A finding blocks `validate` (exit 1) when its check is in config `blocking`, and is reported as an advisory otherwise. In `run`, `promote`, `gate` and `attest` **every finding blocks**, whatever its check; only explicit advisories (`unverifiable-here`, `re-promote owed`, `promote-owed`, `outside-branch-work`, `from-remapped`) do not.

| Check | Finding when (as built) | Blocks `validate` by default |
|---|---|---|
| **V1** schema | `config.json`: an unknown key. A sidecar: not one JSON object, `schema` not 1, `claims` not an array, `doc` unsafe, missing or not governing (unless every claim is retired), stem not the doc's DOC-ID. A record: a field missing or of the wrong type ([Claim record](#claim-record)), an id not `<DOC-ID>#<slug>`, a duplicate id, a `DOC-STALE`/`RETIRE` ruling without `reason`, a `restates` id that names no claim or the claim itself, a `built`/`gated` claim's `promotion` without `proved` and exactly its six keys. With the extension off: a `when` or status `gated`. On: `when` not an object, a `when` key the recorded configuration lacks, `gated` with an empty `when`, `config_independent` not a non-empty string. | yes |
| **V2** anchor | The quote is not uniquely live (and no `quote_occurrence` picks it), or `quote_occurrence` exceeds the live occurrences; a `retired` claim's quote is still live; an `AMENDED` block re-quotes a claimed sentence without `quote_occurrence` (a ruling alone does not anchor it). | yes |
| **V3** binding | A `test` claim (not frozen) whose node the runner's `list` does not report bound to its id; a bound node with `in_gate: false`, or with `subject_imports_ok: false` (a finding for every status); a test file that is unsafe or starts with `-`; `built` or `gated` without `nonvacuity` or `promotion`; a `mutant` that is malformed, absent, the test's own file, or whose `find` does not occur exactly once; an `observed_red` subject that is or holds the test file. With the extension on: a `when` the bound test does not establish, and the configuration-faithful checks. | yes |
| **V4** lint | A selftest `violates` that passes or `clean` that fails ("vacuous pattern"); the pattern's result contradicts the status; an unsafe or (outside `unbuilt`) absent `lint.paths` file; an invalid pattern. | yes |
| **V5** status | `diverged`, `unbuilt` or `gated` without an open tracker; `diverged` without a `CODE-DIVERGES` ruling; `retired` without a `RETIRE` or `DOC-STALE` ruling; `judge` without `why_not_mechanical`. Under `--staged`, only touched claims: a tracker closed in a commit that does not touch its claim surfaces at the next `--all` or scheduled run. | yes |
| **V6** ratchet | Against the merge-base: a `states` change, a lowered `enforced_by` or a token-changing re-anchor needs a new `DOC-STALE` or `RETIRE` ruling (only those change what the doc approved; a `CODE-DIVERGES` ruling keeps the doc as the intent, and the policy judges `DOC-STALE`/`RETIRE` only, so the latitude cannot be obtained by labelling); a re-anchor equal once normalised (a reflow or move) needs none; status moved off `built` needs a new ruling of any direction. Whatever the rulings, a finding: a claim deleted (retire it instead; the one legal deletion is a whole sidecar whose claims were all `retired` at the merge-base), and a move into `built`/`gated` without a promotion. A `built`/`gated` claim that is new or changed is compared with its `promotion.proved`, with the verdict or without it ([Non-vacuity and promote](#non-vacuity-and-promote)): the advisory `re-promote owed` when only the `states` (with the `nonvacuity` or `when` that moves with it) differ and a new `DOC-STALE`/`RETIRE` covers them; a finding naming the field for any other difference, or for a stored verdict that does not bind the claim; `unverifiable-here` only when the verdict is not in the store and nothing differs. Each new ruling's `record` must exist and be neither the doc nor its sidecar; each new `DOC-STALE`/`RETIRE` is judged by the policy. | yes |
| **V7** restates | A claim restating another whose `states` changed since the merge-base, when the restating claim has no new ruling (sibling sweep). A retired claim is not judged, nor a claim new in this change (it was written against the other as it now reads). | no |
| **V8** coverage | A normative line (an added one under `--staged` and at a gate; every one under `--all`) that no claim's quote occurrence covers; an `openq` table's resolved/resolution/answer/decision cell that no quote covers. | no |
| **V8n** descriptive | A descriptive line with a trigger phrase and no claim id or `(unverified)`; any unknown claim id on such a line ([above](#normative-vs-descriptive-text)). | no |
| **V9** claim-bound test edit | A claim whose bound test body the change edits (the runner's `edited-bound-tests`): adjudicate — `states` still holds (`gate --holds <id> --by <principal>`), or a ruling. An id edited only by trunk merged into a range is the advisory `outside-branch-work`. | no |
| **V10** configuration | The extension only: a configuration change re-classifies conditioned claims ([below](#the-configuration-extension)). | yes |
| **V11** status block | The doc's block differs from what `render` writes, or is absent, or its markers are unusable. Under `--staged`, only docs whose sidecar is staged. | yes |
| **V12** plan structure | For a plan (config `plans`) with governing specs that is new, or carries a gate task: a spec-update task with no claims gate for its chunk before it; a finalize task with no final gate before it; an `unbuilt` claim of a target spec named on no task's `**Claims:**` line; an implementation task touching code with no `**Claims:**` line; a `**Claims:** none` task that links a source doc (an issue, a design); a move to `Completed` that no `final.json` accepts. A plan already `Completed` at the merge-base is history: none of this runs on it. | yes |

`run`'s own findings are reported with check `run`. A plan's governing specs are its injected `**Specs**` lines (`- <path> — <target|constraint|amends|infer>`) plus a front-matter `governing_specs:` list (`- <path>[:role]`); `infer` counts as `target` for V12 and the policy.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | everything as expected (advisories may be present) |
| `1` | findings: a blocking check failed, a `built` or `gated` claim failing, a `diverged` or `unbuilt` claim passing |
| `2` | could not run: an adapter reported `indeterminate` or exited non-zero (or is missing), the base did not resolve, the config is not one JSON object, a dirty tree where one is refused, a missing dependency, a run outside a git work tree or below its top level, or an internal failure — never reported as a pass, and never 1 |
| `3` | usage error |

Precedence `1 > 2 > 0`. These codes are the `claims` verbs' own; every other `doc-tools.sh` subcommand keeps its exit table (usage = 2).

Each run prints exactly one verdict object on stdout — `{verb, enabled, exit, base: {ref, merge_base}, findings, advisories, indeterminate, results}` plus any verb-specific fields (a gate's record, attest's checks) — with each finding `{check, claim, doc, message}`, each advisory `{check, claim, code, message}`, each indeterminate row `{check, claim, reason}`. A usage error prints `{verb, enabled, exit: 3, error}` too, and a run that could not start prints `{verb, enabled: true, exit: 2, error}`. The one exception to "one object" is `claims rulings --format markdown`, which prints the amendment batch as Markdown, always under `## Spec amendments (N)` (N may be 0).

## Adapter contracts

*Verbatim* from §D — the JSON shapes are the contract and are never extended or renamed:

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

The run and list shapes, unescaped:

```text
list:  {"id": "<claim id>", "node": "<node>", "file": "<path>", "in_gate": true, "subject_imports_ok": true, "when": null}
run:   {"node": "<node>", "outcome": "pass"|"assert-fail"|"error"|"not-found"|"indeterminate", "reason": "<text>"|null}
log:   {"outcome": "pass"|"fail"|"indeterminate", "evidence": "<text>"}
```

**How doc-tools calls an adapter.** It runs `<repo root>/<adapter path>` with the work tree's top level as the working directory, stdin from `/dev/null` (an adapter must never read a hook's stdin, the pre-push ref lines), and none of doc-tools' own descriptors open. Its stdout is parsed; its stderr passes through, so diagnostics, and the test runner's own output, belong there. Each argument — a file, a node, a path with spaces — arrives as one argument.

**Parsing, fail-closed.** Blank lines are ignored. For `run`: a non-zero exit, or any line that is not a JSON object with a string `node` and one of the five outcomes (a log line, a missing or unknown `outcome`), makes **every** requested node `indeterminate`; a requested node the output does not report, or reports twice with different outcomes, is `indeterminate` itself. A `reason` that is not a string reads as `null`. For `list`: a non-zero exit or any malformed row (`id`, `node` strings, `in_gate` and `subject_imports_ok` booleans, `when` an object or `null`; `file` may be omitted) makes every claim of that call indeterminate — never "not bound". `list` is called once per runner, with the test files of the claims it checks as arguments (`test.file`, else the node's path before `::`); when a claim's node names no file of the tree, with none, meaning all test files. `edited-bound-tests` prints one claim id per line and nothing else: a non-zero exit, an empty line or a line holding a CR makes V9 indeterminate (an edit list that could not be read is never taken as empty); ids no claim has are ignored. It is called with `--staged`, with `<merge-base>..HEAD` (`validate --all`) or with `<from>..HEAD` (the gate). The log adapter's output is exactly one such object.

**The config adapter, as built.** `surfaces` and `readers` print one path or key per line (trimmed; blank lines dropped). `recorded` prints one JSON object whose every value is `{"recorded": …, "default": …}`; anything else, or a non-zero exit, is indeterminate (check `config`). **`--override KEY=VALUE` repeats**: doc-tools passes one per `validate --config KEY=VALUE`, and the adapter parses `VALUE` its own way (a string, or JSON, as the host's configuration does). Under `validate --staged --config …` the call is `recorded --staged --override …`; under `--all`, `recorded` with no revision flag reads the working tree.

**Adapter guidance.**
- `list` must stay a cheap syntax scan: pre-commit calls it under a blocking time budget.
- `run` must report the raw outcome. A test-side helper that marks claims expected-to-fail (xfail, `test.failing`) must be switched off when the adapter runs it, or a diverged claim's assertion failure would read as a pass.
- `run` must tell an assertion failure from any other error: an import error or a typo is `error`, never an expected red.
- A missing interpreter, virtual environment or service is `indeterminate` with a reason such as `env-missing` (or `owed-on-host` for a runner that cannot execute on this machine) — not `error`.
- `--root` may be a throwaway worktree with no untracked files (no virtual environment): find the environment elsewhere, e.g. in the checkout the adapter was called from.
- **Disable interpreter caches.** `promote` mutates a subject file in place and re-runs the test, often within the same second; an interpreter that validates its cache by the source's modification time in seconds and its size (Python's `.pyc`) can then run the stale, unmutated code of a same-size mutation and report a pass — a false refusal of a sound proof. Run Python with `PYTHONDONTWRITEBYTECODE=1` or `python -B`.

## The configuration extension

*Verbatim* from §B.1:

**Off unless a host declares a config adapter in `config.json`.** A project with no feature flags, environment switches or build variants never sees anything in this section: its claims are `built`, `diverged`, `unbuilt` or `retired`, its tests run under the code's defaults, and nothing below is checked.

The extension exists for hosts whose production behaviour depends on recorded configuration — feature flags, environment variables in deploy manifests, build variants — where a claim can be true of the code yet not of what production runs. It adds:

- **`when: {KEY: VALUE}`** on a claim — the condition under which the claim holds. The bound test establishes it itself (an environment variable, a configuration mock — however the host's configuration works); the claim declares it, and the runner adapter's `list` reports the conditions the test sets, so V3 can compare. The checker never injects configuration.
- **Status `gated`** — the claim passes under `when:`, but the host's **recorded production configuration** does not set it. Expected result: pass under `when:`. Requires a tracker for the configuration change, a non-vacuity proof and a `promotion` (it enters through `promote`, like `built`). It is never a final state: once the recorded configuration satisfies `when:`, the claim is promoted to `built`. With the extension on, `built` means true under the recorded production configuration.
- **Configuration-faithful checks** (part of V3) — when a claim's subject reads a key whose recorded production value differs from its code default, the claim must pin that value in `when:`, or declare `config_independent: <reason>`.
- **V10 configuration** — a staged change to a configuration surface re-classifies claims whose `when:` or subject names a changed key: a `gated` claim now satisfied → promote; a `built` claim no longer satisfied → a ruling is owed (§F); a `diverged` claim whose `when:` is being switched on → finding. `claims validate --config KEY=VALUE` runs the same check before a configuration change that is published outside git.
- **The config adapter** (contract in §D) — tells the checker which files carry configuration, the recorded and default value of each key, and which keys a path reads.

In the status block, `gated` claims name their condition. Under R5 (§E), a spec may reach `Implemented` with `gated` claims: `Implemented` means the code implements the spec, and the status block — not the Status field — says what production runs, so a spec's Status never tracks live configuration.

**As built:**

- **On** when config `config_adapter` is not `null`. Off, a claim's `when` (not `null`) or status `gated` is a V1 finding, a `list` row's `when` is ignored, and `validate --config` is a usage error (exit 3).
- **V1**: every `when` key must be a key the adapter's `recorded` reports; `when` is an object; `gated` needs a non-empty `when`; `config_independent` is a non-empty string or `null`.
- **V3, configuration-faithful.** For every claim that is neither retired nor frozen: each key that `readers <subject…>` reports, whose recorded value differs from its default, must be a key of the claim's `when` (key presence), unless `config_independent` gives a reason. The **value** pinned is judged for `built` claims only: a built claim whose `when` the recorded configuration does not satisfy is a finding ("…: gated"). A gated claim's `when` differs from the recorded value by definition, and an unbuilt or diverged claim's `when` may name the configuration it is meant to hold under; `promote` judges those when it runs. The bound test must establish the claim's `when`: each pair must appear in every bound `list` row's `when`.
- **V5**: `gated` needs an open tracker (the configuration change it waits for).
- **`run`** expects a `gated` claim to pass.
- **`promote`** asks `recorded --rev HEAD`: when it does not satisfy `when`, it writes `gated`, not `built`. A `built` claim in that state is re-proved and written `gated` (it **re-gates**), where it would otherwise be refused as already promoted.
- **V10** runs in `validate` when a staged path is a surface (`--staged`: equal to a line `surfaces` prints, or under it as a directory) or when `--config KEY=VALUE` is given (repeatable; the preview of a change published outside git) — never otherwise. It compares `recorded --rev <merge-base>` with the proposed configuration and judges every eligible `gated`, `built` or `diverged` claim (not frozen) whose `when` keys, or whose subject's `readers` keys, include a changed key:
  - **`gated`, its `when` now satisfied** → the advisory `promote-owed` (non-blocking, though V10 blocks): promote it to `built` once the change is committed. A blocking finding whose only remedy, `promote`, needs that very commit would deadlock.
  - **`built`, its `when` no longer satisfied, and no new ruling** → the blocking finding **`ruling owed`**. Order: commit the ruling first (the direction, `CODE-DIVERGES`, `DOC-STALE` or `RETIRE`), then the configuration change, then `claims promote <id>`, which re-gates the claim.
  - **`diverged`, its non-empty `when` satisfied by the proposed configuration and not by the merge-base's** → the blocking finding **`switches on a diverged claim`**. A ruling does **not** clear it (a diverged claim always carries one): fix the code and promote the claim, or retire it, before switching the configuration on.
- A failing `surfaces` or `recorded` call is indeterminate (check `config`); a failing `readers` call makes the claims it was asked for indeterminate.

## Gates, records and attest

The lifecycle (§E) runs claims at the interception points of `references/spec-lifecycle-protocol.md`. `spec-inject --phase=plan` injects a **Claims gate (chunk N)** task into each chunk, before its spec-update task, and a **Final claims gate** before the finalize tasks; both are run by the orchestrating agent, not a delegated implementer. The task texts are in `references/spec-lifecycle-actions.md`. A target spec advances to `Implemented` only when every claim the plan names for it is `built` (or, with the extension, `gated`) with a passing verdict at the final gate (R5, Spec Status Model).

**`claims gate --plan <p> --chunk <n> [--from <rev>] [--holds <id>… --by <principal>]`** refuses a dirty tree, then at HEAD: runs the claims the chunk's `**Claims:**` lines name plus the `--planes-of <from>..HEAD` selection; checks V8, V8n and V9 over `<from>..HEAD` (every finding blocks); finds every named id no claim has, every named claim still `unbuilt` that no included `DOC-STALE` ruling covers (a `CODE-DIVERGES` ruling must move it to `diverged`, a `RETIRE` to `retired`), and every re-promotion owed (decided by `promotion.proved`, so the same in a fresh clone). `<from>` is `--from`, else chunk `<n-1>`'s recorded head (that record must be one JSON object, as attest reads it; anything else is indeterminate), else the merge-base; it must be an ancestor of HEAD. Every red claim is reconciled before the next chunk starts — fix the code, rule `DOC-STALE` and amend, or defer as `diverged` with a tracker ([Direction protocol](#direction-protocol)).

It writes `docs/spec-claims/gates/<plan-stem>/chunk-<n>.json`, even when red: `{schema: 1, plan, chunk, base, from, head, tree, commits [{sha, patch_id}], claims, verdicts, checks {V8, V8n, V9}, reconciliations, unrecorded, result}`, `result` `red`, `indeterminate` or `pass`. **The record-inclusion rule:** over the sidecar changes from `<from>` to HEAD on the plan's claims and every claim of a doc its Specs list names, a new ruling is included only when its `record` names this record; a new promotion is always included, by its `verdict_sha256` (never by the local store, so every clone agrees); a status change only with an included ruling or promotion. Every change not included is a **silent reconciliation**, a finding.

**`claims attest --plan <p> [--final] [--deep]`** checks the records against the branch at HEAD: every chunk with a gate task has a usable record, its commits matched to `merge-base..HEAD` by `git patch-id --stable` (a rebase keeps them; an unmatched one marks the record `rebased: re-verified`, and its claims are re-run, never a finding); every claim the plan names runs at HEAD (`built`/`gated` passing, `diverged` failing by an assertion with its ruling and tracker; `unbuilt` or a re-promotion owed is a finding); every ruling, promotion and status change since the merge-base appears in a chunk record or in `final.json`'s rebuilt reconciliations (a ruling made at the final gate names `final.json` as its record), and every recorded ruling is still there at HEAD; the amendment batch; `render --check`. `--final` refuses a dirty tree and writes `final.json` — `{schema: 1, plan, base, head, tree, from, chunks [{chunk, record, rebased}], claims [{claim, status, verdict}], reconciliations, cross_check {unrecorded, reverted}, amendments, render_check, result}` — even when it does not pass, so a ruling made at the final gate can cite it. `--deep` re-runs each record's test claims in a throwaway worktree at its head. A plan's move to `Completed` (V12) needs a `final.json` whose `result` is `pass` and whose `head` is HEAD or an ancestor of it, with no later branch commit touching a code path (`code_roots`): a commit after the final gate that touches only non-code paths is doc-only and gate-exempt; merges of the base are not counted.

**`claims rulings --range <a>..<b> [--format json|markdown]`** lists the `DOC-STALE` and `RETIRE` rulings present at `<b>` and absent at `<a>`: the amendment batch, one row each `{claim, doc, direction, by, date, reason, approved {quote, states}, new {quote, states}}`, for the human who reviews docs. `spec-verify --mode=post-execute` reports attest's verdict and includes the batch.

**Ranges** read the branch's own work, never trunk merged in: `git rev-list --first-parent --no-merges`, plus each first-parent merge's own conflict resolutions. `<a>...<b>` means `<merge-base a b>..<b>`; `<a>` must be an ancestor of `<b>`.

**What the records prove.** Records are self-reported. `attest` proves that they are consistent with the tree — the patch ids, the reconciliations, the rulings and promotions, the verdicts re-run at HEAD — not that an agent ran them. The `by` field names a principal; doc-superpowers records it and checks the `record` path, and makes no claim to verify who ruled.

**The dirty-tree check** (`gate`, `promote`, `attest --final`): `git status --porcelain --untracked-files=no`, ignoring `docs/spec-claims/gates/`. Untracked files are not counted, so an untracked file a test happens to read can influence a verdict without dirtying the tree; counting them would refuse every run in a checkout with stray build output.

### Hooks and CI

`references/hooks.md` has the installer, tiers and templates; what each leg judges:

- **Pre-commit** runs `claims validate --staged`: a finding blocks the commit whatever `DOC_SUPERPOWERS_STRICT` says (V1–V6 and V10–V12 are blocking by design); advisories only print; a check that cannot run (exit 2 or 3) prints one line and blocks only under STRICT. `DOC_SUPERPOWERS_CLAIMS_SKIP=1` bypasses that leg alone.
- **Pre-push** is advisory: `claims run --planes-of` over the commits each pushed branch adds (from the merge-base for a new branch, or when the remote oid is not an ancestor), and `claims attest --plan` for each plan with gate records but no `final.json`, once per push, for the first pushed ref at HEAD's commit. **A pushed ref that is not HEAD** has its claims *selected* by that ref's range but *run* against the checked-out tree, which may differ from the ref's.
- **CI, on every same-repository PR (fork and dependabot PRs are not checked)** (`doc-spec-verify.yml`'s `claims` job, which runs only when the PR's head repository is the repository itself and the actor is not `dependabot[bot]`): `claims validate --all`, `claims run --all` and `claims attest --plan <p> --final` for each plan the PR touches, each with `--base <the PR's base SHA>`; findings fail the job; a check that cannot run warns, and fails under `--ci-strict`. The checkout has no verdict store, so promotions count by their stored digest, and V6 compares each changed promoted claim with its `promotion.proved`: a field that differs is a finding (or `re-promote owed` under a covering `DOC-STALE`/`RETIRE`), and `unverifiable-here`, an advisory, only when nothing differs. **The job judges the PR head, not the merged tree:** a claim broken only by later changes on the base surfaces on the next run after the PR is updated or merged, not on this one. **A same-repository PR that deletes a `docs/spec-claims/` present at its base is a finding** (`status=findings`, the job fails): such a PR cannot switch its own check off. A fork PR runs no claims job, so this guard does not stop it either: review a fork PR that touches `docs/spec-claims/` by hand. With `doc-pr-release` installed, the amendment batch goes into a `spec-claims` section at the top of the PR description.
- **Scheduled** (`doc-freshness-schedule.yml`, weekly): `claims run --all --scheduled --judge-sample 3`, `claims promote --reverify --all` and `claims validate --all`; findings keep the audit issue open under `### Spec claims` with the week's judge sample.

## Direction protocol

When a doc and the code disagree — a failing claim, an edit to a claimed quote or `states`, a configuration conflict, a mismatch found by any audit or review — neither side is edited until the direction (`CODE-DIVERGES`, `DOC-STALE`, `RETIRE`) is ruled and recorded on the claim. The protocol, its policy keys and their defaults are defined in **Direction protocol** in `references/spec-lifecycle-protocol.md`; this reference does not repeat them. Mechanically, V6 checks each new ruling's `record` and judges each new `DOC-STALE`/`RETIRE` by config `policy`, and the gate's record-inclusion rule decides which rulings a gate record covers.

## Reference helpers

These are examples, not shipped executables: copy them into the host repo and adapt them. A test binds itself to its claim (a marker, a helper call); the helper reads the sidecars and makes the host's ordinary suite expect what the claim's status says; the adapter reports raw outcomes to `claims run`. The helpers and the adapter agree on one switch, `SPEC_CLAIMS_RAW_OUTCOMES=1`, which the adapter sets and which turns the expected-failure marking off.

**pytest helper** — `conftest.py` at the host's test root. It registers `@pytest.mark.claim("<id>")` and applies `pytest.mark.xfail(strict=True, raises=AssertionError)` to `diverged` claims and `pytest.mark.xfail(strict=True)` to `unbuilt` ones. Import the subject inside the test, not at module level, so an unbuilt subject is an expected failure rather than a collection error (`subject_imports_ok`).

```python
"""Spec-claims helper for pytest: an example from doc-superpowers'
references/spec-claims.md, not a shipped file. Put it in the host's root
conftest.py.

A test binds itself to a claim with @pytest.mark.claim("<DOC-ID>#<slug>").
The host's ordinary suite then expects what the claim's status says:
  diverged  xfail(strict=True, raises=AssertionError): only an assertion
            failure is the expected red; any other error fails, and so does
            a pass (XPASS(strict): the code was fixed, promote the claim)
  unbuilt   xfail(strict=True): any failure is expected; a pass fails
  any other status, or an id no sidecar holds: the test runs as written
The runner adapter sets SPEC_CLAIMS_RAW_OUTCOMES=1, which turns this marking
off: `claims run` needs the raw outcome, and doc-tools judges it by the
status itself.
"""
import json
import os
import pathlib

import pytest

RAW_ENV = "SPEC_CLAIMS_RAW_OUTCOMES"
_STATUSES = {}


def _claims_dir(start):
    for directory in [start, *start.parents]:
        candidate = directory / "docs" / "spec-claims"
        if candidate.is_dir():
            return candidate
    return None


def _load_statuses(claims_dir):
    statuses = {}
    for path in sorted(claims_dir.glob("*.json")):
        if path.name == "config.json":
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue  # a malformed sidecar is V1's finding, not the test run's
        claims = data.get("claims") if isinstance(data, dict) else None
        for claim in claims if isinstance(claims, list) else []:
            if isinstance(claim, dict) and isinstance(claim.get("id"), str):
                statuses[claim["id"]] = claim.get("status")
    return statuses


def pytest_configure(config):
    config.addinivalue_line(
        "markers", "claim(id): binds the test to a spec claim in docs/spec-claims/"
    )
    claims_dir = _claims_dir(pathlib.Path(str(config.rootpath)).resolve())
    if claims_dir is not None:
        _STATUSES.update(_load_statuses(claims_dir))


def pytest_collection_modifyitems(config, items):
    if os.environ.get(RAW_ENV) == "1":
        return
    for item in items:
        for marker in item.iter_markers(name="claim"):
            status = _STATUSES.get(marker.args[0]) if marker.args else None
            if status == "diverged":
                item.add_marker(pytest.mark.xfail(strict=True, raises=AssertionError))
            elif status == "unbuilt":
                item.add_marker(pytest.mark.xfail(strict=True))
```

```python
# tests/test_token.py — a bound test
import pytest


@pytest.mark.claim("SPEC-AUTH-001#token-ttl")
def test_ttl_is_15_minutes():
    from app.token import expired  # inside the test: never at module level

    assert expired(900)
    assert not expired(899)
```

**jest helper** — `claim(id, name, fn)`, CommonJS. `test.failing` exists only under jest-circus, jest's default runner; a host still on `testRunner: "jest-jasmine2"` writes the `unbuilt` inversion out as the `diverged` branch does (any thrown error passes, a pass fails). An assertion is `err.matcherResult !== undefined || err.name === 'AssertionError'` (jest's `expect`, node's `assert`). `unbuilt` wraps `test.failing`. `diverged` keeps `test.failing`'s inversion but not the wrapper: `test.failing` passes on **any** thrown error, so under it a non-assertion error could never fail the test. The helper writes the inversion out instead, and rethrows every non-assertion error.

```js
// Spec-claims helper for jest: an example from doc-superpowers'
// references/spec-claims.md, not a shipped file (CommonJS: require it from a
// test file).
//
//   const { claim } = require('./claim');
//   claim('SPEC-AUTH-001#token-ttl', 'rejects a token after 15 minutes', () => { ... });
//
// The host's ordinary suite then expects what the claim's status says:
//   unbuilt   test.failing: any failure is the expected red; a pass fails
//   diverged  test.failing semantics, assertion failures only: an assertion
//             failure is the expected red, any other error is rethrown and
//             fails the test, and a pass fails (the code was fixed: promote)
//   any other status, or an id no sidecar holds: a plain test
// The runner adapter sets SPEC_CLAIMS_RAW_OUTCOMES=1: every claim is then a
// plain test, so `claims run` sees the raw outcome.
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const RAW_ENV = 'SPEC_CLAIMS_RAW_OUTCOMES';

function claimsDir(start) {
  let dir = path.resolve(start);
  for (;;) {
    const candidate = path.join(dir, 'docs', 'spec-claims');
    if (fs.existsSync(candidate) && fs.statSync(candidate).isDirectory()) return candidate;
    const parent = path.dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

function loadStatuses(dir) {
  const statuses = new Map();
  if (dir === null) return statuses;
  for (const name of fs.readdirSync(dir).sort()) {
    if (!name.endsWith('.json') || name === 'config.json') continue;
    let data;
    try {
      data = JSON.parse(fs.readFileSync(path.join(dir, name), 'utf8'));
    } catch {
      continue; // a malformed sidecar is V1's finding, not the test run's
    }
    const claims = data !== null && typeof data === 'object' && Array.isArray(data.claims) ? data.claims : [];
    for (const c of claims) {
      if (c !== null && typeof c === 'object' && typeof c.id === 'string') statuses.set(c.id, c.status);
    }
  }
  return statuses;
}

const STATUSES = loadStatuses(claimsDir(process.cwd()));

function isAssertion(err) {
  return err !== null && typeof err === 'object'
    && (err.matcherResult !== undefined || err.name === 'AssertionError');
}

function claim(id, name, fn) {
  const status = process.env[RAW_ENV] === '1' ? undefined : STATUSES.get(id);
  if (status === 'unbuilt') {
    test.failing(name, fn);
  } else if (status === 'diverged') {
    // Not test.failing: it passes on any thrown error, so it could not let a
    // non-assertion error fail the test. The inversion is written out.
    test(name, async () => {
      try {
        await fn();
      } catch (err) {
        if (isAssertion(err)) return; // the expected red
        throw err; // an error is never an expected red
      }
      throw new Error(`${id} is diverged, but its test passes: the code now does what the claim states (claims promote ${id})`);
    });
  } else {
    test(name, fn);
  }
}

module.exports = { claim, isAssertion };
```

**pytest runner adapter (skeleton)** — `list` is a static scan (`grep -n`) for the marker plus `def test_`, never a collection. `run` is `pytest --junitxml`: a `failure` whose exception type is `AssertionError` is `assert-fail`, any other failure or an `error` is `error`, a module that fails to import (collection failure) is `error`, a skipped test is `indeterminate`, and a missing interpreter or environment is `indeterminate` `env-missing`. pytest's JUnit XML carries no `type` attribute on a failure, so the type is read from the last line of the long traceback (`<file>:<line>: <Type>`). `edited-bound-tests` maps the change's hunks onto the bound tests' spans.

```python
#!/usr/bin/env python3
"""A pytest runner adapter for doc-superpowers spec claims: a skeleton from
references/spec-claims.md (Adapter contracts), not a shipped file. Copy it into
the host repo, make it executable, edit the host settings below, and name it in
docs/spec-claims/config.json:

  "runners": {"pytest": {"adapter": "tools/spec-claims/pytest-adapter",
                         "paths": ["src/", "tests/"]}}

doc-tools calls it from the repo root, stdin /dev/null:
  list [<file>...]                     a static scan (grep -n), never a collection
  run --root <dir> <node>...           pytest --junitxml in <dir>
  edited-bound-tests --staged | <range>
Its stdout is the contract's JSON lines (or ids) and nothing else: pytest's own
output goes to stderr. A non-zero exit makes every requested node indeterminate.

Bound tests are module-level functions: a column-0 @pytest.mark.claim("<id>")
decorator line (the id on that line) above a column-0 `def test_...`. A test's
span ends at the next column-0 line, so a multi-line string whose continuation
line starts in column 0 cuts it short: edited-bound-tests misses an edit below
that line.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

# --- Host settings: edit these -------------------------------------------------
TEST_ROOTS = ("tests/",)            # what the host's test gate runs (in_gate)
SUBJECT_PACKAGES = ("app",)         # a module-level import of one: subject_imports_ok false
VENV_PYTHON = ".venv/bin/python"    # tried under --root, then here; else $PYTHON, else python3
RAW_ENV = "SPEC_CLAIMS_RAW_OUTCOMES"  # the helper's switch: raw outcomes, no xfail

# Every column-0 line that is not a comment or a closing bracket: the scan's
# grep -n pattern. Each such line ends the test above it.
TOPLEVEL = r"^[^])}[:space:]#]"
CLAIM = re.compile(r"""^@pytest\.mark\.claim\(\s*["']([^"']+)["']""")
SKIP = re.compile(r"^@pytest\.mark\.(skip|skipif)\b")
TEST_DEF = re.compile(r"^(?:async\s+)?def\s+(test_\w+)\s*\(")
IMPORT = re.compile(r"^(?:from\s+([\w.]+)\s+import\b|import\s+([\w.]+))")


def grep_lines(text):
    """(line number, line) for each TOPLEVEL line of text: grep -n on stdin."""
    proc = subprocess.run(["grep", "-n", "-E", "-e", TOPLEVEL], input=text.encode("utf-8"),
                          stdout=subprocess.PIPE, check=False)
    if proc.returncode > 1:
        raise RuntimeError("grep failed")
    rows = []
    for raw in proc.stdout.decode("utf-8", "replace").splitlines():
        number, _, line = raw.partition(":")
        rows.append((int(number), line))
    return rows


def scan(text, total_lines):
    """The bound tests of one file's text: {ids, name, first, last, skipped}
    (first..last: the decorator run through the body), and whether the module
    imports a subject package at module level."""
    tests, ids, skipped, first, imports_subject = [], [], False, None, False
    rows = grep_lines(text)
    for i, (number, line) in enumerate(rows):
        match = IMPORT.match(line)
        if match and (match.group(1) or match.group(2)).split(".")[0] in SUBJECT_PACKAGES:
            imports_subject = True
        if line.startswith("@"):
            first = number if first is None else first
            claim = CLAIM.match(line)
            if claim:
                ids.append(claim.group(1))
            skipped = skipped or bool(SKIP.match(line))
            continue
        test_def = TEST_DEF.match(line)
        if test_def and ids:
            last = rows[i + 1][0] - 1 if i + 1 < len(rows) else total_lines
            tests.append({"ids": ids, "name": test_def.group(1), "first": first,
                          "last": last, "skipped": skipped})
        ids, skipped, first = [], False, None
    return tests, imports_subject


def test_names(text):
    return {m.group(1) for m in (TEST_DEF.match(line) for _, line in grep_lines(text)) if m}


def read_file(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def is_test_file(path):
    base = os.path.basename(path)
    return base.endswith(".py") and (base.startswith("test_") or base.endswith("_test.py"))


def cmd_list(files):
    if not files:
        listed = subprocess.run(["git", "ls-files", "-z", "--", *TEST_ROOTS],
                                stdout=subprocess.PIPE, check=True).stdout.decode("utf-8")
        files = [f for f in listed.split("\0") if f and is_test_file(f)]
    for path in files:
        if not os.path.isfile(path):
            continue  # nothing bound there: V3 reports "test not bound"
        text = read_file(path)
        tests, imports_subject = scan(text, len(text.splitlines()))
        in_roots = path.startswith(TEST_ROOTS) and is_test_file(path)
        for test in tests:
            for claim_id in test["ids"]:
                print(json.dumps({"id": claim_id, "node": f"{path}::{test['name']}", "file": path,
                                  "in_gate": in_roots and not test["skipped"],
                                  "subject_imports_ok": not imports_subject,
                                  "when": None}))  # the configuration extension: the conditions the test sets


def find_python(root):
    for base in (root, os.getcwd()):
        candidate = os.path.join(base, VENV_PYTHON)
        if os.access(candidate, os.X_OK):
            return candidate
    return os.environ.get("PYTHON") or shutil.which("python3")


def exc_type(element):
    """A junit failure's exception type: its type attribute when the producer
    writes one, else the last line of pytest's long traceback, '<file>:<line>: <Type>'."""
    if element.get("type"):
        return element.get("type").rsplit(".", 1)[-1]
    lines = (element.text or "").strip().splitlines()
    return lines[-1].rsplit(": ", 1)[-1].strip() if lines else ""


def junit_outcome(case):
    error, failure, skipped = case.find("error"), case.find("failure"), case.find("skipped")
    if error is not None:
        return "error", error.get("message")
    if failure is not None:
        kind = exc_type(failure)
        return ("assert-fail" if kind == "AssertionError" else "error"), failure.get("message") or kind
    if skipped is not None:
        return "indeterminate", "skipped: " + (skipped.get("message") or "")
    return "pass", None


def cmd_run(root, nodes):
    def emit(node, outcome, reason):
        print(json.dumps({"node": node, "outcome": outcome, "reason": reason}))

    python = find_python(root)
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    env[RAW_ENV] = "1"
    if python is None or subprocess.run([python, "-c", "import pytest"], cwd=root, env=env,
                                        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                        stderr=subprocess.DEVNULL, check=False).returncode != 0:
        for node in nodes:
            emit(node, "indeterminate", "env-missing")
        return
    present = []
    for node in nodes:
        path, _, name = node.partition("::")
        name = name.split("[", 1)[0]
        full = os.path.join(root, path)
        if not name or not os.path.isfile(full) or name not in test_names(read_file(full)):
            emit(node, "not-found", None)
        else:
            present.append(node)
    if not present:
        return
    with tempfile.TemporaryDirectory() as tmp:
        report = os.path.join(tmp, "junit.xml")
        proc = subprocess.run([python, "-B", "-m", "pytest", "-p", "no:cacheprovider", "--tb=long",
                               "--junitxml", report, "--", *present],
                              cwd=root, env=env, stdin=subprocess.DEVNULL, stdout=sys.stderr, check=False)
        if not os.path.isfile(report):
            for node in present:
                emit(node, "indeterminate", f"pytest exit {proc.returncode}, no junit report")
            return
        cases = {}
        for case in ET.parse(report).getroot().iter("testcase"):
            cases[(case.get("classname") or "", case.get("name") or "")] = case
    for node in present:
        path, _, name = node.partition("::")
        module = re.sub(r"\.py$", "", path).replace("/", ".")
        case = cases.get((module, name))
        if case is not None:
            emit(node, *junit_outcome(case))
        elif ("", module) in cases:  # pytest reports a module that failed to import this way
            emit(node, "error", "collection failure")
        else:
            emit(node, "error", f"no result in the junit report (pytest exit {proc.returncode})")


def changed_lines(diff):
    """The new-side lines of a -U0 diff's hunks; a pure deletion marks the
    lines on either side of it."""
    lines = set()
    for match in re.finditer(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", diff, re.M):
        start, count = int(match.group(1)), int(match.group(2) or "1")
        lines.update(range(start, start + count) if count else (start, start + 1))
    return lines


def cmd_edited(arg):
    if arg == "--staged":
        diff_args, rev = ["--cached"], ""
    else:
        diff_args, rev = [arg], (arg.split("...", 1) if "..." in arg else arg.split("..", 1))[-1] or "HEAD"
    names = subprocess.run(["git", "diff", "--name-only", "-z", "--no-renames", "--diff-filter=AM",
                            *diff_args, "--", *TEST_ROOTS],
                           stdout=subprocess.PIPE, check=True).stdout.decode("utf-8")
    edited = set()
    for path in (p for p in names.split("\0") if p and is_test_file(p)):
        diff = subprocess.run(["git", "diff", "-U0", "--no-color", "--no-ext-diff", *diff_args, "--", path],
                              stdout=subprocess.PIPE, check=True).stdout.decode("utf-8", "replace")
        text = subprocess.run(["git", "show", f"{rev}:{path}"],
                              stdout=subprocess.PIPE, check=True).stdout.decode("utf-8", "replace")
        touched = changed_lines(diff)
        for test in scan(text, len(text.splitlines()))[0]:
            if any(test["first"] <= n <= test["last"] for n in touched):
                edited.update(test["ids"])
    for claim_id in sorted(edited):
        print(claim_id)


def main(argv):
    if argv and argv[0] == "list":
        cmd_list(argv[1:])
    elif len(argv) >= 3 and argv[0] == "run" and argv[1] == "--root":
        cmd_run(argv[2], argv[3:])
    elif len(argv) == 2 and argv[0] == "edited-bound-tests":
        cmd_edited(argv[1])
    else:
        print("usage: pytest-adapter list [<file>...] | run --root <dir> <node>... | "
              "edited-bound-tests --staged|<range>", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```
