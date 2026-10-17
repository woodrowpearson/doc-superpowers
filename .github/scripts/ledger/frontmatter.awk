# scripts/ledger/frontmatter.awk — an item file's text → one JSON record.
#
# The record (design §B):
#   {"path", "fm": {<key>: <string> | [<string>…]}, "fm_errors": [<string>…],
#    "h1", "first_para", "resolution", "log"}
# h1 / first_para / resolution are strings or null; log is true when a line
# equals log_heading. first_para is the first paragraph (headings and fenced
# blocks are not paragraphs), whitespace collapsed, at most 300 characters
# (a longer one is cut to 299 and ends with "…"). resolution is the first
# text line after resolution_heading (a deeper heading is skipped; a heading
# of the same or a higher level ends the section).
#
# Frontmatter: only when line 1 (after an optional UTF-8 BOM) is "---"; it
# ends at the next "---" line. Inside: `key: value` lines at column 0 —
# plain, "double-" or 'single-quoted' scalars (a plain value folds indented
# continuation lines), flow sequences [a, "b c"] on one line, block
# sequences of scalars (`  - a`, or `- a` at column 0). Anything else in a
# key (a nested map, a nested sequence, a block scalar | or >, a multi-line
# quoted or flow value) is an fm_errors entry naming the key, and the key is
# omitted; the other keys still parse. An unterminated block is an error and
# none of it is trusted (fm is {}); its lines are read as body text. A file
# that does not start with "---" has no frontmatter and no error.
# CRLF line endings are read as LF. Fenced blocks (``` or ~~~, 3 or more,
# closed by the same character at least as long) are ignored in the body.
#
# Modes (-v mode=…):
#   ""     stdin is ONE file's text; prints the record with "path" (-v path;
#          note that -v processes backslash escapes — parse.sh never uses
#          this mode).
#   files  the arguments are files ("./"-prefixed when relative); -v keys=
#          <file> holds "<cache-key>\t<path>" lines; each file's record
#          WITHOUT "path" ({"fm",…,"log"}) is written to <outdir>/<key>.json.
#          An empty file still gets its record.
#   batch  stdin is `git cat-file --batch` output, NUL bytes mapped to \001
#          by the caller (sizes must hold); each blob's record without "path"
#          goes to <outdir>/b-<oid>.json. A stream that does not match its
#          headers exits 3.
# Other variables: bom (the BOM's bytes: -v bom=$'\357\273\277'),
# resolution_heading and log_heading (defaults "## Resolution", "## Log").
#
# Portable awk (macOS BWK awk, gawk, mawk). Run under LC_ALL=C: lengths are
# bytes (the batch sizes depend on it) and multi-byte characters pass through
# as bytes. No gsub with a backslash in the replacement (awks disagree on
# it), and no split() on one character (BWK also splits at newlines):
# escaping uses index().

