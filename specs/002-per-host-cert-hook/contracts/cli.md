# Contract: Startup Configuration (CLI) — Updated

**Branch**: `002-per-host-cert-hook` | **Date**: 2026-03-19 | **Feature**: [spec.md](../spec.md)

> This contract extends the CLI defined in `specs/001-mtls-echo-discovery/contracts/cli.md`. Only additions are documented here; existing positional arguments and options remain as specified in 001.

## Usage

```text
mtls-hello [port] [serverCert] [serverKey] [options]
```

## New Options

| Option | Default | Effect |
|---|---|---|
| `--host=NAME` | `gethostname()` | Hostname announced in multicast messages |
| `--peer-cert-dir=DIR` | `certs/hosts` | Directory containing per-hostname peer certificates |
| `--client-cert=FILE` | `certs/certs/client.crt` | Our client certificate for outgoing authenticated requests |
| `--client-key=FILE` | `certs/private/client.key` | Our client private key for outgoing authenticated requests |
| `--on-discovery=SCRIPT` | (none — disabled) | Path to operator's callback script; executed on each peer announcement |

## Option Details

### `--host=NAME`

- Sets the hostname announced in multicast messages and used for self-announcement filtering.
- Defaults to the system hostname (`gethostname()`).
- Used as `host` value in the JSON announcement: `{"service":"mtls-hello","port":8443,"host":"myhost"}`.

### `--peer-cert-dir=DIR`

- Directory scanned for `<hostname>.crt` files — one per known peer.
- Each file must contain the peer's X.509 server certificate (public key).
- Files named `<hostname>.crt` are matched against the `host` field from announcements.
- The directory may be empty if no peers are known (callbacks simply won't fire for unknown peers).

### `--client-cert=FILE` / `--client-key=FILE`

- Our client identity used by the `mtls_curl` helper for outgoing authenticated requests.
- Passed to the callback script as `OUR_CERT` and `OUR_KEY` environment variables.
- Must be valid X.509 certificate and private key trusted by the peer's CA.

### `--on-discovery=SCRIPT`

- If provided, the server spawns this script on every valid peer announcement (excluding self-announcements).
- The script path may be absolute or relative to the server's working directory.
- The script is spawned via `/bin/sh -c "exec <script>"` so it may use a shebang or rely on `/bin/sh`.
- The script receives environment variables defined in [callback.md](./callback.md).
- If the script is missing or not executable, the server logs a warning at startup and discovery proceeds without callbacks.
- If NOT provided, discovery works as in feature 001 (log-only, no callback).
