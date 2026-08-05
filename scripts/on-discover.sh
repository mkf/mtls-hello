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

# Source shared curl/cert functions.
. "$(dirname "$0")/sync-common.sh"


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

    # Check if peer already has our HEAD to avoid unnecessary bundling.
    our_head=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || echo "")
    peer_refs=$(mtls_curl "/head?repo=${name}" 2>/dev/null || true)
    if [ -n "$our_head" ] && echo "$peer_refs" | grep -q "HEAD $our_head"; then
        echo "[$name] peer HEAD matches; skipping"
        continue
    fi

    bundle="$(mktemp)"
    echo "[$name] bundling refs/heads + refs/tags"
    if ! git -C "$repo_dir" bundle create "$bundle" --branches --tags >/dev/null 2>&1; then
        echo "[$name] bundle creation failed; skipping"
        skipped=$((skipped + 1))
        rm -f "$bundle"
        continue
    fi

    echo "[$name] pushing bundle to $PEER_NETLOC"
    push_out=$(mtls_curl_post "/bundle?repo=${name}&host=${HOST_NAME}" "$bundle" 2>&1)
    if echo "$push_out" | grep -q "HTTP 200"; then
        synced=$((synced + 1))
        echo "[$name] pushed"
    else
        echo "[$name] push failed: $(echo "$push_out" | tail -1)"
        if echo "$push_out" | grep -q "does not exist"; then
            echo "[$name] The peer's certificate is not trusted yet."
            purg="${PEER_CERT_FILE%/*}/../purgatory"
            purg="$(cd "$purg" 2>/dev/null && pwd)" || purg=""
            if [ -n "$purg" ] && [ -n "$(ls -A "$purg" 2>/dev/null)" ]; then
                echo "[$name] Found captured certs in $purg:"
                ls "$purg"/*.crt 2>/dev/null | while read f; do
                    cn=$(openssl x509 -in "$f" -noout -subject 2>/dev/null | sed -n 's/.*CN\s*=\s*//p')
                    printf '[%s]   bash %s/scripts/trust-host.sh %s %s\n' "$name" "${PEER_CERT_FILE%/*}" "$cn" "$f"
                done
            else
                printf '[%s] Warning: no captured certs in %s\n' "$name" "$purg"
                printf '[%s] The peer has not connected yet, or purgatory is empty.\n' "$name"
            fi
            printf '[%s] Trust the peer with:\n' "$name"
            printf '[%s]   bash %s/scripts/trust-host.sh %s <cert-file>\n' "$name" "${PEER_CERT_FILE%/*}" "$HOST_NAME"
        fi
        skipped=$((skipped + 1))
    fi
    rm -f "$bundle"
done

echo "synced=$synced skipped=$skipped"
