# Data Model: Production Install & Systemd Service

**Feature**: 007-production-install-systemd | **Date**: 2026-08-05

## Entities

### Install Layout

The install layout maps source artifacts to their installed locations under `~/.local`.

| Artifact | Source | Destination | Permissions |
|---|---|---|---|
| Server binary | `./mtls-hello` (build output) | `~/.local/bin/mtls-hello` | 0755 (rwxr-xr-x) |
| Handler scripts | `./handlers/` | `~/.local/share/mtls-hello/handlers/` | preserved from source (0755 for .sh scripts) |
| Service unit | generated | `~/.config/systemd/user/mtls-hello.service` | 0644 (rw-r--r--) |

**Invariants**:
- The binary and handlers are only installed to `~/.local` — never to system directories.
- The service unit always references `%h/.local/bin/mtls-hello` (the installed binary), never a source-tree path.
- `just install-service` refuses to create a unit file if the binary is not installed.

### CLI Configuration (new flags)

| Flag | Type | Default | Description |
|---|---|---|---|
| `--version` | flag | — | Print version string and exit 0 |
| `--port=0` | value | 8443 (when omitted) | Listen port; 0 = random ephemeral |
| `--port-file=PATH` | value | — | Write chosen port number to this file atomically |

**State transitions for port**:
1. Server parses port argument → N (port number)
2. If N == 0: pre-bind a socket, get OS-assigned port P, close socket
3. If N != 0: P = N
4. Start vibe.d HTTP listener on port P
5. If `--port-file` given: write P atomically to file
6. Log "listening on …:P" to stderr/log

### Service Unit Template

```ini
[Unit]
Description=mtls-hello mutual-TLS server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=%h/.local/bin/mtls-hello --port=0 --port-file=%t/mtls-hello.port --no-multicast --handlers-dir=%h/.local/share/mtls-hello/handlers
ExecStartPost=/bin/sh -c 'echo "mtls-hello listening on port $(cat %t/mtls-hello.port)"'
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
```

**systemd specifiers** (resolved at runtime by systemd):
- `%h` → user home directory (e.g., `~`)
- `%t` → runtime directory (e.g., `/run/user/1000`)

**Operator customization**: The operator adds certificate paths via a drop-in override:
```sh
systemctl --user edit mtls-hello
```
Adding:
```ini
[Service]
ExecStart=
ExecStart=%h/.local/bin/mtls-hello --port=0 --port-file=%t/mtls-hello.port --no-multicast --handlers-dir=%h/.local/share/mtls-hello/handlers /path/to/server.crt /path/to/server.key --trust-dir /path/to/trust --purgatory-dir /path/to/purgatory
```

The empty `ExecStart=` clears the previous value before setting the new one (systemd override convention).
