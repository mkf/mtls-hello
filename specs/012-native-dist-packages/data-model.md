# Data Model: Native Distribution Packages

## Output artifacts

| Artifact | Path | Format |
|---|---|---|
| Debian package | `dist/mtls-hello_<version>_amd64.deb` | `dpkg-deb` binary package |
| Arch package | `dist/mtls-hello-<version>-1-x86_64.pkg.tar.zst` | `makepkg`/`pacman` binary package |

## Package file tree (both distros, system-wide)

```
usr/bin/mtls-hello                              # compiled D binary
usr/lib/mtls-hello/handlers/bundle.post.sh      # handler scripts
usr/lib/mtls-hello/scripts/on-discover.sh       # discovery callback
usr/lib/mtls-hello/scripts/pre-push.sh.new      # hook template
usr/lib/systemd/user/mtls-hello.service         # systemd user unit
```

## Debian package metadata

| Field | Value |
|---|---|
| Package | `mtls-hello` |
| Version | `<dub.json version>` |
| Architecture | `amd64` |
| Depends | `libc6, libssl3, openssl` |
| Description | from `dub.json` |

Scripts:
- `DEBIAN/postinst` — generate self-signed cert if missing (CN=hostname, 10yr, key 0600)
- `DEBIAN/prerm` — (optional) note to stop service before removal

## Arch package metadata (.PKGINFO)

| Field | Value |
|---|---|
| pkgname | `mtls-hello` |
| pkgver | `<version>-1` |
| arch | `x86_64` |
| depend | `openssl`, `ldc` (runtime libs) |
| pkgdesc | from `dub.json` |

Scripts:
- `.INSTALL` — generate self-signed cert if missing

## Systemd user unit (shared content)

```ini
[Unit]
Description=mtls-hello mutual-TLS server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/mtls-hello 8443 \
  /var/lib/mtls-hello/certs/certs/server.crt \
  /var/lib/mtls-hello/certs/private/server.key \
  --port=0 --port-file=%t/mtls-hello.port \
  --data-dir=/var/lib/mtls-hello \
  --no-multicast
ExecStartPost=/bin/sh -c 'echo "mtls-hello listening on port $(cat %t/mtls-hello.port)"'
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
```

## Docker build inputs/outputs

| Container | Base image | Input | Output |
|---|---|---|---|
| Debian builder | `debian:bookworm` | source mounted read-only at `/src` | `/out/mtls-hello_*.deb` |
| Arch builder | `archlinux:latest` | source mounted read-only at `/src` | `/out/mtls-hello-*.pkg.tar.zst` |

## Distro detection (entry-point script)

| `/etc/os-release` field | Value | Dispatches to |
|---|---|---|
| `ID` or `ID_LIKE` contains `debian` | Debian/Ubuntu | `package-debian.sh` |
| `ID` is `arch` | Arch | `package-arch.sh` |
| anything else | unsupported | exit 1 with error |
