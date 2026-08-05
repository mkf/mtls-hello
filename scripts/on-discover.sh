#!/bin/bash
# Discovery-triggered callback: push all branches and tags from every bare
# repository under REPOS_ROOT to the discovered peer.
#
# Required env (per the 002 callback contract):
#   HOST_NAME         friendly name of this host (used for remote namespace)
#   PEER_NETLOC       host:port of the peer's mTLS server
#   PEER_CERT_FILE    certificate to pin the peer
#   OUR_CERT          our mTLS client certificate
#   OUR_KEY           our mTLS client key
#   REPOS_ROOT        directory containing bare repositories (*.git)
set -euo pipefail

# Clear vendored library path so curl uses the host's libssl, not the
# Guix-built vendored one (which may have older OPENSSL symbol versions).
unset LD_LIBRARY_PATH

: "${HOST_NAME:?}" "${PEER_NETLOC:?}" "${PEER_CERT_FILE:?}" "${OUR_CERT:?}" "${OUR_KEY:?}" "${REPOS_ROOT:?}"

mtls_curl() {
    local path="$1"
    ensure_peer_host
    local peer_ip="${PEER_NETLOC%%:*}" peer_port="${PEER_NETLOC##*:}"
    curl -sS --fail --max-time 5 \
        --cacert "$PEER_CERT_FILE" \
        --cert "$OUR_CERT" --key "$OUR_KEY" \
        --resolve "${PEER_HOST}:${peer_port}:${peer_ip}" \
        "https://${PEER_HOST}:${peer_port}${path}"
}

mtls_curl_post() {
    local path="$1"
    local file="$2"
    ensure_peer_host
    local peer_ip="${PEER_NETLOC%%:*}" peer_port="${PEER_NETLOC##*:}"
    curl -sS --fail --max-time 30 \
        --cacert "$PEER_CERT_FILE" \
        --cert "$OUR_CERT" --key "$OUR_KEY" \
        --data-binary "@$file" \
        --resolve "${PEER_HOST}:${peer_port}:${peer_ip}" \
        "https://${PEER_HOST}:${peer_port}${path}"
}

# Ensure PEER_HOST is set. Grab the cert (which sets it) if missing,
# or extract the CN from an existing cert file.
ensure_peer_host() {
    if [ ! -f "$PEER_CERT_FILE" ]; then
        grab_peer_cert
    elif [ -z "${PEER_HOST:-}" ]; then
        PEER_HOST=$(openssl x509 -in "$PEER_CERT_FILE" -noout -subject 2>/dev/null | \
            sed -n 's/.*CN\s*=\s*//p')
        [ -z "$PEER_HOST" ] && PEER_HOST="${PEER_NETLOC%%:*}"
    fi
}

# Grab the peer's server certificate via openssl s_client and save it to
# purgatory so the operator can later trust it. The peer's hostname is
# extracted from the certificate's CN.
grab_peer_cert() {
    local host="${PEER_NETLOC%%:*}" port="${PEER_NETLOC##*:}"
    local tmp="$(mktemp)"
    local purgatory="${PEER_CERT_FILE%/*}/../purgatory"
    mkdir -p "$purgatory"
    # Extract the peer's server certificate as described at wiki1.mikf.pl/openssl.html
    openssl s_client -connect "${host}:${port}" -showcerts </dev/null 2>/dev/null | \
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
        return 1
    fi
    rm -f "$tmp"
}

synced=0
skipped=0

for repo_dir in "$REPOS_ROOT"/*/; do
    [ -d "$repo_dir" ] || continue

    name="$(basename "$repo_dir" .git)"
    if [ -z "$name" ]; then
        skipped=$((skipped + 1))
        continue
    fi

    # Skip anything that is not a git repository (broken symlink, empty dir, etc.)
    if ! git -C "$repo_dir" rev-parse --git-dir >/dev/null 2>&1; then
        echo "[$name] not a git repository; skipping"
        skipped=$((skipped + 1))
        continue
    fi

    bundle="$(mktemp)"
    echo "[$name] bundling all refs"
    if ! git -C "$repo_dir" bundle create "$bundle" --all >/dev/null 2>&1; then
        echo "[$name] bundle creation failed; skipping"
        skipped=$((skipped + 1))
        rm -f "$bundle"
        continue
    fi

    echo "[$name] pushing bundle to $PEER_NETLOC"
    push_err=$(mtls_curl_post "/bundle?repo=${name}&host=${HOST_NAME}" "$bundle" 2>&1) && push_ok=0 || push_ok=$?
    if [ "$push_ok" -eq 0 ]; then
        synced=$((synced + 1))
        echo "[$name] pushed"
    else
        echo "[$name] push failed: $push_err"
        if echo "$push_err" | grep -q "does not exist"; then
            echo "[$name] The peer's certificate is not trusted yet."
            purg="${PEER_CERT_FILE%/*}/../purgatory"
            purg="$(cd "$purg" 2>/dev/null && pwd)" || purg=""
            if [ -n "$purg" ] && [ -n "$(ls -A "$purg" 2>/dev/null)" ]; then
                echo "[$name] Found captured certs in $purg:"
                ls "$purg"/*.crt 2>/dev/null | while read f; do
                    local cn=$(openssl x509 -in "$f" -noout -subject 2>/dev/null | sed -n 's/.*CN\s*=\s*//p')
                    echo "[$name]   bash ${PEER_CERT_FILE%/*}/scripts/trust-host.sh $cn $f"
                done
            else
                echo "[$name] Warning: no captured certs in $purg"
                echo "[$name] The peer has not connected yet, or purgatory is empty."
            fi
            echo "[$name] Trust the peer with:"
            echo "[$name]   bash ${PEER_CERT_FILE%/*}/scripts/trust-host.sh $HOST_NAME <cert-file>"
        fi
        skipped=$((skipped + 1))
    fi
    rm -f "$bundle"
done

echo "synced=$synced skipped=$skipped"
