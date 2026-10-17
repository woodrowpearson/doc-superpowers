#!/usr/bin/env bash
# Fixture for eval "spec-inject-claims": the spec-inject-claims-inert project,
# opted in to claims. docs/spec-claims/ holds SPEC-AUTH-001's sidecar: two
# unbuilt stub claims (as spec-generate step 6b writes them, tracker = the
# design doc), one per requirement, and the spec carries its rendered status
# block. spec-inject --phase=plan must now also inject a Claims gate in each
# chunk (before its spec-update task), a Final claims gate before the finalize
# task, and a **Claims:** line on each implementation task — Task 1 naming
# SPEC-AUTH-001#token-ttl and Task 3 SPEC-AUTH-001#refresh-single-use (V12:
# every unbuilt claim of a target spec is named on some task).
. "$(dirname "$0")/../lib.sh"
[ -z "$(ls -A . 2>/dev/null)" ] || fx_die "run from an empty directory ($(pwd -P) is not empty)"
"${BASH_BIN:-bash}" "$(dirname "$0")/../spec-inject-claims-inert/setup.sh"
fx_attach "$0"

PLAN=docs/superpowers/plans/2026-10-02-auth-tokens.md
SPEC=docs/specs/SPEC-AUTH-001-token-lifetime.md
DESIGN=docs/superpowers/specs/2026-10-01-auth-tokens-design.md

fx_write docs/spec-claims/SPEC-AUTH-001.json <<EOF
{
  "schema": 1,
  "doc": "$SPEC",
  "claims": [
    {
      "id": "SPEC-AUTH-001#token-ttl",
      "quote": "Access tokens expire after 15 minutes.",
      "states": "An issued access token is rejected 15 minutes after issue.",
      "kind": "behaviour",
      "subject": ["src/auth/token.py"],
      "status": "unbuilt",
      "enforced_by": "test",
      "test": null,
      "tracker": "$DESIGN"
    },
    {
      "id": "SPEC-AUTH-001#refresh-single-use",
      "quote": "Refresh tokens are single-use.",
      "states": "A refresh token is rejected on its second use.",
      "kind": "behaviour",
      "subject": ["src/auth/session.py"],
      "status": "unbuilt",
      "enforced_by": "test",
      "test": null,
      "tracker": "$DESIGN"
    }
  ]
}
EOF
dt claims render >/dev/null
fx_commit "docs: SPEC-AUTH-001's claims"
# The spec's bytes changed (its status block): re-baseline it, as a reviewer
# would after reading it.
dt update-index "$SPEC" >/dev/null 2>&1
fx_commit "docs: index"
# The opt-in is on the trunk too: origin/main is the claims verbs' base.
git update-ref refs/remotes/origin/main HEAD

fx_expect "claims are enabled" test -d docs/spec-claims
fx_expect "the spec carries its rendered status block" grep -q '<!-- spec-claims:status:begin -->' "$SPEC"
fx_expect "claims validate --all passes (enabled, exit 0)" \
  test "$(dt claims validate --all 2>/dev/null | jq -r '[.enabled, .exit] | map(tostring) | join(" ")')" = "true 0"
fx_expect "both claims are unbuilt" \
  test "$(jq '[.claims[] | select(.status == "unbuilt")] | length' docs/spec-claims/SPEC-AUTH-001.json)" = 2
fx_expect "nothing is injected yet" sh -c '! grep -qE "Update governing specs|Claims gate|\*\*Claims:\*\*" "$0"' "$PLAN"
fx_expect "the spec is current in the index" test "$(fx_fresh ".docs[\"$SPEC\"].status")" = current
