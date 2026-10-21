# shellcheck shell=bash
# scripts/ledger/upkeep.sh — merge-time upkeep (#39; design 2026-10-18 §4):
# `ledger upkeep`, the declarations a range's diff says its items are
# missing — proposed, never written. Sourced by lib.sh; uses lib.sh's
# _lg_init, _lg_usage, _lg_die, _lg_emit, _lg_out_file, _lg_cfg,
# _lg_src_cat, index.sh's _lg_index and _LG_JQ_INCLUDE, keys.sh's
# _LG_JQ_RESOLVE_DEFS (lg_resolve), relations.sh's _lg_msg_claims,
# _lg_trailers, _lg_tr_incl, _LG_AWK_TRAILER, _LG_AWK_RW (the Related work
# reader) and _lg_r_file_contracts, glob.sh's _lg_paths_filter,
# _lg_glob_dirs and _LG_AWK_GLOB, inflight.sh's _lg_ifl_plans and
# _LG_AWK_IFL_PLAN (what a plan is), query.sh's _lg_pr_data_into,
# parse.sh's _lg_scratch_name; defs.jq's lg_r_maps; adapters.sh's
# _lg_adapter / _lg_adapter_path, index.sh's _lg_ix_pr_fetch.
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
#     plan-cited — an item no other signal involves that a plan cited by
#     a document-defined contract's document links (Proposals; one its
#     other pointer, a trailer of a commit editing the document, names is
#     always found by that claim trailer), a candidate for that contract
#     only (for another, only when no other item is involved);
#   4 plan-link — an item a plan in the net diff (one the range adds or
#     modifies) links: a Related work row marked include names it (its
#     key, an alias or its path), or a frontmatter value (a scalar, or an
#     element of a list) is one of those; never a key word of its body. A
#     plan as in-flight finds one (_lg_ifl_plans: a .md file in the
#     directory of a doc-index entry of a doc_columns.plan type, or
#     matching doc_columns.plan.globs), read where the index is;
#   5 key-in-pr-body — the same as 3's words, in the PR body (--pr;
#     _lg_up_core's <body-file>).
#   --items <item>… names them instead (found_by ["named"], rank 0): each
#   must resolve, as show resolves, to one item that is not archived (else
#   exit 3), and only they are involved.
# Touched contracts: an index contract whose defined_in matches a net-diff
#   file upkeep.skip_globs does not match, when a changed line of that file
#   names it, or that a "Contract-Change: <id> [— <line>]" trailer in the
#   range names. A document-defined contract (design §4 D9, ruling R68:
#   its one defined_in entry, a markdown path or glob — ending in ".md",
#   up_docdef — matches exactly one .md file in <b>'s tree (or the range's
#   deleted files), and no other contract's defined_in names or matches it)
#   is touched by any net-diff edit of its document, skip_globs
#   notwithstanding, with no name test; any other contract — a glob of
#   several documents, a shared document — as above. Read
#   contracts: an untouched one whose read_by matches such a file with a
#   changed line that names it.
#   Names (design §4, D7): a
#   changed line is an added or removed line of the net diff (git diff -U0;
#   a binary file has none, a deleted file's removed lines count); it names
#   <kind>:<name> when <name> (the id after the first ":") occurs in it,
#   case-sensitive, with no [A-Za-z0-9_] just before or after — a * in
#   <name> any run of [A-Za-z0-9_.-], every other character itself
#   (up_names, _LG_JQ_UP_DEFS).
# Proposals (changes): a touched contract an involved item declares in
#   changes is covered — proposed to nobody. Every other one, except
#   upkeep.skip_contracts, goes to exactly one involved item: the most
#   paths entries its defined_in matches; then the most paths entries that
#   are net-diff files; then the best rank; then key (else path) order. An
#   item the range adds (its file added in the net diff) that neither a
#   claim trailer nor --items names (ruling R63) is a candidate only when
#   every involved item is one (D7: a follow-up filed in the range never
#   takes the work's own contracts).
#   With no involved item it is unattributed. Evidence: "diff names <c> in
#   <f> (defined_in of <c>)" per file (3 at most, then "… and N more
#   files"), then "Contract-Change: <c> — <line>" per trailer line.
#   A document-defined contract's owner comes from the amendment's
#   pointers (D9): the items each plan its document's changed lines name
#   links — by path from the top level, or by a relative link resolved
#   against the document's directory (as plan-link reads a plan) — and
#   the items the claim trailers of the commits that edit the document
#   name (git log <a>..<b> -- <doc>, one per document). The pointed items
#   that are involved join
#   the candidates, an added one too, right after the defined_in count
#   (pointed before not, then the rest of the order), with the evidence
#   "diff amends <doc>, which cites <plan> (links <key>)" / "<commit12>
#   (<trailer>) amends <doc>"; when the lines cite a plan and none is, it
#   is unattributed with cites (the plans), never the normal winner's;
#   with no pointer, the normal order, evidence "diff amends <doc>
#   (defined_in of <c>)" per document.
# Proposals (consumes): (a) a read contract, the same way — covered by an
#   involved item's consumes, else attributed (read_by in place of
#   defined_in) or unattributed; evidence "diff names <c> in <f> (read_by
#   of <c>)". (b) for an item of rank 2 or better (never one found by words
#   alone): each untouched contract whose defined_in matches a paths entry
#   the net diff does not hold and that the item's own text names (Names) —
#   its title and summary (the index's h1 and fields.summary) and the body
#   of its file without the frontmatter, so never its relation lists (a
#   hosted item: its body excerpt, less a word the adapter's cut ends
#   inside), read where the index is (the working tree when <b> is HEAD,
#   else <b>): "the item names <c> and lists <f> (defined_in of <c>),
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
#   [{contract, files, cites?}]} (+ pr_data / items_data; cites only for a
#   document-defined contract whose cited plans reach no involved item —
#   listed whatever the range involves). Text: "range <a12>..<b12>
#   <n> files, <m> commits"; per item "<key|path>  found by <signals>",
#   "  + <field> <value>  — <evidence; …>", "  (showing N of M; --top 0
#   shows all)", "  declared, untouched: a, b", "  link: ledger link …";
#   then "unattributed: <c> (<files>)"; "(no proposals)" when no item has
#   one. Exit 0 (proposals are advisory); 1 with --strict and a proposal; 2
#   a range that does not resolve, a failing contracts adapter, a bad
#   upkeep config, --pr without adapters.pr, its list failing (no copy) or
#   view failing, a PR not usable, a --no-repo-adapters refusal; 3 usage.
#   Cost: one index build, one git diff-tree of the names (with their
#   status: the added ones) and one git diff-tree -p -U0 of the files a
#   defined_in or read_by matches (none without such a file; the whole
#   range when their names pass _LG_UP_PATHS_MAX bytes), two git log walks
#   (_lg_msg_claims' and the word scan's) and one more per document of a
#   document-defined contract in the net diff; with a markdown file in it,
#   the doc-index read once, each plan cited or in the net diff once (from
#   the working tree, or one git cat-file per plan at <b>), and one git
#   ls-tree of <b> when a glob may define a document; the text
#   of the items with a consumes (b) candidate, once (likewise); with --pr,
#   the list (cached) and one view.

