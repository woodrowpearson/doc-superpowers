# Work Ledger — `doc-tools.sh ledger`

**Read by** SKILL.md — **REQUIRED** when `docs/ledger/config.json` exists (the `init` ledger step, `spec-inject --phase=plan`, the `hooks` ledger sets), and by anyone wiring the ledger into a host. `$DOC_TOOLS` is the `doc-tools.sh` SKILL.md's *Detect Bundled Tooling* resolved. `doc-tools.sh help ledger <verb>` (or `ledger <verb> --help`) prints each verb's own usage; this page is the reference those lines point to. The design record is `docs/superpowers/specs/2026-10-12-work-ledger-design.md`.

The work ledger keeps work items as issues — markdown files (default `docs/issues/*.md`) or a hosted tracker's issues reached through an adapter — and derives everything else from them: a stable key per item, ledger pages and one HTML file generated from the items, related work through named *contracts*, and the work in flight on other branches and machines. **The issue is the only source of truth**: no row, view or cache is ever edited by hand, so nothing can disagree with an item.

## Turning it on — the inert contract

The ledger is opt-in. `docs/ledger/config.json` turns it on; `{}` is a complete config (every key has a default, below). Without it:
- every verb except `init` prints one line, `ledger: not enabled (no docs/ledger/config.json)` — with `--format json`, `{"verb":"ledger <sub>","enabled":false,"exit":0}` — and exits 0;
- a hook mode (`notices --hook`, `state-watch --hook`) prints nothing and exits 0;
- `init`, which bootstraps a repository, runs on the default config (`{}`), and every object it prints says `"enabled": false` until a config exists.

The order of the checks: the options are parsed first (an unknown option still exits 3), then the repository (outside a git work tree, or below its top level, exit 2), then the config — before any argument is read. Run `$DOC_TOOLS ledger …` from the repository's top level, like every `doc-tools.sh` subcommand.

The verbs live in `scripts/ledger/` beside `doc-tools.sh` (a `lib.sh` that sources twelve modules, and the `*.jq` / `*.awk` programs they run). A copy of `doc-tools.sh` without that directory beside it exits 2 for an enabled ledger: see *Vendored copies* below.

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
| `docs/ledger/ledgers.proposed.json` | `init --report` | a registry proposal for the host to edit; never read as the registry |
| `docs/ledger/legacy.json` (config `legacy`) | `init --accept`, once | the map from hand-written ledger rows to items (*Legacy map*) |
| `docs/ledger/finalized.json` | `new --finalize`, `finalize` | provisional key → allocated key (*Keys*) |
| item files (`items.globs`) | the host; `new`, `assign`, `link`, `note`, `finalize`, `init --accept`, `init --import` write fields | the items |
| `<report>`, `<report>.decisions.tsv` (+ `.bak`) | `init --report` | the bootstrap report and the assignment decisions (*Bootstrapping*) |
| `<git common dir>/doc-superpowers/ledger/` | every verb | the cache: the parse cache, the indexes, the remote cache (PR list, hosted items, in-flight facts), rendered views (`views/`, `publish-dry-run/`), `push.log`. Never committed; safe to delete |
| `keys.counter_ref` on `keys.remote` (default `refs/doc-superpowers/ledger/counters`) | `new`, `assign`, `finalize`, `init --accept` | the key counters |
| `<inflight.ref_prefix>/<host>/<branch>` on `keys.remote` | `inflight --push` (the post-commit leg); pruned by `publish` | other machines' local branches |
| `views.branch` (default `doc-ledger-views`) | `publish` only | the published views, an orphan branch |

The ledger never writes `docs/.doc-index.json`: it reads it (doc types, `deprecated`, `superseded_by`, archive moves).

### Config — `docs/ledger/config.json`

Deep-merged over the defaults: an object merges key by key; an array, a scalar or `null` the host gives replaces the default (so `fields.severity` may be one name where the default is a list).

