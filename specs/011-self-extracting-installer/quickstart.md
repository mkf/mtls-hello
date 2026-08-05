# Quickstart: Self-Extracting Portable Installer

## Build the installer (dev machine, with Guix)

```bash
just self-extract
# Produces: mtls-hello-installer-abc1234-20260805.sh
```

If the working tree has uncommitted changes:

```bash
echo "test" > /tmp/dirty
just self-extract
# Produces: mtls-hello-installer-abc1234-20260805-dirty.sh
```

## Deploy to a target machine

```bash
# Copy the installer to the target:
scp mtls-hello-installer-*.sh user@debian-server:

# On the target:
ssh user@debian-server

bash mtls-hello-installer-abc1234-20260805.sh install
# → Installed binary, libs, handlers, certs to ~/.local

bash mtls-hello-installer-abc1234-20260805.sh install-service
# → Created systemd user unit at ~/.config/systemd/user/mtls-hello.service

systemctl --user daemon-reload
systemctl --user enable --now mtls-hello
systemctl --user status mtls-hello
# → Active: active (running)
```

## Verify

```bash
# Check the installed binary works with vendored libs:
~/.local/bin/mtls-hello --version
# → 0.1.0

# Check cert was generated:
ls -l ~/.local/share/mtls-hello/certs/certs/server.crt
ls -l ~/.local/share/mtls-hello/certs/private/server.key
# → server.key mode 600

# Check the service port file:
cat $XDG_RUNTIME_DIR/mtls-hello.port
# → random port number
```

## Re-install

```bash
bash mtls-hello-installer-*.sh install
# Binary and handlers are overwritten. Certificate is NOT overwritten.

bash mtls-hello-installer-*.sh install-service
# Service unit is overwritten. systemctl daemon-reload needed.
```

## Troubleshooting

```bash
# openssl not found on target → cert generation skipped
# Solution: install openssl and re-run install, or provide certs manually

# Binary fails to start → likely glibc too old
ldd --version | head -1
# → Must be ≥ 2.31 (Debian 11+)
```
