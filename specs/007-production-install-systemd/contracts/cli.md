# Contract: CLI & Configuration

**Branch**: `007-production-install-systemd` | **Date**: 2026-08-05 | **Feature**: [spec.md](../spec.md)

## Usage

```text
mtls-hello [port] [serverCert] [serverKey] [options]
```

## Positional arguments

| # | Argument | Default | Notes |
|---|---|---|---|
| 1 | port | `8443` | `0` = random ephemeral port |
| 2 | server certificate (chain) file | `certs/certs/server.crt` | |
| 3 | server private key file | `certs/private/server.key` | |

Positional parsing stops at the first token starting with `--`.

## Options

| Option | Default | Effect |
|---|---|---|
| `--version` | — | Print version string to stdout and exit 0. Overrides all other arguments. |
| `--port-file=PATH` | — | Write the chosen listen port number to `PATH` atomically (temp-file + rename). File contains just the port number (no newline, no prefix). |
| `--multicast-group=ADDR` | `239.255.42.42` | Multicast group address |
| `--multicast-port=PORT` | `4242` | Multicast port |
| `--multicast-interval=SECS` | `5` | Announcement interval in seconds |
| `--no-multicast` | (enabled) | Disables announcements and listening entirely |
| `--handlers-dir=DIR` | `handlers` | Handler script directory (`=` or space form) |
| `--script-timeout=SECS` | `10` | Handler script timeout (min 1, `=` or space form) |
| `--trust-dir=DIR` | — | Trusted peer certificate directory (`=` or space form) |
| `--purgatory-dir=DIR` | — | Untrusted/new peer certificate quarantine directory (`=` or space form) |

## Random Port Behavior (port = 0)

When port is `0`:

1. Server pre-binds a temporary TCP socket to port 0 on `::1`.
2. Reads the OS-assigned port `P` from the socket.
3. Closes the temporary socket.
4. Uses `P` as the listen port for the HTTPS server.

If `--port-file=PATH` is also given, `P` is written atomically to `PATH` after the socket is bound but before the log message. The file contains just the port number (e.g., `37421`).

If no port is available (all ephemeral ports exhausted), the server exits non-zero with an error message on stderr.

**Log output** (stderr/journal):

```text
listening on https://::1, 127.0.0.1:37421 (mutual TLS, client certs verified by trust store …)
```

## Port File Contract

- **Format**: Just the port number as decimal ASCII. No prefix, no newline, no trailing whitespace.
- **Atomicity**: Written to a temp file in the same directory, then `rename(2)`-ed into place. Observers never see partial content.
- **Timing**: Written immediately after the server binds, before the first `accept`.
- **Cleanup**: The server does NOT delete the port file on shutdown (systemd's `ExecStartPost` needs it). systemd cleans `%t` on logout.

## Exit behavior

| Scenario | Exit code |
|---|---|
| `--version` given | 0 |
| Successful startup (listening) | 0 (runs until signal) |
| Invalid port value | non-zero |
| Port 0 but no free ports | non-zero |
| Certificate files missing or invalid | non-zero |
| TLS context creation fails | non-zero |
| Port-file directory not writable | 0 (server starts; warning logged) |

## Backward Compatibility

- Port 8443 remains the default when no port argument is given. Existing callers are unaffected.
- All existing options and positional arguments behave identically.
- `--version` is a new flag with no conflicts.
- `--port-file` is a new option with no conflicts.