| Key | Default | Meaning |
|---|---|---|
| `schema` | `"ledger-config/1"` | |
| `base` | `"origin/main"` | the comparison base: merge-bases, adoption, `publish`, in-flight "merged" |
| `items.globs` | `["docs/issues/*.md"]` | the item files (`*` within one segment) |
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
| `state_watch.paths` / `.patterns` | `[]` / `[]` | the state-watch hook (*Hooks*) |
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
- `paths` / `residual_paths`: globs owning code (a residual glob claims only files no ordinary glob does). They power suggestions and in-flight attribution; they never assign an item. `validate --registry` reports a tracked file claimed by two ledgers and, once any ledger declares paths, a tracked file outside `docs/` that none claims.
- `contracts[]`: `{"id": "<kind>:<name>", "defined_in": [globs], "title"?}` — ids match `^[a-z][a-z0-9_-]*:[^[:space:]]+$`; a diff touching `defined_in` changes the contract. Kinds are the host's (`field:`, `endpoint:`, `component:`, `flag:`, `spec:` …).

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
| `inflight [--branch <b>[@<host>]] [--fetch] [--push]` | the branches in flight, one line each (*In-flight work*); `--push` publishes this branch's in-flight ref | 1 unknown `--branch` · 2 offline `--fetch`, a refused push · 1 `pre_push_check` refusing |
| `notices [--branch …] [--gate] [--fetch] \| --hook` | stop / heads-up / info notices for a branch (*In-flight work*) | 1 with `--gate` and an unacked `stop` · 2 a base or branch that does not resolve, offline `--fetch` |
| `state-watch --hook` | the PostToolUse hook mode (*Hooks*) | always 0 |
| `new --ledger <id\|unassigned> --summary <text> [--file <issue>] [--finalize]` | allocate a key and write `key`, `ledger`, `summary` into an issue (default: the one staged or untracked item file without a key); `unassigned` writes no key; prints `<key>  <path>` | 3 no single issue · 2 allocation failed |
| `assign <item> <ledger>` | a new key in that ledger; the old key is appended to `aliases` | 1 unknown |
| `link <item> --consumes <c> \| --changes <c> \| --relates <kind>:<item>` | write confirmed relations into the item's lists (any of the three at once; one write) | 1 a bad value, nothing written |
| `note <item> <text> [--kind log\|ruling\|owed]` | the one home for item state: `- <date> <text>` under `log_heading`, `- <date> RULING: <text>` under `## Rulings`, or the `owed` field; nothing else in the file changes, nothing is staged; a hosted item goes through its adapter | 1 unknown · 3 several or a blank text · 2 adapter failing |
| `view <ledger\|all> [--md] [--html] [--out <dir>] [--open] [--refresh]` | render the views from the working tree (uncommitted items included) | 2 `--refresh` failing |
| `validate --staged \| --all \| --plan <plan> [--strict] \| --pushed <a>..<b> [--registry]` | *Validation* | 1 a blocking finding |
| `publish [--dry-run]` | render from the remote base and push one commit to `views.branch` (*Views*) | 2 the branch moved, an adapter failing, offline |
| `finalize [--all]` | replace provisional keys (*Keys*) | 2 remote unreachable (`cas`) |
| `init --report <file> [--registry <file>] [--sources files,github] \| --accept <decisions.tsv> [--dry-run] \| --import` | *Bootstrapping* | 1 a decision row failing · 2 could not run · 3 usage |

## Keys

Keys are never renumbered or reused. A re-homed item gets a new key and keeps the old one in `aliases`; keys and aliases are globally unique (`validate`).

