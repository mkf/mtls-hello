# Tasks: Bare-Repository Git Sync Between Peers

**Input**: Design documents from `/specs/006-bare-repo-git-sync/`

**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md, contracts/

**Tests**: Test tasks ARE included — the feature spec explicitly requires automated coverage (FR-009).

**Organization**: Tasks are grouped by user story. Working-tree layout is removed; all sync tests use bare repos only.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2)
- Include exact file paths in descriptions

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Baseline verification before any changes

- [x] T001 Verify baseline: run `just test` on branch `006-bare-repo-git-sync` and confirm all 22 existing tests pass before any changes

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Rewrite handlers, callback, and test fixture — ALL user stories depend on these

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [x] T002 [P] Rewrite `handlers/bundle.post.sh` — resolve bare repo path from `QUERY_REPO` (`${REPOS_ROOT?}/${QUERY_REPO?}.git`), receive bundle body to temp file, `git fetch` branches with force into remote-tracking namespace (`+refs/heads/*:refs/remotes/${QUERY_HOST?}/*`), then promote fast-forwardable or missing branches to `refs/heads/*` (diverged branches remain namespaced), `git fetch` tags without force (`refs/tags/*:refs/tags/* || true` for conflict tolerance), respond `ok` on success. Remove old HEAD-merge logic.
- [x] T003 [P] Rewrite `scripts/on-discover.sh` — iterate `"$REPOS_ROOT"/*/` (bare repos with `.git` suffix), strip `.git` with `basename` for repo identifier, `git -C "$repo_dir" bundle create "$tmp" --all`, POST bundle to `https://$PEER_NETLOC/bundle?repo=${name}&host=${HOST_NAME}` via `mtls_curl_post`. Remove all HEAD comparison and `merge-base --is-ancestor` checking. Keep the `synced`/`skipped` summary counters.
- [x] T004 [P] Remove `handlers/head.get.sh` — the HEAD-lookup endpoint is no longer part of the sync flow; GET `/head` falls back to echo (returns "head"), which is acceptable behavior.
- [x] T005 Add `mkfixture_bare` helper function in `tests/smoke.bats` — creates two `REPOS_ROOT` trees (`local/` and `peer/`) with bare git repositories (`*.git`) initialized from a seed working tree. States: `alpha` (local ahead by 1 commit), `beta` (peer ahead by 1 commit), `gamma` (diverged — both have unique commits), `delta` (local-only, no peer counterpart), plus a tag on local gamma (`local-tag-v1`) for tag-push verification. Returns fixture base path.
- [x] T006 Remove the old working-tree fixture functions (`mkfixture`, `mkfixture_symlinked`, `build_demo_repos`) from `tests/smoke.bats` — directly in the edit that adds `mkfixture_bare` in T005, or as a follow-up edit (same file).

**Checkpoint**: Foundation ready — handlers and callback rewritten for bare repos, old fixtures removed, new fixture ready.

---

## Phase 3: User Story 1 - Two Hosts Sync Bare Repos End-to-End (Priority: P1) 🎯 MVP

**Goal**: Two simulated hosts with bare repos, mixed branch/tag states, sync bidirectionally. After sync, all branches and tags from both hosts exist on both, diverged branches preserved, missing tags pushed.

**Independent Test**: A BATS test that invokes the callback in both directions and asserts every branch/tag invariant from the spec.

### Tests for User Story 1 ⚠️

> **NOTE: Write tests FIRST; they must FAIL until the foundational code is in place, then PASS.**

- [x] T007 [US1] Remove the feature 003 US2 working-tree demo test (`@test "US2: multi-repo git sync demo"`) from `tests/smoke.bats` — working-tree layout is no longer supported.
- [x] T008 [US1] Add BATS test `@test "US1: bare-repo sync — all branches, tags, and diverged branches"` in `tests/smoke.bats` — use `mkfixture_bare`, start one server with `REPOS_ROOT="$fixture/peer" --handlers-dir handlers` on port 18530, invoke callback as local side (`HOST_NAME=local REPOS_ROOT="$fixture/local" PEER_NETLOC="localhost:18530" ...`), then tear down the server and start a new server on port 18531 with `REPOS_ROOT="$fixture/local"` and invoke callback as peer side (`HOST_NAME=peer REPOS_ROOT="$fixture/peer" PEER_NETLOC="localhost:18531" ...`). Assert:
  - Alpha's main (local ahead) → fast-forwarded on peer; available at `refs/remotes/local/main` on peer.
  - Beta's main (peer ahead) → available at `refs/remotes/peer/main` on local.
  - Gamma's diverged main → BOTH local's and peer's versions preserved; peer has `refs/remotes/local/main` distinct from its own `refs/heads/main`.
  - Delta repo (local-only) → peer has it at `refs/remotes/local/main`.
  - Local gamma tag `local-tag-v1` → present on peer's gamma.
  - Both callback invocations exit 0 and report `synced=` and `skipped=` counts.
