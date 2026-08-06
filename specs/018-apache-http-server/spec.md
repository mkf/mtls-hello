# Feature Specification: Apache HTTP Server Backend

**Feature Branch**: `018-apache-http-server`

**Created**: 2026-08-06

**Status**: Draft

**Input**: Replace the built-in HTTP server with Apache. Apache should request client certificates without requiring CA validation (`SSLVerifyClient optional_no_ca`), expose the full PEM-encoded client certificate to backend scripts via environment variables, and let the application layer decide whether a client is trusted. Untrusted certificates should be captured in a purgatory directory. Apache installation and basic configuration should be handled by the project install scripts and declared as a dependency in Debian and Arch packages.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Apache handles mutual TLS and exposes client certificates (Priority: P1)

A peer connects to the server over HTTPS. The server requests a client certificate but does not abort the TLS handshake if the certificate is self-signed or otherwise not verifiable against a CA. The backend script receives the full client certificate and can decide at the application layer whether to accept or reject the request.

**Why this priority**: This is the prerequisite for all other behavior. Without a server that can receive arbitrary peer certificates without terminating the handshake, no peer discovery or certificate capture can happen.

**Independent Test**: Start the server, make an HTTPS request with a self-signed client certificate, and verify that the backend script receives the certificate in an environment variable and can log it.

**Acceptance Scenarios**:

1. **Given** a running server configured for optional client certificates, **When** a client presents a trusted certificate, **Then** the backend script sees the certificate and the request succeeds.
2. **Given** a running server configured for optional client certificates, **When** a client presents an untrusted self-signed certificate, **Then** the backend script still sees the certificate and the request is rejected at the application layer, not during the TLS handshake.
3. **Given** a running server configured for optional client certificates, **When** a client presents no certificate, **Then** the backend script is informed that no certificate was provided and the request is rejected.

---

### User Story 2 - Untrusted certificates are captured in purgatory (Priority: P1)

When a peer presents an unknown or untrusted certificate, the server captures the certificate and stores it in a purgatory directory. The operator can later review the captured certificate and promote it to the trust directory if they choose to trust that peer.

**Why this priority**: Certificate capture is the core trust-on-first-use alternative that the project intentionally avoids. Purgatory lets the operator inspect certificates before trusting them.

**Independent Test**: Connect with an untrusted client certificate, verify that the certificate is written to `<data-dir>/purgatory/<hostname>.<fingerprint>.crt`, and verify that promoting the file to the trust directory makes the client accepted.

**Acceptance Scenarios**:

1. **Given** a purgatory directory exists, **When** a client with an untrusted certificate connects, **Then** the certificate is saved in purgatory using a filename that includes the hostname and fingerprint.
2. **Given** a captured certificate in purgatory, **When** the operator moves it to the trust directory as `<hostname>.crt`, **Then** subsequent requests from that client are accepted.
3. **Given** the same untrusted client connects multiple times, **When** the server captures the certificate each time, **Then** only one file exists in purgatory because the filename is deterministic by hostname and fingerprint.

---

### User Story 3 - Apache is installed and configured by the project (Priority: P2)

Installing the project on a fresh Debian or Arch system installs Apache, enables the required modules, and creates a minimal site configuration that serves the project endpoints. The native packages declare Apache as a dependency.

**Why this priority**: Manual Apache configuration is error-prone and would make the project harder to deploy. Automated installation makes the project production-ready.

**Independent Test**: Install the project in a clean container, make an HTTPS request to the default endpoint, and verify that Apache is running and responding.

**Acceptance Scenarios**:

1. **Given** a clean Debian or Arch container, **When** the Debian or Arch package is installed, **Then** Apache is installed and the package manager lists it as a dependency.
2. **Given** the project is installed via the install script, **When** the install script finishes, **Then** Apache is configured with a virtual host or site file that points to the project data directory and handlers.
3. **Given** a running Apache instance, **When** the operator restarts the service, **Then** the project endpoints continue to respond.

---

### User Story 4 - Existing endpoints continue to work after migration (Priority: P2)

