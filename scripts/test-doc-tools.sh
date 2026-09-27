#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

# Run doc-tools.sh under the interpreter this suite was launched with,
# not whatever `#!/usr/bin/env bash` resolves to. See bash_bin_shim().
DOC_TOOLS="$(bash_bin_shim "$SCRIPT_DIR/doc-tools.sh")"

# --- Harness self-tests ---

# `echo "$h" | grep -q` under `set -o pipefail` is a race: grep exits on the
# first match, echo then takes SIGPIPE (141), and pipefail reports the pipeline
# as failed. assert_not_contains read that as "needle absent" — a false PASS
# with the forbidden string present — and assert_contains as a false FAIL.
# Once the haystack outgrows the pipe buffer (64 KiB) and the needle is near
# the top, the race is lost almost every time, so a bounded loop is a reliable
# probe. Each probe runs in a command-substitution subshell so its PASS/FAIL
# bookkeeping never reaches the suite's own counters.
test_harness_asserts_are_pipefail_safe() {
  echo "test: harness: assert_contains / assert_not_contains are pipefail-safe on a >=64 KiB haystack"
  local needle='FORBIDDEN-NEEDLE' line hay="" i=0
  line=$(printf '%0120d' 0)
  while [ "$i" -lt 500 ]; do
    hay="${hay}${line} ${needle}"$'\n'
    i=$((i + 1))
  done
  local runs=500 k=0 false_pass=0 false_fail=0 probe
  while [ "$k" -lt "$runs" ]; do
    probe=$(set -o pipefail; FAIL=0; assert_not_contains "$hay" "$needle" "probe" >/dev/null; echo "$FAIL")
    [ "$probe" = "1" ] || false_pass=$((false_pass + 1))
    probe=$(set -o pipefail; FAIL=0; assert_contains "$hay" "$needle" "probe" >/dev/null; echo "$FAIL")
    [ "$probe" = "0" ] || false_fail=$((false_fail + 1))
    k=$((k + 1))
  done
  assert_eq "0" "$false_pass" "assert_not_contains: 0 false PASS in $runs runs (${#hay}-byte haystack, needle x500)"
  assert_eq "0" "$false_fail" "assert_contains: 0 false FAIL in $runs runs (${#hay}-byte haystack, needle x500)"
}

# An interrupted suite must stop, not return from the INT handler into the
# next test with its scratch root already deleted.
test_harness_int_stops_suite_and_cleans_up() {
  echo "test: harness: SIGINT ends the suite (rc 130) and removes its scratch root"
  local probe out rc=0
  probe=$(harness_mktemp int-probe)
  cat > "$probe" <<EOF
source "$SCRIPT_DIR/test-helpers.sh"
echo "root=\$_HARNESS_TMP"
kill -INT \$\$
echo "STILL-RUNNING"
EOF
  out=$("$BASH_BIN" "$probe" 2>&1) || rc=$?
  local root
  root=$(sed -n 's/^root=//p' <<<"$out")
  assert_eq "130" "$rc" "suite exits 130 on SIGINT"
  assert_not_contains "$out" "STILL-RUNNING" "no test code runs after SIGINT"
  assert_true "scratch root removed on SIGINT ($root)" test -n "$root" -a ! -e "$root"
}

# --- Tests ---

# Exit 2 is the command-line-error status (sweep 05ea982 I-4): no subcommand
# and an unknown one are both usage errors; --help is a successful request.
test_no_args_prints_usage() {
  echo "test: no args prints usage and exits 2"
  setup
  set +e
  local output
  output=$("$DOC_TOOLS" 2>&1)
  local exit_code=$?
  set -e
  assert_eq "2" "$exit_code" "exits 2 with no args"
  assert_contains "$output" "Usage" "prints usage"
  teardown
}

test_unknown_subcommand_prints_usage() {
  echo "test: unknown subcommand is named, prints usage and exits 2"
  setup
  set +e
  local output
  output=$("$DOC_TOOLS" unknown 2>&1)
  local exit_code=$?
  set -e
  assert_eq "2" "$exit_code" "exits 2 with unknown subcommand"
  assert_contains "$output" "unknown subcommand 'unknown'" "names the unknown subcommand"
  assert_contains "$output" "Usage" "prints usage for unknown subcommand"
  teardown
}

test_help_flag() {
  echo "test: --help prints usage and exits 0"
  setup
  set +e
  local output
  output=$("$DOC_TOOLS" --help 2>&1)
  local exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0 with --help"
  assert_contains "$output" "Usage" "prints usage for --help"
  teardown
}

test_build_index_creates_index() {
  echo "test: build-index creates docs/.doc-index.json"
  setup
  local mapping="docs/architecture.md:src/:architecture"
  echo "$mapping" | "$DOC_TOOLS" build-index
  assert_file_exists "docs/.doc-index.json" "index file created"
  local json
  json=$(cat docs/.doc-index.json)
  assert_json_field "$json" ".schema_version" "3" "schema_version is 3"
  assert_json_field "$json" ".generated_by" "doc-superpowers" "generated_by is doc-superpowers"
  teardown
}

test_build_index_hashes_doc() {
  echo "test: build-index stores content hash"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  local json
  json=$(cat docs/.doc-index.json)
  local stored_hash
  stored_hash=$(echo "$json" | jq -r '.docs["docs/architecture.md"].content_hash')
  local expected_hash
  expected_hash="sha256:$(hash_file docs/architecture.md)"
  assert_eq "$expected_hash" "$stored_hash" "content hash matches"
  teardown
}

test_build_index_stores_code_commit() {
  echo "test: build-index stores latest code commit"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  local json
  json=$(cat docs/.doc-index.json)
  local stored_commit
  stored_commit=$(echo "$json" | jq -r '.docs["docs/architecture.md"].code_commit')
  local expected_commit
  expected_commit=$(git log -1 --format=%H -- src/)
  assert_eq "$expected_commit" "$stored_commit" "code_commit matches latest commit for src/"
  teardown
}

test_build_index_multiple_code_refs() {
  echo "test: build-index handles multiple comma-separated code_refs"
  setup
  mkdir -p lib
  echo "module" > lib/util.js
  git add -A && git commit -m "add lib" --quiet
  echo "docs/architecture.md:src/,lib/:architecture" | "$DOC_TOOLS" build-index
  local json
  json=$(cat docs/.doc-index.json)
  local code_refs
  code_refs=$(echo "$json" | jq -r '.docs["docs/architecture.md"].code_refs | length')
  assert_eq "2" "$code_refs" "code_refs has 2 entries"
  local stored_commit
  stored_commit=$(echo "$json" | jq -r '.docs["docs/architecture.md"].code_commit')
  local expected_commit
  expected_commit=$(git log -1 --format=%H -- src/ lib/)
  assert_eq "$expected_commit" "$stored_commit" "code_commit matches latest commit across all refs"
  teardown
}

test_build_index_multiple_docs() {
  echo "test: build-index handles multiple docs"
  setup
  echo "# Workflows" > docs/workflows.md
  git add -A && git commit -m "add workflows" --quiet
  printf "docs/architecture.md:src/:architecture\ndocs/workflows.md:src/:workflows" | "$DOC_TOOLS" build-index
  local json
  json=$(cat docs/.doc-index.json)
  local doc_count
  doc_count=$(echo "$json" | jq '.docs | length')
  assert_eq "2" "$doc_count" "index has 2 doc entries"
  teardown
}

test_build_index_sets_status_current() {
  echo "test: build-index sets status to current"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  local json
  json=$(cat docs/.doc-index.json)
  assert_json_field "$json" '.docs["docs/architecture.md"].status' "current" "status is current"
  assert_json_field "$json" '.docs["docs/architecture.md"].replaces' "null" "replaces is null"
  assert_json_field "$json" '.docs["docs/architecture.md"].superseded_by' "null" "superseded_by is null"
  teardown
}

test_build_index_null_code_commit_for_untracked() {
  echo "test: build-index sets null code_commit for never-committed paths"
  setup
  local err
  err=$(echo "docs/architecture.md:nonexistent/:architecture" | "$DOC_TOOLS" build-index 2>&1)
  assert_contains "$err" "code ref 'nonexistent/' matches no file tracked by git" \
    "the never-committed ref is warned about (such a doc can never go stale)"
  local json
  json=$(cat docs/.doc-index.json)
  assert_json_field "$json" '.docs["docs/architecture.md"].code_commit' "null" "code_commit is null for untracked path"
  assert_json_field "$json" '.docs["docs/architecture.md"].status' "current" "status still current"
  teardown
}

# --- check-freshness tests ---

test_check_freshness_requires_index() {
  echo "test: check-freshness exits 1 when no index"
  setup
  set +e
  local output
  output=$("$DOC_TOOLS" check-freshness 2>&1)
  local exit_code=$?
  set -e
  assert_eq "1" "$exit_code" "exits 1 with no index"
  assert_contains "$output" "doc-index.json" "mentions doc-index.json"
  teardown
}

test_check_freshness_current() {
  echo "test: check-freshness reports current when no changes"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  local output
  output=$("$DOC_TOOLS" check-freshness)
  assert_json_field "$output" ".summary.current" "1" "summary.current=1"
  assert_json_field "$output" ".summary.stale" "0" "summary.stale=0"
  assert_json_field "$output" '.docs["docs/architecture.md"].status' "current" "doc status=current"
  teardown
}

test_check_freshness_stale_after_code_change() {
  echo "test: check-freshness reports stale after code change"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  echo "console.log('changed')" > src/index.js
  git add -A && git commit -m "change code" --quiet
  local output
  output=$("$DOC_TOOLS" check-freshness)
  assert_json_field "$output" ".summary.stale" "1" "summary.stale=1"
  assert_json_field "$output" '.docs["docs/architecture.md"].status' "stale" "status=stale"
  assert_json_field "$output" '.docs["docs/architecture.md"].reason' "code_changed" "reason=code_changed"
  teardown
}

test_check_freshness_doc_modified() {
  echo "test: check-freshness reports doc_modified when doc changes"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  echo "# Updated Overview" > docs/architecture.md
  local output
  output=$("$DOC_TOOLS" check-freshness)
  assert_json_field "$output" '.docs["docs/architecture.md"].doc_modified' "true" "doc_modified=true"
  assert_json_field "$output" '.docs["docs/architecture.md"].status' "current" "status still current"
  teardown
}

test_check_freshness_missing_doc() {
  echo "test: check-freshness reports missing when doc file removed"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  rm docs/architecture.md
  local output
  output=$("$DOC_TOOLS" check-freshness)
  assert_json_field "$output" ".summary.missing" "1" "summary.missing=1"
  assert_json_field "$output" '.docs["docs/architecture.md"].status' "missing" "status=missing"
  teardown
}

test_check_freshness_deprecated_preserved() {
  echo "test: check-freshness preserves deprecated status"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  local index_file="docs/.doc-index.json"
  local updated
  updated=$(jq '.docs["docs/architecture.md"].status = "deprecated"' "$index_file")
  echo "$updated" > "$index_file"
  local output
  output=$("$DOC_TOOLS" check-freshness)
  assert_json_field "$output" ".summary.deprecated" "1" "summary.deprecated=1"
  assert_json_field "$output" '.docs["docs/architecture.md"].status' "deprecated" "status=deprecated"
  teardown
}

test_check_freshness_commits_behind() {
  echo "test: check-freshness reports commits_behind"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  echo "v2" > src/index.js && git add -A && git commit -m "change 1" --quiet
  echo "v3" > src/index.js && git add -A && git commit -m "change 2" --quiet
  echo "v4" > src/index.js && git add -A && git commit -m "change 3" --quiet
  local output
  output=$("$DOC_TOOLS" check-freshness)
  assert_json_field "$output" '.docs["docs/architecture.md"].commits_behind' "3" "commits_behind=3"
  teardown
}

test_check_freshness_code_refs_filter() {
  echo "test: check-freshness --code-refs filters to matching docs"
  setup
  mkdir -p lib
  echo "module" > lib/util.js
  git add -A && git commit -m "add lib" --quiet
  printf "docs/architecture.md:src/:architecture\ndocs/workflows.md:lib/:workflows" \
    | "$DOC_TOOLS" build-index
  echo "# Workflows" > docs/workflows.md
  echo "console.log('changed')" > src/index.js
  git add -A && git commit -m "change src" --quiet
  local output
  output=$("$DOC_TOOLS" check-freshness --code-refs src/)
  local checked
  checked=$(echo "$output" | jq '.docs | length')
  assert_eq "1" "$checked" "only 1 doc checked"
  assert_json_field "$output" '.docs["docs/architecture.md"].status' "stale" "architecture.md is stale"
  teardown
}

# --- update-index tests ---

test_update_index_refreshes_entry() {
  echo "test: update-index refreshes hash and code_commit, sets status=current"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  echo "console.log('changed')" > src/index.js
  git add -A && git commit -m "change code" --quiet
  echo "# Updated Overview" > docs/architecture.md
  "$DOC_TOOLS" update-index docs/architecture.md >/dev/null 2>&1
  local json
  json=$(cat docs/.doc-index.json)
  local new_hash
  new_hash="sha256:$(hash_file docs/architecture.md)"
  assert_json_field "$json" '.docs["docs/architecture.md"].status' "current" "status=current after update"
  assert_json_field "$json" '.docs["docs/architecture.md"].content_hash' "$new_hash" "content_hash updated"
  teardown
}

test_update_index_preserves_build_commit() {
  echo "test: update-index does not change build_commit"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  local orig_build_commit
  orig_build_commit=$(jq -r '.build_commit' docs/.doc-index.json)
  echo "console.log('changed')" > src/index.js
  git add -A && git commit -m "change code" --quiet
  "$DOC_TOOLS" update-index docs/architecture.md >/dev/null 2>&1
  local new_build_commit
  new_build_commit=$(jq -r '.build_commit' docs/.doc-index.json)
  assert_eq "$orig_build_commit" "$new_build_commit" "build_commit unchanged"
  teardown
}

test_update_index_preserves_replaces() {
  echo "test: update-index preserves replaces field"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  local index_file="docs/.doc-index.json"
  local updated
  updated=$(jq '.docs["docs/architecture.md"].replaces = "docs/old-arch.md"' "$index_file")
  echo "$updated" > "$index_file"
  "$DOC_TOOLS" update-index docs/architecture.md >/dev/null 2>&1
  local replaces
  replaces=$(jq -r '.docs["docs/architecture.md"].replaces' docs/.doc-index.json)
  assert_eq "docs/old-arch.md" "$replaces" "replaces preserved"
  teardown
}

test_update_index_unknown_path_errors() {
  echo "test: update-index exits 1 for unknown path"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  set +e
  local output exit_code
  output=$("$DOC_TOOLS" update-index docs/nonexistent.md 2>&1)
  exit_code=$?
  set -e
  assert_eq "1" "$exit_code" "exits 1 for unknown path"
  assert_contains "$output" "add-entry" "suggests add-entry"
  teardown
}

test_check_freshness_code_refs_bidirectional_prefix() {
  echo "test: check-freshness --code-refs bidirectional prefix match"
  setup
  mkdir -p src/auth
  echo "login" > src/auth/login.js
  git add -A && git commit -m "add auth" --quiet
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  echo "login_v2" > src/auth/login.js
  git add -A && git commit -m "change auth" --quiet
  local output
  output=$("$DOC_TOOLS" check-freshness --code-refs src/auth/)
  assert_json_field "$output" '.docs["docs/architecture.md"].status' "stale" "architecture.md is stale"
  teardown
}

test_check_freshness_untracked_docs() {
  echo "test: check-freshness detects untracked docs not in the index"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  # Create a doc that is NOT in the index
  echo "# Untracked" > docs/untracked-test.md
  local output
  output=$("$DOC_TOOLS" check-freshness)
  local untracked_count
  untracked_count=$(echo "$output" | jq '.summary.untracked')
  # Should be at least 1 (untracked-test.md)
  if [ "$untracked_count" -ge 1 ]; then
    assert_eq "true" "true" "summary.untracked >= 1"
  else
    assert_eq ">=1" "$untracked_count" "summary.untracked >= 1"
  fi
  local found_untracked
  found_untracked=$(echo "$output" | jq '[.untracked_docs[] | select(. == "docs/untracked-test.md")] | length')
  assert_eq "1" "$found_untracked" "untracked-test.md appears in untracked_docs"
  # Clean up
  rm docs/untracked-test.md
  teardown
}

# --- portability + scale regression guards ---
#
# Both guards below cover bugs that shipped in earlier releases and were only
# caught once .github/workflows/tests.yml started running the suites on
# ubuntu/bash-5.x AND macos/bash-3.2. Neither reproduced on a developer laptop
# running the suites the usual way.

test_build_index_accepts_entry_with_no_code_refs() {
  # bash 3.2 regression: `IFS=',' read -ra refs <<< ""` leaves `refs` empty, and
  # bash 3.2 treats an unguarded "${refs[@]}" on an empty array as an unbound
  # variable under `set -u` — so a single ref-less mapping line aborted the whole
  # of build-index with "refs[@]: unbound variable". bash 4+ expands it to
  # nothing and never noticed.
  echo "test: build-index accepts a mapping line with an empty code_refs field"
  setup
  local err_file
  err_file=$(harness_mktemp norefs-stderr)
  set +e
  echo "docs/architecture.md::architecture" | "$DOC_TOOLS" build-index 2>"$err_file"
  local rc=$?
  set -e
  local err
  err=$(cat "$err_file" 2>/dev/null || true)
  assert_eq "0" "$rc" "build-index exits 0 with no code_refs (stderr: ${err:-none})"
  assert_not_contains "$err" "unbound variable" "no bash 3.2 unbound-array abort"
  assert_file_exists "docs/.doc-index.json" "index still written"
  local json
  json=$(cat docs/.doc-index.json)
  assert_json_field "$json" '.docs["docs/architecture.md"].code_commit' "null" "code_commit is null with no refs"
  teardown
}

test_update_index_when_every_target_is_skipped() {
  # bash 3.2 regression, same class: when every named doc is indexed but absent
  # from disk, each is skipped and `refreshed` stays empty — and the unguarded
  # summary loop over "${refreshed[@]}" aborted the command under bash 3.2.
  echo "test: update-index survives every target being skipped"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  rm docs/architecture.md
  set +e
  local err
  err=$("$DOC_TOOLS" update-index docs/architecture.md 2>&1 >/dev/null)
  local rc=$?
  set -e
  assert_eq "0" "$rc" "update-index exits 0 when all targets are skipped"
  assert_not_contains "$err" "unbound variable" "no bash 3.2 unbound-array abort"
  assert_contains "$err" "Refreshed 0 entries" "reports zero refreshed entries"
  teardown
}

