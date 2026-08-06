# Feature Specification: Native Peer Certificate Detection

**Feature Branch**: `[017-native-cert-detection]`

**Created**: 2026-08-06

**Status**: Draft

**Input**: User description: "Detecting certificates of discovered peers should be core functionality implemented in D. Also the purgatory should not fill up with duplicates of same certificate."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Automatic peer certificate capture on discovery (Priority: P1)

When an operator starts a server, it should be able to learn the mTLS certificate of a peer it discovers on the LAN without relying on external scripts or manual file copying. The server detects the peer, opens an mTLS connection, captures the certificate it receives during the handshake, and stores it for later trust review.

**Why this priority**: Removing manual cert handling is the core value of the feature. Without it, operators must copy certificates out-of-band, which blocks unattended discovery and sync.

**Independent Test**: Spin up two server instances on the LAN; the first should automatically record the second's certificate material (or a reference to it) after discovery completes.

**Acceptance Scenarios**:

1. **Given** a running server with trust/purgatory directories configured, **When** a second peer advertises itself on the multicast group, **Then** the first server attempts an mTLS connection and captures the peer's presented certificate.
2. **Given** a captured peer certificate, **When** an operator inspects the purgatory directory, **Then** the certificate is present and contains the peer's hostname as its CN/SAN identity.

---

### User Story 2 - Deduplicated purgatory storage (Priority: P2)

The server should not clutter the purgatory directory with multiple copies of the same peer certificate. Instead, it should recognize that a certificate is already recorded for a given hostname and skip writing a duplicate.

**Why this priority**: A purgatory that fills with duplicates makes trust review harder and wastes disk space. Operators need one authoritative, untrusted certificate per peer for review.

**Independent Test**: Trigger discovery of the same peer twice; the purgatory directory should contain exactly one certificate file for that peer identity after both runs.

**Acceptance Scenarios**:

1. **Given** a peer certificate already present in purgatory, **When** the same peer is discovered again, **Then** no additional file is created for that peer identity.
2. **Given** a peer certificate already present in purgatory, **When** the peer presents a new certificate with a different fingerprint, **Then** the server replaces or archives the previous untrusted certificate so the purgatory reflects the latest observed material.

---

### User Story 3 - Clear hostname identity for captured certificates (Priority: P3)

When a certificate is captured, the server must store it in a way that maps cleanly to the peer's hostname. Operators should be able to trust a host by moving the exact file the server recorded for that hostname.

**Why this priority**: Trust decisions are hostname-based in the existing system. Captured certificates must be keyed by hostname so that `trust-host.sh` and the trust subsystem continue to work without extra translation.

**Independent Test**: After discovery, the purgatory contains a file named after the peer's hostname, and moving it to the trust directory under the same hostname enables successful mTLS sync.

**Acceptance Scenarios**:

1. **Given** a discovered peer with hostname `peer-01`, **When** its certificate is captured into purgatory, **Then** the file is stored as `purgatory/peer-01.crt` (or equivalent hostname-keyed path).
2. **Given** a hostname-keyed certificate in purgatory, **When** an operator moves it to the trust directory, **Then** the server accepts mTLS connections from that peer as a trusted host.

### Edge Cases

- What happens when the peer certificate is self-signed and does not chain to a trusted CA?
- What happens when discovery is triggered but the peer is unreachable before the handshake completes?
- What happens when the peer certificate has no CN or SAN that can be mapped to a hostname?
- What happens when a peer's certificate changes but its hostname stays the same?
- How does the system handle multiple simultaneous discoveries of the same peer?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The server MUST capture the certificate presented by a peer during the mTLS handshake when a peer is discovered.
- **FR-002**: The certificate capture MUST be implemented as a core capability of the server, not delegated to external scripts.
- **FR-003**: Captured certificates MUST be stored in the configured purgatory directory keyed by the peer's hostname identity.
- **FR-004**: The server MUST NOT create a duplicate certificate file in purgatory when the same peer identity and certificate fingerprint are already present.
- **FR-005**: When a peer presents a new certificate for a known hostname, the server MUST replace the existing purgatory entry so the latest certificate is available for review.
- **FR-006**: The server MUST expose the captured hostname and certificate fingerprint to the operator via logs or existing status endpoints.
- **FR-007**: The capture process MUST not block the normal discovery announcement or request handling of the server.

### Key Entities *(include if feature involves data)*

- **Peer Certificate**: The X.509 certificate presented by a peer during mTLS. Identified by hostname (CN/SAN) and a SHA-256 fingerprint.
- **Purgatory Entry**: A stored, untrusted certificate file that is keyed by hostname and awaiting operator review before promotion to trust.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: After discovery, 100% of reachable peers that present a valid mTLS certificate have their certificate captured in purgatory within 10 seconds.
- **SC-002**: The purgatory directory contains at most one certificate file per discovered peer hostname, with zero duplicate fingerprints for the same hostname.
- **SC-003**: Operators can trust a captured peer by moving a single purgatory file, and the server recognizes that peer as trusted on the next connection attempt.
- **SC-004**: No external script installation is required for certificate capture to function after the server is installed.

## Assumptions

- Peers use self-signed certificates with a hostname-derivable CN or SAN; the existing system does not use a CA.
- The server is already configured with `--data-dir` and derives trust/purgatory subdirectories from it.
- The existing trust subsystem continues to validate certificates by hostname + fingerprint, so captured purgatory certificates must match that format.
- External `on-discover.sh` may still be invoked for sync, but certificate capture is independent of that callback.
- Discovery is already triggered by multicast; this feature only extends what happens after the discovery event is received.
