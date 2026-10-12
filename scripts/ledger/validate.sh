# shellcheck shell=bash
# scripts/ledger/validate.sh — `ledger validate`. Sourced by lib.sh; uses
# lib.sh's _lg_init, _lg_registry, _lg_emit, _lg_out_file, glob.sh's
# _lg_owner_map / _lg_registry_globs / _LG_AWK_GLOB and parse.sh's
# _LG_AWK_JS, _lg_scratch_name.
#
# --registry: the registry docs/ledger/ledgers.json against the tracked
# files (the index). Findings ({"class","detail"}), each blocking (rc 1):
#   schema              .schema is not "ledger-registry/1"
#   shape               paths / residual_paths / defined_in not a list of
#                       strings; contracts not a list of objects
#   id                  a ledger id not [a-z0-9-]{1,16}, or "unassigned"
#   duplicate-id        an id two ledgers carry
#   status              not "active" | "retired"
#   kind                not "service" | "platform"
#   contract-id         a contract id not <kind>:<name>
#   duplicate-contract  a contract id declared twice (any ledgers)
#   glob                a glob the grammar (glob.sh) rejects
#   overlap             a tracked file two ledgers claim (glob.sh's
#                       ownership: ordinary paths first, then residual;
#                       a retired ledger claims nothing)
#   unowned             a tracked file outside docs/ no ledger claims —
#                       only when some active ledger declares paths or
#                       residual_paths
# Text: "registry <class> <detail>" per finding. JSON: {"findings":[…]}.

# The contract id form: a lowercase kind, ":", a name without whitespace.
# \A … \z: jq's "$" also matches before a trailing newline.
_LG_CONTRACT_RE='\A[a-z][a-z0-9_-]*:[^[:space:]]+\z'

