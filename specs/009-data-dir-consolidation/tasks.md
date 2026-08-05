# Tasks: Data Directory Consolidation

**Input**: Design documents from `/specs/009-data-dir-consolidation/`

**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md, contracts/

**Tests**: BATS acceptance tests for each user story.

**Organization**: Tasks grouped by user story. US1 is the core feature (data-dir derivation), US2 is install tree, US3 is systemd unit update.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

---

## Phase 1: Setup

**Purpose**: Baseline verification

- [x] T001 Verify baseline: run `just test` on branch `009-data-dir-consolidation` and confirm all 37 existing tests pass before any changes

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: ServerConfig field and CLI flag parsing — everything else depends on this

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [x] T002 Add `string dataDir = "";` field to `ServerConfig` struct in `source/app.d` with a comment: "Base directory for runtime data (handlers, scripts, future)."
- [x] T003 Add `--data-dir=PATH` flag parsing in `parseArgs()` in `source/app.d`. Support both `--data-dir=PATH` (equals form) and `--data-dir PATH` (space form, requiring a following argument). Store in `cfg.dataDir`.

**Checkpoint**: CLI flag accepted and stored. Paths not yet derived.

---

## Phase 3: User Story 1 - Single Data Directory Derives All Sub-Paths (Priority: P1) 🎯 MVP

**Goal**: When `--data-dir=PATH` is set, handler and callback paths default to sub-paths of that directory. Explicit `--handlers-dir` or `CALLBACK_SCRIPT` overrides still win.

**Independent Test**: Start server with `--data-dir=/tmp/test-data`, verify handlers load from `/tmp/test-data/handlers/` and callback defaults to `/tmp/test-data/scripts/on-discover.sh`.

### Tests for User Story 1 ⚠️

- [x] T004 [P] [US1] Add BATS test `@test "data-dir derives handlers path"` in `tests/smoke.bats` — create a handler at `<tmp>/handlers/hello.get.sh`, start server with `--data-dir=<tmp>`, curl the handler, verify response.
- [x] T005 [P] [US1] Add BATS test `@test "data-dir derives callback path"` in `tests/smoke.bats` — create `on-discover.sh` at `<tmp>/scripts/on-discover.sh`, start server with `--data-dir=<tmp>`, send UDP announcement, verify callback is spawned.
- [x] T006 [P] [US1] Add BATS test `@test "explicit --handlers-dir overrides data-dir"` in `tests/smoke.bats` — set both `--data-dir=<tmp>` and `--handlers-dir=<other>`, start server, verify handler loads from `<other>` not `<tmp>/handlers`.
- [x] T007 [P] [US1] Add BATS test `@test "no --data-dir preserves existing defaults"` in `tests/smoke.bats` — start server without `--data-dir`, verify `--handlers-dir` defaults to `"handlers"` and `CALLBACK_SCRIPT` must be set explicitly (or empty → callback disabled).

### Implementation for User Story 1

- [x] T008 [US1] In `main()` in `source/app.d`, after `parseArgs()` and env var reads, add derivation logic: if `cfg.dataDir` is non-empty, set `cfg.handlers.handlersDir = cfg.dataDir ~ "/handlers"` (unless `--handlers-dir` was explicitly set) and `cfg.multicast.callbackScript = cfg.dataDir ~ "/scripts/on-discover.sh"` (unless `CALLBACK_SCRIPT` was explicitly set). Use a `bool handlersExplicit = ...` to track whether the flag was explicitly provided.

**Checkpoint**: `--data-dir` correctly derives sub-paths; explicit overrides win; backward compat preserved.

---

## Phase 4: User Story 2 - Install Creates Complete Directory Tree (Priority: P2)

**Goal**: `just install` creates the full `~/.local/share/mtls-hello/` tree with real scripts and `.new` stub files for future extension points.

**Independent Test**: Run `just install` with temp HOME, verify tree contains `handlers/`, `scripts/on-discover.sh`, and `.new` stub files.

### Tests for User Story 2 ⚠️

