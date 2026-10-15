#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=scripts/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

# Run doc-tools.sh under the interpreter this suite was launched with,
# not whatever `#!/usr/bin/env bash` resolves to. See bash_bin_shim().
DOC_TOOLS="$(bash_bin_shim "$REPO_DIR/scripts/doc-tools.sh")"

# The ledger sub-verbs (doc-tools.sh ledger <sub>), in verb-table order.
LG_VERBS="show ls find related sweep recheck inflight notices new assign link note view validate publish finalize init"

LG_INERT_LINE="ledger: not enabled (no docs/ledger/config.json)"

# --- Fixture helpers ----------------------------------------------------------

# A git repo (setup) with the item and ledger dirs, and no config: inert.
lg_fixture() {
  setup
  mkdir -p docs/issues docs/ledger
}

# lg_enable [json]: write docs/ledger/config.json (default "{}": every key
# takes its default).
# shellcheck disable=SC2120  # the argument is optional; later tasks pass one
lg_enable() {
  local c='{}'
  if [ $# -gt 0 ]; then c=$1; fi
  printf '%s\n' "$c" > docs/ledger/config.json
}

# lg <args…>: run `doc-tools.sh ledger args` from the cwd (stdin closed, as a
# hook runs it); sets LG_RC, LG_OUT (stdout) and LG_ERR (stderr).
lg() {
  lg_with "$DOC_TOOLS" "$@"
}

# lg_with <doc-tools> <args…>: lg with another doc-tools.sh (a vendored copy).
lg_with() {
  local tool="$1" err
  shift
  err=$(harness_mktemp lg-err)
  LG_RC=0
  LG_OUT=$("$tool" ledger "$@" 2>"$err" </dev/null) || LG_RC=$?
  LG_ERR=$(cat "$err")
  rm -f "$err"
}

# The number of JSON values in $1 ("" → 0; not JSON → "invalid").
json_count() {
  jq -s 'length' <<<"$1" 2>/dev/null || echo invalid
}

# --- Internal functions, called directly --------------------------------------
#
# lg_source: load doc-tools.sh's functions (DOC_TOOLS_SOURCE_ONLY=1: it
# defines everything and returns before _main) and scripts/ledger/lib.sh into
# THIS shell, cd into the fixture, give it a private scratch dir and run
# _lg_init, so the _LG_* globals and the merged config are what a handler
# sees. LG_SUB (default "ls") names the sub-verb, LG_FORMAT (default text)
# the format. Call it only inside a ( … ) subshell — lg_call and lg_in do:
# doc-tools.sh's globals, set -euo pipefail and exit paths must not reach the
# suite's own shell. Needs lg_fixture (and lg_enable: _lg_init loads the
# config).
lg_source() {
  local scratch
  scratch=$(harness_mktemp_d lg-scratch)
  cd "$TEST_DIR"
  DOC_TOOLS_SOURCE_ONLY=1
  # shellcheck source=scripts/doc-tools.sh
  . "$REPO_DIR/scripts/doc-tools.sh"
  unset DOC_TOOLS_SOURCE_ONLY
  # shellcheck source=scripts/ledger/lib.sh
  . "$REPO_DIR/scripts/ledger/lib.sh"
  _SCRATCH=$scratch
  _LG_ACTIVE=1
  _LG_FORMAT=${LG_FORMAT:-text}
  _lg_init "${LG_SUB:-ls}"
}

# The subshells below run under `set +e` and are never the left side of
# `||`/`&&`: bash ignores errexit for EVERYTHING inside a command on the left
# of `||` (functions included, even after a later `set -e`), so the internal
# functions would run without the errexit they run under in production.
# doc-tools.sh's own `set -euo pipefail`, run by lg_source, turns it back on
# inside the subshell.

# lg_call <function> [args…]: run one internal function in a lg_source'd
# subshell; sets LG_RC, LG_OUT (stdout) and LG_ERR (stderr), as lg does.
lg_call() {
  local err
  err=$(harness_mktemp lg-err)
  set +e
  LG_OUT=$( lg_source; "$@" 2>"$err" </dev/null )
  LG_RC=$?
  set -e
  LG_ERR=$(cat "$err")
  rm -f "$err"
}

# lg_rc <command…>: inside a lg_source'd shell, run <command> in a subshell
# with errexit live; LG_RC is its exit code (stdout and stderr dropped).
lg_rc() {
  set +e
  ( "$@" ) >/dev/null 2>&1
  LG_RC=$?
  set -e
}

# lg_in <test-body> [args…]: run a test body (a function of asserts) in a
# lg_source'd subshell and carry its pass/fail counts back. A body that dies
# before it reports (an internal function exited) counts as one failure.
lg_in() {
  local counts rc
  counts=$(harness_mktemp lg-counts)
  : > "$counts"
  set +e
  ( lg_source; "$@"; print_counts_to "$counts" )
  rc=$?
  set -e
  if [ -s "$counts" ]; then
    absorb_counts "$counts"
  else
    TESTS_RUN=$((TESTS_RUN + 1))
    FAIL=$((FAIL + 1))
    printf "${RED}  FAIL${NC}: %s died before reporting (rc %s)\n" "$1" "$rc"
  fi
}

LG_BOM=$'\357\273\277'
LG_FM_AWK="$REPO_DIR/scripts/ledger/frontmatter.awk"

# lg_fm <file> [path]: frontmatter.awk's record for <file> on stdin, run as
# parse.sh runs it (LC_ALL=C); "<failed: …>" when awk fails.
lg_fm() {
  local out
  out=$(LC_ALL=C awk -v path="${2:-$1}" -v bom="$LG_BOM" -f "$LG_FM_AWK" < "$1" 2>&1) \
    || out="<failed: $out>"
  printf '%s' "$out"
}

# lg_crlf <in> <out>: <in> with CRLF line endings.
lg_crlf() {
  awk '{ printf "%s\r\n", $0 }' "$1" > "$2"
}

# The bytes of <file> from line <n> on, hashed (the "body" of an edit test).
lg_tail_hash() {
  tail -n +"$2" "$1" > "$1.tail"
  hash_file "$1.tail"
  rm -f "$1.tail"
}

# A NUL-terminated list of the arguments, into <file>.
lg_nul_list() {
  local f="$1"
  shift
  : > "$f"
  if [ $# -gt 0 ]; then printf '%s\0' "$@" > "$f"; fi
}

# The NUL-terminated names in <file>, one per line (for asserts).
lg_names() {
  tr '\0' '\n' < "$1"
}

# --- Task 1: verb group, exit family, config, inert ---------------------------

test_lg_inert_text_every_verb() {
  echo "test: without docs/ledger/config.json every ledger verb except init prints the inert line and exits 0"
  lg_fixture
  local v
  for v in $LG_VERBS; do
    # init bootstraps a repository that has no config yet (Task 14 R1):
    # test_lg_init_runs_without_config.
    if [ "$v" = init ]; then continue; fi
    lg "$v"
    assert_eq "0" "$LG_RC" "ledger $v: inert exits 0"
    assert_eq "$LG_INERT_LINE" "$LG_OUT" "ledger $v: stdout is exactly the inert line"
  done
  teardown
}

test_lg_inert_json() {
  echo "test: inert --format json prints exactly one {verb, enabled:false, exit:0} object"
  lg_fixture
  lg ls --format json
  assert_eq "0" "$LG_RC" "inert JSON exits 0"
  assert_eq '{"verb":"ledger ls","enabled":false,"exit":0}' "$LG_OUT" "the exact inert object"
  assert_json_field "$LG_OUT" '.verb' "ledger ls" ".verb is 'ledger ls'"
  assert_json_field "$LG_OUT" '.enabled' "false" ".enabled is false"
  assert_json_field "$LG_OUT" '.exit' "0" ".exit is 0"
  # --format=json spelling, and a verb whose required argument is missing:
  # the inert check runs before any verb checks its arguments.
  lg show --format=json
  assert_eq "0" "$LG_RC" "inert 'show' without its argument exits 0"
  assert_eq '{"verb":"ledger show","enabled":false,"exit":0}' "$LG_OUT" "--format=json spelling"
  teardown
}

test_lg_unknown_option_is_usage() {
  echo "test: ledger usage errors exit 3 (inert or enabled), with one object in JSON mode"
  lg_fixture
  lg ls --bogus
  assert_eq "3" "$LG_RC" "an unknown option exits 3 even when inert"
  assert_not_contains "$LG_OUT" "not enabled" "no inert line on a usage error"
  assert_contains "$LG_ERR" "--bogus" "stderr names the unknown option"
  lg ls --format yaml
  assert_eq "3" "$LG_RC" "--format other than text|json exits 3"
  lg bogus
  assert_eq "3" "$LG_RC" "an unknown ledger sub-verb exits 3"
  lg
  assert_eq "3" "$LG_RC" "'ledger' without a sub-verb exits 3"
  lg --format json
  assert_eq "3" "$LG_RC" "'ledger --format json' without a sub-verb exits 3"
  assert_json_field "$LG_OUT" '.verb' "ledger" ".verb is 'ledger' when no sub-verb was given"
  lg bogus --format json
  assert_json_field "$LG_OUT" '.verb' "ledger bogus" ".verb names an unknown sub-verb"
  assert_json_field "$LG_OUT" '.exit' "3" "unknown sub-verb: .exit is 3"
  lg_enable
  lg ls --bogus --format json
  assert_eq "3" "$LG_RC" "an unknown option exits 3 when enabled"
  assert_eq "1" "$(json_count "$LG_OUT")" "JSON mode: exactly one object (--format after the bad option)"
  assert_json_field "$LG_OUT" '.exit' "3" ".exit is 3"
  assert_json_field "$LG_OUT" '.verb' "ledger ls" ".verb is 'ledger ls'"
  assert_json_field "$LG_OUT" '.enabled' "true" ".enabled is true (config present)"
  lg ls --bogus
  assert_eq "" "$LG_OUT" "text mode: nothing on stdout"
  # --help is not a usage error.
  lg ls --help
  assert_eq "0" "$LG_RC" "ledger ls --help exits 0"
  assert_contains "$LG_OUT" "doc-tools.sh ledger ls" "ledger ls --help prints its usage"
  lg --help
  assert_eq "0" "$LG_RC" "ledger --help exits 0"
  assert_contains "$LG_OUT" "doc-tools.sh ledger show" "ledger --help lists the group"
  teardown
}

test_lg_config_invalid_json() {
  echo "test: an unparsable docs/ledger/config.json exits 2 and names the file"
  lg_fixture
  printf '{\n' > docs/ledger/config.json
  lg ls
  assert_eq "2" "$LG_RC" "invalid config exits 2"
  assert_contains "$LG_ERR" "docs/ledger/config.json" "stderr names docs/ledger/config.json"
  assert_eq "" "$LG_OUT" "text mode: nothing on stdout"
  lg ls --format json
  assert_eq "2" "$LG_RC" "JSON mode: exits 2"
  assert_eq "1" "$(json_count "$LG_OUT")" "JSON mode: exactly one object"
  assert_json_field "$LG_OUT" '.error | test("docs/ledger/config.json")' "true" ".error names the file"
  assert_json_field "$LG_OUT" '.enabled' "true" ".enabled is true"
  # A JSON value that is not one object is invalid too.
  printf '[]\n' > docs/ledger/config.json
  lg ls
  assert_eq "2" "$LG_RC" "a config that is an array exits 2"
  printf '{}\n{}\n' > docs/ledger/config.json
  lg ls
  assert_eq "2" "$LG_RC" "a config holding two objects exits 2"
  teardown
}

test_lg_config_merge() {
  echo "test: config.jq deep-merges the host config over the defaults"
  local cfg="$REPO_DIR/scripts/ledger/config.jq" out
  out=$(jq -n --argjson h '{"views":{"recent_days":7}}' -f "$cfg" 2>&1) || out="<jq failed: $out>"
  assert_json_field "$out" '.views.recent_days' "7" "host value wins"
  assert_json_field "$out" '.views.branch' "doc-ledger-views" "sibling default kept (deep merge)"
  assert_json_field "$out" '.views.html' "true" "views.html default kept"
  assert_json_field "$out" '.keys.counter_ref' "refs/doc-superpowers/ledger/counters" "keys.counter_ref default"
  assert_json_field "$out" '.keys.mode' "cas" "keys.mode default"
  assert_json_field "$out" '.keys.remote' "origin" "keys.remote default"
  assert_json_field "$out" '.base' "origin/main" "base default"
  assert_json_field "$out" '.schema' "ledger-config/1" "schema default"
  assert_json_field "$out" '.inflight.ref_prefix' "refs/doc-superpowers/inflight" "inflight.ref_prefix default"
  assert_json_field "$out" '.inflight.max_age_days' "21" "inflight.max_age_days default"
  assert_json_field "$out" '.inflight.enabled' "false" "inflight.enabled default"
  assert_json_field "$out" '.inflight.pull_refs' "" "inflight.pull_refs default (off, R4)"
  assert_json_field "$out" '.cache.remote_ttl_minutes' "10" "cache.remote_ttl_minutes default"
  assert_json_field "$out" '.severity_order | join(",")' "P0,P1,P2,P3" "severity_order default"
  assert_json_field "$out" '.items.globs | join(",")' "docs/issues/*.md" "items.globs default"
  assert_json_field "$out" '.status.fixed | index("resolved") != null' "true" "status classes default"
  assert_json_field "$out" '.fields.severity | join(",")' "severity,priority" "fields.severity default"
  assert_json_field "$out" '.legacy' "docs/ledger/legacy.json" "legacy default"
  assert_json_field "$out" '.legacy_ids' "[]" "legacy_ids default"
  assert_json_field "$out" '.legacy_ledgers' "{}" "legacy_ledgers default"
  # Arrays and scalars are replaced, not merged.
  out=$(jq -n --argjson h '{"fields":{"severity":"priority"},"items":{"globs":["x/*.md"]}}' -f "$cfg" 2>&1) \
    || out="<jq failed: $out>"
  assert_json_field "$out" '.fields.severity' "priority" "a scalar replaces a list"
  assert_json_field "$out" '.items.globs | join(",")' "x/*.md" "an array is replaced"
  assert_json_field "$out" '.items.archive_globs | join(",")' "docs/archive/issues/*.md" "sibling array default kept"
  # The minimal config.
  out=$(jq -n --argjson h '{}' -f "$cfg" 2>&1) || out="<jq failed: $out>"
  assert_json_field "$out" '.views.recent_days' "14" "{} keeps views.recent_days 14"
}

test_lg_vendored_copy_no_config_inert() {
  echo "test: a vendored doc-tools.sh without scripts/ledger/ is inert without a config"
  lg_fixture
  local dir
  dir=$(harness_mktemp_d vendored)
  cp "$REPO_DIR/scripts/doc-tools.sh" "$dir/doc-tools.sh"
  # Its own runner, not bash_bin_shim: that names the shim by basename and
  # would replace $DOC_TOOLS's shim for the rest of the suite.
  printf '#!/bin/sh\nexec "%s" "%s" "$@"\n' "$BASH_BIN" "$dir/doc-tools.sh" > "$dir/run"
  chmod +x "$dir/run"
  lg_with "$dir/run" ls
  assert_eq "0" "$LG_RC" "vendored, no config: exits 0"
  assert_eq "$LG_INERT_LINE" "$LG_OUT" "vendored, no config: the inert line"
  teardown
}

test_lg_vendored_copy_with_config_rc2() {
  echo "test: a vendored doc-tools.sh without scripts/ledger/ exits 2 when a config exists"
  lg_fixture
  lg_enable
  local dir
  dir=$(harness_mktemp_d vendored)
  cp "$REPO_DIR/scripts/doc-tools.sh" "$dir/doc-tools.sh"
  printf '#!/bin/sh\nexec "%s" "%s" "$@"\n' "$BASH_BIN" "$dir/doc-tools.sh" > "$dir/run"
  chmod +x "$dir/run"
  lg_with "$dir/run" ls
  assert_eq "2" "$LG_RC" "vendored, config present: exits 2"
  assert_contains "$LG_ERR" "scripts/ledger/" "stderr names scripts/ledger/"
  assert_eq "" "$LG_OUT" "text mode: nothing on stdout"
  lg_with "$dir/run" ls --format json
  assert_eq "2" "$LG_RC" "JSON mode: exits 2"
  assert_eq "1" "$(json_count "$LG_OUT")" "JSON mode: exactly one object"
  assert_json_field "$LG_OUT" '.exit' "2" ".exit is 2"
  assert_json_field "$LG_OUT" '.error | test("scripts/ledger/")' "true" ".error names scripts/ledger/"
  teardown
}

test_lg_outside_repo_rc2() {
  echo "test: a ledger verb outside a git repo, or below its top level, exits 2 (not inert)"
  local nogit
  nogit=$(harness_mktemp_d lg-nogit)
  (
    cd "$nogit"
    export GIT_CEILING_DIRECTORIES="$SUITE_TMP"
    lg ls
    assert_eq "2" "$LG_RC" "outside a repo: exits 2"
    assert_not_contains "$LG_OUT" "not enabled" "outside a repo: not the inert line"
    lg ls --format json
    assert_eq "2" "$LG_RC" "outside a repo, JSON: exits 2"
    assert_eq "1" "$(json_count "$LG_OUT")" "outside a repo, JSON: exactly one object"
    assert_json_field "$LG_OUT" '.exit' "2" ".exit is 2"
    print_counts_to "$nogit/counts"
  )
  absorb_counts "$nogit/counts"
  lg_fixture
  (
    cd docs
    lg ls
    assert_eq "2" "$LG_RC" "below the top level: exits 2"
    assert_not_contains "$LG_OUT" "not enabled" "below the top level: not the inert line"
    print_counts_to "$TEST_DIR/counts"
  )
  absorb_counts "$TEST_DIR/counts"
  teardown
}

test_lg_die_inside_subshell_one_object() {
  echo "test: _lg_die inside \$(…) emits one verdict; the EXIT trap adds none"
  lg_fixture
  lg_enable
  DOC_TOOLS_LEDGER_SELFTEST=die-in-subst lg ls --format json
  assert_eq "2" "$LG_RC" "exits 2"
  assert_eq "1" "$(json_count "$LG_OUT")" "exactly one object"
  assert_json_field "$LG_OUT" '.error' "boom" ".error is the die message"
  assert_json_field "$LG_OUT" '.exit' "2" ".exit is 2"
  DOC_TOOLS_LEDGER_SELFTEST=die-in-subst lg ls
  assert_eq "2" "$LG_RC" "text mode: exits 2"
  assert_eq "" "$LG_OUT" "text mode: nothing on stdout"
  assert_contains "$LG_ERR" "boom" "text mode: stderr has the message"
  assert_not_contains "$LG_ERR" "internal error" "text mode: no fallback line"
  teardown
}

test_lg_crash_is_rc2() {
  echo "test: an unhandled crash (set -u) in a ledger verb exits 2 with the fallback, never 1"
  lg_fixture
  lg_enable
  DOC_TOOLS_LEDGER_SELFTEST=unset-var lg ls --format json
  assert_contains "$LG_ERR" "unbound variable" "precondition: the run crashed on an unset variable"
  assert_eq "2" "$LG_RC" "exits 2"
  assert_eq "1" "$(json_count "$LG_OUT")" "exactly one object"
  assert_json_field "$LG_OUT" '.error' "internal" ".error is 'internal'"
  assert_json_field "$LG_OUT" '.verb' "ledger ls" ".verb is 'ledger ls'"
  assert_json_field "$LG_OUT" '.enabled' "true" ".enabled is true"
  assert_json_field "$LG_OUT" '.exit' "2" ".exit is 2"
  DOC_TOOLS_LEDGER_SELFTEST=unset-var lg ls
  assert_eq "2" "$LG_RC" "text mode: exits 2"
  assert_contains "$LG_ERR" "ledger: internal error" "text mode: the internal-error line"
  teardown
}

# --- Task 1 helpers, called directly (lg_source) -------------------------------

test_lg_source_guard() {
  echo "test: DOC_TOOLS_SOURCE_ONLY=1 defines doc-tools.sh's functions without running _main — only when sourced"
  lg_fixture
  local out rc
  set +e
  out=$(DOC_TOOLS_SOURCE_ONLY=1; . "$REPO_DIR/scripts/doc-tools.sh" ledger ls; type _main >/dev/null 2>&1 && echo defined)
  rc=$?
  set -e
  assert_eq "0" "$rc" "sourcing with the guard returns 0"
  assert_eq "defined" "$out" "sourcing prints nothing and defines _main"
  # Executed (not sourced), the variable changes nothing.
  DOC_TOOLS_SOURCE_ONLY=1 lg ls
  assert_eq "0" "$LG_RC" "executed with DOC_TOOLS_SOURCE_ONLY=1: the verb runs"
  assert_eq "$LG_INERT_LINE" "$LG_OUT" "executed with DOC_TOOLS_SOURCE_ONLY=1: the inert line"
  teardown
}

test_lg_doc_index_helper() {
  echo "test: _lg_doc_index — absent → {\"docs\":{}}; present → a copy; invalid → rc 2, never 1"
  lg_fixture
  lg_enable
  lg_call _lg_doc_index
  assert_eq "0" "$LG_RC" "absent index: rc 0"
  assert_eq '{"docs":{}}' "$(cat "$LG_OUT" 2>/dev/null)" "absent index: the empty index"
  printf '%s\n' '{"docs":{"a.md":{"doc_type":"spec"}}}' > docs/.doc-index.json
  lg_call _lg_doc_index
  assert_eq "0" "$LG_RC" "valid index: rc 0"
  assert_true "valid index: a private copy, not the file" test "$LG_OUT" != "docs/.doc-index.json"
  assert_eq '{"docs":{"a.md":{"doc_type":"spec"}}}' "$(cat "$LG_OUT" 2>/dev/null)" "valid index: same content"
  printf '%s\n' '{"docs":[]}' > docs/.doc-index.json
  lg_call _lg_doc_index
  assert_eq "2" "$LG_RC" "a .docs that is not an object: rc 2"
  assert_contains "$LG_ERR" "docs/.doc-index.json" "stderr names the index"
  printf '{\n' > docs/.doc-index.json
  lg_call _lg_doc_index
  assert_eq "2" "$LG_RC" "unparsable index: rc 2"
  teardown
}

test_lg_cfg_usage_emit_helpers() {
  echo "test: _lg_cfg, _lg_usage (rc 3) and _lg_emit (one object; .verb from _LG_VERB)"
  lg_fixture
  lg_enable '{"views":{"recent_days":7}}'
  lg_call _lg_cfg '.views.recent_days'
  assert_eq "7" "$LG_OUT" "_lg_cfg: the host value"
  lg_call _lg_cfg '.views.branch'
  assert_eq "doc-ledger-views" "$LG_OUT" "_lg_cfg: a default, raw"
  lg_call _lg_cfg '.items.globs'
  assert_eq '["docs/issues/*.md"]' "$LG_OUT" "_lg_cfg: compact JSON for a non-string"
  lg_call _lg_cfg '.views | nope('
  assert_eq "2" "$LG_RC" "_lg_cfg: a jq failure is rc 2"

  lg_call _lg_usage "bad thing"
  assert_eq "3" "$LG_RC" "_lg_usage: rc 3"
  assert_contains "$LG_ERR" "ledger ls: bad thing" "_lg_usage: stderr names the verb"
  LG_FORMAT=json lg_call _lg_usage "bad thing"
  assert_eq "3" "$LG_RC" "_lg_usage, JSON: rc 3"
  assert_eq "1" "$(json_count "$LG_OUT")" "_lg_usage, JSON: one object"
  assert_json_field "$LG_OUT" '.exit' "3" "_lg_usage, JSON: .exit 3"
  assert_json_field "$LG_OUT" '.verb' "ledger ls" "_lg_usage, JSON: .verb"

  LG_FORMAT=json lg_call _lg_emit ls 0
  assert_eq "0" "$LG_RC" "_lg_emit 0: rc 0"
  assert_eq '{"verb":"ledger ls","enabled":true,"exit":0}' "$LG_OUT" "_lg_emit 0: the exact object"
  local payload
  payload=$(harness_mktemp payload)
  printf '%s\n' '{"items":[1],"verb":"x","enabled":false,"exit":9}' > "$payload"
  LG_FORMAT=json lg_call _lg_emit ls 1 "$payload"
  assert_eq "1" "$LG_RC" "_lg_emit 1 with a payload: rc 1"
  assert_eq '{"verb":"ledger ls","enabled":true,"exit":1,"items":[1]}' "$LG_OUT" \
    "_lg_emit: the payload's keys follow; its verb/enabled/exit never override"
  LG_SUB=show LG_FORMAT=json lg_call _lg_emit show 0
  assert_json_field "$LG_OUT" '.verb' "ledger show" "_lg_emit: .verb follows _LG_VERB"
  LG_SUB=show LG_FORMAT=json lg_call _lg_emit ls 0
  assert_eq "2" "$LG_RC" "_lg_emit for another verb than _LG_VERB: rc 2"
  assert_eq "1" "$(json_count "$LG_OUT")" "…with one object"
  assert_json_field "$LG_OUT" '.verb' "ledger show" "…naming the run's verb"
  LG_FORMAT=json lg_call _lg_emit ls 7
  assert_eq "2" "$LG_RC" "_lg_emit with an exit code outside 0-3: rc 2"
  assert_eq "1" "$(json_count "$LG_OUT")" "…with one object"
  lg_call _lg_emit ls 1 "$payload"
  assert_eq "1" "$LG_RC" "_lg_emit, text mode: rc 1"
  assert_eq "" "$LG_OUT" "_lg_emit, text mode: nothing on stdout"
  teardown
}

# --- Task 2: frontmatter parser, writer, parse cache ---------------------------

test_lg_fm_scalars_and_lists() {
  echo "test: frontmatter scalars, flow sequences and block sequences parse to exact values"
  lg_fixture
  cat > a.md <<'EOF'
---
key: x-3
ledger: x
changes: [field:a, component:B]
related-files:
  - src/a.js
  - "src/b c.js"
consumes:
- spec:SPEC-1
- 'flag:new one'
relates: []
owed:
---
# Title
EOF
  local out
  out=$(lg_fm a.md docs/issues/a.md)
  assert_json_field "$out" '.path' "docs/issues/a.md" ".path is the -v path"
  assert_json_field "$out" '.fm.key' "x-3" "scalar key"
  assert_json_field "$out" '.fm.ledger' "x" "scalar ledger"
  assert_json_field "$out" '.fm.changes | tojson' '["field:a","component:B"]' "flow sequence"
  assert_json_field "$out" '.fm["related-files"] | tojson' '["src/a.js","src/b c.js"]' "block sequence, quoted item with a space"
  assert_json_field "$out" '.fm.consumes | tojson' '["spec:SPEC-1","flag:new one"]' "compact block sequence (items at column 0)"
  assert_json_field "$out" '.fm.relates | tojson' '[]' "empty flow sequence"
  assert_json_field "$out" '.fm.owed | tojson' '""' "an empty value is the empty string"
  assert_json_field "$out" '.fm | keys_unsorted | join(",")' "key,ledger,changes,related-files,consumes,relates,owed" "keys in file order"
  assert_json_field "$out" '.fm_errors | tojson' '[]' "no errors"
  assert_json_field "$out" '.h1' "Title" "h1"
  assert_json_field "$out" 'keys_unsorted | join(",")' "path,fm,fm_errors,h1,first_para,resolution,log" "the record's keys, in order"
  teardown
}

test_lg_fm_crlf_bom() {
  echo "test: CRLF line endings and a UTF-8 BOM give the identical record"
  lg_fixture
  cat > a.md <<'EOF'
---
key: x-3
summary: "Totals: wrong"
changes: [field:a]
related-files:
  - src/a.js
---
# Title

First para
line two.

## Resolution

Fixed.

## Log
EOF
  lg_crlf a.md crlf.md
  { printf '%s' "$LG_BOM"; cat a.md; } > bom.md
  { printf '%s' "$LG_BOM"; cat crlf.md; } > both.md
  local plain
  plain=$(lg_fm a.md p.md)
  assert_json_field "$plain" '.fm.summary' "Totals: wrong" "precondition: the plain file parses"
  assert_eq "$plain" "$(lg_fm crlf.md p.md)" "CRLF: identical record"
  assert_eq "$plain" "$(lg_fm bom.md p.md)" "BOM: identical record"
  assert_eq "$plain" "$(lg_fm both.md p.md)" "BOM + CRLF: identical record"
  # A BOM anywhere but the very start is not stripped: line 1 is then not "---".
  { printf 'x%s' "$LG_BOM"; cat a.md; } > late.md
  assert_json_field "$(lg_fm late.md)" '.fm | tojson' '{}' "a BOM after the first byte: no frontmatter"
  teardown
}

test_lg_fm_nested_map_rejected() {
  echo "test: a nested map in any key is an fm_errors entry naming the key; the rest parses"
  lg_fixture
  cat > a.md <<'EOF'
---
key: x-1
meta:
  owner: bob
  team: core
status: Open
flow: {a: 1}
items:
  - a: b
  - c
summary: kept
---
EOF
  local out
  out=$(lg_fm a.md)
  assert_json_field "$out" '.fm | keys_unsorted | join(",")' "key,status,summary" "the nested keys are omitted, the rest kept"
  assert_json_field "$out" '.fm.status' "Open" "a key after a nested map still parses"
  assert_json_field "$out" '.fm_errors | length' "3" "three errors"
  assert_json_field "$out" '[.fm_errors[] | test("meta")] | any' "true" "an error names 'meta'"
  assert_json_field "$out" '[.fm_errors[] | test("flow")] | any' "true" "an error names 'flow'"
  assert_json_field "$out" '[.fm_errors[] | test("items")] | any' "true" "an error names 'items' (a map inside a sequence)"
  teardown
}

test_lg_fm_no_frontmatter() {
  echo "test: no frontmatter (line 1 is not ---) → empty fm, no error; the body still parses"
  lg_fixture
  printf '# Title\n\nPara.\n' > a.md
  local out
  out=$(lg_fm a.md)
  assert_json_field "$out" '.fm | tojson' '{}' "fm is {}"
  assert_json_field "$out" '.fm_errors | tojson' '[]' "no errors"
  assert_json_field "$out" '.h1' "Title" "h1"
  assert_json_field "$out" '.first_para' "Para." "first_para"
  # Frontmatter starts only on line 1.
  printf '\n---\nkey: x-1\n---\n# T\n' > b.md
  assert_json_field "$(lg_fm b.md)" '.fm | tojson' '{}' "--- on line 2 is not frontmatter"
  : > empty.md
  out=$(lg_fm empty.md)
  assert_json_field "$out" '.fm | tojson' '{}' "empty file: fm {}"
  assert_json_field "$out" '[.h1, .first_para, .resolution, .log] | tojson' '[null,null,null,false]' "empty file: nulls and log false"
  teardown
}

test_lg_fm_unterminated() {
  echo "test: an unterminated frontmatter block is a per-file error, never trusted"
  lg_fixture
  printf -- '---\nkey: x-1\nstatus: Open\n# Title\n' > a.md
  local out
  out=$(lg_fm a.md)
  assert_json_field "$out" '.fm | tojson' '{}' "fm is {} (nothing from an unterminated block)"
  assert_json_field "$out" '.fm_errors | length' "1" "one error"
  assert_json_field "$out" '.fm_errors[0] | test("unterminated")' "true" "the error says unterminated"
  assert_json_field "$out" '.h1' "Title" "the body still yields its h1"
  teardown
}

test_lg_fm_fence_dash() {
  echo "test: --- and headings inside a fenced body block are ignored"
  lg_fixture
  cat > a.md <<'EOF'
---
key: x-1
---
# T

```yaml
---
key: fake
---
# not a heading
## Resolution
## Log
```

~~~~
```
## Log
~~~~

## Resolution

Real resolution.
EOF
  local out
  out=$(lg_fm a.md)
  assert_json_field "$out" '.fm | tojson' '{"key":"x-1"}' "fm from the real block only"
  assert_json_field "$out" '.fm_errors | tojson' '[]' "no errors"
  assert_json_field "$out" '.h1' "T" "h1 is the real one"
  assert_json_field "$out" '.resolution' "Real resolution." "resolution after the real heading"
  assert_json_field "$out" '.log' "false" "a log heading inside a fence does not count (and a shorter fence does not close a longer one)"
  assert_json_field "$out" '.first_para' "Real resolution." "fenced text is not a paragraph (the first one is after the fences)"
  teardown
}

test_lg_fm_quoted_values() {
  echo "test: quoted scalars, comments and quoted flow items"
  lg_fixture
  cat > a.md <<'EOF'
---
summary: "Totals: wrong # sometimes"
owed: 'it''s # fine'
plain: value # a comment
hash: a#b
colon: a:b
esc: "a \"b\" \\ c"
quoted_c: "x" # trailing comment
flow: [ "a, b", 'c', d ]  # comment
---
EOF
  local out
  out=$(lg_fm a.md)
  assert_json_field "$out" '.fm.summary' "Totals: wrong # sometimes" "double-quoted: ':' and '#' kept"
  assert_json_field "$out" '.fm.owed' "it's # fine" "single-quoted: '' is a quote"
  assert_json_field "$out" '.fm.plain' "value" "plain: ' #' starts a comment"
  assert_json_field "$out" '.fm.hash' "a#b" "plain: '#' without a space before it is text"
  assert_json_field "$out" '.fm.colon' "a:b" "plain: ':' without a space after it is text"
  assert_json_field "$out" '.fm.esc' 'a "b" \ c' "double-quoted escapes"
  assert_json_field "$out" '.fm.quoted_c' "x" "a comment after a quoted value"
  assert_json_field "$out" '.fm.flow | tojson' '["a, b","c","d"]' "flow items: quotes protect commas"
  assert_json_field "$out" '.fm_errors | tojson' '[]' "no errors"
  teardown
}

test_lg_fm_resolution_h1_para() {
  echo "test: h1, first_para (≤ 300 chars), resolution (first non-empty line) and log"
  lg_fixture
  cat > a.md <<'EOF'
---
key: x-1
---

# Totals are wrong

Totals drift	when
the cart is   edited.

More text.

## Resolution

### Detail

Fixed in abc123.

## Log
- something
EOF
  local out
  out=$(lg_fm a.md)
  assert_json_field "$out" '.h1' "Totals are wrong" "h1, trimmed"
  assert_json_field "$out" '.first_para' "Totals drift when the cart is edited." "first_para: lines joined, whitespace collapsed"
  assert_json_field "$out" '.resolution' "Fixed in abc123." "resolution: first text line (a deeper heading skipped)"
  assert_json_field "$out" '.log' "true" "log heading present"
  printf -- '---\nkey: x-1\n---\n# T\n\n## Resolution\n\n## Log\n' > b.md
  out=$(lg_fm b.md)
  assert_json_field "$out" '.resolution' "null" "an empty resolution section is null"
  printf '# T\n' > c.md
  assert_json_field "$(lg_fm c.md)" '[.resolution, .log] | tojson' '[null,false]' "no headings: null and false"
  # A long paragraph of multi-byte characters: cut to 300 characters, valid UTF-8.
  local long="" i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
    long="${long}héllo wörld "
  done
  printf '# T\n\n%s\n' "$long" > d.md
  out=$(lg_fm d.md)
  assert_json_field "$out" '.first_para | length' "300" "first_para is cut to 300 characters"
  assert_json_field "$out" '.first_para | endswith("…")' "true" "a cut paragraph ends with …"
  assert_json_field "$out" '.first_para | startswith("héllo wörld héllo")' "true" "multi-byte characters intact"
  teardown
}

# The writer tests' item: frontmatter, then a body with a fence holding
# frontmatter-like lines, trailing spaces, and no final newline.
lg_write_fixture() {
  # shellcheck disable=SC2016  # the backticks are the fixture's fence
  printf -- '---\nkey: x-1\nstatus: Open\nrelated-files:\n  - src/a.js\n---\n# Title\n\nBody   \n```yaml\n---\nkey: fake\n---\n```\nno final newline' > "$1"
}

lg_t_fm_write_append_and_replace() {
  local f=docs/issues/a.md body out
  lg_write_fixture "$f"
  body=$(lg_tail_hash "$f" 7)
  _lg_fm_set "$f" summary "Totals wrong"
  assert_eq "summary: Totals wrong" "$(sed -n 6p "$f")" "set: a missing field is appended as the last frontmatter line"
  assert_eq "---" "$(sed -n 7p "$f")" "set: the closing --- follows"
  assert_eq "$body" "$(lg_tail_hash "$f" 8)" "set (append): body bytes unchanged"
  _lg_fm_set "$f" status Fixed
  assert_eq "status: Fixed" "$(sed -n 3p "$f")" "set: an existing field is replaced in place"
  assert_eq "$body" "$(lg_tail_hash "$f" 8)" "set (replace): body bytes unchanged"
  _lg_fm_list_add "$f" changes field:a
  _lg_fm_list_add "$f" changes component:B
  _lg_fm_list_add "$f" changes field:a
  assert_eq "changes: [field:a, component:B]" "$(sed -n 7p "$f")" "list add: a flow list, appended once per item"
  _lg_fm_list_add "$f" related-files src/b.js
  assert_eq "  - src/b.js" "$(sed -n 6p "$f")" "list add: a block list gets a new item line"
  assert_eq "$body" "$(lg_tail_hash "$f" 10)" "list add: body bytes unchanged"
  out=$(lg_fm "$f")
  assert_json_field "$out" '.fm | tojson' \
    '{"key":"x-1","status":"Fixed","related-files":["src/a.js","src/b.js"],"summary":"Totals wrong","changes":["field:a","component:B"]}' \
    "the edited frontmatter parses back"
  _lg_fm_del "$f" related-files
  _lg_fm_del "$f" status
  _lg_fm_del "$f" nope
  assert_json_field "$(lg_fm "$f")" '.fm | tojson' \
    '{"key":"x-1","summary":"Totals wrong","changes":["field:a","component:B"]}' "del: the key and its item lines go; a missing key is a no-op"
  assert_eq "$body" "$(lg_tail_hash "$f" 6)" "del: body bytes unchanged"
  # A scalar becomes a list when an item is added.
  _lg_fm_set "$f" relates sibling:x-2
  _lg_fm_list_add "$f" relates root-cause:x-3
  assert_json_field "$(lg_fm "$f")" '.fm.relates | tojson' '["sibling:x-2","root-cause:x-3"]' "list add on a scalar: a two-item list"

  # CRLF: new lines take the file's line ending; the body is untouched.
  lg_write_fixture crlf.src
  lg_crlf crlf.src docs/issues/c.md
  body=$(lg_tail_hash docs/issues/c.md 7)
  _lg_fm_set docs/issues/c.md summary "S"
  assert_eq "summary: S"$'\r' "$(sed -n 6p docs/issues/c.md)" "CRLF: the new line ends in CRLF"
  assert_eq "$body" "$(lg_tail_hash docs/issues/c.md 8)" "CRLF: body bytes unchanged"

  # No frontmatter: a block is created at the top; a BOM stays first.
  printf '%s# T\nbody' "$LG_BOM" > docs/issues/n.md
  _lg_fm_set docs/issues/n.md key x-9
  assert_eq "$(printf '%s---\nkey: x-9\n---\n# T\nbody' "$LG_BOM" | od -An -c)" "$(od -An -c < docs/issues/n.md)" \
    "no frontmatter: a block is prepended after the BOM, the rest byte for byte"
  assert_json_field "$(lg_fm docs/issues/n.md)" '.fm.key' "x-9" "…and it parses"

  # An unterminated block is never edited.
  printf -- '---\nkey: x-1\n# T\n' > docs/issues/u.md
  cp docs/issues/u.md u.before
  lg_rc _lg_fm_set docs/issues/u.md summary S
  assert_eq "2" "$LG_RC" "unterminated frontmatter: the writer exits 2"
  assert_true "unterminated frontmatter: the file is unchanged" cmp -s u.before docs/issues/u.md

  # The file's mode is kept.
  chmod 640 "$f"
  _lg_fm_set "$f" owed deploy
  assert_eq "640" "$(_file_mode "$f")" "the file's permission bits are kept"
}

test_lg_fm_write_append_and_replace() {
  echo "test: frontmatter writers — append, replace, list add, delete; body bytes untouched"
  lg_fixture
  lg_enable
  lg_in lg_t_fm_write_append_and_replace
  teardown
}

lg_t_fm_write_quotes() {
  local f=docs/issues/q.md v line got i=0
  printf -- '---\nkey: x-1\n---\n# T\n' > "$f"
  for v in "a: b" "x # y" " lead" "trail " "[x" "-x" "plain" 'q "a" \ b: c' "" "{x" "'s" "a,b" \
    $'two\nlines' $'tab\there' $'q"\n\\'; do
    i=$((i + 1))
    _lg_fm_set "$f" "f$i" "$v"
    got=$(lg_fm "$f" | jq -r --arg k "f$i" '.fm[$k]')
    assert_eq "$v" "$got" "round trip: '$v'"
  done
  line=$(grep '^f1:' "$f")
  assert_eq 'f1: "a: b"' "$line" "':' is double-quoted"
  assert_eq 'f2: "x # y"' "$(grep '^f2:' "$f")" "'#' is double-quoted"
  assert_eq 'f3: " lead"' "$(grep '^f3:' "$f")" "a leading space is double-quoted"
  assert_eq 'f4: "trail "' "$(grep '^f4:' "$f")" "a trailing space is double-quoted"
  assert_eq 'f5: "[x"' "$(grep '^f5:' "$f")" "a leading [ is double-quoted"
  assert_eq 'f6: "-x"' "$(grep '^f6:' "$f")" "a leading - is double-quoted"
  assert_eq 'f7: plain' "$(grep '^f7:' "$f")" "a plain value is not quoted"
  assert_eq 'f8: "q \"a\" \\ b: c"' "$(grep '^f8:' "$f")" "quotes and backslashes are escaped"
  # Flow-list items with a comma or a quote are quoted too.
  _lg_fm_list_add "$f" changes "a, b"
  _lg_fm_list_add "$f" changes 'c"d'
  _lg_fm_list_add "$f" changes $'e\nf'
  assert_json_field "$(lg_fm "$f")" '.fm.changes | tojson' '["a, b","c\"d","e\nf"]' "flow items round-trip (a newline too)"
  # An empty item and an item ending in a newline are written as given.
  _lg_fm_list_add "$f" tags ""
  assert_json_field "$(lg_fm "$f")" '.fm.tags | tojson' '[""]' "list add: an empty item"
  _lg_fm_list_add "$f" tags2 $'foo\n'
  assert_json_field "$(lg_fm "$f")" '.fm.tags2 | tojson' '["foo\n"]' "list add: an item ending in a newline"
  _lg_fm_list_add "$f" tags2 "bar"
  assert_json_field "$(lg_fm "$f")" '.fm.tags2 | tojson' '["foo\n","bar"]' "list add: then another item"
  # A bad field name is refused.
  lg_rc _lg_fm_set "$f" "bad name" x
  assert_eq "2" "$LG_RC" "a field name with a space: rc 2"
}

test_lg_fm_write_quotes() {
  echo "test: the writer double-quotes scalars that need it, and every value round-trips"
  lg_fixture
  lg_enable
  lg_in lg_t_fm_write_quotes
  teardown
}

# shellcheck disable=SC2031  # lg_in runs this body where lg_source set the _LG_*/_SCRATCH globals
lg_t_parse_path_space_unicode() {
  local paths="$_SCRATCH/t.paths" out="$_SCRATCH/t.jsonl" names
  _lg_item_paths worktree "$paths"
  names=$(lg_names "$paths" | LC_ALL=C sort | tr '\n' '|')
  assert_eq "docs/archive/issues/old.md|docs/issues/new|docs/issues/new.md|docs/issues/ü x.md|line.md|" "$names" \
    "worktree item paths: tracked + untracked under the globs (a newline name too), archive included; others excluded"
  _lg_parse_worktree "$paths" "$out"
  assert_eq "4" "$(jq -s 'length' "$out")" "one record per path"
  assert_json_field "$(jq -c 'select(.path == "docs/issues/ü x.md")' "$out")" '.fm.key' "x-1" "the unicode/space path parses"
  assert_json_field "$(jq -c 'select(.path == "docs/issues/ü x.md")' "$out")" '.blob' \
    "sha256:$(hash_file "docs/issues/ü x.md")" ".blob is the content hash"
  assert_json_field "$(jq -c 'select(.path == "docs/issues/ü x.md")' "$out")" '.archived' "false" "not archived"
  assert_json_field "$(jq -c 'select(.path == "docs/archive/issues/old.md")' "$out")" '.archived' "true" "archive glob → archived"
  assert_json_field "$(jq -c 'select(.path == "docs/issues/new.md")' "$out")" '.fm.key' "x-2" "the untracked item parses"
  # A name holding a newline: listed, then an error record with the exact name.
  assert_json_field "$(jq -c 'select(.path == "docs/issues/new\nline.md")' "$out")" '.fm_errors | length' "1" \
    "a path with a newline: an error record carrying the exact path"
  _lg_item_paths HEAD "$paths"
  names=$(lg_names "$paths" | LC_ALL=C sort | tr '\n' '|')
  assert_eq "docs/archive/issues/old.md|docs/issues/ü x.md|" "$names" "HEAD item paths: committed files only"
  _lg_parse_blobs HEAD "$paths" "$out"
  assert_json_field "$(jq -c 'select(.path == "docs/issues/ü x.md")' "$out")" '.blob' \
    "$(git rev-parse "HEAD:docs/issues/ü x.md")" "blob parse: .blob is the blob id"
  assert_json_field "$(jq -c 'select(.path == "docs/archive/issues/old.md")' "$out")" '.archived' "true" "blob parse: archived"
  assert_json_field "$(jq -c 'select(.path == "docs/issues/ü x.md")' "$out")" '.fm.key' "x-1" "blob parse: the unicode/space path"
  lg_rc _lg_item_paths --bogus "$paths"
  assert_eq "2" "$LG_RC" "a rev that starts with - is refused (rc 2)"
  lg_rc _lg_item_paths no-such-rev "$paths"
  assert_eq "2" "$LG_RC" "an unknown rev is rc 2"
}

test_lg_parse_path_space_unicode() {
  echo "test: item paths and records for a path with a space and unicode; untracked; archived"
  lg_fixture
  lg_enable
  mkdir -p docs/archive/issues docs/notes
  printf -- '---\nkey: x-1\n---\n# Ü\n' > "docs/issues/ü x.md"
  printf -- '---\nkey: x-0\nstatus: Fixed\n---\n' > docs/archive/issues/old.md
  printf -- '# not an item\n' > docs/notes/x.md
  mkdir -p docs/issues/sub && printf '# T\n' > docs/issues/sub/deep.md
  git add -A && git commit -qm items
  printf -- '---\nkey: x-2\n---\n' > docs/issues/new.md
  printf -- '---\nkey: x-3\n---\n' > "docs/issues/new"$'\n'"line.md"
  lg_in lg_t_parse_path_space_unicode
  teardown
}

# shellcheck disable=SC2031  # lg_in runs this body where lg_source set the _LG_*/_SCRATCH globals
lg_t_parse_blobs_staged() {
  local paths="$_SCRATCH/t.paths" out="$_SCRATCH/t.jsonl"
  lg_nul_list "$paths" docs/issues/a.md
  _lg_parse_blobs : "$paths" "$out"
  assert_json_field "$(cat "$out")" '.fm.key' "x-1" "staged blob parse: the staged value"
  assert_json_field "$(cat "$out")" '.blob' "$(git rev-parse :docs/issues/a.md)" "staged: .blob is the index's blob id"
  _lg_parse_blobs HEAD "$paths" "$out"
  assert_json_field "$(cat "$out")" '.fm.key' "x-0" "HEAD blob parse: the committed value"
  _lg_parse_worktree "$paths" "$out"
  assert_json_field "$(cat "$out")" '.fm.key' "x-2" "worktree parse: the working copy's value"
  _lg_item_paths : "$paths"
  assert_eq "docs/issues/a.md|docs/issues/b.md|" "$(lg_names "$paths" | tr '\n' '|')" "index item paths: staged files"
  # A path the rev does not hold is a per-file error, not an abort.
  lg_nul_list "$paths" docs/issues/b.md
  _lg_parse_blobs HEAD "$paths" "$out"
  assert_json_field "$(cat "$out")" '.fm_errors | length' "1" "a path missing at the rev: one error"
  assert_json_field "$(cat "$out")" '.blob' "null" "…and .blob null"
}

test_lg_parse_blobs_staged_differs_from_worktree() {
  echo "test: the staged blob is parsed, not the working copy"
  lg_fixture
  lg_enable
  printf -- '---\nkey: x-0\n---\n' > docs/issues/a.md
  git add -A && git commit -qm a
  printf -- '---\nkey: x-1\n---\n' > docs/issues/a.md
  printf -- '---\nkey: y-1\n---\n' > docs/issues/b.md
  git add docs/issues/a.md docs/issues/b.md
  printf -- '---\nkey: x-2\n---\n' > docs/issues/a.md
  lg_in lg_t_parse_blobs_staged
  teardown
}

# shellcheck disable=SC2031  # lg_in runs this body where lg_source set the _LG_*/_SCRATCH globals
lg_t_parse_cache_reuse() {
  local paths="$_SCRATCH/t.paths" out="$_SCRATCH/t.jsonl" err="$_SCRATCH/t.err" first entry
  lg_nul_list "$paths" docs/issues/a.md docs/issues/b.md
  DOC_TOOLS_LEDGER_TRACE=1 _lg_parse_worktree "$paths" "$out" 2> "$err"
  assert_contains "$(cat "$err")" "parse-miss docs/issues/a.md" "first run: a.md is parsed"
  assert_contains "$(cat "$err")" "parse-miss docs/issues/b.md" "first run: b.md is parsed"
  assert_true "the cache dir was created" test -d "$_LG_CACHE/parse"
  first=$(cat "$out")
  DOC_TOOLS_LEDGER_TRACE=1 _lg_parse_worktree "$paths" "$out" 2> "$err"
  assert_eq "" "$(cat "$err")" "second run: no parse (cache hits)"
  assert_eq "$first" "$(cat "$out")" "second run: the same records"
  printf -- '---\nkey: x-9\n---\n' > docs/issues/a.md
  DOC_TOOLS_LEDGER_TRACE=1 _lg_parse_worktree "$paths" "$out" 2> "$err"
  assert_eq "parse-miss docs/issues/a.md" "$(cat "$err")" "an edited file alone is parsed again"
  assert_json_field "$(jq -c 'select(.path == "docs/issues/a.md")' "$out")" '.fm.key' "x-9" "…with its new value"
  # Same content at another path: the content-keyed entry is reused, the path is the new one.
  cp docs/issues/b.md docs/issues/c.md
  lg_nul_list "$paths" docs/issues/c.md
  DOC_TOOLS_LEDGER_TRACE=1 _lg_parse_worktree "$paths" "$out" 2> "$err"
  assert_eq "" "$(cat "$err")" "identical content elsewhere: a cache hit"
  assert_json_field "$(cat "$out")" '.path' "docs/issues/c.md" "…carrying its own path"
  # A corrupt entry is parsed again, never trusted.
  for entry in "$_LG_CACHE"/parse/*/c-*.json; do printf 'garbage' > "$entry"; done
  DOC_TOOLS_LEDGER_TRACE=1 _lg_parse_worktree "$paths" "$out" 2> "$err"
  assert_eq "parse-miss docs/issues/c.md" "$(cat "$err")" "a corrupt cache entry is a miss"
  assert_json_field "$(cat "$out")" '.fm.key' "y-1" "…and the record is right"
  # Blobs: keyed by blob id. HEAD's a.md (x-1) has no valid working-copy
  # entry any more (the bytes changed, and its old entry was corrupted).
  lg_nul_list "$paths" docs/issues/a.md
  DOC_TOOLS_LEDGER_TRACE=1 _lg_parse_blobs HEAD "$paths" "$out" 2> "$err"
  assert_eq "parse-miss docs/issues/a.md" "$(cat "$err")" "first blob parse: a miss"
  DOC_TOOLS_LEDGER_TRACE=1 _lg_parse_blobs HEAD "$paths" "$out" 2> "$err"
  assert_eq "" "$(cat "$err")" "second blob parse: a hit"
  assert_json_field "$(cat "$out")" '.fm.key' "x-1" "…with the right value"
  assert_json_field "$(cat "$out")" '.blob' "$(git rev-parse HEAD:docs/issues/a.md)" "…and the blob id"
  # b.md's committed bytes are what its working copy holds: the blob parse
  # reuses that entry through the blob id -> sha256 map.
  lg_nul_list "$paths" docs/issues/b.md
  DOC_TOOLS_LEDGER_TRACE=1 _lg_parse_blobs HEAD "$paths" "$out" 2> "$err"
  assert_eq "" "$(cat "$err")" "a blob whose bytes a working copy parse saw: a hit"
  assert_json_field "$(cat "$out")" '.fm.key' "y-1" "…with the right value"
}

test_lg_parse_cache_reuse_by_content() {
  echo "test: the parse cache is reused by content (worktree) and by blob id"
  lg_fixture
  lg_enable
  printf -- '---\nkey: x-1\n---\n' > docs/issues/a.md
  printf -- '---\nkey: y-1\n---\n' > docs/issues/b.md
  git add -A && git commit -qm items
  lg_in lg_t_parse_cache_reuse
  teardown
}

# shellcheck disable=SC2031  # lg_in runs this body where lg_source set the _LG_*/_SCRATCH globals
lg_t_parse_blobs_odd() {
  local paths="$_SCRATCH/t.paths" out="$_SCRATCH/t.jsonl" err="$_SCRATCH/t.err"
  lg_nul_list "$paths" docs/issues/link.md docs/issues/a.md docs/issues
  _lg_parse_blobs HEAD "$paths" "$out" 2> "$err"
  assert_eq "" "$(cat "$err")" "no trace without DOC_TOOLS_LEDGER_TRACE"
  assert_json_field "$(jq -c 'select(.path == "docs/issues/a.md")' "$out")" '.fm.key' "x-1" "a regular file beside them parses"
  assert_json_field "$(jq -c 'select(.path == "docs/issues/link.md")' "$out")" '.fm_errors[0] | test("symbolic link")' "true" \
    "a symbolic link at the rev: an error record, not its target text"
  assert_json_field "$(jq -c 'select(.path == "docs/issues")' "$out")" '.fm_errors[0] | test("not found")' "true" \
    "a directory: not found"
  assert_eq "docs/issues/a.md" "$(jq -r 'select(.blob != null) | .path' "$out")" "only the file has a blob"
  lg_nul_list "$paths" docs/issues/m.md
  _lg_parse_blobs : "$paths" "$out"
  assert_json_field "$(cat "$out")" '.fm_errors[0] | test("unmerged")' "true" "an unmerged index entry: an error record"
  # A gitlink (submodule) at an item path: a per-file error, never an abort.
  lg_nul_list "$paths" docs/issues/g.md docs/issues/a.md
  _lg_parse_blobs : "$paths" "$out"
  assert_json_field "$(jq -c 'select(.path == "docs/issues/g.md")' "$out")" '.fm_errors[0] | test("submodule")' "true" \
    "a gitlink in the index: an error record"
  assert_json_field "$(jq -c 'select(.path == "docs/issues/a.md")' "$out")" '.fm.key' "x-1" "…and the other items still parse"
  _lg_parse_blobs HEAD "$paths" "$out"
  assert_json_field "$(jq -c 'select(.path == "docs/issues/g.md")' "$out")" '.fm_errors[0] | test("submodule")' "true" \
    "a gitlink at a commit: an error record"
}

test_lg_parse_blobs_odd_entries() {
  echo "test: blob parsing of a symbolic link, a directory and an unmerged entry gives per-path errors"
  lg_fixture
  lg_enable
  printf -- '---\nkey: x-1\n---\n' > docs/issues/a.md
  ln -s a.md docs/issues/link.md
  printf -- '---\nkey: m-1\n---\n' > docs/issues/m.md
  git add -A && git commit -qm items
  local oid
  oid=$(git hash-object -w docs/issues/m.md)
  # A gitlink (mode 160000) at docs/issues/g.md, committed.
  git update-index --add --cacheinfo "160000,$(git rev-parse HEAD),docs/issues/g.md"
  git commit -qm gitlink
  git rm -q --cached docs/issues/m.md
  printf '100644 %s 1\tdocs/issues/m.md\n100644 %s 2\tdocs/issues/m.md\n' "$oid" "$oid" | git update-index --index-info
  lg_in lg_t_parse_blobs_odd
  teardown
}

lg_t_field() {
  local rec='{"fm":{"priority":"P1","code_refs":["a.js"],"key":"x-1"}}'
  assert_eq '"P1"' "$(_lg_field severity "$rec")" "_lg_field: the second candidate when the first is absent"
  assert_eq '["a.js"]' "$(_lg_field paths "$rec")" "_lg_field: a list value, as JSON"
  assert_eq '"x-1"' "$(_lg_field key "$rec")" "_lg_field: a one-name field"
  assert_eq 'null' "$(_lg_field summary "$rec")" "_lg_field: null when no candidate is present"
  rec='{"fm":{"severity":"P2","priority":"P1"}}'
  assert_eq '"P2"' "$(_lg_field severity "$rec")" "_lg_field: the first candidate wins"
  lg_rc _lg_field nosuch "$rec"
  assert_eq "2" "$LG_RC" "_lg_field: an unknown logical field is rc 2"
}

test_lg_field_candidates() {
  echo "test: _lg_field picks the first configured candidate name present"
  lg_fixture
  lg_enable
  lg_in lg_t_field
  teardown
}

# --- Task 3: registry, globs, validate --registry ------------------------------

# The glob table: "<glob>|<path>|<1 match, 0 not>".
LG_GLOB_CASES='src/**/x.js|src/x.js|1
src/**/x.js|src/a/b/x.js|1
src/**/x.js|srcx.js|0
src/**/x.js|src/a/x.jsx|0
src/**/x.js|x.js|0
**/x.js|x.js|1
**/x.js|a/b/x.js|1
**/x.js|ax.js|0
src/**|src/a|1
src/**|src/a/b|1
src/**|srcx/a|0
*.md|a.md|1
*.md|d/a.md|0
docs/*/a.md|docs/x/a.md|1
docs/*/a.md|docs/x/y/a.md|0
a?c|abc|1
a?c|a/c|0
a?c|ac|0
{a,b}/x|a/x|1
{a,b}/x|b/x|1
{a,b}/x|c/x|0
{a,b}/x|ab/x|0
x/{p/**,q*}|x/p/z/w|1
x/{p/**,q*}|x/qq|1
x/{p/**,q*}|x/r|0
x/{p/**,q*}|x/q/r|0
{a,{b,c}d}|a|1
{a,{b,c}d}|cd|1
{a,{b,c}d}|b|0
s/{x,**/y}.z|s/k/l/y.z|1
my dir/*.txt|my dir/f g.txt|1
my dir/*.txt|my dirx/f.txt|0
a.b|a.b|1
a.b|axb|0
f(1)+[x]$^,|f(1)+[x]$^,|1
f(1)+[x]$^,|f1x|0
a\*b|a*b|1
a\*b|axb|0
ü/*.md|ü/x y.md|1
x{,.d}.ts|x.ts|1
x{,.d}.ts|x.d.ts|1
x{,.d}.ts|x.e.ts|0
{a,}b|ab|1
{a,}b|b|1
{a,}b|cb|0
{a,,b}c|c|1
{a,,b}c|bc|1
{}x|x|1'

# shellcheck disable=SC2031  # lg_in runs this body where lg_source set the _LG_*/_SCRATCH globals
lg_t_glob_ere_cases() {
  local g p want re got
  while IFS='|' read -r g p want; do
    re=$(_lg_glob_ere "$g")
    # The engine the ledger matches with: awk in the C locale.
    got=$(LC_ALL=C awk -v re="${re//\\/\\\\}" -v p="$p" 'BEGIN { print (p ~ re) ? 1 : 0 }')
    assert_eq "$want" "$got" "glob '$g' vs '$p' (ERE $re)"
  done <<<"$LG_GLOB_CASES"
  assert_eq '^src/(.*/)?x[.]js$' "$(_lg_glob_ere 'src/**/x.js')" "the ERE of src/**/x.js"
  lg_rc _lg_glob_ere 'a{b'
  assert_eq "2" "$LG_RC" "an unbalanced { is refused (rc 2)"
  lg_rc _lg_glob_ere 'a}b'
  assert_eq "2" "$LG_RC" "an unbalanced } is refused (rc 2)"
}

test_lg_glob_ere_cases() {
  echo "test: glob → ERE: **/, **, *, ?, {a,b}, escapes, a space and unicode"
  lg_fixture
  lg_enable
  lg_in lg_t_glob_ere_cases
  teardown
}

# shellcheck disable=SC2031  # lg_in runs this body where lg_source set the _LG_*/_SCRATCH globals
lg_t_item_paths_brace() {
  local paths="$_SCRATCH/t.paths"
  _lg_item_paths worktree "$paths"
  assert_eq "docs/bugs/b.md|docs/issues/a.md|" "$(lg_names "$paths" | LC_ALL=C sort | tr '\n' '|')" \
    "a brace item glob picks both directories, nothing else"
  _lg_item_paths HEAD "$paths"
  assert_eq "docs/issues/a.md|" "$(lg_names "$paths" | tr '\n' '|')" "…and at a commit"
}

test_lg_item_paths_brace_glob() {
  echo "test: item globs share the registry grammar ({a,b})"
  lg_fixture
  lg_enable '{"items":{"globs":["docs/{issues,bugs}/*.md"]}}'
  mkdir -p docs/bugs docs/notes
  printf -- '---\nkey: x-1\n---\n' > docs/issues/a.md
  printf -- '# n\n' > docs/notes/n.md
  git add -A && git commit -qm a
  printf -- '---\nkey: x-2\n---\n' > docs/bugs/b.md
  lg_in lg_t_item_paths_brace
  teardown
}

# lg_registry <json>: write docs/ledger/ledgers.json.
lg_registry() {
  printf '%s\n' "$1" > docs/ledger/ledgers.json
}

# lg_files <path>...: create and commit files (a space in a name is fine).
lg_files() {
  local f
  for f in "$@"; do
    mkdir -p "$(dirname "$f")"
    printf 'x\n' > "$f"
  done
  git add -A && git commit -qm files
}

# The classes of a validate JSON verdict's findings, sorted, "|"-joined.
lg_classes() {
  jq -r '[.findings[].class] | sort | join("|")' <<<"$1" 2>/dev/null || echo invalid
}

LG_REG_CLEAN='{"schema":"ledger-registry/1","ledgers":[
  {"id":"app","title":"App","kind":"service","status":"active","paths":["src/app/**"],
   "contracts":[{"id":"field:order.total","defined_in":["src/app/model.*"]}]},
  {"id":"core","title":"Core","kind":"platform","status":"retired","paths":["src/core/**","*.json"],
   "residual_paths":["src/**"],"contracts":[{"id":"component:Core Sheet x"}]}]}'
LG_REG_CLEAN=${LG_REG_CLEAN/'"status":"retired"'/'"status":"active"'}

test_lg_registry_valid_clean() {
  echo "test: validate --registry: a clean registry exits 0 with no findings; absent; invalid → 2"
  lg_fixture
  lg_enable
  lg_files src/app/model.ts "src/core/a b.ts" src/x.ts docs/readme.md
  # No registry: nothing declared, nothing to report.
  lg validate --registry --format json
  assert_eq "0" "$LG_RC" "no ledgers.json: exit 0"
  assert_json_field "$LG_OUT" '.findings | length' "0" "no ledgers.json: no findings"
  assert_json_field "$LG_OUT" '.verb' "ledger validate" ".verb"
  lg_registry "${LG_REG_CLEAN/Core Sheet x/CoreSheet}"
  lg validate --registry --format json
  assert_eq "0" "$LG_RC" "a clean registry exits 0"
  assert_eq "1" "$(json_count "$LG_OUT")" "one object"
  assert_json_field "$LG_OUT" '.findings | length' "0" "no findings (residual src/** owns src/x.ts; docs/ is exempt; docs/ledger/*.json is claimed by nobody but exempt)"
  lg validate --registry
  assert_eq "0" "$LG_RC" "text mode: exit 0"
  assert_eq "" "$LG_OUT" "text mode: nothing printed when clean"
  printf '{"ledgers": [' > docs/ledger/ledgers.json
  lg validate --registry --format json
  assert_eq "2" "$LG_RC" "invalid JSON in ledgers.json: could not run (2)"
  assert_contains "$(jq -r .error <<<"$LG_OUT")" "ledgers.json" "the error names the file"
  lg_registry '{"schema":"ledger-registry/1","ledgers":["app"]}'
  lg validate --registry
  assert_eq "2" "$LG_RC" "a ledger that is not an object: could not run (2)"
  lg validate --format json
  assert_eq "3" "$LG_RC" "validate without a mode is a usage error"
  lg validate --registry stray
  assert_eq "3" "$LG_RC" "a stray argument is a usage error"
  teardown
}

test_lg_registry_duplicate_id() {
  echo "test: validate --registry: bad and duplicate ledger ids"
  lg_fixture
  lg_enable
  lg_registry '{"schema":"ledger-registry/1","ledgers":[
    {"id":"app","kind":"service","status":"active"},
    {"id":"app","kind":"service","status":"active"},
    {"id":"Bad_Id","kind":"service","status":"active"},
    {"id":"unassigned","kind":"service","status":"active"},
    {"kind":"service","status":"active"}]}'
  lg validate --registry --format json
  assert_eq "1" "$LG_RC" "findings exit 1"
  assert_eq "duplicate-id|id|id|id" "$(lg_classes "$LG_OUT")" "one duplicate-id; three bad ids (case, reserved, missing)"
  assert_contains "$(jq -r '.findings[] | select(.class == "duplicate-id") | .detail' <<<"$LG_OUT")" "app" "the duplicate names the id"
  lg validate --registry
  assert_eq "1" "$LG_RC" "text mode: exit 1"
  assert_contains "$LG_OUT" "registry duplicate-id app" "text: registry <class> <detail>"
  assert_eq "4" "$(grep -c '^registry ' <<<"$LG_OUT")" "text: one line per finding"
  teardown
}

test_lg_registry_reserved_readme() {
  echo "test: validate --registry: the ledger id readme is reserved (views write README.md)"
  lg_fixture
  lg_enable
  lg_registry '{"schema":"ledger-registry/1","ledgers":[
    {"id":"readme","kind":"service","status":"active"},
    {"id":"README","kind":"service","status":"active"},
    {"id":"app","kind":"service","status":"active"}]}'
  lg validate --registry --format json
  assert_eq "1" "$LG_RC" "findings exit 1"
  assert_eq "id|id" "$(lg_classes "$LG_OUT")" "both spellings are id findings"
  assert_contains "$(jq -r '.findings[0].detail' <<<"$LG_OUT")" '"readme" is reserved' "readme: reserved"
  teardown
}

test_lg_registry_bad_status() {
  echo "test: validate --registry: schema, status, kind, shape, glob findings"
  lg_fixture
  lg_enable
  lg_registry '{"schema":"ledger-registry/2","ledgers":[
    {"id":"app","kind":"service","status":"draft"},
    {"id":"web","kind":"team","status":"active","paths":"src/**"},
    {"id":"ops","kind":"platform","status":"retired","paths":["ops/{a,b"]}]}'
  lg validate --registry --format json
  assert_eq "1" "$LG_RC" "findings exit 1"
  assert_eq "glob|kind|schema|shape|status" "$(lg_classes "$LG_OUT")" "schema, status, kind, shape (paths a string), glob (unbalanced {, in a retired ledger too); no active ledger declares paths: no unowned"
  assert_contains "$(jq -r '.findings[] | select(.class == "status") | .detail' <<<"$LG_OUT")" '"draft"' "the status finding quotes the value"
  teardown
}

test_lg_registry_contract_dup() {
  echo "test: validate --registry: bad and duplicate contract ids"
  lg_fixture
  lg_enable
  lg_registry '{"schema":"ledger-registry/1","ledgers":[
    {"id":"app","kind":"service","status":"active","contracts":[{"id":"field:order.total"},{"id":"nocolon"}]},
    {"id":"web","kind":"service","status":"active","contracts":[{"id":"field:order.total"},{"id":"spec:SPEC 1"}]}]}'
  lg validate --registry --format json
  assert_eq "1" "$LG_RC" "findings exit 1"
  assert_eq "contract-id|contract-id|duplicate-contract" "$(lg_classes "$LG_OUT")" "two bad contract ids, one duplicate"
  assert_eq "field:order.total is declared by app, web" \
    "$(jq -r '.findings[] | select(.class == "duplicate-contract") | .detail' <<<"$LG_OUT")" "the duplicate names both ledgers"
  teardown
}

test_lg_registry_overlap() {
  echo "test: validate --registry: a tracked file claimed by two ledgers"
  lg_fixture
  lg_enable
  lg_files "src/a b.ts" src/only.ts
  lg_registry '{"schema":"ledger-registry/1","ledgers":[
    {"id":"app","kind":"service","status":"active","paths":["src/**"]},
    {"id":"web","kind":"service","status":"active","paths":["src/a*"]}]}'
  lg validate --registry --format json
  assert_eq "1" "$LG_RC" "overlap exits 1"
  assert_eq "overlap" "$(lg_classes "$LG_OUT")" "one overlap (src/only.ts has one owner)"
  lg validate --registry
  assert_eq "registry overlap src/a b.ts is claimed by app, web" "$LG_OUT" "the exact text line"
  teardown
}

test_lg_registry_unowned() {
  echo "test: validate --registry: tracked files outside docs/ owned by none, once paths are declared"
  lg_fixture
  lg_enable
  lg_files src/a.ts lib/z.ts docs/readme.md README
  lg_registry '{"schema":"ledger-registry/1","ledgers":[{"id":"app","kind":"service","status":"active"}]}'
  lg validate --registry --format json
  assert_eq "0" "$LG_RC" "no ledger declares paths: unowned is not checked"
  lg_registry '{"schema":"ledger-registry/1","ledgers":[{"id":"app","kind":"service","status":"active","paths":["src/**"]}]}'
  lg validate --registry --format json
  assert_eq "1" "$LG_RC" "unowned files exit 1"
  assert_eq "README|lib/z.ts" "$(jq -r '[.findings[] | select(.class == "unowned") | .detail] | join("|")' <<<"$LG_OUT")" \
    "README and lib/z.ts; docs/ files are exempt (docs/ledger/*.json too)"
  teardown
}

# shellcheck disable=SC2031  # lg_in runs this body where lg_source set the _LG_*/_SCRATCH globals
lg_t_owner_map_residual() {
  local paths="$_SCRATCH/t.paths" map="$_SCRATCH/t.tsv"
  git ls-files -z > "$paths"
  _lg_owner_map "$paths" "$map"
  assert_eq "docs/architecture.md	-|docs/ledger/config.json	-|docs/ledger/ledgers.json	-|lib/k.ts	multi:app,web|src/b/x y.ts	web|src/c.ts	app|src/index.js	app|" \
    "$(tr '\n' '|' < "$map")" "ordinary paths win over residual; two residual claims are multi; none is -"
}

test_lg_registry_residual() {
  echo "test: residual_paths claim only files no ordinary glob claims"
  lg_fixture
  lg_enable
  lg_registry '{"schema":"ledger-registry/1","ledgers":[
    {"id":"app","kind":"service","status":"active","paths":[],"residual_paths":["src/**","lib/**"]},
    {"id":"web","kind":"service","status":"active","paths":["src/b/**"],"residual_paths":["lib/**"]}]}'
  lg_files "src/b/x y.ts" src/c.ts lib/k.ts
  lg_in lg_t_owner_map_residual
  lg validate --registry --format json
  assert_eq "1" "$LG_RC" "two residual claims are an overlap"
  assert_eq "lib/k.ts is claimed by app, web" "$(jq -r '[.findings[].detail] | join("|")' <<<"$LG_OUT")" \
    "only lib/k.ts: src/b/x y.ts goes to web's ordinary glob, not app's residual"
  teardown
}

# shellcheck disable=SC2031  # lg_in runs this body where lg_source set the _LG_*/_SCRATCH globals
lg_t_owner_map_exclusion() {
  local paths="$_SCRATCH/t.paths" map="$_SCRATCH/t.tsv"
  lg_nul_list "$paths" src/gen/g.ts src/a.ts lib/v/w.ts lib/u.ts
  _lg_owner_map "$paths" "$map"
  assert_eq "src/gen/g.ts	gen|src/a.ts	app|lib/v/w.ts	gen|lib/u.ts	app|" "$(tr '\n' '|' < "$map")" \
    "a !glob removes the path from its own ledger only (ordinary and residual)"
}

test_lg_registry_exclusion() {
  echo "test: a !glob excludes within its own ledger"
  lg_fixture
  lg_enable
  lg_registry '{"schema":"ledger-registry/1","ledgers":[
    {"id":"app","kind":"service","status":"active","paths":["src/**","!src/gen/**"],"residual_paths":["lib/**","!lib/v/**"]},
    {"id":"gen","kind":"platform","status":"active","paths":["src/gen/**"],"residual_paths":["lib/v/**"]}]}'
  lg_files src/gen/g.ts src/a.ts lib/v/w.ts lib/u.ts
  lg_in lg_t_owner_map_exclusion
  lg validate --registry --format json
  assert_eq "0" "$LG_RC" "no overlap, nothing unowned"
  assert_json_field "$LG_OUT" '.findings | length' "0" "no findings"
  teardown
}

test_lg_registry_id_newline() {
  echo "test: validate --registry: a ledger or contract id with a newline in it is a finding (jq's \$ is not the end)"
  lg_fixture
  lg_enable
  lg_registry '{"schema":"ledger-registry/1","ledgers":[
    {"id":"app\n","kind":"service","status":"active","paths":["src/**"],"contracts":[{"id":"field:a\n"}]},
    {"id":"x\nweb","kind":"service","status":"active","contracts":[{"id":"x\nfield:b"}]}]}'
  lg validate --registry --format json
  assert_eq "1" "$LG_RC" "findings exit 1"
  assert_eq "contract-id|contract-id|id|id" "$(lg_classes "$LG_OUT")" \
    "both ids and both contract ids are refused; src/index.js still owned (no stray rows)"
  teardown
}

# shellcheck disable=SC2031  # lg_in runs this body where lg_source set the _LG_*/_SCRATCH globals
lg_t_owner_map_retired() {
  local paths="$_SCRATCH/t.paths" map="$_SCRATCH/t.tsv"
  lg_nul_list "$paths" src/index.js src/a.d.ts lib/u.ts
  _lg_owner_map "$paths" "$map"
  assert_eq "src/index.js	new|src/a.d.ts	new|lib/u.ts	-|" "$(tr '\n' '|' < "$map")" \
    "the retired ledger claims nothing; its successor owns the shared glob"
}

test_lg_registry_retired_owns_nothing() {
  echo "test: a retired ledger owns no paths: no overlap with its active successor"
  lg_fixture
  lg_enable
  lg_registry '{"schema":"ledger-registry/1","ledgers":[
    {"id":"old","kind":"service","status":"retired","paths":["src/**","lib/**"]},
    {"id":"new","kind":"service","status":"active","paths":["src/**/*{,.d}.{js,ts}"]}]}'
  lg_files src/a.d.ts
  lg_in lg_t_owner_map_retired
  lg validate --registry --format json
  assert_eq "0" "$LG_RC" "no overlap (and an empty brace alternative does not crash the map)"
  assert_json_field "$LG_OUT" '.findings | length' "0" "no findings"
  teardown
}

# --- Task 4: the index — joins, dates, derived status, caches --------------------

# lg_commit_at <YYYY-MM-DD> <message>: commit everything (git add -A) with that
# author and committer date (noon, local time).
lg_commit_at() {
  git add -A
  GIT_AUTHOR_DATE="$1T12:00:00" GIT_COMMITTER_DATE="$1T12:00:00" git commit -qm "$2"
}

# lg_doc_index <json>: write docs/.doc-index.json.
lg_doc_index() {
  printf '%s\n' "$1" > docs/.doc-index.json
}

# lg_item <file> <frontmatter lines…>: an item file with that frontmatter
# (one argument per line) and a "# <stem>" heading.
lg_item() {
  local f="$1" stem
  shift
  mkdir -p "$(dirname "$f")"
  stem=$(basename "$f" .md)
  { printf -- '---\n'; printf '%s\n' "$@"; printf -- '---\n# %s\n' "$stem"; } > "$f"
}

# lg_ix_item <index-file> <path>: the item with that path, compact.
lg_ix_item() {
  jq -c --arg p "$2" '.items[] | select(.path == $p)' "$1"
}

LG_SCHEMA="$REPO_DIR/references/ledger-index.schema.json"

# shellcheck disable=SC2031  # lg_in runs this body where lg_source set the _LG_*/_SCRATCH globals
lg_t_index_fields() {
  local ix it
  ix=$(_lg_index)
  assert_true "the index file exists under the cache dir" test -f "$ix"
  assert_contains "$ix" "$_LG_CACHE/index-" "named index-<hash>.json in \$_LG_CACHE"
  assert_json_field "$(cat "$ix")" 'keys_unsorted | join(",")' "schema,built,ledgers,contracts,path_contracts,items,legacy,finalized" "top-level keys, in order"
  assert_json_field "$(cat "$ix")" '.schema' "ledger-index/1" "schema"
  assert_json_field "$(cat "$ix")" '.built.head' "$(git rev-parse HEAD)" "built.head is HEAD"
  assert_json_field "$(cat "$ix")" '.built.base' "null" "built.base: no origin/main here → null"
  assert_json_field "$(cat "$ix")" '.built.mode' "worktree" "built.mode"
  assert_json_field "$(cat "$ix")" '.built.inputs_hash | test("^sha256:[0-9a-f]{64}$")' "true" "built.inputs_hash"
  assert_json_field "$(cat "$ix")" '.built.registry_findings' "0" "built.registry_findings: a clean registry"
  assert_json_field "$(cat "$ix")" '.ledgers | map(.id) | join(",")' "app" "ledgers: the registry's"
  assert_json_field "$(cat "$ix")" '[.legacy, .finalized] | tojson' '[{},{}]' "legacy and finalized: {} when absent"
  assert_json_field "$(cat "$ix")" '.items | map(.path) | join("|")' \
    "docs/issues/a.md|docs/issues/b.md|docs/issues/c.md|docs/issues/d.md|docs/issues/e.md|docs/issues/f.md|docs/issues/g.md|docs/issues/h.md|docs/issues/i.md" \
    "items sorted by path"
  it=$(lg_ix_item "$ix" docs/issues/a.md)
  assert_json_field "$it" 'keys_unsorted | join(",")' \
    "path,archived,key,ledger,status,class,severity,date,summary,changes,consumes,relates,superseded_by,owed,aliases,paths,h1,first_para,resolution,docs,derived,pr,inflight,neighbours,recheck_after,fm_errors" \
    "an item's keys, in the brief's order"
  assert_json_field "$it" 'keys_unsorted | join(",")' "$(jq -r '."$defs".item.required | join(",")' "$LG_SCHEMA")" \
    "the schema's item.required lists the same keys"
  assert_json_field "$(cat "$ix")" 'keys_unsorted | join(",")' "$(jq -r '.required | join(",")' "$LG_SCHEMA")" \
    "the schema's top-level required lists the same keys"
  assert_json_field "$it" '[.key, .ledger, .status, .class, .severity] | join("|")' "app-1|app|Open|open|P1" "open P1 with a key"
  assert_json_field "$it" '.summary' "Totals are wrong when the cart is edited" "summary"
  assert_json_field "$it" '[.changes, .consumes, .relates, .aliases, .paths] | tojson' \
    '[["field:order.total"],[],[{"kind":"root-cause","key":"app-2"},{"kind":"sibling","key":"app-3"}],[],["src/a.js"]]' \
    "list fields (paths via the related-files candidate)"
  assert_json_field "$it" '[.superseded_by, .owed, .resolution, .pr] | tojson' '[null,null,null,null]' "absent scalars are null"
  assert_json_field "$it" '.neighbours | tojson' '{"upstream":[{"key":"app-2","via":"root-cause"}],"downstream":[],"siblings":[{"key":"app-3","via":"sibling"}]}' \
    "neighbours computed (Task 9): its relates"
  assert_json_field "$it" '[.inflight, .recheck_after, .fm_errors] | tojson' '[[],[],[]]' "empty lists"
  assert_json_field "$it" '.docs | tojson' '{"spec":[],"plan":[],"handoff":[]}' "docs: no links"
  assert_json_field "$it" '.derived | tojson' '{"status":"not started","detail":null}' "open, no docs → not started"
  assert_json_field "$it" '[.h1, .first_para, .archived] | tojson' '["a","Body text.",false]' "h1, first_para, archived"
  it=$(lg_ix_item "$ix" docs/issues/b.md)
  assert_json_field "$it" '[.class, .owed, .severity] | join("|")' "fixed|deploy|P2" "fixed + owed (severity via priority)"
  assert_json_field "$it" '.derived | tojson' '{"status":"merged","detail":"deploy"}' "fixed + owed → merged · owed"
  it=$(lg_ix_item "$ix" docs/issues/c.md)
  assert_json_field "$it" '[.class, .superseded_by, .resolution] | join("|")' "closed|app-1|Replaced by app-1." "closed + superseded_by + resolution"
  assert_json_field "$it" '.derived | tojson' '{"status":"superseded","detail":"app-1"}' "→ superseded → app-1"
  it=$(lg_ix_item "$ix" docs/issues/d.md)
  assert_json_field "$it" '[.key, .ledger, .class] | tojson' '[null,"unassigned","open"]' "unassigned without a key"
  assert_json_field "$it" '.derived.status' "not started" "…not started"
  it=$(lg_ix_item "$ix" docs/issues/e.md)
  assert_json_field "$it" '[.class, .derived.status, .derived.detail] | tojson' '["fixed","shipped",null]' "fixed, nothing owed → shipped"
  it=$(lg_ix_item "$ix" docs/issues/f.md)
  assert_json_field "$it" '[.class, .derived.status] | tojson' "[\"wontfix\",\"won't fix\"]" "won't fix"
  it=$(lg_ix_item "$ix" docs/issues/g.md)
  assert_json_field "$it" '[.status, .class, .derived.status] | tojson' '["Banana","unknown","not started"]' "an unknown status word → unknown"
  it=$(lg_ix_item "$ix" docs/issues/h.md)
  assert_json_field "$it" '[.status, .class] | tojson' '[null,"unknown"]' "no status → unknown"
  assert_json_field "$it" '.fm_errors | length' "1" "a frontmatter error is carried, not fatal"
  it=$(lg_ix_item "$ix" docs/issues/i.md)
  assert_json_field "$it" '[.class, .superseded_by, .derived.status] | tojson' '["fixed","app-1","shipped"]' \
    "superseded_by on a fixed item: not superseded (that needs a closed-class status)"
}

test_lg_index_fields() {
  echo "test: _lg_index — fields, classes and derived status of each item kind; the schema's keys"
  lg_fixture
  lg_enable
  lg_registry '{"schema":"ledger-registry/1","ledgers":[{"id":"app","title":"App","kind":"service","status":"active"}]}'
  lg_item docs/issues/a.md "key: app-1" "ledger: app" "status: Open" "severity: P1" \
    "summary: Totals are wrong when the cart is edited" "changes: [field:order.total]" \
    "relates: [root-cause:app-2, sibling:app-3]" "related-files:" "  - src/a.js"
  printf '\nBody text.\n' >> docs/issues/a.md
  lg_item docs/issues/b.md "key: app-2" "ledger: app" "status: Fixed" "priority: P2" "owed: deploy"
  lg_item docs/issues/c.md "key: app-3" "ledger: app" "status: Closed" "superseded_by: app-1"
  printf '\n## Resolution\n\nReplaced by app-1.\n' >> docs/issues/c.md
  lg_item docs/issues/d.md "ledger: unassigned" "status: In progress" "summary: Somewhere"
  lg_item docs/issues/e.md "key: app-4" "ledger: app" "status: Fixed"
  lg_item docs/issues/f.md "key: app-5" "ledger: app" "status: won't fix"
  lg_item docs/issues/g.md "key: app-6" "ledger: app" "status: Banana"
  lg_item docs/issues/h.md "key: app-7" "nested:" "  a: b"
  lg_item docs/issues/i.md "key: app-8" "ledger: app" "status: Fixed" "superseded_by: app-1"
  git add -A && git commit -qm items
  lg_in lg_t_index_fields
  teardown
}

# shellcheck disable=SC2031  # lg_in runs this body where lg_source set the _LG_*/_SCRATCH globals
lg_t_index_status_classes() {
  local ix
  ix=$(_lg_index)
  assert_json_field "$(cat "$ix")" '[.items[] | "\(.path | ltrimstr("docs/issues/") | rtrimstr(".md"))=\(.class)"] | join(" ")' \
    "a=fixed b=fixed c=wontfix d=open e=unknown f=wontfix g=closed h=open i=fixed" \
    "leading words, any case: RESOLVED, Resolved —, Won’t Fix, In Progress (…), fixedness, Not Planned, Obsolete, open, \`Done\`"
  # The host's vocabulary replaces a class's list.
  lg_enable '{"status":{"open":["active"]}}'
  _lg_init ls
  ix=$(_lg_index)
  assert_json_field "$(cat "$ix")" '[.items[] | select(.path | test("/[dh][.]md$")) | .class] | join(",")' "unknown,unknown" \
    "a host open list without 'open'/'in progress': those values are unknown"
  lg_item docs/issues/j.md "status: Active"
  ix=$(_lg_index)
  assert_json_field "$(lg_ix_item "$ix" docs/issues/j.md)" '.class' "open" "…and its own word is open"
}

test_lg_index_status_classes_case() {
  echo "test: _lg_index — status classes by case-insensitive leading-word match"
  lg_fixture
  lg_enable
  lg_item docs/issues/a.md "status: RESOLVED"
  lg_item docs/issues/b.md "status: Resolved — 2026-10-01"
  lg_item docs/issues/c.md "status: Won’t Fix"
  lg_item docs/issues/d.md "status: In Progress (blocked)"
  lg_item docs/issues/e.md "status: fixedness"
  lg_item docs/issues/f.md "status: Not Planned"
  lg_item docs/issues/g.md "status: Obsolete"
  lg_item docs/issues/h.md "status: open"
  lg_item docs/issues/i.md 'status: "`Done`"'
  git add -A && git commit -qm items
  lg_in lg_t_index_status_classes
  teardown
}

# shellcheck disable=SC2031  # lg_in runs this body where lg_source set the _LG_*/_SCRATCH globals
lg_t_index_dates() {
  local ix err="$_SCRATCH/t.err" h1 h2
  h1=$(git rev-parse HEAD)
  ix=$(DOC_TOOLS_LEDGER_TRACE=1 _lg_index 2> "$err")
  assert_contains "$(cat "$err")" "dates-cold" "no cached map: one cold git log pass"
  assert_json_field "$(cat "$ix")" '[.items[] | "\(.path | ltrimstr("docs/issues/"))=\(.date)"] | join(" ")' \
    "a.md=2026-01-05 b2.md=2026-02-01 c.md=2026-03-04 t.md=2026-01-07 u.md=2026-04-05 x.md=2026-02-03" \
    "fields.date wins; else the first-add date (a rename keeps it); else mtime (uncommitted); a non-date value is ignored"
  assert_true "the date map is cached for HEAD" test -f "$_LG_CACHE/dates-$h1.tsv"
  lg_item docs/issues/n.md "status: Open"
  mkdir -p docs/archive/issues
  git mv docs/issues/c.md docs/archive/issues/c.md
  lg_commit_at 2026-05-06 "more"
  h2=$(git rev-parse HEAD)
  ix=$(DOC_TOOLS_LEDGER_TRACE=1 _lg_index 2> "$err")
  assert_contains "$(cat "$err")" "dates-extend $h1" "a new HEAD extends the cached map of its ancestor"
  assert_not_contains "$(cat "$err")" "dates-cold" "…without a cold pass"
  assert_true "the extended map is cached for the new HEAD" test -f "$_LG_CACHE/dates-$h2.tsv"
  assert_json_field "$(lg_ix_item "$ix" docs/issues/n.md)" '.date' "2026-05-06" "a new commit's item"
  assert_json_field "$(lg_ix_item "$ix" docs/archive/issues/c.md)" '[.date, .archived] | tojson' '["2026-03-04",true]' \
    "an archive move keeps the add date; archived"
  ix=$(DOC_TOOLS_LEDGER_TRACE=1 _lg_index 2> "$err")
  assert_not_contains "$(cat "$err")" "dates-" "a cached index: no date work at all"
  # A cold map gives the same dates as the extended one.
  rm -f "$_LG_CACHE"/dates-*.tsv "$_LG_CACHE"/index-*.json
  ix=$(DOC_TOOLS_LEDGER_TRACE=1 _lg_index 2> "$err")
  assert_contains "$(cat "$err")" "dates-cold" "caches removed: cold again"
  assert_json_field "$(lg_ix_item "$ix" docs/archive/issues/c.md)" '.date' "2026-03-04" "…the same date"
  assert_json_field "$(lg_ix_item "$ix" docs/issues/b2.md)" '.date' "2026-02-01" "…and the renamed file's"
}

test_lg_index_date_fallback_and_rename() {
  echo "test: _lg_index — dates: fields.date, first add (renames chained), mtime; cached map extended"
  lg_fixture
  lg_enable
  lg_item docs/issues/a.md "date: 2026-01-05" "status: Open"
  lg_item docs/issues/b.md "status: Open"
  lg_item docs/issues/t.md "date: 2026-01-07T09:30:00Z"
  lg_commit_at 2026-02-01 "one"
  lg_item docs/issues/x.md "date: soon"
  lg_commit_at 2026-02-03 "two"
  git mv docs/issues/b.md docs/issues/b2.md
  # The add date of b.md (2026-02-01) is what a rename keeps.
  lg_commit_at 2026-03-04 "three"
  lg_item docs/issues/c.md "status: Open"
  git add -A
  GIT_AUTHOR_DATE="2026-03-04T12:00:00" GIT_COMMITTER_DATE="2026-03-04T12:00:00" git commit -qm four
  lg_item docs/issues/u.md "status: Open"
  touch -t 202604051200 docs/issues/u.md
  lg_in lg_t_index_dates
  teardown
}

# shellcheck disable=SC2031  # lg_in runs this body where lg_source set the _LG_*/_SCRATCH globals
lg_t_index_docs_links() {
  local ix
  ix=$(_lg_index)
  assert_json_field "$(lg_ix_item "$ix" docs/issues/a.md)" '.docs | tojson' \
    '{"spec":["docs/adr/r.md"],"plan":["docs/plans/p.md"],"handoff":["docs/handoffs/h1.md"]}' \
    "a: a plan link with an anchor, an ADR (spec column), a handoff by key; the guide is not a column"
  assert_json_field "$(lg_ix_item "$ix" docs/issues/a.md)" '.derived | tojson' '{"status":"planned","detail":"docs/plans/p.md"}' \
    "a linked plan that is not terminal → planned"
  assert_json_field "$(lg_ix_item "$ix" "docs/issues/a b.md")" '[.docs.plan, .derived.status] | tojson' '[["docs/plans/p.md"],"planned"]' \
    "a link in <…> and one %20-encoded both reach 'a b.md'"
  assert_json_field "$(lg_ix_item "$ix" docs/issues/h.md)" '[.docs.spec, .derived] | tojson' \
    "[[\"docs/specs/s.md\"],{\"status\":\"spec'd\",\"detail\":\"docs/specs/s.md\"}]" "the key as a word in a spec → spec'd"
  assert_json_field "$(lg_ix_item "$ix" docs/issues/k.md)" '[.docs.plan, .docs.spec, .derived.status] | tojson' \
    '[["docs/plans/q.md"],[],"not started"]' "only a completed plan links it (and app-40, xapp-4, app-4x, a URL do not) → not started"
  assert_json_field "$(lg_ix_item "$ix" docs/issues/z.md)" '[.docs.plan, .docs.spec, .derived.status] | tojson' \
    "[[\"docs/plans/old.md\"],[\"docs/specs/s.md\"],\"spec'd\"]" \
    "a reference-style link; a deprecated plan is terminal → spec'd"
  assert_json_field "$(lg_ix_item "$ix" docs/issues/m.md)" '[.docs.plan, .derived.status] | tojson' '[["docs/plans/root.md"],"planned"]' \
    "a root-relative link (/docs/…) and frontmatter status: draft"
}

test_lg_index_docs_links() {
  echo "test: _lg_index — docs joins: links (relative, <…>, %20, anchors, reference-style, /root) and keys as words"
  lg_fixture
  lg_enable '{"doc_columns":{"handoff":{"globs":["docs/handoffs/*.md"]}}}'
  lg_item docs/issues/a.md "key: app-1" "status: Open"
  lg_item "docs/issues/a b.md" "key: app-2" "status: Open"
  lg_item docs/issues/h.md "key: app-3" "status: Open"
  lg_item docs/issues/k.md "key: app-4" "status: Open"
  lg_item docs/issues/z.md "key: app-5" "status: Open"
  lg_item docs/issues/m.md "key: app-6" "status: Open"
  mkdir -p docs/plans docs/specs docs/adr docs/guides docs/handoffs
  printf '# P\n\n**Status:** In progress\n\nSee [a](../issues/a.md#x), [ab](<../issues/a b.md>) and [ab2](../issues/a%%20b.md).\n' > docs/plans/p.md
  printf '# Q\n\nStatus: Completed\n\n- [k](../issues/k.md)\n' > docs/plans/q.md
  printf '# Old\n\nLinks [z](../issues/z.md).\n' > docs/plans/old.md
  printf -- '---\nstatus: draft\n---\n# Root\n\n[m](/docs/issues/m.md)\n' > docs/plans/root.md
  printf '# S\n\nFixes app-3. Not app-40, xapp-4, app-4x or https://example.com/docs/issues/k.md.\n\n[z]: ../issues/z.md\n' > docs/specs/s.md
  printf '# R\n\n[a](../issues/a.md)\n' > docs/adr/r.md
  printf '# G\n\n[a](../issues/a.md) app-4\n' > docs/guides/g.md
  printf '# H\n\nPicking up app-1.\n' > docs/handoffs/h1.md
  lg_doc_index '{"docs":{
    "docs/plans/p.md":{"doc_type":"plan"},"docs/plans/q.md":{"doc_type":"plan"},
    "docs/plans/old.md":{"doc_type":"plan","status":"deprecated"},"docs/plans/root.md":{"doc_type":"plan"},
    "docs/plans/gone.md":{"doc_type":"plan"},
    "docs/specs/s.md":{"doc_type":"spec"},"docs/adr/r.md":{"doc_type":"adr"},"docs/guides/g.md":{"doc_type":"guide"}}}'
  git add -A && git commit -qm docs
  lg_in lg_t_index_docs_links
  teardown
}

# shellcheck disable=SC2031  # lg_in runs this body where lg_source set the _LG_*/_SCRATCH globals
lg_t_index_renamed_link() {
  local ix
  ix=$(_lg_index)
  assert_json_field "$(lg_ix_item "$ix" docs/issues/new.md)" '[.docs.plan, .derived.status] | tojson' '[["docs/plans/p.md"],"planned"]' \
    "a link to the item's former path reaches it (git rename chain)"
  assert_json_field "$(lg_ix_item "$ix" docs/archive/issues/x.md)" '[.archived, .docs.spec] | tojson' '[true,["docs/specs/s.md"]]' \
    "an archive move: the old link still reaches the archived item"
  assert_json_field "$(lg_ix_item "$ix" docs/issues/y.md)" '.docs.spec | tojson' '["docs/specs/s.md"]' \
    "a path re-used by a new item: a link to it is that item's"
  assert_json_field "$(lg_ix_item "$ix" docs/issues/y2.md)" '.docs.spec | tojson' '[]' \
    "…not the item that moved away from it"
  assert_json_field "$(lg_ix_item "$ix" docs/issues/y.md)" '.date' "2026-01-03" "the re-used path: its own (later) add date"
  assert_json_field "$(lg_ix_item "$ix" docs/issues/y2.md)" '.date' "2026-01-01" "the moved item keeps the first add date"
  assert_json_field "$(lg_ix_item "$ix" docs/issues/new.md)" '.date' "2026-01-01" "a chain of renames keeps the first add date"
}

test_lg_index_renamed_link() {
  echo "test: _lg_index — links to a renamed (or archived) item's old path"
  lg_fixture
  lg_enable
  lg_item docs/issues/old.md "key: app-1" "status: Open"
  lg_item docs/issues/x.md "status: Fixed"
  lg_item docs/issues/y.md "status: Open"
  mkdir -p docs/plans docs/specs
  printf '# P\n\n[old](../issues/old.md)\n' > docs/plans/p.md
  printf '# S\n\n[x](../issues/x.md) [y](../issues/y.md)\n' > docs/specs/s.md
  lg_doc_index '{"docs":{"docs/plans/p.md":{"doc_type":"plan"},"docs/specs/s.md":{"doc_type":"spec"}}}'
  lg_commit_at 2026-01-01 one
  git mv docs/issues/old.md docs/issues/new.md
  mkdir -p docs/archive/issues
  git mv docs/issues/x.md docs/archive/issues/x.md
  git mv docs/issues/y.md docs/issues/y2.md
  lg_commit_at 2026-01-02 moves
  lg_item docs/issues/y.md "key: app-9" "status: Open" "summary: a different item at the old path"
  git mv docs/issues/new.md docs/issues/tmp.md
  lg_commit_at 2026-01-03 again
  git mv docs/issues/tmp.md docs/issues/new.md
  lg_commit_at 2026-01-04 back
  lg_in lg_t_index_renamed_link
  teardown
}

# shellcheck disable=SC2031  # lg_in runs this body where lg_source set the _LG_*/_SCRATCH globals
lg_t_index_no_doc_index() {
  local ix
  ix=$(_lg_index)
  assert_json_field "$(lg_ix_item "$ix" docs/issues/a.md)" '[.docs, .derived.status] | tojson' \
    '[{"spec":[],"plan":[],"handoff":[]},"not started"]' "no doc-index: empty docs, the index still builds"
}

test_lg_index_absent_doc_index_ok() {
  echo "test: _lg_index — no docs/.doc-index.json is fine"
  lg_fixture
  lg_enable
  lg_item docs/issues/a.md "key: app-1" "status: Open"
  git add -A && git commit -qm items
  lg_in lg_t_index_no_doc_index
  teardown
}

# shellcheck disable=SC2031  # lg_in runs this body where lg_source set the _LG_*/_SCRATCH globals
lg_t_index_unborn() {
  local ix
  ix=$(_lg_index)
  assert_json_field "$(cat "$ix")" '[.built.head, (.items | length), .items[0].date] | tojson' '[null,1,"2026-04-05"]' \
    "no commit yet: head null, the untracked item dated by its mtime"
}

test_lg_index_unborn_head() {
  echo "test: _lg_index — a repository with no commit yet"
  lg_fixture
  rm -rf .git
  git init -q
  printf 'home/\nxdg/\n' >> .git/info/exclude
  lg_enable
  lg_item docs/issues/a.md "key: app-1"
  touch -t 202604051200 docs/issues/a.md
  lg_in lg_t_index_unborn
  teardown
}

# shellcheck disable=SC2031  # lg_in runs this body where lg_source set the _LG_*/_SCRATCH globals
lg_t_index_bad_doc_index() {
  lg_rc _lg_index
  assert_eq "2" "$LG_RC" "invalid JSON in the doc-index: rc 2"
  lg_doc_index '{"docs":[]}'
  lg_rc _lg_index
  assert_eq "2" "$LG_RC" "docs not an object: rc 2"
  lg_doc_index '{"docs":{}}'
  printf '[' > docs/ledger/legacy.json
  lg_rc _lg_index
  assert_eq "2" "$LG_RC" "an unreadable legacy.json: rc 2"
  rm -f docs/ledger/legacy.json
  printf '{"ledgers":{}}' > docs/ledger/ledgers.json
  lg_rc _lg_index
  assert_eq "2" "$LG_RC" "a registry whose ledgers is not a list: rc 2"
}

test_lg_index_invalid_doc_index_rc2() {
  echo "test: _lg_index — an invalid doc-index, legacy map or registry is rc 2"
  lg_fixture
  lg_enable
  lg_item docs/issues/a.md "key: app-1"
  git add -A && git commit -qm items
  printf '{"docs": [' > docs/.doc-index.json
  lg_in lg_t_index_bad_doc_index
  teardown
}

# lg_ix_hash <file>: the file's content hash.
lg_ix_hash() {
  hash_file "$1"
}

# shellcheck disable=SC2031  # lg_in runs this body where lg_source set the _LG_*/_SCRATCH globals
lg_t_index_cache() {
  local p0 p1 h0 err="$_SCRATCH/t.err" names="" p n
  p0=$(_lg_index)
  h0=$(lg_ix_hash "$p0")
  p1=$(DOC_TOOLS_LEDGER_TRACE=1 _lg_index 2> "$err")
  assert_eq "$p0" "$p1" "no change: the same cache file"
  assert_eq "$h0" "$(lg_ix_hash "$p1")" "…with the same content"
  assert_contains "$(cat "$err")" "index-hit" "…served from the cache"
  assert_not_contains "$(cat "$err")" "parse-miss" "…without parsing"
  names="$p0"
  lg_registry '{"schema":"ledger-registry/1","ledgers":[{"id":"app","title":"App 2","kind":"service","status":"active"}]}'
  p=$(_lg_index); names="$names $p"
  lg_enable '{"views":{"recent_days":7}}'
  _lg_init ls
  p=$(_lg_index); names="$names $p"
  printf '{"app#1":{"key":"app-1"}}\n' > docs/ledger/legacy.json
  p=$(_lg_index); names="$names $p"
  assert_json_field "$(cat "$p")" '.legacy | tojson' '{"app#1":{"key":"app-1"}}' "legacy: legacy.json's map"
  lg_doc_index '{"docs":{"docs/plans/p.md":{"doc_type":"plan","last_verified":null}}}'
  p=$(_lg_index); names="$names $p"
  printf 'more\n' >> docs/issues/a.md
  p=$(DOC_TOOLS_LEDGER_TRACE=1 _lg_index 2> "$err"); names="$names $p"
  assert_eq "parse-miss docs/issues/a.md" "$(grep '^parse-miss' "$err")" "an item edit: only that item is parsed again"
  printf 'An uncommitted line.\n' >> docs/plans/p.md
  p=$(_lg_index); names="$names $p"
  n=$(printf '%s\n' $names | sort -u | wc -l | tr -d ' ')
  assert_eq "7" "$n" "registry, config, legacy.json, doc-index, an item, an uncommitted plan edit: each a new cache file"
  git checkout -q -- docs/plans/p.md
  p1=$(DOC_TOOLS_LEDGER_TRACE=1 _lg_index 2> "$err")
  assert_contains "$(cat "$err")" "index-hit" "the plan edit undone: the earlier cache file again"
  # shellcheck disable=SC2012  # cache names are hex
  assert_eq "7" "$(ls "$_LG_CACHE"/index-*.json | wc -l | tr -d ' ')" \
    "all 7 were written in the last 10 minutes: none pruned (the keep-3 rule: test_lg_index_hit_survives_prune)"
  git add docs/plans/p.md docs/issues/a.md
  p=$(_lg_index)
  assert_eq "$p1" "$p" "staging the same bytes does not change the worktree index"
}

test_lg_index_cache_invalidation() {
  echo "test: _lg_index — the cache key covers registry, config, legacy, doc-index, items, dirty docs"
  lg_fixture
  lg_enable
  lg_registry '{"schema":"ledger-registry/1","ledgers":[{"id":"app","title":"App","kind":"service","status":"active"}]}'
  lg_item docs/issues/a.md "key: app-1" "status: Open"
  lg_item docs/issues/b.md "key: app-2" "status: Open"
  mkdir -p docs/plans
  printf '# P\n\n[a](../issues/a.md)\n' > docs/plans/p.md
  lg_doc_index '{"docs":{"docs/plans/p.md":{"doc_type":"plan"}}}'
  git add -A && git commit -qm items
  lg_in lg_t_index_cache
  teardown
}

# shellcheck disable=SC2031  # lg_in runs this body where lg_source set the _LG_*/_SCRATCH globals
lg_t_index_foreign() {
  local p q
  p=$(_lg_index)
  printf '{"schema":"ledger-index/0","items":[]}\n' > "$p"
  q=$(_lg_index)
  assert_eq "$p" "$q" "the same cache name"
  assert_json_field "$(cat "$q")" '[.schema, (.items | length)] | tojson' '["ledger-index/1",1]' "a foreign schema is ignored and rebuilt"
  printf '{"schema":"ledger-index/1","built":' > "$p"
  q=$(_lg_index)
  assert_json_field "$(cat "$q")" '.items | length' "1" "a truncated file is rebuilt"
  printf 'garbage' > "$p"
  q=$(_lg_index)
  assert_json_field "$(cat "$q")" '.schema' "ledger-index/1" "garbage is rebuilt"
}

test_lg_index_foreign_schema_ignored() {
  echo "test: _lg_index — a cache file of another schema (or broken) is ignored"
  lg_fixture
  lg_enable
  lg_item docs/issues/a.md "key: app-1"
  git add -A && git commit -qm items
  lg_in lg_t_index_foreign
  teardown
}

# shellcheck disable=SC2031  # lg_in runs this body where lg_source set the _LG_*/_SCRATCH globals
lg_t_index_staged() {
  local s w r
  s=$(_lg_index --staged)
  assert_json_field "$(lg_ix_item "$s" docs/issues/a.md)" '[.key, .class] | tojson' '["x-2","fixed"]' "--staged: the staged blob's values"
  assert_json_field "$(cat "$s")" '[.built.mode, (.items | map(.path) | join("|"))] | tojson' '["staged","docs/issues/a.md|docs/issues/n.md"]' \
    "--staged: a staged file deleted from the work tree is an item"
  assert_json_field "$(cat "$s")" '.ledgers | map(.id) | join(",")' "x" "--staged: the staged registry"
  w=$(_lg_index)
  assert_json_field "$(lg_ix_item "$w" docs/issues/a.md)" '.key' "x-3" "worktree: the working copy"
  assert_json_field "$(cat "$w")" '[(.items | map(.path) | join("|")), (.ledgers | length)] | tojson' '["docs/issues/a.md",0]' \
    "worktree: no n.md; the registry deleted from the work tree"
  r=$(_lg_index --rev HEAD)
  assert_json_field "$(lg_ix_item "$r" docs/issues/a.md)" '.key' "x-1" "--rev HEAD: the commit"
  assert_json_field "$(cat "$r")" '[.built.mode, .built.rev] | join("|")' "rev|$(git rev-parse HEAD)" "--rev: built.mode and built.rev"
  assert_eq "3" "$(printf '%s\n' "$s" "$w" "$r" | sort -u | wc -l | tr -d ' ')" "three sources, three cache files"
  lg_rc _lg_index --rev no-such-rev
  assert_eq "2" "$LG_RC" "--rev of an unknown revision: rc 2"
  lg_rc _lg_index --rev --all
  assert_eq "2" "$LG_RC" "--rev of an option-like value: rc 2"
  lg_rc _lg_index --bogus
  assert_eq "2" "$LG_RC" "an unknown argument: rc 2 (internal misuse)"
}

test_lg_index_staged_mode() {
  echo "test: _lg_index --staged / --rev — staged blob values win"
  lg_fixture
  lg_enable
  lg_registry '{"schema":"ledger-registry/1","ledgers":[{"id":"x","title":"X","kind":"service","status":"active"}]}'
  lg_item docs/issues/a.md "key: x-1" "status: Open"
  git add -A && git commit -qm items
  lg_item docs/issues/a.md "key: x-2" "status: Fixed"
  lg_item docs/issues/n.md "key: x-9"
  git add -A
  rm docs/issues/n.md docs/ledger/ledgers.json
  lg_item docs/issues/a.md "key: x-3" "status: Open"
  lg_in lg_t_index_staged
  teardown
}

# shellcheck disable=SC2031  # lg_in runs this body where lg_source set the _LG_*/_SCRATCH globals
lg_t_index_prune() {
  local ix entry kept
  ix=$(_lg_index)
  _lg_parse_prep
  mkdir "$_LG_PARSE_DIR/.new.stale" "$_LG_PARSE_DIR/.new.fresh"
  touch -t 202001010000 "$_LG_PARSE_DIR/.new.stale"
  printf '{"fm":{}}' > "$_LG_PARSE_DIR/c-0000000000000000000000000000000000000000000000000000000000000000.json"
  touch -t 202001010000 "$_LG_PARSE_DIR/c-0000000000000000000000000000000000000000000000000000000000000000.json"
  for entry in "$_LG_PARSE_DIR"/c-*.json; do touch -t 202001010000 "$entry"; done
  kept=$(cd "$_LG_PARSE_DIR" && ls c-*.json | grep -v '^c-0000' | head -n 1)
  mkdir -p "$_LG_CACHE/parse/0123456789abcdef"
  touch -t 202001010000 "$_LG_CACHE/parse/0123456789abcdef"
  rm -f "$_LG_CACHE/prune.stamp"
  printf 'x\n' >> docs/issues/b.md
  ix=$(_lg_index)
  assert_true "a stale .new.* temp dir is swept" test ! -e "$_LG_PARSE_DIR/.new.stale"
  assert_true "a fresh one (a parse in flight) is kept" test -d "$_LG_PARSE_DIR/.new.fresh"
  assert_true "an old entry no kept index references is pruned" \
    test ! -e "$_LG_PARSE_DIR/c-0000000000000000000000000000000000000000000000000000000000000000.json"
  assert_true "an old entry the index references is kept" test -f "$_LG_PARSE_DIR/$kept"
  assert_true "an old parser's cache dir is removed" test ! -e "$_LG_CACHE/parse/0123456789abcdef"
  assert_true "the prune stamp is written" test -f "$_LG_CACHE/prune.stamp"
  assert_json_field "$(lg_ix_item "$ix" docs/issues/a.md)" '.key' "app-1" "the index is intact"
}

test_lg_index_cache_prune() {
  echo "test: _lg_index — parse cache pruning (stale temp dirs, unreferenced old entries, old parser dirs)"
  lg_fixture
  lg_enable
  lg_item docs/issues/a.md "key: app-1"
  lg_item docs/issues/b.md "key: app-2"
  printf '%s\n' '---' 'key: app-3' '---' > docs/issues/c.md
  git add -A && git commit -qm items
  lg_in lg_t_index_prune
  teardown
}

# shellcheck disable=SC2031  # lg_in runs this body where lg_source set the _LG_*/_SCRATCH globals
lg_t_index_odd_worktree() {
  local ix
  ix=$(_lg_index)
  assert_json_field "$(cat "$ix")" '.items | map(.path) | join("|")' "docs/issues/a.md|docs/issues/link.md|docs/issues/new.md" \
    "worktree: a deleted tracked item, a submodule and a link to a directory are not items; a link to a file and an untracked file are"
  assert_json_field "$(lg_ix_item "$ix" docs/issues/link.md)" '.key' "app-1" "the link to a file parses through it"
}

test_lg_index_odd_worktree_entries() {
  echo "test: _lg_index — worktree items skip deleted files, submodules and links to directories"
  lg_fixture
  lg_enable
  lg_item docs/issues/a.md "key: app-1"
  lg_item docs/issues/gone.md "key: app-2"
  ln -s a.md docs/issues/link.md
  mkdir -p docs/issues/dir.md
  printf 'x\n' > docs/issues/dir.md/inner
  ln -s dir.md docs/issues/dlink.md
  git add -A && git commit -qm items
  git update-index --add --cacheinfo "160000,$(git rev-parse HEAD),docs/issues/sub.md"
  git commit -qm gitlink
  mkdir -p docs/issues/sub.md
  rm docs/issues/gone.md
  lg_item docs/issues/new.md "key: app-3"
  lg_in lg_t_index_odd_worktree
  teardown
}

# shellcheck disable=SC2031  # lg_in runs this body where lg_source set the _LG_*/_SCRATCH globals
lg_t_parse_hash_map() {
  local paths="$_SCRATCH/t.paths" out="$_SCRATCH/t.jsonl" err="$_SCRATCH/t.err"
  lg_nul_list "$paths" docs/issues/a.md docs/issues/b.md docs/issues/u.md
  DOC_TOOLS_LEDGER_TRACE=2 _lg_parse_worktree "$paths" "$out" 2> "$err"
  assert_eq "3" "$(grep -c '^content-hash ' "$err")" "first run: every file is hashed"
  printf 'x\n' >> docs/issues/b.md
  DOC_TOOLS_LEDGER_TRACE=2 _lg_parse_worktree "$paths" "$out" 2> "$err"
  assert_eq "content-hash docs/issues/b.md|content-hash docs/issues/u.md" "$(grep '^content-hash ' "$err" | tr '\n' '|' | sed 's/|$//')" \
    "second run: clean tracked files are not hashed (their blob id maps to the hash); modified and untracked are"
  assert_json_field "$(jq -c 'select(.path == "docs/issues/a.md")' "$out")" '.blob' "sha256:$(hash_file docs/issues/a.md)" \
    "a clean file's .blob is still its content hash"
  assert_json_field "$(jq -c 'select(.path == "docs/issues/b.md")' "$out")" '.blob' "sha256:$(hash_file docs/issues/b.md)" \
    "…and a modified one's"
}

test_lg_parse_hash_map() {
  echo "test: _lg_parse_worktree (DOC_TOOLS_LEDGER_TRACE=2) hashes only modified/untracked files once their blob id is known"
  lg_fixture
  lg_enable
  lg_item docs/issues/a.md "key: app-1"
  lg_item docs/issues/b.md "key: app-2"
  git add -A && git commit -qm items
  lg_item docs/issues/u.md "key: app-3"
  lg_in lg_t_parse_hash_map
  teardown
}

# --- Task 4 fix round 1 -------------------------------------------------------

# shellcheck disable=SC2031  # lg_in runs this body where lg_source set the _LG_*/_SCRATCH globals
lg_t_index_staged_reuse() {
  local ix err="$_SCRATCH/t.err"
  _lg_parse_prep
  ix=$(DOC_TOOLS_LEDGER_TRACE=1 _lg_index 2> "$err")
  assert_eq "2" "$(grep -c '^parse-miss' "$err")" "the worktree index parses both items"
  ix=$(DOC_TOOLS_LEDGER_TRACE=1 _lg_index --staged 2> "$err")
  assert_contains "$(cat "$err")" "index-build" "--staged builds its own index"
  assert_eq "0" "$(grep -c '^parse-miss' "$err")" "…from the worktree parse entries (blob id -> sha256 map): nothing parsed"
  assert_json_field "$(lg_ix_item "$ix" docs/issues/b.md)" '[.key, .class] | tojson' '["app-2","open"]' "…with the right values"
  assert_eq "c-|c-|" "$(cut -c 1-2 "${ix%.json}.refs" | tr '\n' '|')" \
    "its .refs names the reused c-<sha256> entries it read (pruning spares those), not b-<oid>"
  assert_true "…entries that exist" test -f "$_LG_PARSE_DIR/$(head -n 1 "${ix%.json}.refs")"
  ix=$(DOC_TOOLS_LEDGER_TRACE=1 _lg_index --rev HEAD 2> "$err")
  assert_eq "0" "$(grep -c '^parse-miss' "$err")" "--rev HEAD: nothing parsed either"
  assert_json_field "$(lg_ix_item "$ix" docs/issues/a.md)" '.key' "app-1" "…with the right values"
}

test_lg_index_staged_reuses_worktree_parse() {
  echo "test: _lg_index --staged / --rev reuse the worktree's parse entries"
  lg_fixture
  lg_enable
  lg_item docs/issues/a.md "key: app-1" "status: Open"
  lg_item docs/issues/b.md "key: app-2" "status: Open"
  git add -A && git commit -qm items
  lg_in lg_t_index_staged_reuse
  teardown
}

# shellcheck disable=SC2031  # lg_in runs this body where lg_source set the _LG_*/_SCRATCH globals
lg_t_index_hit_survives() {
  local a b c d e err="$_SCRATCH/t.err" orig="$_SCRATCH/a.orig"
  cp docs/issues/a.md "$orig"
  a=$(_lg_index)
  printf 'v1\n' >> docs/issues/a.md; b=$(_lg_index)
  printf 'v2\n' >> docs/issues/a.md; c=$(_lg_index)
  printf 'v3\n' >> docs/issues/a.md; d=$(_lg_index)
  # shellcheck disable=SC2012  # cache names are hex
  assert_eq "4" "$(ls "$_LG_CACHE"/index-*.json | wc -l | tr -d ' ')" "four indexes written in the last 10 minutes: none pruned"
  touch -t 202001010001 "$a" "${a%.json}.refs"
  touch -t 202001010002 "$b" "${b%.json}.refs"
  touch -t 202001010003 "$c" "${c%.json}.refs"
  touch -t 202001010004 "$d" "${d%.json}.refs"
  cp "$orig" docs/issues/a.md
  e=$(DOC_TOOLS_LEDGER_TRACE=1 _lg_index 2> "$err")
  assert_eq "$a" "$e" "the first state again: index A"
  assert_contains "$(cat "$err")" "index-hit" "…a hit"
  printf 'v4\n' >> docs/issues/a.md
  e=$(_lg_index)
  assert_true "A, used last, survives the prune" test -f "$a"
  assert_true "…with its .refs" test -f "${a%.json}.refs"
  assert_true "the new index E is kept" test -f "$e"
  assert_true "D (the newest of the old) is kept" test -f "$d"
  assert_true "B is pruned" test ! -e "$b"
  assert_true "C is pruned" test ! -e "$c"
  assert_true "…with its .refs" test ! -e "${c%.json}.refs"
}

test_lg_index_hit_survives_prune() {
  echo "test: _lg_index — a cache hit marks the index newest; recent files are never pruned"
  lg_fixture
  lg_enable
  lg_item docs/issues/a.md "key: app-1"
  git add -A && git commit -qm items
  lg_in lg_t_index_hit_survives
  teardown
}

# shellcheck disable=SC2031  # lg_in runs this body where lg_source set the _LG_*/_SCRATCH globals
lg_t_index_cross_dir() {
  local ix
  ix=$(_lg_index)
  assert_json_field "$(lg_ix_item "$ix" docs/issues/x.md)" '[.date, .docs.plan] | tojson' '["2026-02-02",[]]' \
    "known deviation: an item moved in from outside the item dirs is dated by the move; links to its old path are not followed"
}

test_lg_index_cross_dir_move_deviation() {
  echo "test: _lg_index — a move into the item dirs from elsewhere (pinned deviation: pathspec-limited log)"
  lg_fixture
  lg_enable
  mkdir -p docs/notes docs/plans
  lg_item docs/notes/x.md "key: app-1" "status: Open"
  printf '# P\n\n[x](../notes/x.md)\n' > docs/plans/p.md
  lg_doc_index '{"docs":{"docs/plans/p.md":{"doc_type":"plan"}}}'
  lg_commit_at 2026-01-01 one
  git mv docs/notes/x.md docs/issues/x.md
  lg_commit_at 2026-02-02 moved
  lg_in lg_t_index_cross_dir
  teardown
}

test_lg_parse_parallel_bin_bash() {
  echo "test: parallel frontmatter parsing (DOC_TOOLS_LEDGER_PAR_MIN) under /bin/bash: order kept, a failing awk is rc 2"
  lg_fixture
  lg_enable
  local i n cpus fake="$TEST_DIR/fakebin" realawk rc out="$TEST_DIR/par.jsonl" log="$TEST_DIR/awk.log" want got
  for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
    lg_item "docs/issues/p$i.md" "key: app-$((10#$i))"
  done
  git add -A && git commit -qm items
  realawk=$(command -v awk)
  mkdir -p "$fake"
  # A fake awk: logs each frontmatter (mode=files) process, fails one when asked.
  cat > "$fake/awk" <<EOF
#!/bin/sh
files=0; fail=0
for a in "\$@"; do
  case "\$a" in
    mode=files) files=1 ;;
    *p07.md) [ -n "\${LG_FAIL_AWK:-}" ] && fail=1 ;;
  esac
done
[ "\$files" = 1 ] && echo files >> "$log"
[ "\$fail" = 1 ] && exit 7
exec "$realawk" "\$@"
EOF
  chmod +x "$fake/awk"
  cat > "$TEST_DIR/drive.sh" <<EOF
DOC_TOOLS_SOURCE_ONLY=1
. "$REPO_DIR/scripts/doc-tools.sh"
unset DOC_TOOLS_SOURCE_ONLY
. "$REPO_DIR/scripts/ledger/lib.sh"
_SCRATCH=\$(mktemp -d "$TEST_DIR/drive.XXXXXX")
_LG_ACTIVE=1
_LG_FORMAT=text
_lg_init ls
_lg_item_paths worktree "\$_SCRATCH/paths"
tr '\\000' '\\n' < "\$_SCRATCH/paths" > "$TEST_DIR/paths.txt"
_lg_parse_worktree "\$_SCRATCH/paths" "\$1"
EOF
  rc=0
  DOC_TOOLS_LEDGER_PAR_MIN=2 PATH="$fake:$PATH" /bin/bash "$TEST_DIR/drive.sh" "$out" > /dev/null 2>&1 </dev/null || rc=$?
  assert_eq "0" "$rc" "/bin/bash, 12 files, threshold 2: the parse succeeds"
  n=$(grep -c files "$log" 2>/dev/null || true)
  cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
  if [ "${cpus:-1}" -ge 2 ] 2>/dev/null; then
    assert_true "…in more than one awk process (got $n)" test "${n:-0}" -gt 1
  else
    record_skip "parallel parse: one CPU here (getconf _NPROCESSORS_ONLN = ${cpus:-?}), so one awk process"
  fi
  want=$(tr '\n' '|' < "$TEST_DIR/paths.txt")
  got=$(jq -r .path "$out" | tr '\n' '|')
  assert_eq "$want" "$got" "…records in the input order"
  assert_json_field "$(jq -c 'select(.path == "docs/issues/p07.md")' "$out")" '.fm.key' "app-7" "…with the right values"
  rm -rf .git/doc-superpowers
  rc=0
  LG_FAIL_AWK=1 DOC_TOOLS_LEDGER_PAR_MIN=2 PATH="$fake:$PATH" /bin/bash "$TEST_DIR/drive.sh" "$out" > /dev/null 2>&1 </dev/null || rc=$?
  assert_eq "2" "$rc" "one failing parallel awk process: rc 2"
  teardown
}

# --- Task 4 fix round 2 -------------------------------------------------------

# shellcheck disable=SC2031  # lg_in runs this body where lg_source set the _LG_*/_SCRATCH globals
lg_t_index_dates_merge() {
  local ix err="$_SCRATCH/t.err" ext cold
  git checkout -q main
  ix=$(DOC_TOOLS_LEDGER_TRACE=1 _lg_index 2> "$err")
  assert_json_field "$(lg_ix_item "$ix" docs/issues/x.md)" '.date' "2026-01-10" "main alone: main's add date"
  # Both sides added x.md with different bytes: an add/add conflict, resolved
  # to bytes neither side had, so the log walks both parents (identical
  # bytes would make the merge TREESAME to main and git would prune feat).
  git merge -q --no-edit feat >/dev/null 2>&1 || true
  lg_item docs/issues/x.md "key: app-1" "status: Open" "summary: merged"
  git add -A
  GIT_AUTHOR_DATE="2026-01-11T12:00:00" GIT_COMMITTER_DATE="2026-01-11T12:00:00" git commit -q --no-edit
  ix=$(DOC_TOOLS_LEDGER_TRACE=1 _lg_index 2> "$err")
  assert_contains "$(cat "$err")" "dates-extend" "after the merge: the cached map of main is extended"
  ext=$(lg_ix_item "$ix" docs/issues/x.md | jq -r .date)
  rm -f "$_LG_CACHE"/dates-*.tsv "$_LG_CACHE"/index-*.json "$_LG_CACHE"/index-*.refs
  ix=$(DOC_TOOLS_LEDGER_TRACE=1 _lg_index 2> "$err")
  assert_contains "$(cat "$err")" "dates-cold" "caches removed: a cold map"
  cold=$(lg_ix_item "$ix" docs/issues/x.md | jq -r .date)
  assert_eq "$cold" "$ext" "cold and extended maps agree across the merge"
  assert_eq "2026-01-05" "$ext" "…on the earliest add (the merged side branch's)"
}

test_lg_index_dates_merge_cold_vs_extended() {
  echo "test: _lg_index — dates agree cold vs extended when a side branch adding the same path is merged"
  lg_fixture
  lg_enable
  lg_commit_at 2026-01-01 base
  git checkout -q -b feat
  lg_item docs/issues/x.md "key: app-1" "status: Open" "summary: from feat"
  lg_commit_at 2026-01-05 feat-adds-x
  git checkout -q main
  lg_item docs/issues/x.md "key: app-1" "status: Open" "summary: from main"
  lg_commit_at 2026-01-10 main-adds-x
  lg_in lg_t_index_dates_merge
  teardown
}

# --- Task 4 fix round 3 -------------------------------------------------------

# shellcheck disable=SC2031  # lg_in runs this body where lg_source set the _LG_*/_SCRATCH globals
lg_t_index_dates_treesame() {
  local ix err="$_SCRATCH/t.err" ext cold
  git checkout -q feat
  ix=$(DOC_TOOLS_LEDGER_TRACE=1 _lg_index 2> "$err")
  assert_json_field "$(lg_ix_item "$ix" docs/issues/x.md)" '.date' "2026-01-05" "on feat: feat's add date (the map cached for feat)"
  git checkout -q main
  lg_item docs/issues/x.md "key: app-1" "status: Open"
  lg_commit_at 2026-01-10 main-adds-x-identical
  # The same bytes on both sides: the merge is TREESAME to main for x.md.
  GIT_AUTHOR_DATE="2026-01-11T12:00:00" GIT_COMMITTER_DATE="2026-01-11T12:00:00" git merge -q --no-edit feat
  ix=$(DOC_TOOLS_LEDGER_TRACE=1 _lg_index 2> "$err")
  assert_contains "$(cat "$err")" "dates-extend $(git rev-parse feat)" "after the merge: feat's cached map is extended"
  ext=$(lg_ix_item "$ix" docs/issues/x.md | jq -r .date)
  rm -f "$_LG_CACHE"/dates-*.tsv "$_LG_CACHE"/index-*.json "$_LG_CACHE"/index-*.refs
  ix=$(DOC_TOOLS_LEDGER_TRACE=1 _lg_index 2> "$err")
  assert_contains "$(cat "$err")" "dates-cold" "caches removed: a cold map"
  cold=$(lg_ix_item "$ix" docs/issues/x.md | jq -r .date)
  assert_eq "$ext" "$cold" "a TREESAME merge: the cold map (--full-history) agrees with the one extended from feat"
  assert_eq "2026-01-05" "$cold" "…on feat's earlier add"
}

test_lg_index_dates_treesame_merge() {
  echo "test: _lg_index — dates agree cold vs extended-from-the-side-branch across a TREESAME merge"
  lg_fixture
  lg_enable
  lg_commit_at 2026-01-01 base
  git checkout -q -b feat
  lg_item docs/issues/x.md "key: app-1" "status: Open"
  lg_commit_at 2026-01-05 feat-adds-x
  lg_in lg_t_index_dates_treesame
  teardown
}

# --- Task 5: show, ls, find, bench --------------------------------------------

# The number of lines in $1 ("" → 0).
lg_lines() {
  if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | wc -l | tr -d ' '; fi
}

# Column <n> (whitespace-split) of each line of $1, "|"-joined.
lg_col() {
  printf '%s\n' "$1" | awk -v n="$2" '{ printf "%s%s", (NR > 1 ? "|" : ""), $n }'
}

LG_REG_APP_CORE='{"schema":"ledger-registry/1","ledgers":[
  {"id":"app","title":"App","kind":"service","status":"active"},
  {"id":"core","title":"Core","kind":"platform","status":"active"}]}'

test_lg_show_limits() {
  echo "test: ledger show — header line, derived display, lists capped, ≤ 25 lines; path or key; unknown → rc 1"
  lg_fixture
  lg_enable
  lg_registry "$LG_REG_APP_CORE"
  local i specs="" plans="" out first
  lg_item docs/issues/a.md "key: app-1" "ledger: app" "status: Open" "severity: P1" \
    "summary: Totals are wrong when the cart is edited" "changes: [field:order.total]" \
    "consumes: [endpoint:createOrder, flag:new_checkout]" \
    "relates: [root-cause:app-2, sibling:app-3]" "aliases: [old-1, old-2, old-3, old-4, old-5]" \
    "related-files: [src/a.js, src/b.js, src/c.js, src/d.js, src/e.js, src/f.js]"
  printf '\nBody text.\n' >> docs/issues/a.md
  lg_item docs/issues/b.md "key: app-2" "ledger: app" "status: Fixed" "priority: P2" "owed: deploy" \
    "summary: Order ids collide under load"
  lg_item docs/issues/c.md "key: app-3" "ledger: app" "status: Closed" "severity: P2" "superseded_by: app-1" \
    "summary: Old totals bug"
  printf '\n## Resolution\n\nReplaced by app-1.\nMore text.\n' >> docs/issues/c.md
  lg_item docs/issues/k.md "ledger: unassigned" "status: Open" "summary: Home not decided yet"
  mkdir -p docs/specs docs/plans
  for i in 1 2 3 4 5 6; do
    printf '# S%s\n\nFixes app-1.\n' "$i" > "docs/specs/s$i.md"
    specs="$specs\"docs/specs/s$i.md\":{\"doc_type\":\"spec\"},"
    printf '# P%s\n\nWorks on app-1.\n' "$i" > "docs/plans/p$i.md"
    plans="$plans\"docs/plans/p$i.md\":{\"doc_type\":\"plan\"},"
  done
  lg_doc_index "{\"docs\":{${specs}${plans%,}}}"
  git add -A && git commit -qm items

  lg show app-1
  assert_eq "0" "$LG_RC" "show app-1 exits 0"
  assert_true "at most 25 lines ($(lg_lines "$LG_OUT"))" test "$(lg_lines "$LG_OUT")" -le 25
  first=$(printf '%s\n' "$LG_OUT" | head -n 1)
  assert_eq "app-1  app  P1  planned" "$first" "line 1: key, ledger, severity, derived status"
  assert_eq "Totals are wrong when the cart is edited" "$(printf '%s\n' "$LG_OUT" | sed -n 2p)" "line 2: the summary"
  assert_contains "$LG_OUT" "spec: docs/specs/s1.md, docs/specs/s2.md, docs/specs/s3.md +3 more" "spec list capped at 3, with the rest counted"
  assert_contains "$LG_OUT" "plan: docs/plans/p1.md, docs/plans/p2.md, docs/plans/p3.md +3 more" "plan list capped"
  assert_contains "$LG_OUT" "handoff: —" "an empty column shows —"
  assert_contains "$LG_OUT" "changes: field:order.total" "changes"
  assert_contains "$LG_OUT" "consumes: endpoint:createOrder, flag:new_checkout" "consumes"
  assert_contains "$LG_OUT" "relates: root-cause:app-2, sibling:app-3" "relates as kind:key"
  assert_contains "$LG_OUT" "aliases: old-1, old-2, old-3 +2 more" "aliases capped"
  assert_contains "$LG_OUT" "files: src/a.js, src/b.js, src/c.js +3 more" "paths capped"
  assert_contains "$LG_OUT" "path: docs/issues/a.md" "the path"
  assert_not_contains "$LG_OUT" "resolution:" "an open item has no resolution line"
  out=$LG_OUT
  lg show APP-1
  assert_eq "$out" "$LG_OUT" "a key matches case-insensitively"
  lg show docs/issues/a.md
  assert_eq "$out" "$LG_OUT" "the path gives the same item"
  lg show ./docs/issues/a.md
  assert_eq "$out" "$LG_OUT" "…and ./path"

  lg show app-3
  assert_eq "app-3  app  P2  superseded → app-1" "$(printf '%s\n' "$LG_OUT" | head -n 1)" "superseded → <key>"
  assert_contains "$LG_OUT" "resolution: Replaced by app-1." "a terminal item: the first resolution line"
  assert_not_contains "$LG_OUT" "More text." "…only the first line"
  lg show app-2
  assert_eq "app-2  app  P2  merged · owed: deploy" "$(printf '%s\n' "$LG_OUT" | head -n 1)" "merged · owed: <owed>"
  assert_contains "$LG_OUT" "resolution: (none)" "a terminal item without a resolution says so"
  lg show docs/issues/k.md
  assert_eq "0" "$LG_RC" "a keyless item by path"
  assert_eq "docs/issues/k.md  unassigned  —  not started" "$(printf '%s\n' "$LG_OUT" | head -n 1)" \
    "no key: the path leads; no severity: —"

  lg show app-99
  assert_eq "1" "$LG_RC" "an unknown ref exits 1"
  assert_eq "1" "$(lg_lines "$LG_OUT")" "…with one line"
  assert_contains "$LG_OUT" "app-99" "…naming the ref"
  lg show app-99 --format json
  assert_eq "1" "$LG_RC" "JSON: an unknown ref exits 1"
  assert_eq "1" "$(json_count "$LG_OUT")" "JSON: one object"
  assert_json_field "$LG_OUT" '[.verb, .exit, .item] | tojson' '["ledger show",1,null]' "JSON: item null"
  lg show app-1 --format json
  assert_eq "1" "$(json_count "$LG_OUT")" "JSON: one object"
  assert_json_field "$LG_OUT" '[.exit, .item.key, .item.path, .item.derived.status] | tojson' \
    '[0,"app-1","docs/issues/a.md","planned"]' "JSON: the index item"
  assert_json_field "$LG_OUT" '.display' "planned" "JSON: the derived status as displayed"
  lg show
  assert_eq "3" "$LG_RC" "no ref: usage (3)"
  lg show app-1 app-2
  assert_eq "3" "$LG_RC" "two refs: usage (3)"

  # An item whose every list is long and whose fields are odd still fits.
  lg_item docs/issues/z.md "key: app-9" "ledger: app" "status: won't fix" "severity: P3" \
    "summary: Line one" "changes: [c:1, c:2, c:3, c:4, c:5, c:6, c:7, c:8]" \
    "consumes: [d:1, d:2, d:3, d:4, d:5, d:6, d:7, d:8]" "relates: [sibling:a-1, sibling:a-2, sibling:a-3, sibling:a-4, sibling:a-5]" \
    "owed: a device pass" "nested:" "  a: b"
  lg show app-9
  assert_eq "0" "$LG_RC" "show app-9 exits 0"
  assert_true "a crowded item: at most 25 lines ($(lg_lines "$LG_OUT"))" test "$(lg_lines "$LG_OUT")" -le 25
  assert_eq "app-9  app  P3  won't fix" "$(printf '%s\n' "$LG_OUT" | head -n 1)" "won't fix"
  assert_contains "$LG_OUT" "changes: c:1, c:2, c:3 +5 more" "changes capped"
  assert_contains "$LG_OUT" "owed: a device pass" "owed"
  assert_contains "$LG_OUT" "frontmatter:" "a frontmatter error is shown"
  teardown
}

test_lg_ls_filters_and_order() {
  echo "test: ledger ls — severity order then date; --ledger, --sev, --open, --status, --cluster; JSON items"
  lg_fixture
  lg_enable
  lg_registry "$LG_REG_APP_CORE"
  lg_item docs/issues/a.md "key: app-1" "ledger: app" "status: Open" "severity: P2" "date: 2026-01-05" "summary: Alpha"
  lg_item docs/issues/b.md "key: app-2" "ledger: app" "status: Open" "severity: P1" "date: 2026-01-09" "summary: Bravo"
  lg_item docs/issues/c.md "key: app-3" "ledger: app" "status: Open" "severity: P1" "date: 2026-01-02" "summary: Charlie"
  lg_item docs/issues/d.md "key: core-1" "ledger: core" "status: Fixed" "severity: P0" "date: 2026-01-01" "summary: Delta"
  lg_item docs/issues/e.md "key: app-4" "ledger: app" "status: Closed" "severity: P3" "date: 2026-01-01" "summary: Echo"
  printf '\n## Resolution\n\nDone elsewhere.\n' >> docs/issues/e.md
  lg_item docs/issues/f.md "key: app-5" "ledger: app" "status: Open" "date: 2026-01-01" "summary: Foxtrot"
  lg_item docs/issues/g.md "key: app-6" "ledger: app" "status: Open" "severity: p1" "date: 2026-01-03" \
    "summary: Golf" "changes: [field:x]"
  lg_item docs/issues/h.md "key: app-7" "ledger: app" "status: Open" "severity: P2" "date: 2026-01-04" \
    "summary: Hotel" "consumes: [field:x, field:y]"
  lg_item docs/issues/k.md "ledger: unassigned" "status: Open" "severity: P2" "date: 2026-01-06" "summary: Kilo"
  lg_item docs/issues/w.md "key: app-8" "ledger: app" "status: won't fix" "severity: P2" "date: 2026-01-07" "summary: Whiskey"
  printf '\n## Resolution\n\nNot worth it.\n' >> docs/issues/w.md
  git add -A && git commit -qm items

  lg ls
  assert_eq "0" "$LG_RC" "ls exits 0"
  assert_eq "core-1|app-3|app-6|app-2|app-7|app-1|k|app-8|app-4|app-5" "$(lg_col "$LG_OUT" 1)" \
    "severity order (case-insensitive), then date; no severity last; a keyless item by its path stem"
  assert_eq "P0|P1|p1|P1|P2|P2|P2|P2|P3|—" "$(lg_col "$LG_OUT" 2)" "the severity column"
  lg ls --ledger app --sev P1
  assert_eq "app-3|app-6|app-2" "$(lg_col "$LG_OUT" 1)" "--ledger app --sev P1"
  lg ls --sev 'p0, P3'
  assert_eq "core-1|app-4" "$(lg_col "$LG_OUT" 1)" "--sev is a comma list, case-insensitive, spaces ignored"
  lg ls --open --ledger app
  assert_eq "app-3|app-6|app-2|app-7|app-1|app-5" "$(lg_col "$LG_OUT" 1)" "--open: the open class only"
  lg ls --status shipped
  assert_eq "core-1  P0  shipped  Delta" "$LG_OUT" "--status shipped: one exact line"
  lg ls --status "won't fix"
  assert_eq "app-8" "$(lg_col "$LG_OUT" 1)" "--status won't fix"
  lg ls --status wontfix
  assert_eq "app-8" "$(lg_col "$LG_OUT" 1)" "--status wontfix (apostrophe and space optional)"
  lg ls --status "Won’t-fix"
  assert_eq "app-8" "$(lg_col "$LG_OUT" 1)" "--status with a typographic apostrophe and a dash"
  lg ls --status "NOT STARTED" --sev P2
  assert_eq "app-7|app-1|k" "$(lg_col "$LG_OUT" 1)" "--status not started (case-insensitive)"
  lg ls --status bogus
  assert_eq "3" "$LG_RC" "an unknown --status is a usage error"
  assert_contains "$LG_ERR" "not started" "…which lists the statuses"
  lg ls --cluster field:x
  assert_eq "app-6|app-7" "$(lg_col "$LG_OUT" 1)" "--cluster: the first of changes, else the first of consumes"
  lg ls --cluster field:y
  assert_eq "" "$LG_OUT" "a second consumes entry is not the cluster"
  assert_eq "0" "$LG_RC" "no match: exit 0"
  lg ls --cluster unclustered --open --sev P2
  assert_eq "app-1|k" "$(lg_col "$LG_OUT" 1)" "--cluster unclustered"
  lg ls --ledger nosuch
  assert_eq "3" "$LG_RC" "an unknown ledger is a usage error"
  lg ls --ledger unassigned
  assert_eq "k" "$(lg_col "$LG_OUT" 1)" "--ledger unassigned"
  lg ls bogus
  assert_eq "3" "$LG_RC" "ls takes no argument"
  lg ls --open --ledger app --format json
  assert_eq "0" "$LG_RC" "JSON exits 0"
  assert_eq "1" "$(json_count "$LG_OUT")" "JSON: one object"
  assert_json_field "$LG_OUT" '[.verb, .exit] | tojson' '["ledger ls",0]' "JSON: verb, exit"
  assert_json_field "$LG_OUT" '[.items[].key] | join("|")' "app-3|app-6|app-2|app-7|app-1|app-5" "JSON: the same order"
  assert_json_field "$LG_OUT" '.items[0] | keys_unsorted | join(",")' \
    "key,path,ledger,severity,status,class,derived,display,date,summary,cluster,archived" "JSON: an item's keys"
  assert_json_field "$LG_OUT" '.items[1] | [.cluster, .display, .derived.status] | tojson' \
    '["field:x","not started","not started"]' "JSON: cluster, display, derived"
  lg ls --cluster nothing --format json
  assert_json_field "$LG_OUT" '.items | tojson' '[]' "JSON: no match → []"
  teardown
}

# lg_gen_ledger_items: 300 items — checkout: 60 open P1/P2 with 140-char
# summaries (the budget case), 90 fixed P1/P2, 50 open P3; auth: 100 open P1.
lg_gen_ledger_items() {
  awk 'BEGIN {
    s = "Order totals drift when the cart is edited during checkout and the tax line is recomputed from a stale shipping quote, so receipts disagree"
    while (length(s) < 140) s = s "x"
    s = substr(s, 1, 140)
    for (i = 1; i <= 300; i++) {
      f = sprintf("docs/issues/2026-01-%02d-item-%03d.md", (i % 28) + 1, i)
      if (i <= 60) { l = "checkout"; st = "Open"; sv = (i % 2) ? "P1" : "P2" }
      else if (i <= 150) { l = "checkout"; st = "Fixed"; sv = (i % 2) ? "P1" : "P2" }
      else if (i <= 200) { l = "checkout"; st = "Open"; sv = "P3" }
      else { l = "auth"; st = "Open"; sv = "P1" }
      printf "---\nkey: %s-%d\nledger: %s\nstatus: %s\nseverity: %s\nsummary: %s\nchanges: [field:order.total]\n---\n# Item %d\n\nBody.\n", l, i, l, st, sv, s, i > f
      close(f)
    }
  }'
}

test_lg_ls_output_budget() {
  echo "test: ledger ls --ledger L --sev P1,P2 --open over a 300-item ledger fits 8,000 bytes"
  lg_fixture
  lg_enable
  lg_registry '{"schema":"ledger-registry/1","ledgers":[
    {"id":"checkout","title":"Checkout","kind":"service","status":"active"},
    {"id":"auth","title":"Auth","kind":"service","status":"active"}]}'
  lg_gen_ledger_items
  git add -A && git commit -qm items
  lg ls --ledger checkout --sev P1,P2 --open
  assert_eq "0" "$LG_RC" "exits 0"
  assert_eq "60" "$(lg_lines "$LG_OUT")" "the 60 open P1/P2 items"
  local bytes
  bytes=$(printf '%s\n' "$LG_OUT" | wc -c | tr -d ' ')
  assert_true "≤ 8,000 bytes ($bytes)" test "$bytes" -le 8000
  assert_contains "$(printf '%s\n' "$LG_OUT" | head -n 1)" "…" "a long summary is cut, marked with …"
  teardown
}

test_lg_find_ranks() {
  echo "test: ledger find — 3 × key/summary + 2 × H1/slug + 1 × first paragraph per word; top 15"
  lg_fixture
  lg_enable
  lg_registry "$LG_REG_APP_CORE"
  lg_item docs/issues/a.md "key: app-1" "ledger: app" "status: Open" "severity: P2" "summary: Cart totals are wrong after an edit"
  lg_item docs/issues/cart-totals.md "key: app-2" "ledger: app" "status: Open" "severity: P2" "summary: Something unrelated here"
  lg_item docs/issues/c.md "key: app-3" "ledger: app" "status: Open" "severity: P2" "summary: Other issue entirely"
  printf '\nThe CART TOTALS drift.\n' >> docs/issues/c.md
  lg_item docs/issues/d.md "key: app-4" "ledger: app" "status: Open" "severity: P2" "summary: Cart badge flickers"
  lg_item docs/issues/e.md "key: app-5" "ledger: app" "status: Open" "severity: P2" "summary: Nothing here"
  lg_item docs/issues/f.md "key: app-6" "ledger: app" "status: Open" "severity: P0" "summary: Cart badge is blank"
  git add -A && git commit -qm items
  lg find cart totals
  assert_eq "0" "$LG_RC" "exits 0"
  assert_eq "app-1|app-2|app-6|app-4|app-3" "$(lg_col "$LG_OUT" 2)" "ranked by score; a tie by severity"
  assert_eq "6|4|3|3|2" "$(lg_col "$LG_OUT" 1)" "the scores"
  lg find 'CART Totals'
  assert_eq "app-1|app-2|app-6|app-4|app-3" "$(lg_col "$LG_OUT" 2)" "case-insensitive; one quoted argument splits on spaces"
  lg find app-5
  assert_eq "app-5" "$(lg_col "$LG_OUT" 2)" "the key is searched"
  lg find zzz
  assert_eq "0" "$LG_RC" "no match: exit 0"
  assert_eq "no items match" "$LG_OUT" "no match: one line"
  lg find
  assert_eq "3" "$LG_RC" "no words: usage (3)"
  lg find cart --format json
  assert_eq "1" "$(json_count "$LG_OUT")" "JSON: one object"
  assert_json_field "$LG_OUT" '[.matches, (.items | length), .items[0].score, .items[0].key] | tojson' \
    '[5,5,3,"app-6"]' "JSON: matches, items, score"
  local i
  for i in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20; do
    lg_item "docs/issues/z$i.md" "key: core-$i" "ledger: core" "status: Open" "severity: P3" "summary: Zebra stripes $i"
  done
  lg find zebra
  assert_eq "16" "$(lg_lines "$LG_OUT")" "top 15 and a count line"
  assert_eq "… 5 more matches" "$(printf '%s\n' "$LG_OUT" | tail -n 1)" "the count line"
  lg find zebra --format json
  assert_json_field "$LG_OUT" '[.matches, (.items | length)] | tojson' '[20,15]' "JSON: top 15 of 20"
  teardown
}

test_lg_smoke_budgets() {
  echo "test: scripts/bench-ledger.sh at 300 items — every budget ×3 (CI smoke)"
  local out rc=0 bench="$REPO_DIR/scripts/bench-ledger.sh"
  out=$("$BASH_BIN" "$bench" --scale 3 --history-commits 300 300 2>&1) || rc=$?
  assert_eq "0" "$rc" "bench-ledger.sh 300 --scale 3 exits 0"
  assert_contains "$out" "bench-ledger: ok" "…and says ok"
  local row
  for row in "ls " "ls --ledger" "show " "find " "refs step" "index --staged (20 staged)" \
      "index --staged (400 staged)" "validate --staged (20 staged)" "history: cold index" "history: dates log --full-history"; do
    assert_contains "$out" "$row" "a row for '$row'"
  done
  if [ "$rc" != 0 ]; then printf '%s\n' "$out" | sed 's/^/    | /'; fi
  "$BASH_BIN" "$bench" 2>/dev/null && rc=0 || rc=$?
  assert_eq "3" "$rc" "no N: usage (3)"
}

# --- Task 5 review carry-over: one derived-status label set --------------------

test_lg_status_labels_shared() {
  echo "test: the derived-status labels index.sh writes are the ones query.sh accepts (one definition)"
  lg_fixture
  lg_enable
  local q i want
  want='["superseded","won'"'"'t fix","closed","shipped","merged","in review","on branch","planned","spec'"'"'d","not started"]'
  # shellcheck disable=SC2031  # read inside the lg_source subshell, where it is set
  q=$( lg_source; jq -L "$_LG_LIB" -nc "$_LG_JQ_QUERY_DEFS"'[lg_status_labels[]]' )
  # shellcheck disable=SC2031  # read inside the lg_source subshell, where it is set
  i=$( lg_source; jq -L "$_LG_LIB" -nc "$_LG_JQ_INDEX_DEFS"'[lg_status_labels[]]' )
  assert_eq "$want" "$q" "query.sh's labels"
  assert_eq "$q" "$i" "index.sh's labels are the same"
  # Every label is accepted by ls --status (query.sh) as itself.
  local l
  for l in shipped "not started" "spec'd" "won't fix" planned; do
    lg ls --status "$l"
    assert_eq "0" "$LG_RC" "ls --status '$l' is accepted"
  done
  teardown
}

# --- Task 6: keys — resolution, CAS allocation, finalize, new, assign ------------

LG_REG_XY='{"schema":"ledger-registry/1","ledgers":[
  {"id":"x","title":"X","kind":"service","status":"active"},
  {"id":"y","title":"Y","kind":"service","status":"active"},
  {"id":"old","title":"Old","kind":"service","status":"retired"}]}'

# lg_keys_fixture [config-json]: lg_fixture + config + registry, committed,
# with a local bare remote "origin" (LG_REMOTE) holding main, fetched (so
# origin/main — the default base — exists).
lg_keys_fixture() {
  local c='{}'
  if [ $# -gt 0 ]; then c=$1; fi
  lg_fixture
  lg_enable "$c"
  lg_registry "$LG_REG_XY"
  git add -A && git commit -qm ledger
  LG_REMOTE=$(harness_mktemp_d remote).git
  git init -q --bare "$LG_REMOTE"
  git --git-dir="$LG_REMOTE" symbolic-ref HEAD refs/heads/main
  git remote add origin "$LG_REMOTE"
  git push -q origin main
  git fetch -q origin
}

# lg_clone <dir>: a second clone of LG_REMOTE at <dir>.
lg_clone() {
  git clone -q "$LG_REMOTE" "$1"
}

# lg_call_in <dir> <function> [args…]: lg_call with the fixture at <dir>.
lg_call_in() {
  local dir="$1" saved="$TEST_DIR"
  shift
  TEST_DIR=$dir
  lg_call "$@"
  TEST_DIR=$saved
}

# The counter blob on the remote (compact, keys sorted), or "absent".
lg_remote_counters() {
  local oid
  oid=$(git --git-dir="$LG_REMOTE" rev-parse -q --verify refs/doc-superpowers/ledger/counters 2>/dev/null) \
    || { echo absent; return 0; }
  git --git-dir="$LG_REMOTE" cat-file blob "$oid:counters.json" | jq -cS .
}

# The number of commits on the remote counter ref (0 when absent).
lg_remote_counter_commits() {
  git --git-dir="$LG_REMOTE" rev-list --count refs/doc-superpowers/ledger/counters 2>/dev/null || echo 0
}

# The first 4 hex digits of sha256(<path>) (no newline).
lg_hex4() {
  local h
  if command -v sha256sum >/dev/null 2>&1; then h=$(printf '%s' "$1" | sha256sum); else h=$(printf '%s' "$1" | shasum -a 256); fi
  printf '%s' "${h:0:4}"
}

# lg_wait_job <secs> <pid>: wait for a background job (polling), at most
# <secs> seconds, then reap it with harness_kill_after (which signals it if it
# is still running); its exit code is the return value.
lg_wait_job() {
  local limit="$1" pid="$2" n=0 max rc=0
  max=$((limit * 10))
  while [ "$n" -lt "$max" ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.1
    n=$((n + 1))
  done
  harness_kill_after 0 TERM "$pid" || rc=$?
  return "$rc"
}

lg_keys_resolve_items() {
  lg_item docs/issues/a.md "key: x-14" "ledger: x" "status: Open" "summary: Alpha" "aliases: [y-3, old-7]"
  lg_item docs/issues/b.md "key: x-15" "ledger: x" "status: Open" "summary: Bravo"
  lg_item docs/issues/k.md "ledger: unassigned" "status: Open" "summary: Keyless"
  lg_item "docs/issues/with space.md" "key: y-9" "ledger: y" "status: Open" "summary: Spaced"
}

test_lg_resolve_forms() {
  echo "test: _lg_resolve — key (any case), 'L 14', 'L #14', alias, path, ./path, stem; unknown rc 1"
  lg_keys_fixture
  lg_keys_resolve_items
  local r
  for r in x-14 X-14 "x 14" "x #14" "x  #14" y-3 OLD-7 docs/issues/a.md ./docs/issues/a.md a; do
    lg_call _lg_resolve "$r"
    assert_eq "0|docs/issues/a.md" "$LG_RC|$LG_OUT" "'$r' → docs/issues/a.md"
  done
  lg_call _lg_resolve "y 9"
  assert_eq "0|docs/issues/with space.md" "$LG_RC|$LG_OUT" "'y 9' → a path with a space"
  lg_call _lg_resolve k
  assert_eq "0|docs/issues/k.md" "$LG_RC|$LG_OUT" "a keyless item by its stem"
  for r in x-99 "x 99" nope "x-14 x-15"; do
    lg_call _lg_resolve "$r"
    assert_eq "1|" "$LG_RC|$LG_OUT" "'$r' → none (rc 1, nothing printed)"
  done
  # show takes the same forms, as one argument or several words.
  lg show x 14
  assert_eq "0" "$LG_RC" "show x 14 (two words)"
  assert_eq "x-14  x  —  not started" "$(printf '%s\n' "$LG_OUT" | head -n 1)" "…the item"
  lg show "x #14"
  assert_eq "0" "$LG_RC" "show 'x #14'"
  lg show old-7
  assert_eq "0" "$LG_RC" "show an alias"
  assert_contains "$LG_OUT" "aliases: y-3, old-7" "…the item that carries it"
  lg show x-14 x-15
  assert_eq "3" "$LG_RC" "two refs: still a usage error"
  teardown
}

test_lg_resolve_legacy_forms() {
  echo "test: _lg_resolve — legacy refs '<old>#<n>', '<old> row <n>', '<old> ledger row <n>' through legacy.json"
  lg_keys_fixture '{"legacy_ledgers":{"tier1":"docs/ledgers/tier1-pipeline-ledger.md"}}'
  lg_keys_resolve_items
  printf '%s\n' '{"checkout#3":{"key":"x-14"},"checkout#4":{"item":"docs/issues/b.md"},
    "checkout#5":{"archived":"docs/archive/checkout-ledger.md#row-5"},"tier1#2":{"key":"y-3"},
    "checkout#6":{"key":"x-404"}}' > docs/ledger/legacy.json
  local r
  for r in "checkout#3" "checkout row 3" "checkout ledger row 3" "Checkout Ledger Row 3" "checkout-ledger row 3" \
      "checkout-ledger#3" "tier1#2" "tier1 row 2" "tier1-pipeline-ledger#2" "tier1-pipeline-ledger ledger row 2"; do
    lg_call _lg_resolve "$r"
    assert_eq "0|docs/issues/a.md" "$LG_RC|$LG_OUT" "'$r' → docs/issues/a.md"
  done
  lg_call _lg_resolve "checkout#4"
  assert_eq "0|docs/issues/b.md" "$LG_RC|$LG_OUT" "{\"item\"} → that path"
  lg_call _lg_resolve "checkout row 5"
  assert_eq "0|docs/archive/checkout-ledger.md#row-5" "$LG_RC|$LG_OUT" "{\"archived\"} → the anchor, rc 0"
  for r in "checkout#9" "checkout row 6" "nope#3"; do
    lg_call _lg_resolve "$r"
    assert_eq "1" "$LG_RC" "'$r' → none (rc 1)"
  done
  lg show checkout row 5
  assert_eq "0" "$LG_RC" "show an archived legacy row"
  assert_eq "archived: docs/archive/checkout-ledger.md#row-5" "$LG_OUT" "…prints its anchor"
  lg show "checkout row 5" --format json
  assert_json_field "$LG_OUT" '[.exit, .item, .archived] | tojson' '[0,null,"docs/archive/checkout-ledger.md#row-5"]' \
    "JSON: archived anchor, no item"
  lg show checkout ledger row 3
  assert_eq "x-14  x  —  not started" "$(printf '%s\n' "$LG_OUT" | head -n 1)" "show a legacy row's item"
  teardown
}

test_lg_resolve_finalized() {
  echo "test: _lg_resolve — a provisional key recorded in docs/ledger/finalized.json reaches its key"
  lg_keys_fixture
  lg_keys_resolve_items
  printf '{\n  "x-~ab12": "x-15"\n}\n' > docs/ledger/finalized.json
  lg_call _lg_resolve "x-~ab12"
  assert_eq "0|docs/issues/b.md" "$LG_RC|$LG_OUT" "x-~ab12 → x-15's item"
  lg_call _lg_resolve "X-~AB12"
  assert_eq "0|docs/issues/b.md" "$LG_RC|$LG_OUT" "…in any case"
  lg_call _lg_resolve "x-~ffff"
  assert_eq "1" "$LG_RC" "an unrecorded provisional key → none"
  # A provisional key still on an item resolves to it directly.
  lg_item docs/issues/p.md "key: y-~0f3c" "ledger: y" "status: Open" "summary: Pending"
  lg_call _lg_resolve "y-~0f3c"
  assert_eq "0|docs/issues/p.md" "$LG_RC|$LG_OUT" "a provisional key on an item"
  teardown
}

test_lg_resolve_ambiguous() {
  echo "test: _lg_resolve — several items → rc 3 (duplicate key, key vs alias, stem in two dirs)"
  lg_keys_fixture
  lg_item docs/issues/a.md "key: x-1" "ledger: x" "status: Open" "summary: A"
  lg_item docs/issues/b.md "key: x-1" "ledger: x" "status: Open" "summary: B"
  lg_item docs/issues/c.md "key: x-2" "ledger: x" "status: Open" "summary: C"
  lg_item docs/issues/d.md "key: x-3" "ledger: x" "status: Open" "summary: D" "aliases: [x-2]"
  lg_item docs/archive/issues/c.md "key: x-4" "ledger: x" "status: Closed" "summary: C old"
  lg_call _lg_resolve x-1
  assert_eq "3|" "$LG_RC|$LG_OUT" "a duplicate key → rc 3, nothing on stdout"
  assert_contains "$LG_ERR" "docs/issues/a.md" "…stderr names the items"
  assert_contains "$LG_ERR" "docs/issues/b.md" "…both"
  lg_call _lg_resolve "x 2"
  assert_eq "3" "$LG_RC" "a key on one item and an alias on another → rc 3"
  lg_call _lg_resolve c
  assert_eq "3" "$LG_RC" "a stem two items share → rc 3"
  lg_call _lg_resolve docs/issues/c.md
  assert_eq "0|docs/issues/c.md" "$LG_RC|$LG_OUT" "the path itself is never ambiguous"
  lg show x-1
  assert_eq "3" "$LG_RC" "show: ambiguous → usage (3)"
  teardown
}

test_lg_alloc_seeds_from_base() {
  echo "test: first allocation seeds a ledger from the highest key on the base (x-1, x-5 → x-6), fetched first"
  lg_keys_fixture
  local c2 here
  # The items reach the remote from another clone: this clone's origin/main
  # is stale until the seeding fetches it.
  c2=$(harness_mktemp_d seedclone)/c
  lg_clone "$c2"
  here=$PWD
  cd "$c2"
  lg_item docs/issues/a.md "key: x-1" "ledger: x" "status: Open" "summary: A"
  lg_item docs/issues/b.md "key: x-5" "ledger: x" "status: Fixed" "summary: B"
  lg_item docs/issues/c.md "key: y-2" "ledger: y" "status: Open" "summary: C" "aliases: [y-7]"
  git add -A && git commit -qm items && git push -q origin main
  cd "$here"
  local stale
  stale=$(git rev-parse refs/remotes/origin/main)
  # Not on the base: an uncommitted item with a higher key.
  lg_item docs/issues/d.md "key: x-9" "ledger: x" "status: Open" "summary: D"
  assert_eq "absent" "$(lg_remote_counters)" "no counter ref yet"
  lg_call _lg_counter_read
  assert_eq "0" "$LG_RC" "_lg_counter_read exits 0"
  assert_json_field "$LG_OUT" '[.x, .y] | tojson' '[6,8]' "seeded: x 6, y 8 (an alias counts: keys are never reused)"
  assert_eq "$stale" "$(git rev-parse refs/remotes/origin/main)" "the base was fetched into a private ref: origin/main not moved"
  lg_call _lg_alloc x 1 docs/issues/n.md
  assert_eq "0|x	x-6" "$LG_RC|$LG_OUT" "first key x-6"
  assert_eq '{"x":7,"y":8}' "$(lg_remote_counters)" "the counter ref holds every seeded ledger"
  lg_call _lg_alloc x 2 docs/issues/n.md docs/issues/o.md
  assert_eq "x	x-7
x	x-8" "$LG_OUT" "then x-7, x-8"
  lg_call _lg_alloc z 1 docs/issues/n.md
  assert_eq "0|z	z-1" "$LG_RC|$LG_OUT" "a ledger with no keys anywhere starts at 1"
  lg_call _lg_counter_read
  assert_json_field "$LG_OUT" '[.x, .y, .z] | tojson' '[9,8,2]' "_lg_counter_read reads the ref"
  teardown
}

test_lg_alloc_batch_one_commit() {
  echo "test: _lg_alloc_batch {x:2,y:3} — one CAS commit for every ledger"
  lg_keys_fixture
  lg_call _lg_alloc x 1 docs/issues/n.md
  assert_eq "x	x-1" "$LG_OUT" "x-1"
  assert_eq "1" "$(lg_remote_counter_commits)" "one commit"
  lg_call _lg_alloc_batch '{"x":2,"y":3}'
  assert_eq "0" "$LG_RC" "batch exits 0"
  assert_eq "x	x-2
x	x-3
y	y-1
y	y-2
y	y-3" "$LG_OUT" "ledger<TAB>key lines"
  assert_eq "2" "$(lg_remote_counter_commits)" "the counter ref advanced by one commit"
  assert_eq '{"x":4,"y":4}' "$(lg_remote_counters)" "the blob"
  local msg
  msg=$(git --git-dir="$LG_REMOTE" log -1 --format=%s refs/doc-superpowers/ledger/counters)
  assert_contains "$msg" "ledger: allocate" "commit message 'ledger: allocate …'"
  assert_eq "counters.json" "$(git --git-dir="$LG_REMOTE" ls-tree --name-only refs/doc-superpowers/ledger/counters)" \
    "the tree is one blob, counters.json"
  lg_call _lg_alloc_batch '{"x":0}'
  assert_eq "2" "$LG_RC" "a count below 1 is refused (2)"
  lg_call _lg_alloc_batch '{"Bad Id":1}'
  assert_eq "2" "$LG_RC" "a bad ledger id is refused (2)"
  teardown
}

# One allocation job: <n> single allocations from the fixture at <dir>.
lg_alloc_job() {
  local dir="$1" n="$2"
  TEST_DIR=$dir
  lg_source
  # A loaded host must not turn a race into a spurious "gave up".
  _LG_ALLOC_RETRIES=10
  local i=0
  while [ "$i" -lt "$n" ]; do
    _lg_alloc x 1 docs/issues/r.md
    i=$((i + 1))
  done
}

test_lg_alloc_race() {
  echo "test: two clones × 10 allocations racing on one remote → 20 distinct keys, none provisional"
  lg_keys_fixture
  local c2 o1 o2 p1 p2 rc1=0 rc2=0 alive1 alive2
  c2=$(harness_mktemp_d clone2)/c
  lg_clone "$c2"
  o1=$(harness_mktemp race1)
  o2=$(harness_mktemp race2)
  set +e
  ( lg_alloc_job "$TEST_DIR" 10 ) > "$o1" 2> "$o1.err" &
  p1=$!
  ( lg_alloc_job "$c2" 10 ) > "$o2" 2> "$o2.err" &
  p2=$!
  set -e
  lg_wait_job 180 "$p1" || rc1=$?
  alive1=$HARNESS_KILL_ALIVE
  lg_wait_job 180 "$p2" || rc2=$?
  alive2=$HARNESS_KILL_ALIVE
  assert_eq "0|0" "$alive1|$alive2" "both jobs finished on their own"
  assert_eq "0|0" "$rc1|$rc2" "both jobs exit 0"
  if [ "$rc1|$rc2" != "0|0" ]; then sed 's/^/    | /' "$o1.err" "$o2.err"; fi
  assert_eq "20" "$(cat "$o1" "$o2" | cut -f2 | sort -u | grep -c .)" "20 distinct keys"
  assert_eq "0" "$(cat "$o1" "$o2" | grep -c '~' || true)" "none provisional"
  assert_eq "$(seq 1 20 | sed 's/^/x-/' | sort)" "$(cat "$o1" "$o2" | cut -f2 | sort)" "x-1 … x-20"
  assert_eq '{"x":21}' "$(lg_remote_counters)" "the counter is 21"
  teardown
}

# A receive-pack for the remote that moves the counter ref before every push,
# so the lease never holds (a remote whose counter always moved on).
lg_stale_receive_pack() {
  local f="$1" log="$2"
  cat > "$f" <<EOF
#!/bin/sh
repo="\$1"
echo push >> "$log"
b=\$(echo '{"x":1}' | git --git-dir="\$repo" hash-object -w --stdin)
t=\$(printf '100644 blob %s\\tcounters.json\\n' "\$b" | git --git-dir="\$repo" mktree)
c=\$(echo "bump \$\$" | git --git-dir="\$repo" commit-tree "\$t")
git --git-dir="\$repo" update-ref refs/doc-superpowers/ledger/counters "\$c"
exec git receive-pack "\$repo"
EOF
  chmod +x "$f"
}

test_lg_alloc_exhausted_rc2() {
  echo "test: a remote that always answers 'stale info' → rc 2 after 8 retries, no key, no provisional"
  lg_keys_fixture
  local rp log
  rp=$(harness_mktemp rp)
  log=$(harness_mktemp rplog)
  : > "$log"
  lg_stale_receive_pack "$rp" "$log"
  git config remote.origin.receivepack "$rp"
  lg_call _lg_alloc x 1 docs/issues/n.md
  assert_eq "2" "$LG_RC" "exhausted → rc 2"
  assert_eq "" "$LG_OUT" "no key printed"
  assert_contains "$LG_ERR" "retries" "stderr says the retries ran out"
  assert_eq "9" "$(grep -c push "$log")" "1 attempt + 8 retries"
  teardown
}

test_lg_alloc_declined_rc2() {
  echo "test: a pre-receive hook that declines → rc 2 at once, no key"
  lg_keys_fixture
  local log
  log=$(harness_mktemp hooklog)
  : > "$log"
  printf '#!/bin/sh\necho hook >> "%s"\necho "no counters here" >&2\nexit 1\n' "$log" > "$LG_REMOTE/hooks/pre-receive"
  chmod +x "$LG_REMOTE/hooks/pre-receive"
  lg_call _lg_alloc x 1 docs/issues/n.md
  assert_eq "2" "$LG_RC" "declined → rc 2"
  assert_eq "" "$LG_OUT" "no key printed"
  assert_contains "$LG_ERR" "declined" "stderr gives git's reason"
  assert_eq "1" "$(grep -c hook "$log")" "one attempt, no retries"
  assert_eq "absent" "$(lg_remote_counters)" "the remote has no counter"
  teardown
}

test_lg_counter_push_no_verify() {
  echo "test: the counter push skips the local pre-push hook (--no-verify)"
  lg_keys_fixture
  printf '#!/bin/sh\nexit 1\n' > .git/hooks/pre-push
  chmod +x .git/hooks/pre-push
  lg_call _lg_alloc x 1 docs/issues/n.md
  assert_eq "0|x	x-1" "$LG_RC|$LG_OUT" "allocated despite a failing pre-push hook"
  assert_eq '{"x":2}' "$(lg_remote_counters)" "the counter ref was pushed"
  # Reads go where the push goes: remote.origin.pushurl over url.
  git config remote.origin.pushurl "$LG_REMOTE"
  git config remote.origin.url "$TEST_DIR/no-such-remote.git"
  lg_call _lg_alloc x 1 docs/issues/n.md
  assert_eq "0|x	x-2" "$LG_RC|$LG_OUT" "the counter is read from the push URL (no provisional key)"
  teardown
}

test_lg_alloc_offline_provisional() {
  echo "test: an unreachable remote → a provisional key <ledger>-~<hex4 of the path>, a warning, rc 0"
  lg_keys_fixture
  git remote set-url origin "$TEST_DIR/no-such-remote.git"
  local h
  h=$(lg_hex4 "docs/issues/n.md")
  lg_call _lg_alloc x 1 docs/issues/n.md
  assert_eq "0|x	x-~$h" "$LG_RC|$LG_OUT" "x-~$h"
  assert_contains "$LG_ERR" "provisional" "stderr warns"
  lg_call _lg_alloc_batch '{"x":1,"y":1}'
  assert_eq "2" "$LG_RC" "offline without item paths → rc 2 (no provisional to give)"
  teardown
}

test_lg_merge_mode_provisional_and_finalize() {
  echo "test: keys.mode merge — provisional keys with no network; finalize on the base rewrites references in one commit"
  lg_keys_fixture '{"base":"main","keys":{"mode":"merge"}}'
  git remote set-url origin "$TEST_DIR/no-such-remote.git"
  local h1 h2 out before after body_m body_q
  h1=$(lg_hex4 "docs/issues/n.md")
  h2=$(lg_hex4 "docs/issues/o.md")
  lg_call _lg_alloc x 1 docs/issues/n.md
  assert_eq "0|x	x-~$h1" "$LG_RC|$LG_OUT" "merge mode: provisional"
  assert_not_contains "$LG_ERR" "warning" "…without an offline warning (no network is tried)"
  lg_item docs/issues/a.md "key: x-3" "ledger: x" "status: Open" "summary: Existing"
  lg_item docs/issues/n.md "key: x-~$h1" "ledger: x" "status: Open" "summary: New one"
  lg_item docs/issues/o.md "key: y-~$h2" "ledger: y" "status: Open" "summary: Other new"
  lg_item docs/issues/m.md "key: x-2" "ledger: x" "status: Closed" "summary: Old" "superseded_by: x-~$h1" \
    "relates: [sibling:y-~$h2, root-cause:x-3]"
  printf '\n## Resolution\n\nReplaced.\n' >> docs/issues/m.md
  lg_item docs/issues/q.md "key: y-1" "ledger: y" "status: Open" "summary: Quiet" "relates:" "  - sibling:x-~$h1"
  lg_item docs/issues/u.md "key: x-1" "ledger: x" "status: Open" "summary: Untouched"
  lg_item docs/issues/al.md "key: z-1" "ledger: z" "status: Open" "summary: Aliased" "aliases: [old-1, y-~$h2]"
  git add -A && git commit -qm "items with provisional keys"
  before=$(git rev-parse HEAD)
  body_m=$(lg_tail_hash docs/issues/m.md 8)
  body_q=$(lg_tail_hash docs/issues/q.md 8)
  lg finalize
  assert_eq "0" "$LG_RC" "finalize exits 0"
  assert_contains "$LG_OUT" "x-~$h1 → x-4" "x's provisional → x-4 (after x-3)"
  assert_contains "$LG_OUT" "y-~$h2 → y-2" "y's provisional → y-2"
  assert_eq "$before" "$(git rev-parse HEAD~1)" "one new commit"
  assert_eq "ledger: finalize 2 keys" "$(git log -1 --format=%s)" "its message"
  assert_eq "docs/issues/al.md
docs/issues/m.md
docs/issues/n.md
docs/issues/o.md
docs/issues/q.md
docs/ledger/finalized.json" "$(git show --name-only --format= HEAD | sort)" "it touches only the referencing files and finalized.json"
  assert_eq "" "$(git status --porcelain)" "nothing left uncommitted"
  assert_contains "$(cat docs/issues/n.md)" "key: x-4" "n.md: its key"
  assert_contains "$(cat docs/issues/o.md)" "key: y-2" "o.md: its key"
  assert_contains "$(cat docs/issues/m.md)" "superseded_by: x-4" "m.md: superseded_by"
  assert_contains "$(cat docs/issues/m.md)" "relates: [sibling:y-2, root-cause:x-3]" "m.md: relates"
  assert_contains "$(cat docs/issues/q.md)" "relates:
  - \"sibling:x-4\"" "q.md: a block list stays a block list"
  assert_contains "$(cat docs/issues/al.md)" "aliases: [old-1, y-2]" "al.md: an alias rewritten"
  assert_eq "$body_m" "$(lg_tail_hash docs/issues/m.md 8)" "m.md: the body is byte-identical"
  assert_eq "$body_q" "$(lg_tail_hash docs/issues/q.md 8)" "q.md: the body is byte-identical"
  after=$(cat docs/ledger/finalized.json)
  assert_eq "{
  \"x-~$h1\": \"x-4\",
  \"y-~$h2\": \"y-2\"
}" "$after" "finalized.json: one entry per line, keys sorted"
  lg_call _lg_resolve "x-~$h1"
  assert_eq "0|docs/issues/n.md" "$LG_RC|$LG_OUT" "the old provisional key still resolves"
  lg finalize
  assert_eq "0" "$LG_RC" "a second finalize: nothing to do"
  assert_eq "$before" "$(git rev-parse HEAD~1)" "…no commit"
  # A reference to a finalized key, merged later: rewritten in its own commit.
  lg_item docs/issues/late.md "key: x-1" "ledger: x" "status: Open" "summary: Late" "relates: [sibling:x-~$h1]"
  git rm -q docs/issues/u.md && git add -A && git commit -qm "late reference"
  lg finalize
  assert_eq "0" "$LG_RC" "stale references only"
  assert_eq "ledger: rewrite references to finalized keys" "$(git log -1 --format=%s)" "…committed as a reference rewrite"
  assert_contains "$(cat docs/issues/late.md)" "relates: [sibling:x-4]" "late.md rewritten"
  # Not on the base: refused.
  git checkout -q -b side
  git commit -q --allow-empty -m side
  lg_item docs/issues/s.md "key: x-~beef" "ledger: x" "status: Open" "summary: Side"
  lg finalize
  assert_eq "3" "$LG_RC" "merge mode off the base → usage (3)"
  lg new --finalize --file docs/issues/s.md
  assert_eq "2" "$LG_RC" "new --finalize off the base → 2"
  assert_contains "$LG_ERR" "on the base" "…saying why"
  printf '# T\n' > docs/issues/t.md
  lg new --ledger x --summary "Needs a real key" --file docs/issues/t.md --finalize
  assert_eq "2" "$LG_RC" "new --finalize of a keyless item off the base → 2"
  assert_eq "# T" "$(cat docs/issues/t.md)" "…nothing written"
  git checkout -q main
  lg new --ledger x --summary "Real key on the base" --file docs/issues/t.md --finalize
  assert_eq "0|x-5  docs/issues/t.md" "$LG_RC|$LG_OUT" "new --finalize on the base: the next real key"
  teardown
}

test_lg_new_writes_fields() {
  echo "test: ledger new — key, ledger and summary written into the one new item file"
  lg_keys_fixture
  printf '# New bug\n\nIt breaks.\n' > docs/issues/n.md
  lg new --ledger x --summary "Totals drift after an edit"
  assert_eq "0" "$LG_RC" "new exits 0"
  assert_eq "x-1  docs/issues/n.md" "$LG_OUT" "prints the key and the path"
  assert_contains "$(cat docs/issues/n.md)" "key: x-1" "key written"
  assert_contains "$(cat docs/issues/n.md)" "ledger: x" "ledger written"
  assert_contains "$(cat docs/issues/n.md)" "summary: Totals drift after an edit" "summary written"
  assert_contains "$(cat docs/issues/n.md)" "# New bug" "the body is kept"
  lg new --ledger x --summary "Another"
  assert_eq "3" "$LG_RC" "no keyless new item left → usage (3)"
  printf '# A\n' > docs/issues/a.md
  printf '# B\n' > docs/issues/b.md
  git add docs/issues/b.md
  lg new --ledger x --summary "Which one"
  assert_eq "3" "$LG_RC" "two candidates (one staged, one untracked) → usage (3)"
  assert_contains "$LG_ERR" "docs/issues/a.md" "…naming them"
  lg new --ledger y --summary "Bravo summary" --file docs/issues/b.md --format json
  assert_eq "0" "$LG_RC" "--file picks one"
  assert_json_field "$LG_OUT" '[.verb, .exit, .key, .ledger, .path, .provisional] | tojson' \
    '["ledger new",0,"y-1","y","docs/issues/b.md",false]' "JSON payload"
  lg new --ledger z --summary "Unknown ledger" --file docs/issues/a.md
  assert_eq "3" "$LG_RC" "an unregistered ledger → usage (3)"
  lg new --ledger old --summary "Retired ledger" --file docs/issues/a.md
  assert_eq "3" "$LG_RC" "a retired ledger → usage (3)"
  lg new --ledger x --summary "Has a key" --file docs/issues/n.md
  assert_eq "3" "$LG_RC" "an item that has a key → usage (3)"
  lg new --ledger x --file docs/issues/a.md
  assert_eq "3" "$LG_RC" "no --summary → usage (3)"
  lg new --ledger x --summary "Not an item" --file src/index.js
  assert_eq "3" "$LG_RC" "a file outside the item globs → usage (3)"
  assert_eq '{"x":2,"y":2}' "$(lg_remote_counters)" "only the two successful runs allocated"
  teardown
}

test_lg_new_unassigned_no_key() {
  echo "test: ledger new --ledger unassigned — ledger and summary, no key, no network"
  lg_keys_fixture
  git remote set-url origin "$TEST_DIR/no-such-remote.git"
  printf '# Home unknown\n' > docs/issues/u.md
  lg new --ledger unassigned --summary "Somewhere in the stack"
  assert_eq "0" "$LG_RC" "exits 0"
  assert_eq "unassigned  docs/issues/u.md" "$LG_OUT" "prints the ledger and the path"
  assert_eq "" "$LG_ERR" "no warning: nothing was allocated"
  assert_contains "$(cat docs/issues/u.md)" "ledger: unassigned" "ledger written"
  assert_not_contains "$(cat docs/issues/u.md)" "key:" "no key"
  teardown
}

test_lg_new_summary_too_long() {
  echo "test: ledger new — a summary over 140 characters is a usage error; 140 is fine"
  lg_keys_fixture
  printf '# T\n' > docs/issues/t.md
  local s140 s141
  s140=$(printf 'é%.0s' $(seq 1 140))
  s141="${s140}a"
  lg new --ledger x --summary "$s141"
  assert_eq "3" "$LG_RC" "141 characters → usage (3)"
  assert_contains "$LG_ERR" "140" "…says the limit"
  assert_eq "# T" "$(cat docs/issues/t.md)" "nothing written"
  assert_eq "absent" "$(lg_remote_counters)" "nothing allocated"
  lg new --ledger x --summary "$s140"
  assert_eq "0" "$LG_RC" "140 characters (multi-byte) are fine"
  lg new --ledger x --summary "two
lines" --file docs/issues/t.md
  assert_eq "3" "$LG_RC" "a summary of two lines → usage (3)"
  teardown
}

test_lg_assign_moves_old_key_to_aliases() {
  echo "test: ledger assign — a new key in the target ledger; the previous key appended to aliases"
  lg_keys_fixture
  lg_item docs/issues/a.md "key: x-1" "ledger: x" "status: Open" "summary: Alpha" "aliases: [old-2]"
  lg_item docs/issues/k.md "ledger: unassigned" "status: Open" "summary: Keyless"
  git add -A && git commit -qm items && git push -q origin main && git fetch -q origin
  lg assign "x 1" y
  assert_eq "0" "$LG_RC" "assign exits 0"
  assert_eq "y-1  docs/issues/a.md  (was x-1)" "$LG_OUT" "prints the new key and the old"
  assert_contains "$(cat docs/issues/a.md)" "key: y-1" "the new key"
  assert_contains "$(cat docs/issues/a.md)" "ledger: y" "the new ledger"
  assert_contains "$(cat docs/issues/a.md)" "aliases: [old-2, x-1]" "the old key appended to aliases"
  lg_call _lg_resolve x-1
  assert_eq "0|docs/issues/a.md" "$LG_RC|$LG_OUT" "the old key still resolves (alias)"
  lg assign docs/issues/k.md x --format json
  assert_eq "0" "$LG_RC" "an unassigned item gets its first key"
  assert_json_field "$LG_OUT" '[.key, .ledger, .previous, .path] | tojson' '["x-2","x",null,"docs/issues/k.md"]' \
    "JSON: x-2 (seeded past x-1), no previous key"
  assert_not_contains "$(cat docs/issues/k.md)" "aliases" "no alias for a keyless item"
  lg assign y-1 nosuch
  assert_eq "3" "$LG_RC" "an unknown ledger → usage (3)"
  lg assign x-404 y
  assert_eq "1" "$LG_RC" "an unknown item → rc 1"
  lg assign y-1
  assert_eq "3" "$LG_RC" "a missing ledger argument → usage (3)"
  # A provisional old key: its references follow it, it is recorded as
  # finalized, and it is never kept as an alias.
  lg_item docs/issues/p.md "key: x-~abcd" "ledger: x" "status: Open" "summary: Pending"
  lg_item docs/issues/r.md "key: x-9" "ledger: x" "status: Open" "summary: Refers" "relates: [sibling:x-~abcd]"
  lg assign x-~abcd y
  assert_eq "0" "$LG_RC" "assign an item with a provisional key"
  assert_eq "y-2  docs/issues/p.md  (was x-~abcd)" "$LG_OUT" "…a new key"
  assert_contains "$(cat docs/issues/p.md)" "key: y-2" "p.md: the new key"
  assert_not_contains "$(cat docs/issues/p.md)" "aliases" "p.md: no provisional alias"
  assert_contains "$(cat docs/issues/r.md)" "relates: [sibling:y-2]" "r.md: the reference follows"
  assert_eq '{"x-~abcd":"y-2"}' "$(jq -c . docs/ledger/finalized.json)" "finalized.json records it"
  teardown
}

test_lg_cas_finalize_and_provisional_in_range() {
  echo "test: cas finalize replaces provisional keys in the working tree; _lg_provisional_in_range lists those a range adds"
  lg_keys_fixture
  local h base
  base=$(git rev-parse HEAD)
  git remote set-url origin "$TEST_DIR/no-such-remote.git"
  printf '# Offline\n' > docs/issues/n.md
  h=$(lg_hex4 docs/issues/n.md)
  lg new --ledger x --summary "Filed on a plane"
  assert_eq "0" "$LG_RC" "offline new exits 0"
  assert_eq "x-~$h  docs/issues/n.md" "$LG_OUT" "…with a provisional key"
  assert_contains "$LG_ERR" "provisional" "…and a warning"
  lg_item docs/issues/r.md "key: x-~0000" "ledger: x" "status: Open" "summary: Other" "relates: [depends-on:x-~$h]"
  git add -A && git commit -qm "provisional"
  lg_call _lg_provisional_in_range "$base..HEAD"
  assert_eq "0" "$LG_RC" "_lg_provisional_in_range exits 0"
  assert_eq "$(printf 'x-~0000\tdocs/issues/r.md\nx-~%s\tdocs/issues/n.md\n' "$h" | sort)" \
    "$(printf '%s\n' "$LG_OUT" | sort)" "both provisional keys the range adds"
  lg_call _lg_provisional_in_range "HEAD..HEAD"
  assert_eq "0|" "$LG_RC|$LG_OUT" "an empty range adds none"
  lg finalize
  assert_eq "2" "$LG_RC" "cas finalize offline → rc 2 (never another provisional key)"
  assert_contains "$(cat docs/issues/n.md)" "key: x-~$h" "…nothing rewritten"
  git remote set-url origin "$LG_REMOTE"
  lg new --finalize --file docs/issues/n.md
  assert_eq "0" "$LG_RC" "new --finalize for one file"
  assert_contains "$LG_OUT" "x-~$h → x-1" "n.md's key finalized"
  assert_contains "$(cat docs/issues/n.md)" "key: x-1" "n.md rewritten"
  assert_contains "$(cat docs/issues/r.md)" "relates: [depends-on:x-1]" "a reference in another item rewritten"
  assert_contains "$(cat docs/issues/r.md)" "key: x-~0000" "…but only n.md's key was finalized"
  lg finalize --all
  assert_eq "0" "$LG_RC" "finalize --all"
  assert_contains "$(cat docs/issues/r.md)" "key: x-2" "r.md's key"
  assert_eq "{
  \"x-~0000\": \"x-2\",
  \"x-~$h\": \"x-1\"
}" "$(cat docs/ledger/finalized.json)" "finalized.json, sorted"
  assert_true "cas mode commits nothing" test -n "$(git status --porcelain docs/issues/n.md)"
  teardown
}

test_lg_finalize_refuses_reused_provisional_key() {
  echo "test: a provisional key finalized.json records for another item's key is refused, not reused"
  lg_keys_fixture
  lg_item docs/issues/a.md "key: x-3" "ledger: x" "status: Open" "summary: Old item"
  lg_item docs/issues/r.md "key: y-1" "ledger: y" "status: Open" "summary: Refers" "relates: [sibling:x-~abcd]"
  printf '{\n  "x-~abcd": "x-3"\n}\n' > docs/ledger/finalized.json
  git add -A && git commit -qm items && git push -q origin main && git fetch -q origin
  lg_item docs/issues/n.md "key: x-~abcd" "ledger: x" "status: Open" "summary: New item, same provisional key"
  local hn hr hf
  hn=$(hash_file docs/issues/n.md)
  hr=$(hash_file docs/issues/r.md)
  hf=$(hash_file docs/ledger/finalized.json)
  lg finalize
  assert_eq "2" "$LG_RC" "refused (2)"
  assert_contains "$LG_ERR" "ledger assign docs/issues/n.md" "…suggesting ledger assign"
  assert_eq "$hn|$hr|$hf" "$(hash_file docs/issues/n.md)|$(hash_file docs/issues/r.md)|$(hash_file docs/ledger/finalized.json)" \
    "nothing written"
  assert_eq "absent" "$(lg_remote_counters)" "nothing allocated"
  lg new --finalize --file docs/issues/n.md
  assert_eq "2" "$LG_RC" "new --finalize: refused too"
  lg assign docs/issues/n.md x
  assert_eq "0" "$LG_RC" "ledger assign gives it a new key"
  assert_eq "x-4  docs/issues/n.md  (was x-~abcd)" "$LG_OUT" "x-4"
  assert_contains "$LG_ERR" "another item" "…with a warning"
  assert_eq "$hr|$hf" "$(hash_file docs/issues/r.md)|$(hash_file docs/ledger/finalized.json)" \
    "the record and the old item's references are left alone"
  assert_not_contains "$(cat docs/issues/n.md)" "aliases" "no provisional alias"
  # A record whose key no item carries is a finalize cut short: assign to
  # another ledger waits for it (nothing allocated); the same ledger finishes it.
  lg_item docs/issues/e.md "key: x-~eeee" "ledger: x" "status: Open" "summary: Cut short"
  jq -S '. + {"x-~eeee": "x-9"}' docs/ledger/finalized.json > docs/ledger/f.tmp && mv docs/ledger/f.tmp docs/ledger/finalized.json
  lg assign docs/issues/e.md y
  assert_eq "2" "$LG_RC" "assign to another ledger: refused (2)"
  assert_contains "$LG_ERR" "cut short" "…saying why"
  assert_eq '{"x":5,"y":2}' "$(lg_remote_counters)" "…before allocating (the counters as the first assign left them)"
  lg assign docs/issues/e.md x
  assert_eq "0" "$LG_RC" "assign to its own ledger completes the finalize"
  assert_contains "$(cat docs/issues/e.md)" "key: x-9" "…with the recorded key"
  teardown
}

test_lg_finalize_crash_safe_and_resumable() {
  echo "test: finalize checks every file before writing; a run cut short completes with the same keys"
  lg_keys_fixture
  lg_item docs/issues/n.md "key: x-~aaaa" "ledger: x" "status: Open" "summary: New"
  lg_item docs/issues/a.md "key: y-1" "ledger: y" "status: Open" "summary: A" "relates: [sibling:x-~aaaa]"
  lg_item docs/issues/b.md "key: y-2" "ledger: y" "status: Open" "summary: B" "relates: [sibling:x-~aaaa]" \
    "relates: [depends-on:x-~aaaa]"
  local hn ha hb
  hn=$(hash_file docs/issues/n.md)
  ha=$(hash_file docs/issues/a.md)
  hb=$(hash_file docs/issues/b.md)
  lg finalize
  assert_eq "2" "$LG_RC" "a rejected field in the second file → 2"
  assert_contains "$LG_ERR" "docs/issues/b.md" "…naming the file"
  assert_eq "$hn|$ha|$hb" "$(hash_file docs/issues/n.md)|$(hash_file docs/issues/a.md)|$(hash_file docs/issues/b.md)" \
    "nothing was rewritten"
  assert_file_not_exists docs/ledger/finalized.json "nothing recorded"
  assert_eq "absent" "$(lg_remote_counters)" "nothing allocated"
  lg_item docs/issues/b.md "key: y-2" "ledger: y" "status: Open" "summary: B" "relates: [depends-on:x-~aaaa]"
  lg finalize
  assert_eq "0" "$LG_RC" "fixed: finalize completes"
  assert_contains "$LG_OUT" "x-~aaaa → x-1" "x-1"
  assert_contains "$(cat docs/issues/b.md)" "relates: [depends-on:x-1]" "b.md rewritten"
  assert_contains "$(cat docs/issues/a.md)" "relates: [sibling:x-1]" "a.md rewritten"
  # A run cut short after recording finalized.json: the re-run reuses the
  # recorded key and allocates nothing.
  lg_item docs/issues/o.md "key: x-~bbbb" "ledger: x" "status: Open" "summary: Other"
  lg_item docs/issues/c.md "key: y-3" "ledger: y" "status: Open" "summary: C" "relates: [sibling:x-~bbbb]"
  jq -S '. + {"x-~bbbb": "x-7"}' docs/ledger/finalized.json > docs/ledger/f.tmp && mv docs/ledger/f.tmp docs/ledger/finalized.json
  lg_call _lg_resolve "x-~bbbb"
  assert_eq "0|docs/issues/o.md" "$LG_RC|$LG_OUT" "the intermediate state resolves"
  lg finalize
  assert_eq "0" "$LG_RC" "the re-run completes"
  assert_contains "$LG_OUT" "x-~bbbb → x-7" "…with the recorded key"
  assert_contains "$(cat docs/issues/o.md)" "key: x-7" "o.md"
  assert_contains "$(cat docs/issues/c.md)" "relates: [sibling:x-7]" "c.md"
  assert_eq '{"x":2}' "$(lg_remote_counters)" "nothing allocated again"
  # A reference an interrupted run left behind is rewritten too.
  lg_item docs/issues/d.md "key: y-4" "ledger: y" "status: Open" "summary: D" "relates: [sibling:x-~aaaa]"
  lg finalize
  assert_eq "0" "$LG_RC" "no provisional keys, one stale reference"
  assert_contains "$(cat docs/issues/d.md)" "relates: [sibling:x-1]" "d.md rewritten"
  assert_contains "$LG_OUT" "references" "…and said so"
  teardown
}

# --- Task 7: validate --staged | --all | --plan | --pushed -------------------------

# lg_v_fixture [config-json]: lg_fixture + config + the x/y/old registry,
# committed (no remote).
lg_v_fixture() {
  local c='{}'
  if [ $# -gt 0 ]; then c=$1; fi
  lg_fixture
  lg_enable "$c"
  lg_registry "$LG_REG_XY"
  git add -A && git commit -qm ledger
}

# lg_vf: the findings of the last JSON verdict as "<class> <severity> <path|key>"
# lines, sorted ("invalid" when it is not a verdict with findings).
lg_vf() {
  jq -r '.findings[] | "\(.class) \(.severity) \(.path // .key)"' <<<"$LG_OUT" 2>/dev/null | LC_ALL=C sort \
    || echo invalid
}

# lg_vfb: lg_vf, blocking findings only.
lg_vfb() {
  lg_vf | grep ' block ' || true
}

# lg_resolved <file> <text>: append a "## Resolution" section to an item.
lg_resolved() {
  printf '\n## Resolution\n\n%s\n' "$2" >> "$1"
}

test_lg_validate_staged_clean() {
  echo "test: validate --staged: nothing staged, a well-formed added item, a staged registry"
  lg_v_fixture
  lg_item docs/issues/a.md "key: x-1" "ledger: x" "status: Open" "summary: An existing item"
  git add -A && git commit -qm a
  lg validate --staged --format json
  assert_eq "0" "$LG_RC" "nothing staged: exit 0"
  assert_eq "1" "$(json_count "$LG_OUT")" "one object"
  assert_json_field "$LG_OUT" '.findings | length' "0" "no findings"
  assert_json_field "$LG_OUT" '.verb' "ledger validate" ".verb"
  lg_item docs/issues/b.md "key: x-2" "ledger: x" "status: Open" "summary: A new item, well formed"
  lg_item docs/issues/u.md "ledger: unassigned" "status: Open" "summary: Home undecided, no key yet"
  lg_item docs/issues/p.md "key: y-~0a1f" "ledger: y" "status: Open" "summary: A provisional key is a key"
  printf 'notes\n' > docs/notes.md
  git add -A
  lg validate --staged --format json
  assert_eq "0" "$LG_RC" "well-formed added items: exit 0"
  assert_eq "" "$(lg_vf)" "no findings"
  lg validate --staged
  assert_eq "0|" "$LG_RC|$LG_OUT" "text mode: nothing printed"
  git commit -qm b
  # The registry staged: --registry runs too.
  lg_registry '{"schema":"ledger-registry/1","ledgers":[
    {"id":"x","title":"X","kind":"service","status":"active"},
    {"id":"x","title":"X again","kind":"service","status":"active"}]}'
  git add docs/ledger/ledgers.json
  lg validate --staged --format json
  assert_eq "1" "$LG_RC" "a staged registry with a duplicate id: exit 1"
  assert_contains "$(lg_vf)" "registry block" "…a registry finding, blocking"
  lg validate --staged
  assert_contains "$LG_OUT" "registry duplicate-id x is the id of 2 ledgers" "text: the --registry line"
  # The working copy of the registry is not what is checked.
  lg_registry "$LG_REG_XY"
  lg validate --staged
  assert_eq "1" "$LG_RC" "the staged registry is checked, not the working copy"
  git add docs/ledger/ledgers.json
  lg validate --staged
  assert_eq "0" "$LG_RC" "registry restored and staged: exit 0"
  lg validate --staged --all
  assert_eq "3" "$LG_RC" "two modes: usage (3)"
  lg validate --pushed
  assert_eq "3" "$LG_RC" "--pushed without a range: usage (3)"
  teardown
}

test_lg_validate_staged_bad_key() {
  echo "test: validate --staged: a key that is neither <ledger>-<n> nor <ledger>-~<hex4> blocks"
  lg_v_fixture
  lg_item docs/issues/a.md "key: x-01" "ledger: x" "status: Open" "summary: Leading zero in the number"
  lg_item docs/issues/b.md "key: X-2" "ledger: x" "status: Open" "summary: Upper case is not a key"
  lg_item docs/issues/c.md "key: x-~zz12" "ledger: x" "status: Open" "summary: Not hex in the provisional"
  lg_item docs/issues/d.md "key: [x-3, x-4]" "ledger: x" "status: Open" "summary: Two keys in a list"
  git add -A
  lg validate --staged --format json
  assert_eq "1" "$LG_RC" "exit 1"
  assert_eq "bad-key block docs/issues/a.md
bad-key block docs/issues/b.md
bad-key block docs/issues/c.md
bad-key block docs/issues/d.md" "$(lg_vf)" "each bad key"
  teardown
}

test_lg_validate_staged_dup_key() {
  echo "test: validate --staged: a key another item already carries blocks; a pre-existing duplicate a commit merely touches is advisory"
  lg_v_fixture
  lg_item docs/issues/a.md "key: x-1" "ledger: x" "status: Open" "summary: The first item with x-1"
  lg_item docs/issues/c.md "key: x-5" "ledger: x" "status: Open" "summary: An old duplicate, one side"
  lg_item docs/issues/d.md "key: x-5" "ledger: x" "status: Open" "summary: An old duplicate, other side"
  git add -A && git commit -qm items
  lg_item docs/issues/b.md "key: x-1" "ledger: x" "status: Open" "summary: A second item with x-1"
  git add -A
  lg validate --staged --format json
  assert_eq "1" "$LG_RC" "exit 1"
  assert_eq "duplicate-key block docs/issues/b.md" "$(lg_vf)" "the added item is reported (the untouched one is not)"
  assert_contains "$(jq -r '.findings[0].detail' <<<"$LG_OUT")" "docs/issues/a.md" "the detail names the other item"
  assert_json_field "$LG_OUT" '.findings[0].key' "x-1" ".key"
  git reset -q
  # Case does not make a key different.
  lg_item docs/issues/b.md "key: y-1" "ledger: y" "status: Open" "summary: A second item, other ledger" "aliases: [X-1]"
  git add -A
  lg validate --staged --format json
  assert_eq "duplicate-key block docs/issues/b.md" "$(lg_vf)" "an alias X-1 collides with the key x-1"
  git reset -q
  rm docs/issues/b.md
  # c.md's body changes; its key is old, and so is d.md's.
  printf '\nMore detail.\n' >> docs/issues/c.md
  git add -A
  lg validate --staged --format json
  assert_eq "0" "$LG_RC" "a pre-existing duplicate a commit merely touches: exit 0"
  assert_eq "duplicate-key advisory docs/issues/c.md" "$(lg_vf)" "…reported as advisory"
  lg validate --staged
  assert_contains "$LG_OUT" "(advisory)" "text marks it advisory"
  # Renaming d.md gives it no new key: still advisory.
  git mv docs/issues/d.md docs/issues/d2.md
  lg validate --staged --format json
  assert_eq "0" "$LG_RC" "a renamed item keeps its old key: exit 0"
  teardown
}

test_lg_validate_staged_alias_collision() {
  echo "test: validate --staged: keys and aliases are one namespace"
  lg_v_fixture
  lg_item docs/issues/a.md "key: x-1" "ledger: x" "status: Open" "summary: Alpha, re-homed from y" "aliases: [y-3]"
  git add -A && git commit -qm a
  lg_item docs/issues/b.md "key: y-3" "ledger: y" "status: Open" "summary: Bravo takes a retired key"
  lg_item docs/issues/c.md "key: x-9" "ledger: x" "status: Open" "summary: Charlie claims x-1 as an alias" "aliases:" "  - x-1"
  git add -A
  lg validate --staged --format json
  assert_eq "1" "$LG_RC" "exit 1"
  assert_eq "duplicate-key block docs/issues/b.md
duplicate-key block docs/issues/c.md" "$(lg_vf)" "a key equal to an alias, an alias equal to a key"
  assert_contains "$(jq -r '.findings[] | select(.path == "docs/issues/b.md") | .detail' <<<"$LG_OUT")" "alias" \
    "the detail says the other side is an alias"
  teardown
}

test_lg_validate_staged_unknown_ledger() {
  echo "test: validate --staged: ledger must be an active registered id or unassigned; a retired ledger takes no new items"
  lg_v_fixture
  lg_item docs/issues/r.md "key: old-1" "ledger: old" "status: Open" "summary: Filed before old was retired"
  lg_item docs/issues/t.md "key: Typo-1" "ledger: typo" "status: Open" "summary: Committed past the hook"
  git add -A && git commit -qm r
  lg_item docs/issues/a.md "key: zz-1" "ledger: zz" "status: Open" "summary: An unregistered ledger"
  lg_item docs/issues/b.md "key: old-2" "ledger: old" "status: Open" "summary: A new item in a retired ledger"
  lg_item docs/issues/c.md "ledger: unassigned" "status: Open" "summary: Unassigned is always fine"
  printf '\nA log line.\n' >> docs/issues/r.md
  printf '\nA log line.\n' >> docs/issues/t.md
  git add -A
  lg validate --staged --format json
  assert_eq "1" "$LG_RC" "exit 1"
  assert_eq "bad-key advisory docs/issues/t.md
retired-ledger advisory docs/issues/r.md
retired-ledger block docs/issues/b.md
unknown-ledger advisory docs/issues/t.md
unknown-ledger block docs/issues/a.md" "$(lg_vf)" "unknown blocks; retired blocks an added item, advises on a modified one; unchanged bad values are advisory"
  git reset -q
  lg_item docs/issues/t.md "key: typo-1" "ledger: typo2" "status: Open" "summary: Committed past the hook"
  git add docs/issues/t.md
  lg validate --staged --format json
  assert_eq "1|unknown-ledger block docs/issues/t.md" "$LG_RC|$(lg_vfb)" "a changed ledger value is held to the check"
  teardown
}

test_lg_validate_staged_added_needs_fields() {
  echo "test: validate --staged: an added item carries ledger and summary; a modified one that lacks them is advisory"
  lg_v_fixture
  lg_item docs/issues/old.md "status: Open"
  git add -A && git commit -qm old
  lg_item docs/issues/new.md "status: Open"
  printf '# No frontmatter at all\n' > docs/issues/bare.md
  printf '\nEdited.\n' >> docs/issues/old.md
  git add -A
  lg validate --staged --format json
  assert_eq "1" "$LG_RC" "exit 1"
  assert_eq "missing-ledger advisory docs/issues/old.md
missing-ledger block docs/issues/bare.md
missing-ledger block docs/issues/new.md
missing-summary advisory docs/issues/old.md
missing-summary block docs/issues/bare.md
missing-summary block docs/issues/new.md" "$(lg_vf)" "added: blocking; modified: advisory"
  git reset -q
  rm docs/issues/new.md docs/issues/bare.md
  git add -A
  lg validate --staged
  assert_eq "0" "$LG_RC" "only the pre-existing item: exit 0"
  # An archive move is a rename, not an added item.
  git commit -qm edit
  mkdir -p docs/archive/issues
  git mv docs/issues/old.md docs/archive/issues/old.md
  lg validate --staged --format json
  assert_eq "0" "$LG_RC" "a pre-existing item moved to the archive: exit 0"
  teardown
}

test_lg_validate_staged_modified_legacy_ok() {
  echo "test: validate --staged: a legacy_ids ledger is advisory on a modified item, blocking on an added one"
  lg_v_fixture '{"legacy_ids":["checkout-old"]}'
  lg_item docs/issues/a.md "key: x-1" "ledger: checkout-old" "status: Open" "summary: Filed before the re-split"
  git add -A && git commit -qm a
  printf '\nA log line.\n' >> docs/issues/a.md
  git add -A
  lg validate --staged --format json
  assert_eq "0" "$LG_RC" "modified: exit 0"
  assert_eq "legacy-ledger-id advisory docs/issues/a.md" "$(lg_vf)" "…an advisory"
  lg validate --staged
  assert_contains "$LG_OUT" "ledger assign" "the advisory names the remedy"
  lg_item docs/issues/b.md "key: x-2" "ledger: checkout-old" "status: Open" "summary: A new item in a legacy ledger"
  git add -A
  lg validate --staged --format json
  assert_eq "1" "$LG_RC" "added: exit 1"
  assert_contains "$(lg_vf)" "legacy-ledger-id block docs/issues/b.md" "…blocking"
  teardown
}

test_lg_validate_staged_reads_staged_blob() {
  echo "test: validate --staged reads the staged blobs, not the working copies"
  lg_v_fixture
  lg_item docs/issues/a.md "key: x-1" "ledger: x" "status: Open" "summary: The first item with x-1"
  git add -A && git commit -qm a
  lg_item docs/issues/b.md "key: x-1" "ledger: x" "status: Open" "summary: A clash, staged"
  git add -A
  lg_item docs/issues/b.md "key: x-2" "ledger: x" "status: Open" "summary: Fixed in the work tree only"
  lg validate --staged
  assert_eq "1" "$LG_RC" "worktree fixed, staged still bad: exit 1"
  git add -A
  lg validate --staged
  assert_eq "0" "$LG_RC" "the fix staged: exit 0"
  lg_item docs/issues/b.md "key: x-1" "ledger: x" "status: Open" "summary: Broken in the work tree only"
  lg validate --staged
  assert_eq "0" "$LG_RC" "staged good, worktree bad: exit 0"
  # An unstaged item in the work tree is not in the staged index.
  lg_item docs/issues/c.md "key: x-2" "ledger: x" "status: Open" "summary: Untracked clash"
  lg validate --staged
  assert_eq "0" "$LG_RC" "an untracked clash is not staged: exit 0"
  teardown
}

test_lg_validate_staged_superseded_dangling() {
  echo "test: validate --staged: superseded_by must resolve to an item"
  lg_v_fixture
  lg_item docs/issues/a.md "key: x-1" "ledger: x" "status: Closed" "summary: Replaced by a missing item" "superseded_by: x-99"
  lg_resolved docs/issues/a.md "Superseded."
  git add -A
  lg validate --staged --format json
  assert_eq "1" "$LG_RC" "exit 1"
  assert_eq "superseded-dangling block docs/issues/a.md" "$(lg_vf)" "dangling"
  # Through finalized.json: a provisional key that became x-2.
  lg_item docs/issues/b.md "key: x-2" "ledger: x" "status: Open" "summary: The replacement"
  printf '{"x-~beef":"x-2"}\n' > docs/ledger/finalized.json
  lg_item docs/issues/a.md "key: x-1" "ledger: x" "status: Closed" "summary: Replaced, provisional name" "superseded_by: x-~beef"
  lg_resolved docs/issues/a.md "Superseded."
  git add -A
  lg validate --staged --format json
  assert_eq "0" "$LG_RC" "a finalized provisional key resolves: exit 0"
  teardown
}

test_lg_validate_staged_cycle() {
  echo "test: validate --staged: a supersession cycle blocks"
  lg_v_fixture
  lg_item docs/issues/a.md "key: x-1" "ledger: x" "status: Closed" "summary: A says B replaces it" "superseded_by: x-2"
  lg_resolved docs/issues/a.md "Superseded."
  lg_item docs/issues/b.md "key: x-2" "ledger: x" "status: Closed" "summary: B says A replaces it" "superseded_by: x-1"
  lg_resolved docs/issues/b.md "Superseded."
  lg_item docs/issues/c.md "key: x-3" "ledger: x" "status: Closed" "summary: C replaces itself" "superseded_by: X-3"
  lg_resolved docs/issues/c.md "Superseded."
  git add -A
  lg validate --staged --format json
  assert_eq "1" "$LG_RC" "exit 1"
  assert_eq "superseded-cycle block docs/issues/a.md
superseded-cycle block docs/issues/b.md
superseded-cycle block docs/issues/c.md" "$(lg_vf)" "each item on a cycle"
  assert_contains "$(jq -r '.findings[] | select(.path == "docs/issues/a.md") | .detail' <<<"$LG_OUT")" "x-1 → x-2 → x-1" \
    "the detail shows the cycle by key"
  teardown
}

test_lg_validate_staged_chain_ends_superseded() {
  echo "test: validate --staged: a supersession chain is allowed (advisory: repoint to its end); a dead end is advisory"
  lg_v_fixture
  lg_item docs/issues/c.md "key: x-3" "ledger: x" "status: Closed" "summary: C, replaced by D" "superseded_by: x-4"
  lg_resolved docs/issues/c.md "Superseded by x-4."
  lg_item docs/issues/d.md "key: x-4" "ledger: x" "status: Open" "summary: D, the item in effect"
  lg_item docs/issues/w.md "key: x-5" "ledger: x" "status: Won't fix" "summary: W, dropped"
  lg_resolved docs/issues/w.md "Not worth it."
  lg_item docs/issues/b.md "key: x-6" "ledger: x" "status: Closed" "summary: B, replaced by a missing item" "superseded_by: x-404"
  lg_resolved docs/issues/b.md "Superseded."
  git add -A && git commit -qm items --no-verify
  # A → C → D: allowed; the advisory names the end.
  lg_item docs/issues/a.md "key: x-1" "ledger: x" "status: Closed" "summary: A points at C" "superseded_by: x-3"
  lg_resolved docs/issues/a.md "Superseded."
  git add -A
  lg validate --staged --format json
  assert_eq "0" "$LG_RC" "a chain: exit 0"
  assert_eq "superseded-chain advisory docs/issues/a.md" "$(lg_vf)" "…an advisory"
  assert_contains "$(jq -r '.findings[0].detail' <<<"$LG_OUT")" "x-3 → x-4" "the detail shows the chain"
  assert_contains "$(jq -r '.findings[0].detail' <<<"$LG_OUT")" "point it at x-4" "…and suggests its end"
  # A → D: the item in effect, nothing to say.
  lg_item docs/issues/a.md "key: x-1" "ledger: x" "status: Closed" "summary: A points at D" "superseded_by: x-4"
  lg_resolved docs/issues/a.md "Superseded."
  git add -A
  lg validate --staged
  assert_eq "0|" "$LG_RC|$LG_OUT" "pointing at the item in effect: exit 0, nothing printed"
  # A → W (won't fix): a dead end.
  lg_item docs/issues/a.md "key: x-1" "ledger: x" "status: Closed" "summary: A points at W" "superseded_by: x-5"
  lg_resolved docs/issues/a.md "Superseded."
  git add -A
  lg validate --staged --format json
  assert_eq "0|superseded-dead-end advisory docs/issues/a.md" "$LG_RC|$(lg_vf)" "a dead end: exit 0, an advisory"
  # A → B → (missing): the chain's end is B, the break is named; B is a dead end.
  lg_item docs/issues/a.md "key: x-1" "ledger: x" "status: Closed" "summary: A points at B" "superseded_by: x-6"
  lg_resolved docs/issues/a.md "Superseded."
  git add -A
  lg validate --staged --format json
  assert_eq "0" "$LG_RC" "a chain broken further on: exit 0 (only A's own target must resolve)"
  assert_eq "superseded-chain advisory docs/issues/a.md
superseded-dead-end advisory docs/issues/a.md" "$(lg_vf)" "a chain and a dead end"
  assert_contains "$(jq -r '.findings[] | select(.class == "superseded-chain") | .detail' <<<"$LG_OUT")" "breaks at x-6" \
    "the detail says where the chain breaks"
  assert_contains "$(jq -r '.findings[] | select(.class == "superseded-chain") | .detail' <<<"$LG_OUT")" "x-404" "…and on what"
  teardown
}

test_lg_validate_staged_missing_resolution() {
  echo "test: validate --staged: an item whose status changes to closed or won't fix needs a resolution"
  lg_v_fixture
  lg_item docs/issues/a.md "key: x-1" "ledger: x" "status: Open" "summary: Will be closed"
  lg_item docs/issues/b.md "key: x-2" "ledger: x" "status: In progress" "summary: Will be dropped"
  lg_item docs/issues/c.md "key: x-3" "ledger: x" "status: Closed" "summary: Closed long ago, no resolution"
  git add -A && git commit -qm items
  lg_item docs/issues/a.md "key: x-1" "ledger: x" "status: Closed" "summary: Will be closed"
  lg_item docs/issues/b.md "key: x-2" "ledger: x" "status: Won't Fix" "summary: Will be dropped"
  printf '\nA log line.\n' >> docs/issues/c.md
  git add -A
  lg validate --staged --format json
  assert_eq "1" "$LG_RC" "exit 1"
  assert_eq "missing-resolution advisory docs/issues/c.md
missing-resolution block docs/issues/a.md
missing-resolution block docs/issues/b.md" "$(lg_vf)" "a status change blocks; an old closed item is advisory"
  lg_resolved docs/issues/a.md "Done in abc123."
  printf '\n## Resolution\n\n' >> docs/issues/b.md
  git add -A
  lg validate --staged --format json
  assert_eq "missing-resolution advisory docs/issues/c.md
missing-resolution block docs/issues/b.md" "$(lg_vf)" "an empty resolution section is still missing"
  lg_item docs/issues/b.md "key: x-2" "ledger: x" "status: Won't Fix" "summary: Will be dropped"
  lg_resolved docs/issues/b.md "Not worth it."
  git add -A
  lg validate --staged
  assert_eq "0" "$LG_RC" "resolutions written: exit 0"
  teardown
}

test_lg_validate_staged_superseded_not_closed() {
  echo "test: validate --staged: superseded_by on an item that is not closed blocks"
  lg_v_fixture
  lg_item docs/issues/a.md "key: x-1" "ledger: x" "status: Open" "summary: The item in effect"
  git add -A && git commit -qm a
  lg_item docs/issues/b.md "key: x-2" "ledger: x" "status: Open" "summary: Open but superseded" "superseded_by: x-1"
  lg_item docs/issues/c.md "key: x-3" "ledger: x" "status: Won't fix" "summary: Won't fix is not closed" "superseded_by: x-1"
  lg_resolved docs/issues/c.md "Dropped."
  git add -A
  lg validate --staged --format json
  assert_eq "1" "$LG_RC" "exit 1"
  assert_eq "superseded-not-closed block docs/issues/b.md
superseded-not-closed block docs/issues/c.md" "$(lg_vf)" "open and won't-fix items with superseded_by"
  teardown
}

test_lg_validate_staged_text_one_line() {
  echo "test: validate text: one line per finding; a name with a control character is JSON-quoted"
  lg_v_fixture
  lg_item "docs/issues/t$(printf '\t')ab.md" "status: Open"
  lg_item "docs/issues/n"$'\n'"l.md" "status: Open"
  lg_item "docs/issues/sp ace é.md" "status: Open"
  git add -A
  lg validate --staged --format json
  local n
  n=$(jq '.findings | length' <<<"$LG_OUT")
  lg validate --staged
  assert_eq "1" "$LG_RC" "exit 1"
  assert_true "several findings" test "$n" -ge 6
  assert_eq "$n" "$(printf '%s\n' "$LG_OUT" | wc -l | tr -d ' ')" "one line per finding"
  assert_contains "$LG_OUT" 'missing-ledger "docs/issues/t\tab.md"' "a tab: JSON-quoted"
  assert_contains "$LG_OUT" 'missing-ledger "docs/issues/n\nl.md"' "a newline: JSON-quoted"
  assert_contains "$LG_OUT" "missing-ledger docs/issues/sp ace é.md" "spaces and unicode: as they are"
  teardown
}

test_lg_validate_staged_unborn() {
  echo "test: validate --staged on an unborn branch: every staged item is added"
  lg_v_fixture
  lg_item docs/issues/a.md "key: x-1" "ledger: x" "status: Open" "summary: A complete item, staged"
  lg_item docs/issues/b.md "status: Open"
  git checkout -q --orphan fresh
  git add -A
  lg validate --staged --format json
  assert_eq "1" "$LG_RC" "exit 1"
  assert_eq "missing-ledger block docs/issues/b.md
missing-summary block docs/issues/b.md" "$(lg_vf)" "b.md is added; a.md is fine"
  teardown
}

test_lg_validate_staged_keymap_reads_frontmatter() {
  echo "test: validate --staged: the key map reads keys and aliases as the parser does (frontmatter only; BOM, CRLF, quotes, lists)"
  lg_v_fixture
  # Not keys: a body line, an unterminated frontmatter, a file that does not
  # start with ---.
  lg_item docs/issues/body.md "key: x-1" "ledger: x" "status: Open" "summary: The key x-1 lives here"
  printf '\nkey: x-2\naliases: [x-3]\n' >> docs/issues/body.md
  printf -- '---\nkey: x-4\nledger: x\n' > docs/issues/unterminated.md
  printf '# Title\n---\nkey: x-5\n---\n' > docs/issues/late.md
  # Keys: BOM + CRLF, quoted, a block list of aliases (indented and at column
  # 0), a flow list.
  printf '%s---\r\nkey: x-6\r\nledger: x\r\nsummary: BOM and CRLF item here\r\n---\r\n# T\r\n' "$LG_BOM" > docs/issues/crlf.md
  lg_item docs/issues/quoted.md 'key: "x-7"' "ledger: x" "status: Open" "summary: A quoted key is a key"
  lg_item docs/issues/block.md "key: x-8" "ledger: x" "status: Open" "aliases:" "  - y-1" "- y-2" "summary: Block list aliases"
  lg_item docs/issues/flow.md "key: x-9" "ledger: x" "status: Open" "aliases: ['y-3', y-4] # a comment" "summary: Flow list aliases"
  lg_item docs/issues/other.md "key: x-10" "ledger: x" "relates:" "  - sibling:y-5" "status: Open" "summary: A list under another field"
  # A block list with a comment and a blank line inside it (the parser keeps
  # every item).
  lg_item docs/issues/gap.md "key: x-11" "ledger: x" "status: Open" "aliases:" "  - x-17" "  # retired alias below" "  - x-18" "" \
    "  - x-19" "summary: Aliases with gaps"
  git add -A && git commit -qm items
  local k
  for k in x-2 x-3 x-4 x-5 y-5; do
    lg_item docs/issues/new.md "key: $k" "ledger: x" "status: Open" "summary: A new item, no clash"
    git add -A
    lg validate --staged
    assert_eq "0" "$LG_RC" "$k is not a key or alias of a committed item"
    git reset -q
  done
  for k in x-1 x-6 x-7 y-1 y-2 y-3 y-4 x-10 x-17 x-18 x-19; do
    lg_item docs/issues/new.md "key: $k" "ledger: x" "status: Open" "summary: A new item that clashes"
    git add -A
    lg validate --staged --format json
    assert_eq "1|duplicate-key block docs/issues/new.md" "$LG_RC|$(lg_vfb)" "$k clashes"
    git reset -q
  done
  # superseded_by naming an alias after a gap resolves (the whole blob is
  # parsed): no dangling finding.
  lg_item docs/issues/new.md "key: x-30" "ledger: x" "status: Closed" "summary: Replaced by gap.md" "superseded_by: x-19"
  lg_resolved docs/issues/new.md "Superseded."
  git add -A
  lg validate --staged
  assert_eq "0|" "$LG_RC|$LG_OUT" "superseded_by an alias after a blank line resolves"
  git reset -q
  teardown
}

test_lg_validate_staged_keymap_reads_index() {
  echo "test: validate --staged: an unstaged change to a tracked item does not count — the index does"
  lg_v_fixture
  lg_item docs/issues/a.md "key: x-1" "ledger: x" "status: Open" "summary: Committed with x-1"
  git add -A && git commit -qm a
  # The work tree says x-5; the index (and HEAD) still say x-1.
  lg_item docs/issues/a.md "key: x-5" "ledger: x" "status: Open" "summary: Edited, not staged"
  lg_item docs/issues/b.md "key: x-1" "ledger: x" "status: Open" "summary: Clashes with the staged x-1"
  git add docs/issues/b.md
  lg validate --staged --format json
  assert_eq "1|duplicate-key block docs/issues/b.md" "$LG_RC|$(lg_vfb)" "the index's x-1 clashes"
  git reset -q
  lg_item docs/issues/b.md "key: x-5" "ledger: x" "status: Open" "summary: Takes the work tree's x-5"
  git add docs/issues/b.md
  lg validate --staged
  assert_eq "0" "$LG_RC" "the work tree's unstaged x-5 does not clash"
  teardown
}

test_lg_validate_staged_keymap_newline_path() {
  echo "test: validate --staged: a tracked item whose name holds a newline is left out of the key map, with a note"
  lg_v_fixture
  lg_item "docs/issues/a"$'\n'"docs/issues/b.md" "key: x-1" "ledger: x" "status: Open" "summary: A name with a newline"
  lg_item docs/issues/b.md "key: x-2" "ledger: x" "status: Open" "summary: The real b.md"
  git add -A && git commit -qm items
  lg_item docs/issues/c.md "key: x-2" "ledger: x" "status: Open" "summary: Clashes with b.md"
  git add docs/issues/c.md
  lg validate --staged --format json
  assert_eq "1|duplicate-key block docs/issues/c.md" "$LG_RC|$(lg_vfb)" "x-2 clashes with b.md"
  assert_eq "the key of docs/issues/b.md" "$(jq -r '.findings[0].detail | sub(".*is also "; "")' <<<"$LG_OUT")" \
    "…and only with b.md (no line of the other name is read as b.md's)"
  assert_contains "$LG_ERR" "holds a newline" "a note on stderr"
  assert_eq "1" "$(printf '%s\n' "$LG_ERR" | grep -c 'holds a newline')" "…one line"
  git reset -q
  lg_item docs/issues/c.md "key: x-1" "ledger: x" "status: Open" "summary: Would clash, but that name is unreadable"
  git add docs/issues/c.md
  lg validate --staged
  assert_eq "0" "$LG_RC" "the newline name's key is not in the map (as the index leaves it unparsed)"
  teardown
}

test_lg_validate_all_advisories_rc0() {
  echo "test: validate --all: advisories alone exit 0; a blocking class exits 1"
  lg_v_fixture '{"legacy_ids":["legacy"]}'
  lg_item docs/issues/a.md "key: x-1" "ledger: x" "status: Open" "summary: A complete item with a contract" "changes: [field:a]"
  lg_item docs/issues/k.md "ledger: x" "status: Open" "summary: Keyless but in a real ledger" "consumes: [field:a]"
  lg_item docs/issues/l.md "status: Open" "summary: No ledger here, pre-existing" "changes: [field:b]"
  lg_item docs/issues/s.md "key: x-2" "ledger: x" "status: Fixed" "changes: [field:c]"
  lg_item docs/issues/w.md "key: x-3" "ledger: x" "status: Fixed" "summary: Too short" "changes: [field:d]"
  lg_item docs/issues/u.md "ledger: unassigned" "status: Open" "summary: Unassigned and still open" "changes: [field:e]"
  lg_item docs/issues/n.md "key: x-4" "ledger: x" "status: Open" "summary: Open and names no contract at all"
  lg_item docs/issues/p.md "key: x-5" "ledger: x" "status: Fixed" "summary: A nested map in a field" "changes: [field:f]" "owed:" "  a: b"
  lg_item docs/issues/g.md "key: x-6" "ledger: legacy" "status: Fixed" "summary: Filed under the legacy ledger" "changes: [field:g]"
  lg_item docs/issues/r.md "key: old-1" "ledger: old" "status: Open" "summary: Still open in a retired ledger" "changes: [field:h]"
  git add -A && git commit -qm items
  lg validate --all --format json
  assert_eq "0" "$LG_RC" "advisories only: exit 0"
  assert_eq "legacy-ledger-id advisory docs/issues/g.md
missing-key advisory docs/issues/k.md
missing-ledger advisory docs/issues/l.md
missing-summary advisory docs/issues/s.md
no-contract advisory docs/issues/n.md
parse-error advisory docs/issues/p.md
retired-ledger advisory docs/issues/r.md
unassigned-open advisory docs/issues/u.md
weak-summary advisory docs/issues/w.md" "$(lg_vf)" "each advisory class"
  lg validate --all
  assert_eq "9" "$(printf '%s\n' "$LG_OUT" | wc -l | tr -d ' ')" "text: one line each"
  # --all reads the working tree, and the blocking classes block.
  lg_item docs/issues/d.md "key: x-1" "ledger: zz" "status: Closed" "summary: A duplicate key in an unknown ledger" "superseded_by: x-404"
  lg validate --all --format json
  assert_eq "1" "$LG_RC" "blocking findings: exit 1"
  assert_contains "$(lg_vf)" "duplicate-key block docs/issues/a.md" "both sides of a duplicate"
  assert_contains "$(lg_vf)" "duplicate-key block docs/issues/d.md" "…both"
  assert_contains "$(lg_vf)" "unknown-ledger block docs/issues/d.md" "unknown ledger"
  assert_contains "$(lg_vf)" "missing-resolution block docs/issues/d.md" "missing resolution"
  assert_contains "$(lg_vf)" "superseded-dangling block docs/issues/d.md" "dangling superseded_by"
  lg validate --all --registry --format json
  assert_eq "1" "$LG_RC" "--registry beside --all"
  teardown
}

test_lg_validate_all_concurrent_merge_finalize_dup() {
  echo "test: validate catches the duplicate two maintainers' concurrent merge-mode finalize leave behind"
  lg_keys_fixture '{"base":"main","keys":{"mode":"merge"}}'
  local h1 h2 other
  lg_item docs/issues/a.md "key: x-3" "ledger: x" "status: Open" "summary: The highest key so far"
  git add -A && git commit -qm a && git push -q origin main
  other="$(harness_mktemp_d other)/other clone"
  lg_clone "$other"
  # Maintainer 1 merges n.md and finalizes it.
  h1=$(lg_hex4 docs/issues/n.md)
  lg_item docs/issues/n.md "key: x-~$h1" "ledger: x" "status: Open" "summary: First new item, provisional"
  git add -A && git commit -qm n
  lg finalize
  assert_eq "0" "$LG_RC" "maintainer 1 finalizes"
  assert_contains "$(cat docs/issues/n.md)" "key: x-4" "n.md → x-4"
  git push -q origin main
  # Maintainer 2, not yet pulled, merges o.md and finalizes it.
  (
    cd "$other"
    git config user.name Other && git config user.email other@example.com
    h2=$(lg_hex4 docs/issues/o.md)
    lg_item docs/issues/o.md "key: x-~$h2" "ledger: x" "status: Open" "summary: Second new item, provisional"
    git add -A && git commit -qm o
  )
  cd "$other"
  h2=$(lg_hex4 docs/issues/o.md)
  lg finalize
  assert_eq "0" "$LG_RC" "maintainer 2 finalizes"
  assert_contains "$(cat docs/issues/o.md)" "key: x-4" "o.md → x-4 too"
  # Both wrote finalized.json: the pull stops on it; the items merge cleanly.
  git pull -q --no-rebase --no-edit --no-commit origin main > /dev/null 2>&1 || true
  printf '{\n  "x-~%s": "x-4",\n  "x-~%s": "x-4"\n}\n' "$h1" "$h2" > docs/ledger/finalized.json
  git add docs/ledger/finalized.json
  lg validate --staged --format json
  assert_eq "1" "$LG_RC" "the merge, staged: exit 1"
  assert_eq "duplicate-key block docs/issues/n.md" "$(lg_vfb)" "the incoming item clashes"
  git commit -qm merge --no-verify
  lg validate --all --format json
  assert_eq "1" "$LG_RC" "--all after the merge: exit 1"
  assert_eq "duplicate-key block docs/issues/n.md
duplicate-key block docs/issues/o.md" "$(lg_vfb)" "both items carry x-4"
  teardown
}

test_lg_validate_plan_marks() {
  echo "test: validate --plan: every Related work row is marked include or exclude: <reason>"
  lg_v_fixture
  mkdir -p docs/plans
  cat > docs/plans/p.md <<'EOF'
# Plan

## Related work

| Item | Why related | Mark |
|---|---|---|
| x-1 | consumes field:a | include |
| x-2 | shares src/a.ts | exclude: already fixed |
| x-3 | a \| piped cell | Exclude: different layer |
| x-4 | candidate | |
| x-5 | candidate | exclude: |
| x-6 | candidate | maybe |

## Tasks

| Task | Mark |
|---|---|
| not a related-work row | |
EOF
  lg validate --plan docs/plans/p.md --format json
  assert_eq "0" "$LG_RC" "advisory: exit 0"
  assert_eq "bad-mark advisory docs/plans/p.md
bad-mark advisory docs/plans/p.md
unmarked advisory docs/plans/p.md" "$(lg_vf)" "an empty mark, an exclude without a reason, an unknown mark"
  assert_eq "x-4|x-5|x-6" "$(jq -r '[.findings[].key] | sort | join("|")' <<<"$LG_OUT")" "each names its item"
  lg validate --plan docs/plans/p.md --strict --format json
  assert_eq "1" "$LG_RC" "--strict: exit 1"
  assert_json_field "$LG_OUT" '[.findings[].severity] | unique | join(",")' "block" "--strict findings block"
  lg validate --plan docs/plans/p.md
  assert_contains "$LG_OUT" "unmarked docs/plans/p.md line 10: x-4: no mark" "text names the plan, the line and the item"
  printf '# Plan\n\nNo related work section.\n' > docs/plans/q.md
  lg validate --plan docs/plans/q.md --format json
  assert_eq "0|no-related-work advisory docs/plans/q.md" "$LG_RC|$(lg_vf)" "no section: an advisory"
  printf '# Plan\n\n## Related work\n\n| Item | Why related | Mark |\n|---|---|---|\n| x-1 | why | include |\n' > docs/plans/r.md
  lg validate --plan docs/plans/r.md --strict
  assert_eq "0|" "$LG_RC|$LG_OUT" "every row marked: exit 0, nothing printed"
  lg validate --plan docs/plans/missing.md
  assert_eq "2" "$LG_RC" "a missing plan: could not run (2)"
  lg validate --strict --all
  assert_eq "3" "$LG_RC" "--strict without --plan: usage (3)"
  teardown
}

test_lg_validate_pushed_range() {
  echo "test: validate --pushed <range>: cas refuses provisional keys a push introduces; merge mode never does"
  lg_keys_fixture
  local base h
  base=$(git rev-parse HEAD)
  lg_item docs/issues/a.md "key: x-1" "ledger: x" "status: Open" "summary: A real key"
  git add -A && git commit -qm a
  lg validate --pushed "$base..HEAD" --format json
  assert_eq "0" "$LG_RC" "no provisional key in the range: exit 0"
  assert_json_field "$LG_OUT" '.findings | length' "0" "no findings"
  h=$(lg_hex4 "docs/issues/n b.md")
  lg_item "docs/issues/n b.md" "key: x-~$h" "ledger: x" "status: Open" "summary: Filed offline"
  git add -A && git commit -qm n
  lg validate --pushed "$base..HEAD" --format json
  assert_eq "1" "$LG_RC" "a provisional key in the range: exit 1"
  assert_eq "provisional-key block docs/issues/n b.md" "$(lg_vf)" "the finding"
  assert_json_field "$LG_OUT" '.findings[0].key' "x-~$h" ".key"
  lg validate --pushed "0000000000000000000000000000000000000000..HEAD"
  assert_eq "1" "$LG_RC" "a new branch (zero base): exit 1"
  assert_contains "$LG_OUT" "x-~$h" "text names the key"
  assert_contains "$LG_OUT" "docs/issues/n b.md" "…and the file"
  lg validate --pushed "HEAD..HEAD"
  assert_eq "0" "$LG_RC" "an empty range: exit 0"
  lg validate --pushed "HEAD"
  assert_eq "3" "$LG_RC" "not a range: usage (3)"
  lg validate --pushed "no-such-rev..HEAD"
  assert_eq "2" "$LG_RC" "an unknown revision: could not run (2)"
  lg_enable '{"keys":{"mode":"merge"}}'
  lg validate --pushed "$base..HEAD" --format json
  assert_eq "0" "$LG_RC" "merge mode: exit 0"
  assert_json_field "$LG_OUT" '.findings | length' "0" "…no findings"
  teardown
}

# --- Task 8: renderers, view, publish ----------------------------------------------

# A hand-built index (schema ledger-index/1, the fields the renderers read):
# app — two clusters (field:order.total: app-2 P0 consumes, app-1 P1
# changes; component:Sheet: app-3 P2), unclustered app-4 (P1) and app-9
# (fixed, owed: P3), recently closed app-5 (touched 10-03), app-6 (closed
# long ago: dropped), superseded app-7 → app-1, won't fix app-8; core —
# core-1 (P0); an unassigned item (P1, no key); k.md on no ledger.
# shellcheck disable=SC2016  # JSON
LG_VIEW_IX='{"schema":"ledger-index/1","built":{},"ledgers":[
 {"id":"app","title":"App","kind":"service","status":"active","scope":"Cart to order",
  "contracts":[{"id":"field:order.total","title":"Order totals"}]},
 {"id":"core","title":"Core","kind":"platform","status":"active"},
 {"id":"old","title":"Old","kind":"service","status":"retired"}],
"items":[
 {"path":"docs/issues/a.md","key":"app-1","ledger":"app","status":"Open","class":"open","severity":"P1","date":"2026-09-01",
  "summary":"Totals are wrong","changes":["field:order.total"],"consumes":[],"h1":"Alpha title",
  "docs":{"spec":["docs/specs/s.md"],"plan":[],"handoff":["docs/handoffs/2026-10-01-a.md","docs/handoffs/2026-10-05-b.md"]},
  "derived":{"status":"spec'"'"'d","detail":"docs/specs/s.md"},"pr":null,"inflight":[],"neighbours":null,"resolution":null,"superseded_by":null,"owed":null},
 {"path":"docs/issues/b.md","key":"app-2","ledger":"app","status":"Open","class":"open","severity":"P0","date":"2026-09-05",
  "summary":"Receipts read the total","changes":[],"consumes":["field:order.total"],"h1":"B",
  "docs":{"spec":[],"plan":[],"handoff":[]},"derived":{"status":"not started","detail":null},"pr":null,"inflight":[],"neighbours":null,"resolution":null,"superseded_by":null,"owed":null},
 {"path":"docs/issues/c d.md","key":"app-3","ledger":"app","status":"Open","class":"open","severity":"P2","date":"2026-09-02",
  "summary":"Sheet is broken","changes":["component:Sheet"],"consumes":[],"h1":"C",
  "docs":{"spec":[],"plan":["docs/plans/p.md"],"handoff":[]},"derived":{"status":"planned","detail":"docs/plans/p.md"},"pr":null,"inflight":[],"neighbours":null,"resolution":null,"superseded_by":null,"owed":null},
 {"path":"docs/issues/d.md","key":"app-4","ledger":"app","status":"Open","class":"open","severity":"P1","date":"2026-09-03",
  "summary":"Uses <b>bold</b> & pipes |","changes":[],"consumes":[],"h1":"D",
  "docs":{"spec":[],"plan":[],"handoff":[]},"derived":{"status":"not started","detail":null},"pr":null,"inflight":[],"neighbours":null,"resolution":null,"superseded_by":null,"owed":null},
 {"path":"docs/issues/e.md","key":"app-5","ledger":"app","status":"Fixed","class":"fixed","severity":"P2","date":"2026-01-01",
  "summary":"Shipped last week","changes":["field:order.total"],"consumes":[],"h1":"E",
  "docs":{"spec":[],"plan":[],"handoff":[]},"derived":{"status":"shipped","detail":null},"pr":null,"inflight":[],"neighbours":null,"resolution":"Done.","superseded_by":null,"owed":null},
 {"path":"docs/issues/f.md","key":"app-6","ledger":"app","status":"Fixed","class":"fixed","severity":"P2","date":"2026-01-01",
  "summary":"Shipped long ago","changes":[],"consumes":[],"h1":"F",
  "docs":{"spec":[],"plan":[],"handoff":[]},"derived":{"status":"shipped","detail":null},"pr":null,"inflight":[],"neighbours":null,"resolution":"Done.","superseded_by":null,"owed":null},
 {"path":"docs/issues/g.md","key":"app-7","ledger":"app","status":"Closed","class":"closed","severity":"P2","date":"2026-01-01",
  "summary":"Old totals bug","changes":[],"consumes":[],"h1":"G",
  "docs":{"spec":[],"plan":[],"handoff":[]},"derived":{"status":"superseded","detail":"app-1"},"pr":null,"inflight":[],"neighbours":null,"resolution":"Replaced by app-1.","superseded_by":"app-1","owed":null},
 {"path":"docs/issues/h.md","key":"app-8","ledger":"app","status":"Won'"'"'t Fix","class":"wontfix","severity":"P3","date":"2026-10-01",
  "summary":"Not worth doing","changes":[],"consumes":[],"h1":"H",
  "docs":{"spec":[],"plan":[],"handoff":[]},"derived":{"status":"won'"'"'t fix","detail":null},"pr":null,"inflight":[],"neighbours":null,"resolution":"Not worth it.","superseded_by":null,"owed":null},
 {"path":"docs/issues/i.md","key":"app-9","ledger":"app","status":"Fixed","class":"fixed","severity":"P3","date":"2026-09-20",
  "summary":"Merged, deploy owed","changes":[],"consumes":[],"h1":"I",
  "docs":{"spec":[],"plan":[],"handoff":[]},"derived":{"status":"merged","detail":"deploy"},"pr":null,"inflight":[],"neighbours":null,"resolution":"Merged.","superseded_by":null,"owed":"deploy"},
 {"path":"docs/issues/j.md","key":"core-1","ledger":"core","status":"Open","class":"open","severity":"P0","date":"2026-08-01",
  "summary":"Endpoint times out","changes":["endpoint:x"],"consumes":[],"h1":"J",
  "docs":{"spec":[],"plan":[],"handoff":[]},"derived":{"status":"not started","detail":null},"pr":null,"inflight":[],"neighbours":null,"resolution":null,"superseded_by":null,"owed":null},
 {"path":"docs/issues/k.md","key":null,"ledger":null,"status":"Open","class":"open","severity":"P0","date":"2026-08-01",
  "summary":"Legacy item","changes":[],"consumes":[],"h1":"K",
  "docs":{"spec":[],"plan":[],"handoff":[]},"derived":{"status":"not started","detail":null},"pr":null,"inflight":[],"neighbours":null,"resolution":null,"superseded_by":null,"owed":null},
 {"path":"docs/issues/l.md","key":null,"ledger":"unassigned","status":"Open","class":"open","severity":"P1","date":"2026-09-10",
  "summary":"Home not decided","changes":[],"consumes":[],"h1":"L",
  "docs":{"spec":[],"plan":[],"handoff":[]},"derived":{"status":"not started","detail":null},"pr":null,"inflight":[],"neighbours":null,"resolution":null,"superseded_by":null,"owed":null}
]}'

LG_VIEW_GEN='{"source":"origin/main@abc1234","inflight":0,"at":"2026-10-12T00:00:00Z","cutoff":"2026-09-28","touched":{"docs/issues/e.md":"2026-10-03","docs/issues/g.md":"2026-10-04"},"link":"../main/"}'

# lg_render <program> <index-file> <ledger> <mode> [generated] [host-config]:
# the renderer's output (jq -r) into LG_OUT, its exit code into LG_RC.
# <program>: md or html. The config is config.jq's merge of [host-config].
lg_render() {
  local prog="$1" ix="$2" ledger="$3" mode="$4" gen="$LG_VIEW_GEN" host='{}' cfg
  if [ $# -ge 5 ]; then gen=$5; fi
  if [ $# -ge 6 ]; then host=$6; fi
  cfg=$(harness_mktemp lg-cfg)
  jq -nc --argjson h "$host" -f "$REPO_DIR/scripts/ledger/config.jq" > "$cfg"
  LG_RC=0
  LG_OUT=$(jq -r -L "$REPO_DIR/scripts/ledger" --slurpfile c "$cfg" --arg ledger "$ledger" --arg mode "$mode" \
    --argjson generated "$gen" -f "$REPO_DIR/scripts/ledger/render-$prog.jq" "$ix" 2>&1) || LG_RC=$?
  rm -f "$cfg"
}

# lg_view_ix [jq args…] [jq-filter]: LG_VIEW_IX (through the filter) into a
# file; its path.
lg_view_ix() {
  local f
  f=$(harness_mktemp lg-ix)
  if [ $# -le 1 ]; then
    jq -c "${1:-.}" <<<"$LG_VIEW_IX" > "$f"
  else
    # [jq args…] <filter>
    jq -c "$@" <<<"$LG_VIEW_IX" > "$f"
  fi
  printf '%s\n' "$f"
}

# lg_assert_cond <shell-condition> <msg>: assert the condition (eval'd) holds.
lg_assert_cond() {
  local r=no
  if eval "$1"; then r=yes; fi
  assert_eq yes "$r" "$2 [$1]"
}

# The line of $1 that starts with $2 (the first), or "".
lg_line() {
  printf '%s\n' "$1" | awk -v p="$2" 'index($0, p) == 1 { print; exit }'
}

# The 1-based line number of the first line of $1 containing $2, or 0.
lg_lineno() {
  printf '%s\n' "$1" | awk -v p="$2" 'index($0, p) { print NR; f = 1; exit } END { if (!f) print 0 }'
}

test_lg_render_pure() {
  echo "test: the renderers are pure — the same inputs twice render identically; item order does not matter"
  local ix rev a b
  ix=$(lg_view_ix)
  rev=$(lg_view_ix '.items |= reverse')
  lg_render md "$ix" app page
  assert_eq "0" "$LG_RC" "render-md.jq exits 0"
  a=$LG_OUT
  lg_render md "$ix" app page
  assert_eq "$a" "$LG_OUT" "page: the same \$generated twice → identical"
  lg_render md "$rev" app page
  assert_eq "$a" "$LG_OUT" "page: shuffled item order → identical"
  lg_render md "$ix" all readme
  b=$LG_OUT
  lg_render md "$rev" all readme
  assert_eq "$b" "$LG_OUT" "readme: shuffled item order → identical"
  lg_render html "$ix" all page
  assert_eq "0" "$LG_RC" "render-html.jq exits 0"
  b=$LG_OUT
  lg_render html "$rev" all page
  assert_eq "$b" "$LG_OUT" "html: shuffled item order → identical"
  lg_render md "$ix" app page '{"source":"origin/main@abc1234","inflight":0,"at":"2026-10-13T09:00:00Z","cutoff":"2026-09-28","touched":{"docs/issues/e.md":"2026-10-03","docs/issues/g.md":"2026-10-04"},"link":"../main/"}'
  assert_eq "$(printf '%s\n' "$a" | sed '3d')" "$(printf '%s\n' "$LG_OUT" | sed '3d')" "only the header line changes with the timestamp"
  assert_contains "$(printf '%s\n' "$LG_OUT" | sed -n 3p)" "2026-10-13T09:00:00Z" "…which carries it"
}

test_lg_render_clusters_and_unclustered() {
  echo "test: a ledger page — title, header, open counts, clusters by severity counts, rows by severity, unclustered"
  local ix out n1 n2 n3
  ix=$(lg_view_ix)
  lg_render md "$ix" app page
  out=$LG_OUT
  assert_eq "# App (\`app\`)" "$(printf '%s\n' "$out" | sed -n 1p)" "title line"
  assert_eq "> Generated from origin/main@abc1234 + 0 in-flight branches at 2026-10-12T00:00:00Z by doc-superpowers ledger. Do not edit — edit the item." \
    "$(printf '%s\n' "$out" | sed -n 3p)" "header quote"
  assert_eq "Cart to order · Open: P0 1 · P1 2 · P2 1 · P3 1 · In flight: 0 branches" "$(lg_line "$out" "Cart to order")" \
    "scope · open counts (owed work counts as open) · in flight 0"
  assert_eq "## Order totals — \`field:order.total\` (2)" "$(lg_line "$out" "## Order")" "cluster heading: contract title, id, count"
  assert_eq "## \`component:Sheet\` (1)" "$(lg_line "$out" "## \`component")" "a contract without a title"
  n1=$(lg_lineno "$out" "## Order totals")
  n2=$(lg_lineno "$out" "## \`component:Sheet\`")
  n3=$(lg_lineno "$out" "## Unclustered (2)")
  lg_assert_cond "[ $n1 -gt 0 ] && [ $n1 -lt $n2 ] && [ $n2 -lt $n3 ]" "the P0 cluster first, then the P2 one, then Unclustered (2)"
  assert_eq "| Key | Issue | Why it matters | Sev | Spec | Plan | PR | Latest handoff | Status |" \
    "$(lg_line "$out" "| Key")" "the 9-column header"
  lg_assert_cond "[ $(lg_lineno "$out" "| app-2 ") -lt $(lg_lineno "$out" "| app-1 ") ]" "rows by severity: app-2 (P0) before app-1 (P1)"
  assert_eq "| app-1 | [a](../main/docs/issues/a.md) | Totals are wrong | P1 | [✓](../main/docs/specs/s.md) | — | — | [2026-10-05-b](../main/docs/handoffs/2026-10-05-b.md) | spec'd |" \
    "$(lg_line "$out" "| app-1 ")" "a row: key, linked issue, summary, sev, spec ✓, plan —, PR —, newest handoff, status"
  assert_contains "$(lg_line "$out" "| app-3 ")" "[c d](../main/docs/issues/c%20d.md)" "a path with a space is encoded"
  assert_contains "$(lg_line "$out" "| app-4 ")" "Uses &lt;b>bold&lt;/b> & pipes \\|" "cell text: < and | escaped"
  assert_contains "$(lg_line "$out" "| app-9 ")" "merged · owed: deploy" "owed work: the shared display (lg_q_display)"
  lg_assert_cond "[ $(lg_lineno "$out" "| app-4 ") -gt $n3 ] && [ $(lg_lineno "$out" "| app-9 ") -gt $(lg_lineno "$out" "| app-4 ") ]" \
    "unclustered: app-4 (P1), then app-9 (P3)"
  assert_not_contains "$out" "↳" "no neighbour lines while neighbours is null"
  assert_not_contains "$out" "core-1" "another ledger's item is not on the page"
  # Neighbours (Task 9 computes them): other ledgers only, de-duplicated.
  ix=$(lg_view_ix '(.items[] | select(.key == "app-1") | .neighbours) = {"upstream":[],"downstream":[{"key":"core-1","via":"field:order.total"},{"key":"app-2","via":"field:order.total"}],"siblings":[]}
    | (.items[] | select(.key == "app-2") | .neighbours) = {"upstream":[],"downstream":[{"key":"core-1","via":"field:order.total"}],"siblings":[]}
    | (.items[] | select(.key == "app-3") | .neighbours) = {"upstream":[{"key":"core-1","via":"endpoint:x"}],"downstream":[],"siblings":[]}')
  lg_render md "$ix" app page
  assert_eq "↳ Downstream (consumes \`field:order.total\`): core-1 (core)" "$(lg_line "$LG_OUT" "↳ Downstream")" \
    "downstream line: other ledgers only, once"
  assert_eq "↳ Upstream: core-1 (core) changes \`endpoint:x\` — not started" "$(lg_line "$LG_OUT" "↳ Upstream")" "upstream line"
  lg_assert_cond "[ $(lg_lineno "$LG_OUT" "↳ Downstream") -lt $(lg_lineno "$LG_OUT" "## \`component:Sheet\`") ]" \
    "…under its own cluster"
  lg_render md "$ix" core page
  assert_eq "# Core (\`core\`)" "$(printf '%s\n' "$LG_OUT" | sed -n 1p)" "another ledger's page"
  assert_eq "Open: P0 1 · P1 0 · P2 0 · P3 0 · In flight: 0 branches" "$(lg_line "$LG_OUT" "Open:")" "…with no scope"
}

test_lg_render_footer_recent_days() {
  echo "test: closed items last touched within views.recent_days are listed; older ones drop off"
  local ix
  ix=$(lg_view_ix)
  lg_render md "$ix" app page "$LG_VIEW_GEN" '{"views":{"recent_days":7}}'
  assert_contains "$LG_OUT" "## Recently closed (7 days)" "heading names recent_days"
  assert_contains "$LG_OUT" "## Superseded / won't fix (7 days)" "…both headings"
  assert_eq "- [app-5](../main/docs/issues/e.md) — Shipped last week · shipped" "$(lg_line "$LG_OUT" "- [app-5]")" \
    "app-5: touched on 10-03 (after the cutoff) though dated 01-01"
  assert_not_contains "$LG_OUT" "app-6" "app-6: closed long ago, never touched since — dropped"
  lg_render md "$ix" app page
  assert_contains "$LG_OUT" "## Recently closed (14 days)" "the default recent_days is 14"
  lg_render md "$ix" app page '{"source":"x","inflight":0,"at":"t","cutoff":"2026-10-05","touched":{"docs/issues/e.md":"2026-10-03","docs/issues/g.md":"2026-10-04"},"link":""}'
  assert_eq "None." "$(printf '%s\n' "$LG_OUT" | awk '/^## Recently closed/ { getline; getline; print; exit }')" \
    "a later cutoff: nothing recently closed"
  assert_not_contains "$LG_OUT" "app-7" "…nor superseded"
  assert_contains "$LG_OUT" "[a](docs/issues/a.md)" "an empty link prefix leaves the path"
}

test_lg_render_superseded_line() {
  echo "test: Superseded / won't fix: '<key> → <superseded_by>: <resolution>'; a won't fix says so"
  local ix
  ix=$(lg_view_ix)
  lg_render md "$ix" app page
  assert_eq "- app-7 → app-1: Replaced by app-1." "$(lg_line "$LG_OUT" "- app-7")" "superseded line"
  assert_eq "- app-8 → won't fix: Not worth it." "$(lg_line "$LG_OUT" "- app-8")" "won't fix line"
  lg_assert_cond "[ $(lg_lineno "$LG_OUT" "- app-7") -lt $(lg_lineno "$LG_OUT" "- app-8") ]" "by severity (P2 before P3)"
  lg_assert_cond "[ $(lg_lineno "$LG_OUT" "## Superseded") -lt $(lg_lineno "$LG_OUT" "- app-7") ]" "under the Superseded heading"
  ix=$(lg_view_ix '(.items[] | select(.key == "app-7") | .resolution) = null')
  lg_render md "$ix" app page
  assert_eq "- app-7 → app-1: (no resolution)" "$(lg_line "$LG_OUT" "- app-7")" "no resolution: said so"
}

test_lg_render_readme_rollup() {
  echo "test: README — one row per ledger (open counts, in flight), items on no page, the open P0/P1 rollup"
  local ix out
  ix=$(lg_view_ix)
  lg_render md "$ix" all readme
  out=$LG_OUT
  assert_eq "# Work ledger" "$(printf '%s\n' "$out" | sed -n 1p)" "title"
  assert_eq "| Ledger | Open | P0 | P1 | P2 | P3 | In flight |" "$(lg_line "$out" "| Ledger")" "ledger table header"
  assert_eq "| [App (\`app\`)](app.md) | 5 | 1 | 2 | 1 | 1 | 0 |" "$(lg_line "$out" "| [App")" "app row"
  assert_eq "| [Core (\`core\`)](core.md) | 1 | 1 | 0 | 0 | 0 | 0 |" "$(lg_line "$out" "| [Core")" "core row"
  assert_eq "| [Unassigned (\`unassigned\`)](unassigned.md) | 1 | 0 | 1 | 0 | 0 | 0 |" "$(lg_line "$out" "| [Unassigned")" \
    "unassigned items get a row (and a page)"
  assert_not_contains "$out" "Old" "a retired ledger with no items is left out"
  assert_contains "$out" "1 items are on no ledger page" "the item with no ledger is counted"
  assert_eq "## Open P0/P1 (5)" "$(lg_line "$out" "## Open")" "rollup heading"
  lg_assert_cond "[ $(lg_lineno "$out" "| core-1 ") -lt $(lg_lineno "$out" "| app-2 ") ] && [ $(lg_lineno "$out" "| app-2 ") -lt $(lg_lineno "$out" "| app-1 ") ] && [ $(lg_lineno "$out" "| app-1 ") -lt $(lg_lineno "$out" "| app-4 ") ]" \
    "rollup by severity then date: core-1, app-2 (P0), app-1, app-4 (P1)"
  assert_eq "| — | unassigned | [l](../main/docs/issues/l.md) | Home not decided | P1 | not started |" "$(lg_line "$out" "| — | unassigned")" \
    "a keyless unassigned P1"
  assert_not_contains "$out" "| app-3 " "P2 is not in the rollup"
  assert_not_contains "$out" "Legacy item" "nor an item on no ledger"
}

test_lg_html_self_contained() {
  echo "test: the HTML view is one self-contained document — no external script or style; every shown key; escaped"
  local ix out k
  ix=$(lg_view_ix)
  lg_render html "$ix" app page
  out=$LG_OUT
  assert_eq "0" "$LG_RC" "exit 0"
  assert_eq "<!doctype html>" "$(printf '%s\n' "$out" | sed -n 1p)" "a whole document"
  assert_eq "0" "$(printf '%s\n' "$out" | grep -Eic '<script[^>]*src=|<link[^>]*href=|@import|url\(' || true)" \
    "no script src, stylesheet link, @import or url()"
  assert_eq "0" "$(printf '%s\n' "$out" | grep -Eic '(src|href)="https?://' || true)" "no http(s) resource at all in this fixture"
  assert_contains "$out" "prefers-color-scheme: dark" "light and dark"
  assert_contains "$out" "<script>" "inline JS (the filters)"
  for k in app-1 app-2 app-3 app-4 app-5 app-7 app-8 app-9 core-1; do
    assert_contains "$out" ">$k</td>" "key $k is present"
  done
  assert_not_contains "$out" ">app-6</td>" "an old closed item is not"
  assert_contains "$out" "Uses &lt;b&gt;bold&lt;/b&gt; &amp; pipes |" "text is HTML-escaped"
  assert_not_contains "$out" "<b>bold" "…never raw"
  assert_contains "$out" '<option value="app" selected>' "the ledger filter starts on \$ledger"
  assert_contains "$out" 'id="f-sev"' "severity filter"
  assert_contains "$out" 'id="f-class"' "status-class filter"
  assert_contains "$out" 'id="f-inflight"' "in-flight filter"
  assert_contains "$out" 'id="f-q"' "search box"
  assert_contains "$out" 'data-q="app-1 Totals are wrong a Alpha title"' "search text: key, summary, file stem, H1 (case kept)"
  assert_contains "$out" "d.q.toLowerCase()" "…folded in JS at match time, like the query"
  assert_contains "$out" '<h3>Order totals — <code>field:order.total</code> (2)</h3>' "the cluster layout"
  assert_contains "$out" 'href="../main/docs/issues/c%20d.md"' "links encoded"
}

test_lg_render_hardening() {
  echo "test: renderers — first resolution line, cut before escaping, canonical severity, safe PR links, stable key map"
  local ix out rev pipes amps
  # S1: the first line only; cut, then escaped (no split escape).
  ix=$(lg_view_ix '(.items[] | select(.key == "app-7") | .resolution) = "First line.\r\nSECRET-MARKER second line"')
  lg_render md "$ix" app page
  assert_eq "- app-7 → app-1: First line." "$(lg_line "$LG_OUT" "- app-7")" "md: the first line"
  assert_not_contains "$LG_OUT" "SECRET-MARKER" "md: never line 2"
  lg_render html "$ix" app page
  assert_contains "$LG_OUT" '<div class="res">First line.</div>' "html: the first line"
  assert_not_contains "$LG_OUT" "SECRET-MARKER" "html: never line 2"
  pipes=$(printf '%0250d' 0 | tr 0 '|')
  amps=$(printf '%0250d' 0 | tr 0 '&')
  # shellcheck disable=SC2016  # jq source
  ix=$(lg_view_ix --arg p "$pipes" --arg a "$amps" '(.items[] | select(.key == "app-7") | .resolution) = $p
    | (.items[] | select(.key == "app-8") | .resolution) = $a')
  lg_render md "$ix" app page
  out=$(lg_line "$LG_OUT" "- app-7")
  assert_eq "- app-7 → app-1: $(printf '%0199d' 0 | sed 's/0/\\|/g')…" "$out" "md: 199 escaped pipes + … (cut before escaping)"
  lg_render html "$ix" app page
  assert_contains "$LG_OUT" "$(printf '%0199d' 0 | sed 's/0/\&amp;/g')…</div>" "html: 199 whole entities + …"
  # M2: data-sev is the canonical severity_order label.
  ix=$(lg_view_ix '(.items[] | select(.key == "app-4") | .severity) = "p1"')
  lg_render html "$ix" app page
  assert_contains "$(printf '%s\n' "$LG_OUT" | grep '>app-4</td>')" 'data-sev="P1"' "html: p1 → data-sev P1"
  # M5: a PR url is linked only when http(s).
  ix=$(lg_view_ix '(.items[] | select(.key == "app-1") | .pr) = {"number": 5, "url": "javascript:alert(1)"}
    | (.items[] | select(.key == "app-2") | .pr) = {"number": 6, "url": "https://example.test/pr/6"}')
  lg_render md "$ix" app page
  assert_not_contains "$LG_OUT" "javascript:" "md: no javascript: link"
  assert_contains "$(lg_line "$LG_OUT" "| app-1 ")" "| #5 |" "md: #5 as plain text"
  assert_contains "$(lg_line "$LG_OUT" "| app-2 ")" "[#6](https://example.test/pr/6)" "md: an https url is linked"
  lg_render html "$ix" app page
  assert_not_contains "$LG_OUT" "javascript:" "html: no javascript: link"
  assert_contains "$LG_OUT" '<a href="https://example.test/pr/6">#6</a>' "html: an https url is linked"
  # M4: a duplicate key resolves the same whatever the input order.
  ix=$(lg_view_ix '.items += [{"path":"docs/issues/z.md","key":"core-1","ledger":"zed","status":"Open","class":"open","severity":"P2","date":"2026-08-02","summary":"Duplicate key","changes":[],"consumes":[],"h1":"Z","docs":{"spec":[],"plan":[],"handoff":[]},"derived":{"status":"not started","detail":null},"pr":null,"inflight":[],"neighbours":null,"resolution":null,"superseded_by":null,"owed":null}]
    | (.items[] | select(.key == "app-1") | .neighbours) = {"upstream":[],"downstream":[{"key":"core-1","via":"field:order.total"}],"siblings":[]}')
  rev=$(harness_mktemp lg-ix)
  jq -c '.items |= reverse' "$ix" > "$rev"
  lg_render md "$ix" app page
  out=$LG_OUT
  lg_render md "$rev" app page
  assert_eq "$out" "$LG_OUT" "duplicate key, reversed input: identical page"
}

# lg_view_fixture: a repo with config, registry (app, core) and two items,
# committed.
lg_view_fixture() {
  lg_fixture
  lg_enable
  lg_registry "$LG_REG_APP_CORE"
  lg_item docs/issues/a.md "key: app-1" "ledger: app" "status: Open" "severity: P1" \
    "summary: Totals are wrong when the cart is edited" "changes: [field:order.total]"
  lg_item docs/issues/b.md "key: core-1" "ledger: core" "status: Open" "severity: P0" "summary: Endpoint times out"
  git add -A && git commit -qm items
}

test_lg_view_writes_files() {
  echo "test: ledger view writes <L>.md (+ README.md for all) or ledger.html into --out (default: the cache)"
  lg_view_fixture
  local out="$TEST_DIR/out dir" common bin
  lg view all --out "$out"
  assert_eq "0" "$LG_RC" "view all: exit 0"
  assert_file_exists "$out/app.md" "app.md"
  assert_file_exists "$out/core.md" "core.md"
  assert_file_exists "$out/README.md" "README.md"
  assert_file_not_exists "$out/ledger.html" "no HTML unless asked"
  assert_eq "# App (\`app\`)" "$(sed -n 1p "$out/app.md")" "app.md is the app page"
  assert_contains "$(cat "$out/app.md")" "| app-1 |" "…with its item"
  assert_contains "$(sed -n 3p "$out/app.md")" "Generated from the working tree" "…rendered from the working tree"
  assert_contains "$LG_OUT" "$out/README.md" "text names each file written"
  # Recently closed: by the last commit touching the item (or an
  # uncommitted edit), not by its date.
  lg_item docs/issues/z.md "key: app-8" "ledger: app" "status: Fixed" "date: 2020-01-01" "summary: Closed this week"
  git add docs/issues/z.md && git commit -qm z
  lg_item docs/issues/y.md "key: app-7" "ledger: app" "status: Fixed" "date: 2020-01-01" "summary: Closed years ago"
  git add docs/issues/y.md
  GIT_COMMITTER_DATE="2020-01-02T00:00:00Z" GIT_AUTHOR_DATE="2020-01-02T00:00:00Z" git commit -qm y
  lg_item docs/issues/x.md "key: app-6" "ledger: app" "status: Fixed" "date: 2020-01-01" "summary: Closed in the working tree"
  lg view app --out "$out"
  assert_contains "$(cat "$out/app.md")" "[app-8](" "closed, committed today: recently closed"
  assert_contains "$(cat "$out/app.md")" "[app-6](" "closed in the working tree (untracked): recently closed"
  assert_not_contains "$(cat "$out/app.md")" "app-7" "closed by a 2020 commit: dropped"
  assert_contains "$(cat "$out/app.md")" "($(git rev-parse --show-toplevel)/docs/issues/a.md)" "links: absolute paths into the work tree"
  rm -f docs/issues/x.md
  # The working tree, uncommitted edits included.
  lg_item docs/issues/c.md "key: app-2" "ledger: app" "status: Open" "severity: P2" "summary: Not committed yet"
  lg view app --html --out "$out"
  assert_eq "0" "$LG_RC" "view app --html: exit 0"
  assert_file_exists "$out/ledger.html" "ledger.html"
  assert_contains "$(cat "$out/ledger.html")" '<option value="app" selected>' "…starting on the app ledger"
  assert_contains "$(cat "$out/ledger.html")" ">app-2</td>" "…with the uncommitted item"
  lg view core --md --html --out "$out" --format json
  assert_eq "0" "$LG_RC" "--md --html --format json: exit 0"
  assert_eq "1" "$(json_count "$LG_OUT")" "one JSON object"
  assert_json_field "$LG_OUT" '.files | join(",")' "core.md,ledger.html" ".files"
  assert_json_field "$LG_OUT" '.dir' "$out" ".dir"
  lg view app
  common=$(cd "$(git rev-parse --git-common-dir)" && pwd)
  assert_eq "0" "$LG_RC" "default --out: exit 0"
  assert_file_exists "$common/doc-superpowers/ledger/views/app.md" "default dir: <git-common-dir>/doc-superpowers/ledger/views"
  lg view nope
  assert_eq "3" "$LG_RC" "an unknown ledger: usage (3)"
  assert_contains "$LG_ERR" "app, core" "…naming the ledgers"
  lg view
  assert_eq "3" "$LG_RC" "no target: usage (3)"
  lg view app --bogus
  assert_eq "3" "$LG_RC" "an undeclared option: usage (3)"
  # --open hands the file to the platform opener.
  bin=$(harness_mktemp_d lg-bin)
  # shellcheck disable=SC2016  # $1 is the fake opener's
  printf '#!/bin/sh\nprintf "%%s\\n" "$1" > "%s/opened"\n' "$bin" > "$bin/open"
  cp "$bin/open" "$bin/xdg-open"
  chmod +x "$bin/open" "$bin/xdg-open"
  PATH="$bin:$PATH" lg view all --html --open --out "$out"
  assert_eq "0" "$LG_RC" "--open: exit 0"
  assert_eq "$out/ledger.html" "$(cat "$bin/opened" 2>/dev/null)" "--open opens the HTML file"
  teardown
}

# lg_publish_fixture: lg_keys_fixture (bare remote LG_REMOTE, origin/main)
# with an item x-1 on the remote base.
lg_publish_fixture() {
  lg_keys_fixture
  lg_item docs/issues/a.md "key: x-1" "ledger: x" "status: Open" "severity: P1" "summary: On the base" "changes: [field:a]"
  git add -A && git commit -qm a && git push -q origin main
}

# The state publish must not touch: HEAD, the index, the status.
lg_user_state() {
  printf '%s\n' "$(git rev-parse HEAD)" "$(git symbolic-ref -q HEAD || echo detached)"
  git ls-files -s
  git status --porcelain
}

# The number of worktrees (publish adds none).
lg_wt_state() {
  printf '%s worktree(s)\n' "$(git worktree list --porcelain | grep -c '^worktree ')"
}

test_lg_publish_orphan_branch() {
  echo "test: ledger publish — an orphan views branch with only view files, from the remote base; then a fast-forward"
  lg_publish_fixture
  local before vb first second files msg c2 here
  # Local work that is not on the remote base must not reach the views.
  lg_item docs/issues/b.md "key: x-8" "ledger: x" "status: Open" "severity: P1" "summary: Local commit only"
  git add -A && git commit -qm local
  lg_item docs/issues/c.md "key: x-9" "ledger: x" "status: Open" "severity: P1" "summary: Uncommitted"
  git add docs/issues/c.md
  lg_item docs/issues/d.md "key: x-7" "ledger: x" "status: Open" "severity: P1" "summary: Untracked"
  before=$(lg_user_state)
  lg publish
  assert_eq "0" "$LG_RC" "publish: exit 0"
  vb=refs/heads/doc-ledger-views
  first=$(git --git-dir="$LG_REMOTE" rev-parse -q --verify "$vb" || echo none)
  lg_assert_cond "[ '$first' != none ]" "the remote has the views branch"
  files=$(git --git-dir="$LG_REMOTE" ls-tree -r --name-only "$vb" | tr '\n' ' ')
  assert_eq "README.md ledger.html x.md y.md " "$files" "the views branch holds only the view files"
  assert_eq "1" "$(git --git-dir="$LG_REMOTE" rev-list --parents -n 1 "$vb" | wc -w | tr -d ' ')" "an orphan: no parent"
  msg=$(git --git-dir="$LG_REMOTE" log -1 --format=%s "$vb")
  lg_assert_cond "printf '%s' '$msg' | grep -Eq '^views @ origin/main@[0-9a-f]{7,}, 0 in-flight branches, [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'" \
    "message 'views @ <base>@<short-sha>, <n> in-flight branches, <UTC>' ($msg)"
  assert_contains "$msg" "origin/main@$(git rev-parse --short refs/remotes/origin/main)" "…naming the base commit"
  assert_contains "$(git --git-dir="$LG_REMOTE" show "$vb:x.md")" "| x-1 |" "x.md has the base's item"
  assert_not_contains "$(git --git-dir="$LG_REMOTE" show "$vb:x.md")" "x-8" "…not a local commit's"
  assert_not_contains "$(git --git-dir="$LG_REMOTE" show "$vb:x.md")" "x-9" "…nor a staged or untracked one"
  assert_contains "$(git --git-dir="$LG_REMOTE" show "$vb:x.md")" "Generated from origin/main@" "header names the base"
  assert_eq "$before" "$(lg_user_state)" "HEAD, index and status unchanged"
  assert_eq "1 worktree(s)" "$(lg_wt_state)" "no worktree was added"
  lg_assert_cond "! git rev-parse -q --verify refs/heads/doc-ledger-views >/dev/null" "no local views branch was created"
  # A second publish after the base moves: a fast-forward.
  c2=$(harness_mktemp_d pubclone)/c
  lg_clone "$c2"
  here=$PWD
  cd "$c2"
  lg_item docs/issues/e.md "key: x-2" "ledger: x" "status: Open" "severity: P0" "summary: Added on the base later"
  git add -A && git commit -qm e && git push -q origin main
  cd "$here"
  lg publish --format json
  assert_eq "0" "$LG_RC" "second publish: exit 0"
  second=$(git --git-dir="$LG_REMOTE" rev-parse "$vb")
  assert_eq "$first" "$(git --git-dir="$LG_REMOTE" rev-parse "$second^")" "the second commit's parent is the first (fast-forward)"
  assert_json_field "$LG_OUT" '.commit' "$second" ".commit"
  assert_json_field "$LG_OUT" '.parent' "$first" ".parent"
  assert_json_field "$LG_OUT" '.files | join(",")' "README.md,ledger.html,x.md,y.md" ".files"
  assert_contains "$(git --git-dir="$LG_REMOTE" show "$vb:x.md")" "| x-2 |" "the fetched base's new item"
  assert_eq "$before" "$(lg_user_state)" "still unchanged"
  # --dry-run: everything but the commit and the push.
  lg publish --dry-run --format json
  assert_eq "0" "$LG_RC" "--dry-run: exit 0"
  assert_json_field "$LG_OUT" '.dry_run' "true" ".dry_run"
  assert_json_field "$LG_OUT" '.commit' "null" "no commit"
  assert_eq "$second" "$(git --git-dir="$LG_REMOTE" rev-parse "$vb")" "the remote did not move"
  assert_file_exists "$(jq -r .dir <<<"$LG_OUT")/x.md" "the rendered files are left in .dir"
  # The base's config decides (this clone's says nothing).
  cd "$c2"
  lg_enable '{"views":{"html":false}}'
  git add docs/ledger/config.json && git commit -qm nohtml && git push -q origin main
  cd "$here"
  lg publish
  assert_eq "0" "$LG_RC" "views.html false: exit 0"
  assert_eq "README.md x.md y.md " "$(git --git-dir="$LG_REMOTE" ls-tree -r --name-only "$vb" | tr '\n' ' ')" \
    "views.html false (the base's config): no ledger.html"
  teardown
}

test_lg_publish_rejects_non_ff() {
  echo "test: ledger publish never forces — a views branch that moved meanwhile is rejected with exit 2"
  lg_publish_fixture
  local before vb racer
  lg publish
  assert_eq "0" "$LG_RC" "first publish: exit 0"
  vb=refs/heads/doc-ledger-views
  before=$(lg_user_state)
  # The selftest hook pushes an unrelated commit to the views branch just
  # before this run's push: another publisher won the race.
  DOC_TOOLS_LEDGER_SELFTEST=publish-race lg publish
  assert_eq "2" "$LG_RC" "a non-fast-forward: could not run (2)"
  assert_contains "$LG_ERR" "rejected: the branch moved" "stderr says the push was rejected: the branch moved"
  racer=$(git --git-dir="$LG_REMOTE" log -1 --format=%s "$vb")
  assert_eq "selftest race" "$racer" "the remote keeps the other publisher's commit"
  assert_eq "$before" "$(lg_user_state)" "HEAD, index and status unchanged"
  assert_eq "1 worktree(s)" "$(lg_wt_state)" "no worktree was added"
  DOC_TOOLS_LEDGER_SELFTEST=publish-race lg publish --format json
  assert_eq "2" "$LG_RC" "--format json: exit 2"
  assert_json_field "$LG_OUT" '.exit' "2" "the verdict object"
  teardown
}

test_lg_publish_base_without_config() {
  echo "test: ledger publish — a base without docs/ledger/config.json cannot be published (exit 2)"
  lg_publish_fixture
  git rm -q docs/ledger/config.json && git commit -qm off && git push -q origin HEAD:main
  lg_enable
  lg publish
  assert_eq "2" "$LG_RC" "a base without docs/ledger/config.json: exit 2"
  assert_contains "$LG_ERR" "config.json" "…named"
  assert_eq "1 worktree(s)" "$(lg_wt_state)" "no worktree"
  teardown
}

test_lg_publish_base_only() {
  echo "test: ledger publish reads only the base commit — its config, registry and items; no checkout"
  lg_publish_fixture
  local vb=refs/heads/doc-ledger-views before x
  # A divergent working tree: other globs, another registry, an uncommitted item.
  lg_enable '{"items":{"globs":["elsewhere/*.md"]},"views":{"recent_days":3}}'
  lg_registry '{"schema":"ledger-registry/1","ledgers":[{"id":"zz","title":"ZZ","kind":"service","status":"active"}]}'
  lg_item docs/issues/u.md "key: x-5" "ledger: x" "status: Open" "severity: P0" "summary: Uncommitted item"
  mkdir -p elsewhere
  lg_item elsewhere/e.md "key: zz-1" "ledger: zz" "status: Open" "severity: P0" "summary: Only the working tree globs"
  before=$(lg_user_state)
  lg publish
  assert_eq "0" "$LG_RC" "publish: exit 0"
  assert_eq "README.md ledger.html x.md y.md " "$(git --git-dir="$LG_REMOTE" ls-tree -r --name-only "$vb" | tr '\n' ' ')" \
    "the base's registry (x, y), not the working tree's (zz)"
  x=$(git --git-dir="$LG_REMOTE" show "$vb:x.md")
  assert_contains "$x" "| x-1 |" "the base's item, through the base's globs"
  assert_not_contains "$x" "x-5" "not the uncommitted item"
  assert_contains "$x" "## Recently closed (14 days)" "the base's views settings (recent_days 14), not the working tree's"
  assert_eq "$before" "$(lg_user_state)" "HEAD, index and status unchanged"
  assert_eq "1 worktree(s)" "$(lg_wt_state)" "no worktree was added"
  teardown
}

test_lg_publish_base_without_remote_prefix() {
  echo "test: ledger publish — base \"main\" means <remote>/main, never the local branch"
  lg_publish_fixture
  local vb=refs/heads/doc-ledger-views msg
  lg_item docs/issues/b.md "key: x-8" "ledger: x" "status: Open" "severity: P1" "summary: Local main only"
  git add -A && git commit -qm local
  lg_enable '{"base":"main"}'
  lg publish
  assert_eq "0" "$LG_RC" "publish: exit 0"
  assert_not_contains "$(git --git-dir="$LG_REMOTE" show "$vb:x.md")" "x-8" "the local main's commit is not published"
  assert_contains "$(git --git-dir="$LG_REMOTE" show "$vb:x.md")" "| x-1 |" "origin/main's item is"
  msg=$(git --git-dir="$LG_REMOTE" log -1 --format=%s "$vb")
  assert_contains "$msg" "views @ origin/main@$(git rev-parse --short refs/remotes/origin/main)," "message names origin/main"
  teardown
}

test_lg_publish_keeps_worktree_index() {
  echo "test: a publish's base index is cached apart (\$_LG_CACHE/rev): the working tree's index is never evicted"
  lg_publish_fixture
  local common ix i
  common=$(cd "$(git rev-parse --git-common-dir)" && pwd)
  # The working tree differs from the base (else the two indexes could share a key).
  lg_item docs/issues/u.md "key: x-5" "ledger: x" "status: Open" "severity: P0" "summary: Uncommitted item"
  DOC_TOOLS_LEDGER_TRACE=1 lg ls
  assert_contains "$LG_ERR" "index-build" "ls builds the working tree's index"
  ix=$(find "$common/doc-superpowers/ledger" -maxdepth 1 -name 'index-*.json' | head -n 1)
  assert_true "the working tree index exists" test -f "$ix"
  # Age it, and add three newer (but not recent) indexes beside it: a prune
  # in this directory would now keep those three and drop it.
  touch -t 202001010000 "$ix"
  for i in 1 2 3; do
    cp "$ix" "$common/doc-superpowers/ledger/index-dummy$i.json"
    touch -t "20210101000$i" "$common/doc-superpowers/ledger/index-dummy$i.json"
  done
  lg publish
  assert_eq "0" "$LG_RC" "publish: exit 0"
  assert_true "the base index is under rev/" test -n "$(find "$common/doc-superpowers/ledger/rev" -name 'index-*.json' 2>/dev/null)"
  assert_true "the working tree index still exists" test -f "$ix"
  DOC_TOOLS_LEDGER_TRACE=1 lg ls
  assert_contains "$LG_ERR" "index-hit" "the next ls is a cache hit"
  teardown
}

test_lg_publish_push_failed_not_moved() {
  echo "test: a push failure that is not a rejection says 'failed', not 'moved' (exit 2)"
  lg_publish_fixture
  git config remote.origin.pushurl "$TEST_DIR/no-such-remote.git"
  lg publish
  assert_eq "2" "$LG_RC" "exit 2"
  assert_contains "$LG_ERR" "the push to origin doc-ledger-views failed" "says the push failed"
  assert_not_contains "$LG_ERR" "moved" "…without claiming the branch moved"
  teardown
}

# --- Task 9: contracts, relations, message trailers, re-check -----------------------

# app: field:order.total (src/order/*.js), component:Sheet (src/sheet/**, a
# title); core: endpoint:create (server/create.js).
# shellcheck disable=SC2016  # JSON
LG_REG_REL='{"schema":"ledger-registry/1","ledgers":[
  {"id":"app","title":"App","kind":"service","status":"active",
   "contracts":[{"id":"field:order.total","defined_in":["src/order/*.js"]},
                {"id":"component:Sheet","defined_in":["src/sheet/**"],"title":"The sheet"}]},
  {"id":"core","title":"Core","kind":"platform","status":"active",
   "contracts":[{"id":"endpoint:create","defined_in":["server/create.js"]}]}]}'

# lg_rel_fixture [config]: the relations corpus, committed on main —
#   app-1 changes field:order.total; files src/util/a.js, src/util/b.js
#   core-1 (P0) and app-2 consume field:order.total; app-3 changes it
#   core-2 relates depends-on:app-1, root-cause:core-1, sibling:app-3
#   app-4 lists both util files (a candidate of app-1), app-5 one of them
#   (not), app-6 lists src/order/total.js (field:order.total's definition)
#   core-3 shares the spec docs/specs/s.md with app-1
#   core-4 (closed) lists both util files (closed: never a candidate)
lg_rel_fixture() {
  local c='{"base":"main"}'
  if [ $# -gt 0 ]; then c=$1; fi
  lg_fixture
  lg_enable "$c"
  lg_registry "$LG_REG_REL"
  lg_item docs/issues/a.md "key: app-1" "ledger: app" "status: Open" "severity: P1" "summary: Totals are wrong" \
    "changes: [field:order.total]" "related-files: [src/util/a.js, src/util/b.js]"
  lg_item docs/issues/b.md "key: core-1" "ledger: core" "status: Open" "severity: P0" "summary: Receipts read the total" \
    "consumes: [field:order.total]"
  lg_item docs/issues/c.md "key: app-2" "ledger: app" "status: Open" "severity: P2" "summary: Cart badge reads the total" \
    "consumes: [field:order.total]"
  lg_item docs/issues/d.md "key: app-3" "ledger: app" "status: Open" "severity: P2" "summary: Tax rounding" \
    "changes: [field:order.total]"
  lg_item docs/issues/e.md "key: core-2" "ledger: core" "status: Open" "severity: P2" "summary: Order export breaks" \
    "relates: [depends-on:app-1, root-cause:core-1, sibling:app-3]"
  lg_item docs/issues/f.md "key: app-4" "ledger: app" "status: Open" "severity: P3" "summary: Util cleanup" \
    "related-files: [src/util/a.js, src/util/b.js]"
  lg_item docs/issues/g.md "key: app-5" "ledger: app" "status: Open" "severity: P3" "summary: One util file" \
    "related-files: [src/util/a.js]"
  lg_item docs/issues/h.md "key: app-6" "ledger: app" "status: Open" "severity: P3" "summary: Total file lint" \
    "related-files: [src/order/total.js]"
  lg_item docs/issues/i.md "key: core-3" "ledger: core" "status: Open" "severity: P3" "summary: Specified together"
  lg_item docs/issues/j.md "key: core-4" "ledger: core" "status: Closed" "severity: P3" "summary: Closed util work" \
    "related-files: [src/util/a.js, src/util/b.js]"
  printf '\n## Resolution\n\nDone elsewhere.\n' >> docs/issues/j.md
  mkdir -p docs/specs src/order src/util server
  printf '# Spec\n\nCovers app-1 and core-3.\n' > docs/specs/s.md
  printf '{"docs":{"docs/specs/s.md":{"doc_type":"spec"}}}\n' > docs/.doc-index.json
  echo total > src/order/total.js
  echo a > src/util/a.js
  echo b > src/util/b.js
  echo create > server/create.js
  git add -A && git commit -qm relations
}

# lg_rel_ix: the working tree's index (a file path) into LG_IX.
lg_rel_ix() {
  lg_call _lg_index
  LG_IX=$LG_OUT
}

# lg_nb <key> <list>: the item's neighbours list (upstream | downstream |
# siblings) as "key/via key/via …" from LG_IX.
lg_nb() {
  jq -r --arg k "$1" --arg l "$2" '.items[] | select(.key == $k) | .neighbours[$l] | map("\(.key)/\(.via)") | join(" ")' "$LG_IX"
}

# lg_rc_of <key>: the item's recheck_after, joined by spaces, from LG_IX.
lg_rc_of() {
  jq -r --arg k "$1" '.items[] | select(.key == $k) | .recheck_after | join(" ")' "$LG_IX"
}

test_lg_contract_upstream_downstream() {
  echo "test: contracts — upstream = items changing what it consumes; downstream the reverse"
  lg_rel_fixture
  lg_rel_ix
  assert_eq "0" "$LG_RC" "the index builds"
  assert_eq "" "$(lg_nb app-1 upstream)" "app-1 consumes nothing: no upstream"
  assert_eq "app-2/field:order.total core-1/field:order.total core-2/depends-on" "$(lg_nb app-1 downstream)" \
    "app-1 downstream: the consumers of field:order.total (and core-2's depends-on)"
  assert_eq "app-1/field:order.total app-3/field:order.total" "$(lg_nb core-1 upstream)" \
    "core-1 upstream: every item changing field:order.total"
  assert_eq "core-2/root-cause" "$(lg_nb core-1 downstream)" "core-1 downstream: core-2 (root-cause)"
  assert_eq "" "$(lg_nb app-4 upstream)$(lg_nb app-4 downstream)$(lg_nb app-4 siblings)" "an item naming no contract: no neighbours"
  assert_json_field "$(cat "$LG_IX")" '.contracts | map(.id) | join(",")' "component:Sheet,endpoint:create,field:order.total" \
    "the index lists the registry's contracts, sorted"
  assert_json_field "$(cat "$LG_IX")" '.contracts[] | select(.id == "field:order.total") | [.ledger, (.defined_in | join(","))] | join("|")' \
    "app|src/order/*.js" "…with their ledger and defined_in"
  assert_json_field "$(cat "$LG_IX")" '.path_contracts | tojson' '{"src/order/total.js":["field:order.total"]}' \
    "path_contracts: a listed file a contract's defined_in matches"
  teardown
}

test_lg_contract_siblings() {
  echo "test: contracts — siblings share a contract on one side (both change, or both consume)"
  lg_rel_fixture
  lg_rel_ix
  assert_eq "app-1/field:order.total core-2/sibling" "$(lg_nb app-3 siblings)" "app-3: app-1 changes it too; core-2's relates sibling"
  assert_eq "app-2/field:order.total" "$(lg_nb core-1 siblings)" "core-1: app-2 consumes it too"
  assert_eq "core-1/field:order.total" "$(lg_nb app-2 siblings)" "app-2: core-1 (symmetric)"
  assert_eq "app-3/field:order.total" "$(lg_nb app-1 siblings)" "app-1: app-3 (a changer is not a consumer's sibling)"
  teardown
}

test_lg_relates_edges() {
  echo "test: relates — root-cause / depends-on make the named item upstream; sibling both ways; other kinds no edge"
  lg_rel_fixture
  lg_rel_ix
  assert_eq "app-1/depends-on core-1/root-cause" "$(lg_nb core-2 upstream)" "core-2 upstream: what its relates name"
  assert_eq "app-3/sibling" "$(lg_nb core-2 siblings)" "core-2 sibling: app-3"
  assert_eq "app-2/field:order.total core-1/field:order.total core-2/depends-on" "$(lg_nb app-1 downstream)" \
    "app-1 downstream includes core-2 (it depends on app-1)"
  # Kind case-insensitive, key by alias, an unknown kind and an unknown key: no edge.
  lg_item docs/issues/k.md "key: core-5" "ledger: core" "status: Open" "severity: P3" "summary: Odd relations" \
    "relates: [Depends-On:APP-6, blocks:app-1, sibling:nope-9, core-5x]" "aliases: [core-50]"
  lg_item docs/issues/l.md "key: app-7" "ledger: app" "status: Open" "severity: P3" "summary: Names an alias" \
    "relates: [sibling:core-50]"
  lg_rel_ix
  assert_eq "app-6/depends-on" "$(lg_nb core-5 upstream)" "kind and key case-insensitive; blocks: and unknown keys are no edges"
  assert_eq "app-7/sibling" "$(lg_nb core-5 siblings)" "a relates naming an alias reaches the item"
  teardown
}

test_lg_related_candidates_paths() {
  echo "test: ledger related — confirmed neighbours, then candidates: ≥ 2 shared files (1 is not)"
  lg_rel_fixture
  local line
  lg related app-1
  assert_eq "0" "$LG_RC" "related: exit 0"
  assert_contains "$(sed -n 1p <<<"$LG_OUT")" "app-1  app  P1" "the item's line first"
  assert_contains "$LG_OUT" "downstream  core-1  via field:order.total" "a confirmed downstream item"
  assert_contains "$LG_OUT" "sibling  app-3  via field:order.total" "a confirmed sibling"
  line=$(lg_line "$LG_OUT" "candidate  app-4")
  assert_contains "$line" "shares 2 files: src/util/a.js, src/util/b.js" "2 shared files: a candidate, with its reason"
  assert_not_contains "$LG_OUT" "app-5" "1 shared file: not a candidate"
  assert_not_contains "$LG_OUT" "core-4" "a closed item: never a candidate"
  lg_assert_cond "[ $(lg_lineno "$LG_OUT" "sibling  app-3") -lt $(lg_lineno "$LG_OUT" "candidate  ") ]" "confirmed before candidates"
  lg related app-1 --format json
  assert_eq "1" "$(json_count "$LG_OUT")" "JSON: one object"
  assert_json_field "$LG_OUT" '[.candidates[] | .key] | join(",")' "app-4,app-6,core-3" "JSON candidates"
  assert_json_field "$LG_OUT" '.neighbours | map("\(.kind)/\(.key)") | join(",")' \
    "downstream/app-2,downstream/core-1,downstream/core-2,sibling/app-3" "JSON neighbours"
  lg related nope-9
  assert_eq "1" "$LG_RC" "an unknown item: exit 1"
  lg related app-1 --depth 4
  assert_eq "3" "$LG_RC" "--depth outside 1–3: usage (3)"
  lg related
  assert_eq "3" "$LG_RC" "no item: usage (3)"
  teardown
}

test_lg_related_candidates_spec() {
  echo "test: ledger related — candidates by a shared spec and by a contract's defined_in; --depth"
  lg_rel_fixture
  lg related app-1
  assert_contains "$(lg_line "$LG_OUT" "candidate  core-3")" "same spec: docs/specs/s.md" "a shared spec"
  assert_contains "$(lg_line "$LG_OUT" "candidate  app-6")" "its file src/order/total.js defines field:order.total" \
    "a file the defined_in of a contract app-1 names"
  lg related core-3
  assert_contains "$(lg_line "$LG_OUT" "candidate  app-1")" "same spec: docs/specs/s.md" "the spec, the other way"
  assert_contains "$LG_OUT" "(no confirmed relations)" "core-3 has no confirmed relations"
  lg related app-6
  assert_contains "$(lg_line "$LG_OUT" "candidate  app-1")" "names field:order.total, defined in src/order/total.js" \
    "the other way: app-1 names the contract app-6's file defines"
  lg related core-2 --depth 2
  assert_eq "0" "$LG_RC" "--depth 2: exit 0"
  assert_contains "$LG_OUT" "downstream (depth 2, through app-1)  app-2  via field:order.total" \
    "depth 2: reached through a neighbour, once"
  assert_eq "1" "$(grep -c '  core-1  ' <<<"$LG_OUT")" "each item listed once"
  teardown
}

test_lg_recheck_lists_dependents() {
  echo "test: ledger recheck — downstream and relates dependents, each with the three actions"
  lg_rel_fixture
  lg recheck app-1
  assert_eq "0" "$LG_RC" "recheck: exit 0"
  assert_eq "core-1  via field:order.total · not started · Receipts read the total  → re-verify | close as superseded by app-1 | reshape" \
    "$(sed -n 1p <<<"$LG_OUT")" "the most severe first, with its actions"
  assert_eq "3" "$(wc -l <<<"$LG_OUT" | tr -d ' ')" "three dependents"
  assert_contains "$(lg_line "$LG_OUT" "core-2")" "via depends-on" "a relates dependent"
  lg recheck app-3
  assert_contains "$(lg_line "$LG_OUT" "core-2")" "via sibling" "an item whose relates names it a sibling"
  assert_contains "$LG_OUT" "close as superseded by app-3" "…superseded by the item asked about"
  # A dependent that is closed is not listed.
  lg_item docs/issues/c.md "key: app-2" "ledger: app" "status: Fixed" "severity: P2" "summary: Cart badge reads the total" \
    "consumes: [field:order.total]"
  lg recheck app-1
  assert_not_contains "$LG_OUT" "app-2" "a fixed dependent: not listed"
  lg recheck core-3
  assert_eq "nothing to re-check for core-3" "$LG_OUT" "no dependents: said so"
  lg recheck app-1 --format json
  assert_json_field "$LG_OUT" '.dependents[0].actions | join("|")' "re-verify|close as superseded by app-1|reshape" "JSON actions"
  teardown
}

test_lg_sweep_table_shape() {
  echo "test: ledger sweep — a Related work table, confirmed rows first, then candidates, Mark empty"
  lg_rel_fixture
  local first rows
  cat > docs/plan.md <<'PLAN'
# Plan

Touches `src/util/a.js`, `./src/util/b.js` and `nope/missing.js`.
Changes field:order.total. See core-2 and APP-6.

## Related work

| Item | Why related | Mark |
|---|---|---|
| core-3 | earlier sweep | include |
PLAN
  lg sweep --plan docs/plan.md
  assert_eq "0" "$LG_RC" "sweep --plan: exit 0"
  assert_eq "## Related work" "$(sed -n 1p <<<"$LG_OUT")" "the heading first"
  assert_eq "" "$(sed -n 2p <<<"$LG_OUT")" "a blank line"
  assert_eq "| Item | Why related | Mark |" "$(sed -n 3p <<<"$LG_OUT")" "the header row"
  assert_eq "|---|---|---|" "$(sed -n 4p <<<"$LG_OUT")" "the separator row"
  rows=$(tail -n +5 <<<"$LG_OUT")
  assert_eq "0" "$(grep -cv '^| .* | .* | |$' <<<"$rows")" "every row: 3 cells, Mark empty"
  assert_contains "$(lg_line "$rows" "| core-2 |")" "named" "a key in the text: named"
  assert_contains "$(lg_line "$rows" "| app-6 |")" "named" "a key in another case: named"
  assert_contains "$(lg_line "$rows" "| core-3 |")" "named" "a row of the plan's own table: still listed"
  assert_contains "$(lg_line "$rows" "| app-1 |")" "changes field:order.total" "a contract in the text: its changers"
  assert_contains "$(lg_line "$rows" "| core-1 |")" "consumes field:order.total" "…its consumers"
  assert_contains "$(lg_line "$rows" "| app-5 |")" "lists src/util/a.js" "a backticked existing file: the items listing it"
  assert_not_contains "$rows" "core-4" "a closed item that is not named: no row"
  first=$(sed -n 5p <<<"$LG_OUT")
  assert_contains "$first" "| core-1 |" "confirmed rows by severity: P0 first"
  lg sweep --keys app-1
  assert_eq "0" "$LG_RC" "sweep --keys: exit 0"
  rows=$(tail -n +5 <<<"$LG_OUT")
  assert_contains "$(lg_line "$rows" "| app-4 |")" "shares 2 files" "a candidate of a named key"
  lg_assert_cond "[ $(lg_lineno "$rows" "| app-3 |") -lt $(lg_lineno "$rows" "| app-4 |") ]" "confirmed (app-3, sibling) before candidates (app-4)"
  lg sweep --contracts field:order.total --format json
  assert_eq "1" "$(json_count "$LG_OUT")" "JSON: one object"
  assert_json_field "$LG_OUT" '[.rows[] | select(.confirmed | not) | .key] | join(",")' "app-6" \
    "--contracts: a file its defined_in matches is a candidate"
  assert_json_field "$LG_OUT" '.table | split("\n")[0]' "## Related work" "JSON carries the table"
  lg sweep --files src/order/new.js
  assert_eq "0" "$LG_RC" "--files: a path that does not exist yet is fine"
  assert_contains "$(lg_line "$LG_OUT" "| app-1 |")" "names field:order.total, defined in src/order/new.js" \
    "an item naming a contract a given file defines: a candidate"
  lg sweep --contracts field:nope
  assert_eq "3" "$LG_RC" "an unknown contract: usage (3)"
  lg sweep --keys nope-1
  assert_eq "3" "$LG_RC" "a key that is not an item: usage (3)"
  lg sweep
  assert_eq "3" "$LG_RC" "no input: usage (3)"
  # The table it prints passes validate --plan once marked.
  lg sweep --keys core-2
  { printf '# P\n\n'; sed 's/| |$/| include |/' <<<"$LG_OUT"; } > docs/plan2.md
  lg validate --plan docs/plan2.md
  assert_eq "0" "$LG_RC" "the table, marked, passes validate --plan"
  teardown
}

test_lg_link_validates() {
  echo "test: ledger link — validates every value (exit 1, nothing written), then adds to the lists in one write"
  lg_rel_fixture
  local before
  lg link core-3 --consumes field:order.total
  assert_eq "0" "$LG_RC" "a known contract: exit 0"
  assert_eq "core-3  consumes: field:order.total  (added)" "$LG_OUT" "says what it added"
  assert_contains "$(cat docs/issues/i.md)" "consumes: [field:order.total]" "written into the frontmatter"
  lg link core-3 --consumes field:order.total
  assert_eq "core-3  consumes: field:order.total  (already there)" "$LG_OUT" "a value already there: left"
  before=$(hash_file docs/issues/i.md)
  lg link core-3 --consumes field:nope
  assert_eq "1" "$LG_RC" "an unknown contract: exit 1"
  assert_contains "$LG_OUT" "link: --consumes \"field:nope\" is not a contract" "…named"
  lg link core-3 --relates blocks:app-1
  assert_eq "1" "$LG_RC" "a relates kind outside root-cause/depends-on/sibling: exit 1"
  lg link core-3 --relates sibling:nope-9
  assert_eq "1" "$LG_RC" "a relates key that resolves to nothing: exit 1"
  lg link core-3 --relates sibling:core-3
  assert_eq "1" "$LG_RC" "a self-link: exit 1"
  assert_contains "$LG_OUT" "is the item itself" "…named"
  lg link core-3 --relates depends-on:app-4 --changes field:nope
  assert_eq "1" "$LG_RC" "one bad value of several: exit 1"
  assert_eq "$before" "$(hash_file docs/issues/i.md)" "nothing was written by any failed link"
  lg link core-3 --relates Depends-On:APP-4 --changes component:Sheet
  assert_eq "0" "$LG_RC" "two good values: exit 0"
  assert_contains "$(cat docs/issues/i.md)" "relates: [depends-on:app-4]" "relates written <kind>:<key> as the item spells it"
  assert_contains "$(cat docs/issues/i.md)" "changes: [component:Sheet]" "…and changes, in the same run"
  lg link core-3
  assert_eq "3" "$LG_RC" "no relation given: usage (3)"
  lg link nope-1 --consumes field:order.total
  assert_eq "1" "$LG_RC" "an unknown item: exit 1"
  lg link core-3 --consumes field:order.total --format json
  assert_json_field "$LG_OUT" '[.path, (.present | length)] | tojson' '["docs/issues/i.md",1]' "JSON payload"
  teardown
}

# lg_contracts_adapter <body>: tools/contracts.sh with <body> (sh), executable.
lg_contracts_adapter() {
  mkdir -p tools
  printf '#!/bin/sh\n%s\n' "$1" > tools/contracts.sh
  chmod +x tools/contracts.sh
}

test_lg_contracts_adapter_absent_ok() {
  echo "test: no contracts adapter — only registry contracts; nothing fails"
  lg_rel_fixture
  lg_rel_ix
  assert_json_field "$(cat "$LG_IX")" '.built.contracts_error' "null" "built.contracts_error null"
  assert_json_field "$(cat "$LG_IX")" '.contracts[] | select(.id == "component:Sheet") | [.ledger, .title] | join("|")' \
    "app|The sheet" "a registry title"
  lg related app-1
  assert_eq "0" "$LG_RC" "related: exit 0"
  lg_enable '{"base":"main","adapters":{"contracts":""}}'
  lg related app-1
  assert_eq "0" "$LG_RC" "an empty adapter value is absent too"
  teardown
}

test_lg_adapter_plugin_prefix_resolves() {
  echo "test: adapters — doc-superpowers:<name> is the adapter beside the running copy of doc-tools.sh"
  lg_rel_fixture '{"base":"main","adapters":{"contracts":"doc-superpowers:fixture"}}'
  local root
  root=$(harness_mktemp_d lg-plugin)
  cp -R "$REPO_DIR/scripts" "$root/scripts"
  mkdir -p "$root/scripts/adapters"
  printf '#!/bin/sh\n[ "$1" = list ] && echo %s\n' \
    "'{\"id\":\"flag:plugin\",\"ledger\":\"core\",\"defined_in\":[\"flags.json\"]}'" > "$root/scripts/adapters/fixture.sh"
  chmod +x "$root/scripts/adapters/fixture.sh"
  printf '#!/bin/sh\nexec "%s" "%s" "$@"\n' "$BASH_BIN" "$root/scripts/doc-tools.sh" > "$root/run"
  chmod +x "$root/run"
  lg_with "$root/run" link core-3 --consumes flag:plugin
  assert_eq "0" "$LG_RC" "the copy's sibling adapters/fixture.sh lists flag:plugin"
  assert_contains "$(cat docs/issues/i.md)" "consumes: [flag:plugin]" "…a contract only the adapter knows"
  lg related app-1
  assert_eq "2" "$LG_RC" "this copy has no adapters/fixture.sh: exit 2"
  assert_contains "$LG_ERR" "$REPO_DIR/scripts/adapters/fixture.sh" "…naming the path it resolved to"
  lg_enable '{"base":"main","adapters":{"contracts":"doc-superpowers:../fixture"}}'
  lg_with "$root/run" related app-1
  assert_eq "2" "$LG_RC" "a name that would leave adapters/: exit 2"
  rm -rf "$root"
  teardown
}

test_lg_contract_registry_wins_over_adapter() {
  echo "test: a contract in the registry and the adapter is one — the registry's fields win; the adapter fills gaps"
  lg_rel_fixture '{"base":"main","adapters":{"contracts":"tools/contracts.sh"}}'
  # shellcheck disable=SC2016  # the adapter's own shell text
  lg_contracts_adapter 'case "$1" in
list) echo "{\"id\":\"field:order.total\",\"ledger\":\"core\",\"defined_in\":[\"x/*\"],\"title\":\"Order totals\"}"
      echo "{\"id\":\"flag:new\",\"ledger\":null,\"defined_in\":[\"flags/*.json\"]}" ;;
esac'
  lg_rel_ix
  assert_eq "0" "$LG_RC" "the index builds"
  assert_json_field "$(cat "$LG_IX")" '.contracts[] | select(.id == "field:order.total") | [.ledger, (.defined_in | join(",")), .title] | join("|")' \
    "app|src/order/*.js|Order totals" "registry ledger and defined_in win; the adapter fills the empty title"
  assert_json_field "$(cat "$LG_IX")" '.contracts[] | select(.id == "flag:new") | [(.ledger // "null"), (.defined_in | join(","))] | join("|")' \
    "null|flags/*.json" "an adapter-only contract, as listed"
  assert_json_field "$(cat "$LG_IX")" '[.contracts[] | select(.id == "field:order.total")] | length' "1" "one contract per id"
  teardown
}

test_lg_contracts_adapter_failing_rc2() {
  echo "test: a failing contracts adapter — verbs that show relations exit 2 with its stderr; others run"
  lg_rel_fixture '{"base":"main","adapters":{"contracts":"tools/contracts.sh"}}'
  lg_contracts_adapter 'echo "registry server down" >&2; exit 3'
  lg related app-1
  assert_eq "2" "$LG_RC" "related: exit 2"
  assert_contains "$LG_ERR" "registry server down" "…with the adapter's stderr"
  assert_contains "$LG_ERR" "exited 3" "…and its exit code"
  lg show app-1
  assert_eq "2" "$LG_RC" "show: exit 2"
  lg ls
  assert_eq "0" "$LG_RC" "ls does not need contracts: exit 0"
  lg_rel_ix
  assert_json_field "$(cat "$LG_IX")" '.built.contracts_error | test("registry server down")' "true" "the index records the failure"
  lg_enable '{"base":"main","adapters":{"contracts":"tools/missing.sh"}}'
  lg recheck app-1
  assert_eq "2" "$LG_RC" "a missing adapter file: exit 2"
  teardown
}

test_lg_contracts_adapter_invalid_json_rc2() {
  echo "test: a contracts adapter printing invalid output — exit 2 naming the line"
  lg_rel_fixture '{"base":"main","adapters":{"contracts":"tools/contracts.sh"}}'
  lg_contracts_adapter 'echo "{\"id\":\"flag:a\",\"ledger\":null,\"defined_in\":[]}"; echo "not json"'
  lg related app-1
  assert_eq "2" "$LG_RC" "invalid JSON: exit 2"
  assert_contains "$LG_ERR" "line 2" "…naming the line"
  lg_contracts_adapter 'echo "{\"id\":\"flag:a\",\"ledger\":null}"'
  lg related app-1
  assert_eq "2" "$LG_RC" "a line without defined_in: exit 2"
  assert_contains "$LG_ERR" "contracts contract" "…the contract it breaks"
  lg_contracts_adapter 'echo "{\"id\":\"Not An Id\",\"ledger\":null,\"defined_in\":[]}"'
  lg related app-1
  assert_eq "2" "$LG_RC" "an id that is not <kind>:<name>: exit 2"
  teardown
}

test_lg_msg_claims_squash_bullets() {
  echo "test: trailers read from any message line — a squash body's '* Ledger-Claims: x-3' counts"
  lg_fixture
  lg_enable
  git commit -q --allow-empty -m "Squash of #12" -m "* Ledger-Claims: x-3
* fix things
  - Contract-Change: field:a — cents now
Fixes: #45
Fixes #46
Not-Ledger-Claims: x-9
Ledger-Claims:x-8
ledger-claims: x-4
Ledger-Ack: abc123 — fine"
  lg_call _lg_msg_claims HEAD~1..HEAD
  assert_eq "0" "$LG_RC" "rc 0"
  local h
  h=$(git rev-parse HEAD)
  assert_eq "$(printf '%s\tclaims\tx-3\n%s\tcontract_change\tfield:a — cents now\n%s\tclaims_by_ref\t#45\n%s\tclaims_by_ref\t#46\n%s\tack\tabc123 — fine' "$h" "$h" "$h" "$h" "$h")" \
    "$LG_OUT" "bullets and indents count; no ':', another trailer's suffix, no space after ':' and another case (M6) do not — but a closing keyword's ':' is optional (Fixes #46, R3)"
  teardown
}

test_lg_recheck_marker_set_and_cleared() {
  echo "test: re-check markers — set when a source lands on the base or a consumed contract changes there, cleared by a later commit"
  lg_fixture
  lg_enable '{"base":"main"}'
  lg_registry "$LG_REG_REL"
  local c3 out
  lg_item docs/issues/a.md "key: app-1" "ledger: app" "status: Open" "severity: P1" "summary: Totals are wrong" "changes: [field:order.total]"
  lg_item docs/issues/b.md "key: core-1" "ledger: core" "status: Open" "severity: P0" "summary: Receipts read the total" "consumes: [field:order.total]"
  lg_item docs/issues/c.md "key: core-2" "ledger: core" "status: Open" "severity: P2" "summary: Export breaks" "relates: [depends-on:app-1]"
  lg_item docs/issues/k.md "key: core-3" "ledger: core" "status: Open" "severity: P3" "summary: Calls create" "consumes: [endpoint:create]"
  lg_item docs/issues/x.md "key: app-7" "ledger: app" "status: Open" "severity: P2" "summary: Sheet change" "changes: [component:Sheet]"
  lg_item docs/issues/y.md "key: core-5" "ledger: core" "status: Open" "severity: P2" "summary: Uses the sheet" "consumes: [component:Sheet]"
  mkdir -p src/order && echo 1 > src/order/total.js
  git add -A && git commit -qm items
  lg_rel_ix
  assert_eq "" "$(jq -r '[.items[].recheck_after[]] | join(" ")' "$LG_IX")" "nothing landed: no markers"
  # app-1 is fixed on the base.
  lg_item docs/issues/a.md "key: app-1" "ledger: app" "status: Fixed" "severity: P1" "summary: Totals are wrong" "changes: [field:order.total]"
  printf '\n## Resolution\n\nFixed.\n' >> docs/issues/a.md
  git add -A && git commit -qm "fix app-1"
  lg_rel_ix
  assert_eq "app-1" "$(lg_rc_of core-1)" "a consumer of what app-1 changes: marked"
  assert_eq "app-1" "$(lg_rc_of core-2)" "relates depends-on app-1: marked"
  assert_eq "" "$(lg_rc_of core-3)" "unrelated: not marked"
  assert_eq "" "$(lg_rc_of app-1)" "the terminal item itself: not marked"
  lg show core-2
  assert_contains "$LG_OUT" "re-check: app-1 landed" "show says so"
  out=$(harness_mktemp_d lg-out)
  lg view core --out "$out"
  assert_contains "$(lg_line "$(cat "$out/core.md")" "| core-2 |")" "not started · re-check: app-1 landed" "the view's Status says so"
  # An uncommitted edit clears nothing; a commit does.
  printf '\nre-checked\n' >> docs/issues/b.md
  lg_rel_ix
  assert_eq "app-1" "$(lg_rc_of core-1)" "an uncommitted edit: still marked"
  git add -A && git commit -qm "recheck core-1"
  c3=$(git rev-parse HEAD)
  lg_rel_ix
  assert_eq "" "$(lg_rc_of core-1)" "a later commit to the item: cleared"
  assert_eq "app-1" "$(lg_rc_of core-2)" "…only that item"
  # A base commit changing field:order.total's defined_in.
  echo 2 > src/order/total.js
  git add -A && git commit -qm "totals in cents"
  lg_rel_ix
  assert_eq "field:order.total" "$(lg_rc_of core-1)" "a defined_in change: the consumer is marked with the contract"
  assert_eq "app-1" "$(lg_rc_of core-2)" "an item that does not consume it: unchanged"
  lg show core-1
  assert_contains "$LG_OUT" "re-check: field:order.total changed" "show: <contract> changed"
  # A Contract-Change line (a squash bullet), no defined_in file touched.
  git commit -q --allow-empty -m "api" -m "* Contract-Change: endpoint:create — a new argument"
  lg_rel_ix
  assert_eq "endpoint:create" "$(lg_rc_of core-3)" "a Contract-Change line: marked"
  # Ancestry, not time: a branch cut before the contract change edits
  # core-1 and is merged (--no-ff) after it — its commit never saw the
  # change, so core-1 stays marked; a branch that has the change clears it.
  git checkout -q -b side "$c3"
  printf '\nedited on side\n' >> docs/issues/b.md
  git add -A && git commit -qm "side edit"
  git checkout -q main
  git merge -q --no-ff side -m "merge side"
  lg_rel_ix
  assert_eq "field:order.total" "$(lg_rc_of core-1)" "an edit on a branch without the change: still marked"
  git checkout -q -b side2
  printf '\nedited on side2\n' >> docs/issues/b.md
  git add -A && git commit -qm "side2 edit"
  git checkout -q main
  git merge -q --no-ff side2 -m "merge side2"
  lg_rel_ix
  assert_eq "" "$(lg_rc_of core-1)" "an edit on a branch that has the change: cleared"
  # The base, not the branch: a source closed on a feature branch has not landed.
  git checkout -q -b feat
  lg_item docs/issues/x.md "key: app-7" "ledger: app" "status: Fixed" "severity: P2" "summary: Sheet change" "changes: [component:Sheet]"
  printf '\n## Resolution\n\nDone.\n' >> docs/issues/x.md
  git add -A && git commit -qm "fix app-7 on feat"
  lg_rel_ix
  assert_eq "" "$(lg_rc_of core-5)" "fixed on a branch, not on the base: not marked"
  git checkout -q main
  git merge -q feat
  lg_rel_ix
  assert_eq "app-7" "$(lg_rc_of core-5)" "merged to the base: marked"
  teardown
}

test_lg_render_neighbours_and_suggestions() {
  echo "test: views — ↳ Upstream / Downstream lines (other ledgers), re-check in Status, Unclustered suggestions"
  local ix
  # shellcheck disable=SC2016  # jq source
  ix=$(lg_view_ix '(.items[] | select(.key == "app-1") | .neighbours) = {"upstream":[{"key":"core-1","via":"root-cause"},{"key":"app-2","via":"depends-on"}],"downstream":[{"key":"core-1","via":"field:order.total"}],"siblings":[]}
    | (.items[] | select(.key == "app-2") | .neighbours) = {"upstream":[],"downstream":[{"key":"core-1","via":"field:order.total"}],"siblings":[]}
    | (.items[] | select(.key == "app-2") | .recheck_after) = ["app-7", "field:order.total"]
    | (.items[] | select(.key == "app-4") | .paths) = ["src/order/total.js"]
    | .path_contracts = {"src/order/total.js": ["field:order.total"]}')
  lg_render md "$ix" app page
  assert_eq "0" "$LG_RC" "md: exit 0"
  assert_contains "$LG_OUT" "↳ Upstream: core-1 (core), root-cause — not started" "a relates upstream in another ledger"
  assert_not_contains "$LG_OUT" "↳ Upstream: app-2" "a neighbour in the same ledger: no line"
  assert_eq "1" "$(grep -c '↳ Downstream (consumes `field:order.total`): core-1 (core)$' <<<"$LG_OUT")" \
    "downstream de-duplicated across the cluster's items"
  assert_contains "$(lg_line "$LG_OUT" "| app-2 |")" "not started · re-check: app-7 landed, field:order.total changed" "re-check in Status"
  assert_contains "$LG_OUT" '↳ Suggested cluster for app-4: `field:order.total` — its file src/order/total.js defines it' \
    "an unclustered item's top candidate cluster"
  lg_assert_cond "[ $(lg_lineno "$LG_OUT" "## Unclustered") -lt $(lg_lineno "$LG_OUT" "↳ Suggested cluster") ]" "…under Unclustered"
  lg_render html "$ix" app page
  assert_contains "$LG_OUT" "<b>Suggested cluster</b> for app-4: <code>field:order.total</code>" "html: the suggestion"
  assert_contains "$LG_OUT" "re-check: app-7 landed, field:order.total changed" "html: re-check"
  assert_contains "$LG_OUT" "<b>Upstream</b>: core-1 (core), root-cause" "html: the relates upstream"
}

test_lg_show_neighbours() {
  echo "test: ledger show lists the neighbours (≤ 25 lines)"
  lg_rel_fixture
  lg show core-1
  assert_eq "0" "$LG_RC" "show: exit 0"
  assert_contains "$LG_OUT" "upstream: app-1 (field:order.total), app-3 (field:order.total)" "upstream"
  assert_contains "$LG_OUT" "downstream: core-2 (root-cause)" "downstream"
  assert_contains "$LG_OUT" "siblings: app-2 (field:order.total)" "siblings"
  lg_assert_cond "[ $(wc -l <<<"$LG_OUT") -le 25 ]" "≤ 25 lines"
  lg show app-4
  assert_not_contains "$LG_OUT" "upstream:" "no neighbours: no lines"
  lg_item docs/issues/m.md "key: core-9" "ledger: core" "status: Open" "severity: P3" "summary: Many" \
    "relates: [sibling:app-1, sibling:app-2, sibling:app-3, sibling:app-4, sibling:app-5]"
  lg show core-9
  assert_contains "$LG_OUT" "siblings: app-1 (sibling), app-2 (sibling), app-3 (sibling) +2 more" "lists cut at 3"
  teardown
}

# --- Task 9 fix round 1 --------------------------------------------------------------

# lg_window_fixture <with-M2 0|1>: the reviewer's repro (I1). core-1 and
# core-2 consume field:order.total; side is cut at M0; main: M1 changes
# src/order/total.js, then (with 1) M2 edits core-2; side: S1 edits
# core-1; side merged --no-ff.
lg_window_fixture() {
  lg_fixture
  lg_enable '{"base":"main"}'
  lg_registry "$LG_REG_REL"
  lg_item docs/issues/b.md "key: core-1" "ledger: core" "status: Open" "severity: P1" "summary: Reads the total" "consumes: [field:order.total]"
  lg_item docs/issues/c.md "key: core-2" "ledger: core" "status: Open" "severity: P2" "summary: Also reads it" "consumes: [field:order.total]"
  mkdir -p src/order && echo 1 > src/order/total.js
  git add -A && git commit -qm M0
  git branch -q side
  echo 2 > src/order/total.js
  git add -A && git commit -qm "M1 contract change"
  if [ "$1" = 1 ]; then
    printf '\nedited on main\n' >> docs/issues/c.md
    git add -A && git commit -qm "M2 edit core-2"
  fi
  git checkout -q side
  printf '\nedited on side\n' >> docs/issues/b.md
  git add -A && git commit -qm "S1 edit core-1"
  git checkout -q main
  git merge -q --no-ff side -m "M3 merge side"
}

test_lg_recheck_window_side_branch() {
  echo "test: re-check window — a change older than another item's last commit still marks a side-branch item that never saw it (I1)"
  lg_window_fixture 1
  lg_rel_ix
  assert_eq "field:order.total" "$(lg_rc_of core-1)" "S1 (side, cut before M1) never saw M1: marked"
  assert_eq "" "$(lg_rc_of core-2)" "M2 (after M1 on the line): not marked"
  teardown
  echo "test: re-check window — the control (no M2): both marked"
  lg_window_fixture 0
  lg_rel_ix
  assert_eq "field:order.total" "$(lg_rc_of core-1)" "control: core-1 marked"
  assert_eq "field:order.total" "$(lg_rc_of core-2)" "control: core-2 marked"
  teardown
}

test_lg_relates_edges_sorted_unique() {
  echo "test: relates edges — sorted by key then via, no duplicates, however the relates list is ordered (M3)"
  lg_fixture
  lg_enable
  lg_item docs/issues/a.md "key: a-1" "ledger: a" "status: Open" "summary: A"
  lg_item docs/issues/b.md "key: b-2" "ledger: b" "status: Open" "summary: B"
  lg_item docs/issues/c.md "key: c-1" "ledger: c" "status: Open" "summary: C" \
    "relates: [depends-on:b-2, root-cause:a-1, sibling:a-1, a-1]"
  lg_rel_ix
  assert_eq "a-1/root-cause b-2/depends-on" "$(lg_nb c-1 upstream)" "upstream sorted by key"
  assert_eq "a-1/sibling" "$(lg_nb c-1 siblings)" "sibling:a-1 and a bare a-1: one edge"
  assert_eq "c-1/root-cause" "$(lg_nb a-1 downstream)" "the other side"
  assert_eq "c-1/sibling" "$(lg_nb a-1 siblings)" "the other side, once"
  teardown
}

test_lg_recheck_verb_relates_kinds() {
  echo "test: ledger recheck — a relates entry of an unknown kind is no dependent (M5)"
  lg_rel_fixture
  lg_item docs/issues/k.md "key: core-7" "ledger: core" "status: Open" "severity: P3" "summary: Blocks it" "relates: [blocks:app-5]"
  lg_item docs/issues/l.md "key: core-8" "ledger: core" "status: Open" "severity: P3" "summary: A sibling" "relates: [Sibling:APP-5]"
  lg recheck app-5
  assert_eq "0" "$LG_RC" "exit 0"
  assert_not_contains "$LG_OUT" "core-7" "blocks: is no relation"
  assert_contains "$LG_OUT" "core-8  via sibling" "a sibling (any case) is"
  teardown
}

test_lg_msg_claims_case_sensitive() {
  echo "test: trailer names match as configured — case-sensitive (M6)"
  lg_fixture
  lg_enable
  git commit -q --allow-empty -m "prose" -m "fixes: the crash
Fixes: #7
ledger-claims: x-4
* Ledger-Claims: x-5"
  lg_call _lg_msg_claims HEAD~1..HEAD
  local h
  h=$(git rev-parse HEAD)
  assert_eq "$(printf '%s\tclaims_by_ref\t#7\n%s\tclaims\tx-5' "$h" "$h")" "$LG_OUT" "only the configured spelling counts"
  teardown
}

test_lg_msg_claims_ref_no_colon() {
  echo "test: claims_by_ref — a closing keyword at a line start, ':' optional, any case, then #<digits>; mid-sentence, owner/repo#N and no #N do not count (R3)"
  lg_fixture
  lg_enable
  git commit -q --allow-empty -m "Fixes #12" -m "closes #13.
* RESOLVES: #14, and more
  - Fixes  #15
this fixes #16
Fixes o/r#17
Fixes #18x
Fixes:#19
Fixes: the crash
Fixesx #20
Closes: abc-21
Resolves #22
Fixes #0
Fixes#23
Closes:  #24"
  lg_call _lg_msg_claims HEAD~1..HEAD
  assert_eq "0" "$LG_RC" "rc 0"
  local h
  h=$(git rev-parse HEAD)
  assert_eq "$(printf '%s\tclaims_by_ref\t#%s\n' "$h" 12 "$h" 13 "$h" 14 "$h" 15 "$h" 19 "$h" 22 "$h" 24)" "$LG_OUT" \
    "Fixes #12 (the subject), closes #13., RESOLVES: #14, Fixes  #15, Fixes:#19 (m8), Resolves #22, Closes:  #24 — not #0, not Fixes#23"
  teardown
}

# shellcheck disable=SC2031  # lg_in runs this body where lg_source set the _LG_*/_SCRATCH globals
lg_t_index_valid_tail() {
  local ix cut
  ix=$(_lg_index)
  lg_rc _lg_ix_valid "$ix"
  assert_eq "0" "$LG_RC" "a whole index is valid"
  cut="$_SCRATCH/cut.json"
  sed '$d' "$ix" > "$cut"
  lg_rc _lg_ix_valid "$cut"
  assert_eq "1" "$LG_RC" "cut after the last item line (no tail): not valid"
  sed '$ s/.$//' "$ix" > "$cut"
  lg_rc _lg_ix_valid "$cut"
  assert_eq "1" "$LG_RC" "a tail cut short: not valid"
}

test_lg_index_valid_needs_tail() {
  echo "test: _lg_ix_valid requires the tail line (M7)"
  lg_rel_fixture
  lg_in lg_t_index_valid_tail
  teardown
}

# lg_ev_canon <events-file>: its records as sorted "<commit>|<record>" lines.
lg_ev_canon() {
  awk 'NR == 1 { next }
    $0 == "@" { getline c; next }
    { k = $0; n = (k == "A") ? 2 : (k == "R") ? 3 : 1; r = k
      for (i = 1; i <= n; i++) { getline x; r = r "|" x }
      print c "|" r }' "$1" | LC_ALL=C sort
}

# shellcheck disable=SC2031  # lg_in runs this body where lg_source set the _LG_*/_SCRATCH globals
lg_t_events_derive_exact() {
  local g="$_SCRATCH/g" dirs="$_SCRATCH/dirs" H B derived cold
  _lg_cfg '[(.items.globs // [])[]?, (.items.archive_globs // [])[]?] | .[] | strings' > "$g"
  _lg_glob_dirs "$g" "$dirs"
  H=$(git rev-parse HEAD)
  B=$(git rev-parse newer)
  rm -rf "$_LG_CACHE"
  mkdir -p "$_LG_CACHE"
  _lg_ix_events "$H" "$dirs"
  _lg_ix_graph "$B"
  _lg_ix_events_base "$B" "$dirs" "$H" "$_LG_GRAPH" 2> "$_SCRATCH/trace"
  assert_contains "$(cat "$_SCRATCH/trace")" "dates-derive" "diverged: derived from HEAD's map"
  derived=$(lg_ev_canon "$_LG_EVENTS")
  rm -f "$_LG_CACHE/dates-$B.tsv"
  _lg_ix_events "$B" "$dirs" 2> "$_SCRATCH/trace"
  assert_contains "$(cat "$_SCRATCH/trace")" "dates-cold" "the control: a cold walk of the base"
  cold=$(lg_ev_canon "$_LG_EVENTS")
  assert_eq "$cold" "$derived" "the derived records are the cold walk's"
  lg_assert_cond "[ $(wc -l <<<"$cold") -gt 5 ]" "…a non-trivial history"
  assert_eq "2" "$(grep -c '|R|' <<<"$cold")" "…with the shared rename and the one inside the range (R records)"
}

test_lg_recheck_base_not_head() {
  echo "test: re-check with the base ≠ HEAD — the base's events come from HEAD's walk (I2), same markers"
  lg_rel_fixture
  local expect
  # app-1 fixed on main (the base).
  lg_item docs/issues/a.md "key: app-1" "ledger: app" "status: Fixed" "severity: P1" "summary: Totals are wrong" \
    "changes: [field:order.total]" "related-files: [src/util/a.js, src/util/b.js]"
  printf '\n## Resolution\n\nFixed.\n' >> docs/issues/a.md
  git add -A && git commit -qm "fix app-1"
  # A rename in the history both sides share (the derive filter keeps it).
  git mv docs/issues/g.md docs/issues/g1.md && git commit -qm "rename app-5"
  lg_rel_ix
  expect=$(jq -c '[.items[] | {key, recheck_after}]' "$LG_IX")
  # HEAD ahead of the base (a rename there too: the derive filter drops it).
  git checkout -q -b ahead
  printf '\nmore\n' >> docs/issues/i.md
  git add -A && git commit -qm "ahead"
  git mv docs/issues/h.md docs/issues/h1.md && git commit -qm "rename app-6 on ahead"
  rm -rf "$(git rev-parse --git-common-dir)/doc-superpowers"
  DOC_TOOLS_LEDGER_TRACE=1 lg_rel_ix
  assert_contains "$LG_ERR" "dates-derive" "the base's events derived from HEAD's walk"
  assert_eq "$expect" "$(jq -c '[.items[] | {key, recheck_after}]' "$LG_IX")" "HEAD ahead: the base's markers"
  # The base with commits HEAD lacks: core-3 consumes what app-3 changes; app-3 fixed on the base only.
  git checkout -q main
  lg_item docs/issues/i.md "key: core-3" "ledger: core" "status: Open" "severity: P3" "summary: Specified together" "consumes: [field:order.total]"
  git add -A && git commit -qm "core-3 consumes"
  git checkout -q -b newer
  lg_item docs/issues/d.md "key: app-3" "ledger: app" "status: Fixed" "severity: P2" "summary: Tax rounding" "changes: [field:order.total]"
  printf '\n## Resolution\n\nFixed.\n' >> docs/issues/d.md
  git add -A && git commit -qm "fix app-3 on newer"
  git checkout -q main
  lg_enable '{"base":"newer"}'
  rm -rf "$(git rev-parse --git-common-dir)/doc-superpowers"
  DOC_TOOLS_LEDGER_TRACE=1 lg_rel_ix
  assert_eq "1" "$(grep -c 'dates-cold' <<<"$LG_ERR")" "one cold walk (HEAD's): the base extends it (HEAD is its ancestor)"
  assert_eq "app-3" "$(lg_rc_of core-3)" "a source fixed only on the base: marked (app-1 landed before core-3's last commit)"
  # Inside the diverged range (base commits HEAD lacks): a rename on a side
  # branch, an item edit on the base, and the side merged --no-ff — so a
  # record-size mistake shared by the code and lg_ev_canon (R carries three
  # fields, A two, the others one) would misalign one of the two walks.
  git checkout -q -b side2 newer
  git mv docs/issues/f.md docs/issues/f1.md && git commit -qm "rename app-4 on side2"
  git checkout -q newer
  printf '\nbase edit\n' >> docs/issues/c.md
  git add -A && git commit -qm "edit app-2 on newer"
  git merge -q --no-ff side2 -m "merge side2 into newer"
  git checkout -q main
  # Diverged (HEAD ahead lacks the base's last commits): derived, and the
  # same records a cold walk of the base gives.
  git checkout -q ahead
  DOC_TOOLS_LEDGER_TRACE=1 lg_in lg_t_events_derive_exact
  teardown
}

# --- Task 8 review carry-over (Task 9, first commit) --------------------------------

test_lg_publish_hook_declined_not_moved() {
  echo "test: a push a remote hook declines ('[remote rejected]') says 'failed', not 'moved' (exit 2)"
  lg_publish_fixture
  printf '#!/bin/sh\necho "hook says no" >&2\nexit 1\n' > "$LG_REMOTE/hooks/pre-receive"
  chmod +x "$LG_REMOTE/hooks/pre-receive"
  lg publish
  assert_eq "2" "$LG_RC" "exit 2"
  assert_contains "$LG_ERR" "the push to origin doc-ledger-views failed" "says the push failed"
  assert_contains "$LG_ERR" "remote rejected" "…with git's reason"
  assert_not_contains "$LG_ERR" "moved" "…without claiming the branch moved"
  teardown
}

test_lg_render_resolution_first_nonempty() {
  echo "test: the superseded line uses the first NON-EMPTY resolution line"
  local ix
  ix=$(lg_view_ix '(.items[] | select(.key == "app-7") | .resolution) = "\n  \r\nReal first line.\nsecond"')
  lg_render md "$ix" app page
  assert_eq "- app-7 → app-1: Real first line." "$(lg_line "$LG_OUT" "- app-7")" "md: blank lines skipped"
  lg_render html "$ix" app page
  assert_contains "$LG_OUT" '<div class="res">Real first line.</div>' "html: blank lines skipped"
  ix=$(lg_view_ix '(.items[] | select(.key == "app-7") | .resolution) = " \n\n"')
  lg_render md "$ix" app page
  assert_eq "- app-7 → app-1: (no resolution)" "$(lg_line "$LG_OUT" "- app-7")" "only blank lines: (no resolution)"
}

test_lg_render_pr_url_pipe() {
  echo "test: a PR url's '|' is percent-encoded in the markdown link target (the table stays intact)"
  local ix row
  ix=$(lg_view_ix '(.items[] | select(.key == "app-2") | .pr) = {"number": 6, "url": "https://example.test/pr/6?a|b c)"}')
  lg_render md "$ix" app page
  row=$(lg_line "$LG_OUT" "| app-2 ")
  assert_contains "$row" "[#6](https://example.test/pr/6?a%7Cb%20c%29)" "| → %7C (and space, ) as before)"
  assert_eq "10" "$(printf '%s' "$row" | sed 's/\\|//g' | tr -cd '|' | wc -c | tr -d ' ')" "still 9 cells (10 pipes)"
}

test_lg_rev_cache_ignores_head() {
  echo "test: an --rev index is keyed by the commit and the code, not the local HEAD"
  lg_publish_fixture
  local base
  base=$(git rev-parse refs/remotes/origin/main)
  DOC_TOOLS_LEDGER_TRACE=1 lg publish --dry-run
  assert_eq "0" "$LG_RC" "first publish --dry-run: exit 0"
  assert_contains "$LG_ERR" "index-build" "the base index is built"
  # A local commit that does not move the base.
  echo local > src/local.txt
  git add -A && git commit -qm local
  DOC_TOOLS_LEDGER_TRACE=1 lg publish --dry-run
  assert_eq "0" "$LG_RC" "second publish --dry-run: exit 0"
  assert_contains "$LG_ERR" "index-hit" "same base, another HEAD: a cache hit"
  assert_not_contains "$LG_ERR" "index-build" "…nothing rebuilt"
  assert_eq "$base" "$(git rev-parse refs/remotes/origin/main)" "the base did not move"
  teardown
}

test_lg_publish_link_prefix() {
  echo "test: publish links — a GitHub remote's blob URL, else relative to the views branch"
  lg_fixture
  lg_enable
  git remote add gh git@github.com:own-er/re.po.git
  git remote add gh2 https://github.com/own/repo
  git remote add other /srv/git/repo.git
  lg_call _lg_publish_link gh main doc-ledger-views
  assert_eq "0|https://github.com/own-er/re.po/blob/main/" "$LG_RC|$LG_OUT" "ssh GitHub remote (.git dropped)"
  lg_call _lg_publish_link gh2 "release/1 x" doc-ledger-views
  assert_eq "https://github.com/own/repo/blob/release/1%20x/" "$LG_OUT" "https remote; a branch with a slash and a space"
  lg_call _lg_publish_link other main doc-ledger-views
  assert_eq "../main/" "$LG_OUT" "another host: ../<branch>/ (the page sits at blob/<views>/)"
  lg_call _lg_publish_link other main views/ledger
  assert_eq "../../main/" "$LG_OUT" "one ../ per segment of the views branch"
  teardown
}

# --- Task 9 review carry-over (Task 10, first commit) --------------------------------

# lg_t_shallow_graph <child> <parent>: the base's graph lists <child> with
# <parent> as its parent.
# shellcheck disable=SC2031  # lg_in runs this body where lg_source set the _LG_*/_SCRATCH globals
lg_t_shallow_graph() {
  _lg_ix_graph "$(git rev-parse main)"
  assert_eq "$1 $2" "$(grep "^$1" "$_LG_GRAPH")" "the graph gives $1 its parent"
}

test_lg_shallow_deepen_rebuilds_caches() {
  echo "test: a shallow clone — the graph, dates and index caches follow .git/shallow; deepening rebuilds them"
  lg_fixture
  lg_enable '{"base":"main"}'
  lg_registry "$LG_REG_REL"
  # C1: app-1 (fixed, changes field:order.total) and core-1 (consumes it);
  # C2: an edit to core-1; C3: outside the items.
  lg_item docs/issues/s.md "key: app-1" "ledger: app" "status: Fixed" "severity: P2" "summary: Source fixed" "changes: [field:order.total]"
  printf '\n## Resolution\n\nDone.\n' >> docs/issues/s.md
  lg_item docs/issues/x.md "key: core-1" "ledger: core" "status: Open" "severity: P2" "summary: Consumer" "consumes: [field:order.total]"
  git add -A
  GIT_COMMITTER_DATE="2026-01-05T00:00:00Z" GIT_AUTHOR_DATE="2026-01-05T00:00:00Z" git commit -qm C1
  printf '\nedited\n' >> docs/issues/x.md
  git add -A
  GIT_COMMITTER_DATE="2026-02-05T00:00:00Z" GIT_AUTHOR_DATE="2026-02-05T00:00:00Z" git commit -qm C2
  echo z > src/z.txt
  git add -A
  GIT_COMMITTER_DATE="2026-03-05T00:00:00Z" GIT_AUTHOR_DATE="2026-03-05T00:00:00Z" git commit -qm C3
  local clone c1 c2 saved="$TEST_DIR"
  c1=$(git rev-parse HEAD~2)
  c2=$(git rev-parse HEAD~1)
  clone="$(harness_mktemp_d lg-shallow)/clone"
  git clone -q --depth 2 "file://$TEST_DIR" "$clone"
  cd "$clone"
  assert_eq "true" "$(git rev-parse --is-shallow-repository)" "a shallow clone (C3, C2)"
  lg_call_in "$clone" _lg_index
  LG_IX=$LG_OUT
  assert_eq "2026-02-05" "$(jq -r '.items[] | select(.key == "app-1") | .date' "$LG_IX")" "shallow: app-1 dated by the boundary commit"
  assert_eq "" "$(lg_rc_of core-1)" "shallow: no marker"
  git fetch -q --deepen=1 origin
  assert_eq "true" "$(git rev-parse --is-shallow-repository)" "still shallow, one commit deeper"
  lg_call_in "$clone" _lg_index
  LG_IX=$LG_OUT
  assert_eq "2026-01-05" "$(jq -r '.items[] | select(.key == "app-1") | .date' "$LG_IX")" "deepened: app-1 dated by C1 (the dates and index caches were rebuilt)"
  assert_eq "" "$(lg_rc_of core-1)" "deepened: no false re-check marker (app-1 landed before core-1's last commit)"
  TEST_DIR=$clone
  lg_in lg_t_shallow_graph "$c2" "$c1"
  TEST_DIR=$saved
  cd "$TEST_DIR"
  rm -rf "$(dirname "$clone")"
  teardown
}

# --- Task 10: PR adapter, remote cache, review / merged status ----------------------

# lg_fake_gh: a fake `gh` first on PATH (never the real one, never the
# network). It logs its arguments (LG_GH/args) and, when LG_GH/fail exists,
# prints that file on stderr and exits 1 for every command. `gh pr list`:
# counts the PR adapter's runs (LG_GH/calls: its `--state open` calls —
# ledger-pr-gh.sh makes one per run) and prints the PRs of LG_GH/prs.json
# in the asked --state (all when none). The issue commands (Task 13) keep
# LG_GH/issues.json as the repository's issues: `issue list` prints it
# (LG_GH/icalls counts the calls), `issue view <n>` the issue, `issue edit
# <n>` applies --add-label / --remove-label (comma lists) and --body-file to
# it (Task 15: it fails for <n> while LG_GH/view-fail-<n> exists), `issue
# comment <n> --body-file F` appends "<n>\t<text>" to
# LG_GH/comments, `issue create --title T --body-file F` adds an open issue
# numbered one past the highest and prints its URL (no URL when
# LG_GH/create-nourl exists); `label create <name>`
# records it in LG_GH/labels, and refuses a recorded one ("already exists").
# `repo view` (Task 14: ledger init's GitHub check) prints
# {"hasIssuesEnabled": true}, false when LG_GH/issues-off exists.
# lg_fake_gh_off restores PATH.
lg_fake_gh() {
  LG_GH=$(harness_mktemp_d lg-gh)
  LG_GH_BIN=$(harness_mktemp_d lg-ghbin)
  printf '[]\n' > "$LG_GH/prs.json"
  printf '[]\n' > "$LG_GH/issues.json"
  printf "#!/bin/sh\nd='%s'\n" "$LG_GH" > "$LG_GH_BIN/gh"
  cat >> "$LG_GH_BIN/gh" <<'EOF'
st=""; prev=""
for a in "$@"; do
  if [ "$prev" = --state ]; then st=$a; fi
  prev=$a
done
printf '%s\n' "$*" >> "$d/args"
# opt <name> <args…>: the value after --<name> ("" when absent).
opt() {
  o=$1; shift; v=""; p=""
  for a in "$@"; do
    if [ "$p" = "$o" ]; then v=$a; fi
    p=$a
  done
  printf '%s' "$v"
}
case "$1 $2" in
  "repo view")
    if [ -f "$d/fail" ]; then cat "$d/fail" >&2; exit 1; fi
    if [ -f "$d/issues-off" ]; then echo '{"hasIssuesEnabled":false}'; else echo '{"hasIssuesEnabled":true}'; fi
    exit 0 ;;
  "issue list")
    n=$(cat "$d/icalls" 2>/dev/null || echo 0)
    echo $((n + 1)) > "$d/icalls"
    if [ -f "$d/fail" ]; then cat "$d/fail" >&2; exit 1; fi
    cat "$d/issues.json"
    exit 0 ;;
  "issue view")
    if [ -f "$d/fail" ]; then cat "$d/fail" >&2; exit 1; fi
    if [ -f "$d/view-fail-$3" ]; then echo "HTTP 502: Bad Gateway" >&2; exit 1; fi
    jq -e --argjson n "$3" '.[] | select(.number == $n)' "$d/issues.json" \
      || { echo "GraphQL: Could not resolve to an issue or pull request with the number of $3. (repository.issue)" >&2; exit 1; }
    exit 0 ;;
  "issue edit")
    if [ -f "$d/fail" ]; then cat "$d/fail" >&2; exit 1; fi
    n=$3
    add=$(opt --add-label "$@"); rm=$(opt --remove-label "$@"); bf=$(opt --body-file "$@")
    jq --argjson n "$n" --arg add "$add" --arg rm "$rm" --arg bf "$bf" --rawfile body "${bf:-/dev/null}" '
      map(if .number == $n then
            (if $rm != "" then .labels |= map(select(.name as $x | ($rm | split(",") | index([$x])) | not)) else . end)
            | (if $add != "" then .labels += [$add | split(",")[] | {name: .}] else . end)
            | (if $bf != "" then .body = $body else . end)
          else . end)' "$d/issues.json" > "$d/issues.tmp" && mv "$d/issues.tmp" "$d/issues.json"
    echo "https://github.com/o/r/issues/$n"
    exit 0 ;;
  "issue comment")
    if [ -f "$d/fail" ]; then cat "$d/fail" >&2; exit 1; fi
    bf=$(opt --body-file "$@")
    { printf '%s\t' "$3"; cat "$bf"; printf '\n'; } >> "$d/comments"
    echo "https://github.com/o/r/issues/$3#issuecomment-1"
    exit 0 ;;
  "issue create")
    if [ -f "$d/fail" ]; then cat "$d/fail" >&2; exit 1; fi
    t=$(opt --title "$@"); bf=$(opt --body-file "$@")
    n=$(jq '([.[].number] | max // 0) + 1' "$d/issues.json")
    jq --argjson n "$n" --arg t "$t" --rawfile body "$bf" \
      '. + [{number: $n, title: $t, body: $body, state: "OPEN", stateReason: null, labels: [], createdAt: "2026-10-13T00:00:00Z", updatedAt: "2026-10-13T00:00:00Z", url: "https://github.com/o/r/issues/\($n)"}]' \
      "$d/issues.json" > "$d/issues.tmp" && mv "$d/issues.tmp" "$d/issues.json"
    echo "Creating issue in o/r"
    echo
    if [ -f "$d/create-nourl" ]; then echo "(no URL)"; exit 0; fi
    echo "https://github.com/o/r/issues/$n"
    exit 0 ;;
  "label create")
    if [ -f "$d/fail" ]; then cat "$d/fail" >&2; exit 1; fi
    if grep -qxF -- "$3" "$d/labels" 2>/dev/null; then
      echo "label with name \"$3\" already exists; use \`--force\` to update its color and description" >&2
      exit 1
    fi
    printf '%s\n' "$3" >> "$d/labels"
    exit 0 ;;
esac
if [ "$st" = open ] || [ -z "$st" ]; then
  n=$(cat "$d/calls" 2>/dev/null || echo 0)
  echo $((n + 1)) > "$d/calls"
fi
if [ -f "$d/fail" ]; then cat "$d/fail" >&2; exit 1; fi
if [ -z "$st" ] || [ "$st" = all ]; then cat "$d/prs.json"; exit 0; fi
jq --arg s "$st" '[.[] | select((.state | ascii_downcase) == $s)]' "$d/prs.json"
EOF
  chmod +x "$LG_GH_BIN/gh"
  LG_PATH_SAVED=$PATH
  PATH="$LG_GH_BIN:$PATH"
}
lg_fake_gh_off() {
  PATH=$LG_PATH_SAVED
  rm -rf "$LG_GH" "$LG_GH_BIN"
}
lg_gh_calls() {
  cat "$LG_GH/calls" 2>/dev/null || echo 0
}
# lg_gh_icalls: the `gh issue list` calls so far.
lg_gh_icalls() {
  cat "$LG_GH/icalls" 2>/dev/null || echo 0
}

LG_PR_CFG='{"adapters":{"pr":"doc-superpowers:ledger-pr-gh"},"trailers":{"claims_by_path":["Ledger-Claims-Path"]}}'

# lg_pr_fixture [config]: lg_keys_fixture (a bare remote, origin/main the
# base) with config adapters.pr = doc-superpowers:ledger-pr-gh over a fake
# gh (lg_fake_gh) and Ledger-Claims-Path as a claims_by_path trailer.
# Items on the base:
#   x-1 open   claimed (Ledger-Claims: x-1, x-3) on open PR #12's head
#   x-2 open   modified on PR #12's head
#   x-3 open   claimed on the base too → merged (before in review)
#   x-4 open   claimed by path on the base (Ledger-Claims-Path)
#   x-5 open   modified by merged PR #9 (a --no-ff merge on the base)
#   x-6 fixed  claimed on PR #12 → shipped (the class first)
#   x-7 open   owed: docs; claimed on the base (a squash-style bullet)
#   y-1 open   claimed on PR #13, whose head never reached this clone
#   y-2 open   claimed on closed PR #4 → nothing
#   y-3 open   claimed on open PR #15 (head "feat/-dash")
#   x-8 open   claimed (trailer) on merged PR #10's head (still on the remote)
#   y-5 open   only its file edited on merged PR #10's head → nothing
# PR #12's head is "feat/ünï-x"; open PR #16 is cross-repository (a fork)
# with the same head name — never attributed through origin's branch.
# Merged PR #9 (its branch deleted) only edited x-5's file → nothing.
# LG_PR_M: PR #9's merge commit; LG_PR_SQ: PR #10's merged head
# (headRefOid — a merged PR is walked from it, never from its branch).
lg_pr_fixture() {
  local c="$LG_PR_CFG"
  if [ $# -gt 0 ]; then c=$1; fi
  lg_fake_gh
  lg_keys_fixture "$c"
  lg_item docs/issues/a.md "key: x-1" "ledger: x" "status: Open" "severity: P1" "summary: Claimed on the PR branch"
  lg_item docs/issues/b.md "key: x-2" "ledger: x" "status: Open" "severity: P1" "summary: Edited on the PR branch"
  lg_item docs/issues/c.md "key: x-3" "ledger: x" "status: Open" "severity: P2" "summary: Claimed on the base"
  lg_item docs/issues/d.md "key: x-4" "ledger: x" "status: Open" "severity: P2" "summary: Claimed by path on the base"
  lg_item docs/issues/e.md "key: x-5" "ledger: x" "status: Open" "severity: P2" "summary: Touched by a merged PR"
  lg_item docs/issues/f.md "key: x-6" "ledger: x" "status: Fixed" "severity: P3" "summary: Already fixed"
  lg_item docs/issues/g.md "key: x-7" "ledger: x" "status: Open" "severity: P3" "summary: Merged, docs owed" "owed: docs"
  lg_item docs/issues/h.md "key: y-1" "ledger: y" "status: Open" "severity: P2" "summary: Claimed on an unfetched head"
  lg_item docs/issues/i.md "key: y-2" "ledger: y" "status: Open" "severity: P2" "summary: Claimed on a closed PR"
  lg_item docs/issues/j.md "key: y-3" "ledger: y" "status: Open" "severity: P2" "summary: Claimed on a dash-led head"
  lg_item docs/issues/k.md "key: x-8" "ledger: x" "status: Open" "severity: P3" "summary: Claimed on a merged PR head"
  lg_item docs/issues/l.md "key: y-5" "ledger: y" "status: Open" "severity: P3" "summary: Edited on a merged PR head"
  printf '\n## Resolution\n\nDone.\n' >> docs/issues/f.md
  git add -A && git commit -qm items
  git checkout -q -b merged-branch
  printf '\nfixed here\n' >> docs/issues/e.md
  git add -A && git commit -qm "work on it"
  git checkout -q main
  git merge -q --no-ff merged-branch -m "Merge pull request #9"
  LG_PR_M=$(git rev-parse HEAD)
  git branch -q -D merged-branch
  git commit -q --allow-empty -m "base work" -m "Ledger-Claims: x-3
Ledger-Claims-Path: docs/issues/d.md
* Ledger-Claims: x-7"
  git push -q origin main
  git checkout -q -b "feat/ünï-x"
  git commit -q --allow-empty -m "review work" -m "Ledger-Claims: x-1, x-3
Ledger-Claims: x-6"
  printf '\nedited on the PR\n' >> docs/issues/b.md
  git add -A && git commit -qm "touch it"
  git push -q origin "feat/ünï-x"
  git checkout -q -b "feat/-dash" main
  git commit -q --allow-empty -m "dash work" -m "Ledger-Claims: y-3"
  git push -q origin "feat/-dash"
  git checkout -q -b closed-branch main
  git commit -q --allow-empty -m "abandoned" -m "Ledger-Claims: y-2"
  git push -q origin closed-branch
  git checkout -q -b squashed main
  git commit -q --allow-empty -m "squash me" -m "Ledger-Claims: x-8"
  printf '\nedited on the merged PR\n' >> docs/issues/l.md
  git add -A && git commit -qm "touch y-5"
  git push -q origin squashed
  git checkout -q main
  LG_PR_SQ=$(git rev-parse squashed)
  git branch -q -D "feat/ünï-x" "feat/-dash" closed-branch squashed
  git fetch -q origin
  cat > "$LG_GH/prs.json" <<EOF
[{"number":16,"headRefName":"feat/ünï-x","state":"OPEN","url":"https://github.com/o/r/pull/16","mergeCommit":null,"isCrossRepository":true},
 {"number":15,"headRefName":"feat/-dash","state":"OPEN","url":"https://github.com/o/r/pull/15","mergeCommit":null},
 {"number":13,"headRefName":"gone","state":"OPEN","url":"https://github.com/o/r/pull/13","mergeCommit":null},
 {"number":12,"headRefName":"feat/ünï-x","state":"OPEN","url":"https://github.com/o/r/pull/12","mergeCommit":null},
 {"number":10,"headRefName":"squashed","headRefOid":"$LG_PR_SQ","state":"MERGED","url":"https://github.com/o/r/pull/10","mergeCommit":{"oid":"0123456789abcdef0123456789abcdef01234567"}},
 {"number":9,"headRefName":"merged-branch","state":"MERGED","url":"https://github.com/o/r/pull/9","mergeCommit":{"oid":"$LG_PR_M"}},
 {"number":4,"headRefName":"closed-branch","state":"CLOSED","url":"https://github.com/o/r/pull/4","mergeCommit":null}]
EOF
}

lg_pr_teardown() {
  lg_fake_gh_off
  teardown
}

# lg_pr_status <key>: the item's display status from `ledger ls --format json`
# in LG_OUT.
lg_pr_status() {
  jq -r --arg k "$1" '.items[] | select(.key == $k) | .display' <<<"$LG_OUT"
}

# lg_remote_file <name>: the remote cache file(s) of <name>.
lg_remote_file() {
  ls "$(git rev-parse --git-common-dir)/doc-superpowers/ledger/remote/$1"-*.json 2>/dev/null
}

test_lg_pr_adapter_normalises() {
  echo "test: ledger-pr-gh.sh list — gh pr list (open, then merged) normalised to {number, head, state, url, merge_commit, cross} lines"
  lg_fixture
  lg_fake_gh
  cat > "$LG_GH/prs.json" <<'EOF'
[{"number":12,"headRefName":"feat/ünï-x","headRefOid":"1111111111111111111111111111111111111111","state":"OPEN","url":"https://github.com/o/r/pull/12","mergeCommit":null,"isCrossRepository":false},
 {"number":16,"headRefName":"-dash","state":"OPEN","url":"https://github.com/o/r/pull/16","mergeCommit":null,"isCrossRepository":true},
 {"number":9,"headRefName":"done","state":"MERGED","url":"https://github.com/o/r/pull/9","mergeCommit":{"oid":"0123456789abcdef0123456789abcdef01234567"}},
 {"number":4,"headRefName":"gone","state":"CLOSED","url":"https://github.com/o/r/pull/4","mergeCommit":null}]
EOF
  local out rc=0
  out=$("$BASH_BIN" "$REPO_DIR/scripts/adapters/ledger-pr-gh.sh" list 2>&1) || rc=$?
  assert_eq "0" "$rc" "exit 0"
  assert_eq '{"number":12,"head":"feat/ünï-x","head_oid":"1111111111111111111111111111111111111111","state":"open","url":"https://github.com/o/r/pull/12","merge_commit":null,"cross":false}
{"number":16,"head":"-dash","head_oid":null,"state":"open","url":"https://github.com/o/r/pull/16","merge_commit":null,"cross":true}
{"number":9,"head":"done","head_oid":null,"state":"merged","url":"https://github.com/o/r/pull/9","merge_commit":"0123456789abcdef0123456789abcdef01234567","cross":false}' "$out" \
    "one compact line per open, then merged PR (closed ones not asked for); state lowercased; headRefOid as head_oid; mergeCommit.oid; isCrossRepository as cross"
  assert_eq "pr list --state open --limit 1000 --json number,headRefName,headRefOid,state,url,mergeCommit,isCrossRepository
pr list --state merged --limit 500 --json number,headRefName,headRefOid,state,url,mergeCommit,isCrossRepository" "$(cat "$LG_GH/args")" "the two gh calls"
  printf '[]\n' > "$LG_GH/prs.json"
  out=$("$BASH_BIN" "$REPO_DIR/scripts/adapters/ledger-pr-gh.sh" list 2>&1) || rc=$?
  assert_eq "0|" "$rc|$out" "no PRs: exit 0, no lines"
  rc=0
  "$BASH_BIN" "$REPO_DIR/scripts/adapters/ledger-pr-gh.sh" bogus >/dev/null 2>&1 || rc=$?
  assert_eq "3" "$rc" "an unknown subcommand: usage (3)"
  lg_fake_gh_off
  teardown
}

test_lg_pr_adapter_gh_missing_rc2() {
  echo "test: ledger-pr-gh.sh — gh missing or failing: exit 2 with the reason on stderr"
  lg_fixture
  local bin out rc=0 bb
  bin=$(harness_mktemp_d lg-nogh)
  ln -s "$(command -v jq)" "$bin/jq"
  # The interpreter by its absolute path: PATH holds only jq.
  bb=$(command -v "$BASH_BIN")
  out=$(PATH="$bin" "$bb" "$REPO_DIR/scripts/adapters/ledger-pr-gh.sh" list 2>&1) || rc=$?
  assert_eq "2" "$rc" "no gh on PATH: exit 2"
  assert_contains "$out" "gh" "…naming gh"
  lg_fake_gh
  printf 'HTTP 401: Bad credentials\n' > "$LG_GH/fail"
  rc=0
  out=$("$BASH_BIN" "$REPO_DIR/scripts/adapters/ledger-pr-gh.sh" list 2>&1 >/dev/null) || rc=$?
  assert_eq "2" "$rc" "gh exits 1: exit 2"
  assert_contains "$out" "HTTP 401: Bad credentials" "…with gh's stderr"
  rm -f "$LG_GH/fail"
  printf 'not json\n' > "$LG_GH/prs.json"
  rc=0
  "$BASH_BIN" "$REPO_DIR/scripts/adapters/ledger-pr-gh.sh" list >/dev/null 2>&1 || rc=$?
  assert_eq "2" "$rc" "gh prints something that is not JSON: exit 2"
  lg_fake_gh_off
  rm -rf "$bin"
  teardown
}

test_lg_pr_adapter_open_limit_rc2() {
  echo "test: ledger-pr-gh.sh — as many open PRs as the limit (1000): the list may be cut — exit 2, never a silent truncation"
  lg_pr_fixture
  jq -n '[range(1000) | {number: (. + 100), headRefName: "b\(.)", state: "OPEN", url: "https://github.com/o/r/pull/\(. + 100)", mergeCommit: null}]' \
    > "$LG_GH/prs.json"
  local out rc=0
  out=$("$BASH_BIN" "$REPO_DIR/scripts/adapters/ledger-pr-gh.sh" list 2>&1 >/dev/null) || rc=$?
  assert_eq "2" "$rc" "1000 open PRs: exit 2"
  assert_contains "$out" "could not list completely: 1000 open PRs" "…saying why"
  lg ls --format json
  assert_eq "0" "$LG_RC" "ls: the R1 failure path (exit 0)"
  assert_contains "$LG_ERR" "PR data unavailable" "…one warning"
  assert_contains "$LG_ERR" "could not list completely" "…with the reason"
  jq -c '.[0:999]' "$LG_GH/prs.json" > "$LG_GH/p2" && mv "$LG_GH/p2" "$LG_GH/prs.json"
  rc=0
  "$BASH_BIN" "$REPO_DIR/scripts/adapters/ledger-pr-gh.sh" list >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "999 open PRs: exit 0"
  lg_pr_teardown
}

# The unit test of _lg_remote_cache (a producer that counts its runs).
# shellcheck disable=SC2031  # lg_in runs this body where lg_source set the _LG_*/_SCRATCH globals
lg_t_remote_cache() {
  local f f2 h now i
  lg_t_prod() {
    local n
    n=$(cat "$_SCRATCH/n" 2>/dev/null || echo 0)
    n=$((n + 1))
    echo "$n" > "$_SCRATCH/n"
    if [ -f "$_SCRATCH/fail" ]; then echo "producer down" >&2; return 1; fi
    printf '{"v":%s}\n' "$n"
  }
  _lg_remote_cache t key1 lg_t_prod
  assert_eq "0|fresh" "$?|$_LG_RSTATE" "first call: the producer runs (fresh)"
  f=$_LG_RCACHE
  assert_contains "$f" "$_LG_CACHE/remote/t-" "the file is \$_LG_CACHE/remote/<name>-<sha>.json"
  assert_json_field "$(head -n 1 "$f")" '[.schema, (.fetched_at | type)] | join(",")' "ledger-remote/1,number" "line 1 records fetched_at"
  assert_eq '{"v":1}' "$(tail -n +2 "$f")" "then the producer's lines"
  _lg_remote_cache t key1 lg_t_prod
  assert_eq "1|fresh|$f" "$(cat "$_SCRATCH/n")|$_LG_RSTATE|$_LG_RCACHE" "within the TTL: the cache, no producer run"
  _lg_remote_cache t key2 lg_t_prod
  f2=$_LG_RCACHE
  lg_assert_cond "[ \"$f\" != \"$f2\" ]" "other key material: another file"
  # Older than cache.remote_ttl_minutes (10): refreshed.
  now=$(date +%s)
  h=$(head -n 1 "$f" | jq -c --argjson t "$((now - 11 * 60))" '.fetched_at = $t')
  { printf '%s\n' "$h"; tail -n +2 "$f"; } > "$f.x" && mv "$f.x" "$f"
  _lg_remote_cache t key1 lg_t_prod
  assert_eq "3|fresh|{\"v\":3}" "$(cat "$_SCRATCH/n")|$_LG_RSTATE|$(tail -n +2 "$f")" "past the TTL: the producer runs again"
  # A fetch time in the future (clock skew): expired, refreshed (m1).
  h=$(head -n 1 "$f" | jq -c --argjson t "$((now + 3600))" '.fetched_at = $t')
  { printf '%s\n' "$h"; tail -n +2 "$f"; } > "$f.x" && mv "$f.x" "$f"
  _lg_remote_cache t key1 lg_t_prod
  assert_eq "4|fresh" "$(cat "$_SCRATCH/n")|$_LG_RSTATE" "fetched_at in the future: refreshed"
  echo 3 > "$_SCRATCH/n"
  # A huge TTL is clamped (jq prints 6e+31, which no shell test compares:
  # the TTL was ignored and every call refetched) (m2).
  jq -c '.cache.remote_ttl_minutes = 1e30' "$_LG_CFG" > "$_LG_CFG.x" && mv "$_LG_CFG.x" "$_LG_CFG"
  lg_rc _lg_remote_cache t key1 lg_t_prod
  assert_eq "0|3" "$LG_RC|$(cat "$_SCRATCH/n")" "remote_ttl_minutes 1e30: rc 0, the fresh copy serves"
  # TTL 0: every call refreshes.
  jq -c '.cache.remote_ttl_minutes = 0' "$_LG_CFG" > "$_LG_CFG.x" && mv "$_LG_CFG.x" "$_LG_CFG"
  _lg_remote_cache t key1 lg_t_prod
  assert_eq "4" "$(cat "$_SCRATCH/n")" "TTL 0: refreshed every call"
  # A failing producer: the old copy, marked stale; the failure is
  # remembered for a TTL (no retry storm), unless forced.
  jq -c '.cache.remote_ttl_minutes = 10' "$_LG_CFG" > "$_LG_CFG.x" && mv "$_LG_CFG.x" "$_LG_CFG"
  h=$(head -n 1 "$f" | jq -c --argjson t "$((now - 11 * 60))" '.fetched_at = $t')
  { printf '%s\n' "$h"; tail -n +2 "$f"; } > "$f.x" && mv "$f.x" "$f"
  : > "$_SCRATCH/fail"
  _lg_remote_cache t key1 lg_t_prod
  assert_eq "0|stale|$f|{\"v\":4}" "$?|$_LG_RSTATE|$_LG_RCACHE|$(tail -n +2 "$f")" "producer fails past the TTL: the old copy, stale"
  assert_contains "$_LG_RERR" "producer down" "…with the producer's stderr"
  lg_assert_cond "[ \"$_LG_RAGE\" -ge 660 ]" "…and its age"
  _lg_remote_cache t key1 lg_t_prod
  assert_eq "5|stale" "$(cat "$_SCRATCH/n")|$_LG_RSTATE" "a failure younger than the TTL is not retried"
  _LG_REMOTE_FORCE=1
  lg_rc _lg_remote_cache t key1 lg_t_prod
  assert_eq "2|6" "$LG_RC|$(cat "$_SCRATCH/n")" "forced (--refresh, publish): retried, and a failure is rc 2"
  _LG_REMOTE_FORCE=""
  lg_rc _lg_remote_cache t key3 lg_t_prod
  assert_eq "2" "$LG_RC" "no copy and the producer fails: rc 2"
  _lg_remote_cache t key3 lg_t_prod || true
  assert_eq "none|" "$_LG_RSTATE|$_LG_RCACHE" "…state none, no file"
  rm -f "$_SCRATCH/fail"
  # Concurrent forced refreshes (each its own process scratch, as separate
  # runs have): last writer wins, the file is whole.
  _LG_REMOTE_FORCE=1
  i=0
  while [ "$i" -lt 6 ]; do
    ( _SCRATCH=$(mktemp -d "$_SCRATCH/c.XXXXXX") && echo "$((i * 100))" > "$_SCRATCH/n" \
      && _lg_remote_cache t key1 lg_t_prod ) >/dev/null 2>&1 &
    i=$((i + 1))
  done
  wait
  _LG_REMOTE_FORCE=""
  h=$(head -n 1 "$f")
  assert_json_field "$h" '.schema' "ledger-remote/1" "after concurrent refreshes: a whole header"
  tail -n +2 "$f" > "$_SCRATCH/data"
  _hash_one "$_SCRATCH/data"
  assert_json_field "$h" '.data_sha256' "${_HASH#sha256:}" "…whose data hash is the data's"
  assert_eq "0" "$(find "$_LG_CACHE/remote" -name '.t*' | wc -l | tr -d ' ')" "…and no temp file left"
  # A dead writer's temp file older than 10 minutes is swept on the next
  # write; a young one (a live writer) is not (m4).
  : > "$_LG_CACHE/remote/.t.old123"
  touch -t 202001010000 "$_LG_CACHE/remote/.t.old123"
  : > "$_LG_CACHE/remote/.t.new123"
  _LG_REMOTE_FORCE=1
  _lg_remote_cache t key1 lg_t_prod
  _LG_REMOTE_FORCE=""
  assert_file_not_exists "$_LG_CACHE/remote/.t.old123" "an old temp file is swept"
  assert_file_exists "$_LG_CACHE/remote/.t.new123" "a young one stays"
  rm -f "$_LG_CACHE/remote/.t.new123"
}

test_lg_remote_cache_ttl() {
  echo "test: the remote cache — TTL cache.remote_ttl_minutes, fetch time recorded, stale copy on failure, atomic writes"
  lg_fixture
  lg_enable
  lg_in lg_t_remote_cache
  teardown
  echo "test: the PR list goes through it — gh runs once per TTL"
  lg_pr_fixture
  lg ls
  assert_eq "0|1" "$LG_RC|$(lg_gh_calls)" "first ls: gh runs"
  assert_eq "1" "$(lg_remote_file pr | wc -l | tr -d ' ')" "one cache file under remote/"
  lg show x-1
  lg ls --open
  lg view all --out "$TEST_DIR/v"
  assert_eq "1" "$(lg_gh_calls)" "show, ls, view within the TTL: no gh call"
  lg_enable '{"adapters":{"pr":"doc-superpowers:ledger-pr-gh"},"trailers":{"claims_by_path":["Ledger-Claims-Path"]},"cache":{"remote_ttl_minutes":0}}'
  lg ls
  lg ls
  assert_eq "3" "$(lg_gh_calls)" "TTL 0: every run"
  lg_pr_teardown
}

test_lg_remote_cache_refresh_flag() {
  echo "test: --refresh (show, ls, view) and publish fetch the PR list now; a failure is exit 2 there"
  lg_pr_fixture
  lg ls
  assert_eq "1" "$(lg_gh_calls)" "first run"
  lg ls --refresh
  assert_eq "0|2" "$LG_RC|$(lg_gh_calls)" "ls --refresh within the TTL: gh runs"
  lg show x-1 --refresh
  assert_eq "0|3" "$LG_RC|$(lg_gh_calls)" "show --refresh"
  lg view x --refresh --out "$TEST_DIR/v"
  assert_eq "0|4" "$LG_RC|$(lg_gh_calls)" "view --refresh"
  printf 'gh: network down\n' > "$LG_GH/fail"
  lg ls --refresh
  assert_eq "2" "$LG_RC" "ls --refresh with gh failing: exit 2"
  assert_contains "$LG_ERR" "network down" "…with gh's stderr"
  lg ls --refresh --format json
  assert_eq "1|2" "$(json_count "$LG_OUT")|$(jq -r .exit <<<"$LG_OUT")" "…one JSON object, exit 2"
  lg view all --refresh --out "$TEST_DIR/v"
  assert_eq "2" "$LG_RC" "view --refresh: exit 2"
  lg publish --dry-run
  assert_eq "2" "$LG_RC" "publish needs fresh PR data: exit 2"
  assert_contains "$LG_ERR" "network down" "…saying why"
  lg ls
  assert_eq "0" "$LG_RC" "plain ls within the TTL: the cache (exit 0)"
  lg find claimed
  assert_eq "0" "$LG_RC" "find: exit 0"
  lg ls --bogus
  assert_eq "3" "$LG_RC" "an undeclared option is still usage (3)"
  lg_pr_teardown
}

test_lg_status_in_review() {
  echo "test: in review #<n> — an open PR whose head (refs/remotes/<remote>/<head>) claims the item: trailer or edit"
  lg_pr_fixture
  lg ls --format json
  assert_eq "0" "$LG_RC" "ls: exit 0"
  assert_eq "in review #12" "$(lg_pr_status x-1)" "x-1: Ledger-Claims on PR #12's head (a unicode branch name)"
  assert_eq "in review #12" "$(lg_pr_status x-2)" "x-2: its file edited on PR #12's head"
  assert_eq "in review #15" "$(lg_pr_status y-3)" "y-3: a dash-led head segment"
  assert_eq "merged · owed: closing" "$(lg_pr_status x-3)" "x-3: claimed on the base too — merged comes first"
  assert_eq "shipped" "$(lg_pr_status x-6)" "x-6: fixed — the class comes first"
  assert_eq "not started" "$(lg_pr_status y-2)" "y-2: claimed by a closed PR only"
  assert_eq "not started" "$(lg_pr_status y-1)" "y-1: its PR's head has no local ref"
  assert_contains "$LG_ERR" "1 open PR head not fetched (#13" "the unfetched head is counted on stderr"
  assert_contains "$LG_ERR" "1 cross-repository open PR not compared (#16)" "the fork PR too"
  assert_eq "1" "$(printf '%s\n' "$LG_ERR" | grep -c .)" "…in one line"
  assert_eq "12" "$(jq -r '.items[] | select(.key == "x-1") | .derived.detail' <<<"$LG_OUT")" \
    "x-1: #12, never the fork #16 through origin's same-named branch (C2)"
  lg show x-1 --format json
  assert_json_field "$LG_OUT" '.item.pr | [.number, .state, .url] | join(",")' "12,open,https://github.com/o/r/pull/12" "show: .pr"
  assert_json_field "$LG_OUT" '.item.derived | [.status, .detail] | join(",")' "in review,12" "…derived {in review, 12}"
  lg show x-1
  assert_contains "$(lg_line "$LG_OUT" "x-1")" "in review #12" "show text: the status"
  lg ls --status "in review"
  assert_eq "x-1 x-2 y-3" "$(printf '%s\n' "$LG_OUT" | awk '{ print $1 }' | sort | tr '\n' ' ' | sed 's/ $//')" "ls --status 'in review'"
  lg view x --out "$TEST_DIR/v"
  assert_contains "$(lg_line "$(cat "$TEST_DIR/v/x.md")" "| x-1 ")" "| [#12](https://github.com/o/r/pull/12) |" "the page's PR column"
  # The index follows the heads: a new commit on PR #15's head (pushed
  # from another clone) is a hit until fetched, then a rebuild.
  DOC_TOOLS_LEDGER_TRACE=1 lg ls
  assert_contains "$LG_ERR" "index-hit" "nothing moved: an index hit"
  local other
  other="$(harness_mktemp_d lg-other)/clone"
  lg_clone "$other"
  ( cd "$other" && git checkout -q -b tmp15 "origin/feat/-dash" \
    && git commit -q --allow-empty -m "more on the PR" -m "Ledger-Claims: y-2" && git push -q origin "HEAD:feat/-dash" )
  rm -rf "$(dirname "$other")"
  DOC_TOOLS_LEDGER_TRACE=1 lg ls --format json
  assert_contains "$LG_ERR" "index-hit" "pushed but not fetched: still a hit (index builds never fetch)"
  git fetch -q origin
  DOC_TOOLS_LEDGER_TRACE=1 lg ls --format json
  assert_contains "$LG_ERR" "index-build" "the head moved (fetched): rebuilt"
  assert_eq "in review #15" "$(lg_pr_status y-3)" "y-3 still in review"
  assert_eq "in review #15" "$(lg_pr_status y-2)" "y-2: claimed by the new commit on PR #15's head"
  # The PR list changes (#15 closed): rebuilt, y-3 no longer in review.
  sed 's/"number":15,"headRefName":"feat\/-dash","state":"OPEN"/"number":15,"headRefName":"feat\/-dash","state":"CLOSED"/' "$LG_GH/prs.json" > "$LG_GH/p2" && mv "$LG_GH/p2" "$LG_GH/prs.json"
  DOC_TOOLS_LEDGER_TRACE=1 lg ls --refresh --format json
  assert_contains "$LG_ERR" "index-build" "new PR data: rebuilt"
  assert_eq "not started" "$(lg_pr_status y-3)" "y-3: its PR closed"
  lg_pr_teardown
}

test_lg_status_merged_open_item() {
  echo "test: merged · owed: <owed> — an open item claimed on the base (claims, claims-by-path) or by a merged PR"
  lg_pr_fixture
  lg ls --format json
  assert_eq "merged · owed: closing" "$(lg_pr_status x-3)" "x-3: Ledger-Claims on the base"
  assert_eq "merged · owed: closing" "$(lg_pr_status x-4)" "x-4: Ledger-Claims-Path on the base (config claims_by_path)"
  assert_eq "not started" "$(lg_pr_status x-5)" "x-5: merged PR #9 only changed its file — not merged (C3)"
  assert_eq "merged · owed: closing" "$(lg_pr_status x-8)" "x-8: a Ledger-Claims trailer on merged PR #10's head"
  assert_eq "not started" "$(lg_pr_status y-5)" "y-5: merged PR #10 only edited its file — not merged"
  assert_eq "merged · owed: docs" "$(lg_pr_status x-7)" "x-7: claimed in a bullet; its owed field is what is owed"
  lg show x-8 --format json
  assert_json_field "$LG_OUT" '.item.pr | [.number, .state] | join(",")' "10,merged" "x-8: .pr is the merged PR"
  assert_json_field "$LG_OUT" '.item.derived | [.status, .detail] | join(",")' "merged,closing" "…derived {merged, closing}"
  lg ls --status merged
  assert_eq "x-3 x-4 x-7 x-8" "$(printf '%s\n' "$LG_OUT" | awk '{ print $1 }' | sort | tr '\n' ' ' | sed 's/ $//')" "ls --status merged"
  # Closing the item: shipped, whatever claimed it.
  lg_item docs/issues/c.md "key: x-3" "ledger: x" "status: Fixed" "severity: P2" "summary: Claimed on the base"
  printf '\n## Resolution\n\nDone.\n' >> docs/issues/c.md
  lg ls --format json
  assert_eq "shipped" "$(lg_pr_status x-3)" "x-3 fixed: shipped"
  git checkout -q -- docs/issues/c.md
  # Without the PR adapter: the base claims still count; the merged PR's does not.
  lg_enable '{"trailers":{"claims_by_path":["Ledger-Claims-Path"]}}'
  lg ls --format json
  assert_eq "0" "$LG_RC" "no adapters.pr: exit 0"
  assert_eq "" "$LG_ERR" "…no warning"
  assert_eq "merged · owed: closing" "$(lg_pr_status x-4)" "x-4: base claim"
  assert_eq "not started" "$(lg_pr_status x-8)" "x-8: only a PR said so"
  assert_json_field "$LG_OUT" '.pr_data | [.state, (.as_of | tostring), (.error | tostring)] | join(",")' "unconfigured,null,null" \
    "pr_data: unconfigured (I3)"
  assert_eq "not started" "$(lg_pr_status x-1)" "x-1: no PR data, no review"
  assert_eq "1" "$(lg_gh_calls)" "gh was not called without the adapter (the one call: the first ls)"
  # The default trailers: Ledger-Claims-Path is not one.
  lg_enable '{}'
  lg ls --format json
  assert_eq "not started" "$(lg_pr_status x-4)" "x-4: no claims_by_path trailer configured"
  assert_eq "merged · owed: closing" "$(lg_pr_status x-3)" "x-3: Ledger-Claims (a default)"
  lg_pr_teardown
}

test_lg_view_stale_pr_marker() {
  echo "test: the PR adapter fails — a cached copy: stale marker (views) / stderr note (ls, show); none: '—' and one warning; read verbs exit 0"
  lg_pr_fixture
  lg view all --out "$TEST_DIR/v"
  assert_eq "0" "$LG_RC" "fresh: exit 0"
  assert_not_contains "$(sed -n 3p "$TEST_DIR/v/x.md")" "PR data" "fresh: no marker"
  lg ls --format json
  assert_json_field "$LG_OUT" '.pr_data | [.state, (.as_of | type), (.error | tostring)] | join(",")' "fresh,number,null" "pr_data: fresh (I3)"
  lg view x --out "$TEST_DIR/v" --format json
  assert_json_field "$LG_OUT" '.pr_data.state' "fresh" "view JSON: pr_data"
  # Older than the TTL, and gh fails.
  local f h
  f=$(lg_remote_file pr) || f=""
  assert_eq "1" "$(printf '%s' "$f" | grep -c .)" "one PR cache file"
  if [ -n "$f" ]; then
    h=$(head -n 1 "$f" | jq -c '.fetched_at -= 3 * 3600')
    { printf '%s\n' "$h"; tail -n +2 "$f"; } > "$f.x" && mv "$f.x" "$f"
  fi
  printf 'gh: could not connect\n' > "$LG_GH/fail"
  lg view all --html --md --out "$TEST_DIR/v"
  assert_eq "0" "$LG_RC" "stale: exit 0"
  assert_contains "$(sed -n 3p "$TEST_DIR/v/x.md")" "PR data as of " "the page header: PR data as of …"
  assert_contains "$(sed -n 3p "$TEST_DIR/v/x.md")" "(3 h old)" "…its age"
  assert_contains "$(sed -n 3p "$TEST_DIR/v/README.md")" "PR data as of " "…README too"
  assert_contains "$(cat "$TEST_DIR/v/ledger.html")" "PR data as of " "…and the HTML"
  assert_contains "$(lg_line "$(cat "$TEST_DIR/v/x.md")" "| x-1 ")" "in review #12" "the cached data still serves"
  lg ls
  assert_eq "0" "$LG_RC" "ls: exit 0"
  assert_contains "$LG_ERR" "PR data as of " "ls: a stderr note"
  assert_contains "$LG_ERR" "could not connect" "…with the reason"
  lg show x-1
  assert_eq "0" "$LG_RC" "show: exit 0"
  assert_contains "$LG_ERR" "PR data as of " "show: the note"
  lg show x-1 --format json
  assert_json_field "$LG_OUT" '.pr_data | [.state, (.as_of | type), (.error | test("could not connect") | tostring)] | join(",")' \
    "stale,number,true" "pr_data: stale, its age, the error"
  # No cached copy at all.
  rm -rf "$(git rev-parse --git-common-dir)/doc-superpowers/ledger/remote"
  lg view all --html --md --out "$TEST_DIR/v"
  assert_eq "0" "$LG_RC" "no copy: view exits 0"
  assert_contains "$(sed -n 3p "$TEST_DIR/v/x.md")" "PR data: —" "…the header shows PR data: —"
  assert_contains "$(cat "$TEST_DIR/v/ledger.html")" "PR data: —" "…the HTML too"
  assert_eq "| — |" "$(lg_line "$(cat "$TEST_DIR/v/x.md")" "| x-1 " | awk -F' [|] ' '{ print "| " $7 " |" }')" "…the PR column '—'"
  assert_contains "$(lg_line "$(cat "$TEST_DIR/v/x.md")" "| x-1 ")" "not started" "…no review state from nowhere"
  lg ls --format json
  assert_eq "0" "$LG_RC" "ls: exit 0"
  assert_eq "1" "$(printf '%s\n' "$LG_ERR" | grep -c .)" "one stderr warning"
  assert_contains "$LG_ERR" "PR data unavailable" "…saying the PR data is unavailable"
  assert_eq "merged · owed: closing" "$(lg_pr_status x-3)" "base claims still count"
  assert_eq "not started" "$(lg_pr_status x-8)" "the merged PR's claim is gone (—)"
  assert_json_field "$LG_OUT" '.pr_data | [.state, (.as_of | tostring), (.error | test("could not connect") | tostring)] | join(",")' \
    "none,null,true" "pr_data: none"
  lg show x-1
  assert_eq "0" "$LG_RC" "show: exit 0"
  lg find claimed
  assert_eq "0" "$LG_RC" "find: exit 0"
  assert_contains "$LG_ERR" "PR data unavailable" "find: the warning"
  lg ls --refresh
  assert_eq "2" "$LG_RC" "--refresh: exit 2"
  lg_pr_teardown
}

test_lg_remote_offline() {
  echo "test: DOC_TOOLS_LEDGER_OFFLINE=1 — the producer never runs; a copy past the TTL serves (offline), none: '—'; --refresh / publish exit 2"
  lg_pr_fixture
  lg ls
  assert_eq "1" "$(lg_gh_calls)" "online: one fetch"
  local f h
  f=$(lg_remote_file pr) || f=""
  h=$(head -n 1 "$f" | jq -c '.fetched_at -= 2 * 3600')
  { printf '%s\n' "$h"; tail -n +2 "$f"; } > "$f.x" && mv "$f.x" "$f"
  DOC_TOOLS_LEDGER_OFFLINE=1 lg ls --format json
  assert_eq "0|1" "$LG_RC|$(lg_gh_calls)" "past the TTL, offline: exit 0, no gh call"
  assert_contains "$LG_ERR" "PR data as of " "the stderr note"
  assert_contains "$LG_ERR" "offline" "…says offline"
  assert_not_contains "$LG_ERR" "failed" "…not that the adapter failed"
  assert_json_field "$LG_OUT" '.pr_data | [.state, (.as_of | type), (.error | tostring)] | join(",")' "offline,number,null" "pr_data: offline, as_of, no error"
  assert_eq "in review #12" "$(lg_pr_status x-1)" "the copy serves"
  assert_file_not_exists "$f.fail" "no failure recorded"
  DOC_TOOLS_LEDGER_OFFLINE=1 lg view x --out "$TEST_DIR/v"
  assert_contains "$(sed -n 3p "$TEST_DIR/v/x.md")" "PR data as of " "view: the header marker"
  DOC_TOOLS_LEDGER_OFFLINE=1 lg ls --refresh
  assert_eq "2" "$LG_RC" "--refresh offline: exit 2"
  assert_contains "$LG_ERR" "offline: DOC_TOOLS_LEDGER_OFFLINE=1" "…saying so"
  DOC_TOOLS_LEDGER_OFFLINE=1 lg publish --dry-run
  assert_eq "2" "$LG_RC" "publish offline: exit 2"
  assert_contains "$LG_ERR" "offline: DOC_TOOLS_LEDGER_OFFLINE=1" "…saying so"
  rm -rf "$(git rev-parse --git-common-dir)/doc-superpowers/ledger/remote"
  DOC_TOOLS_LEDGER_OFFLINE=1 lg ls --format json
  assert_eq "0" "$LG_RC" "no copy, offline: exit 0"
  assert_eq "1" "$(printf '%s\n' "$LG_ERR" | grep -c .)" "…one warning"
  assert_contains "$LG_ERR" "PR data unavailable" "…the R1 '—' path"
  assert_json_field "$LG_OUT" '.pr_data | [.state, (.as_of | tostring)] | join(",")' "offline,null" "pr_data: offline, no as_of"
  assert_eq "1" "$(lg_gh_calls)" "gh never ran offline"
  lg_pr_teardown
}

# lg_remote_v2 <cache-file> <out>: a copy of the cache file as a newer
# fetch would write it — PR #15 closed, PR #17 opened on closed-branch (it
# claims y-2) — its header's data hash recomputed.
lg_remote_v2() {
  local d h
  d=$(harness_mktemp lg-v2)
  { tail -n +2 "$1" | jq -c 'if .number == 15 then .state = "closed" else . end'
    echo '{"number":17,"head":"closed-branch","state":"open","url":"https://github.com/o/r/pull/17","merge_commit":null,"cross":false}'; } > "$d"
  h=$(head -n 1 "$1" | jq -c --arg s "$(shasum -a 256 < "$d" | cut -d ' ' -f 1)" '.data_sha256 = $s')
  { printf '%s\n' "$h"; cat "$d"; } > "$2"
  rm -f "$d"
}

test_lg_remote_cache_race_snapshot() {
  echo "test: a reader racing a writer reads one snapshot — no parsed sidecar named for data it did not parse (I2)"
  lg_pr_fixture
  lg ls --format json
  assert_eq "in review #15" "$(lg_pr_status y-3)" "v1: y-3 in review #15"
  local f v2 c
  f=$(lg_remote_file pr) || f=""
  rm -f "${f%.json}"-*.ol
  v2="$TEST_DIR/v2.json"
  lg_remote_v2 "$f" "$v2"
  # A writer replaces the file while this run reads it (selftest hook).
  DOC_TOOLS_LEDGER_SELFTEST=remote-swap DOC_TOOLS_LEDGER_SELFTEST_SWAP="$v2" lg ls --format json
  assert_eq "0" "$LG_RC" "the racing run: exit 0"
  assert_eq "in review #15" "$(lg_pr_status y-3)" "…consistent: the data it read (v1)"
  lg ls --format json
  assert_eq "0" "$LG_RC" "the next run: exit 0"
  assert_eq "not started" "$(lg_pr_status y-3)" "the next run reads v2: #15 closed"
  assert_eq "in review #17" "$(lg_pr_status y-2)" "…and #17's head walked (no sidecar parsed from v1 under v2's name)"
  # A sidecar that cannot be read is a miss, not a failure.
  for c in "${f%.json}"-*.ol; do [ -f "$c" ] && chmod 000 "$c"; done
  lg_enable "$(jq -c '.views.recent_days = 13' docs/ledger/config.json)"
  lg ls
  assert_eq "0" "$LG_RC" "an unreadable sidecar: re-parsed, exit 0"
  for c in "${f%.json}"-*.ol; do [ -f "$c" ] && chmod 644 "$c"; done
  # An ancestor's base-claims file that cannot be read: a cold walk.
  c=$(ls "$(git rev-parse --git-common-dir)"/doc-superpowers/ledger/claims-*.tsv | head -n 1)
  chmod 000 "$c"
  git commit -q --allow-empty -m "later" && git push -q origin main && git fetch -q origin
  lg ls
  assert_eq "0" "$LG_RC" "an unreadable ancestor claims file: a cold walk, exit 0"
  chmod 644 "$c"
  lg_pr_teardown
}

test_lg_pr_numbers_sorted_numerically() {
  echo "test: PR numbers order numerically, whatever type an adapter gives them (m3)"
  lg_pr_fixture '{"adapters":{"pr":"tools/pr.sh"}}'
  mkdir -p tools
  cat > tools/pr.sh <<'EOF'
#!/bin/sh
echo '{"number":"9","head":"feat/-dash","state":"open","url":"https://example.test/9"}'
echo '{"number":"12","head":"feat/ünï-x","state":"open","url":"https://example.test/12"}'
EOF
  chmod +x tools/pr.sh
  git checkout -q -b more "origin/feat/ünï-x"
  git commit -q --allow-empty -m "also" -m "Ledger-Claims: y-3"
  git push -q origin "HEAD:feat/ünï-x"
  git checkout -q main
  git fetch -q origin
  lg ls --format json
  assert_eq "in review #12" "$(lg_pr_status y-3)" "claimed by \"9\" and \"12\": #12, the higher number"
  lg_pr_teardown
}

test_lg_merged_pr_pinned_to_head_oid() {
  echo "test: a merged PR is walked from its merged head (headRefOid), never from its branch — later commits on a reused branch are not its claims (R2-1)"
  lg_pr_fixture
  lg ls --format json
  assert_eq "merged · owed: closing" "$(lg_pr_status x-8)" "x-8: claimed at #10's merged head"
  # The branch "squashed" is reused after the merge: a new commit claims
  # y-2 (pushed from another clone, fetched here).
  local other
  other="$(harness_mktemp_d lg-other)/clone"
  lg_clone "$other"
  ( cd "$other" && git checkout -q -b reuse origin/squashed \
    && git commit -q --allow-empty -m "after the merge" -m "Ledger-Claims: y-2" && git push -q origin "HEAD:squashed" )
  rm -rf "$(dirname "$other")"
  git fetch -q origin
  lg ls --refresh --format json
  assert_eq "not started" "$(lg_pr_status y-2)" "y-2: claimed after #10 merged — not merged"
  assert_eq "merged · owed: closing" "$(lg_pr_status x-8)" "x-8 still merged (its merged head)"
  # An open PR on the reused branch: in review.
  jq -c '. + [{"number":18,"headRefName":"squashed","headRefOid":"0","state":"OPEN","url":"https://github.com/o/r/pull/18","mergeCommit":null}]' \
    "$LG_GH/prs.json" > "$LG_GH/p2" && mv "$LG_GH/p2" "$LG_GH/prs.json"
  lg ls --refresh --format json
  assert_eq "in review #18" "$(lg_pr_status y-2)" "y-2: in review #18 (the open PR on the reused branch)"
  # Without head_oid (a third-party adapter), a merged PR adds nothing
  # beyond the base walk.
  jq -c 'map(select(.number != 18) | del(.headRefOid))' "$LG_GH/prs.json" > "$LG_GH/p2" && mv "$LG_GH/p2" "$LG_GH/prs.json"
  lg ls --refresh --format json
  assert_eq "not started" "$(lg_pr_status x-8)" "no head_oid: x-8 is not merged through #10"
  # A head_oid this clone does not have: nothing, no failure.
  jq -c 'map(if .number == 10 then .headRefOid = "abababababababababababababababababababab" else . end)' "$LG_GH/prs.json" > "$LG_GH/p2" \
    && mv "$LG_GH/p2" "$LG_GH/prs.json"
  lg ls --refresh --format json
  assert_eq "0|not started" "$LG_RC|$(lg_pr_status x-8)" "an unknown head_oid: exit 0, nothing"
  lg_pr_teardown
}

# lg_claims_prune_check <hook>: a base that moved (one commit, fetched),
# then ls under DOC_TOOLS_LEDGER_SELFTEST=<hook> and the trace: exit 0, a
# cold walk of the claims, and stderr holds no stray line — exactly one
# "ledger:" line (the fixture's unfetched head) besides the trace.
lg_claims_prune_check() {
  git commit -q --allow-empty -m "base moves ($1)" && git push -q origin main && git fetch -q origin
  DOC_TOOLS_LEDGER_SELFTEST=$1 DOC_TOOLS_LEDGER_TRACE=1 lg ls
  assert_eq "0" "$LG_RC" "$1: exit 0"
  assert_contains "$LG_ERR" "claims-cold" "$1: a cold walk of the base's claims"
  assert_eq "1" "$(printf '%s\n' "$LG_ERR" | grep -c '^ledger:')" "$1: one ledger: line"
  assert_eq "" "$(printf '%s\n' "$LG_ERR" | grep -v -E '^(ledger: |index-|dates-|claims-)')" "$1: no stray stderr"
}

test_lg_base_claims_prune_race() {
  echo "test: a cached base-claims file pruned mid-run is a cold walk — exit 0, no stray stderr (R2-2, R2-3)"
  lg_pr_fixture
  lg ls
  lg_claims_prune_check claims-prune
  lg_claims_prune_check claims-prune-early
  lg_pr_teardown
}

# --- Task 10 review carry-over (Task 11) ---------------------------------------------

# lg_no_stray <label>: LG_ERR holds only ledger notes and trace lines.
lg_no_stray() {
  assert_eq "" "$(printf '%s\n' "$LG_ERR" | grep -v -E '^(ledger: |index-|dates-|claims-|parse-|inflight-)')" "$1: no stray stderr"
}

test_lg_check_then_read_silent() {
  echo "test: a file that vanishes between its check and its read is a miss, silently — the current base's claims, the remote cache's .fail record"
  lg_pr_fixture
  lg ls
  # An item edit rebuilds the index at the same base: the base's claims
  # file is a hit candidate, and it vanishes after the check.
  printf '\nmore\n' >> docs/issues/a.md
  DOC_TOOLS_LEDGER_SELFTEST=claims-vanish-current DOC_TOOLS_LEDGER_TRACE=1 lg ls
  assert_eq "0" "$LG_RC" "claims file vanished: exit 0"
  assert_contains "$LG_ERR" "claims-cold" "…a cold walk"
  lg_no_stray "claims file vanished"
  lg_pr_teardown
  # A failure record (TTL 0: every run reads it) that vanishes after the check.
  lg_pr_fixture '{"adapters":{"pr":"doc-superpowers:ledger-pr-gh"},"cache":{"remote_ttl_minutes":0}}'
  lg ls
  echo "gh: boom" > "$LG_GH/fail"
  lg ls
  assert_contains "$LG_ERR" "the pr adapter failed" "the failure is recorded"
  rm -f "$LG_GH/fail"
  DOC_TOOLS_LEDGER_SELFTEST=remote-fail-vanish lg ls
  assert_eq "0" "$LG_RC" ".fail vanished: exit 0"
  lg_no_stray ".fail vanished"
  lg_pr_teardown
}

test_lg_pr_matches_shown_status() {
  echo "test: .pr names the PR behind the status shown — merged · owed names the merged PR, not a later open PR on the same branch"
  lg_pr_fixture
  local other
  other="$(harness_mktemp_d lg-other)/clone"
  lg_clone "$other"
  ( cd "$other" && git checkout -q -b reuse origin/squashed \
    && git commit -q --allow-empty -m "after the merge" -m "Ledger-Claims: y-2" && git push -q origin "HEAD:squashed" )
  rm -rf "$(dirname "$other")"
  git fetch -q origin
  jq -c '. + [{"number":18,"headRefName":"squashed","headRefOid":"0","state":"OPEN","url":"https://github.com/o/r/pull/18","mergeCommit":null}]' \
    "$LG_GH/prs.json" > "$LG_GH/p2" && mv "$LG_GH/p2" "$LG_GH/prs.json"
  lg show x-8 --format json
  assert_json_field "$LG_OUT" '.item.derived.status' "merged" "x-8: merged (#10's merged head claims it; open #18's head reaches the same commit)"
  assert_json_field "$LG_OUT" '.item.pr | "\(.number) \(.state)"' "10 merged" "x-8: .pr is #10, the merged PR the status shows"
  lg show y-2 --format json
  assert_json_field "$LG_OUT" '.item.derived | "\(.status) \(.detail)"' "in review 18" "y-2: in review #18"
  assert_json_field "$LG_OUT" '.item.pr | "\(.number) \(.state)"' "18 open" "y-2: .pr is #18"
  lg_pr_teardown
}

# --- Task 11: in-flight scan, branch facts, inflight --------------------------------

LG_IFL_CFG='{"base":"origin/main","inflight":{"enabled":true,"host_id":"hosta"}}'

# lg_ifl_fixture [config]: the in-flight corpus — a bare remote (LG_REMOTE),
# this clone ("hosta": inflight.host_id), base origin/main, the relations
# registry (contracts field:order.total in src/order/*.js, endpoint:create
# in server/create.js, component:Sheet in src/sheet/**). Open items: app-1
# a.md, app-2 b.md, app-3 c.md, core-1 d.md, core-2 e.md, app-4 f.md, app-5
# g.md; a plan docs/plans/p.md (doc-index doc_type plan) naming none.
# In flight:
#   feat-a    local: "Ledger-Claims: app-1", then an edit of b.md (app-2);
#             its own in-flight copy refs/doc-superpowers/inflight/hosta/
#             feat-a on the remote, one commit behind (LG_A_TIP: the tip)
#   feat-wt   the worktree "wt 1" (LG_WT1): the plan names core-2, and
#             "Contract-Change: endpoint:create — adds a field"
#   detached  the worktree "wt 2" (LG_WT2) at an unmerged commit claiming
#             app-4
#   r-only    pushed from another clone (LG_B), fetched: a remote branch
#             without a PR, claiming app-3
#   feat-a    of host "hostb" (LG_B; its in-flight ref only), claiming core-1
#   doc-ledger-views  local and remote, claiming app-5 — the views branch
lg_ifl_fixture() {
  local c="$LG_IFL_CFG"
  if [ $# -gt 0 ]; then c=$1; fi
  lg_fixture
  lg_enable "$c"
  lg_registry "$LG_REG_REL"
  lg_item docs/issues/a.md "key: app-1" "ledger: app" "status: Open" "severity: P1" "summary: Claimed on feat-a"
  lg_item docs/issues/b.md "key: app-2" "ledger: app" "status: Open" "severity: P2" "summary: Edited on feat-a"
  lg_item docs/issues/c.md "key: app-3" "ledger: app" "status: Open" "severity: P2" "summary: Claimed on a remote-only branch"
  lg_item docs/issues/d.md "key: core-1" "ledger: core" "status: Open" "severity: P1" "summary: Claimed on another host"
  lg_item docs/issues/e.md "key: core-2" "ledger: core" "status: Open" "severity: P2" "summary: Named by a plan on a worktree branch"
  lg_item docs/issues/f.md "key: app-4" "ledger: app" "status: Open" "severity: P3" "summary: Claimed on a detached worktree"
  lg_item docs/issues/g.md "key: app-5" "ledger: app" "status: Open" "severity: P3" "summary: Claimed by nothing in flight"
  mkdir -p docs/plans src/order server
  printf '# Plan\n\nNothing yet.\n' > docs/plans/p.md
  lg_doc_index '{"docs":{"docs/plans/p.md":{"doc_type":"plan"}}}'
  echo total > src/order/total.js
  echo create > server/create.js
  git add -A && git commit -qm items
  LG_REMOTE=$(harness_mktemp_d remote).git
  git init -q --bare "$LG_REMOTE"
  git --git-dir="$LG_REMOTE" symbolic-ref HEAD refs/heads/main
  git remote add origin "$LG_REMOTE"
  git push -q origin main
  git fetch -q origin
  git checkout -q -b feat-a
  git commit -q --allow-empty -m "start a" -m "Ledger-Claims: app-1"
  git push -q origin "HEAD:refs/doc-superpowers/inflight/hosta/feat-a"
  printf '\nedited on feat-a\n' >> docs/issues/b.md
  git add -A && git commit -qm "touch app-2"
  LG_A_TIP=$(git rev-parse HEAD)
  git checkout -q main
  LG_WT=$(harness_mktemp_d lg-wt)
  LG_WT1="$LG_WT/wt 1"
  LG_WT2="$LG_WT/wt 2"
  git worktree add -q -b feat-wt "$LG_WT1" main
  ( cd "$LG_WT1" && printf '# Plan\n\nCovers core-2.\n' > docs/plans/p.md && git add -A \
    && git commit -q -m "plan core-2" -m "Contract-Change: endpoint:create — adds a field" )
  git worktree add -q --detach "$LG_WT2" main
  ( cd "$LG_WT2" && git commit -q --allow-empty -m "detached work" -m "Ledger-Claims: app-4" )
  git checkout -q -b doc-ledger-views
  git commit -q --allow-empty -m "views" -m "Ledger-Claims: app-5"
  git push -q origin doc-ledger-views
  git checkout -q main
  LG_B="$(harness_mktemp_d lg-b)/clone"
  lg_clone "$LG_B"
  ( cd "$LG_B" && git checkout -q -b r-only && git commit -q --allow-empty -m "remote only" -m "Ledger-Claims: app-3" \
    && git push -q origin r-only \
    && git checkout -q -b feat-a origin/main && git commit -q --allow-empty -m "b's own feat-a" -m "Ledger-Claims: core-1" \
    && git push -q origin "HEAD:refs/doc-superpowers/inflight/hostb/feat-a" )
  git fetch -q origin
}

lg_ifl_teardown() {
  rm -rf "$LG_WT" "$(dirname "$LG_B")"
  teardown
}

# lg_sha8 <text>: the first 8 hex digits of sha256(<text>).
lg_sha8() {
  local h
  if command -v sha256sum >/dev/null 2>&1; then h=$(printf '%s' "$1" | sha256sum); else h=$(printf '%s' "$1" | shasum -a 256); fi
  printf '%s' "${h:0:8}"
}

# lg_ifl_detached <worktree-dir>: the in-flight name of a detached worktree
# — "(detached:<sha8 of its path, as git lists it>)".
lg_ifl_detached() {
  local p
  p=$(git worktree list --porcelain | sed -n 's/^worktree //p' | awk -v s="/$(basename "$1")" 'substr($0, length($0) - length(s) + 1) == s { print; exit }')
  printf '(detached:%s)' "$(lg_sha8 "$p")"
}

# lg_ifl_status <key>: the item's display status from `ls --format json` in LG_OUT.
lg_ifl_status() {
  jq -r --arg k "$1" '.items[] | select(.key == $k) | .display' <<<"$LG_OUT"
}

test_lg_inflight_sources() {
  echo "test: ledger inflight — local branches, worktrees, remote branches without a PR and other hosts' in-flight refs, one line each"
  lg_ifl_fixture
  local d
  d=$(lg_ifl_detached "$LG_WT2")
  lg inflight
  assert_eq "0" "$LG_RC" "exit 0"
  assert_eq "$d worktree no PR claims:app-4 contracts:— files:0
feat-a local,inflight no PR claims:app-1,app-2 contracts:— files:1
feat-a inflight@hostb no PR claims:core-1 contracts:— files:0
feat-wt local,worktree no PR claims:core-2 contracts:endpoint:create files:1
r-only remote no PR claims:app-3 contracts:— files:0" "$LG_OUT" \
    "detached worktree, local (+ own in-flight copy), other host, worktree branch, remote-only branch — by name, then host"
  lg inflight --format json
  assert_json_field "$LG_OUT" '[.verb, .exit, .host_id] | join(",")' "ledger inflight,0,hosta" "json: verb, exit, host_id"
  assert_json_field "$LG_OUT" '[.branches[] | .branch] | join(",")' "$d,feat-a,feat-a@hostb,feat-wt,r-only" "json: the branches"
  assert_json_field "$LG_OUT" '.branches[] | select(.branch == "feat-a") | [.oid, (.sources | join(",")), .own] | join(" ")' \
    "$LG_A_TIP local,inflight true" "feat-a: own copies merged, the newest oid (the local tip)"
  assert_json_field "$LG_OUT" '.branches[] | select(.branch == "feat-a@hostb") | [.host, .name, .own] | join(" ")' \
    "hostb feat-a false" "feat-a@hostb: another host's"
  assert_json_field "$LG_OUT" '.branches[] | select(.branch == "feat-a") | .files | join(",")' "docs/issues/b.md" "json: the files"
  assert_json_field "$LG_OUT" '.branches[] | select(.branch == "r-only") | .merge_base' "$(git rev-parse origin/main)" "json: the merge base"
  assert_json_field "$LG_OUT" '.pr_data.state' "unconfigured" "json: pr_data (R5)"
  assert_json_field "$LG_OUT" '.inflight_data.state' "fresh" "json: the in-flight refs' fetch state"
  lg inflight --branch feat-wt
  assert_eq "feat-wt local,worktree no PR claims:core-2 contracts:endpoint:create files:1" "$LG_OUT" "--branch: that branch"
  lg inflight --branch feat-a@hostb
  assert_eq "feat-a inflight@hostb no PR claims:core-1 contracts:— files:0" "$LG_OUT" "--branch <name>@<host>"
  lg inflight --branch nope
  assert_eq "1" "$LG_RC" "--branch unknown: exit 1"
  assert_contains "$LG_OUT" "no in-flight branch 'nope'" "…saying so"
  lg inflight extra
  assert_eq "3" "$LG_RC" "an argument: exit 3"
  # A stale branch (tip older than max_age_days) is not in flight — unless
  # it is the current branch.
  git checkout -q -b stale main
  GIT_COMMITTER_DATE="2020-01-01T12:00:00" git commit -q --allow-empty -m "old" -m "Ledger-Claims: app-5"
  git checkout -q main
  lg inflight
  assert_not_contains "$LG_OUT" "stale" "a stale branch is not listed"
  git checkout -q stale
  lg inflight
  assert_contains "$LG_OUT" "stale local,worktree no PR claims:app-5" "…unless it is the current branch (checked out here: a worktree too)"
  git checkout -q main
  lg_ifl_teardown
}

test_lg_inflight_excludes_views_branch() {
  echo "test: the views branch, the base's own branch and HEAD are never in flight"
  lg_ifl_fixture
  # Unmerged commits under the excluded names, on another host too.
  git push -q origin "$LG_A_TIP:refs/doc-superpowers/inflight/hostb/main" \
    "$LG_A_TIP:refs/doc-superpowers/inflight/hostb/HEAD" "$LG_A_TIP:refs/doc-superpowers/inflight/hostb/doc-ledger-views"
  git remote set-head origin main
  lg inflight --fetch
  assert_eq "0" "$LG_RC" "exit 0"
  assert_not_contains "$LG_OUT" "doc-ledger-views" "views.branch: neither the local, the remote nor another host's copy"
  assert_eq "" "$(printf '%s\n' "$LG_OUT" | awk '$1 == "main" || $1 == "HEAD"')" "nor main (the base's branch) nor origin/HEAD"
  lg ls --format json
  assert_eq "not started" "$(lg_ifl_status app-5)" "app-5: claimed only on the views branch"
  lg_enable '{"base":"origin/main","inflight":{"enabled":true,"host_id":"hosta"},"views":{"branch":"pages"}}'
  lg inflight
  assert_contains "$LG_OUT" "doc-ledger-views local,remote no PR claims:app-5" "another views.branch: listed"
  lg_ifl_teardown
}

test_lg_inflight_dedup_host_name() {
  echo "test: one line per (host, name) — this host's local, remote and in-flight copies merge (newest oid); other hosts' stay apart"
  lg_ifl_fixture
  git push -q origin feat-a
  git fetch -q origin
  lg inflight
  assert_eq "feat-a local,remote,inflight no PR claims:app-1,app-2 contracts:— files:1" "$(lg_line "$LG_OUT" "feat-a local")" \
    "local, remote and own in-flight: one line"
  assert_eq "feat-a inflight@hostb no PR claims:core-1 contracts:— files:0" "$(lg_line "$LG_OUT" "feat-a inflight@hostb")" \
    "hostb's feat-a: its own line"
  assert_eq "2" "$(printf '%s\n' "$LG_OUT" | grep -c '^feat-a ')" "two feat-a lines"
  # This host's in-flight copy is newer than the local branch: it wins.
  local newer
  newer=$(GIT_COMMITTER_DATE="$(($(date +%s) + 3600)) +0000" git commit-tree -p "$LG_A_TIP" -m "newer" -m "Ledger-Claims: app-5" "$LG_A_TIP^{tree}")
  git push -q origin "$newer:refs/doc-superpowers/inflight/hosta/feat-a"
  lg inflight --fetch --format json
  assert_json_field "$LG_OUT" '.branches[] | select(.branch == "feat-a") | .oid' "$newer" "the newest copy's oid wins"
  assert_json_field "$LG_OUT" '.branches[] | select(.branch == "feat-a") | .claims | join(",")' "app-1,app-2,app-5" "…and its claims"
  lg_ifl_teardown
}

test_lg_inflight_detached_worktree() {
  echo "test: a detached worktree is (detached:<path hash>) — never its path; at a merged commit it is not in flight"
  lg_ifl_fixture
  local d
  d=$(lg_ifl_detached "$LG_WT2")
  lg inflight --format json
  assert_json_field "$LG_OUT" ".branches[] | select(.branch == \"$d\") | [(.sources | join(\",\")), (.claims | join(\",\")), .oid] | join(\" \")" \
    "worktree app-4 $(git -C "$LG_WT2" rev-parse HEAD)" "the detached worktree: its HEAD's claims"
  assert_not_contains "$LG_OUT" "wt 2" "the path never appears"
  lg show app-4
  assert_contains "$(lg_line "$LG_OUT" "app-4")" "on branch $d" "show: on branch (detached:…)"
  ( cd "$LG_WT2" && git checkout -q --detach origin/main )
  lg inflight
  assert_not_contains "$LG_OUT" "(detached:" "a detached worktree at a merged commit: not in flight"
  lg_ifl_teardown
}

test_lg_inflight_prune_on_fetch() {
  echo "test: --fetch prunes in-flight refs the remote no longer has; without it the TTL holds"
  lg_ifl_fixture
  lg inflight
  assert_contains "$LG_OUT" "inflight@hostb" "hostb's branch, fetched (no copy yet: the TTL had expired)"
  ( cd "$LG_B" && git push -q origin ":refs/doc-superpowers/inflight/hostb/feat-a" )
  lg inflight
  assert_contains "$LG_OUT" "inflight@hostb" "deleted on the remote, within the TTL: still here"
  lg inflight --fetch
  assert_eq "0" "$LG_RC" "--fetch: exit 0"
  assert_not_contains "$LG_OUT" "inflight@hostb" "--fetch: pruned"
  assert_eq "" "$(git for-each-ref refs/doc-superpowers/inflight/hostb/)" "…the local ref too"
  lg_ifl_teardown
}

test_lg_inflight_unicode_branch() {
  echo "test: unicode and dash-led branch names travel whole (feat/ü-x, feat/-dash)"
  lg_ifl_fixture
  git checkout -q -b "feat/ü-x" main
  git commit -q --allow-empty -m "u" -m "Ledger-Claims: app-5"
  git checkout -q main
  ( cd "$LG_B" && git checkout -q -b "feat/-dash" origin/main && git commit -q --allow-empty -m "d" -m "Ledger-Claims: app-5" \
    && git push -q origin "feat/-dash" && git push -q origin "HEAD:refs/doc-superpowers/inflight/hostb/-lead/ü" )
  git fetch -q origin
  lg inflight --fetch
  assert_contains "$LG_OUT" "feat/ü-x local no PR claims:app-5" "feat/ü-x"
  assert_contains "$LG_OUT" "feat/-dash remote no PR claims:app-5" "feat/-dash"
  assert_contains "$LG_OUT" "-lead/ü inflight@hostb no PR claims:app-5" "another host's -lead/ü"
  lg inflight --branch=feat/-dash
  assert_eq "feat/-dash remote no PR claims:app-5 contracts:— files:0" "$LG_OUT" "--branch=feat/-dash"
  lg inflight --branch "feat/ü-x" --format json
  assert_json_field "$LG_OUT" '.branches | map(.name) | join(",")' "feat/ü-x" "--branch feat/ü-x (json)"
  lg ls --format json
  assert_eq "on branch -lead/ü@hostb" "$(lg_ifl_status app-5)" "app-5: the first claiming branch by name"
  lg_ifl_teardown
}

test_lg_host_id_anonymous() {
  echo "test: the host id — inflight.host_id, else git config doc-superpowers.ledger.host, else 8 hex of sha256(hostname); the hostname never appears"
  lg_ifl_fixture '{"base":"origin/main","inflight":{"enabled":true}}'
  local hn hid c
  hn=$(hostname 2>/dev/null || uname -n)
  hid=$(lg_sha8 "$hn")
  lg_call _lg_host_id
  assert_eq "0|$hid" "$LG_RC|$LG_OUT" "no setting: the hostname's hash"
  git config doc-superpowers.ledger.host from-git
  lg_call _lg_host_id
  assert_eq "from-git" "$LG_OUT" "git config doc-superpowers.ledger.host"
  lg_enable '{"base":"origin/main","inflight":{"enabled":true,"host_id":"from-config"}}'
  lg_call _lg_host_id
  assert_eq "from-config" "$LG_OUT" "inflight.host_id wins"
  lg_enable '{"base":"origin/main","inflight":{"enabled":true,"host_id":"a/b"}}'
  lg inflight
  assert_eq "2" "$LG_RC" "a host id that is no ref segment: exit 2"
  assert_contains "$LG_ERR$LG_OUT" "inflight.host_id" "…naming the key"
  git config --unset doc-superpowers.ledger.host
  lg_enable '{"base":"origin/main","inflight":{"enabled":true}}'
  # This host's in-flight copy, under the hash, merges with the local branch.
  git push -q origin "feat-a~1:refs/doc-superpowers/inflight/$hid/feat-a"
  lg inflight --fetch --format json
  assert_json_field "$LG_OUT" '.host_id' "$hid" "json: host_id"
  assert_json_field "$LG_OUT" '.branches[] | select(.name == "feat-a" and .own) | .sources | join(",")' "local,inflight" \
    "the hash's in-flight copy is this host's"
  local all
  all="$LG_OUT$LG_ERR"
  lg inflight
  all="$all$LG_OUT$LG_ERR"
  lg ls
  all="$all$LG_OUT$LG_ERR"
  c="$(git rev-parse --git-common-dir)/doc-superpowers"
  if [ "${#hn}" -ge 3 ]; then
    assert_not_contains "$(git for-each-ref --format='%(refname)'; git --git-dir="$LG_REMOTE" for-each-ref --format='%(refname)')" "$hn" \
      "no ref names the hostname (here or on the remote)"
    assert_not_contains "$(cd "$c" && find . -print)" "$hn" "no cache file names it"
    assert_not_contains "$all" "$hn" "no output names it"
  else
    _pass "hostname '$hn' too short to search for"
  fi
  lg_ifl_teardown
}

test_lg_branch_facts_claims_and_contracts() {
  echo "test: _lg_branch_facts — claims (trailers, paths, item files, plans), contract changes (defined_in, Contract-Change), acks over merge-base..tip: merged feature work counts, merged trunk never (R2)"
  lg_ifl_fixture '{"base":"origin/main","inflight":{"enabled":true,"host_id":"hosta"},"trailers":{"claims_by_path":["Ledger-Claims-Path"]}}'
  git checkout -q -b facts main
  git commit -q --allow-empty -m "work" -m "Ledger-Claims: APP-1, nope-9
Ledger-Claims-Path: ./docs/issues/c.md
Contract-Change: endpoint:create — renames a param
Ledger-Ack: 0123456789ab — seen it
Fixes #12"
  echo changed >> src/order/total.js
  git add -A && git commit -qm "touch the total"
  printf '# Q\n\nCovers core-2.\n' > docs/plans/q.md
  git add -A && git commit -qm "a new plan"
  git checkout -q -b feature main
  git commit -q --allow-empty -m "feature work" -m "Ledger-Claims: app-4"
  git checkout -q facts
  git merge -q --no-ff feature -m "merge feature"
  LG_FACTS1=$(git rev-parse HEAD)
  # The trunk moves (claims app-5, adds a component:Sheet file) and is merged in.
  git checkout -q main
  mkdir -p src/sheet
  echo s > src/sheet/a.js
  git add -A && git commit -q -m "trunk work" -m "Ledger-Claims: app-5"
  git push -q origin main
  git fetch -q origin
  git checkout -q facts
  git merge -q --no-ff origin/main -m "merge trunk"
  git checkout -q main
  lg_call _lg_branch_facts "$(git rev-parse facts)"
  assert_eq "0" "$LG_RC" "rc 0"
  assert_json_field "$LG_OUT" '.merge_base' "$(git rev-parse origin/main)" "merge_base: the trunk merged in"
  assert_json_field "$LG_OUT" '.files | join(",")' "docs/plans/q.md,src/order/total.js" "files: the net diff from the merge base"
  assert_json_field "$LG_OUT" '.claims | join(",")' "app-1,app-3,app-4,core-2" \
    "claims: a trailer (any case), a path trailer, the merged feature's trailer, a plan's key — never the trunk's app-5, never an unknown key"
  assert_json_field "$LG_OUT" '.contract_changes | map("\(.id)=\(.line)") | join(",")' "endpoint:create=renames a param,field:order.total=null" \
    "contract changes: Contract-Change and defined_in — never the trunk's component:Sheet"
  assert_json_field "$LG_OUT" '.acks | join(",")' "0123456789ab" "acks"
  assert_json_field "$LG_OUT" '.refs | join(",")' "#12" "issue refs no adapter maps"
  # Before the trunk merge (one merge base: the fork point).
  lg_call _lg_branch_facts "$LG_FACTS1"
  assert_json_field "$LG_OUT" '[.merge_base, (.claims | join(","))] | join(" ")' \
    "$(git merge-base origin/main "$LG_FACTS1") app-1,app-3,app-4,core-2" "the fork point; the same claims"
  # The verb: the unresolved ref counted in the one stderr note.
  lg inflight --branch facts
  assert_eq "facts local no PR claims:app-1,app-3,app-4,core-2 contracts:endpoint:create,field:order.total files:2" "$LG_OUT" "inflight --branch facts"
  assert_eq "1" "$(printf '%s\n' "$LG_ERR" | grep -c '^ledger:')" "one ledger: note"
  assert_contains "$LG_ERR" "1 issue reference not resolved (#12)" "…counting the unresolved ref"
  lg_ifl_teardown
}

test_lg_branch_facts_criss_cross() {
  echo "test: _lg_branch_facts on a criss-cross (git names two merge bases) — the first, and its own range's trailers"
  lg_ifl_fixture
  git checkout -q -b cc main
  git commit -q --allow-empty -m "branch side" -m "Ledger-Claims: app-3"
  local b
  b=$(git rev-parse HEAD)
  git checkout -q main
  git commit -q --allow-empty -m "trunk side" -m "Ledger-Claims: app-5"
  local a
  a=$(git rev-parse HEAD)
  git merge -q --no-ff cc -m "trunk merges the branch"
  git push -q origin main
  git fetch -q origin
  git checkout -q cc
  git merge -q --no-ff "$a" -m "the branch merges the trunk side" -m "Ledger-Claims: core-2"
  git checkout -q main
  assert_eq "2" "$(git merge-base --all origin/main cc | wc -l | tr -d ' ')" "fixture: two merge bases"
  lg_call _lg_branch_facts cc
  assert_eq "0" "$LG_RC" "rc 0"
  local mb want
  mb=$(git merge-base origin/main cc)
  if [ "$mb" = "$a" ]; then want="app-3,core-2"; else want="app-5,core-2"; fi
  assert_json_field "$LG_OUT" '[.merge_base, (.claims | join(","))] | join(" ")' "$mb $want" \
    "git's first merge base; the trailers of merge-base..tip"
  lg_ifl_teardown
}

test_lg_show_inflight_claims() {
  echo "test: show lists the in-flight claims; the derived status is on branch <b> (no PR)"
  lg_ifl_fixture
  lg show app-1
  assert_eq "0" "$LG_RC" "exit 0"
  assert_contains "$(lg_line "$LG_OUT" "app-1")" "on branch feat-a" "the status: on branch feat-a"
  assert_contains "$LG_OUT" "in flight: feat-a (local,inflight, no PR)" "the in-flight line"
  lg show core-1
  assert_contains "$(lg_line "$LG_OUT" "core-1")" "on branch feat-a@hostb" "another host's branch: <name>@<host>"
  assert_contains "$LG_OUT" "in flight: feat-a@hostb (inflight@hostb, no PR)" "…and its line"
  lg show core-1 --format json
  assert_json_field "$LG_OUT" '.item.inflight | map("\(.branch) \(.host) \(.sources | join(","))") | join(";")' "feat-a@hostb hostb inflight" \
    "json: .item.inflight"
  assert_json_field "$LG_OUT" '.item.derived | "\(.status) \(.detail)"' "on branch feat-a@hostb" "json: derived"
  lg ls --format json
  assert_eq "on branch feat-a|on branch r-only|on branch feat-wt|not started" \
    "$(lg_ifl_status app-2)|$(lg_ifl_status app-3)|$(lg_ifl_status core-2)|$(lg_ifl_status app-5)" "ls: edited file, remote branch, plan; app-5 untouched"
  lg ls --status "on branch"
  assert_eq "app-1 app-2 app-3 app-4 core-1 core-2" "$(printf '%s\n' "$LG_OUT" | awk '{ print $1 }' | sort | tr '\n' ' ' | sed 's/ $//')" \
    "ls --status 'on branch'"
  lg_ifl_teardown
}

test_lg_view_publish_inflight() {
  echo "test: view and publish render the in-flight overlay — the header's branch count, each ledger's in-flight branches"
  lg_ifl_fixture
  lg view app --out "$TEST_DIR/v"
  assert_eq "0" "$LG_RC" "view: exit 0"
  assert_contains "$(cat "$TEST_DIR/v/app.md")" "+ 5 in-flight branches at" "view: the header counts the branches in flight"
  assert_contains "$(cat "$TEST_DIR/v/app.md")" "In flight: 3 branches" "view: app's items are claimed on 3 branches"
  lg publish --format json
  assert_eq "0" "$LG_RC" "publish: exit 0"
  assert_json_field "$LG_OUT" '.message | test("^views @ origin/main@[0-9a-f]+, 5 in-flight branches, ")' "true" "publish: the message counts them"
  lg_ifl_teardown
}

test_lg_inflight_tip_move_keeps_index() {
  echo "test: a branch tip that moves never rebuilds the item index — only the in-flight overlay (R1)"
  lg_ifl_fixture
  lg ls
  DOC_TOOLS_LEDGER_TRACE=1 lg ls
  assert_contains "$LG_ERR" "index-hit" "warm: an index hit"
  assert_contains "$LG_ERR" "inflight-hit" "…and an overlay hit"
  ( cd "$LG_WT1" && git commit -q --allow-empty -m "more" -m "Ledger-Claims: app-5" )
  DOC_TOOLS_LEDGER_TRACE=1 lg ls --format json
  assert_contains "$LG_ERR" "index-hit" "the tip moved: still an index hit"
  assert_contains "$LG_ERR" "inflight-build" "…the overlay rebuilt"
  assert_contains "$LG_ERR" "inflight-facts 1 cold" "…from one branch's new facts"
  assert_eq "on branch feat-wt" "$(lg_ifl_status app-5)" "app-5: claimed by the moved tip"
  # The base moves: every merge base is looked up again, no facts recomputed.
  git commit -q --allow-empty -m "trunk moves"
  git push -q origin main
  git fetch -q origin
  DOC_TOOLS_LEDGER_TRACE=1 lg ls --format json
  assert_contains "$LG_ERR" "inflight-facts 0 cold" "the base moved: the branches' facts reused"
  assert_eq "on branch feat-wt" "$(lg_ifl_status app-5)" "…the same claims"
  lg_ifl_teardown
}

test_lg_inflight_disabled_zero_cost() {
  echo "test: inflight.enabled false — nothing scanned, nothing fetched, statuses untouched"
  lg_ifl_fixture '{"base":"origin/main"}'
  local tr
  tr=$(harness_mktemp lg-gtrace)
  GIT_TRACE="$tr" DOC_TOOLS_LEDGER_TRACE=1 lg ls --format json
  assert_eq "0" "$LG_RC" "exit 0"
  assert_eq "not started" "$(lg_ifl_status app-1)" "app-1: not started"
  assert_not_contains "$LG_ERR" "inflight-" "no in-flight trace"
  assert_eq "" "$(grep -E 'for-each-ref|worktree list|fetch|merge-base|diff-tree' "$tr" || true)" \
    "git ran no scan, fetch, merge-base or diff"
  assert_eq "" "$(git for-each-ref refs/doc-superpowers/)" "no in-flight ref fetched"
  lg inflight
  assert_eq "0|in-flight awareness is off (config inflight.enabled)" "$LG_RC|$LG_OUT" "inflight: off, exit 0"
  lg inflight --format json
  assert_json_field "$LG_OUT" '[.exit, .inflight_enabled, (.branches | length)] | map(tostring) | join(",")' "0,false,0" "json: off"
  rm -f "$tr"
  lg_ifl_teardown
}

test_lg_inflight_fetch_offline() {
  echo "test: DOC_TOOLS_LEDGER_OFFLINE=1 — --fetch exits 2 (offline); scans use what is here; --push does nothing (R7)"
  lg_ifl_fixture
  local tr
  tr=$(harness_mktemp lg-gtrace)
  DOC_TOOLS_LEDGER_OFFLINE=1 lg inflight --fetch
  assert_eq "2" "$LG_RC" "--fetch offline: exit 2"
  assert_contains "$LG_OUT$LG_ERR" "offline" "…saying offline"
  GIT_TRACE="$tr" DOC_TOOLS_LEDGER_OFFLINE=1 lg inflight
  assert_eq "0" "$LG_RC" "offline scan: exit 0"
  assert_not_contains "$LG_OUT" "@hostb" "nothing fetched: no other host's branch"
  assert_eq "" "$(grep -E ' fetch ' "$tr" || true)" "no git fetch"
  local before
  before=$(git --git-dir="$LG_REMOTE" for-each-ref)
  DOC_TOOLS_LEDGER_OFFLINE=1 lg inflight --push
  assert_eq "0" "$LG_RC" "--push offline: exit 0"
  assert_contains "$LG_ERR" "offline" "…a warning"
  assert_eq "$before" "$(git --git-dir="$LG_REMOTE" for-each-ref)" "…nothing pushed"
  lg inflight
  assert_contains "$LG_OUT" "@hostb" "online: fetched (TTL expired, no copy)"
  rm -f "$tr"
  lg_ifl_teardown
}

test_lg_inflight_pull_refs() {
  echo "test: inflight.pull_refs — PR heads (a fork's too) fetched into refs/doc-superpowers/pull/*; an in-flight branch shows its PR (R4)"
  lg_fake_gh
  local cfg='{"base":"origin/main","inflight":{"enabled":true,"host_id":"hosta","pull_refs":"refs/pull/*/head"},"adapters":{"pr":"doc-superpowers:ledger-pr-gh"}}'
  lg_ifl_fixture "$cfg"
  local fork
  fork=$(git commit-tree -p main -m "fork work" -m "Ledger-Claims: app-5" "main^{tree}")
  git push -q origin "$fork:refs/pull/7/head"
  git push -q origin feat-a
  git fetch -q origin
  cat > "$LG_GH/prs.json" <<JSON
[{"number":21,"headRefName":"feat-a","state":"OPEN","url":"https://github.com/o/r/pull/21","mergeCommit":null},
 {"number":7,"headRefName":"feature","headRefOid":"$fork","state":"OPEN","url":"https://github.com/o/r/pull/7","mergeCommit":null,"isCrossRepository":true}]
JSON
  lg ls --format json
  assert_eq "0" "$LG_RC" "exit 0"
  assert_eq "in review #7" "$(lg_ifl_status app-5)" "app-5: the fork's PR #7, its head through refs/doc-superpowers/pull/7"
  assert_eq "$fork" "$(git rev-parse -q --verify refs/doc-superpowers/pull/7)" "the pull ref was fetched"
  assert_not_contains "$LG_ERR" "cross-repository" "no 'not compared' note"
  assert_eq "in review #21" "$(lg_ifl_status app-1)" "app-1: in review #21"
  lg inflight
  assert_contains "$LG_OUT" "feat-a local,remote,inflight PR #21 claims:app-1,app-2" "the in-flight line names the PR"
  lg inflight --format json
  assert_json_field "$LG_OUT" '.pr_data.state' "fresh" "json: pr_data"
  assert_json_field "$LG_OUT" '.branches[] | select(.branch == "feat-a") | .pr | "\(.number) \(.state)"' "21 open" "json: the branch's PR"
  # Without pull_refs: the fork is not compared.
  lg_enable '{"base":"origin/main","inflight":{"enabled":true,"host_id":"hosta"},"adapters":{"pr":"doc-superpowers:ledger-pr-gh"}}'
  lg ls --format json
  assert_eq "not started" "$(lg_ifl_status app-5)" "no pull_refs: app-5 not started"
  assert_contains "$LG_ERR" "1 cross-repository open PR not compared (#7)" "…the fork counted"
  lg_fake_gh_off
  lg_ifl_teardown
}

# --- Task 11 fix round 1 -------------------------------------------------------------

test_lg_registry_failure_one_object() {
  echo "test: an unreadable registry is one verdict object — the producer's failure inside \$(…) is not run past (m9)"
  lg_fixture
  lg_enable '{"base":"main"}'
  printf 'not json\n' > docs/ledger/ledgers.json
  local v
  for v in ls show find related recheck view; do
    case "$v" in
      show|related|recheck) lg "$v" x-1 --format json ;;
      find) lg find word --format json ;;
      view) lg view all --out "$TEST_DIR/v" --format json ;;
      *) lg "$v" --format json ;;
    esac
    assert_eq "2|1" "$LG_RC|$(json_count "$LG_OUT")" "$v: exit 2, exactly one object"
  done
  teardown
}

test_lg_inflight_bg_scan_one_object() {
  echo "test: the background scan prints no verdict — one object when the index build fails during a slow fetch; the child is gone at exit; a \$(…) consumer returns at once (I1)"
  lg_ifl_fixture
  git config protocol.ext.allow always
  git remote set-url origin "ext::sleep 4"
  printf 'not json\n' > docs/ledger/ledgers.json
  local pidf t0 t1 out rc=0
  pidf=$(harness_mktemp lg-pid)
  t0=$(date +%s)
  out=$(DOC_TOOLS_LEDGER_SELFTEST=ifl-pidfile DOC_TOOLS_LEDGER_SELFTEST_PIDFILE="$pidf" "$DOC_TOOLS" ledger ls --format json 2>/dev/null </dev/null) || rc=$?
  t1=$(date +%s)
  assert_eq "2|1" "$rc|$(json_count "$out")" "exit 2, exactly one object"
  assert_json_field "$out" '.error | test("registry")' "true" "…the index build's error"
  assert_eq "1" "$([ $((t1 - t0)) -lt 3 ] && echo 1 || echo "$((t1 - t0)) s")" "the consumer returned before the 4 s fetch ended"
  assert_eq "gone" "$(if [ -s "$pidf" ] && kill -0 "$(cat "$pidf")" 2>/dev/null; then echo alive; elif [ -s "$pidf" ]; then echo gone; else echo "no pid"; fi)" \
    "the scan child is gone when the run ends"
  # A failure in the child itself (an invalid host id from git config) is
  # the parent's one verdict.
  printf '%s\n' '{"schema":"ledger-registry/1","ledgers":[]}' > docs/ledger/ledgers.json
  git remote set-url origin "$LG_REMOTE"
  lg_enable '{"base":"origin/main","inflight":{"enabled":true}}'
  git config doc-superpowers.ledger.host "a/b"
  lg ls --format json
  assert_eq "2|1" "$LG_RC|$(json_count "$LG_OUT")" "a child failure: exit 2, exactly one object"
  assert_contains "$LG_OUT" "doc-superpowers.ledger.host" "…its message"
  lg ls
  assert_contains "$LG_ERR" "doc-superpowers.ledger.host" "text: the message on stderr"
  assert_eq "1" "$(printf '%s\n' "$LG_ERR" | grep -c 'ERROR:')" "…once"
  git config --unset doc-superpowers.ledger.host
  rm -f "$pidf"
  lg_ifl_teardown
}

# --- Task 11 fix round 3 -------------------------------------------------------------

# lg_ps_has <pattern>: 1 when a process whose command line contains
# <pattern> is running, else 0.
lg_ps_has() {
  if ps -ax -o command= 2>/dev/null | grep -F -- "$1" | grep -v grep > /dev/null; then echo 1; else echo 0; fi
}

test_lg_inflight_scan_children_reaped() {
  echo "test: the scan's git fetch and its transport never outlive the run — failure path and signal (R3-1)"
  lg_ifl_fixture
  git config protocol.ext.allow always
  git remote set-url origin "ext::sleep 7.31"
  printf 'not json\n' > docs/ledger/ledgers.json
  local rc=0 out pid i seen=0
  out=$(DOC_TOOLS_LEDGER_SELFTEST=ifl-index-delay "$DOC_TOOLS" ledger ls --format json 2>/dev/null </dev/null) || rc=$?
  assert_eq "2|1" "$rc|$(json_count "$out")" "the index build fails: exit 2, one object"
  sleep 1
  assert_eq "0" "$(lg_ps_has 'sleep 7.31')" "failure path: the slow transport is gone"
  # A signal while the fetch runs (TERM: a background job of a script
  # ignores INT; both reach the same EXIT trap).
  printf '%s\n' '{"schema":"ledger-registry/1","ledgers":[]}' > docs/ledger/ledgers.json
  git remote set-url origin "ext::sleep 7.32"
  "$DOC_TOOLS" ledger ls < /dev/null > /dev/null 2>&1 &
  pid=$!
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if [ "$(lg_ps_has 'sleep 7.32')" = 1 ]; then seen=1; break; fi
    sleep 0.3
  done
  assert_eq "1" "$seen" "the slow transport ran"
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  sleep 1
  assert_eq "0" "$(lg_ps_has 'sleep 7.32')" "signal: the slow transport is gone"
  git remote set-url origin "$LG_REMOTE"
  lg_ifl_teardown
}

test_lg_inflight_heads_prefix_checked() {
  echo "test: a ref_prefix under refs/heads/ is checked before fetching — no upstream, no worktree, <host>/<name> shape; an unpushed branch there is never touched (R3-2b)"
  lg_ifl_fixture '{"base":"origin/main","inflight":{"enabled":true,"host_id":"hosta","ref_prefix":"refs/heads/feature"}}'
  git branch -q feature/x "$LG_A_TIP"
  lg inflight --fetch
  assert_eq "2" "$LG_RC" "feature/x (no <host>/<name> shape): exit 2"
  assert_contains "$LG_ERR" "feature/x" "…naming it"
  assert_eq "$LG_A_TIP" "$(git rev-parse -q --verify refs/heads/feature/x)" "feature/x intact"
  git branch -q -D feature/x
  git branch -q feature/h/y "$LG_A_TIP"
  git branch -q --set-upstream-to=origin/main feature/h/y
  lg inflight --fetch
  assert_eq "2" "$LG_RC" "a branch with an upstream there: exit 2"
  assert_eq "$LG_A_TIP" "$(git rev-parse -q --verify refs/heads/feature/h/y)" "…intact"
  git branch -q -D feature/h/y
  lg inflight --fetch
  assert_eq "0" "$LG_RC" "nothing there but in-flight refs: exit 0"
  git worktree add -q -b feature/h/z "$LG_WT/wt 3" main
  lg inflight --fetch
  assert_eq "2" "$LG_RC" "a branch checked out in a worktree there: exit 2"
  assert_eq "$(git -C "$LG_WT/wt 3" rev-parse HEAD)" "$(git rev-parse -q --verify refs/heads/feature/h/z)" "…intact"
  lg_ifl_teardown
}

test_lg_inflight_fetch_recorded_only() {
  echo "test: the in-flight fetch prunes only refs it recorded, and never overwrites a ref here that differs from its record (R3-2a)"
  lg_ifl_fixture
  # A first fetch records the mirrors (with no record and no earlier fetch,
  # <host>/<name>-shaped refs here would be adopted: R4-1, its own test).
  lg inflight --fetch
  # A ref here that no fetch wrote, and one that differs from the remote's.
  git update-ref refs/doc-superpowers/inflight/hostz/local-only "$LG_A_TIP"
  git update-ref refs/doc-superpowers/inflight/hostb/feat-a "$LG_A_TIP"
  lg inflight --fetch
  assert_eq "0" "$LG_RC" "exit 0"
  assert_eq "$LG_A_TIP" "$(git rev-parse -q --verify refs/doc-superpowers/inflight/hostz/local-only)" "an unrecorded ref here is never deleted"
  assert_eq "$LG_A_TIP" "$(git rev-parse -q --verify refs/doc-superpowers/inflight/hostb/feat-a)" "a ref that differs is never overwritten"
  assert_contains "$LG_ERR" "refs/doc-superpowers/inflight/hostb/feat-a" "…the note names it"
  assert_contains "$LG_ERR" "git update-ref -d <ref>" "…and its remedy (R4-1d)"
  assert_contains "$LG_ERR" "not on the remote" "a ref here the remote lacks and no fetch wrote is named (R5-2)"
  assert_contains "$LG_ERR" "refs/doc-superpowers/inflight/hostz/local-only" "…by name"
  # A recorded mirror whose remote ref is gone is pruned; an unrecorded one stays.
  git update-ref -d refs/doc-superpowers/inflight/hostb/feat-a
  lg inflight --fetch
  assert_contains "$LG_OUT" "feat-a inflight@hostb" "fetched now (recorded)"
  ( cd "$LG_B" && git push -q origin ":refs/doc-superpowers/inflight/hostb/feat-a" )
  lg inflight --fetch
  assert_eq "" "$(git for-each-ref refs/doc-superpowers/inflight/hostb/)" "the recorded mirror is pruned"
  assert_eq "$LG_A_TIP" "$(git rev-parse -q --verify refs/doc-superpowers/inflight/hostz/local-only)" "the unrecorded one stays"
  lg_ifl_teardown
}

test_lg_verdict_backstop() {
  echo "test: one verdict per run — a later failure is one stderr line and a non-zero exit; no success object after an error object (R3-4, R3-6)"
  lg_fixture
  lg_enable
  DOC_TOOLS_LEDGER_SELFTEST=die-twice lg ls --format json
  assert_eq "2|1" "$LG_RC|$(json_count "$LG_OUT")" "die twice: exit 2, one object"
  assert_contains "$LG_ERR" "ERROR (after the run's verdict): second" "…the second as one stderr line"
  DOC_TOOLS_LEDGER_SELFTEST=emit-after-error lg ls --format json
  assert_eq "2|1" "$LG_RC|$(json_count "$LG_OUT")" "a success emit after an error object: exit 2, one object"
  assert_json_field "$LG_OUT" '.exit' "2" "…the error object"
  teardown
}

test_lg_inline_producer_die_one_object() {
  echo "test: a die inside an inline producer (\$(…) inside a string) — exactly one object, non-zero (R3-6)"
  lg_pr_fixture
  DOC_TOOLS_LEDGER_SELFTEST=die-in-pr-numbers lg ls --format json
  assert_eq "2|1" "$LG_RC|$(json_count "$LG_OUT")" "exit 2, one object"
  lg_pr_teardown
}

# --- Task 11 fix round 4 -------------------------------------------------------------

# lg_ifl_ref <host>/<name>: the oid of refs/doc-superpowers/inflight/<host>/<name> here ("" when absent).
lg_ifl_ref() {
  git rev-parse -q --verify "refs/doc-superpowers/inflight/$1" 2>/dev/null || true
}

# lg_ifl_remote_ref <host>/<name>: its oid on the bare remote ("" when absent).
lg_ifl_remote_ref() {
  git --git-dir="$LG_REMOTE" rev-parse -q --verify "refs/doc-superpowers/inflight/$1" 2>/dev/null || true
}

test_lg_inflight_mirror_cache_wiped() {
  echo "test: the in-flight mirrors outlive a lost cache — a moved remote ref still updates, a deleted one still prunes (R4-1)"
  lg_ifl_fixture
  local m2
  ( cd "$LG_B" && git push -q origin "HEAD:refs/doc-superpowers/inflight/hostb/moving" "HEAD:refs/doc-superpowers/inflight/hostb/gone" )
  lg inflight --fetch
  assert_eq "$(lg_ifl_remote_ref hostb/moving)" "$(lg_ifl_ref hostb/moving)" "fetched"
  rm -rf "$(git rev-parse --git-common-dir)/doc-superpowers"
  m2=$(cd "$LG_B" && git commit-tree -p HEAD -m moved "HEAD^{tree}")
  ( cd "$LG_B" && git push -q -f origin "$m2:refs/doc-superpowers/inflight/hostb/moving" ":refs/doc-superpowers/inflight/hostb/gone" )
  lg inflight --fetch
  assert_eq "0" "$LG_RC" "cache wiped: exit 0"
  assert_eq "$m2" "$(lg_ifl_ref hostb/moving)" "…the moved ref is updated"
  assert_eq "" "$(lg_ifl_ref hostb/gone)" "…the deleted one is pruned"
  assert_not_contains "$LG_ERR" "differ" "…no 'differ' note"
  lg_ifl_teardown
}

test_lg_inflight_mirror_killed_before_record() {
  echo "test: a run killed between the mirror update and its record — the next fetch after a remote move still updates (R4-1)"
  lg_ifl_fixture '{"base":"origin/main","inflight":{"enabled":true,"host_id":"hosta"},"cache":{"remote_ttl_minutes":0}}'
  local m1 m2
  lg inflight --fetch
  m1=$(cd "$LG_B" && git commit-tree -p HEAD -m m1 "HEAD^{tree}")
  ( cd "$LG_B" && git push -q -f origin "$m1:refs/doc-superpowers/inflight/hostb/feat-a" )
  DOC_TOOLS_LEDGER_SELFTEST=ifl-kill-after-update-ref lg ls
  assert_eq "2" "$LG_RC" "the scan killed after its update-ref: exit 2"
  assert_eq "$m1" "$(lg_ifl_ref hostb/feat-a)" "…the mirror was updated, its record not"
  m2=$(cd "$LG_B" && git commit-tree -p "$m1" -m m2 "HEAD^{tree}")
  ( cd "$LG_B" && git push -q -f origin "$m2:refs/doc-superpowers/inflight/hostb/feat-a" )
  lg inflight --fetch
  assert_eq "0" "$LG_RC" "the next fetch: exit 0"
  assert_eq "$m2" "$(lg_ifl_ref hostb/feat-a)" "…the moved ref is updated"
  assert_not_contains "$LG_ERR" "differ" "…no 'differ' note"
  lg_ifl_teardown
}

test_lg_inflight_mirror_adopt_cold() {
  echo "test: no record and no earlier fetch — refs here shaped <host>/<name> are adopted as mirrors (said once); others are never touched (R4-1c)"
  lg_ifl_fixture
  git update-ref refs/doc-superpowers/inflight/hostb/feat-a "$LG_A_TIP"
  git update-ref refs/doc-superpowers/inflight/hostz/stale "$LG_A_TIP"
  git update-ref refs/doc-superpowers/inflight/local-only "$LG_A_TIP"
  git update-ref refs/doc-superpowers/inflight/-x/y "$LG_A_TIP"
  lg inflight --fetch
  assert_eq "0" "$LG_RC" "exit 0"
  assert_eq "$(lg_ifl_remote_ref hostb/feat-a)" "$(lg_ifl_ref hostb/feat-a)" "a shaped ref that differs: adopted, updated"
  assert_eq "" "$(lg_ifl_ref hostz/stale)" "a shaped ref the remote lacks: adopted, pruned"
  assert_eq "$LG_A_TIP" "$(lg_ifl_ref local-only)" "a ref not shaped like a mirror survives (no <host>/)"
  assert_eq "$LG_A_TIP" "$(lg_ifl_ref -x/y)" "…nor one whose host segment is invalid"
  assert_contains "$LG_ERR" "adopted" "the note says so"
  assert_eq "1" "$(printf '%s\n' "$LG_ERR" | grep -c 'adopted')" "…once"
  assert_contains "$LG_ERR" "refs/doc-superpowers/inflight/local-only" "the unshaped refs the remote lacks are named (R5-2)"
  # Afterwards there is a record and a fetched snapshot: nothing is adopted.
  git update-ref refs/doc-superpowers/inflight/hostz/later "$LG_A_TIP"
  lg inflight --fetch
  assert_eq "$LG_A_TIP" "$(lg_ifl_ref hostz/later)" "with a record: an unrecorded shaped ref is never deleted"
  assert_not_contains "$LG_ERR" "adopted" "…and nothing is adopted"
  lg_ifl_teardown
}

test_lg_inflight_sigint_reaps_transport() {
  echo "test: a terminal-style SIGINT to the run's process group — the fetch's transport does not survive (R4-2)"
  lg_ifl_fixture
  # An ssh transport through a shell (sh → sleep): the shell is the
  # grandchild that a bare `kill <fetch pid>` orphans.
  git remote set-url origin "ssh://lg-test.invalid/r.git"
  local pid i seen=0
  set -m
  GIT_SSH_COMMAND='sleep 7.33; exit 1' "$DOC_TOOLS" ledger ls < /dev/null > /dev/null 2>&1 &
  pid=$!
  set +m
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if [ "$(lg_ps_has 'sleep 7.33')" = 1 ]; then seen=1; break; fi
    sleep 0.3
  done
  assert_eq "1" "$seen" "the slow transport ran"
  kill -INT -- "-$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  sleep 1
  assert_eq "0" "$(lg_ps_has 'sleep 7.33')" "SIGINT to the group: the slow transport is gone"
  git remote set-url origin "$LG_REMOTE"
  lg_ifl_teardown
}

test_lg_inflight_anc_errors_uncached() {
  echo "test: an ancestry check that errors (merge-base exit 128) is never cached — the next run asks again (R4-3)"
  lg_ifl_fixture
  local fake real tr
  fake=$(harness_mktemp_d lg-fakegit)
  real=$(command -v git)
  # shellcheck disable=SC2016  # the fake's own $1 / $@
  printf '#!/bin/sh\nif [ "$1" = merge-base ] && [ "$2" = --is-ancestor ]; then exit 128; fi\nexec "%s" "$@"\n' "$real" > "$fake/git"
  chmod +x "$fake/git"
  PATH="$fake:$PATH" lg inflight --fetch --format json
  assert_eq "0" "$LG_RC" "every ancestry check errors: exit 0"
  tr=$(harness_mktemp lg-gtrace)
  GIT_TRACE="$tr" lg inflight --format json
  assert_eq "1" "$(if [ "$(grep -c 'is-ancestor' "$tr")" -gt 0 ]; then echo 1; else echo 0; fi)" "the errored verdicts were not cached: asked again"
  assert_json_field "$LG_OUT" '.branches[] | select(.branch == "feat-a") | .oid' "$LG_A_TIP" "…the descendant wins"
  : > "$tr"
  GIT_TRACE="$tr" lg inflight --format json
  assert_eq "0" "$(grep -c 'is-ancestor' "$tr")" "the 0/1 verdicts are cached"
  rm -rf "$tr" "$fake"
  lg_ifl_teardown
}

# --- Task 11 fix round 5 -------------------------------------------------------------

test_lg_inflight_heads_cold_ff_only() {
  echo "test: cold-start adoption under refs/heads/ only fast-forwards — an unpushed branch is never deleted, a diverged one never overwritten (R5-1)"
  lg_ifl_fixture '{"base":"origin/main","inflight":{"enabled":true,"host_id":"hosta","ref_prefix":"refs/heads/wip"}}'
  local main_oid y bob
  main_oid=$(git rev-parse origin/main)
  bob=$(git -C "$LG_B" rev-parse HEAD)
  y=$(cd "$LG_B" && git commit-tree -p origin/main -m "carol ahead" "origin/main^{tree}")
  ( cd "$LG_B" && git push -q origin "$bob:refs/heads/wip/bob/thing" "$y:refs/heads/wip/carol/ff" )
  # First-ever fetch: no record, no snapshot. Here: an unpushed branch, one
  # that diverges from the remote's, one the remote's tip fast-forwards.
  git branch -q wip/alice/experiment "$LG_A_TIP"
  git branch -q wip/bob/thing "$LG_A_TIP"
  git branch -q wip/carol/ff "$main_oid"
  lg inflight --fetch
  assert_eq "0" "$LG_RC" "exit 0"
  assert_eq "$LG_A_TIP" "$(git rev-parse -q --verify refs/heads/wip/alice/experiment)" "the unpushed branch is intact"
  assert_eq "$LG_A_TIP" "$(git rev-parse -q --verify refs/heads/wip/bob/thing)" "the diverged branch is not overwritten"
  assert_eq "$y" "$(git rev-parse -q --verify refs/heads/wip/carol/ff)" "the fast-forwardable branch is updated"
  assert_contains "$LG_ERR" "refs/heads/wip/bob/thing" "the note names the diverged one"
  assert_contains "$LG_ERR" "rename it out of refs/heads/wip/ (\`git branch -m\`)" "…with its remedy (never update-ref -d: it may be the user's branch)"
  assert_contains "$LG_ERR" "refs/heads/wip/alice/experiment" "…and the one the remote lacks (R5-2)"
  assert_contains "$LG_ERR" "adopted" "the adoption is said"
  # A second fetch (record and snapshot now): still intact.
  lg inflight --fetch
  assert_eq "$LG_A_TIP|$LG_A_TIP" "$(git rev-parse -q --verify refs/heads/wip/alice/experiment)|$(git rev-parse -q --verify refs/heads/wip/bob/thing)" \
    "a second fetch: both still intact"
  lg_ifl_teardown
}

# --- Task 12 carry-over (Task 11 review) ---------------------------------------------

test_lg_inflight_heads_differ_remedy() {
  echo "test: a 'differ' note under refs/heads/<seg> never tells the user to update-ref -d what may be their own branch; elsewhere the update-ref remedy stays"
  lg_ifl_fixture '{"base":"origin/main","inflight":{"enabled":true,"host_id":"hosta","ref_prefix":"refs/heads/wip"}}'
  local bob
  bob=$(git -C "$LG_B" rev-parse HEAD)
  ( cd "$LG_B" && git push -q origin "$bob:refs/heads/wip/bob/thing" )
  lg inflight --fetch
  assert_eq "$bob" "$(git rev-parse -q --verify refs/heads/wip/bob/thing)" "the mirror is fetched (and recorded)"
  # The user's own commit on that name: it differs from the record and the remote.
  git branch -q -f wip/bob/thing "$LG_A_TIP"
  lg inflight --fetch
  assert_eq "0" "$LG_RC" "exit 0"
  assert_eq "$LG_A_TIP" "$(git rev-parse -q --verify refs/heads/wip/bob/thing)" "the differing branch is left alone"
  assert_contains "$LG_ERR" "refs/heads/wip/bob/thing" "the note names it"
  assert_contains "$LG_ERR" "if it is your branch, rename it out of refs/heads/wip/ (\`git branch -m\`); else delete it and the next fetch recreates the mirror" \
    "…with the branch-safe remedy"
  assert_not_contains "$LG_ERR" "update-ref -d" "…never update-ref -d"
  lg_ifl_teardown
  # Outside refs/heads/: the update-ref remedy stays.
  lg_ifl_fixture
  lg inflight --fetch
  git update-ref refs/doc-superpowers/inflight/hostb/feat-a "$LG_A_TIP"
  lg inflight --fetch
  assert_contains "$LG_ERR" "(\`git update-ref -d <ref>\` lets the next fetch recreate it)" "default prefix: the update-ref remedy"
  assert_not_contains "$LG_ERR" "git branch -m" "…not the branch remedy"
  lg_ifl_teardown
}

# --- Task 12: notices, acks, gate, push, prune ----------------------------------------

LG_NTC_CFG='{"base":"origin/main","inflight":{"enabled":true,"host_id":"hosta"}}'

# lg_ntc_fixture [config]: the notices corpus — a bare remote (LG_REMOTE),
# base origin/main, the relations registry (field:order.total in
# src/order/*.js, endpoint:create in server/create.js, component:Sheet in
# src/sheet/**). Items: app-1 a.md consumes field:order.total; app-2 b.md;
# app-3 c.md and app-4 d.md change component:Sheet (siblings); core-1 e.md
# consumes endpoint:create; core-2 f.md; core-3 g.md relates
# sibling:app-3. Files shared.txt, mine.txt, "sp ace/ü.txt". Checked out:
# the branch "mine" (B) at main.
lg_ntc_fixture() {
  local c="$LG_NTC_CFG"
  if [ $# -gt 0 ]; then c=$1; fi
  lg_fixture
  lg_enable "$c"
  lg_registry "$LG_REG_REL"
  lg_item docs/issues/a.md "key: app-1" "ledger: app" "status: Open" "severity: P1" "summary: Consumes the order total" "consumes: [field:order.total]"
  lg_item docs/issues/b.md "key: app-2" "ledger: app" "status: Open" "severity: P2" "summary: Wanted on two branches"
  lg_item docs/issues/c.md "key: app-3" "ledger: app" "status: Open" "severity: P2" "summary: Changes the sheet" "changes: [component:Sheet]"
  lg_item docs/issues/d.md "key: app-4" "ledger: app" "status: Open" "severity: P2" "summary: Also changes the sheet" "changes: [component:Sheet]"
  lg_item docs/issues/e.md "key: core-1" "ledger: core" "status: Open" "severity: P2" "summary: Consumes the create endpoint" "consumes: [endpoint:create]"
  lg_item docs/issues/f.md "key: core-2" "ledger: core" "status: Open" "severity: P3" "summary: Unrelated work"
  lg_item docs/issues/g.md "key: core-3" "ledger: core" "status: Open" "severity: P3" "summary: A sibling of the sheet work" "relates: [sibling:app-3]"
  mkdir -p src/order server src/sheet "sp ace"
  echo total > src/order/total.js
  echo create > server/create.js
  echo sheet > src/sheet/s.js
  printf 'one\n' > shared.txt
  printf 'mine\n' > mine.txt
  printf 'u\n' > "sp ace/ü.txt"
  git add -A && git commit -qm items
  LG_REMOTE=$(harness_mktemp_d remote).git
  git init -q --bare "$LG_REMOTE"
  git --git-dir="$LG_REMOTE" symbolic-ref HEAD refs/heads/main
  git remote add origin "$LG_REMOTE"
  git push -q origin main
  git fetch -q origin
  git checkout -q -b mine
}

# lg_ntc_branch <name> <message> [<file> <text>]…: a local branch <name>
# cut from main, one commit (<message>, a second paragraph with trailers
# allowed via $'…') appending each <text> to each <file>; back on "mine".
lg_ntc_branch() {
  local name="$1" msg="$2"
  shift 2
  git checkout -q -b "$name" main
  while [ $# -ge 2 ]; do
    mkdir -p "$(dirname "$1")"
    printf '%s\n' "$2" >> "$1"
    shift 2
  done
  git add -A
  git commit -q --allow-empty -m "$msg"
  git checkout -q mine
}

# lg_ntc_id <other> <overlap> <oid>: the notice id — the first 12 hex of
# sha256(<other> NUL <overlap> NUL <oid>).
lg_ntc_id() {
  local h
  if command -v sha256sum >/dev/null 2>&1; then h=$(printf '%s\0%s\0%s' "$1" "$2" "$3" | sha256sum)
  else h=$(printf '%s\0%s\0%s' "$1" "$2" "$3" | shasum -a 256); fi
  printf '%s' "${h:0:12}"
}

# lg_ntc_state [<rev>:<path> | <commit>]…: a base notice's head component —
# sha256 of the overlap's state, its sorted lines "F\t<path>\t<blob at
# rev>" and "C\t<commit>" (each newline-ended).
lg_ntc_state() {
  local a h
  for a in "$@"; do
    case "$a" in
      *:*) printf 'F\t%s\t%s\n' "${a#*:}" "$(git rev-parse "$a")" ;;
      *) printf 'C\t%s\n' "$a" ;;
    esac
  done | LC_ALL=C sort > "$TEST_DIR/.state"
  if command -v sha256sum >/dev/null 2>&1; then h=$(sha256sum < "$TEST_DIR/.state"); else h=$(shasum -a 256 < "$TEST_DIR/.state"); fi
  rm -f "$TEST_DIR/.state"
  printf '%s' "${h%% *}"
}

test_lg_notice_contract_change_stop() {
  echo "test: ledger notices — stop when another branch changes a contract B's claimed items consume (defined_in) or that B also changes (Contract-Change); text, JSON and the id formula"
  lg_ntc_fixture
  local x1 x2 id1 id2
  git commit -q --allow-empty -m "mine" -m $'Ledger-Claims: app-1\nContract-Change: endpoint:create — renames a param'
  lg_ntc_branch x-total "touch the total" src/order/total.js more
  x1=$(git rev-parse x-total)
  x2=$(git commit-tree -p main -m "cc" -m "Contract-Change: endpoint:create — adds a field" "main^{tree}")
  git push -q origin "$x2:refs/doc-superpowers/inflight/hostb/x-cc"
  lg_ntc_branch x-sheet "sheet work" src/sheet/s.js more
  id1=$(lg_ntc_id "x-cc@hostb" "contracts:endpoint:create" "$x2")
  id2=$(lg_ntc_id "x-total@hosta" "contracts:field:order.total" "$x1")
  lg notices
  assert_eq "0" "$LG_RC" "exit 0"
  assert_eq "stop $id1 x-cc@hostb no PR contracts:endpoint:create — endpoint:create: adds a field → reconcile-before-next-chunk
stop $id2 x-total no PR contracts:field:order.total — field:order.total: 1 file, +1 -0 → reconcile-before-next-chunk" "$LG_OUT" \
    "two stops: another host's Contract-Change on a contract B changes; a defined_in change B's claimed app-1 consumes — x-sheet changes nothing B needs"
  lg notices --format json
  assert_eq "0|1" "$LG_RC|$(json_count "$LG_OUT")" "json: exit 0, one object"
  assert_json_field "$LG_OUT" '[.verb, .exit, (.notices | length)] | join(",")' "ledger notices,0,2" "json: verb, exit, two notices"
  assert_json_field "$LG_OUT" '.notices[1] | keys | join(",")' "action,id,other,overlap,urgency,what_changed" "json: the §H.2 shape"
  assert_json_field "$LG_OUT" '.notices[1] | [.id, .urgency, .other.branch, .other.host, (.other.pr | tostring), (.overlap.contracts | join(",")), .what_changed, .action] | join("|")' \
    "$id2|stop|x-total|hosta|null|field:order.total|field:order.total: 1 file, +1 -0|reconcile-before-next-chunk" "json: the x-total notice"
  assert_json_field "$LG_OUT" '.notices[0] | [.other.branch, .other.host, .what_changed] | join("|")' "x-cc|hostb|endpoint:create: adds a field" \
    "json: another host's branch"
  assert_json_field "$LG_OUT" '.pr_data.state' "unconfigured" "json: pr_data"
  lg notices --branch x-sheet
  assert_eq "0|" "$LG_RC|$LG_OUT" "--branch x-sheet: nothing it claims or changes overlaps"
  lg notices --branch nope
  assert_eq "2" "$LG_RC" "--branch naming no branch: exit 2"
  assert_contains "$LG_ERR" "nope" "…naming it"
  lg notices extra
  assert_eq "3" "$LG_RC" "an argument: exit 3"
  teardown
}

test_lg_notice_double_claim_stop() {
  echo "test: ledger notices — stop when two branches claim one item (trailer or item file); the shared item file is no extra heads-up"
  lg_ntc_fixture
  local y z
  printf '\nmine\n' >> docs/issues/b.md
  git add -A && git commit -qm "work on app-2"
  lg_ntc_branch y-claim $'claim it\n\nLedger-Claims: app-2'
  lg_ntc_branch z-edit "edit it" docs/issues/b.md $'\nz'
  lg_ntc_branch q-other $'other\n\nLedger-Claims: core-2'
  y=$(git rev-parse y-claim)
  z=$(git rev-parse z-edit)
  lg notices
  assert_eq "0" "$LG_RC" "exit 0"
  assert_eq "stop $(lg_ntc_id y-claim@hosta keys:app-2 "$y") y-claim no PR keys:app-2 — 0 files → reconcile-before-next-chunk
stop $(lg_ntc_id z-edit@hosta keys:app-2 "$z") z-edit no PR keys:app-2 — 1 file, +2 -0 → reconcile-before-next-chunk" "$LG_OUT" \
    "app-2 claimed by a trailer and by an item-file edit: two stops; q-other claims another item"
  assert_not_contains "$LG_OUT" "heads-up" "the doubly-claimed item file is not a heads-up too"
  lg notices --format json
  assert_json_field "$LG_OUT" '[.notices[] | .overlap.keys | join(",")] | join(" ")' "app-2 app-2" "json: overlap.keys"
  teardown
}

test_lg_notice_file_overlap_headsup() {
  echo "test: ledger notices — heads-up when another branch changes files B changes (net diff; a space and unicode in a path)"
  lg_ntc_fixture
  local w
  printf 'b\n' >> shared.txt
  printf 'b\n' >> mine.txt
  printf 'b\n' >> "sp ace/ü.txt"
  git add -A && git commit -qm "mine"
  lg_ntc_branch w-shared "shared work" shared.txt $'w1\nw2' "sp ace/ü.txt" w other.txt new
  lg_ntc_branch w-other "elsewhere" other2.txt new
  w=$(git rev-parse w-shared)
  lg notices
  assert_eq "0" "$LG_RC" "exit 0"
  assert_eq "heads-up $(lg_ntc_id w-shared@hosta "files:shared.txt,sp ace/ü.txt" "$w") w-shared no PR files:shared.txt,sp ace/ü.txt — 2 files, +3 -0 → rebase-after-merge" "$LG_OUT" \
    "one heads-up: the shared files and their diffstat; w-other shares none"
  lg notices --format json
  assert_json_field "$LG_OUT" '.notices[0] | [.urgency, (.overlap.files | join(",")), .what_changed, .action] | join("|")' \
    "heads-up|shared.txt,sp ace/ü.txt|2 files, +3 -0|rebase-after-merge" "json: overlap.files"
  lg notices --gate
  assert_eq "0" "$LG_RC" "--gate: a heads-up alone passes"
  teardown
}

test_lg_notice_base_changed_contract() {
  echo "test: ledger notices — stop when the base since B's merge-base changes a contract B consumes or changes (defined_in, Contract-Change); none once the base is merged into B (R1)"
  lg_ntc_fixture
  local base
  git commit -q --allow-empty -m "mine" -m $'Ledger-Claims: app-1\nContract-Change: endpoint:create — renames a param'
  git checkout -q main
  printf 'trunk\n' >> src/order/total.js
  git add -A && git commit -qm "trunk touches the total"
  git commit -q --allow-empty -m "trunk endpoint" -m "Contract-Change: endpoint:create — adds a field"
  git commit -q --allow-empty -m "trunk sheet" -m "Contract-Change: component:Sheet — new prop"
  git push -q origin main
  git fetch -q origin
  git checkout -q mine
  base=$(lg_ntc_state "$(git rev-parse origin/main):src/order/total.js" "$(git rev-parse origin/main~1)")
  lg notices
  assert_eq "0" "$LG_RC" "exit 0"
  assert_eq "stop $(lg_ntc_id origin/main "contracts:endpoint:create,field:order.total" "$base") origin/main no PR contracts:endpoint:create,field:order.total — endpoint:create: adds a field; field:order.total: 1 file, +1 -0 → reconcile-before-next-chunk" "$LG_OUT" \
    "the base: a Contract-Change on a contract B changes, a defined_in change on one it consumes — never component:Sheet"
  lg notices --format json
  assert_json_field "$LG_OUT" '.notices[0].other | [.branch, (.host | tostring), (.pr | tostring)] | join("|")' "origin/main|null|null" \
    "json: the base as other (no host, no PR)"
  git merge -q --no-ff origin/main -m "merge trunk"
  lg notices
  assert_eq "0|" "$LG_RC|$LG_OUT" "the base merged into B: nothing since its merge-base"
  teardown
}

test_lg_notice_sibling_info() {
  echo "test: ledger notices — info when siblings of B's claims (a shared contract side, relates sibling) are claimed elsewhere"
  lg_ntc_fixture
  local s t
  git commit -q --allow-empty -m "mine" -m "Ledger-Claims: app-3"
  lg_ntc_branch s-sib $'sheet too\n\nLedger-Claims: app-4'
  lg_ntc_branch t-rel $'related\n\nLedger-Claims: core-3'
  lg_ntc_branch u-none $'unrelated\n\nLedger-Claims: core-2'
  s=$(git rev-parse s-sib)
  t=$(git rev-parse t-rel)
  lg notices
  assert_eq "0" "$LG_RC" "exit 0"
  assert_eq "info $(lg_ntc_id s-sib@hosta keys:app-4 "$s") s-sib no PR keys:app-4 — 0 files → heads-up
info $(lg_ntc_id t-rel@hosta keys:core-3 "$t") t-rel no PR keys:core-3 — 0 files → heads-up" "$LG_OUT" \
    "app-4 (component:Sheet, both change it) and core-3 (relates sibling:app-3) claimed elsewhere; core-2 is no sibling"
  lg notices --gate
  assert_eq "0" "$LG_RC" "--gate: info alone passes"
  teardown
}

test_lg_notice_ack_hides_and_moved_head_refires() {
  echo "test: a Ledger-Ack: <id> trailer on B hides that notice (case-sensitive name, optional clause); an ack of an id that does not fire is silent; a moved other head re-fires with a new id (R3)"
  lg_ntc_fixture
  local id1 id2 x1 x2
  git commit -q --allow-empty -m "mine" -m "Ledger-Claims: app-1"
  lg_ntc_branch x-total "touch the total" src/order/total.js more
  x1=$(git rev-parse x-total)
  id1=$(lg_ntc_id x-total@hosta contracts:field:order.total "$x1")
  lg notices
  assert_contains "$LG_OUT" "stop $id1 x-total" "the stop fires"
  git commit -q --allow-empty -m "lowercase" -m "ledger-ack: $id1"
  lg notices
  assert_contains "$LG_OUT" "stop $id1 x-total" "a lower-case ledger-ack is no ack (trailer names are case-sensitive)"
  git commit -q --allow-empty -m "ack" -m "* Ledger-Ack: $id1 — reconciled with x-total"
  lg notices
  assert_eq "0|" "$LG_RC|$LG_OUT" "acked (a bullet line with a clause): hidden"
  lg notices --format json
  assert_json_field "$LG_OUT" '.notices | length' "0" "json: no notices"
  git commit -q --allow-empty -m "stray ack" -m "Ledger-Ack: 0123456789ab"
  lg notices
  assert_eq "0||" "$LG_RC|$LG_OUT|$(printf '%s\n' "$LG_ERR" | grep '0123456789ab' || true)" "an ack of an id that does not fire: harmless and silent"
  git checkout -q x-total
  printf 'again\n' >> other.txt
  git add -A && git commit -qm "x-total moves"
  git checkout -q mine
  x2=$(git rev-parse x-total)
  id2=$(lg_ntc_id x-total@hosta contracts:field:order.total "$x2")
  lg notices
  assert_eq "stop $id2 x-total no PR contracts:field:order.total — field:order.total: 1 file, +1 -0 → reconcile-before-next-chunk" "$LG_OUT" \
    "the other head moved: a new id, the notice fires again"
  assert_eq "1" "$(if [ "$id1" != "$id2" ]; then echo 1; else echo 0; fi)" "…the id changed"
  teardown
}

test_lg_notices_gate_rc() {
  echo "test: ledger notices --gate — 1 on an unacked stop, 0 otherwise, 2 when it cannot run; offline: cached refs and facts, said in the note, never fetched (R4)"
  lg_ntc_fixture
  local x id tr
  git commit -q --allow-empty -m "mine" -m "Ledger-Claims: app-1"
  lg_ntc_branch x-total "touch the total" src/order/total.js more
  x=$(git rev-parse x-total)
  id=$(lg_ntc_id x-total@hosta contracts:field:order.total "$x")
  lg notices --gate
  assert_eq "1" "$LG_RC" "an unacked stop: exit 1"
  assert_contains "$LG_OUT" "stop $id x-total" "…listing it"
  lg notices --gate --format json
  assert_eq "1|1" "$LG_RC|$(json_count "$LG_OUT")" "json: exit 1, one object"
  assert_json_field "$LG_OUT" '[.exit, (.notices | length)] | map(tostring) | join(",")' "1,1" "json: .exit 1, the notice"
  tr=$(harness_mktemp lg-gtrace)
  GIT_TRACE="$tr" DOC_TOOLS_LEDGER_OFFLINE=1 lg notices --gate
  assert_eq "1" "$LG_RC" "offline: the cached refs and facts still gate"
  assert_contains "$LG_ERR" "ledger: " "offline: one note…"
  assert_contains "$LG_ERR" "offline" "…saying so"
  assert_eq "1" "$(printf '%s\n' "$LG_ERR" | grep -c '^ledger: ')" "…exactly one ledger: line"
  assert_eq "" "$(grep -E ' fetch ' "$tr" || true)" "offline: no git fetch"
  DOC_TOOLS_LEDGER_OFFLINE=1 lg notices --gate --fetch
  assert_eq "2" "$LG_RC" "offline --fetch: exit 2"
  git commit -q --allow-empty -m "ack" -m "Ledger-Ack: $id — checked"
  lg notices --gate
  assert_eq "0|" "$LG_RC|$LG_OUT" "acked: exit 0"
  lg notices --gate --branch nope
  assert_eq "2" "$LG_RC" "a branch that is not here: exit 2"
  lg_enable '{"base":"origin/nope","inflight":{"enabled":true,"host_id":"hosta"}}'
  lg notices --gate
  assert_eq "2" "$LG_RC" "a base that does not resolve: exit 2 (never a clean gate)"
  assert_contains "$LG_ERR" "origin/nope" "…naming it"
  lg_enable '{"base":"origin/main"}'
  lg notices --gate
  assert_eq "0" "$LG_RC" "in-flight awareness off: exit 0"
  assert_contains "$LG_OUT" "in-flight awareness is off" "…saying so"
  git checkout -q main
  lg_enable "$LG_NTC_CFG"
  lg notices --gate
  assert_eq "0|" "$LG_RC|$LG_OUT" "the current branch is the base's branch: nothing in flight, exit 0"
  rm -f "$tr"
  teardown
}

test_lg_inflight_push_and_pre_push_check() {
  echo "test: ledger inflight --push — pre_push_check gets exactly one stdin line <merge-base>..<tip> (non-zero: abort, rc 1, its output); then a forced, --no-verify push to <ref_prefix>/<host>/<branch> (R5)"
  lg_ntc_fixture '{"base":"origin/main","inflight":{"enabled":true,"host_id":"hosta","pre_push_check":"sh .git/ppc.sh"}}'
  local tip mb ref="refs/doc-superpowers/inflight/hosta/mine" before
  # shellcheck disable=SC2016  # the check's own $PPC_RC
  printf 'cat > .git/ppc.in\nif [ "${PPC_RC:-0}" != 0 ]; then echo "secret found in $(cat .git/ppc.in)"; fi\nexit "${PPC_RC:-0}"\n' > .git/ppc.sh
  git commit -q --allow-empty -m "mine 1" -m "Ledger-Claims: app-1"
  git commit -q --allow-empty -m "mine 2"
  tip=$(git rev-parse HEAD)
  mb=$(git merge-base origin/main HEAD)
  lg inflight --push
  assert_eq "0" "$LG_RC" "exit 0"
  assert_eq "$tip" "$(git --git-dir="$LG_REMOTE" rev-parse -q --verify "$ref")" "pushed to <prefix>/<host>/<branch>"
  assert_eq "$mb..$tip" "$(cat .git/ppc.in)" "the check's stdin: <merge-base>..<tip>"
  assert_eq "1" "$(wc -l < .git/ppc.in | tr -d ' ')" "…exactly one line"
  assert_contains "$LG_OUT" "pushed $(git rev-parse --short HEAD) to origin $ref" "says so"
  # A rewritten branch (amend): --force; a failing pre-push hook: --no-verify.
  printf '#!/bin/sh\nexit 1\n' > .git/hooks/pre-push
  chmod +x .git/hooks/pre-push
  git commit -q --amend --allow-empty -m "mine 2, amended"
  lg inflight --push --format json
  assert_eq "0" "$LG_RC" "amended, a failing pre-push hook: exit 0"
  assert_eq "$(git rev-parse HEAD)" "$(git --git-dir="$LG_REMOTE" rev-parse -q --verify "$ref")" "…force-pushed, no hook run"
  assert_json_field "$LG_OUT" '[.pushed, .ref, .oid, .base_oid] | map(tostring) | join(" ")' "true $ref $(git rev-parse HEAD) $mb" "json: pushed, ref, oid, base_oid"
  before=$(git --git-dir="$LG_REMOTE" rev-parse -q --verify "$ref" || true)
  git commit -q --allow-empty -m "mine 3"
  PPC_RC=3 lg inflight --push
  assert_eq "1" "$LG_RC" "the check fails: exit 1"
  assert_contains "$LG_OUT" "secret found in $mb..$(git rev-parse HEAD)" "…its output shown"
  assert_contains "$LG_OUT$LG_ERR" "pre_push_check" "…naming the check"
  assert_eq "$before" "$(git --git-dir="$LG_REMOTE" rev-parse -q --verify "$ref")" "…nothing pushed"
  # Nothing to push: detached HEAD; a branch with no commits beyond the base.
  git checkout -q --detach HEAD
  lg inflight --push
  assert_eq "0" "$LG_RC" "detached HEAD: exit 0"
  assert_contains "$LG_OUT" "detached HEAD" "…an informational line"
  git checkout -q -b fresh origin/main
  lg inflight --push
  assert_eq "0" "$LG_RC" "no commits beyond the base: exit 0"
  assert_contains "$LG_OUT" "no commits beyond the base" "…an informational line"
  assert_eq "" "$(git --git-dir="$LG_REMOTE" for-each-ref refs/doc-superpowers/inflight/hosta/fresh)" "…nothing pushed"
  # A unicode, dash-led branch name travels whole.
  git checkout -q -b "feat/-ü" origin/main
  git commit -q --allow-empty -m "u"
  lg inflight --push
  assert_eq "$(git rev-parse HEAD)" "$(git --git-dir="$LG_REMOTE" rev-parse -q --verify "refs/doc-superpowers/inflight/hosta/feat/-ü")" "feat/-ü pushed"
  # The pushed name is checked with git check-ref-format.
  lg_call _lg_ifl_push_refname hosta "bad..name"
  assert_eq "2" "$LG_RC" "a ref name git refuses: exit 2"
  assert_contains "$LG_OUT$LG_ERR" "check-ref-format" "…saying why"
  teardown
}

test_lg_inflight_push_offline_warns() {
  echo "test: ledger inflight --push offline or with the remote unreachable — a warning, exit 0, nothing pushed; a remote that rejects it — exit 2 (R5)"
  lg_ntc_fixture
  local before
  git commit -q --allow-empty -m "mine"
  before=$(git --git-dir="$LG_REMOTE" for-each-ref)
  DOC_TOOLS_LEDGER_OFFLINE=1 lg inflight --push --format json
  assert_eq "0|1" "$LG_RC|$(json_count "$LG_OUT")" "offline: exit 0, one object"
  assert_contains "$LG_ERR" "offline" "…a warning"
  assert_eq "$before" "$(git --git-dir="$LG_REMOTE" for-each-ref)" "…nothing pushed"
  git remote set-url origin "$TEST_DIR/no such remote.git"
  lg inflight --push
  assert_eq "0" "$LG_RC" "the remote unreachable: exit 0"
  assert_contains "$LG_ERR" "nothing pushed" "…a warning"
  lg inflight --push --format json
  assert_json_field "$LG_OUT" '[.exit, .pushed] | map(tostring) | join(",")' "0,false" "json: exit 0, pushed false"
  git remote set-url origin "$LG_REMOTE"
  printf '#!/bin/sh\necho "denied by policy" >&2\nexit 1\n' > "$LG_REMOTE/hooks/pre-receive"
  chmod +x "$LG_REMOTE/hooks/pre-receive"
  lg inflight --push
  assert_eq "2" "$LG_RC" "the remote rejects it: exit 2"
  assert_contains "$LG_ERR" "rejected" "…with git's words"
  teardown
}

test_lg_publish_prunes_inflight() {
  echo "test: publish prunes in-flight refs on the remote whose tips are on the base or older than max_age_days — one push, never offline; a prune failure is a note, not a failed publish (R6)"
  lg_ntc_fixture
  local fresh old tr views p="refs/doc-superpowers/inflight/hostb"
  fresh=$(git commit-tree -p main -m "fresh" "main^{tree}")
  old=$(GIT_COMMITTER_DATE="2020-01-01T12:00:00" git commit-tree -p main -m "old" "main^{tree}")
  git push -q origin "main:$p/merged" "$old:$p/old" "$fresh:$p/fresh"
  tr=$(harness_mktemp lg-gtrace)
  GIT_TRACE="$tr" lg publish
  assert_eq "0" "$LG_RC" "publish: exit 0"
  assert_eq "||$fresh" "$(lg_ifl_remote_ref hostb/merged)|$(lg_ifl_remote_ref hostb/old)|$(lg_ifl_remote_ref hostb/fresh)" \
    "the merged and the old refs pruned on the remote; the fresh one kept"
  assert_eq "1" "$(grep -c 'git.*push.*--delete' "$tr")" "…in one push"
  assert_contains "$LG_OUT" "pruned 2 in-flight ref(s)" "…said"
  assert_eq "1" "$(git --git-dir="$LG_REMOTE" for-each-ref refs/heads/doc-ledger-views | wc -l | tr -d ' ')" "the views were published"
  # JSON: the pruned refs.
  git push -q origin "main:$p/merged2"
  lg publish --format json
  assert_json_field "$LG_OUT" '.inflight_pruned | join(",")' "$p/merged2" "json: inflight_pruned"
  # A prune the remote refuses: a note; the publish whose views were pushed stands.
  git push -q origin "main:$p/merged3"
  printf '#!/bin/sh\nwhile read o n r; do case "$n:$r" in 0000000000000000000000000000000000000000:refs/doc-superpowers/inflight/*) echo "no deletes here" >&2; exit 1 ;; esac; done\nexit 0\n' \
    > "$LG_REMOTE/hooks/pre-receive"
  chmod +x "$LG_REMOTE/hooks/pre-receive"
  views=$(git --git-dir="$LG_REMOTE" rev-parse refs/heads/doc-ledger-views)
  lg publish
  assert_eq "0" "$LG_RC" "a refused prune: publish exit 0"
  assert_eq "$views" "$(git --git-dir="$LG_REMOTE" rev-parse refs/heads/doc-ledger-views^)" "…the views pushed (one new commit)"
  assert_eq "1" "$(printf '%s\n' "$LG_ERR" | grep -c '^ledger: ')" "…one ledger: note"
  assert_contains "$(printf '%s\n' "$LG_ERR" | grep '^ledger: ')" "not pruned" "…naming the prune failure"
  assert_contains "$(printf '%s\n' "$LG_ERR" | grep '^ledger: ')" "$p/merged3" "…and the ref"
  assert_eq "$(git rev-parse main)" "$(lg_ifl_remote_ref hostb/merged3)" "…the ref still there"
  rm -f "$LG_REMOTE/hooks/pre-receive"
  # Offline: never pruned.
  DOC_TOOLS_LEDGER_OFFLINE=1 lg publish
  assert_eq "$(git rev-parse main)" "$(lg_ifl_remote_ref hostb/merged3)" "offline: nothing pruned"
  rm -f "$tr"
  teardown
  # Under refs/heads/<seg>: only refs shaped <prefix>/<host>/<name>.
  lg_ntc_fixture '{"base":"origin/main","inflight":{"enabled":true,"host_id":"hosta","ref_prefix":"refs/heads/wip"}}'
  git push -q origin "main:refs/heads/wip/hostb/merged" "main:refs/heads/wip/loose"
  lg publish
  assert_eq "0" "$LG_RC" "refs/heads/wip: exit 0"
  assert_eq "" "$(git --git-dir="$LG_REMOTE" for-each-ref refs/heads/wip/hostb/)" "the shaped merged ref pruned"
  assert_eq "$(git rev-parse main)" "$(git --git-dir="$LG_REMOTE" rev-parse -q --verify refs/heads/wip/loose)" "an unshaped one is never touched"
  teardown
}

# --- Task 12 fix round 1 ------------------------------------------------------------

test_lg_notice_same_branch_other_host() {
  echo "test: the same branch on another host — an ancestor copy (or any branch behind B) raises nothing; a copy ahead of B is one info, never a stop (I1)"
  lg_ntc_fixture
  local b ahead div
  git commit -q --allow-empty -m "mine 1" -m "Ledger-Claims: app-1"
  printf 'b\n' >> shared.txt
  git add -A && git commit -qm "mine 2"
  b=$(git rev-parse HEAD)
  git branch -q older HEAD~1
  ahead=$(git commit-tree -p "$b" -m "more on hostc" "$b^{tree}")
  git push -q origin "$b~1:refs/doc-superpowers/inflight/hostb/mine" "$ahead:refs/doc-superpowers/inflight/hostc/mine"
  lg notices
  assert_eq "0" "$LG_RC" "exit 0"
  assert_eq "info $(lg_ntc_id mine@hostc keys:app-1 "$ahead") mine@hostc no PR keys:app-1 — mine@hostc is ahead of this branch → heads-up" "$LG_OUT" \
    "hostb's copy and the local 'older' are behind B: nothing; hostc's copy is ahead: one info"
  lg notices --gate
  assert_eq "0" "$LG_RC" "--gate: exit 0 (no false stop against itself)"
  lg notices --format json
  assert_json_field "$LG_OUT" '.notices | map([.urgency, .other.branch, .other.host, (.overlap.keys | join(",")), .what_changed, .action] | join("|")) | join(";")' \
    "info|mine|hostc|app-1|mine@hostc is ahead of this branch|heads-up" "json: the one info"
  # A copy that diverged from B (neither behind nor ahead) is real work
  # elsewhere: its claim of app-1 is still a stop.
  div=$(git commit-tree -p "$b~1" -m "diverged on hostd" "$b~1^{tree}")
  git push -q origin "$div:refs/doc-superpowers/inflight/hostd/mine"
  lg notices --fetch
  assert_eq "stop $(lg_ntc_id mine@hostd keys:app-1 "$div") mine@hostd no PR keys:app-1 — 0 files → reconcile-before-next-chunk
info $(lg_ntc_id mine@hostc keys:app-1 "$ahead") mine@hostc no PR keys:app-1 — mine@hostc is ahead of this branch → heads-up" "$LG_OUT" \
    "a diverged copy on another host: still a stop"
  teardown
}

test_lg_notice_base_id_overlap_state() {
  echo "test: a base notice's id follows the overlap's state (contract files' blobs, Contract-Change commits) — an unrelated base commit keeps it acked; a new defined_in change or Contract-Change re-fires (C1)"
  lg_ntc_fixture
  local id id2 id3
  git commit -q --allow-empty -m "mine" -m "Ledger-Claims: app-1"
  git checkout -q main
  printf 'trunk\n' >> src/order/total.js
  git add -A && git commit -qm "trunk touches the total" && git push -q origin main
  git checkout -q mine
  git fetch -q origin
  id=$(lg_ntc_id origin/main contracts:field:order.total "$(lg_ntc_state origin/main:src/order/total.js)")
  lg notices
  assert_contains "$LG_OUT" "stop $id origin/main" "the base's stop: id from the overlap's state"
  git commit -q --allow-empty -m "ack" -m "Ledger-Ack: $id — reconciled"
  lg notices
  assert_eq "0|" "$LG_RC|$LG_OUT" "acked"
  git checkout -q main
  printf 'more\n' >> shared.txt
  git add -A && git commit -qm "unrelated trunk work" && git push -q origin main
  git checkout -q mine
  git fetch -q origin
  lg notices
  assert_eq "0|" "$LG_RC|$LG_OUT" "an unrelated base commit: the base moved, the id did not — still acked"
  git checkout -q main
  printf 'again\n' >> src/order/total.js
  git add -A && git commit -qm "trunk touches the total again" && git push -q origin main
  git checkout -q mine
  git fetch -q origin
  id2=$(lg_ntc_id origin/main contracts:field:order.total "$(lg_ntc_state origin/main:src/order/total.js)")
  lg notices
  assert_contains "$LG_OUT" "stop $id2 origin/main" "a new defined_in change: re-fires with a new id"
  git commit -q --allow-empty -m "ack 2" -m "Ledger-Ack: $id2"
  git checkout -q main
  git commit -q --allow-empty -m "trunk cc" -m "Contract-Change: field:order.total — renames total"
  git push -q origin main
  git checkout -q mine
  git fetch -q origin
  id3=$(lg_ntc_id origin/main contracts:field:order.total "$(lg_ntc_state origin/main:src/order/total.js "$(git rev-parse origin/main)")")
  lg notices
  assert_contains "$LG_OUT" "stop $id3 origin/main" "a new Contract-Change: re-fires"
  assert_contains "$LG_OUT" "field:order.total: renames total" "…with its line"
  teardown
}

test_lg_notice_id_shared_across_hosts() {
  echo "test: a notice's id hashes a canonical name (<name>@<host> unless the branch is on the remote) — the same notice on two hosts has one id, so one ack hides it on both (m3)"
  lg_ntc_fixture
  local id_a id_b clone here
  git commit -q --allow-empty -m "mine" -m "Ledger-Claims: app-1"
  git push -q origin mine
  lg_ntc_branch x-total "touch the total" src/order/total.js more
  git checkout -q x-total
  lg inflight --push
  git checkout -q mine
  git fetch -q origin
  lg notices --format json
  id_a=$(jq -r '.notices[] | select(.other.branch == "x-total") | .id' <<<"$LG_OUT")
  assert_eq "$(lg_ntc_id x-total@hosta contracts:field:order.total "$(git rev-parse x-total)")" "$id_a" "host A: hashed as x-total@hosta"
  clone="$(harness_mktemp_d lg-b)/clone"
  lg_clone "$clone"
  ( cd "$clone" && lg_enable '{"base":"origin/main","inflight":{"enabled":true,"host_id":"hostb"}}' )
  here=$PWD
  cd "$clone"
  lg notices --branch mine --format json
  id_b=$(jq -r '.notices[] | select(.other.branch == "x-total") | .id' <<<"$LG_OUT")
  assert_eq "$id_a" "$id_b" "host B (mine from the remote, x-total@hosta in flight): the same id"
  lg notices --branch mine
  assert_contains "$LG_OUT" "stop $id_b x-total@hosta no PR" "…displayed as x-total@hosta there"
  cd "$here"
  lg notices
  assert_contains "$LG_OUT" "stop $id_a x-total no PR" "…and as x-total here (the display is unchanged)"
  git commit -q --allow-empty -m "ack" -m "Ledger-Ack: $id_a — checked with x-total"
  git push -q origin mine
  cd "$clone"
  git fetch -q origin
  lg notices --branch mine
  assert_not_contains "$LG_OUT" "x-total" "the ack made on host A hides the notice on host B"
  cd "$here"
  rm -rf "$(dirname "$clone")"
  teardown
}

test_lg_notice_branch_not_current_note() {
  echo "test: --branch X other than the current branch — its claimed items are read from this working tree, and the note says so (m4)"
  lg_ntc_fixture
  git commit -q --allow-empty -m "mine" -m "Ledger-Claims: app-1"
  lg_ntc_branch x-total "touch the total" src/order/total.js more
  git checkout -q main
  lg notices --branch mine
  assert_contains "$LG_OUT" "stop " "notices for mine"
  assert_contains "$LG_ERR" "read from this working tree, not from mine's tip" "the note names the limitation"
  assert_eq "1" "$(printf '%s\n' "$LG_ERR" | grep -c '^ledger: ')" "…in the run's one ledger: line"
  lg notices --branch mine --format json
  assert_eq "0|1" "$LG_RC|$(json_count "$LG_OUT")" "json: one object"
  assert_contains "$LG_ERR" "not from mine's tip" "json: the same note"
  git checkout -q mine
  lg notices
  assert_not_contains "$LG_ERR" "working tree, not from" "the current branch: no such note"
  lg notices --branch mine
  assert_not_contains "$LG_ERR" "working tree, not from" "--branch naming the current branch: no such note"
  teardown
}

test_lg_inflight_push_auth_failure() {
  echo "test: ledger inflight --push — an authentication / permission failure is reported as such, exit 0 (m5)"
  lg_ntc_fixture
  git commit -q --allow-empty -m "mine"
  git config protocol.ext.allow always
  git remote set-url origin "ext::sh -c echo% fatal:% Authentication% failed% for% x>&2;% exit% 128"
  lg inflight --push
  assert_eq "0" "$LG_RC" "exit 0 (hooks keep going)"
  assert_contains "$LG_ERR" "authentication or permission failure" "…reported as an authentication failure"
  assert_contains "$LG_ERR" "Authentication failed for x" "…with git's words"
  assert_not_contains "$LG_ERR" "cannot be reached" "…not as unreachable"
  lg inflight --push --format json
  assert_eq "0|1" "$LG_RC|$(json_count "$LG_OUT")" "json: exit 0, one object"
  assert_json_field "$LG_OUT" '[(.pushed | tostring), (.note | startswith("authentication or permission failure on origin"))] | map(tostring) | join(",")' \
    "false,true" "json: pushed false, the note"
  git remote set-url origin "ext::sh -c echo% ERROR:% Permission% denied% to% push>&2;% exit% 128"
  lg inflight --push
  assert_eq "0" "$LG_RC" "Permission denied: exit 0"
  assert_contains "$LG_ERR" "authentication or permission failure" "…an authentication failure"
  git remote set-url origin "ext::sh -c echo% fatal:% The% requested% URL% returned% error:% 403% >&2;% exit% 128"
  lg inflight --push
  assert_contains "$LG_ERR" "authentication or permission failure" "HTTP 403: an authentication failure"
  git remote set-url origin "ext::sh -c echo% fatal:% could% not% read% Username% for% x>&2;% exit% 128"
  lg inflight --push
  assert_contains "$LG_ERR" "authentication or permission failure" "no credentials: an authentication failure"
  git remote set-url origin "ext::sh -c echo% error:% RPC% failed,% HTTP% 403% curl% 22% >&2;% exit% 128"
  lg inflight --push
  assert_contains "$LG_ERR" "authentication or permission failure" "HTTP 403 (curl's RPC line): an authentication failure"
  git remote set-url origin "ext::sh -c echo% fatal:% unable% to% connect% to% host:4030>&2;% exit% 128"
  lg inflight --push
  assert_eq "0" "$LG_RC" "unreachable: exit 0"
  assert_contains "$LG_ERR" "cannot be reached" "a port 4030 is no HTTP 403: unreachable"
  git remote set-url origin "ext::sh -c echo% fatal:% unable% to% access% https://h/team/403/repo.git/:% Could% not% resolve% host:% h>&2;% exit% 128"
  lg inflight --push
  assert_contains "$LG_ERR" "cannot be reached" "a 403 path segment is no HTTP 403: unreachable"
  git remote set-url origin "ext::sh -c echo% fatal:% repository% https://h/org-403/r.git/% not% found>&2;% exit% 128"
  lg inflight --push
  assert_contains "$LG_ERR" "cannot be reached" "a 403 in a repository name is no HTTP 403: unreachable"
  git remote set-url origin "ext::sh -c echo% ssh:% connect% to% host% h% port% 403:% Connection% refused>&2;% exit% 128"
  lg inflight --push
  assert_contains "$LG_ERR" "cannot be reached" "port 403 is no HTTP 403: unreachable"
  assert_eq "" "$(git --git-dir="$LG_REMOTE" for-each-ref refs/doc-superpowers/inflight/)" "nothing pushed"
  git remote set-url origin "$LG_REMOTE"
  teardown
}

test_lg_publish_prune_internal_failure_is_note() {
  echo "test: an internal failure of the prune after the views were pushed — a note, publish exit 0 (m6)"
  lg_ntc_fixture
  local views m
  m=$(git rev-parse main)
  git push -q origin "main:refs/doc-superpowers/inflight/hostb/merged"
  DOC_TOOLS_LEDGER_SELFTEST=ifl-prune-internal lg publish
  assert_eq "0" "$LG_RC" "exit 0"
  views=$(git --git-dir="$LG_REMOTE" rev-parse -q --verify refs/heads/doc-ledger-views || true)
  assert_eq "1" "$(if [ -n "$views" ]; then echo 1; else echo 0; fi)" "the views were pushed"
  assert_eq "1" "$(printf '%s\n' "$LG_ERR" | grep -c '^ledger: ')" "one ledger: note"
  assert_contains "$(printf '%s\n' "$LG_ERR" | grep '^ledger: ')" "in-flight refs not pruned (selftest: an internal failure in the prune)" \
    "…saying the prune did not run, and why"
  assert_not_contains "$LG_ERR" "ERROR" "no error"
  assert_eq "$m" "$(git --git-dir="$LG_REMOTE" rev-parse -q --verify refs/doc-superpowers/inflight/hostb/merged || true)" "the merged ref is still there"
  assert_contains "$LG_OUT" "published" "the publish line"
  assert_not_contains "$LG_OUT" "pruned" "…and no pruned line"
  DOC_TOOLS_LEDGER_SELFTEST=ifl-prune-internal lg publish --format json
  assert_eq "0|1" "$LG_RC|$(json_count "$LG_OUT")" "json: exit 0, one object"
  assert_json_field "$LG_OUT" '[.exit, (.inflight_pruned | length)] | map(tostring) | join(",")' "0,0" "json: exit 0, nothing pruned"
  lg publish
  assert_contains "$LG_OUT" "pruned 1 in-flight ref(s) from origin: refs/doc-superpowers/inflight/hostb/merged" "without the hook: pruned"
  teardown
}

# --- Task 12 fix round 2 ------------------------------------------------------------

test_lg_notice_id_remote_and_inflight_across_hosts() {
  echo "test: a branch on keys.remote and in flight from its host — one notice on every host, hashed <name>, keyed to the newer copy; an ack on one host hides it on the others (m3, round 2)"
  lg_ntc_fixture
  local x id clone here
  git commit -q --allow-empty -m "mine" -m "Ledger-Claims: app-1"
  git push -q origin mine
  lg_ntc_branch x-total "touch the total" src/order/total.js more
  git checkout -q x-total
  git push -q origin x-total
  lg inflight --push
  git checkout -q mine
  x=$(git rev-parse x-total)
  id=$(lg_ntc_id x-total contracts:field:order.total "$x")
  lg notices --fetch
  assert_eq "stop $id x-total no PR contracts:field:order.total — field:order.total: 1 file, +1 -0 → reconcile-before-next-chunk" "$LG_OUT" \
    "host A: one notice, hashed x-total (the branch is on the remote)"
  git commit -q --allow-empty -m "ack" -m "Ledger-Ack: $id — checked"
  git push -q origin mine
  lg notices --gate
  assert_eq "0|" "$LG_RC|$LG_OUT" "host A: acked, gate 0"
  clone="$(harness_mktemp_d lg-b)/clone"
  lg_clone "$clone"
  ( cd "$clone" && lg_enable '{"base":"origin/main","inflight":{"enabled":true,"host_id":"hostb"}}' )
  here=$PWD
  cd "$clone"
  lg notices --branch mine --gate --fetch
  assert_eq "0|" "$LG_RC|$LG_OUT" "host B (x-total from the remote and in flight from hosta, one tip): A's ack hides it, gate 0"
  # The remote copy behind the in-flight one: hosta commits, and its
  # post-commit push moves the in-flight ref alone.
  cd "$here"
  git checkout -q x-total
  printf 'again\n' >> src/order/total.js
  git add -A && git commit -qm "x-total moves"
  lg inflight --push
  git checkout -q mine
  x=$(git rev-parse x-total)
  id=$(lg_ntc_id x-total contracts:field:order.total "$x")
  lg notices --fetch
  assert_eq "stop $id x-total no PR contracts:field:order.total — field:order.total: 1 file, +2 -0 → reconcile-before-next-chunk" "$LG_OUT" \
    "host A: the new tip"
  cd "$clone"
  git fetch -q origin
  lg notices --branch mine --fetch
  assert_eq "stop $id x-total@hosta no PR contracts:field:order.total — field:order.total: 1 file, +2 -0 → reconcile-before-next-chunk" "$LG_OUT" \
    "host B: the stale remote copy collapses into the newer in-flight one — one notice, A's id"
  # The in-flight copy behind the remote one: hosta pushes the branch, not
  # the in-flight ref.
  cd "$here"
  git checkout -q x-total
  printf 'third\n' >> src/order/total.js
  git add -A && git commit -qm "x-total pushed"
  git push -q origin x-total
  git checkout -q mine
  x=$(git rev-parse x-total)
  id=$(lg_ntc_id x-total contracts:field:order.total "$x")
  lg notices --fetch
  assert_eq "stop $id x-total no PR contracts:field:order.total — field:order.total: 1 file, +3 -0 → reconcile-before-next-chunk" "$LG_OUT" \
    "host A: the pushed tip"
  cd "$clone"
  git fetch -q origin
  lg notices --branch mine --fetch
  assert_eq "stop $id x-total no PR contracts:field:order.total — field:order.total: 1 file, +3 -0 → reconcile-before-next-chunk" "$LG_OUT" \
    "host B: the stale in-flight copy collapses into the remote one — one notice, A's id"
  cd "$here"
  git commit -q --allow-empty -m "ack 2" -m "Ledger-Ack: $id — checked again"
  git push -q origin mine
  cd "$clone"
  git fetch -q origin
  lg notices --branch mine --gate
  assert_eq "0|" "$LG_RC|$LG_OUT" "host B: A's second ack hides it, gate 0"
  cd "$here"
  rm -rf "$(dirname "$clone")"
  teardown
}

test_lg_publish_prune_term_prompt() {
  echo "test: a TERM to publish while its prune's push runs — the run ends at once, and the push's remote side does not survive (m6, round 2)"
  lg_ntc_fixture
  local pid i=0 seen=0 t0 t1
  git push -q origin "main:refs/doc-superpowers/inflight/hostb/merged"
  # The remote is slow over in-flight deletes alone (the views push is quick).
  printf '#!/bin/sh\nwhile read o n r; do case "$n:$r" in 0000000000000000000000000000000000000000:refs/doc-superpowers/inflight/*) sleep 9.35 ;; esac; done\nexit 0\n' \
    > "$LG_REMOTE/hooks/pre-receive"
  chmod +x "$LG_REMOTE/hooks/pre-receive"
  "$DOC_TOOLS" ledger publish < /dev/null > /dev/null 2>&1 &
  pid=$!
  while [ "$i" -lt 40 ]; do
    if [ "$(lg_ps_has 'sleep 9.35')" = 1 ]; then seen=1; break; fi
    sleep 0.3
    i=$((i + 1))
  done
  assert_eq "1" "$seen" "the prune's push reached the slow hook"
  t0=$(date +%s)
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  t1=$(date +%s)
  assert_eq "1" "$(if [ $((t1 - t0)) -le 3 ]; then echo 1; else echo 0; fi)" "TERM: the run ends within 3 s (it took $((t1 - t0)) s), not after the push"
  sleep 1
  assert_eq "0" "$(lg_ps_has 'sleep 9.35')" "…and the push's remote side is gone"
  rm -f "$LG_REMOTE/hooks/pre-receive"
  teardown
}

test_lg_inflight_ref_prefix_guard() {
  echo "test: inflight.ref_prefix / pull_refs never point --fetch --prune at local refs (I2)"
  lg_ifl_fixture
  local p
  for p in refs/heads refs/remotes refs/remotes/origin refs/tags refs/notes refs/doc-superpowers/pull refs/doc-superpowers/pull/x \
      refs/doc-superpowers refs/doc-superpowers/ledger refs/doc-superpowers/ledger/counters refs/doc-superpowers/ledger/counters/x; do
    lg_enable "{\"base\":\"origin/main\",\"inflight\":{\"enabled\":true,\"host_id\":\"hosta\",\"ref_prefix\":\"$p\"}}"
    lg inflight --fetch
    assert_eq "2" "$LG_RC" "ref_prefix $p: exit 2"
    assert_contains "$LG_ERR" "inflight.ref_prefix" "…naming the key ($p)"
  done
  lg_enable '{"base":"origin/main","keys":{"counter_ref":"refs/ctr/x"},"inflight":{"enabled":true,"host_id":"hosta","ref_prefix":"refs/ctr"}}'
  lg inflight
  assert_eq "2" "$LG_RC" "a prefix holding keys.counter_ref: exit 2"
  assert_eq "$LG_A_TIP" "$(git rev-parse -q --verify refs/heads/feat-a)" "local branches untouched"
  lg_enable '{"base":"origin/main","inflight":{"enabled":true,"host_id":"hosta","ref_prefix":"refs/x-inflight"}}'
  lg inflight --fetch
  assert_eq "0" "$LG_RC" "another prefix of its own: exit 0"
  lg_ifl_teardown
}

test_lg_inflight_prefix_under_heads() {
  echo "test: ref_prefix strictly under refs/heads/ (a dedicated segment) — in-flight mirrors read as in flight, never as branches; --fetch --prune touches only that namespace (fix round 2)"
  lg_ifl_fixture '{"base":"origin/main","inflight":{"enabled":true,"host_id":"hosta","ref_prefix":"refs/heads/ledger-inflight"}}'
  git branch -q feature/x "$LG_A_TIP"
  ( cd "$LG_B" && git push -q origin "HEAD:refs/heads/ledger-inflight/hostb/feat-a" )
  git fetch -q origin
  lg inflight --fetch
  assert_eq "0" "$LG_RC" "exit 0"
  assert_contains "$LG_OUT" "feat-a inflight@hostb no PR claims:core-1" "hostb's mirror: in flight, from the other host"
  assert_not_contains "$LG_OUT" "ledger-inflight" "the mirrors never appear as local or remote branches"
  assert_contains "$LG_OUT" "feature/x local no PR" "an ordinary local branch is listed"
  assert_eq "$LG_A_TIP" "$(git rev-parse -q --verify refs/heads/feature/x)" "…and survives --fetch --prune"
  assert_eq "$LG_A_TIP" "$(git rev-parse -q --verify refs/heads/feat-a)" "…as does feat-a"
  ( cd "$LG_B" && git push -q origin ":refs/heads/ledger-inflight/hostb/feat-a" )
  lg inflight --fetch
  assert_not_contains "$LG_OUT" "@hostb" "pruned when the remote drops it"
  assert_eq "$LG_A_TIP" "$(git rev-parse -q --verify refs/heads/feature/x)" "feature/x still there"
  for p in refs/heads refs/heads/ refs/remotes/x refs/tags/x refs/notes/x; do
    lg_enable "{\"base\":\"origin/main\",\"inflight\":{\"enabled\":true,\"host_id\":\"hosta\",\"ref_prefix\":\"$p\"}}"
    lg inflight
    assert_eq "2" "$LG_RC" "ref_prefix $p: exit 2"
  done
  lg_ifl_teardown
}

test_lg_inflight_raw_oid_base() {
  echo "test: a base given as a commit id — the current branch is not taken for the base's branch (m5)"
  lg_ifl_fixture
  git checkout -q feat-a
  lg_enable "{\"base\":\"$(git rev-parse origin/main)\",\"inflight\":{\"enabled\":true,\"host_id\":\"hosta\"}}"
  lg inflight
  assert_eq "0" "$LG_RC" "exit 0"
  assert_contains "$LG_OUT" "feat-a local,worktree,inflight no PR claims:app-1,app-2" "the current branch feat-a is in flight"
  git checkout -q main
  lg_ifl_teardown
}

test_lg_inflight_dedup_descendant_wins() {
  echo "test: own copies of one branch with different tips — the descendant wins whatever the dates; unrelated tips: the newer date (m6)"
  lg_ifl_fixture
  local older
  # This host's in-flight copy is AHEAD of the local branch but dated in
  # the past (clock skew): it still wins.
  older=$(GIT_COMMITTER_DATE="$(($(date +%s) - 86400)) +0000" git commit-tree -p "$LG_A_TIP" -m "ahead, skewed" -m "Ledger-Claims: app-5" "$LG_A_TIP^{tree}")
  git push -q origin "$older:refs/doc-superpowers/inflight/hosta/feat-a"
  lg inflight --fetch --format json
  assert_json_field "$LG_OUT" '.branches[] | select(.branch == "feat-a") | .oid' "$older" "the descendant wins over a newer date"
  # The local branch moves ahead of it: the local tip wins again.
  git checkout -q feat-a
  git merge -q --ff-only "$older"
  git commit -q --allow-empty -m "local ahead"
  git checkout -q main
  lg inflight --format json
  assert_json_field "$LG_OUT" '.branches[] | select(.branch == "feat-a") | .oid' "$(git rev-parse feat-a)" "…and the other way"
  local tr
  tr=$(harness_mktemp lg-gtrace)
  GIT_TRACE="$tr" lg inflight --format json
  assert_eq "0" "$(grep -c 'is-ancestor' "$tr")" "the verdicts are cached: no merge-base --is-ancestor the second time (R3-5)"
  rm -f "$tr"
  lg_ifl_teardown
}

test_lg_ifl_facts_sig_in_name() {
  echo "test: facts files carry their signature in the name — two plan-directory sets never overwrite each other (m4)"
  lg_ifl_fixture
  lg ls
  local c n1 n2
  c="$(git rev-parse --git-common-dir)/doc-superpowers/ledger/branch"
  n1=$(cd "$c" && ls f-* | wc -l | tr -d ' ')
  lg_doc_index '{"docs":{"docs/plans/p.md":{"doc_type":"plan"},"docs/other/o.md":{"doc_type":"plan"}}}'
  lg ls
  n2=$(cd "$c" && ls f-* | wc -l | tr -d ' ')
  assert_eq "$((n1 * 2))" "$n2" "another plan-directory set: a second set of facts files beside the first"
  assert_eq "$n1" "$(cd "$c" && ls f-* | sed 's/.*-\([0-9a-f]*\)\.tsv$/\1/' | sort | uniq -c | awk '{ print $1 }' | sort -u | head -n 1)" \
    "…each set under its own signature"
  lg_ifl_teardown
}

# --- Task 16b (U7): the plan words' `git cat-file --batch` reader -------------

# lg_ifl_plan_file <path> <filler-lines> <last-line-format>: a plan — a
# heading, <filler-lines> lines naming no key, then the printf format.
lg_ifl_plan_file() {
  {
    printf '# Plan\n\n'
    awk -v n="$2" 'BEGIN { for (i = 1; i <= n; i++) printf "Step %d: nothing to see here, and no key-shaped word on this line.\n", i }'
    # shellcheck disable=SC2059  # the format is the argument
    printf "$3"
  } > "$1"
}

# lg_ifl_plans_fixture <filler-lines>: open items app-1..app-4 (docs/issues/
# a1.md..a4.md), the plan directory docs/plans (doc-index doc_type plan),
# base origin/main on a bare remote (LG_REMOTE), and four branches off main,
# each adding plans whose last line names one key, after <filler-lines>
# lines of filler — the blob shapes `git cat-file --batch` ends differently:
#   plan-1  docs/plans/one.md, newline-terminated: app-1
#   plan-2  an empty docs/plans/empty.md, then docs/plans/two.md: app-2
#   plan-3  docs/plans/three.md, no final newline: app-3
#   plan-4  docs/plans/four.md, newline-terminated: app-4
lg_ifl_plans_fixture() {
  local n="$1" b
  lg_fixture
  lg_enable "$LG_IFL_CFG"
  lg_registry "$LG_REG_REL"
  for b in 1 2 3 4; do
    lg_item "docs/issues/a$b.md" "key: app-$b" "ledger: app" "status: Open" "severity: P2" "summary: Named by the plan on branch plan-$b"
  done
  mkdir -p docs/plans
  printf '# Plan\n\nNothing yet.\n' > docs/plans/p.md
  lg_doc_index '{"docs":{"docs/plans/p.md":{"doc_type":"plan"}}}'
  git add -A && git commit -qm items
  LG_REMOTE="$(harness_mktemp_d remote)/r.git"
  git init -q --bare "$LG_REMOTE"
  git --git-dir="$LG_REMOTE" symbolic-ref HEAD refs/heads/main
  git remote add origin "$LG_REMOTE"
  git push -q origin main
  git fetch -q origin
  git checkout -q -b plan-1 main
  lg_ifl_plan_file docs/plans/one.md "$n" 'Covers app-1.\n'
  git add -A && git commit -qm "plan 1"
  git checkout -q -b plan-2 main
  : > docs/plans/empty.md
  lg_ifl_plan_file docs/plans/two.md "$n" 'Covers app-2.\n'
  git add -A && git commit -qm "plan 2"
  git checkout -q -b plan-3 main
  lg_ifl_plan_file docs/plans/three.md "$n" 'Covers app-3.'
  git add -A && git commit -qm "plan 3"
  git checkout -q -b plan-4 main
  lg_ifl_plan_file docs/plans/four.md "$n" 'Covers app-4.\n'
  git add -A && git commit -qm "plan 4"
  git checkout -q main
}

LG_IFL_PLANS_OUT="plan-1 local no PR claims:app-1 contracts:— files:1
plan-2 local no PR claims:app-2 contracts:— files:2
plan-3 local no PR claims:app-3 contracts:— files:1
plan-4 local no PR claims:app-4 contracts:— files:1"

test_lg_ifl_plan_words_exact_tips() {
  echo "test: the plan words (U7) — a small batch: each plan's key goes to its own tip (the separator after a newline-terminated or empty blob is not a header)"
  lg_ifl_plans_fixture 2
  lg inflight
  assert_eq "0" "$LG_RC" "exit 0"
  assert_eq "$LG_IFL_PLANS_OUT" "$LG_OUT" "each branch claims the key its own plan names — none dropped, none moved to another tip"
  rm -rf "$(dirname "$LG_REMOTE")"
  teardown
}

# lg_t_ifl_words <req> <stream>: the plan-words reader on a crafted stream.
lg_t_ifl_words() {
  LC_ALL=C awk -v req="$1" "$_LG_AWK_IFL_WORDS" < "$2"
}

test_lg_ifl_plan_words_stream_in_step() {
  echo "test: the plan words (U7 audit) — a non-blob's content is skipped, a missing object takes its request, and a stream out of step with its requests exits 3 (never a silent short read)"
  lg_fixture
  lg_enable
  local rq st o
  rq=$(harness_mktemp ifl-req)
  st=$(harness_mktemp ifl-stream)
  o=0123456789abcdef0123456789abcdef01234567
  printf 't1:docs/plans/sub\nt2:docs/plans/gone.md\nt3:docs/plans/a.md\n' > "$rq"
  printf '%s tree 8\napp-7 x\n\nt2:docs/plans/gone.md missing\n%s blob 10\nSee app-1\n\n' "$o" "$o" > "$st"
  lg_call lg_t_ifl_words "$rq" "$st"
  assert_eq "0" "$LG_RC" "in step: exit 0"
  assert_eq "$(printf 'K\tt3\tapp-1')" "$LG_OUT" "…the blob's word, on its own tip; the tree's content read as content (no word, no header)"
  printf 't1:docs/plans/a.md\n' > "$rq"
  printf '%s blob 10\nSee app-1\n\n%s blob 10\nSee app-2\n\n' "$o" "$o" > "$st"
  lg_call lg_t_ifl_words "$rq" "$st"
  assert_eq "3" "$LG_RC" "a header past the last request: exit 3"
  printf 't1:docs/plans/a.md\nt2:docs/plans/b.md\n' > "$rq"
  printf '%s blob 4\nSee app-1\n\n%s blob 10\nSee app-2\n\n' "$o" "$o" > "$st"
  lg_call lg_t_ifl_words "$rq" "$st"
  assert_eq "3" "$LG_RC" "a size short of the content: exit 3"
  # Fix round 1 (m2), as frontmatter.awk's batch mode: a short read never passes.
  printf 't1:docs/plans/a.md\n' > "$rq"
  printf '%s blob 10\nSee ap' "$o" > "$st"
  lg_call lg_t_ifl_words "$rq" "$st"
  assert_eq "3" "$LG_RC" "a stream cut inside an object: exit 3"
  printf 't1:docs/plans/a.md\nt2:docs/plans/b.md\n' > "$rq"
  printf '%s blob 10\nSee app-1\n\n' "$o" > "$st"
  lg_call lg_t_ifl_words "$rq" "$st"
  assert_eq "3" "$LG_RC" "fewer objects than requests: exit 3"
  printf '%s blob 10\nSee app-1\nX\n%s blob 10\nSee app-2\n\n' "$o" "$o" > "$st"
  lg_call lg_t_ifl_words "$rq" "$st"
  assert_eq "3" "$LG_RC" "a separator line that is not empty: exit 3"
  printf '%s blob 0\n\n%s blob 9\nSee app-2\n' "$o" "$o" > "$st"
  lg_call lg_t_ifl_words "$rq" "$st"
  assert_eq "0|$(printf 'K\tt2\tapp-2')" "$LG_RC|$LG_OUT" "in step: an empty object, then one without a final newline of its own (the separator ends it): exit 0"
  teardown
}

test_lg_ifl_plan_words_large_batch() {
  echo "test: the plan words (U7) — plan blobs past the pipe buffers (> 64 KB) across several tips: the reader reads the whole batch (exit 0, no SIGPIPE) and attributes every word to its tip"
  lg_ifl_plans_fixture 2500
  local bytes
  bytes=$(git cat-file -s "plan-1:docs/plans/one.md")
  assert_eq "1" "$([ "$bytes" -gt 65536 ] && echo 1 || echo 0)" "the fixture: each plan is past 64 KB ($bytes bytes)"
  lg inflight
  assert_eq "0" "$LG_RC" "exit 0"
  assert_not_contains "$LG_ERR" "cannot read the in-flight plans" "…the plans read"
  assert_eq "$LG_IFL_PLANS_OUT" "$LG_OUT" "each branch claims the key its own plan names"
  rm -rf "$(dirname "$LG_REMOTE")"
  teardown
}

# --- Task 13: note, the items adapter, the GitHub reference adapter ------------------

# lg_note_fixture: lg_keys_fixture with item x-1 (docs/issues/a.md): a
# body, a "## Log" section holding one entry, then "## Next".
lg_note_fixture() {
  lg_keys_fixture
  lg_item docs/issues/a.md "key: x-1" "ledger: x" "status: Open" "severity: P2" "summary: An item that collects notes over time"
  printf '\nBody.\n\n## Log\n\n- 2026-01-01 first\n\n## Next\n\nOther.\n' >> docs/issues/a.md
  git add -A && git commit -qm items
}

# lg_bytes_eq <file> <printf-format> [args…]: the file holds exactly the
# bytes printf writes.
lg_bytes_eq() {
  local f="$1" e
  shift
  e=$(harness_mktemp lg-exp)
  # shellcheck disable=SC2059  # the format is the argument
  printf "$@" > "$e"
  if cmp -s "$e" "$f"; then echo same; else echo "differs: $(od -c "$f" | tail -n 4 | head -n 3 | tr -s ' ' | tr '\n' ' ')"; fi
  rm -f "$e"
}

test_lg_note_log_appends() {
  echo "test: ledger note <item> <text> — '- <date> <text>' after the log section's last non-blank line (before the next heading), the heading created at the end when absent; every other byte kept; no git operation"
  lg_note_fixture
  local today head0 n
  today=$(date +%Y-%m-%d)
  head0=$(git rev-parse HEAD)
  lg note x-1 "second entry"
  assert_eq "0" "$LG_RC" "exit 0"
  assert_eq "x-1  - $today second entry" "$LG_OUT" "one line: the item and the line written"
  assert_eq "same" "$(lg_bytes_eq docs/issues/a.md -- '---\nkey: x-1\nledger: x\nstatus: Open\nseverity: P2\nsummary: An item that collects notes over time\n---\n# a\n\nBody.\n\n## Log\n\n- 2026-01-01 first\n- %s second entry\n\n## Next\n\nOther.\n' "$today")" \
    "appended after the section's last non-blank line, before the next heading"
  assert_eq "$head0| M docs/issues/a.md" "$(git rev-parse HEAD)|$(git status --porcelain -- docs)" "no commit, nothing staged"
  assert_eq "a.md" "$(ls -A docs/issues)" "no temp file left beside it"
  # The forms show takes.
  lg note x 1 "third"
  assert_eq "0|x-1  - $today third" "$LG_RC|$LG_OUT" "'x 1' (two words) resolves"
  lg note "x #1" "fourth"
  assert_eq "0" "$LG_RC" "'x #1' resolves"
  lg note docs/issues/a.md "fifth"
  assert_eq "0" "$LG_RC" "a path resolves"
  assert_eq "- 2026-01-01 first|- $today second entry|- $today third|- $today fourth|- $today fifth" \
    "$(sed -n '/^## Log/,/^## Next/p' docs/issues/a.md | grep '^- ' | paste -sd '|' -)" "each line under the last one"
  lg note x-1 "sixth" --format json
  assert_eq "0|1" "$LG_RC|$(json_count "$LG_OUT")" "json: exit 0, one object"
  assert_json_field "$LG_OUT" '[.verb, .exit, .ref, .path, .kind, .line] | map(tostring) | join("|")' \
    "ledger note|0|x-1|docs/issues/a.md|log|- $today sixth" "json: ref, path, kind, line"
  # No log heading: created at the end after one blank line — a heading in
  # a fenced block or in the frontmatter (a YAML comment there) never counts.
  lg_item docs/issues/b.md "key: x-2" "ledger: x" "status: Open" "summary: An item without a log section yet" "## Log"
  # shellcheck disable=SC2016  # literal backticks: a fenced block
  printf '\nBody.\n\n```\n## Log\n```\n' >> docs/issues/b.md
  lg note x-2 "created"
  assert_eq "0" "$LG_RC" "no heading: exit 0"
  # shellcheck disable=SC2016  # literal backticks: a fenced block
  assert_eq "same" "$(lg_bytes_eq docs/issues/b.md -- '---\nkey: x-2\nledger: x\nstatus: Open\nsummary: An item without a log section yet\n## Log\n---\n# b\n\nBody.\n\n```\n## Log\n```\n\n## Log\n- %s created\n' "$today")" \
    "the heading created at the end, after one blank line (fenced and frontmatter lines ignored)"
  lg note x-2 "again"
  assert_eq "- $today again" "$(tail -n 1 docs/issues/b.md)" "…and used from then on"
  assert_eq "3" "$(grep -c '^## Log$' docs/issues/b.md)" "…not created twice (the frontmatter and fenced lines, and the new heading)"
  # A file ending in a blank line: no second blank line.
  lg_item docs/issues/c.md "key: x-3" "ledger: x" "status: Open" "summary: An item whose body ends in a blank line"
  printf '\nBody.\n\n' >> docs/issues/c.md
  lg note x-3 "c"
  assert_eq "same" "$(lg_bytes_eq docs/issues/c.md -- '---\nkey: x-3\nledger: x\nstatus: Open\nsummary: An item whose body ends in a blank line\n---\n# c\n\nBody.\n\n## Log\n- %s c\n' "$today")" \
    "a trailing blank line is the one blank line"
  # BOM, CRLF and no final newline: kept; the written line takes CRLF.
  printf '\357\273\277---\r\nkey: x-4\r\nledger: x\r\nstatus: Open\r\nsummary: A CRLF item with a BOM and no final newline\r\n---\r\n# d\r\n\r\n## Log\r\n\r\n- 2026-01-01 old' > docs/issues/d.md
  lg note x-4 "crlf entry"
  assert_eq "0" "$LG_RC" "BOM + CRLF: exit 0"
  assert_eq "same" "$(lg_bytes_eq docs/issues/d.md -- '\357\273\277---\r\nkey: x-4\r\nledger: x\r\nstatus: Open\r\nsummary: A CRLF item with a BOM and no final newline\r\n---\r\n# d\r\n\r\n## Log\r\n\r\n- 2026-01-01 old\r\n- %s crlf entry' "$today")" \
    "BOM kept, CRLF line, still no final newline"
  printf -- '---\r\nkey: x-5\r\nledger: x\r\nstatus: Open\r\nsummary: A CRLF item that has no log heading yet\r\n---\r\n# e\r\n\r\nBody.' > docs/issues/e.md
  lg note x-5 "e"
  assert_eq "same" "$(lg_bytes_eq docs/issues/e.md -- '---\r\nkey: x-5\r\nledger: x\r\nstatus: Open\r\nsummary: A CRLF item that has no log heading yet\r\n---\r\n# e\r\n\r\nBody.\r\n\r\n## Log\r\n- %s e' "$today")" \
    "a created heading: CRLF lines, no final newline"
  # config log_heading: a deeper heading ends at the next one of its level.
  lg_enable '{"log_heading":"### History"}'
  lg_item docs/issues/g.md "key: x-7" "ledger: x" "status: Open" "summary: An item with a custom history heading"
  printf '\n## Notes\n\n### History\n\n- 2026-01-01 old\n\n### Other\n\nx\n' >> docs/issues/g.md
  lg note x-7 "custom"
  assert_eq "- 2026-01-01 old|- $today custom|### Other" "$(sed -n '/^### History/,$p' docs/issues/g.md | grep -e '^- ' -e '^### O' | paste -sd '|' -)" \
    "config log_heading '### History': appended before the next ### heading"
  # A heading holding a backslash (awk -v would read "\n" as a newline).
  lg_enable '{"log_heading":"## C:\\notes"}'
  lg_item docs/issues/h.md "key: x-8" "ledger: x" "status: Open" "summary: An item whose log heading holds a backslash"
  printf '\n## C:\\notes\n\n- 2026-01-01 old\n\n## After\n' >> docs/issues/h.md
  lg note x-8 "slash"
  assert_eq "1|- 2026-01-01 old|- $today slash|## After" \
    "$(printf '%s|' "$(grep -c '^## C:' docs/issues/h.md)"; sed -n '/^## C:/,$p' docs/issues/h.md | grep -e '^- ' -e '^## A' | paste -sd '|' -)" \
    "log_heading '## C:\\notes': found, the line under it (no second heading)"
  lg_enable '{}'
  # A BOM and no heading: created at the end, the BOM kept.
  printf '\357\273\277---\nkey: x-9\nledger: x\nstatus: Open\nsummary: A BOM item that has no log heading yet\n---\n# i\n\nBody.\n' > docs/issues/i.md
  lg note x-9 "bom"
  assert_eq "same" "$(lg_bytes_eq docs/issues/i.md -- '\357\273\277---\nkey: x-9\nledger: x\nstatus: Open\nsummary: A BOM item that has no log heading yet\n---\n# i\n\nBody.\n\n## Log\n- %s bom\n' "$today")" \
    "BOM, no heading: the heading created at the end, the BOM kept"
  # CRLF, mid-section: the line goes in with CRLF, before the next heading.
  printf -- '---\r\nkey: x-10\r\nledger: x\r\nstatus: Open\r\nsummary: A CRLF item with a section after its log\r\n---\r\n# j\r\n\r\n## Log\r\n\r\n- 2026-01-01 old\r\n\r\n## Next\r\n\r\nOther.\r\n' > docs/issues/j.md
  lg note x-10 "mid"
  assert_eq "same" "$(lg_bytes_eq docs/issues/j.md -- '---\r\nkey: x-10\r\nledger: x\r\nstatus: Open\r\nsummary: A CRLF item with a section after its log\r\n---\r\n# j\r\n\r\n## Log\r\n\r\n- 2026-01-01 old\r\n- %s mid\r\n\r\n## Next\r\n\r\nOther.\r\n' "$today")" \
    "CRLF mid-section: a CRLF line before the next heading, the rest kept"
  # Errors.
  lg note nope-9 "x"
  assert_eq "1|no item matches 'nope-9'" "$LG_RC|$LG_OUT" "unknown: exit 1, one line"
  lg note nope-9 "x" --format json
  assert_eq "1|1" "$LG_RC|$(json_count "$LG_OUT")" "unknown, json: exit 1, one object"
  assert_json_field "$LG_OUT" '[.ref, (.path | tostring)] | join("|")' "nope-9|null" "…ref, path null"
  lg_item docs/issues/dup.md "ledger: x" "status: Open" "summary: One of two items with one stem"
  lg_item docs/archive/issues/dup.md "ledger: x" "status: Closed" "summary: The other item with that stem"
  lg note dup "x"
  assert_eq "3" "$LG_RC" "several items: exit 3"
  assert_contains "$LG_ERR" "matches several items" "…naming them"
  n=$(hash_file docs/issues/a.md)
  lg note x-1
  assert_eq "3" "$LG_RC" "no text: exit 3"
  lg note x-1 ""
  assert_eq "3" "$LG_RC" "empty text: exit 3"
  lg note x-1 "   "
  assert_eq "3" "$LG_RC" "blank text: exit 3"
  lg note x-1 "two
lines"
  assert_eq "3" "$LG_RC" "a newline in the text: exit 3"
  lg note x-1 "x" --kind bogus
  assert_eq "3" "$LG_RC" "--kind bogus: exit 3"
  lg note x-1 "x" --kind bogus --format json
  assert_eq "3|1" "$LG_RC|$(json_count "$LG_OUT")" "…one object"
  assert_eq "$n" "$(hash_file docs/issues/a.md)" "nothing written by a refused note"
  teardown
}

test_lg_note_ruling_heading() {
  echo "test: ledger note --kind ruling — '- <date> RULING: <text>' under '## Rulings' (created at the end when absent); a deeper heading does not end the section"
  lg_note_fixture
  local today
  today=$(date +%Y-%m-%d)
  lg note x-1 "Keep the old API" --kind ruling
  assert_eq "0" "$LG_RC" "exit 0"
  assert_eq "x-1  - $today RULING: Keep the old API" "$LG_OUT" "the line written"
  assert_eq "same" "$(lg_bytes_eq docs/issues/a.md -- '---\nkey: x-1\nledger: x\nstatus: Open\nseverity: P2\nsummary: An item that collects notes over time\n---\n# a\n\nBody.\n\n## Log\n\n- 2026-01-01 first\n\n## Next\n\nOther.\n\n## Rulings\n- %s RULING: Keep the old API\n' "$today")" \
    "## Rulings created at the end; the log untouched"
  lg note x-1 "Ship it behind a flag" --kind ruling --format json
  assert_json_field "$LG_OUT" '[.kind, .line] | join("|")' "ruling|- $today RULING: Ship it behind a flag" "json: kind ruling"
  assert_eq "- $today RULING: Keep the old API|- $today RULING: Ship it behind a flag" \
    "$(sed -n '/^## Rulings/,$p' docs/issues/a.md | grep '^- ' | paste -sd '|' -)" "the second ruling under the first"
  lg note x-1 "a log line"
  assert_eq "- 2026-01-01 first|- $today a log line" "$(sed -n '/^## Log/,/^## Next/p' docs/issues/a.md | grep '^- ' | paste -sd '|' -)" \
    "the default kind still writes under ## Log"
  lg_item docs/issues/b.md "key: x-2" "ledger: x" "status: Open" "summary: An item whose rulings section has a subsection"
  printf '\n## Rulings\n\n- 2026-01-01 RULING: one\n\n### Context\n\nWhy.\n\n## After\n\nEnd.\n' >> docs/issues/b.md
  lg note x-2 "two" --kind ruling
  assert_eq "- 2026-01-01 RULING: one|### Context|Why.|- $today RULING: two|## After" \
    "$(sed -n '/^## Rulings/,/^## After/p' docs/issues/b.md | grep -v -e '^$' -e '^## Rulings' | paste -sd '|' -)" \
    "after the section's last non-blank line: ### Context does not end it, ## After does"
  teardown
}

test_lg_note_owed_set_and_clear() {
  echo "test: ledger note --kind owed — sets fields.owed (its first candidate) through fm-write.awk, empty text removes it; no log line"
  lg_note_fixture
  local body
  body=$(lg_tail_hash docs/issues/a.md 8)
  lg note x-1 "deploy: then verify #2" --kind owed
  assert_eq "0" "$LG_RC" "exit 0"
  assert_eq "x-1  owed: deploy: then verify #2" "$LG_OUT" "the value set"
  assert_eq 'owed: "deploy: then verify #2"' "$(grep '^owed' docs/issues/a.md)" "one frontmatter line, quoted as the parser needs"
  assert_eq "$body" "$(lg_tail_hash docs/issues/a.md 9)" "the body untouched (no log line)"
  lg show x-1
  assert_contains "$LG_OUT" "owed: deploy: then verify #2" "show reads it back"
  lg note x-1 "device pass" --kind owed --format json
  assert_json_field "$LG_OUT" '[.ref, .path, .kind, .owed, (has("line") | tostring)] | join("|")' "x-1|docs/issues/a.md|owed|device pass|false" "json: owed, no line"
  assert_eq "owed: device pass" "$(grep '^owed' docs/issues/a.md)" "replaced, still one line"
  lg note x-1 "" --kind owed --format json
  assert_eq "0" "$LG_RC" "empty text: exit 0"
  assert_json_field "$LG_OUT" '.owed | tostring' "null" "json: owed null"
  assert_eq "0" "$(grep -c '^owed' docs/issues/a.md)" "removed"
  lg note x-1 "" --kind owed
  assert_eq "0|x-1  owed: (cleared)" "$LG_RC|$LG_OUT" "clearing again: exit 0"
  # A host's own name for the field (its first candidate).
  lg_enable '{"fields":{"owed":["remaining","owed"]}}'
  lg note x-1 "docs" --kind owed
  assert_eq "remaining: docs" "$(grep -e '^remaining' -e '^owed' docs/issues/a.md)" "config fields.owed: the first candidate"
  teardown
}

# lg_items_gh <args…>: run the reference items adapter (stdin closed); sets
# LG_RC, LG_OUT and LG_ERR.
lg_items_gh() {
  local err
  err=$(harness_mktemp lg-err)
  LG_RC=0
  LG_OUT=$("$BASH_BIN" "$REPO_DIR/scripts/adapters/ledger-items-gh.sh" "$@" 2>"$err" </dev/null) || LG_RC=$?
  LG_ERR=$(cat "$err")
  rm -f "$err"
}

LG_ITEMS_JSON='[{"number":12,"title":"Totals drift","body":"Intro paragraph\nwraps here.\n\nSecond para.\n\n<!-- doc-superpowers-ledger\nkey: x-12\nsummary: Totals drift when the cart is edited\nchanges: [field:order.total]\nowed: \"deploy: then verify #2\"\n-->\n","state":"OPEN","stateReason":"","labels":[{"name":"ledger:x"},{"name":"sev:P1"},{"name":"bug"}],"updatedAt":"2026-10-01T10:00:00Z","url":"https://github.com/o/r/issues/12"},
 {"number":13,"title":"CRLF, no block","body":"## Heading\r\n\r\nCRLF   body\ttext.\r\n","state":"CLOSED","stateReason":"COMPLETED","labels":[],"updatedAt":"2026-10-05T10:00:00Z","closedAt":"2026-10-05T09:00:00Z","url":"https://github.com/o/r/issues/13"},
 {"number":14,"title":"Two ledgers","body":"<!-- doc-superpowers-ledger\nkey: y-14\nnested:\n  a: b\n-->\n\nAfter the block.","state":"OPEN","stateReason":null,"labels":[{"name":"ledger:y"},{"name":"ledger:x"}],"updatedAt":"2026-10-06T10:00:00Z","url":"https://github.com/o/r/issues/14"},
 {"number":15,"title":"Long","body":"","state":"OPEN","stateReason":null,"labels":[{"name":"area/y"},{"name":"priority/P2"}],"updatedAt":"2026-10-07T10:00:00Z","url":"https://github.com/o/r/issues/15"}]'

test_lg_items_gh_list_normalises() {
  echo "test: ledger-items-gh.sh list — gh issue list (all states, limit 1000) normalised to {ref, url, title, body_excerpt, status, fields, labels, updated} lines; ledger and severity from prefixed labels; --since; at the limit, gh missing or failing, bad JSON: exit 2"
  lg_fixture
  lg_fake_gh
  local long bin bb
  printf '%s\n' "$LG_ITEMS_JSON" | jq '.[3].body = ([range(80)] | map("word") | join(" "))' > "$LG_GH/issues.json"
  long=$(jq -nr '([range(80)] | map("word") | join(" "))[0:279] + "…"')
  lg_items_gh list
  assert_eq "0" "$LG_RC" "exit 0"
  assert_eq "issue list --state all --limit 1000 --json number,title,body,state,stateReason,labels,updatedAt,url,closedAt" "$(cat "$LG_GH/args")" "one gh call"
  assert_eq "4" "$(printf '%s\n' "$LG_OUT" | grep -c .)" "one line per issue"
  assert_eq '{"ref":"gh#12","url":"https://github.com/o/r/issues/12","title":"Totals drift","body_excerpt":"Intro paragraph wraps here.","status":"Open","fields":{"key":"x-12","summary":"Totals drift when the cart is edited","changes":["field:order.total"],"owed":"deploy: then verify #2","ledger":"x","severity":"P1"},"labels":["ledger:x","sev:P1","bug"],"updated":"2026-10-01T10:00:00Z","closed":null,"fm_errors":[]}' \
    "$(printf '%s\n' "$LG_OUT" | sed -n 1p)" "the block's fields (frontmatter grammar), ledger and severity from labels, the first paragraph"
  assert_eq '{"ref":"gh#13","url":"https://github.com/o/r/issues/13","title":"CRLF, no block","body_excerpt":"CRLF body text.","status":"Fixed","fields":{},"labels":[],"updated":"2026-10-05T10:00:00Z","closed":"2026-10-05T09:00:00Z","fm_errors":[]}' \
    "$(printf '%s\n' "$LG_OUT" | sed -n 2p)" "no block: no fields; CRLF and blanks collapsed; a heading is no paragraph"
  assert_json_field "$(printf '%s\n' "$LG_OUT" | sed -n 3p)" '[.fields.key, (.fields.ledger | tojson), (.fm_errors | length), .body_excerpt] | map(tostring) | join("|")' \
    'y-14|["x","y"]|1|After the block.' "two ledger labels: a list (validate reports it); a nested map is an fm_errors entry; the paragraph after the block"
  assert_json_field "$(printf '%s\n' "$LG_OUT" | sed -n 4p)" '[(.fields | tojson), .body_excerpt] | join("|")' "{}|$long" \
    "labels without the prefixes: no fields; a long paragraph cut to 280 characters"
  LG_RC=0
  LG_OUT=$(LEDGER_GH_LEDGER_PREFIX=area/ LEDGER_GH_SEV_PREFIX=priority/ "$BASH_BIN" "$REPO_DIR/scripts/adapters/ledger-items-gh.sh" list 2>/dev/null </dev/null) || LG_RC=$?
  assert_json_field "$(printf '%s\n' "$LG_OUT" | sed -n 4p)" '.fields | tojson' '{"ledger":"y","severity":"P2"}' "LEDGER_GH_LEDGER_PREFIX / LEDGER_GH_SEV_PREFIX"
  lg_items_gh list --since 2026-10-05T10:00:00Z
  assert_eq "0|gh#13,gh#14,gh#15" "$LG_RC|$(printf '%s\n' "$LG_OUT" | jq -r .ref | paste -sd , -)" "--since: updatedAt ≥ the timestamp"
  lg_items_gh list --since
  assert_eq "3" "$LG_RC" "--since without a value: usage (3)"
  lg_items_gh list extra
  assert_eq "3" "$LG_RC" "an extra argument: usage (3)"
  lg_items_gh bogus
  assert_eq "3" "$LG_RC" "an unknown subcommand: usage (3)"
  printf '[]\n' > "$LG_GH/issues.json"
  lg_items_gh list
  assert_eq "0|" "$LG_RC|$LG_OUT" "no issues: exit 0, no lines"
  jq -n '[range(1000) | {number: (. + 1), title: "t", body: "", state: "OPEN", stateReason: null, labels: [], updatedAt: "2026-10-01T00:00:00Z", url: "u"}]' > "$LG_GH/issues.json"
  lg_items_gh list
  assert_eq "2" "$LG_RC" "1000 issues: the list may be cut — exit 2, never a silent truncation"
  assert_contains "$LG_ERR" "could not list completely: 1000 issues" "…saying why"
  jq -c '.[0:999]' "$LG_GH/issues.json" > "$LG_GH/i2" && mv "$LG_GH/i2" "$LG_GH/issues.json"
  lg_items_gh list
  assert_eq "0|999" "$LG_RC|$(printf '%s\n' "$LG_OUT" | grep -c .)" "999 issues: exit 0, every one"
  printf 'not json\n' > "$LG_GH/issues.json"
  lg_items_gh list
  assert_eq "2" "$LG_RC" "gh prints something that is not JSON: exit 2"
  printf 'To get started with GitHub CLI, please run:  gh auth login\n' > "$LG_GH/fail"
  lg_items_gh list
  assert_eq "2" "$LG_RC" "gh unauthenticated: exit 2"
  assert_contains "$LG_ERR" "gh auth login" "…with gh's stderr"
  rm -f "$LG_GH/fail"
  bin=$(harness_mktemp_d lg-nogh)
  ln -s "$(command -v jq)" "$bin/jq"
  bb=$(command -v "$BASH_BIN")
  LG_RC=0
  LG_ERR=$(PATH="$bin" "$bb" "$REPO_DIR/scripts/adapters/ledger-items-gh.sh" list 2>&1 >/dev/null </dev/null) || LG_RC=$?
  assert_eq "2" "$LG_RC" "no gh on PATH: exit 2"
  assert_contains "$LG_ERR" "gh" "…naming gh"
  rm -rf "$bin"
  lg_fake_gh_off
  teardown
}

test_lg_items_gh_block_roundtrip() {
  echo "test: ledger-items-gh.sh write / note / create — a field rewritten in the metadata block (created at the end of the body when absent; every other byte kept) reads back through list; ledger / severity as labels (created once); status refused; note comments; create prints {ref, url}"
  lg_fixture
  lg_fake_gh
  cat > "$LG_GH/issues.json" <<'EOF'
[{"number":30,"title":"No block yet","body":"Some text.\n","state":"OPEN","stateReason":null,"labels":[{"name":"ledger:x"},{"name":"sev:P2"},{"name":"bug"}],"updatedAt":"2026-10-01T10:00:00Z","url":"https://github.com/o/r/issues/30"},
 {"number":31,"title":"CRLF block mid-body","body":"Top.\r\n\r\n<!-- doc-superpowers-ledger\r\nkey: x-31\r\n-->\r\n\r\nBottom.\r\n","state":"OPEN","stateReason":null,"labels":[],"updatedAt":"2026-10-01T10:00:00Z","url":"https://github.com/o/r/issues/31"}]
EOF
  local f
  f=$(harness_mktemp lg-body)
  lg_items_gh write gh#30 owed "deploy: then verify #2"
  assert_eq "0" "$LG_RC" "write owed: exit 0"
  assert_eq "issue view 30 --json body" "$(sed -n 1p "$LG_GH/args")" "it reads the body"
  assert_contains "$(sed -n 2p "$LG_GH/args")" "issue edit 30 --body-file " "…and writes it back with --body-file"
  jq -j '.[] | select(.number == 30) | .body' "$LG_GH/issues.json" > "$f"
  assert_eq "same" "$(lg_bytes_eq "$f" 'Some text.\n\n<!-- doc-superpowers-ledger\nowed: "deploy: then verify #2"\n-->\n')" "the block created at the end of the body (the value quoted)"
  lg_items_gh write gh#30 summary "Short why it matters here"
  jq -j '.[] | select(.number == 30) | .body' "$LG_GH/issues.json" > "$f"
  assert_eq "same" "$(lg_bytes_eq "$f" 'Some text.\n\n<!-- doc-superpowers-ledger\nowed: "deploy: then verify #2"\nsummary: Short why it matters here\n-->\n')" "a second field joins the block"
  lg_items_gh list
  assert_json_field "$(printf '%s\n' "$LG_OUT" | sed -n 1p)" '[.fields.owed, .fields.summary, .body_excerpt] | join("|")' \
    "deploy: then verify #2|Short why it matters here|Some text." "list reads both back; the excerpt is the body outside the block"
  lg_items_gh write gh#30 owed ""
  jq -j '.[] | select(.number == 30) | .body' "$LG_GH/issues.json" > "$f"
  assert_eq "same" "$(lg_bytes_eq "$f" 'Some text.\n\n<!-- doc-superpowers-ledger\nsummary: Short why it matters here\n-->\n')" "an empty value removes the field"
  lg_items_gh write gh#31 owed "x"
  jq -j '.[] | select(.number == 31) | .body' "$LG_GH/issues.json" > "$f"
  assert_eq "same" "$(lg_bytes_eq "$f" 'Top.\r\n\r\n<!-- doc-superpowers-ledger\r\nkey: x-31\r\nowed: x\r\n-->\r\n\r\nBottom.\r\n')" "a CRLF block mid-body: the field added with CRLF, the rest kept"
  lg_items_gh list
  assert_json_field "$(printf '%s\n' "$LG_OUT" | sed -n 2p)" '[.ref, (.fields | tojson), .body_excerpt, (.fm_errors | length)] | map(tostring) | join("|")' \
    'gh#31|{"key":"x-31","owed":"x"}|Top.|0' "…and list reads the CRLF block back (the excerpt: the first paragraph outside it)"
  : > "$LG_GH/args"
  lg_items_gh write gh#30 ledger y
  assert_eq "0" "$LG_RC" "write ledger: exit 0"
  assert_eq "issue view 30 --json labels|label create ledger:y|issue edit 30 --remove-label ledger:x --add-label ledger:y" \
    "$(paste -sd '|' - < "$LG_GH/args")" "ledger: the label with its prefix replaced (created in the repository first)"
  assert_eq "bug,ledger:y,sev:P2" "$(jq -r '.[] | select(.number == 30) | [.labels[].name] | sort | join(",")' "$LG_GH/issues.json")" "…the labels after"
  lg_items_gh write gh#31 ledger y
  assert_eq "0" "$LG_RC" "a label that already exists: not an error"
  assert_eq "ledger:y" "$(jq -r '.[] | select(.number == 31) | [.labels[].name] | join(",")' "$LG_GH/issues.json")" "…the label added"
  lg_items_gh write gh#30 severity ""
  assert_eq "bug,ledger:y" "$(jq -r '.[] | select(.number == 30) | [.labels[].name] | sort | join(",")' "$LG_GH/issues.json")" "an empty severity removes the sev: label only"
  lg_items_gh write gh#30 status Closed
  assert_eq "3" "$LG_RC" "write status: refused (3) — it follows the issue's state"
  lg_items_gh write gh#30 owed "two
lines"
  assert_eq "3" "$LG_RC" "a value with a newline: usage (3)"
  lg_items_gh write 30 owed x
  assert_eq "3" "$LG_RC" "a ref that is not gh#<n>: usage (3)"
  lg_items_gh write gh#99 owed x
  assert_eq "2" "$LG_RC" "an issue gh cannot find: exit 2"
  lg_items_gh note gh#30 "Looked at it today"
  assert_eq "0" "$LG_RC" "note: exit 0"
  assert_eq "30	Looked at it today" "$(cat "$LG_GH/comments")" "note: gh issue comment with the text"
  printf 'Body of the new issue.\n' > "$f"
  lg_items_gh create --title "A new one" --body-file "$f"
  assert_eq "0" "$LG_RC" "create: exit 0"
  assert_eq '{"ref":"gh#32","url":"https://github.com/o/r/issues/32"}' "$LG_OUT" "create: one {ref, url} object"
  assert_eq "A new one|Body of the new issue." "$(jq -r '.[] | select(.number == 32) | "\(.title)|\(.body)"' "$LG_GH/issues.json" | head -n 1)" "…the issue created"
  lg_items_gh create --title "No body"
  assert_eq "3" "$LG_RC" "create without --body-file: usage (3)"
  rm -f "$f"
  lg_fake_gh_off
  teardown
}

test_lg_items_gh_close_reason_mapping() {
  echo "test: ledger-items-gh.sh — status: closed with superseded_by → Closed; COMPLETED → Fixed; NOT_PLANNED → Won't Fix; any other closed → Closed; OPEN → Open; the index maps them onto the status classes"
  lg_fake_gh
  lg_keys_fixture "$LG_ITEMS_CFG"
  cat > "$LG_GH/issues.json" <<'EOF'
[{"number":20,"title":"open","body":"<!-- doc-superpowers-ledger\nkey: x-20\n-->\n","state":"OPEN","stateReason":"REOPENED","labels":[],"updatedAt":"2026-10-01T10:00:00Z","url":"https://github.com/o/r/issues/20"},
 {"number":21,"title":"done","body":"<!-- doc-superpowers-ledger\nkey: x-21\n-->\n","state":"CLOSED","stateReason":"COMPLETED","labels":[],"updatedAt":"2026-10-01T10:00:00Z","url":"https://github.com/o/r/issues/21"},
 {"number":22,"title":"not planned","body":"<!-- doc-superpowers-ledger\nkey: x-22\n-->\n","state":"CLOSED","stateReason":"NOT_PLANNED","labels":[],"updatedAt":"2026-10-01T10:00:00Z","url":"https://github.com/o/r/issues/22"},
 {"number":23,"title":"duplicate","body":"<!-- doc-superpowers-ledger\nkey: x-23\n-->\n","state":"CLOSED","stateReason":"DUPLICATE","labels":[],"updatedAt":"2026-10-01T10:00:00Z","url":"https://github.com/o/r/issues/23"},
 {"number":24,"title":"no reason","body":"<!-- doc-superpowers-ledger\nkey: x-24\n-->\n","state":"CLOSED","stateReason":null,"labels":[],"updatedAt":"2026-10-01T10:00:00Z","url":"https://github.com/o/r/issues/24"},
 {"number":25,"title":"superseded","body":"<!-- doc-superpowers-ledger\nkey: x-25\nsuperseded_by: x-21\n-->\n","state":"CLOSED","stateReason":"COMPLETED","labels":[],"updatedAt":"2026-10-01T10:00:00Z","url":"https://github.com/o/r/issues/25"},
 {"number":26,"title":"open, superseded_by","body":"<!-- doc-superpowers-ledger\nkey: x-26\nsuperseded_by: x-21\n-->\n","state":"OPEN","stateReason":null,"labels":[],"updatedAt":"2026-10-01T10:00:00Z","url":"https://github.com/o/r/issues/26"}]
EOF
  lg_items_gh list
  assert_eq "0" "$LG_RC" "exit 0"
  assert_eq "gh#20=Open,gh#21=Fixed,gh#22=Won't Fix,gh#23=Closed,gh#24=Closed,gh#25=Closed,gh#26=Open" \
    "$(printf '%s\n' "$LG_OUT" | jq -r '"\(.ref)=\(.status)"' | paste -sd , -)" "the five rules, first match wins"
  lg ls --format json
  assert_eq "0" "$LG_RC" "ls: exit 0"
  assert_eq "x-20=open:not started,x-21=fixed:shipped,x-22=wontfix:won't fix,x-23=closed:closed,x-24=closed:closed,x-25=closed:superseded,x-26=open:not started" \
    "$(jq -r '[.items[] | "\(.key)=\(.class):\(.derived.status)"] | sort | join(",")' <<<"$LG_OUT")" "the status classes and derived statuses"
  lg_fake_gh_off
  teardown
}

LG_ITEMS_CFG='{"items":{"adapter":"doc-superpowers:ledger-items-gh"}}'

# lg_items_fixture [config]: lg_keys_fixture (ledgers x and y, an origin
# remote) with config items.adapter = doc-superpowers:ledger-items-gh over a
# fake gh (lg_fake_gh): file item x-1 (docs/issues/a.md, pushed); hosted
# gh#12 (x-12, open, P1) and gh#13 (y-13, closed as completed, P2).
lg_items_fixture() {
  local c="$LG_ITEMS_CFG"
  if [ $# -gt 0 ]; then c=$1; fi
  lg_fake_gh
  lg_keys_fixture "$c"
  lg_item docs/issues/a.md "key: x-1" "ledger: x" "status: Open" "severity: P2" "summary: A file item beside the hosted ones"
  git add -A && git commit -qm items
  git push -q origin main
  git fetch -q origin
  cat > "$LG_GH/issues.json" <<'EOF'
[{"number":12,"title":"Totals drift","body":"The total is wrong after an edit.\n\n<!-- doc-superpowers-ledger\nkey: x-12\nsummary: Totals drift when the cart is edited\n-->\n","state":"OPEN","stateReason":"","labels":[{"name":"ledger:x"},{"name":"sev:P1"}],"updatedAt":"2026-10-01T10:00:00Z","url":"https://github.com/o/r/issues/12"},
 {"number":13,"title":"Old crash","body":"Crashed on launch.\n\n<!-- doc-superpowers-ledger\nkey: y-13\nsummary: The app crashed on launch on old devices\n-->\n","state":"CLOSED","stateReason":"COMPLETED","labels":[{"name":"ledger:y"},{"name":"sev:P2"}],"updatedAt":"2026-10-02T10:00:00Z","url":"https://github.com/o/r/issues/13"}]
EOF
}

lg_items_teardown() {
  lg_fake_gh_off
  teardown
}

# lg_age_remote <name> <hours>: the remote cache file of <name> fetched
# <hours> earlier (its header's fetched_at moved back).
lg_age_remote() {
  local f h
  f=$(lg_remote_file "$1") || f=""
  [ -n "$f" ] || return 0
  h=$(head -n 1 "$f" | jq -c --argjson s "$(($2 * 3600))" '.fetched_at -= $s')
  { printf '%s\n' "$h"; tail -n +2 "$f"; } > "$f.x" && mv "$f.x" "$f"
}

test_lg_items_offline_stale_marker() {
  echo "test: hosted items join the index through the remote cache (path = ref, url) — a changed copy rebuilds the index, an unchanged refresh does not; offline or failing: the last copy and a stale marker with its age; none: absent, '—' and one note; --refresh: exit 2"
  lg_items_fixture
  local d
  lg ls --format json
  assert_eq "0|1" "$LG_RC|$(lg_gh_icalls)" "first ls: exit 0, gh issue list once"
  assert_json_field "$LG_OUT" '[.items[] | .path] | sort | join(",")' "docs/issues/a.md,gh#12,gh#13" "hosted items beside the file item: path = the adapter's ref"
  assert_json_field "$LG_OUT" '.items[] | select(.path == "gh#13") | [.key, .ledger, .severity, .status, .class, .display, .date] | join("|")' \
    "y-13|y|P2|Fixed|fixed|shipped|2026-10-02" "field-equivalent: key, ledger, severity, status, class, derived status, date (updated)"
  assert_json_field "$LG_OUT" '.items_data | [.state, (.as_of | type), (.error | tostring)] | join(",")' "fresh,number,null" "items_data: fresh"
  assert_eq "" "$LG_ERR" "fresh: no note"
  lg show gh#12
  assert_eq "0" "$LG_RC" "show gh#12: exit 0"
  assert_eq "x-12  x  P1  not started" "$(printf '%s\n' "$LG_OUT" | sed -n 1p)" "show: key, ledger, severity, status"
  assert_contains "$LG_OUT" "url: https://github.com/o/r/issues/12" "show: the url"
  assert_contains "$LG_OUT" "title: Totals drift" "show: the title"
  lg show x-12 --format json
  assert_json_field "$LG_OUT" '.item | [.path, .url] | join(" ")' "gh#12 https://github.com/o/r/issues/12" "the key resolves to the hosted item"
  lg ls
  assert_eq "1" "$(lg_gh_icalls)" "within the TTL: no gh call"
  DOC_TOOLS_LEDGER_TRACE=1 lg ls
  assert_contains "$LG_ERR" "index-hit" "…and the index is a hit"
  # The copy's content changes: the next read reflects it.
  jq '(.[] | select(.number == 12) | .body) |= sub("summary: Totals drift when the cart is edited"; "summary: Totals drift after any cart edit")' \
    "$LG_GH/issues.json" > "$LG_GH/i2" && mv "$LG_GH/i2" "$LG_GH/issues.json"
  DOC_TOOLS_LEDGER_TRACE=1 lg ls --refresh --format json
  assert_eq "0|2" "$LG_RC|$(lg_gh_icalls)" "--refresh: gh runs"
  assert_contains "$LG_ERR" "index-build" "…a changed copy rebuilds the index"
  assert_json_field "$LG_OUT" '.items[] | select(.path == "gh#12") | .summary' "Totals drift after any cart edit" "…which shows the change"
  DOC_TOOLS_LEDGER_TRACE=1 lg ls --refresh
  assert_eq "3" "$(lg_gh_icalls)" "--refresh again: gh runs"
  assert_contains "$LG_ERR" "index-hit" "…an unchanged copy: no rebuild"
  assert_not_contains "$LG_ERR" "index-build" "…none"
  # Offline, past the TTL: the copy serves, marked stale with its age.
  lg_age_remote items 3
  DOC_TOOLS_LEDGER_OFFLINE=1 lg ls --format json
  assert_eq "0|3" "$LG_RC|$(lg_gh_icalls)" "offline past the TTL: exit 0, no gh call"
  assert_eq "1" "$(printf '%s\n' "$LG_ERR" | grep -c '^ledger:')" "one ledger: note"
  assert_contains "$LG_ERR" "hosted items as of " "…hosted items as of <UTC>"
  assert_contains "$LG_ERR" "(3 h old, stale)" "…its age, stale"
  assert_contains "$LG_ERR" "offline: DOC_TOOLS_LEDGER_OFFLINE=1" "…offline"
  assert_json_field "$LG_OUT" '.items_data | [.state, (.as_of | type), (.error | tostring)] | join(",")' "offline,number,null" "items_data: offline"
  assert_json_field "$LG_OUT" '[.items[] | .path] | sort | join(",")' "docs/issues/a.md,gh#12,gh#13" "…the copy serves"
  DOC_TOOLS_LEDGER_OFFLINE=1 lg view all --out "$TEST_DIR/v"
  assert_eq "0" "$LG_RC" "view offline: exit 0"
  assert_contains "$(sed -n 3p "$TEST_DIR/v/x.md")" "hosted items as of " "the page header: the marker"
  assert_contains "$(sed -n 3p "$TEST_DIR/v/x.md")" "(3 h old, stale)" "…stale, its age"
  assert_contains "$(grep -F '| x-12 |' "$TEST_DIR/v/x.md")" "(https://github.com/o/r/issues/12)" "the hosted item links to its url"
  # The adapter fails (online): the copy serves, stale, with the reason.
  printf 'HTTP 502: Bad Gateway\n' > "$LG_GH/fail"
  lg ls --format json
  assert_eq "0" "$LG_RC" "adapter failing: exit 0"
  assert_contains "$LG_ERR" "(3 h old, stale) — the items adapter failed" "…stale, the adapter failed"
  assert_contains "$LG_ERR" "HTTP 502" "…with gh's reason"
  assert_json_field "$LG_OUT" '.items_data | [.state, (.error | test("HTTP 502") | tostring)] | join(",")' "stale,true" "items_data: stale, the error"
  lg ls --refresh
  assert_eq "2" "$LG_RC" "--refresh with the adapter failing: exit 2"
  assert_contains "$LG_ERR" "HTTP 502" "…saying why"
  lg ls --refresh --format json
  assert_eq "1|2" "$(json_count "$LG_OUT")|$(jq -r .exit <<<"$LG_OUT")" "…one JSON object, exit 2"
  # No copy at all: hosted items absent, '—', one note.
  d="$(git rev-parse --git-common-dir)/doc-superpowers/ledger/remote"
  rm -rf "$d"
  lg ls --format json
  assert_eq "0" "$LG_RC" "no copy: exit 0"
  assert_eq "1" "$(printf '%s\n' "$LG_ERR" | grep -c .)" "one stderr line"
  assert_contains "$LG_ERR" "hosted items unavailable" "…hosted items unavailable"
  assert_json_field "$LG_OUT" '[.items[] | .path] | join(",")' "docs/issues/a.md" "hosted items absent"
  assert_json_field "$LG_OUT" '.items_data.state' "none" "items_data: none"
  lg view all --out "$TEST_DIR/v"
  assert_contains "$(sed -n 3p "$TEST_DIR/v/x.md")" "hosted items: —" "the page header: hosted items: —"
  lg_items_teardown
}

test_lg_validate_all_hosted_items() {
  echo "test: validate --all checks hosted items through the cache (fresh or stale: the note says which) with the file items' checks where the adapter supplies the data; keys unique across both; no cache and a failing adapter: exit 2; --staged never calls the adapter"
  lg_items_fixture
  cat > "$LG_GH/issues.json" <<'EOF'
[{"number":12,"title":"Same key as the file item","body":"<!-- doc-superpowers-ledger\nkey: x-1\nsummary: A hosted item that reuses a file item's key\n-->\n","state":"OPEN","stateReason":null,"labels":[{"name":"ledger:nope"},{"name":"sev:P1"}],"updatedAt":"2026-10-01T10:00:00Z","url":"https://github.com/o/r/issues/12"},
 {"number":14,"title":"Not planned","body":"<!-- doc-superpowers-ledger\nkey: y-14\nsummary: Closed as not planned on GitHub, reason there\n-->\n","state":"CLOSED","stateReason":"NOT_PLANNED","labels":[{"name":"ledger:y"}],"updatedAt":"2026-10-01T10:00:00Z","url":"https://github.com/o/r/issues/14"},
 {"number":15,"title":"Nested","body":"<!-- doc-superpowers-ledger\nkey: y-15\nsummary: A hosted item whose block holds a nested map\nnested:\n  a: b\n-->\n","state":"OPEN","stateReason":null,"labels":[{"name":"ledger:y"}],"updatedAt":"2026-10-01T10:00:00Z","url":"https://github.com/o/r/issues/15"}]
EOF
  local n
  lg validate --all --format json
  assert_eq "1|1" "$LG_RC|$(json_count "$LG_OUT")" "findings: exit 1, one object"
  assert_eq "duplicate-key,no-contract" "$(jq -r '[.findings[] | select(.path == "docs/issues/a.md") | .class] | sort | join(",")' <<<"$LG_OUT")" \
    "the file item: its key is also a hosted item's"
  assert_eq "duplicate-key,no-contract,unknown-ledger" "$(jq -r '[.findings[] | select(.path == "gh#12") | .class] | sort | join(",")' <<<"$LG_OUT")" \
    "gh#12: the same key, an unknown ledger (from its label)"
  assert_eq "" "$(jq -r '[.findings[] | select(.path == "gh#14") | .class] | join(",")' <<<"$LG_OUT")" \
    "gh#14 (won't fix): no missing-resolution — the adapter supplies no resolution"
  assert_eq "no-contract,parse-error" "$(jq -r '[.findings[] | select(.path == "gh#15") | .class] | sort | join(",")' <<<"$LG_OUT")" \
    "gh#15: its block's nested map (advisory)"
  assert_eq "1" "$(printf '%s\n' "$LG_ERR" | grep -c '^ledger:')" "one ledger: note"
  assert_contains "$LG_ERR" "fresh" "…saying the copy is fresh"
  # Stale: the copy past its TTL and the adapter failing — still checked.
  lg_age_remote items 2
  printf 'HTTP 502: Bad Gateway\n' > "$LG_GH/fail"
  lg validate --all --format json
  assert_eq "1" "$LG_RC" "stale: still the findings (exit 1)"
  assert_eq "duplicate-key,no-contract,unknown-ledger" "$(jq -r '[.findings[] | select(.path == "gh#12") | .class] | sort | join(",")' <<<"$LG_OUT")" "…from the stale copy"
  assert_contains "$LG_ERR" "stale" "the note says stale"
  assert_contains "$LG_ERR" "HTTP 502" "…and why"
  # The pre-commit path never calls the adapter.
  rm -f "$LG_GH/fail"
  n=$(lg_gh_icalls)
  printf '\nedited\n' >> docs/issues/a.md
  git add docs/issues/a.md
  lg validate --staged --format json
  assert_eq "0|$n" "$LG_RC|$(lg_gh_icalls)" "validate --staged: exit 0, no gh call"
  assert_not_contains "$LG_OUT" "gh#12" "…no hosted item in sight"
  git reset -q
  # No copy and the adapter failing: exit 2.
  rm -rf "$(git rev-parse --git-common-dir)/doc-superpowers/ledger/remote"
  printf 'HTTP 502: Bad Gateway\n' > "$LG_GH/fail"
  lg validate --all
  assert_eq "2" "$LG_RC" "no copy, adapter failing: exit 2"
  assert_contains "$LG_ERR" "hosted items" "…naming the hosted items"
  assert_contains "$LG_ERR" "HTTP 502" "…and the reason"
  lg validate --all --format json
  assert_eq "1|2" "$(json_count "$LG_OUT")|$(jq -r .exit <<<"$LG_OUT")" "…one JSON object, exit 2"
  lg_items_teardown
}

test_lg_inflight_claims_by_ref_hosted() {
  echo "test: with an items adapter, a claims_by_ref '#N' claims the one hosted item whose ref ends in #N, mapped at join time (the facts keep the raw ref); no match stays unmapped and the note says so"
  lg_items_fixture '{"base":"origin/main","inflight":{"enabled":true,"host_id":"hosta"},"items":{"adapter":"doc-superpowers:ledger-items-gh"}}'
  git checkout -q -b fix-12
  git commit -q --allow-empty -m "fix it" -m "Fixes #12
Closes #99"
  git checkout -q main
  lg inflight --branch fix-12
  assert_eq "0" "$LG_RC" "exit 0"
  assert_eq "fix-12 local no PR claims:x-12 contracts:— files:0" "$LG_OUT" "Fixes #12 claims the hosted item gh#12 (x-12)"
  assert_eq "1" "$(printf '%s\n' "$LG_ERR" | grep -c '^ledger:')" "one ledger: note"
  assert_contains "$LG_ERR" "1 issue reference not resolved (#99): no single hosted item (items adapter) is #N" "…#99 unmapped, the note reworded"
  assert_not_contains "$LG_ERR" "#12" "…#12 is not in it"
  lg inflight --branch fix-12 --format json
  assert_json_field "$LG_OUT" '.branches[0] | [(.claims | join(",")), (.refs | join(","))] | join(" ")' "x-12 #99" "json: claims x-12, refs (unmapped) #99"
  lg show gh#12
  assert_contains "$LG_OUT" "in flight: fix-12 (local, no PR)" "show: the hosted item is in flight"
  lg ls --format json
  assert_json_field "$LG_OUT" '.items[] | select(.path == "gh#12") | .display' "on branch fix-12" "ls: on branch fix-12"
  assert_contains "$(cat "$(git rev-parse --git-common-dir)"/doc-superpowers/ledger/branch/f-*.tsv)" "#12" "the cached branch facts keep the raw ref"
  lg_items_teardown
}

test_lg_note_hosted_item() {
  echo "test: ledger note on a hosted item — log: adapter note <ref> <text>; ruling: note \"RULING: <text>\"; owed: write <ref> owed <text>; a failing or offline adapter: exit 2"
  lg_items_fixture
  lg note gh#12 "Looked at it"
  assert_eq "0" "$LG_RC" "exit 0"
  assert_eq "x-12  comment: Looked at it" "$LG_OUT" "one line: the comment"
  assert_eq "12	Looked at it" "$(cat "$LG_GH/comments")" "gh issue comment with the text (no date prefix: the comment has its own)"
  lg note x-12 "Keep the old API" --kind ruling --format json
  assert_json_field "$LG_OUT" '[.ref, .path, .kind, .line] | join("|")' "x-12|gh#12|ruling|RULING: Keep the old API" "ruling: json"
  assert_eq "12	RULING: Keep the old API" "$(sed -n 2p "$LG_GH/comments")" "ruling: a RULING: comment"
  lg note gh#12 "deploy" --kind owed --format json
  assert_json_field "$LG_OUT" '[.path, .kind, .owed] | join("|")' "gh#12|owed|deploy" "owed: json"
  assert_contains "$(jq -r '.[] | select(.number == 12) | .body' "$LG_GH/issues.json")" "owed: deploy" "owed: written into the issue's block"
  # The cached list is expired by the write: the next read shows it (m3).
  lg show gh#12
  assert_contains "$LG_OUT" "owed: deploy" "show: the new owed at once (the cache expired by the write)"
  lg note gh#12 "" --kind owed
  assert_eq "0|x-12  owed: (cleared)" "$LG_RC|$LG_OUT" "owed cleared"
  assert_not_contains "$(jq -r '.[] | select(.number == 12) | .body' "$LG_GH/issues.json")" "owed:" "…removed from the block"
  lg show gh#12
  assert_not_contains "$LG_OUT" "owed:" "show: cleared at once"
  # A value that would close the metadata comment: usage (3), the adapter never runs (I1).
  : > "$LG_GH/args"
  lg note gh#12 "rename foo --> bar" --kind owed
  assert_eq "3" "$LG_RC" "owed holding '-->': exit 3"
  assert_contains "$LG_ERR" "-->" "…naming it"
  lg note gh#12 "a --!> b" --kind owed --format json
  assert_eq "3|1" "$LG_RC|$(json_count "$LG_OUT")" "owed holding '--!>': exit 3, one object"
  assert_eq "" "$(grep -v '^issue list' "$LG_GH/args")" "…no write reached gh"
  # link and assign name a hosted item as such (m11).
  lg link gh#12 --relates sibling:x-1
  assert_eq "2" "$LG_RC" "link on a hosted item: exit 2"
  assert_contains "$LG_ERR" "gh#12 is a hosted item" "…named a hosted item"
  lg assign gh#12 y
  assert_eq "2" "$LG_RC" "assign on a hosted item: exit 2"
  assert_contains "$LG_ERR" "gh#12 is a hosted item" "…named a hosted item"
  printf 'HTTP 502: Bad Gateway\n' > "$LG_GH/fail"
  lg note gh#12 "x"
  assert_eq "2" "$LG_RC" "adapter failing: exit 2"
  assert_contains "$LG_ERR" "HTTP 502" "…naming the reason"
  assert_eq "" "$LG_OUT" "…no clean result"
  lg note gh#12 "x" --format json
  assert_eq "1|2" "$(json_count "$LG_OUT")|$(jq -r .exit <<<"$LG_OUT")" "…json: one object, exit 2"
  rm -f "$LG_GH/fail"
  DOC_TOOLS_LEDGER_OFFLINE=1 lg note gh#12 "x"
  assert_eq "2" "$LG_RC" "offline: exit 2"
  assert_contains "$LG_ERR" "offline" "…saying so"
  assert_eq "2" "$(wc -l < "$LG_GH/comments" | tr -d ' ')" "nothing more commented"
  lg_items_teardown
}

test_lg_items_adapter_contract() {
  echo "test: config items.adapter — a path from the top level or an absolute one; output that breaks the items contract (here: no url) is the adapter failing — read verbs serve no hosted items with one note, --refresh and validate --all exit 2; unconfigured: no items_data"
  lg_keys_fixture '{"items":{"adapter":"tools/items.sh"}}'
  mkdir -p tools
  cat > tools/items.sh <<'EOF'
#!/bin/sh
cat <<'J'
{"ref":"t#1","url":"https://example.test/1","title":"One","status":"Open","fields":{"key":"x-41","ledger":"x","summary":"A hosted item from a repo-relative adapter"}}
J
EOF
  chmod +x tools/items.sh
  lg show x-41
  assert_eq "0" "$LG_RC" "a path from the top level: exit 0"
  assert_contains "$LG_OUT" "path: t#1" "…the hosted item, its ref as path"
  assert_contains "$LG_OUT" "url: https://example.test/1" "…its url"
  lg_enable "{\"items\":{\"adapter\":\"$TEST_DIR/tools/items.sh\"}}"
  lg ls --format json
  assert_eq "0|t#1" "$LG_RC|$(jq -r '[.items[] | .path] | join(",")' <<<"$LG_OUT")" "an absolute path"
  cat > tools/items.sh <<'EOF'
#!/bin/sh
echo '{"ref":"t#1","title":"One","status":"Open","fields":{}}'
EOF
  lg ls --refresh
  assert_eq "2" "$LG_RC" "--refresh, a line without url: exit 2"
  assert_contains "$LG_ERR" "breaks the items contract" "…saying the output breaks the contract"
  rm -rf "$(git rev-parse --git-common-dir)/doc-superpowers/ledger/remote"
  lg ls --format json
  assert_eq "0|0" "$LG_RC|$(jq -r '.items | length' <<<"$LG_OUT")" "plain ls: exit 0, no hosted items"
  assert_eq "1" "$(printf '%s\n' "$LG_ERR" | grep -c .)" "…one stderr line"
  assert_contains "$LG_ERR" "hosted items unavailable (—)" "…the hosted items unavailable"
  assert_json_field "$LG_OUT" '.items_data.state' "none" "…items_data: none"
  lg validate --all --format json
  assert_eq "2|1" "$LG_RC|$(json_count "$LG_OUT")" "validate --all with no copy: exit 2, one object"
  lg_enable '{"items":{"adapter":"doc-superpowers:../x"}}'
  lg ls --refresh
  assert_eq "2" "$LG_RC" "a doc-superpowers: name that leaves the directory: exit 2 with --refresh"
  assert_contains "$LG_ERR" "config items.adapter" "…naming the setting"
  lg_enable '{}'
  lg ls --format json
  assert_json_field "$LG_OUT" 'has("items_data")' "false" "no items adapter: no items_data"
  teardown
}

# shellcheck disable=SC2016  # literal $(), backticks: hostile values
test_lg_items_gh_hostile_values() {
  echo "test: ledger-items-gh.sh — values that would close the metadata comment ('-->', '--!>') and commas in ledger / severity: usage (3), nothing written; hostile titles and values pass through argv and files untouched; create says what gh made when it prints no URL"
  lg_fixture
  lg_fake_gh
  cat > "$LG_GH/issues.json" <<'EOF'
[{"number":30,"title":"A block","body":"Some text.\n\n<!-- doc-superpowers-ledger\nkey: x-30\n-->\n","state":"OPEN","stateReason":null,"labels":[{"name":"ledger:x"}],"updatedAt":"2026-10-01T10:00:00Z","url":"https://github.com/o/r/issues/30"}]
EOF
  local f b0 v
  f=$(harness_mktemp lg-body)
  b0=$(jq -r '.[0].body' "$LG_GH/issues.json")
  : > "$LG_GH/args"
  lg_items_gh write gh#30 owed "rename foo --> bar"
  assert_eq "3" "$LG_RC" "a value holding '-->': usage (3)"
  assert_contains "$LG_ERR" "-->" "…naming it"
  lg_items_gh write gh#30 owed "a --!> b"
  assert_eq "3" "$LG_RC" "a value holding '--!>': usage (3)"
  lg_items_gh write gh#30 ledger "a,b"
  assert_eq "3" "$LG_RC" "a ledger value holding a comma: usage (3)"
  lg_items_gh write gh#30 severity "P1,P2"
  assert_eq "3" "$LG_RC" "a severity value holding a comma: usage (3)"
  assert_eq "|$b0" "$(cat "$LG_GH/args")|$(jq -r '.[0].body' "$LG_GH/issues.json")" "no gh call; the body and its block unchanged"
  # Hostile values and titles: never evaluated, read back exactly.
  lg_items_gh write gh#30 summary '$(touch pwned) "q" `w` -x'
  assert_eq "0" "$LG_RC" "a value with \$(), quotes and backticks: exit 0"
  lg_items_gh write gh#30 owed "-x"
  lg_items_gh list
  assert_json_field "$LG_OUT" '[.fields.summary, .fields.owed] | join("|")' '$(touch pwned) "q" `w` -x|-x' "…read back exactly (and a leading '-')"
  printf 'Body $(touch pwned) "q"\n' > "$f"
  lg_items_gh create --title '-x $(touch pwned) "q"' --body-file "$f"
  assert_eq "0|gh#31" "$LG_RC|$(jq -r .ref <<<"$LG_OUT")" "create with a hostile title: exit 0"
  assert_eq '-x $(touch pwned) "q"' "$(jq -r '.[] | select(.number == 31) | .title' "$LG_GH/issues.json")" "…the title as given"
  lg_items_gh note gh#30 '$(touch pwned) "q"'
  assert_eq '30	$(touch pwned) "q"' "$(cat "$LG_GH/comments")" "a hostile comment: as given"
  lg_items_gh list
  assert_json_field "$(printf '%s\n' "$LG_OUT" | sed -n 2p)" '.title' '-x $(touch pwned) "q"' "list: the hostile title as given"
  assert_file_not_exists "$TEST_DIR/pwned" "nothing was evaluated"
  # create: gh made the issue but printed no URL — said, so a retry does not duplicate it silently.
  : > "$LG_GH/create-nourl"
  lg_items_gh create --title "Second" --body-file "$f"
  assert_eq "2" "$LG_RC" "no URL from gh issue create: exit 2"
  assert_contains "$LG_ERR" "may have been created" "…saying the issue may exist"
  assert_contains "$LG_ERR" "Creating issue in o/r" "…with what gh printed"
  v=$(jq -r '[.[] | select(.title == "Second")] | length' "$LG_GH/issues.json")
  assert_eq "1" "$v" "(the fake made it)"
  rm -f "$f"
  lg_fake_gh_off
  teardown
}

# shellcheck disable=SC2016  # literal backticks: fenced blocks
test_lg_items_gh_block_markers() {
  echo "test: ledger-items-gh.sh — the metadata block is the first '<!-- doc-superpowers-ledger' line outside fenced code (a word: not '…ledgerX'); a closing '-->' not on a line of its own is an fm_errors entry; write never edits a fenced example"
  lg_fixture
  lg_fake_gh
  cat > "$LG_GH/issues.json" <<'EOF'
[{"number":40,"title":"Fenced example first","body":"Example:\n\n```\n<!-- doc-superpowers-ledger\nkey: fake-1\n-->\n```\n\n<!-- doc-superpowers-ledger\nkey: x-40\n-->\n","state":"OPEN","stateReason":null,"labels":[],"updatedAt":"2026-10-01T10:00:00Z","url":"https://github.com/o/r/issues/40"},
 {"number":41,"title":"Not a marker","body":"<!-- doc-superpowers-ledgerX\nkey: nope-1\n-->\n\nText.\n","state":"OPEN","stateReason":null,"labels":[],"updatedAt":"2026-10-01T10:00:00Z","url":"https://github.com/o/r/issues/41"},
 {"number":42,"title":"Closing mid-line","body":"<!-- doc-superpowers-ledger\nkey: x-42\nowed: x -->\n","state":"OPEN","stateReason":null,"labels":[],"updatedAt":"2026-10-01T10:00:00Z","url":"https://github.com/o/r/issues/42"},
 {"number":43,"title":"Only a fenced example","body":"Example:\n\n~~~~\n<!-- doc-superpowers-ledger\nkey: fake-2\n-->\n~~~~\n","state":"OPEN","stateReason":null,"labels":[],"updatedAt":"2026-10-01T10:00:00Z","url":"https://github.com/o/r/issues/43"},
 {"number":44,"title":"Unclosed fence","body":"Text.\n\n```\ncode never closed\n","state":"OPEN","stateReason":null,"labels":[],"updatedAt":"2026-10-01T10:00:00Z","url":"https://github.com/o/r/issues/44"},
 {"number":45,"title":"Unclosed tilde fence, CRLF","body":"Text.\r\n\r\n~~~~~\r\ncode never closed","state":"OPEN","stateReason":null,"labels":[],"updatedAt":"2026-10-01T10:00:00Z","url":"https://github.com/o/r/issues/45"}]
EOF
  local f
  f=$(harness_mktemp lg-body)
  lg_items_gh list
  assert_eq "0" "$LG_RC" "exit 0"
  assert_json_field "$(printf '%s\n' "$LG_OUT" | sed -n 1p)" '[(.fields | tojson), .body_excerpt] | join("|")' '{"key":"x-40"}|Example:' \
    "a block inside a fenced example is not the block"
  assert_json_field "$(printf '%s\n' "$LG_OUT" | sed -n 2p)" '.fields | tojson' '{}' "'<!-- doc-superpowers-ledgerX' is no marker"
  assert_json_field "$(printf '%s\n' "$LG_OUT" | sed -n 3p)" '[.fields.key, (.fm_errors | length), (.fm_errors[0] | test("closing -->"))] | map(tostring) | join("|")' \
    "x-42|1|true" "a closing '-->' mid-line: read, and an fm_errors entry"
  assert_json_field "$(printf '%s\n' "$LG_OUT" | sed -n 4p)" '.fields | tojson' '{}' "only a fenced example (~~~~): no block"
  lg_items_gh write gh#43 owed y
  jq -j '.[] | select(.number == 43) | .body' "$LG_GH/issues.json" > "$f"
  assert_eq "same" "$(lg_bytes_eq "$f" 'Example:\n\n~~~~\n<!-- doc-superpowers-ledger\nkey: fake-2\n-->\n~~~~\n\n<!-- doc-superpowers-ledger\nowed: y\n-->\n')" \
    "write: a new block at the end, the fenced example untouched"
  lg_items_gh write gh#40 owed z
  jq -j '.[] | select(.number == 40) | .body' "$LG_GH/issues.json" > "$f"
  assert_eq "same" "$(lg_bytes_eq "$f" 'Example:\n\n```\n<!-- doc-superpowers-ledger\nkey: fake-1\n-->\n```\n\n<!-- doc-superpowers-ledger\nkey: x-40\nowed: z\n-->\n')" \
    "write: the real block edited, the fenced one untouched"
  # A body that ends inside an open fence: the fence is closed first (as
  # GitHub renders it), then the block is appended outside it.
  lg_items_gh write gh#44 owed x
  lg_items_gh write gh#44 summary "Why this matters, briefly"
  jq -j '.[] | select(.number == 44) | .body' "$LG_GH/issues.json" > "$f"
  assert_eq "same" "$(lg_bytes_eq "$f" 'Text.\n\n```\ncode never closed\n```\n\n<!-- doc-superpowers-ledger\nowed: x\nsummary: Why this matters, briefly\n-->\n')" \
    "an open \`\`\` fence closed, then one block; the second write updates it"
  lg_items_gh write gh#45 owed y
  jq -j '.[] | select(.number == 45) | .body' "$LG_GH/issues.json" > "$f"
  assert_eq "same" "$(lg_bytes_eq "$f" 'Text.\r\n\r\n~~~~~\r\ncode never closed\r\n~~~~~\r\n\r\n<!-- doc-superpowers-ledger\r\nowed: y\r\n-->\r\n')" \
    "an open ~~~~~ fence (CRLF, no final newline): closed with the same run and line ending"
  lg_items_gh list
  assert_json_field "$(printf '%s\n' "$LG_OUT" | sed -n 5p)" '[(.fields | tojson), (.fm_errors | length)] | map(tostring) | join("|")' \
    '{"owed":"x","summary":"Why this matters, briefly"}|0' "list reads the block after the closed fence"
  assert_json_field "$(printf '%s\n' "$LG_OUT" | sed -n 6p)" '.fields | tojson' '{"owed":"y"}' "…the ~~~~~ one too"
  assert_eq "1" "$(jq -r '.[] | select(.number == 44) | .body' "$LG_GH/issues.json" | grep -c 'doc-superpowers-ledger')" "exactly one block"
  rm -f "$f"
  lg_fake_gh_off
  teardown
}

# lg_rc_hosted_fixture: base main, the relations registry, an items adapter
# over a fake gh; file items committed on 2026-03-01 (app-1 → hosted root
# cause app-12, app-2 → app-13, app-3 → app-16; core-1 fixed), a
# field:order.total change on 2026-03-15; hosted app-12 (closed
# 2026-04-01), app-13 (closed 2026-02-01, updated 2026-05-01), app-16
# (closed as not planned, no closedAt, updated 2026-04-01), core-14 (open,
# root cause core-1, updated 2026-02-01), core-15 (open, consumes
# field:order.total, updated 2026-03-10).
lg_rc_hosted_fixture() {
  lg_fake_gh
  lg_fixture
  lg_enable '{"base":"main","items":{"adapter":"doc-superpowers:ledger-items-gh"}}'
  lg_registry "$LG_REG_REL"
  lg_item docs/issues/a.md "key: app-1" "ledger: app" "status: Open" "severity: P1" "summary: Depends on a hosted root cause" "relates: [root-cause:app-12]"
  lg_item docs/issues/b.md "key: app-2" "ledger: app" "status: Open" "severity: P2" "summary: Depends on a hosted fix closed before it" "relates: [root-cause:app-13]"
  lg_item docs/issues/d.md "key: app-3" "ledger: app" "status: Open" "severity: P2" "summary: Depends on a hosted won't-fix" "relates: [root-cause:app-16]"
  lg_item docs/issues/c.md "key: core-1" "ledger: core" "status: Fixed" "severity: P2" "summary: A file root cause fixed on the base"
  printf '\n## Resolution\n\nFixed.\n' >> docs/issues/c.md
  mkdir -p src/order && echo 1 > src/order/total.js
  lg_commit_at 2026-03-01 items
  echo 2 > src/order/total.js
  lg_commit_at 2026-03-15 "totals in cents"
  cat > "$LG_GH/issues.json" <<'EOF'
[{"number":12,"title":"Root cause","body":"<!-- doc-superpowers-ledger\nkey: app-12\n-->\n","state":"CLOSED","stateReason":"COMPLETED","labels":[],"updatedAt":"2026-04-02T00:00:00Z","closedAt":"2026-04-01T00:00:00Z","url":"https://github.com/o/r/issues/12"},
 {"number":13,"title":"Closed before","body":"<!-- doc-superpowers-ledger\nkey: app-13\n-->\n","state":"CLOSED","stateReason":"COMPLETED","labels":[],"updatedAt":"2026-05-01T00:00:00Z","closedAt":"2026-02-01T00:00:00Z","url":"https://github.com/o/r/issues/13"},
 {"number":16,"title":"Won't fix","body":"<!-- doc-superpowers-ledger\nkey: app-16\n-->\n","state":"CLOSED","stateReason":"NOT_PLANNED","labels":[],"updatedAt":"2026-04-01T00:00:00Z","url":"https://github.com/o/r/issues/16"},
 {"number":14,"title":"Hosted dependent","body":"<!-- doc-superpowers-ledger\nkey: core-14\nrelates: [root-cause:core-1]\n-->\n","state":"OPEN","stateReason":null,"labels":[],"updatedAt":"2026-02-01T00:00:00Z","url":"https://github.com/o/r/issues/14"},
 {"number":15,"title":"Hosted consumer","body":"<!-- doc-superpowers-ledger\nkey: core-15\nconsumes: [field:order.total]\n-->\n","state":"OPEN","stateReason":null,"labels":[],"updatedAt":"2026-03-10T00:00:00Z","url":"https://github.com/o/r/issues/15"},
 {"number":17,"title":"Hosted on hosted, before","body":"<!-- doc-superpowers-ledger\nkey: core-17\nrelates: [root-cause:app-12]\n-->\n","state":"OPEN","stateReason":null,"labels":[],"updatedAt":"2026-03-20T00:00:00Z","url":"https://github.com/o/r/issues/17"},
 {"number":18,"title":"Hosted on hosted, after","body":"<!-- doc-superpowers-ledger\nkey: core-18\nrelates: [root-cause:app-12]\n-->\n","state":"OPEN","stateReason":null,"labels":[],"updatedAt":"2026-05-01T00:00:00Z","url":"https://github.com/o/r/issues/18"}]
EOF
}

# lg_rc_hosted_all: "<key>=<markers>" for the five items with markers in
# question, from LG_IX.
lg_rc_hosted_all() {
  local k
  for k in app-1 app-2 app-3 core-14 core-15; do printf '%s=%s;' "$k" "$(lg_rc_of "$k")"; done
}

test_lg_recheck_hosted_items() {
  echo "test: re-check markers with hosted items (§F.2) — a hosted source lands at its close time (closed, else updated), a hosted target is touched at updated (any update clears its marker); a contract change marks an open hosted consumer; the --rev (publish) build the same"
  lg_rc_hosted_fixture
  lg_rel_ix
  assert_eq "app-1=app-12;app-2=;app-3=app-16;core-14=core-1;core-15=field:order.total;" "$(lg_rc_hosted_all)" \
    "closed hosted root cause after the item's commit: marked; closed before it (a later update does not count): not; no closedAt: its update; a file root cause fixed after the hosted item's update: marked; a contract change after it: marked"
  assert_eq "core-17=app-12;core-18=;" "core-17=$(lg_rc_of core-17);core-18=$(lg_rc_of core-18);" \
    "a hosted source against a hosted target: closed after its update → marked; updated after the close → not"
  lg show core-14
  assert_contains "$LG_OUT" "re-check: core-1 landed" "show: on the hosted item"
  lg_call _lg_index --rev main
  LG_IX=$LG_OUT
  assert_contains "$LG_IX" "/rev/index-" "(the --rev index)"
  assert_eq "app-1=app-12;app-2=;app-3=app-16;core-14=core-1;core-15=field:order.total;" "$(lg_rc_hosted_all)" "--rev (publish): the same markers"
  # The hosted issues are updated after the changes: their markers clear.
  jq '(.[] | select(.number == 14) | .updatedAt) = "2026-04-01T00:00:00Z" | (.[] | select(.number == 15) | .updatedAt) = "2026-03-20T00:00:00Z"' \
    "$LG_GH/issues.json" > "$LG_GH/i2" && mv "$LG_GH/i2" "$LG_GH/issues.json"
  rm -rf "$(git rev-parse --git-common-dir)/doc-superpowers/ledger/remote"
  lg_rel_ix
  assert_eq "app-1=app-12;app-2=;app-3=app-16;core-14=;core-15=;" "$(lg_rc_hosted_all)" "updated after the source landed / the contract changed: cleared"
  lg_call _lg_index --rev main
  LG_IX=$LG_OUT
  assert_eq "app-1=app-12;app-2=;app-3=app-16;core-14=;core-15=;" "$(lg_rc_hosted_all)" "--rev: cleared too"
  # A later commit to the file dependent clears its hosted-source marker.
  printf '\nre-checked\n' >> docs/issues/a.md
  lg_commit_at 2026-04-10 "recheck app-1"
  lg_rel_ix
  assert_eq "" "$(lg_rc_of app-1)" "a commit to the file item after the hosted source closed: cleared"
  lg_fake_gh_off
  teardown
}

# --- Task 14: init — sources, registry proposal, assignment decisions ---------

# lg_init_fixture: lg_fixture (setup's src/index.js and docs/architecture.md)
# plus code under app/ (6 of the 13 code files: more than 40 %, so it is
# split), server/, scripts/, .github/, .vscode/ (a dot-dir, left out) and a
# root Makefile; six items under docs/issues/; docs/notes/ (three files with
# status: frontmatter: a suggested glob); a plan; the hand-written ledger
# docs/ledgers/checkout-ledger.md (3 rows: one done linking an item, one open
# linking a plan, one open linking an item). Committed; no config.
lg_init_fixture() {
  lg_fixture
  local f
  for f in app/checkout/Cart.ts app/checkout/CheckoutSheet.ts app/checkout/total.ts app/profile/Profile.ts \
      app/profile/Avatar.ts app/main.ts server/orders/model.ts server/orders/api.ts scripts/build.sh \
      .github/workflows/ci.yml .vscode/settings.json Makefile; do
    mkdir -p "$(dirname "$f")"
    printf 'x\n' > "$f"
  done
  lg_item docs/issues/2026-01-01-cart-total.md 'status: Open' 'ledger: checkout' 'summary: Totals drift'
  lg_item docs/issues/2026-01-02-sheet-flicker.md 'status: Open'
  lg_item docs/issues/2026-01-03-order-sync.md 'status: In Progress' 'related-files: [server/orders/model.ts]'
  lg_item docs/issues/2026-01-04-old-bug.md 'status: Resolved'
  lg_item docs/issues/2026-01-05-misc.md 'status: Open' 'component: Checkout'
  lg_item docs/issues/2026-01-06-wontfix.md "status: Won't Fix" 'area: profile'
  lg_item docs/notes/a.md 'status: draft'
  lg_item docs/notes/b.md 'status: draft'
  lg_item docs/notes/c.md 'status: done'
  lg_item docs/plans/x-plan.md 'status: active'
  mkdir -p docs/ledgers
  cat > docs/ledgers/checkout-ledger.md <<'EOF'
# Checkout ledger

| # | Item | State |
|---|------|-------|
| 1 | [Old bug](../issues/2026-01-04-old-bug.md) | ~~done~~ |
| 2 | **Totals plan** — [plan](../plans/x-plan.md) | open |
| 3 | [Sheet flicker](../issues/2026-01-02-sheet-flicker.md#detail) | open |
EOF
  git add -A && git commit -qm "init fixture"
}

# The registry the assignment tests accept: checkout and orders.
LG_INIT_REG='{"schema":"ledger-registry/1","ledgers":[
 {"id":"checkout","title":"Checkout","kind":"service","status":"active","paths":["app/checkout/**"]},
 {"id":"orders","title":"Orders","kind":"service","status":"active","paths":["server/orders/**"]}]}'

# lg_init_edit_reg [json]: write the edited registry docs/ledger/edited.json
# (untracked; default LG_INIT_REG).
lg_init_edit_reg() {
  printf '%s\n' "${1:-$LG_INIT_REG}" > docs/ledger/edited.json
}

# lg_init_rows <decisions.tsv>: its rows (the "#" header lines dropped), an
# empty decision shown as "-" (an assertion's literal keeps no trailing tab).
lg_init_rows() {
  { grep -v '^#' "$1" || true; } | awk -F '\t' -v OFS='\t' 'NF == 5 && $5 == "" { $5 = "-" } { print }'
}

# lg_init_status: the work tree's changes, one porcelain line each, sorted.
lg_init_status() {
  git status --porcelain --untracked-files=all | LC_ALL=C sort
}

test_lg_init_runs_without_config() {
  echo "test: ledger init is exempt from the inert check (R1) — it runs on the default config and writes no config.json"
  lg_init_fixture
  lg init --report docs/ledger/r.md --format json
  assert_eq "0" "$LG_RC" "init without config.json exits 0"
  assert_eq "1" "$(json_count "$LG_OUT")" "exactly one object"
  assert_json_field "$LG_OUT" '[.verb, .enabled, .exit, .report] | map(tostring) | join("|")' \
    "ledger init|false|0|docs/ledger/r.md" "verb, enabled false (no config), exit 0, report"
  assert_file_exists docs/ledger/r.md "the report is written"
  assert_file_not_exists docs/ledger/config.json "no config.json (only --accept writes it)"
  # Every other verb stays inert.
  lg ls
  assert_eq "0|$LG_INERT_LINE" "$LG_RC|$LG_OUT" "ls is still inert"
  # A vendored copy without scripts/ledger/: init cannot run (2), never inert.
  local vend
  vend=$(harness_mktemp_d lg-vend)
  cp "$REPO_DIR/scripts/doc-tools.sh" "$vend/doc-tools.sh"
  # Its own runner (see test_lg_vendored_copy_no_config_inert).
  printf '#!/bin/sh\nexec "%s" "%s" "$@"\n' "$BASH_BIN" "$vend/doc-tools.sh" > "$vend/run"
  chmod +x "$vend/run"
  lg_with "$vend/run" init --report docs/ledger/r2.md
  assert_eq "2" "$LG_RC" "vendored copy without scripts/ledger/: init exits 2"
  assert_contains "$LG_ERR" "scripts/ledger/" "stderr names the missing directory"
  rm -rf "$vend"
  teardown
}

test_lg_init_usage_errors() {
  echo "test: ledger init modes (R2) — none or two: 3; --dry-run with --report: 3; bad --sources: 3; --accept of a missing file / --import without an adapter: 2; a bad --registry: 2"
  lg_init_fixture
  lg init
  assert_eq "3" "$LG_RC" "no mode exits 3"
  assert_contains "$LG_ERR" "--report" "the message names --report"
  lg init --bogus --format json
  assert_eq "3" "$LG_RC" "an unknown option exits 3 without a config"
  assert_json_field "$LG_OUT" '[.verb, .enabled, .exit] | map(tostring) | join("|")' "ledger init|false|3" "its one object"
  lg init --report r.md --accept d.tsv --format json
  assert_eq "3" "$LG_RC" "two modes exit 3"
  assert_eq "1" "$(json_count "$LG_OUT")" "JSON: one object"
  lg init --report r.md --import
  assert_eq "3" "$LG_RC" "--report with --import exits 3"
  lg init --report r.md --dry-run
  assert_eq "3" "$LG_RC" "--dry-run with --report exits 3"
  lg init --report r.md --sources files,svn
  assert_eq "3" "$LG_RC" "an unknown source exits 3"
  assert_contains "$LG_ERR" "svn" "the message names it"
  lg init --report r.md --sources ''
  assert_eq "3" "$LG_RC" "an empty --sources exits 3"
  lg init --report r.md extra
  assert_eq "3" "$LG_RC" "a positional argument exits 3"
  lg init --accept d.tsv
  assert_eq "2" "$LG_RC" "--accept of a missing file exits 2"
  assert_contains "$LG_ERR" "d.tsv" "stderr names it"
  lg init --import --format json
  assert_eq "2" "$LG_RC" "--import without an items adapter exits 2"
  assert_json_field "$LG_OUT" '.error | test("items.adapter")' "true" "JSON error says why"
  lg init --report r.md --registry missing.json
  assert_eq "2" "$LG_RC" "a missing --registry exits 2"
  assert_contains "$LG_ERR" "missing.json" "stderr names it"
  printf '{"schema":"ledger-registry/2","ledgers":[]}\n' > bad.json
  lg init --report r.md --registry bad.json
  assert_eq "2" "$LG_RC" "a --registry that is not ledger-registry/1 exits 2"
  printf 'nope\n' > bad.json
  lg init --report r.md --registry bad.json
  assert_eq "2" "$LG_RC" "an unparsable --registry exits 2"
  assert_file_not_exists r.md "no report on a failed run"
  # A registry path holding a tab or a newline (the decisions header names
  # it on one line): a usage error.
  printf '%s\n' "$LG_INIT_REG" > "re	g.json"
  lg init --report r.md --registry "re	g.json"
  assert_eq "3" "$LG_RC" "a tab in the --registry path exits 3"
  lg init --report r.md --registry "re
g.json"
  assert_eq "3" "$LG_RC" "a newline in the --registry path exits 3"
  teardown
}

test_lg_init_report_writes_only_report_files() {
  echo "test: init --report writes only the report, the decisions file and docs/ledger/ledgers.proposed.json; never ledgers.json or config.json"
  lg_init_fixture
  lg init --report docs/ledger/init-report.md
  assert_eq "0" "$LG_RC" "no registry: exits 0"
  assert_eq "?? docs/ledger/init-report.md
?? docs/ledger/ledgers.proposed.json" "$(lg_init_status)" "the report and the proposal, nothing else"
  assert_eq "wrote docs/ledger/init-report.md" "$(printf '%s\n' "$LG_OUT" | sed -n 1p)" "stdout: the report"
  assert_eq "wrote docs/ledger/ledgers.proposed.json" "$(printf '%s\n' "$LG_OUT" | sed -n 2p)" "stdout: the proposal"
  assert_eq "3" "$(printf '%s\n' "$LG_OUT" | grep -c .)" "three lines: two files and a summary"
  assert_file_not_exists docs/ledger/init-report.md.decisions.tsv "no registry: no decisions file"
  assert_contains "$(cat docs/ledger/init-report.md)" "--registry docs/ledger/ledgers.proposed.json" "the report says how to re-run"
  # Its sections, in order.
  assert_eq "## Sources|## Hand-written ledgers|## Registry|## Registry findings|## Assignment summary|## Next steps" \
    "$(grep '^## ' docs/ledger/init-report.md | paste -sd '|' -)" "the report's sections, in order"
  # With --registry: the decisions file; no proposal written.
  rm -f docs/ledger/init-report.md docs/ledger/ledgers.proposed.json
  lg_init_edit_reg
  lg init --report docs/ledger/init-report.md --registry docs/ledger/edited.json --format json
  assert_eq "0" "$LG_RC" "--registry: exits 0"
  assert_eq "?? docs/ledger/edited.json
?? docs/ledger/init-report.md
?? docs/ledger/init-report.md.decisions.tsv" "$(lg_init_status)" "the report and the decisions file"
  assert_json_field "$LG_OUT" '[.report, .decisions, (.proposed | tostring)] | join("|")' \
    "docs/ledger/init-report.md|docs/ledger/init-report.md.decisions.tsv|null" "JSON: report, decisions, no proposal"
  # ledgers.json present: used, never rewritten, no proposal.
  rm -f docs/ledger/init-report.md docs/ledger/init-report.md.decisions.tsv docs/ledger/edited.json
  lg_registry "$LG_INIT_REG"
  git add -A && git commit -qm registry
  local before
  before=$(cksum < docs/ledger/ledgers.json || true)
  lg init --report docs/ledger/init-report.md
  assert_eq "0" "$LG_RC" "ledgers.json present: exits 0"
  assert_eq "$before" "$(cksum < docs/ledger/ledgers.json)" "ledgers.json unchanged"
  assert_eq "?? docs/ledger/init-report.md
?? docs/ledger/init-report.md.decisions.tsv" "$(lg_init_status)" "no proposal beside a registry"
  assert_contains "$(sed -n '/^## Registry$/,/^## Registry findings/p' docs/ledger/init-report.md)" "docs/ledger/ledgers.json" \
    "the report names the registry it used"
  teardown
}

test_lg_init_registry_proposal_mece() {
  echo "test: the proposal — one ledger per top-level code dir, the >40 % dir split by second-level dir with a residual ledger, platform kinds, slug ids with collisions; MECE (validate --registry: only root files and non-CI dot-dirs unowned)"
  lg_init_fixture
  local f
  for f in app/server/x.ts tests/unit.sh 'Weird Name!/x.ts' a-very-long-directory-name/x.ts docs/tool.py; do
    mkdir -p "$(dirname "$f")"
    printf 'x\n' > "$f"
  done
  git add -A && git commit -qm more
  lg init --report docs/ledger/r.md
  assert_eq "0" "$LG_RC" "exits 0"
  local p=docs/ledger/ledgers.proposed.json
  assert_eq "$(jq -S . "$p")" "$(cat "$p")" "jq -S formatting (sorted keys, 2-space indent)"
  assert_json_field "$(cat "$p")" '.schema' "ledger-registry/1" "schema"
  assert_eq ".github/**|github|platform||.github
Weird Name!/**|weird-name|service||Weird Name!
a-very-long-directory-name/**|a-very-long-dire|service||a-very-long-directory-name
app/checkout/**|checkout|service||checkout
app/profile/**|profile|service||profile
app/server/**|server-2|service||server
scripts/**|scripts|platform||scripts
server/**|server|service||server
src/**|src|service||src
tests/**|tests|platform||tests
|app|service|app/**|app" \
    "$(jq -r '.ledgers[] | "\(.paths | join(","))|\(.id)|\(.kind)|\(.residual_paths | join(","))|\(.title)"' "$p" | LC_ALL=C sort)" \
    "paths|id|kind|residual_paths|title of each ledger (top-level ids first: app/server takes server-2)"
  assert_json_field "$(cat "$p")" '[.ledgers[] | .status] | unique | join(",")' "active" "every ledger active"
  assert_json_field "$(cat "$p")" '[.ledgers[] | .id | length <= 16] | all' "true" "ids within 16 characters"
  # MECE: the proposal as the registry — overlap never; unowned only the
  # root file and the non-CI dot-dir.
  cp "$p" docs/ledger/ledgers.json
  lg_enable
  lg validate --registry
  assert_eq "1" "$LG_RC" "validate --registry: the unowned findings"
  assert_eq "registry unowned .vscode/settings.json
registry unowned Makefile" "$LG_OUT" "only the root file and the non-CI dot-dir are unowned"
  assert_contains "$(sed -n '/^## Registry findings/,/^## Assignment/p' docs/ledger/r.md)" "unowned Makefile" \
    "the report carries the proposal's findings"
  teardown
}

test_lg_init_registry_hints_and_contracts() {
  echo "test: the proposal's hints (component/area, hand-written ledger names, labels) per ledger; initial contracts from the contracts adapter when every defined_in falls in one ledger"
  lg_init_fixture
  mkdir -p docs/archive
  cat > docs/archive/tier1-pipeline-ledger.md <<'EOF'
| # | Step | State |
|---|------|-------|
| 1 | Ingest | done |
EOF
  # legacy_ledgers names both ledgers (naming any, it names them all: U2a).
  lg_enable '{"adapters":{"contracts":"tools/contracts.sh"},"legacy_ledgers":{"tier1":"docs/archive/tier1-pipeline-ledger.md","checkout":"docs/ledgers/checkout-ledger.md"}}'
  # shellcheck disable=SC2016  # the adapter's own shell text
  lg_contracts_adapter 'case "$1" in
list) echo "{\"id\":\"field:order.total\",\"ledger\":null,\"defined_in\":[\"server/orders/model.*\"]}"
      echo "{\"id\":\"component:CheckoutSheet\",\"ledger\":null,\"defined_in\":[\"app/checkout/CheckoutSheet.*\"]}"
      echo "{\"id\":\"api:cross\",\"ledger\":null,\"defined_in\":[\"server/orders/api.ts\",\"app/checkout/Cart.ts\"]}"
      echo "{\"id\":\"flag:root\",\"ledger\":null,\"defined_in\":[\"app/main.ts\"]}" ;;
esac'
  lg init --report docs/ledger/r.md
  assert_eq "0" "$LG_RC" "exits 0"
  local p=docs/ledger/ledgers.proposed.json r
  assert_json_field "$(cat "$p")" '[.ledgers[] | select(.contracts | length > 0) | "\(.id)=\([.contracts[] | "\(.id)@\(.defined_in | join(","))"] | join(";"))"] | join(" ")' \
    "app=flag:root@app/main.ts checkout=component:CheckoutSheet@app/checkout/CheckoutSheet.* server=field:order.total@server/orders/model.*" \
    "contracts placed by defined_in (the residual ledger takes app/main.ts)"
  r=$(cat docs/ledger/r.md 2>/dev/null || true)
  assert_contains "$r" "api:cross" "a contract spanning two ledgers is named, unplaced"
  assert_contains "$(printf '%s\n' "$r" | grep '^- `checkout`')" 'component "Checkout"' "checkout's hints: the item component"
  assert_contains "$(printf '%s\n' "$r" | grep '^- `checkout`')" 'hand-written ledger "checkout"' "checkout's hints: the hand-written ledger"
  assert_contains "$(printf '%s\n' "$r" | grep '^- `profile`')" 'area "profile"' "profile's hints: the item area"
  assert_contains "$r" 'hand-written ledger "tier1"' "a legacy_ledgers id is a hint too (no ledger matches it)"
  # Hand-written ledgers: the two configured ones (one archived).
  local hw
  hw=$(sed -n '/^## Hand-written ledgers/,/^## Registry$/p' docs/ledger/r.md 2>/dev/null || true)
  assert_contains "$hw" '`docs/ledgers/checkout-ledger.md` — `checkout`: 3 rows; 2 link items, 1 plans, 0 specs' "the checkout ledger, its id and counts"
  assert_contains "$hw" '`docs/archive/tier1-pipeline-ledger.md` — `tier1`: 1 rows; 0 link items, 0 plans, 0 specs' "legacy_ledgers: always included, with its configured id"
  # The registry is a proposal only: hints never change it.
  assert_json_field "$(cat "$p")" '[.ledgers[] | keys[]] | unique | join(",")' "contracts,id,kind,paths,residual_paths,status,title" "the ledger objects' keys"
  teardown
}

test_lg_init_assignment_reasons() {
  echo "test: assignment suggestions, first match wins — registered ledger value, hand-written membership, plurality of paths, (labels: github test), none"
  lg_init_fixture
  lg_init_edit_reg
  lg init --report docs/ledger/r.md --registry docs/ledger/edited.json
  assert_eq "0" "$LG_RC" "exits 0"
  assert_eq "docs/issues/2026-01-01-cart-total.md	open	checkout	ledger-field	-
docs/issues/2026-01-02-sheet-flicker.md	open	checkout	legacy:docs/ledgers/checkout-ledger.md#3	-
docs/issues/2026-01-03-order-sync.md	open	orders	paths:orders 1/1	-
docs/issues/2026-01-04-old-bug.md	fixed	checkout	legacy:docs/ledgers/checkout-ledger.md#1	checkout
docs/issues/2026-01-05-misc.md	open	unassigned	none	-
docs/issues/2026-01-06-wontfix.md	wontfix	unassigned	none	unassigned" \
    "$(lg_init_rows docs/ledger/r.md.decisions.tsv)" "one row per item, each with its reason"
  # The summary counts.
  assert_contains "$(cat docs/ledger/r.md)" "| checkout | 3 |" "summary: by suggestion"
  # An id the registry does not hold is no suggestion: the ledger value and
  # the hand-written membership fall through.
  lg_init_edit_reg '{"schema":"ledger-registry/1","ledgers":[{"id":"orders","title":"Orders","kind":"service","status":"active","paths":["server/orders/**"]}]}'
  lg init --report docs/ledger/r.md --registry docs/ledger/edited.json --format json
  assert_eq "0" "$LG_RC" "exits 0"
  assert_eq "docs/issues/2026-01-01-cart-total.md	unassigned	none
docs/issues/2026-01-02-sheet-flicker.md	unassigned	none
docs/issues/2026-01-03-order-sync.md	orders	paths:orders 1/1" \
    "$(lg_init_rows docs/ledger/r.md.decisions.tsv | cut -f 1,3,4 | sed -n 1,3p)" "unregistered ids are not suggested"
  assert_json_field "$LG_OUT" '[.counts.items, .counts.by_reason.none, .counts.by_reason.paths] | map(tostring) | join("|")' \
    "6|5|1" "JSON counts"
  teardown
}

test_lg_init_hub_files_downweighted() {
  echo "test: paths plurality skips hub files (cited by > 5 % of items) and ties"
  lg_fixture
  local i
  for i in $(seq 1 36); do
    lg_item "docs/issues/i$i.md" 'status: Open'
  done
  lg_item docs/issues/a.md 'status: Open' 'related-files: [shared/hub.ts, server/orders/model.ts]'
  lg_item docs/issues/b.md 'status: Open' 'related-files: [shared/hub.ts]'
  lg_item docs/issues/c.md 'status: Open' 'related-files: [shared/hub.ts, shared/util.ts, server/orders/api.ts]'
  lg_item docs/issues/d.md 'status: Open' 'code_refs: [server/orders/api.ts]'
  mkdir -p shared server/orders
  printf 'x\n' > shared/hub.ts
  printf 'x\n' > shared/util.ts
  printf 'x\n' > server/orders/model.ts
  printf 'x\n' > server/orders/api.ts
  git add -A && git commit -qm items
  lg_init_edit_reg '{"schema":"ledger-registry/1","ledgers":[
    {"id":"shared","title":"Shared","kind":"platform","status":"active","paths":["shared/**"]},
    {"id":"orders","title":"Orders","kind":"service","status":"active","paths":["server/orders/**"]}]}'
  lg init --report docs/ledger/r.md --registry docs/ledger/edited.json
  assert_eq "0" "$LG_RC" "exits 0"
  assert_eq "docs/issues/a.md	orders	paths:orders 1/1
docs/issues/b.md	unassigned	none
docs/issues/c.md	unassigned	none
docs/issues/d.md	orders	paths:orders 1/1" \
    "$(lg_init_rows docs/ledger/r.md.decisions.tsv | grep -v '/i[0-9]' | cut -f 1,3,4)" \
    "a: the hub skipped, orders wins; b: only a hub; c: a tie; d: a file 2 of 40 items cite (5 %) is no hub"
  assert_contains "$(cat docs/ledger/r.md)" '`shared/hub.ts` (3 items)' "the report names the hub file"
  teardown
}

test_lg_init_decisions_prefill() {
  echo "test: the decision column — pre-filled with the suggestion for terminal items only; class unknown when no class matches"
  lg_init_fixture
  lg_item docs/issues/2026-01-07-parked.md 'status: Parked'
  lg_item docs/issues/2026-01-08-closed.md 'status: Closed' 'ledger: orders'
  git add -A && git commit -qm more
  lg_init_edit_reg
  lg init --report docs/ledger/r.md --registry docs/ledger/edited.json
  assert_eq "0" "$LG_RC" "exits 0"
  assert_eq "docs/issues/2026-01-01-cart-total.md	open	-
docs/issues/2026-01-02-sheet-flicker.md	open	-
docs/issues/2026-01-03-order-sync.md	open	-
docs/issues/2026-01-04-old-bug.md	fixed	checkout
docs/issues/2026-01-05-misc.md	open	-
docs/issues/2026-01-06-wontfix.md	wontfix	unassigned
docs/issues/2026-01-07-parked.md	unknown	-
docs/issues/2026-01-08-closed.md	closed	orders" \
    "$(lg_init_rows docs/ledger/r.md.decisions.tsv | cut -f 1,2,5)" "terminal (fixed, closed, wontfix): the suggestion; open and unknown: empty"
  assert_eq "5" "$(lg_init_rows docs/ledger/r.md.decisions.tsv | awk -F '\t' '{ print NF }' | sort -u)" "five columns on every row"
  teardown
}

test_lg_init_decisions_header() {
  echo "test: the decisions file's header (R5) — title, the registry's path and sha256, the column names; rows sorted (C locale); a path with a tab is left out and named"
  lg_init_fixture
  lg_item "docs/issues/tab	name.md" 'status: Open'
  lg_item "docs/issues/new
line.md" 'status: Open'
  lg_item docs/issues/Zeta.md 'status: Open'
  git add -A && git commit -qm awkward
  lg_init_edit_reg
  lg init --report docs/ledger/r.md --registry docs/ledger/edited.json
  assert_eq "0" "$LG_RC" "exits 0"
  local sha
  sha=$( (shasum -a 256 2>/dev/null || sha256sum) < docs/ledger/edited.json | cut -d ' ' -f 1 || true)
  assert_eq "# ledger init decisions
# registry: docs/ledger/edited.json $sha
# path	class	suggestion	reason	decision" "$(sed -n 1,3p docs/ledger/r.md.decisions.tsv)" "the three header lines"
  assert_eq "3" "$(grep -c '^#' docs/ledger/r.md.decisions.tsv)" "no other '#' line"
  assert_eq "docs/issues/2026-01-01-cart-total.md" "$(lg_init_rows docs/ledger/r.md.decisions.tsv | sed -n 1p | cut -f 1)" "C order: digits first"
  assert_eq "docs/issues/Zeta.md" "$(lg_init_rows docs/ledger/r.md.decisions.tsv | sed -n '$p' | cut -f 1)" "C order: an uppercase name after digits"
  assert_eq "0" "$(lg_init_rows docs/ledger/r.md.decisions.tsv | grep -c 'tab')" "the path with a tab is not written"
  assert_contains "$(cat docs/ledger/r.md)" 'docs/issues/tab\tname.md' "the report names it"
  assert_eq "0" "$(lg_init_rows docs/ledger/r.md.decisions.tsv | grep -c -E 'new|^line')" "the path with a newline is not written"
  assert_contains "$(cat docs/ledger/r.md)" 'docs/issues/new\nline.md' "the report names it"
  # ledgers.json: its path on the registry line.
  cp docs/ledger/edited.json docs/ledger/ledgers.json
  lg init --report docs/ledger/r.md
  assert_eq "# registry: docs/ledger/ledgers.json $sha" "$(sed -n 2p docs/ledger/r.md.decisions.tsv)" "ledgers.json named when used"
  teardown
}

test_lg_init_github_source() {
  echo "test: GitHub as a source — --sources github or items.adapter, gh repo view hasIssuesEnabled; hosted items by ref; a ledger: label suggests; labels are hints"
  lg_init_fixture
  lg_fake_gh
  printf '%s\n' '[{"number":7,"title":"Two ledger labels","body":"","state":"OPEN","stateReason":null,"labels":[{"name":"ledger:checkout"},{"name":"ledger:old"}],"updatedAt":"2026-10-01T10:00:00Z","url":"https://github.com/o/r/issues/7"},
{"number":8,"title":"Done","body":"","state":"CLOSED","stateReason":"COMPLETED","labels":[{"name":"profile"}],"updatedAt":"2026-10-02T10:00:00Z","closedAt":"2026-10-02T09:00:00Z","url":"https://github.com/o/r/issues/8"}]' > "$LG_GH/issues.json"
  lg_init_edit_reg
  lg init --report docs/ledger/r.md --registry docs/ledger/edited.json --sources files,github --format json
  assert_eq "0" "$LG_RC" "exits 0"
  assert_contains "$(cat "$LG_GH/args")" "repo view --json hasIssuesEnabled" "gh repo view checks the issues"
  assert_eq "1" "$(lg_gh_icalls)" "one issue list"
  assert_json_field "$LG_OUT" '[.sources.github.state, .sources.github.items] | map(tostring) | join("|")' "on|2" "JSON: GitHub on, 2 hosted items"
  assert_eq "gh#7	open	checkout	label	-
gh#8	fixed	unassigned	none	unassigned" "$(lg_init_rows docs/ledger/r.md.decisions.tsv | grep '^gh#')" \
    "hosted items by ref; one registered ledger: label suggests (two make the ledger field a list)"
  assert_eq "6" "$(lg_init_rows docs/ledger/r.md.decisions.tsv | grep -c '^docs/')" "the file items too"
  assert_contains "$(cat docs/ledger/r.md)" 'label "profile"' "labels are hints"
  assert_contains "$(sed -n '/^## Sources/,/^## Hand-written/p' docs/ledger/r.md)" "GitHub: on" "the report: GitHub on"
  # --sources github alone: no file items.
  lg init --report docs/ledger/r.md --registry docs/ledger/edited.json --sources github
  assert_eq "0" "$LG_RC" "github only: exits 0"
  assert_eq "gh#7
gh#8" "$(lg_init_rows docs/ledger/r.md.decisions.tsv | cut -f 1)" "github only: the hosted items alone"
  # items.adapter configured: GitHub by default; --sources files turns it off.
  lg_enable '{"items":{"adapter":"doc-superpowers:ledger-items-gh"}}'
  lg init --report docs/ledger/r.md --registry docs/ledger/edited.json
  assert_eq "0" "$LG_RC" "default with items.adapter: exits 0"
  assert_eq "2" "$(lg_init_rows docs/ledger/r.md.decisions.tsv | grep -c '^gh#')" "items.adapter: GitHub on by default"
  : > "$LG_GH/args"
  lg init --report docs/ledger/r.md --registry docs/ledger/edited.json --sources files
  assert_eq "0" "$(lg_init_rows docs/ledger/r.md.decisions.tsv | grep -c '^gh#')" "--sources files: no hosted items"
  assert_eq "" "$(cat "$LG_GH/args")" "--sources files: gh never runs"
  lg_fake_gh_off
  teardown
}

test_lg_init_github_failure_explicit_vs_default() {
  echo "test: GitHub unavailable — explicit --sources github exits 2 with the reason; reached by default (items.adapter) it is reported and skipped (0)"
  lg_init_fixture
  lg_fake_gh
  : > "$LG_GH/issues-off"
  lg init --report docs/ledger/r.md --sources files,github
  assert_eq "2" "$LG_RC" "explicit, issues disabled: exits 2"
  assert_contains "$LG_ERR" "issues" "stderr gives the reason"
  assert_file_not_exists docs/ledger/r.md "nothing written"
  rm -f "$LG_GH/issues-off"
  printf 'gh: To get started with GitHub CLI, please run:  gh auth login\n' > "$LG_GH/fail"
  lg init --report docs/ledger/r.md --sources github --format json
  assert_eq "2" "$LG_RC" "explicit, gh unauthenticated: exits 2"
  assert_json_field "$LG_OUT" '.error | test("gh auth login")' "true" "the reason carries gh's message"
  # By default (items.adapter set): skipped, reported, rc 0.
  lg_enable '{"items":{"adapter":"doc-superpowers:ledger-items-gh"}}'
  lg init --report docs/ledger/r.md --format json
  assert_eq "0" "$LG_RC" "default: exits 0"
  assert_json_field "$LG_OUT" '[.sources.github.state, (.sources.github.reason | test("gh auth login"))] | map(tostring) | join("|")' \
    "skipped|true" "JSON: skipped, with the reason"
  assert_contains "$(sed -n '/^## Sources/,/^## Hand-written/p' docs/ledger/r.md)" "GitHub: skipped" "the report says it was skipped"
  assert_eq "0" "$(lg_gh_icalls)" "no issue list after a failed check"
  lg_fake_gh_off
  teardown
}

test_lg_init_sources_suggestions() {
  echo "test: sources — the item globs, a suggested glob for a dir with >= 3 status: files (not added), hand-written ledgers detected by their table"
  lg_init_fixture
  lg init --report docs/ledger/r.md --format json
  assert_eq "0" "$LG_RC" "exits 0"
  assert_json_field "$LG_OUT" '.sources.files.suggested | map("\(.glob)=\(.files)") | join(",")' "docs/notes/*.md=3" \
    "docs/notes/ suggested (3 files); docs/plans/ (1) not"
  assert_json_field "$LG_OUT" '.sources.files.globs | join(",")' "docs/issues/*.md" "the item globs"
  assert_json_field "$LG_OUT" '.sources.ledgers | map("\(.file)=\(.id)") | join(",")' "docs/ledgers/checkout-ledger.md=checkout" \
    "the hand-written ledger (the plan and the notes have no such table)"
  assert_contains "$(sed -n '/^## Sources/,/^## Hand-written/p' docs/ledger/r.md)" '`docs/notes/*.md`' "the report suggests the glob"
  assert_file_not_exists docs/ledger/config.json "a suggestion is not added"
  teardown
}

# --- Task 14 fix round 1 ---------------------------------------------------------

# lg_init_decide <decisions.tsv> <path> <value>: fill in one row's decision.
lg_init_decide() {
  awk -F '\t' -v OFS='\t' -v p="$2" -v v="$3" '!/^#/ && $1 == p { $5 = v } { print }' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

test_lg_init_decisions_kept_across_reruns() {
  echo "test: a re-run keeps the decisions already filled in (by path, while still valid in the current registry), drops and names the others, keeps the previous file as .bak, and adds new items"
  lg_init_fixture
  lg_init_edit_reg
  lg init --report docs/ledger/r.md --registry docs/ledger/edited.json
  assert_eq "0" "$LG_RC" "first run exits 0"
  local d=docs/ledger/r.md.decisions.tsv
  lg_init_decide "$d" docs/issues/2026-01-01-cart-total.md checkout
  lg_init_decide "$d" docs/issues/2026-01-05-misc.md orders
  lg_init_decide "$d" docs/issues/2026-01-03-order-sync.md unassigned
  lg_init_decide "$d" docs/issues/2026-01-04-old-bug.md unassigned
  local filled
  filled=$(cat "$d")
  # orders leaves the registry; a new item arrives.
  lg_init_edit_reg '{"schema":"ledger-registry/1","ledgers":[{"id":"checkout","title":"Checkout","kind":"service","status":"active","paths":["app/checkout/**"]}]}'
  lg_item docs/issues/2026-01-09-new.md 'status: Open'
  git add -A && git commit -qm new
  lg init --report docs/ledger/r.md --registry docs/ledger/edited.json --format json
  assert_eq "0" "$LG_RC" "re-run exits 0"
  assert_eq "docs/issues/2026-01-01-cart-total.md	checkout
docs/issues/2026-01-02-sheet-flicker.md	-
docs/issues/2026-01-03-order-sync.md	unassigned
docs/issues/2026-01-04-old-bug.md	unassigned
docs/issues/2026-01-05-misc.md	-
docs/issues/2026-01-06-wontfix.md	unassigned
docs/issues/2026-01-09-new.md	-" "$(lg_init_rows "$d" | cut -f 1,5)" \
    "kept: checkout, unassigned (an open item's and a terminal one's over its pre-fill); dropped: orders; the new item added"
  assert_eq "$filled" "$(cat "$d.bak" 2>/dev/null)" "the previous file is kept as .bak"
  assert_json_field "$LG_OUT" '[.counts.kept, .counts.dropped] | map(tostring) | join("|")' "3|1" \
    "JSON: 3 kept (filled in; the won't-fix item's pre-fill is recomputed, Task 15 R9), 1 dropped"
  local r
  r=$(cat docs/ledger/r.md)
  assert_contains "$r" '`docs/issues/2026-01-05-misc.md` (`orders`: not a registered ledger id)' "the report names the dropped decision, its value and why"
  # A third run: the .bak is overwritten with the second run's file.
  local second
  second=$(cat "$d")
  lg init --report docs/ledger/r.md --registry docs/ledger/edited.json
  assert_eq "$second" "$(cat "$d.bak")" ".bak overwritten on each run"
  assert_eq "$second" "$(cat "$d")" "an unchanged re-run changes nothing"
  teardown
}

test_lg_init_report_path_guard() {
  echo "test: --report (and its decisions file) never lands on ledgers.json, config.json, legacy.json, the proposal or the --registry file — whatever the spelling (./, //, .., symlinks): exit 3"
  lg_init_fixture
  lg_registry "$LG_INIT_REG"
  lg_init_edit_reg
  git add docs/ledger/ledgers.json && git commit -qm registry
  local before reg_before
  before=$(cksum < docs/ledger/ledgers.json)
  reg_before=$(cksum < docs/ledger/edited.json)
  lg init --report ./docs/ledger/ledgers.json
  assert_eq "3" "$LG_RC" "./docs/ledger/ledgers.json: exits 3"
  lg init --report docs//ledger/./config.json
  assert_eq "3" "$LG_RC" "docs//ledger/./config.json: exits 3"
  lg init --report docs/issues/../ledger/legacy.json
  assert_eq "3" "$LG_RC" "docs/issues/../ledger/legacy.json: exits 3"
  lg init --report ./docs/ledger/ledgers.proposed.json
  assert_eq "3" "$LG_RC" "the proposal path: exits 3"
  lg init --report docs/ledger/edited.json --registry ./docs/ledger/edited.json
  assert_eq "3" "$LG_RC" "the --registry file: exits 3"
  lg init --report docs/ledger/r.md --registry docs/ledger/r.md.decisions.tsv
  assert_eq "3" "$LG_RC" "the decisions path onto the --registry file: exits 3"
  ln -s ledger docs/lnk
  lg init --report docs/lnk/config.json
  assert_eq "3" "$LG_RC" "through a symlinked directory: exits 3"
  ln -s ledgers.json docs/ledger/alias.md
  lg init --report docs/ledger/alias.md --format json
  assert_eq "3" "$LG_RC" "a symlink to ledgers.json: exits 3"
  assert_eq "1" "$(json_count "$LG_OUT")" "JSON: one object"
  assert_eq "$before" "$(cksum < docs/ledger/ledgers.json)" "ledgers.json untouched"
  assert_eq "$reg_before" "$(cksum < docs/ledger/edited.json)" "the --registry file untouched"
  assert_file_not_exists docs/ledger/config.json "no config.json"
  assert_file_not_exists docs/ledger/legacy.json "no legacy.json"
  teardown
}

test_lg_init_hub_floor() {
  echo "test: the hub floor (ratified) — a path one item cites is never a hub, even above 5 %; two items above 5 % make one"
  lg_fixture
  local i
  for i in 1 2 3 4 5 6 7; do
    lg_item "docs/issues/i$i.md" 'status: Open'
  done
  lg_item docs/issues/a.md 'status: Open' 'related-files: [server/orders/model.ts]'
  lg_item docs/issues/b.md 'status: Open' 'related-files: [shared/hub.ts]'
  lg_item docs/issues/c.md 'status: Open' 'related-files: [shared/hub.ts, server/orders/api.ts]'
  git add -A && git commit -qm items
  lg_init_edit_reg '{"schema":"ledger-registry/1","ledgers":[
    {"id":"shared","title":"Shared","kind":"platform","status":"active","paths":["shared/**"]},
    {"id":"orders","title":"Orders","kind":"service","status":"active","paths":["server/orders/**"]}]}'
  lg init --report docs/ledger/r.md --registry docs/ledger/edited.json
  assert_eq "0" "$LG_RC" "exits 0"
  assert_eq "docs/issues/a.md	orders	paths:orders 1/1
docs/issues/b.md	unassigned	none
docs/issues/c.md	orders	paths:orders 1/1" "$(lg_init_rows docs/ledger/r.md.decisions.tsv | grep -v '/i[0-9]' | cut -f 1,3,4)" \
    "a: 1 of 10 items (10 %) is no hub; b, c: 2 of 10 is"
  assert_contains "$(cat docs/ledger/r.md)" '`shared/hub.ts` (2 items)' "the report names the hub"
  assert_not_contains "$(cat docs/ledger/r.md)" '`server/orders/model.ts` (1 item)' "not the path one item cites"
  teardown
}

test_lg_init_crash_fallback_not_enabled() {
  echo "test: init without config.json — the crash fallback's object says enabled false (ratified)"
  lg_init_fixture
  DOC_TOOLS_LEDGER_SELFTEST=unset-var lg init --report docs/ledger/r.md --format json
  assert_contains "$LG_ERR" "unbound variable" "precondition: the run crashed on an unset variable"
  assert_eq "2" "$LG_RC" "exits 2"
  assert_eq "1" "$(json_count "$LG_OUT")" "exactly one object"
  assert_json_field "$LG_OUT" '[.verb, .enabled, .exit, .error] | map(tostring) | join("|")' "ledger init|false|2|internal" \
    "the fallback object: enabled false"
  teardown
}

test_lg_init_custom_items_adapter_no_gh() {
  echo "test: a custom items.adapter is listed through itself — no gh repo view probe (it runs only for the reference gh adapter or none)"
  lg_init_fixture
  lg_fake_gh
  printf 'gh must not run\n' > "$LG_GH/fail"
  mkdir -p tools
  # shellcheck disable=SC2016  # the adapter's own shell text
  printf '#!/bin/sh\ncase "$1" in\nlist) echo %s ;;\nesac\n' \
    "'{\"ref\":\"jira#5\",\"url\":\"https://jira.example/5\",\"status\":\"Open\",\"fields\":{\"ledger\":\"orders\"},\"labels\":[]}'" > tools/items.sh
  chmod +x tools/items.sh
  lg_enable '{"items":{"adapter":"tools/items.sh"}}'
  lg_init_edit_reg
  lg init --report docs/ledger/r.md --registry docs/ledger/edited.json --format json
  assert_eq "0" "$LG_RC" "default (items.adapter set): exits 0"
  assert_json_field "$LG_OUT" '[.sources.github.state, .sources.github.adapter] | join("|")' "on|tools/items.sh" "the custom adapter is on"
  assert_eq "jira#5	open	orders	ledger-field	-" "$(lg_init_rows docs/ledger/r.md.decisions.tsv | grep '^jira#')" "its item, by ref"
  lg init --report docs/ledger/r.md --registry docs/ledger/edited.json --sources files,github
  assert_eq "0" "$LG_RC" "explicit --sources github with the custom adapter: exits 0"
  assert_eq "" "$(cat "$LG_GH/args" 2>/dev/null)" "gh never ran"
  lg_fake_gh_off
  teardown
}

test_lg_init_legacy_rows_and_links() {
  echo "test: hand-written ledger rows — a legacy_ledgers id (path with a space and unicode), /-rooted links with ?query#anchor, <…> links, an empty # cell as n<ordinal>, the lowest row by number"
  lg_init_fixture
  mkdir -p "docs/led gers ü"
  cat > "docs/led gers ü/my-ledger.md" <<'EOF'
| # | Item |
|---|------|
| 1 | [misc](/docs/issues/2026-01-05-misc.md?x=1#y) |
|   | [won't fix](../issues/2026-01-06-wontfix.md) |
| 10 | [sheet](<../issues/2026-01-02-sheet-flicker.md> "t") |
| 9 | [sheet again](../issues/2026-01-02-sheet-flicker.md) |
EOF
  git add -A && git commit -qm ledger
  lg_enable '{"legacy_ledgers":{"orders":"docs/led gers ü/my-ledger.md"}}'
  lg_init_edit_reg
  lg init --report docs/ledger/r.md --registry docs/ledger/edited.json
  assert_eq "0" "$LG_RC" "exits 0"
  assert_eq "docs/issues/2026-01-02-sheet-flicker.md	orders	legacy:docs/led gers ü/my-ledger.md#9
docs/issues/2026-01-05-misc.md	orders	legacy:docs/led gers ü/my-ledger.md#1
docs/issues/2026-01-06-wontfix.md	orders	legacy:docs/led gers ü/my-ledger.md#n2" \
    "$(lg_init_rows docs/ledger/r.md.decisions.tsv | grep -E 'sheet|misc|wontfix' | cut -f 1,3,4)" \
    "membership through the configured id; #9 before #10 (numeric); the empty cell is n2; /-rooted and <…> links resolve"
  assert_contains "$(cat docs/ledger/r.md)" '`docs/led gers ü/my-ledger.md` — `orders`: 4 rows; 4 link items' "the ledger listed with its configured id"
  teardown
}

test_lg_init_split_boundary_40() {
  echo "test: the split — exactly 40 % of the code files is not split; more than 40 % is"
  lg_fixture
  local f
  for f in app/a/x.ts app/b/y.ts app/c/z.ts app/d/w.ts server/s1.ts server/s2.ts server/s3.ts scripts/a.sh scripts/b.sh; do
    mkdir -p "$(dirname "$f")"
    printf 'x\n' > "$f"
  done
  git add -A && git commit -qm code
  lg init --report docs/ledger/r.md
  assert_eq "0" "$LG_RC" "exits 0"
  assert_eq "app|app/**" "$(jq -r '.ledgers[] | select(.title == "app") | "\(.id)|\(.paths | join(","))"' docs/ledger/ledgers.proposed.json)" \
    "4 of 10 (40 %): app is one ledger"
  mkdir -p app/e
  printf 'x\n' > app/e/v.ts
  git add -A && git commit -qm more
  lg init --report docs/ledger/r.md
  assert_eq "app||app/**" "$(jq -r '.ledgers[] | select(.title == "app") | "\(.id)|\(.paths | join(","))|\(.residual_paths | join(","))"' docs/ledger/ledgers.proposed.json)" \
    "5 of 11 (45 %): split, app keeps the residual"
  assert_eq "5" "$(jq '[.ledgers[] | select(.paths[0] // "" | startswith("app/"))] | length' docs/ledger/ledgers.proposed.json)" "one ledger per second-level dir"
  teardown
}

# --- Task 15 R9: carry from the Task 14 review ----------------------------------

# lg_mode <file>: its permission string (ls -l's first 10 characters).
lg_mode() {
  ls -l -- "$1" | cut -c 1-10
}

test_lg_init_files_umask_mode() {
  echo "test: init's files get the mode a new file gets under the umask (022 → -rw-r--r--), not mktemp's 0600"
  lg_init_fixture
  lg_init_edit_reg
  local m
  m=$(umask)
  umask 022
  lg init --report docs/ledger/r.md --registry docs/ledger/edited.json
  umask "$m"
  assert_eq "0" "$LG_RC" "exits 0"
  assert_eq "-rw-r--r--" "$(lg_mode docs/ledger/r.md)" "the report: 0644"
  assert_eq "-rw-r--r--" "$(lg_mode docs/ledger/r.md.decisions.tsv)" "the decisions file: 0644"
  rm -f docs/ledger/edited.json
  umask 027
  lg init --report docs/ledger/r2.md
  umask "$m"
  assert_eq "-rw-r-----" "$(lg_mode docs/ledger/ledgers.proposed.json)" "the proposal under umask 027: 0640"
  teardown
}

test_lg_init_guard_same_file() {
  echo "test: the report guard refuses any name of a protected file — a hard link, and another case on a case-insensitive file system (SKIP on a case-sensitive one)"
  lg_init_fixture
  lg_registry "$LG_INIT_REG"
  git add docs/ledger/ledgers.json && git commit -qm registry
  local before
  before=$(cksum < docs/ledger/ledgers.json)
  ln docs/ledger/ledgers.json docs/ledger/hard.md
  lg init --report docs/ledger/hard.md
  assert_eq "3" "$LG_RC" "a hard link to ledgers.json: exits 3"
  assert_contains "$LG_ERR" "the same file" "the message says why"
  rm -f docs/ledger/hard.md
  : > docs/ledger/ci-probe
  if [ -e docs/ledger/CI-PROBE ]; then
    lg init --report docs/ledger/LEDGERS.json
    assert_eq "3" "$LG_RC" "case-insensitive file system: docs/ledger/LEDGERS.json exits 3"
    lg init --report docs/LEDGER/Ledgers.json --format json
    assert_eq "3" "$LG_RC" "docs/LEDGER/Ledgers.json exits 3"
    assert_eq "1" "$(json_count "$LG_OUT")" "JSON: one object"
  else
    record_skip "case-sensitive file system here — the case-change bypass (LEDGERS.json) cannot happen, so it is not tested"
  fi
  assert_eq "$before" "$(cksum < docs/ledger/ledgers.json)" "ledgers.json untouched"
  rm -f docs/ledger/ci-probe
  teardown
}

test_lg_init_stale_prefill_recomputed() {
  echo "test: a re-run recomputes a terminal row's pre-fill (decision = suggestion): a won't-fix item pre-filled unassigned becomes checkout once checkout is registered"
  lg_init_fixture
  lg_item docs/issues/2026-01-07-wf.md "status: Won't Fix" 'ledger: checkout'
  git add -A && git commit -qm wf
  lg_init_edit_reg '{"schema":"ledger-registry/1","ledgers":[{"id":"orders","title":"Orders","kind":"service","status":"active","paths":["server/orders/**"]}]}'
  lg init --report docs/ledger/r.md --registry docs/ledger/edited.json
  assert_eq "0" "$LG_RC" "first run exits 0"
  local d=docs/ledger/r.md.decisions.tsv
  assert_eq "docs/issues/2026-01-07-wf.md	wontfix	unassigned	none	unassigned" "$(lg_init_rows "$d" | grep 'wf.md')" \
    "pre-filled unassigned (checkout is not registered yet)"
  # A terminal row the user changed is a decision: it stays.
  lg_init_decide "$d" docs/issues/2026-01-04-old-bug.md orders
  lg_init_edit_reg
  lg init --report docs/ledger/r.md --registry docs/ledger/edited.json --format json
  assert_eq "0" "$LG_RC" "re-run exits 0"
  assert_eq "docs/issues/2026-01-07-wf.md	wontfix	checkout	ledger-field	checkout" "$(lg_init_rows "$d" | grep 'wf.md')" \
    "the stale pre-fill is recomputed: checkout"
  assert_eq "docs/issues/2026-01-04-old-bug.md	orders" "$(lg_init_rows "$d" | grep 'old-bug' | cut -f 1,5)" \
    "a terminal row's changed decision is kept"
  assert_json_field "$LG_OUT" '[.counts.kept, .counts.dropped] | map(tostring) | join("|")' "1|0" "JSON: only the changed decision is kept"
  teardown
}

# --- Task 15: init --accept, --import ---------------------------------------------

# lg_add_fm <file> <line>: insert a frontmatter line after the opening ---.
lg_add_fm() {
  awk -v l="$2" 'NR == 1 { print; print l; next } { print }' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

# lg_fmblock <file>: its frontmatter lines (between the first two --- lines),
# "|"-joined.
lg_fmblock() {
  awk 'NR == 1 && /^---$/ { f = 1; next } f && /^---$/ { exit } f { print }' "$1" | paste -sd '|' -
}

# lg_accept_remote: a local bare remote "origin" (LG_REMOTE) holding main,
# fetched — origin/main, the default base, exists (as lg_keys_fixture).
lg_accept_remote() {
  LG_REMOTE=$(harness_mktemp_d remote).git
  git init -q --bare "$LG_REMOTE"
  git --git-dir="$LG_REMOTE" symbolic-ref HEAD refs/heads/main
  git remote add origin "$LG_REMOTE"
  git push -q origin main
  git fetch -q origin
}

# lg_accept_fixture: lg_init_fixture with each item dated (date: 2026-01-0N,
# its file name's day), the remote, and the report against LG_INIT_REG
# (docs/ledger/edited.json, untracked); LG_DEC is the decisions file. No
# config.json, no ledgers.json.
lg_accept_fixture() {
  local f
  lg_init_fixture
  for f in docs/issues/2026-01-0*.md; do
    lg_add_fm "$f" "date: $(basename "$f" | cut -c 1-10)"
  done
  git add -A && git commit -qm dated
  lg_accept_remote
  lg_init_edit_reg
  lg init --report docs/ledger/r.md --registry docs/ledger/edited.json
  LG_DEC=docs/ledger/r.md.decisions.tsv
}

# lg_today: today's date (local), as a stub's file name carries it.
lg_today() {
  date +%Y-%m-%d
}

test_lg_init_accept_only_decided_rows() {
  echo "test: init --accept applies only the rows with a decision — ledger, summary when missing, a key for an open item in a registered ledger; writes config.json ({}) and ledgers.json (the report's registry) when absent; rows left empty are untouched"
  lg_accept_fixture
  lg_init_decide "$LG_DEC" docs/issues/2026-01-01-cart-total.md checkout
  lg_init_decide "$LG_DEC" docs/issues/2026-01-03-order-sync.md orders
  local flicker misc
  flicker=$(cksum < docs/issues/2026-01-02-sheet-flicker.md)
  misc=$(cksum < docs/issues/2026-01-05-misc.md)
  lg init --accept "$LG_DEC"
  assert_eq "0" "$LG_RC" "exits 0"
  assert_eq "date: 2026-01-01|status: Open|ledger: checkout|summary: Totals drift|key: checkout-1" \
    "$(lg_fmblock docs/issues/2026-01-01-cart-total.md)" "cart-total: its key (ledger and summary were there)"
  assert_eq "date: 2026-01-03|status: In Progress|related-files: [server/orders/model.ts]|key: orders-1|ledger: orders|summary: 2026-01-03-order-sync" \
    "$(lg_fmblock docs/issues/2026-01-03-order-sync.md)" "order-sync: key, ledger, summary (its H1)"
  assert_eq "date: 2026-01-04|status: Resolved|ledger: checkout|summary: 2026-01-04-old-bug" \
    "$(lg_fmblock docs/issues/2026-01-04-old-bug.md)" "old-bug (fixed, pre-filled checkout): ledger and summary, no key"
  assert_eq "date: 2026-01-06|status: Won't Fix|area: profile|ledger: unassigned|summary: 2026-01-06-wontfix" \
    "$(lg_fmblock docs/issues/2026-01-06-wontfix.md)" "wontfix (pre-filled unassigned): ledger unassigned, no key"
  assert_eq "$flicker|$misc" "$(cksum < docs/issues/2026-01-02-sheet-flicker.md)|$(cksum < docs/issues/2026-01-05-misc.md)" \
    "the rows left empty: untouched"
  assert_eq "{}" "$(cat docs/ledger/config.json)" "config.json: {} (no hosted row)"
  assert_eq "$(cksum < docs/ledger/edited.json)" "$(cksum < docs/ledger/ledgers.json)" "ledgers.json: the report's registry, byte for byte"
  assert_eq '{"checkout":3,"orders":2}' "$(lg_remote_counters)" "counters: checkout-1 and the stub's checkout-2, orders-1"
  assert_contains "$LG_OUT" "docs/issues/2026-01-03-order-sync.md" "stdout names the items to review"
  assert_contains "$LG_OUT" "wrote docs/ledger/config.json" "stdout names config.json"
  assert_contains "$LG_OUT" "wrote docs/ledger/ledgers.json" "stdout names ledgers.json"
  teardown
}

test_lg_init_legacy_map_and_stub() {
  echo "test: legacy import — a row linking an item → {key} (or {item} without a key), an open row tracked by a plan → a stub item (file, status Open, the row's ledger, summary from the row, Migrated-from body), a done row without an item → {archived}"
  lg_accept_fixture
  cat >> docs/ledgers/checkout-ledger.md <<'EOF'
| 4 | Shipped thing | ~~Shipped~~ 2025 |
| 5 | **Retry queue** — [spec](../specs/retry.md) | DONE |
| 6 | **Rate limits are wrong for EU carts** — [plan](../plans/x-plan.md) | blocked |
EOF
  git add -A && git commit -qm rows
  lg_init_decide "$LG_DEC" docs/issues/2026-01-02-sheet-flicker.md checkout
  lg init --accept "$LG_DEC" --format json
  assert_eq "0" "$LG_RC" "exits 0"
  local t s1 s2
  t=$(lg_today)
  s1="docs/issues/$t-totals-plan.md"
  s2="docs/issues/$t-rate-limits-are-wrong-for-eu-carts.md"
  assert_file_exists "$s1" "row 2 (open, a plan): a stub"
  assert_file_exists "$s2" "row 6 (blocked, a plan): a stub"
  assert_eq "status: Open|key: checkout-3|ledger: checkout|summary: Totals plan" "$(lg_fmblock "$s1")" \
    "the stub: Open, the row's ledger (checkout: registered), the summary from the row's bold lead, a key"
  assert_contains "$(cat "$s1")" "Migrated from docs/ledgers/checkout-ledger.md row 2." "the stub's body names its row"
  assert_contains "$(cat "$s1")" '| 2 | **Totals plan** — [plan](../plans/x-plan.md) | open |' "and carries the row text"
  # sheet-flicker (2026-01-02) is the oldest checkout item: checkout-1; the
  # stubs (today) follow, by path: rate-limits… checkout-2, totals-plan checkout-3.
  assert_eq "checkout-1" "$(jq -r '.["checkout#3"].key' docs/ledger/legacy.json)" "row 3 → the linked item's key"
  assert_eq "docs/issues/2026-01-04-old-bug.md" "$(jq -r '.["checkout#1"].item' docs/ledger/legacy.json)" "row 1 (done, an item without a key) → {item}"
  assert_eq "checkout-3" "$(jq -r '.["checkout#2"].key' docs/ledger/legacy.json)" "row 2 → the stub's key"
  assert_eq "docs/ledgers/checkout-ledger.md#4" "$(jq -r '.["checkout#4"].archived' docs/ledger/legacy.json)" "row 4 (~~Shipped~~, no item) → {archived}"
  assert_eq "docs/ledgers/checkout-ledger.md#5" "$(jq -r '.["checkout#5"].archived' docs/ledger/legacy.json)" "row 5 (DONE, a spec) → {archived}"
  assert_eq "checkout-2" "$(jq -r '.["checkout#6"].key' docs/ledger/legacy.json)" "row 6 → its stub's key"
  assert_eq "6" "$(jq 'length' docs/ledger/legacy.json)" "one entry per row"
  assert_eq "$(jq -S . docs/ledger/legacy.json)" "$(cat docs/ledger/legacy.json)" "legacy.json: jq -S, 2-space indent"
  assert_json_field "$LG_OUT" '[.stubs[] | .path] | sort | join(",")' "$s2,$s1" "JSON: the stubs"
  # The stub and its legacy ref resolve.
  lg show checkout#2
  assert_contains "$LG_OUT" "$s1" "show checkout#2 → the stub"
  teardown
}

test_lg_init_legacy_ids_from_config() {
  echo "test: legacy ids — legacy_ledgers maps an id to a file (tier1 → docs/ledgers/tier1-pipeline-ledger.md, checkout → docs/ledgers/checkout-ledger.md; the stem rule for unnamed files: test_lg_init_legacy_map_and_stub); a configured config.json is kept"
  lg_init_fixture
  cat > docs/ledgers/tier1-pipeline-ledger.md <<'EOF'
# Tier 1 pipeline

| # | Item | Status |
|---|------|--------|
| 7 | [Order sync](../issues/2026-01-03-order-sync.md) | open |
| 8 | Old migration | closed |
EOF
  git add -A && git commit -qm tier1
  lg_accept_remote
  lg_enable '{"legacy_ledgers":{"tier1":"docs/ledgers/tier1-pipeline-ledger.md","checkout":"docs/ledgers/checkout-ledger.md"}}'
  local cfg
  cfg=$(cat docs/ledger/config.json)
  lg_init_edit_reg
  lg init --report docs/ledger/r.md --registry docs/ledger/edited.json
  lg init --accept docs/ledger/r.md.decisions.tsv
  assert_eq "0" "$LG_RC" "exits 0"
  assert_eq "checkout#1,checkout#2,checkout#3,tier1#7,tier1#8" "$(jq -r 'keys | join(",")' docs/ledger/legacy.json)" \
    "keys: <id>#<row>, each id from legacy_ledgers"
  assert_eq "docs/issues/2026-01-03-order-sync.md" "$(jq -r '.["tier1#7"].item' docs/ledger/legacy.json)" "tier1#7 → the item (no decision, no key)"
  assert_eq "docs/ledgers/tier1-pipeline-ledger.md#8" "$(jq -r '.["tier1#8"].archived' docs/ledger/legacy.json)" "tier1#8 (closed) → archived"
  assert_eq "$cfg" "$(cat docs/ledger/config.json)" "an existing config.json is not rewritten"
  # The stub of checkout#2: tier1 is not a registered ledger, checkout is.
  assert_contains "$(lg_fmblock "docs/issues/$(lg_today)-totals-plan.md")" "ledger: checkout" "the stub takes its ledger's id when registered"
  teardown
}

test_lg_init_summaries_sources() {
  echo "test: summaries — the existing summary, else the legacy row's first **bold** span, else the H1, else the first sentence of the first paragraph; at most 140 characters, cut at a word boundary"
  lg_fixture
  local long
  long="Checkout totals drift when a coupon and a gift card are combined and the cart is edited after the payment sheet has already been presented to the shopper"
  printf -- '---\nstatus: Open\nsummary: Kept as it is\n---\n# Some heading\n' > docs/issues/a.md
  printf -- '---\nstatus: Open\n---\n# Heading b\n' > docs/issues/b.md
  printf -- '---\nstatus: Open\n---\n# Heading c\n\nBody.\n' > docs/issues/c.md
  printf -- '---\nstatus: Open\n---\nFirst sentence here. Second sentence.\n' > docs/issues/d.md
  printf -- '---\nstatus: Open\n---\n# %s\n' "$long" > docs/issues/e.md
  mkdir -p docs/ledgers
  cat > docs/ledgers/x-ledger.md <<'EOF'
| # | Item | State |
|---|------|-------|
| 1 | **Sheet flickers on rotate** — [b](../issues/b.md) | open |
| 2 | [a](../issues/a.md) **Not this** | open |
EOF
  git add -A && git commit -qm items
  lg_init_edit_reg
  lg init --report docs/ledger/r.md --registry docs/ledger/edited.json
  local p
  for p in a b c d e; do lg_init_decide docs/ledger/r.md.decisions.tsv "docs/issues/$p.md" unassigned; done
  lg init --accept docs/ledger/r.md.decisions.tsv
  assert_eq "0" "$LG_RC" "exits 0"
  assert_eq "summary: Kept as it is" "$(grep '^summary:' docs/issues/a.md)" "a: the existing summary (the row's bold is not used)"
  assert_eq "summary: Sheet flickers on rotate" "$(grep '^summary:' docs/issues/b.md)" "b: the legacy row's bold lead over its H1"
  assert_eq "summary: Heading c" "$(grep '^summary:' docs/issues/c.md)" "c: the H1"
  assert_eq "summary: First sentence here." "$(grep '^summary:' docs/issues/d.md)" "d: the first sentence"
  local want
  want="Checkout totals drift when a coupon and a gift card are combined and the cart is edited after the payment sheet has already been presented"
  assert_eq "summary: $want" "$(grep '^summary:' docs/issues/e.md)" "e: the H1 cut at a word boundary"
  assert_eq "true" "$(jq -nr --arg s "$want" '$s | length <= 140 and length > 130')" "≤ 140 characters"
  teardown
}

test_lg_init_keys_one_commit_date_order() {
  echo "test: keys — one counter commit for every new key, numbered per ledger in item-date order (fields.date, ties by path), seeded from the base; a key in the ledger is kept, one in another ledger re-homed (old key → aliases); terminal items get none"
  lg_fixture
  lg_item docs/issues/p.md 'status: Open' 'date: 2026-03-01'
  lg_item docs/issues/q.md 'status: Open' 'date: 2026-01-15'
  lg_item docs/issues/r.md 'status: Open' 'date: 2026-03-01'
  lg_item docs/issues/s.md 'status: Open' 'date: 2026-02-01'
  lg_item docs/issues/t.md 'status: Open' 'key: checkout-5' 'ledger: checkout' 'summary: Kept'
  lg_item docs/issues/u.md 'status: Open' 'key: orders-3' 'ledger: orders' 'summary: Moving' 'date: 2026-04-01'
  lg_item docs/issues/v.md 'status: Fixed' 'date: 2025-01-01'
  git add -A && git commit -qm items
  lg_accept_remote
  lg_init_edit_reg
  lg init --report docs/ledger/r.md --registry docs/ledger/edited.json
  local d=docs/ledger/r.md.decisions.tsv p
  for p in p q r t u v; do lg_init_decide "$d" "docs/issues/$p.md" checkout; done
  lg_init_decide "$d" docs/issues/s.md orders
  lg init --accept "$d" --format json
  assert_eq "0" "$LG_RC" "exits 0"
  assert_eq "1" "$(lg_remote_counter_commits)" "one counter commit"
  assert_eq '{"checkout":10,"orders":5}' "$(lg_remote_counters)" "checkout seeded past checkout-5, orders past orders-3"
  local k=""
  for p in q p r u s t v; do k="$k$p=$({ grep '^key:' "docs/issues/$p.md" || true; } | cut -d ' ' -f 2);"; done
  assert_eq "q=checkout-6;p=checkout-7;r=checkout-8;u=checkout-9;s=orders-4;t=checkout-5;v=;" "$k" \
    "date order (q 01-15, then p and r on 03-01 by path, then u 04-01); t keeps checkout-5; v (fixed) none"
  assert_eq "aliases: [orders-3]" "$(grep '^aliases:' docs/issues/u.md)" "u re-homed: orders-3 kept as an alias"
  assert_eq "ledger: checkout" "$(grep '^ledger:' docs/issues/u.md)" "u's ledger"
  assert_json_field "$LG_OUT" '[.keys[] | select(.path == "docs/issues/u.md") | .previous] | join(",")' "orders-3" "JSON: the re-home"
  # Offline: provisional keys, a warning, rc 0.
  lg_item docs/issues/w.md 'status: Open'
  git add -A && git commit -qm w
  lg init --report docs/ledger/r.md
  lg_init_decide "$d" docs/issues/w.md checkout
  git remote set-url origin "$TEST_DIR/no-such-remote.git"
  lg init --accept "$d"
  assert_eq "0" "$LG_RC" "offline: exits 0"
  assert_eq "key: checkout-~$(lg_hex4 docs/issues/w.md)" "$(grep '^key:' docs/issues/w.md)" "offline: a provisional key"
  assert_contains "$LG_ERR" "provisional" "stderr warns"
  teardown
}

test_lg_init_first_views_rendered() {
  echo "test: --accept renders the first views (every ledger's page and README.md) into \$_LG_CACHE/views and prints their path"
  lg_accept_fixture
  lg_init_decide "$LG_DEC" docs/issues/2026-01-01-cart-total.md checkout
  lg init --accept "$LG_DEC" --format json
  assert_eq "0" "$LG_RC" "exits 0"
  local v
  v="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)/doc-superpowers/ledger/views"
  assert_file_exists "$v/README.md" "README.md"
  assert_file_exists "$v/checkout.md" "the checkout page"
  assert_contains "$(cat "$v/checkout.md")" "checkout-1" "the page lists the new key"
  assert_json_field "$LG_OUT" '.views | endswith("/doc-superpowers/ledger/views")' "true" "JSON: the views dir"
  lg init --accept "$LG_DEC"
  assert_contains "$LG_OUT" "doc-superpowers/ledger/views" "text: the views path"
  teardown
}

test_lg_init_idempotent() {
  echo "test: a second --accept of the same decisions file changes nothing — no file, no counter commit, no second stub, no new legacy entry"
  lg_accept_fixture
  lg_init_decide "$LG_DEC" docs/issues/2026-01-01-cart-total.md checkout
  lg_init_decide "$LG_DEC" docs/issues/2026-01-05-misc.md unassigned
  lg init --accept "$LG_DEC"
  assert_eq "0" "$LG_RC" "first run exits 0"
  git add -A && git commit -qm accepted
  local commits
  commits=$(lg_remote_counter_commits)
  lg init --accept "$LG_DEC" --format json
  assert_eq "0" "$LG_RC" "second run exits 0"
  assert_eq "" "$(git status --porcelain --untracked-files=all)" "the work tree is unchanged"
  assert_eq "$commits" "$(lg_remote_counter_commits)" "no counter commit"
  assert_json_field "$LG_OUT" '[(.keys | length), (.stubs | length), (.legacy.added | length), (.items | length)] | map(tostring) | join("|")' "0|0|0|0" \
    "JSON: no key, stub, legacy entry or item change"
  # A legacy entry that differs from the computed one is authoritative
  # (Task 16b U2b): no finding, the entry kept.
  jq '.["checkout#3"] = {"item": "docs/issues/2026-01-05-misc.md"}' docs/ledger/legacy.json > l.tmp && mv l.tmp docs/ledger/legacy.json
  local before
  before=$(cat docs/ledger/legacy.json 2>/dev/null || true)
  lg init --accept "$LG_DEC"
  assert_eq "0" "$LG_RC" "a legacy entry that differs: exits 0 (it is authoritative)"
  assert_not_contains "$LG_OUT" "finding" "…no finding"
  assert_eq "$before" "$(cat docs/ledger/legacy.json)" "the entry is not changed"
  teardown
}

test_lg_init_accept_dry_run() {
  echo "test: --accept --dry-run validates, prints the planned changes, and writes nothing (no file, no counter, no views)"
  lg_accept_fixture
  lg_init_decide "$LG_DEC" docs/issues/2026-01-01-cart-total.md checkout
  local st
  st=$(lg_init_status)
  lg init --accept "$LG_DEC" --dry-run
  assert_eq "0" "$LG_RC" "exits 0"
  assert_eq "$st" "$(lg_init_status)" "nothing written"
  assert_eq "absent" "$(lg_remote_counters)" "no counter ref"
  assert_file_not_exists "$(git rev-parse --git-common-dir)/doc-superpowers/ledger/views/README.md" "no views"
  assert_contains "$LG_OUT" "would write docs/ledger/config.json" "plans config.json"
  assert_contains "$LG_OUT" "would write docs/ledger/ledgers.json" "plans ledgers.json"
  assert_contains "$LG_OUT" "would write docs/ledger/legacy.json" "plans legacy.json"
  assert_contains "$LG_OUT" "docs/issues/2026-01-01-cart-total.md" "plans the item"
  assert_contains "$LG_OUT" "would create docs/issues/$(lg_today)-totals-plan.md" "plans the stub"
  lg init --accept "$LG_DEC" --dry-run --format json
  assert_json_field "$LG_OUT" '[.dry_run, (.keys | length)] | map(tostring) | join("|")' "true|2" "JSON: dry run, two keys planned"
  teardown
}

test_lg_init_accept_validates_first() {
  echo "test: --accept checks every row first (R1) — a decision that is not a registered id or unassigned, a path that is no longer an item: exit 1, one finding per row, nothing written; an empty decision is skipped"
  lg_accept_fixture
  lg_init_decide "$LG_DEC" docs/issues/2026-01-01-cart-total.md nope
  lg_init_decide "$LG_DEC" docs/issues/2026-01-03-order-sync.md orders
  lg_init_decide "$LG_DEC" docs/issues/2026-01-05-misc.md checkout
  git rm -q docs/issues/2026-01-05-misc.md
  local st
  st=$(lg_init_status)
  lg init --accept "$LG_DEC" --format json
  assert_eq "1" "$LG_RC" "exits 1"
  assert_json_field "$LG_OUT" '.findings | map(.path) | join(",")' \
    "docs/issues/2026-01-01-cart-total.md,docs/issues/2026-01-05-misc.md" "one finding per bad row"
  assert_eq "$st" "$(lg_init_status)" "nothing written"
  assert_eq "absent" "$(lg_remote_counters)" "nothing allocated"
  lg init --accept "$LG_DEC"
  assert_eq "1" "$LG_RC" "text: exits 1"
  assert_contains "$LG_OUT" "nope" "the finding names the bad value"
  # No registry line and no ledgers.json: exit 2.
  grep -v '^# registry:' "$LG_DEC" > nohdr.tsv
  lg init --accept nohdr.tsv
  assert_eq "2" "$LG_RC" "no registry header, no ledgers.json: exits 2"
  lg init --accept missing.tsv
  assert_eq "2" "$LG_RC" "a missing decisions file: exits 2"
  teardown
}

test_lg_init_accept_registry_changed() {
  echo "test: the report's registry is installed only when its sha256 matches the decisions header; else exit 2 'registry changed since the report'; with ledgers.json present, decisions are checked against it"
  lg_accept_fixture
  lg_init_decide "$LG_DEC" docs/issues/2026-01-01-cart-total.md checkout
  printf '%s\n' "$LG_INIT_REG" | jq -c . > docs/ledger/edited.json
  lg init --accept "$LG_DEC"
  assert_eq "2" "$LG_RC" "a changed registry: exits 2"
  assert_contains "$LG_ERR" "registry changed since the report; re-run \`init --report\`" "the message"
  assert_file_not_exists docs/ledger/ledgers.json "nothing installed"
  assert_file_not_exists docs/ledger/config.json "nothing written"
  # ledgers.json present: the header is not used.
  lg_registry '{"schema":"ledger-registry/1","ledgers":[{"id":"orders","title":"Orders","kind":"service","status":"active"}]}'
  lg init --accept "$LG_DEC"
  assert_eq "1" "$LG_RC" "checked against ledgers.json: checkout is not registered there"
  assert_contains "$LG_OUT" "checkout" "the finding names it"
  lg_registry '{"schema":"ledger-registry/1","ledgers":[{"id":"orders","title":"Orders","kind":"service","status":"active"},{"id":"checkout","title":"Checkout","kind":"service","status":"retired"},{"id":"Bad Id","title":"Bad","kind":"service","status":"active"}]}'
  lg_init_decide "$LG_DEC" docs/issues/2026-01-05-misc.md "Bad Id"
  lg init --accept "$LG_DEC"
  assert_eq "1" "$LG_RC" "a retired ledger, an id that is not a ledger id: exits 1"
  assert_contains "$LG_OUT" "is retired" "the retired ledger"
  assert_contains "$LG_OUT" "is not a ledger id" "the malformed id"
  assert_file_not_exists docs/ledger/config.json "still nothing written"
  teardown
}

# lg_accept_gh_issues: two hosted issues for the fake gh (created dates,
# a metadata block on #8).
lg_accept_gh_issues() {
  printf '%s\n' '[{"number":7,"title":"Cart badge stale","body":"The badge lags.","state":"OPEN","stateReason":null,"labels":[],"createdAt":"2026-02-03T10:00:00Z","updatedAt":"2026-10-01T10:00:00Z","url":"https://github.com/o/r/issues/7"},
{"number":8,"title":"Orders: retry on 502","body":"Retries are missing.\n\n<!-- doc-superpowers-ledger\nsummary: Retry orders on 502\nseverity: P2\n-->\n","state":"OPEN","stateReason":null,"labels":[{"name":"ledger:orders"}],"createdAt":"2026-02-05T10:00:00Z","updatedAt":"2026-10-02T10:00:00Z","url":"https://github.com/o/r/issues/8"}]' > "$LG_GH/issues.json"
}

test_lg_init_accept_hosted_items() {
  echo "test: hosted rows — config.json gets items.adapter (the reference gh adapter) when absent; ledger as a label, summary and key in the metadata block, through the adapter"
  lg_init_fixture
  lg_accept_remote
  lg_fake_gh
  lg_accept_gh_issues
  lg_init_edit_reg
  lg init --report docs/ledger/r.md --registry docs/ledger/edited.json --sources files,github
  assert_eq "0" "$LG_RC" "report exits 0"
  lg_init_decide docs/ledger/r.md.decisions.tsv gh#7 checkout
  lg init --accept docs/ledger/r.md.decisions.tsv
  assert_eq "0" "$LG_RC" "accept exits 0"
  assert_eq '{
  "items": {
    "adapter": "doc-superpowers:ledger-items-gh"
  }
}' "$(cat docs/ledger/config.json)" "config.json: items.adapter (jq -S, 2-space)"
  assert_eq "ledger:checkout" "$(jq -r '.[] | select(.number == 7) | [.labels[].name] | join(",")' "$LG_GH/issues.json")" "gh#7: the ledger label"
  local body
  body=$(jq -r '.[] | select(.number == 7) | .body' "$LG_GH/issues.json")
  assert_contains "$body" "key: checkout-1" "gh#7: the key in the block"
  assert_contains "$body" "summary: Cart badge stale" "gh#7: the summary (its title) in the block"
  lg show checkout-1
  assert_contains "$LG_OUT" "gh#7" "show checkout-1 → the hosted item"
  lg_fake_gh_off
  teardown
}

test_lg_init_accept_hosted_stub() {
  echo "test: items.globs [] with an items adapter — an open legacy row's stub is created through the adapter (create) with its fields, its legacy entry written; a re-run creates no second one"
  lg_init_fixture
  lg_accept_remote
  lg_fake_gh
  lg_enable '{"items":{"globs":[],"adapter":"doc-superpowers:ledger-items-gh"},"legacy_ledgers":{"checkout":"docs/ledgers/checkout-ledger.md"}}'
  lg_init_edit_reg
  lg init --report docs/ledger/r.md --registry docs/ledger/edited.json
  assert_eq "0" "$LG_RC" "report exits 0"
  lg init --accept docs/ledger/r.md.decisions.tsv
  assert_eq "0" "$LG_RC" "accept exits 0"
  # No file is an item now: row 1 (done) is archived, rows 2 and 3 (open)
  # become hosted stubs.
  assert_eq "Totals plan|Sheet flicker" "$(jq -r 'map(.title) | join("|")' "$LG_GH/issues.json")" "two issues created, titled by their rows"
  assert_contains "$(jq -r '.[0].body' "$LG_GH/issues.json")" "Migrated from docs/ledgers/checkout-ledger.md row 2." "the body names the row"
  assert_eq "ledger:checkout" "$(jq -r '.[0] | [.labels[].name] | join(",")' "$LG_GH/issues.json")" "its ledger label"
  assert_contains "$(jq -r '.[0].body' "$LG_GH/issues.json")" "key: checkout-1" "its key in the block"
  assert_eq "checkout-1|checkout-2|docs/ledgers/checkout-ledger.md#1" \
    "$(jq -r '[.["checkout#2"].key, .["checkout#3"].key, .["checkout#1"].archived] | join("|")' docs/ledger/legacy.json)" "the legacy entries"
  assert_eq "0" "$(find docs/issues -name "$(lg_today)-*" | wc -l | tr -d ' ')" "no file stub"
  rm -rf "$(git rev-parse --git-common-dir)/doc-superpowers/ledger/remote"
  lg init --accept docs/ledger/r.md.decisions.tsv
  assert_eq "0" "$LG_RC" "re-run exits 0"
  assert_eq "2" "$(jq 'length' "$LG_GH/issues.json")" "no new issue"
  lg_fake_gh_off
  teardown
}

test_lg_items_gh_get() {
  echo "test: the reference items adapter's get <ref> — {ref, url, title, body (the metadata block removed), created, fields, labels, status}; an unknown issue exits 2"
  lg_fixture
  lg_fake_gh
  lg_accept_gh_issues
  local a="$REPO_DIR/scripts/adapters/ledger-items-gh.sh" out rc=0
  out=$("$BASH_BIN" "$a" get gh#8) || rc=$?
  assert_eq "0" "$rc" "exits 0"
  assert_eq '{"body":"Retries are missing.","created":"2026-02-05T10:00:00Z","fields":{"ledger":"orders","severity":"P2","summary":"Retry orders on 502"},"labels":["ledger:orders"],"ref":"gh#8","status":"Open","title":"Orders: retry on 502","url":"https://github.com/o/r/issues/8"}' \
    "$(jq -cS . <<<"$out")" "the object"
  rc=0
  "$BASH_BIN" "$a" get gh#99 > /dev/null 2>&1 || rc=$?
  assert_eq "2" "$rc" "an unknown issue exits 2"
  rc=0
  "$BASH_BIN" "$a" get 99 > /dev/null 2>&1 || rc=$?
  assert_eq "3" "$rc" "a ref that is not gh#<n> exits 3"
  lg_fake_gh_off
  teardown
}

test_lg_init_import_converts_once() {
  echo "test: init --import — each hosted item becomes docs/issues/<created>-<slug>.md (fields, imported_from, url; # title + body), linked back with a note, nothing closed; a partial failure exits 2 and keeps the adapter; a re-run skips the imported ones and then sets items.adapter to null"
  lg_fixture
  lg_accept_remote
  lg_fake_gh
  lg_accept_gh_issues
  lg_enable '{"items":{"adapter":"doc-superpowers:ledger-items-gh"}}'
  git add -A && git commit -qm config
  : > "$LG_GH/view-fail-8"
  lg init --import
  assert_eq "2" "$LG_RC" "#8 cannot be read: exits 2"
  local f7=docs/issues/2026-02-03-cart-badge-stale.md f8=docs/issues/2026-02-05-orders-retry-on-502.md
  assert_file_exists "$f7" "#7 imported"
  assert_eq "imported_from: \"gh#7\"|url: \"https://github.com/o/r/issues/7\"|status: Open" "$(lg_fmblock "$f7")" "its frontmatter (the writer quotes # and :)"
  assert_eq "# Cart badge stale

The badge lags." "$(sed '1,/^---$/d' "$f7")" "its body: # title, then the issue's body"
  assert_eq "7	Imported to $f7 (doc-superpowers ledger)." "$(cat "$LG_GH/comments")" "linked back with a note"
  assert_eq "OPEN,OPEN" "$(jq -r 'map(.state) | join(",")' "$LG_GH/issues.json")" "nothing closed"
  assert_contains "$(cat docs/ledger/config.json)" "ledger-items-gh" "a partial failure keeps the adapter"
  rm -f "$LG_GH/view-fail-8"
  lg init --import --format json
  assert_eq "0" "$LG_RC" "re-run exits 0"
  assert_eq "1" "$(grep -c '^7	' "$LG_GH/comments")" "#7 skipped (already imported_from)"
  assert_file_exists "$f8" "#8 imported"
  assert_eq "imported_from: \"gh#8\"|url: \"https://github.com/o/r/issues/8\"|ledger: orders|severity: P2|status: Open|summary: Retry orders on 502" \
    "$(lg_fmblock "$f8")" "its fields from the block and labels"
  assert_eq "null" "$(jq -c '.items.adapter' docs/ledger/config.json)" "every item imported: items.adapter null"
  assert_contains "$LG_OUT" '"items.adapter"' "JSON: the config change is named"
  # An adapter without get: exit 2 naming it.
  mkdir -p tools
  # shellcheck disable=SC2016  # the adapter's own shell text
  printf '#!/bin/sh\ncase "$1" in\nlist) echo %s ;;\n*) exit 3 ;;\nesac\n' \
    "'{\"ref\":\"jira#5\",\"url\":\"https://jira.example/5\",\"status\":\"Open\",\"fields\":{},\"labels\":[]}'" > tools/items.sh
  chmod +x tools/items.sh
  lg_enable '{"items":{"adapter":"tools/items.sh"}}'
  lg init --import
  assert_eq "2" "$LG_RC" "an adapter without get: exits 2"
  assert_contains "$LG_ERR" "tools/items.sh" "the message names it"
  lg_fake_gh_off
  teardown
}

# --- Task 15 fix round 1 ------------------------------------------------------------

test_lg_init_stub_dir_from_globs() {
  echo "test: stubs go in the literal directory of the first <dir>/<pattern>.md item glob (work/items/), and are items there"
  lg_fixture
  lg_enable '{"items":{"globs":["work/items/*.md"]}}'
  lg_item work/items/a.md 'status: Open'
  mkdir -p docs/ledgers docs/plans
  printf -- '---\nstatus: active\n---\n# Plan\n' > docs/plans/p.md
  cat > docs/ledgers/w-ledger.md <<'EOF'
| # | Item | State |
|---|------|-------|
| 1 | [a](../../work/items/a.md) | open |
| 2 | **Port the cart** — [plan](../plans/p.md) | open |
EOF
  git add -A && git commit -qm items
  lg_accept_remote
  lg_init_edit_reg '{"schema":"ledger-registry/1","ledgers":[{"id":"w","title":"W","kind":"service","status":"active","paths":["work/**"]}]}'
  lg init --report docs/ledger/r.md --registry docs/ledger/edited.json
  assert_eq "0" "$LG_RC" "report exits 0"
  lg init --accept docs/ledger/r.md.decisions.tsv
  assert_eq "0" "$LG_RC" "accept exits 0"
  local stub
  stub="work/items/$(lg_today)-port-the-cart.md"
  assert_file_exists "$stub" "the stub is in work/items/"
  assert_eq "w-1" "$(jq -r '.["w#2"].key' docs/ledger/legacy.json)" "its key in legacy.json"
  lg show w#2
  assert_eq "0" "$LG_RC" "show w#2: the stub is an item"
  assert_contains "$LG_OUT" "$stub" "show names it"
  teardown
}

test_lg_init_stub_outside_globs_finding() {
  echo "test: a stub path items.globs would not match (docs/issues/2026-01-*.md) is a finding — rc 1, nothing written, nothing allocated"
  lg_init_fixture
  lg_accept_remote
  lg_enable '{"items":{"globs":["docs/issues/2026-01-*.md"]}}'
  lg_init_edit_reg
  lg init --report docs/ledger/r.md --registry docs/ledger/edited.json
  assert_eq "0" "$LG_RC" "report exits 0"
  local st
  st=$(lg_init_status)
  lg init --accept docs/ledger/r.md.decisions.tsv --format json
  assert_eq "1" "$LG_RC" "exits 1"
  assert_json_field "$LG_OUT" '.findings | map(.detail) | join(" ") | test("items.globs")' "true" "the finding names items.globs"
  assert_json_field "$LG_OUT" '.findings[0].path' "docs/issues/$(lg_today)-totals-plan.md" "and the stub path"
  assert_eq "$st" "$(lg_init_status)" "nothing written"
  assert_eq "absent" "$(lg_remote_counters)" "no counter ref"
  teardown
}

test_lg_init_import_outside_globs_finding() {
  echo "test: --import into a path items.globs would not match is a finding — rc 1, no file, no note"
  lg_fixture
  lg_fake_gh
  lg_accept_gh_issues
  lg_enable '{"items":{"globs":["docs/issues/2026-01-*.md"],"adapter":"doc-superpowers:ledger-items-gh"}}'
  git add -A && git commit -qm config
  lg init --import
  assert_eq "1" "$LG_RC" "exits 1"
  assert_contains "$LG_OUT" "items.globs" "the finding names items.globs"
  assert_eq "" "$(git status --porcelain --untracked-files=all)" "nothing written"
  assert_file_not_exists "$LG_GH/comments" "no note"
  lg_fake_gh_off
  teardown
}

test_lg_init_accept_trimmed_rows() {
  echo "test: a decisions file whose trailing tabs an editor trimmed — an undecided row of four columns is skipped, not refused"
  lg_accept_fixture
  lg_init_decide "$LG_DEC" docs/issues/2026-01-01-cart-total.md checkout
  awk '{ sub(/\t+$/, ""); print }' "$LG_DEC" > "$LG_DEC.t" && mv "$LG_DEC.t" "$LG_DEC"
  assert_eq "4" "$(grep 'sheet-flicker' "$LG_DEC" | awk -F '\t' '{ print NF }')" "precondition: an undecided row has four columns"
  lg init --accept "$LG_DEC" --format json
  assert_eq "0" "$LG_RC" "exits 0"
  assert_json_field "$LG_OUT" '.skipped' "3" "the three undecided rows skipped"
  assert_eq "key: checkout-1" "$(grep '^key:' docs/issues/2026-01-01-cart-total.md)" "the decided row applied"
  teardown
}

test_lg_init_stub_slug_collision_and_length() {
  echo "test: stub paths — a slug of at most 50 characters; a taken name (on disk or by another stub) takes -2, -3"
  lg_accept_fixture
  cat >> docs/ledgers/checkout-ledger.md <<'EOF'
| 4 | **Totals plan** — [plan](../plans/x-plan.md) | open |
| 5 | **A very long summary that goes on and on beyond the fifty character slug limit** | open |
EOF
  git add -A && git commit -qm rows
  local t
  t=$(lg_today)
  lg_item "docs/issues/$t-totals-plan.md" 'status: Open'
  lg init --accept "$LG_DEC" --dry-run
  assert_eq "0" "$LG_RC" "exits 0"
  assert_contains "$LG_OUT" "would create docs/issues/$t-totals-plan-2.md: stub of docs/ledgers/checkout-ledger.md row 2" "row 2: -2 (the name is taken on disk)"
  assert_contains "$LG_OUT" "would create docs/issues/$t-totals-plan-3.md: stub of docs/ledgers/checkout-ledger.md row 4" "row 4: -3 (taken by row 2)"
  assert_contains "$LG_OUT" "would create docs/issues/$t-a-very-long-summary-that-goes-on-and-on-beyond-the.md:" "row 5: the slug cut at 50 characters"
  teardown
}

test_lg_init_accept_malformed_and_duplicate_rows() {
  echo "test: a row that is not five (or four) tab-separated columns, and a path listed twice, are findings: rc 1, nothing written"
  lg_accept_fixture
  lg_init_decide "$LG_DEC" docs/issues/2026-01-01-cart-total.md checkout
  printf 'docs/issues/2026-01-02-sheet-flicker.md\topen\n' >> "$LG_DEC"
  printf 'docs/issues/2026-01-01-cart-total.md\topen\tcheckout\tledger-field\torders\n' >> "$LG_DEC"
  local st
  st=$(lg_init_status)
  lg init --accept "$LG_DEC" --format json
  assert_eq "1" "$LG_RC" "exits 1"
  assert_json_field "$LG_OUT" '[.findings[] | .detail | (test("tab-separated") or test("listed again"))] | map(tostring) | join(",")' "true,true" \
    "one finding each: the malformed row, the duplicate"
  assert_json_field "$LG_OUT" '[.findings[] | .line] | map(tostring) | join(",")' "10,11" "their lines"
  assert_eq "$st" "$(lg_init_status)" "nothing written"
  teardown
}

test_lg_init_import_list_field() {
  echo "test: --import writes a list field of the metadata block as a list (setlist)"
  lg_fixture
  lg_fake_gh
  printf '%s\n' '[{"number":9,"title":"Linked","body":"See them.\n\n<!-- doc-superpowers-ledger\nrelates: [a-1, b-2]\n-->\n","state":"OPEN","stateReason":null,"labels":[],"createdAt":"2026-03-01T10:00:00Z","updatedAt":"2026-10-02T10:00:00Z","url":"https://github.com/o/r/issues/9"}]' > "$LG_GH/issues.json"
  lg_enable '{"items":{"adapter":"doc-superpowers:ledger-items-gh"}}'
  git add -A && git commit -qm config
  lg init --import
  assert_eq "0" "$LG_RC" "exits 0"
  assert_contains "$(lg_fmblock docs/issues/2026-03-01-linked.md)" "relates: [a-1, b-2]" "the list, as a flow list"
  lg_fake_gh_off
  teardown
}

# --- Task 15 fix round 2 ------------------------------------------------------------

test_lg_init_rehome_malformed_aliases_finding() {
  echo "test: a re-home over an aliases field the parser rejects (a nested map) is a finding — rc 1, the file untouched, nothing allocated"
  lg_fixture
  printf -- '---\nstatus: Open\nkey: orders-3\nledger: orders\nsummary: Moving\naliases:\n  legacy: tier1-9\n  note: keep me\n---\n# u\n' > docs/issues/u.md
  git add -A && git commit -qm items
  lg_accept_remote
  lg_init_edit_reg
  lg init --report docs/ledger/r.md --registry docs/ledger/edited.json
  lg_init_decide docs/ledger/r.md.decisions.tsv docs/issues/u.md checkout
  local before
  before=$(cksum < docs/issues/u.md)
  lg init --accept docs/ledger/r.md.decisions.tsv --format json
  assert_eq "1" "$LG_RC" "exits 1"
  assert_json_field "$LG_OUT" '.findings | map(select(.path == "docs/issues/u.md") | .detail) | join(" ") | test("aliases")' "true" \
    "the finding names the aliases field"
  assert_eq "$before" "$(cksum < docs/issues/u.md)" "the item is untouched (keep me stays)"
  assert_eq "absent" "$(lg_remote_counters)" "nothing allocated"
  assert_file_not_exists docs/ledger/ledgers.json "nothing written"
  teardown
}

# lg_get_adapter: tools/items.sh lists x#1 and x#2; get x#2 prints its
# object; get x#1 prints what tools/mode says — nothing (empty), two
# objects (two), or its object (ok); note succeeds.
lg_get_adapter() {
  mkdir -p tools
  cat > tools/items.sh <<'EOF'
#!/bin/sh
one='{"ref":"x#1","url":"https://x.example/1","title":"One","body":"b1","created":"2026-02-01","fields":{},"labels":[],"status":"Open"}'
two='{"ref":"x#2","url":"https://x.example/2","title":"Two","body":"b2","created":"2026-02-02","fields":{},"labels":[],"status":"Open"}'
case "$1" in
  list) printf '%s\n%s\n' "$one" "$two" ;;
  get)
    if [ "$2" = "x#2" ]; then printf '%s\n' "$two"; exit 0; fi
    case "$(cat tools/mode)" in
      empty) ;;
      two) printf '%s\n%s\n' "$one" "$one" ;;
      *) printf '%s\n' "$one" ;;
    esac ;;
  note) exit 0 ;;
  *) exit 3 ;;
esac
EOF
  chmod +x tools/items.sh
}

test_lg_init_import_get_output_counts() {
  echo "test: --import counts each get's output — nothing, or two objects, is no item: exit 2, nothing imported from there on, items.adapter kept"
  lg_fixture
  lg_get_adapter
  lg_enable '{"items":{"adapter":"tools/items.sh"}}'
  git add -A && git commit -qm adapter
  echo empty > tools/mode
  lg init --import
  assert_eq "2" "$LG_RC" "an empty get: exits 2"
  assert_contains "$LG_ERR" "x#1: the items adapter's get printed no {ref, title, body, fields} object" "the message names the ref"
  assert_file_not_exists docs/issues/2026-02-02-two.md "x#2 (after it) not imported"
  assert_contains "$(cat docs/ledger/config.json)" "tools/items.sh" "items.adapter kept"
  echo two > tools/mode
  lg init --import
  assert_eq "2" "$LG_RC" "a get printing two objects: exits 2"
  assert_contains "$LG_ERR" "x#1: the items adapter's get printed no" "the message"
  assert_file_not_exists docs/issues/2026-02-01-one.md "x#1 not imported"
  echo ok > tools/mode
  lg init --import
  assert_eq "0" "$LG_RC" "one object each: exits 0"
  assert_file_exists docs/issues/2026-02-01-one.md "x#1 imported"
  assert_file_exists docs/issues/2026-02-02-two.md "x#2 imported"
  teardown
}

test_lg_init_accept_findings_before_offline() {
  echo "test: offline with hosted writes to make, and a bad row: the findings win (rc 1); without the bad row, offline exits 2"
  lg_init_fixture
  lg_accept_remote
  lg_fake_gh
  lg_accept_gh_issues
  lg_init_edit_reg
  lg init --report docs/ledger/r.md --registry docs/ledger/edited.json --sources files,github
  lg_init_decide docs/ledger/r.md.decisions.tsv gh#7 checkout
  lg_init_decide docs/ledger/r.md.decisions.tsv docs/issues/2026-01-01-cart-total.md nope
  DOC_TOOLS_LEDGER_OFFLINE=1 lg init --accept docs/ledger/r.md.decisions.tsv
  assert_eq "1" "$LG_RC" "offline and a bad row: exits 1"
  assert_contains "$LG_OUT" "nope" "the finding"
  lg_init_decide docs/ledger/r.md.decisions.tsv docs/issues/2026-01-01-cart-total.md checkout
  DOC_TOOLS_LEDGER_OFFLINE=1 lg init --accept docs/ledger/r.md.decisions.tsv
  assert_eq "2" "$LG_RC" "offline, the rows valid: exits 2"
  assert_contains "$LG_ERR" "offline" "the reason"
  assert_file_not_exists docs/ledger/config.json "nothing written"
  lg_fake_gh_off
  teardown
}

test_lg_init_import_empty_globs_finding() {
  echo "test: --import with items.globs [] (hosted only): the finding says to add an items.globs entry first"
  lg_fixture
  lg_fake_gh
  lg_accept_gh_issues
  lg_enable '{"items":{"globs":[],"adapter":"doc-superpowers:ledger-items-gh"}}'
  git add -A && git commit -qm config
  lg init --import
  assert_eq "1" "$LG_RC" "exits 1"
  assert_contains "$LG_OUT" "add an items.globs entry (e.g. docs/issues/*.md)" "the finding says what to do"
  assert_eq "" "$(git status --porcelain --untracked-files=all)" "nothing written"
  lg_fake_gh_off
  teardown
}

# --- Task 16b (U2): which files are hand-written ledgers; pre-seeded entries ----

# lg_u2_fixture: lg_init_fixture with dated items and the remote, plus two
# tracked files that discovery reads as hand-written ledgers: a plan whose
# "#" table links an item (row 1) and has a row with no tracker (row 2), no
# State column (docs/plans/y-plan.md); and the host's archived snapshot of
# the checkout ledger (docs/archive/ledgers/checkout-ledger.md). The
# registry LG_INIT_REG is docs/ledger/edited.json; no config, no report.
lg_u2_fixture() {
  local f
  lg_init_fixture
  for f in docs/issues/2026-01-0*.md; do
    lg_add_fm "$f" "date: $(basename "$f" | cut -c 1-10)"
  done
  cat > docs/plans/y-plan.md <<'EOF'
# Y plan

| # | Task | Tracker |
|---|------|---------|
| 1 | Fix the flicker | [sheet](../issues/2026-01-02-sheet-flicker.md) |
| 2 | Write the follow-up doc | — |
EOF
  mkdir -p docs/archive/ledgers
  cp docs/ledgers/checkout-ledger.md docs/archive/ledgers/checkout-ledger.md
  git add -A && git commit -qm "u2 fixture"
  lg_accept_remote
  lg_init_edit_reg
}

# lg_u2_hand <report>: its "Hand-written ledgers" section.
lg_u2_hand() {
  sed -n '/^## Hand-written ledgers/,/^## Registry$/p' "$1" 2>/dev/null || true
}

test_lg_init_legacy_ledgers_only_named() {
  echo "test: init with config legacy_ledgers set (U2a) — only the files it names are hand-written ledgers, in --report and --accept: a plan's \"#\" table linking an item and the host's archived snapshot of a ledger are not scanned"
  lg_u2_fixture
  lg_enable '{"legacy_ledgers":{"checkout":"docs/ledgers/checkout-ledger.md"}}'
  lg init --report docs/ledger/r.md --registry docs/ledger/edited.json
  assert_eq "0" "$LG_RC" "--report exits 0"
  local hw t
  hw=$(lg_u2_hand docs/ledger/r.md)
  assert_contains "$hw" '`docs/ledgers/checkout-ledger.md` — `checkout`: 3 rows' "the named ledger is listed"
  assert_not_contains "$hw" "y-plan" "the plan is not a hand-written ledger"
  assert_not_contains "$hw" "docs/archive/ledgers" "nor the archived snapshot"
  assert_eq "docs/issues/2026-01-02-sheet-flicker.md	open	checkout	legacy:docs/ledgers/checkout-ledger.md#3" \
    "$(lg_init_rows docs/ledger/r.md.decisions.tsv | grep sheet-flicker | cut -f 1-4)" "membership from the named ledger only"
  lg_init_decide docs/ledger/r.md.decisions.tsv docs/issues/2026-01-01-cart-total.md checkout
  lg init --accept docs/ledger/r.md.decisions.tsv --format json
  assert_eq "0" "$LG_RC" "--accept exits 0"
  assert_eq "checkout#1,checkout#2,checkout#3" "$(jq -r 'keys | join(",")' docs/ledger/legacy.json 2>/dev/null)" \
    "legacy.json: the named ledger's rows only"
  assert_eq "docs/ledgers/checkout-ledger.md#2" "$(jq -r '[.stubs[] | .row] | join(",")' <<<"$LG_OUT")" \
    "one stub: the named ledger's open row 2 — none for the plan's row 2 or the snapshot's rows"
  t=$(lg_today)
  assert_file_not_exists "docs/issues/$t-write-the-follow-up-doc.md" "no stub from the plan"
  teardown
}

test_lg_init_hand_written_discovery_without_legacy_ledgers() {
  echo "test: init with legacy_ledgers empty (U2a) — discovery stands: every tracked \"#\" table linking an item is listed, so the user can then set legacy_ledgers"
  lg_u2_fixture
  lg init --report docs/ledger/r.md --registry docs/ledger/edited.json
  assert_eq "0" "$LG_RC" "--report exits 0"
  local hw
  hw=$(lg_u2_hand docs/ledger/r.md)
  assert_contains "$hw" '`docs/ledgers/checkout-ledger.md` — `checkout`: 3 rows' "the ledger"
  assert_contains "$hw" '`docs/plans/y-plan.md` — `y-plan`: 2 rows' "the plan is listed"
  assert_contains "$hw" '`docs/archive/ledgers/checkout-ledger.md`' "the snapshot is listed"
  teardown
}

test_lg_init_preseeded_legacy_entries_authoritative() {
  echo "test: init --accept (U2b) — a row whose <legacy-id>#<row> is already in legacy.json is skipped: no stub for an open row tracked by a plan, no finding for an entry that differs from the computed one, no new entry; the other rows get theirs"
  lg_accept_fixture
  printf '%s\n' '{"checkout#2":{"archived":"docs/ledgers/checkout-ledger.md#2"},"checkout#3":{"item":"docs/issues/2026-01-05-misc.md"}}' \
    | jq -S . > docs/ledger/legacy.json
  local before t
  before=$(jq -c '{"checkout#2": .["checkout#2"], "checkout#3": .["checkout#3"]}' docs/ledger/legacy.json)
  lg_init_decide "$LG_DEC" docs/issues/2026-01-01-cart-total.md checkout
  lg init --accept "$LG_DEC" --format json
  assert_eq "0" "$LG_RC" "exits 0 (no finding)"
  assert_json_field "$LG_OUT" '.findings | length' "0" "JSON: no finding"
  assert_json_field "$LG_OUT" '[.legacy.added[]] | join(",")' "checkout#1" "JSON: one new entry, row 1's"
  assert_json_field "$LG_OUT" '.stubs | length' "0" "JSON: no stub (row 2 is pre-seeded)"
  t=$(lg_today)
  assert_file_not_exists "docs/issues/$t-totals-plan.md" "no stub file"
  assert_eq "$before" "$(jq -c '{"checkout#2": .["checkout#2"], "checkout#3": .["checkout#3"]}' docs/ledger/legacy.json)" \
    "the pre-seeded entries are unchanged"
  assert_eq "docs/issues/2026-01-04-old-bug.md" "$(jq -r '.["checkout#1"].item' docs/ledger/legacy.json)" "row 1 gets its entry"
  assert_eq '{"checkout":2}' "$(lg_remote_counters)" "counters: checkout-1 only (no stub key)"
  # Fix round 1 (m4a): the rows left alone are counted.
  assert_json_field "$LG_OUT" '.legacy.kept' "2" "JSON: legacy.kept 2 (rows 2 and 3)"
  lg init --accept "$LG_DEC"
  assert_eq "0" "$LG_RC" "a second run exits 0"
  assert_contains "$LG_OUT" "3 row(s) already in legacy.json, left alone" "the summary line counts the rows left alone (all three now)"
  teardown
}

test_lg_init_preseeded_legacy_keys_canonical() {
  echo "test: init --accept (fix round 1, m4b) — the pre-seeded check reads a legacy key as U5 does: a pre-seeded x#7 is the row whose # cell is 07, x#21c the row 21C (no second entry, no stub)"
  lg_accept_fixture
  cat > docs/ledgers/x-ledger.md <<'EOF'
| # | Item | State |
|---|------|-------|
| 07 | Seven — [plan](../plans/x-plan.md) | open |
| 21C | Twenty-one c — [plan](../plans/x-plan.md) | open |
| 8 | Eight — [plan](../plans/x-plan.md) | open |
EOF
  git add -A && git commit -qm "x ledger"
  lg_enable '{"legacy_ledgers":{"checkout":"docs/ledgers/checkout-ledger.md","x":"docs/ledgers/x-ledger.md"}}'
  printf '%s\n' '{"x#7":{"archived":"docs/ledgers/x-ledger.md#07"},"x#21c":{"archived":"docs/ledgers/x-ledger.md#21C"}}' \
    | jq -S . > docs/ledger/legacy.json
  lg_init_decide "$LG_DEC" docs/issues/2026-01-01-cart-total.md checkout
  lg init --accept "$LG_DEC" --format json
  assert_eq "0" "$LG_RC" "exits 0"
  assert_eq "checkout#1,checkout#2,checkout#3,x#21c,x#7,x#8" "$(jq -r 'keys | join(",")' docs/ledger/legacy.json)" \
    "legacy.json: no x#07 or x#21C beside the pre-seeded x#7 and x#21c; x#8 added"
  assert_eq "docs/ledgers/checkout-ledger.md#2,docs/ledgers/x-ledger.md#8" "$(jq -r '[.stubs[] | .row] | sort | join(",")' <<<"$LG_OUT")" \
    "stubs: x#8 and checkout#2 only"
  assert_json_field "$LG_OUT" '.legacy.kept' "2" "JSON: legacy.kept 2"
  teardown
}

# --- Task 16b (U1): the row's item comes from its Tracker column -----------------

test_lg_init_row_item_from_tracker_column() {
  echo "test: init (U1) — a hand-written row's item: with a Tracker… column, its links only (the first item link that is no dep: link wins); without one, any cell's, dep: links skipped"
  lg_accept_fixture
  cat > docs/ledgers/z-ledger.md <<'EOF'
| # | Work | Tracker (the authoritative home) | State |
|---|------|----------------------------------|-------|
| 1 | Fix totals — [dep: sheet](../issues/2026-01-02-sheet-flicker.md) | [cart](../issues/2026-01-01-cart-total.md) | open |
| 2 | See [misc](../issues/2026-01-05-misc.md) first | [plan](../plans/x-plan.md) | open |
| 3 | Sync orders | dep: [sheet](../issues/2026-01-02-sheet-flicker.md), [sync](../issues/2026-01-03-order-sync.md) | open |
EOF
  cat > docs/ledgers/y-ledger.md <<'EOF'
| # | Item | State |
|---|------|-------|
| 1 | [dep: cart](../issues/2026-01-01-cart-total.md) then [misc](../issues/2026-01-05-misc.md) | open |
| 2 | Blocked — **dep:** [cart](../issues/2026-01-01-cart-total.md) | open |
| 3 | _dep:_ [cart](../issues/2026-01-01-cart-total.md), [_dep:_ sheet](../issues/2026-01-02-sheet-flicker.md), [misc](../issues/2026-01-05-misc.md) | open |
EOF
  # Fix round 1 (m3): an emphasised header cell is still the Tracker column.
  cat > docs/ledgers/v-ledger.md <<'EOF'
| # | Work | **Tracker** | State |
|---|------|-------------|-------|
| 1 | See [misc](../issues/2026-01-05-misc.md) | [sync](../issues/2026-01-03-order-sync.md) | open |
EOF
  git add -A && git commit -qm "u1 ledgers"
  lg init --report docs/ledger/r.md --registry docs/ledger/edited.json
  assert_eq "0" "$LG_RC" "--report exits 0"
  assert_contains "$(lg_u2_hand docs/ledger/r.md)" '`docs/ledgers/z-ledger.md` — `z`: 3 rows; 2 link items, 1 plans, 0 specs' \
    "z: rows 1 and 3 link items, row 2 a plan (Work's links do not count)"
  assert_contains "$(lg_u2_hand docs/ledger/r.md)" '`docs/ledgers/y-ledger.md` — `y`: 3 rows; 2 link items' "y: rows 1 and 3 link an item (their dep: links skipped), row 2 none"
  lg_init_decide "$LG_DEC" docs/issues/2026-01-01-cart-total.md checkout
  lg init --accept "$LG_DEC" --format json
  assert_eq "0" "$LG_RC" "--accept exits 0"
  assert_eq '{"key":"checkout-1"}' "$(jq -c '.["z#1"]' docs/ledger/legacy.json)" "z#1: the Tracker link (cart-total), not Work's dep: link"
  assert_eq '{"item":"docs/issues/2026-01-03-order-sync.md"}' "$(jq -c '.["z#3"]' docs/ledger/legacy.json)" \
    "z#3: a multi-link Tracker cell — the first link that is no dep: link"
  assert_eq '{"item":"docs/issues/2026-01-05-misc.md"}' "$(jq -c '.["y#1"]' docs/ledger/legacy.json)" "y#1 (no Tracker column): the first item link that is no dep: link"
  assert_eq '{"item":"docs/issues/2026-01-05-misc.md"}' "$(jq -c '.["y#3"]' docs/ledger/legacy.json)" \
    "y#3: _dep:_ before a link and in a label are dep: links too (m3)"
  assert_eq '{"item":"docs/issues/2026-01-03-order-sync.md"}' "$(jq -c '.["v#1"]' docs/ledger/legacy.json)" \
    "v#1: a **Tracker** header is the Tracker column (m3)"
  assert_eq "docs/ledgers/checkout-ledger.md#2,docs/ledgers/y-ledger.md#2,docs/ledgers/z-ledger.md#2" \
    "$(jq -r '[.stubs[] | .row] | sort | join(",")' <<<"$LG_OUT")" \
    "stubs: z#2 (its only item link is outside Tracker: a non-item tracker) and y#2 (a **dep:** link only), beside checkout#2"
  teardown
}

# --- Task 16b (U5): letter-suffixed legacy rows --------------------------------

test_lg_resolve_legacy_letter_rows() {
  echo "test: _lg_resolve (U5) — a letter-suffixed legacy row: '<old>#21c', '<old> #21c', '<old> row 21c' (any case) reach <id>#21c; 21 and 21c are distinct entries; leading zeros are dropped (07 → 7, 07b → 7b); an unknown suffix → rc 1"
  lg_keys_fixture
  lg_keys_resolve_items
  printf '%s\n' '{"design-system#21":{"key":"x-15"},"design-system#21c":{"key":"x-14"},
    "design-system#7":{"item":"docs/issues/k.md"},"design-system#7b":{"archived":"docs/ledgers/design-system-ledger.md#7b"}}' \
    > docs/ledger/legacy.json
  local r
  for r in "design-system#21c" "design-system #21c" "design-system row 21c" "design-system ledger row #21c" \
      "Design-System#21C" "design-system-ledger row 21C"; do
    lg_call _lg_resolve "$r"
    assert_eq "0|docs/issues/a.md" "$LG_RC|$LG_OUT" "'$r' → design-system#21c (x-14)"
  done
  for r in "design-system#21" "design-system row 21"; do
    lg_call _lg_resolve "$r"
    assert_eq "0|docs/issues/b.md" "$LG_RC|$LG_OUT" "'$r' → design-system#21 (x-15), not #21c"
  done
  # Fix round 1 (m5): the spaced "<old> #<n>" is a key form; as a legacy
  # ref it takes a letter-suffixed row only. Ledger x has no key x-14b, and
  # "x #16" (no key x-16) never falls through to a legacy row x#16.
  printf '%s\n' '{"design-system#21":{"key":"x-15"},"design-system#21c":{"key":"x-14"},
    "design-system#7":{"item":"docs/issues/k.md"},"design-system#7b":{"archived":"docs/ledgers/design-system-ledger.md#7b"},
    "x#16":{"item":"docs/issues/b.md"},"x#16b":{"item":"docs/issues/k.md"}}' \
    > docs/ledger/legacy.json
  for r in "design-system #21" "x #16"; do
    lg_call _lg_resolve "$r"
    assert_eq "1|" "$LG_RC|$LG_OUT" "'$r' → none: a missing key, never a legacy row (m5)"
  done
  lg_call _lg_resolve "x#16"
  assert_eq "0|docs/issues/b.md" "$LG_RC|$LG_OUT" "'x#16' (one token) → the legacy row, as before"
  lg_call _lg_resolve "x row 16"
  assert_eq "0|docs/issues/b.md" "$LG_RC|$LG_OUT" "'x row 16' → the legacy row, as before"
  lg show x "#16"
  assert_eq "1" "$LG_RC" "show x #16 (no key x-16, a legacy row x#16): exit 1"
  lg show x "#16b"
  assert_eq "0" "$LG_RC" "show x #16b: the letter-suffixed legacy row"
  lg_call _lg_resolve "x #16b"
  assert_eq "0|docs/issues/k.md" "$LG_RC|$LG_OUT" "'x #16b' → x#16b's item"
  lg_call _lg_resolve "design-system#07"
  assert_eq "0|docs/issues/k.md" "$LG_RC|$LG_OUT" "'#07' → design-system#7"
  lg_call _lg_resolve "design-system row 07B"
  assert_eq "0|docs/ledgers/design-system-ledger.md#7b" "$LG_RC|$LG_OUT" "'row 07B' → design-system#7b (archived)"
  for r in "design-system#21d" "design-system row 21d" "design-system #7c" "design-system#21cc"; do
    lg_call _lg_resolve "$r"
    assert_eq "1|" "$LG_RC|$LG_OUT" "'$r' → none (rc 1)"
  done
  lg show design-system row 21c
  assert_eq "0" "$LG_RC" "show design-system row 21c (three words)"
  assert_eq "x-14  x  —  not started" "$(printf '%s\n' "$LG_OUT" | head -n 1)" "…the item"
  lg show design-system "#21c"
  assert_eq "0" "$LG_RC" "show design-system #21c (two words)"
  lg show design-system row 21d
  assert_eq "1" "$LG_RC" "show an unknown suffix: exit 1"
  teardown
}

# --- Task 16b (U6): terminal State tokens ------------------------------------------

test_lg_init_done_states_from_config() {
  echo "test: init --accept (U6, fix round 1) — a row is done when its State's first words (~~ * \` ' dropped, any case, split at any other non-alphanumeric) are a built-in done word or a config status.fixed / closed / wontfix value, or run together (k ≤ 3) spell one: WONT-FIX, Won't fix, wontfix, a host's closed value → archived; OPEN, Do next, do-next, Do new, Closing stay open"
  lg_accept_fixture
  cat > docs/ledgers/w-ledger.md <<'EOF'
| # | Item | State |
|---|------|-------|
| 1 | Not worth it | WONT-FIX |
| 2 | Nor this | Won't fix |
| 3 | Nor that | wontfix |
| 4 | Parked idea | Parked until Q3 |
| 5 | Still to do | OPEN |
| 6 | A duplicate | Won’t Fix (dup of 3) |
| 7 | Out of scope | ~~Not planned~~ |
| 8 | Old work | **Shipped** |
| 9 | Next up | Do next |
| 10 | Next too | do-next |
| 11 | Fresh | Do new |
| 12 | Closing soon | Closing |
| 13 | Done with it | Done-ish |
| 14 | Wont fix spaced | Wont fix |
| 15 | Partly | Done_partly |
EOF
  git add -A && git commit -qm "w ledger"
  lg_enable '{"legacy_ledgers":{"checkout":"docs/ledgers/checkout-ledger.md","w":"docs/ledgers/w-ledger.md"},"status":{"closed":["closed","obsolete","parked"]}}'
  lg_init_decide "$LG_DEC" docs/issues/2026-01-01-cart-total.md checkout
  lg init --accept "$LG_DEC" --format json
  assert_eq "0" "$LG_RC" "exits 0"
  local n
  for n in 1 2 3 4 6 7 8 13 14 15; do
    assert_eq "docs/ledgers/w-ledger.md#$n" "$(jq -r --arg k "w#$n" '.[$k].archived' docs/ledger/legacy.json)" "w#$n: done → archived"
  done
  # Fix round 1 (Important 1): whole words — "Do next" is not "done…".
  assert_eq "docs/ledgers/checkout-ledger.md#2,docs/ledgers/w-ledger.md#10,docs/ledgers/w-ledger.md#11,docs/ledgers/w-ledger.md#12,docs/ledgers/w-ledger.md#5,docs/ledgers/w-ledger.md#9" \
    "$(jq -r '[.stubs[] | .row] | sort | join(",")' <<<"$LG_OUT")" \
    "stubs: OPEN (w#5), Do next / do-next / Do new (w#9-11: no word is done), Closing (w#12), and the checkout ledger's open row"
  teardown
}

# Pass/fail counters across a ( … ) subshell: the child writes its counts, the
# parent adds them.
print_counts_to() {
  printf '%s %s %s\n' "$PASS" "$FAIL" "$TESTS_RUN" > "$1"
}
absorb_counts() {
  local p f t
  read -r p f t < "$1"
  PASS=$p FAIL=$f TESTS_RUN=$t
}

run_tests() {
  echo "Running ledger tests..."
  echo ""

  # --- Task 1: verb group, exit family, config, inert ---
  test_lg_inert_text_every_verb
  test_lg_inert_json
  test_lg_unknown_option_is_usage
  test_lg_config_invalid_json
  test_lg_config_merge
  test_lg_vendored_copy_no_config_inert
  test_lg_vendored_copy_with_config_rc2
  test_lg_outside_repo_rc2
  test_lg_die_inside_subshell_one_object
  test_lg_crash_is_rc2

  # --- Task 1 helpers, called directly ---
  test_lg_source_guard
  test_lg_doc_index_helper
  test_lg_cfg_usage_emit_helpers

  # --- Task 2: frontmatter parser, writer, parse cache ---
  test_lg_fm_scalars_and_lists
  test_lg_fm_crlf_bom
  test_lg_fm_nested_map_rejected
  test_lg_fm_no_frontmatter
  test_lg_fm_unterminated
  test_lg_fm_fence_dash
  test_lg_fm_quoted_values
  test_lg_fm_resolution_h1_para
  test_lg_fm_write_append_and_replace
  test_lg_fm_write_quotes
  test_lg_parse_path_space_unicode
  test_lg_parse_blobs_staged_differs_from_worktree
  test_lg_parse_cache_reuse_by_content
  test_lg_parse_blobs_odd_entries
  test_lg_field_candidates

  # --- Task 3: registry, globs, validate --registry ---
  test_lg_glob_ere_cases
  test_lg_item_paths_brace_glob
  test_lg_registry_valid_clean
  test_lg_registry_duplicate_id
  test_lg_registry_bad_status
  test_lg_registry_contract_dup
  test_lg_registry_overlap
  test_lg_registry_unowned
  test_lg_registry_residual
  test_lg_registry_exclusion
  test_lg_registry_id_newline
  test_lg_registry_retired_owns_nothing

  # --- Task 4: the index ---
  test_lg_index_fields
  test_lg_index_status_classes_case
  test_lg_index_date_fallback_and_rename
  test_lg_index_docs_links
  test_lg_index_renamed_link
  test_lg_index_absent_doc_index_ok
  test_lg_index_unborn_head
  test_lg_index_invalid_doc_index_rc2
  test_lg_index_cache_invalidation
  test_lg_index_foreign_schema_ignored
  test_lg_index_staged_mode
  test_lg_index_cache_prune
  test_lg_index_odd_worktree_entries
  test_lg_parse_hash_map

  # --- Task 4 fix round 1 ---
  test_lg_index_staged_reuses_worktree_parse
  test_lg_index_hit_survives_prune
  test_lg_index_cross_dir_move_deviation
  test_lg_parse_parallel_bin_bash

  # --- Task 4 fix round 2 ---
  test_lg_index_dates_merge_cold_vs_extended

  # --- Task 4 fix round 3 ---
  test_lg_index_dates_treesame_merge

  # --- Task 5: show, ls, find, bench ---
  test_lg_show_limits
  test_lg_ls_filters_and_order
  test_lg_ls_output_budget
  test_lg_find_ranks
  test_lg_smoke_budgets

  # --- Task 5 carry-over ---
  test_lg_status_labels_shared

  # --- Task 6: keys ---
  test_lg_resolve_forms
  test_lg_resolve_legacy_forms
  test_lg_resolve_finalized
  test_lg_resolve_ambiguous
  test_lg_alloc_seeds_from_base
  test_lg_alloc_batch_one_commit
  test_lg_alloc_race
  test_lg_alloc_exhausted_rc2
  test_lg_alloc_declined_rc2
  test_lg_alloc_offline_provisional
  test_lg_merge_mode_provisional_and_finalize
  test_lg_new_writes_fields
  test_lg_new_unassigned_no_key
  test_lg_new_summary_too_long
  test_lg_assign_moves_old_key_to_aliases
  test_lg_counter_push_no_verify
  test_lg_cas_finalize_and_provisional_in_range
  test_lg_finalize_crash_safe_and_resumable
  test_lg_finalize_refuses_reused_provisional_key

  # --- Task 7: validate ---
  test_lg_validate_staged_clean
  test_lg_validate_staged_bad_key
  test_lg_validate_staged_dup_key
  test_lg_validate_staged_alias_collision
  test_lg_validate_staged_unknown_ledger
  test_lg_validate_staged_added_needs_fields
  test_lg_validate_staged_modified_legacy_ok
  test_lg_validate_staged_reads_staged_blob
  test_lg_validate_staged_superseded_dangling
  test_lg_validate_staged_cycle
  test_lg_validate_staged_chain_ends_superseded
  test_lg_validate_staged_missing_resolution
  test_lg_validate_staged_superseded_not_closed
  test_lg_validate_staged_text_one_line
  test_lg_validate_staged_unborn
  test_lg_validate_staged_keymap_reads_frontmatter
  test_lg_validate_staged_keymap_reads_index
  test_lg_validate_staged_keymap_newline_path
  test_lg_validate_all_advisories_rc0
  test_lg_validate_all_concurrent_merge_finalize_dup
  test_lg_validate_plan_marks
  test_lg_validate_pushed_range

  # --- Task 8: renderers, view, publish ---
  test_lg_render_pure
  test_lg_render_clusters_and_unclustered
  test_lg_render_footer_recent_days
  test_lg_render_superseded_line
  test_lg_render_readme_rollup
  test_lg_html_self_contained
  test_lg_view_writes_files
  test_lg_publish_orphan_branch
  test_lg_publish_rejects_non_ff
  test_lg_publish_base_without_config
  test_lg_publish_base_only
  test_lg_publish_base_without_remote_prefix
  test_lg_publish_keeps_worktree_index
  test_lg_publish_push_failed_not_moved
  test_lg_render_hardening
  test_lg_registry_reserved_readme
  test_lg_publish_link_prefix

  # --- Task 8 review carry-over ---
  test_lg_publish_hook_declined_not_moved
  test_lg_render_resolution_first_nonempty
  test_lg_render_pr_url_pipe
  test_lg_rev_cache_ignores_head

  # --- Task 9: contracts, relations, trailers, re-check ---
  test_lg_contract_upstream_downstream
  test_lg_contract_siblings
  test_lg_relates_edges
  test_lg_related_candidates_paths
  test_lg_related_candidates_spec
  test_lg_recheck_lists_dependents
  test_lg_sweep_table_shape
  test_lg_link_validates
  test_lg_contracts_adapter_absent_ok
  test_lg_adapter_plugin_prefix_resolves
  test_lg_contract_registry_wins_over_adapter
  test_lg_contracts_adapter_failing_rc2
  test_lg_contracts_adapter_invalid_json_rc2
  test_lg_msg_claims_squash_bullets
  test_lg_recheck_marker_set_and_cleared
  test_lg_render_neighbours_and_suggestions
  test_lg_show_neighbours

  # --- Task 9 fix round 1 ---
  test_lg_recheck_window_side_branch
  test_lg_relates_edges_sorted_unique
  test_lg_recheck_verb_relates_kinds
  test_lg_msg_claims_case_sensitive
  test_lg_msg_claims_ref_no_colon
  test_lg_index_valid_needs_tail
  test_lg_recheck_base_not_head

  # --- Task 9 review carry-over (Task 10) ---
  test_lg_shallow_deepen_rebuilds_caches

  # --- Task 10: PR adapter, remote cache, review / merged status ---
  test_lg_pr_adapter_normalises
  test_lg_pr_adapter_gh_missing_rc2
  test_lg_remote_cache_ttl
  test_lg_remote_cache_refresh_flag
  test_lg_status_in_review
  test_lg_status_merged_open_item
  test_lg_view_stale_pr_marker

  # --- Task 10 fix round 1 ---
  test_lg_pr_adapter_open_limit_rc2
  test_lg_remote_offline
  test_lg_remote_cache_race_snapshot
  test_lg_pr_numbers_sorted_numerically

  # --- Task 10 fix round 2 ---
  test_lg_merged_pr_pinned_to_head_oid
  test_lg_base_claims_prune_race

  # --- Task 10 review carry-over (Task 11) ---
  test_lg_check_then_read_silent
  test_lg_pr_matches_shown_status

  # --- Task 11: in-flight scan, branch facts, inflight ---
  test_lg_inflight_sources
  test_lg_inflight_excludes_views_branch
  test_lg_inflight_dedup_host_name
  test_lg_inflight_detached_worktree
  test_lg_inflight_prune_on_fetch
  test_lg_inflight_unicode_branch
  test_lg_host_id_anonymous
  test_lg_branch_facts_claims_and_contracts
  test_lg_branch_facts_criss_cross
  test_lg_show_inflight_claims
  test_lg_view_publish_inflight
  test_lg_inflight_tip_move_keeps_index
  test_lg_inflight_disabled_zero_cost
  test_lg_inflight_fetch_offline
  test_lg_inflight_pull_refs

  # --- Task 11 fix round 1 ---
  test_lg_registry_failure_one_object
  test_lg_inflight_bg_scan_one_object
  test_lg_inflight_ref_prefix_guard
  test_lg_inflight_prefix_under_heads
  test_lg_inflight_raw_oid_base
  test_lg_inflight_dedup_descendant_wins
  test_lg_ifl_facts_sig_in_name

  # --- Task 11 fix round 3 ---
  test_lg_inflight_scan_children_reaped
  test_lg_inflight_heads_prefix_checked
  test_lg_inflight_fetch_recorded_only
  test_lg_verdict_backstop
  test_lg_inline_producer_die_one_object

  # --- Task 11 fix round 4 ---
  test_lg_inflight_mirror_cache_wiped
  test_lg_inflight_mirror_killed_before_record
  test_lg_inflight_mirror_adopt_cold
  test_lg_inflight_sigint_reaps_transport
  test_lg_inflight_anc_errors_uncached

  # --- Task 11 fix round 5 ---
  test_lg_inflight_heads_cold_ff_only

  # --- Task 12 ---
  test_lg_inflight_heads_differ_remedy
  test_lg_notice_contract_change_stop
  test_lg_notice_double_claim_stop
  test_lg_notice_file_overlap_headsup
  test_lg_notice_base_changed_contract
  test_lg_notice_sibling_info
  test_lg_notice_ack_hides_and_moved_head_refires
  test_lg_notices_gate_rc
  test_lg_inflight_push_and_pre_push_check
  test_lg_inflight_push_offline_warns
  test_lg_publish_prunes_inflight

  # --- Task 12 fix round 1 ---
  test_lg_notice_same_branch_other_host
  test_lg_notice_base_id_overlap_state
  test_lg_notice_id_shared_across_hosts
  test_lg_notice_branch_not_current_note
  test_lg_inflight_push_auth_failure
  test_lg_publish_prune_internal_failure_is_note

  # --- Task 12 fix round 2 ---
  test_lg_notice_id_remote_and_inflight_across_hosts
  test_lg_publish_prune_term_prompt

  # --- Task 13 ---
  test_lg_note_log_appends
  test_lg_note_ruling_heading
  test_lg_note_owed_set_and_clear
  test_lg_items_gh_list_normalises
  test_lg_items_gh_block_roundtrip
  test_lg_items_gh_close_reason_mapping
  test_lg_items_offline_stale_marker
  test_lg_validate_all_hosted_items
  test_lg_inflight_claims_by_ref_hosted
  test_lg_note_hosted_item
  test_lg_items_adapter_contract

  # --- Task 13 fix round 1 ---
  test_lg_items_gh_hostile_values
  test_lg_items_gh_block_markers
  test_lg_recheck_hosted_items

  # --- Task 14 ---
  test_lg_init_runs_without_config
  test_lg_init_usage_errors
  test_lg_init_report_writes_only_report_files
  test_lg_init_registry_proposal_mece
  test_lg_init_registry_hints_and_contracts
  test_lg_init_assignment_reasons
  test_lg_init_hub_files_downweighted
  test_lg_init_decisions_prefill
  test_lg_init_decisions_header
  test_lg_init_github_source
  test_lg_init_github_failure_explicit_vs_default
  test_lg_init_sources_suggestions

  # --- Task 14 fix round 1 ---
  test_lg_init_decisions_kept_across_reruns
  test_lg_init_report_path_guard
  test_lg_init_hub_floor
  test_lg_init_crash_fallback_not_enabled
  test_lg_init_custom_items_adapter_no_gh
  test_lg_init_legacy_rows_and_links
  test_lg_init_split_boundary_40
  test_lg_init_files_umask_mode
  test_lg_init_guard_same_file
  test_lg_init_stale_prefill_recomputed
  # --- Task 15 ---
  test_lg_init_accept_only_decided_rows
  test_lg_init_legacy_map_and_stub
  test_lg_init_legacy_ids_from_config
  test_lg_init_summaries_sources
  test_lg_init_keys_one_commit_date_order
  test_lg_init_first_views_rendered
  test_lg_init_idempotent
  test_lg_init_accept_dry_run
  test_lg_init_accept_validates_first
  test_lg_init_accept_registry_changed
  test_lg_init_accept_hosted_items
  test_lg_init_accept_hosted_stub
  test_lg_items_gh_get
  test_lg_init_import_converts_once
  test_lg_init_stub_dir_from_globs
  test_lg_init_stub_outside_globs_finding
  test_lg_init_import_outside_globs_finding
  test_lg_init_accept_trimmed_rows
  test_lg_init_stub_slug_collision_and_length
  test_lg_init_accept_malformed_and_duplicate_rows
  test_lg_init_import_list_field
  test_lg_init_rehome_malformed_aliases_finding
  test_lg_init_import_get_output_counts
  test_lg_init_accept_findings_before_offline
  test_lg_init_import_empty_globs_finding
  # --- Task 16b ---
  test_lg_ifl_plan_words_exact_tips
  test_lg_ifl_plan_words_large_batch
  test_lg_ifl_plan_words_stream_in_step
  test_lg_init_legacy_ledgers_only_named
  test_lg_init_hand_written_discovery_without_legacy_ledgers
  test_lg_init_preseeded_legacy_entries_authoritative
  test_lg_init_preseeded_legacy_keys_canonical
  test_lg_init_row_item_from_tracker_column
  test_lg_resolve_legacy_letter_rows
  test_lg_init_done_states_from_config

  print_summary
}

run_tests
