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
  assert_usage_verdict validate false "inert: an unknown option (options are parsed first)"
  teardown
}

# After `cl`: rc 3 and exactly one usage verdict on stdout, for verb $1
# (enabled $2).
assert_usage_verdict() {
  local verb="$1" enabled="$2" what="$3"
  assert_eq "3" "$CL_RC" "$what exits 3"
  assert_eq "1" "$(json_count "$CL_OUT")" "$what prints exactly one JSON object"
  assert_json_field "$CL_OUT" '.exit' "3" "$what: .exit is 3"
  assert_json_field "$CL_OUT" '.verb' "$verb" "$what: .verb is $verb"
  assert_json_field "$CL_OUT" '.enabled' "$enabled" "$what: .enabled is $enabled"
  assert_json_field "$CL_OUT" '.error | length > 0' "true" "$what: .error is non-empty"
}

test_usage_errors_exit_3() {
  echo "test: claims usage errors exit 3 with one verdict object; other verbs keep exit 2"
  claims_fixture
  cl validate --bogus
  assert_usage_verdict validate true "claims validate --bogus"
  assert_contains "$CL_ERR" "--bogus" "…naming the option on stderr"
  assert_json_field "$CL_OUT" '.error | test("--bogus")' "true" "…and in .error"
  cl frobnicate
  assert_usage_verdict frobnicate true "claims frobnicate"
  cl
  assert_usage_verdict claims true "claims with no subcommand"
  cl validate --staged --all
  assert_usage_verdict validate true "claims validate --staged --all"
  cl validate
  assert_usage_verdict validate true "claims validate with neither --staged nor --all"
  cl gate
  assert_usage_verdict gate true "claims gate without --plan"
  cl gate --plan docs/plans/p.md
  assert_usage_verdict gate true "claims gate without --chunk"
  cl promote
  assert_usage_verdict promote true "claims promote without <id>"
  cl attest
  assert_usage_verdict attest true "claims attest without --plan"
  cl rulings
  assert_usage_verdict rulings true "claims rulings without --range"
  cl rulings --range HEAD
  assert_usage_verdict rulings true "claims rulings --range without '..'"
  cl rulings --range HEAD..HEAD --format yaml
  assert_usage_verdict rulings true "claims rulings --format yaml"
  local rc=0 out
  out=$("$DOC_TOOLS" status --bogus </dev/null 2>/dev/null) || rc=$?
  assert_eq "2" "$rc" "the general verb status --bogus still exits 2"
  assert_eq "" "$out" "…printing nothing on stdout"
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
  assert_usage_verdict validate true "claims validate --bogus"
  assert_eq "" "$(stray_markers)" "no cl-emitted file anywhere"
  assert_not_contains "$CL_ERR" "cl-emitted" "nothing tried to write a cl-emitted path"
  assert_eq "" "$(ls -A "$tmp")" "no scratch dir was created before the usage error"
  # After _claims_init (scratch exists), a required-argument usage error is
  # still 3, still prints no object, and the scratch dir (with its marker)
  # is removed.
  TMPDIR="$tmp" cl validate
  assert_usage_verdict validate true "a required-argument usage error after scratch exists"
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
  # A name of its own: bash_bin_shim names the shim by basename, so
  # "doc-tools.sh" would replace $DOC_TOOLS's shim for the rest of the suite.
  mv "$dir/doc-tools.sh" "$dir/dt-crash.sh"
  crash=$(bash_bin_shim "$dir/dt-crash.sh")
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

# claims_probe <before|after> <line>: a copy of doc-tools.sh whose
# cmd_claims_render runs <line> just before (no scratch dir yet: the
# variable-only marker) or just after (scratch exists: the marker file) its
# _claims_init call. Echoes its shim. <line> must hold no backslash (awk -v).
_CL_PROBES=0
claims_probe() {
  local where="$1" line="$2" dir
  _CL_PROBES=$((_CL_PROBES + 1))
  dir=$(harness_mktemp_d probe)
  awk -v where="$where" -v probe="$line" '
    $0 == "cmd_claims_render() {" { in_fn = 1 }
    in_fn && !done && /_claims_init / {
      if (where == "before") print "  " probe
      print
      if (where == "after") print "  " probe
      done = 1
      next
    }
    { print }' "$SCRIPT_DIR/doc-tools.sh" > "$dir/dt-probe-$_CL_PROBES.sh"
  grep -qF -- "$line" "$dir/dt-probe-$_CL_PROBES.sh" || { echo "probe not injected: $line" >&2; return 1; }
  bash_bin_shim "$dir/dt-probe-$_CL_PROBES.sh"
}

# The run ends with the code its verdict printed, whatever status reaches the
# EXIT trap: a parent's `|| exit 1` after a subshell's die (doc-tools' own
# idiom), or a bare exit 0 that the unfinished-run rule turns into 1.
test_emitted_code_survives_trap() {
  echo "test: a claims run exits with the code its verdict printed"
  claims_fixture
  local probe rc out case where line want
  for case in \
    'after|x=$(_die "helper failed") || exit 1|2' \
    'after|x=$(_claims_mark_emitted 3; _claims_out "{}"; exit 3) || exit 1|3' \
    'after|x=$(_claims_mark_emitted 0; _claims_out "{}"; exit 0); exit 0|0' \
    'after|x=$(_claims_mark_emitted 1; _claims_out "{}"; exit 1) || exit 0|1' \
    'before|_claims_mark_emitted 0; _claims_out "{}"; exit 0|0' \
    'before|_claims_mark_emitted 2; _claims_out "{}"; exit 1|2' \
    'before|_claims_mark_emitted 3; _claims_out "{}"; exit 0|3' \
    'before|_claims_mark_emitted 1; _claims_out "{}"; exit 0|1'; do
    where="${case%%|*}"
    line="${case#*|}"
    want="${line##*|}"
    line="${line%|*}"
    probe=$(claims_probe "$where" "$line")
    rc=0
    out=$("$probe" claims render </dev/null 2>/dev/null) || rc=$?
    assert_eq "$want" "$rc" "$where init: '$line' exits $want"
    assert_eq "1" "$(json_count "$out")" "$where init: '$line' prints exactly one JSON object"
  done
  probe=$(claims_probe after 'x=$(_die "helper failed") || exit 1')
  out=$("$probe" claims render </dev/null 2>/dev/null) || true
  assert_json_field "$out" '.error' "helper failed" "the subshell's die verdict is the one printed"
  assert_json_field "$out" '.exit' "2" "…and its exit field matches the process's"
  teardown
}

# A closed stderr must cost neither the verdict nor its exit code.
test_stderr_closed_still_one_verdict() {
  echo "test: with stderr closed, a die and a usage error still print one verdict with their code"
  claims_fixture
  local rc out
  printf '%s\n' 'not json' > docs/spec-claims/config.json
  rc=0
  out=$("$DOC_TOOLS" claims validate --all </dev/null 2>&-) || rc=$?
  assert_eq "2" "$rc" "die with stderr closed: exits 2"
  assert_eq "1" "$(json_count "$out")" "die with stderr closed: exactly one JSON object"
  assert_json_field "$out" '.exit' "2" "die with stderr closed: .exit is 2"
  git checkout -q -- docs/spec-claims/config.json
  rc=0
  out=$("$DOC_TOOLS" claims validate --bogus </dev/null 2>&-) || rc=$?
  assert_eq "3" "$rc" "usage error (before scratch) with stderr closed: exits 3"
  assert_eq "1" "$(json_count "$out")" "usage error (before scratch) with stderr closed: exactly one JSON object"
  assert_json_field "$out" '.exit' "3" "usage error (before scratch) with stderr closed: .exit is 3"
  rc=0
  out=$("$DOC_TOOLS" claims validate </dev/null 2>&-) || rc=$?
  assert_eq "3" "$rc" "usage error (after scratch) with stderr closed: exits 3"
  assert_eq "1" "$(json_count "$out")" "usage error (after scratch) with stderr closed: exactly one JSON object"
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

# --- V1 schema -----------------------------------------------------------------

SIDECAR=docs/spec-claims/SPEC-AUTH-001.json

# The last `cl`'s V1 finding messages, one per line, and their count.
v1_messages() {
  jq -r '.findings[]? | select(.check == "V1") | .message' <<<"$CL_OUT" 2>/dev/null || true
}
v1_count() {
  jq '[.findings[]? | select(.check == "V1")] | length' <<<"$CL_OUT" 2>/dev/null || echo invalid
}
v2_count() {
  jq '[.findings[]?, .advisories[]? | select(.check == "V2")] | length' <<<"$CL_OUT" 2>/dev/null || echo invalid
}

# assert_v1 <substring> <what>: the last `cl` exited 1 with a V1 finding whose
# message contains <substring>.
assert_v1() {
  assert_eq "1" "$CL_RC" "$2: exits 1"
  assert_contains "$(v1_messages)" "$1" "$2: a V1 finding names '$1'"
}

# assert_no_v1 <what>: the last `cl` reported no V1 finding (its rc is left
# to the later checks).
assert_no_v1() {
  assert_eq "0" "$(v1_count)" "$1: no V1 finding"
}

# A RETIRE ruling recorded in the fixture's issue doc.
_CL_RETIRE='{"date":"2026-10-11","direction":"RETIRE","by":"doc-owner","record":"docs/issues/token-ttl.md","reason":"The spec was archived."}'

test_v1_valid_fixture_passes() {
  echo "test: V1 — the fixture sidecar is valid"
  claims_fixture
  cl validate --all
  assert_eq "0" "$CL_RC" "validate --all on the fixture exits 0"
  assert_json_field "$CL_OUT" '.findings' "[]" "no findings"
  teardown
}

test_v1_malformed_record() {
  echo "test: V1 — a claim record missing a required field"
  claims_fixture
  jset "$SIDECAR" 'del(.claims[0].states)'
  cl validate --all
  assert_v1 "states" "a claim without states"
  assert_json_field "$CL_OUT" '[.findings[] | select(.check == "V1")][0].claim' "SPEC-AUTH-001#token-ttl" "…the finding names the claim"
  assert_json_field "$CL_OUT" '[.findings[] | select(.check == "V1")][0].doc' "docs/specs/SPEC-AUTH-001-token.md" "…and its doc"
  local f
  for f in id quote kind subject status enforced_by; do
    git checkout -q -- "$SIDECAR"
    jset "$SIDECAR" "del(.claims[0].$f)"
    cl validate --all
    assert_v1 "missing required field $f" "a claim without $f"
  done
  git checkout -q -- "$SIDECAR"
  jset "$SIDECAR" '.claims[0].subject = "src/auth/token.py"'
  cl validate --all
  assert_v1 "subject" "a subject that is not an array"
  git checkout -q -- "$SIDECAR"
  jset "$SIDECAR" '.claims[0].quote = ""'
  cl validate --all
  assert_v1 "quote" "an empty quote"
  teardown
}

test_v1_bad_id() {
  echo "test: V1 — an id that is not <DOC-ID>#<slug>"
  claims_fixture
  jset "$SIDECAR" '.claims[0].id = "SPEC-AUTH-001-token-ttl"'
  cl validate --all
  assert_v1 "id" "id SPEC-AUTH-001-token-ttl"
  local id
  for id in "SPEC-AUTH-002#token-ttl" "SPEC-AUTH-001#Token-TTL" "SPEC-AUTH-001#-ttl" "SPEC-AUTH-001#" "SPEC-AUTH-001#a#b"; do
    git checkout -q -- "$SIDECAR"
    jset "$SIDECAR" ".claims[0].id = \"$id\""
    cl validate --all
    assert_v1 "id $id is not SPEC-AUTH-001#<slug>" "id $id"
  done
  teardown
}

test_v1_duplicate_id() {
  echo "test: V1 — ids are unique across all sidecars"
  claims_fixture
  jset "$SIDECAR" '.claims += [.claims[0]]'
  cl validate --all
  assert_v1 "duplicate" "a claim copied within its sidecar"
  assert_eq "1" "$(v1_messages | grep -c duplicate)" "…one finding for the duplicated id"
  git checkout -q -- "$SIDECAR"
  # The same id in another doc's sidecar.
  mkdir -p docs/adr
  printf '# ADR-007: Cache tokens\n\n## Decision\n\nCache tokens for 5 minutes.\n' > docs/adr/ADR-007-cache.md
  jq '.doc = "docs/adr/ADR-007-cache.md"' "$SIDECAR" > docs/spec-claims/ADR-007.json
  cl validate --all
  assert_v1 "duplicate id SPEC-AUTH-001#token-ttl" "the same id in two sidecars"
  teardown
}

test_v1_doc_not_governing() {
  echo "test: V1 — a sidecar's doc must be governing"
  claims_fixture
  printf '# Notes\n\nAccess tokens expire after 15 minutes.\n' > docs/notes.md
  jset "$SIDECAR" '.doc = "docs/notes.md"'
  cl validate --all
  assert_v1 "not governing" "doc docs/notes.md"
  assert_contains "$(v1_messages)" "docs/notes.md" "…the finding names the doc"
  assert_eq "1" "$(v1_count)" "…and is the only V1 finding (no stem or id storm)"
  # Under a governing glob, but without a DOC-ID prefix.
  cp docs/notes.md docs/specs/template.md
  jset "$SIDECAR" '.doc = "docs/specs/template.md"'
  cl validate --all
  assert_v1 "not governing" "doc docs/specs/template.md (no DOC-ID)"
  teardown
}

test_v1_stem_mismatch() {
  echo "test: V1 — the sidecar stem must equal its doc's DOC-ID"
  claims_fixture
  git mv "$SIDECAR" docs/spec-claims/SPEC-AUTH-002.json
  cl validate --all
  assert_v1 "stem" "sidecar SPEC-AUTH-002.json for SPEC-AUTH-001"
  assert_contains "$(v1_messages)" "SPEC-AUTH-001.json" "…naming the stem it should have"
  teardown
}

test_v1_host_glob_doc_id_is_stem() {
  echo "test: V1 — a doc under a governing_extra glob has its file stem as DOC-ID"
  claims_fixture
  jset docs/spec-claims/config.json '.governing_extra = ["docs/evals/*.md"]'
  mkdir -p docs/evals
  cat > docs/evals/prereg-a.md <<'EOF'
# Pre-registration A

## Requirements

- The holdout set holds 500 examples.
EOF
  jq -n '{schema: 1, doc: "docs/evals/prereg-a.md", claims: [{
    id: "prereg-a#holdout-size", quote: "The holdout set holds 500 examples",
    states: "The evaluation holdout set has exactly 500 examples.",
    kind: "behaviour", subject: ["src/auth/token.py"], status: "unbuilt",
    enforced_by: "test", test: null, nonvacuity: null, promotion: null,
    tracker: "docs/issues/token-ttl.md", frozen_at: null, restates: [], rulings: []}]}' \
    > docs/spec-claims/prereg-a.json
  cl validate --all
  assert_eq "0" "$CL_RC" "a host-glob doc's sidecar named by its stem exits 0"
  assert_no_v1 "host-glob doc, sidecar prereg-a.json"
  # Without the host glob the same doc is not governing.
  jset docs/spec-claims/config.json 'del(.governing_extra)'
  cl validate --all
  assert_v1 "not governing" "the same doc without governing_extra"
  teardown
}

