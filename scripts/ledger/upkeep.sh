# shellcheck shell=bash
# scripts/ledger/upkeep.sh — merge-time upkeep (#39; design 2026-10-18 §4):
# `ledger upkeep`, the declarations a range's diff says its items are
# missing — proposed, never written. Sourced by lib.sh; uses lib.sh's
# _lg_init, _lg_usage, _lg_die, _lg_emit, _lg_out_file, _lg_cfg, index.sh's
# _lg_index and _LG_JQ_INCLUDE, keys.sh's _LG_JQ_RESOLVE_DEFS (lg_resolve),
# relations.sh's _lg_msg_claims, _lg_trailers, _LG_AWK_TRAILER and
# _lg_r_file_contracts, glob.sh's _lg_paths_filter, query.sh's
# _lg_pr_data_into, parse.sh's _lg_scratch_name; defs.jq's lg_r_maps;
# adapters.sh's _lg_adapter / _lg_adapter_path, index.sh's _lg_ix_pr_fetch.
#
# ledger upkeep (--range <a>..<b> | --range <a>...<b> | --pr <n>)
#   [--items <item>…] [--top N] [--strict] [--no-repo-adapters]
#   [--format text|json]
#
# Range: <a>..<b> as given; <a>...<b> is merge-base(a, b)..b — trunk merged
#   into the branch never counts. An end that does not resolve to a commit
#   here: exit 2. The net diff is `git diff <a> <b>` (no renames: a moved
#   file is its old path and its new one); the commits, `git log <a>..<b>`.
#   --pr <n> (config adapters.pr, else exit 2): PR <n> from the adapter's
#   list, read through the remote cache as every verb reads it (the index
#   build then reads the same copy). Merged, its merge_commit here:
#   merge-base(<merge_commit>^1, head_oid)..head_oid when head_oid is here
#   too, else <merge_commit>^1..<merge_commit> (for a rebase merge, its
#   last commit only); open, its head_oid here: merge-base(config base,
#   head_oid)..head_oid. Closed, not in the list, its commit or the base
#   not here: exit 2 (with the fetch command). The PR body: the adapter's
#   optional `view <n>` ({"number", "body"}; never cached) — its
#   exit 3, or DOC_TOOLS_LEDGER_OFFLINE=1, is no body (pr.body_scanned
#   false); any other failure, exit 2.
# --no-repo-adapters (review contexts that must not run repository
#   scripts): exit 2, before any adapter runs, when config
#   adapters.contracts, adapters.pr or items.adapter is anything but null
#   ("" or absent alike) or doc-superpowers:<name>.
# Involved items, each with found_by (in this rank order; archived items
#   never):
#   1 trailer:claims / trailer:claims_by_path / trailer:claims_by_ref —
#     _lg_msg_claims "<a>..<b>" (trailers.since honoured): a claims value
#     split on commas and blanks, each a key or an alias (any case; a
#     provisional key finalized.json maps on counts), a claims_by_path value
#     an item path ("./" dropped), a claims_by_ref "#N" the one hosted item
#     whose ref ends in #N;
#   2 item-file-edited — a net-diff file that is an item;
#   3 key-in-message — a key or alias as a word (sweep's word scan: split
#     on [^A-Za-z0-9_-], any case) in a commit message of the range, its
#     claims and claims_by_path trailer lines left out (they are signal 1);
#   4 key-in-pr-body — the same in the PR body (--pr; _lg_up_core's
#     <body-file>).
#   --items <item>… names them instead (found_by ["named"], rank 0): each
#   must resolve, as show resolves, to one item that is not archived (else
#   exit 3), and only they are involved.
# Touched contracts: an index contract whose defined_in matches a net-diff
#   file upkeep.skip_globs does not match, or that a "Contract-Change: <id>
#   [— <line>]" trailer in the range names. Read contracts: an untouched one
#   whose read_by matches such a file.
# Proposals (changes): a touched contract an involved item declares in
#   changes is covered — proposed to nobody. Every other one, except
#   upkeep.skip_contracts, goes to exactly one involved item: the most
#   paths entries its defined_in matches; then the most paths entries that
#   are net-diff files; then the best rank; then key (else path) order. With
#   no involved item it is unattributed. Evidence: "diff touches <f>
#   (defined_in of <c>)" per file (3 at most, then "… and N more files"),
#   then "Contract-Change: <c> — <line>" per trailer line.
# Proposals (consumes): (a) a read contract, the same way — covered by an
#   involved item's consumes, else attributed (read_by in place of
#   defined_in) or unattributed; evidence "diff touches <f> (read_by of
#   <c>)". (b) for an item of rank 2 or better (never one found by words
#   alone): each untouched contract whose defined_in matches a paths entry
#   the net diff does not hold — "the item lists <f> (defined_in of <c>),
#   which the range does not change" — unless the item declares it in
#   consumes or has it from (a). Never a skip_contracts id.
# Per item: changes ranked Contract-Change first, then by evidence count
#   (files and lines), then id; then consumes (a), then (b), each by
#   evidence count, then id; --top N (default 3; 0: all) keeps the first N
#   (total, truncated). declared_untouched: the declared changes the range
#   does not touch (informational). link: "ledger link <key|path> --changes
#   a,b --consumes c" for the shown proposals (a word quoted for the shell
#   when it needs it), null without — printed, never run. upkeep writes
#   nothing.
# Output: JSON {range: "<a-oid>..<b-oid>", pr: null (--range) | {number,
#   state, body_scanned} (--pr), files, commits, items:
#   [{key, path, found_by, proposed: [{field, value, evidence}], total,
#   truncated, declared_untouched, link}], unattributed_contracts:
#   [{contract, files}]} (+ pr_data / items_data). Text: "range <a12>..<b12>
#   <n> files, <m> commits"; per item "<key|path>  found by <signals>",
#   "  + <field> <value>  — <evidence; …>", "  (showing N of M; --top 0
#   shows all)", "  declared, untouched: a, b", "  link: ledger link …";
#   then "unattributed: <c> (<files>)"; "(no proposals)" when no item has
#   one. Exit 0 (proposals are advisory); 1 with --strict and a proposal; 2
#   a range that does not resolve, a failing contracts adapter, a bad
#   upkeep config, --pr without adapters.pr, its list failing (no copy) or
#   view failing, a PR not usable, a --no-repo-adapters refusal; 3 usage.
#   Cost: one index build, one git diff-tree, two git log walks
#   (_lg_msg_claims' and the word scan's); with --pr, the list (cached)
#   and one view.