# _lg_registry_findings <registry> <tracked-nul> <out.jsonl>: the registry's
# findings, one JSON object per line, in the order listed above (overlap
# and unowned in path order).
_lg_registry_findings() {
  local reg="$1" tracked="$2" out="$3" s declares rc=0
  _lg_scratch_name
  s=$_LG_SN
  jq -c --arg cre "$_LG_CONTRACT_RE" '
    def strlist: type == "array" and all(.[]; type == "string");
    def f($c; $d): {class: $c, detail: $d};
    def name($i): if (.id | type) == "string" then .id else "ledgers[\($i)]" end;
    (if .schema != "ledger-registry/1"
     then f("schema"; "expected \"ledger-registry/1\", got \(.schema | tojson)") else empty end),
    (.ledgers | to_entries[] | .key as $i | .value | name($i) as $n
     | (if (.id | type) != "string" or (.id | test("\\A[a-z0-9-]{1,16}\\z") | not)
        then f("id"; "ledgers[\($i)]: \(.id | tojson) is not a ledger id ([a-z0-9-]{1,16})")
        elif .id == "unassigned" then f("id"; "ledgers[\($i)]: \"unassigned\" is reserved")
        else empty end),
       (if .status == "active" or .status == "retired" then empty
        else f("status"; "\($n): \(.status | tojson) is not active | retired") end),
       (if .kind == "service" or .kind == "platform" then empty
        else f("kind"; "\($n): \(.kind | tojson) is not service | platform") end),
       (("paths", "residual_paths") as $k
        | if has($k) and (.[$k] | strlist | not)
          then f("shape"; "\($n): \($k) is not a list of strings") else empty end),
       (if has("contracts") and (.contracts | type) != "array"
        then f("shape"; "\($n): contracts is not a list")
        else (.contracts // [])[]
          | if type != "object" then f("shape"; "\($n): a contract is not an object")
            else (if (.id | type) != "string" or (.id | test($cre) | not)
                  then f("contract-id"; "\($n): \(.id | tojson) is not <kind>:<name>") else empty end),
                 (if has("defined_in") and (.defined_in | strlist | not)
                  then f("shape"; "\($n): \(.id | tojson) defined_in is not a list of strings") else empty end)
            end
        end),
       ([(.paths, .residual_paths, ((.contracts | arrays | .[] | objects | .defined_in)))
         | arrays | .[] | strings | select(explode | any(. < 32))][]
        | f("glob"; "\($n): \(tojson) holds a control character"))),
    ([.ledgers[] | .id | strings] | group_by(.) | map(select(length > 1))[]
     | f("duplicate-id"; "\(.[0]) is the id of \(length) ledgers")),
    ([.ledgers[] | (.id | tostring) as $l | .contracts | arrays | .[] | objects
      | .id | strings | {id: ., l: $l}]
     | group_by(.id) | map(select(length > 1))[]
     | f("duplicate-contract"; "\(.[0].id) is declared by \(map(.l) | join(", "))"))
  ' "$reg" > "$out" || _lg_die "jq failed (registry checks)"

  # Globs the grammar rejects (every list, defined_in included).
  _lg_registry_globs "$reg" "$s.globs"
  LC_ALL=C awk "$_LG_AWK_JS$_LG_AWK_GLOB"'
    BEGIN { js_init() }
    {
      split($0, f, "\t")
      if (glob_ere(f[5]) == "") {
        g = (f[4] == "1") ? "!" f[5] : f[5]
        print "{\"class\":\"glob\",\"detail\":" js(f[2] ": " g ": " GLOB_ERR) "}"
      }
    }' "$s.globs" >> "$out" || _lg_die "cannot check the registry globs"

  # Ownership: overlap always; unowned (outside docs/) only when declared.
  declares=$(jq -r '[.ledgers[] | select(.status != "retired") | ((.paths, .residual_paths) | if type == "array" then length else 0 end)]
    | add // 0 | if . > 0 then 1 else 0 end' "$reg") || _lg_die "jq failed (registry paths)"
  _lg_owner_map "$tracked" "$s.own" "$reg"
  LC_ALL=C awk -v declares="$declares" "$_LG_AWK_JS"'
    BEGIN { js_init() }
    {
      t = 0; r = $0
      while ((i = index(r, "\t")) > 0) { t += i; r = substr(r, i + 1) }
      p = rep(substr($0, 1, t - 1), SOH, "\n"); o = r
      if (o ~ /^multi:/) {
        print "{\"class\":\"overlap\",\"detail\":" js(p " is claimed by " rep(substr(o, 7), ",", ", ")) "}"
      } else if (o == "-" && declares == 1 && substr(p, 1, 5) != "docs/") {
        print "{\"class\":\"unowned\",\"detail\":" js(p) "}"
      }
    }' "$s.own" >> "$out" || rc=$?
  [ "$rc" = 0 ] || _lg_die "cannot read the ownership map (awk rc $rc)"
}

# _lg_validate_registry: `validate --registry` — prints the findings, ends
# the run (rc 1 on any finding).
_lg_validate_registry() {
  local reg s rc=0
  reg=$(_lg_registry)
  _lg_scratch_name
  s=$_LG_SN
  git ls-files -z --cached > "$s.tracked" 2> "$s.err" \
    || _lg_die "git ls-files failed: $(head -n 3 "$s.err" 2>/dev/null)"
  _lg_registry_findings "$reg" "$s.tracked" "$s.findings"
  [ ! -s "$s.findings" ] || rc=1
  if [ "$_LG_FORMAT" = json ]; then
    jq -s -c '{findings: .}' "$s.findings" > "$s.payload" || _lg_die "jq failed (findings)"
    _lg_emit validate "$rc" "$s.payload"
  fi
  jq -r '"registry \(.class) \(.detail)"' "$s.findings" > "$s.text" || _lg_die "jq failed (findings text)"
  _lg_out_file "$s.text"
  _lg_emit validate "$rc"
}

# shellcheck disable=SC2154  # _OPT_* and _ARGS are set by _parse_args
cmd_ledger_validate() {
  local n=0
  _lg_init validate
  [ "$_OPT_staged" != 1 ] || n=$((n + 1))
  [ "$_OPT_all" != 1 ] || n=$((n + 1))
  [ -z "$_OPT_plan" ] || n=$((n + 1))
  [ "${#_ARGS[@]}" = 0 ] || _lg_usage "unexpected argument '${_ARGS[0]}'"
  if [ "$n" = 0 ]; then
    [ "$_OPT_registry" = 1 ] || _lg_usage "give --staged, --all, --registry or --plan <plan>"
    _lg_validate_registry
  fi
  # --staged / --all / --plan (and --registry beside them): Task 7.
  _lg_die "not implemented"
}
