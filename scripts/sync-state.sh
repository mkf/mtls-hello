#!/bin/bash
# Shared-memory sync-state helpers for mTLS-hello git sync.
#
# Tracks the refs hash last sent to each peer for each repository in
# /dev/shm/mtls-hello-sync/<data-dir-hash>/sync-state/<peer-hostname>.txt.
#
# Requires: DATA_DIR set in the environment; set -euo pipefail in the caller.

# Print the base shared-memory directory for this instance.
# The directory name is derived from the canonical absolute DATA_DIR path
# so that separate instances (prod/test/dev) do not collide.
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

# Print the sync-state directory path.
sync_state_dir() {
    local base
    base=$(sync_state_base) || true
    [ -n "${base:-}" ] || return 0
    printf '%s/sync-state\n' "$base"
}

# Print the sync-state file path for a given peer hostname.
sync_state_file_for_peer() {
    local hostname="${1:-}"
    local dir
    dir=$(sync_state_dir) || true
    [ -n "${dir:-}" ] || return 0
    printf '%s/%s.txt\n' "$dir" "$hostname"
}

# Compute a deterministic SHA-256 hash of refs/heads and refs/tags.
# Args: <repo_dir>
# Output: 64-character hex digest, or empty string on failure.
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
    mv "$tmp" "$file"
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
    mv "$tmp" "$file"
}