_LG_UP_TOP=3   # proposals kept per item (0: all) — the verb's --top
_LG_UP_IX=""   # _lg_up_index: the index upkeep reads …
_LG_UP_IXB=""  # … and the commit it was chosen for
_LG_UP_PR=null # the payload's pr: null, or {number, state, body_scanned}
_LG_UP_BODY="" # the PR body's file (_lg_up_pr); "" when none was read
_LG_UP_FH=""   # _lg_up_pr_fetch_hint's command

# _lg_up_no_repo: --no-repo-adapters — exit 2, before anything runs, when
# config adapters.contracts, adapters.pr or items.adapter names anything
# but null ("" or absent alike: none) or doc-superpowers:<name> (an adapter
# shipped beside doc-tools.sh): a repository's own script, which a review
# context must not run. The message names each, with its value.
_lg_up_no_repo() {
  local m
  # shellcheck disable=SC2016  # jq source
  m=$(_lg_cfg 'def at($o; $k): if ($o | type) == "object" then $o[$k] else null end;
    [["adapters.contracts", at(.adapters; "contracts")], ["adapters.pr", at(.adapters; "pr")],
     ["items.adapter", at(.items; "adapter")]]
    | map(select(.[1] != null and .[1] != ""
                 and ((.[1] | type) != "string" or (.[1] | test("\\Adoc-superpowers:[a-z0-9_-]+\\z") | not)))
          | "\(.[0]) (\(.[1] | tojson | .[0:200]))")
    | join(", ")') || exit "$?"
  [ -n "$m" ] || return 0
  _lg_die "--no-repo-adapters: a repository script is configured (not null or doc-superpowers:<name>): $m — nothing was run (run ledger upkeep without --no-repo-adapters yourself)"
}

# _lg_up_pr_fetch_hint <n> <url> → _LG_UP_FH: the command that fetches
# open PR <n>'s head into this clone (after _lg_ix_pr_fetch: the remote is
# _LG_IX_PR_REMOTE) — git fetch <remote> <ref>: the ref config
# inflight.pull_refs names, the number in place of its one * (the host's
# PR-head refs, which the in-flight scan fetches), else pull/<n>/head when
# the PR's url is a pull URL (…/pull/<n>, …/pulls/<n>: GitHub's, Gitea's
# — hosts that publish refs/pull/<n>/head); else git fetch <remote> alone
# (host-neutral: the adapter gives no ref to name).
_lg_up_pr_fetch_hint() {
  local n="$1" url="$2" pat
  pat=$(_lg_cfg '.inflight.pull_refs | if type == "string" then gsub("[\\n\\r]"; " ") else "" end') || exit "$?"
  case "$pat" in
    *[[:space:]]*|*\**\**) pat="" ;;
    refs/*\**) ;;
    *) pat="" ;;
  esac
  if [ -n "$pat" ]; then
    _LG_UP_FH="git fetch $_LG_IX_PR_REMOTE ${pat%%\**}$n${pat#*\*}"
    return 0
  fi
  case "$url" in
    */pull/"$n"|*/pulls/"$n") _LG_UP_FH="git fetch $_LG_IX_PR_REMOTE pull/$n/head" ;;
    *) _LG_UP_FH="git fetch $_LG_IX_PR_REMOTE" ;;
  esac
}

