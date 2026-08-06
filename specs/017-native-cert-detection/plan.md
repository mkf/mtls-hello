# Implementation Plan: Native Peer Certificate Detection

**Branch**: main | **Date**: 2026-08-06 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/017-native-cert-detection/spec.md`

## Summary

Move peer certificate detection from the external `on-discover.sh` callback into the D server. When a peer is discovered via multicast, the server will open an outbound mTLS connection to the peer, capture the server certificate presented during the handshake, and store it in the configured purgatory directory. Purgatory entries are keyed by hostname and fingerprint so duplicates are overwritten rather than accumulated. The callback script is then invoked with `PEER_CERT_FILE` already pointing to the captured certificate.

## Technical Context

**Language/Version**: D (LDC 1.27.1), Bash 5+ for handler scripts

**Primary Dependencies**: vibe.d (vibe-stream OpenSSL TLS), OpenSSL C API via deimos bindings, `std.process`, `std.json`

**Storage**: Filesystem: `<data-dir>/purgatory/<hostname>.<fingerprint>.crt`

**Testing**: BATS integration tests; D unit tests if feasible under the existing build

**Project Type**: D server with shell-script handlers and sync tooling

**Constraints**: Must not break the existing discovery/callback flow; callback script must still be able to run standalone when invoked by tests or operators; existing self-signed cert workflow must remain unchanged; no CA infrastructure.

**Scale/Scope**: LAN deployments, typically <100 peers, certificates captured infrequently (discovery interval 5s by default).

## Constitution Check

Template — PASS by default. No new top-level projects, no framework churn. The change is localized to the D server and the `on-discover.sh` script.

## Project Structure

### Files changed

```text
source/app.d              # UPDATE: build TLS client context, pass purgatory path to callback
source/multicast.d        # UPDATE: replace guessed PEER_CERT_FILE with detected one
source/trust.d            # UPDATE: expose helpers: capture peer cert, hostname, fingerprint, purgatory path
scripts/on-discover.sh    # UPDATE: remove grab_peer_cert; use PEER_CERT_FILE from env unconditionally
scripts/sync-common.sh    # UPDATE: remove cert-extraction fallback; rely on PEER_CERT_FILE
```

### New files

```text
source/certcapture.d      # NEW: D outbound mTLS client capture (optional, or keep in trust.d)
```

### Data flow

```text
Peer A (discovere)                        Peer B (discoverer)
|                                         |
|  UDP multicast announcement             |
|---------------------------------------->|
|                                         |
|  D: processAnnouncement()               |
|  D: detectPeerCert(host, port)          |
|  D: open TLS client -> Peer A HTTPS     |
|  D: capture server certificate          |
|  D: write <purgatory>/<host>.<fp>.crt   |
|  D: set PEER_CERT_FILE in env           |
|  D: spawn on-discover.sh                |
|                                         |  bash: mtls_curl to peer
|                                         |  using PEER_CERT_FILE
```

## Design Decisions

### Why D instead of shell for capture

The existing `on-discover.sh` runs `openssl s_client -showcerts` in a subprocess to extract the peer certificate. This is fragile, requires the operator to have `openssl` in a compatible configuration, and cannot be reused by the D server for trust decisions. Moving capture into D makes it a first-class, testable, core capability.

### Why keep purgatory keyed by hostname + fingerprint

`trust.d` already writes inbound rejected certificates as `<hostname>.<fingerprint>.crt`. Reusing the same filename scheme for outbound captures keeps the directory consistent: one authoritative entry per hostname+identity, with duplicates overwritten automatically. This satisfies the "no duplicates" requirement without introducing a separate index or database.

### Why pass the detected path to the callback

`on-discover.sh` and `sync-common.sh` already consume `PEER_CERT_FILE`. After detection, the server sets this variable to the actual captured path and spawns the callback. This is the smallest change to the shell side and keeps the callback usable for manual invocation if the operator sets `PEER_CERT_FILE` themselves.

### What happens when detection fails

If the peer is unreachable or the handshake fails, the server logs the failure and still invokes the callback with `PEER_CERT_FILE` empty or unset. The callback's existing `ensure_peer_host` logic (after removal of `grab_peer_cert`) must handle this gracefully: if `PEER_CERT_FILE` is missing, it logs an error and exits cleanly. This preserves backward compatibility with manual use where the operator provides the file.

## Implementation Strategy

### MVP: D-side capture and callback wiring (US1)

1. Add a `capturePeerCertificate` function in `trust.d` (or new `certcapture.d`) that:
   - Opens an OpenSSL TLS client context with `OUR_CERT` / `OUR_KEY`.
   - Connects to the peer's HTTPS address.
   - Extracts the server certificate after handshake.
   - Returns hostname, fingerprint, PEM, and the purgatory path.
2. In `multicast.d`, before spawning the callback, call the capture function and update `PEER_CERT_FILE` in the env.
3. Simplify `on-discover.sh` and `sync-common.sh` to trust `PEER_CERT_FILE` when present.

### Then: deduplication guarantee (US2)

4. Ensure `capturePurgatory` returns the existing path when the same hostname+fingerprint is already present.
5. Add a BATS test that triggers discovery twice and verifies the purgatory directory has exactly one file for the peer hostname.

### Then: hostname-keyed storage and operator trust (US3)

6. Verify the captured filename is `hostname.fingerprint.crt` and that moving it to `hosts/hostname.crt` makes the peer trusted on the next inbound connection.
7. Update `README.md` and `quickstart.md` to remove the manual `openssl s_client` step.
