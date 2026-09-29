#!/usr/bin/env bash
# doc-superpowers: git merge driver for docs/.doc-index.json
#
# Git calls: merge-doc-index.sh %O %A %B
#   %O = the common ancestor (base); empty when both sides added the file
#   %A = ours; also the OUTPUT: the merge result is written here
#   %B = theirs
# Git runs it for merge, rebase, cherry-pick and revert alike; in a rebase
# "ours" is the branch being rebased onto, "theirs" the commit replayed.
#
# Exit 0: a clean merge was written to %A. Exit 1: a conflict. %A then holds
# conflict markers (`git merge-file -L ours -L base -L theirs`) so the index is
# left unmerged and visibly so, never silently ours-only.
#
# A THREE-WAY merge, per docs key, with b/o/t = base/ours/theirs (absent = no
# entry):
#   o == t  -> o          (both sides agree, or neither changed it)
#   o == b  -> t          (only theirs changed it: taken, deletions included)
#   t == b  -> o          (only ours changed it)
#   otherwise, both changed it:
#     - one side deleted the entry, the other changed it -> conflict (exit 1)
#     - both kept it -> merged field by field, the same rule per field: the
#       side that changed a field wins. When both changed a field to
#       different values, last_verified decides: the entry whose
#       last_verified is newer wins it (a non-null value beats null). When
#       last_verified does not order the sides (equal, or both null) nothing
#       decides, and the merge is a conflict (exit 1) naming the key and
#       field. That is not a rare same-second case: only update-index writes
#       last_verified, so two set-code-refs, deprecate-entry --superseded-by,
#       move-entry repoints or hand edits of one field always tie.
#       (set-implementation edits a doc, never the index.) Two refinements:
#       * the verification record (content_hash, code_oids, code_commit,
#         last_verified) is ONE field: update-index writes it as a unit, and a
#         doc hash from one side beside code ids from the other would attest a
#         doc/code pair nobody verified. Two different records with the same
#         last_verified are a conflict; two equal ones are not;
#       * deprecated wins: a status both sides changed resolves to
#         "deprecated" if either side has it, and superseded_by (when both
#         changed it) goes with the status the merge kept — so a revert that
#         removes a deprecation still removes it. When both sides have the same
#         status, superseded_by follows the last_verified rule above.
# Before comparing, a stored status "current"/"stale" (legacy: status is
# derived now; only "deprecated" is stored) reads as absent, so it is never a
# conflict; an entry merged field by field is written without it, the way any
# doc-tools write drops it.
#
# The top level starts from ours: every field survives (schema_version or a
# legacy version, build_commit, generated_at, unknown fields); a field only
# theirs changed is taken from theirs, and when both changed it ours wins
# (generated_at always differs: it is write-time metadata, not content). Key
# order is ours' — in .docs and in each entry — with theirs-only keys
# appended, so a merge is not a whole-file reorder.
#
# Any input that is not exactly one JSON object whose .docs is an object
# (0 bytes, `null`, `{}`, two documents, invalid JSON) is a conflict, not an
# empty index. So is an INT/TERM/HUP: %A is restored from ours and given
# markers, never left half-written. Needs bash 3.2+, git and jq >= 1.6.
#
# No lock: the doc-tools index lock guards docs/.doc-index.json in the working
# tree. This driver never touches that file; it writes only %A, a temporary
# file git created for this merge and reads back once the driver exits. Git
# writes the result into the working tree itself, under its own index lock.

set -u

