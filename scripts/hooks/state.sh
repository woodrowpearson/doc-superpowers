#!/usr/bin/env bash
# doc-superpowers state tracking — shared by install.sh
#
# State file: .claude/doc-superpowers/installed.json (project-relative,
# COMMITTED to the repo so install choices persist across contributors).
#
# Schema:
# {
#   "schema_version": 1,
#   "tiers": {
#     "ci": {
#       "workflows": {
#         "doc-freshness-pr": { "state": "installed",   "installed_at": "..." },
#         "doc-freshness-schedule": { "state": "uninstalled",
#                                     "uninstalled_at": "...",
#                                     "intentional": true }
#       },
#       "tools":   { "state": "installed", "dest": ".github/scripts", "installed_at": "..." },
#       "helpers": { "state": "installed", "installed_at": "..." }
#     }
#   }
# }
#
# Behavior contract:
#   - First install on a repo with no state file → infer from filesystem.
#   - Subsequent install with no --workflows flag → SKIP workflows whose
#     state is "uninstalled" with intentional:true.
#   - uninstall --ci → marks as intentional:true.
#   - uninstall --ci --transient → marks as intentional:false.
#   - --force on install → bypass the state-respect check.
#   - Malformed state file → fall back to filesystem inference + warn.

# shellcheck disable=SC2034
STATE_FILE=".claude/doc-superpowers/installed.json"
STATE_SCHEMA_VERSION=1

# Canonical list of workflow names (without .yml extension). Single source
# of truth — referenced by install_ci, uninstall_ci, and state code.
state_known_workflows() {
  cat <<'EOF'
doc-freshness-pr
doc-freshness-schedule
doc-index-update
doc-audit-update
doc-review-pr
doc-release
doc-spec-verify
doc-pr-full-cycle
doc-pr-release
EOF
}

# True iff the named workflow exists in the canonical list.
state_is_known_workflow() {
  local name="$1"
  state_known_workflows | grep -qx -- "$name"
}

# Emit ISO-8601 UTC timestamp.
state_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Echo state file path (kept centralized so tests can override).
state_file_path() {
  echo "${DOC_SP_STATE_FILE:-$STATE_FILE}"
}

# True iff state file exists AND parses as JSON.
# Side-effect: emits a one-line warning on stderr if file exists but is malformed.
state_is_valid() {
  local f
  f="$(state_file_path)"
  [[ -f "$f" ]] || return 1
  if ! jq -e '.' "$f" >/dev/null 2>&1; then
    echo "WARN: $f is malformed; falling back to filesystem inference" >&2
    return 1
  fi
  return 0
}

# Bootstrap: create the state file by inferring from filesystem.
# Any workflow file that is doc-superpowers-managed (per WORKFLOW_MARKER) at
# .github/workflows/<name>.yml → marked "installed". Anything else → omitted
# (treated as "never-installed").
#
# Requires: is_doc_superpowers_workflow() to be defined by caller (install.sh).
state_bootstrap() {
  local f
  f="$(state_file_path)"
  mkdir -p "$(dirname "$f")"
  local now
  now="$(state_now)"

  local state_json
  state_json=$(jq -n --arg sv "$STATE_SCHEMA_VERSION" \
    '{schema_version: ($sv|tonumber), tiers: {ci: {workflows: {}}}}')

  local name dest
  while IFS= read -r name; do
    dest=".github/workflows/${name}.yml"
    if is_doc_superpowers_workflow "$dest" 2>/dev/null; then
      state_json=$(echo "$state_json" | jq --arg n "$name" --arg t "$now" \
        '.tiers.ci.workflows[$n] = {state:"installed", installed_at:$t}')
    fi
  done < <(state_known_workflows)

  # Tools + helpers presence.
  if [[ -f ".github/scripts/doc-tools.sh" ]]; then
    state_json=$(echo "$state_json" | jq --arg t "$now" \
      '.tiers.ci.tools = {state:"installed", dest:".github/scripts", installed_at:$t}')
  fi
  if [[ -d ".github/scripts/doc-pr-release" ]]; then
    state_json=$(echo "$state_json" | jq --arg t "$now" \
      '.tiers.ci.helpers = {state:"installed", installed_at:$t}')
  fi

  state_atomic_write "$state_json"
}