- [x] T009 [US2] Update the existing BATS test `@test "US1: just install copies binary and handlers to ~/.local"` in `tests/smoke.bats` to also verify the `scripts/on-discover.sh` path (already there from feature 008) and the `.new` stub file existence.

### Implementation for User Story 2

- [x] T010 [US2] In `scripts/install.sh`, add creation of a `.new` stub file for future extension points (e.g., `touch "$HOME/.local/share/mtls-hello/scripts/pre-push.sh.new"`). Document in the post-install message that `.new` files can be copied and made executable to activate.

**Checkpoint**: Install creates self-documenting tree with real scripts and stubs.

---

## Phase 5: User Story 3 - Systemd Unit Uses Single Data Directory (Priority: P3)

**Goal**: The generated systemd unit uses `--data-dir=%h/.local/share/mtls-hello` instead of individual `--handlers-dir`.

**Independent Test**: Generate unit, verify `ExecStart` contains `--data-dir` and no `--handlers-dir`.

### Tests for User Story 3 ⚠️

- [x] T011 [US3] Update the existing BATS test `@test "US3: just install-service creates a valid systemd user unit"` in `tests/smoke.bats` to verify `--data-dir=%h/.local/share/mtls-hello` is present and `--handlers-dir` is absent from the unit file.

### Implementation for User Story 3

- [x] T012 [US3] In `scripts/install-service.sh`, replace `--handlers-dir=%h/.local/share/mtls-hello/handlers` with `--data-dir=%h/.local/share/mtls-hello` in the ExecStart line.

**Checkpoint**: Systemd unit uses single data directory flag.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Final verification and documentation

- [x] T013 Run `just test` one final time; confirm all existing 37 tests pass plus the new tests. Verify no leftover processes or temp fixtures.
- [x] T014 [P] Update `AGENTS.md` to mark feature as implemented.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies.
- **Foundational (Phase 2)**: Depends on Setup. BLOCKS all user stories.
- **US1 (Phase 3)**: Depends on Foundational. T004-T007 tests first, then T008 implementation.
- **US2 (Phase 4)**: Depends on US1 (needs data-dir flag). T009 test before T010 implementation.
- **US3 (Phase 5)**: Depends on US1 (needs data-dir flag). T011 test before T012 implementation.
- **Polish (Phase 6)**: Depends on all user stories.

### User Story Dependencies

- **US1 (P1)**: Can start after Foundational. No dependencies on other stories.
- **US2 (P2)**: Can start after US1.
- **US3 (P3)**: Can start after US1. Can run in parallel with US2.

### Parallel Opportunities

```
T004 (test: handlers) ─┐
T005 (test: callback)   ├─ US1 tests — all parallel (different fixtures)
T006 (test: override)   │
T007 (test: backward)  ─┘

US2 (install tree)  ─┐
                     ├─ Can run in parallel after US1
US3 (systemd unit)  ─┘
```

---

## Implementation Strategy

### MVP First (User Story 1)

1. Complete Phase 1: Setup (T001)
2. Complete Phase 2: Foundational (T002–T003)
3. Complete Phase 3: US1 (T004–T008) — data-dir derives paths
4. **STOP and VALIDATE**: Run `just test`, verify data-dir tests pass
5. This is the MVP — operators can use `--data-dir` for all runtime paths

### Incremental Delivery

1. Setup + Foundational → CLI flag accepted
2. Add US1 → data-dir derives handlers + callback → **MVP!**
3. Add US2 → install creates full tree → **production-ready**
4. Add US3 → systemd unit simplified → **operator UX complete**
5. Polish → final verification

---

## Notes

- [P] tasks = different files or non-overlapping code sections, no dependencies
- [Story] label maps task to specific user story for traceability
- US2 and US3 can run in parallel after US1 is complete
- Existing BATS tests that set `--handlers-dir` or `CALLBACK_SCRIPT` explicitly are unaffected (no behavior change when `--data-dir` is absent)
- The `bool handlersExplicit` variable in T008 is an implementation approach — a simpler alternative is to check if `cfg.handlers.handlersDir` differs from the default before deriving
