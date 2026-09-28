#!/usr/bin/env bash
# doc-superpowers install state — sourced by install.sh (and only by it: it
# uses install.sh's tmp_beside / commit_tmp write discipline).
#
# File: .claude/doc-superpowers/installed.json, relative to the repository top
# and COMMITTED, so the CI tier's choices are the team's. Only the CI tier is
# recorded: the git tier lives in .git (per clone) and the Claude tier in
# .claude/settings.local.json (per user), so a committed record of either
# would be wrong for every other contributor.
#
# Schema (schema_version 2):
# {
#   "schema_version": 2,
#   "tiers": {
#     "ci": {
#       "base_branch": "main",          ← the choices a plain `install --ci`
#       "cron": "0 9 * * 1",               reproduces (flags override them,
#       "ci_strict": false,                and are then recorded)
#       "workflows": {                  ← the workflow set
#         "doc-freshness-pr":       {"state": "installed", "installed_at": "…"},
#         "doc-freshness-schedule": {"state": "uninstalled", "intentional": true}
#       }
#     }
#   }
# }
# installed_at is set when a workflow goes from not installed to installed,
# never on a refresh (a rewritten timestamp on every install was the file's
# merge-conflict source). Vendored files are not recorded: which helpers are
# needed follows from the installed workflows, and disk is the truth for them.
# Version 1 files (installed_at/uninstalled_at per workflow, tools/helpers
# records, no choices) are read as they are and rewritten as version 2; a file
# written by a newer installer (schema_version > 2) is refused.
#
# One read (state_load), in-memory marks, one write (state_flush) per run, and
# only when the content changed. An unreadable file (a merge conflict, the
# wrong shape) is never overwritten: state_load fails and the caller refuses.
# Moving it aside to installed.json.corrupt is the recovery path: the next
# install then installs nothing that is absent on disk (STATE_RECOVERY=1).

STATE_FILE=".claude/doc-superpowers/installed.json"
STATE_CORRUPT="$STATE_FILE.corrupt"
STATE_SCHEMA=2
_SEP=$'\037'

STATE_PRESENT=0   # the file exists and was read
STATE_RECOVERY=0  # no file, but installed.json.corrupt is there
STATE_DIRTY=0     # a mark or choice changed something since state_load
STATE_ERROR=""    # why state_load failed
STATE_HAS_CI=0    # .tiers.ci is recorded
STATE_BASE=""     # recorded choices ("" = not recorded)
STATE_CRON=""
STATE_STRICT=""
STATE_WF=""       # one line per workflow: name US state US intentional US installed_at

