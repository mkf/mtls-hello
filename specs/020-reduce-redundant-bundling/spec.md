# Specification: Reduce Redundant Bundle Sync

**Feature Number**: 020
**Short Name**: reduce-redundant-bundling
**Status**: Draft
**Date**: 2026-08-06

## Problem Statement

When mtls-hello peers discover each other, the discovery callback runs `on-discover.sh`, which creates a git bundle for every repository and uploads it to the peer. If the repositories have not changed since the last sync, the bundle contents are identical and the upload is wasted work. On a LAN with frequent discovery announcements or with many peers, this creates redundant bundling and redundant uploads, keeping the CPU and network busy even when there is nothing new to share. The project needs a lean way to skip bundling and uploading when no new commits are available for a peer, while keeping the D discovery daemon separate from git-specific logic.

## User Scenarios & Testing

### Scenario 1: Repeated discovery does not rebundle unchanged repos

**Given** two peers have already synced a repository and no new commits have been made
**When** they discover each other again
**Then** the callback skips creating a bundle for that repository and skips the upload

### Scenario 2: New commits trigger normal sync

**Given** a repository has new commits since the last sync to a peer
**When** the peers discover each other
**Then** the callback creates a bundle and uploads it as usual

### Scenario 3: Multiple peers are tracked independently

**Given** a host has three peers and the repository state differs relative to each peer
**When** the callback runs for each peer
**Then** each peer gets a bundle only if there are commits it has not already received

## Functional Requirements

1. Before creating a bundle for a repository, the callback shall determine whether the repository has commits that the target peer has not already received.
2. If the set of refs to send to a peer is identical to the set sent during the last successful sync, the callback shall skip creating the bundle and uploading it for that peer.
3. The callback shall track the last successful sync state per peer per repository using a lightweight, deterministic key (peer hostname + repository name + current refs hash).
4. The tracking state shall be stored in shared memory (`/dev/shm`) and shall not be written to the persistent data directory. It is allowed to reset when the host reboots or the shared-memory segment is cleared.
5. The callback shall still generate and upload a bundle when a new commit is pushed, a new branch is created, or refs otherwise change.
6. The change shall not require a central database, coordination between peers, or changes to the D discovery daemon. Each host tracks its own view of what each peer has received.
7. The callback shall degrade gracefully: if the shared-memory state is missing or corrupted, it shall fall back to bundling and uploading (safe default).

## Success Criteria

- CPU time spent in `git bundle` commands is reduced by at least 70% for unchanged repositories across repeated discoveries within the same host uptime.
- Network bytes uploaded between already-synced peers is reduced by at least 90% when no new commits exist.
- Sync latency for a repository with new commits remains within 10% of the pre-optimization baseline.
- No repository changes are lost when the callback skips a redundant sync.
- The feature works without modifying the D discovery daemon, the git repository contents, or the spool/merge workflow.

## Key Entities / Data

- **Repository**: a bare git repository under `REPOS_ROOT`.
- **Peer**: another mtls-hello instance identified by hostname.
- **Sync state**: a record of which refs each peer has received from each repository, stored in shared memory.
- **Bundle**: the git bundle file created by `git bundle create` and uploaded via HTTP POST.
- **Data directory**: the directory where the daemon stores persistent state. The sync-state cache is not stored here.

## Scope

### In Scope

- Tracking per-peer, per-repo sync state in shared memory (`/dev/shm`).
- Skipping `git bundle create` when the peer already has the same refs.
- Skipping the HTTP POST upload when the bundle is skipped.
- Updating `scripts/sync-common.sh` or `scripts/on-discover.sh` to implement the check.
- Unit tests for the ref-comparison logic and integration tests for the skip path.

### Out of Scope

- Compressing or splitting bundles.
- Changing the spool/merge workflow on the receiver.
- Implementing a centralized sync state database.
- Modifying the D discovery daemon, the multicast discovery interval, or the capture worker.
- Synchronizing working-tree repositories (only bare repos are supported).

## Assumptions

- The git repositories are bare and refs are the authoritative source of state.
- Each peer has a stable hostname that identifies it across discovery events.
- The callback is invoked with `PEER_NETLOC`, `HOST_NAME`, `PEER_HOST`, and `DATA_DIR` available in the environment.
- `/dev/shm` is available and writable as a tmpfs on the target platform.
- The shared-memory state is allowed to reset on reboot; the first sync after reboot may be redundant but correct.
- Different mtls-hello instances using different data directories must not share the same sync-state namespace, even on the same host.

## Dependencies

- Existing `scripts/on-discover.sh` and `scripts/sync-common.sh`.
- Existing `REPOS_ROOT` and `DATA_DIR` handling.
- Existing bundle POST handling in `handlers/bundle.post.sh`.
- Existing spool/merge workflow in `scripts/merge-spool.sh`.
- Existing D discovery daemon in `source/app.d` and `source/multicast.d` (unchanged).

## Risks & Mitigations

- **Risk**: A stale shared-memory state file prevents a peer from receiving new commits after a force-push or rewrite.
  - **Mitigation**: Detect ref mismatches or missing refs and fall back to bundling; track the current refs hash, not just a boolean.
- **Risk**: Two mtls-hello instances on the same host share `/dev/shm` and collide.
  - **Mitigation**: Namespace the shared-memory directory by a hash of the absolute data directory path so each instance has its own segment. Instances that share the same data directory intentionally share state because they are the same logical instance.
- **Risk**: The shared-memory state is cleared unexpectedly (e.g., by a `tmpfiles` cleanup).
  - **Mitigation**: Missing state triggers the fallback bundling path, which is safe.
- **Risk**: `/dev/shm` is not available on some target platform.
  - **Mitigation**: The feature degrades to the existing behavior if the shared-memory directory cannot be created; no state is recorded but bundling still works.

## Notes

- The intended solution is a shared-memory file that records "peer X has already seen refs hash Y for repo Z". The next time the callback runs, it compares the current refs to the recorded refs and skips the bundle if they match.
- This is purely an optimization in the sender callback path; the receiver's spool/merge behavior and the D discovery daemon remain unchanged.
- No disk writes are performed for sync state.
