# Research: Native Peer Certificate Detection

**Date**: 2026-08-06
**Feature**: specs/017-native-cert-detection

## Unknown 1: How to capture a server certificate from an outbound D TLS connection

**Decision**: Use the OpenSSL C API via the existing deimos bindings, creating a TLS client context and extracting the peer certificate after `SSL_connect`.

**Rationale**: The project already uses `vibe.stream.openssl` and `deimos.openssl.*` for inbound certificate handling. The same bindings can be used for an outbound client: create `SSL_CTX`, load client cert/key, create `SSL`, connect to a `BIO` socket, call `SSL_get_peer_certificate`, and convert it to PEM with `PEM_write_bio_X509`. This avoids adding a new dependency.

**Alternatives considered**:
- Use vibe.d's high-level HTTP client with a custom callback. Vibe.d does not expose a direct hook to capture the peer certificate during an HTTP request, so the low-level OpenSSL approach is more reliable.
- Shell out to `openssl s_client`. Rejected because the feature explicitly asks for core D functionality.

## Unknown 2: How to identify the peer hostname from the certificate

**Decision**: Derive the hostname from the certificate's Common Name (CN), matching the existing `hostnameFromCertificate` logic in `trust.d`.

**Rationale**: The existing trust subsystem uses CN as the primary hostname source. Keeping the same derivation ensures that captured certificates and trusted certificates are keyed consistently. SAN extension support is out of scope for this feature unless the existing trust code already handles it.

**Alternatives considered**:
- Use the hostname advertised in the multicast JSON. Rejected because the certificate is the authoritative identity; the advertised hostname could be spoofed. The CN is used as the canonical identity.

## Unknown 3: How to prevent duplicate purgatory entries

**Decision**: Continue using the filename format `<hostname>.<fingerprint>.crt` and overwrite on each capture.

**Rationale**: Because the fingerprint is part of the filename, capturing the same certificate twice produces the same path. The write operation is idempotent. If the peer presents a new certificate, the filename changes, so the old entry remains as a historical record. This satisfies the requirement without introducing a separate index file or database.

**Alternatives considered**:
- Keep a single `hostname.crt` and overwrite regardless of fingerprint. Rejected because it would silently lose the previous certificate, which may be useful for forensics.
- Scan the directory for matching fingerprints before writing. Rejected because the filename already encodes the fingerprint, making the check redundant.

## Unknown 4: How to test the capture flow

**Decision**: Use BATS integration tests that start two server instances, trigger discovery, and inspect the purgatory directory.

**Rationale**: The feature spans D certificate handling, multicast networking, and shell callback wiring. Integration tests are the most reliable way to verify the end-to-end behavior. Unit tests for the D capture function can be added if the build system supports them easily.

**Alternatives considered**:
- Pure D unit tests. Rejected because the critical failure modes involve the interaction between D, OpenSSL, and the shell environment.
