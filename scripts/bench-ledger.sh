#!/usr/bin/env bash
# scripts/bench-ledger.sh — the work ledger's performance check.
#
#   bench-ledger.sh [--scale K] [--history-commits C] [--keep] <N>
#
# Builds two synthetic repositories of N items each (deterministic: a fixed
# seed and a Park–Miller generator, so every awk draws the same corpus;
# written with `git fast-import`) and times the ledger verbs against the
# Global Constraints budgets (bash 3.2 + jq, 3,000 items, no network):
#
#   corpus     N items over ~N/15 commits, 6 ledgers, a registry, a doc-index
#              of N/15 specs and plans linking items, N/30 items archived by
#              rename.
#   history    the same N items over ~C commits (default 2,000); every fifth
#              step merges a side branch that touches the item directories —
#              half of them ordinary merges, half TREESAME to main (main
#              already has the side's changes), which only the dates pass's
#              `git log --full-history` walks into.
#
# Rows (seconds, wall clock):
#   ls / ls --ledger … --open / show / find   cold (no caches: the run builds
#              the index) < 5 s and warm (caches from the previous run) < 1 s
#   refs step  the index build's parse-reference step (_lg_ix_refs) over all
#              N items as blob records — the --staged / --rev case, which
#              probes one parse entry per blob; reported, no budget
#   index --staged (20 staged) / (400 staged)   _lg_index --staged right
#              after staging (worktree caches warm) < 5 s, then warm < 1 s
#   validate --staged (20 staged)   < 1 s when the verb exists; "skipped
#              (Task 7)" until then; (400 staged) is reported, no budget
#   history: cold index / warm      as ls, on the history repository
#   history: dates log [--full-history]   the dates pass's `git log` alone,
#              with and without --full-history (the price of the flag)
#
# Every budget is multiplied by --scale (CI's 300-item smoke uses 3). A
# measurement over its budget is taken up to twice more, in the same cache
# state (cold: caches wiped again), and the smallest time stands, so a
# scheduling hiccup on a loaded host is not a failure; a row over budget
# three times fails. The header prints the load average.
#
# Exit: 0 every budget met · 1 a budget exceeded · 2 could not run · 3 usage.
# Runs doc-tools.sh under the bash running this script (`/bin/bash
# scripts/bench-ledger.sh 3000` measures bash 3.2).
set -euo pipefail

B_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
B_DT="$B_DIR/doc-tools.sh"
B_LIB="$B_DIR/ledger/lib.sh"
B_BASH="${BASH:-bash}"

b_usage() {
  echo "usage: bench-ledger.sh [--scale K] [--history-commits C] [--keep] <N>" >&2
  exit 3
}

B_SCALE=1
B_HIST=2000
B_KEEP=0
B_N=""
while [ $# -gt 0 ]; do
  case "$1" in
    --scale) [ $# -ge 2 ] || b_usage; B_SCALE=$2; shift 2 ;;
    --scale=*) B_SCALE=${1#*=}; shift ;;
    --history-commits) [ $# -ge 2 ] || b_usage; B_HIST=$2; shift 2 ;;
    --history-commits=*) B_HIST=${1#*=}; shift ;;
    --keep) B_KEEP=1; shift ;;
    -h|--help) b_usage ;;
    -*) echo "bench-ledger.sh: unknown option '$1'" >&2; b_usage ;;
    *) [ -z "$B_N" ] || b_usage; B_N=$1; shift ;;
  esac
done
case "$B_N" in ''|*[!0123456789]*) b_usage ;; esac
case "$B_HIST" in ''|*[!0123456789]*) b_usage ;; esac
case "$B_SCALE" in ''|*[!0123456789.]*|*.*.*) b_usage ;; esac
[ "$B_N" -ge 20 ] || { echo "bench-ledger.sh: N must be at least 20" >&2; exit 3; }
[ "$B_HIST" -ge 10 ] || { echo "bench-ledger.sh: --history-commits must be at least 10" >&2; exit 3; }

b_die() {
  echo "bench-ledger: could not run: $*" >&2
  exit 2
}

for b_tool in git jq awk; do
  command -v "$b_tool" >/dev/null 2>&1 || b_die "$b_tool not found"
done
[ -f "$B_DT" ] && [ -f "$B_LIB" ] || b_die "doc-tools.sh and ledger/lib.sh must sit beside this script"

