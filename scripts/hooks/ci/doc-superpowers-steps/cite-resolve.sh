#!/usr/bin/env bash
# Recomputes the code cites of one doc whose merge conflicts differ only in
# cite line numbers (design 2026-11-18, R2–R4). index-resolve.sh runs it
# once per such doc, as "$(dirname "$0")/cite-resolve.sh".
#
# Usage:
#   cite-resolve.sh <doc> <head> <base> <merged-tree> <stage1> <stage2> <stage3>
#     <doc>          the doc's path in the repository (docs/a.md)
#     <head>         the pull request's head commit
#     <base>         the base branch's commit
#     <merged-tree>  the merge's tree (git merge-tree --write-tree's first
#                    line): its code files are the merged code
#     <stage1..3>    the doc's blobs at the merge base, the head and the base
#                    branch, as git merge-tree prints them
# It runs in a git repository that holds all of these objects. It runs no
# hook, filter or file of the repository.
#
# Output:
#   exit 0  stdout: the doc, merged, each conflict block replaced by the
#           head's side with its cites recomputed. stderr: one line, the
#           number of cites recomputed.
#   exit 1  a refusal. stdout: nothing. stderr: one line, a Markdown sentence
#           naming the doc and the line (the block's line in the head's
#           version).
#   exit 2  could not run (a missing object, a git or jq failure). stderr:
#           one line starting "cite-resolve.sh: cannot run:".
#   exit 3  a usage error. stderr: one line starting "cite-resolve.sh:".
#
# What it does:
#   1. The blocks are those of `git merge-file -p --diff3` on the three blobs
#      (head = ours, merge base = base, base branch = theirs).
#   2. In each block the two sides must be equal once each cite's numbers
#      are replaced by a placeholder. A digit anywhere else is text.
#   3. Each cite of each side names lines in that side's tree. Those lines
#      are searched for in the merged file. A unique match is the new range.
#      Several matches widen the search by one line of the side's context
#      above and below, up to five. Both sides must land on the same range.
#      The block is rewritten as the head's side with the new numbers.
#   4. Every cite outside the blocks must be anchored: the head's or the base
#      branch's doc holds the same line, and the lines it names are equal in
#      that side's tree and in the merged tree. A continuation with no path in
#      its paragraph names no code there: it is text.
#
# The cite grammar (R2):
#   full          a path-like token with a file extension, then :N or :N-M
#                 (src/app/server.py:12-14, app.py:12)
#   list item     , N or , N-M straight after a cite or another list item in
#                 the same code span (`a.py:12-14, 20`)
#   continuation  a bare :N or :N-M after a backtick, space, comma or (
#                 (`a.py:12`, `:20`). It takes the nearest path-like token
#                 before it: on its line, then on earlier lines up to a blank
#                 line or a heading.
#   A path resolves as written, then relative to the doc's directory, then as
#   the one tracked file ending in /<path>. In a block it must resolve to the
#   same file in the head's, the base branch's and the merged tree. A URL
#   (scheme://…) holds no cite.
#
# Needs bash 3.2+, jq 1.6+ and git 2.40+.
set -euo pipefail

usage() {
  echo "cite-resolve.sh: $*" >&2
  exit 3
}
cannot_run() {
  echo "cite-resolve.sh: cannot run: $*" >&2
  exit 2
}

