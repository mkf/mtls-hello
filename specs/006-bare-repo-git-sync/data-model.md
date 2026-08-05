# Data Model: Bare-Repository Git Sync Between Peers

**Branch**: `006-bare-repo-git-sync` | **Date**: 2026-08-05 | **Feature**: [spec.md](./spec.md)

## Entities

### BareRepository

A git repository without a working tree, stored directly under `REPOS_ROOT`. Contains the repository metadata (the contents normally inside `.git`).

| Field | Type | Description |
|---|---|---|
| `name` | string | Repository identifier, e.g. `alpha` from `alpha.git/` |
| `path` | string | Filesystem path, e.g. `REPOS_ROOT/alpha.git/` |
| `branches` | BranchSet | All `refs/heads/*` entries |
| `tags` | TagSet | All `refs/tags/*` entries |

Invariants:
- Named with a `.git` suffix by convention; the identifier used in sync is the basename without `.git`.
- An empty bare repo (no commits) has empty BranchSet and TagSet and is skipped during sync.

### BranchSet

The collection of regular branches in a repository.

| Field | Type | Description |
|---|---|---|
| `entries` | list of BranchRef | Each `refs/heads/*` entry |
| `count` | int | Number of branches |

### BranchRef

A single branch reference.

| Field | Type | Description |
|---|---|---|
| `name` | string | Branch name, e.g. `main`, `feature/x` |
| `fullRef` | string | Full ref path, `refs/heads/<name>` |
| `commit` | string | SHA-1 of the commit it points to |

### TagSet

The collection of tags in a repository.

| Field | Type | Description |
|---|---|---|
| `entries` | list of TagRef | Each `refs/tags/*` entry |
| `count` | int | Number of tags |

### TagRef

A single tag reference (lightweight or annotated).

| Field | Type | Description |
|---|---|---|
| `name` | string | Tag name |
| `fullRef` | string | Full ref path, `refs/tags/<name>` |
| `object` | string | SHA-1 of the object it points to |

### PeerNamespace

The per-peer remote-tracking namespace where a host's branches are stored on its peers after sync.

| Field | Type | Description |
|---|---|---|
| `peerHostname` | string | The sending host's identity (from certificate CN, matching the trust model) |
| `namespace` | string | `refs/remotes/<peerHostname>/` — the ref prefix |
| `branches` | BranchSet | The peer's branches stored under this namespace after sync |

Invariant: after sync, `hostA/refs/remotes/hostB/*` holds all of hostB's branches; `hostB/refs/remotes/hostA/*` holds all of hostA's branches.

### BundleTransfer

A self-contained git bundle carrying all refs from one repository, transmitted via HTTP POST.

| Field | Type | Description |
|---|---|---|
| `repoName` | string | Repository identifier (`?repo=`) |
| `senderHostname` | string | Sending host identity (`?host=`) |
| `contents` | binary | The `git bundle --all` output — all refs and objects |

Lifecycle: created by the sender's callback → POST'd to `/bundle` → fetched into the receiver's repo with namespace remapping → temp file deleted.

## Relationships

```
BareRepository 1 ── 1 BranchSet
BareRepository 1 ── 1 TagSet
BareRepository * ── * PeerNamespace   (each peer that has synced)
PeerNamespace 1 ── 1 BranchSet        (the peer's branches after sync)
BundleTransfer 1 ── 1 BareRepository  (one bundle per repo per sync run)
```

## State Transitions

**Sync operation (per repository, per sender-receiver pair)**:

```
Sender:
  git bundle --all → BundleTransfer

Receiver (post-sync):
  Existing refs/remotes/<sender>/*  →  updated (force) to sender's current branches
  Missing tags                     →  created
  Conflicting tags (same name, different object) → skipped (unchanged)
  Non-conflicting tags             →  created
```