test_v1_adr_doc_id_prefix() {
  echo "test: V1 — an ADR's DOC-ID is its ADR-NNN filename prefix"
  claims_fixture
  mkdir -p docs/adr
  printf '# ADR-007: Cache tokens\n\n## Decision\n\nCache tokens for 5 minutes.\n' > docs/adr/ADR-007-cache.md
  jq '.doc = "docs/adr/ADR-007-cache.md" | .claims[0].id = "ADR-007#cache-ttl"
      | .claims[0].quote = "Cache tokens for 5 minutes"' "$SIDECAR" > docs/spec-claims/ADR-007.json
  cl validate --all
  assert_no_v1 "sidecar ADR-007.json for docs/adr/ADR-007-cache.md"
  jset docs/spec-claims/ADR-007.json '.claims[0].id = "ADR-7#cache-ttl"'
  cl validate --all
  assert_v1 "id ADR-7#cache-ttl is not ADR-007#<slug>" "an ADR claim id with the wrong DOC-ID"
  teardown
}

test_v1_ruling_missing_reason() {
  echo "test: V1 — a DOC-STALE or RETIRE ruling needs a reason"
  claims_fixture
  jset "$SIDECAR" '.claims[0].rulings = [{"date":"2026-10-11","direction":"DOC-STALE","by":"doc-owner","record":"docs/issues/token-ttl.md"}]'
  cl validate --all
  assert_v1 "reason" "a DOC-STALE ruling without reason"
  jset "$SIDECAR" '.claims[0].rulings[0].direction = "RETIRE" | .claims[0].rulings[0].reason = ""'
  cl validate --all
  assert_v1 "reason" "a RETIRE ruling with an empty reason"
  jset "$SIDECAR" '.claims[0].rulings[0].direction = "CODE-DIVERGES" | del(.claims[0].rulings[0].reason)'
  cl validate --all
  assert_no_v1 "a CODE-DIVERGES ruling without reason"
  teardown
}