# One jq pass: validate the shape, then emit the choices line and one line
# per workflow, fields separated by US (\037), which no value may contain.
# shellcheck disable=SC2016  # jq program, not shell expansions
_STATE_READ_JQ='
  def s: tostring | gsub("[\u0000-\u001f]"; "");
  if type != "object" then error("the top level is not a JSON object")
  elif (.schema_version // 1 | type) != "number" then error(".schema_version is not a number")
  elif (.schema_version // 1) > ($max | tonumber) then error("schema_version \(.schema_version) was written by a newer doc-superpowers installer; upgrade the plugin")
  elif (.tiers // {} | type) != "object" then error(".tiers is not an object")
  elif (.tiers.ci // {} | type) != "object" then error(".tiers.ci is not an object")
  elif (.tiers.ci.workflows // {} | type) != "object" then error(".tiers.ci.workflows is not an object")
  elif ([(.tiers.ci.workflows // {})[] | type] | any(. != "object")) then error("a .tiers.ci.workflows entry is not an object")
  else
    .tiers.ci as $ci
    | ([ (if $ci == null then "0" else "1" end),
         ($ci.base_branch // "" | s), ($ci.cron // "" | s),
         (if $ci == null or ($ci | has("ci_strict") | not) then "" else ($ci.ci_strict | s) end)
       ] | join("\u001f")),
      (($ci.workflows // {}) | to_entries[]
       | [ (.key | s), (.value.state // "" | s), (.value.intentional // false | s), (.value.installed_at // "" | s) ]
       | join("\u001f"))
  end'

# state_load: read the state file once. Returns 1 (STATE_ERROR says why) when
# it exists but cannot be used; the caller must then write nothing.
state_load() {
  STATE_PRESENT=0 STATE_RECOVERY=0 STATE_DIRTY=0 STATE_ERROR="" STATE_HAS_CI=0
  STATE_BASE="" STATE_CRON="" STATE_STRICT="" STATE_WF=""
  if [ ! -e "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ]; then
    if [ -e "$STATE_CORRUPT" ]; then
      STATE_RECOVERY=1
    fi
    return 0
  fi
  local out first
  if ! out=$(jq -r --arg max "$STATE_SCHEMA" "$_STATE_READ_JQ" "$STATE_FILE" 2>&1); then
    STATE_ERROR=$(printf '%s\n' "$out" | sed -n '1{s/^jq: error ([^)]*): //;s/^jq: error: //;p;}')
    STATE_ERROR="${STATE_ERROR:-not valid JSON}"
    return 1
  fi
  if [ -z "$out" ]; then
    STATE_ERROR="the file is empty"
    return 1
  fi
  STATE_PRESENT=1
  first="${out%%$'\n'*}"
  IFS="$_SEP" read -r STATE_HAS_CI STATE_BASE STATE_CRON STATE_STRICT <<<"$first"
  case "$out" in
    *$'\n'*) STATE_WF="${out#*$'\n'}" ;;
  esac
  return 0
}

# state_wf_get <name>: WF_STATE, WF_INTENT, WF_AT of <name> ("" if unrecorded).
state_wf_get() {
  local l
  WF_STATE="" WF_INTENT="" WF_AT=""
  [ -n "$STATE_WF" ] || return 1
  while IFS= read -r l; do
    case "$l" in
      "$1$_SEP"*)
        IFS="$_SEP" read -r _ WF_STATE WF_INTENT WF_AT <<<"$l"
        return 0
        ;;
    esac
  done <<<"$STATE_WF"
  return 1
}

# The recorded workflow names, one per line, in file order.
state_wf_names() {
  local l
  [ -n "$STATE_WF" ] || return 0
  while IFS= read -r l; do
    printf '%s\n' "${l%%"$_SEP"*}"
  done <<<"$STATE_WF"
}

# _state_wf_put <name> <state> <intentional> <installed_at>: replace or append.
_state_wf_put() {
  local new="$1$_SEP$2$_SEP$3$_SEP$4" l out="" found=0
  if [ -n "$STATE_WF" ]; then
    while IFS= read -r l; do
      case "$l" in
        "$1$_SEP"*)
          [ "$l" = "$new" ] || STATE_DIRTY=1
          l="$new"
          found=1
          ;;
      esac
      out="${out:+$out$'\n'}$l"
    done <<<"$STATE_WF"
  fi
  if [ "$found" = 0 ]; then
    out="${out:+$out$'\n'}$new"
    STATE_DIRTY=1
  fi
  STATE_WF="$out"
}

# Installed: keeps installed_at when it already was (a refresh is no change).
state_mark_installed() {
  state_wf_get "$1" || true
  if [ "$WF_STATE" = "installed" ]; then
    _state_wf_put "$1" installed false "$WF_AT"
  else
    _state_wf_put "$1" installed false "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
}

# Uninstalled; $2 = "true" (on purpose: a plain install skips it) or "false".
state_mark_uninstalled() {
  _state_wf_put "$1" uninstalled "$2" ""
}

# state_set_choices <base_branch> <cron> <true|false>
state_set_choices() {
  if [ "$STATE_HAS_CI" != 1 ] || [ "$1" != "$STATE_BASE" ] || [ "$2" != "$STATE_CRON" ] || [ "$3" != "$STATE_STRICT" ]; then
    STATE_DIRTY=1
  fi
  STATE_HAS_CI=1 STATE_BASE="$1" STATE_CRON="$2" STATE_STRICT="$3"
}

# shellcheck disable=SC2016  # jq program
_STATE_WRITE_JQ='
  .schema_version = ($schema | tonumber)
  | .tiers = (.tiers // {})
  | .tiers.ci = ((.tiers.ci // {}) | del(.tools, .helpers)
      | (if $b != "" then .base_branch = $b else . end)
      | (if $c != "" then .cron = $c else . end)
      | (if $s != "" then .ci_strict = ($s == "true") else . end)
      | .workflows = (reduce ($wf | split("\n")[] | select(length > 0) | split("\u001f")) as $r ({};
          .[$r[0]] = (if $r[1] == "installed"
                      then {state: "installed"} + (if ($r[3] // "") != "" then {installed_at: $r[3]} else {} end)
                      else {state: "uninstalled", intentional: ($r[2] == "true")} end))))'

# state_flush: write the state once, and only when something changed (the
# first write of a version 1 file migrates it). Callers flush BEFORE they
# delete a workflow, so an interrupted uninstall leaves the removal recorded.
state_flush() {
  [ "$STATE_DIRTY" = 1 ] || [ "$STATE_PRESENT" = 1 ] || return 0
  local new src="$STATE_FILE"
  [ "$STATE_PRESENT" = 1 ] || src=/dev/null
  if [ "$STATE_PRESENT" = 1 ]; then
    new=$(jq --arg schema "$STATE_SCHEMA" --arg b "$STATE_BASE" --arg c "$STATE_CRON" --arg s "$STATE_STRICT" \
      --arg wf "$STATE_WF" "$_STATE_WRITE_JQ" "$src") || die "cannot update $STATE_FILE"
    [ "$new" != "$(cat "$STATE_FILE")" ] || return 0
  else
    new=$(jq -n --arg schema "$STATE_SCHEMA" --arg b "$STATE_BASE" --arg c "$STATE_CRON" --arg s "$STATE_STRICT" \
      --arg wf "$STATE_WF" "{} | $_STATE_WRITE_JQ") || die "cannot build $STATE_FILE"
  fi
  tmp_beside "$STATE_FILE"
  printf '%s\n' "$new" > "$_TMP"
  commit_tmp "$STATE_FILE" 644
  STATE_PRESENT=1 STATE_DIRTY=0
}
