#!/usr/bin/env bash
set -euo pipefail

# doc-superpowers hooks installer. `install.sh help` lists the commands.
#
# WHERE it writes — git plumbing, never guesses from the cwd. Every command
# first cds to `git rev-parse --show-toplevel` (a linked worktree or a
# submodule is its own top). Git hooks go to `git rev-parse --git-path hooks`,
# where git runs them: core.hooksPath, a worktree's common dir, a submodule's
# .git/modules/<name>/hooks. A core.hooksPath from any config but this
# repository's own (global, system) is refused: it is every repository's.
#
# HOW it writes — never through a symbolic link (safe_dest: a link at the
# target or at any directory between the repository top, or git's common dir,
# and the target is refused), and every file through a temp file beside it,
# then mv. Every check runs before the first write (the preflight_* steps), so
# a refused run writes nothing.
#
# WHAT it owns — exactly, never by a substring:
#   - a git hook whose first lines carry "doc-superpowers hook v<N>"; in a
#     hook of yours, the "# doc-superpowers:begin" … "# doc-superpowers:end"
#     block and the local copy .doc-superpowers-<hook> beside it;
#   - the same marked block in .gitattributes and in git's info/exclude;
#   - the merge.doc-index.* git config keys;
#   - in .claude/settings.local.json, each hook ENTRY whose command runs one of
#     .claude/hooks/doc-superpowers/{pre-commit-gate,post-commit-sync,session-summary}.sh
#     (a group is removed only when it held nothing else);
#   - a workflow whose first lines carry "doc-superpowers workflow v<N>" —
#     a RETIRED one too (doc-index-update.yml): any install --ci removes it;
#   - vendored files: `doc-tools.sh tools install|uninstall` decide (uninstall
#     removes only files identical to the plugin's copies, and says what it kept).
#
# STATE — the CI tier's choices (workflow set, base branch, cron, strict) are
# recorded in .claude/doc-superpowers/installed.json (state.sh), so a plain
# re-install reproduces them.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOC_TOOLS="$SKILL_DIR/scripts/doc-tools.sh"
# The plugin-cache parent (holding every version dir), for a plugin-cache install.
DOC_TOOLS_PARENT="$(dirname "$SKILL_DIR")"
DATE=$(date +%Y-%m-%d)

GIT_HOOKS="pre-commit post-merge post-checkout prepare-commit-msg pre-push"
CLAUDE_HOOKS="pre-commit-gate post-commit-sync session-summary"
CLAUDE_HOOKS_DIR=".claude/hooks/doc-superpowers"
SETTINGS_FILE=".claude/settings.local.json"
SHELL_WORKFLOWS="doc-freshness-pr doc-freshness-schedule"
CI_DEFAULT_WORKFLOWS="$SHELL_WORKFLOWS"
# Workflows an earlier version installed and this one no longer ships. A
# managed copy (the workflow marker) is removed by any install --ci and by a
# full uninstall, and its state entry dropped; a file without the marker is
# kept and reported. doc-index-update (retired in v3.0.0) recorded every doc
# edited on the base branch as verified, unread, and failed every run.
RETIRED_WORKFLOWS="doc-index-update"
VENDOR_DEST=".github/scripts"
BLOCK_BEGIN="# doc-superpowers:begin"
BLOCK_END="# doc-superpowers:end"

# The workflow templates, once (a membership test is a string match).
KNOWN_WORKFLOWS=""
for _f in "$SCRIPT_DIR"/ci/*.yml; do
  [ -f "$_f" ] || continue
  _f="${_f##*/}"
  KNOWN_WORKFLOWS="$KNOWN_WORKFLOWS ${_f%.yml}"
done
KNOWN_WORKFLOWS="${KNOWN_WORKFLOWS# }"

# The plugin's version, parsed by doc-tools.sh (the first release heading of
# RELEASE-NOTES.md, line-anchored and outside code fences — the one parser
# check-version uses too), run under this installer's own bash. The AI
# templates carry it as DOC_SUPERPOWERS_VERSION, and their plugin step
# (doc-superpowers-steps/prepare-agent.sh) installs the plugin from the tag
# v<version>. Only rendering a template that holds __VERSION__ uses it, so it
# is looked up there, once, never on status / uninstall / help. A missing or
# malformed RELEASE-NOTES.md does not abort the install: the version is
# "unknown", with one WARN — and that workflow's plugin step then fails with
# an ::error:: until it is re-installed from a released plugin.
VERSION=""
ci_version() {
  [[ -z "$VERSION" ]] || return 0
  if ! VERSION=$("$BASH" "$DOC_TOOLS" tools version 2>/dev/null) || [[ -z "$VERSION" ]]; then
    VERSION="unknown"
    echo "  WARN: cannot read the plugin version from $SKILL_DIR/RELEASE-NOTES.md (doc-tools.sh tools version); workflows get DOC_SUPERPOWERS_VERSION \"vunknown\", and their plugin step fails until you re-install from a released plugin" >&2
  fi
}

# shellcheck source=scripts/hooks/state.sh
source "$SCRIPT_DIR/state.sh"

# --- Help ----------------------------------------------------------------------

workflow_desc() {
  case "$1" in
    doc-freshness-pr) echo "PR opened/updated: one comment with the docs the diff leaves stale or missing; STRICT fails the check (contents: read, pull-requests: write)" ;;
    doc-freshness-schedule) echo "weekly cron: opens/updates/closes an audit issue (contents: read, issues: write)" ;;
    doc-audit-update) echo "push to a non-base branch leaving docs stale: AI audit + update, a checked step commits docs to that branch (contents: write)" ;;
    doc-review-pr) echo "PR opened/updated touching indexed docs: AI review comment; @claude PR comments: tag mode (contents: read, pull-requests + issues: write)" ;;
    doc-release) echo "push to release/**: AI release-notes draft, a checked step commits it to a new branch and opens a PR (contents + pull-requests: write)" ;;
    doc-spec-verify) echo "PR opened/updated touching indexed specs: AI spec-compliance comment (contents: read, pull-requests: write)" ;;
    doc-pr-full-cycle) echo "PR opened touching indexed docs: AI review + update + diagram + sync, a checked step commits docs to the PR branch (contents + pull-requests: write)" ;;
    doc-pr-release) echo "PR pushes: AI release-notes fragment, a checked step commits it to the PR branch; PR body edited (contents + pull-requests: write)" ;;
    *) echo "(no description)" ;;
  esac
}

