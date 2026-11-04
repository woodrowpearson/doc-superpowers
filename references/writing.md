# The writing rule and its lint

**Read by** anyone who writes for a project that follows the rule, and anyone who runs or configures the lint. The rule itself is the marked block in `references/writing-rule.md`, which a project copies into `AGENTS.md` or `CLAUDE.md`. This page holds what the block points to: the key format, the registers (the sets of limits that texts are judged by), the lint's verbs and their limits.

The rule asks writers to put first what the reader needs, to give every code (a short label for a record, such as `KX7`) words or a link, and to keep sentences short. The lint counts what it can of that. It finds a code with nothing explaining it, a sentence over the word limit of its register, and a list item over the word or sentence limit of its register. It reports, for information only, how many backtick spans a file has for every 100 words.

The lint is standard-library Python, version 3.9 or later. It downloads nothing, writes no file except through `ceilings --update`, and runs only when you call it. In this release nothing calls it for you.

```bash
doc-superpowers tools writing check docs/harbour-notes.md
doc-superpowers tools writing range origin/main...HEAD
```

`doc-superpowers tools writing <verb>` and `scripts/doc-tools.sh writing <verb>` are the same command. Each verb takes `--help`.

## The registers

A register sets the limits a text is judged by. `terse` is for text read between other work, and `full` is for text read to learn the system.

| Register | Words in a sentence | Words in a list item | Sentences in a list item |
|---|---|---|---|
| `terse` | 35 | 50 | 2 |
| `full` | 40 | no limit | no limit |

A file's register comes from its `doc_type` in the doc-index (`docs/.doc-index.json`, the index that tracks each doc's freshness) first and from its path second. The steps run in this order, and the first that applies decides.

1. A file whose name does not end in `.md`, or that sits under `docs/archive/`, has no register. It is never linted without `--profile`, whatever its doc-index type says.
2. When the file has an entry in `docs/.doc-index.json` with a `doc_type`, that type decides. A type the table below does not name is `full`.
3. Otherwise the first path rule that matches decides.
4. Otherwise the file has no register. `check` says so on standard error and goes on; it is not a finding.

| `doc_type` | Register |
|---|---|
| `plan`, `issue`, `audit` | `terse` |
| `design-spec`, `spec`, `adr`, `architecture`, `api-contracts`, `data-layer`, `infra`, `ci-cd`, `workflows`, `agentic`, `guide`, `codebase-guide`, `conventions` | `full` |
| any other type | `full` |

| Path rules, first match wins | Register |
|---|---|
| under `docs/archive/` | none |
| `AGENTS.md`, in any folder or at the top | `terse` |
| `CLAUDE.md`, in any folder or at the top | `terse` |
| under `docs/plans/`, name ending `-design.md` | `full` |
| under `docs/plans/` | `terse` |
| under `docs/issues/` | `terse` |
| under `docs/` | `full` |

Anything else has no register. That includes `README.md` and the files under `references/`, unless the doc-index types them or a project rule names them. `check --profile terse|full` overrides the lookup for every input.

A project's own rules come before these, and the folders of a work ledger's items come between the two (*Configuration*). A work ledger is the opt-in set of issue files that `doc-superpowers help ledger` describes.

**Records.** A plan, an issue, an audit or a design spec records a moment, and so does anything under `docs/archive/`. Only its doc-index type, or the archive folder, marks a file as a record. `ceilings` and `counts` leave records out, and a ceiling that names one is a finding. `range` lints the new sentences of a record that has a register, because that is what a branch wrote there. `check` lints a record you name. Archived files are never linted without `--profile`.

## What comes first

The rule's first item is to know the reader and the job they do with the text. The job decides the order. Each reader below gets the answer to their question before any background.

- **Someone decides.** The question, then the options, then the recommendation and why, then the date it is needed by, with the evidence behind links.
- **Someone reviews a pull request (PR).** What changed, in one sentence. Then what must hold before it merges, and what was not run.
- **Someone picks up an issue.** What is wrong, how to see it, and what done looks like.
- **Someone follows a plan.** The steps, each with the files it touches and the check that shows it worked.
- **An agent follows instructions.** The rules first and the commands after them.
- **Someone learns the system.** What it decides or requires, then why, then the detail.

A PR body for the reviewer opens with the change and the open risk, not with the history of how it came about:

```text
Moves the ferry rota sync to a nightly job; the harbour office sheet is
untouched. Before merge: the nightly job must finish in under ten minutes
on the staging copy. Not run: the weekend schedule, which has no fixture.
```

The block in `references/writing-rule.md` ends with room for a project's own readers. Add each in the same form: the reader, then what comes first.

## The key

A code is a short label for a record, such as a decision, an issue, a spec, a run or a finding. On its own it tells the reader nothing. The rule gives three ways to explain one:

- Put words before it and the code in brackets: the ferry rota decision (`KX7`).
- Make it a link; the link text may be the code itself.
- Give it an entry under `## Key`, and the code is explained everywhere in that file.

**What the lint reads as a code.** Four default shapes, plus the ledger ids of a work ledger that is on. A project adds shapes under `codes.patterns` (*Configuration*).

| Shape | Examples |
|---|---|
| capital letters and digits joined by hyphens, ending in a hyphen and a number, then optionally one lower-case letter | `ORB-12`, `ORB-12a`, `NAV-210`, `TRL-0317` |
| one to three capital letters and one to three digits, then optionally one lower-case letter | `KX7`, `KX7b`, `W5`, `RM4` |
| a lower-case name of up to 16 letters, digits and hyphens, then `-~` and four to eight hex digits | `beacon-~a1c9` |
| a `#` and a number | `#318` |

Some words match a shape and are not codes: `P0` to `P3`, `Q1` to `Q4`, `UTF-8`, `SHA-1`, `SHA-256`, `ISO-8601` and `C4`. Add more under `codes.allowed`.

**What counts as an explanation.** A code is explained when it sits inside round or square brackets that come right after a word or a digit, or after one of the characters in `codes.gloss_chars` (a quote, a backtick or an asterisk). It is explained when it is the text of a link. A code inside a file path is part of a file name and is never flagged. In the `full` register an explained code may stand bare later in the same file. The `terse` register wants an explanation at every use.

**The entry.** The lint looks for a bold label at the start of a line or list item, with words after it:

```markdown
## Key

- **KX7** The ferry rota decision for the harbour office.
- **KX9, RM4** The roster and the roof-access review, kept together.
```

Here is exactly what it parses.

- The label is the first bold span of the line, after any list marker. Every code in the label is defined, so one label may hold several.
- Words must follow the label on the same line, and at least one letter must remain once the codes are cut out. A code alone in a label defines nothing, and neither does a bold sentence with nothing after it.
- A heading that holds words as well as a code defines it too: `### KX7. The ferry rota`. A heading of codes alone defines nothing.
- An entry defines its codes for the whole file, above it as well as below. It defines nothing in any other file.
- Front matter and fenced code blocks hold no entries.
- The lint does not look for the heading `## Key`. An entry of this shape counts wherever it stands. Keep the entries together under that heading anyway, because a reader looks there.

## What the lint counts and cannot count

It counts three things, and each is a finding with a rule name.

| Rule | Fires when |
|---|---|
| `bare-code` | a code that no brackets after words, no link and no key entry explains |
| `long-sentence` | a sentence has more words than the register allows |
| `long-item` | a list item has more words, or more sentences, than the register allows |

A finding prints as `path:line: rule: message`:

```text
docs/harbour-notes.md:12: bare-code: "KX7" has no words explaining it; name the record, then give the code in brackets after those words, link it, or define it under ## Key
docs/harbour-notes.md:20: long-sentence: a sentence of 47 words is over the full limit of 40
docs/harbour-notes.md: 3.1 backtick spans per 100 words
```

The last line is the density, for information only. It has no limit and never fails a run.

It cannot tell whether the words beside a code describe it, or whether a short sentence says anything. It cannot tell whether plain words hide jargon, or whether the main point comes first. The rest of the rule belongs to the writer and the reviewer (*Known limits*). A clean run means the counted faults are absent. It does not mean the text is good.

## How it reads a file

The lint reads prose and leaves the rest alone.

