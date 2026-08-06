# Tasks: Apache HTTP Server Backend

**Input**: Design documents from `/specs/018-apache-http-server/`

**Prerequisites**: plan.md, spec.md, data-model.md, contracts/, research.md, quickstart.md

**Tests**: Included per feature specification and project BATS convention.

**Organization**: Tasks grouped by user story to enable independent implementation and testing.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete tasks)
- **[Story]**: User story this task belongs to (US1, US2, US3, US4)
- Exact file paths included in descriptions

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Prepare the codebase and understand how to replace the vibe.d HTTP server with Apache + CGI.

- [X] T001 Read `source/app.d` and identify all HTTP server code, endpoint registration, and TLS context setup that must be removed or moved.
- [X] T002 Read `source/trust.d` and confirm that fingerprint, hostname, and purgatory helpers can be reused by CGI handlers.
- [X] T003 Read `source/multicast.d` and confirm that discovery does not depend on the HTTP server implementation.
- [X] T004 Read `handlers/*.sh` and `scripts/*.sh` to map which scripts are invoked via HTTP and which are invoked via CLI.
- [X] T005 Verify Apache is available on the development host and on Debian/Arch Docker images, and record the exact binary name in each environment.
- [X] T006 Verify `curl` can make HTTPS requests with a self-signed client certificate on the host and in the test containers.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure that MUST be complete before any user story can be implemented.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [X] T007 Create `config/apache-site.conf.in` template with `SSLVerifyClient optional_no_ca`, `SSLOptions +StdEnvVars +ExportCertData`, `ScriptAlias` for handlers, and `SetEnv` directives for `MTLS_DATA_DIR`, `MTLS_TRUST_DIR`, `MTLS_PURGATORY_DIR`, `MTLS_HANDLERS_DIR`, `MTLS_HOST_NAME`, and `MTLS_SCRIPT_TIMEOUT`.
- [X] T008 [P] Create `config/apache-httpd.conf.in` template that provides a self-contained `ServerRoot`, `Listen`, `PidFile`, `LoadModule` directives, `TypesConfig` (with a minimal fallback), and `Include` of the site config.
- [X] T009 [P] Create `scripts/apache-config.sh` that generates the concrete `httpd.conf` and `site.conf` from the templates, a data directory, a port, and server certificate/key paths.
- [X] T010 [P] Create `scripts/apache-port-helper.sh` that reads the OS-assigned port from Apache logs or a ready-file and writes it to `<data-dir>/apache/port`.
- [X] T011 [P] Add `scripts/cgi-trust.sh` containing reusable shell functions that parse `SSL_CLIENT_CERT`, `SSL_CLIENT_VERIFY`, and `SSL_CLIENT_S_DN_CN` from the CGI environment and evaluate trust against the trust directory by fingerprint.
- [X] T012 [P] Add `scripts/cgi-capture.sh` containing reusable shell functions that capture an untrusted client certificate to the purgatory directory using the existing filename scheme `<hostname>.<fingerprint>.crt`.
- [X] T013 Create `patches/apache-mod_ssl-optional_no_ca-cert.patch` as a no-op informational patch documenting the upstream location where `SSL_CLIENT_CERT` export is controlled.
- [X] T014 Run `shellcheck` on all new shell scripts in `scripts/` and `handlers/` and fix any warnings.

**Checkpoint**: Apache can be configured, the CGI environment can be parsed, and trust/capture helpers are ready.

---

## Phase 3: User Story 1 - Apache handles mutual TLS and exposes client certificates (Priority: P1) 🎯 MVP

**Goal**: Apache requests client certificates without terminating the handshake for self-signed certs, and `SSLOptions +ExportCertData` exposes the full PEM certificate to backend scripts.

**Independent Test**: Start Apache, connect with a self-signed client certificate, and verify that a backend handler logs the certificate fingerprint and sees `SSL_CLIENT_VERIFY`.

### Tests for User Story 1

