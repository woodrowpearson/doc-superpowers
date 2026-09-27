---
date: 2026-09-27
status: Resolved
priority: P1
type: bug
component: doc-tools
source: sweep-skill
cluster-key: sweep-skill:full-repo:I-4
run-id: 05ea982
related-files:
  - scripts/doc-tools.sh
  - scripts/test-doc-tools.sh
  - skills/doc-superpowers/SKILL.md
  - references/doc-spec.md
  - docs/issues/2026-07-29-usage-omits-implementation-verbs.md
screenshots: null
axiom-agent: null
branch: null
design-doc: null
report: docs/plans/2026-09-27-full-repo-05ea982-audit-findings.md
---

# I-4 — doc-tools input and CLI robustness

> Cluster **I-4** of sweep run `05ea982`, ranked #7 of 14. Evidence lives in the
> [findings index](../plans/2026-09-27-full-repo-05ea982-audit-findings.md) (S1, S2). The fix is
> **Task 3** of the [fix plan](../plans/2026-09-27-full-repo-05ea982-fix-plan.md). It also closes
> `2026-07-29-usage-omits-implementation-verbs.md`.

## Summary

Most callers of `doc-tools.sh` are LLM agents, and the tool trusts their input completely:
- flags are positional-only;
- unknown options are accepted silently;
- the `path:refs:type` stdin parser does no validation;
- every git call ends in `2>/dev/null || true`, so "git failed" reads as "no history".

`check-freshness` also carries its own inline copy of `compute_freshness`. That copy splits on tab,
which bash treats as IFS whitespace, so any empty middle field shifts the later columns.

## Incorrect assumption

"Callers pass well-formed input in the documented positional order." Also: "a failed git call means
no history", and "the inline `check-freshness` copy equals `compute_freshness`".

## Verified evidence (measured unless noted)

- `doc-tools.sh:511,519,627-640`: `check-freshness` splits `@tsv` records on tab. An empty middle
  field shifts the later fields and reports stale docs as **current**. Empty fields come from:
  - a null `code_commit`, which is the *normal* state for spec-first refs;
  - a null `content_hash`;
  - an empty `doc_type`.

  Other defects in the same code: refs are glob-expanded; empty refs make `git log` fail silently;
  `status` disagrees with `check-freshness`.
- `:316-453`: `build-index` replaces the whole index on zero or partial input.
  - Empty stdin gives `{}`, rc 0. Empty stdin is the default in an agent's non-TTY shell.
  - `--help </dev/null` also gives `{}`.
  - A one-line pipe leaves one key.
  - Deprecations are reset.
- `:1111,460-472,1973`: unknown options are accepted.
  - `deprecate-entry <old> --superseded-by <new>` deprecates the **successor**, rc 0.
  - `check-freshness --code-refs=x` and positional paths are ignored silently.
  - `remove-entry --help` rewrites the index.
- `:324-326,363-366,829-831,865-868`: the stdin parser does no validation.
  - A bare path is split into refs + type.
  - `a, b` stores `" b"`, which never matches.
  - CRLF is kept.
  - A colon in a path re-keys the entry.
  - A typo'd ref gives a null `code_commit`, so the doc is never stale.
  - The duplicate-key policy differs between verbs.
- `:526-537`: `--code-refs` is a raw two-way string prefix.
  - `src/m1` matched 260 of 400 docs; 40 were expected.
  - `''` matches everything.
  - C-quoted non-ASCII paths never match.
  - The bash filter costs O(N·R·S).
- `:56,177,…`: outside a repo, `check-freshness` reports everything current, rc 0.
- `:177,365,569,743,867`: porcelain `git log` honours `log.showSignature`, giving
  `code_commit: "No signature\n…"`.
- P3:
  - `:712-717`: an unknown key aborts the whole `update-index` batch.
  - `:28-34`: `hash_file` breaks on filenames containing a backslash.
  - `:56`: unborn HEAD gives `build_commit: "HEAD\nunknown"`.
  - `:124-129`: `docs//a.md` is stored as a separate key.
  - `:982-985,1169-1172`: `remove-entry`/`deprecate-entry` report the requested targets, not the
    actual changes.
  - `:281,1970,2004-2005`: in the dispatcher, `--help` returns rc 1, there is no "unknown
    subcommand" message, and help needs jq. `usage()` also omits the implementation verbs (the
    existing issue).
- X (security, P3): `code_commit` and tag values reach `git rev-list` as options, so `--output=…`
  truncates a file. An index key of `-` drains `check-freshness`'s stdin.

## Proposed fix (fix plan Task 3)

- One `_parse_args` loop per verb:
  - accepts `--flag X` and `--flag=X` anywhere;
  - `--help` prints usage and exits 0;
  - any other `-*` exits 2;
  - doc paths may not start with `-`.
- One `_entry_from_line`:
  - strips CR and splits on `:`;
  - rejects extra fields;
  - trims refs and drops empty ones;
  - uses the same array for JSON and for git;
  - warns on refs that match no tracked path.
- `build-index` exits non-zero on zero parsed entries, and refuses to overwrite a non-empty index
  without `--force`.
- One freshness function shared by `check-freshness` and `status`, with fields joined on `\x1f`.
- `--code-refs` matches by path segment. New `--code-refs-from <file|->`.
- One `git rev-parse --git-dir` check at start. Real exit codes instead of `|| true`. Plumbing
  `rev-list` instead of porcelain `log`. `--end-of-options` wherever a stored value reaches git.
