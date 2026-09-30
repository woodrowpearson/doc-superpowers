#!/usr/bin/env bash
# Tests for merge-doc-index.sh — the docs/.doc-index.json merge driver — and
# for the way install.sh registers it.
#
# The driver is a three-way merge: every assertion here is made against the
# BASE as well as the two sides. Most fixtures are built with the real
# doc-tools verbs and merged with real `git merge`, `git rebase` and
# `git revert`, in both directions, so a result that depends on which branch
# is checked out (the sweep 05ea982 I-5 P0) is caught.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

# Run the driver and doc-tools under the interpreter this suite was launched
# with, not whatever `#!/usr/bin/env bash` resolves to. See bash_bin_shim().
MERGE_DRIVER="$(bash_bin_shim "$SCRIPT_DIR/merge-doc-index.sh")"
DOC_TOOLS="$(bash_bin_shim "$SCRIPT_DIR/doc-tools.sh")"
export GIT_EDITOR=true

# A controllable clock. doc-tools stamps last_verified with
# `date -u +%Y-%m-%dT%H:%M:%SZ` at one-second resolution; the fixtures need
# exact orderings (and exact ties) without sleeping, so a `date` on PATH
# answers $FAKE_NOW for that one call shape and defers to the real date
# otherwise.
_REAL_DATE="$(command -v date)"
_CLOCK_DIR="$SUITE_TMP/clock"
mkdir -p "$_CLOCK_DIR"
cat > "$_CLOCK_DIR/date" <<EOF
#!/bin/sh
if [ -n "\${FAKE_NOW:-}" ] && [ "\$1" = "-u" ]; then printf '%s\n' "\$FAKE_NOW"; exit 0; fi
exec "$_REAL_DATE" "\$@"
EOF
chmod +x "$_CLOCK_DIR/date"
PATH="$_CLOCK_DIR:$PATH"

T0="2026-01-01T00:00:00Z"
T1="2026-01-01T00:00:01Z"
T2="2026-01-01T00:00:02Z"
T3="2026-01-01T00:00:03Z"
T4="2026-01-01T00:00:04Z"

echo "=== merge-doc-index.sh tests ==="

# ===================================================================
# Helpers
# ===================================================================

# Run a doc-tools verb at a fixed time. A fixture that cannot be built is a
# broken test, not a result: say so and stop the suite.
dt() {
  local now="$1"
  shift
  if ! FAKE_NOW="$now" "$DOC_TOOLS" "$@" > "$SUITE_TMP/dt.out" 2>&1; then
    cat "$SUITE_TMP/dt.out" >&2
    echo "FIXTURE ERROR: doc-tools $* failed" >&2
    exit 1
  fi
}

# Register the driver inside the fixture repo only (local config and
# .git/info/attributes, which no checkout changes).
register_driver() {
  git config merge.doc-index.name "doc-index test driver"
  git config merge.doc-index.driver "'$MERGE_DRIVER' %O %A %B"
  printf 'docs/.doc-index.json merge=doc-index\n' >> .git/info/attributes
}

# A fixture repo on main with three indexed, verified docs (a, b, c), each
# referencing its own source file, built with the real verbs:
#   build-index at T0, update-index at T1.
base_repo() {
  setup
  local n
  for n in a b c; do
    echo "# $n" > "docs/$n.md"
    echo "// $n" > "src/$n.js"
  done
  git add -A && git commit -qm "files"
  printf 'docs/a.md:src/a.js:spec\ndocs/b.md:src/b.js:spec\ndocs/c.md:src/c.js:guide\n' | dt "$T0" build-index
  dt "$T1" update-index docs/a.md docs/b.md docs/c.md
  git add -A && git commit -qm "base index"
  register_driver
}

commit_all() { git add -A && git commit -qm "$1"; }

# Edit the index by hand (a jq program), as a person with an editor would.
hand_edit() {
  jq "$1" docs/.doc-index.json > docs/.doc-index.json.new
  mv docs/.doc-index.json.new docs/.doc-index.json
}

# Merge and rebase two branches in both directions. Way n records its exit
# code, the resulting docs/.doc-index.json and git's output:
#   1 = checkout A, merge B      2 = checkout B, merge A
#   3 = rebase A onto B          4 = rebase B onto A
WAY_NAME=("" "merge B into A" "merge A into B" "rebase A onto B" "rebase B onto A")
WAY_RC=()
WAY_IDX=()
WAY_LOG=()
_way() {
  local n="$1" op="$2" head="$3" other="$4" rc=0
  git checkout -q -f --detach "$head"
  case "$op" in
    merge) git merge --no-edit "$other" > "$SUITE_TMP/way.log" 2>&1 || rc=$? ;;
    rebase) git rebase "$other" > "$SUITE_TMP/way.log" 2>&1 || rc=$? ;;
  esac
  WAY_RC[$n]=$rc
  WAY_IDX[$n]=$(cat docs/.doc-index.json)
  WAY_LOG[$n]=$(cat "$SUITE_TMP/way.log")
  if [ "$rc" -ne 0 ]; then
    git merge --abort > /dev/null 2>&1 || true
    git rebase --abort > /dev/null 2>&1 || true
  fi
  git reset -q --hard
  git checkout -q -f main
}
run_ways() {
  _way 1 merge A B
  _way 2 merge B A
  _way 3 rebase A B
  _way 4 rebase B A
}

# Every way succeeded, and <jq filter> on the merged index gives <expected>.
assert_ways() {
  local filter="$1" expected="$2" msg="$3" n
  for n in 1 2 3 4; do
    assert_eq "0" "${WAY_RC[$n]}" "$msg [${WAY_NAME[$n]}: merged cleanly]"
    assert_json_field "${WAY_IDX[$n]}" "$filter" "$expected" "$msg [${WAY_NAME[$n]}]"
  done
}

# All four ways produced the same docs (key order aside: ours' order is kept,
# so it legitimately differs by direction).
assert_ways_same_docs() {
  local msg="$1" n ref
  ref=$(jq -S -c '.docs' <<<"${WAY_IDX[1]}" 2>&1)
  for n in 2 3 4; do
    assert_eq "$ref" "$(jq -S -c '.docs' <<<"${WAY_IDX[$n]}" 2>&1)" "$msg [${WAY_NAME[$n]} = ${WAY_NAME[1]}]"
  done
}

# Every way stopped with a conflict, conflict markers in the index and the
# conflicting key named.
assert_ways_conflict() {
  local key="$1" msg="$2" n
  for n in 1 2 3 4; do
    assert_true "$msg [${WAY_NAME[$n]}: exit non-zero]" test "${WAY_RC[$n]}" -ne 0
    assert_contains "${WAY_IDX[$n]}" "<<<<<<< ours" "$msg [${WAY_NAME[$n]}: ours marker]"
    assert_contains "${WAY_IDX[$n]}" ">>>>>>> theirs" "$msg [${WAY_NAME[$n]}: theirs marker]"
    assert_contains "${WAY_LOG[$n]}" "$key" "$msg [${WAY_NAME[$n]}: names $key]"
  done
}

# --- direct driver invocation on files ---------------------------------------

B="$SUITE_TMP/mdm-base.json"
O="$SUITE_TMP/mdm-ours.json"
T="$SUITE_TMP/mdm-theirs.json"
RES="$SUITE_TMP/mdm-result.json"
DRV_ERRF="$SUITE_TMP/mdm-err.txt"