_LG_UP_TOP=3   # proposals kept per item (0: all) — the verb's --top
_LG_UP_IX=""   # _lg_up_index: the index upkeep reads …
_LG_UP_IXB=""  # … and the commit it was chosen for
_LG_UP_IXWT="" # … and 1 when it is the working tree's (<b> is HEAD)
_LG_UP_PR=null # the payload's pr: null, or {number, state, body_scanned}
_LG_UP_BODY="" # the PR body's file (_lg_up_pr); "" when none was read
_LG_UP_FH=""   # _lg_up_pr_fetch_hint's command
_LG_UP_PATHS_MAX=100000 # bytes of candidate file names _lg_up_core hands git as
                        # pathspecs; more, the whole range's diff (tests lower it)

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
# written with ledger link counts before it is committed; _LG_UP_IXWT 1),
# else <b-oid>'s own (--rev: an item the range adds counts wherever upkeep
# runs from; _LG_UP_IXWT ""). The item text consumes (b) reads comes from
# the same place (_lg_up_texts). The caller sets _LG_IX_NEED_CONTRACTS (the
# verb: 1, a failing contracts adapter exits 2).
_lg_up_index() {
  local head
  if [ -n "$_LG_UP_IX" ] && [ "$_LG_UP_IXB" = "$1" ]; then return 0; fi
  head=$(git rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null) || head=""
  if [ "$1" = "$head" ]; then
    _LG_UP_IX=$(_lg_index) || exit "$?"
    _LG_UP_IXWT=1
  else
    _LG_UP_IX=$(_lg_index --rev "$1") || exit "$?"
    _LG_UP_IXWT=""
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
def up_signals: ["named", "trailer:claims", "trailer:claims_by_path", "trailer:claims_by_ref",
                 "item-file-edited", "key-in-message", "plan-cited", "plan-link", "key-in-pr-body"];
def up_rank: if . == "named" then 0 elif startswith("trailer:") then 1 elif . == "item-file-edited" then 2
             elif . == "key-in-message" or . == "plan-cited" then 3
             elif . == "plan-link" then 4 else 5 end;
# The items a claim trailer line ({k: its kind, v: its value}) names, as
# paths ($KM: {lower-case key or alias: path}; $FIN: finalized.json; $LP:
# {live item path: true}; $HM: {"#N": [the hosted items whose ref ends in
# #N]}): a claims value split on commas and blanks, each a key or alias
# (any case; a provisional key finalized.json maps on counts), a
# claims_by_path value an item path ("./" dropped), a claims_by_ref "#N"
# the one hosted item whose ref ends in #N; any other kind, none.
def up_claimed($KM; $FIN; $LP; $HM):
  if .k == "claims" then
    .v | splits("[, \t]+") | select(. != "") as $w
    | ($KM[$w | ascii_downcase]
       // (($FIN[$w] // $FIN[$w | ascii_downcase]) | if type == "string" then $KM[ascii_downcase] else null end)
       // empty)
  elif .k == "claims_by_path" then .v | sub("^\\./"; "") | select($LP[.] == true)
  elif .k == "claims_by_ref" then ($HM[.v] // []) | select(length == 1) | .[0]
  else empty end;
# A plan link value (design §4 D9) → the item it is: its key or an alias
# (any case), or its path ("./" dropped); else nothing.
def up_item_ref($KM; $LP):
  . as $s | ($KM[$s | ascii_downcase] // ($s | sub("^\\./"; "") | select($LP[.] == true)) // empty);
# Document-defined (design §4 D9, ruling R68), as far as the contract alone
# tells: its defined_in is one markdown path or glob (a spec, an ADR) — one
# entry, ending in ".md". The core also needs it to match exactly one .md
# file in the tree of <b> (or among the files the range deletes) that no
# other contract names or matches. up_glob: the entry holds a glob
# metacharacter (*, ?, {, }, \).
def up_docdef:
  (.defined_in | type) == "array" and (.defined_in | length) == 1
  and (.defined_in[0] | type == "string" and endswith(".md"));
def up_glob: test("[*?{}\\\\]");
# A path as the path lists carry it (a newline as \001, a tab as \002).
def up_enc: if test("[\n\t]") then gsub("\n"; "\u0001") | gsub("\t"; "\u0002") else . end;
# A Contract-Change value: its id (the first word), and the rest without
# the separator (":", "—", "–", "-") — as the in-flight scan reads it.
def up_cc: (capture("^(?<w>[^ \t]*)(?<r>.*)$")) as $x
  | ($x.r | sub("^[ \t:]*"; "") | (if startswith("—") or startswith("–") then .[1:] else . end) | sub("^[ \t:-]*"; "")) as $l
  | {id: $x.w, line: $l};
# Names (design §4): the one matcher, for the changed lines of a diff and
# for the text of an item alike. up_name_re: a contract id → the regex that
# finds where a text names it — its name (the id after the first ":"; the
# whole id without one), case-sensitive, every regex metacharacter in it
# literal, a "*" in it any run of [A-Za-z0-9_.-], with no [A-Za-z0-9_] just
# before or after it; "" for an empty name. up_names($c): the input text
# (one line, or several joined with "\n": a line end bounds a name as any
# character outside [A-Za-z0-9_] does) → true when it names the contract id
# $c, else false; an empty text names nothing (not even an all-"*" name).
# It is the single "does this change touch this contract"
# test upkeep and the validate --pushed advisory share: a future
# code-intelligence adapter (a deterministic symbol/edge model) may replace
# it with a changed-symbol test when one is configured.
def up_name_re: sub("^[^:]*:"; "")
  | if . == "" then ""
    else "(^|[^A-Za-z0-9_])" + (split("*") | map(lg_q_re) | join("[A-Za-z0-9_.-]*")) + "($|[^A-Za-z0-9_])" end;
def up_names($c): . != "" and (($c | up_name_re) as $re | $re != "" and test($re));
# up_by_file(kf): "<file>\t<line>" lines (the input text; a line may hold
# more tabs) → {<file> | kf: its lines, each ended by "\n"} — the text
# up_names reads. Linear: map(. + "\n") | add, where join is quadratic in
# jq (one 50,000-line file took 13 s), and with_entries, where map_values
# is quadratic in jq 1.6 (20,000 files took 13.6 s).
def up_by_file(kf):
  lg_lists(split("\n")[] | select(. != "") | split("\t")
           | {k: (.[0] | kf), v: (if length == 2 then .[1] else .[1:] | join("\t") end)})
  | with_entries(.value |= (map(. + "\n") | add));
# The pairs of $m ({file: [contract ids]}, a file as the path lists carry
# it) whose file has a changed line naming the contract ($cl: {file: its
# changed lines, each ended by "\n"}; a file with none, binary or a mode
# change, is skipped) → {contract: [files]}, the files decoded.
def up_named($m; $cl):
  lg_lists($m | to_entries[] | .key as $e | ($cl[$e] // empty) as $t | ($e | up_dec) as $f
           | .value[] | select(. as $k | $t | up_names($k)) | {k: ., v: $f});
# Evidence per file: f of each of the first 3 of $fs, then "… and N more
# files".
def up_ev_files($fs; f):
  ($fs | length) as $n | [($fs[0:3][] | f), (if $n > 3 then "… and \($n - 3) more files" else empty end)];
# The evidence of a touched contract $t ({contract, files, cc, doc, pev})
# proposed to item $p: for a document-defined one (doc), the pointer lines
# that reach $p (pev: [{p, e}]), else "diff amends <doc> (defined_in of
# <c>)" per document; for any other, "diff names <c> in <f> (defined_in
# of <c>)" per file; then its Contract-Change lines.
def up_ev_changes($t; $p):
  (if $t.doc
   then ([($t.pev // [])[] | select(.p == $p) | .e] | up_ordered_unique) as $pe
     | if $pe != [] then $pe else up_ev_files($t.files; "diff amends \(.) (defined_in of \($t.contract))") end
   else up_ev_files($t.files; "diff names \($t.contract) in \(.) (defined_in of \($t.contract))") end)
  + [$t.cc[] | if . == "" then "Contract-Change: \($t.contract)" else "Contract-Change: \($t.contract) — \(.)" end];
# Attribution: each contract of $open ([{contract, ptr?, …}]) to one item of
# $inv (the involved, [{p, rank, y, pc}]; $byp: {path: item}) — the most
# paths entries $g ({file: [contract ids]}: the index path_contracts for
# defined_in, the read_by map for a read contract) files under it; then a
# pointed item (ptr: the involved items the pointers of a document-defined
# contract reach, design §4 D9) before one not; then the most paths entries
# that are net-diff files ($ds); then the best rank; then key (else path)
# order. The candidates are the first non-empty of: the items that neither
# yield (y: the range adds its file and neither a claim trailer nor --items
# names it — a follow-up the work filed, D7) nor are plan-cited only (pc:
# involved by a cited plan alone, final review I1); then those not pc;
# then every one — and a pointed item joins its own contract.
# → {item path: [the contracts it gets]}; {} without $inv.
def up_attr($open; $inv; $byp; $g; $ds):
  if $inv == [] then {}
  else ($inv | map(select(.y != true and .pc != true))
        | if . != [] then . else ($inv | map(select(.pc != true)) | if . != [] then . else $inv end) end) as $cand
  | lg_lists($open[] | . as $t | ($t.ptr // []) as $pt
    | (if $pt == [] then $cand else $cand + [$inv[] | select(.p as $p | $pt | index([$p]) != null)] | unique_by(.p) end
       | map(. as $v | $byp[$v.p] as $I | (($I.paths // []) | unique) as $ps
        | {p: $v.p,
           n1: ([$ps[] | select((($g[.] // []) | index([$t.contract])) != null)] | length),
           pt: (if ($pt | index([$v.p])) != null then 0 else 1 end),
           n2: ([$ps[] | select($ds[.] == true)] | length),
           r: $v.rank, o: ($I.key // $I.path)})
        | sort_by(-.n1, .pt, -.n2, .r, .o) | .[0].p) as $win
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

# _LG_JQ_UPKEEP: the first of the core's two jq passes (_LG_JQ_UP_RANK, over
# its object, is the second), over the index ($ix) — inputs $c
# (config), $diff (the net-diff files, lines), $add (those the net diff
# adds, lines), $fc ({file: [contract ids]}
# for the files skip_globs leaves, by defined_in), $rc (the same by
# read_by), $dl (the changed lines of the files $fc and $rc hold:
# _LG_AWK_UP_LINES), $rp ({paths entry: [contract ids]} by read_by, for
# the live items; {} when $rc is), $dd ("<file>\t<id>": each net-diff file
# that is a document-defined contract's document, skip_globs aside), $pl
# (the plans: "C\t<document>\t<plan>" for each one a document's changed
# lines name, "M\t<plan>" for each in the net diff — _LG_AWK_UP_PLANS),
# $plk (what each plan links: _LG_AWK_UP_PLAN_LINKS), $dtr ("<document>\t
# <commit>\t<kind>\t<name>\t<value>": the claim trailers of the commits
# that edit each document), $tr (_lg_msg_claims' lines), $words (the
# words of the messages without their claim trailer lines, one per line:
# _LG_AWK_UP_WORDS), $body / $hasbody (the PR body's words likewise),
# $named / $hasnamed (--items' paths, lines), $a, $b, $commits.
# Stages: touched contracts ($TALL, $TCH), the plans and the pointers of
# the document-defined ones ($PLK, $PTR), involvement ($INV), the
# attribution of the touched ones ($ATTR; $UNRES the unresolved), read
# contracts ($READ) and theirs ($RATTR), proposals ($PROPS: [{p, field,
# value, evidence, _g, _cc, _n}] — _g the group: 0 changes, 1 consumes
# (a), 2 consumes (b), a candidate until _LG_JQ_UP_RANK reads the item's
# text), then per item the object _LG_JQ_UP_RANK finishes.
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
# Touched contracts (before involvement: the pointers of a document-defined
# one involve items): by a net-diff file (skip_globs left out: $fc) with a
# changed line that names the contract ($CL: each file, as the path lists
# carry it, its changed lines: up_by_file); a document-defined one ($DOCC)
# by any net-diff edit of its document ($DF), with no name test; or by a
# Contract-Change line. $TALL every one, $TCH those upkeep may propose.
| ($dl | up_by_file(.)) as $CL
| lg_lists($dd | split("\n")[] | select(. != "") | split("\t") | {k: .[1], v: (.[0] | up_dec)}) as $DF
| lg_obj($DF | keys[] | {(.): true}) as $DOCC
| (up_named($fc[0]; $CL) | with_entries(select($DOCC[.key] != true))) as $CF
| lg_obj(($ix.contracts // [])[] | {(.id): true}) as $ISC
| lg_lists($TR[] | select(.k == "contract_change") | .v | up_cc | select($ISC[.id] == true) | {k: .id, v: .line}) as $CCL
| [(($CF | keys) + ($DF | keys) + ($CCL | keys) | unique)[] as $k
   | {contract: $k, files: ((($CF[$k] // []) + ($DF[$k] // [])) | unique), cc: (($CCL[$k] // []) | up_ordered_unique),
      doc: ($DOCC[$k] == true)}] as $TALL
| lg_obj($TALL[] | {(.contract): true}) as $TOUCHED
| [$TALL[] | select(.contract as $k | $skipc | index([$k]) == null)] as $TCH
# The plans (design §4 D9). $PLK: {plan: [the items it links]} — each
# frontmatter value ("F", JSON: a string, or the strings of a list) and
# each first cell of a Related work row marked include ("R") that is the
# key, an alias or the path of an item (up_item_ref), never a key word in
# the body; $CITE: {document: [the plans its changed lines name]}; $PMOD:
# the plans in the net diff; $DTRM: {document: [{p, e}]} — the items the
# claim trailers of the commits that edit it name (each is trailer:claims*
# already: _lg_msg_claims reads every commit of the range). $PTR:
# {document-defined touched contract: its pointers [{p, e, s?}]} (the item,
# the evidence; s "plan-cited", the signal that involves an item with no
# other one); $CITES: {that contract: [the plans its documents cite]}.
| lg_lists($plk | split("\n")[] | select(. != "") | split("\t") as $x | ($x[2:] | join("\t")) as $v
           | (if $x[1] == "F" then $v | fromjson | (if type == "array" then .[] else . end) | strings else $v end)
           | up_item_ref($KM; $LP) | {k: $x[0], v: .}) as $PLK
| [$pl | split("\n")[] | select(. != "") | split("\t")] as $PL
| lg_lists($PL[] | select(.[0] == "C") | {k: (.[1] | up_dec), v: .[2]}) as $CITE
| [$PL[] | select(.[0] == "M") | .[1]] as $PMOD
| lg_lists($dtr | split("\n")[] | select(. != "") | split("\t") as $x | ($x[0] | up_dec) as $f
           | {k: $x[2], v: ($x[4:] | join("\t"))} | up_claimed($KM; $FIN; $LP; $HM)
           | {k: $f, v: {p: ., e: "\($x[1][0:12]) (\($x[3])) amends \($f)"}}) as $DTRM
| lg_obj($TCH[] | select(.doc) | . as $t
         | {(.contract): [$t.files[] as $f
             | ((($CITE[$f] // [])[] as $P | ($PLK[$P] // [])[]
                 | {p: ., e: "diff amends \($f), which cites \($P) (links \($M.BYP[.].key // .))", s: "plan-cited"}),
                ($DTRM[$f] // [])[])]}) as $PTR
| lg_obj($TCH[] | select(.doc) | . as $t | {(.contract): ([$t.files[] as $f | ($CITE[$f] // [])[]] | unique)}) as $CITES
# Involvement: one {p, s} per signal, then per item its found_by and rank;
# an item a cited plan links that no other signal involves is involved as
# plan-cited. --items: the named only.
| (if $hasnamed then [$named | up_lines | .[] | {p: ., s: "named"}]
   else
     [ ($TR[] | . as $t | up_claimed($KM; $FIN; $LP; $HM) | {p: ., s: "trailer:\($t.k)"}),
       ($DIFF[] | select($LP[.] == true) | {p: ., s: "item-file-edited"}),
       ($words | split("\n")[] | select(. != "") | ($KM[.] // empty) | {p: ., s: "key-in-message"}),
       ($PMOD[] as $P | ($PLK[$P] // [])[] | {p: ., s: "plan-link"}),
       (if $hasbody then ($body | split("\n")[] | select(. != "") | ($KM[.] // empty) | {p: ., s: "key-in-pr-body"}) else empty end) ]
     | . + (lg_obj(.[] | {(.p): true}) as $H | [$PTR[][] | select(.s == "plan-cited" and $H[.p] != true) | {p, s}])
   end) as $SIG
# y: the item yields in attribution (up_attr) — the range adds its file and
# neither a claim trailer nor --items names it (ruling R63); pc: its only
# signal is plan-cited, so it is a candidate for the amendment that cites
# its plan alone (final review I1).
| lg_obj($add | up_lines | .[] | {(.): true}) as $ADD
| [$SIG | group_by(.p)[] | .[0].p as $p | $M.BYP[$p] as $I | (map(.s) | unique) as $ss
   | {p: $p, key: $I.key, found_by: [up_signals[] as $x | select($ss | index([$x]) != null) | $x],
      rank: ([$ss[] | up_rank] | min), y: ($ADD[$p] == true and all($ss[]; (startswith("trailer:") or . == "named") | not)),
      pc: ($ss == ["plan-cited"])}]
  | sort_by(.rank, (.key // .p)) as $INV
| lg_obj($INV[] | {(.p): true}) as $INVP
# Covered: an involved item declares it in changes. A document-defined
# contract carries its pointed items (ptr; pev, the pointers that reach
# them) — the involved items its pointers reach — and the plans it cites;
# one that cites a plan and reaches no involved item is unresolved
# ($UNRES): never attributed, listed with its cites.
| lg_obj($INV[] | ($M.BYP[.p].changes // [])[] | strings | {(.): true}) as $COV
| [$TCH[] | select($COV[.contract] != true)
   | if .doc
     then [($PTR[.contract] // [])[] | select($INVP[.p] == true)] as $pv
       | . + {ptr: ([$pv[].p] | unique), pev: $pv, cites: ($CITES[.contract] // [])}
     else . end] as $OPENALL
| [$OPENALL[] | select(.doc and .ptr == [] and .cites != [])] as $UNRES
| [$OPENALL[] | select((.doc and .ptr == [] and .cites != []) | not)] as $OPEN
| up_attr($OPEN; $INV; $M.BYP; $M.D; $DS) as $ATTR
# Read contracts: a non-skipped net-diff file their read_by matches ($rc)
# with a changed line that names them, and untouched (no defined_in file
# naming them, no Contract-Change line); never a skip_contracts id.
# Covered: an involved item declares it in consumes. Attribution as for a
# touched one, read_by in place of defined_in ($rp: {paths entry:
# [contracts whose read_by matches it]}).
| up_named($rc[0]; $CL) as $RF
| [($RF | keys)[] as $k | select($TOUCHED[$k] != true and ($skipc | index([$k])) == null)
   | {contract: $k, files: ($RF[$k] | unique)}] as $READ
| lg_obj($INV[] | ($M.BYP[.p].consumes // [])[] | strings | {(.): true}) as $RCOV
| [$READ[] | select($RCOV[.contract] != true)] as $ROPEN
| up_attr($ROPEN; $INV; $M.BYP; lg_obj($rp[0] | to_entries[] | {(.key | up_dec): .value}); $DS) as $RATTR
# Proposals, per involved item (_g the group): 0 changes — each attributed
# touched contract it does not declare; 1 consumes (a) — each attributed
# read contract it does not declare; 2 consumes (b), only at rank 2 or
# better — each untouched contract whose defined_in matches a paths entry
# the diff does not hold, not declared, not in skip_contracts, not (a): a
# candidate, kept by _LG_JQ_UP_RANK when the text of the item names it.
| [$INV[] | . as $v | $M.BYP[$v.p] as $I
   | (($I.changes // []) | map(strings)) as $dch
   | (($I.consumes // []) | map(strings)) as $dcs
   | [($ATTR[$v.p] // [])[] | select(.contract as $k | $dch | index([$k]) == null)
      | {p: $v.p, field: "changes", value: .contract, evidence: up_ev_changes(.; $v.p), _g: 0,
         _cc: (if .cc != [] then 0 else 1 end), _n: ((.files | length) + (.cc | length))}] as $PC
   | [($RATTR[$v.p] // [])[] | select(.contract as $k | $dcs | index([$k]) == null) | . as $t
      | {p: $v.p, field: "consumes", value: $t.contract,
         evidence: up_ev_files($t.files; "diff names \($t.contract) in \(.) (read_by of \($t.contract))"),
         _g: 1, _cc: 1, _n: ($t.files | length)}] as $PA
   | (if $v.rank > 2 then {}
      else lg_lists((($I.paths // []) | unique)[] | select($DS[.] != true) as $f | ($M.D[$f] // [])[] | {k: ., v: $f}) end) as $LB
   | ($dcs + [$PA[].value]) as $NOTB
   | $PC[], $PA[],
     (($LB | keys)[] as $k
      | select($TOUCHED[$k] != true and ($skipc | index([$k])) == null and ($NOTB | index([$k])) == null)
      | {p: $v.p, field: "consumes", value: $k,
         evidence: up_ev_files($LB[$k]; "the item names \($k) and lists \(.) (defined_in of \($k)), which the range does not change"),
         _g: 2, _cc: 1, _n: ($LB[$k] | length)})] as $PROPS
| lg_lists($PROPS[] | {k: .p, v: .}) as $PBY
# Per item, for _LG_JQ_UP_RANK: its proposals (_props) and, when one is a
# consumes (b) candidate, the text the index holds (_t: the title — h1 —
# and summary; a hosted item, which has no file, its body excerpt too —
# one an items adapter cut, ending in "…" (at whatever length the adapter
# cuts), without the partial word before the "…", whose prefix may be a
# shorter contract id) and whether the body of its file is read as well
# (_f).
| [$INV[] | . as $v | $M.BYP[$v.p] as $I | ($PBY[$v.p] // []) as $P
   | any($P[]; ._g == 2) as $hasb | (($I.url | type) == "string") as $hosted
   | {key: $I.key, path: $I.path, found_by: $v.found_by, rank: $v.rank, _props: $P,
      declared_untouched: [(($I.changes // []) | map(strings) | unique)[] | select($TOUCHED[.] != true)],
      _t: (if $hasb
           then [$I.h1, $I.summary,
                 (if $hosted
                  then $I.first_para
                       | if type == "string" and endswith("…") then sub("[A-Za-z0-9_]+…$"; "…") else . end
                  else empty end)]
                | map(strings) | join("\n")
           else null end),
      _f: ($hasb and ($hosted | not))}] as $ITEMS
| {range: "\($a)..\($b)", files: ($DIFF | length), commits: $commits, items: $ITEMS,
   unattributed_contracts: ([(if $INV == [] then $OPEN[], $UNRES[], $ROPEN[] else $UNRES[] end)
                             | {contract, files} + (if (.cites // []) != [] then {cites} else {} end)]
                            | sort_by(.contract)),
   touched: [$TCH[] | {contract, files, cc_line: (.cc[0] // null)}]}
'

# _LG_JQ_UP_RANK: _LG_JQ_UPKEEP's object finished, per item — inputs $it
# (the body lines of the items whose files _lg_up_texts read:
# _LG_AWK_UP_TEXT's) and $top. A consumes (b) candidate is kept when the
# item's own text names it (Names, up_names): its _t, then its file's body
# (design §4: the title, summary and body — never the frontmatter's
# relation lists). Then its proposals ranked — changes (Contract-Change
# first), consumes (a), consumes (b), each by evidence count, then id —
# --top of them kept, and the link line.
# shellcheck disable=SC2016  # jq source
_LG_JQ_UP_RANK="$_LG_JQ_UP_DEFS"'
($it | up_by_file(up_dec)) as $BT
| .items |= [.[] | . as $v
   | (if $v._t == null then "" else $v._t + "\n" + ($BT[$v.path] // "") end) as $T
   | ([$v._props[] | select(._g != 2 or (.value as $k | $T | up_names($k)))] | sort_by(._g, ._cc, -._n, .value)) as $R
   | (if $top == 0 then $R else $R[:$top] end) as $SH
   | {key, path, found_by, rank, proposed: [$SH[] | {field, value, evidence}], total: ($R | length),
      truncated: (($SH | length) < ($R | length)), declared_untouched, link: up_link($v; $SH)}]
'

# _LG_AWK_UP_LINES: the changed lines (design §4 Names) of a git diff-tree
# -p -U0 --src-prefix=a/ --dst-prefix=b/ (no renames: a file's two names
# are one) — "<file>\t<line>" per added or removed line, its "+" or "-"
# dropped, for each file of the list -v cand (one per line, a newline in a
# name as \001 and a tab as \002: the form <file> is printed in). A file
# starts at its "diff --git a/<f> b/<f>" line (<f> the line's halves, which
# git C-quotes when <f> holds a '"', a "\" or a control character) and its
# header lines (index, modes, "---", "+++") run to its first "@@": a header
# is never a changed line, and a binary file, which has no hunk, prints
# nothing.
# shellcheck disable=SC2016  # awk source
_LG_AWK_UP_LINES='
function up_unq(s,   o, i, n, c) {
  o = ""; n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c != "\\") { o = o c; continue }
    c = substr(s, ++i, 1)
    if (c ~ /[0-7]/) { o = o sprintf("%c", c * 64 + substr(s, i + 1, 1) * 8 + substr(s, i + 2, 1)); i += 2 }
    else if (c == "n") o = o "\n"
    else if (c == "t") o = o "\t"
    else if (c == "r") o = o "\r"
    else if (c == "a") o = o "\007"
    else if (c == "b") o = o "\010"
    else if (c == "f") o = o "\014"
    else if (c == "v") o = o "\013"
    else o = o c
  }
  return o
}
BEGIN { while ((getline l < cand) > 0) C[l] = 1 }
/^diff --git / {
  h = substr($0, 12); n = (length(h) - 1) / 2; f = substr(h, 1, n)
  if (substr(f, 1, 1) == "\"") f = up_unq(substr(f, 2, n - 2))
  f = substr(f, 3); gsub(/\n/, "\001", f); gsub(/\t/, "\002", f)
  keep = (f in C); hunk = 0; next
}
/^@@/ { hunk = 1; next }
hunk && keep && /^[-+]/ { print f "\t" substr($0, 2) }
'

# _LG_AWK_UP_WORDS: the word scan (sweep's) of the messages and the PR body
# (key-in-message, key-in-pr-body): up_words(s) prints each word of s — a
# run of [A-Za-z0-9_-] — lower-cased, once per run of the program. awk, in
# linear time: jq's splits over the whole text is superlinear (200 KB of
# messages took 25 s on jq 1.8 and about 550 s on jq 1.6).
# shellcheck disable=SC2016  # awk source
_LG_AWK_UP_WORDS='
function up_words(s,   n, i, w, W) {
  n = split(s, W, /[^A-Za-z0-9_-]+/)
  for (i = 1; i <= n; i++) {
    if (W[i] == "") continue
    w = tolower(W[i])
    if (!(w in UPW)) { UPW[w] = 1; print w }
  }
}
'

# _LG_AWK_UP_TEXT: the body lines of item files (design §4 consumes (b):
# the item's own text), after frontmatter.awk run with mode=lib — its
# doc_begin and doc_line read each file, so the frontmatter left out is
# the one the index parses (line 1 "---", after an optional BOM, to the
# next "---" line; an unterminated block is body text) and every other
# line is body. Input: item paths, one per line (none holding a newline);
# each is read from that path, or with -v blobs from the file <blobs><its
# line number>; one that cannot be read has no lines. Prints
# "<path>\t<line>" per body line, a tab in <path> as \002 (the path
# lists' form), the line as the file holds it (a CR or a BOM is no name
# character).
# shellcheck disable=SC2016  # awk source
_LG_AWK_UP_TEXT='
{
  ut_f = (blobs != "") ? blobs NR : $0
  ut_p = $0; gsub(/\t/, "\002", ut_p)
  doc_begin()
  while ((getline ut_l < ut_f) > 0) {
    ut_s = state
    doc_line(ut_l)
    if (ut_s == "body" || (ut_s == "start" && state == "body")) print ut_p "\t" ut_l
  }
  close(ut_f)
  if (state == "fm") for (ut_i = 1; ut_i <= nL; ut_i++) print ut_p "\t" L[ut_i]
}
'

# _lg_up_texts <in.json> <b-oid> <out>: the body lines (_LG_AWK_UP_TEXT's)
# of the file items of <in.json> (_LG_JQ_UPKEEP's object) whose file
# consumes (b) reads (_f) — read once per core run, from the working tree
# when the index upkeep reads is the working tree's (_LG_UP_IXWT: <b> is
# HEAD), else as <b-oid> holds them (git cat-file blob, one per item: the
# index built at <b-oid> lists only paths <b-oid> holds as files, so a
# failure is git's own — exit 2, which validate --pushed reports as its
# "could not check" advisory).
_lg_up_texts() {
  local in="$1" b="$2" out="$3" s p n=0 blobs=""
  _lg_scratch_name
  s=$_LG_SN
  jq -r '.items[] | select(._f == true) | .path | select(test("\n") | not)' "$in" > "$s.paths" \
    || _lg_die "jq failed (the items whose text consumes (b) reads)"
  : > "$out" || _lg_die "cannot write $out"
  [ -s "$s.paths" ] || return 0
  if [ "$_LG_UP_IXWT" != 1 ]; then
    blobs="$s.b"
    while IFS= read -r p; do
      n=$((n + 1))
      git cat-file blob "$b:$p" > "$blobs$n" 2> "$s.err" \
        || _lg_die "git cat-file $b:$p failed: $(head -n 3 "$s.err" 2>/dev/null)"
    done < "$s.paths"
  fi
  printf '%s\n' "$_LG_AWK_UP_TEXT" > "$s.awk" || _lg_die "cannot write $s.awk"
  _lg_awkv "$blobs"
  LC_ALL=C awk -v mode=lib -v bom="$_LG_BOM" -v blobs="$_LG_AV" -f "$_LG_LIB/frontmatter.awk" -f "$s.awk" "$s.paths" > "$out" \
    || _lg_die "cannot read the items' text"
}

# _LG_AWK_UP_PLANS (after _LG_AWK_GLOB and inflight.sh's _LG_AWK_IFL_PLAN:
# a plan is a file in-flight reads as one): the plans upkeep reads (design
# §4 D9). Input: the net-diff files, one per line (a newline in a name as
# \001, a tab as \002); -v plans (_lg_ifl_plans' lines), dd ("<file>\t<id>"
# lines: the documents of the document-defined contracts) and dl
# (_LG_AWK_UP_LINES' "<file>\t<line>" lines). Prints "C\t<document>\t<plan>"
# for each plan a changed line of a document names — a run of
# [A-Za-z0-9_./-] ending in ".md" and followed by no [A-Za-z0-9_] (so a
# link's "#fragment" or "?query" is left out), its path from the top level
# (a leading "/" dropped) or, when it starts with "./" or "../", relative
# to the document's directory (final review I2); its "." and ".."
# segments resolved (up_norm), and one that climbs above the top level
# names none — once per document; then "M\t<plan>" for each net-diff file
# that is a plan.
# shellcheck disable=SC2016  # awk source
_LG_AWK_UP_PLANS='
# up_norm(p): path p with its empty and "." segments dropped and each ".."
# taking the segment before it away; "" when one climbs above the top.
function up_norm(p,   n, i, k, o, S, O) {
  n = split(p, S, /\//)
  k = 0
  for (i = 1; i <= n; i++) {
    if (S[i] == "" || S[i] == ".") continue
    if (S[i] == "..") { if (k == 0) return ""; k--; continue }
    O[++k] = S[i]
  }
  o = ""
  for (i = 1; i <= k; i++) o = o (i > 1 ? "/" : "") O[i]
  return o
}
BEGIN {
  ifl_plans(plans)
  while ((getline l < dd) > 0) UPD[substr(l, 1, index(l, "\t") - 1)] = 1
  close(dd)
  re = "[A-Za-z0-9_./-]+[.]md"
  while ((getline l < dl) > 0) {
    t = index(l, "\t"); f = substr(l, 1, t - 1)
    if (!(f in UPD)) continue
    s = substr(l, t + 1)
    while (match(s, re)) {
      p = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
      if (substr(s, 1, 1) ~ /[A-Za-z0-9_]/) continue
      if (substr(p, 1, 2) == "./" || substr(p, 1, 3) == "../") { d = f; sub(/[^\/]*$/, "", d); p = d p }
      p = up_norm(p)
      if (p == "") continue
      if (ifl_plan(p) && !((f, p) in UPS)) { UPS[f, p] = 1; print "C\t" f "\t" p }
    }
  }
  close(dl)
}
ifl_plan($0) { print "M\t" $0 }
'

# _LG_AWK_UP_PLAN_LINKS (after relations.sh's _LG_AWK_RW, the Related work
# reader sweep --plan and validate --plan use): what each plan links
# (design §4 D9), with frontmatter.awk run with mode=lib — its doc_begin
# and doc_line read each plan, so its frontmatter is parsed as an item's
# is (FK, FV: each key and its value as JSON; an unterminated block has
# none, its lines are body text). Input: plan paths, one per line; each
# read from that path, or with -v blobs from the file <blobs><its line
# number>; one that cannot be read has no lines. Prints "<plan>\tF\t<json>"
# per frontmatter value, and "<plan>\tR\t<item>" per data row of a Related
# work table in its body whose mark is "include" (any case, once its
# surrounding `, * and _ are dropped) — <item> the row's first cell, less
# its surrounding `, * and _.
# shellcheck disable=SC2016  # awk source
_LG_AWK_UP_PLAN_LINKS='
function up_body(line,   c) {
  sub(/\r$/, "", line)
  if (rw_line(line) != 1 || RW_MC > RW_N || tolower(rw_trim(rw_bare(RW_C[RW_MC]))) != "include") return
  c = rw_trim(rw_bare(RW_C[1])); gsub(/\t/, " ", c)
  if (c != "") print UP "\tR\t" c
}
{
  uf = (blobs != "") ? blobs NR : $0
  UP = $0
  doc_begin(); rw_begin()
  while ((getline ul < uf) > 0) {
    us = state
    doc_line(ul)
    if (us == "body" || (us == "start" && state == "body")) up_body(ul)
  }
  close(uf)
  if (state == "fm") for (ui = 1; ui <= nL; ui++) up_body(L[ui])
  else for (ui = 1; ui <= nk; ui++) print UP "\tF\t" FV[FK[ui]]
}
'

# _lg_up_plans <pl> <b-oid> <out>: what the plans of <pl> (_LG_AWK_UP_PLANS'
# lines) link — _LG_AWK_UP_PLAN_LINKS' lines — each plan read once, from
# the working tree when the index upkeep reads is the working tree's
# (_LG_UP_IXWT: <b> is HEAD), else as <b-oid> holds it (lib.sh
# _lg_src_cat): a plan it does not hold (one the range deletes, a citation
# of none) has no text; a failing read is exit 2.
_lg_up_plans() {
  local pl="$1" b="$2" out="$3" s p n=0 blobs=""
  _lg_scratch_name
  s=$_LG_SN
  : > "$out" || _lg_die "cannot write $out"
  [ -s "$pl" ] || return 0
  LC_ALL=C awk -F '\t' '{ p = ($1 == "C") ? $3 : $2 } !(p in S) { S[p] = 1; print p }' "$pl" > "$s.paths" \
    || _lg_die "cannot list the plans"
  if [ "$_LG_UP_IXWT" != 1 ]; then
    blobs="$s.b"
    while IFS= read -r p; do
      n=$((n + 1))
      _lg_src_cat "$b" "$p" "$blobs$n" || : > "$blobs$n" || _lg_die "cannot write $blobs$n"
    done < "$s.paths"
  fi
  printf '%s\n' "$_LG_AWK_RW$_LG_AWK_UP_PLAN_LINKS" > "$s.awk" || _lg_die "cannot write $s.awk"
  _lg_awkv "$blobs"
  LC_ALL=C awk -v mode=lib -v bom="$_LG_BOM" -v blobs="$_LG_AV" -f "$_LG_LIB/frontmatter.awk" -f "$s.awk" "$s.paths" > "$out" \
    || _lg_die "cannot read the plans"
}

# _lg_up_doc_trailers <a-oid> <b-oid> <dd> <out>: the claim trailers of the
# commits of <a>..<b> that edit each document of <dd> ($dd's "<file>\t<id>"
# lines) — "<document>\t<commit>\t<kind>\t<name>\t<value>" (kind claims,
# claims_by_path or claims_by_ref; name the trailer as config writes it;
# config trailers.since honoured, as _lg_msg_claims honours it): one git
# log per document (design §4 D9), read in one awk pass.
_lg_up_doc_trailers() {
  local a="$1" b="$2" dd="$3" out="$4" s x n=0
  _lg_scratch_name
  s=$_LG_SN
  : > "$out" || _lg_die "cannot write $out"
  [ -s "$dd" ] || return 0
  LC_ALL=C awk -F '\t' '!($1 in S) { S[$1] = 1; print $1 }' "$dd" > "$s.docs.l" || _lg_die "cannot list the documents"
  tr '\001\002\n' '\n\t\000' < "$s.docs.l" > "$s.docs" || _lg_die "cannot list the documents"
  : > "$s.log"
  while IFS= read -r -d '' x; do
    n=$((n + 1))
    printf '\002%s\n' "$n" >> "$s.log" || _lg_die "cannot write $s.log"
    git -c log.showSignature=false --literal-pathspecs log --no-color --format='%x01%H%n%B' "$a..$b" -- "$x" >> "$s.log" 2> "$s.err" \
      || _lg_die "git log $a..$b failed (a document's commits): $(head -n 3 "$s.err" 2>/dev/null)"
  done < "$s.docs"
  printf '%s..%s\n' "$a" "$b" > "$s.revl" || _lg_die "cannot write $s.revl"
  _lg_tr_incl "$s.tri" "$s.revl"
  _lg_trailers "$s.tr"
  LC_ALL=C awk -v docs="$s.docs.l" -v tr="$s.tr" -v trx="$s.tri" "$_LG_AWK_TRAILER"'
    BEGIN { while ((getline l < docs) > 0) D[++nd] = l; close(docs); tr_load(tr); tr_since(trx) }
    substr($0, 1, 1) == "\002" { d = D[substr($0, 2) + 0]; next }
    substr($0, 1, 1) == "\001" { c = substr($0, 2); next }
    {
      tr_match($0); tr_cut(c)
      for (i = 1; i <= TRM; i++)
        if (TRMK[i] == "claims" || TRMK[i] == "claims_by_path" || TRMK[i] == "claims_by_ref")
          print d "\t" c "\t" TRMK[i] "\t" TRMN[i] "\t" TRMV[i]
    }' "$s.log" > "$out" || _lg_die "cannot read the documents' commits"
}

# _lg_up_core <a-oid> <b-oid> <body-file|""> <named-paths-file|""> <out.json>:
# upkeep's computation for the range <a-oid>..<b-oid> (full ids; the caller
# resolves "..." and all-zeros ends), written to <out.json> as one object
#   {range: "<a>..<b>", files: <n>, commits: <n>,
#    items: [{key, path, found_by, rank, proposed: [{field, value,
#             evidence}], total, truncated, declared_untouched, link}],
#    unattributed_contracts: [{contract, files, cites?}],
#    touched: [{contract, files, cc_line}]}
# rank (0 named … 5 key-in-pr-body) and touched are for callers
# (validate --pushed); the verb's payload leaves them out. touched: every
# contract touched — through non-skipped files, a document-defined one's
# document, or a Contract-Change line — but upkeep.skip_contracts, sorted
# by id; files the non-skipped net-diff files its defined_in matches that
# have a changed line naming it (Names), or a document-defined one's
# documents in the net diff; cc_line the first Contract-Change line's text
# ("" for a bare one), null without. <body-file>: the PR body
# (key-in-pr-body). <named-paths-file>: a NUL-terminated list of item paths
# (--items, resolved): only they are involved. Keeps _LG_UP_TOP proposals
# per item (0: all; a caller that needs every attribution sets 0). Index:
# _lg_up_index <b-oid>; the item text consumes (b) reads and the plans,
# from the same place (_lg_up_texts, _lg_up_plans). Dies (2) on a git
# failure, a bad upkeep config or glob, or a failing contracts adapter
# (with _LG_IX_NEED_CONTRACTS=1).
_lg_up_core() {
  local a="$1" b="$2" body="$3" named="$4" out="$5" s n="" hb=false hn=false msg="" rd="" md="" x
  local cf=() gd=()
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
  # The net diff: one git diff-tree of the names, each record its status,
  # then its name (each NUL-ended), read as lines (a newline in a name as
  # \001, a tab as \002) — the net-diff files, the ones it adds (an item
  # filed in the range yields in attribution: up_attr), the markdown files
  # it deletes, and md 1 when one is a markdown file; then the files
  # skip_globs matches, the rest (keep), and the skipped markdown files.
  git diff-tree -r --name-status -z --no-renames "$a" "$b" -- > "$s.ns" 2> "$s.err" \
    || _lg_die "git diff-tree $a $b failed: $(head -n 3 "$s.err" 2>/dev/null)"
  tr '\n\t\000' '\001\002\n' < "$s.ns" > "$s.ns.l" || _lg_die "cannot read the net diff"
  LC_ALL=C awk -v diff="$s.diff.l" -v add="$s.add.l" -v del="$s.del.l" '
    BEGIN { printf "" > diff; printf "" > add; printf "" > del }
    NR % 2 { st = $0; next }
    { print > diff; if (st == "A") print > add; if ($0 ~ /\.md$/) { md = 1; if (st == "D") print > del } }
    END { print (md ? 1 : "") }' "$s.ns.l" > "$s.md" || _lg_die "cannot read the net diff"
  IFS= read -r md < "$s.md" || md=""
  _lg_paths_filter "$s.diff.l" "$s.skipg" "$s.skip.l" lines
  LC_ALL=C awk -v skip="$s.skip.l" -v skipm="$s.skipm.l" '
    BEGIN { printf "" > skipm; while ((getline l < skip) > 0) S[l] = 1 }
    ($0 in S) { if ($0 ~ /\.md$/) print > skipm; next }
    { print }' "$s.diff.l" > "$s.keep.l" || _lg_die "cannot list the range's files"
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
  # The document-defined contracts' documents (design §4 D9, ruling R68):
  # "<file>\t<id>" for each net-diff file — skip_globs notwithstanding —
  # that a contract's one defined_in entry, a markdown path or glob
  # (up_docdef), matches alone among the .md files in <b>'s committed tree
  # (never the working tree's) and the range's deleted files, and that no
  # other contract's defined_in names or matches. The document is the key
  # every later step reads (the trailer walk, the citations, the touched
  # files), a glob's matched path, never the glob. By defined_in, the contracts of the net diff's markdown files
  # ($s.fc for a file skip_globs leaves, $s.fcm for one it matches) give
  # each candidate's net-diff files: one, holding that contract alone. A
  # literal path needs nothing more ("D" lines); a glob ("G" lines) must
  # match no other file at <b> — one git ls-tree of <b> under the globs'
  # literal directories, matched with the deleted ones by
  # _lg_r_file_contracts, counts. Without a markdown file in the net diff
  # (md ""), no document and no plan is looked for.
  : > "$s.dd"
  if [ -n "$md" ]; then
    if [ -s "$s.skipm.l" ]; then
      _lg_r_file_contracts "$_LG_UP_IX" "$s.skipm.l" "$s.fcm"
    else
      printf '{}\n' > "$s.fcm" || _lg_die "cannot write $s.fcm"
    fi
    # shellcheck disable=SC2016  # jq source
    jq -L "$_LG_LIB" -r --slurpfile fc "$s.fc" --slurpfile fm "$s.fcm" "$_LG_JQ_INCLUDE$_LG_JQ_UP_DEFS"'
      ($fc[0] + $fm[0]) as $FA
      | lg_lists($FA | to_entries[] | .key as $f | .value[] | {k: ., v: $f}) as $FOF
      | (.contracts // [])[] | select(up_docdef) | .id as $i | .defined_in[0] as $e | ($FOF[$i] // []) as $fs
      | select(($fs | length) == 1 and $FA[$fs[0]] == [$i])
      | if ($e | up_glob) then "G\t\($fs[0])\t\($i)\t\($e)" else "D\t\($fs[0])\t\($i)" end' "$_LG_UP_IX" > "$s.ddc" \
      || _lg_die "jq failed (the document-defined contracts)"
    LC_ALL=C awk -F '\t' -v dd="$s.dd" -v gl="$s.ddg.l" '
      BEGIN { printf "" > dd; printf "" > gl }
      $1 == "D" { print $2 "\t" $3 > dd; next }
      !($4 in S) { S[$4] = 1; print $4 > gl }' "$s.ddc" || _lg_die "cannot read the document-defined contracts"
    if [ -s "$s.ddg.l" ]; then
      _lg_glob_dirs "$s.ddg.l" "$s.ddg.d"
      while IFS= read -r x; do
        gd+=("$x")
      done < "$s.ddg.d"
      git --literal-pathspecs ls-tree -r --name-only -z "$b" -- ${gd[@]+"${gd[@]}"} > "$s.bt" 2> "$s.err" \
        || _lg_die "git ls-tree $b failed: $(head -n 3 "$s.err" 2>/dev/null)"
      tr '\n\t\000' '\001\002\n' < "$s.bt" > "$s.bt.l" || _lg_die "cannot read the documents at $b"
      cat "$s.del.l" >> "$s.bt.l" || _lg_die "cannot write $s.bt.l"
      _lg_r_file_contracts "$_LG_UP_IX" "$s.bt.l" "$s.fcb"
      # shellcheck disable=SC2016  # jq source
      jq -n -r --slurpfile fb "$s.fcb" --rawfile g "$s.ddc" '
        (reduce ($fb[0][][]) as $c ({}; .[$c] += 1)) as $N
        | $g | split("\n")[] | select(startswith("G\t")) | split("\t") | select($N[.[2]] == 1) | "\(.[1])\t\(.[2])"' \
        >> "$s.dd" || _lg_die "jq failed (the documents a glob defines)"
    fi
  fi
  # The changed lines (Names; a document's, for the plans it cites): one git
  # diff-tree -p -U0 over the files a contract's defined_in or read_by
  # matches (pathspecs taken literally; plumbing, so no user diff config —
  # an external diff, colour, prefixes, textconv — changes what it prints),
  # read by _LG_AWK_UP_LINES. None of those files: no diff. Their names
  # over _LG_UP_PATHS_MAX bytes: the whole range's diff, no pathspec (a
  # command line that long fails, E2BIG) — the awk keeps the same files.
  jq -r -s --rawfile dd "$s.dd" '((.[0] + .[1]) | keys[]), ($dd | split("\n")[] | select(. != "") | split("\t")[0])' \
    "$s.fc" "$s.rc" > "$s.cand.l" || _lg_die "jq failed (the contracts' files)"
  : > "$s.dl"
  if [ -s "$s.cand.l" ]; then
    x=$(wc -c < "$s.cand.l") || _lg_die "cannot read the contracts' files"
    if [ "$((x))" -le "$_LG_UP_PATHS_MAX" ]; then
      tr '\001\002\n' '\n\t\000' < "$s.cand.l" > "$s.cand" || _lg_die "cannot read the contracts' files"
      cf=(--)
      while IFS= read -r -d '' x; do
        cf+=("$x")
      done < "$s.cand"
    fi
    git -c core.quotePath=false --literal-pathspecs diff-tree -r -p -U0 --no-renames --no-color --no-ext-diff \
      --no-textconv --src-prefix=a/ --dst-prefix=b/ "$a" "$b" ${cf[@]+"${cf[@]}"} > "$s.patch" 2> "$s.err" \
      || _lg_die "git diff-tree -p $a $b failed: $(head -n 3 "$s.err" 2>/dev/null)"
    LC_ALL=C awk -v cand="$s.cand.l" "$_LG_AWK_UP_LINES" "$s.patch" > "$s.dl" || _lg_die "cannot read the range's changed lines"
  fi
  # The plans (design §4 D9), found as in-flight finds them in the doc-index
  # where the index is (_lg_ifl_plans): those the documents' changed lines
  # cite and those in the net diff, and what each links (none without a
  # markdown file in the net diff). Then the claim trailers of the commits
  # that edit each document.
  : > "$s.pl"
  if [ -n "$md" ]; then
    if [ "$_LG_UP_IXWT" = 1 ]; then x=worktree; else x=$b; fi
    _lg_ifl_plans "$x" "$s.plans"
    if [ -s "$s.plans" ]; then
      LC_ALL=C awk -v plans="$s.plans" -v dd="$s.dd" -v dl="$s.dl" "$_LG_AWK_GLOB$_LG_AWK_IFL_PLAN$_LG_AWK_UP_PLANS" "$s.diff.l" > "$s.pl" \
        || _lg_die "cannot list the range's plans"
    fi
  fi
  _lg_up_plans "$s.pl" "$b" "$s.plk"
  _lg_up_doc_trailers "$a" "$b" "$s.dd" "$s.dtr"
  # The trailers; then the words of the messages (_LG_AWK_UP_WORDS), their
  # claim trailer lines (claims, claims_by_path) left out, and the number
  # of commits; the PR body's words likewise.
  _lg_msg_claims "$a..$b" > "$s.tr"
  _lg_trailers "$s.trn"
  git -c log.showSignature=false log --no-color --format='%x01%H%n%B' "$a..$b" -- > "$s.msg" 2> "$s.err" \
    || _lg_die "git log failed: $(head -n 3 "$s.err" 2>/dev/null)"
  LC_ALL=C awk -v tr="$s.trn" -v cnt="$s.n" "$_LG_AWK_TRAILER$_LG_AWK_UP_WORDS"'
    BEGIN { tr_load(tr) }
    substr($0, 1, 1) == "\001" { n++; next }
    { tr_match($0); for (i = 1; i <= TRM; i++) if (TRMK[i] == "claims" || TRMK[i] == "claims_by_path") next; up_words($0) }
    END { print n + 0 > cnt }' "$s.msg" > "$s.words" || _lg_die "cannot read the range's messages"
  IFS= read -r n < "$s.n" || n=0
  if [ -n "$body" ]; then
    hb=true
    LC_ALL=C awk "$_LG_AWK_UP_WORDS"'{ up_words($0) }' "$body" > "$s.bwords" || _lg_die "cannot read the PR body"
  else
    : > "$s.bwords"
  fi
  if [ -n "$named" ]; then
    hn=true
    tr '\n\t\000' '\001\002\n' < "$named" > "$s.named.l" || _lg_die "cannot read $named"
  else
    : > "$s.named.l"
  fi
  jq -L "$_LG_LIB" -c --slurpfile c "$_LG_CFG" --slurpfile fc "$s.fc" --slurpfile rc "$s.rc" --slurpfile rp "$s.rp" \
    --rawfile diff "$s.diff.l" --rawfile add "$s.add.l" --rawfile dl "$s.dl" --rawfile tr "$s.tr" --rawfile words "$s.words" \
    --rawfile dd "$s.dd" --rawfile pl "$s.pl" --rawfile plk "$s.plk" --rawfile dtr "$s.dtr" \
    --rawfile body "$s.bwords" --argjson hasbody "$hb" --rawfile named "$s.named.l" --argjson hasnamed "$hn" \
    --arg a "$a" --arg b "$b" --argjson commits "$n" \
    "$_LG_JQ_INCLUDE$_LG_JQ_UPKEEP" "$_LG_UP_IX" > "$s.up" || _lg_die "jq failed (ledger upkeep)"
  # consumes (b): the text of the items with a candidate, then the ranking.
  _lg_up_texts "$s.up" "$b" "$s.it"
  jq -L "$_LG_LIB" -c --rawfile it "$s.it" --argjson top "${_LG_UP_TOP:-3}" \
    "$_LG_JQ_INCLUDE$_LG_JQ_UP_RANK" "$s.up" > "$out" || _lg_die "jq failed (ledger upkeep ranking)"
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
# The values reach jq as a file, never as argv (jq reads an option-like
# value, --items -x, as an option even after --args): NUL-terminated, each
# NUL as \001, as the path lists reach jq — jq 1.6 drops the NUL that ends
# raw input, so the last value would be lost.
# shellcheck disable=SC2154  # _OPTV_items is set by _parse_args
_lg_up_named() {
  local s m
  _lg_scratch_name
  s=$_LG_SN
  _lg_up_index "$_LG_UP_B"
  { [ "${#_OPTV_items[@]}" = 0 ] || printf '%s\0' "${_OPTV_items[@]}"; } | tr '\000' '\001' > "$s.refs" \
    || _lg_die "cannot write $s.refs"
  jq -Rsc 'split("\u0001")[:-1]' "$s.refs" > "$s.refs.json" || _lg_die "jq failed (--items)"
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
