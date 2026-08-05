# CLI Contract: Self-Extracting Installer

## Synopsis

```
bash mtls-hello-installer-<hash>-<date>[-dirty].sh [--help|-h] [install|install-service]
```

## Subcommands

### `install`

Extracts the embedded payload and installs the binary, vendored libraries, handlers, and hook templates to `~/.local/`. Generates a self-signed server certificate on first install.

**Preconditions**: `~/.local/bin/mtls-hello` does not need to exist (it will be created). `openssl` should be available for cert generation (if not, cert generation is skipped with a warning).

**Postconditions**:
- `~/.local/bin/mtls-hello` is an executable binary
- `~/.local/lib/mtls-hello/` contains vendored `.so` files
- `~/.local/share/mtls-hello/handlers/` contains handler scripts
- `~/.local/share/mtls-hello/scripts/` contains hook templates (`*.new`)
- If openssl is available and no cert exists: `~/.local/share/mtls-hello/certs/certs/server.crt` and `.../private/server.key` exist (CN=hostname, 10yr, key mode 600)
- If a cert already exists: it is NOT overwritten

**Exit codes**:
- `0` — success
- `1` — failure (e.g., disk full, permission denied)

**Stdout**: Progress messages ("Installed mtls-hello to ...", "Generated self-signed certificate for ...")

**Stderr**: Warnings and errors

### `install-service`

Creates a systemd user unit at `~/.config/systemd/user/mtls-hello.service`.

**Preconditions**: `~/.local/bin/mtls-hello` must exist (if not, prints error and exits non-zero). `~/.config/systemd/user/` will be created if missing.

**Postconditions**:
- `~/.config/systemd/user/mtls-hello.service` exists with:
  - `LD_LIBRARY_PATH=%h/.local/lib/mtls-hello`
  - Absolute cert paths, `--port=0`, `--data-dir=%h/.local/share/mtls-hello`
  - `Restart=on-failure`

**Exit codes**:
- `0` — success
- `1` — binary not found (must run `install` first)
- `1` — other failure

**Stdout**: "Service unit installed to ..." and next-step instructions

**Stderr**: Error messages

### `--help` / `-h`

Prints usage summary and exits 0.

### No subcommand

Same as `--help` (prints usage, exits 1).
