#!/usr/bin/env bash
# Fixture for eval "release-draft-untagged": v1.1.0 is released and tagged;
# then a breaking change went out as v1.2.0 — its RELEASE-NOTES.md entry and
# manifest bump committed ("release: v1.2.0"), but never tagged; since then a
# feat, a fix and a docs commit. The range starts at that release commit, so
# the suggested bump is MINOR (v1.3.0) — from the older v1.1.0 tag it would
# take the released breaking change for unreleased (MAJOR).
. "$(dirname "$0")/../lib.sh"
fx_init "$0"

fx_write package.json <<'JSON'
{
  "name": "csvtool",
  "version": "1.1.0"
}
JSON
fx_write README.md <<'MD'
# csvtool

`csvtool parse <file>` prints a CSV file as a table.
MD
fx_write src/parse.js <<'JS'
exports.parse = (text) => text.split('\n').map((l) => l.split(','));
JS
fx_write RELEASE-NOTES.md <<'MD'
# Release Notes

## v1.1.0 (2026-07-01)

### Features
- **Table output**: `csvtool parse` prints a table.
MD
fx_commit "release: v1.1.0"
git tag v1.1.0

fx_write src/parse.js <<'JS'
exports.parse = (text, sep = ',') => text.split('\n').map((l) => l.split(sep));
JS
fx_commit "feat!: parse takes the separator as its second argument"

fx_write RELEASE-NOTES.md <<'MD'
# Release Notes

## v1.2.0 (2026-08-01)

### Breaking Changes
- **Separator argument**: `parse(text, sep)` replaces the comma-only parser.

## v1.1.0 (2026-07-01)

### Features
- **Table output**: `csvtool parse` prints a table.
MD
sed 's/"1\.1\.0"/"1.2.0"/' package.json > package.json.tmp && mv package.json.tmp package.json
fx_commit "release: v1.2.0"

fx_write src/export.js <<'JS'
exports.toCsv = (rows) => rows.map((r) => r.join(',')).join('\n');
JS
fx_commit "feat: add the export command"
fx_write src/parse.js <<'JS'
exports.parse = (text, sep = ',') => (text ? text.split('\n').map((l) => l.split(sep)) : []);
JS
fx_commit "fix: handle empty input in the parser"
printf '\nSee `csvtool --help`.\n' >> README.md
fx_commit "docs: mention --help in the README"

rel=$(git log -1 --format=%H -S '## v1.2.0' -- RELEASE-NOTES.md)
fx_expect "v1.2.0 is not tagged" test -z "$(git tag -l v1.2.0)"
fx_expect "the nearest release tag is the older v1.1.0" test "$(git describe --tags --abbrev=0 --match 'v[0-9]*')" = v1.1.0
fx_expect "the v1.2.0 heading was added by the release commit" test "$(git log -1 --format=%s "$rel")" = "release: v1.2.0"
fx_expect "three commits follow it" test "$(git rev-list --count "$rel..HEAD")" = 3
fx_expect "the breaking change is before it" test "$(git log --format=%s "$rel..HEAD" | grep -c '!:' || true)" = 0
fx_expect "no fragments" test ! -e RELEASE-NOTES.next
fx_expect "the manifest is at 1.2.0" test "$(jq -r .version package.json)" = 1.2.0
