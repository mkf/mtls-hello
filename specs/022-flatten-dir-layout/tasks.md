# Tasks: Flatten Directory Layout

**Input**: Design documents from `specs/022-flatten-dir-layout/`

**Prerequisites**: `plan.md`, `spec.md`, `research.md`, `data-model.md`, `contracts/layout.md`, `contracts/migrate-layout.md`, `quickstart.md`

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable (different files, no dependency on incomplete tasks)
- **[Story]**: which user story (US1–US3)
- Include exact file paths in descriptions

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Stand up the migration helper skeleton and its test harness.

- [x] T001 [P] Create `scripts/migrate-layout.sh` with a header comment, `#!/bin/bash`, `set -euo pipefail`, arg parsing for `<data-dir> [hostname]`, and a `main` that exits 0 immediately when `<data-dir>/certs` does not exist.
- [x] T002 [P] Create `tests/migrate-layout.bats` with a `setup` that builds a scratch data dir with a legacy `certs/{certs,private,hosts,purgatory}` tree and a `teardown` that removes it.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Implement the migration helper, the new default strings, and the daemon hook — everything the user stories build on.

- [x] T003 [P] Change default strings in `source/trust.d` from `"certs/hosts"` to `"hosts"` and `"certs/purgatory"` to `"purgatory"`.
- [x] T004 [P] Implement identity migration in `scripts/migrate-layout.sh`: move `certs/certs/server.crt` → `identity/<hostname>.crt` and `certs/private/server.key` → `identity/<hostname>.key` (only if target missing; warn on differing existing target).
- [x] T005 [P] Implement trust/purgatory migration in `scripts/migrate-layout.sh`: move `certs/hosts/*` → `hosts/` and `certs/purgatory/*` → `purgatory/` (skip existing targets).
- [x] T006 [P] Implement cleanup in `scripts/migrate-layout.sh`: `rmdir` empty `certs/certs`, `certs/private`, `certs/hosts`, `certs/purgatory`, then `certs`; warn (not fail) on non-empty dirs.
- [x] T007 [P] Add a `sanitize_hostname` function in `scripts/migrate-layout.sh` mapping non-`[A-Za-z0-9._-]` chars to `_` (used for the identity filename).
- [x] T008 In `source/app.d`, after resolving directories, spawn `bash <migrate-layout.sh> <data-dir> <hostname>` best-effort when `<data-dir>/certs` exists and a migration script is found (beside the callback script or `scripts/migrate-layout.sh` relative to CWD); log and ignore failures.

**Checkpoint**: `scripts/migrate-layout.sh` migrates a legacy tree end-to-end; `source/trust.d` uses the new defaults; the daemon triggers migration at startup.

---

## Phase 3: User Story 1 — Trust & purgatory at the top level (Priority: P1) 🎯 MVP

**Goal**: Trust resolves to `hosts` / `<data-dir>/hosts` and purgatory to `purgatory` / `<data-dir>/purgatory`; no `certs/` nesting by default; explicit flags still override.

**Independent Test**: Start the daemon with `--data-dir` and confirm the log lines report `hosts` and `purgatory` at the top level; without `--data-dir`, defaults are `hosts`/`purgatory`.

### Tests for User Story 1

- [x] T009 [P] [US1] Add a D unit test in `source/test_main.d` (or a BATS check) asserting the default `TrustConfig` resolves to `hosts` and `purgatory`, not `certs/*`.
- [x] T010 [P] [US1] Add a BATS/robot check that `--trust-dir`/`--purgatory-dir` explicitly provided still win over the derived defaults.

### Implementation for User Story 1

- [x] T011 [US1] Verify in `source/app.d` that `--data-dir` derivation produces `DIR/hosts` and `DIR/purgatory` (already present) and that `mkdirRecurse` uses the new paths.

**Checkpoint**: US1 complete — trust/purgatory are top-level; explicit flags still honored.

---

## Phase 4: User Story 2 — Identity directory (Priority: P2)

**Goal**: Our own cert/key live in `identity/<hostname>.crt` + `identity/<hostname>.key`; no `certs/certs` or `certs/private` created by install.

**Independent Test**: A fresh `just install` produces `~/.local/share/mtls-hello/identity/<hostname>.crt` + `.key` and no `certs/` directory.

### Tests for User Story 2

- [x] T012 [P] [US2] Add a BATS check that a simulated fresh install generates `identity/<hostname>.crt` + `identity/<hostname>.key` and creates no `certs/` directory.

### Implementation for User Story 2

- [x] T013 [P] [US2] Update `scripts/install.sh` to `mkdir -p` the `identity/` dir and generate `identity/<hostname>.crt` + `identity/<hostname>.key` (CN = `$(hostname)`, key mode 600) instead of `certs/certs/server.crt` + `certs/private/server.key`.
- [x] T014 [US2] Update `scripts/install.sh` to pass `$DATA_DIR/identity/<hostname>.crt` and `$DATA_DIR/identity/<hostname>.key` as the server cert/key arguments to `scripts/apache-config.sh`.
- [x] T015 [P] [US2] Update `scripts/install-service.sh` so `OUR_CERT`/`OUR_KEY` point at `%h/.local/share/mtls-hello/identity/<hostname>.crt` and `.key`.
- [x] T016 [P] [US2] Update `scripts/package-common.sh`: systemd env lines, user cert gen, and `/var/lib/mtls-hello/identity/` layout for the packaged install.
- [x] T017 [P] [US2] Update `scripts/self-extract.in` to generate certs into `identity/` and reference the identity paths.

