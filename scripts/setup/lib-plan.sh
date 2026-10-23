#!/usr/bin/env bash
# doc-superpowers setup: the plan, the summary and the review. Sourced by
# setup.sh after lib-model.sh and lib-probe.sh; probe_run and model_base_init
# run first. It writes no file.
#
# plan_build diffs the selection (SEL) against the PROBED state, never against
# the base (design §5): an item in place and current is no step, an outdated
# one is refreshed (its install step again), an absent one is installed, and
# an installed one that is unticked is uninstalled. Unticking never removes a
# switch (docs/search/config.json, docs/ledger/config.json, docs/spec-claims/):
# doc-search off with its config left in place and no launcher or entry is
# current. Inputs (0 unless set):
#   PLAN_BUILD_REQUESTED  1: plan the build (--build, or Write and build)
#   PLAN_FOR_TEAM         1: the per-user values (git, claude, ledger.git,
#                         ledger.claude) this run sets are the team's
#                         (--for-team); else, once a team record exists, a
#                         departure from it is this user's own (the local
#                         record's overrides). "Sets": named in
#                         PLAN_FOR_TEAM_IDS, or changed against the base; any
#                         other per-user value keeps the record's value and
#                         its override
#   PLAN_FOR_TEAM_IDS     the ids this run names (--set), space-separated
#   PLAN_APPLY            1: setup --apply, which reproduces the recorded team
#                         setup and never changes the team record: no
#                         record-team step, whatever the record's content
# It fills:
#   PLAN               the steps in run order, one op line each, fields
#                      separated by TAB (the shared definitions' plan ops)
#   W_TEAM W_LOCAL W_OUTSIDE
#                      "<path>TAB<what>": what the steps write, committed for
#                      the team, local to you, and local to you outside the
#                      repository; one line per path, in plan order
#   NET                "<item id>TAB<what>": every ticked item that can reach
#                      a remote (design §5.5), installed by this run or not
#   DL                 "<what>TAB<size or estimate>": the downloads
#   PLAN_HNOTES        the non-Claude harnesses this run newly ticks (a name
#                      each): plan_render_harness_notes points them to their
#                      INSTALL guides
#   PLAN_HFOREIGN      the ticked harnesses whose project file already defines
#                      doc-search in a way that is not setup's (a JSON entry
#                      that differs, an unmarked Codex definition): the step
#                      that would add the entry refuses, and the review says so
#   PLAN_TEAM_SETUP    the .setup object record-team writes (compact JSON)
#   PLAN_LOCAL_RECORD  the file record-local writes (compact JSON)
#   PLAN_TEAM_CHANGED PLAN_LOCAL_CHANGED
#                      1 when that record's content would change (its op is
#                      planned only then)
#   PLAN_ERROR         why plan_build returned 1
#
# The order. Each step may read what an earlier one wrote:
#   1. the switches, files setup writes that the installer reads:
#      search-config (install --search needs docs/search/config.json),
#      ledger-config (install --ledger and --ledger-claude need
#      docs/ledger/config.json; install --ci ships the ledger helper set on
#      a ledger host), claims-config;
#   2. the installer: git, claude, ci (its uninstall first), search, ledger,
#      ledger-claude;
#   3. the other harnesses' doc-search entries (claude-code's is install
#      --search's own), envhook, exclude-local, bin-link or bin-unlink;
#   4. record-team, then record-local;
#   5. build (a download), last.
#
# plan_render_summary and plan_render_review print what plan_build made (run
# it first); plan_is_empty says whether there is anything to do;
# plan_envhook_file and plan_envhook_block are the env hook's path and the
# block setup owns there; plan_envhook_merge is the block the envhook step
# writes (the current one, changed per variable).

_PLAN_T=$'\t'
PLAN_ENVHOOK_BEGIN="# doc-superpowers setup:begin (managed; edit with doc-superpowers setup)"
PLAN_ENVHOOK_END="# doc-superpowers setup:end"
PLAN_EXCLUDE_BEGIN="# doc-superpowers setup:begin"
# shellcheck disable=SC2034  # the exclude block's end marker: the executor writes the block
PLAN_EXCLUDE_END="# doc-superpowers setup:end"

PLAN_BUILD_REQUESTED=0
PLAN_FOR_TEAM=0
PLAN_FOR_TEAM_IDS=""
PLAN_APPLY=0
PLAN=() W_TEAM=() W_LOCAL=() W_OUTSIDE=() NET=() DL=() PLAN_HNOTES=() PLAN_HFOREIGN=()
PLAN_TEAM_SETUP="" PLAN_LOCAL_RECORD="" PLAN_TEAM_CHANGED=0 PLAN_LOCAL_CHANGED=0 PLAN_ERROR=""

# Set by plan_build: every write as "<scope>TAB<path>TAB<what>", the groups a
# step acts on ("|<group>|…|"), and the paths it resolved.
_PLAN_W=()
_PLAN_GROUPS="|"
_PLAN_HOOKS="" _PLAN_EXCLUDE="" _PLAN_GITCONFIG="" _PLAN_ENVFILE="" _PLAN_BIN=""
_PLAN_LAUNCHER=absent _PLAN_ENTRY=absent _PLAN_BUILD=0 _PLAN_GONE="|"

