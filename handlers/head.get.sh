#!/bin/bash
# CGI handler: GET /head → return HEAD SHA and branch SHAs for a bare repository.
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

repo_dir="${MTLS_REPOS_ROOT}/${repo}.git"

cgi_header "text/plain"

if [ ! -d "$repo_dir" ]; then
    echo "HEAD 0000000000000000000000000000000000000000"
    exit 0
fi

head=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || echo "0000000000000000000000000000000000000000")
echo "HEAD $head"

git -C "$repo_dir" for-each-ref --format='%(refname:short) %(objectname)' refs/heads/ 2>/dev/null || true