usage() {
  local w
  cat <<EOF
doc-superpowers hooks installer

Usage:
  install.sh install   [--git] [--claude] [--ci] [--all] [CI options]
  install.sh uninstall [--git] [--claude] [--ci] [--all] [--workflows=<csv|all|none>] [--transient]
  install.sh status    [--git] [--claude] [--ci] [--all]
  install.sh help

Every command acts on the repository holding the current directory, at its
top level (a linked worktree or a submodule is its own top level). Nothing is
ever written through a symbolic link.

Tiers:
  --git     Git hooks, where git runs them (git rev-parse --git-path hooks):
              pre-commit          reports the docs a commit leaves stale (STRICT: blocks it)
              post-merge          reports the docs a merge left stale or missing
              post-checkout       reports the docs stale on the branch checked out
              prepare-commit-msg  lists stale docs as comment lines (editor commits)
              pre-push            reminds about unreleased commits on the pushed refs
            plus the docs/.doc-index.json merge driver (git config + .gitattributes).
            A hook of yours is kept: when it is a shell script, a marked block
            that runs ours (with git's arguments) goes right after its #! line.
            A core.hooksPath from your global or system git config is refused.
  --claude  Claude Code hooks, per-user: registered in .claude/settings.local.json,
            both it and .claude/hooks/doc-superpowers/ excluded from git through
            git's info/exclude; commands run "\$CLAUDE_PROJECT_DIR"/.claude/hooks/…:
              pre-commit-gate   PreToolUse   checks the staged tree of a git commit
              post-commit-sync  PostToolUse  reports the docs a commit left stale
              session-summary   Stop         reports docs citing changed working-tree code
  --ci      GitHub Actions workflows, plus doc-tools.sh (and the helpers the
            installed workflows run) vendored into .github/scripts/ via
            doc-tools.sh tools install. Default: the shell workflows; the
            Claude-powered ones are opt-in by name (--workflows=).
  --all     All three tiers.

CI options (install --ci / --all):
  --workflows=<csv|all|none>
            A CSV of names: install those (an explicit name overrides an earlier
            "removed on purpose"). all: every template, except those removed on
            purpose. none: no workflow, only the vendored doc-tools.sh.
            Without it: the recorded set (a first install: the shell workflows).
  --base-branch NAME        target branch (default: main)
  --cron EXPR               schedule, 5 fields (default: 0 9 * * 1)
  --ci-strict[=true|false]  the PR check fails on stale docs (default: false)
  --helpers=<true|false>    ship the doc-pr-release producer helpers (default:
                            true); refused while doc-pr-release is selected or
                            installed, since it runs them
  --force                   also re-install workflows removed on purpose
  The choices are recorded (.claude/doc-superpowers/installed.json, commit it):
  a plain 'install --ci' reproduces the recorded set, branch, cron and strict.

Uninstall options (uninstall --ci):
  --workflows=<csv|all|none>  which workflows (default: all of them, and the
                              vendored files)
  --transient                 record the removal as temporary: the next plain
                              install --ci puts them back

Workflows (--workflows= names):
EOF
  echo "  shell (the default set):"
  for w in $KNOWN_WORKFLOWS; do
    in_list "$w" "$SHELL_WORKFLOWS" || continue
    printf '    %-24s %s\n' "$w" "$(workflow_desc "$w")"
  done
  echo "  Claude-powered (opt-in; need the CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY secret):"
  for w in $KNOWN_WORKFLOWS; do
    in_list "$w" "$SHELL_WORKFLOWS" && continue
    printf '    %-24s %s\n' "$w" "$(workflow_desc "$w")"
  done
}

# --- Small helpers -------------------------------------------------------------

die() {
  echo "ERROR: $*" >&2
  exit 1
}

usage_error() {
  echo "ERROR: $*" >&2
  echo "       See: install.sh help" >&2
  exit 2
}

in_list() {
  case " $2 " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# The first lines of <file> carry <marker> (pure bash: no process per file).
has_marker() {
  local line n=0
  [ -f "$1" ] || return 1
  while [ "$n" -lt 5 ] && IFS= read -r line; do
    case "$line" in
      *"$2"[0-9]*) return 0 ;;
    esac
    n=$((n + 1))
  done < "$1"
  return 1
}
is_our_hook() { has_marker "$1" "doc-superpowers hook v"; }
is_managed_workflow() { has_marker "$1" "doc-superpowers workflow v"; }

file_mode() {
  local m=""
  m=$(stat -c '%a' "$1" 2>/dev/null) || m=$(stat -f '%Lp' "$1" 2>/dev/null) || m=""
  case "$m" in
    [0-7][0-7][0-7] | [0-7][0-7][0-7][0-7]) printf '%s' "$m" ;;
    *) return 1 ;;
  esac
}

# A value for the replacement side of sed's s|…|…|: \ & and the | delimiter escaped.
sed_repl() {
  printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

# <text> single-quoted for sh.
sh_squote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# --- Safe writes ---------------------------------------------------------------

WRITING=0   # 1 once the first write happened (preflight is over)
_TMPS=()
_cleanup() {
  local t
  for t in ${_TMPS[@]+"${_TMPS[@]}"}; do
    rm -f "$t"
  done
  return 0
}
trap _cleanup EXIT
trap '_cleanup; exit 130' INT
trap '_cleanup; exit 143' TERM

# safe_dest <path>: exit 1 when <path>, or a directory between the repository
# top (or git's common dir) and it, is a symbolic link. A committed link would
# point the write anywhere: .claude → ~/.claude, .githooks/pre-commit →
# ~/.bashrc. A path outside both is checked with its own directory only
# (system links such as /var → /private/var are not the repository's).
safe_dest() {
  local p="$1" stop=""
  case "$p" in
    /*)
      case "$p" in
        "$TOP_ABS"/*) p="${p#"$TOP_ABS"/}" ;;
        "$GIT_COMMON_ABS"/*) stop="$GIT_COMMON_ABS" ;;
        *)
          stop="${p%/*}"
          stop="${stop%/*}"
          ;;
      esac
      ;;
  esac
  while [ -n "$p" ] && [ "$p" != "$stop" ] && [ "$p" != "/" ] && [ "$p" != "." ]; do
    if [ -L "$p" ]; then
      echo "ERROR: $p is a symbolic link$([ "$p" = "$1" ] || printf ' (on the way to %s)' "$1"): the installer never writes through a link, which could point anywhere (a committed one at ~/.bashrc). Replace it with a real file or directory, or leave this tier out.$([ "$WRITING" = 1 ] || printf ' Nothing was changed.')" >&2
      exit 1
    fi
    case "$p" in
      */*) p="${p%/*}" ;;
      *) p="" ;;
    esac
  done
}

ensure_dir() {
  safe_dest "$1"
  [ -d "$1" ] || mkdir -p "$1" || die "cannot create $1"
}

# tmp_beside <dest>: an empty temp file in <dest>'s directory → _TMP. Call it
# in the main shell (the temp file is registered for removal on exit).
tmp_beside() {
  local dir
  WRITING=1
  safe_dest "$1"
  dir=$(dirname "$1")
  ensure_dir "$dir"
  _TMP=$(mktemp "$dir/.${1##*/}.XXXXXX") || die "cannot create a temp file beside $1"
  _TMPS+=("$_TMP")
}

# commit_tmp <dest> <mode for a new file> [exec]: _TMP becomes <dest>. An
# existing <dest> keeps its mode; [exec] = 1 also makes it executable. When
# the content is unchanged, <dest> is left alone (its mtime too).
commit_tmp() {
  local dest="$1" mode="$2" m
  if [ -f "$dest" ] && cmp -s "$_TMP" "$dest"; then
    rm -f "$_TMP"
    if [ "${3:-0}" = 1 ] && [ ! -x "$dest" ]; then
      chmod a+x "$dest" || die "cannot chmod a+x $dest"
    fi
    return 0
  fi
  if [ -f "$dest" ] && m=$(file_mode "$dest"); then
    mode="$m"
  fi
  chmod "$mode" "$_TMP" || die "cannot chmod $mode $_TMP"
  if [ "${3:-0}" = 1 ]; then
    chmod a+x "$_TMP" || die "cannot chmod a+x $_TMP"
  fi
  mv -f "$_TMP" "$dest" || die "cannot replace $dest"
}

remove_file() {
  WRITING=1
  safe_dest "$1"
  rm -f "$1" || die "cannot remove $1"
}

remove_dir_if_empty() {
  if [ -d "$1" ] && [ ! -L "$1" ]; then
    rmdir "$1" 2>/dev/null || true
  fi
  return 0
}

# --- Marked blocks ---------------------------------------------------------------

# The "# doc-superpowers:begin" / ":end" lines of <file> pair up (an unpaired
# begin would make a removal run to the end of the file).
blocks_balanced() {
  [ -f "$1" ] || return 0
  awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" '
    index($0, b) == 1 { if (open) bad = 1; open = 1 }
    index($0, e) == 1 { if (!open) bad = 1; open = 0 }
    END { exit (bad || open) ? 1 : 0 }' "$1"
}

check_blocks() {
  blocks_balanced "$1" \
    || die "$1 has a '$BLOCK_BEGIN' line without its '$BLOCK_END' (or the reverse): fix or remove the doc-superpowers lines by hand, then re-run. Nothing was changed."
}

# strip_blocks <file>: <file> without its marked blocks, on stdout. Also
# removes what the pre-3.0 installer wrote:
#   - in a hook, its block (the body ran the hook with "2>/dev/null || true")
#     and the blank line it added: after the block when an "exit 0" follows,
#     before it when the block ends the file;
#   - in .gitattributes, its two lines (the "auto-resolve" comment and the
#     docs/.doc-index.json line after it) and the blank line before them.
strip_blocks() {
  awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" '
    { line[NR] = $0 }
    END {
      o = 0; i = 1
      legacy_attr = "# doc-superpowers: auto-resolve doc-index.json merge conflicts"
      while (i <= NR) {
        if (index(line[i], b) == 1) {
          old = 0; j = i
          while (j <= NR && index(line[j], e) != 1) { if (index(line[j], "2>/dev/null || true")) old = 1; j++ }
          if (old) {
            if (j + 2 <= NR && line[j + 1] == "" && index(line[j + 2], "exit 0") == 1) j++
            else if (j >= NR && o > 0 && out[o] == "") o--
          }
          i = j + 1
          continue
        }
        if (line[i] == legacy_attr && i < NR && line[i + 1] == "docs/.doc-index.json merge=doc-index") {
          if (o > 0 && out[o] == "") o--
          i += 2
          continue
        }
        out[++o] = line[i]; i++
      }
      for (k = 1; k <= o; k++) print out[k]
    }' "$1"
}