test_scripts_are_free_of_bash4_only_constructs() {
  # `local -A` (bash 4.0+) shipped in cmd_fragments_merge and aborted every
  # doc-tools.sh invocation under macOS's /bin/bash 3.2 with
  # "local: -A: invalid option". A behavioural test cannot catch the class on
  # the Linux leg — there is no bash 3.2 there to run under — so this is a
  # static scan of every shell script the plugin ships, and it runs everywhere.
  #
  # bash 3.2 is a deliberate support target: it is what macOS ships as
  # /bin/bash, so it is the interpreter a consuming project's git hooks run
  # under unless the user has installed a newer bash themselves.
  echo "test: shipped scripts use no bash-4-only constructs (macOS /bin/bash is 3.2)"
  local repo_root
  repo_root="$(cd "$SCRIPT_DIR/.." && pwd)"

  # Explicit ship list rather than a glob-minus-tests: the patterns below appear
  # verbatim in this very file, so any discovery rule loose enough to pick up a
  # stray script in scripts/ will eventually match the test's own pattern
  # strings and report a phantom violation. These are exactly the scripts the
  # plugin installs into a consuming project.
  local targets=()
  local candidate
  for candidate in \
    "$repo_root"/scripts/doc-tools.sh \
    "$repo_root"/scripts/merge-doc-index.sh \
    "$repo_root"/scripts/hooks/*.sh \
    "$repo_root"/scripts/hooks/claude/*.sh \
    "$repo_root"/scripts/hooks/ci/doc-pr-release/*.sh \
    "$repo_root"/scripts/hooks/ci/doc-superpowers-steps/*.sh \
    "$repo_root"/scripts/hooks/git/*
  do
    [ -f "$candidate" ] && targets+=("$candidate")
  done

  TESTS_RUN=$((TESTS_RUN + 1))
  if [ ${#targets[@]} -eq 0 ]; then
    FAIL=$((FAIL + 1))
    # shellcheck disable=SC2059
    printf "${RED}  FAIL${NC}: no shipped scripts found to scan — the glob is wrong\n"
    return 0
  fi
  PASS=$((PASS + 1))
  # shellcheck disable=SC2059
  printf "${GREEN}  PASS${NC}: found %d shipped script(s) to scan\n" "${#targets[@]}"

  # Each entry: <label>|<ERE> (the label must not contain a pipe: the first
  # one separates the two). Kept as a flat list rather than a map so this
  # test does not itself need an associative array. `samples` is index-aligned:
  # one planted line per pattern that the pattern MUST match. The sweep planted
  # 12 bash-4 forms that the original 7 patterns all missed; a pattern that
  # stops matching its own planted form is reported as a FAIL, never silently.
  # Bracket expressions ([|], [$], [{], [(]) keep each ERE portable across GNU
  # and BSD grep, which disagree on backslash-escaped metacharacters.
  local patterns=(
    'associative array declaration (declare/local/typeset -A) [bash 4.0+]|(declare|local|typeset)[[:space:]]+-[a-zA-Z]*A[a-zA-Z]*[[:space:]]'
    'mapfile/readarray [bash 4.0+]|(^|[^[:alnum:]_-])(mapfile|readarray)[[:space:]]'
    'case-modification expansion ${v^^} / ${v,,} [bash 4.0+]|\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(\^\^|,,|\^|,)[^}]*\}'
    'append-and-redirect &>> [bash 4.0+]|&>>'
    'negative array index ${a[-1]} [bash 4.3+]|\$\{[A-Za-z_][A-Za-z0-9_]*\[-[0-9]'
    'coproc [bash 4.0+]|(^|[^[:alnum:]_-])coproc[[:space:]]'
    'wait -n [bash 4.3+]|(^|[^[:alnum:]_-])wait[[:space:]]+-n([[:space:]]|$)'
    'nameref (local/declare -n) [bash 4.3+]|(declare|local|typeset)[[:space:]]+-[a-zA-Z]*n[a-zA-Z]*[[:space:]]'
    'declare -g / -l / -u attributes [bash 4.0-4.2+]|(declare|local|typeset)[[:space:]]+-[a-zA-Z]*[glu][a-zA-Z]*[[:space:]]'
    'variable-set test [[ -v x ]] [bash 4.2+]|(\[\[|\[|(^|[^[:alnum:]_-])test)[[:space:]]+-v[[:space:]]'
    'pipe-stderr shorthand (pipe-ampersand) [bash 4.0+]|(^|[^|])[|]&'
    'negative substring length ${x:0:-1} [bash 4.2+]|[$][{][A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?:[^}:]*:[[:space:]]*-[0-9]'
    'transformation expansion ${x@Q} [bash 4.4+]|[$][{][A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?@[QEPAaKkUuL][}]'
    'named file-descriptor redirection {fd}> [bash 4.1+]|(^|[[:space:]])[{][A-Za-z_][A-Za-z0-9_]*[}](>>|<>|>&|<&|>|<)'
    "printf time format %(...)T [bash 4.2+]|printf[[:space:]].*%[-0-9]*[(]"
    'EPOCHSECONDS / EPOCHREALTIME [bash 5.0+]|EPOCH(SECONDS|REALTIME)'
    'shopt globstar [bash 4.0+]|(^|[^[:alnum:]_])globstar([^[:alnum:]_]|$)'
    'case fall-through ;;& / ;& [bash 4.0+]|;;&|(^|[^;]);&'
    'read -N [bash 4.1+]|(^|[^[:alnum:]_-])read[[:space:]]([^;|&]*[[:space:]])?-[a-zA-Z]*N'
  )
  local samples=(
    'local -A seen=()'
    'mapfile -t lines < "$f"'
    'echo "${v^^}"'
    'cmd &>> "$log"'
    'last="${a[-1]}"'
    'coproc worker { cat; }'
    'wait -n'
    'local -n ref="$1"'
    'declare -g COUNT=0'
    'if [[ -v CONFIG ]]; then :; fi'
    'make 2>&1 |& tee log'
    'trimmed="${x:0:-1}"'
    'quoted="${x@Q}"'
    'exec {lock_fd}>"$lock"'
    "printf '%(%Y-%m-%d)T' -1"
    'now=$EPOCHSECONDS'
    'shopt -s globstar'
    '  a) echo a ;;&'
    'IFS= read -r -N 4 buf'
  )

  local idx=0 spec
  TESTS_RUN=$((TESTS_RUN + 1))
  local unmatched="" sample_rc
  while [ "$idx" -lt "${#patterns[@]}" ]; do
    spec="${patterns[$idx]}"
    sample_rc=0
    grep -qE -- "${spec#*|}" <<<"${samples[$idx]}" 2>/dev/null || sample_rc=$?
    [ "$sample_rc" -eq 0 ] || unmatched="${unmatched}    ${spec%%|*}: rc=$sample_rc on planted '${samples[$idx]}'"$'\n'
    idx=$((idx + 1))
  done
  if [ -z "$unmatched" ] && [ "${#patterns[@]}" -eq "${#samples[@]}" ]; then
    PASS=$((PASS + 1))
    # shellcheck disable=SC2059
    printf "${GREEN}  PASS${NC}: every one of %d bash-4 patterns catches its planted form\n" "${#patterns[@]}"
  else
    FAIL=$((FAIL + 1))
    # shellcheck disable=SC2059
    printf "${RED}  FAIL${NC}: bash-4 pattern(s) miss their planted form (%d patterns, %d samples)\n%s" \
      "${#patterns[@]}" "${#samples[@]}" "$unmatched"
  fi

  # Full-line comments are blanked (line numbering preserved) before matching:
  # the fixes for these very bugs are documented in comments that name the
  # offending construct, and a guard that trips on its own rationale is a guard
  # someone disables. Inline code is left untouched, so a real construct is
  # still caught wherever it can actually execute.
  local scrubbed
  scrubbed=$(harness_mktemp bash4scan)

  for spec in "${patterns[@]}"; do
    local label="${spec%%|*}"
    local regex="${spec#*|}"
    local hits=""
    local target
    for target in "${targets[@]}"; do
      awk '{ if ($0 ~ /^[[:space:]]*#/) print ""; else print }' "$target" > "$scrubbed"
      local file_hits grep_rc=0
      file_hits=$(grep -nE -- "$regex" "$scrubbed" 2>&1) || grep_rc=$?
      # rc 1 = no match; rc >= 2 = the ERE itself is broken on this grep. A
      # broken pattern used to be swallowed by `|| true` and read as "clean".
      if [ "$grep_rc" -ge 2 ]; then
        hits="${hits}    ${target#"$repo_root/"}: grep rc=$grep_rc (pattern error): ${file_hits}"$'\n'
      elif [ "$grep_rc" -eq 0 ] && [ -n "$file_hits" ]; then
        hits="${hits}$(printf '%s\n' "$file_hits" | sed "s|^|    ${target#"$repo_root/"}:|")"$'\n'
      fi
    done
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ -z "$hits" ]; then
      PASS=$((PASS + 1))
      # shellcheck disable=SC2059
      printf "${GREEN}  PASS${NC}: no %s\n" "$label"
    else
      FAIL=$((FAIL + 1))
      # shellcheck disable=SC2059
      printf "${RED}  FAIL${NC}: %s\n%s" "$label" "$hits"
    fi
  done
  rm -f "$scrubbed"
}

test_build_index_and_check_freshness_beyond_argv_limits() {
  # Regression guard for "jq: Argument list too long" (exit 126), which killed
  # build-index on Linux at a few hundred entries.
  #
  # The ceiling is a BYTE size on a single argv string, not a doc count: Linux
  # caps one argument at MAX_ARG_STRLEN (32 pages = 131072 bytes) however large
  # ARG_MAX is, while macOS has no per-argument cap and only the ~1 MB total
  # ARG_MAX — which is exactly why this reproduced on the ubuntu leg, passed on
  # the macOS leg, and never showed up in a local run.
  #
  # Reaching that byte threshold with realistically-sized entries would need
  # ~3400 docs; measured, that is ~6 minutes of per-doc git/jq/hash work per
  # leg, which the suite cannot carry. The failure is about bytes, so this test
  # reaches the same threshold with fewer, larger entries and asserts on the
  # serialized size directly. The target is >1.2 MB — comfortably past BOTH the
  # Linux per-argument cap and the macOS total ARG_MAX, so it is a real guard on
  # both legs rather than a Linux-only one.
  echo "test: build-index + check-freshness handle a docs object larger than ARG_MAX"
  setup
  mkdir -p docs/synthetic

  local doc_count=260
  local pad
  pad=$(printf 'synthetic-%.0s' $(seq 1 500))   # ~5000 chars per entry

  local mapping_tmp
  mapping_tmp=$(harness_mktemp argmax)
  local i=0
  while [ "$i" -lt "$doc_count" ]; do
    printf '# doc %d\n' "$i" > "docs/synthetic/d$i.md"
    # Third field is doc_type; it is stored verbatim in the entry, so it is the
    # cheapest way to inflate the serialized index without 3400 files.
    printf 'docs/synthetic/d%d.md:src/:%s\n' "$i" "$pad" >> "$mapping_tmp"
    i=$((i + 1))
  done
  git add -A && git commit -m "synthetic docs" --quiet

  local err_file
  err_file=$(harness_mktemp argmax-stderr)
  local build_start build_elapsed
  build_start=$(date +%s)
  set +e
  "$DOC_TOOLS" build-index < "$mapping_tmp" 2>"$err_file"
  local build_rc=$?
  set -e
  build_elapsed=$(( $(date +%s) - build_start ))
  rm -f "$mapping_tmp"

  local build_err
  build_err=$(cat "$err_file" 2>/dev/null || true)
  assert_eq "0" "$build_rc" "build-index exits 0 (stderr: ${build_err:-none})"
  # These 5,000-character fields once cost ~8 s EACH under bash 3.2 (a
  # quadratic newline count in _rec_put): this build ran for over half an
  # hour there, and nothing failed — the suite just never finished.
  assert_true "build-index of $doc_count wide entries took ${build_elapsed}s (budget 60s)" \
    test "$build_elapsed" -le 60
  assert_not_contains "$build_err" "Argument list too long" "build-index does not hit the argv ceiling"

  # The premise of the test: if this is not comfortably over the platform caps,
  # the guard has quietly stopped guarding anything.
  local docs_bytes
  docs_bytes=$(jq -c '.docs' docs/.doc-index.json | wc -c | tr -d ' ')
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$docs_bytes" -gt 1200000 ]; then
    PASS=$((PASS + 1))
    # shellcheck disable=SC2059
    printf "${GREEN}  PASS${NC}: docs object is %s bytes (>1.2 MB; Linux per-arg cap 131072, macOS ARG_MAX 1048576)\n" "$docs_bytes"
  else
    FAIL=$((FAIL + 1))
    # shellcheck disable=SC2059
    printf "${RED}  FAIL${NC}: docs object only %s bytes — too small to exercise the argv ceiling\n" "$docs_bytes"
  fi

  local entry_count
  entry_count=$(jq '.docs | length' docs/.doc-index.json)
  assert_eq "$doc_count" "$entry_count" "all $doc_count entries survive the merge"

  # check-freshness passes the same oversized object to its final jq; assert it
  # too, since it has its own argv-sized values (docs + untracked_docs).
  echo "v2" > src/index.js
  git add -A && git commit -m "stale all" --quiet

  set +e
  local fresh_out
  fresh_out=$("$DOC_TOOLS" check-freshness 2>"$err_file")
  local fresh_rc=$?
  set -e
  local fresh_err
  fresh_err=$(cat "$err_file" 2>/dev/null || true)
  assert_eq "0" "$fresh_rc" "check-freshness exits 0 (stderr: ${fresh_err:-none})"
  assert_not_contains "$fresh_err" "Argument list too long" "check-freshness does not hit the argv ceiling"
  assert_json_field "$fresh_out" ".summary.stale" "$doc_count" "all $doc_count entries reported stale"
  teardown
}

test_check_freshness_scales_to_large_index() {
  # Regression guard for the 2026-05-26 perf rewrite (issue: per-entry jq
  # spawns made the full walk hit a ~10 min wall-clock ceiling at ~2000
  # entries). With the streaming-extraction + JSON-lines accumulator,
  # 500 entries should complete in well under 60 s on a developer laptop.
  #
  # Wall-clock alone is too blunt: a 4-jq-per-entry regression still finished
  # inside the budget on a fast machine. The primary guard therefore COUNTS jq
  # spawns through a logging shim on PATH. Since I-4 (sweep 05ea982) no jq
  # runs per entry — one pass extracts the entries, the verdicts go back as
  # one record stream — so the budget is a constant, independent of N. (The
  # loop used to spend 1 jq per entry plus 2 per stale entry: 3N here.) The
  # git work per entry is still T4's (I-1: content identity, batch-check).
  #
  # The wall-clock budget is a coarse backstop only; it includes the counting
  # shim's own per-spawn fork+exec, hence 120 s rather than 60 s.
  local doc_count=500 spawn_budget=10
  echo "test: check-freshness scales to ~$doc_count entries (constant jq spawns, within 120s)"
  setup
  # Build a synthetic index with 500 docs pointing at a single tracked
  # code dir, plus a deliberate stale ref to exercise compute_freshness.
  mkdir -p docs/synthetic
  local mapping_tmp
  mapping_tmp=$(harness_mktemp synth)
  local i=0
  while [ "$i" -lt "$doc_count" ]; do
    printf '# doc %d\n' "$i" > "docs/synthetic/d$i.md"
    printf 'docs/synthetic/d%d.md:src/:synthetic\n' "$i" >> "$mapping_tmp"
    i=$((i + 1))
  done
  git add -A && git commit -m "synthetic docs" --quiet
  "$DOC_TOOLS" build-index < "$mapping_tmp"
  rm -f "$mapping_tmp"

  # Touch code to make all 500 stale in one pass.
  echo "v2" > src/index.js
  git add -A && git commit -m "stale all" --quiet

  # Counting jq shim: appends one line per spawn, then execs the real jq.
  local real_jq shim_dir spawn_log
  real_jq=$(command -v jq)
  shim_dir=$(harness_mktemp_d jq-count)
  spawn_log="$shim_dir/spawns"
  : > "$spawn_log"
  printf '#!/bin/sh\necho x >> "%s"\nexec "%s" "$@"\n' "$spawn_log" "$real_jq" > "$shim_dir/jq"
  chmod +x "$shim_dir/jq"

  local start_ts end_ts elapsed output rc=0
  start_ts=$(date +%s)
  output=$(PATH="$shim_dir:$PATH" "$DOC_TOOLS" check-freshness) || rc=$?
  end_ts=$(date +%s)
  elapsed=$((end_ts - start_ts))
  local spawns
  spawns=$(wc -l < "$spawn_log" | tr -d ' ')

  assert_eq "0" "$rc" "check-freshness exits 0 on a $doc_count-entry index"
  assert_json_field "$output" ".summary.stale" "$doc_count" "all $doc_count synthetic docs reported stale"

  assert_true "check-freshness spawned $spawns jq processes for $doc_count stale entries (budget $spawn_budget, independent of N)" \
    test "$spawns" -le "$spawn_budget"

  # Real-world failures hit a ~600 s SIGKILL; 120 s still separates the classes.
  assert_true "check-freshness took ${elapsed}s for $doc_count docs (budget: 120s)" \
    test "$elapsed" -le 120
  teardown
}

# --- status tests ---

test_status_single_doc() {
  echo "test: status returns path, doc_type, status for a single doc"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  local output
  output=$("$DOC_TOOLS" status docs/architecture.md)
  assert_json_field "$output" ".path" "docs/architecture.md" "path field"
  assert_json_field "$output" ".doc_type" "architecture" "doc_type field"
  assert_json_field "$output" ".status" "current" "status field"
  teardown
}

test_status_stale_doc() {
  echo "test: status reports stale with reason=code_changed"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  echo "console.log('changed')" > src/index.js
  git add -A && git commit -m "change code" --quiet
  local output
  output=$("$DOC_TOOLS" status docs/architecture.md)
  assert_json_field "$output" ".status" "stale" "status=stale"
  assert_json_field "$output" ".reason" "code_changed" "reason=code_changed"
  teardown
}

test_status_unknown_path() {
  echo "test: status exits 1 for unknown path"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  set +e
  local output exit_code
  output=$("$DOC_TOOLS" status docs/nonexistent.md 2>&1)
  exit_code=$?
  set -e
  assert_eq "1" "$exit_code" "exits 1 for unknown path"
  teardown
}

test_status_requires_path_arg() {
  echo "test: status exits 2 (usage error) with no path argument"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  set +e
  local exit_code
  "$DOC_TOOLS" status >/dev/null 2>&1
  exit_code=$?
  set -e
  assert_eq "2" "$exit_code" "exits 2 with no arg"
  teardown
}

test_check_freshness_current_includes_doc_type() {
  echo "test: check-freshness current entry includes doc_type"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  local output
  output=$("$DOC_TOOLS" check-freshness)
  assert_json_field "$output" '.docs["docs/architecture.md"].doc_type' "architecture" "doc_type=architecture in current entry"
  teardown
}

test_check_freshness_current_includes_last_verified() {
  echo "test: check-freshness current entry includes last_verified"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  local output
  output=$("$DOC_TOOLS" check-freshness)
  local last_verified
  last_verified=$(echo "$output" | jq -r '.docs["docs/architecture.md"].last_verified')
  assert_eq "false" "$([ "$last_verified" = "null" ] || [ -z "$last_verified" ] && echo true || echo false)" "last_verified present in current entry"
  teardown
}

test_check_freshness_stale_includes_code_refs_changed() {
  echo "test: check-freshness stale entry includes code_refs_changed array"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  echo "console.log('changed')" > src/index.js
  git add -A && git commit -m "change code" --quiet
  local output
  output=$("$DOC_TOOLS" check-freshness)
  local refs_changed_len
  refs_changed_len=$(echo "$output" | jq '.docs["docs/architecture.md"].code_refs_changed | length')
  assert_eq "1" "$refs_changed_len" "code_refs_changed has 1 entry"
  assert_json_field "$output" '.docs["docs/architecture.md"].code_refs_changed[0]' "src/" "code_refs_changed contains src/"
  teardown
}

test_status_stale_includes_code_refs_changed() {
  echo "test: status stale entry includes code_refs_changed array"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  echo "console.log('changed')" > src/index.js
  git add -A && git commit -m "change code" --quiet
  local output
  output=$("$DOC_TOOLS" status docs/architecture.md)
  local refs_changed_len
  refs_changed_len=$(echo "$output" | jq '.code_refs_changed | length')
  assert_eq "1" "$refs_changed_len" "code_refs_changed has 1 entry"
  assert_json_field "$output" '.code_refs_changed[0]' "src/" "code_refs_changed contains src/"
  teardown
}

test_update_index_preserves_superseded_by() {
  echo "test: update-index preserves superseded_by field"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  local index_file="docs/.doc-index.json"
  local updated
  updated=$(jq '.docs["docs/architecture.md"].superseded_by = "docs/new-arch.md"' "$index_file")
  echo "$updated" > "$index_file"
  "$DOC_TOOLS" update-index docs/architecture.md >/dev/null 2>&1
  local superseded_by
  superseded_by=$(jq -r '.docs["docs/architecture.md"].superseded_by' docs/.doc-index.json)
  assert_eq "docs/new-arch.md" "$superseded_by" "superseded_by preserved"
  teardown
}

test_update_index_updates_generated_at() {
  echo "test: update-index updates generated_at"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  local orig_generated_at
  orig_generated_at=$(jq -r '.generated_at' docs/.doc-index.json)
  sleep 1
  "$DOC_TOOLS" update-index docs/architecture.md >/dev/null 2>&1
  local new_generated_at
  new_generated_at=$(jq -r '.generated_at' docs/.doc-index.json)
  if [ "$orig_generated_at" != "$new_generated_at" ]; then
    assert_eq "true" "true" "generated_at updated after update-index"
  else
    assert_eq "changed" "unchanged" "generated_at updated after update-index"
  fi
  teardown
}

# An empty stdin is the default in an agent's non-TTY shell, so it used to
# write an EMPTY index with rc 0 (sweep 05ea982 I-4). Zero mapping lines is
# now an error, and nothing is written.
test_build_index_empty_stdin() {
  echo "test: build-index with empty stdin exits non-zero and writes no index"
  setup
  local rc=0 err
  err=$(echo "" | "$DOC_TOOLS" build-index 2>&1) || rc=$?
  assert_true "build-index with empty stdin exits non-zero (rc=$rc)" test "$rc" -ne 0
  assert_contains "$err" "no mapping lines" "says there was nothing to index"
  assert_file_not_exists "docs/.doc-index.json" "no empty index is written"
  teardown
}

test_update_index_multiple_paths() {
  echo "test: update-index refreshes multiple paths at once"
  setup
  echo "# Workflows" > docs/workflows.md
  git add -A && git commit -m "add workflows" --quiet
  printf 'docs/architecture.md:src/:architecture\ndocs/workflows.md:src/:workflows\n' | "$DOC_TOOLS" build-index
  # Modify code to make both stale
  echo "// changed" >> src/index.js
  git add -A && git commit -m "change code" --quiet
  "$DOC_TOOLS" update-index docs/architecture.md docs/workflows.md >/dev/null 2>&1
  local result
  result=$("$DOC_TOOLS" check-freshness)
  local current_count
  current_count=$(echo "$result" | jq '.summary.current')
  assert_eq "2" "$current_count" "both docs current after multi-path update"
  teardown
}

# --- Version management tests ---

# Helper: create minimal version manifest files in test dir
setup_version_files() {
  echo '{"name":"test","version":"1.0.0"}' > package.json
  echo '{"name":"test","version":"1.0.0"}' > claude-code.json
  mkdir -p .claude-plugin .cursor-plugin
  echo '{"name":"test","version":"1.0.0"}' > .claude-plugin/plugin.json
  echo '{"name":"test","metadata":{"version":"1.0.0"},"plugins":[]}' > .claude-plugin/marketplace.json
  echo '{"name":"test","version":"1.0.0"}' > .cursor-plugin/plugin.json
  echo '{"name":"test","version":"1.0.0"}' > gemini-extension.json
  echo -e "# Release Notes\n\n## v1.0.0 (2026-01-01)" > RELEASE-NOTES.md
}

test_bump_version_updates_all_files() {
  echo "test: bump-version updates all 6 manifest files"
  setup
  setup_version_files
  set +e
  output=$("$DOC_TOOLS" bump-version 2.0.0 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_contains "$output" "Updated 6 file(s)" "reports 6 files updated"
  assert_eq "2.0.0" "$(jq -r .version package.json)" "package.json bumped"
  assert_eq "2.0.0" "$(jq -r .version claude-code.json)" "claude-code.json bumped"
  assert_eq "2.0.0" "$(jq -r .version .claude-plugin/plugin.json)" "plugin.json bumped"
  assert_eq "2.0.0" "$(jq -r .metadata.version .claude-plugin/marketplace.json)" "marketplace.json bumped"
  assert_eq "2.0.0" "$(jq -r .version .cursor-plugin/plugin.json)" "cursor plugin.json bumped"
  assert_eq "2.0.0" "$(jq -r .version gemini-extension.json)" "gemini-extension.json bumped"
  teardown
}

test_bump_version_idempotent() {
  echo "test: bump-version is idempotent"
  setup
  setup_version_files
  "$DOC_TOOLS" bump-version 1.0.0 >/dev/null 2>&1
  set +e
  output=$("$DOC_TOOLS" bump-version 1.0.0 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_contains "$output" "Updated 0 file(s)" "no files changed"
  teardown
}

test_bump_version_validates_semver() {
  echo "test: bump-version rejects invalid version format"
  setup
  set +e
  output=$("$DOC_TOOLS" bump-version "abc" 2>&1)
  exit_code=$?
  set -e
  assert_eq "1" "$exit_code" "exits 1"
  assert_contains "$output" "invalid version format" "error message"
  teardown
}

test_bump_version_requires_arg() {
  echo "test: bump-version requires a version argument"
  setup
  set +e
  output=$("$DOC_TOOLS" bump-version 2>&1)
  exit_code=$?
  set -e
  assert_eq "2" "$exit_code" "exits 2 (usage error)"
  assert_contains "$output" "requires a version" "error message"
  teardown
}

test_check_version_detects_mismatch() {
  echo "test: check-version detects version mismatch"
  setup
  setup_version_files
  # Desync one file
  echo '{"name":"test","version":"0.9.0"}' > package.json
  set +e
  output=$("$DOC_TOOLS" check-version 2>&1)
  exit_code=$?
  set -e
  assert_eq "1" "$exit_code" "exits 1 on mismatch"
  assert_contains "$output" "MISMATCH" "reports mismatch"
  assert_contains "$output" "package.json" "names the file"
  teardown
}

test_check_version_passes_when_synced() {
  echo "test: check-version passes when all versions match"
  setup
  setup_version_files
  set +e
  output=$("$DOC_TOOLS" check-version 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_contains "$output" "PASS" "reports pass"
  teardown
}

# --- fragments subcommand ---

_write_fragment() {
  # _write_fragment <path> <pr_number> <payload>
  # Computes hash from payload bytes and writes a well-formed fragment.
  local path="$1" pr_number="$2" payload="$3"
  local hash
  hash=$(printf '%s' "$payload" | { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } | awk '{print $1}')
  printf '<!-- doc-superpowers:fragment PR-%s -->\n<!-- doc-superpowers:hash %s -->\n%s' \
    "$pr_number" "$hash" "$payload" > "$path"
}

test_fragments_list_empty() {
  echo "test: fragments list with no RELEASE-NOTES.next dir prints []"
  setup
  local output
  output=$("$DOC_TOOLS" fragments list)
  assert_eq "[]" "$output" "list returns empty JSON array"
  teardown
}

test_fragments_list_valid() {
  echo "test: fragments list with one valid fragment"
  setup
  mkdir -p RELEASE-NOTES.next
  _write_fragment RELEASE-NOTES.next/PR-42.md 42 $'### Added\n- thing\n'
  local count valid
  count=$("$DOC_TOOLS" fragments list | jq 'length')
  assert_eq "1" "$count" "list reports one fragment"
  valid=$("$DOC_TOOLS" fragments list | jq '.[0].hash_valid')
  assert_eq "true" "$valid" "hash_valid is true"
  teardown
}

test_fragments_validate_drifted() {
  echo "test: validate detects drifted hash (exit 1)"
  setup
  mkdir -p RELEASE-NOTES.next
  cat > RELEASE-NOTES.next/PR-42.md <<'EOF'
<!-- doc-superpowers:fragment PR-42 -->
<!-- doc-superpowers:hash 0000000000000000000000000000000000000000000000000000000000000000 -->
### Added
- thing
EOF
  set +e
  "$DOC_TOOLS" fragments validate RELEASE-NOTES.next/PR-42.md >/dev/null 2>&1
  local rc=$?
  set -e
  assert_eq "1" "$rc" "validate exits 1 on drifted hash"
  teardown
}

test_fragments_merge_includes_drifted() {
  echo "test: merge includes drifted fragments (human edits authoritative) with WARN"
  setup
  mkdir -p RELEASE-NOTES.next
  # Write a fragment with a deliberately-wrong stored hash.
  cat > RELEASE-NOTES.next/PR-7.md <<'EOF'
<!-- doc-superpowers:fragment PR-7 -->
<!-- doc-superpowers:hash 0000000000000000000000000000000000000000000000000000000000000000 -->
### Added
- drifted bullet
EOF
  git add RELEASE-NOTES.next/PR-7.md
  git commit -q -m "PR-7 drifted"

  # Use the empty tree as the half-open range start so the PR-7 commit (the
  # root commit) is included.
  local empty_tree out stderr_out err_file rc=0
  err_file=$(harness_mktemp merge-stderr)
  empty_tree=$(git hash-object -t tree --stdin </dev/null)
  out=$("$DOC_TOOLS" fragments merge "$empty_tree" HEAD 2>"$err_file") || rc=$?
  stderr_out=$(cat "$err_file" 2>/dev/null || true)
  assert_eq "0" "$rc" "merge exits 0 with a drifted fragment (stderr: ${stderr_out:-none})"

  assert_contains "$out" "drifted bullet" "drifted fragment content is merged"
  assert_contains "$stderr_out" "drifted" "WARN about drift on stderr"
  teardown
}

test_fragments_merge_preserves_non_canonical_sections() {
  echo "test: merge preserves non-canonical headings (e.g. ### Notes)"
  setup
  mkdir -p RELEASE-NOTES.next
  _write_fragment RELEASE-NOTES.next/PR-5.md 5 $'### Notes\n- non-canonical note\n### Breaking Changes\n- multi-word heading\n'
  git add RELEASE-NOTES.next/PR-5.md
  git commit -q -m "PR-5"
  local out rc=0
  out=$("$DOC_TOOLS" fragments merge "$(git hash-object -t tree --stdin </dev/null)" HEAD) || rc=$?
  assert_eq "0" "$rc" "merge exits 0 on non-canonical headings"
  assert_contains "$out" "non-canonical note" "non-canonical bullet survives merge"
  assert_contains "$out" "multi-word heading" "multi-word heading bullet survives"
  assert_contains "$out" "### Notes" "Notes heading emitted"
  assert_contains "$out" "### Breaking Changes" "multi-word heading emitted verbatim"
  teardown
}

test_fragments_merge_dedupes_bullets() {
  echo "test: merge dedupes identical bullets within a section"
  setup
  mkdir -p RELEASE-NOTES.next
  _write_fragment RELEASE-NOTES.next/PR-1.md 1 $'### Added\n- same bullet\n'
  _write_fragment RELEASE-NOTES.next/PR-2.md 2 $'### Added\n- same bullet\n'
  git add RELEASE-NOTES.next/PR-1.md RELEASE-NOTES.next/PR-2.md
  git commit -q -m "PRs"
  local out count rc=0
  out=$("$DOC_TOOLS" fragments merge "$(git hash-object -t tree --stdin </dev/null)" HEAD) || rc=$?
  assert_eq "0" "$rc" "merge exits 0 on duplicate bullets"
  count=$(grep -c -- "- same bullet" <<<"$out" || true)
  assert_eq "1" "$count" "duplicate bullet appears exactly once"
  teardown
}

test_fragments_list_skips_non_numeric() {
  echo "test: list skips non-numeric PR filenames without crashing"
  setup
  mkdir -p RELEASE-NOTES.next
  _write_fragment RELEASE-NOTES.next/PR-9.md 9 $'### Added\n- ok\n'
  # Drop a junk file that matches PR-*.md but isn't numeric.
  cat > RELEASE-NOTES.next/PR-junk.md <<'EOF'
<!-- doc-superpowers:fragment PR-junk -->
<!-- doc-superpowers:hash 0000000000000000000000000000000000000000000000000000000000000000 -->
### Added
- junk
EOF
  local out count
  set +e
  out=$("$DOC_TOOLS" fragments list 2>/dev/null)
  local rc=$?
  set -e
  assert_eq "0" "$rc" "list does not crash on non-numeric filename"
  count=$(printf '%s' "$out" | jq 'length')
  assert_eq "1" "$count" "only the numeric fragment is listed"
  teardown
}

test_fragments_merge_paths_out() {
  echo "test: merge --paths-out writes only consumed fragment paths"
  setup
  mkdir -p RELEASE-NOTES.next
  _write_fragment RELEASE-NOTES.next/PR-3.md 3 $'### Added\n- in-range\n'
  git add RELEASE-NOTES.next/PR-3.md
  git commit -q -m "PR-3"
  local before_tag
  before_tag=$(git rev-parse HEAD)
  # Fragment introduced AFTER the tag — should be the only consumed one.
  _write_fragment RELEASE-NOTES.next/PR-4.md 4 $'### Added\n- after-tag\n'
  git add RELEASE-NOTES.next/PR-4.md
  git commit -q -m "PR-4"

  local out paths_file
  paths_file=$(harness_mktemp paths-out)
  local rc=0
  out=$("$DOC_TOOLS" fragments merge "$before_tag" HEAD --paths-out="$paths_file") || rc=$?
  assert_eq "0" "$rc" "merge exits 0 with --paths-out"
  assert_contains "$out" "after-tag" "PR-4 (post-tag) is consumed"
  assert_not_contains "$out" "in-range" "PR-3 (pre-tag) is NOT in merged output"
  # paths-out should contain PR-4.md only.
  if grep -q "PR-4.md" "$paths_file" && ! grep -q "PR-3.md" "$paths_file"; then
    PASS=$((PASS + 1))
    TESTS_RUN=$((TESTS_RUN + 1))
    # shellcheck disable=SC2059
    printf "${GREEN}  PASS${NC}: paths-out contains only %s\n" "PR-4.md"
  else
    FAIL=$((FAIL + 1))
    TESTS_RUN=$((TESTS_RUN + 1))
    # shellcheck disable=SC2059
    printf "${RED}  FAIL${NC}: paths-out content unexpected: %s\n" "$(cat "$paths_file")"
  fi
  rm -f "$paths_file"
  teardown
}

test_fragments_merge_errors_outside_git_repo() {
  echo "test: merge errors gracefully outside a git repo"
  local tmp
  tmp=$(harness_mktemp_d not-a-repo)
  local err_file
  err_file=$(harness_mktemp merge-stderr)
  set +e
  ( cd "$tmp" && "$DOC_TOOLS" fragments merge HEAD~1 HEAD >/dev/null 2>"$err_file" )
  local rc=$?
  set -e
  local stderr_out
  stderr_out=$(cat "$err_file" 2>/dev/null || true)
  rm -rf "$tmp"
  assert_eq "2" "$rc" "merge exits 2 outside git repo"
  assert_contains "$stderr_out" "git repo" "stderr explains the problem"
}

test_fragments_merge_orders_by_n() {
  echo "test: merge orders fragments by ascending integer N"
  setup
  mkdir -p RELEASE-NOTES.next

  # PR-101 introduced first.
  _write_fragment RELEASE-NOTES.next/PR-101.md 101 $'### Added\n- larger N\n'
  git add RELEASE-NOTES.next/PR-101.md
  git commit -q -m "PR-101"
  local base
  base=$(git rev-list --max-parents=0 HEAD)

  # PR-99 introduced second.
  _write_fragment RELEASE-NOTES.next/PR-99.md 99 $'### Added\n- smaller N\n'
  git add RELEASE-NOTES.next/PR-99.md
  git commit -q -m "PR-99"

  local out pos_99 pos_101 rc=0
  out=$("$DOC_TOOLS" fragments merge "$base" HEAD) || rc=$?
  assert_eq "0" "$rc" "merge exits 0 on a two-fragment range"
  pos_99=$(grep -n "smaller N" <<<"$out" | sed -n '1s/:.*//p' || true)
  pos_101=$(grep -n "larger N" <<<"$out" | sed -n '1s/:.*//p' || true)

  TESTS_RUN=$((TESTS_RUN + 1))
  if [ -n "$pos_99" ] && [ -n "$pos_101" ] && [ "$pos_99" -lt "$pos_101" ]; then
    PASS=$((PASS + 1))
    printf "${GREEN}  PASS${NC}: PR-99 appears before PR-101 (pos_99=%s pos_101=%s)\n" "$pos_99" "$pos_101"
  else
    FAIL=$((FAIL + 1))
    printf "${RED}  FAIL${NC}: expected PR-99 before PR-101, got pos_99=%s pos_101=%s\n    output: %s\n" "$pos_99" "$pos_101" "$out"
  fi
  teardown
}