# Budgets (seconds) × scale.
b_budget() { awk -v b="$1" -v k="$B_SCALE" 'BEGIN { printf "%.3f", b * k }'; }
B_WARM=$(b_budget 1)
B_COLD=$(b_budget 5)
B_VSTAGED=$(b_budget 1)

# A private root and git environment: no user or system config.
B_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/bench-ledger.XXXXXX") || b_die "mktemp failed"
b_cleanup() {
  cd / 2>/dev/null || true
  if [ "$B_KEEP" = 1 ]; then echo "bench-ledger: kept $B_ROOT" >&2; else rm -rf "$B_ROOT"; fi
}
trap b_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
  GIT_COMMON_DIR GIT_NAMESPACE GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null HOME="$B_ROOT/home"
export GIT_AUTHOR_NAME=Bench GIT_AUTHOR_EMAIL=bench@example.com GIT_COMMITTER_NAME=Bench GIT_COMMITTER_EMAIL=bench@example.com
mkdir -p "$HOME"
TIMEFORMAT=%3R

B_T="$B_ROOT/time"
B_OUT="$B_ROOT/out"
B_ERR="$B_ROOT/err"

# --- The corpus ---------------------------------------------------------------------

# b_gen <n> <steps> <merge-every> <archive> <meta-out>: a fast-import stream
# on stdout. Each step adds the next items (or, once all are added, edits
# one) and touches src/; every <merge-every>-th step (0: none) commits on a
# side branch cut one main commit back and merges it (the merge repeats the
# step's changes, so it touches the item directories). The last commit
# adds the registry, config, doc-index and docs, and renames <archive>
# closed items into docs/archive/issues/. <meta-out>: a key to show and two
# words to find.
b_gen() {
  LC_ALL=C awk -v N="$1" -v STEPS="$2" -v MEV="$3" -v ARCH="$4" -v META="$5" '
    function rnd() { SEED = (SEED * 16807) % 2147483647; return SEED / 2147483647 }
    function ri(n) { return int(rnd() * n) }
    function words(k,   s, j) { s = ""; for (j = 0; j < k; j++) s = s (j ? " " : "") V[ri(NV)]; return s }
    function blob(content) { MK++; printf "blob\nmark :%d\ndata %d\n%s\n", MK, length(content), content; return MK }
    function commit(ref, from, merge, files, msg,   m) {
      MK++; m = MK; T += 3600 * 5
      printf "commit %s\nmark :%d\nauthor Bench <bench@example.com> %d +0000\ncommitter Bench <bench@example.com> %d +0000\ndata %d\n%s\n", ref, m, T, T, length(msg), msg
      if (from != "") printf "from :%s\n", from
      if (merge != "") printf "merge :%s\n", merge
      printf "%s", files
      NC++
      return m
    }
    function item(i,   s, st, sv, r, c, l) {
      l = LG[i]
      r = rnd()
      sv = (r < 0.05) ? "P0" : (r < 0.30) ? "P1" : (r < 0.70) ? "P2" : (r < 0.95) ? "P3" : ""
      r = rnd()
      st = (r < 0.45) ? "Open" : (r < 0.55) ? "In progress" : (r < 0.80) ? "Fixed" : (r < 0.92) ? "Closed" : "won'"'"'t fix"
      ST[i] = st
      s = "---\nkey: " KEY[i] "\nledger: " l "\nstatus: " st "\n"
      if (sv != "") s = s "severity: " sv "\n"
      if (rnd() < 0.3) s = s sprintf("date: 2025-%02d-%02d\n", ri(12) + 1, ri(28) + 1)
      c = substr(words(4 + ri(18)), 1, 140)
      s = s "summary: " c "\n"
      if (rnd() < 0.4) s = s "changes: [field:" l ".f" (ri(20) + 1) "]\n"
      if (rnd() < 0.3) s = s "consumes: [field:" LG[ri(N) + 1] ".f" (ri(20) + 1) "]\n"
      if (rnd() < 0.2 && i > 1) s = s "relates: [sibling:" KEY[i - 1] "]\n"
      if (st == "Fixed" && rnd() < 0.33) s = s "owed: deploy\n"
      if (st == "Closed" && rnd() < 0.5 && i > 1) s = s "superseded_by: " KEY[i - 1] "\n"
      s = s "related-files: [src/f" ri(50) ".txt]\n---\n# " words(3 + ri(4)) "\n\n" words(10 + ri(20)) ".\n"
      if (st == "Closed" || st == "won'"'"'t fix") s = s "\n## Resolution\n\n" words(6 + ri(8)) ".\n"
      return s
    }
    BEGIN {
      SEED = 20261012; T = 1735689600; MK = 0; NC = 0
      NV = split("cart total order tax shipping quote receipt refund payment invoice login token session " \
        "password reset email search index query filter sort facet catalog price stock variant image " \
        "upload sync offline cache retry timeout crash memory leak scroll layout sheet button label " \
        "badge banner toast modal picker field form error warning stale race lock deadlock queue worker " \
        "deploy rollback flag config schema migration vector embedding dedup scan camera capture photo " \
        "thumbnail crop mask subject tile grid list detail header footer nav tab rail chat thread " \
        "message reply draft notification push audit log metric trace alert budget quota billing plan " \
        "trial coupon discount currency locale timezone date format copy string accessibility contrast " \
        "voiceover dynamic type keyboard focus gesture swipe drag drop haptic animation transition", V, " ")
      split("checkout auth search billing catalog infra", LN, " ")
      for (i = 1; i <= N; i++) {
        LG[i] = LN[((i - 1) % 6) + 1]; CNT[LG[i]]++; KEY[i] = LG[i] "-" CNT[LG[i]]
        P[i] = sprintf("docs/issues/2025-%02d-%02d-%s-%s-%d.md", ri(12) + 1, ri(28) + 1, V[ri(NV)], V[ri(NV)], i)
      }
      for (i = 1; i <= N; i++) { C[i] = item(i); B[i] = blob(C[i]) }
      main = ""; next_i = 1; per = N / STEPS; if (per < 0) per = 0
      for (k = 1; k <= STEPS; k++) {
        lim = int(k * per); if (k == STEPS) lim = N
        files = ""; added = ""
        for (; next_i <= N && next_i <= lim; next_i++) { files = files sprintf("M 100644 :%d %s\n", B[next_i], P[next_i]); added = added " " next_i }
        if (added == "" && next_i > 1) {
          j = ri(next_i - 1) + 1
          if (ONMAIN[j]) { C[j] = C[j] "\n- step " k "\n"; B[j] = blob(C[j]); files = files sprintf("M 100644 :%d %s\n", B[j], P[j]) }
        }
        files = files sprintf("M 100644 inline src/f%d.txt\ndata %d\n%s\n", k % 50, length("step " k), "step " k)
        if (MEV > 0 && k % MEV == 0 && NMAIN >= 2 && (k / MEV) % 2 == 0) {
          side = commit("refs/heads/side", MAINS[NMAIN - 1], "", files, "side step " k)
          main = commit("refs/heads/main", main, side, files, "merge step " k); NMERGE++
        } else if (MEV > 0 && k % MEV == 0 && NMAIN >= 1) {
          # main has the side branch'"'"'s changes already: the merge is TREESAME
          # to main, so only --full-history walks the side commit.
          side = commit("refs/heads/side", main, "", files, "side step " k)
          main = commit("refs/heads/main", main, "", files, "step " k)
          main = commit("refs/heads/main", main, side, "", "merge step " k " (treesame)"); NMERGE++; NTS++
        } else {
          main = commit("refs/heads/main", main, "", files, "step " k)
        }
        NMAIN++; MAINS[NMAIN] = main
        na = split(added, A, " "); for (a = 1; a <= na; a++) ONMAIN[A[a]] = 1
      }
      # The last commit: registry, config, doc-index, docs, archive renames.
      reg = "{\"schema\":\"ledger-registry/1\",\"ledgers\":["
      for (l = 1; l <= 6; l++) {
        reg = reg (l > 1 ? "," : "") "{\"id\":\"" LN[l] "\",\"title\":\"" LN[l] "\",\"kind\":\"service\",\"status\":\"active\",\"contracts\":["
        for (c = 1; c <= 20; c++) reg = reg (c > 1 ? "," : "") "{\"id\":\"field:" LN[l] ".f" c "\"}"
        reg = reg "]}"
      }
      reg = reg "]}\n"
      files = sprintf("M 100644 :%d docs/ledger/ledgers.json\n", blob(reg))
      files = files sprintf("M 100644 :%d docs/ledger/config.json\n", blob("{}\n"))
      nd = int(N / 15); if (nd < 2) nd = 2
      di = "{\"docs\":{"
      for (d = 1; d <= nd; d++) {
        kind = (d % 2) ? "spec" : "plan"
        dp = (kind == "spec") ? sprintf("docs/specs/SPEC-%04d.md", d) : sprintf("docs/plans/%04d-plan.md", d)
        body = "# " words(4) "\n\n" ((kind == "plan" && d % 6 == 0) ? "Status: Completed\n\n" : "")
        nl = 3 + ri(6)
        for (q = 0; q < nl; q++) {
          i = ri(N) + 1
          if (q % 2) body = body "- [" KEY[i] "](../../" P[i] ")\n"
          else body = body "- fixes " KEY[i] "\n"
        }
        files = files sprintf("M 100644 :%d %s\n", blob(body), dp)
        di = di (d > 1 ? "," : "") "\"" dp "\":{\"doc_type\":\"" kind "\"}"
      }
      di = di "}}\n"
      files = files sprintf("M 100644 :%d docs/.doc-index.json\n", blob(di))
      na = 0
      for (i = 1; i <= N && na < ARCH; i++) {
        if (ST[i] == "Closed") { np = P[i]; sub(/^docs\/issues\//, "docs/archive/issues/", np); files = files "R " P[i] " " np "\n"; na++ }
      }
      main = commit("refs/heads/main", main, "", files, "ledger setup")
      mid = int(N / 2) + 1
      printf("show %s\nfind %s %s\ncommits %d\nmerges %d\ntreesame %d\narchived %d\n", KEY[mid], V[1], V[3], NC, NMERGE + 0, NTS + 0, na) > META
    }'
}

# b_repo <dir> <steps> <merge-every> <archive>: build a repository.
b_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main 2>/dev/null || { git -C "$dir" init -q && git -C "$dir" symbolic-ref HEAD refs/heads/main; }
  b_gen "$B_N" "$2" "$3" "$4" "$dir.meta" > "$dir.stream" || b_die "cannot generate the corpus"
  git -C "$dir" fast-import --quiet < "$dir.stream" || b_die "git fast-import failed"
  git -C "$dir" reset -q --hard main || b_die "cannot check out the corpus"
  git -C "$dir" branch -q -D side 2>/dev/null || true
  rm -f "$dir.stream"
}

b_meta() { awk -v k="$2" '$1 == k { $1 = ""; sub(/^ /, ""); print; exit }' "$1.meta"; }

# --- Timing ---------------------------------------------------------------------------

# b_run <cmd…>: run in the current repo, time into B_SEC; rc 2 on failure.
b_run() {
  local rc=0
  { time "$@" > "$B_OUT" 2> "$B_ERR"; } 2> "$B_T" || rc=$?
  if [ "$rc" != 0 ]; then
    echo "bench-ledger: '$*' exited $rc:" >&2
    head -n 5 "$B_ERR" >&2 || true
    exit 2
  fi
  B_SEC=$(tail -n 1 "$B_T")
}

b_over() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }
b_min() { awk -v a="$1" -v b="$2" 'BEGIN { print (a < b) ? a : b }'; }

B_FAILS=""
B_FAIL_N=0
b_fail() {
  B_FAIL_N=$((B_FAIL_N + 1))
  B_FAILS="$B_FAILS
  $1"
}

# b_wipe <0|1|2>: 0 nothing; 1 every ledger cache (a cold run); 2 the index
# files only (parse entries and dates stay: the state right after an input
# changed).
b_wipe() {
  local c
  c="$(git rev-parse --git-common-dir)/doc-superpowers/ledger"
  case "$1" in
    1) rm -rf "$c" ;;
    2) rm -f "$c"/index-*.json "$c"/index-*.refs ;;
  esac
}

