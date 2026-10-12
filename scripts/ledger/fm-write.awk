# scripts/ledger/fm-write.awk — rewrite fields of an item's frontmatter, in one
# pass (several edits, one output: the caller installs it once).
#
# stdin: the file. stdout: the NEW frontmatter block, from line 1 through the
# closing "---" line. The caller appends the body itself, byte for byte
# (tail), as the status file says — so this program never touches a body byte:
#   body <N>       append the file from line N on (tail -n +N)
#   prepend <B>    the file had no frontmatter: stdout is a new block; append
#                  the file from byte B+1 on (B = 3 when it starts with a BOM,
#                  which the new block now carries)
#   unchanged      nothing to write (only del edits, and no field to drop —
#                  or no frontmatter)
#   unterminated   the block has no closing --- line: refuse
#
# -v status=<file>, -v bom=<the BOM's bytes>. The edits come through ENVIRON
# (never -v, which processes backslashes), applied in order 1..LG_FMW_NOPS:
#   LG_FMW_<k>_OP      set | setlist | add | del
#   LG_FMW_<k>_FIELD   the field name (the caller validated it)
#   LG_FMW_<k>_VALUE   set: the scalar; add: the new item (a block list gets
#                      it as one more "- item" line)
#   LG_FMW_<k>_ITEMS, LG_FMW_<k>_NITEMS   setlist / add on a flow list or a
#                      scalar: the whole new list, items joined by \001
#
# set / setlist replace the field's line and its continuation lines (the
# indented, blank or "- " lines under it) at its first occurrence and drop any
# later duplicate; a missing field is appended as the LAST frontmatter line.
# setlist on a block list keeps the block form (its "key:" line as it was, one
# "- item" line per item at the first item's indent); otherwise it writes a
# flow list.
# del drops every occurrence. New lines take the file's line ending (CRLF when
# line 1 ends in CR). Untouched frontmatter lines are copied byte for byte.
#
# Quoting (design §B): a scalar is double-quoted when it is empty, contains
# ":" or "#", has a leading or trailing space, starts with one of
# [ ] { } " ' | > ! & * % @ ` ? , - or holds a control character. A flow
# item is double-quoted when it is empty, contains one of , [ ] { } # " ' or
# ": ", ends with ":", has a leading or trailing space, starts with one of
# | > ! & * % @ ` ? or "- ", or holds a control character.
#
# Portable awk; run under LC_ALL=C.

BEGIN {
  CTLRE = "[" sprintf("%c", 1) "-" sprintf("%c", 31) "]"
  SEP = sprintf("%c", 1)
  NOPS = ENVIRON["LG_FMW_NOPS"] + 0
  ALLDEL = 1
  for (k = 1; k <= NOPS; k++) if (ENVIRON["LG_FMW_" k "_OP"] != "del") ALLDEL = 0
  EOL = "\n"
  CR = ""
  n = 0
  done = 0
}

# load_op(k): edit k into OP, FIELD, VALUE, NITEMS, ITEMS[].
function load_op(k,   pre) {
  pre = "LG_FMW_" k "_"
  OP = ENVIRON[pre "OP"]
  FIELD = ENVIRON[pre "FIELD"]
  VALUE = ENVIRON[pre "VALUE"]
  NITEMS = ENVIRON[pre "NITEMS"] + 0
  split("", ITEMS)
  if (NITEMS > 0) split_sep(ENVIRON[pre "ITEMS"])
}

# s with every <ch> replaced by <by>, literally. Not split(): BWK awk's
# split() on a one-character separator also splits at every newline.
function rep(s, ch, by,   out, i) {
  out = ""
  while ((i = index(s, ch)) > 0) {
    out = out substr(s, 1, i - 1) by
    s = substr(s, i + length(ch))
  }
  return out s
}

# ITEMS[1..] from s split at SEP (index(), not split(): see rep).
function split_sep(s,   k, i) {
  k = 0
  while ((i = index(s, SEP)) > 0) {
    ITEMS[++k] = substr(s, 1, i - 1)
    s = substr(s, i + 1)
  }
  ITEMS[++k] = s
}

function trim(s) {
  sub(/^[ \t]+/, "", s)
  sub(/[ \t]+$/, "", s)
  return s
}

function dq(v) {
  v = rep(v, "\\", "\\\\")
  v = rep(v, "\"", "\\\"")
  v = rep(v, "\n", "\\n")
  v = rep(v, "\t", "\\t")
  v = rep(v, "\r", "\\r")
  return "\"" v "\""
}

