# Tasks: Production-Ready Install & Systemd Service

**Input**: Design documents from `/specs/007-production-install-systemd/`

**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md, contracts/

**Tests**: Included — each user story has acceptance scenarios requiring automated BATS verification.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Baseline verification and build infrastructure for version injection

- [x] T001 Verify baseline: run `just test` on branch `007-production-install-systemd` and confirm all 23 existing tests pass before any changes
- [x] T002 [P] Add version string constant to `dub.json` — ensure `"version"` field is present (current value: check file, use `0.1.0` if missing)
- [x] T003 [P] Inject version constant into D build — write a `source/version_.d` file with `module version_; enum appVersion = "...";` populated from `dub.json` version, or embed via D compile-time string import. The build step in `justfile` must regenerate this file before compilation.

**Checkpoint**: Baseline passing, version ready for `--version` flag.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core CLI additions that ALL user stories depend on (version flag and port infrastructure)

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [x] T004 Add `--version` flag to `source/app.d` — parse early in argument handling (before any server setup). When `--version` is given, print the version string from `source/version_.d` to stdout and exit 0. Update the header comment in `source/app.d` to document the new flag.
- [x] T005 [P] Add `--port-file=PATH` argument parsing to `source/app.d` — accept both `--port-file PATH` and `--port-file=PATH` forms. Store in `ServerConfig` struct. Add to header comment.
- [x] T006 Add `port=0` (random) support to `source/app.d` — when port is 0: pre-bind a `std.socket.TcpSocket` to port 0 on `::1`, read OS-assigned port via `socket.localAddress`, close socket, use assigned port. Reject invalid port values (<0 or >65535). Update header comment.

**Checkpoint**: Server has `--version`, random port, and `--port-file` parsing — all user stories can now build on this.

---

## Phase 3: User Story 1 - `just install` to ~/.local (Priority: P1) 🎯 MVP

**Goal**: Operator can install the binary and handlers to `~/.local` with a single command.

**Independent Test**: Run `just install` in a clean checkout, verify `~/.local/bin/mtls-hello` is executable, `~/.local/share/mtls-hello/handlers/` contains the handler scripts, and `~/.local/bin/mtls-hello --version` prints the version.

### Tests for User Story 1 ⚠️

> **NOTE: Write these tests FIRST; they must FAIL until US1 implementation is complete, then PASS.**

- [x] T007 [P] [US1] Add BATS test `@test "just install copies binary and handlers to ~/.local"` in `tests/smoke.bats` — set `HOME` to a temp directory, run `just install`, assert `$HOME/.local/bin/mtls-hello` exists and is executable, assert `$HOME/.local/share/mtls-hello/handlers/bundle.post.sh` exists, assert `$HOME/.local/bin/mtls-hello --version` prints a non-empty version string.
- [x] T008 [P] [US1] Add BATS test `@test "just install is idempotent"` in `tests/smoke.bats` — run `just install` twice with a temp `HOME`, assert second run exits 0, assert binary and handlers still present with correct content.
- [x] T009 [P] [US1] Add BATS test `@test "just install creates missing ~/.local directories"` in `tests/smoke.bats` — with no `~/.local` pre-existing, run `just install`, assert directories were created automatically.

### Implementation for User Story 1

- [x] T010 [US1] Create `scripts/install.sh` — shell script that:
  - Checks that `./mtls-hello` binary exists (exit 1 if not)
  - Creates `~/.local/bin/` with `mkdir -p`
  - Copies `./mtls-hello` to `~/.local/bin/mtls-hello` using `install -D -m 755`
  - Creates `~/.local/share/mtls-hello/` with `mkdir -p`
  - Removes old `~/.local/share/mtls-hello/handlers/` if it exists (to avoid stale files)
  - Copies `handlers/` recursively to `~/.local/share/mtls-hello/handlers/` with `cp -r`
  - Prints post-install message with PATH reminder
  - Exits 0 on success
- [x] T011 [US1] Add `install` target to `justfile` — invokes `bash scripts/install.sh` (no Guix shell needed — shell script uses only coreutils). Must depend on `build` target or be callable independently (warn if binary missing at script level).
- [x] T012 [US1] Run `just build && just install` with a temporary `HOME`; verify the expected files exist at the expected paths. Run `just test` and confirm US1 BATS tests pass.

**Checkpoint**: User Story 1 complete — operator can install mtls-hello to `~/.local` and run it from there.

---

## Phase 4: User Story 2 - Random Port in Production (Priority: P2)

**Goal**: Server picks a random available port when started with `--port=0` and writes it to a port-file for process managers.

**Independent Test**: Start the server with `--port=0 --port-file=/tmp/test.port`, verify it binds to a non-zero port, the port file contains a valid port number, and a curl to that port responds.

