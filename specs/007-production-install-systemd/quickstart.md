# Quickstart: Production-Ready Install & Systemd Service

**Branch**: `007-production-install-systemd` | **Date**: 2026-08-05 | **Feature**: [spec.md](./spec.md)

## 1. Build and install

```sh
# Build the binary (requires Guix dev shell — one-time setup)
just build

# Install to ~/.local
just install
```

The binary is copied to `~/.local/bin/mtls-hello`. Handler scripts go to `~/.local/share/mtls-hello/handlers/`.

Add `~/.local/bin` to your PATH if not already:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

## 2. Verify the install

```sh
mtls-hello --version
#→ mtls-hello 0.1.0
```

## 3. Test with a random port

```sh
mtls-hello 0 certs/certs/server.crt certs/private/server.key \
  --port-file=/tmp/mtls-port --no-multicast \
  --trust-dir /tmp/trust --purgatory-dir /tmp/purgatory &

sleep 1
port=$(cat /tmp/mtls-port)
echo "Server listening on port $port"

# Verify it responds
curl -k --cert certs/certs/client.crt --key certs/private/client.key \
  "https://localhost:$port/hello"
#→ hello

kill %1
```

## 4. Install the systemd service

```sh
just install-service
```

This creates `~/.config/systemd/user/mtls-hello.service`.

**Important**: The generated service file uses `--port=0` (random port) and `--no-multicast`. It does NOT include certificate paths — you MUST add them via a drop-in override.

## 5. Configure certificates for the service

```sh
systemctl --user edit mtls-hello
```

Add your paths (the empty `ExecStart=` clears the default, then you set the real one):

```ini
[Service]
ExecStart=
ExecStart=%h/.local/bin/mtls-hello --port=0 --port-file=%t/mtls-hello.port --no-multicast --handlers-dir=%h/.local/share/mtls-hello/handlers %h/certs/server.crt %h/certs/server.key --trust-dir %h/certs/trusted --purgatory-dir %h/certs/purgatory
```

The `%h` and `%t` specifiers are resolved by systemd at runtime.

## 6. Start and enable the service

```sh
systemctl --user daemon-reload
systemctl --user enable --now mtls-hello
systemctl --user status mtls-hello
```

The port file is at `$XDG_RUNTIME_DIR/mtls-hello.port` (typically `/run/user/1000/mtls-hello.port`):

```sh
cat $XDG_RUNTIME_DIR/mtls-hello.port
#→ 37421
```

## 7. View logs

```sh
journalctl --user -u mtls-hello -f
```

## 8. Stop and disable

```sh
systemctl --user stop mtls-hello
systemctl --user disable mtls-hello
```

## 9. Verify service unit validity

```sh
systemd-analyze --user verify ~/.config/systemd/user/mtls-hello.service
```
