#!/usr/bin/env bash
# Fixture for eval "spec-inject-amends": a two-chunk plan whose Task 3 (chunk
# 2) quotes the AMENDED block it will write into SPEC-UI-041's `## Design`.
# Injection must add ONE Task N+1a, in chunk 2 — none in chunk 1, where the
# block cannot exist yet.
. "$(dirname "$0")/../lib.sh"
fx_init "$0"

PLAN=docs/superpowers/plans/2026-09-01-recents.md
fx_write src/ui/collection.js <<'EOF'
export const render = (items) => items.map((i) => i.name);
EOF
fx_write src/ui/recents.js <<'EOF'
export const sortRecents = (items) => items.sort((a, b) => a.name.localeCompare(b.name));
EOF
fx_write docs/specs/SPEC-UI-010-collection-view.md <<'EOF'
# SPEC-UI-010: Collection View

**Status**: In Review
**Category**: UI
**Created**: 2026-07-01
**Author**: eval
**Supersedes**: none
**Superseded by**: none
**Source**: manual

Realized-by: []

## Design

The collection renders item names in a grid.
EOF
fx_write docs/specs/SPEC-UI-041-recents.md <<'EOF'
# SPEC-UI-041: Recents

**Status**: Implemented
**Category**: UI
**Created**: 2026-05-01
**Author**: eval
**Supersedes**: none
**Superseded by**: none
**Source**: manual

Realized-by: []

## Design

Items are sorted by name.
EOF
fx_write "$PLAN" <<'EOF'
# Collection and Recents — Implementation Plan

## Chunk 1: Collection grid

### Task 1: Render the grid
- [ ] **Step 1:** Render item names in `src/ui/collection.js`.

### Task 2: Grid tests
- [ ] **Step 1:** Cover an empty collection.

## Chunk 2: Recents order

### Task 3: Sort recents by last access
- [ ] **Step 1:** Sort by `lastAccess` in `src/ui/recents.js`.
- [ ] **Step 2:** Amend SPEC-UI-041 `## Design`:

> ⚠️ **AMENDED 2026-09-01 — sort order.** Landed by `docs/superpowers/plans/2026-09-01-recents.md` Task 3. The list was
> sorted by name; it is sorted by last access, newest first.

### Task 4: Recents tests
- [ ] **Step 1:** Cover ties.
EOF
fx_commit "docs: specs and plan"
printf '%s\n' docs/specs/SPEC-UI-010-collection-view.md:src/ui/collection.js:spec \
  docs/specs/SPEC-UI-041-recents.md:src/ui/recents.js:spec | dt build-index >/dev/null
fx_commit "docs: index"

fx_expect "the plan has two chunks" test "$(grep -c '^## Chunk ' "$PLAN")" = 2
fx_expect "Task 3 quotes the block, citing the plan on its first line" \
  grep -q "^> ⚠️ \*\*AMENDED 2026-09-01 — sort order.\*\* Landed by \`$PLAN\` Task 3" "$PLAN"
fx_expect "the spec does not carry the block yet" sh -c '! grep -q AMENDED docs/specs/SPEC-UI-041-recents.md'
fx_expect "nothing is injected yet" sh -c '! grep -q "Land the spec amendment" "$0"' "$PLAN"
