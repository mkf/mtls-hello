# Contract: Shared-Memory Sync State

## Purpose

Define the shared-memory format of the sync-state cache and the helper functions used by `on-discover.sh` to read and write it. The state lives in `/dev/shm` and is not persisted to the data directory.

## Storage Contract

### Location

The sync-state directory is located in shared memory:

```text
/dev/shm/mtls-hello-sync/<data-dir-hash>/sync-state
```

Where `<data-dir-hash>` is the first 16 characters of the SHA-256 digest of the canonical, absolute `DATA_DIR` path. This ensures that separate instances (prod, test, dev) using different data directories do not share sync state, while instances that intentionally use the same data directory share state. The helper functions canonicalize `DATA_DIR` with `realpath` or `cd "$DATA_DIR" && pwd` before hashing.

### File Format

- One file per peer: `/dev/shm/mtls-hello-sync/<data-dir-hash>/sync-state/<peer-hostname>.txt`.
- Text encoding: UTF-8.
- One record per line: `<repo-name> <refs-hash>`.
- Fields separated by one or more whitespace characters.
- Lines are not order-sensitive.
- Blank lines and lines starting with `#` are ignored.
- Lines that do not match the expected format are ignored on read and removed on the next write.

### Example File

```text
# Sync state for peer2
myproject a3b2c9d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2
notes     7f8e9d0c1b2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8
```

## Function Contract: `scripts/sync-state.sh`

All functions are sourced by `scripts/on-discover.sh`. They expect `DATA_DIR` to be set in the environment and fall back to empty/invalid state if it is missing or if `/dev/shm` is not writable.

### `sync_state_dir()`

- **Input**: none
- **Output**: prints the path `/dev/shm/mtls-hello-sync/<data-dir-hash>/sync-state` to stdout.
- **Side effects**: none (the directory is not created).
- **Failure**: prints empty string if `DATA_DIR` is unset or `/dev/shm` is missing.

### `sync_state_file_for_peer(hostname)`

- **Input**: peer hostname (string)
- **Output**: prints the path to the peer's state file to stdout.
- **Side effects**: none.
- **Failure**: prints empty string if `DATA_DIR` is unset, `/dev/shm` is missing, or hostname is empty.

### `compute_refs_hash(repo_dir)`

- **Input**: path to a bare git repository directory
- **Output**: prints the 64-character SHA-256 hex digest of the sorted refs list to stdout.
- **Refs included**: `refs/heads/*` and `refs/tags/*` (dereferenced to object SHAs).
- **Determinism**: the same set of refs always produces the same hash, regardless of the order returned by `git for-each-ref`.
- **Side effects**: none (read-only git operation).
- **Failure**: prints empty string if `repo_dir` is not a git repository or is missing.

### `get_synced_hash(hostname, repo_name)`

- **Input**: peer hostname, repository name
- **Output**: prints the recorded refs hash for that peer/repo, or empty string if no valid record exists.
- **Side effects**: none.
- **Failure**: empty string on missing file, corrupted line, or invalid `refs_hash` field.

### `set_synced_hash(hostname, repo_name, refs_hash)`

- **Input**: peer hostname, repository name, refs hash (64 hex chars)
- **Output**: none
- **Side effects**: writes or updates the record in the peer's state file in `/dev/shm`. Creates the shared-memory directory and file if necessary.
- **Failure**: silently returns if `DATA_DIR`, `/dev/shm`, or hostname is empty, or if the hash is not 64 hex characters.

### `clear_synced_hash(hostname, repo_name)`

- **Input**: peer hostname, repository name
- **Output**: none
- **Side effects**: removes the record for the repo from the peer's state file in `/dev/shm`. Does nothing if the record does not exist.
- **Failure**: silently returns if `DATA_DIR`, `/dev/shm`, or hostname is empty.

## Atomicity Contract

- Reads may see a file that is being rewritten concurrently, but the worst case is a partial or missing record, which triggers the fallback bundling path (safe default).
- Writes rewrite the peer's state file from scratch to a temporary file in the same `/dev/shm` directory and then move it into place, so a failed write never leaves a partially updated state file.

## Lifecycle

- **Record created**: after a successful bundle upload to a peer for a given repo.
- **Record updated**: when the repo's refs change and a successful upload occurs again.
- **Record invalidated**: automatically when the current refs hash no longer matches the recorded hash.
- **Record deleted**: when `clear_synced_hash` is called or when the host reboots (tmpfs is cleared).
