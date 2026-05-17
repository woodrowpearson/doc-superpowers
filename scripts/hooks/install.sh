#!/usr/bin/env bash
set -euo pipefail

# doc-superpowers hooks installer
# Usage: install.sh <install|uninstall|status> [--git] [--claude] [--ci] [--all]
#        install.sh install [--base-branch NAME] [--cron EXPR] [--ci-strict]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOC_TOOLS="$SKILL_DIR/scripts/doc-tools.sh"
MARKER="doc-superpowers hook v1"
WORKFLOW_MARKER="doc-superpowers workflow v1"
DATE=$(date +%Y-%m-%d)

# Detect version from RELEASE-NOTES.md
VERSION=$(grep -m 1 -o '## v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*' "$SKILL_DIR/RELEASE-NOTES.md" | sed 's/## v//')
if [[ -z "$VERSION" || ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  VERSION="2.0.0"
fi

# Default CI parameters
BASE_BRANCH="main"
CRON_SCHEDULE="0 9 * * 1"
CI_STRICT="false"

# Granular CI install (v2.12.0+):
#   WORKFLOWS_FILTER  — "" (default = "all"), "all", "none", or csv of names (no .yml).
#   HELPERS_FLAG      — "true" (default) or "false".
#   FORCE_FLAG        — "true" bypasses state-respect (re-installs prior-uninstalled).
#   TRANSIENT_FLAG    — "true" on uninstall marks intentional:false.
WORKFLOWS_FILTER=""
HELPERS_FLAG="true"
FORCE_FLAG="false"
TRANSIENT_FLAG="false"

# Source state-tracking helpers (must come AFTER WORKFLOW_MARKER def for
# is_doc_superpowers_workflow, but state.sh uses caller-defined helpers so
# we can source here.)
# shellcheck source=scripts/hooks/state.sh
source "$SCRIPT_DIR/state.sh"

# --- Usage ---

usage() {
  cat <<EOF
doc-superpowers hooks installer

Usage:
  install.sh install [--git] [--claude] [--ci] [--all]
  install.sh uninstall [--git] [--claude] [--ci] [--all]
  install.sh status

Tier flags:
  --git      Git hooks (pre-commit, post-merge, post-checkout, prepare-commit-msg, pre-push)
  --claude   Claude Code hooks (pre-commit gate, post-commit sync, session summary)
  --ci       CI/CD workflows (PR check, weekly audit, index update)
  --all      All tiers

CI options (used with --ci):
  --base-branch NAME       Target branch (default: main)
  --cron EXPR              Schedule cron expression (default: 0 9 * * 1)
  --ci-strict              Make PR check fail on stale docs
  --workflows=<csv|all|none>
                           Granular workflow selection. "all" (default) installs
                           every template; "none" skips workflows but still
                           vendors doc-tools.sh; a CSV picks specific workflows
                           by basename (no .yml). Unknown names error out.
  --helpers=<true|false>   Install doc-pr-release helpers (default: true).
                           No effect if doc-pr-release workflow isn't installed.
  --force                  Bypass state-respect — re-install workflows that were
                           previously uninstalled with intentional:true.

CI options (used with uninstall --ci):
  --transient              Mark uninstall as transient (intentional:false) so
                           the next plain install --ci re-installs them.

Known workflow names (for --workflows=):
  doc-freshness-pr, doc-freshness-schedule, doc-index-update,
  doc-audit-update, doc-review-pr, doc-release, doc-spec-verify,
  doc-pr-full-cycle, doc-pr-release
EOF
  exit 1
}

# --- Helpers ---

is_doc_superpowers_hook() {
  local file="$1"
  [[ -f "$file" ]] && head -5 "$file" | grep -q "$MARKER"
}

is_doc_superpowers_workflow() {
  local file="$1"
  [[ -f "$file" ]] && head -5 "$file" | grep -q "$WORKFLOW_MARKER"
}

# --- Git tier ---

# Resolve the hooks directory: core.hooksPath > .githooks/ > .git/hooks/
resolve_hooks_dir() {
  local custom_path
  custom_path=$(git config core.hooksPath 2>/dev/null || true)
  if [[ -n "$custom_path" ]]; then
    echo "$custom_path"
  elif [[ -d ".githooks" ]]; then
    echo ".githooks"
  else
    echo ".git/hooks"
  fi
}

install_git() {
  if [[ ! -d ".git" ]]; then
    echo "ERROR: not a git repo (no .git/ directory)" >&2
    return 1
  fi

  local hooks_dir
  hooks_dir=$(resolve_hooks_dir)
  mkdir -p "$hooks_dir"
  local installed=0 skipped=0

  echo "  Hooks directory: $hooks_dir"

  for hook_name in pre-commit post-merge post-checkout prepare-commit-msg pre-push; do
    local hook_src="$SCRIPT_DIR/git/$hook_name"
    [[ -f "$hook_src" ]] || continue
    local hook_dest="$hooks_dir/$hook_name"

    if [[ -f "$hook_dest" ]] && ! is_doc_superpowers_hook "$hook_dest"; then
      # Check if already integrated via source line
      if grep -q "doc-superpowers" "$hook_dest" 2>/dev/null; then
        skipped=$((skipped + 1))
        continue
      fi
      # Copy hook script locally so integration survives skill reinstall
      local local_hook="$hooks_dir/.doc-superpowers-$hook_name"
      sed -e "s|__DOC_TOOLS_PATH__|$DOC_TOOLS|g" -e "s|__INSTALL_DATE__|$DATE|g" "$hook_src" > "$local_hook"
      chmod +x "$local_hook"
      # Auto-integrate: use begin/end markers for clean uninstall, dirname $0 for portability
      local tmpblock
      tmpblock=$(mktemp)
      cat > "$tmpblock" <<INTEGRATION_EOF
# doc-superpowers:begin
DOC_SP_HOOK="\$(dirname "\$0")/.doc-superpowers-$hook_name"
if [[ -f "\$DOC_SP_HOOK" ]]; then
    bash "\$DOC_SP_HOOK" 2>/dev/null || true
fi
# doc-superpowers:end
INTEGRATION_EOF
      if grep -q '^exit 0' "$hook_dest"; then
        # Insert before final exit 0
        local tmpfile
        tmpfile=$(mktemp)
        while IFS= read -r line || [[ -n "$line" ]]; do
          if [[ "$line" == "exit 0"* ]]; then
            cat "$tmpblock" >> "$tmpfile"
            echo "" >> "$tmpfile"
          fi
          printf '%s\n' "$line" >> "$tmpfile"
        done < "$hook_dest"
        mv "$tmpfile" "$hook_dest"
      else
        printf '\n' >> "$hook_dest"
        cat "$tmpblock" >> "$hook_dest"
      fi
      rm -f "$tmpblock"
      chmod +x "$hook_dest"
      echo "  Integrated $hook_name into existing hook"
      installed=$((installed + 1))
      continue
    fi

    # Copy with DOC_TOOLS path substituted
    sed -e "s|__DOC_TOOLS_PATH__|$DOC_TOOLS|g" -e "s|__INSTALL_DATE__|$DATE|g" "$hook_src" > "$hook_dest"
    chmod +x "$hook_dest"
    installed=$((installed + 1))
  done

  # Register custom merge driver for doc-index.json (auto-resolves timestamp conflicts)
  local merge_driver="$SKILL_DIR/scripts/merge-doc-index.sh"
  if [[ -f "$merge_driver" ]]; then
    git config --local merge.doc-index.name "doc-superpowers index merger"
    git config --local merge.doc-index.driver "$merge_driver %O %A %B"

    # Add .gitattributes entry if not already present
    local gitattributes=".gitattributes"
    if ! grep -q 'merge=doc-index' "$gitattributes" 2>/dev/null; then
      # Add blank separator only if file exists and is non-empty
      if [[ -s "$gitattributes" ]]; then
        echo "" >> "$gitattributes"
      fi
      echo "# doc-superpowers: auto-resolve doc-index.json merge conflicts" >> "$gitattributes"
      echo "docs/.doc-index.json merge=doc-index" >> "$gitattributes"
      echo "  Added merge driver to .gitattributes"
    fi
    echo "  Registered merge driver: doc-index"
  fi

  echo "Git hooks: $installed installed, $skipped skipped (existing)"
}

uninstall_git() {
  local hooks_dir
  hooks_dir=$(resolve_hooks_dir)

  if [[ ! -d "$hooks_dir" ]]; then
    echo "Git hooks: nothing to uninstall"
    return 0
  fi

  local removed=0
  for hook_name in pre-commit post-merge post-checkout prepare-commit-msg pre-push; do
    local hook_dest="$hooks_dir/$hook_name"
    if is_doc_superpowers_hook "$hook_dest"; then
      rm "$hook_dest"
      removed=$((removed + 1))
    elif [[ -f "$hook_dest" ]] && grep -q "doc-superpowers" "$hook_dest" 2>/dev/null; then
      # Remove source-integrated block (between begin/end markers) and legacy single-line patterns
      sed -i.bak '/# doc-superpowers:begin/,/# doc-superpowers:end/d;/# doc-superpowers/d;/DOC_SP_HOOK=/d;/bash.*DOC_SP_HOOK/d;/source.*DOC_SP_HOOK/d' "$hook_dest"
      # Squeeze consecutive blank lines left by marker removal
      sed -i.bak '/^$/N;/^\n$/d' "$hook_dest"
      rm -f "$hook_dest.bak"
      # Remove local hook copy
      rm -f "$hooks_dir/.doc-superpowers-$hook_name"
      removed=$((removed + 1))
    fi
  done

  # Unregister merge driver
  if git config --local --get merge.doc-index.driver &>/dev/null; then
    git config --local --unset merge.doc-index.name 2>/dev/null || true
    git config --local --unset merge.doc-index.driver 2>/dev/null || true
    echo "  Unregistered merge driver: doc-index"
  fi
  # Remove .gitattributes entry
  if grep -q 'merge=doc-index' ".gitattributes" 2>/dev/null; then
    sed -i.bak '/# doc-superpowers: auto-resolve doc-index/d;/docs\/.doc-index.json merge=doc-index/d' ".gitattributes"
    # Remove trailing blank lines
    sed -i.bak -e :a -e '/^\n*$/{$d;N;ba' -e '}' ".gitattributes"
    rm -f ".gitattributes.bak"
    echo "  Removed merge driver from .gitattributes"
  fi

  echo "Git hooks: $removed removed (from $hooks_dir)"
}

status_git() {
  local hooks_dir
  hooks_dir=$(resolve_hooks_dir)
  echo "Git Hooks (dir: $hooks_dir):"
  for hook_name in pre-commit post-merge post-checkout prepare-commit-msg pre-push; do
    local hook_dest="$hooks_dir/$hook_name"
    if is_doc_superpowers_hook "$hook_dest" 2>/dev/null; then
      local install_date
      install_date=$(head -3 "$hook_dest" | sed -n 's/.*installed \([0-9-]*\).*/\1/p')
      install_date="${install_date:-unknown}"
      printf "  ✓ %-22s installed %s\n" "$hook_name" "$install_date"
    elif [[ -f "$hook_dest" ]] && grep -q "doc-superpowers" "$hook_dest" 2>/dev/null; then
      printf "  ✓ %-22s integrated (source)\n" "$hook_name"
    else
      printf "  ✗ %-22s not installed\n" "$hook_name"
    fi
  done

  # Merge driver status
  if git config --local --get merge.doc-index.driver &>/dev/null; then
    local driver_path
    driver_path=$(git config --local --get merge.doc-index.driver | awk '{print $1}')
    if [[ -f "$driver_path" ]]; then
      printf "  ✓ %-22s registered\n" "merge-driver"
    else
      printf "  ⚠ %-22s registered but script missing: %s\n" "merge-driver" "$driver_path"
    fi
  else
    printf "  ✗ %-22s not registered\n" "merge-driver"
  fi
  if grep -q 'merge=doc-index' ".gitattributes" 2>/dev/null; then
    printf "  ✓ %-22s configured\n" ".gitattributes"
  else
    printf "  ✗ %-22s not configured\n" ".gitattributes"
  fi
}

# --- Claude tier ---

install_claude() {
  mkdir -p .claude

  # Copy hook scripts to project-local directory (like git tier copies to .git/hooks/)
  # This avoids absolute paths that break on skill reinstall
  local hooks_dir=".claude/hooks/doc-superpowers"
  mkdir -p "$hooks_dir"

  for hook_src in "$SCRIPT_DIR/claude/"*; do
    local hook_name
    hook_name=$(basename "$hook_src")
    sed -e "s|__DOC_TOOLS_PATH__|$DOC_TOOLS|g" -e "s|__INSTALL_DATE__|$DATE|g" "$hook_src" > "$hooks_dir/$hook_name"
    chmod +x "$hooks_dir/$hook_name"
  done

  # Register hooks in settings.local.json using relative paths
  local settings_file=".claude/settings.local.json"
  local settings="{}"

  if [[ -f "$settings_file" ]]; then
    settings=$(cat "$settings_file")
  fi

  local pre_commit_cmd="$hooks_dir/pre-commit-gate.sh"
  local post_commit_cmd="$hooks_dir/post-commit-sync.sh"
  local session_cmd="$hooks_dir/session-summary.sh"

  # Build new hook entries using Claude Code's required format:
  # Each event has an array of matcher objects, each with a "hooks" array of command objects
  # Wrap commands with git-root cd so hooks work from any subdirectory
  local wrap_prefix='cd "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null && exec '
  local pre_tool_entry post_tool_entry stop_entry
  pre_tool_entry=$(jq -n --arg cmd "bash -c '${wrap_prefix}${pre_commit_cmd}'" \
    '{"matcher":"Bash","hooks":[{"type":"command","command":$cmd,"timeout":10}]}')
  post_tool_entry=$(jq -n --arg cmd "bash -c '${wrap_prefix}${post_commit_cmd}'" \
    '{"matcher":"Bash","hooks":[{"type":"command","command":$cmd,"timeout":10}]}')
  stop_entry=$(jq -n --arg cmd "bash -c '${wrap_prefix}${session_cmd}'" \
    '{"matcher":"","hooks":[{"type":"command","command":$cmd,"timeout":10}]}')


  # Deep merge: preserve existing hooks, append ours
  # Filter out any existing doc-superpowers entries by checking nested hooks[].command
  settings=$(echo "$settings" | jq --argjson pte "$pre_tool_entry" --argjson pote "$post_tool_entry" --argjson se "$stop_entry" '
    # Remove any existing doc-superpowers entries first (check nested .hooks[].command)
    .hooks.PreToolUse = ([(.hooks.PreToolUse // [])[] | select(any(.hooks[]?; .command | contains("doc-superpowers")) | not)] + [$pte]) |
    .hooks.PostToolUse = ([(.hooks.PostToolUse // [])[] | select(any(.hooks[]?; .command | contains("doc-superpowers")) | not)] + [$pote]) |
    .hooks.Stop = ([(.hooks.Stop // [])[] | select(any(.hooks[]?; .command | contains("doc-superpowers")) | not)] + [$se])
  ')

  echo "$settings" | jq '.' > "$settings_file"
  echo "Claude Code hooks: 3 installed (pre-commit-gate, post-commit-sync, session-summary)"
  echo "  Scripts copied to $hooks_dir/"
  echo "  Settings written to $settings_file"
}

uninstall_claude() {
  local settings_file=".claude/settings.local.json"
  local hooks_dir=".claude/hooks/doc-superpowers"

  if [[ ! -f "$settings_file" ]] && [[ ! -d "$hooks_dir" ]]; then
    echo "Claude Code hooks: nothing to uninstall"
    return 0
  fi

  # Remove hook entries from settings
  if [[ -f "$settings_file" ]]; then
    local settings
    settings=$(cat "$settings_file")

    settings=$(echo "$settings" | jq '
      .hooks.PreToolUse = [(.hooks.PreToolUse // [])[] | select(any(.hooks[]?; .command | contains("doc-superpowers")) | not)] |
      .hooks.PostToolUse = [(.hooks.PostToolUse // [])[] | select(any(.hooks[]?; .command | contains("doc-superpowers")) | not)] |
      .hooks.Stop = [(.hooks.Stop // [])[] | select(any(.hooks[]?; .command | contains("doc-superpowers")) | not)] |
      # Clean up empty arrays
      if (.hooks.PreToolUse | length) == 0 then del(.hooks.PreToolUse) else . end |
      if (.hooks.PostToolUse | length) == 0 then del(.hooks.PostToolUse) else . end |
      if (.hooks.Stop | length) == 0 then del(.hooks.Stop) else . end |
      if (.hooks | length) == 0 then del(.hooks) else . end
    ')

    echo "$settings" | jq '.' > "$settings_file"
  fi

  # Remove copied hook scripts
  if [[ -d "$hooks_dir" ]]; then
    rm -rf "$hooks_dir"
    # Clean up empty parent if no other hook dirs remain
    rmdir .claude/hooks 2>/dev/null || true
  fi

  echo "Claude Code hooks: removed"
}

status_claude() {
  echo "Claude Code Hooks:"
  local settings_file=".claude/settings.local.json"
  local hooks_dir=".claude/hooks/doc-superpowers"

  if [[ ! -f "$settings_file" ]]; then
    echo "  ✗ not installed (no $settings_file)"
    return
  fi

  local settings
  settings=$(cat "$settings_file")

  for hook_name in pre-commit-gate post-commit-sync session-summary; do
    local script_exists="✗"
    [[ -x "$hooks_dir/${hook_name}.sh" ]] && script_exists="✓"

    if echo "$settings" | jq -e ".hooks | .. | .command? // empty | select(contains(\"$hook_name\"))" >/dev/null 2>&1; then
      if [[ "$script_exists" == "✓" ]]; then
        printf "  ✓ %-22s active (script + settings)\n" "$hook_name"
      else
        printf "  ⚠ %-22s in settings but script missing from %s/\n" "$hook_name" "$hooks_dir"
      fi
    else
      printf "  ✗ %-22s not installed\n" "$hook_name"
    fi
  done
}

# --- CI tier ---

# --- CI install helpers (granular workflow selection) ---

# Resolve WORKFLOWS_FILTER into a newline-separated list of workflow names
# (without .yml) that should be installed. Echoes nothing for "none".
# Validates CSV entries against state_known_workflows; errors on unknowns.
ci_resolve_workflow_set() {
  local filter="${WORKFLOWS_FILTER:-all}"
  [[ -z "$filter" ]] && filter="all"

  case "$filter" in
    all)
      state_known_workflows
      ;;
    none)
      # Echo nothing — caller skips the install loop.
      ;;
    *)
      # CSV path. Split, trim, validate each entry.
      local -a names=()
      local IFS_save="$IFS"
      IFS=','
      # shellcheck disable=SC2206
      local raw=( $filter )
      IFS="$IFS_save"
      local n
      for n in "${raw[@]}"; do
        # Trim whitespace.
        n="${n#"${n%%[![:space:]]*}"}"
        n="${n%"${n##*[![:space:]]}"}"
        [[ -z "$n" ]] && continue
        if ! state_is_known_workflow "$n"; then
          {
            echo "ERROR: unknown workflow name: $n"
            echo "Valid names:"
            state_known_workflows | sed 's/^/  - /'
          } >&2
          exit 1
        fi
        names+=( "$n" )
      done
      printf '%s\n' "${names[@]}"
      ;;
  esac
}

# Copy a single workflow template into .github/workflows.
ci_copy_workflow_template() {
  local workflow_name="$1"          # bare name (no .yml)
  local workflow_src="$SCRIPT_DIR/ci/${workflow_name}.yml"
  local workflow_dest=".github/workflows/${workflow_name}.yml"

  if [[ ! -f "$workflow_src" ]]; then
    echo "  WARN: template not found: $workflow_src — skipping" >&2
    return 1
  fi

  if [[ -f "$workflow_dest" ]] && ! is_doc_superpowers_workflow "$workflow_dest"; then
    echo "  Existing ${workflow_name}.yml found (not doc-superpowers-managed), skipping."
    return 2
  fi

  local ci_strict_value="0"
  [[ "$CI_STRICT" == "true" ]] && ci_strict_value="1"

  sed \
    -e "s|__BASE_BRANCH__|$BASE_BRANCH|g" \
    -e "s|__VERSION__|v$VERSION|g" \
    -e "s|__CRON_SCHEDULE__|$CRON_SCHEDULE|g" \
    -e "s|__CI_STRICT__|$ci_strict_value|g" \
    "$workflow_src" > "$workflow_dest"

  return 0
}

install_ci() {
  # Validate WORKFLOWS_FILTER UP FRONT so a bogus name aborts before we
  # touch the filesystem. The validation must happen here (not in a subshell)
  # so `exit 1` propagates.
  case "${WORKFLOWS_FILTER:-all}" in
    ""|all|none) ;;
    *)
      local _w_save _IFS_save="$IFS"
      IFS=','
      # shellcheck disable=SC2206
      local -a _wfs=( ${WORKFLOWS_FILTER} )
      IFS="$_IFS_save"
      for _w_save in "${_wfs[@]}"; do
        _w_save="${_w_save#"${_w_save%%[![:space:]]*}"}"
        _w_save="${_w_save%"${_w_save##*[![:space:]]}"}"
        [[ -z "$_w_save" ]] && continue
        if ! state_is_known_workflow "$_w_save"; then
          {
            echo "ERROR: unknown workflow name: $_w_save"
            echo "Valid names:"
            state_known_workflows | sed 's/^/  - /'
          } >&2
          exit 1
        fi
      done
      ;;
  esac

  mkdir -p .github/workflows

  # Bootstrap state file if missing/invalid.
  if ! state_is_valid; then
    state_bootstrap
  fi

  local -a install_set=()
  local name
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    install_set+=( "$name" )
  done < <(ci_resolve_workflow_set)

  local installed=0 skipped_existing=0 skipped_intentional=0
  local -a skipped_intentional_names=()

  # `${arr[@]+"${arr[@]}"}` guards against empty-array expansion under
  # `set -u` on bash 3.2 (default /bin/bash on macOS).
  for name in ${install_set[@]+"${install_set[@]}"}; do
    # State-respect check (skipped if --force or if --workflows= was passed
    # explicitly listing this workflow — explicit beats state).
    if [[ "$FORCE_FLAG" != "true" ]] \
       && [[ "$WORKFLOWS_FILTER" == "" || "$WORKFLOWS_FILTER" == "all" ]] \
       && state_should_skip_workflow "$name"; then
      skipped_intentional_names+=( "$name" )
      skipped_intentional=$((skipped_intentional + 1))
      continue
    fi

    local rc=0
    ci_copy_workflow_template "$name" || rc=$?
    case "$rc" in
      0) installed=$((installed + 1))
         state_mark_workflow_installed "$name" ;;
      2) skipped_existing=$((skipped_existing + 1)) ;;
      *) : ;;
    esac
  done

  # Vendor doc-tools.sh into the project for local CI execution
  # (always done — independent of workflow set; mirrors `tools install`
  # contract).
  if [[ -f "$DOC_TOOLS" ]]; then
    mkdir -p .github/scripts
    cp "$DOC_TOOLS" .github/scripts/doc-tools.sh
    chmod +x .github/scripts/doc-tools.sh
    echo "  Vendored doc-tools.sh → .github/scripts/doc-tools.sh"
    state_mark_component tools installed ".github/scripts"
  fi

  # Install doc-pr-release helper scripts (alongside the workflow), gated on
  # --helpers=true AND (doc-pr-release in install_set OR no --workflows filter).
  # Rationale: helpers are useless without the workflow, but a user passing
  # --workflows=doc-pr-release with --helpers=false is a valid "bring your own
  # helpers" case.
  local should_install_helpers=false
  if [[ "$HELPERS_FLAG" == "true" ]] && [[ ${#install_set[@]} -gt 0 ]] \
     && printf '%s\n' "${install_set[@]}" | grep -qx 'doc-pr-release'; then
    should_install_helpers=true
  fi

  if [[ "$should_install_helpers" == "true" ]] \
     && [[ -d "$SCRIPT_DIR/ci/doc-pr-release" ]]; then
    mkdir -p .github/scripts/doc-pr-release
    local helpers_installed=0
    for helper in "$SCRIPT_DIR/ci/doc-pr-release/"*.sh; do
      [[ -f "$helper" ]] || continue
      local helper_dest
      helper_dest=".github/scripts/doc-pr-release/$(basename "$helper")"
      cp "$helper" "$helper_dest"
      chmod +x "$helper_dest"
      helpers_installed=$((helpers_installed + 1))
    done
    if [[ "$helpers_installed" -gt 0 ]]; then
      echo "  Installed $helpers_installed doc-pr-release helpers in .github/scripts/doc-pr-release/"
      state_mark_component helpers installed
    fi

    # Install the RELEASE-NOTES.next/ fragment-format spec (only if missing —
    # never overwrite user customizations).
    if [[ ! -f "RELEASE-NOTES.next/README.md" ]]; then
      mkdir -p RELEASE-NOTES.next
      cp "$SCRIPT_DIR/ci/doc-pr-release/RELEASE-NOTES.next.README.md" \
         "RELEASE-NOTES.next/README.md"
      echo "  Created RELEASE-NOTES.next/README.md (fragment format spec)"
    fi
  fi

  echo "CI/CD workflows: $installed installed, $skipped_existing skipped (existing non-managed), $skipped_intentional skipped (intentionally uninstalled)"
  if [[ "$skipped_intentional" -gt 0 ]]; then
    for n in "${skipped_intentional_names[@]}"; do
      echo "  skipping ${n}.yml (previously uninstalled; pass --workflows=$n to override, or --force)"
    done
  fi

  if [[ $installed -gt 0 ]]; then
    echo "  Remember to commit and push these workflows."
    # Check if any installed workflow requires Anthropic auth.
    # Workflows accept either CLAUDE_CODE_OAUTH_TOKEN (preferred) or
    # ANTHROPIC_API_KEY; the in-workflow preflight step picks one and fails
    # fast if both are unset.
    if grep -rlqE 'CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_API_KEY' .github/workflows/doc-*.yml 2>/dev/null; then
      echo ""
      echo "  NOTE: Claude-powered workflows require ONE of these GitHub Actions secrets:"
      echo "    - CLAUDE_CODE_OAUTH_TOKEN (preferred — Claude Code OAuth token)"
      echo "    - ANTHROPIC_API_KEY       (fallback — Anthropic API key)"
      echo "  If both are set, CLAUDE_CODE_OAUTH_TOKEN takes precedence."
      echo "  Set one at: Settings > Secrets and variables > Actions > New repository secret"
    fi
  fi
}

uninstall_ci() {
  if [[ ! -d ".github/workflows" ]]; then
    echo "CI/CD workflows: nothing to uninstall"
    return 0
  fi

  # --transient flips intentional:false; default is intentional:true.
  local intentional_flag="true"
  [[ "$TRANSIENT_FLAG" == "true" ]] && intentional_flag="false"

  # Determine the set of workflows to uninstall.
  #   No --workflows= → ALL doc-superpowers workflows (legacy behavior).
  #   --workflows=csv → only those.
  #   --workflows=none → uninstall nothing (no-op for workflows; still removes
  #     helpers + vendored doc-tools.sh below).
  local -a uninstall_set=()
  local name
  if [[ -z "$WORKFLOWS_FILTER" || "$WORKFLOWS_FILTER" == "all" ]]; then
    while IFS= read -r name; do
      uninstall_set+=( "$name" )
    done < <(state_known_workflows)
  elif [[ "$WORKFLOWS_FILTER" == "none" ]]; then
    : # leave empty
  else
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      uninstall_set+=( "$name" )
    done < <(ci_resolve_workflow_set)
  fi

  local removed=0
  # `${arr[@]+...}` guards against empty-array expansion under `set -u`
  # on bash 3.2 (default /bin/bash on macOS) — relevant for --workflows=none.
  for name in ${uninstall_set[@]+"${uninstall_set[@]}"}; do
    local workflow_dest=".github/workflows/${name}.yml"
    if is_doc_superpowers_workflow "$workflow_dest" 2>/dev/null; then
      rm "$workflow_dest"
      removed=$((removed + 1))
    fi
    # Always record state so the next install respects it — even if the file
    # was missing on disk (user manually deleted), we still flip state.
    state_mark_workflow_uninstalled "$name" "$intentional_flag"
  done

  # Remove doc-pr-release helpers if present and unmodified (best-effort).
  # Only triggered when ALL workflows uninstalled OR doc-pr-release is in set.
  local should_remove_helpers=false
  if [[ -z "$WORKFLOWS_FILTER" || "$WORKFLOWS_FILTER" == "all" ]]; then
    should_remove_helpers=true
  elif [[ ${#uninstall_set[@]} -gt 0 ]] \
       && printf '%s\n' "${uninstall_set[@]}" | grep -qx 'doc-pr-release'; then
    should_remove_helpers=true
  fi
  if [[ "$should_remove_helpers" == "true" ]] \
     && [[ -d ".github/scripts/doc-pr-release" ]]; then
    rm -rf .github/scripts/doc-pr-release
    echo "  Removed .github/scripts/doc-pr-release/"
    state_mark_component helpers uninstalled
  fi
  # Note: RELEASE-NOTES.next/README.md is NOT auto-removed — it may have
  # accumulated user-authored fragment edits via PR-<N>.md siblings, and
  # nuking the directory would lose unmerged release notes. Leave it.

  # Remove vendored doc-tools.sh ONLY on a full uninstall (no --workflows= or
  # --workflows=all). Partial uninstalls keep doc-tools.sh — it's a per-
  # project tool, not per-workflow.
  if [[ -z "$WORKFLOWS_FILTER" || "$WORKFLOWS_FILTER" == "all" ]] \
     && [[ -f ".github/scripts/doc-tools.sh" ]]; then
    rm .github/scripts/doc-tools.sh
    rmdir .github/scripts 2>/dev/null || true
    state_mark_component tools uninstalled
  fi

  echo "CI/CD workflows: $removed removed"
}

status_ci() {
  echo "CI/CD Workflows:"
  if [[ ! -d ".github/workflows" ]]; then
    echo "  ✗ not installed"
    return
  fi

  local found=0 name state_file_cache="" have_state_file=false
  if state_is_valid; then
    have_state_file=true
    state_file_cache="$(state_file_path)"
  fi
  while IFS= read -r name; do
    local workflow_dest=".github/workflows/${name}.yml"
    if is_doc_superpowers_workflow "$workflow_dest" 2>/dev/null; then
      printf "  ✓ %-26s installed\n" "${name}.yml"
      found=$((found + 1))
    elif [[ "$have_state_file" == "true" ]]; then
      # One jq invocation per workflow — pull state + intentional together.
      local entry
      entry=$(jq -r --arg n "$name" '
        .tiers.ci.workflows[$n] // {} |
        "\(.state // "never")|\(.intentional // false)"
      ' "$state_file_cache" 2>/dev/null)
      local entry_state="${entry%%|*}"
      local entry_intentional="${entry##*|}"
      if [[ "$entry_state" == "uninstalled" ]]; then
        if [[ "$entry_intentional" == "true" ]]; then
          printf "  ✗ %-26s uninstalled (intentional)\n" "${name}.yml"
        else
          printf "  ✗ %-26s uninstalled (transient)\n" "${name}.yml"
        fi
      else
        printf "  ✗ %-26s not installed\n" "${name}.yml"
      fi
    else
      printf "  ✗ %-26s not installed\n" "${name}.yml"
    fi
  done < <(state_known_workflows)

  # Also report whether helpers are installed.
  if [[ -d ".github/scripts/doc-pr-release" ]]; then
    local helper_count
    helper_count=$(find .github/scripts/doc-pr-release -maxdepth 1 -name '*.sh' | wc -l | tr -d ' ')
    echo "  doc-pr-release helpers: $helper_count installed"
  fi
  if [[ -f ".github/scripts/doc-tools.sh" ]]; then
    echo "  doc-tools.sh: vendored at .github/scripts/doc-tools.sh"
  fi
  if state_is_valid; then
    echo "  state file: $(state_file_path)"
  fi
}

# --- Main ---

[[ $# -lt 1 ]] && usage

COMMAND="$1"
shift

# Validate skill directory
if [[ ! -f "$DOC_TOOLS" ]]; then
  echo "ERROR: doc-tools.sh not found at $DOC_TOOLS" >&2
  echo "Is the doc-superpowers skill installed correctly?" >&2
  exit 1
fi

# Parse flags
DO_GIT=false
DO_CLAUDE=false
DO_CI=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --git) DO_GIT=true; shift ;;
    --claude) DO_CLAUDE=true; shift ;;
    --ci) DO_CI=true; shift ;;
    --all) DO_GIT=true; DO_CLAUDE=true; DO_CI=true; shift ;;
    --base-branch)
      [[ $# -lt 2 ]] && { echo "ERROR: --base-branch requires a value" >&2; exit 1; }
      BASE_BRANCH="$2"; shift 2 ;;
    --cron)
      [[ $# -lt 2 ]] && { echo "ERROR: --cron requires a value" >&2; exit 1; }
      CRON_SCHEDULE="$2"; shift 2 ;;
    --ci-strict) CI_STRICT="true"; shift ;;
    --workflows=*) WORKFLOWS_FILTER="${1#--workflows=}"; shift ;;
    --workflows)
      [[ $# -lt 2 ]] && { echo "ERROR: --workflows requires a value" >&2; exit 1; }
      WORKFLOWS_FILTER="$2"; shift 2 ;;
    --helpers=*) HELPERS_FLAG="${1#--helpers=}"; shift ;;
    --helpers)
      [[ $# -lt 2 ]] && { echo "ERROR: --helpers requires a value" >&2; exit 1; }
      HELPERS_FLAG="$2"; shift 2 ;;
    --force) FORCE_FLAG="true"; shift ;;
    --transient) TRANSIENT_FLAG="true"; shift ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

# Validate --helpers value.
case "$HELPERS_FLAG" in
  true|false) ;;
  *) echo "ERROR: --helpers must be 'true' or 'false' (got: $HELPERS_FLAG)" >&2; exit 1 ;;
esac

case "$COMMAND" in
  install)
    # If no tier selected, check for interactive mode
    if ! $DO_GIT && ! $DO_CLAUDE && ! $DO_CI; then
      if [[ -t 0 ]]; then
        echo "doc-superpowers hooks installer"
        echo ""
        echo "Which tiers would you like to install?"
        echo "  [1] Git hooks (pre-commit, post-merge, post-checkout, prepare-commit-msg)"
        echo "  [2] Claude Code hooks (pre-commit gate, session summary)"
        echo "  [3] CI/CD workflows (PR check, weekly audit, index update)"
        echo "  [a] All of the above"
        echo ""
        read -rp "Select (comma-separated, e.g. 1,2): " selection
        [[ "$selection" == *1* ]] && DO_GIT=true
        [[ "$selection" == *2* ]] && DO_CLAUDE=true
        [[ "$selection" == *3* ]] && DO_CI=true
        [[ "$selection" == *a* ]] && DO_GIT=true && DO_CLAUDE=true && DO_CI=true
      else
        usage
      fi
    fi

    echo ""
    echo "Installing doc-superpowers hooks..."
    echo ""
    $DO_GIT && install_git
    $DO_CLAUDE && install_claude
    $DO_CI && install_ci
    echo ""
    echo "Done."
    ;;

  uninstall)
    if ! $DO_GIT && ! $DO_CLAUDE && ! $DO_CI; then
      if [[ -t 0 ]]; then
        read -rp "No tier specified. Uninstall all tiers? [y/N] " confirm
        if [[ "$confirm" =~ ^[Yy] ]]; then
          DO_GIT=true; DO_CLAUDE=true; DO_CI=true
        else
          echo "Cancelled."
          exit 0
        fi
      else
        echo "ERROR: specify tier flags (--git, --claude, --ci, --all)" >&2
        exit 1
      fi
    fi

    echo ""
    echo "Uninstalling doc-superpowers hooks..."
    echo ""
    $DO_GIT && uninstall_git
    $DO_CLAUDE && uninstall_claude
    $DO_CI && uninstall_ci
    echo ""
    echo "Done."
    ;;

  status)
    echo ""
    echo "doc-superpowers hooks status"
    echo ""
    status_git
    echo ""
    status_claude
    echo ""
    status_ci
    echo ""
    echo "Env overrides: DOC_SUPERPOWERS_STRICT=${DOC_SUPERPOWERS_STRICT:-unset} DOC_SUPERPOWERS_SKIP=${DOC_SUPERPOWERS_SKIP:-unset}"
    ;;

  *)
    usage
    ;;
esac
