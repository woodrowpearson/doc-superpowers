#!/usr/bin/env bash
# scripts/adapters/ledger-items-gh.sh — the work ledger's reference items
# adapter (design §G; config "items": {"adapter":
# "doc-superpowers:ledger-items-gh"}): hosted items as the repository's
# GitHub issues, through the GitHub CLI. gh runs in the current directory
# (the ledger runs adapters from the work tree's top level, so gh finds the
# repository from its remotes).
#
#   ledger-items-gh.sh list [--since <timestamp>]
#     One call: gh issue list --state all --limit 1000 --json number,title,
#     body,state,stateReason,labels,updatedAt,url. When it returns as many
#     issues as its limit, the list may be cut: exit 2 ("could not list
#     completely"), never a silent truncation. --since keeps the issues
#     whose updatedAt is that timestamp or later (compared as strings: give
#     gh's form, 2026-10-01T00:00:00Z). Output: one compact JSON line per
#     issue, in gh's order —
#       {"ref": "gh#<number>", "url", "title", "body_excerpt", "status",
#        "fields": {…}, "labels": [<name>…], "updated": <updatedAt>,
#        "closed": <closedAt>|null, "fm_errors": [<message>…]}
#     ("closed": when it was closed — the ledger's re-check markers take a
#     hosted item as landed then; beyond §G's contract, like fm_errors)
#     fields: the metadata block's fields — the HTML comment
#       <!-- doc-superpowers-ledger
#       key: checkout-14
#       summary: …
#       -->
#     in the body (its first marker line outside fenced code: JQ_BLOCK
#     below; a closing "-->" not on a line of its own is an fm_errors
#     entry), invisible when rendered, read with the item frontmatter
#     grammar (scripts/ledger/frontmatter.awk: scalars, flow and block
#     lists; anything else is an fm_errors entry — beyond §G's contract,
#     as ledger-pr-gh.sh's merge_commit is) — plus ledger and severity from
#     the labels "<LEDGER_GH_LEDGER_PREFIX><id>" (default "ledger:") and
#     "<LEDGER_GH_SEV_PREFIX><value>" (default "sev:"), which win over the
#     block (two such labels: a list, which validate reports). The block's
#     keys are the ledger's logical field names (owed, superseded_by, …).
#     body_excerpt: the first paragraph of the body outside the block
#     (headings and fenced blocks are no paragraph), whitespace collapsed,
#     at most 280 characters (a longer one ends with "…"); null when none.
#     status, the first rule that matches: closed with superseded_by in the
#     block → "Closed"; closed as completed → "Fixed"; closed as not
#     planned → "Won't Fix"; closed otherwise (duplicate, no reason) →
#     "Closed"; open → "Open".
#   ledger-items-gh.sh write <ref> <field> <value>
#     ledger, severity: the issue's labels with that prefix are replaced by
#     <prefix><value> (an empty value removes them), the label created in
#     the repository first when the issue lacks it (`gh label create`;
#     "already exists" is not an error). status: refused (exit 3) — it
#     follows the issue's open or closed state. Any other field: that line
#     of the metadata block is rewritten (scripts/ledger/fm-write.awk: the
#     frontmatter quoting; an empty value removes it), the rest of the block
#     and of the body kept byte for byte; a body without a block gets one at
#     its end (after the closing line of a fence the body ends inside).
#     gh issue view, then gh issue edit --body-file. Refused
#     (exit 3): a value holding "-->" or "--!>" (it would close the HTML
#     comment early), a line break, or — for ledger and severity, which
#     are joined into gh's comma-separated label lists — a comma.
#   ledger-items-gh.sh note <ref> <text>
#     gh issue comment <n> --body-file (the text).
#   ledger-items-gh.sh create --title <title> --body-file <file>
#     gh issue create; prints {"ref": "gh#<n>", "url": <url>}. When gh
#     prints no issue URL the issue may exist all the same: exit 2 with
#     what gh printed, so a retry does not duplicate it unseen.
# <ref> is "gh#<number>".
#
# Exit: 0 done · 2 could not — gh missing, unauthenticated or failing (its
# stderr is passed through), output that is not gh's JSON, the list at its
# limit, scripts/ledger/ not beside this script's directory · 3 usage. The
# ledger caches the list (cache.remote_ttl_minutes; scripts/ledger/
# adapters.sh _lg_remote_cache), so gh runs at most once per TTL.
#
# bash 3.2 + jq >= 1.6; awk: macOS awk (BWK) or any POSIX awk.
set -euo pipefail

