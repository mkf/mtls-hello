#!/bin/bash
# CGI handler for testing Apache client certificate exposure and trust handling.
# Returns 200 for trusted clients and 401 for untrusted/missing certificates.
# Untrusted client certificates are captured to purgatory.
set -euo pipefail

# Source shared CGI helpers from the project data directory.
# shellcheck disable=SC1091
source "${MTLS_DATA_DIR}/scripts/cgi-trust.sh"

cert="${SSL_CLIENT_CERT:-}"
hostname="$(cgi_client_hostname)"
fp="$(cgi_client_fingerprint)"

# Decide trust status before emitting headers.
if [ -z "$cert" ]; then
    trusted=0
    status="401 Unauthorized"
elif is_trusted; then
    trusted=1
    status=""
else
    trusted=0
    status="401 Unauthorized"
fi

# Emit CGI headers.
if [ -n "$status" ]; then
    echo "Status: $status"
fi
echo "Content-Type: text/plain"
echo ""

# Emit body.
if [ -z "$cert" ]; then
    echo "No client certificate presented"
    exit 0
fi

echo "verify=${SSL_CLIENT_VERIFY:-NONE}"
echo "cn=${hostname:-unknown}"
echo "fp=${fp:-unknown}"

if [ "$trusted" -eq 1 ]; then
    echo "trusted"
else
    echo "Untrusted"
fi
