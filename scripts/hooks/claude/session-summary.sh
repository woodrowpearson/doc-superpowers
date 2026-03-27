#!/usr/bin/env bash
# doc-superpowers hook v1 — installed __INSTALL_DATE__ — Claude Code Stop hook
# DO NOT EDIT — managed by doc-superpowers hooks installer

DOC_TOOLS="${DOC_TOOLS:-__DOC_TOOLS_PATH__}"
DOC_INDEX="${DOC_INDEX:-docs/.doc-index.json}"

[[ "${DOC_SUPERPOWERS_SKIP:-}" == "1" ]] && exit 0
[[ -f "$DOC_TOOLS" ]] || exit 0
[[ -f "$DOC_INDEX" ]] || exit 0

# Enforce 1s timeout to avoid blocking session exit
# timeout (Linux/GNU), gtimeout (macOS Homebrew coreutils), or manual background+kill
if command -v timeout >/dev/null 2>&1; then
  result=$(timeout 1 "$DOC_TOOLS" check-freshness 2>/dev/null) || exit 0
elif command -v gtimeout >/dev/null 2>&1; then
  result=$(gtimeout 1 "$DOC_TOOLS" check-freshness 2>/dev/null) || exit 0
else
  # Manual timeout fallback for vanilla macOS (no coreutils)
  "$DOC_TOOLS" check-freshness > /tmp/.doc-sp-summary.$$ 2>/dev/null &
  bg_pid=$!
  ( sleep 1; kill "$bg_pid" 2>/dev/null ) &
  wait "$bg_pid" 2>/dev/null || { rm -f /tmp/.doc-sp-summary.$$; exit 0; }
  result=$(cat /tmp/.doc-sp-summary.$$)
  rm -f /tmp/.doc-sp-summary.$$
fi

stale_count=$(echo "$result" | jq -r '.summary.stale // 0' 2>/dev/null) || exit 0
[[ "$stale_count" -eq 0 ]] && exit 0

if [[ "${DOC_SUPERPOWERS_QUIET:-}" != "1" ]]; then
  stale_list=$(echo "$result" | jq -r '[.docs | to_entries[] | select(.value.status == "stale") | .key] | join(", ")' 2>/dev/null)
  echo ""
  echo "doc-superpowers: session ending with $stale_count stale doc(s)"
  echo "  $stale_list"
  echo "  Consider running '/doc-superpowers update' next session."
  echo ""
fi

exit 0
