# Feature Specification: Mutual-TLS Echo Endpoint with LAN Discovery

**Feature Branch**: `001-mtls-echo-discovery`

**Created**: 2026-08-05

**Status**: Draft

**Input**: User description: "A secure HTTP service where each request to a URL path returns that path as plain text. Only clients presenting a valid client certificate can connect. Multiple service instances on the same local network can automatically discover each other."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Echo a URL Path to an Authenticated Client (Priority: P1)

An operator starts the service and wants to verify it is reachable. They send a request to the service using a client certificate issued by the service's trusted authority. The service responds with the exact URL path they requested, as plain text, proving the secure channel works end to end.

**Why this priority**: This is the core value of the feature — a demonstrable, mutually authenticated HTTPS round-trip. Without it there is no service.

**Independent Test**: Can be fully tested by starting the service, requesting `https://host:<port>/hello` with a valid client certificate, and confirming the response body is exactly `hello` with content type `text/plain`.

**Acceptance Scenarios**:

1. **Given** a running service with a trusted client certificate configured,
   **When** a client presents that certificate and requests path `/hello`,
   **Then** the response is exactly `hello` as `text/plain`.
2. **Given** a client without a certificate,
   **When** it attempts any request,
   **Then** the connection is rejected before any response is served.
3. **Given** a client presenting a certificate from an untrusted authority,
   **When** it attempts any request,
   **Then** the connection is rejected before any response is served.

---

### User Story 2 - Instances Discover Each Other on a LAN (Priority: P2)

Multiple service instances run on different machines on the same local network. Each instance periodically announces its presence, and every instance logs the other instances it hears. An operator can see which peers are online from any instance's logs.

**Why this priority**: The echo endpoint is the MVP; discovery is the second slice that makes multi-instance operation practical.

**Independent Test**: Can be fully tested by starting two instances on the same network and confirming each instance reports the other in its output within a short window.

**Acceptance Scenarios**:

1. **Given** two instances on the same local network,
   **When** they run for at least one announcement interval,
   **Then** each instance reports the other's address and port in its output.
2. **Given** an instance configured with discovery disabled,
   **When** it starts,
   **Then** it neither announces nor logs peers.

---

### User Story 3 - Operator Controls Service Behavior via Configuration (Priority: P3)

An operator can start the service with different ports, certificate paths, and discovery settings without rebuilding it.

**Why this priority**: Configuration makes the service deployable in different environments; the defaults already work for a single-host trial.

**Independent Test**: Can be tested by starting the service with a custom port and confirming it listens there, and with discovery disabled and confirming no discovery output.

**Acceptance Scenarios**:

1. **Given** a custom port provided at startup,
   **When** the service starts,
   **Then** it listens on that port.
2. **Given** the discovery-disabled option at startup,
   **When** the service starts,
   **Then** no discovery announcements are sent and no peers are logged.

---

### Edge Cases

- What happens when a malformed or non-JSON multicast packet is received? The service ignores it and continues operating.
- How does the service handle its own announcements? It filters out announcements from itself (same port) so an operator is not shown the local instance as a peer.
- What happens when the certificate files are missing at startup? The service fails to start with a clear error.
- What happens when the multicast port is already in use? The service continues serving HTTP; discovery errors are reported to the operator output without stopping the server.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST reject any client that does not present a client certificate.
- **FR-002**: System MUST reject any client whose certificate is not issued by a trusted authority.
- **FR-003**: System MUST respond to a request for path `/X` with the exact string `X` as plain text.
- **FR-004**: System MUST present its own certificate to clients so the connection is mutually authenticated.
- **FR-005**: System MUST periodically announce its service address and port to other instances on the local network.
- **FR-006**: System MUST listen for announcements from other instances and report each discovered peer to the operator.
- **FR-007**: System MUST allow the operator to disable discovery.
- **FR-008**: System MUST allow the operator to configure the service port and certificate locations at startup.
- **FR-009**: System MUST continue operating normally when it receives malformed discovery traffic.

### Key Entities *(include if feature involves data)*

- **Service instance**: A running copy of the service with an address, port, and discovery configuration.
- **Peer**: Another service instance discovered via the local network, identified by its address and port.
- **Identity (certificate)**: The client and server identities verified during the mutual-TLS handshake, issued by a shared authority.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A client with a valid certificate receives the exact path text for 100% of tested paths within the default timeout.
- **SC-002**: Unauthenticated and untrusted clients are rejected in every test scenario (100% of attempts fail before a response).
- **SC-003**: Two instances on the same local network detect each other within one announcement interval in 100% of test runs.
- **SC-004**: Starting the service with custom port and certificate settings succeeds without modification of the installed artifact.

## Assumptions

- The operator has generated or obtained a certificate authority, a server certificate, and client certificates before starting the service (a helper script is provided for local testing).
- Instances run on the same broadcast-capable local network segment (single LAN, no VLAN routing of multicast).
- Mutual authentication means the server verifies the client certificate's authority; the client independently verifies the server's certificate using its own trust store.
- Discovery is informational (peer presence only); it does not transfer data between instances.
- Discovery is disabled in the default single-host scenario only if the operator chooses; by default it is enabled with a group and port that do not interfere with common services.