- **Left out.** Front matter (a YAML block from `---` on line 1 to the next `---`), fenced code blocks, headings, table rows and quoted lines that start with `>`.
- **Tool-written lines.** A paragraph that opens with a skip prefix is passed over. The defaults are `Ledger-Claims:` and `Co-Authored-By:`. So is the block a tool writes after a `skip_blocks` header. So are the plan tasks `spec-inject` writes. Their headings read `## Task N: <phrase>`, with two to four `#`, and the phrase starts with Update governing specs, Land the spec amendment, Claims gate, Final claims gate, Ledger notices or Finalize all governing specs. A task runs to the next heading of its level or above. Its wording is the template's, not the author's. A heading that starts with one of those phrases but lacks `Task N:` is not skipped.
- **Paragraphs.** Lines that wrap are joined with single spaces, so a bracket can open on one line and close on the next. Each list item is a paragraph of its own, and only its indented lines extend it.
- **Words.** Whitespace-separated tokens, with link targets removed. A link counts as its text. A list marker (a bullet or a number) and a task box (`[ ]`) are not words.
- **Sentences.** A sentence ends at `.`, `!` or `?` followed by whitespace and anything but a lower-case letter. `e.g.`, `i.e.`, `cf.` and `vs.` do not end one, and neither does a file name such as `rota_sync.py`.
- **Files and encodings.** A byte-order mark is dropped and CRLF reads as LF. A file that is not UTF-8 is an error (exit 2), not a finding.

## The verbs

All five verbs share one exit-code scheme.

| Exit | Meaning |
|---|---|
| 0 | Clean. `counts` exits 0 or 2, never 1. |
| 1 | Findings: a bare code or a limit exceeded, a ceiling that failed, or an anchor lost. |
| 2 | A wrong command line, an input that cannot be read or decoded, a malformed configuration or ceilings file, a base git cannot resolve, or a crash in the lint, printed as `writing: internal error: <type>: <message>`. |
| 3 | The check could not run. |

Exit 3 prints `writing: skipped (needs python3 3.9 or later)` when the interpreter is missing or too old. It prints `writing: skipped (no scripts/writing/ beside doc-tools.sh)` from a vendored copy of `doc-tools.sh`, which carries no engine. The interpreter is `python3` unless `DOC_SUPERPOWERS_PYTHON` names another. The engine runs as `python3 -I -B -X utf8`: isolated, writing no bytecode, and reading UTF-8 whatever the locale.

### check

`writing check [--profile terse|full] [--github] [--format text|json] [--name LABEL] FILE...`

Lints whole files, or standard input for `-`, which may be named once. Standard input has no path, so it has no register and needs `--profile`. `--name` only sets the label its findings carry, and goes with `-`. Without `--profile`, each file's register comes from the lookup in *The registers*, with the path taken from the top of the repository. `--github` is for text GitHub renders, such as a PR body, where an issue number (`#318`) is linked already.

### range

`writing range [--format text|json] BASE...HEAD`

Lints the sentences the committed HEAD gained over the merge base of `BASE` and `HEAD`. It reads commits only, never the working tree, and the head must be `HEAD`. `BASE` alone means `BASE...HEAD`. A head other than `HEAD` is a usage error.

- A sentence is the branch's own when a line the diff adds holds it, and neither the old copy of the file nor any Markdown file the branch deletes holds one like it. Digits, link targets and line breaks do not tell two sentences apart.
- It follows renames (`git diff -M`), so a renamed file compares against its old name. A sentence that only moved, within its file or out of a Markdown file the branch deletes, is old.
- When a new sentence is close to an older one that HEAD no longer holds (a difflib ratio of 0.6 or more over their words), it is a rewrite. Only the harm the rewrite did is reported: a code that was not bare before, more words in the sentence, more words or sentences in the item.
- Registers come from the configuration and doc-index as committed at HEAD. Records are linted. `docs/archive/` never is. A file with no register is passed over without a word.

After the findings, each file with new sentences gets one density line, counted over the whole file.

### ceilings

`writing ceilings [--file PATH] [--base REF] [--update]`

See *Ceilings*.

### counts

`writing counts [--format text|json] [PATH...]`

It counts the findings of the working tree for each folder and register, leaving out records and files with no register. `PATH` is a git pathspec from the working directory. It counts files git knows or does not ignore, so a new file counts before it is staged. A file at the top of the repository is in the folder `.`. It gates nothing.

```text
.: terse, 2 files, 0 findings
docs: full, 14 files, 6 findings
docs/guides: full, 3 files, 1 finding
counting version 1; 9 records skipped
```

### anchors

`writing anchors --base REF [--format text|json] FILE...`

See *The anchor check*.

### JSON

`check` and `range` with `--format json` print one list of objects, one per finding, and nothing else on standard output. A clean run prints `[]`. Each object has six fields.

