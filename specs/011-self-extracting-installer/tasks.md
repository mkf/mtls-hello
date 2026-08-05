# Tasks: Self-Extracting Portable Installer

**Input**: Design documents from `/specs/011-self-extracting-installer/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/cli.md, quickstart.md

**Tests**: BATS — new tests for filename generation, `--help`, install, install-service behavior

**Organization**: US1 (build the script) is the MVP. US2 (install subcommand) and US3 (install-service) are the actual deployment steps exercised through the generated script.

---

## Phase 1: Setup

- [X] T001 Run `just test` on branch `011-self-extracting-installer` — confirm the existing 44 tests pass before starting
- [X] T002 Create `scripts/self-extract.in` — empty template with shebang, `set -euo pipefail`, and placeholder usage function

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The self-extract.in template and the justfile recipe that assembles it.

- [X] T003 Implement `scripts/self-extract.in` — add `usage()`, subcommand dispatch (`case "${1:-}" in install|install-service|--help|-h)`), and `extract_payload()` function that uses `sed '1,/^__PAYLOAD__$/d' "$0" | base64 -d | tar xz -C "$tmpdir"`. Leave `do_install` and `do_install_service` as stubs that echo "NYI".
- [X] T004 [P] Add `self-extract` recipe to `justfile` — compute `HASH=$(git rev-parse --short HEAD)`, `DATE=$(date +%Y%m%d)`, `DIRTY` (from `git status --porcelain`), check `./mtls-hello` exists, create temp dir with install tree (`bin/`, `lib/mtls-hello/`, `share/mtls-hello/handlers/`, `share/mtls-hello/scripts/`), tar+gz+base64 it, concatenate template + `__PAYLOAD__` + payload to `mtls-hello-installer-${HASH}-${DATE}${DIRTY}.sh`, chmod +x.

**Checkpoint**: `just self-extract` produces a valid shell script; `bash <output> --help` prints usage.

---

## Phase 3: User Story 1 - Build the Self-Extracting Installer (Priority: P1) 🎯 MVP

**Goal**: `just self-extract` produces a correctly-named self-extracting script with `--help` working.

**Independent Test**: Run `just self-extract`, verify filename matches pattern, verify `bash <output> --help` prints usage and exits 0, verify `bash <output>` (no args) exits 1 with usage.

### Tests for User Story 1

- [X] T005 [US1] Add BATS test `@test "just self-extract produces a named script"` in `tests/smoke.bats` — clean tree, `just self-extract`, verify file `mtls-hello-installer-*-YYYYMMDD.sh` exists, is executable, and does NOT contain `-dirty`.
- [X] T006 [US1] Add BATS test `@test "just self-extract -dirty suffix on unclean tree"` in `tests/smoke.bats` — touch a file, run `just self-extract`, verify output filename contains `-dirty`.
- [X] T007 [US1] Add BATS test `@test "self-extracting script --help prints usage"` in `tests/smoke.bats` — run `bash <installer> --help`, verify exit 0 and output mentions `install` and `install-service`.

### Implementation for User Story 1

*None — covered by Phase 2 foundational tasks T003-T004.*

**Checkpoint**: Filename generation and help work.

---

## Phase 4: User Story 2 - Install Subcommand (Priority: P1)

**Goal**: `bash <installer> install` extracts the payload and installs to `~/.local` exactly like `just install`.

**Independent Test**: In a temp HOME, run `bash <installer> install`, then verify the binary works, handlers exist, cert was generated.

### Tests for User Story 2

- [X] T008 [US2] Add BATS test `@test "installer install subcommand works"` in `tests/smoke.bats` — temp HOME, run `just self-extract`, run `bash <installer> install`, verify `~/.local/bin/mtls-hello --version` works, handlers exist, cert exists with correct CN.
- [X] T009 [US2] Add BATS test `@test "installer install does not overwrite existing certs"` in `tests/smoke.bats` — pre-place a cert, run `bash <installer> install`, verify fingerprint unchanged.
- [X] T010 [US2] Add BATS test `@test "installer warns but succeeds without openssl"` in `tests/smoke.bats` — fake openssl, run `bash <installer> install`, verify exit 0, warning printed, no cert generated.

### Implementation for User Story 2

- [X] T011 [US2] Implement `do_install()` in `scripts/self-extract.in` — extract payload, `mkdir -p` targets, `cp` binary/libs/handlers/scripts to `~/.local/`, then run cert generation (same logic as `scripts/install.sh`): check openssl, `openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$(hostname)"`, chmod 600 key, never overwrite. Print progress messages.

