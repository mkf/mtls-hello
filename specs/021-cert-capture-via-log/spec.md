# Feature Specification: Cert Capture via Logging Pipeline

**Feature Branch**: `021-cert-capture-via-log`

**Created**: 2026-08-06

**Status**: Draft

**Input**: User description: "the capture-client-cert is ugly — it would be best to use the custom-log-to-script feature of apache to do this."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Automatic peer-certificate capture for every request (Priority: P1)

As an operator, I want every connecting peer's certificate to be captured into the purgatory directory automatically for every request, through a single centralized mechanism, so that I never have to remember to wire capture logic into each handler and new handlers "just work".

**Why this priority**: This is the core value. Today, certificate capture is duplicated inside every CGI handler (each one must source the capture helper and call it). Centralizing capture into one place that runs for all requests removes a whole class of mistakes (a new handler that forgets to capture) and is the whole point of the change.

**Independent Test**: Send a request with an untrusted client certificate to any single endpoint and confirm the certificate is written to the purgatory directory, even though the endpoint's handler does not contain any capture code.

**Acceptance Scenarios**:

1. **Given** a peer connects with an untrusted certificate, **When** the request reaches the server via any endpoint, **Then** the certificate is captured into purgatory under `<hostname>.<fingerprint>.crt`.
2. **Given** a handler that contains no capture logic at all, **When** an untrusted peer calls it, **Then** the peer's certificate is still captured into purgatory.
3. **Given** the same untrusted peer makes several requests in a row, **Then** purgatory holds exactly one deduplicated file for that peer (same fingerprint).

---

### User Story 2 - Simplified handlers (Priority: P2)

As a maintainer, I want the CGI handlers to contain only their business logic plus a trust check, so that they are short, readable, and free of the repeated capture boilerplate.

**Why this priority**: This is the direct payoff of US1 and the reason the user called the current code "ugly". It makes the codebase easier to read and extend.

**Independent Test**: Inspect each handler script and confirm it no longer sources the capture helper and contains no call to capture the certificate.

**Acceptance Scenarios**:

1. **Given** the change is complete, **When** reading any CGI handler, **Then** it contains no reference to the capture helper and no explicit certificate-capture call.
2. **Given** a trusted peer connects, **When** any handler runs, **Then** the handler still rejects/accepts based on the trust check exactly as before.

---

### User Story 3 - Capture must not interfere with serving (Priority: P3)

As an operator, I want certificate capture to happen as a side-effect of the request pipeline without slowing down or breaking the response, so that request serving remains reliable even if the capture path has a hiccup.

**Why this priority**: Robustness. Capture is a best-effort background activity; it must never become a single point of failure for serving requests.

**Independent Test**: Stop or break the capture path and confirm requests are still served correctly, with capture failing gracefully (no crash, no hung request).

**Acceptance Scenarios**:

1. **Given** the capture mechanism is slow or temporarily unavailable, **When** an untrusted peer makes a request, **Then** the response is still served promptly and correctly.
2. **Given** a request arrives with no client certificate at all, **Then** no capture is attempted and no error is raised.

---

### User Story 4 - Reject unknown hosts outright (Priority: CONDITIONAL on feasibility)

As an operator, I want the server to refuse connections from any host that is not already known/trusted — including hosts whose certificate has merely been captured into purgatory — so that unknown peers can no longer connect at all, *provided* the centralized capture reliably records every trust-failing certificate as a safety net.

**Why this priority**: This is a hardening of US1, not a standalone deliverable. It is only valuable if the capture pipeline can reliably record trust-failing certificates; otherwise the current accept-and-capture behavior must be kept.

**Feasibility gate**: This story is IN SCOPE only if `/speckit.plan` research confirms the request pipeline can reliably identify and record a certificate that fails the project's custom trust check (note: project trust is a file/fingerprint check, not the server's own TLS verification). If feasibility cannot be confirmed, this story is dropped ("nvm") and the existing accept-and-capture behavior is preserved unchanged.

**Independent Test**: Attempt a connection from a host that is neither trusted nor promoted; the connection is refused, and its certificate is still recorded for later review.

**Acceptance Scenarios**:

1. **Given** feasibility is confirmed, **When** a host that is not in the trust directory connects, **Then** the connection is refused.
2. **Given** a host whose certificate is only in purgatory (captured but never promoted), **When** it connects, **Then** it is treated as unknown and refused.
3. **Given** a fully trusted host, **When** it connects, **Then** it is served as before.

