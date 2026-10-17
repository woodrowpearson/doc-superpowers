#!/usr/bin/env bash
# Fixture for eval "spec-inject-ledger": the spec-inject-claims-inert project
# (no docs/spec-claims/), opted in to the work ledger. docs/ledger/config.json
# is {} (every key defaulted), the registry holds one ledger, "auth", owning
# src/auth/** and the contract field:token.ttl (defined in
# src/auth/token.py), and one open item, auth-1, consumes that contract.
# The plan names `src/auth/token.py`, so `ledger sweep --plan` relates auth-1
# to it. spec-inject --phase=plan must now also paste the sweep's
# "## Related work" table into the plan and inject a "Ledger notices
# (chunk N)" task, running `ledger notices --gate`, at the end of each chunk
# (references/spec-lifecycle-actions.md, Plan Phase steps 1c and 2c) — and,
# claims being inert here, still no claims gate.
. "$(dirname "$0")/../lib.sh"
[ -z "$(ls -A . 2>/dev/null)" ] || fx_die "run from an empty directory ($(pwd -P) is not empty)"
"${BASH_BIN:-bash}" "$(dirname "$0")/../spec-inject-claims-inert/setup.sh"
fx_attach "$0"

PLAN=docs/superpowers/plans/2026-10-02-auth-tokens.md
ITEM=docs/issues/2026-10-01-access-tokens-live-an-hour.md

fx_write docs/ledger/config.json <<'EOF2'
{}
EOF2
fx_write docs/ledger/ledgers.json <<'EOF2'
{ "schema": "ledger-registry/1",
  "ledgers": [
    { "id": "auth", "title": "Auth", "kind": "service", "status": "active",
      "scope": "Token issue, lifetime and refresh.",
      "paths": ["src/auth/**"], "residual_paths": [],
      "contracts": [ { "id": "field:token.ttl", "defined_in": ["src/auth/token.py"] } ],
      "governing": ["docs/specs/SPEC-AUTH-001-token-lifetime.md"] } ] }
EOF2
fx_write "$ITEM" <<'EOF2'
---
key: auth-1
ledger: auth
status: open
severity: P1
summary: Access tokens live an hour, so a leaked token stays usable far too long
consumes: [field:token.ttl]
related-files: [src/auth/token.py]
---
# Access tokens live an hour

`TTL_SECONDS` in `src/auth/token.py` is 3600.
EOF2
fx_commit "docs: the work ledger (auth) and its first item"
git update-ref refs/remotes/origin/main HEAD

fx_expect "the ledger is enabled" test -f docs/ledger/config.json
fx_expect "claims stay inert" test ! -e docs/spec-claims
fx_expect "the registry is valid" dt ledger validate --registry
fx_expect "every item validates" dt ledger validate --all
fx_expect "auth-1 is the open item" \
  test "$(dt ledger show auth-1 --format json 2>/dev/null | jq -r '.item.class')" = open
fx_expect "the sweep relates auth-1 to the plan" \
  test "$(dt ledger sweep --plan "$PLAN" 2>/dev/null | grep -c '^| auth-1 |')" = 1
fx_expect "nothing is injected yet" sh -c '! grep -qE "Update governing specs|Related work|Ledger notices" "$0"' "$PLAN"