# drive: %O=$B, %A=a copy of $O, %B=$T.  drive_swapped: the other direction.
DRV_RC=0
DRV_OUT=""
DRV_ERR=""
_drive() {
  cp "$1" "$RES"
  DRV_RC=0
  "$MERGE_DRIVER" "$B" "$RES" "$2" 2> "$DRV_ERRF" || DRV_RC=$?
  DRV_OUT=$(cat "$RES")
  DRV_ERR=$(cat "$DRV_ERRF")
}
drive() { _drive "$O" "$T"; }
drive_swapped() { _drive "$T" "$O"; }

# A verified entry, as update-index writes it.
ENTRY='{"content_hash":"sha256:h0","code_refs":["src/a.js"],"code_oids":{"src/a.js":"oid0"},"code_commit":"c0","doc_type":"spec","replaces":null,"superseded_by":null,"last_verified":"2026-01-01T00:00:01Z"}'

# Write a v3 index with the given docs object (JSON) to a file.
write_index() {
  jq -n --argjson d "$2" \
    '{schema_version: 3, generated_by: "doc-superpowers", generated_at: "2026-01-01T00:00:00Z", build_commit: "b0", docs: $d}' > "$1"
}
# Derive a side (or the base itself) from the base with a jq program.
derive() { jq "$2" "$B" > "$1.new" && mv "$1.new" "$1"; }

# ===================================================================
# Real verbs, real git: the brief's cases
# ===================================================================

echo ""
echo "--- deprecate vs update-index ---"
base_repo
git checkout -q -b A
dt "$T2" deprecate-entry --superseded-by docs/b.md docs/a.md
commit_all "A: deprecate a"
git checkout -q -b B main
echo "// a changed" > src/a.js
git add -A && git commit -qm "B: code"
dt "$T3" update-index docs/a.md
commit_all "B: re-verify a"
A_OID=$(git rev-parse B:src/a.js)
run_ways
assert_ways '.docs["docs/a.md"].status' "deprecated" "deprecation survives the re-verify"
assert_ways '.docs["docs/a.md"].superseded_by' "docs/b.md" "superseded_by survives"
assert_ways '.docs["docs/a.md"].last_verified' "$T3" "re-verification survives the deprecation"
assert_ways '.docs["docs/a.md"].code_oids["src/a.js"]' "$A_OID" "re-verified code_oids survive"
assert_ways '.docs["docs/b.md"].replaces' "docs/a.md" "successor's replaces survives"
assert_ways_same_docs "deprecate vs update-index"
teardown

echo ""
echo "--- move-entry repoint (+ set-code-refs) vs add-entry ---"
base_repo
dt "$T2" deprecate-entry --superseded-by docs/b.md docs/a.md
commit_all "a superseded by b"
git checkout -q -b A
git mv docs/b.md docs/b2.md
git commit -qm "A: move b"
dt "$T3" move-entry docs/b.md docs/b2.md
dt "$T3" set-code-refs docs/c.md --refs src/c.js,src/a.js
commit_all "A: move-entry + refs"
git checkout -q -b B main
echo "# d" > docs/d.md
echo "// d" > src/d.js
git add -A && git commit -qm "B: d"
printf 'docs/d.md:src/d.js:guide\n' | dt "$T4" add-entry
commit_all "B: add d"
run_ways
assert_ways '.docs | keys | join(",")' "docs/a.md,docs/b2.md,docs/c.md,docs/d.md" "moved key re-keyed, added key kept"
assert_ways '.docs["docs/a.md"].superseded_by' "docs/b2.md" "repointed superseded_by survives"
assert_ways '.docs["docs/b2.md"].replaces' "docs/a.md" "moved successor keeps replaces"
assert_ways '.docs["docs/c.md"].code_refs | join(",")' "src/c.js,src/a.js" "set-code-refs change survives"
assert_ways '[.docs[] | (.superseded_by, .replaces) | select(. != null)] - (.docs | keys) | length' "0" "no dangling superseded_by/replaces"
assert_ways_same_docs "repoint vs add"
teardown

echo ""
echo "--- hand edit vs untouched ---"
base_repo
git checkout -q -b A
hand_edit '.docs["docs/c.md"].doc_type = "workflow" | .docs["docs/c.md"].code_refs += ["src/b.js"]'
commit_all "A: hand edit c"
git checkout -q -b B main
echo "# b, revised" > docs/b.md
git add -A && git commit -qm "B: doc"
dt "$T3" update-index docs/b.md
commit_all "B: re-verify b"
run_ways
assert_ways '.docs["docs/c.md"].doc_type' "workflow" "hand-edited field survives"
assert_ways '.docs["docs/c.md"].code_refs | join(",")' "src/c.js,src/b.js" "hand-edited refs survive"
assert_ways '.docs["docs/b.md"].last_verified' "$T3" "other side's re-verify survives"
assert_ways_same_docs "hand edit vs untouched"
teardown

echo ""
echo "--- delete vs modify: a conflict, never a silent drop ---"
base_repo
git checkout -q -b A
dt "$T2" remove-entry docs/c.md
commit_all "A: remove c"
git checkout -q -b B main
echo "// c changed" > src/c.js
git add -A && git commit -qm "B: code"
dt "$T3" update-index docs/c.md
commit_all "B: re-verify c"
run_ways
assert_ways_conflict "docs/c.md" "delete vs modify"
teardown

echo ""
echo "--- delete on one side, untouched on the other ---"
base_repo
git checkout -q -b A
dt "$T2" remove-entry docs/c.md
commit_all "A: remove c"
git checkout -q -b B main
echo "// b changed" > src/b.js
git add -A && git commit -qm "B: code"
dt "$T3" update-index docs/b.md
commit_all "B: re-verify b"
run_ways
assert_ways '.docs | has("docs/c.md")' "false" "deletion applies in every direction"
assert_ways '.docs["docs/b.md"].last_verified' "$T3" "the other side's change survives"
assert_ways_same_docs "delete on one side"
teardown

echo ""
echo "--- tie on last_verified: both sides change one entry, neither verifies ---"
base_repo
git checkout -q -b A
dt "$T2" set-code-refs docs/b.md --refs src/b.js,src/c.js
commit_all "A: refs"
git checkout -q -b B main
dt "$T2" deprecate-entry docs/b.md
commit_all "B: deprecate"
run_ways
assert_ways '.docs["docs/b.md"].code_refs | join(",")' "src/b.js,src/c.js" "one side's refs survive the tie"
assert_ways '.docs["docs/b.md"].status' "deprecated" "the other side's deprecation survives the tie"
assert_ways '.docs["docs/b.md"].last_verified' "$T1" "last_verified untouched"
assert_ways_same_docs "tie on last_verified"
teardown

echo ""
echo "--- tie with null last_verified (add-entry does not attest) ---"
base_repo
echo "# d" > docs/d.md
echo "// d" > src/d.js
git add -A && git commit -qm "d"
printf 'docs/d.md:src/d.js:guide\n' | dt "$T2" add-entry
commit_all "index d (unverified)"
git checkout -q -b A
dt "$T3" set-code-refs docs/d.md --refs src/d.js,src/a.js
commit_all "A: refs"
git checkout -q -b B main
dt "$T3" deprecate-entry docs/d.md
commit_all "B: deprecate"
run_ways
assert_ways '.docs["docs/d.md"].last_verified' "null" "last_verified stays null"
assert_ways '.docs["docs/d.md"].code_refs | join(",")' "src/d.js,src/a.js" "refs survive"
assert_ways '.docs["docs/d.md"].status' "deprecated" "deprecation survives"
assert_ways_same_docs "null last_verified tie"
teardown

