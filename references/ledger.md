# Work Ledger — `doc-tools.sh ledger`

**Read by** SKILL.md — **REQUIRED** when `docs/ledger/config.json` exists (the `init` ledger step, `spec-inject --phase=plan`, the `hooks` ledger sets, `review-pr`'s ledger step, the filing flow `/doc-superpowers ledger file`), by anyone wiring the ledger into a host, and by authors of skills and scripts built on it (*Building on the ledger*). `$DOC_TOOLS` is the `doc-tools.sh` SKILL.md's *Detect Bundled Tooling* resolved. `doc-tools.sh help ledger <verb>` (or `ledger <verb> --help`) prints each verb's own usage; this page is the reference those lines point to. The design record is `docs/superpowers/specs/2026-10-12-work-ledger-design.md`.

The work ledger keeps work items as issues — markdown files (default `docs/issues/*.md`) or a hosted tracker's issues reached through an adapter — and derives everything else from them: a stable key per item, ledger pages and one HTML file generated from the items, related work through named *contracts*, and the work in flight on other branches and machines. **The issue is the only source of truth**: no row, view or cache is ever edited by hand, so nothing can disagree with an item.

## Turning it on — the inert contract

The ledger is opt-in. `docs/ledger/config.json` turns it on; `{}` is a complete config (every key has a default, below). Without it:
- every verb except `init` prints one line, `ledger: not enabled (no docs/ledger/config.json)` — with `--format json`, `{"verb":"ledger <sub>","enabled":false,"exit":0}` — and exits 0;
- a hook mode (`notices --hook`, `state-watch --hook`) prints nothing and exits 0;
- `init`, which bootstraps a repository, runs on the default config (`{}`), and every object it prints says `"enabled": false` until a config exists.

The order of the checks: the options are parsed first (an unknown option still exits 3), then the repository (outside a git work tree, or below its top level, exit 2), then the config — before any argument is read. Run `$DOC_TOOLS ledger …` from the repository's top level, like every `doc-tools.sh` subcommand.

The verbs live in `scripts/ledger/` beside `doc-tools.sh` (a `lib.sh` that sources thirteen modules, and the `*.jq` / `*.awk` programs they run). A copy of `doc-tools.sh` without that directory beside it exits 2 for an enabled ledger: see *Vendored copies* below.

Requirements: bash 3.2 or later, `jq` ≥ 1.6, git — nothing else. `gh` (the GitHub CLI, authenticated) only for the two reference adapters; a git remote only for key allocation in `cas` mode, the in-flight layer and `publish`; `open` / `xdg-open` only for `view --open`.

## Output and exit codes

Text is the default output (it is what agents read, and the token budget is the point). `--format json` prints exactly one object, `{"verb":"ledger <sub>","enabled":true,"exit":<rc>, …payload}`. The index the verbs read — and the item objects `show`, `ls` and the views carry — has the shape in `references/ledger-index.schema.json` (`ledger-index/1`; derived and cached, never committed).

The ledger verbs share the `claims` verbs' exit family, not the rest of `doc-tools.sh`'s:

| Exit | Meaning |
|---|---|
| `0` | ok (inert included) |
| `1` | findings: a blocking check failed, an unknown item, `notices --gate` with an unacked `stop` |
| `2` | could not run: a missing or failing adapter, an unreachable remote where one is needed, a base that does not resolve, an invalid config, `scripts/ledger/` not beside `doc-tools.sh`, an internal failure — never reported as clean, never `1` |
| `3` | usage: an unknown option, a missing argument, an ambiguous item (`show` naming several), a bad value the verb checks itself |

When several apply, `1` wins over `2`, and `2` over `0`. A caller routes on all four: `2` is never green.

## Files

| Path | Written by | What |
|---|---|---|
| `docs/ledger/config.json` | the host (`init --accept` writes `{}` when absent) | the switch and the settings (*Config*) |
| `docs/ledger/ledgers.json` | the host (`init --accept` installs the accepted proposal) | the registry of ledgers (*Registry*) |
| `docs/ledger/ledgers.proposed.json` | `init --report` without a registry | a registry proposal for the host to edit; never read as the registry unless named with `--registry` |
| `docs/ledger/legacy.json` (config `legacy`) | `init --accept`, once | the map from hand-written ledger rows to items (*Legacy map*) |
| `docs/ledger/finalized.json` | `new --finalize`, `finalize` | provisional key → allocated key (*Keys*) |
| item files (`items.globs`) | the host; `new`, `assign`, `link`, `note`, `finalize`, `init --accept`, `init --import` write fields | the items |
| `<report>`; `<report>.decisions.tsv` (+ `.bak`) | `init --report`; the decisions file only when the run has a registry | the bootstrap report and the assignment decisions (*Bootstrapping*) |
| `<git common dir>/doc-superpowers/ledger/` | every verb | the cache: the parse cache, the indexes, the remote cache (PR list, hosted items, in-flight facts), rendered views (`views/`, `publish-dry-run/`), `push.log`. Never committed; safe to delete |
| `keys.counter_ref` on `keys.remote` (default `refs/doc-superpowers/ledger/counters`) | `new`, `assign`, `finalize`, `init --accept` | the key counters |
| `<inflight.ref_prefix>/<host>/<branch>` on `keys.remote` | `inflight --push` (the post-commit leg); pruned by `publish` | other machines' local branches |
| `views.branch` (default `doc-ledger-views`) | `publish` only | the published views, an orphan branch |

The ledger never writes `docs/.doc-index.json`: it reads it (doc types, `deprecated`, `superseded_by`, archive moves).

### Config — `docs/ledger/config.json`

Deep-merged over the defaults: an object merges key by key; an array, a scalar or `null` the host gives replaces the default (so `fields.severity` may be one name where the default is a list), except `base`: a `null` there is the default.

| Key | Default | Meaning |
|---|---|---|
| `schema` | `"ledger-config/1"` | |
| `base` | `"origin/main"` | the comparison base: merge-bases, adoption, `publish`, in-flight "merged"; `null` is the default |
| `items.globs` | `["docs/issues/*.md"]` | the item files (globs: *Globs* below) |
| `items.archive_globs` | `["docs/archive/issues/*.md"]` | archived items: still resolved, never open |
| `items.adapter` | `null` | the items adapter for hosted items (*Adapters*) |
| `fields.<name>` | `key`, `ledger`, `status`, `severity` → `["severity","priority"]`, `date`, `summary`, `changes`, `consumes`, `relates`, `superseded_by`, `owed`, `aliases`, `paths` → `["related-files","code_refs"]` | the frontmatter name of each logical field; a list is tried in order |
| `status.open` / `.fixed` / `.closed` / `.wontfix` | `["open","in progress","draft","triage"]` / `["fixed","resolved","done","completed"]` / `["closed","obsolete"]` / `["won't fix","wontfix","wont-fix","not planned"]` | the status classes, matched on the status value's leading words, any case. A status no class names is in no class |
| `severity_order` | `["P0","P1","P2","P3"]` | sort order |
| `resolution_heading` | `"## Resolution"` | the section a closed or won't-fix item needs |
| `log_heading` | `"## Log"` | where `note` appends |
| `doc_columns.spec` / `.plan` / `.handoff` | `["spec","adr","design-spec"]` / `["plan"]` / `null` | doc-index doc types (or `{"doc_types": […], "globs": […]}`) whose docs link items: the Spec, Plan and Latest-handoff columns. A doc links an item by a markdown link to its path (or a former path) or by its key as a word |
| `keys.mode` | `"cas"` | `cas` or `merge` (*Keys*) |
| `keys.remote` | `"origin"` | the remote for the counter ref, the in-flight refs and branch scans |
| `keys.counter_ref` | `"refs/doc-superpowers/ledger/counters"` | the counter ref (*Keys*; see the claude.ai/code note there) |
| `trailers.claims` | `["Ledger-Claims"]` | trailers whose value names item keys a commit claims |
| `trailers.claims_by_path` | `[]` | trailers whose value names item paths (a host maps its own trailers here) |
| `trailers.claims_by_ref` | `["Fixes","Closes","Resolves"]` | keywords naming a hosted item (`Fixes #12`) |
| `trailers.contract_change` | `"Contract-Change"` | `Contract-Change: <contract-id> — <one line>` |
| `trailers.ack` | `"Ledger-Ack"` | `Ledger-Ack: <notice id> — <clause>` |
| `trailers.since` | `null` | a commit, `"adoption"` or `null` (*In-flight work*) |
| `inflight.enabled` | `false` | the in-flight layer |
| `inflight.ref_prefix` | `"refs/doc-superpowers/inflight"` | where in-flight refs live |
| `inflight.host_id` | `null` | this machine's name in those refs |
| `inflight.max_age_days` | `21` | older tips are skipped, and pruned by `publish` (0 or less: no cutoff) |
| `inflight.pre_push_check` | `null` | a host command run before an in-flight push (*In-flight work*) |
| `inflight.pull_refs` | `""` | e.g. `"refs/pull/*/head"`: PR heads, forks' too, fetched with the in-flight refs |
| `views.branch` | `"doc-ledger-views"` | the branch `publish` writes |
| `views.recent_days` | `14` | how long closed items stay on a page |
| `views.html` | `true` | `publish` renders `ledger.html` too |
| `cache.remote_ttl_minutes` | `10` | how long network-derived data is reused |
| `adapters.pr` / `adapters.contracts` | `null` / `null` | the PR and contracts adapters |
| `state_watch.paths` / `.patterns` | `[]` / `[]` | the state-watch hook (*Hooks*). A write fires it only when it holds one of `patterns`, so `paths` set with no `patterns` (absent, `null`, `[]` or only empty strings) never fires: `validate --all` reports it (class `config`, advisory) and `hooks status` warns where state-watch is installed |
| `validate.require_relations` | `null` | `null` (off) or `"new"`: a new open item must declare its relations — `changes`, `consumes` or `relates` — or opt out with `relations: none` (*Validation*). Any other value, or a `validate` that is not an object, exits 2 in `validate --staged` / `--all` (the modes that read it) |
| `validate.undeclared_contract_change` | `true` | `true` or `false`: whether `validate --pushed` (the pre-push leg) adds the `undeclared-contract-change` advisory (*Merge-time upkeep*), which costs an index build and a run of the contracts adapter per pushed ref. `false` skips it — no index, no adapter — while `cas`'s provisional-key check still runs. Any other value is one advisory there, `could not check: validate.undeclared_contract_change must be true or false`, never a change of the push's exit, and exits 2 in `validate --staged` / `--all` (the modes that read the `validate` object) |
| `init.stub_defaults` | `{}` | frontmatter fields `init --accept` writes into each stub it creates (*Bootstrapping*), and `new --create` into the item it writes (every field but `relations`): `{"<field>": <string \| number \| boolean>}`, in this order; `{today}` in a string is the run's local date (`YYYY-MM-DD`). The stub's own fields win (`status`, `key`, `ledger`, `summary`). A string a YAML loader would read as another type — `true`, `false`, `yes`, `no`, `on`, `off`, `y`, `n` (any case), `null`, `~`, a number such as `007`, `1e3`, `0x1F`, `.5` — is written double-quoted in a file stub, so it stays a string; an empty string is quoted too; a date, `{today}`'s included, stays bare (a date-typed field reads it as one). Give a JSON number or boolean when that type is meant. A field name the parser would not read back (`^[A-Za-z0-9_][A-Za-z0-9_.-]*$`), a `null`, list or object value, a line break, or any `{…}` but `{today}` exits 2 — checked before anything is written, `--dry-run` included. With `validate.require_relations: "new"` already set, an `init --accept` re-run creates stubs with no relations, which the pre-commit leg blocks: add `"relations": "none"` here for that run (it writes the opt-out into each stub; `new --create` never copies `relations`) |
| `upkeep.skip_globs` | `["docs/**", "**/*.md", "**/test/**", "**/tests/**", "**/__tests__/**", "**/*.test.*", "**/*.spec.*", "**/*_test.*", "**/Tests/**", "**/*Tests/**"]` | files whose change never touches or reads a contract in `upkeep` and the `undeclared-contract-change` advisory (*Merge-time upkeep*) |
| `upkeep.skip_contracts` | `[]` | contract ids `upkeep` never proposes and the advisory never reports |
| `legacy` | `"docs/ledger/legacy.json"` | the legacy map |
| `legacy_ids` | `[]` | retired ledger ids: advisory on a modified item, blocking on an added one |
| `legacy_ledgers` | `{}` | `{"<legacy id>": "<file>"}`: the hand-written ledgers `init` reads (when it names any, no other file is read for tables) |

There is no `ledger: none`: an item whose home is undecided says `ledger: unassigned` (the reserved value; it carries no key and keeps surfacing in `validate --all`). A host migrating from a "none" vocabulary maps it to `unassigned`.

### Registry — `docs/ledger/ledgers.json`

```json
{ "schema": "ledger-registry/1",
  "ledgers": [
    { "id": "checkout", "title": "Checkout", "kind": "service", "status": "active",
      "scope": "Cart to confirmed order, client and server.",
      "paths": ["app/checkout/**", "server/orders/**"], "residual_paths": [],
      "contracts": [ { "id": "field:order.total", "defined_in": ["server/orders/model.*"] } ],
      "governing": ["docs/specs/SPEC-PAY-003-checkout.md"] } ] }
```

- `id`: `^[a-z0-9-]{1,16}$`, unique, never `unassigned`. `kind`: `service` | `platform` (a label). `status`: `active` | `retired` — a retired ledger owns no paths and takes no new items; its keys keep resolving.
- `paths` / `residual_paths`: globs owning code (*Globs* below; a leading `!` makes one an exclusion; a residual glob claims only files no ordinary glob does). They power suggestions and in-flight attribution; they never assign an item. `validate --registry` reports a tracked file claimed by two ledgers and, once any ledger declares paths, a tracked file outside `docs/` that none claims.
- `contracts[]`: `{"id": "<kind>:<name>", "defined_in": [globs], "read_by"?: [globs], "title"?}` — ids match `^[a-z][a-z0-9_-]*:[^[:space:]]+$`; a diff touching `defined_in` changes the contract (the file rule: in-flight notices, re-check), while `upkeep` and the push advisory also require a changed line of that file that names the contract (*Merge-time upkeep*). `read_by` (optional, same glob grammar; the index always carries a list) names the files that read it: the reader signal merge-time upkeep uses (`validate --registry` checks it like `defined_in`). Kinds are the host's (`field:`, `endpoint:`, `component:`, `flag:`, `spec:` …).

### Globs

One grammar for `items.globs` / `archive_globs`, the registry's `paths` / `residual_paths` and contracts' `defined_in` / `read_by`. A glob matches a whole path, relative to the top level, byte by byte (a unicode name is matched as its bytes):

| Form | Matches |
|---|---|
| `**/` | zero or more directories (at the start, or after `/`, `{` or `,`) |
| `**` elsewhere | anything, `/` included (`src/**`, `a**b`) |
| `*` | anything within one path segment (never `/`) |
| `?` | one byte other than `/` |
| `{a,b,c}` | one of the alternatives (each may hold globs; braces nest) |
| `\c` | the character `c` itself |

Every other character is itself: `[` and `]` are literal (there are no character classes, so `src/[ab]*` matches only a name that starts with `[ab]`), as are `.` and, outside braces, `,`. An unbalanced `{` or `}` makes the glob invalid (`validate --registry` reports it). In the registry's `paths` / `residual_paths`, a leading `!` makes the glob an exclusion.

### Items

Item frontmatter, read by awk: flat `key: value` scalars (plain, double- or single-quoted), flow sequences `[a, "b c"]` on one line, and block sequences of scalars (`- a`). A nested map, a nested sequence, a block scalar (`|`, `>`) or a multi-line quoted or flow value is a per-key error (`fm_errors`, reported by `validate`); the other keys still parse. An unterminated frontmatter block is an error and none of it is trusted. CRLF, a UTF-8 BOM and fenced `---` in the body are handled; one malformed file never aborts the index.

| Field (logical name) | Required | Meaning |
|---|---|---|
| `key` | once `ledger` names a ledger | `<ledger>-<n>` (regex `^[a-z0-9-]{1,16}-[1-9][0-9]*$`), or a provisional `<ledger>-~<4–8 hex>` |
| `ledger` | on items added after enablement | a registered, active id, or `unassigned` |
| `summary` | on items added after enablement | one line, ≤ 140 characters: why it matters (under 20 is a weak-summary advisory) |
| `status` | — | matched against the status classes |
| `severity` | — | sorted by `severity_order` |
| `changes` / `consumes` | — | contract ids this item's fix changes / its premise depends on |
| `relates` | — | `root-cause:<key>`, `depends-on:<key>`, `sibling:<key>` |
| `relations` | — | `none` (any case) records that the item has no relation to declare: the opt-out `validate.require_relations` reads, written by `link <item> --relations none`. Not a `fields` mapping: the frontmatter key is always `relations`, and any other value is no opt-out (and no finding) |
| `superseded_by` | iff superseded (on a closed-class item) | the replacing item's key |
| `owed` | — | what remains after the code merged (`deploy`, `device pass`) |
| `aliases` | tool-written | prior keys after a re-home |
| `paths` | — | the item's file references (candidates, in-flight attribution) |
| `date` | — | else the date git first added the file, else its mtime |

Superseded, won't-fix and obsolete are testable: superseded = closed class + `superseded_by` + a non-empty resolution section; won't fix = wontfix class + resolution; obsolete = closed class + resolution. Nothing in the ledger adds a status value.

**Derived fields** (the index, never written to the item): `class`, `derived` (first match: `superseded → <key>` · `won't fix` · `closed` · `shipped` · `merged · owed: <owed>` · `in review #<pr>` · `on branch <b>` · `planned` · `spec'd` · `not started`), `docs` (the linked specs, plans, handoffs), `neighbours` (upstream, downstream, siblings), `recheck_after`, `pre_adoption`, `pr`, `inflight`, and `claims`:
- **`claims: {diverged, unbuilt}`** — with spec claims (`docs/spec-claims/*.json`, `config.json` and subdirectories excluded, as the tree the index reads holds them), how many claims that are `diverged` or `unbuilt` name this item as their `tracker`: its path, or its key or an alias (any case) that exactly one item carries. A malformed sidecar adds nothing. `show` prints `claims: <n> diverged · <n> unbuilt`, and the views append ` · claims: …` to the Status column (the HTML a `claims` note), each only when a count is non-zero.

### Legacy map — `docs/ledger/legacy.json`

Written once by `init --accept` (or a host's own migration) and never edited, so citations of a retired hand-written ledger keep resolving:

```json
{ "checkout#14": {"key": "checkout-3"},
  "checkout#15": {"item": "docs/issues/2026-01-02-old-done.md"},
  "checkout#16": {"archived": "docs/archive/ledgers/checkout-ledger.md#row-16"} }
```

Keys are `<legacy id>#<row>`; the legacy id is `legacy_ledgers`' name for the file, else the file stem minus a trailing `-ledger`; `<row>` is the row's `#` cell (digits and an optional letter; leading zeros and case do not matter: `x#07` is row 7) or `n<ordinal>`. A value is the item's key, the item's path (a terminal item needs no key), or the archived anchor of a done row with no item. `show checkout#14`, `show "checkout row 14"`, `show "checkout ledger row 14"` all reach it (`"checkout #14"` only for a letter-suffixed row; with digits alone it is a key).

### Finalized map — `docs/ledger/finalized.json`

`{"<provisional key>": "<allocated key>"}`, one entry per line, keys sorted. `finalize` (and `new --finalize`) write it **before** rewriting the items, so an interrupted run resumes with the same keys; a provisional key already recorded with another key exits 2. A finalized provisional key keeps resolving to its key in `show` and every `<item>` argument, and no later provisional key may repeat one it records.

## Verbs

`<item>` takes what `show` takes: a key or alias (any case, spaced forms `checkout 14`, `checkout #14` included), a provisional key `finalized.json` records, a legacy ref, a path from the top level, or a path stem. Every verb takes `--format text|json`. The one-line synopsis of each is below; `doc-tools.sh help ledger <verb>` has the full rules.

| Verb | Does | Exits beyond 0 |
|---|---|---|
| `show <item> [--refresh]` | one item in ≤ 25 lines: key, ledger, severity, derived status, summary, docs, contracts, relations, neighbours, re-check markers, claims, the first resolution line of a closed item | 1 unknown · 3 ambiguous · 2 `--refresh` failing |
| `ls [--ledger <id>] [--sev <a,b>] [--open] [--status <s>] [--cluster <contract>\|unclustered] [--refresh]` | one line per item, `<key>  <severity>  <status>  <summary>`, by severity then date | 2 `--refresh` failing |
| `find <words>…` | ranked fuzzy match over key, summary, file name, H1, first paragraph (top 15) | — |
| `related <item> [--depth 1\|2\|3]` | confirmed upstream, downstream and siblings, then unconfirmed candidates (≥ 2 shared listed files, a shared spec, a `defined_in` overlap) with reasons | 1 unknown |
| `sweep --plan <plan> \| --files <path>… \| --contracts <id>… \| --keys <item>…` | the planning sweep: a `## Related work` table, `\| Item \| Why related \| Mark \|`, confirmed relations first, then candidates, the Mark column empty | 3 unknown `--contracts` / `--keys` |
| `recheck <item>` | the open items to re-check when `<item>` resolves or its contracts change, each `re-verify \| close as superseded by <item> \| reshape` | 1 unknown |
| `upkeep (--range <a>..<b> \| --range <a>...<b> \| --pr <n>) [--items <item>…] [--top N] [--strict] [--no-repo-adapters]` | the `changes` and `consumes` a range's items are missing, proposed with their evidence and a ready `ledger link` line — never written (*Merge-time upkeep*) | 1 `--strict` and a proposal · 2 a range end or base that does not resolve, a failing contracts adapter, an invalid `upkeep` config, `--pr` without `adapters.pr` or with its list or `view` failing, a PR not usable here, a `--no-repo-adapters` refusal · 3 neither or both of `--range` and `--pr`, a `--range` that is not `<a>..<b>` or `<a>...<b>` or has an empty end, an unexpected argument, a bad `--top` or `--pr`, an `--items` value naming no item (or an archived one) |
| `inflight [--branch <b>[@<host>]] [--fetch] [--push]` | the branches in flight, one line each (*In-flight work*); `--push` publishes this branch's in-flight ref | 1 unknown `--branch` · 2 offline `--fetch`, a refused push · 1 `pre_push_check` refusing |
| `notices [--branch …] [--gate] [--fetch] \| --hook` | stop / heads-up / info notices for a branch (*In-flight work*) | 1 with `--gate` and an unacked `stop` · 2 a base or branch that does not resolve, offline `--fetch`, and with `--gate` an in-flight fetch that failed ("could not verify") |
| `state-watch --hook` | the PostToolUse hook mode (*Hooks*) | always 0 |
| `new --ledger <id\|unassigned> --summary <text> [--file <issue> \| --create --title <text> [--sev <value>] [--paths <a,b,…>] [--body-file <file>]] [--finalize] [--suggest-contracts [--top N]]` | allocate a key and write `key`, `ledger`, `summary` into an issue (default: the one staged or untracked item file without a key); `unassigned` writes no key; prints `<key>  <path>`; `--suggest-contracts` then prints `suggest`'s candidates, `--top` included (writing no relation). `--create` writes the issue itself, once and complete (any exit but 0 leaves no file; the key is allocated from its path first): `<dir>/<YYYY-MM-DD>-<slug>.md` — `<dir>` the literal directory of the first `items.globs` entry `<dir>/<pattern>.md` (else `docs/issues`), `<slug>` the title lowercased with every run of other characters than `a-z0-9` one `-` (≤ 50; `item` when empty), a taken name `-2` … `-99`, and a name another writer takes meanwhile is never replaced (exit 2, nothing written); frontmatter status (`status.open[0]`), date (today), severity (`--sev`), paths (`--paths`, a flow list), the `init.stub_defaults` fields it does not set (never `relations`: `link` writes relations, or `--relations none`), then key, ledger, summary; body `# <title>`, a blank line, the `--body-file` bytes; prints `created <path>` first (JSON `"created": true`) | 3 no single issue, `--top` without `--suggest-contracts`; with `--create`: `--file`, a missing, blank or multi-line `--title`, a `--body-file` that is not a readable file, an empty `--paths` piece, `--sev` outside a non-empty `severity_order`, `items.adapter` set (hosted items), a path `items.globs` do not match (give `--file`); `--title`, `--sev`, `--paths` or `--body-file` without `--create` · 2 allocation failed, every name to `-99` taken |
| `assign <item> <ledger>` | a new key in that ledger; the old key is appended to `aliases` | 1 unknown |
| `link <item> --consumes <c>[,…] \| --changes <c>[,…] \| --relates <kind>:<item>[,…] \| --relations none` | write confirmed relations into the item's lists (any of the three at once, each one value or a comma list — a `--relates` piece is a whole `<kind>:<item>`; one write, one index read). A comma list is split only when the whole value is not itself valid, so a single value — even a contract id holding a comma — is checked as before; blanks around commas are ignored, a repeat counts once, an empty piece is a bad value. `--relations none` writes `relations: none` (the opt-out `validate.require_relations` reads); refused beside another flag or when the item already names a relation; a later link that writes a relation removes it in the same write (JSON `removed`) | 1 a bad value, nothing written |
| `suggest <item> [--top N]` | contracts the item might declare, never written: `changes` candidates are the contracts whose `defined_in` matches a file the item lists; `consumes` candidates the contracts its related items (confirmed neighbours, and the open candidates `related` lists) change or consume; a contract it already declares on that side is left out. Candidates rank by their evidence — the number of reasons, most first — then contract id (then `changes` before `consumes`); `--top N` keeps the first N (default 15, `0`: all), and when some are left out a line says `(showing N of M candidates; --top 0 shows all)`. Ends `confirm with: ledger link <item> --changes a,b --consumes c` naming the shown ones (or `(no contract candidates)`). `new --suggest-contracts` prints the same after its write | 1 unknown · 3 ambiguous or archived, a `--top` that is not a whole number |
| `note <item> <text> [--kind log\|ruling\|owed]` | the one home for item state: `- <date> <text>` under `log_heading`, `- <date> RULING: <text>` under `## Rulings`, or the `owed` field; nothing else in the file changes, nothing is staged; a hosted item goes through its adapter | 1 unknown · 3 several or a blank text · 2 adapter failing |
| `view <ledger\|all> [--md] [--html] [--out <dir>] [--open] [--refresh]` | render the views from the working tree (uncommitted items included) | 2 `--refresh` failing |
| `validate (--staged \| --all \| --plan <plan> [--strict] \| --pushed <a>..<b>) [--registry]`, or `validate --registry` alone | *Validation* | 1 a blocking finding |
| `publish [--dry-run]` | render from the remote base and push one commit to `views.branch` (*Views*) | 2 the branch moved, an adapter failing, offline |
| `finalize [--all]` | replace provisional keys (*Keys*) | 2 remote unreachable (`cas`); the remote's base has commits this one lacks (`merge`) |
| `init --report <file> [--registry <file>] [--sources files,github] \| --accept <decisions.tsv> [--dry-run] \| --import` | *Bootstrapping* | 1 a decision row failing · 2 could not run · 3 usage |

## Keys

Keys are never renumbered or reused. A re-homed item gets a new key and keeps the old one in `aliases`; keys and aliases are globally unique (`validate`).

- **`keys.mode: "cas"`** (the default, for teams that push to one remote). The counter ref on `keys.remote` is a commit whose tree holds one blob, `counters.json`, `{"<ledger>": <next number>}`. Allocation fetches it, writes a commit with the new numbers (and a random nonce) on top, and pushes it with `--force-with-lease=<ref>:<fetched oid>` and `--no-verify`: the remote's ref update is the atomic step, so two allocators never share a number. The loser retries (at most 8 times, 0.1–0.6 s jitter apart, re-reading each time), then exits 2 — never a silent provisional key, since the remote was reachable. The first allocation creates the ref, seeding each ledger after the highest key or alias already on the base and, for `new` and `init --accept`, in the working tree (the run's index), so a key that exists only on this branch or in an uncommitted file is never issued again. A batch (`init --accept`) is one counter commit.
- **Offline: provisional keys.** When the remote cannot be reached (a transport failure) or refuses the push for permission (git's words for a 403, `Forbidden` — capitalised, HTTP's reason phrase — or `Permission denied`; a hook's lowercase "forbidden by policy" refuses the content, and is exit 2, not a provisional key), `new` and `init --accept` give `<ledger>-~<hex>` — the first 4 hex digits of sha256 of the item path, lengthened one digit at a time (8 at most) while the key would repeat a key, an alias, a `finalized.json` key or a key given earlier in the same batch (by path) — with a warning. In `cas` mode the pre-push leg refuses to push a provisional key the branch adds — only the keys it adds since its merge-base with config `base`, for a new branch and for an existing one alike, so a provisional key that came from the base (a new branch forked after it landed, or an existing branch that merged the base since) never blocks it; with no base to compare, every one at a new branch's tip, or every one the range adds; `finalize` (or `new --finalize` on that issue) replaces it once the remote is reachable, and `finalize --all` replaces one the base carries too (the refusal names it). `new --finalize` and `finalize` never fall back: unreachable is exit 2.
- **`keys.mode: "merge"`** (fork-and-PR repositories, whose contributors cannot push to the shared remote). Allocation never touches the network: every new item carries a provisional key, provisional keys may reach the base, and a maintainer runs `finalize` on the base, which numbers them after the highest key in the tree and commits the rewrite in one commit, `ledger: finalize N keys`.
  - **Two maintainers.** Before it writes, `finalize` (and `new --finalize`) fetches the base's branch from its remote — config `base`'s remote and branch, or a local branch's upstream, else `keys.remote`'s branch of the same name — into a private ref, and refuses (exit 2, nothing written) when HEAD lacks its tip: another maintainer's finalize, or merges, landed there. **Pull, then run `finalize` again.** HEAD may be ahead of the remote (merges not yet pushed); it must not be behind. When the remote has no such branch, or `base` is a commit or a tag, there is nothing to compare; when the remote cannot be reached, or with `DOC_TOOLS_LEDGER_OFFLINE=1`, a warning, and `finalize` goes on unchecked.
  - Two finalizers that pass the check within the same moments still race at the push: the loser's push is rejected (non-fast-forward). **Drop your own finalize commit, pull, run `finalize` again, then push** — the commit holds only the rewrite, so drop it with `git reset --hard HEAD~1` after checking that `git log -1` reads `ledger: finalize N keys`. **Never pull over or rebase a finalize commit**: when the two finalizers' new `finalized.json` lines sort apart, a pull merges cleanly — no conflict, and a merge commit runs no pre-commit hook — and a rebase likewise carries the duplicate key through; only `validate --all` reports it (`duplicate-key`; re-home one of the two items with `assign`).
- **`finalize`** rewrites each provisional key in the item's `key` and in every `relates`, `superseded_by` and `aliases` that names it, and adds one line per key to `finalized.json`; nothing else. In `cas` mode it finalizes the provisional keys this branch added (`--all`: every one) in the working tree, committing nothing.

**claude.ai/code sessions.** Its git proxy refuses (HTTP 403) every push under `refs/doc-superpowers/…` — create, force and delete — while under `refs/heads/…` it allows a create, a compare-and-swap, a stale-lease rejection and a force, but refuses deletes. Local hosts allow both. The default `keys.counter_ref` stays under `refs/doc-superpowers/`, so a cloud session cannot allocate: the counter push fails (a transport failure, or a refusal in a permission's words), and `new` gives a provisional key with a warning (`finalize` exits 2). `ledger finalize` on a local clone replaces it; one that reaches the base through a cloud session's PR never blocks another branch's push, and `finalize --all` replaces it there. A host whose sessions run mostly in claude.ai/code has two alternatives:
- `keys.mode: "merge"`, which never touches the network; a maintainer runs `finalize` on the base.
- `keys.counter_ref` under `refs/heads/`, e.g. `refs/heads/doc-superpowers/ledger-counters`. GitHub treats that ref as a branch: every allocation pushes it, so `on: push` workflows run for it — add it to their `branches-ignore`, `doc-audit-update`'s included (its own trigger is `push` with `branches-ignore: [<base>]`) — it shows in branch lists and "Compare & pull request" banners, and branch-protection rules (`**` patterns) and stale-branch bots apply to it.

Deletes under `refs/heads/` are refused there too, so `publish`'s in-flight prune fails from such a session (a note, not a failed publish); `inflight --push` reports the 403 as a permission failure — a `push.log` warning, exit 0.

## Adapters

Executables named in config `adapters.pr`, `adapters.contracts` and `items.adapter`. A value is an absolute path, a path from the top level, or `doc-superpowers:<name>` — `scripts/adapters/<name>.sh` beside the running `doc-tools.sh` (`<name>`: `[a-z0-9_-]+`). They run from the top level with stdin closed. A list prints one compact JSON object per line. A missing or non-executable file, a non-zero exit, or output that breaks the contract is exit 2 for every verb that needs it — never a silent clean — and a visible `—` in the views. An absent adapter is no error: its column shows `—`.

| Adapter | Contract |
|---|---|
| `contracts` | `list` → lines `{"id": "<kind>:<name>", "ledger": "<id>"\|null, "defined_in": [globs], "read_by"?: [globs], "title"?: string\|null}` (`read_by` absent: none; present, it must be a string list); `resolve <id>` → exit 0 / 1. A contract both the registry and the adapter declare is one contract: the registry's `ledger`, `defined_in`, `read_by` and `title` win (an empty registry list leaves `defined_in` and `read_by` to the adapter's). An index built at another commit than the working tree's — `upkeep` with `<b>` ≠ HEAD, a `--pr` whose head is not HEAD, `validate --pushed` of a tip other than HEAD — takes this list from the checked-out tree (the adapter has no revision argument), while the registry's contracts and the items come from that commit. Needed by `show`, `related`, `recheck`, `suggest`, `sweep`, `link`, `view`, `publish` |
| `pr` | `list` → lines `{"number", "head", "state": "open"\|"merged"\|"closed", "url"}`, optional `"cross"` (true: the head is a fork's branch, never resolved through a same-named branch of `keys.remote`) and `"head_oid"` (a merged PR is walked from it when the clone has it, never from its branch; absent: a merged PR adds nothing beyond the base's own claims). `upkeep --pr` reads a merged PR as `merge-base(<merge_commit>^1, head_oid)..head_oid` when the clone has `head_oid` (the PR's own commits, for any merge strategy), else as `<merge_commit>^1..<merge_commit>` — for a rebase merge, its last commit only. Optional `view <n>` → one `{"number", "body"}` (the PR's description, `""` for none; never cached) — `upkeep --pr` scans the body for item keys; exit 3 means "no view" (`"body_scanned": false`), any other failure is exit 2. Reference: `doc-superpowers:ledger-pr-gh` — `gh pr list` for every open PR (it exits 2 rather than truncate at its limit of 1,000) and the 500 newest merged ones, adding `"merge_commit"`; `view` is `gh pr view <n> --json number,body` |
| `items` | `list [--since <ts>]` → lines `{"ref": "<no whitespace>", "url": "<non-empty>", "status": "…", "fields": {…}}`, optional `"title"`, `"body_excerpt"`, `"updated"`, `"closed"` (strings or null; ISO 8601 times), `"labels"`, `"fm_errors"` (string lists); `get <ref>` → one `{"ref", "url", "title", "body", "created", "fields", "labels", "status"}` (`init --import`; exit 3 means "no get"); `write <ref> <field> <value>`; `note <ref> <text>`; `create --title <t> --body-file <f>` → `{"ref", "url"}`. Reference: `doc-superpowers:ledger-items-gh` |

**The PR list and hosted items are cached** for `cache.remote_ttl_minutes`. When the adapter fails, the verbs serve the last copy (one stderr line; `pr_data` / `items_data` in `--format json`; the views' header says `PR data as of <UTC> (<age> old)` or `PR data: —`), and only `--refresh` and `publish` exit 2 (`validate --all` too, for hosted items with no copy at all; `upkeep --pr`, for a PR list with no copy).

**`DOC_TOOLS_LEDGER_OFFLINE=1`** runs neither remote adapter — `pr` (`list`, and `upkeep --pr`'s `view`: `"body_scanned": false`) and `items` — and fetches nothing through the cache or the in-flight refs (for hooks that must not reach the network): a copy past its TTL is served stale, none is `—`, `--refresh` / `publish` exit 2 (`offline: DOC_TOOLS_LEDGER_OFFLINE=1`), a `note` on a hosted item exits 2 (nothing written), and `inflight --push` pushes nothing. The `contracts` adapter, a local script, still runs: every index build reads its list, and its failure is exit 2 as without the variable. The SessionStart hook mode, the spec-claims V5 lookup and `validate --pushed`'s `undeclared-contract-change` check (for that check alone) set it. It does not stop key allocation, except `init --accept` with hosted items to write, which needs the items adapter and exits 2 (nothing written).

**Hosted items** (`items.adapter`, e.g. `doc-superpowers:ledger-items-gh`) join the index with their ref as path (`gh#<n>`) and their url, read through the same cache: `hosted items as of <UTC> (<age> old, stale)` in the note and views when stale, `hosted items: —` when there is no copy. The GitHub reference adapter lists every issue, open and closed, up to `LEDGER_GH_LIMIT` (default 10000; at the limit it exits 2, "could not list completely", rather than truncate), and keeps `ledger` and `severity` as labels (`ledger:<id>`, `sev:<value>`; prefixes from `LEDGER_GH_LEDGER_PREFIX` / `LEDGER_GH_SEV_PREFIX`) and every other field in an HTML-comment block in the issue body (`<!-- doc-superpowers-ledger` … `-->`, invisible when rendered, read with the frontmatter grammar). Status: closed with `superseded_by` → `Closed`; closed as completed → `Fixed`; closed as not planned → `Won't Fix`; closed otherwise → `Closed`; open → `Open`. The hosted issue stays the source of truth: the index caches it and never mirrors it into files. `validate --staged` never runs the adapter; `validate --all` checks hosted items through it. A `note` on a hosted item is a comment (`RULING: <text>` for a ruling) or its `owed` field, and expires the cached list; a value holding `-->` or `--!>` is refused (exit 3). With in-flight awareness on, `Fixes #<n>` (`trailers.claims_by_ref`) claims the one hosted item whose ref ends in `#<n>`.

## Relations

- Through contracts: item A is **upstream** of B when A's `changes` meet B's `consumes`; **siblings** share a contract on the same side. Direct: `relates`.
- **Candidates** are never asserted: open items sharing two or more listed files, a governing spec, or a file a named contract is defined in. `related` and `sweep` list them with the reason; `link` writes a confirmed one into the item.
- **Re-check.** When an item reaches a terminal class on the base, or a base commit changes a contract an open item consumes, the downstream items read `re-check: <key> landed` (`recheck_after`) until a later commit on the base touches them. Computed; no state file.
- **Declaring relations.** What an item declares decides what the ledger can tell its author later, so declare by these rules (`link` writes them; `suggest` and `related` propose candidates, never decide):
  - **`consumes`: every contract the item's premise reads** — even one it also writes. A consumed contract is what makes an item downstream: `recheck`, and the `re-check: <key> landed` markers, reach it when another item changing that contract lands or a base commit changes it.
  - **`changes`: every contract the fix moves**, derived fields included (a total recomputed from the line it changes is changed too).
  - **The finest registered contract**: `field:order.total` over `endpoint:orders` when the registry (or the contracts adapter) has both. A coarse contract makes everything that touches the area a sibling, and the notices noisy.
  - **No contract fits** (none is registered for it, or the dependency is on another item, not on a surface): `relates depends-on:<key>` — or `root-cause:<key>`, `sibling:<key>` — rather than a contract stretched to fit.
  - **Co-changers are siblings.** Two items that both change one contract are siblings: neither is downstream of the other, so `recheck` and the re-check markers never surface one when the other lands. When B must be re-verified after A lands, B consumes the contract too (or `relates depends-on:A`).
  - **Nothing to declare**: `ledger link <item> --relations none` writes `relations: none` (with `validate.require_relations: "new"`, the opt-out the check reads), and a ruling can say why — `ledger note <item> "…" --kind ruling`.
- **Planning sweep.** `sweep --plan <plan>` reads the plan's backticked existing files, the contract ids and keys in its text and its own Related work rows, and prints the `## Related work` table for the author to mark `include` or `exclude: <reason>`. `validate --plan <plan>` checks every row carries a mark (advisory; `--strict` blocks). SKILL.md's `spec-inject --phase=plan` pastes it into a plan (`references/spec-lifecycle-actions.md`).

## Merge-time upkeep

Declarations drift as code moves: a fix edits a contract's `defined_in` without naming it in `changes`, readers are rarely declared `consumes`, and re-check reaches only declared contracts. `upkeep` compares a range's diff with what the items it involves declare and proposes the missing `changes` and `consumes`, each with its evidence and a ready `ledger link` line. It writes nothing and runs no line: the author confirms by *Relations* → **Declaring relations**, and `link` writes.

- **Range.** `--range <a>..<b>` as given; `<a>...<b>` is `merge-base(a, b)..b` (a trunk merged into the branch never counts). A `--range` with an empty end is a usage error (3); an end that does not resolve to a commit here, or (`...`) two ends with no merge base, exit 2. `--pr <n>` (config `adapters.pr`, else exit 2) reads PR `<n>` from the adapter's list, cached as every verb reads it: merged, the range *Adapters* → `pr` gives; open, `merge-base(<base>, head_oid)..head_oid`. A closed PR exits 2, as do one the list does not hold (`ledger ls --refresh` reads the list again), one the adapter gives no `merge_commit` (merged) or `head_oid` (open) for, and a commit or base not in this clone (the message names the `git fetch`: for an open PR's head, the ref config `inflight.pull_refs` gives, else `pull/<n>/head` when the PR's url is a pull URL; for a merge commit with no parent in a shallow clone, `git fetch --unshallow`). The PR body comes from the adapter's optional `view <n>`; with no view (its exit 3) or with `DOC_TOOLS_LEDGER_OFFLINE=1` it is not read (`"body_scanned": false`). The diff is the net `git diff <a> <b>`, without renames (a moved file is its old path and its new one). The index is the working tree's when `<b>` is HEAD — a `link` not yet committed counts — else `<b>`'s own.
- **Involved items**, each with `found_by`, in this rank order (archived items never): `trailer:claims`, `trailer:claims_by_path`, `trailer:claims_by_ref` — the range's claim trailers (`trailers.since` honoured); `item-file-edited` — an item file in the net diff; `key-in-message` — a key or alias as a word (any case) in a commit message, its `claims` and `claims_by_path` trailer lines left out, so a key there is found by the trailer only (a provisional `<ledger>-~<hex>` key is no word: name it in a trailer); `key-in-pr-body` — the same in the PR body (`--pr`). `--items <item>…` names them instead (`found_by: ["named"]`; each must resolve to one item that is not archived, else exit 3), and then only they are involved.
- **Touched contracts**: an index contract whose `defined_in` matches a net-diff file `upkeep.skip_globs` does not match (*Config*: docs, markdown and tests by default) when a changed line of that file names the contract, or that a `Contract-Change: <id> — <line>` trailer in the range names. A changed line is an added or removed line of `git diff -U0 --no-renames <a> <b> -- <file>`, never a header or context line (a binary file has none; a deleted file's removed lines count). It **names** `<kind>:<name>` when `<name>` — the id after the first `:` — occurs in it case-sensitively with no `[A-Za-z0-9_]` just before or after; a `*` in `<name>` matches any run of `[A-Za-z0-9_.-]`, and every other character is itself. A contract the code never spells (a component, a pattern) is touched only by a `Contract-Change:` line: the way to declare such a change. The name test is the one rule a code-model adapter could later replace with "a symbol defining the contract changed"; nothing here depends on one. A **read** contract is one the range does not touch (no file naming it, no `Contract-Change` line) whose `read_by` matches such a file with a changed line that names it.
- **Proposals.** A touched contract that an involved item declares in `changes` is covered, proposed to nobody. Each other one goes to exactly one involved item — the most `paths` entries its `defined_in` matches, then the most `paths` entries that are net-diff files, then the best `found_by` rank, then key (else path) order — as `changes`, with the evidence `diff names <c> in <f> (defined_in of <c>)` per file (three at most, then `… and N more files`) and `Contract-Change: <c> — <line>`. A read contract goes the same way, covered by `consumes` and attributed by `read_by`, as `consumes` (`diff names <c> in <f> (read_by of <c>)`). An item found by `--items`, a trailer or its own file (never one found by words alone) also gets `consumes` for each contract the range does not touch whose `defined_in` matches a file the item lists that the net diff does not hold — `the item lists <f> (defined_in of <c>), which the range does not change` — even a contract it declares in `changes`. Never a value already declared on that side, never an `upkeep.skip_contracts` id. When the range involves no item, the contracts it touches or reads (`skip_contracts` aside) are listed as `unattributed_contracts` instead.
- **Per item**: `changes` first (`Contract-Change` evidence first, then the most evidence, then id), then `consumes` — the read ones before the listed-file ones — the same way; `--top N` (default 3; `0`: all) keeps the first N (`total`, `truncated`). `declared_untouched` lists its declared `changes` the range does not touch (informational); `link` is `ledger link <key|path> --changes a,b --consumes c` for the proposals shown (`null` with none). Text: `range <a12>..<b12>  <n> files, <m> commits`, then per item `<key|path>  found by …`, a `  + <field> <value>  — <evidence>` line per proposal, `  (showing N of M; --top 0 shows all)` when truncated, `  declared, untouched: a, b` and `  link: ledger link …`; then an `unattributed: <c> (<files>)` line per unattributed contract; `(no proposals)` when no item has one. The JSON payload: *Building on the ledger*.
- **Exits**: 0 — proposals are advisory; 1 with `--strict` and at least one proposal; 2 and 3 as the *Verbs* row says.
- **`--no-repo-adapters`**, for a review that must not run repository scripts: before any adapter runs, exit 2 — nothing run; the message, `--no-repo-adapters: a repository script is configured …`, names each — when config `adapters.contracts`, `adapters.pr` or `items.adapter` is anything but `null` or `doc-superpowers:<name>`.

Where else the comparison runs:
- **pre-push**: `validate --pushed` reports each touched contract no involved item declares as the advisory `undeclared-contract-change` (*Validation* has its range and rules), naming `ledger upkeep --range <a>..<b>`; it never refuses a push. It costs an index build and a run of the contracts adapter per pushed ref; it runs offline (`DOC_TOOLS_LEDGER_OFFLINE=1` for the check alone: no PR or items adapter, no fetch), and not at all for an empty range or a tip config `base` already holds. Config `validate.undeclared_contract_change: false` turns it off.
- **`review-pr`** (SKILL.md, step 9): `ledger upkeep --range "$BASE...HEAD" --no-repo-adapters --format json` on a ledger host, not in a CI run — read-only: a refusal is a skipped section with the command for the user to run, and the step edits nothing.
- **CI**: no doc-superpowers template runs it (none grants an agent a ledger verb); a host's own job may run `upkeep` with the ledger helper set vendored (*Vendored copies*) and post what it proposes. `--no-repo-adapters` does not keep such a job from running repository files: `doc-superpowers:<name>` adapters resolve beside the running `doc-tools.sh` (*Adapters*), so a job that runs the repository's vendored `.github/scripts/doc-tools.sh` runs the repository's copies of the tool, the ledger modules and those adapters — the flag refuses only the adapters config names by path.

## In-flight work and notices (opt-in: `inflight.enabled`)

Scanned every run: local branches, every worktree's HEAD (a detached one as `(detached:<path hash>)`, never the path), `keys.remote`'s branches, and **other machines' local branches** through in-flight refs `<ref_prefix>/<host>/<branch>`, pushed by the post-commit leg (`inflight --push`: forced, `--no-verify`, only for commits beyond the base) — each not merged into the base and younger than `max_age_days`. A branch's work is `merge-base(<base>, tip)..tip` (trunk merged into it never counts). It **claims** an item through a `trailers.claims` trailer naming the key, a `trailers.claims_by_path` trailer naming the path, a `claims_by_ref` keyword naming a hosted item, by modifying the item file, or through a plan it modifies that links the item. Trailers are read from any message line of the form `[* ]<Trailer>: <value>`, so a squash merge carrying the branch's messages keeps its claims. It **changes a contract** when its diff touches the contract's `defined_in`, or a commit says `Contract-Change: <id> — <line>`.

**Privacy.** Enabling the in-flight layer publishes this machine's local branch names (and their commits) to the shared remote. `<host>` is `inflight.host_id`, else git config `doc-superpowers.ledger.host`, else the first 8 hex of a hash of the hostname — a pseudonym, not anonymity (a dictionary of likely hostnames reverses it; every machine with an empty hostname shares one): set `inflight.host_id` when that matters. `inflight.pre_push_check` names a host command run (`sh -c`, one stdin line `<merge-base>..<tip>`) before each in-flight push — the push itself is `--no-verify`, so a host's secret or token guard runs here; non-zero → nothing pushed, its output shown, exit 1. Refs outside `refs/heads`/`refs/tags` do not show as branches on common hosts; a host whose server refuses them sets `ref_prefix` under `refs/heads/` with a segment of its own (e.g. `refs/heads/ledger-inflight`). Such a ref is a branch to GitHub: the post-commit leg then pushes a branch on every commit, so `on: push` workflows run for it (add the prefix to their `branches-ignore`, `doc-audit-update`'s included), it shows in branch lists, and branch-protection rules apply to it.

**Notices** for a branch (default: the current one), against every other branch in flight and the base since the branch's merge-base:

| Urgency | Trigger |
|---|---|
| `stop` | another branch (or the base) changes a contract the branch's claimed items consume or that it changes itself; or two branches claim one item |
| `heads-up` | another branch changes files this branch changes |
| `info` | siblings of its claimed items are claimed elsewhere |

One line each: `<urgency> <id> <other>[@<host>] <PR #n|no PR> <kind>:<values> — <what changed> → <action>`. The id is 12 hex of sha256(other, overlap, other's tip), with the other branch hashed as `<name>` on the shared remote and `<name>@<host>` otherwise, so every host computes one id and a notice fires again only when the other side moves (for the base: when the overlap's own state moves). **Ack** with a commit trailer `Ledger-Ack: <id> — <clause>` on the branch; there is no state file. `notices --gate` exits 1 on any unacked `stop`: the gate `spec-inject` injects at each chunk close. A gate never passes on in-flight data it could not fetch: when the in-flight fetch failed (the refs here, or a stale copy, would decide) and no `stop` blocks anyway, `--gate` exits 2, `could not verify: <reason>` — `--fetch` retries now. A stop found on that data still exits 1. `DOC_TOOLS_LEDGER_OFFLINE=1` is a deliberate choice to decide on the refs here (exit 0, with a note); without `--gate`, a failed fetch is a note, and the hook mode always exits 0.

**`trailers.since`** — a commit, `"adoption"` or `null` (every trailer counts). When set, the claim trailers (`claims`, `claims_by_path`, `claims_by_ref`) of every commit that does not descend from it — the commit itself, its ancestors, a branch forked before it, merged after it or still in flight — are ignored in every walk (the base's claims, the PR heads, the in-flight branches); `Contract-Change` and ack lines are unaffected. Use it when a host's commits carried a mapped trailer name before adoption. `"adoption"` is the **adoption commit**: the first commit on `base` to add `docs/ledger/config.json` (while there is none, no claim trailer counts). A `since` that names no commit here exits 2.

**Shallow clones.** In a shallow clone whose boundary is where `config.json` first shows, the adoption commit cannot be known. With `trailers.since: "adoption"` every verb that builds the index — `validate --staged` in the pre-commit leg included — then exits 2, naming the shallow clone and `git fetch --unshallow` (or name the commit in `trailers.since`). Without it, `validate --all` treats no item as from before adoption (fail-closed).

## Views and publishing

- `view <ledger|all>` renders the working tree into `--out` (default `<git common dir>/doc-superpowers/ledger/views`): `<ledger>.md`, or every ledger's page and `README.md` for `all` (`--md`, the default); `--html` writes `ledger.html`, every ledger in one self-contained file with filters (ledger, severity, status, in flight) and a search box. A page groups the open items by the contract they change (else consume), then *Unclustered*, *Recently closed* and *Superseded / won't fix* (both `views.recent_days`). Its header says what it was generated from: "Do not edit — edit the item". Hosts without CI render views locally with `view`.
- `publish` fetches the remote, renders from the base commit's blobs (that commit's config, registry and items — no checkout), and pushes one new commit to `views.branch` (an orphan branch holding only the view files), built with git plumbing so HEAD, the index and the working tree are never touched, without force: a branch that moved meanwhile exits 2. With in-flight awareness on, it then deletes the in-flight refs whose tips are on the base or older than `max_age_days` (one push; a failed prune is a note). `--dry-run` renders into `<git common dir>/doc-superpowers/ledger/publish-dry-run` and lists what it would prune. Three settings come from the **working tree's** config, because they say where the base is before it is read: `base`, `keys.remote` and `views.branch`. `base` must name a branch: `<remote>/<branch>`, or a bare `<branch>` of `keys.remote`; a tag or a commit id exits 2. Everything else comes from the base commit's config.
- **`doc-ledger-publish.yml`** (CI, opt-in by name: `hooks install --ci --workflows=doc-ledger-publish`; no AI, no secret): every 30 minutes and by hand, `.github/scripts/doc-superpowers-steps/ledger-publish.sh` runs the vendored `doc-tools.sh ledger publish`; `contents: write` (the views push, the prune), `pull-requests: read` and `issues: read` (the reference adapters, with the job's token as `GH_TOKEN`). Without a config it passes, doing nothing; a publish that cannot run fails the run, and the next one retries. On a ledger host it ships the ledger helper set; `--workflows=all` skips it on a host without `docs/ledger/config.json` (one note line), and naming it installs it anyway.

## Validation

| Check | Default | Where |
|---|---|---|
| on staged items only: a present key well formed and unique among keys and aliases · `ledger` registered and active, or `unassigned` · an added item carries `ledger` and `summary` · an item whose status moves into closed or won't fix has a resolution, and its `superseded_by` names an existing item with no cycle · `superseded_by` only on a closed item | blocking (on a modified item, a finding about what it already was at HEAD — and a `legacy_ids` or retired ledger — is advisory) | pre-commit, `validate --staged` |
| the registry (schema, ids, statuses, kinds, contract ids, globs, overlap, unowned) | blocking when the registry is staged | `validate --staged`; `--registry` alone |
| an added open item naming no `changes`, `consumes` or `relates`, without `relations: none` (`no-relations`; only with `validate.require_relations: "new"`) | blocking | pre-commit, `validate --staged` |
| provisional keys the branch adds since its merge-base with config `base` | blocking in `cas`; passes in `merge` | pre-push, `validate --pushed <a>..<b>` |
| `undeclared-contract-change`: a contract the pushed range touches (a changed line names it; `upkeep`'s touched contracts, `skip_globs` and `skip_contracts` honoured; an all-zeros `<a>` is `merge-base(<base>, <b>)`; a file counts only when the branch itself also changes it — it differs between `merge-base(<base>, <b>)` and `<b>` — so a base merged into the branch adds no file of its own; the filter is by file, so a line naming a contract that the merged base brings into a file the branch also changes still counts) that no item the range involves declares in `changes` — path its first file (null for a `Contract-Change` line alone), key the item `upkeep` would propose it to, the detail naming `ledger upkeep --range <a>..<b>`; none when the range involves no item, and none — nothing runs — for an empty range or a tip config `base` already holds; at most 10, then one `… N more contracts`. Run offline; off with config `validate.undeclared_contract_change: false`. A check that cannot run (a failing contracts adapter, a base that does not resolve, a `validate.undeclared_contract_change` that is not `true` or `false`) is one `could not check: <message>` | advisory, in `cas` and `merge` (never exit 2) | pre-push, `validate --pushed <a>..<b>` |
| the same as `--staged` over every item, plus missing key / ledger / summary, weak summary, unassigned or contract-less open items, parse errors | advisories added | `validate --all` |
| `no-relations` (with `validate.require_relations: "new"`) on an open file item new since adoption: its path is neither in the adoption commit's tree nor the new path of a rename from a file there (untracked files are new). With no adoption commit on the base yet, no item is new; a base that does not resolve, or an adoption commit beyond a shallow boundary, counts every one (fail-closed). Hosted items are not checked | advisory | `validate --all` |
| `config`: `state_watch.paths` set while `state_watch.patterns` names nothing — the state-watch hook never fires | advisory | `validate --all` |
| a missing resolution on a terminal item from before adoption ("terminal before adoption": the base has no adoption commit yet, or holds the item and no commit after adoption touched it — a merge counts with what it brings in; a pure rename does not touch the moved file) | advisory | `validate --all` |
| sweep marks in a plan's Related work table | advisory (`--strict`: blocking) | `validate --plan` |
| an unacked `stop` notice; an in-flight fetch that failed ("could not verify", exit 2) | blocking at chunk close | `notices --gate` |

Text output is one `<class> <path|key> <detail>` line per finding, ` (advisory)` after an advisory (an `undeclared-contract-change` detail starts with its path, so its line prints the path once); exit 1 when any finding blocks. With `--format json`, `{"findings": [{class, severity: "block"|"advisory", path, key, detail}]}`.

`validate.require_relations: "new"` lets a host turn the rule on without turning its history red: `--staged` blocks only on items a commit adds, `--all` reports the new ones as advisories (as it reports a missing `ledger` or `summary`), and an item from before adoption is never reported (except fail-closed, above: with no resolvable base, or an adoption commit beyond a shallow boundary, every open item counts). Items keep the `no-contract` advisory beside it, `relations: none` ones included.

Renames, as git sees them: `--staged` takes an item as added when git reports it added, so a move that also rewrites most of the file (git pairs no rename) counts as a new item there, `no-relations` included — move it in one commit and edit it in the next. `--all` reads "new since adoption" through git's rename pairing too, which can pair a genuinely new file with a similar deleted one (template-shaped stubs), and a new item that reuses a deleted pre-adoption path reads as old — either leaves a new item unreported; it is an advisory pass, and `--staged` at the item's commit is the check that blocks.

## Hooks

Two opt-in installer sets, never part of `--all`; each refuses to install (exit 1, nothing written) without `docs/ledger/config.json`, and like the git and Claude tiers they are per-clone / per-user and never recorded in `installed.json`. `references/hooks.md` → *Ledger sets* has the placement rules.

- **`hooks install --ledger`** — the git legs, as `# ledger-superpowers:begin` … `:end` blocks where git runs hooks:
  - pre-commit: `ledger validate --staged`; any non-zero exit — 1 or 2 — blocks the commit (unlike the git tier, whose failing check blocks only under `DOC_SUPERPOWERS_STRICT`).
  - pre-push: `ledger validate --pushed <remote oid>..<local oid>` per pushed ref (from all zeros for a new branch, or a remote oid that is not here or not an ancestor); refuses a push whose branch adds a provisional key in `cas` mode — only the keys it adds since its merge-base with config `base`, so a key an existing branch got by merging the base never blocks it — and refuses when git's ref lines cannot be saved for the checks after it. Its advisories (`undeclared-contract-change`) print and never refuse a push; they cost an index build and a run of the contracts adapter per pushed ref (offline; none for an empty range or a tip the base already holds), and config `validate.undeclared_contract_change: false` turns them off.
  - post-commit: `ledger inflight --push` in the background, output to `<git common dir>/doc-superpowers/ledger/push.log`, never prompting (`GIT_TERMINAL_PROMPT=0`, `GCM_INTERACTIVE=never`, ssh `BatchMode=yes`). It is the one leg with a network side effect: with `inflight.enabled`, it pushes this branch's in-flight ref.
- **`hooks install --ledger-claude`** — two Claude Code events in `.claude/settings.local.json` (it never installs the general `--claude` tier):
  - `ledger-session-notices.sh` (SessionStart): `ledger notices --hook` — the unacked `stop` and `heads-up` notices for the session's branch, offline, at most 15 lines, under a 2 s budget; silent with none or with `inflight.enabled` off.
  - `ledger-state-watch.sh` (PostToolUse, matcher `Write|Edit|MultiEdit`): `ledger state-watch --hook` — when a write lands under a `state_watch.paths` entry (a leading `~/` is `$HOME`; an absolute entry is itself; any other is under the project; `*` within one segment; it matches the file and anything below; a path crossing a symbolic link is compared resolved) and what was written (Write's content, Edit's `new_string`, MultiEdit's edits) names an item key and holds one of `state_watch.patterns` (any case), one advisory line suggests `doc-tools.sh ledger note <key> "…"`. Never blocks. Hosts list their agent-memory and scratch directories in `paths` and phrases like `"next:"` or `"approved"` in `patterns` — both: with `paths` and no `patterns` it never fires, which `validate --all` (class `config`) and `hooks status` (`⚠ ledger-state-watch never fires`) report.
- **Hook modes.** `ledger notices --hook` and `ledger state-watch --hook` are the stable entry points: each reads the event on stdin, prints one hook object or nothing, never fetches, and always exits 0 (a usage error, no repository, no config: silent). A host that keeps its hooks in a committed `.claude/settings.json` (which, unlike the per-user `settings.local.json` `--ledger-claude` writes, travels to every worktree) registers them directly instead of `--ledger-claude`:

  ```json
  { "hooks": {
      "SessionStart": [ { "matcher": "", "hooks": [ { "type": "command", "timeout": 10,
        "command": "bash \"$CLAUDE_PROJECT_DIR\"/<path>/doc-tools.sh ledger notices --hook" } ] } ],
      "PostToolUse": [ { "matcher": "Write|Edit|MultiEdit", "hooks": [ { "type": "command", "timeout": 10,
        "command": "bash \"$CLAUDE_PROJECT_DIR\"/<path>/doc-tools.sh ledger state-watch --hook" } ] } ] } }
  ```

  `<path>` is a `doc-tools.sh` every worktree resolves, with its `ledger/` directory beside it. A direct registration has no 2 s watchdog (the entry's `timeout` bounds it), and registering both a mode and `--ledger-claude` for one event prints its notices twice. Details: `references/hooks.md` → *Registering the ledger hooks in your own settings.json*.
- **Skipping.** `DOC_SUPERPOWERS_LEDGER_SKIP=1` skips every ledger leg and hook mode; `DOC_SUPERPOWERS_SKIP=1` (every doc-superpowers hook) does too. The pre-commit and pre-push legs print a line naming the variable; the others are silent.
- **Upgrading.** `hooks status` reports each set in its own section; a block or script of another version reads `⚠ … outdated: re-run install --ledger` (or `--ledger-claude`). `status --claude` reports the `--ledger-claude` section too once any of that set is installed, since both live in one settings file (`status --all` still reports the three tiers only). A 3.3.0 `--ledger-claude` install registered state-watch for `Write|Edit` only: it reads `outdated (registered for other tools than matcher "Write|Edit|MultiEdit")` until `install --ledger-claude` is re-run, which replaces the entry in place. A host that registers `ledger state-watch --hook` in its own committed `.claude/settings.json` (the snippet above) changes that entry's matcher to `Write|Edit|MultiEdit` itself: `hooks status` never inspects such entries, so nothing flags the old `Write|Edit`.

## Bootstrapping — `ledger init`

SKILL.md's `init` action runs it as its *Ledger (opt-in)* step; it also runs standalone on a repository that already has docs. Three modes, one per run. On a repository with no registry yet the bootstrap is **two `--report` passes**: the first proposes a registry, the second — against the edited proposal — writes the decisions file:

1. **`init --report <file> [--registry <file>] [--sources files,github]`** writes the report `<file>` (a markdown report: Sources, Hand-written ledgers, Registry, Registry findings, Assignment summary, Next steps) and, depending on the registry, one more file, and nothing else:
   - **No registry** (no `--registry`, no `docs/ledger/ledgers.json`): it writes `docs/ledger/ledgers.proposed.json`, a proposal, and **no decisions file**. Its Next steps say what follows: edit the proposal, then run `init --report <file> --registry docs/ledger/ledgers.proposed.json`.
   - **With a registry** (`--registry <file>`, else `docs/ledger/ledgers.json`): it writes `<file>.decisions.tsv` (the previous one kept as `.bak`) and no proposal.
   - Sources: `files` (the item globs, plus a suggested glob — never added — for each tracked directory holding three or more `*.md` files with a `status:` line) and `github` (the items adapter; for the reference adapter, `gh` must be authenticated and the repository must have issues enabled — an explicit `--sources github` that fails exits 2, the default one is reported and skipped).
   - Hand-written ledgers: the files `legacy_ledgers` names, when it names any; else every tracked `*.md` file with a table whose header has a `#` column and a column linking item files (set `legacy_ledgers` to the ones that are ledgers). A row's links come from its Tracker column when the header has one, never from a `dep:` link.
   - The registry: `--registry <file>`, else `docs/ledger/ledgers.json`, else a proposal (one ledger per top-level code directory, the largest split per second-level directory when it holds over 40 % of the code; docs, CI, scripts and tests as `platform`). Its `validate --registry` findings are in the report.
   - Each item gets a suggested ledger — its `ledger` value when registered, then a hand-written ledger row, then the plurality owner of its paths, then a `ledger:<id>` label, else `unassigned` — never by keyword. The decisions file pre-fills the suggestion for terminal items and leaves open items' decision empty; a re-run keeps decisions already made.
2. **Review**, in two parts on a repository without a registry: the host's owner edits `docs/ledger/ledgers.proposed.json` (ids, titles, kinds, paths, contracts; the report's findings), then the second pass, `init --report <file> --registry docs/ledger/ledgers.proposed.json`, writes `<file>.decisions.tsv`, whose decision column the owner fills. The decisions header records the registry and its sha256, and `--accept` installs that file as `ledgers.json` (or write `ledgers.json` by hand and run the report against it). With a registry already in place, the first pass writes the decisions file and only the second part applies. Nothing is assigned the owner did not decide.
3. **`init --accept <decisions.tsv> [--dry-run]`** checks every decided row first (any failure: exit 1, one finding per row, nothing written), then writes `config.json` when absent, the registry, the keys (one counter commit, per ledger in item-date order; offline: provisional), the item fields (`ledger`; a mechanical `summary` when missing; `key`), stubs (`docs/issues/<today>-<slug>.md`) for the open rows of hand-written ledgers that link no item — each relative link re-expressed from the stub's directory, and config `init.stub_defaults`' fields added where the stub has none (hosted stubs: one adapter write per field) — and `legacy.json` entries for every row (a row `legacy.json` already holds is left alone), then renders the views into the cache and prints the paths to review and commit. A second run changes nothing. `--dry-run` prints the plan only. It never writes through a symbolic link: a `legacy.json` (config `legacy`) that is a link, when the run has legacy entries to write, is a finding before anything is written (exit 1, no counter allocated, the link intact) — point `legacy` at the file it points to, or replace the link with that file; any other target that is a link exits 2 rather than be replaced by a regular file.

**`init --import`** turns hosted items into `docs/issues/<created>-<slug>.md` files once (each linked back with a note; nothing closed), then sets `items.adapter` to `null`, for a host that chooses files as the source of truth.

The ledger dispatches no agent: summaries are mechanical (the item's `summary`, else a hand-written row's bold lead, else its H1, else its first sentence).

## Building on the ledger

For authors of skills, routines and scripts on top of the ledger — a filing command, a triage routine, a backfill script.

### The surface to script against

- **The verbs and flags** `doc-tools.sh help ledger <verb>` lists, run from the repository's top level through the `doc-tools.sh` SKILL.md's *Detect Bundled Tooling* resolves (`$DOC_TOOLS`).
- **`--format json`**, never the text: text is written for people and agents to read, and its wording changes. Every verb prints exactly one object, `{"verb": "ledger <sub>", "enabled": <bool>, "exit": <rc>, …payload}`, and exits with that `exit`. `enabled: false` (no `docs/ledger/config.json`) is exit 0 with no payload: a wrapper says the ledger is off and does nothing. Exit 2 and 3 carry `"error": "<message>"` instead of a payload.
- **The item object** `show` returns (and the index carries) is `references/ledger-index.schema.json` (`ledger-index/1`).
- **The hook modes** `notices --hook` and `state-watch --hook` (*Hooks*).
- Not a surface: the cache under `<git common dir>/doc-superpowers/ledger/`, the scripts in `scripts/ledger/`, the text lines.

The payloads a wrapper reads most:

| Verb | Payload beyond the envelope |
|---|---|
| `show <item>` | `item` (the index item: `key`, `path`, `ledger`, `status`, `class`, `summary`, `changes`, `consumes`, `relates`, `paths`, `derived`, `neighbours`, `recheck_after`, …), `display`, `pr_data`; unknown (exit 1): `item: null`, `ref` |
| `ls` | `items: [{key, path, ledger, severity, status, class, derived, display, cluster, date, summary, archived}]`, `pr_data` |
| `find <words>…` | `matches`, `items: [{score, key, path, ledger, severity, derived, display, date, summary}]` |
| `related <item>` | `item: {key, path, ledger, severity, display, summary}`, `depth`, `neighbours: [{kind: upstream\|downstream\|sibling, key, path, via, depth, through, display, summary}]`, `candidates: [{key, path, reasons, display, summary}]` |
| `suggest <item>` | `item: {key, path, ledger, severity, display, summary}`, `declared: {changes, consumes}`, `total` (every candidate), `truncated` (`true` when `--top` left some out), `candidates: [{field: "changes"\|"consumes", contract, reasons, sources}]` (the first `--top`, ranked) — `reasons[i]` is the text of `sources[i]`, a source `{kind: "file", file}` or `{kind: "upstream"\|"downstream"\|"sibling"\|"candidate", key, path, side, why}`; exit 0 with candidates (proposals, not findings); unknown (exit 1): `item: null`, `ref` |
| `recheck <item>` | `item`, `dependents: [{key, path, via, display, summary, actions}]` |
| `sweep …` | `rows: [{key, path, confirmed, why}]`, `table` (the markdown) |
| `upkeep …` | `range` (`"<a-oid>..<b-oid>"`), `pr` (`null` with `--range`; `{number, state, body_scanned}`), `files`, `commits`, `items: [{key, path, found_by, proposed: [{field: "changes"\|"consumes", value, evidence}], total, truncated, declared_untouched, link}]` — `found_by` from `named`, `trailer:claims`, `trailer:claims_by_path`, `trailer:claims_by_ref`, `item-file-edited`, `key-in-message`, `key-in-pr-body`; `link` the ready `ledger link …` line for the proposals shown, `null` with none, never run — `unattributed_contracts: [{contract, files}]` (contracts the range touches or reads when it involves no item, with the files whose changed lines name them; `files: []` for a `Contract-Change` line alone), `pr_data` / `items_data`; exit 0 with proposals (advisory; `--strict`: 1) |
| `new` | `path`, `ledger`, `key` (`null` for `unassigned`), `provisional` (`true`: an offline `<ledger>-~<hex>` key that `finalize` replaces), `created` (`true` with `--create`; absent without); with `--suggest-contracts`, `total`, `truncated` and `candidates` in `suggest`'s shape |
| `assign <item> <ledger>` | `path`, `ledger`, `key`, `previous`, `provisional` |
| `link <item> …` | `path`, `key`, `added: [{field, value}]`, `present: [{field, value}]` (already there), `removed: [{field: "relations", value: "none"}]` only when a link dropped the opt-out; a bad value (exit 1, nothing written): `problems: ["…"]` |
| `note <item> <text>` | `ref`, `path`, `kind`, `line` |
| `validate …` | `findings: [{class, severity: "block"\|"advisory", path, key, detail}]` |
| `notices` | `inflight_enabled`, `notices: [{id, urgency, other: {branch, host, pr}, overlap, what_changed, action}]`, `pr_data` |
| `finalize` | `finalized: [{provisional, key, path}]`, `commit` (the finalize commit in `merge` mode; `null` in `cas`, which commits nothing) |

What a wrapper does on each exit:

| Exit | Means | The wrapper |
|---|---|---|
| `0` | done (inert included: check `enabled`) | reads the payload; advisories may still be in `findings` |
| `1` | findings: a blocking check, an unknown item, a bad `link` value, an unacked `stop` | shows them and stops the step; nothing was written by a write verb that exits 1 |
| `2` | could not run: an adapter, the remote, a base that does not resolve, an invalid config, "could not verify" | reports `error` and treats the step as **not done** — never as clean, never as findings; retry later, or with `--fetch` / `--refresh` |
| `3` | usage: the wrapper's command line is wrong, or `show` named several items | a bug in the wrapper (or ask the user which item); do not retry the same line |

### Suggest → confirm → link

Relations are declared by people, not inferred: the ledger proposes, the caller decides, `link` writes.

1. **Candidates.** `suggest <item>` (or `new … --suggest-contracts`, when filing) proposes `changes` contracts from the files the item lists and `consumes` contracts from its related items, each with its reasons, the best-evidenced first — at most 15 unless `--top N` says otherwise (`--top 0`: all; JSON `truncated` says whether any were left out, `total` how many there are); `related <item>` adds the candidate items (shared files, a shared spec, a `defined_in` overlap) a `relates` may name.
2. **Confirm.** The wrapper shows them and asks; the user picks, adds or rejects, by the rules in *Relations* → **Declaring relations** (that section is the one statement of what to declare — a wrapper points to it rather than restate it).
3. **Write.** One `link` call with comma lists: `link <item> --consumes a,b --changes a --relates depends-on:<key>`. A value already there is reported in `present` and left alone; any bad value writes nothing (exit 1).
4. **Nothing to declare.** `link <item> --relations none` — the sanctioned writer of the opt-out (refused when the item already names a relation; a later `link` that writes one removes it) — and, when the reason matters, `note <item> "…" --kind ruling`.

With `validate.require_relations: "new"`, the pre-commit leg (`validate --staged`) refuses a commit that adds an open item with none of `changes`, `consumes`, `relates` and no `relations: none`, so a wrapper that skips step 3 or 4 is caught at commit (*Validation*).

### Filing an item

SKILL.md's `/doc-superpowers ledger file [<title>]`: the agent procedure over the verbs (there is no `ledger file` verb), each call with `--format json` and routed on its exit (*What a wrapper does on each exit*):

1. **Enabled?** `"enabled": false` from the first call (`ledger: not enabled …`): say so, offer SKILL.md `init`'s *Ledger (opt-in)* step, and stop.
2. **Duplicates first.** `ledger find <title words> --format json` (no `<title>` given: ask for one first). Show the top matches (`key`, `summary`, `display`) and ask whether the work is already tracked; if it is, record what the user adds on that item with `ledger note <item> "<text>"`, and stop.
3. **Ask**, in one question round (`AskUserQuestion`; another client's tool: `references/tool-mappings.md`): the title; the summary (one line, ≤ 140 characters: why it matters); the ledger — the active ledgers' `id` and `scope` from `docs/ledger/ledgers.json`, or `unassigned`, never inferred from the text; the severity (config `severity_order`); the related files; the body (written to a temporary file outside the repository).
4. **Create.** `ledger new --create --title <title> --ledger <id|unassigned> --summary <summary> [--sev <severity>] [--paths <a,b,…>] [--body-file <file>] --suggest-contracts --format json` writes the item file — path, frontmatter, key and body — once and complete. Exit 2: report `error`; nothing was written. Exit 3: fix the line (with config `items.adapter` set, items are hosted: create the issue through the tracker instead), never retry it unchanged.
5. **Candidates.** Show its `candidates` (`{field, contract, reasons}`, best-evidenced first; when `truncated`, "showing N of `total`", and offer `ledger suggest <key> --top 0`) and the `candidates` of `ledger related <key> --format json` (items a `relates` may name). `<key>` is the payload's `key`, or its `path` for an `unassigned` item. The user confirms them (a multi-select), adds or rejects, by *Relations* → **Declaring relations**.
6. **Link.** One `ledger link <key> --consumes … --changes … --relates <kind>:<item>,…` with what was confirmed; nothing to declare: `ledger link <key> --relations none`, plus `ledger note <key> "<why>" --kind ruling` when the user gives a reason. Exit 1: a bad value, nothing written — show `problems` and ask again.
7. **Report** the path, the key — provisional (`"provisional": true`, `<ledger>-~<hex>`): `ledger finalize` replaces it once the remote is reachable — and the relations written. Never commit unless the user asks: the new file is theirs to commit.

### Example: a filing wrapper

```bash
# The wrapper asked the user for the title, summary, ledger, severity, files and body (body.md).
# One call writes the item file (its path, frontmatter, key and body: all or nothing), then
# proposes its contracts:
out=$("$DOC_TOOLS" ledger new --create --title "Refund totals round twice" --ledger checkout \
        --summary "Totals round twice on refunds" --sev P1 --paths src/order/total.js,src/refund/amount.js \
        --body-file body.md --suggest-contracts --top 10 --format json)
case $? in
  0) ;;
  2) echo "ledger: could not file it, nothing was written: $(jq -r .error <<<"$out")"; exit 2 ;;
  *) echo "ledger new: $out"; exit 1 ;;
esac
path=$(jq -r .path <<<"$out")            # docs/issues/<today>-refund-totals-round-twice.md
key=$(jq -r '.key // .path' <<<"$out")   # provisional (offline) keys are fine: finalize replaces them
# …show .candidates[] ({field, contract, reasons}, best-evidenced first) to the user — when .truncated, say
#    "showing N of .total" and offer the rest (ledger suggest "$key" --top 0 --format json); they confirm field:order.total (consumes and changes) and
#    field:refund.amount (consumes)…
"$DOC_TOOLS" ledger link "$key" --consumes field:order.total,field:refund.amount \
  --changes field:order.total --format json
# …or, nothing to declare: "$DOC_TOOLS" ledger link "$key" --relations none
echo "filed $path ($key)"   # nothing is committed: the user commits the new file
```

### Example: a backfill script

Declaring relations for existing open items in bulk, from a list a person reviewed. Exit 2 from any call is "could not run": the item is reported as not done and the script ends non-zero, never "all clean".

```bash
#!/usr/bin/env bash
# reviewed.tsv: <item>\t<--consumes|--changes|--relates>\t<comma list>, one row per confirmed relation
rc=0
while IFS="$(printf '\t')" read -r item flag values; do
  out=$("$DOC_TOOLS" ledger link "$item" "$flag" "$values" --format json)
  case $? in
    0) jq -r '"\(.key // .path): +\(.added | length) relations"' <<<"$out" ;;
    1) echo "$item: refused: $(jq -r '.problems // [] | join("; ")' <<<"$out")"; [ "$rc" = 2 ] || rc=1 ;;
    2) echo "$item: could not run: $(jq -r .error <<<"$out")"; rc=2 ;;
    *) echo "$item: usage error: $out"; exit 3 ;;
  esac
done < reviewed.tsv
exit "$rc"
```

To build the list, `ls --open --format json` gives the open items and `show <item> --format json` their `changes`, `consumes` and `relates`; `suggest <item> --top 0 --format json` proposes every candidate for the reviewer (without `--top 0`, the 15 best-evidenced). A row `<item>\t--relations\tnone` records an item with nothing to declare.

### What a wrapper owns

A wrapper owns **process**: asking the user, its own fields (title, body, `status`, `severity`, labels, the host's frontmatter), where the file goes, when to run. It never owns **keys** (`new`, `assign`, `finalize` allocate them; never write `key`, `aliases` or `finalized.json`), **views** (generated; never edited), or **relation semantics** (what `changes`, `consumes` and `relates` mean, and which to declare: *Relations* → **Declaring relations**). Item state goes through `note`.

## Spec claims (3.2.0) with the ledger on

With `docs/ledger/config.json` and `docs/spec-claims/`, check **V5** reads a claim's `tracker` that names a ledger item — its path, or its key or an alias that one item carries — by the ledger's status classes: open is open; fixed, closed and wontfix are closed, so `Won't Fix`, `Not planned` and `Obsolete` now close a tracker (an `unbuilt`, `diverged` or `gated` claim tracked by one becomes a V5 finding). An item whose status no class names is read at its path as any tracker is; a tracker naming no item is unchanged. V5 reads the ledger index offline; a ledger that cannot be read (`scripts/ledger/` not beside `doc-tools.sh`, an invalid config) is one indeterminate V5 row, `ledger-unavailable: …` (exit 2), and no tracker is then judged. With the ledger off, V5 is byte-identical to 3.2.0. `references/spec-claims.md` → V5.

## Vendored copies

`doc-tools.sh` runs the ledger from `scripts/ledger/` (and `doc-superpowers:<name>` adapters from `scripts/adapters/`) beside itself. `tools install --helper ledger` vendors both — `<dest>/ledger/` and `<dest>/adapters/` beside `<dest>/doc-tools.sh` — and `tools uninstall --helper ledger` removes them. `hooks install --ci` ships that set only on a ledger host (`docs/ledger/config.json` exists), with `doc-ledger-publish` and with every workflow that runs the claims check (`doc-freshness-schedule`, `doc-spec-verify`), because V5 reads ledger trackers through it there. Without the config nothing is vendored and nothing is said; a set vendored before is removed by the next `install --ci` (byte-identical files only). On a ledger host, `hooks status --ci` flags a claims workflow without the set, and `init --accept`, which writes the config, prints a note to re-run `install --ci` when such a workflow is installed. A host that keeps a file of its own under `.github/scripts/ledger/` or `.github/scripts/adapters/` with a shipped file's name has it replaced by `install --ci`: keep host adapters elsewhere and name them by path.

## Environment

| Variable | Effect |
|---|---|
| `DOC_TOOLS_LEDGER_OFFLINE=1` | the remote adapters (`pr`, `items`) do not run and nothing is fetched or pushed by the remote cache or `inflight --push`; the `contracts` adapter, a local script, still runs (*Adapters*); key allocation is not covered (except `init --accept` with hosted items: exit 2), but `keys.mode: "merge"` `finalize` skips its check of the remote's base (a warning; *Keys*); `notices --gate` decides on the refs here rather than exit 2 |
| `DOC_SUPERPOWERS_LEDGER_SKIP=1` | skips every ledger hook leg and hook mode |
| `DOC_SUPERPOWERS_SKIP=1` | skips every doc-superpowers hook, the ledger legs included |
| `LEDGER_GH_LEDGER_PREFIX`, `LEDGER_GH_SEV_PREFIX` | the GitHub items adapter's label prefixes (default `ledger:`, `sev:`) |
| `LEDGER_GH_LIMIT` | the most issues the GitHub items adapter lists (default 10000, open and closed together); at the limit it exits 2 |
| `DOC_TOOLS_LEDGER_TRACE=1` | index cache hits and misses on stderr (debugging) |