### Tests for User Story 2 ⚠️

> **NOTE: Write these tests FIRST; they must FAIL until US2 implementation is complete, then PASS.**

- [x] T013 [P] [US2] Add BATS test `@test "--port=0 picks a random port"` in `tests/smoke.bats` — start server with `--port=0 --trust-dir ... --purgatory-dir ...`, capture stderr, verify it contains a non-8443 port number, verify `curl` to that port works.
- [x] T014 [P] [US2] Add BATS test `@test "--port-file writes the port atomically"` in `tests/smoke.bats` — start server with `--port=0 --port-file=/tmp/mtls-port-test`, verify the file exists and contains a valid port number matching the logged port, verify `curl` works.
- [x] T015 [P] [US2] Add BATS test `@test "port 8443 is still the default"` in `tests/smoke.bats` — start server with no port argument (or explicit 8443), verify it listens on 8443 (existing behavior preserved).

### Implementation for User Story 2

- [x] T016 [US2] Implement port-file atomic write in `source/app.d` — after bind (random or fixed), if `--port-file=PATH` was given: create temp file in same directory as PATH, write port number (no trailing newline) to temp file, `rename(2)` temp file to PATH. Use `std.file` for file operations. On failure to write port-file, log a warning but continue serving.
- [x] T017 [US2] Wire the random-port logic from T006 into the server startup flow in `source/app.d` — pass the assigned port to `buildServerSettings`. Ensure the "listening on" log message uses the actual port, not 0.
- [x] T018 [US2] Run `just test`; verify US1 and US2 BATS tests all pass (tests T013–T015 plus T007–T009 from US1), and all existing 23 tests still pass.

**Checkpoint**: User Story 2 complete — server can use random ports and write port files.

---

## Phase 5: User Story 3 - Systemd User Service Unit (Priority: P3)

**Goal**: Operator can generate a systemd user service unit and run mtls-hello as a managed service.

**Independent Test**: Run `just install-service`, verify the `.service` file exists at `~/.config/systemd/user/mtls-hello.service`, `systemd-analyze verify` passes, `systemctl --user start mtls-hello` starts the server, and port file contains a valid port.

### Tests for User Story 3 ⚠️

> **NOTE: Write these tests FIRST; they must FAIL until US3 implementation is complete, then PASS.**

- [x] T019 [P] [US3] Add BATS test `@test "just install-service creates a valid systemd user unit"` in `tests/smoke.bats` — set `XDG_CONFIG_HOME` to temp dir, run `just install-service`, assert `mtls-hello.service` exists, assert it contains `ExecStart` with `%h/.local/bin/mtls-hello`, assert it contains `Restart=on-failure`, assert `systemd-analyze --user verify` passes (skip if systemd-analyze unavailable).
- [x] T020 [P] [US3] Add BATS test `@test "just install-service refuses without prior install"` in `tests/smoke.bats` — with a temp `HOME` that has no `~/.local/bin/mtls-hello`, run `just install-service`, assert exit code non-zero, assert error message mentions missing binary.

### Implementation for User Story 3

- [x] T021 [US3] Create `scripts/install-service.sh` — shell script that:
  - Checks `~/.local/bin/mtls-hello` exists (exit 1 with message if not)
  - Creates `~/.config/systemd/user/` with `mkdir -p`
  - Writes the service unit file (heredoc) to `~/.config/systemd/user/mtls-hello.service` with:
    - `ExecStart=%h/.local/bin/mtls-hello --port=0 --port-file=%t/mtls-hello.port --no-multicast --handlers-dir=%h/.local/share/mtls-hello/handlers`
    - `ExecStartPost=/bin/sh -c 'echo "mtls-hello listening on port $(cat %t/mtls-hello.port)"'`
    - `Restart=on-failure`, `RestartSec=5s`
    - `WantedBy=default.target`
  - Prints post-install message with `systemctl --user daemon-reload; systemctl --user enable --now mtls-hello` instructions and drop-in override hint for certificates
  - Exits 0 on success
- [x] T022 [US3] Add `install-service` target to `justfile` — invokes `bash scripts/install-service.sh` (no Guix shell needed). Must depend on `install` target or warn independently (script checks for binary).
- [x] T023 [US3] Run `just test`; verify all BATS tests pass (US1 T007–T009, US2 T013–T015, US3 T019–T020, plus all 23 existing tests). Run `just install && just install-service` with a temporary `HOME` and verify the generated unit file matches the contract.

**Checkpoint**: User Story 3 complete — all three user stories independently functional.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Documentation validation and final verification

