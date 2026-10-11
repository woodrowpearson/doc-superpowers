#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

# Run doc-tools.sh under the interpreter this suite was launched with,
# not whatever `#!/usr/bin/env bash` resolves to. See bash_bin_shim().
DOC_TOOLS="$(bash_bin_shim "$SCRIPT_DIR/doc-tools.sh")"

# --- Fixture helpers ----------------------------------------------------------
#
# Every claims test builds on claims_fixture: one governing spec with one
# sidecar claim (unbuilt, tracked), a config naming `main` as the base, all
# committed on main, then a `feature` branch checked out — so the merge-base
# the ratchets compare against is main's tip.

claims_fixture() {
  setup
  mkdir -p docs/specs docs/issues docs/spec-claims src/auth
  cat > docs/specs/SPEC-AUTH-001-token.md <<'EOF'
# SPEC-AUTH-001: Token lifetimes

**Status**: Draft
**Created**: 2026-10-10

## Summary

How long issued tokens stay valid.

## Requirements

- Access tokens expire after 15 minutes.
- Refresh tokens are single-use.

## Implementation Notes

Not started.

## Open Questions

| Question | Resolved |
|---|---|
| Rotate keys? | Keys rotate every 30 days. |
EOF
  printf 'TTL_SECONDS = 900\n' > src/auth/token.py
  cat > docs/issues/token-ttl.md <<'EOF'
# Token TTL

**Status**: Open

Build the 15-minute access-token expiry (SPEC-AUTH-001#token-ttl).
EOF
  printf '%s\n' '{"schema":1,"base":"main"}' > docs/spec-claims/config.json
  jq -n '{
    schema: 1,
    doc: "docs/specs/SPEC-AUTH-001-token.md",
    claims: [{
      id: "SPEC-AUTH-001#token-ttl",
      quote: "Access tokens expire after 15 minutes",
      states: "An issued access token is rejected 15 minutes after issue.",
      kind: "behaviour",
      subject: ["src/auth/token.py"],
      status: "unbuilt",
      enforced_by: "test",
      test: null,
      nonvacuity: null,
      promotion: null,
      tracker: "docs/issues/token-ttl.md",
      frozen_at: null,
      restates: [],
      rulings: []
    }]
  }' > docs/spec-claims/SPEC-AUTH-001.json
  git add -A && git commit -qm "claims fixture"
  git checkout -qb feature
}

# cl <verb> [args…]: run `doc-tools.sh claims <verb> args` from the fixture
# root (stdin closed, as a hook runs it); sets CL_RC, CL_OUT (stdout) and
# CL_ERR (stderr).
cl() {
  local err
  err=$(harness_mktemp cl-err)
  CL_RC=0
  CL_OUT=$("$DOC_TOOLS" claims "$@" 2>"$err" </dev/null) || CL_RC=$?
  CL_ERR=$(cat "$err")
  rm -f "$err"
}

# jset <file> <jq-filter>: rewrite a JSON file in place (keeping its mode).
jset() {
  local tmp
  tmp=$(harness_mktemp jset)
  jq "$2" "$1" > "$tmp"
  cat "$tmp" > "$1"
  rm -f "$tmp"
}

# The number of JSON values in $1 ("" → 0; not JSON → "invalid").
json_count() {
  jq -s 'length' <<<"$1" 2>/dev/null || echo invalid
}

# Every file named cl-emitted that a claims run could have left behind.
stray_markers() {
  find "$TEST_DIR" "$SUITE_TMP" -name cl-emitted 2>/dev/null || true
  if [ -e /cl-emitted ]; then echo /cl-emitted; fi
}

# --- Inert behaviour and argument order ---------------------------------------

test_inert_without_spec_claims_dir() {
  echo "test: no docs/spec-claims/ → every claims verb is inert"
  setup
  local v
  for v in validate run promote render gate attest rulings; do
    cl "$v"
    assert_eq "0" "$CL_RC" "claims $v exits 0 without docs/spec-claims/"
    assert_json_field "$CL_OUT" '.enabled' "false" "claims $v reports enabled:false"
    assert_json_field "$CL_OUT" '.exit' "0" "claims $v reports exit 0"
    assert_eq "1" "$(json_count "$CL_OUT")" "claims $v prints exactly one JSON object"
  done
  teardown
}

