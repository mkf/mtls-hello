# Tasks: Hostname-Matched Certificate Trust

**Input**: Design documents from `/specs/004-hostname-cert-trust/`

**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md, contracts/

**Tests**: BATS end-to-end tests are this project's established verification convention (features 001–003). Tests are included for each user story and must be written before implementation.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete tasks)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

- Single project: `source/`, `tests/`, `scripts/` at repository root (per plan.md structure).

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Baseline and operator helper skeleton

- [x] T001 Verify baseline: run `just test` and confirm all existing tests still pass on branch `004-hostname-cert-trust` before any changes
- [x] T002 [P] Create `scripts/trust-host.sh` (chmod +x) as a skeleton for the certificate promotion helper

**Checkpoint**: Baseline is green; helper script skeleton exists

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure that MUST be complete before ANY user story can be implemented

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [x] T003 Extend `ServerConfig` and `parseArgs` in `source/app.d` with `--trust-dir` (default `certs/hosts`) and `--purgatory-dir` (default `certs/purgatory`)
- [x] T004 Create `source/trust.d` with `TrustConfig` struct and `hostnameFromCertificate` helper (subject CN, or first DNS SAN)
- [x] T005 [P] Implement `loadTrustedCertFingerprint` in `source/trust.d` — read `<trustDir>/<hostname>.crt`, validate it is not expired, and return the SHA-256 fingerprint
- [x] T006 [P] Implement `capturePurgatory` in `source/trust.d` — write a presented certificate PEM to `<purgatoryDir>/<hostname>.<sha256>.crt`, overwriting an existing identical file so capture is idempotent
- [x] T007 Implement `evaluateTrust` in `source/trust.d` — combine hostname lookup, fingerprint match, and validity to return `trusted`/`unknown`/`mismatch`/`expired`/`invalidName`
- [x] T008 Research and implement access to the presented client certificate from the vibe.d TLS/HTTP layer in `source/trust.d`; expose the certificate as a PEM string for evaluation
- [x] T009 Change `buildTLSContext` in `source/app.d` to use `peerValidationMode = requireCert | checkCert` (no `checkTrust`) and wire `evaluateTrust` to be called on every client-authenticated connection
- [x] T010 Implement trust-decision logging in `source/app.d` or `source/trust.d` with hostname, fingerprint, and reason (including purgatory path when captured)

**Checkpoint**: Foundation ready — the server can extract a client certificate, evaluate it against the trust store, capture unknowns, and log the decision

---

## Phase 3: User Story 1 - Hostname-Matched Certificate Trust (Priority: P1) 🎯 MVP

**Goal**: A peer is trusted only when its certificate is present in the local trust store under the matching hostname and matches the presented certificate; no first-use trust.

**Independent Test**: Start the server with a trust store containing the test client cert under its CN; connect with the same cert and verify acceptance, then connect with a missing or mismatched cert and verify rejection.

### Tests for User Story 1 (write FIRST — must fail) ⚠️

- [x] T011 [P] [US1] Add BATS test to `tests/smoke.bats`: a peer presenting a certificate that is present in the trust store under the matching hostname is accepted
- [x] T012 [P] [US1] Add BATS test to `tests/smoke.bats`: a peer with no matching trust-store entry is rejected
- [x] T013 [P] [US1] Add BATS test to `tests/smoke.bats`: a peer presenting a different certificate that claims the same hostname is rejected (mismatch)

### Implementation for User Story 1

- [x] T014 [US1] Update `start_server` in `tests/smoke.bats` to create a temporary trust directory containing `certs/certs/client.crt` under its CN (`test-client.crt`) and pass `--trust-dir`/`--purgatory-dir` to the server
- [x] T015 [US1] Adapt legacy feature-001 trust tests in `tests/smoke.bats` to the new model (e.g., untrusted CA cert is still rejected because it is not in the trust store)
- [x] T016 [US1] Implement server-side trust enforcement: accept the HTTP request only if `evaluateTrust` returns `trusted`; otherwise reject before any handler runs
- [x] T017 [US1] Run `just build` then `just test`; verify the new US1 tests and all prior tests pass

**Checkpoint**: User Story 1 is fully functional — explicit per-hostname trust is enforced and all legacy tests remain green

---

## Phase 4: User Story 2 - Purgatory Quarantine for Unknown Peers (Priority: P2)

**Goal**: Rejected, not-yet-trusted peers have their certificates captured into a purgatory directory for operator review; presence in purgatory confers no trust.

**Independent Test**: Connect with a brand-new self-signed certificate; verify the connection is rejected and the certificate appears in `certs/purgatory/`; verify repeated attempts do not duplicate the entry and that the certificate in purgatory is not trusted.

### Tests for User Story 2 (write FIRST — must fail) ⚠️

- [x] T018 [P] [US2] Add BATS test to `tests/smoke.bats`: an unknown peer's certificate is rejected and captured to the purgatory directory
- [x] T019 [P] [US2] Add BATS test to `tests/smoke.bats`: repeated connection with the same unknown certificate does not create duplicate purgatory entries
- [x] T020 [P] [US2] Add BATS test to `tests/smoke.bats`: a certificate present only in purgatory does not allow a trusted connection

### Implementation for User Story 2

