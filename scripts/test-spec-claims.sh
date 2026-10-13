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

# diverge_claim [<test-json>]: the fixture claim made diverged: a bound test
# (V1 wants one once the claim runs; bind_test, so V3 holds; default
# _CL_PYTEST_TTL) and the CODE-DIVERGES ruling, its tracker left as the
# fixture's.
_CL_PYTEST_TTL='{"runner":"pytest","node":"tests/test_token.py::test_ttl"}'
diverge_claim() {
  bind_test "${1:-$_CL_PYTEST_TTL}"
  jset "$SIDECAR" ".claims[0].status = \"diverged\" | .claims[0].rulings = [$_CL_DIVERGES]"
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

# verdict_bytes <out-file> [states]: the fixture claim's verdict as promote
# writes it (doc-tools' claims promote): the jq -cS bytes of {claim,
# states_sha256, test, nonvacuity, head, subject_oids, green, red,
# status_to}. states_sha256 is the sha256 of [states] (default: the claim's
# own), with no trailing newline; head is HEAD; subject_oids maps each
# subject path to its object at HEAD; status_to is the claim's status.
verdict_bytes() {
  local st ss oids p
  st=$(harness_mktemp states)
  if [ $# -gt 1 ]; then printf '%s' "$2" > "$st"; else jq -j '.claims[0].states' "$SIDECAR" > "$st"; fi
  ss=$(hash_file "$st")
  rm -f "$st"
  oids='{}'
  while IFS= read -r p; do
    oids=$(jq -c --arg p "$p" --arg o "$(git rev-parse "HEAD:$p")" '. + {($p): $o}' <<<"$oids")
  done < <(jq -r '.claims[0].subject[]' "$SIDECAR")
  jq -cS --arg ss "$ss" --arg head "$(git rev-parse HEAD)" --argjson oids "$oids" \
    '.claims[0] | {claim: .id, states_sha256: $ss, test, nonvacuity, head: $head,
      subject_oids: $oids, green: "pass", red: "assert-fail", status_to: .status}' \
    "$SIDECAR" > "$1"
}

# write_verdict [states]: write the fixture claim's verdict (verdict_bytes)
# into the store, in a file named by its sha256, as promote does. Prints the
# digest.
write_verdict() {
  local store tmp digest
  store=$(claims_store)
  mkdir -p "$store"
  tmp=$(harness_mktemp verdict)
  verdict_bytes "$tmp" "$@"
  digest=$(hash_file "$tmp")
  mv "$tmp" "$store/$digest.json"
  printf '%s\n' "$digest"
}

# hand_promote: the fixture claim made built as promote makes it. The bound
# test (bind_test: what V3 checks) and the mutant are committed first
# (promote refuses a dirty tree, so the sidecar at promotion.at holds the
# proved states and test); then status built, its verdict in the store, and
# promotion {at: HEAD, verdict_sha256}; then the doc's status block
# rendered, as promote renders it. Sets CL_DIGEST.
hand_promote() {
  bind_test "$_CL_TEST"
  jset "$SIDECAR" ".claims[0].nonvacuity = $_CL_MUTANT"
  git add "$SIDECAR" docs/spec-claims/config.json tools/claims && git commit -qm "bind the TTL test"
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
  bind_test "$_CL_TEST"
  jset "$SIDECAR" ".claims[0].status = \"built\" | .claims[0].nonvacuity = $_CL_MUTANT"
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
  bind_test "$_CL_TEST"
  jset "$SIDECAR" ".claims[0].status = \"built\" | .claims[0].nonvacuity = $_CL_MUTANT
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
  bind_test "$_CL_TEST"
  jset "$SIDECAR" ".claims[0].status = \"built\" | .claims[0].nonvacuity = $_CL_MUTANT"
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
# owes (§B). A failed render fails the test.
rerender() {
  local rc=0
  "$DOC_TOOLS" claims render </dev/null >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "rerender: claims render exits 0"
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

# evil_sidecar <doc> [DOC-ID]: a sidecar <DOC-ID>.json (default SPEC-EVIL-001)
# whose doc is <doc>, its one claim quoting the evil doc's sentence.
evil_sidecar() {
  local id="${2:-SPEC-EVIL-001}"
  jq -n --arg doc "$1" --arg id "$id#x" '{schema: 1, doc: $doc, claims: [{
    id: $id, quote: "Evil sentence",
    states: "The evil doc says so.", kind: "behaviour", subject: ["src/auth/token.py"],
    status: "unbuilt", enforced_by: "test", test: null, nonvacuity: null, promotion: null,
    tracker: "docs/issues/token-ttl.md", frozen_at: null, restates: [], rulings: []}]}' \
    > "docs/spec-claims/$id.json"
}

# A spec outside the work tree, beside it in the suite's scratch root: sets
# EVIL_DIR (absolute) and EVIL_REL (docs/specs/../../../<dir>/…, which a
# governing glob's * matches).
evil_outside() {
  EVIL_DIR=$(mktemp -d "$SUITE_TMP/outside.XXXXXX")
  printf '# SPEC-EVIL-001\n\n## Summary\n\nEvil sentence.\n\n## Requirements\n\nNone.\n' \
    > "$EVIL_DIR/SPEC-EVIL-001-x.md"
  EVIL_REL="docs/specs/../../../$(basename "$EVIL_DIR")/SPEC-EVIL-001-x.md"
}

test_v1_unsafe_doc_path() {
  echo "test: V1 — a sidecar doc that is not a safe repo path is a finding, never read"
  claims_fixture
  evil_outside
  printf '# SPEC-EVIL-001\n\n## Summary\n\nEvil sentence.\n' > docs/specs/SPEC-EVIL-001-x.md
  git add docs/specs/SPEC-EVIL-001-x.md && git commit -qm "an evil spec inside, too"
  local d
  for d in "$EVIL_REL" "$EVIL_DIR/SPEC-EVIL-001-x.md" "docs/specs/./SPEC-EVIL-001-x.md"; do
    evil_sidecar "$d"
    cl validate --all
    assert_v1 "not a safe repo path" "--all, doc $d"
    assert_contains "$(v1_messages)" "docs/spec-claims/SPEC-EVIL-001.json: doc $d" "…naming the sidecar and the path"
    assert_eq "0" "$(v2_count)" "…no V2 finding (the doc is never read)"
    assert_eq "0" "$(v11_count)" "…no V11 finding"
    git add docs/spec-claims/SPEC-EVIL-001.json
    cl validate --staged
    assert_v1 "not a safe repo path" "--staged, doc $d"
    git reset -q
  done
  rm -rf "$EVIL_DIR"
  teardown
}

test_render_unsafe_doc_skipped() {
  echo "test: render — a doc outside the work tree is skipped, never written"
  claims_fixture
  evil_outside
  evil_sidecar "$EVIL_REL"
  local h
  assert_file_exists "$EVIL_REL" "precondition: the outside file is reachable at the sidecar's doc path"
  h=$(hash_file "$EVIL_DIR/SPEC-EVIL-001-x.md")
  cl render
  assert_eq "0" "$CL_RC" "render exits 0"
  assert_json_field "$CL_OUT" "[.results[] | select(.doc == \"$EVIL_REL\")] | tojson" \
    "[{\"doc\":\"$EVIL_REL\",\"skipped\":\"unsafe path\"}]" "…reports skipped: unsafe path"
  assert_eq "$h" "$(hash_file "$EVIL_DIR/SPEC-EVIL-001-x.md")" "…and the outside file is byte-identical"
  cl render --check
  assert_eq "0" "$CL_RC" "render --check exits 0"
  assert_eq "0" "$(v11_count)" "…with no V11 finding"
  rm -rf "$EVIL_DIR"
  teardown
}

test_v11_inline_markers_are_text() {
  echo "test: V11 — a status marker counts only as a whole line"
  claims_fixture
  # Both markers quoted inline, on one line, in a doc never rendered.
  strip_block "$DOC"
  local prose
  prose="The block sits between \`$BLOCK_BEGIN\` and \`$BLOCK_END\` lines."
  doc_edit "$DOC" "How long issued tokens stay valid." "$prose" after
  cl render
  assert_eq "0" "$CL_RC" "render exits 0"
  assert_json_field "$CL_OUT" '.results[0].changed' "true" "…a fresh block is inserted"
  assert_eq "$BLOCK_END" "$(line_before "$DOC" "## Requirements")" "…before ## Requirements"
  assert_eq "1" "$(L="$prose" awk '$0 == ENVIRON["L"] { n++ } END { print n + 0 }' "$DOC")" \
    "…and the prose line is untouched"
  teardown
  # One marker quoted inline in a rendered doc: no V11, and V2 reads the
  # sentence as live.
  claims_fixture
  doc_edit "$DOC" "How long issued tokens stay valid." \
    "Tokens list their claims after \`$BLOCK_BEGIN\` here." after
  jset "$SIDECAR" '.claims += [.claims[0] | .id = "SPEC-AUTH-001#inline-marker"
    | .quote = "Tokens list their claims after <!-- spec-claims:status:begin --> here"]'
  rerender
  cl validate --all
  assert_eq "0" "$CL_RC" "one marker quoted inline: validate --all exits 0"
  assert_eq "0" "$(v11_count)" "…no V11 finding"
  assert_eq "0" "$(v2_count)" "…and the sentence holding the marker text is live (no V2)"
  teardown
}

test_v11_malformed_markers() {
  echo "test: V11 — end before begin, or two pairs: a finding, the doc never written"
  claims_fixture
  local h
  # End before begin: the fixture block's markers swapped.
  doc_edit "$DOC" "$BLOCK_BEGIN" "@@BEGIN@@"
  doc_edit "$DOC" "$BLOCK_END" "$BLOCK_BEGIN"
  doc_edit "$DOC" "@@BEGIN@@" "$BLOCK_END"
  h=$(hash_file "$DOC")
  cl render --check
  assert_eq "1" "$CL_RC" "end before begin: render --check exits 1"
  assert_contains "$(v11_messages)" "not one begin/end pair" "…a V11 finding"
  assert_json_field "$CL_OUT" '.results[0].changed' "null" "…its result's changed is null"
  cl render
  assert_eq "1" "$CL_RC" "end before begin: render exits 1"
  assert_eq "$h" "$(hash_file "$DOC")" "…and never writes the doc"
  # Two pairs: the fixture block, and a copy of it before ## Implementation Notes.
  git checkout -q -- "$DOC"
  doc_edit "$DOC" "## Implementation Notes" "$BLOCK_BEGIN"$'\n'"$BLOCK_END"$'\n'"## Implementation Notes"
  h=$(hash_file "$DOC")
  cl validate --all
  assert_eq "1" "$CL_RC" "two pairs: validate --all exits 1"
  assert_contains "$(v11_messages)" "not one begin/end pair" "…a V11 finding"
  cl render
  assert_eq "1" "$CL_RC" "two pairs: render exits 1"
  assert_eq "$h" "$(hash_file "$DOC")" "…and never writes the doc"
  teardown
}

test_render_base_unused() {
  echo "test: render — the base is never read, so an unresolvable one is not indeterminate"
  claims_fixture
  cl render --base no-such-ref
  assert_eq "0" "$CL_RC" "render --base no-such-ref exits 0"
  assert_json_field "$CL_OUT" '.indeterminate | tojson' "[]" "…with nothing indeterminate"
  cl render --check --base no-such-ref
  assert_eq "0" "$CL_RC" "render --check --base no-such-ref exits 0 on a clean tree"
  cl validate --all --base no-such-ref
  assert_eq "2" "$CL_RC" "precondition: validate (which ratchets) still exits 2"
  teardown
}

# assert_symlink_doc_refused <doc> <outside-file> <what>: the SPEC-SYM-001
# sidecar naming <doc> (which reaches <outside-file> through a link) is V1
# under --all, render skips it as an unsafe path and leaves <outside-file>
# byte-identical, and render --check raises no V11 for it.
assert_symlink_doc_refused() {
  local h
  evil_sidecar "$1" SPEC-SYM-001
  assert_file_exists "$1" "$3: precondition: the outside file is reachable at the doc path"
  h=$(hash_file "$2")
  cl validate --all
  assert_v1 "not a safe repo path" "$3: --all"
  assert_contains "$(v1_messages)" "docs/spec-claims/SPEC-SYM-001.json: doc $1" "$3: …naming the sidecar and the path"
  assert_eq "0" "$(v2_count)" "$3: …no V2 (never read)"
  cl render
  assert_eq "0" "$CL_RC" "$3: render exits 0"
  assert_json_field "$CL_OUT" "[.results[] | select(.doc == \"$1\")] | tojson" \
    "[{\"doc\":\"$1\",\"skipped\":\"unsafe path\"}]" "$3: …reports skipped: unsafe path"
  assert_eq "$h" "$(hash_file "$2")" "$3: …and the outside file is byte-identical"
  cl render --check
  assert_eq "0" "$(v11_count)" "$3: render --check raises no V11"
}

test_unsafe_symlinked_dir() {
  echo "test: a doc reached through a committed symlinked directory is unsafe, never written"
  claims_fixture
  local out
  out=$(mktemp -d "$SUITE_TMP/symout.XXXXXX")
  printf '# SPEC-SYM-001\n\n## Summary\n\nEvil sentence.\n\n## Requirements\n\nNone.\n' > "$out/SPEC-SYM-001-x.md"
  ln -s "$out" docs/specs/sym
  git add docs/specs/sym && git commit -qm "a symlinked directory"
  assert_symlink_doc_refused docs/specs/sym/SPEC-SYM-001-x.md "$out/SPEC-SYM-001-x.md" "symlinked directory"
  # The index stores the link as a blob: through it the doc is simply absent.
  git add docs/spec-claims/SPEC-SYM-001.json
  cl validate --staged
  assert_eq "1" "$CL_RC" "--staged: exits 1 (a finding, not an error)"
  assert_contains "$(v1_messages)" "docs/specs/sym/SPEC-SYM-001-x.md is missing" "…the doc is missing in the index"
  rm -rf "$out"
  teardown
}

test_unsafe_symlinked_file() {
  echo "test: a doc that is itself a symlink is unsafe, never written"
  claims_fixture
  local out
  out=$(mktemp -d "$SUITE_TMP/symout.XXXXXX")
  printf '# SPEC-SYM-001\n\n## Summary\n\nEvil sentence.\n\n## Requirements\n\nNone.\n' > "$out/SPEC-SYM-001-x.md"
  ln -s "$out/SPEC-SYM-001-x.md" docs/specs/SPEC-SYM-001-x.md
  assert_symlink_doc_refused docs/specs/SPEC-SYM-001-x.md "$out/SPEC-SYM-001-x.md" "symlinked file"
  rm -rf "$out"
  teardown
}

test_v11_indented_markers() {
  echo "test: V11 — indented status markers (up to 3 spaces, trailing blanks) are markers"
  claims_fixture
  doc_edit "$DOC" "$BLOCK_BEGIN" "  $BLOCK_BEGIN"
  doc_edit "$DOC" "$BLOCK_END" "   $BLOCK_END"$'\t '
  # The quote copied into the indented block: blanked, so V2 sees one occurrence.
  doc_edit "$DOC" "## Claim status" $'\nAccess tokens expire after 15 minutes.' after
  cl validate --all
  assert_eq "0" "$(v2_count)" "the quote inside the indented block: no V2 (the block is blanked)"
  assert_json_field "$CL_OUT" '[.findings[].check] | unique | tojson' '["V11"]' "…the hand edit is V11's finding alone"
  cl render
  assert_eq "0" "$CL_RC" "render exits 0"
  assert_eq "1" "$(grep -c "spec-claims:status:begin" "$DOC")" "…replaces the block in place, no duplicate"
  assert_true "…restoring the rendered fixture byte for byte" git diff --quiet -- "$DOC"
  # Four spaces is an indented code block, not a marker: text.
  doc_edit "$DOC" "$BLOCK_BEGIN" "    $BLOCK_BEGIN"
  cl render --check
  assert_contains "$(v11_messages)" "not one begin/end pair" "a 4-space-indented begin marker is not a marker"
  teardown
}

# --- Runner adapters and claims run --------------------------------------------
#
# stub_runner makes the fixture runnable: a /bin/sh stub runner adapter in
# tools/claims/runner (committed with the fixture, as a host's adapter is),
# config runners.stub, and the fixture claim bound to the stub's node. The
# stub's behaviour is data in tools/claims/ (see the script), and every call
# it gets is logged to $STUB_LOG, outside the work tree.

STUB_NODE="tests/test_token.py::test_ttl"
STUB_TEST="{\"runner\":\"stub\",\"node\":\"$STUB_NODE\"}"

