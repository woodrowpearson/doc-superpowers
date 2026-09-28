#!/usr/bin/env bash
set -euo pipefail

# doc-superpowers hooks installer
# Usage: install.sh <install|uninstall|status> [--git] [--claude] [--ci] [--all]
#        install.sh install [--base-branch NAME] [--cron EXPR] [--ci-strict]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOC_TOOLS="$SKILL_DIR/scripts/doc-tools.sh"
# Plugin-cache parent (containing all versioned sibling dirs). Substituted into
# hook bodies so they resolve the latest installed version at runtime instead
# of pinning the version active at install time. See issue 2026-05-26-doc-
# superpowers-hook-pins-v2.12.0-despite-v2.12.1-fix in the abundance-mvp repo
# for the motivating bug.
DOC_TOOLS_PARENT="$(dirname "$SKILL_DIR")"
MARKER="doc-superpowers hook v1"
WORKFLOW_MARKER="doc-superpowers workflow v1"
DATE=$(date +%Y-%m-%d)

# The plugin's version, parsed by doc-tools.sh (the first release heading of
# RELEASE-NOTES.md, line-anchored and outside code fences — the one parser
# check-version uses too), run under this installer's own bash. Only rendering
# a CI template uses it, so it is looked up there, once (ci_version), never on
# status / uninstall / usage. A missing or malformed RELEASE-NOTES.md must not
# abort the install (under pipefail the old grep | sed did, silently): the
# version is "unknown", with one WARN.
VERSION=""
ci_version() {
  [[ -z "$VERSION" ]] || return 0
  if ! VERSION=$("$BASH" "$DOC_TOOLS" tools version 2>/dev/null) || [[ -z "$VERSION" ]]; then
    VERSION="unknown"
    echo "  WARN: cannot read the plugin version from $SKILL_DIR/RELEASE-NOTES.md (doc-tools.sh tools version); workflows get DOC_SUPERPOWERS_VERSION \"vunknown\"" >&2
  fi
}

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
                           doc-pr-release.yml runs those helpers, so install
                           refuses --helpers=false while doc-pr-release is
                           selected (deselect it, or drop --helpers=false).
                           (The workflows' own step scripts in
                           .github/scripts/doc-superpowers-steps/ always ship
                           with doc-pr-release / doc-release.)
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

# --- Merge driver registration (merge.doc-index.driver) ---
#
# Git runs the registered value with sh, after replacing %O %A %B with its
# temp file names (and %% with %). The value resolves the driver when the
# merge RUNS, not at install time, so a plugin update reaches existing
# installs without re-registration and a pruned version dir is not fatal:
#   - plugin-cache install (basename of SKILL_DIR is a version, e.g.
#     …/doc-superpowers/3.0.0): the newest version-named sibling that has
#     scripts/merge-doc-index.sh, in numeric order (10.0.0 > 9.0.0); any other
#     sibling is never run;
#   - any other install (a git checkout): SKILL_DIR's own driver, pinned (a
#     `git pull` updates it in place).
# No driver found → conflict markers via git merge-file, exit 1 — never a
# silent ours-only result. (Against an EMPTY base: against the real one a
# line merge of two JSON edits can come out clean, i.e. unchecked and without
# markers.) The path is single-quoted for sh and its % doubled
# for git. POSIX sh and tools only (no sort -V: GNU-only).
# (T8/I-7 reworks the installer's placement and ownership; the git hooks'
# DOC_TOOLS resolution should converge on this same rule there.)
# shellcheck disable=SC2016  # sh programs for git to run, not bash expansions
_MD_RESOLVE='if [ -d "$t" ]; then v=$(for d in "$t"/*/; do d=$(basename "$d"); [ -f "$t/$d/scripts/merge-doc-index.sh" ] && echo "$d"; done | grep -Ex "[0-9]+[.][0-9]+[.][0-9]+" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1); if [ -n "$v" ]; then t=$t/$v/scripts/merge-doc-index.sh; fi; fi'
# shellcheck disable=SC2016
_MD_RUN='if [ -f "$t" ]; then exec bash "$t" "$@"; fi; echo "doc-superpowers: merge driver not found ($t); leaving conflict markers" >&2; git merge-file -L ours -L base -L theirs "$2" /dev/null "$3"; exit 1'