All HTTP endpoints that currently exist (path echo, bundle spool, spool query, etc.) continue to behave the same way after the server is replaced by Apache. Discovery, sync, and handler scripts continue to work.

**Why this priority**: Replacing the server must not break existing user workflows or the feature tests already written for prior features.

**Independent Test**: Run the existing BATS test suite and verify that the tests relevant to prior features still pass.

**Acceptance Scenarios**:

1. **Given** a server migrated to Apache, **When** a trusted client requests `/hello`, **Then** the response is the same as before the migration.
2. **Given** a server migrated to Apache, **When** a trusted client POSTs a bundle to `/bundle`, **Then** the bundle is spooled as before.
3. **Given** a server migrated to Apache, **When** multicast discovery runs, **Then** the on-discover callback is still triggered and sync behaves the same.

---

### Edge Cases

- What happens if Apache is already installed on the target system? The install script should reuse it and not fail.
- What happens if the Apache modules `mod_ssl` or CGI are missing? The install script should enable them or report a clear error.
- What happens if the client certificate is very large? Apache and the CGI script must handle it without truncation.
- What happens if the operator disables the Apache site or stops the service? The project should provide a clear status command or error message.
- What happens if the certificate hostname cannot be extracted from the certificate? The capture should fall back to a safe identifier and log a warning.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The server MUST accept HTTPS connections and request a client certificate.
- **FR-002**: The server MUST expose the full PEM-encoded client certificate to backend scripts regardless of whether the certificate is trusted by any CA.
- **FR-003**: The server MUST NOT terminate the TLS handshake solely because the client certificate is self-signed or not verifiable against a CA.
- **FR-004**: The application layer MUST evaluate trust against the project’s trust directory and reject untrusted clients with an appropriate HTTP response.
- **FR-005**: Untrusted client certificates MUST be capturable in the project’s purgatory directory, keyed by hostname and fingerprint.
- **FR-006**: The project install scripts and native packages MUST install Apache, enable the required SSL/CGI modules, and configure a site or virtual host for the project.
- **FR-007**: Existing HTTP endpoints and handler scripts MUST continue to function after the migration with no behavior change from the client perspective.
- **FR-008**: The server configuration MUST allow the operator to disable or re-enable the project site without losing the project data directory or trust state.

### Key Entities

- **Client Certificate**: A PEM-encoded X.509 certificate presented by the connecting peer. It contains the subject (including common name), issuer, validity period, and public key.
- **Trust Directory**: A directory containing trusted certificates, keyed by hostname (`<hostname>.crt`). A client is trusted if its certificate matches a file in this directory and the fingerprint matches.
- **Purgatory Directory**: A quarantine directory for untrusted or unknown certificates, keyed by hostname and fingerprint (`<hostname>.<fingerprint>.crt`).
- **Apache Site Configuration**: A file or set of files that tell Apache how to serve the project endpoints, request client certificates, and route requests to the backend scripts.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A client presenting a trusted certificate can reach every existing endpoint without regression.
- **SC-002**: A client presenting an untrusted certificate is rejected and its certificate appears in the purgatory directory within 5 seconds of the request.
- **SC-003**: Installing the project on a fresh Debian or Arch container results in a running, reachable server with no manual Apache configuration required.
- **SC-004**: All existing BATS tests that do not specifically test the old server implementation pass after the migration.
- **SC-005**: A captured certificate promoted from purgatory to the trust directory grants trust on the next request.

## Assumptions

- Apache is the sole HTTP server after this feature; the previous built-in server is removed and not kept as a fallback.
- The target distributions (Debian and Arch) provide Apache with `mod_ssl` and CGI support in their standard repositories.
- The operator is willing to run Apache as a system or user service, and the install script handles the necessary service enablement/restart.
- The backend scripts continue to run as CGI under Apache; no migration to a different runtime model (FastCGI, WSGI, etc.) is required for the first version.
- The project data directory, trust directory, and purgatory directory remain under the same paths as before, driven by the `--data-dir` flag.