# Atomic write via tmp + mv.
state_atomic_write() {
  local payload="$1"
  local f tmp
  f="$(state_file_path)"
  mkdir -p "$(dirname "$f")"
  tmp="$(mktemp "${f}.XXXXXX")"
  echo "$payload" | jq '.' > "$tmp"
  mv "$tmp" "$f"
}

# Query: should this workflow be skipped on a no-flag install?
# Returns 0 (yes-skip) if state.tiers.ci.workflows[name].state == "uninstalled"
# AND intentional == true. Otherwise 1.
#
# If state file is absent/malformed, returns 1 (don't skip — i.e. install).
state_should_skip_workflow() {
  local name="$1"
  state_is_valid || return 1
  local f
  f="$(state_file_path)"
  local result
  result=$(jq -r --arg n "$name" '
    .tiers.ci.workflows[$n] // {} |
    if (.state == "uninstalled") and (.intentional == true) then "skip" else "go" end
  ' "$f")
  [[ "$result" == "skip" ]]
}

# Mark a workflow installed (with installed_at timestamp).
state_mark_workflow_installed() {
  local name="$1"
  local f
  f="$(state_file_path)"
  if ! state_is_valid; then
    state_atomic_write "$(jq -n --arg sv "$STATE_SCHEMA_VERSION" \
      '{schema_version: ($sv|tonumber), tiers: {ci: {workflows: {}}}}')"
  fi
  local now state_json
  now="$(state_now)"
  state_json=$(jq --arg n "$name" --arg t "$now" \
    '.tiers.ci.workflows[$n] = {state:"installed", installed_at:$t}' "$f")
  state_atomic_write "$state_json"
}

# Mark a workflow uninstalled. $2 is "true" or "false" for intentional flag.
state_mark_workflow_uninstalled() {
  local name="$1"
  local intentional="$2"  # "true" or "false"
  local f
  f="$(state_file_path)"
  if ! state_is_valid; then
    state_atomic_write "$(jq -n --arg sv "$STATE_SCHEMA_VERSION" \
      '{schema_version: ($sv|tonumber), tiers: {ci: {workflows: {}}}}')"
  fi
  local now state_json
  now="$(state_now)"
  state_json=$(jq --arg n "$name" --arg t "$now" --argjson i "$intentional" \
    '.tiers.ci.workflows[$n] = {state:"uninstalled", uninstalled_at:$t, intentional:$i}' "$f")
  state_atomic_write "$state_json"
}

# Mark tools / helpers state. $1: "tools" or "helpers". $2: "installed" or "uninstalled". $3: optional dest for tools.
state_mark_component() {
  local component="$1"   # "tools" or "helpers"
  local action="$2"      # "installed" or "uninstalled"
  local dest="${3:-}"    # optional, only meaningful for tools
  local f
  f="$(state_file_path)"
  if ! state_is_valid; then
    state_atomic_write "$(jq -n --arg sv "$STATE_SCHEMA_VERSION" \
      '{schema_version: ($sv|tonumber), tiers: {ci: {workflows: {}}}}')"
  fi
  local now state_json
  now="$(state_now)"
  if [[ "$action" == "installed" ]]; then
    if [[ -n "$dest" ]]; then
      state_json=$(jq --arg c "$component" --arg d "$dest" --arg t "$now" \
        '.tiers.ci[$c] = {state:"installed", dest:$d, installed_at:$t}' "$f")
    else
      state_json=$(jq --arg c "$component" --arg t "$now" \
        '.tiers.ci[$c] = {state:"installed", installed_at:$t}' "$f")
    fi
  else
    state_json=$(jq --arg c "$component" --arg t "$now" \
      '.tiers.ci[$c] = {state:"uninstalled", uninstalled_at:$t}' "$f")
  fi
  state_atomic_write "$state_json"
}

# Dump state to stdout in a human-readable form (for `status --ci` + `tools status` extension).
state_dump_ci() {
  if ! state_is_valid; then
    echo "  (no state file — install state is filesystem-inferred only)"
    return 0
  fi
  local f
  f="$(state_file_path)"
  jq -r '
    .tiers.ci.workflows // {} | to_entries[] |
    "  \(.key): \(.value.state)" +
      (if .value.intentional == true then " (intentional)" else "" end)
  ' "$f"
}
