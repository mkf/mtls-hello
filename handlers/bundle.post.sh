#!/bin/bash
# CGI handler: POST /bundle → receive a git bundle and spool it.
# The bundle is saved to <data-dir>/spool/<repo>/<from>-<to>.bundle
# instead of being applied immediately. The operator runs merge-spool.sh.
# Requires a trusted client certificate.
set -euo pipefail

# shellcheck disable=SC1091
source "${MTLS_DATA_DIR}/scripts/cgi-lib.sh"

cgi_require_trusted

cgi_parse_query

repo="${QUERY_REPO:-}"
if [ -z "$repo" ]; then
    cgi_error "400 Bad Request" "Missing repo parameter"
fi

from="${QUERY_FROM:-0000000000000000000000000000000000000000}"
to="${QUERY_TO:-}"

spool_dir="${MTLS_DATA_DIR}/spool/${repo}"
mkdir -p "$spool_dir"

# Read the bundle from stdin.
tmp_bundle="$(mktemp)"
cat > "$tmp_bundle"

# Extract the tip SHA from the bundle if not provided.
if [ -z "$to" ]; then
    to=$(git bundle list-heads "$tmp_bundle" 2>/dev/null | head -1 | awk '{print $1}')
    [ -n "$to" ] || to="unknown"
fi

dest="$spool_dir/${from}-${to}.bundle"
mv "$tmp_bundle" "$dest"

cgi_header "text/plain"
echo "spooled"