# b_measure <label> <budget|-> <wipe 0|1|2> <cmd…>: the time into B_SEC and
# a mark into B_MARK ("ok", "ok (try 2)", "ok (try 3)" or "OVER"); over
# budget → up to twice more in the same state (b_wipe <wipe> again first),
# keeping the smallest.
b_measure() {
  local label="$1" budget="$2" wipe="$3" best try=1
  shift 3
  b_wipe "$wipe"
  b_run "$@"
  B_MARK=ok
  best=$B_SEC
  while [ "$budget" != - ] && b_over "$best" "$budget" && [ "$try" -lt 3 ]; do
    try=$((try + 1))
    b_wipe "$wipe"
    b_run "$@"
    best=$(b_min "$best" "$B_SEC")
    B_MARK="ok (try $try)"
  done
  B_SEC=$best
  if [ "$budget" != - ] && b_over "$B_SEC" "$budget"; then
    B_MARK=OVER
    b_fail "$label: $B_SEC s > $budget s (best of $try)"
  fi
}

b_row() { printf '%-44s %9s %9s  %s\n' "$1" "$2" "$3" "$4"; }

# b_verb <label> <args…>: a ledger verb cold, then warm.
b_verb() {
  local label="$1" cold cmark
  shift
  b_measure "$label (cold)" "$B_COLD" 1 "$B_BASH" "$B_DT" ledger "$@"
  cold=$B_SEC
  cmark=$B_MARK
  b_measure "$label (warm)" "$B_WARM" 0 "$B_BASH" "$B_DT" ledger "$@"
  b_row "$label" "$cold" "$B_SEC" "cold $cmark · warm $B_MARK"
}