# has_block <file>: the file holds a marked block or the pre-3.0 attribute lines.
has_block() {
  [ -f "$1" ] || return 1
  grep -qF -e "$BLOCK_BEGIN" -e "# doc-superpowers: auto-resolve doc-index.json merge conflicts" "$1"
}

# upsert_block <file> <block text> <mode>: <file> without our old block(s),
# then the block appended (no blank line before it, so removal is exact).
upsert_block() {
  local f="$1"
  tmp_beside "$f"
  {
    if [ -f "$f" ]; then
      strip_blocks "$f"
    fi
    printf '%s\n' "$2"
  } > "$_TMP"
  commit_tmp "$f" "$3"
}

# remove_block <file>: drop our block(s); a file left with only blank lines
# (the installer created it) is removed.
remove_block() {
  local f="$1"
  has_block "$f" || return 0
  tmp_beside "$f"
  strip_blocks "$f" > "$_TMP"
  if ! grep -q '[^[:space:]]' "$_TMP"; then
    rm -f "$_TMP"
    remove_file "$f"
    return 0
  fi
  commit_tmp "$f" 644
}

# --- Rendering -------------------------------------------------------------------

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
# The hooks resolve doc-tools.sh by the same rule (_DT_RESOLVE).
# shellcheck disable=SC2016  # sh programs for git to run, not bash expansions
_MD_RESOLVE='if [ -d "$t" ]; then v=$(for d in "$t"/*/; do d=$(basename "$d"); [ -f "$t/$d/scripts/merge-doc-index.sh" ] && echo "$d"; done | grep -Ex "[0-9]+[.][0-9]+[.][0-9]+" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1); if [ -n "$v" ]; then t=$t/$v/scripts/merge-doc-index.sh; fi; fi'
# shellcheck disable=SC2016
_MD_RUN='if [ -f "$t" ]; then exec bash "$t" "$@"; fi; echo "doc-superpowers: merge driver not found ($t); leaving conflict markers" >&2; git merge-file -L ours -L base -L theirs "$2" /dev/null "$3"; exit 1'
_DT_RESOLVE="${_MD_RESOLVE//merge-doc-index.sh/doc-tools.sh}"

# What a registration or a hook names for scripts/<name>: the version-dir
# parent (plugin cache), or the script itself (a checkout).
_resolve_target() {
  local re='^[0-9]+\.[0-9]+\.[0-9]+$' base
  base=$(basename "$SKILL_DIR")
  if [[ "$base" =~ $re ]]; then
    printf '%s' "$DOC_TOOLS_PARENT"
  else
    printf '%s' "$SKILL_DIR/scripts/$1"
  fi
}
merge_driver_target() { _resolve_target merge-doc-index.sh; }

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

# The program a hook runs to find doc-tools.sh (when $DOC_TOOLS is unset),
# substituted for __DOC_TOOLS_RESOLVE__ — sed-escaped once, here.
RESOLVE_REPL=$(sed_repl "t=$(sh_squote "$(_resolve_target doc-tools.sh)"); $_DT_RESOLVE; printf '%s' \"\$t\"")

render_hook() {
  sed -e "s|__INSTALL_DATE__|$DATE|g" -e "s|__DOC_TOOLS_RESOLVE__|$RESOLVE_REPL|g" "$1"
}

# CI choices, sed-escaped when the plan is made (render_workflow runs in $(…)).
render_workflow() {
  sed \
    -e "s|__BASE_BRANCH__|$R_BASE|g" \
    -e "s|__VERSION__|v$R_VERSION|g" \
    -e "s|__CRON_SCHEDULE__|$R_CRON|g" \
    -e "s|__CI_STRICT__|$R_STRICT|g" \
    "$1"
}

# --- Placement -------------------------------------------------------------------

enter_repo() {
  local top
  if ! top=$(git rev-parse --show-toplevel 2>/dev/null) || [ -z "$top" ]; then
    echo "ERROR: not a git repo (or not inside its work tree): run the installer from the repository to install into." >&2
    exit 1
  fi
  cd "$top" || die "cannot enter $top"
  TOP_ABS=$(pwd -P)
  GIT_COMMON_ABS=$(cd "$(git rev-parse --git-common-dir)" && pwd -P) || die "cannot find git's directory"
  HOOKS_DIR=$(git rev-parse --git-path hooks) || die "git rev-parse --git-path hooks failed"
  EXCLUDE_FILE=$(git rev-parse --git-path info/exclude) || die "git rev-parse --git-path info/exclude failed"
}

# The config scope core.hooksPath comes from ("" when unset).
hooks_path_scope() {
  local line rc=0 eff loc
  line=$(git config --show-scope --get core.hooksPath 2>/dev/null) || rc=$?
  case "$rc" in
    0) printf '%s' "${line%%$'\t'*}" ;;
    1) printf '' ;;
    *) # git < 2.26: no --show-scope. Local iff the value is the local one.
      eff=$(git config --get core.hooksPath 2>/dev/null || true)
      loc=$(git config --local --get core.hooksPath 2>/dev/null || true)
      if [ -z "$eff" ]; then
        printf ''
      elif [ "$eff" = "$loc" ]; then
        printf 'local'
      else
        printf 'global'
      fi
      ;;
  esac
}

check_hooks_path_scope() {
  local scope
  scope=$(hooks_path_scope)
  case "$scope" in
    "" | local) ;;
    *)
      echo "ERROR: core.hooksPath is set in your $scope git config ($(git config --get core.hooksPath)). Git runs every repository's hooks from there, so installing into it would add doc-superpowers hooks to all of them. Set a repository-local one (git config --local core.hooksPath <dir>) or unset the $scope one, then re-run. Nothing was changed." >&2
      exit 1
      ;;
  esac
}

# --- Git tier ----------------------------------------------------------------------

# The block that runs our copy from a hook of yours. POSIX sh; it goes right
# after the #! line, so it runs before anything of yours can exit or exec.
# pre-commit passes our exit code on (DOC_SUPERPOWERS_STRICT blocks the
# commit); the others never stop your hook. pre-push reads the ref lines on
# stdin, so the block hands ours a copy and your hook the same lines.
integration_block() {
  local hook="$1"
  printf '%s (managed by doc-superpowers install.sh --git; uninstall --git removes it)\n' "$BLOCK_BEGIN"
  # shellcheck disable=SC2016  # hook code, expanded when the hook runs
  printf 'DOC_SP_HOOK="$(dirname "$0")/.doc-superpowers-%s"\n' "$hook"
  case "$hook" in
    pre-commit)
      # shellcheck disable=SC2016
      echo 'if [ -f "$DOC_SP_HOOK" ]; then bash "$DOC_SP_HOOK" "$@" || exit $?; fi'
      ;;
    pre-push)
      # shellcheck disable=SC2016
      echo 'if [ -f "$DOC_SP_HOOK" ] && DOC_SP_IN=$(mktemp "${TMPDIR:-/tmp}/doc-sp-push.XXXXXX"); then'
      # shellcheck disable=SC2016
      echo '  cat > "$DOC_SP_IN"; bash "$DOC_SP_HOOK" "$@" < "$DOC_SP_IN" || true; exec < "$DOC_SP_IN"; rm -f "$DOC_SP_IN"'
      echo 'fi'
      ;;
    *)
      # shellcheck disable=SC2016
      echo 'if [ -f "$DOC_SP_HOOK" ]; then bash "$DOC_SP_HOOK" "$@" || true; fi'
      ;;
  esac
  printf '%s\n' "$BLOCK_END"
}

# A hook git (or sh, for a hook without #!) runs as a shell script: our POSIX
# block can go into it. Another interpreter (python, node, …) cannot take it.
host_is_shell() {
  local first w1 w2 w3
  first=""
  IFS= read -r first < "$1" || true
  case "$first" in
    '#!'*) ;;
    *) return 0 ;;
  esac
  read -r w1 w2 w3 _ <<<"${first#\#!}"
  w1="${w1##*/}"
  if [ "$w1" = env ]; then
    w1="$w2"
    case "$w1" in
      -*) w1="$w3" ;;
    esac
  fi
  case "${w1##*/}" in
    sh | bash | dash | zsh | ksh | mksh | ash | yash | posh) return 0 ;;
  esac
  return 1
}

# <host> without our block(s), our block inserted after its #! line, on stdout.
integrate_hook() {
  local blk line
  blk=$(integration_block "$2")
  strip_blocks "$1" | {
    if IFS= read -r line || [ -n "$line" ]; then
      case "$line" in
        '#!'*) printf '%s\n%s\n' "$line" "$blk" ;;
        *) printf '%s\n%s\n' "$blk" "$line" ;;
      esac
      cat
    else
      printf '%s\n' "$blk"
    fi
  }
}

