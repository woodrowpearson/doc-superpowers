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
  echo "test: without docs/ledger/config.json every ledger verb prints the inert line and exits 0"
  lg_fixture
  local v
  for v in $LG_VERBS; do
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

test_lg_stub_not_implemented() {
  echo "test: an enabled verb with no implementation yet exits 2 with one object"
  lg_fixture
  lg_enable
  lg show x-1 --format json
  assert_eq "2" "$LG_RC" "stub exits 2"
  assert_eq "1" "$(json_count "$LG_OUT")" "exactly one object"
  assert_json_field "$LG_OUT" '.verb' "ledger show" ".verb is 'ledger show'"
  assert_json_field "$LG_OUT" '.enabled' "true" ".enabled is true"
  assert_json_field "$LG_OUT" '.exit' "2" ".exit is 2"
  assert_json_field "$LG_OUT" '.error' "not implemented" ".error"
  lg show x-1
  assert_eq "2" "$LG_RC" "text mode: exits 2"
  assert_eq "" "$LG_OUT" "text mode: nothing on stdout"
  assert_contains "$LG_ERR" "not implemented" "text mode: stderr says why"
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
  # Blobs: keyed by blob id.
  lg_nul_list "$paths" docs/issues/b.md
  DOC_TOOLS_LEDGER_TRACE=1 _lg_parse_blobs HEAD "$paths" "$out" 2> "$err"
  assert_eq "parse-miss docs/issues/b.md" "$(cat "$err")" "first blob parse: a miss"
  DOC_TOOLS_LEDGER_TRACE=1 _lg_parse_blobs HEAD "$paths" "$out" 2> "$err"
  assert_eq "" "$(cat "$err")" "second blob parse: a hit"
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
  test_lg_stub_not_implemented
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

  print_summary
}

run_tests
