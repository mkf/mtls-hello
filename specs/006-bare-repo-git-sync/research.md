# Research: Bare-Repository Git Sync Between Peers

**Branch**: `006-bare-repo-git-sync` | **Date**: 2026-08-05 | **Feature**: [spec.md](./spec.md)

## Decision: Transport via git bundle (--all) over HTTP POST

**Decision**: Each host creates a `git bundle --all` for every bare repository and POSTs it to the peer's `/bundle` endpoint. The peer receives the bundle and fetches its refs into the repository with namespace remapping for branches.

**Rationale**:
- `git bundle create <file> --all` captures every ref (branches, tags, HEAD) in one self-contained file.
- The existing HTTP POST infrastructure from feature 003 is reused — no git-smart-http or SSH transport needed.
- Git bundles were already validated in features 003/005 (bundle create → POST → fetch → merge) and work through symlinks (feature 005).

**Alternatives considered**:
- `git push` over a git transport — requires implementing the git-smart-http protocol or SSH access; overkill for an HTTPS server.
- Direct filesystem access (assuming shared volume) — breaks the LAN multi-host model; rejected.

## Decision: Branches are synced by force-fetching into a per-peer namespace, then promoting when safe

**Decision**: On the receiving side, branches from a bundle are first fetched into a per-peer remote-tracking namespace:

```text
git fetch <bundle> +refs/heads/*:refs/remotes/<peer-hostname>/*
```

The `+` prefix (force) accepts all incoming branches into the namespace. Then each incoming branch is promoted to the local `refs/heads/*` tree when it is safe:
- **Missing branch**: create `refs/heads/<branch>` at the incoming commit.
- **Fast-forward**: update `refs/heads/<branch>` to the incoming commit when the current local commit is an ancestor of the incoming commit.
- **Diverged**: leave the local `refs/heads/<branch>` unchanged; the peer's version remains in `refs/remotes/<peer-hostname>/<branch>`.

After a full bidirectional sync, both hosts have:
- Their own branches at `refs/heads/*`, updated for fast-forwardable branches and preserved for diverged ones.
- The peer's branches at `refs/remotes/<peer>/` for every branch the peer sent.

**Rationale**:
- This is the standard git pattern for multi-remote setups, extended with explicit promotion logic.
- It matches the user's spec: fast-forwardable branches are synced ("all regular branches"), while diverged branches are preserved non-destructively ("even if the branches were diverged").
- The peer hostname is derived from the sending host's identity (its certificate CN, matching the feature 004 trust model).

**Alternatives considered**:
- Fetch to `refs/heads/*` directly — impossible for diverged branches. Force-fetch would overwrite local branches. Rejected.
- Keep all branches in `refs/remotes/*` only — would not satisfy the "sync regular branches" intent for fast-forwardable branches. Rejected.
- Skip diverged branches (feature 003 model) — explicitly rejected by the user. Rejected.

## Decision: Tags fetched without force — conflict means skip

**Decision**: Tags from a bundle are fetched without the force prefix, and conflicts are tolerated:

```text
git fetch <bundle> refs/tags/*:refs/tags/* 2>/dev/null || true
```

- If a tag already exists on the receiver with the **same name and same object** — git leaves it untouched (idempotent).
- If a tag exists with the **same name but a different object** — git refuses the non-fast-forward update; the `|| true` prevents the fetch from failing the whole operation, effectively skipping the conflicting tag.
- If a tag is **missing** on the receiver — it is created.

**Rationale**:
- The user's spec says "the receiving host's existing tag wins" for same-name/different-object tags. This naturally falls out of non-force git fetch behavior.
- Idempotency (US2) is automatic: repeated syncs with identical refs produce no changes.

**Alternatives considered**:
- Force-fetch tags — overwrites existing tags with the sender's version; violates the user's "existing tag wins" intent. Rejected.
- Merge tags to a per-peer namespace — inconsistent with tags being globally unique identifiers; rejected.

## Decision: Callback rewritten for bare repos and push-everything model

**Decision**: `scripts/on-discover.sh` is substantially rewritten:

1. Iterates `"$REPOS_ROOT"/*/` — bare repos (e.g., `alpha.git/`).
2. Strips the `.git` suffix from the directory name to obtain the repo identifier.
3. For each bare repo: creates `git bundle --all`, POSTs it to the peer's `/bundle?repo=<name>&host=<HOST_NAME>`.
4. No HEAD comparison, no ancestor check — pushes all refs unconditionally.
5. The sender's identity (`HOST_NAME` env var from feature 002) is sent as the `host` query parameter for the receiving side's namespace mapping.

