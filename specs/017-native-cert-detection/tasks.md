# Tasks: Native Peer Certificate Detection

**Input**: Design documents from `specs/017-native-cert-detection/`

**Prerequisites**: plan.md, spec.md, data-model.md, contracts/discovery.md, research.md, quickstart.md

**Tests**: Included per feature specification and project BATS convention.

**Organization**: Tasks grouped by user story to enable independent implementation and testing.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete tasks)
- **[Story]**: User story this task belongs to (US1, US2, US3)
- Exact file paths included in descriptions

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Prepare the codebase and understand existing capture/naming conventions.

- [x] T001 Read `source/trust.d` and confirm existing fingerprint, hostname, and purgatory helpers can be reused for outbound capture.
- [x] T002 Read `scripts/on-discover.sh` and `scripts/sync-common.sh` to map where `PEER_CERT_FILE` is consumed and where `grab_peer_cert` can be removed.
- [x] T003 Read `source/multicast.d` and `source/app.d` to confirm where discovery events are processed and where callback env is built.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core D infrastructure that MUST be complete before any user story can be implemented.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [x] T004 [P] Add `source/certcapture.d` (or extend `source/trust.d`) with a public function `detectPeerCertificate(string peerHost, ushort peerPort, string ourCert, string ourKey, string purgatoryDir)` that returns a struct with hostname, fingerprint, pem, and purgatory path.
- [x] T005 [P] Implement OpenSSL client TLS handshake in `source/certcapture.d` using `deimos.openssl.ssl`, `deimos.openssl.bio`, and `deimos.openssl.x509` to extract the peer's server certificate.
- [x] T006 [P] Implement PEM and fingerprint extraction in `source/certcapture.d` by reusing `x509ToPEM` and `x509Fingerprint` logic from `source/trust.d` (move helpers to a shared private module if needed).
- [x] T007 Add `captureOrFindPurgatory` in `source/trust.d` that writes `<hostname>.<fingerprint>.crt` to the purgatory directory, or returns the existing path if the same file already exists.
- [x] T008 Wire `detectPeerCertificate` into `source/multicast.d` so that `processAnnouncement()` calls it before spawning the callback and updates `PEER_CERT_FILE` in the callback environment.
- [x] T009 Ensure `source/multicast.d` still invokes the callback even when capture fails, but logs the failure and leaves `PEER_CERT_FILE` empty.

**Checkpoint**: D can capture a peer certificate during discovery and knows where to store it.

---

## Phase 3: User Story 1 - Automatic peer certificate capture on discovery (Priority: P1) 🎯 MVP

**Goal**: When a peer is discovered, the server captures its certificate and stores it in purgatory without relying on external scripts.

**Independent Test**: Run two server instances, trigger discovery, and verify the purgatory directory contains the peer's certificate.

### Tests for User Story 1

- [x] T010 [P] [US1] Add BATS test in `tests/smoke.bats` that starts two servers and asserts that `<data-dir>/purgatory/<peer-host>.<fingerprint>.crt` exists after discovery.

### Implementation for User Story 1

- [x] T011 [US1] Complete `detectPeerCertificate` in `source/certcapture.d` so that the returned struct includes the actual purgatory path written by `captureOrFindPurgatory`.
- [x] T012 [US1] Update `source/multicast.d` to set `PEER_CERT_FILE` from the capture result and log the captured hostname, fingerprint, and path.
- [x] T013 [US1] Add `README.md` / `quickstart.md` note that manual certificate extraction is no longer required.

**Checkpoint**: User Story 1 is independently testable: two servers discover each other and a certificate appears in purgatory.

---

## Phase 4: User Story 2 - Deduplicated purgatory storage (Priority: P2)

**Goal**: The same certificate is not written multiple times; the purgatory directory does not fill with duplicates.

**Independent Test**: Trigger discovery of the same peer twice and verify the purgatory directory contains exactly one file for that peer hostname.

### Tests for User Story 2

- [x] T014 [P] [US2] Add BATS test in `tests/smoke.bats` that triggers discovery twice and asserts the purgatory directory has exactly one `<hostname>.*.crt` file.

### Implementation for User Story 2

- [x] T015 [US2] Verify `captureOrFindPurgatory` in `source/trust.d` returns the existing path when the same hostname+fingerprint file is already present, so the write is idempotent.
- [x] T016 [US2] If not already done, update `captureOrFindPurgatory` to overwrite the same file (same hostname+fingerprint) without creating a second file with a timestamp suffix or different name.

