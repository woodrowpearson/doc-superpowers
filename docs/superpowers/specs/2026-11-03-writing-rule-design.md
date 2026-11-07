# Writing rule — design

**Status:** draft 2026-11-03, for the developer's approval · **Releases:** four, in the order under
*Order* · **Source:** a sibling project's writing lint, its tests and its migration. That project
is not named here, and none of its texts, codes, paths or measurements are copied.

## What this decides

doc-superpowers adopts a writing rule as its house style for every project. Every text it writes
follows the rule, and a lint checks it by default. The lint reports and never blocks unless a
project asks it to. The rule says three things:

- Put first what the reader's job needs first.
- Give every code words, a link or a key entry.
- Keep sentences short: at most 35 words in the terse register and 40 in the full one.

The rule and its lint come from a sibling project (here, "the source project"). That project built
them, migrated its own documents to them, and measured the result. This design moves the generic
parts into doc-superpowers and leaves the source project's own readers and pages where they are.

## Why

Documents written by agents drift into two faults. Some run long, in list items that hold several
ideas. Others cite codes, such as record numbers and run ids, with no words beside them, so the
reader has to know what each one means. The source project found both and migrated its documents.
Its migration showed that a rewrite can fix them without changing what a document says, and a
script confirmed that every identifier, number and link target survived.

doc-superpowers writes much of a project's documentation: generated docs, spec and decision-record
templates, audit reports, release notes and plan tasks. If those templates break the rule, every
project that uses them inherits the faults. A project that then migrates gets them back on the next
`update`.

## Goals

- One rule, shipped as a marked block a project copies into `AGENTS.md`, reported current or
  outdated by `hooks status`, as the search rule is.
- A lint that runs with no install on a stock Mac and on GitHub's runners, and never downloads.
- Registers picked from the doc-index `doc_type` first and from the path second, so a project needs
  no configuration.
- Every template, agent prompt and report format doc-superpowers ships passes the lint.
- A `writing migrate` action that rewrites a project's backlog without changing what it says.
- doc-superpowers' own documents pass the lint and are held there by ceilings.

## Non-goals

- Checks a project builds for its own surfaces, such as a pull-request body check. They stay in
  that project and call the lint's verbs.
- A project's own scenario rows: who its readers are and what each needs first. Upstream ships the
  table's shape with generic rows.
- Judging whether a gloss uses the right words, whether a short sentence says anything, or jargon in
  ordinary words. The lint cannot count these; the reference page says so.
- Windows. doc-search's reference already excludes it.

## Anti-goals

These would make the work a failure even if every test passed:

- The lint blocks a commit, a push or a merge in a project that did not ask for that.
- A default setup downloads something or reaches the network. `references/setup.md` promises it
  never does.
- doc-superpowers' own output fails its own rule.
- A migration changes a decision, a value, an identifier, a link target, code, a table's data, a
  quote or front matter.

## Constraints

- **The core stays bash and jq.** The lint is Python because it relies on the standard library's
  `difflib` and on look-behind patterns, which awk lacks. It is plain scripts, not a package, and
  nothing installs them.
- **Python 3.9 is the floor.** Every source file parses under macOS's own `/usr/bin/python3` (3.9.6).
  Type annotations sit behind `from __future__ import annotations`, and the newest call is
  `str.removeprefix`, added in 3.9. The tests run on 3.9, in CI and locally.
- **bash 3.2 and jq 1.6** for every shell wrapper, as for the rest of the shipped scripts.
- **Hooks report.** The git tier's hooks never block outside `DOC_SUPERPOWERS_STRICT=1`, and each
  check runs inside the hook budget of 20 seconds by default.
- **Nothing from the source project** in any file, commit or GitHub text: no name, example text,
  code, path or measurement. The ported tests get invented fixtures, and the reference page gets
  invented examples. The leak scan and a review of each commit check this.

## Approaches

Four choices were weighed with the developer. A reviewer who saw only the code and the constraints
checked the packaging choice.

**Who the rule reaches.** (a) Only projects that turn it on, like doc-search and the work ledger.
(b) Every project. The developer chose (b). No evidence showed the rule doing worse than the text it
replaced, and the migration measured it better in almost every case.

**How the lint is packaged.**

