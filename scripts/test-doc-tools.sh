#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOC_TOOLS="$SCRIPT_DIR/doc-tools.sh"

# shellcheck source=scripts/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

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
  assert_json_field "$json" ".version" "1" "version is 1"
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
  test_bump_version_updates_all_files
  test_bump_version_idempotent
  test_bump_version_validates_semver
  test_bump_version_requires_arg
  test_check_version_detects_mismatch
  test_check_version_passes_when_synced
  print_summary
}

run_tests