echo ""
echo "--- same field, no newer last_verified: set-code-refs on both sides is a conflict ---"
base_repo
git checkout -q -b A
dt "$T2" set-code-refs docs/c.md --refs src/c.js,src/a.js
commit_all "A: c + a.js"
git checkout -q -b B main
dt "$T3" set-code-refs docs/c.md --refs src/c.js,src/b.js
commit_all "B: c + b.js"
run_ways
assert_ways_conflict "docs/c.md: both sides changed code_refs" "set-code-refs vs set-code-refs"
teardown

# GH #22: move-entry repoints the code_refs / code_oids of every entry citing
# the moved doc, so two branches that each move a different doc cited by ONE
# entry both change that entry while last_verified ties. The driver merges those
# as in-place substitutions (code_refs) and key by key (code_oids); an edit that
# the substitutions cannot be applied to still conflicts — never a silent loss.
cite_repo() {
  base_repo
  echo "# d" > docs/d.md
  git add -A && git commit -qm "d"
  printf 'docs/d.md:docs/a.md,docs/b.md,src/c.js:guide\n' | dt "$T1" add-entry
  dt "$T1" update-index docs/d.md
  commit_all "d cites a and b"
  A_ID=$(jq -r '.docs["docs/d.md"].code_oids["docs/a.md"]' docs/.doc-index.json)
  B_ID=$(jq -r '.docs["docs/d.md"].code_oids["docs/b.md"]' docs/.doc-index.json)
}

echo ""
echo "--- parallel move-entry repoints of one citing entry merge cleanly (GH #22) ---"
cite_repo
git checkout -q -b A
git mv docs/a.md docs/a2.md && git commit -qm "A: move a"
dt "$T2" move-entry docs/a.md docs/a2.md
commit_all "A: re-key a"
git checkout -q -b B main
git mv docs/b.md docs/b2.md && git commit -qm "B: move b"
dt "$T3" move-entry docs/b.md docs/b2.md
commit_all "B: re-key b"
run_ways
assert_ways '.docs["docs/d.md"].code_refs | join(",")' "docs/a2.md,docs/b2.md,src/c.js" "both repoints kept, in place"
assert_ways '.docs["docs/d.md"].code_oids["docs/a2.md"]' "$A_ID" "a's recorded id under a2"
assert_ways '.docs["docs/d.md"].code_oids["docs/b2.md"]' "$B_ID" "b's recorded id under b2"
assert_ways '.docs["docs/d.md"].code_oids | keys | length' "3" "no stale key left"
assert_ways_same_docs "parallel repoints"
teardown

echo ""
echo "--- a move-entry repoint vs a set-code-refs that adds a ref: both kept (GH #22) ---"
cite_repo
git checkout -q -b A
git mv docs/a.md docs/a2.md && git commit -qm "A: move a"
dt "$T2" move-entry docs/a.md docs/a2.md
commit_all "A: re-key a"
git checkout -q -b B main
dt "$T3" set-code-refs docs/d.md --refs docs/a.md,docs/b.md,src/c.js,src/b.js
commit_all "B: d also covers b.js"
run_ways
assert_ways '.docs["docs/d.md"].code_refs | join(",")' "docs/a2.md,docs/b.md,src/c.js,src/b.js" "repoint applied to the widened list"
assert_ways '.docs["docs/d.md"].code_oids | has("docs/a2.md") and has("src/b.js") and (has("docs/a.md") | not)' "true" "code_oids carries both changes"
assert_ways_same_docs "repoint vs added ref"
teardown

echo ""
echo "--- a move-entry repoint vs a set-code-refs that drops the moved ref: a conflict (GH #22) ---"
cite_repo
git checkout -q -b A
git mv docs/a.md docs/a2.md && git commit -qm "A: move a"
dt "$T2" move-entry docs/a.md docs/a2.md
commit_all "A: re-key a"
git checkout -q -b B main
dt "$T3" set-code-refs docs/d.md --refs docs/b.md,src/c.js
commit_all "B: d stops citing a"
run_ways
assert_ways_conflict "docs/d.md: both sides changed code_refs" "repoint vs a drop of the moved ref"
teardown

echo ""
echo "--- two same-length set-code-refs edits (a remove plus an add at one position): a conflict (GH #22) ---"
cite_repo
git checkout -q -b A
dt "$T2" set-code-refs docs/d.md --refs docs/a.md,src/c.js,src/d.js
commit_all "A: d drops b, gains d.js"
git checkout -q -b B main
dt "$T3" set-code-refs docs/d.md --refs docs/a.md,docs/b.md,src/d.js
commit_all "B: d drops c.js, gains d.js"
run_ways
assert_ways_conflict "docs/d.md: both sides changed code_refs" "remove + add on both sides is not a substitution"
teardown

echo ""
echo "--- A moves a citing doc while B moves a doc it cites: a conflict, documented under Renames ---"
cite_repo
git checkout -q -b A
git mv docs/d.md docs/d2.md && git commit -qm "A: move d"
dt "$T2" move-entry docs/d.md docs/d2.md
commit_all "A: re-key d"
git checkout -q -b B main
git mv docs/a.md docs/a2.md && git commit -qm "B: move a"
dt "$T3" move-entry docs/a.md docs/a2.md
commit_all "B: re-key a (repoints d)"
run_ways
assert_ways_conflict "docs/d.md: deleted on one side, changed on the other" "a re-key against a repoint of the re-keyed entry"
teardown

echo ""
echo "--- same field, no newer last_verified: move-entry repoint vs deprecate --superseded-by ---"
base_repo
dt "$T2" deprecate-entry --superseded-by docs/b.md docs/a.md
commit_all "a superseded by b"
git checkout -q -b A
git mv docs/b.md docs/b2.md
git commit -qm "A: move b"
dt "$T3" move-entry docs/b.md docs/b2.md
commit_all "A: move-entry repoints a"
git checkout -q -b B main
dt "$T3" deprecate-entry --superseded-by docs/c.md docs/a.md
commit_all "B: a superseded by c"
run_ways
assert_ways_conflict "docs/a.md: both sides changed superseded_by" "repoint vs re-deprecate"
teardown

echo ""
echo "--- same-second update-index on both sides, different results: a conflict ---"
base_repo
git checkout -q -b A
echo "// a changed" > src/a.js
git add -A && git commit -qm "A: code"
dt "$T3" update-index docs/a.md
commit_all "A: re-verify a (new code)"
git checkout -q -b B main
echo "# a, revised" > docs/a.md
git add -A && git commit -qm "B: doc"
dt "$T3" update-index docs/a.md
commit_all "B: re-verify a (new doc)"
run_ways
assert_ways_conflict "docs/a.md: both sides changed the verification record" "same-second re-verifies"
teardown