usage() {
  echo "usage: ledger-items-gh.sh list [--since <timestamp>] | write <ref> <field> <value> | note <ref> <text> | create --title <title> --body-file <file>" >&2
  exit 3
}
die() {
  echo "ledger-items-gh: $*" >&2
  exit 2
}

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ledger"
LP=${LEDGER_GH_LEDGER_PREFIX:-ledger:}
SP=${LEDGER_GH_SEV_PREFIX:-sev:}
LIMIT=1000
FIELDS=number,title,body,state,stateReason,labels,updatedAt,url,closedAt
BOM=$'\357\273\277'
# The metadata block in a body (jq): blk → {pre, open, blk, close, post},
# or nothing. The block starts at the first line outside fenced code (```
# or ~~~, three or more, closed by the same character at least as long)
# that is "<!-- doc-superpowers-ledger" — a word: followed by a blank or
# the line's end — after at most three spaces; open is the marker and the
# blanks after it with its line break, blk the text up to the first "-->"
# after it, close that "-->", post the rest; pre the lines before.
# shellcheck disable=SC2016  # jq source
JQ_BLOCK='def blk:
  . as $b
  | if ($b | test("<!-- doc-superpowers-ledger") | not) then empty
    else ($b | split("\n")) as $L
    | (first(foreach range(0; $L | length) as $i ({f: null, s: null};
          ($L[$i] | sub("\r$"; "")) as $t
          | .f as $f
          | if $f != null then
              (if ($t | test("^ {0,3}" + $f.c + "{" + ($f.n | tostring) + ",}[ \t]*$")) then .f = null else . end) | .s = null
            elif ($t | test("^ {0,3}(```|~~~)")) then
              ($t | capture("^ {0,3}(?<c>`+|~+)(?<r>.*)$")) as $m
              | if ($m.c[0:1] == "`" and ($m.r | test("`"))) then .s = null
                else .f = {c: $m.c[0:1], n: ($m.c | length)} | .s = null end
            elif ($t | test("^ {0,3}<!-- doc-superpowers-ledger(?![^ \t])")) then .s = $i
            else .s = null end;
          if .s != null then .s else empty end)) // null) as $s
    | if $s == null then empty
      else ($L[$s:] | join("\n"))
        | capture("^(?<open> {0,3}<!-- doc-superpowers-ledger[ \t]*(\r?\n)?)(?<blk>[\\s\\S]*?)(?<close>-->)(?<post>[\\s\\S]*)")
        | {pre: (($L[0:$s] | join("\n")) + (if $s > 0 then "\n" else "" end)), open, blk, close, post}
      end
    end;
# openfence: the line that closes the fence the body ends inside (its
# character, as long a run as the opener), or "" when it ends outside one.
def openfence:
  reduce (split("\n")[] | sub("\r$"; "")) as $t (null;
    . as $f
    | if $f != null then
        (if ($t | test("^ {0,3}" + $f.c + "{" + ($f.n | tostring) + ",}[ \t]*$")) then null else $f end)
      elif ($t | test("^ {0,3}(```|~~~)")) then
        ($t | capture("^ {0,3}(?<c>`+|~+)(?<r>.*)$")) as $m
        | if ($m.c[0:1] == "`" and ($m.r | test("`"))) then null else {c: $m.c[0:1], n: ($m.c | length)} end
      else null end)
  | if . == null then "" else .c * .n end;'

# ref_num <ref>: the issue number of gh#<n> into N; usage (3) otherwise.
ref_num() {
  case "$1" in
    gh#[123456789]*) N=${1#gh#} ;;
    *) echo "ledger-items-gh: '$1' is not gh#<number>" >&2; exit 3 ;;
  esac
  case "$N" in *[!0123456789]*) echo "ledger-items-gh: '$1' is not gh#<number>" >&2; exit 3 ;; esac
}