- [x] T021 [US2] Wire purgatory capture for `unknown` and `mismatch` decisions into `source/trust.d` so every rejected peer is captured
- [x] T022 [US2] Ensure purgatory capture happens before the connection/request is rejected so the certificate is preserved
- [x] T023 [US2] Add log lines in `source/trust.d` for `unknown`/`mismatch` decisions including the purgatory path
- [x] T024 [US2] Run `just build` then `just test`; verify the US2 purgatory tests pass

**Checkpoint**: User Stories 1 AND 2 work — trusted peers are accepted, unknown peers are quarantined, and purgatory entries are never trusted

---

## Phase 5: User Story 3 - Onboarding Documentation (Priority: P3)

**Goal**: An operator-facing guide and helper script show how to obtain a peer's self-signed certificate and make it trusted locally.

**Independent Test**: Follow the onboarding doc and helper script in a BATS test: generate a fresh self-signed cert, promote it, and verify a connection is accepted.

### Tests for User Story 3 (write FIRST — must fail) ⚠️

- [x] T025 [P] [US3] Add BATS test to `tests/smoke.bats` that follows the onboarding flow: generate a fresh self-signed cert with a CN, promote it via `scripts/trust-host.sh`, and verify the connection is accepted

### Implementation for User Story 3

- [x] T026 [US3] Implement `scripts/trust-host.sh`: validate that the certificate's CN/SAN matches the target hostname, then copy it to `<trustDir>/<hostname>.crt`
- [x] T027 [US3] Finalize `specs/004-hostname-cert-trust/quickstart.md` so every step matches the implemented onboarding flow and helper script
- [x] T028 [US3] Run `just build` then `just test`; verify the onboarding test passes

**Checkpoint**: All three user stories work — the onboarding doc and helper script are usable, verified by an automated test

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Improvements that affect multiple user stories

- [x] T029 [P] Validate `specs/004-hostname-cert-trust/quickstart.md` end-to-end by manually following the steps with a fresh self-signed cert
- [x] T030 Cross-check `contracts/trust.md` and `contracts/cli.md` against the implementation in `source/app.d`, `source/trust.d`, and `scripts/trust-host.sh`
- [x] T031 Run `just test` one final time; confirm no leftover `mtls-hello` processes or temp files; confirm `git status` shows only intended changes
- [x] T032 [P] Update `specs/004-hostname-cert-trust/quickstart.md` Troubleshooting section with any new failure modes discovered during implementation

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — can start immediately (T001, T002 in parallel)
- **Foundational (Phase 2)**: Depends on Setup; BLOCKS all user stories
- **US1 (Phase 3)**: Depends on Foundational (T003–T010)
- **US2 (Phase 4)**: Depends on Foundational AND US1 (T014 provides the test-server trust setup that US2 tests also need)
- **US3 (Phase 5)**: Depends on Foundational AND US1 (same test-server helper dependency)
- **Polish (Phase 6)**: Depends on US1 + US2 + US3

### User Story Dependencies

- **US1 (P1)**: Can start after Foundational; no dependencies on other stories
- **US2 (P2)**: Can start after Foundational + US1; uses the same trust/purgatory directories but does not depend on US3
- **US3 (P3)**: Can start after Foundational + US1; provides the helper script and doc; does not depend on US2

### Within Each User Story

- Tests FIRST (must fail) → implementation → tests green
- `start_server` helper (T014) must land before US1/US2/US3 tests that rely on the default trust store
- Core trust enforcement (T016) before T017 verification
- Promotion helper (T026) before T028 onboarding verification

### Parallel Opportunities

- T001 ∥ T002 (Setup)
- T005 ∥ T006 (trust store read + purgatory capture, different functions in `source/trust.d`)
- T011 ∥ T012 ∥ T013 (US1 tests, different test cases)
- T018 ∥ T019 ∥ T020 (US2 tests)
- T025 (US3 onboarding test) can run in parallel with US2 tests once T014 is done
- T029 ∥ T032 (Polish docs, different files)

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (T001, T002)
2. Complete Phase 2: Foundational (T003–T010)
3. Complete Phase 3: User Story 1 (T011–T017)
4. **STOP and VALIDATE**: per-hostname trust enforced; legacy tests green; `just test` passes
5. Deploy/demo if ready

### Incremental Delivery

1. Setup + Foundational → foundation ready
2. US1 (hostname trust) → test → deploy (MVP!)
3. US2 (purgatory) → test → quarantine unknown peers
4. US3 (onboarding doc + helper) → test → usable operator workflow
5. Polish (docs validation, cross-checks)

### Notes

- Feature 002's `certs/hosts/<hostname>.crt` convention (from `contracts/callback.md`) is the default trust store layout; feature 004 formalizes and enforces it for inbound trust.
- The TLS client-verification mode changes from `requireCert|checkCert|checkTrust` to `requireCert|checkCert` so unknown self-signed certificates can be observed and captured. This is the foundational design decision in `research.md` and must be implemented in T009.
- The `start_server` test helper must be updated in T014 so every test that uses the test client certificate also has it in the trust store; otherwise the legacy 001/002/003 BATS tests will fail under the new trust model.
- Commit after each task or logical group; stop at any checkpoint to validate independently.
