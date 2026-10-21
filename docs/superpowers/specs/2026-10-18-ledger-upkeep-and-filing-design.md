# Work ledger: filing flow and merge-time upkeep — design

**Status:** approved 2026-10-18 (decisions below were the owner's answers in session); amended 2026-10-20 (D7 precision, D8 `ledger declare`)
**Issues:** #36 (row 1, *Filing wrapper*), #39 (*Merge-time upkeep*). Builds on v3.4.0 (`suggest`, multi-value `link`, `validate.require_relations`).

## Problem

1. **Filing.** v3.4.0 documents `new → suggest → confirm → link` but ships no wrapper: a host without its own (abundance's `/file-issue` is host-specific) must hand-write the item file — the right directory, its status vocabulary, its severity and paths field names, `init.stub_defaults` — before `ledger new` can run, and then script the confirm step.
2. **Upkeep.** Declarations drift as code moves: a fix that edits a contract's `defined_in` usually lands without `changes` naming it; readers are rarely declared `consumes`. `recheck_after` only fires for declared contracts. The PR is where the diff and the author meet, so the comparison runs there (#39 has the evidence and the existing pieces).

## Decisions (owner, 2026-10-18)

| # | Question | Decision |
|---|---|---|
| D1 | What ships upstream for filing | **A verb option + a skill flow.** `ledger new --create` writes the item file itself; `/doc-superpowers ledger file` is the agent procedure create → suggest → confirm → link. |
| D2 | #39 Q1/Q2 — which signals make an item involved | **Range-only**: claim trailers, item files the range edits, keys/aliases as words in commit messages (and the PR body with `--pr`). No in-flight branch claims, so every host and claude.ai/code see the same result. Disagreeing signals: every item is reported with its `found_by`; each contract is attributed to one item (rules below). |
| D3 | #39 Q3 — review-pr leg vs "never run repository scripts" | **Run it, guarded.** review-pr runs `ledger upkeep --no-repo-adapters`; that flag makes upkeep refuse (exit 2, nothing run) when `adapters.contracts`, `adapters.pr` or `items.adapter` is anything but `null` or `doc-superpowers:<name>`. review-pr then prints a skipped section with the command for the user. Local only: in a CI workflow the step is skipped (the vendored copy carries no ledger; a CI job may run upkeep itself and post it). |
| D4 | #39 Q4 — reader signal | **Registry `read_by` globs**: an optional per-contract list, also accepted from the contracts adapter's `list` lines (registry wins when non-empty, as for `defined_in`). |
| D5 | #39 Q5 — propose `relates: depends-on:` between two involved items | Declined for now: no measured need; recorded on #39. |
| D6 | A host config that writes `"base": null` explicitly (found while reviewing the abundance install, 2026-10-19; abundance-mvp has no `base` key) | **Null means the default** (`origin/main`), fixed in config.jq: upkeep's all-zeros and open-PR ranges read `base`, and a null base today reads as `""` — `validate --pushed` from all zeros refuses every provisional key at a new branch's tip, `publish` dies. Not a decision of the owner's; proposed with the plan. |
| D7 | (2026-10-20, after the abundance replay: 3 of 22 default proposals plausible) Ship upkeep as measured, or fix precision first | **Fix precision before merge.** The two rules that produce most misses change (§4 *Touched contracts*, *Proposals*), and with them the push advisory (§5), which shares *Touched contracts*. Acceptance moves from the later-declared proxy, which cannot score on a host three days after adoption, to a blind judgment of each proposal (*Acceptance*). |
| D8 | (2026-10-20) Nothing in doc-superpowers writes an existing item's relations as code moves: upkeep proposes, nobody confirms | **A confirm-and-link skill flow**, `/doc-superpowers ledger declare` (§7): upkeep's proposals for a range, one question round, one `ledger link` per item for what the person confirms. Attended only; unattended callers stay #40's. |
| D9 | (2026-10-20, owner) A spec change leads the code change, or both are in sync at merge — must upkeep propose spec and ADR amendments? | **Yes, to the item that owns the amendment.** An edit to a spec's or ADR's own document changes it; the owner comes from the amendment's pointers (the plan it cites and the items that plan links; the claim trailers of the commits that edit it), and a citation that resolves to no item is listed, never guessed (§4). An item linked by a plan the range edits is involved (`plan-link`). |

## 1. `ledger new --create`

`ledger new --create --title <text> --ledger <id|unassigned> --summary <text> [--sev <value>] [--paths <a,b,…>] [--body-file <file>] [--suggest-contracts [--top N]] [--finalize]`

- Writes `<dir>/<YYYY-MM-DD>-<slug>.md`: `<dir>` is `_lg_init_item_dir`'s (the literal directory of the first `items.globs` entry `<dir>/<pattern>.md`, else `docs/issues`); `<slug>` is init's `lg_stubslug` of the title (lowercase, runs of non-`[a-z0-9]` → `-`, ≤ 50, `item` when empty); a taken name gets `-2` … `-99` (then exit 2). The path must match `items.globs`, else exit 3 naming `--file`.
- Frontmatter, in this order: status (the first `fields.status` name) = `status.open[0]` verbatim; date (first `fields.date` name) = today; severity (first `fields.severity` name) = `--sev` when given; paths (first `fields.paths` name) = `--paths` as a flow list `[a, b]` when given; then `init.stub_defaults` fields the item does not already set (the existing `_lg_init_stub_defaults` reader and quoting), never `relations` (ruling R26, from the abundance trial: relations are `link`'s to write — filing step 6, or `--relations none` — so `validate.require_relations` still catches a filing that skips that step; `init --accept`'s stubs keep the default); then key, ledger, summary as `new` writes them. Body: `# <title>`, a blank line, then the `--body-file` bytes when given.
- **All or nothing.** The key is allocated before the file exists (the path is computed first: a provisional key's hex comes from it), and the file is written once, complete. Any exit ≠ 0 leaves no file.
- Usage (3): `--create` with `--file`; `--title`, `--sev`, `--paths` or `--body-file` without `--create`; an empty or multi-line `--title`; a `--body-file` that is not a readable file; `--create` with `items.adapter` set ("hosted items: create the issue through the adapter"); `--sev` not in `severity_order` when `severity_order` is non-empty.
- Output: text `created <path>` then `new`'s line; JSON `new`'s payload plus `"created": true` (absent without `--create`).

## 2. `/doc-superpowers ledger file [<title>]` (skill flow)

SKILL.md's `ledger` action gains one skill-level sub-action (not a doc-tools verb), detailed in `references/ledger.md` → *Building on the ledger* → **Filing an item**:

1. Inert check (`ledger: not enabled` → offer init's ledger step; stop).
2. Duplicates first: `ledger find <title words> --format json`; show the top matches and ask whether the work is already tracked (if so: `ledger note`, stop).
3. Ask (one question round, the client's question tool): title, summary (≤ 140), ledger (the active ids and scopes from `docs/ledger/ledgers.json`, or `unassigned` — never inferred from the text), severity (`severity_order`), related files, body.
4. `ledger new --create … --suggest-contracts --format json`; exit 2 → report it, nothing was written; 3 → fix the line.
5. Show `candidates` (when `truncated`, say "N of total" and offer `suggest --top 0`) and `ledger related <key> --format json` candidates; the user confirms (multi-select) by *Declaring relations*.
6. One `ledger link <key> --consumes … --changes … --relates …`, or `ledger link <key> --relations none` (+ `ledger note <key> "<why>" --kind ruling` when the user gives a reason).
7. Report path, key (provisional: `finalize` once connected), relations. Never commits unless asked.

The *Example: a filing wrapper* script switches to `--create`.

## 3. Contract `read_by`

- Registry `contracts[].read_by`: optional list of globs (glob grammar), the files that read the contract. `validate --registry` reports a non-list (`shape`) and bad globs as for `defined_in`.
- Contracts adapter `list` lines may carry `"read_by": [globs]` (validated like `defined_in`; absent → `[]`).
- Index `contracts[]` gains `read_by` (always a list; registry's when non-empty, else the adapter's). Schema updated.
- Read by `upkeep` only (no other verb's output changes).

## 4. `ledger upkeep`

`ledger upkeep (--range <a>..<b> | --range <a>...<b> | --pr <n>) [--items <item>…] [--top N] [--strict] [--no-repo-adapters] [--format text|json]`

### Range
- `<a>..<b>`: as given; `<a>...<b>`: merge-base(a, b)..b. Either end not resolving: exit 2.
- `--pr <n>` (needs `adapters.pr`, else exit 2): the PR from the adapter's list (cached, as other verbs). Merged with `merge_commit` here: `merge-base(<merge_commit>^1, head_oid)..head_oid` when `head_oid` is here too (the PR's own commits, for any merge strategy), else `<merge_commit>^1..<merge_commit>` — for a rebase merge, its last commit only (ruling R15); open with `head_oid` here: `merge-base(<config base>, head_oid)..head_oid`; closed, unknown, or the commit missing locally: exit 2 with the fetch command. Body: the adapter's optional `view <n>` → `{"number", "body"}`; exit 3 from it = unsupported (no body scan, JSON `pr.body_scanned: false`); any other failure: exit 2. The reference `ledger-pr-gh` gains `view`.

### Involved items (D2), each with `found_by` (ordered by this rank)
1. `trailer:claims` / `trailer:claims_by_path` / `trailer:claims_by_ref` — `_lg_msg_claims "<a>..<b>"` lines (honouring `trailers.since`).
2. `item-file-edited` — net-diff files that are index items.
3. `key-in-message` — a key or alias of an item as a word in a commit message of the range (the sweep word scan).
4. `plan-link` — an item that a plan the range adds or modifies **links** (*Proposals* → *Document-defined contracts* defines it: an `include` Related work row or a frontmatter value naming the item) (D9). In-flight claims read plans the same way with a looser link (any key word); upkeep keeps the strict one — one host plan names 286 keys.
5. `key-in-pr-body` — the same in the PR body (`--pr`).
Items with no other signal that a document-defined contract's cited plan links are involved too, `plan-cited` (*Proposals*), ranked with `key-in-message`; an item its other pointer reaches — a claim trailer of a commit that edits the document — is always found by that claim trailer already (signal 1 reads every commit of the range).
`--items` names items explicitly (`found_by: ["named"]`, rank 0), each must resolve to one item (exit 3 otherwise), and then only named items are involved. Archived items never.

### Touched contracts
- A contract is touched by a net-diff file its `defined_in` matches — unless the file matches `upkeep.skip_globs` — **when a changed line of that file names the contract** (D7), or by a `Contract-Change: <id>` line in the range (index contracts only). Without the name test, any edit to a file that defines many contracts touched all of them: 30 of 41 `changes` in the abundance replay named a contract no changed line mentions.
- **Names.** A changed line is an added or removed line of `git diff -U0 --no-renames <a> <b> -- <file>` (not a header or context line). It names `<kind>:<name>` when `<name>` (the id after the first `:`) occurs in it case-sensitively with no `[A-Za-z0-9_]` immediately before or after; a `*` in `<name>` matches any run of `[A-Za-z0-9_.-]`. A contract whose id the code never spells (a component, a pattern) is reached by a `Contract-Change:` line — the documented way to declare such a change. The name test is the one rule a code-model adapter could later replace with "a symbol defining the contract changed"; nothing here depends on one.
- **Document-defined contracts** (D9). A contract is document-defined when its `defined_in` is one literal markdown path — one entry, ending in `.md`, with no glob metacharacter (`*`, `?`, `{`, `}`, `\`) — that no other contract's `defined_in` names or matches (a spec, an ADR; ruling R65). It is touched by any net-diff edit of that document, `upkeep.skip_globs` notwithstanding, with no *Names* test: the document is the contract. Evidence `"diff amends <doc> (defined_in of <c>)"`. Otherwise — a glob, or a document two contracts share — the *Names* test applies as for any contract (and `skip_globs` with it): one edit of a shared document would otherwise touch every contract it holds.
- `upkeep.skip_globs` default: `["docs/**", "**/*.md", "**/test/**", "**/tests/**", "**/__tests__/**", "**/*.test.*", "**/*.spec.*", "**/*_test.*", "**/Tests/**", "**/*Tests/**"]`. `upkeep.skip_contracts` default `[]`: ids never proposed (stand-in for #41's grain audit).
- A contract **read** by the range: a non-skipped net-diff file its `read_by` matches with a changed line naming it, when the range does not touch it.

### Proposals
- **Covered**: a touched contract that any involved item already declares in `changes` is proposed to nobody. A read contract any involved item declares in `consumes` likewise.
- **Attribution** of each remaining contract to exactly one involved item: the most item `paths` entries matching the contract's `defined_in` (for a read contract: `read_by`); tie → the most item `paths` entries that are net-diff files; tie → best `found_by` rank; tie → key (else path) order. No involved item → `unattributed_contracts`. **An item the range adds** (its file is added in the net diff) **that no claim trailer names** — nor `--items`, the person's own statement of ownership, as a trailer is (ruling R63) — is a candidate only when the range involves no other item — none but items like it (D7): a PR that files follow-up items otherwise hands its own contracts to them — 47 of the replay's 117 judged proposals were the right contract on the wrong item, nearly all on follow-ups filed in the PR.
- **Document-defined contracts** (D9): the owner comes from the amendment's pointers, before the normal order.
  1. **Pointers.** (a) The items each plan the document's changed lines name **links** — a plan is a doc of a `doc_columns.plan` type (or matching its globs) — found as in-flight finds one: a `.md` file in the directory of such a doc-index entry, so a plan the range adds counts before the doc-index lists it — named by its path; it links an item when a `## Related work` row marked `include` names it (key, alias or path, as `sweep --plan` writes), or any frontmatter field's value, or an element of a list value, is its key, an alias or its path — never key words in the body. (b) The items the claim trailers (`trailers.claims`, `claims_by_path`, `claims_by_ref`) of the range's commits that edit the document name.
  2. Pointed items join the candidates, exempt from the added-item rule, ranked right after the `defined_in` count: an item whose `paths` list the document still wins, then pointed before not pointed, then the net-diff count, rank, key. A pointed item with no other signal is involved (`found_by` `plan-cited`; one a trailer points to is `trailer:claims*` already).
  3. **Unresolved.** When the changed lines name a plan and no pointed item results, the contract is listed in `unattributed_contracts` with `"cites": ["<plan>", …]` — never handed to the normal winner.
  4. Otherwise the normal attribution.
  - Evidence: `"diff amends <doc>, which cites <plan> (links <key>)"`, `"<commit12> (<trailer>) amends <doc>"`.
  - Amendments carry plan citations, not keys: 16 of 22 in the replay cite a plan (doc-superpowers' `AMENDED … Landed by <plan>` lines), 1 names a key. A key named in the lines is not a pointer: amendment text often cites other items.
- **changes** proposal per attributed touched contract; evidence: `"diff names <c> in <f> (defined_in of <c>)"` per file (at most 3, then `"… and N more files"`), `"Contract-Change: <c> — <line>"`.
- **consumes** proposals per involved item: (a) each attributed read contract — `"diff names <c> in <f> (read_by of <c>)"`; (b) each contract whose `defined_in` matches a file the item lists in `paths` that the range does not change, **that the item's own text names** (its title, `summary` and body, by the *Names* rule; not its relation lists; a hosted item's text is its excerpt, minus a trailing word the adapter cut (`…`)), and that the item does not declare in `consumes` — `"the item names <c> and lists <f> (defined_in of <c>), which the range does not change"` — only for items with rank ≤ 2 (`named`, trailers, item-file-edited), never for message-only items. The premise is what reads a contract (*Declaring relations*); a listed file merely holds it.
- Never a value already declared on that side; never a contract in `skip_contracts`.
- Per item: ranked changes (Contract-Change evidence first, then by evidence count, then id), then consumes (a) then (b) the same way; `--top N` (default 3; 0 all) keeps the first N: `total`, `truncated`.
- `declared_untouched`: the item's declared `changes` the range does not touch (informational).
- `link`: the ready line `ledger link <key|path> --changes a,b --consumes c` for the shown proposals (null when none). Never run.

### Output and exits
- JSON: `{"verb":"ledger upkeep","enabled":true,"exit":<rc>,"range":"<a-oid>..<b-oid>","pr":null|{"number","state","body_scanned"},"files":<n>,"commits":<n>,"items":[{"key","path","found_by":[…],"proposed":[{"field","value","evidence":[…]}],"total","truncated","declared_untouched":[…],"link"}],"unattributed_contracts":[{"contract","files":[…],"cites"?:[…]}]}` (`cites` only for a document-defined contract whose cited plan links no item; `pr_data` / `items_data` as other verbs add them).
- Text: `range <a12>..<b12>  <n> files, <m> commits`; per item `<key|path>  found by <found_by, comma>`, then `  + <field> <value>  — <evidence joined "; ">` per proposal, `  (showing N of M; --top 0 shows all)`, `  declared, untouched: a, b`, `  link: ledger link …`; then `unattributed: <c> (<files>)` lines; `(no proposals)` when no item has one.
- Exit 0 (proposals are advisory); 1 only with `--strict` and at least one proposal; 2: range/base not resolving, contracts adapter failing, `--pr` without `adapters.pr` or the adapter failing, PR not usable, `--no-repo-adapters` refusing; 3 usage (neither or both of `--range`/`--pr`, a bad `--top`, an unresolved `--items`).
- Cost: one index build (contracts needed), one `git diff --name-status` (the net diff's files and the ones it adds), one `git diff -U0` over the candidate files, one `git log`; with a markdown file in the net diff, the doc-index read once (what a plan is), each plan cited or in the net diff read once, and one `git log <a>..<b> -- <doc>` per document-defined contract's document.

## 5. `validate --pushed` advisory

`validate --pushed <a>..<b>` adds the class **`undeclared-contract-change`** (advisory, in `cas` and `merge` modes): for the range (all-zeros `<a>`: merge-base(config base, b)..b), upkeep's involved items and touched contracts (§4: a changed line names the contract — D7 drops the advisory from 28 contracts to 10 on one abundance push); one finding per touched contract no involved item declares in `changes`, only when the range involves at least one item: `{class, severity: "advisory", path: <first file>, key: <attributed item's key or null>, detail: "<f> changes <c>, which no item this push involves declares (changes): ledger upkeep --range <a>..<b> proposes the link"}` — `"<f> and N more change <c>, …"` for several files, `"a Contract-Change line changes <c>, …"` (path null) for a Contract-Change line alone; at most 10, then one finding `"… N more contracts"`. The base's own changes never count (ruling R22): with a non-zero `<a>`, a touched contract's file counts only when it also differs between merge-base(config base, b) and b (a base merged into the branch brings the base's changes into `<a>..<b>`); a contract left with no file and no Contract-Change line is dropped; with no base or no merge base, nothing is filtered. A contracts adapter failure is one advisory finding of the class (`"could not check: <message>"`), never exit 2. The pre-push leg is unchanged: advisories exit 0. The advisory runs unless config `validate.undeclared_contract_change` (`true`, the default, or `false`) is `false` — then nothing runs: no index, no adapter (ruling R33: on upgrade the pre-push leg went from sub-second to 25–72 s cold on a large host, and `DOC_SUPERPOWERS_LEDGER_SKIP` also drops the provisional-key guard); any other value is one `"could not check: validate.undeclared_contract_change must be true or false"` (never an exit change; `validate --staged` / `--all`, which read the `validate` object, exit 2 on it). It runs offline — `DOC_TOOLS_LEDGER_OFFLINE=1` for the check alone: it reads no PR data, so no `pr` or `items` adapter and no fetch (ruling R31). It is skipped, before any index build or adapter run, for an empty range or a tip config base already holds, which report nothing (rulings R24, R32).

## 6. review-pr ledger leg

SKILL.md `review-pr` adds step 9, **Ledger declarations** (read-only), on a ledger host (`docs/ledger/config.json`), not in a CI run: `"$DOC_TOOLS" ledger upkeep --range "$BASE...HEAD" --no-repo-adapters --format json`. Exit 0: per item its proposals and `link` line (printed, never run), `unattributed_contracts` as a note; nothing proposed → "Ledger declarations: none missing". Exit 2: the section says "could not run: <error>" (a `--no-repo-adapters` refusal: "skipped: <adapter> is a repository script — run `ledger upkeep --range <base>...HEAD` yourself"), never "none missing". It edits nothing: `git status --porcelain` stays empty.

## 7. `/doc-superpowers ledger declare [--range <a>..<b> | --range <a>...<b> | --pr <n>] [--items <item>…]` (skill flow)

The attended confirm-and-link step over `upkeep` (D8). SKILL.md's `ledger` action gains a second skill-level sub-action (not a doc-tools verb), detailed in `references/ledger.md` → *Building on the ledger* → **Declaring after a change**:

1. Inert check (as filing step 1).
2. A person answers it: never in a CI run or for an unattended caller (#40) — there, run `ledger upkeep` and report what it proposes.
3. Range: as given; else `"$BASE...HEAD"` with review-pr step 2's base (`origin/HEAD`, else `origin/main`; not found → ask). `ledger upkeep <range> [--items …] --format json`. Exit 2: report `error` and stop — never "none missing"; 3: fix the line.
4. Nothing proposed (no item proposes, no `unattributed_contracts`): "Ledger declarations: none missing"; stop.
5. Confirm, in one question round (the client's question tool): per item (`key`, `found_by`), its proposals as a multi-select, each `+ <field> <value> — <evidence>`, by *Declaring relations*; the person may add values. `truncated`: say "N of total" and offer the same call with `--top 0`. `unattributed_contracts`: shown, each with its files and any `cites`; for one the person assigns to an item, `ledger link <key> --changes <contract>` for that contract alone — never a re-run with `--items`, which would hand every touched contract to that item.
6. Link: per item with a confirmed value, one `ledger link <key|path> --changes … --consumes …` built from what was confirmed (the payload's `link` line only when every shown proposal was); exit 1: show `problems`, ask again. A rejected proposal is written nowhere; `ledger note <item> "<why>" --kind ruling` when the person gives a reason.
7. Report what was written per item. Never commits unless asked: on a branch, the declarations then land with the change they describe.

Offered from: review-pr step 9 (a section with proposals ends with the command, and the range when it is not the default) and SKILL.md's *Merge-time upkeep* bullet.

## Acceptance

- Unit tests in `scripts/test-ledger.sh` for every rule above (bash 5 and 3.2).
- Abundance-mvp (a throwaway clone, deleted afterwards): `new --create` + suggest + link end to end against its real config; `upkeep` replayed over the 50 most recent merged PRs; recorded: precision proxy (proposals the item declares at `origin/main` now), median proposals per PR, run time. #39's targets (precision ≥ 0.6, median ≤ 2) are the goal; the measured numbers are reported as they are.
- **Precision (D7).** The later-declared proxy cannot score a host days after adoption (upkeep never proposes what is declared, and nothing declared the proposals afterwards). The measure is a blind judgment: the replay's real `--top 0` proposals, each with its PR, item, evidence and diff hunks, labelled `correct`, `wrong-item`, `wrong` or `unsure` by two judges who never see the rule that produced it, against *Declaring relations*. Precision = correct / (correct + wrong + wrong-item), per judge; both ≥ 0.6, agreement reported. On the simulated rules (2026-10-20): today's 0.25 / 0.22 over 65 proposals; this section's rules 0.71 / 0.64 over 14 (agreement 109 of 117) — a small sample, two PRs carrying most of it. Spec and ADR amendments (D9), on the same replay with the new pairs judged blind by two more judges (agreement 23 of 23): 0.45 / 0.42 with the normal attribution; 0.78 / 0.74 over 23 with the pointers and `plan-link`, no amendment to a wrong item — 8 of the 19 judged amendments reach their owner, 11 are listed unattributed because the host's plan records its item in a field of its own (the host names the item instead).
- review-pr on a ledger host prints the section and leaves `git status --porcelain` empty.
- `ledger declare`: the flow's steps are pinned in `test-spec-status-model.sh`; links only what was confirmed.

## Out of scope

Writing relations automatically (#40), static import analysis, notices urgency, CI templates running upkeep, a `ledger file` or `ledger declare` doc-tools verb, hosted-item `--create`. Measured and left out (D7, D9): a key named in an amendment's lines as a pointer (it moved no judged proposal, and amendment text often cites other items); resolving a host's own plan frontmatter fields (`ledger:` + `ledger-row:`) through the legacy map — the host names the item in its plans instead; counting any edit to a file that defines a single contract (0.20 / 0.10); ranking named contracts first instead of filtering (0.11 / 0.07). In-flight notices keep the file-grained rule.