# The stub runner adapter (§D contract, /bin/sh; interpreter-neutral):
#   list                  cats list.jsonl
#   run [--root <dir>] <node>…  per node: the force line (node<TAB>outcome
#                         [<TAB>reason]) when there is one, else checks
#                         (node<TAB>file<TAB>needle): pass when <dir>/<file>
#                         holds needle (grep -F), assert-fail when the file
#                         lacks it, error when the file is missing or holds
#                         the text STUB_ERROR; a node in
#                         neither file is not-found. A force outcome "noise"
#                         prints its reason raw on stdout, then the node's
#                         checks outcome. STUB_CAT=<path> first appends
#                         the bytes of <dir>/<path> to $STUB_LOG.cat (what
#                         the adapter saw under that root). STUB_BG=1 first starts
#                         `sleep 30 >/dev/null 2>&1 &` (every other fd
#                         inherited) and writes its pid to $STUB_LOG.bgpid.
#   edited-bound-tests    cats edited
# Every call appends its subcommand, its arguments (one per line) and the
# stdin it read to $STUB_LOG; STUB_EXIT=<n> makes it exit n after printing.
# shellcheck disable=SC2016  # the stub's own expansions
STUB_RUNNER_SH='#!/bin/sh
dir=$(cd "$(dirname "$0")" && pwd)
log=${STUB_LOG:-/dev/null}
sub=${1:-}
[ $# -eq 0 ] || shift
{
  printf "%s\n" "$sub"
  for a in "$@"; do printf "%s\n" "$a"; done
  cat
} >> "$log"
lookup() {
  N="$1" awk -F "	" "\$1 == ENVIRON[\"N\"] { print \$2 \"	\" \$3; exit }" "$2" 2>/dev/null
}
jstr() {
  printf "\"%s\"" "$(printf "%s" "$1" | sed "s/[\\\\\"]/\\\\&/g")"
}
case $sub in
  list) cat "$dir/list.jsonl" ;;
  edited-bound-tests) cat "$dir/edited" ;;
  run)
    root=.
    if [ "${1:-}" = --root ]; then root=$2; shift 2; fi
    if [ -n "${STUB_CAT:-}" ]; then cat "$root/$STUB_CAT" >> "$log.cat"; fi
    if [ "${STUB_BG:-}" = 1 ]; then
      sleep 30 >/dev/null 2>&1 &
      echo $! > "$log.bgpid"
    fi
    for node in "$@"; do
      forced=$(lookup "$node" "$dir/force")
      outcome=${forced%%"	"*}
      reason=${forced#*"	"}
      if [ "$outcome" = noise ]; then
        printf "%s\n" "$reason"
        forced=""
      fi
      if [ -z "$forced" ]; then
        reason=""
        check=$(lookup "$node" "$dir/checks")
        if [ -z "$check" ]; then
          outcome=not-found
        else
          file=${check%%"	"*}
          needle=${check#*"	"}
          if [ ! -f "$root/$file" ] || grep -qF STUB_ERROR "$root/$file"; then outcome=error
          elif grep -qF -- "$needle" "$root/$file"; then outcome=pass
          else outcome=assert-fail; fi
        fi
      fi
      if [ -n "$reason" ]; then r=$(jstr "$reason"); else r=null; fi
      printf "{\"node\":%s,\"outcome\":\"%s\",\"reason\":%s}\n" "$(jstr "$node")" "$outcome" "$r"
    done
    ;;
esac
exit "${STUB_EXIT:-0}"
'

# The stub log adapter: `run <claim-id>` prints {"outcome":
# $STUB_LOG_OUTCOME (default pass), "evidence"}; logging, STUB_BG and
# STUB_EXIT as the runner's (its log lines start with "log").
# shellcheck disable=SC2016  # the stub's own expansions
STUB_LOG_SH='#!/bin/sh
log=${STUB_LOG:-/dev/null}
{
  printf "log %s\n" "${1:-}"
  [ $# -eq 0 ] || shift
  for a in "$@"; do printf "%s\n" "$a"; done
  cat
} >> "$log"
if [ "${STUB_BG:-}" = 1 ]; then
  sleep 30 >/dev/null 2>&1 &
  echo $! > "$log.bgpid"
fi
printf "{\"outcome\":\"%s\",\"evidence\":\"stub evidence\"}\n" "${STUB_LOG_OUTCOME:-pass}"
exit "${STUB_EXIT:-0}"
'

# write_stub <path> <script>: an executable stub (mode 755).
write_stub() {
  mkdir -p "$(dirname "$1")"
  printf '%s' "$2" > "$1"
  chmod 755 "$1"
}

# stub_install: the stub runner adapter and its data files in tools/claims/
# (list.jsonl empty, checks holding STUB_NODE's), not committed; STUB_LOG a
# fresh harness_mktemp file.
stub_install() {
  write_stub tools/claims/runner "$STUB_RUNNER_SH"
  : > tools/claims/list.jsonl
  : > tools/claims/force
  : > tools/claims/edited
  printf '%s\t%s\t%s\n' "$STUB_NODE" src/auth/token.py "TTL_SECONDS = 900" > tools/claims/checks
  STUB_LOG=$(harness_mktemp stub-log)
  export STUB_LOG
}

# stub_runner: the fixture made runnable through the stub (see above), all
# committed. Its list reports nothing yet (list_row binds a node).
stub_runner() {
  stub_install
  jset docs/spec-claims/config.json '.runners.stub = {"adapter": "tools/claims/runner", "paths": ["src/", "tests/"]}'
  jset "$SIDECAR" ".claims[0].test = $STUB_TEST"
  git add -A && git commit -qm "stub runner"
}

# list_row <id> <node> [<in_gate> [<subject_imports_ok>]]: the stub's list
# reports a test at <node> binding itself to <id> (§D's row; both flags
# default to true, when is null).
list_row() {
  jq -nc --arg id "$1" --arg node "$2" --argjson g "${3:-true}" --argjson s "${4:-true}" \
    '{id: $id, node: $node, file: ($node | split("::")[0]), in_gate: $g, subject_imports_ok: $s, when: null}' \
    >> tools/claims/list.jsonl
}

# bind_test <test-json>: the fixture claim bound to <test-json> ({runner,
# node}) as a host test binds itself, so V3 holds: the stub installed
# (stub_install) when the fixture has none, config runners.<runner> naming it
# unless the config already names that runner, a list.jsonl row binding the
# node to the claim, and the claim's test set. Nothing is committed. The
# shared helper every earlier test with a bound test claim goes through (R3).
bind_test() {
  local runner node
  runner=$(jq -r '.runner' <<<"$1")
  node=$(jq -r '.node' <<<"$1")
  [ -x tools/claims/runner ] || stub_install
  jset docs/spec-claims/config.json \
    ".runners[\"$runner\"] //= {\"adapter\": \"tools/claims/runner\", \"paths\": [\"src/\", \"tests/\"]}"
  list_row "$(jq -r '.claims[0].id' "$SIDECAR")" "$node"
  jset "$SIDECAR" ".claims[0].test = $1"
}

# stub_log_adapter: config log_adapter → the stub log adapter, committed.
stub_log_adapter() {
  write_stub tools/claims/log "$STUB_LOG_SH"
  jset docs/spec-claims/config.json '.log_adapter = "tools/claims/log"'
  git add -A && git commit -qm "stub log adapter"
}

# add_claim <json>: append a claim record to the fixture sidecar.
add_claim() {
  jset "$SIDECAR" ".claims += [$1]"
}

# A second unbuilt claim of the fixture doc (the refresh sentence), bound to
# <runner> <node>.
refresh_claim() {
  jq -nc --arg r "$1" --arg n "$2" '{
    id: "SPEC-AUTH-001#refresh-single-use", quote: "Refresh tokens are single-use",
    states: "A refresh token is rejected on its second use.", kind: "behaviour",
    subject: ["src/auth/token.py"], status: "unbuilt", enforced_by: "test",
    test: {runner: $r, node: $n}, nonvacuity: null, promotion: null,
    tracker: "docs/issues/token-ttl.md", frozen_at: null, restates: [], rulings: []}'
}

# force <node> <outcome> [<reason>]: the stub reports <outcome> for <node>.
force() {
  if [ $# -ge 3 ]; then
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> tools/claims/force
  else
    printf '%s\t%s\n' "$1" "$2" >> tools/claims/force
  fi
}

# set_ttl <seconds>: the subject's TTL.
set_ttl() {
  printf 'TTL_SECONDS = %s\n' "$1" > src/auth/token.py
}

# run_built: the fixture claim made built (with its verdict) on the stub.
run_built() {
  local _CL_TEST="$STUB_TEST"
  hand_promote
}

# run_diverged: the fixture claim made diverged (tracker open, ruling) on the stub.
run_diverged() {
  diverge_claim "$STUB_TEST"
}

# The stub's run calls in $STUB_LOG: the number of "run" lines.
stub_run_calls() {
  grep -c '^run$' "$STUB_LOG" || true
}

# The fixture claim's result field <f> in the last `cl`.
run_field() {
  jq -r --arg f "$1" '[.results[] | select(.claim == "SPEC-AUTH-001#token-ttl")][0][$f]' <<<"$CL_OUT" 2>/dev/null
}

test_run_built_pass_exit_0() {
  echo "test: run — a built claim whose check passes is ok"
  claims_fixture
  stub_runner
  run_built
  cl run --all
  assert_eq "0" "$CL_RC" "built, check passes: run --all exits 0"
  assert_eq "1" "$(json_count "$CL_OUT")" "…one verdict object"
  assert_json_field "$CL_OUT" '.verb' "run" "…verb run"
  assert_eq "ok" "$(run_field verdict)" "…verdict ok"
  assert_eq "pass" "$(run_field outcome)" "…outcome pass"
  assert_eq "built" "$(run_field status)" "…status built"
  assert_eq "$STUB_NODE" "$(run_field node)" "…the bound node"
  assert_json_field "$CL_OUT" '.results[0] | keys | sort | tojson' \
    '["claim","message","node","outcome","status","verdict"]' "…a result row is {claim, status, node, outcome, verdict, message}"
  assert_eq "1" "$(stub_run_calls)" "…one run call for the runner"
  assert_contains "$(cat "$STUB_LOG")" "--root"$'\n'"$(git rev-parse --show-toplevel)" "…with --root <the work tree>"
  teardown
}

test_run_built_assert_fail_exit_1() {
  echo "test: run — a built claim whose check fails is a finding"
  claims_fixture
  stub_runner
  run_built
  set_ttl 1800
  cl run --all
  assert_eq "1" "$CL_RC" "built, source → 1800: exits 1"
  assert_eq "finding" "$(run_field verdict)" "…verdict finding"
  assert_eq "assert-fail" "$(run_field outcome)" "…outcome assert-fail"
  assert_json_field "$CL_OUT" '.findings[0].claim' "SPEC-AUTH-001#token-ttl" "…the finding names the claim"
  assert_json_field "$CL_OUT" '.findings[0].doc' "$DOC" "…and its doc"
  teardown
}

test_run_diverged_assert_fail_expected_exit_0() {
  echo "test: run — a diverged claim's assertion failure is its expected red"
  claims_fixture
  stub_runner
  run_diverged
  set_ttl 1800
  cl run --all
  assert_eq "0" "$CL_RC" "diverged, source → 1800: exits 0"
  assert_eq "ok" "$(run_field verdict)" "…verdict ok"
  assert_eq "assert-fail" "$(run_field outcome)" "…outcome assert-fail"
  teardown
}

test_run_diverged_pass_is_finding_promote() {
  echo "test: run — a diverged claim that passes is a finding: promote"
  claims_fixture
  stub_runner
  run_diverged
  cl run --all
  assert_eq "1" "$CL_RC" "diverged, source 900: exits 1"
  assert_eq "finding" "$(run_field verdict)" "…verdict finding"
  assert_contains "$(run_field message)" "promote" "…the message says promote"
  assert_json_field "$CL_OUT" '.findings[0].message | test("^passes: promote")' "true" "…the finding says 'passes: promote'"
  teardown
}

test_run_diverged_error_is_finding() {
  echo "test: run — a diverged claim's error is not an expected red"
  claims_fixture
  stub_runner
  run_diverged
  rm src/auth/token.py
  cl run --all
  assert_eq "1" "$CL_RC" "diverged, subject deleted (error): exits 1"
  assert_eq "error" "$(run_field outcome)" "…outcome error"
  assert_contains "$(run_field message)" "error is not an expected red" "…the message"
  teardown
}

test_run_unbuilt_any_failure_ok() {
  echo "test: run — an unbuilt claim may fail any way"
  claims_fixture
  stub_runner
  local o
  for o in error not-found assert-fail; do
    : > tools/claims/force
    force "$STUB_NODE" "$o"
    cl run --all
    assert_eq "0" "$CL_RC" "unbuilt, forced $o: exits 0"
    assert_eq "ok" "$(run_field verdict)" "…verdict ok ($o)"
  done
  teardown
}

test_run_unbuilt_pass_is_finding() {
  echo "test: run — an unbuilt claim that passes is a finding"
  claims_fixture
  stub_runner
  cl run --all
  assert_eq "1" "$CL_RC" "unbuilt, source 900 (pass): exits 1"
  assert_contains "$(run_field message)" "promote" "…the message says promote"
  teardown
}

test_run_unbuilt_no_check_yet() {
  echo "test: run — an unbuilt claim with test null is not run"
  claims_fixture
  stub_runner
  jset "$SIDECAR" '.claims[0].test = null'
  cl run --all
  assert_eq "0" "$CL_RC" "unbuilt, test null: exits 0"
  assert_eq "ok" "$(run_field verdict)" "…verdict ok"
  assert_eq "no check yet" "$(run_field message)" "…message 'no check yet'"
  assert_eq "null" "$(run_field outcome)" "…no outcome"
  assert_eq "0" "$(stub_run_calls)" "…the adapter was not called"
  teardown
}

test_run_indeterminate_exit_2() {
  echo "test: run — an indeterminate outcome exits 2"
  claims_fixture
  stub_runner
  force "$STUB_NODE" indeterminate env-missing
  cl run --all
  assert_eq "2" "$CL_RC" "forced indeterminate: exits 2"
  assert_json_field "$CL_OUT" '.indeterminate[0].reason' "env-missing" ".indeterminate[0].reason is the adapter's"
  assert_json_field "$CL_OUT" '.indeterminate[0].claim' "SPEC-AUTH-001#token-ttl" "…naming the claim"
  assert_eq "indeterminate" "$(run_field verdict)" "…verdict indeterminate"
  assert_json_field "$CL_OUT" '.findings' "[]" "…never a finding"
  teardown
}

test_run_adapter_nonzero_all_indeterminate() {
  echo "test: run — a non-zero adapter exit makes every requested node indeterminate"
  claims_fixture
  stub_runner
  add_claim "$(refresh_claim stub tests/test_token.py::test_refresh)"
  STUB_EXIT=3 cl run --all
  assert_eq "2" "$CL_RC" "STUB_EXIT=3: exits 2"
  assert_json_field "$CL_OUT" '[.results[].verdict] | tojson' '["indeterminate","indeterminate"]' "…both claims indeterminate"
  assert_json_field "$CL_OUT" '[.indeterminate[].reason] | unique | tojson' '["adapter-exit-3"]' "…reason adapter-exit-3"
  assert_json_field "$CL_OUT" '.indeterminate | length' "2" "…one row per claim"
  assert_eq "1" "$(stub_run_calls)" "…one run call for both nodes"
  teardown
}

test_run_precedence_finding_beats_indeterminate() {
  echo "test: run — a finding beats an indeterminate (exit 1)"
  claims_fixture
  stub_runner
  add_claim "$(refresh_claim stub tests/test_token.py::test_refresh)"
  run_built
  force tests/test_token.py::test_refresh indeterminate env-missing
  set_ttl 1800
  cl run --all
  assert_eq "1" "$CL_RC" "one red claim, one indeterminate: exits 1"
  assert_json_field "$CL_OUT" '.indeterminate | length' "1" "…the indeterminate is still reported"
  assert_json_field "$CL_OUT" '.findings | length' "1" "…beside the finding"
  teardown
}

test_run_adapter_malformed_json_indeterminate() {
  echo "test: run — noise on the adapter's stdout is indeterminate, never a pass"
  claims_fixture
  stub_runner
  run_built
  force "$STUB_NODE" noise oops
  cl run --all
  assert_eq "2" "$CL_RC" "'oops' before the JSON: exits 2"
  assert_json_field "$CL_OUT" '.indeterminate[0].reason' "malformed-adapter-output" "…reason malformed-adapter-output"
  assert_eq "indeterminate" "$(run_field verdict)" "…never the pass the JSON line reported"
  # A missing outcome, an unknown outcome, a non-object line: the same.
  local bad
  for bad in '{"node":"'"$STUB_NODE"'"}' '{"node":"'"$STUB_NODE"'","outcome":"green"}' '[1]' 'null'; do
    : > tools/claims/force
    force "$STUB_NODE" noise "$bad"
    cl run --all
    assert_eq "2" "$CL_RC" "stdout line $bad: exits 2"
    assert_json_field "$CL_OUT" '.indeterminate[0].reason' "malformed-adapter-output" "…$bad: malformed-adapter-output"
  done
  # A requested node the adapter does not report.
  write_stub tools/claims/runner '#!/bin/sh
cat > /dev/null
printf "{\"node\":\"tests/test_token.py::test_other\",\"outcome\":\"pass\",\"reason\":null}\n"
'
  cl run --all
  assert_eq "2" "$CL_RC" "a requested node missing from the output: exits 2"
  assert_json_field "$CL_OUT" '.indeterminate[0].reason' "malformed-adapter-output" "…malformed-adapter-output"
  teardown
}

test_run_frozen_skipped() {
  echo "test: run — retired, frozen and judge claims are skipped, the adapter not called"
  claims_fixture
  stub_runner
  jset "$SIDECAR" ".claims[0].frozen_at = \"$(git rev-parse HEAD)\""
  cl run --all
  assert_eq "0" "$CL_RC" "frozen: exits 0"
  assert_eq "skipped" "$(run_field verdict)" "…result skipped"
  assert_eq "frozen" "$(run_field message)" "…reason frozen"
  assert_eq "" "$(cat "$STUB_LOG")" "…the adapter was not called (\$STUB_LOG empty)"
  jset "$SIDECAR" '.claims[0].frozen_at = null | .claims[0].status = "retired"'
  cl run --all
  assert_eq "retired" "$(run_field message)" "retired: skipped, reason retired"
  jset "$SIDECAR" '.claims[0].status = "unbuilt" | .claims[0].enforced_by = "judge"'
  cl run --all
  assert_eq "judge" "$(run_field message)" "judge: skipped, reason judge"
  assert_eq "" "$(cat "$STUB_LOG")" "…the adapter never called"
  teardown
}

test_run_planes_of_selects_runner_by_paths() {
  echo "test: run --planes-of — every claim of each runner whose paths the range touched"
  claims_fixture
  stub_runner
  write_stub tools/claims/docs-runner "$STUB_RUNNER_SH"
  jset docs/spec-claims/config.json '.runners.docs = {"adapter": "tools/claims/docs-runner", "paths": ["docs/"]}'
  add_claim "$(refresh_claim docs docs/checks.md::refresh)"
  git add -A && git commit -qm "a docs runner"
  set_ttl 901
  git add -A && git commit -qm "a source change"
  cl run --planes-of HEAD~1..HEAD
  assert_eq "0" "$CL_RC" "a src/ change: exits 0 (the stub claim is unbuilt, its assert-fail ok)"
  assert_json_field "$CL_OUT" '[.results[].claim] | tojson' '["SPEC-AUTH-001#token-ttl"]' "…only the stub runner's claim"
  assert_not_contains "$(cat "$STUB_LOG")" "docs/checks.md::refresh" "…the docs runner was not called"
  # A docs change selects the docs runner alone; a glob entry matches too.
  : > "$STUB_LOG"
  jset docs/spec-claims/config.json '.runners.docs.paths = ["docs/*.md"]'
  echo "x" >> docs/architecture.md
  git add -A && git commit -qm "a docs change"
  cl run --planes-of HEAD~1..HEAD
  assert_json_field "$CL_OUT" '[.results[].claim] | tojson' '["SPEC-AUTH-001#refresh-single-use"]' "a docs/*.md change: only the docs runner's claim"
  assert_not_contains "$(cat "$STUB_LOG")" "$STUB_NODE" "…the stub runner was not called"
  # Nothing touched: nothing runs.
  cl run --planes-of HEAD..HEAD
  assert_eq "0" "$CL_RC" "an empty range: exits 0"
  assert_json_field "$CL_OUT" '.results' "[]" "…no result"
  cl run --planes-of nope..HEAD
  assert_eq "2" "$CL_RC" "an unresolvable range: exits 2"
  teardown
}

test_run_log_claims_only_scheduled() {
  echo "test: run — log claims run only with --scheduled, through the log adapter"
  claims_fixture
  stub_runner
  stub_log_adapter
  jset "$SIDECAR" '.claims[0].enforced_by = "log" | .claims[0].test = null | .claims[0].status = "built"'
  cl run --all
  assert_eq "0" "$CL_RC" "without --scheduled: exits 0"
  assert_eq "skipped" "$(run_field verdict)" "…the log claim is skipped"
  assert_eq "" "$(cat "$STUB_LOG")" "…the log adapter was not called"
  cl run --all --scheduled
  assert_eq "0" "$CL_RC" "with --scheduled: exits 0 (built, the log check passes)"
  assert_eq "ok" "$(run_field verdict)" "…verdict ok"
  assert_eq "null" "$(run_field node)" "…no node"
  assert_eq "log run"$'\n'"SPEC-AUTH-001#token-ttl" "$(cat "$STUB_LOG")" "…the log adapter got run <claim-id>"
  STUB_LOG_OUTCOME=fail cl run --all --scheduled
  assert_eq "1" "$CL_RC" "a failing log check on a built claim: exits 1"
  assert_eq "fail" "$(run_field outcome)" "…the row keeps the log adapter's own outcome word"
  assert_eq "finding" "$(run_field verdict)" "…judged as an assertion failure (a finding)"
  STUB_LOG_OUTCOME=indeterminate cl run --all --scheduled
  assert_eq "2" "$CL_RC" "an indeterminate log check: exits 2"
  jset docs/spec-claims/config.json '.log_adapter = null'
  cl run --all --scheduled
  assert_eq "2" "$CL_RC" "no log adapter configured: exits 2"
  assert_json_field "$CL_OUT" '.indeterminate[0].reason' "adapter-exit-126" "…reason adapter-exit-126"
  teardown
}

test_run_judge_sample_rotates() {
  echo "test: run --judge-sample — n judge ids, rotated by ISO week"
  claims_fixture
  stub_runner
  local s
  for s in c a b; do
    add_claim "$(jq -nc --arg s "$s" '{id: ("SPEC-AUTH-001#judge-" + $s), quote: "Refresh tokens are single-use",
      states: "Reviewed by a person.", kind: "behaviour", subject: ["src/auth/token.py"], status: "unbuilt",
      enforced_by: "judge", why_not_mechanical: "a person reads it", test: null, nonvacuity: null, promotion: null,
      tracker: "docs/issues/token-ttl.md", frozen_at: null, restates: [], rulings: []}')"
  done
  local week ids want
  week=$(date +%V)
  ids='["SPEC-AUTH-001#judge-a","SPEC-AUTH-001#judge-b","SPEC-AUTH-001#judge-c"]'
  want=$(jq -r --argjson w "$((10#$week))" '.[$w % 3]' <<<"$ids")
  cl run --all --judge-sample 1
  assert_json_field "$CL_OUT" '.judge_sample | length' "1" "--judge-sample 1: one id"
  assert_json_field "$CL_OUT" '.judge_sample[0]' "$want" "…the id at (ISO week $week) mod 3, sorted by id"
  cl run --all --judge-sample 3
  assert_json_field "$CL_OUT" '.judge_sample | sort | tojson' "$ids" "--judge-sample 3: every judge claim"
  assert_json_field "$CL_OUT" '.judge_sample[0]' "$want" "…starting at the week's index"
  cl run --all
  assert_json_field "$CL_OUT" 'has("judge_sample")' "false" "without --judge-sample: no judge_sample"
  cl run --all --judge-sample x
  assert_eq "3" "$CL_RC" "--judge-sample x: usage, exits 3"
  teardown
}

test_run_node_with_spaces() {
  echo "test: run — a node with spaces reaches the adapter as one argument"
  claims_fixture
  stub_runner
  run_built
  printf 'TTL_SECONDS = 900\n' > "src/a b.py"
  printf '%s\t%s\t%s\n' "tests/a b.py::t" "src/a b.py" "TTL_SECONDS = 900" >> tools/claims/checks
  jset "$SIDECAR" '.claims[0].test.node = "tests/a b.py::t"'
  cl run --all
  assert_eq "0" "$CL_RC" "node 'tests/a b.py::t': exits 0 (pass)"
  assert_contains "$(cat "$STUB_LOG")" $'\n'"tests/a b.py::t"$'\n' "…\$STUB_LOG shows the node as one argument"
  assert_eq "tests/a b.py::t" "$(run_field node)" "…the result names it intact"
  teardown
}

# assert_returns_promptly <what> <args…>: `doc-tools.sh claims <args>`,
# captured by a plain $(…) pipe as a hook does, returns in under 10 s while
# the adapter's background child (STUB_BG=1) still runs; then kills it.
assert_returns_promptly() {
  local what="$1" start took pid out
  shift
  rm -f "$STUB_LOG.bgpid"
  start=$SECONDS
  out=$(STUB_BG=1 "$DOC_TOOLS" claims "$@" 2>/dev/null </dev/null) || true
  took=$((SECONDS - start))
  pid=$(cat "$STUB_LOG.bgpid" 2>/dev/null || true)
  assert_true "$what: the adapter started its background child" test -n "$pid"
  assert_true "$what: \$(…) returned in under 10 s (took ${took}s)" test "$took" -lt 10
  assert_eq "1" "$(json_count "$out")" "$what: one verdict object"
  if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi
}

test_adapter_child_does_not_hold_stdout() {
  echo "test: run — an adapter's background child never holds the caller's stdout (fd 9 closed)"
  claims_fixture
  stub_runner
  assert_returns_promptly "runner adapter" run --all
  stub_log_adapter
  jset "$SIDECAR" '.claims[0].enforced_by = "log" | .claims[0].test = null'
  assert_returns_promptly "log adapter" run --all --scheduled
  teardown
}

test_adapter_stdin_is_dev_null() {
  echo "test: run — the adapter's stdin is /dev/null, never the caller's"
  claims_fixture
  stub_runner
  # Not `cl` (it closes stdin itself): a hook's ref lines on doc-tools' stdin.
  local out
  out=$(printf 'ref-line\n' | "$DOC_TOOLS" claims run --all 2>/dev/null) || true
  assert_eq "1" "$(json_count "$out")" "one verdict object"
  assert_eq "1" "$(stub_run_calls)" "the adapter ran"
  assert_not_contains "$(cat "$STUB_LOG")" "ref-line" "\$STUB_LOG records no stdin bytes"
  teardown
}

test_run_unknown_runner_indeterminate() {
  echo "test: run — a test.runner not in config runners is a missing adapter (indeterminate)"
  claims_fixture
  stub_runner
  jset "$SIDECAR" '.claims[0].test.runner = "nosuch"'
  cl run --all
  assert_eq "2" "$CL_RC" "an unknown runner: exits 2"
  assert_json_field "$CL_OUT" '.indeterminate[0].reason' "adapter-exit-126" "…reason adapter-exit-126"
  # A configured adapter that is not executable: the same.
  jset "$SIDECAR" '.claims[0].test.runner = "stub"'
  chmod 644 tools/claims/runner
  cl run --all
  assert_eq "2" "$CL_RC" "a non-executable adapter: exits 2"
  assert_json_field "$CL_OUT" '.indeterminate[0].reason' "adapter-exit-126" "…reason adapter-exit-126"
  assert_eq "" "$(cat "$STUB_LOG")" "…nothing ran"
  teardown
}

test_run_unsafe_adapter_path_indeterminate() {
  echo "test: run — an adapter path outside the work tree is a missing adapter, never run"
  claims_fixture
  stub_runner
  local out rel
  out=$(harness_mktemp_d outside-adapter)
  printf '#!/bin/sh\ntouch "%s/ran"\nexit 0\n' "$out" > "$out/runner"
  chmod 755 "$out/runner"
  # Through "..": the safe-path guard.
  # tools/claims/../../.. is the fixture's parent, where $out lives.
  rel="tools/claims/../../../$(basename "$out")/runner"
  jset docs/spec-claims/config.json ".runners.stub.adapter = \"$rel\""
  cl run --all
  assert_eq "2" "$CL_RC" "an adapter path with .. segments: exits 2"
  assert_json_field "$CL_OUT" '.indeterminate[0].reason' "adapter-exit-126" "…reason adapter-exit-126"
  # Through a symbolic link: the containment guard.
  ln -s "$out" tools/outside
  jset docs/spec-claims/config.json '.runners.stub.adapter = "tools/outside/runner"'
  cl run --all
  assert_eq "2" "$CL_RC" "an adapter reached through a symlinked directory: exits 2"
  assert_json_field "$CL_OUT" '.indeterminate[0].reason' "adapter-exit-126" "…reason adapter-exit-126"
  assert_file_not_exists "$out/ran" "…the outside adapter never ran"
  teardown
}

# The parse helpers never default the adapter's exit code: called without
# one (or with a non-integer one) they die, exit 2. Reached through a probe
# copy of doc-tools.sh (claims_probe) that calls the helper after init.
test_parse_helpers_require_rc() {
  echo "test: _claims_parse_run / _claims_parse_log without an rc die (exit 2), never default to 0"
  claims_fixture
  local line probe rc out
  for line in \
    'printf "[]" > "$_SCRATCH/req"; : > "$_SCRATCH/out"; _claims_parse_run "$_SCRATCH/out" "$_SCRATCH/req"' \
    'printf "[]" > "$_SCRATCH/req"; : > "$_SCRATCH/out"; _claims_parse_run "$_SCRATCH/out" "$_SCRATCH/req" ""' \
    'printf "[]" > "$_SCRATCH/req"; : > "$_SCRATCH/out"; _claims_parse_run "$_SCRATCH/out" "$_SCRATCH/req" x1' \
    ': > "$_SCRATCH/out"; _claims_parse_log "$_SCRATCH/out" SPEC-AUTH-001#token-ttl' \
    ': > "$_SCRATCH/out"; _claims_parse_log "$_SCRATCH/out" SPEC-AUTH-001#token-ttl -1'; do
    probe=$(claims_probe after "$line")
    rc=0
    out=$("$probe" claims render </dev/null 2>/dev/null) || rc=$?
    assert_eq "2" "$rc" "'$line': exits 2"
    assert_json_field "$out" '.error | test("<rc> must be the adapter.s exit code")' "true" "…the error names the missing rc"
  done
  # With an rc the same call runs (the probe itself works). The probe line
  # holds no backslash (awk -v): single quotes inside it.
  probe=$(claims_probe after "printf '%s' '[\"n\"]' > \"\$_SCRATCH/req\"; : > \"\$_SCRATCH/out\"; _claims_parse_run \"\$_SCRATCH/out\" \"\$_SCRATCH/req\" 3 > \"\$_SCRATCH/row\"; jq -e '.reason == \"adapter-exit-3\"' \"\$_SCRATCH/row\" >/dev/null || exit 1")
  rc=0
  "$probe" claims render </dev/null >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "with rc 3: the helper runs and reports adapter-exit-3"
  teardown
}

test_run_selection() {
  echo "test: run — exactly one of --claims, --planes-of, --all; --claims ids split on commas"
  claims_fixture
  stub_runner
  add_claim "$(refresh_claim stub tests/test_token.py::test_refresh)"
  cl run
  assert_usage_verdict run true "claims run with no selection"
  cl run --all --planes-of HEAD~1..HEAD
  assert_usage_verdict run true "claims run --all --planes-of"
  cl run --claims SPEC-AUTH-001#nope
  assert_usage_verdict run true "claims run --claims <unknown id>"
  cl run --claims SPEC-AUTH-001#refresh-single-use
  assert_json_field "$CL_OUT" '[.results[].claim] | tojson' '["SPEC-AUTH-001#refresh-single-use"]' "--claims <id>: that claim alone"
  cl run --claims SPEC-AUTH-001#token-ttl,SPEC-AUTH-001#refresh-single-use
  assert_json_field "$CL_OUT" '.results | length' "2" "--claims a,b: both"
  cl run --claims SPEC-AUTH-001#token-ttl SPEC-AUTH-001#refresh-single-use --scheduled
  assert_json_field "$CL_OUT" '.results | length' "2" "--claims a b: both"
  teardown
}

# --- V3 test binding -------------------------------------------------------------
#
# V3 asks each touched test claim's runner adapter, statically, whether a
# test binds itself to the claim at test.node: one `list [<file>…]` call per
# runner. The stub runner's list prints tools/claims/list.jsonl (list_row
# adds a row), and logs its arguments to $STUB_LOG.

# The last `cl`'s V3 finding messages, one per line, and their count; its V3
# indeterminate reasons, one per line.
v3_messages() {
  jq -r '.findings[]? | select(.check == "V3") | .message' <<<"$CL_OUT" 2>/dev/null || true
}
v3_count() {
  jq '[.findings[]?, .advisories[]? | select(.check == "V3")] | length' <<<"$CL_OUT" 2>/dev/null || echo invalid
}
v3_reasons() {
  jq -r '.indeterminate[]? | select(.check == "V3") | .reason' <<<"$CL_OUT" 2>/dev/null || true
}

# assert_v3 <substring> <what>: the last `cl` exited 1 with a V3 finding whose
# message contains <substring>.
assert_v3() {
  assert_eq "1" "$CL_RC" "$2: exits 1"
  assert_contains "$(v3_messages)" "$1" "$2: a V3 finding names '$1'"
}

# assert_v3_ok <what>: the last `cl` exited 0 with no V3 finding.
assert_v3_ok() {
  assert_eq "0" "$CL_RC" "$1: exits 0"
  assert_eq "0" "$(v3_count)" "$1: no V3 finding"
}

# The stub's list calls in $STUB_LOG: the number of "list" lines.
stub_list_calls() {
  grep -c '^list$' "$STUB_LOG" || true
}

# stub_v9_log <arg>…: the $STUB_LOG lines of one edited-bound-tests call per
# <arg>, which V9 makes after V3's list calls in every validate (Task 10).
stub_v9_log() {
  local a
  for a in "$@"; do printf 'edited-bound-tests\n%s\n' "$a"; done
}
# validate --all's V9 range: <the fixture's merge-base>..HEAD.
mb_range() {
  printf '%s..HEAD' "$(git merge-base HEAD main)"
}

test_v3_unbound_node() {
  echo "test: V3 — a test node the runner's list does not bind to the claim"
  claims_fixture
  stub_runner
  cl validate --all
  assert_v3 "not bound" "list.jsonl empty"
  assert_json_field "$CL_OUT" '[.findings[] | select(.check == "V3")][0].claim' "SPEC-AUTH-001#token-ttl" "…the finding names the claim"
  assert_json_field "$CL_OUT" '[.findings[] | select(.check == "V3")][0].doc' "$DOC" "…and its doc"
  assert_eq "1" "$(stub_list_calls)" "…one list call"
  # The id bound at another node, and the node bound to another id: neither
  # binds this claim's node to it.
  list_row SPEC-AUTH-001#token-ttl tests/test_token.py::test_other
  list_row SPEC-AUTH-001#other "$STUB_NODE"
  cl validate --all
  assert_v3 "not bound" "the id at another node, the node under another id"
  teardown
}

test_v3_bound_passes() {
  echo "test: V3 — a node the runner's list binds to the claim passes; one list call per runner"
  claims_fixture
  stub_runner
  list_row SPEC-AUTH-001#token-ttl "$STUB_NODE"
  cl validate --all
  assert_v3_ok "bound, in the gate, subject imported inside the test"
  assert_eq "$(printf 'list\n'; stub_v9_log "$(mb_range)")" "$(cat "$STUB_LOG")" \
    "…tests/test_token.py is not a path: list with no file (all files)"
  # The node's file exists: list is asked for it, once though two claims
  # name it.
  mkdir -p tests
  printf 'def test_ttl(): pass\n' > tests/test_token.py
  add_claim "$(refresh_claim stub tests/test_token.py::test_refresh)"
  list_row SPEC-AUTH-001#refresh-single-use tests/test_token.py::test_refresh
  rerender
  : > "$STUB_LOG"
  cl validate --all
  assert_v3_ok "two bound claims of one runner"
  assert_eq "$(printf 'list\ntests/test_token.py\n'; stub_v9_log "$(mb_range)")" "$(cat "$STUB_LOG")" \
    "…one list call, the node's file once"
  # test.file, when set, is the file (passed as one argument, spaces kept).
  jset "$SIDECAR" '.claims[1].test.file = "tests/refresh spec.py"'
  : > "$STUB_LOG"
  cl validate --all
  assert_v3_ok "test.file set"
  assert_eq "$(printf 'list\ntests/refresh spec.py\ntests/test_token.py\n'; stub_v9_log "$(mb_range)")" "$(cat "$STUB_LOG")" \
    "…test.file passed as one argument"
  # --staged checks the touched claims alone: none, then the one whose test
  # file is staged.
  git add -A && git commit -qm "two bound claims"
  : > "$STUB_LOG"
  cl validate --staged
  assert_v3_ok "--staged, nothing staged"
  assert_eq "0" "$(stub_list_calls)" "…no list call"
  printf 'def test_ttl(): assert True\n' > tests/test_token.py
  git add tests/test_token.py
  cl validate --staged
  assert_v3_ok "--staged, the token-ttl test file staged"
  assert_eq "$(stub_v9_log --staged; printf 'list\ntests/test_token.py\n'; stub_v9_log --staged)" "$(cat "$STUB_LOG")" \
    "…list asked for that claim's file alone (after the first run's V9 call)"
  teardown
}

test_v3_in_gate_false() {
  echo "test: V3 — a bound node outside the host's test gate"
  claims_fixture
  stub_runner
  list_row SPEC-AUTH-001#token-ttl "$STUB_NODE" false
  cl validate --all
  assert_v3 "outside the test gate" "in_gate false"
  teardown
}

test_v3_subject_imports_not_ok() {
  echo "test: V3 — a bound node importing its subject at module level, whatever the status"
  claims_fixture
  stub_runner
  list_row SPEC-AUTH-001#token-ttl "$STUB_NODE" true false
  cl validate --all
  assert_v3 "imports its subject at module level" "unbuilt, subject_imports_ok false"
  run_built
  : > tools/claims/list.jsonl
  list_row SPEC-AUTH-001#token-ttl "$STUB_NODE" true false
  cl validate --all
  assert_v3 "imports its subject at module level" "built, subject_imports_ok false"
  teardown
}

test_v3_built_without_nonvacuity() {
  echo "test: V3 — built without nonvacuity or without promotion"
  claims_fixture
  stub_runner
  run_built
  cl validate --all
  assert_v3_ok "promoted: a bound test, a mutant, a promotion and its verdict"
  jset "$SIDECAR" '.claims[0].nonvacuity = null'
  cl validate --all
  assert_v3 "without nonvacuity" "built, nonvacuity null"
  jset "$SIDECAR" '.claims[0].nonvacuity = {}'
  cl validate --all
  assert_v3 "without nonvacuity" "built, nonvacuity {} (neither observed_red nor mutant)"
  jset "$SIDECAR" '.claims[0].nonvacuity = {"observed_red": "0123abc"}'
  cl validate --all
  assert_v3_ok "built, nonvacuity observed_red"
  jset "$SIDECAR" '.claims[0].nonvacuity = {"mutant": {"file": "src/auth/token.py", "find": ""}}'
  cl validate --all
  assert_v3 "nonvacuity.mutant must be {file, find, replace}" "a mutant without replace, find empty"
  jset "$SIDECAR" ".claims[0].nonvacuity = $_CL_MUTANT | .claims[0].promotion = null"
  cl validate --all
  assert_v3 "without promotion" "built, promotion null"
  teardown
}

test_v3_mutant_find_not_unique() {
  echo "test: V3 — nonvacuity.mutant.find must occur exactly once (literally) in the proposed mutant.file"
  claims_fixture
  stub_runner
  run_built
  printf 'TTL_SECONDS = 900  # TTL in seconds\n' > src/auth/token.py
  jset "$SIDECAR" '.claims[0].nonvacuity.mutant.find = "TTL"'
  cl validate --all
  assert_v3 "occurs 2 times" "find TTL, twice in src/auth/token.py"
  jset "$SIDECAR" '.claims[0].nonvacuity.mutant.find = "TTL_SECONDS = 1800"'
  cl validate --all
  assert_v3 "occurs 0 times" "find absent from the file"
  # Literal, never a regex: "." matches only a dot.
  jset "$SIDECAR" '.claims[0].nonvacuity.mutant.find = "TTL.SECONDS"'
  cl validate --all
  assert_v3 "occurs 0 times" "find TTL.SECONDS (a regex would match)"
  jset "$SIDECAR" '.claims[0].nonvacuity.mutant.find = "TTL_SECONDS = 900"'
  cl validate --all
  assert_v3_ok "find once"
  # --staged reads the index's mutant.file, --all the work tree's.
  jset "$SIDECAR" '.claims[0].nonvacuity.mutant.find = "TTL"'
  printf 'TTL_SECONDS = 900  # TTL in seconds\n' > src/auth/token.py
  git add -A
  printf 'TTL_SECONDS = 900\n' > src/auth/token.py
  cl validate --staged
  assert_v3 "occurs 2 times" "--staged: twice in the index"
  cl validate --all
  assert_eq "0" "$(v3_count)" "--all: once in the work tree, no V3 finding"
  teardown
}

test_v3_mutant_file_unsafe_never_read() {
  echo "test: V3 — an unsafe or absent nonvacuity.mutant.file is a finding, never read"
  claims_fixture
  stub_runner
  run_built
  local out
  out=$(harness_mktemp_d outside-mutant)
  printf 'TTL_SECONDS = 900\n' > "$out/token.py"
  # Through "..": src/../.. is the fixture's parent, where $out lives. Read,
  # it would hold find exactly once.
  jset "$SIDECAR" ".claims[0].nonvacuity.mutant.file = \"src/../../$(basename "$out")/token.py\""
  cl validate --all
  assert_v3 "is not a safe repo path" "mutant.file with .. segments"
  # Through a symbolic link.
  ln -s "$out" src/outside
  jset "$SIDECAR" '.claims[0].nonvacuity.mutant.file = "src/outside/token.py"'
  cl validate --all
  assert_v3 "is not a safe repo path" "mutant.file through a symlinked directory"
  jset "$SIDECAR" '.claims[0].nonvacuity.mutant.file = "src/auth/nope.py"'
  cl validate --all
  assert_v3 "is not in the proposed tree" "mutant.file absent"
  teardown
}

test_v3_test_file_unsafe() {
  echo "test: V3 — an unsafe test.file is a finding, never passed to the adapter"
  claims_fixture
  stub_runner
  list_row SPEC-AUTH-001#token-ttl "$STUB_NODE"
  jset "$SIDECAR" '.claims[0].test.file = "../tests/test_token.py"'
  cl validate --all
  assert_v3 "test.file ../tests/test_token.py is not a safe repo path" "test.file with a .. segment"
  assert_eq "0" "$(stub_list_calls)" "…no list call for it"
  teardown
}

test_v3_list_adapter_failure_indeterminate() {
  echo "test: V3 — a list call that fails or prints noise is indeterminate, never a pass or a finding"
  claims_fixture
  stub_runner
  list_row SPEC-AUTH-001#token-ttl "$STUB_NODE"
  STUB_EXIT=1 cl validate --all
  assert_eq "2" "$CL_RC" "STUB_EXIT=1: exits 2"
  assert_eq "adapter-exit-1" "$(v3_reasons)" "…V3 indeterminate, adapter-exit-1"
  assert_json_field "$CL_OUT" '[.indeterminate[] | select(.check == "V3")][0].claim' "SPEC-AUTH-001#token-ttl" "…naming the claim"
  # Unbound, but the adapter failed: indeterminate, never "not bound".
  : > tools/claims/list.jsonl
  STUB_EXIT=1 cl validate --all
  assert_eq "2" "$CL_RC" "STUB_EXIT=1, no row: exits 2"
  assert_eq "0" "$(v3_count)" "…no V3 finding"
  # Noise, or a row of the wrong shape, among the rows.
  local bad
  for bad in 'scanning tests...' '[1]' 'null' \
      '{"id":"SPEC-AUTH-001#token-ttl","node":"'"$STUB_NODE"'","file":"tests/test_token.py","in_gate":"yes","subject_imports_ok":true,"when":null}' \
      '{"id":"SPEC-AUTH-001#token-ttl","node":"'"$STUB_NODE"'","file":"tests/test_token.py","in_gate":true,"when":null}'; do
    : > tools/claims/list.jsonl
    list_row SPEC-AUTH-001#token-ttl "$STUB_NODE"
    printf '%s\n' "$bad" >> tools/claims/list.jsonl
    cl validate --all
    assert_eq "2" "$CL_RC" "list line $bad: exits 2"
    assert_eq "malformed-adapter-output" "$(v3_reasons)" "…$bad: malformed-adapter-output"
  done
  # An unknown runner is a missing adapter (R6): indeterminate, no finding.
  : > tools/claims/list.jsonl
  list_row SPEC-AUTH-001#token-ttl "$STUB_NODE"
  jset "$SIDECAR" '.claims[0].test.runner = "nosuch"'
  cl validate --all
  assert_eq "2" "$CL_RC" "an unknown runner: exits 2"
  assert_eq "adapter-exit-126" "$(v3_reasons)" "…adapter-exit-126"
  assert_eq "0" "$(v1_count)" "…no V1 finding"
  assert_eq "0" "$(v3_count)" "…no V3 finding"
  # The static checks still run when the adapter fails.
  jset "$SIDECAR" '.claims[0].test.runner = "stub"'
  run_built
  jset "$SIDECAR" '.claims[0].nonvacuity = null'
  STUB_EXIT=1 cl validate --all
  assert_v3 "without nonvacuity" "STUB_EXIT=1, built without nonvacuity"
  assert_eq "adapter-exit-1" "$(v3_reasons)" "…beside the indeterminate"
  teardown
}

test_v3_mutant_checked_only_built() {
  echo "test: V3 — only a built or gated claim's mutant is checked"
  claims_fixture
  stub_runner
  list_row SPEC-AUTH-001#token-ttl "$STUB_NODE"
  local nv='{"mutant":{"file":"src/auth/token.py","find":"TTL_SECONDS = 1800","replace":"TTL_SECONDS = 900"}}'
  jset "$SIDECAR" ".claims[0].nonvacuity = $nv"
  cl validate --all
  assert_v3_ok "unbuilt, an early mutant whose find is absent"
  diverge_claim "$STUB_TEST"
  jset "$SIDECAR" ".claims[0].nonvacuity = $nv"
  cl validate --all
  assert_v3_ok "diverged, a stale mutant whose find is absent"
  jset "$SIDECAR" '.claims[0].nonvacuity.mutant.file = "src/auth/nope.py"'
  cl validate --all
  assert_v3_ok "diverged, a mutant whose file is absent (never read)"
  teardown
}

test_v3_frozen_structural_only() {
  echo "test: V3 — a frozen claim is checked structurally only: no list call"
  claims_fixture
  stub_runner
  run_built
  : > tools/claims/list.jsonl
  jset "$SIDECAR" ".claims[0].frozen_at = \"$(git rev-parse HEAD)\""
  : > "$STUB_LOG"
  cl validate --all
  assert_v3_ok "frozen built, its list row gone"
  assert_eq "0" "$(stub_list_calls)" "…no list call for it"
  jset "$SIDECAR" '.claims[0].promotion = null'
  cl validate --all
  assert_v3 "without promotion" "frozen built, promotion null"
  assert_not_contains "$(v3_messages)" "not bound" "…no binding finding"
  assert_eq "0" "$(stub_list_calls)" "…still no list call"
  teardown
}

test_v3_runner_name_with_newline() {
  echo "test: V3 — a runner name holding a newline is a missing adapter, as in run"
  claims_fixture
  stub_runner
  list_row SPEC-AUTH-001#token-ttl "$STUB_NODE"
  # Trimmed, "stub\n" would name the configured stub, which binds the node.
  jset "$SIDECAR" '.claims[0].test.runner = "stub\n"'
  cl validate --all
  assert_eq "2" "$CL_RC" "runner \"stub\\n\": exits 2"
  assert_eq "adapter-exit-126" "$(v3_reasons)" "…V3 indeterminate, adapter-exit-126"
  assert_eq "0" "$(v3_count)" "…no V3 finding"
  assert_eq "0" "$(stub_list_calls)" "…the stub never listed"
  cl run --all
  assert_eq "2" "$CL_RC" "…run agrees: exits 2"
  assert_eq "indeterminate" "$(run_field verdict)" "…run's verdict indeterminate"
  teardown
}

test_v3_staged_mutant_file_touches_claim() {
  echo "test: V3 — under --staged, staging a built claim's mutant file touches the claim"
  claims_fixture
  stub_runner
  run_built
  printf 'TTL_SECONDS = 900\n' > src/auth/consts.py
  jset "$SIDECAR" '.claims[0].nonvacuity.mutant.file = "src/auth/consts.py"'
  git add -A && git commit -qm "the mutant in consts.py"
  printf 'TTL_SECONDS = 900\nTTL_SECONDS = 900\n' > src/auth/consts.py
  git add src/auth/consts.py
  cl validate --staged
  assert_v3 "occurs 2 times" "--staged, only the mutant file staged"
  teardown
}

test_v3_test_file_dash_and_containment() {
  echo "test: V3 — a test file starting with - or reached through a symlink never reaches the adapter"
  claims_fixture
  stub_runner
  list_row SPEC-AUTH-001#token-ttl "$STUB_NODE"
  jset "$SIDECAR" '.claims[0].test.file = "-t.py"'
  : > "$STUB_LOG"
  cl validate --all
  assert_v3 'test.file -t.py starts with "-"' "test.file -t.py"
  assert_eq "0" "$(stub_list_calls)" "…no list call"
  # The node's path, an existing file starting with -.
  printf 'def test_ttl(): pass\n' > ./-t.py
  list_row SPEC-AUTH-001#token-ttl "-t.py::test_ttl"
  jset "$SIDECAR" '.claims[0].test = {"runner": "stub", "node": "-t.py::test_ttl"}'
  cl validate --all
  assert_v3 'test file -t.py (the node path before ::) starts with "-"' "node -t.py::test_ttl"
  assert_eq "0" "$(stub_list_calls)" "…no list call"
  # Through a symlinked directory, in both modes (the adapter reads the work tree).
  local out
  out=$(harness_mktemp_d outside-tests)
  printf 'def test_ttl(): pass\n' > "$out/test_x.py"
  mkdir -p tests
  ln -s "$out" tests/link
  jset "$SIDECAR" ".claims[0].test = $STUB_TEST | .claims[0].test.file = \"tests/link/test_x.py\""
  git add "$SIDECAR"
  cl validate --staged
  assert_v3 "test.file tests/link/test_x.py is not a safe repo path" "--staged, test.file through a symlink"
  cl validate --all
  assert_v3 "test.file tests/link/test_x.py is not a safe repo path" "--all, test.file through a symlink"
  assert_eq "0" "$(stub_list_calls)" "…no list call"
  teardown
}

test_v3_two_runners_one_call_each() {
  echo "test: V3 — two runners: one list call each, with its own files"
  claims_fixture
  stub_runner
  list_row SPEC-AUTH-001#token-ttl "$STUB_NODE"
  mkdir -p tests
  printf 'def test_ttl(): pass\n' > tests/test_token.py
  printf 'def test_refresh(): pass\n' > tests/test_refresh.py
  # A second adapter: the same stub in tools/claims2/, its own list.jsonl.
  write_stub tools/claims2/runner "$STUB_RUNNER_SH"
  : > tools/claims2/edited
  jq -nc '{id: "SPEC-AUTH-001#refresh-single-use", node: "tests/test_refresh.py::test_refresh",
    file: "tests/test_refresh.py", in_gate: true, subject_imports_ok: true, when: null}' > tools/claims2/list.jsonl
  jset docs/spec-claims/config.json '.runners.stub2 = {"adapter": "tools/claims2/runner", "paths": ["tests/"]}'
  add_claim "$(refresh_claim stub2 tests/test_refresh.py::test_refresh)"
  rerender
  : > "$STUB_LOG"
  cl validate --all
  assert_v3_ok "both claims bound, each by its own runner"
  assert_eq "$(printf 'list\ntests/test_token.py\nlist\ntests/test_refresh.py\n'; stub_v9_log "$(mb_range)" "$(mb_range)")" \
    "$(cat "$STUB_LOG")" "…two list calls, stub then stub2, each with its claim's file alone (then V9's, one per runner)"
  teardown
}

# --- V4 lint and lint runs ---------------------------------------------------------
#
# A lint claim (enforced_by lint) carries {pattern, paths, expect, selftest}.
# V4 evaluates the pattern (grep -E) on each selftest string — violates must
# fail the lint, clean pass it — and on the proposed lint.paths files: a
# built claim's lint must pass, a diverged one's fail. claims run re-runs the
# same evaluation on the working tree (pass → pass, fail → assert-fail).

# The fixture's TTL sentence as a lint: the 900-second constant present in
# the subject.
_CL_LINT='{"pattern":"TTL_SECONDS = 900","paths":["src/auth/token.py"],"expect":"present","selftest":{"violates":"TTL_SECONDS = 1800","clean":"TTL_SECONDS = 900"}}'

# The last `cl`'s V4 finding messages, one per line, and their count.
v4_messages() {
  jq -r '.findings[]? | select(.check == "V4") | .message' <<<"$CL_OUT" 2>/dev/null || true
}
v4_count() {
  jq '[.findings[]?, .advisories[]? | select(.check == "V4")] | length' <<<"$CL_OUT" 2>/dev/null || echo invalid
}

# assert_v4 <substring> <what>: the last `cl` exited 1 with a V4 finding whose
# message contains <substring>.
assert_v4() {
  assert_eq "1" "$CL_RC" "$2: exits 1"
  assert_contains "$(v4_messages)" "$1" "$2: a V4 finding names '$1'"
}

# assert_v4_ok <what>: the last `cl` exited 0 with no V4 finding.
assert_v4_ok() {
  assert_eq "0" "$CL_RC" "$1: exits 0"
  assert_eq "0" "$(v4_count)" "$1: no V4 finding"
}

# lint_claim [<lint-json>]: the fixture claim enforced by lint (default
# _CL_LINT), test null, still unbuilt, committed as the branch point
# (base_here: the tier change is not what these tests ratchet).
lint_claim() {
  jset "$SIDECAR" ".claims[0].enforced_by = \"lint\" | .claims[0].test = null | .claims[0].lint = ${1:-$_CL_LINT}"
  base_here "lint claim"
}

# lint_promote: the lint claim made built as promote makes it (V6): the tree
# committed first (when it has changes), then status built, its verdict in the store, promotion
# {at: HEAD, verdict_sha256} and the status block rendered.
lint_promote() {
  git add -A
  git diff --cached --quiet || git commit -qm "lint claim, before promote"
  jset "$SIDECAR" '.claims[0].status = "built"'
  CL_DIGEST=$(write_verdict)
  jset "$SIDECAR" ".claims[0].promotion = {\"at\": \"$(git rev-parse HEAD)\", \"verdict_sha256\": \"$CL_DIGEST\"}"
  rerender
}

# lint_diverge: the lint claim made diverged (its tracker the fixture's, a
# CODE-DIVERGES ruling).
lint_diverge() {
  jset "$SIDECAR" ".claims[0].status = \"diverged\" | .claims[0].rulings = [$_CL_DIVERGES]"
  rerender
}

test_v4_selftest_violates_passes() {
  echo "test: V4 — a pattern its violates selftest passes is vacuous"
  claims_fixture
  lint_claim '{"pattern":".*","paths":["src/auth/token.py"],"expect":"present","selftest":{"violates":"TTL_SECONDS = 1800","clean":"TTL_SECONDS = 900"}}'
  cl validate --all
  assert_v4 "vacuous pattern" "pattern .*, expect present"
  assert_contains "$(v4_messages)" "selftest.violates" "…it names the violates selftest"
  assert_not_contains "$(v4_messages)" "selftest.clean" "…not the clean one (it passes)"
  assert_json_field "$CL_OUT" '[.findings[] | select(.check == "V4")][0].claim' "SPEC-AUTH-001#token-ttl" "…the finding names the claim"
  assert_json_field "$CL_OUT" '[.findings[] | select(.check == "V4")][0].doc' "$DOC" "…and its doc"
  # The same pattern, expect absent: every clean text fails it.
  jset "$SIDECAR" '.claims[0].lint.expect = "absent"'
  cl validate --all
  assert_v4 "vacuous pattern" "pattern .*, expect absent"
  assert_contains "$(v4_messages)" "selftest.clean" "…it names the clean selftest"
  # An empty violates is one empty line, which .* matches: never a 0-byte
  # file no pattern matches.
  jset "$SIDECAR" '.claims[0].lint.expect = "present" | .claims[0].lint.selftest.violates = ""'
  cl validate --all
  assert_v4 "vacuous pattern" "pattern .*, violates \"\""
  assert_contains "$(v4_messages)" "selftest.violates" "…it names the violates selftest"
  # A pattern ending in a newline is also the empty pattern to grep, which
  # matches every line: an empty violates does not hide it.
  jset "$SIDECAR" '.claims[0].lint.pattern = "TTL_SECONDS = 900\n"'
  cl validate --all
  assert_v4 "vacuous pattern" "pattern with a trailing newline, violates \"\""
  assert_contains "$(v4_messages)" "selftest.violates" "…it names the violates selftest"
  teardown
}

test_v4_selftest_clean_fails() {
  echo "test: V4 — a pattern its clean selftest fails is vacuous"
  claims_fixture
  lint_claim
  jset "$SIDECAR" '.claims[0].lint.selftest.clean = "TTL = 15 minutes"'
  cl validate --all
  assert_v4 "vacuous pattern" "clean text without the constant, expect present"
  assert_contains "$(v4_messages)" "selftest.clean" "…it names the clean selftest"
  assert_eq "1" "$(v4_count)" "…one V4 finding (violates still fails the lint)"
  # A violates text holding the pattern passes the lint: vacuous too.
  jset "$SIDECAR" '.claims[0].lint.selftest = {"violates":"TTL_SECONDS = 900  # was 1800","clean":"TTL_SECONDS = 900"}'
  cl validate --all
  assert_v4 "selftest.violates" "violates text holding the pattern"
  teardown
}

test_v4_pattern_contradicts_status() {
  echo "test: V4 — the lint over the proposed paths contradicts the status"
  claims_fixture
  lint_claim
  lint_promote
  cl validate --all
  assert_v4_ok "built, the constant present"
  set_ttl 1800
  cl validate --all
  assert_v4 "contradicts" "built, the pattern absent from the paths"
  assert_contains "$(v4_messages)" "src/auth/token.py" "…it names the paths"
  # Two paths: their concatenation is evaluated, so one holding it passes.
  mkdir -p src/auth/legacy
  printf 'TTL_SECONDS = 900\n' > src/auth/legacy/token.py
  jset "$SIDECAR" '.claims[0].lint.paths = ["src/auth/token.py", "src/auth/legacy/token.py"]'
  cl validate --all
  assert_eq "0" "$(v4_count)" "built, one of two paths holds the pattern: no V4 finding"
  # A file without a final newline does not run into the next one.
  printf 'TTL_SECONDS = 9' > src/auth/token.py
  printf '00\n' > src/auth/legacy/token.py
  cl validate --all
  assert_v4 "contradicts" "the pattern only across the two files' boundary"
  teardown
}

test_v4_diverged_and_unbuilt_status() {
  echo "test: V4 — diverged expects the lint to fail; unbuilt takes either"
  claims_fixture
  lint_claim
  cl validate --all
  assert_v4_ok "unbuilt, the lint passes"
  set_ttl 1800
  cl validate --all
  assert_v4_ok "unbuilt, the lint fails"
  lint_diverge
  cl validate --all
  assert_v4_ok "diverged, the lint fails"
  set_ttl 900
  cl validate --all
  assert_v4 "contradicts" "diverged, the lint passes"
  teardown
}

test_v4_unbuilt_absent_path_allowed() {
  echo "test: V4 — an unbuilt claim's absent lint path is its allowed failure; an unsafe one is still a finding"
  claims_fixture
  lint_claim
  jset "$SIDECAR" '.claims[0].lint.paths = ["src/auth/rotation.py"]'
  cl validate --all
  assert_v4_ok "unbuilt, the lint path not written yet"
  cl run --all
  assert_eq "0" "$CL_RC" "…run exits 0"
  assert_eq "ok" "$(run_field verdict)" "…verdict ok"
  assert_eq "assert-fail" "$(run_field outcome)" "…outcome assert-fail (the lint evaluates as fail)"
  assert_contains "$(run_field message)" "absent" "…the message says a lint path is absent"
  # An unsafe path is a finding whatever the status.
  jset "$SIDECAR" '.claims[0].lint.paths = ["src/auth/rotation.py", "src/../../x/token.py"]'
  cl validate --all
  assert_v4 "is not a safe repo path" "unbuilt, one path unsafe"
  cl run --all
  assert_eq "1" "$CL_RC" "…run exits 1"
  assert_contains "$(run_field message)" "is not a safe repo path" "…a run finding names it"
  # built: an absent path is still a finding.
  jset "$SIDECAR" '.claims[0].lint.paths = ["src/auth/token.py"]'
  lint_promote
  jset "$SIDECAR" '.claims[0].lint.paths = ["src/auth/rotation.py"]'
  cl validate --all
  assert_v4 "is not a file in the proposed tree" "built, the lint path absent"
  cl run --all
  assert_eq "1" "$CL_RC" "…run exits 1"
  assert_contains "$(run_field message)" "is not a file in the proposed tree" "…a run finding names it"
  teardown
}

test_v4_valid_lint_passes() {
  echo "test: V4 — a lint with honest selftests, consistent with its status, passes"
  claims_fixture
  lint_claim
  cl validate --all
  assert_v4_ok "unbuilt lint claim"
  lint_promote
  cl validate --all
  assert_v4_ok "built lint claim, the constant present"
  assert_eq "0" "$(json_count "$(jq -c '.findings[]?' <<<"$CL_OUT")")" "…no finding of any check"
  # expect absent: the 1800-second constant must not appear.
  jset "$SIDECAR" '.claims[0].lint = {"pattern":"TTL_SECONDS = 1800","paths":["src/auth/token.py"],"expect":"absent","selftest":{"violates":"TTL_SECONDS = 1800","clean":"TTL_SECONDS = 900"}}'
  cl validate --all
  assert_eq "0" "$(v4_count)" "expect absent, the forbidden constant absent: no V4 finding"
  teardown
}

test_v4_invalid_pattern() {
  echo "test: V4 — a pattern grep -E rejects is a finding, never a pass or a fail"
  claims_fixture
  lint_claim '{"pattern":"TTL_SECONDS = (900","paths":["src/auth/token.py"],"expect":"absent","selftest":{"violates":"TTL_SECONDS = (900","clean":"x"}}'
  cl validate --all
  assert_v4 "invalid pattern" "an unbalanced parenthesis"
  assert_eq "1" "$(v4_count)" "…one V4 finding (no vacuous-pattern reading of the error)"
  teardown
}

test_v4_lint_paths_unsafe_or_absent() {
  echo "test: V4 — an unsafe or absent lint path is a finding, never read"
  claims_fixture
  lint_claim
  lint_promote
  local out
  out=$(harness_mktemp_d outside-lint)
  printf 'TTL_SECONDS = 900\n' > "$out/token.py"
  set_ttl 1800
  # Through "..": read, the outside file would hold the pattern.
  jset "$SIDECAR" ".claims[0].lint.paths = [\"src/../../$(basename "$out")/token.py\"]"
  cl validate --all
  assert_v4 "is not a safe repo path" "a lint path with .. segments"
  assert_not_contains "$(v4_messages)" "contradicts" "…the lint is not evaluated"
  # Through a symbolic link.
  ln -s "$out" src/outside
  jset "$SIDECAR" '.claims[0].lint.paths = ["src/outside/token.py"]'
  cl validate --all
  assert_v4 "is not a safe repo path" "a lint path through a symlinked directory"
  assert_not_contains "$(v4_messages)" "contradicts" "…the lint is not evaluated"
  jset "$SIDECAR" '.claims[0].lint.paths = ["src/auth/nope.py"]'
  cl validate --all
  assert_v4 "is not a file in the proposed tree" "a lint path absent"
  teardown
}

test_v4_staged_reads_index() {
  echo "test: V4 — --staged evaluates the index's paths; a staged lint path touches the claim"
  claims_fixture
  lint_claim
  lint_promote
  git add -A && git commit -qm "built lint claim"
  set_ttl 1800
  git add src/auth/token.py
  set_ttl 900
  cl validate --staged
  assert_v4 "contradicts" "the index drops the constant, the work tree keeps it"
  cl validate --all
  assert_v4_ok "--all reads the work tree"
  teardown
}

test_v4_frozen_selftest_only() {
  echo "test: V4 — a frozen lint claim's selftests are checked, its paths not read"
  claims_fixture
  lint_claim
  lint_promote
  jset "$SIDECAR" ".claims[0].frozen_at = \"$(git rev-parse HEAD)\""
  set_ttl 1800
  cl validate --all
  assert_v4_ok "frozen built, the pattern gone from the paths"
  jset "$SIDECAR" '.claims[0].lint.selftest.clean = "nothing"'
  cl validate --all
  assert_v4 "vacuous pattern" "frozen, clean selftest fails"
  # Its path strings are structural: an unsafe one is a finding, an absent
  # one is not read.
  jset "$SIDECAR" '.claims[0].lint.selftest.clean = "TTL_SECONDS = 900" | .claims[0].lint.paths = ["src/auth/rotation.py"]'
  cl validate --all
  assert_v4_ok "frozen, its lint path absent (never read)"
  jset "$SIDECAR" '.claims[0].lint.paths = ["src/../../x/token.py"]'
  cl validate --all
  assert_v4 "is not a safe repo path" "frozen, an unsafe lint path string"
  teardown
}

test_run_lint_rerun() {
  echo "test: run — a lint claim is re-run over the work tree"
  claims_fixture
  lint_claim
  lint_promote
  cl run --all
  assert_eq "0" "$CL_RC" "built lint claim, the constant present: run --all exits 0"
  assert_eq "ok" "$(run_field verdict)" "…verdict ok"
  assert_eq "pass" "$(run_field outcome)" "…outcome pass"
  set_ttl 1800
  cl run --all
  assert_eq "1" "$CL_RC" "the source edited to violate: exits 1"
  assert_eq "finding" "$(run_field verdict)" "…verdict finding"
  assert_eq "assert-fail" "$(run_field outcome)" "…outcome assert-fail"
  assert_json_field "$CL_OUT" '.findings[0].check' "run" "…a run finding"
  assert_json_field "$CL_OUT" '.findings[0].claim' "SPEC-AUTH-001#token-ttl" "…naming the claim"
  # diverged: the violation is the expected red.
  lint_diverge
  cl run --claims SPEC-AUTH-001#token-ttl
  assert_eq "0" "$CL_RC" "diverged, the lint fails: exits 0"
  assert_eq "assert-fail" "$(run_field outcome)" "…outcome assert-fail"
  teardown
}

test_run_lint_unbuilt_pass_is_finding() {
  echo "test: run — an unbuilt lint claim whose lint passes is a finding: promote"
  claims_fixture
  lint_claim
  cl run --all
  assert_eq "1" "$CL_RC" "unbuilt, the constant present: exits 1"
  assert_eq "finding" "$(run_field verdict)" "…verdict finding"
  assert_eq "pass" "$(run_field outcome)" "…outcome pass"
  assert_contains "$(run_field message)" "passes: promote" "…it says promote"
  teardown
}

test_run_lint_structural_findings() {
  echo "test: run — an invalid pattern or an unsafe or absent lint path is a finding, not indeterminate"
  claims_fixture
  lint_claim
  lint_promote
  jset "$SIDECAR" '.claims[0].lint.pattern = "TTL_SECONDS = (900"'
  cl run --all
  assert_eq "1" "$CL_RC" "invalid pattern: exits 1"
  assert_eq "finding" "$(run_field verdict)" "…verdict finding"
  assert_contains "$(run_field message)" "invalid pattern" "…invalid pattern"
  assert_eq "0" "$(jq '.indeterminate | length' <<<"$CL_OUT")" "…nothing indeterminate"
  jset "$SIDECAR" ".claims[0].lint.pattern = \"TTL_SECONDS = 900\" | .claims[0].lint.paths = [\"src/../../x/token.py\", \"src/auth/nope.py\"]"
  cl run --all
  assert_eq "1" "$CL_RC" "unsafe and absent paths: exits 1"
  assert_contains "$(run_field message)" "is not a safe repo path" "…the unsafe path named"
  assert_contains "$(run_field message)" "src/auth/nope.py" "…the absent path named"
  assert_eq "0" "$(jq '.indeterminate | length' <<<"$CL_OUT")" "…nothing indeterminate"
  # A malformed lint on a lint claim is a finding too (V1 names the shape).
  jset "$SIDECAR" '.claims[0].lint = {"pattern": ""}'
  cl run --all
  assert_eq "1" "$CL_RC" "malformed lint: exits 1"
  assert_contains "$(run_field message)" "nothing to run" "…nothing to run"
  # An unbuilt lint claim with lint null has no check yet.
  jset "$SIDECAR" '.claims[0].lint = null | .claims[0].status = "unbuilt" | .claims[0].promotion = null'
  cl run --all
  assert_eq "0" "$CL_RC" "unbuilt, lint null: exits 0"
  assert_eq "no check yet" "$(run_field message)" "…no check yet"
  teardown
}

# --- V9: claim-bound test edits -------------------------------------------------
#
# The fixture made runnable (stub_runner) with its node bound (list_row), so
# V3 holds; tools/claims/edited is what the stub's edited-bound-tests prints.

V9_MSG="bound test edited: adjudicate (states still holds → gate --holds <id>, else a ruling)"

v9_bound() {
  claims_fixture
  stub_runner
  list_row SPEC-AUTH-001#token-ttl "$STUB_NODE"
}

# The last `cl`'s V9 rows: findings and advisories (count), indeterminate reasons.
v9_count() {
  jq '[.findings[]?, .advisories[]? | select(.check == "V9")] | length' <<<"$CL_OUT" 2>/dev/null || echo invalid
}
v9_reasons() {
  jq -r '.indeterminate[]? | select(.check == "V9") | .reason' <<<"$CL_OUT" 2>/dev/null || true
}

# The arguments of each edited-bound-tests call in $STUB_LOG (its next line;
# every call here takes one argument), one per line.
v9_call_args() {
  awk 'p { print; p = 0 } $0 == "edited-bound-tests" { p = 1 }' "$STUB_LOG"
}

test_v9_edited_bound_test_listed_advisory() {
  echo "test: V9 — a claim's bound test edited is listed, advisory in validate"
  v9_bound
  cl validate --staged
  assert_eq "0" "$CL_RC" "nothing edited: exits 0"
  assert_eq "0" "$(v9_count)" "…no V9 row"
  assert_eq "--staged" "$(v9_call_args)" "…one edited-bound-tests --staged call"
  printf 'SPEC-AUTH-001#token-ttl\n' > tools/claims/edited
  : > "$STUB_LOG"
  cl validate --staged
  assert_eq "0" "$CL_RC" "the id listed: exits 0"
  assert_json_field "$CL_OUT" '[.advisories[] | select(.check == "V9")] | length' "1" "…one V9 advisory"
  assert_json_field "$CL_OUT" '[.advisories[] | select(.check == "V9")][0].claim' "SPEC-AUTH-001#token-ttl" "…naming the claim"
  assert_json_field "$CL_OUT" '[.advisories[] | select(.check == "V9")][0].message' "$V9_MSG" "…with the adjudication message"
  assert_json_field "$CL_OUT" '[.advisories[] | select(.check == "V9")][0].code' "non-blocking" "…non-blocking"
  assert_json_field "$CL_OUT" '.findings | length' "0" "…no finding"
  assert_eq "--staged" "$(v9_call_args)" "…called with --staged"
  # Listed twice (or by two calls): one row.
  printf 'SPEC-AUTH-001#token-ttl\n' >> tools/claims/edited
  cl validate --staged
  assert_json_field "$CL_OUT" '[.advisories[] | select(.check == "V9")] | length' "1" "the id listed twice: one V9 advisory"
  # The blocking list (the staged config's) decides: with V9 in it, the same
  # edit blocks.
  jset docs/spec-claims/config.json '.blocking += ["V9"]'
  git add docs/spec-claims/config.json
  cl validate --staged
  assert_eq "1" "$CL_RC" "V9 in blocking: exits 1"
  assert_json_field "$CL_OUT" '[.findings[] | select(.check == "V9")][0].doc' "$DOC" "…a V9 finding naming the doc"
  teardown
}

test_v9_all_uses_merge_base_range() {
  echo "test: V9 — validate --all asks for the edits over <merge-base>..HEAD; an unresolvable base skips it"
  v9_bound
  local mb
  git commit -qm "feature work" --allow-empty
  mb=$(git merge-base HEAD main)
  cl validate --all
  assert_eq "0" "$CL_RC" "validate --all: exits 0"
  assert_eq "$mb..HEAD" "$(v9_call_args)" "…one edited-bound-tests <merge-base>..HEAD call"
  # No base: V9 is skipped, under the one base indeterminate row.
  : > "$STUB_LOG"
  printf 'SPEC-AUTH-001#token-ttl\n' > tools/claims/edited
  cl validate --all --base nosuch
  assert_eq "2" "$CL_RC" "an unresolvable base: exits 2"
  assert_eq "" "$(v9_call_args)" "…no edited-bound-tests call"
  assert_eq "0" "$(v9_count)" "…no V9 row"
  assert_eq "" "$(v9_reasons)" "…no V9 indeterminate"
  assert_json_field "$CL_OUT" '[.indeterminate[] | select(.reason == "base-unresolvable")] | length' "1" "…one base-unresolvable row"
  # --staged needs no base.
  cl validate --staged --base nosuch
  assert_eq "--staged" "$(v9_call_args)" "--staged, no base: still called"
  assert_eq "1" "$(v9_count)" "…the V9 row"
  teardown
}

test_v9_unknown_id_ignored() {
  echo "test: V9 — an id that is not a known claim is ignored"
  v9_bound
  printf 'SPEC-AUTH-001#nosuch\nSPEC-AUTH-001#token-ttl \nsomething else\n' > tools/claims/edited
  cl validate --staged
  assert_eq "0" "$CL_RC" "unknown ids: exits 0"
  assert_eq "0" "$(v9_count)" "…no V9 row"
  assert_eq "" "$(v9_reasons)" "…nothing indeterminate"
  # Known at the base only (the claim gone from the proposed tree): ignored.
  add_claim "$(refresh_claim stub tests/test_token.py::test_refresh)"
  base_here "refresh claim on main"
  jset "$SIDECAR" 'del(.claims[1])'
  git add "$SIDECAR"
  printf 'SPEC-AUTH-001#refresh-single-use\n' > tools/claims/edited
  cl validate --staged
  assert_eq "0" "$(v9_count)" "an id known only at the base: no V9 row"
  assert_eq "" "$(v9_reasons)" "…nothing indeterminate"
  teardown
}

test_v9_adapter_failure_indeterminate() {
  echo "test: V9 — a failing call or an implausible id line is indeterminate, never an empty list"
  v9_bound
  printf 'SPEC-AUTH-001#token-ttl\n' > tools/claims/edited
  STUB_EXIT=1 cl validate --staged
  assert_eq "2" "$CL_RC" "STUB_EXIT=1: exits 2"
  assert_eq "adapter-exit-1" "$(v9_reasons)" "…V9 indeterminate, adapter-exit-1"
  assert_eq "0" "$(v9_count)" "…the failed call's ids unused"
  : > tools/claims/edited
  STUB_EXIT=3 cl validate --all
  assert_eq "2" "$CL_RC" "STUB_EXIT=3, nothing printed, --all: exits 2"
  assert_contains "$(v9_reasons)" "adapter-exit-3" "…adapter-exit-3"
  # Garbage lines: empty, carrying a CR, carrying a NUL.
  local label
  for label in empty cr nul; do
    case $label in
      empty) printf 'SPEC-AUTH-001#token-ttl\n\n' > tools/claims/edited ;;
      cr) printf 'SPEC-AUTH-001#token-ttl\r\n' > tools/claims/edited ;;
      nul) printf 'SPEC-AUTH-001#token-ttl\000x\n' > tools/claims/edited ;;
    esac
    cl validate --staged
    assert_eq "2" "$CL_RC" "a $label line: exits 2"
    assert_eq "malformed-adapter-output" "$(v9_reasons)" "…$label: malformed-adapter-output"
    assert_eq "0" "$(v9_count)" "…$label: no V9 row"
  done
  # A runner with no adapter is a missing adapter: adapter-exit-126.
  : > tools/claims/edited
  jset docs/spec-claims/config.json '.runners.other = {"paths": ["lib/"]}'
  git add docs/spec-claims/config.json
  cl validate --staged
  assert_eq "2" "$CL_RC" "a runner without an adapter: exits 2"
  assert_eq "adapter-exit-126" "$(v9_reasons)" "…adapter-exit-126"
  # A finding still wins over the indeterminate.
  jset docs/spec-claims/config.json '.blocking += ["V9"]'
  git add docs/spec-claims/config.json
  printf 'SPEC-AUTH-001#token-ttl\n' > tools/claims/edited
  cl validate --staged
  assert_eq "1" "$CL_RC" "a V9 finding beside the indeterminate: exits 1"
  assert_eq "adapter-exit-126" "$(v9_reasons)" "…the indeterminate still reported"
  teardown
}

