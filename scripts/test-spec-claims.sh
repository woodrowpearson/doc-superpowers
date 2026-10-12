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
# the ratchets compare against is main's tip. The doc carries its rendered
# status block (§B: a doc with a sidecar shows its status), byte for byte
# what `claims render` writes (test_v11_fixture_is_rendered), so V11 holds on
# the fixture; a test that changes a claim's status re-renders (rerender).

claims_fixture() {
  setup
  mkdir -p docs/specs docs/issues docs/spec-claims src/auth
  cat > docs/specs/SPEC-AUTH-001-token.md <<'EOF'
# SPEC-AUTH-001: Token lifetimes

**Status**: Draft
**Created**: 2026-10-10

## Summary

How long issued tokens stay valid.

<!-- spec-claims:status:begin -->
## Claim status

| Claim | Status | Tracker |
|---|---|---|
| `SPEC-AUTH-001#token-ttl` | unbuilt | docs/issues/token-ttl.md |

<!-- spec-claims:status:end -->
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
# A DOC-STALE ruling recorded in the fixture's issue doc: what a re-anchor
# that changes a token, or another ratcheted edit, carries (V6).
_CL_DOC_STALE='{"date":"2026-10-11","direction":"DOC-STALE","by":"doc-owner","record":"docs/issues/token-ttl.md","reason":"The TTL was renegotiated."}'

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
  rerender
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
  # The quote copied into the fixture's rendered block: a hand edit, which
  # is V11's finding, never V2's.
  doc_edit "$DOC" "## Claim status" $'\nAccess tokens expire after 15 minutes.' after
  cl validate --all
  assert_eq "0" "$(v2_count)" "the quote copied inside the status markers: no V2 finding"
  assert_json_field "$CL_OUT" '[.findings[].check] | unique | tojson' '["V11"]' "…the hand edit is V11's finding alone"
  teardown
}

