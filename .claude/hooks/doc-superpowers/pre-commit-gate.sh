#!/usr/bin/env bash
# doc-superpowers hook v1 — installed 2026-03-29 — Claude Code PreToolUse (Bash)
# DO NOT EDIT — managed by doc-superpowers hooks installer

DOC_TOOLS="${DOC_TOOLS:-/Users/w/code/doc-superpowers/scripts/doc-tools.sh}"
DOC_INDEX="${DOC_INDEX:-docs/.doc-index.json}"

[[ "${DOC_SUPERPOWERS_SKIP:-}" == "1" ]] && exit 0

# Resolve to git root so relative paths work from any subdirectory
cd "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || exit 0

# Check if this is a git commit command
command_str="${TOOL_INPUT:-}"
if [[ -n "$command_str" ]]; then
  # Extract command field from JSON if it looks like JSON
  if echo "$command_str" | jq -e '.command' >/dev/null 2>&1; then
    command_str=$(echo "$command_str" | jq -r '.command' 2>/dev/null)
  fi
fi

# Only activate for git commit commands
echo "$command_str" | grep -qE '\bgit\s+commit\b' || exit 0

[[ -f "$DOC_TOOLS" ]] || exit 0
[[ -f "$DOC_INDEX" ]] || exit 0

# Reuse pre-commit logic: scope to staged files
staged=$(git diff --cached --name-only 2>/dev/null)
[[ -z "$staged" ]] && exit 0

code_refs_args=()
while IFS= read -r f; do
  [[ -n "$f" ]] && code_refs_args+=("$f")
done <<< "$staged"

result=$("$DOC_TOOLS" check-freshness --code-refs "${code_refs_args[@]}" 2>/dev/null) || exit 0

stale_count=$(echo "$result" | jq -r '.summary.stale // 0' 2>/dev/null) || exit 0
missing_count=$(echo "$result" | jq -r '.summary.missing // 0' 2>/dev/null) || missing_count=0
[[ "$stale_count" -eq 0 && "$missing_count" -eq 0 ]] && exit 0

if [[ "${DOC_SUPERPOWERS_QUIET:-}" != "1" ]]; then
  echo ""

  if [[ "$stale_count" -gt 0 ]]; then
    echo "doc-superpowers: $stale_count stale doc(s) detected before commit"
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

  echo "  Consider running '/doc-superpowers update' before committing."
  echo ""
fi

if [[ "${DOC_SUPERPOWERS_STRICT:-}" == "1" ]]; then
  exit 2
fi
exit 0
