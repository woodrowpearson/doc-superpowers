#!/usr/bin/env bash
# doc-superpowers hook v1 — installed __INSTALL_DATE__ — Claude Code PostToolUse (Write|Edit) hook (work ledger)
# DO NOT EDIT — managed by doc-superpowers hooks installer (install.sh install --ledger-claude)
#
# `doc-tools.sh ledger note` is the one home for an item's state. When Claude
# writes a file under one of config state_watch.paths (the host's agent-memory
# and scratch directories) and what it wrote — Write's content, Edit's
# new_string — names an item key (<ledger>-<n>, the ledger one the registry
# docs/ledger/ledgers.json or config legacy_ids holds; any key-shaped word
# when there is no registry) and holds one of state_watch.patterns (text
# such as "next:" or "approved", any case), one advisory line
# (additionalContext, for Claude) suggests `doc-tools.sh ledger note <key>
# "…"` instead.
#
# A state_watch.paths entry is a path: a leading "~/" is $HOME, an absolute
# one is itself, any other is under the project (git's top level, or
# $CLAUDE_PROJECT_DIR). "*" matches within one path segment; every other
# character — a space, a "~" anywhere else, "?", "[" — is itself. An entry
# matches the file itself and anything below it. Nothing is word-split or
# matched against the disk: one jq program reads the event, the config and
# the registry.
#
# Advisory only: always exits 0 and never blocks; stdout is one JSON object or
# nothing. Silent without docs/ledger/config.json or jq, and on an event or
# config it cannot read. DOC_SUPERPOWERS_LEDGER_SKIP=1 turns it off.

[[ "${DOC_SUPERPOWERS_LEDGER_SKIP:-}" == "1" ]] && exit 0

payload=""
[ -t 0 ] || payload=$(cat 2>/dev/null)

HOOK_EVENT=PostToolUse
case "${BASH_SOURCE[0]}" in
  /*) _lib="${BASH_SOURCE[0]%/*}/hook-lib.sh" ;;
  */*) _lib="$PWD/${BASH_SOURCE[0]%/*}/hook-lib.sh" ;;
  *) _lib="$PWD/hook-lib.sh" ;;
esac
proj="${CLAUDE_PROJECT_DIR:-}"

cd "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || exit 0
[[ -f docs/ledger/config.json ]] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
have_jq=1

# shellcheck source=scripts/hooks/claude/hook-lib.sh
if ! . "$_lib" 2>/dev/null; then
  printf '%s\n' '{"systemMessage":"doc-superpowers: hook-lib.sh is missing beside the ledger-state-watch hook, so it cannot report; re-run install.sh install --ledger-claude"}'
  exit 0
fi

reg=docs/ledger/ledgers.json
[[ -f "$reg" ]] || reg=/dev/null

# shellcheck disable=SC2016  # jq program
_watch_jq='
  # An entry as a regex: "*" is any run within a segment, all else literal.
  def glob_re: gsub("(?<c>[.+?()\\[\\]{}^$|\\\\])"; "\\\(.c)") | gsub("\\*"; "[^/]*");
  # An entry'\''s absolute spellings ("" and "/" name nothing).
  def spellings:
    sub("/+$"; "") as $e
    | if $e == "" then empty
      elif ($e | startswith("~/")) then $home + ($e | .[1:])
      elif ($e | startswith("/")) then $e
      else ([$top, $proj] | map(select(. != "")) | unique | .[]) + "/" + $e
      end;
  ($cfg[0] // {}) as $c
  | (($c | if type == "object" then .state_watch else null end) // {}) as $sw0
  | (if ($sw0 | type) == "object" then $sw0 else {} end) as $sw
  | ((.tool_input // {}) | if type == "object" then . else {} end) as $in
  | ($in.file_path // "") as $raw
  | select(($raw | type) == "string" and $raw != "")
  | (if ($raw | startswith("/")) then $raw else ((.cwd // $top) + "/" + $raw) end) as $p
  | [($sw.paths // [])[]? | strings | spellings | glob_re] as $res
  | select(any($res[]; . as $r | $p | test("^" + $r + "(/|$)")))
  | ([$in.content, $in.new_string, (($in.edits // []) | .[]? | .new_string?)] | map(strings) | join("\n")) as $text
  | ($text | ascii_downcase) as $lc
  | select(any(($sw.patterns // [])[]? | strings | select(. != "") | ascii_downcase; . as $pt | $lc | contains($pt)))
  | (if $reg == "" then null else (try ($reg | fromjson | [.ledgers[]? | .id? | strings]) catch null) end) as $ids0
  | (if $ids0 == null then null else $ids0 + [($c.legacy_ids // [])[]? | strings] end) as $ids
  | [$text | scan("(?<![a-z0-9-])[a-z0-9-]{1,16}-[1-9][0-9]*(?![a-z0-9-])")
     | select($ids == null or (sub("-[1-9][0-9]*$"; "") as $l | $ids | index([$l]) != null))]
  | reduce .[] as $k ([]; if index([$k]) != null then . else . + [$k] end)
  | select(length > 0)
  | "ledger: this write to \($raw) records state for \(.[0:5] | join(", "))\(if length > 5 then ", …" else "" end): keep it in the ledger, its one home — doc-tools.sh ledger note \(.[0]) \"…\" (--kind ruling for a ruling)"'

line=$(jq -r --arg home "${HOME:-}" --arg top "$PWD" --arg proj "$proj" \
  --slurpfile cfg docs/ledger/config.json --rawfile reg "$reg" "$_watch_jq" <<<"$payload" 2>/dev/null) || exit 0
[[ -n "$line" ]] || exit 0
_emit "" "$line"
exit 0
