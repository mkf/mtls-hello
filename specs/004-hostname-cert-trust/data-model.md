# Data Model: Hostname-Matched Certificate Trust

**Branch**: `004-hostname-cert-trust` | **Date**: 2026-08-05 | **Feature**: [spec.md](./spec.md)

## Entities

### PresentedClientCertificate

The X.509 certificate a connecting peer presents during the TLS handshake.

| Field | Type | Source | Description |
|---|---|---|---|
| `hostname` | string | Subject CN, or first DNS SAN | The identity used for trust lookup |
| `fingerprint` | string | SHA-256 of DER encoding | Stable identity for matching and purgatory filenames |
| `valid` | bool | Certificate validity period | Whether the cert is currently within its validity window |
| `pem` | ubyte[] | TLS handshake | The certificate bytes (for purgatory storage) |

Validation: `hostname` must be non-empty (else `invalid-name`); `valid` must be true at trust time.

### TrustStoreEntry

A certificate the operator has decided to trust, stored under a hostname.

| Field | Type | Description |
|---|---|---|
| `hostname` | string | File identity: `<trustDir>/<hostname>.crt` |
| `certPath` | string | Path to the stored PEM file |
| `fingerprint` | string | SHA-256 of the stored certificate (derived at lookup) |
| `valid` | bool | Whether the stored certificate is currently valid |

Invariant: the trust decision for a presented certificate is `trusted` iff an entry exists for the presented `hostname` AND its fingerprint equals the presented `fingerprint` AND it is valid.

### TrustDecision

The outcome of evaluating a presented certificate.

| Field | Type | Values / Description |
|---|---|---|
| `outcome` | enum | `trusted`, `unknown`, `mismatch`, `invalidName`, `expired` |
| `hostname` | string | Derived hostname (may be empty on `invalidName`) |
| `fingerprint` | string | Presented cert fingerprint (for logging/purgatory) |
| `purgatoryPath` | string (nullable) | Where the cert was captured, when applicable |

Transitions: an `unknown` / `mismatch` decision ALWAYS captures to purgatory and NEVER trusts; a later operator promotion changes the store such that the same presentation yields `trusted`.

### PurgatoryEntry

A quarantined certificate from an untrusted peer.

| Field | Type | Description |
|---|---|---|
| `hostname` | string | Hostname the cert claimed (filename prefix) |
| `fingerprint` | string | SHA-256 fingerprint (filename component) |
| `certPath` | string | `<purgatoryDir>/<hostname>.<fingerprint>.crt` |

Invariant: capture is idempotent — the same hostname+fingerprint maps to the same path (overwrite, no duplicates); presence in purgatory never affects the trust decision.

### TrustConfig

Server configuration for the trust subsystem.

| Field | Type | Default | Description |
|---|---|---|---|
| `trustDir` | string | `"certs/hosts"` | Trust store directory (`<hostname>.crt` files) |
| `purgatoryDir` | string | `"certs/purgatory"` | Quarantine directory for untrusted certs |

### Promotion (operator action)

A manual operation: install a certificate into the trust store as `<trustDir>/<hostname>.crt`. Validated by `scripts/trust-host.sh`: the certificate's name must match the target hostname (refused on mismatch by default). After promotion, a peer presenting that exact certificate for that hostname is trusted.

## Relationships

- A `PresentedClientCertificate` maps to at most one `TrustStoreEntry` (by `hostname` + `fingerprint`).
- An untrusted `PresentedClientCertificate` produces exactly one `PurgatoryEntry` per unique (hostname, fingerprint) pair.
- `TrustConfig` scopes both the trust store and the purgatory directory.