test_v1_ruling_fields() {
  echo "test: V1 — a ruling needs date YYYY-MM-DD, a known direction, by and record"
  claims_fixture
  jset "$SIDECAR" '.claims[0].rulings = [{"date":"10/11/2026","direction":"MAYBE","by":"","reason":"x"}]'
  cl validate --all
  assert_v1 "date" "a ruling dated 10/11/2026"
  assert_contains "$(v1_messages)" "direction" "…an unknown direction is named"
  assert_contains "$(v1_messages)" "by" "…an empty by is named"
  assert_contains "$(v1_messages)" "record" "…a missing record is named"
  jset "$SIDECAR" '.claims[0].rulings = "none"'
  cl validate --all
  assert_v1 "rulings" "rulings that is not an array"
  teardown
}

test_v1_enums() {
  echo "test: V1 — status, kind and enforced_by enums (config kinds extend kind)"
  claims_fixture
  jset "$SIDECAR" '.claims[0].status = "gated"'
  cl validate --all
  assert_v1 "status" "status gated (not valid without the configuration extension)"
  git checkout -q -- "$SIDECAR"
  jset "$SIDECAR" '.claims[0].enforced_by = "review"'
  cl validate --all
  assert_v1 "enforced_by" "enforced_by review"
  git checkout -q -- "$SIDECAR"
  jset "$SIDECAR" '.claims[0].kind = "parity"'
  cl validate --all
  assert_v1 "kind" "kind parity without config kinds"
  jset docs/spec-claims/config.json '.kinds = ["parity"]'
  cl validate --all
  assert_no_v1 "kind parity with config kinds [parity]"
  teardown
}

