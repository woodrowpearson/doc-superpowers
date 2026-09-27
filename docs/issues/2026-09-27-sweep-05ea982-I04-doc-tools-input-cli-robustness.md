---
date: 2026-09-27
status: Open
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

- [ ] Every Step-1 test in fix plan Task 3 passes.
- [ ] `check-freshness` and `status` agree on every fixture.
- [ ] `--help` exits 0 and lists every dispatchable verb.
- [ ] `SKILL.md` tooling table and `references/doc-spec.md` describe the flag grammar, `--force` and
  `--code-refs-from`.
