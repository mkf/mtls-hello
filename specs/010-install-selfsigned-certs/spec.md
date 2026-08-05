# Feature Specification: Install-Time Self-Signed Certificates

**Feature Branch**: `010-install-selfsigned-certs`

**Created**: 2026-08-05

**Status**: Draft

**Input**: User description: "generate self-signed certificates during install, never overwrite existing ones, no CA needed"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - First Install Generates Certificates (Priority: P1)

An operator runs `just install`. The installer detects that no server certificate exists at the install target and generates a self-signed certificate and private key. After install, the systemd service starts successfully because the certificate files exist at absolute paths.

**Why this priority**: Currently the systemd unit crashes because the default cert path `certs/certs/server.crt` is relative and the service runs from `$HOME`. Without auto-generated certs, the operator must manually generate and place certificates before the service can start. This is the #1 cause of install failure.

**Independent Test**: Run `just install` with a temporary HOME, verify `~/.local/share/mtls-hello/certs/certs/server.crt` and `~/.local/share/mtls-hello/certs/private/server.key` exist and the certificate CN matches the hostname.

**Acceptance Scenarios**:

1. **Given** a fresh install with no existing certificates, **When** `just install` runs, **Then** a self-signed server certificate and private key are generated at `<data-dir>/certs/certs/server.crt` and `<data-dir>/certs/private/server.key`.
2. **Given** an existing install with certificates already in place, **When** `just install` is re-run, **Then** the existing certificate and key are NOT overwritten.
3. **Given** certificates generated at install time, **When** the systemd service starts, **Then** the TLS handshake succeeds (server has a valid cert to present).

---

### User Story 2 - No CA Infrastructure Anywhere (Priority: P2)

The project uses ad-hoc self-signed certificates for mutual TLS. There is no certificate authority — every machine generates its own self-signed certificate for both server TLS and client mTLS. Trust is established out-of-band by exchanging certificate fingerprints (feature 004 onboarding flow). The existing `scripts/gen_certs.sh` and all CA-related test fixtures are removed.

**Why this priority**: The CA-based PKI (`scripts/gen_certs.sh`) was always intended as a development/testing convenience. Production deployments have no use for a CA. Removing it from the install path simplifies the mental model: one machine, one self-signed cert, exchanged directly.

**Independent Test**: Verify that `cert.pem` and `key.pem` (or equivalent) are the only certificate artifacts created at install time — no CA certificate, no signing chain.

**Acceptance Scenarios**:

1. **Given** a fresh install, **When** certificates are generated, **Then** only a server certificate and private key are created. No CA certificate, no signing requests, no intermediate files.

---

### User Story 3 - Tests Use Self-Signed Certificates (Priority: P3)

All BATS tests that require TLS certificates generate self-signed server and client certificates at test time. No pre-generated CA, server, or client certificates are committed to the repository. Each test creates a fresh self-signed cert for the server and a separate self-signed cert+key for the mTLS client.

**Why this priority**: Eliminating the CA from tests ensures the production and test environments match. If self-signed certs work in production, they must work in tests — no divergence.

**Independent Test**: Run `just test` and verify all tests pass using only self-signed certificates generated within the test functions (or test fixtures).

**Acceptance Scenarios**:

1. **Given** no pre-generated certificates exist, **When** `just test` runs, **Then** all 41 tests pass using self-signed certificates only.

- What if `openssl` is not available on the host? The install script logs a clear error message and skips certificate generation. The systemd unit will fail until the operator provides certificates manually or installs OpenSSL.
- What if the hostname changes after certificate generation? The existing certificate (with the old CN) is preserved. The operator can delete it and re-run install to regenerate with the new hostname.
- What if the installed key file has incorrect permissions? The install script sets key files to mode 600 (owner read-only).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: `just install` MUST generate a self-signed X.509 certificate and RSA 2048-bit private key if no certificate exists at the install target.
- **FR-002**: The generated certificate MUST have its Common Name (CN) set to the machine's hostname.
- **FR-003**: The certificate MUST be valid for 10 years (3650 days) from the generation date.
- **FR-004**: The private key MUST be written with mode 0600 (owner read-only).
- **FR-005**: If a certificate already exists at the target path, `just install` MUST NOT overwrite it.
- **FR-006**: `just install` MUST generate the certificate and key directly into `~/.local/share/mtls-hello/certs/certs/server.crt` and `~/.local/share/mtls-hello/certs/private/server.key` respectively (no temp-and-move needed — this is a first-time creation with an existence guard).
- **FR-007**: The generated systemd unit MUST reference the certificate and key at their absolute paths (`%h/.local/share/mtls-hello/certs/...`).
- **FR-008**: The `scripts/gen_certs.sh` script and all CA-based test certificate fixtures MUST be removed. All tests MUST use self-signed certificates generated at test time or provided as test fixtures.
- **FR-009**: If `openssl` is not available on the host, `just install` MUST print a clear warning and skip certificate generation without failing.
- **FR-010**: No CA certificate, CSR, or signing chain files are created by the install process, nor used anywhere in the project — neither in production code nor in tests. All certificates are self-signed.

### Key Entities

- **Self-signed certificate**: An X.509 certificate signed by its own private key (no CA). Contains the machine's hostname as CN.
- **Private key**: An RSA 2048-bit private key paired with the certificate. Stored with restricted permissions.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: After `just install && just install-service && systemctl --user daemon-reload && systemctl --user start mtls-hello`, the service reaches `Active: active (running)` without manual certificate generation.
- **SC-002**: Re-running `just install` does not change an existing certificate's fingerprint (SHA-256 remains identical).
- **SC-003**: The generated certificate's CN equals `$(hostname)` at install time.

## Assumptions

- `openssl` is available on the host. If not, the operator is responsible for providing certificates.
- The hostname doesn't change between install and first service start (or if it does, the operator regenerates by deleting the old cert and re-running install).
- Mutual TLS trust (exchanging and trusting peer certificates) is handled by the existing feature 004 onboarding flow. The self-signed cert generated here is what peers will encounter and optionally trust.
- The development `scripts/gen_certs.sh` and all CA-related certificates under `certs/` are removed. BATS tests generate self-signed certificates per test or use committed test fixtures.
