#!/usr/bin/env bash
# scripts/on-discovery.d/50-bundle-push.sh — replicate the legacy
# `scripts/on-discover.sh` git-bundle-sync-on-discovery loop. Trust-add
# (`10-trust-add.sh`) and NNCP-neighbour-registration (`20-...`) are
# separate scripts now; we only do the bundle push.
#
# Required env (legacy + 025-aware):
#   HOST_NAME, PEER_NETLOC, PEER_CERT_FILE, OUR_CERT, OUR_KEY, REPOS_ROOT
#
# This script preserves feature 016/006 behaviour: on discovery, push
# per-repo bundles over https://<peer>/bundle?repo=…&host=…&from=…&to=…, with
# FFDC (First Failure Data Capture) per (repo, host) pair and idempotency
# driven by `scripts/sync-state.sh` (compute_refs_hash / get_synced_hash).
#
# Per safety rule (G1): never `rm -rf` / `find -delete`. The legacy
# on-discover.sh used `remove_file_safe` (feature 022) — we keep it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DATA_DIR="${DATA_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
REPOS_ROOT="${REPOS_ROOT:-$DATA_DIR/repos}"

# Clear vendored library path so curl uses the host's libssl, not the
# Guix/Nix-built vendored one (which may have older OPENSSL symbol versions).
unset LD_LIBRARY_PATH

: "${HOST_NAME:?}" "${PEER_NETLOC:?}" "${OUR_CERT:?}" "${OUR_KEY:?}" "${REPOS_ROOT:?}"

if [ -z "${PEER_CERT_FILE:-}" ] || [ ! -f "$PEER_CERT_FILE" ]; then
    echo "[50-bundle-push] PEER_CERT_FILE is not set or missing; cannot connect to peer" >&2
    exit 0
fi

# FFDC: on first push failure for a (repo, host) pair, capture full details.
FFDC_DIR="$DATA_DIR/ffdc"

# Source shared helpers (all under scripts/, or under <data-dir>/scripts/ for installs).
. "$DATA_DIR/scripts/sync-common.sh"  2>/dev/null || . "$PROJECT_ROOT/scripts/sync-common.sh"
. "$DATA_DIR/scripts/cleanup-common.sh" 2>/dev/null || . "$PROJECT_ROOT/scripts/cleanup-common.sh"
. "$DATA_DIR/scripts/sync-state.sh" 2>/dev/null || . "$PROJECT_ROOT/scripts/sync-state.sh"

# Resolve the peer hostname before the repo loop so we can use it for sync-state keys.
ensure_peer_host 2>/dev/null || true

synced=0
skipped=0

# Pure per-repo loop; aligned with the legacy on-discover.sh semantics —
# bundled per-branch to stay under Apache's LimitRequestBody ceiling.
for repo_dir in "$REPOS_ROOT"/*/; do
    [ -d "$repo_dir" ] || continue

    name="$(basename "$repo_dir" .git)"
    if [ -z "$name" ]; then
        skipped=$((skipped + 1))
        continue
    fi

    # Skip anything that is not a git repository.
    if ! git -C "$repo_dir" rev-parse --git-dir >/dev/null 2>&1; then
        echo "[50-bundle-push] $name not a git repository; skipping"
        skipped=$((skipped + 1))
        continue
    fi

    current_hash="$(compute_refs_hash "$repo_dir")"
    cached_hash="$(get_synced_hash "$PEER_HOST" "$name")"
    if [ -n "$current_hash" ] && [ "$current_hash" = "$cached_hash" ]; then
        echo "[50-bundle-push] $name refs hash unchanged for $PEER_HOST; skipping"
        continue
    fi

    our_head="$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || echo "")"
    peer_refs="$(mtls_curl "/head?repo=${name}" 2>/dev/null || true)"
    if [ -n "$our_head" ] && echo "$peer_refs" | grep -q "HEAD $our_head"; then
        echo "[50-bundle-push] $name peer HEAD matches; skipping"
        continue
    fi

    spool_cov="$(query_spool_coverage "$name")"

    branches=()
    while IFS= read -r ref; do branches+=("$ref"); done < <(git -C "$repo_dir" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null || true)

    repo_failed=0

    for branch in "${branches[@]}"; do
        to_sha="$(git -C "$repo_dir" rev-parse "$branch" 2>/dev/null || echo "")"
        if [ -n "$to_sha" ] && echo "$spool_cov" | grep -q "0000000000000000000000000000000000000000 $to_sha"; then
            echo "[50-bundle-push] $name $branch already spooled at peer; skipping"
            continue
        fi

        bbundle="$(mktemp)"
        echo "[50-bundle-push] $name bundling $branch"
        bbundle_output="$(git -C "$repo_dir" bundle create "$bbundle" "$branch" --tags 2>&1)" || true
        if [ ! -s "$bbundle" ]; then
            echo "[50-bundle-push] $name bundle creation failed for $branch: $bbundle_output"
            remove_file_safe "$bbundle"
            continue
        fi
        bsize="$(wc -c < "$bbundle")"
        echo "[50-bundle-push] $name bundle ($branch): $bsize bytes"

        echo "[50-bundle-push] $name pushing $branch to $PEER_NETLOC"
        push_out="$(mtls_curl_post "/bundle?repo=${name}&host=${HOST_NAME}&from=0000000000000000000000000000000000000000&to=${to_sha}" "$bbundle" 2>&1)" || true
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
            echo "[50-bundle-push] $name push to $HOST_NAME still failing — see $ffdc"
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
            echo "[50-bundle-push] $name push failed [$HOST_NAME] — details captured to $ffdc"
        fi
    done

    if [ "$repo_failed" -eq 0 ] && [ -n "$current_hash" ]; then
        set_synced_hash "$PEER_HOST" "$name" "$current_hash"
    fi
done

echo "[50-bundle-push] synced=$synced skipped=$skipped"
exit 0
