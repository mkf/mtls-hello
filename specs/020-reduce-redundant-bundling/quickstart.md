# Quickstart: Reduce Redundant Bundle Sync

## What this feature does

When `on-discover.sh` runs, it now records the refs hash of each repository last sent to each peer in `/dev/shm`. On the next discovery, if the repository's refs have not changed, the callback skips the entire repo — no HEAD query, no spool query, no `git bundle create`, no upload.

## Inspect the shared-memory cache

After a successful discovery sync, the cache files are written to:

```text
/dev/shm/mtls-hello-sync/<data-dir-hash>/sync-state/<peer-hostname>.txt
```

Where `<data-dir-hash>` is the first 16 characters of the SHA-256 digest of the canonical, absolute `DATA_DIR` path. This keeps separate instances (prod, test, dev) isolated, while instances that share the same data directory share state.

Example:

```bash
DATA_DIR=$(realpath /tmp/mtls-data)
hash=$(printf '%s' "$DATA_DIR" | sha256sum | head -c16)
ls "/dev/shm/mtls-hello-sync/$hash/sync-state"
cat "/dev/shm/mtls-hello-sync/$hash/sync-state/peer2.txt"
```

Each line shows a repo name and the refs hash last sent:

```text
myproject a3b2c9d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2
```

## Run the focused tests

```bash
just test-d
bats tests/sync-state.bats      # once created
just robot
```

## Verify the skip behavior manually

1. Start two peers with the same data directory layout and trust each other.
2. Run a discovery sync and confirm bundles are uploaded.
3. Rediscover the same peer without pushing new commits.
4. Check the callback logs: the repo should be skipped with the exact message `[myproject] refs hash unchanged for peer2; skipping` (where `peer2` is the peer hostname from its certificate CN).
5. Inspect the shared-memory cache to confirm the current refs hash is recorded for that peer/repo.
5. Push a new commit to the repo and rediscover: the bundle should be uploaded again.

## Troubleshooting

- **No sync-state file appears**: Check that `DATA_DIR` is set in the daemon's environment, `/dev/shm` is writable, and the upload returned `HTTP 200`.
- **Still bundling after no changes**: Check the log for a failed branch upload; the cache is only written when all branches for a repo succeed.
- **Force-push not syncing**: Verify the refs hash changed (it is derived from the actual refs). The cache will be stale and the fallback bundling path will run.
- **Multiple instances on the same host**: The cache namespace is derived from the absolute `DATA_DIR` path. If two instances share the same `DATA_DIR`, they also share the cache.
