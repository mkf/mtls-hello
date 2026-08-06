# Tasks: Reduce Redundant Bundle Sync

**Input**: Design documents from `specs/020-reduce-redundant-bundling/`

**Prerequisites**: `plan.md`, `spec.md`, `research.md`, `data-model.md`, `contracts/`, `quickstart.md`

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete tasks)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Create the helper file and test harness that all user stories depend on.

- [x] T001 [P] Create `scripts/sync-state.sh` with a header comment and `set -euo pipefail` and a stub for `compute_refs_hash`.
- [x] T002 [P] Create `tests/sync-state.bats` with a `setup` function that creates a temporary bare git repo and a `teardown` function that removes it.
- [ ] T003 [P] Create `tests/robot/redundant-sync.robot` (or add a new test case to `robot/mtls_hello.robot`) to cover the redundant skip behavior end-to-end.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core helper functions that MUST be complete before any user story can be fully implemented.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [x] T004 [P] Implement `compute_refs_hash(repo_dir)` in `scripts/sync-state.sh` using `git for-each-ref --format='%(objectname) %(refname)' refs/heads refs/tags | sort | sha256sum` and extract the 64-character hex digest.
- [x] T005 [P] Implement `sync_state_dir()` and `sync_state_file_for_peer(hostname)` in `scripts/sync-state.sh` using the canonical absolute `DATA_DIR` path and `/dev/shm/mtls-hello-sync/<data-dir-hash>/sync-state`.
- [x] T006 [P] Implement `get_synced_hash(hostname, repo_name)`, `set_synced_hash(hostname, repo_name, refs_hash)`, and `clear_synced_hash(hostname, repo_name)` in `scripts/sync-state.sh` with atomic writes to `/dev/shm`.
- [x] T007 Add D/BATS unit tests in `tests/sync-state.bats` for `compute_refs_hash`, `get_synced_hash`, and `set_synced_hash`.

**Checkpoint**: `scripts/sync-state.sh` is fully implemented and unit-tested; `tests/sync-state.bats` passes.

---

## Phase 3: User Story 1 — Repeated discovery does not rebundle unchanged repos (Priority: P1) 🎯 MVP

**Goal**: When a repo's refs have not changed since the last successful sync to a peer, the callback skips the HEAD query, spool query, bundle creation, and upload for that repo.

**Independent Test**: Run `tests/sync-state.bats` and `tests/smoke.bats` (or `tests/apache.bats`) to verify that the second discovery of the same peer does not create a bundle when no new commits exist.

### Tests for User Story 1

- [ ] T008 [P] [US1] Add BATS unit test in `tests/sync-state.bats` that verifies `get_synced_hash` returns the previously recorded hash after `set_synced_hash`.
- [ ] T009 [P] [US1] Add BATS integration test in `tests/smoke.bats` that runs two discoveries and asserts the second one does not create a bundle for an unchanged repo.
- [ ] T010 [P] [US1] Add Robot test in `robot/mtls_hello.robot` that syncs a repo, rediscovers the peer, and verifies no new bundle is uploaded.

### Implementation for User Story 1

- [x] T011 [US1] Source `scripts/sync-state.sh` in `scripts/on-discover.sh` after `scripts/sync-common.sh`.
- [x] T012 [US1] At the start of each repo iteration in `scripts/on-discover.sh`, compute the current refs hash and call `get_synced_hash "$PEER_HOST" "$name"`; if equal, print a skip message and continue to the next repo.
- [x] T013 [US1] After the branch loop in `scripts/on-discover.sh` completes with no upload failures for a repo, call `set_synced_hash "$PEER_HOST" "$name" "$current_hash"`.
- [x] T014 [US1] Ensure that if any branch upload fails for a repo, `set_synced_hash` is not called for that repo.
- [x] T015 [US1] Update `specs/020-reduce-redundant-bundling/quickstart.md` with the exact skip message and log inspection steps.

**Checkpoint**: User Story 1 is fully functional and testable independently. `tests/sync-state.bats` passes, the redundant-skip BATS test passes, and the Robot test passes.

---

## Phase 4: User Story 2 — New commits trigger normal sync (Priority: P2)

**Goal**: When a repo gains new commits, branches, or tags, the hash changes and the callback performs a normal bundle and upload.

**Independent Test**: Run `tests/smoke.bats` or `robot/mtls_hello.robot` to verify that after pushing a new commit, the next discovery uploads a bundle.

### Tests for User Story 2

- [ ] T016 [P] [US2] Add BATS unit test in `tests/sync-state.bats` that verifies `compute_refs_hash` returns a different value after a new commit is added to the repo.
- [ ] T017 [P] [US2] Add BATS integration test in `tests/smoke.bats` (or `tests/apache.bats`) that pushes a new commit and asserts the next discovery creates a bundle.
- [ ] T018 [P] [US2] Add Robot test in `robot/mtls_hello.robot` that pushes a new commit and verifies the bundle is uploaded.

