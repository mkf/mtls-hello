#!/usr/bin/env bash
# Test git sync flow locally — sender (bundle) + receiver (bundle.post.sh).
# Takes a bare repo, bundles it, runs the receiver logic directly.
# Purpose: debug the 400 error by testing bundle.post.sh in isolation.
set -euo pipefail
unset LD_LIBRARY_PATH

cd "$(dirname "$0")/.."

repo="${1:?Usage: $0 <path-to-bare-repo.git>}"
name=$(basename "$repo" .git)
tmpdir=$(mktemp -d)
trap "rm -rf $tmpdir" EXIT

# Create receiver side (fresh bare repo)
PEER_REPO="$tmpdir/${name}.git"
git init --bare "$PEER_REPO" >/dev/null 2>&1
echo "=== Receiver: fresh bare repo at $PEER_REPO ==="

# Sender: bundle all refs
echo "=== Sender: bundling $repo ==="
BUNDLE="$tmpdir/bundle"
git -C "$repo" bundle create "$BUNDLE" --all 2>&1
echo "Bundle size: $(wc -c < "$BUNDLE") bytes, contains:"
git bundle list-heads "$BUNDLE" 2>/dev/null

# Receiver: simulate bundle.post.sh logic
echo ""
echo "=== Receiver: applying bundle (bundle.post.sh logic) ==="
export REPOS_ROOT="$tmpdir"
export QUERY_REPO="$name"
export QUERY_HOST="test-peer"

repo_dir="${REPOS_ROOT?}/${QUERY_REPO?}.git"
peer_host="${QUERY_HOST?}"
remote_ns="refs/remotes/${peer_host}"

# Step 1: fetch all incoming branches into per-peer namespace (via temp file as in bundle.post.sh)
echo "--- fetch into $remote_ns ---"
BF="$tmpdir/bundle.tmp"
cp "$BUNDLE" "$BF"
git -C "$repo_dir" fetch "$BF" "+refs/heads/*:${remote_ns}/*" 2>&1

# Step 2: promote branches
echo "--- promoting branches ---"
while IFS= read -r ref; do
    branch="${ref#${remote_ns}/}"
    incoming="$(git -C "$repo_dir" rev-parse "$ref" 2>/dev/null)" || continue

    if git -C "$repo_dir" show-ref --verify --quiet "refs/heads/${branch}" 2>/dev/null; then
        local_sha="$(git -C "$repo_dir" rev-parse "refs/heads/${branch}")"
        if git -C "$repo_dir" merge-base --is-ancestor "$local_sha" "$incoming" 2>/dev/null; then
            echo "  $branch: fast-forward $local_sha -> $incoming"
            git -C "$repo_dir" update-ref "refs/heads/${branch}" "$incoming"
        else
            echo "  $branch: diverged, keeping both (local + $remote_ns)"
        fi
    else
        echo "  $branch: created at $incoming"
        git -C "$repo_dir" update-ref "refs/heads/${branch}" "$incoming"
    fi
done < <(git -C "$repo_dir" for-each-ref --format='%(refname)' "${remote_ns}/" 2>/dev/null || true)

# Step 3: fetch tags (via same temp file)
echo "--- fetching tags ---"
git -C "$repo_dir" fetch "$BF" "refs/tags/*:refs/tags/*" 2>&1 || true

# Step 4: fix HEAD
first_branch=$(git -C "$repo_dir" for-each-ref --format='%(refname)' refs/heads 2>/dev/null | head -1)
if [ -n "$first_branch" ] && ! git -C "$repo_dir" rev-parse --verify HEAD >/dev/null 2>&1; then
    git -C "$repo_dir" symbolic-ref HEAD "$first_branch"
    echo "  HEAD -> $first_branch"
fi

echo ""
echo "=== Result ==="
echo "Branches:"
git -C "$PEER_REPO" for-each-ref --format='  %(refname:short) %(objectname)' refs/heads/ 2>/dev/null || echo "  (none)"
echo "Tags:"
git -C "$PEER_REPO" for-each-ref --format='  %(refname:short) %(objectname)' refs/tags/ 2>/dev/null || echo "  (none)"
echo "HEAD: $(git -C "$PEER_REPO" symbolic-ref HEAD 2>/dev/null || echo 'dangling')"

echo ""
echo "=== Source (sender) refs ==="
git -C "$repo" for-each-ref --format='  %(refname:short) %(objectname)' 2>/dev/null || true

# Verify cloneability
echo ""
echo "=== Test clone ==="
clone=$(mktemp -d)
if git clone "$PEER_REPO" "$clone" 2>/dev/null; then
    echo "clone OK — HEAD at $(git -C "$clone" rev-parse HEAD)"
    ls "$clone" | head -5
    rm -rf "$clone"
else
    echo "clone FAILED (this is the bug)"
    rm -rf "$clone"
fi