# --- claims promote with a mutant proof ----------------------------------------
#
# promote_fixture: the fixture claim ready for promote, all committed: unbuilt
# and tracked, bound to the stub (bind_test: the stub's check passes while
# src/auth/token.py holds TTL_SECONDS = 900), with the mutant $_CL_MUTANT
# (900 → 1800, so under the mutation the check fails by an assertion).

TTL_ID="SPEC-AUTH-001#token-ttl"
REFRESH_ID="SPEC-AUTH-001#refresh-single-use"
REFRESH_NODE="tests/test_token.py::test_refresh"

promote_fixture() {
  claims_fixture
  bind_test "$STUB_TEST"
  jset "$SIDECAR" ".claims[0].nonvacuity = $_CL_MUTANT"
  git add -A && git commit -qm "bind the TTL test, with its mutant"
}

# promote_second_claim: a second unbuilt claim (refresh_claim) bound to the
# stub at REFRESH_NODE, its check on src/auth/refresh.py and its own mutant,
# all committed.
promote_second_claim() {
  printf 'SINGLE_USE = True\n' > src/auth/refresh.py
  printf '%s\t%s\t%s\n' "$REFRESH_NODE" src/auth/refresh.py "SINGLE_USE = True" >> tools/claims/checks
  list_row "$REFRESH_ID" "$REFRESH_NODE"
  add_claim "$(refresh_claim stub "$REFRESH_NODE" | jq -c '.nonvacuity = {mutant: {file: "src/auth/refresh.py",
    find: "SINGLE_USE = True", replace: "SINGLE_USE = False"}}')"
  rerender
  git add -A && git commit -qm "a second claim to promote"
}

# The claim <id>'s field <f> in the work-tree sidecar (compact JSON).
claim_field() {
  jq -c --arg id "$1" --arg f "$2" '.claims[] | select(.id == $id) | .[$f]' "$SIDECAR"
}

# The repository's worktrees, the main one included.
wt_count() {
  git worktree list | wc -l | tr -d ' '
}

# The --root argument of each stub run call, one per line, in call order.
stub_roots() {
  awk 'p { print; p = 0 } $0 == "--root" { p = 1 }' "$STUB_LOG"
}

# The last `cl`'s finding messages, one per line; its indeterminate reasons.
promote_messages() {
  jq -r '.findings[]?.message' <<<"$CL_OUT" 2>/dev/null || true
}
promote_reasons() {
  jq -r '.indeterminate[]?.reason' <<<"$CL_OUT" 2>/dev/null || true
}

# assert_promote_finding <substring> <what>: the last `cl` exited 1 with a
# finding whose message contains <substring>.
assert_promote_finding() {
  assert_eq "1" "$CL_RC" "$2: exits 1"
  assert_contains "$(promote_messages)" "$1" "$2: a finding names '$1'"
}

# assert_promote_dirty <what>: the last `cl` refused a dirty tree (exit 2,
# reason dirty-tree).
assert_promote_dirty() {
  assert_eq "2" "$CL_RC" "$1: exits 2"
  assert_eq "dirty-tree" "$(promote_reasons)" "$1: indeterminate, reason dirty-tree"
}

test_promote_mutant_assert_fail_promotes() {
  echo "test: promote — green at HEAD, the mutant fails by an assertion: built, with its verdict"
  promote_fixture
  local head store digest exp oid
  head=$(git rev-parse HEAD)
  cl promote "$TTL_ID"
  assert_eq "0" "$CL_RC" "promote exits 0"
  assert_eq "1" "$(json_count "$CL_OUT")" "…one verdict object"
  assert_eq '"built"' "$(claim_field "$TTL_ID" status)" "…the sidecar's status is built"
  assert_eq "$head" "$(jq -r '.claims[0].promotion.at' "$SIDECAR")" "…promotion.at is HEAD"
  digest=$(jq -r '.claims[0].promotion.verdict_sha256' "$SIDECAR")
  store=$(claims_store)
  assert_file_exists "$store/$digest.json" "…the verdict is in the store, named by its digest"
  assert_eq "$digest" "$(hash_file "$store/$digest.json")" "…promotion.verdict_sha256 is the sha256 of the stored file"
  exp=$(harness_mktemp exp-verdict)
  verdict_bytes "$exp"
  assert_true "…the stored bytes are the jq -cS verdict object (the suite's write_verdict format)" \
    cmp -s "$exp" "$store/$digest.json"
  oid=$(git rev-parse HEAD:src/auth/token.py)
  assert_json_field "$(cat "$store/$digest.json")" '.subject_oids | tojson' "{\"src/auth/token.py\":\"$oid\"}" \
    "…subject_oids maps each subject path to its blob at HEAD"
  assert_json_field "$(cat "$store/$digest.json")" '[.green, .red, .status_to, .head] | join(" ")' \
    "pass assert-fail built $head" "…green pass, red assert-fail, status_to built, head HEAD"
  assert_json_field "$CL_OUT" '.results | tojson' \
    "[{\"claim\":\"$TTL_ID\",\"status_from\":\"unbuilt\",\"status_to\":\"built\",\"green\":\"pass\",\"red\":\"assert-fail\",\"verdict_sha256\":\"$digest\"}]" \
    "…one result row naming the claim, both outcomes and the digest"
  assert_contains "$(cat "$DOC")" "Claims: 1 built" "…and the doc's status block re-rendered"
  assert_eq "$(git rev-parse --show-toplevel)" "$(stub_roots | sed -n 1p)" "…the green run under the work tree"
  assert_true "…the clean-checkout run under another root" test "$(stub_roots | sed -n 2p)" != "$(git rev-parse --show-toplevel)"
  assert_eq "$(stub_roots | sed -n 2p)" "$(stub_roots | sed -n 3p)" "…the mutant run under that same worktree"
  assert_eq "3" "$(stub_roots | wc -l | tr -d ' ')" "…three run calls in all"
  assert_eq "TTL_SECONDS = 900" "$(cat src/auth/token.py)" "…the work tree's subject is untouched"
  cl validate --all
  assert_eq "0" "$CL_RC" "validate --all after the promote exits 0"
  teardown
}

test_promote_mutant_stays_green_refused() {
  echo "test: promote — a mutant under which the test still passes is refused"
  promote_fixture
  local before
  jset "$SIDECAR" '.claims[0].nonvacuity.mutant.replace = "TTL_SECONDS = 900 "'
  git commit -qam "a mutant that keeps the needle"
  before=$(hash_file "$SIDECAR")
  cl promote "$TTL_ID"
  assert_promote_finding "mutant stays green" "replace still holds the checked text"
  assert_eq "$before" "$(hash_file "$SIDECAR")" "…the sidecar unchanged"
  assert_true "…no verdict stored" test ! -e "$(claims_store)"
  assert_eq "[]" "$(jq -c '.results' <<<"$CL_OUT")" "…no result row"
  teardown
}

test_promote_mutant_error_refused() {
  echo "test: promote — a mutant run that errors is not an assertion failure"
  promote_fixture
  # The mutant writes the stub's error marker into the checked file: under
  # it the run errors (as a test would on a syntax error).
  jset "$SIDECAR" '.claims[0].nonvacuity.mutant.replace = "STUB_ERROR"'
  git commit -qam "a mutant under which the test errors"
  cl promote "$TTL_ID"
  assert_promote_finding "mutant error is not an assertion failure" "the mutant run gives error"
  assert_eq '"unbuilt"' "$(claim_field "$TTL_ID" status)" "…the claim stays unbuilt"
  assert_eq "3" "$(stub_roots | wc -l | tr -d ' ')" "…after the green, clean-checkout and mutant runs"
  teardown
}

test_promote_requires_green_in_clean_checkout() {
  echo "test: promote — the bound test must also pass unmutated in a clean checkout of HEAD"
  promote_fixture
  local before
  # The check reads an untracked build output: present in the work tree (so
  # the green run passes), absent from the throwaway worktree at HEAD, where
  # a red under the mutant would prove nothing.
  mkdir -p build
  printf 'TTL_SECONDS = 900\n' > build/token.txt
  printf '%s\t%s\t%s\n' "$STUB_NODE" build/token.txt "TTL_SECONDS = 900" > tools/claims/checks
  git add tools/claims/checks && git commit -qm "check an untracked build output"
  before=$(hash_file "$SIDECAR")
  cl promote "$TTL_ID"
  assert_promote_finding "not green in a clean checkout" "green in the work tree only"
  assert_eq "$before" "$(hash_file "$SIDECAR")" "…the sidecar unchanged (no promotion)"
  assert_true "…no verdict stored" test ! -e "$(claims_store)"
  assert_eq "2" "$(stub_roots | wc -l | tr -d ' ')" "…no mutant run"
  assert_eq "1" "$(wt_count)" "…no worktree left"
  teardown
}

test_promote_mutant_find_not_unique_refused() {
  echo "test: promote — mutant.find must match exactly once"
  promote_fixture
  printf 'TTL_SECONDS = 900\nTTL_SECONDS = 900\n' > src/auth/token.py
  git commit -qam "the needle twice"
  cl promote "$TTL_ID"
  assert_promote_finding "matches 2 times" "find twice in the mutant file"
  assert_eq '"unbuilt"' "$(claim_field "$TTL_ID" status)" "…the claim stays unbuilt"
  printf 'TTL_SECONDS = 600\n' > src/auth/token.py
  printf '%s\t%s\t%s\n' "$STUB_NODE" src/auth/token.py "TTL_SECONDS" > tools/claims/checks
  git commit -qam "the needle gone"
  cl promote "$TTL_ID"
  assert_promote_finding "matches 0 times" "find absent from the mutant file"
  teardown
}

