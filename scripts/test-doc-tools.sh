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
  print_summary
}

run_tests
