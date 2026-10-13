# shellcheck shell=bash
# scripts/ledger/views.sh — `ledger view` and `ledger publish` (design §E.2,
# §E.3): the renderers render-md.jq / render-html.jq (pure jq programs over
# the index, sharing defs.jq's model) fed by this file's $generated object.
# Sourced by lib.sh; uses lib.sh's _lg_init, _lg_usage, _lg_die, _lg_emit,
# _lg_out_file, _lg_cfg, index.sh's _lg_index, glob.sh's _lg_glob_dirs,
# parse.sh's _lg_scratch_name.
#
# ledger view <L|all> [--md] [--html] [--out DIR] [--open] [--refresh]
#   Renders the working tree (its index: uncommitted items included) into
#   DIR (default $_LG_CACHE/views): <L>.md, or every ledger's page and
#   README.md for "all" (--md, the default), and/or ledger.html (--html:
#   every ledger, the ledger filter on <L>). Links point at the files in
#   this work tree (absolute paths). --open hands the HTML (else the page,
#   README.md for all) to the platform opener (open; xdg-open). One line
#   per file written; --format json: {"dir", "files"}.
#
# ledger publish [--dry-run]
#   git fetch <remote> (the remote <base> names, else keys.remote); the base
#   commit is refs/remotes/<remote>/<branch> — never a local branch — and
#   the views branch's tip comes from `git ls-remote`. Everything is read
#   from the base commit's blobs: its docs/ledger/config.json (the run's
#   config from then on: globs, views settings), registry, legacy map,
#   doc-index and items (`_lg_index --rev`, cached apart from the working
#   tree's indexes) — no checkout, nothing of the working tree. The pages,
#   README.md and (views.html) ledger.html are rendered, then one commit on
#   views.branch is written with git plumbing only — a private
#   GIT_INDEX_FILE, hash-object -w, update-index --add --cacheinfo,
#   write-tree, commit-tree [-p <tip>] — and pushed as
#   <commit>:refs/heads/<views.branch> without force and with --no-verify
#   (a host's pre-push gate is for its code, not for views). A rejected
#   push is exit 2 ("the branch moved" when git reports a non-fast-forward
#   or "[rejected]"; a remote hook's "[remote rejected]" is "failed"). The user's HEAD,
#   index and working tree are never touched. Message: "views @
#   <base>@<short-sha>, <n> in-flight branches, <UTC>". --dry-run renders
#   into $_LG_CACHE/publish-dry-run and stops before the commit. Links:
#   https://github.com/<owner>/<repo>/blob/<branch>/<path> for a GitHub
#   remote, else relative to the views branch (../<branch>/<path>, one ../
#   per segment of views.branch: the hosted blob view resolves them).
#
# $generated (render-md.jq): the header's source ("the working tree at
# <short HEAD>" / "<base>@<short-sha>"), the in-flight branch count (0
# until the in-flight scan exists), the UTC time, the PR data note (view:
# "PR data as of <UTC> (<age> old)" when the PR adapter failed and its
# last copy serves, "PR data: — (unavailable)" when there is none;
# publish fetches the PR list and fails, exit 2, without it), the recency cutoff
# (today − views.recent_days), the last-touched date of every item path a
# commit since the cutoff touched (git log over the item and archive glob
# directories; for view, also today for each modified or untracked item
# file), and the link prefix.

