# Data Model: Native Peer Certificate Detection

**Feature**: specs/017-native-cert-detection

## Entities

### PeerCertificate

Represents an X.509 certificate presented by a peer during an outbound mTLS handshake.

| Attribute | Type | Description |
|-----------|------|-------------|
| hostname | string | Hostname derived from the certificate's Common Name (CN). |
| fingerprint | string | SHA-256 fingerprint of the certificate, lowercase hex. |
| pem | string | PEM-encoded certificate text. |
| sourceAddress | string | IP address of the peer that presented the certificate. |

### PurgatoryEntry

A stored, untrusted certificate awaiting operator review.

| Attribute | Type | Description |
|-----------|------|-------------|
| hostname | string | Hostname from the peer certificate. |
| fingerprint | string | SHA-256 fingerprint, used for deduplication. |
| path | string | Filesystem path: `<purgatoryDir>/<hostname>.<fingerprint>.crt`. |
| createdAt | datetime | Approximate write time, derived from filesystem mtime. |

## Relationships

- A `PeerCertificate` captured from a peer produces exactly one `PurgatoryEntry`.
- Multiple captures of the same certificate produce the same `PurgatoryEntry` path (overwrite).
- A `PurgatoryEntry` can be promoted to a trusted certificate by moving it to `<trustDir>/<hostname>.crt` and verifying the fingerprint matches.

## Validation Rules

- A certificate with no hostname-derived CN cannot be stored; the capture is logged and discarded.
- A certificate with an empty fingerprint cannot be stored; the capture is logged and discarded.
- The purgatory directory must be created recursively if it does not exist.
- File permissions should follow the default for the runtime user; no special mode is required because purgatory certificates are untrusted.

## State Transitions

```text
Discovered peer
      |
      v
Capture certificate via outbound mTLS
      |
      v
Extract hostname + fingerprint + PEM
      |
      v
Write PurgatoryEntry
      |
      +---> Same hostname + fingerprint already exists? OVERWRITE (no duplicate)
      |
      v
Invoke callback with PEER_CERT_FILE pointing to PurgatoryEntry
      |
      v
Operator reviews and moves PurgatoryEntry to TrustDir
      |
      v
Peer becomes trusted on next inbound mTLS connection
```