[ $# -eq 7 ] || usage "expected 7 arguments (<doc> <head> <base> <merged-tree> <stage1> <stage2> <stage3>), got $#"
DOC=$1 HEAD_C=$2 BASE_C=$3 MERGED=$4 S1=$5 S2=$6 S3=$7
for a in "$@"; do
  [ -n "$a" ] || usage "an argument is empty"
done

command -v jq >/dev/null 2>&1 || cannot_run "no jq on PATH"
git rev-parse --git-dir >/dev/null 2>&1 || cannot_run "not in a git repository"
git rev-parse -q --verify "$HEAD_C^{commit}" >/dev/null || cannot_run "the head $HEAD_C is not a commit here"
git rev-parse -q --verify "$BASE_C^{commit}" >/dev/null || cannot_run "the base $BASE_C is not a commit here"
git rev-parse -q --verify "$MERGED^{tree}" >/dev/null || cannot_run "the merged tree $MERGED is not a tree here"
for b in "$S1" "$S2" "$S3"; do
  git rev-parse -q --verify "$b^{blob}" >/dev/null || cannot_run "the doc's blob $b is not a blob here"
done

T=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cite-resolve.XXXXXX") || cannot_run "cannot create a scratch directory"
trap 'rm -rf "$T"' EXIT

git cat-file blob "$S1" > "$T/base.md" || cannot_run "cannot read $S1"
git cat-file blob "$S2" > "$T/head.md" || cannot_run "cannot read $S2"
git cat-file blob "$S3" > "$T/theirs.md" || cannot_run "cannot read $S3"

# The blocks. Markers of 32 characters, so a Markdown line such as a setext
# underline (=======) is never read as one. merge-file exits with the number
# of conflicts (0 to 127), or above 127 on an error.
MS=32
rc=0
git merge-file -p --diff3 --marker-size=$MS -L head -L base -L theirs \
  "$T/head.md" "$T/base.md" "$T/theirs.md" > "$T/d3" 2>/dev/null || rc=$?
[ "$rc" -le 127 ] || cannot_run "git merge-file failed ($rc)"
# The head's view: the merge with each block resolved to the head's side.
# Its diff against the head's doc maps a line of the merge to the head's line.
rc=0
git merge-file -p --diff3 --ours "$T/head.md" "$T/base.md" "$T/theirs.md" > "$T/ours" 2>/dev/null || rc=$?
[ "$rc" -le 127 ] || cannot_run "git merge-file --ours failed ($rc)"
rc=0
git diff --no-index --no-color --no-ext-diff --no-textconv -U0 --inter-hunk-context=0 "$T/head.md" "$T/ours" > "$T/hunks" 2>/dev/null || rc=$?
[ "$rc" -le 1 ] || cannot_run "git diff --no-index failed ($rc)"

# The tracked files of the three trees, NUL-separated "mode type oid<TAB>path".
git ls-tree -r -z "$HEAD_C" > "$T/ls-H" || cannot_run "cannot list $HEAD_C"
git ls-tree -r -z "$BASE_C" > "$T/ls-B" || cannot_run "cannot list $BASE_C"
git ls-tree -r -z "$MERGED" > "$T/ls-M" || cannot_run "cannot list $MERGED"

m() { printf "%${MS}s" "" | tr ' ' "$1"; }
: > "$T/blobs"

# The jq program: the grammar, the blocks, the search and the anchor check.
# Mode need prints the blob ids of every cited file in the three trees; mode
# run prints {ok, doc, count} or {ok: false, reason}. jq 1.6: no string
# offsets are used (1.6 counts them in bytes), only split, match and slices.
cat > "$T/cite.jq" <<'JQ'
def lines: split("\n") | if length > 0 and .[-1] == "" then .[:-1] else . end;

# One tree: {set: {path: oid}, byname: {basename: [path]}}, blobs only.
def tree($txt):
  [$txt | split("\u0000")[] | select(length > 0) | split("\t") as $f
   | ($f[0] | split(" ")) as $m | select($m[1] == "blob")
   | {p: ($f[1:] | join("\t")), o: $m[2]}]
  | {set: (reduce .[] as $e ({}; .[$e.p] = $e.o)),
     byname: (reduce .[] as $e ({}; .[$e.p | split("/") | last] += [$e.p]))};

# A path without . and .. parts; null when .. climbs out of the root.
def norm:
  reduce (split("/")[]) as $p ([];
    if . == null then null
    elif $p == "" or $p == "." then .
    elif $p == ".." then (if length > 0 then .[:-1] else null end)
    else . + [$p] end)
  | if . == null or length == 0 then null else join("/") end;

# The file a path token names in tree $t, or null.
def resolve($tok; $t):
  ($tok | norm) as $w
  | (($doc | split("/") | .[:-1] | join("/")) + "/" + $tok | norm) as $r
  | if $w != null and $t.set[$w] != null then $w
    elif $r != null and $t.set[$r] != null then $r
    else [($t.byname[$tok | split("/") | last] // [])[] | select(endswith("/" + $tok))]
      | if length == 1 then .[0] else null end
    end;

# The tokens of one line, which joined give the line back. A cite is
# {kind: "cite", sub: full|list|cont, pre, n, m, ptok}: pre is the text before
# its numbers, m is null for :N, ptok is the full cite's path (list items and
# continuations get theirs from annotate).
def toks:
  [match("(?<url>[A-Za-z][A-Za-z0-9+.-]*://[^\\s`<>()\\[\\]]*)"
       + "|(?<full>(?<fp>[A-Za-z0-9_.@+/-]*[A-Za-z0-9_@+-]\\.[A-Za-z][A-Za-z0-9]*):(?<fn>[0-9]+)(?:-(?<fm>[0-9]+))?)"
       + "|(?<path>[A-Za-z0-9_.@+/-]*[A-Za-z0-9_@+-]\\.[A-Za-z][A-Za-z0-9]*)"
       + "|(?<word>[A-Za-z0-9_.@+/-]+)"
       + "|(?<cont>:(?<cn>[0-9]+)(?:-(?<cm>[0-9]+))?)"
       + "|(?<list>,(?<ls> *)(?<ln>[0-9]+)(?:-(?<lm>[0-9]+))?)"
       + "|(?<tick>`)"
       + "|(?<other>[^A-Za-z0-9_.@+/:,`-]+|.)"; "g")
   | {s: .string, c: (.captures | map(select(.string != null) | {key: .name, value: .string}) | from_entries)}]
  | reduce .[] as $t ({out: [], code: false, prev: null};
      (.prev // {s: "", kind: "text"}) as $p
      | ($t.c | if .full then {kind: "cite", sub: "full", pre: (.fp + ":"), n: .fn, m: .fm, ptok: .fp}
                elif .cont and ($p.s[($p.s | length) - 1:] | . == "`" or . == " " or . == "," or . == "(")
                  then {kind: "cite", sub: "cont", pre: ":", n: .cn, m: .cm}
                elif .list and $p.kind == "cite" then {kind: "cite", sub: "list", pre: ("," + .ls), n: .ln, m: .lm}
                elif .path then {kind: "path", ptok: $t.s}
                elif .tick then {kind: "tick"}
                else {kind: "text"} end) as $k
      # A list item belongs to the code span of the cite before it.
      | (if $k.sub == "list" and (.code | not) then {kind: "text"} else $k end) as $k
      | ($k + {s: $t.s}
         | if .kind == "cite" then .n |= tonumber | .m |= (if . == null then null else tonumber end) else . end) as $tok
      | .out += [$tok] | .prev = $tok
      | if $tok.kind == "tick" then .code = (.code | not) else . end)
  | .out;

def barrier: test("^\\s*$") or test("^ {0,3}#{1,6}(\\s|$)");
def lastpath: [.[] | select(.kind == "path" or .sub == "full") | .ptok] | last;
def up($V; $L; $k):
  if $k < 0 or ($L[$k] | barrier) then null else (($V[$k] | lastpath) // up($V; $L; $k - 1)) end;

# Tokens of lines $L, each list item and continuation given the nearest path
# token before it (ptok null: none in its paragraph).
def annotate($L):
  [$L[] | toks] as $V
  | [range(0; $V | length) as $i
     | [range(0; $V[$i] | length) as $j | $V[$i][$j]
        | if .kind == "cite" and .sub != "full"
          then .ptok = (($V[$i][:$j] | lastpath) // up($V; $L; $i - 1)) else . end]];

def cites: map(select(.kind == "cite"));
def nums: if .m == null then "\(.n)" else "\(.n)-\(.m)" end;
def span: if .[0] == .[1] then "line \(.[0])" else "lines \(.[0])-\(.[1])" end;
def shown: if .ptok == null then .s else "\(.ptok):\(nums)" end;
def refuse($msg): error({reason: "In `\($doc)`, \($msg)."});

# The blocks of the diff3 text, and the views of the head (o) and of the base
# branch (t): the lines outside the blocks plus that side's lines.
def merged:
  ($mo + " ") as $mo | ($mb + " ") as $mb | ($mt + " ") as $mt
  | reduce ($d3 | split("\n"))[] as $l ({o: [], t: [], blocks: [], st: "out", cur: null};
      if .st == "out" then
        if ($l | startswith($mo)) then .st = "ours" | .cur = {ours: [], theirs: []}
        else .o += [$l] | .t += [$l] end
      elif .st == "ours" then (if ($l | startswith($mb)) then .st = "base" else .cur.ours += [$l] end)
      elif .st == "base" then (if $l == $me then .st = "theirs" else . end)
      elif ($l | startswith($mt)) then
        .blocks += [.cur + {os: (.o | length), ts: (.t | length)}]
        | .o += .cur.ours | .t += .cur.theirs | .st = "out" | .cur = null
      else .cur.theirs += [$l] end)
  | if .st != "out" then refuse("git merge-file left a conflict block unclosed") else . end;

def main:
{H: tree($lsH), B: tree($lsB), M: tree($lsM)} as $TR
| merged as $mg
| ($mg.o | annotate(.)) as $OV
| ($mg.t | annotate(.)) as $TV
# Each path token's file in each tree.
| ([$OV[], $TV[] | .[] | .ptok // empty] | unique
   | map({key: ., value: {H: resolve(.; $TR.H), B: resolve(.; $TR.B), M: resolve(.; $TR.M)}}) | from_entries) as $R
| if $mode == "need" then
    {ok: true, oids: ([$R[] | to_entries[] | select(.value != null) | $TR[.key].set[.value]] | unique)}
  else
  (reduce $blobs[] as $b ({}; .[$b.o] = ($b.c | lines))) as $F
  | def file($tree; $path): $F[$TR[$tree].set[$path]];
    # The head's line of line $l (1-based) of the merge, or null when the
    # head does not hold it ($hunks: git diff -U0 of the head's doc to the
    # head's view).
    def headline($l):
      [$hunks | split("\n")[]
       | select(startswith("@@ "))
       | capture("^@@ -(?<a>[0-9]+)(,(?<b>[0-9]+))? \\+(?<c>[0-9]+)(,(?<d>[0-9]+))? @@")
       | {b: ((.b // "1") | tonumber), c: (.c | tonumber), d: ((.d // "1") | tonumber)}]
      | reduce .[] as $h ({d: 0, r: null};
          if .r != null then .
          else (if $h.d > 0 then $h.c else $h.c + 1 end) as $ns
            | if $l < $ns then .r = $l - .d
              elif $l < $ns + $h.d then .r = -1
              else .d += $h.d - $h.b end
          end)
      | if .r == null then $l - .d elif .r < 0 then null else .r end;
    def where($l): (headline($l)) as $h
      | if $h != null then "line \($h) of the head's version" else "line \($l) of the merged doc" end;
    # The merged range [p, q] of cite $c, read in tree $tree.
    def land($c; $tree; $side; $at):
      ($R[$c.ptok // ""] // {}) as $res
      | if $c.ptok == null or $res.H == null or $res.H != $res.B or $res.H != $res.M then
          refuse("the block at \($at) cites `\($c | shown)`, whose path does not resolve to one file in the head's, the base branch's and the merged tree")
        else . end
      | file($tree; $res.H) as $S | file("M"; $res.M) as $Mf
      | ($c.m // $c.n) as $m | ($m - $c.n + 1) as $len
      | if $c.n < 1 or $len < 1 then
          refuse("the block at \($at) cites `\($c | shown)`, an invalid range (lines start at 1, and a range ends at or after its start)")
        elif $m > ($S | length) then
          refuse("the block at \($at) cites `\($c | shown)` past the end of the file in the \($side) tree")
        else . end
      | $S[$c.n - 1:$m] as $want
      | def at($a; $i): if $i < 0 then null else $a[$i] end;
        [range(0; ($Mf | length) - $len + 1) as $p | select($Mf[$p] == $want[0] and $Mf[$p:$p + $len] == $want) | $p] as $c0
      | if ($c0 | length) == 0 then
          refuse("the block at \($at) cites `\($c | shown)`, whose lines in the \($side) tree are not in the merged file")
        else . end
      | (reduce range(1; 6) as $k ($c0;
          if length <= 1 then .
          else map(. as $p | select(all(range(1; $k + 1);
                 . as $e | at($S; $c.n - 1 - $e) == at($Mf; $p - $e) and at($S; $m - 1 + $e) == at($Mf; $p + $len - 1 + $e))))
          end)) as $cs
      | if ($cs | length) == 0 then
          refuse("the block at \($at) cites `\($c | shown)`, whose lines in the \($side) tree match no merged lines with the same context")
        elif ($cs | length) > 1 then
          refuse("the block at \($at) cites `\($c | shown)`, whose lines match more than once in the merged file, even with five lines of context")
        else [$cs[0] + 1, $cs[0] + $len] end;
    # Each block's head lines, rewritten.
    ([$mg.blocks[] as $b
      | where($b.os + 1) as $at
      | if ($b.ours | length) != ($b.theirs | length) then refuse("the block at \($at) differs in more than cite numbers") else . end
      | range(0; $b.ours | length) as $k
      | $OV[$b.os + $k] as $ho | $TV[$b.ts + $k] as $th
      | def ph: map(if .kind == "cite" then .pre + "#" else .s end) | join("");
        if ($ho | ph) != ($th | ph) or ($ho | cites | length) != ($th | cites | length) then
          refuse("the block at \($at) differs in more than cite numbers")
        else . end
      | [range(0; $ho | cites | length) as $i
         | ($ho | cites)[$i] as $hc | ($th | cites)[$i] as $tc
         | land($hc; "H"; "head's"; $at) as $hr | land($tc; "B"; "base branch's"; $at) as $tr
         | if $hr != $tr then
             refuse("the block at \($at) cites `\($hc | shown)`, and the two sides land on different lines of the merged file (\($hr | span) and \($tr | span))")
           else $hr end] as $new
      | {i: ($b.os + $k), n: ($new | length),
         s: (reduce $ho[] as $t ({s: "", i: 0};
               if $t.kind == "cite" then .s += $t.pre + ($t + {n: $new[.i][0], m: (if $t.m == null then null else $new[.i][1] end)} | nums) | .i += 1
               else .s += $t.s end) | .s)}]) as $rw
  | (reduce $rw[] as $r ($mg.o; .[$r.i] = $r.s)) as $W
  | (reduce $rw[] as $r ({}; .["\($r.i)"] = true)) as $inblock
  # R4: every cite outside the blocks is anchored. A continuation with no path
  # in its paragraph (prose such as "on :8090") names no code: it is text.
  | (reduce ($A | lines[]) as $l ({}; .[$l] = true)) as $Aset
  | (reduce ($Th | lines[]) as $l ({}; .[$l] = true)) as $Tset
  | ($W | annotate(.)) as $WV
  | ([range(0; $W | length) as $i | select($inblock["\($i)"] | not)
      | $WV[$i] | cites[] | select(.ptok != null) as $c | $R[$c.ptok] as $res
      | select(any(["H", $Aset], ["B", $Tset];
          .[0] as $tree | .[1][$W[$i]] == true
          and $res[$tree] != null and $res[$tree] == $res.M
          and (file($tree; $res[$tree]) as $S | file("M"; $res.M) as $Mf | ($c.m // $c.n) as $m
               | $c.n >= 1 and $m >= $c.n and $m <= ($S | length) and $m <= ($Mf | length)
               and $S[$c.n - 1:$m] == $Mf[$c.n - 1:$m])) | not)
      | {i: $i, c: $c}] | first) as $bad
  | if $bad != null then
      refuse("the cite `\($bad.c | shown)` at \(where($bad.i + 1)) is not anchored: no side holds that line naming the same code as the merged tree")
    else . end
  | {ok: true, doc: ($W | join("\n")), count: ([$rw[].n] | add // 0)}
  end;

# A refusal is the value {ok: false, reason}; any other error stays an error.
try main catch (if type == "object" and has("reason") then {ok: false, reason: .reason} else error end)
JQ

# run_jq <mode> <out>: the program on the gathered files, its JSON in <out>.
run_jq() {
  jq -n -c --arg mode "$1" --arg doc "$DOC" --arg mo "$(m '<')" --arg mb "$(m '|')" --arg me "$(m '=')" \
    --arg mt "$(m '>')" --rawfile d3 "$T/d3" --rawfile hunks "$T/hunks" --rawfile A "$T/head.md" \
    --rawfile Th "$T/theirs.md" --rawfile lsH "$T/ls-H" --rawfile lsB "$T/ls-B" --rawfile lsM "$T/ls-M" \
    --slurpfile blobs "$T/blobs" -f "$T/cite.jq" > "$2" 2> "$T/jq.err" \
    || cannot_run "jq failed: $(head -n 1 "$T/jq.err")"
}

# refused <json>: a refusal's reason on stderr, exit 1.
refused() {
  if [ "$(jq -r '.ok' "$1")" != true ]; then
    jq -r '.reason' "$1" >&2
    exit 1
  fi
}

# The cited files' blobs, one JSON object {o, c} per line.
run_jq need "$T/need.json"
refused "$T/need.json"
jq -r '.oids[]' "$T/need.json" > "$T/need"
while IFS= read -r oid; do
  git cat-file blob "$oid" > "$T/blob" || cannot_run "cannot read blob $oid"
  jq -R -s -c --arg o "$oid" '{o: $o, c: .}' "$T/blob" >> "$T/blobs" || cannot_run "jq failed on blob $oid"
done < "$T/need"

run_jq run "$T/out.json"
refused "$T/out.json"
# The doc and the count go to files first: a late failure prints nothing.
jq -j '.doc' "$T/out.json" > "$T/doc.out" || cannot_run "cannot write the doc"
jq -r '.count' "$T/out.json" > "$T/count.out" || cannot_run "cannot write the count"
cat "$T/doc.out"
cat "$T/count.out" >&2