# The library driver: an internal function in a doc-tools.sh-sourced shell,
# the way scripts/test-ledger.sh calls them. "refs" prints its own time.
B_DRIVER="$B_ROOT/driver.sh"
cat > "$B_DRIVER" <<'EOF'
dt="$1"; lib="$2"; op="$3"; shift 3
DOC_TOOLS_SOURCE_ONLY=1
. "$dt"
unset DOC_TOOLS_SOURCE_ONLY
. "$lib"
_SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/bench-ledger-drv.XXXXXX")
trap 'rm -rf "$_SCRATCH"' EXIT
_LG_ACTIVE=1
_LG_FORMAT=text
_lg_init ls
case "$op" in
  index) _lg_index ;;
  index-staged) _lg_index --staged ;;
  refs)
    _lg_index > /dev/null
    TIMEFORMAT=%3R
    { time _lg_ix_refs "$1" "$_SCRATCH/refs.out" > /dev/null; } 2> "$_SCRATCH/t"
    printf '%s %s\n' "$(tail -n 1 "$_SCRATCH/t")" "$(wc -l < "$_SCRATCH/refs.out" | tr -d ' ')"
    ;;
esac
EOF
b_lib() { "$B_BASH" "$B_DRIVER" "$B_DT" "$B_LIB" "$@"; }