- (a) Its own uv project, `writing/`, like `search/`: locked, and uv fetches a Python when one is
  missing. But uv would become a dependency of every project. It writes a `.venv` into the plugin
  directory, which can be read-only, and a download does not fit in the hook budget.
- (b) Plain scripts in `scripts/writing/`, run by `python3` 3.11 or later, else by uv. This removes
  uv where a Python exists, but the uv fallback can still download.
- (c) Plain scripts in `scripts/writing/`, run by `python3 -I -B -X utf8`, with 3.9 as the floor and
  no uv at runtime. **Chosen.** Stock macOS runs it, nothing downloads, and the CI tier copies the
  folder into `.github/scripts/` the way it already copies the ledger's helper set.
- Ruled out: a module of `search/`, which would install semble and the MCP SDK for a lint and tie
  it to doc-search's opt-in. Also ruled out: a bash and awk port, which has no look-behind and no
  `difflib`.

**Which git hook.** Pre-commit runs before the commit exists. The lint's range mode compares the
merge base with the committed head and never reads the working tree, so pre-commit would need a new
mode. Pre-push sees committed work and prints once per push. **Chosen: pre-push**, on by default and
report-only.

**How `audit` shows a backlog.** A project that has never followed the rule can hold hundreds of
findings in its living documents. Listing every one would bury the freshness results an audit
exists for. **Chosen: a count per folder and register**, with `writing migrate` named as the fix.

## Design

### The engine

`scripts/writing/` holds four Python files and a defaults file:

| File | What it does |
|---|---|
| `config.py` | The configuration reader: the defaults merged with the project's file, and each file's register |
| `lint.py` | The writing lint: whole-file check, range mode, ceilings, JSON output |
| `anchors.py` | The anchor check: every identifier, code, number and link target survives a rewrite |
| `markdown.py` | The shared parser: prose lines, paragraphs, code spans, the file-path rule |
| `defaults.json` | The default registers, limits, code patterns, allowed words and skipped line prefixes |

In the source, the parser lives inside a second lint. Only the parser and the code-pattern logic
move; that lint's own checks stay in the source.

`doc-tools.sh writing` dispatches to them, so every caller goes through the bundled tooling:

| Verb | What it runs |
|---|---|
| `writing check [--profile terse\|full] [--github] FILE...` | The lint on whole files. With no `--profile`, each file's register is looked up |
| `writing range BASE...HEAD` | The lint on the sentences a branch adds |
| `writing ceilings [--base REF] [--update]` | The ceilings check; `--update` re-records each count and the counting version |
| `writing anchors --base REF FILE...` | The anchor check |
| `writing counts [PATH...]` | Findings per folder and register, as JSON, for `audit` |

`writing check --profile terse|full -` reads text on stdin, for text that is not a file: a
pull-request body or a page's paragraphs. Stdin has no path, so no register to look up, and
`--profile` is required. `--name LABEL` only labels the findings.

**The command line is the contract.** The Python modules are internal and may change in any
release. A project that builds its own checks on the lint calls the verbs. `check`, `range`,
`counts` and `anchors` take `--format text|json`; `ceilings` does not. The flags keep the source
lint's spelling, so a project moving from its own copy only renames the command. The exit codes
are the source's: 0 clean, 1 findings, 2 a usage error or a file or base that cannot be read.

The wrapper finds Python before it runs anything. It checks that `python3` is at least 3.9 and
otherwise prints one line, `writing: skipped (needs python3 3.9 or later)`, and exits 3. Callers
read 3 as "could not run", never as clean.

### The behaviors kept from the source

Each was a defect the source project found and fixed, and each has a test that moves with the
code:

1. Front matter that opens on line 1 is skipped.
2. Range mode compares the merge base with the committed head, never the working tree.
3. Only new sentences count. A sentence already in the base, with only numbers or link targets
   changed, is not linted; digits compare as runs.
4. Renamed files and moved text are compared with their source, deleted files included.
5. An edited sentence is judged against its closest base sentence (a `difflib` ratio of at least
   0.6). Only what the edit made worse is reported.
6. A new bare code beside an old bare code of the same series is reported.
7. A code inside a file path is not bare, and one rule in the parser decides that.
8. A heading defines its codes only when it holds other words. A bold label defines its codes only
   when words follow it.
9. In the full register a code glossed or linked once passes later in the document. In the terse
   register every use needs its gloss.
