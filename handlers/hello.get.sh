#!/bin/bash
# CGI handler: GET /hello → echoes the path segment as text/plain.
# Requires a trusted client certificate.
set -euo pipefail

# shellcheck disable=SC1091
source "${MTLS_DATA_DIR}/scripts/cgi-lib.sh"

cgi_require_trusted

cgi_header "text/plain"
echo "${PATH_INFO#/}"