**Checkpoint**: `bash <installer> install` works end-to-end on a clean HOME.

---

## Phase 5: User Story 3 - Install-Service Subcommand (Priority: P2)

**Goal**: `bash <installer> install-service` creates a systemd user unit identical to `just install-service`.

**Independent Test**: After `install`, run `install-service`, verify unit file exists and passes systemd-analyze verify.

### Tests for User Story 3

- [X] T012 [US3] Add BATS test `@test "installer install-service creates a valid unit"` in `tests/smoke.bats` — temp HOME, `install` then `install-service`, verify unit file at `~/.config/systemd/user/mtls-hello.service`, grep for `LD_LIBRARY_PATH`, `--data-dir`, absolute paths.
- [X] T013 [US3] Add BATS test `@test "installer install-service refuses without prior install"` in `tests/smoke.bats` — skip `install`, run `install-service`, verify exit non-zero, error message.

### Implementation for User Story 3

- [X] T014 [US3] Implement `do_install_service()` in `scripts/self-extract.in` — check `~/.local/bin/mtls-hello` exists (error if not), create `~/.config/systemd/user/` dir, write unit file with `LD_LIBRARY_PATH=%h/.local/lib/mtls-hello` and absolute cert paths and `--port=0 --port-file=%t/mtls-hello.port --data-dir=%h/.local/share/mtls-hello --no-multicast`. Print next-step instructions.

**Checkpoint**: `bash <installer> install-service` generates a correct unit.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [X] T015 Update `README.md` — add a "Deploying Without Guix" section referencing `just self-extract` and the one-liner deploy command (`scp ... && bash installer.sh install && bash installer.sh install-service`).
- [X] T016 Run `just test` — confirm all tests pass (existing 44 + new ~9 = ~53 tests total). Verify no regressions.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No deps.
- **Foundational (Phase 2)**: T003 → T004 (justfile references the template, but can be written in parallel since T003 creates a stub).
- **US1 (Phase 3)**: Depends on Foundational. Tests T005-T007 verify T003-T004.
- **US2 (Phase 4)**: Depends on Foundational (T003-T004). T011 (impl) → T008-T010 (tests can be written against T011).
- **US3 (Phase 5)**: Depends on US2 (needs `install` to work). T014 (impl) → T012-T013.
- **Polish (Phase 6)**: Depends on all.

### Parallel Opportunities

```
T003 (self-extract.in template) ─┐ Foundational, different files
T004 (justfile recipe)           ─┘

T005 (test: filename) ─┐
T006 (test: dirty)     ─┤ US1 tests, parallel
T007 (test: help)      ─┘

T008 (test: install)  ─┐
T009 (test: no overwrite)─┤ US2 tests, parallel
T010 (test: no openssl)  ─┘
```

---

## Implementation Strategy

### MVP (US1 Only)

1. Phase 1 (T001-T002) — setup
2. Phase 2 (T003-T004) — template + justfile → `just self-extract` works
3. US1 tests (T005-T007) — verify filename and help → **MVP**
4. US2 impl (T011) — `bash <installer> install` works
5. US2 tests (T008-T010) — verify install behavior
6. US3 impl (T014) — `bash <installer> install-service` works
7. US3 tests (T012-T013) — verify service unit
8. Polish (T015-T016)

---

## Notes

- The self-extract.in template uses `$0` for self-referencing — this means pipe-to-bash is NOT supported. Tests must save the installer to a file first.
- Cert generation in `do_install()` mirrors `scripts/install.sh` — same `openssl req -x509` command, same existence check, same 0600 mode.
- The `install-service` logic mirrors `scripts/install-service.sh` as an inline function — no external script dependency.
- Filename tests (T005, T006) should clean up the generated `.sh` file to not pollute the repo.
