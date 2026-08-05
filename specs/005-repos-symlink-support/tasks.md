# Tasks: REPOS_ROOT Symlinked Repositories

**Input**: Design documents from `/specs/005-repos-symlink-support/`

**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md, contracts/

**Tests**: Test tasks ARE included — the feature spec explicitly requires automated coverage (FR-008, FR-009).

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

- **Single project**: `source/`, `tests/`, `handlers/`, `scripts/` at repository root
- This feature changes **no D code** (see plan.md); work is BATS tests + docs, all under `tests/smoke.bats` and `specs/005-repos-symlink-support/`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Baseline verification before any changes

- [x] T001 Verify baseline: run `just test` on branch `005-repos-symlink-support` and confirm all 20 existing tests pass before any changes

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Shared test infrastructure — a fixture mode for symlinked REPOS_ROOT layouts, required by BOTH user stories

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [x] T002 Extend `tests/smoke.bats` `mkfixture` (or add a sibling helper `mkfixture_symlinked`) so the demo fixture can be created with repositories stored in a separate directory (`$base/real/local/*`, `$base/real/peer/*`) and each entry under `$base/local/` and `$base/peer/` is a **symlink** to the corresponding real repo (use relative symlinks, e.g. `ln -s ../real/local/alpha "$base/local/alpha"`). Preserve the existing behaviors: `alpha`/`beta` local-ahead, `gamma` in sync, `delta` diverged. Return the fixture base path. Do NOT change the default (real-directory) behavior of the existing `mkfixture`.
- [x] T003 Verify the symlinked fixture is self-consistent: create a symlinked fixture manually and confirm `git -C <fixture>/local/alpha rev-parse HEAD` and `git -C <fixture>/peer/alpha rev-parse HEAD` return the same HEADs as the real-directory fixture for the same test scenario (alpha local-ahead, gamma equal, delta diverged)

**Checkpoint**: Foundation ready - user story implementation can now begin

---

## Phase 3: User Story 1 - Multi-Repo Sync Works With Fully Symlinked REPOS_ROOT (Priority: P1) 🎯 MVP

**Goal**: The full multi-repo sync demo passes when every `REPOS_ROOT` entry (both sides) is a symlink to a repository stored elsewhere.

**Independent Test**: A BATS test that runs the demo with the symlinked fixture and asserts the identical invariants as the real-directory demo.

### Tests for User Story 1 ⚠️

> **NOTE: Write this test FIRST; it must FAIL until the fixture/helpers are in place, then PASS.**

- [x] T004 [US1] Add BATS test `@test "US1: multi-repo git sync demo works with fully symlinked REPOS_ROOT"` in `tests/smoke.bats`: build a symlinked fixture (`mkfixture_symlinked "/tmp/mtls-symlink-demo-$$"`), start one server on port `18510` with `REPOS_ROOT="$fixture/peer"` and `--handlers-dir handlers`, record peer delta HEAD before the run, invoke `scripts/on-discover.sh` as the local side (`REPOS_ROOT="$fixture/local"`), then assert: output contains `synced=2` and `skipped=2`; peer `alpha` and `beta` reach local HEADs; peer `gamma` still equals the shared origin HEAD; peer `delta` is unchanged and still differs from local `delta` (mirror the existing real-directory US2 test at `tests/smoke.bats` lines ~321–353)

### Implementation for User Story 1

- [x] T005 [US1] Run `just build` then `just test`; verify the new symlinked demo test (T004) passes and all 20 prior tests still pass
- [x] T006 [US1] Contingency — ONLY if T004 fails: adjust REPOS_ROOT entry resolution in `handlers/head.get.sh`, `handlers/bundle.post.sh`, and/or `scripts/on-discover.sh` so symlinked entries resolve to their target repositories (e.g., operate on the resolved path), then re-run `just test` until T004 and all prior tests pass

**Checkpoint**: User Story 1 is fully functional and testable independently (MVP)

---

## Phase 4: User Story 2 - Broken Symlink Targets Fail Cleanly (Priority: P2)

**Goal**: A broken symlink under `REPOS_ROOT` is skipped with a log line and does not block or corrupt the other repositories.

**Independent Test**: A BATS test with one broken symlink among healthy entries, asserting healthy repos sync and the broken entry is isolated.