test_v1_test_null_only_while_unbuilt() {
  echo "test: V1 — a test claim's test may be null only while unbuilt"
  claims_fixture
  jset "$SIDECAR" '.claims[0].status = "built"'
  cl validate --all
  assert_v1 "test" "a built test claim with test null"
  jset "$SIDECAR" '.claims[0].status = "diverged"'
  cl validate --all
  assert_v1 "test" "a diverged test claim with test null"
  jset "$SIDECAR" '.claims[0].status = "built" | .claims[0].test = {"runner":"pytest","node":"tests/test_token.py::test_ttl"}'
  cl validate --all
  assert_no_v1 "a built test claim with test {runner, node}"
  jset "$SIDECAR" '.claims[0].test = {"runner":"pytest"}'
  cl validate --all
  assert_v1 "test.node" "a test without node"
  jset "$SIDECAR" '.claims[0].test = {"runner":"pytest","node":"t::x","file":""}'
  cl validate --all
  assert_v1 "test.file" "a test with an empty file"
  git checkout -q -- "$SIDECAR"
  # Retired: nothing runs, so no test is owed.
  jset "$SIDECAR" ".claims[0].status = \"retired\" | .claims[0].rulings = [$_CL_RETIRE]"
  cl validate --all
  assert_no_v1 "a retired test claim with test null"
  teardown
}

test_v1_lint_shape() {
  echo "test: V1 — lint is {pattern, paths[], expect: present|absent, selftest: {violates, clean}}"
  claims_fixture
  jset "$SIDECAR" '.claims[0].enforced_by = "lint" | .claims[0].lint = {"pattern":"TTL_SECONDS = 900","paths":["src/auth/token.py"],"expect":"present","selftest":{"violates":"TTL_SECONDS = 1800","clean":"TTL_SECONDS = 900"}}'
  cl validate --all
  assert_no_v1 "a well-formed lint"
  jset "$SIDECAR" '.claims[0].lint = {"pattern":"","paths":[],"expect":"maybe","selftest":{"violates":"x"}}'
  cl validate --all
  assert_v1 "lint.pattern" "a lint with an empty pattern"
  assert_contains "$(v1_messages)" "lint.paths" "…no paths"
  assert_contains "$(v1_messages)" "lint.expect" "…expect maybe"
  assert_contains "$(v1_messages)" "lint.selftest" "…selftest without clean"
  jset "$SIDECAR" '.claims[0].lint = null | .claims[0].status = "built" | .claims[0].test = {"runner":"pytest","node":"t::x"}'
  cl validate --all
  assert_v1 "lint" "a built lint claim with lint null"
  teardown
}

test_v1_malformed_sidecar() {
  echo "test: V1 — a sidecar that is not a well-formed envelope is a finding, not a crash"
  claims_fixture
  printf 'not json\n' > "$SIDECAR"
  cl validate --all
  assert_v1 "not one JSON object" "a sidecar that is not JSON"
  assert_eq "1" "$(json_count "$CL_OUT")" "…one verdict object"
  printf '%s\n' '{"schema":1,"doc":"docs/specs/SPEC-AUTH-001-token.md","claims":{}}' > "$SIDECAR"
  cl validate --all
  assert_v1 "claims must be an array" "claims that is an object"
  printf '%s\n' '{"schema":2,"doc":"docs/specs/SPEC-AUTH-001-token.md","claims":["x"]}' > "$SIDECAR"
  cl validate --all
  assert_v1 "schema" "schema 2"
  assert_contains "$(v1_messages)" "not a JSON object" "…a claim that is not an object"
  printf '%s\n' '{"schema":1,"claims":[]}' > "$SIDECAR"
  cl validate --all
  assert_v1 "doc" "a sidecar without doc"
  teardown
}

test_v1_archived_doc_sidecar() {
  echo "test: V1 — a sidecar with live claims whose doc was archived: one finding, no storm"
  claims_fixture
  mkdir -p docs/archive/specs
  git mv docs/specs/SPEC-AUTH-001-token.md docs/archive/specs/SPEC-AUTH-001-token.md
  # The sidecar still names the old (now missing) path.
  cl validate --all
  assert_eq "1" "$CL_RC" "doc missing after the move: exits 1"
  assert_eq "1" "$(v1_count)" "…exactly one V1 finding"
  assert_contains "$(v1_messages)" "RETIRE" "…advising RETIRE"
  assert_contains "$(v1_messages)" "move-entry" "…and move-entry"
  assert_contains "$(v1_messages)" "docs/specs/SPEC-AUTH-001-token.md" "…naming the doc"
  assert_eq "0" "$(v2_count)" "…no V2 finding"
  # The staged rename touches the doc, so --staged reports it too.
  cl validate --staged
  assert_eq "1" "$(v1_count)" "validate --staged: exactly one V1 finding"
  # The sidecar repointed at the archived path, its claim still live.
  jset "$SIDECAR" '.doc = "docs/archive/specs/SPEC-AUTH-001-token.md"'
  cl validate --all
  assert_eq "1" "$CL_RC" "doc archived (not governing): exits 1"
  assert_eq "1" "$(v1_count)" "…exactly one V1 finding"
  assert_contains "$(v1_messages)" "not governing" "…the doc is not governing"
  assert_contains "$(v1_messages)" "RETIRE" "…advising RETIRE"
  assert_contains "$(v1_messages)" "move-entry" "…and move-entry"
  assert_contains "$(v1_messages)" "docs/archive/specs/SPEC-AUTH-001-token.md" "…naming the doc"
  assert_eq "0" "$(v2_count)" "…no V2 finding"
  teardown
}

