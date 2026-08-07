#!/usr/bin/env bash
# Merge spooled git bundles into their bare repositories.
#
# Processes <data-dir>/spool/<repo>/*.bundle files, applies each to the
# corresponding bare repo under REPOS_ROOT, and deletes the spool file
# on success. Skips bundles whose parent commits are missing.
#
# Usage: scripts/merge-spool.sh [repo-name]
#   repo-name  merge only this repo (default: all repos in spool)
set -euo pipefail

cd "$(dirname "$0")/.."

# Safe-deletion helpers (no rm -rf / rm -f anywhere).
# shellcheck source=scripts/cleanup-common.sh
. scripts/cleanup-common.sh

. scripts/sync-lib.sh 2>/dev/null || true

: "${REPOS_ROOT:?REPOS_ROOT must be set}"

spool_dir="$(dirname "$0")/../spool"
filter="${1:-}"

applied=0
skipped=0

for repo_spool in "$spool_dir"/*/; do
    [ -d "$repo_spool" ] || continue
    repo=$(basename "$repo_spool")
    [ -n "$filter" ] && [ "$repo" != "$filter" ] && continue

    repo_dir="${REPOS_ROOT}/${repo}.git"
    echo "=== $repo ==="

    for bundle in "$repo_spool"*.bundle; do
        [ -f "$bundle" ] || continue
        bname=$(basename "$bundle")

        # Extract the peer host from the filename or use a default.
        peer_host="merged"

        if apply_bundle_to_repo "$repo_dir" "$bundle" "$peer_host" 2>&1; then
            remove_file_safe "$bundle"
            echo "  applied $bname"
            applied=$((applied + 1))
        else
            echo "  skipped $bname (missing parent or conflict)"
            skipped=$((skipped + 1))
        fi
    done
done

echo "applied=$applied skipped=$skipped"
