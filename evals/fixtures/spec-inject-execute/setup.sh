#!/usr/bin/env bash
# Fixture for eval "spec-inject-execute": chunk 1 of a plan WITHOUT injected
# spec tasks has landed (so this execute phase is the chunk's one writer).
# Three governing specs: a Draft target the chunk implements, an In Review
# constraint it must not touch, and an Active reference spec (exempt) whose
# broad code_refs make it read stale too.
. "$(dirname "$0")/../lib.sh"
fx_init "$0"

fx_write src/app.py <<'EOF'
from auth import oauth
from api import orders
EOF
fx_write src/auth/oauth.py <<'EOF'
AUTHORIZE_URL = "https://accounts.google.com/o/oauth2/v2/auth"
EOF
fx_write src/api/orders.py <<'EOF'
ALLOWED_FIELDS = ("id", "item", "quantity")
EOF
fx_write docs/specs/SPEC-AUTH-001-oauth-flow.md <<'EOF'
# SPEC-AUTH-001: OAuth Flow

**Status**: Draft
**Category**: AUTH
**Created**: 2026-09-01
**Author**: eval
**Supersedes**: none
**Superseded by**: none
**Source**: manual

Realized-by: []

## Summary

Sign-in uses Google OAuth 2.0 with PKCE.

## Design

The callback `/auth/callback` receives `code` and `state`, checks `state`,
exchanges the code (with the PKCE verifier) for tokens, and starts a session.

## Implementation Notes
EOF
fx_write docs/specs/SPEC-API-006-backend.md <<'EOF'
# SPEC-API-006: Backend Field Allowlist

**Status**: In Review
**Category**: API
**Created**: 2026-08-01
**Author**: eval
**Supersedes**: none
**Superseded by**: none
**Source**: manual

Realized-by: []

## Summary

The orders API returns only `id`, `item` and `quantity`.
EOF
fx_write docs/specs/SPEC-ARCH-004-system-overview.md <<'EOF'
# SPEC-ARCH-004: System Overview

**Status**: Active
**Category**: ARCH
**Created**: 2026-06-01
**Author**: eval
**Supersedes**: none
**Superseded by**: none
**Source**: manual

Realized-by: []

## Summary

A continuously evolving reference: the service is `src/app.py` plus the
`auth` and `api` packages.
EOF
fx_write docs/superpowers/plans/2026-09-01-auth.md <<'EOF'
# OAuth Sign-in — Implementation Plan

## Chunk 1: The OAuth callback

### Task 1: Add the callback handler
- [x] **Step 1:** Create `src/auth/callback.py` with `handle_callback(code, state)`.
- [x] **Step 2:** Verify `state` against the session.

### Task 2: Exchange the code
- [x] **Step 1:** Add `exchange_code(code, verifier)` to `src/auth/oauth.py`.

## Chunk 2: Sessions

### Task 3: Start a session after the exchange
- [ ] **Step 1:** Create `src/auth/session.py`.
EOF
fx_commit "docs: auth specs and plan"
printf '%s\n' \
  docs/specs/SPEC-AUTH-001-oauth-flow.md:src/auth/:spec \
  docs/specs/SPEC-API-006-backend.md:src/api/:spec \
  docs/specs/SPEC-ARCH-004-system-overview.md:src/:spec | dt build-index >/dev/null
dt update-index docs/specs/SPEC-AUTH-001-oauth-flow.md docs/specs/SPEC-API-006-backend.md \
  docs/specs/SPEC-ARCH-004-system-overview.md >/dev/null
fx_commit "docs: index"

# Chunk 1 lands.
fx_write src/auth/callback.py <<'EOF'
from auth.oauth import exchange_code

def handle_callback(code, state, session):
    if state != session.get("oauth_state"):
        raise PermissionError("state mismatch")
    return exchange_code(code, session["pkce_verifier"])
EOF
cat >> src/auth/oauth.py <<'EOF'

def exchange_code(code, verifier):
    """POST the code and the PKCE verifier to the token endpoint."""
EOF
fx_commit "feat(auth): OAuth callback (chunk 1)"

fx_expect "the target spec is stale" test "$(fx_fresh '.docs["docs/specs/SPEC-AUTH-001-oauth-flow.md"].status')" = stale
fx_expect "the constraint spec is current" test "$(fx_fresh '.docs["docs/specs/SPEC-API-006-backend.md"].status')" = current
fx_expect "the Active spec reads stale (its ref src/ changed)" \
  test "$(fx_fresh '.docs["docs/specs/SPEC-ARCH-004-system-overview.md"].status')" = stale
fx_expect "the plan carries no injected spec tasks (this phase is the writer)" \
  sh -c '! grep -q "Update governing specs for this chunk" docs/superpowers/plans/2026-09-01-auth.md'