### Tests for User Story 2 ⚠️

> **NOTE: Write this test FIRST; it must FAIL until the fixture/helpers are in place, then PASS.**

- [x] T007 [US2] Add BATS test `@test "US2: broken symlink under REPOS_ROOT fails cleanly"` in `tests/smoke.bats`: build a symlinked fixture, then replace ONE peer entry (e.g. `beta`) with a broken symlink (`ln -s /nonexistent "$fixture/peer/beta"` after removing the good link); start one server with `REPOS_ROOT="$fixture/peer"`; run the callback as the local side; then assert: the run exits 0, output reports `skipped=2` or more and does NOT report the broken entry as synced, peer `alpha` reaches the local HEAD (healthy entries unaffected), and peer `delta` remains unchanged (diverged, untouched)

### Implementation for User Story 2

- [x] T008 [US2] Run `just build` then `just test`; verify the broken-symlink test (T007) passes and all prior tests still pass

**Checkpoint**: User Stories 1 AND 2 both work independently

---

## Phase 5: Polish & Cross-Cutting Concerns

**Purpose**: Documentation validation and final verification

- [x] T009 [P] Validate `specs/005-repos-symlink-support/quickstart.md` end-to-end by manually following the symlinked-layout steps with a fresh fixture (Section 1 layout + Section 2 run), and confirm the troubleshooting notes (broken symlink, dubious ownership) match observed behavior
- [x] T010 [P] Cross-check `specs/005-repos-symlink-support/contracts/repos-layout.md` and `spec.md` against the implemented tests in `tests/smoke.bats`: every invariant (ahead→synced, in-sync→skipped, diverged→untouched, broken→isolated, absolute/relative/chain targets) must be either covered by a test or explicitly documented as operator-environment concern
- [x] T011 Run `just test` one final time; confirm no leftover `mtls-hello` processes or `/tmp/mtls-*-demo-*` fixtures; confirm `git status` shows only intended changes

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — baseline verification first
- **Foundational (Phase 2)**: Depends on Setup; BLOCKS both user stories (the symlinked fixture helper is shared)
- **User Stories (Phase 3+)**:
  - US1 (P1) depends on Foundational
  - US2 (P2) depends on Foundational; may reuse the US1 fixture (both touch `tests/smoke.bats`, so run sequentially, not in parallel)
- **Polish (Phase 5)**: Depends on both user stories

### User Story Dependencies

- **User Story 1 (P1)**: No dependencies on other stories
- **User Story 2 (P2)**: Depends on the symlinked fixture from Foundational; should be independently testable (separate `@test` block)

### Within Each User Story

- Tests MUST be written and FAIL before implementation completes
- The US1 and US2 tests edit the same file (`tests/smoke.bats`) — do NOT run them in parallel

### Parallel Opportunities

- T001 (baseline) and T002 (fixture helper) are sequential (T001 first)
- T009 and T010 (docs validation) can run in parallel — different files
- No other parallel opportunities: all implementation is in `tests/smoke.bats` (single file)

---

## Parallel Example: Polish Phase

```bash
# Launch both doc validations together:
Task: "Validate quickstart.md end-to-end"     (T009)
Task: "Cross-check contracts/repos-layout.md"  (T010)
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: T001 baseline
2. Complete Phase 2: T002–T003 symlinked fixture (CRITICAL — blocks all stories)
3. Complete Phase 3: T004 test → T005 verify (T006 contingency only if needed)
4. **STOP and VALIDATE**: run `just test` — US1 passes, all 20 prior tests pass

### Incremental Delivery

1. Setup + Foundational → symlinked fixture ready
2. Add User Story 1 → test independently (MVP!)
3. Add User Story 2 → test independently
4. Polish: validate docs, final full run

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- Each user story is independently completable and testable (separate `@test` blocks in `tests/smoke.bats`)
- Verify tests fail before implementation completes (test-first)
- Commit after each task or logical group
- Stop at any checkpoint to validate the story independently
- Avoid: vague tasks, same-file conflicts (US1/US2 both edit `tests/smoke.bats` — sequential)
- Expected outcome per plan.md: **no D code changes**; any fix is confined to the bash handlers/callback (T006 contingency)
