# Quickstart: Native Distribution Packages

## On the dev machine (any distro with Docker) — build both packages

```bash
just package-docker
# → dist/mtls-hello_0.1.0_amd64.deb
# → dist/mtls-hello-0.1.0-1-x86_64.pkg.tar.zst
```

## On a Debian/Ubuntu host — build natively

```bash
# one-time: install build deps
sudo apt install ldc dub libssl-dev pkg-config

just package-debian
# → dist/mtls-hello_0.1.0_amd64.deb
```

## On an Arch host — build natively

```bash
# one-time: install build deps
sudo pacman -S ldc dub openssl pkgconf

just package-arch
# → dist/mtls-hello-0.1.0-1-x86_64.pkg.tar.zst
```

## On any supported distro — let it detect

```bash
just package
# detects Debian → builds .deb
# detects Arch → builds .pkg.tar.zst
# unsupported → error, suggests `just package-docker`
```

## Install the Debian package on a Debian target

```bash
sudo dpkg -i dist/mtls-hello_0.1.0_amd64.deb
# postinst generates a self-signed cert if none exists

systemctl --user daemon-reload
systemctl --user enable --now mtls-hello
systemctl --user status mtls-hello
# → Active: active (running)

journalctl --user -u mtls-hello -f
# → mtls-hello listening on port 42xxx
```

## Install the Arch package on an Arch target

```bash
sudo pacman -U dist/mtls-hello-0.1.0-1-x86_64.pkg.tar.zst
# .INSTALL generates a self-signed cert if none exists

systemctl --user daemon-reload
systemctl --user enable --now mtls-hello
```

## Verify

```bash
mtls-hello --version
# → 0.1.0

ls /usr/bin/mtls-hello /usr/lib/mtls-hello/handlers/
ls /usr/lib/systemd/user/mtls-hello.service
```

## Upgrade (cert preserved)

```bash
sudo dpkg -i dist/mtls-hello_0.1.0_amd64.deb   # or pacman -U
# existing certificate is NOT overwritten
```

## Remove (user data preserved)

```bash
sudo dpkg -r mtls-hello        # Debian
# or
sudo pacman -R mtls-hello      # Arch
# package files removed; user certs/repos/trust store remain
```
