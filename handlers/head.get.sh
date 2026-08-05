#!/bin/bash
# Return HEAD SHA and branch SHAs for a bare repository.
# Called by the peer during discovery to check if bundling is needed.
# Required env: REPOS_ROOT, QUERY_REPO
set -euo pipefail

repo_dir="${REPOS_ROOT?}/${QUERY_REPO?}.git"
if [ ! -d "$repo_dir" ]; then
    echo "HEAD 0000000000000000000000000000000000000000"
    exit 0
fi

# Print the HEAD commit SHA
head=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || echo "0000000000000000000000000000000000000000")
echo "HEAD $head"

# Print all local branch SHAs for fine-grained comparison
git -C "$repo_dir" for-each-ref --format='%(refname:short) %(objectname)' refs/heads/ 2>/dev/null || true