test_v1_archived_doc_all_retired_ok() {
  echo "test: V1 — a fully retired sidecar may name an archived doc"
  claims_fixture
  mkdir -p docs/archive/specs
  git mv docs/specs/SPEC-AUTH-001-token.md docs/archive/specs/SPEC-AUTH-001-token.md
  jset "$SIDECAR" ".doc = \"docs/archive/specs/SPEC-AUTH-001-token.md\"
    | .claims[0].status = \"retired\" | .claims[0].rulings = [$_CL_RETIRE]"
  cl validate --all
  assert_eq "0" "$CL_RC" "all claims retired, doc archived: exits 0"
  assert_no_v1 "all retired, archived doc"
  assert_eq "0" "$(v2_count)" "…no V2 finding"
  # The DOC-ID still comes from the basename: a wrong stem is still a finding.
  git mv "$SIDECAR" docs/spec-claims/SPEC-AUTH-009.json
  cl validate --all
  assert_v1 "stem" "a fully retired sidecar under the wrong stem"
  git mv docs/spec-claims/SPEC-AUTH-009.json "$SIDECAR"
  # Deleted outright, the doc may be missing too.
  git rm -qf docs/archive/specs/SPEC-AUTH-001-token.md
  cl validate --all
  assert_eq "0" "$CL_RC" "all claims retired, doc deleted: exits 0"
  assert_no_v1 "all retired, deleted doc"
  teardown
}

test_v1_staged_scope() {
  echo "test: V1 under --staged checks touched claims only, in the index"
  claims_fixture
  # A bad id committed on feature: --all sees it.
  jset "$SIDECAR" '.claims[0].id = "SPEC-AUTH-001-token-ttl"'
  git commit -qam "bad id"
  cl validate --all
  assert_v1 "id" "--all: the committed bad id"
  # Nothing staged: no claim is touched.
  cl validate --staged
  assert_eq "0" "$CL_RC" "--staged with nothing staged exits 0"
  assert_no_v1 "--staged, nothing staged"
  # An unrelated staged file touches nothing.
  echo "more" >> docs/architecture.md
  git add docs/architecture.md
  cl validate --staged
  assert_no_v1 "--staged, an unrelated file staged"
  # A staged subject file touches the claim.
  echo "# change" >> src/auth/token.py
  git add src/auth/token.py
  cl validate --staged
  assert_v1 "id" "--staged, the claim's subject staged"
  git reset -q
  # A staged doc touches its claims.
  echo "" >> docs/specs/SPEC-AUTH-001-token.md
  git add docs/specs/SPEC-AUTH-001-token.md
  cl validate --staged
  assert_v1 "id" "--staged, the claim's doc staged"
  git reset -q
  # A staged test file (the node's path) touches the claim.
  mkdir -p tests
  echo "def test_ttl(): pass" > tests/test_token.py
  jset "$SIDECAR" '.claims[0].test = {"runner":"pytest","node":"tests/test_token.py::test_ttl"}'
  git add "$SIDECAR"
  git commit -qm "bind a test"
  git add tests/test_token.py
  cl validate --staged
  assert_v1 "id" "--staged, the claim's test file staged"
  git reset -q
  # --staged reads the index: a fix in the work tree alone does not count,
  # a staged fix does.
  jset "$SIDECAR" '.claims[0].id = "SPEC-AUTH-001#token-ttl"'
  git add src/auth/token.py
  cl validate --staged
  assert_v1 "id" "--staged, the fix unstaged (the index still holds the bad id)"
  git add "$SIDECAR"
  cl validate --staged
  assert_no_v1 "--staged, the fix staged"
  teardown
}

test_v1_staged_config_touches_every_claim() {
  echo "test: V1 under --staged — a staged config.json touches every claim"
  claims_fixture
  jset docs/spec-claims/config.json '.kinds = ["parity"]'
  jset "$SIDECAR" '.claims[0].kind = "parity"'
  git commit -qam "a host kind"
  cl validate --staged
  assert_no_v1 "--staged, nothing staged"
  # Staging a config without kinds makes the committed claim's kind invalid.
  jset docs/spec-claims/config.json 'del(.kinds)'
  git add docs/spec-claims/config.json
  cl validate --staged
  assert_v1 "kind" "--staged, a config without kinds staged"
  assert_json_field "$CL_OUT" '[.findings[] | select(.check == "V1")][0].claim' "SPEC-AUTH-001#token-ttl" "…the finding names the claim"
  teardown
}

test_v1_staged_reads_index_sidecars() {
  echo "test: V1 under --staged lists sidecars from the index, never gates/"
  claims_fixture
  # An untracked sidecar is not in the index.
  jq '.claims[0].id = "bad"' "$SIDECAR" > docs/spec-claims/SPEC-AUTH-003.json
  echo "# change" >> src/auth/token.py
  git add src/auth/token.py
  cl validate --staged
  assert_no_v1 "--staged: an untracked sidecar is not read"
  cl validate --all
  assert_v1 "stem" "--all: the work tree's untracked sidecar is read"
  rm docs/spec-claims/SPEC-AUTH-003.json
  # A gate record is never a sidecar.
  mkdir -p docs/spec-claims/gates/2026-01-01-ttl
  printf '%s\n' '{"result":"pass"}' > docs/spec-claims/gates/2026-01-01-ttl/chunk-1.json
  git add docs/spec-claims/gates
  cl validate --staged
  assert_no_v1 "--staged: a staged gate record is not a sidecar"
  cl validate --all
  assert_no_v1 "--all: a gate record is not a sidecar"
  teardown
}

# --- V2 anchor and quote normalisation -----------------------------------------

DOC=docs/specs/SPEC-AUTH-001-token.md
# The fixture doc's claimed line.
TTL_LINE="- Access tokens expire after 15 minutes."