# What the registration names: the version-dir parent, or the pinned script.
merge_driver_target() {
  local re='^[0-9]+\.[0-9]+\.[0-9]+$' base
  base=$(basename "$SKILL_DIR")
  if [[ "$base" =~ $re ]]; then
    printf '%s' "$DOC_TOOLS_PARENT"
  else
    printf '%s' "$SKILL_DIR/scripts/merge-doc-index.sh"
  fi
}

# The exact merge.doc-index.driver value this install registers.
merge_driver_cmd() {
  local q
  q=$(merge_driver_target | sed -e "s/'/'\\\\''/g" -e 's/%/%%/g')
  printf "t='%s'; set -- %%O %%A %%B; %s; %s" "$q" "$_MD_RESOLVE" "$_MD_RUN"
}

# The driver a merge would run now for this install ("" if none).
merge_driver_resolved() {
  # shellcheck disable=SC2016  # sh program, not bash expansion
  sh -c 't=$1; '"$_MD_RESOLVE"'; if [ -f "$t" ]; then echo "$t"; fi' doc-index-merge "$(merge_driver_target)" 2>/dev/null || true
}

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
      sed -e "s|__DOC_TOOLS_PATH__|$DOC_TOOLS|g" -e "s|__DOC_TOOLS_PARENT__|$DOC_TOOLS_PARENT|g" -e "s|__INSTALL_DATE__|$DATE|g" "$hook_src" > "$local_hook"
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
    sed -e "s|__DOC_TOOLS_PATH__|$DOC_TOOLS|g" -e "s|__DOC_TOOLS_PARENT__|$DOC_TOOLS_PARENT|g" -e "s|__INSTALL_DATE__|$DATE|g" "$hook_src" > "$hook_dest"
    chmod +x "$hook_dest"
    installed=$((installed + 1))
  done

  # Register the three-way merge driver for docs/.doc-index.json (see
  # merge_driver_cmd: resolved at merge time, path quoted). Re-running install
  # replaces an older, pinned registration.
  local merge_driver="$SKILL_DIR/scripts/merge-doc-index.sh"
  if [[ -f "$merge_driver" ]]; then
    git config --local merge.doc-index.name "doc-superpowers index merger"
    git config --local merge.doc-index.driver "$(merge_driver_cmd)"

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
    echo "  Registered merge driver: doc-index (a merge runs: $(merge_driver_resolved))"
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

  # Merge driver status. The registration is compared with the one this
  # install would write rather than parsed: the path is quoted and resolved at
  # merge time. A pre-3.0 registration is "<unquoted path> %O %A %B"; its path
  # is everything before that suffix (it may contain spaces).
  local registered
  if registered=$(git config --local --get merge.doc-index.driver 2>/dev/null); then
    local resolved legacy
    if [[ "$registered" == "$(merge_driver_cmd)" ]]; then
      resolved=$(merge_driver_resolved)
      if [[ -n "$resolved" ]]; then
        printf "  ✓ %-22s registered (a merge runs %s)\n" "merge-driver" "$resolved"
      else
        printf "  ⚠ %-22s registered but script missing: %s\n" "merge-driver" "$(merge_driver_target)"
      fi
    elif [[ "$registered" == *" %O %A %B" && "$registered" != "t='"* ]]; then
      legacy="${registered% %O %A %B}"
      if [[ -f "$legacy" ]]; then
        printf "  ⚠ %-22s registered at a pinned path (%s); re-run install --git\n" "merge-driver" "$legacy"
      else
        printf "  ⚠ %-22s registered but script missing: %s\n" "merge-driver" "$legacy"
      fi
    else
      printf "  ⚠ %-22s registered by another install; re-run install --git\n" "merge-driver"
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
    sed -e "s|__DOC_TOOLS_PATH__|$DOC_TOOLS|g" -e "s|__DOC_TOOLS_PARENT__|$DOC_TOOLS_PARENT|g" -e "s|__INSTALL_DATE__|$DATE|g" "$hook_src" > "$hooks_dir/$hook_name"
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

  ci_version
  sed \
    -e "s|__BASE_BRANCH__|$BASE_BRANCH|g" \
    -e "s|__VERSION__|v$VERSION|g" \
    -e "s|__CRON_SCHEDULE__|$CRON_SCHEDULE|g" \
    -e "s|__CI_STRICT__|$ci_strict_value|g" \
    "$workflow_src" > "$workflow_dest"

  return 0
}