test_set_implementation_creates_block() {
  echo "test: set-implementation creates Implementation: block when absent"
  setup
  cat > test-adr.md <<'EOF'
# Test ADR

**Date:** 2026-05-16

## Context
EOF
  "$DOC_TOOLS" set-implementation test-adr.md --ref "PR: #123" --status complete >/dev/null
  assert_contains "$(cat test-adr.md)" "Implementation:" "Implementation: block added"
  assert_contains "$(cat test-adr.md)" "  - PR: #123 — complete" "ref line added"
  teardown
}

test_set_implementation_appends_to_existing() {
  echo "test: set-implementation appends to existing Implementation: block"
  setup
  cat > test-adr.md <<'EOF'
# Test ADR

**Date:** 2026-05-16

Implementation:
  - PR: #100 — complete

## Context
EOF
  "$DOC_TOOLS" set-implementation test-adr.md --ref "PR: #200" --status partial --note "phase 1" >/dev/null
  local content
  content=$(cat test-adr.md)
  assert_contains "$content" "  - PR: #100 — complete" "preserves existing ref"
  assert_contains "$content" "  - PR: #200 — partial — phase 1" "appends new ref with note"
  teardown
}

test_set_implementation_replaces_existing_ref() {
  echo "test: set-implementation replaces line when ref already present"
  setup
  cat > test-adr.md <<'EOF'
# Test ADR

**Date:** 2026-05-16

Implementation:
  - PR: #100 — in-progress
EOF
  "$DOC_TOOLS" set-implementation test-adr.md --ref "PR: #100" --status complete >/dev/null
  local content
  content=$(cat test-adr.md)
  assert_contains "$content" "  - PR: #100 — complete" "ref status updated"
  assert_not_contains "$content" "in-progress" "old status replaced (no stale 'in-progress')"
  teardown
}

test_set_implementation_rejects_invalid_status() {
  echo "test: set-implementation rejects invalid status enum"
  setup
  cat > test-adr.md <<'EOF'
# Test ADR

**Date:** 2026-05-16
EOF
  set +e
  local output
  output=$("$DOC_TOOLS" set-implementation test-adr.md --ref "PR: #1" --status nonsense 2>&1)
  local rc=$?
  set -e
  assert_eq "2" "$rc" "exits 2 on invalid status"
  assert_contains "$output" "invalid status" "error message names the problem"
  teardown
}

test_implementation_status_parses_block() {
  echo "test: implementation-status emits the parsed block"
  setup
  cat > test-adr.md <<'EOF'
# Test ADR

Implementation:
  - PR: #1 — complete
  - PR: #2 — partial

## Body
EOF
  local out
  out=$("$DOC_TOOLS" implementation-status test-adr.md)
  assert_contains "$out" "PR: #1 — complete" "first ref echoed"
  assert_contains "$out" "PR: #2 — partial" "second ref echoed"
  teardown
}

test_implementation_status_no_field() {
  echo "test: implementation-status reports missing field"
  setup
  cat > test-adr.md <<'EOF'
# Test ADR

## Body
EOF
  local out
  out=$("$DOC_TOOLS" implementation-status test-adr.md)
  assert_contains "$out" "no Implementation field" "missing-field message"
  teardown
}

test_update_index_captures_implementation() {
  echo "test: update-index captures Implementation: block into entry"
  setup
  mkdir -p docs/adr
  cat > docs/adr/ADR-X.md <<'EOF'
# ADR X

Implementation:
  - PR: #42 — complete
  - PR: #43 — partial
EOF
  local mapping="docs/adr/ADR-X.md::adr"
  echo "$mapping" | "$DOC_TOOLS" build-index
  "$DOC_TOOLS" update-index docs/adr/ADR-X.md >/dev/null 2>&1
  local impl_count
  impl_count=$(jq '.docs["docs/adr/ADR-X.md"].implementation | length' docs/.doc-index.json)
  assert_eq "2" "$impl_count" "implementation array has 2 entries"
  local first
  first=$(jq -r '.docs["docs/adr/ADR-X.md"].implementation[0]' docs/.doc-index.json)
  assert_eq "PR: #42 — complete" "$first" "first impl entry preserved"
  teardown
}

# --- `tools` subcommand (Feature A: standalone install/uninstall/status) ---

test_tools_install_vendors_doc_tools_default_dest() {
  echo "test: tools install vendors doc-tools.sh into .github/scripts by default"
  setup
  set +e
  local output
  output=$("$DOC_TOOLS" tools install 2>&1)
  local exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_exists ".github/scripts/doc-tools.sh" "doc-tools.sh vendored at default dest"
  assert_true "vendored copy is executable" test -x ".github/scripts/doc-tools.sh"
  assert_contains "$output" "Installed doc-tools.sh" "install message"
  teardown
}

test_tools_install_custom_dest() {
  echo "test: tools install --dest <path> vendors to custom dest"
  setup
  set +e
  local output
  output=$("$DOC_TOOLS" tools install --dest scripts/vendor 2>&1)
  local exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_exists "scripts/vendor/doc-tools.sh" "doc-tools.sh at custom dest"
  assert_file_not_exists ".github/scripts/doc-tools.sh" "default dest NOT used"
  teardown
}

test_tools_install_with_helpers() {
  echo "test: tools install --with-helpers copies doc-pr-release helpers + RELEASE-NOTES.next/README.md"
  setup
  set +e
  local output
  output=$("$DOC_TOOLS" tools install --with-helpers 2>&1)
  local exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_exists ".github/scripts/doc-tools.sh" "doc-tools.sh vendored"
  assert_file_exists ".github/scripts/doc-pr-release/extract-context.sh" "helper installed"
  assert_file_exists ".github/scripts/doc-pr-release/update-pr-body.sh" "helper installed"
  assert_file_exists ".github/scripts/doc-pr-release/commit-and-push.sh" "helper installed"
  assert_file_exists "RELEASE-NOTES.next/README.md" "fragment spec installed"
  teardown
}

test_tools_install_without_helpers_default() {
  echo "test: tools install (default, no --with-helpers) does NOT install helpers"
  setup
  set +e
  "$DOC_TOOLS" tools install >/dev/null 2>&1
  set -e
  assert_file_exists ".github/scripts/doc-tools.sh" "doc-tools.sh vendored"
  assert_true "helpers dir NOT created" test ! -d ".github/scripts/doc-pr-release"
  assert_file_not_exists "RELEASE-NOTES.next/README.md" "fragment spec NOT created"
  teardown
}

test_tools_uninstall_removes_vendored_copy() {
  echo "test: tools uninstall removes vendored doc-tools.sh"
  setup
  "$DOC_TOOLS" tools install >/dev/null 2>&1
  assert_file_exists ".github/scripts/doc-tools.sh" "installed first"
  set +e
  local output
  output=$("$DOC_TOOLS" tools uninstall 2>&1)
  local exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_not_exists ".github/scripts/doc-tools.sh" "doc-tools.sh removed"
  assert_contains "$output" "Removed" "removal message"
  teardown
}

test_tools_uninstall_removes_unmodified_helpers() {
  echo "test: tools uninstall removes helper dir when files match plugin copy"
  setup
  "$DOC_TOOLS" tools install --with-helpers >/dev/null 2>&1
  assert_file_exists ".github/scripts/doc-pr-release/extract-context.sh" "installed"
  set +e
  "$DOC_TOOLS" tools uninstall >/dev/null 2>&1
  set -e
  assert_true "helpers dir removed (no local edits)" test ! -d ".github/scripts/doc-pr-release"
  teardown
}

test_tools_uninstall_keeps_modified_helpers() {
  echo "test: tools uninstall KEEPS helpers if they have local edits"
  setup
  "$DOC_TOOLS" tools install --with-helpers >/dev/null 2>&1
  echo "# locally modified" >> .github/scripts/doc-pr-release/extract-context.sh
  set +e
  local output
  output=$("$DOC_TOOLS" tools uninstall 2>&1)
  set -e
  assert_file_exists ".github/scripts/doc-pr-release/extract-context.sh" "modified helper preserved"
  assert_contains "$output" "Kept" "kept message shown"
  teardown
}

test_tools_uninstall_preserves_release_notes_next_readme() {
  echo "test: tools uninstall does NOT remove RELEASE-NOTES.next/README.md (may have edits)"
  setup
  "$DOC_TOOLS" tools install --with-helpers >/dev/null 2>&1
  assert_file_exists "RELEASE-NOTES.next/README.md" "installed"
  set +e
  "$DOC_TOOLS" tools uninstall >/dev/null 2>&1
  set -e
  assert_file_exists "RELEASE-NOTES.next/README.md" "README preserved on uninstall"
  teardown
}

test_tools_status_not_installed() {
  echo "test: tools status reports not-installed when nothing vendored"
  setup
  set +e
  local output
  output=$("$DOC_TOOLS" tools status 2>&1)
  local exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0 (read-only)"
  assert_contains "$output" "not installed" "reports not installed"
  teardown
}

test_tools_status_installed_matches_plugin() {
  echo "test: tools status reports matches-plugin when installed unmodified"
  setup
  "$DOC_TOOLS" tools install >/dev/null 2>&1
  set +e
  local output
  output=$("$DOC_TOOLS" tools status 2>&1)
  local exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_contains "$output" "matches plugin" "reports matches plugin"
  teardown
}

test_tools_status_reports_drift() {
  echo "test: tools status reports DRIFTED when vendored copy diverges"
  setup
  "$DOC_TOOLS" tools install >/dev/null 2>&1
  echo "# drifted" >> .github/scripts/doc-tools.sh
  set +e
  local output
  output=$("$DOC_TOOLS" tools status 2>&1)
  local exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_contains "$output" "DRIFTED" "reports drift"
  teardown
}

test_tools_install_unknown_flag_errors() {
  echo "test: tools install --bogus errors"
  setup
  set +e
  local output
  output=$("$DOC_TOOLS" tools install --bogus 2>&1)
  local exit_code=$?
  set -e
  assert_eq "2" "$exit_code" "exits 2"
  assert_contains "$output" "Unknown option" "clear error"
  teardown
}

# --- Doc-path key normalization (add-entry and siblings) ---
#
# The doc-index is keyed by working-tree-relative paths; every other consumer
# (update-index, check-freshness, the coverage gate, the merge driver) looks
# entries up by that key. A non-relative key can be written but never found, so
# these commands must normalize it or refuse it — never write it silently.
#
# `$PWD` is used for the "absolute, inside the repo" cases on purpose: on macOS
# mktemp -d returns a /var/... path that symlinks to /private/var/..., so these
# also cover physical (symlink-resolving) path comparison.

test_add_entry_accepts_relative_path() {
  echo "test: add-entry accepts the documented relative form (control)"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  echo "# design" > docs/design.md
  set +e
  local output
  output=$(echo "docs/design.md:src/:design" | "$DOC_TOOLS" add-entry 2>&1)
  local exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0 for relative path"
  local json
  json=$(cat docs/.doc-index.json)
  assert_json_field "$json" '.docs | has("docs/design.md")' "true" "relative key stored verbatim"
  assert_contains "$output" "Added 1 entry" "reports the add"
  teardown
}

test_add_entry_normalizes_absolute_path_inside_repo() {
  echo "test: add-entry rewrites an absolute in-tree path to a relative key"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  echo "# design" > docs/design.md
  set +e
  local output
  output=$(echo "$PWD/docs/design.md:src/:design" | "$DOC_TOOLS" add-entry 2>&1)
  local exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  local json
  json=$(cat docs/.doc-index.json)
  assert_json_field "$json" '.docs | has("docs/design.md")' "true" "stored under the relative key"
  local keys
  keys=$(echo "$json" | jq -r '.docs | keys[]')
  assert_not_contains "$keys" "$PWD" "no absolute key written"
  assert_contains "$output" "docs/design.md" "reports the normalized path"
  teardown
}

test_add_entry_rejects_path_outside_repo() {
  echo "test: add-entry rejects an out-of-tree path loudly and writes nothing"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  local before
  before=$(jq -S '.docs' docs/.doc-index.json)
  set +e
  local output
  output=$(echo "/etc/hosts:src/:design" | "$DOC_TOOLS" add-entry 2>&1)
  local exit_code=$?
  set -e
  assert_eq "1" "$exit_code" "exits non-zero"
  assert_contains "$output" "outside the working directory" "explains why"
  local after
  after=$(jq -S '.docs' docs/.doc-index.json)
  assert_eq "$before" "$after" "index docs unchanged"
  teardown
}

test_add_entry_mixed_batch_applies_valid_and_fails() {
  echo "test: add-entry applies valid lines, rejects invalid, still exits non-zero"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  echo "# design" > docs/design.md
  set +e
  local output
  output=$(printf '%s\n%s\n' "/etc/hosts:src/:design" "docs/design.md:src/:design" \
    | "$DOC_TOOLS" add-entry 2>&1)
  local exit_code=$?
  set -e
  assert_eq "1" "$exit_code" "exits non-zero because one line was invalid"
  local json
  json=$(cat docs/.doc-index.json)
  assert_json_field "$json" '.docs | has("docs/design.md")' "true" "valid line still applied"
  assert_contains "$output" "Rejected 1 invalid mapping line" "reports the rejection"
  teardown
}

test_add_entry_reports_added_paths() {
  echo "test: add-entry enumerates what it added (no dangling colon)"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  echo "# design" > docs/design.md
  set +e
  local output
  output=$(echo "docs/design.md:src/:design" | "$DOC_TOOLS" add-entry 2>&1)
  set -e
  assert_contains "$output" "  docs/design.md" "lists the added path"
  # Nothing added => no trailing colon promising a list that never comes.
  set +e
  local none
  none=$(echo "/etc/hosts:src/:design" | "$DOC_TOOLS" add-entry 2>&1)
  set -e
  assert_contains "$none" "Added 0 entries" "reports a zero count"
  assert_not_contains "$none" "Added 0 entries:" "no dangling colon when nothing added"
  teardown
}

test_add_entry_normalizes_dot_segments() {
  echo "test: add-entry collapses ./ and ../ segments into the canonical key"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  echo "# design" > docs/design.md
  set +e
  echo "./docs/design.md:src/:design" | "$DOC_TOOLS" add-entry >/dev/null 2>&1
  local exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  local json
  json=$(cat docs/.doc-index.json)
  assert_json_field "$json" '.docs | has("docs/design.md")' "true" "./ collapsed to canonical key"
  assert_json_field "$json" '.docs | has("./docs/design.md")' "false" "no ./-prefixed duplicate key"
  teardown
}

test_add_entry_preserves_dots_in_filenames() {
  echo "test: add-entry does not mangle dots that are not path segments"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  mkdir -p docs/v1.2
  echo "# notes" > docs/v1.2/notes.md
  set +e
  echo "docs/v1.2/notes.md:src/:design" | "$DOC_TOOLS" add-entry >/dev/null 2>&1
  local exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  local json
  json=$(cat docs/.doc-index.json)
  assert_json_field "$json" '.docs | has("docs/v1.2/notes.md")' "true" "dotted filename preserved"
  teardown
}

test_build_index_rejects_path_outside_repo() {
  echo "test: build-index aborts on an out-of-tree path without writing a partial index"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  local before
  before=$(cat docs/.doc-index.json)
  set +e
  local output
  # --force: the index exists, and without it build-index refuses before it
  # ever reads a line; this test is about the invalid line.
  output=$(printf '%s\n%s\n' "docs/architecture.md:src/:architecture" "/etc/hosts:src/:design" \
    | "$DOC_TOOLS" build-index --force 2>&1)
  local exit_code=$?
  set -e
  assert_eq "1" "$exit_code" "exits non-zero"
  assert_contains "$output" "index NOT written" "says the index was left alone"
  local after
  after=$(cat docs/.doc-index.json)
  assert_eq "$before" "$after" "pre-existing index untouched"
  teardown
}

test_build_index_normalizes_absolute_path_inside_repo() {
  echo "test: build-index rewrites an absolute in-tree path to a relative key"
  setup
  echo "$PWD/docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  local json
  json=$(cat docs/.doc-index.json)
  assert_json_field "$json" '.docs | has("docs/architecture.md")' "true" "stored under the relative key"
  local keys
  keys=$(echo "$json" | jq -r '.docs | keys[]')
  assert_not_contains "$keys" "$PWD" "no absolute key written"
  teardown
}

test_update_index_accepts_absolute_path_inside_repo() {
  echo "test: update-index resolves an absolute in-tree path to its entry"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  set +e
  local output
  output=$("$DOC_TOOLS" update-index "$PWD/docs/architecture.md" 2>&1)
  local exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_contains "$output" "Refreshed 1 entry" "refreshed the entry"
  teardown
}

