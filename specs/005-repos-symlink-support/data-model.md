# Data Model: REPOS_ROOT Symlinked Repositories

**Branch**: `005-repos-symlink-support` | **Date**: 2026-08-05 | **Feature**: [spec.md](./spec.md)

## Entities

### ReposRootLayout

The root collection directory referenced by the `REPOS_ROOT` environment variable. Its children are repository entries.

| Field | Type | Source | Description |
|---|---|---|---|
| `path` | string | `REPOS_ROOT` env var | Directory containing repository entries |
| `entryCount` | int | filesystem scan | Number of entries processed per sync run |

Validation / invariants:
- `REPOS_ROOT` must point to a readable directory; may itself be a symlink to a directory.
- Missing directory = no repositories to sync (callback produces `synced=0 skipped=0`, no error) — unchanged from feature 003.

### RepoEntry

A single repository reference under `REPOS_ROOT`, identified by its entry name.

| Field | Type | Description |
|---|---|---|
| `name` | string | Entry name (basename of the entry path); used as the `repo` query parameter |
| `referenceType` | enum | `realDirectory` or `symlink` (to a directory) |
| `resolvedPath` | string | The physical repository directory the entry resolves to (identical to the entry path for real directories) |
| `available` | bool | Whether the entry resolves to an existing, readable repository (false for broken symlinks / missing targets) |

Invariants:
- Resolution is identical for real directories and symlinks: `git -C <entry>` operates on `resolvedPath` either way.
- An entry is `available=false` when its symlink target is missing or unreadable (broken symlink); such an entry is never synced.
- Mixed layouts (some real directories, some symlinks) are valid; each entry is handled independently.

### SymlinkTarget

The external location a symlinked entry points to.

| Field | Type | Description |
|---|---|---|
| `path` | string | Absolute or relative target; relative targets resolve relative to the entry's parent directory |
| `kind` | enum | `absolute`, `relative`, `chain` (symlink → symlink → target) |
| `ownedByInvoker` | bool | Whether the target's owner matches the process invoking git (see `safe.directory` caveat) |

Invariants:
- Targets are standard (non-bare) repository working trees with their own version-control metadata (matches feature-003 demo repos).
- A target whose owner differs from the invoking user may be refused by git (dubious-ownership protection); this is an operator-environment concern, documented in `contracts/repos-layout.md`.

### Repository (per side) — unchanged from feature 003

An independent version-controlled repository tracked for synchronization. Identified by its `RepoEntry.name` (the `repo` query parameter).

State per sync run: `ahead` (local strictly advances peer → bundle pushed), `inSync` (equal HEADs → skipped), `diverged` (neither is an ancestor → skipped), `unavailable` (broken symlink / lookup failure → skipped with log).

## Relationships

```
ReposRootLayout 1 ── * RepoEntry
RepoEntry 0..1 ── 1 SymlinkTarget   (only when referenceType = symlink)
RepoEntry 1 ── 1 Repository (per side)
```

## State Transitions

`RepoEntry` availability is determined fresh on each sync run (a target may become available/unavailable between runs). There is no persisted state.

```
entry resolved
├── available=true  → Repository state: ahead → pushed / inSync → skipped / diverged → skipped
└── available=false → skipped (logged, isolated; other entries unaffected)
```
