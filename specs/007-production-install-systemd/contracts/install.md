# Contract: Install & Service Generation

**Branch**: `007-production-install-systemd` | **Date**: 2026-08-05 | **Feature**: [spec.md](../spec.md)

## `just install` → `scripts/install.sh`

### Preconditions

- `mtls-hello` binary exists in the repository root (produced by `just build`)
- `handlers/` directory exists in the repository root

### Behavior

1. Creates `~/.local/bin/` if it doesn't exist (`mkdir -p`).
2. Copies `mtls-hello` to `~/.local/bin/mtls-hello` with mode `0755`.
3. Creates `~/.local/share/mtls-hello/` if it doesn't exist.
4. Removes any previous `~/.local/share/mtls-hello/handlers/` (to avoid stale files).
5. Copies `handlers/` to `~/.local/share/mtls-hello/handlers/` (recursive, preserving permissions).

### Post-install message

```text
Installed mtls-hello to ~/.local/bin/mtls-hello
Installed handlers to ~/.local/share/mtls-hello/handlers/

If ~/.local/bin is not on your PATH, add:
  export PATH="$HOME/.local/bin:$PATH"
```

### Edge cases

| Scenario | Behavior |
|---|---|
| `~/.local/bin` doesn't exist | Created (`mkdir -p`). |
| `mtls-hello` binary not found | Exit non-zero with: `Error: mtls-hello binary not found. Run 'just build' first.` |
| Previous install exists | Overwritten cleanly (handlers dir removed then re-copied). |
| Install run twice | Idempotent — exits 0, no errors. |

## `just install-service` → `scripts/install-service.sh`

### Preconditions

- `~/.local/bin/mtls-hello` exists (produced by `just install`)

### Behavior

1. Checks that `~/.local/bin/mtls-hello` exists. If not, exits non-zero with: `Error: ~/.local/bin/mtls-hello not found. Run 'just install' first.`
2. Creates `~/.config/systemd/user/` if it doesn't exist (`mkdir -p`).
3. Writes the service unit file to `~/.config/systemd/user/mtls-hello.service` with content:

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

### Post-install message

```text
Service unit installed to ~/.config/systemd/user/mtls-hello.service

Next steps:
  systemctl --user daemon-reload
  systemctl --user enable --now mtls-hello

To add certificates and trust paths, create a drop-in override:
  systemctl --user edit mtls-hello
```

### Certificate and trust configuration

The generated service file intentionally does NOT include certificate, key, trust-dir, or purgatory-dir paths. These are deployment-specific and must be configured by the operator via a systemd drop-in override:

```sh
systemctl --user edit mtls-hello
```

Adding:

```ini
[Service]
ExecStart=
ExecStart=%h/.local/bin/mtls-hello --port=0 --port-file=%t/mtls-hello.port --no-multicast --handlers-dir=%h/.local/share/mtls-hello/handlers /path/to/server.crt /path/to/server.key --trust-dir /path/to/trusted --purgatory-dir /path/to/purgatory
```

The empty `ExecStart=` clears the previous value. The replacement `ExecStart=` sets the full command with certificate paths.

### Edge cases

| Scenario | Behavior |
|---|---|
| `~/.config/systemd/user` doesn't exist | Created (`mkdir -p`). |
| `~/.local/bin/mtls-hello` doesn't exist | Exit non-zero with error message. |
| Previous service file exists | Overwritten. |
| systemd not running (chroot, container) | Script succeeds; operator must verify service on target. |

## Exit Codes

| Script | Code | Meaning |
|---|---|---|
| `install.sh` | 0 | Success |
| `install.sh` | 1 | Binary not found |
| `install.sh` | 2 | Copy failed (permissions, disk space) |
| `install-service.sh` | 0 | Success |
| `install-service.sh` | 1 | Binary not installed |
| `install-service.sh` | 2 | File write failed |
