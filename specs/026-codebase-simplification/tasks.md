# Tasks: Codebase Simplification

**Input**: Design documents from `/specs/026-codebase-simplification/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/external-interfaces.md

**Tests**: No new test tasks — the existing BATS + Robot suite IS the regression oracle. Tasks validate by running existing tests green.

**Organization**: Tasks grouped by user story. US1 is the consolidation work validated by the full test suite. US2 is dead-code removal and file merging. US3 is the final consistency pass.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to
- Include exact file paths in descriptions

## Phase 1: Setup (Baseline Measurement)

**Purpose**: Record the "before" state so we can measure improvement

- [ ] T001 Record baseline line count: `find source scripts handlers cli -name '*.d' -o -name '*.sh' | xargs wc -l | tail -1` → save to `specs/026-codebase-simplification/baseline-lines.txt`
- [ ] T002 Record baseline file count: `find source scripts handlers cli -name '*.d' -o -name '*.sh' | wc -l` → save to `specs/026-codebase-simplification/baseline-files.txt`
- [ ] T003 Record baseline test status: `nix-shell --run 'bats tests/'` → confirm 92/92 pass (or note skips)

---

## Phase 2: Foundational (Create cgi-lib.sh)

**Purpose**: Create the consolidated CGI library that all handlers and discovery scripts will source. This is the single blocking prerequisite — nothing else can proceed until it exists.

**⚠️ CRITICAL**: All user story work depends on this library existing.

- [ ] T004 Create `scripts/cgi-lib.sh` by concatenating `scripts/cgi-common.sh` + `scripts/cgi-trust.sh` into a single file with one header, one `set -euo pipefail`, and all functions from both originals
- [ ] T005 Add `extract_cn()` function to `scripts/cgi-lib.sh` — uses the RFC2253 `openssl x509 -noout -subject -nameopt RFC2253 | sed -n 's/^subject=.*CN=\([^,+\/]*\).*/\1/p'` pattern (the most robust variant from research R2)
- [ ] T006 Add `resolve_data_dir()` function to `scripts/cgi-lib.sh` — resolves via `${DATA_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}` pattern; callers pass their relative depth or just use `DATA_DIR` env override
- [ ] T007 Add `cgi_require_trusted()` function to `scripts/cgi-lib.sh` — combines the SSL_CLIENT_CERT presence check + `is_trusted()` call + `cgi_error "401"` on failure; replaces the 6-line boilerplate in every handler
- [ ] T008 Run `shellcheck --severity=warning scripts/cgi-lib.sh` and `bash -n scripts/cgi-lib.sh` — both must be clean

**Checkpoint**: `cgi-lib.sh` exists, passes shellcheck, defines all functions from both originals plus three new helpers.

---

## Phase 3: User Story 1 — All Features Still Work (Priority: P1) 🎯 MVP

**Goal**: Migrate all consumers from the two old libraries to `cgi-lib.sh`, fix the 90-log.sh DATA_DIR bug, and consolidate CN extraction. The full test suite remains green throughout.

**Independent Test**: `nix-shell --run 'bats tests/'` — all tests pass, zero regressions.

### Implementation for User Story 1

- [ ] T009 [P] [US1] Update `handlers/hello.get.sh`: replace dual `source cgi-common.sh` + `source cgi-trust.sh` with single `source cgi-lib.sh`; replace 6-line cert/trust boilerplate with `cgi_require_trusted`
- [ ] T010 [P] [US1] Update `handlers/head.get.sh`: same migration as T009
- [ ] T011 [P] [US1] Update `handlers/bundle.post.sh`: same migration as T009
- [ ] T012 [P] [US1] Update `handlers/spool.get.sh`: same migration as T009
- [ ] T013 [US1] Update `handlers/drop-proxy.sh`: source `cgi-lib.sh` (single source line); replace cert/trust boilerplate with `cgi_require_trusted`; keep the WebDAV proxy logic intact — this is the most complex handler (166L), verify the 403 CN-mismatch path still works
- [ ] T014 [US1] Update `handlers/nncp-receive.post.sh`: source `cgi-lib.sh`; replace inline `DATA_DIR` resolution with `resolve_data_dir`; keep the nncp-toss dispatch and exit-code mapping (0→202, 1/2→502) unchanged
- [ ] T015 [US1] Update `handlers/cert-echo.get.sh`: source `cgi-lib.sh` (was only sourcing cgi-trust.sh); replace inline `echo "Status:"` / `echo "Content-Type:"` with `cgi_header()` / `cgi_error()` calls
- [ ] T016 [P] [US1] Update `scripts/on-discovery.d/00-validate.sh`: replace inline `DATA_DIR` resolution with `resolve_data_dir` from cgi-lib.sh
- [ ] T017 [P] [US1] Update `scripts/on-discovery.d/10-trust-add.sh`: same as T016
- [ ] T018 [P] [US1] Update `scripts/on-discovery.d/90-log.sh`: replace buggy `DATA_DIR="${DATA_DIR:-$(dirname …)}/../../../..}"` (trailing `}`) with `resolve_data_dir` — this fixes the latent bug from research R3
- [ ] T019 [P] [US1] Update `scripts/on-discovery.d/20-nncp-register.sh`: source cgi-lib.sh (was sourcing both); use `resolve_data_dir`
- [ ] T020 [P] [US1] Update `scripts/on-discovery.d/_run-parts.sh`: source cgi-lib.sh (was sourcing cgi-trust.sh only); keep peer_extract / peer_extract_stage calls intact
- [ ] T021 [P] [US1] Update `scripts/log-capture.sh`: replace inline CN extraction (line 30-31) with `extract_cn` from cgi-lib.sh
- [ ] T022 [P] [US1] Update `scripts/trust-host.sh`: replace inline CN extraction (line 22) with `extract_cn` from cgi-lib.sh
- [ ] T023 [P] [US1] Update `scripts/sync-common.sh`: replace inline CN extraction (line 40) with `extract_cn` from cgi-lib.sh; source cgi-lib.sh for the function
- [ ] T024 [US1] Remove old library files: `rm scripts/cgi-common.sh scripts/cgi-trust.sh` — verify zero references first: `grep -r 'cgi-common\|cgi-trust' --include='*.sh' scripts/ handlers/ | grep -v cgi-lib | grep -v specs/`
- [ ] T025 [US1] Run `nix-shell --run 'bats tests/'` — all tests must pass. If any test fails, fix the consumer, not the test (tests are the regression oracle).

**Checkpoint**: All handlers and discovery scripts source `cgi-lib.sh` exclusively. Old libraries removed. Full test suite green.

---

## Phase 4: User Story 2 — Developer Reads Quickly (Priority: P2)

**Goal**: Remove dead code and merge the three sync scripts into one. Reduce file count so a new developer sees fewer, clearer files.

**Independent Test**: `find source scripts handlers cli -name '*.sh' -o -name '*.d' | wc -l` — count is lower than baseline. `grep -r docker-discovery-test` returns zero hits outside `specs/`.

### Implementation for User Story 2

- [ ] T026 [US2] Remove dead code: `rm scripts/docker-discovery-test.sh` — first verify zero references: `grep -r docker-discovery-test . | grep -v specs/ | grep -v '.git/'`
- [ ] T027 [US2] Create `scripts/sync-lib.sh` by merging `scripts/sync-common.sh` + `scripts/sync-state.sh` + `scripts/sync-test.sh` into a single file with one header and all functions: `mtls_curl`, `mtls_curl_post`, `ensure_peer_host`, `apply_bundle_to_repo`, `query_spool_coverage`, `sync_state_base`, `sync_state_dir`, `compute_refs_hash`, `get_synced_hash`, `set_synced_hash`, `clear_synced_hash`, `cleanup_tmpdir`
- [ ] T028 [US2] Run `shellcheck --severity=warning scripts/sync-lib.sh` and `bash -n scripts/sync-lib.sh` — both clean
- [ ] T029 [P] [US2] Update `scripts/on-discovery.d/50-bundle-push.sh`: replace `source sync-common.sh` + `source sync-state.sh` with single `source sync-lib.sh`
- [ ] T030 [P] [US2] Update `scripts/install.sh`: replace `source sync-common.sh` (and sync-test.sh if sourced) with `source sync-lib.sh`
- [ ] T031 [P] [US2] Update `scripts/merge-spool.sh`: replace sync source(s) with `source sync-lib.sh`
- [ ] T032 [P] [US2] Update `scripts/package-common.sh`: replace sync source(s) with `source sync-lib.sh`
- [ ] T033 [US2] Remove old sync files: `rm scripts/sync-common.sh scripts/sync-state.sh scripts/sync-test.sh` — verify zero references first: `grep -r 'sync-common\|sync-state\|sync-test' --include='*.sh' scripts/ handlers/ | grep -v sync-lib | grep -v specs/`
- [ ] T034 [US2] Run `nix-shell --run 'bats tests/sync-state.bats tests/smoke.bats'` — sync tests must pass

**Checkpoint**: 4 files removed (1 dead + 3 merged into sync-lib.sh). Developer sees fewer files.

---

## Phase 5: User Story 3 — Maintainer Fixes in One Place (Priority: P3)

**Goal**: Eliminate remaining inline implementations of shared concerns. After this phase, grep for any duplicated pattern finds exactly one authoritative definition.

**Independent Test**: For each top-5 concern (cert extraction, CGI headers, path resolution, CLI curl boilerplate, sync state), grep finds exactly one definition sourced by all callers.

### Implementation for User Story 3

- [ ] T035 [US3] Audit `handlers/drop-proxy.sh` for any remaining inline `echo "Content-Type"` or `echo "Status:"` calls — replace with `cgi_header()` / `cgi_error()` from cgi-lib.sh
- [ ] T036 [P] [US3] Grep audit: `grep -rn 'openssl x509.*-subject' scripts/ handlers/ | grep -v cgi-lib | grep -v specs/` — verify only `extract_cn` in cgi-lib.sh implements CN extraction; any remaining hits must be calling `extract_cn`, not reimplementing it
- [ ] T037 [P] [US3] Grep audit: `grep -rn 'DATA_DIR=' scripts/ handlers/ | grep -v specs/` — verify all on-discovery.d scripts use `resolve_data_dir`; apache-config.sh and install.sh may keep their positional/env patterns (different context)
- [ ] T038 [P] [US3] Grep audit: `grep -rn 'SSL_CLIENT_CERT' handlers/ | grep -v cgi-lib` — verify no handler reads `SSL_CLIENT_CERT` directly (all go through `cgi_require_trusted`)
- [ ] T039 [US3] Extract `tests/helpers.bash` with shared setup: sandbox creation (`mktemp -d`), cert generation (`openssl req -x509`), and `LD_LIBRARY_PATH=""` prefix; source from `tests/smoke.bats` setup()
- [ ] T040 [US3] Run `nix-shell --run 'bats tests/'` — full suite green after all changes

**Checkpoint**: Every shared concern has exactly one definition. Maintainer edits one file.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Final validation, metrics, and cleanup

- [ ] T041 [P] Run `shellcheck --severity=warning scripts/*.sh scripts/on-discovery.d/*.sh handlers/*.sh` — zero hits across all modified files
- [ ] T042 [P] Run `bash -n` on all modified scripts — zero syntax errors
- [ ] T043 Record final line count: `find source scripts handlers cli -name '*.d' -o -name '*.sh' | xargs wc -l | tail -1` — verify ≥15% reduction vs T001
- [ ] T044 Record final file count: `find source scripts handlers cli -name '*.d' -o -name '*.sh' | wc -l` — verify ≥10% reduction vs T002
- [ ] T045 Run `nix-shell --run 'bats tests/'` — final full suite run, all green
- [ ] T046 Commit with message: `refactor(026): consolidate CGI/sync libraries, remove dead code, fix 90-log.sh DATA_DIR bug`

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — run first to establish baseline
- **Foundational (Phase 2)**: T004–T008 create `cgi-lib.sh` — BLOCKS all US1 work
- **US1 (Phase 3)**: T009–T025 migrate consumers — BLOCKS US2 (sync merge needs cgi-lib stable)
- **US2 (Phase 4)**: T026–T034 remove dead code + merge sync libs — independent of US1 but best done after (fewer files in flux)
- **US3 (Phase 5)**: T035–T040 consistency audits — depends on US1+US2 completion
- **Polish (Phase 6)**: T041–T046 final validation — depends on everything

### Within US1: Migration Order

1. T004–T008: Create cgi-lib.sh (blocking)
2. T009–T015: Migrate handlers (7 tasks, 5 parallel [P])
3. T016–T020: Migrate on-discovery.d scripts (5 tasks, all parallel [P])
4. T021–T023: Consolidate CN extraction (3 tasks, all parallel [P])
5. T024: Remove old libraries (after all consumers migrated)
6. T025: Full test suite (validation gate)

### Parallel Opportunities

- T009–T012: Four simple handler migrations — all parallel
- T016–T020: Five discovery script migrations — all parallel
- T021–T023: Three CN extraction consolidations — all parallel
- T029–T032: Four sync consumer updates — all parallel
- T036–T038: Three grep audits — all parallel

---

## Implementation Strategy

### MVP First (US1 Only)

1. T001–T003: Baseline measurement
2. T004–T008: Create cgi-lib.sh
3. T009–T025: Migrate all consumers + remove old libs + test green
4. **STOP**: Full suite green = all features preserved = MVP delivered

### Incremental Delivery

1. US1 → All features work on consolidated library (primary value)
2. US2 → Dead code removed, sync libs merged (readability)
3. US3 → Single-source audit passed (maintainability)
4. Polish → Metrics verified, committed

### Commit Strategy

One commit per phase (or per US). Each commit must have green tests:
- Commit 1: `refactor(026): create cgi-lib.sh, migrate handlers and discovery scripts`
- Commit 2: `refactor(026): merge sync libraries, remove dead code`
- Commit 3: `refactor(026): consistency audits and test helper extraction`
- Or single squash: `refactor(026): consolidate CGI/sync libraries, remove dead code`

---

## Notes

- Tests are the regression oracle — never modify a test to make it pass; fix the consumer
- Handler filenames MUST NOT change (Apache `ScriptAlias` references them)
- HTTP status codes and CGI env var names MUST NOT change (see contracts/external-interfaces.md)
- No `rm -rf` / `rm -f` / `find -delete` — plain `rm` on known files only
- The D daemon (source/*.d) is NOT modified in this feature (already lean)
