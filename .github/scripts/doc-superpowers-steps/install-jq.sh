#!/usr/bin/env bash
# Every workflow's first step script: the job's jq, at a version that has the
# fixes for what crafted JSON can reach, because these jobs run jq over PR
# content and the runner's jq is older (1.7.1 on the Ubuntu images). The build
# is checked against the digest recorded here before anything runs it.
#
# jq 1.8.2 (2026-06-20) fixes CVE-2026-32316, -33948, -39979, -40164, -40612,
# -47770 and -49839, among others. To move the pin: the new release's asset
# digests, from `gh api repos/jqlang/jq/releases/tags/jq-<version>`, here.
#
# A digest that does not match always fails the job. A download that does not
# happen is an outage, not an attack: the job carries on with the runner's jq
# and a ::warning:: (an ::error:: under DOC_SUPERPOWERS_STRICT=1), as it does on
# a platform with no pinned build.
#
# Env: RUNNER_TEMP, GITHUB_PATH (set by the runner); DOC_SUPERPOWERS_STRICT.
#
# Exit codes: 0 (the pinned jq is on the job's PATH, or the warning above); 1
# (with an ::error::) for a wrong digest, a build that is not the pinned version,
# or a warning's case under strict.
set -euo pipefail

VERSION=1.8.2

err() {
  echo "::error::doc-superpowers: $*"
  exit 1
}

# The job can run without the pinned jq, but should know.
cannot() {
  if [ "${DOC_SUPERPOWERS_STRICT:-0}" = 1 ]; then
    err "$*"
  fi
  echo "::warning::doc-superpowers: $*; this job uses the runner's jq ($(jq --version 2>/dev/null || echo none))."
  exit 0
}

if [ -z "${RUNNER_TEMP:-}" ] || [ ! -d "$RUNNER_TEMP" ]; then
  err "RUNNER_TEMP is not a directory"
fi
[ -n "${GITHUB_PATH:-}" ] || err "GITHUB_PATH is not set (this runs as a GitHub Actions step)"

if [ "$(jq --version 2>/dev/null || true)" = "jq-$VERSION" ]; then
  echo "jq $VERSION is already on the runner."
  exit 0
fi

platform="$(uname -s)-$(uname -m)"
case "$platform" in
  Linux-x86_64) asset=jq-linux-amd64 sum=b1c22172dd303f3be49e935aa56aa48a8b7a46e0bc838b4997d3bb451495870f ;;
  Linux-aarch64 | Linux-arm64) asset=jq-linux-arm64 sum=8b85c817833814ddca00a144c33705546355afccf0cf39b188f3cdb48b852309 ;;
  Darwin-x86_64) asset=jq-macos-amd64 sum=e94b266e3c26690550006abe63152b782280f4e14374accdf04cbde844f00bc0 ;;
  Darwin-arm64) asset=jq-macos-arm64 sum=2d75340ba57a4b4b4c8708a21c2dc8e958a48aaa8bba13b27f77f6e4c0eca07e ;;
  *) cannot "no pinned jq $VERSION build for $platform" ;;
esac

dir=$(mktemp -d "$RUNNER_TEMP/doc-superpowers-jq.XXXXXX") || err "cannot create a directory under $RUNNER_TEMP"
url="https://github.com/jqlang/jq/releases/download/jq-$VERSION/$asset"
if ! curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 20 --max-time 120 -o "$dir/jq" "$url"; then
  rm -rf "$dir"
  cannot "cannot download $url"
fi

if command -v sha256sum >/dev/null 2>&1; then
  found=$(sha256sum < "$dir/jq")
else
  found=$(shasum -a 256 < "$dir/jq")
fi
found="${found%% *}"
if [ "$found" != "$sum" ]; then
  rm -rf "$dir"
  err "$url has sha256 $found, not the pinned $sum. Nothing from it ran. Find out why before re-running this job."
fi

chmod 0755 "$dir/jq"
if [ "$("$dir/jq" --version 2>/dev/null || true)" != "jq-$VERSION" ]; then
  rm -rf "$dir"
  err "the verified $asset does not report jq-$VERSION"
fi
printf '%s\n' "$dir" >> "$GITHUB_PATH"
echo "jq $VERSION (sha256 $sum) is on this job's PATH."