# _lg_up_pr <n> <body-out> → _LG_UP_A, _LG_UP_B (as _lg_up_range), _LG_UP_PR
# and _LG_UP_BODY (<body-out>, or "" when the body was not read): PR <n> from
# config adapters.pr's list, through the remote cache (index.sh
# _lg_ix_pr_fetch: a stale or offline copy serves, as for every verb).
# Merged, with its merge_commit here: merge-base(<merge_commit>^1,
# head_oid)..head_oid when head_oid is here too (the PR's own commits, for
# any merge strategy), else <merge_commit>^1..<merge_commit> (for a rebase
# merge, its last commit only); without a merge_commit, exit 2. Open, with
# its head_oid here: merge-base(config base, head_oid)..head_oid.
# The body: the adapter's view <n> into <body-out>; its exit 3 (no view) or
# DOC_TOOLS_LEDGER_OFFLINE=1 reads none (body_scanned false). Exit 2: no
# adapters.pr, the list failing with no copy, a number the list does not
# hold, a PR neither merged nor open, its commit or the base not here (with
# the fetch command: _lg_up_pr_fetch_hint for an open PR's head; a merge
# commit with no parent names git fetch --unshallow in a shallow clone),
# view failing or breaking its contract.
_lg_up_pr() {
  local n="$1" bodyf="$2" s cfg st mc ho url h base x rc=0 scanned=true
  _lg_scratch_name
  s=$_LG_SN
  _lg_adapter_path pr || _lg_die "--pr: $_LG_ADP_ERR"
  [ -n "$_LG_ADP" ] || _lg_die "--pr needs a PR adapter (config adapters.pr), none is set — give --range <a>..<b> instead"
  _lg_ix_pr_fetch || rc=$?
  if [ "$rc" != 0 ]; then
    _lg_die "--pr: the pr adapter's list is unavailable: ${_LG_RERR:-the pr adapter failed}"
  fi
  # The PR's state, merge_commit, head_oid and url, one line each ("" for a
  # value that is no string; the oids are checked as hex below), from the
  # snapshot (its header line has no number: never a match).
  # shellcheck disable=SC2016  # jq source
  jq -n -r --arg n "$n" '
    def s: if type == "string" then gsub("[\\n\\r]"; " ") else "" end;
    first(inputs | select(type == "object" and (.number | tostring) == $n))
    | (.state | s), (.merge_commit | s), (.head_oid | s), (.url | s)' "$_LG_RSNAP" > "$s.pr" 2> "$s.err" \
    || _lg_die "--pr: cannot read the pr adapter's list: $(head -n 1 "$s.err")"
  [ -s "$s.pr" ] || _lg_die "--pr: no PR #$n in the pr adapter's list (ledger ls --refresh reads the list again)"
  { IFS= read -r st; IFS= read -r mc; IFS= read -r ho; IFS= read -r url; } < "$s.pr" || _lg_die "cannot read $s.pr"
  cfg=$(_lg_cfg '.base | if type == "string" then gsub("\n"; " ") else "" end') || exit "$?"
  x="git fetch $_LG_IX_PR_REMOTE"
  case "$st" in
    merged)
      case "$mc" in
        '') _lg_die "--pr: PR #$n is merged, but the pr adapter gives no merge_commit — give --range <a>..<b>" ;;
      esac
      if ! printf '%s\n' "$mc" | LC_ALL=C grep -Eqx '[0-9a-f]{40}([0-9a-f]{24})?' \
          || ! _LG_UP_B=$(git rev-parse -q --verify "$mc^{commit}" 2>/dev/null); then
        _lg_die "--pr: PR #$n's merge commit ${mc:0:12} is not in this clone ($x)"
      fi
      if ! _LG_UP_A=$(git rev-parse -q --verify "$_LG_UP_B^1" 2>/dev/null); then
        if [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
          _lg_die "--pr: PR #$n's merge commit ${mc:0:12} has no parent here: this clone is shallow (git fetch --unshallow)"
        fi
        _lg_die "--pr: PR #$n's merge commit ${mc:0:12} has no parent"
      fi
      # The merged head here: the PR's own commits, whatever the merge
      # (a rebase merge's merge_commit is its last rebased commit alone).
      if printf '%s\n' "$ho" | LC_ALL=C grep -Eqx '[0-9a-f]{40}([0-9a-f]{24})?' \
          && h=$(git rev-parse -q --verify "$ho^{commit}" 2>/dev/null); then
        _LG_UP_A=$(git merge-base "$_LG_UP_A" "$h" 2>/dev/null) \
          || _lg_die "--pr: PR #$n's head ${ho:0:12} and its merge commit's first parent have no merge base here"
        _LG_UP_B=$h
      fi
      ;;
    open)
      case "$ho" in
        '') _lg_die "--pr: PR #$n is open, but the pr adapter gives no head_oid — give --range <base>...<head>" ;;
      esac
      if ! printf '%s\n' "$ho" | LC_ALL=C grep -Eqx '[0-9a-f]{40}([0-9a-f]{24})?' \
          || ! _LG_UP_B=$(git rev-parse -q --verify "$ho^{commit}" 2>/dev/null); then
        _lg_up_pr_fetch_hint "$n" "$url"
        _lg_die "--pr: PR #$n's head ${ho:0:12} is not in this clone ($_LG_UP_FH)"
      fi
      case "$cfg" in
        '') _lg_die "--pr: PR #$n is open and config base is empty: no merge base to start from" ;;
        -*) _lg_die "--pr: config base '$cfg' does not resolve to a commit here ($x)" ;;
      esac
      base=$(git rev-parse -q --verify "$cfg^{commit}" 2>/dev/null) \
        || _lg_die "--pr: config base '$cfg' does not resolve to a commit here ($x)"
      _LG_UP_A=$(git merge-base "$base" "$_LG_UP_B" 2>/dev/null) \
        || _lg_die "--pr: config base '$cfg' and PR #$n's head ${ho:0:12} have no merge base here"
      ;;
    *) _lg_die "--pr: PR #$n is ${st:-of no state}, neither merged nor open: no range to read" ;;
  esac
  # The body (view is optional and never cached; offline, it never runs).
  _LG_UP_BODY=""
  if [ "${DOC_TOOLS_LEDGER_OFFLINE:-}" = 1 ]; then
    scanned=false
  else
    rc=0
    _lg_adapter pr view "$n" > "$s.view" 2> "$s.verr" || rc=$?
    case "$rc" in
      0) jq -j '.body' "$s.view" > "$bodyf" || _lg_die "jq failed (the PR body)"
         _LG_UP_BODY=$bodyf ;;
      3) scanned=false ;;
      *) _lg_die "--pr: the pr adapter's view $n failed: $(head -n 1 "$s.verr" | tr -d '\000-\010\013-\037')" ;;
    esac
  fi
  _LG_UP_PR=$(jq -nc --argjson n "$n" --arg st "$st" --argjson b "$scanned" '{number: $n, state: $st, body_scanned: $b}') \
    || _lg_die "jq failed (the pr object)"
}