echo ""
echo "--- same-second update-index on both sides, same result: no conflict ---"
base_repo
git checkout -q -b A
dt "$T3" update-index docs/a.md
commit_all "A: re-verify a"
git checkout -q -b B main
dt "$T3" update-index docs/a.md
hand_edit '.docs["docs/a.md"].doc_type = "adr"'
commit_all "B: re-verify a, retype"
run_ways
assert_ways '.docs["docs/a.md"] | "\(.last_verified) \(.doc_type)"' "$T3 adr" "identical records merge, the other field is kept"
assert_ways_same_docs "same-second identical re-verifies"
teardown

echo ""
echo "--- one-sided change with an OLDER last_verified (a reverted re-verify) ---"
base_repo
echo "// a changed" > src/a.js
git add -A && git commit -qm "code"
dt "$T2" update-index docs/a.md
commit_all "re-verify a"
git checkout -q -b B
git revert --no-edit HEAD > /dev/null
git checkout -q -b A main
echo "# b, revised" > docs/b.md
git add -A && git commit -qm "A: doc"
dt "$T3" update-index docs/b.md
commit_all "A: re-verify b"
run_ways
assert_ways '.docs["docs/a.md"].last_verified' "$T1" "the older, one-sided last_verified is taken"
assert_ways '.docs["docs/a.md"].code_oids["src/a.js"]' "$(git rev-parse main~2:src/a.js)" "with its code_oids"
assert_ways '.docs["docs/b.md"].last_verified' "$T3" "the other side's re-verify survives"
assert_ways_same_docs "older one-sided change"
teardown

echo ""
echo "--- one-sided change beside a newer re-verify of the same entry ---"
base_repo
git checkout -q -b A
echo "# a, revised" > docs/a.md
git add -A && git commit -qm "A: doc"
dt "$T3" update-index docs/a.md
commit_all "A: re-verify a"
git checkout -q -b B main
hand_edit '.docs["docs/a.md"].doc_type = "adr"'
commit_all "B: retype a (last_verified stays T1)"
run_ways
assert_ways '.docs["docs/a.md"].doc_type' "adr" "older side's one-sided field survives"
assert_ways '.docs["docs/a.md"].last_verified' "$T3" "newer side's verification survives"
assert_ways_same_docs "one-sided field vs newer verify"
teardown

echo ""
echo "--- git revert of a deprecation reverts it, keeps the later re-verify ---"
base_repo
dt "$T2" deprecate-entry --superseded-by docs/b.md docs/a.md
commit_all "deprecate a"
DEP=$(git rev-parse HEAD)
echo "// a changed" > src/a.js
git add -A && git commit -qm "code"
dt "$T3" update-index docs/a.md
commit_all "re-verify a"
rc=0
git revert --no-edit "$DEP" > "$SUITE_TMP/revert.log" 2>&1 || rc=$?
IDX=$(cat docs/.doc-index.json)
assert_eq "0" "$rc" "revert of the deprecation merges cleanly"
assert_json_field "$IDX" '.docs["docs/a.md"] | has("status")' "false" "revert un-deprecates"
assert_json_field "$IDX" '.docs["docs/a.md"].superseded_by' "null" "revert clears superseded_by"
assert_json_field "$IDX" '.docs["docs/b.md"].replaces' "null" "revert clears the successor's replaces"
assert_json_field "$IDX" '.docs["docs/a.md"].last_verified' "$T3" "the later re-verify survives the revert"
teardown

echo ""
echo "--- git revert of a re-verify keeps a later deprecation ---"
base_repo
echo "// a changed" > src/a.js
git add -A && git commit -qm "code"
dt "$T2" update-index docs/a.md
commit_all "re-verify a"
VER=$(git rev-parse HEAD)
dt "$T3" deprecate-entry docs/a.md
commit_all "deprecate a"
rc=0
git revert --no-edit "$VER" > "$SUITE_TMP/revert.log" 2>&1 || rc=$?
IDX=$(cat docs/.doc-index.json)
assert_eq "0" "$rc" "revert of the re-verify merges cleanly"
assert_json_field "$IDX" '.docs["docs/a.md"].last_verified' "$T1" "revert restores the earlier verification"
assert_json_field "$IDX" '.docs["docs/a.md"].status' "deprecated" "the later deprecation survives the revert"
teardown

echo ""
echo "--- schema_version survives, no invented version ---"
base_repo
git checkout -q -b A
echo "# d" > docs/d.md
git add -A && git commit -qm "A: d"
printf 'docs/d.md:src/a.js:guide\n' | dt "$T2" add-entry
commit_all "A: add d"
git checkout -q -b B main
echo "# e" > docs/e.md
git add -A && git commit -qm "B: e"
printf 'docs/e.md:src/b.js:guide\n' | dt "$T3" add-entry
commit_all "B: add e"
BASE_BUILD=$(git show main:docs/.doc-index.json | jq -r .build_commit)
run_ways
assert_ways '.schema_version' "3" "schema_version survives"
assert_ways 'has("version")' "false" "no version key invented"
assert_ways '.build_commit' "$BASE_BUILD" "build_commit kept, not stamped with merge-time HEAD"
assert_ways '.docs | keys | length' "5" "both additions kept"
teardown

echo ""
echo "--- key order: ours' order kept, theirs-only keys appended ---"
setup
for n in z m a; do echo "# $n" > "docs/$n.md"; done
git add -A && git commit -qm "files"
printf 'docs/z.md:src/:spec\ndocs/m.md:src/:spec\ndocs/a.md:src/:spec\n' | dt "$T0" build-index
commit_all "base index"
register_driver
git checkout -q -b A
echo "# y" > docs/y.md
git add -A && git commit -qm "A: y"
printf 'docs/y.md:src/:spec\n' | dt "$T1" add-entry
commit_all "A: add y"
git checkout -q -b B main
echo "# b" > docs/b.md
git add -A && git commit -qm "B: b"
printf 'docs/b.md:src/:spec\n' | dt "$T2" add-entry
commit_all "B: add b"
BASE_ORDER=$(git show main:docs/.doc-index.json | jq -r '.docs | keys_unsorted | join(",")')
assert_eq "docs/z.md,docs/m.md,docs/a.md" "$BASE_ORDER" "fixture: writers keep insertion order"
run_ways
assert_json_field "${WAY_IDX[1]}" '.docs | keys_unsorted | join(",")' "$BASE_ORDER,docs/y.md,docs/b.md" "merge into A: A's order, B's key appended"
assert_json_field "${WAY_IDX[2]}" '.docs | keys_unsorted | join(",")' "$BASE_ORDER,docs/b.md,docs/y.md" "merge into B: B's order, A's key appended"
assert_json_field "${WAY_IDX[1]}" 'keys_unsorted | join(",")' "$(jq -r 'keys_unsorted | join(",")' docs/.doc-index.json)" "top-level key order kept"
assert_ways_same_docs "key order"
teardown

