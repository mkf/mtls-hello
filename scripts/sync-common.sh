# Shared curl and cert-handling functions for mTLS git sync.
# Sourced by on-discover.sh and sync-test.sh.
# Requires: set -euo pipefail, unset LD_LIBRARY_PATH (caller's responsibility).
# Expects these env vars to be set before calling the curl functions:
#   PEER_NETLOC  PEER_CERT_FILE  PEER_HOST  OUR_CERT  OUR_KEY

mtls_curl() {
    local path="$1"
    ensure_peer_host
    local peer_ip="${PEER_NETLOC%%:*}" peer_port="${PEER_NETLOC##*:}"
    curl -sS --max-time 5 \
        --cacert "$PEER_CERT_FILE" \
        --cert "$OUR_CERT" --key "$OUR_KEY" \
        --resolve "${PEER_HOST}:${peer_port}:${peer_ip}" \
        -w '\nHTTP %{http_code}' \
        "https://${PEER_HOST}:${peer_port}${path}" 2>&1
}

mtls_curl_post() {
    local path="$1"
    local file="$2"
    ensure_peer_host
    local peer_ip="${PEER_NETLOC%%:*}" peer_port="${PEER_NETLOC##*:}"
    curl -sS --max-time 30 \
        --cacert "$PEER_CERT_FILE" \
        --cert "$OUR_CERT" --key "$OUR_KEY" \
        --data-binary "@$file" \
        --resolve "${PEER_HOST}:${peer_port}:${peer_ip}" \
        -w '\nHTTP %{http_code}' \
        "https://${PEER_HOST}:${peer_port}${path}" 2>&1
}

ensure_peer_host() {
    if [ ! -f "$PEER_CERT_FILE" ]; then
        grab_peer_cert || { echo "[discovery] cannot connect to peer (cert extraction failed)" >&2; exit 1; }
    elif [ -z "${PEER_HOST:-}" ]; then
        PEER_HOST=$(openssl x509 -in "$PEER_CERT_FILE" -noout -subject 2>/dev/null | \
            sed -n 's/.*CN\s*=\s*//p')
        [ -z "$PEER_HOST" ] && PEER_HOST="${PEER_NETLOC%%:*}"
    fi
}

grab_peer_cert() {
    local host="${PEER_NETLOC%%:*}" port="${PEER_NETLOC##*:}"
    local tmp="$(mktemp)"
    local purgatory="${PEER_CERT_FILE%/*}/../purgatory"
    mkdir -p "$purgatory"
    timeout 10 openssl s_client -connect "${host}:${port}" -showcerts </dev/null 2>/dev/null | \
        sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' > "$tmp"
    if [ -s "$tmp" ]; then
        local peer_host
        peer_host=$(openssl x509 -in "$tmp" -noout -subject 2>/dev/null | sed -n 's/.*CN\s*=\s*//p')
        [ -z "$peer_host" ] && peer_host="$host"
        local dst="$purgatory/${peer_host}.$(date +%s).crt"
        cp "$tmp" "$dst"
        echo "[discovery] captured peer certificate for $peer_host to $dst"
        PEER_CERT_FILE="$dst"
        PEER_HOST="$peer_host"
    else
        echo "[discovery] failed to extract peer certificate from ${host}:${port}" >&2
        echo "[discovery] (peer may be unreachable or not running yet)" >&2
        return 1
    fi
    rm -f "$tmp"
}