# The records, from the selection. The team's .setup keeps the keys the record
# already holds that setup does not know, and its harness list's order when it
# names the same harnesses; the local record keeps its other keys and the
# overrides of items that are not per-user.
# shellcheck disable=SC2016  # jq program, not shell expansions
_PLAN_RECORDS_JQ='
  def tf($v): $v == "on";
  ($tr | if . == "" then null else fromjson end) as $t
  | ($lr | if . == "" then null else fromjson end) as $l
  | (if $harness == "none" then [] else ($harness | split(",")) end) as $h
  | (($t // {}) + {
       format: 1,
       harnesses: (if $t != null and (($t.harnesses // null) | type) == "array" and (($t.harnesses | sort) == ($h | sort))
                   then $t.harnesses else $h end),
       git: $tgit,
       claude: tf($tclaude),
       search: (if $search == "on" then {model: (if $model == "gte" then $gte else "static" end)} else null end),
       ledger: (if $ledger == "on" then {git: tf($tlgit), claude: tf($tlclaude)} else null end),
       claims: tf($claims)
     }) as $nt
  | ({}
     + (if $ogit == "" then {} else {git: $ogit} end)
     + (if $oclaude == "" then {} else {claude: tf($oclaude)} end)
     + (if $olgit == "" then {} else {"ledger.git": tf($olgit)} end)
     + (if $olclaude == "" then {} else {"ledger.claude": tf($olclaude)} end)) as $ov
  | (if $cache == "host" then null else $cache end) as $c
  | (($l // {}) + {format: 1}
     | .overrides = (((.overrides // {}) | del(.git, .claude, .["ledger.git"], .["ledger.claude"])) + $ov)
     | .search = ((.search // {}) + {cache: $c})) as $nl
  | (if $t == null then 1 elif $nt == $t then 0 else 1 end),
    ($nt | tojson),
    (if $l == null then (if $ov == {} and $c == null then 0 else 1 end) elif $nl == $l then 0 else 1 end),
    ($nl | tojson)'

# _plan_sel <id>: _PS = SEL of <id> (no subshell).
_plan_sel() {
  _PS=""
  _model_i "$1" || return 1
  _PS="${SEL[_MI]}"
}

# _plan_sh_quote <s>: <s> as one sh word, always single-quoted.
_plan_sh_quote() {
  local q="'"
  printf "'%s'" "${1//$q/$q\\$q$q}"
}

# _plan_shell_word <s>: <s> as one sh word, quoted only when it needs it.
_plan_shell_word() {
  case "$1" in
    "" | *[!A-Za-z0-9._/@%+=:,-]*) _plan_sh_quote "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

# _plan_abs <path>: a path git printed, made absolute against TOP when it is
# relative (for reading the file; the review shows the path as git gave it).
_plan_abs() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$TOP" "$1" ;;
  esac
}

# plan_envhook_file: the per-user env hook the launcher sources (references/
# search.md, DOC_SEARCH_ENV_FILE), resolved now.
plan_envhook_file() {
  printf '%s\n' "${DOC_SEARCH_ENV_FILE:-${XDG_CONFIG_HOME:-${HOME:-}/.config}/doc-search/env.sh}"
}

# plan_write_path <path>: a path of the catalog's writes (CAT_WRITES) as it
# is for this user, resolved now: the env hook's symbolic
# ~/.config/doc-search/env.sh is plan_envhook_file (DOC_SEARCH_ENV_FILE,
# XDG_CONFIG_HOME), another ~/ path is under HOME; any other path is as given.
plan_write_path() {
  case "$1" in
    \~/.config/doc-search/env.sh) plan_envhook_file ;;
    \~/*) printf '%s/%s\n' "${HOME:-}" "${1#\~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# plan_envhook_block <cache|-> <root|->: the block setup owns in the env hook
# (design §6.3), each value sh-quoted; nothing when both are -.
plan_envhook_block() {
  local c="$1"
  [ "$1" != - ] || [ "$2" != - ] || return 0
  printf '%s\n' "$PLAN_ENVHOOK_BEGIN"
  if [ "$c" != - ]; then
    [ "$c" = / ] || c="${c%/}"
    printf 'export SEMBLE_CACHE_LOCATION=%s\n' "$(_plan_sh_quote "${c%/}/semble")"
    printf 'export DOC_SEARCH_CACHE_LOCATION=%s\n' "$(_plan_sh_quote "${c%/}/doc-search")"
  fi
  if [ "$2" != - ]; then
    printf 'export DOC_SUPERPOWERS_ROOT=%s\n' "$(_plan_sh_quote "$2")"
  fi
  printf '%s\n' "$PLAN_ENVHOOK_END"
}

# plan_envhook_merge <cache|-|host> <root|->: the block the envhook step
# leaves in the env hook, from the block it holds now, per variable: a path
# writes that variable's line(s) (the cache: SEMBLE_CACHE_LOCATION and
# DOC_SEARCH_CACHE_LOCATION under it); - keeps the line(s) there now as they
# are; host (the cache set back from a recorded path to the host default)
# drops the two cache lines. Any other line in the block is kept, after
# them; an empty line is dropped. Nothing when the block would hold no line
# (the envhook step then removes it).
plan_envhook_merge() {
  local cache="$1" rootv="$2" cur line cl="" rl="" other="" c
  cur=$(_plan_envhook_current)
  if [ -n "$cur" ]; then
    while IFS= read -r line; do
      case "$line" in
        "" | "$PLAN_ENVHOOK_BEGIN" | "$PLAN_ENVHOOK_END") ;;
        "export SEMBLE_CACHE_LOCATION="* | "export DOC_SEARCH_CACHE_LOCATION="*) cl="$cl$line"$'\n' ;;
        "export DOC_SUPERPOWERS_ROOT="*) rl="$rl$line"$'\n' ;;
        *) other="$other$line"$'\n' ;;
      esac
    done <<<"$cur"
  fi
  case "$cache" in
    -) ;;
    host) cl="" ;;
    *)
      c="$cache"
      [ "$c" = / ] || c="${c%/}"
      cl="export SEMBLE_CACHE_LOCATION=$(_plan_sh_quote "${c%/}/semble")"$'\n'
      cl="${cl}export DOC_SEARCH_CACHE_LOCATION=$(_plan_sh_quote "${c%/}/doc-search")"$'\n'
      ;;
  esac
  [ "$rootv" = - ] || rl="export DOC_SUPERPOWERS_ROOT=$(_plan_sh_quote "$rootv")"$'\n'
  [ -n "$cl$rl$other" ] || return 0
  printf '%s\n%s%s%s%s\n' "$PLAN_ENVHOOK_BEGIN" "$cl" "$rl" "$other" "$PLAN_ENVHOOK_END"
}

# _plan_envhook_current: the block the env hook holds now (from its begin
# marker to its end marker), or nothing.
_plan_envhook_current() {
  [ -f "$_PLAN_ENVFILE" ] || return 0
  awk -v b="$PLAN_ENVHOOK_BEGIN" -v e="$PLAN_ENVHOOK_END" \
    '$0 == b { on = 1 } on { print } on && $0 == e { exit }' "$_PLAN_ENVFILE" 2>/dev/null || true
}

# _plan_root_in_cache: ROOT is under the plugin cache (logical paths, ruling
# R1), where the launcher finds the plugin by itself.
_plan_root_in_cache() {
  local c="${CLAUDE_PLUGIN_CACHE:-${HOME:-}/.claude/plugins/cache}"
  c="${c%/}"
  [ -n "$c" ] || return 1
  case "$ROOT/" in
    "$c"/*) return 0 ;;
  esac
  return 1
}

# _plan_csv_minus <a> <b>: the names of CSV <a> not in CSV <b>, as a CSV in
# <a>'s order (none is the empty set).
_plan_csv_minus() {
  local o out=""
  [ "$1" != none ] || return 0
  for o in ${1//,/ }; do
    _model_csv_has "$2" "$o" || out="${out:+$out,}$o"
  done
  printf '%s' "$out"
}

# _plan_harness <h>: _PH_FILE (its project file) and _PH_NAME.
_plan_harness() {
  case "$1" in
    claude-code) _PH_FILE=.mcp.json _PH_NAME="Claude Code" ;;
    codex) _PH_FILE=.codex/config.toml _PH_NAME=Codex ;;
    cursor) _PH_FILE=.cursor/mcp.json _PH_NAME=Cursor ;;
    opencode) _PH_FILE=opencode.json _PH_NAME=OpenCode ;;
    gemini) _PH_FILE=.gemini/settings.json _PH_NAME="Gemini CLI" ;;
    *) _PH_FILE="" _PH_NAME="$1" ;;
  esac
}

# _plan_recorded_harnesses: the harnesses the team record lists (a CSV, or
# none); without a record, the ones whose entry is in place.
_plan_recorded_harnesses() {
  local line
  if [ -n "$PROBE_TEAM" ]; then
    while IFS= read -r line; do
      case "$line" in
        harness=*)
          printf '%s' "${line#harness=}"
          return 0
          ;;
      esac
    done <<<"$PROBE_TEAM_VALUES"
  fi
  probe_installed harness
}

# _plan_harness_guide <h>: _PH_GUIDE, the harness's skill install guide.
_plan_harness_guide() {
  case "$1" in
    codex) _PH_GUIDE=.codex/INSTALL.md ;;
    cursor) _PH_GUIDE=.cursor-plugin/INSTALL.md ;;
    opencode) _PH_GUIDE=.opencode/INSTALL.md ;;
    gemini) _PH_GUIDE=GEMINI.md ;;
    *) _PH_GUIDE="" ;;
  esac
}

# plan_render_harness_notes: for each non-Claude harness this run newly ticks,
# a pointer to its INSTALL guide (its skill install steps), and to the help
# topic; Codex's names its trust requirement when its doc-search entry is
# written. Nothing when there is none.
plan_render_harness_notes() {
  local h
  if [ "${#PLAN_HFOREIGN[@]}" -gt 0 ]; then
    echo "Not setup's, so not touched (--yes refuses until you move or fix it):"
    for h in "${PLAN_HFOREIGN[@]}"; do
      _plan_harness "$h"
      printf '  %s: it already defines doc-search in a way setup did not write (or cannot be read)\n' "$_PH_FILE"
    done
  fi
  [ "${#PLAN_HNOTES[@]}" -gt 0 ] || return 0
  echo "Harness skill install steps (doc-superpowers help setup has the rest):"
  for h in "${PLAN_HNOTES[@]}"; do
    _plan_harness "$h"
    _plan_harness_guide "$h"
    printf '  %s: %s' "$_PH_NAME" "$_PH_GUIDE"
    if [ "$h" = codex ] && model_is_on search; then
      printf ' (Codex loads the project'"'"'s doc-search entry only for a trusted project)'
    fi
    echo ""
  done
}

# _plan_cache_dirs: _PLAN_SEMBLE_CACHE and _PLAN_DS_CACHE, where a build
# writes doc-search's indexes (references/search.md, Configuration).
_plan_cache_dirs() {
  local c cdir
  _plan_sel search.cache
  c="$_PS"
  if [ "$c" != host ]; then
    [ "$c" = / ] || c="${c%/}"
    _PLAN_SEMBLE_CACHE="${c%/}/semble"
    _PLAN_DS_CACHE="${c%/}/doc-search"
    return 0
  fi
  case "$(uname -s 2>/dev/null)" in
    Darwin) cdir="${HOME:-}/Library/Caches" ;;
    *) cdir="${XDG_CACHE_HOME:-${HOME:-}/.cache}" ;;
  esac
  _PLAN_SEMBLE_CACHE="${SEMBLE_CACHE_LOCATION:-$cdir/semble}"
  _PLAN_DS_CACHE="${DOC_SEARCH_CACHE_LOCATION:-$cdir/doc-search}"
}

# _plan_w <team|local|outside> <path> <what> [gone]: one write; a path written
# by several steps is one line, its texts joined with "; ". <gone> 1: the step
# may delete the path (its last such step decides: _PLAN_GONE lists them).
_plan_w() {
  local key="$1$_PLAN_T$2$_PLAN_T" k=0 e what
  if [ "${4:-0}" = 1 ]; then
    case "$_PLAN_GONE" in
      *"|$2|"*) ;;
      *) _PLAN_GONE="$_PLAN_GONE$2|" ;;
    esac
  else
    _PLAN_GONE=${_PLAN_GONE//"|$2|"/|}
  fi
  while [ "$k" -lt "${#_PLAN_W[@]}" ]; do
    e="${_PLAN_W[k]}"
    case "$e" in
      "$key"*)
        what="${e#"$key"}"
        case "; $what; " in
          *"; $3; "*) ;;
          *) _PLAN_W[k]="$key$what; $3" ;;
        esac
        return 0
        ;;
    esac
    k=$((k + 1))
  done
  _PLAN_W+=("$key$3")
}

# _plan_wf_foreign <workflow>: .github/workflows/<workflow>.yml is there and
# not doc-superpowers-managed (install.sh's is_managed_workflow: the marker in
# its first 5 lines), so install --ci skips it.
_plan_wf_foreign() {
  local f="$TOP/.github/workflows/$1.yml"
  [ -e "$f" ] || [ -L "$f" ] || return 1
  [ -f "$f" ] || return 0
  ! awk 'NR > 5 { exit } /doc-superpowers workflow v[0-9]/ { m = 1; exit } END { exit !m }' "$f"
}

# _plan_rn_readme_removable: uninstalling doc-pr-release's helpers removes
# RELEASE-NOTES.next/README.md (doc-tools.sh tools uninstall): a regular file
# identical to the plugin's fragment-format spec, alone in its directory.
_plan_rn_readme_removable() {
  local d="$TOP/RELEASE-NOTES.next" e
  [ -f "$d/README.md" ] && [ ! -L "$d/README.md" ] || return 1
  cmp -s "$ROOT/scripts/hooks/ci/doc-pr-release/RELEASE-NOTES.next.README.md" "$d/README.md" || return 1
  for e in "$d"/* "$d"/.[!.]* "$d"/..?*; do
    [ -e "$e" ] || [ -L "$e" ] || continue
    [ "$e" = "$d/README.md" ] || return 1
  done
  return 0
}

# _plan_op_writes <op line>: the writes of one step, as the installer makes
# them (a file it leaves untouched is not one).
_plan_op_writes() {
  local op a b c d w gone g=0
  IFS="$_PLAN_T" read -r op a b c d <<<"$1"
  case "$op" in
    *-uninstall | *-remove | bin-unlink)
      gone=", removed"
      g=1
      ;;
    *) gone="" ;;
  esac
  case "$op" in
    search-config)
      if [ "$a" = gte ]; then w="docs.model $PROBE_GTE_MODEL"; else w="the static docs model"; fi
      if [ -f "$TOP/docs/search/config.json" ]; then
        _plan_w team docs/search/config.json "doc-search's config (sets docs.model: $w)"
      else
        _plan_w team docs/search/config.json "doc-search's config (doc-search init's defaults, $w)"
      fi
      ;;
    ledger-config) _plan_w team docs/ledger/config.json "the work ledger's switch: {}" ;;
    claims-config) _plan_w team docs/spec-claims/config.json "spec claims' switch: {\"schema\": 1}" ;;
    git-install | git-uninstall)
      _plan_w team .gitattributes "the merge driver's block$gone" "$g"
      _plan_w local "$_PLAN_GITCONFIG" "the merge driver's registration$gone"
      if [ "$a" = hooks ]; then
        if [ -n "$gone" ]; then w="the git hooks, removed"; else w="the 5 report-only git hooks"; fi
        _plan_w local "$_PLAN_HOOKS" "$w"
      fi
      ;;
    claude-install | claude-uninstall)
      _plan_w local .claude/settings.local.json "the 3 Claude Code hooks' registration$gone"
      _plan_w local .claude/hooks/doc-superpowers/ "the Claude Code hooks' scripts$gone"
      _plan_w local "$_PLAN_EXCLUDE" "keeps the Claude Code hooks' files out of git"
      ;;
    ci-install | ci-uninstall)
      for w in ${a//,/ }; do
        # install --ci skips a workflow file that is not its own.
        [ -n "$gone" ] || ! _plan_wf_foreign "$w" || continue
        _plan_w team ".github/workflows/$w.yml" "the $w workflow$gone" "$g"
      done
      if [ -n "$gone" ]; then
        _plan_w team .github/scripts/ "the vendored files no installed workflow runs, removed" 1
        _plan_w team "$PROBE_STATE_FILE" "the workflows recorded as removed (.tiers.ci)"
        if _model_csv_has "$a" doc-pr-release && _plan_rn_readme_removable; then
          _plan_w team RELEASE-NOTES.next/README.md "the fragment format spec, removed" 1
        fi
      else
        _plan_w team .github/scripts/ "doc-tools.sh and the helpers the workflows run, vendored"
        _plan_w team "$PROBE_STATE_FILE" "the CI choices (.tiers.ci)"
        if _model_csv_has "$a" doc-pr-release && [ ! -e "$TOP/RELEASE-NOTES.next/README.md" ] \
          && [ ! -L "$TOP/RELEASE-NOTES.next/README.md" ]; then
          _plan_w team RELEASE-NOTES.next/README.md "the fragment format spec (doc-pr-release's)"
        fi
      fi
      ;;
    search-install)
      # install --search leaves a launcher and an entry that are right alone.
      [ "$_PLAN_LAUNCHER" = installed ] || _plan_w team .claude/doc-superpowers/search-mcp.sh "doc-search's launcher"
      [ "$_PLAN_ENTRY" = registered ] || _plan_w team .mcp.json "the doc-search server entry for Claude Code"
      ;;
    search-uninstall)
      [ "$_PLAN_LAUNCHER" = absent ] || _plan_w team .claude/doc-superpowers/search-mcp.sh "doc-search's launcher, removed" 1
      [ "$_PLAN_ENTRY" = absent ] || _plan_w team .mcp.json "the doc-search server entry for Claude Code, removed" 1
      ;;
    ledger-install | ledger-uninstall)
      _plan_w local "$_PLAN_HOOKS" "the ledger's blocks in pre-commit, pre-push and post-commit$gone"
      ;;
    ledger-claude-install | ledger-claude-uninstall)
      _plan_w local .claude/settings.local.json "the ledger's 2 Claude Code hooks' registration$gone"
      _plan_w local .claude/hooks/doc-superpowers/ "the ledger's Claude Code hook scripts$gone"
      _plan_w local "$_PLAN_EXCLUDE" "keeps the ledger's Claude Code hook files out of git"
      ;;
    harness-add)
      _plan_harness "$a"
      _plan_w team "$_PH_FILE" "the doc-search server entry for $_PH_NAME"
      ;;
    harness-remove)
      # The entry alone goes: the file stays, so it is not one that is gone.
      _plan_harness "$a"
      _plan_w team "$_PH_FILE" "the doc-search server entry for $_PH_NAME, removed (the file stays)"
      ;;
    envhook)
      _plan_w outside "$_PLAN_ENVFILE" "your env hook's doc-superpowers block (doc-search's cache path, DOC_SUPERPOWERS_ROOT): per user and per host, read in every repository on this host"
      ;;
    exclude-local) _plan_w local "$_PLAN_EXCLUDE" "keeps $PROBE_LOCAL_FILE out of git" ;;
    bin-link | bin-unlink) _plan_w outside "$_PLAN_BIN" "the terminal command$gone" ;;
    record-team) _plan_w team "$PROBE_STATE_FILE" "the team's setup (.setup)" ;;
    record-local) _plan_w local "$PROBE_LOCAL_FILE" "your own setup (untracked)" ;;
    build)
      # uv run --project <ROOT>/search: uv's cache, then the project's own
      # environment; semble's model and gte from the Hugging Face hub; the
      # indexes in semble's cache (gte's vectors in doc-search's).
      _plan_cache_dirs
      _plan_sel search.model
      _plan_w outside "${UV_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME:-}/.cache}/uv}" \
        "uv's cache: doc-search's Python packages, about 40 MB$([ "$_PS" != gte ] || printf ' (and onnxruntime for gte)')"
      _plan_w outside "$ROOT/search/.venv" "the plugin's Python environment for doc-search (uv run --project), about 150 MB"
      _plan_w outside "${HF_HOME:-${XDG_CACHE_HOME:-${HOME:-}/.cache}/huggingface}" \
        "the Hugging Face cache: semble's model, about 30 MB$([ "$_PS" != gte ] || printf ', and the gte model, about 150 MB')"
      _plan_w outside "$_PLAN_SEMBLE_CACHE" "doc-search's indexes (semble's cache)"
      [ "$_PS" != gte ] || _plan_w outside "$_PLAN_DS_CACHE" "the gte encode cache"
      ;;
  esac
}

# _plan_op <item id|""> <op> [<field>…]: append one step (its fields joined
# by TAB), mark the item's group as acted on, and record the step's writes.
_plan_op() {
  local id="$1" line="$2"
  shift 2
  while [ "$#" -gt 0 ]; do
    line="$line$_PLAN_T$1"
    shift
  done
  PLAN+=("$line")
  if [ -n "$id" ] && _model_i "$id"; then
    case "$_PLAN_GROUPS" in
      *"|${CAT_GROUP[_MI]}|"*) ;;
      *) _PLAN_GROUPS="$_PLAN_GROUPS${CAT_GROUP[_MI]}|" ;;
    esac
  fi
  _plan_op_writes "$line"
}

# _plan_set <id> <install op> <uninstall op>: an installer set behind a toggle.
_plan_set() {
  if model_is_on "$1"; then
    [ "$(probe_state "$1")" = current ] || _plan_op "$1" "$2"
  elif [ "$(probe_installed "$1")" = on ]; then
    _plan_op "$1" "$3"
  fi
}

# _plan_rec <id>: _PS = the value a record keeps for <id>: SEL, except that an
# item on a host fallback (model_hostfall: this host cannot offer the option
# the base wanted) keeps the option the base wanted, since one host's quirk is
# not the team's setting.
_plan_rec() {
  _plan_sel "$1"
  if model_hostfall "$1"; then _PS="$MODEL_WISH"; fi
}

# _plan_promoted <id>: --for-team makes this run's value of <id> the team's:
# PLAN_FOR_TEAM, and <id> named in PLAN_FOR_TEAM_IDS or changed against the
# base. A per-user value this run does not set stays as it is: the record's
# for the team, an override for you.
_plan_promoted() {
  [ "$PLAN_FOR_TEAM" = 1 ] || return 1
  case " $PLAN_FOR_TEAM_IDS " in
    *" $1 "*) return 0 ;;
  esac
  model_changed "$1"
}

# _plan_team_value <id>: _PTV = the team's value of a per-user item: the team
# record's, when there is one (and --for-team does not promote <id>); else
# the selection.
_plan_team_value() {
  local line
  _plan_rec "$1"
  _PTV="$_PS"
  if [ -z "$PROBE_TEAM" ] || _plan_promoted "$1"; then return 0; fi
  while IFS= read -r line; do
    case "$line" in
      "$1="*)
        _PTV="${line#*=}"
        return 0
        ;;
    esac
  done <<<"$PROBE_TEAM_VALUES"
}

# _plan_records: PLAN_TEAM_SETUP, PLAN_LOCAL_RECORD and their *_CHANGED flags.
# shellcheck disable=SC2034  # PLAN_* are the plan's interface, read by setup.sh and the executor
_plan_records() {
  local id out tgit tclaude tlgit=off tlclaude=off ogit="" oclaude="" olgit="" olclaude="" v
  local harness search model ledger claims cache
  for id in git claude ledger.git ledger.claude; do
    _plan_team_value "$id"
    _plan_rec "$id"
    v=""
    if [ -n "$PROBE_TEAM" ] && ! _plan_promoted "$id" && [ "$_PTV" != "$_PS" ]; then v="$_PS"; fi
    case "$id" in
      git) tgit="$_PTV" ogit="$v" ;;
      claude) tclaude="$_PTV" oclaude="$v" ;;
      ledger.git) tlgit="$_PTV" olgit="$v" ;;
      ledger.claude) tlclaude="$_PTV" olclaude="$v" ;;
    esac
  done
  # With the ledger off, its hook sets are not a choice anyone made.
  if ! model_is_on ledger; then olgit="" olclaude=""; fi
  _plan_sel harness && harness="$_PS"
  _plan_sel search && search="$_PS"
  _plan_rec search.model && model="$_PS"
  _plan_sel ledger && ledger="$_PS"
  _plan_sel claims && claims="$_PS"
  _plan_sel search.cache && cache="$_PS"
  if ! out=$(jq -n -r --arg tr "$PROBE_TEAM" --arg lr "$PROBE_LOCAL" --arg gte "$PROBE_GTE_MODEL" \
    --arg harness "$harness" --arg tgit "$tgit" --arg tclaude "$tclaude" --arg search "$search" \
    --arg model "$model" --arg ledger "$ledger" --arg tlgit "$tlgit" --arg tlclaude "$tlclaude" \
    --arg claims "$claims" --arg cache "$cache" --arg ogit "$ogit" --arg oclaude "$oclaude" \
    --arg olgit "$olgit" --arg olclaude "$olclaude" "$_PLAN_RECORDS_JQ" 2>&1); then
    PLAN_ERROR="cannot compute the records: ${out%%$'\n'*}"
    return 1
  fi
  {
    IFS= read -r PLAN_TEAM_CHANGED
    IFS= read -r PLAN_TEAM_SETUP
    IFS= read -r PLAN_LOCAL_CHANGED
    IFS= read -r PLAN_LOCAL_RECORD
  } <<<"$out"
}

# _plan_option_detail <i> <option>: the "<option>: <text>" line of item i's
# details, without its "<option>: ".
_plan_option_detail() {
  local line
  while IFS= read -r line; do
    case "$line" in
      "$2: "*)
        printf '%s' "${line#"$2: "}"
        return 0
        ;;
    esac
  done <<<"${CAT_DETAILS[$1]}"
}

# _plan_net_dl: NET and DL, from the selection.
_plan_net_dl() {
  local w i size what cfg="$TOP/docs/search/config.json"
  if model_is_on search; then
    what="doc-search: only its downloads (below), once per host; it sends nothing else"
    if [ -f "$cfg" ] && jq -e '(.cloud // null) != null' "$cfg" >/dev/null 2>&1; then
      what="$what, except its cloud leg (docs/search/config.json sets cloud): Vertex embeddings and a Firestore corpus on Google Cloud"
    fi
    NET+=("search$_PLAN_T$what")
  fi
  _plan_sel ci.workflows
  if [ "$_PS" != none ] && _model_i ci.workflows; then
    i=$_MI
    for w in ${_PS//,/ }; do
      NET+=("ci.workflows$_PLAN_T$w runs on GitHub: $(_plan_option_detail "$i" "$w")")
    done
  fi
  if model_is_on ledger; then
    NET+=("ledger${_PLAN_T}the work ledger: with keys.mode cas (the default), issuing a key (ledger new) fetches and pushes the counter ref on the remote")
  fi
  if model_is_on ledger.git; then
    NET+=("ledger.git${_PLAN_T}the ledger git hooks: post-commit pushes this branch's in-flight ref when inflight.enabled is on (off in the {} config setup writes); pre-push refuses provisional keys (keys.mode cas) without a fetch")
  fi
  if model_is_on search; then
    _plan_sel search.model
    what="each contributor's client, on its first start of doc-search (after that client's own approval prompt, which is that contributor's consent): uv's Python packages and semble's model"
    size="about 70 MB, once per host (and Python, when the host has none)"
    if [ "$_PS" = gte ]; then
      what="$what, and the gte docs model"
      size="about 70 MB, and about 150 MB more for the gte model, once per host; then a first build of hours"
    fi
    DL+=("$what$_PLAN_T$size")
    if [ "$_PLAN_BUILD" = 1 ]; then
      DL+=("this run (the build): the same downloads, then the first index build (sh .claude/doc-superpowers/search-mcp.sh index)$_PLAN_T$size")
    fi
  fi
}

# plan_build: PLAN and the review's lists, from SEL against the probed state.
# shellcheck disable=SC2034  # PLAN_* are the plan's interface, read by setup.sh and the executor
plan_build() {
  local out sel inst st x y rm add h m cache hroot strict b c rec new hbase search_off=0
  PLAN=() W_TEAM=() W_LOCAL=() W_OUTSIDE=() NET=() DL=() PLAN_HNOTES=() PLAN_HFOREIGN=() _PLAN_W=()
  _PLAN_GROUPS="|" _PLAN_GONE="|" PLAN_ERROR=""
  PLAN_TEAM_SETUP="" PLAN_LOCAL_RECORD="" PLAN_TEAM_CHANGED=0 PLAN_LOCAL_CHANGED=0
  # The merge driver is the team's (its .gitattributes block is committed): a
  # per-user git value that adds or removes it, against the team record, would
  # flip that block for everyone. Only the team's choice may (--for-team);
  # hooks and merge-driver both keep the driver, so either is a user's own.
  if [ -n "$PROBE_TEAM" ] && ! _plan_promoted git; then
    _plan_team_value git
    _plan_sel git
    case "$_PTV:$_PS" in
      hooks:off | merge-driver:off)
        PLAN_ERROR="git=off removes the merge driver, which is the team's (.gitattributes): pass --for-team to change the team's choice"
        return 1
        ;;
      off:hooks | off:merge-driver)
        PLAN_ERROR="git=$_PS adds the merge driver, which is the team's (.gitattributes): pass --for-team to change the team's choice"
        return 1
        ;;
    esac
  fi
  if ! out=$(cd "$TOP" && git rev-parse --git-path hooks --git-path info/exclude --git-path config 2>&1); then
    PLAN_ERROR="git rev-parse --git-path failed: ${out%%$'\n'*}"
    return 1
  fi
  _PLAN_HOOKS="${out%%$'\n'*}/"
  out="${out#*$'\n'}"
  _PLAN_EXCLUDE="${out%%$'\n'*}"
  _PLAN_GITCONFIG="${out#*$'\n'}"
  _PLAN_ENVFILE=$(plan_envhook_file)
  _PLAN_BIN="${HOME:-}/.local/bin/doc-superpowers"
  out=$(jq -r '[(.tiers.search.launcher // "absent"), (.tiers.search.mcp_entry // "absent")] | join(" ")' \
    <<<"$PROBE_STATUS" 2>/dev/null) || out="absent absent"
  _PLAN_LAUNCHER="${out%% *}"
  _PLAN_ENTRY="${out#* }"

  # 1. The switches the installer reads.
  if model_is_on search; then
    _plan_sel search.model
    m="$_PS"
    if [ ! -f "$TOP/docs/search/config.json" ] || [ "$(probe_installed search.model)" != "$m" ]; then
      _plan_op search search-config "$m"
    fi
  fi
  if model_is_on ledger && [ "$(probe_installed ledger)" = off ]; then _plan_op ledger ledger-config; fi
  if model_is_on claims && [ "$(probe_installed claims)" = off ]; then _plan_op claims claims-config; fi

  # 2. The installer: git (three modes), claude, ci, search, the ledger sets.
  _plan_sel git
  sel="$_PS"
  inst=$(probe_installed git)
  st=$(probe_state git)
  case "$sel" in
    hooks)
      if [ "$inst" != hooks ] || [ "$st" != current ]; then _plan_op git git-install hooks; fi
      ;;
    merge-driver)
      if [ "$inst" = hooks ]; then
        # No installer command removes the hooks alone: uninstall --git takes
        # the driver too, and --merge-driver-only puts it back.
        _plan_op git git-uninstall hooks
        _plan_op git git-install merge-driver
      elif [ "$inst" != merge-driver ] || [ "$st" != current ]; then
        _plan_op git git-install merge-driver
      fi
      ;;
    off)
      case "$inst" in
        hooks | merge-driver) _plan_op git git-uninstall "$inst" ;;
      esac
      ;;
  esac
  _plan_set claude claude-install claude-uninstall
  _plan_sel ci.workflows
  x="$_PS"
  y=$(probe_installed ci.workflows)
  rm=$(_plan_csv_minus "$y" "$x")
  add=$(_plan_csv_minus "$x" "$y")
  [ -z "$rm" ] || _plan_op ci.workflows ci-uninstall "$rm"
  if [ "$x" != none ]; then
    _plan_sel ci.base_branch
    b="$_PS"
    _plan_sel ci.cron
    c="$_PS"
    _plan_sel ci.strict
    strict=false
    [ "$_PS" != on ] || strict=true
    if [ -n "$add" ] || [ "$(probe_state ci.workflows)" != current ] \
      || [ "$b" != "$(probe_installed ci.base_branch)" ] || [ "$c" != "$(probe_installed ci.cron)" ] \
      || [ "$_PS" != "$(probe_installed ci.strict)" ]; then
      _plan_op ci.workflows ci-install "$x" "$b" "$c" "$strict"
    fi
  fi
  if model_is_on search; then
    if [ "$_PLAN_LAUNCHER" != installed ] || [ "$_PLAN_ENTRY" != registered ]; then _plan_op search search-install; fi
  elif [ "$_PLAN_LAUNCHER" != absent ] || [ "$_PLAN_ENTRY" != absent ]; then
    # docs/search/config.json stays: setup never removes a switch.
    _plan_op search search-uninstall
    search_off=1
  fi
  _plan_set ledger.git ledger-install ledger-uninstall
  _plan_set ledger.claude ledger-claude-install ledger-claude-uninstall

  # 3. The other harnesses' doc-search entries (install --search writes the
  # Claude Code one), the env hook, the exclude block, the terminal command.
  _plan_sel harness
  x="$_PS"
  y=$(probe_installed harness)
  _model_i harness
  hbase="${BASE[_MI]}"
  rec=$(_plan_recorded_harnesses)
  for h in ${CAT_OPTIONS[_MI]//,/ }; do
    [ "$h" != claude-code ] || continue
    new=0
    _model_csv_has "$x" "$h" && ! _model_csv_has "$rec" "$h" && new=1
    if model_is_on search && _model_csv_has "$x" "$h"; then
      if ! _model_csv_has "$y" "$h"; then
        # Not setup's entry yet. One that is not setup's own (a definition of
        # the user's) is refused when the step runs, and said so here.
        _plan_op harness harness-add "$h"
        new=1
        [ "$(harness_entry_state "$h")" = absent ] || PLAN_HFOREIGN+=("$h")
      elif [ "$h" = codex ] && [ "$(harness_entry_state codex)" = different ]; then
        # Setup's block, edited or older than this one: refreshed.
        _plan_op harness harness-add "$h"
      fi
    elif _model_csv_has "$y" "$h"; then
      # Only what this run unticks, or what leaves with doc-search itself: an
      # entry that is merely there is not a reason to remove it.
      if [ "$search_off" = 1 ] || { _model_csv_has "$hbase" "$h" && ! _model_csv_has "$x" "$h"; }; then
        _plan_op harness harness-remove "$h"
      fi
    fi
    [ "$new" = 0 ] || PLAN_HNOTES+=("$h")
  done
  # The env hook, per variable (plan_envhook_merge): the cache when it is a
  # path, or when it goes back from a recorded path to the host default
  # (host); DOC_SUPERPOWERS_ROOT when setup runs from a clone; - leaves a
  # variable's line as it is (the hook is per host: another repository's
  # cache path stays).
  if model_is_on search; then
    _plan_sel search.cache
    cache="$_PS"
    if [ "$cache" = host ]; then
      cache=-
      [ "$(probe_installed search.cache)" = host ] || cache=host
    fi
    hroot=-
    _plan_root_in_cache || hroot="$ROOT"
    if { [ "$cache" != - ] || [ "$hroot" != - ]; } \
      && [ "$(_plan_envhook_current)" != "$(plan_envhook_merge "$cache" "$hroot")" ]; then
      _plan_op search.cache envhook "$cache" "$hroot"
    fi
  fi
  _plan_records || return 1
  if { [ "$PLAN_LOCAL_CHANGED" = 1 ] || [ -e "$TOP/$PROBE_LOCAL_FILE" ]; } \
    && ! grep -qxF "$PLAN_EXCLUDE_BEGIN" "$(_plan_abs "$_PLAN_EXCLUDE")" 2>/dev/null; then
    _plan_op "" exclude-local
  fi
  _plan_set bin bin-link bin-unlink

  # 4. The records (--apply never writes the team's). 5. The build.
  [ "$PLAN_TEAM_CHANGED" != 1 ] || [ "$PLAN_APPLY" = 1 ] || _plan_op "" record-team
  [ "$PLAN_LOCAL_CHANGED" != 1 ] || _plan_op "" record-local
  _PLAN_BUILD=0
  if [ "$PLAN_BUILD_REQUESTED" = 1 ] && model_is_on search; then
    if [ -n "${HOST_NO_BUILD:-}" ]; then
      PLAN_ERROR="--build: doc-search's build needs uv: $HOST_NO_BUILD (without --build, setup writes doc-search's files and builds nothing)"
      return 1
    fi
    _plan_op search build
    _PLAN_BUILD=1
  fi

  _plan_net_dl
  for out in ${_PLAN_W[@]+"${_PLAN_W[@]}"}; do
    case "$out" in
      "team$_PLAN_T"*) W_TEAM+=("${out#"team$_PLAN_T"}") ;;
      "local$_PLAN_T"*) W_LOCAL+=("${out#"local$_PLAN_T"}") ;;
      "outside$_PLAN_T"*) W_OUTSIDE+=("${out#"outside$_PLAN_T"}") ;;
    esac
  done
  return 0
}

# plan_is_empty: 0 when the plan does nothing: no step, except at most a
# record whose content would not change.
plan_is_empty() {
  local line
  for line in ${PLAN[@]+"${PLAN[@]}"}; do
    case "$line" in
      record-team) [ "$PLAN_TEAM_CHANGED" != 1 ] || return 1 ;;
      record-local) [ "$PLAN_LOCAL_CHANGED" != 1 ] || return 1 ;;
      *) return 1 ;;
    esac
  done
  return 0
}

# _plan_group_text <i>: _PG_TEXT, the summary's value text for the group whose
# first item is i (ticked).
_plan_group_text() {
  local t
  _plan_sel "${CAT_ID[$1]}"
  case "${CAT_ID[$1]}" in
    harness) t="${_PS//,/, }" ;;
    search)
      _plan_sel search.model
      t="on, $_PS model"
      _plan_sel search.cache
      [ "$_PS" = host ] || t="$t, cache $_PS"
      ;;
    git)
      case "$_PS" in
        hooks) t="hooks + merge driver" ;;
        merge-driver) t="merge driver only" ;;
        *) t="$_PS" ;;
      esac
      ;;
    claude) t="on (3 hooks)" ;;
    ci.workflows)
      t="${_PS//,/, }"
      _plan_sel ci.base_branch
      t="$t; base $_PS"
      _plan_sel ci.cron
      t="$t, cron '$_PS'"
      _plan_sel ci.strict
      [ "$_PS" != on ] || t="$t, strict"
      ;;
    ledger)
      t="on"
      model_is_on ledger.git && t="$t, git hooks"
      model_is_on ledger.claude && t="$t, Claude hooks"
      ;;
    bin)
      # shellcheck disable=SC2088  # display text: the shim's place, as a user writes it
      t="~/.local/bin/doc-superpowers"
      ;;
    *)
      if [ "${CAT_KIND[$1]}" = toggle ]; then t=on; else t="$_PS"; fi
      ;;
  esac
  _PG_TEXT="$t"
}

# _plan_group_notes <group> <ticked>: what this host cannot offer in the
# group, one indented line each: an item it disables ("<label> is off here:
# <reason>"), and, while the group is ticked, an option it disables
# ("<id>: <option> is off here: <reason>"). A host check only says what is
# off; it never changes the selection.
_plan_group_notes() {
  local i=0 line
  while [ "$i" -lt "$CAT_N" ]; do
    if [ "${CAT_GROUP[i]}" = "$1" ]; then
      if [ -n "${DISABLED[i]}" ]; then
        printf '    %s is off here: %s\n' "${CAT_LABEL[i]}" "${DISABLED[i]}"
      fi
      if [ "$2" = 1 ] && [ -n "$DISABLED_OPT" ]; then
        while IFS= read -r line; do
          case "$line" in
            "${CAT_ID[i]}="*)
              line="${line#*=}"
              printf '    %s: %s is off here: %s\n' "${CAT_ID[i]}" "${line%%"$_PLAN_T"*}" "${line#*"$_PLAN_T"}"
              ;;
          esac
        done <<<"$DISABLED_OPT"
      fi
    fi
    i=$((i + 1))
  done
}

# plan_render_summary: one line per group, in order: "[x] <Group>  <value
# text>" or "[ ] <Group>  off", then " (changed)" when the group differs from
# the base and " (already installed)" when it is ticked, in place, and no step
# acts on it. Under a group, what this host cannot offer in it. After the
# groups, the scan hints ("  hint: <Group>: <text>"): shown, never applied.
plan_render_summary() {
  local g i first changed line ticked
  for g in "${GROUPS[@]}"; do
    first=-1 changed=0 i=0
    while [ "$i" -lt "$CAT_N" ]; do
      if [ "${CAT_GROUP[i]}" = "$g" ]; then
        [ "$first" -ge 0 ] || first=$i
        [ "${SEL[i]}" = "${BASE[i]}" ] || changed=1
      fi
      i=$((i + 1))
    done
    [ "$first" -ge 0 ] || continue
    if model_is_on "${CAT_ID[first]}"; then
      _plan_group_text "$first"
      line="[x] $g  $_PG_TEXT"
    else
      line="[ ] $g  off"
    fi
    [ "$changed" = 0 ] || line="$line (changed)"
    if model_is_on "${CAT_ID[first]}" && ! _model_is_off "$first" "$(probe_installed "${CAT_ID[first]}")"; then
      case "$_PLAN_GROUPS" in
        *"|$g|"*) ;;
        *) line="$line (already installed)" ;;
      esac
    fi
    printf '%s\n' "$line"
    ticked=0
    if model_is_on "${CAT_ID[first]}"; then ticked=1; fi
    _plan_group_notes "$g" "$ticked"
  done
  i=0
  while [ "$i" -lt "$CAT_N" ]; do
    if [ -n "${HINT[i]}" ]; then printf '  hint: %s: %s\n' "${CAT_GROUP[i]}" "${HINT[i]}"; fi
    i=$((i + 1))
  done
}

# _plan_op_text <op line>: one step, as the review shows it.
_plan_op_text() {
  local op a b c d
  IFS="$_PLAN_T" read -r op a b c d <<<"$1"
  case "$op" in
    search-config)
      if [ -f "$TOP/docs/search/config.json" ]; then
        if [ "$a" = gte ]; then a="\"$PROBE_GTE_MODEL\""; else a="null (the static docs model)"; fi
        printf '%s' "edit docs/search/config.json: sets docs.model to $a, nothing else (setup edits it; uv does not run)"
      else
        if [ "$a" = gte ]; then a="docs.model $PROBE_GTE_MODEL"; else a="the static docs model"; fi
        printf '%s' "write docs/search/config.json: doc-search init's defaults, $a (setup writes it; uv does not run)"
      fi
      ;;
    ledger-config) printf '%s' "write docs/ledger/config.json = {}: the work ledger on (doc-superpowers help ledger: ledger init)" ;;
    claims-config) printf '%s' "write docs/spec-claims/config.json = {\"schema\": 1}: spec claims on (its pre-commit leg blocks a commit on a finding)" ;;
    git-install)
      if [ "$a" = hooks ]; then
        printf '%s' "install the merge driver and the 5 report-only git hooks (doc-superpowers hooks install --git)"
      else
        printf '%s' "install the merge driver alone (doc-superpowers hooks install --git --merge-driver-only)"
      fi
      ;;
    git-uninstall)
      if [ "$a" = hooks ]; then
        printf '%s' "remove the git hooks and the merge driver (doc-superpowers hooks uninstall --git)"
      else
        printf '%s' "remove the merge driver (doc-superpowers hooks uninstall --git --merge-driver-only)"
      fi
      ;;
    claude-install) printf '%s' "install the 3 Claude Code hooks (doc-superpowers hooks install --claude)" ;;
    claude-uninstall) printf '%s' "remove the Claude Code hooks (doc-superpowers hooks uninstall --claude)" ;;
    ci-install)
      printf '%s' "install the workflows ${a//,/, } with base $b, cron '$c', strict $d (doc-superpowers hooks install --ci --workflows=$a --base-branch $(_plan_shell_word "$b") --cron $(_plan_shell_word "$c") --ci-strict=$d)"
      ;;
    ci-uninstall) printf '%s' "remove the workflows ${a//,/, } (doc-superpowers hooks uninstall --ci --workflows=$a)" ;;
    search-install) printf '%s' "install doc-search's launcher and its Claude Code entry in .mcp.json (doc-superpowers hooks install --search)" ;;
    search-uninstall)
      printf '%s' "remove doc-search's launcher and its .mcp.json entry (doc-superpowers hooks uninstall --search); docs/search/config.json is left in place (git rm docs/search/config.json removes it)"
      ;;
    ledger-install) printf '%s' "install the ledger git hooks (doc-superpowers hooks install --ledger)" ;;
    ledger-uninstall) printf '%s' "remove the ledger git hooks (doc-superpowers hooks uninstall --ledger)" ;;
    ledger-claude-install) printf '%s' "install the ledger's Claude Code hooks (doc-superpowers hooks install --ledger-claude)" ;;
    ledger-claude-uninstall) printf '%s' "remove the ledger's Claude Code hooks (doc-superpowers hooks uninstall --ledger-claude)" ;;
    harness-add)
      _plan_harness "$a"
      if harness_entry_present "$a"; then
        printf '%s' "refresh the doc-search server entry for $_PH_NAME in $_PH_FILE (setup's block, as this version writes it)"
      else
        printf '%s' "add the doc-search server entry for $_PH_NAME to $_PH_FILE"
      fi
      [ "$a" != codex ] || printf '%s' " (Codex loads it only for a trusted project)"
      ;;
    harness-remove)
      _plan_harness "$a"
      printf '%s' "remove the doc-search server entry for $_PH_NAME from $_PH_FILE (the entry alone: the file, and anything else in it, stays)"
      ;;
    envhook)
      case "$a" in
        -) a="as it is" ;;
        host) a="the host default (its lines removed)" ;;
      esac
      [ "$b" != - ] || b="as it is (the launcher finds the plugin cache)"
      printf '%s' "write the doc-superpowers block of your env hook $_PLAN_ENVFILE: cache $a, DOC_SUPERPOWERS_ROOT $b"
      ;;
    exclude-local) printf '%s' "keep $PROBE_LOCAL_FILE out of git (a marked block in $_PLAN_EXCLUDE)" ;;
    bin-link) printf '%s' "write the terminal command $_PLAN_BIN" ;;
    bin-unlink) printf '%s' "remove the terminal command $_PLAN_BIN" ;;
    record-team) printf '%s' "record the team's setup: .setup in $PROBE_STATE_FILE" ;;
    record-local) printf '%s' "record your own setup: $PROBE_LOCAL_FILE" ;;
    build) printf '%s' "build doc-search's indexes, downloading first (sh .claude/doc-superpowers/search-mcp.sh index)" ;;
    *) printf '%s' "$1" ;;
  esac
}

# _plan_print_section <header> <path|net|dl> [<line>…]: a review section; an
# empty one prints "  (nothing)".
_plan_print_section() {
  local kind="$2" e
  printf '%s\n' "$1"
  shift 2
  if [ "$#" -eq 0 ]; then
    echo "  (nothing)"
    return 0
  fi
  for e in "$@"; do
    case "$kind" in
      path) printf '  %s  %s\n' "${e%%"$_PLAN_T"*}" "${e#*"$_PLAN_T"}" ;;
      net) printf '  %s\n' "${e#*"$_PLAN_T"}" ;;
      dl) printf '  %s -- %s\n' "${e%%"$_PLAN_T"*}" "${e#*"$_PLAN_T"}" ;;
    esac
  done
}

# plan_render_review: the steps, then what they write (committed for the
# team, local to you, outside the repository), the network, the downloads,
# and the git add line for the team's paths.
plan_render_review() {
  local n=0 line e p paths="" all=""
  echo "Steps:"
  if [ "${#PLAN[@]}" -eq 0 ]; then
    echo "  (nothing)"
  else
    for line in "${PLAN[@]}"; do
      n=$((n + 1))
      printf '  %d. %s\n' "$n" "$(_plan_op_text "$line")"
    done
  fi
  _plan_print_section "Committed for the team:" path ${W_TEAM[@]+"${W_TEAM[@]}"}
  _plan_print_section "Local to you:" path ${W_LOCAL[@]+"${W_LOCAL[@]}"}
  _plan_print_section "Local to you (outside the repository):" path ${W_OUTSIDE[@]+"${W_OUTSIDE[@]}"}
  _plan_print_section "Network:" net ${NET[@]+"${NET[@]}"}
  _plan_print_section "Downloads:" dl ${DL[@]+"${DL[@]}"}
  # The git add line runs as printed: a path a step may delete is on it only
  # when git tracks it (else git add fails for every path), and then -A
  # stages the deletion.
  echo "Then commit:"
  for e in ${W_TEAM[@]+"${W_TEAM[@]}"}; do
    p="${e%%"$_PLAN_T"*}"
    case "$_PLAN_GONE" in
      *"|$p|"*)
        (cd "$TOP" && git ls-files --error-unmatch -- "$p" >/dev/null 2>&1) || continue
        all=" -A"
        ;;
    esac
    paths="$paths $(_plan_shell_word "$p")"
  done
  if [ -z "$paths" ]; then
    echo "  (nothing)"
  else
    printf '  git add%s --%s\n' "$all" "$paths"
  fi
  plan_render_harness_notes
}
