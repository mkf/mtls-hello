#!/bin/bash
# Receive a git bundle containing all refs and apply it to a bare repository.
#
# Branch sync rules:
#   1. All incoming branches are fetched into a per-peer namespace:
#      refs/remotes/<QUERY_HOST>/<branch>
#   2. If the local branch does not exist, it is created at the incoming commit.
#   3. If the local branch exists and the incoming commit is a descendant of
#      the local one (fast-forward), the local branch is updated.
#   4. If the local branch exists and the histories have diverged, the local
#      branch is left unchanged and the peer's version stays in the namespace.
#
# Tag sync rules:
#   - Tags are fetched without force. Missing tags are created; existing tags
#     with the same name but a different object are left untouched (the existing
#     tag wins). A non-zero exit from a tag conflict is ignored so that the
#     branch sync is not rolled back.
#
# Required env (set by the server):
#   REPOS_ROOT       directory containing bare repositories (e.g. alpha.git)
#   QUERY_REPO       repository identifier (without .git suffix, e.g. alpha)
#   QUERY_HOST       sending host's identity (used for the remote namespace)
set -euo pipefail

repo_dir="${REPOS_ROOT?}/${QUERY_REPO?}.git"
# Create the bare repo if it doesn't exist on this side yet.
[ -d "$repo_dir" ] || git init --bare "$repo_dir"
peer_host="${QUERY_HOST?}"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

cat > "$tmp"

remote_ns="refs/remotes/${peer_host}"

# 1. Fetch all incoming branches into the per-peer namespace.
git -C "$repo_dir" fetch "$tmp" "+refs/heads/*:${remote_ns}/*"

# 2. Promote incoming branches to local refs/heads when safe.
while IFS= read -r ref; do
    branch="${ref#${remote_ns}/}"
    incoming="$(git -C "$repo_dir" rev-parse "$ref")"

    if git -C "$repo_dir" show-ref --verify --quiet "refs/heads/${branch}"; then
        local="$(git -C "$repo_dir" rev-parse "refs/heads/${branch}")"
        if git -C "$repo_dir" merge-base --is-ancestor "$local" "$incoming"; then
            git -C "$repo_dir" update-ref "refs/heads/${branch}" "$incoming"
        fi
    else
        git -C "$repo_dir" update-ref "refs/heads/${branch}" "$incoming"
    fi
done < <(git -C "$repo_dir" for-each-ref --format='%(refname)' "${remote_ns}/")

# 3. Fetch tags without force; skip conflicts silently.
git -C "$repo_dir" fetch "$tmp" "refs/tags/*:refs/tags/*" || true

echo "ok"
