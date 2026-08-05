# Contract: REPOS_ROOT Layout — Symlink Semantics

**Branch**: `005-repos-symlink-support` | **Date**: 2026-08-05 | **Feature**: [spec.md](../spec.md)

> This contract extends `specs/003-script-endpoints-git-sync/contracts/callback.md`. The callback invocation contract, the `REPOS_ROOT` environment variable, and the HEAD/bundle endpoint semantics are unchanged. This document specifies the **layout semantics** of `REPOS_ROOT` entries.

## Repository Entry Types

Each entry under `REPOS_ROOT` is a repository reference of one of two types:

| Type | Example | Behavior |
|---|---|---|
| Real directory | `REPOS_ROOT/alpha/` (contains `.git`) | Synced as in feature 003 |
| Symlink to a directory | `REPOS_ROOT/alpha -> /srv/git/alpha` | Resolved to the target; synced identically |

### Symlink resolution rules

- Targets may be **absolute** (`/srv/git/alpha`) or **relative** (`../git/alpha`; resolved relative to the entry's parent directory).
- **Symlink chains** (entry → symlink → target) are supported.
- `REPOS_ROOT` itself may be a symlink to a directory of entries.
- Resolution happens via the operating system and git (`git -C <entry>`); handlers do not pre-resolve paths.

## Selection and Naming

- The entry **name** is the basename of the entry path (e.g. `alpha` for `REPOS_ROOT/alpha -> /srv/git/alpha`).
- The name is used as the `repo` query parameter for `/head` and `/bundle` — unchanged from feature 003.
- Symlinks do not change naming, and must not introduce new ways to address paths outside `REPOS_ROOT` (entry-name handling is unchanged; traversal semantics are the same as feature 003).

## Failure Semantics

| Scenario | Behavior |
|---|---|
| Broken symlink / missing target (entry `available=false`) | HEAD lookup fails (handler non-zero → HTTP 500); bundle submission fails; callback skips the entry with a log line; **no other entry is affected** |
| Symlinked entry diverged from peer | No bundle sent; unchanged from feature 003 |
| Symlinked entry already in sync | Skipped; no bundle; unchanged |
| Target owned by a different user (git ≥ 2.35.2 dubious-ownership protection) | git refuses to operate (`safe.directory`); operator must align ownership or configure `safe.directory` — documented, not handled by the tooling |

## Test Coverage

The automated test suite must include:

1. **Fully symlinked layout (US1)**: every `REPOS_ROOT` entry on both sides is a symlink to a repository stored in a separate directory; the demo must produce the identical invariants as the real-directory demo (ahead → synced, in-sync → skipped, diverged → untouched).
2. **Broken symlink isolation (US2)**: one broken symlink among healthy entries; healthy entries sync, the broken entry is skipped, no cross-entry corruption.
