#!/bin/bash
# sync-lib.sh — Unified curl + sync-state library for mTLS git sync.
#
# Merged from sync-common.sh + sync-state.sh (feature 026). All consumers
# source this single file instead of two. Not executed directly.
#
# Curl helpers (from sync-common.sh):
#   mtls_curl, mtls_curl_post, ensure_peer_host, apply_bundle_to_repo, query_spool_coverage
#
# Sync-state helpers (from sync-state.sh):
#   sync_state_base, sync_state_dir, sync_state_file_for_peer,
#   compute_refs_hash, get_synced_hash, set_synced_hash, clear_synced_hash
#
# Requires: set -euo pipefail, unset LD_LIBRARY_PATH (caller's responsibility).
# Expects these env vars before calling the curl functions:
#   PEER_NETLOC  PEER_CERT_FILE  PEER_HOST  OUR_CERT  OUR_KEY
# Expects DATA_DIR before calling the sync-state functions.

# ─── Curl Helpers ────────────────────────────────────────────────────────────

mtls_curl() {
    local path="$1"
    ensure_peer_host 2>/dev/null || true
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
    ensure_peer_host 2>/dev/null || true
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
        echo "[discovery] PEER_CERT_FILE is not set or missing; cannot connect to peer" >&2
        return 1
    fi
    if [ -z "${PEER_HOST:-}" ]; then
        # shellcheck disable=SC1091  # cgi-lib.sh sourced by caller if available
        if command -v extract_cn >/dev/null 2>&1; then
            PEER_HOST="$(extract_cn "$PEER_CERT_FILE")"
        else
            PEER_HOST=$(openssl x509 -in "$PEER_CERT_FILE" -noout -subject 2>/dev/null | \
                sed -n 's/.*CN\s*=\s*//p')
        fi
        [ -z "$PEER_HOST" ] && PEER_HOST="${PEER_NETLOC%%:*}"
    fi
}

# Apply a git bundle to a bare repository.
# Fetches into per-peer namespace, promotes branches, fetches tags, fixes HEAD.
# Args: <repo_dir> <bundle_file> <peer_host>
apply_bundle_to_repo() {
    repo_dir="$1" bundle_file="$2" peer_host="$3"
    remote_ns="refs/remotes/${peer_host}"

    [ -d "$repo_dir" ] || git init --bare "$repo_dir"

    git -C "$repo_dir" fetch "$bundle_file" "+refs/heads/*:${remote_ns}/*" 2>&1 || return 1

    while IFS= read -r ref; do
        branch="${ref#"${remote_ns}"/}"
        incoming="$(git -C "$repo_dir" rev-parse "$ref" 2>/dev/null)" || continue
        if git -C "$repo_dir" show-ref --verify --quiet "refs/heads/${branch}" 2>/dev/null; then
            local_sha="$(git -C "$repo_dir" rev-parse "refs/heads/${branch}")"
            if git -C "$repo_dir" merge-base --is-ancestor "$local_sha" "$incoming" 2>/dev/null; then
                git -C "$repo_dir" update-ref "refs/heads/${branch}" "$incoming"
            fi
        else
            git -C "$repo_dir" update-ref "refs/heads/${branch}" "$incoming"
        fi
    done < <(git -C "$repo_dir" for-each-ref --format='%(refname)' "${remote_ns}/" 2>/dev/null || true)

    git -C "$repo_dir" fetch "$bundle_file" "refs/tags/*:refs/tags/*" 2>&1 || true

    first_branch=$(git -C "$repo_dir" for-each-ref --format='%(refname)' refs/heads 2>/dev/null | head -1)
    if [ -n "$first_branch" ] && ! git -C "$repo_dir" rev-parse --verify HEAD >/dev/null 2>&1; then
        git -C "$repo_dir" symbolic-ref HEAD "$first_branch"
    fi
}

# Query the peer's spool coverage for a repo.
query_spool_coverage() {
    local repo="$1"
    mtls_curl "/spool?repo=${repo}" 2>/dev/null | grep -E '^[0-9a-f]+ [0-9a-f]+$' || true
}