- [x] T009 [US1] Adapt the feature 005 US1 symlinked-layout test (`@test "US1: multi-repo git sync demo works with fully symlinked REPOS_ROOT"`) in `tests/smoke.bats` to use bare repos — symlink bare repo directories (`*.git/*`) instead of working trees, reusing `mkfixture_bare` plus symlink creation.
- [x] T010 [US1] Adapt the feature 005 US2 broken-symlink test (`@test "US2: broken symlink under REPOS_ROOT fails cleanly"`) in `tests/smoke.bats` to use bare repos — broken symlink to a bare repo directory; assert healthy repos sync and broken entry skipped.

### Implementation for User Story 1

- [x] T011 [US1] Run `just build` then `just test`; verify the new bare-repo sync test (T008), the adapted symlink tests (T009, T010), and all prior non-REPOS-ROOT tests (features 001/002/004 trust, discovery, handler dispatch, purgatory) pass. Expected total: ~22 tests (1 removed, 1 added, 2 adapted).

**Checkpoint**: User Story 1 is fully functional — bare-repo sync with all branch states, symlink support, and broken-symlink isolation are all verified.

---

## Phase 4: User Story 2 - Idempotency (Priority: P2)

**Goal**: Running the sync twice with no changes produces no new refs and no errors.

**Independent Test**: Run full bidirectional sync, capture refs, run again, assert identical.

### Tests for User Story 2 ⚠️

- [x] T012 [US2] Add BATS test `@test "US2: repeated bare-repo sync is idempotent"` in `tests/smoke.bats` — build fixture, run full bidirectional sync twice, capture the remote-tracking refs after each run, assert the second run produces zero new refs and exits 0 for all repos.

### Implementation for User Story 2

- [x] T013 [US2] Run `just test`; verify US2 idempotency test passes and no prior tests regress.

**Checkpoint**: Both user stories work independently.

---

## Phase 5: Polish & Cross-Cutting Concerns

**Purpose**: Documentation validation and final verification

- [x] T014 [P] Cross-check `specs/006-bare-repo-git-sync/contracts/bare-sync.md` against all implemented tests in `tests/smoke.bats` — verify every contract invariant (branch namespace `refs/remotes/<host>/*`, tag conflict tolerance, symlink support, error codes) is covered by at least one test assertion.
- [x] T015 [P] Validate `specs/006-bare-repo-git-sync/quickstart.md` end-to-end — manually follow steps 1–2 (create bare repos, simulate sync, verify remote-tracking refs appear at `refs/remotes/<peer>/<branch>`).
- [x] T016 Run `just test` one final time; confirm no leftover `mtls-hello` processes or `/tmp/mtls-*-demo-*` fixtures; confirm `git status` shows only intended changes: `handlers/bundle.post.sh` (modified), `scripts/on-discover.sh` (modified), `handlers/head.get.sh` (deleted), `tests/smoke.bats` (modified), plus the spec docs under `specs/006-bare-repo-git-sync/`.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — baseline first.
- **Foundational (Phase 2)**: Depends on Setup. BLOCKS both user stories. T002/T003/T004 can run in parallel (different files). T005–T006 are sequential (single file).
- **US1 (Phase 3)**: Depends on Foundational. T007–T010 are sequential (all edit `tests/smoke.bats`). T011 is verification.
- **US2 (Phase 4)**: Depends on US1 (the idempotency test uses the same fixture/callback infrastructure built for US1). T012 is test, T013 verification.
- **Polish (Phase 5)**: Depends on both user stories. T014/T015 can run in parallel (different files).

### Within Each User Story

- Tests MUST be written and FAIL before implementation is verified fully.
- US1 and US2 both edit `tests/smoke.bats` — sequential.

### Parallel Opportunities

```
T002 (bundle.post.sh)  ─┬─ parallel
T003 (on-discover.sh)  ─┤
T004 (remove head.get) ─┘

T014 (contracts cross-check) ─┬─ parallel
T015 (quickstart validation) ─┘
```

---

## Parallel Example: Foundational Phase

```bash
# Launch all three script edits together:
Task: "Rewrite handlers/bundle.post.sh"    (T002)
Task: "Rewrite scripts/on-discover.sh"     (T003)
Task: "Remove handlers/head.get.sh"        (T004)
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: T001 baseline
2. Complete Phase 2: T002–T006 foundational (scripts + fixture)
3. Complete Phase 3: T007–T011 US1 (tests + verification)
4. **STOP and VALIDATE**: run `just test` — bare-repo sync, symlinks, and all prior tests pass

### Incremental Delivery

1. Setup + Foundational → handlers/callback rewritten, bare fixture ready
2. Add User Story 1 → bare-repo sync verified (MVP!)
3. Add User Story 2 → idempotency verified
4. Polish → docs validated, final suite clean

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- Each user story is independently testable (separate `@test` blocks)
- Expected D code changes: **none** (all bash + BATS)
- Working-tree layout and all its artifacts (`mkfixture`, `build_demo_repos`, `mkfixture_symlinked`, the 003 demo test) are **removed** — bare repos only
