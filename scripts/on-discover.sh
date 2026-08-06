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

: "${HOST_NAME:?}" "${PEER_NETLOC:?}" "${OUR_CERT:?}" "${OUR_KEY:?}" "${REPOS_ROOT:?}"

if [ -z "${PEER_CERT_FILE:-}" ] || [ ! -f "$PEER_CERT_FILE" ]; then
    echo "[discovery] PEER_CERT_FILE is not set or missing; cannot connect to peer" >&2
    exit 0
fi

# FFDC (First Failure Data Capture): on first push failure for a given
# repo+host pair, capture full details to a log file. Subsequent failures
# just reference the existing log instead of spamming the journal.
FFDC_DIR="$(dirname "$0")/../ffdc"

# Source shared curl/cert functions.
# shellcheck source=scripts/sync-common.sh
. "$(dirname "$0")/sync-common.sh"

# Source shared safe-deletion helpers (no rm -rf / rm -f anywhere).
# shellcheck source=scripts/cleanup-common.sh
. "$(dirname "$0")/cleanup-common.sh"

# Source shared sync-state helpers.
# shellcheck source=scripts/sync-state.sh
. "$(dirname "$0")/sync-state.sh"

# Resolve the peer hostname before the repo loop so we can use it for sync-state keys.
ensure_peer_host 2>/dev/null || true


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

    # Check if we already sent this peer the current refs for this repo.
    current_hash=$(compute_refs_hash "$repo_dir")
    cached_hash=$(get_synced_hash "$PEER_HOST" "$name")
    if [ -n "$current_hash" ] && [ "$current_hash" = "$cached_hash" ]; then
        echo "[$name] refs hash unchanged for $PEER_HOST; skipping"
        continue
    fi

    # Check if peer already has our HEAD to avoid unnecessary bundling.
    our_head=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || echo "")
    peer_refs=$(mtls_curl "/head?repo=${name}" 2>/dev/null || true)
    if [ -n "$our_head" ] && echo "$peer_refs" | grep -q "HEAD $our_head"; then
        echo "[$name] peer HEAD matches; skipping"
        continue
    fi

    # Query spool coverage to skip already-spooled ranges.
    spool_cov=$(query_spool_coverage "$name")

    # Push each branch as a separate bundle to stay under server size limits.
    # Large combined bundles (--branches --tags) can exceed maxRequestSize.
    branches=()
    while IFS= read -r ref; do branches+=("$ref"); done < <(git -C "$repo_dir" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null || true)

    repo_failed=0

    for branch in "${branches[@]}"; do
        to_sha=$(git -C "$repo_dir" rev-parse "$branch" 2>/dev/null || echo "")
        # Skip if this range is already spooled at the peer.
        if [ -n "$to_sha" ] && echo "$spool_cov" | grep -q "0000000000000000000000000000000000000000 $to_sha"; then
            echo "[$name] $branch already spooled at peer; skipping"
            continue
        fi

        bbundle="$(mktemp)"
        echo "[$name] bundling $branch"
        bbundle_output=$(git -C "$repo_dir" bundle create "$bbundle" "$branch" --tags 2>&1) || true
        if [ ! -s "$bbundle" ]; then
            echo "[$name] bundle creation failed for $branch: $bbundle_output"
            remove_file_safe "$bbundle"
            continue
        fi
        bsize=$(wc -c < "$bbundle")
        echo "[$name] bundle ($branch): $bsize bytes"

        echo "[$name] pushing $branch to $PEER_NETLOC"
        push_out=$(mtls_curl_post "/bundle?repo=${name}&host=${HOST_NAME}&from=0000000000000000000000000000000000000000&to=${to_sha}" "$bbundle" 2>&1) || true
        remove_file_safe "$bbundle"
        if echo "$push_out" | grep -q "HTTP 200"; then
            synced=$((synced + 1))
            # Success clears FFDC for this repo+host pair.
            remove_file_safe "$FFDC_DIR/${name}-${HOST_NAME}"
            continue
        fi
        repo_failed=1
        ffdc="$FFDC_DIR/${name}-${HOST_NAME}"
        if [ -f "$ffdc" ]; then
            echo "[$name] push to $HOST_NAME still failing — see $ffdc"
        else
            mkdir -p "$FFDC_DIR"
            {
                echo "timestamp: $(date -Iseconds)"
                echo "peer: $PEER_NETLOC"
                echo "host: $HOST_NAME"
                echo "repo: $name"
                echo "---server response---"
                echo "$push_out"
            } > "$ffdc"
            echo "[$name] push failed [$HOST_NAME] — details captured to $ffdc"
        fi
        if echo "$push_out" | grep -q "does not exist"; then
            echo "[$name] The peer's certificate is not trusted yet."
            purg="${PEER_CERT_FILE%/*}/../purgatory"
            purg="$(cd "$purg" 2>/dev/null && pwd)" || purg=""
            if [ -n "$purg" ] && [ -n "$(find "$purg" -maxdepth 1 -type f -name '*.crt' -print -quit 2>/dev/null)" ]; then
                echo "[$name] Found captured certs in $purg:"
                for f in "$purg"/*.crt; do
                    [ -e "$f" ] || continue
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
    done

    if [ "$repo_failed" -eq 0 ] && [ -n "$current_hash" ]; then
        set_synced_hash "$PEER_HOST" "$name" "$current_hash"
    fi
done
echo "synced=$synced skipped=$skipped"