# doc_edit <file> <exact line> <replacement> [after]: rewrite <file> with each
# line equal to <exact line> replaced by <replacement> (which may hold
# newlines), or, with a fourth argument, followed by it. ENVIRON, not -v, so
# awk applies no escape processing to either text.
doc_edit() {
  local tmp
  tmp=$(harness_mktemp doc-edit)
  OLD="$2" NEW="$3" MODE="${4:-replace}" awk '
    $0 == ENVIRON["OLD"] {
      if (ENVIRON["MODE"] == "after") print
      print ENVIRON["NEW"]
      next
    }
    { print }' "$1" > "$tmp"
  cat "$tmp" > "$1"
  rm -f "$tmp"
}

# The last `cl`'s V2 finding messages, one per line.
v2_messages() {
  jq -r '.findings[]? | select(.check == "V2") | .message' <<<"$CL_OUT" 2>/dev/null || true
}

# assert_v2 <substring> <what>: the last `cl` exited 1 with a V2 finding whose
# message contains <substring>.
assert_v2() {
  assert_eq "1" "$CL_RC" "$2: exits 1"
  assert_contains "$(v2_messages)" "$1" "$2: a V2 finding names '$1'"
}

# assert_v2_ok <what>: the last `cl` exited 0 with no V2 finding.
assert_v2_ok() {
  assert_eq "0" "$CL_RC" "$1: exits 0"
  assert_eq "0" "$(v2_count)" "$1: no V2 finding"
}

# The AMENDED block a DOC-STALE amendment adds under Requirements.
AMENDED_LINE='> ⚠️ **AMENDED 2026-10-10 — ttl.** Access tokens expire after 15 minutes.'
add_amended_requote() {
  doc_edit "$DOC" "- Refresh tokens are single-use." $'\n'"$AMENDED_LINE" after
}

# _JQ_CLAIMS_NORM, read out of doc-tools.sh (a single-quoted bash string, so it
# holds no single quote), for the tests that check its output directly. awk,
# not ${src#*…}: bash's prefix strip is quadratic on a file this size.
claims_norm_defs() {
  awk '!f && sub(/^_JQ_CLAIMS_NORM=\047/, "") { f = 1 }
       f { if (sub(/\047$/, "")) { print; exit } print }' "$SCRIPT_DIR/doc-tools.sh"
}

test_v2_unique_live_quote_passes() {
  echo "test: V2 — a quote with exactly one live occurrence"
  claims_fixture
  cl validate --all
  assert_v2_ok "the fixture's quote"
  teardown
}

test_v2_quote_missing() {
  echo "test: V2 — a quote that is not in the doc"
  claims_fixture
  doc_edit "$DOC" "$TTL_LINE" "- Access tokens expire after 30 minutes."
  cl validate --all
  assert_v2 "not found" "the doc says 30, the quote 15"
  assert_json_field "$CL_OUT" '[.findings[] | select(.check == "V2")][0].claim' "SPEC-AUTH-001#token-ttl" "…the finding names the claim"
  assert_json_field "$CL_OUT" '[.findings[] | select(.check == "V2")][0].doc' "$DOC" "…and its doc"
  teardown
}

test_v2_staged_reads_index() {
  echo "test: V2 under --staged reads the doc from the index"
  claims_fixture
  doc_edit "$DOC" "$TTL_LINE" "- Access tokens expire after 30 minutes."
  echo "# change" >> src/auth/token.py
  git add src/auth/token.py
  cl validate --staged
  assert_v2_ok "--staged, the doc edit unstaged"
  git add "$DOC"
  cl validate --staged
  assert_v2 "not found" "--staged, the doc edit staged"
  teardown
}

test_v2_quote_twice_needs_occurrence() {
  echo "test: V2 — two live occurrences need quote_occurrence"
  claims_fixture
  doc_edit "$DOC" "How long issued tokens stay valid." $'\n'"Access tokens expire after 15 minutes." after
  cl validate --all
  assert_v2 "2 live occurrences" "the sentence copied under Summary"
  jset "$SIDECAR" '.claims[0].quote_occurrence = 1'
  cl validate --all
  assert_v2_ok "quote_occurrence 1"
  jset "$SIDECAR" '.claims[0].quote_occurrence = 2'
  cl validate --all
  assert_v2_ok "quote_occurrence 2"
  jset "$SIDECAR" '.claims[0].quote_occurrence = 3'
  cl validate --all
  assert_v2 "quote_occurrence 3" "quote_occurrence 3 of 2"
  teardown
}

test_v2_reflow_passes() {
  echo "test: V2 — a reflowed sentence still anchors"
  claims_fixture
  doc_edit "$DOC" "$TTL_LINE" $'- Access tokens   expire\n      after 15\tminutes.'
  cl validate --all
  assert_v2_ok "the sentence wrapped over two lines"
  teardown
}

test_v2_emphasis_stripped() {
  echo "test: V2 — emphasis is stripped before matching"
  claims_fixture
  doc_edit "$DOC" "$TTL_LINE" '- **Access** tokens expire after _15_ `minutes`.'
  cl validate --all
  assert_v2_ok "emphasis inside the sentence"
  teardown
}

test_v2_struck_text_not_live() {
  echo "test: V2 — struck text is not live"
  claims_fixture
  doc_edit "$DOC" "$TTL_LINE" "- ~~Access tokens expire after 15 minutes.~~"$'\n'"$TTL_LINE"
  cl validate --all
  assert_v2_ok "the struck copy is not counted"
  # Struck alone, the quote has no live occurrence.
  doc_edit "$DOC" "$TTL_LINE" "- Refresh tokens rotate."
  cl validate --all
  assert_v2 "not found" "only the struck copy remains"
  teardown
}

test_v2_multiline_struck_lazy() {
  echo "test: V2 — the strike match is lazy across lines"
  claims_fixture
  doc_edit "$DOC" "$TTL_LINE" "~~Old rule one.~~"$'\n'"$TTL_LINE"$'\n'"~~Old rule"$'\n'"two.~~"
  cl validate --all
  assert_v2_ok "two struck spans around the quote"
  teardown
}

test_v2_status_block_not_live() {
  echo "test: V2 — the generated status block is not live"
  claims_fixture
  doc_edit "$DOC" "## Requirements" $'<!-- spec-claims:status:begin -->\n## Claim status\n\nAccess tokens expire after 15 minutes.\n\n<!-- spec-claims:status:end -->\n\n## Requirements'
  cl validate --all
  assert_v2_ok "the quote copied inside the status markers"
  teardown
}

