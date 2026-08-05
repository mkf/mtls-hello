# Contract: Trust Store, Purgatory, and Promotion

**Branch**: `004-hostname-cert-trust` | **Date**: 2026-08-05 | **Feature**: [spec.md](../spec.md)

> Governs how inbound client certificates are trusted. Transport (mutual TLS) is unchanged from `specs/001-mtls-echo-discovery/contracts/http.md`; only the trust decision changes.

## Trust decision procedure

For each TLS client certificate presented to the server:

1. **Derive hostname**: subject CN, or first DNS subjectAltName if CN is absent. No usable name → decision `invalid-name`, connection rejected (not captured — no identity to file it under).
2. **Look up** `<trustDir>/<hostname>.crt`.
3. **Compare**: compute the SHA-256 fingerprint of the presented certificate and of the stored certificate.
4. **Decide**:

   | Store state | Presented matches | Stored cert valid | Decision | Capture to purgatory? |
   |---|---|---|---|---|
   | Entry exists | yes | yes | **trusted** | no |
   | Entry exists | yes | no | expired | no |
   | Entry exists | no | — | mismatch | yes |
   | No entry | — | — | unknown | yes |
   | Name unusable | — | — | invalid-name | no |

## Trust store layout

- Flat directory (default `certs/hosts/`), one PEM certificate per trusted peer.
- Filename: `<hostname>.crt` (e.g. `certs/hosts/alpha.local.crt`). Dots in hostnames are allowed (operator-maintained, unlike script-handler names).
- Content: PEM-encoded X.509 certificate (the exact certificate the peer presents).
- The server never writes to the trust store; it is operator-maintained.

## Purgatory layout

- Flat directory (default `certs/purgatory/`).
- Filename: `<hostname>.<sha256-hex-fingerprint>.crt`.
- Idempotent capture: the same (hostname, fingerprint) always maps to the same path — repeated connections overwrite, never duplicate.
- Purgatory presence confers **no trust**; it is purely a review queue for the operator.

## Promotion (operator action)

Promotion installs a certificate into the trust store as `<trustDir>/<hostname>.crt`. Two documented ways:

1. **Helper script** (recommended): `scripts/trust-host.sh <hostname> <cert-file>` — verifies the certificate's name matches `<hostname>` (refuses on mismatch by default), copies it to `<trustDir>/<hostname>.crt`, and prints a verification hint.
2. **Manual**: `cp <cert-file> certs/hosts/<hostname>.crt` — the operator is responsible for the name match.

After promotion, a peer presenting that exact certificate for that hostname is trusted. Replacing the file changes the pinned certificate (key rotation is an operator action).

## Logging

Every trust evaluation logs: derived hostname, presented certificate fingerprint, and decision (`trusted` / `unknown` / `mismatch` / `invalid-name` / `expired`). `unknown`/`mismatch` logs include the purgatory path. (SC-006.)

## Examples

```sh
# On the peer host, generate a self-signed host certificate:
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout alpha.key -out alpha.crt -subj "/CN=alpha.local"

# Obtain alpha.crt out-of-band (e.g. scp), then on this host:
./scripts/trust-host.sh alpha.local alpha.crt

# Connect with the peer's key + cert → now trusted:
curl --cacert certs/certs/server.crt \
     --cert alpha.crt --key alpha.key \
     https://alpha.local:8443/status
```