test_promote_mutant_literal_safe() {
  echo "test: promote — the mutation is literal: no glob, regex or backreference in find or replace"
  promote_fixture
  # shellcheck disable=SC2016  # literal text, not expansions
  local line='x = a*b[0]$\1' repl='y = \1 & $0 * [x]^' exp got
  printf 'head\n%s\ntail' "$line" > src/auth/expr.py
  printf '%s\t%s\t%s\n' "$STUB_NODE" src/auth/expr.py "$line" > tools/claims/checks
  jset "$SIDECAR" ".claims[0].nonvacuity.mutant = {file: \"src/auth/expr.py\",
    find: $(jq -Rn --arg l "$line" '$l'), replace: $(jq -Rn --arg r "$repl" '$r')}"
  git add -A && git commit -qm "a mutant full of metacharacters"
  export STUB_CAT=src/auth/expr.py
  cl promote "$TTL_ID"
  unset STUB_CAT
  assert_eq "0" "$CL_RC" "promote exits 0 (the literal find matched once, the literal replace removed the needle)"
  exp=$(harness_mktemp exp-cat)
  got=$(harness_mktemp got-cat)
  printf 'head\n%s\ntail' "$line" > "$exp"
  printf 'head\n%s\ntail' "$line" >> "$exp"
  printf 'head\n%s\ntail' "$repl" >> "$exp"
  cat "$STUB_LOG.cat" > "$got"
  assert_true "…the adapter saw the file (work tree, clean checkout), then exactly find → replace (no byte added, none lost)" cmp -s "$exp" "$got"
  assert_eq "$(printf 'head\n%s\ntail' "$line")" "$(cat src/auth/expr.py)" "…the work tree's file untouched"
  teardown
}

test_promote_requires_green_first() {
  echo "test: promote — the bound test must pass at HEAD first"
  promote_fixture
  set_ttl 1800
  git commit -qam "the subject at 1800"
  cl promote "$TTL_ID"
  assert_promote_finding "not green" "the check fails at HEAD"
  assert_eq "1" "$(stub_roots | wc -l | tr -d ' ')" "…no mutant run"
  assert_eq "1" "$(wt_count)" "…no worktree left"
  # An indeterminate green run: exit 2.
  set_ttl 900
  force "$STUB_NODE" indeterminate "runner busy"
  git commit -qam "back to 900, the stub indeterminate"
  cl promote "$TTL_ID"
  assert_eq "2" "$CL_RC" "an indeterminate green run exits 2"
  assert_eq "runner busy" "$(promote_reasons)" "…with the adapter's reason"
  assert_eq '"unbuilt"' "$(claim_field "$TTL_ID" status)" "…the claim stays unbuilt"
  teardown
}

test_promote_dirty_tree_exit_2() {
  echo "test: promote — refuses a dirty tree (exit 2, dirty-tree)"
  promote_fixture
  local before
  before=$(hash_file "$SIDECAR")
  printf '# edited\n' >> src/auth/token.py
  cl promote "$TTL_ID"
  assert_promote_dirty "an unstaged edit"
  assert_eq "" "$(cat "$STUB_LOG")" "…no adapter called"
  assert_eq "$before" "$(hash_file "$SIDECAR")" "…the sidecar unchanged"
  git add src/auth/token.py
  cl promote "$TTL_ID"
  assert_promote_dirty "a staged edit"
  git reset -q && git checkout -q -- src/auth/token.py
  # Neither an untracked file nor a change under docs/spec-claims/gates/ counts.
  mkdir -p docs/spec-claims/gates/p
  printf '{}\n' > docs/spec-claims/gates/p/chunk-1.json
  git add -A && git commit -qm "a gate record"
  printf '{"edited":true}\n' > docs/spec-claims/gates/p/chunk-1.json
  printf 'scratch\n' > notes.txt
  cl promote "$TTL_ID"
  assert_eq "0" "$CL_RC" "an untracked file and a gate-record edit: promote exits 0"
  teardown
}

test_promote_throwaway_worktree_removed() {
  echo "test: promote — the throwaway worktree is removed on every path"
  promote_fixture
  cl promote "$TTL_ID"
  assert_eq "0" "$CL_RC" "precondition: promote exits 0"
  assert_eq "1" "$(wt_count)" "after a promotion: git worktree list has 1 line"
  assert_eq "" "$(ls -A .git/worktrees 2>/dev/null)" "…and no worktree metadata is left"
  teardown
  promote_fixture
  jset "$SIDECAR" '.claims[0].nonvacuity.mutant.replace = "TTL_SECONDS = 900 "'
  git commit -qam "a mutant that keeps the needle"
  cl promote "$TTL_ID"
  assert_eq "1" "$CL_RC" "precondition: a refusal (mutant stays green)"
  assert_eq "1" "$(wt_count)" "after a refusal: git worktree list has 1 line"
  assert_eq "" "$(ls -A .git/worktrees 2>/dev/null)" "…and no worktree metadata is left"
  teardown
  promote_fixture
  # The store cannot be created (a file where its parent directory goes):
  # promote dies after the mutant run.
  printf 'x\n' > .git/spec-claims
  cl promote "$TTL_ID"
  assert_eq "2" "$CL_RC" "precondition: the store cannot be written (exit 2)"
  assert_eq "3" "$(stub_roots | wc -l | tr -d ' ')" "…after all three runs"
  assert_eq "1" "$(wt_count)" "after a failure: git worktree list has 1 line"
  assert_eq "" "$(ls -A .git/worktrees 2>/dev/null)" "…and no worktree metadata is left"
  assert_eq '"unbuilt"' "$(claim_field "$TTL_ID" status)" "…the sidecar unchanged"
  teardown
  # Another worktree whose directory looks gone (a volume not mounted) keeps
  # its registration: promote removes only its own, never prunes.
  promote_fixture
  local away
  away=$(harness_mktemp_d away)
  git worktree add -q --detach "$away/other" HEAD
  mv "$away/other" "$away/other.offline"
  cl promote "$TTL_ID"
  assert_eq "0" "$CL_RC" "precondition: promote exits 0"
  assert_contains "$(git worktree list --porcelain)" "$away/other" "…the offline worktree is still registered"
  assert_eq "2" "$(wt_count)" "…and only promote's own worktree is gone"
  mv "$away/other.offline" "$away/other"
  git worktree remove --force "$away/other"
  teardown
}

test_promote_mutant_file_unsafe() {
  echo "test: promote — a mutant file that is not a safe path inside the worktree is never written"
  promote_fixture
  local outside before
  outside=$(harness_mktemp_d outside)
  printf 'TTL_SECONDS = 900\n' > "$outside/token.py"
  jset "$SIDECAR" '.claims[0].nonvacuity.mutant.file = "../outside/token.py"'
  git commit -qam "a mutant file outside the tree"
  cl promote "$TTL_ID"
  assert_promote_finding "not a safe repo path" "mutant.file with a .. segment"
  assert_eq "0" "$(stub_roots | wc -l | tr -d ' ')" "…refused before any run"
  # Through a committed symbolic link: a safe-looking path whose directory
  # leaves the worktree.
  ln -s "$outside" src/linked
  jset "$SIDECAR" '.claims[0].nonvacuity.mutant.file = "src/linked/token.py"'
  git add -A && git commit -qm "a mutant file through a symbolic link"
  before=$(hash_file "$outside/token.py")
  cl promote "$TTL_ID"
  assert_promote_finding "not a safe repo path" "mutant.file through a symbolic link"
  assert_eq "$before" "$(hash_file "$outside/token.py")" "…the file the link reaches is not written"
  assert_eq '"unbuilt"' "$(claim_field "$TTL_ID" status)" "…the claim stays unbuilt"
  assert_eq "1" "$(wt_count)" "…no worktree left"
  teardown
}

test_promote_subject_not_at_head() {
  echo "test: promote — every subject path must be at HEAD (its blob goes into subject_oids)"
  promote_fixture
  jset "$SIDECAR" '.claims[0].subject += ["src/auth/missing.py"]'
  git commit -qam "a subject that does not exist"
  cl promote "$TTL_ID"
  assert_promote_finding "subject not at HEAD" "a subject path absent at HEAD"
  assert_contains "$(promote_messages)" "src/auth/missing.py" "…naming the path"
  teardown
}

test_promote_claim_preconditions() {
  echo "test: promote — only a test claim with a nonvacuity proof, in a promotable status"
  promote_fixture
  cl promote "SPEC-AUTH-001#nope"
  assert_eq "3" "$CL_RC" "an unknown claim id: usage error (exit 3)"
  jset "$SIDECAR" '.claims[0].nonvacuity = null'
  git commit -qam "no proof"
  cl promote "$TTL_ID"
  assert_promote_finding "nonvacuity" "no nonvacuity proof"
  jset "$SIDECAR" ".claims[0].nonvacuity = $_CL_MUTANT | .claims[0].enforced_by = \"lint\""
  git commit -qam "a lint claim"
  cl promote "$TTL_ID"
  assert_promote_finding "enforced_by" "a lint claim"
  jset "$SIDECAR" '.claims[0].enforced_by = "test" | .claims[0].test = null'
  git commit -qam "no test"
  cl promote "$TTL_ID"
  assert_promote_finding "test" "no bound test"
  jset "$SIDECAR" ".claims[0].test = $STUB_TEST | .claims[0].frozen_at = \"$(git rev-parse HEAD)\""
  git commit -qam "frozen"
  cl promote "$TTL_ID"
  assert_promote_finding "frozen" "a frozen claim"
  assert_eq "0" "$(stub_roots | wc -l | tr -d ' ')" "…no run for any of them"
  teardown
}

test_promote_second_without_commit_refused() {
  echo "test: promote — a second promote before the first is committed sees a dirty tree"
  promote_fixture
  promote_second_claim
  local digest
  cl promote "$TTL_ID"
  assert_eq "0" "$CL_RC" "the first promote exits 0"
  digest=$(jq -r '.claims[0].promotion.verdict_sha256' "$SIDECAR")
  cl promote "$REFRESH_ID"
  assert_promote_dirty "the second, the first's sidecar and doc writes uncommitted"
  assert_eq '"built"' "$(claim_field "$TTL_ID" status)" "…the first claim still built"
  assert_eq "$digest" "$(jq -r '.claims[0].promotion.verdict_sha256' "$SIDECAR")" "…its promotion intact"
  assert_file_exists "$(claims_store)/$digest.json" "…its verdict still stored"
  assert_eq '"unbuilt"' "$(claim_field "$REFRESH_ID" status)" "…the second claim still unbuilt"
  teardown
}

test_promote_twice_with_commit_between() {
  echo "test: promote — commit the first promote's writes, then the second promotes"
  promote_fixture
  promote_second_claim
  cl promote "$TTL_ID"
  assert_eq "0" "$CL_RC" "the first promote exits 0"
  git add "$SIDECAR" "$DOC" && git commit -qm "promote $TTL_ID"
  cl promote "$REFRESH_ID"
  assert_eq "0" "$CL_RC" "the second promote exits 0"
  assert_eq '"built"' "$(claim_field "$TTL_ID" status)" "…the first claim built"
  assert_eq '"built"' "$(claim_field "$REFRESH_ID" status)" "…the second claim built"
  assert_eq "$(git rev-parse HEAD)" "$(jq -r --arg id "$REFRESH_ID" '.claims[] | select(.id == $id) | .promotion.at' "$SIDECAR")" \
    "…the second's promotion.at is the commit holding the first"
  assert_contains "$(cat "$DOC")" "Claims: 2 built" "…the doc's block shows both built"
  git add "$SIDECAR" "$DOC" && git commit -qm "promote $REFRESH_ID"
  cl validate --all
  assert_eq "0" "$CL_RC" "validate --all exits 0"
  teardown
}

test_promote_built_with_ok_verdict_refused() {
  echo "test: promote — a built claim whose verdict matches is already promoted"
  promote_fixture
  cl promote "$TTL_ID"
  assert_eq "0" "$CL_RC" "the promote exits 0"
  git add "$SIDECAR" "$DOC" && git commit -qm "promote $TTL_ID"
  cl promote "$TTL_ID"
  assert_promote_finding "already promoted" "promote again"
  assert_eq "3" "$(stub_roots | wc -l | tr -d ' ')" "…no run the second time"
  teardown
}

test_repromote_after_doc_stale() {
  echo "test: promote — a DOC-STALE amendment of a built claim is re-promoted"
  promote_fixture
  local old new ss st
  cl promote "$TTL_ID"
  assert_eq "0" "$CL_RC" "the promote exits 0"
  old=$(jq -r '.claims[0].promotion.verdict_sha256' "$SIDECAR")
  git add "$SIDECAR" "$DOC" && git commit -qm "promote $TTL_ID"
  doc_stale_amend
  git add -A && git commit -qm "DOC-STALE: amend the TTL claim"
  cl validate --all
  assert_eq "0" "$CL_RC" "validate --all after the amendment exits 0"
  assert_contains "$(v6_codes)" "re-promote owed" "…with the advisory re-promote owed"
  cl promote "$TTL_ID"
  assert_eq "0" "$CL_RC" "the re-promote exits 0"
  new=$(jq -r '.claims[0].promotion.verdict_sha256' "$SIDECAR")
  assert_true "…a new promotion.verdict_sha256" test "$new" != "$old"
  st=$(harness_mktemp new-states)
  printf '%s' "$NEW_STATES" > "$st"
  ss=$(hash_file "$st")
  assert_json_field "$(cat "$(claims_store)/$new.json")" '.states_sha256' "$ss" "…the new verdict's states_sha256 is the new states'"
  assert_eq "$(git rev-parse HEAD)" "$(jq -r '.claims[0].promotion.at' "$SIDECAR")" "…promotion.at the amendment commit"
  git add "$SIDECAR" "$DOC" && git commit -qm "re-promote $TTL_ID"
  cl validate --all
  assert_eq "0" "$CL_RC" "validate --all after the re-promote exits 0"
  assert_not_contains "$(v6_codes)" "re-promote owed" "…with no re-promote owed"
  teardown
}

test_promote_mutant_not_utf8_refused() {
  echo "test: promote — a mutant file that is not UTF-8 text is refused (jq would rewrite its bytes)"
  promote_fixture
  local before
  printf 'TTL_SECONDS = 900\n# caf\351\n' > src/auth/token.py
  git commit -qam "a Latin-1 byte in the subject"
  before=$(hash_file "$SIDECAR")
  cl promote "$TTL_ID"
  assert_promote_finding "mutant file is not UTF-8 text" "a \\xe9 byte in the mutant file"
  assert_eq "$before" "$(hash_file "$SIDECAR")" "…the sidecar unchanged"
  assert_true "…no verdict stored" test ! -e "$(claims_store)"
  assert_eq "2" "$(stub_roots | wc -l | tr -d ' ')" "…no mutant run"
  teardown
}

test_promote_mutant_is_test_file_refused() {
  echo "test: promote — mutating the bound test's own file is no proof"
  promote_fixture
  jset "$SIDECAR" '.claims[0].nonvacuity.mutant.file = "tests/test_token.py"'
  git commit -qam "a mutant of the test file (the node's path)"
  cl promote "$TTL_ID"
  assert_promote_finding "the bound test's own file" "mutant.file = the node's file"
  jset "$SIDECAR" '.claims[0].test.file = "tests/ttl_check.py" | .claims[0].nonvacuity.mutant.file = "tests/ttl_check.py"'
  git commit -qam "a mutant of the test file (test.file)"
  cl promote "$TTL_ID"
  assert_promote_finding "the bound test's own file" "mutant.file = test.file"
  assert_eq "0" "$(stub_roots | wc -l | tr -d ' ')" "…refused before any run"
  teardown
}

test_v3_mutant_is_test_file() {
  echo "test: V3 — a built claim's mutant.file must not be its bound test's own file"
  claims_fixture
  stub_runner
  run_built
  cl validate --all
  assert_v3_ok "precondition: the mutant on the subject"
  mkdir -p tests
  printf 'assert TTL_SECONDS == 900\n' > tests/test_token.py
  jset "$SIDECAR" '.claims[0].nonvacuity.mutant = {file: "tests/test_token.py", find: "900", replace: "1800"}'
  cl validate --all
  assert_v3 "the bound test's own file" "mutant.file = the node's file"
  teardown
}

test_promote_mutant_file_absent_or_observed_red() {
  echo "test: promote — a mutant file absent at HEAD; an observed_red naming HEAD's parent (the same subject) proves nothing"
  promote_fixture
  jset "$SIDECAR" '.claims[0].nonvacuity.mutant.file = "src/auth/missing.py"'
  git commit -qam "a mutant file that does not exist"
  cl promote "$TTL_ID"
  assert_promote_finding "is not a file at HEAD" "mutant.file absent at HEAD"
  assert_contains "$(promote_messages)" "src/auth/missing.py" "…naming the path"
  # The subject as at HEAD is the subject at HEAD: the red run passes.
  jset "$SIDECAR" ".claims[0].nonvacuity = {\"observed_red\": \"$(git rev-parse HEAD)\"}"
  git commit -qam "an observed_red proof"
  cl promote "$TTL_ID"
  assert_promote_finding "observed_red stays green" "an observed_red-only proof naming HEAD's parent (the same subject)"
  assert_eq '"unbuilt"' "$(claim_field "$TTL_ID" status)" "…the claim stays unbuilt"
  teardown
}

test_promote_built_missing_verdict_repromotes() {
  echo "test: promote — a built claim whose verdict is missing (another clone's) is re-proved"
  promote_fixture
  local old new
  cl promote "$TTL_ID"
  assert_eq "0" "$CL_RC" "the promote exits 0"
  old=$(jq -r '.claims[0].promotion.verdict_sha256' "$SIDECAR")
  git add "$SIDECAR" "$DOC" && git commit -qm "promote $TTL_ID"
  rm -f "$(claims_store)/$old.json"
  cl promote "$TTL_ID"
  assert_eq "0" "$CL_RC" "built, the verdict missing: promote exits 0"
  new=$(jq -r '.claims[0].promotion.verdict_sha256' "$SIDECAR")
  assert_true "…a new promotion.verdict_sha256" test "$new" != "$old"
  assert_eq "$(git rev-parse HEAD)" "$(jq -r '.claims[0].promotion.at' "$SIDECAR")" "…promotion.at the current HEAD"
  assert_file_exists "$(claims_store)/$new.json" "…its verdict stored"
  assert_json_field "$CL_OUT" '.results[0].status_from' "built" "…status_from built"
  teardown
}

# --- claims promote with an observed_red proof ---------------------------------
#
# observed_red_fixture <old-ttl>: the fixture claim bound to the stub (its
# check passes while src/auth/token.py holds TTL_SECONDS = 900), the subject
# committed at TTL_SECONDS = <old-ttl> (that commit in RED_SHA), then at 900
# again with the proof nonvacuity.observed_red = RED_SHA, all committed.

observed_red_fixture() {
  claims_fixture
  bind_test "$STUB_TEST"
  set_ttl "$1"
  git add -A && git commit -qm "the subject at TTL_SECONDS = $1"
  RED_SHA=$(git rev-parse HEAD)
  set_ttl 900
  jset "$SIDECAR" ".claims[0].nonvacuity = {\"observed_red\": \"$RED_SHA\"}"
  git add -A && git commit -qm "TTL_SECONDS = 900, with its observed_red proof"
}

# The stub's run calls in $STUB_LOG (their --root lines).
stub_run_count() {
  stub_roots | wc -l | tr -d ' '
}

test_promote_observed_red_reverified() {
  echo "test: promote — observed_red: green at HEAD, an assertion failure on the subject as at <sha>"
  observed_red_fixture 1800
  local head digest store exp top
  head=$(git rev-parse HEAD)
  top=$(git rev-parse --show-toplevel)
  export STUB_CAT=src/auth/token.py
  cl promote "$TTL_ID"
  unset STUB_CAT
  assert_eq "0" "$CL_RC" "promote exits 0"
  assert_eq '"built"' "$(claim_field "$TTL_ID" status)" "…the sidecar's status is built"
  assert_eq "$head" "$(jq -r '.claims[0].promotion.at' "$SIDECAR")" "…promotion.at is HEAD"
  digest=$(jq -r '.claims[0].promotion.verdict_sha256' "$SIDECAR")
  store=$(claims_store)
  exp=$(harness_mktemp exp-verdict)
  verdict_bytes "$exp"
  assert_true "…the stored bytes are the jq -cS verdict object" cmp -s "$exp" "$store/$digest.json"
  assert_json_field "$(cat "$store/$digest.json")" '.nonvacuity | tojson' "{\"observed_red\":\"$RED_SHA\"}" \
    "…its nonvacuity the observed_red proof"
  assert_json_field "$CL_OUT" '.results[0] | [.status_from, .status_to, .green, .red] | join(" ")' \
    "unbuilt built pass assert-fail" "…one result row: unbuilt → built, green pass, red assert-fail"
  assert_eq "$top" "$(stub_roots | sed -n 1p)" "…the green run under the work tree"
  assert_true "…the clean-checkout run under another root" test "$(stub_roots | sed -n 2p)" != "$top"
  assert_eq "$(stub_roots | sed -n 2p)" "$(stub_roots | sed -n 3p)" "…the red run under that same worktree"
  assert_eq "3" "$(stub_run_count)" "…three run calls in all"
  printf 'TTL_SECONDS = 900\nTTL_SECONDS = 900\nTTL_SECONDS = 1800\n' > "$exp"
  assert_true "…the adapter saw the subject at HEAD twice (work tree, clean checkout), then as at <sha>" \
    cmp -s "$exp" "$STUB_LOG.cat"
  assert_eq "TTL_SECONDS = 900" "$(cat src/auth/token.py)" "…the work tree's subject is untouched"
  assert_eq "1" "$(wt_count)" "…no worktree left"
  cl validate --all
  assert_eq "0" "$CL_RC" "validate --all after the promote exits 0"
  teardown
}

test_promote_observed_red_passes_refused() {
  echo "test: promote — observed_red: a <sha> whose subject already passes the test is refused"
  observed_red_fixture 900
  local before
  before=$(hash_file "$SIDECAR")
  cl promote "$TTL_ID"
  assert_promote_finding "observed_red stays green" "the subject at <sha> already held TTL_SECONDS = 900"
  assert_contains "$(promote_messages)" "$RED_SHA" "…naming <sha>"
  assert_eq "$before" "$(hash_file "$SIDECAR")" "…the sidecar unchanged"
  assert_true "…no verdict stored" test ! -e "$(claims_store)"
  assert_eq "3" "$(stub_run_count)" "…after the green, clean-checkout and red runs"
  assert_eq "1" "$(wt_count)" "…no worktree left"
  teardown
  # An error on the old subject is not an assertion failure.
  observed_red_fixture 900
  printf 'STUB_ERROR\n' > src/auth/token.py
  git commit -qam "a subject the test errors on"
  RED_SHA=$(git rev-parse HEAD)
  set_ttl 900
  jset "$SIDECAR" ".claims[0].nonvacuity.observed_red = \"$RED_SHA\""
  git commit -qam "observed_red: the erroring subject"
  cl promote "$TTL_ID"
  assert_promote_finding "observed_red error is not an assertion failure" "the old subject makes the test error"
  assert_eq '"unbuilt"' "$(claim_field "$TTL_ID" status)" "…the claim stays unbuilt"
  teardown
}

test_promote_observed_red_bad_sha() {
  echo "test: promote — observed_red must be a full commit id (lowercase hex, HEAD's length) naming a commit"
  observed_red_fixture 1800
  local bad upper
  upper=$(printf '%s' "$RED_SHA" | tr 'a-f' 'A-F')
  # A ref, an abbreviation, an option, uppercase, the wrong length: never
  # resolved, so a re-verification cannot name another commit.
  for bad in 0123abc "${RED_SHA:0:12}" HEAD~1 HEAD feature main "$upper" "${RED_SHA}0" nope --all -q; do
    jset "$SIDECAR" ".claims[0].nonvacuity.observed_red = $(jq -n --arg b "$bad" '$b')"
    git commit -qam "observed_red: $bad"
    cl promote "$TTL_ID"
    assert_promote_finding "observed_red is not a full commit id" "observed_red $bad"
  done
  jset "$SIDECAR" '.claims[0].nonvacuity.observed_red = 42'
  git commit -qam "observed_red: a number"
  cl promote "$TTL_ID"
  assert_promote_finding "observed_red is not a full commit id" "observed_red 42 (not a string)"
  # A full-length lowercase hex id that is not a commit: a blob, a tree, a
  # missing object.
  for bad in "$(git rev-parse HEAD:src/auth/token.py)" "$(git rev-parse 'HEAD^{tree}')" \
      "$(printf '%s' "$RED_SHA" | tr '0-9a-f' 'e')"; do
    jset "$SIDECAR" ".claims[0].nonvacuity.observed_red = $(jq -n --arg b "$bad" '$b')"
    git commit -qam "observed_red: $bad"
    cl promote "$TTL_ID"
    assert_promote_finding "observed_red is not a commit" "observed_red $bad (full length, not a commit)"
  done
  assert_eq "0" "$(stub_run_count)" "…refused before any run"
  assert_eq '"unbuilt"' "$(claim_field "$TTL_ID" status)" "…the claim stays unbuilt"
  teardown
}

test_promote_observed_red_utf8_locale() {
  echo "test: promote — observed_red: uppercase hex is refused under a UTF-8 locale too (no collation-dependent range)"
  local loc="" l bad pad
  for l in en_US.UTF-8 C.UTF-8 en_US.utf8; do
    if [ "$(LC_ALL=$l locale charmap 2>/dev/null)" = "UTF-8" ]; then loc=$l; break; fi
  done
  if [ -z "$loc" ]; then
    record_skip "promote — observed_red under a UTF-8 locale (no en_US.UTF-8 / C.UTF-8 locale on this host)"
    return 0
  fi
  observed_red_fixture 1800
  # Bash 3.2 collates a glob bracket range by locale: under en_US.UTF-8
  # [!0-9a-f] lets a digits-then-uppercase id through. Full length (HEAD's),
  # so the hex check alone decides.
  for bad in 9434591B2DC 94345912B2DC; do
    pad=$(printf '%040d' 0)
    bad="$bad${pad:0:$((${#RED_SHA} - ${#bad}))}"
    jset "$SIDECAR" ".claims[0].nonvacuity.observed_red = $(jq -n --arg b "$bad" '$b')"
    git commit -qam "observed_red: $bad"
    LC_ALL=$loc cl promote "$TTL_ID"
    assert_promote_finding "observed_red is not a full commit id" "observed_red $bad under $loc"
  done
  assert_eq "0" "$(stub_run_count)" "…refused before any run"
  teardown
}

