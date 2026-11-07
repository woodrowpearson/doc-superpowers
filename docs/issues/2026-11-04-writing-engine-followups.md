---
date: 2026-11-04
status: Open
priority: P2
type: enhancement
component: writing
source: manual
related-files:
  - scripts/writing/lint.py
  - scripts/writing/markdown.py
  - scripts/writing/config.py
  - scripts/writing/anchors.py
  - scripts/check-ci.sh
  - scripts/test-doc-tools.sh
  - references/writing.md
screenshots: null
axiom-agent: null
branch: claude/doc-superpowers-writing-upstream-6024b3
design-doc: docs/superpowers/specs/2026-11-03-writing-rule-design.md
report: null
---

## Summary

The whole-branch review of the writing engine left these follow-ups. None blocks the first release. Each group says when it must be settled.

## At step 2's counting-version bump

Each of these moves counts, so settle them together and raise `COUNTING_VERSION` once.

- Removing the injected-task skip raises `COUNTING_VERSION`.
- `markdown.prose_lines` uses `str.splitlines`, so U+2028, U+0085 and form feed shift line numbers. Range mode can then drop a new sentence after one.
- `defined_codes` reads skipped blocks and quotes, so a bold label in a tool block defines a code.
- A fence indented four spaces or more counts as a fence. Keep it, since nested lists need it, and document it.
- Ledger glob rules reach nested folders and design docs. Decide, then pin.
- HTML comments and indented code are linted. Decide.

## Before step 4 makes the lint default-on

- A failed `git cat-file` reads as absent in `config.py`, so the default config is used without a word.
- A bad ledger config raises even with `enabled: false`.
- `_closest` took 77 s on a contrived reorganisation, against a hook budget of 20 s.
- One 2 MB single-line paragraph ran past 120 s.
- `ceilings --update` counts untracked files.
- The writing tests' Python skip ignores a `DOC_SP_REQUIRE_*` gate.
- No per-file opt-out exists for a typed doc.
- The stale-version line tells an older engine to run `--update`, which downgrades a newer file.
- `range` reads the config at HEAD, so a PR can relax its own limits.
- One non-UTF-8 file aborts all of `counts`.
- `check-ci.sh writing` passes on "Ran 0 tests" on a host whose newest Python is 3.9 to 3.11.

## No user effect, whenever convenient

- The `markdown` module name collides with PyPI's in IDEs.
- `anchors.py` imports the underscore helpers of `lint.py`.
- `lint.py` is about 1250 lines, so a `ceilings.py` split is possible.
- `update_ceilings` writes in place.
- `test-doc-tools.sh` copies the search-rule tests for the writing rule.
- Link-existence checks follow the host filesystem's case rules.