**Checkpoint**: User Story 2 is independently testable: repeated discovery of the same peer leaves the purgatory directory unchanged (one file).

---

## Phase 5: User Story 3 - Clear hostname identity for captured certificates (Priority: P3)

**Goal**: Captured certificates are stored by hostname and can be promoted to the trust directory to enable mTLS sync.

**Independent Test**: After discovery, move the captured purgatory file to the trust directory under the same hostname and verify the next inbound connection is accepted.

### Tests for User Story 3

- [x] T017 [P] [US3] Add BATS test in `tests/smoke.bats` that copies the captured purgatory certificate to the trust directory and then performs a successful mTLS `GET` request.

### Implementation for User Story 3

- [x] T018 [US3] Confirm the captured filename in `source/trust.d` is exactly `<hostname>.<fingerprint>.crt` and the hostname matches the peer's certificate CN.
- [x] T019 [US3] Update `scripts/trust-host.sh` (if it exists) to support moving a purgatory file of the form `<hostname>.<fingerprint>.crt` to the trust directory as `<hostname>.crt`.

**Checkpoint**: User Story 3 is independently testable: promoting a captured certificate to the trust store makes the peer trusted.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Clean up callback scripts and documentation now that D handles capture.

- [x] T020 [P] Remove `grab_peer_cert` and cert-extraction fallback from `scripts/on-discover.sh` and `scripts/sync-common.sh`; rely on `PEER_CERT_FILE` provided by the server.
- [x] T021 [P] Update `README.md` to remove manual `openssl s_client` instructions and document the new automatic capture behavior.
- [x] T022 [P] Update `specs/017-native-cert-detection/quickstart.md` if implementation details changed during coding.
- [x] T023 Run `just test` (or the relevant filtered BATS tests) and ensure all new and existing tests pass.
- [x] T024 Run `shellcheck` on modified shell scripts.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — can start immediately.
- **Foundational (Phase 2)**: Depends on Setup. Blocks all user stories.
- **User Stories (Phase 3-5)**: All depend on Foundational. Can run sequentially in priority order or in parallel once the capture API is stable.
- **Polish (Phase 6)**: Depends on all user stories.

### User Story Dependencies

- **US1 (P1)**: Can start after Foundational. No dependencies on other stories.
- **US2 (P2)**: Can start after Foundational and US1 capture logic is stable.
- **US3 (P3)**: Can start after Foundational; requires US1's capture path to be settled.

### Within Each User Story

- Tests written before implementation (if using TDD).
- D capture function before multicast wiring.
- Multicast wiring before callback simplification.
- Story test passes before moving on.

### Parallel Opportunities

- T001, T002, T003 (Phase 1) can run in parallel.
- T004-T007 (Phase 2 D capture internals) can run in parallel.
- T010 and T011 (US1 test and implementation) can be worked in parallel by different people if the API is agreed.
- T020-T022 (Polish) can run in parallel once the behavior is locked.

---

## Parallel Example: User Story 1

```bash
# Developer A: integration test
Task: T010 Add BATS test in tests/smoke.bats for peer certificate capture

# Developer B: capture wiring
Task: T011 Complete detectPeerCertificate in source/certcapture.d
Task: T012 Update source/multicast.d to set PEER_CERT_FILE from capture result
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1 (read existing code).
2. Complete Phase 2 (D capture function + multicast wiring).
3. Complete Phase 3 (US1 test + logging + docs).
4. **STOP and VALIDATE**: Run the US1 BATS test and confirm a certificate is captured.

### Incremental Delivery

1. Setup + Foundational → D can capture peer certificates.
2. US1 → Automatic capture works end-to-end.
3. US2 → Deduplication verified.
4. US3 → Trust promotion verified.
5. Polish → Shell scripts cleaned up, docs updated, full test suite green.

---

## Notes

- All shell-side changes should be minimal: remove `grab_peer_cert` and use the env var the server now provides.
- Keep the callback script manually invokable for operators who want to pass `PEER_CERT_FILE` themselves.
- No CA infrastructure: continue using self-signed certificates with hostname-derived CN.
- The existing purgatory filename format `<hostname>.<fingerprint>.crt` already prevents fingerprint duplicates; this feature reuses that format.
