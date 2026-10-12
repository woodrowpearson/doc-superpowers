# Design: Work Ledger — keyed work items, generated ledger views, related work, and in-flight awareness

**Status:** Draft — 2026-10-12. Origin: a host repository's brainstorm with its owner; the owner directed that the mechanism be an upstream, project-agnostic doc-superpowers feature rather than host tooling.
**Target version:** 3.3.0 (additive, opt-in: inert without `docs/ledger/config.json`). Independent of 3.2.0 (spec claims) except the optional integration in §I.
**Base branch:** developed from `claude/task-3-quote-reading-bugs-7d538a` (the 3.2.0 spec-claims work, Tasks 1–3) per the owner; rebase onto the released 3.2.0 before the PR. Everything here lives in its own verb group and files so the rebase touches only the shared dispatch/help/version surfaces.
**Co-existing (no supersession):** the doc-index (`.doc-index.json`) — read, never written, by this feature; spec claims (3.2.0) — claim trackers resolve to ledger items when both are on.

---

## Problem

Projects that track work as markdown issue files (`docs/issues/*.md`) eventually add hand-written "ledgers": per-area markdown tables whose rows point at issues and restate their state. The host repo that motivated this design measured what that costs once a dozen concurrent agent sessions write to them:

| Symptom | Measured (host, 13 ledgers, 2,244 issues) |
|---|---|
| Ledger and issue disagree | Row state is a second copy of issue status: 107 rows *done* over open issues; 8 of 10 "superseded" rows over open issues; 141 of 145 "merge-pending" rows stale. |
| Row numbers collide | Parallel branches append to the same table tail: 16 % of all commits touched ledgers; 372 of 528 open-PR pairs conflict, mostly on row appends; 130 renumber banners; ~2,000 "ledger X row N" citations break on renumber. |
| Nothing prunes | 2 MB of tables, 1,419 rows of paragraph-length prose, 250 done rows retained, 244 stacked "last verified" banners — ~90 k tokens to read one ledger. |
| Coverage | 301 open issues in no ledger; one ledger spanning four features; one feature split across three ledgers. |
| Related work invisible | For three items being fixed, 38 dependent items existed; explicit links found 11–14, almost none across ledgers. |
| Branches blind to each other | Concurrent sessions learn about each other's changes only when a human relays it in prose. |
| State leaks out of git | Arc status, approvals and "next" lists land in per-user agent memory, gitignored folders and temp files. |

**Root cause.** The ledger is a second source of truth, keyed by a number allocated from a shared mutable tail, maintained by hand, with relationships expressed in prose. Every symptom follows from one of those four properties.

## Principles

1. **The issue is the only source of truth for an item.** Everything a ledger shows is derived; a ledger cannot disagree with an issue because it is computed from it.
2. **A ledger view is generated and immutable.** Humans read it (markdown, HTML); nobody edits it.
3. **Every item and every ledger has a short stable key**, allocated so that two branches or two machines can never take the same one.
4. **Relationships are data**, expressed through named *contracts* (the things one piece of work changes and another depends on), not prose.
5. **In-flight work is visible wherever it is** — a local branch, a pushed branch without a PR, or a local branch on another machine.
6. **Cheaper than the hand-written ledger** on both sides: writing an issue costs at most three short frontmatter lines more than today and no row; reading a slice costs a query, not a file.
7. **Language- and platform-agnostic** like the rest of doc-superpowers: bash 3.2 + `jq` ≥ 1.6, no new dependency; hosts plug in small executables (adapters) for anything project-specific.

## Design

### A. Model

| Entity | Definition | Source of truth |
|---|---|---|
| **Ledger** | A bucket of work. Hosts are advised to split ledgers like services (one capability end to end) plus platform ledgers for shared machinery, so every item has exactly one home. Key: its id (`checkout`, `auth`). | `docs/ledger/ledgers.json` (host-edited registry) |
| **Item** | One unit of work = one issue: a markdown file (glob from config, default `docs/issues/*.md`) or an issue in a hosted tracker reached through an items adapter (§G; GitHub Issues reference adapter). Key `<ledger>-<n>` (`checkout-14`). | the issue itself — file frontmatter, or the hosted issue's labels + metadata block (§G) |
| **Contract** | A named interface a ledger owns: `<kind>:<name>` — `field:order.total`, `endpoint:createOrder`, `component:CheckoutSheet`, `flag:new_checkout`, `spec:SPEC-PAY-003`. Kinds are host-extensible. | the ledger registry, plus host registries through the contracts adapter (§G) |
| **Index** | Derived join of items, ledgers, contracts, the doc-index, git and PR state. | derived, cached, never committed (§C) |
| **View** | Generated ledger page (markdown) and one HTML file. | derived; published to an orphan branch (§E) |