echo ""
echo "--- degenerate sides through real git: conflict with markers ---"
for bad in empty null object two-docs; do
  base_repo
  git checkout -q -b A
  dt "$T2" deprecate-entry docs/a.md
  commit_all "A: deprecate a"
  git checkout -q -b B main
  case "$bad" in
    empty) : > docs/.doc-index.json ;;
    null) echo null > docs/.doc-index.json ;;
    object) echo '{}' > docs/.doc-index.json ;;
    two-docs) cat docs/.doc-index.json docs/.doc-index.json > docs/.doc-index.json.new
              mv docs/.doc-index.json.new docs/.doc-index.json ;;
  esac
  commit_all "B: $bad index"
  # B holds the degenerate index: checked out it is ours, merged in theirs.
  for side in ours theirs; do
    if [ "$side" = ours ]; then head=B other=A; else head=A other=B; fi
    git checkout -q -f "$head"
    rc=0
    git merge --no-edit "$other" > "$SUITE_TMP/merge.log" 2>&1 || rc=$?
    assert_true "$side-degenerate ($bad): merge exits non-zero" test "$rc" -ne 0
    assert_contains "$(cat docs/.doc-index.json)" "<<<<<<< ours" "$side-degenerate ($bad): markers in the index"
    assert_contains "$(git ls-files -u docs/.doc-index.json)" ".doc-index.json" "$side-degenerate ($bad): index left unmerged"
    git merge --abort > /dev/null 2>&1 || true
    git reset -q --hard
  done
  teardown
done

# ===================================================================
# Direct invocation: the per-key and per-field rules
# ===================================================================

echo ""
echo "--- degenerate %A / %B / %O: exit non-zero, markers in %A ---"
write_index "$B" "{\"docs/a.md\": $ENTRY}"
derive "$O" '.docs["docs/a.md"].doc_type = "guide"'
GOOD="$SUITE_TMP/mdm-good.json"
derive "$GOOD" '.docs["docs/a.md"].code_refs = ["src/"]'
BAD="$SUITE_TMP/mdm-bad.json"
for bad in empty null object two-docs not-json docs-array; do
  case "$bad" in
    empty) : > "$BAD" ;;
    null) echo null > "$BAD" ;;
    object) echo '{}' > "$BAD" ;;
    two-docs) cat "$GOOD" "$GOOD" > "$BAD" ;;
    not-json) echo 'not json' > "$BAD" ;;
    docs-array) echo '{"docs": []}' > "$BAD" ;;
  esac
  # theirs degenerate
  _drive "$O" "$BAD"
  assert_true "theirs $bad: exit non-zero" test "$DRV_RC" -ne 0
  assert_contains "$DRV_OUT" "<<<<<<< ours" "theirs $bad: ours marker in %A"
  assert_contains "$DRV_OUT" ">>>>>>> theirs" "theirs $bad: theirs marker in %A"
  # ours degenerate
  _drive "$BAD" "$GOOD"
  assert_true "ours $bad: exit non-zero" test "$DRV_RC" -ne 0
  assert_contains "$DRV_OUT" "<<<<<<< ours" "ours $bad: ours marker in %A"
done
# A non-empty base that is not an index is corrupt, not "no ancestor".
cp "$B" "$SUITE_TMP/mdm-base.keep"
cp "$GOOD" "$T"
echo '{}' > "$B"
drive
assert_true "base {}: exit non-zero" test "$DRV_RC" -ne 0
assert_contains "$DRV_OUT" "<<<<<<< ours" "base {}: markers in %A"
cp "$SUITE_TMP/mdm-base.keep" "$B"

echo ""
echo "--- delete vs modify, direct: exit 1, markers, the key named ---"
derive "$O" '.docs["docs/b.md"] = .docs["docs/a.md"] | del(.docs["docs/a.md"])'
derive "$T" '.docs["docs/a.md"].doc_type = "guide"'
drive
assert_eq "1" "$DRV_RC" "deleted by ours, changed by theirs: exit 1"
assert_contains "$DRV_OUT" "<<<<<<< ours" "deleted by ours, changed by theirs: markers"
assert_contains "$DRV_ERR" "docs/a.md" "deleted by ours, changed by theirs: key named"
drive_swapped
assert_eq "1" "$DRV_RC" "changed by ours, deleted by theirs: exit 1"
assert_contains "$DRV_ERR" "docs/a.md" "changed by ours, deleted by theirs: key named"
# deleted on one side, untouched on the other: dropped, both ways
derive "$T" '.docs["docs/c.md"] = .docs["docs/a.md"]'
drive
assert_eq "0" "$DRV_RC" "deleted by ours, untouched by theirs: exit 0"
assert_json_field "$DRV_OUT" '.docs | keys | join(",")' "docs/b.md,docs/c.md" "deleted by ours, untouched by theirs: dropped"
drive_swapped
assert_json_field "$DRV_OUT" '.docs | keys | join(",")' "docs/b.md,docs/c.md" "untouched by ours, deleted by theirs: dropped"

echo ""
echo "--- empty base (add/add): union ---"
write_index "$O" "{\"docs/a.md\": $ENTRY}"
write_index "$T" "{\"docs/b.md\": $ENTRY}"
: > "$B"
drive
assert_eq "0" "$DRV_RC" "empty base: exit 0"
assert_json_field "$DRV_OUT" '.docs | keys | join(",")' "docs/a.md,docs/b.md" "empty base: both entries"
write_index "$B" "{\"docs/a.md\": $ENTRY}"

echo ""
echo "--- a verification is one unit: never a doc/code pair nobody verified ---"
# ours re-verified after a doc edit (content_hash); theirs after a code change
# (code_oids). Mixing them would attest the new doc against the new code.
derive "$O" '.docs["docs/a.md"] += {content_hash: "sha256:h-ours", code_commit: "c-ours", last_verified: "2026-01-01T00:00:03Z"}'
derive "$T" '.docs["docs/a.md"] += {code_oids: {"src/a.js": "oid-theirs"}, code_commit: "c-theirs", last_verified: "2026-01-01T00:00:02Z"}'
drive
assert_eq "0" "$DRV_RC" "verify unit: exit 0"
assert_json_field "$DRV_OUT" '.docs["docs/a.md"] | [.content_hash, .code_oids["src/a.js"], .code_commit, .last_verified] | join(" ")' \
  "sha256:h-ours oid0 c-ours 2026-01-01T00:00:03Z" "newer verification taken whole"
drive_swapped
assert_json_field "$DRV_OUT" '.docs["docs/a.md"] | [.content_hash, .code_oids["src/a.js"], .code_commit, .last_verified] | join(" ")' \
  "sha256:h-ours oid0 c-ours 2026-01-01T00:00:03Z" "newer verification taken whole (swapped)"

echo ""
echo "--- both changed one field: newer last_verified wins; non-null beats null; unordered is a conflict ---"
derive "$O" '.docs["docs/a.md"] += {doc_type: "guide", last_verified: "2026-01-01T00:00:02Z"}'
derive "$T" '.docs["docs/a.md"] += {doc_type: "adr", last_verified: "2026-01-01T00:00:03Z"}'
drive
assert_json_field "$DRV_OUT" '.docs["docs/a.md"].doc_type' "adr" "theirs newer: theirs' value"
drive_swapped
assert_json_field "$DRV_OUT" '.docs["docs/a.md"].doc_type' "adr" "theirs newer: same value swapped"
# non-null beats null
derive "$B" '.docs["docs/a.md"].last_verified = null'
derive "$O" '.docs["docs/a.md"] += {doc_type: "guide"}'
derive "$T" '.docs["docs/a.md"] += {doc_type: "adr", last_verified: "2026-01-01T00:00:03Z"}'
drive
assert_json_field "$DRV_OUT" '.docs["docs/a.md"].doc_type' "adr" "non-null last_verified beats null"
drive_swapped
assert_json_field "$DRV_OUT" '.docs["docs/a.md"].doc_type' "adr" "non-null last_verified beats null (swapped)"
# both null: nothing orders them -> conflict, in both directions
derive "$T" '.docs["docs/a.md"] += {doc_type: "adr"}'
for way in drive drive_swapped; do
  "$way"
  assert_eq "1" "$DRV_RC" "both null, same field ($way): exit 1"
  assert_contains "$DRV_OUT" "<<<<<<< ours" "both null, same field ($way): markers"
  assert_contains "$DRV_ERR" "docs/a.md: both sides changed doc_type" "both null, same field ($way): key and field named"
