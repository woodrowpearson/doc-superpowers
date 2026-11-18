#!/usr/bin/env bash
# The step of doc-index-resolve.yml (not yet implemented). It merges the doc
# index with the driver vendored beside it.
set -euo pipefail
DRIVER="$(dirname "$0")/merge-doc-index.sh"
echo "::error::index-resolve.sh is not implemented yet ($DRIVER)"
exit 3