| Field | Value |
|---|---|
| `path` | the file, as given |
| `line` | the line of the finding |
| `rule` | `bare-code`, `long-sentence` or `long-item` |
| `message` | the text after `rule:` in the text form |
| `paragraph_first_line` | where the finding's paragraph starts |
| `paragraph_last_line` | where it ends |

Density is not in the JSON. `counts --format json` prints an object: `counting_version`, `folders` (a list of objects with `folder`, `register`, `files` and `findings`) and `records_skipped`. `anchors` has its own fields (*The anchor check*). `ceilings` takes no `--format`.

## Configuration

`docs/writing/config.json` is optional, and a project states only what differs from the defaults. A malformed file exits 2 and names the file and the key at fault. An unknown key is an error, which catches a misspelled one.

```json
{
  "enabled": true,
  "registers": {
    "doc_types": { "runbook": "terse" },
    "paths": [{ "prefix": "docs/handover/", "register": "terse" }]
  },
  "limits": { "full": { "sentence": 30 } },
  "codes": {
    "patterns": ["(?<![A-Za-z0-9_])SR[0-9]{4}(?![A-Za-z0-9_])"],
    "allowed": ["H2"],
    "gloss_chars": ["~"]
  },
  "skip_prefixes": ["Reviewed-By:"],
  "skip_blocks": ["Changelog:"]
}
```

| Key | Sets |
|---|---|
| `enabled` | The switch for callers that run the lint unasked: the audit, the review and the hooks, in later releases. An explicit `check`, `range`, `ceilings` or `counts` always runs. |
| `registers.doc_types` | A doc-index type and its register, `terse` or `full`. |
| `registers.paths` | Path rules: a `prefix`, a `suffix` or both, and a `register` that is `terse`, `full` or `null` for never linted. |
| `limits` | Per register: `sentence`, `item` and `item_sentences`, each a whole number of 1 or more. `item` and `item_sentences` may be `null` for no limit. |
| `codes` | `patterns` (regular expressions), `allowed` (words that are not codes) and `gloss_chars` (single characters that let a bracket explain what stands before it). |
| `skip_prefixes` | Line prefixes whose paragraph is left alone. |
| `skip_blocks` | Headers that open a block of list items a tool wrote. The default is `Implementation:` and `Realized-by:`. |

**How a file combines with the defaults.**

- An object merges key by key. A scalar, `null` included, replaces the default: the example above leaves the other limits alone, and `{"limits": {"terse": {"item": null}}}` removes the terse item limit.
- A list adds to the default list, so you never repeat a default. Duplicates are dropped. In `registers.paths` your rules come first, so one of yours wins over a default.
- A path rule's suffix is tested against a slash plus the path. `/AGENTS.md` names that file in any folder, the top included, and no file whose name merely ends in `AGENTS.md`.

**A skipped block.** A header from `skip_blocks` opens a block only when it starts a line and is alone on it, or is followed by `[]`, which makes a block of one line. The block is the header, each `- ` item at any indent, and the indented lines that follow the header or an item. It ends at a blank line, at a fence, or at an unindented line that is not an item. Once a block has opened, no later header in the file opens another. A header with words after it, or inside a list item or a quote, is prose.

**The work ledger.** When `docs/ledger/config.json` exists, two things follow. The ids in `docs/ledger/ledgers.json` become one more code shape, so `orbit-14` is a code once a ledger is named `orbit`. The folder each `items.globs` entry names, up to its first wildcard, becomes a `terse` path rule. A glob with a wildcard in a folder name names no one folder and adds none. A glob with no wildcard at all names one file and adds a rule for that file.

## Ceilings

A ceiling holds a path to the number of findings it has today, so a project can adopt the rule on old text and keep it from getting worse. `docs/writing/ceilings.json` lists paths, each a Markdown file or a folder of them:

```json
{
  "counting_version": 1,
  "paths": { "docs/guides": 12, "docs/harbour-notes.md": 0 }
}
```

`writing ceilings [--file PATH] [--base REF] [--update]` reads the file as committed at HEAD, counts the Markdown files committed there under each path, each whole and in its own register, and prints one line per path. A count over its ceiling fails, and the findings are listed beneath it. A count under its ceiling fails too, with the number to set, so every gain is recorded. A path added in this range that names no Markdown file the lint reads fails, and so does a ceiling that names a record. A last line names the file and how many paths were checked. With no ceilings file at HEAD or at the base, that line stands alone and the run exits 0.

