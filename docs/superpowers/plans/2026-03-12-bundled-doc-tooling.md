# Bundled Doc Tooling Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add bundled shell tooling (`scripts/doc-tools.sh`) for doc freshness tracking, restructure `SKILL.md` with audit-owned discovery and orchestrator pattern, standardize doc directory structure and naming conventions, and update all templates and project docs.

**Architecture:** Single shell script with 4 subcommands (`build-index`, `check-freshness`, `update-index`, `status`) provides deterministic freshness detection via content hashing (docs) and commit SHA comparison (code). SKILL.md is restructured so audit owns discovery logic and all actions consume it. Audit and review-pr become orchestrators that dispatch scope-specific agents through a gather→plan→execute→diagram→sync→report cycle.

**Tech Stack:** Bash/Zsh, jq, git, sha256sum/shasum, standard Unix tools. Mermaid MCP for diagrams.

**Spec:** `docs/superpowers/specs/2026-03-12-bundled-doc-tooling-design.md`

---

## Chunk 1: `scripts/doc-tools.sh` — Test Harness and `build-index`

### Task 1: Create test harness skeleton

**Files:**
- Create: `scripts/test-doc-tools.sh`

- [ ] **Step 1: Write test harness with setup/teardown and first test case**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOC_TOOLS="$SCRIPT_DIR/doc-tools.sh"
PASS=0
FAIL=0
TESTS_RUN=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

setup() {
  TEST_DIR=$(mktemp -d)
  cd "$TEST_DIR"
  git init --quiet
  git config user.email "test@test.com"
  git config user.name "Test"
  mkdir -p docs src
  echo "# Overview" > docs/architecture.md
  echo "console.log('hello')" > src/index.js
  git add -A && git commit -m "init" --quiet
}

teardown() {
  cd /
  rm -rf "$TEST_DIR"
}

assert_eq() {
  local expected="$1" actual="$2" msg="${3:-}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    printf "${GREEN}  PASS${NC}: %s\n" "$msg"
  else
    FAIL=$((FAIL + 1))
    printf "${RED}  FAIL${NC}: %s\n    expected: %s\n    actual:   %s\n" "$msg" "$expected" "$actual"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if echo "$haystack" | grep -q "$needle"; then
    PASS=$((PASS + 1))
    printf "${GREEN}  PASS${NC}: %s\n" "$msg"
  else
    FAIL=$((FAIL + 1))
    printf "${RED}  FAIL${NC}: %s\n    expected to contain: %s\n    in: %s\n" "$msg" "$needle" "$haystack"
  fi
}

assert_exit_code() {
  local expected="$1" msg="${2:-}"
  shift 2
  TESTS_RUN=$((TESTS_RUN + 1))
  set +e
  "$@" >/dev/null 2>&1
  local actual=$?
  set -e
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    printf "${GREEN}  PASS${NC}: %s\n" "$msg"
  else
    FAIL=$((FAIL + 1))
    printf "${RED}  FAIL${NC}: %s\n    expected exit: %s\n    actual exit:   %s\n" "$msg" "$expected" "$actual"
  fi
}

assert_file_exists() {
  local path="$1" msg="${2:-}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ -f "$path" ]; then
    PASS=$((PASS + 1))
    printf "${GREEN}  PASS${NC}: %s\n" "$msg"
  else
    FAIL=$((FAIL + 1))
    printf "${RED}  FAIL${NC}: %s\n    file not found: %s\n" "$msg" "$path"
  fi
}

assert_json_field() {
  local json="$1" field="$2" expected="$3" msg="${4:-}"
  TESTS_RUN=$((TESTS_RUN + 1))
  local actual
  actual=$(echo "$json" | jq -r "$field")
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    printf "${GREEN}  PASS${NC}: %s\n" "$msg"
  else
    FAIL=$((FAIL + 1))
    printf "${RED}  FAIL${NC}: %s\n    field: %s\n    expected: %s\n    actual:   %s\n" "$msg" "$field" "$expected" "$actual"
  fi
}

# --- Helpers (duplicated from doc-tools.sh for test independence) ---

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# --- Tests ---

test_no_args_prints_usage() {
  echo "test: no args prints usage and exits 1"
  setup
  set +e
  local output
  output=$("$DOC_TOOLS" 2>&1)
  local exit_code=$?
  set -e
  assert_eq "1" "$exit_code" "exits 1 with no args"
  assert_contains "$output" "Usage" "prints usage"
  teardown
}

test_unknown_subcommand_prints_usage() {
  echo "test: unknown subcommand prints usage and exits 1"
  setup
  set +e
  local output
  output=$("$DOC_TOOLS" unknown 2>&1)
  local exit_code=$?
  set -e
  assert_eq "1" "$exit_code" "exits 1 with unknown subcommand"
  assert_contains "$output" "Usage" "prints usage for unknown subcommand"
  teardown
}

test_help_flag() {
  echo "test: --help prints usage and exits 1"
  setup
  set +e
  local output
  output=$("$DOC_TOOLS" --help 2>&1)
  local exit_code=$?
  set -e
  assert_eq "1" "$exit_code" "exits 1 with --help"
  assert_contains "$output" "Usage" "prints usage for --help"
  teardown
}

# --- Runner ---

run_tests() {
  echo "=== doc-tools.sh test suite ==="
  echo ""
  test_no_args_prints_usage
  test_unknown_subcommand_prints_usage
  test_help_flag
  echo ""
  echo "=== Results: $PASS passed, $FAIL failed, $TESTS_RUN total ==="
  [ "$FAIL" -eq 0 ]
}

run_tests
```

- [ ] **Step 2: Make test script executable and run — verify it fails**

```bash
chmod +x scripts/test-doc-tools.sh
bash scripts/test-doc-tools.sh
```

Expected: FAIL — `doc-tools.sh` does not exist yet.

- [ ] **Step 3: Commit test harness**

```bash
git add scripts/test-doc-tools.sh
git commit -m "test: add doc-tools.sh test harness with usage tests"
```

---

### Task 2: Implement script skeleton (usage, dependency checks, subcommand dispatch)

**Files:**
- Create: `scripts/doc-tools.sh`

- [ ] **Step 1: Create doc-tools.sh with usage, dependency checks, and subcommand routing**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Dependency checks ---

check_dependencies() {
  local missing=()
  command -v git >/dev/null 2>&1 || missing+=("git")
  command -v jq >/dev/null 2>&1 || missing+=("jq (install: brew install jq / apt install jq)")
  if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    missing+=("sha256sum or shasum")
  fi
  if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: Missing required dependencies:" >&2
    for dep in "${missing[@]}"; do
      echo "  - $dep" >&2
    done
    exit 1
  fi
}

# --- Utility functions ---

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

iso_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

repo_head() {
  git rev-parse --short HEAD
}

latest_commit_for() {
  # Returns latest commit SHA touching any of the given paths
  # Returns "null" if no commits found (path never committed)
  local result
  result=$(git log -1 --format=%H -- "$@" 2>/dev/null || true)
  if [ -z "$result" ]; then
    echo "null"
  else
    echo "$result"
  fi
}

# --- Usage ---

usage() {
  cat >&2 <<'EOF'
Usage: doc-tools.sh <subcommand> [options]

Subcommands:
  build-index         Build docs/.doc-index.json from stdin mapping
  check-freshness     Check doc freshness against index (read-only)
  update-index        Update specific entries in the index
  status <path>       Query freshness of a single doc (read-only)

Options:
  --help              Show this help message

Examples:
  echo "docs/arch.md:src/:architecture" | doc-tools.sh build-index
  doc-tools.sh check-freshness
  doc-tools.sh check-freshness --code-refs src/auth/ src/models/
  doc-tools.sh update-index docs/arch.md docs/api.md
  doc-tools.sh status docs/arch.md
EOF
  exit 1
}

# --- Subcommand stubs ---

cmd_build_index() {
  echo "ERROR: build-index not yet implemented" >&2
  exit 1
}

cmd_check_freshness() {
  echo "ERROR: check-freshness not yet implemented" >&2
  exit 1
}

cmd_update_index() {
  echo "ERROR: update-index not yet implemented" >&2
  exit 1
}

cmd_status() {
  echo "ERROR: status not yet implemented" >&2
  exit 1
}

# --- Main ---

main() {
  check_dependencies

  if [ $# -eq 0 ]; then
    usage
  fi

  case "$1" in
    build-index)
      shift
      cmd_build_index "$@"
      ;;
    check-freshness)
      shift
      cmd_check_freshness "$@"
      ;;
    update-index)
      shift
      cmd_update_index "$@"
      ;;
    status)
      shift
      cmd_status "$@"
      ;;
    --help|-h)
      usage
      ;;
    *)
      echo "ERROR: Unknown subcommand '$1'" >&2
      echo "" >&2
      usage
      ;;
  esac
}

main "$@"
```

- [ ] **Step 2: Make executable and run tests**

```bash
chmod +x scripts/doc-tools.sh
bash scripts/test-doc-tools.sh
```

Expected: All 3 tests PASS (usage/help tests).

- [ ] **Step 3: Commit**

```bash
git add scripts/doc-tools.sh
git commit -m "feat: add doc-tools.sh skeleton with usage, deps, subcommand routing"
```

---

### Task 3: Write `build-index` tests

**Files:**
- Modify: `scripts/test-doc-tools.sh`

- [ ] **Step 1: Add build-index test cases to test harness**

Add these test functions before the `run_tests` function:

```bash
test_build_index_creates_index() {
  echo "test: build-index creates docs/.doc-index.json"
  setup
  local mapping="docs/architecture.md:src/:architecture"
  echo "$mapping" | "$DOC_TOOLS" build-index
  assert_file_exists "docs/.doc-index.json" "index file created"
  local json
  json=$(cat docs/.doc-index.json)
  assert_json_field "$json" ".version" "1" "version is 1"
  assert_json_field "$json" ".generated_by" "doc-superpowers" "generated_by is doc-superpowers"
  teardown
}

test_build_index_hashes_doc() {
  echo "test: build-index stores content hash"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  local json
  json=$(cat docs/.doc-index.json)
  local stored_hash
  stored_hash=$(echo "$json" | jq -r '.docs["docs/architecture.md"].content_hash')
  local expected_hash
  expected_hash="sha256:$(hash_file docs/architecture.md)"
  assert_eq "$expected_hash" "$stored_hash" "content hash matches"
  teardown
}

test_build_index_stores_code_commit() {
  echo "test: build-index stores latest code commit"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  local json
  json=$(cat docs/.doc-index.json)
  local stored_commit
  stored_commit=$(echo "$json" | jq -r '.docs["docs/architecture.md"].code_commit')
  local expected_commit
  expected_commit=$(git log -1 --format=%H -- src/)
  assert_eq "$expected_commit" "$stored_commit" "code_commit matches latest commit for src/"
  teardown
}

test_build_index_multiple_code_refs() {
  echo "test: build-index handles multiple comma-separated code_refs"
  setup
  mkdir -p lib
  echo "module" > lib/util.js
  git add -A && git commit -m "add lib" --quiet
  echo "docs/architecture.md:src/,lib/:architecture" | "$DOC_TOOLS" build-index
  local json
  json=$(cat docs/.doc-index.json)
  local code_refs
  code_refs=$(echo "$json" | jq -r '.docs["docs/architecture.md"].code_refs | length')
  assert_eq "2" "$code_refs" "code_refs has 2 entries"
  teardown
}

test_build_index_multiple_docs() {
  echo "test: build-index handles multiple docs"
  setup
  echo "# Workflows" > docs/workflows.md
  git add -A && git commit -m "add workflows" --quiet
  printf "docs/architecture.md:src/:architecture\ndocs/workflows.md:src/:workflows" | "$DOC_TOOLS" build-index
  local json
  json=$(cat docs/.doc-index.json)
  local doc_count
  doc_count=$(echo "$json" | jq '.docs | length')
  assert_eq "2" "$doc_count" "index has 2 doc entries"
  teardown
}

test_build_index_sets_status_current() {
  echo "test: build-index sets status to current"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  local json
  json=$(cat docs/.doc-index.json)
  assert_json_field "$json" '.docs["docs/architecture.md"].status' "current" "status is current"
  assert_json_field "$json" '.docs["docs/architecture.md"].replaces' "null" "replaces is null"
  assert_json_field "$json" '.docs["docs/architecture.md"].superseded_by' "null" "superseded_by is null"
  teardown
}

test_build_index_null_code_commit_for_untracked() {
  echo "test: build-index sets null code_commit for never-committed paths"
  setup
  echo "docs/architecture.md:nonexistent/:architecture" | "$DOC_TOOLS" build-index
  local json
  json=$(cat docs/.doc-index.json)
  assert_json_field "$json" '.docs["docs/architecture.md"].code_commit' "null" "code_commit is null for untracked path"
  assert_json_field "$json" '.docs["docs/architecture.md"].status' "current" "status still current"
  teardown
}
```

Add them to `run_tests`:

```bash
run_tests() {
  echo "=== doc-tools.sh test suite ==="
  echo ""
  test_no_args_prints_usage
  test_unknown_subcommand_prints_usage
  test_help_flag
  test_build_index_creates_index
  test_build_index_hashes_doc
  test_build_index_stores_code_commit
  test_build_index_multiple_code_refs
  test_build_index_multiple_docs
  test_build_index_sets_status_current
  test_build_index_null_code_commit_for_untracked
  echo ""
  echo "=== Results: $PASS passed, $FAIL failed, $TESTS_RUN total ==="
  [ "$FAIL" -eq 0 ]
}
```

- [ ] **Step 2: Run tests — verify build-index tests fail**

```bash
bash scripts/test-doc-tools.sh
```

Expected: First 3 pass, build-index tests FAIL (stub returns error).

- [ ] **Step 3: Commit tests**

```bash
git add scripts/test-doc-tools.sh
git commit -m "test: add build-index test cases"
```

---

### Task 4: Implement `build-index`

**Files:**
- Modify: `scripts/doc-tools.sh`

- [ ] **Step 1: Replace `cmd_build_index` stub with implementation**

```bash
cmd_build_index() {
  local now
  now=$(iso_now)
  local head
  head=$(repo_head)
  local full_head
  full_head=$(git rev-parse HEAD)

  # Read mapping from stdin: doc_path:comma_code_refs:doc_type
  local entries=()
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    entries+=("$line")
  done

  if [ ${#entries[@]} -eq 0 ]; then
    echo "ERROR: No mapping data received on stdin" >&2
    echo "Format: doc_path:comma_code_refs:doc_type (one per line)" >&2
    exit 1
  fi

  # Build JSON entries
  local docs_json="{}"
  for entry in "${entries[@]}"; do
    local doc_path code_refs_csv doc_type
    doc_path=$(echo "$entry" | cut -d: -f1)
    code_refs_csv=$(echo "$entry" | cut -d: -f2)
    doc_type=$(echo "$entry" | cut -d: -f3)

    # Validate doc exists
    if [ ! -f "$doc_path" ]; then
      echo "ERROR: Doc file not found: $doc_path" >&2
      exit 1
    fi

    # Hash doc
    local content_hash
    content_hash="sha256:$(hash_file "$doc_path")"

    # Split code_refs on comma
    local code_refs_json="[]"
    IFS=',' read -ra refs <<< "$code_refs_csv"
    code_refs_json=$(printf '%s\n' "${refs[@]}" | jq -R . | jq -s .)

    # Get latest commit for code_refs
    local code_commit
    code_commit=$(latest_commit_for "${refs[@]}")

    # Build entry
    local entry_json
    entry_json=$(jq -n \
      --arg content_hash "$content_hash" \
      --argjson code_refs "$code_refs_json" \
      --arg code_commit "$code_commit" \
      --arg doc_type "$doc_type" \
      --arg last_verified "$now" \
      '{
        content_hash: $content_hash,
        code_refs: $code_refs,
        code_commit: (if $code_commit == "null" then null else $code_commit end),
        doc_type: $doc_type,
        status: "current",
        replaces: null,
        superseded_by: null,
        last_verified: $last_verified
      }')

    docs_json=$(echo "$docs_json" | jq --arg path "$doc_path" --argjson entry "$entry_json" '.[$path] = $entry')
  done

  # Assemble full index
  local index_json
  index_json=$(jq -n \
    --argjson version 1 \
    --arg generated_by "doc-superpowers" \
    --arg generated_at "$now" \
    --arg build_commit "$full_head" \
    --argjson docs "$docs_json" \
    '{
      version: $version,
      generated_by: $generated_by,
      generated_at: $generated_at,
      build_commit: $build_commit,
      docs: $docs
    }')

  # Write index
  echo "$index_json" > docs/.doc-index.json
  echo "Built index with $(echo "$docs_json" | jq 'length') entries at docs/.doc-index.json" >&2
}
```

- [ ] **Step 2: Run tests — verify all pass**

```bash
bash scripts/test-doc-tools.sh
```

Expected: All 10 tests PASS.

- [ ] **Step 3: Commit**

```bash
git add scripts/doc-tools.sh
git commit -m "feat: implement build-index subcommand"
```

---

## Chunk 2: `scripts/doc-tools.sh` — `check-freshness`, `update-index`, `status`

### Task 5: Write `check-freshness` tests and implement

**Files:**
- Modify: `scripts/test-doc-tools.sh`
- Modify: `scripts/doc-tools.sh`

- [ ] **Step 1: Add check-freshness test cases**

```bash
test_check_freshness_requires_index() {
  echo "test: check-freshness exits 1 when no index"
  setup
  set +e
  local output
  output=$("$DOC_TOOLS" check-freshness 2>&1)
  local exit_code=$?
  set -e
  assert_eq "1" "$exit_code" "exits 1 without index"
  assert_contains "$output" "doc-index.json" "mentions missing index"
  teardown
}

test_check_freshness_current() {
  echo "test: check-freshness reports current when nothing changed"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  local output
  output=$("$DOC_TOOLS" check-freshness)
  assert_json_field "$output" '.summary.current' "1" "1 current doc"
  assert_json_field "$output" '.summary.stale' "0" "0 stale docs"
  assert_json_field "$output" '.docs["docs/architecture.md"].status' "current" "doc is current"
  teardown
}

test_check_freshness_stale_after_code_change() {
  echo "test: check-freshness reports stale after code change"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  # Change code
  echo "updated" >> src/index.js
  git add -A && git commit -m "code change" --quiet
  local output
  output=$("$DOC_TOOLS" check-freshness)
  assert_json_field "$output" '.summary.stale' "1" "1 stale doc"
  assert_json_field "$output" '.docs["docs/architecture.md"].status' "stale" "doc is stale"
  assert_json_field "$output" '.docs["docs/architecture.md"].reason' "code_changed" "reason is code_changed"
  teardown
}

test_check_freshness_doc_modified() {
  echo "test: check-freshness detects doc modification"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  # Modify doc without code change
  echo "added section" >> docs/architecture.md
  local output
  output=$("$DOC_TOOLS" check-freshness)
  assert_json_field "$output" '.docs["docs/architecture.md"].doc_modified' "true" "doc_modified is true"
  assert_json_field "$output" '.docs["docs/architecture.md"].status' "current" "status still current (no code change)"
  teardown
}

test_check_freshness_missing_doc() {
  echo "test: check-freshness reports missing doc"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  rm docs/architecture.md
  local output
  output=$("$DOC_TOOLS" check-freshness)
  assert_json_field "$output" '.summary.missing' "1" "1 missing doc"
  assert_json_field "$output" '.docs["docs/architecture.md"].status' "missing" "doc is missing"
  teardown
}

test_check_freshness_deprecated_preserved() {
  echo "test: check-freshness preserves deprecated status"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  # Manually set status to deprecated
  local tmp
  tmp=$(jq '.docs["docs/architecture.md"].status = "deprecated"' docs/.doc-index.json)
  echo "$tmp" > docs/.doc-index.json
  local output
  output=$("$DOC_TOOLS" check-freshness)
  assert_json_field "$output" '.summary.deprecated' "1" "1 deprecated doc"
  assert_json_field "$output" '.docs["docs/architecture.md"].status' "deprecated" "deprecated preserved"
  teardown
}

test_check_freshness_commits_behind() {
  echo "test: check-freshness counts commits behind"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  echo "change1" >> src/index.js && git add -A && git commit -m "c1" --quiet
  echo "change2" >> src/index.js && git add -A && git commit -m "c2" --quiet
  echo "change3" >> src/index.js && git add -A && git commit -m "c3" --quiet
  local output
  output=$("$DOC_TOOLS" check-freshness)
  assert_json_field "$output" '.docs["docs/architecture.md"].commits_behind' "3" "3 commits behind"
  teardown
}

test_check_freshness_code_refs_filter() {
  echo "test: check-freshness --code-refs filters entries"
  setup
  mkdir -p lib
  echo "util" > lib/util.js
  echo "# API" > docs/api.md
  git add -A && git commit -m "add lib and api" --quiet
  printf "docs/architecture.md:src/:architecture\ndocs/api.md:lib/:api-contracts" | "$DOC_TOOLS" build-index
  # Change only src/
  echo "changed" >> src/index.js && git add -A && git commit -m "src change" --quiet
  # Filter to only src/ — should only show architecture.md
  local output
  output=$("$DOC_TOOLS" check-freshness --code-refs src/)
  local doc_count
  doc_count=$(echo "$output" | jq '.docs | length')
  assert_eq "1" "$doc_count" "only 1 doc checked with --code-refs src/"
  assert_json_field "$output" '.docs["docs/architecture.md"].status' "stale" "architecture.md is stale"
  teardown
}

test_check_freshness_code_refs_bidirectional_prefix() {
  echo "test: check-freshness --code-refs matches bidirectionally"
  setup
  mkdir -p src/auth
  echo "auth" > src/auth/login.js
  git add -A && git commit -m "add auth" --quiet
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  echo "changed" >> src/auth/login.js && git add -A && git commit -m "auth change" --quiet
  # Filter with more specific path — should match because src/auth/ is a prefix match of src/
  local output
  output=$("$DOC_TOOLS" check-freshness --code-refs src/auth/)
  local doc_count
  doc_count=$(echo "$output" | jq '.docs | length')
  assert_eq "1" "$doc_count" "bidirectional prefix match works"
  teardown
}
```