# The integration state of <hook> in HOOKS_DIR: ours | current | outdated | none.
hook_state() {
  local dest="$HOOKS_DIR/$1"
  if is_our_hook "$dest"; then
    echo ours
  elif [ -f "$dest" ] && grep -qF "$BLOCK_BEGIN" "$dest"; then
    if grep -qxF "$(integration_block "$1" | sed -n 3p)" "$dest" && [ -f "$HOOKS_DIR/.doc-superpowers-$1" ]; then
      echo current
    else
      echo outdated
    fi
  else
    echo none
  fi
}

ATTR_BLOCK="$BLOCK_BEGIN — the doc-index merge driver (install.sh --git; uninstall --git removes this block)
docs/.doc-index.json merge=doc-index
$BLOCK_END"

preflight_git() {
  local hook dest
  check_hooks_path_scope
  safe_dest "$HOOKS_DIR"
  for hook in $GIT_HOOKS; do
    dest="$HOOKS_DIR/$hook"
    safe_dest "$dest"
    safe_dest "$HOOKS_DIR/.doc-superpowers-$hook"
    if [ -f "$dest" ] && ! is_our_hook "$dest"; then
      check_blocks "$dest"
    fi
  done
  safe_dest .gitattributes
  check_blocks .gitattributes
}

install_git() {
  local hook src dest copy installed=0 integrated=0 skipped=0
  ensure_dir "$HOOKS_DIR"
  echo "  Hooks directory: $HOOKS_DIR"
  for hook in $GIT_HOOKS; do
    src="$SCRIPT_DIR/git/$hook"
    [ -f "$src" ] || continue
    dest="$HOOKS_DIR/$hook"
    copy="$HOOKS_DIR/.doc-superpowers-$hook"
    if [ ! -e "$dest" ] || is_our_hook "$dest"; then
      tmp_beside "$dest"
      render_hook "$src" > "$_TMP"
      commit_tmp "$dest" 755 1
      if [ -f "$copy" ]; then
        remove_file "$copy"
      fi
      installed=$((installed + 1))
    elif host_is_shell "$dest"; then
      tmp_beside "$copy"
      render_hook "$src" > "$_TMP"
      commit_tmp "$copy" 755 1
      tmp_beside "$dest"
      integrate_hook "$dest" "$hook" > "$_TMP"
      commit_tmp "$dest" 755
      echo "  Integrated $hook into your existing hook (a marked block after its #! line runs ours)"
      integrated=$((integrated + 1))
    else
      echo "  Skipped $hook: your existing hook is not a shell script, so no block can go into it (remove it, or run the doc-superpowers hook from it yourself)"
      skipped=$((skipped + 1))
    fi
  done

  # The three-way merge driver for docs/.doc-index.json (merge_driver_cmd:
  # resolved at merge time, path quoted). Re-running install replaces an
  # older, pinned registration.
  if [[ -f "$SKILL_DIR/scripts/merge-doc-index.sh" ]]; then
    git config --local merge.doc-index.name "doc-superpowers index merger"
    git config --local merge.doc-index.driver "$(merge_driver_cmd)"
    if ! has_block .gitattributes || grep -qF "auto-resolve doc-index.json" .gitattributes; then
      echo "  Added merge driver to .gitattributes"
    fi
    upsert_block .gitattributes "$ATTR_BLOCK" 644
    echo "  Registered merge driver: doc-index (a merge runs: $(merge_driver_resolved))"
  fi

  echo "Git hooks: $installed installed, $integrated integrated, $skipped skipped"
}

uninstall_git() {
  local hook dest copy removed=0
  for hook in $GIT_HOOKS; do
    dest="$HOOKS_DIR/$hook"
    copy="$HOOKS_DIR/.doc-superpowers-$hook"
    if is_our_hook "$dest"; then
      remove_file "$dest"
      removed=$((removed + 1))
    elif [ -f "$dest" ] && grep -qF "$BLOCK_BEGIN" "$dest"; then
      tmp_beside "$dest"
      strip_blocks "$dest" > "$_TMP"
      commit_tmp "$dest" 755
      removed=$((removed + 1))
    fi
    if [ -f "$copy" ]; then
      remove_file "$copy"
    fi
  done

  if git config --local --get merge.doc-index.driver >/dev/null 2>&1 \
    || git config --local --get merge.doc-index.name >/dev/null 2>&1; then
    git config --local --unset merge.doc-index.name 2>/dev/null || true
    git config --local --unset merge.doc-index.driver 2>/dev/null || true
    if ! git config --local --get-regexp '^merge\.doc-index\.' >/dev/null 2>&1; then
      git config --local --remove-section merge.doc-index 2>/dev/null || true
    fi
    echo "  Unregistered merge driver: doc-index"
  fi
  if has_block .gitattributes; then
    remove_block .gitattributes
    echo "  Removed merge driver from .gitattributes"
  fi

  echo "Git hooks: $removed removed (from $HOOKS_DIR)"
}

status_git() {
  local hook dest scope st install_date
  scope=$(hooks_path_scope)
  if [ -n "$scope" ] && [ "$scope" != local ]; then
    echo "Git Hooks (dir: $HOOKS_DIR — from your $scope core.hooksPath: not this repository's; install --git refuses it):"
  else
    echo "Git Hooks (dir: $HOOKS_DIR):"
  fi
  for hook in $GIT_HOOKS; do
    dest="$HOOKS_DIR/$hook"
    st=$(hook_state "$hook")
    case "$st" in
      ours)
        install_date=$(head -3 "$dest" | sed -n 's/.*installed \([0-9-]*\).*/\1/p')
        if [ -x "$dest" ]; then
          printf "  ✓ %-22s installed %s\n" "$hook" "${install_date:-unknown}"
        else
          printf "  ⚠ %-22s installed but not executable (git skips it): chmod +x %s\n" "$hook" "$dest"
        fi
        ;;
      current) printf "  ✓ %-22s integrated (a block in your hook runs ours)\n" "$hook" ;;
      outdated) printf "  ⚠ %-22s integrated with an outdated block (or its copy is missing): re-run install --git\n" "$hook" ;;
      *) printf "  ✗ %-22s not installed\n" "$hook" ;;
    esac
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
  if [ "$(git check-attr merge -- docs/.doc-index.json 2>/dev/null)" = "docs/.doc-index.json: merge: doc-index" ]; then
    printf "  ✓ %-22s configured\n" ".gitattributes"
  else
    printf "  ✗ %-22s not configured\n" ".gitattributes"
  fi
}

# --- Claude tier ---------------------------------------------------------------------

