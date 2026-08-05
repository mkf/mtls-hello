# Research: Hostname-Matched Certificate Trust

**Branch**: `004-hostname-cert-trust` | **Date**: 2026-08-05 | **Feature**: [spec.md](./spec.md)

## Decision: Client-certificate trust moves from CA to a per-hostname trust store

**Decision**: The TLS server context changes from `peerValidationMode = requireCert | checkCert | checkTrust` (client certs verified against one CA) to `requireCert | checkCert` (any syntactically valid client certificate is accepted at the TLS layer). Trust is then decided at the application layer: the server derives the peer's hostname from the presented certificate's name and looks it up in a local trust store. A peer is trusted only when a certificate file exists in the store under that hostname AND its SHA-256 fingerprint matches the presented certificate.

**Rationale**:
- Peers use self-signed certificates; there is no shared CA to verify against, so trust must be per-host pinning.
- The user's rule is explicit and non-TOFU: "if it will be present locally under that name i want to consider it trusted" — presence + match under the hostname is the entire trust decision.
- The permissive TLS mode is required to observe unknown certificates: with `checkTrust` against a CA, an unknown self-signed cert fails the handshake and the application never sees it, so purgatory capture would be impossible. Moving the decision to the application layer lets the server see the certificate, quarantine it, and still reject the connection.

**Alternatives considered**:
- Keep `checkTrust` (CA) and add the store as a second check — makes self-signed onboarding impossible without a CA; rejected.
- CA-only trust — no per-hostname granularity; this feature's entire point is per-host pinning; rejected.
- TOFU (auto-trust first connection) — explicitly rejected by the user ("no that is not TOFU").

## Decision: Hostname is derived from the client certificate's name

**Decision**: The peer's hostname for trust lookup is the client certificate's subject common name (CN); if no CN is present, the first DNS subjectAltName is used. A certificate with neither is rejected (no identity to look up). The lookup name is the hostname as it appears in the certificate — "hostname to match cert name locally".

**Rationale**:
- The user's phrasing ties trust to the certificate's own name ("hostname to match cert name"), not to a network-observed value.
- CN is the conventional identity field on self-signed host certificates; SAN-DNS is the fallback for modern certs that omit CN.
- This avoids spoofable inputs (TLS SNI or IP source) driving the trust decision.

