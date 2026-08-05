# Quickstart: REPOS_ROOT with Symlinked Repositories

**Branch**: `005-repos-symlink-support` | **Date**: 2026-08-05 | **Feature**: [spec.md](./spec.md)

This guide explains how to use `REPOS_ROOT` when the repositories under it are **symlinks pointing to repositories stored elsewhere**, and what the test suite verifies.

## 1. The supported layout

`REPOS_ROOT` is the directory of local repositories used by the discovery callback (`scripts/on-discover.sh`) and the `/head` / `/bundle` handlers. Each entry may be a real directory **or a symlink to a directory stored elsewhere**:

```sh
export REPOS_ROOT=/srv/repos          # may itself be a symlink too
ls -l "$REPOS_ROOT"
# alpha -> /srv/git/alpha
# beta  -> ../shared/beta            # relative targets work
# gamma -> /srv/git/gamma
# delta                              # a real directory also works (mixed layout)
```

Rules:

- Targets may be absolute or relative; symlink chains work.
- The entry **name** (e.g. `alpha`) is the repository identifier used as `?repo=alpha`.
- Mixed layouts (some real dirs, some symlinks) are fine — each entry is handled independently.

## 2. Run the sync as usual

No changes to the flow — the callback and handlers operate through the symlinks:

```sh
REPOS_ROOT=/srv/repos bash scripts/on-discover.sh
```

## 3. What the tests verify

The BATS suite includes:

- **US1 — fully symlinked demo**: every `REPOS_ROOT` entry (both local and peer sides) is a symlink to a repository stored in a separate directory. The sync must produce the identical outcome as the real-directory demo: ahead repositories are fast-forwarded, in-sync repositories are skipped, diverged repositories are untouched.
- **US2 — broken symlink isolation**: one broken symlink among healthy entries. Healthy entries sync normally; the broken entry is skipped with a log line and no other repository is affected.

Run everything:

```sh
just test
```

## 4. Troubleshooting

- **`[name] head lookup failed; skipping` for an entry that looks fine**: the entry's symlink target may be missing (broken symlink) or unreadable. Fix the link or the target's permissions.
- **git error: "detected dubious ownership"**: git ≥ 2.35.2 refuses to operate on a repository owned by a different user. If the symlink target lives under another owner (e.g., a shared location), either align ownership or add the target to `git config --global --add safe.directory <target>`.
- **Diverged repositories are skipped**: unchanged behavior — the callback never sends a bundle when neither HEAD is an ancestor of the other.
