#!/bin/bash
# Shared CGI utilities for Apache handlers.
# Sourced by handler scripts; not executed directly.

# Parse QUERY_STRING into QUERY_<KEY> variables (uppercase, matching the
# convention used by the previous vibe.d server).
# Example: QUERY_STRING="repo=laptops&host=peer1" sets QUERY_REPO and QUERY_HOST.
cgi_parse_query() {
    local qs="${QUERY_STRING:-}"
    local IFS='&'
    local pair key val upper
    for pair in $qs; do
        key="${pair%%=*}"
        val="${pair#*=}"
        # URL-decode: replace + with space and %XX with bytes.
        val="${val//+/ }"
        val=$(printf '%b' "${val//%/\\x}")
        # Uppercase the key and prefix with QUERY_.
        upper=$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]' | tr -c '[:alnum:]' '_')
        [ -n "$upper" ] && eval "QUERY_${upper}=\$val"
    done
}

# Emit a CGI response header and blank line.
# Usage: cgi_header [content-type]
cgi_header() {
    echo "Content-Type: ${1:-text/plain}"
    echo ""
}

# Emit a CGI error response with a status code.
# Usage: cgi_error <status_code> <message>
cgi_error() {
    echo "Status: $1"
    echo "Content-Type: text/plain"
    echo ""
    echo "$2"
    exit 0
}
