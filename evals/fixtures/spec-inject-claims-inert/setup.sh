#!/usr/bin/env bash
# Fixture for eval "spec-inject-claims-inert": a two-chunk plan governed by
# one Draft spec, in a project WITHOUT docs/spec-claims/. Claims are inert
# there, so spec-inject --phase=plan must inject exactly what it injects
# without claims: a spec-update task per chunk and one finalize task, and no
# Claims gate, no Final claims gate and no **Claims:** line.
# The eval "spec-inject-claims" builds this same project and then opts it in
# to claims (its setup runs this one first).
. "$(dirname "$0")/../lib.sh"
fx_init "$0"

PLAN=docs/superpowers/plans/2026-10-02-auth-tokens.md
SPEC=docs/specs/SPEC-AUTH-001-token-lifetime.md
DESIGN=docs/superpowers/specs/2026-10-01-auth-tokens-design.md

fx_write src/auth/token.py <<'EOF'
TTL_SECONDS = 3600


def issue(user):
    return {"user": user, "ttl": TTL_SECONDS}
EOF
fx_write src/auth/session.py <<'EOF'
def refresh(token):
    return {"user": token["user"]}
EOF
fx_write "$DESIGN" <<'EOF'
# Auth tokens — Design

**Status**: Approved

Access tokens get a 15-minute lifetime, and refresh tokens become single-use.
EOF
fx_write "$SPEC" <<'EOF'
# SPEC-AUTH-001: Token Lifetime

**Status**: Draft
**Category**: AUTH
**Created**: 2026-10-01
**Author**: eval
**Supersedes**: none
**Superseded by**: none
**Source**: docs/superpowers/specs/2026-10-01-auth-tokens-design.md

Realized-by: []

## Requirements

Access tokens expire after 15 minutes.

Refresh tokens are single-use.
EOF
fx_write "$PLAN" <<'EOF'
# Auth Tokens — Implementation Plan

## Chunk 1: Token lifetime

### Task 1: Expire access tokens
- [ ] **Step 1:** Set `TTL_SECONDS = 900` in `src/auth/token.py`.

### Task 2: Lifetime tests
- [ ] **Step 1:** Add `tests/test_token.py`: a token is rejected 15 minutes after issue.

## Chunk 2: Refresh rotation

### Task 3: Single-use refresh tokens
- [ ] **Step 1:** Reject a refresh token's second use in `src/auth/session.py`.

### Task 4: Rotation tests
- [ ] **Step 1:** Add `tests/test_session.py`: a second refresh with one token fails.
EOF
fx_commit "docs: auth tokens design, spec and plan"
printf '%s\n' "$SPEC:src/auth/:spec" | dt build-index >/dev/null
fx_commit "docs: index"
# The trunk as pushed: origin/main is the base the claims verbs resolve.
git update-ref refs/remotes/origin/main HEAD

fx_expect "the plan has two chunks" test "$(grep -c '^## Chunk ' "$PLAN")" = 2
fx_expect "the spec is a Draft target" grep -qx '\*\*Status\*\*: Draft' "$SPEC"
fx_expect "the spec is indexed" test "$(fx_fresh ".docs | has(\"$SPEC\")")" = true
fx_expect "nothing is injected yet" sh -c '! grep -qE "Update governing specs|Claims gate|\*\*Claims:\*\*" "$0"' "$PLAN"
# The inert path: no docs/spec-claims/, so every claims verb reports
# enabled:false and exits 0.
fx_expect "the project has no docs/spec-claims/" test ! -e docs/spec-claims
fx_expect "claims are inert (enabled: false)" \
  test "$(dt claims validate --all 2>/dev/null | jq -r '.enabled')" = false
