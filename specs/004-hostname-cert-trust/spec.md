# Feature Specification: Hostname-Matched Certificate Trust

**Feature Branch**: `004-hostname-cert-trust`

**Created**: 2026-08-05

**Status**: Draft

**Input**: User description: "lets create an onboarding doc that will tell me how to, upon grabbing a self-signed cert from the other host, make it trusted on my side. actually you know what, i want the hostname to match cert name locally and if it will be present locally under that name i want to consider it trusted" (refined: "no that is not TOFU. ALTHOUGH we could indeed make a thing where certificates that tried to connect land in a 'purgatory' directory and are not trusted yet")

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Hostname-Matched Certificate Trust (Priority: P1)

The operator trusts another host by obtaining its self-signed certificate and placing it in a local trust store under that host's name. From then on, when that host connects, the server considers it trusted only if a certificate is present locally under the host's name AND the presented certificate matches it. There is no automatic trust on first use: a host is never trusted merely because it connected.

**Why this priority**: This is the core trust model. It replaces blanket CA-based trust of peers with explicit per-host pinning, which is the security foundation the onboarding and purgatory flows build upon.

**Independent Test**: Start the server with a trust store containing a peer certificate under a hostname; connect using a matching client certificate and verify the connection is accepted. Connect using a different certificate claiming the same hostname and verify the connection is rejected. Connect using a certificate not present in the store and verify rejection.

**Acceptance Scenarios**:

1. **Given** a peer certificate is present in the local trust store under hostname `alpha`, **When** a client presenting that exact certificate connects as `alpha`, **Then** the connection is accepted.
2. **Given** no certificate is present in the trust store for hostname `alpha`, **When** a client presenting a certificate named `alpha` connects, **Then** the connection is rejected (no first-use trust).
3. **Given** a certificate is present in the trust store under hostname `alpha`, **When** a client presents a different certificate that also claims `alpha`, **Then** the connection is rejected (certificate mismatch).
4. **Given** the trust store is empty, **When** any peer connects, **Then** the connection is rejected.

---

### User Story 2 - Purgatory Quarantine for Unknown Peers (Priority: P2)

When a host connects that is not yet trusted (no matching certificate in the trust store), its certificate is captured into a "purgatory" directory so the operator can review it. Capturing a certificate does NOT make the peer trusted — the peer remains rejected until the operator explicitly promotes the certificate to the trusted store under the correct hostname.

**Why this priority**: Purgatory gives the operator visibility into who is trying to connect without weakening the trust model. It is the input side of the onboarding loop.

**Independent Test**: Connect with an untrusted certificate; verify the certificate file appears in the purgatory directory, the connection is rejected, and the peer is still untrusted on a second connection. Connect twice with the same untrusted certificate and verify purgatory does not accumulate duplicate entries.

**Acceptance Scenarios**:

1. **Given** a peer connects with a certificate not in the trust store, **Then** the certificate is saved to the purgatory directory and the connection is rejected.
2. **Given** the same untrusted certificate connects multiple times, **Then** purgatory contains exactly one entry for it (no duplicates).
3. **Given** a certificate is in purgatory, **When** its peer connects again, **Then** the peer is still rejected (purgatory presence confers no trust).
4. **Given** a certificate in purgatory, **When** the operator promotes it to the trust store under the matching hostname, **Then** subsequent connections with that certificate are accepted.

---

### User Story 3 - Onboarding Documentation (Priority: P3)

The operator-facing onboarding guide explains, end to end, how to take a self-signed certificate obtained from another host and make it trusted on the operator's side: where to place it, under which name, and how to verify it took effect.

**Why this priority**: The documentation is what makes the trust model usable. It is lower priority than the mechanism itself but required for the feature to deliver value.

**Independent Test**: A reader follows the guide with a freshly generated self-signed certificate and successfully makes it trusted, then confirms a connection from that host is accepted.

**Acceptance Scenarios**:

1. **Given** a self-signed certificate obtained from another host, **When** the operator follows the onboarding guide, **Then** the certificate ends up trusted under the host's name.
2. **Given** the guide's verification step, **When** the operator follows it, **Then** they can confirm the host is trusted (or see why it is not).
3. **Given** a certificate whose name does not match the hostname it would be stored under, **When** the operator places it, **Then** the guide warns that the host will not be trusted under that name.

