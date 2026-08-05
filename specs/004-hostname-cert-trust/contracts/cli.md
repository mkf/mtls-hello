# Contract: Startup Configuration (CLI) — Trust Store Mode

**Branch**: `004-hostname-cert-trust` | **Date**: 2026-08-05 | **Feature**: [spec.md](../spec.md)

> This contract extends the CLI defined in `specs/001-mtls-echo-discovery/contracts/cli.md`, `specs/002-per-host-cert-hook/contracts/cli.md`, and `specs/003-script-endpoints-git-sync/contracts/cli.md`. Only additions and changed semantics are documented here.

## Usage

```text
mtls-hello [port] [serverCert] [serverKey] [options]
```

The legacy 4th positional (`clientCA`) was removed; inbound client trust is decided entirely by the trust store (see `contracts/trust.md`).

## New Options

| Option | Default | Effect |
|---|---|---|
| `--trust-dir=DIR` | `certs/hosts` | Trust store directory: `<trustDir>/<hostname>.crt` per trusted peer |
| `--purgatory-dir=DIR` | `certs/purgatory` | Quarantine directory for untrusted peers' certificates |

## Option Details

### `--trust-dir=DIR`

- Directory scanned at each client-certificate evaluation: a peer is trusted iff `<trustDir>/<hostname>.crt` exists, its fingerprint matches the presented certificate, and it is currently valid.
- Missing directory = empty trust store = every peer rejected (all captured to purgatory). Not a startup error.

### `--purgatory-dir=DIR`

- Directory where rejected peers' certificates are captured as `<hostname>.<sha256>.crt`.
- Created on demand; not a startup error if missing.

## Exit behavior (unchanged)

- Invalid port value or missing server certificate/key files → error at startup, non-zero exit.
- `--script-timeout` < 1 → error at startup (feature 003, unchanged).