done
write_index "$B" "{\"docs/a.md\": $ENTRY}"
# equal: nothing orders them -> conflict, in both directions
derive "$O" '.docs["docs/a.md"] += {doc_type: "guide"}'
derive "$T" '.docs["docs/a.md"] += {doc_type: "adr"}'
for way in drive drive_swapped; do
  "$way"
  assert_eq "1" "$DRV_RC" "equal last_verified, same field ($way): exit 1"
  assert_contains "$DRV_ERR" "docs/a.md: both sides changed doc_type" "equal last_verified, same field ($way): key and field named"
done
# equal last_verified, different verification records -> conflict
derive "$O" '.docs["docs/a.md"] += {content_hash: "sha256:h-ours"}'
derive "$T" '.docs["docs/a.md"] += {code_oids: {"src/a.js": "oid-theirs"}}'
drive
assert_eq "1" "$DRV_RC" "equal last_verified, different records: exit 1"
assert_contains "$DRV_ERR" "the verification record" "equal last_verified, different records: named"
# equal records (both sides wrote the same one) are no conflict
derive "$O" '.docs["docs/a.md"] += {content_hash: "sha256:h2", doc_type: "guide"}'
derive "$T" '.docs["docs/a.md"] += {content_hash: "sha256:h2", code_refs: ["src/"]}'
drive
assert_eq "0" "$DRV_RC" "equal records: exit 0"
assert_json_field "$DRV_OUT" '.docs["docs/a.md"] | "\(.content_hash) \(.doc_type) \(.code_refs[0])"' "sha256:h2 guide src/" "equal records: kept, other fields merged"

echo ""
echo "--- deprecated wins; superseded_by travels with the status ---"
derive "$O" '.docs["docs/a.md"] += {status: "deprecated", superseded_by: "docs/x.md"}'
derive "$T" '.docs["docs/a.md"] += {superseded_by: "docs/y.md", last_verified: "2026-01-01T00:00:03Z"}'
drive
assert_json_field "$DRV_OUT" '.docs["docs/a.md"] | "\(.status) \(.superseded_by) \(.last_verified)"' \
  "deprecated docs/x.md 2026-01-01T00:00:03Z" "deprecating side's superseded_by wins over a newer one"
drive_swapped
assert_json_field "$DRV_OUT" '.docs["docs/a.md"] | "\(.status) \(.superseded_by) \(.last_verified)"' \
  "deprecated docs/x.md 2026-01-01T00:00:03Z" "deprecating side's superseded_by wins (swapped)"
# base deprecated; ours un-deprecates; theirs repoints the successor: ours
# removed the deprecation and theirs did not, so it is removed.
derive "$B" '.docs["docs/a.md"] += {status: "deprecated", superseded_by: "docs/x.md"}'
derive "$O" '.docs["docs/a.md"] |= (del(.status) | .superseded_by = null)'
derive "$T" '.docs["docs/a.md"].superseded_by = "docs/x2.md"'
drive
assert_json_field "$DRV_OUT" '.docs["docs/a.md"] | "\(.status) \(.superseded_by)"' "null null" "un-deprecation beats a repoint"
drive_swapped
assert_json_field "$DRV_OUT" '.docs["docs/a.md"] | "\(.status) \(.superseded_by)"' "null null" "un-deprecation beats a repoint (swapped)"
write_index "$B" "{\"docs/a.md\": $ENTRY}"

echo ""
echo "--- code_refs substitutions collapse as move-entry would, and dedupe nothing else (GH #22) ---"
# Theirs repoints x -> y (keeps the base length); ours widened the list to cite
# y too. move-entry on ours' list would drop the moved ref into its own y.
derive "$B" '.docs["docs/a.md"].code_refs = ["docs/x.md", "src/a.js"]'
derive "$O" '.docs["docs/a.md"].code_refs = ["docs/x.md", "src/a.js", "docs/y.md"]'
derive "$T" '.docs["docs/a.md"].code_refs = ["docs/y.md", "src/a.js"]'
drive
assert_eq "0" "$DRV_RC" "repoint vs a list already citing the new path: exit 0"
assert_json_field "$DRV_OUT" '.docs["docs/a.md"].code_refs | join(",")' "src/a.js,docs/y.md" "the moved ref collapses into ours' own copy"
drive_swapped
assert_json_field "$DRV_OUT" '.docs["docs/a.md"].code_refs | join(",")' "src/a.js,docs/y.md" "the moved ref collapses (swapped)"
# A duplicate neither side's substitution made is left alone.
derive "$B" '.docs["docs/a.md"].code_refs = ["src/a.js", "src/a.js", "docs/x.md"]'
derive "$O" '.docs["docs/a.md"].code_refs = ["src/a.js", "src/a.js", "docs/x.md", "src/z.js"]'
derive "$T" '.docs["docs/a.md"].code_refs = ["src/a.js", "src/a.js", "docs/y.md"]'
drive
assert_json_field "$DRV_OUT" '.docs["docs/a.md"].code_refs | join(",")' "src/a.js,src/a.js,docs/y.md,src/z.js" "an existing duplicate survives"
# Same-length lists that are not substitutions: a duplicate neither side had,
# and a duplicated base ref, both conflict rather than lose or invent a ref.
derive "$B" '.docs["docs/a.md"].code_refs = ["src/a.js", "src/b.js"]'
derive "$O" '.docs["docs/a.md"].code_refs = ["src/c.js", "src/b.js"]'
derive "$T" '.docs["docs/a.md"].code_refs = ["src/a.js", "src/c.js"]'
drive
assert_eq "1" "$DRV_RC" "a merge that would duplicate a ref: exit 1"
derive "$B" '.docs["docs/a.md"].code_refs = ["src/a.js", "src/a.js"]'
derive "$O" '.docs["docs/a.md"].code_refs = ["src/a.js", "src/a.js", "src/e.js"]'
derive "$T" '.docs["docs/a.md"].code_refs = ["src/c.js", "src/d.js"]'
drive
assert_eq "1" "$DRV_RC" "a duplicated base ref: exit 1 (was a silent loss of src/c.js)"
write_index "$B" "{\"docs/a.md\": $ENTRY}"

echo ""
echo "--- two same-second re-verifications that differ only in code_oids: a conflict ---"
# update-index on each side with a different uncommitted code change: the
# same content_hash, code_commit and last_verified, different code_oids.
derive "$B" '.docs["docs/a.md"] += {code_refs: ["src/a.js", "src/b.js"], code_oids: {"src/a.js": "oidA0", "src/b.js": "oidB0"}}'
derive "$O" '.docs["docs/a.md"] += {code_oids: {"src/a.js": "oidA1", "src/b.js": "oidB0"}, last_verified: "2026-01-01T00:00:05Z"}'
derive "$T" '.docs["docs/a.md"] += {code_oids: {"src/a.js": "oidA0", "src/b.js": "oidB1"}, last_verified: "2026-01-01T00:00:05Z"}'
drive
assert_eq "1" "$DRV_RC" "tied re-verifications: exit 1 (never a pair nobody verified)"
assert_contains "$DRV_ERR" "the verification record" "tied re-verifications: the record is named"
drive_swapped
assert_eq "1" "$DRV_RC" "tied re-verifications (swapped): exit 1"
write_index "$B" "{\"docs/a.md\": $ENTRY}"

