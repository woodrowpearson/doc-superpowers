#!/bin/sh
# doc-superpowers terminal shim v1
# The terminal command `doc-superpowers`: `doc-superpowers setup` writes this
# file to ~/.local/bin/doc-superpowers when its Terminal command item is
# ticked (`doc-superpowers setup --yes --no-link-bin` removes it). It is a
# small POSIX sh script, not a link: a plugin update replaces the versioned
# plugin directory, so it finds doc-superpowers each time it runs, in this
# order:
#   1. $DOC_SUPERPOWERS_ROOT;
#   2. the clone setup ran from, written below when setup wrote this file
#      ('' for a plugin install);
#   3. the newest numeric X.Y.Z directory under
#      ${CLAUDE_PLUGIN_CACHE:-$HOME/.claude/plugins/cache}/*/doc-superpowers/.
# A candidate must hold scripts/doc-superpowers. That script then runs under
# the bash on PATH. No candidate: one line on stderr, exit 2.
# (setup reads line 2 to know the file is its own: it never replaces a file
# without it.)

clone_root=@CLONE_ROOT@

root=""
if [ -n "${DOC_SUPERPOWERS_ROOT:-}" ] && [ -f "$DOC_SUPERPOWERS_ROOT/scripts/doc-superpowers" ]; then
  root=$DOC_SUPERPOWERS_ROOT
elif [ -n "$clone_root" ] && [ -f "$clone_root/scripts/doc-superpowers" ]; then
  root=$clone_root
else
  cache=${CLAUDE_PLUGIN_CACHE:-$HOME/.claude/plugins/cache}
  # One "<version> <dir>" line per candidate, across every marketplace.
  candidates=""
  for dir in "$cache"/*/doc-superpowers/*; do
    [ -f "$dir/scripts/doc-superpowers" ] || continue
    version=${dir##*/}
    printf '%s\n' "$version" | grep -Ex '[0-9]+[.][0-9]+[.][0-9]+' >/dev/null 2>&1 || continue
    candidates="$candidates$version $dir
"
  done
  if [ -n "$candidates" ]; then
    # Numeric per field: 3.10.0 is newer than 3.9.0.
    root=$(printf '%s' "$candidates" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1 | cut -d' ' -f2-)
  fi
fi

if [ -z "$root" ]; then
  echo "doc-superpowers: cannot find doc-superpowers (set DOC_SUPERPOWERS_ROOT, or install the plugin)" >&2
  exit 2
fi
exec bash "$root/scripts/doc-superpowers" "$@"
