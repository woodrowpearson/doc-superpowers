# Work ledger: filing flow and merge-time upkeep — design

**Status:** approved 2026-10-18 (decisions below were the owner's answers in session)
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

## 1. `ledger new --create`

`ledger new --create --title <text> --ledger <id|unassigned> --summary <text> [--sev <value>] [--paths <a,b,…>] [--body-file <file>] [--suggest-contracts [--top N]] [--finalize]`

- Writes `<dir>/<YYYY-MM-DD>-<slug>.md`: `<dir>` is `_lg_init_item_dir`'s (the literal directory of the first `items.globs` entry `<dir>/<pattern>.md`, else `docs/issues`); `<slug>` is init's `lg_stubslug` of the title (lowercase, runs of non-`[a-z0-9]` → `-`, ≤ 50, `item` when empty); a taken name gets `-2` … `-99` (then exit 2). The path must match `items.globs`, else exit 3 naming `--file`.
- Frontmatter, in this order: status (the first `fields.status` name) = `status.open[0]` verbatim; date (first `fields.date` name) = today; severity (first `fields.severity` name) = `--sev` when given; paths (first `fields.paths` name) = `--paths` as a flow list `[a, b]` when given; then `init.stub_defaults` fields the item does not already set (the existing `_lg_init_stub_defaults` reader and quoting); then key, ledger, summary as `new` writes them. Body: `# <title>`, a blank line, then the `--body-file` bytes when given.
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
4. `key-in-pr-body` — the same in the PR body (`--pr`).
`--items` names items explicitly (`found_by: ["named"]`, rank 0), each must resolve to one item (exit 3 otherwise), and then only named items are involved. Archived items never.

### Touched contracts
- A contract is touched by a net-diff file its `defined_in` matches — unless the file matches `upkeep.skip_globs` — or by a `Contract-Change: <id>` line in the range (index contracts only).
- `upkeep.skip_globs` default: `["docs/**", "**/*.md", "**/test/**", "**/tests/**", "**/__tests__/**", "**/*.test.*", "**/*.spec.*", "**/*_test.*", "**/Tests/**", "**/*Tests/**"]`. `upkeep.skip_contracts` default `[]`: ids never proposed (stand-in for #41's grain audit).
- A contract **read** by the range: a non-skipped net-diff file its `read_by` matches, when no non-skipped file its `defined_in` matches is in the diff.

### Proposals
- **Covered**: a touched contract that any involved item already declares in `changes` is proposed to nobody. A read contract any involved item declares in `consumes` likewise.
- **Attribution** of each remaining contract to exactly one involved item: the most item `paths` entries matching the contract's `defined_in` (for a read contract: `read_by`); tie → the most item `paths` entries that are net-diff files; tie → best `found_by` rank; tie → key (else path) order. No involved item → `unattributed_contracts`.
- **changes** proposal per attributed touched contract; evidence: `"diff touches <f> (defined_in of <c>)"` per file (at most 3, then `"… and N more files"`), `"Contract-Change: <c> — <line>"`.
- **consumes** proposals per involved item: (a) each attributed read contract — `"diff touches <f> (read_by of <c>)"`; (b) each contract whose `defined_in` matches a file the item lists in `paths` that the range does not change, and that the item does not declare in `consumes` — `"the item lists <f> (defined_in of <c>), which the range does not change"` — only for items with rank ≤ 2 (`named`, trailers, item-file-edited), never for message-only items.
- Never a value already declared on that side; never a contract in `skip_contracts`.
- Per item: ranked changes (Contract-Change evidence first, then by evidence count, then id), then consumes (a) then (b) the same way; `--top N` (default 3; 0 all) keeps the first N: `total`, `truncated`.
- `declared_untouched`: the item's declared `changes` the range does not touch (informational).
- `link`: the ready line `ledger link <key|path> --changes a,b --consumes c` for the shown proposals (null when none). Never run.

### Output and exits
- JSON: `{"verb":"ledger upkeep","enabled":true,"exit":<rc>,"range":"<a-oid>..<b-oid>","pr":null|{"number","state","body_scanned"},"files":<n>,"commits":<n>,"items":[{"key","path","found_by":[…],"proposed":[{"field","value","evidence":[…]}],"total","truncated","declared_untouched":[…],"link"}],"unattributed_contracts":[{"contract","files":[…]}]}` (`pr_data` / `items_data` as other verbs add them).
- Text: `range <a12>..<b12>  <n> files, <m> commits`; per item `<key|path>  found by <found_by, comma>`, then `  + <field> <value>  — <evidence joined "; ">` per proposal, `  (showing N of M; --top 0 shows all)`, `  declared, untouched: a, b`, `  link: ledger link …`; then `unattributed: <c> (<files>)` lines; `(no proposals)` when no item has one.
- Exit 0 (proposals are advisory); 1 only with `--strict` and at least one proposal; 2: range/base not resolving, contracts adapter failing, `--pr` without `adapters.pr` or the adapter failing, PR not usable, `--no-repo-adapters` refusing; 3 usage (neither or both of `--range`/`--pr`, a bad `--top`, an unresolved `--items`).
- Cost: one index build (contracts needed), one `git diff`, one `git log`.

## 5. `validate --pushed` advisory

`validate --pushed <a>..<b>` adds the class **`undeclared-contract-change`** (advisory, in `cas` and `merge` modes): for the range (all-zeros `<a>`: merge-base(config base, b)..b), upkeep's involved items and touched contracts; one finding per touched contract no involved item declares in `changes`, only when the range involves at least one item: `{class, severity: "advisory", path: <first file>, key: <attributed item's key or null>, detail: "<f> changes <c>, which no item this push involves declares (changes): ledger upkeep --range <a>..<b> proposes the link"}` — `"<f> and N more change <c>, …"` for several files, `"a Contract-Change line changes <c>, …"` (path null) for a Contract-Change line alone; at most 10, then one finding `"… N more contracts"`. The base's own changes never count (ruling R22): with a non-zero `<a>`, a touched contract's file counts only when it also differs between merge-base(config base, b) and b (a base merged into the branch brings the base's changes into `<a>..<b>`); a contract left with no file and no Contract-Change line is dropped; with no base or no merge base, nothing is filtered. A contracts adapter failure is one advisory finding of the class (`"could not check: <message>"`), never exit 2. The pre-push leg is unchanged: advisories exit 0.

## 6. review-pr ledger leg

SKILL.md `review-pr` adds step 9, **Ledger declarations** (read-only), on a ledger host (`docs/ledger/config.json`), not in a CI run: `"$DOC_TOOLS" ledger upkeep --range "$BASE...HEAD" --no-repo-adapters --format json`. Exit 0: per item its proposals and `link` line (printed, never run), `unattributed_contracts` as a note; nothing proposed → "Ledger declarations: none missing". Exit 2: the section says "could not run: <error>" (a `--no-repo-adapters` refusal: "skipped: <adapter> is a repository script — run `ledger upkeep --range <base>...HEAD` yourself"), never "none missing". It edits nothing: `git status --porcelain` stays empty.

## Acceptance

- Unit tests in `scripts/test-ledger.sh` for every rule above (bash 5 and 3.2).
- Abundance-mvp (a throwaway clone, deleted afterwards): `new --create` + suggest + link end to end against its real config; `upkeep` replayed over the 50 most recent merged PRs; recorded: precision proxy (proposals the item declares at `origin/main` now), median proposals per PR, run time. #39's targets (precision ≥ 0.6, median ≤ 2) are the goal; the measured numbers are reported as they are.
- review-pr on a ledger host prints the section and leaves `git status --porcelain` empty.

## Out of scope

Writing relations automatically (#40), static import analysis, notices urgency, CI templates running upkeep, a `ledger file` doc-tools verb, hosted-item `--create`.
