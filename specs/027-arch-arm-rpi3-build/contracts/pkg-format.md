# Contract: Package Format (`.pkg.tar.zst`)

**Date**: 2026-08-07
**Feature**: 027-arch-arm-rpi3-build

The shape of the .pkg.tar.zst artifact that pacman and Arch Linux ARM expect.

## PKGINFO schema (Arch Linux package metadata, RFC-822-ish keys)

```text
pkgname = mtls-hello
pkgver = 0.13.2-1
pkgdesc = mTLS-aware discovery + sync + dropbox via Apache httpd + D daemon
url = https://github.com/mkf/mtls-hello
arch = armv7h
builddate = 1723075200     # SOURCE_DATE_EPOCH-derived, integer unix epoch
packager = mkf <mkf@mkf.pl>
size = 12345              # kilobytes of payload
depend = apache
depend = bash
depend = openssl
depend = git
depend = coreutils
depend = grep
depend = findutils
depend = sed
depend = awk
depend = glibc
depend = zstd
```

### Mandatory fields

| Key | Value | Why |
|-----|-------|-----|
| `pkgname` | `mtls-hello` | how `pacman -Ql mtls-hello` finds it |
| `pkgver` | `${project_version}-${pkgrel}` | monotonically comparable |
| `arch` | `armv7h` | FR-003 — wrong-arch package rejects install |
| `depend =` | one or more lines, one package per line | FR-006 |

### Optional but conventional

| Key | When omitted |
|-----|--------------|
| `pkgdesc` | always present — Arch guidelines |
| `url` | always present |
| `packager` | always present |
| `optdepend` | `optdepend = mod_dav: required for the per-host drop-box` — explicit because Apache's `mod_dav` is sometimes split out |
| `provides` | not used |
| `replaces` | never |
| `backup` | never (we don't touch system files) |

## MTREE

A `.MTREE` file describing directory/file modes, owners, timestamps. Generated automatically by makepkg. Our package has `root:root` and `0644/0755` modes only.

## INSTALL

A `.INSTALL` shell snippet. Functions `post_install()` and `post_upgrade()` are called by pacman after install/upgrade.

```bash
post_install() {
    echo "mtls-hello installed. Enable with:"
    echo "  systemctl --user daemon-reload"
    echo "  systemctl --user enable --now mtls-hello"
    echo "A self-signed certificate will be generated on first start."
}

post_upgrade() {
    post_install
}
```

`pre_install`, `pre_upgrade`, `pre_remove`, `post_remove` may be defined but don't have to.

## Payload file layout

All paths inside the archive are relative to `./` and must not begin with `./usr/`. Standard convention:

| Path | Source on host | Mode |
|------|----------------|------|
| `./usr/bin/mtls-hello` | `bin/mtls-hello` (cross-built) | 0755 |
| `./usr/lib/systemd/user/mtls-hello.service` | installed by `scripts/install.sh --systemd-only` | 0644 |
| `./var/lib/mtls-hello/handlers/*.sh` | `handlers/*.sh` | 0755 |
| `./var/lib/mtls-hello/scripts/cgi-lib.sh` | `scripts/cgi-lib.sh` | 0644 |
| `./var/lib/mtls-hello/scripts/sync-lib.sh` | `scripts/sync-lib.sh` | 0644 |
| `./var/lib/mtls-hello/scripts/on-discovery.d/*.sh` | `scripts/on-discovery.d/*.sh` | 0755 |
| `./var/lib/mtls-hello/scripts/apache-config.sh` | `scripts/apache-config.sh` | 0755 |
| `./var/lib/mtls-hello/scripts/gen-certs.sh` | `scripts/gen-certs.sh` | 0755 |
| `./var/lib/mtls-hello/scripts/build-nncp.sh` | `scripts/build-nncp.sh` | 0755 |
| `./var/lib/mtls-hello/scripts/install.sh` | `scripts/install.sh` | 0755 |
| `./var/lib/mtls-hello/scripts/install-service.sh` | `scripts/install-service.sh` | 0755 |
| `./var/lib/mtls-hello/scripts/log-capture.sh` | `scripts/log-capture.sh` | 0755 |
| `./var/lib/mtls-hello/scripts/merge-spool.sh` | `scripts/merge-spool.sh` | 0755 |
| `./var/lib/mtls-hello/scripts/trust-host.sh` | `scripts/trust-host.sh` | 0755 |
| `./var/lib/mtls-hello/scripts/migrate-layout.sh` | `scripts/migrate-layout.sh` | 0755 |
| `./var/lib/mtls-hello/scripts/cleanup-common.sh` | `scripts/cleanup-common.sh` | 0644 |
| `./var/lib/mtls-hello/cli/*.sh` | `cli/*.sh` (mtls-cp, mtls-del, etc.) | 0755 |
| `./var/lib/mtls-hello/bin/{nncp,nncp-toss,nncp-call,...}` | cross-built by `scripts/build-nncp.sh` | 0755 |
| `./var/lib/mtls-hello/drop/` | empty directory | 0755 |
| `./var/lib/mtls-hello/identity/` | empty directory (populated on first run by `scripts/gen-certs.sh`) | 0755 |

## Self-consistency checks pacman will run

| Check | Command | Expected outcome |
|-------|---------|-----------------|
| `pacman -Qi mtls-hello` | read PKGINFO | lists pkgname, pkgver, arch, depend |
| `pacman -Ql mtls-hello` | list payload | lists files with `./` prefix |
| `pacman -Qkk mtls-hello` | md5sum check | all files match (when `SOURCE_DATE_EPOCH` set deterministically) |
| `tar -tvf mtls-hello-*.pkg.tar.zst \| head` | raw inspection | first 3 entries are `.PKGINFO`, `.INSTALL`, `.MTREE` (no `./` prefix on metadata) |
| `tar -tvf ... \| wc -l` | file count | matches expected for the layout above |