test_remove_entry_accepts_absolute_path_inside_repo() {
  echo "test: remove-entry removes via an absolute in-tree path (was a silent no-op)"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  set +e
  local output
  output=$("$DOC_TOOLS" remove-entry "$PWD/docs/architecture.md" 2>&1)
  local exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_contains "$output" "Removed 1 entry" "actually removed it"
  local json
  json=$(cat docs/.doc-index.json)
  assert_json_field "$json" '.docs | has("docs/architecture.md")' "false" "entry gone"
  teardown
}

test_remove_entry_rejects_path_outside_repo() {
  echo "test: remove-entry rejects an out-of-tree path"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  set +e
  "$DOC_TOOLS" remove-entry /etc/hosts >/dev/null 2>&1
  local exit_code=$?
  set -e
  assert_eq "1" "$exit_code" "exits non-zero"
  teardown
}

test_remove_entry_missing_relative_path_still_skips() {
  echo "test: remove-entry still SKIPs a valid-but-absent relative path (exit 0)"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  set +e
  local output
  output=$("$DOC_TOOLS" remove-entry docs/nope.md 2>&1)
  local exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0 — unchanged behaviour"
  assert_contains "$output" "SKIP" "reports the skip"
  teardown
}

test_deprecate_entry_normalizes_paths_and_superseded_by() {
  echo "test: deprecate-entry normalizes both the target and --superseded-by"
  setup
  echo "# design" > docs/design.md
  printf '%s\n%s\n' "docs/architecture.md:src/:architecture" "docs/design.md:src/:design" \
    | "$DOC_TOOLS" build-index
  set +e
  local exit_code
  "$DOC_TOOLS" deprecate-entry --superseded-by "$PWD/docs/design.md" \
    "$PWD/docs/architecture.md" >/dev/null 2>&1
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  local json
  json=$(cat docs/.doc-index.json)
  assert_json_field "$json" '.docs["docs/architecture.md"].status' "deprecated" "target deprecated"
  assert_json_field "$json" '.docs["docs/architecture.md"].superseded_by' "docs/design.md" \
    "superseded_by stored as a relative key"
  teardown
}

test_status_accepts_absolute_path_inside_repo() {
  echo "test: status resolves an absolute in-tree path to its entry"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  set +e
  local output
  output=$("$DOC_TOOLS" status "$PWD/docs/architecture.md" 2>&1)
  local exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_contains "$output" "docs/architecture.md" "reports the relative path"
  teardown
}

# --- move-entry: re-key without metadata loss ---------------------------------
#
# Two harness properties make the obvious assertions here VACUOUS, and both are
# worked around deliberately below:
#
#   1. iso_now() has 1-second resolution, so two writes in the same second
#      produce byte-identical last_verified / generated_at strings. An assertion
#      that a stamp was "preserved" therefore passes against an implementation
#      that re-stamps it, and an assertion that generated_at CHANGED fails
#      spuriously without a sleep. (test_update_index_updates_generated_at
#      already carries a sleep 1 for exactly this reason.)
#   2. A pure `git mv` leaves file content — and so the content hash —
#      unchanged, and a fixture with no second commit leaves code_commit
#      unchanged. So "preserved" passes against re-derivation there too.
#
# Preservation is therefore asserted against injected SENTINEL values that no
# re-deriving implementation could reproduce, and the hash assertion is made
# after mutating the file so a recomputed hash necessarily differs.

# Inject a code_commit / last_verified pair that cannot arise from re-derivation.
# Writes through a temp file inside $TEST_DIR (never /tmp) so the two CI matrix
# legs cannot race on a shared path.
_mv_inject_sentinels() {
  local key="$1"
  jq --arg k "$key" \
    '.docs[$k].code_commit = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
    | .docs[$k].last_verified = "2020-01-01T00:00:00Z"' \
    docs/.doc-index.json > docs/.idx.tmp && mv docs/.idx.tmp docs/.doc-index.json
}

test_move_entry_preserves_all_metadata() {
  echo "test: move-entry re-keys an entry and preserves code_refs/code_commit/last_verified"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  _mv_inject_sentinels "docs/architecture.md"
  local old_hash
  old_hash=$(jq -r '.docs["docs/architecture.md"].content_hash' docs/.doc-index.json)
  # `implementation` is named in the issue's loss table as a field the
  # remove-entry + add-entry path drops, so assert it explicitly rather than
  # leaning on the generic unknown-field test.
  jq '.docs["docs/architecture.md"].implementation = ["ADR-001 (shipped)"]' \
    docs/.doc-index.json > docs/.idx.tmp && mv docs/.idx.tmp docs/.doc-index.json

  git mv docs/architecture.md docs/arch-renamed.md
  # Mutate content so a recomputed hash necessarily DIFFERS from the stored one.
  echo "renamed and edited" >> docs/arch-renamed.md

  local report
  report=$("$DOC_TOOLS" move-entry docs/architecture.md docs/arch-renamed.md 2>&1)

  local json
  json=$(cat docs/.doc-index.json)
  # `.docs["absent"]` is null, which is ALSO what a destroyed .docs map yields —
  # so assert has()==false plus the surviving entry count.
  assert_json_field "$json" '.docs | has("docs/architecture.md")' "false" "old key is gone"
  assert_json_field "$json" '.docs | length' "1" "entry count unchanged (nothing else dropped)"
  assert_json_field "$json" '.docs["docs/arch-renamed.md"].code_refs[0]' "src/" "code_refs preserved"
  assert_json_field "$json" '.docs["docs/arch-renamed.md"].code_commit' \
    "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "code_commit preserved, not re-queried"
  assert_json_field "$json" '.docs["docs/arch-renamed.md"].last_verified' \
    "2020-01-01T00:00:00Z" "last_verified preserved, not re-stamped"
  assert_json_field "$json" '.docs["docs/arch-renamed.md"].doc_type' "architecture" "doc_type preserved"
  assert_json_field "$json" '.docs["docs/arch-renamed.md"].implementation[0]' "ADR-001 (shipped)" \
    "implementation array preserved (the field add-entry drops entirely)"
  assert_json_field "$json" '.docs["docs/arch-renamed.md"].content_hash' \
    "sha256:$(hash_file docs/arch-renamed.md)" "content_hash recomputed at new path"
  local new_hash
  new_hash=$(echo "$json" | jq -r '.docs["docs/arch-renamed.md"].content_hash')
  if [ "$new_hash" = "$old_hash" ]; then
    assert_eq "differs" "identical" "recomputed hash actually differs from the stored one"
  else
    assert_eq "differs" "differs" "recomputed hash actually differs from the stored one"
  fi
  # The success report was otherwise unasserted — renaming it to anything left the
  # suite green. Includes the `->` arrow, which is deliberately ASCII.
  assert_contains "$report" "docs/architecture.md -> docs/arch-renamed.md" \
    "reports the old -> new rename"
  teardown
}

test_move_entry_preserves_unknown_fields() {
  echo "test: move-entry carries a field the implementation has never heard of"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  jq '.docs["docs/architecture.md"].future_field = "keep-me"' docs/.doc-index.json \
    > docs/.idx.tmp && mv docs/.idx.tmp docs/.doc-index.json
  git mv docs/architecture.md docs/arch-renamed.md
  "$DOC_TOOLS" move-entry docs/architecture.md docs/arch-renamed.md 2>/dev/null
  local json
  json=$(cat docs/.doc-index.json)
  assert_json_field "$json" '.docs["docs/arch-renamed.md"].future_field' "keep-me" \
    "unknown field survives the move (entry carried wholesale, not field-by-field)"
  teardown
}

test_move_entry_preserves_key_position() {
  echo "test: move-entry re-keys in position rather than appending"
  setup
  echo "# W" > docs/workflows.md
  echo "# G" > docs/guide.md
  git add -A && git commit -m "more docs" --quiet
  printf 'docs/architecture.md:src/:architecture\ndocs/workflows.md:src/:workflows\ndocs/guide.md:src/:guide\n' \
    | "$DOC_TOOLS" build-index
  git mv docs/workflows.md docs/flows.md
  "$DOC_TOOLS" move-entry docs/workflows.md docs/flows.md 2>/dev/null
  local second
  second=$(jq -r '.docs | keys_unsorted | .[1]' docs/.doc-index.json)
  assert_eq "docs/flows.md" "$second" "moved entry stays at index 1, not appended last"
  teardown
}

test_move_entry_status_deprecated_survives() {
  echo "test: move-entry preserves a deprecated status and superseded_by"
  setup
  echo "# W" > docs/workflows.md
  git add -A && git commit -m "add workflows" --quiet
  printf 'docs/architecture.md:src/:architecture\ndocs/workflows.md:src/:workflows\n' \
    | "$DOC_TOOLS" build-index
  "$DOC_TOOLS" deprecate-entry --superseded-by docs/workflows.md docs/architecture.md 2>/dev/null
  git mv docs/architecture.md docs/arch-old.md
  "$DOC_TOOLS" move-entry docs/architecture.md docs/arch-old.md 2>/dev/null
  local json
  json=$(cat docs/.doc-index.json)
  assert_json_field "$json" '.docs["docs/arch-old.md"].status' "deprecated" \
    "status stays deprecated (not reset to current the way add-entry would)"
  assert_json_field "$json" '.docs["docs/arch-old.md"].superseded_by' "docs/workflows.md" \
    "superseded_by preserved"
  teardown
}

test_move_entry_bumps_generated_at() {
  echo "test: move-entry bumps top-level generated_at"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  local before
  before=$(jq -r '.generated_at' docs/.doc-index.json)
  # Required, not defensive: iso_now() is 1-second resolution, so without this
  # the two stamps are identical and the assertion fails spuriously.
  sleep 1
  git mv docs/architecture.md docs/arch-renamed.md
  "$DOC_TOOLS" move-entry docs/architecture.md docs/arch-renamed.md 2>/dev/null
  local after
  after=$(jq -r '.generated_at' docs/.doc-index.json)
  if [ "$before" = "$after" ]; then
    assert_eq "bumped" "unchanged" "generated_at bumped"
  else
    assert_eq "bumped" "bumped" "generated_at bumped"
  fi
  teardown
}

test_move_entry_requires_two_args() {
  echo "test: move-entry requires exactly two arguments"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  local output exit_code
  set +e
  output=$("$DOC_TOOLS" move-entry 2>&1)
  exit_code=$?
  set -e
  assert_eq "2" "$exit_code" "exits 2 (usage error) with no arguments"
  assert_contains "$output" "requires exactly two arguments" "stderr explains the arity"
  set +e
  output=$("$DOC_TOOLS" move-entry docs/architecture.md 2>&1)
  exit_code=$?
  set -e
  assert_eq "2" "$exit_code" "exits 2 (usage error) with one argument"
  assert_contains "$output" "two arguments" "stderr explains the arity"
  teardown
}

test_move_entry_unknown_old_path_errors() {
  echo "test: move-entry errors when the old path is not in the index"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  cp docs/.doc-index.json docs/.idx.before
  # Required for the cmp below to mean anything: iso_now() is 1-second
  # resolution, so a verb that writes the index and THEN errors produces a
  # byte-identical file within the same second and cmp passes anyway.
  sleep 1
  echo "# N" > docs/nope.md
  local output exit_code
  set +e
  output=$("$DOC_TOOLS" move-entry docs/absent.md docs/nope.md 2>&1)
  exit_code=$?
  set -e
  assert_eq "1" "$exit_code" "exits 1"
  assert_contains "$output" "not found in index" "stderr explains why"
  assert_exit_code 0 "index not mutated" cmp -s docs/.idx.before docs/.doc-index.json
  teardown
}

test_move_entry_refuses_existing_target() {
  echo "test: move-entry refuses to overwrite an existing index entry"
  setup
  echo "# W" > docs/workflows.md
  git add -A && git commit -m "add workflows" --quiet
  printf 'docs/architecture.md:src/:architecture\ndocs/workflows.md:src/:workflows\n' \
    | "$DOC_TOOLS" build-index
  cp docs/.doc-index.json docs/.idx.before
  # Required for the cmp below to mean anything: iso_now() is 1-second
  # resolution, so a verb that writes the index and THEN errors produces a
  # byte-identical file within the same second and cmp passes anyway.
  sleep 1
  local output exit_code
  set +e
  output=$("$DOC_TOOLS" move-entry docs/architecture.md docs/workflows.md 2>&1)
  exit_code=$?
  set -e
  assert_eq "1" "$exit_code" "exits 1"
  assert_contains "$output" "already in the index" "stderr explains why"
  assert_exit_code 0 "index not mutated" cmp -s docs/.idx.before docs/.doc-index.json
  local json
  json=$(cat docs/.doc-index.json)
  assert_json_field "$json" '.docs | length' "2" "both entries still present"
  teardown
}

test_move_entry_requires_new_file_on_disk() {
  echo "test: move-entry refuses a new path with no file on disk"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  cp docs/.doc-index.json docs/.idx.before
  # Required for the cmp below to mean anything: iso_now() is 1-second
  # resolution, so a verb that writes the index and THEN errors produces a
  # byte-identical file within the same second and cmp passes anyway.
  sleep 1
  local output exit_code
  set +e
  output=$("$DOC_TOOLS" move-entry docs/architecture.md docs/typo-never-created.md 2>&1)
  exit_code=$?
  set -e
  assert_eq "1" "$exit_code" "exits 1"
  assert_contains "$output" "does not exist on disk" "stderr explains why"
  assert_exit_code 0 "index not mutated" cmp -s docs/.idx.before docs/.doc-index.json
  teardown
}

test_move_entry_same_path_is_noop() {
  echo "test: move-entry with identical paths is a no-op and writes nothing"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  cp docs/.doc-index.json docs/.idx.before
  sleep 1
  local output exit_code
  set +e
  output=$("$DOC_TOOLS" move-entry docs/architecture.md docs/architecture.md 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0 (idempotent re-runs must not fail)"
  assert_contains "$output" "SKIP" "reports a skip"
  # Byte-identity is the load-bearing assertion: an implementation that bumps
  # generated_at on a no-op passes the exit-code check and fails this.
  assert_exit_code 0 "index file is byte-identical (not even a generated_at bump)" \
    cmp -s docs/.idx.before docs/.doc-index.json
  teardown
}

test_move_entry_warns_when_old_file_remains() {
  echo "test: move-entry warns but proceeds when the old file is still on disk"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  cp docs/architecture.md docs/arch-copy.md
  local output exit_code
  set +e
  output=$("$DOC_TOOLS" move-entry docs/architecture.md docs/arch-copy.md 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0 — a partially-staged git mv must not be refused"
  assert_contains "$output" "still exists on disk" "warns about the orphaned file"
  local json
  json=$(cat docs/.doc-index.json)
  assert_json_field "$json" '.docs | has("docs/arch-copy.md")' "true" "the move still happened"
  teardown
}

test_move_entry_normalizes_absolute_paths() {
  echo "test: move-entry accepts absolute in-tree paths and rejects out-of-tree ones"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  git mv docs/architecture.md docs/arch-renamed.md
  local exit_code
  set +e
  "$DOC_TOOLS" move-entry "$PWD/docs/architecture.md" "$PWD/docs/arch-renamed.md" >/dev/null 2>&1
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "absolute in-tree paths accepted"
  local json
  json=$(cat docs/.doc-index.json)
  assert_json_field "$json" '.docs | has("docs/arch-renamed.md")' "true" \
    "stored under the relative key, not the absolute one"

  local outside
  outside=$(harness_mktemp_d outside)
  echo "# O" > "$outside/outside.md"
  set +e
  "$DOC_TOOLS" move-entry docs/arch-renamed.md "$outside/outside.md" >/dev/null 2>&1
  exit_code=$?
  set -e
  rm -rf "$outside"
  assert_eq "1" "$exit_code" "out-of-tree new path rejected"
  teardown
}

test_move_entry_repoints_references() {
  echo "test: move-entry repoints other entries' replaces/superseded_by"
  setup
  echo "# W" > docs/workflows.md
  git add -A && git commit -m "add workflows" --quiet
  printf 'docs/architecture.md:src/:architecture\ndocs/workflows.md:src/:workflows\n' \
    | "$DOC_TOOLS" build-index
  # superseded_by via the real verb; replaces has no writing verb, so set it directly.
  "$DOC_TOOLS" deprecate-entry --superseded-by docs/architecture.md docs/workflows.md 2>/dev/null
  jq '.docs["docs/workflows.md"].replaces = "docs/architecture.md"' docs/.doc-index.json \
    > docs/.idx.tmp && mv docs/.idx.tmp docs/.doc-index.json
  git mv docs/architecture.md docs/arch-renamed.md
  "$DOC_TOOLS" move-entry docs/architecture.md docs/arch-renamed.md 2>/dev/null
  local json
  json=$(cat docs/.doc-index.json)
  assert_json_field "$json" '.docs["docs/workflows.md"].superseded_by' "docs/arch-renamed.md" \
    "sibling superseded_by repointed (no dangling key)"
  assert_json_field "$json" '.docs["docs/workflows.md"].replaces' "docs/arch-renamed.md" \
    "sibling replaces repointed"
  teardown
}

test_move_entry_usage_lists_move_entry() {
  echo "test: usage text names move-entry"
  setup
  local output
  set +e
  output=$("$DOC_TOOLS" --help 2>&1)
  set -e
  # NOT a bare `assert_contains "$output" "move-entry"` — `remove-entry` contains
  # "move-entry" as a substring, so that assertion passes even with the
  # move-entry line deleted entirely (verified: it stayed green against a
  # usage() with the verb renamed away). Anchor on the unambiguous strings.
  assert_contains "$output" "  move-entry <old_doc_path> <new_doc_path>" \
    "usage documents the move-entry signature"
  assert_contains "$output" "Re-key an entry after a doc moves" \
    "usage heredoc describes what move-entry does"
  teardown
}

test_empty_code_refs_field_yields_empty_array() {
  # `[""]` is a phantom ref that is not a path. Behaviourally it matches [] —
  # compute_freshness() filters empty strings — but it is a state no caller
  # intended to write, and a consuming project had to normalize 1691 of them
  # away. This asserts neither verb mints new ones.
  echo "test: an omitted code_refs field yields [] not [\"\"]"
  setup
  echo "docs/architecture.md::architecture" | "$DOC_TOOLS" build-index
  local json
  json=$(cat docs/.doc-index.json)
  assert_json_field "$json" '.docs["docs/architecture.md"].code_refs | length' "0" \
    "build-index writes no phantom empty ref"
  echo "# W" > docs/workflows.md
  echo "docs/workflows.md::workflows" | "$DOC_TOOLS" add-entry 2>/dev/null
  json=$(cat docs/.doc-index.json)
  assert_json_field "$json" '.docs["docs/workflows.md"].code_refs | length' "0" \
    "add-entry writes no phantom empty ref"
  teardown
}

# --- Index persistence: one locked atomic writer (sweep 05ea982 I-2) ----------
#
# docs/.doc-index.json has exactly one write path in doc-tools.sh: mkdir lock →
# shape-validated snapshot → one jq pass → tmp file beside the target → chmod
# to the prior mode → mv. Signals terminate (INT 130, TERM 143) instead of
# cleaning up and resuming. These tests pin the failures the sweep measured:
# a resumed trap installing a truncated or empty index with rc 0, lost updates
# from parallel writers, readers catching a half-written file, a 0-byte index
# read as a valid empty one, and the index installed 0600.

# Leftover in-flight files next to the index: "" when clean.
_i2_residue() {
  (cd docs && ls -a) | grep -E '^\.doc-index\.json\.' | tr '\n' ' ' || true
}

# Permission string of a file via `ls -l` (stat -c / stat -f differ GNU vs BSD).
_i2_mode() {
  ls -l "$1" | cut -c1-10
}

# Write an N-entry index directly (no per-entry cost): keys
# docs/synthetic/dI.md, refs ["src/"], code_commit HEAD. The docs need not exist.
_i2_synthetic_index() {
  local n="$1" head
  head=$(git rev-parse HEAD)
  jq -n --argjson n "$n" --arg c "$head" '{
    schema_version: 2, generated_by: "doc-superpowers",
    generated_at: "2020-01-01T00:00:00Z", build_commit: $c,
    docs: ([range(0; $n) | {key: "docs/synthetic/d\(.).md", value: {
      content_hash: null, code_refs: ["src/"], code_commit: $c,
      doc_type: "synthetic", status: "current", replaces: null,
      superseded_by: null, last_verified: "2020-01-01T00:00:00Z"}}] | from_entries)
  }' > docs/.doc-index.json
}

# (a) The old INT/TERM trap deleted its accumulators and RESUMED: the verb ran
# on and installed a truncated index with rc 0.
test_index_term_mid_build_index_keeps_previous_index() {
  echo "test: I-2: SIGTERM mid-build-index leaves the previous index byte-identical, rc != 0"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  local before mapping i=0 rc=0
  before=$(hash_file docs/.doc-index.json)
  mapping=$(harness_mktemp i2-map)
  while [ "$i" -lt 400 ]; do
    printf 'docs/gen/d%d.md:src/:gen\n' "$i"
    i=$((i + 1))
  done > "$mapping"
  # Held mid-build by a slow git, not by machine speed: since I-1 the run is a
  # handful of batched git calls, cheap enough to finish before the kill. The
  # shim sleeps after each call whose last argument is the ref's path "src"
  # (the batch's `git rev-list -1 … -- src` for code_commit and its `git add
  # -A -- src` for code_oids), so the TERM lands while the entries' facts are
  # gathered (stdin read, nothing written) and the precondition holds on any
  # machine.
  local shim
  shim=$(_i2_slow_shim git 'src')
  PATH="$shim:$PATH" "$DOC_TOOLS" build-index --force < "$mapping" >/dev/null 2>&1 &
  harness_kill_after 1 TERM "$!" || rc=$?
  assert_eq "1" "$HARNESS_KILL_ALIVE" "precondition: build-index still running when signalled"
  assert_eq "143" "$rc" "build-index exits 143 on SIGTERM"
  assert_eq "$before" "$(hash_file docs/.doc-index.json)" "previous index byte-identical"
  assert_eq "" "$(_i2_residue)" "no tmp file or lock left beside the index"
  teardown
}

# (b) Blocked on stdin, the old trap swallowed TERM, ran to EOF and installed an
# EMPTY index. `{ sleep 3; } | timeout 1 build-index`, without `timeout`.
test_index_term_while_build_index_blocked_on_stdin() {
  echo "test: I-2: SIGTERM while build-index waits on stdin leaves the index unchanged"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  local before rc=0
  before=$(hash_file docs/.doc-index.json)
  { sleep 3; } | "$DOC_TOOLS" build-index --force >/dev/null 2>&1 &
  harness_kill_after 1 TERM "$!" || rc=$?
  assert_eq "1" "$HARNESS_KILL_ALIVE" "precondition: build-index still waiting when signalled"
  assert_true "build-index exits non-zero (rc=$rc)" test "$rc" -ne 0
  assert_eq "$before" "$(hash_file docs/.doc-index.json)" "index unchanged"
  assert_eq "" "$(_i2_residue)" "no tmp file or lock left beside the index"
  teardown
}

# check-freshness after TERM used to resume and print a summary that
# disagreed with its own .docs. It must stop and print nothing. The walk over
# these 400 (missing) docs takes milliseconds since I-4, so a slow `find` (the
# untracked-docs scan, which runs before the report is printed) holds it
# mid-run long enough to be signalled.
test_index_term_mid_check_freshness_prints_nothing() {
  echo "test: I-2: SIGTERM mid-check-freshness exits 143 with no report"
  setup
  _i2_synthetic_index 400
  local out rc=0 shim
  out=$(harness_mktemp i2-cf)
  shim=$(_i2_slow_shim find '*')
  PATH="$shim:$PATH" "$DOC_TOOLS" check-freshness > "$out" 2>/dev/null &
  harness_kill_after 0.5 TERM "$!" || rc=$?
  assert_eq "1" "$HARNESS_KILL_ALIVE" "precondition: check-freshness still running when signalled"
  assert_eq "143" "$rc" "check-freshness exits 143 on SIGTERM"
  assert_eq "0" "$(wc -c < "$out" | tr -d ' ')" "no (partial) report on stdout"
  teardown
}

# (c) Ten concurrent writers each did an unlocked read-modify-write: 9 of 10
# updates were lost, all with rc 0. The skill's `update` action dispatches
# exactly this — one agent per stale doc, each calling update-index.
test_index_parallel_update_index_loses_nothing() {
  echo "test: I-2: 10 parallel update-index runs on 10 stale docs leave 0 stale"
  setup
  local i=0 mapping="" pids="" pid fails=0
  while [ "$i" -lt 10 ]; do
    echo "# doc $i" > "docs/p$i.md"
    mapping="${mapping}docs/p$i.md:src/:guide"$'\n'
    i=$((i + 1))
  done
  git add -A && git commit -m "docs" --quiet
  printf '%s' "$mapping" | "$DOC_TOOLS" build-index
  echo "// v2" >> src/index.js
  git add -A && git commit -m "code change" --quiet
  assert_json_field "$("$DOC_TOOLS" check-freshness)" ".summary.stale" "10" "precondition: 10 stale"
  i=0
  while [ "$i" -lt 10 ]; do
    "$DOC_TOOLS" update-index "docs/p$i.md" >/dev/null 2>&1 &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" || fails=$((fails + 1))
  done
  assert_eq "0" "$fails" "every parallel update-index exits 0"
  local result
  result=$("$DOC_TOOLS" check-freshness)
  assert_json_field "$result" ".summary.stale" "0" "0 stale after the parallel run"
  assert_json_field "$result" ".summary.current" "10" "all 10 current"
  assert_eq "" "$(_i2_residue)" "no tmp file or lock left beside the index"
  teardown
}

# (d) `echo "$index" > "$index_file"` truncates before writing: a reader in that
# window sees an empty or half-written file. Writer + reader race, bounded.
test_index_reader_never_sees_a_partial_write() {
  local secs=6
  echo "test: I-2: a reader racing a writer for ${secs}s always parses the index"
  setup
  _i2_synthetic_index 3000
  echo "# race" > docs/race.md
  git add -A && git commit -m "race doc" --quiet
  echo "docs/race.md:src/:guide" | "$DOC_TOOLS" add-entry 2>/dev/null
  local wlog wcount
  wlog=$(harness_mktemp i2-wlog)
  wcount=$(harness_mktemp i2-wcount)
  (
    end=$((SECONDS + secs)); n=0
    while [ "$SECONDS" -lt "$end" ]; do
      echo "$n" >> docs/race.md
      "$DOC_TOOLS" update-index docs/race.md >/dev/null 2>&1 || echo "rc=$?" >> "$wlog"
      n=$((n + 1))
    done
    echo "$n" > "$wcount"
  ) &
  local wpid=$! reads=0 bad=0
  while kill -0 "$wpid" 2>/dev/null; do
    jq -e '(.docs | type) == "object"' docs/.doc-index.json >/dev/null 2>&1 || bad=$((bad + 1))
    reads=$((reads + 1))
  done
  wait "$wpid" || true
  assert_true "precondition: the writer made several writes ($(cat "$wcount") in ${secs}s)" \
    test "$(cat "$wcount")" -ge 2
  assert_true "precondition: the reader read repeatedly ($reads reads)" test "$reads" -ge 10
  assert_eq "0" "$bad" "0 of $reads reads saw an unparsable index"
  assert_eq "" "$(cat "$wlog")" "every write exited 0"
  teardown
}

# (e) A 0-byte index read as a valid EMPTY one: check-freshness rc 0 with every
# doc untracked, add-entry "Added 1 entry" into a 1-byte file.
test_index_zero_byte_index_rejected_by_every_verb() {
  echo "test: I-2: a 0-byte index makes every index verb exit non-zero with a clear message"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  echo "# new" > docs/new.md
  : > docs/.doc-index.json
  local verb out rc
  for verb in check-freshness status update-index add-entry remove-entry move-entry deprecate-entry; do
    rc=0
    case "$verb" in
      check-freshness) out=$("$DOC_TOOLS" check-freshness 2>&1 >/dev/null) || rc=$? ;;
      add-entry) out=$(echo "docs/new.md:src/:guide" | "$DOC_TOOLS" add-entry 2>&1 >/dev/null) || rc=$? ;;
      move-entry) out=$("$DOC_TOOLS" move-entry docs/architecture.md docs/new.md 2>&1 >/dev/null) || rc=$? ;;
      *) out=$("$DOC_TOOLS" "$verb" docs/architecture.md 2>&1 >/dev/null) || rc=$? ;;
    esac
    assert_true "$verb exits non-zero on a 0-byte index (rc=$rc)" test "$rc" -ne 0
    assert_contains "$out" "not a valid doc-index" "$verb says why"
    assert_eq "0" "$(wc -c < docs/.doc-index.json | tr -d ' ')" "$verb left the 0-byte file alone"
  done
  teardown
}