10. An issue or pull-request number (`#` and digits) passes only with `--github`, for text read on
    GitHub.
11. Headings, table rows, fenced blocks, quotes, link targets, trailers and task boxes are skipped.
12. A bold lead-in that ends in a full stop counts as a sentence, because a reader sees one.
13. Each ceiling equals its path's count at the committed head. A ceiling may only fall unless the
    range changes what the lint counts.
14. The anchor check joins a backtick span wrapped across lines, skips footnotes, and fails on an
    added link to a file that does not exist.

### Fixes made in the move

The reviewer found these in the source; each gets a test:

- **A crash reads as findings.** An uncaught exception exits 1. The entry point catches it and
  exits 2 with the error.
- **Bytecode beside the scripts.** Loading the parser by path writes `__pycache__` into the plugin
  or into a copy under `.github/scripts/`. The wrapper runs Python with `-B`.
- **Encoding.** `-I` ignores `PYTHONIOENCODING`, so a non-UTF-8 locale can crash on a curly quote.
  The wrapper adds `-X utf8`.
- **Fixed paths.** The source picks registers from its own folders and loads its code patterns from
  beside the script. Both come from configuration instead.
- **The ceilings exemption.** The source lets a ceiling rise when a range changes the lint's own
  files, named by the source's paths. Upstream, a plugin upgrade changes counts with no change in
  the repository. So the engine carries a **counting version**: a whole number in `lint.py`, apart
  from the release number, raised by any change that changes what the lint counts. A test over a
  fixed corpus fails when its counts change and the counting version did not. Most releases leave
  the counting version alone, so they leave ceilings alone.
- **How ceilings follow it.** The ceilings file records the counting version it was counted with.
  A range may raise or drop a ceiling only when it changes the project's writing configuration, or
  changes the recorded version to the running engine's own. When the running engine's counting
  version differs from the recorded one, the check exits 1 with one line: run
  `writing ceilings --update`. The copy under `.github/scripts/` and the plugin's copy are told
  apart the same way; `install --ci` refreshes the copy.
- **Tool-written lines.** `set-implementation` writes a `Realized-by:` or `Implementation:` header
  with a list of items under it, in a fixed form that the rule would flag. The config key
  `skip_blocks`, which defaults to those two headers, skips the whole block: the header line, its
  `- ` items and their indented wraps. A header opens a block only when it is alone on its line or
  followed by `[]`, and only the first header in a file opens one. The two headers are not in
  `skip_prefixes`.
- **Injected plan tasks.** The source skips them by title because the templates failed the rule.
  Once the templates pass, the skip goes.

### Registers and configuration

A file's register comes from, in order:

1. Its doc-index entry's `doc_type`. Plans, issues and audits are terse. Design specs, specs,
   decision records and the living types (architecture, guides and the rest) are full. A type the
   index invents, such as `reference`, is full.
2. Its path, by the rules in the configuration. The defaults: `AGENTS.md` and `CLAUDE.md` anywhere
   are terse; `docs/plans/*-design.md` is full; the rest of `docs/plans/` and `docs/issues/` are
   terse; the rest of `docs/` is full. The work ledger's items folder is terse when the ledger is
   configured.
3. Nothing: the file is not linted. `docs/archive/`, files that are not Markdown, and Markdown
   outside these paths, such as the root `README.md`, are not linted.

**Records.** An entry whose `doc_type` is a record type (plan, issue, audit, design-spec) gets
range mode only, and a path under `docs/archive/` is never linted without `--profile`. `audit` does
not count a record and it takes no ceiling. This matches the freshness check, which never reports a
record stale.

`docs/writing/config.json` is optional. When present it is merged over `defaults.json` key by key:

```json
{
  "enabled": true,
  "registers": { "doc_types": { "runbook": "terse" }, "paths": [ { "prefix": "ops/", "register": "terse" } ] },
  "limits": { "terse": { "sentence": 35, "item": 50, "item_sentences": 2 }, "full": { "sentence": 40 } },
  "codes": { "patterns": [], "allowed": [ "P0", "UTF-8" ], "gloss_chars": [ "'", "`" ] },
  "skip_prefixes": [ "Ledger-Claims:", "Co-Authored-By:" ],
  "skip_blocks": [ "Implementation:", "Realized-by:" ]
}
```

**The default code patterns** are the source's four, with two changes for doc-superpowers' own
vocabulary:

- The work ledger's keys are codes. When `docs/ledger/config.json` exists, the lint adds a pattern
  built from its configured ledger names for finalized keys, and the provisional-key pattern
  accepts every name the ledger's key rule allows.
- The architecture diagram model every generated architecture doc names (C4) joins the allowed
  words.

Labels such as a spec claim check (V1) or a spec status rule (R1) stay codes: a reader needs their
words too. The patterns keep the source's rule that each compiles the same way in Python and JavaScript,
so a project's JavaScript tools can share them. No test enforces that upstream.

The configuration is data. Its code patterns are compiled as regular expressions, so a pattern that
backtracks badly could slow the lint. Every caller already runs it under a budget or a CI timeout.
`SECURITY.md` names this.

`docs/writing/ceilings.json` is optional too:
`{"counting_version": <int>, "paths": {"<file or folder>": <count>}}`. Without it there is no
ceilings check. A file without `counting_version` reads as version 0, which is stale.

### The rule and its reference

`references/writing-rule.md` holds the rule as a marked block,
`<!-- doc-superpowers:writing-rule vX.Y.Z -->` to `<!-- /doc-superpowers:writing-rule -->`.
`bump-version` stamps it and `check-version` checks it, as for the search rule. `hooks status`
reports each copy in `AGENTS.md` or `CLAUDE.md` as current, outdated or absent.

The block is the source rule with its project-specific parts removed. It does not mention a project
lead or cite a project's records. Its scenarios are generic: someone deciding, someone reviewing a
pull request, someone picking up an issue, someone following a plan, an agent following
instructions, and someone learning the system. A project adds its own readers below the block.

`references/writing.md` is the reference page: the registers, the key format, what the lint counts
and cannot count, the verbs, the configuration, ceilings, and the anchor check. Its examples are
invented.

The skill's prompts point every agent that writes text at the rule, so text written through
doc-superpowers follows it whether or not a project copied the block.

### House style

These templates and prompts are rewritten to pass the lint in the register of what they produce:

- `references/doc-spec.md`: generated docs, specs and decision records (full).
- `references/agent-prompt-template.md`: every scope agent's instructions and the findings they
  return.
- `references/output-templates.md`: the audit report and the compliance report (terse).
- `references/release.md`: release-note entries.
- `references/ledger.md`: the filing procedure's item text (terse).
- `references/spec-lifecycle-actions.md`: the plan tasks `spec-inject` writes (terse).

A static gate in the test suites lints each template's text in its register, so a later edit cannot
bring a fault back.

### `writing migrate`

A skill action, `/doc-superpowers writing migrate [scope]`. It rewrites a project's living documents
until they pass, without changing what they say. The method is the source project's, as measured:

1. `writing check --format json` lists each file's findings first, so no agent picks passages.
2. Files are batched at about 5,000 touched words or ten files.
3. One agent per batch rewrites only the paragraphs that hold findings, plus first-use glosses. A
   file may grow by at most 5%. A cited code is linked rather than glossed where a link says
   enough.
4. The agent never changes decisions, values, identifiers, link targets, code, table data, quotes
   or front matter. It returns a claims table: each changed paragraph, whether it was kept,
   reworded or linked, and its risk.
5. `writing anchors` checks the batch against the commit it started from.
6. A reader agent gets the before text, the after text and the claims table. It reports a dropped,
   narrowed, widened or added claim.
7. The batch is committed with its range result recorded in the commit body, because range mode
   cannot replay a past range.
8. When a folder passes, `writing ceilings --update` records it at its count.

Decision records keep their approved text: a migration only adds links to them, and flags anything
else for the project to rule on.

### Where the lint runs by default

- **`audit`** adds a step: `writing counts` over living documents. Each folder with findings
  becomes one P3 (style) finding with its count per register and the line
  `Run /doc-superpowers writing migrate <folder>`. A file whose count is off its ceiling is listed
  with its findings.
- **`review-pr`** adds a **Writing** section: `writing range "$BASE...HEAD"` with the base it
  already resolved, one line per finding. The lint is the plugin's script, not the repository's,
  and reads the repository's files and configuration as data. So the rule that `review-pr` runs no
  repository script still holds. The CI review templates grant the verb.
- **The git pre-push hook** gains a writing leg, like its claims leg. It lints the range from the
  merge base with `origin/HEAD` (else `origin/main`) to HEAD. It runs only for the first pushed ref
  whose commit is HEAD's, because range mode reads HEAD. It prints
  `writing (advisory): <n> findings` and the first lines, under the hook budget.
  `DOC_SUPERPOWERS_WRITING_SKIP=1` turns it off.
- **When Python is missing or too old**, each of these prints the skip line and carries on.

**A team can turn the checks off.** `"enabled": false` in `docs/writing/config.json` turns off the
`audit` step, the `review-pr` section, the pre-push leg and the CI template for everyone, each
saying so in one line. The developer chose a committed switch because a rule on by default that a
team cannot decline reads as the tool overruling the team. It does not change the templates and
prompts: what doc-superpowers writes follows the rule either way. `DOC_SUPERPOWERS_WRITING_SKIP=1`
stays as one developer's switch for the pre-push leg.

Opt-in, as in the source:

- A CI workflow template, `doc-writing.yml`, runs `writing range` and, when `ceilings.json` exists,
  `writing ceilings`. It fails the check only with `--ci-strict`.
- Ceilings are opt-in by the presence of `docs/writing/ceilings.json`.

`setup` gains one item, `writing.rule`, on by default. It appends the marked block to `AGENTS.md`,
or to `CLAUDE.md` when there is no `AGENTS.md`, and shows the write in its review first. The help
text gains a `writing` topic.

### Known limits, decided

- **Loose glosses pass.** Words before a bracket that do not describe the code still pass. A check
  for a describing noun would flag most normal citations. The migrate action links cited codes instead, and the reference page names the limit.
- **Ordinary names shaped like codes are flagged.** A chip or a model name trips the code pattern.
  The fix is words, then the name in brackets, or the project's `allowed` list.
- **Range mode reads HEAD only.** A second base, to leave out a merged branch's text, is left for
  later.
- **Losing baselines in a doc-index merge.** A migration re-baselines many docs, and git's line
  merge of two such branches can keep the older baselines. doc-superpowers already handles this
  with its merge driver and `audit-merges`, so nothing is built for it here.

## Order

Each step is its own branch and release. Each default-on surface lands only after doc-superpowers'
own output passes and the fix it names exists.

1. **Engine.** `scripts/writing/`, the `writing` verbs, `defaults.json` and the configuration
   reader, and the fixes above. The three test suites move to the standard library's `unittest`,
   with a CI leg on Python 3.9. The locked pytest needs Python 3.10, so it cannot run at the floor. The rule block, the reference page and the help topic ship too.
   `check-ci.sh` gains a `writing` check, and `SECURITY.md` a `python3` row with floor 3.9.
2. **House style.** The template and prompt rewrites, the static gate over them, and the removal
   of the injected-task skip.
3. **Migrate.** The `writing migrate` action. Its acceptance run is doc-superpowers' own living
   documents (`docs/`, `references/`, `SKILL.md`, `AGENTS.md`, `CLAUDE.md`), which then take
   ceilings that `check-ci.sh` enforces. This repository's `docs/writing/config.json` sets their
   registers by the rule's own scenarios:
   - `SKILL.md`, `AGENTS.md` and `CLAUDE.md` are agent instructions, so terse.
   - `references/*.md` are reference pages read to learn the tool, so full.
   - Three texts are frozen at their counts: the search-rule block, the writing-rule block and the
     Spec Status Model wording. Projects copy the first two, and wrapper authors rely on the third,
     which a test pins word for word. They change only in a release meant to change them.
4. **Default on.** The `audit` and `review-pr` steps, the pre-push leg, the `setup` item,
   `hooks status` for the rule block, and the opt-in CI template.

Step 1 is also all that a project running its own copy of the lint needs to switch to the verbs.

## Left to the builder

- How `check-ci.sh` picks the 3.9 interpreter on each leg.
  GitHub's macOS image likely puts a newer Python first on the path.
- The exact JSON of `writing counts`, and how `audit` folds it into the report.
- How the configuration's path rules match: prefix lists, as in the source, or globs.
- The CI template's permissions and its `--allowedTools`, following the existing templates.
- The order of the ported tests and their fixtures. Every test of the writing lint (80) and the
  anchor check (15) moves. Of the second lint's 69, only those that test the shared parser and the
  code patterns move; its own checks stay in the source. Every fixture is invented.
