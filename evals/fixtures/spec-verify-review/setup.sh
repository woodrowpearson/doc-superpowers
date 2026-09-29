#!/usr/bin/env bash
# Fixture for eval "spec-verify-review": two :amends specs of one plan. Task 3
# of the plan landed SPEC-UI-041's block in its `## Design` section, citing the
# plan. SPEC-UI-042 carries only an OLDER block, from another plan — the one
# this plan's Task 4 promised never landed. The fixture checks both with the
# landed-check command of references/spec-lifecycle-actions.md itself.
. "$(dirname "$0")/../lib.sh"
fx_init "$0"

PLAN=docs/superpowers/plans/2026-09-01-recents.md
fx_write src/ui/recents.js <<'EOF'
export const sortRecents = (items) => items.sort((a, b) => b.name.localeCompare(a.name));
EOF
fx_write src/ui/favorites.js <<'EOF'
export const sortFavorites = (items) => items.sort((a, b) => a.pinnedAt - b.pinnedAt);
EOF
fx_write "$PLAN" <<'EOF'
# Recents and Favorites — Implementation Plan

## Chunk 1: Recents

### Task 3: Sort recents by last access

Sort by `lastAccess`, newest first, and amend SPEC-UI-041 `## Design`:

> ⚠️ **AMENDED 2026-09-01 — sort order.** Landed by `docs/superpowers/plans/2026-09-01-recents.md` Task 3. The list was
> sorted by name; it is sorted by last access, newest first.

### Task 4: Pin order for favorites

Amend SPEC-UI-042 `## Design`:

> ⚠️ **AMENDED 2026-09-01 — pin order.** Landed by `docs/superpowers/plans/2026-09-01-recents.md` Task 4. Favorites
> were ordered by pin time; they are ordered by name.
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

## Summary

The recents list shows the last 20 opened items.

## Design

> ⚠️ **AMENDED 2026-09-01 — sort order.** Landed by `docs/superpowers/plans/2026-09-01-recents.md` Task 3. The list was
> sorted by name; it is sorted by last access, newest first.

Items are sorted by last access.
EOF
fx_write docs/specs/SPEC-UI-042-favorites.md <<'EOF'
# SPEC-UI-042: Favorites

**Status**: Implemented
**Category**: UI
**Created**: 2026-05-01
**Author**: eval
**Supersedes**: none
**Superseded by**: none
**Source**: manual

Realized-by: []

## Summary

Favorites are pinned items.

## Design

> ⚠️ **AMENDED 2026-06-10 — pinning.** Landed by `docs/superpowers/plans/2026-06-10-favorites.md` Task 2. Pinning was
> per device; it is per account.

Favorites are ordered by pin time.
EOF
fx_commit "docs: specs and plan"
printf '%s\n' docs/specs/SPEC-UI-041-recents.md:src/ui/recents.js:spec \
  docs/specs/SPEC-UI-042-favorites.md:src/ui/favorites.js:spec | dt build-index >/dev/null
fx_commit "docs: index"
fx_write src/ui/recents.js <<'EOF'
export const sortRecents = (items) => items.sort((a, b) => b.lastAccess - a.lastAccess);
EOF
fx_commit "feat(ui): sort recents by last access"

# The landed-check, exactly as the reference defines it.
LC=$(grep -E "^[[:space:]]*awk -v h='\{section-heading\}'" "$FX_ROOT/references/spec-lifecycle-actions.md" | head -n 1 | sed 's/^[[:space:]]*//')
[ -n "$LC" ] || fx_die "no landed-check command in references/spec-lifecycle-actions.md"
landed() { # <spec>
  local c="$LC"
  c=${c//\{section-heading\}/## Design}
  c=${c//\{spec-path\}/$1}
  c=${c//\{plan-path\}/$PLAN}
  "$FX_BASH" -c "$c"
}
not_landed() { ! landed "$1"; }
fx_expect "SPEC-UI-041's amendment landed and cites the plan" landed docs/specs/SPEC-UI-041-recents.md
fx_expect "SPEC-UI-042's promised amendment did not land" not_landed docs/specs/SPEC-UI-042-favorites.md
fx_expect "only the recents code changed since the index" \
  test "$(git -c core.quotePath=false diff --name-only HEAD~1 HEAD)" = src/ui/recents.js