**A ceiling may fall but never rise, and a path may not leave the file.** The check compares the file with its copy at the merge base of `--base` and HEAD. `--base` defaults to the target of `origin/HEAD`, else `origin/main`. A ceiling that rises, or a path that leaves the file, passes only when the range changes `docs/writing/config.json` (any edit counts) or raises `counting_version` to the engine's. When it does, the line says which.

**The counting version.** The engine counts findings one way, and the number of that way is `COUNTING_VERSION`, which is 1 in this release. It changes only when a limit, a default code shape or any other counting rule moves the findings of text that did not change. A file with no `counting_version` is from before versions and reads as 0. A file recorded with another version than the engine's fails with one line, `writing ceilings: counted with version 0; this engine counts with 1: run writing ceilings --update`, and no counts are compared.

**Updating.** `--update` counts the working tree for each listed path and rewrites the file with the engine's version. It adds no path and removes none, and it takes no `--base`. If the file does not exist it exits 2 and shows what to create. If a listed path names a record it fails and leaves the file as it was. Commit the result.

## The anchor check

A rewrite may reword and reorder freely, but it should keep the landmarks a reader navigates by. `writing anchors --base REF [--format text|json] FILE...` compares each file in the working tree with its copy at `REF` and reports every anchor the new copy uses less often than the old.

| Kind | What it is |
|---|---|
| `identifier` | text between single backticks. A span that wraps over lines is joined, and its whitespace collapses. |
| `code` | whatever the code shapes of *The key* match, anywhere on a line, link text and link targets included |
| `number` | a number on any line, fences, table rows and headings included, with its decimal point or thousands separator. The digits of a code, an identifier, an inline link target or an ordered-list marker do not count. |
| `link-target` | the destination of an inline link or image, or of a reference definition. A footnote definition has none. |

A second rule covers links. Each relative destination the new copy adds, outside code spans and fenced code blocks, must point at a file or folder that exists, counted from the folder of the file. A `#fragment` and a `?query` are cut off and percent escapes are decoded first. URLs, a bare fragment, a destination that starts with `/` and one the base copy already held are not looked up.

The base is a commit and the other side is the working tree, never HEAD, so a rewrite can be checked before it is committed. A file missing from the base has nothing to lose, though its links are still looked up. Only the working-tree copy has to be UTF-8: undecodable bytes in the base copy are replaced, so the file is still compared.

Text mode prints `FILE:LINE: MESSAGE` for each finding, lost anchors first. A lost anchor is reported at the first line of the base copy that used it. Exit 0 means nothing was lost and no added link leads nowhere, 1 means one did, 2 and 3 are as above.

Each JSON object has `path`, `line`, `kind`, `anchor`, `rule` (`lost-anchor` or `unresolved-target`) and `message`. A `lost-anchor` object also has `before` (uses in the base copy), `after` (uses in the new copy) and `base_lines` (the base lines that used it, ascending).

An anchor lost in one place and gained in another nets out to nothing. Whether a statement got stronger or weaker, and whether a link leads where the author meant, are left to the reader who holds both texts.

## Known limits

- **No per-file opt-out for a typed, indexed doc yet.** A doc-index `doc_type` decides the register before any path rule, and a type cannot map to "never linted". Only `docs/archive/` is exempt.
- **Some characters shift line numbers.** Characters such as U+2028, U+0085 and the form feed split a line in the lint's reading but not in most editors. Reported line numbers can then differ from the editor's, and `range` can drop a new sentence that follows one.
- **Under `range`, a symlinked Markdown file is judged by the path it points to.** `range` reads what git stores for it, which is that path, not the file behind it. `check` follows the link, reads the file behind it and takes the register from the link's own path. `ceilings` and `counts` leave symlinks out.
- **The anchor check's file test follows the host file system.** On a case-insensitive system such as the macOS default, a link whose case is wrong still finds its file and passes.
- **A lost reference definition can report twice.** It does so only when its destination holds a standalone number, such as `notes-7.md`. It then reports once as a lost link target and once more for that number, because the destination of a reference definition is not set aside when numbers are counted.
- **The lint counts what it can.** The order for the reader, the scope of claims and the naming of things by purpose belong to the rule, not the lint. A review has to judge them.