# b_validate <args…>: `ledger validate` (findings, exit 1, are fine here).
b_validate() {
  local rc=0
  "$B_BASH" "$B_DT" ledger validate "$@" || rc=$?
  [ "$rc" -le 1 ]
}

# b_validate_staged <label> <budget|->: validate --staged right after
# staging (index files wiped, as after an input change), or "skipped (Task
# 7)" while the verb is a stub (exit 2, "not implemented").
b_validate_staged() {
  local rc=0 label="$1" budget="$2"
  "$B_BASH" "$B_DT" ledger validate --staged --format json > "$B_OUT" 2> "$B_ERR" || rc=$?
  if [ "$rc" = 2 ] && [ "$(jq -r '.error // empty' "$B_OUT" 2>/dev/null)" = "not implemented" ]; then
    b_row "$label" "-" "-" "skipped (Task 7)"
    return 0
  fi
  b_measure "$label" "$budget" 2 b_validate --staged
  b_row "$label" "$B_SEC" "-" "$B_MARK"
}

# b_staged <count> <validate-budget|->: <count> staged item edits (20) or
# new items (400), timed, then undone.
b_staged() {
  local n="$1" vb="$2" i f
  if [ "$n" -le 20 ]; then
    git ls-files -- 'docs/issues/*.md' > "$B_ROOT/items.list"
    head -n "$n" "$B_ROOT/items.list" > "$B_ROOT/staged.list"
    while IFS= read -r f; do printf '\n- staged edit\n' >> "$f"; done < "$B_ROOT/staged.list"
  else
    mkdir -p docs/issues
    i=1
    while [ "$i" -le "$n" ]; do
      printf -- '---\nkey: checkout-%d\nledger: checkout\nstatus: Open\nseverity: P2\nsummary: Staged item %d for the bench\n---\n# Staged %d\n\nBody.\n' \
        "$((900000 + i))" "$i" "$i" > "docs/issues/zz-staged-$i.md"
      i=$((i + 1))
    done
  fi
  git add -A docs/issues
  b_measure "index --staged ($n staged) (first)" "$B_COLD" 2 b_lib index-staged
  local first=$B_SEC fmark=$B_MARK
  b_measure "index --staged ($n staged) (warm)" "$B_WARM" 0 b_lib index-staged
  b_row "index --staged ($n staged)" "$first" "$B_SEC" "first $fmark · warm $B_MARK"
  b_validate_staged "validate --staged ($n staged)" "$vb"
  git reset -q --hard
  git clean -q -f -- docs/issues
}