Add to `run_tests`:

```bash
  test_check_freshness_requires_index
  test_check_freshness_current
  test_check_freshness_stale_after_code_change
  test_check_freshness_doc_modified
  test_check_freshness_missing_doc
  test_check_freshness_deprecated_preserved
  test_check_freshness_commits_behind
  test_check_freshness_code_refs_filter
  test_check_freshness_code_refs_bidirectional_prefix
```

- [ ] **Step 2: Run tests — verify check-freshness tests fail**

```bash
bash scripts/test-doc-tools.sh
```

Expected: build-index tests pass, check-freshness tests FAIL.

- [ ] **Step 3: Implement `cmd_check_freshness`**

Replace the stub in `scripts/doc-tools.sh`:

```bash
cmd_check_freshness() {
  local index_file="docs/.doc-index.json"
  if [ ! -f "$index_file" ]; then
    echo "ERROR: $index_file not found. Run 'doc-tools.sh build-index' first." >&2
    exit 1
  fi

  # Parse --code-refs filter
  local filter_refs=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --code-refs)
        shift
        while [ $# -gt 0 ] && [[ "$1" != --* ]]; do
          filter_refs+=("$1")
          shift
        done
        ;;
      *)
        echo "ERROR: Unknown option '$1'" >&2
        exit 1
        ;;
    esac
  done

  local index
  index=$(cat "$index_file")
  local now
  now=$(iso_now)
  local head
  head=$(repo_head)

  local summary_current=0 summary_stale=0 summary_missing=0 summary_deprecated=0
  local docs_json="{}"

  # Iterate over each doc in the index
  local doc_paths
  doc_paths=$(echo "$index" | jq -r '.docs | keys[]')

  while IFS= read -r doc_path; do
    [ -z "$doc_path" ] && continue

    local entry
    entry=$(echo "$index" | jq -r --arg p "$doc_path" '.docs[$p]')
    local stored_status
    stored_status=$(echo "$entry" | jq -r '.status')
    local stored_hash
    stored_hash=$(echo "$entry" | jq -r '.content_hash')
    local stored_commit
    stored_commit=$(echo "$entry" | jq -r '.code_commit')
    local stored_verified
    stored_verified=$(echo "$entry" | jq -r '.last_verified')
    local doc_type
    doc_type=$(echo "$entry" | jq -r '.doc_type')
    local code_refs
    code_refs=$(echo "$entry" | jq -r '.code_refs[]')

    # Apply --code-refs filter
    if [ ${#filter_refs[@]} -gt 0 ]; then
      local matched=false
      for fref in "${filter_refs[@]}"; do
        while IFS= read -r cref; do
          # Bidirectional prefix match
          if [[ "$fref" == "$cref"* ]] || [[ "$cref" == "$fref"* ]]; then
            matched=true
            break 2
          fi
        done <<< "$code_refs"
      done
      if [ "$matched" = false ]; then
        continue
      fi
    fi

    # Deprecated is terminal — report and skip freshness check
    if [ "$stored_status" = "deprecated" ]; then
      summary_deprecated=$((summary_deprecated + 1))
      local dep_entry
      dep_entry=$(jq -n --arg dt "$doc_type" --arg s "deprecated" '{doc_type: $dt, status: $s}')
      docs_json=$(echo "$docs_json" | jq --arg p "$doc_path" --argjson e "$dep_entry" '.[$p] = $e')
      continue
    fi

    # Check if doc file exists
    if [ ! -f "$doc_path" ]; then
      summary_missing=$((summary_missing + 1))
      local miss_entry
      miss_entry=$(jq -n --arg dt "$doc_type" '{doc_type: $dt, status: "missing"}')
      docs_json=$(echo "$docs_json" | jq --arg p "$doc_path" --argjson e "$miss_entry" '.[$p] = $e')
      continue
    fi

    # Compare doc hash
    local current_hash="sha256:$(hash_file "$doc_path")"
    local doc_modified=false
    if [ "$current_hash" != "$stored_hash" ]; then
      doc_modified=true
    fi

    # Compare code commit
    local refs_array=()
    while IFS= read -r ref; do
      [ -n "$ref" ] && refs_array+=("$ref")
    done <<< "$code_refs"

    local current_commit
    current_commit=$(latest_commit_for "${refs_array[@]}")

    local status="current"
    local reason=""
    local code_refs_changed="[]"
    local commits_behind=0

    if [ "$stored_commit" != "null" ] && [ "$current_commit" != "null" ] && [ "$stored_commit" != "$current_commit" ]; then
      status="stale"
      reason="code_changed"

      # Find which code_refs changed
      local changed_refs=()
      for ref in "${refs_array[@]}"; do
        local ref_commit
        ref_commit=$(latest_commit_for "$ref")
        if [ "$ref_commit" != "$stored_commit" ] && [ "$ref_commit" != "null" ]; then
          changed_refs+=("$ref")
        fi
      done
      code_refs_changed=$(printf '%s\n' "${changed_refs[@]}" | jq -R . | jq -s .)

      # Count commits behind
      commits_behind=$(git rev-list --count "$stored_commit"..HEAD -- "${refs_array[@]}" 2>/dev/null || echo "0")
    fi

    if [ "$status" = "stale" ]; then
      summary_stale=$((summary_stale + 1))
      local stale_entry
      stale_entry=$(jq -n \
        --arg dt "$doc_type" \
        --arg s "$status" \
        --arg r "$reason" \
        --argjson dm "$doc_modified" \
        --argjson crc "$code_refs_changed" \
        --argjson cb "$commits_behind" \
        --arg lv "$stored_verified" \
        '{doc_type: $dt, status: $s, reason: $r, doc_modified: $dm, code_refs_changed: $crc, commits_behind: $cb, last_verified: $lv}')
      docs_json=$(echo "$docs_json" | jq --arg p "$doc_path" --argjson e "$stale_entry" '.[$p] = $e')
    else
      summary_current=$((summary_current + 1))
      local curr_entry
      curr_entry=$(jq -n \
        --arg dt "$doc_type" \
        --arg s "current" \
        --argjson dm "$doc_modified" \
        --arg lv "$stored_verified" \
        '{doc_type: $dt, status: $s, doc_modified: $dm, last_verified: $lv}')
      docs_json=$(echo "$docs_json" | jq --arg p "$doc_path" --argjson e "$curr_entry" '.[$p] = $e')
    fi

  done <<< "$doc_paths"

  # Assemble output
  jq -n \
    --arg checked_at "$now" \
    --arg repo_head "$head" \
    --argjson current "$summary_current" \
    --argjson stale "$summary_stale" \
    --argjson missing "$summary_missing" \
    --argjson deprecated "$summary_deprecated" \
    --argjson docs "$docs_json" \
    '{
      checked_at: $checked_at,
      repo_head: $repo_head,
      summary: {current: $current, stale: $stale, missing: $missing, deprecated: $deprecated},
      docs: $docs
    }'
}
```

- [ ] **Step 4: Run tests — verify all pass**

```bash
bash scripts/test-doc-tools.sh
```

Expected: All tests PASS (usage + build-index + check-freshness).

- [ ] **Step 5: Commit**

```bash
git add scripts/doc-tools.sh scripts/test-doc-tools.sh
git commit -m "feat: implement check-freshness subcommand with filter support"
```

---

### Task 6: Write `update-index` tests and implement

**Files:**
- Modify: `scripts/test-doc-tools.sh`
- Modify: `scripts/doc-tools.sh`

- [ ] **Step 1: Add update-index test cases**

```bash
test_update_index_refreshes_entry() {
  echo "test: update-index refreshes specified entries"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  # Change code
  echo "updated" >> src/index.js
  git add -A && git commit -m "code change" --quiet
  # Update doc to match
  echo "# Updated Architecture" > docs/architecture.md
  "$DOC_TOOLS" update-index docs/architecture.md
  local json
  json=$(cat docs/.doc-index.json)
  assert_json_field "$json" '.docs["docs/architecture.md"].status' "current" "status reset to current"
  local new_hash
  new_hash=$(echo "$json" | jq -r '.docs["docs/architecture.md"].content_hash')
  local expected_hash="sha256:$(hash_file docs/architecture.md)"
  assert_eq "$expected_hash" "$new_hash" "hash updated"
  teardown
}

test_update_index_preserves_build_commit() {
  echo "test: update-index does not change build_commit"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  local original_build_commit
  original_build_commit=$(jq -r '.build_commit' docs/.doc-index.json)
  echo "updated" >> src/index.js
  git add -A && git commit -m "code change" --quiet
  "$DOC_TOOLS" update-index docs/architecture.md
  local new_build_commit
  new_build_commit=$(jq -r '.build_commit' docs/.doc-index.json)
  assert_eq "$original_build_commit" "$new_build_commit" "build_commit unchanged"
  teardown
}

test_update_index_preserves_replaces() {
  echo "test: update-index preserves replaces/superseded_by"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  # Manually set replaces
  local tmp
  tmp=$(jq '.docs["docs/architecture.md"].replaces = "docs/old-arch.md"' docs/.doc-index.json)
  echo "$tmp" > docs/.doc-index.json
  "$DOC_TOOLS" update-index docs/architecture.md
  local json
  json=$(cat docs/.doc-index.json)
  assert_json_field "$json" '.docs["docs/architecture.md"].replaces' "docs/old-arch.md" "replaces preserved"
  teardown
}

test_update_index_unknown_path_errors() {
  echo "test: update-index errors for path not in index"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  set +e
  local output
  output=$("$DOC_TOOLS" update-index docs/unknown.md 2>&1)
  local exit_code=$?
  set -e
  assert_eq "1" "$exit_code" "exits 1 for unknown path"
  assert_contains "$output" "build-index" "suggests build-index"
  teardown
}
```