test_v2_retired_quote_still_live() {
  echo "test: V2 — a retired claim's quote must not be live"
  claims_fixture
  jset "$SIDECAR" ".claims[0].status = \"retired\" | .claims[0].rulings = [$_CL_RETIRE]"
  rerender
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
  # The fenced text keeps its tildes: a claim may quote it (a re-anchor to
  # other tokens, so with a ruling: V6).
  jset "$SIDECAR" ".claims[0].quote = \"a ~~ b\" | .claims[0].rulings = [$_CL_DOC_STALE]"
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
  # A re-anchor to other tokens, so with a ruling (V6).
  jset "$SIDECAR" ".claims[0].quote = \"Tokens — même après 15 minutes\" | .claims[0].rulings = [$_CL_DOC_STALE]"
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

# norm_jq <filter> <text>: <filter> (after _JQ_CLAIMS_NORM) on <text> as a raw
# doc, compact output; "jq failed" when jq fails.
norm_jq() {
  local tmp out
  tmp=$(harness_mktemp norm-jq)
  printf '%s' "$2" > "$tmp"
  out=$(jq -Rsc "$(claims_norm_defs) $1" "$tmp" 2>/dev/null) || out="jq failed"
  rm -f "$tmp"
  printf '%s' "$out"
}

test_fence_pairing_commonmark() {
  echo "test: fence masking pairs fences as CommonMark does (character, run length, no info string)"
  # A ``` line inside a ```` fence is content: its fenced ~~ stays fenced, and
  # the prose strike after the fence is blanked alone.
  local doc
  doc=$'````md\n```\ncode ~~x\n```\n````\nA ~~struck~~ claim sentence.\n'
  assert_eq '"\n```\ncode ~~x\n```\n\nA  claim sentence.\n"' "$(norm_jq claims_live "$doc")" \
    "\`\`\`\` fence holding \`\`\`: the live text keeps 'A ' and blanks only the strike"
  assert_eq '"code ~~x A claim sentence."' "$(norm_jq claims_norm "$doc")" "…normalised"
  # A ~~~ line inside a ``` fence is content, and a ```` run followed by an
  # info string does not close it; a longer bare run does.
  doc=$'```\n~~~\nx ~~ y\n~~~\n```` not\n````\nLater ~~gone~~ B line.\n'
  assert_eq '"\n~~~\nx ~~ y\n~~~\n```` not\n\nLater  B line.\n"' "$(norm_jq claims_live "$doc")" \
    "\`\`\` fence holding ~~~ lines, closed by a longer bare run"
  # A shorter run of the opener's character is content too.
  doc=$'~~~~\n~~~\na ~~ b\n~~~\n~~~~\nC ~~gone~~ line.\n'
  assert_eq '"\n~~~\na ~~ b\n~~~\n\nC  line.\n"' "$(norm_jq claims_live "$doc")" \
    "~~~~ fence holding ~~~ lines"
  # A ``` run whose info string holds a ` is not an opener.
  doc=$'```x`\nD ~~gone~~ line.\n'
  assert_eq '"```x`\nD  line.\n"' "$(norm_jq claims_live "$doc")" "a \`\`\` run with a \` in its info string opens no fence"
  # End to end: V2 finds the sentence after the nested fence.
  claims_fixture
  doc_edit "$DOC" "- Refresh tokens are single-use." $'\n````md\n```\ncode ~~x\n```\n````\nA ~~struck~~ claim sentence.' after
  jset "$SIDECAR" '.claims += [.claims[0] | .id = "SPEC-AUTH-001#claim-sentence" | .quote = "A claim sentence"]'
  rerender
  cl validate --all
  assert_v2_ok "a claim quoting the sentence after a nested fence"
  teardown
}

test_amended_flag_carry() {
  echo "test: claims_doc's amended flag — carried through the blockquote, from the source lines"
  local am='claims_doc | [.lines[] | [.n, .amended]]'
  # A strike across a line break inside the block does not end it.
  assert_eq "[[1,true],[2,true],[3,true]]" \
    "$(norm_jq "$am" $'> ⚠️ **AMENDED 2026-10-10 — ttl.** ~~Access tokens expire after\n> 15 minutes.~~ Access tokens expire after\n> 30 minutes.\n')" \
    "a strike spanning lines of the AMENDED block: every line amended"
  # A bare ">" line keeps the block going.
  assert_eq "[[1,true],[3,true]]" \
    "$(norm_jq "$am" $'> **AMENDED 2026-10-10 — ttl.** First.\n>\n> Second.\n')" \
    "carried across a bare '>' line"
  # A blank line ends it.
  assert_eq "[[1,true],[3,false]]" \
    "$(norm_jq "$am" $'> **AMENDED 2026-10-10 — ttl.** First.\n\n> Second.\n')" \
    "stopped by a blank line"
  # A later plain blockquote is not amended.
  assert_eq "[[1,true],[3,false],[5,false]]" \
    "$(norm_jq "$am" $'> **AMENDED 2026-10-10 — ttl.** First.\n\nPlain.\n\n> Quote.\n')" \
    "a later plain blockquote is not amended"
  # Inside a code fence a "> **AMENDED" line is not a blockquote.
  assert_eq "[[2,false],[5,false]]" \
    "$(norm_jq "$am" $'```\n> **AMENDED 2026-10-10 — ttl.** In code.\n```\n\n> Quote.\n')" \
    "a fenced '> **AMENDED' line is not a blockquote"
  # CRLF: the same as LF.
  assert_eq "[[1,true],[2,true],[3,true]]" \
    "$(norm_jq "$am" $'> **AMENDED 2026-10-10 — ttl.** ~~a\r\n> b~~ c\r\n> d\r\n')" \
    "a CRLF AMENDED block"
}

# --- V5 status requirements ----------------------------------------------------

TRACKER=docs/issues/token-ttl.md
# The fixture tracker's status line.
TRACKER_OPEN="**Status**: Open"
# A CODE-DIVERGES ruling recorded in the fixture's issue doc.
_CL_DIVERGES='{"date":"2026-10-11","direction":"CODE-DIVERGES","by":"doc-owner","record":"docs/issues/token-ttl.md"}'

# The last `cl`'s V5 finding messages, one per line, and their count.
v5_messages() {
  jq -r '.findings[]? | select(.check == "V5") | .message' <<<"$CL_OUT" 2>/dev/null || true
}
v5_count() {
  jq '[.findings[]?, .advisories[]? | select(.check == "V5")] | length' <<<"$CL_OUT" 2>/dev/null || echo invalid
}

# assert_v5 <substring> <what>: the last `cl` exited 1 with a V5 finding whose
# message contains <substring>.
assert_v5() {
  assert_eq "1" "$CL_RC" "$2: exits 1"
  assert_contains "$(v5_messages)" "$1" "$2: a V5 finding names '$1'"
}

# assert_v5_ok <what>: the last `cl` exited 0 with no V5 finding.
assert_v5_ok() {
  assert_eq "0" "$CL_RC" "$1: exits 0"
  assert_eq "0" "$(v5_count)" "$1: no V5 finding"
}

# The fixture claim made diverged: a bound test (V1 wants one once the claim
# runs) and the CODE-DIVERGES ruling, its tracker left as the fixture's.
diverge_claim() {
  jset "$SIDECAR" ".claims[0].status = \"diverged\"
    | .claims[0].test = {\"runner\":\"pytest\",\"node\":\"tests/test_token.py::test_ttl\"}
    | .claims[0].rulings = [$_CL_DIVERGES]"
  rerender
}

test_v5_fixture_passes() {
  echo "test: V5 — the fixture's unbuilt claim has an open tracker"
  claims_fixture
  cl validate --all
  assert_v5_ok "unbuilt, tracker docs/issues/token-ttl.md (Status: Open)"
  teardown
}

test_v5_diverged_without_tracker() {
  echo "test: V5 — a diverged claim without a tracker"
  claims_fixture
  diverge_claim
  cl validate --all
  assert_v5_ok "diverged with its ruling and an open tracker"
  jset "$SIDECAR" '.claims[0].tracker = null'
  cl validate --all
  assert_v5 "no tracker" "diverged, tracker null"
  assert_eq "1" "$(v5_count)" "…exactly one V5 finding"
  assert_json_field "$CL_OUT" '[.findings[] | select(.check == "V5")][0].claim' "SPEC-AUTH-001#token-ttl" "…the finding names the claim"
  assert_json_field "$CL_OUT" '[.findings[] | select(.check == "V5")][0].doc' "$DOC" "…and its doc"
  # unbuilt needs one too.
  jset "$SIDECAR" '.claims[0].status = "unbuilt" | .claims[0].rulings = []'
  cl validate --all
  assert_v5 "no tracker" "unbuilt, tracker null"
  teardown
}

test_v5_tracker_missing_path() {
  echo "test: V5 — a tracker path that is not in the proposed tree"
  claims_fixture
  jset "$SIDECAR" '.claims[0].tracker = "docs/issues/nope.md"'
  cl validate --all
  assert_v5 "docs/issues/nope.md" "tracker docs/issues/nope.md (no such file)"
  assert_contains "$(v5_messages)" "not a path in the proposed tree" "…saying why"
  # A directory is not a tracker.
  jset "$SIDECAR" '.claims[0].tracker = "docs/issues"'
  cl validate --all
  assert_v5 "not a path in the proposed tree" "tracker docs/issues (a directory)"
  # Nor is a path outside the repository.
  jset "$SIDECAR" '.claims[0].tracker = "../outside.md"'
  printf '**Status**: Open\n' > ../outside.md
  cl validate --all
  assert_v5 "not a path in the proposed tree" "tracker ../outside.md"
  rm -f ../outside.md
  # --staged reads the index: a tracker in the work tree alone does not count.
  jset "$SIDECAR" '.claims[0].tracker = "docs/issues/nope.md"'
  printf '# Nope\n\n**Status**: Open\n' > docs/issues/nope.md
  rerender
  cl validate --all
  assert_v5_ok "--all, the tracker in the work tree"
  git add "$SIDECAR" "$DOC"
  cl validate --staged
  assert_v5 "docs/issues/nope.md" "--staged, the tracker untracked"
  git add docs/issues/nope.md
  cl validate --staged
  assert_v5_ok "--staged, the tracker staged"
  teardown
}

test_v5_tracker_closed_is_finding() {
  echo "test: V5 — a closed tracker"
  claims_fixture
  doc_edit "$TRACKER" "$TRACKER_OPEN" "**Status**: Resolved"
  cl validate --all
  assert_v5 "tracker is closed" "the issue doc's Status: Resolved"
  assert_contains "$(v5_messages)" "Resolved" "…naming the status"
  # --staged reads the tracker from the index.
  echo "# change" >> src/auth/token.py
  git add src/auth/token.py
  cl validate --staged
  assert_v5_ok "--staged, the close unstaged"
  git add "$TRACKER"
  cl validate --staged
  assert_v5 "tracker is closed" "--staged, the close staged"
  # Every closed word, any case.
  local w
  for w in closed DONE Fixed completed WontFix; do
    printf '# Token TTL\n\n**Status**: %s\n' "$w" > "$TRACKER"
    cl validate --all
    assert_v5 "tracker is closed" "Status: $w"
  done
  teardown
}

test_v5_tracker_status_leading_word() {
  echo "test: V5 — only the status value's leading word decides"
  claims_fixture
  doc_edit "$TRACKER" "$TRACKER_OPEN" "**Status**: Approved — not done"
  cl validate --all
  assert_v5_ok "Status: Approved — not done"
  doc_edit "$TRACKER" "**Status**: Approved — not done" '**Status:** `Done` (2026-10-01)'
  cl validate --all
  assert_v5 "tracker is closed" '**Status:** `Done` (2026-10-01)'
  printf -- '---\nstatus: reopened, was closed\n---\n# Token TTL\n' > "$TRACKER"
  cl validate --all
  assert_v5_ok "front matter status: reopened, was closed"
  printf -- '---\ntitle: Token TTL\nstatus: Resolved\n---\n# Token TTL\n' > "$TRACKER"
  cl validate --all
  assert_v5 "tracker is closed" "front matter status: Resolved"
  # CRLF reads as LF.
  printf -- '---\r\nstatus: done\r\n---\r\n# Token TTL\r\n' > "$TRACKER"
  cl validate --all
  assert_v5 "tracker is closed" "CRLF front matter status: done"
  # The first status line counts.
  printf '# Token TTL\n\n**Status**: Open\n\nLater: **Status**: Done\n**Status**: Done\n' > "$TRACKER"
  cl validate --all
  assert_v5_ok "Status: Open, then a later Status: Done"
  # A status line inside a code fence is not the doc's status.
  printf '# Token TTL\n\n```\n**Status**: Done\n```\n\n**Status**: Open\n' > "$TRACKER"
  cl validate --all
  assert_v5_ok "a fenced Status: Done before Status: Open"
  # status: outside front matter is not front matter.
  printf '# Token TTL\n\nstatus: closed\n' > "$TRACKER"
  cl validate --all
  assert_v5_ok "a body line status: closed"
  # No status line at all: open.
  printf '# Token TTL\n\nBuild the expiry.\n' > "$TRACKER"
  cl validate --all
  assert_v5_ok "no status line"
  teardown
}

test_v5_tracker_pattern_accepted() {
  echo "test: V5 — a tracker matching tracker_patterns is accepted as open"
  claims_fixture
  diverge_claim
  jset "$SIDECAR" '.claims[0].tracker = "#42"'
  rerender
  cl validate --all
  assert_v5 "#42" "tracker #42 without tracker_patterns"
  jset docs/spec-claims/config.json '.tracker_patterns = ["^https://issues\\.example\\.com/", "^#[0-9]+$"]'
  cl validate --all
  assert_v5_ok "tracker #42 matching ^#[0-9]+$"
  jset "$SIDECAR" '.claims[0].tracker = "#42a"'
  rerender
  cl validate --all
  assert_v5 "#42a" "tracker #42a matches no pattern"
  # An invalid pattern matches nothing (and is not a crash).
  jset docs/spec-claims/config.json '.tracker_patterns = ["(", "^#[0-9]+a$"]'
  cl validate --all
  assert_v5_ok "an invalid pattern beside one that matches"
  teardown
}

test_v5_diverged_without_code_diverges_ruling() {
  echo "test: V5 — a diverged claim needs a CODE-DIVERGES ruling"
  claims_fixture
  diverge_claim
  jset "$SIDECAR" '.claims[0].rulings = []'
  cl validate --all
  assert_v5 "CODE-DIVERGES" "diverged with a tracker, no ruling"
  assert_eq "1" "$(v5_count)" "…exactly one V5 finding"
  jset "$SIDECAR" '.claims[0].rulings = [{"date":"2026-10-11","direction":"DOC-STALE","by":"doc-owner","record":"docs/issues/token-ttl.md","reason":"Amended."}]'
  cl validate --all
  assert_v5 "CODE-DIVERGES" "diverged with a DOC-STALE ruling only"
  jset "$SIDECAR" ".claims[0].rulings += [$_CL_DIVERGES]"
  cl validate --all
  assert_v5_ok "diverged with a later CODE-DIVERGES ruling"
  teardown
}

test_v5_retired_without_ruling() {
  echo "test: V5 — a retired claim needs a RETIRE or DOC-STALE ruling"
  claims_fixture
  # Struck, so V2 has nothing to say.
  doc_edit "$DOC" "$TTL_LINE" "- ~~Access tokens expire after 15 minutes.~~"
  jset "$SIDECAR" '.claims[0].status = "retired"'
  rerender
  cl validate --all
  assert_v5 "RETIRE" "retired, no ruling"
  assert_eq "1" "$(v5_count)" "…exactly one V5 finding"
  jset "$SIDECAR" ".claims[0].rulings = [$_CL_DIVERGES]"
  cl validate --all
  assert_v5 "RETIRE" "retired with a CODE-DIVERGES ruling only"
  jset "$SIDECAR" ".claims[0].rulings = [$_CL_RETIRE]"
  cl validate --all
  assert_v5_ok "retired with a RETIRE ruling"
  jset "$SIDECAR" '.claims[0].rulings = [{"date":"2026-10-11","direction":"DOC-STALE","by":"doc-owner","record":"docs/issues/token-ttl.md","reason":"Superseded."}]'
  cl validate --all
  assert_v5_ok "retired with a DOC-STALE ruling"
  # A retired claim needs no tracker.
  jset "$SIDECAR" '.claims[0].tracker = null'
  cl validate --all
  assert_v5_ok "retired, tracker null"
  teardown
}

test_v5_judge_without_why() {
  echo "test: V5 — a judge claim needs why_not_mechanical"
  claims_fixture
  jset "$SIDECAR" '.claims[0].enforced_by = "judge"'
  cl validate --all
  assert_v5 "why_not_mechanical" "enforced_by judge, no why_not_mechanical"
  # test → judge lowers enforced_by, so with a ruling (V6).
  jset "$SIDECAR" ".claims[0].why_not_mechanical = \"Token expiry depends on the identity provider clock.\"
    | .claims[0].rulings = [$_CL_DOC_STALE]"
  cl validate --all
  assert_v5_ok "enforced_by judge with why_not_mechanical"
  teardown
}

test_v5_scope() {
  echo "test: V5 — touched, eligible claims only"
  claims_fixture
  jset "$SIDECAR" '.claims[0].tracker = null'
  git commit -qam "untracked claim"
  cl validate --all
  assert_v5 "no tracker" "--all: the committed claim without a tracker"
  cl validate --staged
  assert_v5_ok "--staged, nothing staged"
  echo "# change" >> src/auth/token.py
  git add src/auth/token.py
  cl validate --staged
  assert_v5 "no tracker" "--staged, the claim's subject staged"
  git reset -q
  # A doc that is missing: V1 names it once; V5 does not run on its claims.
  git rm -q "$DOC"
  cl validate --all
  assert_eq "1" "$(v1_count)" "doc deleted: one V1 finding"
  assert_eq "0" "$(v5_count)" "…and no V5 finding"
  teardown
}

# --- V6 merge-base ratchet -----------------------------------------------------

# The last `cl`'s V6 finding messages, one per line, and their count; its V6
# advisory codes and messages, one per line.
v6_messages() {
  jq -r '.findings[]? | select(.check == "V6") | .message' <<<"$CL_OUT" 2>/dev/null || true
}
v6_count() {
  jq '[.findings[]? | select(.check == "V6")] | length' <<<"$CL_OUT" 2>/dev/null || echo invalid
}
v6_codes() {
  jq -r '.advisories[]? | select(.check == "V6") | .code' <<<"$CL_OUT" 2>/dev/null || true
}
v6_advice() {
  jq -r '.advisories[]? | select(.check == "V6") | .message' <<<"$CL_OUT" 2>/dev/null || true
}

# assert_v6 <substring> <what>: the last `cl` exited 1 with a V6 finding whose
# message contains <substring>.
assert_v6() {
  assert_eq "1" "$CL_RC" "$2: exits 1"
  assert_contains "$(v6_messages)" "$1" "$2: a V6 finding names '$1'"
}

# assert_v6_ok <what>: the last `cl` exited 0 with no V6 finding.
assert_v6_ok() {
  assert_eq "0" "$CL_RC" "$1: exits 0"
  assert_eq "0" "$(v6_count)" "$1: no V6 finding"
}

# base_here <message>: commit everything on feature and move main to it, so
# this commit is the branch point — the merge-base V6 compares against.
base_here() {
  git add -A && git commit -qm "$1" && git branch -f main HEAD
}

# What a built test claim carries besides its promotion.
_CL_TEST='{"runner":"pytest","node":"tests/unit/test_token.py::test_ttl_is_15_minutes"}'
_CL_MUTANT='{"mutant":{"file":"src/auth/token.py","find":"TTL_SECONDS = 900","replace":"TTL_SECONDS = 1800"}}'
# The amended states of a DOC-STALE amendment.
NEW_STATES="An issued access token is rejected 15 minutes after issue, refresh included."

# The fixture repo's verdict store, resolved as _claims_store_dir does.
claims_store() {
  printf '%s/spec-claims/promotions\n' "$(cd "$(git rev-parse --git-common-dir)" && pwd -P)"
}

# write_verdict [states]: write the fixture claim's verdict into the store as
# promote will (Task 11): the jq -cS bytes of {claim, states_sha256, test,
# nonvacuity, head, subject_oids, green, red, status_to}, in a file named by
# their sha256. states_sha256 is the sha256 of [states] (default: the claim's
# own), with no trailing newline. Prints the digest.
write_verdict() {
  local store tmp st ss digest
  store=$(claims_store)
  mkdir -p "$store"
  st=$(harness_mktemp states)
  if [ $# -gt 0 ]; then printf '%s' "$1" > "$st"; else jq -j '.claims[0].states' "$SIDECAR" > "$st"; fi
  ss=$(hash_file "$st")
  rm -f "$st"
  tmp=$(harness_mktemp verdict)
  jq -cS --arg ss "$ss" --arg head "$(git rev-parse HEAD)" --arg oid "$(git rev-parse HEAD:src/auth/token.py)" \
    '.claims[0] | {claim: .id, states_sha256: $ss, test, nonvacuity, head: $head,
      subject_oids: {"src/auth/token.py": $oid}, green: "pass", red: "assert-fail", status_to: .status}' \
    "$SIDECAR" > "$tmp"
  digest=$(hash_file "$tmp")
  mv "$tmp" "$store/$digest.json"
  printf '%s\n' "$digest"
}

# hand_promote: the fixture claim made built as promote makes it. The bound
# test and the mutant are committed first (promote refuses a dirty tree, so
# the sidecar at promotion.at holds the proved states and test); then status
# built, its verdict in the store, and promotion {at: HEAD, verdict_sha256};
# then the doc's status block rendered, as promote renders it. Sets CL_DIGEST.
hand_promote() {
  jset "$SIDECAR" ".claims[0].test = $_CL_TEST | .claims[0].nonvacuity = $_CL_MUTANT"
  git add "$SIDECAR" && git commit -qm "bind the TTL test"
  jset "$SIDECAR" '.claims[0].status = "built"'
  CL_DIGEST=$(write_verdict)
  jset "$SIDECAR" ".claims[0].promotion = {\"at\": \"$(git rev-parse HEAD)\", \"verdict_sha256\": \"$CL_DIGEST\"}"
  rerender
}

# The fixture claim's DOC-STALE amendment: an AMENDED block re-quoting the
# sentence (quote_occurrence 2), new states, and the ruling.
doc_stale_amend() {
  add_amended_requote
  jset "$SIDECAR" ".claims[0].quote_occurrence = 2 | .claims[0].states = \"$NEW_STATES\"
    | .claims[0].rulings += [${1:-$_CL_DOC_STALE}]"
}

test_v6_states_changed_without_ruling() {
  echo "test: V6 — states changed without a ruling"
  claims_fixture
  jset "$SIDECAR" ".claims[0].states = \"$NEW_STATES\""
  git add "$SIDECAR"
  cl validate --staged
  assert_v6 "states" "--staged: states edited, no ruling"
  assert_json_field "$CL_OUT" '[.findings[] | select(.check == "V6")][0].claim' "SPEC-AUTH-001#token-ttl" "…the finding names the claim"
  assert_json_field "$CL_OUT" '[.findings[] | select(.check == "V6")][0].doc' "$DOC" "…and its doc"
  cl validate --all
  assert_v6 "states" "--all: states edited, no ruling"
  teardown
}

test_v6_states_changed_with_doc_stale_ruling_ok() {
  echo "test: V6 — states changed under a new DOC-STALE ruling"
  claims_fixture
  jset "$SIDECAR" ".claims[0].states = \"$NEW_STATES\" | .claims[0].rulings = [$_CL_DOC_STALE]"
  git add "$SIDECAR"
  cl validate --staged
  assert_v6_ok "--staged: states edited with a DOC-STALE ruling"
  cl validate --all
  assert_v6_ok "--all: states edited with a DOC-STALE ruling"
  teardown
}

test_v6_status_off_built_without_ruling() {
  echo "test: V6 — status moved off built without a ruling"
  claims_fixture
  hand_promote
  base_here "built"
  cl validate --all
  assert_v6_ok "precondition: the base's built claim, its verdict matching"
  assert_eq "" "$(v6_codes)" "…with no V6 advisory"
  jset "$SIDECAR" '.claims[0].status = "unbuilt"'
  rerender
  cl validate --all
  assert_v6 "off built" "built → unbuilt, no ruling"
  jset "$SIDECAR" ".claims[0].rulings += [$_CL_DOC_STALE]"
  cl validate --all
  assert_v6_ok "built → unbuilt with a new ruling"
  teardown
}

test_v6_enforced_by_lowered() {
  echo "test: V6 — enforced_by lowered without a ruling"
  claims_fixture
  jset "$SIDECAR" '.claims[0].enforced_by = "judge" | .claims[0].why_not_mechanical = "The clock is the identity provider'"'"'s."'
  cl validate --all
  assert_v6 "enforced_by" "test → judge, no ruling"
  jset "$SIDECAR" '.claims[0].enforced_by = "lint" | del(.claims[0].why_not_mechanical)'
  cl validate --all
  assert_v6 "enforced_by" "test → lint, no ruling"
  jset "$SIDECAR" ".claims[0].enforced_by = \"judge\" | .claims[0].why_not_mechanical = \"Clock skew.\" | .claims[0].rulings = [$_CL_DOC_STALE]"
  cl validate --all
  assert_v6_ok "test → judge with a new ruling"
  teardown
}

test_v6_claim_deleted() {
  echo "test: V6 — a claim deleted"
  claims_fixture
  jset "$SIDECAR" '.claims = []'
  cl validate --all
  assert_v6 "retire it instead" "--all: the claim removed from its sidecar"
  assert_json_field "$CL_OUT" '[.findings[] | select(.check == "V6")][0].claim' "SPEC-AUTH-001#token-ttl" "…the finding names the deleted claim"
  git add "$SIDECAR"
  cl validate --staged
  assert_v6 "retire it instead" "--staged: the claim removed from its sidecar"
  teardown
}

test_v6_sidecar_deleted_after_all_retired_ok() {
  echo "test: V6 — a sidecar whose claims were all retired at the merge-base may go"
  claims_fixture
  doc_edit "$DOC" "$TTL_LINE" "- ~~Access tokens expire after 15 minutes.~~"
  jset "$SIDECAR" ".claims[0].status = \"retired\" | .claims[0].rulings = [$_CL_RETIRE]"
  base_here "retire the TTL claim"
  git rm -q "$SIDECAR"
  cl validate --staged
  assert_v6_ok "--staged: the fully retired sidecar deleted"
  cl validate --all
  assert_v6_ok "--all: the fully retired sidecar deleted"
  teardown
}

test_v6_sidecar_deleted_with_live_claims_finding() {
  echo "test: V6 — a sidecar with live claims deleted"
  claims_fixture
  git rm -q "$SIDECAR"
  cl validate --staged
  assert_v6 "retire it instead" "--staged: the sidecar (claim unbuilt at base) deleted"
  cl validate --all
  assert_v6 "retire it instead" "--all: the sidecar deleted"
  teardown
}

test_v6_built_record_edit_rechecks_verdict() {
  echo "test: V6 — a built claim's edited record re-checks its verdict"
  claims_fixture
  hand_promote
  base_here "built"
  printf 'LEEWAY = 0\n' > src/auth/ttl.py
  jset "$SIDECAR" '.claims[0].subject += ["src/auth/ttl.py"]'
  cl validate --all
  assert_v6_ok "subject edited, the verdict still matching"
  assert_eq "" "$(v6_codes)" "…with no V6 advisory"
  rm -f "$(claims_store)/$CL_DIGEST.json"
  cl validate --all
  assert_v6_ok "subject edited, the verdict missing"
  assert_contains "$(v6_codes)" "unverifiable-here" "…re-checked though the status did not move: unverifiable-here"
  teardown
}

test_v6_reanchor_reflow_needs_no_ruling() {
  echo "test: V6 — a re-anchor equal after normalisation needs no ruling"
  claims_fixture
  doc_edit "$DOC" "$TTL_LINE" $'- Access tokens expire\n  after 15 minutes.'
  jset "$SIDECAR" '.claims[0].quote = "Access  tokens expire\nafter 15 minutes"'
  cl validate --all
  assert_v6_ok "the quote and the doc reflowed"
  assert_eq "0" "$(v2_count)" "…and still anchored"
  teardown
}

test_v6_reanchor_token_change_needs_ruling() {
  echo "test: V6 — a re-anchor that changes a token needs a ruling"
  claims_fixture
  doc_edit "$DOC" "$TTL_LINE" "- Access tokens expire after 20 minutes."
  jset "$SIDECAR" '.claims[0].quote = "Access tokens expire after 20 minutes"'
  cl validate --all
  assert_v6 "re-anchor" "the doc and the quote both 15 → 20, no ruling"
  assert_eq "0" "$(v2_count)" "…the new quote anchored (V2 is silent)"
  jset "$SIDECAR" ".claims[0].rulings = [$_CL_DOC_STALE]"
  cl validate --all
  assert_v6_ok "15 → 20 with a new DOC-STALE ruling"
  teardown
}

test_v6_self_referential_record_refused() {
  echo "test: V6 — a ruling whose record is the doc or the sidecar"
  claims_fixture
  jset "$SIDECAR" ".claims[0].rulings = [$_CL_DOC_STALE] | .claims[0].rulings[0].record = \"$DOC\""
  cl validate --all
  assert_v6 "self-referential" "record = the doc"
  jset "$SIDECAR" ".claims[0].rulings[0].record = \"$SIDECAR\""
  cl validate --all
  assert_v6 "self-referential" "record = the sidecar"
  teardown
}

test_v6_record_missing_refused() {
  echo "test: V6 — a ruling whose record does not exist"
  claims_fixture
  jset "$SIDECAR" ".claims[0].rulings = [$_CL_DOC_STALE] | .claims[0].rulings[0].record = \"docs/issues/absent.md\""
  cl validate --all
  assert_v6 "record" "record docs/issues/absent.md"
  assert_contains "$(v6_messages)" "docs/issues/absent.md" "…naming the record"
  # --staged reads the index: a record in the work tree alone does not count.
  printf '# Absent\n' > docs/issues/absent.md
  cl validate --all
  assert_v6_ok "--all, the record in the work tree"
  git add "$SIDECAR"
  cl validate --staged
  assert_v6 "docs/issues/absent.md" "--staged, the record untracked"
  git add docs/issues/absent.md
  cl validate --staged
  assert_v6_ok "--staged, the record staged"
  teardown
}

test_v6_merge_base_ratchet_behind_trunk() {
  echo "test: V6 — a branch behind a ruled trunk change compares with the merge-base"
  claims_fixture
  local fork
  fork=$(git rev-parse HEAD)
  git checkout -q main
  jset "$SIDECAR" ".claims[0].states = \"$NEW_STATES\" | .claims[0].rulings = [$_CL_DOC_STALE]"
  git commit -qam "DOC-STALE: the TTL states"
  git checkout -q feature
  echo "// unrelated" >> src/index.js
  git commit -qam "unrelated"
  cl validate --all
  assert_v6_ok "feature behind main's ruled states change"
  assert_json_field "$CL_OUT" '.base.merge_base' "$fork" "…compared with the merge-base, not main's tip"
  teardown
}

test_v6_hand_edited_built_refused() {
  echo "test: V6 — status built without a promotion"
  claims_fixture
  jset "$SIDECAR" ".claims[0].status = \"built\" | .claims[0].test = $_CL_TEST | .claims[0].nonvacuity = $_CL_MUTANT"
  cl validate --all
  assert_v6 "promote" "unbuilt → built by hand, no promotion"
  assert_eq "1" "$(v6_count)" "…exactly one V6 finding"
  jset "$SIDECAR" ".claims[0].rulings = [$_CL_DOC_STALE]"
  cl validate --all
  assert_v6 "promote" "…which a ruling does not license"
  teardown
}

test_v6_unverifiable_here_advisory() {
  echo "test: V6 — a promotion whose verdict is not in this clone's store"
  claims_fixture
  jset "$SIDECAR" ".claims[0].status = \"built\" | .claims[0].test = $_CL_TEST | .claims[0].nonvacuity = $_CL_MUTANT
    | .claims[0].promotion = {\"at\": \"$(git rev-parse HEAD)\", \"verdict_sha256\": \"$(printf '%064d' 0)\"}"
  rerender
  cl validate --all
  assert_v6_ok "built with a promotion, no verdict file"
  assert_contains "$(v6_codes)" "unverifiable-here" "…an unverifiable-here advisory"
  teardown
}

test_v6_verdict_mismatch_is_finding() {
  echo "test: V6 — a promotion whose verdict does not match the claim"
  claims_fixture
  local d
  jset "$SIDECAR" ".claims[0].status = \"built\" | .claims[0].test = $_CL_TEST | .claims[0].nonvacuity = $_CL_MUTANT"
  d=$(write_verdict "Another statement.")
  jset "$SIDECAR" ".claims[0].promotion = {\"at\": \"$(git rev-parse HEAD)\", \"verdict_sha256\": \"$d\"}"
  cl validate --all
  assert_v6 "verdict" "the verdict's states_sha256 is another statement's"
  # A verdict file whose bytes no longer hash to its digest.
  hand_promote
  cl validate --all
  assert_v6_ok "precondition: a matching verdict"
  printf ' ' >> "$(claims_store)/$CL_DIGEST.json"
  cl validate --all
  assert_v6 "verdict" "the verdict file edited after promotion"
  teardown
}

test_v6_doc_stale_on_built_is_repromote_owed() {
  echo "test: V6 — a DOC-STALE amendment of a built claim: re-promote owed"
  claims_fixture
  hand_promote
  base_here "built"
  doc_stale_amend
  git add -A
  cl validate --staged
  assert_eq "0" "$CL_RC" "--staged: the amendment commits (exits 0)"
  assert_eq "0" "$(v6_count)" "…no V6 finding"
  assert_contains "$(v6_codes)" "re-promote owed" "…a re-promote owed advisory"
  assert_contains "$(v6_advice)" "states changed under a ruling: run claims promote SPEC-AUTH-001#token-ttl" "…naming the promote to run"
  teardown
}

test_v6_mismatch_with_code_diverges_ruling_still_finding() {
  echo "test: V6 — a CODE-DIVERGES ruling does not cover a built claim's verdict mismatch"
  claims_fixture
  hand_promote
  base_here "built"
  doc_stale_amend "$_CL_DIVERGES"
  git add -A
  cl validate --staged
  assert_v6 "verdict" "states amended under CODE-DIVERGES, status built"
  assert_not_contains "$(v6_codes)" "re-promote owed" "…not a re-promote owed advisory"
  teardown
}

test_v6_staged_reads_index_not_worktree() {
  echo "test: V6 — --staged reads the index, not the work tree"
  claims_fixture
  printf 'LEEWAY = 0\n' > src/auth/ttl.py
  jset "$SIDECAR" '.claims[0].subject += ["src/auth/ttl.py"]'
  git add -A
  jset "$SIDECAR" ".claims[0].states = \"$NEW_STATES\""
  cl validate --staged
  assert_v6_ok "--staged: the staged sidecar is clean"
  cl validate --all
  assert_v6 "states" "--all: the work tree's states edit"
  teardown
}

# _claims_repromote_owed, through a probe (its consumers, gate and attest,
# come later): run on the fixture claim with <since-rev> = the merge-base.
repromote_owed() {
  local out
  out=$(CL_PROBE_ID="SPEC-AUTH-001#token-ttl" "$CL_PROBE" claims render </dev/null 2>/dev/null) || out="rc $?: $out"
  printf '%s\n' "$out"
}

test_v6_repromote_owed_proved_record() {
  echo "test: _claims_repromote_owed — by the local verdict, else by the record at promotion.at"
  claims_fixture
  CL_PROBE=$(claims_probe after '_claims_load; r=$(_claims_repromote_owed "$CL_PROBE_ID" "$_CL_MB") || _claims_propagate $?; _claims_mark_emitted 0; _claims_out "$r"; exit 0')
  assert_eq "clear" "$(repromote_owed)" "an unbuilt claim: clear"
  hand_promote
  base_here "built"
  local store at aside c init other
  store=$(claims_store)
  aside=$(harness_mktemp_d verdict-aside)
  assert_eq "clear" "$(repromote_owed)" "built, the verdict present and matching: clear"
  mv "$store/$CL_DIGEST.json" "$aside/"
  assert_eq "clear" "$(repromote_owed)" "built, the verdict missing, states and test as at promotion.at: clear"
  mv "$aside/$CL_DIGEST.json" "$store/"
  # The amendment (commit A), committed after the proof.
  doc_stale_amend
  git add -A && git commit -qm "DOC-STALE: amend the TTL claim"
  assert_eq "owed" "$(repromote_owed)" "amended, the verdict present (mismatch): owed"
  rm -f "$store/$CL_DIGEST.json"
  assert_eq "owed" "$(repromote_owed)" "amended, the verdict missing, states not those at promotion.at: owed"
  # Re-promoted at A.
  at=$(git rev-parse HEAD)
  CL_DIGEST=$(write_verdict)
  jset "$SIDECAR" ".claims[0].promotion = {\"at\": \"$at\", \"verdict_sha256\": \"$CL_DIGEST\"}"
  git commit -qam "promote SPEC-AUTH-001#token-ttl"
  assert_eq "clear" "$(repromote_owed)" "re-promoted at A, the verdict present: clear"
  mv "$store/$CL_DIGEST.json" "$aside/"
  assert_eq "clear" "$(repromote_owed)" "re-promoted at A, the verdict missing, states and test as at A: clear"
  # A second states change under the same ruling (commit C): the ruling is
  # still new against the merge-base, but these states were never proved.
  jset "$SIDECAR" '.claims[0].states = "An issued access token is rejected 15 minutes after issue, or at logout."'
  git commit -qam "states again, under the same ruling"
  mv "$aside/$CL_DIGEST.json" "$store/"
  cl validate --all
  assert_contains "$(v6_codes)" "re-promote owed" "precondition: V6 licenses C (re-promote owed, not a finding)"
  assert_eq "owed" "$(repromote_owed)" "states changed after the re-promotion, the verdict present: owed"
  mv "$store/$CL_DIGEST.json" "$aside/"
  assert_eq "owed" "$(repromote_owed)" "states changed after the re-promotion, the verdict missing: owed"
  # The test changed instead (states as proved at A).
  git show "$at:$SIDECAR" | jq -r '.claims[0].states' > "$aside/states"
  jset "$SIDECAR" ".claims[0].states = $(jq -Rs 'rtrimstr("\n")' "$aside/states") | .claims[0].test.node = \"tests/unit/test_token.py::test_other\""
  assert_eq "owed" "$(repromote_owed)" "the test changed after the re-promotion, the verdict missing: owed"
  jset "$SIDECAR" ".claims[0].test = $_CL_TEST"
  assert_eq "clear" "$(repromote_owed)" "states and test back to those proved at A: clear"
  # A rebased branch's old sha.
  jset "$SIDECAR" ".claims[0].promotion.at = \"$(printf '%040d' 7)\""
  assert_eq "unverifiable-here" "$(repromote_owed)" "the verdict missing, promotion.at not a commit here: unverifiable-here"
  # promotion.at a commit without the sidecar (the repository's first).
  init=$(git rev-list --max-parents=0 HEAD)
  jset "$SIDECAR" ".claims[0].promotion.at = \"$init\""
  assert_eq "unverifiable-here" "$(repromote_owed)" "the sidecar absent at promotion.at: unverifiable-here"
  # promotion.at a commit whose sidecar holds no claim with that id.
  c=$(git rev-parse HEAD)
  git checkout -q -b other
  jset "$SIDECAR" '.claims[0].id = "SPEC-AUTH-001#other"'
  git commit -qam "another claim id"
  other=$(git rev-parse HEAD)
  git checkout -q feature
  git branch -q -D other
  assert_eq "$c" "$(git rev-parse HEAD)" "precondition: back on feature"
  jset "$SIDECAR" ".claims[0].promotion.at = \"$other\" | .claims[0].test = $_CL_TEST"
  assert_eq "unverifiable-here" "$(repromote_owed)" "no claim with that id in the sidecar at promotion.at: unverifiable-here"
  teardown
}

# --- Status block render and V11 -----------------------------------------------

BLOCK_BEGIN='<!-- spec-claims:status:begin -->'
BLOCK_END='<!-- spec-claims:status:end -->'
# The fixture block's row, and the same row hand-edited.
# shellcheck disable=SC2016  # Markdown backticks, not command substitution
TTL_ROW='| `SPEC-AUTH-001#token-ttl` | unbuilt | docs/issues/token-ttl.md |'
# shellcheck disable=SC2016  # Markdown backticks, not command substitution
TTL_ROW_EDITED='| `SPEC-AUTH-001#token-ttl` | built | docs/issues/token-ttl.md |'

v11_messages() {
  jq -r '.findings[]? | select(.check == "V11") | .message' <<<"$CL_OUT" 2>/dev/null || true
}
v11_count() {
  jq '[.findings[]?, .advisories[]? | select(.check == "V11")] | length' <<<"$CL_OUT" 2>/dev/null || echo invalid
}

# rerender: the fixture's status blocks rendered again, as a status change
# owes (§B); the run must succeed.
rerender() {
  "$DOC_TOOLS" claims render </dev/null >/dev/null 2>&1 || { echo "rerender failed" >&2; return 1; }
}

# strip_block <file>: drop the status block (its marker lines and every line
# between them), as a doc that was never rendered.
strip_block() {
  local tmp
  tmp=$(harness_mktemp strip-block)
  B="$BLOCK_BEGIN" E="$BLOCK_END" awk '
    $0 == ENVIRON["B"] { skip = 1 }
    !skip { print }
    $0 == ENVIRON["E"] { skip = 0 }' "$1" > "$tmp"
  cat "$tmp" > "$1"
  rm -f "$tmp"
}

# block_of <file>: the lines strictly between the status-block markers.
block_of() {
  B="$BLOCK_BEGIN" E="$BLOCK_END" awk '
    $0 == ENVIRON["E"] { exit }
    on { print }
    $0 == ENVIRON["B"] { on = 1 }' "$1"
}

# line_no <file> <exact line>: the 1-based number of its first line equal to
# <exact line> ("" when none).
line_no() {
  L="$2" awk '$0 == ENVIRON["L"] { print NR; exit }' "$1"
}

# 0 when the fixture doc in the work tree differs from HEAD's.
doc_differs_from_head() {
  ! git diff --quiet HEAD -- "$DOC"
}

# The line just before the first line equal to <exact line>.
line_before() {
  L="$2" awk '$0 == ENVIRON["L"] { print prev; exit } { prev = $0 }' "$1"
}

test_v11_fixture_is_rendered() {
  echo "test: V11 — the fixture's status block is exactly what render writes"
  claims_fixture
  cl render --check
  assert_eq "0" "$CL_RC" "render --check on the fixture exits 0"
  assert_json_field "$CL_OUT" '.results | tojson' "[{\"doc\":\"$DOC\",\"changed\":false}]" "…one result, unchanged"
  cl validate --all
  assert_eq "0" "$(v11_count)" "validate --all: no V11 finding"
  teardown
}

test_v11_render_inserts_before_second_heading() {
  echo "test: V11 — the first render goes before the doc's second ## heading"
  claims_fixture
  strip_block "$DOC"
  assert_eq "" "$(line_no "$DOC" "$BLOCK_BEGIN")" "precondition: no block"
  cl validate --all
  assert_eq "1" "$CL_RC" "no block: validate --all exits 1"
  assert_contains "$(v11_messages)" "no status block" "…a V11 finding: no status block"
  cl render
  assert_eq "0" "$CL_RC" "render exits 0"
  assert_json_field "$CL_OUT" '.results | tojson' "[{\"doc\":\"$DOC\",\"changed\":true}]" "…reports the doc changed"
  assert_eq "$BLOCK_END" "$(line_before "$DOC" "## Requirements")" "the end marker is the line before ## Requirements"
  assert_true "## Summary precedes the begin marker" \
    test "$(line_no "$DOC" "## Summary")" -lt "$(line_no "$DOC" "$BLOCK_BEGIN")"
  assert_true "the render is byte for byte the committed fixture" git diff --quiet -- "$DOC"
  cl validate --all
  assert_eq "0" "$CL_RC" "rendered: validate --all exits 0"
  teardown
}

test_v11_render_idempotent() {
  echo "test: V11 — a second render changes nothing"
  claims_fixture
  strip_block "$DOC"
  cl render
  assert_json_field "$CL_OUT" '.results[0].changed' "true" "the first render changes the doc"
  local h
  h=$(hash_file "$DOC")
  cl render
  assert_eq "0" "$CL_RC" "the second render exits 0"
  assert_json_field "$CL_OUT" '.results[0].changed' "false" "…reports changed: false"
  assert_eq "$h" "$(hash_file "$DOC")" "…and leaves the doc byte-identical"
  teardown
}

test_v11_render_all_built_one_line() {
  echo "test: V11 — every live claim built: the block is one line"
  claims_fixture
  hand_promote
  assert_true "the promotion's render changed the doc" doc_differs_from_head
  assert_eq $'## Claim status\n\nClaims: 1 built' "$(block_of "$DOC")" "block body: Claims: 1 built"
  cl render
  assert_eq "0" "$CL_RC" "render exits 0"
  assert_json_field "$CL_OUT" '.results[0].changed' "false" "…and has nothing left to change"
  cl render --check
  assert_eq "0" "$CL_RC" "render --check after render exits 0"
  teardown
}

test_v11_check_detects_hand_edit() {
  echo "test: V11 — render --check reports a hand-edited block and writes nothing"
  claims_fixture
  doc_edit "$DOC" "$TTL_ROW" "$TTL_ROW_EDITED"
  local h
  h=$(hash_file "$DOC")
  cl render --check
  assert_eq "1" "$CL_RC" "render --check exits 1"
  assert_eq "1" "$(v11_count)" "…one V11 finding"
  assert_json_field "$CL_OUT" '.findings[0].doc' "$DOC" "…naming the doc"
  assert_contains "$(v11_messages)" "claims render" "…advising claims render"
  assert_eq "$h" "$(hash_file "$DOC")" "…and the doc is unchanged"
  cl validate --all
  assert_eq "1" "$CL_RC" "validate --all exits 1"
  assert_eq "1" "$(v11_count)" "…with one V11 finding"
  # Markers that are not one begin/end pair: a finding, the doc untouched.
  doc_edit "$DOC" "## Requirements" "$BLOCK_BEGIN"$'\n'"## Requirements"
  h=$(hash_file "$DOC")
  cl render
  assert_eq "1" "$CL_RC" "render with an unpaired begin marker exits 1"
  assert_contains "$(v11_messages)" "not one begin/end pair" "…a V11 finding: the markers are not one pair"
  assert_eq "$h" "$(hash_file "$DOC")" "…and the doc is not written"
  teardown
}

test_v11_only_when_sidecar_staged() {
  echo "test: V11 under --staged — only a doc whose sidecar is staged"
  claims_fixture
  doc_edit "$DOC" "$TTL_ROW" "$TTL_ROW_EDITED"
  git add "$DOC"
  cl validate --staged
  assert_eq "0" "$(v11_count)" "only the doc staged: no V11"
  # The same claims, reformatted: a staged sidecar change that means nothing.
  jq -c . "$SIDECAR" > "$SIDECAR.tmp" && mv "$SIDECAR.tmp" "$SIDECAR"
  git add "$SIDECAR"
  cl validate --staged
  assert_eq "1" "$CL_RC" "the sidecar staged too: exits 1"
  assert_eq "1" "$(v11_count)" "…one V11 finding"
  # The staged doc is what counts: fixing the work tree alone changes nothing.
  git show "HEAD:$DOC" > "$DOC"
  cl validate --staged
  assert_eq "1" "$(v11_count)" "the work tree fixed, the index not: still V11"
  git add "$DOC"
  cl validate --staged
  assert_eq "0" "$(v11_count)" "the fix staged: no V11"
  teardown
}

test_v11_fence_heading_ignored() {
  echo "test: V11 — a ## line inside a code fence is not a heading"
  claims_fixture
  strip_block "$DOC"
  doc_edit "$DOC" "How long issued tokens stay valid." \
    $'\n~~~markdown\n## x\n~~~\n\n````markdown\n```\n## y\n```\n````' after
  cl render
  assert_eq "0" "$CL_RC" "render exits 0"
  assert_eq "$BLOCK_END" "$(line_before "$DOC" "## Requirements")" "the block goes before ## Requirements"
  assert_true "…after the ~~~ fence's ## x" test "$(line_no "$DOC" "## x")" -lt "$(line_no "$DOC" "$BLOCK_BEGIN")"
  assert_true "…and after the nested fence's ## y (CommonMark pairing)" \
    test "$(line_no "$DOC" "## y")" -lt "$(line_no "$DOC" "$BLOCK_BEGIN")"
  # No ## heading outside a fence after the first: end of file, after one blank line.
  # shellcheck disable=SC2016  # Markdown backticks, not command substitution
  printf '# T\n\n## Only\n\nText.\n\n```\n## z\n```\n' > "$DOC"
  cl render
  assert_eq $'# T\n\n## Only\n\nText.\n\n```\n## z\n```\n\n'"$BLOCK_BEGIN"$'\n## Claim status\n\n| Claim | Status | Tracker |\n|---|---|---|\n| `SPEC-AUTH-001#token-ttl` | unbuilt | docs/issues/token-ttl.md |\n\n'"$BLOCK_END" \
    "$(cat "$DOC")" "no second heading: the block ends the file, after one blank line"
  teardown
}

test_v11_retired_not_listed() {
  echo "test: V11 — a retired claim is not listed"
  claims_fixture
  doc_edit "$DOC" "- Refresh tokens are single-use." "- ~~Refresh tokens are single-use.~~"
  jset "$SIDECAR" ".claims += [{id: \"SPEC-AUTH-001#refresh-single-use\", quote: \"Refresh tokens are single-use\",
      states: \"A refresh token is accepted once.\", kind: \"behaviour\", subject: [\"src/auth/token.py\"],
      status: \"retired\", enforced_by: \"test\", test: null, nonvacuity: null, promotion: null,
      tracker: null, frozen_at: null, restates: [], rulings: [$_CL_RETIRE]}]"
  cl render
  assert_eq "0" "$CL_RC" "render exits 0"
  assert_contains "$(block_of "$DOC")" "SPEC-AUTH-001#token-ttl" "the unbuilt claim is listed"
  assert_not_contains "$(block_of "$DOC")" "refresh-single-use" "the retired claim is not"
  # Every live claim built: the count leaves the retired one out.
  hand_promote
  assert_eq $'## Claim status\n\nClaims: 1 built' "$(block_of "$DOC")" "one built, one retired: Claims: 1 built"
  teardown
}

test_v11_crlf_doc() {
  echo "test: V11 — a CRLF doc gets a CRLF block, rendered as its LF twin"
  claims_fixture
  local lf
  lf=$(harness_mktemp lf-doc)
  cp "$DOC" "$lf"
  awk '{ printf "%s\r\n", $0 }' "$lf" > "$DOC"
  cl render --check
  assert_eq "0" "$CL_RC" "the fixture saved with CRLF: render --check exits 0"
  strip_block "$lf"
  awk '{ printf "%s\r\n", $0 }' "$lf" > "$DOC"
  cl render
  assert_json_field "$CL_OUT" '.results[0].changed' "true" "the block stripped: render inserts it"
  tr -d '\r' < "$DOC" > "$lf"
  git show "HEAD:$DOC" > "$lf.head"
  assert_true "…the render is the LF fixture's, line for line" cmp -s "$lf" "$lf.head"
  assert_eq "0" "$(LC_ALL=C awk '!/\r$/ { n++ } END { print n + 0 }' "$DOC")" "…every line still ends in CRLF"
  rm -f "$lf" "$lf.head"
  teardown
}

test_render_archived_doc_skipped() {
  echo "test: render — an archived doc is skipped, never written"
  claims_fixture
  local arch=docs/archive/specs/SPEC-AUTH-001-token.md h
  mkdir -p docs/archive/specs
  git mv "$DOC" "$arch"
  jset "$SIDECAR" ".doc = \"$arch\" | .claims[0].status = \"retired\" | .claims[0].rulings = [$_CL_RETIRE]"
  git add -A && git commit -qm "archive SPEC-AUTH-001"
  h=$(hash_file "$arch")
  cl render
  assert_eq "0" "$CL_RC" "render exits 0"
  assert_json_field "$CL_OUT" '.results | tojson' "[{\"doc\":\"$arch\",\"skipped\":\"not governing\"}]" "…reports skipped: not governing"
  assert_eq "$h" "$(hash_file "$arch")" "…and the archived file is byte-identical"
  assert_true "…the work tree is clean" git diff --quiet
  cl validate --all
  assert_eq "0" "$(v11_count)" "validate --all: no V11"
  jq -c . "$SIDECAR" > "$SIDECAR.tmp" && mv "$SIDECAR.tmp" "$SIDECAR"
  git add "$SIDECAR"
  cl validate --staged
  assert_eq "0" "$(v11_count)" "validate --staged, the sidecar staged: no V11"
  cl render --check
  assert_eq "0" "$CL_RC" "render --check exits 0"
  teardown
}

test_render_deleted_doc_check_ok() {
  echo "test: render — a deleted doc is skipped, never created"
  claims_fixture
  jset "$SIDECAR" ".claims[0].status = \"retired\" | .claims[0].rulings = [$_CL_RETIRE]"
  git rm -q "$DOC"
  git add -A && git commit -qm "delete SPEC-AUTH-001"
  cl render --check
  assert_eq "0" "$CL_RC" "render --check exits 0"
  assert_json_field "$CL_OUT" '.results | tojson' "[{\"doc\":\"$DOC\",\"skipped\":\"doc missing\"}]" "…reports skipped: doc missing"
  cl render
  assert_eq "0" "$CL_RC" "render exits 0"
  assert_true "…and creates no file at the old path" test ! -e "$DOC"
  cl validate --all
  assert_eq "0" "$(v11_count)" "validate --all: no V11"
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
  test_fence_pairing_commonmark
  test_amended_flag_carry

  # --- Task 4: V5 status requirements ---
  test_v5_fixture_passes
  test_v5_diverged_without_tracker
  test_v5_tracker_missing_path
  test_v5_tracker_closed_is_finding
  test_v5_tracker_status_leading_word
  test_v5_tracker_pattern_accepted
  test_v5_diverged_without_code_diverges_ruling
  test_v5_retired_without_ruling
  test_v5_judge_without_why
  test_v5_scope

  # --- Task 5: V6 merge-base ratchet ---
  test_v6_states_changed_without_ruling
  test_v6_states_changed_with_doc_stale_ruling_ok
  test_v6_status_off_built_without_ruling
  test_v6_enforced_by_lowered
  test_v6_claim_deleted
  test_v6_sidecar_deleted_after_all_retired_ok
  test_v6_sidecar_deleted_with_live_claims_finding
  test_v6_built_record_edit_rechecks_verdict
  test_v6_reanchor_reflow_needs_no_ruling
  test_v6_reanchor_token_change_needs_ruling
  test_v6_self_referential_record_refused
  test_v6_record_missing_refused
  test_v6_merge_base_ratchet_behind_trunk
  test_v6_hand_edited_built_refused
  test_v6_unverifiable_here_advisory
  test_v6_verdict_mismatch_is_finding
  test_v6_doc_stale_on_built_is_repromote_owed
  test_v6_mismatch_with_code_diverges_ruling_still_finding
  test_v6_staged_reads_index_not_worktree
  test_v6_repromote_owed_proved_record

  # --- Task 6: status block render and V11 ---
  test_v11_fixture_is_rendered
  test_v11_render_inserts_before_second_heading
  test_v11_render_idempotent
  test_v11_render_all_built_one_line
  test_v11_check_detects_hand_edit
  test_v11_only_when_sidecar_staged
  test_v11_fence_heading_ignored
  test_v11_retired_not_listed
  test_v11_crlf_doc
  test_render_archived_doc_skipped
  test_render_deleted_doc_check_ok

  print_summary
}

run_tests
