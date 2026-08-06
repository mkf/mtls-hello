#!/bin/bash
# CGI handler: GET /hello → echoes the path segment as text/plain.
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

cgi_header "text/plain"
echo "${PATH_INFO#/}"