test_index_malformed_shapes_rejected() {
  echo "test: I-2: non-object / non-object .docs / concatenated / truncated indexes are rejected"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  local shape out rc
  for shape in '[]' 'null' '{}' '{"docs":[]}' '{"docs":{}}{"docs":{}}' '{"docs": {'; do
    printf '%s\n' "$shape" > docs/.doc-index.json
    rc=0
    out=$("$DOC_TOOLS" check-freshness 2>&1 >/dev/null) || rc=$?
    assert_true "check-freshness rejects $shape (rc=$rc)" test "$rc" -ne 0
    assert_contains "$out" "not a valid doc-index" "check-freshness explains $shape"
    rc=0
    out=$("$DOC_TOOLS" remove-entry docs/architecture.md 2>&1 >/dev/null) || rc=$?
    assert_true "remove-entry rejects $shape (rc=$rc)" test "$rc" -ne 0
    assert_eq "$shape" "$(cat docs/.doc-index.json)" "remove-entry left $shape untouched"
  done
  teardown
}

# build-index is the recovery path, so it must NOT refuse a broken index.
test_index_build_index_recovers_a_zero_byte_index() {
  echo "test: I-2: build-index rebuilds over a 0-byte index"
  setup
  : > docs/.doc-index.json
  local rc=0
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index 2>/dev/null || rc=$?
  assert_eq "0" "$rc" "build-index exits 0"
  assert_json_field "$(cat docs/.doc-index.json)" '.docs | has("docs/architecture.md")' "true" "rebuilt index has the entry"
  teardown
}

# (f) mktemp + mv installed the index 0600.
test_index_mode_is_0644_and_prior_mode_is_kept() {
  echo "test: I-2: index is written 0644 under umask 022, and a writer keeps the prior mode"
  setup
  (umask 022 && echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index)
  assert_eq "-rw-r--r--" "$(_i2_mode docs/.doc-index.json)" "build-index writes 0644"
  echo "more" >> docs/architecture.md
  (umask 022 && "$DOC_TOOLS" update-index docs/architecture.md 2>/dev/null)
  assert_eq "-rw-r--r--" "$(_i2_mode docs/.doc-index.json)" "update-index keeps 0644"
  chmod 664 docs/.doc-index.json
  echo "again" >> docs/architecture.md
  (umask 077 && "$DOC_TOOLS" update-index docs/architecture.md 2>/dev/null)
  assert_eq "-rw-rw-r--" "$(_i2_mode docs/.doc-index.json)" "update-index keeps a prior 0664 (umask ignored)"
  teardown
}

# A no-op run writes nothing: not even a generated_at bump.
test_index_noop_writers_leave_the_file_byte_identical() {
  echo "test: I-2: no-op remove/add/deprecate/update runs leave the index byte-identical"
  setup
  echo "# design" > docs/design.md
  printf '%s\n%s\n' "docs/architecture.md:src/:architecture" "docs/design.md:src/:design" \
    | "$DOC_TOOLS" build-index
  cp docs/.doc-index.json docs/.idx.before
  # Any generated_at / last_verified re-stamp would now differ.
  sleep 1
  "$DOC_TOOLS" remove-entry docs/nope.md >/dev/null 2>&1
  assert_exit_code 0 "remove-entry of an absent key writes nothing" cmp -s docs/.idx.before docs/.doc-index.json
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" add-entry >/dev/null 2>&1
  assert_exit_code 0 "add-entry of an existing key writes nothing" cmp -s docs/.idx.before docs/.doc-index.json
  "$DOC_TOOLS" deprecate-entry docs/nope.md >/dev/null 2>&1
  assert_exit_code 0 "deprecate-entry of an absent key writes nothing" cmp -s docs/.idx.before docs/.doc-index.json
  rm docs/design.md
  "$DOC_TOOLS" update-index docs/design.md >/dev/null 2>&1
  assert_exit_code 0 "update-index with every target skipped writes nothing" cmp -s docs/.idx.before docs/.doc-index.json
  rm -f docs/.idx.before
  teardown
}

# remove-entry / deprecate-entry listed every REQUESTED path as removed or
# deprecated, including ones they had just reported as SKIP.
test_index_writers_report_only_changed_keys() {
  echo "test: I-2: remove-entry / deprecate-entry report only the keys they changed"
  setup
  echo "# design" > docs/design.md
  printf '%s\n%s\n' "docs/architecture.md:src/:architecture" "docs/design.md:src/:design" \
    | "$DOC_TOOLS" build-index
  local out
  out=$("$DOC_TOOLS" deprecate-entry docs/design.md docs/nope.md 2>&1)
  assert_contains "$out" "Deprecated 1 entry:" "deprecate-entry counts only the changed key"
  assert_contains "$out" "  docs/design.md" "lists the deprecated key"
  assert_not_contains "$out" "  docs/nope.md" "does not list the skipped key"
  out=$("$DOC_TOOLS" remove-entry docs/architecture.md docs/nope.md 2>&1)
  assert_contains "$out" "Removed 1 entry:" "remove-entry counts only the removed key"
  assert_contains "$out" "  docs/architecture.md" "lists the removed key"
  assert_not_contains "$out" "  docs/nope.md" "does not list the skipped key"
  teardown
}

# The skill dispatches parallel writers, so a crashed one must not wedge the
# rest: a lock whose recorded owner is dead is broken.
test_index_stale_lock_from_dead_owner_is_broken() {
  echo "test: I-2: a lock left by a dead process does not wedge the next writer"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  local dead rc=0 err
  sh -c 'exit 0' &
  dead=$!
  wait "$dead" || true
  mkdir docs/.doc-index.json.lock
  echo "$dead" > docs/.doc-index.json.lock/pid
  echo "more" >> docs/architecture.md
  err=$(DOC_TOOLS_LOCK_TIMEOUT=5 "$DOC_TOOLS" update-index docs/architecture.md 2>&1 >/dev/null) || rc=$?
  assert_eq "0" "$rc" "update-index succeeds past a dead owner's lock (stderr: $err)"
  assert_contains "$err" "stale lock" "says it broke a stale lock"
  assert_json_field "$(cat docs/.doc-index.json)" '.docs["docs/architecture.md"].content_hash' \
    "sha256:$(hash_file docs/architecture.md)" "the write landed"
  assert_eq "" "$(_i2_residue)" "no lock left behind"
  teardown
}

test_index_live_lock_times_out_with_clear_error() {
  echo "test: I-2: a lock held by a live process times out with a clear error, index untouched"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  local holder rc=0 err before
  sleep 30 &
  holder=$!
  mkdir docs/.doc-index.json.lock
  echo "$holder" > docs/.doc-index.json.lock/pid
  before=$(hash_file docs/.doc-index.json)
  echo "more" >> docs/architecture.md
  err=$(DOC_TOOLS_LOCK_TIMEOUT=1 "$DOC_TOOLS" update-index docs/architecture.md 2>&1 >/dev/null) || rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  assert_true "update-index exits non-zero (rc=$rc)" test "$rc" -ne 0
  assert_contains "$err" "docs/.doc-index.json.lock" "names the lock"
  assert_contains "$err" "pid $holder" "names the owner"
  assert_eq "$before" "$(hash_file docs/.doc-index.json)" "index untouched"
  assert_true "the live owner's lock was not removed" test -d docs/.doc-index.json.lock
  rm -rf docs/.doc-index.json.lock
  teardown
}

# Poll (<= 10 s) until a path exists; the signal tests below use it to hit a
# writer inside a window a shim holds open.
_i2_wait_for() {
  local n=0
  while [ ! -e "$1" ] && [ "$n" -lt 100 ]; do
    sleep 0.1
    n=$((n + 1))
  done
  [ -e "$1" ]
}

# A shim for $1 (mkdir/git/…) that runs the real command, then sleeps 2 s when
# the LAST argument matches the glob $2 — holding a window open so a signal
# lands inside it. Prints the shim directory (prepend it to PATH).
_i2_slow_shim() {
  local cmd="$1" glob="$2" real dir
  real=$(command -v "$cmd")
  dir=$(harness_mktemp_d "slow-$cmd")
  cat > "$dir/$cmd" <<EOF
#!/bin/sh
last=""
for a; do last=\$a; done
"$real" "\$@" || exit \$?
case "\$last" in $glob) sleep 2 ;; esac
EOF
  chmod +x "$dir/$cmd"
  printf '%s' "$dir"
}

# bash runs a trap only once the foreground child exits. A TERM that lands
# while the lock's `mkdir` is running used to exit (143) right after it
# SUCCEEDED but before the shell recorded holding the lock, so cleanup left
# docs/.doc-index.json.lock behind with no pid — wedging every later writer.
test_index_term_during_lock_acquire_leaves_no_lock() {
  echo "test: I-2: SIGTERM while a writer acquires the lock leaves no lock behind"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  local shim before pid rc=0 err
  shim=$(_i2_slow_shim mkdir '*.doc-index.json.lock')
  before=$(hash_file docs/.doc-index.json)
  echo "more" >> docs/architecture.md
  PATH="$shim:$PATH" "$DOC_TOOLS" update-index docs/architecture.md >/dev/null 2>&1 &
  pid=$!
  assert_true "precondition: the writer reached the lock's mkdir" _i2_wait_for docs/.doc-index.json.lock
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" || rc=$?
  assert_eq "143" "$rc" "writer exits 143"
  assert_eq "" "$(_i2_residue)" "no lock (or tmp) left behind"
  assert_eq "$before" "$(hash_file docs/.doc-index.json)" "index unchanged"
  rc=0
  err=$(DOC_TOOLS_LOCK_TIMEOUT=2 "$DOC_TOOLS" update-index docs/architecture.md 2>&1 >/dev/null) || rc=$?
  assert_eq "0" "$rc" "the next writer is not wedged (stderr: $err)"
  teardown
}

# Same window on the stale-lock breaker's mutex (docs/.doc-index.json.lock.break).
test_index_term_while_breaking_a_stale_lock_leaves_no_mutex() {
  echo "test: I-2: SIGTERM while breaking a stale lock leaves neither the lock nor its mutex"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  local shim dead pid rc=0
  sh -c 'exit 0' &
  dead=$!
  wait "$dead" || true
  mkdir docs/.doc-index.json.lock
  echo "$dead" > docs/.doc-index.json.lock/pid
  shim=$(_i2_slow_shim mkdir '*.doc-index.json.lock.break')
  PATH="$shim:$PATH" "$DOC_TOOLS" update-index docs/architecture.md >/dev/null 2>&1 &
  pid=$!
  assert_true "precondition: the writer reached the breaker's mkdir" _i2_wait_for docs/.doc-index.json.lock.break
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" || rc=$?
  assert_eq "143" "$rc" "writer exits 143"
  assert_eq "" "$(_i2_residue)" "no lock, mutex or tmp left behind"
  teardown
}

# TERM while the writer HOLDS the lock (mid-work: its git log is held open).
# Neither build-index (locks only at the end) nor check-freshness (never
# locks) covers this.
test_index_term_while_holding_the_lock() {
  echo "test: I-2: SIGTERM while a writer holds the lock releases it and leaves the index intact"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  local shim before pid rc=0
  shim=$(_i2_slow_shim git '*')
  before=$(hash_file docs/.doc-index.json)
  echo "more" >> docs/architecture.md
  PATH="$shim:$PATH" "$DOC_TOOLS" update-index docs/architecture.md >/dev/null 2>&1 &
  pid=$!
  assert_true "precondition: the writer holds the lock" _i2_wait_for docs/.doc-index.json.lock/pid
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" || rc=$?
  assert_eq "143" "$rc" "writer exits 143"
  assert_eq "" "$(_i2_residue)" "lock released, no tmp left"
  assert_eq "$before" "$(hash_file docs/.doc-index.json)" "index unchanged"
  teardown
}

# jq >= 1.6 is required (--args / $ARGS.positional). An older jq must fail
# fast with a clear message, not deep inside a writer with a jq usage error.
test_jq_version_gate() {
  echo "test: I-2: doc-tools.sh refuses a jq older than 1.6, accepts 1.6+ and unrecognised builds"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  local real_jq shim_dir v out rc
  real_jq=$(command -v jq)
  shim_dir=$(harness_mktemp_d jq-old)
  printf '#!/bin/sh\nif [ "$1" = "--version" ]; then echo "$FAKE_JQ_VERSION"; exit 0; fi\nexec "%s" "$@"\n' \
    "$real_jq" > "$shim_dir/jq"
  chmod +x "$shim_dir/jq"
  for v in "jq-1.5" "jq-1.5-1-a5b5cbe" "jq version 1.3"; do
    rc=0
    out=$(FAKE_JQ_VERSION="$v" PATH="$shim_dir:$PATH" "$DOC_TOOLS" status docs/architecture.md 2>&1 >/dev/null) || rc=$?
    assert_true "'$v' is refused (rc=$rc)" test "$rc" -ne 0
    assert_contains "$out" "jq >= 1.6" "'$v': message names the floor"
    assert_contains "$out" "$v" "'$v': message names the version found"
  done
  for v in "jq-1.6" "jq-1.7.1-apple" "jq-1.8.1" "jq-master-1a2b3c"; do
    rc=0
    out=$(FAKE_JQ_VERSION="$v" PATH="$shim_dir:$PATH" "$DOC_TOOLS" status docs/architecture.md 2>&1 >/dev/null) || rc=$?
    assert_eq "0" "$rc" "'$v' is accepted (stderr: $out)"
  done
  teardown
}

# Each writer was a per-path loop re-parsing the whole index (O(k·N)): 5 jq
# spawns per doc for update-index. A batch run is a constant number of index
# passes, whatever k is.
test_update_index_is_one_batch_pass() {
  local k=20 budget=10
  echo "test: I-2: update-index of $k docs spawns a constant number of jq processes (<= $budget)"
  setup
  _i2_synthetic_index 1000
  mkdir -p docs/real
  local i=0 mapping="" paths=""
  while [ "$i" -lt "$k" ]; do
    echo "# real $i" > "docs/real/r$i.md"
    mapping="${mapping}docs/real/r$i.md:src/:guide"$'\n'
    paths="$paths docs/real/r$i.md"
    i=$((i + 1))
  done
  git add -A && git commit -m "real docs" --quiet
  printf '%s' "$mapping" | "$DOC_TOOLS" add-entry 2>/dev/null
  echo "// v2" >> src/index.js
  git add -A && git commit -m "code change" --quiet
  local real_jq shim_dir spawn_log rc=0
  real_jq=$(command -v jq)
  shim_dir=$(harness_mktemp_d jq-count)
  spawn_log="$shim_dir/spawns"
  : > "$spawn_log"
  printf '#!/bin/sh\necho x >> "%s"\nexec "%s" "$@"\n' "$spawn_log" "$real_jq" > "$shim_dir/jq"
  chmod +x "$shim_dir/jq"
  # shellcheck disable=SC2086  # $paths is a space-separated list of fixed names
  PATH="$shim_dir:$PATH" "$DOC_TOOLS" update-index $paths >/dev/null 2>&1 || rc=$?
  local spawns
  spawns=$(wc -l < "$spawn_log" | tr -d ' ')
  assert_eq "0" "$rc" "update-index exits 0"
  assert_true "update-index of $k docs spawned $spawns jq processes (budget $budget, independent of k)" \
    test "$spawns" -le "$budget"
  local head_src
  head_src=$(git log -1 --format=%H -- src/)
  assert_json_field "$(cat docs/.doc-index.json)" \
    "[.docs | to_entries[] | select(.key | startswith(\"docs/real/\")) | .value.code_commit == \"$head_src\"] | unique | map(tostring) | join(\",\")" \
    "true" "all $k refreshed entries carry the new code_commit"
  teardown
}

# Structural guard, cheaper and more durable than racing: the index has one
# write path, and no trap resumes after INT/TERM.
test_index_single_write_path_static() {
  echo "test: I-2: doc-tools.sh has one index write path and terminating traps"
  local src scrubbed hits
  src="$SCRIPT_DIR/doc-tools.sh"
  scrubbed=$(harness_mktemp i2-scan)
  awk '{ if ($0 ~ /^[[:space:]]*#/) print ""; else print }' "$src" > "$scrubbed"
  hits=$(grep -nE '>[[:space:]]*"?[$][{]?(index_file|INDEX_FILE)' "$scrubbed" || true)
  assert_eq "" "$hits" "no redirection straight into the index file"
  hits=$(grep -cE '(^|[^[:alnum:]_])mv[[:space:]].*"[$][{]?INDEX_FILE[}]?"' "$scrubbed" || true)
  assert_eq "1" "$hits" "exactly one mv installs the index"
  hits=$(grep -nE '(^|[[:space:]])trap[[:space:]].*RETURN' "$scrubbed" || true)
  assert_eq "" "$hits" "no RETURN trap"
  # The only non-exiting form allowed is the critical-section deferral pair,
  # which records the signal and is always followed by _signals_restore —
  # itself required to re-arm the exiting traps and exit with the recorded
  # status.
  hits=$(grep -nE '(^|[[:space:]])trap[[:space:]].*(INT|TERM)' "$scrubbed" \
    | grep -vE "trap 'exit 1(30|43)' (INT|TERM)" \
    | grep -vE "trap '_INDEX_SIG=1(30|43)' (INT|TERM)" || true)
  assert_eq "" "$hits" "every INT/TERM trap terminates (exit 130 / 143) or is the deferral pair"
  local restore
  restore=$(sed -n '/^_signals_restore() {/,/^}/p' "$scrubbed")
  assert_contains "$restore" "trap 'exit 130' INT" "_signals_restore re-arms the INT exit trap"
  assert_contains "$restore" "trap 'exit 143' TERM" "_signals_restore re-arms the TERM exit trap"
  assert_contains "$restore" 'exit "$_INDEX_SIG"' "_signals_restore exits with a deferred signal's status"
}

# --- CLI and input robustness (sweep 05ea982 I-4) ------------------------------
#
# Most callers are LLM agents, so doc-tools.sh cannot trust its command line or
# its stdin. These pin: flags anywhere in either spelling (--flag X, --flag=X);
# unknown options refused with exit 2 before anything is read or written; one
# validated mapping-line parser; one freshness path shared by check-freshness
# and status; path-segment --code-refs matching; and no git failure read as
# "no history".

# The rows (verb|handler|needs|options) of doc-tools.sh's verb table, read from
# the source. The dispatcher and usage() are both generated from this table.
_i4_table_rows() {
  grep -E '^[a-z][a-z-]*( [a-z][a-z-]*)?[|]cmd_[a-z_]+[|](repo|deps|none)[|]' \
    "$SCRIPT_DIR/doc-tools.sh" || true
}

# SHA-256 of a file's bytes, read from stdin: the harness hash_file passes the
# name as an argument, so a backslash in it prefixes the digest with "\".
_i4_sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum < "$1" | awk '{print $1}'
  else
    shasum -a 256 < "$1" | awk '{print $1}'
  fi
}

# A 40- or 64-hex object id and nothing else (a newline is not hex).
_i4_is_sha() {
  case "$1" in
    ''|*[!0-9a-f]*) return 1 ;;
  esac
  [ "${#1}" -eq 40 ] || [ "${#1}" -eq 64 ]
}

# Sorted, comma-joined .docs keys of a check-freshness report.
_i4_keys() {
  jq -r '.docs | keys | join(",")' <<<"$1"
}