### Implementation for User Story 2

- [x] T019 [US2] Verify that `compute_refs_hash` in `scripts/sync-state.sh` correctly includes both `refs/heads/*` and `refs/tags/*` so new branches and tags change the hash.
- [x] T020 [US2] Verify that `set_synced_hash` in `scripts/on-discover.sh` is called after the new-commit bundle is uploaded successfully, so the next discovery skips the now-current refs.
- [x] T021 [US2] Confirm that a force-push (rewriting history) changes the refs hash and triggers a normal sync.

**Checkpoint**: User Story 2 works independently. New commits/branches/tags cause a sync; unchanged repos continue to skip.

---

## Phase 5: User Story 3 — Multiple peers are tracked independently (Priority: P3)

**Goal**: The sync-state cache is keyed by peer hostname, so each peer has its own view of which repos it has received.

**Independent Test**: Run `tests/smoke.bats` or `robot/mtls_hello.robot` with two peers to verify that syncing to one peer does not cause the other peer's repos to be skipped.

### Tests for User Story 3

- [ ] T022 [P] [US3] Add BATS unit test in `tests/sync-state.bats` that records a hash for `peer1` and confirms `get_synced_hash` for `peer2` returns empty for the same repo.
- [ ] T023 [P] [US3] Add BATS integration test in `tests/smoke.bats` that discovers two peers and verifies each gets a bundle independently.
- [ ] T024 [P] [US3] Add Robot test in `robot/mtls_hello.robot` with two trusted peers to verify per-peer sync-state isolation.

### Implementation for User Story 3

- [x] T025 [US3] Verify that `sync_state_file_for_peer(hostname)` in `scripts/sync-state.sh` uses `PEER_HOST` (derived from the peer certificate CN) as the filename.
- [x] T026 [US3] Verify that `set_synced_hash` and `get_synced_hash` in `scripts/on-discover.sh` are called with `"$PEER_HOST"` and not with `HOST_NAME` or `PEER_NETLOC`.
- [x] T027 [US3] Confirm that two different peers produce two different shared-memory files in `/dev/shm/mtls-hello-sync/<data-dir-hash>/sync-state/`.

**Checkpoint**: User Story 3 works independently. Each peer has its own sync-state file; syncing to one does not affect the other.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Final validation, documentation, and cleanup.

- [x] T028 [P] Run `shellcheck` on `scripts/sync-state.sh` and `scripts/on-discover.sh` and fix any warnings.
- [x] T029 [P] Run `bats tests/sync-state.bats` and any new BATS integration tests.
- [x] T030 [P] Run `just robot` to verify the Robot Framework suite still passes.
- [x] T031 [P] Run `just test-d` to verify the D unit tests still pass (no D daemon changes).
- [x] T032 Update `specs/020-reduce-redundant-bundling/tasks.md` to mark completed tasks once implementation is finished.
- [x] T033 Verify `AGENTS.md` still points to `specs/020-reduce-redundant-bundling/plan.md`.
- [x] T034 Verify no concrete time-of-day examples exist in the feature documentation.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies.
- **Foundational (Phase 2)**: Depends on Setup. Blocks all user stories.
- **User Stories (Phase 3–5)**: All depend on Foundational phase. Can proceed in parallel or sequentially by priority (P1 → P2 → P3).
- **Polish (Phase 6)**: Depends on all user stories being complete.

### User Story Dependencies

- **User Story 1 (P1)**: Can start after Foundational. No dependencies on other stories.
- **User Story 2 (P2)**: Can start after Foundational and ideally after US1. Independently testable.
- **User Story 3 (P3)**: Can start after Foundational. Independently testable.

### Within Each User Story

- Tests are written before implementation (TDD where possible).
- Helper functions (`scripts/sync-state.sh`) are already complete from the Foundational phase.
- `scripts/on-discover.sh` changes per story are small and incremental.
- Each story is independently testable before moving to the next.

### Parallel Opportunities

- All Phase 1 tasks can run in parallel.
- All Phase 2 tasks can run in parallel (except T007, which depends on T004–T006).
- Once Phase 2 is complete, all three user stories can be worked on in parallel by different developers.
- Tests within each story can be written in parallel.
- Polish phase tasks can run in parallel after the user stories are complete.

---

## Implementation Strategy

1. **MVP first**: Complete US1 (skip unchanged repos on repeated discovery). This delivers the core CPU and bandwidth savings immediately.
2. **Incremental delivery**: After US1, add US2 (new commits still sync) to ensure correctness, then US3 (per-peer isolation) for multi-peer robustness.
3. **Test-driven**: Write the BATS unit tests for `scripts/sync-state.sh` first, then the integration tests, then implement the callback changes.
4. **No D daemon changes**: Keep all changes in shell scripts. The existing D daemon is not modified.
5. **Shared memory**: Use `/dev/shm/mtls-hello-sync/<data-dir-hash>/sync-state/` for the cache, with the data-dir hash computed from the canonical absolute path.
