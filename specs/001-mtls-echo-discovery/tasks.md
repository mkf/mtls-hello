# Tasks: Mutual-TLS Echo Endpoint with LAN Discovery

**Input**: Design documents from `/specs/001-mtls-echo-discovery/`

**Prerequisites**: plan.md (required), spec.md (user stories), research.md (build env decisions), data-model.md, contracts/

**Tests**: BATS e2e tests are included per the spec's acceptance scenarios (each story is independently testable).

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

- **Single project**: `source/`, `tests/`, `scripts/` at repository root (per plan.md structure)

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization and build environment

- [x] T001 Create D package recipe `dub.json` with `vibe-d:http ~>0.10.0` and target `executable`
- [x] T002 Pin dependency versions in `dub.selections.json` (vibe-d 0.10.3, vibe-http 1.5.1, vibe-core 2.14.0, vibe-stream 1.4.1, deimos openssl 3.4.0)
- [x] T003 Create Guix dev shell `guix.scm` with dub, ldc, gcc-toolchain, openssl, pkg-config, curl, bats, nss-certs (research.md decision: real OpenSSL required — host LibreSSL breaks deimos bindings)
- [x] T004 Create `justfile` with build / run / gen-certs / test / clean recipes, all invoking `guix shell -f guix.scm`
- [x] T005 [P] Create `.gitignore` excluding `certs/` (private keys), `.dub/`, `*.o`, `*.a`, built binary `mtls-hello`

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Test PKI + build-env verification — MUST complete before any user story tests run

**⚠️ CRITICAL**: No user story work can be verified until this phase is complete

- [x] T006 Create certificate generation script `scripts/gen_certs.sh` producing `certs/ca.crt`, `certs/certs/server.crt`, `certs/private/server.key`, `certs/certs/client.crt`, `certs/private/client.key`, `certs/client.p12` (server cert with SAN localhost/127.0.0.1/::1, client cert with `clientAuth` EKU)
- [x] T007 Verify build environment: `guix shell -f guix.scm -- dub build --compiler=ldc2 --skip-registry=standard` resolves the pinned deps and compiles (research.md: if `vibe-d:http` still fails to resolve, generate `~/.dub/packages/local-packages.json` from the existing cache)
- [x] T008 Create BATS harness skeleton `tests/smoke.bats` with `setup_file` (generate certs, build, start server on port 18443, wait for TCP accept) and `teardown_file` (kill server)

**Checkpoint**: Foundation ready — user story implementation can now begin

---

## Phase 3: User Story 1 - Echo a URL Path to an Authenticated Client (Priority: P1) 🎯 MVP

**Goal**: Mutual-TLS HTTPS endpoint that echoes each path segment as text/plain, rejecting clients without a trusted certificate.

**Independent Test**: Start the server, request `/hello` with a valid client cert → body `hello`, `text/plain`; without a cert or with an untrusted cert → TLS handshake fails.

### Tests for User Story 1

> **NOTE: Write these tests FIRST, ensure they FAIL before implementation**

- [x] T009 [P] [US1] BATS test: no client certificate → handshake rejected in `tests/smoke.bats`
- [x] T010 [P] [US1] BATS test: client cert from untrusted CA → handshake rejected in `tests/smoke.bats`
- [x] T011 [P] [US1] BATS test: valid client cert → body equals path segment (`hello%20world` → `hello world`) in `tests/smoke.bats`
- [x] T012 [P] [US1] BATS test: response `Content-Type` is `text/plain` in `tests/smoke.bats`

### Implementation for User Story 1

- [x] T013 [P] [US1] Implement `buildTLSContext` in `source/app.d` using `OpenSSLContext(TLSContextKind.server)` with `useCertificateChainFile`, `usePrivateKeyFile`, `useTrustedCertificateFile`, and `peerValidationMode = requireCert | checkCert | checkTrust` (research.md: do NOT use `trustedCert` — its `checkPeer` flag is wrong for server-side client-cert verification)
- [x] T014 [US1] Implement `buildRouter` (`GET /:whatever` → `res.writeBody(req.params["whatever"], "text/plain; charset=utf-8")`) and `buildServerSettings` (bind `::1` + `127.0.0.1`) in `source/app.d`
- [x] T015 [US1] Wire `main` in `source/app.d`: build TLS → router → settings → `listenHTTP` → `runEventLoop`, with startup `logInfo` lines

**Checkpoint**: User Story 1 fully functional — `curl` against a live server passes all four BATS tests

---

## Phase 4: User Story 2 - Instances Discover Each Other on a LAN (Priority: P2)

**Goal**: Instances announce presence via UDP multicast and log discovered peers.

**Independent Test**: Start two instances on one host (loopback multicast enabled); each reports the other's port within one announcement interval.

### Tests for User Story 2

- [x] T016 [P] [US2] BATS test: start two instances (ports 18443 + 18444), wait ~7 s, assert each captured log contains `[discovery] peer at ... on port <other>` in `tests/smoke.bats`

### Implementation for User Story 2