test_i4_help_lists_every_dispatchable_verb() {
  echo "test: I-4: --help exits 0 (anywhere, without jq or git) and lists every dispatchable verb"
  local nogit bare out rc arg
  nogit=$(harness_mktemp_d i4-nogit)
  bare=$(harness_mktemp_d i4-path)
  ln -s "$(command -v dirname)" "$bare/dirname"
  for arg in --help -h help; do
    rc=0
    out=$(cd "$nogit" && GIT_CEILING_DIRECTORIES="$SUITE_TMP" PATH="$bare" "$DOC_TOOLS" "$arg" 2>&1) || rc=$?
    assert_eq "0" "$rc" "'$arg' exits 0 outside a git repo with neither jq nor git on PATH"
    assert_contains "$out" "Usage: doc-tools.sh" "'$arg' prints the usage"
  done

  local help rows row verb count=0 unlisted="" undispatched=""
  help=$("$DOC_TOOLS" --help 2>&1) || true
  rows=$(_i4_table_rows)
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    count=$((count + 1))
    verb="${row%%|*}"
    grep -qE "^  ${verb}( |\$)" <<<"$help" || unlisted="$unlisted '$verb'"
    rc=0
    # shellcheck disable=SC2086  # a two-word verb ("fragments merge") is two arguments
    out=$(cd "$nogit" && GIT_CEILING_DIRECTORIES="$SUITE_TMP" "$DOC_TOOLS" $verb --help 2>&1) || rc=$?
    { [ "$rc" = 0 ] && grep -qF "doc-tools.sh $verb" <<<"$out"; } || undispatched="$undispatched '$verb'(rc=$rc)"
  done <<<"$rows"
  assert_true "the verb table has a row per subcommand ($count found)" test "$count" -ge 19
  assert_eq "" "$unlisted" "--help lists every verb in the table"
  assert_eq "" "$undispatched" "every table verb dispatches: '<verb> --help' exits 0 anywhere"

  # No second dispatch list: every cmd_* handler is reached through the table.
  local handler orphans=""
  while IFS= read -r handler; do
    [ -n "$handler" ] || continue
    grep -qE "[|]${handler}[|]" <<<"$rows" || orphans="$orphans $handler"
  done < <(grep -oE '^cmd_[a-z_]+\(\)' "$SCRIPT_DIR/doc-tools.sh" | sed 's/()$//' | sort -u)
  assert_eq "" "$orphans" "every cmd_* handler has a table row (no dispatch path outside the table)"

  # Independent of the table: every verb SKILL.md's tooling table names.
  local missing_skill=""
  while IFS= read -r verb; do
    [ -n "$verb" ] || continue
    grep -qE "^  ${verb}( |\$)" <<<"$help" || missing_skill="$missing_skill $verb"
  done < <(grep -oE '^[|] `doc-tools\.sh [a-z-]+`' "$SCRIPT_DIR/../skills/doc-superpowers/SKILL.md" \
             | sed -E 's/.*doc-tools\.sh ([a-z-]+)`$/\1/' | sort -u)
  assert_eq "" "$missing_skill" "--help lists every verb in SKILL.md's tooling table"

  # bump-version's help names exactly the files it writes (VERSION_FILES).
  local bump f wrong=""
  bump=$("$DOC_TOOLS" bump-version --help 2>&1) || true
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -qF -- "$f" <<<"$bump" || wrong="$wrong $f"
  done < <(sed -n '/^VERSION_FILES=(/,/^)/p' "$SCRIPT_DIR/doc-tools.sh" | sed -n 's/^ *"\([^:]*\):.*/\1/p')
  assert_eq "" "$wrong" "bump-version --help names every VERSION_FILES entry"
  assert_contains "$bump" "never written" "bump-version --help says RELEASE-NOTES.md is never written"
}

test_i4_flags_anywhere_and_unknown_flags_exit_2() {
  echo "test: I-4: --flag X / --flag=X anywhere; unknown options exit 2 and touch nothing"
  setup
  echo "# design" > docs/design.md
  echo "# old" > docs/old.md
  git add -A && git commit -m docs --quiet
  printf '%s\n' "docs/architecture.md:src/:architecture" "docs/design.md:src/:design" \
    "docs/old.md:src/:design" | "$DOC_TOOLS" build-index
  local rc json
  # The flag AFTER the path used to deprecate the successor, rc 0.
  rc=0
  "$DOC_TOOLS" deprecate-entry docs/architecture.md --superseded-by docs/design.md >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "deprecate-entry <old> --superseded-by <new> exits 0"
  json=$(cat docs/.doc-index.json)
  assert_json_field "$json" '.docs["docs/architecture.md"].status' "deprecated" "<old> is deprecated"
  assert_json_field "$json" '.docs["docs/architecture.md"].superseded_by' "docs/design.md" "<old>.superseded_by is <new>"
  assert_json_field "$json" '.docs["docs/design.md"].status' "current" "<new>, the successor, is NOT deprecated"
  rc=0
  "$DOC_TOOLS" deprecate-entry --superseded-by=docs/design.md docs/old.md >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "--superseded-by=<path> exits 0"
  assert_json_field "$(cat docs/.doc-index.json)" '.docs["docs/old.md"].superseded_by' "docs/design.md" \
    "--superseded-by=<path> is honoured"

  local before cmd out
  before=$(hash_file docs/.doc-index.json)
  for cmd in "check-freshness --bogus" "check-freshness --code-refs" "check-freshness docs/design.md" \
      "build-index --bogus" "add-entry --bogus" "add-entry docs/design.md" \
      "update-index --bogus docs/design.md" "update-index docs/design.md -x" \
      "remove-entry --bogus docs/design.md" "deprecate-entry docs/design.md --bogus" \
      "deprecate-entry docs/design.md --superseded-by" "move-entry --bogus docs/design.md docs/x.md" \
      "status docs/design.md --bogus" "check-version --bogus" "fragments list --bogus"; do
    rc=0
    # shellcheck disable=SC2086  # $cmd is a fixed word list
    out=$(echo "docs/design.md:src/:design" | "$DOC_TOOLS" $cmd 2>&1 >/dev/null) || rc=$?
    assert_eq "2" "$rc" "'$cmd' exits 2 (stderr: $out)"
    assert_eq "$before" "$(hash_file docs/.doc-index.json)" "'$cmd' leaves the index byte-identical"
  done

  # --help on a writer prints its usage; it used to run remove-entry on "--help".
  rc=0
  out=$("$DOC_TOOLS" remove-entry --help 2>&1) || rc=$?
  assert_eq "0" "$rc" "remove-entry --help exits 0"
  assert_contains "$out" "doc-tools.sh remove-entry" "remove-entry --help prints remove-entry's usage"
  assert_eq "$before" "$(hash_file docs/.doc-index.json)" "remove-entry --help writes nothing"

  # --code-refs=<path> used to be ignored (a full report came back).
  echo "// v2" >> src/index.js
  git add -A && git commit -m code --quiet
  out=$("$DOC_TOOLS" check-freshness --code-refs=lib/) || true
  assert_json_field "$out" '.docs | length' "0" "--code-refs=<path> is honoured (no doc covers lib/)"
  teardown
}

test_i4_build_index_refuses_empty_input_and_existing_index() {
  echo "test: I-4: build-index refuses empty stdin, and a non-empty index without --force"
  setup
  local rc before
  rc=0
  "$DOC_TOOLS" build-index </dev/null >/dev/null 2>&1 || rc=$?
  assert_true "build-index </dev/null with no index exits non-zero (rc=$rc)" test "$rc" -ne 0
  assert_file_not_exists docs/.doc-index.json "no empty index is created"
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  jq '.docs["docs/architecture.md"].status = "deprecated"' docs/.doc-index.json > docs/.i4.tmp
  mv docs/.i4.tmp docs/.doc-index.json
  before=$(hash_file docs/.doc-index.json)
  rc=0
  "$DOC_TOOLS" build-index </dev/null >/dev/null 2>&1 || rc=$?
  assert_true "build-index </dev/null over an existing index exits non-zero (rc=$rc)" test "$rc" -ne 0
  assert_eq "$before" "$(hash_file docs/.doc-index.json)" "…and leaves it byte-identical"
  echo "# w" > docs/workflows.md
  local err
  rc=0
  err=$(echo "docs/workflows.md:src/:workflows" | "$DOC_TOOLS" build-index 2>&1 >/dev/null) || rc=$?
  assert_true "build-index over a non-empty index without --force exits non-zero (rc=$rc)" test "$rc" -ne 0
  assert_contains "$err" "--force" "…and says --force is how to rebuild"
  assert_eq "$before" "$(hash_file docs/.doc-index.json)" "…and leaves it byte-identical (the deprecation survives)"
  rc=0
  "$DOC_TOOLS" build-index --help </dev/null >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "build-index --help </dev/null exits 0"
  assert_eq "$before" "$(hash_file docs/.doc-index.json)" "…and writes nothing"
  rc=0
  echo "docs/workflows.md:src/:workflows" | "$DOC_TOOLS" build-index --force >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "build-index --force rebuilds a non-empty index"
  assert_json_field "$(cat docs/.doc-index.json)" '.docs | keys | join(",")' "docs/workflows.md" "--force replaced the index"
  rc=0
  "$DOC_TOOLS" build-index --force </dev/null >/dev/null 2>&1 || rc=$?
  assert_true "build-index --force with empty stdin still exits non-zero (rc=$rc)" test "$rc" -ne 0
  assert_json_field "$(cat docs/.doc-index.json)" '.docs | length' "1" "…and does not empty the index"
  teardown
}

test_i4_mapping_line_parser() {
  echo "test: I-4: mapping lines — bare path, CRLF, 'a, b', ':' in a path, a typo'd ref"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  local d
  for d in bare crlf spaced typo; do echo "# $d" > "docs/$d.md"; done
  echo "# ab" > "docs/a:b.md"
  git add -A && git commit -m docs --quiet
  local out rc=0 json
  out=$(printf '%s\n' "docs/bare.md" "docs/crlf.md:src/:guide"$'\r' "docs/spaced.md:src/index.js, src/ :guide" \
          "docs/a:b.md:src/:guide" "docs/typo.md:srcc/:guide" | "$DOC_TOOLS" add-entry 2>&1) || rc=$?
  json=$(cat docs/.doc-index.json)
  assert_true "add-entry exits non-zero when a line is rejected (rc=$rc)" test "$rc" -ne 0
  assert_json_field "$json" '.docs | has("docs/bare.md")' "false" \
    "a bare path is rejected, not split into refs + doc_type"
  assert_contains "$out" "docs/bare.md" "the rejection names the bare-path line"
  assert_json_field "$json" '.docs["docs/crlf.md"].doc_type' "guide" "CRLF: doc_type has no trailing CR"
  assert_json_field "$json" '.docs["docs/spaced.md"].code_refs | join("|")' "src/index.js|src/" \
    "'a, b' refs are trimmed"
  assert_json_field "$json" '.docs["docs/spaced.md"].code_commit | type' "string" \
    "…and the same trimmed refs reach git (code_commit is set)"
  assert_json_field "$json" '[.docs | keys[] | select(startswith("docs/a"))] | join(",")' "docs/architecture.md" \
    "a path containing ':' is rejected, never re-keyed as docs/a"
  assert_contains "$out" "srcc/" "a ref that matches no tracked path is warned about"
  assert_json_field "$json" '.docs["docs/typo.md"].code_refs | join(",")' "srcc/" "…but the entry is still added"
  # The short forms: one ':' in the path and no doc_type, or no doc_type field
  # at all. Both used to key the entry docs/a with ref b.md, rc 0.
  local form
  for form in "docs/a:b.md" "docs/a:b.md:src/"; do
    rc=0
    out=$(printf '%s\n' "$form" | "$DOC_TOOLS" add-entry 2>&1) || rc=$?
    json=$(cat docs/.doc-index.json)
    assert_true "add-entry '$form' exits non-zero (rc=$rc)" test "$rc" -ne 0
    assert_json_field "$json" '.docs | has("docs/a")' "false" "'$form' is not keyed as docs/a"
    assert_contains "$out" "ambiguous" "'$form' is rejected as ambiguous"
  done
  # build-index replaces the whole index, so one bad line aborts all of it.
  rc=0
  printf '%s\n' "docs/crlf.md:src/:guide" "docs/bare.md" | "$DOC_TOOLS" build-index --force >/dev/null 2>&1 || rc=$?
  assert_true "build-index --force refuses input with a bare-path line (rc=$rc)" test "$rc" -ne 0
  assert_json_field "$(cat docs/.doc-index.json)" '.docs | has("docs/spaced.md")' "true" "…and leaves the index as it was"
  rc=0
  printf '%s\n' "docs/crlf.md:src/:guide" "docs/a:b.md:src/" | "$DOC_TOOLS" build-index --force >/dev/null 2>&1 || rc=$?
  assert_true "build-index --force refuses an ambiguous ':' path line (rc=$rc)" test "$rc" -ne 0
  assert_json_field "$(cat docs/.doc-index.json)" '.docs | has("docs/spaced.md")' "true" "…and leaves the index as it was"
  teardown
}

test_i4_check_freshness_and_status_agree() {
  echo "test: I-4: check-freshness and status agree (null code_commit/content_hash, empty doc_type, ',,' and ',' refs, globs, TAB key)"
  setup
  printf 'c\n' > src/c.txt
  printf 'd\n' > src/d.txt
  printf 'ab\n' > 'src/a,b.txt'
  printf 'x\n' > src/x.js
  local tabkey="docs/tab"$'\t'"key.md" k
  for k in null-commit null-hash empty-type phantom glob comma dep; do echo "# $k" > "docs/$k.md"; done
  echo "# tab" > "$tabkey"
  git add -A && git commit -m "docs + code" --quiet
  local old head_src
  old=$(git rev-parse HEAD)
  printf 'c2\n' > src/c.txt
  printf 'ab2\n' > 'src/a,b.txt'
  git rm -q src/x.js
  echo "// v2" >> src/index.js
  git add -A && git commit -m "code change" --quiet
  head_src=$(git rev-list -1 HEAD -- src/)
  # shellcheck disable=SC2016  # jq program
  jq -n --arg old "$old" --arg head "$head_src" --arg tab "$tabkey" \
    --arg h_nc "sha256:$(_i4_sha docs/null-commit.md)" --arg h_et "sha256:$(_i4_sha docs/empty-type.md)" \
    --arg h_ph "sha256:$(_i4_sha docs/phantom.md)" --arg h_gl "sha256:$(_i4_sha docs/glob.md)" \
    --arg h_co "sha256:$(_i4_sha docs/comma.md)" --arg h_tb "sha256:$(_i4_sha "$tabkey")" \
    'def e($h; $refs; $c; $t): {content_hash: $h, code_refs: $refs, code_commit: $c, doc_type: $t,
       status: "current", replaces: null, superseded_by: null, last_verified: "2026-01-01T00:00:00Z"};
    {schema_version: 2, generated_by: "doc-superpowers", generated_at: "2026-01-01T00:00:00Z", build_commit: $old,
     docs: {
       "docs/null-commit.md": e($h_nc; ["src/"]; null; "guide"),
       "docs/null-hash.md": e(null; ["src/"]; $head; "guide"),
       "docs/empty-type.md": (e($h_et; ["src/"]; $old; "") | del(.last_verified)),
       "docs/phantom.md": e($h_ph; ["src/c.txt", "", "src/d.txt"]; $old; "guide"),
       "docs/glob.md": e($h_gl; ["src/*.js"]; $old; "guide"),
       "docs/comma.md": e($h_co; ["src/a,b.txt"]; $old; "guide"),
       "docs/dep.md": (e(null; ["src/"]; $old; "guide") | .status = "deprecated"),
       "docs/gone.md": e(null; ["src/"]; $old; "guide"),
       ($tab): e($h_tb; ["src/"]; $head; "guide")
     }}' > docs/.doc-index.json
  local cf rc=0
  cf=$("$DOC_TOOLS" check-freshness) || rc=$?
  assert_eq "0" "$rc" "check-freshness exits 0"
  local key st a b mismatches=""
  while IFS= read -r key; do
    st=$("$DOC_TOOLS" status "$key" 2>&1) || true
    a=$(jq -S -c 'del(.path)' <<<"$st" 2>/dev/null || printf 'invalid: %s' "$st")
    b=$(jq -S -c --arg k "$key" '.docs[$k]' <<<"$cf")
    [ "$a" = "$b" ] || mismatches="${mismatches}  ${key}: status=${a} check-freshness=${b}"$'\n'
  done < <(jq -r '.docs | keys[]' docs/.doc-index.json)
  assert_eq "" "$mismatches" "status and check-freshness report the same object for every entry"
  assert_json_field "$cf" '.docs["docs/null-commit.md"].status' "stale" "a null code_commit with code present is stale"
  assert_json_field "$cf" '.docs["docs/null-hash.md"].status' "current" "a null content_hash does not shift the columns"
  assert_json_field "$cf" '.docs["docs/null-hash.md"].doc_modified' "true" "…and reads as doc_modified"
  assert_json_field "$cf" '.docs["docs/empty-type.md"].status' "stale" "an empty doc_type / no last_verified: stale code still stale"
  assert_json_field "$cf" '.docs["docs/phantom.md"].status' "stale" "a phantom '' ref (',,') does not hide the change"
  assert_json_field "$cf" '.docs["docs/phantom.md"].code_refs_changed | join(",")' "src/c.txt" "…and only the changed ref is listed"
  assert_json_field "$cf" '.docs["docs/comma.md"].status' "stale" "a ref containing ',' is one ref"
  assert_json_field "$cf" '.docs["docs/glob.md"].code_refs_changed | join(",")' "src/*.js" \
    "a glob ref reaches git verbatim, never shell-expanded"
  assert_json_field "$cf" '.docs["docs/tab\tkey.md"].status' "current" "a TAB in a key is not @tsv-escaped into a missing doc"
  assert_json_field "$cf" '.docs["docs/dep.md"].status' "deprecated" "deprecated is preserved"
  assert_json_field "$cf" '.docs["docs/gone.md"].status' "missing" "a doc not on disk is missing"
  assert_json_field "$cf" '.summary | "\(.current) \(.stale) \(.missing) \(.deprecated)"' "2 5 1 1" \
    "summary counts match the entries"
  teardown
}

test_i4_code_refs_match_by_path_segment() {
  echo "test: I-4: --code-refs matches by path segment; --code-refs-from <file|-> takes the same list"
  setup
  mkdir -p src/m1 src/m10
  echo a > src/m1/a.js
  echo x > src/m10/x.js
  local d
  for d in m1 m10 src; do echo "# $d" > "docs/$d.md"; done
  git add -A && git commit -m tree --quiet
  printf '%s\n' "docs/m1.md:src/m1:guide" "docs/m10.md:src/m10/x.js:guide" "docs/src.md:src/:guide" \
    | "$DOC_TOOLS" build-index 2>/dev/null
  local out list
  out=$("$DOC_TOOLS" check-freshness --code-refs src/m1) || true
  assert_eq "docs/m1.md,docs/src.md" "$(_i4_keys "$out")" "src/m1 matches src/m1 and its parent src/, never src/m10/x.js"
  out=$("$DOC_TOOLS" check-freshness --code-refs src/m1/a.js) || true
  assert_eq "docs/m1.md,docs/src.md" "$(_i4_keys "$out")" "a file under a ref matches that ref"
  out=$("$DOC_TOOLS" check-freshness --code-refs=src/m10/) || true
  assert_eq "docs/m10.md,docs/src.md" "$(_i4_keys "$out")" "--code-refs=<dir>/ matches the refs below it"
  out=$("$DOC_TOOLS" check-freshness --code-refs src/m1/a.js src/m10/x.js) || true
  assert_eq "docs/m1.md,docs/m10.md,docs/src.md" "$(_i4_keys "$out")" "--code-refs takes several paths (the hooks' form)"
  out=$("$DOC_TOOLS" check-freshness --code-refs '') || true
  assert_eq "" "$(_i4_keys "$out")" "an empty --code-refs value matches nothing (it used to match everything)"
  list=$(harness_mktemp i4-list)
  printf 'src/m1/a.js\r\n\nsrc/m10/x.js\r\n' > "$list"
  out=$("$DOC_TOOLS" check-freshness --code-refs-from "$list") || true
  assert_eq "docs/m1.md,docs/m10.md,docs/src.md" "$(_i4_keys "$out")" "--code-refs-from <file> (CRLF, blank line) scopes like --code-refs"
  out=$(printf 'src/m10/x.js\n' | "$DOC_TOOLS" check-freshness --code-refs-from -) || true
  assert_eq "docs/m10.md,docs/src.md" "$(_i4_keys "$out")" "--code-refs-from - reads the list from stdin"
  out=$(: | "$DOC_TOOLS" check-freshness --code-refs-from -) || true
  assert_eq "" "$(_i4_keys "$out")" "an empty list scopes to no docs"
  teardown
}

