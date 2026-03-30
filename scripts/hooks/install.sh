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
  --base-branch NAME   Target branch (default: main)
  --cron EXPR          Schedule cron expression (default: 0 9 * * 1)
  --ci-strict          Make PR check fail on stale docs
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
      rm -f "$hook_dest.bak"
      # Remove local hook copy
      rm -f "$hooks_dir/.doc-superpowers-$hook_name"
      removed=$((removed + 1))
    fi
  done

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
  local pre_tool_entry="{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"$pre_commit_cmd\",\"timeout\":10}]}"
  local post_tool_entry="{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"$post_commit_cmd\",\"timeout\":10}]}"
  local stop_entry="{\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"$session_cmd\",\"timeout\":10}]}"

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

install_ci() {
  mkdir -p .github/workflows
  local installed=0 skipped=0

  for workflow_src in "$SCRIPT_DIR/ci/"*.yml; do
    local workflow_name
    workflow_name=$(basename "$workflow_src")
    local workflow_dest=".github/workflows/$workflow_name"

    if [[ -f "$workflow_dest" ]] && ! is_doc_superpowers_workflow "$workflow_dest"; then
      echo "  Existing $workflow_name found, skipping."
      skipped=$((skipped + 1))
      continue
    fi

    # Map CI_STRICT boolean to the value the workflow expects
    local ci_strict_value="0"
    [[ "$CI_STRICT" == "true" ]] && ci_strict_value="1"

    # Copy with placeholder substitution
    sed \
      -e "s|__BASE_BRANCH__|$BASE_BRANCH|g" \
      -e "s|__VERSION__|v$VERSION|g" \
      -e "s|__CRON_SCHEDULE__|$CRON_SCHEDULE|g" \
      -e "s|__CI_STRICT__|$ci_strict_value|g" \
      "$workflow_src" > "$workflow_dest"

    installed=$((installed + 1))
  done

  echo "CI/CD workflows: $installed installed, $skipped skipped"
  if [[ $installed -gt 0 ]]; then
    echo "  Remember to commit and push these workflows."
  fi
}

uninstall_ci() {
  if [[ ! -d ".github/workflows" ]]; then
    echo "CI/CD workflows: nothing to uninstall"
    return 0
  fi

  local removed=0
  for workflow_name in doc-freshness-pr.yml doc-freshness-schedule.yml doc-index-update.yml; do
    local workflow_dest=".github/workflows/$workflow_name"
    if is_doc_superpowers_workflow "$workflow_dest" 2>/dev/null; then
      rm "$workflow_dest"
      removed=$((removed + 1))
    fi
  done

  echo "CI/CD workflows: $removed removed"
}

status_ci() {
  echo "CI/CD Workflows:"
  if [[ ! -d ".github/workflows" ]]; then
    echo "  ✗ not installed"
    return
  fi

  local found=0
  for workflow_name in doc-freshness-pr.yml doc-freshness-schedule.yml doc-index-update.yml; do
    local workflow_dest=".github/workflows/$workflow_name"
    if is_doc_superpowers_workflow "$workflow_dest" 2>/dev/null; then
      printf "  ✓ %-22s installed\n" "$workflow_name"
      found=$((found + 1))
    else
      printf "  ✗ %-22s not installed\n" "$workflow_name"
    fi
  done
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
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

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
