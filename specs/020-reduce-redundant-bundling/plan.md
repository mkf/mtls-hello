# Implementation Plan: Reduce Redundant Bundle Sync

**Branch**: `020-reduce-redundant-bundling` | **Date**: 2026-08-06 | **Spec**: spec.md

**Input**: Feature specification from `specs/020-reduce-redundant-bundling/spec.md`

## Summary

Add a shared-memory refs-hash cache in the shell callback path so that `on-discover.sh` can skip a repository entirely when the refs that would be sent to a peer have not changed since the last successful sync. The cache lives in `/dev/shm` and is managed entirely by shell helper functions. The D discovery daemon is not modified and remains unaware of git repositories or sync state.

## Technical Context

**Language/Version**: Bash 4+, POSIX utilities, Git 2.30+

**Primary Dependencies**: `git`, `curl`, `openssl`, `sha256sum` (or `shasum` on macOS)

**Storage**: Shared-memory tmpfs (`/dev/shm/mtls-hello-sync/<data-dir-hash>/sync-state/`)

**Testing**: BATS (legacy), Robot Framework (Apache end-to-end), shell tests for `sync-state.sh` helpers

**Target Platform**: Linux server (Debian/Arch), also runs on Nix and in Docker

**Project Type**: mTLS daemon + shell-scripted git sync workflow

**Performance Goals**: Reduce CPU time in `git bundle` and `git rev-parse` calls by 70%+ for unchanged repos; reduce upload bytes by 90%+ when no new commits exist

**Constraints**: No writes to the data directory for sync state; no D daemon changes; no central database; each peer tracked independently; must tolerate force-push and missing/stale state by falling back to bundling

**Scale/Scope**: Number of repos per host typically <100, number of peers per host typically <20, discovery interval 5 seconds

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

The project constitution is a template and has no active non-negotiable gates. The following principles are observed:

1. **No system-wide changes**: Sync state lives in `/dev/shm`, not in `/etc` or system paths. The namespace is derived from the data directory, so multiple instances do not collide.
2. **No hardcoded defaults**: The data directory is provided by the caller (`DATA_DIR`), defaulting only to the environment/CLI value already established by prior features. The shared-memory path is derived from `DATA_DIR`.
3. **Maintainable code**: The logic is data-driven, shellcheck-clean, and testable with small helper functions.
4. **No central coordination**: Each host tracks only what it has sent to each peer; no shared database or disk state.
5. **Separation of concerns**: The D discovery daemon handles discovery and certificate capture; the shell callback handles git sync and the shared-memory cache.

## Project Structure

### Documentation (this feature)

```text
specs/020-reduce-redundant-bundling/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
└── tasks.md             # Phase 2 output (created by /speckit.tasks)
```

### Source Code (repository root)

```text
scripts/
├── on-discover.sh       # Main callback; will call sync-state helpers
├── sync-common.sh       # Shared curl/cert helpers (no change)
└── sync-state.sh        # NEW: load/save refs-hash sync state in /dev/shm

tests/
├── smoke.bats           # Legacy tests; may add sync-state checks
├── apache.bats          # Legacy tests; may add sync-state checks
└── sync-state.bats      # NEW: focused tests for the helper functions
```

**Structure Decision**: The feature is a pure shell-script optimization, so changes are concentrated in `scripts/`. A small dedicated `scripts/sync-state.sh` keeps the refs-hash cache logic isolated and testable. The D discovery daemon is untouched. No new top-level project structure is created.

## Research (Phase 0)

See `specs/020-reduce-redundant-bundling/research.md` for detailed findings.

### Key Decisions

- **Sync state location**: `/dev/shm/mtls-hello-sync/<data-dir-hash>/sync-state/<peer-hostname>.txt`. Backed by RAM, not the data directory, and cleared on reboot. The data-dir hash ensures each instance has its own namespace.
- **Refs hash input**: A deterministic hash of `refs/heads/*` and `refs/tags/*` SHAs, sorted by ref name. This captures the complete set of refs that would be sent, not just HEAD.
- **Hash function**: `git for-each-ref` piped to `sha256sum` (or equivalent). The callback shells out to `git` and `sha256sum`, which are already available in the Nix and target environments.
- **Update trigger**: Record state only after a successful bundle upload for every branch of a repo. If any branch fails, the cache is not updated for that repo, so the next discovery will retry.
- **Fallback**: If the shared-memory state is missing, corrupted, or the hash does not match, the callback falls back to the existing HEAD/spool checks and bundling path.
- **Daemon boundary**: The D discovery daemon is not modified. The callback receives the same environment variables as today and uses `DATA_DIR` only to derive the shared-memory namespace.

## Design (Phase 1)

### Data Model

See `specs/020-reduce-redundant-bundling/data-model.md`.

Primary entity:

- **SyncStateRecord**
  - `peer_hostname`: string, used as part of the shared-memory filename
  - `repo_name`: string, line key
  - `refs_hash`: hex string, 64 characters (SHA-256)

### Contracts