---

### Edge Cases

- Peer connects with a certificate whose hostname has no entry in the trust store → connection rejected; certificate captured to purgatory.
- Peer presents a certificate that does not match the stored certificate for its hostname (e.g., key rotation or spoofing) → connection rejected; new certificate captured to purgatory for review.
- Certificate in the trust store is expired or revoked → peer not trusted.
- Purgatory receives the same certificate repeatedly → only one entry retained.
- Purgatory directory grows over time → operator is responsible for review and cleanup; growth does not affect the trust decision.
- Trust store is empty or missing → all peers rejected; all connect attempts captured to purgatory.
- Operator places a certificate under a hostname that does not match the certificate's own name → host remains untrusted until corrected.
- A host reconnects immediately after being rejected → no behavioral difference; each attempt is evaluated independently.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The server MUST trust a peer only when a certificate is present in the local trust store under the peer's hostname AND the presented certificate matches the stored one.
- **FR-002**: The server MUST NOT grant trust on first use; a successful connection alone MUST NOT make a peer trusted.
- **FR-003**: The trust store MUST be keyed by hostname, with each entry being a certificate file, and its location MUST be documented and configurable.
- **FR-004**: The server MUST capture the certificate of any rejected, not-yet-trusted peer into a purgatory directory, without granting any trust.
- **FR-005**: The server MUST NOT create duplicate purgatory entries for the same certificate (capture is idempotent).
- **FR-006**: The operator MUST be able to promote a purgatory certificate to trusted status under the peer's hostname, after which connections with that certificate are accepted.
- **FR-007**: Trust must remain tied to the hostname: a promoted/placed certificate is effective only for its own hostname.
- **FR-008**: The feature MUST ship onboarding documentation covering: obtaining the peer's self-signed certificate, placing it in the trust store under the matching hostname, and verifying trust.
- **FR-009**: Mutual TLS transport MUST remain in place (unchanged from prior features); this feature changes how client certificates are trusted, not the transport.
- **FR-010**: All trust decisions (accept/reject) MUST be observable in the server's logs, including the hostname and the reason (trusted / unknown / mismatch).

### Key Entities

- **Trusted Peer Certificate**: A certificate file stored in the trust store under a hostname; its presence (plus match with the presented certificate) is what makes a peer trusted.
- **Hostname**: The identity under which a peer is known and under which its certificate must be stored; derived from the certificate's name.
- **Purgatory Entry**: A certificate captured from an untrusted connecting peer, stored for operator review; confers no trust by itself.
- **Trust Decision**: The accept/reject outcome for a connecting peer, based on trust store presence plus certificate match (trusted, unknown, or mismatch).
- **Promotion**: The operator action of moving a purgatory certificate into the trust store under its hostname.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In 100% of test runs, a peer with a matching certificate in the trust store is accepted.
- **SC-002**: In 100% of test runs, a peer without a matching certificate in the trust store is rejected.
- **SC-003**: In 100% of test runs, every rejected peer's certificate is captured to purgatory exactly once per unique certificate.
- **SC-004**: In 100% of test runs, a certificate sitting in purgatory never results in the peer being trusted.
- **SC-005**: An operator following the onboarding guide can go from obtained certificate to trusted host in under 5 minutes.
- **SC-006**: In 100% of test runs, every trust decision is logged with hostname and reason.

## Assumptions

- Peers present self-signed certificates whose name (subject common name or SAN) identifies the host; that name is the hostname used for trust lookup.
- The trust store and purgatory are both directories of certificate files; the exact layout and the promotion mechanism (file move vs. command) are planning details.
- This feature governs trust of peer client certificates; the server's own certificate handling is unchanged.
- To capture unknown certificates into purgatory, the server must be able to observe a client certificate during connection setup even when it is not yet trusted; the exact mechanics (e.g., application-layer trust verification after a permissive TLS handshake) are a planning detail.
- Purgatory is operator-managed: review, promotion, and cleanup are manual; automated remediation is out of scope.
- Certificate revocation/expiry handling beyond "not trusted" is out of scope for this feature.
- This builds on feature 002's per-host certificate convention (`certs/hosts/<hostname>.crt`) and the `HOST_NAME`/`PEER_CERT_FILE` callback contract; feature 004 formalizes the trust store and its management.