# The doc-pr-release and doc-release templates run their steps from
# .github/scripts/doc-superpowers-steps/. Those scripts ARE the step bodies, not
# optional helpers, so --helpers never gates them: they are present exactly
# while a doc-superpowers-managed doc-pr-release.yml or doc-release.yml is on
# disk. Called after every install and uninstall.
ci_sync_step_scripts() {
  local src="$SCRIPT_DIR/ci/doc-superpowers-steps" dest=".github/scripts/doc-superpowers-steps"
  local wf needed=false
  for wf in doc-pr-release doc-release; do
    if is_doc_superpowers_workflow ".github/workflows/${wf}.yml" 2>/dev/null; then
      needed=true
    fi
  done
  if [[ "$needed" == "true" ]] && [[ -d "$src" ]]; then
    mkdir -p "$dest"
    local step n=0
    for step in "$src"/*.sh; do
      [[ -f "$step" ]] || continue
      cp "$step" "$dest/$(basename "$step")"
      chmod +x "$dest/$(basename "$step")"
      n=$((n + 1))
    done
    echo "  Installed $n workflow step scripts in $dest/"
  elif [[ "$needed" == "false" ]] && [[ -d "$dest" ]]; then
    rm -rf "$dest"
    echo "  Removed $dest/"
  fi
  return 0
}

# --helpers=false skips the doc-pr-release producer helpers (extract-context,
# update-pr-body, commit-and-push), but doc-pr-release.yml runs all three. A
# selected doc-pr-release with --helpers=false would therefore install a
# workflow that fails at runtime: refuse it up front, before any tier writes.
# Unknown --workflows names are left to install_ci's own validation.
ci_refuse_helpers_false_conflict() {
  [[ "$HELPERS_FLAG" == "false" ]] || return 0
  local name
  while IFS= read -r name; do
    if [[ "$name" == "doc-pr-release" ]]; then
      {
        echo "ERROR: --helpers=false cannot be combined with the doc-pr-release workflow:"
        echo "  doc-pr-release.yml runs .github/scripts/doc-pr-release/{extract-context,update-pr-body,commit-and-push}.sh,"
        echo "  which --helpers=false skips, so the installed workflow would fail at runtime."
        echo "  Fix: drop --helpers=false or deselect doc-pr-release (e.g. --workflows=<list without doc-pr-release>)."
        echo "Nothing was installed."
      } >&2
      exit 1
    fi
  done < <(ci_resolve_workflow_set 2>/dev/null)
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
  # --helpers=true AND doc-pr-release in install_set. (--helpers=false with
  # doc-pr-release selected is refused up front by
  # ci_refuse_helpers_false_conflict: the workflow runs these helpers.)
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

  ci_sync_step_scripts

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
  ci_sync_step_scripts
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
  if [[ -d ".github/scripts/doc-superpowers-steps" ]]; then
    local step_count
    step_count=$(find .github/scripts/doc-superpowers-steps -maxdepth 1 -name '*.sh' | wc -l | tr -d ' ')
    echo "  workflow step scripts: $step_count installed"
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

    $DO_CI && ci_refuse_helpers_false_conflict

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