test_i4_doc_paths_normalized_and_targets_deduped() {
  echo "test: I-4: docs//x.md is docs/x.md; a repeated target counts once; a '-' path is refused"
  setup
  echo "# x" > docs/x.md
  echo "# y" > docs/y.md
  git add -A && git commit -m docs --quiet
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  printf '%s\n' "docs//x.md:src/:guide" "docs/y.md:src/:guide" | "$DOC_TOOLS" add-entry 2>/dev/null
  local json out rc
  json=$(cat docs/.doc-index.json)
  assert_json_field "$json" '.docs | has("docs/x.md")' "true" "docs//x.md is stored as docs/x.md"
  assert_json_field "$json" '.docs | has("docs//x.md")' "false" "…not as a separate docs//x.md key"
  echo "more" >> docs/x.md
  out=$("$DOC_TOOLS" update-index docs/x.md docs//x.md 2>&1) || true
  assert_contains "$out" "Refreshed 1 entry:" "update-index docs/x.md docs//x.md refreshes one entry"
  out=$("$DOC_TOOLS" deprecate-entry docs/y.md docs/y.md 2>&1) || true
  assert_contains "$out" "Deprecated 1 entry:" "deprecate-entry counts a repeated target once"
  assert_eq "1" "$(grep -c '^  docs/y.md$' <<<"$out")" "…and lists it once"
  out=$("$DOC_TOOLS" remove-entry docs/x.md docs//x.md docs/x.md 2>&1) || true
  assert_contains "$out" "Removed 1 entry:" "remove-entry counts a repeated target once"
  assert_eq "1" "$(grep -c '^  docs/x.md$' <<<"$out")" "…and lists it once"
  assert_not_contains "$out" "SKIP" "…and does not report the repeat as not found"
  rc=0
  out=$("$DOC_TOOLS" update-index -- -x.md 2>&1) || rc=$?
  assert_true "a doc path starting with '-' is refused (rc=$rc)" test "$rc" -ne 0
  assert_contains "$out" "'-x.md'" "…naming the path"
  teardown
}

test_i4_outside_a_git_repo() {
  echo "test: I-4: outside a git repo every index/git verb exits non-zero; help still exits 0"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  local nogit cmd rc out before
  nogit=$(harness_mktemp_d i4-nogit)
  mkdir -p "$nogit/docs"
  cp docs/.doc-index.json docs/architecture.md "$nogit/docs/"
  cd "$nogit"
  before=$(hash_file docs/.doc-index.json)
  for cmd in "check-freshness" "status docs/architecture.md" "update-index docs/architecture.md" \
      "remove-entry docs/architecture.md" "deprecate-entry docs/architecture.md" \
      "move-entry docs/architecture.md docs/b.md" "add-entry" "build-index --force" \
      "fragments merge HEAD~1 HEAD"; do
    rc=0
    # shellcheck disable=SC2086  # $cmd is a fixed word list
    out=$(echo "docs/architecture.md:src/:architecture" \
            | GIT_CEILING_DIRECTORIES="$SUITE_TMP" "$DOC_TOOLS" $cmd 2>&1 >/dev/null) || rc=$?
    assert_true "'$cmd' exits non-zero outside a git repo (rc=$rc)" test "$rc" -ne 0
    assert_contains "$out" "git repository" "'$cmd' says it needs a git repository"
  done
  assert_eq "$before" "$(hash_file docs/.doc-index.json)" "no verb touched the index"
  for cmd in "--help" "help" "status --help" "help status"; do
    rc=0
    # shellcheck disable=SC2086
    GIT_CEILING_DIRECTORIES="$SUITE_TMP" "$DOC_TOOLS" $cmd >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "'$cmd' exits 0 outside a git repo"
  done
  cd "$TEST_DIR"
  teardown
}

test_i4_show_signature_does_not_leak_into_code_commit() {
  echo "test: I-4: with log.showSignature=true on a signed history, code_commit is a bare SHA"
  setup
  if ! command -v ssh-keygen >/dev/null 2>&1; then
    record_skip "I-4 log.showSignature: ssh-keygen not available to sign a fixture commit"
    teardown
    return 0
  fi
  ssh-keygen -q -t ed25519 -N '' -f "$HOME/sign" -C test
  git config gpg.format ssh
  git config user.signingkey "$HOME/sign.pub"
  echo "// signed" >> src/index.js
  git add -A && git commit -S -m signed --quiet
  git config log.showSignature true
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index 2>/dev/null
  local cc rc
  cc=$(jq -r '.docs["docs/architecture.md"].code_commit' docs/.doc-index.json)
  assert_true "build-index writes a bare SHA (got: $cc)" _i4_is_sha "$cc"
  echo "# w" > docs/workflows.md
  echo "docs/workflows.md:src/:workflows" | "$DOC_TOOLS" add-entry 2>/dev/null
  cc=$(jq -r '.docs["docs/workflows.md"].code_commit' docs/.doc-index.json)
  assert_true "add-entry writes a bare SHA (got: $cc)" _i4_is_sha "$cc"
  echo "more" >> docs/architecture.md
  rc=0
  "$DOC_TOOLS" update-index docs/architecture.md >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "update-index exits 0"
  cc=$(jq -r '.docs["docs/architecture.md"].code_commit' docs/.doc-index.json)
  assert_true "update-index writes a bare SHA (got: $cc)" _i4_is_sha "$cc"
  assert_json_field "$("$DOC_TOOLS" check-freshness)" '.summary.stale' "0" "…and nothing reads as stale"
  teardown
}

test_i4_unborn_head() {
  echo "test: I-4: on an unborn HEAD build_commit and repo_head are null (not \"HEAD\\nunknown\")"
  setup
  local unborn rc out
  unborn=$(harness_mktemp_d i4-unborn)
  cd "$unborn"
  git init -q -b main 2>/dev/null || { git init -q && git symbolic-ref HEAD refs/heads/main; }
  mkdir docs
  echo "# a" > docs/a.md
  rc=0
  echo "docs/a.md:src/:guide" | "$DOC_TOOLS" build-index 2>/dev/null || rc=$?
  assert_eq "0" "$rc" "build-index exits 0 on an unborn HEAD"
  assert_json_field "$(cat docs/.doc-index.json)" '.build_commit' "null" "build_commit is null"
  assert_json_field "$(cat docs/.doc-index.json)" '.docs["docs/a.md"].code_commit' "null" "code_commit is null"
  rc=0
  out=$("$DOC_TOOLS" check-freshness 2>/dev/null) || rc=$?
  assert_eq "0" "$rc" "check-freshness exits 0 on an unborn HEAD"
  assert_json_field "$out" '.repo_head' "null" "repo_head is null"
  assert_json_field "$out" '.docs["docs/a.md"].status' "current" "the doc reads as current"
  cd "$TEST_DIR"
  teardown
}

test_i4_update_index_unknown_key_applies_the_rest() {
  echo "test: I-4: update-index with an unknown key refreshes the known ones, then exits 1"
  setup
  echo "# w" > docs/workflows.md
  git add -A && git commit -m w --quiet
  printf '%s\n' "docs/architecture.md:src/:architecture" "docs/workflows.md:src/:workflows" \
    | "$DOC_TOOLS" build-index
  echo "// v2" >> src/index.js
  git add -A && git commit -m code --quiet
  local out rc=0
  out=$("$DOC_TOOLS" update-index docs/architecture.md docs/nope.md docs/workflows.md 2>&1) || rc=$?
  assert_eq "1" "$rc" "exits 1 because one key is not indexed"
  assert_contains "$out" "docs/nope.md" "names the unknown key"
  assert_contains "$out" "add-entry" "points at add-entry"
  assert_contains "$out" "Refreshed 2 entries:" "the indexed keys are still refreshed"
  assert_json_field "$("$DOC_TOOLS" check-freshness)" '.summary.stale' "0" "…so neither is stale"
  teardown
}

test_i4_hostile_names_and_stored_values() {
  echo "test: I-4: '\\' and '-' doc names hash their own bytes; a stored code_commit never reaches git as an option"
  setup
  printf '# back\n' > 'docs/back\slash.md'
  printf '# dash\n' > ./-
  git add -A && git commit -m names --quiet
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  printf '%s\n' 'docs/back\slash.md:src/:guide' | "$DOC_TOOLS" add-entry 2>/dev/null
  assert_json_field "$(cat docs/.doc-index.json)" '.docs["docs/back\\slash.md"].content_hash' \
    "sha256:$(_i4_sha 'docs/back\slash.md')" "a '\\' in the name: content_hash is the file's own hash"
  # An index key "-" (hand-edited: writers refuse it) must hash the FILE "-",
  # not drain stdin — in the old loop, stdin was the record stream itself.
  local head
  head=$(git rev-list -1 HEAD -- src/)
  # shellcheck disable=SC2016  # jq program
  jq --arg h "sha256:$(_i4_sha ./-)" --arg c "$head" \
    '.docs = ({"-": {content_hash: $h, code_refs: ["src/"], code_commit: $c, doc_type: "guide",
        status: "current", replaces: null, superseded_by: null, last_verified: "2026-01-01T00:00:00Z"}} + .docs)' \
    docs/.doc-index.json > docs/.i4.tmp
  mv docs/.i4.tmp docs/.doc-index.json
  local out rc=0
  out=$(printf 'stdin bytes\n' | "$DOC_TOOLS" check-freshness) || rc=$?
  assert_eq "0" "$rc" "check-freshness exits 0 with a '-' key"
  assert_json_field "$out" '.docs | length' "3" "every entry is reported (the '-' key did not drain the record stream)"
  assert_json_field "$out" '.docs["-"].doc_modified' "false" "the '-' key hashes the file named '-', not stdin"
  # A code_commit shaped like an option reached `git rev-list` as one (the old
  # script wrote a file "pwned..HEAD"). The "-" key goes first: in the old loop
  # it drained the records before this entry was ever evaluated. Checked on a
  # legacy entry (no code_oids: the commit logic, where it is the baseline)
  # and on a stale v3 entry (where it only feeds commits_behind).
  jq 'del(.docs["-"]) | .docs["docs/architecture.md"] |= (.code_commit = "--output=pwned" | del(.code_oids))' \
    docs/.doc-index.json > docs/.i4.tmp
  mv docs/.i4.tmp docs/.doc-index.json
  rc=0
  out=$("$DOC_TOOLS" check-freshness) || rc=$?
  assert_eq "0" "$rc" "check-freshness exits 0 with an option-shaped code_commit"
  assert_eq "" "$(ls -a | grep '^pwned' || true)" "a code_commit of '--output=pwned' created no file"
  assert_json_field "$out" '.docs["docs/architecture.md"].status' "stale" \
    "legacy entry: a stored code_commit that is not an object id reads as no baseline (stale)"
  echo "// v2" >> src/index.js
  git add -A && git commit -m v2 --quiet
  jq '.docs["docs/back\\slash.md"].code_commit = "--output=pwned"' docs/.doc-index.json > docs/.i4.tmp
  mv docs/.i4.tmp docs/.doc-index.json
  rc=0
  out=$("$DOC_TOOLS" check-freshness) || rc=$?
  assert_eq "0" "$rc" "check-freshness exits 0 with an option-shaped code_commit on a stale v3 entry"
  assert_eq "" "$(ls -a | grep '^pwned' || true)" "…which created no file either"
  assert_json_field "$out" '.docs["docs/back\\slash.md"] | "\(.status) \(.commits_behind)"' "stale null" \
    "v3 entry: stale by content; commits_behind is null (no usable baseline commit)"
  teardown
}

# The option specs in the verb table contain "*" (code-refs-from=*). Split
# unquoted, a spec underwent pathname expansion: a file named
# "code-refs-from=zz" in the working directory made --code-refs-from unknown.
test_i4_option_spec_is_not_glob_expanded() {
  echo "test: I-4: a file named like an option spec does not change which options a verb takes"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  : > "code-refs-from=zz"
  local out rc=0
  out=$(printf 'src/index.js\n' | "$DOC_TOOLS" check-freshness --code-refs-from - 2>&1) || rc=$?
  assert_eq "0" "$rc" "--code-refs-from - still works with 'code-refs-from=zz' in the cwd (output: ${out:0:200})"
  assert_json_field "$out" '.docs | keys | join(",")' "docs/architecture.md" "…and still scopes the report"
  rm -f "code-refs-from=zz"
  teardown
}

# Every wrong-number-of-arguments error is a usage error: exit 2, index
# untouched (status used to exit 1 for two paths, bump-version 2 for two
# versions; missing paths exited 1 everywhere).
test_i4_arity_errors_exit_2() {
  echo "test: I-4: every wrong-number-of-arguments error exits 2 and writes nothing"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  local before cmd rc out
  before=$(hash_file docs/.doc-index.json)
  for cmd in "status" "status docs/architecture.md docs/x.md" "update-index" "remove-entry" \
      "deprecate-entry" "deprecate-entry --superseded-by docs/architecture.md" "move-entry" \
      "move-entry docs/architecture.md" "move-entry docs/a.md docs/b.md docs/c.md" \
      "bump-version" "bump-version 1.0.0 2.0.0" "fragments validate" "fragments validate a.md b.md" \
      "fragments merge HEAD" "fragments merge HEAD~1 HEAD extra" "implementation-status" \
      "set-implementation" "set-implementation docs/architecture.md" \
      "set-implementation docs/architecture.md docs/x.md --ref PR:1 --status complete" \
      "check-version extra" "fragments list extra" "tools status extra" "help status extra"; do
    rc=0
    # shellcheck disable=SC2086  # $cmd is a fixed word list
    out=$("$DOC_TOOLS" $cmd </dev/null 2>&1 >/dev/null) || rc=$?
    assert_eq "2" "$rc" "'$cmd' exits 2 (stderr: ${out:0:160})"
  done
  assert_eq "$before" "$(hash_file docs/.doc-index.json)" "no arity error touched the index"
  teardown
}

# --- Content identity: code_oids and --tree (sweep 05ea982 I-1) ----------------
#
# A doc is stale when the CONTENT of one of its code refs differs from what was
# verified — not when the commit that last touched the refs has a different id.
# Writers store each ref's blob/tree object id (code_oids), captured from the
# working tree the verifier read; readers look the same refs up in HEAD, or in
# any tree given with --tree (pre-commit: the staged tree from git write-tree),
# in one `git cat-file --batch-check` pass. The fixtures below are the history
# shapes that mint new commit ids for identical bytes, plus a shallow clone,
# verifying in the same commit as the code, and a staged change.

# "status|commits_behind|code_refs_changed" of doc $2 in a check-freshness
# report (or of a status object, which has no .docs).
_i1_verdict() {
  jq -r --arg k "$2" '(if has("docs") then .docs[$k] else . end)
    | "\(.status)|\(.commits_behind)|\(.code_refs_changed // [] | join(","))"' <<<"$1"
}

_i1_commit() {
  git add -A && git commit -m "$1" --quiet
}

# The last commit touching $@ (what the pre-v3 model compared code_commit with).
_i1_last() {
  git rev-list -1 HEAD -- "$@"
}

# Counting shims for each named command: every spawn appends the command's name
# to <dir>/spawns. Prints <dir>; prepend it to PATH.
_i1_count_shims() {
  local dir cmd real
  dir=$(harness_mktemp_d spawn-count)
  : > "$dir/spawns"
  for cmd in "$@"; do
    real=$(command -v "$cmd")
    printf '#!/bin/sh\necho %s >> "%s"\nexec "%s" "$@"\n' "$cmd" "$dir/spawns" "$real" > "$dir/$cmd"
    chmod +x "$dir/$cmd"
  done
  printf '%s' "$dir"
}

test_i1_writers_record_code_oids() {
  echo "test: I-1: writers record code_oids from the working tree (schema_version 3), never touching git's index"
  setup
  printf 'a\n' > src/a.js
  printf '*.log\n' > .gitignore
  printf 'log\n' > src/x.log
  mkdir -p src/empty
  _i1_commit files
  # Uncommitted: the verifier reads the working tree, so THIS is what is verified.
  printf 'a-worktree\n' > src/a.js
  local staged_before err json exp_src t
  staged_before=$(git diff --cached --name-only)
  err=$(echo "docs/architecture.md:src/,src/a.js,src/x.log,src/empty,src/nope.js:architecture" \
          | "$DOC_TOOLS" build-index 2>&1) || true
  json=$(cat docs/.doc-index.json)
  t=$(harness_mktemp i1-idx)
  rm -f "$t"
  cp .git/index "$t"
  GIT_INDEX_FILE="$t" git add -A src
  exp_src=$(git rev-parse "$(GIT_INDEX_FILE="$t" git write-tree):src")
  assert_json_field "$json" '.schema_version' "3" "build-index writes schema_version 3"
  assert_json_field "$json" '.docs["docs/architecture.md"].code_oids["src/a.js"]' "$(git hash-object src/a.js)" \
    "a file ref's OID is its working-tree blob, not HEAD's"
  assert_json_field "$json" '.docs["docs/architecture.md"].code_oids["src/"]' "$exp_src" \
    "a directory ref's OID is the tree of its working-tree content (key as stored, 'src/')"
  assert_json_field "$json" '.docs["docs/architecture.md"].code_oids["src/x.log"]' "missing" "an ignored file is recorded as missing"
  assert_json_field "$json" '.docs["docs/architecture.md"].code_oids["src/empty"]' "missing" "an empty directory is recorded as missing"
  assert_json_field "$json" '.docs["docs/architecture.md"].code_oids["src/nope.js"]' "missing" "an absent path is recorded as missing"
  assert_json_field "$json" '.docs["docs/architecture.md"].code_oids | keys | length' "5" "one code_oids key per ref"
  assert_contains "$err" "src/nope.js" "the unmatched ref is still warned about"
  assert_eq "$staged_before" "$(git diff --cached --name-only)" "build-index staged nothing in git's own index"
  echo "# w" > docs/workflows.md
  echo "docs/workflows.md:src/a.js:workflows" | "$DOC_TOOLS" add-entry 2>/dev/null
  assert_json_field "$(cat docs/.doc-index.json)" '.docs["docs/workflows.md"].code_oids["src/a.js"]' \
    "$(git hash-object src/a.js)" "add-entry records code_oids"
  rm src/a.js
  "$DOC_TOOLS" update-index docs/architecture.md >/dev/null 2>&1
  assert_json_field "$(cat docs/.doc-index.json)" '.docs["docs/architecture.md"].code_oids["src/a.js"]' "missing" \
    "update-index re-captures: a file deleted from the working tree is missing"
  assert_eq "$staged_before" "$(git diff --cached --name-only)" "update-index staged nothing in git's own index"
  teardown
}

test_i1_squash_merge_is_current() {
  echo "test: I-1: squash-merge of verified code is current (also in a fresh clone after the branch is deleted)"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  _i1_commit index
  git checkout -q -b feat
  echo "// feat" >> src/index.js
  _i1_commit "feat code"
  echo "more" >> docs/architecture.md
  "$DOC_TOOLS" update-index docs/architecture.md >/dev/null 2>&1
  _i1_commit verify
  git checkout -q main
  git merge -q --squash feat
  git commit -m squash --quiet
  assert_true "precondition: the stored code_commit is not HEAD's last src/ commit (the old model's stale)" \
    test "$(jq -r '.docs["docs/architecture.md"].code_commit' docs/.doc-index.json)" != "$(_i1_last src/)"
  assert_eq "current|0|" "$(_i1_verdict "$("$DOC_TOOLS" check-freshness)" docs/architecture.md)" "squash-merged: current"
  git branch -q -D feat
  local clone
  clone=$(harness_mktemp_d i1-clone)
  git clone -q "file://$TEST_DIR" "$clone/r"
  cd "$clone/r"
  assert_eq "current|0|" "$(_i1_verdict "$("$DOC_TOOLS" check-freshness)" docs/architecture.md)" \
    "fresh clone, feat branch gone (its commits absent): still current"
  echo "// later" >> src/index.js
  _i1_commit later
  assert_eq "stale|null|src/" "$(_i1_verdict "$("$DOC_TOOLS" check-freshness)" docs/architecture.md)" \
    "a later change is stale; commits_behind is null (the verified commit is not in this clone), never 0"
  cd "$TEST_DIR"
  teardown
}

test_i1_rebase_merge_is_current() {
  echo "test: I-1: a GitHub-style rebase-merge of verified code is current"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  _i1_commit index
  git checkout -q -b feat
  echo "// feat" >> src/index.js
  _i1_commit "feat code"
  "$DOC_TOOLS" update-index docs/architecture.md >/dev/null 2>&1
  _i1_commit verify
  git checkout -q main
  echo "other" > other.txt
  _i1_commit "unrelated main work"
  git checkout -q feat
  git rebase -q main
  git checkout -q main
  git merge -q --ff-only feat
  assert_true "precondition: rebase re-minted the code commit" \
    test "$(jq -r '.docs["docs/architecture.md"].code_commit' docs/.doc-index.json)" != "$(_i1_last src/)"
  assert_eq "current|0|" "$(_i1_verdict "$("$DOC_TOOLS" check-freshness)" docs/architecture.md)" "rebase-merged: current"
  teardown
}

test_i1_cherry_pick_is_current() {
  echo "test: I-1: cherry-picked code + verification is current"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  _i1_commit index
  git checkout -q -b feat
  echo "// feat" >> src/index.js
  _i1_commit "feat code"
  "$DOC_TOOLS" update-index docs/architecture.md >/dev/null 2>&1
  _i1_commit verify
  local code verify
  code=$(git rev-parse HEAD~1)
  verify=$(git rev-parse HEAD)
  git checkout -q main
  # Diverge first: picked onto its own parent within the same second, a
  # commit can come out byte-identical, with the same id.
  echo "other" > other.txt
  _i1_commit "unrelated main work"
  git cherry-pick "$code" "$verify" >/dev/null
  assert_true "precondition: cherry-pick re-minted the code commit" \
    test "$(jq -r '.docs["docs/architecture.md"].code_commit' docs/.doc-index.json)" != "$(_i1_last src/)"
  assert_eq "current|0|" "$(_i1_verdict "$("$DOC_TOOLS" check-freshness)" docs/architecture.md)" "cherry-picked: current"
  teardown
}

test_i1_revert_to_verified_bytes_is_current() {
  echo "test: I-1: reverting code back to the verified bytes makes the doc current again"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  _i1_commit index
  echo "v2" > src/index.js
  _i1_commit v2
  assert_eq "stale|1|src/" "$(_i1_verdict "$("$DOC_TOOLS" check-freshness)" docs/architecture.md)" "changed: stale, 1 commit behind"
  git revert --no-edit HEAD >/dev/null
  assert_eq "current|0|" "$(_i1_verdict "$("$DOC_TOOLS" check-freshness)" docs/architecture.md)" \
    "reverted to the verified bytes: current"
  teardown
}

test_i1_code_doc_and_update_index_in_one_commit() {
  echo "test: I-1: code + doc + update-index committed together is current"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  _i1_commit index
  echo "v2" > src/index.js
  echo "## v2" >> docs/architecture.md
  "$DOC_TOOLS" update-index docs/architecture.md >/dev/null 2>&1
  _i1_commit "code + doc + index"
  local cf
  cf=$("$DOC_TOOLS" check-freshness)
  assert_eq "current|0|" "$(_i1_verdict "$cf" docs/architecture.md)" "verified in the same commit as the code: current"
  assert_json_field "$cf" '.docs["docs/architecture.md"].doc_modified' "false" "…and the doc is unmodified"
  teardown
}

test_i1_staged_change_seen_via_tree() {
  echo "test: I-1: a staged invalidating change is stale under --tree \$(git write-tree), current at HEAD"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  _i1_commit index
  echo "v2" > src/index.js
  git add src/index.js
  local staged rc out
  staged=$(git write-tree)
  assert_eq "current|0|" "$(_i1_verdict "$("$DOC_TOOLS" check-freshness)" docs/architecture.md)" "at HEAD: current"
  assert_eq "stale|0|src/" "$(_i1_verdict "$("$DOC_TOOLS" check-freshness --tree "$staged")" docs/architecture.md)" \
    "--tree <staged tree>: stale (no commit yet, so 0 commits behind)"
  assert_eq "stale|0|src/" "$(_i1_verdict "$("$DOC_TOOLS" status docs/architecture.md --tree="$staged")" docs/architecture.md)" \
    "status --tree=<staged tree> agrees"
  assert_eq "current|0|" "$(_i1_verdict "$("$DOC_TOOLS" check-freshness --tree HEAD)" docs/architecture.md)" \
    "--tree HEAD is the default"
  rc=0
  out=$("$DOC_TOOLS" check-freshness --tree no-such-rev 2>&1 >/dev/null) || rc=$?
  assert_eq "1" "$rc" "an unresolvable --tree exits 1"
  assert_contains "$out" "no-such-rev" "…naming it"
  rc=0
  "$DOC_TOOLS" check-freshness --tree=-x >/dev/null 2>&1 || rc=$?
  assert_eq "2" "$rc" "a --tree value starting with '-' is a usage error (exit 2)"
  teardown
}

test_i1_shallow_clone() {
  echo "test: I-1: a --depth 1 clone reads current; writers there record OIDs but no code_commit; commits_behind null"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  _i1_commit index
  local i=0
  while [ "$i" -lt 3 ]; do
    echo "$i" >> other.txt
    _i1_commit "other $i"
    i=$((i + 1))
  done
  local clone err json
  clone=$(harness_mktemp_d i1-shallow)
  git clone -q --depth 1 "file://$TEST_DIR" "$clone/r"
  cd "$clone/r"
  assert_eq "true" "$(git rev-parse --is-shallow-repository)" "precondition: the clone is shallow"
  assert_true "precondition: the shallow graft is src/'s last commit here (the old model's stale)" \
    test "$(jq -r '.docs["docs/architecture.md"].code_commit' docs/.doc-index.json)" != "$(_i1_last src/)"
  assert_eq "current|0|" "$(_i1_verdict "$("$DOC_TOOLS" check-freshness)" docs/architecture.md)" "depth-1 clone: current"
  echo "// shallow change" >> src/index.js
  _i1_commit "shallow change"
  assert_eq "stale|null|src/" "$(_i1_verdict "$("$DOC_TOOLS" check-freshness)" docs/architecture.md)" \
    "stale; the verified commit is beyond the graft, so commits_behind is null, not 0"
  err=$("$DOC_TOOLS" update-index docs/architecture.md 2>&1 >/dev/null) || true
  json=$(cat docs/.doc-index.json)
  assert_contains "$err" "shallow" "update-index in a shallow clone warns"
  assert_json_field "$json" '.docs["docs/architecture.md"].code_commit' "null" "…and records no code_commit"
  assert_json_field "$json" '.docs["docs/architecture.md"].code_oids["src/"]' "$(git rev-parse HEAD:src)" "…but does record code_oids"
  assert_eq "current|0|" "$(_i1_verdict "$("$DOC_TOOLS" check-freshness)" docs/architecture.md)" "re-verified: current"
  echo "// again" >> src/index.js
  _i1_commit again
  assert_eq "stale|null|src/" "$(_i1_verdict "$("$DOC_TOOLS" check-freshness)" docs/architecture.md)" \
    "no code_commit recorded: commits_behind is null"
  cd "$TEST_DIR"
  teardown
}

test_i1_code_refs_changed_is_exact() {
  echo "test: I-1: code_refs_changed lists exactly the refs whose content changed"
  setup
  echo a > src/a.js
  _i1_commit a
  echo b > src/b.js
  _i1_commit b
  echo "docs/architecture.md:src/a.js,src/b.js:architecture" | "$DOC_TOOLS" build-index
  _i1_commit index
  echo b2 > src/b.js
  _i1_commit b2
  assert_eq "stale|1|src/b.js" "$(_i1_verdict "$("$DOC_TOOLS" check-freshness)" docs/architecture.md)" \
    "only src/b.js is listed (the commit model also listed the untouched src/a.js)"
  echo b3 > src/b.js
  _i1_commit b3
  echo b4 > src/b.js
  _i1_commit b4
  assert_eq "stale|3|src/b.js" "$(_i1_verdict "$("$DOC_TOOLS" check-freshness)" docs/architecture.md)" \
    "commits_behind counts the commits touching the refs since code_commit"
  teardown
}