echo ""
echo "--- a re-verified side's code_refs win whole over the other side's repoint (documented under Renames) ---"
derive "$B" '.docs["docs/a.md"] += {code_refs: ["docs/x.md", "src/a.js"], code_oids: {"docs/x.md": "oidX", "src/a.js": "oid0"}}'
derive "$O" '.docs["docs/a.md"] += {code_refs: ["docs/x2.md", "src/a.js"], code_oids: {"docs/x2.md": "oidX", "src/a.js": "oid0"}, content_hash: "sha256:h9", last_verified: "2026-01-01T00:00:05Z"}'
derive "$T" '.docs["docs/a.md"] += {code_refs: ["docs/x.md", "src/b.js"], code_oids: {"docs/x.md": "oidX", "src/b.js": "oidB"}}'
drive
assert_eq "0" "$DRV_RC" "re-verified side vs a repoint: exit 0"
assert_json_field "$DRV_OUT" '.docs["docs/a.md"] | (.code_refs | join(",")) + " " + .last_verified' \
  "docs/x2.md,src/a.js 2026-01-01T00:00:05Z" "the re-verified side's list and record win whole"
drive_swapped
assert_json_field "$DRV_OUT" '.docs["docs/a.md"].code_refs | join(",")' "docs/x2.md,src/a.js" "the same (swapped)"
write_index "$B" "{\"docs/a.md\": $ENTRY}"
write_index "$B" "{\"docs/a.md\": $ENTRY}"

echo ""
echo "--- legacy stored status current/stale reads as absent ---"
derive "$B" '.docs["docs/a.md"].status = "current"'
# ours: a doc-tools write dropped the legacy status; theirs: a hand edit kept it
derive "$O" '.docs["docs/a.md"] |= del(.status)'
derive "$T" '.docs["docs/a.md"] += {status: "current", doc_type: "guide"}'
drive
assert_eq "0" "$DRV_RC" "legacy status vs absent: no conflict"
assert_json_field "$DRV_OUT" '.docs["docs/a.md"].doc_type' "guide" "legacy status vs absent: theirs' change taken"
derive "$O" '.docs["docs/a.md"] += {status: "stale", code_refs: ["src/"]}'
derive "$T" '.docs["docs/a.md"] |= (del(.status) | .doc_type = "guide")'
drive
assert_json_field "$DRV_OUT" '.docs["docs/a.md"] | "\(.status) \(.code_refs[0]) \(.doc_type)"' "null src/ guide" "field-wise merge drops the legacy status"
derive "$T" '.docs["docs/a.md"].status = "deprecated"'
drive
assert_json_field "$DRV_OUT" '.docs["docs/a.md"].status' "deprecated" "legacy status vs deprecated: deprecated"
write_index "$B" "{\"docs/a.md\": $ENTRY}"

echo ""
echo "--- top level: starts from ours; legacy version vs schema_version ---"
jq '. + {version: 1} | del(.schema_version)' "$B" > "$SUITE_TMP/mdm-legacy.json"
cp "$SUITE_TMP/mdm-legacy.json" "$B"
jq '.generated_at = "g-ours" | .docs["docs/a.md"].doc_type = "guide"' "$B" > "$O"
jq '{schema_version: 3} + del(.version) | .generated_at = "g-theirs" | .docs["docs/b.md"] = .docs["docs/a.md"]' "$B" > "$T"
drive
assert_eq "0" "$DRV_RC" "legacy base: exit 0"
assert_json_field "$DRV_OUT" '[.schema_version, has("version"), .generated_at] | map(tostring) | join(" ")' "3 false g-ours" "theirs' upgrade to schema_version kept, legacy version dropped, ours' generated_at"
drive_swapped
assert_json_field "$DRV_OUT" '[.schema_version, has("version"), .generated_at] | map(tostring) | join(" ")' "3 false g-theirs" "same schema both ways; generated_at is the checked-out side's"
jq '.custom = "x" | .docs["docs/a.md"].owner = "me"' "$SUITE_TMP/mdm-legacy.json" > "$O"
drive
assert_json_field "$DRV_OUT" '"\(.custom) \(.docs["docs/a.md"].owner)"' "x me" "unknown top-level and entry fields survive"
write_index "$B" "{\"docs/a.md\": $ENTRY}"

echo ""
echo "--- field order: ours' order, theirs-only fields appended ---"
derive "$O" '.docs["docs/a.md"] |= ({implementation: []} + . | .doc_type = "guide")'
derive "$T" '.docs["docs/a.md"] += {owner: "them", code_refs: ["src/"]}'
drive
assert_json_field "$DRV_OUT" '.docs["docs/a.md"] | keys_unsorted | join(",")' \
  "implementation,content_hash,code_refs,code_oids,code_commit,doc_type,replaces,superseded_by,last_verified,owner" "field order: ours', then theirs-only"

echo ""
echo "--- a signal during the %A write leaves markers, never a partial result ---"
# A `cat` on the driver's PATH that writes part of the result, stalls, then
# writes the rest: the driver's first cat is its write of %A. The signal lands
# while that write is in progress.
_REAL_CAT="$(command -v cat)"
_SLOW_DIR="$SUITE_TMP/slow-cat"
SLOW_FLAG="$SUITE_TMP/slow-cat.flag"
mkdir -p "$_SLOW_DIR"
cat > "$_SLOW_DIR/cat" <<EOF
#!/bin/sh
if [ -f "$SLOW_FLAG" ]; then
  rm -f "$SLOW_FLAG"
  head -c 40 "\$1"
  sleep 3
  tail -c +41 "\$1"
  exit 0
fi
exec "$_REAL_CAT" "\$@"
EOF
chmod +x "$_SLOW_DIR/cat"
derive "$O" '.docs["docs/a.md"].doc_type = "guide"'
derive "$T" '.docs["docs/a.md"].code_refs = ["src/"]'
for sig in TERM HUP; do
  cp "$O" "$RES"
  : > "$SLOW_FLAG"
  PATH="$_SLOW_DIR:$PATH" "$MERGE_DRIVER" "$B" "$RES" "$T" 2> "$DRV_ERRF" &
  rc=0
  harness_kill_after 1 "$sig" "$!" || rc=$?
  assert_eq "1" "$HARNESS_KILL_ALIVE" "$sig: the driver was mid-write when signalled"
  assert_true "$sig during the write: exit non-zero" test "$rc" -ne 0
  assert_contains "$(cat "$RES")" "<<<<<<< ours" "$sig during the write: markers in %A"
  assert_contains "$(cat "$RES")" '"doc_type": "guide"' "$sig during the write: rebuilt from ours"
  assert_contains "$(cat "$DRV_ERRF")" "interrupted" "$sig during the write: says why"
done
rm -f "$SLOW_FLAG"

# ===================================================================
# Registration: install.sh --git (quoted path, newest driver at merge time)
# ===================================================================