Add to `run_tests`:

```bash
  test_update_index_refreshes_entry
  test_update_index_preserves_build_commit
  test_update_index_preserves_replaces
  test_update_index_unknown_path_errors
```

- [ ] **Step 2: Run tests — verify update-index tests fail**

```bash
bash scripts/test-doc-tools.sh
```

Expected: update-index tests FAIL (stub).

- [ ] **Step 3: Implement `cmd_update_index`**

```bash
cmd_update_index() {
  local index_file="docs/.doc-index.json"
  if [ ! -f "$index_file" ]; then
    echo "ERROR: $index_file not found. Run 'doc-tools.sh build-index' first." >&2
    exit 1
  fi

  if [ $# -eq 0 ]; then
    echo "ERROR: No doc paths specified" >&2
    echo "Usage: doc-tools.sh update-index <doc_path> [doc_path ...]" >&2
    exit 1
  fi

  local index
  index=$(cat "$index_file")
  local now
  now=$(iso_now)
  local refreshed=()

  for doc_path in "$@"; do
    # Check if path exists in index
    local exists
    exists=$(echo "$index" | jq --arg p "$doc_path" '.docs | has($p)')
    if [ "$exists" != "true" ]; then
      echo "ERROR: '$doc_path' not in index. Use 'doc-tools.sh build-index' to add new entries." >&2
      exit 1
    fi

    # Check if doc file exists
    if [ ! -f "$doc_path" ]; then
      echo "ERROR: Doc file not found: $doc_path" >&2
      exit 1
    fi

    # Re-hash doc
    local content_hash="sha256:$(hash_file "$doc_path")"

    # Get code_refs from existing entry
    local code_refs
    code_refs=$(echo "$index" | jq -r --arg p "$doc_path" '.docs[$p].code_refs[]')
    local refs_array=()
    while IFS= read -r ref; do
      [ -n "$ref" ] && refs_array+=("$ref")
    done <<< "$code_refs"

    # Re-query latest commit
    local code_commit
    code_commit=$(latest_commit_for "${refs_array[@]}")

    # Update entry — preserve replaces/superseded_by
    index=$(echo "$index" | jq \
      --arg p "$doc_path" \
      --arg ch "$content_hash" \
      --arg cc "$code_commit" \
      --arg lv "$now" \
      '.docs[$p].content_hash = $ch |
       .docs[$p].code_commit = (if $cc == "null" then null else $cc end) |
       .docs[$p].status = "current" |
       .docs[$p].last_verified = $lv')

    refreshed+=("$doc_path")
  done

  # Update generated_at but NOT build_commit
  index=$(echo "$index" | jq --arg ga "$now" '.generated_at = $ga')

  echo "$index" > "$index_file"

  echo "Updated ${#refreshed[@]} entries:" >&2
  for r in "${refreshed[@]}"; do
    echo "  - $r" >&2
  done
}
```

- [ ] **Step 4: Run tests — verify all pass**

```bash
bash scripts/test-doc-tools.sh
```

Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/doc-tools.sh scripts/test-doc-tools.sh
git commit -m "feat: implement update-index subcommand"
```

---

### Task 7: Write `status` tests and implement

**Files:**
- Modify: `scripts/test-doc-tools.sh`
- Modify: `scripts/doc-tools.sh`

- [ ] **Step 1: Add status test cases**

```bash
test_status_single_doc() {
  echo "test: status reports single doc freshness"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  local output
  output=$("$DOC_TOOLS" status docs/architecture.md)
  assert_json_field "$output" '.path' "docs/architecture.md" "path field set"
  assert_json_field "$output" '.doc_type' "architecture" "doc_type field set"
  assert_json_field "$output" '.status' "current" "status is current"
  teardown
}

test_status_stale_doc() {
  echo "test: status reports stale after code change"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  echo "changed" >> src/index.js && git add -A && git commit -m "c1" --quiet
  local output
  output=$("$DOC_TOOLS" status docs/architecture.md)
  assert_json_field "$output" '.status' "stale" "status is stale"
  assert_json_field "$output" '.reason' "code_changed" "reason is code_changed"
  teardown
}

test_status_unknown_path() {
  echo "test: status errors for unknown path"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  assert_exit_code 1 "exits 1 for unknown path" "$DOC_TOOLS" status docs/unknown.md
  teardown
}

test_status_requires_path_arg() {
  echo "test: status requires a path argument"
  setup
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
  assert_exit_code 1 "exits 1 without path" "$DOC_TOOLS" status
  teardown
}
```

Add to `run_tests`:

```bash
  test_status_single_doc
  test_status_stale_doc
  test_status_unknown_path
  test_status_requires_path_arg
