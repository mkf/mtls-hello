#!/usr/bin/env bats

# Safe-deletion helpers (no rm -rf / rm -f anywhere).
# shellcheck source=scripts/cleanup-common.sh
. scripts/cleanup-common.sh

setup() {
    TEST_DIR=$(mktemp -d)
    REPO_DIR="$TEST_DIR/repo.git"
    DATA_DIR="$TEST_DIR/data"
    mkdir -p "$DATA_DIR"
    git init --bare "$REPO_DIR" >/dev/null 2>&1
    git -C "$REPO_DIR" config user.email "test@example.com"
    git -C "$REPO_DIR" config user.name "Test"
    export DATA_DIR
    export REPO_DIR
}

teardown() {
    remove_git_repo "$TEST_DIR/repo.git"
    rmdir -- "$TEST_DIR/data" 2>/dev/null || true
    rmdir -- "$TEST_DIR" || echo "warning: could not rmdir $TEST_DIR" >&2
}

_commit_empty() {
    local repo="$1" msg="$2" branch="${3:-main}"
    local tree commit parent
    tree=$(git -C "$repo" hash-object -t tree /dev/null)
    parent=$(git -C "$repo" rev-parse --verify "$branch" 2>/dev/null || true)
    if [ -n "$parent" ]; then
        commit=$(printf '%s\n' "$msg" | git -C "$repo" commit-tree "$tree" -p "$parent")
    else
        commit=$(printf '%s\n' "$msg" | git -C "$repo" commit-tree "$tree")
    fi
    git -C "$repo" update-ref "refs/heads/$branch" "$commit"
}

@test "compute_refs_hash returns empty for non-git directory" {
    mkdir -p "$TEST_DIR/not-git"
    run bash -c 'source scripts/sync-state.sh; compute_refs_hash "$TEST_DIR/not-git"'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "compute_refs_hash returns 64-character hex for bare repo" {
    _commit_empty "$REPO_DIR" "init"
    run bash -c 'source scripts/sync-state.sh; compute_refs_hash "$REPO_DIR"'
    [ "$status" -eq 0 ]
    [ "${#output}" -eq 64 ]
    [[ "$output" =~ ^[0-9a-f]+$ ]]
}

@test "compute_refs_hash is stable for unchanged repo" {
    _commit_empty "$REPO_DIR" "init"
    run bash -c 'source scripts/sync-state.sh; compute_refs_hash "$REPO_DIR"'
    hash1="$output"
    run bash -c 'source scripts/sync-state.sh; compute_refs_hash "$REPO_DIR"'
    [ "$output" = "$hash1" ]
}

@test "compute_refs_hash changes after new commit" {
    _commit_empty "$REPO_DIR" "first"
    run bash -c 'source scripts/sync-state.sh; compute_refs_hash "$REPO_DIR"'
    hash1="$output"
    _commit_empty "$REPO_DIR" "second"
    run bash -c 'source scripts/sync-state.sh; compute_refs_hash "$REPO_DIR"'
    [ "$output" != "$hash1" ]
}

@test "set and get synced hash roundtrip" {
    local hash="a3b2c9d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2"
    run bash -c 'source scripts/sync-state.sh; set_synced_hash "peer1" "repo" "'"$hash"'"; get_synced_hash "peer1" "repo"'
    [ "$status" -eq 0 ]
    [ "$output" = "$hash" ]
}

@test "different peers are isolated" {
    local hash1="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    local hash2="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    run bash -c 'source scripts/sync-state.sh; set_synced_hash "peer1" "repo" "'"$hash1"'"; get_synced_hash "peer2" "repo"'
    [ -z "$output" ]
    run bash -c 'source scripts/sync-state.sh; set_synced_hash "peer2" "repo" "'"$hash2"'"; get_synced_hash "peer2" "repo"'
    [ "$output" = "$hash2" ]
}

@test "set_synced_hash updates existing record" {
    local hash1="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    local hash2="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    run bash -c 'source scripts/sync-state.sh; set_synced_hash "peer1" "repo" "'"$hash1"'"; set_synced_hash "peer1" "repo" "'"$hash2"'"; get_synced_hash "peer1" "repo"'
    [ "$output" = "$hash2" ]
}

@test "clear_synced_hash removes record" {
    local hash="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    run bash -c 'source scripts/sync-state.sh; set_synced_hash "peer1" "repo" "'"$hash"'"; clear_synced_hash "peer1" "repo"; get_synced_hash "peer1" "repo"'
    [ -z "$output" ]
}

@test "sync_state_file_for_peer uses canonical DATA_DIR" {
    local abs_dir
    abs_dir=$(cd "$DATA_DIR" && pwd)
    local hash
    hash=$(printf '%s' "$abs_dir" | sha256sum | awk '{print $1}' | head -c16)
    run bash -c 'source scripts/sync-state.sh; sync_state_file_for_peer "peer1"'
    [ "$output" = "/dev/shm/mtls-hello-sync/$hash/sync-state/peer1.txt" ]
}

@test "helpers fall back gracefully when DATA_DIR is unset" {
    run bash -c 'unset DATA_DIR; source scripts/sync-state.sh; sync_state_dir; sync_state_file_for_peer "peer1"; compute_refs_hash "$REPO_DIR"'
    [ "$status" -eq 0 ]
}

@test "skip condition matches when hash is unchanged" {
    _commit_empty "$REPO_DIR" "init"
    run bash -c 'source scripts/sync-state.sh; h=$(compute_refs_hash "$REPO_DIR"); set_synced_hash "peer1" "repo" "$h"; [ "$(compute_refs_hash "$REPO_DIR")" = "$(get_synced_hash "peer1" "repo")" ]'
    [ "$status" -eq 0 ]
}

@test "skip condition does not match after new commit" {
    _commit_empty "$REPO_DIR" "init"
    run bash -c 'source scripts/sync-state.sh; h=$(compute_refs_hash "$REPO_DIR"); set_synced_hash "peer1" "repo" "$h"'
    _commit_empty "$REPO_DIR" "second"
    run bash -c 'source scripts/sync-state.sh; [ "$(compute_refs_hash "$REPO_DIR")" != "$(get_synced_hash "peer1" "repo")" ]'
    [ "$status" -eq 0 ]
}