---

### Edge Cases

- What happens when a request carries **no** client certificate? (Capture is skipped; no error.)
- What happens for a peer whose certificate is **already trusted**? (Purgatory is not polluted; at most a harmless no-op / dedup.)
- What happens when **many concurrent** untrusted peers with the same certificate connect? (Exactly one purgatory file per distinct fingerprint — same dedup behavior as today.)
- What happens if the centralized capture path **crashes or is restarted**? (Request serving continues; capture resumes on restart without manual intervention.)
- (US4 only) If unknown hosts are rejected, what happens to peers that have not been promoted yet? They must still be recorded so an operator can later promote them; rejection must not silently lose certificate evidence.
- What happens when the peer certificate has an **unusual or empty** subject/CN? (Captured with a safe fallback filename, never crashes.)

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST capture every presented client certificate into the purgatory directory through a single centralized mechanism that runs for all requests, rather than per-handler capture code.
- **FR-002**: Capture MUST be deduplicated by certificate fingerprint, producing at most one file per distinct peer certificate (`<hostname>.<fingerprint>.crt`), matching the current naming convention.
- **FR-003**: CGI handlers MUST NOT be required to source a capture helper or call a capture function; capture MUST occur independently of handler logic.
- **FR-004**: Capture MUST be best-effort and non-blocking relative to request serving: a problem in the capture path MUST NOT prevent the response from being served.
- **FR-005**: The trust check (trusted peers are accepted, untrusted peers are rejected/captured) MUST continue to behave exactly as before for every handler.
- **FR-006**: The mechanism MUST capture the peer certificate regardless of which endpoint is hit, so that adding a new handler requires zero capture-related wiring.
- **FR-007**: Requests that present no client certificate MUST result in no capture attempt and no error.
- **FR-008** *(CONDITIONAL — included only if `/speckit.plan` confirms feasibility)*: The system MAY refuse connections from hosts that are not in the trust directory, including hosts present only in purgatory, while still recording every such trust-failing certificate. If feasibility is not confirmed, this requirement is removed and the existing accept-and-capture behavior is preserved.

### Key Entities *(include if feature involves data)*

- **Client certificate**: the PEM certificate presented by the connecting peer (already available to the request pipeline). Captured into purgatory when untrusted.
- **Purgatory directory**: existing quarantine directory; capture target. Unchanged by this feature.
- **Trust check**: existing per-handler decision (trusted → serve, untrusted → reject + capture). Behavior unchanged.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Zero CGI handlers reference the capture helper or contain explicit capture calls after the change.
- **SC-002**: A previously-untrusted peer's certificate appears in purgatory after a single request to any endpoint, with no per-handler capture code in place.
- **SC-003**: A newly added handler with no capture wiring still results in the untrusted caller's certificate being captured.
- **SC-004**: All existing end-to-end tests (the "capture untrusted cert in purgatory" and "promote captured cert and trust" flows) continue to pass without modification.
- **SC-005**: Request latency for an untrusted peer is not measurably increased by the centralized capture path.
- **SC-006** *(CONDITIONAL — only if FR-008 is retained)*: A host that is neither trusted nor promoted cannot establish a connection, yet its certificate is still recorded.

## Assumptions

- The capture target remains the existing purgatory directory with the existing `<hostname>.<fingerprint>.crt` naming, so promotion/trust tooling is unaffected.
- The capture mechanism is invoked by the HTTP server's request pipeline (the user-specified "log-to-script" approach) and therefore has access to the same per-request certificate data that handlers have today.
- Capturing a certificate that is already trusted is harmless (the dedup/trust tooling already tolerates this), so the centralized mechanism may capture all presented certificates and rely on the existing dedup.
- No new command-line flags or data-directory layout are required; the mechanism is configured as part of the existing server configuration generation.
- Existing trust and promotion scripts (`trust-host.sh`, `cgi-trust.sh`) are unchanged.
- **Open research question for `/speckit.plan`**: Can the request/logging pipeline reliably identify a certificate that fails the project's custom (file + fingerprint) trust check, distinct from the server's own TLS verification? The answer determines whether US4 / FR-008 / SC-006 are in scope. Until that research is done, US4 is treated as provisional.
