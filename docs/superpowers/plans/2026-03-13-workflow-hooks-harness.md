# Workflow Hooks Harness Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in hooks harness that plugs doc-superpowers freshness checking into git, Claude Code, and CI/CD workflows via a tiered installer.

**Architecture:** Three tiers of hooks (git, Claude Code, CI/CD) live in `scripts/hooks/{git,claude,ci}/`. A single installer script (`scripts/hooks/install.sh`) handles install/uninstall/status across all tiers. Each hook uses a shared preamble pattern for path resolution and graceful degradation. The SKILL.md action router gains a `hooks` action.

**Tech Stack:** Bash (hooks + installer), jq (JSON settings manipulation), GitHub Actions YAML (CI tier)

**Spec:** `docs/superpowers/specs/2026-03-13-workflow-hooks-harness-design.md`

---

## File Structure

| File | Responsibility |
|------|---------------|
| `scripts/hooks/install.sh` | Installer engine: install/uninstall/status for all 3 tiers. Path discovery, marker detection, TTY detection. |
| `scripts/hooks/git/pre-commit` | Check freshness for staged files, warn or block. |
| `scripts/hooks/git/post-merge` | Check freshness after merge, report stale docs. |
| `scripts/hooks/git/post-checkout` | Check freshness on branch switch, report stale docs. |
| `scripts/hooks/git/prepare-commit-msg` | Inject stale doc comments into commit message. |
| `scripts/hooks/claude/pre-commit-gate.sh` | PreToolUse hook: check freshness before Claude-initiated commits. |
| `scripts/hooks/claude/session-summary.sh` | Stop hook: summarize stale docs at session end. |
| `scripts/hooks/ci/doc-freshness-pr.yml` | GitHub Action: PR freshness check + comment. |
| `scripts/hooks/ci/doc-freshness-schedule.yml` | GitHub Action: weekly cron drift detector. |
| `scripts/hooks/ci/doc-index-update.yml` | GitHub Action: post-merge index update PR. |
| `scripts/test-hooks.sh` | Test suite for all hooks and installer logic. |
| `SKILL.md` | Add `hooks` action routing (Section 1). |
| `RELEASE-NOTES.md` | v2.1.0 entry. |
| `README.md` | Add Workflow Integration section. |
| `CLAUDE.md` | Add `hooks` command to Commands table. |

---

## Chunk 1: Shared Test Harness + Git Hook: pre-commit

### Task 1: Create test harness for hooks

**Files:**
- Create: `scripts/test-hooks.sh`

This reuses the same test pattern as `scripts/test-doc-tools.sh` (setup/teardown with temp git repos, assert_* helpers).

- [ ] **Step 1: Write the test harness skeleton with helper functions**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$SCRIPT_DIR/hooks"
DOC_TOOLS="$SCRIPT_DIR/doc-tools.sh"
PASS=0
FAIL=0
TESTS_RUN=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