test_promote_observed_red_subject_absent_at_sha() {
  echo "test: promote — observed_red: a subject path absent at <sha> is removed in the worktree (test-first)"
  claims_fixture
  bind_test "$STUB_TEST"
  set_ttl 1800
  git add -A && git commit -qm "TTL_SECONDS = 1800, no helper yet"
  RED_SHA=$(git rev-parse HEAD)
  set_ttl 900
  printf 'def helper():\n    return 1\n' > src/auth/helper.py
  jset "$SIDECAR" ".claims[0].subject = [\"src/auth/token.py\", \"src/auth/helper.py\"]
    | .claims[0].nonvacuity = {\"observed_red\": \"$RED_SHA\"}"
  git add -A && git commit -qm "TTL_SECONDS = 900 and a helper, with the observed_red proof"
  local exp digest
  export STUB_CAT=src/auth/helper.py
  cl promote "$TTL_ID"
  unset STUB_CAT
  assert_eq "0" "$CL_RC" "promote exits 0 (the red run gives assert-fail)"
  assert_eq '"built"' "$(claim_field "$TTL_ID" status)" "…promoted: the sidecar's status is built"
  exp=$(harness_mktemp exp-cat)
  printf 'def helper():\n    return 1\ndef helper():\n    return 1\n' > "$exp"
  assert_true "…the helper in the work tree and the clean checkout, gone from the red run (removed, not checked out)" \
    cmp -s "$exp" "$STUB_LOG.cat"
  digest=$(jq -r '.claims[0].promotion.verdict_sha256' "$SIDECAR")
  assert_json_field "$(cat "$(claims_store)/$digest.json")" '.subject_oids | keys | join(" ")' \
    "src/auth/helper.py src/auth/token.py" "…subject_oids holds both paths at HEAD"
  assert_file_exists src/auth/helper.py "…the work tree's helper untouched"
  assert_eq "1" "$(wt_count)" "…the worktree is gone"
  assert_eq "" "$(ls -A .git/worktrees 2>/dev/null)" "…and no worktree metadata is left"
  teardown
}

test_promote_observed_red_subject_unsafe() {
  echo "test: promote — observed_red never removes or checks out a subject path outside the worktree"
  observed_red_fixture 1800
  local outside before
  outside=$(harness_mktemp_d outside)
  printf 'keep\n' > "$outside/helper.py"
  before=$(hash_file "$outside/helper.py")
  jset "$SIDECAR" '.claims[0].subject += ["../outside/helper.py"]'
  git commit -qam "a subject with a .. segment"
  cl promote "$TTL_ID"
  assert_promote_finding "not a safe repo path" "a subject with a .. segment"
  assert_eq "0" "$(stub_run_count)" "…refused before any run"
  assert_eq "$before" "$(hash_file "$outside/helper.py")" "…the file outside untouched"
  teardown
  # At <sha> src/lib is a symbolic link out of the tree; at HEAD a directory.
  # Checking the subject src/lib out as at <sha> puts the link in the
  # worktree, so src/lib/helper.py (absent at <sha>) would be removed
  # through it: the containment check refuses it first.
  claims_fixture
  bind_test "$STUB_TEST"
  outside=$(harness_mktemp_d outside)
  printf 'keep\n' > "$outside/helper.py"
  set_ttl 1800
  ln -s "$outside" src/lib
  git add -A && git commit -qm "TTL_SECONDS = 1800; src/lib a symbolic link out of the tree"
  RED_SHA=$(git rev-parse HEAD)
  set_ttl 900
  git rm -q src/lib
  mkdir -p src/lib
  printf 'def helper():\n    return 1\n' > src/lib/helper.py
  jset "$SIDECAR" ".claims[0].subject = [\"src/auth/token.py\", \"src/lib\", \"src/lib/helper.py\"]
    | .claims[0].nonvacuity = {\"observed_red\": \"$RED_SHA\"}"
  git add -A && git commit -qm "src/lib a directory, with the observed_red proof"
  before=$(hash_file "$outside/helper.py")
  cl promote "$TTL_ID"
  assert_promote_finding "subject src/lib/helper.py is not a safe repo path" "a subject reached through a symbolic link in the worktree"
  assert_file_exists "$outside/helper.py" "…the file the link reaches is not removed"
  assert_eq "$before" "$(hash_file "$outside/helper.py")" "…nor changed"
  assert_eq "helper.py" "$(ls -A "$outside")" "…and nothing is added beside it"
  assert_eq "2" "$(stub_run_count)" "…no red run"
  assert_eq '"unbuilt"' "$(claim_field "$TTL_ID" status)" "…the claim stays unbuilt"
  assert_eq "1" "$(wt_count)" "…no worktree left"
  teardown
}

test_promote_observed_red_subject_is_test_file() {
  echo "test: promote — observed_red: a subject that is (or holds) the bound test's own file is refused"
  observed_red_fixture 1800
  jset "$SIDECAR" '.claims[0].subject += ["tests/test_token.py"]'
  git commit -qam "the node's file as a subject"
  cl promote "$TTL_ID"
  assert_promote_finding "the bound test's own file" "subject = the node's file"
  jset "$SIDECAR" '.claims[0].subject = ["src/auth/token.py", "tests"]'
  git commit -qam "the test directory as a subject"
  cl promote "$TTL_ID"
  assert_promote_finding "the bound test's own file" "subject = a directory holding the node's file"
  jset "$SIDECAR" '.claims[0].test.file = "checks/ttl_check.py" | .claims[0].subject = ["src/auth/token.py", "checks/ttl_check.py"]'
  git commit -qam "test.file as a subject"
  cl promote "$TTL_ID"
  assert_promote_finding "the bound test's own file" "subject = test.file"
  # A sibling whose name only starts like the test's directory is no test file.
  jset "$SIDECAR" '.claims[0].subject = ["src/auth/token.py", "check"]'
  git commit -qam "a subject named like the test directory's prefix"
  cl promote "$TTL_ID"
  assert_promote_finding "subject not at HEAD: check" "subject = check (a name prefix, not a directory holding test.file)"
  assert_eq "0" "$(stub_run_count)" "…refused before any run"
  teardown
}

test_promote_observed_red_and_mutant_both_verified() {
  echo "test: promote — a nonvacuity with a mutant and an observed_red: both are verified, apart"
  observed_red_fixture 3600
  local top exp
  top=$(git rev-parse --show-toplevel)
  jset "$SIDECAR" ".claims[0].nonvacuity.mutant = $(jq -c '.mutant' <<<"$_CL_MUTANT")"
  git commit -qam "both proofs"
  export STUB_CAT=src/auth/token.py
  cl promote "$TTL_ID"
  unset STUB_CAT
  assert_eq "0" "$CL_RC" "promote exits 0"
  assert_eq '"built"' "$(claim_field "$TTL_ID" status)" "…built"
  assert_eq "5" "$(stub_run_count)" "…five run calls: green, then clean and red for each proof"
  assert_eq "$top" "$(stub_roots | sed -n 1p)" "…the green run under the work tree"
  assert_eq "$(stub_roots | sed -n 2p)" "$(stub_roots | sed -n 3p)" "…the mutant's clean and red runs share a worktree"
  assert_eq "$(stub_roots | sed -n 4p)" "$(stub_roots | sed -n 5p)" "…observed_red's clean and red runs share a worktree"
  assert_true "…a fresh one, not the mutant's" test "$(stub_roots | sed -n 2p)" != "$(stub_roots | sed -n 4p)"
  exp=$(harness_mktemp exp-cat)
  printf 'TTL_SECONDS = 900\nTTL_SECONDS = 900\nTTL_SECONDS = 1800\nTTL_SECONDS = 900\nTTL_SECONDS = 3600\n' \
    > "$exp"
  assert_true "…the adapter saw 900, 900, the mutant (1800), 900 again (no mutation carried over), the old subject (3600)" \
    cmp -s "$exp" "$STUB_LOG.cat"
  assert_json_field "$(cat "$(claims_store)/$(jq -r '.claims[0].promotion.verdict_sha256' "$SIDECAR")".json)" \
    '.nonvacuity | keys | join(" ")' "mutant observed_red" "…the verdict records both proofs"
  assert_eq "1" "$(wt_count)" "…no worktree left"
  teardown
  # Each must hold: a good mutant does not carry an observed_red that stays green…
  observed_red_fixture 900
  jset "$SIDECAR" ".claims[0].nonvacuity.mutant = $(jq -c '.mutant' <<<"$_CL_MUTANT")"
  git commit -qam "a good mutant, an observed_red that stays green"
  cl promote "$TTL_ID"
  assert_promote_finding "observed_red stays green" "the mutant holds, observed_red does not"
  assert_eq '"unbuilt"' "$(claim_field "$TTL_ID" status)" "…the claim stays unbuilt"
  teardown
  # …nor a good observed_red a mutant that stays green.
  observed_red_fixture 1800
  jset "$SIDECAR" ".claims[0].nonvacuity.mutant = {file: \"src/auth/token.py\", find: \"TTL_SECONDS = 900\", replace: \"TTL_SECONDS = 900 \"}"
  git commit -qam "a mutant that stays green, a good observed_red"
  cl promote "$TTL_ID"
  assert_promote_finding "mutant stays green" "observed_red holds, the mutant does not"
  assert_eq '"unbuilt"' "$(claim_field "$TTL_ID" status)" "…the claim stays unbuilt"
  teardown
}

test_v3_observed_red_subject_is_test_file() {
  echo "test: V3 — a built claim's observed_red: no subject is (or holds) its bound test's own file"
  claims_fixture
  stub_runner
  run_built
  jset "$SIDECAR" '.claims[0].nonvacuity = {"observed_red": "0123abc"}'
  cl validate --all
  assert_v3_ok "precondition: observed_red, the subject the code under test"
  jset "$SIDECAR" '.claims[0].subject += ["tests"]'
  cl validate --all
  assert_v3 "the bound test's own file" "a subject directory holding the node's file"
  jset "$SIDECAR" '.claims[0].nonvacuity = {"mutant": {"file": "src/auth/token.py", "find": "TTL_SECONDS = 900", "replace": "TTL_SECONDS = 1800"}}'
  cl validate --all
  assert_eq "0" "$(v3_messages | grep -c "the bound test's own file" || true)" "…a mutant proof swaps no subject: no such finding"
  teardown
}

# _claims_mutate itself, through a probe: literal and exactly once, the
# file's bytes kept (trailing newlines included), an empty file 0 matches.
test_mutate_exactly_once_bytes_kept() {
  echo "test: _claims_mutate — exactly once, byte for byte; an empty file matches 0 times"
  claims_fixture
  local probe f exp out
  # shellcheck disable=SC2016  # the probe's own expansions
  probe=$(claims_probe after '_claims_mutate "$CL_PROBE_FILE" "$CL_PROBE_FIND" "$CL_PROBE_REPL" || { _claims_mark_emitted 0; _claims_out "refused: $_CL_MUTATE_ERR"; exit 0; }; _claims_mark_emitted 0; _claims_out ok; exit 0')
  f="$TEST_DIR/mutate.txt"
  exp=$(harness_mktemp mutate-exp)
  printf 'a\nb\n\n' > "$f"
  out=$(CL_PROBE_FILE=$f CL_PROBE_FIND=$'b\n' CL_PROBE_REPL=$'c\n\n' "$probe" claims render </dev/null 2>/dev/null) || out="rc $?: $out"
  assert_eq "ok" "$out" "a find and replace ending in newlines: applied"
  printf 'a\nc\n\n\n' > "$exp"
  assert_true "…byte for byte (no newline added or lost)" cmp -s "$exp" "$f"
  out=$(CL_PROBE_FILE=$f CL_PROBE_FIND=$'\n' CL_PROBE_REPL=x "$probe" claims render </dev/null 2>/dev/null) || out="rc $?: $out"
  assert_eq "refused: find matches 4 times" "$out" "a find matching four times: refused, counted"
  assert_true "…the file unchanged" cmp -s "$exp" "$f"
  : > "$f"
  out=$(CL_PROBE_FILE=$f CL_PROBE_FIND=x CL_PROBE_REPL=y "$probe" claims render </dev/null 2>/dev/null) || out="rc $?: $out"
  assert_eq "refused: find matches 0 times" "$out" "an empty file: find matches 0 times"
  printf 'b\n\351\n' > "$f"
  cp "$f" "$exp"
  out=$(CL_PROBE_FILE=$f CL_PROBE_FIND=b CL_PROBE_REPL=c "$probe" claims render </dev/null 2>/dev/null) || out="rc $?: $out"
  assert_eq "refused: not UTF-8 text" "$out" "a file jq would not read back unchanged: refused"
  assert_true "…the file unchanged" cmp -s "$exp" "$f"
  teardown
}

# --- The verdict store round trip, its sharing, claims promote --reverify ------
#
# promoted_fixture: promote_fixture with the TTL claim promoted by
# `claims promote` (mutant proof) and its writes committed, so the tree is
# clean for a --reverify.

promoted_fixture() {
  promote_fixture
  cl promote "$TTL_ID"
  assert_eq "0" "$CL_RC" "promoted_fixture: promote exits 0"
  git add "$SIDECAR" "$DOC" && git commit -qm "promote $TTL_ID"
}

# The last `cl`'s results, compact JSON.
cl_results() {
  jq -c '.results' <<<"$CL_OUT" 2>/dev/null || echo invalid
}

# The verdict files in the fixture repo's store, one name per line, sorted.
store_files() {
  local d
  d=$(claims_store)
  if [ -d "$d" ]; then (cd "$d" && find . -type f -name '*.json' | sed 's|^\./||' | sort); fi
}

# assert_reverified <what>: the last `cl` stored the fixture claim's fresh
# verdict — the verdict_bytes of the claim as it stands at HEAD (head HEAD,
# status_to its status) — in the store, named by its digest.
assert_reverified() {
  local exp digest
  exp=$(harness_mktemp reverify-exp)
  verdict_bytes "$exp"
  digest=$(hash_file "$exp")
  assert_file_exists "$(claims_store)/$digest.json" "$1: the fresh verdict is in the store, named by its digest"
  assert_true "$1: …its bytes the verdict of the claim at HEAD (verdict_bytes)" \
    cmp -s "$exp" "$(claims_store)/$digest.json"
  rm -f "$exp"
}

test_verdict_round_trip_v6_accepts() {
  echo "test: verdict store — promote's verdict round-trips: V6 accepts it; a states edit mismatches it"
  promoted_fixture
  cl validate --all
  assert_v6_ok "after the promote, validate --all"
  assert_eq "" "$(v6_codes)" "…no V6 advisory: the stored verdict found and matching"
  jset "$SIDECAR" ".claims[0].states = \"$NEW_STATES\""
  cl validate --all
  assert_v6 "states changed since the merge-base without a new ruling" "states edited, no ruling"
  assert_contains "$(v6_messages)" "promotion verdict does not match the claim" "…and the verdict check reports mismatch"
  assert_eq "2" "$(v6_count)" "…two V6 findings"
  assert_not_contains "$(v6_codes)" "re-promote owed" "…not the advisory a DOC-STALE ruling earns"
  git add "$SIDECAR"
  cl validate --staged
  assert_v6 "states changed since the merge-base without a new ruling" "--staged: the same edit"
  assert_contains "$(v6_messages)" "promotion verdict does not match the claim" "--staged: …and mismatch"
  teardown
}

test_verdict_store_shared_across_worktrees() {
  echo "test: verdict store — one store for every worktree of the repo (the git common dir)"
  promoted_fixture
  local away store before
  store=$(claims_store)
  away=$(harness_mktemp_d linked)
  git worktree add -q --detach "$away/linked" HEAD
  cd "$away/linked"
  assert_eq "$store" "$(claims_store)" "a linked worktree resolves the main checkout's store"
  cl validate --all
  assert_v6_ok "validate --all in the linked worktree"
  assert_not_contains "$(v6_codes)" "unverifiable-here" "…no unverifiable-here: the main checkout's verdict is found"
  before=$(store_files | wc -l | tr -d ' ')
  cl promote --reverify --all
  assert_eq "0" "$CL_RC" "promote --reverify --all in the linked worktree exits 0"
  assert_eq "$((before + 1))" "$(store_files | wc -l | tr -d ' ')" "…its fresh verdict lands in the shared store"
  assert_reverified "in the linked worktree"
  cd "$TEST_DIR"
  git worktree remove --force "$away/linked"
  teardown
}

test_verdict_store_fresh_clone_unverifiable() {
  echo "test: verdict store — a fresh clone holds none: unverifiable-here, an advisory, rc 0"
  promoted_fixture
  local c digest
  digest=$(jq -r '.claims[0].promotion.verdict_sha256' "$SIDECAR")
  c="$(harness_mktemp_d clone)/c"
  git clone -q -b feature "$TEST_DIR" "$c"
  git -C "$c" branch -q main origin/main
  cd "$c"
  assert_true "the clone's store does not hold the verdict" test ! -e "$(claims_store)/$digest.json"
  cl validate --all
  assert_eq "0" "$CL_RC" "validate --all in the clone exits 0"
  assert_contains "$(v6_codes)" "unverifiable-here" "…an unverifiable-here advisory"
  assert_eq "0" "$(v6_count)" "…no V6 finding"
  # The scheduled run re-verifies it there: --reverify needs no stored verdict.
  cl promote --reverify --all
  assert_eq "0" "$CL_RC" "promote --reverify --all in the clone exits 0"
  assert_eq "[{\"claim\":\"$TTL_ID\",\"verdict\":\"ok\"}]" "$(cl_results)" "…the claim re-verified"
  assert_eq "1" "$(store_files | wc -l | tr -d ' ')" "…one fresh verdict in the clone's own store"
  assert_reverified "in the clone"
  cd "$TEST_DIR"
  teardown
}

test_promote_reverify_all_no_sidecar_write() {
  echo "test: promote --reverify --all — re-proves each promotion, stores a fresh verdict, writes no sidecar"
  promoted_fixture
  local sc doc old n
  sc=$(hash_file "$SIDECAR")
  doc=$(hash_file "$DOC")
  old=$(jq -r '.claims[0].promotion.verdict_sha256' "$SIDECAR")
  : > "$STUB_LOG"
  cl promote --reverify --all
  assert_eq "0" "$CL_RC" "--reverify --all exits 0"
  assert_eq "1" "$(json_count "$CL_OUT")" "…one verdict object"
  assert_eq "[{\"claim\":\"$TTL_ID\",\"verdict\":\"ok\"}]" "$(cl_results)" "…one result row {claim, verdict}"
  assert_eq "$sc" "$(hash_file "$SIDECAR")" "…the sidecar's hash unchanged"
  assert_eq "$doc" "$(hash_file "$DOC")" "…the doc's hash unchanged"
  assert_eq "" "$(git status --porcelain --untracked-files=no)" "…the tree still clean"
  assert_reverified "--reverify --all"
  assert_eq "2" "$(store_files | wc -l | tr -d ' ')" "…a fresh verdict beside the promote's (head moved: its own digest)"
  assert_file_exists "$(claims_store)/$old.json" "…the promote's verdict kept"
  assert_eq "3" "$(stub_run_count)" "…promote's three run calls: work tree, clean checkout, mutant"
  assert_eq "$(git rev-parse --show-toplevel)" "$(stub_roots | sed -n 1p)" "…the green run under the work tree"
  assert_eq "$(stub_roots | sed -n 2p)" "$(stub_roots | sed -n 3p)" "…the clean and mutant runs under one worktree"
  assert_eq "1" "$(wt_count)" "…no worktree left"
  set_ttl 1800
  git commit -qam "the TTL source changed to 1800"
  n=$(store_files | wc -l | tr -d ' ')
  cl promote --reverify --all
  assert_promote_finding "not green" "after a committed change of the source to 1800"
  assert_json_field "$CL_OUT" '.findings[0].claim' "$TTL_ID" "…the finding names the claim"
  assert_eq "[{\"claim\":\"$TTL_ID\",\"verdict\":\"finding\"}]" "$(cl_results)" "…its result row: finding"
  assert_eq "$sc" "$(hash_file "$SIDECAR")" "…the sidecar's hash still unchanged"
  assert_eq "$n" "$(store_files | wc -l | tr -d ' ')" "…no verdict stored for a failed proof"
  teardown
}

test_promote_reverify_selection() {
  echo "test: promote --reverify — --all takes the promoted claims; a named claim that is not one is a finding"
  promoted_fixture
  promote_second_claim
  local before
  : > "$STUB_LOG"
  cl promote --reverify --all
  assert_eq "0" "$CL_RC" "--all, one claim built and one unbuilt: exits 0"
  assert_eq "[{\"claim\":\"$TTL_ID\",\"verdict\":\"ok\"}]" "$(cl_results)" "…only the promoted claim is selected"
  assert_eq "3" "$(stub_run_count)" "…its three run calls only"
  : > "$STUB_LOG"
  cl promote --reverify "$REFRESH_ID"
  assert_promote_finding "not promoted" "the unbuilt claim named"
  assert_json_field "$CL_OUT" '.findings[0].claim' "$REFRESH_ID" "…the finding names the claim"
  assert_eq "[{\"claim\":\"$REFRESH_ID\",\"verdict\":\"finding\"}]" "$(cl_results)" "…its result row: finding"
  assert_eq "0" "$(stub_run_count)" "…nothing run"
  cl promote --reverify "$TTL_ID" "$REFRESH_ID"
  assert_eq "1" "$CL_RC" "both named: exits 1"
  assert_eq "[{\"claim\":\"$TTL_ID\",\"verdict\":\"ok\"},{\"claim\":\"$REFRESH_ID\",\"verdict\":\"finding\"}]" \
    "$(cl_results)" "…one row per named claim, in order"
  : > "$STUB_LOG"
  before=$(store_files)
  cl promote --reverify "$TTL_ID" nope
  assert_eq "3" "$CL_RC" "an unknown id among the named: a usage error"
  assert_eq "0" "$(stub_run_count)" "…found before anything runs"
  assert_eq "$before" "$(store_files)" "…no verdict stored"
  # A dirty tree is refused (an untracked file does not count).
  printf 'TTL_SECONDS = 901\n' > src/auth/token.py
  printf 'x\n' > untracked.txt
  cl promote --reverify --all
  assert_promote_dirty "--reverify, the subject edited"
  assert_eq "0" "$(stub_run_count)" "…nothing run"
  git checkout -q -- src/auth/token.py
  rm -f untracked.txt
  # A gated claim with a promotion: its fresh verdict's status_to is gated.
  jset "$SIDECAR" '.claims[0].status = "gated"'
  git commit -qam "the TTL claim gated"
  cl promote --reverify --all
  assert_eq "0" "$CL_RC" "--all, the claim gated: exits 0"
  assert_eq "[{\"claim\":\"$TTL_ID\",\"verdict\":\"ok\"}]" "$(cl_results)" "…the gated claim selected"
  assert_reverified "gated"
  # A frozen claim is never run: --all reports it skipped; named, it is a finding.
  jset "$SIDECAR" ".claims[0].frozen_at = \"$(git rev-parse HEAD)\""
  git commit -qam "the TTL claim frozen"
  : > "$STUB_LOG"
  cl promote --reverify --all
  assert_eq "0" "$CL_RC" "--all, the claim frozen: exits 0"
  assert_eq "[{\"claim\":\"$TTL_ID\",\"verdict\":\"skipped\"}]" "$(cl_results)" "…reported skipped"
  cl promote --reverify "$TTL_ID"
  assert_promote_finding "frozen" "the frozen claim named"
  assert_eq "0" "$(stub_run_count)" "…nothing run"
  teardown
}

test_promote_reverify_same_proof_path() {
  echo "test: promote --reverify — promote's proof path: clean-checkout green, each proof, every guard"
  observed_red_fixture 1800
  local top exp sc
  cl promote "$TTL_ID"
  assert_eq "0" "$CL_RC" "precondition: the observed_red promote exits 0"
  git add "$SIDECAR" "$DOC" && git commit -qm "promote $TTL_ID"
  top=$(git rev-parse --show-toplevel)
  : > "$STUB_LOG"
  rm -f "$STUB_LOG.cat"
  export STUB_CAT=src/auth/token.py
  cl promote --reverify "$TTL_ID"
  unset STUB_CAT
  assert_eq "0" "$CL_RC" "observed_red re-verified: exits 0"
  assert_eq "3" "$(stub_run_count)" "…three run calls"
  assert_eq "$top" "$(stub_roots | sed -n 1p)" "…the green run under the work tree"
  assert_true "…the clean-checkout run under another root" test "$(stub_roots | sed -n 2p)" != "$top"
  assert_eq "$(stub_roots | sed -n 2p)" "$(stub_roots | sed -n 3p)" "…the red run under that same worktree"
  exp=$(harness_mktemp exp-cat)
  printf 'TTL_SECONDS = 900\nTTL_SECONDS = 900\nTTL_SECONDS = 1800\n' > "$exp"
  assert_true "…the adapter saw the subject at HEAD twice, then as at observed_red" cmp -s "$exp" "$STUB_LOG.cat"
  assert_reverified "observed_red"
  assert_eq "1" "$(wt_count)" "…no worktree left"
  assert_eq "" "$(ls -A .git/worktrees 2>/dev/null)" "…and no worktree metadata"
  # The observed_red must stay a full commit id.
  jset "$SIDECAR" ".claims[0].nonvacuity.observed_red = \"${RED_SHA:0:12}\""
  git commit -qam "observed_red abbreviated"
  : > "$STUB_LOG"
  cl promote --reverify --all
  assert_promote_finding "observed_red is not a full commit id" "an abbreviated observed_red"
  assert_eq "0" "$(stub_run_count)" "…nothing run"
  teardown
  # The mutant file must still be UTF-8 text.
  promoted_fixture
  printf 'TTL_SECONDS = 900\n# caf\351\n' > src/auth/token.py
  git commit -qam "a Latin-1 byte in the subject"
  sc=$(hash_file "$SIDECAR")
  cl promote --reverify --all
  assert_promote_finding "mutant file is not UTF-8 text" "a \\xe9 byte in the mutant file"
  assert_eq "[{\"claim\":\"$TTL_ID\",\"verdict\":\"finding\"}]" "$(cl_results)" "…its result row: finding"
  assert_eq "$sc" "$(hash_file "$SIDECAR")" "…the sidecar unchanged"
  assert_eq "1" "$(wt_count)" "…no worktree left"
  teardown
  # Green in the work tree only (the check reads an untracked file).
  promoted_fixture
  printf '%s\t%s\t%s\n' "$STUB_NODE" build/out.txt "TTL_SECONDS = 900" > tools/claims/checks
  git commit -qam "the check reads build output"
  mkdir -p build
  printf 'TTL_SECONDS = 900\n' > build/out.txt
  cl promote --reverify --all
  assert_promote_finding "not green in a clean checkout" "the needle only in an untracked file"
  teardown
  # A mutant that no longer fails the test.
  promoted_fixture
  jset "$SIDECAR" '.claims[0].nonvacuity.mutant.replace = "TTL_SECONDS = 900 "'
  git commit -qam "a mutant that keeps the needle"
  cl promote --reverify --all
  assert_promote_finding "mutant stays green" "a mutant under which the test passes"
  teardown
  # An indeterminate run exits 2.
  promoted_fixture
  force "$STUB_NODE" indeterminate stub-offline
  git commit -qam "the runner offline"
  cl promote --reverify --all
  assert_eq "2" "$CL_RC" "an indeterminate green run: exits 2"
  assert_eq "stub-offline" "$(promote_reasons)" "…its reason reported"
  assert_eq "[{\"claim\":\"$TTL_ID\",\"verdict\":\"indeterminate\"}]" "$(cl_results)" "…its result row: indeterminate"
  teardown
}

# --- V12 plan structure -----------------------------------------------------------
#
# The fixture plan, docs/superpowers/plans/2026-01-01-ttl.md, is assembled
# from named blocks (plan_write), its `### Task` headings numbered in order,
# so a test removes, moves or alters one element by listing other blocks.
# The default plan has two chunks: chunk 1 builds the fixture claim (a
# Claims line naming it, src/auth/token.py modified), chunk 2 documents it
# (Claims none); each chunk carries its claims gate before its spec-update
# task, and the last ends with the final gate before the finalize task. The
# Specs lists name the fixture spec as target, as spec-inject writes them.

PLAN=docs/superpowers/plans/2026-01-01-ttl.md
PLAN_STEM=2026-01-01-ttl
# shellcheck disable=SC2034  # read by plan_write callers
PLAN_DEFAULT="head chunk1 impl1 gate1 update chunk2 impl2 gate2 update final finalize"
_PLAN_TASK=0

# plan_task <title>: the next `### Task N: <title>` heading.
plan_task() {
  _PLAN_TASK=$((_PLAN_TASK + 1))
  printf '\n### Task %s: %s\n\n' "$_PLAN_TASK" "$1"
}

# plan_specs: an injected Specs list naming the fixture spec as $PLAN_ROLE
# (default target).
plan_specs() {
  printf '%s\n' '**Specs** (roles copied from `--specs`; `infer` = resolve against `git diff` when this task runs):'
  printf -- '- docs/specs/SPEC-AUTH-001-token.md — %s\n\n' "${PLAN_ROLE:-target}"
}

# shellcheck disable=SC2016  # Markdown backticks, not command substitution
plan_block() {
  case "$1" in
    head)
      printf '# Token TTL Implementation Plan\n\n**Goal:** Build the 15-minute access-token expiry.\n\n**Spec:** docs/specs/SPEC-AUTH-001-token.md\n\n---\n' ;;
    completed) printf '\n**Status**: Completed\n' ;;
    chunk1) printf '\n## Chunk 1: Expiry\n' ;;
    chunk2) printf '\n## Chunk 2: Docs\n' ;;
    impl1|impl1_noclaims)
      plan_task "Expire access tokens"
      printf '**Files:**\n- Modify: `src/auth/token.py:1-1`\n- Test: `tests/unit/test_token.py`\n\n'
      if [ "$1" = impl1 ]; then printf '**Claims:** SPEC-AUTH-001#token-ttl\n\n'; fi
      printf -- '- [ ] **Step 1: Write the failing test**\n' ;;
    impl2)
      plan_task "Document the expiry"
      printf '**Files:**\n- Modify: `docs/guides/tokens.md`\n\n**Claims:** none — documentation only\n' ;;
    impl_code_noclaims)
      plan_task "Tidy the token module"
      printf '**Files:**\n- Modify: `src/auth/token.py`\n' ;;
    impl_none_link)
      plan_task "Refactor the token module"
      printf '**Files:**\n- Modify: `src/auth/token.py`\n\n**Claims:** none — refactor\n\nThe approach is in docs/issues/token-ttl.md.\n' ;;
    amendment)
      plan_task "Land the spec amendment for docs/specs/SPEC-AUTH-001-token.md"
      printf -- '- [ ] **Step 1: Write the AMENDED block**\n' ;;
    impl_docs_prose)
      plan_task "Describe the expiry in the guide"
      printf '**Files:**\n- Modify: `docs/guides/tokens.md` (mirrors `src/auth/token.py`)\n' ;;
    gate1|gate2)
      plan_task "Claims gate (chunk ${1#gate})"
      printf -- '- [ ] **Step 1: Run the claims gate**\n' ;;
    update|update_nospecs)
      plan_task "Update governing specs for this chunk"
      if [ "$1" = update ]; then plan_specs; fi
      printf -- '- [ ] **Step 1: Update spec status (guarded)**\n' ;;
    final)
      plan_task "Final claims gate"
      printf -- '- [ ] **Step 1: Attest the final gate**\n' ;;
    finalize|finalize_nospecs)
      plan_task "Finalize all governing specs"
      if [ "$1" = finalize ]; then plan_specs; fi
      printf -- '- [ ] **Step 1: Advance implemented specs (scope-gated)**\n' ;;
    fenced_gate1)
      printf '\nAn example of an injected gate:\n\n```markdown\n### Task 9: Claims gate (chunk 1)\n```\n' ;;
    nested_gate1)
      # A ``` line inside a ```` fence is content: a bare toggle would close
      # the fence there and read the heading after it.
      printf '\nA template quoting a fence:\n\n````markdown\n```\n### Task 9: Claims gate (chunk 1)\n```\n````\n' ;;
    tilde_gate1)
      # A ~~~ line inside a ~~~~ fence is content (shorter run).
      printf '\nA template quoting a tilde fence:\n\n~~~~markdown\n~~~\n### Task 9: Claims gate (chunk 1)\n~~~~\n' ;;
    mixed_gate1)
      # A ~~~ line does not close a ``` fence (another character).
      printf '\nA template quoting both:\n\n```markdown\n~~~\n### Task 9: Claims gate (chunk 1)\n~~~\n```\n' ;;
    *) echo "plan_block: unknown block $1" >&2; return 1 ;;
  esac
}

# plan_write [<path>] -- <block>…: write the plan (default $PLAN) from blocks.
plan_write() {
  local path="$PLAN"
  if [ "$1" != -- ]; then path="$1"; shift; fi
  shift
  mkdir -p "$(dirname "$path")"
  _PLAN_TASK=0
  {
    local b
    for b in "$@"; do plan_block "$b"; done
  } > "$path"
}

# The last `cl`'s V12 finding messages, one per line, and their count.
v12_messages() {
  jq -r '.findings[]? | select(.check == "V12") | .message' <<<"$CL_OUT" 2>/dev/null || true
}
v12_count() {
  jq '[.findings[]?, .advisories[]? | select(.check == "V12")] | length' <<<"$CL_OUT" 2>/dev/null || echo invalid
}

# assert_v12 <substring> <what>: the last `cl` exited 1 with a V12 finding
# whose message contains <substring>.
assert_v12() {
  assert_eq "1" "$CL_RC" "$2: exits 1"
  assert_contains "$(v12_messages)" "$1" "$2: a V12 finding names '$1'"
}

# assert_v12_ok <what>: the last `cl` exited 0 with no V12 row.
assert_v12_ok() {
  assert_eq "0" "$CL_RC" "$1: exits 0"
  assert_eq "0" "$(v12_count)" "$1: no V12 finding"
}

# v12_staged <block>…: the fixture with the plan written from <block>…,
# staged, and `validate --staged` run.
v12_staged() {
  claims_fixture
  plan_write -- "$@"
  git add "$PLAN"
  cl validate --staged
}

# final_record <head> [result]: a committed-shape final gate record of the
# fixture plan (attest --final arrives in Task 17; R7).
final_record() {
  mkdir -p "docs/spec-claims/gates/$PLAN_STEM"
  jq -n --arg head "$1" --arg result "${2:-pass}" '{result: $result, head: $head}' \
    > "docs/spec-claims/gates/$PLAN_STEM/final.json"
}

test_v12_well_formed_plan_passes() {
  echo "test: V12 — a well-formed plan passes"
  # shellcheck disable=SC2086  # the block list splits on spaces
  v12_staged $PLAN_DEFAULT
  assert_v12_ok "the default plan, staged"
  cl validate --all
  assert_v12_ok "the default plan, --all"
  teardown
}

test_v12_chunk_without_gate() {
  echo "test: V12 — a chunk without its claims gate"
  v12_staged head chunk1 impl1 gate1 update chunk2 impl2 update final finalize
  assert_v12 "chunk 2: no claims gate before the spec-update task" "chunk 2's gate deleted"
  assert_not_contains "$(v12_messages)" "chunk 1" "…chunk 1 is not named"
  # A gate numbered for another chunk is not this chunk's gate.
  plan_write -- head chunk1 impl1 gate1 update chunk2 impl2 gate1 update final finalize
  git add "$PLAN"
  cl validate --staged
  assert_v12 "chunk 2: no claims gate" "chunk 2 carrying chunk 1's gate"
  teardown
}

test_v12_gate_after_spec_update() {
  echo "test: V12 — a claims gate after its spec-update task"
  v12_staged head chunk1 impl1 update gate1 chunk2 impl2 gate2 update final finalize
  assert_v12 "chunk 1: no claims gate before" "chunk 1's gate moved after its spec-update task"
  teardown
}

test_v12_no_final_gate() {
  echo "test: V12 — no final claims gate before the finalize task"
  v12_staged head chunk1 impl1 gate1 update chunk2 impl2 gate2 update finalize
  assert_v12 "final claims gate" "the final gate deleted"
  plan_write -- head chunk1 impl1 gate1 update chunk2 impl2 gate2 update finalize final
  git add "$PLAN"
  cl validate --staged
  assert_v12 "final claims gate" "the final gate after the finalize task"
  teardown
}

test_v12_unbuilt_target_claim_unnamed() {
  echo "test: V12 — an unbuilt claim of a target spec named on no Claims line"
  v12_staged head chunk1 impl1_noclaims gate1 update chunk2 impl2 gate2 update final finalize
  assert_v12 "SPEC-AUTH-001#token-ttl" "the Claims line naming the claim deleted"
  teardown
}

test_v12_code_task_without_claims_line() {
  echo "test: V12 — an impl task changing code without a Claims line"
  v12_staged head chunk1 impl1 gate1 update chunk2 impl2 impl_code_noclaims gate2 update final finalize
  assert_v12 "no **Claims:** line" "a task modifying src/auth/token.py without Claims"
  assert_contains "$(v12_messages)" "Tidy the token module" "…the finding names the task"
  assert_contains "$(v12_messages)" "src/auth/token.py" "…and its code path"
  # With code_roots set, a path outside them is not code.
  jset docs/spec-claims/config.json '.code_roots = ["lib/"]'
  git add docs/spec-claims/config.json
  cl validate --staged
  assert_eq "0" "$(v12_count)" "code_roots [lib/]: src/auth/token.py is not code, no V12 finding"
  teardown
}

test_v12_claims_none_linking_issue() {
  echo "test: V12 — a Claims none task linking an issue as its source"
  v12_staged head chunk1 impl1 gate1 update chunk2 impl2 impl_none_link gate2 update final finalize
  assert_v12 "promote the decision into a governing doc" "Claims none plus a docs/issues/ link"
  assert_contains "$(v12_messages)" "docs/issues/token-ttl.md" "…the finding names the link"
  teardown
}

test_v12_completed_without_final_record() {
  echo "test: V12 — a plan moving to Completed without a final gate record"
  v12_staged head completed chunk1 impl1 gate1 update chunk2 impl2 gate2 update final finalize
  assert_v12 "final gate" "**Status**: Completed with no final.json"
  assert_contains "$(v12_messages)" "docs/spec-claims/gates/$PLAN_STEM/final.json" "…naming the record's path"
  teardown
}

test_v12_plan_without_governing_specs_exempt() {
  echo "test: V12 — a plan without governing specs is exempt"
  # No Specs list anywhere, and chunk 2's gate and the final gate missing:
  # each would be a finding in a plan with governing specs.
  v12_staged head chunk1 impl1_noclaims gate1 update_nospecs chunk2 impl2 update_nospecs finalize_nospecs
  assert_v12_ok "every Specs list stripped"
  teardown
}

test_v12_legacy_plan_without_gates_exempt() {
  echo "test: V12 — a pre-claims plan (on main before the branch point, no gate tasks) edited later is exempt"
  claims_fixture
  plan_write -- head chunk1 impl1 update chunk2 impl2 update finalize
  base_here "a pre-claims plan"
  printf '\nOne more note.\n' >> "$PLAN"
  git add "$PLAN"
  cl validate --staged
  assert_v12_ok "the legacy plan edited on feature"
  cl validate --all
  assert_v12_ok "…and under --all"
  # The same plan, new on the branch, is checked.
  cp "$PLAN" docs/superpowers/plans/2026-01-02-copy.md
  git add docs/superpowers/plans/2026-01-02-copy.md
  cl validate --staged
  assert_v12 "chunk 1: no claims gate" "the same plan added on feature"
  teardown
}

test_v12_fenced_example_ignored() {
  echo "test: V12 — a gate heading inside a code fence is not a task"
  v12_staged head chunk1 impl1 fenced_gate1 update chunk2 impl2 gate2 update final finalize
  assert_v12 "chunk 1: no claims gate" "a fenced gate heading only"
  teardown
}

test_v12_nested_fence_ignored() {
  echo "test: V12 — a gate heading after a \`\`\` line inside a \`\`\`\` fence is still fenced"
  v12_staged head chunk1 impl1 nested_gate1 update chunk2 impl2 gate2 update final finalize
  assert_v12 "chunk 1: no claims gate" "a gate heading inside a nested fence"
  teardown
}

test_v12_fence_pairing_ignored() {
  echo "test: V12 — fences pair as in CommonMark: a shorter run, or another character, does not close"
  v12_staged head chunk1 impl1 tilde_gate1 update chunk2 impl2 gate2 update final finalize
  assert_v12 "chunk 1: no claims gate" "a gate heading inside a ~~~~ fence holding a ~~~ line"
  plan_write -- head chunk1 impl1 mixed_gate1 update chunk2 impl2 gate2 update final finalize
  git add "$PLAN"
  cl validate --staged
  assert_v12 "chunk 1: no claims gate" "a gate heading inside a \`\`\` fence holding ~~~ lines"
  teardown
}

test_v12_chunkless_plan_gate_immediately_precedes() {
  echo "test: V12 — a chunkless plan: the gate immediately precedes each spec-update task"
  v12_staged head impl1 gate1 update impl2 update gate2 final finalize
  assert_v12 "chunk 2: the claims gate must immediately precede the spec-update task" "chunk 2's gate after its spec-update task"
  assert_not_contains "$(v12_messages)" "chunk 1" "…chunk 1 is not named"
  plan_write -- head impl1 gate1 update impl2 gate2 update final finalize
  git add "$PLAN"
  cl validate --staged
  assert_v12_ok "chunk 2 reordered"
  # Before the spec-update task is not enough: the gate must be the task
  # right above it.
  plan_write -- head impl1 gate1 update impl2 gate2 amendment update final finalize
  git add "$PLAN"
  cl validate --staged
  assert_v12 "chunk 2: the claims gate must immediately precede the spec-update task" "chunk 2's gate, then an amendment task, then the spec-update task"
  teardown
}