if [ $# -ne 3 ]; then
  echo "usage: merge-doc-index.sh <base %O> <ours %A> <theirs %B>" >&2
  exit 2
fi
BASE="$1"
OURS="$2"
THEIRS="$3"

KEEP=""
OUT=""
ERR=""
EMPTY=""
# shellcheck disable=SC2329  # run by the EXIT trap
cleanup() {
  local f
  for f in "$KEEP" "$OUT" "$ERR" "$EMPTY"; do
    [ -n "$f" ] && rm -f "$f"
  done
  return 0
}
trap cleanup EXIT
# A signal is a conflict like any other failure: conflict() restores %A from
# the pristine copy of ours and writes markers. (bash runs the trap once the
# foreground command in progress returns, so a signal landing mid-write still
# ends with %A rebuilt, never half-written.) Defined below; set here so no
# window exists before it.
# shellcheck disable=SC2329  # run by the INT/TERM/HUP traps
on_signal() { conflict "interrupted by a signal; the merge result was not kept"; }
trap on_signal INT TERM HUP

# Scratch files live in TMPDIR, never beside %A: %A sits in the work tree's
# top directory, and a scratch file left there would show up as untracked.
tmpfile() { mktemp "${TMPDIR:-/tmp}/merge-doc-index.XXXXXX"; }

# Print $1, then a newline if it does not already end in one.
cat_nl() {
  cat "$1"
  if [ -s "$1" ] && [ -n "$(tail -c 1 "$1")" ]; then echo; fi
}

# Leave %A as conflict markers and exit 1. `git merge-file` merges line by
# line; when that happens to be clean (a side that only APPENDED a second
# document merges without overlap), the merge is redone against an empty base
# so the two sides conflict as a whole. Should merge-file itself fail (e.g. a
# binary side), whole-file markers are written directly.
conflict() {
  # Writing the markers must not itself be interrupted half-way.
  trap '' INT TERM HUP
  printf '%s\n' "$1" | sed -e 's/^/merge-doc-index: /' >&2
  echo "merge-doc-index: leaving conflict markers in the index; resolve them, then re-run doc-tools.sh update-index for the docs involved" >&2
  if [ -n "$KEEP" ]; then
    cp "$KEEP" "$OURS" 2>/dev/null || true
  fi
  local rc=0
  git merge-file -L ours -L base -L theirs "$OURS" "$BASE" "$THEIRS" 2>/dev/null || rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$KEEP" ]; then
    cp "$KEEP" "$OURS" 2>/dev/null || true
    EMPTY=$(tmpfile) || EMPTY=""
    if [ -n "$EMPTY" ]; then
      git merge-file -L ours -L base -L theirs "$OURS" "$EMPTY" "$THEIRS" 2>/dev/null || rc=$?
    fi
  fi
  if [ "$rc" -eq 0 ] || [ "$rc" -gt 127 ]; then
    if [ -n "$KEEP" ]; then
      {
        echo "<<<<<<< ours"
        cat_nl "$KEEP"
        echo "======="
        cat_nl "$THEIRS"
        echo ">>>>>>> theirs"
      } > "$OURS" 2>/dev/null || true
    fi
  fi
  exit 1
}

# Exactly one JSON value, an object whose .docs is an object.
is_index() {
  jq -e -s 'length==1 and (.[0].docs|type=="object")' "$1" > /dev/null 2>&1
}

for f in "$BASE" "$OURS" "$THEIRS"; do
  if [ ! -f "$f" ]; then
    echo "merge-doc-index: missing input file: $f" >&2
    exit 1
  fi
done

# A pristine copy of ours: conflict() rebuilds %A from it.
KEEP=$(tmpfile) || KEEP=""
if [ -z "$KEEP" ] || ! cp "$OURS" "$KEEP"; then
  # Never restore %A from a partial copy: markers go on the original instead.
  [ -n "$KEEP" ] && rm -f "$KEEP"
  KEEP=""
  conflict "cannot create a scratch file"
fi

command -v jq > /dev/null 2>&1 || conflict "jq is not installed (the index merge needs jq >= 1.6)"
is_index "$OURS" || conflict "ours (%A) is not a doc index: not exactly one JSON object with a .docs object"
is_index "$THEIRS" || conflict "theirs (%B) is not a doc index: not exactly one JSON object with a .docs object"
# An empty (or blank) base is the add/add case: no ancestor. Anything else
# must be an index too — a corrupt ancestor is not an empty one.
if ! jq -e -s 'length == 0' "$BASE" > /dev/null 2>&1; then
  is_index "$BASE" || conflict "base (%O) is not a doc index: not exactly one JSON object with a .docs object"
fi

# shellcheck disable=SC2016  # jq program, not shell expansion
PROGRAM='
# A value wrapped so "absent" ([]) and "null" ([null]) stay distinct.
def w($o; $k): if ($o | type) == "object" and ($o | has($k)) then [$o[$k]] else [] end;
# $o keys in $o order, then the keys only $t has, in $t order.
def ukeys($o; $t): ($o | keys_unsorted) + [($t | keys_unsorted)[] | select(. as $k | $o | has($k) | not)];
# The three-way pick on wrapped values; null when both changed it differently.
def pick3($b; $o; $t): if $o == $t then $o elif $o == $b then $t elif $t == $b then $o else null end;
# A stored "current"/"stale" is legacy (status is derived): it reads as absent.
def norm: if type == "object" and (.status == "current" or .status == "stale") then del(.status) else . end;
# Which side last_verified says is newer: "t" or "o"; null when it does not
# order them (equal, or both null). A non-null value beats null.
def order($o; $t):
  ($o.last_verified) as $x | ($t.last_verified) as $y
  | if $x == $y then null
    elif $y == null then "o" elif $x == null then "t"
    elif $y > $x then "t" else "o" end;
# The verification record, compared and taken as one unit.
def VERIFY: {content_hash: 0, code_oids: 1, code_commit: 2, last_verified: 3};
def vrec($e): [w($e; "content_hash"), w($e; "code_oids"), w($e; "code_commit"), w($e; "last_verified")];

# Returns {e: merged entry, c: [fields nothing decides]}.
def merge_fields($b; $o; $t):
  order($o; $t) as $ord
  # A field both sides changed to different values: the newer side, or null.
  | def newer($x; $y): if $ord == "t" then $y elif $ord == "o" then $x else null end;
  (pick3(vrec($b); vrec($o); vrec($t)) // newer(vrec($o); vrec($t))) as $ver
  | w($o; "status") as $so | w($t; "status") as $st
  | (pick3(w($b; "status"); $so; $st)
     // (if $so == ["deprecated"] or $st == ["deprecated"] then ["deprecated"]
         else newer($so; $st) end)) as $status
  | (pick3(w($b; "superseded_by"); w($o; "superseded_by"); w($t; "superseded_by"))
     // (if $status != null and $so != $st
         then (if $status == $so then w($o; "superseded_by") else w($t; "superseded_by") end)
         else newer(w($o; "superseded_by"); w($t; "superseded_by")) end)) as $sup
  | reduce ukeys($o; $t)[] as $f ({e: {}, c: []};
      (VERIFY | .[$f]) as $vi
      | (if $f == "status" then $status
         elif $f == "superseded_by" then $sup
         elif $vi != null then (if $ver == null then [] else $ver[$vi] end)
         else (pick3(w($b; $f); w($o; $f); w($t; $f)) // newer(w($o; $f); w($t; $f)))
         end) as $v
      | if $v == null then .c += [$f]
        elif $v == [] then .
        else .e += {($f): $v[0]} end)
  | if $ver == null
    then .c += ["the verification record (content_hash, code_oids, code_commit, last_verified)"]
    else . end;

# One docs key. Wrapped entries in, {v: wrapped result} or {c: why} out.
def merge_entry($b; $o; $t):
  ($b | map(norm)) as $nb | ($o | map(norm)) as $no | ($t | map(norm)) as $nt
  | if $no == $nt then {v: $o}
    elif $no == $nb then {v: $t}
    elif $nt == $nb then {v: $o}
    elif $o == [] or $t == [] then {c: "deleted on one side, changed on the other"}
    elif ([$nb[], $no[], $nt[]] | all(type == "object"))
      then merge_fields($nb[0] // {}; $no[0]; $nt[0]) as $m
        | if ($m.c | length) > 0
          then {c: "both sides changed \($m.c | join(", ")), and last_verified does not say which is newer"}
          else {v: [$m.e]} end
    else {c: "not an object on every side"} end;

($B[0] // {}) as $base | $O[0] as $ours | $T[0] as $theirs
| ($base.docs // {}) as $bd | $ours.docs as $od | $theirs.docs as $td
| [ukeys($od; $td)[] as $k | merge_entry(w($bd; $k); w($od; $k); w($td; $k)) + {k: $k}] as $rows
| [$rows[] | select(.c) | "\(.k): \(.c)"] as $conflicts
| if ($conflicts | length) > 0 then error($conflicts | join("\n")) else . end
| (reduce ($rows[] | select(.v != [])) as $r ({}; . + {($r.k): $r.v[0]})) as $docs
| reduce ukeys($ours; $theirs)[] as $k ({};
    if $k == "docs" then . + {docs: $docs}
    else (pick3(w($base; $k); w($ours; $k); w($theirs; $k)) // w($ours; $k)) as $v
      | if $v == [] then . else . + {($k): $v[0]} end
    end)
'

OUT=$(tmpfile) || conflict "cannot create a scratch file"
ERR=$(tmpfile) || conflict "cannot create a scratch file"
if ! jq -n --slurpfile B "$BASE" --slurpfile O "$OURS" --slurpfile T "$THEIRS" "$PROGRAM" > "$OUT" 2> "$ERR"; then
  conflict "$(sed -e 's/^jq: error[^:]*: //' "$ERR" 2>/dev/null || echo "jq failed")"
fi
cat "$OUT" > "$OURS" || conflict "cannot write the result to $OURS"
exit 0
