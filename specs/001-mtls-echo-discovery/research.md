# Research: Mutual-TLS Echo Endpoint with LAN Discovery

**Branch**: `001-mtls-echo-discovery` | **Date**: 2026-08-05 | **Feature**: [spec.md](./spec.md)

## Decision: Build environment — Guix with real OpenSSL

**Decision**: Build and run inside `guix shell -f guix.scm` using LDC 1.27.1 + dub 1.23.0 against Guix's real OpenSSL 3.0.7.

**Rationale**:
- The host's `/usr/lib64` ships **LibreSSL 4.2.1** masquerading as OpenSSL 3.5.3. The deimos OpenSSL bindings used by vibe-stream reference `ERR_new`, `ERR_set_debug`, `ERR_set_error`, and `ERR_add_error_data` — symbols LibreSSL removed. Linking against the host fails (`undefined reference to ERR_new` etc.).
- Guix provides genuine OpenSSL 3.x, which exports all required symbols.
- LDC is used because Guix's `dmd` is GNU Shepherd, not the D compiler.

**Alternatives considered**:
- Patching vibe-stream's `setSSLError` to use `ERR_put_error` — viable but modifies vendored dependency code.
- Nix dev shell — explored; host Nix is flake-based with no nixpkgs channel, and the user switched to Guix.

## Decision: LDC linker configuration inside Guix

**Decision**: Pass `--linker=bfd` (via `DFLAGS="--linker=bfd"`) and provide a `cc` symlink to `gcc` on `PATH` when invoking dub inside the Guix shell.

**Rationale**:
- Guix's `gcc-toolchain` does not install a `cc` binary; LDC's default linker driver is `cc` → "failed to locate cc".
- LDC defaults to `-fuse-ld=gold`; Guix binutils has only `ld.bfd` → collect2 "cannot find 'ld'". LDC's `--linker=bfd` (or empty) prevents the `-fuse-ld` flag.
- Verified end-to-end: minimal dub project builds and runs with this setup.

**Alternatives considered**: `--linker=` (empty) also works; dub 1.23 has no `--dflags` flag, so the `DFLAGS` environment variable is the mechanism (confirmed in `dub run -h`).

## Decision: Dependency resolution inside Guix

**Decision**: Keep `dub.selections.json` pinned; when the Guix dub cannot reach the registry, resolve offline.

**Rationale**:
- Guix's libcurl (GnuTLS backend) does not honor `SSL_CERT_FILE`/`CURL_CA_BUNDLE` env vars for library callers — the `curl` CLI works in the shell but dub's `std.net.curl`-based registry client still fails TLS against code.dlang.org. Verified empirically.
- dub 1.23's offline flag is `--skip-registry=standard` (no `--offline` flag exists); for fully cached deps this avoids registry queries.
- Host dub 1.41 successfully fetched all dependencies earlier (they live in `~/.dub/packages`), so the cache is populated.

**Open item (carried into tasks)**: If `--skip-registry=standard` still fails on `vibe-d:http` resolution, generate `~/.dub/packages/local-packages.json` from the existing cache (dub 1.23 only reads that map file; it does not scan the directory).

## Decision: Server-side mutual TLS API

**Decision**: Use vibe-stream 1.x `OpenSSLContext` with `peerValidationMode = requireCert | checkCert | checkTrust`.

**Rationale**:
- `TLSPeerValidationMode.trustedCert` includes `checkPeer`, which compares the peer certificate name against the connected address — wrong for server-side client-cert verification.
- `requireCert | checkCert | checkTrust` requests a client certificate, requires it, checks chain validity/expiry, and requires trust against the loaded CA pool (`useTrustedCertificateFile`).
- API confirmed against vibe-stream 1.4.1 source (`tls/vibe/stream/openssl.d`, `tls/vibe/stream/tls.d`).

**Alternatives considered**: vibe-d 0.9.x `TLSContext` with `acceptClientCert`/`requireClientCert` — older API, would require downgrading the whole dependency tree for the older LDC frontend; not needed once Guix's OpenSSL resolves linking.

## Decision: LAN discovery mechanism

**Decision**: UDP multicast on group `239.255.42.42:4242`, JSON payload `{"service":"mtls-hello","port":<port>}`, announce every 5 s, listen with a 500 ms receive timeout in a daemon thread.

**Rationale**:
- std.socket exposes IPv6 join group but not the IPv4 `IP_ADD_MEMBERSHIP`/`IP_MULTICAST_TTL`/`IP_MULTICAST_LOOP` options on this compiler — used raw `setsockopt` with the Linux constants (33/34/35) and a local `ip_mreq` struct.
- TTL=1 keeps announcements on the LAN; loopback=1 lets same-host instances discover each other (useful for tests).
- JSON is human-readable and easy to extend; `service` field filters foreign traffic.

**Alternatives considered**: mDNS/DNS-SD — significantly more complex; overkill for presence-only discovery. Raw UDP with a custom text protocol — JSON chosen for debuggability.

## Decision: Testing

**Decision**: BATS end-to-end tests against a live server on a scratch port (18443), using generated test PKI.

**Rationale**: Matches the service's black-box contract; BATS is already in the Guix shell. Tests: no client cert rejected, untrusted-CA cert rejected, valid client cert echoes path, `text/plain` content type.

**Alternatives considered**: D unit tests — the value is in the TLS handshake behavior, which is e2e only.
