# Quickstart: Bare-Repository Git Sync

**Branch**: `006-bare-repo-git-sync` | **Date**: 2026-08-05 | **Feature**: [spec.md](./spec.md)

## 1. Set up bare repositories

Create bare git repositories under your `REPOS_ROOT` directory. Each one must be named with a `.git` suffix:

```sh
export REPOS_ROOT=/srv/repos
mkdir -p "$REPOS_ROOT"

for name in alpha beta gamma; do
    git init --bare "$REPOS_ROOT/${name}.git"
done
```

Populate them with initial content by cloning, committing, and pushing from a working tree:

```sh
# Create initial content somewhere else, then push to the bare repos.
# You can also import existing repos or symlink bare repos from elsewhere
# (feature 005's symlink contract applies).
```

## 2. Run the server

```sh
just run -- 8443 certs/certs/server.crt certs/private/server.key
```

The server will:
- Listen on port 8443 with mutual TLS.
- Accept peer discovery announcements via multicast.
- On discovery, run `scripts/on-discover.sh` which pushes all branches and tags from every bare repo to the peer.

## 3. What happens on sync

When host A discovers host B (and vice versa):

- **All branches** from A are fetched into B's per-peer namespace as `refs/remotes/A/<branchname>` (diverged branches are preserved here).
- **Fast-forwardable or missing branches** from A are promoted to B's own `refs/heads/<branchname>`. Diverged branches are left untouched in B's `refs/heads/*`; the peer's version is still available under `refs/remotes/A/<branchname>`.
- **New tags** from A appear on B under their original tag names. Tags that already exist on B with the same name but different content are **not overwritten** — B's existing tag wins.
- **After both directions sync**, each host has its own branches updated where possible, preserved where they diverged, PLUS all of the peer's branches under `refs/remotes/<peer>/`.

Verify what was received:

```sh
git -C "$REPOS_ROOT/alpha.git" branch -a          # all branches, local + remote-tracking
git -C "$REPOS_ROOT/alpha.git" tag                # all tags
git -C "$REPOS_ROOT/alpha.git" log refs/remotes/B/main  # peer's version of main
```

## 4. Automated tests

The test suite verifies:

- Two simulated hosts with bare repos, mixed branch states (ahead, behind, diverged, exclusive), and missing tags. After sync: all branches from both hosts exist on both hosts, diverged branches are preserved, missing tags were pushed.
- Running the sync twice (no changes) produces no new refs (idempotency).
- Symlinked bare repos work identically (feature 005 contract).
- A broken symlink under REPOS_ROOT is isolated and does not block other repos.

```sh
just test
```

## 5. Troubleshooting

- **"Repository not found" (404) on `/bundle`**: ensure the bare repo is named exactly `<identifier>.git` under `REPOS_ROOT` and is readable by the server.
- **Sync produced no remote-tracking branches**: check the server log for handler errors (bundle invalid, temp file failure).
- **Tag not synced**: the receiving side already had a tag with that name pointing to a different object — it is preserved (not overwritten). This is intentional.
- **git dubious-ownership error**: see feature 005 quickstart troubleshooting — ownership of the bare repo must match the user running the server.