test_inert_runs_before_required_args() {
  echo "test: the inert check runs after option parsing and before required-argument checks"
  setup
  cl gate
  assert_eq "0" "$CL_RC" "inert: claims gate without --plan exits 0"
  assert_json_field "$CL_OUT" '.enabled' "false" "inert: claims gate without --plan reports enabled:false"
  cl validate
  assert_eq "0" "$CL_RC" "inert: claims validate without a mode exits 0"
  assert_json_field "$CL_OUT" '.enabled' "false" "inert: claims validate without a mode reports enabled:false"
  cl validate --bogus
  assert_eq "3" "$CL_RC" "inert: an unknown option still exits 3 (options are parsed first)"
  teardown
}

test_usage_errors_exit_3() {
  echo "test: claims usage errors exit 3; other verbs keep exit 2"
  claims_fixture
  cl validate --bogus
  assert_eq "3" "$CL_RC" "claims validate --bogus exits 3"
  assert_contains "$CL_ERR" "--bogus" "…naming the option on stderr"
  cl frobnicate
  assert_eq "3" "$CL_RC" "claims frobnicate exits 3"
  cl validate --staged --all
  assert_eq "3" "$CL_RC" "claims validate --staged --all exits 3"
  cl validate
  assert_eq "3" "$CL_RC" "claims validate with neither --staged nor --all exits 3"
  cl gate
  assert_eq "3" "$CL_RC" "claims gate without --plan exits 3"
  cl gate --plan docs/plans/p.md
  assert_eq "3" "$CL_RC" "claims gate without --chunk exits 3"
  cl promote
  assert_eq "3" "$CL_RC" "claims promote without <id> exits 3"
  cl attest
  assert_eq "3" "$CL_RC" "claims attest without --plan exits 3"
  cl rulings
  assert_eq "3" "$CL_RC" "claims rulings without --range exits 3"
  cl rulings --range HEAD
  assert_eq "3" "$CL_RC" "claims rulings --range without '..' exits 3"
  cl rulings --range HEAD..HEAD --format yaml
  assert_eq "3" "$CL_RC" "claims rulings --format yaml exits 3"
  local rc=0
  "$DOC_TOOLS" claims </dev/null >/dev/null 2>&1 || rc=$?
  assert_eq "3" "$rc" "claims with no subcommand exits 3"
  rc=0
  "$DOC_TOOLS" status --bogus </dev/null >/dev/null 2>&1 || rc=$?
  assert_eq "2" "$rc" "the general verb status --bogus still exits 2"
  rc=0
  "$DOC_TOOLS" frobnicate </dev/null >/dev/null 2>&1 || rc=$?
  assert_eq "2" "$rc" "an unknown general subcommand still exits 2"
  teardown
}

test_claims_help_exits_0() {
  echo "test: claims --help and claims <verb> --help exit 0 and print the usage"
  claims_fixture
  local rc=0 out
  out=$("$DOC_TOOLS" claims --help 2>&1) || rc=$?
  assert_eq "0" "$rc" "claims --help exits 0"
  assert_contains "$out" "doc-tools.sh claims validate" "claims --help lists claims validate"
  assert_contains "$out" "doc-tools.sh claims rulings" "claims --help lists claims rulings"
  rc=0
  out=$("$DOC_TOOLS" claims gate --help 2>&1) || rc=$?
  assert_eq "0" "$rc" "claims gate --help exits 0"
  assert_contains "$out" "--plan" "claims gate --help names --plan"
  out=$("$DOC_TOOLS" --help 2>&1) || true
  assert_contains "$out" "Spec claims" "--help carries the Spec claims note"
  assert_contains "$out" "1 > 2 > 0" "…with the exit-code precedence"
  teardown
}

# --- Exit discipline: internal failures are 2, one verdict object -------------

test_internal_failure_exit_2_never_1() {
  echo "test: a scratch-creation failure exits 2 with one verdict object and no marker anywhere"
  claims_fixture
  TMPDIR="$SUITE_TMP/absent" cl validate --all
  assert_eq "2" "$CL_RC" "mktemp -d failure exits 2, never 1"
  assert_eq "1" "$(json_count "$CL_OUT")" "stdout holds exactly one JSON object"
  assert_json_field "$CL_OUT" '.error | test("mktemp")' "true" ".error names mktemp"
  assert_json_field "$CL_OUT" '.exit' "2" ".exit is 2"
  assert_json_field "$CL_OUT" '.enabled' "true" ".enabled is true"
  assert_eq "" "$(stray_markers)" "no cl-emitted file anywhere (not /cl-emitted, not in the fixture or suite tmp)"
  # A marker write to "/cl-emitted" (an empty \$_SCRATCH) fails on / and says so.
  assert_not_contains "$CL_ERR" "cl-emitted" "nothing tried to write a cl-emitted path"
  teardown
}