# An entry is the installer's when its command runs one of its scripts.
# shellcheck disable=SC2016  # jq programs
_CLAUDE_JQ_DEFS='
  def ours: type == "object" and .type == "command" and ((.command | type) == "string")
            and (.command | test("\\.claude/hooks/doc-superpowers/(pre-commit-gate|post-commit-sync|session-summary)\\.sh"));
  def holds_ours: type == "object" and ((.hooks | type) == "array") and any(.hooks[]; ours);
  def strip: map(if holds_ours then (.hooks |= map(select(ours | not))) | select(.hooks | length > 0) else . end);
  def shape:
    if type != "object" then error("it is not a JSON object")
    elif has("hooks") and (.hooks | type) != "object" then error(".hooks is not an object")
    elif ((.hooks // {}) | to_entries | any(.value | type != "array")) then error("a .hooks event is not an array")
    else . end;'

claude_cmd() {
  # shellcheck disable=SC2016  # expanded by the shell Claude Code runs it in
  printf 'bash "$CLAUDE_PROJECT_DIR"/%s/%s.sh' "$CLAUDE_HOOKS_DIR" "$1"
}

# The settings file as one compact JSON object ({} when absent or empty).
settings_read() {
  if [ ! -e "$SETTINGS_FILE" ]; then
    echo '{}'
    return 0
  fi
  jq -cs 'if length == 0 then {} elif length == 1 then .[0] else error("it holds more than one JSON value") end' "$SETTINGS_FILE" 2>&1
}

settings_refuse() {
  echo "ERROR: $SETTINGS_FILE cannot be read as Claude Code settings (${1#jq: error*: }). Fix it, then re-run. Nothing was changed." >&2
  exit 1
}

EXCLUDE_BLOCK="$BLOCK_BEGIN — the per-user Claude Code hook tier (install.sh --claude; uninstall --claude removes this block)
$SETTINGS_FILE
$CLAUDE_HOOKS_DIR/
$BLOCK_END"

SETTINGS_NEW=""
preflight_claude() {
  local cur h
  ensure_safe_claude_paths
  cur=$(settings_read) || settings_refuse "$cur"
  SETTINGS_NEW=$(jq \
    --argjson pte "$(jq -cn --arg c "$(claude_cmd pre-commit-gate)" '{matcher: "Bash", hooks: [{type: "command", command: $c, timeout: 10}]}')" \
    --argjson pote "$(jq -cn --arg c "$(claude_cmd post-commit-sync)" '{matcher: "Bash", hooks: [{type: "command", command: $c, timeout: 10}]}')" \
    --argjson se "$(jq -cn --arg c "$(claude_cmd session-summary)" '{matcher: "", hooks: [{type: "command", command: $c, timeout: 10}]}')" \
    "$_CLAUDE_JQ_DEFS"'
    shape
    | .hooks = (.hooks // {})
    | .hooks.PreToolUse = ((.hooks.PreToolUse // []) | strip) + [$pte]
    | .hooks.PostToolUse = ((.hooks.PostToolUse // []) | strip) + [$pote]
    | .hooks.Stop = ((.hooks.Stop // []) | strip) + [$se]' <<<"$cur" 2>&1) || settings_refuse "$SETTINGS_NEW"
  for h in $CLAUDE_HOOKS; do
    [ -f "$SCRIPT_DIR/claude/$h.sh" ] || die "the plugin's $SCRIPT_DIR/claude/$h.sh is missing. Nothing was changed."
  done
}

SETTINGS_STRIPPED="" SETTINGS_CUR=""
preflight_uninstall_claude() {
  local cur
  ensure_safe_claude_paths
  [ -e "$SETTINGS_FILE" ] || return 0
  cur=$(settings_read) || settings_refuse "$cur"
  SETTINGS_CUR="$cur"
  SETTINGS_STRIPPED=$(jq "$_CLAUDE_JQ_DEFS"'
    shape
    | if has("hooks") then
        . as $orig
        | reduce (.hooks | keys_unsorted[]) as $e (.;
            if any(.hooks[$e][]; holds_ours)
            then .hooks[$e] |= strip | (if (.hooks[$e] | length) == 0 then del(.hooks[$e]) else . end)
            else . end)
        | if (.hooks | length) == 0 and ($orig.hooks | length) > 0 then del(.hooks) else . end
      else . end' <<<"$cur" 2>&1) || settings_refuse "$SETTINGS_STRIPPED"
}

ensure_safe_claude_paths() {
  local h
  safe_dest "$SETTINGS_FILE"
  for h in $CLAUDE_HOOKS; do
    safe_dest "$CLAUDE_HOOKS_DIR/$h.sh"
  done
  safe_dest "$EXCLUDE_FILE"
  check_blocks "$EXCLUDE_FILE"
}

install_claude() {
  local h
  ensure_dir "$CLAUDE_HOOKS_DIR"
  for h in $CLAUDE_HOOKS; do
    tmp_beside "$CLAUDE_HOOKS_DIR/$h.sh"
    render_hook "$SCRIPT_DIR/claude/$h.sh" > "$_TMP"
    commit_tmp "$CLAUDE_HOOKS_DIR/$h.sh" 755 1
  done
  tmp_beside "$SETTINGS_FILE"
  printf '%s\n' "$SETTINGS_NEW" | jq . > "$_TMP"
  commit_tmp "$SETTINGS_FILE" 644
  upsert_block "$EXCLUDE_FILE" "$EXCLUDE_BLOCK" 644
  echo "Claude Code hooks: 3 installed (pre-commit-gate, post-commit-sync, session-summary)"
  echo "  Scripts in $CLAUDE_HOOKS_DIR/, registered in $SETTINGS_FILE — per-user: both are excluded from git ($EXCLUDE_FILE)"
  # An exclude entry cannot hide a file git already tracks.
  if git ls-files --error-unmatch -- "$SETTINGS_FILE" >/dev/null 2>&1; then
    echo "  NOTE: $SETTINGS_FILE is tracked by git, so this machine's hook wiring would be committed for everyone."
    echo "        Untrack it (git rm --cached $SETTINGS_FILE) to keep the tier per-user."
  fi
}

uninstall_claude() {
  local h any=0
  if [ -e "$SETTINGS_FILE" ] && [ "$(jq -c . <<<"$SETTINGS_STRIPPED")" != "$SETTINGS_CUR" ]; then
    if [ "$(jq -c . <<<"$SETTINGS_STRIPPED")" = "{}" ]; then
      remove_file "$SETTINGS_FILE"
    else
      tmp_beside "$SETTINGS_FILE"
      printf '%s\n' "$SETTINGS_STRIPPED" | jq . > "$_TMP"
      commit_tmp "$SETTINGS_FILE" 644
    fi
    any=1
  fi
  for h in $CLAUDE_HOOKS; do
    if [ -f "$CLAUDE_HOOKS_DIR/$h.sh" ]; then
      remove_file "$CLAUDE_HOOKS_DIR/$h.sh"
      any=1
    fi
  done
  remove_dir_if_empty "$CLAUDE_HOOKS_DIR"
  remove_dir_if_empty .claude/hooks
  remove_dir_if_empty .claude
  if has_block "$EXCLUDE_FILE"; then
    remove_block "$EXCLUDE_FILE"
    any=1
  fi
  if [ "$any" = 1 ]; then
    echo "Claude Code hooks: removed"
  else
    echo "Claude Code hooks: nothing to uninstall"
  fi
}

status_claude() {
  local h reg="" ev
  echo "Claude Code Hooks (per-user: $SETTINGS_FILE):"
  if [ -e "$SETTINGS_FILE" ]; then
    reg=$(jq -r "$_CLAUDE_JQ_DEFS"'
      [(.hooks // {}) | to_entries[] | select(.value | type == "array") | .key as $e
       | .value[] | select(type == "object" and ((.hooks | type) == "array")) | .hooks[] | select(ours)
       | "\($e) \(.command | capture("doc-superpowers/(?<n>[a-z-]+)\\.sh").n)"] | .[]' "$SETTINGS_FILE" 2>/dev/null) \
      || echo "  ⚠ $SETTINGS_FILE cannot be read as JSON"
  fi
  for h in $CLAUDE_HOOKS; do
    case "$h" in
      pre-commit-gate) ev=PreToolUse ;;
      post-commit-sync) ev=PostToolUse ;;
      *) ev=Stop ;;
    esac
    if grep -qxF "$ev $h" <<<"$reg"; then
      if [ -f "$CLAUDE_HOOKS_DIR/$h.sh" ]; then
        printf "  ✓ %-22s active (%s: script + settings)\n" "$h" "$ev"
      else
        printf "  ⚠ %-22s in settings but script missing from %s/\n" "$h" "$CLAUDE_HOOKS_DIR"
      fi
    else
      printf "  ✗ %-22s not installed\n" "$h"
    fi
  done
}

# --- CI tier -------------------------------------------------------------------------

# Branch names: what git accepts AND what a workflow line takes as is (the
# value lands in YAML flow lists, quoted strings and a shell command).
valid_branch() {
  local re='^[A-Za-z0-9][A-Za-z0-9._/-]*$'
  [[ "$1" =~ $re ]] && git check-ref-format "refs/heads/$1" >/dev/null 2>&1
}
# Five cron fields of digits, names, * , - / (GitHub's syntax).
valid_cron() {
  local re='^[A-Za-z0-9*,/-]+([[:space:]]+[A-Za-z0-9*,/-]+){4}$'
  [[ "$1" =~ $re ]]
}

# Parse a --workflows CSV into CSV_NAMES: trimmed, de-duplicated, validated.
parse_workflow_csv() {
  local raw="$1" n IFS_save="$IFS"
  CSV_NAMES=""
  IFS=','
  set -f
  # shellcheck disable=SC2086  # split on commas (globbing off)
  set -- $raw
  set +f
  IFS="$IFS_save"
  for n in "$@"; do
    n="${n#"${n%%[![:space:]]*}"}"
    n="${n%"${n##*[![:space:]]}"}"
    [ -n "$n" ] || continue
    if in_list "$n" "$RETIRED_WORKFLOWS"; then
      # Uninstall takes the name (removes an owned copy); install never
      # installs it.
      [ "$COMMAND" = uninstall ] || die "$n was retired in v3.0.0 (it recorded docs as verified that nobody had read) and is no longer installed; install --ci removes an installed copy."
    elif ! in_list "$n" "$KNOWN_WORKFLOWS"; then
      {
        echo "ERROR: unknown workflow name: $n"
        echo "Valid names:"
        for n in $KNOWN_WORKFLOWS; do echo "  - $n"; done
      } >&2
      exit 1
    fi
    in_list "$n" "$CSV_NAMES" || CSV_NAMES="${CSV_NAMES:+$CSV_NAMES }$n"
  done
  [ -n "$CSV_NAMES" ] || die "--workflows='$raw' names no workflow (use --workflows=none for none)"
}

# The managed workflows on disk, in template order.
disk_workflows() {
  local w out=""
  for w in $KNOWN_WORKFLOWS; do
    if is_managed_workflow ".github/workflows/$w.yml"; then
      out="${out:+$out }$w"
    fi
  done
  printf '%s' "$out"
}

# A choice the state does not record (a pre-3.0 install) read back from the
# rendered workflows, so an upgrade does not silently change it. (A retired
# doc-index-update.yml still counts: it is read before the upgrade removes it.)
infer_choice() {
  local f line v
  case "$1" in
    strict)
      f=.github/workflows/doc-freshness-pr.yml
      is_managed_workflow "$f" || return 0
      if grep -q 'DOC_SUPERPOWERS_STRICT: "1"' "$f"; then echo true; else echo false; fi
      ;;
    cron)
      f=.github/workflows/doc-freshness-schedule.yml
      is_managed_workflow "$f" || return 0
      line=$(grep -m1 -E "^[[:space:]]*- cron: '[^']*'" "$f" || true)
      v="${line#*\'}"
      v="${v%\'*}"
      if [ -n "$line" ] && valid_cron "$v"; then echo "$v"; fi
      ;;
    branch)
      for f in doc-freshness-pr doc-index-update doc-review-pr doc-spec-verify doc-pr-full-cycle doc-pr-release doc-audit-update; do
        f=".github/workflows/$f.yml"
        is_managed_workflow "$f" || continue
        line=$(grep -m1 -E '^[[:space:]]*branches(-ignore)?:[[:space:]]*\[[^],]+\][[:space:]]*$' "$f" || true)
        [ -n "$line" ] || continue
        v="${line#*[}"
        v="${v%]*}"
        v="${v#"${v%%[![:space:]]*}"}"
        v="${v%"${v##*[![:space:]]}"}"
        if valid_branch "$v"; then
          echo "$v"
          return 0
        fi
      done
      ;;
  esac
}

state_refuse() {
  echo "ERROR: $STATE_FILE cannot be read: $STATE_ERROR (an unresolved merge conflict?). It records which workflows were removed on purpose, so it is not overwritten. Resolve it (e.g. git checkout --ours/--theirs $STATE_FILE, or edit it), or move it aside (mv $STATE_FILE $STATE_CORRUPT): the next install then rebuilds it from the workflows on disk and installs nothing that is not already there. Nothing was changed." >&2
  exit 1
}

check_ci_paths() {
  local w d
  safe_dest .github/workflows
  for w in $KNOWN_WORKFLOWS $RETIRED_WORKFLOWS; do
    safe_dest ".github/workflows/$w.yml"
  done
  safe_dest "$VENDOR_DEST/doc-tools.sh"
  for d in doc-pr-release doc-superpowers-steps; do
    safe_dest "$VENDOR_DEST/$d/x"
  done
  safe_dest RELEASE-NOTES.next/README.md
  safe_dest "$STATE_FILE"
}

# The install plan: CI_RENDER (workflows to write, template order), the
# skipped lists, the choices; refusals before anything is written.
preflight_ci() {
  local w new="" refresh skip="" foreign="" final
  check_ci_paths
  state_load || state_refuse

  # Choices: flag > recorded > read from a pre-3.0 install's workflows > default.
  CI_BASE="${OPT_BASE:-${STATE_BASE:-$(infer_choice branch)}}"
  CI_BASE="${CI_BASE:-main}"
  CI_CRON="${OPT_CRON:-${STATE_CRON:-$(infer_choice cron)}}"
  CI_CRON="${CI_CRON:-0 9 * * 1}"
  CI_STRICT="${OPT_STRICT:-${STATE_STRICT:-$(infer_choice strict)}}"
  CI_STRICT="${CI_STRICT:-false}"
  valid_branch "$CI_BASE" || die "the recorded base branch '$CI_BASE' is not a valid branch name; pass --base-branch. Nothing was changed."
  valid_cron "$CI_CRON" || die "the recorded cron '$CI_CRON' is not 5 cron fields; pass --cron. Nothing was changed."

  CI_DISK=$(disk_workflows)
  # Every install --ci retires every retired workflow.
  plan_retired "$RETIRED_WORKFLOWS"
  case "$WF_MODE" in
    csv) new="$CSV_NAMES" ;;
    none) ;;
    all | plain)
      if [ "$WF_MODE" = all ]; then
        for w in $KNOWN_WORKFLOWS; do
          state_wf_get "$w" || true
          if [ "$WF_STATE" = uninstalled ] && [ "$WF_INTENT" = true ] && [ "$FORCE" != true ] && ! in_list "$w" "$CI_DISK"; then
            skip="${skip:+$skip }$w"
          else
            new="${new:+$new }$w"
          fi
        done
      elif [ "$STATE_HAS_CI" = 1 ]; then
        # The recorded set: installed, removed "for now" (--transient), and
        # with --force also removed on purpose.
        while IFS= read -r w; do
          [ -n "$w" ] && in_list "$w" "$KNOWN_WORKFLOWS" || continue
          state_wf_get "$w" || true
          if [ "$WF_STATE" = installed ] || { [ "$WF_STATE" = uninstalled ] && [ "$WF_INTENT" != true ]; } || [ "$FORCE" = true ]; then
            new="${new:+$new }$w"
          elif ! in_list "$w" "$CI_DISK"; then
            skip="${skip:+$skip }$w"
          fi
        done < <(state_wf_names)
      elif [ "$STATE_RECOVERY" = 1 ] || [ -n "$CI_DISK" ]; then
        : # only what is on disk (below)
      else
        new="$CI_DEFAULT_WORKFLOWS"
      fi
      ;;
  esac

  # Every managed workflow on disk is installed (whatever the state says) and
  # is refreshed with the tier's choices, as is every recorded one.
  refresh="$CI_DISK"
  if [ "$WF_MODE" != none ]; then
    while IFS= read -r w; do
      [ -n "$w" ] && in_list "$w" "$KNOWN_WORKFLOWS" || continue
      state_wf_get "$w" || true
      if [ "$WF_STATE" = installed ] && ! in_list "$w" "$refresh"; then
        refresh="$refresh $w"
      fi
    done < <(state_wf_names)
  else
    refresh=""
  fi

  CI_RENDER="" CI_FOREIGN=""
  for w in $KNOWN_WORKFLOWS; do
    in_list "$w" "$new" || in_list "$w" "$refresh" || continue
    if [ -e ".github/workflows/$w.yml" ] && ! is_managed_workflow ".github/workflows/$w.yml"; then
      foreign="${foreign:+$foreign }$w"
      continue
    fi
    CI_RENDER="${CI_RENDER:+$CI_RENDER }$w"
  done
  CI_SKIP="$skip" CI_FOREIGN="$foreign"

  # doc-pr-release.yml runs the producer helpers --helpers=false leaves out.
  final="$CI_DISK $CI_RENDER"
  if [ "$HELPERS" = false ] && in_list doc-pr-release "$final"; then
    {
      echo "ERROR: --helpers=false cannot be combined with the doc-pr-release workflow (selected, or already installed):"
      echo "  doc-pr-release.yml runs .github/scripts/doc-pr-release/{extract-context,update-pr-body,commit-and-push}.sh,"
      echo "  which --helpers=false skips, so the installed workflow would fail at runtime."
      echo "  Fix: drop --helpers=false or deselect doc-pr-release (e.g. --workflows=<list without doc-pr-release>);"
      echo "  if it is installed, remove it first (uninstall --ci --workflows=doc-pr-release)."
      echo "Nothing was installed."
    } >&2
    exit 1
  fi

  # sed-escaped once, in the main shell (the version lookup is cached here).
  R_BASE=$(sed_repl "$CI_BASE") R_CRON=$(sed_repl "$CI_CRON") R_STRICT=0 R_VERSION=""
  if [ "$CI_STRICT" = true ]; then
    R_STRICT=1
  fi
  for w in $CI_RENDER; do
    if grep -q '__VERSION__' "$SCRIPT_DIR/ci/$w.yml"; then
      ci_version
      R_VERSION=$(sed_repl "$VERSION")
      break
    fi
  done
  return 0
}

# Run a `doc-tools.sh tools …` verb (the one vendoring implementation), its
# output indented.
run_tools() {
  local out
  if ! out=$("$BASH" "$DOC_TOOLS" "$@" 2>&1); then
    printf '%s\n' "$out" >&2
    die "doc-tools.sh $1 $2 failed (above)"
  fi
  [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/  /'
}

# The helper dirs the managed workflows on disk run — a workflow that names
# .github/scripts/<dir>/ runs it: every template runs step scripts
# (doc-superpowers-steps), doc-pr-release.yml also the producer helpers.
needed_helpers() {
  local need="" d w
  for d in doc-pr-release doc-superpowers-steps; do
    for w in $KNOWN_WORKFLOWS; do
      is_managed_workflow ".github/workflows/$w.yml" || continue
      if grep -q "\.github/scripts/$d/" ".github/workflows/$w.yml"; then
        need="${need:+$need }$d"
        break
      fi
    done
  done
  printf '%s' "$need"
}

# plan_retired <names>: the retired workflows this run retires (preflight;
# nothing is written). RETIRE_NAMES are dropped from the state; of their
# files, RETIRE_OWNED carry the workflow marker (the ownership rule of every
# managed workflow) and are removed, RETIRE_KEPT do not and are kept.
plan_retired() {
  local w
  RETIRE_NAMES="$1" RETIRE_OWNED="" RETIRE_KEPT=""
  for w in $RETIRE_NAMES; do
    if is_managed_workflow ".github/workflows/$w.yml"; then
      RETIRE_OWNED="${RETIRE_OWNED:+$RETIRE_OWNED }$w"
    elif [ -e ".github/workflows/$w.yml" ]; then
      RETIRE_KEPT="${RETIRE_KEPT:+$RETIRE_KEPT }$w"
    fi
  done
}

# retire_workflows: carry out plan_retired's plan — drop the state entries,
# remove the owned files, report the kept ones.
retire_workflows() {
  local w
  for w in $RETIRE_NAMES; do
    state_wf_drop "$w"
  done
  for w in $RETIRE_OWNED; do
    remove_file ".github/workflows/$w.yml"
    echo "  Removed .github/workflows/$w.yml: the $w workflow was retired (see RELEASE-NOTES v3.0.0)."
  done
  for w in $RETIRE_KEPT; do
    echo "  Kept .github/workflows/$w.yml: named like the retired doc-superpowers $w workflow but without its marker, so not provably the installer's. Remove it yourself if it is the old one."
  done
}

# Vendored files follow the installed workflows: needed helper dirs are
# installed (doc-tools.sh always, on install), the others removed —
# `tools uninstall` keeps an edited or foreign file and says so.
vendor_sync() {
  local need d args=()
  need=$(needed_helpers)
  if [ "$1" = install ]; then
    args=(tools install --dest "$VENDOR_DEST")
    for d in $need; do
      args+=(--helper "$d")
    done
    run_tools "${args[@]}"
  fi
  for d in doc-pr-release doc-superpowers-steps; do
    if ! in_list "$d" "$need" && [ -d "$VENDOR_DEST/$d" ]; then
      run_tools tools uninstall --dest "$VENDOR_DEST" --helper "$d"
    fi
  done
}

install_ci() {
  local w installed=0 refreshed=0 dest
  for w in $CI_RENDER; do
    dest=".github/workflows/$w.yml"
    if is_managed_workflow "$dest"; then
      refreshed=$((refreshed + 1))
    else
      installed=$((installed + 1))
    fi
    tmp_beside "$dest"
    render_workflow "$SCRIPT_DIR/ci/$w.yml" > "$_TMP"
    commit_tmp "$dest" 644
    state_mark_installed "$w"
  done
  for w in $CI_FOREIGN; do
    echo "  Existing $w.yml found (not doc-superpowers-managed), skipping."
  done
  retire_workflows
  state_set_choices "$CI_BASE" "$CI_CRON" "$CI_STRICT"
  vendor_sync install
  state_flush

  local nforeign nskip
  nforeign=$(set -- $CI_FOREIGN; echo $#)
  nskip=$(set -- $CI_SKIP; echo $#)
  echo "CI/CD workflows: $installed installed, $refreshed refreshed, $nforeign skipped (existing non-managed), $nskip skipped (intentionally uninstalled)"
  echo "  Choices (recorded in $STATE_FILE): base branch $CI_BASE, cron '$CI_CRON', strict $CI_STRICT"
  for w in $CI_SKIP; do
    echo "  skipping $w.yml (previously uninstalled; pass --workflows=$w to override, or --force)"
  done
  if [ $((installed + refreshed)) -gt 0 ]; then
    echo "  Remember to commit and push these workflows (and $STATE_FILE)."
    for w in $(disk_workflows); do
      if grep -qE 'CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_API_KEY' ".github/workflows/$w.yml"; then
        echo ""
        echo "  NOTE: Claude-powered workflows require ONE of these GitHub Actions secrets:"
        echo "    - CLAUDE_CODE_OAUTH_TOKEN (preferred — Claude Code OAuth token)"
        echo "    - ANTHROPIC_API_KEY       (fallback — Anthropic API key)"
        echo "  If both are set, CLAUDE_CODE_OAUTH_TOKEN takes precedence."
        echo "  Set one at: Settings > Secrets and variables > Actions > New repository secret"
        break
      fi
    done
  fi
}

preflight_uninstall_ci() {
  local w
  check_ci_paths
  state_load || state_refuse
  CI_DISK=$(disk_workflows)
  case "$WF_MODE" in
    plain | all) CI_TARGETS="$KNOWN_WORKFLOWS" CI_FULL=1 ;;
    csv) CI_TARGETS="$CSV_NAMES" CI_FULL=0 ;;
    none) CI_TARGETS="" CI_FULL=0 ;;
  esac
  # Retired names (every one on a full uninstall, else the listed ones) are
  # retired, not marked.
  local t="" retired=""
  [ "$CI_FULL" = 0 ] || retired="$RETIRED_WORKFLOWS"
  for w in $CI_TARGETS; do
    if in_list "$w" "$RETIRED_WORKFLOWS"; then
      in_list "$w" "$retired" || retired="${retired:+$retired }$w"
    else
      t="${t:+$t }$w"
    fi
  done
  CI_TARGETS="$t"
  plan_retired "$retired"
  # Marked: a listed name always (an explicit choice); on a full uninstall,
  # what is installed (on disk or recorded) — earlier removals keep their mark.
  CI_MARK=""
  for w in $CI_TARGETS; do
    if [ "$CI_FULL" = 0 ] || in_list "$w" "$CI_DISK" || { state_wf_get "$w" && [ "$WF_STATE" = installed ]; }; then
      CI_MARK="${CI_MARK:+$CI_MARK }$w"
    fi
  done
}

uninstall_ci() {
  local w removed=0 intentional=true
  if [ "$TRANSIENT" = true ]; then
    intentional=false
  fi
  for w in $CI_MARK; do
    state_mark_uninstalled "$w" "$intentional"
  done
  # A retired file removed before the record is harmless: the next install
  # or uninstall retires whatever is left.
  retire_workflows
  for w in $RETIRE_OWNED; do
    removed=$((removed + 1))
  done
  # Recorded first: an interrupted run then cannot bring a workflow back.
  state_flush
  for w in $CI_TARGETS; do
    if is_managed_workflow ".github/workflows/$w.yml"; then
      remove_file ".github/workflows/$w.yml"
      removed=$((removed + 1))
    fi
  done
  if [ "$CI_FULL" = 1 ]; then
    run_tools tools uninstall --dest "$VENDOR_DEST"
  else
    vendor_sync uninstall
  fi
  # RELEASE-NOTES.next/README.md stays: fragments and edits may live there.
  remove_dir_if_empty .github/workflows
  remove_dir_if_empty .github
  echo "CI/CD workflows: $removed removed"
}

status_ci() {
  local w line state_ok=1 on_disk
  echo "CI/CD Workflows:"
  if ! state_load; then
    state_ok=0
    echo "  ⚠ $STATE_FILE cannot be read ($STATE_ERROR): resolve it, or move it aside to $STATE_CORRUPT"
  fi
  on_disk=$(disk_workflows)
  for w in $KNOWN_WORKFLOWS; do
    if in_list "$w" "$on_disk"; then
      printf "  ✓ %-26s installed\n" "$w.yml"
      continue
    fi
    WF_STATE=""
    if [ "$state_ok" = 1 ]; then
      state_wf_get "$w" || true
    fi
    if [ "$WF_STATE" = uninstalled ] && [ "$WF_INTENT" = true ]; then
      printf "  ✗ %-26s uninstalled (intentional)\n" "$w.yml"
    elif [ "$WF_STATE" = uninstalled ]; then
      printf "  ✗ %-26s uninstalled (transient)\n" "$w.yml"
    elif [ "$WF_STATE" = installed ]; then
      printf "  ⚠ %-26s recorded installed but missing: the next install --ci restores it\n" "$w.yml"
    else
      printf "  ✗ %-26s not installed\n" "$w.yml"
    fi
  done
  for w in $RETIRED_WORKFLOWS; do
    if is_managed_workflow ".github/workflows/$w.yml"; then
      printf "  ⚠ %-26s retired: the next install --ci (or uninstall --ci) removes it\n" "$w.yml"
    fi
  done
  if [ "$state_ok" = 1 ] && [ "$STATE_HAS_CI" = 1 ]; then
    echo "  choices: base branch ${STATE_BASE:-main}, cron '${STATE_CRON:-0 9 * * 1}', strict ${STATE_STRICT:-false} ($STATE_FILE)"
  fi
  local d n f
  for d in doc-pr-release doc-superpowers-steps; do
    [ -d "$VENDOR_DEST/$d" ] || continue
    n=0
    for f in "$VENDOR_DEST/$d"/*.sh; do
      if [ -f "$f" ]; then
        n=$((n + 1))
      fi
    done
    echo "  $d helpers: $n in $VENDOR_DEST/$d/"
  done
  if [ -f "$VENDOR_DEST/doc-tools.sh" ]; then
    echo "  doc-tools.sh: vendored at $VENDOR_DEST/doc-tools.sh"
  fi
  return 0
}

# --- Main ------------------------------------------------------------------------------

if [ $# -lt 1 ]; then
  usage >&2
  exit 1
fi
COMMAND="$1"
shift
case "$COMMAND" in
  help | --help | -h)
    usage
    exit 0
    ;;
  install | uninstall | status) ;;
  *)
    echo "Unknown command: $COMMAND" >&2
    usage >&2
    exit 1
    ;;
esac

if [[ ! -f "$DOC_TOOLS" ]]; then
  echo "ERROR: doc-tools.sh not found at $DOC_TOOLS" >&2
  echo "Is the doc-superpowers skill installed correctly?" >&2
  exit 1
fi
case "$SKILL_DIR" in
  *$'\n'*) die "the skill path holds a line break, which no hook line can carry: $SKILL_DIR" ;;
esac

DO_GIT=false DO_CLAUDE=false DO_CI=false
OPT_BASE="" OPT_CRON="" OPT_STRICT="" HELPERS=true FORCE=false TRANSIENT=false
WF_MODE=plain CSV_NAMES=""
SEEN_CI_OPTS=""

# Which command takes which flag (anything else: exit 2).
allowed() {
  case "$COMMAND:$1" in
    *:--git | *:--claude | *:--ci | *:--all) return 0 ;;
    install:--workflows | install:--base-branch | install:--cron | install:--ci-strict | install:--helpers | install:--force) return 0 ;;
    uninstall:--workflows | uninstall:--transient) return 0 ;;
  esac
  return 1
}

while [ $# -gt 0 ]; do
  arg="$1"
  shift
  name="${arg%%=*}"
  case "$arg" in
    --*=*) value="${arg#*=}" has_value=1 ;;
    *) value="" has_value=0 ;;
  esac
  case "$name" in
    --git | --claude | --ci | --all | --workflows | --base-branch | --cron | --ci-strict | --helpers | --force | --transient) ;;
    *) usage_error "unknown option: $arg" ;;
  esac
  allowed "$name" || usage_error "$name does not apply to $COMMAND"
  case "$name" in
    --base-branch | --cron | --workflows | --helpers)
      if [ "$has_value" = 0 ]; then
        [ $# -gt 0 ] || die "$name requires a value"
        value="$1"
        shift
      fi
      ;;
    --ci-strict) ;;
    *) [ "$has_value" = 0 ] || usage_error "$name takes no value" ;;
  esac
  case "$name" in
    --git) DO_GIT=true ;;
    --claude) DO_CLAUDE=true ;;
    --ci) DO_CI=true ;;
    --all) DO_GIT=true DO_CLAUDE=true DO_CI=true ;;
    --base-branch)
      valid_branch "$value" || die "invalid --base-branch '$value': a branch name of letters, digits and . _ / - that git accepts"
      OPT_BASE="$value"
      ;;
    --cron)
      valid_cron "$value" || die "invalid --cron '$value': 5 fields of digits, names and * , - /"
      OPT_CRON="$value"
      ;;
    --ci-strict)
      case "$has_value:$value" in
        0:* | 1:true) OPT_STRICT=true ;;
        1:false) OPT_STRICT=false ;;
        *) die "--ci-strict takes true or false (got: $value)" ;;
      esac
      ;;
    --helpers)
      case "$value" in
        true | false) HELPERS="$value" ;;
        *) die "--helpers must be 'true' or 'false' (got: $value)" ;;
      esac
      ;;
    --workflows)
      case "$value" in
        all) WF_MODE=all ;;
        none) WF_MODE=none ;;
        *) WF_MODE=csv; parse_workflow_csv "$value" ;;
      esac
      ;;
    --force) FORCE=true ;;
    --transient) TRANSIENT=true ;;
  esac
  case "$name" in
    --workflows | --base-branch | --cron | --ci-strict | --helpers | --force | --transient)
      SEEN_CI_OPTS="${SEEN_CI_OPTS:+$SEEN_CI_OPTS }$name"
      ;;
  esac
done
if [ -n "$SEEN_CI_OPTS" ] && [ "$DO_CI" != true ] && [ "$COMMAND" != status ]; then
  usage_error "${SEEN_CI_OPTS%% *} applies to the CI tier: add --ci (or --all)"
fi

enter_repo

case "$COMMAND" in
  install)
    if ! $DO_GIT && ! $DO_CLAUDE && ! $DO_CI; then
      if [[ -t 0 ]]; then
        echo "doc-superpowers hooks installer"
        echo ""
        echo "Which tiers would you like to install?"
        echo "  [1] Git hooks: pre-commit, post-merge, post-checkout, prepare-commit-msg, pre-push (+ the index merge driver)"
        echo "  [2] Claude Code hooks (per-user): pre-commit-gate, post-commit-sync, session-summary"
        echo "  [3] CI/CD workflows: $SHELL_WORKFLOWS"
        echo "      (Claude-powered ones are opt-in: install.sh install --ci --workflows=<names>; install.sh help lists them)"
        echo "  [a] All of the above"
        echo ""
        read -rp "Select (comma-separated, e.g. 1,2): " selection
        [[ "$selection" == *1* ]] && DO_GIT=true
        [[ "$selection" == *2* ]] && DO_CLAUDE=true
        [[ "$selection" == *3* ]] && DO_CI=true
        [[ "$selection" == *a* ]] && DO_GIT=true && DO_CLAUDE=true && DO_CI=true
      else
        usage >&2
        exit 1
      fi
    fi
    # Every check first: a refusal writes nothing.
    $DO_GIT && preflight_git
    $DO_CLAUDE && preflight_claude
    $DO_CI && preflight_ci
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
          DO_GIT=true DO_CLAUDE=true DO_CI=true
        else
          echo "Cancelled."
          exit 0
        fi
      else
        echo "ERROR: specify tier flags (--git, --claude, --ci, --all)" >&2
        exit 1
      fi
    fi
    $DO_GIT && preflight_git
    $DO_CLAUDE && preflight_uninstall_claude
    $DO_CI && preflight_uninstall_ci
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
    if ! $DO_GIT && ! $DO_CLAUDE && ! $DO_CI; then
      DO_GIT=true DO_CLAUDE=true DO_CI=true
    fi
    echo ""
    echo "doc-superpowers hooks status"
    echo ""
    if $DO_GIT; then
      status_git
      echo ""
    fi
    if $DO_CLAUDE; then
      status_claude
      echo ""
    fi
    if $DO_CI; then
      status_ci
      echo ""
    fi
    echo "Env overrides: DOC_SUPERPOWERS_STRICT=${DOC_SUPERPOWERS_STRICT:-unset} DOC_SUPERPOWERS_SKIP=${DOC_SUPERPOWERS_SKIP:-unset}"
    ;;
esac