There are no rows. A row's one-line "why it matters" moves to the issue (`summary`); everything else a row said is computed.

### B. Files and frontmatter

**`docs/ledger/config.json`** (presence turns the feature on):

```json
{
  "schema": "ledger-config/1",
  "base": "origin/main",
  "items": { "globs": ["docs/issues/*.md"], "archive_globs": ["docs/archive/issues/*.md"], "adapter": null },
  "fields": { "key": "key", "ledger": "ledger", "status": "status", "severity": ["severity", "priority"],
              "date": "date", "summary": "summary", "changes": "changes", "consumes": "consumes", "relates": "relates",
              "superseded_by": "superseded_by", "owed": "owed", "aliases": "aliases", "paths": ["related-files", "code_refs"] },
  "status": { "open": ["open", "in progress", "draft", "triage"], "fixed": ["fixed", "resolved", "done", "completed"],
              "closed": ["closed", "obsolete"], "wontfix": ["won't fix", "wontfix", "wont-fix", "not planned"] },
  "severity_order": ["P0", "P1", "P2", "P3"],
  "resolution_heading": "## Resolution",
  "log_heading": "## Log",
  "doc_columns": { "spec": ["spec", "adr", "design-spec"], "plan": ["plan"], "handoff": null },
  "keys": { "mode": "cas", "remote": "origin", "counter_ref": "refs/doc-superpowers/ledger/counters" },
  "trailers": { "claims": ["Ledger-Claims"], "claims_by_path": [], "claims_by_ref": ["Fixes", "Closes", "Resolves"], "contract_change": "Contract-Change", "ack": "Ledger-Ack" },
  "inflight": { "enabled": false, "ref_prefix": "refs/doc-superpowers/inflight", "host_id": null, "max_age_days": 21, "pre_push_check": null },
  "views": { "branch": "doc-ledger-views", "recent_days": 14, "html": true },
  "cache": { "remote_ttl_minutes": 10 },
  "adapters": { "pr": null, "contracts": null },
  "state_watch": { "paths": [], "patterns": [] },
  "legacy": "docs/ledger/legacy.json",
  "legacy_ids": [],
  "legacy_ledgers": {}
}
```

Every key has a default (shown); a minimal config is `{}`. `fields` values are a name or a list of candidate names tried in order, so a host keeps its own frontmatter (`severity` or `priority`; `related-files` or `code_refs`). `status` classes are matched case-insensitively on the value's leading words and map the host's vocabulary onto open / fixed / closed / wontfix — the defaults cover doc-superpowers' own issues (`Resolved`); nothing in this feature adds a status value (a new terminal value would break every consumer that matches terminal words, including spec-claims V5). An item's **date** is `fields.date`, else the date git first added the file, else its mtime; ties break by path. `doc_columns.handoff` is off by default (handoffs are not a doc-superpowers doc type); a host that keeps them sets `{"globs": [...]}`. `base` is the comparison base for merge-bases, ratchets and publishing, defaulting like spec-claims' `base`. `legacy_ids` lists retired ledger ids a host used before adopting (or before a re-split): on an item **modified** (not added) in a commit, a legacy id is advisory ("run `ledger assign`"), so branches cut before a migration are not blocked; on an added item it blocks. `inflight.pre_push_check` names a host command run on the commits about to be pushed to an in-flight ref (the push itself is `--no-verify`, so a host's secret/token guard runs here instead).

**`docs/ledger/ledgers.json`**:

```json
{ "schema": "ledger-registry/1",
  "ledgers": [
    { "id": "checkout", "title": "Checkout", "kind": "service", "status": "active",
      "scope": "Cart to confirmed order, client and server.",
      "paths": ["app/checkout/**", "server/orders/**"], "residual_paths": [],
      "contracts": [ { "id": "field:order.total", "defined_in": ["server/orders/model.*"] },
                     { "id": "component:CheckoutSheet", "defined_in": ["app/checkout/CheckoutSheet.*"] } ],
      "governing": ["docs/specs/SPEC-PAY-003-checkout.md"] } ] }
```