# ─── Sync-State Helpers ──────────────────────────────────────────────────────

# Per-peer refs-hash cache under /dev/shm so we can skip redundant bundling.
# Layout: /dev/shm/mtls-hello-sync/<data-dir-hash>/sync-state/<peer>.txt
# Each file: lines of "<repo_name> <64-hex-sha>" — one entry per repo synced.

# Print the base shared-memory directory for this instance.
sync_state_base() {
    if [ -z "${DATA_DIR:-}" ] || [ ! -d "/dev/shm" ]; then
        return 0
    fi
    local abs_dir
    abs_dir=$(cd "$DATA_DIR" 2>/dev/null && pwd) || abs_dir="$DATA_DIR"
    local hash
    hash=$(printf '%s' "$abs_dir" | sha256sum | awk '{print $1}' | head -c16)
    printf '/dev/shm/mtls-hello-sync/%s' "$hash"
}

sync_state_dir() {
    local base
    base=$(sync_state_base) || true
    [ -n "${base:-}" ] || return 0
    printf '%s/sync-state\n' "$base"
}

sync_state_file_for_peer() {
    local hostname="${1:-}"
    local dir
    dir=$(sync_state_dir) || true
    [ -n "${dir:-}" ] || return 0
    printf '%s/%s.txt\n' "$dir" "$hostname"
}

# Compute a deterministic SHA-256 hash of refs/heads and refs/tags.
# Args: <repo_dir>. Output: 64-character hex digest, or empty on failure.
compute_refs_hash() {
    local repo_dir="${1:-}"
    if [ -z "$repo_dir" ] || [ ! -d "$repo_dir" ]; then
        return 0
    fi
    if ! git -C "$repo_dir" rev-parse --git-dir >/dev/null 2>&1; then
        return 0
    fi
    git -C "$repo_dir" for-each-ref --format='%(objectname) %(refname)' refs/heads refs/tags 2>/dev/null \
        | sort \
        | sha256sum \
        | awk '{print $1}' \
        | head -c64
}

# Print the recorded refs hash for a peer/repo, or empty string.
# Args: <hostname> <repo_name>
get_synced_hash() {
    local hostname="${1:-}" repo_name="${2:-}"
    local file
    file=$(sync_state_file_for_peer "$hostname") || true
    [ -n "${file:-}" ] || return 0
    [ -f "$file" ] || return 0
    awk -v repo="$repo_name" '$1 == repo { print $2; exit }' "$file"
}

# Record or update the refs hash for a peer/repo in shared memory.
# Args: <hostname> <repo_name> <refs_hash>
set_synced_hash() {
    local hostname="${1:-}" repo_name="${2:-}" refs_hash="${3:-}"
    if [ -z "$hostname" ] || [ -z "$repo_name" ] || [ -z "$refs_hash" ]; then
        return 0
    fi
    if [ -z "${DATA_DIR:-}" ] || [ ! -d "/dev/shm" ]; then
        return 0
    fi
    local dir
    dir=$(sync_state_dir) || return 0
    [ -n "${dir:-}" ] || return 0
    mkdir -p "$dir"
    local file tmp
    file="$dir/$hostname.txt"
    tmp=$(mktemp -p "$dir")
    awk -v repo="$repo_name" '$1 != repo { print }' "$file" > "$tmp" 2>/dev/null || true
    printf '%s %s\n' "$repo_name" "$refs_hash" >> "$tmp"
    mv -- "$tmp" "$file"
}

# Remove the recorded refs hash for a peer/repo.
# Args: <hostname> <repo_name>
clear_synced_hash() {
    local hostname="${1:-}" repo_name="${2:-}"
    local file
    file=$(sync_state_file_for_peer "$hostname") || true
    [ -n "${file:-}" ] || return 0
    [ -f "$file" ] || return 0
    local dir tmp
    dir=$(dirname "$file")
    tmp=$(mktemp -p "$dir")
    awk -v repo="$repo_name" '$1 != repo { print }' "$file" > "$tmp"
    mv -- "$tmp" "$file"
}
