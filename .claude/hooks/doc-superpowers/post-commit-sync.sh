#!/usr/bin/env bash
# doc-superpowers hook v1 — installed 2026-03-29 — Claude Code PostToolUse (Bash)
# DO NOT EDIT — managed by doc-superpowers hooks installer

DOC_TOOLS="${DOC_TOOLS:-/Users/w/code/doc-superpowers/scripts/doc-tools.sh}"
DOC_INDEX="${DOC_INDEX:-docs/.doc-index.json}"

[[ "${DOC_SUPERPOWERS_SKIP:-}" == "1" ]] && exit 0

# Resolve to git root so relative paths work from any subdirectory
cd "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || exit 0

# Check if this was a git commit command
command_str="${TOOL_INPUT:-}"
if [[ -n "$command_str" ]]; then
  if echo "$command_str" | jq -e '.command' >/dev/null 2>&1; then
    command_str=$(echo "$command_str" | jq -r '.command' 2>/dev/null)
  fi
fi

# Only activate for git commit commands
echo "$command_str" | grep -qE '\bgit\s+commit\b' || exit 0

[[ -f "$DOC_TOOLS" ]] || exit 0
[[ -f "$DOC_INDEX" ]] || exit 0

# Auto-refresh index after commit to keep it current
bash "$DOC_TOOLS" update-index 2>/dev/null || true

# Check freshness scoped to just-committed files (handles initial commit)
committed=$(git diff --name-only HEAD~1..HEAD 2>/dev/null || git diff-tree --no-commit-id --name-only -r HEAD 2>/dev/null)
[[ -z "$committed" ]] && exit 0

code_refs_args=()
while IFS= read -r f; do
  [[ -n "$f" ]] && code_refs_args+=("$f")
done <<< "$committed"

result=$(bash "$DOC_TOOLS" check-freshness --code-refs "${code_refs_args[@]}" 2>/dev/null) || exit 0

stale_count=$(echo "$result" | jq -r '.summary.stale // 0' 2>/dev/null) || exit 0
missing_count=$(echo "$result" | jq -r '.summary.missing // 0' 2>/dev/null) || missing_count=0
[[ "$stale_count" -eq 0 && "$missing_count" -eq 0 ]] && exit 0

if [[ "${DOC_SUPERPOWERS_QUIET:-}" != "1" ]]; then
  echo ""

  if [[ "$stale_count" -gt 0 ]]; then
    echo "doc-superpowers: $stale_count doc(s) affected by this commit"
    echo "$result" | jq -r '
      .docs | to_entries[] |
      select(.value.status == "stale") |
      "  \(.key) — \(.value.reason // "unknown")"
    ' 2>/dev/null
  fi

  if [[ "$missing_count" -gt 0 ]]; then
    echo "doc-superpowers: $missing_count indexed doc(s) missing from disk"
    echo "$result" | jq -r '
      .docs | to_entries[] |
      select(.value.status == "missing") |
      "  \(.key)"
    ' 2>/dev/null
    echo "  Run 'doc-tools.sh remove-entry' or 'deprecate-entry' to clean up."
  fi

  echo "  Run '/doc-superpowers update' to refresh stale documentation."
  echo ""
fi

exit 0
