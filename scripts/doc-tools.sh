#!/usr/bin/env bash
set -euo pipefail

# doc-tools.sh — bundled doc freshness tracking for doc-superpowers
# Usage: doc-tools.sh <subcommand> [options]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Dependency checks ---

check_deps() {
  local missing=0
  for cmd in git jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "ERROR: required command not found: $cmd" >&2
      missing=1
    fi
  done
  if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    echo "ERROR: required command not found: sha256sum or shasum" >&2
    missing=1
  fi
  [ "$missing" -eq 0 ]
}

# --- Utility functions ---

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

iso_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

repo_head() {
  git rev-parse HEAD 2>/dev/null || echo "unknown"
}

# Computes freshness for a single doc entry.
# Args: doc_path entry_json
# Outputs JSON with: status, doc_modified, commits_behind, and if stale: reason, code_refs_changed
compute_freshness() {
  local doc_path="$1"
  local entry="$2"

  local current_hash stored_hash doc_modified
  current_hash="sha256:$(hash_file "$doc_path")"
  stored_hash=$(echo "$entry" | jq -r '.content_hash')
  [ "$current_hash" != "$stored_hash" ] && doc_modified=true || doc_modified=false

  local code_refs_arr=()
  while IFS= read -r _ref; do
    [[ -n "$_ref" ]] && code_refs_arr+=("$_ref")
  done < <(echo "$entry" | jq -r '.code_refs[]' 2>/dev/null || true)

  local current_code_commit=""
  if [ ${#code_refs_arr[@]} -gt 0 ]; then
    current_code_commit=$(git log -1 --format=%H -- "${code_refs_arr[@]}" 2>/dev/null || true)
  fi

  local stored_code_commit
  stored_code_commit=$(echo "$entry" | jq -r '.code_commit // empty')

  local status reason
  if [ -n "$current_code_commit" ] && [ "$current_code_commit" != "$stored_code_commit" ]; then
    status="stale"
    reason="code_changed"
  else
    status="current"
    reason=""
  fi

  local commits_behind=0
  if [ -n "$stored_code_commit" ] && [ ${#code_refs_arr[@]} -gt 0 ]; then
    commits_behind=$(git rev-list --count "${stored_code_commit}..HEAD" -- "${code_refs_arr[@]}" 2>/dev/null || echo 0)
  fi

  local code_refs_changed_json="[]"
  if [ "$status" = "stale" ] && [ -n "$stored_code_commit" ]; then
    local changed_refs=()
    for ref in "${code_refs_arr[@]}"; do
      local ref_commit
      ref_commit=$(git log -1 --format=%H -- "$ref" 2>/dev/null || true)
      if [ -n "$ref_commit" ] && [ "$ref_commit" != "$stored_code_commit" ]; then
        changed_refs+=("$ref")
      fi
    done
    code_refs_changed_json=$(printf '%s\n' "${changed_refs[@]+"${changed_refs[@]}"}" | jq -R . | jq -s .)
  fi

  if [ -n "$reason" ]; then
    jq -n \
      --arg status "$status" \
      --arg reason "$reason" \
      --argjson doc_modified "$doc_modified" \
      --argjson commits_behind "$commits_behind" \
      --argjson code_refs_changed "$code_refs_changed_json" \
      '{status: $status, reason: $reason, doc_modified: $doc_modified, commits_behind: $commits_behind, code_refs_changed: $code_refs_changed}'
  else
    jq -n \
      --arg status "$status" \
      --argjson doc_modified "$doc_modified" \
      --argjson commits_behind "$commits_behind" \
      '{status: $status, doc_modified: $doc_modified, commits_behind: $commits_behind}'
  fi
}

# --- Usage ---

usage() {
  cat >&2 <<'EOF'
Usage: doc-tools.sh <subcommand> [options]

Subcommands:
  build-index       Build docs/.doc-index.json from stdin mapping
                    Stdin format: one line per doc — doc_path:code_refs_csv:doc_type
                    Example: docs/architecture.md:SKILL.md,scripts/:architecture
  check-freshness   Check if docs are stale relative to code changes
  update-index      Update specific entries in docs/.doc-index.json
  add-entry         Add new entries to existing docs/.doc-index.json
                    Stdin format: same as build-index — doc_path:code_refs_csv:doc_type
  remove-entry      Remove entries from docs/.doc-index.json by path
  deprecate-entry   Mark entries as deprecated in docs/.doc-index.json
                    Usage: deprecate-entry [--superseded-by <path>] <doc_path> ...
  status <path>     Query freshness of a single doc (read-only)
  bump-version VER  Update version string in all manifest files
                    Files: RELEASE-NOTES.md, package.json, claude-code.json,
                    .claude-plugin/plugin.json, .claude-plugin/marketplace.json,
                    .cursor-plugin/plugin.json, gemini-extension.json
  check-version     Verify all manifest files have the same version
  fragments list                       List per-PR release-notes fragments + hash status
  fragments validate <path>            Exit 0 if fragment hash matches, 1 if drifted
  fragments merge <start> <end> [--paths-out=<file>]
                                       Print merged sections from fragments in commit range
                                       (--paths-out writes consumed fragment paths, one per line)
  tools install [--dest <path>] [--with-helpers]
                                       Vendor doc-tools.sh (and optionally doc-pr-release
                                       helpers + RELEASE-NOTES.next/README.md) into <path>.
                                       Default --dest is .github/scripts.
  tools uninstall [--dest <path>]      Remove vendored doc-tools.sh (and matching helpers)
                                       from <path>. Default --dest is .github/scripts.
  tools status [--dest <path>]         Report whether doc-tools.sh is vendored, version,
                                       drift state, helper presence.

Options:
  --help            Show this help message

EOF
  exit 1
}

# --- Subcommand stubs ---

cmd_build_index() {
  # Read stdin: one line per doc in format doc_path:comma_code_refs:doc_type
  # Write docs/.doc-index.json
  local docs_dir="docs"
  local index_file="$docs_dir/.doc-index.json"
  local now
  now=$(iso_now)
  local build_commit
  build_commit=$(repo_head)

  # Accumulate entries as a jq-compatible JSON object
  local docs_json="{}"

  # Save stdin to fd 3, then redirect fd 0 to /dev/null so subprocesses
  # (e.g. git) don't consume lines from the input pipe
  exec 3<&0 0</dev/null

  while IFS= read -r line <&3 || [ -n "$line" ]; do
    [ -z "$line" ] && continue

    # Parse fields
    local doc_path code_refs_raw doc_type
    doc_path=$(echo "$line" | cut -d: -f1)
    code_refs_raw=$(echo "$line" | cut -d: -f2)
    doc_type=$(echo "$line" | cut -d: -f3)

    # Compute content hash
    local content_hash_val
    if [ -f "$doc_path" ]; then
      content_hash_val="\"sha256:$(hash_file "$doc_path")\""
    else
      content_hash_val="null"
    fi

    # Build code_refs JSON array from comma-separated list
    local code_refs_json
    code_refs_json=$(echo "$code_refs_raw" | tr ',' '\n' | jq -R . | jq -s .)

    # Compute latest commit across all code refs (single git log call per spec)
    local code_commit=""
    IFS=',' read -ra refs <<< "$code_refs_raw"
    code_commit=$(git log -1 --format=%H -- "${refs[@]}" 2>/dev/null || true)

    # Build the entry JSON
    local entry_json
    if [ -n "$code_commit" ]; then
      entry_json=$(jq -n \
        --argjson content_hash "$content_hash_val" \
        --argjson code_refs "$code_refs_json" \
        --arg code_commit "$code_commit" \
        --arg doc_type "$doc_type" \
        --arg last_verified "$now" \
        '{
          content_hash: $content_hash,
          code_refs: $code_refs,
          code_commit: $code_commit,
          doc_type: $doc_type,
          status: "current",
          replaces: null,
          superseded_by: null,
          last_verified: $last_verified
        }')
    else
      entry_json=$(jq -n \
        --argjson content_hash "$content_hash_val" \
        --argjson code_refs "$code_refs_json" \
        --arg doc_type "$doc_type" \
        --arg last_verified "$now" \
        '{
          content_hash: $content_hash,
          code_refs: $code_refs,
          code_commit: null,
          doc_type: $doc_type,
          status: "current",
          replaces: null,
          superseded_by: null,
          last_verified: $last_verified
        }')
    fi

    # Merge entry into docs_json
    docs_json=$(echo "$docs_json" | jq --arg key "$doc_path" --argjson val "$entry_json" '. + {($key): $val}')
  done

  exec 3<&-

  # Build the final index
  local index_json
  index_json=$(jq -n \
    --argjson version 1 \
    --arg generated_by "doc-superpowers" \
    --arg generated_at "$now" \
    --arg build_commit "$build_commit" \
    --argjson docs "$docs_json" \
    '{
      version: $version,
      generated_by: $generated_by,
      generated_at: $generated_at,
      build_commit: $build_commit,
      docs: $docs
    }')

  mkdir -p "$docs_dir"
  echo "$index_json" > "$index_file"
}

cmd_check_freshness() {
  local index_file="docs/.doc-index.json"
  local filter_refs=()

  # Parse optional --code-refs arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --code-refs)
        shift
        while [[ $# -gt 0 && "$1" != --* ]]; do
          filter_refs+=("$1")
          shift
        done
        ;;
      *) shift ;;
    esac
  done

  if [ ! -f "$index_file" ]; then
    echo "ERROR: doc-index.json not found at $index_file. Run build-index first." >&2
    exit 1
  fi

  local index
  index=$(cat "$index_file")

  local checked_at
  checked_at=$(iso_now)
  local repo_head_val
  repo_head_val=$(repo_head)

  local count_current=0
  local count_stale=0
  local count_missing=0
  local count_deprecated=0

  local docs_out="{}"

  # Iterate over each doc path in the index
  local doc_paths
  doc_paths=$(echo "$index" | jq -r '.docs | keys[]')

  while IFS= read -r doc_path; do
    local entry
    entry=$(echo "$index" | jq --arg p "$doc_path" '.docs[$p]')

    local stored_status
    stored_status=$(echo "$entry" | jq -r '.status')

    local doc_type
    doc_type=$(echo "$entry" | jq -r '.doc_type')

    local last_verified
    last_verified=$(echo "$entry" | jq -r '.last_verified // empty')

    # Extract code_refs as array (bash 3.2 compatible)
    local code_refs_arr=()
    while IFS= read -r _ref; do
      [[ -n "$_ref" ]] && code_refs_arr+=("$_ref")
    done < <(echo "$entry" | jq -r '.code_refs[]' 2>/dev/null || true)

    # Apply --code-refs filter if provided (bidirectional prefix match)
    if [ ${#filter_refs[@]} -gt 0 ]; then
      local matched=0
      for filter_ref in "${filter_refs[@]}"; do
        for doc_ref in "${code_refs_arr[@]}"; do
          # Bidirectional prefix: filter is prefix of doc_ref OR doc_ref is prefix of filter
          if [[ "$doc_ref" == "$filter_ref"* || "$filter_ref" == "$doc_ref"* ]]; then
            matched=1
            break 2
          fi
        done
      done
      [ "$matched" -eq 0 ] && continue
    fi

    # Deprecated: preserve status, no freshness fields
    if [ "$stored_status" = "deprecated" ]; then
      count_deprecated=$((count_deprecated + 1))
      docs_out=$(echo "$docs_out" | jq \
        --arg p "$doc_path" \
        --arg status "deprecated" \
        --arg doc_type "$doc_type" \
        '. + {($p): {status: $status, doc_type: $doc_type}}')
      continue
    fi

    # Missing: doc file no longer exists
    if [ ! -f "$doc_path" ]; then
      count_missing=$((count_missing + 1))
      docs_out=$(echo "$docs_out" | jq \
        --arg p "$doc_path" \
        --arg status "missing" \
        --arg doc_type "$doc_type" \
        '. + {($p): {status: $status, doc_type: $doc_type}}')
      continue
    fi

    # Compute freshness via shared helper
    local freshness
    freshness=$(compute_freshness "$doc_path" "$entry")
    local status
    status=$(echo "$freshness" | jq -r '.status')

    if [ "$status" = "current" ]; then
      count_current=$((count_current + 1))
    else
      count_stale=$((count_stale + 1))
    fi

    # Add doc_type and last_verified to the freshness result
    local doc_entry
    doc_entry=$(echo "$freshness" | jq \
      --arg doc_type "$doc_type" \
      --arg last_verified "$last_verified" \
      '. + {doc_type: $doc_type, last_verified: $last_verified}')

    docs_out=$(echo "$docs_out" | jq \
      --arg p "$doc_path" \
      --argjson entry "$doc_entry" \
      '. + {($p): $entry}')

  done <<< "$doc_paths"

  # Detect untracked docs: .md files in docs/ not present in the index
  local untracked_docs="[]"
  local count_untracked=0
  while IFS= read -r md_file; do
    # Check if this file is in the index
    local in_index
    in_index=$(echo "$index" | jq --arg p "$md_file" '.docs | has($p)')
    if [ "$in_index" = "false" ]; then
      count_untracked=$((count_untracked + 1))
      untracked_docs=$(echo "$untracked_docs" | jq --arg p "$md_file" '. + [$p]')
    fi
  done < <(find docs -name '*.md' -not -path 'docs/archive/*' 2>/dev/null | sort)

  # Build final output
  jq -n \
    --arg checked_at "$checked_at" \
    --arg repo_head "$repo_head_val" \
    --argjson current "$count_current" \
    --argjson stale "$count_stale" \
    --argjson missing "$count_missing" \
    --argjson deprecated "$count_deprecated" \
    --argjson untracked "$count_untracked" \
    --argjson untracked_docs "$untracked_docs" \
    --argjson docs "$docs_out" \
    '{
      checked_at: $checked_at,
      repo_head: $repo_head,
      summary: {current: $current, stale: $stale, missing: $missing, deprecated: $deprecated, untracked: $untracked},
      untracked_docs: $untracked_docs,
      docs: $docs
    }'
}

cmd_update_index() {
  local index_file="docs/.doc-index.json"

  if [ ! -f "$index_file" ]; then
    echo "ERROR: doc-index.json not found at $index_file. Run build-index first." >&2
    exit 1
  fi

  if [ $# -eq 0 ]; then
    echo "ERROR: update-index requires at least one doc path argument." >&2
    exit 1
  fi

  local index
  index=$(cat "$index_file")
  local now
  now=$(iso_now)
  local refreshed=()

  for doc_path in "$@"; do
    # Verify path exists in index
    local exists
    exists=$(echo "$index" | jq --arg p "$doc_path" '.docs | has($p)')
    if [ "$exists" != "true" ]; then
      echo "ERROR: '$doc_path' not found in index. Use add-entry to add new docs." >&2
      exit 1
    fi

    # Check file exists on disk — don't silently set current with null hash
    if [ ! -f "$doc_path" ]; then
      echo "WARNING: '$doc_path' no longer exists on disk. Skipping. Use remove-entry or deprecate-entry to clean up." >&2
      continue
    fi

    # Re-hash the doc
    local content_hash_val
    content_hash_val="\"sha256:$(hash_file "$doc_path")\""

    # Re-query code_commit from code_refs (bash 3.2 compatible)
    local code_refs_arr=()
    while IFS= read -r _ref; do
      [[ -n "$_ref" ]] && code_refs_arr+=("$_ref")
    done < <(echo "$index" | jq -r --arg p "$doc_path" '.docs[$p].code_refs[]' 2>/dev/null || true)

    local code_commit=""
    if [ ${#code_refs_arr[@]} -gt 0 ]; then
      code_commit=$(git log -1 --format=%H -- "${code_refs_arr[@]}" 2>/dev/null || true)
    fi

    local code_commit_json
    if [ -n "$code_commit" ]; then
      code_commit_json="\"$code_commit\""
    else
      code_commit_json="null"
    fi

    # Update the entry: re-hash, re-query code_commit, set status=current, update last_verified
    # Preserve: replaces, superseded_by, doc_type, build_commit (top-level), code_refs
    index=$(echo "$index" | jq \
      --arg p "$doc_path" \
      --argjson content_hash "$content_hash_val" \
      --argjson code_commit "$code_commit_json" \
      --arg status "current" \
      --arg last_verified "$now" \
      '.docs[$p].content_hash = $content_hash
      | .docs[$p].code_commit = $code_commit
      | .docs[$p].status = $status
      | .docs[$p].last_verified = $last_verified')
    refreshed+=("$doc_path")
  done

  # Update generated_at (but NOT build_commit)
  index=$(echo "$index" | jq --arg generated_at "$now" '.generated_at = $generated_at')

  echo "$index" > "$index_file"

  # Output refreshed entries to stderr (informational, keeps stdout clean)
  local count=${#refreshed[@]}
  echo "Refreshed $count $([ "$count" -eq 1 ] && echo entry || echo entries):" >&2
  for doc_path in "${refreshed[@]}"; do
    echo "  $doc_path" >&2
  done
}

cmd_add_entry() {
  local index_file="docs/.doc-index.json"

  if [ ! -f "$index_file" ]; then
    echo "ERROR: doc-index.json not found at $index_file. Run build-index first." >&2
    exit 1
  fi

  local index
  index=$(cat "$index_file")
  local now
  now=$(iso_now)

  local count=0

  # Save stdin to fd 3, redirect fd 0 so subprocesses don't consume input
  exec 3<&0 0</dev/null

  while IFS= read -r line <&3 || [ -n "$line" ]; do
    [ -z "$line" ] && continue

    local doc_path code_refs_raw doc_type
    doc_path=$(echo "$line" | cut -d: -f1)
    code_refs_raw=$(echo "$line" | cut -d: -f2)
    doc_type=$(echo "$line" | cut -d: -f3)

    # Skip if already in index
    local exists
    exists=$(echo "$index" | jq --arg p "$doc_path" '.docs | has($p)')
    if [ "$exists" = "true" ]; then
      echo "SKIP: '$doc_path' already in index. Use update-index to refresh." >&2
      continue
    fi

    # Compute content hash
    local content_hash_val
    if [ -f "$doc_path" ]; then
      content_hash_val="\"sha256:$(hash_file "$doc_path")\""
    else
      content_hash_val="null"
    fi

    # Build code_refs JSON array
    local code_refs_json
    code_refs_json=$(echo "$code_refs_raw" | tr ',' '\n' | jq -R . | jq -s .)

    # Compute latest commit across code refs
    local code_commit=""
    IFS=',' read -ra refs <<< "$code_refs_raw"
    code_commit=$(git log -1 --format=%H -- "${refs[@]}" 2>/dev/null || true)

    # Build entry JSON
    local entry_json
    if [ -n "$code_commit" ]; then
      entry_json=$(jq -n \
        --argjson content_hash "$content_hash_val" \
        --argjson code_refs "$code_refs_json" \
        --arg code_commit "$code_commit" \
        --arg doc_type "$doc_type" \
        --arg last_verified "$now" \
        '{
          content_hash: $content_hash,
          code_refs: $code_refs,
          code_commit: $code_commit,
          doc_type: $doc_type,
          status: "current",
          replaces: null,
          superseded_by: null,
          last_verified: $last_verified
        }')
    else
      entry_json=$(jq -n \
        --argjson content_hash "$content_hash_val" \
        --argjson code_refs "$code_refs_json" \
        --arg doc_type "$doc_type" \
        --arg last_verified "$now" \
        '{
          content_hash: $content_hash,
          code_refs: $code_refs,
          code_commit: null,
          doc_type: $doc_type,
          status: "current",
          replaces: null,
          superseded_by: null,
          last_verified: $last_verified
        }')
    fi

    # Merge into index
    index=$(echo "$index" | jq --arg key "$doc_path" --argjson val "$entry_json" '.docs[$key] = $val')
    count=$((count + 1))
  done

  exec 3<&-

  # Update generated_at
  index=$(echo "$index" | jq --arg generated_at "$now" '.generated_at = $generated_at')

  echo "$index" > "$index_file"

  echo "Added $count $([ "$count" -eq 1 ] && echo entry || echo entries):" >&2
}

cmd_remove_entry() {
  local index_file="docs/.doc-index.json"

  if [ ! -f "$index_file" ]; then
    echo "ERROR: doc-index.json not found at $index_file. Run build-index first." >&2
    exit 1
  fi

  if [ $# -eq 0 ]; then
    echo "ERROR: remove-entry requires at least one doc path argument." >&2
    exit 1
  fi

  local index
  index=$(cat "$index_file")
  local now
  now=$(iso_now)
  local count=0

  for doc_path in "$@"; do
    local exists
    exists=$(echo "$index" | jq --arg p "$doc_path" '.docs | has($p)')
    if [ "$exists" != "true" ]; then
      echo "SKIP: '$doc_path' not found in index." >&2
      continue
    fi

    index=$(echo "$index" | jq --arg p "$doc_path" 'del(.docs[$p])')
    count=$((count + 1))
  done

  # Update generated_at
  index=$(echo "$index" | jq --arg generated_at "$now" '.generated_at = $generated_at')

  echo "$index" > "$index_file"

  echo "Removed $count $([ "$count" -eq 1 ] && echo entry || echo entries):" >&2
  for doc_path in "$@"; do
    echo "  $doc_path" >&2
  done
}

cmd_deprecate_entry() {
  local index_file="docs/.doc-index.json"

  if [ ! -f "$index_file" ]; then
    echo "ERROR: doc-index.json not found at $index_file. Run build-index first." >&2
    exit 1
  fi

  if [ $# -eq 0 ]; then
    echo "ERROR: deprecate-entry requires at least one doc path argument." >&2
    echo "Usage: deprecate-entry [--superseded-by <path>] <doc_path> [doc_path ...]" >&2
    exit 1
  fi

  # Parse optional --superseded-by flag
  local superseded_by="null"
  if [ "${1:-}" = "--superseded-by" ]; then
    shift
    if [ $# -eq 0 ]; then
      echo "ERROR: --superseded-by requires a path argument." >&2
      exit 1
    fi
    superseded_by="\"$1\""
    shift
  fi

  if [ $# -eq 0 ]; then
    echo "ERROR: no doc paths provided after flags." >&2
    exit 1
  fi

  local index
  index=$(cat "$index_file")
  local now
  now=$(iso_now)
  local count=0

  for doc_path in "$@"; do
    local exists
    exists=$(echo "$index" | jq --arg p "$doc_path" '.docs | has($p)')
    if [ "$exists" != "true" ]; then
      echo "SKIP: '$doc_path' not found in index." >&2
      continue
    fi

    index=$(echo "$index" | jq \
      --arg p "$doc_path" \
      --argjson superseded_by "$superseded_by" \
      --arg last_verified "$now" \
      '.docs[$p].status = "deprecated"
      | .docs[$p].superseded_by = $superseded_by
      | .docs[$p].last_verified = $last_verified')
    count=$((count + 1))
  done

  # Update generated_at
  index=$(echo "$index" | jq --arg generated_at "$now" '.generated_at = $generated_at')

  echo "$index" > "$index_file"

  echo "Deprecated $count $([ "$count" -eq 1 ] && echo entry || echo entries):" >&2
  for doc_path in "$@"; do
    echo "  $doc_path" >&2
  done
}

cmd_status() {
  local index_file="docs/.doc-index.json"

  if [ $# -eq 0 ]; then
    echo "ERROR: status requires a doc path argument." >&2
    exit 1
  fi

  local doc_path="$1"

  if [ ! -f "$index_file" ]; then
    echo "ERROR: doc-index.json not found at $index_file. Run build-index first." >&2
    exit 1
  fi

  local index
  index=$(cat "$index_file")

  # Verify path exists in index
  local exists
  exists=$(echo "$index" | jq --arg p "$doc_path" '.docs | has($p)')
  if [ "$exists" != "true" ]; then
    echo "ERROR: '$doc_path' not found in index." >&2
    exit 1
  fi

  local entry
  entry=$(echo "$index" | jq --arg p "$doc_path" '.docs[$p]')

  local stored_status
  stored_status=$(echo "$entry" | jq -r '.status')
  local doc_type
  doc_type=$(echo "$entry" | jq -r '.doc_type')
  local last_verified
  last_verified=$(echo "$entry" | jq -r '.last_verified // empty')

  # Deprecated: short-circuit
  if [ "$stored_status" = "deprecated" ]; then
    jq -n \
      --arg path "$doc_path" \
      --arg doc_type "$doc_type" \
      --arg status "deprecated" \
      --arg last_verified "$last_verified" \
      '{path: $path, doc_type: $doc_type, status: $status, last_verified: $last_verified}'
    return 0
  fi

  # Missing
  if [ ! -f "$doc_path" ]; then
    jq -n \
      --arg path "$doc_path" \
      --arg doc_type "$doc_type" \
      --arg status "missing" \
      '{path: $path, doc_type: $doc_type, status: $status}'
    return 0
  fi

  # Compute freshness via shared helper, add path/doc_type/last_verified
  local freshness
  freshness=$(compute_freshness "$doc_path" "$entry")

  echo "$freshness" | jq \
    --arg path "$doc_path" \
    --arg doc_type "$doc_type" \
    --arg last_verified "$last_verified" \
    '{path: $path} + . + {doc_type: $doc_type, last_verified: $last_verified}'
}

# --- Version management ---

# All files that carry a version string, with their jq path
VERSION_FILES=(
  "package.json:.version"
  "claude-code.json:.version"
  ".claude-plugin/plugin.json:.version"
  ".claude-plugin/marketplace.json:.metadata.version"
  ".cursor-plugin/plugin.json:.version"
  "gemini-extension.json:.version"
)

cmd_bump_version() {
  local new_version="${1:-}"
  if [[ -z "$new_version" ]]; then
    echo "ERROR: bump-version requires a version argument (e.g., 2.5.0)" >&2
    exit 1
  fi

  # Validate semver format
  if ! [[ "$new_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: invalid version format '$new_version' — expected MAJOR.MINOR.PATCH" >&2
    exit 1
  fi

  local updated=0

  for entry in "${VERSION_FILES[@]}"; do
    local file="${entry%%:*}"
    local jq_path="${entry#*:}"

    if [[ ! -f "$file" ]]; then
      echo "  skip: $file (not found)"
      continue
    fi

    local current
    current=$(jq -r "$jq_path // empty" "$file" 2>/dev/null)
    if [[ "$current" == "$new_version" ]]; then
      echo "  ok:   $file (already $new_version)"
      continue
    fi

    local tmp
    tmp=$(mktemp)
    jq "$jq_path = \"$new_version\"" "$file" > "$tmp" && mv "$tmp" "$file"
    echo "  bump: $file ($current → $new_version)"
    updated=$((updated + 1))
  done

  echo "Updated $updated file(s) to v$new_version"
}

cmd_check_version() {
  # Extract canonical version from RELEASE-NOTES.md
  local canonical
  canonical=$(grep -m 1 -o '## v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*' RELEASE-NOTES.md 2>/dev/null | sed 's/## v//')
  if [[ -z "$canonical" ]]; then
    echo "ERROR: could not extract version from RELEASE-NOTES.md" >&2
    exit 1
  fi

  local mismatched=0
  local checked=0

  echo "Canonical version (RELEASE-NOTES.md): v$canonical"

  for entry in "${VERSION_FILES[@]}"; do
    local file="${entry%%:*}"
    local jq_path="${entry#*:}"

    if [[ ! -f "$file" ]]; then
      continue
    fi

    local actual
    actual=$(jq -r "$jq_path // empty" "$file" 2>/dev/null)
    checked=$((checked + 1))

    if [[ "$actual" != "$canonical" ]]; then
      echo "  MISMATCH: $file has $actual (expected $canonical)"
      mismatched=$((mismatched + 1))
    else
      echo "  ok:       $file"
    fi
  done

  if [[ "$mismatched" -gt 0 ]]; then
    echo "FAIL: $mismatched/$checked file(s) have mismatched versions"
    echo "  Run: doc-tools.sh bump-version $canonical"
    exit 1
  fi

  echo "PASS: all $checked file(s) match v$canonical"
}

# --- Fragments subcommand ---

# Compute SHA-256 of bytes from line 3 onwards of a fragment file.
_fragment_payload_sha256() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo ""
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    tail -n +3 "$path" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    tail -n +3 "$path" | shasum -a 256 | awk '{print $1}'
  else
    echo "no sha256 tool available" >&2
    return 1
  fi
}

# Extract the line-2 hash from a fragment file (returns empty if missing).
_fragment_stored_hash() {
  local path="$1"
  sed -n '2p' "$path" \
    | grep -oE '^<!-- doc-superpowers:hash [a-f0-9]+ -->$' \
    | awk '{print $3}'
}

# Extract the integer N from a fragment filename "PR-<N>.md".
# Returns empty string if filename is not "PR-<digits>.md".
_fragment_pr_number() {
  local path="$1"
  local base
  base=$(basename "$path" .md)
  if [[ "$base" =~ ^PR-([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo ""
  fi
}

# Parse section headings from a fragment body (line 3 onwards).
# Emits one heading per line, with the leading "### " stripped (full heading text).
# Accepts any heading text (single or multi-word).
_fragment_section_headings() {
  local path="$1"
  tail -n +3 "$path" | grep -E '^###[[:space:]]+.+' | sed -E 's/^###[[:space:]]+//'
}

# Backward-compat shim used by cmd_fragments_list — emits unique section headings.
_fragment_section_names() {
  _fragment_section_headings "$1" | sort -u
}

cmd_fragments_list() {
  local dir="RELEASE-NOTES.next"
  if [[ ! -d "$dir" ]]; then
    echo "[]"
    return 0
  fi
  local out="[]"
  local found=0
  for path in "$dir"/PR-*.md; do
    [[ -f "$path" ]] || continue
    local n hash_stored hash_actual hash_valid sections_json
    n=$(_fragment_pr_number "$path")
    if [[ -z "$n" ]]; then
      echo "WARN: skipping non-numeric fragment filename: $path" >&2
      continue
    fi
    found=1
    hash_stored=$(_fragment_stored_hash "$path")
    hash_actual=$(_fragment_payload_sha256 "$path")
    if [[ "$hash_stored" = "$hash_actual" ]] && [[ -n "$hash_stored" ]]; then
      hash_valid="true"
    else
      hash_valid="false"
    fi
    sections_json=$(_fragment_section_names "$path" \
      | jq -R -s 'split("\n") | map(select(length > 0))')
    out=$(printf '%s' "$out" | jq \
      --argjson n "$n" \
      --arg path "$path" \
      --arg hash_stored "$hash_stored" \
      --arg hash_actual "$hash_actual" \
      --arg hash_valid "$hash_valid" \
      --argjson sections "$sections_json" \
      '. += [{pr_number: $n, path: $path, hash_stored: $hash_stored, hash_actual: $hash_actual, hash_valid: ($hash_valid == "true"), sections: $sections}]'
    )
  done
  if [[ "$found" -eq 0 ]]; then
    echo "[]"
    return 0
  fi
  printf '%s\n' "$out" | jq 'sort_by(.pr_number)'
}

cmd_fragments_validate() {
  local path="$1"
  if [[ -z "$path" ]]; then
    echo "Usage: $0 fragments validate <path>" >&2
    return 2
  fi
  if [[ ! -f "$path" ]]; then
    echo "ERROR: fragment not found: $path" >&2
    return 2
  fi
  local stored actual
  stored=$(_fragment_stored_hash "$path")
  actual=$(_fragment_payload_sha256 "$path")
  if [[ -z "$stored" ]]; then
    echo "ERROR: no hash marker on line 2 of $path" >&2
    return 1
  fi
  if [[ "$stored" = "$actual" ]]; then
    echo "valid: $path"
    return 0
  fi
  echo "drifted: $path (stored=$stored, actual=$actual)" >&2
  return 1
}

cmd_fragments_merge() {
  local range_start="$1" range_end="$2"
  local paths_out_file=""
  # Optional --paths-out=<file>: write one consumed-fragment path per line.
  # Lets callers (e.g., SKILL.md step 9) `git rm` only the fragments that were
  # actually merged, instead of globbing PR-*.md unconditionally.
  if [[ "${3:-}" == --paths-out=* ]]; then
    paths_out_file="${3#--paths-out=}"
    : > "$paths_out_file"
  fi
  if [[ -z "$range_start" ]] || [[ -z "$range_end" ]]; then
    echo "Usage: $0 fragments merge <range-start> <range-end> [--paths-out=<file>]" >&2
    return 2
  fi
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "ERROR: fragments merge must be run inside a git repo" >&2
    return 2
  fi
  local dir="RELEASE-NOTES.next"
  if [[ ! -d "$dir" ]]; then
    return 0  # Empty output is valid (no fragments)
  fi

  # Collect fragments whose introducing commit is in the range.
  local -a included_paths=()
  for path in "$dir"/PR-*.md; do
    [[ -f "$path" ]] || continue
    # Skip non-numeric PR filenames (defensive — see cmd_fragments_list).
    local n
    n=$(_fragment_pr_number "$path")
    if [[ -z "$n" ]]; then
      echo "WARN: skipping non-numeric fragment filename: $path" >&2
      continue
    fi
    # Find the commit that introduced this fragment (oldest commit touching it).
    local introduced
    introduced=$(git log --format="%H" --reverse -- "$path" 2>/dev/null | head -n 1)
    if [[ -z "$introduced" ]]; then
      # Untracked; skip with a warning.
      echo "WARN: $path is not tracked; skipping" >&2
      continue
    fi
    # Check if `introduced` is in `range_start..range_end` (exclusive of range_start).
    if git merge-base --is-ancestor "$introduced" "$range_end" 2>/dev/null \
       && ! git merge-base --is-ancestor "$introduced" "$range_start" 2>/dev/null; then
      included_paths+=("$path")
    fi
  done

  if [[ "${#included_paths[@]}" -eq 0 ]]; then
    return 0
  fi

  # Sort by integer PR number.
  local -a sorted
  # shellcheck disable=SC2207
  sorted=($(for p in "${included_paths[@]}"; do
    printf "%s\t%s\n" "$(_fragment_pr_number "$p")" "$p"
  done | sort -n -k1,1 | awk -F'\t' '{print $2}'))

  # Section storage: any heading is accepted. Canonical Keep-a-Changelog
  # sections emit in a fixed order; non-canonical sections emit after, in
  # first-seen order.
  local -a canonical_order=(Added Changed Deprecated Removed Fixed Security Dependencies)
  local -A is_canonical=()
  local s
  for s in "${canonical_order[@]}"; do is_canonical["$s"]=1; done

  local -A section_bodies=()
  local -a non_canonical_seen=()

  for path in "${sorted[@]}"; do
    # Validate hash; include drifted fragments anyway (human edits authoritative)
    # but warn on stderr.
    if ! cmd_fragments_validate "$path" >/dev/null 2>&1; then
      echo "WARN: including drifted fragment $path (human edits are authoritative)" >&2
    fi
    # Parse sections out of the fragment body (line 3 onwards). Accept any
    # heading text after "### " (single or multi-word).
    local current_section=""
    while IFS= read -r line; do
      if [[ "$line" =~ ^###[[:space:]]+(.+)$ ]]; then
        current_section="${BASH_REMATCH[1]}"
        # Track non-canonical headings in first-seen order.
        if [[ -z "${is_canonical[$current_section]:-}" ]]; then
          local already_seen=0
          local seen
          for seen in "${non_canonical_seen[@]}"; do
            if [[ "$seen" = "$current_section" ]]; then
              already_seen=1
              break
            fi
          done
          if [[ "$already_seen" -eq 0 ]]; then
            non_canonical_seen+=("$current_section")
          fi
        fi
        continue
      fi
      if [[ -n "$current_section" ]] && [[ -n "$line" ]]; then
        section_bodies[$current_section]+="${line}"$'\n'
      fi
    done < <(tail -n +3 "$path")

    if [[ -n "$paths_out_file" ]]; then
      printf '%s\n' "$path" >> "$paths_out_file"
    fi
  done

  # Emit canonical sections first (fixed order), then non-canonical (first-seen).
  # Dedupe bullets within each section, preserving first-occurrence order.
  _emit_section() {
    local section="$1"
    local body="${section_bodies[$section]:-}"
    if [[ -z "$body" ]]; then
      return 0
    fi
    local deduped
    deduped=$(printf '%s' "$body" | awk '!seen[$0]++')
    printf '### %s\n%s\n' "$section" "$deduped"
  }

  for s in "${canonical_order[@]}"; do
    _emit_section "$s"
  done
  for s in "${non_canonical_seen[@]}"; do
    _emit_section "$s"
  done
}

# --- `tools` subcommand: vendor/uninstall/status doc-tools.sh itself ---

# Source of truth: SCRIPT_DIR points at the directory containing the running
# script. Use that as the "plugin copy" — when this script lives in a plugin
# cache, the plugin copy is the one being executed; when it lives in
# .github/scripts/ (already-vendored), `tools install` becomes a no-op
# self-copy which is still valid.
_tools_plugin_source() {
  echo "$SCRIPT_DIR/doc-tools.sh"
}

_tools_plugin_helpers_dir() {
  # Helpers live under scripts/hooks/ci/doc-pr-release/ in the plugin source
  # tree. When the script has been vendored to .github/scripts/, there are no
  # helpers next to it — return empty so callers can skip gracefully.
  local candidate="$SCRIPT_DIR/hooks/ci/doc-pr-release"
  [[ -d "$candidate" ]] && echo "$candidate" || echo ""
}

cmd_tools() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    install)   _tools_install "$@" ;;
    uninstall) _tools_uninstall "$@" ;;
    status)    _tools_status "$@" ;;
    ""|--help) cat >&2 <<'EOF'
Usage:
  doc-tools.sh tools install   [--dest <path>] [--with-helpers]
  doc-tools.sh tools uninstall [--dest <path>]
  doc-tools.sh tools status    [--dest <path>]

--dest defaults to .github/scripts (project-relative).
--with-helpers also installs doc-pr-release/*.sh + RELEASE-NOTES.next/README.md
EOF
      exit 1 ;;
    *) echo "Unknown tools sub-command: $sub" >&2; exit 2 ;;
  esac
}

_tools_install() {
  local dest=".github/scripts"
  local with_helpers=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dest)
        [[ $# -lt 2 ]] && { echo "ERROR: --dest requires a value" >&2; exit 1; }
        dest="$2"; shift 2 ;;
      --with-helpers) with_helpers=true; shift ;;
      *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
  done

  local src
  src="$(_tools_plugin_source)"
  if [[ ! -f "$src" ]]; then
    echo "ERROR: source doc-tools.sh not found at $src" >&2
    exit 1
  fi

  mkdir -p "$dest"
  cp "$src" "$dest/doc-tools.sh"
  chmod +x "$dest/doc-tools.sh"
  echo "Installed doc-tools.sh → $dest/doc-tools.sh"

  if [[ "$with_helpers" == "true" ]]; then
    local helpers_src
    helpers_src="$(_tools_plugin_helpers_dir)"
    if [[ -z "$helpers_src" ]]; then
      echo "WARN: --with-helpers requested but plugin helpers dir not found." >&2
      echo "      (Are you running from a vendored copy? Re-run from plugin source.)" >&2
    else
      mkdir -p "$dest/doc-pr-release"
      local helpers_installed=0
      for helper in "$helpers_src"/*.sh; do
        [[ -f "$helper" ]] || continue
        cp "$helper" "$dest/doc-pr-release/$(basename "$helper")"
        chmod +x "$dest/doc-pr-release/$(basename "$helper")"
        helpers_installed=$((helpers_installed + 1))
      done
      echo "Installed $helpers_installed doc-pr-release helpers → $dest/doc-pr-release/"

      # RELEASE-NOTES.next/README.md — never overwrite (user may have edits).
      if [[ -f "$helpers_src/RELEASE-NOTES.next.README.md" ]] \
         && [[ ! -f "RELEASE-NOTES.next/README.md" ]]; then
        mkdir -p RELEASE-NOTES.next
        cp "$helpers_src/RELEASE-NOTES.next.README.md" \
           "RELEASE-NOTES.next/README.md"
        echo "Created RELEASE-NOTES.next/README.md (fragment format spec)"
      fi
    fi
  fi
}

_tools_uninstall() {
  local dest=".github/scripts"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dest)
        [[ $# -lt 2 ]] && { echo "ERROR: --dest requires a value" >&2; exit 1; }
        dest="$2"; shift 2 ;;
      *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
  done

  local removed=0
  if [[ -f "$dest/doc-tools.sh" ]]; then
    rm "$dest/doc-tools.sh"
    echo "Removed $dest/doc-tools.sh"
    removed=$((removed + 1))
  fi

  # Best-effort helper cleanup: only remove if files match the plugin copy
  # byte-for-byte (no local edits). The `RELEASE-NOTES.next/README.md` is
  # intentionally NOT removed — it may have user-authored fragment edits.
  local helpers_src
  helpers_src="$(_tools_plugin_helpers_dir)"
  if [[ -d "$dest/doc-pr-release" ]] && [[ -n "$helpers_src" ]]; then
    local has_local_edits=false
    for installed in "$dest/doc-pr-release"/*.sh; do
      [[ -f "$installed" ]] || continue
      local plugin_copy="$helpers_src/$(basename "$installed")"
      if [[ ! -f "$plugin_copy" ]] \
         || ! cmp -s "$plugin_copy" "$installed"; then
        has_local_edits=true
        break
      fi
    done
    if [[ "$has_local_edits" == "true" ]]; then
      echo "Kept $dest/doc-pr-release/ (contains local edits or unknown files)"
    else
      rm -rf "$dest/doc-pr-release"
      echo "Removed $dest/doc-pr-release/"
      removed=$((removed + 1))
    fi
  fi

  # Clean up empty parent dir.
  rmdir "$dest" 2>/dev/null || true

  if [[ "$removed" -eq 0 ]]; then
    echo "Nothing to uninstall at $dest"
  fi
  return 0
}

_tools_status() {
  local dest=".github/scripts"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dest)
        [[ $# -lt 2 ]] && { echo "ERROR: --dest requires a value" >&2; exit 1; }
        dest="$2"; shift 2 ;;
      *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
  done

  local installed="$dest/doc-tools.sh"
  local plugin
  plugin="$(_tools_plugin_source)"

  if [[ ! -f "$installed" ]]; then
    echo "doc-tools.sh: not installed at $dest"
    return 0
  fi

  if cmp -s "$plugin" "$installed"; then
    echo "doc-tools.sh: installed at $dest (matches plugin v$( _tools_extract_version ))"
  else
    echo "doc-tools.sh: installed at $dest (DRIFTED from plugin source)"
  fi

  # Helper-presence summary.
  if [[ -d "$dest/doc-pr-release" ]]; then
    local helper_count
    helper_count=$(find "$dest/doc-pr-release" -maxdepth 1 -name '*.sh' 2>/dev/null | wc -l | tr -d ' ')
    echo "doc-pr-release helpers: $helper_count installed at $dest/doc-pr-release/"
  else
    echo "doc-pr-release helpers: not installed at $dest"
  fi
  if [[ -f "RELEASE-NOTES.next/README.md" ]]; then
    echo "RELEASE-NOTES.next/README.md: present"
  else
    echo "RELEASE-NOTES.next/README.md: not present"
  fi
}

# Best-effort: parse version from a sibling RELEASE-NOTES.md if present.
_tools_extract_version() {
  local relnotes
  relnotes="$(dirname "$SCRIPT_DIR")/RELEASE-NOTES.md"
  if [[ -f "$relnotes" ]]; then
    grep -m 1 -o '## v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*' "$relnotes" \
      | sed 's/## v//' || echo "unknown"
  else
    echo "unknown"
  fi
}

# --- Main ---

check_deps

case "${1:-}" in
  build-index)      shift; cmd_build_index "$@" ;;
  check-freshness)  shift; cmd_check_freshness "$@" ;;
  update-index)     shift; cmd_update_index "$@" ;;
  add-entry)        shift; cmd_add_entry "$@" ;;
  remove-entry)     shift; cmd_remove_entry "$@" ;;
  deprecate-entry)  shift; cmd_deprecate_entry "$@" ;;
  status)           shift; cmd_status "$@" ;;
  bump-version)     shift; cmd_bump_version "$@" ;;
  check-version)    shift; cmd_check_version "$@" ;;
  fragments)
    shift
    case "${1:-}" in
      list)
        cmd_fragments_list
        ;;
      validate)
        cmd_fragments_validate "${2:-}"
        ;;
      merge)
        cmd_fragments_merge "${2:-}" "${3:-}" "${4:-}"
        ;;
      *)
        echo "Usage: $0 fragments {list|validate <path>|merge <range-start> <range-end> [--paths-out=<file>]}" >&2
        exit 2
        ;;
    esac
    ;;
  tools)            shift; cmd_tools "$@" ;;
  --help|"")        usage ;;
  *)                usage ;;
esac
