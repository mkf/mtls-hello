#!/bin/bash
# Promote a certificate to the trust store under a hostname.
# Usage: scripts/trust-host.sh <hostname> <cert-file> [trust-dir]
set -euo pipefail

# The script may be invoked from inside the Guix dev shell, where
# LD_LIBRARY_PATH points to the Guix profile's libc. Host binaries like
# /bin/bash and coreutils would then load the wrong libc, so we clear it.
unset LD_LIBRARY_PATH

hostname="${1:?hostname required}"
cert_file="${2:?certificate file required}"
# Default to ../hosts relative to this script (scripts/ and hosts/ are siblings
# under the data-dir). The operator can override with the third argument.
trust_dir="${3:-$(dirname "$0")/../hosts}"

if [ ! -f "$cert_file" ]; then
    echo "error: certificate file not found: $cert_file" >&2
    exit 1
fi

cn="$(openssl x509 -noout -subject -in "$cert_file" | sed -n 's/.*CN\s*=\s*\([^,]*\).*/\1/p' | head -1)"
if [ "$cn" != "$hostname" ]; then
    echo "error: certificate CN '$cn' does not match hostname '$hostname'" >&2
    exit 1
fi

mkdir -p "$trust_dir"
cp "$cert_file" "$trust_dir/$hostname.crt"
echo "trusted $hostname under $trust_dir/$hostname.crt"
