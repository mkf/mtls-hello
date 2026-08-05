# Contract: Bare-Repository Sync Protocol

**Branch**: `006-bare-repo-git-sync` | **Date**: 2026-08-05 | **Feature**: [spec.md](../spec.md)

> This contract defines the sync protocol between two hosts with bare repositories. It supersedes the HEAD-comparison sync from features 003 and 005.

## REPOS_ROOT Layout

`REPOS_ROOT` is a directory containing **bare git repositories**, each named with a `.git` suffix:

```text
REPOS_ROOT/
├── alpha.git/
├── beta.git/
└── gamma.git/
```

The repository **identifier** used in sync is the basename with the `.git` suffix stripped: `alpha`, `beta`, `gamma`.

## Bundle Endpoint

### POST /bundle?repo=<name>&host=<sender-hostname>

Receives a git bundle containing all refs from a peer repository and applies them.

**Query parameters**:

| Parameter | Required | Description |
|---|---|---|
| `repo` | Yes | Repository identifier (basename without `.git`, e.g. `alpha`) |
| `host` | Yes | Sending host's identity (used for the remote-tracking namespace) |

**Request body**: A git bundle file created with `git bundle create --all`.

**Processing**:

1. The handler maps `repo` to the bare repo path: `$REPOS_ROOT/${repo}.git`.
2. Saves the body to a temp file.
3. Fetches branches into the per-peer namespace:

   ```text
   git fetch <tmpfile> +refs/heads/*:refs/remotes/<host>/*
   ```

4. Promotes incoming branches to `refs/heads/*` when safe:
   - If the local `refs/heads/<branch>` does not exist, it is created at the incoming commit.
   - If the local `refs/heads/<branch>` exists and the incoming commit is a descendant (fast-forward), it is updated to the incoming commit.
   - If the histories have diverged, the local branch is left unchanged and the peer's version remains in `refs/remotes/<host>/<branch>` (non-destructive).

5. Fetches tags without force:

   ```text
   git fetch <tmpfile> refs/tags/*:refs/tags/* || true
   ```

   Tags already present with the same object are untouched. Tags with the same name but different objects are skipped (the existing tag wins). Missing tags are created.

5. Cleans up the temp file, responds `200 ok`.

**Error behavior**:

| Scenario | Behavior |
|---|---|
| Repository not found under `REPOS_ROOT` | 404 |
| `repo` or `host` query parameter missing | 400 |
| Bundle is invalid or corrupted | 500 (git fetch fails) |
| Temp file creation fails | 500 |

## Callback Sync Logic

`scripts/on-discover.sh` is rewritten for bare repos. On each discovery event:

```text
for each directory matching REPOS_ROOT/*.git/:
  repo_name = basename(strip .git)
  bundle = mktemp
  git -C <repo> bundle create --all → $bundle
  POST /bundle?repo=$repo_name&host=$HOST_NAME  body=$bundle
  rm $bundle
```

No HEAD comparison, no ancestor check — **all refs are pushed unconditionally**. The sender's identity is taken from `$HOST_NAME` (feature 002).

## After-Sync State

After a full bidirectional sync (host A pushes to B, B pushes to A):

**On host A**:
- `refs/heads/*` — A's own branches. Branches that B has fast-forwarded (A's commit is an ancestor of B's) are updated to B's commit. Branches that exist only on B are created. Diverged branches remain at A's own commit.
- `refs/remotes/B/*` — B's branches (force-synced into the namespace). For diverged branches, this holds B's version while A's own branch stays unchanged.
- `refs/tags/*` — A's tags + B's new tags; conflicting tags won as per conflict rules

**On host B**:
- `refs/heads/*` — B's own branches, updated on fast-forward / created from A, unchanged on divergence.
- `refs/remotes/A/*` — A's branches (force-synced into the namespace).
- `refs/tags/*` — B's tags + A's new tags; conflicting tags won as per conflict rules

## Idempotency

Running the sync again with no changes to either side:
- Branch fetch: force-update of identical refs — no change.
- Tag fetch: all tags already present — no new tags created.
- Exit cleanly with `200 ok` for every repository.

## Symlink Support

Bare repositories may be symlinks to repositories stored elsewhere (feature 005 contract applies — `REPOS_ROOT/alpha.git -> /srv/git/alpha.git` works identically).