- `hash_file` hashes stdin.
- Dispatcher and `usage()` are generated from one verb table.

## Acceptance criteria

- [x] Every Step-1 test in fix plan Task 3 passes.
- [x] `check-freshness` and `status` agree on every fixture.
- [x] `--help` exits 0 and lists every dispatchable verb.
- [x] `SKILL.md` tooling table and `references/doc-spec.md` describe the flag grammar, `--force` and
  `--code-refs-from`.

## Resolution (Task 3)

Resolved by Task 3 of the fix plan. `scripts/doc-tools.sh` now has one path for each kind of input:

- **One verb table (`_VERBS`).** The dispatcher (`_main`) and the usage text are both generated
  from it, so a verb exists only if it has a row, and `--help` cannot omit one. `--help`, `-h` and
  `help [<verb>]` exit 0 anywhere, and need neither jq nor git. No subcommand, or an unknown one,
  exits 2 and names it.
- **One argument loop (`_parse_args`).** `--opt VALUE` and `--opt=VALUE` are the same and may
  appear anywhere; `--` ends the options. An option the verb does not take, an option missing its
  value, or the wrong number of arguments exits 2 before anything is read or written.
  `deprecate-entry <old> --superseded-by <new>` deprecates only `<old>`.
- **One mapping-line parser (`_entry_from_line`).** It uses `IFS=: read -r path refs type extra`
  on the line minus its trailing CR. It rejects a bare path, a line with more than three fields,
  and a line whose first field is not a file while its first two or three fields joined by `:`
  name one on disk. That last case is an ambiguous `:` path: `docs/a:b.md` used to be keyed
  `docs/a` with ref `b.md`, rc 0. A `:` path whose file does not exist yet cannot be detected. Refs are split once, trimmed, and empty ones dropped; that one
  array is stored and handed to git. A ref that matches no tracked file draws a warning (one
  `git ls-files` per batch). A key listed twice keeps its first line, in both `build-index` and
  `add-entry`.
- **`build-index`** exits 1 on zero mapping lines. It refuses to replace an index with entries
  unless given `--force`. It checks this before reading stdin, and again under the lock. A
  missing or malformed index is still rebuilt: that is the recovery path.
- **One freshness evaluation (`_freshness_scan`)** serves `check-freshness` and `status`. One jq
  pass extracts every entry as a NUL-terminated record whose fields are joined with
  `\u001f` and read with `IFS=$'\x1f'`. bash evaluates each record (`_freshness_eval`, still the
  commit-based model; T4 swaps in content identity), and one jq pass renders the verdicts. No jq
  runs per entry: 3N + 4 jq spawns became 4.
- **`--code-refs` matches by path segment:** equal, the ref above the path, or the path above the
  ref, with `.` meaning the root. An empty list keeps nothing. `--code-refs-from <file|->` takes
  the same list one path per line, with no argv limit, for hooks (T7) and CI (T9).
- **git.** `_main` checks `git rev-parse --git-dir` once for repository verbs (exit 2 outside a
  work tree). Every git call's exit status is checked. Plumbing replaces porcelain
  (`git rev-list -1 <HEAD> -- <refs>`, `git rev-parse --verify -q HEAD^{commit}`), so
  `log.showSignature` cannot leak into `code_commit`, and an unborn HEAD gives
  `build_commit: null` and `repo_head: null`. A stored `code_commit` reaches git only if it is a
  full hex object id.
- **Paths.** `hash_file` hashes stdin, so a `\` in a name and a doc named `-` are safe.
  `docs//x.md` normalizes to `docs/x.md`. A path starting with `-` is refused. Repeated targets
  of `update-index`, `remove-entry` and `deprecate-entry` count once.
- **`update-index`** reports an unknown key, applies the rest, then exits 1.

Pinned by the `test_i4_*` tests in `scripts/test-doc-tools.sh`, plus the updated
`test_no_args_prints_usage`, `test_unknown_subcommand_prints_usage`, `test_help_flag` and
`test_build_index_empty_stdin`. RED against the pre-fix script: 122 of 167 assertions failed under
bash 5.3 and /bin/bash 3.2.

Behaviour changes that ship with this fix:

- `--help` exits 0. No subcommand, an unknown subcommand, or an unknown option exits 2, as does a
  repository verb run outside a git work tree. `fragments merge` already did.
- `build-index` needs `--force` over a non-empty index, and fails on empty input.
- `check-freshness` rejects positional arguments. A `--code-refs` value that is empty matches
  nothing.
- `update-index` no longer aborts the batch on an unknown key.
- A deprecated entry's `check-freshness` result gains `last_verified`, matching `status`.
- `untracked_docs` is sorted bytewise (`LC_ALL=C`).
- The `add-entry` rejection line reads `Rejected N invalid mapping line(s)`.

The prompt layer changed in the same Task:

- `skills/doc-superpowers/SKILL.md`: the tooling table, plus the *Command line*, *Mapping
  lines* and *Scoping by changed files* paragraphs; `init` step 12; `review-pr` steps 2–3; the
  untracked-docs row.
- `references/doc-spec.md`: *Writing entries*, *Command line*, and the `build_commit` row.
- The `spec-generate` bootstrap and step 8 in `references/spec-lifecycle-actions.md`,
  `references/spec-lifecycle-protocol.md` and `docs/workflows/doc-superpowers.md`.
- The *Command line* section of `docs/codebase-guide.md`.