```

- [ ] **Step 2: Run tests — verify status tests fail**

```bash
bash scripts/test-doc-tools.sh
```

- [ ] **Step 3: Implement `cmd_status`**

```bash
cmd_status() {
  local index_file="docs/.doc-index.json"
  if [ ! -f "$index_file" ]; then
    echo "ERROR: $index_file not found. Run 'doc-tools.sh build-index' first." >&2
    exit 1
  fi

  if [ $# -eq 0 ]; then
    echo "ERROR: No doc path specified" >&2
    echo "Usage: doc-tools.sh status <doc_path>" >&2
    exit 1
  fi

  local doc_path="$1"
  local index
  index=$(cat "$index_file")

  # Check if path exists in index
  local exists
  exists=$(echo "$index" | jq --arg p "$doc_path" '.docs | has($p)')
  if [ "$exists" != "true" ]; then
    echo "ERROR: '$doc_path' not in index" >&2
    exit 1
  fi

  local entry
  entry=$(echo "$index" | jq -r --arg p "$doc_path" '.docs[$p]')
  local stored_status
  stored_status=$(echo "$entry" | jq -r '.status')
  local stored_hash
  stored_hash=$(echo "$entry" | jq -r '.content_hash')
  local stored_commit
  stored_commit=$(echo "$entry" | jq -r '.code_commit')
  local stored_verified
  stored_verified=$(echo "$entry" | jq -r '.last_verified')
  local doc_type
  doc_type=$(echo "$entry" | jq -r '.doc_type')

  # Deprecated — report and exit
  if [ "$stored_status" = "deprecated" ]; then
    jq -n --arg p "$doc_path" --arg dt "$doc_type" '{path: $p, doc_type: $dt, status: "deprecated"}'
    return
  fi

  # Missing doc
  if [ ! -f "$doc_path" ]; then
    jq -n --arg p "$doc_path" --arg dt "$doc_type" '{path: $p, doc_type: $dt, status: "missing"}'
    return
  fi

  # Compare
  local current_hash="sha256:$(hash_file "$doc_path")"
  local doc_modified=false
  if [ "$current_hash" != "$stored_hash" ]; then
    doc_modified=true
  fi

  local code_refs
  code_refs=$(echo "$entry" | jq -r '.code_refs[]')
  local refs_array=()
  while IFS= read -r ref; do
    [ -n "$ref" ] && refs_array+=("$ref")
  done <<< "$code_refs"

  local current_commit
  current_commit=$(latest_commit_for "${refs_array[@]}")

  if [ "$stored_commit" != "null" ] && [ "$current_commit" != "null" ] && [ "$stored_commit" != "$current_commit" ]; then
    # Stale
    local changed_refs=()
    for ref in "${refs_array[@]}"; do
      local ref_commit
      ref_commit=$(latest_commit_for "$ref")
      if [ "$ref_commit" != "$stored_commit" ] && [ "$ref_commit" != "null" ]; then
        changed_refs+=("$ref")
      fi
    done
    local code_refs_changed
    code_refs_changed=$(printf '%s\n' "${changed_refs[@]}" | jq -R . | jq -s .)
    local commits_behind
    commits_behind=$(git rev-list --count "$stored_commit"..HEAD -- "${refs_array[@]}" 2>/dev/null || echo "0")

    jq -n \
      --arg p "$doc_path" \
      --arg dt "$doc_type" \
      --argjson dm "$doc_modified" \
      --argjson crc "$code_refs_changed" \
      --argjson cb "$commits_behind" \
      --arg lv "$stored_verified" \
      '{path: $p, doc_type: $dt, status: "stale", reason: "code_changed", doc_modified: $dm, code_refs_changed: $crc, commits_behind: $cb, last_verified: $lv}'
  else
    jq -n \
      --arg p "$doc_path" \
      --arg dt "$doc_type" \
      --argjson dm "$doc_modified" \
      --arg lv "$stored_verified" \
      '{path: $p, doc_type: $dt, status: "current", doc_modified: $dm, last_verified: $lv}'
  fi
}
```

- [ ] **Step 4: Run tests — verify all pass**

```bash
bash scripts/test-doc-tools.sh
```

Expected: All tests PASS (all 4 subcommands complete).

- [ ] **Step 5: Commit**

```bash
git add scripts/doc-tools.sh scripts/test-doc-tools.sh
git commit -m "feat: implement status subcommand — doc-tools.sh complete"
```

---

## Chunk 3: `references/doc-spec.md` — New Templates and Updated Paths

### Task 8: Update diagram paths to co-located model

**Files:**
- Modify: `references/doc-spec.md`

- [ ] **Step 1: Rename template headings and update diagram paths**

In `references/doc-spec.md`, make these changes:

1. **Rename template headings** to match new directory structure:
   - `## docs/architecture.md` → `## docs/architecture/system-overview.md`
   - `## docs/workflows.md` → `## docs/workflows/{name}.md` (this is now a per-workflow template, not monolithic)
   - `## docs/getting-started.md` → `## docs/guides/getting-started.md`
   - `## docs/data-layer.md` → keep as-is (stays at `docs/` root per spec)

2. **Relative diagram paths** within templates stay the same (e.g., `diagrams/c4-context.png`) since docs are now co-located with their `diagrams/` directories. No path changes needed inside the template content.

3. In the `Diagram File Naming` section at the bottom, replace:
   ```
   Save all diagrams to `docs/diagrams/` with these names:
   ```
   With:
   ```
   Diagrams are co-located with their doc section:

   | Diagram | Location | Filename |
   |---------|----------|----------|
   | C4 Context | `docs/architecture/diagrams/` | `c4-context.png` |
   | C4 Container | `docs/architecture/diagrams/` | `c4-container.png` |
   | Component | `docs/architecture/diagrams/` | `{component}.png` |
   | ERD | `docs/architecture/diagrams/` | `erd.png` |
   | Primary workflow | `docs/workflows/diagrams/` | `workflow-primary.png` |
   | Additional workflows | `docs/workflows/diagrams/` | `workflow-{name}.png` |
   | Sequence diagrams | `docs/workflows/diagrams/` | `sequence-{name}.png` |
   | State diagram | `docs/workflows/diagrams/` | `state-{name}.png` |
   ```

- [ ] **Step 2: Verify the changes are consistent**

```bash
rg 'docs/diagrams/' references/doc-spec.md
```

Expected: No matches (all paths updated to co-located model).

- [ ] **Step 3: Commit**

```bash
git add references/doc-spec.md
git commit -m "refactor: update doc-spec diagram paths to co-located model"
```

---

### Task 9: Add new doc type templates

**Files:**
- Modify: `references/doc-spec.md`

- [ ] **Step 1: Add architecture component template**

Append after the `docs/architecture.md` section:

```markdown
---

## docs/architecture/{component}.md

Per-component architecture doc. Create one for each major component/domain discovered by scope detection.

\`\`\`markdown
# {Component Name}

## Overview
<!-- 2-3 sentence summary of what this component does -->

## Responsibilities
<!-- Bulleted list of what this component owns -->

## Dependencies
<!-- What this component depends on -->

| Dependency | Type | Purpose |
|-----------|------|---------|
| | internal/external | |

## Key Interfaces
<!-- Public API / entry points -->

## Diagrams

![Component](diagrams/{component}.png)

## Key Decisions
<!-- Component-specific ADR references -->
\`\`\`
```

- [ ] **Step 2: Add spec template**

```markdown
---

## docs/specs/template.md

Template for new specs. Copy to create `SPEC-{CAT}-NNN-{slug}.md`.

\`\`\`markdown
# SPEC-{CAT}-{NNN}: {Title}

**Status**: Draft | In Review | Approved | Implemented | Superseded
**Category**: {CAT}
**Created**: YYYY-MM-DD
**Author**: {name}
**Supersedes**: {path or "none"}
**Superseded by**: {path or "none"}

## Summary
<!-- 2-3 sentences describing what this spec defines -->

## Motivation
<!-- Why this spec is needed -->

## Design
<!-- Detailed design description -->

## Implementation Notes
<!-- Key implementation considerations -->

## Testing Strategy
<!-- How to verify the implementation matches this spec -->

## Open Questions
<!-- Unresolved questions (remove when resolved) -->
\`\`\`
```

- [ ] **Step 3: Add ADR template**

```markdown
---

## docs/adr/template.md

Template for architecture decision records. Copy to create `ADR-NNN-{slug}.md`.

\`\`\`markdown
# ADR-{NNN}: {Title}

**Status**: Proposed | Active | Superseded | Deprecated
**Date**: YYYY-MM-DD
**Supersedes**: {ADR number or "none"}
**Superseded by**: {ADR number or "none"}

## Context
<!-- What is the issue that we're seeing that is motivating this decision? -->

## Decision
<!-- What is the change that we're proposing and/or doing? -->

## Consequences
<!-- What becomes easier or more difficult because of this change? -->

### Positive
-

### Negative
-

### Neutral
-
\`\`\`
```

- [ ] **Step 4: Add specs/README.md and adr/README.md index templates**

```markdown
---

## docs/specs/README.md

Auto-generated spec index. Updated by `init` and `audit`.

\`\`\`markdown
# Specs Index

| ID | Title | Status | Category | Date |
|----|-------|--------|----------|------|
<!-- Auto-generated rows. Do not edit manually. -->
\`\`\`

---

## docs/adr/README.md

Auto-generated ADR log. Updated by `init` and `audit`.

\`\`\`markdown
# Architecture Decision Records

| # | Title | Status | Date |
|---|-------|--------|------|
<!-- Auto-generated rows. Do not edit manually. -->
\`\`\`
```

- [ ] **Step 5: Add ci-cd.md and infra.md templates**

```markdown
---

## docs/ci-cd.md

Skip if no CI/CD scope detected.

\`\`\`markdown
# CI/CD

## Pipeline Overview
<!-- Build, test, deploy stages -->

## Triggers
<!-- What triggers each pipeline -->

| Pipeline | Trigger | Branch |
|----------|---------|--------|
| | | |

## Environments
<!-- Deployment targets -->

| Environment | URL | Deploy Method |
|-------------|-----|--------------|
| | | |

## Scripts
<!-- CI/CD related scripts and their purpose -->
\`\`\`

---

## docs/infra.md

Skip if no infrastructure scope detected.

\`\`\`markdown
# Infrastructure

## Overview
<!-- Infrastructure topology -->

## Components
<!-- Cloud services, containers, networking -->

| Component | Service | Purpose |
|-----------|---------|---------|
| | | |

## Configuration
<!-- How infrastructure is configured (IaC, manifests, etc.) -->

## Deployment
<!-- How to deploy infrastructure changes -->
\`\`\`
```

- [ ] **Step 6: Add per-workflow template**

```markdown
---

## docs/workflows/{name}.md

Per-workflow doc. Create one for each distinct workflow/process discovered.

\`\`\`markdown
# {Workflow Name}

## Overview
<!-- 2-3 sentence summary of this workflow -->

## Trigger
<!-- What initiates this workflow -->

## Steps

1. Step description
2. Step description

## Sequence Diagram
<!-- For multi-actor workflows -->

![Sequence](diagrams/sequence-{name}.png)

## Error Handling
<!-- What happens when steps fail -->
\`\`\`
```

- [ ] **Step 7: Add agentic workflow template**

```markdown
---

## docs/workflows/agentic/{skill-name}.md

Per-skill agentic workflow doc. Create one for each discovered skill.

\`\`\`markdown
# Agentic Workflow: {Skill Name}

**Command**: `/command-name`

## Pipeline Overview
<!-- REQUIRED: Subgraph flowchart showing sessions/phases -->

![Workflow](../diagrams/workflow-{name}.png)

## Steps

| Phase | Action | Script/Agent | Output Artifact |
|-------|--------|-------------|----------------|
| 1 | | | |

## Sub-Agents

| Agent | Dispatched In | Task | Fresh Context |
|-------|--------------|------|--------------|
| | | | |

## User Interaction Gates

| Gate | Phase | User Action | Output |
|------|-------|-------------|--------|
| | | | |

## MCP Tools Used

| Tool | Purpose | When Called |
|------|---------|-----------|
| | | |

## Sequence Diagram
<!-- REQUIRED: Multi-actor with sub-agent lifelines, loops, user gates -->

![Sequence](../diagrams/sequence-{name}.png)
\`\`\`
```

- [ ] **Step 8: Add naming convention reference section**

Append to `references/doc-spec.md`:

```markdown
---

## Naming Conventions Reference

### File Naming

| Doc Type | Pattern | Example |
|----------|---------|---------|
| Architecture | `{component-slug}.md` (kebab-case) | `auth-service.md` |
| Specs | `SPEC-{CAT}-{NNN}-{slug}.md` | `SPEC-AUTH-001-oauth-flow.md` |
| ADRs | `ADR-{NNN}-{slug}.md` | `ADR-001-use-jwt-for-auth.md` |
| Workflows | `{workflow-slug}.md` (kebab-case) | `deployment.md` |
| Agentic workflows | `{skill-name}.md` | `doc-superpowers.md` |
| Diagrams | `{type}-{name}.png` | `c4-context.png` |
| Guides | `{topic-slug}.md` (kebab-case) | `getting-started.md` |
| Templates | `template.md` (one per structured dir) | `docs/adr/template.md` |
| Plans | `YYYY-MM-DD-{slug}.md` | `2026-03-12-doc-update-plan.md` |

### Spec Categories

Discovered from code analysis. Canonical list maintained in `docs/specs/README.md`.

| Code | Scope |
|------|-------|
| `ARCH` | System architecture |
| `AUTH` | Authentication / authorization |
| `DATA` | Data layer / schema / persistence |
| `API` | API contracts / endpoints |
| `UI` | User interface / views |
| `PIPE` | Processing pipelines |
| `OPS` | Operations / DevOps / CI-CD |
| `INFRA` | Infrastructure |
| `TEST` | Testing strategy |

New categories: uppercase, max 5 characters. Check `docs/specs/README.md` before creating.

### ADR Numbering

Sequential, monotonic, never reused. Zero-padded 3 digits: `ADR-001`, `ADR-002`.

### Spec Numbering

Sequential per category. Zero-padded 3 digits: `SPEC-AUTH-001`, `SPEC-DATA-001`.
```

- [ ] **Step 9: Add doc-index schema reference**

Append:

```markdown
---

## Doc-Index Schema Reference

Schema for `docs/.doc-index.json`. Generated by `scripts/doc-tools.sh build-index`.

| Field | Type | Purpose |
|-------|------|---------|
| `version` | integer | Schema version (currently 1) |
| `generated_by` | string | Always `"doc-superpowers"` |
| `generated_at` | ISO 8601 | When index was last built/updated |
| `build_commit` | string | Repo HEAD at last `build-index` |
| `docs.<path>.content_hash` | string | `sha256:<hex>` of doc content |
| `docs.<path>.code_refs` | string[] | Directories/files this doc covers |
| `docs.<path>.code_commit` | string | Latest commit SHA for code_refs |
| `docs.<path>.doc_type` | string | Template type |
| `docs.<path>.status` | enum | `current` \| `stale` \| `deprecated` |
| `docs.<path>.replaces` | string\|null | Path to superseded doc |
| `docs.<path>.superseded_by` | string\|null | Path to superseding doc |
| `docs.<path>.last_verified` | ISO 8601 | Last freshness check confirmed current |

### Status Transitions

- `current` → `stale`: reported by `check-freshness` (read-only, doesn't write index)
- `stale` → `current`: set by `update-index` after doc regeneration
- `current` → `deprecated`: human-set only, never overridden by tooling
- `deprecated` is terminal for automated tools
```

- [ ] **Step 10: Commit**

```bash
git add references/doc-spec.md
git commit -m "feat: add new doc templates, naming conventions, schema reference"
```

---

## Chunk 4: `SKILL.md` — Discovery Phase and Init Action

### Task 10: Rewrite SKILL.md discovery phase

**Files:**
- Modify: `SKILL.md`

- [ ] **Step 1: Replace Section 0 (Discovery Phase) with structural scope detection**

Replace everything from `## 0. Discovery Phase` through the `---` before `## 1. Action Routing` with:

```markdown
## 0. Discovery Phase

Run before any action to understand the project's documentation infrastructure.

**Discovery is universal** — all actions run discovery as their first step. Audit *defines* the discovery logic (it is the canonical implementation). Other actions invoke the same discovery function. No action skips discovery.

### Detect Bundled Tooling

doc-superpowers bundles `scripts/doc-tools.sh` in its skill directory. Use it directly:

```bash
# Script location (relative to skill directory)
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOC_TOOLS="$SKILL_DIR/scripts/doc-tools.sh"
```

For user-provided optional scripts, detect dynamically:

```bash
# Optional user scripts (project-level scripts/ directory)
ls scripts/*validate_docs* scripts/*validate_doc_references* scripts/*fix_doc_references* scripts/*archive_doc* scripts/*map_documents* 2>/dev/null
```

| Script Pattern | Source | Purpose |
|---|---|---|
| `doc-tools.sh build-index` | Bundled | Build `docs/.doc-index.json` |
| `doc-tools.sh check-freshness` | Bundled | Hash-based staleness detection (read-only) |
| `doc-tools.sh update-index` | Bundled | Refresh specific index entries |
| `doc-tools.sh status` | Bundled | Single-doc freshness query (read-only) |
| `*validate_docs*` | Optional, user-provided | Doc validation (links, structure) |
| `*validate_doc_references*` | Optional, user-provided | Code reference validation |
| `*fix_doc_references*` | Optional, user-provided | Broken reference repair |
| `*archive_doc*` | Optional, user-provided | Doc archival |
| `*map_documents*` | Optional, user-provided | Custom document mapping |

### Detect Scopes

Scopes are **structural categories**, not platform or language identifiers. The skill detects *what kind of thing exists*. Explore agents determine specific technology during analysis.

| Structural Signal | Scope | Detection |
|---|---|---|
| Package manifests, project files, source dirs | `application` | Glob for `Package.swift`, `Cargo.toml`, `package.json`, `pyproject.toml`, `*.xcodeproj`, `build.gradle`, `go.mod`, `*.sln`, or `src/`, `Sources/`, `lib/`, `app/` |
| API schema definitions | `api-contracts` | Glob for `openapi.*`, `swagger.*`, `*.graphql`, `*.proto`, `*.thrift`, `*-api.*` |
| Models, migrations, schema definitions | `data-layer` | Glob for migration dirs, ORM model files, database schema files |
| IaC, container configs, deploy manifests | `infrastructure` | Glob for `Dockerfile*`, `docker-compose*`, `k8s/`, `terraform/`, `*.tf`, `pulumi/`, `helm/`, `ansible/` |
| CI/CD configuration | `ci-cd` | Glob for `.github/workflows/`, `Fastfile`, `Jenkinsfile`, `.gitlab-ci.yml`, `.circleci/`, `Makefile` with deploy targets |
| Test directories and frameworks | `testing` | Glob for `Tests/`, `test/`, `__tests__/`, `spec/`, `*_test.*`, `*.test.*` |
| Agent skills, commands, MCP configs | `agentic` | Glob for `.claude/skills/*/SKILL.md`, `.claude/commands/*.md`, `.mcp.json`, `.claude/mcp*.json` |
| Existing ADRs | `adr` | Directory existence: `docs/adr/`, `docs/decisions/` |
| Existing specs | `spec` | Directory existence: `docs/specs/`, `docs/superpowers/specs/` |
| Multiple package manifests at different levels | `monorepo` | Two+ manifests at different directory levels, or workspace config fields |

**Rule**: scopes are never `ios`, `android`, `rust`, `python`, etc. Platform/language details are discovered by agents and reflected in doc content, not scope categories.

### Run Baseline Checks

```bash
# Always available — bundled tooling
doc-tools.sh check-freshness

# Optional user scripts
[ -f scripts/validate_docs.py ] && uv run scripts/validate_docs.py
```

If no doc-index exists (first run), `check-freshness` will report the index is missing — this is expected. `init` builds the index after generating docs.

### Detect Agentic Workflows

```bash
# Skills
ls .claude/skills/*/SKILL.md 2>/dev/null

# Commands
ls .claude/commands/*.md 2>/dev/null

# MCP server configs
ls .claude/mcp*.json .mcp.json claude_desktop_config.json 2>/dev/null
```

Build an internal inventory capturing:

| Element | Source | What to capture |
|---|---|---|
| Skills | `.claude/skills/*/SKILL.md` | Name, sub-agents dispatched, scripts invoked, user gates |
| Commands | `.claude/commands/*.md` | Name, which skill they invoke, parameters |
| MCP tools | MCP config files | Server name, tool names, purpose |
| Scripts | `scripts/` referenced by skills | Name, role in pipeline |
| Artifacts | Skill SKILL.md files | Intermediate files, state files, output files |
| User gates | Skill SKILL.md files | Socratic reviews, approval points |
| State/recovery | Commands + skill files | Has `-continue` command, checkpoint files |

### Generated Directory Structure

```
docs/
├── architecture/
│   ├── system-overview.md
│   ├── {component}.md
│   └── diagrams/
├── specs/
│   ├── README.md
│   ├── template.md
│   └── SPEC-{CAT}-NNN-{slug}.md
├── adr/
│   ├── README.md
│   ├── template.md
│   └── ADR-NNN-{slug}.md
├── workflows/
│   ├── {workflow-name}.md
│   ├── agentic/
│   │   └── {skill-name}.md
│   └── diagrams/
├── guides/
│   └── getting-started.md
├── api-contracts.md
├── data-layer.md
├── ci-cd.md
├── infra.md
├── codebase-guide.md
├── conventions.md
├── plans/
├── archive/
│   ├── adr/
│   ├── specs/
│   ├── plans/
│   └── architecture/
└── .doc-index.json
```

### Scope → Generated Docs Matrix

| Scope | Architecture | Workflows | Other |
|---|---|---|---|
| Always | `architecture/system-overview.md` | `workflows/` primary | `guides/getting-started.md`, `codebase-guide.md`, `conventions.md` |
| `application` | `architecture/{component}.md` per major component | — | — |
| `api-contracts` | — | — | `api-contracts.md` |
| `data-layer` | `architecture/diagrams/erd.png` | — | `data-layer.md` |
| `infrastructure` | — | — | `infra.md` |
| `ci-cd` | — | `workflows/deployment.md` | `ci-cd.md` |
| `testing` | — | — | Section in `conventions.md` |
| `agentic` | — | `workflows/agentic/{skill}.md` per skill | — |
| `adr` (existing) | — | — | `adr/README.md` + `adr/template.md` |
| `spec` (existing) | — | — | `specs/README.md` + `specs/template.md` |
| `monorepo` | Section in `architecture/system-overview.md` | — | Section in `codebase-guide.md` |
```

- [ ] **Step 2: Verify the discovery phase is consistent with spec**

Read through the rewritten section and compare against `docs/superpowers/specs/2026-03-12-bundled-doc-tooling-design.md` sections: Scope Detection, Generated Directory Structure, Scope → Generated Docs Matrix.

- [ ] **Step 3: Commit**

```bash
git add SKILL.md
git commit -m "refactor: rewrite discovery phase with structural scopes and bundled tooling"
```

---

### Task 11: Rewrite init action

**Files:**
- Modify: `SKILL.md`

- [ ] **Step 1: Replace the `init` action section**

Replace everything under `### \`init\` — Generate Documentation from Scratch` up to the next `###` heading with:

```markdown
### `init` — Generate Documentation from Scratch

Use when a project has no docs or needs a complete documentation suite generated.

1. **Run discovery** to detect all scopes and existing docs.
2. **Flat-to-structured migration check**: If old-structure files exist (e.g., `docs/architecture.md` from a previous init), detect them by checking for files with doc-superpowers freshness markers that map to a structured path. Offer to migrate instead of creating duplicates.
3. **Dispatch Explore agents** (up to 3 parallel via `Agent` tool, `subagent_type: "Explore"`):
   - **Structure**: Directory tree, key files, entry points
   - **Tech Stack**: Languages, frameworks, dependencies
   - **APIs**: Route definitions, endpoint handlers, schemas
   - **Data Layer**: Models, migrations, database configs
   - **Workflows**: CI/CD configs, scripts, Makefiles
   - **Conventions**: Linting configs, formatting rules, naming patterns
   - **Existing Docs**: Current `docs/`, README, CLAUDE.md content
4. For each skill in the agentic inventory, dispatch an Explore agent to read the SKILL.md and extract: sub-agents, scripts, MCP tools, artifacts, user gates, session boundaries, state tracking.
5. **Create directory structure**: `docs/architecture/diagrams/`, `docs/specs/`, `docs/adr/`, `docs/workflows/agentic/`, `docs/workflows/diagrams/`, `docs/guides/`, `docs/plans/`, `docs/archive/{adr,specs,plans,architecture}/`.
6. **Generate docs per scope** using the Scope → Generated Docs Matrix. Use templates from `references/doc-spec.md`. Apply naming conventions (SPEC-{CAT}-NNN, ADR-NNN, kebab-case).
   - **Never overwrite** existing docs — skip files that already exist.
   - Generate `docs/specs/README.md`, `docs/specs/template.md`, `docs/adr/README.md`, `docs/adr/template.md`.
7. **Seed ADRs** for discovered architectural patterns. ADR seeding is agent-driven — Explore agents identify patterns (auth strategy, data flow, framework selection) and propose ADRs. Seeded ADRs use a `<!-- Generated by doc-superpowers -->` marker.
8. Update `CLAUDE.md` to reflect current project state (create if missing). See `references/doc-spec.md` for CLAUDE.md update rules.
9. **Generate diagrams** per the `diagram` action using co-located paths.
10. Add freshness marker as first line of each generated file: `<!-- Generated by doc-superpowers | YYYY-MM-DD | commit: SHORT_HASH -->`
11. **Build doc-index**: Construct mapping from generated docs (file paths, code areas from Explore results, doc types from templates). Pipe to `doc-tools.sh build-index` via stdin.
12. **Verification gate**: Run `doc-tools.sh check-freshness` to confirm all generated docs are indexed and current.
```

- [ ] **Step 2: Commit**

```bash
git add SKILL.md
git commit -m "refactor: rewrite init action with scope-conditional generation and index building"
```

---

## Chunk 5: `SKILL.md` — Audit, Review-PR, Orchestrator, and Remaining Actions

### Task 12: Rewrite audit action with orchestrator pattern

**Files:**
- Modify: `SKILL.md`

- [ ] **Step 1: Replace the `audit` action section**

```markdown
### `audit` — Full Documentation Health Check

Audit is an **orchestrator**. It discovers what needs attention, then dispatches scope-specific agents who do the actual work. It never creates, edits, or deletes docs itself.

1. **Run discovery** — detect all scopes, existing docs, and naming convention violations.
2. **Call `doc-tools.sh check-freshness`** — get full staleness report.
3. **Compare scope inventory against existing docs** — find gaps (scope detected but no doc, doc exists but missing sections).
4. **Validate naming conventions** — flag files that don't match SPEC-{CAT}-NNN, ADR-NNN, or kebab-case patterns.
5. **For each affected scope**, dispatch a scope agent (`Agent` tool, `subagent_type: "general-purpose"`).

   **Isolation constraint**: Each scope agent receives context ONLY for its scope. It does NOT receive context from other scopes — isolation prevents cross-contamination and keeps agent context focused.

   Each scope agent runs the full cycle:

   **GATHER**: Collect all relevant context for this scope (and only this scope):
   - Stale code refs from the freshness report
   - Existing docs in this scope (architecture, specs, ADRs) — full content
   - The freshness report for this scope from `doc-tools.sh`
   - Naming conventions (SPEC-{CAT}-NNN, ADR-NNN, diagram co-location)
   - Templates from `references/doc-spec.md` for doc types needed

   **PLAN**: Invoke `superpowers:writing-plans` skill:
   - Reason about what to create / edit / delete
   - Produce a scoped plan document saved to `docs/plans/YYYY-MM-DD-{scope}-doc-update-plan.md`

   **EXECUTE**: Follow the plan:
   - Create/edit/delete docs per plan
   - Apply naming conventions (SPEC-{CAT}-NNN, ADR-NNN)
   - Set `replaces`/`superseded_by` for superseded docs
   - Move deleted docs to `docs/archive/{type}/`

   **DIAGRAM**: Run `diagram` action for this scope:
   - Regenerate affected diagrams
   - Co-locate in appropriate `diagrams/` subdirectory

   **SYNC**: Run `sync` for this scope:
   - Update `docs/specs/README.md` and `docs/adr/README.md` indexes
   - Call `doc-tools.sh update-index` for changed docs

   **REPORT**: Return results to orchestrator:
   - List of docs created / edited / deleted / archived
   - Freshness status after changes
   - Any unresolved issues

6. **Merge all scope agent reports** into unified report sorted by severity:
   - **P0 Critical**: Doc describes behavior code no longer implements
   - **P1 Stale**: Code has changed, doc probably needs updating
   - **P2 Incomplete**: Doc is missing sections for new functionality
   - **P3 Style**: Formatting, broken links, outdated terminology
7. When auditing `workflows/`, also compare agentic inventory against documented workflow sections.
8. Output the report.
9. Output is a read-only report (write operations are handled by the `update` action).
```

- [ ] **Step 2: Commit**

```bash
git add SKILL.md
git commit -m "refactor: rewrite audit action with orchestrator pattern and scope agents"
```

---

### Task 13: Rewrite review-pr action with orchestrator pattern

**Files:**
- Modify: `SKILL.md`

- [ ] **Step 1: Replace the `review-pr` action section**

```markdown
### `review-pr` — PR-Scoped Documentation Review

Review-pr is an **orchestrator** like `audit`, but scoped to PR changes.

1. **Run discovery**.
2. **Identify changed files** from PR diff:
   ```bash
   BASE=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@refs/remotes/origin/@@' || echo "main")
   git diff --name-only "$BASE"...HEAD
   ```
3. **Call `doc-tools.sh check-freshness --code-refs <changed_paths>`** — scope check to PR.
4. **Map changed files to affected scopes**.
5. **For each affected scope**, dispatch a scope agent per the Orchestrator Pattern (same gather→plan→execute→diagram→sync→report cycle as `audit`). **Isolation**: each agent receives context ONLY for its scope — no cross-scope context. The scope agent receives:
   - The scope name and its `code_refs`
   - Changed files relevant to this scope (from PR diff)
   - All existing docs in this scope (full content)
   - Existing specs and ADRs that reference this scope
   - The freshness report for this scope from `doc-tools.sh`
   - Naming conventions (SPEC-{CAT}-NNN, ADR-NNN, diagram co-location)
   - Templates from `references/doc-spec.md` for any doc types it needs to create
6. **Merge all scope agent reports** into PR review output.
```

- [ ] **Step 2: Commit**

```bash
git add SKILL.md
git commit -m "refactor: rewrite review-pr action with orchestrator pattern"
```

---

### Task 14: Update remaining actions (update, diagram, sync)

**Files:**
- Modify: `SKILL.md`

- [ ] **Step 1: Update the `update` action**

```markdown
### `update` — Execute Documentation Updates

1. Requires a prior `audit` or `review-pr` report (or pass `--from-freshness` to use `doc-tools.sh check-freshness`).
2. For each stale doc, dispatch an agent to:
   - Read current doc + all code_refs
   - Write updated version preserving manually-added content
   - Update freshness markers
3. Call `doc-tools.sh update-index` for each regenerated doc.
4. Human reviews diffs before committing.
```

- [ ] **Step 2: Update the `diagram` action**

```markdown
### `diagram` — Regenerate Architecture Diagrams

1. Find docs containing Mermaid code blocks:
   ```bash
   rg -l '```mermaid' docs/
   ```
2. Verify diagram accuracy against current code.
3. Load agentic inventory from discovery phase.
4. For each discovered skill/command, check (respecting depth guidance from `references/doc-spec.md`):
   - Does `workflows/agentic/{skill}.md` have a corresponding agentic workflow section?
   - Does it have a subgraph flowchart? (required if 2+ phases)
   - Does it have a multi-actor sequence diagram? (required if sub-agent dispatch)
   - Does it have a state diagram? (internals depth only, if state tracking detected)
5. Flag missing diagrams as P2 Incomplete.
6. Use `mcp__mermaid__generate_mermaid_diagram` (if available) to regenerate PNGs to co-located `diagrams/` dirs:
   - `docs/architecture/diagrams/` for architecture diagrams
   - `docs/workflows/diagrams/` for workflow diagrams
7. If mermaid MCP unavailable, output updated Mermaid source inline.
8. Flag diagrams where code has diverged.
```

- [ ] **Step 3: Update the `sync` action**

```markdown
### `sync` — Sync Doc Index with Filesystem

1. Call `doc-tools.sh check-freshness` to detect drift.
2. Investigate `doc_modified` entries — if a doc's content hash changed but wasn't regenerated by doc-superpowers, flag for agent review.
3. Run user-provided optional scripts if detected:
   ```bash
   [ -f scripts/validate_doc_references.py ] && uv run scripts/validate_doc_references.py
   ```
4. Call `doc-tools.sh update-index` for verified docs.
5. Update `docs/specs/README.md` and `docs/adr/README.md` indexes.
```

- [ ] **Step 4: Commit**

```bash
git add SKILL.md
git commit -m "refactor: update remaining actions with bundled tooling and co-located diagrams"
```

---

### Task 15: Update error handling and scope-specific focus areas

**Files:**
- Modify: `SKILL.md`

- [ ] **Step 1: Update error handling table**

Replace the error handling table in Section 7:

```markdown
## 7. Error Handling

| Situation | Action |
|-----------|--------|
| No `docs/` directory | Run `init` to generate docs from scratch |
| No code_refs on doc | Agent does full-text comparison against likely code locations |
| Missing code_ref path | Flag as P0 ("referenced code deleted") |
| No doc-index | `check-freshness` reports index missing — run `init` to build it |
| Agent timeout | Report partial results, continue with other agents |
| Mermaid MCP unavailable | Output Mermaid source text instead of PNG |
| No stale docs found | Report "All documentation is fresh" and exit |
| `jq` not installed | `doc-tools.sh` exits with install instructions |
| Old flat-file structure detected | `init` offers migration to structured dirs |
```

- [ ] **Step 2: Update common mistakes table**

```markdown
## 8. Common Mistakes

| Mistake | Fix |
|---------|-----|
| Skipping discovery phase | Always detect scopes first — generic fallbacks are less precise |
| Using `init` on a project with existing docs | Use `audit` + `update` instead — `init` creates new docs only |
| Updating doc but not index | Always call `doc-tools.sh update-index` after verifying changes |
| Trusting hash-fresh = content-accurate | Hashes detect file changes; semantic drift needs agent review |
| Auditing `all` on every PR | Use `review-pr` for PRs — it only checks affected scopes |
| Hardcoding platform scopes | Scopes are structural (`application`, `data-layer`), never `ios`/`android` |
| Putting diagrams in global `docs/diagrams/` | Co-locate: `docs/architecture/diagrams/`, `docs/workflows/diagrams/` |
| Skipping the plan step in audit agents | Scope agents MUST use `superpowers:writing-plans` before executing |
```

- [ ] **Step 3: Commit**

```bash
git add SKILL.md
git commit -m "refactor: update error handling and common mistakes for bundled tooling"
```

---

## Chunk 6: Project Documentation and Metadata Updates

### Task 16: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update directory structure in CLAUDE.md**

Replace the directory structure section:

```markdown
## Directory Structure

\`\`\`
doc-superpowers/
├── SKILL.md              # Main skill definition — action routing, discovery, verification
├── scripts/
│   ├── doc-tools.sh      # Bundled freshness tooling (build-index, check-freshness, update-index, status)
│   └── test-doc-tools.sh # Test suite for doc-tools.sh
├── references/
│   └── doc-spec.md       # Templates for generated docs (C4, ERD, workflows, agentic, specs, ADRs)
├── docs/                 # Documentation about this skill itself
│   ├── architecture.md   # C4 diagrams, tech stack, key decisions
│   ├── workflows.md      # Action flows, sequence diagrams, agentic docs
│   ├── getting-started.md # Installation, first run, verification
│   ├── codebase-guide.md # Directory map, key files, code flow
│   ├── conventions.md    # Naming, versioning, skill structure
│   └── diagrams/         # Rendered PNGs (committed for GitHub viewing)
├── README.md             # Installation, usage, examples
├── LICENSE               # MIT
├── RELEASE-NOTES.md      # Semantic versioned changelog
└── CLAUDE.md             # This file
\`\`\`
```

- [ ] **Step 2: Update key files table**

```markdown
## Key Files

| File | Purpose | When to Modify |
|------|---------|---------------|
| `SKILL.md` | Skill logic — discovery, action routing, agent prompts, verification | Adding actions, changing workflow |
| `scripts/doc-tools.sh` | Bundled freshness tooling — 4 subcommands for index management | Changing staleness detection, index schema |
| `scripts/test-doc-tools.sh` | Test suite for doc-tools.sh | Adding tests for new doc-tools features |
| `references/doc-spec.md` | Doc templates, Mermaid syntax, naming conventions, schema reference | Adding doc types, changing templates |
| `RELEASE-NOTES.md` | Version history | Every release |
| `README.md` | User-facing docs | Feature changes |
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md with scripts/ directory and key files"
```

---

### Task 17: Update README.md

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update "What It Does" section to mention bundled tooling**

Add after "Syncs doc indexes with the filesystem" bullet:

```markdown
- **Tracks freshness** via bundled `scripts/doc-tools.sh` — content hashing for docs, commit SHA comparison for code
```

- [ ] **Step 2: Update "Generated Documentation" section**

Replace the table with the new directory structure description:

```markdown
## Generated Documentation

The `init` action generates a structured documentation suite in `docs/`:

| Directory/File | Content | When Generated |
|----------------|---------|---------------|
| `architecture/system-overview.md` | System overview, C4 diagrams, tech stack | Always |
| `architecture/{component}.md` | Per major component/domain | `application` scope |
| `architecture/diagrams/` | C4, component, ERD diagrams | Always |
| `specs/README.md` + `template.md` | Spec index and template | Always |
| `adr/README.md` + `template.md` | ADR log and template | Always |
| `workflows/{name}.md` | Process flows, CI/CD | Always |
| `workflows/agentic/{skill}.md` | Agentic workflow docs | `agentic` scope |
| `workflows/diagrams/` | Workflow, sequence, state diagrams | Always |
| `guides/getting-started.md` | Prerequisites, installation, verification | Always |
| `api-contracts.md` | Endpoints, schemas, request/response | `api-contracts` scope |
| `data-layer.md` | Data models, ERD, storage | `data-layer` scope |
| `ci-cd.md` | Pipeline overview, triggers, environments | `ci-cd` scope |
| `infra.md` | Infrastructure topology, components | `infrastructure` scope |
| `codebase-guide.md` | Directory map, key files, code flow | Always |
| `conventions.md` | Code style, naming, git conventions | Always |
| `.doc-index.json` | Machine-readable freshness index | Always |
```

- [ ] **Step 3: Update "File Structure" section**

```markdown
## File Structure

\`\`\`
doc-superpowers/
├── SKILL.md              # Main skill definition
├── scripts/
│   ├── doc-tools.sh      # Bundled freshness tooling
│   └── test-doc-tools.sh # Test suite
├── references/
│   └── doc-spec.md       # Templates and conventions
├── docs/                 # Documentation about this skill
│   ├── architecture.md
│   ├── workflows.md
│   ├── codebase-guide.md
│   ├── conventions.md
│   ├── getting-started.md
│   └── diagrams/
├── README.md
├── LICENSE               # MIT
├── RELEASE-NOTES.md
├── CLAUDE.md
└── .gitignore
\`\`\`
```

- [ ] **Step 4: Add "Dependencies" section after Architecture**

```markdown
## Dependencies

The skill itself (`SKILL.md` + `references/`) has zero dependencies. The bundled tooling in `scripts/` requires:

| Dependency | Required | Notes |
|-----------|----------|-------|
| `git` | Yes | Already required by doc-superpowers |
| `jq` | Yes | `brew install jq` / `apt install jq` |
| `sha256sum` or `shasum` | Yes | Standard on Linux/macOS respectively |
```

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: update README with structured doc layout, bundled tooling, dependencies"
```

---

### Task 18: Update docs/getting-started.md

**Files:**
- Modify: `docs/getting-started.md`

- [ ] **Step 1: Read current getting-started.md and update**

Remove any references to "optional enhancement" for freshness scripts. Update the generated directory structure example to show the new structured layout. Add `jq` to prerequisites.

Key changes:
- Add `jq` to prerequisites
- Replace any "optional: add freshness scripts" language with "bundled: `scripts/doc-tools.sh` provides freshness tracking"
- Update the directory structure example to show `architecture/`, `specs/`, `adr/`, `workflows/` structure

- [ ] **Step 2: Commit**

```bash
git add docs/getting-started.md
git commit -m "docs: update getting-started — bundled tooling, jq prerequisite, structured dirs"
```

---

### Task 19: Update docs/architecture.md

**Files:**
- Modify: `docs/architecture.md`

- [ ] **Step 1: Read current and add `scripts/` component**

Add `scripts/doc-tools.sh` as a component in the C4 container diagram. Update the "Key Decisions" section to include:
- Decision: Bundled shell tooling — Rationale: Portability, zero language deps, Agent Skills spec compliance
- Decision: Content hash + commit SHA — Rationale: Deterministic staleness detection, agent decides meaning
- Decision: Audit owns discovery — Rationale: Discovery is fundamentally an audit operation

- [ ] **Step 2: Commit**

```bash
git add docs/architecture.md
git commit -m "docs: add scripts/ component and bundled tooling decisions to architecture"
```

---

### Task 20: Update docs/workflows.md

**Files:**
- Modify: `docs/workflows.md`

- [ ] **Step 1: Update init/audit sequence diagrams**

Update to show the discovery boundary (audit owns discovery, init consumes it). Add the orchestrator dispatch flow for audit and review-pr. Key additions:
- Init workflow: discovery → scope detection → generate per scope → build-index → verify
- Audit workflow: discovery → check-freshness → per scope agent dispatch (gather→plan→execute→diagram→sync→report) → merge reports

- [ ] **Step 2: Commit**

```bash
git add docs/workflows.md
git commit -m "docs: update workflows with orchestrator pattern and discovery boundary"
```

---

### Task 21: Update docs/codebase-guide.md

**Files:**
- Modify: `docs/codebase-guide.md`

- [ ] **Step 1: Add `scripts/` directory to directory map**

Add entry for `scripts/doc-tools.sh` and `scripts/test-doc-tools.sh` in the directory structure and key files table.

- [ ] **Step 2: Commit**

```bash
git add docs/codebase-guide.md
git commit -m "docs: add scripts/ directory to codebase guide"
```

---

### Task 22: Update docs/conventions.md

**Files:**
- Modify: `docs/conventions.md`

- [ ] **Step 1: Add naming conventions and doc-index schema**

Add sections for:
- Doc naming conventions (SPEC-{CAT}-NNN, ADR-NNN, kebab-case, diagram co-location)
- Doc-index schema conventions (read/write separation, status transitions)

- [ ] **Step 2: Commit**

```bash
git add docs/conventions.md
git commit -m "docs: add naming conventions and doc-index schema to conventions"
```

---

### Task 23: Update RELEASE-NOTES.md

**Files:**
- Modify: `RELEASE-NOTES.md`

- [ ] **Step 1: Add v2.0.0 entry**

```markdown
## v2.0.0 (2026-03-12)

### Breaking Changes
- **Directory structure**: Generated docs now use structured directories (`docs/architecture/`, `docs/specs/`, `docs/adr/`, `docs/workflows/`, `docs/guides/`). Projects with v1.0.0 flat files will be offered migration on next `init`.
- **Diagram paths**: Diagrams co-located in `docs/{section}/diagrams/` instead of global `docs/diagrams/`.
- **Discovery rewrite**: Scope detection uses structural categories (`application`, `data-layer`, `infrastructure`) instead of platform identifiers.

### Features
- **Bundled freshness tooling**: `scripts/doc-tools.sh` with 4 subcommands (`build-index`, `check-freshness`, `update-index`, `status`). Content hashing for docs, commit SHA comparison for code.
- **Doc-index**: Machine-readable `docs/.doc-index.json` tracks content hashes, code references, staleness, supersession chains.
- **Naming conventions**: `SPEC-{CAT}-NNN-{slug}.md` for specs, `ADR-NNN-{slug}.md` for ADRs, kebab-case for everything else.
- **Orchestrator pattern**: `audit` and `review-pr` dispatch scope-specific agents through gather→plan→execute→diagram→sync→report cycle. Each scope agent uses `superpowers:writing-plans`.
- **Audit owns discovery**: All actions consume the same discovery logic. No more duplicated scope detection.
- **New doc templates**: Architecture components, spec template, ADR template, ci-cd.md, infra.md, specs/README.md, adr/README.md.
- **Flat-to-structured migration**: `init` detects old flat files and offers migration.

### Dependencies
- **jq** is now required for `scripts/doc-tools.sh`. The skill itself remains zero-dependency.
```

- [ ] **Step 2: Commit**

```bash
git add RELEASE-NOTES.md
git commit -m "docs: add v2.0.0 release notes"
```

---

### Task 24: Final verification

- [ ] **Step 1: Run doc-tools.sh test suite**

```bash
bash scripts/test-doc-tools.sh
```

Expected: All tests PASS.

- [ ] **Step 2: Verify no references to old paths**

```bash
rg 'scripts/check_doc_freshness' SKILL.md
rg 'scripts/update_doc_index' SKILL.md
rg 'scripts/check_doc_status_drift' SKILL.md
```

Expected: No matches (replaced by bundled tooling references).

- [ ] **Step 3: Verify co-located diagram paths**

```bash
rg 'docs/diagrams/' SKILL.md references/doc-spec.md
```

Expected: No matches (all paths updated to co-located model).

- [ ] **Step 4: Verify structural scope detection**

```bash
rg '"ios"|"android"|"rust"|"python"|"react"' SKILL.md
```

Expected: No matches (no platform-specific scopes).

- [ ] **Step 5: Verify doc-spec template headings match new directory structure**

```bash
rg '^## docs/' references/doc-spec.md
```

Expected output should show:
- `## docs/architecture/system-overview.md` (not `docs/architecture.md`)
- `## docs/guides/getting-started.md` (not `docs/getting-started.md`)
- `## docs/workflows/{name}.md` (not `docs/workflows.md` as monolithic)
- `## docs/workflows/agentic/{skill-name}.md` (new)
- Other headings for new templates (component, spec, ADR, ci-cd, infra)

- [ ] **Step 6: Final commit if any loose changes**

```bash
git status
# If clean: done. If not: stage and commit remaining changes.
```