# A skill tree at <dir> (copied from this checkout) and a PATH `bash` that is
# the interpreter under test, so the registered command runs the driver under
# $BASH_BIN like everything else in this suite.
make_skill() {
  mkdir -p "$1"
  cp -R "$SCRIPT_DIR" "$1/scripts"
  cp "$SCRIPT_DIR/../RELEASE-NOTES.md" "$1/"
}
_BASH_PATH_DIR="$SUITE_TMP/bash-path"
mkdir -p "$_BASH_PATH_DIR"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$BASH_BIN" > "$_BASH_PATH_DIR/bash"
chmod +x "$_BASH_PATH_DIR/bash"
SENTINEL="$SUITE_TMP/sentinel"
# install --git also installs the git hooks; they are not under test here.
export DOC_SUPERPOWERS_SKIP=1
# A driver version that records that it ran, then runs the real one.
fake_version() {
  mkdir -p "$1/$2/scripts"
  printf '#!/usr/bin/env bash\necho %s >> "%s"\nexec bash "%s" "$@"\n' "$2" "$SENTINEL" "$SCRIPT_DIR/merge-doc-index.sh" \
    > "$1/$2/scripts/merge-doc-index.sh"
}
# Two branches that both change docs/a.md's entry, so every merge needs the
# driver; merge A into B once and report rc + ran versions.
diverge() {
  git checkout -q -b A
  dt "$T2" deprecate-entry docs/a.md
  commit_all "A: deprecate a"
  git checkout -q -b B main
  hand_edit '.docs["docs/a.md"].doc_type = "adr"'
  commit_all "B: retype a"
  git checkout -q main
}
REG_RC=0
REG_IDX=""
REG_LOG=""
merge_once() {
  : > "$SENTINEL"
  git checkout -q -f --detach B
  REG_RC=0
  PATH="$_BASH_PATH_DIR:$PATH" git merge --no-edit A > "$SUITE_TMP/reg.log" 2>&1 || REG_RC=$?
  REG_IDX=$(cat docs/.doc-index.json)
  REG_LOG=$(cat "$SUITE_TMP/reg.log")
  [ "$REG_RC" -eq 0 ] || git merge --abort > /dev/null 2>&1 || true
  git reset -q --hard
  git checkout -q -f main
}
# base_repo without the suite's own registration: install.sh registers it.
install_repo() {
  setup
  local n
  for n in a b; do
    echo "# $n" > "docs/$n.md"
    echo "// $n" > "src/$n.js"
  done
  git add -A && git commit -qm "files"
  printf 'docs/a.md:src/a.js:spec\ndocs/b.md:src/b.js:spec\n' | dt "$T0" build-index
  dt "$T1" update-index docs/a.md docs/b.md
  git add -A && git commit -qm "base index"
  if ! "$BASH_BIN" "$1/scripts/hooks/install.sh" install --git > "$SUITE_TMP/install.log" 2>&1; then
    cat "$SUITE_TMP/install.log" >&2
    echo "FIXTURE ERROR: install.sh install --git failed" >&2
    exit 1
  fi
  # The installer's own files are not part of the fixture's history.
  printf '.gitattributes\n.claude/\n' >> .git/info/exclude
  diverge
}

echo ""
echo "--- registration: plugin-cache install (path with a space) resolves the newest version at merge time ---"
CACHE="$SUITE_TMP/plugin cache/doc-superpowers"
make_skill "$CACHE/1.0.0"
install_repo "$CACHE/1.0.0"
REG=$(git config --local --get merge.doc-index.driver)
assert_contains "$REG" "'$CACHE'" "registered with the quoted plugin-cache dir"
assert_not_contains "$REG" "1.0.0" "no version pinned in the registration"
STATUS=$("$BASH_BIN" "$CACHE/1.0.0/scripts/hooks/install.sh" status 2>&1 || true)
assert_contains "$STATUS" "$CACHE/1.0.0/scripts/merge-doc-index.sh" "status names the driver a merge would run"
assert_not_contains "$STATUS" "re-run" "status: registration current"
merge_once
assert_eq "0" "$REG_RC" "merge through the registered driver (space in path) succeeds"
assert_json_field "$REG_IDX" '.docs["docs/a.md"] | "\(.status) \(.doc_type)"' "deprecated adr" "both sides' changes merged"
fake_version "$CACHE" 2.0.0
merge_once
assert_eq "2.0.0" "$(cat "$SENTINEL")" "version bump without re-install: 2.0.0 runs"
assert_eq "0" "$REG_RC" "merge after the bump succeeds"
fake_version "$CACHE" 9.0.0
fake_version "$CACHE" 10.0.0
fake_version "$CACHE" zzz
merge_once
assert_eq "10.0.0" "$(cat "$SENTINEL")" "numeric version order (10.0.0 > 9.0.0), non-version dirs ignored"
rm -rf "$CACHE/1.0.0" "$CACHE/10.0.0"
merge_once
assert_eq "9.0.0" "$(cat "$SENTINEL")" "a pruned version dir falls back to the newest remaining"
rm -rf "${CACHE:?}"/*
merge_once
assert_true "no driver left: merge exits non-zero" test "$REG_RC" -ne 0
assert_contains "$REG_IDX" "<<<<<<< ours" "no driver left: conflict markers in the index"
assert_contains "$REG_LOG" "merge driver not found" "no driver left: says why"
teardown

echo ""
echo "--- registration: checkout install (not a version dir) is pinned, quoted ---"
CHECKOUT="$SUITE_TMP/my checkout/doc superpowers"
make_skill "$CHECKOUT"
fake_version "$SUITE_TMP/my checkout" 9.9.9
install_repo "$CHECKOUT"
REG=$(git config --local --get merge.doc-index.driver)
assert_contains "$REG" "'$CHECKOUT/scripts/merge-doc-index.sh'" "registered with the quoted script path"
merge_once
assert_eq "0" "$REG_RC" "merge through the pinned driver (spaces in path) succeeds"
assert_eq "" "$(cat "$SENTINEL")" "sibling version dirs are never run for a checkout install"
STATUS=$("$BASH_BIN" "$CHECKOUT/scripts/hooks/install.sh" status 2>&1 || true)
assert_contains "$STATUS" "merge-driver" "status lists the merge driver"
assert_not_contains "$STATUS" "script missing" "status: driver found"
assert_not_contains "$STATUS" "re-run" "status: registration current"
# A pre-v3 registration (unquoted, pinned) is reported for re-install.
git config --local merge.doc-index.driver "$CHECKOUT/scripts/merge-doc-index.sh %O %A %B"
STATUS=$("$BASH_BIN" "$CHECKOUT/scripts/hooks/install.sh" status 2>&1 || true)
assert_contains "$STATUS" "re-run" "status: a pinned legacy registration asks for re-install"
git config --local merge.doc-index.driver "/nonexistent dir/merge-doc-index.sh %O %A %B"
STATUS=$("$BASH_BIN" "$CHECKOUT/scripts/hooks/install.sh" status 2>&1 || true)
assert_contains "$STATUS" "script missing: /nonexistent dir/merge-doc-index.sh" "status: missing legacy path named whole (spaces)"
"$BASH_BIN" "$CHECKOUT/scripts/hooks/install.sh" uninstall --git > /dev/null 2>&1
assert_eq "UNSET" "$(git config --local --get merge.doc-index.driver 2>/dev/null || echo UNSET)" "uninstall removes the registration"
teardown

print_summary
