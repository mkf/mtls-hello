#!/bin/bash
# CGI handler: GET /spool → list covered commit ranges from the spool directory.
# Query: repo=<name>
# Requires a trusted client certificate.
set -euo pipefail

# shellcheck disable=SC1091
source "${MTLS_DATA_DIR}/scripts/cgi-common.sh"
# shellcheck disable=SC1091
source "${MTLS_DATA_DIR}/scripts/cgi-trust.sh"

cert="${SSL_CLIENT_CERT:-}"
if [ -z "$cert" ]; then
    cgi_error "401 Unauthorized" "No client certificate presented"
fi

if ! is_trusted; then
    cgi_error "401 Unauthorized" "Untrusted"
fi

cgi_parse_query

repo="${QUERY_REPO:-}"
if [ -z "$repo" ]; then
    cgi_error "400 Bad Request" "Missing repo parameter"
fi

spool_dir="${MTLS_DATA_DIR}/spool/${repo}"

cgi_header "text/plain"

[ -d "$spool_dir" ] || exit 0

for f in "$spool_dir"/*.bundle; do
    [ -f "$f" ] || continue
    base=$(basename "$f" .bundle)
    from="${base%%-*}"
    to="${base##*-}"
    echo "$from $to"
done
