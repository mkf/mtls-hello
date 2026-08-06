#!/bin/bash
# Reusable CGI trust-evaluation helpers for Apache handlers.
# Sourced by handler scripts; not executed directly.

# Extract the hostname (CN) from the client certificate in SSL_CLIENT_CERT.
# Prints the CN or "unknown" if unavailable.
cgi_client_hostname() {
    local cert
    cert="${SSL_CLIENT_CERT:-}"
    if [ -z "$cert" ]; then
        echo "unknown"
        return 0
    fi
    echo "$cert" | openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null |
        sed -n 's/^subject=.*CN=\([^,+\/]*\).*/\1/p'
}

# Compute the SHA-256 fingerprint of the client certificate in SSL_CLIENT_CERT.
# Prints the lowercase hex fingerprint or nothing on failure.
cgi_client_fingerprint() {
    local cert
    cert="${SSL_CLIENT_CERT:-}"
    if [ -z "$cert" ]; then
        return 0
    fi
    echo "$cert" | openssl x509 -noout -fingerprint -sha256 2>/dev/null |
        cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]'
}

# Check if the client certificate is trusted.
# Returns 0 if <trust_dir>/<hostname>.crt exists and its fingerprint matches.
# Returns 1 otherwise.
# Usage: is_trusted [trust_dir]
is_trusted() {
    local trust_dir="${1:-${MTLS_TRUST_DIR:-}}"
    local cert hostname fp trust_file trust_fp

    cert="${SSL_CLIENT_CERT:-}"
    if [ -z "$cert" ]; then
        return 1
    fi

    hostname="$(cgi_client_hostname)"
    if [ -z "$hostname" ] || [ "$hostname" = "unknown" ]; then
        return 1
    fi

    fp="$(cgi_client_fingerprint)"
    if [ -z "$fp" ]; then
        return 1
    fi

    trust_file="$trust_dir/$hostname.crt"
    if [ ! -f "$trust_file" ]; then
        return 1
    fi

    trust_fp=$(openssl x509 -in "$trust_file" -noout -fingerprint -sha256 2>/dev/null |
        cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')

    if [ "$fp" = "$trust_fp" ]; then
        return 0
    fi
    return 1
}