need() {
  if ! command -v gh >/dev/null 2>&1; then
    die "gh (the GitHub CLI) is not on PATH — install it and run 'gh auth login'"
  fi
  command -v jq >/dev/null 2>&1 || die "jq is not on PATH"
}

TMPD=""
cleanup() { if [ -n "$TMPD" ]; then rm -rf "$TMPD"; fi; }
trap cleanup EXIT
tmpd() {
  TMPD=$(mktemp -d "${TMPDIR:-/tmp}/ledger-items-gh.XXXXXX") || die "mktemp failed"
}

# jq_err <file>: jq's error message without its prefix.
jq_err() {
  sed -n 's/^jq: error ([^)]*): //p; s/^jq: error: //p' "$1" | head -n 1
}

# --- list ---------------------------------------------------------------------

cmd_list() {
  local since="" json
  while [ $# -gt 0 ]; do
    case "$1" in
      --since) [ $# -ge 2 ] && [ -n "$2" ] || usage; since=$2; shift 2 ;;
      --since=?*) since=${1#--since=}; shift ;;
      *) usage ;;
    esac
  done
  need
  [ -f "$LIB/frontmatter.awk" ] || die "scripts/ledger/frontmatter.awk is not beside this adapter's directory ($LIB)"
  tmpd
  if ! json=$(gh issue list --state all --limit "$LIMIT" --json "$FIELDS" < /dev/null); then
    die "gh issue list failed (signed in? gh auth status)"
  fi
  printf '%s\n' "$json" > "$TMPD/gh.json" || die "cannot write $TMPD/gh.json"
  # Pass 1: the checks, --since, and each issue's text as frontmatter.awk
  # reads a blob — its metadata block as the frontmatter, then the body
  # outside it — in `git cat-file --batch` form (sizes in bytes; NUL bytes
  # as \001, as the ledger's own batch passes them).
  # shellcheck disable=SC2016  # jq source
  if ! jq -r --argjson limit "$LIMIT" --arg since "$since" "$JQ_BLOCK"'
      if type != "array" then error("gh issue list did not print a JSON list")
      elif length >= $limit then error("could not list completely: \(length) issues ≥ limit \($limit)")
      else .[] end
      | if (.number | type) != "number" or .number < 1 or (.number | floor) != .number then error("an issue without a number: \(tojson | .[0:200])") else . end
      | select($since == "" or ((.updatedAt // "") | tostring) >= $since)
      | ((.body // "") | if type == "string" then gsub("\u0000"; "\u0001") else "" end) as $b
      | (($b | blk) // {pre: $b, blk: "", post: ""}) as $m
      | ($m.blk | sub("\\r?\\n$"; "")) as $k
      | ("---\n" + (if $k == "" then "" else $k + "\n" end) + "---\n" + $m.pre + $m.post) as $doc
      | "\(.number) blob \($doc | utf8bytelength)\n\($doc)"' "$TMPD/gh.json" > "$TMPD/stream" 2> "$TMPD/jq.err"; then
    die "cannot use gh's issue list: $(jq_err "$TMPD/jq.err")"
  fi
  [ -s "$TMPD/stream" ] || return 0
  mkdir -p "$TMPD/rec" || die "cannot create $TMPD/rec"
  LC_ALL=C awk -v mode=batch -v outdir="$TMPD/rec" -v bom="$BOM" -f "$LIB/frontmatter.awk" < "$TMPD/stream" 2> "$TMPD/awk.err" \
    || die "cannot read the issues' metadata blocks: $(head -n 1 "$TMPD/awk.err")"
  # Pass 2: the records joined with the issues.
  # shellcheck disable=SC2016  # jq source
  if ! jq -c -n --arg lp "$LP" --arg sp "$SP" --slurpfile gh "$TMPD/gh.json" "$JQ_BLOCK"'
      def lbl($p): [.[] | select(startswith($p)) | .[($p | length):] | select(. != "")]
        | if length == 0 then null elif length == 1 then .[0] else sort end;
      (reduce inputs as $r ({}; .[input_filename | capture("b-(?<n>[0-9]+)\\.json$").n] = $r)) as $R
      | $gh[0][]
      | $R[.number | tostring] as $r
      | select($r != null)
      | [(.labels // [])[] | if type == "object" then .name else . end | strings] as $L
      | ($L | lbl($lp)) as $led
      | ($L | lbl($sp)) as $sev
      | ($r.fm // {}) as $fm
      # A closing "-->" not on a line of its own: read, and said.
      | ([(.body // "") | strings | gsub("\u0000"; "\u0001") | blk
          | select(.blk != "" and (.blk | test("\n$") | not))] | length > 0) as $mid
      | ((.state // "") | tostring | ascii_upcase) as $st
      | ((.stateReason // "") | tostring | ascii_upcase) as $why
      | (if $st == "CLOSED" then
           (if ($fm.superseded_by | . != null and . != "" and . != []) then "Closed"
            elif $why == "COMPLETED" then "Fixed"
            elif $why == "NOT_PLANNED" then "Won'"'"'t Fix"
            else "Closed" end)
         elif $st == "OPEN" then "Open"
         else error("issue #\(.number): state \(.state | tojson) is neither OPEN nor CLOSED") end) as $status
      | {ref: "gh#\(.number)", url: .url, title: .title,
         body_excerpt: ($r.first_para | if type == "string" then (if length > 280 then .[0:279] + "…" else . end) else null end),
         status: $status,
         fields: ($fm + (if $led != null then {ledger: $led} else {} end) + (if $sev != null then {severity: $sev} else {} end)),
         labels: $L, updated: .updatedAt,
         closed: (.closedAt | if type == "string" and . != "" then . else null end),
         fm_errors: (($r.fm_errors // [])
                     + (if $mid then ["metadata block: its closing --> is not on a line of its own"] else [] end))}' \
      "$TMPD"/rec/b-*.json 2> "$TMPD/jq.err"; then
    die "cannot use gh's issue list: $(jq_err "$TMPD/jq.err")"
  fi
}

# --- write --------------------------------------------------------------------

# gh_view <n> <fields> <out>: gh issue view's JSON into <out>.
gh_view() {
  gh issue view "$1" --json "$2" < /dev/null > "$3" || die "gh issue view $1 failed"
  jq -e 'type == "object"' "$3" > /dev/null 2>&1 || die "gh issue view $1 did not print a JSON object"
}

# write_label <n> <prefix> <value>
write_label() {
  local n="$1" p="$2" v="$3" new="" rm="" e
  gh_view "$n" labels "$TMPD/view.json"
  if [ -n "$v" ]; then new="$p$v"; fi
  # shellcheck disable=SC2016  # jq source
  rm=$(jq -r --arg p "$p" --arg new "$new" '[(.labels // [])[] | if type == "object" then .name else . end | strings
      | select(startswith($p) and . != $new)] | join(",")' "$TMPD/view.json") || die "cannot read the labels of #$n"
  if [ -n "$new" ] && jq -e --arg new "$new" 'any((.labels // [])[] | if type == "object" then .name else . end; . == $new)' \
      "$TMPD/view.json" > /dev/null; then
    new=""
  fi
  if [ -n "$new" ]; then
    if ! gh label create "$new" < /dev/null > /dev/null 2> "$TMPD/label.err"; then
      e=$(head -n 3 "$TMPD/label.err" | tr '\n' ' ')
      case "$e" in
        *"already exists"*) ;;
        *) printf '%s\n' "$e" >&2; die "gh label create $new failed" ;;
      esac
    fi
  fi
  set -- issue edit "$n"
  if [ -n "$rm" ]; then set -- "$@" --remove-label "$rm"; fi
  if [ -n "$new" ]; then set -- "$@" --add-label "$new"; fi
  [ "$#" -gt 3 ] || return 0
  gh "$@" < /dev/null > /dev/null || die "gh issue edit $n failed"
}

# write_block <n> <field> <value>: the metadata block's <field> line.
write_block() {
  local n="$1" f="$2" v="$3" eol=$'\n' has st op part fence
  gh_view "$n" body "$TMPD/view.json"
  jq -j '.body // "" | if type == "string" then . else "" end' "$TMPD/view.json" > "$TMPD/body" || die "cannot read the body of #$n"
  # shellcheck disable=SC2016  # jq source
  has=$(jq -r "$JQ_BLOCK"'[(.body // "") | strings | blk] | if length > 0 then "1" else "0" end' "$TMPD/view.json") \
    || die "cannot read the body of #$n"
  if grep -q $'\r$' "$TMPD/body" 2>/dev/null; then eol=$'\r\n'; fi
  if [ "$has" = 1 ]; then
    for part in pre open blk close post; do
      # shellcheck disable=SC2016  # jq source
      jq -j --arg p "$part" "$JQ_BLOCK"'.body | blk | .[$p]' "$TMPD/view.json" > "$TMPD/$part" || die "cannot split the body of #$n"
    done
  else
    : > "$TMPD/blk"
  fi
  # The block as a frontmatter (its own line ending), fm-write.awk's edit.
  case "$(cat "$TMPD/blk")" in *$'\r'*) eol=$'\r\n' ;; esac
  {
    printf -- '---%s' "$eol"
    if [ -s "$TMPD/blk" ]; then
      cat "$TMPD/blk"
      case "$(tail -c 1 "$TMPD/blk")" in '') ;; *) printf '%s' "$eol" ;; esac
    fi
    printf -- '---%s' "$eol"
  } > "$TMPD/fm" || die "cannot write $TMPD/fm"
  op="set"
  if [ -z "$v" ]; then op="del"; fi
  : > "$TMPD/st"
  env LG_FMW_NOPS=1 LG_FMW_1_OP="$op" LG_FMW_1_FIELD="$f" LG_FMW_1_VALUE="$v" LG_FMW_1_ITEMS="" LG_FMW_1_NITEMS=0 \
    LC_ALL=C awk -v status="$TMPD/st" -v bom="$BOM" -f "$LIB/fm-write.awk" < "$TMPD/fm" > "$TMPD/newfm" \
    || die "cannot edit the metadata block of #$n (fm-write.awk failed)"
  st=""
  IFS= read -r st < "$TMPD/st" || true
  case "$st" in
    unchanged) return 0 ;;
    "body "*) ;;
    *) die "cannot edit the metadata block of #$n (fm-write.awk: '$st')" ;;
  esac
  # The new block's lines (the frontmatter without its --- lines).
  sed '1d;$d' "$TMPD/newfm" > "$TMPD/newblk" || die "cannot write $TMPD/newblk"
  if [ "$has" = 1 ]; then
    case "$(tail -c 1 "$TMPD/open")" in '') ;; *) printf '%s' "$eol" >> "$TMPD/open" ;; esac
    cat "$TMPD/pre" "$TMPD/open" "$TMPD/newblk" "$TMPD/close" "$TMPD/post" > "$TMPD/newbody" || die "cannot write the new body"
  else
    # A body that ends inside an open fence gets its closing line first
    # (GitHub renders the fence closed there already), so the block is
    # outside it.
    fence=$(jq -r "$JQ_BLOCK"'(.body // "") | if type == "string" then openfence else "" end' "$TMPD/view.json") \
      || die "cannot read the body of #$n"
    if [ -n "$fence" ]; then
      case "$(tail -c 1 "$TMPD/body")" in '') fence="$fence$eol" ;; *) fence="$eol$fence$eol" ;; esac
      printf '%s' "$fence" >> "$TMPD/body" || die "cannot write the body"
    fi
    {
      cat "$TMPD/body"
      if [ -s "$TMPD/body" ]; then
        case "$(tail -c 1 "$TMPD/body")" in '') printf '%s' "$eol" ;; *) printf '%s%s' "$eol" "$eol" ;; esac
      fi
      printf '<!-- doc-superpowers-ledger%s' "$eol"
      cat "$TMPD/newblk"
      printf -- '-->%s' "$eol"
    } > "$TMPD/newbody" || die "cannot write the new body"
  fi
  if cmp -s "$TMPD/newbody" "$TMPD/body"; then return 0; fi
  gh issue edit "$n" --body-file "$TMPD/newbody" < /dev/null > /dev/null || die "gh issue edit $n failed"
}

cmd_write() {
  [ "$#" = 3 ] || usage
  ref_num "$1"
  case "$2" in
    ''|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-]*|[.-]*)
      echo "ledger-items-gh: '$2' is not a field name" >&2; exit 3 ;;
    status) echo "ledger-items-gh: status follows the issue's state (close or reopen it on GitHub)" >&2; exit 3 ;;
  esac
  case "$3" in
    *[$'\n\r']*) echo "ledger-items-gh: a value cannot hold a line break" >&2; exit 3 ;;
    *'-->'*|*'--!>'*) echo "ledger-items-gh: a value cannot hold '-->' or '--!>' (it would close the metadata comment)" >&2; exit 3 ;;
  esac
  case "$2:$3" in
    ledger:*,*|severity:*,*) echo "ledger-items-gh: a $2 value cannot hold a comma (gh joins labels with commas)" >&2; exit 3 ;;
  esac
  need
  [ -f "$LIB/fm-write.awk" ] || die "scripts/ledger/fm-write.awk is not beside this adapter's directory ($LIB)"
  tmpd
  case "$2" in
    ledger) write_label "$N" "$LP" "$3" ;;
    severity) write_label "$N" "$SP" "$3" ;;
    *) write_block "$N" "$2" "$3" ;;
  esac
}