# _lg_v_generated <commit> <dirty 0|1> <source> <link> <out> [pr-note]:
# write the $generated object (see the header) to <out>; [pr-note] the PR
# data's state for the header ("PR data as of …", "PR data: —"; index.sh
# writes it to $_SCRATCH/lg-pr.mark), "" when fresh or not configured.
_lg_v_generated() {
  local commit="$1" dirty="$2" source="$3" link="$4" out="$5" prnote="${6:-}" s days at cutoff today d e xy p since
  local specs=()
  _lg_scratch_name
  s=$_LG_SN
  days=$(_lg_cfg '.views.recent_days | if type == "number" and . >= 0 then floor else 14 end')
  at=$(date -u +%Y-%m-%dT%H:%M:%SZ) || _lg_die "date failed"
  today=${at%%T*}
  cutoff=$(jq -nr --argjson d "$days" 'now - ($d * 86400) | strftime("%Y-%m-%d")') || _lg_die "jq failed (the recency cutoff)"
  _lg_cfg '[(.items.globs // [])[]?, (.items.archive_globs // [])[]?] | .[] | strings | select(. != "")' > "$s.globs"
  _lg_glob_dirs "$s.globs" "$s.dirs"
  while IFS= read -r d; do
    specs+=("$d")
  done < "$s.dirs"
  : > "$s.touch"
  if [ -n "$commit" ]; then
    # git log -z --name-only: "<date>\0\n<path>\0<path>\0<date>\0\n…"; after
    # tr, one token per line, a commit's first path led by \001.
    # UTC days, like the cutoff (a bare --since date means that day at the
    # current time of day: spell midnight out). --since-as-filter (git
    # 2.37+) filters by date without ending the walk at the first older
    # commit, as --since does — a commit dated before its parent (clock
    # skew, a hand-set date) would hide everything behind it; older git
    # falls back to --since.
    for since in --since-as-filter --since; do
      if TZ=UTC GIT_LITERAL_PATHSPECS=1 git -c log.showSignature=false log --no-color \
          --date=format-local:%Y-%m-%d --format=%cd --name-only -z "$since=$cutoff 00:00:00 +0000" \
          "$commit" -- ${specs[@]+"${specs[@]}"} > "$s.log" 2> "$s.err"; then
        break
      fi
      [ "$since" = --since ] && _lg_die "git log failed: $(head -n 3 "$s.err" 2>/dev/null)"
    done
    tr '\n\000' '\001\n' < "$s.log" | LC_ALL=C awk '
      {
        t = $0
        if (substr(t, 1, 1) == "\001") { print d "\t" substr(t, 2); next }
        if (t ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) { d = t; next }
        if (t != "" && d != "") print d "\t" t
      }' > "$s.touch" || _lg_die "cannot read the git history of the items"
  fi
  if [ "$dirty" = 1 ]; then
    git status --porcelain=v1 -z --untracked-files=all -- ${specs[@]+"${specs[@]}"} > "$s.st" 2> "$s.err" \
      || _lg_die "git status failed: $(head -n 3 "$s.err" 2>/dev/null)"
    while IFS= read -r -d '' e; do
      xy=${e:0:2}
      p=${e:3}
      case "$xy" in
        R*|C*) IFS= read -r -d '' _ || true ;;
      esac
      case "$xy" in
        *D*) continue ;;
      esac
      printf '%s\t%s\n' "$today" "${p//$'\n'/$'\001'}"
    done < "$s.st" >> "$s.touch"
  fi
  jq -n -R -c --arg source "$source" --arg at "$at" --arg cutoff "$cutoff" --arg link "$link" --arg pr "$prnote" '
    {source: $source, inflight: 0, at: $at, cutoff: $cutoff, link: $link, pr_note: $pr,
     touched: (reduce (inputs | select(length > 11)) as $l ({};
       ($l[11:] | gsub("\u0001"; "\n")) as $p | $l[0:10] as $d
       | if (.[$p] // "") < $d then .[$p] = $d else . end))}' "$s.touch" > "$out" \
    || _lg_die "jq failed (\$generated)"
}

# _lg_v_ledger_ids <index>: the ledgers the views show (defs.jq
# lg_v_ledgers), one id per line.
_lg_v_ledger_ids() {
  jq -L "$_LG_LIB" -r "$_LG_JQ_INCLUDE"'lg_v_ledgers(.)[] | .id' "$1" || _lg_die "jq failed (the ledgers)"
}

# _lg_v_render <index> <generated> <target L|all> <md 0|1> <html 0|1> <dir>:
# render into <dir> (which exists); the names written, one per line,
# sorted, into <dir>/.names.
_lg_v_render() {
  local ix="$1" gen="$2" target="$3" md="$4" html="$5" dir="$6" s
  _lg_scratch_name
  s=$_LG_SN
  : > "$dir/.names"
  if [ "$md" = 1 ]; then
    jq -j -L "$_LG_LIB" --slurpfile c "$_LG_CFG" --arg ledger "$target" --arg mode files \
      --slurpfile generated "$gen" -f "$_LG_LIB/render-md.jq" "$ix" > "$s.md" \
      || _lg_die "jq failed (scripts/ledger/render-md.jq)"
    # "<name>\001<content>\001…": the names are <id>.md (ids are
    # [a-z0-9-]) and README.md.
    LC_ALL=C awk -v dir="$dir" 'BEGIN { RS = "\001" }
      NR % 2 == 1 { name = $0; next }
      { f = dir "/" name; printf "%s", $0 > f; close(f); print name }' "$s.md" >> "$dir/.names" \
      || _lg_die "cannot write the pages into $dir"
  fi
  if [ "$html" = 1 ]; then
    jq -r -L "$_LG_LIB" --slurpfile c "$_LG_CFG" --arg ledger "$target" \
      --slurpfile generated "$gen" -f "$_LG_LIB/render-html.jq" "$ix" > "$dir/ledger.html" \
      || _lg_die "jq failed (scripts/ledger/render-html.jq)"
    printf 'ledger.html\n' >> "$dir/.names"
  fi
  LC_ALL=C sort -o "$dir/.names" "$dir/.names" || _lg_die "cannot sort $dir/.names"
}

# _lg_v_payload <names-file> <out> <dir|""> [jq args… <object-filter>]: the
# --format json payload {"dir" (when given), "files"} + the filter's
# object (built from the jq args).
_lg_v_payload() {
  local names="$1" out="$2" dir="$3"
  shift 3
  local x='{}'
  if [ $# -gt 0 ]; then
    x=$(jq -nc "$@") || _lg_die "jq failed (the payload)"
  fi
  jq -R -n -c --arg dir "$dir" --argjson x "$x" \
    '(if $dir == "" then {} else {dir: $dir} end) + {files: [inputs]} + $x' "$names" > "$out" \
    || _lg_die "jq failed (the payload)"
}

# --- view ------------------------------------------------------------------------

# shellcheck disable=SC2154  # _OPT_* and _ARGS are set by _parse_args
cmd_ledger_view() {
  local target out ix s gen stage n md=1 html=0 link head ids opener="" open_file
  _lg_init view
  [ "${#_ARGS[@]}" -ge 1 ] || _lg_usage "give a ledger id, or all"
  [ "${#_ARGS[@]}" = 1 ] || _lg_usage "give one ledger id, or all (got ${#_ARGS[@]} arguments)"
  target=${_ARGS[0]}
  if [ -n "$_OPT_html" ]; then html=1; md=0; fi
  if [ -n "$_OPT_md" ]; then md=1; fi
  if [ -n "$_OPT_refresh" ]; then _LG_REMOTE_FORCE=1; fi
  out=${_OPT_out:-$_LG_CACHE/views}
  case "$out" in
    /*) ;;
    *) out="$PWD/$out" ;;
  esac
  _lg_scratch_name
  s=$_LG_SN
  _LG_IX_NEED_CONTRACTS=1
  ix=$(_lg_index)
  _lg_v_ledger_ids "$ix" > "$s.ids"
  if [ "$target" != all ] && ! grep -Fqx -- "$target" "$s.ids"; then
    ids=$(tr '\n' ',' < "$s.ids" | sed 's/,$//; s/,/, /g')
    _lg_usage "'$target' is not a ledger the views show (${ids:-none})"
  fi
  head=$(git rev-parse -q --verify --short 'HEAD^{commit}' 2>/dev/null) || head=""
  link=$(jq -nr --arg r "$_LG_ROOT" '$r | split("/") | map(@uri) | join("/") + "/"') || _lg_die "jq failed (the link prefix)"
  gen="$s.gen"
  _lg_v_generated "$(git rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null || true)" 1 \
    "the working tree at ${head:-(no commit)}" "$link" "$gen" "$(cat "$_SCRATCH/lg-pr.mark" 2>/dev/null || true)"
  stage=$(mktemp -d "$_SCRATCH/lg-view.XXXXXX") || _lg_die "mktemp failed"
  _lg_v_render "$ix" "$gen" "$target" "$md" "$html" "$stage"
  mkdir -p -- "$out" 2>/dev/null || _lg_die "cannot create $out"
  : > "$s.lines"
  while IFS= read -r n; do
    if ! cp -- "$stage/$n" "$out/.$n.$$" 2>/dev/null || ! mv -f -- "$out/.$n.$$" "$out/$n"; then
      rm -f -- "$out/.$n.$$"
      _lg_die "cannot write $out/$n"
    fi
    printf '%s\n' "$out/$n" >> "$s.lines"
  done < "$stage/.names"
  if [ -n "$_OPT_open" ]; then
    if [ "$html" = 1 ]; then open_file="$out/ledger.html"
    elif [ "$target" = all ]; then open_file="$out/README.md"
    else open_file="$out/$target.md"; fi
    case "$(uname -s 2>/dev/null)" in
      Darwin) opener=open ;;
      *) opener=xdg-open ;;
    esac
    if ! command -v "$opener" >/dev/null 2>&1; then
      echo "ledger view: no '$opener' to open $open_file" >&2
    elif ! "$opener" "$open_file" </dev/null >/dev/null 2>&1; then
      echo "ledger view: '$opener $open_file' failed" >&2
    fi
  fi
  if [ "$_LG_FORMAT" = json ]; then
    _lg_v_payload "$stage/.names" "$s.json" "$out"
    _lg_emit view 0 "$s.json"
  fi
  _lg_out_file "$s.lines"
  _lg_emit view 0
}

# --- publish ---------------------------------------------------------------------

# _lg_publish_link <remote> <branch> <views-branch>: the link prefix.
_lg_publish_link() {
  local url="" path n segs
  url=$(git remote get-url "$1" 2>/dev/null) || url=""
  path=""
  case "$url" in
    git@github.com:*) path=${url#git@github.com:} ;;
    ssh://git@github.com/*) path=${url#ssh://git@github.com/} ;;
    https://github.com/*) path=${url#https://github.com/} ;;
    http://github.com/*) path=${url#http://github.com/} ;;
  esac
  path=${path%/}
  path=${path%.git}
  if [ -n "$path" ]; then
    jq -nr --arg p "$path" --arg b "$2" '"https://github.com/\($p | split("/") | map(@uri) | join("/"))/blob/\($b | split("/") | map(@uri) | join("/"))/"'
    return
  fi
  # ../ per segment of the views branch: <host>/blob/<views>/<page> → <host>/blob/<branch>/<path>.
  segs=$(printf '%s' "$3" | tr -cd '/' | wc -c | tr -d ' ')
  n=0
  path=""
  while [ "$n" -le "$segs" ]; do path="../$path"; n=$((n + 1)); done
  jq -nr --arg up "$path" --arg b "$2" '$up + ($b | split("/") | map(@uri) | join("/")) + "/"'
}

# _lg_publish_selftest_race <remote> <ref>: TEST-ONLY (scripts/test-ledger.sh
# sets DOC_TOOLS_LEDGER_SELFTEST=publish-race; nothing else reaches it):
# another publisher pushes an unrelated commit to the views branch first.
# The --force below is the simulated rival's, never publish's own push.
_lg_publish_selftest_race() {
  local t c
  t=$(git hash-object -t tree -w --stdin < /dev/null) || return 1
  c=$(git commit-tree "$t" -m "selftest race") || return 1
  git push -q --no-verify --force "$1" "$c:$2" >/dev/null 2>&1
}

# shellcheck disable=SC2154  # _OPT_* and _ARGS are set by _parse_args
cmd_ledger_publish() {
  local s base_ref remote="" branch="" r vb tip="" base short at link n gen ix stage
  local msg tree commit gi oid out err dry=0 html prev_short base_name
  _lg_init publish
  [ "${#_ARGS[@]}" = 0 ] || _lg_usage "unexpected argument '${_ARGS[0]}'"
  if [ -n "$_OPT_dry_run" ]; then dry=1; fi
  _lg_scratch_name
  s=$_LG_SN

  # The remote, the base branch, the views branch (this work tree's config).
  _lg_cfg '(.base | if type == "string" then . else "" end), (.keys.remote | if type == "string" then . else "" end), (.views.branch | if type == "string" then . else "" end)' > "$s.cfgv"
  { IFS= read -r base_ref; IFS= read -r r; IFS= read -r vb; } < "$s.cfgv" || true
  case "$base_ref" in
    ''|-*) _lg_die "config base is not a revision: '$base_ref'" ;;
  esac
  git remote > "$s.remotes" 2>/dev/null || _lg_die "git remote failed"
  while IFS= read -r n; do
    case "$base_ref" in
      "$n"/?*)
        if [ "${#n}" -gt "${#remote}" ]; then remote=$n; branch=${base_ref#"$n"/}; fi ;;
    esac
  done < "$s.remotes"
  if [ -z "$remote" ]; then
    # A base without a remote prefix ("main") names the remote's branch.
    remote=${r:-origin}
    branch=$base_ref
  fi
  grep -Fqx -- "$remote" "$s.remotes" || _lg_die "no remote '$remote' to publish to (config base / keys.remote)"
  if [ -z "$vb" ] || ! git check-ref-format "refs/heads/$vb"; then
    _lg_die "config views.branch is not a branch name: '$vb'"
  fi
  base_name="$remote/$branch"

  # Fetch the base; read the views branch's tip from the remote itself.
  LC_ALL=C git fetch -q --no-recurse-submodules "$remote" > "$s.err" 2>&1 || _lg_die "git fetch $remote failed: $(head -n 3 "$s.err")"
  git ls-remote --heads "$remote" "refs/heads/$vb" > "$s.ls" 2> "$s.err" \
    || _lg_die "git ls-remote $remote failed: $(head -n 3 "$s.err")"
  tip=$(awk -v r="refs/heads/$vb" '$2 == r { print $1; exit }' "$s.ls")
  if [ -n "$tip" ] && ! git cat-file -e "$tip^{commit}" 2>/dev/null; then
    LC_ALL=C git fetch -q --no-recurse-submodules "$remote" "refs/heads/$vb" > "$s.err" 2>&1 \
      || _lg_die "cannot fetch $remote $vb: $(head -n 3 "$s.err")"
    git cat-file -e "$tip^{commit}" 2>/dev/null || _lg_die "the tip of $remote $vb ($tip) did not arrive"
  fi
  base=$(git rev-parse -q --verify "refs/remotes/$remote/$branch^{commit}" 2>/dev/null) \
    || _lg_die "the base $base_name (refs/remotes/$remote/$branch) does not resolve after fetching $remote"
  short=$(git rev-parse --short "$base") || _lg_die "git rev-parse failed"
  link=$(_lg_publish_link "$remote" "$branch" "$vb") || _lg_die "jq failed (the link prefix)"

  # The base commit's own config, then its index — blobs only.
  git cat-file -e "$base:docs/ledger/config.json" 2>/dev/null \
    || _lg_die "the base $base_name ($short) has no docs/ledger/config.json — nothing to publish"
  _lg_cfg_from_rev "$base"
  _LG_IX_NEED_CONTRACTS=1
  # The PR list is fetched now (no stale copy is published).
  _LG_REMOTE_FORCE=1
  ix=$(_lg_index --rev "$base")
  gen="$s.gen"
  _lg_v_generated "$base" 0 "$base_name@$short" "$link" "$gen" ""
  at=$(jq -r '.at' "$gen") || _lg_die "jq failed"
  html=$(_lg_cfg 'if .views.html == false then 0 else 1 end')
  stage="$_SCRATCH/lg-publish"
  mkdir -p -- "$stage" || _lg_die "mkdir failed"
  _lg_v_render "$ix" "$gen" all 1 "$html" "$stage"

  msg="views @ $base_name@$short, 0 in-flight branches, $at"
  if [ "$dry" = 1 ]; then
    out="$_LG_CACHE/publish-dry-run"
    rm -rf -- "$out"
    mkdir -p -- "$out" || _lg_die "cannot create $out"
    while IFS= read -r n; do
      cp -- "$stage/$n" "$out/$n" || _lg_die "cannot write $out/$n"
    done < "$stage/.names"
    if [ "$_LG_FORMAT" = json ]; then
      # shellcheck disable=SC2016  # jq source
      _lg_v_payload "$stage/.names" "$s.json" "$out" --arg remote "$remote" --arg branch "$vb" --arg base "$base" \
        --arg msg "$msg" --arg tip "$tip" '{remote: $remote, branch: $branch, base_commit: $base, message: $msg,
          commit: null, parent: (if $tip == "" then null else $tip end), dry_run: true}'
      _lg_emit publish 0 "$s.json"
    fi
    {
      printf 'dry run: would publish %s files to %s %s (%s)\n' "$(wc -l < "$stage/.names" | tr -d ' ')" "$remote" "$vb" \
        "$(if [ -n "$tip" ]; then printf 'fast-forward from %s' "$(git rev-parse --short "$tip")"; else printf 'a new branch'; fi)"
      printf 'message: %s\n' "$msg"
      printf 'files: %s\n' "$out"
    } > "$s.lines"
    _lg_out_file "$s.lines"
    _lg_emit publish 0
  fi

  # The commit, with plumbing only: a private index, never the user's.
  gi="$_SCRATCH/lg-publish.index"
  rm -f -- "$gi"
  while IFS= read -r n; do
    oid=$(git hash-object -w --no-filters -- "$stage/$n") || _lg_die "git hash-object failed ($n)"
    GIT_INDEX_FILE=$gi git update-index --add --cacheinfo "100644,$oid,$n" || _lg_die "git update-index failed ($n)"
  done < "$stage/.names"
  tree=$(GIT_INDEX_FILE=$gi git write-tree) || _lg_die "git write-tree failed"
  if ! git var GIT_COMMITTER_IDENT >/dev/null 2>&1 || ! git var GIT_AUTHOR_IDENT >/dev/null 2>&1; then
    export GIT_AUTHOR_NAME="doc-superpowers ledger" GIT_AUTHOR_EMAIL="ledger@doc-superpowers.invalid"
    export GIT_COMMITTER_NAME="doc-superpowers ledger" GIT_COMMITTER_EMAIL="ledger@doc-superpowers.invalid"
  fi
  if [ -n "$tip" ]; then
    commit=$(git commit-tree "$tree" -p "$tip" -m "$msg") || _lg_die "git commit-tree failed"
  else
    commit=$(git commit-tree "$tree" -m "$msg") || _lg_die "git commit-tree failed"
  fi
  case "${DOC_TOOLS_LEDGER_SELFTEST:-}" in
    # TEST-ONLY: a rival publisher wins the race (see _lg_publish_selftest_race).
    publish-race) _lg_publish_selftest_race "$remote" "refs/heads/$vb" || _lg_die "selftest: the race push failed" ;;
  esac
  if ! LC_ALL=C git push -q --no-verify "$remote" "$commit:refs/heads/$vb" > "$s.err" 2>&1; then
    err=$(head -n 3 "$s.err" | tr '\n' ' ')
    # Only a lost race ("! [rejected] … (non-fast-forward | fetch first)"),
    # never "! [remote rejected] … (pre-receive hook declined)" or another
    # refusal: those are failures, reported with git's words.
    if grep -Eq 'non-fast-forward|fetch first|\[rejected\]' "$s.err"; then
      _lg_die "the push to $remote $vb was rejected: the branch moved since it was read — run publish again ($err)"
    fi
    _lg_die "the push to $remote $vb failed: $err"
  fi
  if [ "$_LG_FORMAT" = json ]; then
    # shellcheck disable=SC2016  # jq source
    _lg_v_payload "$stage/.names" "$s.json" "" --arg remote "$remote" --arg branch "$vb" --arg base "$base" \
      --arg msg "$msg" --arg tip "$tip" --arg c "$commit" '{remote: $remote, branch: $branch, base_commit: $base,
        message: $msg, commit: $c, parent: (if $tip == "" then null else $tip end), dry_run: false}'
    _lg_emit publish 0 "$s.json"
  fi
  prev_short="a new branch"
  if [ -n "$tip" ]; then prev_short="fast-forward from $(git rev-parse --short "$tip")"; fi
  printf 'published %s files to %s %s @ %s (%s)\n' "$(wc -l < "$stage/.names" | tr -d ' ')" "$remote" "$vb" \
    "$(git rev-parse --short "$commit")" "$prev_short" > "$s.lines"
  printf 'message: %s\n' "$msg" >> "$s.lines"
  _lg_out_file "$s.lines"
  _lg_emit publish 0
}