test_v12_completed_after_base_merge_ok() {
  echo "test: V12 — Completed after merging the base (which gained a code commit) into the branch"
  claims_fixture
  # shellcheck disable=SC2086  # the block list splits on spaces
  plan_write -- $PLAN_DEFAULT
  git add "$PLAN" && git commit -qm "the plan"
  final_record "$(git rev-parse HEAD)"
  git add docs/spec-claims/gates && git commit -qm "the final gate record"
  git checkout -q main
  printf 'CLOCK_SKEW = 5\n' > src/auth/clock.py
  git add src/auth/clock.py && git commit -qm "trunk: a code change"
  git checkout -q feature
  git merge -q --no-edit main
  # shellcheck disable=SC2086
  plan_write -- head completed ${PLAN_DEFAULT#head }
  git add "$PLAN"
  cl validate --staged
  assert_v12_ok "the merge and trunk's code commit are not this plan's"
  git commit -qm "the plan completed"
  cl validate --all
  assert_v12_ok "…committed, under --all"
  # A code commit of the branch's own after the final gate is a finding.
  printf 'TTL_SECONDS = 901\n' > src/auth/token.py
  git commit -qam "a code change after the final gate"
  cl validate --all
  assert_v12 "after the final gate" "a non-merge code commit after the gate"
  assert_contains "$(v12_messages)" "src/auth/token.py" "…naming its code path"
  teardown
}

test_v12_final_record_checked() {
  echo "test: V12 — the final gate record must pass, its head be an ancestor of HEAD, and the commit change no code"
  claims_fixture
  # shellcheck disable=SC2086  # the block list splits on spaces
  plan_write -- $PLAN_DEFAULT
  git add "$PLAN" && git commit -qm "the plan"
  local gated
  gated=$(git rev-parse HEAD)
  final_record "$gated" fail
  # shellcheck disable=SC2086
  plan_write -- head completed ${PLAN_DEFAULT#head }
  git add -A
  cl validate --staged
  assert_v12 "final gate" "a record whose result is fail"
  assert_contains "$(v12_messages)" "fail" "…naming the result"
  final_record "$(git commit-tree -m elsewhere "HEAD^{tree}")"
  git add -A
  cl validate --staged
  assert_v12 "is not an ancestor of HEAD" "a record whose head is off the branch"
  final_record "$gated"
  printf 'TTL_SECONDS = 901\n' > src/auth/token.py
  git add -A
  cl validate --staged
  assert_v12 "after the final gate" "a staged code change in the completing commit"
  git restore --staged --worktree src/auth/token.py
  cl validate --staged
  assert_v12_ok "the passing record alone"
  teardown
}

test_v12_final_record_malformed() {
  echo "test: V12 — a final gate record that is not one object with a commit head is a finding"
  claims_fixture
  # shellcheck disable=SC2086  # the block list splits on spaces
  plan_write -- $PLAN_DEFAULT
  git add "$PLAN" && git commit -qm "the plan"
  local gated v
  gated=$(git rev-parse HEAD)
  # shellcheck disable=SC2086
  plan_write -- head completed ${PLAN_DEFAULT#head }
  mkdir -p "docs/spec-claims/gates/$PLAN_STEM"
  for v in 'not json at all' '[1, 2]' '{"result":"pass"}{"result":"pass"}'; do
    printf '%s\n' "$v" > "docs/spec-claims/gates/$PLAN_STEM/final.json"
    git add -A
    cl validate --staged
    assert_v12 "is not one JSON object" "the record $v"
  done
  for v in '{"result":"pass"}' '{"result":"pass","head":"zzz"}' '{"result":"pass","head":7}'; do
    printf '%s\n' "$v" > "docs/spec-claims/gates/$PLAN_STEM/final.json"
    git add -A
    cl validate --staged
    assert_v12 "names no commit head" "the record $v"
  done
  printf '{"result":"pass","head":"%s"}\n' "$gated" > "docs/spec-claims/gates/$PLAN_STEM/final.json"
  git add -A
  cl validate --staged
  assert_v12_ok "a passing record whose head is a commit of the branch"
  teardown
}

test_v12_final_record_unsafe_path() {
  echo "test: V12 — the final gate record is read only through a safe path inside the work tree"
  claims_fixture
  evil_outside
  local gated
  # shellcheck disable=SC2086  # the block list splits on spaces
  plan_write -- $PLAN_DEFAULT
  git add -A && git commit -qm "the plan"
  gated=$(git rev-parse HEAD)
  # shellcheck disable=SC2086
  plan_write -- head completed ${PLAN_DEFAULT#head }
  # A passing record, but only through a symlinked gates directory.
  mkdir -p "$EVIL_DIR/$PLAN_STEM"
  jq -n --arg head "$gated" '{result: "pass", head: $head}' > "$EVIL_DIR/$PLAN_STEM/final.json"
  ln -s "$EVIL_DIR" docs/spec-claims/gates
  cl validate --all
  assert_v12 "final gate" "the gates directory is a symlink to a passing record outside the work tree"
  assert_contains "$(v12_messages)" "docs/spec-claims/gates/$PLAN_STEM/final.json" "…naming the record's path"
  rm docs/spec-claims/gates
  final_record "$gated"
  cl validate --all
  assert_v12_ok "the same record in the work tree"
  # A plan named ...md has the stem "..": its record path leaves the gates directory.
  cp "$PLAN" "docs/superpowers/plans/...md"
  jq -n --arg head "$gated" '{result: "pass", head: $head}' > docs/spec-claims/final.json
  rm -r "docs/spec-claims/gates/$PLAN_STEM"
  git rm -q --cached "$PLAN" 2>/dev/null || true
  rm -f "$PLAN"
  cl validate --all
  assert_v12 "not a safe" "a plan whose stem is .. (record path docs/spec-claims/gates/../final.json)"
  teardown
}

test_v12_symlinked_plan_skipped() {
  echo "test: V12 — under --all a plan reached through a symbolic link is skipped, never read"
  claims_fixture
  evil_outside
  # A plan outside the work tree that would be a finding (no gate tasks, new).
  plan_write "$EVIL_DIR/2026-01-09-link.md" -- head chunk1 impl1 update chunk2 impl2 update finalize
  mkdir -p docs/superpowers/plans
  ln -s "$EVIL_DIR/2026-01-09-link.md" docs/superpowers/plans/2026-01-09-link.md
  cl validate --all
  assert_v12_ok "a plan that is a symlink to a file outside the work tree"
  rm docs/superpowers/plans/2026-01-09-link.md
  # The same plan as a regular file is checked.
  cp "$EVIL_DIR/2026-01-09-link.md" docs/superpowers/plans/2026-01-09-link.md
  cl validate --all
  assert_v12 "chunk 1: no claims gate" "the same plan as a regular file"
  teardown
}

test_v12_files_line_first_path_only() {
  echo "test: V12 — a Files line names its first backticked path; prose after it is not a file"
  claims_fixture
  local json
  v12_staged head chunk1 impl1 gate1 update chunk2 impl_docs_prose gate2 update final finalize
  assert_v12_ok "a docs task whose Files line mentions src/auth/token.py in prose"
  json=$(parse_plan "$PLAN" all)
  assert_json_field "$json" '.chunks[1].tasks[0].files | tojson' '["docs/guides/tokens.md"]' "files: the first backticked path only"
  teardown
}

test_v12_completed_at_base_exempt_from_every_check() {
  echo "test: V12 — a plan completed at the merge-base is history: none of its checks run, edited or not"
  claims_fixture
  # Completed on main before the branch point, with no final.json, and not
  # naming the fixture's unbuilt target claim (the claim a later feature added).
  # shellcheck disable=SC2086  # the block list splits on spaces
  plan_write -- head completed chunk1 impl1_noclaims gate1 update chunk2 impl2 update finalize
  base_here "a completed plan that names no claim"
  cl validate --all
  assert_v12_ok "validate --all on feature"
  printf '\nA typo fix.\n' >> "$PLAN"
  git add "$PLAN"
  cl validate --staged
  assert_v12_ok "…after a one-line edit, staged"
  # The same text, new on the branch, is judged (the control).
  cp "$PLAN" docs/superpowers/plans/2026-01-02-copy.md
  git add docs/superpowers/plans/2026-01-02-copy.md
  cl validate --staged
  assert_v12 "SPEC-AUTH-001#token-ttl" "the same plan added on feature"
  teardown
}

test_v12_historical_completed_plan_not_finding() {
  echo "test: V12 — a plan Completed on main before the branch point is history"
  claims_fixture
  # shellcheck disable=SC2086  # the block list splits on spaces
  plan_write -- head completed ${PLAN_DEFAULT#head }
  base_here "a completed plan"
  cl validate --all
  assert_v12_ok "no final.json, validate --all on feature"
  printf '\nA later note.\n' >> "$PLAN"
  git add "$PLAN"
  cl validate --staged
  assert_v12_ok "…edited and staged"
  # The same plan, new on the branch, moves to Completed here.
  cp "$PLAN" docs/superpowers/plans/2026-01-02-copy.md
  cl validate --all
  assert_v12 "final gate" "the same completed plan added on feature"
  teardown
}

test_v12_base_unresolvable_gate_carrying_only() {
  echo "test: V12 — with the base unresolvable, only a gate-carrying plan is checked, and not its move to Completed"
  claims_fixture
  jset docs/spec-claims/config.json '.base = "no-such-ref"'
  git add docs/spec-claims/config.json
  # No gate task: newness is unknown, so it is not checked.
  plan_write -- head completed chunk1 impl1 update chunk2 impl2 update finalize
  git add "$PLAN"
  cl validate --staged
  assert_eq "2" "$CL_RC" "a plan without gates: exits 2 (base-unresolvable)"
  assert_eq "0" "$(v12_count)" "…no V12 finding"
  # Gate-carrying: checked (a finding wins over the indeterminate), but its
  # move to Completed cannot be judged without the base.
  plan_write -- head completed chunk1 impl1 gate1 update chunk2 impl2 update final finalize
  git add "$PLAN"
  cl validate --staged
  assert_v12 "chunk 2: no claims gate" "a gate-carrying plan"
  assert_not_contains "$(v12_messages)" "final gate record" "…its move to Completed is not judged"
  teardown
}

# --- V6 direction policy (Task 15) ----------------------------------------------

POLICY_CHUNK_REC=docs/spec-claims/gates/$PLAN_STEM/chunk-1.json
POLICY_FINAL_REC=docs/spec-claims/gates/$PLAN_STEM/final.json

# policy_fixture <role> [<record>]: the fixture, the default plan listing the
# fixture spec as <role>, the gate record file <record> (default chunk 1's),
# and a new DOC-STALE ruling that names it. Nothing is staged or committed.
policy_fixture() {
  local role="$1" rec="${2:-$POLICY_CHUNK_REC}"
  claims_fixture
  policy_plan "$role"
  policy_record "$rec"
}

# policy_plan <role>: (re)write the default plan with the spec listed as <role>.
policy_plan() {
  PLAN_ROLE="$1"
  # shellcheck disable=SC2086  # the block list splits on spaces
  plan_write -- $PLAN_DEFAULT
  unset PLAN_ROLE
}

# policy_record <record>: the file <record>, and the fixture ruling naming it.
policy_record() {
  mkdir -p "$(dirname "$1")"
  printf '{"result":"pass"}\n' > "$1"
  jset "$SIDECAR" ".claims[0].rulings = [$_CL_DOC_STALE] | .claims[0].rulings[0].record = \"$1\""
}

test_v6_in_plan_ruling_requires_gate_record_of_listing_plan() {
  echo "test: V6 — a ruling on a gate record needs a plan that lists the doc as target, infer or amends"
  policy_fixture constraint
  cl validate --all
  assert_v6 "gate record of a plan that does not govern $DOC" "--all: the plan lists the spec as constraint"
  git add -A
  cl validate --staged
  assert_v6 "gate record of a plan that does not govern $DOC" "--staged: the same"
  policy_plan target
  cl validate --all
  assert_v6_ok "--all: the plan lists the spec as target"
  git add -A
  cl validate --staged
  assert_v6_ok "--staged: the same"
  policy_plan amends
  cl validate --all
  assert_v6_ok "--all: the plan lists the spec as amends"
  # The record of a stem no plan has.
  policy_plan target
  policy_record "docs/spec-claims/gates/2026-02-02-other/chunk-3.json"
  cl validate --all
  assert_v6 "gate record of a plan that does not govern $DOC" "a gate record of a plan that is not there"
  # A plan that exists but does not list the doc at all.
  policy_record "$POLICY_CHUNK_REC"
  plan_write -- head chunk1 impl2 gate1 update_nospecs
  cl validate --all
  assert_v6 "gate record of a plan that does not govern $DOC" "the plan lists no governing specs"
  teardown
}

test_v6_in_plan_ruling_infer_role_ok() {
  echo "test: V6 — an infer-role plan governs the doc, as V12's decomposition check treats it"
  policy_fixture infer
  cl validate --all
  assert_v6_ok "--all: the plan lists the spec as infer"
  git add -A
  cl validate --staged
  assert_v6_ok "--staged: the same"
  teardown
}

# policy_committed_plan <role>: the fixture with the plan (listing the spec as
# <role>) already committed; then the gate record and the ruling, and only
# those two staged — what a later commit stages. Runs `validate --staged`.
policy_committed_plan() {
  claims_fixture
  policy_plan "$1"
  git add "$PLAN" && git commit -qm "the plan"
  policy_record "$POLICY_CHUNK_REC"
  git add "$SIDECAR" "$POLICY_CHUNK_REC"
  cl validate --staged
}

test_v6_staged_reads_plans_committed_earlier() {
  echo "test: V6 — under --staged, a plan committed earlier governs a ruling staged alone"
  policy_committed_plan target
  assert_v6_ok "--staged: the plan (target) is committed, only the sidecar and the gate record are staged"
  teardown
  policy_committed_plan infer
  assert_v6_ok "--staged: the plan (infer) is committed, only the sidecar and the gate record are staged"
  teardown
  policy_committed_plan amends
  assert_v6_ok "--staged: the plan (amends) is committed"
  teardown
  policy_committed_plan constraint
  assert_v6 "gate record of a plan that does not govern $DOC" "--staged: the committed plan lists the spec as constraint"
  teardown
}

test_v6_final_json_is_a_gate_record() {
  echo "test: V6 — final.json is a gate record, so a ruling on it is never outside a plan"
  policy_fixture target "$POLICY_FINAL_REC"
  jset docs/spec-claims/config.json '.policy.doc_stale_outside_plan_requires = "doc-owner"'
  jset "$SIDECAR" '.claims[0].rulings[0].by = "someone"'
  cl validate --all
  assert_v6_ok "final.json of a plan that lists the spec as target, by someone else"
  policy_plan constraint
  cl validate --all
  assert_v6 "gate record of a plan that does not govern $DOC" "final.json of a plan that lists the spec as constraint"
  assert_not_contains "$(v6_messages)" "outside a plan" "…and not an outside-a-plan finding"
  teardown
}

test_v6_gate_record_matched_structurally() {
  echo "test: V6 — only docs/spec-claims/gates/<stem>/chunk-<n>.json and final.json are gate records"
  policy_fixture constraint
  jset docs/spec-claims/config.json '.policy.doc_stale_outside_plan_requires = "doc-owner"'
  jset "$SIDECAR" '.claims[0].rulings[0].by = "someone"'
  local rec g=docs/spec-claims/gates/$PLAN_STEM
  for rec in "$g/chunk-0.json" "$g/chunk-01.json" "$g/chunk-x.json" "$g/chunk-.json" "$g/chunk-1.json.bak" \
      "$g/final.jsonl" "$g/sub/chunk-1.json" "docs/spec-claims/gates/chunk-1.json" \
      "docs/issues/$g/chunk-1.json" "x$g/chunk-1.json"; do
    policy_record "$rec"
    jset "$SIDECAR" '.claims[0].rulings[0].by = "someone"'
    cl validate --all
    assert_v6 "outside a plan, DOC-STALE needs doc-owner" "$rec is not a gate record"
    assert_not_contains "$(v6_messages)" "does not govern" "$rec: …so no plan is consulted"
  done
  teardown
}

test_v6_outside_plan_requires_principal() {
  echo "test: V6 — outside a plan, policy.doc_stale_outside_plan_requires names who may rule"
  claims_fixture
  jset docs/spec-claims/config.json '.policy.doc_stale_outside_plan_requires = "doc-owner"'
  jset "$SIDECAR" ".claims[0].rulings = [$_CL_DOC_STALE] | .claims[0].rulings[0].by = \"someone\""
  cl validate --all
  assert_v6 "outside a plan, DOC-STALE needs doc-owner" "--all: ruled by someone"
  git add -A
  cl validate --staged
  assert_v6 "outside a plan, DOC-STALE needs doc-owner" "--staged: ruled by someone"
  jset "$SIDECAR" '.claims[0].rulings[0].by = "doc-owner"'
  cl validate --all
  assert_v6_ok "--all: ruled by doc-owner"
  git add -A
  cl validate --staged
  assert_v6_ok "--staged: ruled by doc-owner"
  # Unset (null, the default): any principal.
  jset docs/spec-claims/config.json '.policy.doc_stale_outside_plan_requires = null'
  jset "$SIDECAR" '.claims[0].rulings[0].by = "someone"'
  cl validate --all
  assert_v6_ok "no principal required"
  teardown
}

test_v6_policy_off_allows_any_record() {
  echo "test: V6 — with in_plan_ruling_requires_gate_record false, a gate record of any plan is accepted"
  policy_fixture constraint
  jset docs/spec-claims/config.json '.policy.in_plan_ruling_requires_gate_record = false'
  cl validate --all
  assert_v6_ok "--all: a gate record of a plan listing the spec as constraint"
  policy_record "docs/spec-claims/gates/2026-02-02-other/chunk-3.json"
  cl validate --all
  assert_v6_ok "--all: a gate record of no plan at all"
  # The record must still exist.
  /bin/rm -f docs/spec-claims/gates/2026-02-02-other/chunk-3.json
  cl validate --all
  assert_v6 "does not exist" "…but it must exist"
  teardown
}

test_v6_gate_record_symlink_not_followed() {
  echo "test: V6 — a ruling record that is a symlink out of the work tree does not exist (--all)"
  policy_fixture target
  /bin/rm -f "$POLICY_CHUNK_REC"
  ln -s /etc/hosts "$POLICY_CHUNK_REC"
  cl validate --all
  assert_v6 "does not exist" "a symlinked gate record"
  teardown
}

# parse_plan <path> <source>: _claims_plan_parse's JSON, run inside a probed
# doc-tools (the parser is not a verb).
parse_plan() {
  local out probe
  out=$(harness_mktemp plan-parse)
  probe=$(claims_probe after '_claims_plan_parse "$PP_PATH" "$PP_SRC" > "$PP_OUT"')
  PP_PATH="$1" PP_SRC="$2" PP_OUT="$out" "$probe" claims render </dev/null >/dev/null 2>&1 || true
  cat "$out"
  rm -f "$out"
}

test_plan_parse_shape() {
  echo "test: _claims_plan_parse — chunks, kinds, Claims, files, links, specs, completed, fences, CRLF"
  claims_fixture
  local p=docs/superpowers/plans/2026-01-03-parse.md json crlf
  mkdir -p docs/superpowers/plans
  cat > "$p" <<'EOF'
---
title: Parser plan
status: Completed
governing_specs:
  - docs/specs/SPEC-AUTH-001-token.md:target
  - docs/adr/ADR-007-keys.md
---
# Parser plan

## Chunk 1: One

### Task 1: Build it

**Files:**
- Create: `src/auth/new.py`
- Modify: `src/auth/token.py:10-20`
- Test: `tests/unit/test_new.py`

**Claims:** SPEC-AUTH-001#token-ttl, `SPEC-AUTH-001#refresh-single-use`

See [the issue](docs/issues/token-ttl.md) and docs/superpowers/specs/2026-01-01-design.md.

```markdown
### Task 9: Claims gate (chunk 1)
**Claims:** SPEC-AUTH-001#fenced
```

### Task 2: Claims gate (chunk 1)

### Task 3: Update governing specs for this chunk

**Specs** (roles copied from `--specs`):
- docs/specs/SPEC-AUTH-001-token.md — target
- docs/adr/ADR-007-keys.md — constraint

## Chunk 2: Two

### Task 4: Tidy

**Claims:** none — refactor only

### Task 5: Land the spec amendment for docs/specs/SPEC-AUTH-001-token.md

### Task 6: Final claims gate

### Task 7: Finalize all governing specs
EOF
  json=$(parse_plan "$p" all)
  assert_json_field "$json" '.path' "$p" ".path"
  assert_json_field "$json" '.stem' "2026-01-03-parse" ".stem"
  assert_json_field "$json" '.completed' "true" "front matter status: Completed → completed"
  assert_json_field "$json" '.chunked' "true" "## Chunk headings → chunked"
  assert_json_field "$json" '.specs | tojson' \
    '[{"path":"docs/specs/SPEC-AUTH-001-token.md","role":"target"},{"path":"docs/adr/ADR-007-keys.md","role":"infer"},{"path":"docs/adr/ADR-007-keys.md","role":"constraint"}]' \
    ".specs: front matter (unsuffixed → infer) and the Specs list, each pair once"
  assert_json_field "$json" '[.chunks[].n] | tojson' '[1,2]' "chunk numbers from the headings"
  assert_json_field "$json" '[.chunks[] | [.tasks[].kind]] | tojson' \
    '[["impl","gate","spec-update"],["impl","amendment","final-gate","finalize"]]' "task kinds (the fenced heading is no task)"
  assert_json_field "$json" '.chunks[0].tasks[0].title' "Build it" "the title follows 'Task N: '"
  assert_json_field "$json" '.chunks[0].tasks[0].line' "$(line_no "$p" '### Task 1: Build it')" ".line is the heading's line"
  assert_json_field "$json" '.chunks[0].tasks[0].files | tojson' '["src/auth/new.py","src/auth/token.py","tests/unit/test_new.py"]' "files, :N-M stripped"
  assert_json_field "$json" '.chunks[0].tasks[0].claims | tojson' '["SPEC-AUTH-001#token-ttl","SPEC-AUTH-001#refresh-single-use"]' "Claims: a comma list (backticks dropped)"
  assert_json_field "$json" '.chunks[0].tasks[0].claims_none' "null" "…claims_none null"
  assert_json_field "$json" '.chunks[0].tasks[0].links | tojson' '["docs/issues/token-ttl.md","docs/superpowers/specs/2026-01-01-design.md"]' "links: path tokens under source_doc_patterns"
  assert_json_field "$json" '.chunks[1].tasks[0].claims_none' "refactor only" "Claims: none — <reason>"
  assert_json_field "$json" '.chunks[1].tasks[0].claims | tojson' '[]' "…no ids"
  assert_not_contains "$json" "SPEC-AUTH-001#fenced" "a fenced Claims line is ignored"
  # The CRLF twin parses the same.
  crlf=docs/superpowers/plans/2026-01-04-crlf.md
  awk '{ printf "%s\r\n", $0 }' "$p" > "$crlf"
  assert_eq "$(jq -c 'del(.path, .stem)' <<<"$json")" "$(parse_plan "$crlf" all | jq -c 'del(.path, .stem)')" "a CRLF plan parses as its LF twin"
  # The index is read under staged, a commit under rev:<sha>.
  git add "$p" && git commit -qm "parse plan"
  printf '\n### Task 8: Added later\n' >> "$p"
  git add "$p"
  assert_json_field "$(parse_plan "$p" staged)" '[.chunks[1].tasks[].title] | last' "Added later" "staged reads the index"
  assert_json_field "$(parse_plan "$p" "rev:$(git rev-parse HEAD)")" '[.chunks[1].tasks[].title] | last' "Finalize all governing specs" "rev:<sha> reads the commit"
  teardown
}

test_plan_parse_chunkless() {
  echo "test: _claims_plan_parse — a chunkless plan: each impl task opens a chunk; **Status:** Completed"
  claims_fixture
  local json
  plan_write -- head impl1 gate1 update impl2 gate2 update final finalize
  printf '\n**Status:** completed\n' >> "$PLAN"
  json=$(parse_plan "$PLAN" all)
  assert_json_field "$json" '.chunked' "false" "no ## Chunk heading → chunked false"
  assert_json_field "$json" '[.chunks[] | {n, k: [.tasks[].kind]}] | tojson' \
    '[{"n":1,"k":["impl","gate","spec-update"]},{"n":2,"k":["impl","gate","spec-update","final-gate","finalize"]}]' \
    "each impl task opens chunk n; the injected tasks after it belong to it"
  assert_json_field "$json" '.completed' "true" "**Status:** completed (any case) → completed"
  assert_json_field "$json" '.specs | tojson' '[{"path":"docs/specs/SPEC-AUTH-001-token.md","role":"target"}]' "the Specs lists, once"
  teardown
}

test_is_code_path() {
  echo "test: _claims_is_code_path — outside docs/ without code_roots; else a code_roots glob or prefix"
  claims_fixture
  local out probe
  out=$(harness_mktemp code-paths)
  probe=$(claims_probe after 'for p in src/a.py README.md docs/x.md docs srcx/a.py lib/a.sh lib/sub/b.sh lib/a.py; do if _claims_is_code_path "$p"; then printf "%s " "$p" >> "$CP_OUT"; fi; done')
  CP_OUT="$out" "$probe" claims render </dev/null >/dev/null 2>&1 || true
  assert_eq "src/a.py README.md docs srcx/a.py lib/a.sh lib/sub/b.sh lib/a.py " "$(cat "$out")" "code_roots empty: every path outside docs/"
  jset docs/spec-claims/config.json '.code_roots = ["src", "lib/*.sh"]'
  : > "$out"
  CP_OUT="$out" "$probe" claims render </dev/null >/dev/null 2>&1 || true
  assert_eq "src/a.py lib/a.sh lib/sub/b.sh " "$(cat "$out")" "code_roots [src, lib/*.sh]: the prefix src (not srcx) and the glob"
  rm -f "$out"
  teardown
}

# --- claims gate (Task 16) -------------------------------------------------------
#
# gate_fixture is promote_fixture (the fixture claim bound to the stub, its
# mutant 900 → 1800) with the default plan committed: chunk 1 names the
# claim on its Claims line, chunk 2 names none, and the plan lists the
# fixture spec as target. gate_promote promotes the claim and commits what
# promote wrote. The gate records land in docs/spec-claims/gates/<stem>/,
# untracked unless a test commits them (the dirty-tree check ignores them).

GATE_REC1=docs/spec-claims/gates/$PLAN_STEM/chunk-1.json
GATE_REC2=docs/spec-claims/gates/$PLAN_STEM/chunk-2.json
GATE_UNBUILT_MSG="chunk was meant to build it: promote, rule, or defer"

gate_fixture() {
  promote_fixture
  # shellcheck disable=SC2086  # the block list splits on spaces
  plan_write -- $PLAN_DEFAULT
  git add "$PLAN" && git commit -qm "the plan"
}

# gate_plain_fixture: claims_fixture (the claim unbuilt, no check yet, no
# runner) with the default plan committed.
gate_plain_fixture() {
  claims_fixture
  # shellcheck disable=SC2086  # the block list splits on spaces
  plan_write -- $PLAN_DEFAULT
  git add "$PLAN" && git commit -qm "the plan"
}

gate_promote() {
  cl promote "$TTL_ID"
  assert_eq "0" "$CL_RC" "gate_promote: promote exits 0"
  git add "$SIDECAR" "$DOC" && git commit -qm "promote $TTL_ID"
}

# gate <n> [args…]: claims gate of the fixture plan's chunk <n>.
gate() {
  local n="$1"
  shift
  cl gate --plan "$PLAN" --chunk "$n" "$@"
}

# rec <n> <jq-filter>: the filter's raw output on chunk <n>'s record.
rec() {
  jq -r "$2" "docs/spec-claims/gates/$PLAN_STEM/chunk-$1.json" 2>/dev/null || echo "no record"
}

# The last `cl`'s finding messages of check <c>, one per line.
gate_messages() {
  jq -r --arg c "$1" '.findings[]? | select(.check == $c) | .message' <<<"$CL_OUT" 2>/dev/null || true
}

# gate_ruling <record>: the fixture claim gets a new DOC-STALE ruling naming
# <record> (nothing staged).
gate_ruling() {
  jset "$SIDECAR" ".claims[0].rulings += [$_CL_DOC_STALE] | .claims[0].rulings[-1].record = \"$1\""
}

# The diff options a record's patch text is read with: pinned, so no clone's
# git config (diff.noprefix, diff.mnemonicPrefix, diff.algorithm,
# diff.context, …) changes a patch id.
PINNED_DIFF="--no-renames --diff-algorithm=myers --src-prefix=a/ --dst-prefix=b/ --no-color --no-ext-diff --no-textconv --unified=3 --inter-hunk-context=0 --indent-heuristic"

# The patch ids of <range>'s first-parent non-merge commits, as the record
# stores them.
expected_patch_ids() {
  # shellcheck disable=SC2086  # the option list splits on spaces
  git -c core.quotePath=true log -p --no-show-signature --first-parent --no-merges --format='commit %H' \
    $PINNED_DIFF "$1" | git patch-id --stable \
    | jq -Rsc 'split("\n") | map(select(. != "") | split(" ") | {sha: .[1], patch_id: .[0]})'
}

test_gate_writes_record_with_patch_ids() {
  echo "test: gate — a passing chunk writes its record, with each commit's patch id"
  gate_fixture
  gate_promote
  local mb
  mb=$(git merge-base HEAD main)
  gate 1
  assert_eq "0" "$CL_RC" "gate --chunk 1 after the promote exits 0"
  assert_eq "1" "$(json_count "$CL_OUT")" "…one verdict object"
  assert_file_exists "$GATE_REC1" "…the record is written"
  assert_eq "$(expected_patch_ids "$mb..HEAD")" "$(rec 1 '.commits | tojson')" \
    "….commits: each commit's sha and git patch-id --stable"
  assert_eq "3" "$(rec 1 '.commits | length')" "…the branch's three commits"
  assert_eq "1 $PLAN 1 $mb $mb" "$(rec 1 '"\(.schema) \(.plan) \(.chunk) \(.base) \(.from)"')" \
    "…schema, plan, chunk, base and from (the merge-base, for chunk 1)"
  assert_eq "$(git rev-parse HEAD) $(git rev-parse 'HEAD^{tree}')" "$(rec 1 '"\(.head) \(.tree)"')" "…head and tree"
  assert_eq "[\"$TTL_ID\"]" "$(rec 1 '.claims | tojson')" "…the claims the gate ran"
  assert_eq "[{\"claim\":\"$TTL_ID\",\"status\":\"built\",\"outcome\":\"pass\",\"verdict\":\"ok\"}]" \
    "$(rec 1 '.verdicts | tojson')" "…each verdict"
  assert_eq '{"V8":[],"V8n":[],"V9":[]}' "$(rec 1 '.checks | tojson')" "…the V8, V8n and V9 checks, empty"
  assert_eq "pass" "$(rec 1 .result)" "…result pass"
  assert_eq "[]" "$(rec 1 '.unrecorded | tojson')" "…nothing unrecorded"
  assert_json_field "$CL_OUT" '.record' "$GATE_REC1" "the verdict names the record"
  assert_json_field "$CL_OUT" '.result' "pass" "…and its result"
  teardown
}

test_gate_red_claim_exit_1_record_result_red() {
  echo "test: gate — a red claim exits 1; the record is written, result red"
  gate_fixture
  gate_promote
  set_ttl 1800
  git add -A && git commit -qm "TTL 30 minutes"
  gate 1
  assert_eq "1" "$CL_RC" "a built claim failing its check: exits 1"
  assert_eq "red" "$(rec 1 .result)" "…the record is written, result red"
  assert_eq "assert-fail finding" "$(rec 1 '.verdicts[0] | "\(.outcome) \(.verdict)"')" "…its verdict assert-fail, a finding"
  assert_contains "$(gate_messages run)" "a built claim must pass its check" "…the run finding"
  teardown
}

test_gate_unbuilt_named_claim_is_red() {
  echo "test: gate — a claim the chunk names that is still unbuilt is red"
  gate_plain_fixture
  gate 1
  assert_eq "1" "$CL_RC" "the named claim still unbuilt: exits 1"
  assert_contains "$(gate_messages gate)" "$GATE_UNBUILT_MSG" "…'$GATE_UNBUILT_MSG'"
  assert_json_field "$CL_OUT" '[.findings[] | select(.check == "gate")][0].claim' "$TTL_ID" "…naming the claim"
  assert_eq "red" "$(rec 1 .result)" "…the record result red"
  # A name no claim has is red too.
  doc_edit "$PLAN" "**Claims:** SPEC-AUTH-001#token-ttl" "**Claims:** SPEC-AUTH-001#token-ttl, SPEC-AUTH-001#nope"
  git add -A && git commit -qm "name an unknown claim"
  gate 1
  assert_contains "$(gate_messages gate)" "no claim has this id" "an unknown id on the Claims line: a finding"
  # Chunk 2 names none: nothing unbuilt is red there.
  gate 2
  assert_eq "0" "$CL_RC" "chunk 2 (Claims none) exits 0"
  assert_eq "[]" "$(rec 2 '.claims | tojson')" "…and ran no claim"
  teardown
}

test_gate_v8_v9_mandatory_blocking() {
  echo "test: gate — V9 blocks at the gate; --holds <id> --by <principal> satisfies it"
  gate_fixture
  gate_promote
  printf '%s\n' "$TTL_ID" > tools/claims/edited
  git add -A && git commit -qm "the bound test edited"
  local from
  from=$(git merge-base HEAD main)
  gate 1
  assert_eq "1" "$CL_RC" "a V9 item: exits 1 (blocking at the gate)"
  assert_json_field "$CL_OUT" '[.findings[] | select(.check == "V9")][0].claim' "$TTL_ID" "…V9 in findings"
  assert_eq "$from..HEAD" "$(v9_call_args)" "…the edits asked for over <from>..HEAD"
  assert_eq "1 false" "$(rec 1 '"\(.checks.V9 | length) \(.checks.V9[0].held)"')" "…the record's checks.V9, not held"
  gate 1 --holds "$TTL_ID" --by reviewer
  assert_eq "0" "$CL_RC" "--holds <id>: exits 0"
  assert_json_field "$CL_OUT" '[.findings[] | select(.check == "V9")] | length' "0" "…no V9 finding"
  assert_eq "{\"claim\":\"$TTL_ID\",\"kind\":\"states-holds\",\"by\":\"reviewer\"}" \
    "$(rec 1 '.reconciliations[] | select(.kind == "states-holds") | tojson')" "…the reconciliation states-holds"
  assert_eq "true" "$(rec 1 '.checks.V9[0].held')" "…checks.V9 marks it held"
  gate 1 --holds "$TTL_ID"
  assert_usage_verdict gate true "--holds without --by"
  gate 1 --holds SPEC-AUTH-001#nope --by reviewer
  assert_usage_verdict gate true "--holds naming no claim"
  teardown
}

test_gate_dirty_tree_refused_exit_2() {
  echo "test: gate — a dirty tree is refused (exit 2), no record written"
  gate_fixture
  set_ttl 901
  gate 1
  assert_eq "2" "$CL_RC" "a modified tracked file: exits 2"
  assert_eq "dirty-tree" "$(promote_reasons)" "…indeterminate, reason dirty-tree"
  assert_file_not_exists "$GATE_REC1" "…no record written"
  git checkout -q -- src/auth/token.py
  # A gate record and an untracked file do not count.
  mkdir -p "$(dirname "$GATE_REC1")"
  printf '{}\n' > "$GATE_REC1"
  printf 'x\n' > untracked.txt
  gate 1
  assert_true "a stale record and an untracked file: not refused (rc $CL_RC)" test "$CL_RC" != 2
  assert_eq "red" "$(rec 1 .result)" "…the record rewritten"
  teardown
}

test_gate_from_defaults_previous_chunk_head() {
  echo "test: gate — from is --from, else chunk <n-1>'s head, else the merge-base"
  gate_fixture
  gate_promote
  local head1 side
  gate 1
  head1=$(rec 1 .head)
  printf 'Guide.\n' > docs/guide.md
  git add docs/guide.md "$GATE_REC1" && git commit -qm "chunk 2 work"
  gate 2
  assert_eq "$head1" "$(rec 2 .from)" "chunk 2's from is chunk 1's head"
  assert_eq "1" "$(rec 2 '.commits | length')" "…its commits: the one since"
  gate 2 --from HEAD~2
  assert_eq "$(git rev-parse HEAD~2)" "$(rec 2 .from)" "--from overrides it"
  # A previous record whose head is no ancestor of HEAD: indeterminate.
  git checkout -q -b side main
  git commit -q --allow-empty -m "side"
  side=$(git rev-parse HEAD)
  git checkout -q feature
  jset "$GATE_REC1" ".head = \"$side\""
  gate 2
  assert_eq "2" "$CL_RC" "chunk 1's head not an ancestor of HEAD: exits 2"
  assert_json_field "$CL_OUT" '.indeterminate[0].reason | test("not an ancestor")' "true" "…saying so"
  jset "$GATE_REC1" '.head = 7'
  gate 2
  assert_eq "2" "$CL_RC" "chunk 1's record without a head: exits 2"
  gate 2 --from "$side"
  assert_eq "2" "$CL_RC" "--from not an ancestor of HEAD: exits 2, never an empty range"
  assert_json_field "$CL_OUT" '.indeterminate[0].reason | test("not an ancestor")' "true" "…saying so"
  gate 2 --from nope
  assert_eq "2" "$CL_RC" "--from unresolvable: exits 2"
  teardown
}

test_gate_records_reconciliations_from_sidecar_changes() {
  echo "test: gate — a ruling naming this chunk's record is a reconciliation"
  gate_plain_fixture
  gate 1
  assert_eq "1" "$CL_RC" "precondition: chunk 1 red (the claim unbuilt)"
  gate_ruling "$GATE_REC1"
  git add "$SIDECAR" "$GATE_REC1" && git commit -qm "DOC-STALE: rule at the chunk 1 gate"
  gate 1
  assert_eq "1" "$(rec 1 '.reconciliations | length')" "the re-run lists one reconciliation"
  assert_eq "$TTL_ID ruling $GATE_REC1 unbuilt unbuilt null" \
    "$(rec 1 '.reconciliations[0] | "\(.claim) \(.kind) \(.ruling.record) \(.from_status) \(.to_status) \(.verdict_sha256)"')" \
    "…the ruling, citing chunk-1.json"
  assert_eq "[]" "$(rec 1 '.unrecorded | tojson')" "…nothing unrecorded"
  assert_eq "0" "$CL_RC" "…the DOC-STALE ruling reconciles the unbuilt named claim: exits 0"
  teardown
}

test_gate_unbuilt_cleared_only_by_doc_stale() {
  echo "test: gate — a still-unbuilt named claim is cleared by a DOC-STALE ruling here, never by CODE-DIVERGES"
  gate_plain_fixture
  gate 1
  assert_eq "1" "$CL_RC" "precondition: chunk 1 red (the claim unbuilt)"
  jset "$SIDECAR" ".claims[0].rulings += [$_CL_DIVERGES] | .claims[0].rulings[-1].record = \"$GATE_REC1\""
  git add "$SIDECAR" "$GATE_REC1" && git commit -qm "CODE-DIVERGES at the chunk 1 gate, the claim left unbuilt"
  gate 1
  assert_eq "1" "$CL_RC" "a CODE-DIVERGES ruling citing this record, the claim still unbuilt: exits 1"
  assert_contains "$(gate_messages gate)" "$GATE_UNBUILT_MSG" "…'$GATE_UNBUILT_MSG'"
  assert_eq "CODE-DIVERGES" "$(rec 1 '.reconciliations[0].ruling.direction')" "…though the ruling is recorded"
  gate_ruling "$GATE_REC1"
  git add "$SIDECAR" "$GATE_REC1" && git commit -qm "DOC-STALE at the chunk 1 gate"
  gate 1
  assert_eq "0" "$CL_RC" "a DOC-STALE ruling citing this record: exits 0"
  assert_not_contains "$(gate_messages gate)" "$GATE_UNBUILT_MSG" "…the unbuilt finding cleared"
  teardown
}

test_gate_ruling_citing_other_record_is_silent() {
  echo "test: gate — a ruling citing an issue doc or another record is a silent reconciliation"
  gate_plain_fixture
  gate 1
  git add "$GATE_REC1" && git commit -qm "the chunk 1 record"
  gate_ruling docs/issues/token-ttl.md
  git add -A && git commit -qm "DOC-STALE: rule in the issue"
  gate 2
  assert_eq "1" "$CL_RC" "a ruling citing an issue doc: exits 1"
  assert_eq "docs/issues/token-ttl.md" "$(rec 2 '.unrecorded[0].ruling.record')" "…unrecorded, its record the issue doc"
  assert_eq "ruling" "$(rec 2 '.unrecorded[0].kind')" "…kind ruling"
  assert_contains "$(gate_messages gate)" "silent reconciliation" "…a silent reconciliation finding"
  assert_eq "[]" "$(rec 2 '.reconciliations | tojson')" "…not a reconciliation"
  jset "$SIDECAR" ".claims[0].rulings[-1].record = \"$GATE_REC1\""
  git add -A && git commit -qm "cite chunk 1's record instead"
  gate 2
  assert_eq "1" "$CL_RC" "a ruling citing another chunk's record: exits 1"
  assert_eq "$GATE_REC1" "$(rec 2 '.unrecorded[0].ruling.record')" "…unrecorded too"
  teardown
}

test_gate_promotion_without_ruling_included() {
  echo "test: gate — a promotion is a reconciliation, stored with its digest; its status change with it"
  gate_fixture
  gate_promote
  local digest
  digest=$(jq -r '.claims[0].promotion.verdict_sha256' "$SIDECAR")
  gate 1
  assert_eq "0" "$CL_RC" "a promotion with no ruling: exits 0"
  assert_eq "$digest" "$(rec 1 '.reconciliations[] | select(.kind == "promotion") | .verdict_sha256')" \
    "…the promotion, with its verdict_sha256"
  assert_eq "unbuilt built" "$(rec 1 '.reconciliations[] | select(.kind == "status") | "\(.from_status) \(.to_status)"')" \
    "…and its status change"
  assert_eq "[]" "$(rec 1 '.unrecorded | tojson')" "…nothing unrecorded"
  teardown
}

test_gate_promotion_missing_verdict_still_included() {
  echo "test: gate — a promotion whose verdict is not in the local store is still included (advisory)"
  gate_fixture
  gate_promote
  local digest
  digest=$(jq -r '.claims[0].promotion.verdict_sha256' "$SIDECAR")
  rm -f "$(claims_store)/$digest.json"
  gate 1
  assert_eq "0" "$CL_RC" "the verdict missing: exits 0"
  assert_eq "$digest" "$(rec 1 '.reconciliations[] | select(.kind == "promotion") | .verdict_sha256')" \
    "…the promotion still included, with its digest"
  assert_json_field "$CL_OUT" '[.advisories[] | select(.code == "unverifiable-here")][0].claim' "$TTL_ID" \
    "…the advisory unverifiable-here"
  teardown
}

test_gate_doc_stale_repromote_cycle() {
  echo "test: gate — red, DOC-STALE amendment at the gate, re-promote owed, promote, green"
  gate_fixture
  gate_promote
  # 1. The code moves to 30 minutes: red.
  set_ttl 1800
  git add -A && git commit -qm "TTL 30 minutes"
  gate 1
  assert_eq "1" "$CL_RC" "1. the source at 1800: exits 1"
  assert_file_exists "$GATE_REC1" "…chunk-1.json written"
  # 2. The DOC-STALE amendment, committed with the record.
  doc_edit "$DOC" "$TTL_LINE" "- ~~Access tokens expire after 15 minutes.~~"$'\n''> ⚠️ **AMENDED 2026-10-12 — ttl.** Access tokens expire after 30 minutes.'
  jset "$SIDECAR" ".claims[0].quote = \"Access tokens expire after 30 minutes\"
    | .claims[0].states = \"An issued access token is rejected 30 minutes after issue.\"
    | .claims[0].rulings += [$_CL_DOC_STALE] | .claims[0].rulings[-1].record = \"$GATE_REC1\"
    | .claims[0].nonvacuity.mutant.find = \"TTL_SECONDS = 1800\" | .claims[0].nonvacuity.mutant.replace = \"TTL_SECONDS = 900\""
  printf '%s\t%s\t%s\n' "$STUB_NODE" src/auth/token.py "TTL_SECONDS = 1800" > tools/claims/checks
  git add -A
  cl validate --staged
  assert_eq "0" "$CL_RC" "2. validate --staged on the amendment exits 0"
  assert_contains "$(v6_codes)" "re-promote owed" "…with the advisory re-promote owed"
  git commit -qm "DOC-STALE: the TTL is 30 minutes"
  # 3. Still red: the verdict is the old states'.
  gate 1
  assert_eq "1" "$CL_RC" "3. the gate re-run exits 1"
  assert_contains "$(gate_messages gate)" "re-promote owed: run claims promote $TTL_ID" "…re-promote owed"
  # 4. Re-promote.
  gate_promote
  # 5. Green.
  gate 1
  assert_eq "0" "$CL_RC" "5. after the re-promote: exits 0"
  assert_eq "$GATE_REC1" "$(rec 1 '.reconciliations[] | select(.kind == "ruling") | .ruling.record')" \
    "…the ruling, record chunk-1.json"
  assert_eq "$(jq -r '.claims[0].promotion.verdict_sha256' "$SIDECAR")" \
    "$(rec 1 '.reconciliations[] | select(.kind == "promotion") | .verdict_sha256')" "…the new promotion"
  assert_eq "[]" "$(rec 1 '.unrecorded | tojson')" "…unrecorded empty"
  teardown
}

test_gate_indeterminate_exit_2() {
  echo "test: gate — an indeterminate run exits 2; the record says indeterminate"
  gate_fixture
  gate_promote
  force "$STUB_NODE" indeterminate "no database"
  git add -A && git commit -qm "the runner cannot run"
  gate 1
  assert_eq "2" "$CL_RC" "an indeterminate outcome: exits 2"
  assert_eq "indeterminate" "$(rec 1 .result)" "…the record result indeterminate"
  teardown
}

test_gate_path_safety() {
  echo "test: gate — --chunk is a positive integer; the plan and record paths are safe repo paths"
  gate_plain_fixture
  local n
  for n in 0 01 -1 1x ""; do
    gate "$n"
    assert_usage_verdict gate true "--chunk '$n'"
  done
  cl gate --plan ../outside.md --chunk 1
  assert_usage_verdict gate true "--plan with a .. segment"
  cl gate --plan docs/superpowers/plans/absent.md --chunk 1
  assert_eq "2" "$CL_RC" "a plan absent at HEAD: exits 2"
  gate 3
  assert_eq "2" "$CL_RC" "a chunk the plan does not have: exits 2"
  # The gates directory through a symbolic link: never written.
  mkdir -p "$SUITE_TMP/elsewhere"
  ln -s "$SUITE_TMP/elsewhere" docs/spec-claims/gates
  gate 1
  assert_eq "2" "$CL_RC" "gates/ a symbolic link: exits 2"
  assert_eq "" "$(ls "$SUITE_TMP/elsewhere")" "…nothing written through it"
  rm -f docs/spec-claims/gates
  teardown
}

# --- The range rule: a <from>..HEAD consumer reads the branch's own work ------

# range_probe <range>: through a probe, the --planes-of path set of <range>
# (one path per line) into $RANGE_OUT.paths, and its patch text into
# $RANGE_OUT.patch.
range_probe() {
  local probe
  probe=$(claims_probe after '_claims_range_paths "$CL_T_RANGE" "$_SCRATCH/p"; tr "[:cntrl:]" "|" < "$_SCRATCH/p" > "$CL_T_OUT.paths"; _claims_range_patch "$CL_T_RANGE" "$CL_T_OUT.patch"; _claims_mark_emitted 0; exit 0')
  CL_T_RANGE="$1" CL_T_OUT="$RANGE_OUT" "$probe" claims render </dev/null >/dev/null 2>&1 || true
}

test_gate_range_first_parent_excludes_trunk() {
  echo "test: range rule — trunk merged into the branch is not the branch's work"
  gate_fixture
  gate_promote
  local from trunk mine
  RANGE_OUT=$(harness_mktemp range)
  from=$(git rev-parse HEAD)
  git checkout -q main
  printf 'TRUNK = 1\n' > src/trunk.py
  git add -A && git commit -qm "trunk work"
  trunk=$(git rev-parse HEAD)
  git checkout -q feature
  printf 'Notes.\n' > docs/notes.md
  git add -A && git commit -qm "branch work"
  mine=$(git rev-parse HEAD)
  git merge -q --no-edit main
  range_probe "$from..HEAD"
  assert_eq "docs/notes.md|" "$(cat "$RANGE_OUT.paths")" "the path set: the branch's file, not the trunk-only one"
  assert_not_contains "$(cat "$RANGE_OUT.patch")" "src/trunk.py" "…nor is it in the patch text"
  assert_contains "$(cat "$RANGE_OUT.patch")" "+Notes." "…which holds the branch's hunk"
  cl run --planes-of "$from..HEAD"
  assert_json_field "$CL_OUT" '.results' "[]" "run --planes-of: the trunk src/ change selects no runner"
  gate 1 --from "$from"
  assert_eq "0" "$CL_RC" "the gate over the merge exits 0"
  assert_eq "[\"$mine\"]" "$(rec 1 '[.commits[].sha] | tojson')" "….commits: the branch's commit, no trunk commit"
  assert_eq "$(expected_patch_ids "$from..HEAD")" "$(rec 1 '.commits | tojson')" "…with its patch id"
  assert_not_contains "$(rec 1 '.commits | tojson')" "$trunk" "…the trunk commit absent"
  teardown
}

test_gate_range_conflict_resolution_in_path_set() {
  echo "test: range rule — a file resolved in a merge is in the path set"
  gate_fixture
  local from
  RANGE_OUT=$(harness_mktemp range)
  printf 'branch\n' > docs/notes.md
  git add -A && git commit -qm "branch notes"
  from=$(git rev-parse HEAD)
  git checkout -q main
  printf 'trunk\n' > docs/notes.md
  printf 'TRUNK = 1\n' > src/trunk.py
  git add -A && git commit -qm "trunk notes"
  git checkout -q feature
  git merge -q --no-edit main >/dev/null 2>&1 || true
  printf 'resolved\n' > docs/notes.md
  git add docs/notes.md && git commit -qm "merge main, notes resolved"
  range_probe "$from..HEAD"
  assert_eq "docs/notes.md|" "$(cat "$RANGE_OUT.paths")" "the resolved file is in the path set (and the trunk-only one is not)"
  assert_contains "$(cat "$RANGE_OUT.patch")" "+resolved" "…its resolution hunk in the patch text"
  assert_not_contains "$(cat "$RANGE_OUT.patch")" "src/trunk.py" "…the trunk-only file absent"
  gate 1 --from "$from"
  assert_eq "[]" "$(rec 1 '.commits | tojson')" "…patch ids: non-merge commits only (none here)"
  teardown
}

test_gate_v9_trunk_only_bound_test_edit() {
  echo "test: range rule — V9 does not count a bound-test edit that only trunk made"
  gate_fixture
  gate_promote
  local from
  git checkout -q main
  mkdir -p tests
  printf 'def test_ttl(): pass\n' > tests/test_token.py
  git add -A && git commit -qm "the test file on trunk"
  git checkout -q feature
  git merge -q --no-edit main
  printf '%s\n' "$TTL_ID" > tools/claims/edited
  git add -A && git commit -qm "the adapter reports the edit"
  from=$(git rev-parse HEAD)
  git checkout -q main
  printf 'def test_ttl(): assert True\n' > tests/test_token.py
  git add -A && git commit -qm "trunk edits the test"
  git checkout -q feature
  git merge -q --no-edit main
  gate 1 --from "$from"
  assert_eq "0" "$CL_RC" "a bound test only trunk edited: exits 0"
  assert_json_field "$CL_OUT" '[.findings[] | select(.check == "V9")] | length' "0" "…no V9 finding"
  assert_json_field "$CL_OUT" '[.advisories[] | select(.check == "V9")][0].code' "outside-branch-work" "…an advisory says why"
  printf 'def test_ttl(): assert 1\n' > tests/test_token.py
  git add -A && git commit -qm "the branch edits the test"
  gate 1 --from "$from"
  assert_eq "1" "$CL_RC" "the branch edits the bound test: exits 1"
  assert_json_field "$CL_OUT" '[.findings[] | select(.check == "V9")][0].claim' "$TTL_ID" "…a V9 finding"
  teardown
}

# --- The range rule: a merge's hand resolutions, from git's --remerge-diff -----

# merge_fixture: gate_fixture, then a twelve-line src/shared.py and a
# src/untouched.py that trunk and the branch both hold (merged into the
# branch), and RANGE_OUT for range_probe.
merge_fixture() {
  gate_fixture
  RANGE_OUT=$(harness_mktemp range)
  git checkout -q main
  printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\n' > src/shared.py
  printf 'same\n' > src/untouched.py
  git add -A && git commit -qm "shared files on trunk"
  git checkout -q feature
  git merge -q --no-edit main
}

# conflict_merge: a docs/notes.md both sides edit on one line; the merge of
# main into feature is left conflicted (not committed). Sets MERGE_FROM to the
# branch tip before the merge.
conflict_merge() {
  printf 'branch\n' > docs/notes.md
  git add -A && git commit -qm "branch notes"
  MERGE_FROM=$(git rev-parse HEAD)
  git checkout -q main
  printf 'trunk\n' > docs/notes.md
  git add -A && git commit -qm "trunk notes"
  git checkout -q feature
  git merge -q --no-edit main >/dev/null 2>&1 || true
}

test_range_clean_merge_excludes_trunk_additions() {
  echo "test: range rule — a clean merge that auto-merges a file both sides edited adds neither the file nor trunk's lines"
  merge_fixture
  local from
  sed -i 's/^l1$/l1 by the branch/' src/shared.py
  git commit -qam "the branch edits the top of shared.py"
  from=$(git rev-parse HEAD)
  git checkout -q main
  printf 'def trunk_added():\n    return 1\n' >> src/shared.py
  git commit -qam "trunk appends a function"
  git checkout -q feature
  git merge -q --no-edit main
  assert_eq "3" "$(git rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" "precondition: HEAD is a two-parent merge"
  assert_contains "$(git show --cc --name-only --format= HEAD)" "src/shared.py" "precondition: --cc lists the auto-merged file"
  range_probe "$from..HEAD"
  assert_eq "" "$(cat "$RANGE_OUT.paths")" "the path set: empty (the merge resolved nothing by hand)"
  assert_not_contains "$(cat "$RANGE_OUT.patch")" "trunk_added" "…and trunk's function is not in the patch text"
  assert_eq "" "$(cat "$RANGE_OUT.patch")" "…which is empty"
  sed -i 's/^l3$/l3 by the branch/' src/shared.py
  git commit -qam "the branch edits the middle of shared.py"
  range_probe "$from..HEAD"
  assert_eq "src/shared.py|" "$(cat "$RANGE_OUT.paths")" "a later branch edit of that file: it is in the set, from its own commit"
  assert_contains "$(cat "$RANGE_OUT.patch")" "+l3 by the branch" "…its hunk in the patch text"
  assert_not_contains "$(cat "$RANGE_OUT.patch")" "trunk_added" "…still without trunk's function"
  teardown
}

test_range_conflict_keep_both_in_set() {
  echo "test: range rule — a conflict resolved by keeping both sides is in the set"
  gate_fixture
  RANGE_OUT=$(harness_mktemp range)
  conflict_merge
  printf 'branch\ntrunk\n' > docs/notes.md
  git add docs/notes.md && git commit -qm "merge main, both kept"
  range_probe "$MERGE_FROM..HEAD"
  assert_eq "docs/notes.md|" "$(cat "$RANGE_OUT.paths")" "the file is in the path set"
  assert_contains "$(cat "$RANGE_OUT.patch")" "-<<<<<<<" "…its patch text shows the markers git removed"
  teardown
}

test_range_conflict_new_line_in_patch() {
  echo "test: range rule — a line the author wrote into a conflict resolution is a + line"
  gate_fixture
  RANGE_OUT=$(harness_mktemp range)
  conflict_merge
  printf 'written by hand\n' > docs/notes.md
  git add docs/notes.md && git commit -qm "merge main, rewritten"
  range_probe "$MERGE_FROM..HEAD"
  assert_eq "docs/notes.md|" "$(cat "$RANGE_OUT.paths")" "the file is in the path set"
  assert_contains "$(cat "$RANGE_OUT.patch")" "+written by hand" "…the new line is a + line"
  assert_not_contains "$(cat "$RANGE_OUT.patch")" "@@@" "…in plain unified format"
  teardown
}

test_range_conflict_take_theirs_not_in_set() {
  echo "test: range rule — a conflict resolved by taking trunk's side is not the branch's work"
  gate_fixture
  RANGE_OUT=$(harness_mktemp range)
  conflict_merge
  git checkout -q --theirs docs/notes.md
  git add docs/notes.md && git commit -qm "merge main, theirs"
  assert_eq "trunk" "$(cat docs/notes.md)" "precondition: the resolution is trunk's file"
  range_probe "$MERGE_FROM..HEAD"
  assert_eq "" "$(cat "$RANGE_OUT.paths")" "the path set: empty"
  assert_eq "" "$(cat "$RANGE_OUT.patch")" "…and so is the patch text"
  teardown
}

test_range_evil_merge_in_set() {
  echo "test: range rule — an edit a merge makes to a file neither side changed is in the set"
  merge_fixture
  local from
  from=$(git rev-parse HEAD)
  git checkout -q main
  printf 'TRUNK = 1\n' > src/trunk.py
  git add -A && git commit -qm "trunk work"
  git checkout -q feature
  printf 'BRANCH = 1\n' > src/branch.py
  git add -A && git commit -qm "branch work"
  git merge -q --no-edit --no-commit --no-ff main
  printf 'same\nsneaked in\n' > src/untouched.py
  git add -A && git commit -qm "merge main, with an edit"
  range_probe "$from..HEAD"
  assert_eq "src/branch.py|src/untouched.py|" "$(cat "$RANGE_OUT.paths")" "the path set: the branch's file and the evil-merge file, not trunk's"
  assert_contains "$(cat "$RANGE_OUT.patch")" "+sneaked in" "…the evil-merge hunk in the patch text"
  assert_not_contains "$(cat "$RANGE_OUT.patch")" "TRUNK" "…without trunk's file"
  teardown
}

test_range_octopus_merge_indeterminate() {
  echo "test: range rule — an octopus first-parent merge in the range is indeterminate"
  merge_fixture
  local from octo
  from=$(git rev-parse HEAD)
  git checkout -q -b side1 main
  mkdir -p lib
  printf 'S1 = 1\n' > lib/side1.py
  git add -A && git commit -qm "side one"
  git checkout -q -b side2 main
  mkdir -p lib
  printf 'S2 = 1\n' > lib/side2.py
  git add -A && git commit -qm "side two"
  git checkout -q feature
  git merge -q --no-edit side1 side2 >/dev/null 2>&1
  octo=$(git rev-parse HEAD)
  assert_eq "4" "$(git rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" "precondition: HEAD has three parents"
  cl run --planes-of "$from..HEAD"
  assert_eq "2" "$CL_RC" "run --planes-of over an octopus merge: exits 2"
  assert_json_field "$CL_OUT" ".error | test(\"$octo\")" "true" "…the error names the merge"
  assert_json_field "$CL_OUT" '.error | test("octopus")' "true" "…and says why"
  teardown
}

test_range_git_without_remerge_diff_indeterminate() {
  echo "test: range rule — a git that rejects --remerge-diff, with a merge in the range, is indeterminate"
  merge_fixture
  local from shim real
  from=$(git rev-parse HEAD)
  git checkout -q main
  mkdir -p lib
  printf 'TRUNK = 1\n' > lib/trunk.py
  git add -A && git commit -qm "trunk work"
  git checkout -q feature
  mkdir -p lib
  printf 'BRANCH = 1\n' > lib/branch.py
  git add -A && git commit -qm "branch work"
  git merge -q --no-edit main
  shim=$(harness_mktemp_d git-shim)
  real=$(command -v git)
  cat > "$shim/git" <<EOF
#!/bin/sh
for a in "\$@"; do
  case "\$a" in --remerge-diff) echo "error: unknown option 'remerge-diff'" >&2; exit 129 ;; esac
done
exec "$real" "\$@"
EOF
  chmod +x "$shim/git"
  PATH="$shim:$PATH" cl run --planes-of "$from..HEAD"
  assert_eq "2" "$CL_RC" "run --planes-of: exits 2"
  assert_json_field "$CL_OUT" '.error | test("remerge-diff")' "true" "…naming --remerge-diff"
  assert_json_field "$CL_OUT" ".error | contains(\"$(git --version | awk '{print $3}')\")" "true" "…and the git version"
  git checkout -q -b flat "$from"
  mkdir -p lib
  printf 'BRANCH = 1\n' > lib/branch.py
  git add -A && git commit -qm "branch work, no merge"
  PATH="$shim:$PATH" cl run --planes-of "$from..HEAD"
  assert_eq "0" "$CL_RC" "a range without a merge never asks for --remerge-diff: exits 0"
  teardown
}

test_planes_of_three_dot_range() {
  echo "test: range rule — <a>...<b> is <merge-base a b>..<b>, then the range rule"
  gate_fixture
  local mb paths3 patch3
  RANGE_OUT=$(harness_mktemp range)
  printf 'Notes.\n' > docs/notes.md
  git add -A && git commit -qm "branch work"
  git checkout -q main
  printf 'TRUNK = 1\n' > src/trunk.py
  git add -A && git commit -qm "trunk work"
  git checkout -q feature
  git merge -q --no-edit main
  printf 'More notes.\n' >> docs/notes.md
  git add -A && git commit -qm "branch work after the merge"
  mb=$(git merge-base main HEAD)
  range_probe "main...HEAD"
  paths3=$(cat "$RANGE_OUT.paths" 2>/dev/null) || paths3="no path set"
  patch3=$(cat "$RANGE_OUT.patch" 2>/dev/null) || patch3="no patch"
  range_probe "$mb..HEAD"
  assert_eq "$(cat "$RANGE_OUT.paths")" "$paths3" "main...HEAD: the path set of <merge-base>..HEAD"
  assert_eq "$(cat "$RANGE_OUT.patch")" "$patch3" "…and its patch text"
  assert_contains "$paths3" "docs/notes.md|" "…the branch's file"
  assert_not_contains "$paths3" "src/trunk.py" "…not the trunk-only one"
  cl run --planes-of "$mb..HEAD"
  local two="$CL_OUT"
  cl run --planes-of main...HEAD
  assert_eq "0" "$CL_RC" "run --planes-of main...HEAD exits 0"
  assert_json_field "$CL_OUT" '.results | tojson' "$(jq -c '.results' <<<"$two")" "…the same selection as <merge-base>..HEAD"
  # No merge base: indeterminate, never empty.
  git checkout -q --orphan lone
  git rm -rq --cached . && git commit -q --allow-empty -m "unrelated root"
  git checkout -q -f feature
  cl run --planes-of lone...feature
  assert_eq "2" "$CL_RC" "<a>...<b> without a merge base: exits 2"
  assert_json_field "$CL_OUT" '.error | test("no merge base")' "true" "…saying so"
  teardown
}

test_planes_of_not_ancestor_indeterminate() {
  echo "test: range rule — a range whose start is no ancestor of its end is indeterminate"
  gate_fixture
  local side
  git checkout -q -b side main
  git commit -q --allow-empty -m "side"
  side=$(git rev-parse HEAD)
  git checkout -q feature
  cl run --planes-of "$side..HEAD"
  assert_eq "2" "$CL_RC" "run --planes-of <non-ancestor>..HEAD: exits 2"
  assert_json_field "$CL_OUT" '.error | test("not an ancestor")' "true" "…saying so"
  cl run --planes-of HEAD
  assert_eq "2" "$CL_RC" "run --planes-of without '..': exits 2"
  teardown
}

test_patch_ids_independent_of_clone_diff_config() {
  echo "test: range rule — a record's patch ids do not depend on the clone's diff config"
  gate_fixture
  gate_promote
  # A change that myers and patience render differently.
  printf 'a\nb\nc\n{\n x\n}\n{\n y\n}\nz\n' > src/auth/shape.py
  git add -A && git commit -qm "shape"
  printf 'a\nb\nc\n{\n y\n}\n{\n x\n}\n{\n w\n}\nz\n' > src/auth/shape.py
  git commit -qam "shape reordered"
  local mb before plain
  mb=$(git merge-base HEAD main)
  gate 1
  before=$(rec 1 '[.commits[].patch_id] | tojson')
  assert_eq "$(expected_patch_ids "$mb..HEAD")" "$(rec 1 '.commits | tojson')" "precondition: the pinned patch ids"
  plain=$(git log -p --first-parent --no-merges --format='commit %H' -1 HEAD | git patch-id --stable)
  git config diff.noprefix true
  git config diff.mnemonicPrefix true
  git config diff.algorithm patience
  git config diff.context 6
  assert_true "precondition: under that config, an unpinned git log -p gives another patch id" \
    test "$plain" != "$(git log -p --first-parent --no-merges --format='commit %H' -1 HEAD | git patch-id --stable)"
  gate 1
  assert_eq "$before" "$(rec 1 '[.commits[].patch_id] | tojson')" \
    "diff.noprefix, diff.mnemonicPrefix, diff.algorithm patience and diff.context 6: .commits[].patch_id unchanged"
  teardown
}

# --- claims attest and claims rulings (Task 17) -----------------------------------
#
# attest_fixture is gate_fixture with the claim promoted (gate_promote) and
# both chunk gates run green, each record committed: a plan that converged
# chunk by chunk, ready for its final gate. attest runs claims attest on the
# fixture plan; fin reads its final.json. fresh_clone clones the fixture's
# feature branch (main tracking origin/main), with an empty verdict store,
# and enters it (inside home/, which the fixture's git ignores).

GATE_FINAL=docs/spec-claims/gates/$PLAN_STEM/final.json
ATTEST_UNBUILT_MSG="named claim still unbuilt at the final gate"

attest_fixture() {
  gate_fixture
  gate_promote
  gate 1
  assert_eq "0" "$CL_RC" "attest_fixture: gate 1 exits 0"
  git add "$GATE_REC1" && git commit -qm "the chunk 1 gate record"
  gate 2
  assert_eq "0" "$CL_RC" "attest_fixture: gate 2 exits 0"
  git add "$GATE_REC2" && git commit -qm "the chunk 2 gate record"
}

attest() {
  cl attest --plan "$PLAN" "$@"
}

# fin <jq-filter>: the filter's raw output on final.json.
fin() {
  jq -r "$1" "$GATE_FINAL" 2>/dev/null || echo "no record"
}

# The last `cl`'s finding messages, one per line; its advisory codes.
attest_messages() {
  jq -r '.findings[]?.message' <<<"$CL_OUT" 2>/dev/null || true
}
attest_codes() {
  jq -r '.advisories[]?.code' <<<"$CL_OUT" 2>/dev/null || true
}

fresh_clone() {
  local c="$TEST_DIR/home/clone"
  git clone -q -b feature "$TEST_DIR" "$c"
  git -C "$c" branch -q main origin/main
  cd "$c"
}

# attest_amend_final <record>: the Final claims gate's DOC-STALE amendment of
# the fixture claim to 30 minutes (the sentence struck, an AMENDED block, the
# quote re-anchored, new states, a ruling naming <record>, the stub's needle
# and the mutant following the code), nothing staged.
attest_amend_final() {
  doc_edit "$DOC" "$TTL_LINE" "- ~~Access tokens expire after 15 minutes.~~"$'\n''> ⚠️ **AMENDED 2026-10-12 — ttl.** Access tokens expire after 30 minutes.'
  jset "$SIDECAR" ".claims[0].quote = \"Access tokens expire after 30 minutes\"
    | .claims[0].states = \"An issued access token is rejected 30 minutes after issue.\"
    | .claims[0].rulings += [$_CL_DOC_STALE] | .claims[0].rulings[-1].record = \"$1\"
    | .claims[0].nonvacuity.mutant.find = \"TTL_SECONDS = 1800\" | .claims[0].nonvacuity.mutant.replace = \"TTL_SECONDS = 900\""
  printf '%s\t%s\t%s\n' "$STUB_NODE" src/auth/token.py "TTL_SECONDS = 1800" > tools/claims/checks
}

# attest_converge: the Final claims gate sequence (Task 25) on the fixture's
# built claim, every step's record committed: the code moves to 1800 (red),
# the DOC-STALE amendment citing final.json, the re-promotion, the green
# final gate. Asserts only that the last run passes.
attest_converge() {
  attest_fixture
  set_ttl 1800
  git add -A && git commit -qm "TTL 30 minutes"
  attest --final
  attest_amend_final "$GATE_FINAL"
  git add -A && git commit -qm "DOC-STALE: the TTL is 30 minutes"
  gate_promote
  attest --final
  assert_eq "0" "$CL_RC" "attest_converge: the final gate passes"
  git add "$GATE_FINAL" && git commit -qm "the final gate record"
}

test_attest_final_all_records_pass() {
  echo "test: attest --final — every chunk recorded and green: final.json result pass, which V12 accepts"
  attest_fixture
  local mb head2
  mb=$(git merge-base HEAD main)
  head2=$(rec 2 .head)
  attest --final
  assert_eq "0" "$CL_RC" "attest --final exits 0"
  assert_eq "1" "$(json_count "$CL_OUT")" "…one verdict object"
  assert_json_field "$CL_OUT" '.record' "$GATE_FINAL" "…naming the record"
  assert_eq "pass" "$(fin .result)" "final.json result pass"
  assert_eq "1 $PLAN $mb $head2" "$(fin '"\(.schema) \(.plan) \(.base) \(.from)"')" \
    "…schema, plan, base, and from (chunk 2's head)"
  assert_eq "$(git rev-parse HEAD) $(git rev-parse 'HEAD^{tree}')" "$(fin '"\(.head) \(.tree)"')" "…head and tree"
  assert_eq "[{\"chunk\":1,\"record\":\"$GATE_REC1\",\"rebased\":null},{\"chunk\":2,\"record\":\"$GATE_REC2\",\"rebased\":null}]" \
    "$(fin '.chunks | tojson')" "…both chunk records, matched"
  assert_eq "[{\"claim\":\"$TTL_ID\",\"status\":\"built\",\"verdict\":\"ok\"}]" "$(fin '.claims | tojson')" "…the named claim, ok"
  assert_eq '[] {"unrecorded":[],"reverted":[]} [] ok' \
    "$(fin '"\(.reconciliations | tojson) \(.cross_check | tojson) \(.amendments | tojson) \(.render_check)"')" \
    "…no reconciliation at the final gate, nothing unrecorded or reverted, no amendment, render ok"
  # V12 accepts the record attest wrote.
  # shellcheck disable=SC2086  # the block list splits on spaces
  plan_write -- head completed ${PLAN_DEFAULT#head }
  git add "$PLAN" "$GATE_FINAL"
  cl validate --staged
  assert_v12_ok "validate --staged, the plan Completed with attest's final.json"
  git commit -qm "the plan completed"
  cl validate --all
  assert_v12_ok "…committed, under --all"
  teardown
}

test_attest_missing_chunk_record() {
  echo "test: attest — a chunk with a gate task and no record is a finding"
  gate_fixture
  gate_promote
  gate 1
  git add "$GATE_REC1" && git commit -qm "the chunk 1 gate record"
  attest
  assert_eq "1" "$CL_RC" "chunk 2 never gated: exits 1"
  assert_contains "$(attest_messages)" "chunk 2: no gate record" "…'chunk 2: no gate record'"
  attest --final
  assert_eq "fail" "$(fin .result)" "--final: final.json written, result fail"
  assert_eq "null" "$(fin '.chunks[1].record')" "…chunk 2's record null"
  teardown
}

test_attest_rebased_branch_matched_by_patch_id() {
  echo "test: attest — a rebased branch's records match by patch id"
  attest_fixture
  git checkout -q main
  printf 'Trunk notes.\n' > docs/trunk.md
  git add docs/trunk.md && git commit -qm "trunk: unrelated"
  git checkout -q feature
  git rebase -q main
  assert_true "precondition: chunk 1's recorded head is no longer an ancestor of HEAD" \
    test "$(git merge-base --is-ancestor "$(rec 1 .head)" HEAD && echo yes || echo no)" = no
  attest --final
  assert_eq "0" "$CL_RC" "attest --final after the rebase exits 0"
  assert_eq "[null,null]" "$(fin '[.chunks[].rebased] | tojson')" "…no record marked rebased"
  teardown
}

# A sha no clone has.
MISSING_SHA=0123456789abcdef0123456789abcdef01234567

test_attest_unresolvable_head_without_twin_indeterminate() {
  echo "test: attest — the last record's head not here and no rebased twin: indeterminate, never a wider window"
  gate_fixture
  gate_promote
  gate 1
  git add "$GATE_REC1" && git commit -qm "the chunk 1 gate record"
  # A ruling naming final.json, committed during chunk 2: silent there.
  gate_ruling "$GATE_FINAL"
  git add "$SIDECAR" && git commit -qm "DOC-STALE citing final.json, before chunk 2's gate"
  gate 2
  assert_eq "1" "$CL_RC" "precondition: chunk 2's gate is red (silent reconciliation)"
  git add "$GATE_REC2" && git commit -qm "the chunk 2 gate record"
  attest
  assert_eq "1" "$CL_RC" "precondition: attest exits 1"
  assert_contains "$(attest_messages)" "silent reconciliation" "…a silent reconciliation"
  # chunk 2's head gone, its patch matching no branch commit.
  jset "$GATE_REC2" ".head = \"$MISSING_SHA\" | .commits = [{sha: \"$MISSING_SHA\", patch_id: \"$MISSING_SHA\"}]"
  attest --final
  assert_eq "2" "$CL_RC" "the head not a commit here, no twin: exits 2 (never the merge-base window)"
  assert_json_field "$CL_OUT" '.indeterminate[0].reason | test("re-run the gate for chunk 2")' "true" \
    "…telling the user to re-run chunk 2's gate"
  assert_not_contains "$(attest_codes)" "from-remapped" "…no from-remapped"
  assert_file_not_exists "$GATE_FINAL" "…and final.json not written"
  # The head absent from its own commits (a merge, or an empty chunk): the same.
  jset "$GATE_REC2" '.commits = []'
  attest
  assert_eq "2" "$CL_RC" "the head not among its record's commits: exits 2"
  teardown
}

test_attest_fresh_clone_rebase_remaps_to_twin() {
  echo "test: attest — in a fresh clone of a rebased branch, the last head maps to its rebased twin"
  attest_fixture
  git checkout -q main
  printf 'Trunk notes.\n' > docs/trunk.md
  git add docs/trunk.md && git commit -qm "trunk: unrelated"
  git checkout -q feature
  git rebase -q main
  local c="$TEST_DIR/home/clone" old
  old=$(rec 2 .head)
  # --no-local: only the reachable objects, so the old heads are not there.
  git clone -q --no-local -b feature "$TEST_DIR" "$c"
  git -C "$c" branch -q main origin/main
  cd "$c"
  assert_true "precondition: chunk 2's old head is not in the clone" \
    test "$(git cat-file -e "$old^{commit}" 2>/dev/null && echo yes || echo no)" = no
  attest --final
  assert_eq "0" "$CL_RC" "attest --final exits 0"
  assert_contains "$(attest_codes)" "from-remapped" "…with the advisory from-remapped"
  assert_eq "$(git log -1 --format=%H -- "$GATE_REC1")" "$(fin .from)" \
    "…from is the twin: the rebased commit of chunk 1's record (chunk 2's head)"
  teardown
}

test_attest_ambiguous_twin_indeterminate() {
  echo "test: attest — two branch commits with the head's patch id: indeterminate"
  attest_fixture
  printf 'Same.\n' > docs/dup.md
  git add docs/dup.md && git commit -qm "dup"
  local pid
  pid=$(git show HEAD | git patch-id --stable | cut -d' ' -f1)
  git rm -q docs/dup.md && git commit -qm "undo dup"
  printf 'Same.\n' > docs/dup.md
  git add docs/dup.md && git commit -qm "dup again"
  jset "$GATE_REC2" ".head = \"$MISSING_SHA\" | .commits = [{sha: \"$MISSING_SHA\", patch_id: \"$pid\"}]"
  attest
  assert_eq "2" "$CL_RC" "the head's patch id on two branch commits: exits 2"
  assert_json_field "$CL_OUT" '.indeterminate[0].reason | test("re-run the gate for chunk 2")' "true" "…saying so"
  teardown
}

test_attest_unmatched_commit_marked_rebased_reverified() {
  echo "test: attest — a record whose commits were squashed is marked re-verified, not a finding"
  gate_fixture
  gate_promote
  gate 1
  gate 2
  git reset -q --soft HEAD~2
  git commit -qm "the plan and the promotion, squashed"
  attest --final
  assert_eq "0" "$CL_RC" "attest --final exits 0"
  assert_eq "re-verified" "$(fin '.chunks[0].rebased')" "…chunk 1 marked rebased: re-verified"
  assert_eq "null" "$(fin '.chunks[1].rebased')" "…chunk 2 (no commit) not"
  assert_json_field "$CL_OUT" '.chunks[0].rebased' "re-verified" "…in the verdict too"
  teardown
}

test_attest_sidecar_ruling_with_no_gate_record() {
  echo "test: attest — a ruling after the last chunk gate citing no gate record is silent, never absorbed"
  attest_fixture
  gate_ruling docs/issues/token-ttl.md
  git add -A && git commit -qm "DOC-STALE: rule in the issue"
  attest --final
  assert_eq "1" "$CL_RC" "attest --final exits 1"
  assert_contains "$(attest_messages)" "silent reconciliation" "…a silent reconciliation"
  assert_eq "fail" "$(fin .result)" "…final.json written, result fail"
  assert_eq "0" "$(fin '[.reconciliations[] | select(.kind == "ruling")] | length')" "…its reconciliations hold no ruling"
  assert_eq "docs/issues/token-ttl.md" "$(fin '.cross_check.unrecorded[0].ruling.record')" \
    "…cross_check.unrecorded holds the ruling, its record the issue doc"
  attest --final
  assert_eq "1" "$CL_RC" "a second --final run: exits 1 again (never absorbed)"
  assert_eq "0" "$(fin '[.reconciliations[] | select(.kind == "ruling")] | length')" "…still not a reconciliation"
  teardown
}

test_attest_record_reconciliation_reverted_at_head() {
  echo "test: attest — a ruling a chunk record reconciled, reverted at HEAD, is a finding"
  gate_fixture
  gate_promote
  gate_ruling "$GATE_REC1"
  git add "$SIDECAR" && git commit -qm "DOC-STALE at the chunk 1 gate"
  local ruled
  ruled=$(git rev-parse HEAD)
  gate 1
  assert_eq "1" "$(rec 1 '[.reconciliations[] | select(.kind == "ruling")] | length')" "precondition: chunk 1 records the ruling"
  git add "$GATE_REC1" && git commit -qm "the chunk 1 gate record"
  gate 2
  git add "$GATE_REC2" && git commit -qm "the chunk 2 gate record"
  attest
  assert_eq "0" "$CL_RC" "precondition: attest exits 0"
  git revert --no-edit "$ruled" >/dev/null
  attest
  assert_eq "1" "$CL_RC" "the ruling reverted: exits 1"
  assert_contains "$(attest_messages)" "reconciliation reverted at HEAD" "…'reconciliation reverted at HEAD'"
  attest --final
  assert_eq "$GATE_REC1 DOC-STALE" "$(fin '.cross_check.reverted[0] | "\(.record) \(.ruling.direction)"')" \
    "…cross_check.reverted names the record and the ruling"
  teardown
}

test_attest_named_claim_red_at_head() {
  echo "test: attest — a named built claim red at HEAD is a finding"
  attest_fixture
  set_ttl 1800
  git add -A && git commit -qm "TTL 30 minutes"
  attest
  assert_eq "1" "$CL_RC" "the source at 1800: exits 1"
  assert_contains "$(attest_messages)" "a built claim must pass its check" "…the run finding"
  teardown
}

test_attest_named_claim_unbuilt_is_finding() {
  echo "test: attest — a named claim still unbuilt is a finding"
  gate_plain_fixture
  gate 1
  gate 2
  attest
  assert_eq "1" "$CL_RC" "the named claim unbuilt: exits 1"
  assert_contains "$(attest_messages)" "$ATTEST_UNBUILT_MSG" "…'$ATTEST_UNBUILT_MSG'"
  assert_json_field "$CL_OUT" "[.findings[] | select(.message | test(\"$ATTEST_UNBUILT_MSG\"))][0].claim" "$TTL_ID" \
    "…naming the claim"
  # A name no claim has is a finding too.
  doc_edit "$PLAN" "**Claims:** SPEC-AUTH-001#token-ttl" "**Claims:** SPEC-AUTH-001#token-ttl, SPEC-AUTH-001#nope"
  git add -A && git commit -qm "name an unknown claim"
  attest
  assert_contains "$(attest_messages)" "no claim has this id" "an unknown id on a Claims line: a finding"
  teardown
}

test_attest_unbuilt_cleared_only_by_doc_stale() {
  echo "test: attest — a still-unbuilt named claim is cleared by a recorded DOC-STALE ruling, never by CODE-DIVERGES"
  gate_plain_fixture
  gate 1
  gate 2
  jset "$SIDECAR" ".claims[0].rulings += [$_CL_DIVERGES] | .claims[0].rulings[-1].record = \"$GATE_FINAL\""
  git add "$SIDECAR" && git commit -qm "CODE-DIVERGES at the final gate, the claim left unbuilt"
  attest --final
  assert_eq "1" "$CL_RC" "a CODE-DIVERGES ruling in final.json, the claim still unbuilt: exits 1"
  assert_contains "$(attest_messages)" "$ATTEST_UNBUILT_MSG" "…'$ATTEST_UNBUILT_MSG'"
  assert_eq "CODE-DIVERGES" "$(fin '.reconciliations[] | select(.kind == "ruling") | .ruling.direction')" \
    "…though the ruling is recorded in final.json"
  gate_ruling "$GATE_FINAL"
  git add "$SIDECAR" && git commit -qm "DOC-STALE at the final gate"
  attest --final
  assert_eq "0" "$CL_RC" "a DOC-STALE ruling in final.json: exits 0"
  assert_not_contains "$(attest_messages)" "$ATTEST_UNBUILT_MSG" "…the unbuilt finding cleared"
  teardown
}

test_attest_named_diverged_needs_ruling_and_tracker() {
  echo "test: attest — a named diverged claim needs its assertion failure, its ruling and an open tracker (V5)"
  claims_fixture
  diverge_claim "$STUB_TEST"
  jset "$SIDECAR" ".claims[0].rulings[0].record = \"$GATE_REC1\""
  set_ttl 1800
  # shellcheck disable=SC2086  # the block list splits on spaces
  plan_write -- $PLAN_DEFAULT
  git add -A && git commit -qm "diverged at chunk 1, the plan"
  gate 1
  git add "$GATE_REC1" && git commit -qm "the chunk 1 gate record"
  gate 2
  git add "$GATE_REC2" && git commit -qm "the chunk 2 gate record"
  attest
  assert_eq "0" "$CL_RC" "precondition: diverged, failing by an assertion, ruled at chunk 1, tracker open: exits 0"
  doc_edit "$TRACKER" "$TRACKER_OPEN" "**Status**: Closed"
  git add -A && git commit -qm "close the tracker"
  attest
  assert_eq "1" "$CL_RC" "its tracker closed: exits 1"
  assert_contains "$(v5_messages)" "tracker is closed" "…V5 names the closed tracker"
  set_ttl 900
  git add -A && git commit -qm "the code meets the spec again"
  attest
  assert_contains "$(attest_messages)" "passes: promote" "a diverged claim that passes: a finding (promote it)"
  teardown
}

test_attest_final_reconciliation_converges() {
  echo "test: attest --final — red, DOC-STALE amendment citing final.json, re-promote owed, promote, green"
  attest_fixture
  # 1. The code moves to 30 minutes after the last chunk gate: red.
  set_ttl 1800
  git add -A && git commit -qm "TTL 30 minutes"
  attest --final
  assert_eq "1" "$CL_RC" "1. the source at 1800: exits 1"
  assert_eq "fail" "$(fin .result)" "…final.json written, result fail"
  # 2. The DOC-STALE amendment, committed with that final.json.
  attest_amend_final "$GATE_FINAL"
  git add -A
  cl validate --staged
  assert_eq "0" "$CL_RC" "2. validate --staged on the amendment exits 0"
  assert_contains "$(v6_codes)" "re-promote owed" "…with the advisory re-promote owed"
  git commit -qm "DOC-STALE: the TTL is 30 minutes"
  # 3. Still red: the verdict proves the old states.
  attest --final
  assert_eq "1" "$CL_RC" "3. the final gate re-run exits 1"
  assert_contains "$(attest_messages)" "re-promote owed: run claims promote $TTL_ID" "…re-promote owed"
  # 4. Re-promote.
  gate_promote
  # 5. Green.
  attest --final
  assert_eq "0" "$CL_RC" "5. after the re-promote: exits 0"
  assert_eq "pass" "$(fin .result)" "…result pass"
  assert_eq "$GATE_FINAL" "$(fin '.reconciliations[] | select(.kind == "ruling") | .ruling.record')" \
    "…final.json's reconciliations hold the ruling"
  assert_eq "$(jq -r '.claims[0].promotion.verdict_sha256' "$SIDECAR")" \
    "$(fin '.reconciliations[] | select(.kind == "promotion") | .verdict_sha256')" "…and the new promotion"
  assert_eq "[]" "$(fin '.cross_check.unrecorded | tojson')" "…cross_check.unrecorded empty"
  assert_eq "1 $TTL_ID DOC-STALE The TTL was renegotiated." \
    "$(fin '"\(.amendments | length) \(.amendments[0].claim) \(.amendments[0].direction) \(.amendments[0].reason)"')" \
    "…the amendment batch holds the ruling"
  teardown
}

test_attest_final_fresh_clone_passes_converged_plan() {
  echo "test: attest --final — a fresh clone (no verdict store) passes the converged plan"
  attest_converge
  fresh_clone
  assert_true "precondition: the clone's verdict store is empty" test ! -d "$(claims_store)"
  attest --final
  assert_eq "0" "$CL_RC" "attest --final in the fresh clone exits 0"
  assert_not_contains "$(attest_messages)" "silent reconciliation" "…promotions match by their stored digest"
  assert_eq "[]" "$(fin '.cross_check.unrecorded | tojson')" "…nothing unrecorded"
  assert_eq "unverifiable-here" "$(attest_codes | sort -u | tr '\n' ' ' | sed 's/ $//')" \
    "…advisories: unverifiable-here only"
  teardown
}

test_attest_fresh_clone_repromoted_not_flagged() {
  echo "test: attest — in a fresh clone, an amended claim re-promoted after the amendment is not owed"
  attest_converge
  fresh_clone
  attest --final
  assert_eq "0" "$CL_RC" "attest --final in the fresh clone exits 0"
  assert_not_contains "$(attest_messages)" "re-promote owed" "…no re-promote owed finding"
  assert_not_contains "$(jq -r '.advisories[]?.message' <<<"$CL_OUT")" "re-promote" "…nor advisory"
  teardown
}

test_attest_fresh_clone_unrepromoted_flagged_by_commit_order() {
  echo "test: attest — in a fresh clone, an amendment after the promotion is owed (commit order)"
  attest_fixture
  attest --final
  assert_eq "0" "$CL_RC" "precondition: the final gate passes"
  doc_stale_amend "$(jq -c --arg r "$GATE_FINAL" '.record = $r' <<<"$_CL_DOC_STALE")"
  git add -A && git commit -qm "DOC-STALE amendment citing final.json, not re-promoted"
  fresh_clone
  attest --final
  assert_eq "1" "$CL_RC" "attest --final in the fresh clone exits 1"
  assert_contains "$(attest_messages)" "re-promote owed: run claims promote $TTL_ID" "…re-promote owed"
  jset "$SIDECAR" '.claims[0].promotion.at = "0123456789abcdef0123456789abcdef01234567"'
  git commit -qam "promotion.at: a commit this clone does not have"
  attest
  assert_not_contains "$(attest_messages)" "re-promote owed" "promotion.at not a commit here: no re-promote owed finding"
  assert_contains "$(attest_codes)" "unverifiable-here" "…the advisory unverifiable-here"
  teardown
}

test_attest_unrelated_ruling_not_attributed() {
  echo "test: attest — a ruling on a claim of a doc the plan does not govern is not the plan's"
  attest_fixture
  mkdir -p docs/adr
  printf '# ADR-007: Cache tokens\n\n## Decision\n\nCache tokens for 5 minutes.\n' > docs/adr/ADR-007-cache.md
  jq --argjson r "$_CL_DOC_STALE" '.doc = "docs/adr/ADR-007-cache.md" | .claims = [.claims[0] | .id = "ADR-007#cache-ttl"
      | .quote = "Cache tokens for 5 minutes" | .status = "unbuilt" | .test = null | .nonvacuity = null
      | .promotion = null | .rulings = [$r]]' "$SIDECAR" > docs/spec-claims/ADR-007.json
  rerender
  git add -A && git commit -qm "ADR-007, its claim ruled DOC-STALE in an issue"
  attest
  assert_eq "0" "$CL_RC" "attest --plan (governing SPEC-AUTH-001 only) exits 0"
  assert_not_contains "$(attest_messages)" "silent reconciliation" "…no silent reconciliation for ADR-007's claim"
  teardown
}

test_attest_deep_reruns_recorded_tree() {
  echo "test: attest --deep — each record's claims re-run in a worktree at its head"
  attest_fixture
  # Another worktree, its directory gone (prunable): attest never prunes it.
  git worktree add -q --detach "$TEST_DIR/home/other" HEAD
  rm -rf "$TEST_DIR/home/other"
  : > "$STUB_LOG"
  attest --deep
  assert_eq "0" "$CL_RC" "attest --deep exits 0"
  assert_contains "$(stub_roots)" "/wt." "…the stub ran with --root a throwaway worktree"
  assert_contains "$(stub_roots)" "$(git rev-parse --show-toplevel)" "…besides the work tree (step 2)"
  assert_json_field "$CL_OUT" '[.results[] | select(.chunk == 1)][0] | "\(.claim) \(.outcome) \(.verdict)"' \
    "$TTL_ID pass ok" "…chunk 1's claim passes at its recorded tree"
  assert_eq "2" "$(wt_count)" "…its worktrees removed; the other, prunable one still registered"
  # A recorded head that is not a commit here: indeterminate.
  jset "$GATE_REC1" '.head = "0123456789abcdef0123456789abcdef01234567"'
  attest --deep
  assert_eq "2" "$CL_RC" "a recorded head not in this clone: exits 2"
  assert_json_field "$CL_OUT" '.indeterminate[0].reason | test("not a commit here")' "true" "…indeterminate, saying so"
  teardown
}

test_attest_render_check_fails() {
  echo "test: attest — a hand-edited status block fails render --check (V11)"
  attest_fixture
  doc_edit "$DOC" "## Claim status" "## Claim status (edited)"
  git add -A && git commit -qm "hand-edit the status block"
  attest --final
  assert_eq "1" "$CL_RC" "exits 1"
  assert_json_field "$CL_OUT" '[.findings[] | select(.check == "V11")] | length > 0' "true" "…a V11 finding"
  assert_eq "failed" "$(fin .render_check)" "…final.json render_check failed"
  assert_json_field "$CL_OUT" '[.results[] | select(has("changed"))] | length' "0" "…render's rows stay out of results"
  teardown
}

test_attest_path_safety() {
  echo "test: attest — the plan path is a safe repo path; final.json is never written through a link"
  attest_fixture
  cl attest --plan ../outside.md
  assert_usage_verdict attest true "--plan with a .. segment"
  cl attest --plan docs/superpowers/plans/absent.md
  assert_eq "2" "$CL_RC" "a plan absent at HEAD: exits 2"
  set_ttl 901
  attest --final
  assert_eq "2" "$CL_RC" "--final on a dirty tree: exits 2"
  assert_file_not_exists "$GATE_FINAL" "…nothing written"
  git checkout -q -- src/auth/token.py
  mkdir -p "$SUITE_TMP/elsewhere-final"
  ln -s "$SUITE_TMP/elsewhere-final" "docs/spec-claims/gates/$PLAN_STEM/final.json"
  attest --final
  assert_eq "2" "$CL_RC" "final.json a symbolic link: exits 2"
  assert_eq "" "$(ls "$SUITE_TMP/elsewhere-final")" "…nothing written through it"
  teardown
}

test_rulings_amendment_batch_json_and_markdown() {
  echo "test: rulings — the amendment batch, as JSON rows and as Markdown"
  claims_fixture
  local base
  base=$(git rev-parse HEAD)
  doc_stale_amend
  jset "$SIDECAR" ".claims[0].rulings += [$_CL_DIVERGES]"
  git add -A && git commit -qm "DOC-STALE amendment, and a CODE-DIVERGES ruling"
  cl rulings --range "$base..HEAD"
  assert_eq "0" "$CL_RC" "rulings exits 0"
  assert_json_field "$CL_OUT" '.results | length' "1" "…one row: CODE-DIVERGES is not an amendment"
  assert_json_field "$CL_OUT" '.results[0] | "\(.claim)|\(.doc)|\(.direction)|\(.by)|\(.date)|\(.reason)"' \
    "$TTL_ID|$DOC|DOC-STALE|doc-owner|2026-10-11|The TTL was renegotiated." "…claim, doc, direction, by, date, reason"
  assert_json_field "$CL_OUT" '.results[0].approved | "\(.quote)|\(.states)"' \
    "Access tokens expire after 15 minutes|An issued access token is rejected 15 minutes after issue." \
    "…approved: the quote and states at <a>"
  assert_json_field "$CL_OUT" '.results[0].new.states' "$NEW_STATES" "…new: the states at <b>"
  cl rulings --range "$base..HEAD" --format markdown
  assert_eq "0" "$CL_RC" "--format markdown exits 0"
  assert_eq "## Spec amendments (1)" "$(head -n 1 <<<"$CL_OUT")" "…'## Spec amendments (1)'"
  assert_contains "$CL_OUT" "### $TTL_ID — DOC-STALE" "…the row's heading"
  assert_contains "$CL_OUT" "**Approved:** An issued access token is rejected 15 minutes after issue." "…the approved states"
  assert_contains "$CL_OUT" "**New:** $NEW_STATES" "…the new states"
  assert_contains "$CL_OUT" "**Reason:** The TTL was renegotiated." "…the reason"
  cl rulings --range "main...HEAD"
  assert_json_field "$CL_OUT" '.results | length' "1" "a three-dot range: from the merge-base"
  cl rulings --range "HEAD..$base"
  assert_eq "2" "$CL_RC" "a range whose start is no ancestor of its end: exits 2"
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
  test_v1_unsafe_doc_path
  test_render_unsafe_doc_skipped
  test_v11_inline_markers_are_text
  test_v11_malformed_markers
  test_render_base_unused
  test_unsafe_symlinked_dir
  test_unsafe_symlinked_file
  test_v11_indented_markers

  # --- Task 7: runner adapters and claims run ---
  test_run_built_pass_exit_0
  test_run_built_assert_fail_exit_1
  test_run_diverged_assert_fail_expected_exit_0
  test_run_diverged_pass_is_finding_promote
  test_run_diverged_error_is_finding
  test_run_unbuilt_any_failure_ok
  test_run_unbuilt_pass_is_finding
  test_run_unbuilt_no_check_yet
  test_run_indeterminate_exit_2
  test_run_adapter_nonzero_all_indeterminate
  test_run_precedence_finding_beats_indeterminate
  test_run_adapter_malformed_json_indeterminate
  test_run_frozen_skipped
  test_run_planes_of_selects_runner_by_paths
  test_run_log_claims_only_scheduled
  test_run_judge_sample_rotates
  test_run_node_with_spaces
  test_adapter_child_does_not_hold_stdout
  test_adapter_stdin_is_dev_null
  test_run_unknown_runner_indeterminate
  test_run_unsafe_adapter_path_indeterminate
  test_run_selection
  test_parse_helpers_require_rc

  # --- Task 8: V3 test binding ---
  test_v3_unbound_node
  test_v3_bound_passes
  test_v3_in_gate_false
  test_v3_subject_imports_not_ok
  test_v3_built_without_nonvacuity
  test_v3_mutant_find_not_unique
  test_v3_mutant_file_unsafe_never_read
  test_v3_test_file_unsafe
  test_v3_list_adapter_failure_indeterminate
  test_v3_mutant_checked_only_built
  test_v3_frozen_structural_only
  test_v3_runner_name_with_newline
  test_v3_staged_mutant_file_touches_claim
  test_v3_test_file_dash_and_containment
  test_v3_two_runners_one_call_each

  # --- Task 9: V4 lint and lint runs ---
  test_v4_selftest_violates_passes
  test_v4_selftest_clean_fails
  test_v4_pattern_contradicts_status
  test_v4_diverged_and_unbuilt_status
  test_v4_unbuilt_absent_path_allowed
  test_v4_valid_lint_passes
  test_v4_invalid_pattern
  test_v4_lint_paths_unsafe_or_absent
  test_v4_staged_reads_index
  test_v4_frozen_selftest_only
  test_run_lint_rerun
  test_run_lint_unbuilt_pass_is_finding
  test_run_lint_structural_findings

  # --- Task 10: V9 claim-bound test edits ---
  test_v9_edited_bound_test_listed_advisory
  test_v9_all_uses_merge_base_range
  test_v9_unknown_id_ignored
  test_v9_adapter_failure_indeterminate

  # --- Task 11: claims promote with a mutant proof ---
  test_promote_mutant_assert_fail_promotes
  test_promote_mutant_stays_green_refused
  test_promote_mutant_error_refused
  test_promote_requires_green_in_clean_checkout
  test_promote_mutant_not_utf8_refused
  test_promote_mutant_is_test_file_refused
  test_v3_mutant_is_test_file
  test_promote_mutant_file_absent_or_observed_red
  test_promote_built_missing_verdict_repromotes
  test_promote_mutant_find_not_unique_refused
  test_promote_mutant_literal_safe
  test_mutate_exactly_once_bytes_kept
  test_promote_requires_green_first
  test_promote_dirty_tree_exit_2
  test_promote_throwaway_worktree_removed
  test_promote_mutant_file_unsafe
  test_promote_subject_not_at_head
  test_promote_claim_preconditions
  test_promote_second_without_commit_refused
  test_promote_twice_with_commit_between
  test_promote_built_with_ok_verdict_refused
  test_repromote_after_doc_stale

  # --- Task 12: observed_red proofs ---
  test_promote_observed_red_reverified
  test_promote_observed_red_passes_refused
  test_promote_observed_red_bad_sha
  test_promote_observed_red_utf8_locale
  test_promote_observed_red_subject_absent_at_sha
  test_promote_observed_red_subject_unsafe
  test_promote_observed_red_subject_is_test_file
  test_promote_observed_red_and_mutant_both_verified
  test_v3_observed_red_subject_is_test_file

  # --- Task 13: the verdict store round trip, its sharing, --reverify ---
  test_verdict_round_trip_v6_accepts
  test_verdict_store_shared_across_worktrees
  test_verdict_store_fresh_clone_unverifiable
  test_promote_reverify_all_no_sidecar_write
  test_promote_reverify_selection
  test_promote_reverify_same_proof_path

  # --- Task 14: the plan parser and V12 plan structure ---
  test_plan_parse_shape
  test_plan_parse_chunkless
  test_is_code_path
  test_v12_well_formed_plan_passes
  test_v12_chunk_without_gate
  test_v12_gate_after_spec_update
  test_v12_no_final_gate
  test_v12_unbuilt_target_claim_unnamed
  test_v12_code_task_without_claims_line
  test_v12_claims_none_linking_issue
  test_v12_completed_without_final_record
  test_v12_plan_without_governing_specs_exempt
  test_v12_legacy_plan_without_gates_exempt
  test_v12_fenced_example_ignored
  test_v12_nested_fence_ignored
  test_v12_fence_pairing_ignored
  test_v12_chunkless_plan_gate_immediately_precedes
  test_v12_completed_after_base_merge_ok
  test_v12_final_record_checked
  test_v12_final_record_malformed
  test_v12_final_record_unsafe_path
  test_v12_symlinked_plan_skipped
  test_v12_files_line_first_path_only
  test_v12_completed_at_base_exempt_from_every_check
  test_v12_historical_completed_plan_not_finding
  test_v12_base_unresolvable_gate_carrying_only
  test_v6_in_plan_ruling_requires_gate_record_of_listing_plan
  test_v6_in_plan_ruling_infer_role_ok
  test_v6_staged_reads_plans_committed_earlier
  test_v6_final_json_is_a_gate_record
  test_v6_gate_record_matched_structurally
  test_v6_outside_plan_requires_principal
  test_v6_policy_off_allows_any_record
  test_v6_gate_record_symlink_not_followed

  # --- Task 16: claims gate, the chunk gate records ---
  test_gate_writes_record_with_patch_ids
  test_gate_red_claim_exit_1_record_result_red
  test_gate_unbuilt_named_claim_is_red
  test_gate_v8_v9_mandatory_blocking
  test_gate_dirty_tree_refused_exit_2
  test_gate_from_defaults_previous_chunk_head
  test_gate_records_reconciliations_from_sidecar_changes
  test_gate_unbuilt_cleared_only_by_doc_stale
  test_gate_ruling_citing_other_record_is_silent
  test_gate_promotion_without_ruling_included
  test_gate_promotion_missing_verdict_still_included
  test_gate_doc_stale_repromote_cycle
  test_gate_indeterminate_exit_2
  test_gate_path_safety
  test_gate_range_first_parent_excludes_trunk
  test_gate_range_conflict_resolution_in_path_set
  test_range_clean_merge_excludes_trunk_additions
  test_range_conflict_keep_both_in_set
  test_range_conflict_new_line_in_patch
  test_range_conflict_take_theirs_not_in_set
  test_range_evil_merge_in_set
  test_range_octopus_merge_indeterminate
  test_range_git_without_remerge_diff_indeterminate
  test_gate_v9_trunk_only_bound_test_edit
  test_planes_of_three_dot_range
  test_planes_of_not_ancestor_indeterminate
  test_patch_ids_independent_of_clone_diff_config

  # --- Task 17: claims attest, the final gate; claims rulings ---
  test_attest_final_all_records_pass
  test_attest_missing_chunk_record
  test_attest_rebased_branch_matched_by_patch_id
  test_attest_unmatched_commit_marked_rebased_reverified
  test_attest_unresolvable_head_without_twin_indeterminate
  test_attest_fresh_clone_rebase_remaps_to_twin
  test_attest_ambiguous_twin_indeterminate
  test_attest_sidecar_ruling_with_no_gate_record
  test_attest_record_reconciliation_reverted_at_head
  test_attest_named_claim_red_at_head
  test_attest_named_claim_unbuilt_is_finding
  test_attest_unbuilt_cleared_only_by_doc_stale
  test_attest_named_diverged_needs_ruling_and_tracker
  test_attest_final_reconciliation_converges
  test_attest_final_fresh_clone_passes_converged_plan
  test_attest_fresh_clone_repromoted_not_flagged
  test_attest_fresh_clone_unrepromoted_flagged_by_commit_order
  test_attest_unrelated_ruling_not_attributed
  test_attest_deep_reruns_recorded_tree
  test_attest_render_check_fails
  test_attest_path_safety
  test_rulings_amendment_batch_json_and_markdown

  print_summary
}

run_tests