- [X] T015 [P] [US1] Add BATS test `@test "Apache requests client cert and exposes it to CGI"` in `tests/apache.bats` that starts Apache, sends an HTTPS request with a self-signed client cert, and checks that the handler receives `SSL_CLIENT_CERT` and a non-empty fingerprint.
- [X] T016 [P] [US1] Add BATS test `@test "Apache accepts handshake for self-signed client without CA validation"` in `tests/apache.bats` that verifies the TLS connection completes even though the client cert is not in any CA file.

### Implementation for User Story 1

- [X] T017 [US1] Update `config/apache-site.conf.in` and `scripts/apache-config.sh` to use `SSLOptions +StdEnvVars +ExportCertData` and load the system `mod_ssl` module.
- [X] T018 [US1] Create `handlers/cert-echo.get.sh` handler that writes `SSL_CLIENT_VERIFY`, `SSL_CLIENT_S_DN_CN`, and the certificate fingerprint to the response body for testing.
- [X] T019 [US1] Add `scripts/start-apache.sh` helper that generates the config, starts Apache, and waits for the port file.
- [X] T020 [US1] Run the US1 BATS tests and verify they pass on the development host or in a Docker container with Apache available.

**Checkpoint**: User Story 1 is independently testable: Apache passes the full self-signed client cert to a CGI handler.

---

## Phase 4: User Story 2 - Untrusted certificates are captured in purgatory (Priority: P1)

**Goal**: When a client presents an unknown or untrusted certificate, the handler captures it in purgatory and rejects the request at the application layer.

**Independent Test**: Connect with an untrusted client certificate, verify the certificate is written to `<data-dir>/purgatory/<hostname>.<fingerprint>.crt`, and verify promoting it to the trust directory makes the client accepted.

### Tests for User Story 2

- [X] T021 [P] [US2] Add BATS test `@test "Apache backend captures untrusted client certificate"` in `tests/apache.bats` that connects with an untrusted cert and asserts the purgatory file exists.
- [X] T022 [P] [US2] Add BATS test `@test "Promoted captured certificate grants trust under Apache"` in `tests/apache.bats` that copies the captured certificate to the trust directory and asserts the next request succeeds.
- [X] T023 [P] [US2] Add BATS test `@test "Repeated untrusted connections leave exactly one purgatory file"` in `tests/apache.bats` that connects multiple times with the same untrusted cert and verifies only one purgatory file exists.

### Implementation for User Story 2

- [X] T024 [US2] Integrate `scripts/cgi-trust.sh` and `scripts/cgi-capture.sh` into a common request handler wrapper so every HTTP handler evaluates trust before running the business logic.
- [X] T025 [US2] Update `handlers/cert-echo.get.sh` (or a new default handler) to reject untrusted clients with HTTP 401 and capture the certificate in purgatory.
- [X] T026 [US2] Verify that the capture helper is deterministic: repeated untrusted connections overwrite the same purgatory file instead of creating duplicates.
- [X] T027 [US2] Add a fallback identifier in `scripts/cgi-capture.sh` for certificates whose hostname cannot be extracted (e.g., use `unknown.<fp>` and log a warning).

**Checkpoint**: User Story 2 is independently testable: untrusted certs are captured and promoted certs grant trust.

---

## Phase 5: User Story 3 - Apache is installed and configured by the project (Priority: P2)

**Goal**: Installing the project on Debian or Arch installs Apache, enables the required modules, and configures a site for the project.

**Independent Test**: Install the project in a clean container, make an HTTPS request to the default endpoint, and verify Apache is running and responding.

### Tests for User Story 3

- [ ] T028 [P] [US3] Add BATS test `@test "install script installs Apache and starts a reachable server"` in `tests/apache.bats` that runs `scripts/install.sh` in a fresh data directory and asserts the server responds with a trusted client certificate.
- [ ] T029 [P] [US3] Add BATS test `@test "Debian package declares Apache dependency"` in `tests/smoke.bats` that builds the Debian package and checks `Depends` includes `apache2`.
- [ ] T030 [P] [US3] Add BATS test `@test "Arch package declares Apache dependency"` in `tests/smoke.bats` that builds the Arch package and checks `depends` includes `apache`.