- **`keys.mode: "cas"`** (the default, for teams that push to one remote). The counter ref on `keys.remote` is a commit whose tree holds one blob, `counters.json`, `{"<ledger>": <next number>}`. Allocation fetches it, writes a commit with the new numbers (and a random nonce) on top, and pushes it with `--force-with-lease=<ref>:<fetched oid>` and `--no-verify`: the remote's ref update is the atomic step, so two allocators never share a number. The loser retries (at most 8 times, 0.1–0.6 s jitter apart, re-reading each time), then exits 2 — never a silent provisional key, since the remote was reachable. The first allocation creates the ref, seeding each ledger after the highest key already on the base. A batch (`init --accept`) is one counter commit.
- **Offline: provisional keys.** When the remote cannot be reached (a transport failure), `new` and `init --accept` give `<ledger>-~<hex>` — the first 4 hex digits of sha256 of the item path, lengthened one digit at a time (8 at most) while the key would repeat a key, an alias, a `finalized.json` key or a key given earlier in the same batch (by path) — with a warning. In `cas` mode the pre-push leg refuses to push a provisional key; `finalize` (or `new --finalize` on that issue) replaces it once the remote is reachable. `new --finalize` and `finalize` never fall back: unreachable is exit 2.
- **`keys.mode: "merge"`** (fork-and-PR repositories, whose contributors cannot push to the shared remote). Allocation never touches the network: every new item carries a provisional key, provisional keys may reach the base, and a maintainer runs `finalize` on the base, which numbers them after the highest key in the tree and commits the rewrite in one commit, `ledger: finalize N keys`.
- **`finalize`** rewrites each provisional key in the item's `key` and in every `relates`, `superseded_by` and `aliases` that names it, and adds one line per key to `finalized.json`; nothing else. In `cas` mode it finalizes the provisional keys this branch added (`--all`: every one) in the working tree, committing nothing.

**claude.ai/code sessions.** Its git proxy refuses (HTTP 403) every push under `refs/doc-superpowers/…` — create, force and delete — while under `refs/heads/…` it allows a create, a compare-and-swap, a stale-lease rejection and a force, but refuses deletes. Local hosts allow both. So with the default `keys.counter_ref` a cloud session cannot allocate: the counter push fails, and `new` gives a provisional key (`finalize` exits 2). A host whose sessions run in claude.ai/code sets `keys.counter_ref` under `refs/heads/`, e.g. `refs/heads/doc-superpowers/ledger-counters` (the ref then shows as a branch on the host). Deletes under `refs/heads/` are refused there too, so `publish`'s in-flight prune fails from such a session (a note, not a failed publish); `inflight --push` reports the 403 as a permission failure — a `push.log` warning, exit 0.

## Adapters

Executables named in config `adapters.pr`, `adapters.contracts` and `items.adapter`. A value is an absolute path, a path from the top level, or `doc-superpowers:<name>` — `scripts/adapters/<name>.sh` beside the running `doc-tools.sh` (`<name>`: `[a-z0-9_-]+`). They run from the top level with stdin closed. A list prints one compact JSON object per line. A missing or non-executable file, a non-zero exit, or output that breaks the contract is exit 2 for every verb that needs it — never a silent clean — and a visible `—` in the views. An absent adapter is no error: its column shows `—`.

| Adapter | Contract |
|---|---|
| `contracts` | `list` → lines `{"id": "<kind>:<name>", "ledger": "<id>"\|null, "defined_in": [globs], "title"?: string\|null}`; `resolve <id>` → exit 0 / 1. A contract both the registry and the adapter declare is one contract: the registry's `ledger`, `defined_in` and `title` win. Needed by `show`, `related`, `recheck`, `sweep`, `link`, `view`, `publish` |
| `pr` | `list` → lines `{"number", "head", "state": "open"\|"merged"\|"closed", "url"}`, optional `"cross"` (true: the head is a fork's branch, never resolved through a same-named branch of `keys.remote`) and `"head_oid"` (a merged PR is walked from it when the clone has it, never from its branch; absent: a merged PR adds nothing beyond the base's own claims). Reference: `doc-superpowers:ledger-pr-gh` — `gh pr list` for every open PR (it exits 2 rather than truncate at its limit of 1,000) and the 500 newest merged ones, adding `"merge_commit"` |
| `items` | `list [--since <ts>]` → lines `{"ref": "<no whitespace>", "url": "<non-empty>", "status": "…", "fields": {…}}`, optional `"title"`, `"body_excerpt"`, `"updated"`, `"closed"` (strings or null; ISO 8601 times), `"labels"`, `"fm_errors"` (string lists); `get <ref>` → one `{"ref", "url", "title", "body", "created", "fields", "labels", "status"}` (`init --import`; exit 3 means "no get"); `write <ref> <field> <value>`; `note <ref> <text>`; `create --title <t> --body-file <f>` → `{"ref", "url"}`. Reference: `doc-superpowers:ledger-items-gh` |