test_usage_error_no_stray_marker() {
  echo "test: a usage error before scratch exists records its marker as a variable only"
  claims_fixture
  local tmp
  # Scratch dirs land under the suite root, where stray_markers looks.
  tmp=$(harness_mktemp_d scratch)
  TMPDIR="$tmp" cl validate --bogus
  assert_eq "3" "$CL_RC" "claims validate --bogus exits 3"
  assert_eq "" "$CL_OUT" "a usage error prints nothing on stdout (no internal-failure object)"
  assert_eq "" "$(stray_markers)" "no cl-emitted file anywhere"
  assert_not_contains "$CL_ERR" "cl-emitted" "nothing tried to write a cl-emitted path"
  assert_eq "" "$(ls -A "$tmp")" "no scratch dir was created before the usage error"
  # After _claims_init (scratch exists), a required-argument usage error is
  # still 3, still prints no object, and the scratch dir (with its marker)
  # is removed.
  TMPDIR="$tmp" cl validate
  assert_eq "3" "$CL_RC" "a required-argument usage error after scratch exists exits 3"
  assert_eq "" "$CL_OUT" "…and prints nothing on stdout"
  assert_eq "" "$(stray_markers)" "…and leaves no cl-emitted file"
  assert_eq "" "$(ls -A "$tmp")" "…and its scratch dir is removed"
  teardown
}

test_die_in_subshell_single_verdict() {
  echo "test: _claims_die inside \$(…) emits one verdict; the parent propagates, printing nothing more"
  claims_fixture
  local shim real
  shim=$(harness_mktemp_d jq-shim)
  real=$(command -v jq)
  # Fails only the config-merge program: the one jq call whose argv carries
  # the defaults (governing_extra).
  cat > "$shim/jq" <<EOF
#!/bin/sh
for a in "\$@"; do
  case "\$a" in *governing_extra*) exit 5 ;; esac
done
exec "$real" "\$@"
EOF
  chmod +x "$shim/jq"
  PATH="$shim:$PATH" cl validate --all
  assert_eq "2" "$CL_RC" "a jq failure inside \$(…) exits 2"
  assert_eq "1" "$(json_count "$CL_OUT")" "stdout holds exactly one JSON object (no second from the EXIT trap)"
  assert_json_field "$CL_OUT" '.error | length > 0' "true" ".error is non-empty"
  assert_json_field "$CL_OUT" '.error | test("config-merge")' "true" ".error names the failing jq call"
  assert_json_field "$CL_OUT" '.exit' "2" ".exit is 2"
  teardown
}

# A crash no emitter saw (an unbound variable under set -u) still ends with
# exit 2 and exactly one object: the EXIT trap's fallback.
test_internal_crash_fallback_object() {
  echo "test: an unhandled crash in a claims verb exits 2 with the internal-failure object"
  claims_fixture
  local dir
  dir=$(harness_mktemp_d crash)
  awk '
    { print }
    $0 == "cmd_claims_render() {" { in_fn = 1; next }
    in_fn && !done && /_claims_init / { print "  : \"$_CL_NEVER_SET_PROBE\""; done = 1 }
  ' "$SCRIPT_DIR/doc-tools.sh" > "$dir/doc-tools.sh"
  assert_true "precondition: the probe was injected" grep -q _CL_NEVER_SET_PROBE "$dir/doc-tools.sh"
  local crash rc=0 out err
  crash=$(bash_bin_shim "$dir/doc-tools.sh")
  err=$(harness_mktemp crash-err)
  out=$("$crash" claims render 2>"$err" </dev/null) || rc=$?
  assert_contains "$(cat "$err")" "unbound variable" "precondition: the run crashed on the probe"
  assert_eq "2" "$rc" "the crash exits 2, never 1 (or 0)"
  assert_eq "1" "$(json_count "$out")" "stdout holds exactly one JSON object"
  assert_json_field "$out" '.error | startswith("internal failure (rc ")' "true" ".error is the internal-failure fallback"
  assert_json_field "$out" '.verb' "render" ".verb names the claims verb"
  assert_json_field "$out" '.exit' "2" ".exit is 2"
  teardown
}

