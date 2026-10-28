<!-- doc-superpowers release notes for the next version (spaced paths), drafted by hand on fix/spaced-tmpdir-suites. Not a PR-<N> fragment: `fragments merge` skips this name, so the release session folds it into the next version's entry itself and deletes it in the release commit. -->
`check-ci.sh` now takes an interpreter path that holds a space, and every test suite runs its fixtures under a spaced path, whatever `TMPDIR` is.

### Fixes
- **`check-ci.sh --bash` with a spaced path.** The interpreter list was space-joined and word-split, so `--bash "/Volumes/My Disk/bin/bash"` stopped with `--bash /Volumes/My: not an executable bash` (exit 2), and so did a detected interpreter under such a path. The list is now one path per line.

### Other
- Tests: the harness's scratch dir (`test-helpers.sh`'s `SUITE_TMP`) is named `suite tmp`, so every fixture repo, scratch file and installed workflow in all seven suites sits under a spaced path on every run. Before, the suites hit a spaced path only on a host whose `TMPDIR` had one, and three of them failed there on test bugs alone: `test-hooks.sh` passed an unquoted `GIT_EDITOR` (git runs it through `sh`) and wrote unquoted assignments into the doc-search env hook; `test-doc-pr-release.sh` word-split a workflow file list and rejected any step output whose value held a space (a `$RUNNER_TEMP` report path can; the check is now one `key=` line of at most 4,096 bytes). The `check-ci.sh` self-tests now pass a spaced `--bash` path on every run.
