# Tasks: Bundle Spooling with Hash-Range Deduplication

**Input**: Design documents from `/specs/016-bundle-spooling/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/cli.md, quickstart.md

**Tests**: BATS — spool a bundle, verify file, run merge-spool.sh, verify refs

**Organization**: US1 (spool) + US4 (merge) are the MVP. US2 (coverage query) and US3 (smart sizing) build on top.

---

## Phase 1: Setup

- [ ] T001 Verify baseline: `just build` succeeds and existing tests pass before starting

---

## Phase 2: Foundational (Blocking Prerequisites)

- [X] T002 Extract the fetch-and-promote logic from the current `handlers/bundle.post.sh` into a reusable function in `scripts/sync-common.sh` named `apply_bundle_to_repo`. The function takes `<repo_dir> <bundle_file> <peer_host>` and performs: fetch into per-peer namespace, promote branches, fetch tags, fix HEAD. This is the core logic that `merge-spool.sh` will call.

---

## Phase 3: User Story 1 - Bundles Are Spooled, Not Applied (Priority: P1) 🎯 MVP

**Goal**: POST `/bundle` saves to `<data-dir>/spool/<repo>/<from>-<to>.bundle` instead of applying.

**Independent Test**: POST a bundle to a server, verify the spool file exists and the bare repo is unchanged.

### Implementation for User Story 1

- [X] T003 [US1] Rewrite `handlers/bundle.post.sh` to spool instead of apply: read POST body to a temp file with `.tmp` suffix at `<data-dir>/spool/<repo>/<from>-<to>.bundle.tmp`, extract from/to SHA from query params (or `git bundle list-heads` if missing), rename `.tmp` to `.bundle` atomically, return `200 spooled`. Create the spool directory if it doesn't exist.
- [ ] T004 [US1] Add BATS test `@test "bundle POST spools instead of applying"` in `tests/smoke.bats` — POST a bundle to the server, verify `<data-dir>/spool/<repo>/` contains a `.bundle` file, and `refs/heads/main` in the bare repo is unchanged.
- [ ] T005 [US1] Add BATS test `@test "duplicate bundle POST overwrites spool file"` in `tests/smoke.bats` — POST the same bundle twice, verify only one `.bundle` file exists (idempotent).

**Checkpoint**: Bundles are spooled, not applied. Bare repos are untouched by the server.

---

## Phase 4: User Story 4 - User Merges Spooled Bundles (Priority: P2) 🎯 MVP

**Goal**: `scripts/merge-spool.sh` applies spooled bundles to bare repos and cleans up.

**Independent Test**: Spool bundles, run merge-spool.sh, verify refs updated and spool files deleted.

### Implementation for User Story 4

- [X] T006 [US4] Create `scripts/merge-spool.sh` — iterates over `<data-dir>/spool/<repo>/*.bundle` files, calls `apply_bundle_to_repo` (from sync-common.sh) for each in topological order (sort by from-sha), deletes the spool file on success, skips bundles with missing parent commits with a clear message. Accepts optional repo-name argument to merge only one repo.
- [ ] T007 [US4] Add BATS test `@test "merge-spool.sh applies spooled bundles"` in `tests/smoke.bats` — spool a bundle, run `merge-spool.sh`, verify `refs/heads/main` is updated and the spool file is deleted.
- [ ] T008 [US4] Add BATS test `@test "merge-spool.sh skips missing parent"` in `tests/smoke.bats` — spool a bundle whose parent commit doesn't exist, run `merge-spool.sh`, verify it skips with a clear message and the spool file remains.

**Checkpoint**: Operator can merge spooled bundles on demand. Full spool→merge cycle works.

---

## Phase 5: User Story 2 - Bundler Queries Coverage Before Sending (Priority: P1)

**Goal**: `on-discover.sh` queries `/spool?repo=name` before bundling to skip covered ranges.

**Independent Test**: After syncing, re-run discovery; zero bundles sent.

### Implementation for User Story 2

- [X] T009 [US2] Create `handlers/spool.get.sh` — GET handler that lists covered ranges from `<data-dir>/spool/<repo>/` as plain text (`from-sha to-sha` per line). Returns 404 if no spool directory for this repo.
- [X] T010 [US2] Update `scripts/sync-common.sh` — add `query_spool_coverage` function that does `mtls_curl "/spool?repo=${name}"` and returns the list of covered ranges.
- [X] T011 [US2] Update `scripts/on-discover.sh` — before bundling each branch, call `query_spool_coverage` and skip ranges already covered. Compute the from/to SHA for each bundle and pass them as query params in the POST.
- [ ] T012 [US2] Add BATS test `@test "spool GET lists covered ranges"` in `tests/smoke.bats` — spool a bundle, GET `/spool?repo=name`, verify the range is listed.
- [ ] T013 [US2] Add BATS test `@test "on-discover skips covered ranges"` in `tests/smoke.bats` — sync once, then run on-discover again, verify zero bundles are sent (all ranges covered).

**Checkpoint**: Discovery cycle sends zero bundles when nothing changed.

---

## Phase 6: User Story 3 - Smart Bundle Sizing via Git-Only Operations (Priority: P2)

**Goal**: Consolidate small branches, chunk large histories, all via `git bundle create`.

**Independent Test**: Mixed repo sizes produce bundles between 500KB and 10MB.

### Implementation for User Story 3

- [ ] T014 [US3] Update `scripts/on-discover.sh` — add consolidation logic: if multiple branches each produce bundles under 500KB, combine them with `git bundle create branch1 branch2 --tags` into a single bundle.
- [ ] T015 [US3] Update `scripts/on-discover.sh` — add chunking logic: if a single branch bundle exceeds 10MB, split by computing a midpoint commit with `git rev-list --max-count=N --skip=K` and creating incremental bundles `git bundle create main ^midpoint --tags`.
- [ ] T016 [US3] Add BATS test `@test "small branches are consolidated"` in `tests/smoke.bats` — create three tiny branches, run on-discover, verify a single combined bundle is sent.
- [ ] T017 [US3] Add BATS test `@test "large branch is chunked"` in `tests/smoke.bats` — create a branch with many commits, run on-discover, verify multiple chunk bundles are sent, each under 10MB.

**Checkpoint**: Bundle sizes are optimized. No file-level concatenation.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [X] T018 Update `scripts/install.sh` to copy `merge-spool.sh` and `spool.get.sh` to the install directory.
- [X] T019 Update `scripts/package-common.sh` to stage `merge-spool.sh` and `spool.get.sh` in the package tree.
- [X] T020 Update `README.md` — document the spool→merge workflow and `merge-spool.sh` usage.
- [ ] T021 Run `just test` — confirm all tests pass (existing + new spooling tests).

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No deps.
- **Foundational (Phase 2)**: T002 blocks US1 and US4 (merge-spool.sh needs the extracted function).
- **US1 Spool (Phase 3)**: Depends on T002. T003 → T004, T005.
- **US4 Merge (Phase 4)**: Depends on T002 and US1. T006 → T007, T008.
- **US2 Coverage (Phase 5)**: Depends on US1. T009 → T010 → T011 → T012, T013.
- **US3 Sizing (Phase 6)**: Depends on US2. T014, T015 → T016, T017.
- **Polish (Phase 7)**: Depends on all.

### Practical build order (MVP first)

1. T001 (setup)
2. T002 (extract apply_bundle_to_repo)
3. T003 (rewrite bundle.post.sh to spool) + T004, T005 (tests) → **MVP: spooling works**
4. T006 (merge-spool.sh) + T007, T008 (tests) → **MVP: full spool→merge cycle**
5. T009-T013 (coverage query)
6. T014-T017 (smart sizing)
7. T018-T021 (polish)

### Parallel Opportunities

```
T004 (test: spool)    ─┐  US1 tests, independent
T005 (test: dupe)     ─┘

T007 (test: merge)    ─┐  US4 tests, independent
T008 (test: skip)     ─┘

T012 (test: spool GET)─┐  US2 tests, independent
T013 (test: skip)     ─┘

T016 (test: consolidate)─┐  US3 tests, independent
T017 (test: chunk)     ─┘
```

---

## Implementation Strategy

### MVP: Spool + Merge (US1 + US4)

1. Phase 1 (T001) — setup
2. Phase 2 (T002) — extract reusable apply function
3. Phase 3 (T003-T005) — spool instead of apply → **MVP**
4. Phase 4 (T006-T008) — merge script → **full cycle**
5. Phase 5 (T009-T013) — coverage query
6. Phase 6 (T014-T017) — smart sizing
7. Phase 7 (T018-T021) — polish

---

## Notes

- `bundle.post.sh` is completely rewritten — it no longer applies bundles, just spools them.
- `merge-spool.sh` reuses the old `bundle.post.sh` fetch-and-promote logic (extracted to `sync-common.sh`).
- The spool directory is `<data-dir>/spool/` which is derived from the script location: `$(dirname "$0")/../spool/`.
- Backward compatibility: old senders (no from/to params) still work — server computes range from bundle. Old servers still work — sender doesn't check response content.