# --- Run ------------------------------------------------------------------------------

B_START=$(date +%s)
b_repo "$B_ROOT/corpus" "$(( B_N / 15 > 10 ? B_N / 15 : 10 ))" 0 "$(( B_N / 30 ))"
b_repo "$B_ROOT/history" "$(( B_HIST * 10 / 13 ))" 5 0
B_BUILT=$(( $(date +%s) - B_START ))

load=$(uptime 2>/dev/null | sed 's/.*load average[s]*: *//') || load="?"
echo "bench-ledger: N=$B_N, budgets ×$B_SCALE (warm $B_WARM s, cold $B_COLD s, validate --staged $B_VSTAGED s)"
# shellcheck disable=SC2016  # expanded by the child bash
echo "  bash $("$B_BASH" -c 'echo $BASH_VERSION'), $(jq --version), $(git --version), load $load"
echo "  corpus: $(b_meta "$B_ROOT/corpus" commits) commits, $(b_meta "$B_ROOT/corpus" archived) archived; history: $(b_meta "$B_ROOT/history" commits) commits, $(b_meta "$B_ROOT/history" merges) merges ($(b_meta "$B_ROOT/history" treesame) TREESAME); built in ${B_BUILT} s"
b_row "case" "cold s" "warm s" "budget"

cd "$B_ROOT/corpus"
show_key=$(b_meta "$B_ROOT/corpus" show)
find_words=$(b_meta "$B_ROOT/corpus" find)
b_verb "ls" ls
b_verb "ls --ledger checkout --sev P1,P2 --open" ls --ledger checkout --sev P1,P2 --open
echo "  (ls --ledger checkout --sev P1,P2 --open: $(wc -l < "$B_OUT" | tr -d ' ') lines, $(wc -c < "$B_OUT" | tr -d ' ') bytes)"
b_verb "show $show_key" show "$show_key"
# shellcheck disable=SC2086  # two words
b_verb "find $find_words" find $find_words

# The refs step: every item as a blob record (the --staged / --rev shape).
git ls-files -s -- docs/issues docs/archive/issues | awk '{ print "{\"blob\":\"" $2 "\"}" }' > "$B_ROOT/recs.jsonl"
b_lib refs "$B_ROOT/recs.jsonl" > "$B_OUT" 2> "$B_ERR" || { head -n 5 "$B_ERR" >&2; b_die "the refs step failed"; }
read -r refs_sec refs_n < "$B_OUT"
b_row "refs step ($refs_n blob records)" "-" "$refs_sec" "reported (no budget)"

b_staged 20 "$B_VSTAGED"
b_staged 400 -

cd "$B_ROOT/history"
b_measure "history: cold index (ls --sev P0) (cold)" "$B_COLD" 1 "$B_BASH" "$B_DT" ledger ls --sev P0
hc=$B_SEC; hm=$B_MARK
b_measure "history: cold index (ls --sev P0) (warm)" "$B_WARM" 0 "$B_BASH" "$B_DT" ledger ls --sev P0
b_row "history: cold index (ls --sev P0)" "$hc" "$B_SEC" "cold $hm · warm $B_MARK"
b_log() {
  GIT_LITERAL_PATHSPECS=1 git -c log.showSignature=false log --no-color --reverse "$@" --date=short \
    --format=%ad --name-status -M --diff-filter=AR -z HEAD -- docs/issues/ docs/archive/issues/
}
b_run b_log --full-history
b_row "history: dates log --full-history" "$B_SEC" "-" "reported ($(wc -c < "$B_OUT" | tr -d ' ') bytes)"
b_run b_log
b_row "history: dates log (simplified)" "$B_SEC" "-" "reported ($(wc -c < "$B_OUT" | tr -d ' ') bytes)"

if [ "$B_FAIL_N" -gt 0 ]; then
  echo "bench-ledger: OVER BUDGET ($B_FAIL_N):$B_FAILS"
  exit 1
fi
echo "bench-ledger: ok (every budget met)"