# check_deps failing (no jq) is "could not run" for a claims verb: 2, with a
# verdict object built without jq.
test_missing_jq_exit_2() {
  echo "test: a claims verb without jq exits 2 with one verdict object"
  claims_fixture
  local bare cmd p
  bare=$(harness_mktemp_d no-jq)
  for cmd in git dirname mktemp cat rm sha256sum shasum; do
    p=$(command -v "$cmd" 2>/dev/null) || continue
    ln -s "$p" "$bare/$cmd"
  done
  PATH="$bare" cl validate --all
  assert_contains "$CL_ERR" "required command not found: jq" "precondition: check_deps reported jq missing"
  assert_eq "2" "$CL_RC" "no jq: exits 2, not 1"
  assert_eq "1" "$(json_count "$CL_OUT")" "stdout holds exactly one JSON object"
  assert_json_field "$CL_OUT" '.exit' "2" ".exit is 2"
  assert_json_field "$CL_OUT" '.verb' "validate" ".verb names the claims verb"
  local rc=0
  PATH="$bare" "$DOC_TOOLS" status docs/architecture.md </dev/null >/dev/null 2>&1 || rc=$?
  assert_eq "1" "$rc" "a general verb without jq still exits 1"
  teardown
}

test_rulings_markdown_exit_0() {
  echo "test: claims rulings --format markdown prints Markdown and exits 0"
  claims_fixture
  cl rulings --range HEAD..HEAD --format markdown
  assert_eq "0" "$CL_RC" "rulings --format markdown exits 0 (not mapped to 2)"
  assert_eq "## Spec amendments (0)" "$(head -n 1 <<<"$CL_OUT")" "stdout starts with the amendments heading"
  assert_eq "invalid" "$(json_count "$CL_OUT")" "stdout is Markdown, not JSON"
  cl rulings --range HEAD..HEAD
  assert_eq "0" "$CL_RC" "rulings (json) exits 0"
  assert_json_field "$CL_OUT" '.results' "[]" "rulings (json) reports empty results"
  assert_json_field "$CL_OUT" '.verb' "rulings" "rulings (json) names its verb"
  teardown
}

# --- Config, base and the verdict object -------------------------------------

test_enabled_verdict_shape() {
  echo "test: an enabled run prints the full verdict object"
  claims_fixture
  cl validate --all
  assert_eq "0" "$CL_RC" "validate --all on the fixture exits 0"
  assert_eq "1" "$(json_count "$CL_OUT")" "stdout holds exactly one JSON object"
  assert_json_field "$CL_OUT" '.verb' "validate" ".verb"
  assert_json_field "$CL_OUT" '.enabled' "true" ".enabled"
  assert_json_field "$CL_OUT" '.exit' "0" ".exit"
  assert_json_field "$CL_OUT" '.base.ref' "main" ".base.ref comes from config base"
  assert_json_field "$CL_OUT" '.base.merge_base' "$(git merge-base HEAD main)" ".base.merge_base is merge-base HEAD main"
  assert_json_field "$CL_OUT" '[.findings, .advisories, .indeterminate, .results] | map(type == "array") | all' "true" "the four row lists are arrays"
  cl validate --all --base HEAD
  assert_json_field "$CL_OUT" '.base.ref' "HEAD" "--base overrides config base"
  jset docs/spec-claims/config.json 'del(.base)'
  git branch -q origin/main main 2>/dev/null || true
  cl validate --all
  assert_json_field "$CL_OUT" '.base.ref' "origin/main" "without --base or config base, the base is origin/main"
  teardown
}

test_base_unresolvable_indeterminate() {
  echo "test: an unresolvable base is indeterminate (exit 2)"
  claims_fixture
  jset docs/spec-claims/config.json '.base = "nope"'
  cl validate --all
  assert_eq "2" "$CL_RC" "an unresolvable base exits 2"
  assert_json_field "$CL_OUT" '.indeterminate[0].reason' "base-unresolvable" "indeterminate reason base-unresolvable"
  assert_json_field "$CL_OUT" '.indeterminate[0].check' "V6" "…reported under V6"
  assert_json_field "$CL_OUT" '.indeterminate[0].claim' "null" "…for no single claim"
  assert_json_field "$CL_OUT" '.base.merge_base' "null" ".base.merge_base is null"
  teardown
}

