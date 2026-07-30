#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

# Run doc-tools.sh under the interpreter this suite was launched with,
# not whatever `#!/usr/bin/env bash` resolves to. See bash_bin_shim().
DOC_TOOLS="$(bash_bin_shim "$SCRIPT_DIR/doc-tools.sh")"

# --- Tests ---

test_no_args_prints_usage() {
  echo "test: no args prints usage and exits 1"
  setup
  set +e
  local output
  output=$("$DOC_TOOLS" 2>&1)
  local exit_code=$?
  set -e
  assert_eq "1" "$exit_code" "exits 1 with no args"
  assert_contains "$output" "Usage" "prints usage"
  teardown
}

test_unknown_subcommand_prints_usage() {
  echo "test: unknown subcommand prints usage and exits 1"
  setup
  set +e
  local output
  output=$("$DOC_TOOLS" unknown 2>&1)
  local exit_code=$?
  set -e
  assert_eq "1" "$exit_code" "exits 1 with unknown subcommand"
  assert_contains "$output" "Usage" "prints usage for unknown subcommand"
  teardown
}

test_help_flag() {
  echo "test: --help prints usage and exits 1"
  setup
  set +e
  local output
  output=$("$DOC_TOOLS" --help 2>&1)
  local exit_code=$?
  set -e
  assert_eq "1" "$exit_code" "exits 1 with --help"
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
  assert_json_field "$json" ".schema_version" "2" "schema_version is 2"
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
  echo "docs/architecture.md:nonexistent/:architecture" | "$DOC_TOOLS" build-index
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
  "$DOC_TOOLS" update-index docs/architecture.md
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
  "$DOC_TOOLS" update-index docs/architecture.md
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
  "$DOC_TOOLS" update-index docs/architecture.md
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
  set +e
  echo "docs/architecture.md::architecture" | "$DOC_TOOLS" build-index 2>/tmp/.norefs-stderr
  local rc=$?
  set -e
  local err
  err=$(cat /tmp/.norefs-stderr 2>/dev/null || true)
  rm -f /tmp/.norefs-stderr
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

  # Each entry: <label>|<ERE>. Kept as a flat list rather than a map so this
  # test does not itself need an associative array.
  local patterns=(
    'associative array declaration (declare/local/typeset -A) [bash 4.0+]|(declare|local|typeset)[[:space:]]+-[a-zA-Z]*A[a-zA-Z]*[[:space:]]'
    'mapfile/readarray [bash 4.0+]|(^|[^[:alnum:]_-])(mapfile|readarray)[[:space:]]'
    'case-modification expansion ${v^^} / ${v,,} [bash 4.0+]|\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(\^\^|,,|\^|,)[^}]*\}'
    'append-and-redirect &>> [bash 4.0+]|&>>'
    'negative array index ${a[-1]} [bash 4.3+]|\$\{[A-Za-z_][A-Za-z0-9_]*\[-[0-9]'
    'coproc [bash 4.0+]|(^|[^[:alnum:]_-])coproc[[:space:]]'
    'wait -n [bash 4.3+]|(^|[^[:alnum:]_-])wait[[:space:]]+-n([[:space:]]|$)'
  )

  # Full-line comments are blanked (line numbering preserved) before matching:
  # the fixes for these very bugs are documented in comments that name the
  # offending construct, and a guard that trips on its own rationale is a guard
  # someone disables. Inline code is left untouched, so a real construct is
  # still caught wherever it can actually execute.
  local scrubbed
  scrubbed=$(mktemp -t bash4scan.XXXXXX)

  local spec
  for spec in "${patterns[@]}"; do
    local label="${spec%%|*}"
    local regex="${spec#*|}"
    local hits=""
    local target
    for target in "${targets[@]}"; do
      awk '{ if ($0 ~ /^[[:space:]]*#/) print ""; else print }' "$target" > "$scrubbed"
      local file_hits
      file_hits=$(grep -nE -- "$regex" "$scrubbed" 2>/dev/null || true)
      if [ -n "$file_hits" ]; then
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
  mapping_tmp=$(mktemp -t argmax.XXXXXX)
  local i=0
  while [ "$i" -lt "$doc_count" ]; do
    printf '# doc %d\n' "$i" > "docs/synthetic/d$i.md"
    # Third field is doc_type; it is stored verbatim in the entry, so it is the
    # cheapest way to inflate the serialized index without 3400 files.
    printf 'docs/synthetic/d%d.md:src/:%s\n' "$i" "$pad" >> "$mapping_tmp"
    i=$((i + 1))
  done
  git add -A && git commit -m "synthetic docs" --quiet

  set +e
  "$DOC_TOOLS" build-index < "$mapping_tmp" 2>/tmp/.argmax-stderr
  local build_rc=$?
  set -e
  rm -f "$mapping_tmp"

  local build_err
  build_err=$(cat /tmp/.argmax-stderr 2>/dev/null || true)
  rm -f /tmp/.argmax-stderr
  assert_eq "0" "$build_rc" "build-index exits 0 (stderr: ${build_err:-none})"
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
  fresh_out=$("$DOC_TOOLS" check-freshness 2>/tmp/.argmax-stderr2)
  local fresh_rc=$?
  set -e
  local fresh_err
  fresh_err=$(cat /tmp/.argmax-stderr2 2>/dev/null || true)
  rm -f /tmp/.argmax-stderr2
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
  echo "test: check-freshness scales to ~500 entries within 60s"
  setup
  # Build a synthetic index with 500 docs pointing at a single tracked
  # code dir, plus a deliberate stale ref to exercise compute_freshness.
  mkdir -p docs/synthetic
  local mapping_tmp
  mapping_tmp=$(mktemp -t synth.XXXXXX)
  local i=0
  while [ "$i" -lt 500 ]; do
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

  local start_ts end_ts elapsed output
  start_ts=$(date +%s)
  output=$("$DOC_TOOLS" check-freshness)
  end_ts=$(date +%s)
  elapsed=$((end_ts - start_ts))

  local stale_count
  stale_count=$(echo "$output" | jq '.summary.stale')
  assert_eq "500" "$stale_count" "all 500 synthetic docs reported stale"

  # Soft budget: 60 s is generous (real-world failures hit ~600 s SIGKILL).
  # A regression here would mean the per-entry jq spawn pattern crept back in.
  if [ "$elapsed" -gt 60 ]; then
    echo "    FAIL: check-freshness took ${elapsed}s for 500 docs (budget: 60s)" >&2
    return 1
  fi
  echo "    elapsed: ${elapsed}s for 500 docs (budget: 60s)"
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
  echo "test: status exits 1 with no path argument"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  set +e
  local exit_code
  "$DOC_TOOLS" status >/dev/null 2>&1
  exit_code=$?
  set -e
  assert_eq "1" "$exit_code" "exits 1 with no arg"
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
  "$DOC_TOOLS" update-index docs/architecture.md >/dev/null
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
  "$DOC_TOOLS" update-index docs/architecture.md >/dev/null
  local new_generated_at
  new_generated_at=$(jq -r '.generated_at' docs/.doc-index.json)
  if [ "$orig_generated_at" != "$new_generated_at" ]; then
    assert_eq "true" "true" "generated_at updated after update-index"
  else
    assert_eq "changed" "unchanged" "generated_at updated after update-index"
  fi
  teardown
}

