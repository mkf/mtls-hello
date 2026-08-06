# Data Model: Reduce Redundant Bundle Sync

## Entity: SyncStateRecord

A SyncStateRecord remembers the refs hash last sent to a specific peer for a specific repository. The record is stored in a shared-memory tmpfs file, not in the persistent data directory.

### Fields

| Field | Type | Description | Example |
|-------|------|-------------|---------|
| `peer_hostname` | string | Hostname of the peer, derived from the peer certificate CN. Used as part of the filename. | `peer2` |
| `repo_name` | string | Base name of the bare repository (without `.git`). | `myproject` |
| `refs_hash` | string | 64-character SHA-256 hex digest of the sorted refs list. | `a3b2c9...` |

### Identity

The natural key is the composite `(peer_hostname, repo_name)`.

### Storage Layout

```text
/dev/shm/
└── mtls-hello-sync/
    └── <data-dir-hash>/
        └── sync-state/
            ├── peer1.txt
            ├── peer2.txt
            └── ...
```

Where `<data-dir-hash>` is the first 16 characters of the SHA-256 digest of the canonical, absolute `DATA_DIR` path. This ensures that separate instances (prod, test, dev) using different data directories do not share sync state, while instances that intentionally use the same data directory share state.

Each file is a plain text file. One line per repository:

```text
myproject a3b2c9d4e5f6...
notes     7f8e9d0c1b2a...
```

Lines are stored in an arbitrary order. The helper functions read and rewrite the file atomically when updating a record.

### State Transitions

```text
┌──────────────────┐
│   No record      │
│   (missing or    │
│   hash mismatch) │
└────────┬─────────┘
         │
         │ sync succeeds
         ▼
┌──────────────────┐
│   Record stored  │
│   in /dev/shm    │
└────────┬─────────┘
         │
         │ refs change
         ▼
┌──────────────────┐
│   Hash mismatch  │
│   (record stale) │
└────────┬─────────┘
         │
         │ sync succeeds
         ▼
┌──────────────────┐
│   Record updated │
│   in /dev/shm    │
└──────────────────┘
         │
         │ reboot or tmpfs cleared
         ▼
┌──────────────────┐
│   Record lost    │
│   (acceptable)   │
└──────────────────┘
```

### Validation Rules

- `peer_hostname` must be non-empty and contain only characters valid in a filename.
- `repo_name` must be non-empty.
- `refs_hash` must be exactly 64 hex characters.
- Corrupted lines are ignored and the file is rewritten cleanly on the next update.

## Entity: Repository (existing)

Bare git repository under `REPOS_ROOT`. The set of refs is the source of truth for the refs hash.

## Entity: Peer (existing)

Another mtls-hello instance identified by hostname. The peer hostname is used to scope the sync-state file.