- `id`: `[a-z0-9-]{1,16}`, unique. `kind`: `service` | `platform` (advisory label). `status`: `active` | `retired`.
- `paths` / `residual_paths`: globs owning code. `ledger validate --registry` reports files claimed by zero or by several ledgers (residual globs match only files no ordinary glob claims) — a host may require it to be clean. Paths power suggestions (§F.3) and in-flight attribution (§H); they never assign an item.
- `contracts[].defined_in`: globs where the contract is defined, so a diff touching them is detected as a contract change (§H.1).

**Item frontmatter** (names via `fields`; parsed by awk: flat `key: value` scalars, flow sequences `[a, b]` and block sequences (`- a` lines) of scalars — the parser rejects nested maps in these keys with a clear error):

| Field | Required | Meaning |
|---|---|---|
| `key` | yes, once `ledger` names a ledger | `<ledger>-<n>` (§D); an `unassigned` item has no key until `ledger assign` allocates one |
| `ledger` | yes on items added after the feature is enabled | one ledger id — where the fix lands — or the reserved value `unassigned` (in scope, home undecided; it keeps surfacing in `validate --all`) |
| `summary` | yes on items added after the feature is enabled | ≤ 140 chars: why it matters |
| `changes` / `consumes` | no | contract ids this item's fix changes / this item's premise depends on |
| `relates` | no | `[root-cause:<key>, depends-on:<key>, sibling:<key>]` |
| `superseded_by` | iff superseded | replacing item's key |
| `owed` | no | what remains after the code merged ("deploy", "device pass") |
| `aliases` | tool-written | prior keys after a re-home |

**Superseded / won't-fix / obsolete — testable, reason on the issue.** Superseded = a `closed`-class status + `superseded_by` + a non-empty resolution section; won't-fix = `wontfix`-class + resolution; obsolete = `closed` + resolution. `ledger validate` rejects a dangling `superseded_by`, a cycle, a chain that ends superseded, and a missing resolution on any closed/wontfix item it checks.