- [x] T017 [P] [US2] Define `MulticastConfig` (group 239.255.42.42, port 4242, 5 s interval, enabled) and `startMulticastDiscovery` (daemon `Thread`) in `source/multicast.d`
- [x] T018 [US2] Implement multicast worker socket setup in `source/multicast.d`: UDP socket, `SO_REUSEADDR`, bind `0.0.0.0:port`, join group via raw `setsockopt` `IP_ADD_MEMBERSHIP` (Linux constant 35, local `ip_mreq`), `IP_MULTICAST_TTL=1` (33), `IP_MULTICAST_LOOP=1` (34), `RCVTIMEO` 500 ms
- [x] T019 [US2] Implement announce loop in `source/multicast.d`: every interval send JSON `{"service":"mtls-hello","port":<httpPort>}` to the group
- [x] T020 [US2] Implement receive path in `source/multicast.d`: parse JSON, ignore non-`mtls-hello`/malformed payloads, ignore own-port announcements, log valid peers as `[discovery] peer at <addr>:<src> -> mtls-hello on port <peer>`; log socket errors to stderr without stopping HTTP server
- [x] T021 [US2] Register `startMulticastDiscovery(settings.port, cfg)` in `source/app.d` main after `listenHTTP`

**Checkpoint**: User Stories 1 AND 2 both work — two-instance discovery test passes

---

## Phase 5: User Story 3 - Operator Controls Service Behavior via Configuration (Priority: P3)

**Goal**: Operator can set port, certificate paths, and discovery settings at startup without rebuilding.

**Independent Test**: Start with a custom port and with `--no-multicast`; server listens on the custom port and produces no discovery output.

### Tests for User Story 3

- [x] T022 [P] [US3] BATS test: server started with `--no-multicast` produces no `[discovery]` output in `tests/smoke.bats`
- [x] T023 [P] [US3] BATS test: server started on a custom port accepts requests on that port in `tests/smoke.bats`

### Implementation for User Story 3

- [x] T024 [US3] Implement `ServerConfig` struct (port, certFile, keyFile, clientCA, multicast) in `source/app.d`
- [x] T025 [US3] Implement `parseArgs` in `source/app.d`: positional port/cert/key/clientCA until first `--`, then flags `--multicast-group=`, `--multicast-port=`, `--multicast-interval=`, `--no-multicast`
- [x] T026 [US3] Update `main` in `source/app.d` to consume `ServerConfig` from `parseArgs` (replaces hardcoded defaults)

**Checkpoint**: All user stories functional — configuration tests pass

---

## Phase N: Polish & Cross-Cutting Concerns

**Purpose**: Documentation and final validation

- [x] T027 [P] Run `quickstart.md` end-to-end (gen-certs → build → run → curl checks → two-instance discovery → `just test`)
- [x] T028 Verify `AGENTS.md` plan reference points to `specs/001-mtls-echo-discovery/plan.md`
- [x] T029 Final review: no secrets committed (`certs/` ignored), clean working tree, full suite green

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — can start immediately
- **Foundational (Phase 2)**: Depends on Setup — BLOCKS all user stories (PKI + build-env)
- **User Stories (Phase 3+)**: Depend on Phase 2; run in priority order (P1 → P2 → P3)
- **Polish (Final Phase)**: Depends on all user stories complete

### User Story Dependencies

- **User Story 1 (P1)**: Independent — mTLS echo needs only TLS context + router + settings
- **User Story 2 (P2)**: Independent of US1 code-wise (separate module `source/multicast.d`); registration line in `source/app.d` is additive
- **User Story 3 (P3)**: Touches `source/app.d` (parseArgs) — do after US1/US2 wiring to avoid same-file churn

### Within Each User Story

- Tests FIRST (write failing tests before implementation)
- Implementation → integration → checkpoint validation

### Parallel Opportunities

- All `[P]` tests within a story can run in parallel
- `T013` (TLS) and `T014` (router) are parallel; `T015` (main wiring) depends on both
- US2 module work (`T017`–`T020`, `source/multicast.d`) is file-independent of US1 work (`source/app.d`) and can proceed in parallel

---

## Parallel Example: User Story 1

```bash
# Launch all four BATS tests together (different assertions in tests/smoke.bats):
Task: "T009 no-cert rejected"
Task: "T010 untrusted-CA rejected"
Task: "T011 path echo"
Task: "T012 content-type"

# Launch TLS context and router together:
Task: "T013 buildTLSContext in source/app.d"
Task: "T014 buildRouter + buildServerSettings in source/app.d"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (PKI + build env — critical)
3. Complete Phase 3: User Story 1 (mTLS echo endpoint)
4. **STOP and VALIDATE**: `just test` — four mTLS BATS tests green
5. Deploy/demo: `just run -- 8443` + curl with client cert

### Incremental Delivery

1. Setup + Foundational → foundation ready
2. US1 (mTLS echo) → test → demo (MVP)
3. US2 (discovery) → test (two instances) → demo
4. US3 (configuration) → test → demo
5. Polish: quickstart validation, docs, final commit

---

## Notes

- **[P]** tasks = different files, no dependencies
- **[Story]** label maps task to the user story for traceability
- Commit after each task or logical group
- Verify tests fail before implementing (TDD per story)
- The Guix build-env quirk (LDC `cc` shim + `--linker=bfd`, registry `--skip-registry=standard`) is resolved in research.md — apply it in the justfile recipes (T004)