**Checkpoint**: US2 complete — installs produce the flat `identity/` layout.

---

## Phase 5: User Story 3 — Automatic non-interactive migration (Priority: P2)

**Goal**: Legacy `certs/` installs migrate automatically (move files, remove empty dirs), idempotently, with no prompts and no overwrites.

**Independent Test**: Run `scripts/migrate-layout.sh` against a populated legacy tree; files land in the new layout, empty legacy dirs are gone; a second run is a no-op.

### Tests for User Story 3

- [x] T018 [P] [US3] Add a BATS test: full legacy tree migrates to `hosts/`, `purgatory/`, `identity/<hostname>.crt|.key` and `certs/` is removed.
- [x] T019 [P] [US3] Add a BATS test: second migration run is a no-op (exit 0, no changes).
- [x] T020 [P] [US3] Add a BATS test: partial legacy layout (cert but no key) migrates without failure.
- [x] T021 [P] [US3] Add a BATS test: an existing differing target file is kept and a warning is emitted (no overwrite).
- [x] T022 [P] [US3] Add a BATS test: a non-empty leftover legacy dir is kept with a warning, not deleted.

### Implementation for User Story 3

- [x] T023 [US3] Wire `scripts/migrate-layout.sh` into `scripts/install.sh` (after cert generation, before apache-config.sh).
- [x] T024 [P] [US3] Wire `scripts/migrate-layout.sh` into `scripts/package-common.sh` postinst (user + `/var/lib/mtls-hello`).
- [x] T025 [P] [US3] Wire `scripts/migrate-layout.sh` into `scripts/self-extract.in`.

**Checkpoint**: US3 complete — legacy installs migrate automatically and safely.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [x] T026 [P] Update `README.md`: Directory Resolution section (hosts/purgatory top-level, `identity/` instead of `certs/certs`+`certs/private`), the "Start With Discovery" example, the Certificates section, and CLI defaults (drop `certs/` fallbacks).
- [x] T027 [P] Run `shellcheck` on `scripts/migrate-layout.sh`, `scripts/install.sh`, `scripts/install-service.sh`, `scripts/package-common.sh`, `scripts/self-extract.in`; fix warnings.
- [x] T028 [P] Run `just test-d` to confirm D unit tests pass (new defaults + daemon hook).
- [x] T029 [P] Run `just robot` to confirm existing end-to-end tests still pass.
- [x] T030 [P] Run `bats tests/migrate-layout.bats` and all new US3 tests.
- [x] T031 Grep the repo (excluding `specs/`) for stale `certs/certs`, `certs/private`, `certs/hosts`, `certs/purgatory`, `server.crt`, `server.key` references and update or remove any remaining ones.
- [x] T032 Verify `AGENTS.md` still points to `specs/022-flatten-dir-layout/plan.md`.
- [x] T033 Update `specs/022-flatten-dir-layout/tasks.md` to mark completed tasks.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies.
- **Foundational (Phase 2)**: depends on Setup; blocks all user stories.
- **US1 (Phase 3)**: depends on Foundational (new defaults).
- **US2 (Phase 4)**: depends on Foundational (identity migration helper exists); can run in parallel with US1.
- **US3 (Phase 5)**: depends on Foundational (migration helper implemented + tested).
- **Polish (Phase 6)**: after all stories.

### Parallel Opportunities

- All Phase 1 tasks are independent files.
- Foundational `[P]` tasks (T003–T007) are independent; T008 depends on T004–T006.
- US1 tests (T009, T010) run in parallel with US2/US3.
- US2 edits (T013–T017) are different files → parallel.
- US3 tests (T018–T022) are parallel; wiring tasks T023–T025 are different files.

---

## Implementation Strategy

1. **MVP first**: Foundational + US1 — new defaults (`hosts`/`purgatory`) + migration helper working; verify resolution and migration.
2. **Then US2**: flip install/service/package/self-extract to the `identity/` layout.
3. **Then US3**: wire migration into every installer entry point and prove idempotency/safety with the BATS suite.
4. **Polish**: README + shellcheck + full test sweep + stale-path grep.

## Bugfix Notes

- **BUG-001** (cleanup_pkgroot leaves per-distro metadata): fixed in
  `scripts/package-common.sh` — `cleanup_pkgroot` now removes
  `DEBIAN/{control,postinst}` and `.PKGINFO`/`.INSTALL` before rmdir'ing the
  tree. Also fixed `package-common.sh` to resolve `cleanup-common.sh` via
  `BASH_SOURCE` (was `$0`, which breaks when the file is sourced). Regression
  test added in `tests/migrate-layout.bats` ("BUG-001: cleanup_pkgroot removes
  per-distro metadata without warnings").