test_v2_retired_quote_still_live() {
  echo "test: V2 — a retired claim's quote must not be live"
  claims_fixture
  jset "$SIDECAR" ".claims[0].status = \"retired\" | .claims[0].rulings = [$_CL_RETIRE]"
  cl validate --all
  assert_v2 "retired" "a retired claim whose sentence is not struck"
  doc_edit "$DOC" "$TTL_LINE" "- ~~Access tokens expire after 15 minutes.~~"
  cl validate --all
  assert_v2_ok "the retired claim's sentence struck"
  teardown
}

test_v2_amended_requote_fires() {
  echo "test: V2 — an AMENDED block re-quoting a claimed sentence"
  claims_fixture
  add_amended_requote
  cl validate --all
  assert_v2 "AMENDED block re-quotes" "the AMENDED re-quote without quote_occurrence"
  assert_contains "$(v2_messages)" "set quote_occurrence to the live occurrence" "…telling the author what to set"
  teardown
}

test_v2_amended_requote_with_occurrence_ok() {
  echo "test: V2 — an AMENDED re-quote anchored by quote_occurrence"
  claims_fixture
  add_amended_requote
  jset "$SIDECAR" '.claims[0].quote_occurrence = 2'
  cl validate --all
  assert_v2_ok "quote_occurrence 2 (the amended occurrence)"
  # The re-quote wrapping inside the blockquote: its ">" markers are stripped.
  doc_edit "$DOC" "$AMENDED_LINE" $'> ⚠️ **AMENDED 2026-10-10 — ttl.** Access tokens\n> expire after 15 minutes.'
  cl validate --all
  assert_v2_ok "quote_occurrence 2, the amended re-quote wrapped across '>' lines"
  teardown
}

test_v2_amended_requote_ruling_alone_fails() {
  echo "test: V2 — a ruling alone does not anchor an AMENDED re-quote"
  claims_fixture
  add_amended_requote
  jset "$SIDECAR" '.claims[0].rulings = [{"date":"2026-10-10","direction":"DOC-STALE","by":"doc-owner","record":"docs/issues/token-ttl.md","reason":"The TTL was renegotiated."}]'
  cl validate --all
  assert_v2 "a ruling alone does not anchor it" "a DOC-STALE ruling without quote_occurrence"
  assert_no_v1 "the ruling itself is well formed"
  teardown
}

test_v2_tilde_fence_not_strike() {
  echo "test: V2 — ~~~ fences are not strike spans"
  claims_fixture
  doc_edit "$DOC" "## Requirements" $'## Requirements\n\n~~~sh\ncd ~/app\n~~~'
  doc_edit "$DOC" "- Refresh tokens are single-use." $'\n~~~text\nexample\n~~~' after
  cl validate --all
  assert_v2_ok "a ~~~ fence above the sentence and one below"
  # The upper fence closed by a longer (legal) ~~~~: unmasked, its second
  # "~~" would open a strike that the fence below closes, swallowing the
  # sentence.
  git checkout -q -- "$DOC"
  doc_edit "$DOC" "## Requirements" $'## Requirements\n\n~~~sh\ncd ~/app\n~~~~'
  doc_edit "$DOC" "- Refresh tokens are single-use." $'\n~~~text\nexample\n~~~' after
  cl validate --all
  assert_v2_ok "a ~~~ fence closed by ~~~~ above the sentence, a ~~~ fence below"
  teardown
}

test_v2_fenced_tilde_restored() {
  echo "test: V2 — a ~~ inside a fence is neither a strike nor lost"
  claims_fixture
  # Unmasked, the fenced "~~" would pair with the fence opener, and the
  # closer with the later strike, swallowing the claimed prose line.
  doc_edit "$DOC" "## Requirements" $'## Requirements\n\n```\na ~~ b\n```'
  doc_edit "$DOC" "- Refresh tokens are single-use." $'~~Refresh tokens are reusable.~~' after
  cl validate --all
  assert_v2_ok "a fenced 'a ~~ b' before the claimed prose line"
  # The fenced text keeps its tildes: a claim may quote it.
  jset "$SIDECAR" '.claims[0].quote = "a ~~ b"'
  cl validate --all
  assert_v2_ok "a claim quoting the fenced 'a ~~ b'"
  teardown
}

test_no_raw_sentinel_in_doc_tools() {
  echo "test: the U+FFFF sentinel appears in doc-tools.sh only as the \\uffff escape"
  local raw esc
  raw=$(LC_ALL=C grep -c $'\xef\xbf\xbf' "$SCRIPT_DIR/doc-tools.sh" || true)
  esc=$(grep -cF '\uffff' "$SCRIPT_DIR/doc-tools.sh" || true)
  assert_eq "0" "$raw" "no raw U+FFFF bytes in doc-tools.sh"
  assert_true "the \\uffff escape masks and restores (at least 2 uses; got ${esc:-0})" [ "${esc:-0}" -ge 2 ]
}

test_v2_crlf_doc() {
  echo "test: V2 — a CRLF doc anchors as its LF twin does"
  claims_fixture
  local tmp
  tmp=$(harness_mktemp crlf)
  awk '{ printf "%s\r\n", $0 }' "$DOC" > "$tmp"
  cat "$tmp" > "$DOC"
  assert_true "the doc is CRLF" grep -q $'\r$' "$DOC"
  cl validate --all
  assert_v2_ok "the CRLF doc"
  # A wrap in a CRLF doc: the \r is part of the line break.
  doc_edit "$DOC" "$TTL_LINE"$'\r' $'- Access tokens expire\r\n  after 15 minutes.\r'
  cl validate --all
  assert_v2_ok "the sentence wrapped in the CRLF doc"
  # The CRLF doc's normalised text and line spans equal its LF twin's.
  local defs crlf lf
  defs=$(claims_norm_defs)
  tr -d '\r' < "$DOC" > "$tmp"
  crlf=$(jq -Rsc "$defs claims_doc" "$DOC" 2>/dev/null || echo "jq failed")
  lf=$(jq -Rsc "$defs claims_doc" "$tmp" 2>/dev/null || echo "jq failed")
  assert_contains "$lf" '"lines":[{"n":1,' "claims_doc ran on the LF twin"
  assert_eq "$lf" "$crlf" "claims_doc of the CRLF doc equals the LF doc's"
  rm -f "$tmp"
  teardown
}

