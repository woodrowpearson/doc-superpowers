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

  print_summary
}

run_tests
