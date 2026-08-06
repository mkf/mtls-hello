# Tasks: Cert Capture via Logging Pipeline

**Input**: Design documents from `specs/021-cert-capture-via-log/`

**Prerequisites**: `plan.md`, `spec.md`, `research.md`, `data-model.md`, `contracts/capture.md`, `quickstart.md`

**Organization**: Tasks are grouped by user story. US4 is the rescoped (feasible) form — see `research.md` §4 / D004.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable (different files, no dependency on incomplete tasks)
- **[Story]**: which user story (US1–US4)
- Include exact file paths in descriptions

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Stand up the capture script skeleton and the Apache log wiring.

- [x] T001 [P] Create `scripts/log-capture.sh` with a header comment, `#!/bin/bash`, `set -euo pipefail`, and a `while IFS= read -r line` loop over stdin that echoes each line to stderr (placeholder).
- [x] T002 [P] Add the `mtls_cert_fmt` `LogFormat` and a piped `CustomLog` referencing `scripts/log-capture.sh` to `config/apache-site.conf.in`, using `{{TRUST_DIR}}` and `{{PURGATORY_DIR}}` placeholders.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Implement the capture logic and the install/config wiring that every user story depends on.

- [x] T003 [P] Implement the capture core in `scripts/log-capture.sh`: read args `<trust-dir> <purgatory-dir>`, split each stdin line on tab into subject_dn / ssl_verify / cert_escaped / marker, skip when `cert_escaped` is empty.
- [x] T004 [P] In `scripts/log-capture.sh`, unescape literal `\n` to newlines to recover the PEM, compute the SHA-256 fingerprint with `openssl x509 -fingerprint -sha256 -noout`, and derive the hostname from the subject `CN=` (fallback `unknown`).
- [x] T005 [P] In `scripts/log-capture.sh`, if the cert is already trusted (same fingerprint present in `<trust-dir>` per the existing trust rules) do nothing; otherwise write `<purgatory-dir>/<hostname>.<fingerprint>.crt`.
- [x] T006 [P] Make `scripts/log-capture.sh` resilient: wrap the per-line body so a malformed/unparseable line logs a warning to stderr and the loop continues (never exits on bad input). Add `set -o pipefail` handling so a closed stdin exits cleanly.
- [x] T007 Update `scripts/apache-config.sh` so the generated `httpd.conf` emits an absolute piped command (e.g. `"|{{DATA_DIR}}/scripts/log-capture.sh {{DATA_DIR}}/hosts {{DATA_DIR}}/purgatory"`) consistent with where handlers/scripts are installed.
- [x] T008 [P] Add `scripts/log-capture.sh` to the list of scripts copied into the data-dir scripts directory in `scripts/install.sh`.

**Checkpoint**: a booting Apache pipes one line per request (subject, verify, escaped PEM) to `scripts/log-capture.sh`.

---

## Phase 3: User Story 1 — Automatic capture for every request (Priority: P1) 🎯 MVP

**Goal**: Every presented client certificate is captured into purgatory through the log pipeline, regardless of endpoint, with no per-handler capture code.

**Independent Test**: a request with an untrusted cert to a handler that contains no capture code still writes `<hostname>.<fingerprint>.crt` to purgatory.

### Tests for User Story 1

- [x] T009 [P] [US1] Add a BATS/Robot case (in `robot/mtls_hello.robot` and/or `tests/`) that connects with an untrusted cert to an endpoint whose handler has no capture code and asserts a purgatory file appears.
- [ ] T010 [P] [US1] Add a test that makes several requests with the same untrusted cert and asserts exactly one deduplicated purgatory file.
- [ ] T011 [P] [US1] Add a test that connects with **no** client cert and asserts no capture attempt / no purgatory file and no error.

### Implementation for User Story 1

- [x] T012 [US1] Verify end-to-end capture by booting the server against a scratch data dir and curling an untrusted client cert to `/hello`; confirm the cert is written under `<purgatory-dir>/` matching `quickstart.md`.
- [x] T013 [US1] Confirm a second, distinct untrusted peer produces a second, distinct `<hostname>.<fingerprint>.crt` file.

**Checkpoint**: centralized capture works for every request without handler code.

---

## Phase 4: User Story 2 — Simplified handlers (Priority: P2)

**Goal**: CGI handlers contain only business logic + trust check; no capture boilerplate.

**Independent Test**: grep the handlers for capture references → none; existing trust/reject behavior unchanged.

### Implementation for User Story 2