**`docs/ledger/legacy.json`** (optional, written once by a host's migration and never edited; entries keyed `<legacy-id>#<row>`, where config `legacy_ledgers` maps a legacy id to its file, else the file stem minus a trailing `-ledger`): `{"<old-ledger>#<row>": {"key": "<key>"} | {"item": "<path>"} | {"archived": "<path>#<anchor>"}}` — an item without a key (terminal items need none) is referenced by path — so citations of a retired hand-written ledger keep resolving.

### C. `doc-tools.sh ledger` — the CLI

New subcommand group; bash 3.2 + `jq`. Text is the default output (it is what agents read — the token budget is the point); `--format json` prints exactly one verdict object per run, `{"verb", "enabled", "exit", …payload}`, matching the claims verbs (schema: `references/ledger-index.schema.json`). Without `docs/ledger/config.json` every verb is inert: text mode prints one line `ledger: not enabled (no docs/ledger/config.json)`, JSON mode `{"verb":"ledger <v>","enabled":false,"exit":0}`, exit 0. Exit codes: `0` ok · `1` findings · `2` could not run (missing adapter, unreadable input — never reported as clean) · `3` usage.

| Verb | Does |
|---|---|
| `ledger show <key\|alias\|legacy-ref\|path>` | one item in ≤ 25 lines: key, ledger, severity, status, summary, derived status (§E.1), links, upstream/downstream, in-flight claims. Accepts `checkout-14`, `checkout 14`, `checkout #14`. |
| `ledger ls [--ledger L] [--sev P1,P2] [--open] [--status S] [--cluster C]` | one line per item |
| `ledger find <words>` | ranked fuzzy match over key, summary, filename slug, H1, first paragraph — for the item whose name you can't remember |
| `ledger related <key> [--depth N]` | siblings, upstream, downstream (§F), and unconfirmed candidates |
| `ledger sweep --plan <path> \| --files … \| --contracts … \| --keys …` | the planning sweep (§F.3) |
| `ledger recheck <key>` | the re-check list when `<key>` resolves or its contracts change (§F.2) |
| `ledger inflight [--branch B]` / `ledger notices [--branch B]` | in-flight work and notices (§H) |
| `ledger new --ledger L --summary "…" [--file <issue>]` | allocate a key (§D) and write `key`/`ledger`/`summary` into the issue (`--ledger unassigned` writes no key) |
| `ledger assign <item> <ledger>` | move an item to a ledger: allocate a key there; a previous key goes to `aliases` |
| `ledger link <item> --consumes C \| --changes C \| --relates kind:key` | write a confirmed relation into the item |
| `ledger note <key> "<text>" [--kind log\|ruling\|owed]` | the one deterministic home for item state: appends a dated line under `log_heading` (or a `Rulings` heading), or sets `owed` |
| `ledger view <ledger\|all> [--md\|--html] [--out DIR] [--open]` | render views locally from the working tree (includes local branches) |
| `ledger validate [--staged\|--all\|--registry]` | §J |
| `ledger publish [--dry-run]` | render from the remote base + in-flight scan and push the views branch (§E.3) |

**Index.** Built on demand by one awk pass over item frontmatter (+ the first resolution line and the H1) and `jq` joins with the registry, `.doc-index.json` (doc types, `deprecated`, `superseded_by`), git (trailers, refs, and rename detection — the doc-index re-keys moved entries in place and keeps no move history, so a link to a path that no longer exists is resolved through `git log --follow --name-status`; an archive move therefore reaches the views with no extra trigger) and the PR adapter. Two caches under `$(git rev-parse --git-common-dir)/doc-superpowers/ledger/`: the **local index**, keyed by HEAD + a hash of dirty item files + the config, registry and doc-index hashes; and **remote-derived data** (PR list, remote and in-flight branch claims, per-branch merge-base and diff), keyed by ref oids and refreshed only by `--refresh`, `ledger publish`, `ledger inflight --fetch`, or when older than `cache.remote_ttl_minutes`. No verb touches the network unless asked or the TTL has expired; offline, remote-derived columns show their age. Budgets (bash 3.2 + jq on 3,000 items, local caches warm, no network): `show`/`ls`/`find` < 1 s; cold local index build < 5 s; `validate --staged` < 1 s for ≤ 20 staged items; the `SessionStart` notice hook < 2 s (it never fetches). The index is never committed.

### D. Keys

- **Allocation — atomic, offline-tolerant.** `ledger new` fetches `keys.counter_ref` (a commit whose tree holds one JSON blob `{ledger: next}`), writes `next+1` in a new commit, and pushes it with `--force-with-lease=<ref>:<old-oid>`. The remote's receive-pack rejects a stale old value, so concurrent allocators never share a number; the loser retries (bounded, with jitter). A first allocation creates the ref, seeding each ledger's counter from the highest key already present on the base.
- **Offline:** a provisional key `<ledger>-~<4 hex of the issue path hash>`; `ledger new --finalize` replaces it later; in `cas` mode the pre-push hook refuses to push a provisional key.
- **Fork-and-PR repositories (`keys.mode: "merge"`).** Contributors who cannot push to the shared remote never allocate: every new item carries a provisional key on its branch, provisional keys are allowed to reach the base, and the publisher (`ledger publish`, or a maintainer running `ledger finalize` on the base) assigns real keys in one commit on the base. `cas` (default) suits teams that push to one remote.
- Keys are never renumbered or reused. A re-homed item gets a new key and keeps the old one in `aliases`. Keys and aliases are globally unique (`validate`).

### E. Views

#### E.1 Derived status (first match wins)

`superseded → <key>` · `won't fix` · `closed` · `shipped` (fixed-class, no `owed`) · `merged · owed: <owed>` (fixed with `owed`, or a claims-by-path trailer reachable from the base while still open) · `in review #<pr>` (an open PR whose head claims the item) · `on branch <b>` (an in-flight branch claims it, no PR) · `planned` (an open plan links it) · `spec'd` (a spec links it, no plan) · `not started`.

#### E.2 Ledger page (markdown) — clusters by shared contract

```
# Checkout (`checkout`)
> Generated from <base>@<sha> + <n> in-flight branches at <UTC> by doc-superpowers ledger. Do not edit — edit the item.
Scope … · Open: P0 0 · P1 3 · P2 5 · In flight: 2 branches

## Order totals — `field:order.total` (3)
| Key | Issue | Why it matters | Sev | Spec | Plan | PR | Latest handoff | Status |
↳ Downstream (consumes field:order.total): billing-7, receipts-2
↳ Upstream: pricing-12 changes field:order.total on branch `pricing-rework` (no PR) — re-check when it lands

## Unclustered (n) — each with its suggested cluster
## Recently closed (recent_days)
## Superseded / won't fix (recent_days) — key → replacement: first line of the resolution
```

- Cluster = the item's primary contract (first of `changes`, else first of `consumes`). Clusters sort by severity counts, items by severity then age.
- Columns: key, issue, summary, severity, spec / plan written, PR, newest handoff that links the item, derived status.
- Closed items older than `recent_days` drop off the page and stay queryable — pruning by construction.
- `README.md` on the views branch: every ledger with open counts and in-flight branches, and a cross-ledger open-P0/P1 rollup.

#### E.3 HTML and publishing

- `ledger view all --html`: one self-contained HTML file (no network) with every ledger in the cluster layout, client-side filters (ledger, severity, status, in flight) and a search box.
- **Publishing.** Views are never committed to the main line or feature branches (they would conflict on every item edit, and hosted merges do not run custom merge drivers). `ledger publish` renders from `<remote>/<base>` plus the in-flight scan and commits to the orphan branch `views.branch`, one immutable commit per snapshot, fast-forward only; only the publisher writes it. Hosts schedule `publish` (cron, a CI template `doc-ledger-publish.yml` for hosts with Actions, or a local routine). Readers use the hosted file view of that branch; `ledger view` renders a fresh local copy.

### F. Related work

#### F.1 Relations
- Through contracts: item A is **upstream** of B when `A.changes ∩ B.consumes ≠ ∅`; siblings share a contract on the same side.
- Direct: `relates` (`root-cause`, `depends-on`, `sibling`).
- Candidates (never asserted): ≥ 2 shared code paths in the items' file references (host field via config, e.g. `related-files`), a shared governing spec, a shared contract `defined_in` overlap. On the motivating corpus these surfaced ~20 of 38 true dependents at ~1:1 noise — enough to propose, not to assert; semantic search added nothing beyond them.

#### F.2 Re-check
When an item reaches a terminal class, or a base commit changes a contract, `ledger recheck` lists every downstream item to re-verify, close as superseded, or reshape. Views mark them `re-check: <key> landed` until a later commit touches the item (computed; no state file).

#### F.3 Planning sweep
`ledger sweep --plan <path>` reads the plan's governing specs, the items/keys and files it names, and emits a `## Related work` table — confirmed relations first, then candidates — for the author to mark `include` / `exclude: <why>`. `validate --plan <path>` (advisory by default; a host may make it blocking) checks every row carries a mark. Confirmed candidates are written back to the items' frontmatter by `ledger link`.

### G. Adapters (executables named in `config.adapters`)

| Adapter | Contract |
|---|---|
| `pr` | `<adapter> list` → JSON lines `{"number", "head", "state", "url"}`. Reference: `scripts/adapters/ledger-pr-gh.sh` (GitHub CLI). Absent → PR column "—", never an error. |
| `contracts` | `<adapter> list` → JSON lines `{"id", "ledger": <id\|null>, "defined_in": [globs]}` for contracts held in host registries (a design-system registry, a flags file, …); `<adapter> resolve <id>` → exit 0/1. Absent → only registry contracts exist. |
| `items` | `<adapter> list [--since <ts>]` → JSON lines `{"ref", "url", "title", "body_excerpt", "status", "fields": {…}, "labels": [...], "updated"}` with `fields` holding the same logical fields as file frontmatter; `<adapter> write <ref> <field> <value>` sets one field; `<adapter> note <ref> <text>` appends a comment. Reference: `scripts/adapters/ledger-items-gh.sh` — GitHub Issues via `gh`: `ledger` and `severity` as labels (`ledger:<id>`, `sev:<v>`, prefixes configurable), all other fields in an HTML-comment metadata block in the issue body (`<!-- doc-superpowers-ledger … -->`, invisible when rendered); open/closed and the close reason (`completed` / `not planned`) map onto the status classes; `superseded_by` lives in the block. The hosted issue stays the source of truth — the index caches the adapter's list (TTL, `--refresh`), shows a stale marker when offline, and never mirrors items into files. A host that wants files instead runs `ledger init --import` once (§K). Hosted items are validated by `validate --all` through the adapter, not by the pre-commit hook. |

An adapter failure is exit `2` for verbs that need it and a visible "—" in views; never a silent clean. A contract id declared both in the registry and by the `contracts` adapter is one contract: the registry's `ledger`, `defined_in` and `title` win, and the adapter fills only fields the registry leaves empty. Adapter values may be an absolute path, a repo-relative path, or `doc-superpowers:<name>` for an adapter shipped with doc-superpowers.

### H. In-flight awareness (opt-in: `inflight.enabled`)

#### H.1 Sources and claims
Scanned every run: local branches and worktrees; every remote branch (PR or not); and **other machines' local-only branches** via in-flight refs — a git-tier `post-commit` hook pushes `HEAD:<ref_prefix>/<host>/<branch>` (background, `--no-verify`, force, skipped offline) whenever the branch has commits not on the base; the scanner fetches `+<ref_prefix>/*:<ref_prefix>/*`; `publish` prunes refs whose commits are on the base or older than `max_age_days`. Refs outside `refs/heads`/`refs/tags` do not appear as branches on common hosts; a host whose server rejects them sets `ref_prefix` under `refs/heads/`. `<host>` is `inflight.host_id`, else git config `doc-superpowers.ledger.host`, else the first 8 hex of a hash of the machine's hostname — machine names are not published unless the user sets one. Enabling the in-flight layer publishes local branch names to the shared remote; the docs say so.

Trailers are read from any line of a commit message of the form `[* ]<Trailer>: <value>` — not only git's final trailer paragraph — so squash-merge messages that carry the branch's commit messages still count; the PR adapter's merged state is a second source for "merged". A branch **claims** an item when a commit since its merge-base carries a `trailers.claims` trailer naming the key, a `trailers.claims_by_path` trailer naming the item path (hosts map their existing trailers here), a `trailers.claims_by_ref` keyword naming a hosted issue (`Fixes #123`), or modifies the item file, or when a plan on the branch names it. A branch **changes a contract** when its diff touches the contract's `defined_in`, or a commit carries `Contract-Change: <contract-id> — <one line>`.

#### H.2 Notices
`ledger notices --branch B` computes, against every other in-flight branch and the base since B's merge-base:

| Urgency | Trigger |
|---|---|
| `stop` | another branch (or the base since B's merge-base) changes a contract that B's claimed items consume or that B also changes; or two branches claim one item |
| `heads-up` | another branch changes files B changes |
| `info` | siblings of B's claims are in flight elsewhere |

Notice = `{id, urgency, other: {branch, host, pr}, overlap: {files|contracts|keys}, what_changed: <Contract-Change line or diffstat>, action}`; `id` = hash(other branch, overlap, other head), so a notice re-fires only when the other side moves. Ack = trailer `Ledger-Ack: <id> — <clause>`; no state file.

#### H.3 Delivery
- Claude-tier `SessionStart` hook: unacked `stop`/`heads-up` notices for the session's branch (≤ 15 lines; silent when none).
- `ledger notices --gate` exits 1 on any unacked `stop` notice. When the ledger is enabled, `spec-inject --phase=plan` adds a "Ledger notices (chunk N)" task to each chunk that runs it — a SKILL.md procedure step, independent of the 3.2.0 `claims gate`.
- `ledger notices` is cheap enough to run at any other pause a host wires (pre-PR, pre-close).

### I. Integrations
- **doc-index:** read only (types, archive moves, deprecation, supersession). No index schema change.
- **Spec claims (3.2.0) — explicit 3.3.0 changes to a 3.2.0 surface:** when the ledger is enabled, V5 resolves a `tracker` that is an item key through the index and reads open/closed from the ledger's status classes (so `Won't Fix` counts as closed, which V5's `wontfix` word match misses today); a path tracker to an item uses the same classes. Item pages show counts of `diverged`/`unbuilt` claims an item tracks. With the ledger off, V5 is unchanged.
- **spec-inject (SKILL.md):** the plan-phase "Ledger notices (chunk N)" task (§H.3), only when the ledger is enabled.
- **State home:** `ledger note` is the documented single home for item state. A Claude-tier `PostToolUse(Write|Edit)` advisory hook fires on writes under `state_watch.paths` (hosts list their agent-memory and scratch directories) whose content matches item keys plus `state_watch.patterns` ("next:", "approved", …) and suggests the `ledger note` command. Advisory only.

### J. Validation and hooks

| Check | Default | Where |
|---|---|---|
| on **staged** items only: any present key well-formed and globally unique (keys + aliases) · `ledger` is a registered id or `unassigned` · items **added** in this commit carry `ledger` + `summary` · supersession integrity and a non-empty resolution on items whose status changed to closed/wontfix in this commit | blocking | git-tier pre-commit `ledger validate --staged` |
| pre-existing items missing `key`/`ledger`/`summary` | advisory (so a host can migrate in stages) | `validate --all` |
| provisional keys (`cas` mode only) | blocking | git-tier pre-push |
| registry: ids, statuses, contract ids, MECE paths | blocking when the registry is staged | pre-commit |
| unconfirmed candidates · items with no contract · weak summary (< 20 chars) · sweep marks | advisory | `validate --all` / `--plan` |
| unacked `stop` notice | blocking at chunk close | spec-inject gate |

Hooks install as their own opt-in set — `install --ledger` adds the git legs (pre-commit validate, pre-push provisional check, post-commit in-flight push) and, with `--claude`, the Claude events (`SessionStart` notices, `PostToolUse(Write|Edit)` state-watch); `uninstall --ledger` removes them. Like the existing git and Claude tiers they are per-clone / per-user and are **not** recorded in `installed.json` (which records the CI tier only). `install --ledger` refuses when `docs/ledger/config.json` is absent.

### K. Bootstrapping — `init`

The skill's `init` action gains a ledger step, and `doc-tools.sh ledger init` runs it standalone on a repo that already has docs. It **populates the ledgers and fetches the items wherever they already live**:

1. **Item sources.** Detect local markdown issues (default globs, plus any `*.md` directory whose files carry `status:` frontmatter) and, when the remote is GitHub and issues are enabled, GitHub Issues through the reference items adapter (`gh` authenticated; otherwise reported and skipped — exit 2 only if the user asked for it). Both may be on at once. Existing hand-written ledgers — markdown tables with a link column — are detected too (step 4).
2. **Ledgers (buckets).** Propose a registry from what discovery already maps (the `init` Explore agents' containers and components): one `service` ledger per capability, `platform` ledgers for shared machinery (build, CI, test infra, docs tooling, design system), each with `paths` checked MECE over the code dirs and initial `contracts` from obvious registries. Hints from item data: frontmatter `component`/`area` values, GitHub labels, existing ledger files. The skill presents the proposal; the user edits; `ledger init --registry <file>` accepts the result.
3. **Assignment.** For each item: a suggested ledger from (in order) an existing `ledger`/legacy-ledger membership, the item's code-path references against `paths`, labels, then none. Suggestions are confirmed in batches by the user (or, for terminal items, accepted as suggested); unconfirmed open items stay `unassigned` and keep appearing in `validate --all` (the lazy option is the one that keeps asking). Nothing is assigned by keyword inference.
4. **Legacy ledgers.** Each hand-written table row with a tracker link becomes a `legacy.json` entry (`<ledger>#<row>` → the linked item's key); a row whose tracker is not an item (a plan, a spec) and is not done becomes a new item (file stub or adapter `create`) carrying the row text, so nothing open is lost; a done row without an item maps to its archived anchor. The host archives the old files through the doc-index archive flow afterwards.
5. **Summaries.** Mechanical: the item's existing `summary`, else its legacy row's bold lead, else its H1, else its first sentence (≤ 140 chars). The skill may have an agent rewrite summaries for open items above a severity threshold (opt-in, budgeted).
6. **Keys.** One allocation commit seeds the counter ref with every assignment, numbered per ledger in item-date order, so keys are stable and the earliest items get the smallest numbers.
7. **Write** `config.json`, `ledgers.json`, `legacy.json`, item fields (files: frontmatter; hosted: through the adapter), render the first views, and offer the git- and Claude-tier hooks.

`init` is idempotent: a re-run picks up new items and sources and never renumbers. `ledger init --import` converts hosted issues into local markdown items once (writing back a link and closing nothing) for hosts that choose files as the source of truth.

## Non-goals
- A server or database. Hosted trackers are reached only through an items adapter; 3.3.0 ships one reference adapter (GitHub Issues), vendored by `tools install` alongside the publish workflow template.
- Assigning items to ledgers automatically (suggestions only; declared assignment).
- A host's taxonomy decisions: `init` proposes ledgers, the host's owner decides them.
- Push delivery into live agent sessions (notices are pulled at pause points).

## Verification
New suite `scripts/test-ledger.sh` on the existing harness, in CI under bash 5.x and `/bin/bash` 3.2:
1. Views are pure: the same inputs render byte-identically apart from the header timestamp.
2. Key allocation: two allocators racing against a local bare remote get distinct keys; provisional keys refused at pre-push; seeding from existing keys.
3. Supersession fixtures: dangling, cycle, chain ending superseded, missing resolution — each exit 1.
4. Frontmatter parser: scalars, flow sequences, quoted values, CRLF, a rejected block sequence with a clear message.
5. Contracts: upstream/downstream/sibling computation; re-check lists; candidate rules.
6. In-flight fixture: two local worktrees, one remote branch without a PR, one in-flight ref from another "host" — file overlap → heads-up, contract change → stop, double claim → stop, including the other host's local-only branch; ack suppresses; a moved head re-fires.
7. Adapters: absent → "—"; failing → exit 2; reference `gh` adapter against a fake `gh`.
8. Performance on a synthetic 3,000-item corpus within the §C budgets.
9. Token budget: `ledger ls --ledger L --sev P1,P2 --open` over 300 items ≤ 2 k tokens of output.
10. `init` on a fixture repo (code dirs, local issues, a fake `gh` returning hosted issues, one hand-written markdown ledger): proposes a MECE registry; suggests assignments from paths/labels/legacy membership; writes `legacy.json` (incl. a stub for an open plan-tracked row); allocates keys in item-date order in one counter commit; a second run is a no-op.
11. GitHub items adapter against a fake `gh`: list normalisation, label + metadata-block round-trip, close-reason mapping, offline stale marker.
12. `keys.mode: merge`: provisional keys pass pre-push; `ledger finalize` on the base assigns real keys in one commit and rewrites nothing else.
13. Staged-migration scope: editing a pre-existing item that lacks `key`/`ledger`/`summary` passes pre-commit (advisory only); adding a new item without them blocks; `unassigned` passes and carries no key.
14. Squash-merge claims: a squash commit whose body carries `* Ledger-Claims: x-3` lines counts as a claim; a merged PR from the adapter marks its claimed items merged.
15. Spec-claims V5 with the ledger on: a key tracker resolves; a `Won't Fix` item counts as closed; with the ledger off V5 output is byte-identical to 3.2.0.
16. Inert behaviour: every verb without `config.json` prints the one inert line (text) or `{"verb","enabled":false,"exit":0}` (JSON) and exits 0.

## Version
3.3.0 — minor, additive, opt-in. `references/ledger.md` (config, schema, verbs, adapters, hook wiring), SKILL.md `ledger` action, `integration-patterns.md` section, README.

## Decisions from the builder check (2026-10-12)

Resolved in the sections above, listed here for the owner's review: unassigned items carry no key and the blocking pre-commit checks only staged items, requiring the new fields only on items added after enablement (§B, §J) · `keys.mode: merge` for fork-and-PR repositories (§D) · the notices gate is a `ledger notices --gate` task injected by `spec-inject`, independent of `claims gate` (§H.3, §I) · network sources are cached by ref oid with a TTL and never fetched implicitly; budgets restated for bash 3.2 (§C) · the ledger hooks are their own opt-in installer set, not recorded in `installed.json` (§J) · the GitHub items adapter stays in 3.3.0 as a reference adapter, vendored with the publish template (Non-goals) · trailers are read from any message line so squash merges keep claims, with the PR adapter as a second source (§H.1) · block sequences are parsed (§B) · item date = `fields.date`, else git first-add date (§B) · host-neutral defaults: handoff column off, status classes cover `Resolved`, severity tries `severity` then `priority` (§B) · in-flight host segment is an anonymous hash unless the user names it (§H.1) · move history comes from git rename detection, not the doc-index (§C) · 3.3.0 changes spec-claims V5 explicitly when the ledger is on (§I) · JSON verdict and inert output match the claims verbs; `schema` keys and a `base` config key (§B, §C).
