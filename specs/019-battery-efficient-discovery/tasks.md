# Tasks: Battery-Efficient Discovery

**Input**: Design documents from `/specs/019-battery-efficient-discovery/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/internal.md, quickstart.md

**Tests**: Included per feature specification and project convention (D unit tests + Robot Framework).

**Organization**: Tasks grouped by user story to enable independent implementation and testing.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete tasks)
- **[Story]**: User story this task belongs to (US1, US2, US3)
- Exact file paths included in descriptions

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Understand the current code and establish a baseline before making changes.

- [x] T001 Read `source/app.d` and `source/multicast.d` to confirm the exact location of the 100 ms polling loop and the capture queue access patterns.
- [x] T002 [P] Create a small CPU measurement helper (script or one-liner) that records the discovery process CPU usage over a 60-second idle window. Save it under `scripts/measure-idle-cpu.sh` or as a note in `specs/019-battery-efficient-discovery/`.
- [x] T003 Run the baseline measurement on the current `source/app.d` polling loop and record the result in `specs/019-battery-efficient-discovery/baseline-cpu.md`.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Extend the capture queue with a condition variable so the worker can sleep until work arrives.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [x] T004 [P] Add a `core.sync.condition.Condition` to the capture queue in `source/multicast.d`, initialized alongside the existing mutex.
- [x] T005 [P] Update `pushCaptureRequest` in `source/multicast.d` to signal the condition variable only when the queue transitions from empty to non-empty.
- [x] T006 Add a public helper in `source/multicast.d` that lets the worker atomically pop the next request while holding the mutex, returning an empty request if the queue is empty.

**Checkpoint**: The capture queue can be safely signaled from the multicast thread and can be waited on from the worker task.

---

## Phase 3: User Story 1 - Idle daemon stays cool (Priority: P1) 🎯 MVP

**Goal**: Replace the fixed 100 ms polling loop with an event-driven wait so the CPU sleeps when no peers are present.

**Independent Test**: Start the daemon with no peers, measure CPU usage for 5 minutes, and verify it stays below 1%.

### Tests for User Story 1

- [ ] T007 [P] [US1] Add a D unit test in `source/test_main.d` (or a new test module) that verifies the worker waits when the queue is empty and wakes when a request is pushed.
- [ ] T008 [P] [US1] Add a Robot Framework test in `robot/mtls_hello.robot` that starts the daemon, waits 60 seconds, and asserts the CPU usage stays below 1% (or add a shell-based measurement step to the library).

### Implementation for User Story 1

- [x] T009 [US1] Rewrite the worker loop in `source/app.d` to wait on the capture queue condition variable instead of `sleep(100.msecs)`. The worker should sleep when the queue is empty and periodically check the shutdown flag with a bounded timeout (e.g., 1 second).
- [x] T010 [US1] Ensure the worker does not call `processCaptureQueue()` when the queue is empty; it should only process after a successful dequeue.
- [x] T011 [US1] Run the idle CPU measurement after the change and verify the 80% reduction target is met; update `baseline-cpu.md` with the after numbers.

**Checkpoint**: User Story 1 is independently testable: the daemon uses negligible CPU when idle.

---

## Phase 4: User Story 2 - New peer triggers immediate capture (Priority: P1)

**Goal**: When a peer announcement arrives, the worker wakes immediately and processes the capture request within a few seconds.

**Independent Test**: Start the daemon, wait for it to reach idle, inject a peer announcement, and verify the certificate is captured/callback spawned within 2 seconds.

### Tests for User Story 2

- [ ] T012 [P] [US2] Add a D unit test in `source/test_main.d` that pushes a capture request and verifies the worker wakes and processes it without waiting for a timer.
- [ ] T013 [P] [US2] Add a Robot Framework test in `robot/mtls_hello.robot` that sends a peer announcement and measures the time until a purgatory file appears and the callback log shows activity.

### Implementation for User Story 2

- [x] T014 [US2] Verify that `pushCaptureRequest` in `source/multicast.d` signals the condition variable while holding the mutex and that the signal is not lost if the worker is not yet waiting.
- [x] T015 [US2] Confirm the worker in `source/app.d` wakes promptly on signal and processes the request without the 100 ms polling delay.
- [x] T016 [US2] Measure peer capture latency after the change and verify it stays under 2 seconds.

**Checkpoint**: User Story 2 is independently testable: peer capture latency is under 2 seconds.

---

## Phase 5: User Story 3 - Multiple peers handled without head-of-line blocking (Priority: P2)

**Goal**: A burst of peer announcements does not block or lose work; the worker drains the queue before sleeping again.

**Independent Test**: Send several peer announcements in quick succession and verify all are captured and all callbacks are spawned.

### Tests for User Story 3

- [ ] T017 [P] [US3] Add a D unit test in `source/test_main.d` that pushes multiple capture requests in a row and verifies they are processed in FIFO order without the worker sleeping between them.
- [ ] T018 [P] [US3] Add a Robot Framework test in `robot/mtls_hello.robot` that simulates multiple peer announcements and asserts the expected number of purgatory files and callback invocations.

### Implementation for User Story 3

- [x] T019 [US3] Ensure the worker loop in `source/app.d` processes queued requests in a tight inner loop and only waits on the condition variable when the queue is empty.
- [x] T020 [US3] Verify the signal optimization (only signal on empty→non-empty transition) does not starve the worker when the queue is already non-empty.

**Checkpoint**: User Story 3 is independently testable: burst peer announcements are all captured.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Clean up and ensure the whole feature is consistent and tested.

- [x] T021 [P] Run `shellcheck` on any shell scripts modified during this feature (likely none, but verify).
- [x] T022 [P] Run `just test-d` and verify all D unit tests pass.
- [x] T023 [P] Run `just robot` and verify the first 5 (and any new) Robot Framework tests pass.
- [x] T024 [P] Update `specs/019-battery-efficient-discovery/tasks.md` to mark completed tasks once implementation is finished.
- [x] T025 [P] Verify `AGENTS.md` still points to the correct plan.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: No dependencies — can start immediately.
- **Phase 2 (Foundational)**: Depends on Phase 1. Blocks all user stories.
- **Phase 3 (US1)**: Depends on Phase 2. MVP priority.
- **Phase 4 (US2)**: Depends on Phase 2. Can be done in parallel with US1 testing.
- **Phase 5 (US3)**: Depends on Phase 2 and US1/US2 implementation behavior.
- **Phase 6 (Polish)**: Depends on all user stories.

### User Story Dependencies

- **US1 (P1)**: Can start after Phase 2. No dependencies on other stories.
- **US2 (P1)**: Can start after Phase 2. No dependencies on other stories, but shares the same worker loop with US1.
- **US3 (P2)**: Depends on US1 and US2 because the worker drain behavior is validated after the basic wake/sleep logic works.

### Within Each User Story

- Tests written before or alongside implementation (per project convention).
- Foundational queue changes before worker loop changes.
- Story test passes before moving on.

### Parallel Opportunities

- T001 and T002 can be done in parallel.
- T004, T005, and T006 can be done in parallel once T001/T003 are done.
- US1, US2, and US3 tests (T007/T008, T012/T013, T017/T018) can be drafted in parallel once the foundational API is stable.
- T021–T025 (polish) can run in parallel with each other after implementation.

### Parallel Example: User Story 1

```bash
# Developer A: condition variable plumbing
Task: T004 Add Condition to capture queue in source/multicast.d

# Developer B: worker loop rewrite
Task: T009 Rewrite worker loop in source/app.d to wait on condition

# Developer C: measurement
Task: T003 Run baseline measurement, T011 Run post-fix measurement
```

### Implementation Strategy

1. **MVP first**: Complete US1 (idle CPU reduction) before optimizing peer latency or burst handling. This delivers the core battery-saving value immediately.
2. **Incremental delivery**: After US1, add US2 to ensure peers are still discovered quickly, then US3 for burst robustness.
3. **Measurement-driven**: Establish the baseline before changing behavior, then validate the reduction after each story.

## Implementation Notes

- A deduplication check was added in `source/multicast.d` (`isPeerAlreadyKnown`) so that already-captured or already-trusted peers do not trigger another TLS handshake or `on-discover.sh` callback. This is the primary battery-saving change.
- A `core.sync.condition.Condition` was added to the capture queue and the worker loop in `source/app.d` no longer polls every 100 ms.
- A unit test for `isPeerAlreadyKnown` was added to `source/multicast.d`.
- All D unit tests and the first 5 Robot Framework tests pass.