- [x] T014 [P] [US2] Remove `source .../cgi-capture.sh` and the `capture_client_cert` call (and the now-redundant `cert="${SSL_CLIENT_CERT:-}"`/`is_trusted` capture branch where applicable) from `handlers/hello.get.sh`.
- [x] T015 [P] [US2] Do the same removal in `handlers/head.get.sh`.
- [x] T016 [P] [US2] Do the same removal in `handlers/spool.get.sh`.
- [x] T017 [P] [US2] Do the same removal in `handlers/bundle.post.sh`.
- [x] T018 [P] [US2] Do the same removal in `handlers/cert-echo.get.sh`.
- [x] T019 [US2] Verify no remaining references to `cgi-capture.sh`/`capture_client_cert` anywhere in `handlers/` and `scripts/`; then delete `scripts/cgi-capture.sh`.
- [x] T020 [US2] Remove the `cgi-capture.sh` copy line from `scripts/install.sh`.

**Checkpoint**: handlers are capture-free; capture happens solely via the log pipeline.

---

## Phase 5: User Story 3 — Capture must not interfere with serving (Priority: P3)

**Goal**: capture is best-effort and non-blocking; a capture hiccup never breaks a response.

### Tests for User Story 3

- [ ] T021 [P] [US3] Add a test that kills the piped logger process and confirms requests are still served correctly (Apache restarts the logger).
- [ ] T022 [P] [US3] Add a test that sends a malformed/garbage log-shaped line (or a request yielding an empty cert) and confirms the logger keeps running.

### Implementation for User Story 3

- [x] T023 [US3] Confirm the logger writes at most one small file per request (no blocking I/O) by inspection of `scripts/log-capture.sh` and a timed request under an untrusted cert.

**Checkpoint**: serving is resilient to capture-path failures.

---

## Phase 6: User Story 4 — Rescoped: untrusted never served, certs still recorded (Priority: P4, feasibility-rescoped)

**Goal**: Every endpoint rejects untrusted clients (handler-level), while their certs are still recorded by the log pipeline. (Connection-level refusal is infeasible — see `research.md` §4.)

### Tests for User Story 4

- [ ] T024 [P] [US4] Add a test asserting a **trusted** client produces **no** new purgatory file on repeated requests (capture filters on trust state).
- [ ] T025 [P] [US4] Add a test asserting every endpoint returns an error status for an untrusted client (no endpoint serves an unknown host).

### Implementation for User Story 4

- [x] T026 [US4] Audit `handlers/hello.get.sh` and `handlers/cert-echo.get.sh` (and all others) to ensure each rejects untrusted clients (401) before serving; harden any endpoint that currently serves untrusted clients.
- [x] T027 [US4] Ensure `specs/021-cert-capture-via-log/quickstart.md` documents that connection-level rejection is not feasible and that handler-level rejection is the implemented behavior.

**Checkpoint**: unknown hosts are never served; their certs are still recorded.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [x] T028 [P] Run `shellcheck` on `scripts/log-capture.sh`, `scripts/apache-config.sh`, and all touched `handlers/*.sh`; fix warnings.
- [x] T029 [P] Run `just robot` and confirm the existing "Capture Untrusted Cert In Purgatory" and "Promote Captured Cert And Trust" cases still pass unchanged.
- [x] T030 [P] Run `just test-d` to confirm no D-side regressions.
- [x] T031 [P] Run the new capture/skip/resilience tests added in US1/US3/US4.
- [x] T032 Verify `AGENTS.md` still points to `specs/021-cert-capture-via-log/plan.md`.
- [x] T033 Update `specs/021-cert-capture-via-log/tasks.md` to mark completed tasks.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies.
- **Foundational (Phase 2)**: depends on Setup; blocks all user stories.
- **US1 (Phase 3)**: depends on Foundational. MVP.
- **US2 (Phase 4)**: depends on US1 (capture must work before handlers drop their own capture).
- **US3 (Phase 5)**: depends on Foundational; can run alongside US1/US2.
- **US4 (Phase 6)**: depends on US1 (capture present) and US2 (handlers simplified) for clean hardening.
- **Polish (Phase 7)**: after all stories.

### Parallel Opportunities

- Phase 1 (T001, T002) and the [P] foundational tasks (T003–T006, T008) are independent files → parallel.
- The five handler edits in US2 (T014–T018) are different files → parallel.
- US3 tests (T021, T022) are parallel with US1/US2 work.

---

## Implementation Strategy

1. **MVP first**: Foundational + US1 — boot Apache with the piped logger and prove an untrusted cert lands in purgatory with zero handler capture code.
2. **Then US2**: strip capture code from all handlers and delete `cgi-capture.sh`, relying on US1's pipeline.
3. **US3**: prove resilience (logger crash/empty cert never breaks serving).
4. **US4 (rescoped)**: harden any endpoint that serves untrusted clients; prove trusted clients create no purgatory noise. Connection-level refusal is explicitly **not** pursued (infeasible under no-CA + post-response logger).