See `specs/020-reduce-redundant-bundling/contracts/`.

- `sync-state.md`: On-disk format of the shared-memory state files and the helper functions exposed by `scripts/sync-state.sh`.
- `callback-env.md`: Re-iteration of the environment variables available to `on-discover.sh` (no new env vars are required).

### Implementation Details

1. **New helper file `scripts/sync-state.sh`**
   - `sync_state_dir()`: prints the path to the shared-memory sync-state directory, derived from `DATA_DIR`.
   - `sync_state_file_for_peer(hostname)`: prints the path to the peer's state file.
   - `compute_refs_hash(repo_dir)`: computes a deterministic hash of all refs in the repo.
   - `get_synced_hash(hostname, repo_name)`: returns the recorded hash or empty string.
   - `set_synced_hash(hostname, repo_name, refs_hash)`: records the hash in the shared-memory file.
   - `clear_synced_hash(hostname, repo_name)`: removes the record.

2. **Shared-memory namespace**
   - The base directory is `/dev/shm/mtls-hello-sync`.
   - The instance directory is a hash of the canonical, absolute `DATA_DIR` path (e.g., first 16 characters of `sha256sum` of the absolute path). This ensures that prod, test, and dev instances using different data directories never share state, while instances that intentionally use the same data directory share state.
   - The full path is `/dev/shm/mtls-hello-sync/<data-dir-hash>/sync-state/<peer-hostname>.txt`.
   - The directory is created on demand with `mkdir -p`.
   - If `/dev/shm` is not available or writable, the helpers fall back to empty state, causing the fallback bundling path to run.

3. **Modify `scripts/on-discover.sh`**
   - Source `scripts/sync-state.sh` after `sync-common.sh`.
   - At the start of each repo iteration, compute the current refs hash.
   - Compare with `get_synced_hash "$PEER_HOST" "$name"`. If equal, skip the repo entirely (no HEAD query, no spool query, no bundling).
   - Otherwise, proceed with the existing HEAD/spool/bundle logic.
   - After a successful `HTTP 200` push for every branch of the repo, call `set_synced_hash` for the repo.
   - On any upload failure for a branch, do not update the sync state for that repo.

4. **Edge cases**
   - **Force-push / rewrite**: The current refs hash will differ from the cached hash, so the callback will bundle and upload.
   - **New branch / tag**: The refs hash changes, so the callback will bundle and upload.
   - **Deleted repo**: The stale record remains in the peer's state file but is ignored because the repo no longer exists. A prune helper can be added later if needed.
   - **Missing `/dev/shm`**: The helpers return empty state, triggering the fallback bundling path. No errors are raised.
   - **Multiple branches pushed separately**: The current code pushes each branch separately. The refs hash represents the full repo state; after the first successful branch push, the hash is recorded and the next branches in the same run will still be pushed because the loop does not re-check the cache mid-iteration. This is acceptable because the cache is meant to skip work *across discovery runs*, not within a single run.

5. **Tests**
   - Unit tests for `compute_refs_hash` and `get_synced_hash`/`set_synced_hash` in a new `tests/sync-state.bats`.
   - BATS integration test in `tests/smoke.bats` or `tests/apache.bats` that verifies the second discovery does not upload when no refs changed.
   - Robot Framework test that adds a new repo, syncs, then rediscovers and confirms no new bundle is uploaded.

## Quickstart

See `specs/020-reduce-redundant-bundling/quickstart.md` for how to run the new tests and inspect the shared-memory cache.

## Complexity Tracking

No constitution violations. The feature introduces one small shell helper file and one shared-memory directory per instance, keeping the change local and maintaining the separation between the D daemon and git sync logic.

## Risks & Mitigations

- **Risk**: Hashing every ref on every discovery could itself be CPU-intensive if the repo has many refs.
  - **Mitigation**: The hash is computed by `git for-each-ref` and `sha256sum`, which is much cheaper than `git bundle create` and upload. If it becomes a problem, the result can be cached with file mtime checks.
- **Risk**: Recording the full refs hash after a partial upload could create inconsistent state.
  - **Mitigation**: Record the full refs hash only after the entire repo loop completes with no upload failures for that repo. If any branch fails or is skipped due to an error, do not record the state for that repo.
- **Risk**: `/dev/shm` is cleared unexpectedly.
  - **Mitigation**: Missing state triggers the fallback bundling path, which is safe.
- **Risk**: Multiple mtls-hello instances on the same host share the same shared-memory namespace.
  - **Mitigation**: The namespace is derived from a hash of the canonical, absolute `DATA_DIR` path, so different instances (prod, test, dev) are isolated. Instances that share the same data directory intentionally share state.

## Research Links

- `specs/020-reduce-redundant-bundling/research.md`
- `specs/020-reduce-redundant-bundling/data-model.md`
- `specs/020-reduce-redundant-bundling/contracts/sync-state.md`
- `specs/020-reduce-redundant-bundling/contracts/callback-env.md`
- `specs/020-reduce-redundant-bundling/quickstart.md`
