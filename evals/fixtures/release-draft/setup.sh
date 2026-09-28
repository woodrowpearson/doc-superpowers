#!/usr/bin/env bash
# Fixture for eval "release-draft": v1.2.0 is released and tagged; since then
# a feat, a fix and a docs commit, and no RELEASE-NOTES.next/ fragments.
. "$(dirname "$0")/../lib.sh"
fx_init "$0"
fx_release_base

fx_expect "the last release tag is v1.2.0" test "$(git describe --tags --abbrev=0 --match 'v[0-9]*')" = v1.2.0
fx_expect "three commits are unreleased" test "$(git rev-list --count v1.2.0..HEAD)" = 3
fx_expect "no fragments" test ! -e RELEASE-NOTES.next
fx_expect "the manifest is at 1.2.0" test "$(jq -r .version package.json)" = 1.2.0