**Alternatives considered**:
- SNI (server name indication) — client-declared at handshake, trivially spoofable, and irrelevant to self-signed peer identity; rejected.
- Multicast announcement `host` field (feature 002's `HOST_NAME`) — the announcement format currently has no host field, and discovery is unrelated to inbound trust; rejected for trust (note: if feature 002 ever lands, its `HOST_NAME` should equal the cert CN — consistency noted, not implemented here).

## Decision: Trust store layout and matching

**Decision**: The trust store is a flat directory, default `certs/hosts/`, with one PEM certificate per trusted peer named `<hostname>.crt` (e.g. `certs/hosts/alpha.local.crt`). Trust requires BOTH: the file exists AND the SHA-256 fingerprint of the file's certificate equals the fingerprint of the presented certificate. The stored certificate must also be currently valid (not expired) at trust time.

**Rationale**:
- Matches feature 002's existing per-host cert convention (`certs/hosts/<hostname>.crt` in `contracts/callback.md`), so onboarding, callback pinning, and trust lookup share one layout.
- Fingerprint equality is exact pinning: a different key/cert for the same hostname is NOT trusted (mismatch), which is exactly the "certificate mismatch" acceptance scenario.
- Filenames are hostnames, so dots are allowed (unlike the script-handler sanitization rules — this store is operator-maintained, not attacker-controlled).

**Alternatives considered**:
- Trust by "any cert named X" (CN only, no pin) — a re-issued cert for X would be auto-trusted, defeating pinning; rejected.
- Single bundle file of all trusted certs — loses per-hostname lookup and makes promotion/replacement atomicity harder; rejected.
- Key-hash directory per host — over-engineered for LAN scale; rejected.

## Decision: Purgatory layout and idempotent capture

**Decision**: When a presented certificate is not trusted (store miss OR fingerprint mismatch), the server saves it to the purgatory directory, default `certs/purgatory/`, as `<hostname>.<sha256-fingerprint-hex>.crt`. Capture is idempotent: the same certificate for the same hostname maps to the same filename, so repeated connections overwrite the same entry instead of accumulating duplicates. Capture NEVER changes the trust decision — the connection is still rejected.

**Rationale**:
- The fingerprint in the filename gives natural dedup (FR-005) and lets the operator identify which exact cert tried to connect.
- Purgatory is operator-managed: review, promotion, and cleanup are manual (per spec assumptions).
- Storing the hostname prefix helps the operator match purgatory entries to hosts.

**Alternatives considered**:
- Append-only log of every attempt — unbounded growth and harder review; rejected.
- Capture only the first attempt per host — hides key-rotation/mismatch events; rejected (fingerprint dedup keeps one file per unique cert while still recording each distinct cert).

## Decision: Promotion is an operator action via a helper script

**Decision**: Promotion = installing the certificate into the trust store as `<hostname>.crt`. The server never self-promotes. A helper script `scripts/trust-host.sh <hostname> <cert-file>` validates that the certificate's name (CN/SAN) matches `<hostname>` (warn and refuse on mismatch by default), copies it to `certs/hosts/<hostname>.crt`, and prints verification instructions. Manual `cp`/`mv` is also documented in the onboarding doc.

**Rationale**:
- The spec requires operator action (FR-006/FR-007) and warns when the name doesn't match (acceptance scenario 3 of US3).
- A script makes the "must match hostname" rule enforceable and the onboarding doc repeatable; manual placement remains possible for power users.
- No server-side promotion endpoint: promotion is a local operator decision, not a network action.

**Alternatives considered**:
- Promotion endpoint on the server — exposes trust-store mutation to the network; rejected (trust changes are operator-local).
- Automatic promotion from purgatory after N matches — violates the no-TOFU and no-auto-trust rules; rejected.

## Decision: Observability

**Decision**: Every client-certificate trust evaluation is logged with: derived hostname, certificate SHA-256 fingerprint, and decision (`trusted` / `unknown` / `mismatch` / `invalid-name` / `expired`), plus the purgatory path when captured. Rejections of unknown/mismatched peers include the purgatory filename so operators can find the quarantined cert.

**Rationale**:
- SC-006 requires every trust decision to be logged with hostname and reason; the purgatory path makes the capture actionable.
- Existing log conventions (`logInfo`/`logWarn` with structured messages) are reused; no new logging framework.

**Alternatives considered**: Metrics/counters — out of scope at LAN scale; a log line per decision is sufficient and debuggable (constitution-consistent text I/O).

## Decision: CLI surface — legacy argument removed

**Decision**: New options `--trust-dir=DIR` (default `certs/hosts`) and `--purgatory-dir=DIR` (default `certs/purgatory`). The legacy 4th positional (`clientCA`) is removed entirely: the project is pre-release, so there is no installed user base to preserve CLI compatibility for, and the argument no longer has any effect on trust decisions.

**Rationale**:
- Since feature 004 the TLS layer only *requires* a client certificate (`TLSPeerValidationMode.requireCert`); trust is decided per-hostname at the application layer. The CA file loaded from `clientCA` was never consulted.
- Pre-release project → no backward-compatibility burden; keeping a dead argument invites confusion (see greenfield cleanup decision).
- The trust store and purgatory are separate concerns (trust vs. quarantine), hence two options.

**Alternatives considered**: Keep `clientCA` as an ignored no-op for CLI stability — rejected as vestigial in a pre-release codebase. Reuse `clientCA` as the trust dir — conflates two different things; rejected.
