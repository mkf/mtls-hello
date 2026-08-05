# Feature Specification: Per-Hostname Credential Store and Discovery Callback

**Feature Branch**: `002-per-host-cert-hook`

**Created**: 2026-03-19

**Status**: Draft

**Input**: User description: "So the thing is that I want the certs to be stored per-hostname and i want there to be a bash file, executed every time theres a multicast discovery, with a utility function for running curl on an X endpoint of the other host so as to use our private key and the given hostnames public key, and meant to be executed with environment variables telling us the hosts name, its public key filename, and the fqdn netloc to connect to it."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Discovery Callback (Priority: P1)

An operator provides a script that executes whenever a peer is discovered via multicast. The script receives the peer's identity (name), the path to the peer's public credential file, and the peer's connection address. This enables the operator to react to peer discovery events and perform actions with the peer's context.

**Why this priority**: This is the core observable behavior — when a peer appears on the network, the operator's script runs with the peer's context. It delivers immediate value by making discovery actionable.

**Independent Test**: Can be fully tested by starting the system, announcing a peer via multicast, and verifying the operator's script executes with the correct peer name, credential file path, and connection address. Delivers value by making discovery events actionable.

**Acceptance Scenarios**:

1. **Given** the system is running and the operator's script is configured, **When** a peer announces itself via multicast, **Then** the operator's script executes within one announcement interval.
2. **Given** the operator's script is configured, **When** it executes due to peer discovery, **Then** it receives the peer's name as input.
3. **Given** the operator's script is configured, **When** it executes due to peer discovery, **Then** it receives the path to the peer's credential file as input.
4. **Given** the operator's script is configured, **When** it executes due to peer discovery, **Then** it receives the peer's connection address as input.
5. **Given** a peer announces itself, **When** the announcement is received, **Then** the operator's script executes on every announcement (not deduplicated).

---

### User Story 2 - Per-Hostname Credential Store (Priority: P2)

Credentials for each peer are organized by hostname. When a peer is discovered, the system locates the peer's public credential file by hostname and provides the path to the operator's script. This enables per-peer credential management and verification.

**Why this priority**: This is foundational — it provides the credential file path to the callback. Without it, the callback cannot reference the peer's credential.

**Independent Test**: Can be tested by placing a credential file for a specific hostname in the store, discovering a peer with that hostname, and verifying the system provides the correct file path to the callback.

**Acceptance Scenarios**:

1. **Given** a peer's public credential is stored under its hostname, **When** the peer is discovered, **Then** the system locates the credential file by hostname.
2. **Given** a peer's public credential is stored under its hostname, **When** the peer is discovered, **Then** the system provides the credential file path to the operator's script.
3. **Given** no credential is stored for a discovered peer's hostname, **When** the peer is discovered, **Then** the system logs a warning and does not crash.

---

### User Story 3 - Authenticated Request Helper (Priority: P3)

The operator's script includes a helper capability that issues authenticated requests to any endpoint on the peer. The helper uses the local private credential (our identity) and the peer's public credential (for server verification) to establish a mutually authenticated connection. This enables the operator's script to communicate with the peer.

**Why this priority**: This is a value-add — it provides a ready-made capability for the operator's script to interact with the peer. The callback (US1) is the MVP; the helper builds on it.

**Independent Test**: Can be tested by invoking the helper with a peer's connection address and a path, and verifying the request succeeds using the local private credential and the peer's public credential.

**Acceptance Scenarios**:

1. **Given** the operator's script is executing with a peer's context, **When** the helper is invoked with a path, **Then** an authenticated request is issued to the peer's endpoint at that path.
2. **Given** the helper is invoked, **When** the request is issued, **Then** it uses the local private credential for client authentication.
3. **Given** the helper is invoked, **When** the request is issued, **Then** it uses the peer's public credential for server verification.
4. **Given** the helper is invoked with a peer that is unreachable, **When** the request fails, **Then** the helper returns a non-zero exit status.

---

### Edge Cases

- What happens when a peer announces a hostname with no stored credential? The system logs a warning and does not execute the callback (or executes with an empty credential path, depending on configuration).
- What happens when the peer's credential file is missing or unreadable? The helper fails with a clear error message and returns a non-zero exit status.
- What happens when the peer is unreachable? The helper's request fails, and the operator's script handles the exit status.
- What happens when the peer's hostname contains special characters (e.g., `/`, `..`)? The hostname is sanitized to prevent path traversal when locating the credential file.
- What happens when the operator's script is not configured or not executable? The system logs a warning and continues running.
- What happens when the same peer announces multiple times? The operator's script executes on every announcement (per requirement), which may result in repeated executions.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST execute the operator's script when a peer is discovered via multicast.
- **FR-002**: Script execution MUST include the peer's name (hostname) as input.
- **FR-003**: Script execution MUST include the path to the peer's public credential file as input.
- **FR-004**: Script execution MUST include the peer's connection address (netloc) as input.
- **FR-005**: Credentials MUST be stored per hostname and located by hostname.
- **FR-006**: Missing peer credentials MUST NOT crash the system; the system MUST log a warning.
- **FR-007**: The helper MUST be able to issue an authenticated request to any path on the peer.
- **FR-008**: The helper MUST use the local private credential for client authentication.
- **FR-009**: The helper MUST use the peer's public credential for server verification.
- **FR-010**: The callback script MUST be executed on every announcement from a peer (not deduplicated).
- **FR-011**: Hostnames used in credential lookups MUST be sanitized to prevent path traversal.

### Key Entities

- **Peer**: Represents a discovered service instance. Attributes: hostname (identity), connection address (netloc), public credential file (path).
- **Credential Store**: Organizes peer credentials by hostname. Provides lookup by hostname to locate the peer's public credential file.
- **Callback Script**: Operator-provided script that executes on peer discovery. Receives peer context (name, credential path, connection address) as input.
- **Request Helper**: Capability within the callback script that issues authenticated requests to peer endpoints. Uses local private credential and peer's public credential.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: When a peer is discovered, the operator's script executes within one announcement interval in 100% of test runs.
- **SC-002**: 100% of script invocations receive the peer's name, credential file path, and connection address.
- **SC-003**: An authenticated request via the helper to a peer's endpoint succeeds in 100% of test runs when credentials are present and the peer is reachable.
- **SC-004**: The system does not crash when a peer's credentials are missing (0 crashes in 100 test runs with missing credentials).
- **SC-005**: The operator's script executes on every announcement from a peer (verified by counting executions over a 30-second window with a peer announcing every 5 seconds = 6 executions).

## Assumptions

- Operator pre-provisions each peer's public credential (X.509 certificate) in the credential store before discovery occurs.
- "X endpoint" means any URL path on the peer; the helper accepts a path argument and constructs the full URL.
- "Public key" refers to the peer's X.509 certificate used to verify the server when connecting (server certificate pinning).
- "Our private key" refers to the local client identity (client certificate + private key) used to authenticate our requests (shared across all peers, not per-host).
- The callback script is executed on every announcement from a peer (every 5 seconds per peer), per the user's explicit statement "executed every time theres a multicast discovery". Deduplication is not implemented unless explicitly requested.
- The credential store layout (directory structure, file naming) is an implementation detail determined during planning. A reasonable default is a directory per hostname containing the peer's certificate.
- The local client identity (our private key + certificate) is configured once and used for all peer connections.
- The operator's script is responsible for handling errors (missing credentials, unreachable peers, request failures) and deciding what to do with the helper's output.