# _lg_up_range <spec> → _LG_UP_A, _LG_UP_B: the range's two commits (full
# ids); for <a>...<b>, _LG_UP_A is merge-base(a, b). A spec that is no range,
# or one with an empty end: usage (3). An end that does not resolve to a
# commit here, or two ends without a merge base: exit 2.
_lg_up_range() {
  local spec="$1" a b x
  case "$spec" in
    *...*) a=${spec%%...*}; b=${spec#*...} ;;
    *..*) a=${spec%%..*}; b=${spec#*..} ;;
    *) _lg_usage "--range takes <a>..<b> or <a>...<b> (got '$spec')" ;;
  esac
  if [ -z "$a" ] || [ -z "$b" ]; then
    _lg_usage "--range takes <a>..<b> or <a>...<b>, both ends named (got '$spec')"
  fi
  for x in "$a" "$b"; do
    case "$x" in
      -*|*$'\n'*) _lg_die "--range: '$x' does not resolve to a commit here" ;;
    esac
  done
  _LG_UP_A=$(git rev-parse -q --verify "$a^{commit}" 2>/dev/null) || _lg_die "--range: '$a' does not resolve to a commit here"
  _LG_UP_B=$(git rev-parse -q --verify "$b^{commit}" 2>/dev/null) || _lg_die "--range: '$b' does not resolve to a commit here"
  case "$spec" in
    *...*)
      _LG_UP_A=$(git merge-base "$_LG_UP_A" "$_LG_UP_B" 2>/dev/null) \
        || _lg_die "--range: '$a' and '$b' have no merge base here" ;;
  esac
}

# _lg_up_index <b-oid> → _LG_UP_IX: the index upkeep reads, built once per
# run — the working tree's when <b-oid> is HEAD's commit (a relation just
# written with ledger link counts before it is committed), else <b-oid>'s
# own (--rev: an item the range adds counts wherever upkeep runs from). The
# caller sets _LG_IX_NEED_CONTRACTS (the verb: 1, a failing contracts
# adapter exits 2).
_lg_up_index() {
  local head
  if [ -n "$_LG_UP_IX" ] && [ "$_LG_UP_IXB" = "$1" ]; then return 0; fi
  head=$(git rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null) || head=""
  if [ "$1" = "$head" ]; then
    _LG_UP_IX=$(_lg_index) || exit "$?"
  else
    _LG_UP_IX=$(_lg_index --rev "$1") || exit "$?"
  fi
  _LG_UP_IXB=$1
}

# The core's jq helpers. Path lists reach jq one per line, a newline in a
# name as \001 and a tab as \002 (up_dec takes them back).
# shellcheck disable=SC2016  # jq source
_LG_JQ_UP_DEFS='
def up_dec: if test("[\u0001\u0002]") then gsub("\u0001"; "\n") | gsub("\u0002"; "\t") else . end;
def up_lines: split("\n") | map(select(. != "") | up_dec);
def up_ordered_unique: reduce .[] as $x ([]; if index([$x]) != null then . else . + [$x] end);
# The word scan (sweep): words of [A-Za-z0-9_-], lower case, once each.
def up_words: [splits("[^A-Za-z0-9_-]+") | select(. != "") | ascii_downcase] | unique;
def up_signals: ["named", "trailer:claims", "trailer:claims_by_path", "trailer:claims_by_ref",
                 "item-file-edited", "key-in-message", "key-in-pr-body"];
def up_rank: if . == "named" then 0 elif startswith("trailer:") then 1 elif . == "item-file-edited" then 2
             elif . == "key-in-message" then 3 else 4 end;
# A Contract-Change value: its id (the first word), and the rest without
# the separator (":", "—", "–", "-") — as the in-flight scan reads it.
def up_cc: (capture("^(?<w>[^ \t]*)(?<r>.*)$")) as $x
  | ($x.r | sub("^[ \t:]*"; "") | (if startswith("—") or startswith("–") then .[1:] else . end) | sub("^[ \t:-]*"; "")) as $l
  | {id: $x.w, line: $l};
# Evidence per file: f of each of the first 3 of $fs, then "… and N more
# files".
def up_ev_files($fs; f):
  ($fs | length) as $n | [($fs[0:3][] | f), (if $n > 3 then "… and \($n - 3) more files" else empty end)];
# The evidence of a touched contract $t ({contract, files, cc}).
def up_ev_changes($t):
  up_ev_files($t.files; "diff touches \(.) (defined_in of \($t.contract))")
  + [$t.cc[] | if . == "" then "Contract-Change: \($t.contract)" else "Contract-Change: \($t.contract) — \(.)" end];