setup() {
  TEST_DIR=$(mktemp -d)
  cd "$TEST_DIR"
  git init --quiet
  git config user.email "test@test.com"
  git config user.name "Test"
  mkdir -p docs src
  echo "# Architecture" > docs/architecture.md
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

assert_not_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if ! echo "$haystack" | grep -q "$needle"; then
    PASS=$((PASS + 1))
    printf "${GREEN}  PASS${NC}: %s\n" "$msg"
  else
    FAIL=$((FAIL + 1))
    printf "${RED}  FAIL${NC}: %s\n    expected NOT to contain: %s\n    in: %s\n" "$msg" "$needle" "$haystack"
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

assert_file_not_exists() {
  local path="$1" msg="${2:-}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ ! -f "$path" ]; then
    PASS=$((PASS + 1))
    printf "${GREEN}  PASS${NC}: %s\n" "$msg"
  else
    FAIL=$((FAIL + 1))
    printf "${RED}  FAIL${NC}: %s\n    file should not exist: %s\n" "$msg" "$path"
  fi
}

# Build a doc-index for testing. Requires: docs/ and src/ exist with committed files.
build_test_index() {
  echo "docs/architecture.md:src/:architecture" | "$DOC_TOOLS" build-index
}

print_summary() {
  echo ""
  echo "================================"
  printf "Results: ${GREEN}%d passed${NC}, ${RED}%d failed${NC}, %d total\n" "$PASS" "$FAIL" "$TESTS_RUN"
  echo "================================"
  [ "$FAIL" -eq 0 ]
}
```

- [ ] **Step 2: Run the test file to verify harness loads without errors**

Run: `bash scripts/test-hooks.sh`
Expected: exits 0, prints empty summary (0 passed, 0 failed)

- [ ] **Step 3: Commit**

```bash
git add scripts/test-hooks.sh
git commit -m "test: add hooks test harness skeleton"
```

### Task 2: Write the pre-commit git hook

**Files:**
- Create: `scripts/hooks/git/pre-commit`
- Modify: `scripts/test-hooks.sh`

- [ ] **Step 1: Write failing tests for pre-commit hook behavior**

Add to `scripts/test-hooks.sh` before the `print_summary` call:

```bash
# --- pre-commit hook tests ---

test_pre_commit_exits_0_no_index() {
  echo "test: pre-commit exits 0 when no doc-index exists"
  setup
  # No index built — hook should skip silently
  local output exit_code
  set +e
  output=$(DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/git/pre-commit" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0 with no index"
  assert_eq "" "$output" "produces no output"
  teardown
}

test_pre_commit_exits_0_no_stale() {
  echo "test: pre-commit exits 0 when docs are current"
  setup
  build_test_index
  # Stage a file that is NOT a code_ref for any doc
  echo "unrelated" > unrelated.txt
  git add unrelated.txt
  set +e
  output=$(DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/git/pre-commit" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0 with no stale docs"
  teardown
}

test_pre_commit_warns_on_stale() {
  echo "test: pre-commit warns when staged files make docs stale"
  setup
  build_test_index
  # Modify src/ (which is a code_ref) and commit to make docs stale
  echo "changed" > src/index.js
  git add src/index.js && git commit -m "change code" --quiet
  # Now stage another change — docs are now stale relative to code
  echo "changed again" > src/index.js
  git add src/index.js
  set +e
  output=$(DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/git/pre-commit" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0 (warn mode)"
  assert_contains "$output" "doc-superpowers" "mentions doc-superpowers"
  assert_contains "$output" "stale" "mentions stale"
  teardown
}

test_pre_commit_blocks_in_strict_mode() {
  echo "test: pre-commit exits 1 in strict mode when stale"
  setup
  build_test_index
  echo "changed" > src/index.js
  git add src/index.js && git commit -m "change code" --quiet
  echo "changed again" > src/index.js
  git add src/index.js
  set +e
  output=$(DOC_SUPERPOWERS_STRICT=1 DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/git/pre-commit" 2>&1)
  exit_code=$?
  set -e
  assert_eq "1" "$exit_code" "exits 1 in strict mode"
  assert_contains "$output" "stale" "mentions stale"
  teardown
}

test_pre_commit_skip_env() {
  echo "test: pre-commit exits 0 when DOC_SUPERPOWERS_SKIP=1"
  setup
  build_test_index
  echo "changed" > src/index.js
  git add src/index.js && git commit -m "change code" --quiet
  echo "changed again" > src/index.js
  git add src/index.js
  set +e
  output=$(DOC_SUPERPOWERS_SKIP=1 DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/git/pre-commit" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0 with SKIP"
  assert_eq "" "$output" "produces no output"
  teardown
}

test_pre_commit_quiet_mode() {
  echo "test: pre-commit suppresses output in quiet mode"
  setup
  build_test_index
  echo "changed" > src/index.js
  git add src/index.js && git commit -m "change code" --quiet
  echo "changed again" > src/index.js
  git add src/index.js
  set +e
  output=$(DOC_SUPERPOWERS_QUIET=1 DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/git/pre-commit" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0 in quiet mode"
  assert_eq "" "$output" "produces no output in quiet mode"
  teardown
}

test_pre_commit_exits_0_no_doc_tools() {
  echo "test: pre-commit exits 0 when doc-tools.sh is missing"
  setup
  build_test_index
  echo "changed" > src/index.js
  git add src/index.js
  set +e
  output=$(DOC_TOOLS="/nonexistent/doc-tools.sh" bash "$HOOKS_DIR/git/pre-commit" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0 with missing doc-tools"
  assert_eq "" "$output" "produces no output"
  teardown
}

echo ""
echo "=== Git Hook: pre-commit ==="
test_pre_commit_exits_0_no_index
test_pre_commit_exits_0_no_stale
test_pre_commit_warns_on_stale
test_pre_commit_blocks_in_strict_mode
test_pre_commit_skip_env
test_pre_commit_quiet_mode
test_pre_commit_exits_0_no_doc_tools
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash scripts/test-hooks.sh`
Expected: FAIL (hooks/git/pre-commit does not exist yet)

- [ ] **Step 3: Create the pre-commit hook script**

Create `scripts/hooks/git/pre-commit`:

```bash
#!/usr/bin/env bash
# doc-superpowers hook v1 — installed __INSTALL_DATE__
# DO NOT EDIT — managed by doc-superpowers hooks installer

# --- Path resolution (DOC_TOOLS is replaced at install time) ---
# When running from test harness or directly, DOC_TOOLS env var overrides.
DOC_TOOLS="${DOC_TOOLS:-__DOC_TOOLS_PATH__}"
DOC_INDEX="docs/.doc-index.json"

# --- Graceful degradation ---
[[ "${DOC_SUPERPOWERS_SKIP:-}" == "1" ]] && exit 0
[[ -f "$DOC_TOOLS" ]] || exit 0
[[ -f "$DOC_INDEX" ]] || exit 0

# --- Get staged files ---
staged=$(git diff --cached --name-only 2>/dev/null)
[[ -z "$staged" ]] && exit 0

# --- Check freshness scoped to staged files ---
# Convert newlines to space-separated args for --code-refs
code_refs_args=()
while IFS= read -r f; do
  [[ -n "$f" ]] && code_refs_args+=("$f")
done <<< "$staged"

result=$("$DOC_TOOLS" check-freshness --code-refs "${code_refs_args[@]}" 2>/dev/null) || exit 0

# --- Parse results ---
stale_count=$(echo "$result" | jq -r '.summary.stale // 0' 2>/dev/null) || exit 0
[[ "$stale_count" -eq 0 ]] && exit 0

# --- Report stale docs ---
if [[ "${DOC_SUPERPOWERS_QUIET:-}" != "1" ]]; then
  echo ""
  echo "doc-superpowers: $stale_count stale doc(s) detected"

  # Extract stale doc details
  echo "$result" | jq -r '
    .docs | to_entries[] |
    select(.value.status == "stale") |
    "  \(.key) — \(.value.reason // "unknown")\(
      if .value.commits_behind and .value.commits_behind > 0
      then " (\(.value.commits_behind) commits behind)"
      else "" end
    )"
  ' 2>/dev/null

  echo "  Run '/doc-superpowers update' to refresh, or DOC_SUPERPOWERS_SKIP=1 to bypass."
  echo ""
fi

# --- Exit code ---
if [[ "${DOC_SUPERPOWERS_STRICT:-}" == "1" ]]; then
  exit 1
fi
exit 0
```

- [ ] **Step 4: Make the hook executable**

Run: `chmod +x scripts/hooks/git/pre-commit`

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash scripts/test-hooks.sh`
Expected: All 7 pre-commit tests PASS

- [ ] **Step 6: Commit**

```bash
git add scripts/hooks/git/pre-commit scripts/test-hooks.sh
git commit -m "feat: add pre-commit git hook with freshness check"
```

### Task 3: Write the post-merge git hook

**Files:**
- Create: `scripts/hooks/git/post-merge`
- Modify: `scripts/test-hooks.sh`

- [ ] **Step 1: Write failing tests for post-merge**

Add to `scripts/test-hooks.sh` before `print_summary`:

```bash
# --- post-merge hook tests ---

test_post_merge_silent_no_stale() {
  echo "test: post-merge silent when no stale docs"
  setup
  build_test_index
  set +e
  output=$(DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/git/post-merge" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "always exits 0"
  assert_eq "" "$output" "silent when current"
  teardown
}

test_post_merge_reports_stale() {
  echo "test: post-merge reports stale docs"
  setup
  build_test_index
  # Make code change to trigger staleness
  echo "changed" > src/index.js
  git add src/index.js && git commit -m "change code" --quiet
  set +e
  output=$(DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/git/post-merge" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "always exits 0"
  assert_contains "$output" "stale" "reports stale docs"
  assert_contains "$output" "doc-superpowers" "identifies source"
  teardown
}

test_post_merge_skip_env() {
  echo "test: post-merge respects SKIP env"
  setup
  build_test_index
  echo "changed" > src/index.js
  git add src/index.js && git commit -m "change code" --quiet
  set +e
  output=$(DOC_SUPERPOWERS_SKIP=1 DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/git/post-merge" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_eq "" "$output" "silent with SKIP"
  teardown
}

echo ""
echo "=== Git Hook: post-merge ==="
test_post_merge_silent_no_stale
test_post_merge_reports_stale
test_post_merge_skip_env
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash scripts/test-hooks.sh`
Expected: post-merge tests FAIL (file doesn't exist)

- [ ] **Step 3: Create the post-merge hook**

Create `scripts/hooks/git/post-merge`:

```bash
#!/usr/bin/env bash
# doc-superpowers hook v1 — installed __INSTALL_DATE__
# DO NOT EDIT — managed by doc-superpowers hooks installer

DOC_TOOLS="${DOC_TOOLS:-__DOC_TOOLS_PATH__}"
DOC_INDEX="docs/.doc-index.json"

[[ "${DOC_SUPERPOWERS_SKIP:-}" == "1" ]] && exit 0
[[ -f "$DOC_TOOLS" ]] || exit 0
[[ -f "$DOC_INDEX" ]] || exit 0

result=$("$DOC_TOOLS" check-freshness 2>/dev/null) || exit 0

stale_count=$(echo "$result" | jq -r '.summary.stale // 0' 2>/dev/null) || exit 0
[[ "$stale_count" -eq 0 ]] && exit 0

if [[ "${DOC_SUPERPOWERS_QUIET:-}" != "1" ]]; then
  stale_docs=$(echo "$result" | jq -r '.docs | to_entries[] | select(.value.status == "stale") | .key' 2>/dev/null)
  echo ""
  echo "doc-superpowers: $stale_count doc(s) became stale after merge"
  echo "  $(echo "$stale_docs" | tr '\n' ', ' | sed 's/, $//')"
  echo "  Run '/doc-superpowers audit' to review."
  echo ""
fi

exit 0
```

- [ ] **Step 4: Make executable and run tests**

Run: `chmod +x scripts/hooks/git/post-merge && bash scripts/test-hooks.sh`
Expected: All post-merge tests PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/hooks/git/post-merge scripts/test-hooks.sh
git commit -m "feat: add post-merge git hook with freshness report"
```

### Task 4: Write the post-checkout git hook

**Files:**
- Create: `scripts/hooks/git/post-checkout`
- Modify: `scripts/test-hooks.sh`

- [ ] **Step 1: Write failing tests for post-checkout**

Add to `scripts/test-hooks.sh` before `print_summary`:

```bash
# --- post-checkout hook tests ---

test_post_checkout_skips_file_checkout() {
  echo "test: post-checkout skips file checkouts (flag=0)"
  setup
  build_test_index
  echo "changed" > src/index.js
  git add src/index.js && git commit -m "change" --quiet
  set +e
  # $1=prev_head $2=new_head $3=flag (0=file, 1=branch)
  output=$(DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/git/post-checkout" abc123 def456 0 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_eq "" "$output" "silent on file checkout"
  teardown
}

test_post_checkout_reports_on_branch_switch() {
  echo "test: post-checkout reports stale on branch switch (flag=1)"
  setup
  build_test_index
  echo "changed" > src/index.js
  git add src/index.js && git commit -m "change" --quiet
  set +e
  output=$(DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/git/post-checkout" abc123 def456 1 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "always exits 0"
  assert_contains "$output" "stale" "reports stale docs"
  teardown
}

test_post_checkout_silent_when_current() {
  echo "test: post-checkout silent when docs current"
  setup
  build_test_index
  set +e
  output=$(DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/git/post-checkout" abc123 def456 1 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_eq "" "$output" "silent when current"
  teardown
}

echo ""
echo "=== Git Hook: post-checkout ==="
test_post_checkout_skips_file_checkout
test_post_checkout_reports_on_branch_switch
test_post_checkout_silent_when_current
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash scripts/test-hooks.sh`
Expected: post-checkout tests FAIL

- [ ] **Step 3: Create the post-checkout hook**

Create `scripts/hooks/git/post-checkout`:

```bash
#!/usr/bin/env bash
# doc-superpowers hook v1 — installed __INSTALL_DATE__
# DO NOT EDIT — managed by doc-superpowers hooks installer

DOC_TOOLS="${DOC_TOOLS:-__DOC_TOOLS_PATH__}"
DOC_INDEX="docs/.doc-index.json"

[[ "${DOC_SUPERPOWERS_SKIP:-}" == "1" ]] && exit 0

# Only fire on branch switches ($3=1), not file checkouts ($3=0)
# Also fires during git clone with $3=1 — index guard handles gracefully
[[ "${3:-1}" == "0" ]] && exit 0

[[ -f "$DOC_TOOLS" ]] || exit 0
[[ -f "$DOC_INDEX" ]] || exit 0

result=$("$DOC_TOOLS" check-freshness 2>/dev/null) || exit 0

stale_count=$(echo "$result" | jq -r '.summary.stale // 0' 2>/dev/null) || exit 0
[[ "$stale_count" -eq 0 ]] && exit 0

if [[ "${DOC_SUPERPOWERS_QUIET:-}" != "1" ]]; then
  stale_docs=$(echo "$result" | jq -r '.docs | to_entries[] | select(.value.status == "stale") | .key' 2>/dev/null)
  echo ""
  echo "doc-superpowers: $stale_count stale doc(s) on this branch"
  echo "  $(echo "$stale_docs" | tr '\n' ', ' | sed 's/, $//')"
  echo "  Run '/doc-superpowers audit' to review."
  echo ""
fi

exit 0
```

- [ ] **Step 4: Make executable and run tests**

Run: `chmod +x scripts/hooks/git/post-checkout && bash scripts/test-hooks.sh`
Expected: All post-checkout tests PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/hooks/git/post-checkout scripts/test-hooks.sh
git commit -m "feat: add post-checkout git hook with branch-switch filter"
```

### Task 5: Write the prepare-commit-msg git hook

**Files:**
- Create: `scripts/hooks/git/prepare-commit-msg`
- Modify: `scripts/test-hooks.sh`

- [ ] **Step 1: Write failing tests for prepare-commit-msg**

Add to `scripts/test-hooks.sh` before `print_summary`:

```bash
# --- prepare-commit-msg hook tests ---

test_prepare_commit_msg_appends_stale() {
  echo "test: prepare-commit-msg appends stale doc comments"
  setup
  build_test_index
  echo "changed" > src/index.js
  git add src/index.js && git commit -m "change" --quiet
  echo "changed again" > src/index.js
  git add src/index.js
  # Create a temp commit message file (git passes this as $1)
  local msg_file="$TEST_DIR/.git/COMMIT_EDITMSG"
  echo "my commit message" > "$msg_file"
  set +e
  DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/git/prepare-commit-msg" "$msg_file" 2>/dev/null
  exit_code=$?
  set -e
  local content
  content=$(cat "$msg_file")
  assert_eq "0" "$exit_code" "exits 0"
  assert_contains "$content" "my commit message" "preserves original message"
  assert_contains "$content" "# Doc freshness" "appends freshness comment"
  assert_contains "$content" "stale" "mentions stale docs"
  teardown
}

test_prepare_commit_msg_skips_when_current() {
  echo "test: prepare-commit-msg does nothing when docs current"
  setup
  build_test_index
  echo "unrelated" > unrelated.txt
  git add unrelated.txt
  local msg_file="$TEST_DIR/.git/COMMIT_EDITMSG"
  echo "my commit message" > "$msg_file"
  set +e
  DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/git/prepare-commit-msg" "$msg_file" 2>/dev/null
  exit_code=$?
  set -e
  local content
  content=$(cat "$msg_file")
  assert_eq "0" "$exit_code" "exits 0"
  assert_not_contains "$content" "Doc freshness" "does not append when current"
  teardown
}

test_prepare_commit_msg_skips_no_index() {
  echo "test: prepare-commit-msg skips when no index"
  setup
  local msg_file="$TEST_DIR/.git/COMMIT_EDITMSG"
  echo "my commit message" > "$msg_file"
  set +e
  DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/git/prepare-commit-msg" "$msg_file" 2>/dev/null
  exit_code=$?
  set -e
  local content
  content=$(cat "$msg_file")
  assert_eq "0" "$exit_code" "exits 0"
  assert_not_contains "$content" "Doc freshness" "does not append without index"
  teardown
}

echo ""
echo "=== Git Hook: prepare-commit-msg ==="
test_prepare_commit_msg_appends_stale
test_prepare_commit_msg_skips_when_current
test_prepare_commit_msg_skips_no_index
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash scripts/test-hooks.sh`
Expected: prepare-commit-msg tests FAIL

- [ ] **Step 3: Create the prepare-commit-msg hook**

Create `scripts/hooks/git/prepare-commit-msg`:

```bash
#!/usr/bin/env bash
# doc-superpowers hook v1 — installed __INSTALL_DATE__
# DO NOT EDIT — managed by doc-superpowers hooks installer

DOC_TOOLS="${DOC_TOOLS:-__DOC_TOOLS_PATH__}"
DOC_INDEX="docs/.doc-index.json"
COMMIT_MSG_FILE="${1:-}"

[[ "${DOC_SUPERPOWERS_SKIP:-}" == "1" ]] && exit 0
[[ -n "$COMMIT_MSG_FILE" ]] || exit 0
[[ -f "$DOC_TOOLS" ]] || exit 0
[[ -f "$DOC_INDEX" ]] || exit 0

# Scope to staged files (consistent with pre-commit)
staged=$(git diff --cached --name-only 2>/dev/null)
[[ -z "$staged" ]] && exit 0

code_refs_args=()
while IFS= read -r f; do
  [[ -n "$f" ]] && code_refs_args+=("$f")
done <<< "$staged"

result=$("$DOC_TOOLS" check-freshness --code-refs "${code_refs_args[@]}" 2>/dev/null) || exit 0

stale_count=$(echo "$result" | jq -r '.summary.stale // 0' 2>/dev/null) || exit 0
[[ "$stale_count" -eq 0 ]] && exit 0

# Append freshness comment block
{
  echo ""
  echo "# Doc freshness: $stale_count stale doc(s) related to this commit"
  echo "$result" | jq -r '
    .docs | to_entries[] |
    select(.value.status == "stale") |
    "#   stale: \(.key)\(
      if .value.reason then " (\(.value.reason))" else "" end
    )"
  ' 2>/dev/null
} >> "$COMMIT_MSG_FILE"

exit 0
```

- [ ] **Step 4: Make executable and run tests**

Run: `chmod +x scripts/hooks/git/prepare-commit-msg && bash scripts/test-hooks.sh`
Expected: All prepare-commit-msg tests PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/hooks/git/prepare-commit-msg scripts/test-hooks.sh
git commit -m "feat: add prepare-commit-msg hook with freshness injection"
```

---

## Chunk 2: Claude Code Hooks

### Task 6: Write the Claude Code pre-commit gate hook

**Files:**
- Create: `scripts/hooks/claude/pre-commit-gate.sh`
- Modify: `scripts/test-hooks.sh`

- [ ] **Step 1: Write failing tests for pre-commit-gate**

Add to `scripts/test-hooks.sh` before `print_summary`:

```bash
# --- Claude Code Hook: pre-commit-gate ---

test_claude_gate_skips_non_commit() {
  echo "test: claude pre-commit-gate skips non-commit bash commands"
  setup
  build_test_index
  # Simulate tool input that is NOT a git commit
  set +e
  output=$(DOC_TOOLS="$DOC_TOOLS" TOOL_INPUT='{"command":"ls -la"}' bash "$HOOKS_DIR/claude/pre-commit-gate.sh" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0 for non-commit"
  assert_eq "" "$output" "silent for non-commit"
  teardown
}

test_claude_gate_warns_on_stale_commit() {
  echo "test: claude pre-commit-gate warns when committing with stale docs"
  setup
  build_test_index
  echo "changed" > src/index.js
  git add src/index.js && git commit -m "change" --quiet
  echo "changed again" > src/index.js
  git add src/index.js
  set +e
  output=$(DOC_TOOLS="$DOC_TOOLS" TOOL_INPUT='{"command":"git commit -m \"update\""}' bash "$HOOKS_DIR/claude/pre-commit-gate.sh" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0 (warn mode)"
  assert_contains "$output" "stale" "warns about stale docs"
  teardown
}

test_claude_gate_blocks_strict() {
  echo "test: claude pre-commit-gate blocks in strict mode"
  setup
  build_test_index
  echo "changed" > src/index.js
  git add src/index.js && git commit -m "change" --quiet
  echo "changed again" > src/index.js
  git add src/index.js
  set +e
  output=$(DOC_SUPERPOWERS_STRICT=1 DOC_TOOLS="$DOC_TOOLS" TOOL_INPUT='{"command":"git commit -m \"update\""}' bash "$HOOKS_DIR/claude/pre-commit-gate.sh" 2>&1)
  exit_code=$?
  set -e
  assert_eq "2" "$exit_code" "exits 2 in strict mode"
  teardown
}

test_claude_gate_skip_env() {
  echo "test: claude pre-commit-gate respects SKIP"
  setup
  set +e
  output=$(DOC_SUPERPOWERS_SKIP=1 DOC_TOOLS="$DOC_TOOLS" TOOL_INPUT='{"command":"git commit -m \"test\""}' bash "$HOOKS_DIR/claude/pre-commit-gate.sh" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_eq "" "$output" "silent with SKIP"
  teardown
}

echo ""
echo "=== Claude Code Hook: pre-commit-gate ==="
test_claude_gate_skips_non_commit
test_claude_gate_warns_on_stale_commit
test_claude_gate_blocks_strict
test_claude_gate_skip_env
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash scripts/test-hooks.sh`
Expected: Claude pre-commit-gate tests FAIL

- [ ] **Step 3: Create the pre-commit-gate hook**

Create `scripts/hooks/claude/pre-commit-gate.sh`:

```bash
#!/usr/bin/env bash
# doc-superpowers hook v1 — installed __INSTALL_DATE__ — Claude Code PreToolUse (Bash)
# DO NOT EDIT — managed by doc-superpowers hooks installer

DOC_TOOLS="${DOC_TOOLS:-__DOC_TOOLS_PATH__}"
DOC_INDEX="docs/.doc-index.json"

[[ "${DOC_SUPERPOWERS_SKIP:-}" == "1" ]] && exit 0

# Check if this is a git commit command
command_str="${TOOL_INPUT:-}"
if [[ -n "$command_str" ]]; then
  # Extract command field from JSON if it looks like JSON
  if echo "$command_str" | jq -e '.command' >/dev/null 2>&1; then
    command_str=$(echo "$command_str" | jq -r '.command' 2>/dev/null)
  fi
fi

# Only activate for git commit commands
echo "$command_str" | grep -qE '\bgit\s+commit\b' || exit 0

[[ -f "$DOC_TOOLS" ]] || exit 0
[[ -f "$DOC_INDEX" ]] || exit 0

# Reuse pre-commit logic: scope to staged files
staged=$(git diff --cached --name-only 2>/dev/null)
[[ -z "$staged" ]] && exit 0

code_refs_args=()
while IFS= read -r f; do
  [[ -n "$f" ]] && code_refs_args+=("$f")
done <<< "$staged"

result=$("$DOC_TOOLS" check-freshness --code-refs "${code_refs_args[@]}" 2>/dev/null) || exit 0

stale_count=$(echo "$result" | jq -r '.summary.stale // 0' 2>/dev/null) || exit 0
[[ "$stale_count" -eq 0 ]] && exit 0

if [[ "${DOC_SUPERPOWERS_QUIET:-}" != "1" ]]; then
  echo ""
  echo "doc-superpowers: $stale_count stale doc(s) detected before commit"
  echo "$result" | jq -r '
    .docs | to_entries[] |
    select(.value.status == "stale") |
    "  \(.key) — \(.value.reason // "unknown")"
  ' 2>/dev/null
  echo "  Consider running '/doc-superpowers update' before committing."
  echo ""
fi

if [[ "${DOC_SUPERPOWERS_STRICT:-}" == "1" ]]; then
  exit 2
fi
exit 0
```

- [ ] **Step 4: Make executable and run tests**

Run: `chmod +x scripts/hooks/claude/pre-commit-gate.sh && bash scripts/test-hooks.sh`
Expected: All Claude pre-commit-gate tests PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/hooks/claude/pre-commit-gate.sh scripts/test-hooks.sh
git commit -m "feat: add Claude Code pre-commit gate hook"
```

### Task 7: Write the Claude Code session summary hook

**Files:**
- Create: `scripts/hooks/claude/session-summary.sh`
- Modify: `scripts/test-hooks.sh`

- [ ] **Step 1: Write failing tests for session-summary**

Add to `scripts/test-hooks.sh` before `print_summary`:

```bash
# --- Claude Code Hook: session-summary ---

test_session_summary_reports_stale() {
  echo "test: session-summary reports stale docs"
  setup
  build_test_index
  echo "changed" > src/index.js
  git add src/index.js && git commit -m "change" --quiet
  set +e
  output=$(DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/claude/session-summary.sh" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "always exits 0"
  assert_contains "$output" "stale" "reports stale"
  assert_contains "$output" "doc-superpowers" "identifies source"
  teardown
}

test_session_summary_silent_when_current() {
  echo "test: session-summary silent when docs current"
  setup
  build_test_index
  set +e
  output=$(DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/claude/session-summary.sh" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_eq "" "$output" "silent when current"
  teardown
}

test_session_summary_skip_env() {
  echo "test: session-summary respects SKIP"
  setup
  set +e
  output=$(DOC_SUPERPOWERS_SKIP=1 DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/claude/session-summary.sh" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_eq "" "$output" "silent with SKIP"
  teardown
}

echo ""
echo "=== Claude Code Hook: session-summary ==="
test_session_summary_reports_stale
test_session_summary_silent_when_current
test_session_summary_skip_env
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash scripts/test-hooks.sh`
Expected: session-summary tests FAIL

- [ ] **Step 3: Create the session-summary hook**

Create `scripts/hooks/claude/session-summary.sh`:

```bash
#!/usr/bin/env bash
# doc-superpowers hook v1 — installed __INSTALL_DATE__ — Claude Code Stop hook
# DO NOT EDIT — managed by doc-superpowers hooks installer

DOC_TOOLS="${DOC_TOOLS:-__DOC_TOOLS_PATH__}"
DOC_INDEX="docs/.doc-index.json"

[[ "${DOC_SUPERPOWERS_SKIP:-}" == "1" ]] && exit 0
[[ -f "$DOC_TOOLS" ]] || exit 0
[[ -f "$DOC_INDEX" ]] || exit 0

# Enforce 1s timeout to avoid blocking session exit
if command -v timeout >/dev/null 2>&1; then
  result=$(timeout 1 "$DOC_TOOLS" check-freshness 2>/dev/null) || exit 0
else
  result=$("$DOC_TOOLS" check-freshness 2>/dev/null) || exit 0
fi

stale_count=$(echo "$result" | jq -r '.summary.stale // 0' 2>/dev/null) || exit 0
[[ "$stale_count" -eq 0 ]] && exit 0

if [[ "${DOC_SUPERPOWERS_QUIET:-}" != "1" ]]; then
  stale_docs=$(echo "$result" | jq -r '.docs | to_entries[] | select(.value.status == "stale") | .key' 2>/dev/null)
  echo ""
  echo "doc-superpowers: session ending with $stale_count stale doc(s)"
  echo "  $(echo "$stale_docs" | tr '\n' ', ' | sed 's/, $//')"
  echo "  Consider running '/doc-superpowers update' next session."
  echo ""
fi

exit 0
```

- [ ] **Step 4: Make executable and run tests**

Run: `chmod +x scripts/hooks/claude/session-summary.sh && bash scripts/test-hooks.sh`
Expected: All session-summary tests PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/hooks/claude/session-summary.sh scripts/test-hooks.sh
git commit -m "feat: add Claude Code session summary stop hook"
```

---

## Chunk 3: CI/CD Workflows

### Task 8: Write the PR freshness check workflow

**Files:**
- Create: `scripts/hooks/ci/doc-freshness-pr.yml`

- [ ] **Step 1: Create the PR workflow**

Create `scripts/hooks/ci/doc-freshness-pr.yml`:

```yaml
# doc-superpowers workflow v1
# PR documentation freshness check
# Installed by doc-superpowers hooks installer

name: Doc Freshness Check

on:
  pull_request:
    branches: [__BASE_BRANCH__]

env:
  DOC_SUPERPOWERS_VERSION: "__VERSION__"

jobs:
  check-freshness:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write

    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Get changed files
        id: changed
        run: |
          files=$(git diff --name-only origin/__BASE_BRANCH__...HEAD | tr '\n' ' ')
          echo "files=$files" >> "$GITHUB_OUTPUT"
          echo "Changed files: $files"

      - name: Fetch doc-superpowers tooling
        run: |
          curl -sSfL "https://raw.githubusercontent.com/woodrowpearson/doc-superpowers/${DOC_SUPERPOWERS_VERSION}/scripts/doc-tools.sh" \
            -o /tmp/doc-tools.sh
          chmod +x /tmp/doc-tools.sh

      - name: Check doc freshness
        id: freshness
        run: |
          if [ ! -f "docs/.doc-index.json" ]; then
            echo "No doc-index found, skipping freshness check."
            echo "stale_count=0" >> "$GITHUB_OUTPUT"
            exit 0
          fi

          result=$(/tmp/doc-tools.sh check-freshness --code-refs ${{ steps.changed.outputs.files }}) || {
            echo "Freshness check failed, skipping."
            echo "stale_count=0" >> "$GITHUB_OUTPUT"
            exit 0
          }

          stale_count=$(echo "$result" | jq -r '.summary.stale // 0')
          echo "stale_count=$stale_count" >> "$GITHUB_OUTPUT"
          echo "result<<RESULT_EOF" >> "$GITHUB_OUTPUT"
          echo "$result" >> "$GITHUB_OUTPUT"
          echo "RESULT_EOF" >> "$GITHUB_OUTPUT"

      - name: Comment on PR
        if: steps.freshness.outputs.stale_count != '0'
        uses: actions/github-script@v7
        with:
          script: |
            const result = JSON.parse(process.env.FRESHNESS_RESULT);
            const staleCount = parseInt(process.env.STALE_COUNT);
            const staleDocs = Object.entries(result.docs || {})
              .filter(([_, v]) => v.status === 'stale')
              .map(([k, v]) => `| \`${k}\` | ${v.reason || 'unknown'} | ${v.commits_behind || '?'} |`)
              .join('\n');

            const body = `## Doc Freshness Report

            **${staleCount} stale doc(s)** detected in this PR:

            | Doc | Reason | Commits Behind |
            |-----|--------|----------------|
            ${staleDocs}

            Run \`/doc-superpowers update\` to refresh these docs.

            ---
            *Generated by [doc-superpowers](https://github.com/woodrowpearson/doc-superpowers)*`;

            // Find existing comment to update
            const comments = await github.rest.issues.listComments({
              owner: context.repo.owner,
              repo: context.repo.repo,
              issue_number: context.issue.number,
            });
            const existing = comments.data.find(c =>
              c.body.includes('Doc Freshness Report') && c.body.includes('doc-superpowers')
            );

            if (existing) {
              await github.rest.issues.updateComment({
                owner: context.repo.owner,
                repo: context.repo.repo,
                comment_id: existing.id,
                body,
              });
            } else {
              await github.rest.issues.createComment({
                owner: context.repo.owner,
                repo: context.repo.repo,
                issue_number: context.issue.number,
                body,
              });
            }
        env:
          FRESHNESS_RESULT: ${{ steps.freshness.outputs.result }}
          STALE_COUNT: ${{ steps.freshness.outputs.stale_count }}

      - name: Fail if strict mode
        if: steps.freshness.outputs.stale_count != '0' && env.DOC_SUPERPOWERS_STRICT == '1'
        run: |
          echo "::error::${{ steps.freshness.outputs.stale_count }} stale doc(s) detected. Fix before merging."
          exit 1
```

- [ ] **Step 2: Commit**

```bash
git add scripts/hooks/ci/doc-freshness-pr.yml
git commit -m "feat: add GitHub Action for PR doc freshness check"
```

### Task 9: Write the scheduled drift detector workflow

**Files:**
- Create: `scripts/hooks/ci/doc-freshness-schedule.yml`

- [ ] **Step 1: Create the schedule workflow**

Create `scripts/hooks/ci/doc-freshness-schedule.yml`:

```yaml
# doc-superpowers workflow v1
# Weekly documentation drift detector
# Installed by doc-superpowers hooks installer

name: Doc Freshness Audit (Scheduled)

on:
  schedule:
    - cron: '__CRON_SCHEDULE__'
  workflow_dispatch: # Allow manual trigger

env:
  DOC_SUPERPOWERS_VERSION: "__VERSION__"

jobs:
  audit-freshness:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      issues: write

    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Fetch doc-superpowers tooling
        run: |
          curl -sSfL "https://raw.githubusercontent.com/woodrowpearson/doc-superpowers/${DOC_SUPERPOWERS_VERSION}/scripts/doc-tools.sh" \
            -o /tmp/doc-tools.sh
          chmod +x /tmp/doc-tools.sh

      - name: Check doc freshness
        id: freshness
        run: |
          if [ ! -f "docs/.doc-index.json" ]; then
            echo "No doc-index found."
            echo "stale_count=0" >> "$GITHUB_OUTPUT"
            exit 0
          fi

          result=$(/tmp/doc-tools.sh check-freshness) || {
            echo "Freshness check failed."
            echo "stale_count=0" >> "$GITHUB_OUTPUT"
            exit 0
          }

          stale_count=$(echo "$result" | jq -r '.summary.stale // 0')
          echo "stale_count=$stale_count" >> "$GITHUB_OUTPUT"
          echo "result<<RESULT_EOF" >> "$GITHUB_OUTPUT"
          echo "$result" >> "$GITHUB_OUTPUT"
          echo "RESULT_EOF" >> "$GITHUB_OUTPUT"

      - name: Create or update issue
        if: steps.freshness.outputs.stale_count != '0'
        uses: actions/github-script@v7
        with:
          script: |
            const result = JSON.parse(process.env.FRESHNESS_RESULT);
            const staleCount = parseInt(process.env.STALE_COUNT);
            const title = '[doc-superpowers] Stale documentation detected';
            const staleDocs = Object.entries(result.docs || {})
              .filter(([_, v]) => v.status === 'stale')
              .map(([k, v]) => `- \`${k}\` — ${v.reason || 'unknown'} (${v.commits_behind || '?'} commits behind)`)
              .join('\n');

            const body = `## Stale Documentation Report

            **${staleCount} stale doc(s)** detected:

            ${staleDocs}

            ### How to fix
            1. Open Claude Code in this repo
            2. Run \`/doc-superpowers update\`
            3. Review and commit the changes

            ---
            *Generated by [doc-superpowers](https://github.com/woodrowpearson/doc-superpowers) scheduled audit*
            *Last checked: ${new Date().toISOString()}*`;

            // Find existing open issue
            const issues = await github.rest.issues.listForRepo({
              owner: context.repo.owner,
              repo: context.repo.repo,
              state: 'open',
              labels: 'doc-superpowers',
            });
            const existing = issues.data.find(i => i.title === title);

            if (existing) {
              await github.rest.issues.update({
                owner: context.repo.owner,
                repo: context.repo.repo,
                issue_number: existing.number,
                body,
              });
            } else {
              await github.rest.issues.create({
                owner: context.repo.owner,
                repo: context.repo.repo,
                title,
                body,
                labels: ['doc-superpowers', 'documentation'],
              });
            }
        env:
          FRESHNESS_RESULT: ${{ steps.freshness.outputs.result }}
          STALE_COUNT: ${{ steps.freshness.outputs.stale_count }}

      - name: Close issue if all clear
        if: steps.freshness.outputs.stale_count == '0'
        uses: actions/github-script@v7
        with:
          script: |
            const title = '[doc-superpowers] Stale documentation detected';
            const issues = await github.rest.issues.listForRepo({
              owner: context.repo.owner,
              repo: context.repo.repo,
              state: 'open',
              labels: 'doc-superpowers',
            });
            const existing = issues.data.find(i => i.title === title);

            if (existing) {
              await github.rest.issues.createComment({
                owner: context.repo.owner,
                repo: context.repo.repo,
                issue_number: existing.number,
                body: 'All documentation is now current. Closing.',
              });
              await github.rest.issues.update({
                owner: context.repo.owner,
                repo: context.repo.repo,
                issue_number: existing.number,
                state: 'closed',
              });
            }
```

- [ ] **Step 2: Commit**

```bash
git add scripts/hooks/ci/doc-freshness-schedule.yml
git commit -m "feat: add GitHub Action for scheduled doc freshness audit"
```

### Task 10: Write the doc-index update workflow

**Files:**
- Create: `scripts/hooks/ci/doc-index-update.yml`

- [ ] **Step 1: Create the index update workflow**

Create `scripts/hooks/ci/doc-index-update.yml`:

```yaml
# doc-superpowers workflow v1
# Auto-update doc index after docs change on main
# Installed by doc-superpowers hooks installer

name: Doc Index Update

on:
  push:
    branches: [__BASE_BRANCH__]
    paths:
      - 'docs/**'

env:
  DOC_SUPERPOWERS_VERSION: "__VERSION__"

jobs:
  update-index:
    # Skip if this push was made by doc-superpowers itself
    if: "!contains(github.event.head_commit.message, '[doc-superpowers]')"
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write

    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 2

      - name: Get changed docs
        id: changed
        run: |
          docs=$(git diff --name-only HEAD~1 -- 'docs/' | tr '\n' ' ')
          echo "docs=$docs" >> "$GITHUB_OUTPUT"
          echo "Changed docs: $docs"

      - name: Check if index update needed
        if: steps.changed.outputs.docs != ''
        id: check
        run: |
          if [ ! -f "docs/.doc-index.json" ]; then
            echo "No doc-index, skipping."
            echo "needed=false" >> "$GITHUB_OUTPUT"
            exit 0
          fi
          echo "needed=true" >> "$GITHUB_OUTPUT"

      - name: Fetch doc-superpowers tooling
        if: steps.check.outputs.needed == 'true'
        run: |
          curl -sSfL "https://raw.githubusercontent.com/woodrowpearson/doc-superpowers/${DOC_SUPERPOWERS_VERSION}/scripts/doc-tools.sh" \
            -o /tmp/doc-tools.sh
          chmod +x /tmp/doc-tools.sh

      - name: Update index
        if: steps.check.outputs.needed == 'true'
        run: |
          /tmp/doc-tools.sh update-index ${{ steps.changed.outputs.docs }}

      - name: Create PR if index changed
        if: steps.check.outputs.needed == 'true'
        run: |
          if git diff --quiet docs/.doc-index.json 2>/dev/null; then
            echo "Index unchanged, no PR needed."
            exit 0
          fi

          branch="doc-superpowers/update-index-$(date +%Y%m%d%H%M%S)"
          git checkout -b "$branch"
          git config user.name "doc-superpowers[bot]"
          git config user.email "doc-superpowers[bot]@users.noreply.github.com"
          git add docs/.doc-index.json
          git commit -m "[doc-superpowers] update doc index"
          git push origin "$branch"

          gh pr create \
            --title "[doc-superpowers] update doc index" \
            --body "Auto-generated by doc-superpowers after docs were updated on __BASE_BRANCH__." \
            --base __BASE_BRANCH__ \
            --head "$branch"
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

- [ ] **Step 2: Commit**

```bash
git add scripts/hooks/ci/doc-index-update.yml
git commit -m "feat: add GitHub Action for post-merge doc index update"
```

---

## Chunk 4: Installer

### Task 11: Write the installer engine

**Files:**
- Create: `scripts/hooks/install.sh`
- Modify: `scripts/test-hooks.sh`

This is the largest single file. It handles install, uninstall, and status across all three tiers.

- [ ] **Step 1: Write failing tests for installer**

Add to `scripts/test-hooks.sh` before `print_summary`:

```bash
# --- Installer tests ---

test_install_git_creates_hooks() {
  echo "test: install --git creates hook files in .git/hooks/"
  setup
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" install --git 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_exists ".git/hooks/pre-commit" "pre-commit installed"
  assert_file_exists ".git/hooks/post-merge" "post-merge installed"
  assert_file_exists ".git/hooks/post-checkout" "post-checkout installed"
  assert_file_exists ".git/hooks/prepare-commit-msg" "prepare-commit-msg installed"
  # Verify marker
  assert_contains "$(head -2 .git/hooks/pre-commit)" "doc-superpowers hook v1" "has marker"
  # Verify DOC_TOOLS path was substituted
  assert_not_contains "$(cat .git/hooks/pre-commit)" "__DOC_TOOLS_PATH__" "path substituted"
  assert_contains "$(cat .git/hooks/pre-commit)" "doc-tools.sh" "has real path"
  teardown
}

test_install_git_preserves_existing_hook() {
  echo "test: install --git does not overwrite foreign hooks"
  setup
  printf '#!/bin/bash\necho existing\n' > .git/hooks/pre-commit
  chmod +x .git/hooks/pre-commit
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" install --git 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_contains "$(cat .git/hooks/pre-commit)" "existing" "original preserved"
  assert_contains "$output" "Existing" "warns about existing hook"
  teardown
}

test_install_git_overwrites_own_hook() {
  echo "test: install --git overwrites existing doc-superpowers hooks"
  setup
  mkdir -p .git/hooks
  printf '#!/bin/bash\n# doc-superpowers hook v1\necho old\n' > .git/hooks/pre-commit
  chmod +x .git/hooks/pre-commit
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" install --git 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_not_contains "$(cat .git/hooks/pre-commit)" "echo old" "old content replaced"
  assert_contains "$(cat .git/hooks/pre-commit)" "doc-superpowers hook v1" "new marker present"
  teardown
}

test_uninstall_git_removes_hooks() {
  echo "test: uninstall --git removes doc-superpowers hooks"
  setup
  bash "$HOOKS_DIR/install.sh" install --git >/dev/null 2>&1
  assert_file_exists ".git/hooks/pre-commit" "hook exists before uninstall"
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" uninstall --git 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_not_exists ".git/hooks/pre-commit" "pre-commit removed"
  assert_file_not_exists ".git/hooks/post-merge" "post-merge removed"
  teardown
}

test_uninstall_git_preserves_foreign_hooks() {
  echo "test: uninstall --git preserves foreign hooks"
  setup
  printf '#!/bin/bash\necho foreign\n' > .git/hooks/post-merge
  chmod +x .git/hooks/post-merge
  bash "$HOOKS_DIR/install.sh" install --git >/dev/null 2>&1
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" uninstall --git 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_exists ".git/hooks/post-merge" "foreign hook preserved"
  assert_contains "$(cat .git/hooks/post-merge)" "foreign" "content preserved"
  teardown
}

test_install_claude_creates_settings() {
  echo "test: install --claude creates .claude/settings.local.json"
  setup
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" install --claude 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_exists ".claude/settings.local.json" "settings file created"
  local settings
  settings=$(cat .claude/settings.local.json)
  assert_contains "$settings" "PreToolUse" "has PreToolUse hook"
  assert_contains "$settings" "Stop" "has Stop hook"
  assert_contains "$settings" "pre-commit-gate" "has pre-commit-gate"
  assert_contains "$settings" "session-summary" "has session-summary"
  teardown
}

test_install_claude_preserves_existing() {
  echo "test: install --claude preserves existing settings"
  setup
  mkdir -p .claude
  echo '{"permissions":{"allow":["Read"]}}' > .claude/settings.local.json
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" install --claude 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  local settings
  settings=$(cat .claude/settings.local.json)
  assert_contains "$settings" "permissions" "preserves existing"
  assert_contains "$settings" "PreToolUse" "adds hooks"
  teardown
}

test_uninstall_claude_removes_hooks() {
  echo "test: uninstall --claude removes doc-superpowers hooks"
  setup
  bash "$HOOKS_DIR/install.sh" install --claude >/dev/null 2>&1
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" uninstall --claude 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  local settings
  settings=$(cat .claude/settings.local.json)
  assert_not_contains "$settings" "pre-commit-gate" "hooks removed"
  teardown
}

test_install_ci_creates_workflows() {
  echo "test: install --ci creates workflow files"
  setup
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" install --ci 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_exists ".github/workflows/doc-freshness-pr.yml" "PR workflow"
  assert_file_exists ".github/workflows/doc-freshness-schedule.yml" "schedule workflow"
  assert_file_exists ".github/workflows/doc-index-update.yml" "index workflow"
  # Verify placeholders were substituted
  assert_not_contains "$(cat .github/workflows/doc-freshness-pr.yml)" "__BASE_BRANCH__" "base branch substituted"
  assert_not_contains "$(cat .github/workflows/doc-freshness-pr.yml)" "__VERSION__" "version substituted"
  teardown
}

test_status_reports_installed() {
  echo "test: status reports installed hooks"
  setup
  bash "$HOOKS_DIR/install.sh" install --git >/dev/null 2>&1
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" status 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_contains "$output" "pre-commit" "shows pre-commit"
  assert_contains "$output" "installed" "shows installed status"
  teardown
}

test_status_reports_not_installed() {
  echo "test: status reports when nothing installed"
  setup
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" status 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_contains "$output" "not installed" "shows not installed"
  teardown
}

test_install_all_installs_git_and_claude_and_ci() {
  echo "test: install --all installs all tiers"
  setup
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" install --all 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0"
  assert_file_exists ".git/hooks/pre-commit" "git tier"
  assert_file_exists ".claude/settings.local.json" "claude tier"
  assert_file_exists ".github/workflows/doc-freshness-pr.yml" "ci tier"
  teardown
}

test_install_no_git_dir() {
  echo "test: install --git fails when not a git repo"
  local tmpdir
  tmpdir=$(mktemp -d)
  cd "$tmpdir"
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" install --git 2>&1)
  exit_code=$?
  set -e
  assert_eq "1" "$exit_code" "exits 1"
  assert_contains "$output" "not a git repo" "error message"
  cd /
  rm -rf "$tmpdir"
}

test_no_args_prints_usage() {
  echo "test: no args prints usage"
  setup
  set +e
  output=$(bash "$HOOKS_DIR/install.sh" 2>&1)
  exit_code=$?
  set -e
  assert_eq "1" "$exit_code" "exits 1"
  assert_contains "$output" "Usage" "prints usage"
  teardown
}

echo ""
echo "=== Installer ==="
test_install_git_creates_hooks
test_install_git_preserves_existing_hook
test_install_git_overwrites_own_hook
test_uninstall_git_removes_hooks
test_uninstall_git_preserves_foreign_hooks
test_install_claude_creates_settings
test_install_claude_preserves_existing
test_uninstall_claude_removes_hooks
test_install_ci_creates_workflows
test_status_reports_installed
test_status_reports_not_installed
test_install_all_installs_git_and_claude_and_ci
test_install_no_git_dir
test_no_args_prints_usage
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash scripts/test-hooks.sh`
Expected: Installer tests FAIL

- [ ] **Step 3: Create the installer script**

Create `scripts/hooks/install.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# doc-superpowers hooks installer
# Usage: install.sh <install|uninstall|status> [--git] [--claude] [--ci] [--all]
#        install.sh install [--base-branch NAME] [--cron EXPR] [--ci-strict]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOC_TOOLS="$SKILL_DIR/scripts/doc-tools.sh"
MARKER="doc-superpowers hook v1"
WORKFLOW_MARKER="doc-superpowers workflow v1"
DATE=$(date +%Y-%m-%d)

# Detect version from RELEASE-NOTES.md
VERSION=$(grep -o '## v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*' "$SKILL_DIR/RELEASE-NOTES.md" | head -1 | sed 's/## v//')
VERSION="${VERSION:-2.0.0}"

# Default CI parameters
BASE_BRANCH="main"
CRON_SCHEDULE="0 9 * * 1"
CI_STRICT="false"

# --- Usage ---

usage() {
  cat <<EOF
doc-superpowers hooks installer

Usage:
  install.sh install [--git] [--claude] [--ci] [--all]
  install.sh uninstall [--git] [--claude] [--ci] [--all]
  install.sh status

Tier flags:
  --git      Git hooks (pre-commit, post-merge, post-checkout, prepare-commit-msg)
  --claude   Claude Code hooks (pre-commit gate, session summary)
  --ci       CI/CD workflows (PR check, weekly audit, index update)
  --all      All tiers

CI options (used with --ci):
  --base-branch NAME   Target branch (default: main)
  --cron EXPR          Schedule cron expression (default: 0 9 * * 1)
  --ci-strict          Make PR check fail on stale docs
EOF
  exit 1
}

# --- Helpers ---

is_doc_superpowers_hook() {
  local file="$1"
  [[ -f "$file" ]] && head -3 "$file" | grep -q "$MARKER"
}

is_doc_superpowers_workflow() {
  local file="$1"
  [[ -f "$file" ]] && head -3 "$file" | grep -q "$WORKFLOW_MARKER"
}

# --- Git tier ---

install_git() {
  if [[ ! -d ".git" ]]; then
    echo "ERROR: not a git repo (no .git/ directory)" >&2
    return 1
  fi

  mkdir -p .git/hooks
  local installed=0 skipped=0

  for hook_src in "$SCRIPT_DIR/git/"*; do
    local hook_name
    hook_name=$(basename "$hook_src")
    local hook_dest=".git/hooks/$hook_name"

    if [[ -f "$hook_dest" ]] && ! is_doc_superpowers_hook "$hook_dest"; then
      echo "  Existing $hook_name hook found. Add this line to integrate:"
      echo "    source \"$hook_src\""
      skipped=$((skipped + 1))
      continue
    fi

    # Copy with DOC_TOOLS path substituted
    sed -e "s|__DOC_TOOLS_PATH__|$DOC_TOOLS|g" -e "s|__INSTALL_DATE__|$DATE|g" "$hook_src" > "$hook_dest"
    chmod +x "$hook_dest"
    installed=$((installed + 1))
  done

  echo "Git hooks: $installed installed, $skipped skipped (existing)"
}

uninstall_git() {
  if [[ ! -d ".git/hooks" ]]; then
    echo "Git hooks: nothing to uninstall"
    return 0
  fi

  local removed=0
  for hook_name in pre-commit post-merge post-checkout prepare-commit-msg; do
    local hook_dest=".git/hooks/$hook_name"
    if is_doc_superpowers_hook "$hook_dest"; then
      rm "$hook_dest"
      removed=$((removed + 1))
    fi
  done

  echo "Git hooks: $removed removed"
}

status_git() {
  echo "Git Hooks:"
  for hook_name in pre-commit post-merge post-checkout prepare-commit-msg; do
    local hook_dest=".git/hooks/$hook_name"
    if is_doc_superpowers_hook "$hook_dest" 2>/dev/null; then
      local install_date
      install_date=$(head -3 "$hook_dest" | sed -n 's/.*installed \([0-9-]*\).*/\1/p')
      install_date="${install_date:-unknown}"
      printf "  ✓ %-22s installed %s\n" "$hook_name" "$install_date"
    else
      printf "  ✗ %-22s not installed\n" "$hook_name"
    fi
  done
}

# --- Claude tier ---

install_claude() {
  mkdir -p .claude
  local settings_file=".claude/settings.local.json"
  local settings="{}"

  if [[ -f "$settings_file" ]]; then
    settings=$(cat "$settings_file")
  fi

  local pre_commit_cmd="$SKILL_DIR/scripts/hooks/claude/pre-commit-gate.sh"
  local session_cmd="$SKILL_DIR/scripts/hooks/claude/session-summary.sh"

  # Build new hook entries
  local pre_tool_entry="{\"matcher\":\"Bash\",\"command\":\"$pre_commit_cmd\"}"
  local stop_entry="{\"command\":\"$session_cmd\"}"

  # Deep merge: preserve existing hooks, append ours
  settings=$(echo "$settings" | jq --argjson pte "$pre_tool_entry" --argjson se "$stop_entry" '
    # Remove any existing doc-superpowers entries first
    .hooks.PreToolUse = ([(.hooks.PreToolUse // [])[] | select(.command | contains("doc-superpowers/scripts/hooks/claude/") | not)] + [$pte]) |
    .hooks.Stop = ([(.hooks.Stop // [])[] | select(.command | contains("doc-superpowers/scripts/hooks/claude/") | not)] + [$se])
  ')

  echo "$settings" | jq '.' > "$settings_file"
  echo "Claude Code hooks: 2 installed (pre-commit-gate, session-summary)"
}

uninstall_claude() {
  local settings_file=".claude/settings.local.json"

  if [[ ! -f "$settings_file" ]]; then
    echo "Claude Code hooks: nothing to uninstall"
    return 0
  fi

  local settings
  settings=$(cat "$settings_file")

  settings=$(echo "$settings" | jq '
    .hooks.PreToolUse = [(.hooks.PreToolUse // [])[] | select(.command | contains("doc-superpowers/scripts/hooks/claude/") | not)] |
    .hooks.Stop = [(.hooks.Stop // [])[] | select(.command | contains("doc-superpowers/scripts/hooks/claude/") | not)] |
    # Clean up empty arrays
    if (.hooks.PreToolUse | length) == 0 then del(.hooks.PreToolUse) else . end |
    if (.hooks.Stop | length) == 0 then del(.hooks.Stop) else . end |
    if (.hooks | length) == 0 then del(.hooks) else . end
  ')

  echo "$settings" | jq '.' > "$settings_file"
  echo "Claude Code hooks: removed"
}

status_claude() {
  echo "Claude Code Hooks:"
  local settings_file=".claude/settings.local.json"

  if [[ ! -f "$settings_file" ]]; then
    echo "  ✗ not installed"
    return
  fi

  local settings
  settings=$(cat "$settings_file")

  for hook_name in pre-commit-gate session-summary; do
    if echo "$settings" | jq -e ".hooks | .. | .command? // empty | select(contains(\"$hook_name\"))" >/dev/null 2>&1; then
      printf "  ✓ %-22s active in .claude/settings.local.json\n" "$hook_name"
    else
      printf "  ✗ %-22s not installed\n" "$hook_name"
    fi
  done
}

# --- CI tier ---

install_ci() {
  mkdir -p .github/workflows
  local installed=0 skipped=0

  for workflow_src in "$SCRIPT_DIR/ci/"*.yml; do
    local workflow_name
    workflow_name=$(basename "$workflow_src")
    local workflow_dest=".github/workflows/$workflow_name"

    if [[ -f "$workflow_dest" ]] && ! is_doc_superpowers_workflow "$workflow_dest"; then
      echo "  Existing $workflow_name found, skipping."
      skipped=$((skipped + 1))
      continue
    fi

    # Copy with placeholder substitution
    sed \
      -e "s|__BASE_BRANCH__|$BASE_BRANCH|g" \
      -e "s|__VERSION__|v$VERSION|g" \
      -e "s|__CRON_SCHEDULE__|$CRON_SCHEDULE|g" \
      "$workflow_src" > "$workflow_dest"

    installed=$((installed + 1))
  done

  echo "CI/CD workflows: $installed installed, $skipped skipped"
  if [[ $installed -gt 0 ]]; then
    echo "  Remember to commit and push these workflows."
  fi
}

uninstall_ci() {
  if [[ ! -d ".github/workflows" ]]; then
    echo "CI/CD workflows: nothing to uninstall"
    return 0
  fi

  local removed=0
  for workflow_name in doc-freshness-pr.yml doc-freshness-schedule.yml doc-index-update.yml; do
    local workflow_dest=".github/workflows/$workflow_name"
    if is_doc_superpowers_workflow "$workflow_dest" 2>/dev/null; then
      rm "$workflow_dest"
      removed=$((removed + 1))
    fi
  done

  echo "CI/CD workflows: $removed removed"
}

status_ci() {
  echo "CI/CD Workflows:"
  if [[ ! -d ".github/workflows" ]]; then
    echo "  ✗ not installed"
    return
  fi

  local found=0
  for workflow_name in doc-freshness-pr.yml doc-freshness-schedule.yml doc-index-update.yml; do
    local workflow_dest=".github/workflows/$workflow_name"
    if is_doc_superpowers_workflow "$workflow_dest" 2>/dev/null; then
      printf "  ✓ %-22s installed\n" "$workflow_name"
      found=$((found + 1))
    else
      printf "  ✗ %-22s not installed\n" "$workflow_name"
    fi
  done
}

# --- Main ---

[[ $# -lt 1 ]] && usage

COMMAND="$1"
shift

# Validate skill directory
if [[ ! -f "$DOC_TOOLS" ]]; then
  echo "ERROR: doc-tools.sh not found at $DOC_TOOLS" >&2
  echo "Is the doc-superpowers skill installed correctly?" >&2
  exit 1
fi

# Parse flags
DO_GIT=false
DO_CLAUDE=false
DO_CI=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --git) DO_GIT=true; shift ;;
    --claude) DO_CLAUDE=true; shift ;;
    --ci) DO_CI=true; shift ;;
    --all) DO_GIT=true; DO_CLAUDE=true; DO_CI=true; shift ;;
    --base-branch) BASE_BRANCH="$2"; shift 2 ;;
    --cron) CRON_SCHEDULE="$2"; shift 2 ;;
    --ci-strict) CI_STRICT="true"; shift ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

case "$COMMAND" in
  install)
    # If no tier selected, check for interactive mode
    if ! $DO_GIT && ! $DO_CLAUDE && ! $DO_CI; then
      if [[ -t 0 ]]; then
        echo "doc-superpowers hooks installer"
        echo ""
        echo "Which tiers would you like to install?"
        echo "  [1] Git hooks (pre-commit, post-merge, post-checkout, prepare-commit-msg)"
        echo "  [2] Claude Code hooks (pre-commit gate, session summary)"
        echo "  [3] CI/CD workflows (PR check, weekly audit, index update)"
        echo "  [a] All of the above"
        echo ""
        read -rp "Select (comma-separated, e.g. 1,2): " selection
        [[ "$selection" == *1* ]] && DO_GIT=true
        [[ "$selection" == *2* ]] && DO_CLAUDE=true
        [[ "$selection" == *3* ]] && DO_CI=true
        [[ "$selection" == *a* ]] && DO_GIT=true && DO_CLAUDE=true && DO_CI=true
      else
        usage
      fi
    fi

    echo ""
    echo "Installing doc-superpowers hooks..."
    echo ""
    $DO_GIT && install_git
    $DO_CLAUDE && install_claude
    $DO_CI && install_ci
    echo ""
    echo "Done."
    ;;

  uninstall)
    if ! $DO_GIT && ! $DO_CLAUDE && ! $DO_CI; then
      DO_GIT=true; DO_CLAUDE=true; DO_CI=true
    fi

    echo ""
    echo "Uninstalling doc-superpowers hooks..."
    echo ""
    $DO_GIT && uninstall_git
    $DO_CLAUDE && uninstall_claude
    $DO_CI && uninstall_ci
    echo ""
    echo "Done."
    ;;

  status)
    echo ""
    echo "doc-superpowers hooks status"
    echo ""
    status_git
    echo ""
    status_claude
    echo ""
    status_ci
    echo ""
    echo "Env overrides: DOC_SUPERPOWERS_STRICT=${DOC_SUPERPOWERS_STRICT:-unset} DOC_SUPERPOWERS_SKIP=${DOC_SUPERPOWERS_SKIP:-unset}"
    ;;

  *)
    usage
    ;;
esac
```

- [ ] **Step 4: Make executable**

Run: `chmod +x scripts/hooks/install.sh`

- [ ] **Step 5: Run tests**

Run: `bash scripts/test-hooks.sh`
Expected: All installer tests PASS

- [ ] **Step 6: Commit**

```bash
git add scripts/hooks/install.sh scripts/test-hooks.sh
git commit -m "feat: add hooks installer with install/uninstall/status"
```

---

## Chunk 5: Integration (SKILL.md, README, CLAUDE.md, RELEASE-NOTES)

### Task 12: Add `hooks` action to SKILL.md

**Files:**
- Modify: `SKILL.md:169` (Section 1, after `sync` action around line 312)

- [ ] **Step 1: Add hooks action routing after the `sync` section (before `## 2. Agent Prompt Template` at line 315)**

Insert before line 315 (`## 2. Agent Prompt Template`):

```markdown
### `hooks` — Install Workflow Hooks

Scaffolding command — installs opt-in hooks into the target project for automated freshness monitoring. No discovery phase needed.

```
/doc-superpowers hooks install [--git] [--claude] [--ci] [--all]
/doc-superpowers hooks status
/doc-superpowers hooks uninstall [--git] [--claude] [--ci] [--all]
```

Routes to `scripts/hooks/install.sh <subcommand> [flags]`.

**Tier options:**
- `--git` — Git hooks: pre-commit (freshness gate), post-merge (stale alert), post-checkout (branch check), prepare-commit-msg (inject comments)
- `--claude` — Claude Code hooks: PreToolUse pre-commit gate, Stop session summary
- `--ci` — CI/CD workflows: PR freshness check, weekly audit, doc-index auto-update

**CI-specific flags:**
- `--base-branch NAME` — Target branch (default: `main`)
- `--cron EXPR` — Schedule expression (default: `0 9 * * 1`)
- `--ci-strict` — Make PR check a required status

When no tier flags are provided via SKILL.md routing, present options to the user and pass the appropriate flags. The installer's interactive menu is for direct terminal invocation only.
```

- [ ] **Step 2: Update the Usage section at line 14-18 to include hooks**

Change the usage block from:
```
Actions: init | audit | review-pr | update | diagram | sync
```
to:
```
Actions: init | audit | review-pr | update | diagram | sync | hooks
```

- [ ] **Step 3: Commit**

```bash
git add SKILL.md
git commit -m "feat: add hooks action routing to SKILL.md"
```

### Task 13: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add `hooks` to the Commands section**

Add after the existing sync command entry:

```markdown
- `/doc-superpowers hooks install [--git] [--claude] [--ci] [--all]` — Install workflow hooks
- `/doc-superpowers hooks status` — Show installed hooks
- `/doc-superpowers hooks uninstall` — Remove installed hooks
```

- [ ] **Step 2: Add `scripts/hooks/` to the Directory Structure**

In the directory tree, add under `scripts/`:
```
│   └── hooks/
│       ├── install.sh        # Hook installer engine
│       ├── git/              # Git hook scripts
│       ├── claude/           # Claude Code hook scripts
│       └── ci/               # GitHub Actions workflow templates
```

- [ ] **Step 3: Add install.sh to Key Files table**

Add row:
```markdown
| `scripts/hooks/install.sh` | Hook installer — install/uninstall/status for all tiers | Adding hook tiers, changing installer logic |
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add hooks commands and files to CLAUDE.md"
```

### Task 14: Update README.md

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add hooks command to the usage section**

After the existing command list, add:

```markdown
### Workflow Integration

Install opt-in hooks for automated freshness monitoring:

```bash
# Install all hook tiers
/doc-superpowers hooks install --all

# Or pick specific tiers
/doc-superpowers hooks install --git           # Git hooks
/doc-superpowers hooks install --claude        # Claude Code hooks
/doc-superpowers hooks install --ci            # GitHub Actions

# Check what's installed
/doc-superpowers hooks status

# Remove hooks
/doc-superpowers hooks uninstall --all
```

**Git hooks:** Pre-commit warns when staged files affect stale docs. Post-merge and post-checkout alert on branch switches. Prepare-commit-msg injects freshness comments.

**Claude Code hooks:** Pre-commit gate catches Claude-initiated commits. Session summary reminds about stale docs when ending a session.

**CI/CD:** PR freshness check comments on PRs. Weekly cron detects drift. Post-merge workflow keeps the doc index in sync.

Set `DOC_SUPERPOWERS_STRICT=1` to make pre-commit block instead of warn. Set `DOC_SUPERPOWERS_SKIP=1` to bypass all hooks temporarily.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add workflow integration section to README"
```

### Task 15: Update RELEASE-NOTES.md

**Files:**
- Modify: `RELEASE-NOTES.md`

- [ ] **Step 1: Add v2.1.0 entry at the top (before ## v2.0.0)**

```markdown
## v2.1.0 (2026-03-13)

### Features
- **Workflow hooks harness**: Opt-in hooks that plug doc-superpowers into git, Claude Code, and CI/CD workflows.
  - Git hooks: `pre-commit` (freshness gate), `post-merge` (stale alert), `post-checkout` (branch check), `prepare-commit-msg` (commit message injection)
  - Claude Code hooks: `PreToolUse` pre-commit gate, `Stop` session summary
  - CI/CD workflows: PR freshness check, weekly drift detector, post-merge index auto-update
- **Tiered installer**: `/doc-superpowers hooks install [--git] [--claude] [--ci] [--all]` with status and uninstall support
- **Environment variable controls**: `DOC_SUPERPOWERS_SKIP`, `DOC_SUPERPOWERS_STRICT`, `DOC_SUPERPOWERS_QUIET`
- **CI parameterization**: `--base-branch`, `--cron`, `--ci-strict` flags for CI tier
```

- [ ] **Step 2: Commit**

```bash
git add RELEASE-NOTES.md
git commit -m "docs: add v2.1.0 release notes for workflow hooks harness"
```

---

## Chunk 6: Run Full Test Suite and Verify

### Task 16: Run all tests and fix any failures

- [ ] **Step 1: Run the hooks test suite**

Run: `bash scripts/test-hooks.sh`
Expected: All tests PASS (0 failed)

- [ ] **Step 2: Run the existing doc-tools test suite (regression check)**

Run: `bash scripts/test-doc-tools.sh`
Expected: All existing tests still PASS

- [ ] **Step 3: Run the installer end-to-end in a temp repo**

Run in a temp directory:
```bash
tmpdir=$(mktemp -d) && cd "$tmpdir"
git init && git config user.email "t@t.com" && git config user.name "T"
mkdir -p docs src && echo "# Arch" > docs/arch.md && echo "x" > src/main.js
git add -A && git commit -m "init"
echo "docs/arch.md:src/:architecture" | /path/to/doc-tools.sh build-index
/path/to/install.sh install --all
/path/to/install.sh status
/path/to/install.sh uninstall --all
/path/to/install.sh status
```
Expected: Install creates all hooks, status reports them, uninstall removes them, status shows nothing installed.

- [ ] **Step 4: Verify pre-commit hook fires in a real git commit**

In the temp repo after installing:
```bash
/path/to/install.sh install --git
echo "changed" > src/main.js
git add src/main.js
git commit -m "test commit"
```
Expected: Pre-commit hook fires and shows stale doc warning (since docs/arch.md tracks src/ and src/ changed).

- [ ] **Step 5: Fix any failing tests or issues found**

If failures: fix, re-run, re-commit.

- [ ] **Step 6: Final commit if any fixes were needed**

```bash
git add -A
git commit -m "fix: address test failures from integration testing"
```

---

## Chunk 7: Spec Completeness — Deferred Integration Points

### Task 17: Add hooks prompt to `init` action in SKILL.md

Per spec resolved decision 1: after `init` generates docs, suggest hooks installation.

**Files:**
- Modify: `SKILL.md` (init action, around line 195)

- [ ] **Step 1: Add prompt after verification gate (step 12 of init)**

After the verification gate step in the `init` action, add:

```markdown
13. **Suggest workflow hooks**: After successful init, suggest: "Documentation generated. To keep docs fresh automatically, run `/doc-superpowers hooks install` to set up workflow hooks."
```

- [ ] **Step 2: Commit**

```bash
git add SKILL.md
git commit -m "feat: add hooks install prompt to init action"
```

### Task 18: Add hooks summary to `sync` action output

Per spec resolved decision 3: append one-line hooks summary to sync output.

**Files:**
- Modify: `SKILL.md` (sync action, around line 311)

- [ ] **Step 1: Add hooks status step to sync action**

After step 5 in the `sync` action, add:

```markdown
6. If `scripts/hooks/install.sh` exists in the skill directory, run `install.sh status` and append a one-line summary: `Hooks: N/4 git, N/2 claude, N/3 ci`
```

- [ ] **Step 2: Commit**

```bash
git add SKILL.md
git commit -m "feat: add hooks status summary to sync action"
```

### Task 19: Add corrupted index test

Per spec graceful degradation matrix: corrupted/conflicted doc-index should exit 0 silently.

**Files:**
- Modify: `scripts/test-hooks.sh`

- [ ] **Step 1: Add test for corrupted doc-index**

Add to test-hooks.sh in the pre-commit section:

```bash
test_pre_commit_exits_0_corrupted_index() {
  echo "test: pre-commit exits 0 with corrupted doc-index"
  setup
  echo "NOT VALID JSON{{{" > docs/.doc-index.json
  echo "changed" > src/index.js
  git add src/index.js
  set +e
  output=$(DOC_TOOLS="$DOC_TOOLS" bash "$HOOKS_DIR/git/pre-commit" 2>&1)
  exit_code=$?
  set -e
  assert_eq "0" "$exit_code" "exits 0 with corrupted index"
  teardown
}
```

And add it to the test runner.

- [ ] **Step 2: Run tests**

Run: `bash scripts/test-hooks.sh`
Expected: New test PASSES (jq parse failure caught by `|| exit 0`)

- [ ] **Step 3: Commit**

```bash
git add scripts/test-hooks.sh
git commit -m "test: add corrupted doc-index graceful degradation test"
```
