# Tasks: Wire Discovery Callback

**Input**: Design documents from `/specs/008-wire-discovery-callback/`

**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md, contracts/

**Tests**: Included — acceptance scenarios require automated BATS verification.

**Organization**: Tasks are grouped by user story. US2 (hostname announcement) is ordered before US1 (callback execution) because the callback needs the peer's hostname from the announcement.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Baseline verification

- [ ] T001 Verify baseline: run `just test` on branch `008-wire-discovery-callback` and confirm all 31 existing tests pass before any changes

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Config fields that both US1 and US2 depend on

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [x] T002 Add `hostName`, `trustDir`, and `callbackScript` fields to `MulticastConfig` struct in `source/multicast.d`. Default `hostName` to `"localhost"`, `trustDir` to empty string, `callbackScript` to `"scripts/on-discover.sh"`. Update the struct doc comment.
- [x] T003 In `source/app.d`, read `HOST_NAME` and `CALLBACK_SCRIPT` from `std.process.environment` (defaults `"localhost"` and `"scripts/on-discover.sh"`), store in `cfg.multicast.hostName` and `cfg.multicast.callbackScript`. Set `cfg.multicast.trustDir` from `cfg.trust.trustDir`. Pass all to `startMulticastDiscovery`. Add `import std.process : environment;`.

**Checkpoint**: Config ready — multicast config has hostname and trust-dir paths.

---

## Phase 3: User Story 2 - Hostname Announced in Multicast (Priority: P2)

**Goal**: The multicast announcement JSON includes a `host` field with the server's hostname, so peers can look up the sender's certificate.

**Independent Test**: Capture a multicast announcement packet (or inspect the send buffer in a BATS test), verify it contains `"host":"<value>"`.

### Tests for User Story 2 ⚠️

- [x] T004 [US2] Add BATS test `@test "multicast announcement includes host field"` in `tests/smoke.bats` — start server with `HOST_NAME=testme`, use `nc -ul <port>` or check the server's own log (which prints the announcement in debug mode) to verify the sent JSON contains `"host":"testme"`. Alternative: test the `announceMessage` function by checking its output if exposed.
- [x] T005 [US2] Add BATS test `@test "multicast announcement host defaults to localhost"` in `tests/smoke.bats` — start server without `HOST_NAME` set, verify announcement contains `"host":"localhost"`.

### Implementation for User Story 2

- [x] T006 [US2] Modify `announceMessage` in `source/multicast.d` to include `"host": JSONValue(cfg.hostName)` in the JSON output. Use `cfg` parameter (already available in the worker).

**Checkpoint**: Announcements include hostname. Peers can see who sent each announcement.

---

## Phase 4: User Story 1 - Discovered Peer Triggers Sync (Priority: P1) 🎯 MVP

**Goal**: When a peer announcement is received, the multicast worker spawns `scripts/on-discover.sh` with the correct environment variables.

**Independent Test**: Simulate a peer announcement by sending a raw UDP packet to the multicast port, verify the server spawns the callback (check server log or side-effect).

### Tests for User Story 1 ⚠️

- [x] T007 [US1] Add BATS test `@test "discovered peer triggers on-discover callback"` in `tests/smoke.bats` — start server with `HOST_NAME=local`, `OUR_CERT=certs/certs/client.crt`, `OUR_KEY=certs/private/client.key`, `REPOS_ROOT=tmpdir`. Send a simulated announcement via UDP: `echo '{"service":"mtls-hello","port":12345,"host":"peer"}' | nc -u -w0 127.0.0.1 4242`. Check the server log for the spawn attempt (it may fail because no repo exists, but the spawn itself should be logged or produce output). Verify the callback was spawned (check `[discovery]` log line is followed by callback output).
- [x] T008 [US1] Add BATS test `@test "own announcement does not trigger callback"` in `tests/smoke.bats` — start server on port N, verify that an announcement with port N from 127.0.0.1 does NOT spawn a callback (self-ignore logic).

### Implementation for User Story 1