# --- note, create -------------------------------------------------------------

cmd_note() {
  [ "$#" = 2 ] || usage
  ref_num "$1"
  need
  tmpd
  printf '%s' "$2" > "$TMPD/comment" || die "cannot write $TMPD/comment"
  gh issue comment "$N" --body-file "$TMPD/comment" < /dev/null > /dev/null || die "gh issue comment $N failed"
}

cmd_create() {
  local title="" file="" out url seen=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) [ $# -ge 2 ] || usage; title=$2; seen="${seen}t"; shift 2 ;;
      --body-file) [ $# -ge 2 ] || usage; file=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$seen" ] && [ -n "$title" ] && [ -n "$file" ] || usage
  [ -f "$file" ] || { echo "ledger-items-gh: no such file: $file" >&2; exit 3; }
  need
  out=$(gh issue create --title "$title" --body-file "$file" < /dev/null) || die "gh issue create failed"
  url=$(printf '%s\n' "$out" | grep -E '^https?://[^[:space:]]+/issues/[0-9]+$' | tail -n 1) || url=""
  [ -n "$url" ] || die "gh issue create printed no issue URL, but the issue may have been created — check before retrying. gh printed: $(printf '%s' "$out" | tr '\n' ' ' | cut -c 1-500)"
  jq -nc --arg u "$url" '{ref: "gh#\($u | capture("/issues/(?<n>[0-9]+)$").n)", url: $u}'
}

case "${1:-}" in
  list) shift; cmd_list "$@" ;;
  write) shift; cmd_write "$@" ;;
  note) shift; cmd_note "$@" ;;
  create) shift; cmd_create "$@" ;;
  *) usage ;;
esac