test_v2_unicode_quote() {
  echo "test: V2 — non-ASCII text: occurrences are codepoint offsets"
  claims_fixture
  doc_edit "$DOC" "How long issued tokens stay valid." "How long issued tokens stay valid — durée de vie, § café."
  doc_edit "$DOC" "- Refresh tokens are single-use." "- Tokens — même après 15 minutes."
  jset "$SIDECAR" '.claims[0].quote = "Tokens — même après 15 minutes"'
  cl validate --all
  assert_v2_ok "a quote with é and — after lines holding them"
  # claims_occ's offset against an independent codepoint search of the same
  # normalised text (explode and compare windows; no split, no index).
  local defs q='Tokens — même après 15 minutes' got want line bytes
  defs=$(claims_norm_defs)
  got=$(jq -Rsc --arg q "$q" "$defs claims_doc | claims_occ(\$q)" "$DOC" 2>/dev/null || echo "jq failed")
  want=$(jq -Rsc --arg q "$q" "$defs claims_doc | .text | explode as \$t | (\$q | explode) as \$e
    | [range(0; (\$t | length) - (\$e | length) + 1) | select(\$t[.:. + (\$e | length)] == \$e)]" "$DOC" 2>/dev/null || echo "want failed")
  assert_eq "$want" "$got" "claims_occ equals the codepoint offsets"
  # …which differ from the byte offset (so the doc does exercise the difference).
  bytes=$(jq -Rsr --arg q "$q" "$defs claims_doc | .text | split(\$q)[0] | utf8bytelength" "$DOC" 2>/dev/null || echo "bytes failed")
  assert_true "one occurrence, at a codepoint offset (got $want)" grep -qE '^\[[0-9]+\]$' <<<"$want"
  assert_true "the codepoint offset $got is not the byte offset $bytes" [ "$want" != "[$bytes]" ]
  # claims_lines_hit names the line the quote is on (grep -n, independent).
  line=$(grep -n "^- Tokens — même" "$DOC" | cut -d: -f1)
  got=$(jq -Rsc --arg q "$q" "$defs claims_doc | claims_lines_hit(\$q; 1)" "$DOC" 2>/dev/null || echo "jq failed")
  assert_eq "[$line]" "$got" "claims_lines_hit names line $line"
  teardown
}

test_v2_lines_hit_wrapped() {
  echo "test: claims_lines_hit — a wrapped quote hits both its lines"
  claims_fixture
  doc_edit "$DOC" "$TTL_LINE" $'- Access tokens expire\n  after 15 minutes.'
  local defs line got
  defs=$(claims_norm_defs)
  line=$(grep -n "^- Access tokens expire$" "$DOC" | cut -d: -f1)
  got=$(jq -Rsc --arg q "Access tokens expire after 15 minutes" "$defs claims_doc | claims_lines_hit(\$q; 1)" "$DOC" 2>/dev/null || echo "jq failed")
  assert_eq "[$line,$((line + 1))]" "$got" "the occurrence hits lines $line and $((line + 1))"
  got=$(jq -Rsc --arg q "Access tokens expire after 15 minutes" "$defs claims_doc | claims_lines_hit(\$q; 2)" "$DOC" 2>/dev/null || echo "jq failed")
  assert_eq "[]" "$got" "no second occurrence: no lines"
  # claims_live keeps the line count: the doc's own, struck spans and status block included.
  doc_edit "$DOC" "## Summary" $'## Summary\n\n~~gone\nacross lines~~\n<!-- spec-claims:status:begin -->\nx\n<!-- spec-claims:status:end -->\n```\ny\n```'
  got=$(jq -Rsr "$defs claims_live | split(\"\\n\") | length" "$DOC" 2>/dev/null || echo "jq failed")
  assert_eq "$(jq -Rsr 'split("\n") | length' "$DOC")" "$got" "claims_live keeps the line count"
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
  test_emitted_code_survives_trap
  test_stderr_closed_still_one_verdict
  test_missing_jq_exit_2
  test_rulings_markdown_exit_0
  test_enabled_verdict_shape
  test_base_unresolvable_indeterminate
  test_config_malformed_exit_2
  test_config_optional_defaults_apply
  test_v1_config_unknown_key
  test_stub_verbs_enabled

  # --- Task 2: V1 schema, the claim loader and --staged scope ---
  test_v1_valid_fixture_passes
  test_v1_malformed_record
  test_v1_bad_id
  test_v1_duplicate_id
  test_v1_doc_not_governing
  test_v1_stem_mismatch
  test_v1_host_glob_doc_id_is_stem
  test_v1_adr_doc_id_prefix
  test_v1_ruling_missing_reason
  test_v1_ruling_fields
  test_v1_enums
  test_v1_test_null_only_while_unbuilt
  test_v1_lint_shape
  test_v1_malformed_sidecar
  test_v1_archived_doc_sidecar
  test_v1_archived_doc_all_retired_ok
  test_v1_staged_scope
  test_v1_staged_config_touches_every_claim
  test_v1_staged_reads_index_sidecars

  # --- Task 3: quote normalisation and V2 anchor ---
  test_v2_unique_live_quote_passes
  test_v2_quote_missing
  test_v2_staged_reads_index
  test_v2_quote_twice_needs_occurrence
  test_v2_reflow_passes
  test_v2_emphasis_stripped
  test_v2_struck_text_not_live
  test_v2_multiline_struck_lazy
  test_v2_status_block_not_live
  test_v2_retired_quote_still_live
  test_v2_amended_requote_fires
  test_v2_amended_requote_with_occurrence_ok
  test_v2_amended_requote_ruling_alone_fails
  test_v2_tilde_fence_not_strike
  test_v2_fenced_tilde_restored
  test_no_raw_sentinel_in_doc_tools
  test_v2_crlf_doc
  test_v2_unicode_quote
  test_v2_lines_hit_wrapped

  print_summary
}

run_tests