- [x] T009 [US1] Add `import std.process : spawnProcess, Config;` and `import std.format : format;` to `source/multicast.d`.
- [x] T010 [US1] In `processAnnouncement` in `source/multicast.d`, after the `writefln("[discovery] ...")` line, construct the callback environment AA (`HOST_NAME`, `PEER_NETLOC`, `PEER_CERT_FILE`, `OUR_CERT`, `OUR_KEY`, `REPOS_ROOT`) and spawn `bash` with `cfg.callbackScript` via `spawnProcess`. Wrap in try/catch; on `ProcessException`, log a warning and continue.
- [x] T011 [US1] Read `OUR_CERT`, `OUR_KEY`, and `REPOS_ROOT` from `std.process.environment` in the multicast worker. These are passed through as-is to the callback env. Empty strings are acceptable (the callback script will fail with `${VAR?}` and that's fine).
- [x] T012 [US1] Modify `scripts/install.sh` to copy `scripts/on-discover.sh` to `~/.local/share/mtls-hello/scripts/on-discover.sh` (create directory if needed). The script is installed alongside the binary so the production service can use it. Update the post-install message to mention `CALLBACK_SCRIPT`.

**Checkpoint**: Discovered peers trigger a sync callback. The core gap from feature 002 is closed.

---

## Phase 5: User Story 3 - Non-Blocking Callback Execution (Priority: P3)

**Goal**: Callback execution is fire-and-forget; the multicast loop is not blocked.

**Independent Test**: Verify that `spawnProcess` is used (not `execute`/`executeShell`), and that the discovery loop continues after spawning a callback.

### Tests for User Story 3 ⚠️

- [x] T013 [US3] Add BATS test `@test "callback spawn is non-blocking"` in `tests/smoke.bats` — start server, send two simulated announcements in quick succession (e.g., within 1 second). Verify both callbacks are spawned (two log entries) and the discovery loop did not stall.

### Implementation for User Story 3

- [x] T014 [US3] Code review: confirm `spawnProcess` is used without `wait()` or `pid.wait()` calls in `source/multicast.d`. No code changes expected beyond what was already done in T010 — this is a verification task.

**Checkpoint**: All three user stories independently functional.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Documentation, final verification

- [x] T015 [P] Update the header comment in `source/app.d` to document the `HOST_NAME` environment variable (used for multicast announcements and callback identity).
- [x] T016 Run `just test` one final time; confirm all tests pass (existing 31 + new). Verify no leftover `mtls-hello` processes or `/tmp/mtls-*` fixtures. Confirm `git status` shows only intended changes: `source/multicast.d` (modified), `source/app.d` (modified), `tests/smoke.bats` (modified), plus spec docs under `specs/008-wire-discovery-callback/`.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — baseline first.
- **Foundational (Phase 2)**: Depends on Setup. BLOCKS all user stories. T002, T003 can run in parallel (different files).
- **US2 (Phase 3)**: Depends on Foundational. Tests T004, T005 before implementation T006.
- **US1 (Phase 4)**: Depends on US2 (needs hostname in announcement to construct cert path). Tests T007, T008 before implementation T009-T011.
- **US3 (Phase 5)**: Depends on US1 (needs spawnProcess already in place). T012 is a test, T013 is a review task.
- **Polish (Phase 6)**: Depends on all user stories.

### User Story Dependencies

- **User Story 2 (P2)**: Can start after Foundational. No dependencies on other stories.
- **User Story 1 (P1)**: Depends on US2 (needs `host` field from announcements to construct `PEER_CERT_FILE`).
- **User Story 3 (P3)**: Depends on US1 (verifies spawnProcess behavior).

### Within Each User Story

- Tests written FIRST and verified to FAIL before implementation
- Implementation followed by verification

### Parallel Opportunities

```
T002 (MulticastConfig) ─┐─ Phase 2 parallel (different files)
T003 (app.d env read)   ─┘

T004 (test: host field)  ─┐─ US2 tests parallel
T005 (test: default host) ─┘

T007 (test: callback spawn)    ─┐─ US1 tests parallel
T008 (test: self-ignore)       ─┘

T009 (import std.process)  ─┐
T010 (spawn callback)      ─┤─ US1 impl sequential (same function)
T011 (read env vars)       ─┘
```

---

## Implementation Strategy

### MVP First (User Story 2 + 1)

1. Complete Phase 1: Setup (T001)
2. Complete Phase 2: Foundational (T002–T003)
3. Complete Phase 3: User Story 2 (T004–T006) — hostname in announcements
4. Complete Phase 4: User Story 1 (T007–T011) — callback spawn
5. **STOP and VALIDATE**: Run `just test`, verify callback spawn test passes
6. This is the MVP — discovered peers trigger sync

### Incremental Delivery

1. Setup + Foundational → config ready
2. Add US2 (hostname announcement) → test: announcement contains hostname
3. Add US1 (callback execution) → test: discovered peer triggers sync → **MVP!**
4. Add US3 (non-blocking) → test: multiple callbacks don't block
5. Polish → final verification

---

## Notes

- [P] tasks = different files or non-overlapping code sections, no dependencies
- [Story] label maps task to specific user story for traceability
- US2 is P2 but implemented before US1 because US1 needs the hostname field
- Tests for US1/2 simulate discovery via UDP packets using `nc` (netcat)
- The `systemd-analyze` from feature 007 is not affected
- Commit after each phase or logical group
