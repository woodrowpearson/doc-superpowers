---
date: 2026-07-29
status: Open
priority: P2
type: bug
component: doc-index
source: manual
related-files:
  - scripts/merge-doc-index.sh
  - scripts/doc-tools.sh
  - scripts/test-merge-driver.sh
  - docs/conventions.md
screenshots: null
axiom-agent: null
branch: null
design-doc: null
report: null
---

## Summary

The doc-index merge driver reads the top-level schema version from `.version`,
but `build-index` has written it as `schema_version` since the schema-2 rename.
The two names never meet, so on any index produced by a current `build-index`
the driver would compute `version: 0` and drop `schema_version` from its output
entirely.

This is **latent, not active**. It is correct for this repository today, which
is why it must be described precisely or the follow-up is unreproducible.

## Description

### Why it is inert right now

`docs/.doc-index.json` in this repo predates the rename and still carries a
top-level `version: 1` with no `schema_version` — exactly as
`docs/conventions.md` documents. Verified 2026-07-29:

```
$ jq -r 'keys' docs/.doc-index.json
["build_commit","docs","generated_at","generated_by","version"]
```

So the driver's `.version` read resolves, `max` picks `1`, and the merged
output is right. Nothing is broken for any consumer whose index was built
before the rename and has only ever been maintained incrementally
(`update-index` / `add-entry` / `move-entry` / `remove-entry` /
`deprecate-entry` all preserve unrecognized top-level fields rather than
re-deriving them).

### When it would bite

The moment a repo runs `build-index` — a full rebuild, which
`docs/workflows/doc-superpowers.md` documents as the normal recovery path after
a large refactor — the index is re-minted with `schema_version: 2` and no
`version` key. From that point the driver's

```jq
version: ([.version, $base[0].version, $theirs[0].version] | map(. // 0) | max)
```

sees `null` on all three sides, `// 0` floors each to `0`, and emits
`version: 0`. `schema_version` is not in the driver's output object at all, so
it is silently dropped on the first merge. A rebuilt index therefore loses its
schema marker and gains a bogus one the first time two branches touch it.

### Locations

| File | Line | What it does |
|---|---|---|
| `scripts/merge-doc-index.sh` | ~78 | reads `.version`, emits `version:` |
| `scripts/doc-tools.sh` | ~439, ~445 | `build-index` writes `schema_version: 2` |

### Not introduced by `move-entry`

This predates the v2.14.0 `move-entry` work and is unrelated to it — it was
found while planning that change and is recorded separately rather than
widening that diff. `move-entry` does not touch top-level index fields.

## Steps to Reproduce

1. In a scratch repo, build an index from scratch:
   `echo 'docs/a.md:src/:architecture' | doc-tools.sh build-index`
2. `jq -r 'keys' docs/.doc-index.json` — observe `schema_version`, no `version`.
3. Create two branches that each add a different entry, and merge one into the
   other with the driver registered.
4. `jq -r '{version, schema_version}' docs/.doc-index.json` — observe
   `version: 0` and `schema_version: null`.

## Expected Behavior

The driver reads and re-emits whichever schema field the index actually
carries, and never invents a version number it did not read. A missing schema
field should not silently become `0`.

## Actual Behavior

Reads only `.version`; floors an absent value to `0` rather than distinguishing
"absent" from "zero"; omits `schema_version` from its output object, so a
rebuilt index loses it on the first merge.

## Technical Context

- Introduced by the schema 1 → 2 rename in `build-index`, which did not update
  the driver.
- `scripts/test-merge-driver.sh` (19 assertions) does not cover the top-level
  version field on a `schema_version`-shaped index, which is why it stayed
  hidden — every fixture in that suite is `version`-shaped like the live index.

## Proposed Solution

Read both names and preserve whichever was present, e.g. accept
`(.schema_version // .version)` on each side, carry the field forward under the
name the inputs used, and treat "no schema field on any side" as "omit it"
rather than `0`. Add a `test-merge-driver.sh` fixture built by the current
`build-index` so the suite would have caught this.

Consider also whether `build-index` should keep writing `version` alongside
`schema_version` for one release as a compatibility bridge — that is the
decision this issue exists to force, not to pre-empt.