test_build_index_empty_stdin() {
  echo "test: build-index with empty stdin produces valid empty index"
  setup
  echo "" | "$DOC_TOOLS" build-index
  assert_file_exists "docs/.doc-index.json" "index created"
  local doc_count
  doc_count=$(jq '.docs | length' docs/.doc-index.json)
  assert_eq "0" "$doc_count" "zero docs in index"
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
  "$DOC_TOOLS" update-index docs/architecture.md docs/workflows.md >/dev/null
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
  assert_eq "1" "$exit_code" "exits 1"
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
  local empty_tree out stderr_out
  empty_tree=$(git hash-object -t tree --stdin </dev/null)
  out=$("$DOC_TOOLS" fragments merge "$empty_tree" HEAD 2>/tmp/.merge-stderr || true)
  stderr_out=$(cat /tmp/.merge-stderr || true)
  rm -f /tmp/.merge-stderr

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
  local out
  out=$("$DOC_TOOLS" fragments merge "$(git hash-object -t tree --stdin </dev/null)" HEAD)
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
  local out count
  out=$("$DOC_TOOLS" fragments merge "$(git hash-object -t tree --stdin </dev/null)" HEAD)
  count=$(printf '%s\n' "$out" | grep -c -- "- same bullet" || true)
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

  local out paths_file=/tmp/test-paths-out.txt
  out=$("$DOC_TOOLS" fragments merge "$before_tag" HEAD --paths-out="$paths_file")
  assert_contains "$out" "after-tag" "PR-4 (post-tag) is consumed"
  # shellcheck disable=SC2059
  if printf '%s' "$out" | grep -q "in-range"; then
    FAIL=$((FAIL + 1))
    TESTS_RUN=$((TESTS_RUN + 1))
    printf "${RED}  FAIL${NC}: PR-3 (pre-tag) should NOT be in merged output (%s)\n" "$out"
  fi
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
  tmp=$(mktemp -d)
  set +e
  ( cd "$tmp" && "$DOC_TOOLS" fragments merge HEAD~1 HEAD >/dev/null 2>/tmp/.merge-stderr )
  local rc=$?
  set -e
  local stderr_out
  stderr_out=$(cat /tmp/.merge-stderr 2>/dev/null || true)
  rm -f /tmp/.merge-stderr
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

  local out pos_99 pos_101
  out=$("$DOC_TOOLS" fragments merge "$base" HEAD)
  pos_99=$(printf '%s' "$out" | grep -n "smaller N" | head -1 | cut -d: -f1)
  pos_101=$(printf '%s' "$out" | grep -n "larger N" | head -1 | cut -d: -f1)

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
  if echo "$content" | grep -q "in-progress"; then
    FAIL=$((FAIL + 1))
    printf "${RED}  FAIL${NC}: stale 'in-progress' status still present\n"
  else
    PASS=$((PASS + 1))
    printf "${GREEN}  PASS${NC}: old status replaced\n"
  fi
  TESTS_RUN=$((TESTS_RUN + 1))
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
  "$DOC_TOOLS" update-index docs/adr/ADR-X.md 2>/dev/null
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
  [[ -x ".github/scripts/doc-tools.sh" ]]
  assert_eq "0" "$?" "vendored copy is executable"
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
  [[ ! -d ".github/scripts/doc-pr-release" ]]
  assert_eq "0" "$?" "helpers dir NOT created"
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
  [[ ! -d ".github/scripts/doc-pr-release" ]]
  assert_eq "0" "$?" "helpers dir removed (no local edits)"
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
  assert_contains "$output" "Rejected 1 invalid path" "reports the rejection"
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
  output=$(printf '%s\n%s\n' "docs/architecture.md:src/:architecture" "/etc/hosts:src/:design" \
    | "$DOC_TOOLS" build-index 2>&1)
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
  assert_eq "1" "$exit_code" "exits 1 with no arguments"
  assert_contains "$output" "requires exactly two arguments" "stderr explains the arity"
  set +e
  output=$("$DOC_TOOLS" move-entry docs/architecture.md 2>&1)
  exit_code=$?
  set -e
  assert_eq "1" "$exit_code" "exits 1 with one argument"
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
  outside=$(mktemp -d)
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
  assert_contains "$output" "Usage: move-entry <old_doc_path>" \
    "usage heredoc documents the move-entry signature"
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

# --- Runner ---

run_tests() {
  echo "=== doc-tools.sh test suite ==="
  echo ""
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

  print_summary
}

run_tests
