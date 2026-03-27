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
  --help|"")        usage ;;
  *)                usage ;;
esac