# Attribution: each contract of $open ([{contract, …}]) to one item of $inv
# (the involved, [{p, rank}]; $byp: {path: item}) — the most paths entries
# $g ({file: [contract ids]}: the index path_contracts for defined_in, the
# read_by map for a read contract) files under it; then the most paths
# entries that are net-diff files ($ds); then the best rank; then key (else
# path) order. → {item path: [the contracts it gets]}; {} without $inv.
def up_attr($open; $inv; $byp; $g; $ds):
  if $inv == [] then {}
  else lg_lists($open[] | . as $t
    | ($inv | map(. as $v | $byp[$v.p] as $I | (($I.paths // []) | unique) as $ps
        | {p: $v.p,
           n1: ([$ps[] | select((($g[.] // []) | index([$t.contract])) != null)] | length),
           n2: ([$ps[] | select($ds[.] == true)] | length),
           r: $v.rank, o: ($I.key // $I.path)})
        | sort_by(-.n1, -.n2, .r, .o) | .[0].p) as $win
    | {k: $win, v: $t})
  end;
# A word as the shell reads it: bare when safe, else single-quoted.
def up_shq: if test("^[A-Za-z0-9_./:,@%+=-][A-Za-z0-9_./:,@%+=~-]*$") then . else @sh end;
# The link line for item $I and its shown proposals $SH (null without).
def up_link($I; $SH):
  if $SH == [] then null
  else (($I.key // ($I.path | if startswith("-") then "./" + . else . end)) | up_shq) as $ref
    | ("ledger link \($ref)"
       + ([("changes", "consumes") as $f | [$SH[] | select(.field == $f) | .value] as $vs
           | select($vs != []) | " --\($f) \($vs | join(",") | up_shq)"] | join("")))
    | lg_q_one
  end;
'

# _LG_JQ_UPKEEP: the core's one pass, over the index ($ix) — inputs $c
# (config), $diff (the net-diff files, lines), $fc ({file: [contract ids]}
# for the files skip_globs leaves, by defined_in), $rc (the same by
# read_by), $rp ({paths entry: [contract ids]} by read_by, for the live
# items; {} when $rc is), $tr (_lg_msg_claims' lines), $words (the messages
# without their claim trailer lines), $body / $hasbody (the PR body), $named
# / $hasnamed (--items' paths, lines), $a, $b, $commits, $top. Stages:
# involvement ($INV), touched contracts ($TALL, $TCH), their attribution
# ($ATTR), read contracts ($READ) and theirs ($RATTR), proposals ($PROPS:
# [{p, field, value, evidence, _g, _cc, _n}] — _g the group: 0 changes, 1
# consumes (a), 2 consumes (b)), then per item ranking, --top and the link
# line.
# shellcheck disable=SC2016  # jq source
_LG_JQ_UPKEEP="$_LG_JQ_UP_DEFS"'
. as $ix
| lg_r_maps($ix) as $M
| $c[0].upkeep.skip_contracts as $skipc
| [$ix.items[] | select(.archived != true)] as $LIVE
| lg_obj($LIVE[] | {(.path): true}) as $LP
| (reduce $LIVE[] as $i ({}; reduce ([$i.key] + ($i.aliases // []) | .[] | strings | ascii_downcase) as $k
     (.; if has($k) then . else .[$k] = $i.path end))) as $KM
| (($ix.finalized // {}) | if type == "object" then . else {} end) as $FIN
| lg_lists($LIVE[] | select((.url | type) == "string")
           | (.path | capture("(?<n>#[0-9]+)$").n // empty) as $n | {k: $n, v: .path}) as $HM
| ($diff | up_lines) as $DIFF
| lg_obj($DIFF[] | {(.): true}) as $DS
| [$tr | split("\n")[] | select(. != "") | split("\t") | {k: .[1], v: (.[2:] | join("\t"))}] as $TR
# Involvement: one {p, s} per signal, then per item its found_by and rank.
| (if $hasnamed then [$named | up_lines | .[] | {p: ., s: "named"}]
   else
     [ ($TR[] | select(.k == "claims") | .v | splits("[, \t]+") | select(. != "") as $w
        | ($KM[$w | ascii_downcase]
           // (($FIN[$w] // $FIN[$w | ascii_downcase]) | if type == "string" then $KM[ascii_downcase] else null end)
           // empty)
        | {p: ., s: "trailer:claims"}),
       ($TR[] | select(.k == "claims_by_path") | .v | sub("^\\./"; "") | select($LP[.] == true) | {p: ., s: "trailer:claims_by_path"}),
       ($TR[] | select(.k == "claims_by_ref") | ($HM[.v] // []) | select(length == 1) | {p: .[0], s: "trailer:claims_by_ref"}),
       ($DIFF[] | select($LP[.] == true) | {p: ., s: "item-file-edited"}),
       ($words | up_words[] | ($KM[.] // empty) | {p: ., s: "key-in-message"}),
       (if $hasbody then ($body | up_words[] | ($KM[.] // empty) | {p: ., s: "key-in-pr-body"}) else empty end) ]
   end) as $SIG
| [$SIG | group_by(.p)[] | .[0].p as $p | $M.BYP[$p] as $I | (map(.s) | unique) as $ss
   | {p: $p, key: $I.key, found_by: [up_signals[] as $x | select($ss | index([$x]) != null) | $x],
      rank: ([$ss[] | up_rank] | min)}]
  | sort_by(.rank, (.key // .p)) as $INV
# Touched contracts: by a net-diff file (skip_globs left out: $fc) or by a
# Contract-Change line; $TALL every one, $TCH those upkeep may propose.
| lg_lists($fc[0] | to_entries[] | (.key | up_dec) as $f | .value[] | {k: ., v: $f}) as $CF
| lg_obj(($ix.contracts // [])[] | {(.id): true}) as $ISC
| lg_lists($TR[] | select(.k == "contract_change") | .v | up_cc | select($ISC[.id] == true) | {k: .id, v: .line}) as $CCL
| [(($CF | keys) + ($CCL | keys) | unique)[] as $k
   | {contract: $k, files: (($CF[$k] // []) | unique), cc: (($CCL[$k] // []) | up_ordered_unique)}] as $TALL
| lg_obj($TALL[] | {(.contract): true}) as $TOUCHED
| [$TALL[] | select(.contract as $k | $skipc | index([$k]) == null)] as $TCH
# Covered: an involved item declares it in changes.
| lg_obj($INV[] | ($M.BYP[.p].changes // [])[] | strings | {(.): true}) as $COV
| [$TCH[] | select($COV[.contract] != true)] as $OPEN
| up_attr($OPEN; $INV; $M.BYP; $M.D; $DS) as $ATTR
# Read contracts: a non-skipped net-diff file their read_by matches ($rc),
# and untouched (no defined_in file, no Contract-Change line); never a
# skip_contracts id. Covered: an involved item declares it in consumes.
# Attribution as for a touched one, read_by in place of defined_in ($rp:
# {paths entry: [contracts whose read_by matches it]}).
| lg_lists($rc[0] | to_entries[] | (.key | up_dec) as $f | .value[] | {k: ., v: $f}) as $RF
| [($RF | keys)[] as $k | select($TOUCHED[$k] != true and ($skipc | index([$k])) == null)
   | {contract: $k, files: ($RF[$k] | unique)}] as $READ
| lg_obj($INV[] | ($M.BYP[.p].consumes // [])[] | strings | {(.): true}) as $RCOV
| [$READ[] | select($RCOV[.contract] != true)] as $ROPEN
| up_attr($ROPEN; $INV; $M.BYP; lg_obj($rp[0] | to_entries[] | {(.key | up_dec): .value}); $DS) as $RATTR
# Proposals, per involved item (_g the group): 0 changes — each attributed
# touched contract it does not declare; 1 consumes (a) — each attributed
# read contract it does not declare; 2 consumes (b), only at rank 2 or
# better — each untouched contract whose defined_in matches a paths entry
# the diff does not hold, not declared, not in skip_contracts, not (a).
| [$INV[] | . as $v | $M.BYP[$v.p] as $I
   | (($I.changes // []) | map(strings)) as $dch
   | (($I.consumes // []) | map(strings)) as $dcs
   | [($ATTR[$v.p] // [])[] | select(.contract as $k | $dch | index([$k]) == null)
      | {p: $v.p, field: "changes", value: .contract, evidence: up_ev_changes(.), _g: 0,
         _cc: (if .cc != [] then 0 else 1 end), _n: ((.files | length) + (.cc | length))}] as $PC
   | [($RATTR[$v.p] // [])[] | select(.contract as $k | $dcs | index([$k]) == null) | . as $t
      | {p: $v.p, field: "consumes", value: $t.contract,
         evidence: up_ev_files($t.files; "diff touches \(.) (read_by of \($t.contract))"),
         _g: 1, _cc: 1, _n: ($t.files | length)}] as $PA
   | (if $v.rank > 2 then {}
      else lg_lists((($I.paths // []) | unique)[] | select($DS[.] != true) as $f | ($M.D[$f] // [])[] | {k: ., v: $f}) end) as $LB
   | ($dcs + [$PA[].value]) as $NOTB
   | $PC[], $PA[],
     (($LB | keys)[] as $k
      | select($TOUCHED[$k] != true and ($skipc | index([$k])) == null and ($NOTB | index([$k])) == null)
      | {p: $v.p, field: "consumes", value: $k,
         evidence: up_ev_files($LB[$k]; "the item lists \(.) (defined_in of \($k)), which the range does not change"),
         _g: 2, _cc: 1, _n: ($LB[$k] | length)})] as $PROPS
| lg_lists($PROPS[] | {k: .p, v: .}) as $PBY
# Per item: rank its proposals, keep --top of them, the link line.
| [$INV[] | . as $v | $M.BYP[$v.p] as $I
   | (($PBY[$v.p] // []) | sort_by(._g, ._cc, -._n, .value)) as $R
   | (if $top == 0 then $R else $R[:$top] end) as $SH
   | {key: $I.key, path: $I.path, found_by: $v.found_by, rank: $v.rank,
      proposed: [$SH[] | {field, value, evidence}], total: ($R | length), truncated: (($SH | length) < ($R | length)),
      declared_untouched: [(($I.changes // []) | map(strings) | unique)[] | select($TOUCHED[.] != true)],
      link: up_link($I; $SH)}] as $ITEMS
| {range: "\($a)..\($b)", files: ($DIFF | length), commits: $commits, items: $ITEMS,
   unattributed_contracts: (if $INV == [] then [($OPEN[], $ROPEN[]) | {contract, files}] | sort_by(.contract) else [] end),
   touched: [$TCH[] | {contract, files, cc_line: (.cc[0] // null)}]}
'

# _lg_up_core <a-oid> <b-oid> <body-file|""> <named-paths-file|""> <out.json>:
# upkeep's computation for the range <a-oid>..<b-oid> (full ids; the caller
# resolves "..." and all-zeros ends), written to <out.json> as one object
#   {range: "<a>..<b>", files: <n>, commits: <n>,
#    items: [{key, path, found_by, rank, proposed: [{field, value,
#             evidence}], total, truncated, declared_untouched, link}],
#    unattributed_contracts: [{contract, files}],
#    touched: [{contract, files, cc_line}]}
# rank (0 named … 4 key-in-pr-body) and touched are for callers
# (validate --pushed); the verb's payload leaves them out. touched: every
# contract touched — through non-skipped files or a Contract-Change line —
# but upkeep.skip_contracts, sorted by id; files the non-skipped net-diff
# files its defined_in matches; cc_line the first Contract-Change line's
# text ("" for a bare one), null without. <body-file>: the PR body
# (key-in-pr-body). <named-paths-file>: a NUL-terminated list of item paths
# (--items, resolved): only they are involved. Keeps _LG_UP_TOP proposals
# per item (0: all; a caller that needs every attribution sets 0). Index:
# _lg_up_index <b-oid>. Dies (2) on a git failure, a bad upkeep config or
# glob, or a failing contracts adapter (with _LG_IX_NEED_CONTRACTS=1).
_lg_up_core() {
  local a="$1" b="$2" body="$3" named="$4" out="$5" s n="" hb=false hn=false msg="" rd=""
  [ "$#" = 5 ] || _lg_die "internal: _lg_up_core <a> <b> <body-file|\"\"> <named-paths-file|\"\"> <out>"
  _lg_scratch_name
  s=$_LG_SN
  # The config: upkeep.skip_globs (one per line) and skip_contracts, checked.
  # shellcheck disable=SC2016  # jq source
  _lg_cfg '.upkeep as $u
    | if ($u | type) != "object" then "bad\tconfig upkeep must be an object"
      elif ($u.skip_globs | type) != "array" or any($u.skip_globs[]; type != "string" or test("[\n\r]"))
      then "bad\tconfig upkeep.skip_globs must be a list of globs"
      elif ($u.skip_contracts | type) != "array" or any($u.skip_contracts[]; type != "string")
      then "bad\tconfig upkeep.skip_contracts must be a list of contract ids"
      else "ok", $u.skip_globs[] end' > "$s.cfg"
  IFS= read -r msg < "$s.cfg" || msg=""
  case "$msg" in
    ok) ;;
    bad*) _lg_die "${msg#bad	}" ;;
    *) _lg_die "internal: upkeep config read as '$msg'" ;;
  esac
  tail -n +2 "$s.cfg" > "$s.skipg" || _lg_die "cannot write $s.skipg"
  _lg_up_index "$b"
  # The net diff (NUL-terminated), the files skip_globs matches, the rest.
  git diff-tree -r --name-only -z --no-renames "$a" "$b" -- > "$s.diff" 2> "$s.err" \
    || _lg_die "git diff-tree $a $b failed: $(head -n 3 "$s.err" 2>/dev/null)"
  _lg_paths_filter "$s.diff" "$s.skipg" "$s.skip"
  tr '\n\t\000' '\001\002\n' < "$s.diff" > "$s.diff.l" || _lg_die "cannot read the net diff"
  tr '\n\t\000' '\001\002\n' < "$s.skip" > "$s.skip.l" || _lg_die "cannot read the skipped files"
  LC_ALL=C awk -v skip="$s.skip.l" 'BEGIN { while ((getline l < skip) > 0) S[l] = 1 } !($0 in S)' "$s.diff.l" > "$s.keep.l" \
    || _lg_die "cannot list the range's files"
  _lg_r_file_contracts "$_LG_UP_IX" "$s.keep.l" "$s.fc"
  # The reader signal: the contracts whose read_by matches each of those
  # files; when one does, also each live item's paths entry (the read
  # contracts' attribution).
  _lg_r_file_contracts "$_LG_UP_IX" "$s.keep.l" "$s.rc" read_by
  IFS= read -r rd < "$s.rc" || rd=""
  if [ "$rd" = "{}" ]; then
    printf '{}\n' > "$s.rp" || _lg_die "cannot write $s.rp"
  else
    # shellcheck disable=SC2016  # jq source
    jq -r '[.items[] | select(.archived != true) | (.paths // [])[] | strings] | unique[]
      | if test("[\n\t]") then gsub("\n"; "\u0001") | gsub("\t"; "\u0002") else . end' "$_LG_UP_IX" > "$s.ip.l" \
      || _lg_die "jq failed (the items' paths)"
    _lg_r_file_contracts "$_LG_UP_IX" "$s.ip.l" "$s.rp" read_by
  fi
  # The trailers; then the messages for the word scan, without the claim
  # trailer lines (claims, claims_by_path), and the number of commits.
  _lg_msg_claims "$a..$b" > "$s.tr"
  _lg_trailers "$s.trn"
  git -c log.showSignature=false log --no-color --format='%x01%H%n%B' "$a..$b" -- > "$s.msg" 2> "$s.err" \
    || _lg_die "git log failed: $(head -n 3 "$s.err" 2>/dev/null)"
  LC_ALL=C awk -v tr="$s.trn" -v cnt="$s.n" "$_LG_AWK_TRAILER"'
    BEGIN { tr_load(tr) }
    substr($0, 1, 1) == "\001" { n++; next }
    { tr_match($0); for (i = 1; i <= TRM; i++) if (TRMK[i] == "claims" || TRMK[i] == "claims_by_path") next; print }
    END { print n + 0 > cnt }' "$s.msg" > "$s.words" || _lg_die "cannot read the range's messages"
  IFS= read -r n < "$s.n" || n=0
  if [ -n "$body" ]; then hb=true; else body=/dev/null; fi
  if [ -n "$named" ]; then
    hn=true
    tr '\n\t\000' '\001\002\n' < "$named" > "$s.named.l" || _lg_die "cannot read $named"
  else
    : > "$s.named.l"
  fi
  jq -L "$_LG_LIB" -c --slurpfile c "$_LG_CFG" --slurpfile fc "$s.fc" --slurpfile rc "$s.rc" --slurpfile rp "$s.rp" \
    --rawfile diff "$s.diff.l" --rawfile tr "$s.tr" --rawfile words "$s.words" \
    --rawfile body "$body" --argjson hasbody "$hb" --rawfile named "$s.named.l" --argjson hasnamed "$hn" \
    --arg a "$a" --arg b "$b" --argjson commits "$n" --argjson top "${_LG_UP_TOP:-3}" \
    "$_LG_JQ_INCLUDE$_LG_JQ_UPKEEP" "$_LG_UP_IX" > "$out" || _lg_die "jq failed (ledger upkeep)"
}

# _lg_up_top: --top N into _LG_UP_TOP — a whole number, at most 9 digits
# (leading zeros dropped); default 3; anything else is a usage error (3).
# shellcheck disable=SC2154  # _OPT_top is set by _parse_args
_lg_up_top() {
  _LG_UP_TOP=3
  if _opt_seen top; then
    case "$_OPT_top" in
      ''|*[!0123456789]*|??????????*) _lg_usage "--top takes a whole number (0: all proposals; got '$_OPT_top')" ;;
    esac
    _LG_UP_TOP=$((10#$_OPT_top))
  fi
}

# _lg_up_named <out>: the --items values resolved as show resolves them,
# against the index upkeep reads (_lg_up_index), into <out>: their item
# paths, NUL-terminated, in order (a repeat once). A value that names no
# item, several, an archived legacy row or an archived item: usage (3).
# The values reach jq as a file (NUL-separated), never as argv: jq reads
# an option-like value (--items -x) as an option even after --args.
# shellcheck disable=SC2154  # _OPTV_items is set by _parse_args
_lg_up_named() {
  local s m
  _lg_scratch_name
  s=$_LG_SN
  _lg_up_index "$_LG_UP_B"
  { [ "${#_OPTV_items[@]}" = 0 ] || printf '%s\0' "${_OPTV_items[@]}"; } > "$s.refs" || _lg_die "cannot write $s.refs"
  jq -Rsc 'split("\u0000")[:-1]' "$s.refs" > "$s.refs.json" || _lg_die "jq failed (--items)"
  # shellcheck disable=SC2016  # jq source
  jq -L "$_LG_LIB" -r --slurpfile c "$_LG_CFG" --slurpfile refs "$s.refs.json" \
    "$_LG_JQ_INCLUDE$_LG_JQ_RESOLVE_DEFS"'
    . as $ix
    | [$refs[0][] as $r | {v: $r, r: ($ix | lg_resolve($r; $c[0]))}] as $R
    | ([$R[] | select(.r.r != "item")
        | "bad\t--items \(.v | tojson) is not one item" + (if .r.r == "ambiguous" then " (several: \(.r.v | join(", ")))" else "" end)]
       + [$R[] | select(.r.r == "item") | .r.v as $p | select(any($ix.items[]; .path == $p and .archived == true))
          | "bad\t--items \(.v | tojson) is an archived item: upkeep never involves one"]) as $bad
    | if $bad != [] then $bad[]
      else ([$R[].r.v] | reduce .[] as $p ([]; if index([$p]) != null then . else . + [$p] end))[]
        | "ok\t\(gsub("\n"; "\u0001"))" end' "$_LG_UP_IX" > "$s.r" || _lg_die "jq failed (--items)"
  if grep -q '^bad	' "$s.r"; then
    m=$(grep '^bad	' "$s.r" | head -n 1 | cut -f 2-)
    _lg_usage "$m"
  fi
  cut -f 2- "$s.r" | tr '\n\001' '\000\n' > "$1" || _lg_die "cannot write $1"
}

# The text lines of the verb's payload.
# shellcheck disable=SC2016  # jq source
_LG_JQ_UP_TEXT='
def up_files($fs): ($fs | length) as $n | ($fs[0:3] | join(", ")) + (if $n > 3 then ", … and \($n - 3) more files" else "" end);
. as $O
| "range \($O.range | split("..") | map(.[0:12]) | join(".."))  \($O.files) files, \($O.commits) commits",
  ($O.items[]
   | "\((.key // .path) | lg_q_one)  found by \(.found_by | join(", "))",
     (.proposed[] | "  + \(.field) \(.value | lg_q_one)  — \(.evidence | join("; ") | lg_q_one)"),
     (if .truncated then "  (showing \(.proposed | length) of \(.total); --top 0 shows all)" else empty end),
     (if .declared_untouched != [] then "  declared, untouched: \(.declared_untouched | join(", ") | lg_q_one)" else empty end),
     (if .link != null then "  link: \(.link)" else empty end)),
  ($O.unattributed_contracts[]
   | "unattributed: \(.contract | lg_q_one) (\(if .files == [] then "Contract-Change" else up_files(.files) | lg_q_one end))"),
  (if all($O.items[]; .total == 0) then "(no proposals)" else empty end)
'

# shellcheck disable=SC2154  # _OPT_*, _OPTV_* and _ARGS are set by _parse_args
cmd_ledger_upkeep() {
  local s named="" rc=0 n pr=""
  _lg_init upkeep
  [ "${#_ARGS[@]}" = 0 ] || _lg_usage "unexpected argument '${_ARGS[0]}' (give --range <a>..<b> or --pr <n>)"
  if _opt_seen range && _opt_seen pr; then _lg_usage "give --range or --pr, not both"; fi
  if ! _opt_seen range && ! _opt_seen pr; then _lg_usage "give --range <a>..<b>, --range <a>...<b> or --pr <n>"; fi
  if _opt_seen pr; then
    case "$_OPT_pr" in
      ''|*[!0123456789]*|??????????*) _lg_usage "--pr takes a PR number (got '$_OPT_pr')" ;;
    esac
    pr=$((10#$_OPT_pr))
  fi
  _lg_up_top
  # Before anything that could run an adapter (the PR list, the index).
  if [ "$_OPT_no_repo_adapters" = 1 ]; then _lg_up_no_repo; fi
  _lg_scratch_name
  s=$_LG_SN
  if [ -n "$pr" ]; then
    _lg_up_pr "$pr" "$s.body"
  else
    _lg_up_range "$_OPT_range"
  fi
  _LG_IX_NEED_CONTRACTS=1
  if [ "${#_OPTV_items[@]}" -gt 0 ]; then
    _lg_up_named "$s.named"
    named="$s.named"
  fi
  _lg_up_core "$_LG_UP_A" "$_LG_UP_B" "$_LG_UP_BODY" "$named" "$s.core"
  # The payload: spec §4's fields — rank and touched stay the core's.
  jq -c --argjson pr "$_LG_UP_PR" '{range, pr: $pr, files, commits, items: [.items[] | del(.rank)], unattributed_contracts}' "$s.core" > "$s.out" \
    || _lg_die "jq failed (ledger upkeep payload)"
  n=$(jq '[.items[].total] | add // 0' "$s.out") || _lg_die "jq failed (ledger upkeep proposals)"
  if [ "$_OPT_strict" = 1 ] && [ "$n" -gt 0 ]; then rc=1; fi
  if [ "$_LG_FORMAT" = json ]; then
    _lg_pr_data_into "$s.out"
    _lg_emit upkeep "$rc" "$s.out"
  fi
  jq -L "$_LG_LIB" -r "$_LG_JQ_INCLUDE$_LG_JQ_UP_TEXT" "$s.out" | tr -d '\000-\010\013-\037' > "$s.txt" \
    || _lg_die "jq failed (ledger upkeep text)"
  _lg_out_file "$s.txt"
  _lg_emit upkeep "$rc"
}