test_config_malformed_exit_2() {
  echo "test: a config.json that is not one JSON object exits 2"
  claims_fixture
  local body
  for body in 'not json' '[1,2]' '{"schema":1} {"schema":1}' ''; do
    printf '%s\n' "$body" > docs/spec-claims/config.json
    cl validate --all
    assert_eq "2" "$CL_RC" "config '$body' exits 2"
    assert_eq "1" "$(json_count "$CL_OUT")" "config '$body': exactly one JSON object"
    assert_json_field "$CL_OUT" '.error | test("config.json")' "true" "config '$body': .error names config.json"
  done
  # Well-formed JSON whose values the merge cannot use is a could-not-run too.
  printf '%s\n' '{"governing":"docs/*.md"}' > docs/spec-claims/config.json
  cl validate --all
  assert_eq "2" "$CL_RC" "a governing that is not an array exits 2"
  assert_eq "1" "$(json_count "$CL_OUT")" "…with exactly one JSON object"
  teardown
}

test_config_optional_defaults_apply() {
  echo "test: config.json is optional; findings block per the default blocking list"
  claims_fixture
  rm docs/spec-claims/config.json
  git branch -q origin/main main
  cl validate --all
  assert_eq "0" "$CL_RC" "no config.json: validate --all exits 0"
  assert_json_field "$CL_OUT" '.base.ref' "origin/main" "…with the default base"
  teardown
}

test_v1_config_unknown_key() {
  echo "test: an unknown config key is a V1 finding"
  claims_fixture
  jset docs/spec-claims/config.json '.bogus = 1'
  cl validate --all
  assert_eq "1" "$CL_RC" "an unknown config key exits 1"
  assert_json_field "$CL_OUT" '.findings[0].check' "V1" "the finding is V1"
  assert_json_field "$CL_OUT" '.findings[0].message' "config: unknown key bogus" "…naming the key"
  # Not blocking when V1 is dropped from the config's blocking list.
  jset docs/spec-claims/config.json '.blocking = ["V2"]'
  cl validate --all
  assert_eq "0" "$CL_RC" "a finding whose check is not blocking exits 0"
  assert_json_field "$CL_OUT" '.advisories[0].check' "V1" "…and is reported as an advisory"
  assert_json_field "$CL_OUT" '.findings' "[]" "…not as a finding"
  teardown
}

# The verbs whose handlers later tasks write: enabled, each prints exactly one
# verdict object and never exits 3 (or anything outside the family).
test_stub_verbs_enabled() {
  echo "test: every enabled claims verb prints one verdict object"
  claims_fixture
  local v
  for v in "validate --all" "run --all" "promote SPEC-AUTH-001#token-ttl" "render" \
           "gate --plan docs/plans/p.md --chunk 1" "attest --plan docs/plans/p.md" "rulings --range HEAD..HEAD"; do
    # shellcheck disable=SC2086  # the verb and its arguments are words
    cl $v
    assert_true "claims $v exits 0, 1 or 2 (rc=$CL_RC)" test "$CL_RC" -le 2
    assert_json_field "$CL_OUT" '.enabled' "true" "claims $v reports enabled:true"
    assert_eq "1" "$(json_count "$CL_OUT")" "claims $v prints exactly one JSON object"
  done
  teardown
}

run_tests() {
  echo "Running spec-claims tests..."
  echo ""

  # --- Task 1: verb group, exit-code family, verdict emitter, config, inert ---
  test_inert_without_spec_claims_dir
  test_inert_runs_before_required_args
  test_usage_errors_exit_3
  test_claims_help_exits_0
  test_internal_failure_exit_2_never_1
  test_usage_error_no_stray_marker
  test_die_in_subshell_single_verdict
  test_internal_crash_fallback_object
  test_missing_jq_exit_2
  test_rulings_markdown_exit_0
  test_enabled_verdict_shape
  test_base_unresolvable_indeterminate
  test_config_malformed_exit_2
  test_config_optional_defaults_apply
  test_v1_config_unknown_key
  test_stub_verbs_enabled

  print_summary
}

run_tests