### Implementation for US3

- [X] T031 [US3] Update `scripts/install.sh` to install `apache2` on Debian/Ubuntu and `apache` on Arch using the system package manager (or skip if already installed), and enable `mod_ssl`, `mod_cgid`, and `mod_alias`.
- [ ] T032 [US3] Update `scripts/install-service.sh` to create a systemd user unit that starts Apache with the generated site config instead of running the D binary.
- [ ] T033 [US3] Update `scripts/package-debian.sh` to add `apache2` to the package `Depends` field.
- [ ] T034 [US3] Update `scripts/package-arch.sh` to add `apache` to the package `depends` array.
- [X] T035 [US3] Update `scripts/package-common.sh` to stage the Apache site config template and helper scripts into the package tree.
- [ ] T036 [US3] Update `docker/Dockerfile.debian` and `docker/Dockerfile.arch` to install Apache so package builds and CI tests have the dependency available.

**Checkpoint**: User Story 3 is independently testable: clean install yields a running Apache-backed server.

---

## Phase 6: User Story 4 - Existing endpoints continue to work after migration (Priority: P2)

**Goal**: All current HTTP endpoints (echo, bundle spool, spool query, etc.) behave the same under Apache as they did under vibe.d.

**Independent Test**: Run the existing BATS tests for prior features and verify they pass after the migration.

### Tests for User Story 4

- [ ] T037 [P] [US4] Add BATS regression test `@test "Apache serves the echo endpoint"` in `tests/apache.bats` that calls `/hello` with a trusted client and verifies the response body.
- [ ] T038 [P] [US4] Add BATS regression test `@test "Apache serves the bundle spool endpoint"` in `tests/apache.bats` that POSTs a bundle and verifies it is spooled, not applied.
- [ ] T039 [P] [US4] Add BATS regression test `@test "Apache serves the spool query endpoint"` in `tests/apache.bats` that queries `/spool` and verifies the covered ranges.
- [ ] T040 [P] [US4] Add BATS regression test `@test "Apache discovery callback still triggers sync"` in `tests/apache.bats` that starts two instances, waits for discovery, and verifies spool files are created.

### Implementation for User Story 4

- [X] T041 [US4] Update `handlers/hello.get.sh` to read the path from `PATH_INFO` and write the path segment as `text/plain`.
- [X] T042 [US4] Update `handlers/bundle.post.sh` to read the POST body from stdin, extract the commit range from `QUERY_STRING` or `git bundle list-heads`, and spool the bundle to `<data-dir>/spool/<repo>/<from>-<to>.bundle`.
- [X] T043 [US4] Update `handlers/spool.get.sh` to read `QUERY_STRING` for the `repo` parameter and return the spool coverage JSON.
- [X] T044 [US4] Update `handlers/head.get.sh` to read `QUERY_STRING` and return repository head information.
- [ ] T045 [US4] Update `scripts/on-discover.sh` and `scripts/sync-common.sh` if needed to ensure the sync callback uses the correct Apache URL and client certificate paths.
- [X] T046 [US4] Remove `source/app.d` and the vibe-d HTTP server code; keep only `source/trust.d` and `source/multicast.d` helpers.
- [X] T047 [US4] Update `dub.json` to remove vibe-d HTTP dependencies and adjust the `application` configuration to exclude `source/app.d`.
- [X] T048 [US4] Update `justfile` recipes (`build`, `run`, `test`, `test-d`) to work with Apache instead of the D HTTP server.
- [ ] T049 [US4] Update `tests/smoke.bats` helper functions (`start_server`, `stop_server`) to start and stop Apache using the install scripts.
- [ ] T050 [US4] Update the `setup` function in `tests/smoke.bats` to install the project and start Apache before each test.

**Checkpoint**: User Story 4 is independently testable: existing functionality works under Apache and prior feature tests pass.

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Clean up after the server migration and update documentation.

