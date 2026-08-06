#!/bin/bash
# Piped-log certificate-capture script for Apache.
#
# Apache spawns this once and pipes one log line per request to its stdin.
# Each line is tab-separated:
#   <SSL_CLIENT_S_DN>\t<SSL_CLIENT_VERIFY>\t<SSL_CLIENT_CERT-escaped>\tCERTEND
# Apache escapes the PEM's newlines as the literal two characters "\n", so each
# request is exactly one line.
#
# For every presented certificate this script:
#   - unescapes the PEM,
#   - derives the hostname (CN) and SHA-256 fingerprint,
#   - skips it if it is already trusted (matching the cgi-trust.sh rules),
#   - otherwise writes <purgatory-dir>/<hostname>.<fingerprint>.crt (dedup by name).
#
# Usage: log-capture.sh <trust-dir> <purgatory-dir>
# Reads request lines from stdin until EOF. Never exits on a single bad line.
set -uo pipefail

TRUST_DIR="${1:-}"
PURGATORY_DIR="${2:-}"

if [ -z "$TRUST_DIR" ] || [ -z "$PURGATORY_DIR" ]; then
    echo "log-capture: usage: $0 <trust-dir> <purgatory-dir>" >&2
    exit 2
fi

# Derive hostname (CN) from a PEM on stdin, matching cgi-trust.sh exactly.
hostname_of_pem() {
    openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null |
        sed -n 's/^subject=.*CN=\([^,+\/]*\).*/\1/p'
}

# SHA-256 fingerprint (lowercase hex) of a PEM on stdin.
fingerprint_of_pem() {
    openssl x509 -noout -fingerprint -sha256 2>/dev/null |
        cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]'
}

# Process one raw log line. Returns 0 on success or "skipped", non-zero on error.
process_line() {
    local _subject _verify cert_escaped _marker
    IFS=$'\t' read -r _subject _verify cert_escaped _marker <<<"$1"

    # No certificate presented (SSL_CLIENT_CERT empty) -> nothing to capture.
    [ -n "$cert_escaped" ] || return 0

    # Unescape literal "\n" sequences back into newlines to recover the PEM.
    local cert_pem="${cert_escaped//\\n/$'\n'}"

    local hostname fp trust_file trust_fp
    hostname="$(printf '%s' "$cert_pem" | hostname_of_pem)"
    [ -n "$hostname" ] || hostname="unknown"
    fp="$(printf '%s' "$cert_pem" | fingerprint_of_pem)"
    [ -n "$fp" ] || return 1

    # Already trusted? Then do not pollute purgatory.
    trust_file="$TRUST_DIR/$hostname.crt"
    if [ -f "$trust_file" ]; then
        trust_fp="$(openssl x509 -in "$trust_file" -noout -fingerprint -sha256 2>/dev/null |
            cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')"
        if [ "$fp" = "$trust_fp" ]; then
            return 0
        fi
    fi

    # Write (deduplicated by filename).
    mkdir -p "$PURGATORY_DIR"
    printf '%s\n' "$cert_pem" >"$PURGATORY_DIR/$hostname.$fp.crt"
}

while IFS= read -r line || [ -n "$line" ]; do
    if ! process_line "$line"; then
        echo "log-capture: skipping malformed line" >&2
    fi
done