**Rationale**:
- The "push everything" model is the user's intent: sync all branches and tags, even diverged ones.
- Stripping `.git` ensures the repo identifier (`alpha` from `alpha.git`) matches the query parameter convention from feature 003.

**Alternatives considered**: Keep HEAD comparison + ancestor check — narrower than the user's request (all branches, all tags, diverged included). Rejected.

## Decision: Handler replaced — `bundle.post.sh` rewritten, `head.get.sh` retired

**Decision**:
- `handlers/head.get.sh` — **removed**. HEAD-based comparison is no longer part of the sync flow.
- `handlers/bundle.post.sh` — **rewritten** to accept bare repos and apply namespace-mapped refs:

```bash
repo_dir="${REPOS_ROOT?}/${QUERY_REPO?}.git"
peer_host="${QUERY_HOST?}"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
cat > "$tmp"

remote_ns="refs/remotes/${peer_host}"

# Namespaced fetch: accepts all branches, even diverged ones.
git -C "$repo_dir" fetch "$tmp" "+refs/heads/*:${remote_ns}/*"

# Promote fast-forwardable branches to local refs/heads; leave diverged branches
# in the per-peer namespace so nothing is overwritten.
while IFS= read -r ref; do
    branch="${ref#${remote_ns}/}"
    local_ref="refs/heads/${branch}"
    incoming="$(git -C "$repo_dir" rev-parse "${ref}")"
    if git -C "$repo_dir" show-ref --verify --quiet "${local_ref}"; then
        current="$(git -C "$repo_dir" rev-parse "${local_ref}")"
        if git -C "$repo_dir" merge-base --is-ancestor "${current}" "${incoming}"; then
            git -C "$repo_dir" update-ref "${local_ref}" "${incoming}"
        fi
    else
        git -C "$repo_dir" update-ref "${local_ref}" "${incoming}"
    fi
done < <(git -C "$repo_dir" for-each-ref --format='%(refname)' "${remote_ns}/")

# Tags: fetch without force; existing tags win on conflict.
git -C "$repo_dir" fetch "$tmp" "refs/tags/*:refs/tags/*" || true
echo "ok"
```

**Rationale**:
- The repo directory is `${QUERY_REPO}.git` because `REPOS_ROOT` contains bare repos named `*.git`.
- The `host` query parameter identifies the sender for the namespace, consistent with the callback's decision.
- Two separate fetch commands handle branches (forced, namespaced) and tags (non-forced, skip-on-conflict).

**Alternatives considered**: Keep a HEAD endpoint — unused in the new model; rejected.

## Decision: Test strategy — replace working-tree demos with bare-repo versions

**Decision**: The following BATS tests are replaced or added:

| Old test (feature/line) | Action | New test |
|---|---|---|
| 003 US2: working-tree sync demo | **Replaced** | 006 US1: two-host bare-repo sync (all branches, all tags, divergent) |
| 005 US1: symlinked working-tree demo | **Adapted** | Symlinked bare-repo sync (bare repos stored elsewhere, symlinked into REPOS_ROOT) |
| 005 US2: broken symlink (working-tree) | **Adapted** | Broken symlink with bare repos |

Idempotency (feature 006 US2) is a new test: run the sync twice, assert no new refs.

All other tests (features 001–004: trust, discovery, handlers, purgatory) are unchanged.

**Rationale**:
- Working-tree layout is removed per user directive; the old demo tests can't pass with the new code.
- Adapting 005's symlink tests preserves the symlink contract while switching to bare repos.
- Test count unchanged or slightly increased.

**Alternatives considered**: Keep old tests working — impossible without maintaining both layouts, which the user explicitly rejected.

## Decision: No D code changes

**Decision**: The feature changes only bash scripts (`handlers/bundle.post.sh`, `scripts/on-discover.sh`), test fixtures (`tests/smoke.bats`), and documentation. No D code is added, removed, or modified.

**Rationale**: The HTTP routing and TLS infrastructure are unchanged. The script-execution framework (feature 003) already supports arbitrary scripts. The sync logic lives entirely in shell scripts, which is the design intent from features 002/003.
