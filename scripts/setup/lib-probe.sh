#!/usr/bin/env bash
# doc-superpowers setup: the probe. Sourced by setup.sh after lib-model.sh,
# whose loaded catalog it reads (CAT_*: option order, defaults). Read-only: it
# never writes a file. ROOT is the plugin root (setup.sh sets it).
#
# probe_run, from anywhere in a work tree, sets:
#   TOP                 the repository top (git rev-parse --show-toplevel): a
#                       linked worktree's own top
#   PROBE_STATUS        the JSON of install.sh status --json --git --claude
#                       --ci --search (all four tiers named: --search alone
#                       reports only doc-search)
#   PROBE_TEAM          the team record's .setup (installed.json), compact
#                       JSON, or empty: no team setup recorded (a CI-only
#                       record included)
#   PROBE_LOCAL         the local record (installed.local.json), compact
#                       JSON, or empty
#   PROBE_RECORD_ERROR  why a record cannot be used, or empty: state.sh's own
#                       reason when it refuses installed.json (status --json
#                       still exits 0, with .tiers.ci.state_readable false and
#                       .tiers.ci.state_error), or a .setup or local record
#                       setup cannot read. The caller must then write nothing.
#   PROBE_TEAM_VALUES   .setup as "<id>=<value>" lines, in the model's values
#   PROBE_LOCAL_VALUES  the local record's overrides, as "<id>=<value>" lines
#   PROBE_ERROR         why probe_run returned 1 (not a work tree; the
#                       installer's status failed)
#   HOST_NO_BUILD       why this host cannot build doc-search's indexes
#                       ("uv not found"), or empty. It disables the build, not
#                       the doc-search item: setup writes the config, the
#                       launcher and the entries without uv.
#   DISABLED[i]         (the terminal command) why this host cannot offer an
#                       item at all; DISABLED_OPT (lib-model.sh): the options
#                       it cannot offer while the item stays usable, one
#                       "<id>=<option>TAB<reason>" line each: gte (arm64 macOS
#                       below 14, a host that is neither macOS nor Linux) and
#                       the git tier's hooks mode (a global or system
#                       core.hooksPath, or a local one inside the work tree).
#                       A check that cannot decide disables nothing. They are
#                       the only things a host check does: it never changes a
#                       selection (probe_host_checks).
#   HINT[i]             what the repository suggests, for the lists and the
#                       summary (probe_hints). A hint never changes SEL or
#                       BASE, and nothing reads it but the renderers.
# Then, from what status --json and the files on disk say:
#   probe_installed <id>  the installed value, in the item's value space (the
#                         default for a value nothing records)
#   probe_state <id>      current | outdated (in place, but partly, or another
#                         version's: an install refreshes it) | absent

# The harness entries (what is present in each harness's project file).
# shellcheck source=scripts/setup/lib-harness.sh
source "$ROOT/scripts/setup/lib-harness.sh"

_PROBE_US=$'\037'
PROBE_STATE_FILE=".claude/doc-superpowers/installed.json"
PROBE_LOCAL_FILE=".claude/doc-superpowers/installed.local.json"
PROBE_SHIM_MARKER="# doc-superpowers terminal shim v1"
PROBE_GTE_MODEL="transformer:gte-modernbert-base"

TOP=""
PROBE_STATUS="" PROBE_TEAM="" PROBE_LOCAL="" PROBE_RECORD_ERROR="" PROBE_ERROR=""
PROBE_TEAM_VALUES="" PROBE_LOCAL_VALUES=""
HOST_NO_BUILD=""
_PB_OS="" _PB_ARCH=""
_PB_HP_FOREIGN=false _PB_HP_SCOPE="" _PB_HP_DIR=""
_PB_CORPUS_N=0 _PB_CORPUS_BYTES=0