- [x] T024 [P] Validate `specs/007-production-install-systemd/quickstart.md` end-to-end — with a temporary `HOME`, follow steps 1–9 and verify each command's expected output.
- [x] T025 Run `just test` one final time; confirm all tests pass. Verify no leftover `mtls-hello` processes or `/tmp/mtls-*` fixtures. Confirm `git status` shows only intended changes: `source/app.d` (modified), `source/version_.d` (new), `scripts/install.sh` (new), `scripts/install-service.sh` (new), `justfile` (modified), `dub.json` (modified), `tests/smoke.bats` (modified), plus spec docs under `specs/007-production-install-systemd/`.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — baseline first.
- **Foundational (Phase 2)**: Depends on Setup. BLOCKS all user stories. T004, T005 can run in parallel (different code sections). T006 builds on T005 (needs port-file field in config).
- **US1 (Phase 3)**: Depends on Foundational. T007–T009 are parallel tests. T010 is sequential. T011 depends on T010.
- **US2 (Phase 4)**: Depends on Foundational + US1 (the tests in T013–T015 need the installed server binary pattern from US1 for end-to-end validation; however the core random-port code in source/app.d is self-contained and can be developed in parallel with US1's scripts). Tests T013–T015 parallel.
- **US3 (Phase 5)**: Depends on US1 (needs install scripts) + US2 (service unit uses `--port=0` and `--port-file`). T019–T020 parallel.
- **Polish (Phase 6)**: Depends on all user stories. T024 parallel with T025 prep.

### User Story Dependencies

- **User Story 1 (P1)**: Can start after Foundational. No dependencies on other stories.
- **User Story 2 (P2)**: Core code in source/app.d can start after Foundational. Tests require US1's install pattern. Implementation tasks T016–T017 independent of US1 scripts.
- **User Story 3 (P3)**: Depends on US1 (install script) and US2 (random port). Must be last.

### Within Each User Story

- Tests written FIRST and verified to FAIL before implementation
- Script creation before justfile target
- Implementation before verification

### Parallel Opportunities

```
T002 (dub.json version)  ─┐
T003 (version_.d)        ─┤─ Phase 1 parallel
                          ─┘

T004 (--version flag)     ─┐
T005 (--port-file parsing) ─┤─ Phase 2 parallel
                            ─┘
T006 (port=0 logic)       ───Phase 2 sequential (needs T005)

T007 (test: install)      ─┐
T008 (test: idempotent)   ─┤─ US1 tests parallel
T009 (test: mkdir)        ─┘

T013 (test: random port)   ─┐
T014 (test: port file)     ─┤─ US2 tests parallel
T015 (test: default port)  ─┘

T019 (test: valid unit)    ─┐─ US3 tests parallel
T020 (test: no install)    ─┘

T016 (port-file atomic)    ─┐─ US2 impl parallel
T017 (wire random port)    ─┘
```

---

## Parallel Example: User Story 1

```bash
# Launch all US1 tests together:
Task: "Add BATS test @test 'just install copies binary and handlers to ~/.local' in tests/smoke.bats"
Task: "Add BATS test @test 'just install is idempotent' in tests/smoke.bats"
Task: "Add BATS test @test 'just install creates missing ~/.local directories' in tests/smoke.bats"

# Then implement:
Task: "Create scripts/install.sh"
Task: "Add install target to justfile"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (T001–T003)
2. Complete Phase 2: Foundational (T004–T006)
3. Complete Phase 3: User Story 1 (T007–T012)
4. **STOP and VALIDATE**: Run `just install` with temp HOME, verify binary works independently
5. Deploy/demo: operator can install and run mtls-hello from `~/.local`

### Incremental Delivery

1. Setup + Foundational → server has version, random port, port-file parsing
2. Add US1 (install) → `just install` works → operator can deploy binary outside Guix shell
3. Add US2 (random port) → `--port=0 --port-file=...` works → ready for process manager integration
4. Add US3 (systemd) → `just install-service` creates valid unit → full production deployment

### Parallel Team Strategy

With multiple developers:

1. Team completes Setup + Foundational together
2. Once Foundational is done:
   - Developer A: User Story 1 (install scripts + justfile)
   - Developer B: User Story 2 (random port + port file in source/app.d)
3. US3 starts after US1 + US2 complete
4. Each story adds value without breaking previous stories

---

## Notes

- [P] tasks = different files or non-overlapping code sections, no dependencies
- [Story] label maps task to specific user story for traceability
- Each user story is independently completable and testable
- `HOME` override in tests: use `HOME="$BATS_TMPDIR/home"` to isolate from real home
- The Guix shell is needed only for build (`just build`); install and service scripts use only coreutils
- Commit after each task or logical group
- Stop at any checkpoint to validate story independently