**The PR list and hosted items are cached** for `cache.remote_ttl_minutes`. When the adapter fails, the verbs serve the last copy (one stderr line; `pr_data` / `items_data` in `--format json`; the views' header says `PR data as of <UTC> (<age> old)` or `PR data: —`), and only `--refresh` and `publish` exit 2 (`validate --all` too, for hosted items with no copy at all).

**`DOC_TOOLS_LEDGER_OFFLINE=1`** never runs an adapter or fetches (for hooks that must not reach the network): a copy past its TTL is served stale, none is `—`, `--refresh` / `publish` exit 2 (`offline: DOC_TOOLS_LEDGER_OFFLINE=1`), and `inflight --push` pushes nothing. The SessionStart hook mode and the spec-claims V5 lookup set it. It does not stop key allocation.

**Hosted items** (`items.adapter`, e.g. `doc-superpowers:ledger-items-gh`) join the index with their ref as path (`gh#<n>`) and their url, read through the same cache: `hosted items as of <UTC> (<age> old, stale)` in the note and views when stale, `hosted items: —` when there is no copy. The GitHub reference adapter keeps `ledger` and `severity` as labels (`ledger:<id>`, `sev:<value>`; prefixes from `LEDGER_GH_LEDGER_PREFIX` / `LEDGER_GH_SEV_PREFIX`) and every other field in an HTML-comment block in the issue body (`<!-- doc-superpowers-ledger` … `-->`, invisible when rendered, read with the frontmatter grammar). Status: closed with `superseded_by` → `Closed`; closed as completed → `Fixed`; closed as not planned → `Won't Fix`; closed otherwise → `Closed`; open → `Open`. The hosted issue stays the source of truth: the index caches it and never mirrors it into files. `validate --staged` never runs the adapter; `validate --all` checks hosted items through it. A `note` on a hosted item is a comment (`RULING: <text>` for a ruling) or its `owed` field, and expires the cached list; a value holding `-->` or `--!>` is refused (exit 3). With in-flight awareness on, `Fixes #<n>` (`trailers.claims_by_ref`) claims the one hosted item whose ref ends in `#<n>`.

## Relations

- Through contracts: item A is **upstream** of B when A's `changes` meet B's `consumes`; **siblings** share a contract on the same side. Direct: `relates`.
- **Candidates** are never asserted: open items sharing two or more listed files, a governing spec, or a file a named contract is defined in. `related` and `sweep` list them with the reason; `link` writes a confirmed one into the item.
- **Re-check.** When an item reaches a terminal class on the base, or a base commit changes a contract an open item consumes, the downstream items read `re-check: <key> landed` (`recheck_after`) until a later commit on the base touches them. Computed; no state file.
- **Planning sweep.** `sweep --plan <plan>` reads the plan's backticked existing files, the contract ids and keys in its text and its own Related work rows, and prints the `## Related work` table for the author to mark `include` or `exclude: <reason>`. `validate --plan <plan>` checks every row carries a mark (advisory; `--strict` blocks). SKILL.md's `spec-inject --phase=plan` pastes it into a plan (`references/spec-lifecycle-actions.md`).

## In-flight work and notices (opt-in: `inflight.enabled`)

Scanned every run: local branches, every worktree's HEAD (a detached one as `(detached:<path hash>)`, never the path), `keys.remote`'s branches, and **other machines' local branches** through in-flight refs `<ref_prefix>/<host>/<branch>`, pushed by the post-commit leg (`inflight --push`: forced, `--no-verify`, only for commits beyond the base) — each not merged into the base and younger than `max_age_days`. A branch's work is `merge-base(<base>, tip)..tip` (trunk merged into it never counts). It **claims** an item through a `trailers.claims` trailer naming the key, a `trailers.claims_by_path` trailer naming the path, a `claims_by_ref` keyword naming a hosted item, by modifying the item file, or through a plan it modifies that links the item. Trailers are read from any message line of the form `[* ]<Trailer>: <value>`, so a squash merge carrying the branch's messages keeps its claims. It **changes a contract** when its diff touches the contract's `defined_in`, or a commit says `Contract-Change: <id> — <line>`.

**Privacy.** Enabling the in-flight layer publishes this machine's local branch names (and their commits) to the shared remote. `<host>` is `inflight.host_id`, else git config `doc-superpowers.ledger.host`, else the first 8 hex of a hash of the hostname — a pseudonym, not anonymity (a dictionary of likely hostnames reverses it; every machine with an empty hostname shares one): set `inflight.host_id` when that matters. `inflight.pre_push_check` names a host command run (`sh -c`, one stdin line `<merge-base>..<tip>`) before each in-flight push — the push itself is `--no-verify`, so a host's secret or token guard runs here; non-zero → nothing pushed, its output shown, exit 1. Refs outside `refs/heads`/`refs/tags` do not show as branches on common hosts; a host whose server refuses them sets `ref_prefix` under `refs/heads/` with a segment of its own (e.g. `refs/heads/ledger-inflight`).

**Notices** for a branch (default: the current one), against every other branch in flight and the base since the branch's merge-base:

| Urgency | Trigger |
|---|---|
| `stop` | another branch (or the base) changes a contract the branch's claimed items consume or that it changes itself; or two branches claim one item |
| `heads-up` | another branch changes files this branch changes |
| `info` | siblings of its claimed items are claimed elsewhere |

One line each: `<urgency> <id> <other>[@<host>] <PR #n|no PR> <kind>:<values> — <what changed> → <action>`. The id is 12 hex of sha256(other, overlap, other's tip), with the other branch hashed as `<name>` on the shared remote and `<name>@<host>` otherwise, so every host computes one id and a notice fires again only when the other side moves (for the base: when the overlap's own state moves). **Ack** with a commit trailer `Ledger-Ack: <id> — <clause>` on the branch; there is no state file. `notices --gate` exits 1 on any unacked `stop`: the gate `spec-inject` injects at each chunk close.

**`trailers.since`** — a commit, `"adoption"` or `null` (every trailer counts). When set, the claim trailers (`claims`, `claims_by_path`, `claims_by_ref`) of every commit that does not descend from it — the commit itself, its ancestors, a branch forked before it, merged after it or still in flight — are ignored in every walk (the base's claims, the PR heads, the in-flight branches); `Contract-Change` and ack lines are unaffected. Use it when a host's commits carried a mapped trailer name before adoption. `"adoption"` is the **adoption commit**: the first commit on `base` to add `docs/ledger/config.json` (while there is none, no claim trailer counts). A `since` that names no commit here exits 2.

**Shallow clones.** In a shallow clone whose boundary is where `config.json` first shows, the adoption commit cannot be known. With `trailers.since: "adoption"` every verb that builds the index — `validate --staged` in the pre-commit leg included — then exits 2, naming the shallow clone and `git fetch --unshallow` (or name the commit in `trailers.since`). Without it, `validate --all` treats no item as from before adoption (fail-closed).

## Views and publishing

- `view <ledger|all>` renders the working tree into `--out` (default `<git common dir>/doc-superpowers/ledger/views`): `<ledger>.md`, or every ledger's page and `README.md` for `all` (`--md`, the default); `--html` writes `ledger.html`, every ledger in one self-contained file with filters (ledger, severity, status, in flight) and a search box. A page groups the open items by the contract they change (else consume), then *Unclustered*, *Recently closed* and *Superseded / won't fix* (both `views.recent_days`). Its header says what it was generated from: "Do not edit — edit the item". Hosts without CI render views locally with `view`.
- `publish` fetches the remote, renders from the base commit's blobs (its own config, registry and items — no checkout), and pushes one new commit to `views.branch` (an orphan branch holding only the view files), built with git plumbing so HEAD, the index and the working tree are never touched, without force: a branch that moved meanwhile exits 2. With in-flight awareness on, it then deletes the in-flight refs whose tips are on the base or older than `max_age_days` (one push; a failed prune is a note). `--dry-run` renders into `<git common dir>/doc-superpowers/ledger/publish-dry-run` and lists what it would prune.
- **`doc-ledger-publish.yml`** (CI, opt-in by name: `hooks install --ci --workflows=doc-ledger-publish`; no AI, no secret): every 30 minutes and by hand, `.github/scripts/doc-superpowers-steps/ledger-publish.sh` runs the vendored `doc-tools.sh ledger publish`; `contents: write` (the views push, the prune), `pull-requests: read` and `issues: read` (the reference adapters, with the job's token as `GH_TOKEN`). Without a config it passes, doing nothing; a publish that cannot run fails the run, and the next one retries. It ships the ledger helper set.

## Validation

| Check | Default | Where |
|---|---|---|
| on staged items only: a present key well formed and unique among keys and aliases · `ledger` registered and active, or `unassigned` · an added item carries `ledger` and `summary` · an item whose status moves into closed or won't fix has a resolution, and its `superseded_by` names an existing item with no cycle · `superseded_by` only on a closed item | blocking (on a modified item, a finding about what it already was at HEAD — and a `legacy_ids` or retired ledger — is advisory) | pre-commit, `validate --staged` |
| the registry (schema, ids, statuses, kinds, contract ids, globs, overlap, unowned) | blocking when the registry is staged | `validate --staged`; `--registry` alone |
| provisional keys a push adds | blocking in `cas`; passes in `merge` | pre-push, `validate --pushed <a>..<b>` |
| the same as `--staged` over every item, plus missing key / ledger / summary, weak summary, unassigned or contract-less open items, parse errors | advisories added | `validate --all` |
| a missing resolution on a terminal item from before adoption ("terminal before adoption": the base has no adoption commit yet, or holds the item and no commit after adoption touched it — a merge counts with what it brings in; a pure rename does not touch the moved file) | advisory | `validate --all` |
| sweep marks in a plan's Related work table | advisory (`--strict`: blocking) | `validate --plan` |
| an unacked `stop` notice | blocking at chunk close | `notices --gate` |

Text output is one `<class> <path|key> <detail>` line per finding, ` (advisory)` after an advisory; exit 1 when any finding blocks.

## Hooks

Two opt-in installer sets, never part of `--all`; each refuses to install (exit 1, nothing written) without `docs/ledger/config.json`, and like the git and Claude tiers they are per-clone / per-user and never recorded in `installed.json`. `references/hooks.md` → *Ledger sets* has the placement rules.

- **`hooks install --ledger`** — the git legs, as `# ledger-superpowers:begin` … `:end` blocks where git runs hooks:
  - pre-commit: `ledger validate --staged`; any non-zero exit — 1 or 2 — blocks the commit (unlike the git tier, whose failing check blocks only under `DOC_SUPERPOWERS_STRICT`).
  - pre-push: `ledger validate --pushed <remote oid>..<local oid>` per pushed ref; refuses a push that adds a provisional key in `cas` mode, and refuses when git's ref lines cannot be saved for the checks after it.
  - post-commit: `ledger inflight --push` in the background, output to `<git common dir>/doc-superpowers/ledger/push.log`, never prompting (`GIT_TERMINAL_PROMPT=0`, `GCM_INTERACTIVE=never`, ssh `BatchMode=yes`). It is the one leg with a network side effect: with `inflight.enabled`, it pushes this branch's in-flight ref.
- **`hooks install --ledger-claude`** — two Claude Code events in `.claude/settings.local.json` (it never installs the general `--claude` tier):
  - `ledger-session-notices.sh` (SessionStart): `ledger notices --hook` — the unacked `stop` and `heads-up` notices for the session's branch, offline, at most 15 lines, under a 2 s budget; silent with none or with `inflight.enabled` off.
  - `ledger-state-watch.sh` (PostToolUse, matcher `Write|Edit`): `ledger state-watch --hook` — when a write lands under a `state_watch.paths` entry (a leading `~/` is `$HOME`; an absolute entry is itself; any other is under the project; `*` within one segment; it matches the file and anything below; a path crossing a symbolic link is compared resolved) and what was written names an item key and holds one of `state_watch.patterns` (any case), one advisory line suggests `doc-tools.sh ledger note <key> "…"`. Never blocks. Hosts list their agent-memory and scratch directories in `paths` and phrases like `"next:"` or `"approved"` in `patterns`.
- **Hook modes.** `ledger notices --hook` and `ledger state-watch --hook` are the stable entry points: each reads the event on stdin, prints one hook object or nothing, never fetches, and always exits 0 (a usage error, no repository, no config: silent). A host that keeps its hooks in a committed `.claude/settings.json` (which, unlike the per-user `settings.local.json` `--ledger-claude` writes, travels to every worktree) registers them directly instead of `--ledger-claude`:

  ```json
  { "hooks": {
      "SessionStart": [ { "matcher": "", "hooks": [ { "type": "command", "timeout": 10,
        "command": "bash \"$CLAUDE_PROJECT_DIR\"/<path>/doc-tools.sh ledger notices --hook" } ] } ],
      "PostToolUse": [ { "matcher": "Write|Edit", "hooks": [ { "type": "command", "timeout": 10,
        "command": "bash \"$CLAUDE_PROJECT_DIR\"/<path>/doc-tools.sh ledger state-watch --hook" } ] } ] } }
  ```

  `<path>` is a `doc-tools.sh` every worktree resolves, with its `ledger/` directory beside it. A direct registration has no 2 s watchdog (the entry's `timeout` bounds it), and registering both a mode and `--ledger-claude` for one event prints its notices twice. Details: `references/hooks.md` → *Registering the ledger hooks in your own settings.json*.
- **Skipping.** `DOC_SUPERPOWERS_LEDGER_SKIP=1` skips every ledger leg and hook mode; `DOC_SUPERPOWERS_SKIP=1` (every doc-superpowers hook) does too. The pre-commit and pre-push legs print a line naming the variable; the others are silent.
- **Upgrading.** `hooks status` reports each set in its own section; a block or script of another version reads `⚠ … outdated: re-run install --ledger` (or `--ledger-claude`).

## Bootstrapping — `ledger init`

SKILL.md's `init` action runs it as its *Ledger (opt-in)* step; it also runs standalone on a repository that already has docs. Three modes, one per run:

1. **`init --report <file> [--registry <file>] [--sources files,github]`** writes three files and nothing else: `<file>` (a markdown report: Sources, Hand-written ledgers, Registry, Registry findings, Assignment summary, Next steps), `docs/ledger/ledgers.proposed.json`, and `<file>.decisions.tsv`.
   - Sources: `files` (the item globs, plus a suggested glob — never added — for each tracked directory holding three or more `*.md` files with a `status:` line) and `github` (the items adapter; for the reference adapter, `gh` must be authenticated and the repository must have issues enabled — an explicit `--sources github` that fails exits 2, the default one is reported and skipped).
   - Hand-written ledgers: the files `legacy_ledgers` names, when it names any; else every tracked `*.md` file with a table whose header has a `#` column and a column linking item files (set `legacy_ledgers` to the ones that are ledgers). A row's links come from its Tracker column when the header has one, never from a `dep:` link.
   - The registry: `--registry <file>`, else `docs/ledger/ledgers.json`, else a proposal (one ledger per top-level code directory, the largest split per second-level directory when it holds over 40 % of the code; docs, CI, scripts and tests as `platform`). Its `validate --registry` findings are in the report.
   - Each item gets a suggested ledger — its `ledger` value when registered, then a hand-written ledger row, then the plurality owner of its paths, then a `ledger:<id>` label, else `unassigned` — never by keyword. The decisions file pre-fills the suggestion for terminal items and leaves open items' decision empty; a re-run keeps decisions already made.
2. **Review.** The host's owner edits the proposal (installed as `ledgers.json` by `--accept`, or written as `ledgers.json` by hand) and fills the decisions column. Nothing is assigned the owner did not decide.
3. **`init --accept <decisions.tsv> [--dry-run]`** checks every decided row first (any failure: exit 1, one finding per row, nothing written), then writes `config.json` when absent, the registry, the keys (one counter commit, per ledger in item-date order; offline: provisional), the item fields (`ledger`; a mechanical `summary` when missing; `key`), stubs (`docs/issues/<today>-<slug>.md`) for the open rows of hand-written ledgers that link no item — each relative link re-expressed from the stub's directory — and `legacy.json` entries for every row (a row `legacy.json` already holds is left alone), then renders the views into the cache and prints the paths to review and commit. A second run changes nothing. `--dry-run` prints the plan only.

**`init --import`** turns hosted items into `docs/issues/<created>-<slug>.md` files once (each linked back with a note; nothing closed), then sets `items.adapter` to `null`, for a host that chooses files as the source of truth.

The ledger dispatches no agent: summaries are mechanical (the item's `summary`, else a hand-written row's bold lead, else its H1, else its first sentence).

## Spec claims (3.2.0) with the ledger on

With `docs/ledger/config.json` and `docs/spec-claims/`, check **V5** reads a claim's `tracker` that names a ledger item — its path, or its key or an alias that one item carries — by the ledger's status classes: open is open; fixed, closed and wontfix are closed, so `Won't Fix`, `Not planned` and `Obsolete` now close a tracker (an `unbuilt` or `diverged` claim tracked by one becomes a V5 finding). An item whose status no class names is read at its path as any tracker is; a tracker naming no item is unchanged. V5 reads the ledger index offline; a ledger that cannot be read (`scripts/ledger/` not beside `doc-tools.sh`, an invalid config) is one indeterminate V5 row, `ledger-unavailable: …` (exit 2), and no tracker is then judged. With the ledger off, V5 is byte-identical to 3.2.0. `references/spec-claims.md` → V5.

## Vendored copies

`doc-tools.sh` runs the ledger from `scripts/ledger/` (and `doc-superpowers:<name>` adapters from `scripts/adapters/`) beside itself. `tools install --helper ledger` vendors both — `<dest>/ledger/` and `<dest>/adapters/` beside `<dest>/doc-tools.sh` — and `tools uninstall --helper ledger` removes them. `hooks install --ci` ships that set with `doc-ledger-publish` and with every workflow that runs the claims check (`doc-freshness-schedule`, `doc-spec-verify`), whether or not the ledger is enabled, because V5 needs it on a ledger host; `hooks status --ci` flags a claims workflow without it. A host that keeps a file of its own under `.github/scripts/ledger/` or `.github/scripts/adapters/` with a shipped file's name has it replaced by `install --ci`: keep host adapters elsewhere and name them by path.

## Environment

| Variable | Effect |
|---|---|
| `DOC_TOOLS_LEDGER_OFFLINE=1` | no adapter runs and nothing is fetched or pushed by the remote cache or `inflight --push` (*Adapters*) |
| `DOC_SUPERPOWERS_LEDGER_SKIP=1` | skips every ledger hook leg and hook mode |
| `DOC_SUPERPOWERS_SKIP=1` | skips every doc-superpowers hook, the ledger legs included |
| `LEDGER_GH_LEDGER_PREFIX`, `LEDGER_GH_SEV_PREFIX` | the GitHub items adapter's label prefixes (default `ledger:`, `sev:`) |
| `DOC_TOOLS_LEDGER_TRACE=1` | index cache hits and misses on stderr (debugging) |