BEGIN {
  if (resolution_heading == "") resolution_heading = "## Resolution"
  if (log_heading == "") log_heading = "## Log"
  RHEAD = trim(resolution_heading)
  LHEAD = trim(log_heading)
  RLEVEL = 0
  if (match(RHEAD, /^#+/)) RLEVEL = RLENGTH
  for (i = 1; i < 32; i++) CTL[sprintf("%c", i)] = sprintf("\\u%04x", i)
  CTLRE = "[" sprintf("%c", 1) "-" sprintf("%c", 31) "]"
  for (i = 128; i < 192; i++) CONT[sprintf("%c", i)] = 1
  ELLIPSIS = "\342\200\246"
  if (mode == "files") {
    while ((getline kl < keys) > 0) {
      t = index(kl, "\t")
      KEYOF[substr(kl, t + 1)] = substr(kl, 1, t - 1)
    }
    close(keys)
    for (i = 1; i < ARGC; i++) PENDING[ARGV[i]] = 1
  }
  if (mode == "batch") { inblob = 0; skipsep = 0 }
  if (mode == "") doc_begin()
}

# --- strings -------------------------------------------------------------------

function trim(s) {
  sub(/^[ \t]+/, "", s)
  sub(/[ \t]+$/, "", s)
  return s
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

# A JSON string literal for s.
function js(s,   out, i, n, c) {
  if (index(s, "\\")) s = rep(s, "\\", "\\\\")
  if (index(s, "\"")) s = rep(s, "\"", "\\\"")
  if (s ~ CTLRE) {
    s = rep(s, "\t", "\\t")
    s = rep(s, "\n", "\\n")
    s = rep(s, "\r", "\\r")
    if (s ~ CTLRE) {
      out = ""
      n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        out = out ((c in CTL) ? CTL[c] : c)
      }
      s = out
    }
  }
  return "\"" s "\""
}

# s cut to at most max characters (UTF-8), ending with "…" when cut.
function cut(s, max,   n, i, chars, p) {
  if (length(s) <= max) return s
  n = length(s)
  chars = 0
  for (i = 1; i <= n; i++) {
    if (!(substr(s, i, 1) in CONT)) {
      chars++
      if (chars == max) p = i
      # p: the first byte of character number max — keep what precedes it.
      if (chars > max) return substr(s, 1, p - 1) ELLIPSIS
    }
  }
  return s
}

# --- one document --------------------------------------------------------------

function doc_begin() {
  ln = 0; state = "start"; nL = 0
  nk = 0; nerr = 0
  split("", L); split("", FK); split("", FV); split("", FERR)
  h1 = ""; h1set = 0
  pstate = 0; para = ""
  resv = ""; rset = 0; rseek = 0; rdone = 0
  logseen = 0
  infence = 0; fch = ""; flen = 0
}

function doc_line(line) {
  ln++
  if (ln == 1 && bom != "" && substr(line, 1, length(bom)) == bom) line = substr(line, length(bom) + 1)
  sub(/\r$/, "", line)
  if (state == "start") {
    if (line ~ /^---[ \t]*$/) { state = "fm"; return }
    state = "body"
    body_line(line)
    return
  }
  if (state == "fm") {
    if (line ~ /^---[ \t]*$/) { fm_parse(nL); state = "body"; return }
    L[++nL] = line
    return
  }
  body_line(line)
}

# The record without "path".
function doc_end(   i, s) {
  if (state == "fm") {
    fm_err("unterminated frontmatter: no closing --- line")
    for (i = 1; i <= nL; i++) body_line(L[i])
  }
  if (pstate == 1) pstate = 2
  s = "{\"fm\":{"
  for (i = 1; i <= nk; i++) s = s (i > 1 ? "," : "") js(FK[i]) ":" FV[FK[i]]
  s = s "},\"fm_errors\":["
  for (i = 1; i <= nerr; i++) s = s (i > 1 ? "," : "") js(FERR[i])
  s = s "],\"h1\":" (h1set ? js(h1) : "null")
  if (pstate) {
    para = rep(para, "\t", " ")
    gsub(/  +/, " ", para)
    s = s ",\"first_para\":" js(cut(para, 300))
  } else {
    s = s ",\"first_para\":null"
  }
  s = s ",\"resolution\":" (rset ? js(resv) : "null")
  s = s ",\"log\":" (logseen ? "true" : "false") "}"
  return s
}

# --- frontmatter ---------------------------------------------------------------

function fm_err(msg) { FERR[++nerr] = msg }

# fm_put <key> <json-value>: a later duplicate replaces the value (and is an
# error); the key keeps its first position.
function fm_put(k, v) {
  if (k in FV) fm_err(k ": duplicate key (the last value is kept)")
  else FK[++nk] = k
  FV[k] = v
}

# A plain scalar: up to a " #" comment, trimmed.
function plain(s) {
  if (match(s, /[ \t]#/)) s = substr(s, 1, RSTART - 1)
  return trim(s)
}

# A quoted scalar at the start of s (its first character is the quote).
# Sets SV (the value), SREST (the text after the closing quote) and SERR
# ("" when it parsed).
function quoted(s,   q, n, i, c, out) {
  SERR = ""; SREST = ""; SV = ""
  q = substr(s, 1, 1)
  n = length(s)
  out = ""
  for (i = 2; i <= n; i++) {
    c = substr(s, i, 1)
    if (q == "\"" && c == "\\") {
      i++
      c = substr(s, i, 1)
      if (c == "n") out = out "\n"
      else if (c == "t") out = out "\t"
      else if (c == "r") out = out "\r"
      else if (c == "\"" || c == "\\" || c == "/") out = out c
      else if (c == "") break
      else out = out "\\" c
      continue
    }
    if (c == q) {
      if (q == "'" && substr(s, i + 1, 1) == "'") { out = out "'"; i++; continue }
      SV = out
      SREST = substr(s, i + 1)
      return
    }
    out = out c
  }
  SERR = "unterminated " (q == "\"" ? "double" : "single") "-quoted value"
}

# True when the text after a quoted value or a flow sequence is nothing or a
# comment.
function tail_ok(r) {
  r = trim(r)
  return r == "" || substr(r, 1, 1) == "#"
}

# A flow sequence on one line ("[" first). Sets FJ (a JSON array) and FERRM
# ("" when it parsed).
function flow(s,   rest, c, item, n, out, pc, pb, p) {
  FERRM = ""; FJ = ""
  rest = substr(s, 2)
  n = 0
  out = ""
  while (1) {
    sub(/^[ \t]+/, "", rest)
    if (rest == "") { FERRM = "a flow sequence must close on its line"; return }
    c = substr(rest, 1, 1)
    if (c == "]") { rest = substr(rest, 2); break }
    if (c == "[" || c == "{") { FERRM = "a nested sequence or map is not supported"; return }
    if (c == "\"" || c == "'") {
      quoted(rest)
      if (SERR != "") { FERRM = SERR; return }
      item = SV
      rest = SREST
    } else {
      pc = index(rest, ",")
      pb = index(rest, "]")
      p = (pc > 0 && (pb == 0 || pc < pb)) ? pc : pb
      if (p == 0) { FERRM = "a flow sequence must close on its line"; return }
      item = trim(substr(rest, 1, p - 1))
      rest = substr(rest, p)
      if (item ~ /[[{]/) { FERRM = "a nested sequence or map is not supported"; return }
      if (item ~ /:[ \t]/ || item ~ /:$/) { FERRM = "a nested map is not supported"; return }
    }
    out = out (n++ ? "," : "") js(item)
    sub(/^[ \t]+/, "", rest)
    c = substr(rest, 1, 1)
    if (c == ",") { rest = substr(rest, 2); continue }
    if (c == "]") { rest = substr(rest, 2); break }
    FERRM = "expected , or ] in a flow sequence"
    return
  }
  if (!tail_ok(rest)) { FERRM = "text after the closing ]"; return }
  FJ = "[" out "]"
}

# True for an indented "name: …" line (a nested map's line).
function map_line(s) {
  return s ~ /^[ \t]+[[:alnum:]_][[:alnum:]_.-]*[ \t]*:([ \t]|$)/
}

# The frontmatter lines L[1..n] (file lines 2..n+1).
function fm_parse(n,   i, j, k, line, key, rest, c, items, cnt, bad, v, item, ic) {
  for (i = 1; i <= n; i++) {
    line = L[i]
    if (line ~ /^[ \t]*$/ || line ~ /^[ \t]*#/) continue
    if (line ~ /^[ \t]/ || line ~ /^-([ \t]|$)/) {
      fm_err("line " (i + 1) ": an indented or list line with no key above it")
      continue
    }
    if (!match(line, /^[[:alnum:]_][[:alnum:]_.-]*[ \t]*:/) || substr(line, RLENGTH + 1) !~ /^([ \t]|$)/) {
      fm_err("line " (i + 1) ": not a 'key: value' line")
      continue
    }
    key = substr(line, 1, RLENGTH - 1)
    sub(/[ \t]+$/, "", key)
    rest = trim(substr(line, RLENGTH + 1))
    # The key's continuation lines: indented, blank, or "- " items at column 0.
    j = i
    while (j < n && (L[j + 1] ~ /^[ \t]/ || L[j + 1] ~ /^-([ \t]|$)/ || L[j + 1] ~ /^[ \t]*$/)) j++
    while (j > i && L[j] ~ /^[ \t]*$/) j--
    c = substr(rest, 1, 1)
    if (rest == "" || c == "#") {
      if (j == i) { fm_put(key, "\"\""); i = j; continue }
      items = ""; cnt = 0; bad = ""
      for (k = i + 1; k <= j; k++) {
        line = L[k]
        if (line ~ /^[ \t]*$/ || line ~ /^[ \t]*#/) continue
        if (line !~ /^[ \t]*-([ \t]|$)/) {
          bad = map_line(line) ? "a nested map is not supported" : "an unsupported multi-line value"
          bad = key ": " bad " (line " (k + 1) ")"
          break
        }
        item = line
        sub(/^[ \t]*-/, "", item)
        item = trim(item)
        ic = substr(item, 1, 1)
        if (item == "") {
          v = ""
        } else if (ic == "[" || ic == "{") {
          bad = key ": a nested sequence or map is not supported (line " (k + 1) ")"
          break
        } else if (ic == "\"" || ic == "'") {
          quoted(item)
          if (SERR != "") { bad = key ": " SERR " (line " (k + 1) ")"; break }
          if (!tail_ok(SREST)) { bad = key ": text after the closing quote (line " (k + 1) ")"; break }
          v = SV
        } else {
          v = plain(item)
          if (v ~ /:[ \t]/ || v ~ /:$/) { bad = key ": a nested map is not supported (line " (k + 1) ")"; break }
        }
        items = items (cnt++ ? "," : "") js(v)
      }
      if (bad != "") fm_err(bad)
      else fm_put(key, "[" items "]")
    } else if (c == "[") {
      flow(rest)
      if (FERRM != "") fm_err(key ": " FERRM)
      else if (j > i) fm_err(key ": a flow sequence must be on one line")
      else fm_put(key, FJ)
    } else if (c == "{") {
      fm_err(key ": a nested map is not supported")
    } else if (c == "|" || c == ">") {
      fm_err(key ": block scalars (| or >) are not supported")
    } else if (c == "\"" || c == "'") {
      quoted(rest)
      if (SERR != "") fm_err(key ": " SERR)
      else if (!tail_ok(SREST)) fm_err(key ": text after the closing quote")
      else if (j > i) fm_err(key ": a quoted value must be on one line")
      else fm_put(key, js(SV))
    } else {
      v = plain(rest)
      bad = ""
      for (k = i + 1; k <= j; k++) {
        line = L[k]
        if (line ~ /^[ \t]*$/ || line ~ /^[ \t]*#/) continue
        if (line ~ /^-([ \t]|$)/) { bad = key ": list items under a key that has a value (line " (k + 1) ")"; break }
        if (map_line(line)) { bad = key ": a nested map is not supported (line " (k + 1) ")"; break }
        v = v " " plain(line)
      }
      if (bad != "") fm_err(bad)
      else fm_put(key, js(v))
    }
    i = j
  }
}

# --- body ----------------------------------------------------------------------

function fence_open(line,   s, c) {
  s = line
  sub(/^ ? ? ?/, "", s)
  c = substr(s, 1, 1)
  if (c == "`") match(s, /^`+/)
  else if (c == "~") match(s, /^~+/)
  else return 0
  if (RLENGTH < 3) return 0
  if (c == "`" && index(substr(s, RLENGTH + 1), "`") > 0) return 0
  fch = c
  flen = RLENGTH
  return 1
}

function fence_close(line,   s) {
  s = line
  sub(/^ ? ? ?/, "", s)
  if (substr(s, 1, 1) != fch) return 0
  if (fch == "`") match(s, /^`+/)
  else match(s, /^~+/)
  if (RLENGTH < flen) return 0
  return substr(s, RLENGTH + 1) ~ /^[ \t]*$/
}

function body_line(line,   t, h, lvl, txt) {
  if (infence) {
    if (fence_close(line)) infence = 0
    return
  }
  if (fence_open(line)) {
    infence = 1
    if (pstate == 1) pstate = 2
    return
  }
  t = trim(line)
  lvl = 0
  if (line ~ /^ ? ? ?#+([ \t]|$)/) {
    h = line
    sub(/^ +/, "", h)
    match(h, /^#+/)
    if (RLENGTH <= 6) lvl = RLENGTH
  }
  if (lvl > 0) {
    if (pstate == 1) pstate = 2
    if (rseek && (RLEVEL == 0 || lvl <= RLEVEL)) rseek = 0
    if (!rdone && t == RHEAD) { rdone = 1; rseek = 1 }
    if (t == LHEAD) logseen = 1
    if (lvl == 1 && !h1set) {
      txt = trim(substr(h, 2))
      sub(/[ \t]+#+$/, "", txt)
      if (txt ~ /^#+$/) txt = ""
      if (txt != "") { h1 = txt; h1set = 1 }
    }
    return
  }
  if (!rdone && t == RHEAD) {
    rdone = 1; rseek = 1
    if (pstate == 1) pstate = 2
    return
  }
  if (t == LHEAD) {
    logseen = 1
    if (pstate == 1) pstate = 2
    return
  }
  if (t == "") {
    if (pstate == 1) pstate = 2
    return
  }
  if (rseek) { resv = t; rset = 1; rseek = 0 }
  if (pstate == 0) { pstate = 1; para = t }
  else if (pstate == 1) para = para " " t
}

# --- modes ---------------------------------------------------------------------

function finish_file(f,   p, out) {
  p = f
  if (substr(p, 1, 2) == "./") p = substr(p, 3)
  if (!(p in KEYOF)) {
    print "frontmatter.awk: no cache key for " p > "/dev/stderr"
    DIE = 1
    exit 3
  }
  out = outdir "/" KEYOF[p] ".json"
  print doc_end() > out
  close(out)
}

function finish_blob(   out) {
  out = outdir "/b-" oid ".json"
  print doc_end() > out
  close(out)
}

function desync() {
  print "frontmatter.awk: the git cat-file --batch stream does not match its headers (line " NR ")" > "/dev/stderr"
  DIE = 1
  exit 3
}

mode == "" { doc_line($0); next }

mode == "files" {
  if (FNR == 1) {
    if (cur != "") finish_file(cur)
    cur = FILENAME
    delete PENDING[cur]
    doc_begin()
  }
  doc_line($0)
  next
}

mode == "batch" {
  if (skipsep) {
    skipsep = 0
    if ($0 == "") next
    desync()
  }
  if (inblob) {
    rem -= length($0) + 1
    if (rem < -1) desync()
    doc_line($0)
    if (rem == 0) { finish_blob(); inblob = 0; skipsep = 1 }
    else if (rem == -1) { finish_blob(); inblob = 0 }
    next
  }
  if ($0 ~ / missing$/ || $0 ~ / ambiguous$/) next
  if ($0 !~ /^[0123456789abcdef]+ blob [0123456789]+$/) desync()
  split($0, hdr, " ")
  oid = hdr[1]
  rem = hdr[3] + 0
  doc_begin()
  if (rem == 0) { finish_blob(); skipsep = 1 }
  else inblob = 1
  next
}

# An `exit` in a rule still runs END: DIE says it was an error exit.
END {
  if (DIE) exit 3
  if (mode == "") {
    print "{\"path\":" js(path) "," substr(doc_end(), 2)
  } else if (mode == "files") {
    if (cur != "") finish_file(cur)
    for (f in PENDING) { doc_begin(); finish_file(f) }
  } else if (mode == "batch") {
    if (inblob) desync()
  }
}