# The facts probe_installed and probe_state read (set by probe_run).
_PB_GIT_HOOKS=""     # "<hook>:<state> ..." (references/hooks.md lists the states)
_PB_MD=absent        # the merge driver's state
_PB_ATTR=absent      # the .gitattributes block's state
_PB_CLAUDE=""        # "<hook>:<state> ..."
_PB_CI_READABLE=true
_PB_CI_ERROR=""
_PB_CI_WF=""         # "<workflow>:<state> ..."
_PB_CI_CHOSEN=0      # 1 when installed.json records CI choices
_PB_CI_BASE="" _PB_CI_CRON="" _PB_CI_STRICT=false
_PB_LAUNCHER=absent _PB_MCP=absent
_PB_SEARCH_MODEL=static
_PB_LOCAL_CACHE=host
_PB_HARNESSES=none   # a CSV in catalog order
_PB_LEDGER_GIT=""    # "<hook>:<current|outdated|absent> ..."
_PB_LEDGER_CLAUDE=""

# status --json in one pass: one line, fields separated by US (control
# characters, the separator among them, become spaces).
# shellcheck disable=SC2016  # jq program, not shell expansions
_PROBE_STATUS_JQ='
  def s: tostring | gsub("[\u0000-\u001f]"; " ");
  def states($o): [($o // {}) | to_entries[] | .key + ":" + (.value.state // "absent")] | join(" ");
  .tiers as $t
  | [ states($t.git.hooks),
      ($t.git.merge_driver.state // "absent"),
      ($t.git.gitattributes.state // "absent"),
      states($t.claude.hooks),
      (if $t.ci.state_readable == false then "false" else "true" end),
      ($t.ci.state_error // ""),
      states($t.ci.workflows),
      (if $t.ci.choices == null then "0" else "1" end),
      ($t.ci.choices.base_branch // ""),
      ($t.ci.choices.cron // ""),
      (if $t.ci.choices.ci_strict == true then "true" else "false" end),
      ($t.search.launcher // "absent"),
      ($t.search.mcp_entry // "absent"),
      (if $t.git.hooks_path_foreign == true then "true" else "false" end),
      ($t.git.hooks_path_scope // ""),
      ($t.git.hooks_dir // "")
    ] | map(s) | join("\u001f")'

# installed.json's .setup (design §6.1): its compact JSON on the first line,
# then "<id>=<value>" lines; nothing when there is no .setup. A key the record
# lacks gives no line (the item is then as installed). Anything setup cannot
# read is an error.
# shellcheck disable=SC2016  # jq program, not shell expansions
_PROBE_TEAM_JQ='
  def bad($m): error(".setup: " + $m);
  def onoff($k): if type == "boolean" then (if . then "on" else "off" end) else bad("\($k) is not true or false") end;
  if length != 1 then error("it is not one JSON value") else .[0] end
  | if type != "object" then error("the top level is not a JSON object") else . end
  | .setup as $s
  | if $s == null then empty
    elif ($s | type) != "object" then bad("it is not an object")
    elif ($s.format // 1 | type) != "number" then bad("format is not a number")
    elif ($s.format // 1) > 1 then bad("format \($s.format) was written by a newer doc-superpowers setup; upgrade the plugin")
    else
      ($s | tojson),
      (if $s | has("harnesses") then
         ($s.harnesses
          | if type == "array" and all(.[]; type == "string" and (contains(",") | not))
            then "harness=" + (if length == 0 then "none" else join(",") end)
            else bad("harnesses is not a list of names (\(tojson))") end)
       else empty end),
      (if $s | has("git") then
         ($s.git | if type == "string" then "git=" + . else bad("git is not a string") end)
       else empty end),
      (if $s | has("claude") then "claude=" + ($s.claude | onoff("claude")) else empty end),
      (if $s | has("search") then
         ($s.search
          | if . == null then "search=off", "search.model=static"
            elif type == "object" then
              "search=on",
              ("search.model=" + (.model // "static"
                | if . == "static" then "static"
                  elif . == $gte then "gte"
                  else bad("search.model \(tojson) is neither \"static\" nor \"\($gte)\"") end))
            else bad("search is neither null nor an object") end)
       else empty end),
      (if $s | has("ledger") then
         ($s.ledger
          | if . == null then "ledger=off", "ledger.git=off", "ledger.claude=off"
            elif type == "object" then
              "ledger=on",
              ("ledger.git=" + (.git // false | onoff("ledger.git"))),
              ("ledger.claude=" + (.claude // false | onoff("ledger.claude")))
            else bad("ledger is neither null nor an object") end)
       else empty end),
      (if $s | has("claims") then "claims=" + ($s.claims | onoff("claims")) else empty end)
    end'

# installed.local.json (design §6.2): its compact JSON, the cache line
# ("search.cache=host|/abs"), then one "<id>=<value>" line per override of a
# per-user item (git, claude, ledger.git, ledger.claude; other keys ignored).
# shellcheck disable=SC2016  # jq program, not shell expansions
_PROBE_LOCAL_JQ='
  if length != 1 then error("it is not one JSON value") else .[0] end
  | if type != "object" then error("the top level is not a JSON object")
    elif (.format // 1 | type) != "number" then error("format is not a number")
    elif (.format // 1) > 1 then error("format \(.format) was written by a newer doc-superpowers setup; upgrade the plugin")
    elif (.overrides // {} | type) != "object" then error("overrides is not an object")
    elif (.search // {} | type) != "object" then error("search is not an object")
    else
      tojson,
      ("search.cache=" + ((.search // {}).cache
        | if . == null then "host"
          elif type == "string" and startswith("/") and (test("[\u0000-\u001f]") | not) then .
          else error("search.cache \(tojson) is neither null nor an absolute path") end)),
      ((.overrides // {}) | to_entries[] | .key as $k | .value as $v
       | if $k == "git" then
           (if ($v | type) == "string" then "git=" + $v else error("overrides.git is not a string") end)
         elif $k == "claude" or $k == "ledger.git" or $k == "ledger.claude" then
           (if ($v | type) == "boolean" then $k + "=" + (if $v then "on" else "off" end)
            else error("overrides.\($k) is not true or false") end)
         else empty end)
    end'

# A jq error's message, without jq's "jq: error (at <file>:N): " prefix.
_probe_jq_error() {
  local m
  m=$(printf '%s\n' "$1" | sed -n '1{s/^jq: error ([^)]*): //;s/^jq: error: //;p;}')
  printf '%s' "${m:-not valid JSON}"
}

# The ledger sets have no JSON status (status --json refuses --ledger), so
# their verdicts are read from status --ledger --ledger-claude's lines: per
# hook, its first line in its section, by its glyph (a check mark: current; a
# warning sign: outdated; a cross: absent).
_probe_ledger_parse() {
  local line sec="" glyph name rest st g="" c=""
  local ok=$'\xe2\x9c\x93' warn=$'\xe2\x9a\xa0' no=$'\xe2\x9c\x97'
  while IFS= read -r line; do
    case "$line" in
      "Ledger git hooks"*)
        sec=git
        continue
        ;;
      "Ledger Claude Code hooks"*)
        sec=claude
        continue
        ;;
      "")
        sec=""
        continue
        ;;
    esac
    [ -n "$sec" ] || continue
    read -r glyph name rest <<<"$line" || true
    case "$glyph" in
      "$ok") st=current ;;
      "$warn") st=outdated ;;
      "$no") st=absent ;;
      *) continue ;;
    esac
    case "$sec:$name" in
      git:pre-commit | git:pre-push | git:post-commit)
        case " $g " in
          *" $name:"*) ;;
          *) g="$g $name:$st" ;;
        esac
        ;;
      claude:ledger-session-notices | claude:ledger-state-watch)
        case " $c " in
          *" $name:"*) ;;
          *) c="$c $name:$st" ;;
        esac
        ;;
    esac
  done <<<"$1"
  _PB_LEDGER_GIT="${g# }"
  _PB_LEDGER_CLAUDE="${c# }"
}

# shellcheck disable=SC2034  # PROBE_* are the probe's interface, read by setup.sh and lib-model.sh
probe_run() {
  local out line rest h hh
  TOP="" PROBE_STATUS="" PROBE_TEAM="" PROBE_LOCAL="" PROBE_RECORD_ERROR="" PROBE_ERROR=""
  PROBE_TEAM_VALUES="" PROBE_LOCAL_VALUES=""
  if ! TOP=$(git rev-parse --show-toplevel 2>/dev/null) || [ -z "$TOP" ]; then
    TOP=""
    PROBE_ERROR="not a git repository (run setup inside a repository's work tree)"
    return 1
  fi
  # status --json exits 0 even for a record state.sh refuses (below).
  if ! out=$(cd "$TOP" && "$BASH" "$ROOT/scripts/hooks/install.sh" status --json --git --claude --ci --search </dev/null 2>/dev/null); then
    out=$(cd "$TOP" && "$BASH" "$ROOT/scripts/hooks/install.sh" status --json --git --claude --ci --search </dev/null 2>&1 >/dev/null) || true
    PROBE_ERROR="install.sh status --json failed: ${out%%$'\n'*}"
    return 1
  fi
  if ! line=$(jq -r "$_PROBE_STATUS_JQ" <<<"$out" 2>/dev/null) || [ -z "$line" ]; then
    PROBE_ERROR="install.sh status --json did not print its JSON object"
    return 1
  fi
  PROBE_STATUS="$out"
  IFS="$_PROBE_US" read -r _PB_GIT_HOOKS _PB_MD _PB_ATTR _PB_CLAUDE _PB_CI_READABLE _PB_CI_ERROR \
    _PB_CI_WF _PB_CI_CHOSEN _PB_CI_BASE _PB_CI_CRON _PB_CI_STRICT _PB_LAUNCHER _PB_MCP \
    _PB_HP_FOREIGN _PB_HP_SCOPE _PB_HP_DIR <<<"$line"

  # The team record: refused as state.sh refuses it, else its .setup.
  if [ "$_PB_CI_READABLE" != true ]; then
    PROBE_RECORD_ERROR="$PROBE_STATE_FILE cannot be used: ${_PB_CI_ERROR:-it cannot be read}"
  elif [ -e "$TOP/$PROBE_STATE_FILE" ]; then
    if out=$(jq -rs --arg gte "$PROBE_GTE_MODEL" "$_PROBE_TEAM_JQ" "$TOP/$PROBE_STATE_FILE" 2>&1); then
      if [ -n "$out" ]; then
        PROBE_TEAM="${out%%$'\n'*}"
        case "$out" in
          *$'\n'*) PROBE_TEAM_VALUES="${out#*$'\n'}" ;;
        esac
      fi
    else
      PROBE_RECORD_ERROR="$PROBE_STATE_FILE cannot be used: $(_probe_jq_error "$out")"
    fi
  fi

  # The local record.
  _PB_LOCAL_CACHE=host
  if [ -e "$TOP/$PROBE_LOCAL_FILE" ] || [ -L "$TOP/$PROBE_LOCAL_FILE" ]; then
    if out=$(jq -rs "$_PROBE_LOCAL_JQ" "$TOP/$PROBE_LOCAL_FILE" 2>&1); then
      PROBE_LOCAL="${out%%$'\n'*}"
      rest="${out#*$'\n'}"
      line="${rest%%$'\n'*}"
      _PB_LOCAL_CACHE="${line#search.cache=}"
      case "$rest" in
        *$'\n'*) PROBE_LOCAL_VALUES="${rest#*$'\n'}" ;;
      esac
    elif [ -z "$PROBE_RECORD_ERROR" ]; then
      PROBE_RECORD_ERROR="$PROBE_LOCAL_FILE cannot be used: $(_probe_jq_error "$out")"
    fi
  fi

  # doc-search's model, from its config.
  _PB_SEARCH_MODEL=static
  if [ -f "$TOP/docs/search/config.json" ]; then
    out=$(jq -r '.docs.model // "" | tostring' "$TOP/docs/search/config.json" 2>/dev/null) || out=""
    [ "$out" != "$PROBE_GTE_MODEL" ] || _PB_SEARCH_MODEL=gte
  fi

  # The harnesses whose doc-search entry is present, in catalog order.
  h=""
  case "$_PB_MCP" in
    registered | different-command) h=claude-code ;;
  esac
  # The others, by lib-harness.sh: setup's own Codex block (an unmarked table
  # is the user's, not an entry of ours) and the "doc-search" key of the JSON
  # files.
  for hh in codex cursor opencode gemini; do
    if harness_entry_present "$hh"; then h="$h,$hh"; fi
  done
  h="${h#,}"
  _PB_HARNESSES="${h:-none}"

  # The ledger's two hook sets.
  out=$(cd "$TOP" && "$BASH" "$ROOT/scripts/hooks/install.sh" status --ledger --ledger-claude </dev/null 2>/dev/null) || out=""
  _probe_ledger_parse "$out"

  # The host checks: the build runs doc-search through uv.
  HOST_NO_BUILD=""
  command -v uv >/dev/null 2>&1 || HOST_NO_BUILD="uv not found"
  probe_host_checks
  probe_hints
  return 0
}

# _probe_disable_opt <id> <option> <reason>: one DISABLED_OPT line.
_probe_disable_opt() {
  local r="${3//$'\t'/ }"
  r="${r//$'\n'/ }"
  DISABLED_OPT="${DISABLED_OPT:+$DISABLED_OPT$'\n'}$1=$2"$'\t'"$r"
}

# _probe_hooks_dir_inside: 0, with _PHD (the folder, relative to the top),
# when core.hooksPath is this repository's own (local or worktree scope) and
# points at a folder inside the work tree that is not under .git. git hands
# the folder back as written (relative to the top) or absolute.
_probe_hooks_dir_inside() {
  local d="$_PB_HP_DIR" t phys rel=""
  _PHD=""
  case "$_PB_HP_SCOPE" in
    local | worktree) ;;
    *) return 1 ;;
  esac
  [ -n "$d" ] || return 1
  case "$d" in
    /*)
      phys=$(cd "$d" 2>/dev/null && pwd -P) || phys=""
      for t in "$TOP" "$(cd "$TOP" 2>/dev/null && pwd -P)"; do
        [ -n "$t" ] || continue
        case "$d" in
          "$t"/*)
            rel="${d#"$t"/}"
            break
            ;;
        esac
        case "$phys" in
          "$t"/*)
            rel="${phys#"$t"/}"
            break
            ;;
        esac
      done
      ;;
    .. | ../*) ;;
    *) rel="${d#./}" ;;
  esac
  while :; do
    case "$rel" in
      */) rel="${rel%/}" ;;
      *) break ;;
    esac
  done
  case "$rel" in
    "" | . | .git | .git/* | ..*/* | */../*) return 1 ;;
  esac
  _PHD="$rel"
}

# probe_host_checks: what this host cannot do, as reasons that disable and
# never decide (design §5.4): DISABLED_OPT (gte, the git tier's hooks mode)
# and DISABLED[] of the terminal command. A check that cannot decide (no
# uname, no version) disables nothing.
# shellcheck disable=SC2034  # DISABLED is the probe's interface, read by setup.sh and the renderers
probe_host_checks() {
  local ver major val f bindir why
  DISABLED_OPT=""
  _PB_OS=$(uname -s 2>/dev/null) || _PB_OS=""
  _PB_ARCH=$(uname -m 2>/dev/null) || _PB_ARCH=""
  case "$_PB_OS" in
    Darwin)
      if [ "$_PB_ARCH" = arm64 ]; then
        ver=$(sw_vers -productVersion 2>/dev/null) || ver=""
        major="${ver%%.*}"
        case "$major" in
          "" | *[!0-9]*) ;;
          *)
            if [ "$major" -lt 14 ]; then
              _probe_disable_opt search.model gte "onnxruntime 1.31 needs macOS 14 (this Mac runs macOS $ver); the static model works"
            fi
            ;;
        esac
      fi
      ;;
    Linux | "") ;;
    *) _probe_disable_opt search.model gte "the gte model runs on macOS and Linux only (this host is $_PB_OS); the static model works" ;;
  esac

  if [ "$_PB_HP_FOREIGN" = true ]; then
    val=$(cd "$TOP" && git config --get core.hooksPath 2>/dev/null) || val=""
    _probe_disable_opt git hooks "core.hooksPath is set in your ${_PB_HP_SCOPE:-global} git config${val:+ ($val)}: git runs every repository's hooks from there, so install --git refuses it; the merge driver alone can be installed"
  elif _probe_hooks_dir_inside; then
    _probe_disable_opt git hooks "core.hooksPath is $_PHD/, a folder inside this repository: install --git would write the hooks there, and they would be committed with this machine's plugin path; the merge driver alone stays"
  fi

  # The terminal command.
  if _model_i bin; then
    DISABLED[_MI]=""
    if [ -n "${HOME:-}" ]; then
      bindir="$HOME/.local/bin"
      f="$bindir/doc-superpowers"
      why=""
      if [ -e "$bindir" ] && [ ! -d "$bindir" ]; then
        # shellcheck disable=SC2088  # display text: the folder, as a user writes it
        why="~/.local/bin is not a directory"
      elif [ -d "$bindir" ] && [ ! -w "$bindir" ]; then
        # shellcheck disable=SC2088  # display text: the folder, as a user writes it
        why="~/.local/bin is not writable"
      elif { [ -e "$f" ] || [ -L "$f" ]; } && ! _probe_bin_ours; then
        # shellcheck disable=SC2088  # display text: the file, as a user writes it
        why="~/.local/bin/doc-superpowers exists and is not setup's shim (line 2 is not \"$PROBE_SHIM_MARKER\"); setup leaves it alone"
      fi
      DISABLED[_MI]="$why"
    fi
  fi
  return 0
}

# _probe_corpus: _PB_CORPUS_N and _PB_CORPUS_BYTES, the default docs corpus
# (docs.include docs/**/*.md and *.md, docs.exclude docs/archive/** and the
# doc index) among the files git lists. Nothing is read from a remote.
_probe_corpus() {
  local list
  _PB_CORPUS_N=0 _PB_CORPUS_BYTES=0
  list=$(cd "$TOP" && git -c core.quotepath=off ls-files --cached --others --exclude-standard 2>/dev/null |
    awk '/\.md$/ && index($0, "docs/archive/") != 1' || true)
  [ -n "$list" ] || return 0
  _PB_CORPUS_N=$(printf '%s\n' "$list" | wc -l | tr -d ' ')
  _PB_CORPUS_BYTES=$(cd "$TOP" && printf '%s\n' "$list" | tr '\n' '\0' | xargs -0 cat 2>/dev/null | wc -c | tr -d ' ') || _PB_CORPUS_BYTES=0
  [ -n "$_PB_CORPUS_BYTES" ] || _PB_CORPUS_BYTES=0
}

# _probe_duration <seconds>: _PD = "N s", "N min" or "H h M min", rounded up.
_probe_duration() {
  local s="$1" m h
  [ "$s" -ge 1 ] || s=1
  if [ "$s" -lt 90 ]; then
    _PD="$s s"
  elif [ "$s" -lt 5400 ]; then
    _PD="$(((s + 59) / 60)) min"
  else
    m=$(((s + 59) / 60))
    h=$((m / 60))
    m=$((m % 60))
    if [ "$m" -eq 0 ]; then _PD="$h h"; else _PD="$h h $m min"; fi
  fi
}

# probe_hints: HINT[i] per item, from the repository and the host: shown in
# --list's last column and under the summary, never applied (design §5.4).
# shellcheck disable=SC2034  # HINT is the probe's interface, read by setup.sh and the renderers
probe_hints() {
  local i=0 h="" f rate chunks secs url found=0
  while [ "$i" -lt "$CAT_N" ]; do
    HINT[i]=""
    i=$((i + 1))
  done
  _probe_corpus
  if _model_i search; then
    HINT[_MI]="$_PB_CORPUS_N docs (default corpus)"
  fi
  # A first gte build: the corpus bytes over semble's ~750-character chunks,
  # at the per-host rates references/search.md gives; no estimate elsewhere.
  if _model_i search.model && ! model_option_disabled search.model gte; then
    rate=""
    case "$_PB_OS:$_PB_ARCH" in
      Darwin:arm64) rate=160 ;;
      Darwin:x86_64) rate=36 ;;
    esac
    if [ -n "$rate" ]; then
      chunks=$(((_PB_CORPUS_BYTES + 749) / 750))
      secs=$(((chunks * 10 + rate - 1) / rate))
      _probe_duration "$secs"
      HINT[_MI]="a gte first build: about $_PD here"
    fi
  fi
  if _model_i harness; then
    for f in .cursor/ .codex/ .gemini/ opencode.json; do
      if [ -e "$TOP/${f%/}" ]; then h="${h:+$h, }$f"; fi
    done
    [ -z "$h" ] || HINT[_MI]="detected: $h"
  fi
  if _model_i git && [ ! -e "$TOP/docs/.doc-index.json" ]; then
    HINT[_MI]="no doc index yet: run /doc-superpowers init"
  fi
  if _model_i ci.workflows; then
    while IFS= read -r url; do
      case "$url" in
        *github.com*) found=1 ;;
      esac
    done < <(cd "$TOP" && git config --get-regexp '^remote\..*\.url$' 2>/dev/null || true)
    [ "$found" = 1 ] || HINT[_MI]="no GitHub remote"
  fi
  if _model_i claims && [ -d "$TOP/docs/spec-claims" ]; then
    HINT[_MI]="docs/spec-claims/ already present: its pre-commit leg blocks on findings"
  fi
  return 0
}

# _probe_git: _PG_VALUE (hooks | merge-driver | off) and _PG_STATE. A hook of
# ours counts whatever its state (an outdated one is still installed); hooks
# is current when all 5 are installed or integrated and the driver is
# registered and configured. The driver counts when git config registers one
# (even another install's) or .gitattributes routes the index to it (a fresh
# clone of a repository that committed the block).
_probe_git() {
  local p n=0 ours=0 cur=0 driver=0 driver_cur=0
  for p in $_PB_GIT_HOOKS; do
    n=$((n + 1))
    case "${p#*:}" in
      installed | integrated)
        ours=$((ours + 1))
        cur=$((cur + 1))
        ;;
      not-executable | outdated | integrated-copy-outdated | integrated-block-outdated) ours=$((ours + 1)) ;;
    esac
  done
  case "$_PB_MD" in
    registered | script-missing | pinned | other) driver=1 ;;
  esac
  [ "$_PB_ATTR" != configured ] || driver=1
  if [ "$_PB_MD" = registered ] && [ "$_PB_ATTR" = configured ]; then driver_cur=1; fi
  if [ "$ours" -gt 0 ]; then
    _PG_VALUE=hooks
    if [ "$cur" -eq "$n" ] && [ "$driver_cur" = 1 ]; then _PG_STATE=current; else _PG_STATE=outdated; fi
  elif [ "$driver" = 1 ]; then
    _PG_VALUE=merge-driver
    if [ "$driver_cur" = 1 ]; then _PG_STATE=current; else _PG_STATE=outdated; fi
  else
    _PG_VALUE=off
    _PG_STATE=absent
  fi
}

# _probe_agg "<name>:<state> ..." <current state word>: _PA_ON (1 when any is
# in place) and _PA_STATE (absent when none is; current when all are current).
_probe_agg() {
  local p all=1
  _PA_ON=0
  for p in $1; do
    case "${p#*:}" in
      absent) all=0 ;;
      "$2") _PA_ON=1 ;;
      *)
        _PA_ON=1
        all=0
        ;;
    esac
  done
  if [ "$_PA_ON" = 0 ]; then
    _PA_STATE=absent
  elif [ "$all" = 1 ]; then
    _PA_STATE=current
  else
    _PA_STATE=outdated
  fi
}

# The installed workflows (on disk, or recorded installed and missing), in
# catalog order.
_probe_ci_workflows() {
  local o p out="" st
  _model_i ci.workflows || return 1
  for o in ${CAT_OPTIONS[_MI]//,/ }; do
    st=absent
    for p in $_PB_CI_WF; do
      [ "${p%%:*}" != "$o" ] || st="${p#*:}"
    done
    case "$st" in
      installed | recorded-missing) out="${out:+$out,}$o" ;;
    esac
  done
  _PC_WF="${out:-none}"
  _PC_STATE=absent
  if [ -n "$out" ]; then
    _PC_STATE=current
    case " $_PB_CI_WF " in
      *":recorded-missing "*) _PC_STATE=outdated ;;
    esac
  fi
}

# The terminal command: ~/.local/bin/doc-superpowers with the shim's marker
# on line 2 (anything else there is the user's).
_probe_bin_ours() {
  local f="${HOME:-}/.local/bin/doc-superpowers" l2=""
  [ -f "$f" ] || return 1
  { IFS= read -r _ || true; IFS= read -r l2 || true; } 2>/dev/null <"$f" || return 1
  [ "$l2" = "$PROBE_SHIM_MARKER" ]
}

# _probe_default <id>: the catalog default.
_probe_default() {
  _model_i "$1" || return 1
  printf '%s\n' "${CAT_DEFAULT[_MI]}"
}

probe_installed() {
  case "$1" in
    harness) printf '%s\n' "$_PB_HARNESSES" ;;
    search)
      if [ -f "$TOP/docs/search/config.json" ]; then echo on; else echo off; fi
      ;;
    search.model) echo "$_PB_SEARCH_MODEL" ;;
    search.cache) printf '%s\n' "$_PB_LOCAL_CACHE" ;;
    git)
      _probe_git
      echo "$_PG_VALUE"
      ;;
    claude)
      _probe_agg "$_PB_CLAUDE" active
      if [ "$_PA_ON" = 1 ]; then echo on; else echo off; fi
      ;;
    ci.workflows)
      _probe_ci_workflows || return 1
      echo "$_PC_WF"
      ;;
    ci.base_branch)
      if [ "$_PB_CI_CHOSEN" = 1 ] && [ -n "$_PB_CI_BASE" ]; then printf '%s\n' "$_PB_CI_BASE"; else _probe_default "$1"; fi
      ;;
    ci.cron)
      if [ "$_PB_CI_CHOSEN" = 1 ] && [ -n "$_PB_CI_CRON" ]; then printf '%s\n' "$_PB_CI_CRON"; else _probe_default "$1"; fi
      ;;
    ci.strict)
      if [ "$_PB_CI_STRICT" = true ]; then echo on; else echo off; fi
      ;;
    ledger)
      if [ -f "$TOP/docs/ledger/config.json" ]; then echo on; else echo off; fi
      ;;
    ledger.git | ledger.claude)
      if [ "$1" = ledger.git ]; then _probe_agg "$_PB_LEDGER_GIT" current; else _probe_agg "$_PB_LEDGER_CLAUDE" current; fi
      if [ "$_PA_ON" = 1 ]; then echo on; else echo off; fi
      ;;
    claims)
      if [ -d "$TOP/docs/spec-claims" ]; then echo on; else echo off; fi
      ;;
    bin)
      if _probe_bin_ours; then echo on; else echo off; fi
      ;;
    *) return 1 ;;
  esac
}

probe_state() {
  case "$1" in
    harness)
      if [ "$_PB_HARNESSES" = none ]; then
        echo absent
      elif [ "$_PB_MCP" = different-command ]; then
        echo outdated
      else
        echo current
      fi
      ;;
    search | search.model | search.cache)
      if [ ! -f "$TOP/docs/search/config.json" ]; then
        echo absent
      elif [ "$_PB_LAUNCHER" = installed ] && [ "$_PB_MCP" = registered ]; then
        echo current
      else
        echo outdated
      fi
      ;;
    git)
      _probe_git
      echo "$_PG_STATE"
      ;;
    claude)
      _probe_agg "$_PB_CLAUDE" active
      echo "$_PA_STATE"
      ;;
    ci.workflows | ci.base_branch | ci.cron | ci.strict)
      _probe_ci_workflows || return 1
      echo "$_PC_STATE"
      ;;
    ledger)
      if [ -f "$TOP/docs/ledger/config.json" ]; then echo current; else echo absent; fi
      ;;
    ledger.git)
      _probe_agg "$_PB_LEDGER_GIT" current
      echo "$_PA_STATE"
      ;;
    ledger.claude)
      _probe_agg "$_PB_LEDGER_CLAUDE" current
      echo "$_PA_STATE"
      ;;
    claims)
      if [ -d "$TOP/docs/spec-claims" ]; then echo current; else echo absent; fi
      ;;
    bin)
      if _probe_bin_ours; then echo current; else echo absent; fi
      ;;
    *) return 1 ;;
  esac
}