function fmt_scalar(v) {
  if (v == "" || v ~ /[:#]/ || v ~ /^[ \t]/ || v ~ /[ \t]$/ || v ~ CTLRE \
      || index("[]{}\"'|>!&*%@`?,-", substr(v, 1, 1)) > 0) return dq(v)
  return v
}

function fmt_flow(v) {
  if (v == "" || v ~ /[,{}#"']/ || index(v, "[") || index(v, "]") || v ~ /:[ \t]/ || v ~ /:$/ \
      || v ~ /^[ \t]/ || v ~ /[ \t]$/ || v ~ CTLRE || v ~ /^-[ \t]/ || v == "-" \
      || index("|>!&*%@`?", substr(v, 1, 1)) > 0) return dq(v)
  return v
}

function flow_line(   i, s) {
  s = ""
  for (i = 1; i <= NITEMS; i++) s = s (i > 1 ? ", " : "") fmt_flow(ITEMS[i])
  return FIELD ": [" s "]"
}

function new_line() {
  if (OP == "set") return FIELD ": " fmt_scalar(VALUE)
  return flow_line()
}

# The field name of a "key: …" line at column 0, or "".
function key_of(s,   k) {
  if (!match(s, /^[[:alnum:]_][[:alnum:]_.-]*[ \t]*:/)) return ""
  if (substr(s, RLENGTH + 1) !~ /^([ \t]|$)/) return ""
  k = substr(s, 1, RLENGTH - 1)
  sub(/[ \t]+$/, "", k)
  return k
}

function finish(st) {
  print st > status
  close(status)
  done = 1
  exit 0
}

# R[1..n]: the raw frontmatter lines (CR kept); S[1..n]: without CR.
# emit(): one line of the new block T[1..tn]; commit(): T becomes R/S.
function emit(line) { T[++tn] = line }
function commit(   i, l) {
  n = tn
  for (i = 1; i <= n; i++) { R[i] = T[i]; l = T[i]; sub(/\r$/, "", l); S[i] = l }
}

# apply(): the loaded edit (load_op) on R/S.
function apply(   i, j, first, last, isblock, k, prefix, placed) {
  # Each occurrence's range i..j (its continuation lines included).
  split("", DROP)
  split("", T)
  tn = 0
  first = 0
  for (i = 1; i <= n; i++) {
    if (key_of(S[i]) != FIELD) continue
    j = i
    while (j < n && (S[j + 1] ~ /^[ \t]/ || S[j + 1] ~ /^-([ \t]|$)/ || S[j + 1] ~ /^[ \t]*$/)) j++
    while (j > i && S[j] ~ /^[ \t]*$/) j--
    if (!first) { first = i; last = j }
    for (k = i; k <= j; k++) DROP[k] = 1
    i = j
  }
  # add on a block list: one more item line after the last one; setlist on
  # one: the same "key:" line, then the new items.
  if ((OP == "add" || OP == "setlist") && first) {
    isblock = (trim(substr(S[first], index(S[first], ":") + 1)) ~ /^(#.*)?$/) && last > first
    for (k = first + 1; isblock && k <= last; k++) {
      if (S[k] ~ /^[ \t]*$/ || S[k] ~ /^[ \t]*#/) continue
      if (S[k] !~ /^[ \t]*-([ \t]|$)/) isblock = 0
      else { prefix = S[k]; sub(/-.*$/, "", prefix) }
    }
    if (isblock && OP == "add") {
      for (i = 1; i <= n; i++) {
        emit(R[i])
        if (i == last) emit(prefix "- " fmt_scalar(VALUE) CR)
      }
      commit()
      return
    }
    if (isblock) {
      for (i = 1; i <= n; i++) {
        if (i == first) {
          emit(R[i])
          for (k = 1; k <= NITEMS; k++) emit(prefix "- " fmt_scalar(ITEMS[k]) CR)
          continue
        }
        if (i in DROP) continue
        emit(R[i])
      }
      commit()
      return
    }
  }
  placed = 0
  for (i = 1; i <= n; i++) {
    if (i == first && OP != "del") { emit(new_line() CR); placed = 1 }
    if (i in DROP) continue
    emit(R[i])
  }
  if (!placed && OP != "del") emit(new_line() CR)
  commit()
}

# apply_all(): every edit, in order.
function apply_all(   k) {
  for (k = 1; k <= NOPS; k++) { load_op(k); apply() }
}

function print_block(   i) {
  for (i = 1; i <= n; i++) printf "%s\n", R[i]
}

NR == 1 {
  raw = $0
  hadbom = 0
  if (bom != "" && substr(raw, 1, length(bom)) == bom) { raw = substr(raw, length(bom) + 1); hadbom = 1 }
  if (raw ~ /\r$/) { EOL = "\r\n"; CR = "\r" }
  line = raw
  sub(/\r$/, "", line)
  if (line !~ /^---[ \t]*$/) {
    if (ALLDEL) finish("unchanged")
    printf "%s---%s", (hadbom ? bom : ""), EOL
    apply_all()
    print_block()
    printf "---%s", EOL
    finish("prepend " (hadbom ? length(bom) : 0))
  }
  head = $0
  next
}

{
  line = $0
  sub(/\r$/, "", line)
  if (line ~ /^---[ \t]*$/) {
    if (ALLDEL) {
      # Nothing to delete: leave the file alone.
      found = 0
      for (k = 1; k <= NOPS; k++) {
        load_op(k)
        for (i = 1; i <= n; i++) if (key_of(S[i]) == FIELD) found = 1
      }
      if (!found) finish("unchanged")
    }
    printf "%s\n", head
    apply_all()
    print_block()
    printf "%s\n", $0
    finish("body " (NR + 1))
  }
  n++
  R[n] = $0
  S[n] = line
}

END {
  if (done) exit 0
  if (NR == 0) {
    # An empty file: no frontmatter.
    if (ALLDEL) { print "unchanged" > status; exit 0 }
    printf "---%s", EOL
    apply_all()
    print_block()
    printf "---%s", EOL
    print "prepend 0" > status
    exit 0
  }
  print "unterminated" > status
}
