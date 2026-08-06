# Research: Reduce Redundant Bundle Sync

**Date**: 2026-08-06
**Feature**: specs/020-reduce-redundant-bundling/spec.md

## Questions to Resolve

1. How should the callback detect that a peer already has the same refs without issuing a network request and without involving the D discovery daemon in git-specific logic?
2. What is the cheapest way to represent the current refs of a bare repository as a deterministic hash?
3. Where should the sync-state cache live if it is not persisted to disk but also not inside the D daemon?
4. When should the cache be updated, and how should it be invalidated?

## Findings

### 1. Detecting unchanged state without a network request or D daemon changes

The existing callback already uses two network checks per repo:

- `mtls_curl "/head?repo=${name}"` to compare the peer's HEAD with our HEAD.
- `mtls_curl "/spool?repo=${name}"` to query already-spooled ranges.

Both are HTTP round-trips and are therefore wasteful when our local refs have not changed since the last successful sync. The user wants to avoid using the D discovery daemon for git domain logic, so the optimization must be implemented in the shell callback path.

**Decision**: Implement the cache entirely in shell scripts. The callback reads and writes a lightweight state file in shared memory. The D daemon is not modified and remains unaware of git repositories.

### 2. Cheapest deterministic refs hash

The bare repo is the authoritative source. The hash must capture all refs that would be sent, including branches and tags.

Options considered:

- **Option A**: `git rev-parse HEAD` only. Cheap but misses branches and tags, so it is insufficient.
- **Option B**: `git show-ref --head --dereference | sort | sha256sum`. Lists all refs and their SHAs, deterministic, and is cheap for repos with a reasonable number of refs.
- **Option C**: `git bundle create /dev/null refs/heads/* refs/tags/*` and hash the bundle. Accurate but expensive; defeats the purpose of avoiding bundle creation.
- **Option D**: Use the commit-graph or `git rev-list --all --count`. Not deterministic across force-pushes or rewrites.

**Decision**: Use Option B. The helper runs `git -C "$repo_dir" for-each-ref --format='%(objectname) %(refname)' refs/heads refs/tags | sort | sha256sum` and extracts the hex digest. This is O(refs) and much cheaper than `git bundle create`.

### 3. Cache location and lifetime

Requirements:

- Not persisted to the data directory.
- Not inside the D daemon.
- No new process required.
- Survives multiple invocations of the callback within the same host uptime.

Options considered:

- **Shared memory (`/dev/shm`)**: A tmpfs backed by RAM, not persistent disk, writable by the callback, and survives until reboot. No new daemon needed. Different mtls-hello instances can be namespaced by data directory.
- **In-memory map in the D daemon**: Violates the separation-of-concerns requirement; the D daemon should not know about git repos.
- **New in-memory helper daemon**: Violates the "no new daemon" constraint.
- **On-disk state file in the data directory**: Violates the explicit "no on-disk" constraint.

**Decision**: Use `/dev/shm/mtls-hello-sync/<data-dir-hash>/sync-state/<peer-hostname>.txt`. The data-dir hash is computed from the canonical, absolute `DATA_DIR` path, ensuring that separate instances (prod, test, dev) using different data directories never collide. Instances that intentionally use the same data directory share state. The state resets on reboot, which is acceptable.

### 4. Update and invalidation strategy

The cache must be invalidated whenever our local refs change. Because the hash is computed from the actual refs, any push, branch creation, tag, or force-push automatically changes the hash, so the cache self-invalidates.

The cache is updated only after a successful bundle upload. If a branch upload fails, the cache is not updated for that repo, so the next discovery will retry.

**Decision**: Record the full refs hash for a repo only after the entire repo iteration succeeds with no upload failures. If any branch fails to upload, do not record the state for that repo.

## Risks

- **Force-push**: A force-push changes the refs hash, so the next discovery will bundle and upload. The cache is safe.
- **Reboot**: The cache is lost, causing a full sync on the first discovery after boot. This is acceptable by design.
- **Callback failure**: If a branch upload fails, the cache is not updated for that repo, so the next discovery will retry.
- **Tag-only changes**: The refs hash includes tags, so a new tag triggers a sync.
- **Instance collision**: Multiple mtls-hello instances using the same data-dir hash could share state incorrectly. Mitigated by using the actual data-dir path hash.

## Alternatives Rejected

- **Central database**: Violates the "no central coordination" constraint.
- **On-disk state file**: Violates the explicit "no on-disk" constraint.
- **In-memory state in the D daemon**: Violates separation of concerns; the D daemon should not manage git-specific state.
- **Bundle content hash**: Requires creating the bundle first, which defeats the optimization goal.
- **File-system mtime of the repo**: Unreliable for bare repos and does not capture ref changes.
- **Relying solely on HEAD**: Does not capture branches and tags.