- [X] T051 [P] Update `README.md` to describe Apache as the HTTP server, document `SSLVerifyClient optional_no_ca` + `+ExportCertData`, and remove vibe.d-specific instructions.
- [X] T052 [P] Update `specs/018-apache-http-server/quickstart.md` if implementation details changed during coding.
- [ ] T053 [P] Update `scripts/self-extract-build.sh` and `scripts/self-extract.in` if they reference the old binary startup method.
- [ ] T054 [P] Run `shellcheck` on all modified shell scripts.
- [X] T055 [P] Run the Robot Framework end-to-end tests and ensure the first 5 Apache tests pass.
- [X] T056 [P] Update `.gitignore` if new build artifacts are generated (e.g., Apache runtime files, pid files).
- [X] T057 [P] Verify `patches/apache-mod_ssl-optional_no_ca-cert.patch` documents the upstream version and behavior.
- [X] T058 [P] Switch development environment from Guix to a plain Nix channel; add `shell.nix`, update `justfile`, and remove `guix.scm`.
- [X] T059 [P] Create Robot Framework test suite `robot/mtls_hello.robot` and `robot/MtlsLibrary.py` covering US1 and US2.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — can start immediately.
- **Foundational (Phase 2)**: Depends on Setup. Blocks all user stories.
- **User Stories (Phase 3-6)**: All depend on Foundational. Can run sequentially in priority order.
- **Polish (Phase 7)**: Depends on all user stories.

### User Story Dependencies

- **US1 (P1)**: Can start after Foundational. No dependencies on other stories.
- **US2 (P1)**: Depends on US1 (the CGI trust/capture wrapper must exist before capture behavior can be tested).
- **US3 (P2)**: Can start after Foundational. No dependencies on other stories, but the install script should generate the same config US1 tests.
- **US4 (P2)**: Depends on US1 and US2 (handlers need the trust wrapper and capture logic). Must be completed after US1/US2.

### Within Each User Story

- Tests written before implementation (if using TDD).
- Apache config / handler scripts before integration tests.
- Story test passes before moving on.

### Parallel Opportunities

- T001–T006 (Phase 1 reading/tooling) can run in parallel.
- T007–T014 (Phase 2 foundational) can run in parallel after reading is complete.
- T015, T021, T028, T037 (story tests) can be drafted in parallel once the foundational API is stable.
- T031–T036 (US3 packaging) can run in parallel with US1/US2 implementation once the config is stable.

---

## Parallel Example: User Story 1

```bash
# Developer A: Apache config + service
Task: T017 Update config/apache-site.conf.in for +ExportCertData
Task: T019 Create scripts/start-apache.sh helper

# Developer B: handler and test
Task: T018 Create handlers/cert-echo.get.sh
Task: T015 Add BATS test for Apache exposing client cert
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1 (read existing code).
2. Complete Phase 2 (Apache config template, CGI trust/capture helpers, no-op patch).
3. Complete Phase 3 (US1 test + Apache mTLS wiring + test handler).
4. **STOP and VALIDATE**: Run the US1 BATS test and confirm Apache passes the full client certificate to a CGI handler.

### Incremental Delivery

1. Setup + Foundational → Apache can be configured and CGI scripts can parse the client cert.
2. US1 → Apache requests and exposes the full client certificate.
3. US2 → Untrusted certificates are captured in purgatory.
4. US3 → Install scripts and packages set up Apache automatically.
5. US4 → All existing endpoints work under Apache and prior tests pass.
6. Polish → Docs updated, scripts linted, full test suite green.

---

## Notes

- Apache is configured with `SSLVerifyClient optional_no_ca` and `SSLOptions +StdEnvVars +ExportCertData`. Trust is enforced by the CGI handlers, not by Apache.
- The D binary is no longer an HTTP server. It may still be built for the multicast discovery thread and certificate helpers if those remain in D; otherwise, consider removing D entirely and moving discovery to a shell process.
- The `handlers/` directory scripts remain shell scripts but now read from CGI environment variables instead of being invoked by the D HTTP router.
- `patches/apache-mod_ssl-optional_no_ca-cert.patch` is a no-op informational patch documenting the upstream export behavior. It is not applied.