test_i1_commits_behind_null_when_unreachable() {
  echo "test: I-1: commits_behind is null (never a masked 0) when the verified commit is unknown"
  setup
  echo "# w" > docs/workflows.md
  _i1_commit w
  printf '%s\n' "docs/architecture.md:src/:architecture" "docs/workflows.md:src/:workflows" | "$DOC_TOOLS" build-index
  # v3 entry whose commit object does not exist; legacy (v2) entry with none.
  jq '.docs["docs/architecture.md"].code_commit = "0123456789abcdef0123456789abcdef01234567"
      | .docs["docs/workflows.md"] |= (del(.code_oids) | .code_commit = null)' \
    docs/.doc-index.json > docs/.i1.tmp
  mv docs/.i1.tmp docs/.doc-index.json
  _i1_commit index
  echo v2 > src/index.js
  _i1_commit v2
  local cf
  cf=$("$DOC_TOOLS" check-freshness)
  assert_eq "stale|null|src/" "$(_i1_verdict "$cf" docs/architecture.md)" "v3 entry, absent commit: commits_behind null"
  assert_eq "stale|null|src/" "$(_i1_verdict "$cf" docs/workflows.md)" \
    "legacy entry, null code_commit: commits_behind null, and the refs with history are listed"
  teardown
}

test_i1_mixed_v2_v3_index() {
  echo "test: I-1: a mixed v2/v3 index: legacy entries keep the commit logic; the first write bumps schema_version to 3"
  setup
  echo "# w" > docs/workflows.md
  _i1_commit w
  printf '%s\n' "docs/architecture.md:src/:architecture" "docs/workflows.md:src/:workflows" | "$DOC_TOOLS" build-index
  # architecture.md becomes a legacy entry in a v2 index.
  jq '.schema_version = 2 | .docs["docs/architecture.md"] |= del(.code_oids)' docs/.doc-index.json > docs/.i1.tmp
  mv docs/.i1.tmp docs/.doc-index.json
  _i1_commit "v2 index"
  echo v2 > src/index.js
  _i1_commit v2
  git revert --no-edit HEAD >/dev/null
  local cf before wf
  cf=$("$DOC_TOOLS" check-freshness)
  assert_eq "stale|2|src/" "$(_i1_verdict "$cf" docs/architecture.md)" \
    "legacy entry (no code_oids): the commit logic still applies (stale after a revert; 2 commits behind)"
  assert_eq "current|0|" "$(_i1_verdict "$cf" docs/workflows.md)" "v3 entry in the same index: content logic (current)"
  cp docs/.doc-index.json docs/.i1.before
  "$DOC_TOOLS" remove-entry docs/nope.md >/dev/null 2>&1
  assert_exit_code 0 "a no-op write leaves the v2 index byte-identical" cmp -s docs/.i1.before docs/.doc-index.json
  wf=$(jq -c '.docs["docs/workflows.md"]' docs/.doc-index.json)
  "$DOC_TOOLS" update-index docs/architecture.md >/dev/null 2>&1
  local json
  json=$(cat docs/.doc-index.json)
  assert_json_field "$json" '.schema_version' "3" "the first write bumps schema_version to 3"
  assert_json_field "$json" '.docs["docs/architecture.md"].code_oids["src/"]' "$(git rev-parse HEAD:src)" \
    "the re-verified legacy entry now has code_oids"
  assert_eq "$wf" "$(jq -c '.docs["docs/workflows.md"]' docs/.doc-index.json)" "the other entry is untouched"
  assert_eq "current|0|" "$(_i1_verdict "$("$DOC_TOOLS" check-freshness)" docs/architecture.md)" "re-verified: current"
  # A pre-v2 header ("version": 1) is replaced by schema_version on the first write.
  jq '{version: 1} + del(.schema_version)' docs/.doc-index.json > docs/.i1.tmp
  mv docs/.i1.tmp docs/.doc-index.json
  echo "more" >> docs/workflows.md
  "$DOC_TOOLS" update-index docs/workflows.md >/dev/null 2>&1
  assert_json_field "$(cat docs/.doc-index.json)" 'keys_unsorted | .[0]' "schema_version" "a version-1 header gets schema_version first"
  assert_json_field "$(cat docs/.doc-index.json)" 'has("version")' "false" "…and loses the legacy version key"
  rm -f docs/.i1.before
  teardown
}

test_i1_glob_looking_refs_are_literal() {
  echo "test: I-1: code refs are literal paths: glob characters warn at write time and never glob in git"
  setup
  printf 'lit\n' > 'src/a*.js'
  echo abc > src/abc.js
  _i1_commit files
  local lit_commit
  lit_commit=$(git rev-parse HEAD)
  echo "abc2" >> src/abc.js
  _i1_commit "abc only"
  local err json
  err=$(echo "docs/architecture.md:src/a*.js:architecture" | "$DOC_TOOLS" build-index 2>&1) || true
  json=$(cat docs/.doc-index.json)
  assert_contains "$err" "glob" "build-index warns about a glob-looking ref"
  assert_json_field "$json" '.docs["docs/architecture.md"].code_commit' "$lit_commit" \
    "code_commit is the literal file's last commit (a glob would have matched src/abc.js)"
  assert_json_field "$json" '.docs["docs/architecture.md"].code_oids["src/a*.js"]' "$(git rev-parse 'HEAD:src/a*.js')" \
    "code_oids holds the literal file's blob"
  _i1_commit index
  echo "abc3" >> src/abc.js
  _i1_commit "abc again"
  assert_eq "current|0|" "$(_i1_verdict "$("$DOC_TOOLS" check-freshness)" docs/architecture.md)" \
    "a change to src/abc.js does not touch the literal ref"
  echo "lit2" >> 'src/a*.js'
  _i1_commit "lit change"
  assert_eq "stale|1|src/a*.js" "$(_i1_verdict "$("$DOC_TOOLS" check-freshness)" docs/architecture.md)" \
    "a change to the literal file is stale"
  echo "# w" > docs/workflows.md
  err=$(echo "docs/workflows.md:src/?.js:workflows" | "$DOC_TOOLS" add-entry 2>&1) || true
  assert_contains "$err" "glob" "add-entry warns about a glob-looking ref"
  err=$("$DOC_TOOLS" update-index docs/architecture.md 2>&1) || true
  assert_contains "$err" "glob" "update-index warns about a glob-looking ref"
  teardown
}

test_i1_index_file_is_not_part_of_a_ref() {
  echo "test: I-1: refs covering docs/ or the repo root ignore the doc-index itself"
  setup
  echo "# w" > docs/workflows.md
  _i1_commit w
  printf '%s\n' "docs/architecture.md:.:architecture" "docs/workflows.md:docs/:workflows" | "$DOC_TOOLS" build-index
  _i1_commit index
  local cf
  cf=$("$DOC_TOOLS" check-freshness)
  assert_eq "current|0|" "$(_i1_verdict "$cf" docs/architecture.md)" "ref '.': current after committing the index"
  assert_eq "current|0|" "$(_i1_verdict "$cf" docs/workflows.md)" "ref 'docs/': current after committing the index"
  echo "## more" >> docs/architecture.md
  "$DOC_TOOLS" update-index docs/architecture.md >/dev/null 2>&1
  _i1_commit "doc + index"
  cf=$("$DOC_TOOLS" check-freshness)
  assert_eq "current|0|" "$(_i1_verdict "$cf" docs/architecture.md)" "ref '.': re-verified under the lock, committed: current"
  assert_eq "stale" "$(_i1_verdict "$cf" docs/workflows.md | cut -d'|' -f1)" \
    "ref 'docs/': another doc in docs/ changed, so stale"
  teardown
}

test_i1_ref_without_code_oids_is_unverified() {
  echo "test: I-1: a ref that code_oids does not cover (added to code_refs by hand) is unverified: stale"
  setup
  echo a > src/a.js
  _i1_commit a
  echo "docs/architecture.md:src/index.js:architecture" | "$DOC_TOOLS" build-index
  # Last in code_refs, so its (empty) stored id is the record's final field.
  jq '.docs["docs/architecture.md"].code_refs += ["src/a.js"]' docs/.doc-index.json > docs/.i1.tmp
  mv docs/.i1.tmp docs/.doc-index.json
  _i1_commit index
  local rc=0 out
  out=$("$DOC_TOOLS" check-freshness 2>&1) || rc=$?
  assert_eq "0" "$rc" "check-freshness exits 0 (stderr/stdout: ${out:0:200})"
  assert_eq "stale|1|src/a.js" "$(_i1_verdict "$out" docs/architecture.md)" "only the unverified ref is listed"
  "$DOC_TOOLS" update-index docs/architecture.md >/dev/null 2>&1
  assert_eq "current|0|" "$(_i1_verdict "$("$DOC_TOOLS" check-freshness)" docs/architecture.md)" \
    "update-index records it: current"
  teardown
}

test_i1_move_entry_preserves_code_oids() {
  echo "test: I-1: move-entry carries code_oids over unchanged"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  local oids
  oids=$(jq -c '.docs["docs/architecture.md"].code_oids' docs/.doc-index.json)
  git mv docs/architecture.md docs/arch.md 2>/dev/null || mv docs/architecture.md docs/arch.md
  "$DOC_TOOLS" move-entry docs/architecture.md docs/arch.md >/dev/null 2>&1
  assert_eq "$oids" "$(jq -c '.docs["docs/arch.md"].code_oids' docs/.doc-index.json)" "code_oids preserved"
  assert_true "precondition: code_oids is a non-empty object" test "$oids" != "null"
  teardown
}

# The sweep measured 117 s at N=4,000 / H=3,000: every doc paid its own
# `git rev-list` walks. Content identity is one batch-check for the whole index,
# plus one `git rev-list --count` per stale (code_commit, refs) group.
test_i1_check_freshness_scale() {
  local n=2000 h=500 k=3 dirs=100
  echo "test: I-1: check-freshness over $n docs and $h commits: < 5 s, git spawns independent of N"
  setup
  # One fast-import: $dirs x 20 files, then $h commits touching one file each.
  {
    printf 'commit refs/heads/main\ncommitter T <t@t> 1600000000 +0000\ndata <<EOT\nfiles\nEOT\nfrom refs/heads/main^0\n'
    local m=0 f c
    while [ "$m" -lt "$dirs" ]; do
      f=0
      while [ "$f" -lt 20 ]; do
        printf 'M 100644 inline src/m%d/f%d.js\ndata <<EOT\nv0\nEOT\n' "$m" "$f"
        f=$((f + 1))
      done
      m=$((m + 1))
    done
    c=1
    while [ "$c" -lt "$h" ]; do
      printf 'commit refs/heads/main\ncommitter T <t@t> %d +0000\ndata <<EOT\nc%d\nEOT\n' $((1600000000 + c)) "$c"
      printf 'M 100644 inline src/m%d/f%d.js\ndata <<EOT\nv%d\nEOT\n' $((c % dirs)) $((c % 20)) "$c"
      c=$((c + 1))
    done
  } | git fast-import --quiet
  git reset -q --hard
  mkdir -p docs/s
  local i=0 map
  map=$(harness_mktemp i1-scale-map)
  while [ "$i" -lt "$n" ]; do
    printf '# d%d\n' "$i" > "docs/s/d$i.md"
    printf 'docs/s/d%d.md:src/m%d/:guide\n' "$i" $((i % dirs))
    i=$((i + 1))
  done > "$map"
  _i1_commit docs
  local t0 build_s
  t0=$(date +%s)
  "$DOC_TOOLS" build-index < "$map" 2>/dev/null
  build_s=$(( $(date +%s) - t0 ))
  _i1_commit index
  i=0
  while [ "$i" -lt "$k" ]; do
    echo "changed" >> "src/m$i/f0.js"
    i=$((i + 1))
  done
  _i1_commit change
  assert_true "precondition: history has >= $h commits ($(git rev-list --count HEAD))" \
    test "$(git rev-list --count HEAD)" -ge "$h"
  local shims out rc=0 elapsed git_n jq_n
  shims=$(_i1_count_shims git jq)
  t0=$(date +%s)
  out=$(PATH="$shims:$PATH" "$DOC_TOOLS" check-freshness) || rc=$?
  elapsed=$(( $(date +%s) - t0 ))
  git_n=$(grep -c '^git$' "$shims/spawns" || true)
  jq_n=$(grep -c '^jq$' "$shims/spawns" || true)
  assert_eq "0" "$rc" "check-freshness exits 0"
  assert_json_field "$out" '.summary | "\(.current) \(.stale)"' "$((n - k * n / dirs)) $((k * n / dirs))" \
    "exactly the docs covering the $k changed directories are stale"
  # Whole seconds: <= 4 measured guarantees < 5 s real.
  assert_true "check-freshness took ${elapsed}s for $n docs x $h commits (< 5 s; build-index took ${build_s}s)" \
    test "$elapsed" -le 4
  # Fixed git calls (repository check, HEAD, tree, one batch-check) plus one
  # rev-list --count per stale (code_commit, refs) group — $k here — and none
  # per current doc.
  assert_true "check-freshness spawned $git_n git processes (budget 6 + $k stale groups)" \
    test "$git_n" -le $((6 + k))
  assert_true "check-freshness spawned $jq_n jq processes (budget 10)" test "$jq_n" -le 10
  teardown
}

# The writers' per-key work was quadratic in the number of keys: a
# newline-framed `case` lookup per key in every report, and — under bash 3.2,
# which copies the caller's "$@" on every function call — any loop calling a
# function while "$@" held the paths. Every writer now reports from one
# classification its own jq pass makes, and clears "$@" once it has the paths.
# Measured at 4,000 keys under bash 3.2 (M-series laptop), before → after:
# update-index 20 s → 4.4 s, deprecate-entry / remove-entry 14-15 s → 1.3 s,
# add-entry (one git walk and one hash per key) 63 s → 6.2 s. The budgets are
# about 3x the linear times, and below the quadratic ones on bash 3.2 (the
# interpreter where the quadratic cost bites; under bash 5 the old code took
# 6 / 4 / 4 / 52 s, so there only the add-entry budget discriminates).
test_i1_writer_reports_are_linear() {
  local k=4000
  echo "test: I-1: add-entry / update-index / deprecate-entry / remove-entry of $k keys stay linear"
  setup
  mkdir -p docs/k
  local i=0 map paths=()
  map=$(harness_mktemp i1-wr-map)
  while [ "$i" -lt "$k" ]; do
    printf '# k%d\n' "$i" > "docs/k/k$i.md"
    printf 'docs/k/k%d.md:src/:guide\n' "$i"
    paths+=("docs/k/k$i.md")
    i=$((i + 1))
  done > "$map"
  _i1_commit docs
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  local t0 s_add s_upd s_dep s_rem out
  t0=$(date +%s)
  out=$("$DOC_TOOLS" add-entry < "$map" 2>&1) || true
  s_add=$(( $(date +%s) - t0 ))
  assert_contains "$out" "Added $k entries:" "add-entry reports $k added"
  echo "v2" >> src/index.js
  _i1_commit v2
  t0=$(date +%s)
  out=$("$DOC_TOOLS" update-index "${paths[@]}" 2>&1) || true
  s_upd=$(( $(date +%s) - t0 ))
  assert_contains "$out" "Refreshed $k entries:" "update-index reports $k refreshed"
  t0=$(date +%s)
  out=$("$DOC_TOOLS" deprecate-entry "${paths[@]}" docs/nope.md 2>&1) || true
  s_dep=$(( $(date +%s) - t0 ))
  assert_contains "$out" "Deprecated $k entries:" "deprecate-entry reports $k deprecated"
  assert_contains "$out" "SKIP: 'docs/nope.md' not found in index." "…and the absent key as not found"
  t0=$(date +%s)
  out=$("$DOC_TOOLS" remove-entry "${paths[@]}" 2>&1) || true
  s_rem=$(( $(date +%s) - t0 ))
  assert_contains "$out" "Removed $k entries:" "remove-entry reports $k removed"
  assert_true "add-entry of $k keys took ${s_add}s (budget 20 s)" test "$s_add" -le 20
  assert_true "update-index of $k keys took ${s_upd}s (budget 14 s)" test "$s_upd" -le 14
  assert_true "deprecate-entry of $k keys took ${s_dep}s (budget 5 s)" test "$s_dep" -le 5
  assert_true "remove-entry of $k keys took ${s_rem}s (budget 5 s)" test "$s_rem" -le 5
  teardown
}

# --- Runner ---

run_tests() {
  echo "=== doc-tools.sh test suite ==="
  echo ""
  # --- harness self-tests (run first: every later result depends on them) ---
  test_harness_asserts_are_pipefail_safe
  test_harness_int_stops_suite_and_cleans_up

  test_no_args_prints_usage
  test_unknown_subcommand_prints_usage
  test_help_flag
  test_build_index_creates_index
  test_build_index_hashes_doc
  test_build_index_stores_code_commit
  test_build_index_multiple_code_refs
  test_build_index_multiple_docs
  test_build_index_sets_status_current
  test_build_index_null_code_commit_for_untracked
  test_check_freshness_requires_index
  test_check_freshness_current
  test_check_freshness_stale_after_code_change
  test_check_freshness_doc_modified
  test_check_freshness_missing_doc
  test_check_freshness_deprecated_preserved
  test_check_freshness_commits_behind
  test_check_freshness_code_refs_filter
  test_check_freshness_code_refs_bidirectional_prefix
  test_check_freshness_untracked_docs
  test_check_freshness_scales_to_large_index
  test_update_index_refreshes_entry
  test_update_index_preserves_build_commit
  test_update_index_preserves_replaces
  test_update_index_unknown_path_errors
  test_status_single_doc
  test_status_stale_doc
  test_status_unknown_path
  test_status_requires_path_arg
  test_check_freshness_current_includes_doc_type
  test_check_freshness_current_includes_last_verified
  test_check_freshness_stale_includes_code_refs_changed
  test_status_stale_includes_code_refs_changed
  test_update_index_preserves_superseded_by
  test_update_index_updates_generated_at
  test_build_index_empty_stdin
  test_update_index_multiple_paths

  # --- cross-platform regression guards (CI matrix: bash 5.x + bash 3.2) ---
  test_scripts_are_free_of_bash4_only_constructs
  test_build_index_accepts_entry_with_no_code_refs
  test_update_index_when_every_target_is_skipped
  test_build_index_and_check_freshness_beyond_argv_limits
  test_bump_version_updates_all_files
  test_bump_version_idempotent
  test_bump_version_validates_semver
  test_bump_version_requires_arg
  test_check_version_detects_mismatch
  test_check_version_passes_when_synced
  test_fragments_list_empty
  test_fragments_list_valid
  test_fragments_validate_drifted
  test_fragments_merge_orders_by_n
  test_fragments_merge_includes_drifted
  test_fragments_merge_preserves_non_canonical_sections
  test_fragments_merge_dedupes_bullets
  test_fragments_list_skips_non_numeric
  test_fragments_merge_paths_out
  test_fragments_merge_errors_outside_git_repo
  test_set_implementation_creates_block
  test_set_implementation_appends_to_existing
  test_set_implementation_replaces_existing_ref
  test_set_implementation_rejects_invalid_status
  test_implementation_status_parses_block
  test_implementation_status_no_field
  test_update_index_captures_implementation

  # --- tools subcommand (Feature A) ---
  test_tools_install_vendors_doc_tools_default_dest
  test_tools_install_custom_dest
  test_tools_install_with_helpers
  test_tools_install_without_helpers_default
  test_tools_uninstall_removes_vendored_copy
  test_tools_uninstall_removes_unmodified_helpers
  test_tools_uninstall_keeps_modified_helpers
  test_tools_uninstall_preserves_release_notes_next_readme
  test_tools_status_not_installed
  test_tools_status_installed_matches_plugin
  test_tools_status_reports_drift
  test_tools_install_unknown_flag_errors

  # --- doc-path key normalization (add-entry + siblings) ---
  test_add_entry_accepts_relative_path
  test_add_entry_normalizes_absolute_path_inside_repo
  test_add_entry_rejects_path_outside_repo
  test_add_entry_mixed_batch_applies_valid_and_fails
  test_add_entry_reports_added_paths
  test_add_entry_normalizes_dot_segments
  test_add_entry_preserves_dots_in_filenames
  test_build_index_rejects_path_outside_repo
  test_build_index_normalizes_absolute_path_inside_repo
  test_update_index_accepts_absolute_path_inside_repo
  test_remove_entry_accepts_absolute_path_inside_repo
  test_remove_entry_rejects_path_outside_repo
  test_remove_entry_missing_relative_path_still_skips
  test_deprecate_entry_normalizes_paths_and_superseded_by
  test_status_accepts_absolute_path_inside_repo

  # --- move-entry (re-key without metadata loss) ---
  test_move_entry_preserves_all_metadata
  test_move_entry_preserves_unknown_fields
  test_move_entry_preserves_key_position
  test_move_entry_status_deprecated_survives
  test_move_entry_bumps_generated_at
  test_move_entry_requires_two_args
  test_move_entry_unknown_old_path_errors
  test_move_entry_refuses_existing_target
  test_move_entry_requires_new_file_on_disk
  test_move_entry_same_path_is_noop
  test_move_entry_warns_when_old_file_remains
  test_move_entry_normalizes_absolute_paths
  test_move_entry_repoints_references
  test_move_entry_usage_lists_move_entry
  test_empty_code_refs_field_yields_empty_array

  # --- index persistence: one locked atomic writer (sweep 05ea982 I-2) ---
  test_index_single_write_path_static
  test_index_term_mid_build_index_keeps_previous_index
  test_index_term_while_build_index_blocked_on_stdin
  test_index_term_mid_check_freshness_prints_nothing
  test_index_parallel_update_index_loses_nothing
  test_index_reader_never_sees_a_partial_write
  test_index_zero_byte_index_rejected_by_every_verb
  test_index_malformed_shapes_rejected
  test_index_build_index_recovers_a_zero_byte_index
  test_index_mode_is_0644_and_prior_mode_is_kept
  test_index_noop_writers_leave_the_file_byte_identical
  test_index_writers_report_only_changed_keys
  test_index_stale_lock_from_dead_owner_is_broken
  test_index_live_lock_times_out_with_clear_error
  test_index_term_during_lock_acquire_leaves_no_lock
  test_index_term_while_breaking_a_stale_lock_leaves_no_mutex
  test_index_term_while_holding_the_lock
  test_jq_version_gate
  test_update_index_is_one_batch_pass

  # --- CLI and input robustness (sweep 05ea982 I-4) ---
  test_i4_help_lists_every_dispatchable_verb
  test_i4_flags_anywhere_and_unknown_flags_exit_2
  test_i4_build_index_refuses_empty_input_and_existing_index
  test_i4_mapping_line_parser
  test_i4_check_freshness_and_status_agree
  test_i4_code_refs_match_by_path_segment
  test_i4_doc_paths_normalized_and_targets_deduped
  test_i4_outside_a_git_repo
  test_i4_show_signature_does_not_leak_into_code_commit
  test_i4_unborn_head
  test_i4_update_index_unknown_key_applies_the_rest
  test_i4_hostile_names_and_stored_values
  test_i4_option_spec_is_not_glob_expanded
  test_i4_arity_errors_exit_2

  # --- Content identity: code_oids and --tree (sweep 05ea982 I-1) ---
  test_i1_writers_record_code_oids
  test_i1_squash_merge_is_current
  test_i1_rebase_merge_is_current
  test_i1_cherry_pick_is_current
  test_i1_revert_to_verified_bytes_is_current
  test_i1_code_doc_and_update_index_in_one_commit
  test_i1_staged_change_seen_via_tree
  test_i1_shallow_clone
  test_i1_code_refs_changed_is_exact
  test_i1_commits_behind_null_when_unreachable
  test_i1_mixed_v2_v3_index
  test_i1_glob_looking_refs_are_literal
  test_i1_index_file_is_not_part_of_a_ref
  test_i1_ref_without_code_oids_is_unverified
  test_i1_move_entry_preserves_code_oids
  test_i1_check_freshness_scale
  test_i1_writer_reports_are_linear

  print_summary
}

run_tests
