#!/bin/bash
# Shared helpers for cli/mtls-*.sh drop-box wrappers.
# Sourced by each wrapper; not executed directly.
#
# Provides:
#   _mtls_parse_args "$@"   — parses --server, --cert, --key, --cacert
#   MTLS_SERVER             — base URL (e.g. https://host:8443)
#   MTLS_CERT               — client cert file
#   MTLS_KEY                — client key file
#   MTLS_CACERT             — server cert for --cacert
#   _mtls_cn                — the CN derived from MTLS_CERT
#   _mtls_url <name>        — prints https://server/drop/<cn>/<name>
#   _mtls_curl_status       — last HTTP status code from curl

# Parse common arguments. Call once at wrapper entry after method-specific
# args have been extracted.
_mtls_parse_args() {
    MTLS_SERVER="${MTLS_SERVER:-}"
    MTLS_CERT="${MTLS_CERT:-}"
    MTLS_KEY="${MTLS_KEY:-}"
    MTLS_CACERT="${MTLS_CACERT:-}"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --server)   MTLS_SERVER="$2"; shift 2 ;;
            --cert)     MTLS_CERT="$2"; shift 2 ;;
            --key)      MTLS_KEY="$2"; shift 2 ;;
            --cacert)   MTLS_CACERT="$2"; shift 2 ;;
            --cn)       _mtls_cn_override="$2"; shift 2 ;;
            *)          break ;;
        esac
    done
    # Fall back to env vars.
    MTLS_SERVER="${MTLS_SERVER:-${MTLS_HELLO_URL:-}}"
    MTLS_CERT="${MTLS_CERT:-${MTLS_CLIENT_CERT:-}}"
    MTLS_KEY="${MTLS_KEY:-${MTLS_CLIENT_KEY:-}}"
    MTLS_CACERT="${MTLS_CACERT:-${MTLS_CACERT:-}}"
    # Validate.
    if [ -z "$MTLS_SERVER" ]; then
        echo "error: --server or MTLS_SERVER env is required" >&2
        exit 2
    fi
    if [ -z "$MTLS_CERT" ] || [ -z "$MTLS_KEY" ]; then
        echo "error: --cert and --key are required" >&2
        exit 2
    fi
    if [ -z "$MTLS_CACERT" ]; then
        echo "error: --cacert is required (self-signed server cert)" >&2
        exit 2
    fi
    # Strip trailing slash from server URL.
    MTLS_SERVER="${MTLS_SERVER%/}"
    # Derive CN unless overridden.
    if [ -z "${_mtls_cn_override:-}" ]; then
        _mtls_cn_override="$(openssl x509 -in "$MTLS_CERT" -noout \
            -subject -nameopt RFC2253 2>/dev/null |
            sed -n 's/^subject=.*CN=\([^,+\/]*\).*/\1/p')" || true
    fi
    _mtls_cn="${_mtls_cn_override:-}"
    if [ -z "$_mtls_cn" ]; then
        echo "error: could not extract CN from $MTLS_CERT" >&2
        exit 2
    fi
    # Sanitize CN to [A-Za-z0-9._-]+.
    local sanitized
    sanitized="$(printf '%s' "$_mtls_cn" | tr -cd 'A-Za-z0-9._-')"
    if [ "$sanitized" != "$_mtls_cn" ]; then
        echo "warning: CN '$_mtls_cn' sanitized to '$sanitized'" >&2
    fi
    _mtls_cn="$sanitized"
}

# Print the full URL for a given remote name.
_mtls_url() {
    local name="$1"
    printf '%s/drop/%s/%s\n' "$MTLS_SERVER" "$_mtls_cn" "${name#/}"
}

# Run curl and capture HTTP status. Sets _mtls_curl_status.
# Usage: _mtls_curl <method> <url> [--header "K: V"]... [--data-binary @file]
_mtls_curl() {
    local method="$1"; shift
    local url="$1"; shift
    _mtls_hdr_file="$(mktemp)"
    _mtls_body_file="$(mktemp)"
    _mtls_curl_status="$(curl -sS --max-time 300 \
        --cert "$MTLS_CERT" --key "$MTLS_KEY" --cacert "$MTLS_CACERT" \
        -X "$method" \
        -D "$_mtls_hdr_file" \
        -o "$_mtls_body_file" \
        -w '%{http_code}' \
        "$@" \
        "$url" 2>/dev/null)" || {
        # curl itself failed (TLS, network, etc.).
        echo "error: curl failed for $method $url" >&2
        rm -- "$_mtls_hdr_file" "$_mtls_body_file" 2>/dev/null || true
        exit 1
    }
}

# Map HTTP status to exit code per the contract.
_mtls_exit_for_status() {
    local s="$1"
    case "$s" in
        2[0-9][0-9]|304) exit 0 ;;
        401)             exit 3 ;;
        403)             exit 5 ;;
        5[0-9][0-9])     exit 4 ;;
        *)               exit 1 ;;
    esac
}

# Cleanup temp files. Call at end of wrapper or trap.
_mtls_cleanup() {
    [ -n "${_mtls_hdr_file:-}" ] && rm -- "$_mtls_hdr_file" 2>/dev/null || true
    [ -n "${_mtls_body_file:-}" ] && rm -- "$_mtls_body_file" 2>/dev/null || true
}
